-- Byeharu — WORLD EDITOR PUBLISHING SLICE 2: mining_field_create — the SECOND live-world-write
-- publish command, owner-gated through the 0243 contract; the byte-for-byte MINING TWIN of 0244.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT THIS IS: the second World Editor command that MUTATES world content — it INSERTs one row
-- into public.mining_fields. It reproduces the 0244 exploration_site_create template step for step
-- (which itself reproduces 0243 world_editor_ping): (1) authn (auth.uid() non-null) → typed
-- 'not_authenticated'; (2) authz via THE ONE guard public.is_owner() → typed 'not_authorized';
-- (3) request_id idempotency against THE ONE ledger public.world_editor_audit; (4) exactly one
-- audit row per applied command (with after_snapshot + source_revision — the 0244 columns);
-- (5) a typed {ok,request_id,result|error} envelope; plus the write-command parts: server-side
-- re-validation of the authoritative payload subset (the client's advisory validator is never
-- trusted), a typed 'validation_failed' + details[] vocabulary, and a typed 'conflict' on the
-- unique natural key (mining_fields.name). mining_fields (0103) is the IDENTICAL structural twin
-- of exploration_sites (0098): name UNIQUE NOT NULL, space_x/space_y finite ±10000,
-- reward_bundle_json NOT NULL jsonb object, is_active, RLS with no client grant.
--
-- DEPLOY POSTURE: UNDEPLOYED — deploy is a human gate. Fail-closed by design: even deployed, the
-- capability is inert until an owner is seeded into app_owners (is_owner() is false for everyone on
-- an unseeded DB). No client grant is widened anywhere: the mining_fields write happens INSIDE this
-- SECURITY DEFINER function only; client-role write grants on the table are explicitly REVOKED
-- (a pure narrowing — RLS already denied them).
--
-- NO-SPAGHETTI: no second owner check (is_owner() only), no second audit ledger, no second
-- idempotency key, no reuse of the gameplay RPC surface (command_mining_extract /
-- process_mining_securing stay untouched). The 0244 audit snapshot columns are NOT re-added — 0244
-- shipped them; the dependency gate below asserts they exist. world_editor_ping and
-- exploration_site_create are left byte-identical.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. dependency gate — abort loudly if the surfaces this slice builds on are missing ────────────
do $pubdep$
begin
  if to_regclass('public.mining_fields') is null then
    raise exception 'PUBLISH-MINING: public.mining_fields (0103) is missing — nothing to publish into';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'PUBLISH-MINING: public.world_editor_audit (0243) is missing — the audit/idempotency spine must exist first';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'PUBLISH-MINING: public.is_owner() (0243) is missing — THE ONE owner guard must exist first';
  end if;
  if to_regprocedure('public.exploration_site_create(text, jsonb)') is null then
    raise exception 'PUBLISH-MINING: public.exploration_site_create (0244) is missing — the publish template this twins must exist';
  end if;
  -- the 0244 audit snapshot columns must already exist (0244 added them; this slice re-adds NOTHING).
  if not exists (select 1 from pg_attribute
                 where attrelid = 'public.world_editor_audit'::regclass
                   and attname = 'after_snapshot' and not attisdropped) then
    raise exception 'PUBLISH-MINING: world_editor_audit.after_snapshot (0244) is missing — the snapshot columns must exist first';
  end if;
  if to_regprocedure('public.pirate_zone_create(text, jsonb, uuid)') is null
     or to_regprocedure('public.pirate_zone_delete(uuid)') is null then
    raise exception 'PUBLISH-MINING: a 0239 pirate_zone write RPC is missing — the lockdown surface must exist to be re-asserted';
  end if;
end $pubdep$;

