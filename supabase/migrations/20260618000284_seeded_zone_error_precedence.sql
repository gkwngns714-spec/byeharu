-- Byeharu — SEEDED-ZONE ERROR PRECEDENCE (migration 0284). Eligibility is now decided BEFORE the
-- optimistic-concurrency compare. Behaviour changes for exactly one case: the error you get back.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE BUG, IN THE OWNER'S WORDS
-- "when i edit shape of zone, and try to publish, it says the live row changed since this draft was
--  forked - review the draft before retrying. what do i need to do"
--
-- Nothing. The draft was fine and the live row had not changed. The zone was SEEDED, and seeded zones
-- were not editable — but the command never said so, because it compared the fork-time snapshot FIRST
-- and returned stale_revision the moment the geometry compare drifted. The honest answer,
-- protected_zone, sat in the very next block and was never reached.
--
-- An owner told "the live row changed" goes looking for a concurrent edit that does not exist. A
-- misleading error is worse than a blunt one: it spends someone's afternoon.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE RULE
-- A stale revision only MATTERS if the operation is otherwise permitted. Reporting a conflict for an
-- action that is categorically disabled tells the caller to fix the wrong thing. So eligibility now
-- runs first, and the precedence in all three commands is:
--
--   1. authn                      not_authenticated
--   2. authz (is_owner)           not_authorized
--   3. request shape / id         invalid_request
--   4. idempotent replay          duplicate_request        <-- still ahead of everything below
--   5. locate + ROW LOCK          not_found
--   5b. ELIGIBILITY               protected_zone           <-- MOVED HERE
--   6. optimistic concurrency     stale_revision
--   7. operation validation       validation_failed
--   8. mutate + audit atomically
--
-- IDEMPOTENCY STAYS AHEAD OF BOTH. If a first call succeeded and the response was lost, the retry
-- must return the RECORDED result — not a fresh verdict from re-examining current state. Moving
-- eligibility above the revision compare must not disturb that, and it does not: the replay check is
-- untouched at step 4.
--
-- THE ROW LOCK STAYS AHEAD OF BOTH TOO, so eligibility and the revision compare read the same
-- committed state and cannot straddle a concurrent write.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT DOES NOT CHANGE
-- Which operations are permitted. Nothing here widens or narrows protection: the same zones are
-- protected before and after, under the same two flags from 0283. Only the ORDER of two checks moves,
-- so the only observable difference is WHICH typed error a rejected call receives — and only when
-- both would have fired.
--
-- HOW THESE WERE PRODUCED: each body is taken from 0283 and altered by MOVING one block. No line is
-- rewritten, so nothing else in ~200 lines of gating can drift. A test asserts the eligibility check
-- now precedes the stale_revision return in all three, and that the replay check still precedes both.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. preconditions ────────────────────────────────────────────────────────────────────────────
do $pre$
begin
  if not exists (select 1 from public.game_config where key = 'seeded_zone_edit_enabled') then
    raise exception 'ERROR PRECEDENCE 0284: seeded_zone_edit_enabled (0283) is missing';
  end if;
end $pre$;

