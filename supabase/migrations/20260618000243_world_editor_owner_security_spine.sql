-- Byeharu — WORLD EDITOR V1B-0: OWNER SECURITY SPINE (mutation-READINESS only; ZERO world mutation).
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT THIS IS: the ONE reusable server-authoritative owner boundary + audit/idempotency/command
-- contracts that EVERY future World Editor command will call FIRST, built once as prerequisite #1
-- (docs/ZONE_TEMPLATES_ARCH.md §7 "Owner-only server-authoritative security model", §WE.10 "ONE
-- shared security + lifecycle + draft + audit framework"). Until this lands there is NO server-side
-- owner identity anywhere in byeharu (grep: no is_owner/is_admin/is_developer/app_owners exists) — the
-- World Editor's only gate is the CLIENT-side dev_zone_editor_enabled flag + the /dev route, which is
-- UX, never authorization (§8.8). This migration builds the REAL, server-authoritative one.
--
-- WHAT THIS IS NOT: it mutates NO world content. It creates NO location/mining/exploration/zone write
-- path, publishes NO blueprint, migrates NO coordinate, changes NO production flag, touches NO combat
-- and NO read-only-editor behavior. The ONLY function here that "does" anything is a guarded NO-OP
-- (world_editor_ping) that writes an audit row and returns — the contract/guard proof, nothing more.
--
-- DEPLOY POSTURE: this migration is UNDEPLOYED and must remain so pending separate review. Fail-closed
-- by design: with no owner seeded, is_owner() returns false for EVERYONE — nobody can command until
-- the out-of-git seed runs on the target. The seed below is idempotent and no-ops on a DB where the
-- owner's auth.users row does not exist (e.g. a fresh disposable proof DB — the proof seeds its own).
--
-- NO-SPAGHETTI: ONE owner authority (app_owners), ONE is_owner() predicate consulted by every command,
-- ONE audit writer path (the command entrypoint), ONE idempotency key (world_editor_audit.request_id
-- UNIQUE). No scattered owner-uuid literals, no per-command ad-hoc auth checks.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. dependency gate — the surfaces this slice PROMISES to leave intact must exist ──────────────
-- (never silently no-op: if the chain shape changed under us, abort loudly rather than assert nothing)
do $spinedep$
begin
  if to_regprocedure('public.pirate_zone_create(text, jsonb, uuid)') is null then
    raise exception 'OWNER-SPINE: public.pirate_zone_create(text,jsonb,uuid) is missing — the 0239 lockdown surface must exist to be re-asserted';
  end if;
  if to_regprocedure('public.pirate_zone_delete(uuid)') is null then
    raise exception 'OWNER-SPINE: public.pirate_zone_delete(uuid) is missing — the 0239 lockdown surface must exist to be re-asserted';
  end if;
  if to_regprocedure('public.get_world_map()') is null
     or to_regprocedure('public.get_danger_zones()') is null
     or to_regprocedure('public.get_active_mining_fields()') is null then
    raise exception 'OWNER-SPINE: a read-only World Editor RPC (get_world_map/get_danger_zones/get_active_mining_fields) is missing — this slice must not be the thing that removed it';
  end if;
end $spinedep$;

-- ── 1. app_owners — THE ONE owner allow-list (deny-all to game users) ─────────────────────────────
-- A dedicated typed table, NOT a profiles column: profiles has a player-writable UPDATE policy, so an
-- owner flag there would be SELF-PROMOTABLE (privilege escalation). This table has NO client write.
create table if not exists public.app_owners (
  user_id  uuid primary key references auth.users(id) on delete cascade,
  added_at timestamptz not null default now(),
  note     text
);

comment on table public.app_owners is
  'WORLD EDITOR OWNER SPINE (0243): the canonical owner allow-list. is_owner() is the single source of '
  'truth every World Editor command consults FIRST. RLS deny-all to anon/authenticated — populated ONLY '
  'by service_role / owner tooling via an out-of-git seed. NOT a profiles column (that would be '
  'self-promotable). Fail-closed: empty table ⇒ is_owner() false for everyone.';

alter table public.app_owners enable row level security;
-- Deny-all to the client roles at BOTH layers (RLS has no policy ⇒ no row is visible/writable; and we
-- revoke the Supabase default table grants belt-and-braces so the privilege matrix is unambiguous).
revoke all on table public.app_owners from anon, authenticated;

-- ── 2. is_owner() — THE ONE guard, server-authoritative, keyed off auth.uid() (NOT the Postgres role) ─
-- SECURITY DEFINER so it can read the deny-all app_owners table; STABLE; search_path pinned. Because it
-- checks auth.uid() (the JWT subject) inside the body, NO client flag/route and NO direct-RPC role can
-- bypass it — even a superuser calling with a non-owner JWT is rejected.
create or replace function public.is_owner()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.app_owners where user_id = auth.uid())
$$;

