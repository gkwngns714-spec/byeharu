-- Byeharu — WORLD EDITOR PUBLISHING SLICE: zone_set_active — the owner-gated zone RE-ACTIVATE command
-- that closes the zone lifecycle-parity gap (a zone could be unpublished by 0255 zone_unpublish but
-- never re-activated). REACTIVATE-ONLY, COMPLEMENTING zone_unpublish — it does NOT supersede it.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT THIS IS: the canonical SAFE zone RE-ACTIVATE command — flips ONE public.danger_zones row's status
-- text from 'inactive' back to 'active' (the ONE direction 0255 zone_unpublish left missing), the
-- restore-half of the 0250 exploration_site_set_active / mining_field_set_active toggles adapted to the
-- zone status column. The danger_zones status CHECK already models both values (0233:189 `status text ...
-- check (status in ('active','inactive'))`); status='active' RESTORES the row into all three player-active
-- reads at once (the RLS SELECT policy danger_zones_select_when_lit (0233:205), get_danger_zones()
-- (0233), and pirate_intercept_leg_zone_hits() (0233:321) all gate on status='active'). NOTHING but
-- status/updated_at is ever written, so id/zone_kind/geometry(boundary)/source/location_id/created_by/
-- created_at survive BIT-FOR-BIT — no geometry editing happens in this RPC. There is NO hard delete here
-- (the only historical hard-delete surface, pirate_zone_delete (0239), stays locked to every client role
-- and is re-asserted below).
--
-- COMPLEMENT (NOT supersede) POSTURE: zone_unpublish (0255) remains the SOLE deactivate path (active→
-- inactive) and is LEFT byte-identical + intact (its ACL is re-asserted below). zone_set_active adds ONLY
-- the reverse edge (inactive→active). Deterministic direction: this command REQUIRES the target to be
-- currently INACTIVE — a target that is ALREADY ACTIVE is rejected with a typed validation_failed
-- {already_active} and NOTHING is written (it never silently no-ops or double-toggles). Together the two
-- commands are the complete, symmetric zone lifecycle: zone_unpublish down, zone_set_active up.
--
-- This body reproduces the 0250 set_active template step for step ((1) authn → typed 'not_authenticated';
-- (2) authz via THE ONE guard public.is_owner() → 'not_authorized'; (3) request_id idempotency against
-- THE ONE ledger public.world_editor_audit — CHECKED BEFORE the stale-revision compare; (4) exactly one
-- audit row per applied command with BOTH before/after snapshots; (5) a typed {ok,request_id,result|error}
-- envelope; (6) TARGETING: p_payload.target_id is the zone's uuid id (danger_zones has NO unique natural
-- key — name is not unique — so the PK is the addressing key, the 0255/0266 zone variant), located AND
-- ROW-LOCKED (FOR UPDATE) before anything is compared or written — a vanished target is 'not_found' with
-- details[{code:'source_missing'}]; (7) OPTIMISTIC CONCURRENCY: p_payload.expected is the draft's
-- fork-time sourceSnapshot, compared VALUE-BY-VALUE against the locked row over the fields the zone read
-- exposes (name/source/location_id, the 0255 idiom) — any drift is 'stale_revision' with details[{code:
-- 'source_changed',field:…}] and NOTHING is written) — plus the two guards a zone re-activate adds:
--
--   • SEEDED-ZONE PROTECTION (fail-closed): source <> 'drawn' ⇒ a typed validation_failed with
--     details[{code:'protected_zone'}] — the 3 seeded 'circle' zones (Blackden/Reaver/Snare and any
--     future seed) can NEVER be toggled through the editor; only editor-created 'drawn' zones (what 0254
--     zone_create writes) are toggleable. The EXACT guard 0255 zone_unpublish and 0266 zone_update
--     enforce; surfaced through validation_failed + protected_zone (the 0266 idiom — no new top-level code).
--   • ALREADY-ACTIVE (deterministic reactivate-only): status <> 'inactive' ⇒ a typed validation_failed
--     with details[{code:'already_active'}] — this command only RE-activates; an already-active zone is
--     not re-activatable (a same-request replay is still the idempotent success path via the request_id
--     ledger; only a NEW request on an active zone is rejected). Deactivation is zone_unpublish's job.
--   • NO fields re-validation step and NO 'conflict' path: nothing authored is written and the flip never
--     touches a unique key, so the ONLY reachable unique_violation is world_editor_audit.request_id (a
--     concurrent duplicate raced us) ⇒ idempotent replay, disambiguated via GET STACKED DIAGNOSTICS.
--
-- DEPLOY POSTURE: UNDEPLOYED — deploy is a human gate. Fail-closed by design: even deployed, the
-- capability is inert until an owner is seeded into app_owners (is_owner() is false for everyone on an
-- unseeded DB). No client grant is widened anywhere: the danger_zones write happens INSIDE this SECURITY
-- DEFINER function only; the client write-grant revocation is ESTABLISHED again here (idempotent — do NOT
-- assume a prior migration left it revoked; the 0254 production-drift lesson) and then asserted.
--
-- NO-SPAGHETTI: no second owner check (is_owner() only), no second audit ledger, no second idempotency
-- key, no server-side fingerprint re-derivation (value equality is the one staleness authority), no
-- DELETE statement anywhere (status is the one lifecycle authority), no reuse of the locked
-- pirate_zone_create/delete surface, no new read RPC, no new top-level error code (protected_zone /
-- already_active ride the existing validation_failed details pipeline), no NEW column (danger_zones has
-- no revision column — updated_at is the ONE mutation timestamp and is bumped). zone_create /
-- zone_unpublish / zone_update / get_danger_zones / world_editor_ping and the prior publish commands are
-- left byte-identical; the 0244 audit snapshot columns are NOT re-added (the dependency gate asserts them).
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. dependency gate — abort loudly if the surfaces this slice builds on are missing ────────────
do $pubdep$
begin
  if to_regclass('public.danger_zones') is null then
    raise exception 'PUBLISH-ZONE-SETACTIVE: public.danger_zones (0233) is missing — nothing to reactivate';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'PUBLISH-ZONE-SETACTIVE: public.world_editor_audit (0243) is missing — the audit/idempotency spine must exist first';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'PUBLISH-ZONE-SETACTIVE: public.is_owner() (0243) is missing — THE ONE owner guard must exist first';
  end if;
  if to_regprocedure('public.zone_unpublish(text, jsonb)') is null then
    raise exception 'PUBLISH-ZONE-SETACTIVE: public.zone_unpublish(text,jsonb) (0255) is missing — the deactivate half this complements must exist';
  end if;
  if to_regprocedure('public.get_danger_zones()') is null then
    raise exception 'PUBLISH-ZONE-SETACTIVE: public.get_danger_zones() (0233) is missing — the read this slice must NOT break must exist to be asserted';
  end if;
  -- the danger_zones.status column + its CHECK must model BOTH 'active' and 'inactive' (0233) — the two
  -- lifecycle states this reactivate flips between.
  if not exists (select 1 from pg_attribute
                 where attrelid = 'public.danger_zones'::regclass
                   and attname = 'status' and not attisdropped) then
    raise exception 'PUBLISH-ZONE-SETACTIVE: danger_zones.status (0233) is missing — the lifecycle target column must exist';
  end if;
  -- the 0244 audit snapshot columns must already exist (this slice re-adds NOTHING; a toggle USES both).
  if not exists (select 1 from pg_attribute
                 where attrelid = 'public.world_editor_audit'::regclass
                   and attname = 'before_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'after_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'source_revision' and not attisdropped) then
    raise exception 'PUBLISH-ZONE-SETACTIVE: a 0244 audit snapshot column (before_snapshot/after_snapshot/source_revision) is missing — the snapshot columns must exist first';
  end if;
  if to_regprocedure('public.pirate_zone_create(text, jsonb, uuid)') is null
     or to_regprocedure('public.pirate_zone_delete(uuid)') is null then
    raise exception 'PUBLISH-ZONE-SETACTIVE: a 0239 pirate_zone write RPC is missing — the lockdown surface must exist to be re-asserted';
  end if;
