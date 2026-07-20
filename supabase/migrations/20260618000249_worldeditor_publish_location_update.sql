-- Byeharu — WORLD EDITOR PUBLISHING SLICE 5: location_update — the THIRD publish DOMAIN (locations),
-- an owner-gated live-world-UPDATE command through the 0243 contract, with OPTIMISTIC CONCURRENCY.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT THIS IS: the location twin of exploration_site_update (0247) / mining_field_update (0248) —
-- it UPDATEs one row in public.locations (the row an owner EDIT draft was forked from). It follows
-- the 0247 body shape step for step ((1) authn → typed 'not_authenticated'; (2) authz via THE ONE
-- guard public.is_owner() → typed 'not_authorized'; (3) request_id idempotency against THE ONE
-- ledger public.world_editor_audit; (4) exactly one audit row per applied command, with BOTH
-- before_snapshot AND after_snapshot; (5) a typed {ok,request_id,result|error} envelope; server-side
-- re-validation with 'validation_failed' + details[]; typed 'conflict' on a unique-key collision)
-- with the LOCATION-specific differences:
--
--   • TARGETING BY UUID: unlike the exploration/mining twins (whose editor read contract exposes
--     only the natural-key name), a location's read contract (get_world_map → MapLocation) DOES
--     carry the row id — locationDraftModel.ts liveId = live.id. So p_payload.target_id is the
--     location's uuid; the live row is located AND ROW-LOCKED by primary key (select … for update).
--     A malformed (non-uuid) target_id is a malformed REQUEST → 'invalid_request'; a vanished
--     target is a typed 'not_found' with details[{code:'source_missing'}].
--   • MORE FIELDS: the draft payload (locationDraftTypes.ts LocationDraftPayload) is 11 fields —
--     name, location_type, activity_type, x, y, reward_tier, base_difficulty, min_power_required,
--     is_public, territory_radius, status. The optimistic-concurrency compare AND the update SET
--     cover ALL of them. territory_radius null is a REAL authored value ("no territory", 0217) —
--     it is compared null-safely and WRITTEN (not "kept" — the mining-bundle keep semantics do not
--     apply: every location field is client-readable).
--   • ENUM VALIDATION: location_type / activity_type / status are CHECK enums on the live table
--     (0002). The server re-validates membership itself (mirroring locationValidation.ts /
--     locationEnums.ts error codes) so a bad enum is a TYPED validation_failed detail, never a raw
--     check_violation. x/y are validated within the ±10000 safe envelope of the current map-seed
--     frame (coordinate normalization is V1C's job — 0245 — and deliberately NOT done here).
--   • zone_id IS NOT A DRAFT FIELD: the update never touches locations.zone_id — a location edit
--     cannot move a row between zones. unique(zone_id, name) is deliberately NOT pre-checked (the
--     client cannot even see zone_id — MapLocation has none): the table constraint is the ONE
--     authority; a rename that collides within the zone raises unique_violation → typed 'conflict'
--     (get stacked diagnostics TABLE_NAME disambiguates: locations → conflict/duplicate_name;
--     world_editor_audit → a raced duplicate request → idempotent replay).
--
-- DEPLOY POSTURE: UNDEPLOYED — deploy is a human gate. Fail-closed by design: even deployed, the
-- capability is inert until an owner is seeded into app_owners (is_owner() is false for everyone on
-- an unseeded DB). No client grant is widened anywhere: the locations write happens INSIDE this
-- SECURITY DEFINER function only, and this slice NARROWS the matrix explicitly (the 0002 posture —
-- SELECT-only client grants — is made unambiguous by an explicit write revoke below; SELECT is left
-- exactly as-is, so get_world_map and every map read are untouched).
--
-- NO-SPAGHETTI: no second owner check (is_owner() only), no second audit ledger, no second
-- idempotency key, no server-side fingerprint re-derivation (value equality is the one staleness
-- authority), no second enum list authority (the literals below mirror the 0002 CHECKs — the same
-- source locationEnums.ts mirrors), no reuse of any gameplay/map RPC. world_editor_ping and the
-- four prior publish commands are left byte-identical; the 0244 audit snapshot columns are NOT
-- re-added (the dependency gate asserts they exist).
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. dependency gate — abort loudly if the surfaces this slice builds on are missing ────────────
do $pubdep$
begin
  if to_regclass('public.locations') is null then
    raise exception 'PUBLISH-LOC-UPDATE: public.locations (0002) is missing — nothing to update';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'PUBLISH-LOC-UPDATE: public.world_editor_audit (0243) is missing — the audit/idempotency spine must exist first';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'PUBLISH-LOC-UPDATE: public.is_owner() (0243) is missing — THE ONE owner guard must exist first';
  end if;
  if to_regprocedure('public.exploration_site_update(text, jsonb)') is null then
    raise exception 'PUBLISH-LOC-UPDATE: public.exploration_site_update (0247) is missing — the UPDATE template this extends must exist';
  end if;
  -- the 0244 audit snapshot columns must already exist (this slice re-adds NOTHING; an update USES both).
  if not exists (select 1 from pg_attribute
                 where attrelid = 'public.world_editor_audit'::regclass
                   and attname = 'before_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'after_snapshot' and not attisdropped) then
    raise exception 'PUBLISH-LOC-UPDATE: a 0244 audit snapshot column (before_snapshot/after_snapshot) is missing — the snapshot columns must exist first';
  end if;
  -- the 0217 territory column this update writes must exist (null-or-positive CHECK is 0219's).
  if not exists (select 1 from pg_attribute
                 where attrelid = 'public.locations'::regclass
                   and attname = 'territory_radius' and not attisdropped) then
    raise exception 'PUBLISH-LOC-UPDATE: locations.territory_radius (0217) is missing — the draft field set would not fit the table';
  end if;
  if to_regprocedure('public.get_world_map()') is null then
    raise exception 'PUBLISH-LOC-UPDATE: public.get_world_map() is missing — the read this slice must NOT break must exist to be asserted';
  end if;
  if to_regprocedure('public.pirate_zone_create(text, jsonb, uuid)') is null
     or to_regprocedure('public.pirate_zone_delete(uuid)') is null then
    raise exception 'PUBLISH-LOC-UPDATE: a 0239 pirate_zone write RPC is missing — the lockdown surface must exist to be re-asserted';
  end if;
end $pubdep$;

-- ── 1. location_update — the THIRD-domain UPDATE command (0247 template, uuid-addressed) ──────────
-- TYPED RESULT/ERROR CONTRACT (the 0247 vocabulary, unchanged):
--   success : {ok:true,  request_id, command_type, result:{updated:true,id,name}}
--   replay  : {ok:true,  request_id, command_type, replayed:true, code:'duplicate_request', result:<prior jsonb>}
--   failure : {ok:false, request_id, error:<code> [, details:[{code,field,message}...]]}  where code ∈
--             { 'not_authenticated', 'not_authorized', 'invalid_request'   -- the 0243 vocabulary
--             , 'not_found'          -- target_id names no live row (details: source_missing)
--             , 'stale_revision'     -- the locked live row no longer matches `expected` (details: source_changed per field)
--             , 'validation_failed'  -- the authoritative payload subset failed server re-validation
--             , 'conflict'           -- the NEW name collides with another location in the SAME zone (unique(zone_id,name))
--             }
-- p_payload = { target_id:      <the location's uuid id — locationDraftModel liveId, the edit fork's sourceId>,
--               expected:       <the draft's sourceSnapshot: the 11 projected field values at fork time>,
--               fields:         <the new values: name, location_type, activity_type, x, y, reward_tier,
--                                base_difficulty, min_power_required, is_public, territory_radius, status>,
--               source_revision:<the draft's forked fingerprint — audit trail only> }
create or replace function public.location_update(p_request_id text, p_payload jsonb default '{}'::jsonb)
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
  v_loc_type  text;
  v_act_type  text;
  v_status    text;
  v_x         numeric;
  v_y         numeric;
  v_tier      numeric;
  v_diff      numeric;
  v_minpow    numeric;
  v_radius    numeric;   -- null = "no territory" (a REAL authored value, 0217 — always written)
  v_public    boolean;
  v_live      record;    -- the LOCKED live row
  v_before    jsonb;
  v_after     jsonb;
  v_result    jsonb;
  v_prior     text;
  v_id        uuid;
  v_conflict_table text;
begin
  -- (1) authn — reject the anonymous caller with a typed code (no world touch). [0247:119-122]
  if v_uid is null then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authenticated');
  end if;

  -- (2) authz — THE ONE guard. Non-owner authenticated caller is rejected server-side. [0247:124-127]
  if not public.is_owner() then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authorized');
  end if;

  -- (3) request_id is the idempotency key — it must be present. [0247:129-132]
  if p_request_id is null or length(btrim(p_request_id)) = 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;

  -- (4a) idempotent replay: a prior row for this request_id ⇒ return its result, no second apply.
  select result into v_prior from public.world_editor_audit where request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'request_id', p_request_id,
             'command_type', 'location_update', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  -- (4b) structural addressing: an UPDATE cannot even be located without a uuid target_id and an
  -- `expected` snapshot object — missing/malformed addressing is a malformed REQUEST (the 0243
  -- invalid_request code), not a field-validation report.
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

  -- (5) LOCATE + ROW-LOCK the live target by PRIMARY KEY (the id the editor's read contract carries
  -- — locationDraftModel liveId; the 0247 twins address by natural-key name only because their read
  -- exposes no id). The lock holds until commit/rollback, so the compare-then-write below cannot
  -- race a concurrent editor. zone_id is selected for the snapshots but NEVER written.
  select id, zone_id, name, location_type, activity_type, x, y, reward_tier, base_difficulty,
         min_power_required, is_public, territory_radius, status, max_presence_seconds, created_at
    into v_live
    from public.locations
   where id = v_target_id
     for update;
  if not found then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_found',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_missing', 'field', null,
               'message', 'No live location with id ''' || v_target || ''' exists — it may have been removed since the draft was forked.')));
  end if;

  -- (6) OPTIMISTIC CONCURRENCY — re-project the LOCKED row onto ALL 11 draft-carried fields and
  -- compare value-by-value with `expected` (the fork-time sourceSnapshot). Value equality is the
  -- authority (the client fingerprint is NOT re-derived — see header). Every drifted field is
  -- reported, then the whole command is rejected with NOTHING written. to_jsonb makes each compare
  -- null-safe and type-honest (numbers as jsonb numbers, booleans as jsonb booleans);
  -- territory_radius folds SQL null and JSON null together (both mean "no territory").
  if v_expected->>'name' is distinct from v_live.name then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'name',
      'message', 'The live location''s name changed since this draft was forked.'));
  end if;
  if v_expected->>'location_type' is distinct from v_live.location_type then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'location_type',
      'message', 'The live location''s location_type changed since this draft was forked.'));
  end if;
  if v_expected->>'activity_type' is distinct from v_live.activity_type then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'activity_type',
      'message', 'The live location''s activity_type changed since this draft was forked.'));
  end if;
  if v_expected->'x' is distinct from to_jsonb(v_live.x) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'x',
      'message', 'The live location''s x changed since this draft was forked.'));
  end if;
  if v_expected->'y' is distinct from to_jsonb(v_live.y) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'y',
      'message', 'The live location''s y changed since this draft was forked.'));
  end if;
  if v_expected->'reward_tier' is distinct from to_jsonb(v_live.reward_tier) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'reward_tier',
      'message', 'The live location''s reward_tier changed since this draft was forked.'));
  end if;
  if v_expected->'base_difficulty' is distinct from to_jsonb(v_live.base_difficulty) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'base_difficulty',
      'message', 'The live location''s base_difficulty changed since this draft was forked.'));
  end if;
  if v_expected->'min_power_required' is distinct from to_jsonb(v_live.min_power_required) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'min_power_required',
      'message', 'The live location''s min_power_required changed since this draft was forked.'));
  end if;
  if v_expected->'is_public' is distinct from to_jsonb(v_live.is_public) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'is_public',
      'message', 'The live location''s is_public changed since this draft was forked.'));
  end if;
  if coalesce(v_expected->'territory_radius', 'null'::jsonb)
       is distinct from coalesce(to_jsonb(v_live.territory_radius), 'null'::jsonb) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'territory_radius',
      'message', 'The live location''s territory_radius changed since this draft was forked.'));
  end if;
  if v_expected->>'status' is distinct from v_live.status then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'status',
      'message', 'The live location''s status changed since this draft was forked.'));
  end if;
  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'stale_revision', 'details', v_details);
  end if;

  -- (7) SERVER-SIDE re-validation of the authoritative subset (p_payload->'fields') — the SAME
  -- rules the advisory client validator mirrors (locationValidation.ts / locationEnums.ts; the
  -- live CHECKs are 0002 + 0219), with the SAME error codes, so the client renders one vocabulary.
  -- The client is NEVER trusted; every issue is collected so the full report renders at once.
  -- Zone-scoped name uniqueness is deliberately NOT pre-checked — the table's unique(zone_id,name)
  -- constraint is the one authority (typed 'conflict' below).
  v_fields := p_payload->'fields';
  if v_fields is null or jsonb_typeof(v_fields) <> 'object' then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'invalid_payload', 'field', null, 'message', 'payload.fields must be a JSON object.'));
  else
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

  -- (8) apply + audit in ONE sub-block: any unique_violation rolls BOTH back atomically. The
  -- constraint's table disambiguates: locations (unique(zone_id,name) — a RENAME collided with
  -- another location in the SAME zone) ⇒ typed 'conflict'; world_editor_audit.request_id ⇒ a
  -- concurrent duplicate raced us ⇒ idempotent replay (this call's UPDATE is undone by the
  -- sub-block rollback — no torn write). The row is addressed by its LOCKED primary key; zone_id
  -- is NEVER in the SET (a location edit cannot move a row between zones).
  v_before := jsonb_build_object(
                'id', v_live.id, 'zone_id', v_live.zone_id, 'name', v_live.name,
                'location_type', v_live.location_type, 'activity_type', v_live.activity_type,
                'x', v_live.x, 'y', v_live.y, 'reward_tier', v_live.reward_tier,
                'base_difficulty', v_live.base_difficulty,
                'min_power_required', v_live.min_power_required, 'is_public', v_live.is_public,
                'territory_radius', v_live.territory_radius, 'status', v_live.status,
                'max_presence_seconds', v_live.max_presence_seconds, 'created_at', v_live.created_at);
  begin
    update public.locations
       set name               = v_name,
           location_type      = v_loc_type,
           activity_type      = v_act_type,
           x                  = v_x::double precision,
           y                  = v_y::double precision,
           reward_tier        = v_tier::int,
           base_difficulty    = v_diff::double precision,
           min_power_required = v_minpow::double precision,
           is_public          = v_public,
           territory_radius   = v_radius,
           status             = v_status
     where id = v_live.id
     returning jsonb_build_object(
                 'id', id, 'zone_id', zone_id, 'name', name, 'location_type', location_type,
                 'activity_type', activity_type, 'x', x, 'y', y, 'reward_tier', reward_tier,
                 'base_difficulty', base_difficulty, 'min_power_required', min_power_required,
                 'is_public', is_public, 'territory_radius', territory_radius, 'status', status,
                 'max_presence_seconds', max_presence_seconds, 'created_at', created_at),
               id
       into v_after, v_id;

    v_result := jsonb_build_object('updated', true, 'id', v_id, 'name', v_name);

    -- (9) exactly ONE audit row — an UPDATE records BOTH snapshots (the 0244 columns, both used).
    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'location_update', 'location', v_id::text, v_result::text,
         v_before, v_after, p_payload->>'source_revision');
  exception when unique_violation then
    get stacked diagnostics v_conflict_table = TABLE_NAME;
    if v_conflict_table = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'location_update', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'conflict',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'duplicate_name', 'field', 'name',
               'message', 'A location with this name already exists in the same zone.')));
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id,
           'command_type', 'location_update', 'result', v_result);
end $$;

comment on function public.location_update(text, jsonb) is
  'WORLD EDITOR PUBLISH SLICE (0249): the THIRD publish DOMAIN — edits ONE location from an owner '
  'EDIT draft with OPTIMISTIC CONCURRENCY, following the 0247 update template. Authn → is_owner() '
  'authz → request_id idempotency → one audit row → typed envelope; locates + ROW-LOCKS the target '
  'by its uuid PRIMARY KEY (payload.target_id = the MapLocation id the edit fork pinned; not_found/'
  'source_missing when gone), rejects any fork-time drift across ALL 11 draft fields with '
  'stale_revision/source_changed (value-by-value against payload.expected — the client fingerprint '
  'is never re-derived), re-validates every field server-side with the locationValidation error '
  'vocabulary (validation_failed + details[]; enums mirror the 0002 CHECKs; territory_radius null '
  'is a REAL value per 0217/0219), applies the UPDATE (never zone_id — a location cannot change '
  'zone), and audits BOTH before_snapshot and after_snapshot. unique(zone_id,name) is the ONE '
  'uniqueness authority — a rename collision is a typed conflict. Execute granted to authenticated '
  '(the guard enforces owner IN-BODY); NEVER to anon/public. The locations write happens only '
  'inside this SECURITY DEFINER body — no client grant.';

-- ── 2. ACL — authenticated may CALL (guard is in-body); anon/public may not. No table grant widened.
revoke all on function public.location_update(text, jsonb) from public;
grant execute on function public.location_update(text, jsonb) to authenticated;  -- guard is in-body; NEVER anon

-- NARROWING (make the matrix unambiguous): 0002 granted SELECT only and RLS has no write policy,
-- so client roles never held a locations write path — state that explicitly. SELECT is deliberately
-- LEFT AS-IS (get_world_map and every map read depend on it; nothing about reading changes here).
revoke insert, update, delete on table public.locations from anon, authenticated;

-- ── 3. self-assert (deploy-time; any raise aborts the txn — nothing half-applies) ─────────────────
do $pubassert$
begin
  -- (a) the 0243 spine this command stands on exists.
  if to_regclass('public.app_owners') is null then
    raise exception 'PUBLISH-LOC-UPDATE self-assert FAIL: app_owners missing';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'PUBLISH-LOC-UPDATE self-assert FAIL: is_owner() missing';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'PUBLISH-LOC-UPDATE self-assert FAIL: world_editor_audit missing';
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
    raise exception 'PUBLISH-LOC-UPDATE self-assert FAIL: an audit snapshot column (before_snapshot/after_snapshot/source_revision) is missing';
  end if;

  -- (c) the command exists, is SECURITY DEFINER, and its ACL is authenticated-only.
  if to_regprocedure('public.location_update(text, jsonb)') is null then
    raise exception 'PUBLISH-LOC-UPDATE self-assert FAIL: location_update(text,jsonb) missing';
  end if;
  if not exists (select 1 from pg_proc
                 where oid = 'public.location_update(text,jsonb)'::regprocedure and prosecdef) then
    raise exception 'PUBLISH-LOC-UPDATE self-assert FAIL: location_update is not SECURITY DEFINER';
  end if;
  if not has_function_privilege('authenticated', 'public.location_update(text,jsonb)', 'execute') then
    raise exception 'PUBLISH-LOC-UPDATE self-assert FAIL: authenticated cannot execute location_update — the in-body guard would be unreachable';
  end if;
  if has_function_privilege('anon', 'public.location_update(text,jsonb)', 'execute') then
    raise exception 'PUBLISH-LOC-UPDATE self-assert FAIL: anon CAN execute location_update — must be authenticated-only';
  end if;

  -- (d) NO client-role write grant on locations — the 0002 SELECT-only posture is now EXPLICIT
  -- (the only write path is the SECURITY DEFINER command surface). SELECT itself must SURVIVE:
  -- the map read (get_world_map + RLS public read) depends on it.
  if has_table_privilege('authenticated', 'public.locations', 'INSERT')
     or has_table_privilege('authenticated', 'public.locations', 'UPDATE')
     or has_table_privilege('authenticated', 'public.locations', 'DELETE')
     or has_table_privilege('anon', 'public.locations', 'INSERT')
     or has_table_privilege('anon', 'public.locations', 'UPDATE')
     or has_table_privilege('anon', 'public.locations', 'DELETE') then
    raise exception 'PUBLISH-LOC-UPDATE self-assert FAIL: a client role holds a write grant on locations — the only write path must be the SECURITY DEFINER command';
  end if;
  if not has_table_privilege('anon', 'public.locations', 'SELECT')
     or not has_table_privilege('authenticated', 'public.locations', 'SELECT') then
    raise exception 'PUBLISH-LOC-UPDATE self-assert FAIL: a client role LOST SELECT on locations — the map read would break; this slice must narrow writes only';
  end if;

  -- (e) the world read is intact: get_world_map still exists and clients can still call it.
  if to_regprocedure('public.get_world_map()') is null then
    raise exception 'PUBLISH-LOC-UPDATE self-assert FAIL: get_world_map() vanished — the world read is broken';
  end if;
  if not has_function_privilege('anon', 'public.get_world_map()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_world_map()', 'execute') then
    raise exception 'PUBLISH-LOC-UPDATE self-assert FAIL: a client role lost EXECUTE on get_world_map() — the world read is broken';
  end if;

  -- (f) the 0239 pirate-zone lockdown is STILL intact (this slice restored NO write privilege).
  if has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_zone_delete(uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'PUBLISH-LOC-UPDATE self-assert FAIL: a client role regained EXECUTE on a pirate_zone write RPC — the 0239 lockdown was disturbed';
  end if;

  raise notice 'PUBLISH-LOC-UPDATE self-assert ok: 0243 spine + snapshot columns present; location_update SECURITY DEFINER + authenticated-only; no client write grant on locations (SELECT intact); get_world_map intact; 0239 lockdown intact';
end $pubassert$;
