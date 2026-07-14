-- REPAIR-ECON — disposable REAL-CHAIN proof (runs on the actual chain 0001..0201 in a throwaway Supabase).
-- Proves REPAIR-ECON (0201): the dark gate, the cost knob, and the atomic repair_ship_hull_at_port surface —
-- full mend (exact debit for exact hp restored + receipt), partial mend, idempotent replay, the guard
-- envelope, and THE SAFELOCK SEAM: a destroyed ship is rejected by the PAID path (ship_destroyed) while the
-- FREE repair_main_ship() still recovers it at zero cost, UNTOUCHED. Fixture users carry the 're1.' email
-- prefix. The ENTIRE proof runs inside ONE transaction that ROLLBACKs — it persists NO wallet, hp, receipt,
-- ship, or flag flip. No production access. No COMMIT anywhere.
--
-- ── DARK-CAPABILITY EXERCISE (sanctioned; never crosses a flag human-gate) ────────────────────────
-- The harness enables repair_economy_enabled ONLY inside this rolled-back transaction (AFTER proving the
-- dark reject); the ROLLBACK reverts it, so the committed/production flag value stays false. It transiently
-- mirrors production config a fresh chain lacks (reveal_starter_ports + mainship_space_movement_enabled) —
-- all reverted by ROLLBACK. Ships are commissioned via the REAL commission_first_main_ship() RPC (docked at
-- Haven), then DAMAGED by a direct fixture hp write (combat is the real damage source — not yet wired to
-- main ships; the fixture simulates a battle-dented hull), and wallets are pre-seeded by a direct owner
-- insert (the salvage-proof precedent) so every credit assert is an EXACT delta. The harness NEVER writes
-- repair_receipts directly — every receipt is minted by the RPC under test.

\set ON_ERROR_STOP on

begin;   -- everything below is transient; the trailing ROLLBACK leaves ZERO persisted state.

create temp table re1(k text primary key, v uuid) on commit preserve rows;
insert into re1 values
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

-- four fresh players: uR (repairer, funded), uP (poor), uD (undocked), uX (spare/cross-player).
do $$
declare u uuid; sk text;
begin
  foreach sk in array array['uR','uP','uD','uX'] loop
    insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
      values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
              're1.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
      returning id into u;
    insert into re1 values (sk, u);
  end loop;
end $$;

-- mirror production config a fresh disposable chain lacks (all reverted by ROLLBACK): reveal starter ports +
-- enable port-to-port movement. repair_economy_enabled stays OFF here (P0 proves the dark reject first).
do $$
declare r jsonb;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: reveal_starter_ports %', r; end if;
  insert into public.game_config(key,value,description)
    values('mainship_space_movement_enabled','true'::jsonb,'re1 transient (rolled back)')
    on conflict (key) do update set value='true'::jsonb;
end $$;

-- commission each player's first ship (real RPC) → docked at Haven; pre-seed wallets at KNOWN balances by
-- direct owner insert (the salvage-proof funding precedent; rolled back) so every credit assert is an EXACT
-- delta, independent of wallet_ensure's seed.
do $$
declare r jsonb; sk text; u uuid;
begin
  foreach sk in array array['uR','uP','uD','uX'] loop
    u := (select v from re1 where re1.k = sk);
    r := pg_temp.call_as(u, 'public.commission_first_main_ship()');
    if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then raise exception 'SETUP FAIL first-ship %: %', sk, r; end if;
  end loop;
  insert into public.player_wallet (player_id, balance) values
    ((select v from re1 where k='uR'), 1000),
    ((select v from re1 where k='uP'), 0),      -- poor: the insufficient_credits arm
    ((select v from re1 where k='uD'), 500),
    ((select v from re1 where k='uX'), 500)
  on conflict (player_id) do update set balance = excluded.balance;
end $$;