end $pubdep$;

-- ── 1. zone_set_active — the zone RE-ACTIVATE command (inactive → active only) ─────────────────────
-- TYPED RESULT/ERROR CONTRACT (the 0250 set_active vocabulary, PLUS the zone eligibility codes
-- protected_zone / already_active riding validation_failed — the 0266 details idiom):
--   success : {ok:true,  request_id, command_type:'zone_set_active', result:{set_active:true,id,name,status:'active'}}
--   replay  : {ok:true,  request_id, command_type:'zone_set_active', replayed:true, code:'duplicate_request', result:<prior jsonb>}
--   failure : {ok:false, request_id, error:<code> [, details:[{code,field,message}...]]}  where code ∈
--             { 'not_authenticated', 'not_authorized', 'invalid_request'  -- the 0243 vocabulary
--             , 'not_found'          -- target_id names no live zone (details: source_missing)
--             , 'stale_revision'     -- the locked live zone no longer matches `expected` (details: source_changed per field)
--             , 'validation_failed'  -- the target is ineligible; details carry protected_zone (seeded) | already_active
--             }
-- p_payload = { target_id: <the zone's uuid id — danger_zones has no unique natural key>,
--               expected:  <the draft's sourceSnapshot: {name, source, location_id} at fork time>,
--               source_revision: <optional client draft fingerprint — audit trail only> }
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

  -- (6b) SEEDED-ZONE PROTECTION (fail-closed) — only editor-created source='drawn' zones are toggleable.
  -- The seeded source='circle' zones (and any future seed) can NEVER be reactivated through the editor:
  -- a typed validation_failed {protected_zone} (the 0266 zone_update guard — no new top-level error code).
  if v_live.source <> 'drawn' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'validation_failed', 'details', jsonb_build_array(jsonb_build_object(
               'code', 'protected_zone', 'field', 'source',
               'message', 'Only editor-created (source=''drawn'') zones can be reactivated; this is a seeded zone.')));
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

