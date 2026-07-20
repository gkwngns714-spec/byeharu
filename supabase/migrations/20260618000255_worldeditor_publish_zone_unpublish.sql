-- Byeharu — WORLD EDITOR PUBLISHING SLICE: zone_unpublish — the owner-gated SAFE unpublish for the
-- 4th publish domain (zones), the twin of 0254 zone_create, through the 0243 contract.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT THIS IS: the canonical SAFE zone-unpublish command — flips ONE public.danger_zones row's
-- status from 'active' to 'inactive'. The danger_zones status CHECK already models both values
-- (0233:189 `status text ... check (status in ('active','inactive'))`); status='inactive' is the
-- ONLY unpublish (readers treat it as nonexistent), and NOTHING but status/updated_at is touched, so
-- the geometry, name, attach, source and created_by survive bit-for-bit and the row can later be
-- republished. There is NO hard delete here (the only historical hard-delete surface,
-- pirate_zone_delete (0239), stays locked to every client role and is re-asserted below).
--
-- WHY status='inactive' is a COMPLETE unpublish: all THREE player-active reads of danger_zones gate
-- on `status = 'active'` (0233): the RLS SELECT policy danger_zones_select_when_lit (0233:205), the
-- read RPC get_danger_zones() (0233:1387), and the sole interception geometry read
-- pirate_intercept_leg_zone_hits() (0233:321). Flipping status to 'inactive' removes the zone from
-- ALL THREE at once — player map, flag-gated read, and pirate interception — while preserving the row.
--
-- This body reproduces the 0250 set_active UNPUBLISH template step for step ((1) authn → typed
-- 'not_authenticated'; (2) authz via THE ONE guard public.is_owner() → 'not_authorized'; (3)
-- request_id idempotency against THE ONE ledger public.world_editor_audit; (4) exactly one audit row
-- per applied command with BOTH before/after snapshots; (5) a typed {ok,request_id,result|error}
-- envelope; (6) TARGETING: p_payload.target_id is the zone's uuid id (danger_zones has NO unique
-- natural key — name is not unique — so the PK is the addressing key, like 0249 location_update),
-- located AND ROW-LOCKED before anything is compared or written — a vanished target is 'not_found'
-- with details[{code:'source_missing'}]; (7) OPTIMISTIC CONCURRENCY: p_payload.expected is the
-- draft's fork-time sourceSnapshot, compared VALUE-BY-VALUE against the locked row over the fields the
-- zone read exposes (name/source/location_id) — any drift is 'stale_revision' with
-- details[{code:'source_changed',field:…}] and NOTHING is written) — plus the two guards a zone
-- unpublish adds that a field toggle does not have:
--
--   • ELIGIBILITY (fail-closed on invalid state, typed 'not_unpublishable'):
--       – source <> 'drawn'  ⇒ details[{code:'protected_zone'}]  — the 3 seeded 'circle' zones
--         (Blackden/Reaver/Snare and any future seed) can NEVER be unpublished; only editor-created
--         'drawn' zones (what 0254 zone_create writes) are unpublishable.
--       – status <> 'active' ⇒ details[{code:'already_inactive'}] — a zone that is already
--         unpublished is not re-unpublishable (a same-request replay is still the idempotent
--         success path via the request_id ledger; only a NEW request on an inactive zone is rejected).
--   • NO fields re-validation step and NO 'conflict' path: nothing authored is written and the flip
--     never touches a unique key, so the ONLY reachable unique_violation is
--     world_editor_audit.request_id (a concurrent duplicate raced us) ⇒ idempotent replay,
--     disambiguated via GET STACKED DIAGNOSTICS exactly like the templates.
--
-- DEPLOY POSTURE: UNDEPLOYED — deploy is a human gate. Fail-closed by design: even deployed, the
-- capability is inert until an owner is seeded into app_owners (is_owner() is false for everyone on
-- an unseeded DB). No client grant is widened anywhere: the danger_zones write happens INSIDE this
-- SECURITY DEFINER function only; the 0254 client write-grant revocation is ESTABLISHED again here
-- (idempotent — do NOT repeat the 0254 production-drift assumption that a prior migration left it
-- revoked) and then asserted.
--
-- NO-SPAGHETTI: no second owner check (is_owner() only), no second audit ledger, no second
-- idempotency key, no server-side fingerprint re-derivation (value equality is the one staleness
-- authority), no DELETE statement anywhere (status='inactive' is the one unpublish authority), no
-- reuse of the locked pirate_zone_create/delete surface, no new read RPC. zone_create /
-- get_danger_zones / world_editor_ping / the *_create/*_update/*_set_active commands are left
-- byte-identical; the 0244 audit snapshot columns are NOT re-added (the dependency gate asserts them).
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. dependency gate — abort loudly if the surfaces this slice builds on are missing ────────────
do $pubdep$
begin
  if to_regclass('public.danger_zones') is null then
    raise exception 'PUBLISH-ZONE-UNPUBLISH: public.danger_zones (0233) is missing — nothing to unpublish';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'PUBLISH-ZONE-UNPUBLISH: public.world_editor_audit (0243) is missing — the audit/idempotency spine must exist first';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'PUBLISH-ZONE-UNPUBLISH: public.is_owner() (0243) is missing — THE ONE owner guard must exist first';
  end if;
  if to_regprocedure('public.zone_create(text, jsonb)') is null then
    raise exception 'PUBLISH-ZONE-UNPUBLISH: public.zone_create(text,jsonb) (0254) is missing — the create twin this unpublish pairs with must exist';
  end if;
  if to_regprocedure('public.get_danger_zones()') is null then
    raise exception 'PUBLISH-ZONE-UNPUBLISH: public.get_danger_zones() (0233) is missing — the read this slice must NOT break must exist to be asserted';
  end if;
  -- the danger_zones.status column + its CHECK must model 'inactive' (0233) — the soft-unpublish target.
  if not exists (select 1 from pg_attribute
                 where attrelid = 'public.danger_zones'::regclass
                   and attname = 'status' and not attisdropped) then
    raise exception 'PUBLISH-ZONE-UNPUBLISH: danger_zones.status (0233) is missing — the soft-unpublish target column must exist';
  end if;
  -- the 0244 audit snapshot columns must already exist (this slice re-adds NOTHING; an unpublish USES both).
  if not exists (select 1 from pg_attribute
                 where attrelid = 'public.world_editor_audit'::regclass
                   and attname = 'before_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'after_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'source_revision' and not attisdropped) then
    raise exception 'PUBLISH-ZONE-UNPUBLISH: a 0244 audit snapshot column (before_snapshot/after_snapshot/source_revision) is missing — the snapshot columns must exist first';
  end if;
  if to_regprocedure('public.pirate_zone_create(text, jsonb, uuid)') is null
     or to_regprocedure('public.pirate_zone_delete(uuid)') is null then
    raise exception 'PUBLISH-ZONE-UNPUBLISH: a 0239 pirate_zone write RPC is missing — the lockdown surface must exist to be re-asserted';
  end if;
end $pubdep$;

-- ── 1. zone_unpublish — the zone UNPUBLISH command ────────────────────────────────────────────────
-- TYPED RESULT/ERROR CONTRACT (the 0250 vocabulary MINUS validation_failed/conflict, PLUS the zone
-- eligibility code not_unpublishable):
--   success : {ok:true,  request_id, command_type:'zone_unpublish', result:{unpublished:true,id,name,status:'inactive'}}
--   replay  : {ok:true,  request_id, command_type:'zone_unpublish', replayed:true, code:'duplicate_request', result:<prior jsonb>}
--   failure : {ok:false, request_id, error:<code> [, details:[{code,field,message}...]]}  where code ∈
--             { 'not_authenticated', 'not_authorized', 'invalid_request'  -- the 0243 vocabulary
--             , 'not_found'          -- target_id names no live zone (details: source_missing)
--             , 'stale_revision'     -- the locked live zone no longer matches `expected` (details: source_changed per field)
--             , 'not_unpublishable'  -- the zone exists but may not be unpublished (details: protected_zone | already_inactive)
--             }
-- p_payload = { target_id: <the zone's uuid id — danger_zones has no unique natural key>,
--               expected:  <the draft's sourceSnapshot: {name, source, location_id} at fork time> }
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

  -- (6b) ELIGIBILITY (fail-closed on invalid state) — the zone exists and matches the draft, but may
  -- still be ineligible to unpublish:
  --   • source <> 'drawn'  ⇒ a seeded/system zone (the 3 'circle' zones and any future seed). These
  --     are NEVER unpublishable through the editor — protected_zone.
  --   • status <> 'active' ⇒ already unpublished (a fresh request on an inactive zone is a no-op we
  --     reject rather than silently re-apply; a genuine replay is already the idempotent success path
  --     above). already_inactive.
  if v_live.source <> 'drawn' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_unpublishable',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'protected_zone', 'field', 'source',
               'message', 'Only editor-created (source=''drawn'') zones can be unpublished; this is a seeded zone.')));
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

comment on function public.zone_unpublish(text, jsonb) is
  'WORLD EDITOR PUBLISH SLICE (0255): the zone UNPUBLISH command and twin of 0254 zone_create — '
  'flips ONE public.danger_zones row from status=''active'' to ''inactive'' from an owner draft with '
  'OPTIMISTIC CONCURRENCY. status=''inactive'' is the CANONICAL safe unpublish: all three player-active '
  'reads (RLS danger_zones_select_when_lit, get_danger_zones(), pirate_intercept_leg_zone_hits()) gate '
  'on status=''active'', so the zone leaves the player map + flag-gated read + interception at once, '
  'while the row (geometry/name/attach/created_by) is preserved for a future republish. There is NO '
  'hard delete. Reproduces the 0243/0250 template: authn → is_owner() authz → request_id idempotency → '
  'one audit row (BOTH snapshots) → typed envelope; locates + ROW-LOCKS the target by uuid PK '
  '(danger_zones has no unique natural key; not_found/source_missing when gone), rejects fork-time '
  'drift with stale_revision/source_changed (name/source/location_id), and rejects ineligible targets '
  'with not_unpublishable (protected_zone for seeded source<>''drawn'' zones; already_inactive for '
  'non-active zones). Execute granted to authenticated (the guard enforces owner IN-BODY); NEVER to '
  'anon/public. The danger_zones write happens only inside this SECURITY DEFINER body — no client grant.';

-- ── 2. ACL — authenticated may CALL (guard is in-body); anon/public may not. No table grant widened.
revoke all on function public.zone_unpublish(text, jsonb) from public;
grant execute on function public.zone_unpublish(text, jsonb) to authenticated;  -- guard is in-body; NEVER anon

-- danger_zones is THIS command's write target: ESTABLISH the client write-path lockdown here rather
-- than assume 0254 already did it (the 0254 production-drift lesson — a Supabase project-default
-- GRANT ALL was live in prod until 0254 revoked it). Revoking a privilege a role does not hold is a
-- silent no-op, so this is idempotent and keeps the fresh-chain apply-proof green. SELECT is
-- preserved — the flag-gated zone read depends on it, and self-assert (d) verifies SELECT survives.
revoke insert, update, delete on table public.danger_zones from anon, authenticated;

-- ── 3. self-assert (deploy-time; any raise aborts the txn — nothing half-applies) ─────────────────
do $pubassert$
begin
  -- (a) the 0243 spine this command stands on exists.
  if to_regclass('public.app_owners') is null then
    raise exception 'PUBLISH-ZONE-UNPUBLISH self-assert FAIL: app_owners missing';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'PUBLISH-ZONE-UNPUBLISH self-assert FAIL: is_owner() missing';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'PUBLISH-ZONE-UNPUBLISH self-assert FAIL: world_editor_audit missing';
  end if;

  -- (b) the 0244 audit snapshot columns are present (an unpublish writes BOTH).
  if not exists (select 1 from pg_attribute
                 where attrelid = 'public.world_editor_audit'::regclass
                   and attname = 'before_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'after_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'source_revision' and not attisdropped) then
    raise exception 'PUBLISH-ZONE-UNPUBLISH self-assert FAIL: an audit snapshot column (before_snapshot/after_snapshot/source_revision) is missing';
  end if;

  -- (c) the command exists, is SECURITY DEFINER, and its ACL is authenticated-only.
  if to_regprocedure('public.zone_unpublish(text, jsonb)') is null then
    raise exception 'PUBLISH-ZONE-UNPUBLISH self-assert FAIL: zone_unpublish(text,jsonb) missing';
  end if;
  if not exists (select 1 from pg_proc
                 where oid = 'public.zone_unpublish(text,jsonb)'::regprocedure and prosecdef) then
    raise exception 'PUBLISH-ZONE-UNPUBLISH self-assert FAIL: zone_unpublish is not SECURITY DEFINER';
  end if;
  if not has_function_privilege('authenticated', 'public.zone_unpublish(text,jsonb)', 'execute') then
    raise exception 'PUBLISH-ZONE-UNPUBLISH self-assert FAIL: authenticated cannot execute zone_unpublish — the in-body guard would be unreachable';
  end if;
  if has_function_privilege('anon', 'public.zone_unpublish(text,jsonb)', 'execute') then
    raise exception 'PUBLISH-ZONE-UNPUBLISH self-assert FAIL: anon CAN execute zone_unpublish — must be authenticated-only';
  end if;

  -- (c2) the 0254 create twin is intact and still authenticated-only (this slice touched it not).
  if to_regprocedure('public.zone_create(text, jsonb)') is null then
    raise exception 'PUBLISH-ZONE-UNPUBLISH self-assert FAIL: zone_create(text,jsonb) twin vanished';
  end if;
  if not has_function_privilege('authenticated', 'public.zone_create(text,jsonb)', 'execute')
     or has_function_privilege('anon', 'public.zone_create(text,jsonb)', 'execute') then
    raise exception 'PUBLISH-ZONE-UNPUBLISH self-assert FAIL: the zone_create twin ACL was disturbed (must stay authenticated-only)';
  end if;

  -- (d) NO client-role write grant on danger_zones — the only write path is the SECURITY DEFINER
  -- command surface. SELECT itself must SURVIVE: the zone read (get_danger_zones + the flag-gated RLS
  -- policy) depends on it, and this slice narrowed nothing there.
  if has_table_privilege('authenticated', 'public.danger_zones', 'INSERT')
     or has_table_privilege('authenticated', 'public.danger_zones', 'UPDATE')
     or has_table_privilege('authenticated', 'public.danger_zones', 'DELETE')
     or has_table_privilege('anon', 'public.danger_zones', 'INSERT')
     or has_table_privilege('anon', 'public.danger_zones', 'UPDATE')
     or has_table_privilege('anon', 'public.danger_zones', 'DELETE') then
    raise exception 'PUBLISH-ZONE-UNPUBLISH self-assert FAIL: a client role holds a write grant on danger_zones — the only write path must be the SECURITY DEFINER command';
  end if;
  if not has_table_privilege('anon', 'public.danger_zones', 'SELECT')
     or not has_table_privilege('authenticated', 'public.danger_zones', 'SELECT') then
    raise exception 'PUBLISH-ZONE-UNPUBLISH self-assert FAIL: a client role LOST SELECT on danger_zones — the flag-gated zone read would break; this slice must add no narrowing there';
  end if;

  -- (e) the zone read is intact: get_danger_zones still exists and clients can still call it.
  if to_regprocedure('public.get_danger_zones()') is null then
    raise exception 'PUBLISH-ZONE-UNPUBLISH self-assert FAIL: get_danger_zones() vanished — the zone read is broken';
  end if;
  if not has_function_privilege('anon', 'public.get_danger_zones()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_danger_zones()', 'execute') then
    raise exception 'PUBLISH-ZONE-UNPUBLISH self-assert FAIL: a client role lost EXECUTE on get_danger_zones() — the zone read is broken';
  end if;

  -- (f) the 0239 pirate-zone lockdown is STILL intact (this slice touched NEITHER RPC: no client
  -- role may execute them; service_role keeps its owner-tooling grant).
  if has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_zone_delete(uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'PUBLISH-ZONE-UNPUBLISH self-assert FAIL: a client role regained EXECUTE on a pirate_zone write RPC — the 0239 lockdown was disturbed';
  end if;
  if not has_function_privilege('service_role', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or not has_function_privilege('service_role', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'PUBLISH-ZONE-UNPUBLISH self-assert FAIL: service_role LOST execute on a pirate_zone RPC — the 0239 owner-tooling path was disturbed';
  end if;

  raise notice 'PUBLISH-ZONE-UNPUBLISH self-assert ok: 0243 spine + snapshot columns present; zone_unpublish SECURITY DEFINER + authenticated-only; zone_create twin intact; no client write grant on danger_zones (SELECT intact); get_danger_zones intact; 0239 lockdown intact (service_role kept)';
end $pubassert$;
