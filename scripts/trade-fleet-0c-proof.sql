-- TRADE-FLEET-0C — disposable REAL-CHAIN proof (runs on the actual chain 0001..0084 in a throwaway Supabase).
-- Proves the 0C-established subset of the TRADE-FLEET-0B §2.7 eight properties. Fixture users carry the
-- 'tf0c.' email prefix. The ENTIRE proof runs inside ONE transaction that ROLLBACKs — it persists NO ship,
-- flag flip, or trade row. No production access. No COMMIT anywhere.
--
-- ── SCOPE (planner authority) ────────────────────────────────────────────────────────────────────
-- Covered here (0C establishes these): provisioning via the real RPCs + the dark/cap/flag gate;
--   (1) N-ship coexistence; (2) independent per-ship movement; (7) legacy one-ship (shim) validity.
-- DEFERRED to TRADE-MARKET-1's verifier (no buy/sell RPC exists yet, so these are unprovable now):
--   volume-capacity-check-on-write, and docked-trade-while-another-in-transit concurrency.
--
-- ── DARK-CAPABILITY EXERCISE (sanctioned; never crosses the flag human-gate) ──────────────────────
-- The harness enables `mainship_additional_commission_enabled` ONLY inside this rolled-back transaction to
-- exercise the dark add-ship capability; the ROLLBACK reverts it, so the committed/production flag value
-- stays false. It also transiently mirrors production config a fresh chain lacks (reveal_starter_ports +
-- mainship_space_movement_enabled=true) — all reverted by ROLLBACK. No committed flag/state changes.
--
-- ── ABSTRACT-COLUMN DEFER (planner authority, refines §2.3) ───────────────────────────────────────
-- The abstract cargo columns are NOT physically dropped in 0C: the frontend still SELECTs/displays
-- cargo_capacity (instance) + base_cargo_capacity (hull) (mainshipApi.ts, MainShipPreview.tsx,
-- useGalaxyMapData.ts), and fixing that is TRADE-UI-1 scope (0C must not touch src/). So in 0C the volume
-- model (cargo_capacity_m3, ship_cargo_lots lot-sum) is the AUTHORITATIVE capacity source for new trade
-- paths, while the abstract columns REMAIN as coexisting legacy. The physical drop + UI swap land in TRADE-UI-1.

\set ON_ERROR_STOP on

begin;   -- everything below is transient; the trailing ROLLBACK leaves ZERO persisted state.

create temp table tf0c(k text primary key, v uuid) on commit preserve rows;
insert into tf0c values
  ('haven','b1a00001-0066-4a00-8a00-000000000001'),     -- Haven Reach (designated spawn / commission port)
  ('slag', 'b1a00002-0066-4a00-8a00-000000000002');     -- Slagworks Anchorage (a different active port)

