-- Byeharu — WORLD EDITOR PUBLISHING SLICE: zone_update — the zone EDIT command, the last missing edge
-- of the publish domain matrix (zones were the only domain with create+unpublish but no UPDATE).
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT THIS IS: the exact twin of location_update (0249) crossed with the geometry materialization of
-- zone_create (0254). It UPDATEs ONE row in public.danger_zones (the row an owner EDIT draft was
-- forked from), re-materializing the draft's edited geometry onto that same row. It follows the 0249
-- update body shape step for step ((1) authn → typed 'not_authenticated'; (2) authz via THE ONE guard
-- public.is_owner() → typed 'not_authorized'; (3) request_id idempotency against THE ONE ledger
-- public.world_editor_audit; (4) exactly one audit row per applied command, with BOTH before_snapshot
-- AND after_snapshot; (5) a typed {ok,request_id,result|error} envelope; server-side re-validation
-- with 'validation_failed' + details[]; optimistic concurrency: lock the live row FOR UPDATE and
-- compare the caller's `expected` fork-time snapshot value-by-value → typed 'stale_revision') with the
-- zone-specific differences:
--
--   • TARGETING BY UUID: danger_zones exposes a REAL uuid through the read (get_danger_zones →
--     DangerZoneLite.id; the zone draft descriptor's liveId = z.id). So p_payload.target_id is the
--     zone's uuid; the live row is located AND ROW-LOCKED by primary key (select … for update). A
--     malformed (non-uuid) target_id is a malformed REQUEST → 'invalid_request'; a vanished target is
--     a typed 'not_found' with details[{code:'source_missing'}] (the 0249 idiom, not a name key —
--     danger_zones has NO unique natural key, exactly like the 0255 unpublish twin).
--   • GEOMETRY IS THE MUTABLE PAYLOAD: p_payload.fields.geometry is the draft union
--       {kind:'circle',  center:{x,y}, radius}          — an editor may re-seed an edit as a circle
--       {kind:'polygon', vertices:[{x,y}, ... 3..64]}   — an OPEN owner-drawn ring
--     materialized server-side with the 0254 idioms VERBATIM (circle → ST_Buffer(point, radius, 32);
--     polygon → close the ring + ST_MakePolygon(ST_MakeLine(...))) and gated by the AUTHORITATIVE
--     ST_IsValid(boundary) AND ST_Area(boundary) > 0 check → typed validation_failed {invalid_geometry}
--     on failure (the client self-intersection scan is advisory; PostGIS is the ONE geometry authority).
--   • OPTIMISTIC CONCURRENCY OVER name / attach / geometry: the `expected` snapshot is the zone draft's
--     fork-time sourceSnapshot (zoneDraftModel.projectFromLive → {name, zone_kind, attach_location_id,
--     geometry:{kind:'polygon', open ring}}). We compare the three MUTABLE fields value-by-value against
--     the LOCKED live row — name (text), attach_location_id (null-safe vs live.location_id, the 0255
--     idiom), and geometry (the expected ring re-materialized with the SAME 0254 idioms and compared
--     spatially via ST_Equals against the live boundary — robust to vertex order/representation, unlike
--     a fragile float-ring compare). Any drift → 'stale_revision' with details[{code:'source_changed',
--     field:…}] and NOTHING is written. zone_kind is fixed 'pirate' (not a mutable field) and is neither
--     compared nor written.
--   • SEEDED-ZONE PROTECTION: the 3 seeded source='circle' zones (and any future seed) can NEVER be
--     edited through the editor — only editor-created source='drawn' zones (what 0254 zone_create writes)
--     are editable. A source<>'drawn' target is a typed validation_failed {code:'protected_zone'} (the
--     exact guard 0255 zone_unpublish enforces with protected_zone; surfaced through the SAME details
--     pipeline, no new top-level error code). The danger_zones coherence CHECK (source<>'circle' or
--     location_id not null) stays trivially satisfied: 'drawn' rows may be standalone (attach → null).
--   • attach_location_id: null (standalone — warning-only) OR an EXISTING ACTIVE pirate_hunt/pirate_den
--     location (the EXACT 0254/0233 rule), else a typed validation_failed {code:'invalid_attach'} — a
--     dangling FK never surfaces raw.
--   • NO conflict code: danger_zones.name has NO unique constraint (like zone_create) — the only
--     unique_violation reachable from the apply sub-block is world_editor_audit.request_id (a raced
--     duplicate → idempotent replay; the sub-block rollback undoes this call's UPDATE — no torn write).
--
-- NOT pirate_zone_*: the 0233 prototype authoring RPCs were LOCKED DOWN by 0239 (service_role only) and
-- are NOT reused, re-created, re-granted, or touched here — this command is a NEW owner-gated surface
-- through the 0243 spine, and the self-assert below RE-ASSERTS the 0239 lockdown is intact and that the
-- function body references NEITHER of them.
--
-- DEPLOY POSTURE: UNDEPLOYED — deploy is a human gate. Fail-closed by design: even deployed, the
-- capability is inert until an owner is seeded into app_owners (is_owner() is false for everyone on an
-- unseeded DB). READ-SIDE dark-coupling (documented, unchanged): danger_zones SELECT/RLS and
-- get_danger_zones() are gated on pirate_intercept_enabled (0233) — an edited zone is invisible to every
-- client read while that flag is dark. No client grant is widened anywhere: the danger_zones write
-- happens INSIDE this SECURITY DEFINER body only, and this slice re-establishes the client write-path
-- revoke (idempotent) then asserts it.
--
-- NO-SPAGHETTI: no second owner check (is_owner() only), no second audit ledger, no second idempotency
-- key, no second geometry engine (PostGIS is the ONE authority; the client scan is advisory), no
-- server-side fingerprint re-derivation (value equality is the one staleness authority), no reuse of the
-- locked pirate_zone_create/delete, no new read RPC (get_danger_zones stays the one zone read).
-- zone_create / zone_unpublish / get_danger_zones / world_editor_ping and the prior publish commands are
-- left byte-identical; the 0244 audit snapshot columns are NOT re-added (the dependency gate asserts them).
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. dependency gate — abort loudly if the surfaces this slice builds on are missing ────────────
do $pubdep$
begin
  if to_regclass('public.danger_zones') is null then
    raise exception 'PUBLISH-ZONE-UPDATE: public.danger_zones (0233) is missing — nothing to update';
  end if;
  if to_regclass('public.locations') is null then
    raise exception 'PUBLISH-ZONE-UPDATE: public.locations (0002) is missing — the attach target table must exist';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'PUBLISH-ZONE-UPDATE: public.world_editor_audit (0243) is missing — the audit/idempotency spine must exist first';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'PUBLISH-ZONE-UPDATE: public.is_owner() (0243) is missing — THE ONE owner guard must exist first';
  end if;
  if to_regprocedure('public.zone_create(text, jsonb)') is null then
    raise exception 'PUBLISH-ZONE-UPDATE: public.zone_create(text,jsonb) (0254) is missing — the geometry-materialization twin this extends must exist';
  end if;
  if to_regprocedure('public.location_update(text, jsonb)') is null then
    raise exception 'PUBLISH-ZONE-UPDATE: public.location_update(text,jsonb) (0249) is missing — the UPDATE template this reproduces must exist';
  end if;
  if to_regprocedure('public.st_makepolygon(public.geometry)') is null
     or to_regprocedure('public.st_buffer(public.geometry, double precision, integer)') is null
     or to_regprocedure('public.st_equals(public.geometry, public.geometry)') is null then
    raise exception 'PUBLISH-ZONE-UPDATE: a PostGIS materialization/compare function (0233 extension install) is missing';
  end if;
  -- the 0244 audit snapshot columns must already exist (this slice re-adds NOTHING; an update USES both).
  if not exists (select 1 from pg_attribute
                 where attrelid = 'public.world_editor_audit'::regclass
                   and attname = 'before_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'after_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'source_revision' and not attisdropped) then
    raise exception 'PUBLISH-ZONE-UPDATE: a 0244 audit snapshot column (before_snapshot/after_snapshot/source_revision) is missing — the snapshot columns must exist first';
  end if;
  if to_regprocedure('public.get_danger_zones()') is null then
    raise exception 'PUBLISH-ZONE-UPDATE: public.get_danger_zones() is missing — the read this slice must NOT break must exist to be asserted';
  end if;
  if to_regprocedure('public.pirate_zone_create(text, jsonb, uuid)') is null
     or to_regprocedure('public.pirate_zone_delete(uuid)') is null then
    raise exception 'PUBLISH-ZONE-UPDATE: a 0239 pirate_zone write RPC is missing — the lockdown surface must exist to be re-asserted';
  end if;
end $pubdep$;

-- ── 1. zone_update — the zone EDIT command (0249 update template + 0254 zone geometry) ─────────────
-- TYPED RESULT/ERROR CONTRACT (the 0249 vocabulary MINUS 'conflict' — danger_zones has no unique key):
--   success : {ok:true,  request_id, command_type:'zone_update', result:{updated:true,id,name}}
--   replay  : {ok:true,  request_id, command_type:'zone_update', replayed:true, code:'duplicate_request', result:<prior jsonb>}
--   failure : {ok:false, request_id, error:<code> [, details:[{code,field,message}...]]}  where code ∈
--             { 'not_authenticated', 'not_authorized', 'invalid_request'   -- the 0243 vocabulary
--             , 'not_found'          -- target_id names no live zone (details: source_missing)
--             , 'stale_revision'     -- the locked live zone drifted from `expected` (details: source_changed per field)
--             , 'validation_failed'  -- the mutable payload failed server re-validation; details carry the
--                                    -- zoneValidation vocabulary (name_required/name_too_long/
--                                    -- radius_not_positive/polygon_too_few_vertices/polygon_too_many_vertices/
--                                    -- coord_out_of_bounds/…) PLUS
--                                    --   {code:'protected_zone'}   — a seeded source<>'drawn' zone is not editable
--                                    --   {code:'invalid_attach'}   — attach_location_id names no active hostile site
--                                    --   {code:'invalid_geometry'} — the MATERIALIZED boundary failed the
--                                    --     authoritative ST_IsValid/ST_Area gate
--             }
-- p_payload = { target_id:       <the zone's uuid id — danger_zones has no unique natural key>,
--               expected:        <the draft's sourceSnapshot: {name, zone_kind, attach_location_id, geometry}>,
--               fields:          <the new values: name, attach_location_id, geometry (circle|open polygon)>,
--               source_revision: <optional client draft fingerprint — audit trail only> }
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

  -- (6b) SEEDED-ZONE PROTECTION — only editor-created source='drawn' zones are editable. The seeded
  -- source='circle' zones (and any future seed) are NEVER editable through the editor: a typed
  -- validation_failed {protected_zone} (the 0255 zone_unpublish protected_zone guard, surfaced through
  -- the SAME details pipeline — no new top-level error code). Fail-closed on an ineligible target.
  if v_live.source <> 'drawn' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'validation_failed', 'details', jsonb_build_array(jsonb_build_object(
               'code', 'protected_zone', 'field', 'source',
               'message', 'Only editor-created (source=''drawn'') zones can be edited; this is a seeded zone.')));
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

comment on function public.zone_update(text, jsonb) is
  'WORLD EDITOR PUBLISH SLICE (0266): the zone EDIT command and the last missing edge of the publish '
  'domain matrix — re-materializes ONE owner zone draft''s edited geometry (circle {center,radius} | open '
  'polygon ring) onto the SAME live public.danger_zones row, the twin of location_update (0249) crossed '
  'with zone_create''s (0254) geometry materialization, through the 0243 spine. Authn → is_owner() authz '
  '→ request_id idempotency → one audit row (BOTH before/after snapshots) → typed envelope; locates + '
  'ROW-LOCKS the target by uuid PK (danger_zones has no unique natural key; not_found/source_missing when '
  'gone), rejects fork-time drift over name/attach/geometry with stale_revision/source_changed (geometry '
  'compared SPATIALLY via ST_Equals against the re-materialized expected ring), rejects a seeded '
  'source<>''drawn'' target with a typed validation_failed {protected_zone} (the 0255 guard), re-validates '
  'name/attach/geometry server-side (validation_failed + details; invalid_attach / the authoritative '
  'ST_IsValid+area {invalid_geometry}), and applies ONLY boundary+name+location_id+updated_at (source/'
  'zone_kind/created_by preserved). NO conflict code (danger_zones.name has no unique constraint). NOT '
  'the locked pirate_zone_* (0239). Execute granted to authenticated (the guard enforces owner IN-BODY); '
  'NEVER to anon/public. The danger_zones write happens only inside this SECURITY DEFINER body — no '
  'client grant. Reads stay dark-coupled to pirate_intercept_enabled (0233).';

-- ── 2. ACL — authenticated may CALL (guard is in-body); anon/public may not. No table grant widened.
revoke all on function public.zone_update(text, jsonb) from public;
grant execute on function public.zone_update(text, jsonb) to authenticated;  -- guard is in-body; NEVER anon

-- danger_zones is THIS command's write target: ESTABLISH the client write-path lockdown here rather than
-- assume a prior migration left it revoked (the 0254 production-drift lesson — a Supabase project-default
-- GRANT ALL was live in prod until 0254 revoked it). Revoking a privilege a role does not hold is a
-- silent no-op, so this is idempotent and keeps the fresh-chain apply-proof green. SELECT is preserved —
-- the flag-gated zone read depends on it, and self-assert (d) verifies SELECT survives.
revoke insert, update, delete on table public.danger_zones from anon, authenticated;

-- ── 3. self-assert (deploy-time; any raise aborts the txn — nothing half-applies) ─────────────────
do $pubassert$
begin
  -- (a) the 0243 spine this command stands on exists.
  if to_regclass('public.app_owners') is null then
    raise exception 'PUBLISH-ZONE-UPDATE self-assert FAIL: app_owners missing';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'PUBLISH-ZONE-UPDATE self-assert FAIL: is_owner() missing';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'PUBLISH-ZONE-UPDATE self-assert FAIL: world_editor_audit missing';
  end if;

  -- (b) the 0244 audit snapshot columns are present (an UPDATE writes BOTH).
  if not exists (select 1 from pg_attribute
                 where attrelid = 'public.world_editor_audit'::regclass
                   and attname = 'before_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'after_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'source_revision' and not attisdropped) then
    raise exception 'PUBLISH-ZONE-UPDATE self-assert FAIL: an audit snapshot column (before_snapshot/after_snapshot/source_revision) is missing';
  end if;

  -- (c) the command exists, is SECURITY DEFINER, has search_path='', and its ACL is authenticated-only.
  if to_regprocedure('public.zone_update(text, jsonb)') is null then
    raise exception 'PUBLISH-ZONE-UPDATE self-assert FAIL: zone_update(text,jsonb) missing';
  end if;
  if not exists (select 1 from pg_proc
                 where oid = 'public.zone_update(text,jsonb)'::regprocedure and prosecdef) then
    raise exception 'PUBLISH-ZONE-UPDATE self-assert FAIL: zone_update is not SECURITY DEFINER';
  end if;
  if not exists (select 1 from pg_proc
                 where oid = 'public.zone_update(text,jsonb)'::regprocedure
                   and proconfig @> array['search_path=']) then
    raise exception 'PUBLISH-ZONE-UPDATE self-assert FAIL: zone_update does not pin search_path='''' — a search_path hijack would be possible';
  end if;
  if not has_function_privilege('authenticated', 'public.zone_update(text,jsonb)', 'execute') then
    raise exception 'PUBLISH-ZONE-UPDATE self-assert FAIL: authenticated cannot execute zone_update — the in-body guard would be unreachable';
  end if;
  if has_function_privilege('anon', 'public.zone_update(text,jsonb)', 'execute') then
    raise exception 'PUBLISH-ZONE-UPDATE self-assert FAIL: anon CAN execute zone_update — must be authenticated-only';
  end if;

  -- (c2) the function body writes ONLY danger_zones and NEVER touches the 0239-locked pirate_zone_*
  -- surface (a cheap, robust source-text guard — the update target must be danger_zones alone).
  if position('pirate_zone' in pg_get_functiondef('public.zone_update(text,jsonb)'::regprocedure)) > 0 then
    raise exception 'PUBLISH-ZONE-UPDATE self-assert FAIL: zone_update body references pirate_zone — it must not touch the 0239-locked surface';
  end if;
  if position('danger_zones' in pg_get_functiondef('public.zone_update(text,jsonb)'::regprocedure)) = 0 then
    raise exception 'PUBLISH-ZONE-UPDATE self-assert FAIL: zone_update body does not reference danger_zones — the update target is wrong';
  end if;

  -- (c3) the 0254 create twin + 0255 unpublish twin are intact and still authenticated-only (untouched).
  if not has_function_privilege('authenticated', 'public.zone_create(text,jsonb)', 'execute')
     or has_function_privilege('anon', 'public.zone_create(text,jsonb)', 'execute') then
    raise exception 'PUBLISH-ZONE-UPDATE self-assert FAIL: the zone_create twin ACL was disturbed (must stay authenticated-only)';
  end if;
  if not has_function_privilege('authenticated', 'public.zone_unpublish(text,jsonb)', 'execute')
     or has_function_privilege('anon', 'public.zone_unpublish(text,jsonb)', 'execute') then
    raise exception 'PUBLISH-ZONE-UPDATE self-assert FAIL: the zone_unpublish twin ACL was disturbed (must stay authenticated-only)';
  end if;

  -- (d) NO client-role write grant on danger_zones — the only write path is the SECURITY DEFINER command
  -- surface. SELECT itself must SURVIVE: the flag-gated zone read (get_danger_zones + RLS) depends on it.
  if has_table_privilege('authenticated', 'public.danger_zones', 'INSERT')
     or has_table_privilege('authenticated', 'public.danger_zones', 'UPDATE')
     or has_table_privilege('authenticated', 'public.danger_zones', 'DELETE')
     or has_table_privilege('anon', 'public.danger_zones', 'INSERT')
     or has_table_privilege('anon', 'public.danger_zones', 'UPDATE')
     or has_table_privilege('anon', 'public.danger_zones', 'DELETE') then
    raise exception 'PUBLISH-ZONE-UPDATE self-assert FAIL: a client role holds a write grant on danger_zones — the only write path must be the SECURITY DEFINER command';
  end if;
  if not has_table_privilege('anon', 'public.danger_zones', 'SELECT')
     or not has_table_privilege('authenticated', 'public.danger_zones', 'SELECT') then
    raise exception 'PUBLISH-ZONE-UPDATE self-assert FAIL: a client role LOST SELECT on danger_zones — the flag-gated zone read would break; this slice must narrow writes only';
  end if;

  -- (e) the zone read is intact: get_danger_zones still exists and clients can still call it.
  if to_regprocedure('public.get_danger_zones()') is null then
    raise exception 'PUBLISH-ZONE-UPDATE self-assert FAIL: get_danger_zones() vanished — the zone read is broken';
  end if;
  if not has_function_privilege('anon', 'public.get_danger_zones()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_danger_zones()', 'execute') then
    raise exception 'PUBLISH-ZONE-UPDATE self-assert FAIL: a client role lost EXECUTE on get_danger_zones() — the zone read is broken';
  end if;

  -- (f) the 0239 pirate-zone lockdown is STILL intact (no client execute; service_role keeps its grant).
  if has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_zone_delete(uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'PUBLISH-ZONE-UPDATE self-assert FAIL: a client role regained EXECUTE on a pirate_zone write RPC — the 0239 lockdown was disturbed';
  end if;
  if not has_function_privilege('service_role', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or not has_function_privilege('service_role', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'PUBLISH-ZONE-UPDATE self-assert FAIL: service_role LOST execute on a pirate_zone RPC — the 0239 owner-tooling path was disturbed';
  end if;

  raise notice 'PUBLISH-ZONE-UPDATE self-assert ok: 0243 spine + snapshot columns present; zone_update SECURITY DEFINER + search_path='''' + authenticated-only; body writes danger_zones only (no pirate_zone_*); create/unpublish twins intact; no client write grant on danger_zones (SELECT intact); get_danger_zones intact; 0239 lockdown intact (service_role kept)';
end $pubassert$;