-- ── 1. mining_field_create — the SECOND live-world-write command (0244 template, mining target) ───
-- TYPED RESULT/ERROR CONTRACT (identical to 0244, target-swapped):
--   success : {ok:true,  request_id, command_type, result:{created:true,id,name}}
--   replay  : {ok:true,  request_id, command_type, replayed:true, code:'duplicate_request', result:<prior jsonb>}
--   failure : {ok:false, request_id, error:<code> [, details:[{code,field,message}...]]}  where code ∈
--             { 'not_authenticated', 'not_authorized', 'invalid_request'   -- the 0243 vocabulary
--             , 'validation_failed'  -- the authoritative payload subset failed server re-validation
--             , 'conflict'           -- unique natural key (name) already taken
--             }
create or replace function public.mining_field_create(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_fields  jsonb;
  v_details jsonb := '[]'::jsonb;
  v_name    text;
  v_x       numeric;
  v_y       numeric;
  v_bundle  jsonb;
  v_items   jsonb;
  v_item    jsonb;
  v_i       int;
  v_after   jsonb;
  v_result  jsonb;
  v_prior   text;
  v_id      uuid;
  v_conflict_table text;
begin
  -- (1) authn — reject the anonymous caller with a typed code (no world touch). [0244:96-98]
  if v_uid is null then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authenticated');
  end if;

  -- (2) authz — THE ONE guard. Non-owner authenticated caller is rejected server-side. [0244:101-103]
  if not public.is_owner() then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authorized');
  end if;

  -- (3) request_id is the idempotency key — it must be present. [0244:106-108]
  if p_request_id is null or length(btrim(p_request_id)) = 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;

  -- (4a) idempotent replay: a prior row for this request_id ⇒ return its result, no second apply. [0244:111-116]
  select result into v_prior from public.world_editor_audit where request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'request_id', p_request_id,
             'command_type', 'mining_field_create', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  -- (5) SERVER-SIDE re-validation of the authoritative subset (p_payload->'fields'). The client's
  -- advisory validator (miningValidation.ts) is NEVER trusted; every issue is collected into a
  -- typed details[] so the client renders the full report, not just the first failure. jsonb numbers
  -- are finite by construction (JSON cannot encode NaN/Infinity), so type-check + range covers
  -- "numeric + finite + in-envelope". Name UNIQUENESS is deliberately NOT pre-checked here — the
  -- table's unique constraint is the one authority (a pre-check would be a racy second copy).
  v_fields := p_payload->'fields';
  if v_fields is null or jsonb_typeof(v_fields) <> 'object' then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'invalid_payload', 'field', null, 'message', 'payload.fields must be a JSON object.'));
  else
    v_name := btrim(coalesce(v_fields->>'name', ''));
    if v_name = '' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'name_required', 'field', 'name', 'message', 'Name is required (mining_fields.name is NOT NULL).'));
    end if;

    if jsonb_typeof(v_fields->'space_x') is distinct from 'number' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'numeric_not_finite', 'field', 'space_x', 'message', 'space_x must be a finite number.'));
    else
      v_x := (v_fields->'space_x')::numeric;
      if v_x < -10000 or v_x > 10000 then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'coord_out_of_bounds', 'field', 'space_x', 'message', 'space_x must be within ±10000.'));
      end if;
    end if;

    if jsonb_typeof(v_fields->'space_y') is distinct from 'number' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'numeric_not_finite', 'field', 'space_y', 'message', 'space_y must be a finite number.'));
    else
      v_y := (v_fields->'space_y')::numeric;
      if v_y < -10000 or v_y > 10000 then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'coord_out_of_bounds', 'field', 'space_y', 'message', 'space_y must be within ±10000.'));
      end if;
    end if;

    v_bundle := v_fields->'reward_bundle_json';
    if v_bundle is null or jsonb_typeof(v_bundle) <> 'object' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'reward_bundle_invalid', 'field', 'reward_bundle_json',
        'message', 'reward_bundle_json must be a JSON object with a non-empty items[] list.'));
    elsif jsonb_typeof(v_bundle->'items') is distinct from 'array' or jsonb_array_length(v_bundle->'items') = 0 then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'reward_bundle_invalid', 'field', 'reward_bundle_json',
        'message', 'Reward bundle must carry a non-empty items[] list.'));
    else
      v_items := v_bundle->'items';
      for v_i in 0 .. jsonb_array_length(v_items) - 1 loop
        v_item := v_items->v_i;
        if jsonb_typeof(v_item) <> 'object'
           or btrim(coalesce(v_item->>'item_id', '')) = '' then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code', 'reward_bundle_invalid', 'field', 'reward_bundle_json',
            'message', 'Reward item #' || (v_i + 1) || ': item_id must be a non-empty string.'));
        end if;
        if jsonb_typeof(v_item) <> 'object'
           or jsonb_typeof(v_item->'quantity') is distinct from 'number'
           or (v_item->'quantity')::numeric <= 0
           or ((v_item->'quantity')::numeric % 1) <> 0 then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code', 'reward_bundle_invalid', 'field', 'reward_bundle_json',
            'message', 'Reward item #' || (v_i + 1) || ': quantity must be a positive integer.'));
        end if;
      end loop;
    end if;
  end if;

  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'validation_failed', 'details', v_details);
  end if;

  -- (6) apply + audit in ONE sub-block: any unique_violation rolls BOTH back atomically. The
  -- constraint's table disambiguates: mining_fields.name ⇒ typed 'conflict';
  -- world_editor_audit.request_id ⇒ a concurrent duplicate raced us ⇒ idempotent replay
  -- (and this call's field insert is undone by the sub-block rollback — no orphan row). [0244:197-227]
  begin
    insert into public.mining_fields (name, space_x, space_y, reward_bundle_json)
      values (v_name, v_x::double precision, v_y::double precision, v_bundle)
      returning jsonb_build_object(
                  'id', id, 'name', name, 'space_x', space_x, 'space_y', space_y,
                  'reward_bundle_json', reward_bundle_json, 'is_active', is_active,
                  'created_at', created_at),
                id
        into v_after, v_id;

    v_result := jsonb_build_object('created', true, 'id', v_id, 'name', v_name);

    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'mining_field_create', 'mining_field', v_id::text, v_result::text,
         null, v_after, p_payload->>'source_revision');
  exception when unique_violation then
    get stacked diagnostics v_conflict_table = TABLE_NAME;
    if v_conflict_table = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'mining_field_create', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'conflict',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'duplicate_name', 'field', 'name',
               'message', 'A mining field with this name already exists.')));
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id,
           'command_type', 'mining_field_create', 'result', v_result);
