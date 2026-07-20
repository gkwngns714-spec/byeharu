-- Byeharu — WORLD EDITOR PUBLISHING SLICE 7: location_create — the LAST publishing gap: an
-- owner-gated live-world-CREATE command for the locations domain through the 0243 contract.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT THIS IS: the location twin of exploration_site_create (0244) / mining_field_create (0246) —
-- it INSERTs one row into public.locations from an owner CREATE draft. It reproduces the 0244
-- create-command template step for step ((1) authn → typed 'not_authenticated'; (2) authz via THE
-- ONE guard public.is_owner() → typed 'not_authorized'; (3) request_id idempotency against THE ONE
-- ledger public.world_editor_audit; (4) exactly one audit row per applied command, with
-- after_snapshot only (before_snapshot is null on a create); (5) a typed {ok,request_id,
-- result|error} envelope; server-side re-validation with 'validation_failed' + details[]; typed
-- 'conflict' on a unique-key collision) and re-validates the SAME authoritative field subset as
-- location_update (0249) — the same enum literals, the same range rules, the same error codes, so
-- the client renders ONE vocabulary — with the CREATE-specific difference:
--
--   • zone_id IS REQUIRED: locations.zone_id is NOT NULL with an FK to public.zones (0002), and
--     name uniqueness is per-(zone_id, name). A NEW location therefore must say WHICH zone it goes
--     into. The client sources the zone list from the RAW get_world_map() tree (WorldMap
--     sectors[].zones[] carries id + name — flattenWorldMapZones in mapTypes.ts; no new server
--     read exists for this). The server validates zone_id itself: present + a uuid + naming an
--     EXISTING zone, else a typed validation_failed detail {code:'invalid_zone'} — a dangling FK
--     can never surface as a raw foreign_key_violation.
--   • NO target_id / expected / optimistic concurrency: a create has no live source row to drift
--     from. unique(zone_id, name) is deliberately NOT pre-checked — the table constraint is the
--     ONE uniqueness authority; a collision raises unique_violation → typed 'conflict'
--     (get stacked diagnostics TABLE_NAME disambiguates: locations → conflict/duplicate_name;
--     world_editor_audit → a raced duplicate request → idempotent replay).
--
-- DEPLOY POSTURE: UNDEPLOYED — deploy is a human gate. Fail-closed by design: even deployed, the
-- capability is inert until an owner is seeded into app_owners (is_owner() is false for everyone on
-- an unseeded DB). No client grant is widened anywhere: the locations write happens INSIDE this
-- SECURITY DEFINER function only; the 0249 explicit write-revoke on locations is RE-ASSERTED below
-- (a re-statement, never a widening) and SELECT is left exactly as-is — get_world_map and every
-- player map read are untouched.
--
-- NO-SPAGHETTI: no second owner check (is_owner() only), no second audit ledger, no second
-- idempotency key, no second enum list authority (the literals below mirror the 0002 CHECKs — the
-- same source locationEnums.ts mirrors, byte-identical to 0249's), no zone-read RPC added (the
-- client reuses the get_world_map tree it already fetches), no reuse of any gameplay/map RPC.
-- world_editor_ping and the six prior publish commands are left byte-identical; the 0244 audit
-- snapshot columns are NOT re-added (the dependency gate asserts they exist).
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. dependency gate — abort loudly if the surfaces this slice builds on are missing ────────────
do $pubdep$
begin
  if to_regclass('public.locations') is null then
    raise exception 'PUBLISH-LOC-CREATE: public.locations (0002) is missing — nothing to publish into';
  end if;
  if to_regclass('public.zones') is null then
    raise exception 'PUBLISH-LOC-CREATE: public.zones (0002) is missing — a location cannot exist without a zone';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'PUBLISH-LOC-CREATE: public.world_editor_audit (0243) is missing — the audit/idempotency spine must exist first';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'PUBLISH-LOC-CREATE: public.is_owner() (0243) is missing — THE ONE owner guard must exist first';
  end if;
  if to_regprocedure('public.exploration_site_create(text, jsonb)') is null then
    raise exception 'PUBLISH-LOC-CREATE: public.exploration_site_create (0244) is missing — the CREATE template this reproduces must exist';
  end if;
  if to_regprocedure('public.location_update(text, jsonb)') is null then
    raise exception 'PUBLISH-LOC-CREATE: public.location_update (0249) is missing — the location validation vocabulary this mirrors must exist';
  end if;
  -- the 0244 audit snapshot columns must already exist (this slice re-adds NOTHING; a create USES after_snapshot).
  if not exists (select 1 from pg_attribute
                 where attrelid = 'public.world_editor_audit'::regclass
                   and attname = 'after_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'source_revision' and not attisdropped) then
    raise exception 'PUBLISH-LOC-CREATE: a 0244 audit snapshot column (after_snapshot/source_revision) is missing — the snapshot columns must exist first';
  end if;
  -- the 0217 territory column this create writes must exist (null-or-positive CHECK is 0219's).
  if not exists (select 1 from pg_attribute
                 where attrelid = 'public.locations'::regclass
                   and attname = 'territory_radius' and not attisdropped) then
    raise exception 'PUBLISH-LOC-CREATE: locations.territory_radius (0217) is missing — the draft field set would not fit the table';
  end if;
  if to_regprocedure('public.get_world_map()') is null then
    raise exception 'PUBLISH-LOC-CREATE: public.get_world_map() is missing — the read this slice must NOT break must exist to be asserted';
  end if;
  if to_regprocedure('public.pirate_zone_create(text, jsonb, uuid)') is null
     or to_regprocedure('public.pirate_zone_delete(uuid)') is null then
    raise exception 'PUBLISH-LOC-CREATE: a 0239 pirate_zone write RPC is missing — the lockdown surface must exist to be re-asserted';
  end if;
end $pubdep$;

-- ── 1. location_create — the LAST-gap CREATE command (0244 template + 0249 location validation) ───
-- TYPED RESULT/ERROR CONTRACT (the 0244 vocabulary, unchanged):
--   success : {ok:true,  request_id, command_type, result:{created:true,id,name}}
--   replay  : {ok:true,  request_id, command_type, replayed:true, code:'duplicate_request', result:<prior jsonb>}
--   failure : {ok:false, request_id, error:<code> [, details:[{code,field,message}...]]}  where code ∈
--             { 'not_authenticated', 'not_authorized', 'invalid_request'   -- the 0243 vocabulary
--             , 'validation_failed'  -- the authoritative payload subset failed server re-validation
--                                    -- (incl. {code:'invalid_zone'}: zone_id missing / not a uuid /
--                                    --  naming no existing zone)
--             , 'conflict'           -- unique(zone_id, name) already taken in the chosen zone
--             }
-- p_payload = { fields: { zone_id (uuid — REQUIRED), name, location_type, activity_type, x, y,
--                         reward_tier, base_difficulty, min_power_required, is_public,
--                         territory_radius, status },
--               source_revision:<optional client draft fingerprint — audit trail only> }
create or replace function public.location_create(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_fields    jsonb;
  v_details   jsonb := '[]'::jsonb;
  v_zone_raw  text;
  v_zone_id   uuid;
  v_name      text;
  v_loc_type  text;
  v_act_type  text;
  v_status    text;
  v_x         numeric;
  v_y         numeric;
  v_tier      numeric;
  v_diff      numeric;
  v_minpow    numeric;
  v_radius    numeric;   -- null = "no territory" (a REAL authored value, 0217)
  v_public    boolean;
  v_after     jsonb;
  v_result    jsonb;
  v_prior     text;
  v_id        uuid;
  v_conflict_table text;
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
             'command_type', 'location_create', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  -- (5) SERVER-SIDE re-validation of the authoritative subset (p_payload->'fields') — the SAME
  -- rules and error codes as location_update (0249; the advisory client mirror is
  -- locationValidation.ts / locationEnums.ts; the live CHECKs are 0002 + 0219), PLUS the
  -- create-only zone_id rule. The client is NEVER trusted; every issue is collected so the full
  -- report renders at once. Zone-scoped name uniqueness is deliberately NOT pre-checked — the
  -- table's unique(zone_id,name) constraint is the one authority (typed 'conflict' below).
  v_fields := p_payload->'fields';
  if v_fields is null or jsonb_typeof(v_fields) <> 'object' then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'invalid_payload', 'field', null, 'message', 'payload.fields must be a JSON object.'));
  else
    -- zone_id — CREATE-ONLY: required, a uuid, and it must name an EXISTING zone (locations.zone_id
    -- is NOT NULL + FK→zones). All three failure shapes are ONE typed code: 'invalid_zone' — a
    -- dangling reference must never surface as a raw foreign_key_violation.
    v_zone_raw := btrim(coalesce(v_fields->>'zone_id', ''));
    if v_zone_raw = '' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_zone', 'field', 'zone_id',
        'message', 'zone_id is required — a new location must be created inside an existing zone.'));
    else
      begin
        v_zone_id := v_zone_raw::uuid;
      exception when invalid_text_representation then
        v_zone_id := null;
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'invalid_zone', 'field', 'zone_id',
          'message', 'zone_id ''' || v_zone_raw || ''' is not a valid uuid.'));
      end;
      if v_zone_id is not null
         and not exists (select 1 from public.zones where id = v_zone_id) then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'invalid_zone', 'field', 'zone_id',
          'message', 'No zone with id ''' || v_zone_raw || ''' exists — pick an existing zone.'));
      end if;
    end if;

    v_name := btrim(coalesce(v_fields->>'name', ''));
    if v_name = '' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'name_required', 'field', 'name', 'message', 'Name is required (locations.name is NOT NULL).'));
    end if;

    v_loc_type := v_fields->>'location_type';
    if v_loc_type is null or v_loc_type not in
       ('pirate_hunt','pirate_den','mining_site','derelict_station','trade_outpost','rally_point','safe_zone','event_site') then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_location_type', 'field', 'location_type',
        'message', 'Location type ''' || coalesce(v_loc_type, '(missing)') || ''' is not allowed by the live CHECK constraint.'));
    end if;

    v_act_type := v_fields->>'activity_type';
    if v_act_type is null or v_act_type not in
       ('hunt_pirates','mine_resource','explore_derelict','trade_visit','rally','none') then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_activity_type', 'field', 'activity_type',
        'message', 'Activity type ''' || coalesce(v_act_type, '(missing)') || ''' is not allowed by the live CHECK constraint.'));
    end if;

    v_status := v_fields->>'status';
    if v_status is null or v_status not in ('active','locked','hidden') then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_status', 'field', 'status',
        'message', 'Status ''' || coalesce(v_status, '(missing)') || ''' is not allowed — must be one of active, locked, hidden.'));
    end if;

    if jsonb_typeof(v_fields->'x') is distinct from 'number' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'numeric_not_finite', 'field', 'x', 'message', 'x must be a finite number.'));
    else
      v_x := (v_fields->'x')::numeric;
      if v_x < -10000 or v_x > 10000 then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'coord_out_of_bounds', 'field', 'x', 'message', 'x must be within ±10000.'));
      end if;
    end if;

    if jsonb_typeof(v_fields->'y') is distinct from 'number' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'numeric_not_finite', 'field', 'y', 'message', 'y must be a finite number.'));
    else
      v_y := (v_fields->'y')::numeric;
      if v_y < -10000 or v_y > 10000 then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'coord_out_of_bounds', 'field', 'y', 'message', 'y must be within ±10000.'));
      end if;
    end if;

    if jsonb_typeof(v_fields->'reward_tier') is distinct from 'number' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'numeric_not_finite', 'field', 'reward_tier', 'message', 'reward_tier must be a finite number.'));
    else
      v_tier := (v_fields->'reward_tier')::numeric;
      if v_tier < 0 then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'reward_tier_negative', 'field', 'reward_tier', 'message', 'Reward tier must be >= 0.'));
      elsif (v_tier % 1) <> 0 then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'reward_tier_not_integer', 'field', 'reward_tier', 'message', 'Reward tier must be an integer.'));
      end if;
    end if;

    if jsonb_typeof(v_fields->'base_difficulty') is distinct from 'number' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'numeric_not_finite', 'field', 'base_difficulty', 'message', 'base_difficulty must be a finite number.'));
    else
      v_diff := (v_fields->'base_difficulty')::numeric;
      if v_diff < 0 then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'base_difficulty_negative', 'field', 'base_difficulty', 'message', 'Difficulty must be >= 0.'));
      end if;
    end if;

    if jsonb_typeof(v_fields->'min_power_required') is distinct from 'number' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'numeric_not_finite', 'field', 'min_power_required', 'message', 'min_power_required must be a finite number.'));
    else
      v_minpow := (v_fields->'min_power_required')::numeric;
      if v_minpow < 0 then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'min_power_negative', 'field', 'min_power_required', 'message', 'Min power must be >= 0.'));
      end if;
    end if;

    -- territory_radius: null (or absent) = "no territory" — a legal authored value, WRITTEN as
    -- NULL. Otherwise a strictly positive number (the 0219 CHECK: null or > 0).
    if v_fields->'territory_radius' is null or jsonb_typeof(v_fields->'territory_radius') = 'null' then
      v_radius := null;
    elsif jsonb_typeof(v_fields->'territory_radius') <> 'number' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'numeric_not_finite', 'field', 'territory_radius', 'message', 'territory_radius must be a finite number (or null for no territory).'));
    else
      v_radius := (v_fields->'territory_radius')::numeric;
      if v_radius <= 0 then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'territory_radius_not_positive', 'field', 'territory_radius',
          'message', 'Territory radius must be greater than 0 (null for no territory).'));
      end if;
    end if;

    if jsonb_typeof(v_fields->'is_public') is distinct from 'boolean' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_payload', 'field', 'is_public', 'message', 'is_public must be a boolean.'));
    else
      v_public := (v_fields->'is_public')::boolean;
    end if;
  end if;

  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'validation_failed', 'details', v_details);
  end if;

  -- (6) apply + audit in ONE sub-block: any unique_violation rolls BOTH back atomically. The
  -- constraint's table disambiguates: locations (unique(zone_id,name) — the chosen zone already
  -- has a location with this name) ⇒ typed 'conflict'; world_editor_audit.request_id ⇒ a
  -- concurrent duplicate raced us ⇒ idempotent replay (this call's INSERT is undone by the
  -- sub-block rollback — no orphan row).
  begin
    insert into public.locations
        (zone_id, name, location_type, activity_type, x, y, reward_tier, base_difficulty,
         min_power_required, is_public, territory_radius, status)
      values
        (v_zone_id, v_name, v_loc_type, v_act_type, v_x::double precision, v_y::double precision,
         v_tier::int, v_diff::double precision, v_minpow::double precision, v_public, v_radius,
         v_status)
      returning jsonb_build_object(
                  'id', id, 'zone_id', zone_id, 'name', name, 'location_type', location_type,
                  'activity_type', activity_type, 'x', x, 'y', y, 'reward_tier', reward_tier,
                  'base_difficulty', base_difficulty, 'min_power_required', min_power_required,
                  'is_public', is_public, 'territory_radius', territory_radius, 'status', status,
                  'max_presence_seconds', max_presence_seconds, 'created_at', created_at),
                id
        into v_after, v_id;

    v_result := jsonb_build_object('created', true, 'id', v_id, 'name', v_name);

    -- (7) exactly ONE audit row — a CREATE records after_snapshot only (before is null by nature).
    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'location_create', 'location', v_id::text, v_result::text,
         null, v_after, p_payload->>'source_revision');
  exception when unique_violation then
    get stacked diagnostics v_conflict_table = TABLE_NAME;
    if v_conflict_table = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'location_create', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'conflict',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'duplicate_name', 'field', 'name',
               'message', 'A location with this name already exists in the chosen zone.')));
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id,
           'command_type', 'location_create', 'result', v_result);
end $$;

comment on function public.location_create(text, jsonb) is
  'WORLD EDITOR PUBLISH SLICE (0252): the LAST publishing gap — creates ONE location from an owner '
  'CREATE draft, following the 0244 create template with the 0249 location validation vocabulary. '
  'Authn → is_owner() authz → request_id idempotency → one audit row (after_snapshot only; before '
  'is null on a create) → typed envelope. zone_id is REQUIRED and validated (present + uuid + an '
  'existing zone, else typed validation_failed {invalid_zone} — never a raw FK violation); every '
  'other field re-validates server-side with the locationValidation error codes (enums mirror the '
  '0002 CHECKs; territory_radius null is a REAL value per 0217/0219). unique(zone_id,name) is the '
  'ONE uniqueness authority — a collision is a typed conflict. Execute granted to authenticated '
  '(the guard enforces owner IN-BODY); NEVER to anon/public. The locations write happens only '
  'inside this SECURITY DEFINER body — no client grant.';

-- ── 2. ACL — authenticated may CALL (guard is in-body); anon/public may not. No table grant widened.
revoke all on function public.location_create(text, jsonb) from public;
grant execute on function public.location_create(text, jsonb) to authenticated;  -- guard is in-body; NEVER anon

-- RE-ASSERT the 0249 narrowing (grants NOTHING new): client roles hold no locations write path —
-- the only write is this slice's + 0249's SECURITY DEFINER command surface. SELECT is deliberately
-- LEFT AS-IS (get_world_map and every player map read depend on it; nothing about reading changes).
revoke insert, update, delete on table public.locations from anon, authenticated;

-- ── 3. self-assert (deploy-time; any raise aborts the txn — nothing half-applies) ─────────────────
do $pubassert$
begin
  -- (a) the 0243 spine this command stands on exists.
  if to_regclass('public.app_owners') is null then
    raise exception 'PUBLISH-LOC-CREATE self-assert FAIL: app_owners missing';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'PUBLISH-LOC-CREATE self-assert FAIL: is_owner() missing';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'PUBLISH-LOC-CREATE self-assert FAIL: world_editor_audit missing';
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
    raise exception 'PUBLISH-LOC-CREATE self-assert FAIL: an audit snapshot column (before_snapshot/after_snapshot/source_revision) is missing';
  end if;

  -- (c) the command exists, is SECURITY DEFINER, and its ACL is authenticated-only.
  if to_regprocedure('public.location_create(text, jsonb)') is null then
    raise exception 'PUBLISH-LOC-CREATE self-assert FAIL: location_create(text,jsonb) missing';
  end if;
  if not exists (select 1 from pg_proc
                 where oid = 'public.location_create(text,jsonb)'::regprocedure and prosecdef) then
    raise exception 'PUBLISH-LOC-CREATE self-assert FAIL: location_create is not SECURITY DEFINER';
  end if;
  if not has_function_privilege('authenticated', 'public.location_create(text,jsonb)', 'execute') then
    raise exception 'PUBLISH-LOC-CREATE self-assert FAIL: authenticated cannot execute location_create — the in-body guard would be unreachable';
  end if;
  if has_function_privilege('anon', 'public.location_create(text,jsonb)', 'execute') then
    raise exception 'PUBLISH-LOC-CREATE self-assert FAIL: anon CAN execute location_create — must be authenticated-only';
  end if;

  -- (d) NO client-role write grant on locations — the 0249 posture RE-ASSERTED (the only write path
  -- is the SECURITY DEFINER command surface). SELECT itself must SURVIVE: the map read
  -- (get_world_map + RLS public read) depends on it.
  if has_table_privilege('authenticated', 'public.locations', 'INSERT')
     or has_table_privilege('authenticated', 'public.locations', 'UPDATE')
     or has_table_privilege('authenticated', 'public.locations', 'DELETE')
     or has_table_privilege('anon', 'public.locations', 'INSERT')
     or has_table_privilege('anon', 'public.locations', 'UPDATE')
     or has_table_privilege('anon', 'public.locations', 'DELETE') then
    raise exception 'PUBLISH-LOC-CREATE self-assert FAIL: a client role holds a write grant on locations — the only write path must be the SECURITY DEFINER command';
  end if;
  if not has_table_privilege('anon', 'public.locations', 'SELECT')
     or not has_table_privilege('authenticated', 'public.locations', 'SELECT') then
    raise exception 'PUBLISH-LOC-CREATE self-assert FAIL: a client role LOST SELECT on locations — the map read would break; this slice must narrow writes only';
  end if;

  -- (e) the world read is intact: get_world_map still exists and clients can still call it.
  if to_regprocedure('public.get_world_map()') is null then
    raise exception 'PUBLISH-LOC-CREATE self-assert FAIL: get_world_map() vanished — the world read is broken';
  end if;
  if not has_function_privilege('anon', 'public.get_world_map()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_world_map()', 'execute') then
    raise exception 'PUBLISH-LOC-CREATE self-assert FAIL: a client role lost EXECUTE on get_world_map() — the world read is broken';
  end if;

  -- (f) the 0239 pirate-zone lockdown is STILL intact (this slice restored NO write privilege).
  if has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_zone_delete(uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'PUBLISH-LOC-CREATE self-assert FAIL: a client role regained EXECUTE on a pirate_zone write RPC — the 0239 lockdown was disturbed';
  end if;

  raise notice 'PUBLISH-LOC-CREATE self-assert ok: 0243 spine + snapshot columns present; location_create SECURITY DEFINER + authenticated-only; no client write grant on locations (SELECT intact); get_world_map intact; 0239 lockdown intact';
end $pubassert$;
