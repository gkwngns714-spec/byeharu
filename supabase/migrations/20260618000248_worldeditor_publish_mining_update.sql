-- Byeharu — WORLD EDITOR PUBLISHING SLICE 4: mining_field_update — the MINING TWIN of the 0247
-- exploration_site_update live-world-UPDATE publish command, owner-gated through the 0243 contract,
-- with OPTIMISTIC CONCURRENCY.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT THIS IS: the second World Editor command that EDITS existing world content — it UPDATEs one
-- row in public.mining_fields (the row an EDIT draft was forked from). It reproduces the 0247
-- exploration_site_update template step for step ((1) authn → typed 'not_authenticated'; (2) authz
-- via THE ONE guard public.is_owner() → typed 'not_authorized'; (3) request_id idempotency against
-- THE ONE ledger public.world_editor_audit; (4) exactly one audit row per applied command; (5) a
-- typed {ok,request_id,result|error} envelope; server-side re-validation with 'validation_failed' +
-- details[]; typed 'conflict' on the unique name) — mining_fields is the schema-identical twin of
-- exploration_sites (0103 mirrors 0098: name UNIQUE, space_x/space_y ±10000, reward_bundle_json
-- NOT NULL, RLS server-only), so the body carries over unchanged apart from the table:
--
--   • TARGETING: p_payload.target_id is the field's CURRENT name — the natural key the edit draft
--     forked from (the editor's read contract exposes no client-visible uuid; see
--     miningDraftModel.ts liveId). The live row is located AND ROW-LOCKED (select … for
--     update) before anything is compared or written. A vanished target is a typed 'not_found'
--     with details[{code:'source_missing'}].
--   • OPTIMISTIC CONCURRENCY: p_payload.expected is the draft's sourceSnapshot — the projected
--     field values AT FORK TIME (draftModel.ts forkEdit). The LOCKED live row is re-projected onto
--     the same fields and compared VALUE-BY-VALUE; any mismatch is a typed 'stale_revision' with
--     details[{code:'source_changed', field:<the differing field>}] and NOTHING is written. Value
--     equality is the ONE authority — the client fingerprint is deliberately NOT re-derived
--     server-side (re-implementing FNV-1a over JS JSON.stringify output would be a fragile second
--     copy; comparing the values themselves is robust AND names the exact drifted field).
--   • reward_bundle_json is UNOBSERVABLE client-side (0103: RLS server-only; the editor's read is
--     name + coords only — miningDraftTypes.ts), so an edit fork honestly carries null for it.
--     A JSON-null bundle therefore means "not observed / not authored", NOT "expected empty":
--     null in `expected` ⇒ the bundle is NOT compared; null in `fields` ⇒ the live bundle is KEPT
--     (the column is NOT NULL — null is never written). A NON-null bundle is fully validated,
--     compared, and applied like any other field.
--   • BEFORE/AFTER audit: the one audit row records BOTH before_snapshot (the locked row before
--     the write) and after_snapshot (the returned row after) — the 0244 columns, both used.
--
-- DEPLOY POSTURE: UNDEPLOYED — deploy is a human gate. Fail-closed by design: even deployed, the
-- capability is inert until an owner is seeded into app_owners (is_owner() is false for everyone on
-- an unseeded DB). No client grant is widened anywhere: the mining_fields write happens INSIDE
-- this SECURITY DEFINER function only; the 0246 write-grant revocation is re-asserted (never
-- re-granted) below.
--
-- NO-SPAGHETTI: no second owner check (is_owner() only), no second audit ledger, no second
-- idempotency key, no server-side fingerprint re-derivation (value equality is the one staleness
-- authority), no reuse of the mining gameplay RPC surface (command_mining_extract/securing
-- untouched). world_editor_ping / exploration_site_create / mining_field_create /
-- exploration_site_update are left byte-identical; the 0244 audit snapshot columns are NOT
-- re-added (the dependency gate asserts they exist).
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. dependency gate — abort loudly if the surfaces this slice builds on are missing ────────────
do $pubdep$
begin
  if to_regclass('public.mining_fields') is null then
    raise exception 'PUBLISH-MINING-UPDATE: public.mining_fields (0103) is missing — nothing to update';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'PUBLISH-MINING-UPDATE: public.world_editor_audit (0243) is missing — the audit/idempotency spine must exist first';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'PUBLISH-MINING-UPDATE: public.is_owner() (0243) is missing — THE ONE owner guard must exist first';
  end if;
  if to_regprocedure('public.mining_field_create(text, jsonb)') is null then
    raise exception 'PUBLISH-MINING-UPDATE: public.mining_field_create (0246) is missing — the mining publish template this extends must exist';
  end if;
  if to_regprocedure('public.exploration_site_update(text, jsonb)') is null then
    raise exception 'PUBLISH-MINING-UPDATE: public.exploration_site_update (0247) is missing — the UPDATE template this twins must exist';
  end if;
  -- the 0244 audit snapshot columns must already exist (this slice re-adds NOTHING; an update USES both).
  if not exists (select 1 from pg_attribute
                 where attrelid = 'public.world_editor_audit'::regclass
                   and attname = 'before_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'after_snapshot' and not attisdropped) then
    raise exception 'PUBLISH-MINING-UPDATE: a 0244 audit snapshot column (before_snapshot/after_snapshot) is missing — the snapshot columns must exist first';
  end if;
  if to_regprocedure('public.pirate_zone_create(text, jsonb, uuid)') is null
     or to_regprocedure('public.pirate_zone_delete(uuid)') is null then
    raise exception 'PUBLISH-MINING-UPDATE: a 0239 pirate_zone write RPC is missing — the lockdown surface must exist to be re-asserted';
  end if;
end $pubdep$;

-- ── 1. mining_field_update — the mining live-world-UPDATE command (0247 template, mining table) ────
-- TYPED RESULT/ERROR CONTRACT (extends the 0243/0246 vocabulary; identical to 0247):
--   success : {ok:true,  request_id, command_type, result:{updated:true,id,name}}
--   replay  : {ok:true,  request_id, command_type, replayed:true, code:'duplicate_request', result:<prior jsonb>}
--   failure : {ok:false, request_id, error:<code> [, details:[{code,field,message}...]]}  where code ∈
--             { 'not_authenticated', 'not_authorized', 'invalid_request'   -- the 0243 vocabulary
--             , 'not_found'          -- target_id names no live row (details: source_missing)
--             , 'stale_revision'     -- the locked live row no longer matches `expected` (details: source_changed per field)
--             , 'validation_failed'  -- the authoritative payload subset failed server re-validation
--             , 'conflict'           -- the NEW name collides with another field's unique name
--             }
-- p_payload = { target_id:      <the field's CURRENT name — the natural key the draft forked from>,
--               expected:       <the draft's sourceSnapshot: projected field values at fork time>,
--               fields:         <the new values: name, space_x, space_y, reward_bundle_json>,
--               source_revision:<the draft's forked fingerprint — audit trail only> }
create or replace function public.mining_field_update(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_target   text;
  v_expected jsonb;
  v_fields   jsonb;
  v_details  jsonb := '[]'::jsonb;
  v_name     text;
  v_x        numeric;
  v_y        numeric;
  v_bundle   jsonb;          -- null ⇒ keep the live bundle (unauthorable on an edit draft)
  v_items    jsonb;
  v_item     jsonb;
  v_i        int;
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
             'command_type', 'mining_field_update', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  -- (4b) structural addressing: an UPDATE cannot even be located without a target_id and an
  -- `expected` snapshot object — missing/malformed addressing is a malformed REQUEST (the 0243
  -- invalid_request code), not a field-validation report.
  v_target   := btrim(coalesce(p_payload->>'target_id', ''));
  v_expected := p_payload->'expected';
  if v_target = '' or v_expected is null or jsonb_typeof(v_expected) <> 'object' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;

  -- (5) LOCATE + ROW-LOCK the live target (name is the unique natural key, 0103). The lock holds
  -- until commit/rollback, so the compare-then-write below cannot race a concurrent editor.
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

  -- (6) OPTIMISTIC CONCURRENCY — re-project the LOCKED row onto the draft-carried fields and
  -- compare value-by-value with `expected` (the fork-time sourceSnapshot). Value equality is the
  -- authority (the client fingerprint is NOT re-derived — see header). Every drifted field is
  -- reported, then the whole command is rejected with NOTHING written. reward_bundle_json is
  -- compared ONLY when `expected` carries a non-null value: the live bundle is never
  -- client-readable (0103), so a fork's null means "unobservable", not "expected empty".
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

  -- (7) SERVER-SIDE re-validation of the authoritative subset (p_payload->'fields') — the SAME
  -- rules as mining_field_create (the client's advisory validator is NEVER trusted; every
  -- issue is collected so the client renders the full report). The ONE update-specific difference:
  -- a JSON-null reward_bundle_json is VALID here and means "keep the live bundle" (an edit draft
  -- cannot author the bundle it cannot read — miningDraftTypes.ts). Name UNIQUENESS is
  -- deliberately NOT pre-checked — the table's unique constraint is the one authority.
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
    if v_bundle is null or jsonb_typeof(v_bundle) = 'null' then
      v_bundle := null;   -- keep the live bundle (the update-specific null semantics, header §)
    elsif jsonb_typeof(v_bundle) <> 'object' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'reward_bundle_invalid', 'field', 'reward_bundle_json',
        'message', 'reward_bundle_json must be a JSON object with a non-empty items[] list (or null to keep the live bundle).'));
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

  -- (8) apply + audit in ONE sub-block: any unique_violation rolls BOTH back atomically. The
  -- constraint's table disambiguates: mining_fields.name (a RENAME collided with another
  -- field) ⇒ typed 'conflict'; world_editor_audit.request_id ⇒ a concurrent duplicate raced us ⇒
  -- idempotent replay (this call's UPDATE is undone by the sub-block rollback — no torn write).
  -- The row is addressed by its LOCKED primary key (same row the name lookup locked — name is
  -- unique and the lock precludes a concurrent rename).
  v_before := jsonb_build_object(
                'id', v_live.id, 'name', v_live.name, 'space_x', v_live.space_x,
                'space_y', v_live.space_y, 'reward_bundle_json', v_live.reward_bundle_json,
                'is_active', v_live.is_active, 'created_at', v_live.created_at);
  begin
    update public.mining_fields
       set name    = v_name,
           space_x = v_x::double precision,
           space_y = v_y::double precision,
           reward_bundle_json = coalesce(v_bundle, reward_bundle_json)
     where id = v_live.id
     returning jsonb_build_object(
                 'id', id, 'name', name, 'space_x', space_x, 'space_y', space_y,
                 'reward_bundle_json', reward_bundle_json, 'is_active', is_active,
                 'created_at', created_at),
               id
       into v_after, v_id;

    v_result := jsonb_build_object('updated', true, 'id', v_id, 'name', v_name);

    -- (9) exactly ONE audit row — an UPDATE records BOTH snapshots (the 0244 columns, both used).
    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'mining_field_update', 'mining_field', v_id::text, v_result::text,
         v_before, v_after, p_payload->>'source_revision');
  exception when unique_violation then
    get stacked diagnostics v_conflict_table = TABLE_NAME;
    if v_conflict_table = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'mining_field_update', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'conflict',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'duplicate_name', 'field', 'name',
               'message', 'A mining field with this name already exists.')));
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id,
           'command_type', 'mining_field_update', 'result', v_result);