-- ════════ P0 — DARK gate: with repair_economy_enabled OFF, the repair RPC rejects and writes NOTHING. ════════
do $$
declare r jsonb; uR uuid := (select v from re1 where k='uR'); v_ship uuid; v_bal numeric; v_hp0 int; n int;
begin
  select main_ship_id, hp into v_ship, v_hp0 from public.main_ship_instances where player_id=uR;
  -- damage uR's hull by 120 (fixture: a battle-dented hull) so a repair WOULD have something to do.
  update public.main_ship_instances set hp = max_hp - 120 where player_id = uR;
  select hp into v_hp0 from public.main_ship_instances where player_id=uR;   -- max_hp-120
  select balance into v_bal from public.player_wallet where player_id=uR;

  r := pg_temp.call_as(uR, format('public.repair_ship_hull_at_port(%L::uuid, %s, %L::uuid)', v_ship, 100000, gen_random_uuid()));
  if (r->>'reason') is distinct from 'repair_economy_disabled' then raise exception 'P0 FAIL dark repair: %', r; end if;

  select count(*) into n from public.repair_receipts where main_ship_id=v_ship;
  if n <> 0 then raise exception 'P0 FAIL dark path wrote % receipts', n; end if;
  if (select balance from public.player_wallet where player_id=uR) <> v_bal then raise exception 'P0 FAIL dark path moved wallet'; end if;
  if (select hp from public.main_ship_instances where player_id=uR) <> v_hp0 then raise exception 'P0 FAIL dark path healed hull'; end if;

  -- enable the dark repair capability ONLY inside this rolled-back txn (production flag stays false after ROLLBACK).
  update public.game_config set value='true'::jsonb where key='repair_economy_enabled';
  raise notice 'REPAIR_PASS_DARK_GATE ok: paid repair rejected repair_economy_disabled, zero writes (no receipt/wallet/hp delta)';
end $$;

-- ════════ P1 — SEED pins: the flag key exists, the knob is the approved 0.5 [D], hp is proportional cost. ════════
do $$
declare v_per numeric;
begin
  if not exists (select 1 from public.game_config where key='repair_economy_enabled') then
    raise exception 'P1 FAIL: repair_economy_enabled key absent (0201 seeds it)'; end if;
  v_per := public.cfg_num('repair_credits_per_hp');
  if v_per is distinct from 0.5 then raise exception 'P1 FAIL: repair_credits_per_hp % (want the seeded 0.5)', v_per; end if;
  raise notice 'REPAIR_PASS_SEED ok: repair_economy_enabled key present; repair_credits_per_hp = 0.5 (the approved [D] seed)';
end $$;

-- ════════ P2 — HAPPY (full mend via over-request clamp): missing 120 hp, request 100000 → restore EXACTLY 120,
--            debit EXACTLY 120×0.5=60, hull → max_hp, ONE receipt with exact fields. ════════
do $$
declare r jsonb; uR uuid := (select v from re1 where k='uR'); v_ship uuid; v_max int; v_bal0 numeric; v_bal1 numeric;
  n int; v_req uuid := gen_random_uuid();
begin
  select main_ship_id, max_hp into v_ship, v_max from public.main_ship_instances where player_id=uR;  -- still missing 120 from P0
  select balance into v_bal0 from public.player_wallet where player_id=uR;                             -- known 1000

  r := pg_temp.call_as(uR, format('public.repair_ship_hull_at_port(%L::uuid, %s, %L::uuid)', v_ship, 100000, v_req));
  if (r->>'ok')::boolean is not true then raise exception 'P2 FAIL repair: %', r; end if;
  -- over-request clamps to the actual missing 120; cost = 120 × 0.5 = 60 EXACT.
  if (r->>'hp_restored')::int <> 120 then raise exception 'P2 FAIL hp_restored %: %', r->>'hp_restored', r; end if;
  if (r->>'total_price')::numeric <> 60 or (r->>'credits_per_hp')::numeric <> 0.5 then raise exception 'P2 FAIL price: %', r; end if;
  if (r->>'hp_after')::int <> v_max then raise exception 'P2 FAIL hp_after % (want max_hp %): %', r->>'hp_after', v_max, r; end if;
  if (r->>'location_id')::uuid is distinct from (select v from re1 where k='haven') then raise exception 'P2 FAIL location: %', r; end if;

  -- wallet delta EXACT: −60, nothing else.
  select balance into v_bal1 from public.player_wallet where player_id=uR;
  if v_bal0 - v_bal1 <> 60 then raise exception 'P2 FAIL wallet delta % (want exactly -60)', v_bal0 - v_bal1; end if;
  -- hull is now full.
  if (select hp from public.main_ship_instances where player_id=uR) <> v_max then raise exception 'P2 FAIL hull not at max'; end if;
  -- exactly ONE receipt with the exact fields.
  select count(*) into n from public.repair_receipts where main_ship_id=v_ship;
  if n <> 1 then raise exception 'P2 FAIL % receipts', n; end if;
  if not exists (select 1 from public.repair_receipts
                   where main_ship_id=v_ship and request_id=v_req and hp_restored=120
                     and credits_per_hp=0.5 and total_price=60 and hp_after=v_max
                     and location_id=(select v from re1 where k='haven')) then
    raise exception 'P2 FAIL receipt fields wrong';
  end if;
  raise notice 'REPAIR_PASS_HAPPY ok: over-request clamps to missing 120 hp -> restore 120, debit 60 exact, hull->max, 1 receipt';
