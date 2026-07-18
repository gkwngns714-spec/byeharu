-- PORT-SHOP — disposable REAL-CHAIN proof (runs on the actual chain 0001..0235 in a throwaway Supabase).
-- Proves PORT-SHOP (0235): the dark gate, the seeded beginner outfit, and the atomic buy_shop_offer_at_port
-- surface — buy a MODULE (mint one instance + exact debit + receipt), buy an ITEM/ammo (deposit + exact
-- debit + receipt), idempotent replay, and the guard envelope (invalid_quantity, no_offer,
-- module_qty_must_be_one, not_docked, insufficient_credits). The ENTIRE proof runs inside ONE transaction
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
-- player_inventory / port_shop_receipts directly — every grant + receipt is minted by the RPC under test.

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

-- three fresh players: uB (buyer, funded), uP (poor), uD (undocked/in-transit).
do $$
declare u uuid; sk text;
begin
  foreach sk in array array['uB','uP','uD'] loop
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
  foreach sk in array array['uB','uP','uD'] loop
    u := (select v from ps1 where ps1.k = sk);
    r := pg_temp.call_as(u, 'public.commission_first_main_ship()');
    if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then raise exception 'SETUP FAIL first-ship %: %', sk, r; end if;
  end loop;
  insert into public.player_wallet (player_id, balance) values
    ((select v from ps1 where k='uB'), 1000),
    ((select v from ps1 where k='uP'), 0),      -- poor: the insufficient_credits arm
    ((select v from ps1 where k='uD'), 500)
  on conflict (player_id) do update set balance = excluded.balance;
end $$;

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

-- ════════ P1 — SEED pins: the flag key, the two new catalog rows, the wired ammo, and 3×8 active offers. ════════
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
  -- exactly 8 active offers at each starter port, Mk-II excluded.
  select count(*) into v_n from unnest(array[(select v from ps1 where k='haven'),(select v from ps1 where k='slag'),(select v from ps1 where k='drift')]) p
    where (select count(*) from public.port_shop_offers o where o.location_id=p and o.active) <> 8;
  if v_n <> 0 then raise exception 'P1 FAIL: % starter port(s) not carrying exactly 8 active offers', v_n; end if;
  if exists (select 1 from public.port_shop_offers where ref_id in ('autocannon_battery_mk2','shield_lattice_mk2')) then
    raise exception 'P1 FAIL: a Mk-II tier is on sale (beginner shop only)'; end if;
  -- the EXACT beginner outfit at Haven: 7 modules + 1 ammo item, no more, no less.
  select count(*) into v_n from public.port_shop_offers o
    where o.location_id=(select v from ps1 where k='haven') and o.active
      and o.ref_id not in ('autocannon_battery','shield_generator','shield_lattice','vector_thruster_kit',
                           'deep_scan_sensor_array','expanded_cargo_lattice','mining_rig_extension','autocannon_rounds');
  if v_n <> 0 then raise exception 'P1 FAIL: % unexpected offer ref(s) at Haven (outfit drifted)', v_n; end if;
  -- the gated read now lists exactly the 8 offers at Haven.
  r := pg_temp.call_as((select v from ps1 where k='uB'), format('public.get_port_shop(%L::uuid)', (select v from ps1 where k='haven')));
  if (r->>'ok')::boolean is not true or jsonb_array_length(r->'offers') <> 8 then raise exception 'P1 FAIL get_port_shop: %', r; end if;
  raise notice 'SHOP_PASS_SEED ok: flag key present; autocannon_rounds + shield_generator seeded + ammo wired; 3x8 active offers (Mk-II excluded); get_port_shop lists 8';
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