end $$;

comment on function public.mining_field_update(text, jsonb) is
  'WORLD EDITOR PUBLISH SLICE (0248): the MINING twin of the 0247 live-world-UPDATE command — edits '
  'ONE mining field from an owner EDIT draft with OPTIMISTIC CONCURRENCY. Reproduces the 0243/0246 '
  'template: authn → is_owner() authz → request_id idempotency → one audit row → typed envelope; '
  'then locates + ROW-LOCKS the target by its natural key (payload.target_id = the current name; '
  'not_found/source_missing when gone), rejects any fork-time drift with stale_revision/'
  'source_changed (value-by-value against payload.expected — the client fingerprint is never '
  're-derived), re-validates the new fields server-side (validation_failed + details[]; a null '
  'reward_bundle_json means KEEP — the bundle is never client-readable), applies the UPDATE, and '
  'audits BOTH before_snapshot and after_snapshot. Typed conflict on a rename collision. Execute '
  'granted to authenticated (the guard enforces owner IN-BODY); NEVER to anon/public. The '
  'mining_fields write happens only inside this SECURITY DEFINER body — no client grant.';

-- ── 2. ACL — authenticated may CALL (guard is in-body); anon/public may not. No table grant widened.
revoke all on function public.mining_field_update(text, jsonb) from public;
grant execute on function public.mining_field_update(text, jsonb) to authenticated;  -- guard is in-body; NEVER anon