-- ── zone_update: eligibility moved ahead of the concurrency compare ──
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
  select id, name, zone_kind, source, location_id, boundary, status, created_by, created_at
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

  -- (6) OPTIMISTIC CONCURRENCY — compare the locked live row against `expected` (the fork-time
  -- sourceSnapshot) over the THREE mutable fields, value-by-value. Value equality is the authority (the
  -- client fingerprint is NOT re-derived). Every drifted field is reported, then the command is rejected
  -- with NOTHING written. zone_kind is fixed 'pirate' (never a draft field) and is not compared.
  --   • name           — plain text compare (the 0255 idiom).
  --   • location_id     — null-safe compare vs expected.attach_location_id (the 0249/0255 territory idiom).
  --   • geometry        — the expected ring re-materialized with the SAME 0254 idioms and compared
  --                       SPATIALLY (ST_Equals — order/representation independent, robust to the
  --                       full-precision [x,y] ring get_danger_zones hands the client). A malformed or
  --                       unmaterializable expected geometry (never produced by projectFromLive of a live
  --                       row) is treated as drift: we reject rather than clobber.
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
  begin
    v_egeom := v_expected->'geometry';
    if jsonb_typeof(v_egeom) = 'object' and (v_egeom->>'kind') = 'circle' then
      v_exp_boundary := public.st_buffer(
        public.st_makepoint((v_egeom->'center'->>'x')::double precision,
                            (v_egeom->'center'->>'y')::double precision),
        (v_egeom->>'radius')::double precision, 32);
    elsif jsonb_typeof(v_egeom) = 'object' and (v_egeom->>'kind') = 'polygon'
          and jsonb_typeof(v_egeom->'vertices') = 'array'
          and jsonb_array_length(v_egeom->'vertices') >= 3 then
      v_epts := array[]::public.geometry[];
      for v_i in 0 .. jsonb_array_length(v_egeom->'vertices') - 1 loop
        v_epts := v_epts || public.st_makepoint(
          (v_egeom->'vertices'->v_i->>'x')::double precision,
          (v_egeom->'vertices'->v_i->>'y')::double precision);
      end loop;
      v_epts := v_epts || v_epts[1];   -- close the OPEN draft ring
      v_exp_boundary := public.st_makepolygon(public.st_makeline(v_epts));
    else
      v_exp_boundary := null;
    end if;
  exception when others then
    v_exp_boundary := null;   -- an unmaterializable expected geometry is drift, never a raw error
  end;
  if v_exp_boundary is null
     or not public.st_isvalid(v_exp_boundary)
     or not public.st_equals(v_exp_boundary, v_live.boundary) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'geometry',
      'message', 'The live zone''s geometry changed since this draft was forked.'));
  end if;
  if jsonb_array_length(v_details) > 0 then
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
                'boundary_wkt', public.st_astext(v_live.boundary), 'created_at', v_live.created_at);
  begin
    update public.danger_zones
       set boundary    = v_boundary,
           name        = v_name,
           location_id = v_attach,
           updated_at  = now()
     where id = v_live.id
     returning jsonb_build_object(
                 'id', id, 'name', name, 'zone_kind', zone_kind, 'source', source,
                 'location_id', location_id, 'status', status,
                 'boundary_wkt', public.st_astext(boundary), 'created_at', created_at),
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

-- ── zone_unpublish: eligibility moved ahead of the concurrency compare ──
create or replace function public.zone_unpublish(p_request_id text, p_payload jsonb default '{}'::jsonb)
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
  v_details   jsonb := '[]'::jsonb;
  v_live      record;        -- the LOCKED live row
  v_before    jsonb;
  v_after     jsonb;
  v_result    jsonb;
  v_prior     text;
  v_id        uuid;
  v_conflict_table text;
