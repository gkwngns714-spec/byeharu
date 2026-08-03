-- ONE WAY TO REPAIR — disposable REAL-CHAIN proof (runs on the actual chain 0001..head in a throwaway
-- Supabase). Proves migration 0335's unified repair verb, public.repair_ship_hull: ONE authority, one
-- position gate, one reason vocabulary, one receipt ledger — with COST and AMOUNT as policy inside it.
--
-- The properties, in order:
--   P0  the economy gate rejects a PRICED mend and writes nothing — while a WRECK still recovers with
--       the same flag dark, because recovery is never gated (the 0052 no-softlock rule)
--   P1  the knob + flag keys EXIST (structure, never a seeded VALUE — this proof sets every value it
--       depends on, in-txn, and asserts nothing it does not own)
--   P2  full mend: over-request clamps to the missing hull, exact debit, hull -> max, one receipt
--   P3  partial mend
--   P4  idempotent replay on (ship, request_id)
--   P5  guards: invalid amounts / another player's ship / a full hull / a ship NOT AT A PORT / broke
--   P6  THE WRECK: a destroyed ship recovers whole and FREE at a NON-ZERO knob, comes back to 'home',
--       and its receipt records 0 credits
--   P7  ZERO IS FREE — knob 0 mends a living hull for a player with an EMPTY wallet
--   P8  a NEGATIVE knob still fails closed (repair_misconfigured)
--   P9  THE KNOB GOVERNS — the identical repair costs 3x at a 3x price
--   P10 ONE AUTHORITY — both predecessors are gone, only repair_ship_hull is client-granted, and the
--       receipt ledger is not client-writable
--   P11 a BERTHED ship (at a port, owning no live fleet) MENDS — the position unification
--
-- RED BY CONSTRUCTION against the exact defects 0335 closes: P7 fails on 0201 (which answered
-- repair_misconfigured for any price <= 0, so the owner's deliberate free-repair setting was a total
-- outage), P11 fails on 0201 (which gated on mainship_resolve_docked_location and answered not_docked
-- for a ship plainly tied up at a port), and P10 fails on any chain where either predecessor survives.
--
-- Fixture users carry the 're1.' email prefix. The ENTIRE proof runs inside ONE transaction that
-- ROLLBACKs — it persists NO wallet, hp, receipt, ship, or flag/knob change. No production access.
-- No COMMIT anywhere.
--
-- ── DARK-CAPABILITY EXERCISE (sanctioned; never crosses a flag human-gate) ────────────────────────
-- The harness SETS repair_economy_enabled false and then true, and sets repair_credits_per_hp to every
-- value it asserts against, ONLY inside this rolled-back transaction — it never trusts a seeded value
-- for anything (a proof that asserts an ambient default is asserting a world, not a property, and goes
-- red the day the owner legitimately retunes it). It transiently mirrors production config a fresh
-- chain lacks (reveal_starter_ports + mainship_space_movement_enabled) — all reverted by ROLLBACK.
-- Ships are commissioned via the REAL commission_first_main_ship() RPC (docked at Haven), then DAMAGED
-- by a direct fixture hp write (combat is the real damage source; the fixture simulates a dented hull),
-- and wallets are pre-seeded by a direct owner insert (the salvage-proof precedent) so every credit
-- assert is an EXACT delta. The harness NEVER writes repair_receipts directly — every receipt is
-- minted by the RPC under test.

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

-- the ONE knob setter this harness uses, so every price in the proof is a value the proof OWNS.
create or replace function pg_temp.set_rate(p_val numeric) returns void language plpgsql as $$
begin
  insert into public.game_config(key, value, description)
    values('repair_credits_per_hp', to_jsonb(p_val), 're1 transient (rolled back)')
    on conflict (key) do update set value = to_jsonb(p_val);
end $$;

-- six fresh players: uR (repairer, funded), uP (poor), uD (undocked), uX (spare/cross-player),
-- uW (the wreck), uB (berthed with no live fleet).
do $$
declare u uuid; sk text;
begin
  foreach sk in array array['uR','uP','uD','uX','uW','uB'] loop
    insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
      values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
              're1.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
      returning id into u;
    insert into re1 values (sk, u);
  end loop;
end $$;

