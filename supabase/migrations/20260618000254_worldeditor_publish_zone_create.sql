-- Byeharu — WORLD EDITOR PUBLISHING: zone_create — the 4th/FINAL publish DOMAIN: an owner-gated
-- live-world-CREATE command for danger-zone GEOMETRY through the 0243 contract.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT THIS IS: the zone twin of location_create (0252) / exploration_site_create (0244) — it
-- MATERIALIZES an owner zone draft's seed geometry (circle | polygon, the client's ZoneGeometry
-- union) into ONE public.danger_zones row. It reproduces the 0244/0252 create-command template step
-- for step ((1) authn → typed 'not_authenticated'; (2) authz via THE ONE guard public.is_owner() →
-- typed 'not_authorized'; (3) request_id idempotency against THE ONE ledger
-- public.world_editor_audit; (4) exactly one audit row per applied command, with after_snapshot
-- only (before_snapshot is null on a create); (5) a typed {ok,request_id,result|error} envelope;
-- server-side re-validation with 'validation_failed' + details[]) with the zone-specific deltas:
--
--   • GEOMETRY IS THE PAYLOAD: p_payload.fields.geometry is the draft union
--       {kind:'circle',  center:{x,y}, radius}          — CREATE-only convenience seed
--       {kind:'polygon', vertices:[{x,y}, ... 3..64]}   — an OPEN owner-drawn ring
--     materialized server-side with the 0233 idioms VERBATIM: circle → ST_Buffer(point, radius, 32)
--     (the seed sweep's idiom, 0233:217); polygon → close the ring (append vertex 1) +
--     ST_MakePolygon(ST_MakeLine(...)) (pirate_zone_create's idiom, 0233:1449-1451). After
--     materialization the AUTHORITATIVE geometry gate runs: ST_IsValid(boundary) AND
--     ST_Area(boundary) > 0, else a typed validation_failed {code:'invalid_geometry'} — the
--     client's self-intersection scan (zoneGeometryMath) is ADVISORY; owner-drawn rings can
--     self-intersect and PostGIS is the one authority on what encloses an area.
--   • source='drawn' ALWAYS: this command publishes owner-AUTHORED geometry. 'circle' rows are the
--     0233 auto-seed's territory mirrors — a published circle draft is still an authored shape
--     (the draft model's own law: "a draft is by definition not a seeded 'circle' row").
--   • attach_location_id: null (standalone — the documented warning-only stub, 0233 header) OR an
--     EXISTING ACTIVE pirate_hunt/pirate_den location (the EXACT 0233:1456-1462 rule), else a typed
--     validation_failed {code:'invalid_attach'} — a dangling FK never surfaces raw. The danger_zones
--     coherence CHECK (source<>'circle' or location_id not null) is trivially satisfied: 'drawn'
--     rows may be standalone.
--   • NO conflict code: danger_zones.name has NO unique constraint (zoneValidation's duplicate-name
--     rule is a WARNING for exactly this reason) — the only unique_violation reachable from the
--     apply sub-block is world_editor_audit.request_id (a raced duplicate → idempotent replay; the
--     sub-block rollback undoes this call's zone insert — no orphan row).
--
-- NOT pirate_zone_create: the 0233 prototype authoring RPC was LOCKED DOWN by 0239 (service_role
-- only) and is NOT reused, re-created, re-granted, or touched here — this command is a NEW,
-- owner-gated (is_owner) surface through the 0243 spine, and the self-assert below RE-ASSERTS the
-- 0239 lockdown is intact.
--
-- DEPLOY POSTURE: UNDEPLOYED — deploy is a human gate. Fail-closed by design: even deployed, the
-- capability is inert until an owner is seeded into app_owners (is_owner() is false for everyone on
-- an unseeded DB). READ-SIDE dark-coupling (documented, unchanged): danger_zones SELECT/RLS and
-- get_danger_zones() are gated on pirate_intercept_enabled (0233) — a zone published while that
-- flag is dark EXISTS but is invisible to every client read until the flag is lit. No client grant
-- is widened anywhere: the danger_zones write happens INSIDE this SECURITY DEFINER body only.
--
-- NO-SPAGHETTI: no second owner check (is_owner() only), no second audit ledger, no second
-- idempotency key, no second geometry engine (PostGIS is the ONE authority; the client scan is
-- advisory), no reuse of the locked pirate_zone_create/delete, no new read RPC (get_danger_zones
-- stays the one zone read). world_editor_ping and the seven prior publish commands are left
-- byte-identical.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. dependency gate — abort loudly if the surfaces this slice builds on are missing ────────────
do $pubdep$
begin
  if to_regclass('public.danger_zones') is null then
    raise exception 'PUBLISH-ZONE-CREATE: public.danger_zones (0233) is missing — nothing to publish into';
  end if;
  if to_regclass('public.locations') is null then
    raise exception 'PUBLISH-ZONE-CREATE: public.locations (0002) is missing — the attach target table must exist';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'PUBLISH-ZONE-CREATE: public.world_editor_audit (0243) is missing — the audit/idempotency spine must exist first';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'PUBLISH-ZONE-CREATE: public.is_owner() (0243) is missing — THE ONE owner guard must exist first';
  end if;
  if to_regprocedure('public.location_create(text, jsonb)') is null then
    raise exception 'PUBLISH-ZONE-CREATE: public.location_create (0252) is missing — the CREATE template this reproduces must exist';
  end if;
  if to_regprocedure('public.st_makepolygon(public.geometry)') is null
     or to_regprocedure('public.st_buffer(public.geometry, double precision, integer)') is null then
    raise exception 'PUBLISH-ZONE-CREATE: a PostGIS materialization function (0233 extension install) is missing';
  end if;
  -- the 0244 audit snapshot columns must already exist (this slice re-adds NOTHING; a create USES after_snapshot).
  if not exists (select 1 from pg_attribute
                 where attrelid = 'public.world_editor_audit'::regclass
                   and attname = 'after_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'source_revision' and not attisdropped) then
    raise exception 'PUBLISH-ZONE-CREATE: a 0244 audit snapshot column (after_snapshot/source_revision) is missing — the snapshot columns must exist first';
  end if;
  if to_regprocedure('public.get_danger_zones()') is null then
    raise exception 'PUBLISH-ZONE-CREATE: public.get_danger_zones() is missing — the read this slice must NOT break must exist to be asserted';
  end if;
  if to_regprocedure('public.pirate_zone_create(text, jsonb, uuid)') is null
     or to_regprocedure('public.pirate_zone_delete(uuid)') is null then
    raise exception 'PUBLISH-ZONE-CREATE: a 0239 pirate_zone write RPC is missing — the lockdown surface must exist to be re-asserted';
  end if;
end $pubdep$;

-- ── 1. zone_create — the 4th publish DOMAIN's CREATE command (0244/0252 template + zone geometry) ──
-- TYPED RESULT/ERROR CONTRACT (the 0244 vocabulary, minus 'conflict' — no unique natural key):
--   success : {ok:true,  request_id, command_type, result:{created:true,id,name}}
--   replay  : {ok:true,  request_id, command_type, replayed:true, code:'duplicate_request', result:<prior jsonb>}
--   failure : {ok:false, request_id, error:<code> [, details:[{code,field,message}...]]}  where code ∈
--             { 'not_authenticated', 'not_authorized', 'invalid_request'   -- the 0243 vocabulary
--             , 'validation_failed'  -- the payload failed server re-validation; details carry the
--                                    -- zoneValidation vocabulary (name_required/coord_out_of_bounds/
--                                    -- radius_not_positive/polygon_too_few_vertices/
--                                    -- polygon_too_many_vertices/...) PLUS
--                                    --   {code:'invalid_attach'}   — attach_location_id names no
--                                    --     existing ACTIVE pirate_hunt/pirate_den location
--                                    --   {code:'invalid_geometry'} — the MATERIALIZED boundary
--                                    --     failed the authoritative ST_IsValid/ST_Area gate
--             }
-- p_payload = { fields: { name, zone_kind ('pirate'), attach_location_id (uuid|null),
--                         geometry: {kind:'circle', center:{x,y}, radius}
--                                 | {kind:'polygon', vertices:[{x,y},...]} },
--               source_revision:<optional client draft fingerprint — audit trail only> }
create or replace function public.zone_create(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_fields    jsonb;
  v_details   jsonb := '[]'::jsonb;
  v_name      text;
  v_kind      text;
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
  v_boundary  public.geometry;
  v_after     jsonb;
  v_result    jsonb;
  v_prior     text;
  v_id        uuid;
  v_conflict_table text;
  c_lo constant double precision := -10000;  -- the ONE navigable-square bound (0233/0219 idiom)
  c_hi constant double precision :=  10000;
begin
  -- (1) authn — reject the anonymous caller with a typed code (no world touch). [0244:95-98]
  if v_uid is null then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authenticated');
  end if;

  -- (2) authz — THE ONE guard. Non-owner authenticated caller is rejected server-side. [0244:100-103]
  if not public.is_owner() then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authorized');
  end if;

  -- (3) request_id is the idempotency key — it must be present. [0244:105-108]
  if p_request_id is null or length(btrim(p_request_id)) = 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;

  -- (4) idempotent replay: a prior row for this request_id ⇒ return its result, no second apply.
  select result into v_prior from public.world_editor_audit where request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'request_id', p_request_id,
             'command_type', 'zone_create', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  -- (5) SERVER-SIDE re-validation of the authoritative subset (p_payload->'fields') — the SAME
  -- rules and error codes as the advisory client mirror (zoneValidation.ts), PLUS the attach rule
  -- (the 0233:1456-1462 vocabulary). The client is NEVER trusted; every issue is collected so the
  -- full report renders at once. jsonb 'number' is finite by construction (JSON has no NaN/Inf).
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

    -- zone_kind — 'pirate' is the one zone kind this runtime has (the danger_zones CHECK).
    v_kind := v_fields->>'zone_kind';
    if v_kind is null or v_kind <> 'pirate' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_zone_kind', 'field', 'zone_kind',
        'message', 'Zone kind ''' || coalesce(v_kind, '(missing)') || ''' is not allowed — must be ''pirate''.'));
    end if;

    -- attach_location_id — null/absent = standalone (a REAL authored value: warning-only zone, the
    -- 0233 stub). Otherwise it must be a uuid naming an EXISTING ACTIVE pirate_hunt/pirate_den
    -- location (the EXACT 0233:1456-1462 rule). All failure shapes are ONE typed code:
    -- 'invalid_attach' — a dangling reference never surfaces as a raw foreign_key_violation.
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

    -- geometry — the draft union. Structural badness is 'invalid_payload'; value badness mirrors
    -- the zoneValidation codes (coord_out_of_bounds / radius_not_positive / polygon_too_few_vertices
    -- / polygon_too_many_vertices).
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

  -- (6) MATERIALIZE the boundary with the 0233 idioms VERBATIM:
  --   circle  → ST_Buffer(point, radius, 32)                      [the 0233:217 seed idiom]
  --   polygon → close the ring + ST_MakePolygon(ST_MakeLine(...)) [the 0233:1449-1451 draw idiom]
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

  -- THE AUTHORITATIVE GEOMETRY GATE: owner-drawn rings can self-intersect; the client scan is
  -- advisory. PostGIS decides — an invalid or zero-area boundary is a typed rejection, never a row.
  if v_boundary is null or not public.st_isvalid(v_boundary) or not (public.st_area(v_boundary) > 0) then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'validation_failed', 'details', jsonb_build_array(jsonb_build_object(
               'code', 'invalid_geometry', 'field', 'geometry',
               'message', 'The materialized boundary is not a valid, positive-area polygon — untangle the ring.')));
  end if;

  -- (7) apply + audit in ONE sub-block: any unique_violation rolls BOTH back atomically.
  -- danger_zones has NO unique natural key, so the only reachable unique_violation is
  -- world_editor_audit.request_id — a concurrent duplicate raced us ⇒ idempotent replay (this
  -- call's zone insert is undone by the sub-block rollback — no orphan row). source='drawn' ALWAYS
  -- (owner-authored geometry — see header); status='active' (published means live);
  -- created_by=the owner (the danger_zones FK→auth.users).
  begin
    insert into public.danger_zones (name, zone_kind, source, location_id, boundary, status, created_by)
      values (v_name, 'pirate', 'drawn', v_attach, v_boundary, 'active', v_uid)
      returning jsonb_build_object(
                  'id', id, 'name', name, 'zone_kind', zone_kind, 'source', source,
                  'location_id', location_id, 'status', status,
                  'boundary_wkt', public.st_astext(boundary), 'created_at', created_at),
                id
        into v_after, v_id;

    v_result := jsonb_build_object('created', true, 'id', v_id, 'name', v_name);

    -- (8) exactly ONE audit row — a CREATE records after_snapshot only (before is null by nature).
    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'zone_create', 'zone', v_id::text, v_result::text,
         null, v_after, p_payload->>'source_revision');
  exception when unique_violation then
    get stacked diagnostics v_conflict_table = TABLE_NAME;
    if v_conflict_table = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'zone_create', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    -- no other unique constraint exists on this write path — never swallow an unknown violation.
    raise;
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id,
           'command_type', 'zone_create', 'result', v_result);
end $$;

comment on function public.zone_create(text, jsonb) is
  'WORLD EDITOR PUBLISH SLICE (0254): the 4th/final publish domain — materializes ONE owner zone '
  'draft (circle {center,radius} | open polygon ring) into a live public.danger_zones row, following '
  'the 0244/0252 create template through the 0243 spine. Authn → is_owner() authz → request_id '
  'idempotency → one audit row (after_snapshot only) → typed envelope. Geometry is materialized with '
  'the 0233 idioms (ST_Buffer circle / ST_MakePolygon+ST_MakeLine closed ring) and gated by the '
  'AUTHORITATIVE ST_IsValid + ST_Area>0 check (typed validation_failed {invalid_geometry}); '
  'attach_location_id must be null or an existing ACTIVE pirate_hunt/pirate_den location (typed '
  '{invalid_attach}, the 0233 attach rule — never a raw FK violation). source=''drawn'' always; NO '
  'conflict code (danger_zones.name has no unique constraint). NOT the locked pirate_zone_create '
  '(0239: service_role only — untouched). Execute granted to authenticated (the guard enforces owner '
  'IN-BODY); NEVER to anon/public. The danger_zones write happens only inside this SECURITY DEFINER '
  'body — no client grant. Reads stay dark-coupled to pirate_intercept_enabled (0233).';

-- ── 2. ACL — authenticated may CALL (guard is in-body); anon/public may not. No table grant widened.
revoke all on function public.zone_create(text, jsonb) from public;
grant execute on function public.zone_create(text, jsonb) to authenticated;  -- guard is in-body; NEVER anon

-- ── 3. self-assert (deploy-time; any raise aborts the txn — nothing half-applies) ─────────────────
do $pubassert$
begin
  -- (a) the 0243 spine this command stands on exists.
  if to_regclass('public.app_owners') is null then
    raise exception 'PUBLISH-ZONE-CREATE self-assert FAIL: app_owners missing';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'PUBLISH-ZONE-CREATE self-assert FAIL: is_owner() missing';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'PUBLISH-ZONE-CREATE self-assert FAIL: world_editor_audit missing';
  end if;

  -- (b) the 0244 audit snapshot columns are present (a CREATE writes after_snapshot).
  if not exists (select 1 from pg_attribute
                 where attrelid = 'public.world_editor_audit'::regclass
                   and attname = 'before_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'after_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'source_revision' and not attisdropped) then
    raise exception 'PUBLISH-ZONE-CREATE self-assert FAIL: an audit snapshot column (before_snapshot/after_snapshot/source_revision) is missing';
  end if;

  -- (c) the command exists, is SECURITY DEFINER, and its ACL is authenticated-only.
  if to_regprocedure('public.zone_create(text, jsonb)') is null then
    raise exception 'PUBLISH-ZONE-CREATE self-assert FAIL: zone_create(text,jsonb) missing';
  end if;
  if not exists (select 1 from pg_proc
                 where oid = 'public.zone_create(text,jsonb)'::regprocedure and prosecdef) then
    raise exception 'PUBLISH-ZONE-CREATE self-assert FAIL: zone_create is not SECURITY DEFINER';
  end if;
  if not has_function_privilege('authenticated', 'public.zone_create(text,jsonb)', 'execute') then
    raise exception 'PUBLISH-ZONE-CREATE self-assert FAIL: authenticated cannot execute zone_create — the in-body guard would be unreachable';
  end if;
  if has_function_privilege('anon', 'public.zone_create(text,jsonb)', 'execute') then
    raise exception 'PUBLISH-ZONE-CREATE self-assert FAIL: anon CAN execute zone_create — must be authenticated-only';
  end if;

  -- (d) NO client-role write grant on danger_zones — the only write path is the SECURITY DEFINER
  -- command surface (0233 granted SELECT only; nothing here widened it). SELECT itself must
  -- SURVIVE: the zone read (get_danger_zones + the flag-gated RLS policy) depends on it.
  if has_table_privilege('authenticated', 'public.danger_zones', 'INSERT')
     or has_table_privilege('authenticated', 'public.danger_zones', 'UPDATE')
     or has_table_privilege('authenticated', 'public.danger_zones', 'DELETE')
     or has_table_privilege('anon', 'public.danger_zones', 'INSERT')
     or has_table_privilege('anon', 'public.danger_zones', 'UPDATE')
     or has_table_privilege('anon', 'public.danger_zones', 'DELETE') then
    raise exception 'PUBLISH-ZONE-CREATE self-assert FAIL: a client role holds a write grant on danger_zones — the only write path must be the SECURITY DEFINER command';
  end if;
  if not has_table_privilege('anon', 'public.danger_zones', 'SELECT')
     or not has_table_privilege('authenticated', 'public.danger_zones', 'SELECT') then
    raise exception 'PUBLISH-ZONE-CREATE self-assert FAIL: a client role LOST SELECT on danger_zones — the flag-gated zone read would break; this slice must add no narrowing there';
  end if;

  -- (e) the zone read is intact: get_danger_zones still exists and clients can still call it.
  if to_regprocedure('public.get_danger_zones()') is null then
    raise exception 'PUBLISH-ZONE-CREATE self-assert FAIL: get_danger_zones() vanished — the zone read is broken';
  end if;
  if not has_function_privilege('anon', 'public.get_danger_zones()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_danger_zones()', 'execute') then
    raise exception 'PUBLISH-ZONE-CREATE self-assert FAIL: a client role lost EXECUTE on get_danger_zones() — the zone read is broken';
  end if;

  -- (f) the 0239 pirate-zone lockdown is STILL intact (this slice touched NEITHER RPC: no client
  -- role may execute them; service_role keeps its owner-tooling grant).
  if has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_zone_delete(uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'PUBLISH-ZONE-CREATE self-assert FAIL: a client role regained EXECUTE on a pirate_zone write RPC — the 0239 lockdown was disturbed';
  end if;
  if not has_function_privilege('service_role', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or not has_function_privilege('service_role', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'PUBLISH-ZONE-CREATE self-assert FAIL: service_role LOST execute on a pirate_zone RPC — the 0239 owner-tooling path was disturbed';
  end if;

  raise notice 'PUBLISH-ZONE-CREATE self-assert ok: 0243 spine + snapshot columns present; zone_create SECURITY DEFINER + authenticated-only; no client write grant on danger_zones (SELECT intact); get_danger_zones intact; 0239 lockdown intact (service_role kept)';
end $pubassert$;