-- NOTE: the mining_fields client write grants were already revoked by 0246 (a pure narrowing).
-- This slice RE-ASSERTS that posture in the self-assert below and deliberately re-grants NOTHING.

-- ── 3. self-assert (deploy-time; any raise aborts the txn — nothing half-applies) ─────────────────
do $pubassert$
begin
  -- (a) the 0243 spine this command stands on exists.
  if to_regclass('public.app_owners') is null then
    raise exception 'PUBLISH-MINING-UPDATE self-assert FAIL: app_owners missing';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'PUBLISH-MINING-UPDATE self-assert FAIL: is_owner() missing';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'PUBLISH-MINING-UPDATE self-assert FAIL: world_editor_audit missing';
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
    raise exception 'PUBLISH-MINING-UPDATE self-assert FAIL: an audit snapshot column (before_snapshot/after_snapshot/source_revision) is missing';
  end if;

  -- (c) the command exists, is SECURITY DEFINER, and its ACL is authenticated-only.
  if to_regprocedure('public.mining_field_update(text, jsonb)') is null then
    raise exception 'PUBLISH-MINING-UPDATE self-assert FAIL: mining_field_update(text,jsonb) missing';
  end if;
  if not exists (select 1 from pg_proc
                 where oid = 'public.mining_field_update(text,jsonb)'::regprocedure and prosecdef) then
    raise exception 'PUBLISH-MINING-UPDATE self-assert FAIL: mining_field_update is not SECURITY DEFINER';
  end if;
  if not has_function_privilege('authenticated', 'public.mining_field_update(text,jsonb)', 'execute') then
    raise exception 'PUBLISH-MINING-UPDATE self-assert FAIL: authenticated cannot execute mining_field_update — the in-body guard would be unreachable';
  end if;
  if has_function_privilege('anon', 'public.mining_field_update(text,jsonb)', 'execute') then
    raise exception 'PUBLISH-MINING-UPDATE self-assert FAIL: anon CAN execute mining_field_update — must be authenticated-only';
  end if;

  -- (d) NO client-role write grant on mining_fields — the 0246 revocation is INTACT (this
  -- slice re-granted nothing; the only write path is the SECURITY DEFINER command surface).
  if has_table_privilege('authenticated', 'public.mining_fields', 'INSERT')
     or has_table_privilege('authenticated', 'public.mining_fields', 'UPDATE')
     or has_table_privilege('anon', 'public.mining_fields', 'INSERT')
     or has_table_privilege('anon', 'public.mining_fields', 'UPDATE') then
    raise exception 'PUBLISH-MINING-UPDATE self-assert FAIL: a client role holds an INSERT/UPDATE grant on mining_fields — the only write path must be the SECURITY DEFINER command';
  end if;

  -- (e) the 0239 pirate-zone lockdown is STILL intact (this slice restored NO write privilege).
  if has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_zone_delete(uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'PUBLISH-MINING-UPDATE self-assert FAIL: a client role regained EXECUTE on a pirate_zone write RPC — the 0239 lockdown was disturbed';
  end if;

  raise notice 'PUBLISH-MINING-UPDATE self-assert ok: 0243 spine + 0244 snapshot columns present; mining_field_update SECURITY DEFINER + authenticated-only; no client write grant on mining_fields; 0239 lockdown intact';
end $pubassert$;