end $$;

-- ════════ P3 — PARTIAL: re-damage to missing 100, request only 40 → restore EXACTLY 40, debit 20, hull leaves
--            60 still missing (a partial mend), ONE more receipt. ════════
do $$
declare r jsonb; uR uuid := (select v from re1 where k='uR'); v_ship uuid; v_max int; v_bal0 numeric;
  n int; v_req uuid := gen_random_uuid();
begin
  select main_ship_id, max_hp into v_ship, v_max from public.main_ship_instances where player_id=uR;
  update public.main_ship_instances set hp = max_hp - 100 where player_id = uR;   -- fixture: fresh 100-hp dent
  select balance into v_bal0 from public.player_wallet where player_id=uR;

  r := pg_temp.call_as(uR, format('public.repair_ship_hull_at_port(%L::uuid, %s, %L::uuid)', v_ship, 40, v_req));
  if (r->>'ok')::boolean is not true then raise exception 'P3 FAIL partial: %', r; end if;
  if (r->>'hp_restored')::int <> 40 then raise exception 'P3 FAIL restored %: %', r->>'hp_restored', r; end if;
  if (r->>'total_price')::numeric <> 20 then raise exception 'P3 FAIL price % (want 40×0.5=20): %', r->>'total_price', r; end if;
  if (r->>'hp_after')::int <> v_max - 60 then raise exception 'P3 FAIL hp_after % (want max-60): %', r->>'hp_after', r; end if;

  if v_bal0 - (select balance from public.player_wallet where player_id=uR) <> 20 then raise exception 'P3 FAIL wallet delta (want -20)'; end if;
  if (select hp from public.main_ship_instances where player_id=uR) <> v_max - 60 then raise exception 'P3 FAIL hull not at max-60 (partial mend)'; end if;
  select count(*) into n from public.repair_receipts where main_ship_id=v_ship;
  if n <> 2 then raise exception 'P3 FAIL expected 2 receipts, got %', n; end if;

  insert into re1 values ('partialreq', v_req);  -- stash for the idempotency replay
  raise notice 'REPAIR_PASS_PARTIAL ok: request 40 of 100 missing -> restore 40, debit 20 exact, hull left at max-60 (partial)';
end $$;

-- ════════ P4 — idempotent replay: same (ship, request_id) → replayed VERBATIM, NO double debit/heal/receipt. ════════
do $$
declare r jsonb; uR uuid := (select v from re1 where k='uR'); v_ship uuid; v_req uuid := (select v from re1 where k='partialreq');
  v_bal0 numeric; v_hp0 int; nrec int;
begin
  select main_ship_id, hp into v_ship, v_hp0 from public.main_ship_instances where player_id=uR;   -- max-60
  select balance into v_bal0 from public.player_wallet where player_id=uR;
  select count(*) into nrec from public.repair_receipts where main_ship_id=v_ship;

  r := pg_temp.call_as(uR, format('public.repair_ship_hull_at_port(%L::uuid, %s, %L::uuid)', v_ship, 40, v_req));
  if (r->>'ok')::boolean is not true or (r->>'idempotent_replay')::boolean is not true then raise exception 'P4 FAIL not replay: %', r; end if;
  if (r->>'total_price')::numeric <> 20 or (r->>'hp_restored')::int <> 40 then raise exception 'P4 FAIL replay envelope: %', r; end if;

  if (select balance from public.player_wallet where player_id=uR) <> v_bal0 then raise exception 'P4 FAIL replay re-debited'; end if;
  if (select hp from public.main_ship_instances where player_id=uR) <> v_hp0 then raise exception 'P4 FAIL replay re-healed the hull'; end if;
  if (select count(*) from public.repair_receipts where main_ship_id=v_ship) <> nrec then raise exception 'P4 FAIL replay wrote a receipt'; end if;
  raise notice 'REPAIR_PASS_IDEMPOTENT ok: replay -> idempotent_replay envelope verbatim, no double debit/heal/receipt';
end $$;