-- mirror production config a fresh disposable chain lacks (all reverted by ROLLBACK): reveal starter
-- ports + enable port-to-port movement. The repair flag is set DARK here BY THIS HARNESS (never
-- inherited from the seed) so P0 proves a gate it owns.
do $$
declare r jsonb;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: reveal_starter_ports %', r; end if;
  insert into public.game_config(key,value,description)
    values('mainship_space_movement_enabled','true'::jsonb,'re1 transient (rolled back)')
    on conflict (key) do update set value='true'::jsonb;
  update public.game_config set value='false'::jsonb where key='repair_economy_enabled';
  perform pg_temp.set_rate(0.5);
end $$;

-- commission each player's first ship (real RPC) → docked at Haven; pre-seed wallets at KNOWN balances
-- by direct owner insert (the salvage-proof funding precedent; rolled back) so every credit assert is
-- an EXACT delta, independent of wallet_ensure's seed.
do $$
declare r jsonb; sk text; u uuid;
begin
  foreach sk in array array['uR','uP','uD','uX','uW','uB'] loop
    u := (select v from re1 where re1.k = sk);
    r := pg_temp.call_as(u, 'public.commission_first_main_ship()');
    if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then raise exception 'SETUP FAIL first-ship %: %', sk, r; end if;
  end loop;
  insert into public.player_wallet (player_id, balance) values
    ((select v from re1 where k='uR'), 1000),
    ((select v from re1 where k='uP'), 0),      -- poor: the insufficient_credits arm AND the free arm
    ((select v from re1 where k='uD'), 500),
    ((select v from re1 where k='uX'), 500),
    ((select v from re1 where k='uW'), 500),
    ((select v from re1 where k='uB'), 500)
  on conflict (player_id) do update set balance = excluded.balance;
end $$;

-- ════════ P0 — THE GATE IS ON THE PRICE, NEVER ON RECOVERY. With repair_economy_enabled DARK (set so
--            by this harness), a PRICED mend rejects and writes nothing — while a WRECK still recovers.
--            That asymmetry IS the one essential difference the two old functions encoded structurally
--            and 0335 encodes as policy; proving it with the flag dark is the only way to see it. ════════
do $$
declare r jsonb; uR uuid := (select v from re1 where k='uR'); uW uuid := (select v from re1 where k='uW');
  v_ship uuid; v_wreck uuid; v_bal numeric; v_hp0 int; v_max int; n int;
begin
  select main_ship_id into v_ship from public.main_ship_instances where player_id=uR;
  -- damage uR's hull by 120 (fixture: a battle-dented hull) so a repair WOULD have something to do.
  update public.main_ship_instances set hp = max_hp - 120 where player_id = uR;
  select hp into v_hp0 from public.main_ship_instances where player_id=uR;   -- max_hp-120
  select balance into v_bal from public.player_wallet where player_id=uR;

  r := pg_temp.call_as(uR, format('public.repair_ship_hull(%L::uuid, %s, %L::uuid)', v_ship, 100000, gen_random_uuid()));
  if (r->>'reason') is distinct from 'repair_economy_disabled' then raise exception 'P0 FAIL dark priced mend: %', r; end if;

  select count(*) into n from public.repair_receipts where main_ship_id=v_ship;
  if n <> 0 then raise exception 'P0 FAIL dark path wrote % receipts', n; end if;
  if (select balance from public.player_wallet where player_id=uR) <> v_bal then raise exception 'P0 FAIL dark path moved wallet'; end if;
  if (select hp from public.main_ship_instances where player_id=uR) <> v_hp0 then raise exception 'P0 FAIL dark path healed hull'; end if;

  -- ...and the SAME dark flag does not touch a wreck. uW is destroyed through the real primitive and
  -- is berthed at Haven (the commissioned shape), so its position gate passes.
  select main_ship_id, max_hp into v_wreck, v_max from public.main_ship_instances where player_id=uW;
  perform public.dev_set_main_ship_destroyed(uW);
  r := pg_temp.call_as(uW, format('public.repair_ship_hull(%L::uuid, null, %L::uuid)', v_wreck, gen_random_uuid()));
  if (r->>'ok')::boolean is not true then raise exception 'P0 FAIL: the economy flag gated a WRECK recovery — a player could never get their ship back: %', r; end if;
  if (r->>'status') is distinct from 'home' or (r->>'total_price')::numeric <> 0 then raise exception 'P0 FAIL wreck recovery envelope: %', r; end if;
  if (select hp from public.main_ship_instances where main_ship_id=v_wreck) <> v_max then raise exception 'P0 FAIL wreck did not come back whole'; end if;

  -- enable the priced capability ONLY inside this rolled-back txn.
  update public.game_config set value='true'::jsonb where key='repair_economy_enabled';
  raise notice 'REPAIR_PASS_DARK_GATE ok: with repair_economy_enabled dark the PRICED mend rejected repair_economy_disabled with zero writes (no receipt/wallet/hp delta), while a WRECK still recovered whole and free — the gate is on the price, never on recovery';
