-- Byeharu — WORLD EDITOR PUBLISHING SLICE 1: exploration_site_create — the FIRST live-world-WRITE
-- publish command, owner-gated through the 0243 contract.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT THIS IS: the first World Editor command that MUTATES world content — it INSERTs one row into
-- public.exploration_sites. It reproduces the 0243 world_editor_ping template step for step:
-- (1) authn (auth.uid() non-null) → typed 'not_authenticated'; (2) authz via THE ONE guard
-- public.is_owner() → typed 'not_authorized'; (3) request_id idempotency against THE ONE ledger
-- public.world_editor_audit; (4) exactly one audit row per applied command; (5) a typed
-- {ok,request_id,result|error} envelope. On top of the template it adds the parts a WRITE needs:
-- server-side re-validation of the authoritative payload subset (the client's advisory validator is
-- never trusted), a typed 'validation_failed' + details[] vocabulary, a typed 'conflict' on the
-- unique natural key, and before/after snapshots on the audit row (additive columns, below).
--
-- DEPLOY POSTURE: UNDEPLOYED — deploy is a human gate. Fail-closed by design: even deployed, the
-- capability is inert until an owner is seeded into app_owners (is_owner() is false for everyone on
-- an unseeded DB). No client grant is widened anywhere: the exploration_sites write happens INSIDE
-- this SECURITY DEFINER function only; client-role write grants on the table are explicitly REVOKED
-- (a pure narrowing — RLS already denied them).
--
-- NO-SPAGHETTI: no second owner check (is_owner() only), no second audit ledger, no second
-- idempotency key, no reuse of the gameplay RPC surface (command_exploration_scan/securing stay
-- untouched). world_editor_ping is left byte-identical; the audit columns are ADDITIVE + NULLABLE.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. dependency gate — abort loudly if the surfaces this slice builds on are missing ────────────
do $pubdep$
begin
  if to_regclass('public.exploration_sites') is null then
    raise exception 'PUBLISH-EXPLORATION: public.exploration_sites (0098) is missing — nothing to publish into';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'PUBLISH-EXPLORATION: public.world_editor_audit (0243) is missing — the audit/idempotency spine must exist first';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'PUBLISH-EXPLORATION: public.is_owner() (0243) is missing — THE ONE owner guard must exist first';
  end if;
  if to_regprocedure('public.world_editor_ping(text, jsonb)') is null then
    raise exception 'PUBLISH-EXPLORATION: public.world_editor_ping (0243) is missing — the command template this reproduces must exist';
  end if;
  if to_regprocedure('public.pirate_zone_create(text, jsonb, uuid)') is null
     or to_regprocedure('public.pirate_zone_delete(uuid)') is null then
    raise exception 'PUBLISH-EXPLORATION: a 0239 pirate_zone write RPC is missing — the lockdown surface must exist to be re-asserted';
  end if;
end $pubdep$;

-- ── 1. world_editor_audit snapshots — ADDITIVE, NULLABLE (world_editor_ping untouched) ────────────
-- A write command must record what it changed: before_snapshot (null on a create), after_snapshot
-- (the created/updated row as jsonb), and the client-supplied source_revision (the draft's forked
-- fingerprint — audit trail only in this slice; server-side stale checks come with edit commands).
alter table public.world_editor_audit
  add column if not exists before_snapshot jsonb,
  add column if not exists after_snapshot  jsonb,
  add column if not exists source_revision text;

comment on column public.world_editor_audit.before_snapshot is
  'PUBLISH SLICE (0244): jsonb snapshot of the target row BEFORE the command applied (null for a create).';
comment on column public.world_editor_audit.after_snapshot is
  'PUBLISH SLICE (0244): jsonb snapshot of the target row AFTER the command applied (null for a delete).';
comment on column public.world_editor_audit.source_revision is
  'PUBLISH SLICE (0244): the client draft''s source fingerprint at fork time (audit trail; nullable).';

-- ── 2. exploration_site_create — the FIRST live-world-write command (0243 template + validation) ──
-- TYPED RESULT/ERROR CONTRACT (extends the 0243 vocabulary):
--   success : {ok:true,  request_id, command_type, result:{created:true,id,name}}
--   replay  : {ok:true,  request_id, command_type, replayed:true, code:'duplicate_request', result:<prior jsonb>}
--   failure : {ok:false, request_id, error:<code> [, details:[{code,field,message}...]]}  where code ∈
--             { 'not_authenticated', 'not_authorized', 'invalid_request'   -- the 0243 vocabulary
--             , 'validation_failed'  -- the authoritative payload subset failed server re-validation
--             , 'conflict'           -- unique natural key (name) already taken
--             }
create or replace function public.exploration_site_create(p_request_id text, p_payload jsonb default '{}'::jsonb)
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
  -- (1) authn — reject the anonymous caller with a typed code (no world touch). [0243:136-138]
  if v_uid is null then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authenticated');
  end if;

  -- (2) authz — THE ONE guard. Non-owner authenticated caller is rejected server-side. [0243:141-144]
  if not public.is_owner() then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authorized');
  end if;

  -- (3) request_id is the idempotency key — it must be present. [0243:146-149]
  if p_request_id is null or length(btrim(p_request_id)) = 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;

  -- (4a) idempotent replay: a prior row for this request_id ⇒ return its result, no second apply. [0243:151-157]
  select result into v_prior from public.world_editor_audit where request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'request_id', p_request_id,
             'command_type', 'exploration_site_create', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  -- (5) SERVER-SIDE re-validation of the authoritative subset (p_payload->'fields'). The client's
  -- advisory validator (explorationValidation.ts) is NEVER trusted; every issue is collected into a
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
        'code', 'name_required', 'field', 'name', 'message', 'Name is required (exploration_sites.name is NOT NULL).'));
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
  -- constraint's table disambiguates: exploration_sites.name ⇒ typed 'conflict';
  -- world_editor_audit.request_id ⇒ a concurrent duplicate raced us ⇒ idempotent replay
  -- (and this call's site insert is undone by the sub-block rollback — no orphan row). [0243:161-170]
  begin
    insert into public.exploration_sites (name, space_x, space_y, reward_bundle_json)
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
        (v_uid, p_request_id, 'exploration_site_create', 'exploration_site', v_id::text, v_result::text,
         null, v_after, p_payload->>'source_revision');
  exception when unique_violation then
    get stacked diagnostics v_conflict_table = TABLE_NAME;
    if v_conflict_table = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'exploration_site_create', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'conflict',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'duplicate_name', 'field', 'name',
               'message', 'An exploration site with this name already exists.')));
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id,
           'command_type', 'exploration_site_create', 'result', v_result);
