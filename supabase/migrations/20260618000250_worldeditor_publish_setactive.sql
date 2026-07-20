-- Byeharu — WORLD EDITOR PUBLISHING SLICE 6: exploration_site_set_active + mining_field_set_active —
-- the UNPUBLISH/RESTORE commands, owner-gated through the 0243 contract, with OPTIMISTIC CONCURRENCY.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT THIS IS: the canonical SAFE unpublish/re-publish surface — TWO twin commands that toggle
-- ONE row's is_active flag (0098 exploration_sites / 0103 mining_fields both carry
-- `is_active boolean not null default true`; readers/processors treat is_active=false as
-- nonexistent). There is NO hard delete anywhere in the World Editor: is_active=false is the ONLY
-- unpublish, and is_active=true restores the row bit-for-bit (nothing else is touched).
--
-- Both bodies reproduce the 0247/0248 UPDATE template step for step ((1) authn → typed
-- 'not_authenticated'; (2) authz via THE ONE guard public.is_owner() → typed 'not_authorized';
-- (3) request_id idempotency against THE ONE ledger public.world_editor_audit; (4) exactly one
-- audit row per applied command; (5) a typed {ok,request_id,result|error} envelope; (6) TARGETING:
-- p_payload.target_id is the row's CURRENT name, located AND ROW-LOCKED before anything is compared
-- or written — a vanished target is a typed 'not_found' with details[{code:'source_missing'}];
-- (7) OPTIMISTIC CONCURRENCY: p_payload.expected is the draft's fork-time sourceSnapshot, compared
-- VALUE-BY-VALUE against the locked row — any drift is a typed 'stale_revision' with
-- details[{code:'source_changed', field:…}] and NOTHING is written; reward_bundle_json is compared
-- ONLY when `expected` carries non-null, the SAME null-means-unobservable rule as 0247/0248) —
-- minus the parts a flag toggle does not have:
--
--   • NO fields re-validation step: is_active is the ONLY change, and its structural check
--     (p_payload.is_active must be a JSON boolean) belongs to the addressing gate — a payload that
--     cannot even say which way to flip is a malformed REQUEST ('invalid_request'), not a
--     field-validation report.
--   • NO 'conflict' path: the name is never modified, so the only reachable unique_violation is
--     world_editor_audit.request_id (a concurrent duplicate raced us) ⇒ idempotent replay —
--     disambiguated via GET STACKED DIAGNOSTICS exactly like the templates.
--   • BEFORE/AFTER audit: the one audit row records BOTH before_snapshot and after_snapshot — the
--     flag flip is fully reconstructible (and reversible by eye) from the ledger.
--
-- DEPLOY POSTURE: UNDEPLOYED — deploy is a human gate. Fail-closed by design: even deployed, the
-- capability is inert until an owner is seeded into app_owners (is_owner() is false for everyone on
-- an unseeded DB). No client grant is widened anywhere: both table writes happen INSIDE these
-- SECURITY DEFINER functions only; the 0244/0246 write-grant revocations are re-asserted (never
-- re-granted) below.
--
-- NO-SPAGHETTI: no second owner check (is_owner() only), no second audit ledger, no second
-- idempotency key, no server-side fingerprint re-derivation (value equality is the one staleness
-- authority), no DELETE statement anywhere (is_active is the one unpublish authority), no reuse of
-- the gameplay RPC surface (command_exploration_scan / command_mining_extract / securing untouched).
-- world_editor_ping / *_create / *_update / location_update are left byte-identical; the 0244 audit
-- snapshot columns are NOT re-added (the dependency gate asserts they exist).
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. dependency gate — abort loudly if the surfaces this slice builds on are missing ────────────
do $pubdep$
begin
  if to_regclass('public.exploration_sites') is null then
    raise exception 'PUBLISH-SETACTIVE: public.exploration_sites (0098) is missing — nothing to toggle';
  end if;
  if to_regclass('public.mining_fields') is null then
    raise exception 'PUBLISH-SETACTIVE: public.mining_fields (0103) is missing — nothing to toggle';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'PUBLISH-SETACTIVE: public.world_editor_audit (0243) is missing — the audit/idempotency spine must exist first';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'PUBLISH-SETACTIVE: public.is_owner() (0243) is missing — THE ONE owner guard must exist first';
  end if;
  if to_regprocedure('public.exploration_site_update(text, jsonb)') is null
     or to_regprocedure('public.mining_field_update(text, jsonb)') is null then
    raise exception 'PUBLISH-SETACTIVE: a 0247/0248 UPDATE command is missing — the optimistic-concurrency template this extends must exist';
  end if;
  -- the is_active columns this slice toggles must exist on BOTH tables (0098/0103).
  if not exists (select 1 from pg_attribute
                 where attrelid = 'public.exploration_sites'::regclass
                   and attname = 'is_active' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.mining_fields'::regclass
                      and attname = 'is_active' and not attisdropped) then
    raise exception 'PUBLISH-SETACTIVE: an is_active column (0098/0103) is missing — the soft-unpublish flag must exist';
  end if;
  -- the 0244 audit snapshot columns must already exist (this slice re-adds NOTHING; a toggle USES both).
  if not exists (select 1 from pg_attribute
                 where attrelid = 'public.world_editor_audit'::regclass
                   and attname = 'before_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'after_snapshot' and not attisdropped) then
    raise exception 'PUBLISH-SETACTIVE: a 0244 audit snapshot column (before_snapshot/after_snapshot) is missing — the snapshot columns must exist first';
  end if;
  if to_regprocedure('public.pirate_zone_create(text, jsonb, uuid)') is null
     or to_regprocedure('public.pirate_zone_delete(uuid)') is null then
    raise exception 'PUBLISH-SETACTIVE: a 0239 pirate_zone write RPC is missing — the lockdown surface must exist to be re-asserted';
  end if;
end $pubdep$;

-- ── 1. exploration_site_set_active — the exploration UNPUBLISH/RESTORE command ─────────────────────
-- TYPED RESULT/ERROR CONTRACT (the 0247 vocabulary MINUS validation_failed/conflict — a flag toggle
-- has no authored fields and never touches the unique name):
--   success : {ok:true,  request_id, command_type, result:{set_active:true,id,name,is_active}}
--   replay  : {ok:true,  request_id, command_type, replayed:true, code:'duplicate_request', result:<prior jsonb>}
--   failure : {ok:false, request_id, error:<code> [, details:[{code,field,message}...]]}  where code ∈
--             { 'not_authenticated', 'not_authorized', 'invalid_request'   -- the 0243 vocabulary
--             , 'not_found'          -- target_id names no live row (details: source_missing)
--             , 'stale_revision'     -- the locked live row no longer matches `expected` (details: source_changed per field)
--             }
-- p_payload = { target_id: <the site's CURRENT name — the natural key the edit draft forked from>,
--               expected:  <the draft's sourceSnapshot: projected field values at fork time>,
--               is_active: <boolean — false = unpublish (readers treat as nonexistent), true = restore> }
create or replace function public.exploration_site_set_active(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_target   text;
  v_expected jsonb;
  v_active   boolean;
  v_details  jsonb := '[]'::jsonb;
  v_live     record;         -- the LOCKED live row
  v_before   jsonb;
  v_after    jsonb;
  v_result   jsonb;
  v_prior    text;
  v_id       uuid;
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

  -- (4a) idempotent replay: a prior row for this request_id ⇒ return its result, no second apply. [0247:134-140]
  select result into v_prior from public.world_editor_audit where request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'request_id', p_request_id,
             'command_type', 'exploration_site_set_active', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  -- (4b) structural addressing: a toggle cannot even be located without a target_id and an
  -- `expected` snapshot object, and cannot be APPLIED without a boolean direction — any of the
  -- three missing/malformed is a malformed REQUEST (the 0243 invalid_request code), not a
  -- field-validation report (there are no authored fields to report on).
  v_target   := btrim(coalesce(p_payload->>'target_id', ''));
  v_expected := p_payload->'expected';
  if v_target = '' or v_expected is null or jsonb_typeof(v_expected) <> 'object'
     or jsonb_typeof(p_payload->'is_active') is distinct from 'boolean' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;
  v_active := (p_payload->>'is_active')::boolean;

  -- (5) LOCATE + ROW-LOCK the live target (name is the unique natural key, 0098). The lock holds
  -- until commit/rollback, so the compare-then-write below cannot race a concurrent editor.
  select id, name, space_x, space_y, reward_bundle_json, is_active, created_at
    into v_live
    from public.exploration_sites
   where name = v_target
     for update;
  if not found then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_found',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_missing', 'field', null,
               'message', 'No live exploration site named ''' || v_target || ''' exists — it may have been renamed or removed since the draft was forked.')));
  end if;

  -- (6) OPTIMISTIC CONCURRENCY — re-project the LOCKED row onto the draft-carried fields and
  -- compare value-by-value with `expected` (the fork-time sourceSnapshot). Value equality is the
  -- authority (the client fingerprint is NOT re-derived — 0247 header). Every drifted field is
  -- reported, then the whole command is rejected with NOTHING written. reward_bundle_json is
  -- compared ONLY when `expected` carries a non-null value: the live bundle is never
  -- client-readable (0098), so a fork's null means "unobservable", not "expected empty".
  if v_expected->>'name' is distinct from v_live.name then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'name',
      'message', 'The live site''s name changed since this draft was forked.'));
  end if;
  if v_expected->'space_x' is distinct from to_jsonb(v_live.space_x) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'space_x',
      'message', 'The live site''s space_x changed since this draft was forked.'));
  end if;
  if v_expected->'space_y' is distinct from to_jsonb(v_live.space_y) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'space_y',
      'message', 'The live site''s space_y changed since this draft was forked.'));
  end if;
  if v_expected->'reward_bundle_json' is not null
     and jsonb_typeof(v_expected->'reward_bundle_json') <> 'null'
     and v_expected->'reward_bundle_json' is distinct from v_live.reward_bundle_json then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'reward_bundle_json',
      'message', 'The live site''s reward bundle changed since this draft was forked.'));
  end if;
  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'stale_revision', 'details', v_details);
  end if;

  -- (7) apply + audit in ONE sub-block: any unique_violation rolls BOTH back atomically. The flag
  -- flip never touches the unique name, so the ONLY reachable unique_violation is
  -- world_editor_audit.request_id (a concurrent duplicate raced us) ⇒ idempotent replay —
  -- disambiguated via the constraint's table exactly like 0247/0248 (anything else re-raises).
  -- The row is addressed by its LOCKED primary key (same row the name lookup locked). NOTHING but
  -- is_active is written: an unpublish keeps every other column bit-for-bit, so a restore
  -- (is_active=true) brings back exactly the row that was unpublished. NO hard delete exists.
  v_before := jsonb_build_object(
                'id', v_live.id, 'name', v_live.name, 'space_x', v_live.space_x,
                'space_y', v_live.space_y, 'reward_bundle_json', v_live.reward_bundle_json,
                'is_active', v_live.is_active, 'created_at', v_live.created_at);
  begin
    update public.exploration_sites
       set is_active = v_active
     where id = v_live.id
     returning jsonb_build_object(
                 'id', id, 'name', name, 'space_x', space_x, 'space_y', space_y,
                 'reward_bundle_json', reward_bundle_json, 'is_active', is_active,
                 'created_at', created_at),
               id
       into v_after, v_id;

    v_result := jsonb_build_object('set_active', true, 'id', v_id, 'name', v_live.name, 'is_active', v_active);

    -- (8) exactly ONE audit row — a toggle records BOTH snapshots (the 0244 columns, both used).
    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'exploration_site_set_active', 'exploration_site', v_id::text, v_result::text,
         v_before, v_after, p_payload->>'source_revision');
  exception when unique_violation then
    get stacked diagnostics v_conflict_table = TABLE_NAME;
    if v_conflict_table = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'exploration_site_set_active', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    raise;   -- no other unique key is touchable by a flag flip — surface the anomaly loudly.
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id,
           'command_type', 'exploration_site_set_active', 'result', v_result);
end $$;

comment on function public.exploration_site_set_active(text, jsonb) is
  'WORLD EDITOR PUBLISH SLICE (0250): the exploration UNPUBLISH/RESTORE command — toggles ONE '
  'exploration site''s is_active flag from an owner EDIT draft with OPTIMISTIC CONCURRENCY. '
  'is_active=false is the CANONICAL safe unpublish (readers treat the row as nonexistent, 0098); '
  'is_active=true restores it bit-for-bit; there is NO hard delete. Reproduces the 0243/0247 '
  'template: authn → is_owner() authz → request_id idempotency → one audit row → typed envelope; '
  'locates + ROW-LOCKS the target by its natural key (payload.target_id = the current name; '
  'not_found/source_missing when gone), rejects any fork-time drift with stale_revision/'
  'source_changed (value-by-value against payload.expected), then writes ONLY is_active and audits '
  'BOTH before_snapshot and after_snapshot. Execute granted to authenticated (the guard enforces '
  'owner IN-BODY); NEVER to anon/public. The exploration_sites write happens only inside this '
  'SECURITY DEFINER body — no client grant.';

-- ── 2. mining_field_set_active — the byte-identical MINING twin (0103 mining_fields) ───────────────
-- Same contract, same payload shape, same vocabulary — only the table, the messages, and the
-- audit command_type/target_type differ (mining_fields is the schema-identical twin of
-- exploration_sites: name UNIQUE, coords, reward_bundle_json server-only, is_active default true).
create or replace function public.mining_field_set_active(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_target   text;
  v_expected jsonb;
  v_active   boolean;
  v_details  jsonb := '[]'::jsonb;
  v_live     record;         -- the LOCKED live row
  v_before   jsonb;
  v_after    jsonb;
  v_result   jsonb;
  v_prior    text;
  v_id       uuid;
  v_conflict_table text;
begin
  -- (1) authn — reject the anonymous caller with a typed code (no world touch).
  if v_uid is null then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authenticated');
  end if;

  -- (2) authz — THE ONE guard. Non-owner authenticated caller is rejected server-side.
  if not public.is_owner() then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authorized');
  end if;

  -- (3) request_id is the idempotency key — it must be present.
  if p_request_id is null or length(btrim(p_request_id)) = 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;

  -- (4a) idempotent replay: a prior row for this request_id ⇒ return its result, no second apply.
  select result into v_prior from public.world_editor_audit where request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'request_id', p_request_id,
             'command_type', 'mining_field_set_active', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  -- (4b) structural addressing: target_id + `expected` object + a boolean direction, or the
  -- request is malformed (invalid_request — there are no authored fields to report on).
  v_target   := btrim(coalesce(p_payload->>'target_id', ''));
  v_expected := p_payload->'expected';
  if v_target = '' or v_expected is null or jsonb_typeof(v_expected) <> 'object'
     or jsonb_typeof(p_payload->'is_active') is distinct from 'boolean' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;
  v_active := (p_payload->>'is_active')::boolean;

  -- (5) LOCATE + ROW-LOCK the live target (name is the unique natural key, 0103).
  select id, name, space_x, space_y, reward_bundle_json, is_active, created_at
    into v_live
    from public.mining_fields
   where name = v_target
     for update;
  if not found then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_found',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_missing', 'field', null,
               'message', 'No live mining field named ''' || v_target || ''' exists — it may have been renamed or removed since the draft was forked.')));
  end if;

  -- (6) OPTIMISTIC CONCURRENCY — value-by-value against the fork-time `expected` snapshot;
  -- reward_bundle_json compared ONLY when `expected` carries non-null (0103: never client-readable).
  if v_expected->>'name' is distinct from v_live.name then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'name',
      'message', 'The live field''s name changed since this draft was forked.'));
  end if;
  if v_expected->'space_x' is distinct from to_jsonb(v_live.space_x) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'space_x',
      'message', 'The live field''s space_x changed since this draft was forked.'));
  end if;
  if v_expected->'space_y' is distinct from to_jsonb(v_live.space_y) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'space_y',
      'message', 'The live field''s space_y changed since this draft was forked.'));
  end if;
  if v_expected->'reward_bundle_json' is not null
     and jsonb_typeof(v_expected->'reward_bundle_json') <> 'null'
     and v_expected->'reward_bundle_json' is distinct from v_live.reward_bundle_json then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'reward_bundle_json',
      'message', 'The live field''s reward bundle changed since this draft was forked.'));
  end if;
  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'stale_revision', 'details', v_details);
  end if;

  -- (7) apply + audit in ONE sub-block. The flag flip never touches the unique name, so the ONLY
  -- reachable unique_violation is world_editor_audit.request_id ⇒ idempotent replay. NOTHING but
  -- is_active is written — a restore brings back exactly the row that was unpublished. NO hard delete.
  v_before := jsonb_build_object(
                'id', v_live.id, 'name', v_live.name, 'space_x', v_live.space_x,
                'space_y', v_live.space_y, 'reward_bundle_json', v_live.reward_bundle_json,
                'is_active', v_live.is_active, 'created_at', v_live.created_at);
  begin
    update public.mining_fields
       set is_active = v_active
     where id = v_live.id
     returning jsonb_build_object(
                 'id', id, 'name', name, 'space_x', space_x, 'space_y', space_y,
                 'reward_bundle_json', reward_bundle_json, 'is_active', is_active,
                 'created_at', created_at),
               id
       into v_after, v_id;

    v_result := jsonb_build_object('set_active', true, 'id', v_id, 'name', v_live.name, 'is_active', v_active);

    -- (8) exactly ONE audit row — a toggle records BOTH snapshots (the 0244 columns, both used).
    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'mining_field_set_active', 'mining_field', v_id::text, v_result::text,
         v_before, v_after, p_payload->>'source_revision');
  exception when unique_violation then
    get stacked diagnostics v_conflict_table = TABLE_NAME;
    if v_conflict_table = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'mining_field_set_active', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    raise;   -- no other unique key is touchable by a flag flip — surface the anomaly loudly.
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id,
           'command_type', 'mining_field_set_active', 'result', v_result);
end $$;

comment on function public.mining_field_set_active(text, jsonb) is
  'WORLD EDITOR PUBLISH SLICE (0250): the mining twin of exploration_site_set_active — toggles ONE '
  'mining field''s is_active flag from an owner EDIT draft with OPTIMISTIC CONCURRENCY. '
  'is_active=false is the CANONICAL safe unpublish (readers treat the row as nonexistent, 0103); '
  'is_active=true restores it bit-for-bit; there is NO hard delete. Reproduces the 0243/0248 '
  'template: authn → is_owner() authz → request_id idempotency → one audit row → typed envelope; '
  'locates + ROW-LOCKS the target by its natural key, rejects fork-time drift with stale_revision/'
  'source_changed, then writes ONLY is_active and audits BOTH before_snapshot and after_snapshot. '
  'Execute granted to authenticated (the guard enforces owner IN-BODY); NEVER to anon/public. The '
  'mining_fields write happens only inside this SECURITY DEFINER body — no client grant.';

-- ── 3. ACL — authenticated may CALL (guard is in-body); anon/public may not. No table grant widened.
revoke all on function public.exploration_site_set_active(text, jsonb) from public;
grant execute on function public.exploration_site_set_active(text, jsonb) to authenticated;  -- guard is in-body; NEVER anon
revoke all on function public.mining_field_set_active(text, jsonb) from public;
grant execute on function public.mining_field_set_active(text, jsonb) to authenticated;      -- guard is in-body; NEVER anon

-- NOTE: the exploration_sites/mining_fields client write grants were already revoked by 0244/0246
-- (pure narrowings). This slice RE-ASSERTS that posture in the self-assert below and deliberately
-- re-grants NOTHING.

-- ── 4. self-assert (deploy-time; any raise aborts the txn — nothing half-applies) ─────────────────
do $pubassert$
begin
  -- (a) the 0243 spine this command stands on exists.
  if to_regclass('public.app_owners') is null then
    raise exception 'PUBLISH-SETACTIVE self-assert FAIL: app_owners missing';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'PUBLISH-SETACTIVE self-assert FAIL: is_owner() missing';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'PUBLISH-SETACTIVE self-assert FAIL: world_editor_audit missing';
  end if;

  -- (b) the 0244 audit snapshot columns are present (a toggle writes BOTH).
  if not exists (select 1 from pg_attribute
                 where attrelid = 'public.world_editor_audit'::regclass
                   and attname = 'before_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'after_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'source_revision' and not attisdropped) then
    raise exception 'PUBLISH-SETACTIVE self-assert FAIL: an audit snapshot column (before_snapshot/after_snapshot/source_revision) is missing';
  end if;

  -- (c) BOTH commands exist, are SECURITY DEFINER, and their ACL is authenticated-only.
  if to_regprocedure('public.exploration_site_set_active(text, jsonb)') is null then
    raise exception 'PUBLISH-SETACTIVE self-assert FAIL: exploration_site_set_active(text,jsonb) missing';
  end if;
  if to_regprocedure('public.mining_field_set_active(text, jsonb)') is null then
    raise exception 'PUBLISH-SETACTIVE self-assert FAIL: mining_field_set_active(text,jsonb) missing';
  end if;
  if not exists (select 1 from pg_proc
                 where oid = 'public.exploration_site_set_active(text,jsonb)'::regprocedure and prosecdef)
     or not exists (select 1 from pg_proc
                    where oid = 'public.mining_field_set_active(text,jsonb)'::regprocedure and prosecdef) then
    raise exception 'PUBLISH-SETACTIVE self-assert FAIL: a set_active command is not SECURITY DEFINER';
  end if;
  if not has_function_privilege('authenticated', 'public.exploration_site_set_active(text,jsonb)', 'execute')
     or not has_function_privilege('authenticated', 'public.mining_field_set_active(text,jsonb)', 'execute') then
    raise exception 'PUBLISH-SETACTIVE self-assert FAIL: authenticated cannot execute a set_active command — the in-body guard would be unreachable';
  end if;
  if has_function_privilege('anon', 'public.exploration_site_set_active(text,jsonb)', 'execute')
     or has_function_privilege('anon', 'public.mining_field_set_active(text,jsonb)', 'execute') then
    raise exception 'PUBLISH-SETACTIVE self-assert FAIL: anon CAN execute a set_active command — must be authenticated-only';
  end if;

  -- (d) NO client-role write grant on exploration_sites OR mining_fields — the 0244/0246
  -- revocations are INTACT (this slice re-granted nothing; the only write path is the SECURITY
  -- DEFINER command surface).
  if has_table_privilege('authenticated', 'public.exploration_sites', 'INSERT')
     or has_table_privilege('authenticated', 'public.exploration_sites', 'UPDATE')
     or has_table_privilege('anon', 'public.exploration_sites', 'INSERT')
     or has_table_privilege('anon', 'public.exploration_sites', 'UPDATE') then
    raise exception 'PUBLISH-SETACTIVE self-assert FAIL: a client role holds an INSERT/UPDATE grant on exploration_sites — the only write path must be the SECURITY DEFINER command';
  end if;
  if has_table_privilege('authenticated', 'public.mining_fields', 'INSERT')
     or has_table_privilege('authenticated', 'public.mining_fields', 'UPDATE')
     or has_table_privilege('anon', 'public.mining_fields', 'INSERT')
     or has_table_privilege('anon', 'public.mining_fields', 'UPDATE') then
    raise exception 'PUBLISH-SETACTIVE self-assert FAIL: a client role holds an INSERT/UPDATE grant on mining_fields — the only write path must be the SECURITY DEFINER command';
  end if;

  -- (e) the 0239 pirate-zone lockdown is STILL intact (this slice restored NO write privilege).
  if has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_zone_delete(uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'PUBLISH-SETACTIVE self-assert FAIL: a client role regained EXECUTE on a pirate_zone write RPC — the 0239 lockdown was disturbed';
  end if;

  raise notice 'PUBLISH-SETACTIVE self-assert ok: 0243 spine + snapshot columns present; exploration_site_set_active + mining_field_set_active SECURITY DEFINER + authenticated-only; no client write grant on exploration_sites/mining_fields; 0239 lockdown intact';
end $pubassert$;