end $$;

-- ════════ P1 — STRUCTURE pins (never a seeded VALUE): the flag key and the knob key exist, and the
--            knob this proof set is the one cfg_num reads back. ════════
do $$
declare v_per numeric;
begin
  if not exists (select 1 from public.game_config where key='repair_economy_enabled') then
    raise exception 'P1 FAIL: repair_economy_enabled key absent (0201 seeds it)'; end if;
  if not exists (select 1 from public.game_config where key='repair_credits_per_hp') then
    raise exception 'P1 FAIL: repair_credits_per_hp key absent (0201 seeds it)'; end if;
  -- the proof OWNS this value (it set 0.5 above); it does not assert whatever the chain happened to
  -- seed. See the header: a test that asserts an ambient default asserts a world, not a property.
  v_per := public.cfg_num('repair_credits_per_hp');
  if v_per is distinct from 0.5 then raise exception 'P1 FAIL: the knob this proof set reads back as % (want 0.5)', v_per; end if;
  raise notice 'REPAIR_PASS_SEED ok: both repair keys exist; the knob this proof SET (0.5) is the value cfg_num returns — no ambient default is asserted anywhere in this file';
end $$;

-- ════════ P2 — HAPPY (full mend via over-request clamp): missing 120 hp, request 100000 → restore
--            EXACTLY 120, debit EXACTLY 120×0.5=60, hull → max_hp, ONE receipt with exact fields. ════════
do $$
declare r jsonb; uR uuid := (select v from re1 where k='uR'); v_ship uuid; v_max int; v_bal0 numeric; v_bal1 numeric;
  n int; v_req uuid := gen_random_uuid();
begin
  select main_ship_id, max_hp into v_ship, v_max from public.main_ship_instances where player_id=uR;  -- still missing 120 from P0
  select balance into v_bal0 from public.player_wallet where player_id=uR;                             -- known 1000

  r := pg_temp.call_as(uR, format('public.repair_ship_hull(%L::uuid, %s, %L::uuid)', v_ship, 100000, v_req));
  if (r->>'ok')::boolean is not true then raise exception 'P2 FAIL repair: %', r; end if;
  -- over-request clamps to the actual missing 120; cost = 120 × 0.5 = 60 EXACT.
  if (r->>'hp_restored')::int <> 120 then raise exception 'P2 FAIL hp_restored %: %', r->>'hp_restored', r; end if;
  if (r->>'total_price')::numeric <> 60 or (r->>'credits_per_hp')::numeric <> 0.5 then raise exception 'P2 FAIL price: %', r; end if;
  if (r->>'hp_after')::int <> v_max then raise exception 'P2 FAIL hp_after % (want max_hp %): %', r->>'hp_after', v_max, r; end if;
  if (r->>'location_id')::uuid is distinct from (select v from re1 where k='haven') then raise exception 'P2 FAIL location: %', r; end if;
  -- a living hull is NOT a recovery: status is untouched and the envelope says so.
  if (r->>'recovered')::boolean is not false then raise exception 'P2 FAIL a dented hull was reported as a recovery: %', r; end if;

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

-- ════════ P3 — PARTIAL: re-damage to missing 100, request only 40 → restore EXACTLY 40, debit 20, hull
--            leaves 60 still missing (a partial mend), ONE more receipt. ════════
do $$
declare r jsonb; uR uuid := (select v from re1 where k='uR'); v_ship uuid; v_max int; v_bal0 numeric;
  n int; v_req uuid := gen_random_uuid();
