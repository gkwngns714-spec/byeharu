-- PORT-SHOP — disposable REAL-CHAIN proof (runs on the actual chain 0001..0235 in a throwaway Supabase).
-- Proves PORT-SHOP (0235): the dark gate, the seeded beginner outfit, and the atomic buy_shop_offer_at_port
-- surface — buy a MODULE (mint one instance + exact debit + receipt), buy an ITEM/ammo (deposit + exact
-- debit + receipt), idempotent replay, and the guard envelope (invalid_quantity, no_offer,
-- module_qty_must_be_one, insufficient_credits). The ENTIRE proof runs inside ONE transaction
-- that ROLLBACKs — it persists NO wallet, inventory, module_instance, receipt, ship, or flag flip. No
-- production access. No COMMIT anywhere. Fixture users carry the 'ps1.' email prefix.
--
-- ── DARK-CAPABILITY EXERCISE (sanctioned; never crosses a flag human-gate) ────────────────────────
-- The harness enables port_shop_enabled ONLY inside this rolled-back transaction (AFTER proving the dark
-- reject); the ROLLBACK reverts it, so the committed/production flag stays false. It transiently mirrors
-- production config a fresh chain lacks (reveal_starter_ports + mainship_space_movement_enabled) — all
-- reverted by ROLLBACK. Ships are commissioned via the REAL commission_first_main_ship() RPC (docked at
-- Haven); wallets are pre-seeded by a direct owner insert (the repair-proof precedent) so every credit
-- assert is an EXACT delta. The harness NEVER writes port_shop_offers / module_instances /
-- base_items / port_shop_receipts directly — every grant + receipt is minted by the RPC under test.
--
-- ── WHERE THE ITEMS ARE (0333) ────────────────────────────────────────────────────────────────────
-- `player_inventory` (the global pool) is DROPPED: items live PER PORT in `base_items`, keyed to the
-- player's `bases` row for that port. `buy_shop_offer_at_port` now deposits what you bought into the
-- store of the port you are DOCKED AT. uB is docked at HAVEN throughout, so the ammo assertions below
-- are measured at Haven's store — `get_or_create_store(uB, haven)`, the exact row the RPC deposits to.

\set ON_ERROR_STOP on

begin;   -- everything below is transient; the trailing ROLLBACK leaves ZERO persisted state.

create temp table ps1(k text primary key, v uuid) on commit preserve rows;
insert into ps1 values
  ('haven','b1a00001-0066-4a00-8a00-000000000001'),     -- Haven (commission port)
  ('slag', 'b1a00002-0066-4a00-8a00-000000000002'),     -- Slagworks
  ('drift','b1a00003-0066-4a00-8a00-000000000003');     -- Driftmarch