end $$;

comment on function public.exploration_site_create(text, jsonb) is
  'WORLD EDITOR PUBLISH SLICE (0244): the FIRST live-world-write command — creates ONE exploration '
  'site from an owner draft. Reproduces the 0243 template: authn → is_owner() authz → request_id '
  'idempotency → one audit row (with after_snapshot + source_revision) → typed envelope. Adds '
  'server-side re-validation (validation_failed + details[]) and a typed conflict on the unique '
  'name. Execute granted to authenticated (the guard enforces owner IN-BODY); NEVER to anon/public. '
  'The exploration_sites write happens only inside this SECURITY DEFINER body — no client grant.';

-- ── 3. ACL — authenticated may CALL (guard is in-body); anon/public may not. No table grant widened.
revoke all on function public.exploration_site_create(text, jsonb) from public;
grant execute on function public.exploration_site_create(text, jsonb) to authenticated;  -- guard is in-body; NEVER anon

-- Belt-and-braces NARROWING (the 0243 app_owners idiom): RLS already denies client writes to
-- exploration_sites (no policy, 0098), but the Supabase default table grants may still exist —
-- revoke the write grants so the privilege matrix is unambiguous and self-assertable. SELECT is left
-- exactly as it stands today (the editor's fail-closed read path is not this slice's concern).
revoke insert, update, delete on table public.exploration_sites from anon, authenticated;

-- ── 4. self-assert (deploy-time; any raise aborts the txn — nothing half-applies) ─────────────────
do $pubassert$
begin
  -- (a) the 0243 spine this command stands on exists.
  if to_regclass('public.app_owners') is null then
    raise exception 'PUBLISH-EXPLORATION self-assert FAIL: app_owners missing';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'PUBLISH-EXPLORATION self-assert FAIL: is_owner() missing';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'PUBLISH-EXPLORATION self-assert FAIL: world_editor_audit missing';
  end if;

  -- (b) the additive audit snapshot columns exist.
  if not exists (select 1 from pg_attribute
                 where attrelid = 'public.world_editor_audit'::regclass
                   and attname = 'before_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'after_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'source_revision' and not attisdropped) then
    raise exception 'PUBLISH-EXPLORATION self-assert FAIL: an audit snapshot column (before_snapshot/after_snapshot/source_revision) is missing';
  end if;

  -- (c) the command exists, is SECURITY DEFINER, and its ACL is authenticated-only.
  if to_regprocedure('public.exploration_site_create(text, jsonb)') is null then
    raise exception 'PUBLISH-EXPLORATION self-assert FAIL: exploration_site_create(text,jsonb) missing';
  end if;
  if not exists (select 1 from pg_proc
                 where oid = 'public.exploration_site_create(text,jsonb)'::regprocedure and prosecdef) then
    raise exception 'PUBLISH-EXPLORATION self-assert FAIL: exploration_site_create is not SECURITY DEFINER';
  end if;
  if not has_function_privilege('authenticated', 'public.exploration_site_create(text,jsonb)', 'execute') then
    raise exception 'PUBLISH-EXPLORATION self-assert FAIL: authenticated cannot execute exploration_site_create — the in-body guard would be unreachable';
  end if;
  if has_function_privilege('anon', 'public.exploration_site_create(text,jsonb)', 'execute') then
    raise exception 'PUBLISH-EXPLORATION self-assert FAIL: anon CAN execute exploration_site_create — must be authenticated-only';
  end if;

  -- (d) NO client-role write grant on exploration_sites — the write lives only inside the definer body.
  if has_table_privilege('authenticated', 'public.exploration_sites', 'INSERT')
     or has_table_privilege('authenticated', 'public.exploration_sites', 'UPDATE')
     or has_table_privilege('anon', 'public.exploration_sites', 'INSERT')
     or has_table_privilege('anon', 'public.exploration_sites', 'UPDATE') then
    raise exception 'PUBLISH-EXPLORATION self-assert FAIL: a client role holds an INSERT/UPDATE grant on exploration_sites — the only write path must be the SECURITY DEFINER command';
  end if;

  -- (e) the 0239 pirate-zone lockdown is STILL intact (this slice restored NO write privilege).
  if has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_zone_delete(uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'PUBLISH-EXPLORATION self-assert FAIL: a client role regained EXECUTE on a pirate_zone write RPC — the 0239 lockdown was disturbed';
  end if;

  raise notice 'PUBLISH-EXPLORATION self-assert ok: 0243 spine present; audit snapshot columns added; exploration_site_create SECURITY DEFINER + authenticated-only; no client write grant on exploration_sites; 0239 lockdown intact';
end $pubassert$;
