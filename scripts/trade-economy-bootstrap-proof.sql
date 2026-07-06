-- TRADE-ECONOMY-BOOTSTRAP — disposable REAL-CHAIN proof (runs on the actual chain 0001..0095 in a throwaway Supabase).
-- Proves the two economy-bootstrap features: (a) SEED CAPITAL — starting_credits is seeded ONCE at wallet creation
-- (via wallet_ensure) then debited, never re-seeded; and (b) the NO-SOFTLOCK RELIEF FLOOR — market_claim_relief's
-- full anti-farm matrix (dark gate, existing-wallet requirement, rock-bottom checks, idempotency, cooldown, cap).
-- Fixture users carry the 'teb.' email prefix. The ENTIRE proof runs inside ONE transaction that ROLLBACKs — it
-- persists NO wallet, lot, receipt, ship, claim, or flag flip. No production access. No COMMIT anywhere.
--
-- ── DARK-CAPABILITY EXERCISE (sanctioned; never crosses a flag human-gate) ────────────────────────
-- The harness enables trade_market_enabled + trade_relief_enabled ONLY inside this rolled-back transaction to
-- exercise the dark capabilities; the ROLLBACK reverts them, so the committed/production flag values stay false.
-- It also transiently mirrors production config a fresh chain lacks (reveal_starter_ports +
-- mainship_space_movement_enabled=true) and transiently zeroes relief_cooldown_seconds for the CAP case — ALL
-- reverted by ROLLBACK. Wallets/cargo are set up by direct owner insert/update (the harness runs as the DB owner,
-- bypassing RLS) — also rolled back. Relief credits are NEVER injected directly: the GRANT case exercises the real
-- market_claim_relief RPC end-to-end.

\set ON_ERROR_STOP on

begin;   -- everything below is transient; the trailing ROLLBACK leaves ZERO persisted state.

create temp table teb(k text primary key, v uuid) on commit preserve rows;
insert into teb values
  ('haven','b1a00001-0066-4a00-8a00-000000000001'),     -- Haven (commission port; seeded market_offers)
  ('slag', 'b1a00002-0066-4a00-8a00-000000000002');     -- Slagworks (a different active port)