-- ════════ P5 — guards: invalid_amount (0/-3/2.5) · cross-player ship_not_found · nothing_to_repair (full hull)
--            · not_docked (in transit) · insufficient_credits (broke). All zero-write. ════════
do $$
declare r jsonb;
  uR uuid := (select v from re1 where k='uR'); uP uuid := (select v from re1 where k='uP');
  uD uuid := (select v from re1 where k='uD'); uX uuid := (select v from re1 where k='uX');
  v_shipR uuid; v_shipP uuid; v_shipD uuid; v_shipX uuid;
  v_balR numeric; v_hpR int; nrec int;
begin
  select main_ship_id into v_shipR from public.main_ship_instances where player_id=uR;
  select main_ship_id into v_shipP from public.main_ship_instances where player_id=uP;
  select main_ship_id into v_shipD from public.main_ship_instances where player_id=uD;
  select main_ship_id into v_shipX from public.main_ship_instances where player_id=uX;
  select balance, hp into v_balR, v_hpR from public.player_wallet w join public.main_ship_instances m on m.player_id=w.player_id where w.player_id=uR;
  select count(*) into nrec from public.repair_receipts where main_ship_id=v_shipR;

  -- invalid_amount: zero, negative, fractional (hull hp is INTEGER — never rounded).
  r := pg_temp.call_as(uR, format('public.repair_ship_hull_at_port(%L::uuid, %s, %L::uuid)', v_shipR, 0, gen_random_uuid()));
  if (r->>'reason') is distinct from 'invalid_amount' then raise exception 'P5 FAIL amt 0: %', r; end if;
  r := pg_temp.call_as(uR, format('public.repair_ship_hull_at_port(%L::uuid, %s, %L::uuid)', v_shipR, -3, gen_random_uuid()));
  if (r->>'reason') is distinct from 'invalid_amount' then raise exception 'P5 FAIL amt -3: %', r; end if;
  r := pg_temp.call_as(uR, format('public.repair_ship_hull_at_port(%L::uuid, %s, %L::uuid)', v_shipR, 2.5, gen_random_uuid()));
  if (r->>'reason') is distinct from 'invalid_amount' then raise exception 'P5 FAIL amt 2.5 (fractional must reject): %', r; end if;

  -- cross-player: uR cannot repair uX's ship (mainship_resolve_owned_ship asserts ownership) → ship_not_found.
  r := pg_temp.call_as(uR, format('public.repair_ship_hull_at_port(%L::uuid, %s, %L::uuid)', v_shipX, 10, gen_random_uuid()));
  if (r->>'reason') is distinct from 'ship_not_found' then raise exception 'P5 FAIL cross-player: %', r; end if;

  -- nothing_to_repair: uD is docked at Haven with a FULL hull (never damaged) → reject before any charge.
  r := pg_temp.call_as(uD, format('public.repair_ship_hull_at_port(%L::uuid, %s, %L::uuid)', v_shipD, 10, gen_random_uuid()));
  if (r->>'reason') is distinct from 'nothing_to_repair' then raise exception 'P5 FAIL full-hull not nothing_to_repair: %', r; end if;

  -- not_docked: uD departs toward Slagworks → in transit → the ONE docked-resolver returns null. (Damage it
  -- first so nothing_to_repair cannot mask not_docked.)
  update public.main_ship_instances set hp = max_hp - 50 where player_id = uD;
  r := pg_temp.call_as(uD, format('public.command_main_ship_space_move_to_location(%L::uuid, %L::uuid, %L::uuid)',
                                   (select v from re1 where k='slag'), gen_random_uuid(), v_shipD));
  if (r->>'ok')::boolean is not true then raise exception 'P5 FAIL move uD: %', r; end if;
  r := pg_temp.call_as(uD, format('public.repair_ship_hull_at_port(%L::uuid, %s, %L::uuid)', v_shipD, 50, gen_random_uuid()));
  if (r->>'reason') is distinct from 'not_docked' then raise exception 'P5 FAIL in-transit not rejected: %', r; end if;

  -- insufficient_credits: uP is docked at Haven, damaged, wallet 0 → can't afford → NOTHING healed/charged.
  update public.main_ship_instances set hp = max_hp - 80 where player_id = uP;
  r := pg_temp.call_as(uP, format('public.repair_ship_hull_at_port(%L::uuid, %s, %L::uuid)', v_shipP, 80, gen_random_uuid()));
  if (r->>'reason') is distinct from 'insufficient_credits' then raise exception 'P5 FAIL broke not insufficient_credits: %', r; end if;
  if (select hp from public.main_ship_instances where player_id=uP) <> (select max_hp-80 from public.main_ship_instances where player_id=uP) then
    raise exception 'P5 FAIL insufficient_credits still healed the hull'; end if;
  if (select balance from public.player_wallet where player_id=uP) <> 0 then raise exception 'P5 FAIL insufficient_credits moved a 0 wallet'; end if;

  -- ALL guards wrote nothing on uR: wallet, hull, receipts unchanged.
  if (select balance from public.player_wallet where player_id=uR) <> v_balR then raise exception 'P5 FAIL a guard moved uR wallet'; end if;
  if (select hp from public.main_ship_instances where player_id=uR) <> v_hpR then raise exception 'P5 FAIL a guard healed uR hull'; end if;
  if (select count(*) from public.repair_receipts where main_ship_id=v_shipR) <> nrec then raise exception 'P5 FAIL a guard wrote a receipt'; end if;
  raise notice 'REPAIR_PASS_GUARDS ok: invalid_amount (0/-3/2.5), cross-player ship_not_found, full-hull nothing_to_repair, in-transit not_docked, broke insufficient_credits — all zero-write';
