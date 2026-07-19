-- WORLD EDITOR OWNER-SPINE — disposable apply-proof (run against a THROWAWAY local Supabase ONLY).
--
-- Proves migration 0243 (20260618000243_world_editor_owner_security_spine.sql) after the FULL chain is
-- applied by `supabase start`: the server-authoritative owner boundary ACCEPTS the owner, REJECTS the
-- non-owner and the anonymous caller, cannot be bypassed by any client flag or by direct/authenticated
-- RPC invocation, is idempotent on request_id, restores NO pirate-zone write privilege, and leaves the
-- read-only World Editor surface untouched.
--
-- Self-rolling-back: everything runs inside one begin;...rollback; — ZERO persisted state, no flag
-- flipped, no world row touched. The owner it "seeds" is a synthetic auth.users row created HERE (the
-- real byeharu owner does not exist in a disposable DB, so migration 0243's own seed is a 0-row no-op,
-- as intended). NEVER point this at production.

\set ON_ERROR_STOP on

begin;

-- ── fixtures: a synthetic OWNER and a synthetic NON-OWNER (real auth.users rows for the FK) ────────
create temp table spineids(k text primary key, v uuid) on commit drop;
insert into spineids values ('owner', gen_random_uuid()), ('nonowner', gen_random_uuid());

insert into auth.users
  (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
   confirmation_token,recovery_token,email_change_token_new,email_change)
select '00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated',
       'spine.'||k||'.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','',''
from spineids;

-- seed ONLY the owner into the allow-list (as superuser — the deny-all table has no client write path).
insert into public.app_owners(user_id) select v from spineids where k = 'owner';

-- ── PROOF 1 — OWNER is ACCEPTED by is_owner() and world_editor_ping ────────────────────────────────
do $$
declare v_owner uuid; r jsonb;
begin
  select v into v_owner from spineids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  if not public.is_owner() then
    raise exception 'OWNERSPINE PROOF FAIL: is_owner() returned false for the seeded owner';
  end if;
  r := public.world_editor_ping('spine-owner-req-1', jsonb_build_object('hello','owner'));
  if (r->>'ok')::boolean is not true then
    raise exception 'OWNERSPINE PROOF FAIL: owner world_editor_ping not ok: %', r;
  end if;
  if (r->'result'->>'pong') <> 'true' then
    raise exception 'OWNERSPINE PROOF FAIL: owner ping result missing pong: %', r;
  end if;
  if not exists (select 1 from public.world_editor_audit where request_id = 'spine-owner-req-1') then
    raise exception 'OWNERSPINE PROOF FAIL: owner command wrote no audit row';
  end if;
  raise notice 'OWNERSPINE_PASS_OWNER_ACCEPTED';
end $$;

-- ── PROOF 2 — NON-OWNER authenticated user is REJECTED (not_authorized), zero side effects ─────────
-- Set request.jwt.claims to a non-owner authenticated subject and assert rejection. This is executed as
-- the superuser (postgres) — a STRICT SUPERSET of "authenticated": the guard keys off auth.uid() IN THE
-- FUNCTION BODY, so even a superuser with a non-owner JWT is refused. No client flag exists in the path.
do $$
declare v_no uuid; r jsonb; n int;
begin
  select v into v_no from spineids where k = 'nonowner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_no::text, 'role','authenticated')::text, true);
  if public.is_owner() then
    raise exception 'OWNERSPINE PROOF FAIL: is_owner() returned true for a non-owner';
  end if;
  r := public.world_editor_ping('spine-nonowner-req-1', '{}'::jsonb);
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authorized' then
    raise exception 'OWNERSPINE PROOF FAIL: non-owner was not rejected as not_authorized: %', r;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'spine-nonowner-req-1';
  if n <> 0 then
    raise exception 'OWNERSPINE PROOF FAIL: a rejected non-owner command wrote % audit row(s)', n;
  end if;
  raise notice 'OWNERSPINE_PASS_NONOWNER_REJECTED';
end $$;

-- ── PROOF 3 — ANONYMOUS caller is REJECTED (not_authenticated) ─────────────────────────────────────
-- claims carry no 'sub' ⇒ auth.uid() is null ⇒ the in-body authn check fires before any authz.
do $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  r := public.world_editor_ping('spine-anon-req-1', '{}'::jsonb);
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authenticated' then
    raise exception 'OWNERSPINE PROOF FAIL: anonymous caller was not rejected as not_authenticated: %', r;
  end if;
  raise notice 'OWNERSPINE_PASS_ANON_REJECTED';
end $$;

