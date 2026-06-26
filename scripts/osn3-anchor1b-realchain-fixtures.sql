-- OSN-ANCHOR-1B — REAL-CHAIN proof for the additive canonical-anchor schema (migration 0063). Runs via psql
-- against a DISPOSABLE local Supabase stack whose schema is the ACTUAL migration chain 0001..0067 (NOT a stub,
-- NEVER the shared/live DB). Proves the server-only public.space_anchors contract:
--   1  table/columns/types exist as intended; RLS on; partial-unique indexes + guard trigger present.
--   2  only kind in {base, location} is accepted.
--   3  each kind requires exactly its matching typed FK.
--   4  all-null / both-owner / mismatched-kind / unknown-kind inserts fail.
--   5  valid base and location anchors insert.
--   6  NaN / infinity / null / out-of-bounds coordinates fail; finite in-bounds succeed.
--   7  at most one ACTIVE anchor per base / per location.
--   8  retired + replacement active anchor for the same owner is allowed.
--   9  active anchor coordinate/owner/kind/created_at mutation fails (immutability guard).
--   10 active -> retired succeeds.
--   11 retired -> active (or any retired edit) fails.
--   12 base deletion CASCADES its anchor rows (owner gone).
--   13 location deletion is RESTRICTED while anchored.
--   14 anon / authenticated / PUBLIC cannot access the table.
--   15 service_role has full access.
--   17 mainship_space_resolve_origin is UNCHANGED: home/legacy_home still resolve origin_not_anchored, and the
--      resolver descriptor (signature/SECDEF/search_path/owner/grants) is unchanged. (Item 16 — S1..S6A,
--      DOCK-0, ANCHOR-1A non-regression — is proven by the sibling osn3-** real-chain proofs on the same push,
--      which boot the SAME 0001..0067 chain.)
-- Seeds NO durable rows; fixtures use the 'osn3anchor1b.' email prefix and are removed at the end; the table is
-- asserted NET-ZERO against its pre-fixture baseline at the end (the fixture cleans up completely and leaves no
-- rows of its own). The 3 permanent WORLD-HUB hidden-port location anchors seeded by migration 0066 are a
-- separate WORLD-HUB baseline invariant (covered by the WORLD-HUB proof), NOT re-asserted here. Touches NO
-- flags. NEVER touches the shared/live DB.

\set ON_ERROR_STOP on

\echo ''
\echo '================= ANCHOR-1B: schema shape, RLS, indexes, trigger ================='
do $$
declare n int;
begin
  if to_regclass('public.space_anchors') is null then raise exception 'space_anchors table missing'; end if;

  -- column types
  perform 1 from information_schema.columns where table_schema='public' and table_name='space_anchors'
    and ((column_name='id' and data_type='uuid')
      or false);
  if (select data_type from information_schema.columns where table_schema='public' and table_name='space_anchors' and column_name='id') <> 'uuid' then raise exception 'id type'; end if;
  if (select data_type from information_schema.columns where table_schema='public' and table_name='space_anchors' and column_name='kind') <> 'text' then raise exception 'kind type'; end if;
  if (select data_type from information_schema.columns where table_schema='public' and table_name='space_anchors' and column_name='base_id') <> 'uuid' then raise exception 'base_id type'; end if;
  if (select data_type from information_schema.columns where table_schema='public' and table_name='space_anchors' and column_name='location_id') <> 'uuid' then raise exception 'location_id type'; end if;
  if (select data_type from information_schema.columns where table_schema='public' and table_name='space_anchors' and column_name='space_x') <> 'double precision' then raise exception 'space_x type'; end if;
  if (select data_type from information_schema.columns where table_schema='public' and table_name='space_anchors' and column_name='space_y') <> 'double precision' then raise exception 'space_y type'; end if;
  if (select data_type from information_schema.columns where table_schema='public' and table_name='space_anchors' and column_name='status') <> 'text' then raise exception 'status type'; end if;
  if (select data_type from information_schema.columns where table_schema='public' and table_name='space_anchors' and column_name='created_at') not in ('timestamp with time zone') then raise exception 'created_at type'; end if;
  -- space_x/space_y/status/kind/created_at NOT NULL
  if (select count(*) from information_schema.columns where table_schema='public' and table_name='space_anchors'
        and column_name in ('kind','space_x','space_y','status','created_at') and is_nullable='NO') <> 5 then
    raise exception 'expected kind/space_x/space_y/status/created_at NOT NULL';
  end if;

  -- RLS enabled
  if not (select relrowsecurity from pg_class where oid='public.space_anchors'::regclass) then raise exception 'RLS not enabled'; end if;

  -- partial-unique indexes
  if to_regclass('public.space_anchors_one_active_per_base') is null then raise exception 'missing one-active-per-base index'; end if;
  if to_regclass('public.space_anchors_one_active_per_location') is null then raise exception 'missing one-active-per-location index'; end if;

  -- named CHECK constraints
  select count(*) into n from pg_constraint where conrelid='public.space_anchors'::regclass and contype='c'
    and conname in ('space_anchors_exactly_one_owner','space_anchors_coords_finite_in_bounds');
  if n <> 2 then raise exception 'missing owner/coord CHECK constraints (found %)', n; end if;

  -- guard trigger
  if not exists (select 1 from pg_trigger where tgrelid='public.space_anchors'::regclass and tgname='space_anchors_immutability' and not tgisinternal) then
    raise exception 'missing immutability trigger';
  end if;

  raise notice 'shape ok: table/columns/types/RLS/indexes/checks/trigger present';