-- caller helper: set the authenticated subject then run an RPC, returning its jsonb.
create or replace function pg_temp.call_as(p_sub uuid, p_fn text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_fn into v;
  return v;
end $$;

-- six fresh players: uS1 (seed), uR (relief rock-bottom/grant/cooldown), uNW (no wallet), uPos (has credits),
-- uC (cargo not empty), uCap (lifetime-cap drainer).
do $$
declare u uuid; k text;
begin
  foreach k in array array['uS1','uR','uNW','uPos','uC','uCap'] loop
    insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
      values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
              'teb.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
      returning id into u;
    insert into teb values (k, u);
  end loop;
end $$;

-- mirror production config a fresh disposable chain lacks (all reverted by ROLLBACK): reveal starter ports +
-- enable the port-to-port movement domain. Both economy flags stay OFF here (the DARK cases prove the reject first).
do $$
declare r jsonb;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: reveal_starter_ports %', r; end if;
  insert into public.game_config(key,value,description)
    values('mainship_space_movement_enabled','true'::jsonb,'teb transient (rolled back)')
    on conflict (key) do update set value='true'::jsonb;
end $$;

-- commission each player's first ship (real RPC) → docked at Haven. Commissioning creates NO wallet (0072), so the
-- seed/no_wallet cases below start from a genuinely wallet-less player.
do $$
declare r jsonb; k text; u uuid;
begin
  foreach k in array array['uS1','uR','uNW','uPos','uC','uCap'] loop
    u := (select v from teb where teb.k = k);
    r := pg_temp.call_as(u, 'public.commission_first_main_ship()');
    if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then raise exception 'SETUP FAIL first-ship %: %', k, r; end if;
  end loop;
end $$;

-- ════════ SEED_DARK — trade OFF: a wallet-less player's market_buy rejects AND seeds no wallet row. ════════
do $$
declare r jsonb; uS1 uuid := (select v from teb where k='uS1'); v_ship uuid; n int;
begin
  select main_ship_id into v_ship from public.main_ship_instances where player_id=uS1;
  if (select count(*) from public.player_wallet where player_id=uS1) <> 0 then raise exception 'SEED_DARK FAIL: wallet exists pre-buy'; end if;

  r := pg_temp.call_as(uS1, format('public.market_buy(%L::uuid, %L, %s, %L::uuid)', v_ship, 'ore', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'trade_market_disabled' then raise exception 'SEED_DARK FAIL not dark-rejected: %', r; end if;
  select count(*) into n from public.player_wallet where player_id=uS1;
  if n <> 0 then raise exception 'SEED_DARK FAIL dark path seeded a wallet (% rows)', n; end if;

  -- enable the dark trade capability ONLY inside this rolled-back txn (production flag stays false after ROLLBACK).
  update public.game_config set value='true'::jsonb where key='trade_market_enabled';
  raise notice 'SEED_PASS_DARK ok: wallet-less market_buy rejected trade_market_disabled, no wallet seeded while dark';
end $$;

-- ════════ SEED_APPLIED — first buy seeds starting_credits(1000) once, then debits: balance = 1000 − T. ════════
do $$
declare r jsonb; uS1 uuid := (select v from teb where k='uS1'); v_ship uuid; v_bal numeric; v_total numeric;
begin
  select main_ship_id into v_ship from public.main_ship_instances where player_id=uS1;
  if public.cfg_num('starting_credits') <> 1000 then raise exception 'SEED_APPLIED FAIL starting_credits % (want 1000)', public.cfg_num('starting_credits'); end if;

  -- FIRST buy creates the wallet (wallet_debit → wallet_ensure seeds 1000), then debits the cost.
  r := pg_temp.call_as(uS1, format('public.market_buy(%L::uuid, %L, %s, %L::uuid)', v_ship, 'ore', 1, gen_random_uuid()));
  if (r->>'ok')::boolean is not true or (r->>'side') <> 'buy' then raise exception 'SEED_APPLIED FAIL buy: %', r; end if;
  v_total := (r->>'total_price')::numeric;   -- ore sell_price 20 * 1 = 20
  select balance into v_bal from public.player_wallet where player_id=uS1;
  if v_bal <> 1000 - v_total then raise exception 'SEED_APPLIED FAIL balance % (want %)', v_bal, 1000 - v_total; end if;
  raise notice 'SEED_PASS_APPLIED ok: first buy seeded 1000 then debited % → balance %', v_total, v_bal;
end $$;

-- ════════ SEED_ONCE — a second buy debits further; balance never returns to 1000 (no re-seed; unfarmable). ════════
do $$
declare r jsonb; uS1 uuid := (select v from teb where k='uS1'); v_ship uuid; v_bal0 numeric; v_bal1 numeric; v_total numeric;
begin
  select main_ship_id into v_ship from public.main_ship_instances where player_id=uS1;
  select balance into v_bal0 from public.player_wallet where player_id=uS1;   -- 980

  r := pg_temp.call_as(uS1, format('public.market_buy(%L::uuid, %L, %s, %L::uuid)', v_ship, 'ore', 1, gen_random_uuid()));
  if (r->>'ok')::boolean is not true then raise exception 'SEED_ONCE FAIL buy: %', r; end if;
  v_total := (r->>'total_price')::numeric;
  select balance into v_bal1 from public.player_wallet where player_id=uS1;
  if v_bal1 <> v_bal0 - v_total then raise exception 'SEED_ONCE FAIL balance % (want %)', v_bal1, v_bal0 - v_total; end if;
  if v_bal1 = 1000 then raise exception 'SEED_ONCE FAIL wallet re-seeded to 1000'; end if;
  raise notice 'SEED_PASS_ONCE ok: 2nd buy debited to % — never re-seeded to 1000 (on conflict do nothing)', v_bal1;
end $$;

-- ════════ RELIEF_DARK — relief OFF: rock-bottom player's claim rejects, writes no claim, leaves wallet at 0. ════════
do $$
declare r jsonb; uR uuid := (select v from teb where k='uR'); n int;
begin
  -- set uR up as an existing rock-bottom account: wallet row at balance 0 (owner insert), no cargo.
  insert into public.player_wallet (player_id, balance) values (uR, 0)
    on conflict (player_id) do update set balance = 0;

  r := pg_temp.call_as(uR, format('public.market_claim_relief(%L::uuid)', gen_random_uuid()));
  if (r->>'reason') is distinct from 'trade_relief_disabled' then raise exception 'RELIEF_DARK FAIL not dark-rejected: %', r; end if;
  select count(*) into n from public.trade_relief_claims where player_id=uR;
  if n <> 0 then raise exception 'RELIEF_DARK FAIL dark path wrote % claims', n; end if;
  if (select balance from public.player_wallet where player_id=uR) <> 0 then raise exception 'RELIEF_DARK FAIL dark path moved wallet'; end if;

  -- enable the dark relief capability ONLY inside this rolled-back txn (production flag stays false after ROLLBACK).
  update public.game_config set value='true'::jsonb where key='trade_relief_enabled';
  raise notice 'RELIEF_PASS_DARK ok: rock-bottom claim rejected trade_relief_disabled, zero claims, wallet at 0';
end $$;

-- ════════ RELIEF_NO_WALLET — a wallet-less player → no_wallet; no claim; STILL no wallet (relief never ensures). ════════
do $$
declare r jsonb; uNW uuid := (select v from teb where k='uNW'); n int;
begin
  if (select count(*) from public.player_wallet where player_id=uNW) <> 0 then raise exception 'RELIEF_NO_WALLET FAIL: wallet exists pre-claim'; end if;

  r := pg_temp.call_as(uNW, format('public.market_claim_relief(%L::uuid)', gen_random_uuid()));
  if (r->>'reason') is distinct from 'no_wallet' then raise exception 'RELIEF_NO_WALLET FAIL not no_wallet: %', r; end if;
  if (select count(*) from public.trade_relief_claims where player_id=uNW) <> 0 then raise exception 'RELIEF_NO_WALLET FAIL wrote a claim'; end if;
  select count(*) into n from public.player_wallet where player_id=uNW;
  if n <> 0 then raise exception 'RELIEF_NO_WALLET FAIL relief ensured a wallet (% rows) — seed+relief hole', n; end if;
  raise notice 'RELIEF_PASS_NO_WALLET ok: wallet-less → no_wallet, no claim, still no wallet (no wallet_ensure in relief)';
end $$;

-- ════════ RELIEF_WALLET_NOT_EMPTY — balance > 0 → wallet_not_empty, no claim. ════════
do $$
declare r jsonb; uPos uuid := (select v from teb where k='uPos');
begin
  insert into public.player_wallet (player_id, balance) values (uPos, 100)
    on conflict (player_id) do update set balance = 100;

  r := pg_temp.call_as(uPos, format('public.market_claim_relief(%L::uuid)', gen_random_uuid()));
  if (r->>'reason') is distinct from 'wallet_not_empty' then raise exception 'RELIEF_WALLET_NOT_EMPTY FAIL: %', r; end if;
  if (r->>'balance')::numeric <> 100 then raise exception 'RELIEF_WALLET_NOT_EMPTY FAIL balance in payload %', r->>'balance'; end if;
  if (select count(*) from public.trade_relief_claims where player_id=uPos) <> 0 then raise exception 'RELIEF_WALLET_NOT_EMPTY FAIL wrote a claim'; end if;
  raise notice 'RELIEF_PASS_WALLET_NOT_EMPTY ok: balance 100 → wallet_not_empty, no claim';
end $$;

-- ════════ RELIEF_CARGO_NOT_EMPTY — balance 0 but a cargo lot present → cargo_not_empty, no claim. ════════
do $$
declare r jsonb; uC uuid := (select v from teb where k='uC'); v_ship uuid;
begin
  select main_ship_id into v_ship from public.main_ship_instances where player_id=uC;
  insert into public.player_wallet (player_id, balance) values (uC, 0)
    on conflict (player_id) do update set balance = 0;
  -- directly seed a cargo lot (owner insert; rolled back) so the account has cargo but zero credits.
  insert into public.ship_cargo_lots (main_ship_id, good_id, qty, unit_cost_basis, origin_location_id)
    values (v_ship, 'ore', 2, 20, (select v from teb where k='haven'));

  r := pg_temp.call_as(uC, format('public.market_claim_relief(%L::uuid)', gen_random_uuid()));
  if (r->>'reason') is distinct from 'cargo_not_empty' then raise exception 'RELIEF_CARGO_NOT_EMPTY FAIL: %', r; end if;
  if (r->>'cargo_qty')::numeric <> 2 then raise exception 'RELIEF_CARGO_NOT_EMPTY FAIL cargo_qty in payload %', r->>'cargo_qty'; end if;
  if (select count(*) from public.trade_relief_claims where player_id=uC) <> 0 then raise exception 'RELIEF_CARGO_NOT_EMPTY FAIL wrote a claim'; end if;
  raise notice 'RELIEF_PASS_CARGO_NOT_EMPTY ok: balance 0 + cargo 2 → cargo_not_empty, no claim';
end $$;

-- ════════ RELIEF_GRANT — genuine rock-bottom uR → ok; wallet 0 → relief_credits(250); exactly one claim @ 250. ════════
do $$
declare r jsonb; uR uuid := (select v from teb where k='uR'); v_bal numeric; n int; v_req uuid := gen_random_uuid();
begin
  if public.cfg_num('relief_credits') <> 250 then raise exception 'RELIEF_GRANT FAIL relief_credits % (want 250)', public.cfg_num('relief_credits'); end if;

  r := pg_temp.call_as(uR, format('public.market_claim_relief(%L::uuid)', v_req));
  if (r->>'ok')::boolean is not true then raise exception 'RELIEF_GRANT FAIL not ok: %', r; end if;
  if (r->>'amount')::numeric <> 250 then raise exception 'RELIEF_GRANT FAIL amount % (want 250)', r->>'amount'; end if;
  select balance into v_bal from public.player_wallet where player_id=uR;
  if v_bal <> 250 then raise exception 'RELIEF_GRANT FAIL balance % (want 250)', v_bal; end if;
  select count(*) into n from public.trade_relief_claims where player_id=uR;
  if n <> 1 then raise exception 'RELIEF_GRANT FAIL % claims (want 1)', n; end if;
  if (select amount from public.trade_relief_claims where player_id=uR) <> 250 then raise exception 'RELIEF_GRANT FAIL claim amount'; end if;

  insert into teb values ('reliefreq', v_req);   -- stash for the idempotency replay
  raise notice 'RELIEF_PASS_GRANT ok: rock-bottom → ok, wallet 0 → 250, exactly 1 claim @ 250';
end $$;

-- ════════ RELIEF_IDEMPOTENT — replay same request_id → idempotent_replay; no 2nd claim; balance still 250. ════════
do $$
declare r jsonb; uR uuid := (select v from teb where k='uR'); v_req uuid := (select v from teb where k='reliefreq');
begin
  r := pg_temp.call_as(uR, format('public.market_claim_relief(%L::uuid)', v_req));
  if (r->>'ok')::boolean is not true or (r->>'idempotent_replay')::boolean is not true then raise exception 'RELIEF_IDEMPOTENT FAIL not replay: %', r; end if;
  if (select count(*) from public.trade_relief_claims where player_id=uR) <> 1 then raise exception 'RELIEF_IDEMPOTENT FAIL replay wrote a claim'; end if;
  if (select balance from public.player_wallet where player_id=uR) <> 250 then raise exception 'RELIEF_IDEMPOTENT FAIL replay re-credited'; end if;
  raise notice 'RELIEF_PASS_IDEMPOTENT ok: replay → idempotent_replay, no 2nd claim, balance still 250';
end $$;

-- ════════ RELIEF_COOLDOWN — drain uR to 0, claim again (new request_id) → relief_cooldown_active, no new claim. ════════
do $$
declare r jsonb; uR uuid := (select v from teb where k='uR');
begin
  update public.player_wallet set balance = 0 where player_id=uR;   -- drain so wallet_not_empty can't mask cooldown

  r := pg_temp.call_as(uR, format('public.market_claim_relief(%L::uuid)', gen_random_uuid()));
  if (r->>'reason') is distinct from 'relief_cooldown_active' then raise exception 'RELIEF_COOLDOWN FAIL: %', r; end if;
  if (r->>'next_eligible_at') is null then raise exception 'RELIEF_COOLDOWN FAIL missing next_eligible_at: %', r; end if;
  if (select count(*) from public.trade_relief_claims where player_id=uR) <> 1 then raise exception 'RELIEF_COOLDOWN FAIL wrote a claim'; end if;
  if (select balance from public.player_wallet where player_id=uR) <> 0 then raise exception 'RELIEF_COOLDOWN FAIL moved wallet'; end if;
  raise notice 'RELIEF_PASS_COOLDOWN ok: within cooldown → relief_cooldown_active (+next_eligible_at), no new claim, wallet 0';
end $$;

-- ════════ RELIEF_CAP — with cooldown transiently 0, uCap claims 3× then the 4th → relief_cap_reached. ════════
do $$
declare r jsonb; uCap uuid := (select v from teb where k='uCap'); i int; n int;
begin
  -- transiently drop the cooldown to 0 so only the LIFETIME CAP can block (rolled back with everything else).
  update public.game_config set value='0'::jsonb where key='relief_cooldown_seconds';
  insert into public.player_wallet (player_id, balance) values (uCap, 0)
    on conflict (player_id) do update set balance = 0;

  for i in 1..3 loop
    r := pg_temp.call_as(uCap, format('public.market_claim_relief(%L::uuid)', gen_random_uuid()));
    if (r->>'ok')::boolean is not true then raise exception 'RELIEF_CAP FAIL claim % not ok: %', i, r; end if;
    update public.player_wallet set balance = 0 where player_id=uCap;   -- drain between claims so balance stays rock-bottom
  end loop;
  select count(*) into n from public.trade_relief_claims where player_id=uCap;
  if n <> 3 then raise exception 'RELIEF_CAP FAIL % claims after 3 grants (want 3)', n; end if;
  if public.cfg_num('relief_max_lifetime_claims') <> 3 then raise exception 'RELIEF_CAP FAIL cap % (want 3)', public.cfg_num('relief_max_lifetime_claims'); end if;

  -- 4th claim → cap reached (count 3 >= relief_max_lifetime_claims), no 4th claim/credit.
  r := pg_temp.call_as(uCap, format('public.market_claim_relief(%L::uuid)', gen_random_uuid()));
  if (r->>'reason') is distinct from 'relief_cap_reached' then raise exception 'RELIEF_CAP FAIL 4th not capped: %', r; end if;
  if (r->>'claims')::int <> 3 then raise exception 'RELIEF_CAP FAIL claims in payload %', r->>'claims'; end if;
  if (select count(*) from public.trade_relief_claims where player_id=uCap) <> 3 then raise exception 'RELIEF_CAP FAIL 4th wrote a claim'; end if;
  if (select balance from public.player_wallet where player_id=uCap) <> 0 then raise exception 'RELIEF_CAP FAIL 4th credited'; end if;
  raise notice 'RELIEF_PASS_CAP ok: 3 grants then 4th → relief_cap_reached, no 4th claim/credit';
end $$;

select 'TRADE-ECONOMY-BOOTSTRAP PROOF PASSED (seed applied once + unfarmable; relief dark/no_wallet/wallet_not_empty/cargo_not_empty/grant/idempotent/cooldown/cap)' as result;

rollback;   -- leave ZERO persisted state: no wallet, lot, receipt, ship, claim, flag flip, or fixture user.