comment on function public.zone_set_active(text, jsonb) is
  'WORLD EDITOR PUBLISH SLICE (0268): the owner-gated zone RE-ACTIVATE command that closes the zone '
  'lifecycle-parity gap — flips ONE public.danger_zones row''s status from ''inactive'' back to ''active'' '
  '(the ONE direction the one-way 0255 zone_unpublish left missing), the restore-half of the 0250 '
  'exploration/mining set_active toggles on the zone status column. REACTIVATE-ONLY and COMPLEMENTS '
  'zone_unpublish (left intact as the deactivate path): it REQUIRES the target to be currently INACTIVE — '
  'an already-active zone is rejected with validation_failed {already_active}, nothing written. '
  'status=''active'' restores the zone into all three player-active reads (RLS danger_zones_select_when_lit, '
  'get_danger_zones(), pirate_intercept_leg_zone_hits()) at once; NOTHING but status+updated_at is written '
  '(id/zone_kind/geometry/source/location_id/created_by preserved bit-for-bit); NO geometry editing; NO '
  'hard delete. Reproduces the 0243/0250 template: authn → is_owner() authz → request_id idempotency '
  '(checked BEFORE stale) → one audit row (BOTH snapshots) → typed envelope; locates + ROW-LOCKS the '
  'target by uuid PK (danger_zones has no unique natural key; not_found/source_missing when gone), rejects '
  'fork-time drift with stale_revision/source_changed (name/source/location_id), rejects a seeded '
  'source<>''drawn'' target with validation_failed {protected_zone} (the 0266 guard). Execute granted to '
  'authenticated (the guard enforces owner IN-BODY); NEVER to anon/public. The danger_zones write happens '
  'only inside this SECURITY DEFINER body — no client grant.';