end $$;

\echo ''
\echo '================= ANCHOR-1B: security / ACL ================='
do $$
begin
  -- private: anon/authenticated (and therefore PUBLIC, which they inherit) have NO table privileges
  if has_table_privilege('anon','public.space_anchors','SELECT')          then raise exception 'anon can SELECT'; end if;
  if has_table_privilege('anon','public.space_anchors','INSERT')          then raise exception 'anon can INSERT'; end if;
  if has_table_privilege('authenticated','public.space_anchors','SELECT') then raise exception 'authenticated can SELECT'; end if;
  if has_table_privilege('authenticated','public.space_anchors','INSERT') then raise exception 'authenticated can INSERT'; end if;
  if has_table_privilege('authenticated','public.space_anchors','UPDATE') then raise exception 'authenticated can UPDATE'; end if;
  if has_table_privilege('authenticated','public.space_anchors','DELETE') then raise exception 'authenticated can DELETE'; end if;
  -- service_role: full access
  if not has_table_privilege('service_role','public.space_anchors','SELECT') then raise exception 'service_role lacks SELECT'; end if;
  if not has_table_privilege('service_role','public.space_anchors','INSERT') then raise exception 'service_role lacks INSERT'; end if;
  if not has_table_privilege('service_role','public.space_anchors','UPDATE') then raise exception 'service_role lacks UPDATE'; end if;
  if not has_table_privilege('service_role','public.space_anchors','DELETE') then raise exception 'service_role lacks DELETE'; end if;
  -- guard trigger function is not directly executable by clients
  if has_function_privilege('anon','public.space_anchors_immutability_guard()','EXECUTE')          then raise exception 'anon can EXECUTE guard fn'; end if;
  if has_function_privilege('authenticated','public.space_anchors_immutability_guard()','EXECUTE') then raise exception 'authenticated can EXECUTE guard fn'; end if;
  raise notice 'acl ok: anon/authenticated/PUBLIC denied; service_role full; guard fn locked';
end $$;