-- ════════ P3 — BUY ITEM (ammo): buy autocannon_rounds ×10 (2cr ea) → wallet −20, inventory 10, ONE receipt. ════════
do $$
declare r jsonb; uB uuid := (select v from ps1 where k='uB'); v_ship uuid; v_bal0 numeric; v_have int; v_req uuid := gen_random_uuid();
begin
  select main_ship_id into v_ship from public.main_ship_instances where player_id=uB;
  select balance into v_bal0 from public.player_wallet where player_id=uB;
  select public.inventory_get_balance(uB, 'autocannon_rounds') into v_have;
  if v_have <> 0 then raise exception 'P3 SETUP FAIL: uB already holds ammo'; end if;

  r := pg_temp.call_as(uB, format('public.buy_shop_offer_at_port(%L::uuid, %L, %s, %L::uuid)', v_ship, 'autocannon_rounds', 10, v_req));
  if (r->>'ok')::boolean is not true then raise exception 'P3 FAIL buy ammo: %', r; end if;
  if (r->>'kind') is distinct from 'item' or (r->>'quantity')::int <> 10 or (r->>'total_price')::numeric <> 20 then raise exception 'P3 FAIL envelope: %', r; end if;
  if (r->>'instance_id') is not null then raise exception 'P3 FAIL: an item buy carried an instance_id: %', r; end if;

  if v_bal0 - (select balance from public.player_wallet where player_id=uB) <> 20 then raise exception 'P3 FAIL wallet delta (want -20)'; end if;
  if public.inventory_get_balance(uB, 'autocannon_rounds') <> 10 then raise exception 'P3 FAIL: inventory not +10 ammo'; end if;
  if not exists (select 1 from public.port_shop_receipts where main_ship_id=v_ship and request_id=v_req and kind='item' and ref_id='autocannon_rounds' and quantity=10 and total_price=20) then
    raise exception 'P3 FAIL receipt fields wrong'; end if;
  raise notice 'SHOP_PASS_BUY_ITEM ok: autocannon_rounds x10 bought -> wallet -20, inventory +10, 1 item receipt (no instance_id)';
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
--            · not_docked (in transit) · insufficient_credits (broke). All zero-write on uB. ════════
do $$
declare r jsonb;
  uB uuid := (select v from ps1 where k='uB'); uP uuid := (select v from ps1 where k='uP'); uD uuid := (select v from ps1 where k='uD');
  v_shipB uuid; v_shipP uuid; v_shipD uuid; v_balB numeric; ninstB int; nrecB int;
begin
  select main_ship_id into v_shipB from public.main_ship_instances where player_id=uB;
  select main_ship_id into v_shipP from public.main_ship_instances where player_id=uP;
  select main_ship_id into v_shipD from public.main_ship_instances where player_id=uD;
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

  -- not_docked: uD departs toward Slagworks → in transit → the ONE docked-resolver returns null.
  r := pg_temp.call_as(uD, format('public.command_main_ship_space_move_to_location(%L::uuid, %L::uuid, %L::uuid)',
                                   (select v from ps1 where k='slag'), gen_random_uuid(), v_shipD));
  if (r->>'ok')::boolean is not true then raise exception 'P5 FAIL move uD: %', r; end if;
  r := pg_temp.call_as(uD, format('public.buy_shop_offer_at_port(%L::uuid, %L, %s, %L::uuid)', v_shipD, 'autocannon_rounds', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'not_docked' then raise exception 'P5 FAIL in-transit not rejected: %', r; end if;

  -- insufficient_credits: uP is docked at Haven, wallet 0 → can't afford → NOTHING granted/charged.
  r := pg_temp.call_as(uP, format('public.buy_shop_offer_at_port(%L::uuid, %L, %s, %L::uuid)', v_shipP, 'autocannon_battery', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'insufficient_credits' then raise exception 'P5 FAIL broke not insufficient_credits: %', r; end if;
  if (select count(*) from public.module_instances where player_id=uP) <> 0 then raise exception 'P5 FAIL insufficient_credits still minted'; end if;
  if (select balance from public.player_wallet where player_id=uP) <> 0 then raise exception 'P5 FAIL insufficient_credits moved a 0 wallet'; end if;

  -- ALL guards wrote nothing on uB: wallet, instances, receipts unchanged.
  if (select balance from public.player_wallet where player_id=uB) <> v_balB then raise exception 'P5 FAIL a guard moved uB wallet'; end if;
  if (select count(*) from public.module_instances where player_id=uB) <> ninstB then raise exception 'P5 FAIL a guard minted an instance'; end if;
  if (select count(*) from public.port_shop_receipts where main_ship_id=v_shipB) <> nrecB then raise exception 'P5 FAIL a guard wrote a receipt'; end if;
  raise notice 'SHOP_PASS_GUARDS ok: invalid_quantity (0/2.5), no_offer, module_qty_must_be_one, in-transit not_docked, broke insufficient_credits — all zero-write';
end $$;

select 'PORT-SHOP PROOF PASSED (dark gate; seeded outfit + wired ammo; buy module exact debit + minted instance + receipt; buy ammo exact debit + inventory + receipt; idempotent replay; quantity/offer/module-qty/dock/credit guards)' as result;

rollback;   -- leave ZERO persisted state: no wallet, inventory, instance, receipt, ship, flag flip, or fixture user.