begin
  select main_ship_id, max_hp into v_ship, v_max from public.main_ship_instances where player_id=uR;
  update public.main_ship_instances set hp = max_hp - 100 where player_id = uR;   -- fixture: fresh 100-hp dent
  select balance into v_bal0 from public.player_wallet where player_id=uR;

  r := pg_temp.call_as(uR, format('public.repair_ship_hull(%L::uuid, %s, %L::uuid)', v_ship, 40, v_req));
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

  r := pg_temp.call_as(uR, format('public.repair_ship_hull(%L::uuid, %s, %L::uuid)', v_ship, 40, v_req));
  if (r->>'ok')::boolean is not true or (r->>'idempotent_replay')::boolean is not true then raise exception 'P4 FAIL not replay: %', r; end if;
  if (r->>'total_price')::numeric <> 20 or (r->>'hp_restored')::int <> 40 then raise exception 'P4 FAIL replay envelope: %', r; end if;

  if (select balance from public.player_wallet where player_id=uR) <> v_bal0 then raise exception 'P4 FAIL replay re-debited'; end if;
  if (select hp from public.main_ship_instances where player_id=uR) <> v_hp0 then raise exception 'P4 FAIL replay re-healed the hull'; end if;
  if (select count(*) from public.repair_receipts where main_ship_id=v_ship) <> nrec then raise exception 'P4 FAIL replay wrote a receipt'; end if;
  raise notice 'REPAIR_PASS_IDEMPOTENT ok: replay -> idempotent_replay envelope verbatim, no double debit/heal/receipt';
end $$;