comment on function public.is_owner() is
  'WORLD EDITOR OWNER SPINE (0243): true iff the calling JWT subject (auth.uid()) is in app_owners. THE '
  'ONE authorization predicate every future World Editor command calls FIRST. Fail-closed (false for '
  'anon and for any non-listed user). Server-authoritative: the check is in-body on auth.uid(), so no '
  'client flag, route, or direct RPC role can bypass it.';

revoke all on function public.is_owner() from public;
grant execute on function public.is_owner() to authenticated;   -- NOT anon (fail-closed for the unauthenticated)

-- ── 3. world_editor_audit — THE ONE audit + idempotency contract ──────────────────────────────────
-- Sole writer = the command entrypoint (SECURITY DEFINER). request_id is the GLOBALLY-UNIQUE
-- idempotency key: a repeated request_id NEVER double-applies and NEVER writes a second row.
create table if not exists public.world_editor_audit (
  id          uuid primary key default gen_random_uuid(),
  actor       uuid not null,
  request_id  text not null unique,          -- idempotency key: one applied command per request_id
  command_type text not null,
  target_type text,
  target_id   text,
  result      text,                          -- the serialized typed result payload (for idempotent replay)
  created_at  timestamptz not null default now()
);

comment on table public.world_editor_audit is
  'WORLD EDITOR OWNER SPINE (0243): the audit + idempotency ledger for privileged World Editor commands. '
  'Sole writer = the command entrypoint (SECURITY DEFINER); RLS deny-all to clients. request_id is the '
  'GLOBALLY-UNIQUE idempotency key — a repeated request_id returns the prior result and writes no second '
  'row. result holds the serialized typed result payload so a replay returns byte-identical output.';

alter table public.world_editor_audit enable row level security;
revoke all on table public.world_editor_audit from anon, authenticated;