begin
  -- (1) authn — reject the anonymous caller with a typed code (no world touch). [0250:124-126]
  if v_uid is null then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authenticated');
  end if;

  -- (2) authz — THE ONE guard. Non-owner authenticated caller is rejected server-side. [0250:129-131]
  if not public.is_owner() then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authorized');
  end if;

  -- (3) request_id is the idempotency key — it must be present. [0250:134-136]
  if p_request_id is null or length(btrim(p_request_id)) = 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;

  -- (4a) idempotent replay: a prior row for this request_id ⇒ return its result, no second apply. [0250:139-144]
  select result into v_prior from public.world_editor_audit where request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'request_id', p_request_id,
             'command_type', 'zone_unpublish', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  -- (4b) structural addressing: a zone unpublish cannot even be located without a target_id (the
  -- zone's uuid) and an `expected` snapshot object — either missing/malformed, or a target_id that is
  -- not a uuid, is a malformed REQUEST (the 0243 invalid_request code), not a field-validation report.
  -- danger_zones has NO unique natural key (name is not unique, unlike sites/fields), so the PK uuid
  -- is the addressing key (the 0249 location_update variant, not the 0250 name variant).
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

  -- (5) LOCATE + ROW-LOCK the live target by PK. The lock holds until commit/rollback, so the
  -- compare-then-write below cannot race a concurrent editor.
  select id, name, zone_kind, source, location_id, status, created_by, created_at
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

  -- (5b) ELIGIBILITY (fail-closed on invalid state) — the zone exists and matches the draft, but may
  -- still be ineligible to unpublish:
  --   • source <> 'drawn'  ⇒ a seeded/system zone (the 3 'circle' zones and any future seed). These
  --     are NEVER unpublishable through the editor — protected_zone.
  --   • status <> 'active' ⇒ already unpublished (a fresh request on an inactive zone is a no-op we
  --     reject rather than silently re-apply; a genuine replay is already the idempotent success path
  --     above). already_inactive.
  if v_live.provenance = 'seeded'
     and not coalesce(public.cfg_bool('seeded_zone_lifecycle_enabled'), false) then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_unpublishable',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'protected_zone', 'field', 'source',
               'message', 'This is a seeded zone. Seeded-zone lifecycle changes are not enabled.')));
  end if;

  -- (6) OPTIMISTIC CONCURRENCY — re-project the LOCKED row onto the fields the zone read exposes
  -- (get_danger_zones returns id/name/source/location_id/ring) and compare value-by-value with
  -- `expected` (the fork-time sourceSnapshot). Value equality is the authority (the client fingerprint
  -- is NOT re-derived). Every drifted field is reported, then the command is rejected with NOTHING
  -- written. Geometry is intentionally NOT compared (it is not touched by an unpublish, and a float
  -- ring compare is fragile); name/source/location_id are the stable identity a stale unpublish
  -- decision would hinge on.
  if v_expected->>'name' is distinct from v_live.name then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'name',
      'message', 'The live zone''s name changed since this draft was forked.'));
  end if;
  if v_expected->>'source' is distinct from v_live.source then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'source',
      'message', 'The live zone''s source changed since this draft was forked.'));
  end if;
  if coalesce(v_expected->'location_id', 'null'::jsonb)
       is distinct from coalesce(to_jsonb(v_live.location_id), 'null'::jsonb) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'location_id',
      'message', 'The live zone''s attachment changed since this draft was forked.'));
  end if;
  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'stale_revision', 'details', v_details);
  end if;

  if v_live.status <> 'active' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_unpublishable',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'already_inactive', 'field', 'status',
               'message', 'This zone is already unpublished (status is not active).')));
  end if;

  -- (7) apply + audit in ONE sub-block: any unique_violation rolls BOTH back atomically. The status
  -- flip never touches a unique key (danger_zones has none beyond the PK, which is unchanged), so the
  -- ONLY reachable unique_violation is world_editor_audit.request_id (a concurrent duplicate raced
  -- us) ⇒ idempotent replay — disambiguated via the constraint's table exactly like the templates
  -- (anything else re-raises). NOTHING but status + updated_at is written: an unpublish keeps every
  -- other column bit-for-bit, so the row (geometry, name, attach, created_by) is fully preserved and
  -- a future republish restores it exactly. NO hard delete exists.
  v_before := jsonb_build_object(
                'id', v_live.id, 'name', v_live.name, 'zone_kind', v_live.zone_kind,
                'source', v_live.source, 'location_id', v_live.location_id,
                'status', v_live.status, 'created_by', v_live.created_by, 'created_at', v_live.created_at);
  begin
    update public.danger_zones
       set status = 'inactive', updated_at = now()
     where id = v_live.id
     returning jsonb_build_object(
                 'id', id, 'name', name, 'zone_kind', zone_kind, 'source', source,
                 'location_id', location_id, 'status', status, 'created_by', created_by,
                 'created_at', created_at),
               id
       into v_after, v_id;

    v_result := jsonb_build_object('unpublished', true, 'id', v_id, 'name', v_live.name, 'status', 'inactive');

    -- (8) exactly ONE audit row — an unpublish records BOTH snapshots (the 0244 columns, both used).
    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'zone_unpublish', 'zone', v_id::text, v_result::text,
         v_before, v_after, p_payload->>'source_revision');
  exception when unique_violation then
    get stacked diagnostics v_conflict_table = TABLE_NAME;
    if v_conflict_table = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'zone_unpublish', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    raise;   -- no other unique key is touchable by a status flip — surface the anomaly loudly.
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id,
           'command_type', 'zone_unpublish', 'result', v_result);
end $$;

-- ── zone_set_active: eligibility moved ahead of the concurrency compare ──
create or replace function public.zone_set_active(p_request_id text, p_payload jsonb default '{}'::jsonb)
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
  v_details   jsonb := '[]'::jsonb;
  v_live      record;        -- the LOCKED live row
  v_before    jsonb;
  v_after     jsonb;
  v_result    jsonb;
  v_prior     text;
  v_id        uuid;
  v_conflict_table text;