-- caller helper: set the authenticated subject then run an RPC, returning its jsonb.
create or replace function pg_temp.call_as(p_sub uuid, p_fn text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_fn into v;
  return v;
end $$;

-- three fresh players: uM (multi-ship), uS (single-ship shim), uZ (zero-ship no_first_ship case).
do $$
declare u uuid; k text;
begin
  foreach k in array array['uM','uS','uZ'] loop
    insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
      values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
              'tf0c.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
      returning id into u;
    insert into tf0c values (k, u);
  end loop;
end $$;

-- mirror production config a fresh disposable chain lacks (all reverted by ROLLBACK):
--   reveal the starter ports (0066 boots them hidden) + enable the port-to-port movement domain.
do $$
declare r jsonb;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: reveal_starter_ports %', r; end if;
  insert into public.game_config(key,value,description)
    values('mainship_space_movement_enabled','true'::jsonb,'tf0c transient (rolled back)')
    on conflict (key) do update set value='true'::jsonb;
  raise notice 'setup ok: starter ports active + movement domain enabled (transient)';
end $$;

-- ════════ P. Provisioning + DARK flag gate + per-player cap (§1a–b) ════════
do $$
declare r jsonb; n int; uM uuid := (select v from tf0c where k='uM'); uZ uuid := (select v from tf0c where k='uZ');
begin
  -- first ship via the REAL first-ship path.
  r := pg_temp.call_as(uM, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then raise exception 'P FAIL first-ship: %', r; end if;

  -- (a) DARK: with the flag still FALSE, the server REJECTS an additional ship and writes nothing.
  r := pg_temp.call_as(uM, 'public.commission_additional_main_ship()');
  if (r->>'reason') is distinct from 'additional_commission_disabled' then raise exception 'P FAIL dark-reject: %', r; end if;
  select count(*) into n from public.main_ship_instances where player_id=uM;
  if n <> 1 then raise exception 'P FAIL dark path wrote (% ships)', n; end if;

  -- enable the dark capability ONLY inside this rolled-back txn (production flag stays false after ROLLBACK).
  update public.game_config set value='true'::jsonb where key='mainship_additional_commission_enabled';

  -- (b) a ZERO-ship player must use the first-ship path — additional rejects with no_first_ship.
  r := pg_temp.call_as(uZ, 'public.commission_additional_main_ship()');
  if (r->>'reason') is distinct from 'no_first_ship' then raise exception 'P FAIL no_first_ship: %', r; end if;
  select count(*) into n from public.main_ship_instances where player_id=uZ;
  if n <> 0 then raise exception 'P FAIL no_first_ship wrote (% ships)', n; end if;

  -- (c) commission additional ships up to the cap (=3): first→2nd→3rd all created & docked.
  r := pg_temp.call_as(uM, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true or (r->>'docked')::boolean is not true then raise exception 'P FAIL 2nd ship: %', r; end if;
  r := pg_temp.call_as(uM, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then raise exception 'P FAIL 3rd ship: %', r; end if;
  select count(*) into n from public.main_ship_instances where player_id=uM;
  if n <> 3 then raise exception 'P FAIL expected 3 ships at cap, got %', n; end if;

  -- (d) the cap BLOCKS the 4th (server-enforced under the commission advisory lock).
  r := pg_temp.call_as(uM, 'public.commission_additional_main_ship()');
  if (r->>'reason') is distinct from 'ship_cap_reached' or (r->>'cap')::int is distinct from 3 then raise exception 'P FAIL cap block: %', r; end if;
  select count(*) into n from public.main_ship_instances where player_id=uM;
  if n <> 3 then raise exception 'P FAIL cap block wrote (% ships)', n; end if;

  raise notice 'TF0C_PASS_PROVISIONING ok: dark-reject + no_first_ship + cap=3 + 4th blocked';
end $$;

-- ════════ Property (1): N-ship coexistence ════════
do $$
declare n int; uM uuid := (select v from tf0c where k='uM');
begin
  -- exactly 3 DISTINCT ship rows, each with its own main_ship_id.
  select count(distinct main_ship_id) into n from public.main_ship_instances where player_id=uM;
  if n <> 3 then raise exception 'PROP1 FAIL: % distinct ships (want 3)', n; end if;
  -- every ship has cargo_capacity_m3 populated (>0) — the authoritative volume capacity (§2.3).
  select count(*) into n from public.main_ship_instances where player_id=uM and (cargo_capacity_m3 is null or cargo_capacity_m3 <= 0);
  if n <> 0 then raise exception 'PROP1 FAIL: % ships missing cargo_capacity_m3', n; end if;
  -- every ship is independently docked/eligible (ship-scoped validated context = at_location).
  select count(*) into n from public.main_ship_instances s
    where s.player_id=uM and (public.mainship_space_validate_context(s.main_ship_id)->>'state') is distinct from 'at_location';
  if n <> 0 then raise exception 'PROP1 FAIL: % ships not canonical at_location', n; end if;
  raise notice 'TF0C_PASS_PROP1 ok: 3 ships coexist — distinct ids, cargo_capacity_m3 populated, all docked/eligible';
end $$;

-- ════════ Property (2): independent per-ship movement (explicit p_main_ship_id) ════════
do $$
declare r jsonb; uM uuid := (select v from tf0c where k='uM'); slag uuid := (select v from tf0c where k='slag');
  ship_a uuid; ship_b uuid; n int; st_a text; st_b text;
begin
  select main_ship_id into ship_a from public.main_ship_instances where player_id=uM order by created_at asc  limit 1;
  select main_ship_id into ship_b from public.main_ship_instances where player_id=uM order by created_at desc limit 1;
  if ship_a = ship_b then raise exception 'PROP2 FAIL: could not pick two distinct ships'; end if;

  -- command ONLY ship_a by explicit p_main_ship_id → it departs; ship_b must be untouched.
  r := pg_temp.call_as(uM, format('public.command_main_ship_space_move_to_location(%L::uuid, gen_random_uuid(), %L::uuid)', slag, ship_a));
  if (r->>'ok')::boolean is not true then raise exception 'PROP2 FAIL: selected-ship move rejected: %', r; end if;

  st_a := public.mainship_space_validate_context(ship_a)->>'state';
  st_b := public.mainship_space_validate_context(ship_b)->>'state';
  if st_a = 'at_location' then raise exception 'PROP2 FAIL: ship_a did not leave dock (state %)', st_a; end if;
  if st_b is distinct from 'at_location' then raise exception 'PROP2 FAIL: ship_b was disturbed (state %)', st_b; end if;

  -- per-ship receipt/lock scoping: a space-movement row exists for ship_a and NONE for ship_b.
  select count(*) into n from public.main_ship_space_movements where main_ship_id=ship_a;
  if n < 1 then raise exception 'PROP2 FAIL: no space-movement row for ship_a'; end if;
  select count(*) into n from public.main_ship_space_movements where main_ship_id=ship_b;
  if n <> 0 then raise exception 'PROP2 FAIL: ship_b has a space-movement row (% rows) — not per-ship scoped', n; end if;

  raise notice 'TF0C_PASS_PROP2 ok: explicit p_main_ship_id moved ship_a only; ship_b stayed docked; receipt scoped per-ship';
end $$;

-- ════════ Property (7): legacy one-ship (shim) validity + multi-ship ambiguity fails closed ════════
do $$
declare r jsonb; uS uuid := (select v from tf0c where k='uS'); uM uuid := (select v from tf0c where k='uM');
  slag uuid := (select v from tf0c where k='slag'); n int; st text;
begin
  -- provision uS with exactly ONE ship.
  r := pg_temp.call_as(uS, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'PROP7 FAIL first-ship: %', r; end if;
  select count(*) into n from public.main_ship_instances where player_id=uS; if n <> 1 then raise exception 'PROP7 FAIL: uS has % ships (want 1)', n; end if;

  -- (a) zero-p_main_ship_id READ resolves to the sole ship (shim) and reports it docked.
  r := pg_temp.call_as(uS, 'public.get_my_current_dock_services()');
  if (r->>'state') is distinct from 'at_location' or (r->>'docked')::boolean is not true then raise exception 'PROP7 FAIL shim read: %', r; end if;

  -- (b) zero-p_main_ship_id COMMAND resolves to and moves the sole ship (backward compatible).
  r := pg_temp.call_as(uS, format('public.command_main_ship_space_move_to_location(%L::uuid, gen_random_uuid())', slag));
  if (r->>'ok')::boolean is not true then raise exception 'PROP7 FAIL shim move: %', r; end if;
  st := public.mainship_space_validate_context((select main_ship_id from public.main_ship_instances where player_id=uS))->>'state';
  if st = 'at_location' then raise exception 'PROP7 FAIL: sole ship did not move via shim (state %)', st; end if;

  -- (c) the shim is UNAMBIGUOUS-only: a zero-p_main_ship_id call by the MULTI-ship uM fails closed (resolver
  --     returns null for >1 ship → the existing no_main_ship shape), forcing explicit selection post-flip.
  r := pg_temp.call_as(uM, 'public.get_my_current_dock_services()');
  if (r->>'state') is distinct from 'no_main_ship' then raise exception 'PROP7 FAIL: multi-ship shim not ambiguous (state %)', r->>'state'; end if;

  raise notice 'TF0C_PASS_PROP7 ok: single-ship shim resolves+commands the sole ship; multi-ship shim fails closed (ambiguous)';
end $$;

select 'TRADE-FLEET-0C PROOF PASSED (provisioning/dark-flag/cap + properties 1,2,7; trade-enforcement 2 props deferred to TRADE-MARKET-1)' as result;

rollback;   -- leave ZERO persisted state: no ship, no fleet, no presence, no flag flip, no fixture user.