-- ── 4. world_editor_ping — THE CANONICAL guarded command entrypoint (NO-OP; contract proof only) ──
-- Demonstrates the pattern EVERY future command follows: (1) authn (auth.uid() non-null) → typed
-- 'not_authenticated'; (2) authz (is_owner()) → typed 'not_authorized'; (3) idempotent on request_id;
-- (4) writes ONE audit row; (5) returns a typed {ok,request_id,result|error} envelope. It performs
-- ZERO world mutation — it is the guard/contract proof, not a feature.
--
-- TYPED RESULT/ERROR CONTRACT (the vocabulary every command reuses):
--   success : {ok:true,  request_id, command_type, result:<jsonb>}
--   replay  : {ok:true,  request_id, command_type, replayed:true, code:'duplicate_request', result:<prior jsonb>}
--   failure : {ok:false, request_id, error:<code>}  where code ∈
--             { 'not_authenticated'  -- no JWT subject (anonymous)
--             , 'not_authorized'     -- authenticated but not in app_owners
--             , 'invalid_request'    -- missing/blank request_id
--             , 'duplicate_request'  -- (surfaced on the success-replay envelope above; reserved as a code)
--             }
create or replace function public.world_editor_ping(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_result jsonb;
  v_prior  text;
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
             'command_type', 'world_editor_ping', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  -- (4b) the NO-OP "work": build the typed result (ZERO world mutation) and record the audit row.
  v_result := jsonb_build_object('pong', true, 'payload', coalesce(p_payload, '{}'::jsonb));
  begin
    insert into public.world_editor_audit(actor, request_id, command_type, target_type, target_id, result)
      values (v_uid, p_request_id, 'world_editor_ping', 'none', null, v_result::text);
  exception when unique_violation then
    -- concurrent duplicate raced us to the insert — return the winner's result idempotently.
    select result into v_prior from public.world_editor_audit where request_id = p_request_id;
    return jsonb_build_object('ok', true, 'request_id', p_request_id,
             'command_type', 'world_editor_ping', 'replayed', true,
             'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id,
           'command_type', 'world_editor_ping', 'result', v_result);
end $$;

comment on function public.world_editor_ping(text, jsonb) is
  'WORLD EDITOR OWNER SPINE (0243): the canonical guarded command entrypoint, demonstrated by a NO-OP. '
  'Enforces authn (not_authenticated) → authz via is_owner() (not_authorized) → idempotency on '
  'request_id → one audit row → typed {ok,request_id,result|error} envelope. Performs ZERO world '
  'mutation (audit write only). Execute is granted to authenticated (the guard enforces owner IN-BODY); '
  'NEVER to anon/public. The template every future World Editor command reproduces.';

revoke all on function public.world_editor_ping(text, jsonb) from public;
grant execute on function public.world_editor_ping(text, jsonb) to authenticated;  -- guard is in-body; NEVER anon

-- ── 5. seed the real byeharu owner idempotently (no-op where that user does not exist) ────────────
-- On production this lights the owner once their auth.users row exists. On a fresh disposable proof DB
-- that user does not exist ⇒ 0 rows seeded (correct — the proof creates its OWN owner). Idempotent.
insert into public.app_owners (user_id)
  select id from auth.users where email = 'gkwngns714@gmail.com'
  on conflict (user_id) do nothing;

-- ── 6. self-assert (deploy-time; any raise aborts the txn — nothing half-applies) ─────────────────
do $spineassert$
begin
  -- (a) the spine exists and is shaped correctly.
  if to_regclass('public.app_owners') is null then
    raise exception 'OWNER-SPINE self-assert FAIL: app_owners table missing';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'OWNER-SPINE self-assert FAIL: world_editor_audit table missing';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'OWNER-SPINE self-assert FAIL: is_owner() missing';
  end if;
  if to_regprocedure('public.world_editor_ping(text, jsonb)') is null then
    raise exception 'OWNER-SPINE self-assert FAIL: world_editor_ping(text,jsonb) missing';
  end if;

  -- (b) is_owner() is SECURITY DEFINER (else it could not read the deny-all allow-list).
  if not exists (select 1 from pg_proc where oid = 'public.is_owner()'::regprocedure and prosecdef) then
    raise exception 'OWNER-SPINE self-assert FAIL: is_owner() is not SECURITY DEFINER';
  end if;

  -- (c) RLS is ON for both authoritative tables (deny-all to clients).
  if not (select relrowsecurity from pg_class where oid = 'public.app_owners'::regclass) then
    raise exception 'OWNER-SPINE self-assert FAIL: RLS not enabled on app_owners';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.world_editor_audit'::regclass) then
    raise exception 'OWNER-SPINE self-assert FAIL: RLS not enabled on world_editor_audit';
  end if;

  -- (d) idempotency key is enforced by a single-column UNIQUE constraint on request_id.
  if not exists (
    select 1
    from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
    where c.conrelid = 'public.world_editor_audit'::regclass
      and c.contype = 'u'
      and array_length(c.conkey, 1) = 1
      and a.attname = 'request_id'
  ) then
    raise exception 'OWNER-SPINE self-assert FAIL: world_editor_audit.request_id has no single-column UNIQUE constraint (idempotency unenforced)';
  end if;

  -- (e) command entrypoint ACL: authenticated MAY execute (guard is in-body); anon/public MAY NOT.
  if not has_function_privilege('authenticated', 'public.world_editor_ping(text,jsonb)', 'execute') then
    raise exception 'OWNER-SPINE self-assert FAIL: authenticated cannot execute world_editor_ping — the in-body guard would be unreachable';
  end if;
  if has_function_privilege('anon', 'public.world_editor_ping(text,jsonb)', 'execute') then
    raise exception 'OWNER-SPINE self-assert FAIL: anon CAN execute world_editor_ping — must be authenticated-only';
  end if;

  -- (f) app_owners is deny-all to the client roles (no INSERT/UPDATE/DELETE/SELECT grant leaked).
  if has_table_privilege('authenticated', 'public.app_owners', 'INSERT')
     or has_table_privilege('authenticated', 'public.app_owners', 'UPDATE')
     or has_table_privilege('authenticated', 'public.app_owners', 'DELETE')
     or has_table_privilege('authenticated', 'public.app_owners', 'SELECT')
     or has_table_privilege('anon', 'public.app_owners', 'SELECT') then
    raise exception 'OWNER-SPINE self-assert FAIL: a client role has a grant on app_owners — the allow-list must be deny-all to clients';
  end if;

  -- (g) the 0239 pirate-zone lockdown is STILL intact (this slice restored NO write privilege).
  if has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_zone_delete(uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'OWNER-SPINE self-assert FAIL: a client role regained EXECUTE on a pirate_zone write RPC — the 0239 lockdown was disturbed';
  end if;

  -- (h) the read-only World Editor surface is UNCHANGED (authenticated keeps execute on all three reads).
  if not has_function_privilege('authenticated', 'public.get_world_map()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_danger_zones()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_active_mining_fields()', 'execute') then
    raise exception 'OWNER-SPINE self-assert FAIL: a read-only World Editor RPC lost its authenticated execute grant — this slice must not touch the read surface';
  end if;

  raise notice 'OWNER-SPINE self-assert ok: app_owners + is_owner() + world_editor_audit(unique request_id) + guarded world_editor_ping present; deny-all allow-list; authenticated-only entrypoint; 0239 lockdown intact; read surface unchanged';
end $spineassert$;