-- ════════ P5 — guards: invalid_request (no replay key) · invalid_amount (0/-3/2.5) · cross-player
--            ship_not_found · nothing_to_repair (full hull) · not_at_port (in transit) ·
--            insufficient_credits (broke). All zero-write. ════════
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

  -- invalid_request: the replay key is REQUIRED (0335 kept 0201's rule and extended it to recovery).
  r := pg_temp.call_as(uR, format('public.repair_ship_hull(%L::uuid, %s, null)', v_shipR, 10));
  if (r->>'reason') is distinct from 'invalid_request' then raise exception 'P5 FAIL null request id: %', r; end if;

  -- invalid_amount: zero, negative, fractional (hull hp is INTEGER — never rounded). NULL is NOT an
  -- invalid amount — it is the legitimate "restore everything missing" request, proven throughout.
  r := pg_temp.call_as(uR, format('public.repair_ship_hull(%L::uuid, %s, %L::uuid)', v_shipR, 0, gen_random_uuid()));
  if (r->>'reason') is distinct from 'invalid_amount' then raise exception 'P5 FAIL amt 0: %', r; end if;
  r := pg_temp.call_as(uR, format('public.repair_ship_hull(%L::uuid, %s, %L::uuid)', v_shipR, -3, gen_random_uuid()));
  if (r->>'reason') is distinct from 'invalid_amount' then raise exception 'P5 FAIL amt -3: %', r; end if;
  r := pg_temp.call_as(uR, format('public.repair_ship_hull(%L::uuid, %s, %L::uuid)', v_shipR, 2.5, gen_random_uuid()));
  if (r->>'reason') is distinct from 'invalid_amount' then raise exception 'P5 FAIL amt 2.5 (fractional must reject): %', r; end if;

  -- cross-player: uR cannot repair uX's ship (mainship_resolve_owned_ship asserts ownership) →
  -- ship_not_found, which is also the right answer for privacy: never an existence oracle.
  r := pg_temp.call_as(uR, format('public.repair_ship_hull(%L::uuid, %s, %L::uuid)', v_shipX, 10, gen_random_uuid()));
  if (r->>'reason') is distinct from 'ship_not_found' then raise exception 'P5 FAIL cross-player: %', r; end if;
  if (select hp from public.main_ship_instances where player_id=uX) <> (select max_hp from public.main_ship_instances where player_id=uX) then
    raise exception 'P5 FAIL a cross-player call touched the stranger''s hull'; end if;

  -- nothing_to_repair: uD is docked at Haven with a FULL hull (never damaged) → reject before any charge.
  r := pg_temp.call_as(uD, format('public.repair_ship_hull(%L::uuid, %s, %L::uuid)', v_shipD, 10, gen_random_uuid()));
  if (r->>'reason') is distinct from 'nothing_to_repair' then raise exception 'P5 FAIL full-hull not nothing_to_repair: %', r; end if;

  -- not_at_port: uD departs toward Slagworks → in transit → the ONE position authority answers null.
  -- (Damage it first so nothing_to_repair cannot mask not_at_port.)
  update public.main_ship_instances set hp = max_hp - 50 where player_id = uD;
  r := pg_temp.call_as(uD, format('public.command_main_ship_space_move_to_location(%L::uuid, %L::uuid, %L::uuid)',
                                   (select v from re1 where k='slag'), gen_random_uuid(), v_shipD));
  if (r->>'ok')::boolean is not true then raise exception 'P5 FAIL move uD: %', r; end if;
  r := pg_temp.call_as(uD, format('public.repair_ship_hull(%L::uuid, %s, %L::uuid)', v_shipD, 50, gen_random_uuid()));
  if (r->>'reason') is distinct from 'not_at_port' then raise exception 'P5 FAIL in-transit not rejected: %', r; end if;

  -- insufficient_credits: uP is docked at Haven, damaged, wallet 0, price 0.5 → can't afford → NOTHING
  -- healed/charged. (P7 re-runs this exact player at a 0 knob and it SUCCEEDS — that pair is the proof
  -- that the price, and only the price, is what refused here.)
  update public.main_ship_instances set hp = max_hp - 80 where player_id = uP;
  r := pg_temp.call_as(uP, format('public.repair_ship_hull(%L::uuid, %s, %L::uuid)', v_shipP, 80, gen_random_uuid()));
  if (r->>'reason') is distinct from 'insufficient_credits' then raise exception 'P5 FAIL broke not insufficient_credits: %', r; end if;
  if (select hp from public.main_ship_instances where player_id=uP) <> (select max_hp-80 from public.main_ship_instances where player_id=uP) then
    raise exception 'P5 FAIL insufficient_credits still healed the hull'; end if;
  if (select balance from public.player_wallet where player_id=uP) <> 0 then raise exception 'P5 FAIL insufficient_credits moved a 0 wallet'; end if;

  -- ALL guards wrote nothing on uR: wallet, hull, receipts unchanged.
  if (select balance from public.player_wallet where player_id=uR) <> v_balR then raise exception 'P5 FAIL a guard moved uR wallet'; end if;
  if (select hp from public.main_ship_instances where player_id=uR) <> v_hpR then raise exception 'P5 FAIL a guard healed uR hull'; end if;
  if (select count(*) from public.repair_receipts where main_ship_id=v_shipR) <> nrec then raise exception 'P5 FAIL a guard wrote a receipt'; end if;
  raise notice 'REPAIR_PASS_GUARDS ok: invalid_request (null replay key), invalid_amount (0/-3/2.5), cross-player ship_not_found (stranger untouched), full-hull nothing_to_repair, in-transit not_at_port, broke insufficient_credits — all zero-write';
end $$;

-- ════════ P6 — THE WRECK POLICY, at a NON-ZERO price: a destroyed ship is restored WHOLE and FREE,
--            comes back to status='home', and its receipt records 0 credits — while the SAME knob is
--            charging living hulls 0.5/hp. That asymmetry is the one essential difference between the
--            two functions 0335 deleted, and it now lives in eight lines of policy. ════════
do $$
declare r jsonb; uP uuid := (select v from re1 where k='uP'); v_ship uuid; v_max int; nrec int;
begin
  -- uP is the BROKE player on purpose: a wreck must recover with an EMPTY wallet, or a bad fight is a
  -- permanent loss of the ship. The destruction primitive itself zeroes the hull, so the recovery has
  -- a whole max_hp to restore — no fixture damage needed here.
  select main_ship_id, max_hp into v_ship, v_max from public.main_ship_instances where player_id=uP;
  perform public.dev_set_main_ship_destroyed(uP);
  if (select status from public.main_ship_instances where player_id=uP) <> 'destroyed' then raise exception 'P6 SETUP FAIL: ship not destroyed'; end if;
  if public.cfg_num('repair_credits_per_hp') <> 0.5 then raise exception 'P6 SETUP FAIL: the knob is not the 0.5 this phase needs'; end if;

  r := pg_temp.call_as(uP, format('public.repair_ship_hull(%L::uuid, null, %L::uuid)', v_ship, gen_random_uuid()));
  if (r->>'ok')::boolean is not true then raise exception 'P6 FAIL: a broke player could not recover their own wreck at a non-zero knob — that is a permanently lost ship: %', r; end if;
  if (r->>'recovered')::boolean is not true then raise exception 'P6 FAIL: the envelope did not report a recovery: %', r; end if;
  if (r->>'status') is distinct from 'home' then raise exception 'P6 FAIL: the wreck did not come back to home: %', r; end if;
  if (r->>'total_price')::numeric <> 0 or (r->>'credits_per_hp')::numeric <> 0 then raise exception 'P6 FAIL: recovery was PRICED: %', r; end if;
  if (r->>'hp_restored')::int <> v_max then raise exception 'P6 FAIL: recovery was partial (% of %) — a wreck restores whole', r->>'hp_restored', v_max; end if;
  if (select hp from public.main_ship_instances where player_id=uP) <> v_max then raise exception 'P6 FAIL hull not restored'; end if;
  if (select balance from public.player_wallet where player_id=uP) <> 0 then raise exception 'P6 FAIL a free recovery moved the wallet'; end if;
  -- ONE ledger for both policies: the free recovery is receipted too, at zero.
  select count(*) into nrec from public.repair_receipts where main_ship_id=v_ship and total_price=0 and hp_restored=v_max;
  if nrec <> 1 then raise exception 'P6 FAIL: the free recovery wrote % zero-price receipts (want exactly 1) — one verb, one ledger', nrec; end if;
  raise notice 'REPAIR_PASS_WRECK ok: a BROKE player recovered their destroyed ship whole and free (status home, hp->max, 0 credits, one 0-price receipt) while the same knob charges living hulls 0.5/hp — recovery is exempt by POLICY, not by a second function';
end $$;

-- ════════ P7 — ██ ZERO IS FREE ██ (RED BY CONSTRUCTION ON 0201). Set the knob to 0 — the owner's real
--            production setting — and a LIVING damaged hull mends for a player with an EMPTY wallet.
--            0201 answered repair_misconfigured for any price <= 0, so this exact call was a total
--            outage on production the moment the price was set to free. ════════
do $$
declare r jsonb; uP uuid := (select v from re1 where k='uP'); v_ship uuid; v_max int;
begin
  perform pg_temp.set_rate(0);
  if public.cfg_num('repair_credits_per_hp') <> 0 then raise exception 'P7 SETUP FAIL: the knob did not take 0'; end if;
  select main_ship_id, max_hp into v_ship, v_max from public.main_ship_instances where player_id=uP;
  update public.main_ship_instances set hp = max_hp - 90 where player_id = uP;   -- fixture: a fresh dent

  r := pg_temp.call_as(uP, format('public.repair_ship_hull(%L::uuid, %s, %L::uuid)', v_ship, 90, gen_random_uuid()));
  if (r->>'ok')::boolean is not true then
    raise exception 'P7 FAIL: a 0 price refused a repair (%) — setting repairs free must make them FREE, not unavailable', r;
  end if;
  if (r->>'reason') is not null then raise exception 'P7 FAIL: a 0 price produced a reason: %', r; end if;
  if (r->>'total_price')::numeric <> 0 or (r->>'credits_per_hp')::numeric <> 0 then raise exception 'P7 FAIL price at a 0 knob: %', r; end if;
  if (r->>'hp_restored')::int <> 90 then raise exception 'P7 FAIL restored %: %', r->>'hp_restored', r; end if;
  if (select hp from public.main_ship_instances where player_id=uP) <> v_max then raise exception 'P7 FAIL hull not mended at a 0 knob'; end if;
  if (select balance from public.player_wallet where player_id=uP) <> 0 then raise exception 'P7 FAIL a 0-price mend moved a 0 wallet'; end if;
  raise notice 'REPAIR_PASS_ZERO_IS_FREE ok: with repair_credits_per_hp = 0 an EMPTY-wallet player mended a living hull for 0 credits — the exact call 0201 refused as repair_misconfigured, which is what turned the owner''s deliberate free-repair setting into a game-wide outage';
end $$;

-- ════════ P8 — a NEGATIVE knob still FAILS CLOSED. Free is a price; nonsense is not. ════════
do $$
declare r jsonb; uR uuid := (select v from re1 where k='uR'); v_ship uuid; v_hp0 int; v_bal0 numeric;
begin
  perform pg_temp.set_rate(-1);
  select main_ship_id, hp into v_ship, v_hp0 from public.main_ship_instances where player_id=uR;
  select balance into v_bal0 from public.player_wallet where player_id=uR;
  r := pg_temp.call_as(uR, format('public.repair_ship_hull(%L::uuid, %s, %L::uuid)', v_ship, 10, gen_random_uuid()));
  if (r->>'reason') is distinct from 'repair_misconfigured' then raise exception 'P8 FAIL: a negative price did not fail closed: %', r; end if;
  if (select hp from public.main_ship_instances where player_id=uR) <> v_hp0 then raise exception 'P8 FAIL a misconfigured knob healed the hull'; end if;
  if (select balance from public.player_wallet where player_id=uR) <> v_bal0 then raise exception 'P8 FAIL a misconfigured knob moved the wallet'; end if;
  raise notice 'REPAIR_PASS_MISCONFIG ok: a NEGATIVE repair_credits_per_hp still rejects repair_misconfigured with zero writes — only 0 was reinterpreted, and only because 0 is a real price';
end $$;

-- ════════ P9 — ██ THE KNOB STILL GOVERNS ██. Set it to 3 and the identical repair costs 3/hp. Putting
--            the price back is ONE set-knob call and nothing else — no migration, no code change. ════════
do $$
declare r jsonb; uR uuid := (select v from re1 where k='uR'); v_ship uuid; v_max int; v_bal0 numeric;
begin
  perform pg_temp.set_rate(3);
  if public.cfg_num('repair_credits_per_hp') <> 3 then raise exception 'P9 SETUP FAIL: the knob did not take 3'; end if;
  select main_ship_id, max_hp into v_ship, v_max from public.main_ship_instances where player_id=uR;
  update public.main_ship_instances set hp = max_hp - 30 where player_id = uR;
  select balance into v_bal0 from public.player_wallet where player_id=uR;

  r := pg_temp.call_as(uR, format('public.repair_ship_hull(%L::uuid, %s, %L::uuid)', v_ship, 30, gen_random_uuid()));
  if (r->>'ok')::boolean is not true then raise exception 'P9 FAIL priced mend: %', r; end if;
  if (r->>'credits_per_hp')::numeric <> 3 or (r->>'total_price')::numeric <> 90 then
    raise exception 'P9 FAIL: the knob did not govern the charge (want 30 × 3 = 90): %', r; end if;
  if v_bal0 - (select balance from public.player_wallet where player_id=uR) <> 90 then
    raise exception 'P9 FAIL wallet delta (want exactly -90)'; end if;
  if not exists (select 1 from public.repair_receipts where main_ship_id=v_ship and credits_per_hp=3 and total_price=90) then
    raise exception 'P9 FAIL the receipt did not record the 3/hp price'; end if;
  raise notice 'REPAIR_PASS_KNOB_GOVERNS ok: the same 30-hp mend that was free at knob 0 cost exactly 90 at knob 3, debited and receipted — restoring the price later is one set-knob call, and nothing in the repair body is hardcoded';
end $$;

-- ════════ P10 — ██ ONE AUTHORITY ██. Both predecessors are GONE (not deprecated, not shimmed), only
--            repair_ship_hull is client-granted, and the receipt ledger is not client-writable. ════════
do $$
declare n int;
begin
  if to_regprocedure('public.repair_main_ship(uuid)') is not null then
    raise exception 'P10 FAIL: repair_main_ship still exists — a second repair authority is live';
  end if;
  if to_regprocedure('public.repair_ship_hull_at_port(uuid,numeric,uuid)') is not null then
    raise exception 'P10 FAIL: repair_ship_hull_at_port still exists — a second repair authority is live';
  end if;
  -- exactly ONE client-executable repair verb, by count, so a future third one is caught too.
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname='public' and p.proname like 'repair%'
     and has_function_privilege('authenticated', p.oid, 'execute');
  if n <> 1 then
    raise exception 'P10 FAIL: % client-executable repair* functions (want exactly 1 — repair_ship_hull)', n;
  end if;
  if not has_function_privilege('authenticated','public.repair_ship_hull(uuid,numeric,uuid)','execute')
     or has_function_privilege('anon','public.repair_ship_hull(uuid,numeric,uuid)','execute') then
    raise exception 'P10 FAIL: repair_ship_hull ACL drifted (want authenticated-only, never anon)';
  end if;
  -- the ledger the one verb writes is not forgeable by a client (0335 §3 revoked the Supabase
  -- project-default GRANT ALL that no earlier migration had ever removed).
  if has_table_privilege('authenticated','public.repair_receipts','insert')
     or has_table_privilege('anon','public.repair_receipts','insert')
     or has_table_privilege('authenticated','public.repair_receipts','update')
     or has_table_privilege('authenticated','public.repair_receipts','delete') then
    raise exception 'P10 FAIL: a client role can write repair_receipts — a forgeable ledger is not a ledger';
  end if;
  raise notice 'REPAIR_PASS_ONE_AUTHORITY ok: repair_main_ship and repair_ship_hull_at_port are gone, exactly ONE client-executable repair* function remains (repair_ship_hull, authenticated-only, never anon), and repair_receipts client INSERT/UPDATE/DELETE is revoked';
end $$;

-- ════════ P11 — ██ THE POSITION UNIFICATION ██ (RED BY CONSTRUCTION ON 0201). A ship BERTHED at a port
--            that owns no live fleet is at that port — mainship_port_of_ship says so, and the recovery
--            path always agreed. The paid mend did not: it gated on mainship_resolve_docked_location,
--            which additionally demands a PRESENT FLEET, so it answered not_docked for a ship the rest
--            of the game rendered as "Docked at Haven". One authority ends that disagreement. ════════
do $$
declare r jsonb; uB uuid := (select v from re1 where k='uB'); v_ship uuid; v_max int; v_port uuid; v_docked uuid;
begin
  select main_ship_id, max_hp into v_ship, v_max from public.main_ship_instances where player_id=uB;
  -- FIXTURE SURGERY (rolled back): finish the commission fleet so the ship owns no NON-TERMINAL fleet
  -- row. mainship_resolve_fleet only considers idle/moving/present/returning, so the ship now resolves
  -- no fleet and falls to mainship_port_of_ship's BERTH arm — the exact shape a player sees after a
  -- fleet is disbanded, and the shape all three of production's destroyed ships carry.
  update public.fleets set status = 'completed' where main_ship_id = v_ship;
  update public.main_ship_instances set hp = max_hp - 70 where main_ship_id = v_ship;

  -- the premise, proven rather than assumed: the two old authorities DISAGREE about this ship.
  v_port   := public.mainship_port_of_ship(v_ship);
  v_docked := public.mainship_resolve_docked_location(v_ship);
  if v_port is distinct from (select v from re1 where k='haven') then
    raise exception 'P11 PREMISE FAIL: the position authority does not place the berthed ship at Haven (got %) — without that this phase proves nothing', v_port;
  end if;
  if v_docked is not null then
    raise exception 'P11 PREMISE FAIL: the old dock resolver still answers % for a fleet-less berthed ship — the divergence this phase exists to close is not present', v_docked;
  end if;

  -- and the ONE verb accepts it, at the port the rest of the game already shows.
  r := pg_temp.call_as(uB, format('public.repair_ship_hull(%L::uuid, null, %L::uuid)', v_ship, gen_random_uuid()));
  if (r->>'ok')::boolean is not true then
    raise exception 'P11 FAIL: a ship berthed at a port could not be repaired there (%) — this is the dead end that forced the client to say "add this ship to a fleet to mend its hull here"', r;
  end if;
  if (r->>'location_id')::uuid is distinct from (select v from re1 where k='haven') then
    raise exception 'P11 FAIL: the mend receipted the wrong port: %', r; end if;
  if (select hp from public.main_ship_instances where main_ship_id=v_ship) <> v_max then
    raise exception 'P11 FAIL hull not mended'; end if;
  raise notice 'REPAIR_PASS_ONE_POSITION ok: a BERTHED ship owning no live fleet resolves Haven through mainship_port_of_ship while the old dock resolver answers NULL for it — and the one repair verb mends it there. Under 0201 this identical ship answered not_docked';
end $$;

select 'ONE-WAY-TO-REPAIR PROOF PASSED (gate on price not recovery; owned knob values only; full mend exact debit + receipt; partial mend; idempotent replay; request/amount/ownership/full/position/credit guards; wreck restores whole + free at a non-zero knob; ZERO means FREE; negative fails closed; the knob still governs at 3/hp; one authority with both predecessors dropped and the ledger client-locked; a berthed ship mends where it is)' as result;

rollback;   -- leave ZERO persisted state: no wallet, hp, receipt, ship, flag flip, or fixture user.