-- caller helper: set the authenticated subject then run an RPC, returning its jsonb.
create or replace function pg_temp.call_as(p_sub uuid, p_fn text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_fn into v;
  return v;
end $$;

-- two fresh players: uB (buyer, funded), uP (poor — the insufficient_credits arm).
do $$
declare u uuid; sk text;
begin
  foreach sk in array array['uB','uP'] loop
    insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
      values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
              'ps1.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
      returning id into u;
    insert into ps1 values (sk, u);
  end loop;
end $$;

-- mirror production config a fresh disposable chain lacks (all reverted by ROLLBACK): reveal starter ports
-- + enable port-to-port movement. port_shop_enabled stays OFF here (P0 proves the dark reject first).
do $$
declare r jsonb;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: reveal_starter_ports %', r; end if;
  insert into public.game_config(key,value,description)
    values('mainship_space_movement_enabled','true'::jsonb,'ps1 transient (rolled back)')
    on conflict (key) do update set value='true'::jsonb;
end $$;

-- commission each player's first ship (real RPC) → docked at Haven; pre-seed wallets at KNOWN balances by
-- direct owner insert (the repair-proof funding precedent; rolled back) so every credit assert is EXACT.
do $$
declare r jsonb; sk text; u uuid;
begin
  foreach sk in array array['uB','uP'] loop
    u := (select v from ps1 where ps1.k = sk);
    r := pg_temp.call_as(u, 'public.commission_first_main_ship()');
    if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then raise exception 'SETUP FAIL first-ship %: %', sk, r; end if;
  end loop;
  insert into public.player_wallet (player_id, balance) values
    ((select v from ps1 where k='uB'), 1000),
    ((select v from ps1 where k='uP'), 0)       -- poor: the insufficient_credits arm
  on conflict (player_id) do update set balance = excluded.balance;
  -- 0333: items live PER PORT. Resolve uB's store AT HAVEN once and stash it — Haven is the port uB
  -- is docked at for every buy below, so it is where buy_shop_offer_at_port now puts the goods.
  insert into ps1 values ('storeB', public.get_or_create_store((select v from ps1 where k='uB'),
                                                               (select v from ps1 where k='haven')));
end $$;

-- ⚠ THE PRECONDITION IS STATED, NOT ASSUMED. Migration 0300 LIT port_shop_enabled (it is one of the 44
-- capability flags that migration turned on), so the 0185/0235-era seed this block used to lean on
-- is gone: on the real chain the flag is TRUE by the time this proof runs. Asserting the seed was
-- asserting a WORLD rather than a property — the exact failure recorded after 0300's lights-on wave
-- — and it went unnoticed only because this workflow fired on no branch that carried 0300. The dark
-- scenario now SETS its own precondition in-txn (the hold-transfer-proof idiom); the ROLLBACK
-- reverts it either way, so the block is correct whichever way the committed flag ever points.
update public.game_config set value='false'::jsonb where key='port_shop_enabled';
-- ════════ P0 — DARK gate: with port_shop_enabled OFF, the buy RPC rejects and writes NOTHING. ════════
do $$
declare r jsonb; uB uuid := (select v from ps1 where k='uB'); v_ship uuid; v_bal numeric; ninst int; nrec int;
begin
  select main_ship_id into v_ship from public.main_ship_instances where player_id=uB;
  select balance into v_bal from public.player_wallet where player_id=uB;
  select count(*) into ninst from public.module_instances where player_id=uB;

  r := pg_temp.call_as(uB, format('public.buy_shop_offer_at_port(%L::uuid, %L, %s, %L::uuid)', v_ship, 'autocannon_battery', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'port_shop_disabled' then raise exception 'P0 FAIL dark buy: %', r; end if;
  -- the gated read is dark too.
  r := pg_temp.call_as(uB, format('public.get_port_shop(%L::uuid)', (select v from ps1 where k='haven')));
  if (r->>'reason') is distinct from 'port_shop_disabled' then raise exception 'P0 FAIL dark read: %', r; end if;

  select count(*) into nrec from public.port_shop_receipts where main_ship_id=v_ship;
  if nrec <> 0 then raise exception 'P0 FAIL dark path wrote % receipts', nrec; end if;
  if (select balance from public.player_wallet where player_id=uB) <> v_bal then raise exception 'P0 FAIL dark path moved wallet'; end if;
  if (select count(*) from public.module_instances where player_id=uB) <> ninst then raise exception 'P0 FAIL dark path minted an instance'; end if;

  -- enable the dark shop capability ONLY inside this rolled-back txn (production flag stays false after ROLLBACK).
  update public.game_config set value='true'::jsonb where key='port_shop_enabled';
  raise notice 'SHOP_PASS_DARK_GATE ok: buy + read rejected port_shop_disabled, zero writes (no receipt/wallet/instance delta)';
end $$;

-- ════════ P1 — SEED pins: the flag key, the two new catalog rows, the wired ammo, and 3×7 active offers. ════════
-- 0342 WITHDREW the deep-scan array on the SERVER: its three offer rows survive, priced 90, with
-- active = false, so the 0235 beginner outfit of 8 is now 7 on sale + 1 withdrawn. The count is
-- pinned at the new exact number in BOTH directions — an outfit that drifted either way goes red.
do $$
declare v_n int; r jsonb;
begin
  if not exists (select 1 from public.game_config where key='port_shop_enabled') then
    raise exception 'P1 FAIL: port_shop_enabled key absent (0235 seeds it)'; end if;
  if not exists (select 1 from public.item_types where item_id='autocannon_rounds' and category='ammunition' and stackable) then
    raise exception 'P1 FAIL: autocannon_rounds ammo item missing'; end if;
  if not exists (select 1 from public.module_types where id='shield_generator' and slot_type='defense' and stats_json='{"defense": 6}'::jsonb) then
    raise exception 'P1 FAIL: shield_generator module missing/mis-shaped'; end if;
  if not exists (select 1 from public.module_types where id='autocannon_battery' and ammo_type='autocannon_rounds') then
    raise exception 'P1 FAIL: autocannon ammo_type not wired'; end if;
  -- exactly 7 active offers at each starter port, Mk-II excluded (8 seeded − the 0342 withdrawal).
  select count(*) into v_n from unnest(array[(select v from ps1 where k='haven'),(select v from ps1 where k='slag'),(select v from ps1 where k='drift')]) p
    where (select count(*) from public.port_shop_offers o where o.location_id=p and o.active) <> 7;
  if v_n <> 0 then raise exception 'P1 FAIL: % starter port(s) not carrying exactly 7 active offers', v_n; end if;
  if exists (select 1 from public.port_shop_offers where ref_id in ('autocannon_battery_mk2','shield_lattice_mk2')) then
    raise exception 'P1 FAIL: a Mk-II tier is on sale (beginner shop only)'; end if;
  -- 0342: the withdrawal is a DEACTIVATION, never a delete. All three deep-scan rows are still
  -- there, still priced 90, and every one of them is inactive — that is what makes the rollback a
  -- one-line flip and what keeps the buy RPC's own `no_offer` the thing doing the refusing.
  select count(*) into v_n from public.port_shop_offers
    where ref_id='deep_scan_sensor_array' and active is false and price=90 and kind='module';
  if v_n <> 3 then raise exception 'P1 FAIL: % deep_scan_sensor_array rows inactive-at-90 (want 3)', v_n; end if;
  select count(*) into v_n from public.port_shop_offers where ref_id='deep_scan_sensor_array' and active;
  if v_n <> 0 then raise exception 'P1 FAIL: % deep_scan_sensor_array offer(s) are still active', v_n; end if;
  -- …and NOTHING ELSE was withdrawn with it: the other 7 refs are active at all 3 ports (21 rows).
  select count(*) into v_n from public.port_shop_offers
    where active and ref_id in ('autocannon_battery','shield_generator','shield_lattice','vector_thruster_kit',
                                'expanded_cargo_lattice','mining_rig_extension','autocannon_rounds');
  if v_n <> 21 then raise exception 'P1 FAIL: % active non-deep-scan offers (want 7 refs x 3 ports = 21)', v_n; end if;
  -- the EXACT beginner outfit at Haven: 6 modules + 1 ammo item on sale, no more, no less.
  select count(*) into v_n from public.port_shop_offers o
    where o.location_id=(select v from ps1 where k='haven') and o.active
      and o.ref_id not in ('autocannon_battery','shield_generator','shield_lattice','vector_thruster_kit',
                           'expanded_cargo_lattice','mining_rig_extension','autocannon_rounds');
  if v_n <> 0 then raise exception 'P1 FAIL: % unexpected offer ref(s) at Haven (outfit drifted)', v_n; end if;
  -- the gated read now lists exactly the 7 live offers at Haven, and the deep-scan is not among them.
  r := pg_temp.call_as((select v from ps1 where k='uB'), format('public.get_port_shop(%L::uuid)', (select v from ps1 where k='haven')));
  if (r->>'ok')::boolean is not true or jsonb_array_length(r->'offers') <> 7 then raise exception 'P1 FAIL get_port_shop: %', r; end if;
  if r->'offers' @> '[{"ref_id":"deep_scan_sensor_array"}]'::jsonb then
    raise exception 'P1 FAIL: the shop read still lists the withdrawn deep_scan_sensor_array'; end if;
  raise notice 'SHOP_PASS_SEED ok: flag key present; autocannon_rounds + shield_generator seeded + ammo wired; 3x7 active offers + 3 inactive deep-scan rows preserved at 90 (Mk-II excluded); get_port_shop lists 7 and never the deep-scan';
end $$;

-- ════════ P2 — BUY MODULE: buy autocannon_battery (120cr) → wallet −120, ONE instance minted, ONE receipt. ════════
do $$
declare r jsonb; uB uuid := (select v from ps1 where k='uB'); v_ship uuid; v_bal0 numeric; v_inst uuid;
  n int; v_req uuid := gen_random_uuid();
begin
  select main_ship_id into v_ship from public.main_ship_instances where player_id=uB;
  select balance into v_bal0 from public.player_wallet where player_id=uB;   -- known 1000

  r := pg_temp.call_as(uB, format('public.buy_shop_offer_at_port(%L::uuid, %L, %s, %L::uuid)', v_ship, 'autocannon_battery', 1, v_req));
  if (r->>'ok')::boolean is not true then raise exception 'P2 FAIL buy: %', r; end if;
  if (r->>'kind') is distinct from 'module' or (r->>'ref_id') is distinct from 'autocannon_battery' then raise exception 'P2 FAIL envelope: %', r; end if;
  if (r->>'total_price')::numeric <> 120 or (r->>'quantity')::int <> 1 then raise exception 'P2 FAIL price/qty: %', r; end if;
  v_inst := (r->>'instance_id')::uuid;
  if v_inst is null then raise exception 'P2 FAIL: no instance_id in the envelope: %', r; end if;

  -- wallet delta EXACT: −120, nothing else.
  if v_bal0 - (select balance from public.player_wallet where player_id=uB) <> 120 then raise exception 'P2 FAIL wallet delta (want -120)'; end if;
  -- exactly ONE module instance of the bought type, owned by uB, and it IS the returned instance (fittable pool).
  select count(*) into n from public.module_instances where player_id=uB and module_type_id='autocannon_battery';
  if n <> 1 then raise exception 'P2 FAIL % autocannon instances (want 1)', n; end if;
  if not exists (select 1 from public.module_instances where id=v_inst and player_id=uB and module_type_id='autocannon_battery') then
    raise exception 'P2 FAIL: the returned instance is not an owned autocannon_battery'; end if;
  -- exactly ONE receipt with the exact fields, instance_id pinned.
  if not exists (select 1 from public.port_shop_receipts
                   where main_ship_id=v_ship and request_id=v_req and kind='module' and ref_id='autocannon_battery'
                     and quantity=1 and unit_price=120 and total_price=120 and instance_id=v_inst
                     and location_id=(select v from ps1 where k='haven')) then
    raise exception 'P2 FAIL receipt fields wrong'; end if;

  insert into ps1 values ('modreq', v_req);  -- stash for the idempotency replay
  raise notice 'SHOP_PASS_BUY_MODULE ok: autocannon_battery bought -> wallet -120, 1 owned instance (=returned id, fittable), 1 receipt with instance_id';
end $$;

-- ════════ P3 — BUY ITEM (ammo): buy autocannon_rounds ×10 (2cr ea) → wallet −20, 10 stored AT HAVEN, ONE receipt. ════════
do $$
declare r jsonb; uB uuid := (select v from ps1 where k='uB'); v_ship uuid; v_bal0 numeric; v_have int; v_req uuid := gen_random_uuid();
  v_store uuid := (select v from ps1 where k='storeB');   -- 0333: uB's stock AT HAVEN (the docked port)
begin
  select main_ship_id into v_ship from public.main_ship_instances where player_id=uB;
  select balance into v_bal0 from public.player_wallet where player_id=uB;
  select public.inventory_get_balance(uB, v_store, 'autocannon_rounds') into v_have;
  if v_have <> 0 then raise exception 'P3 SETUP FAIL: uB already holds ammo at Haven'; end if;

  r := pg_temp.call_as(uB, format('public.buy_shop_offer_at_port(%L::uuid, %L, %s, %L::uuid)', v_ship, 'autocannon_rounds', 10, v_req));
  if (r->>'ok')::boolean is not true then raise exception 'P3 FAIL buy ammo: %', r; end if;
  if (r->>'kind') is distinct from 'item' or (r->>'quantity')::int <> 10 or (r->>'total_price')::numeric <> 20 then raise exception 'P3 FAIL envelope: %', r; end if;
  if (r->>'instance_id') is not null then raise exception 'P3 FAIL: an item buy carried an instance_id: %', r; end if;

  if v_bal0 - (select balance from public.player_wallet where player_id=uB) <> 20 then raise exception 'P3 FAIL wallet delta (want -20)'; end if;
  -- 0333: the ammo landed in HAVEN's store — the port uB is docked at — and nowhere else.
  if public.inventory_get_balance(uB, v_store, 'autocannon_rounds') <> 10 then raise exception 'P3 FAIL: Haven store not +10 ammo'; end if;
  if not exists (select 1 from public.base_items bi join public.bases b on b.id = bi.base_id
                   where b.player_id = uB and b.location_id = (select v from ps1 where k='haven')
                     and bi.item_id = 'autocannon_rounds' and bi.quantity = 10) then
    raise exception 'P3 FAIL: no base_items row for the ammo at Haven (the deposit did not land per-port)'; end if;
  if not exists (select 1 from public.port_shop_receipts where main_ship_id=v_ship and request_id=v_req and kind='item' and ref_id='autocannon_rounds' and quantity=10 and total_price=20) then
    raise exception 'P3 FAIL receipt fields wrong'; end if;
  raise notice 'SHOP_PASS_BUY_ITEM ok: autocannon_rounds x10 bought -> wallet -20, +10 in HAVEN''s base_items store, 1 item receipt (no instance_id)';
end $$;

-- ════════ P4 — idempotent replay: same (ship, request_id) → replayed VERBATIM, NO double debit/mint/receipt. ════════
do $$
declare r jsonb; uB uuid := (select v from ps1 where k='uB'); v_ship uuid; v_req uuid := (select v from ps1 where k='modreq');
  v_bal0 numeric; ninst int; nrec int;
begin
  select main_ship_id into v_ship from public.main_ship_instances where player_id=uB;
  select balance into v_bal0 from public.player_wallet where player_id=uB;
  select count(*) into ninst from public.module_instances where player_id=uB;
  select count(*) into nrec from public.port_shop_receipts where main_ship_id=v_ship;

  r := pg_temp.call_as(uB, format('public.buy_shop_offer_at_port(%L::uuid, %L, %s, %L::uuid)', v_ship, 'autocannon_battery', 1, v_req));
  if (r->>'ok')::boolean is not true or (r->>'idempotent_replay')::boolean is not true then raise exception 'P4 FAIL not replay: %', r; end if;
  if (r->>'total_price')::numeric <> 120 then raise exception 'P4 FAIL replay envelope: %', r; end if;

  if (select balance from public.player_wallet where player_id=uB) <> v_bal0 then raise exception 'P4 FAIL replay re-debited'; end if;
  if (select count(*) from public.module_instances where player_id=uB) <> ninst then raise exception 'P4 FAIL replay minted again'; end if;
  if (select count(*) from public.port_shop_receipts where main_ship_id=v_ship) <> nrec then raise exception 'P4 FAIL replay wrote a receipt'; end if;
  raise notice 'SHOP_PASS_IDEMPOTENT ok: replay -> idempotent_replay envelope verbatim, no double debit/mint/receipt';
end $$;

-- ════════ P5 — guards: invalid_quantity (0/2.5) · no_offer (unknown ref) · module_qty_must_be_one (module qty 2)
--            · insufficient_credits (broke). All zero-write on uB. (not_docked uses the SAME shared
--            docked-resolver as salvage 0174 / repair 0201 — proven there; the live movement command is
--            mid-refactor at this chain head, so it is not re-exercised here.) ════════
do $$
declare r jsonb;
  uB uuid := (select v from ps1 where k='uB'); uP uuid := (select v from ps1 where k='uP');
  v_shipB uuid; v_shipP uuid; v_balB numeric; ninstB int; nrecB int;
begin
  select main_ship_id into v_shipB from public.main_ship_instances where player_id=uB;
  select main_ship_id into v_shipP from public.main_ship_instances where player_id=uP;
  select balance into v_balB from public.player_wallet where player_id=uB;
  select count(*) into ninstB from public.module_instances where player_id=uB;
  select count(*) into nrecB from public.port_shop_receipts where main_ship_id=v_shipB;

  -- invalid_quantity: zero and fractional (units are INTEGER — never rounded).
  r := pg_temp.call_as(uB, format('public.buy_shop_offer_at_port(%L::uuid, %L, %s, %L::uuid)', v_shipB, 'autocannon_rounds', 0, gen_random_uuid()));
  if (r->>'reason') is distinct from 'invalid_quantity' then raise exception 'P5 FAIL qty 0: %', r; end if;
  r := pg_temp.call_as(uB, format('public.buy_shop_offer_at_port(%L::uuid, %L, %s, %L::uuid)', v_shipB, 'autocannon_rounds', 2.5, gen_random_uuid()));
  if (r->>'reason') is distinct from 'invalid_quantity' then raise exception 'P5 FAIL qty 2.5: %', r; end if;

  -- no_offer: an unknown ref has no offer row at this port.
  r := pg_temp.call_as(uB, format('public.buy_shop_offer_at_port(%L::uuid, %L, %s, %L::uuid)', v_shipB, 'nonexistent_widget', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'no_offer' then raise exception 'P5 FAIL unknown ref: %', r; end if;

  -- module_qty_must_be_one: a module purchase with qty 2 is rejected (one instance per buy).
  r := pg_temp.call_as(uB, format('public.buy_shop_offer_at_port(%L::uuid, %L, %s, %L::uuid)', v_shipB, 'autocannon_battery', 2, gen_random_uuid()));
  if (r->>'reason') is distinct from 'module_qty_must_be_one' then raise exception 'P5 FAIL module qty 2: %', r; end if;

  -- insufficient_credits: uP is docked at Haven, wallet 0 → can't afford → NOTHING granted/charged.
  r := pg_temp.call_as(uP, format('public.buy_shop_offer_at_port(%L::uuid, %L, %s, %L::uuid)', v_shipP, 'autocannon_battery', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'insufficient_credits' then raise exception 'P5 FAIL broke not insufficient_credits: %', r; end if;
  if (select count(*) from public.module_instances where player_id=uP) <> 0 then raise exception 'P5 FAIL insufficient_credits still minted'; end if;
  if (select balance from public.player_wallet where player_id=uP) <> 0 then raise exception 'P5 FAIL insufficient_credits moved a 0 wallet'; end if;

  -- ALL guards wrote nothing on uB: wallet, instances, receipts unchanged.
  if (select balance from public.player_wallet where player_id=uB) <> v_balB then raise exception 'P5 FAIL a guard moved uB wallet'; end if;
  if (select count(*) from public.module_instances where player_id=uB) <> ninstB then raise exception 'P5 FAIL a guard minted an instance'; end if;
  if (select count(*) from public.port_shop_receipts where main_ship_id=v_shipB) <> nrecB then raise exception 'P5 FAIL a guard wrote a receipt'; end if;
  raise notice 'SHOP_PASS_GUARDS ok: invalid_quantity (0/2.5), no_offer, module_qty_must_be_one, broke insufficient_credits — all zero-write';
end $$;

-- ════════ P6 — 0342: THE DEEP-SCAN ARRAY CANNOT BE BOUGHT, AT ANY OF THE THREE PORTS. ════════
--   THE VERDICT (owner, 2026-08-04): "A disabled React button is not purchase prevention." The
--   previous slice withdrew the Buy affordance in React while all three offers stayed active = true
--   at 90 credits, so the RPC would still have sold it. 0342 sets those three rows inactive, and
--   THIS block calls the REAL buy RPC at EACH port — not one representative — and requires the
--   server's own `no_offer`.
--
--   A RETURNED REASON STRING IS NOT PROOF THAT NOTHING WAS WRITTEN. The wallet, the module-instance
--   pool, the deep-scan instance count, the receipts and the per-port item stores are all measured
--   BEFORE the three attempts and again AFTER, and compared. The offer rows are re-checked too: a
--   refused purchase must not touch the catalog it was refused by.
--
--   FIXTURE SURGERY (the fleetgo-proof idiom, and it is stated rather than hidden): no live
--   single-ship mover survives at this chain head, so uB's dock is relocated by writing its OWN
--   present fleet + that fleet's active presence + its berth, then CONFIRMED through the real
--   shared resolver (mainship_resolve_docked_location) before any probe — a relocation that did not
--   take would otherwise make all three probes the same Haven probe wearing three names. Rolled
--   back with everything else.
do $$
declare
  r jsonb; uB uuid := (select v from ps1 where k='uB');
  v_ship uuid; v_fleet uuid; v_port uuid; sk text;
  v_bal0 numeric; n_inst0 int; n_rec0 int; n_deep0 int; n_items0 numeric; n_probes int := 0;
begin
  select main_ship_id into v_ship from public.main_ship_instances where player_id=uB;
  select balance into v_bal0 from public.player_wallet where player_id=uB;
  select count(*) into n_inst0 from public.module_instances where player_id=uB;
  select count(*) into n_deep0 from public.module_instances where player_id=uB and module_type_id='deep_scan_sensor_array';
  select count(*) into n_rec0 from public.port_shop_receipts where main_ship_id=v_ship;
  select coalesce(sum(bi.quantity),0) into n_items0
    from public.base_items bi join public.bases b on b.id=bi.base_id where b.player_id=uB;
  if n_deep0 <> 0 then raise exception 'P6 SETUP FAIL: uB already owns a deep-scan array — the non-mutation assert would be vacuous'; end if;

  foreach sk in array array['haven','slag','drift'] loop
    v_port := (select v from ps1 where ps1.k = sk);
    v_fleet := public.mainship_resolve_fleet(v_ship);
    if v_fleet is null then raise exception 'P6 SETUP FAIL: uB has no resolvable fleet'; end if;
    update public.fleets
       set current_location_id = v_port, current_base_id = null, location_mode = 'location', updated_at = now()
     where id = v_fleet;
    update public.location_presence
       set location_id = v_port, status = 'active', updated_at = now()
     where fleet_id = v_fleet;
    -- berth follows the dock for an UNGROUPED ship only: 0216's CHECK is the XOR
    -- (group_id is null) = (berth_location_id is not null), so writing a berth onto a grouped
    -- ship would violate it. The dock answer itself comes from fleet+presence, never berth.
    update public.main_ship_instances set berth_location_id = v_port
     where main_ship_id = v_ship and group_id is null;
    -- ESTABLISHED, NOT ASSUMED: the REAL docked resolver — the one the buy RPC itself calls — must
    -- agree that uB is docked at this port, or the probe below proves nothing about this port.
    if public.mainship_resolve_docked_location(v_ship) is distinct from v_port then
      raise exception 'P6 SETUP FAIL: uB is not docked at % after relocation', sk; end if;

    -- the catalog row is present-but-withdrawn at THIS port…
    if not exists (select 1 from public.port_shop_offers
                    where location_id=v_port and ref_id='deep_scan_sensor_array'
                      and active is false and price=90 and kind='module') then
      raise exception 'P6 FAIL %: the deep-scan offer row is not present-inactive-at-90', sk; end if;

    -- …the REAL purchase RPC refuses it with the SERVER's own reason…
    r := pg_temp.call_as(uB, format('public.buy_shop_offer_at_port(%L::uuid, %L, %s, %L::uuid)', v_ship, 'deep_scan_sensor_array', 1, gen_random_uuid()));
    if (r->>'ok')::boolean is not false then raise exception 'P6 FAIL % : the deep-scan buy SUCCEEDED: %', sk, r; end if;
    if (r->>'reason') is distinct from 'no_offer' then raise exception 'P6 FAIL % : deep-scan buy not refused no_offer: %', sk, r; end if;

    -- …and the gated READ does not list it at this port either (7 live offers, none of them it).
    r := pg_temp.call_as(uB, format('public.get_port_shop(%L::uuid)', v_port));
    if (r->>'ok')::boolean is not true or jsonb_array_length(r->'offers') <> 7 then
      raise exception 'P6 FAIL % read: %', sk, r; end if;
    if r->'offers' @> '[{"ref_id":"deep_scan_sensor_array"}]'::jsonb then
      raise exception 'P6 FAIL %: the shop read still lists the withdrawn deep-scan array', sk; end if;

    -- the refusal did not touch the row it was refused by.
    if not exists (select 1 from public.port_shop_offers
                    where location_id=v_port and ref_id='deep_scan_sensor_array' and active is false and price=90) then
      raise exception 'P6 FAIL %: the refused purchase moved the offer row', sk; end if;
    n_probes := n_probes + 1;
  end loop;
  if n_probes <> 3 then raise exception 'P6 FAIL: % ports probed (want 3)', n_probes; end if;

  -- ── NON-MUTATION, MEASURED. Nothing was charged, minted, deposited or receipted. ──
  if (select balance from public.player_wallet where player_id=uB) <> v_bal0 then
    raise exception 'P6 FAIL: a refused deep-scan buy moved the wallet'; end if;
  if (select count(*) from public.module_instances where player_id=uB) <> n_inst0 then
    raise exception 'P6 FAIL: a refused deep-scan buy minted a module instance'; end if;
  if (select count(*) from public.module_instances where player_id=uB and module_type_id='deep_scan_sensor_array') <> 0 then
    raise exception 'P6 FAIL: a deep-scan instance exists after three refusals'; end if;
  if (select count(*) from public.port_shop_receipts where main_ship_id=v_ship) <> n_rec0 then
    raise exception 'P6 FAIL: a refused deep-scan buy wrote a receipt'; end if;
  if (select coalesce(sum(bi.quantity),0) from public.base_items bi join public.bases b on b.id=bi.base_id
       where b.player_id=uB) <> n_items0 then
    raise exception 'P6 FAIL: a refused deep-scan buy moved a per-port item store'; end if;

  -- put uB back at Haven for P7, and CONFIRM it through the real resolver.
  v_port := (select v from ps1 where k='haven');
  v_fleet := public.mainship_resolve_fleet(v_ship);
  update public.fleets set current_location_id = v_port, current_base_id = null, location_mode='location', updated_at=now() where id = v_fleet;
  update public.location_presence set location_id = v_port, status='active', updated_at=now() where fleet_id = v_fleet;
  update public.main_ship_instances set berth_location_id = v_port where main_ship_id = v_ship and group_id is null;
  if public.mainship_resolve_docked_location(v_ship) is distinct from v_port then
    raise exception 'P6 FAIL: uB was not restored to Haven'; end if;

  raise notice 'SHOP_PASS_DEEP_SCAN_WITHDRAWN ok: buy_shop_offer_at_port -> no_offer at ALL THREE starter ports; get_port_shop lists 7 and never the deep-scan; wallet, module instances, deep-scan instances, receipts and per-port item stores all unchanged; the inactive-at-90 offer rows untouched';
end $$;

-- ════════ P7 — 0342 DID NOT OVERREACH: the mining rig still PASSES the availability gate. ════════
--   The mining rig claims the same dormant `mining` key, and it deliberately stays on sale: its
--   range 120 is REAL — mining_extract takes the mining radius from max(mt.range) over fitted
--   mining modules — so it has a live effect. "We withdrew the dead one" is only true if the live
--   one survived, so this buys it through the SAME RPC and requires an ok with the exact debit.
--   (The dormant chip staying hidden in the player-facing shop row is a presentation claim, proven
--   on the real component by the rendered shop proof; it is not a server property.)
do $$
declare
  r jsonb; uB uuid := (select v from ps1 where k='uB'); v_ship uuid; v_bal0 numeric; v_inst uuid;
  n int; v_req uuid := gen_random_uuid();
begin
  select main_ship_id into v_ship from public.main_ship_instances where player_id=uB;
  select balance into v_bal0 from public.player_wallet where player_id=uB;

  -- catalogued and on sale at all three ports, at its 0235 price…
  select count(*) into n from public.port_shop_offers where ref_id='mining_rig_extension' and active and price=110;
  if n <> 3 then raise exception 'P7 FAIL: % active mining_rig_extension offers at 110 (want 3)', n; end if;
  -- …with its LIVE attribute intact (the reason it is not withdrawn).
  if not exists (select 1 from public.module_types where id='mining_rig_extension' and range=120 and power=8) then
    raise exception 'P7 FAIL: mining_rig_extension lost its live range 120 / power 8'; end if;

  r := pg_temp.call_as(uB, format('public.buy_shop_offer_at_port(%L::uuid, %L, %s, %L::uuid)', v_ship, 'mining_rig_extension', 1, v_req));
  if (r->>'reason') is not distinct from 'no_offer' then
    raise exception 'P7 FAIL: the mining rig was withdrawn too — 0342 overreached: %', r; end if;
  if (r->>'ok')::boolean is not true then raise exception 'P7 FAIL buy: %', r; end if;
  if (r->>'total_price')::numeric <> 110 or (r->>'quantity')::int <> 1 then raise exception 'P7 FAIL price/qty: %', r; end if;
  v_inst := (r->>'instance_id')::uuid;
  if v_inst is null then raise exception 'P7 FAIL: no instance_id in the envelope: %', r; end if;
  if v_bal0 - (select balance from public.player_wallet where player_id=uB) <> 110 then
    raise exception 'P7 FAIL wallet delta (want -110)'; end if;
  if not exists (select 1 from public.module_instances where id=v_inst and player_id=uB and module_type_id='mining_rig_extension') then
    raise exception 'P7 FAIL: the returned instance is not an owned mining_rig_extension'; end if;

  raise notice 'SHOP_PASS_MINING_RIG_ON_SALE ok: mining_rig_extension still passes the availability gate — buy_shop_offer_at_port returned ok (never no_offer), wallet -110, one owned instance; catalogued active at 110 x3 ports with range 120 / power 8 intact';
end $$;

select 'PORT-SHOP PROOF PASSED (dark gate; seeded outfit + wired ammo; buy module exact debit + minted instance + receipt; buy ammo exact debit + the docked port''s base_items store + receipt; idempotent replay; quantity/offer/module-qty/dock/credit guards; the 0342 deep-scan withdrawal refused at all three ports with zero writes; the mining rig still sold)' as result;

rollback;   -- leave ZERO persisted state: no wallet, inventory, instance, receipt, ship, flag flip, or fixture user.
