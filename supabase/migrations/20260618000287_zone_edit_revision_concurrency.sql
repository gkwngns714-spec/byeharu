-- 0287 — ZONE EDIT CONCURRENCY: compare danger_zones.revision, not a re-materialized boundary.
--
-- THE DEFECT (reproduced on a disposable stack, not inferred). After 0286 fixed the 42703 crash,
-- publishing an edit of a real zone returned:
--
--     {ok:false, error:'stale_revision',
--      details:[{code:'source_changed', field:'geometry',
--                message:"The live zone's geometry changed since this draft was forked."}]}
--
-- on a row that had NOT changed. Measured in the running app: name identical, attach identical, all 14
-- geometry vertices byte-identical to the draft's fork-time snapshot, and the client's own staleness
-- check agreeing ('dirty', not 'stale').
--
-- WHY. 0284's compare re-materialized the fork-time ring and compared it with ST_Equals, on the stated
-- premise that it was "robust to the full-precision [x,y] ring get_danger_zones hands the client".
-- That ring is NOT full precision. get_danger_zones emits it through
-- jsonb_build_array(ST_X(pt.geom), ST_Y(pt.geom)), and those float8 values reach the client at 15
-- significant digits (measured: 96 coordinates across all live zones, histogram {14:14, 15:82},
-- maximum 15). For any boundary whose doubles need more — every ST_Buffer arc, i.e. every seeded zone
-- — the client cannot send back a ring that re-materializes to an ST_Equals-identical geometry. The
-- compare therefore failed PERMANENTLY, and re-forking could not help because the fork reads through
-- the same lossy channel. Every seeded zone was unpublishable via edit.
--
-- WHY THE SUITE WAS GREEN. Every fixture in the zone-update proof is built by zone_create from literal
-- integer coordinates (0, 300 …), which survive 15-digit formatting exactly, so `expected`
-- re-materializes bit-identically and ST_Equals passes trivially. The one geometry class that actually
-- ships was never covered. PROOF 11 (added with this slice) closes that: it builds a buffer-arc
-- boundary, reads the ring back through get_danger_zones — the client's only channel — and publishes a
-- name-only edit. It FAILS on 0286 and PASSES here.
--
-- THE FIX — ONE authority, already on the platform. 0275 added danger_zones.revision and 0285's
-- zone_kind_change already selects and bumps it. zone_update simply never used it. This migration:
--   * exposes `revision` (and `provenance`) through get_danger_zones so a draft can carry the token;
--   * makes zone_update compare that token instead of re-deriving geometry;
--   * BUMPS revision on every applied edit, so the token actually advances (0284 never did).
-- The per-field name/attach checks remain, demoted to DIAGNOSTICS: they explain a rejection the
-- revision has already decided. They no longer gate — there is not a second concurrency authority.
--
-- FAIL-CLOSED: a draft carrying no token, or a non-numeric one (forked before this landed), is
-- rejected as drifted rather than published against an unknown baseline. Re-forking is the recovery.
--
-- SECURITY / SHAPE UNCHANGED: no signature, no grant, no guard order, no error vocabulary change.
-- zone_unpublish and zone_set_active are NOT touched (their `expected` is {name, source, location_id} —
-- plain scalars with no lossy round-trip). Forward-only; 0284/0286 are never edited in place.

-- ── 1. THE READ — expose the concurrency token (and provenance) ─────────────────────────────────────
-- Additive only: every existing key keeps its name, type and meaning. `ring` stays exactly as it was —
-- it remains the DRAWING input; it is simply no longer load-bearing for staleness.
create or replace function public.get_danger_zones()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', z.id, 'name', z.name, 'source', z.source, 'location_id', z.location_id,
    'revision', z.revision,
    'provenance', z.provenance,
    'ring', (
      select jsonb_agg(jsonb_build_array(ST_X(pt.geom), ST_Y(pt.geom)) order by pt.path[1])
        from ST_DumpPoints(ST_ExteriorRing(z.boundary)) as pt
    )
  )), '[]'::jsonb)
  from public.danger_zones z
  where z.status = 'active' and public.cfg_bool('pirate_intercept_enabled')
$$;

revoke all on function public.get_danger_zones() from public;
grant execute on function public.get_danger_zones() to anon, authenticated;