end $$;

comment on function public.mining_field_create(text, jsonb) is
  'WORLD EDITOR PUBLISH SLICE (0246): the SECOND live-world-write command — creates ONE mining '
  'field from an owner draft; the mining twin of exploration_site_create (0244). Reproduces the '
  '0243 template: authn → is_owner() authz → request_id idempotency → one audit row (with '
  'after_snapshot + source_revision) → typed envelope. Adds server-side re-validation '
  '(validation_failed + details[]) and a typed conflict on the unique name. Execute granted to '
  'authenticated (the guard enforces owner IN-BODY); NEVER to anon/public. The mining_fields write '
  'happens only inside this SECURITY DEFINER body — no client grant.';

-- ── 2. ACL — authenticated may CALL (guard is in-body); anon/public may not. No table grant widened.
revoke all on function public.mining_field_create(text, jsonb) from public;
grant execute on function public.mining_field_create(text, jsonb) to authenticated;  -- guard is in-body; NEVER anon

-- Belt-and-braces NARROWING (the 0244 idiom): RLS already denies client writes to mining_fields
-- (no policy, 0103), but the Supabase default table grants may still exist — revoke the write
-- grants so the privilege matrix is unambiguous and self-assertable. SELECT is left exactly as it
-- stands today (mining_fields has no client read path by design — 0103 hidden-fields posture).
revoke insert, update, delete on table public.mining_fields from anon, authenticated;

-- ── 3. self-assert (deploy-time; any raise aborts the txn — nothing half-applies) ─────────────────
do $pubassert$
begin
  -- (a) the 0243 spine this command stands on exists.
  if to_regclass('public.app_owners') is null then
    raise exception 'PUBLISH-MINING self-assert FAIL: app_owners missing';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'PUBLISH-MINING self-assert FAIL: is_owner() missing';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'PUBLISH-MINING self-assert FAIL: world_editor_audit missing';
  end if;

  -- (b) the 0244 audit snapshot columns are present (this slice added nothing to them).
  if not exists (select 1 from pg_attribute
                 where attrelid = 'public.world_editor_audit'::regclass
                   and attname = 'before_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'after_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'source_revision' and not attisdropped) then
    raise exception 'PUBLISH-MINING self-assert FAIL: an audit snapshot column (before_snapshot/after_snapshot/source_revision) is missing';
  end if;

  -- (c) the command exists, is SECURITY DEFINER, and its ACL is authenticated-only.
  if to_regprocedure('public.mining_field_create(text, jsonb)') is null then
    raise exception 'PUBLISH-MINING self-assert FAIL: mining_field_create(text,jsonb) missing';
  end if;
  if not exists (select 1 from pg_proc
                 where oid = 'public.mining_field_create(text,jsonb)'::regprocedure and prosecdef) then
    raise exception 'PUBLISH-MINING self-assert FAIL: mining_field_create is not SECURITY DEFINER';
  end if;
  if not has_function_privilege('authenticated', 'public.mining_field_create(text,jsonb)', 'execute') then
    raise exception 'PUBLISH-MINING self-assert FAIL: authenticated cannot execute mining_field_create — the in-body guard would be unreachable';
  end if;
  if has_function_privilege('anon', 'public.mining_field_create(text,jsonb)', 'execute') then
    raise exception 'PUBLISH-MINING self-assert FAIL: anon CAN execute mining_field_create — must be authenticated-only';
  end if;

  -- (d) NO client-role write grant on mining_fields — the write lives only inside the definer body.
  if has_table_privilege('authenticated', 'public.mining_fields', 'INSERT')
     or has_table_privilege('authenticated', 'public.mining_fields', 'UPDATE')
     or has_table_privilege('anon', 'public.mining_fields', 'INSERT')
     or has_table_privilege('anon', 'public.mining_fields', 'UPDATE') then
    raise exception 'PUBLISH-MINING self-assert FAIL: a client role holds an INSERT/UPDATE grant on mining_fields — the only write path must be the SECURITY DEFINER command';
  end if;

  -- (e) the 0239 pirate-zone lockdown is STILL intact (this slice restored NO write privilege).
  if has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_zone_delete(uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'PUBLISH-MINING self-assert FAIL: a client role regained EXECUTE on a pirate_zone write RPC — the 0239 lockdown was disturbed';
  end if;

  raise notice 'PUBLISH-MINING self-assert ok: 0243 spine + 0244 snapshot columns present; mining_field_create SECURITY DEFINER + authenticated-only; no client write grant on mining_fields; 0239 lockdown intact';
end $pubassert$;