begin
  -- (1) authn — reject the anonymous caller with a typed code (no world touch). [0250:124-126]
  if v_uid is null then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authenticated');
  end if;

  -- (2) authz — THE ONE guard. Non-owner authenticated caller is rejected server-side. [0250:129-131]
  if not public.is_owner() then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authorized');
  end if;

  -- (3) request_id is the idempotency key — it must be present. [0250:134-136]
  if p_request_id is null or length(btrim(p_request_id)) = 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;

  -- (4a) idempotent replay: a prior row for this request_id ⇒ return its result, no second apply. This
  -- is CHECKED BEFORE the stale-revision compare so a retried apply always replays rather than tripping
  -- a now-stale snapshot. [0250:139-144]
  select result into v_prior from public.world_editor_audit where request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'request_id', p_request_id,
             'command_type', 'zone_set_active', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  -- (4b) structural addressing: a reactivate cannot even be located without a uuid target_id and an
  -- `expected` snapshot object — either missing/malformed, or a target_id that is not a uuid, is a
  -- malformed REQUEST (the 0243 invalid_request code), not a field-validation report. danger_zones has
  -- NO unique natural key, so the PK uuid is the addressing key (the 0255/0266 zone variant).
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

  -- (5) LOCATE + ROW-LOCK the live target by PK. The lock holds until commit/rollback, so the
  -- compare-then-write below cannot race a concurrent editor.
  select id, name, zone_kind, source, location_id, status, created_by, created_at
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

  -- (5b) SEEDED-ZONE PROTECTION (fail-closed) — only editor-created source='drawn' zones are toggleable.
  -- The seeded source='circle' zones (and any future seed) can NEVER be reactivated through the editor:
  -- a typed validation_failed {protected_zone} (the 0266 zone_update guard — no new top-level error code).
  if v_live.provenance = 'seeded'
     and not coalesce(public.cfg_bool('seeded_zone_lifecycle_enabled'), false) then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'validation_failed', 'details', jsonb_build_array(jsonb_build_object(
               'code', 'protected_zone', 'field', 'source',
               'message', 'This is a seeded zone. Seeded-zone lifecycle changes are not enabled.')));
  end if;

  -- (6) OPTIMISTIC CONCURRENCY — re-project the LOCKED row onto the fields the zone read exposes and
  -- compare value-by-value with `expected` (the fork-time sourceSnapshot: {name, source, location_id},
  -- the 0255 idiom). Value equality is the authority (the client fingerprint is NOT re-derived). Every
  -- drifted field is reported, then the command is rejected with NOTHING written. Geometry is
  -- intentionally NOT compared (a status flip never touches it, and a float ring compare is fragile).
  if v_expected->>'name' is distinct from v_live.name then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'name',
      'message', 'The live zone''s name changed since this draft was forked.'));
  end if;
  if v_expected->>'source' is distinct from v_live.source then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'source',
      'message', 'The live zone''s source changed since this draft was forked.'));
  end if;
  if coalesce(v_expected->'location_id', 'null'::jsonb)
       is distinct from coalesce(to_jsonb(v_live.location_id), 'null'::jsonb) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'location_id',
      'message', 'The live zone''s attachment changed since this draft was forked.'));
  end if;
  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'stale_revision', 'details', v_details);
  end if;

  -- (6c) ALREADY-ACTIVE (deterministic reactivate-only) — this command ONLY flips inactive→active. A zone
  -- that is already active is not re-activatable: a typed validation_failed {already_active}, NOTHING
  -- written. (A genuine request_id replay already returned above; only a NEW request on an active zone
  -- reaches here.) Deactivation is zone_unpublish's job, never this command's.
  if v_live.status <> 'inactive' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'validation_failed', 'details', jsonb_build_array(jsonb_build_object(
               'code', 'already_active', 'field', 'status',
               'message', 'This zone is already active — reactivate only applies to an inactive zone. Use unpublish to deactivate.')));
  end if;

  -- (7) apply + audit in ONE sub-block: any unique_violation rolls BOTH back atomically. The status flip
  -- never touches a unique key (danger_zones has none beyond the PK, which is unchanged), so the ONLY
  -- reachable unique_violation is world_editor_audit.request_id (a concurrent duplicate raced us) ⇒
  -- idempotent replay — disambiguated via the constraint's table exactly like the templates (anything
  -- else re-raises). NOTHING but status + updated_at is written: the flip keeps every other column
  -- bit-for-bit (id/zone_kind/geometry/source/location_id/created_by/created_at preserved). NO hard delete.
  v_before := jsonb_build_object(
                'id', v_live.id, 'name', v_live.name, 'zone_kind', v_live.zone_kind,
                'source', v_live.source, 'location_id', v_live.location_id,
                'status', v_live.status, 'created_by', v_live.created_by, 'created_at', v_live.created_at);
  begin
    update public.danger_zones
       set status = 'active', updated_at = now()
     where id = v_live.id
     returning jsonb_build_object(
                 'id', id, 'name', name, 'zone_kind', zone_kind, 'source', source,
                 'location_id', location_id, 'status', status, 'created_by', created_by,
                 'created_at', created_at),
               id
       into v_after, v_id;

    v_result := jsonb_build_object('set_active', true, 'id', v_id, 'name', v_live.name, 'status', 'active');

    -- (8) exactly ONE audit row — a reactivate records BOTH snapshots (the 0244 columns, both used).
    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'zone_set_active', 'zone', v_id::text, v_result::text,
         v_before, v_after, p_payload->>'source_revision');
  exception when unique_violation then
    get stacked diagnostics v_conflict_table = TABLE_NAME;
    if v_conflict_table = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'zone_set_active', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    raise;   -- no other unique key is touchable by a status flip — surface the anomaly loudly.
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id,
           'command_type', 'zone_set_active', 'result', v_result);