-- ── 2. zone_update — revision is the concurrency authority ──────────────────────────────────────────

create or replace function public.zone_update(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_target    text;
  v_target_id uuid;
  v_expected  jsonb;
  v_fields    jsonb;
  v_details   jsonb := '[]'::jsonb;
  v_name      text;
  v_attach_raw text;
  v_attach    uuid;
  v_geom      jsonb;
  v_gkind     text;
  v_cx        double precision;
  v_cy        double precision;
  v_radius    double precision;
  v_nverts    integer;
  v_i         integer;
  v_vx        double precision;
  v_vy        double precision;
  v_bad_verts integer := 0;
  v_pts       public.geometry[];
  v_boundary  public.geometry;      -- the NEW materialized boundary
  v_egeom     jsonb;                -- the `expected` fork-time geometry (for the concurrency compare)
  v_epts      public.geometry[];
  v_exp_boundary public.geometry;   -- the re-materialized `expected` boundary
  v_live      record;               -- the LOCKED live row
  v_before    jsonb;
  v_after     jsonb;
  v_result    jsonb;
  v_prior     text;
  v_id        uuid;
  v_conflict_table text;
  v_exp_rev   text;                 -- the draft's fork-time revision token (compared against v_live.revision)
  c_lo constant double precision := -10000;  -- the ONE navigable-square bound (0233/0254 idiom)
  c_hi constant double precision :=  10000;
begin
  -- (1) authn — reject the anonymous caller with a typed code (no world touch). [0249:141-143]
  if v_uid is null then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authenticated');
  end if;

  -- (2) authz — THE ONE guard. Non-owner authenticated caller is rejected server-side. [0249:146-148]
  if not public.is_owner() then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authorized');
  end if;

  -- (3) request_id is the idempotency key — it must be present. [0249:151-153]
  if p_request_id is null or length(btrim(p_request_id)) = 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;

  -- (4a) idempotent replay: a prior row for this request_id ⇒ return its result, no second apply.
  select result into v_prior from public.world_editor_audit where request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'request_id', p_request_id,
             'command_type', 'zone_update', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  -- (4b) structural addressing: an UPDATE cannot be located without a uuid target_id and an `expected`
  -- object — missing/malformed addressing is a malformed REQUEST (the 0243 invalid_request code), not a
  -- field-validation report. danger_zones has NO unique natural key (name is not unique), so the PK uuid
  -- is the addressing key (the 0249 location_update / 0255 unpublish variant, not a name key).
  v_target   := btrim(coalesce(p_payload->>'target_id', ''));
  v_expected := p_payload->'expected';
  if v_target = '' or v_expected is null or jsonb_typeof(v_expected) <> 'object' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;
  begin
    v_target_id := v_target::uuid;
  exception when invalid_text_representation then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end;

  -- (5) LOCATE + ROW-LOCK the live target by PRIMARY KEY. The lock holds until commit/rollback, so the
  -- compare-then-write below cannot race a concurrent editor. boundary is selected for the concurrency
  -- geometry compare AND the before_snapshot.
  select id, name, zone_kind, source, location_id, boundary, status, created_by, created_at, provenance, revision
    into v_live
    from public.danger_zones
   where id = v_target_id
     for update;
  if not found then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_found',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_missing', 'field', null,
               'message', 'No live zone with id ''' || v_target || ''' exists — it may have been removed since the draft was forked.')));
  end if;

  -- (5b) SEEDED-ZONE PROTECTION — only editor-created source='drawn' zones are editable. The seeded
  -- source='circle' zones (and any future seed) are NEVER editable through the editor: a typed
  -- validation_failed {protected_zone} (the 0255 zone_unpublish protected_zone guard, surfaced through
  -- the SAME details pipeline — no new top-level error code). Fail-closed on an ineligible target.
  if v_live.provenance = 'seeded'
     and not coalesce(public.cfg_bool('seeded_zone_edit_enabled'), false) then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'validation_failed', 'details', jsonb_build_array(jsonb_build_object(
               'code', 'protected_zone', 'field', 'source',
               'message', 'This is a seeded zone. Seeded-zone editing is not enabled.')));
  end if;
  -- (6) OPTIMISTIC CONCURRENCY — ONE authority: danger_zones.revision, the server's own token (0275).
  --
  -- WHAT THIS REPLACES, AND WHY. 0284 compared the locked row against `expected` value-by-value and
  -- re-materialized the fork-time ring to compare it SPATIALLY with ST_Equals. Its comment claimed the
  -- compare was "robust to the full-precision [x,y] ring get_danger_zones hands the client". That
  -- premise is false: get_danger_zones emits the ring through jsonb_build_array(ST_X(...), ST_Y(...)),
  -- and those float8 values cross the wire at 15 significant digits. For any boundary whose doubles
  -- need more, the client CANNOT send back a ring that re-materializes to an ST_Equals-identical
  -- geometry — so the compare failed forever and re-forking could not help, because the fork reads
  -- through the same lossy channel. Reproduced on a disposable stack: a buffer-arc zone, read back
  -- through get_danger_zones and published with ONLY its name changed, was rejected stale_revision
  -- {geometry} (scripts/worldeditor-publish-zone-update-proof.sql, PROOF 11 — which fails on 0286 and
  -- passes here). Every seeded zone was permanently unpublishable via edit.
  --
  -- The revision is exact, opaque, and immune to coordinate rounding. It is ALSO already the platform's
  -- token: 0275 added the column and 0285's zone_kind_change selects and bumps it. This makes the
  -- SINGLE authority explicit rather than adding one beside the value compares — the per-field checks
  -- below no longer DECIDE anything; they only explain a rejection the revision already made.
  if v_expected ? 'source_revision' then
    v_exp_rev := nullif(btrim(v_expected->>'source_revision'), '');
  else
    v_exp_rev := nullif(btrim(p_payload->>'source_revision'), '');
  end if;
  -- A draft forked before the revision was exposed carries no usable token. FAIL CLOSED: reject as
  -- drifted rather than publish against an unknown baseline (re-fork is the owner's recovery).
  if v_exp_rev is null or v_exp_rev !~ '^[0-9]+$' or v_exp_rev::bigint is distinct from v_live.revision then
    -- Diagnostics only — WHICH fields moved, so the owner knows what re-forking will show them. These
    -- are advisory strings attached to a decision the revision has already made; they never gate.
    if v_expected->>'name' is distinct from v_live.name then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'source_changed', 'field', 'name',
        'message', 'The live zone''s name changed since this draft was forked.'));
    end if;
    if coalesce(v_expected->'attach_location_id', 'null'::jsonb)
         is distinct from coalesce(to_jsonb(v_live.location_id), 'null'::jsonb) then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'source_changed', 'field', 'attach_location_id',
        'message', 'The live zone''s attachment changed since this draft was forked.'));
    end if;
    if jsonb_array_length(v_details) = 0 then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'source_changed', 'field', null,
        'message', 'The live zone changed since this draft was forked — re-open it to edit the current version.'));
    end if;
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'stale_revision', 'details', v_details);
  end if;

  -- (7) SERVER-SIDE re-validation of the MUTABLE subset (p_payload->'fields') — the SAME rules and
  -- error codes as the advisory client mirror (zoneValidation.ts), PLUS the attach rule, mirroring
  -- zone_create (0254) EXACTLY for name / attach_location_id / geometry. zone_kind is NOT a mutable
  -- field (fixed 'pirate') and is neither validated nor written. The client is NEVER trusted; every
  -- issue is collected so the full report renders at once.
  v_fields := p_payload->'fields';
  if v_fields is null or jsonb_typeof(v_fields) <> 'object' then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'invalid_payload', 'field', null, 'message', 'payload.fields must be a JSON object.'));
  else
    -- name — required, 1..60 after trim (the danger_zones CHECK, 0233:184).
    v_name := btrim(coalesce(v_fields->>'name', ''));
    if v_name = '' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'name_required', 'field', 'name', 'message', 'Name is required — a zone must be nameable on the map.'));
    elsif char_length(v_name) > 60 then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'name_too_long', 'field', 'name', 'message', 'Name must be at most 60 characters (the live CHECK constraint).'));
    end if;

    -- attach_location_id — null/absent = standalone (a REAL authored value). Otherwise a uuid naming an
    -- EXISTING ACTIVE pirate_hunt/pirate_den location (the EXACT 0254/0233 rule). All failure shapes are
    -- ONE typed code 'invalid_attach' — a dangling reference never surfaces as a raw FK violation.
    if v_fields->'attach_location_id' is null or jsonb_typeof(v_fields->'attach_location_id') = 'null' then
      v_attach := null;
    else
      v_attach_raw := btrim(coalesce(v_fields->>'attach_location_id', ''));
      begin
        v_attach := v_attach_raw::uuid;
      exception when invalid_text_representation then
        v_attach := null;
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'invalid_attach', 'field', 'attach_location_id',
          'message', 'attach_location_id ''' || v_attach_raw || ''' is not a valid uuid.'));
      end;
      if v_attach is not null
         and not exists (select 1 from public.locations l
                          where l.id = v_attach and l.status = 'active'
                            and l.location_type in ('pirate_hunt', 'pirate_den')) then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'invalid_attach', 'field', 'attach_location_id',
          'message', 'No ACTIVE pirate_hunt/pirate_den location with id ''' || v_attach_raw
                     || ''' exists — attach to a live hostile site or publish standalone.'));
        v_attach := null;
      end if;
    end if;

    -- geometry — the draft union. Structural badness is 'invalid_payload'; value badness mirrors the
    -- zoneValidation codes (coord_out_of_bounds / radius_not_positive / polygon_too_few_vertices /
    -- polygon_too_many_vertices). Identical to zone_create (0254).
    v_geom := v_fields->'geometry';
    if v_geom is null or jsonb_typeof(v_geom) <> 'object'
       or (v_geom->>'kind') is null or (v_geom->>'kind') not in ('circle', 'polygon') then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_payload', 'field', 'geometry',
        'message', 'geometry must be {kind:''circle'',center,radius} or {kind:''polygon'',vertices}.'));
    else
      v_gkind := v_geom->>'kind';
      if v_gkind = 'circle' then
        if jsonb_typeof(v_geom->'center') <> 'object'
           or jsonb_typeof(v_geom->'center'->'x') is distinct from 'number'
           or jsonb_typeof(v_geom->'center'->'y') is distinct from 'number' then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code', 'invalid_payload', 'field', 'geometry',
            'message', 'A circle needs a numeric center {x,y}.'));
        else
          v_cx := (v_geom->'center'->>'x')::double precision;
          v_cy := (v_geom->'center'->>'y')::double precision;
        end if;
        if jsonb_typeof(v_geom->'radius') is distinct from 'number' then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code', 'radius_not_positive', 'field', 'geometry',
            'message', 'Circle radius must be a finite number greater than 0.'));
        else
          v_radius := (v_geom->>'radius')::double precision;
          if not (v_radius > 0) then
            v_details := v_details || jsonb_build_array(jsonb_build_object(
              'code', 'radius_not_positive', 'field', 'geometry',
              'message', 'Circle radius must be a finite number greater than 0.'));
          end if;
        end if;
        -- the whole extent (center ± radius, both axes) must fit the world (the client rule, mirrored).
        if v_cx is not null and v_cy is not null and v_radius is not null and v_radius > 0
           and (v_cx - v_radius < c_lo or v_cx + v_radius > c_hi
                or v_cy - v_radius < c_lo or v_cy + v_radius > c_hi) then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code', 'coord_out_of_bounds', 'field', 'geometry',
            'message', 'The circle must fit inside the world: center ± radius must be within ±10000.'));
        elsif v_cx is not null and v_cy is not null
              and (v_cx < c_lo or v_cx > c_hi or v_cy < c_lo or v_cy > c_hi) then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code', 'coord_out_of_bounds', 'field', 'geometry',
            'message', 'The circle center must be within ±10000.'));
        end if;
      else
        -- polygon: an OPEN ring of 3..64 numeric in-bounds vertices (the zoneValidation bounds).
        if jsonb_typeof(v_geom->'vertices') <> 'array' then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code', 'invalid_payload', 'field', 'geometry',
            'message', 'A polygon needs a vertices array of {x,y} points.'));
        else
          v_nverts := jsonb_array_length(v_geom->'vertices');
          if v_nverts < 3 then
            v_details := v_details || jsonb_build_array(jsonb_build_object(
              'code', 'polygon_too_few_vertices', 'field', 'geometry',
              'message', 'A zone polygon needs at least 3 vertices (' || v_nverts || ' sent).'));
          elsif v_nverts > 64 then
            v_details := v_details || jsonb_build_array(jsonb_build_object(
              'code', 'polygon_too_many_vertices', 'field', 'geometry',
              'message', 'A zone polygon carries at most 64 vertices (' || v_nverts || ' sent).'));
          else
            for v_i in 0 .. v_nverts - 1 loop
              if jsonb_typeof(v_geom->'vertices'->v_i) <> 'object'
                 or jsonb_typeof(v_geom->'vertices'->v_i->'x') is distinct from 'number'
                 or jsonb_typeof(v_geom->'vertices'->v_i->'y') is distinct from 'number' then
                v_bad_verts := v_bad_verts + 1;
              else
                v_vx := (v_geom->'vertices'->v_i->>'x')::double precision;
                v_vy := (v_geom->'vertices'->v_i->>'y')::double precision;
                if v_vx < c_lo or v_vx > c_hi or v_vy < c_lo or v_vy > c_hi then
                  v_bad_verts := v_bad_verts + 1;
                end if;
              end if;
            end loop;
            if v_bad_verts > 0 then
              v_details := v_details || jsonb_build_array(jsonb_build_object(
                'code', 'coord_out_of_bounds', 'field', 'geometry',
                'message', v_bad_verts || ' vertex/vertices are not finite numeric points within ±10000.'));
            end if;
          end if;
        end if;
      end if;
    end if;
  end if;

  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'validation_failed', 'details', v_details);
  end if;

  -- (8) MATERIALIZE the NEW boundary with the 0254 idioms VERBATIM:
  --   circle  → ST_Buffer(point, radius, 32)                      [the 0254/0233 seed idiom]
  --   polygon → close the ring + ST_MakePolygon(ST_MakeLine(...)) [the 0254/0233 draw idiom]
  if v_gkind = 'circle' then
    v_boundary := public.st_buffer(public.st_makepoint(v_cx, v_cy), v_radius, 32);
  else
    v_pts := array[]::public.geometry[];
    for v_i in 0 .. v_nverts - 1 loop
      v_pts := v_pts || public.st_makepoint(
        (v_geom->'vertices'->v_i->>'x')::double precision,
        (v_geom->'vertices'->v_i->>'y')::double precision);
    end loop;
    v_pts := v_pts || v_pts[1];  -- close the ring (the draft ring is OPEN by contract)
    v_boundary := public.st_makepolygon(public.st_makeline(v_pts));
  end if;

  -- THE AUTHORITATIVE GEOMETRY GATE (identical to zone_create): owner-drawn rings can self-intersect;
  -- the client scan is advisory. PostGIS decides — an invalid or zero-area boundary is a typed
  -- rejection, never a write.
  if v_boundary is null or not public.st_isvalid(v_boundary) or not (public.st_area(v_boundary) > 0) then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'validation_failed', 'details', jsonb_build_array(jsonb_build_object(
               'code', 'invalid_geometry', 'field', 'geometry',
               'message', 'The materialized boundary is not a valid, positive-area polygon — untangle the ring.')));
  end if;

  -- (9) apply + audit in ONE sub-block: any unique_violation rolls BOTH back atomically. danger_zones
  -- has NO unique natural key, so the only reachable unique_violation is world_editor_audit.request_id —
  -- a concurrent duplicate raced us ⇒ idempotent replay (this call's UPDATE is undone by the sub-block
  -- rollback — no torn write). ONLY boundary + name + location_id + updated_at are written: source
  -- ('drawn'), zone_kind ('pirate'), created_by and created_at are preserved bit-for-bit (a zone edit
  -- cannot change what KIND of row this is or who authored it).
  v_before := jsonb_build_object(
                'id', v_live.id, 'name', v_live.name, 'zone_kind', v_live.zone_kind,
                'source', v_live.source, 'location_id', v_live.location_id, 'status', v_live.status,
                'boundary_wkt', public.st_astext(v_live.boundary), 'created_at', v_live.created_at, 'revision', v_live.revision);
  begin
    update public.danger_zones
       set boundary    = v_boundary,
           name        = v_name,
           location_id = v_attach,
           updated_at  = now(),
           -- the concurrency token advances on every applied edit (0284 never bumped it, so the
           -- token was inert; a second edit off the same fork could have passed unnoticed)
           revision    = revision + 1
     where id = v_live.id
     returning jsonb_build_object(
                 'id', id, 'name', name, 'zone_kind', zone_kind, 'source', source,
                 'location_id', location_id, 'status', status,
                 'boundary_wkt', public.st_astext(boundary), 'created_at', created_at, 'revision', revision),
               id
       into v_after, v_id;

    v_result := jsonb_build_object('updated', true, 'id', v_id, 'name', v_name);

    -- (10) exactly ONE audit row — an UPDATE records BOTH snapshots (the 0244 columns, both used).
    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'zone_update', 'zone', v_id::text, v_result::text,
         v_before, v_after, p_payload->>'source_revision');
  exception when unique_violation then
    get stacked diagnostics v_conflict_table = TABLE_NAME;
    if v_conflict_table = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'zone_update', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    raise;   -- no other unique key is touchable by this UPDATE — surface the anomaly loudly.
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id,
           'command_type', 'zone_update', 'result', v_result);
end $$;

-- ── SELF-ASSERT ─────────────────────────────────────────────────────────────────────────────────────
do $$
declare v_def text; v_read text;
begin
  -- (1) the read exposes the token. Assert on the emitted KEY, not merely the word appearing in the
  -- body — the 0284 lesson: a reference that never runs proves nothing.
  v_read := pg_get_functiondef(to_regprocedure('public.get_danger_zones()'));
  if position('''revision'', z.revision' in v_read) = 0 then
    raise exception '0287: get_danger_zones does not emit revision';
  end if;
  if position('''provenance'', z.provenance' in v_read) = 0 then
    raise exception '0287: get_danger_zones does not emit provenance';
  end if;
  if position('ST_ExteriorRing' in v_read) = 0 then
    raise exception '0287: get_danger_zones lost its ring — the read contract must stay additive';
  end if;

  v_def := pg_get_functiondef(to_regprocedure('public.zone_update(text, jsonb)'));

  -- (2) revision is SELECTED into the record (0286's lesson: the guard is worthless if the column is
  -- not in the SELECT list — that is exactly how 42703 happened).
  if position('provenance, revision' in v_def) = 0 then
    raise exception '0287: zone_update does not select revision into v_live';
  end if;
  -- (3) it is COMPARED …
  if position('v_live.revision' in v_def) = 0 then
    raise exception '0287: zone_update does not compare v_live.revision';
  end if;
  -- (4) … and it ADVANCES on write, or the token is inert and two edits could both pass.
  if position('revision    = revision + 1' in v_def) = 0 then
    raise exception '0287: zone_update does not bump revision on write';
  end if;
  -- (5) the lossy geometry compare is GONE — not merely bypassed. If st_equals survives against the
  -- expected boundary, a second concurrency authority is still present.
  if position('st_equals(v_exp_boundary' in v_def) > 0 then
    raise exception '0287: the ST_Equals expected-boundary compare survives — one authority only';
  end if;
  -- (6) the seeded guard 0286 repaired is still intact (this migration must not regress it).
  if position('v_live.provenance' in v_def) = 0 then
    raise exception '0287: the seeded-provenance guard was lost';
  end if;
  -- (7) grants unchanged; anon never gains execute.
  if not has_function_privilege('authenticated', 'public.zone_update(text,jsonb)', 'execute')
     or has_function_privilege('anon', 'public.zone_update(text,jsonb)', 'execute') then
    raise exception '0287: zone_update grants moved';
  end if;
  if not has_function_privilege('anon', 'public.get_danger_zones()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_danger_zones()', 'execute') then
    raise exception '0287: get_danger_zones lost a client execute grant';
  end if;
  -- (8) the 0239 lockdown still holds.
  if position('pirate_zone' in v_def) > 0 then
    raise exception '0287: zone_update references a 0239-locked pirate_zone surface';
  end if;

  raise notice '0287 OK: revision is the ONE zone-edit concurrency authority; read exposes it';
end $$;

