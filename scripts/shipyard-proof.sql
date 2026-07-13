-- SHIPYARD — disposable REAL-CHAIN proof (runs on the actual chain 0001..0194 in a throwaway Supabase).
-- Proves SHIPYARD-1 (mig 0188): the dark gate (gate-first, NO existence oracle), the lit hull-build
-- ORDER happy path (exact credits + ingredient spends, the 'waiting' M4.5 queue row), replay
-- idempotency (same request_id → same receipt, no double spend), the ingredient shortfall reject
-- (incl. the blueprint gate ingredient), the T2 progression gates (required hull / required captain
-- level), the 0185 self-prereq impossibility, and receipt survival past the 0047 reaper.
-- Proves SHIPYARD-2 (mig 0194 — the seam CLOSED): the engine's hull arm (P6 prosrc pins; P8 the
-- cron-sweep promotion with recipe build_seconds EXACT + the serial one-slot law across kinds),
-- delivery through the ONE commission build core (P9 — exact hull stats, the 0184 class-name +
-- roman-numeral idiom, docked present/location fleet at the commission port, unit orders promoted +
-- delivered IDENTICALLY: the exact 0038 formula + base_merge_units, and the post-delivery replay
-- verbatim), the per-order delivery guard (P9G — a POISONED delivery leaves its order active and
-- never blocks another player's co-tick completion; restored fixture -> self-healing retry), and
-- hull-aware cancel refunds (P10 — waiting 100% / active 50% floor-half from the
-- durable receipt bill via Wallet + Inventory, double-cancel rejected, post-cancel replay verbatim).
-- Fixture users carry the 'sy1.' email prefix. The ENTIRE proof runs inside ONE transaction that
-- ROLLBACKs — it persists NO order, receipt, wallet, inventory, ship, base, fleet, catalog fixture,
-- or flag flip. No production access. No COMMIT anywhere.
--
-- ── DARK-CAPABILITY EXERCISE (sanctioned; never crosses a flag human-gate) ────────────────────────
-- The harness enables shipyard_enabled ONLY inside this rolled-back transaction (AFTER proving the
-- dark reject), via the raw-update idiom — NEVER via set_game_config (the selftest pins both); the
-- ROLLBACK reverts it, so the committed/production flag value stays false. It transiently mirrors
-- production config a fresh chain lacks (reveal_starter_ports + mainship_space_movement_enabled) and
-- shapes an in-txn T2 catalog fixture (a synthetic hull + gated recipe — the ONLY way to exercise
-- the gate arms while the T1 seeds honestly carry NULL gates); all reverted by ROLLBACK. Items are
-- granted via the REAL secured-deposit pipeline leaf public.reward_grant (0040) — the harness NEVER
-- inserts into player_inventory; captains are minted via the REAL Captain leaf
-- public.captains_mint_instance (0118) — never a direct captain_instances insert.

\set ON_ERROR_STOP on

begin;   -- everything below is transient; the trailing ROLLBACK leaves ZERO persisted state.

create temp table sy1(k text primary key, v uuid) on commit preserve rows;

-- caller helper: set the authenticated subject then run an RPC, returning its jsonb.
create or replace function pg_temp.call_as(p_sub uuid, p_fn text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_fn into v;
  return v;
end $$;

-- one fresh builder player uB.
do $$
declare u uuid;
begin
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'sy1.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into u;
  insert into sy1 values ('uB', u);
end $$;

-- mirror production config a fresh disposable chain lacks (all reverted by ROLLBACK): reveal starter
-- ports + enable movement, then commission uB's first ship (real RPC — the required-hull gate below
-- needs a real owned starter_frigate). shipyard_enabled stays OFF here (P0 proves the dark reject
-- first). Wallet pre-created at a KNOWN 500 by direct owner insert (the tm1/sv1 funding precedent;
-- rolled back) so every credit assert is an EXACT delta, independent of wallet_ensure's seed.
do $$
declare r jsonb; uB uuid := (select v from sy1 where k='uB');
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: reveal_starter_ports %', r; end if;
  insert into public.game_config(key,value,description)
    values('mainship_space_movement_enabled','true'::jsonb,'sy1 transient (rolled back)')
    on conflict (key) do update set value='true'::jsonb;
  r := pg_temp.call_as(uB, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then raise exception 'SETUP FAIL first-ship: %', r; end if;
  insert into public.player_wallet (player_id, balance) values (uB, 500)
    on conflict (player_id) do update set balance = excluded.balance;
end $$;

-- ════════ P0 — DARK gate: shipyard_enabled OFF → gate-first reject, IDENTICAL for a real and a
--          garbage hull (no existence oracle), zero writes; the PRIVATE writer rejects dark too. ════════
do $$
declare r1 jsonb; r2 jsonb; r3 jsonb; uB uuid := (select v from sy1 where k='uB'); n int;
begin
  -- wrapper, real hull vs garbage hull: the dark envelope must be BYTE-IDENTICAL (anti-probe).
  r1 := pg_temp.call_as(uB, format('public.start_hull_build(%L::uuid, %L)', gen_random_uuid(), 'bulk_hauler'));
  r2 := pg_temp.call_as(uB, format('public.start_hull_build(%L::uuid, %L)', gen_random_uuid(), 'no_such_hull_xyz'));
  if (r1->>'code') is distinct from 'feature_disabled' then raise exception 'P0 FAIL dark real-hull: %', r1; end if;
  if r1 is distinct from r2 then raise exception 'P0 FAIL existence oracle: real % vs garbage %', r1, r2; end if;
  -- the PRIVATE writer is gate-first on its own authority (not just the wrapper).
  r3 := public.production_start_hull_build(uB, 'bulk_hauler', gen_random_uuid());
  if (r3->>'reason') is distinct from 'feature_disabled' then raise exception 'P0 FAIL dark private writer: %', r3; end if;

  select count(*) into n from public.build_orders where player_id=uB;
  if n <> 0 then raise exception 'P0 FAIL dark path wrote % build_orders rows', n; end if;
  select count(*) into n from public.hull_build_receipts where player_id=uB;
  if n <> 0 then raise exception 'P0 FAIL dark path wrote % receipts', n; end if;
  if (select balance from public.player_wallet where player_id=uB) <> 500 then raise exception 'P0 FAIL dark path moved wallet'; end if;

  -- enable the dark shipyard capability ONLY inside this rolled-back txn (raw-update idiom; the
  -- committed/production flag value stays false after ROLLBACK).
  update public.game_config set value='true'::jsonb where key='shipyard_enabled';
  raise notice 'SHIPYARD_PASS_DARK_GATE ok: gate-first feature_disabled, real-vs-garbage hull envelopes identical (no existence oracle), private writer dark on its own authority, zero writes';
end $$;

-- ════════ P1 — ORDER happy path: exact hauler recipe granted via the REAL pipeline → order OK,
--          wallet 500→100 EXACT, all 5 ingredient balances →0 EXACT, ONE 'waiting' queue row
--          (hull shape: unit/base NULL, no timestamps), ONE receipt. ════════
do $$
declare r jsonb; uB uuid := (select v from sy1 where k='uB'); v_req uuid := gen_random_uuid();
  v_order uuid; n int;
begin
  -- the EXACT 0185 hauler recipe: ore 24 + crystal 6 + engine_parts 6 + scrap 12 + blueprint_fragment 2.
  perform public.reward_grant('combat', gen_random_uuid(), uB, null,
    '{"items":[{"item_id":"ore","quantity":24},{"item_id":"crystal","quantity":6},{"item_id":"engine_parts","quantity":6},{"item_id":"scrap","quantity":12},{"item_id":"blueprint_fragment","quantity":2}]}'::jsonb);
  if public.inventory_get_balance(uB,'ore') <> 24 or public.inventory_get_balance(uB,'blueprint_fragment') <> 2 then
    raise exception 'P1 FAIL: reward_grant deposit did not land';
  end if;

  r := pg_temp.call_as(uB, format('public.start_hull_build(%L::uuid, %L)', v_req, 'bulk_hauler'));
  if (r->>'ok')::boolean is not true or (r->>'idempotent_replay')::boolean is true then raise exception 'P1 FAIL order: %', r; end if;
  if (r->>'hull_type_id') is distinct from 'bulk_hauler' or (r->>'credits_spent')::numeric <> 400 then raise exception 'P1 FAIL envelope: %', r; end if;
  v_order := (r->>'order_id')::uuid;

  -- wallet delta EXACT: 500 - 400 = 100 (want exactly -400).
  if (select balance from public.player_wallet where player_id=uB) <> 100 then
    raise exception 'P1 FAIL wallet % (want exactly 100 = 500 - 400)', (select balance from public.player_wallet where player_id=uB);
  end if;
  -- every ingredient spent to EXACTLY 0 via the sole Inventory writer.
  if public.inventory_get_balance(uB,'ore') <> 0 or public.inventory_get_balance(uB,'crystal') <> 0
     or public.inventory_get_balance(uB,'engine_parts') <> 0 or public.inventory_get_balance(uB,'scrap') <> 0
     or public.inventory_get_balance(uB,'blueprint_fragment') <> 0 then
    raise exception 'P1 FAIL: ingredient balances not exactly zero after the spend';
  end if;

  -- exactly ONE queue row in the HULL shape on the REUSED M4.5 queue: 'waiting', quantity 1,
  -- unit_type_id NULL, base_id NULL, metal untouched, credits_spent 400, NO timestamps (the serial
  -- law: only ACTIVE rows carry started_at/complete_at — SHIPYARD-2's engine promotes it).
  select count(*) into n from public.build_orders where player_id=uB;
  if n <> 1 then raise exception 'P1 FAIL % build_orders rows', n; end if;
  if not exists (select 1 from public.build_orders
                   where id=v_order and player_id=uB and hull_type_id='bulk_hauler'
                     and unit_type_id is null and base_id is null
                     and status='waiting' and quantity=1 and metal_spent=0 and credits_spent=400
                     and started_at is null and complete_at is null) then
    raise exception 'P1 FAIL: the queue row is not the exact waiting hull shape';
  end if;

  -- exactly ONE receipt with the exact fields (5 ingredient elements).
  select count(*) into n from public.hull_build_receipts where player_id=uB;
  if n <> 1 then raise exception 'P1 FAIL % receipts', n; end if;
  if not exists (select 1 from public.hull_build_receipts
                   where player_id=uB and request_id=v_req and hull_type_id='bulk_hauler'
                     and order_id=v_order and credits_spent=400
                     and jsonb_array_length(ingredients_json)=5) then
    raise exception 'P1 FAIL receipt fields wrong';
  end if;

  insert into sy1 values ('req1', v_req);      -- stash for the replay
  insert into sy1 values ('order1', v_order);
  raise notice 'SHIPYARD_PASS_ORDER ok: hauler order queued waiting (hull shape, no timestamps); wallet 500->100 exact; all 5 ingredients spent to 0 exact; 1 receipt';
end $$;

-- ════════ P2 — replay idempotency: same (player, request_id) → SAME receipt/order verbatim,
--          flagged replay, NO double spend/debit/order/receipt. ════════
do $$
declare r jsonb; uB uuid := (select v from sy1 where k='uB'); v_req uuid := (select v from sy1 where k='req1');
begin
  r := pg_temp.call_as(uB, format('public.start_hull_build(%L::uuid, %L)', v_req, 'bulk_hauler'));
  if (r->>'ok')::boolean is not true or (r->>'idempotent_replay')::boolean is not true then raise exception 'P2 FAIL not replay: %', r; end if;
  if (r->>'order_id')::uuid is distinct from (select v from sy1 where k='order1') then raise exception 'P2 FAIL replay order_id differs: %', r; end if;
  if (r->>'credits_spent')::numeric <> 400 then raise exception 'P2 FAIL replay envelope: %', r; end if;

  if (select balance from public.player_wallet where player_id=uB) <> 100 then raise exception 'P2 FAIL replay re-debited'; end if;
  if public.inventory_get_balance(uB,'ore') <> 0 then raise exception 'P2 FAIL replay re-spent (impossible balance)'; end if;
  if (select count(*) from public.build_orders where player_id=uB) <> 1 then raise exception 'P2 FAIL replay enqueued a second order'; end if;
  if (select count(*) from public.hull_build_receipts where player_id=uB) <> 1 then raise exception 'P2 FAIL replay wrote a receipt'; end if;
  raise notice 'SHIPYARD_PASS_REPLAY ok: same request_id -> same receipt/order verbatim, flagged idempotent_replay, no double spend/debit/order/receipt';
end $$;

-- ════════ P3 — shortfalls: the BLUEPRINT GATE ingredient missing → insufficient_items with exact
--          have/need; then credits short → insufficient_credits with ingredients UNTOUCHED
--          (pre-check-before-any-write ordering). Zero writes on both. ════════
do $$
declare r jsonb; uB uuid := (select v from sy1 where k='uB'); n int;
begin
  -- grant the corvette recipe EXCEPT blueprint_fragment: ore 16 + crystal 4 + weapon_parts 6 + pirate_alloy 8.
  perform public.reward_grant('combat', gen_random_uuid(), uB, null,
    '{"items":[{"item_id":"ore","quantity":16},{"item_id":"crystal","quantity":4},{"item_id":"weapon_parts","quantity":6},{"item_id":"pirate_alloy","quantity":8}]}'::jsonb);

  -- (a) blueprint gate: 0 of 2 blueprint_fragment held → the gate ingredient rejects the build.
  r := pg_temp.call_as(uB, format('public.start_hull_build(%L::uuid, %L)', gen_random_uuid(), 'strike_corvette'));
  if (r->>'code') is distinct from 'insufficient_items' or (r->>'item_id') is distinct from 'blueprint_fragment'
     or (r->>'have')::int <> 0 or (r->>'need')::int <> 2 then
    raise exception 'P3 FAIL blueprint-gate shortfall: %', r;
  end if;
  if public.inventory_get_balance(uB,'ore') <> 16 then raise exception 'P3 FAIL shortfall spent ore'; end if;
  if (select balance from public.player_wallet where player_id=uB) <> 100 then raise exception 'P3 FAIL shortfall moved wallet'; end if;

  -- (b) credits short: complete the items (grant blueprint_fragment 2) but the wallet holds 100 < 400.
  perform public.reward_grant('combat', gen_random_uuid(), uB, null,
    '{"items":[{"item_id":"blueprint_fragment","quantity":2}]}'::jsonb);
  r := pg_temp.call_as(uB, format('public.start_hull_build(%L::uuid, %L)', gen_random_uuid(), 'strike_corvette'));
  if (r->>'code') is distinct from 'insufficient_credits' or (r->>'need')::numeric <> 400 then
    raise exception 'P3 FAIL credits shortfall: %', r;
  end if;
  -- ALL-OR-NOTHING ordering: the failed debit spent NO ingredients and moved NO credits.
  if public.inventory_get_balance(uB,'ore') <> 16 or public.inventory_get_balance(uB,'crystal') <> 4
     or public.inventory_get_balance(uB,'weapon_parts') <> 6 or public.inventory_get_balance(uB,'pirate_alloy') <> 8
     or public.inventory_get_balance(uB,'blueprint_fragment') <> 2 then
    raise exception 'P3 FAIL: the credits shortfall consumed ingredients (all-or-nothing broken)';
  end if;
  if (select balance from public.player_wallet where player_id=uB) <> 100 then raise exception 'P3 FAIL credits shortfall moved wallet'; end if;
  select count(*) into n from public.build_orders where player_id=uB;
  if n <> 1 then raise exception 'P3 FAIL a shortfall enqueued an order (% rows)', n; end if;
  if (select count(*) from public.hull_build_receipts where player_id=uB) <> 1 then raise exception 'P3 FAIL a shortfall wrote a receipt'; end if;
  raise notice 'SHIPYARD_PASS_SHORTFALL ok: blueprint_fragment 0/2 -> insufficient_items exact; credits 100<400 -> insufficient_credits with ingredients+wallet untouched; zero writes';
end $$;

-- ════════ P4 — the T2 progression gates, on an in-txn synthetic gated recipe (the T1 seeds are
--          honestly NULL-gated): required hull → required captain level (existence AND level arms)
--          → then the lit positive arm. unknown_hull / no_recipe truthful reasons too. ════════
do $$
declare r jsonb; uB uuid := (select v from sy1 where k='uB'); n int;
begin
  -- unknown_hull vs no_recipe (the 0109 distinct-truthful-reason posture; starter_frigate is the
  -- deliberately recipe-less T0 — the credits-only commission stays the only way to get one).
  r := pg_temp.call_as(uB, format('public.start_hull_build(%L::uuid, %L)', gen_random_uuid(), 'no_such_hull_xyz'));
  if (r->>'code') is distinct from 'unknown_hull' then raise exception 'P4 FAIL unknown_hull: %', r; end if;
  r := pg_temp.call_as(uB, format('public.start_hull_build(%L::uuid, %L)', gen_random_uuid(), 'starter_frigate'));
  if (r->>'code') is distinct from 'no_recipe' then raise exception 'P4 FAIL starter_frigate must be no_recipe: %', r; end if;

  -- in-txn T2 catalog fixture (rolled back): a synthetic hull gated on bulk_hauler + captain lvl 2.
  insert into public.main_ship_hull_types
    (hull_type_id, name, description, base_hp, base_speed, base_cargo_capacity, base_cargo_capacity_m3,
     base_support_capacity, base_captain_slots, base_module_slots, base_stats_json)
    values ('sy1_test_dread', 'SY1 Test Dreadnought', 'sy1 transient fixture (rolled back)',
            1000, 0.5, 50, 50.0, 10, 6, 2, '{"attack": 1, "defense": 1}'::jsonb);
  insert into public.hull_build_recipes
    (hull_type_id, credits_cost, build_seconds, required_hull_type_id, required_captain_level)
    values ('sy1_test_dread', 10, 60, 'bulk_hauler', 2);
  insert into public.hull_recipe_ingredients (hull_type_id, item_id, qty) values ('sy1_test_dread', 'scrap', 1);

  -- (a) required hull NOT owned (uB owns only the starter_frigate; the P1 hauler is a queued
  --     ORDER, not a delivered ship — the seam truth) → hull_prerequisite_not_met.
  r := pg_temp.call_as(uB, format('public.start_hull_build(%L::uuid, %L)', gen_random_uuid(), 'sy1_test_dread'));
  if (r->>'code') is distinct from 'hull_prerequisite_not_met'
     or (r->>'required_hull_type_id') is distinct from 'bulk_hauler' then
    raise exception 'P4 FAIL hull prereq: %', r;
  end if;

  -- (b) prereq satisfied (fixture repoint to the owned starter hull) but ZERO captains → the level
  --     gate rejects on the existence arm.
  update public.hull_build_recipes set required_hull_type_id='starter_frigate' where hull_type_id='sy1_test_dread';
  r := pg_temp.call_as(uB, format('public.start_hull_build(%L::uuid, %L)', gen_random_uuid(), 'sy1_test_dread'));
  if (r->>'code') is distinct from 'captain_level_too_low' or (r->>'required_captain_level')::int <> 2 then
    raise exception 'P4 FAIL level gate (no captains): %', r;
  end if;

  -- (c) a REAL level-1 captain (minted via the sole Captain leaf, 0118) still fails a level-2
  --     requirement → the LEVEL arm rejects, not mere existence.
  perform public.captains_mint_instance(uB, 'gunnery_veteran', 'sy1:' || gen_random_uuid()::text);
  r := pg_temp.call_as(uB, format('public.start_hull_build(%L::uuid, %L)', gen_random_uuid(), 'sy1_test_dread'));
  if (r->>'code') is distinct from 'captain_level_too_low' then raise exception 'P4 FAIL level gate (lvl-1 captain): %', r; end if;

  -- gates wrote nothing.
  if (select count(*) from public.build_orders where player_id=uB) <> 1 then raise exception 'P4 FAIL a gate reject enqueued'; end if;
  if (select balance from public.player_wallet where player_id=uB) <> 100 then raise exception 'P4 FAIL a gate reject moved wallet'; end if;

  -- (d) the lit positive arm: requirement lowered to the level-1 boundary + 1 scrap granted →
  --     the gated build succeeds (10 credits, 1 scrap).
  update public.hull_build_recipes set required_captain_level=1 where hull_type_id='sy1_test_dread';
  perform public.reward_grant('combat', gen_random_uuid(), uB, null, '{"items":[{"item_id":"scrap","quantity":1}]}'::jsonb);
  r := pg_temp.call_as(uB, format('public.start_hull_build(%L::uuid, %L)', gen_random_uuid(), 'sy1_test_dread'));
  if (r->>'ok')::boolean is not true then raise exception 'P4 FAIL gated build: %', r; end if;
  if (select balance from public.player_wallet where player_id=uB) <> 90 then raise exception 'P4 FAIL gated build wallet delta'; end if;
  if public.inventory_get_balance(uB,'scrap') <> 0 then raise exception 'P4 FAIL gated build scrap spend'; end if;
  select count(*) into n from public.build_orders where player_id=uB and status='waiting';
  if n <> 2 then raise exception 'P4 FAIL: expected 2 waiting orders, got %', n; end if;
  raise notice 'SHIPYARD_PASS_GATES ok: unknown_hull/no_recipe truthful; hull prereq reject; captain level reject on BOTH arms (no captain / real lvl-1 vs required 2, sole-leaf mint); boundary pass -> 2nd order queued';
end $$;

-- ════════ P5 — the 0185 self-prereq impossibility: a recipe can NEVER require its own hull. ════════
do $$
declare uB uuid := (select v from sy1 where k='uB');
begin
  insert into public.main_ship_hull_types
    (hull_type_id, name, description, base_hp, base_speed, base_cargo_capacity, base_cargo_capacity_m3,
     base_support_capacity, base_captain_slots, base_module_slots, base_stats_json)
    values ('sy1_selfref', 'SY1 Selfref', 'sy1 transient fixture (rolled back)',
            100, 1.0, 10, 10.0, 10, 6, 1, '{"attack": 1, "defense": 1}'::jsonb);
  begin
    insert into public.hull_build_recipes
      (hull_type_id, credits_cost, build_seconds, required_hull_type_id, required_captain_level)
      values ('sy1_selfref', 1, 60, 'sy1_selfref', null);
    raise exception 'P5 FAIL: a self-prerequisite recipe row was accepted (hull_recipe_no_self_prereq broken)';
  exception
    when check_violation then null;   -- the 0185 CHECK fired — the impossibility holds.
  end;
  raise notice 'SHIPYARD_PASS_SELF_PREREQ ok: required_hull_type_id = own hull -> check_violation (hull_recipe_no_self_prereq)';
end $$;

-- ════════ P6 — the queue-engine SEAM, now CLOSED by 0194 (SHIPYARD-2): the deployed engine
--          carries the hull arm (prosrc pins — behavior proven in P8/P9/P10 below); the
--          kind-coherence CHECK holds; the shared queue cap counts hull orders. ════════
do $$
declare r jsonb; uB uuid := (select v from sy1 where k='uB'); n int; v_src text;
begin
  -- seam CLOSED by 0194: the deployed engine bodies carry BOTH arms — the byte-intact 0038 unit
  -- arm and the SHIPYARD-2 hull arm (promotion join / kind dispatch / commission delivery).
  select prosrc into v_src from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='public' and p.proname='production_start_next';
  if v_src is null or strpos(v_src, 'join unit_types ut on ut.id = bo.unit_type_id') = 0
     or strpos(v_src, 'join hull_build_recipes hr on hr.hull_type_id = bo.hull_type_id') = 0 then
    raise exception 'P6 FAIL: production_start_next does not carry BOTH the byte-intact unit arm and the 0194 hull arm';
  end if;
  select prosrc into v_src from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='public' and p.proname='process_build_queue';
  if v_src is null or strpos(v_src, 'if o.hull_type_id is null then') = 0 then
    raise exception 'P6 FAIL: process_build_queue lacks the 0194 kind dispatch (base_merge_units would fire on a hull row)';
  end if;
  select prosrc into v_src from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='public' and p.proname='production_complete_order';
  if v_src is null or strpos(v_src, 'port_entry_commission_build') = 0 then
    raise exception 'P6 FAIL: production_complete_order does not deliver through the ONE commission build core';
  end if;

  -- kind coherence: a bare row and a hybrid row are both impossible by CHECK.
  begin
    insert into public.build_orders (player_id, quantity, status, queued_at) values (uB, 1, 'waiting', now());
    raise exception 'P6 FAIL: a bare (no unit, no hull) build_orders row was accepted';
  exception when check_violation then null;
  end;
  declare v_unit text;
  begin
    select id into v_unit from public.unit_types limit 1;   -- seeded catalog: always present
    if v_unit is null then raise exception 'P6 FAIL: unit_types catalog empty (fixture grounding broken)'; end if;
    begin
      insert into public.build_orders (player_id, hull_type_id, unit_type_id, quantity, status, queued_at)
        values (uB, 'bulk_hauler', v_unit, 1, 'waiting', now());
      raise exception 'P6 FAIL: a hybrid hull+unit build_orders row was accepted';
    exception when check_violation then null;
    end;
  end;

  -- the SHARED M4.5 cap: with 2 non-terminal hull orders and max_build_orders lowered to 2 (knob,
  -- in-txn), a third order rejects queue_full BEFORE any spend.
  insert into public.game_config(key,value,description) values ('max_build_orders','2'::jsonb,'sy1 transient (rolled back)')
    on conflict (key) do update set value='2'::jsonb;
  perform public.reward_grant('combat', gen_random_uuid(), uB, null, '{"items":[{"item_id":"scrap","quantity":1}]}'::jsonb);
  r := pg_temp.call_as(uB, format('public.start_hull_build(%L::uuid, %L)', gen_random_uuid(), 'sy1_test_dread'));
  if (r->>'code') is distinct from 'queue_full' or (r->>'max')::int <> 2 then raise exception 'P6 FAIL queue_full: %', r; end if;
  if public.inventory_get_balance(uB,'scrap') <> 1 then raise exception 'P6 FAIL queue_full spent items'; end if;
  if (select balance from public.player_wallet where player_id=uB) <> 90 then raise exception 'P6 FAIL queue_full moved wallet'; end if;

  raise notice 'SHIPYARD_PASS_QUEUE_SEAM ok: seam CLOSED by 0194 — the engine carries both arms (unit tokens byte-intact + hull promotion join + kind dispatch + commission delivery, prosrc-pinned); bare+hybrid rows check-rejected; shared cap queue_full at 2 with zero writes';
end $$;

-- ════════ P7 — RETENTION (review H1): the receipt OUTLIVES the 0047 reaper — a purged order row
--          can NEVER expire the replay guarantee (a stale retry must not place a second
--          full-price order) nor destroy the audit bill. ════════
do $$
declare r jsonb; uB uuid := (select v from sy1 where k='uB'); v_req uuid := (select v from sy1 where k='req1');
  v_order uuid := (select v from sy1 where k='order1'); n int; v_bal0 numeric; nord int;
begin
  -- make the P1 order reapable — terminal + aged past the 30-day window (fixture shaping of
  -- Production's own runtime row, in-txn, rolled back) — then run the REAL 0047 reaper
  -- (maintenance_cleanup_runtime_data §10: terminal build_orders with updated_at > 30d).
  update public.build_orders set status='cancelled', resolved_at=now(), updated_at=now()-interval '31 days'
    where id=v_order;
  perform count(*) from public.maintenance_cleanup_runtime_data(false, 5000);

  select count(*) into n from public.build_orders where id=v_order;
  if n <> 0 then raise exception 'P7 FAIL: the 0047 reaper did not purge the aged terminal order'; end if;
  -- the receipt SURVIVED, order_id set NULL, every audit field intact.
  select count(*) into n from public.hull_build_receipts
    where player_id=uB and request_id=v_req and order_id is null
      and hull_type_id='bulk_hauler' and credits_spent=400 and jsonb_array_length(ingredients_json)=5;
  if n <> 1 then raise exception 'P7 FAIL: the receipt did not survive the reap with order_id NULL + fields intact'; end if;

  -- the stale retry (the day-32 shape): the SAME request_id still replays the ORIGINAL envelope
  -- from the receipt row ALONE — no new debit, no new order, no second receipt.
  select balance into v_bal0 from public.player_wallet where player_id=uB;
  select count(*) into nord from public.build_orders where player_id=uB;
  r := pg_temp.call_as(uB, format('public.start_hull_build(%L::uuid, %L)', v_req, 'bulk_hauler'));
  if (r->>'ok')::boolean is not true or (r->>'idempotent_replay')::boolean is not true then raise exception 'P7 FAIL post-reap not replay: %', r; end if;
  if (r->>'credits_spent')::numeric <> 400 or (r->>'hull_type_id') is distinct from 'bulk_hauler' then raise exception 'P7 FAIL post-reap envelope: %', r; end if;
  if r->'order_id' is distinct from 'null'::jsonb then raise exception 'P7 FAIL post-reap order_id not null in the replay: %', r; end if;
  if (select balance from public.player_wallet where player_id=uB) <> v_bal0 then raise exception 'P7 FAIL post-reap replay re-debited'; end if;
  if (select count(*) from public.build_orders where player_id=uB) <> nord then raise exception 'P7 FAIL post-reap replay placed a SECOND order'; end if;
  if (select count(*) from public.hull_build_receipts where player_id=uB) <> 2 then raise exception 'P7 FAIL post-reap receipt count moved'; end if;
  raise notice 'SHIPYARD_PASS_RETENTION ok: real 0047 reaper purged the aged terminal order; receipt survived (order_id->NULL, bill intact); stale same-request_id retry replayed the original envelope verbatim, no re-debit, no second order';
end $$;

-- ════════ P8 — SHIPYARD-2 PROMOTE: the cron sweep promotes a stalled waiting hull order with
--          recipe build_seconds EXACT; the serial one-slot law holds ACROSS kinds (a unit order
--          and a second hull order both stay waiting); the 0188 order RPC still enqueues
--          'waiting' (the CRON is the promoter — the order side is untouched). ════════
do $$
declare r jsonb; uB uuid := (select v from sy1 where k='uB'); v_done int; v_base uuid;
  v_uorder uuid; v_order3 uuid; v_req3 uuid := gen_random_uuid();
begin
  -- headroom for the remaining blocks (the P6 cap fixture lowered it to 2; in-txn, rolled back).
  update public.game_config set value='5'::jsonb where key='max_build_orders';

  -- pre-state: the P4 dread order is the SOLE order — waiting, NO timestamps, slot free.
  if not exists (select 1 from public.build_orders
                   where player_id=uB and hull_type_id='sy1_test_dread' and status='waiting'
                     and started_at is null and complete_at is null) then
    raise exception 'P8 FAIL pre-state: the dread order is not a bare waiting row';
  end if;

  -- the REAL cron entry point: no due actives (completes 0) but the 0194 hull sweep promotes the
  -- stalled waiting hull order — with the recipe's build_seconds, EXACT (fixture recipe: 60s).
  select public.process_build_queue() into v_done;
  if v_done <> 0 then raise exception 'P8 FAIL: process_build_queue completed % orders (want 0 — promotion only)', v_done; end if;
  if not exists (select 1 from public.build_orders
                   where player_id=uB and hull_type_id='sy1_test_dread' and status='active'
                     and started_at is not null
                     and complete_at - started_at = interval '60 seconds') then
    raise exception 'P8 FAIL: the cron sweep did not promote the waiting hull order with recipe build_seconds exact (60s)';
  end if;

  -- the serial one-slot law ACROSS kinds: a unit order (real Base bootstrap + the real Production
  -- creator) and a second hull order (real RPC) both queue WAITING behind the active hull build.
  perform set_config('request.jwt.claims', json_build_object('sub', uB::text, 'role','authenticated')::text, true);
  perform public.bootstrap_me();
  select id into v_base from public.bases where player_id=uB order by created_at limit 1;
  if v_base is null then raise exception 'P8 FAIL: bootstrap_me created no base'; end if;
  v_uorder := public.production_create_order(uB, v_base, 'scout', 2, 100);
  perform public.production_start_next(uB);   -- direct promoter call: must NOT double-promote
  if not exists (select 1 from public.build_orders
                   where id=v_uorder and status='waiting' and started_at is null and complete_at is null) then
    raise exception 'P8 FAIL: the unit order jumped the serial one-slot law';
  end if;

  insert into public.player_wallet (player_id, balance) values (uB, 500)
    on conflict (player_id) do update set balance = excluded.balance;
  perform public.reward_grant('combat', gen_random_uuid(), uB, null,
    '{"items":[{"item_id":"ore","quantity":24},{"item_id":"crystal","quantity":6},{"item_id":"engine_parts","quantity":6},{"item_id":"scrap","quantity":12},{"item_id":"blueprint_fragment","quantity":2}]}'::jsonb);
  r := pg_temp.call_as(uB, format('public.start_hull_build(%L::uuid, %L)', v_req3, 'bulk_hauler'));
  if (r->>'ok')::boolean is not true then raise exception 'P8 FAIL hauler order: %', r; end if;
  v_order3 := (r->>'order_id')::uuid;
  if not exists (select 1 from public.build_orders
                   where id=v_order3 and status='waiting' and started_at is null and complete_at is null) then
    raise exception 'P8 FAIL: the order RPC no longer enqueues waiting (the 0188 order side must stay untouched — the cron is the promoter)';
  end if;

  insert into sy1 values ('base',   v_base);
  insert into sy1 values ('uorder', v_uorder);
  insert into sy1 values ('order3', v_order3);
  insert into sy1 values ('req3',   v_req3);
  raise notice 'SHIPYARD_PASS_PROMOTE ok: cron sweep promoted the stalled waiting hull order with recipe build_seconds exact (60s); serial one-slot law holds across kinds (unit + second hull stay waiting, no timestamps); the order RPC still enqueues waiting';
end $$;

-- ════════ P9 — SHIPYARD-2 DELIVER: fast-forward (two-timestamp shift, duration preserved) →
--          the completion delivers the ship through the commission core — exact hull stats,
--          exact 0184 name idiom (class name + per-player roman numeral), docked at the
--          commission port; unit orders complete IDENTICALLY (base_merge_units, no ship — the
--          exact 0038 unit formula on promotion); post-delivery replay returns the ORIGINAL
--          envelope verbatim. ════════
do $$
declare r jsonb; uB uuid := (select v from sy1 where k='uB'); v_done int;
  v_base uuid := (select v from sy1 where k='base'); v_uorder uuid := (select v from sy1 where k='uorder');
  v_order3 uuid := (select v from sy1 where k='order3'); v_req3 uuid := (select v from sy1 where k='req3');
  v_ships0 int; v_scouts0 int; v_ship uuid; n int; v_rcpts int;
begin
  select count(*) into v_ships0 from public.main_ship_instances where player_id=uB;   -- 1 (the starter)
  select quantity into v_scouts0 from public.base_units where base_id=v_base and unit_type_id='scout';

  -- (a) the DREAD delivery: fast-forward the active hull order with the two-timestamp shift
  --     (started_at AND complete_at move together — the stamped duration is preserved) by EXACTLY
  --     the 60s duration (review B1): the whole proof is ONE txn, so now() is frozen at T and
  --     queued_at = T — a shift of MORE than the duration would land complete_at < queued_at and
  --     trip the 0038 build_orders_complete_after_queue CHECK (23514); the exact-duration shift
  --     lands complete_at = T, which is both due (complete_at <= now()) and constraint-legal.
  update public.build_orders
     set started_at = started_at - interval '60 seconds', complete_at = complete_at - interval '60 seconds'
   where player_id=uB and hull_type_id='sy1_test_dread' and status='active';
  select public.process_build_queue() into v_done;
  if v_done <> 1 then raise exception 'P9 FAIL: expected exactly 1 completion, got %', v_done; end if;
  if not exists (select 1 from public.build_orders
                   where player_id=uB and hull_type_id='sy1_test_dread' and status='completed' and resolved_at is not null) then
    raise exception 'P9 FAIL: the due hull order is not terminal completed';
  end if;
  select main_ship_id into v_ship from public.main_ship_instances
    where player_id=uB and hull_type_id='sy1_test_dread';
  if v_ship is null then raise exception 'P9 FAIL: no ship was delivered'; end if;
  -- exact hull stats + the exact 0184 name idiom (2nd ship -> class name + '' II'').
  if not exists (select 1 from public.main_ship_instances
                   where main_ship_id=v_ship and name='SY1 Test Dreadnought II'
                     and hp=1000 and max_hp=1000 and cargo_capacity=50 and cargo_capacity_m3=50.0
                     and support_capacity=10 and captain_slots=6 and module_slots=2
                     and status='stationary' and spatial_state='at_location'
                     and space_x is null and space_y is null) then
    raise exception 'P9 FAIL: the delivered ship is not the exact hull stats/name shape (want SY1 Test Dreadnought II, 1000hp, 50 cargo, canonical at_location)';
  end if;
  -- docked at the commission port: the present/location fleet + canonical at_location coherence.
  if not exists (select 1 from public.fleets
                   where player_id=uB and main_ship_id=v_ship and status='present' and location_mode='location'
                     and current_location_id='b1a00001-0066-4a00-8a00-000000000001'::uuid) then
    raise exception 'P9 FAIL: the delivered ship has no present/location fleet at the commission port';
  end if;
  if (public.mainship_space_validate_context(v_ship)->>'state') is distinct from 'at_location' then
    raise exception 'P9 FAIL: the delivered ship is not canonical at_location';
  end if;
  if (select count(*) from public.main_ship_instances where player_id=uB) <> v_ships0 + 1 then
    raise exception 'P9 FAIL: ship count moved wrong';
  end if;
  -- the freed slot chained to the OLDEST waiting order — the UNIT one — promoted with the exact
  -- 0038 unit formula (scout 30s x qty 2 x scale 1.0 = 60s): unit orders promote identically.
  if not exists (select 1 from public.build_orders
                   where id=v_uorder and status='active' and started_at is not null
                     and complete_at - started_at = interval '60 seconds') then
    raise exception 'P9 FAIL: the unit order did not promote with the exact 0038 unit formula (30s x 2 x 1.0)';
  end if;
  if not exists (select 1 from public.build_orders where id=v_order3 and status='waiting') then
    raise exception 'P9 FAIL: the younger hull order jumped the queue';
  end if;

  -- (b) the UNIT delivery stays the 0038 shape: fast-forward -> base_merge_units (+2 scouts to
  --     the base), NO ship minted, completion chains promotion to the waiting hull order.
  --     (Exact-duration shift again — the B1 constraint law: complete_at lands at queued_at.)
  update public.build_orders
     set started_at = started_at - interval '60 seconds', complete_at = complete_at - interval '60 seconds'
   where id=v_uorder and status='active';
  select public.process_build_queue() into v_done;
  if v_done <> 1 then raise exception 'P9 FAIL: expected exactly 1 unit completion, got %', v_done; end if;
  if not exists (select 1 from public.build_orders where id=v_uorder and status='completed') then
    raise exception 'P9 FAIL: the unit order is not completed';
  end if;
  if (select quantity from public.base_units where base_id=v_base and unit_type_id='scout') <> v_scouts0 + 2 then
    raise exception 'P9 FAIL: base_merge_units did not land exactly +2 scouts (the unit delivery parity)';
  end if;
  if (select count(*) from public.main_ship_instances where player_id=uB) <> v_ships0 + 1 then
    raise exception 'P9 FAIL: a unit completion minted a ship (kind dispatch broken)';
  end if;
  -- the hauler now holds the slot — with the REAL 0185 recipe build_seconds, EXACT (3600s).
  if not exists (select 1 from public.build_orders
                   where id=v_order3 and status='active' and started_at is not null
                     and complete_at - started_at = interval '3600 seconds') then
    raise exception 'P9 FAIL: the hauler did not promote with the real 0185 recipe build_seconds (3600s)';
  end if;

  -- (c) the MULE delivery: 3rd ship -> 'Mule-class Hauler III' with the exact 0185 hull stats.
  --     (Exact-duration shift again — the B1 constraint law: complete_at lands at queued_at.)
  update public.build_orders
     set started_at = started_at - interval '3600 seconds', complete_at = complete_at - interval '3600 seconds'
   where id=v_order3 and status='active';
  select public.process_build_queue() into v_done;
  if v_done <> 1 then raise exception 'P9 FAIL: expected exactly 1 hauler completion, got %', v_done; end if;
  if not exists (select 1 from public.main_ship_instances
                   where player_id=uB and hull_type_id='bulk_hauler' and name='Mule-class Hauler III'
                     and hp=650 and max_hp=650 and cargo_capacity=140 and cargo_capacity_m3=140.0
                     and support_capacity=10 and captain_slots=6 and module_slots=2
                     and status='stationary' and spatial_state='at_location') then
    raise exception 'P9 FAIL: the delivered Mule is not the exact hull stats/name shape (want Mule-class Hauler III, 650hp, 140 cargo)';
  end if;
  if not exists (select 1 from public.build_orders where id=v_order3 and status='completed' and resolved_at is not null) then
    raise exception 'P9 FAIL: the hauler order is not terminal completed';
  end if;

  -- (d) post-delivery replay: the SAME request_id still returns the ORIGINAL success envelope
  --     verbatim from the receipt ALONE — a DELIVERED order changes nothing (the receipt path
  --     never consults order state): no re-debit, no second order, no second ship.
  select count(*) into v_rcpts from public.hull_build_receipts where player_id=uB;
  select count(*) into n from public.build_orders where player_id=uB;
  r := pg_temp.call_as(uB, format('public.start_hull_build(%L::uuid, %L)', v_req3, 'bulk_hauler'));
  if (r->>'ok')::boolean is not true or (r->>'idempotent_replay')::boolean is not true then
    raise exception 'P9 FAIL post-delivery replay not a replay: %', r;
  end if;
  if (r->>'order_id')::uuid is distinct from v_order3 or (r->>'credits_spent')::numeric <> 400
     or jsonb_array_length(r->'ingredients_spent') <> 5 then
    raise exception 'P9 FAIL post-delivery replay envelope not the verbatim original: %', r;
  end if;
  if (select balance from public.player_wallet where player_id=uB) <> 100 then raise exception 'P9 FAIL post-delivery replay re-debited'; end if;
  if (select count(*) from public.build_orders where player_id=uB) <> n then raise exception 'P9 FAIL post-delivery replay placed a second order'; end if;
  if (select count(*) from public.hull_build_receipts where player_id=uB) <> v_rcpts then raise exception 'P9 FAIL post-delivery replay wrote a receipt'; end if;
  if (select count(*) from public.main_ship_instances where player_id=uB) <> v_ships0 + 2 then raise exception 'P9 FAIL post-delivery replay minted a ship'; end if;

  raise notice 'SHIPYARD_PASS_DELIVER ok: two-timestamp fast-forward -> commission-core delivery (SY1 Test Dreadnought II + Mule-class Hauler III, exact hull stats + 0184 name idiom, docked present/location fleet at the commission port, canonical at_location); unit order promoted/completed identically (the exact 0038 unit formula, base_merge_units +2, no ship); orders terminal; post-delivery replay verbatim (no re-debit/order/receipt/ship)';
end $$;

-- ════════ P9G — SHIPYARD-2 DELIVERY GUARD (review H1): a POISONED delivery (the commission port
--          undockable, in-txn fixture) must NOT wedge the cron — a SECOND player's due unit
--          completion in the SAME tick proceeds, the poisoned hull order stays 'active' (no
--          half-completion), and after the fixture is restored the next tick delivers it. ════════
do $$
declare r jsonb; uB uuid := (select v from sy1 where k='uB'); uC uuid;
  v_baseC uuid; v_uorderC uuid; v_reqH2 uuid := gen_random_uuid(); v_oH2 uuid;
  v_done int; v_scoutsC0 int; v_ships0 int; v_mules0 int;
begin
  -- a SECOND fixture player uC (the same sy1 idiom): base via the real bootstrap leaf + a real
  -- unit order, promoted and fast-forwarded (exact-duration shift — the B1 constraint law).
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'sy1.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uC;
  perform set_config('request.jwt.claims', json_build_object('sub', uC::text, 'role','authenticated')::text, true);
  perform public.bootstrap_me();
  select id into v_baseC from public.bases where player_id=uC order by created_at limit 1;
  if v_baseC is null then raise exception 'P9G FAIL: bootstrap_me created no base for uC'; end if;
  select quantity into v_scoutsC0 from public.base_units where base_id=v_baseC and unit_type_id='scout';
  v_uorderC := public.production_create_order(uC, v_baseC, 'scout', 2, 50);
  perform public.production_start_next(uC);
  update public.build_orders
     set started_at = started_at - interval '60 seconds', complete_at = complete_at - interval '60 seconds'
   where id=v_uorderC and status='active';

  -- uB: a fresh hauler build, promoted and fast-forwarded due (exact-duration shift, 3600s).
  select count(*) into v_ships0 from public.main_ship_instances where player_id=uB;
  select count(*) into v_mules0 from public.main_ship_instances where player_id=uB and hull_type_id='bulk_hauler';
  insert into public.player_wallet (player_id, balance) values (uB, 500)
    on conflict (player_id) do update set balance = excluded.balance;
  perform public.reward_grant('combat', gen_random_uuid(), uB, null,
    '{"items":[{"item_id":"ore","quantity":24},{"item_id":"crystal","quantity":6},{"item_id":"engine_parts","quantity":6},{"item_id":"scrap","quantity":12},{"item_id":"blueprint_fragment","quantity":2}]}'::jsonb);
  r := pg_temp.call_as(uB, format('public.start_hull_build(%L::uuid, %L)', v_reqH2, 'bulk_hauler'));
  if (r->>'ok')::boolean is not true then raise exception 'P9G FAIL hauler order: %', r; end if;
  v_oH2 := (r->>'order_id')::uuid;
  perform public.production_start_next(uB);
  update public.build_orders
     set started_at = started_at - interval '3600 seconds', complete_at = complete_at - interval '3600 seconds'
   where id=v_oH2 and status='active';

  -- POISON the delivery (in-txn fixture, restored below): the commission port's docking service
  -- goes 'disabled' -> mainship_space_location_target_legal fails -> build raises -> the delivery
  -- subtransaction rolls THAT order back. Both orders are due in the SAME tick.
  update public.location_services set status='disabled'
   where location_id='b1a00001-0066-4a00-8a00-000000000001'::uuid and service='docking';

  select public.process_build_queue() into v_done;
  if v_done <> 1 then
    raise exception 'P9G FAIL: expected exactly 1 completion under poison (uC''s unit; the poisoned hull must not count), got %', v_done;
  end if;
  -- uC's unit completion PROCEEDED in the same tick (the whole point of the per-order guard):
  if not exists (select 1 from public.build_orders where id=v_uorderC and status='completed') then
    raise exception 'P9G FAIL: the poisoned delivery blocked another player''s due unit completion (cron wedge)';
  end if;
  if (select quantity from public.base_units where base_id=v_baseC and unit_type_id='scout') <> v_scoutsC0 + 2 then
    raise exception 'P9G FAIL: the co-tick unit completion did not merge exactly +2 scouts';
  end if;
  -- the poisoned hull order is UNTOUCHED — still active (no half-completion, no cancel, no ship):
  if not exists (select 1 from public.build_orders where id=v_oH2 and status='active') then
    raise exception 'P9G FAIL: the poisoned hull order did not stay active for retry';
  end if;
  if (select count(*) from public.main_ship_instances where player_id=uB) <> v_ships0 then
    raise exception 'P9G FAIL: a poisoned delivery minted a ship';
  end if;

  -- RESTORE the fixture; the next tick retries and delivers (self-healing — no manual repair).
  update public.location_services set status='active'
   where location_id='b1a00001-0066-4a00-8a00-000000000001'::uuid and service='docking';
  select public.process_build_queue() into v_done;
  if v_done <> 1 then raise exception 'P9G FAIL: the restored retry did not complete exactly 1 order, got %', v_done; end if;
  if not exists (select 1 from public.build_orders where id=v_oH2 and status='completed' and resolved_at is not null) then
    raise exception 'P9G FAIL: the restored retry did not complete the hull order';
  end if;
  if (select count(*) from public.main_ship_instances where player_id=uB and hull_type_id='bulk_hauler') <> v_mules0 + 1
     or (select count(*) from public.main_ship_instances where player_id=uB) <> v_ships0 + 1 then
    raise exception 'P9G FAIL: the restored retry did not deliver exactly 1 ship';
  end if;

  raise notice 'SHIPYARD_PASS_DELIVERY_GUARD ok: poisoned delivery (port undockable) left its order active and UNCOUNTED while another player''s due unit completion proceeded in the SAME tick (no cron wedge); fixture restored -> the next tick retried and delivered exactly 1 ship (self-healing)';
end $$;

-- ════════ P10 — SHIPYARD-2 CANCEL REFUND: waiting hull cancel -> EXACT full refund (credits via
--          Wallet + every ingredient via Inventory from the receipt bill); double-cancel rejected
--          with NO double refund; post-cancel replay still verbatim; active hull cancel -> the
--          unit arm''s 50% law (floored credits + floor-half per ingredient). ════════
do $$
declare r jsonb; uB uuid := (select v from sy1 where k='uB');
  v_reqC1 uuid := gen_random_uuid(); v_reqC2 uuid := gen_random_uuid();
  v_oC1 uuid; v_oC2 uuid; v_ships int; v_done int; n int;
begin
  select count(*) into v_ships from public.main_ship_instances where player_id=uB;

  -- (a) a WAITING corvette order: fund to a known 500, spend the exact P3 corvette mats.
  insert into public.player_wallet (player_id, balance) values (uB, 500)
    on conflict (player_id) do update set balance = excluded.balance;
  r := pg_temp.call_as(uB, format('public.start_hull_build(%L::uuid, %L)', v_reqC1, 'strike_corvette'));
  if (r->>'ok')::boolean is not true then raise exception 'P10 FAIL corvette order: %', r; end if;
  v_oC1 := (r->>'order_id')::uuid;
  if (select balance from public.player_wallet where player_id=uB) <> 100
     or public.inventory_get_balance(uB,'ore') <> 0 or public.inventory_get_balance(uB,'blueprint_fragment') <> 0 then
    raise exception 'P10 FAIL: the corvette order did not spend exactly';
  end if;
  if not exists (select 1 from public.build_orders where id=v_oC1 and status='waiting') then
    raise exception 'P10 FAIL: the corvette order is not waiting (cancel-waiting is the arm under test)';
  end if;

  -- (b) cancel WAITING -> 100%: credits and EVERY ingredient restored exactly from the receipt
  --     bill (wallet 100 -> 500: the full credit refund plus every item back).
  perform set_config('request.jwt.claims', json_build_object('sub', uB::text, 'role','authenticated')::text, true);
  perform public.cancel_build_order(v_oC1);
  if not exists (select 1 from public.build_orders where id=v_oC1 and status='cancelled' and resolved_at is not null) then
    raise exception 'P10 FAIL: the cancelled order is not terminal cancelled';
  end if;
  if (select balance from public.player_wallet where player_id=uB) <> 500 then
    raise exception 'P10 FAIL waiting-cancel credits: wallet % (want exactly 500 = 100 + the full 400-credit refund)',
      (select balance from public.player_wallet where player_id=uB);
  end if;
  if public.inventory_get_balance(uB,'ore') <> 16 or public.inventory_get_balance(uB,'crystal') <> 4
     or public.inventory_get_balance(uB,'weapon_parts') <> 6 or public.inventory_get_balance(uB,'pirate_alloy') <> 8
     or public.inventory_get_balance(uB,'blueprint_fragment') <> 2 then
    raise exception 'P10 FAIL waiting-cancel ingredients: not the exact receipt bill restored (want 16/4/6/8/2)';
  end if;
  if (select count(*) from public.main_ship_instances where player_id=uB) <> v_ships then
    raise exception 'P10 FAIL: a cancel delivered a ship';
  end if;

  -- (c) double-cancel: rejected at the status check — NO double refund.
  begin
    perform public.cancel_build_order(v_oC1);
    raise exception 'P10 FAIL: double-cancel was accepted';
  exception when others then
    if sqlerrm not like '%cannot cancel a cancelled order%' then raise; end if;
  end;
  if (select balance from public.player_wallet where player_id=uB) <> 500
     or public.inventory_get_balance(uB,'ore') <> 16 then
    raise exception 'P10 FAIL: the rejected double-cancel refunded again';
  end if;

  -- (d) post-cancel replay: the receipt is NEVER rewritten — the same request_id still returns
  --     the ORIGINAL success envelope verbatim; nothing re-spends, no second order.
  select count(*) into n from public.build_orders where player_id=uB;
  r := pg_temp.call_as(uB, format('public.start_hull_build(%L::uuid, %L)', v_reqC1, 'strike_corvette'));
  if (r->>'ok')::boolean is not true or (r->>'idempotent_replay')::boolean is not true
     or (r->>'order_id')::uuid is distinct from v_oC1 or (r->>'credits_spent')::numeric <> 400
     or jsonb_array_length(r->'ingredients_spent') <> 5 then
    raise exception 'P10 FAIL post-cancel replay envelope not the verbatim original: %', r;
  end if;
  if (select balance from public.player_wallet where player_id=uB) <> 500
     or public.inventory_get_balance(uB,'ore') <> 16
     or (select count(*) from public.build_orders where player_id=uB) <> n then
    raise exception 'P10 FAIL: the post-cancel replay moved state';
  end if;

  -- (e) cancel ACTIVE -> the unit arm''s 50% law: re-order, let the cron sweep promote it, cancel:
  --     credits floor(400 x 0.5) = 200 (wallet 100 -> 300 exact) + the floor-half refund per
  --     ingredient (ore 8, crystal 2, weapon_parts 3, pirate_alloy 4, blueprint_fragment 1).
  r := pg_temp.call_as(uB, format('public.start_hull_build(%L::uuid, %L)', v_reqC2, 'strike_corvette'));
  if (r->>'ok')::boolean is not true then raise exception 'P10 FAIL second corvette order: %', r; end if;
  v_oC2 := (r->>'order_id')::uuid;
  select public.process_build_queue() into v_done;   -- no due actives; the sweep promotes
  if not exists (select 1 from public.build_orders where id=v_oC2 and status='active') then
    raise exception 'P10 FAIL: the second corvette order was not sweep-promoted to active';
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', uB::text, 'role','authenticated')::text, true);
  perform public.cancel_build_order(v_oC2);
  if not exists (select 1 from public.build_orders where id=v_oC2 and status='cancelled') then
    raise exception 'P10 FAIL: the active order did not cancel';
  end if;
  if (select balance from public.player_wallet where player_id=uB) <> 300 then
    raise exception 'P10 FAIL active-cancel credits: wallet % (want exactly 300 = 100 + floor(400 x 0.5))',
      (select balance from public.player_wallet where player_id=uB);
  end if;
  if public.inventory_get_balance(uB,'ore') <> 8 or public.inventory_get_balance(uB,'crystal') <> 2
     or public.inventory_get_balance(uB,'weapon_parts') <> 3 or public.inventory_get_balance(uB,'pirate_alloy') <> 4
     or public.inventory_get_balance(uB,'blueprint_fragment') <> 1 then
    raise exception 'P10 FAIL active-cancel ingredients: not the exact floor-half refund (want 8/2/3/4/1)';
  end if;
  if (select count(*) from public.main_ship_instances where player_id=uB) <> v_ships then
    raise exception 'P10 FAIL: an active-cancel delivered a ship';
  end if;

  raise notice 'SHIPYARD_PASS_CANCEL_REFUND ok: waiting hull cancel -> exact full refund from the receipt bill (credits via Wallet, every ingredient via Inventory); double-cancel rejected, no double refund; post-cancel replay verbatim; active hull cancel -> the unit-arm 50%% law (floored credits + floor-half per ingredient) exact';
end $$;

select 'SHIPYARD-1+2 PROOF PASSED (dark gate + no existence oracle; exact-spend order on the M4.5 queue; verbatim replay; blueprint/credit shortfalls all-or-nothing; hull + captain-level gates both arms; self-prereq impossible; engine seam CLOSED — cron-sweep promotion with recipe build_seconds, commission-core delivery with exact stats + name idiom, unit arm byte-parity, poisoned-delivery guard (no cron wedge), hull-aware cancel refunds; receipts outlive the 0047 reaper)' as result;

rollback;   -- leave ZERO persisted state: no order, receipt, wallet, inventory, ship, captain, base, unit, fleet, catalog fixture, or flag flip.