end $$;

-- ── SELF-ASSERT ─────────────────────────────────────────────────────────────────────────────────
do $prec$
declare
  v_fn  text;
  v_def text;
  v_elig int; v_stale int; v_replay int; v_lock int;
begin
  foreach v_fn in array array['public.zone_update(text, jsonb)',
                              'public.zone_unpublish(text, jsonb)',
                              'public.zone_set_active(text, jsonb)'] loop
    v_def := pg_get_functiondef(to_regprocedure(v_fn));
    if v_def is null then
      raise exception 'ERROR PRECEDENCE 0284 self-assert FAIL: % vanished', v_fn; end if;

    v_elig   := strpos(v_def, 'v_live.provenance = ''seeded''');
    v_stale  := strpos(v_def, '''stale_revision''');
    v_replay := strpos(v_def, 'from public.world_editor_audit where request_id');
    v_lock   := strpos(v_def, 'for update');

    if v_elig = 0 or v_stale = 0 or v_replay = 0 or v_lock = 0 then
      raise exception 'ERROR PRECEDENCE 0284 self-assert FAIL: % lost a required step', v_fn; end if;

    -- THE FIX: eligibility must now decide before the revision compare can answer
    if v_elig > v_stale then
      raise exception 'ERROR PRECEDENCE 0284 self-assert FAIL: % still reports stale_revision before protected_zone', v_fn;
    end if;
    -- …but idempotent replay must STILL come first, or a lost-response retry would be re-judged
    if v_replay > v_elig then
      raise exception 'ERROR PRECEDENCE 0284 self-assert FAIL: % now evaluates eligibility before the idempotent replay', v_fn;
    end if;
    -- …and the row lock must precede eligibility, so both checks read the same committed state
    if v_lock > v_elig then
      raise exception 'ERROR PRECEDENCE 0284 self-assert FAIL: % evaluates eligibility before locking the row', v_fn;
    end if;
    -- protection itself is unchanged: still provenance-based, still flag-gated
    if strpos(v_def, 'protected_zone') = 0 then
      raise exception 'ERROR PRECEDENCE 0284 self-assert FAIL: % lost protected_zone', v_fn; end if;
    if strpos(v_def, 'v_live.source <> ''drawn''') > 0 then
      raise exception 'ERROR PRECEDENCE 0284 self-assert FAIL: % regressed to source-based protection', v_fn; end if;
    -- and the house gate chain survived the re-creation
    if strpos(v_def, 'not_authenticated') = 0 or strpos(v_def, 'is_owner()') = 0
       or strpos(v_def, 'duplicate_request') = 0 then
      raise exception 'ERROR PRECEDENCE 0284 self-assert FAIL: % lost part of its gate chain', v_fn; end if;
  end loop;

  -- the flags are untouched by this slice
  if coalesce(public.cfg_bool('seeded_zone_edit_enabled'), true)
     or coalesce(public.cfg_bool('seeded_zone_lifecycle_enabled'), true) then
    raise exception 'ERROR PRECEDENCE 0284 self-assert FAIL: a seeded-zone flag was disturbed'; end if;

  raise notice 'ERROR PRECEDENCE 0284 self-assert ok: all three commands now decide ELIGIBILITY before the concurrency compare, so a seeded zone reports protected_zone instead of the misleading stale_revision that sent the owner looking for a concurrent edit that never happened; idempotent replay STILL precedes eligibility, so a lost-response retry returns its recorded result rather than a fresh verdict; the row lock still precedes both, so they read the same committed state; protection itself is unchanged (provenance-based, flag-gated, same zones) and both flags are still false';
end $prec$;