-- ── 2. ACL — authenticated may CALL (guard is in-body); anon/public may not. No table grant widened.
revoke all on function public.zone_set_active(text, jsonb) from public;
grant execute on function public.zone_set_active(text, jsonb) to authenticated;  -- guard is in-body; NEVER anon

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
    raise exception 'PUBLISH-ZONE-SETACTIVE self-assert FAIL: app_owners missing';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'PUBLISH-ZONE-SETACTIVE self-assert FAIL: is_owner() missing';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'PUBLISH-ZONE-SETACTIVE self-assert FAIL: world_editor_audit missing';
  end if;

  -- (b) the 0244 audit snapshot columns are present (a reactivate writes BOTH).
  if not exists (select 1 from pg_attribute
                 where attrelid = 'public.world_editor_audit'::regclass
                   and attname = 'before_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'after_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'source_revision' and not attisdropped) then
    raise exception 'PUBLISH-ZONE-SETACTIVE self-assert FAIL: an audit snapshot column (before_snapshot/after_snapshot/source_revision) is missing';
  end if;

  -- (c) the command exists, is SECURITY DEFINER, pins search_path, and its ACL is authenticated-only.
  if to_regprocedure('public.zone_set_active(text, jsonb)') is null then
    raise exception 'PUBLISH-ZONE-SETACTIVE self-assert FAIL: zone_set_active(text,jsonb) missing';
  end if;
  if not exists (select 1 from pg_proc
                 where oid = 'public.zone_set_active(text,jsonb)'::regprocedure and prosecdef) then
    raise exception 'PUBLISH-ZONE-SETACTIVE self-assert FAIL: zone_set_active is not SECURITY DEFINER';
  end if;
  if not exists (select 1 from pg_proc p
                 where p.oid = 'public.zone_set_active(text,jsonb)'::regprocedure
                   and exists (select 1 from unnest(p.proconfig) cfg where cfg like 'search_path=%')) then
    raise exception 'PUBLISH-ZONE-SETACTIVE self-assert FAIL: zone_set_active does not pin search_path — a search_path hijack would be possible';
  end if;
  if not has_function_privilege('authenticated', 'public.zone_set_active(text,jsonb)', 'execute') then
    raise exception 'PUBLISH-ZONE-SETACTIVE self-assert FAIL: authenticated cannot execute zone_set_active — the in-body guard would be unreachable';
  end if;
  if has_function_privilege('anon', 'public.zone_set_active(text,jsonb)', 'execute') then
    raise exception 'PUBLISH-ZONE-SETACTIVE self-assert FAIL: anon CAN execute zone_set_active — must be authenticated-only';
  end if;

  -- (c2) the function body writes ONLY danger_zones and NEVER touches the 0239-locked pirate_zone_*
  -- surface (a cheap, robust source-text guard — the reactivate target must be danger_zones alone).
  if position('pirate_zone' in pg_get_functiondef('public.zone_set_active(text,jsonb)'::regprocedure)) > 0 then
    raise exception 'PUBLISH-ZONE-SETACTIVE self-assert FAIL: zone_set_active body references pirate_zone — it must not touch the 0239-locked surface';
  end if;
  if position('danger_zones' in pg_get_functiondef('public.zone_set_active(text,jsonb)'::regprocedure)) = 0 then
    raise exception 'PUBLISH-ZONE-SETACTIVE self-assert FAIL: zone_set_active body does not reference danger_zones — the reactivate target is wrong';
  end if;

  -- (c3) the 0255 unpublish twin (this slice COMPLEMENTS, never supersedes it) is intact + authenticated-
  -- only, and the 0254 create + 0266 update twins are untouched.
  if not has_function_privilege('authenticated', 'public.zone_unpublish(text,jsonb)', 'execute')
     or has_function_privilege('anon', 'public.zone_unpublish(text,jsonb)', 'execute') then
    raise exception 'PUBLISH-ZONE-SETACTIVE self-assert FAIL: the zone_unpublish twin ACL was disturbed (must stay authenticated-only)';
  end if;
  if not has_function_privilege('authenticated', 'public.zone_create(text,jsonb)', 'execute')
     or has_function_privilege('anon', 'public.zone_create(text,jsonb)', 'execute') then
    raise exception 'PUBLISH-ZONE-SETACTIVE self-assert FAIL: the zone_create twin ACL was disturbed (must stay authenticated-only)';
  end if;
  if not has_function_privilege('authenticated', 'public.zone_update(text,jsonb)', 'execute')
     or has_function_privilege('anon', 'public.zone_update(text,jsonb)', 'execute') then
    raise exception 'PUBLISH-ZONE-SETACTIVE self-assert FAIL: the zone_update twin ACL was disturbed (must stay authenticated-only)';
  end if;

  -- (d) NO client-role write grant on danger_zones — the only write path is the SECURITY DEFINER command
  -- surface. SELECT itself must SURVIVE: the flag-gated zone read (get_danger_zones + RLS) depends on it.
  if has_table_privilege('authenticated', 'public.danger_zones', 'INSERT')
     or has_table_privilege('authenticated', 'public.danger_zones', 'UPDATE')
     or has_table_privilege('authenticated', 'public.danger_zones', 'DELETE')
     or has_table_privilege('anon', 'public.danger_zones', 'INSERT')
     or has_table_privilege('anon', 'public.danger_zones', 'UPDATE')
     or has_table_privilege('anon', 'public.danger_zones', 'DELETE') then
    raise exception 'PUBLISH-ZONE-SETACTIVE self-assert FAIL: a client role holds a write grant on danger_zones — the only write path must be the SECURITY DEFINER command';
  end if;
  if not has_table_privilege('anon', 'public.danger_zones', 'SELECT')
     or not has_table_privilege('authenticated', 'public.danger_zones', 'SELECT') then
    raise exception 'PUBLISH-ZONE-SETACTIVE self-assert FAIL: a client role LOST SELECT on danger_zones — the flag-gated zone read would break; this slice must narrow writes only';
  end if;

  -- (e) the zone read is intact: get_danger_zones still exists and clients can still call it.
  if to_regprocedure('public.get_danger_zones()') is null then
    raise exception 'PUBLISH-ZONE-SETACTIVE self-assert FAIL: get_danger_zones() vanished — the zone read is broken';
  end if;
  if not has_function_privilege('anon', 'public.get_danger_zones()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_danger_zones()', 'execute') then
    raise exception 'PUBLISH-ZONE-SETACTIVE self-assert FAIL: a client role lost EXECUTE on get_danger_zones() — the zone read is broken';
  end if;

  -- (f) the 0239 pirate-zone lockdown is STILL intact (this slice touched NEITHER RPC: no client role
  -- may execute them; service_role keeps its owner-tooling grant).
  if has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_zone_delete(uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'PUBLISH-ZONE-SETACTIVE self-assert FAIL: a client role regained EXECUTE on a pirate_zone write RPC — the 0239 lockdown was disturbed';
  end if;
  if not has_function_privilege('service_role', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or not has_function_privilege('service_role', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'PUBLISH-ZONE-SETACTIVE self-assert FAIL: service_role LOST execute on a pirate_zone RPC — the 0239 owner-tooling path was disturbed';
  end if;

  raise notice 'PUBLISH-ZONE-SETACTIVE self-assert ok: 0243 spine + snapshot columns present; zone_set_active SECURITY DEFINER + search_path='''' + authenticated-only; body writes danger_zones only (no pirate_zone_*); create/unpublish/update twins intact; no client write grant on danger_zones (SELECT intact); get_danger_zones intact; 0239 lockdown intact (service_role kept)';
end $pubassert$;