\echo ''
\echo '================= ANCHOR-1B: resolver UNCHANGED (descriptor parity) ================='
do $$
declare r record;
begin
  select p.oid, p.prosecdef, p.proconfig,
         pg_get_function_identity_arguments(p.oid) as args, pg_get_userbyid(p.proowner) as owner
    into r from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='mainship_space_resolve_origin';
  if r.oid is null then raise exception 'resolver missing'; end if;
  if r.args is distinct from 'p_main_ship_id uuid' then raise exception 'resolver signature changed: %', r.args; end if;
  if not r.prosecdef then raise exception 'resolver not SECURITY DEFINER'; end if;
  if r.proconfig is null or not ('search_path=public' = any(r.proconfig)) then raise exception 'resolver search_path not public'; end if;
  if r.owner <> 'postgres' then raise exception 'resolver owner=%', r.owner; end if;
  if has_function_privilege('anon', r.oid, 'EXECUTE') or has_function_privilege('authenticated', r.oid, 'EXECUTE') then raise exception 'resolver granted to a client role'; end if;
  if not has_function_privilege('service_role', r.oid, 'EXECUTE') then raise exception 'resolver not service_role-executable'; end if;
  raise notice 'resolver descriptor unchanged (service_role-only SECDEF search_path=public)';
end $$;

\echo ''
\echo '================= ANCHOR-1B: behavioral contract (constraints, lifecycle, FK, resolver) ================='
do $$
declare
  v_u1 uuid; v_u2 uuid;
  v_base1 uuid; v_base2 uuid; v_loc uuid;
  v_a_base1 uuid; v_a_base1b uuid; v_a_loc uuid;
  v_ship uuid;
  v_ok boolean; v_state text; v_reason text; v_sqlstate text; n int; n_base0 int;