end $$;

-- ════════ P6 — THE SAFELOCK SEAM: a DESTROYED ship is REJECTED by the PAID path (ship_destroyed) while the
--            FREE repair_main_ship() still recovers it at ZERO cost, hull → max, UNTOUCHED. ════════
do $$
declare r jsonb; uR uuid := (select v from re1 where k='uR'); v_ship uuid; v_max int; v_bal0 numeric; nrec int;
begin
  select main_ship_id, max_hp into v_ship, v_max from public.main_ship_instances where player_id=uR;
  select balance into v_bal0 from public.player_wallet where player_id=uR;
  select count(*) into nrec from public.repair_receipts where main_ship_id=v_ship;

  -- destroy uR's ship via the service-role primitive (the 10G-combat primitive; status='destroyed', hp 0).
  perform public.dev_set_main_ship_destroyed(uR);
  if (select status from public.main_ship_instances where player_id=uR) <> 'destroyed' then raise exception 'P6 SETUP FAIL: ship not destroyed'; end if;

  -- PAID repair must REJECT a destroyed ship (the seam) — no wallet touch, no receipt, no heal.
  r := pg_temp.call_as(uR, format('public.repair_ship_hull_at_port(%L::uuid, %s, %L::uuid)', v_ship, 100000, gen_random_uuid()));
  if (r->>'reason') is distinct from 'ship_destroyed' then raise exception 'P6 FAIL destroyed not rejected by paid path: %', r; end if;
  if (select balance from public.player_wallet where player_id=uR) <> v_bal0 then raise exception 'P6 FAIL paid path charged a destroyed ship'; end if;
  if (select count(*) from public.repair_receipts where main_ship_id=v_ship) <> nrec then raise exception 'P6 FAIL paid path wrote a receipt on destroyed'; end if;

  -- FREE safelock recovers it — repair_economy_enabled is LIT here, so this also proves the free path is
  -- ungated (never blocked by the economy flag): status home (dark launch_from_dock), hp → max, NO charge.
  r := pg_temp.call_as(uR, 'public.repair_main_ship()');
  if (r->>'status') is distinct from 'home' or (r->>'hp')::int <> v_max then raise exception 'P6 FAIL free recovery: %', r; end if;
  if (select hp from public.main_ship_instances where player_id=uR) <> v_max then raise exception 'P6 FAIL hull not restored by free safelock'; end if;
  if (select balance from public.player_wallet where player_id=uR) <> v_bal0 then raise exception 'P6 FAIL free safelock charged the wallet'; end if;
  raise notice 'REPAIR_PASS_SAFELOCK ok: destroyed ship rejected by paid path (ship_destroyed, zero-write) + FREE repair_main_ship recovered it (hull->max, no charge) even with the economy flag LIT — the seam holds';
end $$;

select 'REPAIR-ECON PROOF PASSED (dark gate; 0.5 knob seed; full mend exact debit + receipt; partial mend; idempotent replay; amount/ownership/full/dock/credit guards; destroyed-safelock seam preserved free + intact)' as result;

rollback;   -- leave ZERO persisted state: no wallet, hp, receipt, ship, flag flip, or fixture user.