-- ── PROOF 4 — direct RPC invocation as the REAL authenticated Postgres role cannot bypass ─────────
-- Switch the session role to `authenticated` (the exact role a browser JWT assumes) with a non-owner
-- subject, call the RPC directly, and assert not_authorized. Proves the guard is server-side: no client
-- flag/route and no direct call as the client role can defeat it.
do $$
declare v_no uuid; r jsonb;
begin
  select v into v_no from spineids where k = 'nonowner';        -- read fixture as superuser first
  perform set_config('request.jwt.claims', json_build_object('sub', v_no::text, 'role','authenticated')::text, true);
  perform set_config('role', 'authenticated', true);            -- become the actual client role
  r := public.world_editor_ping('spine-directrole-req-1', '{}'::jsonb);
  perform set_config('role', 'none', true);                     -- restore superuser for the rest of the proof
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authorized' then
    raise exception 'OWNERSPINE PROOF FAIL: direct RPC as the authenticated role was not rejected: %', r;
  end if;
  raise notice 'OWNERSPINE_PASS_DIRECT_RPC_AS_AUTHENTICATED_REJECTED';
end $$;

-- ── PROOF 5 — repeated request_id is IDEMPOTENT (prior result returned, no duplicate audit row) ───
do $$
declare v_owner uuid; r1 jsonb; r2 jsonb; n int;
begin
  select v into v_owner from spineids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r1 := public.world_editor_ping('spine-idem-req-1', jsonb_build_object('n', 1));
  r2 := public.world_editor_ping('spine-idem-req-1', jsonb_build_object('n', 2));   -- same id, different payload
  if (r1->>'ok')::boolean is not true then
    raise exception 'OWNERSPINE PROOF FAIL: first idempotent call not ok: %', r1;
  end if;
  if (r2->>'ok')::boolean is not true or (r2->>'replayed')::boolean is not true or (r2->>'code') <> 'duplicate_request' then
    raise exception 'OWNERSPINE PROOF FAIL: second call was not an idempotent replay: %', r2;
  end if;
  -- the replay returns the PRIOR result (payload n=1), NOT the second call's n=2 ⇒ no double-apply.
  if (r2->'result'->'payload'->>'n') <> '1' then
    raise exception 'OWNERSPINE PROOF FAIL: replay did not return the prior result (expected n=1): %', r2;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'spine-idem-req-1';
  if n <> 1 then
    raise exception 'OWNERSPINE PROOF FAIL: idempotent request produced % audit rows (expected exactly 1)', n;
  end if;
  raise notice 'OWNERSPINE_PASS_IDEMPOTENT';
end $$;

-- ── PROOF 6 — RPC/table PRIVILEGE MATRIX (client roles cannot reach the allow-list or bypass grants) ─
do $$
begin
  if not has_function_privilege('authenticated', 'public.world_editor_ping(text,jsonb)', 'execute') then
    raise exception 'OWNERSPINE PROOF FAIL: authenticated lost execute on world_editor_ping (in-body guard unreachable)';
  end if;
  if has_function_privilege('anon', 'public.world_editor_ping(text,jsonb)', 'execute') then
    raise exception 'OWNERSPINE PROOF FAIL: anon can execute world_editor_ping';
  end if;
  if has_function_privilege('anon', 'public.is_owner()', 'execute') then
    raise exception 'OWNERSPINE PROOF FAIL: anon can execute is_owner()';
  end if;
  if has_table_privilege('authenticated', 'public.app_owners', 'INSERT')
     or has_table_privilege('authenticated', 'public.app_owners', 'UPDATE')
     or has_table_privilege('authenticated', 'public.app_owners', 'DELETE')
     or has_table_privilege('authenticated', 'public.app_owners', 'SELECT')
     or has_table_privilege('anon', 'public.app_owners', 'SELECT') then
    raise exception 'OWNERSPINE PROOF FAIL: a client role holds a grant on app_owners (allow-list must be deny-all)';
  end if;
  raise notice 'OWNERSPINE_PASS_PRIVILEGE_MATRIX';
end $$;

-- ── PROOF 7 — the 0239 pirate-zone lockdown is INTACT (this slice restored NO write privilege) ────
do $$
begin
  if has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_zone_delete(uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'OWNERSPINE PROOF FAIL: a client role regained EXECUTE on a pirate_zone write RPC — 0239 lockdown regressed';
  end if;
  raise notice 'OWNERSPINE_PASS_ZONE_LOCKDOWN_INTACT';
end $$;

-- ── PROOF 8 — the read-only World Editor surface is UNAFFECTED (grants unchanged) ─────────────────
do $$
begin
  if not has_function_privilege('authenticated', 'public.get_world_map()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_danger_zones()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_active_mining_fields()', 'execute') then
    raise exception 'OWNERSPINE PROOF FAIL: a read-only World Editor RPC lost its authenticated execute grant';
  end if;
  raise notice 'OWNERSPINE_PASS_READ_SURFACE_INTACT';
end $$;

do $$ begin raise notice 'WORLD-EDITOR OWNER-SPINE PROOF PASSED'; end $$;

rollback;   -- leave ZERO persisted state.