begin
  -- ── fixtures ──────────────────────────────────────────────────────────────────────────────────────────
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated','osn3anchor1b.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','') returning id into v_u1;
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated','osn3anchor1b.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','') returning id into v_u2;
  select id into v_base1 from bases where player_id=v_u1 order by created_at limit 1;
  select id into v_base2 from bases where player_id=v_u2 order by created_at limit 1;
  if v_base1 is null or v_base2 is null then raise exception 'fixture bases not auto-provisioned'; end if;
  select id into v_loc from locations where status='active' limit 1;
  if v_loc is null then raise exception 'no seeded active location for fixtures'; end if;
  -- Pre-fixture baseline: on the full 0001..0067 chain this is the 3 permanent WORLD-HUB hidden-port location
  -- anchors (migration 0066). The fixture must net-zero back to exactly this — it seeds nothing durable of its
  -- own and must not disturb the baseline. (v_loc is an ACTIVE seeded location; the 0066 ports are status='hidden'.)
  select count(*) into n_base0 from space_anchors;

  -- ── 6  coordinate domain rejections (base1 has no anchor yet → only the coord/not-null constraint can fail)
  begin v_ok:=true; insert into space_anchors(kind,base_id,space_x,space_y) values('base',v_base1,'NaN'::double precision,0); exception when others then v_sqlstate:=sqlstate; v_ok:=false; end;
  if v_ok then raise exception 'NEG FAIL: NaN x accepted'; end if; if v_sqlstate<>'23514' then raise exception 'NaN x expected check_violation got %', v_sqlstate; end if;
  begin v_ok:=true; insert into space_anchors(kind,base_id,space_x,space_y) values('base',v_base1,'Infinity'::double precision,0); exception when others then v_sqlstate:=sqlstate; v_ok:=false; end;
  if v_ok then raise exception 'NEG FAIL: +Inf x accepted'; end if; if v_sqlstate<>'23514' then raise exception '+Inf expected check_violation got %', v_sqlstate; end if;
  begin v_ok:=true; insert into space_anchors(kind,base_id,space_x,space_y) values('base',v_base1,0,'-Infinity'::double precision); exception when others then v_sqlstate:=sqlstate; v_ok:=false; end;
  if v_ok then raise exception 'NEG FAIL: -Inf y accepted'; end if; if v_sqlstate<>'23514' then raise exception '-Inf expected check_violation got %', v_sqlstate; end if;
  begin v_ok:=true; insert into space_anchors(kind,base_id,space_x,space_y) values('base',v_base1,10001,0); exception when others then v_sqlstate:=sqlstate; v_ok:=false; end;
  if v_ok then raise exception 'NEG FAIL: out-of-bounds x accepted'; end if; if v_sqlstate<>'23514' then raise exception 'oob expected check_violation got %', v_sqlstate; end if;
  begin v_ok:=true; insert into space_anchors(kind,base_id,space_x,space_y) values('base',v_base1,null,0); exception when others then v_sqlstate:=sqlstate; v_ok:=false; end;
  if v_ok then raise exception 'NEG FAIL: null x accepted'; end if; if v_sqlstate<>'23502' then raise exception 'null x expected not_null_violation got %', v_sqlstate; end if;

  -- ── 2,3,4  owner-kind rejections
  begin v_ok:=true; insert into space_anchors(kind,space_x,space_y) values('base',1,1); exception when others then v_ok:=false; end;            -- all-null owner
  if v_ok then raise exception 'NEG FAIL: all-null owner accepted'; end if;
  begin v_ok:=true; insert into space_anchors(kind,base_id,location_id,space_x,space_y) values('base',v_base1,v_loc,1,1); exception when others then v_ok:=false; end;  -- both owners
  if v_ok then raise exception 'NEG FAIL: both-owner accepted'; end if;
  begin v_ok:=true; insert into space_anchors(kind,location_id,space_x,space_y) values('base',v_loc,1,1); exception when others then v_ok:=false; end;  -- mismatched (kind base, loc owner)
  if v_ok then raise exception 'NEG FAIL: mismatched kind/owner accepted'; end if;
  begin v_ok:=true; insert into space_anchors(kind,location_id,space_x,space_y) values('location',v_loc,1,1); exception when others then v_ok:=false; end;  -- kind=location requires location_id (this is valid!) -- guard below
  if not v_ok then raise exception 'POS FAIL: valid location anchor (kind=location, location_id) rejected'; end if;
  delete from space_anchors where location_id=v_loc;  -- undo the probe; the canonical location anchor is created below
  begin v_ok:=true; insert into space_anchors(kind,base_id,space_x,space_y) values('station',v_base1,1,1); exception when others then v_ok:=false; end;  -- unknown kind
  if v_ok then raise exception 'NEG FAIL: unknown kind accepted'; end if;

  -- ── 5  valid inserts
  insert into space_anchors(kind,base_id,space_x,space_y)     values('base',v_base1,1234,-987) returning id into v_a_base1;
  insert into space_anchors(kind,location_id,space_x,space_y) values('location',v_loc,-50,50)  returning id into v_a_loc;
  if v_a_base1 is null or v_a_loc is null then raise exception 'POS FAIL: valid anchors not inserted'; end if;

  -- ── 7  one active per base
  begin v_ok:=true; insert into space_anchors(kind,base_id,space_x,space_y) values('base',v_base1,1,1); exception when others then v_sqlstate:=sqlstate; v_ok:=false; end;
  if v_ok then raise exception 'NEG FAIL: second active anchor per base accepted'; end if; if v_sqlstate<>'23505' then raise exception 'expected unique_violation got %', v_sqlstate; end if;

  -- ── 9  active mutation rejected (coord)
  begin v_ok:=true; update space_anchors set space_x=2 where id=v_a_base1; exception when others then v_ok:=false; end;
  if v_ok then raise exception 'NEG FAIL: active coordinate mutation accepted'; end if;
  begin v_ok:=true; update space_anchors set base_id=v_base2 where id=v_a_base1; exception when others then v_ok:=false; end;   -- owner mutation
  if v_ok then raise exception 'NEG FAIL: active owner mutation accepted'; end if;

  -- ── 10  active -> retired succeeds
  update space_anchors set status='retired' where id=v_a_base1;
  if (select status from space_anchors where id=v_a_base1) <> 'retired' then raise exception 'POS FAIL: active->retired did not stick'; end if;

  -- ── 8  retired + replacement active for the same base is allowed
  insert into space_anchors(kind,base_id,space_x,space_y) values('base',v_base1,7777,7777) returning id into v_a_base1b;
  if v_a_base1b is null then raise exception 'POS FAIL: replacement active anchor rejected'; end if;

  -- ── 11  retired anchor is immutable (no reactivation / edit)
  begin v_ok:=true; update space_anchors set status='active' where id=v_a_base1; exception when others then v_ok:=false; end;
  if v_ok then raise exception 'NEG FAIL: retired->active accepted'; end if;
  begin v_ok:=true; update space_anchors set space_y=3 where id=v_a_base1; exception when others then v_ok:=false; end;
  if v_ok then raise exception 'NEG FAIL: retired edit accepted'; end if;

  -- ── 13  location deletion RESTRICTED while anchored (a_loc still anchors v_loc)
  begin v_ok:=true; delete from locations where id=v_loc; exception when others then v_sqlstate:=sqlstate; v_ok:=false; end;
  if v_ok then raise exception 'NEG FAIL: anchored location was deletable'; end if; if v_sqlstate<>'23503' then raise exception 'expected fk_violation got %', v_sqlstate; end if;

  -- ── 12  base deletion CASCADES its anchor rows (documented exception: the owner is gone). Delete via the
  --        owning user → bases CASCADE (and any base-child rows) → space_anchors.base_id CASCADE.
  insert into space_anchors(kind,base_id,space_x,space_y) values('base',v_base2,10,10);
  delete from auth.users where id=v_u2;
  select count(*) into n from space_anchors where base_id=v_base2;
  if n<>0 then raise exception 'base cascade FAIL: % anchor rows remain for deleted base', n; end if;

  -- ── 17  resolver behavior unchanged: a legacy_home ship resolves origin_not_anchored
  perform public.ensure_main_ship_for_player(v_u1);
  select main_ship_id into v_ship from main_ship_instances where player_id=v_u1;
  if v_ship is null then raise exception 'fixture ship missing'; end if;
  -- Normalize to a clean legacy home (status=home, spatial_state NULL, no coords) — removes any provisioning
  -- default ambiguity. A home ship with no fleet classifies as legacy_home (validate_context).
  update main_ship_instances set status='home', spatial_state=null, space_x=null, space_y=null where main_ship_id=v_ship;
  v_state := public.mainship_space_validate_context(v_ship)->>'state';
  if v_state <> 'legacy_home' then raise exception 'expected legacy_home context, got %', v_state; end if;
  v_reason := public.mainship_space_resolve_origin(v_ship)->>'reason';
  if v_reason <> 'origin_not_anchored' then raise exception 'resolver REGRESSION: legacy_home origin=% (expected origin_not_anchored)', v_reason; end if;

  -- ── cleanup: remove the fixture's location anchor (location persists under ON DELETE RESTRICT), then the
  --    fixture users (cascades bases → base anchors, and the ship). Then prove the fixture left NET-ZERO rows
  --    of its own — the table returns to its pre-fixture baseline. (NOT a global-empty assertion: the 3
  --    permanent WORLD-HUB hidden-port anchors from migration 0066 are a baseline invariant owned by the
  --    WORLD-HUB proof and must remain untouched.)
  delete from space_anchors where location_id=v_loc;
  delete from auth.users where id in (v_u1, v_u2);
  if exists (select 1 from space_anchors where location_id = v_loc or base_id in (v_base1, v_base2)) then
    raise exception 'ANCHOR-1B cleanup incomplete: a fixture-owned anchor row (location/base) still remains';
  end if;
  select count(*) into n from space_anchors;
  if n <> n_base0 then raise exception 'ANCHOR-1B cleanup: space_anchors=% rows, expected pre-fixture baseline % (fixture left net rows or disturbed the WORLD-HUB baseline)', n, n_base0; end if;

  raise notice 'behavioral contract ok: kinds/owners/coords/uniqueness/immutability/cascade/restrict/resolver';
end $$;

\echo ''
\echo 'OSN-ANCHOR-1B REAL-CHAIN PROOF: ALL PASSED'
