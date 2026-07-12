-- TRADE ACTIVATION — the Phase-10 flip (docs/FULL_CAPACITY_PLAN.md §B rung 3 "Trade market";
-- queue slice #5 ACT-TRADE; prereq ECON-SEED-1 = migration 0173, the differentiated three-port economy).
--
-- ██ HUMAN ACTIVATION TOOL ██ — run BY THE HUMAN, deliberately, against prod. NOT CI; nothing
-- flips at build/deploy time. Each run of this file IS the recorded human go decision.
--
-- ── WHAT IT DOES (one transaction; COMMIT only if every assert passes) ───────────────────────────
--   PRECONDITIONS (no write until these hold):
--     • migration head >= 20260618000173 AND 0173 (the multiport econ seed) is actually recorded in
--       supabase_migrations.schema_migrations — the flip physically cannot light a one-port economy;
--     • the seeded economy is REALLY there and sane: each of the 3 starter ports (0066) carries
--       exactly 6 ACTIVE offers over the six 0073 goods (18 rows total); the anti-pump spread
--       (sell_price >= buy_price) holds on EVERY row; and the 3 flagship routes are re-derived
--       PROFITABLE from the live rows (route direction law: the player buys at origin sell_price and
--       sells at destination buy_price, so profit = dest.buy - origin.sell — the
--       trade-econ-seed-proof's independent-recompute style, cheap form): ore Slagworks→Haven,
--       provisions Haven→Slagworks, machinery Slagworks→Driftmarch;
--     • the DEPLOYED trade RPC bodies are the 0138 re-creates, prosrc-pinned: each of
--       get_market_offers / market_buy / market_sell must carry BOTH the shared docked-resolve
--       helper call 'public.mainship_resolve_docked_location(v_ship)' (0138 restored it; the 0136
--       stale-body regression re-inlined that block and does not contain the token ANYWHERE, its
--       body comments included) AND 'trade_effective_price(' (the P19 price composition, which the
--       pre-drift 0092 bodies — helper call but no composition — lack). Two positive pins together
--       identify 0138 and no comment in an older body can fake them;
--     • the relief backstop is wired and sane (0094/0095): relief_credits (0094 seeds 250) in
--       0 < x <= starting_credits — relief must never out-pay the first-trade wallet seed (the 0095
--       farming-hole reasoning); relief_max_lifetime_claims (0094 seeds 3) in 1..10;
--       relief_cooldown_seconds (0094 seeds 86400) >= 3600. Asserted, NEVER rewritten;
--     • starting_credits exists and is > 0 (1000 — the lazy wallet seed, 0093) and main_ship_price
--       exists and is > 0 (READ-ONLY here: already 250 on prod runtime since the 2026-07-12 team
--       activation — this script NEVER rewrites it);
--     • the two config keys this script writes already exist (no typo can invent a key).
--   STAGE 1 — the switch (the ONLY writes of this script; plan §B rung 3: they light together):
--     1. trade_market_enabled → true  (the market surface lights: get_market_offers / market_buy /
--        market_sell — 0087/0089/0090 as re-created by 0136 and finally 0138)
--     2. trade_relief_enabled → true  (market_claim_relief lights: 0095 — the no-softlock backstop.
--        Relief MUST light with the market: the moment credits can be spent, a player can reach
--        0 credits + 0 cargo, and relief is the designed recovery floor — plan §B rung 3.)
--   STAGE 2 — smoke asserts (read-only): both flags committed true (raw value + cfg_bool); the whole
--     trade function surface exists via to_regprocedure (the 4 client RPCs + the 8 internal leaves);
--     EXACTLY 18 active offers across EXACTLY 3 ports; the anti-pump CHECK constraint exists on
--     market_offers (matched by definition text, not by auto-generated name); ship_cargo_lots exists
--     and is selectable (count >= 0, FYI — likely 0 at flip time).
--   Emits ACTIVATE_TRADE_PASS_* markers per stage and one final PASS line; any failed assert RAISES
--   → the whole transaction rolls back → NOTHING is applied (all-or-nothing activation).
--
-- IDEMPOTENT: safe to re-run — both writes are set_game_config upserts to the same value.
--
-- ── THE FINAL STEP IS NOT IN THIS FILE (verified against this branch, 2026-07-12) ────────────────
--   AFTER this script passes against prod, ship the ONE-LINE client PR flipping the compile mirror
--   in src/features/map/osnReleaseGates.ts:
--       export const TRADE_MARKET_ENABLED = true as const
--   → admin merge → Pages deploy mounts, EXACTLY (both mount sites verified in source):
--     • MarketPanel on the Port screen main rail — PortScreen.tsx:61
--       `{TRADE_MARKET_ENABLED && <MarketPanel key={…} selectedShip={…} />}` — the ONLY newly
--       visible surface: per-selected-ship wallet balance, cargo m³, docked station offers with
--       Buy/Sell actions (idempotent request ids);
--     • the ShipSwitcher OR-gate completes — ShipScreen.tsx:62
--       `{(TRADE_MARKET_ENABLED || MAINSHIP_ADDITIONAL_ENABLED) && <ShipSwitcher …/>}`. NOTE: the
--       switcher is ALREADY MOUNTED today because MAINSHIP_ADDITIONAL_ENABLED has been true since
--       the 2026-07-12 team launch — this flip completes the designed OR-gate but produces NO new
--       visible switcher change. Claim only what mounts: MarketPanel is the visible delta.
--   There is NO other TRADE_MARKET_ENABLED consumer (repo-verified: PortScreen.tsx + ShipScreen.tsx
--   are the only two mount sites; tradeApi.ts / MarketPanel.tsx / ShipSwitcher.tsx reference the
--   constant in comments only). The wallet + per-ship cargo reads the panel makes are OWNER-READ
--   table reads (player_wallet; ship_cargo_lots ⋈ trade_goods — tradeApi.getWalletBalance /
--   getShipCargoLots), not RPCs; displayed prices ride get_market_offers, composed through
--   trade_effective_price so display == charged/paid. (Server flags first, client second — the
--   server rejects are the authority; a lagging client gate is safe, the reverse is not.)
--
-- ── WHAT IT DELIBERATELY DOES NOT TOUCH ──────────────────────────────────────────────────────────
--   • The relief knobs (relief_credits / relief_cooldown_seconds / relief_max_lifetime_claims) and
--     starting_credits — asserted sane, NEVER rewritten (retunes are a deliberate separate
--     set_game_config write, no deploy).
--   • main_ship_price — already 250 on prod runtime (the team activation's stage-1 knob); asserted
--     present, NEVER rewritten here.
--   • market_offers rows — Reference/Config, migration-seeded ONLY (0085/0173); a flip script never
--     writes prices.
--   • Every other window's key: exploration_enabled / mining_enabled (their own scripts),
--     team_command_enabled + the team-launch knobs (LIVE since 2026-07-12), the captain keys (their
--     own window), station_storage_enabled (rung 4), ranking / investment / world-balance / phase20
--     flags (later rungs). Any table other than game_config. Any DDL. Any migration.
--
-- ── INVOCATION (Management-API compatible: NO psql meta-commands; one BEGIN..COMMIT) ─────────────
--   psql "<prod session-pooler conn (pinned CA, sslmode=verify-full)>" -X -v ON_ERROR_STOP=1 \
--        -f scripts/activate-trade.sql
--   Or paste this whole file into the Supabase Dashboard SQL editor / run it through the
--   management-API runner (it contains no backslash commands to strip), or:
--     bash scripts/activate-trade.sh run ACTIVATE_TRADE      # DB_URL required
--   AFTER a green run: ship the one-line client PR above, then the manual smoke — dock at
--   Slagworks → MarketPanel shows the 6 offers → buy ore at 12 → sail to Haven → sell at 16
--   (+4/unit) → wallet moves by exactly the receipt totals; a re-click replays idempotent; and the
--   relief probe: a fresh throwaway account with 0 balance + 0 cargo claims relief once (+250),
--   a second immediate claim rejects relief_cooldown_active.
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
--   See the marked ROLLBACK section at the BOTTOM (commented out). Flag-only and fully reversible
--   (plan §B rung 3): wallets, cargo lots, trade_receipts and trade_relief_claims all PERSIST
--   harmlessly inert — every trade/relief RPC reject-before-reads on its flag, so the rows are
--   unreachable while dark and correct again on re-light. While LIT, the anti-pump CHECK
--   (sell_price >= buy_price) makes single-station buy-then-sell pumping structurally unprofitable
--   by construction (plan §B) — there is no economy reason to rush a rollback.

begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local idle_in_transaction_session_timeout = '60s';

-- ══════════ PRECONDITIONS (read-only; no write happens unless all pass) ══════════
do $$
declare
  c_haven constant uuid := 'b1a00001-0066-4a00-8a00-000000000001';
  c_slag  constant uuid := 'b1a00002-0066-4a00-8a00-000000000002';
  c_drift constant uuid := 'b1a00003-0066-4a00-8a00-000000000003';
  v_goods constant text[] := array['textiles','ore','provisions','reagents','machinery','luxury_goods'];
  v_head text; n int; v_missing text; v_src text; fn text;
  v_ore numeric; v_prov numeric; v_mach numeric;
  v_relief numeric; v_cap numeric; v_cool numeric; v_start numeric; v_price numeric;
begin
  -- the seed migration is deployed AND recorded (head alone is not enough: 0171/0172 are lower numbers).
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  if v_head is null or v_head < '20260618000173' then
    raise exception 'PRECONDITION FAIL: migration head % < 20260618000173 (ECON-SEED-1, the multiport offers seed) — deploy it first', coalesce(v_head, '(none)');
  end if;
  if not exists (select 1 from supabase_migrations.schema_migrations where version = '20260618000173') then
    raise exception 'PRECONDITION FAIL: migration 20260618000173 (ECON-SEED-1) is not recorded as deployed — the flip would light a one-port economy';
  end if;

  -- the seeded economy is really there: each starter port carries exactly 6 ACTIVE offers (18 rows).
  select count(*) into n from unnest(array[c_haven, c_slag, c_drift]) p
    where (select count(*) from public.market_offers o
             where o.location_id = p and o.good_id = any(v_goods) and o.active) <> 6;
  if n <> 0 then
    raise exception 'PRECONDITION FAIL: % starter port(s) do not carry exactly 6 active offers (the 0173 seed)', n;
  end if;

  -- anti-pump invariant recomputed over every seeded row (belt-and-braces beside the CHECK constraint).
  select count(*) into n from public.market_offers
    where location_id in (c_haven, c_slag, c_drift) and good_id = any(v_goods)
      and sell_price < buy_price;
  if n <> 0 then
    raise exception 'PRECONDITION FAIL: % seeded row(s) violate sell_price >= buy_price (anti-pump)', n;
  end if;

  -- the 3 flagship routes re-derived PROFITABLE from the live rows (dest.buy - origin.sell > 0):
  --   ore Slagworks -> Haven; provisions Haven -> Slagworks; machinery Slagworks -> Driftmarch.
  select h.buy_price - s.sell_price into v_ore
    from public.market_offers s, public.market_offers h
    where s.location_id = c_slag  and s.good_id = 'ore'        and s.active
      and h.location_id = c_haven and h.good_id = 'ore'        and h.active;
  select s.buy_price - h.sell_price into v_prov
    from public.market_offers h, public.market_offers s
    where h.location_id = c_haven and h.good_id = 'provisions' and h.active
      and s.location_id = c_slag  and s.good_id = 'provisions' and s.active;
  select d.buy_price - s.sell_price into v_mach
    from public.market_offers s, public.market_offers d
    where s.location_id = c_slag  and s.good_id = 'machinery'  and s.active
      and d.location_id = c_drift and d.good_id = 'machinery'  and d.active;
  if v_ore is null or v_ore <= 0 then
    raise exception 'PRECONDITION FAIL: ore route Slagworks->Haven not profitable (profit=%)', v_ore;
  end if;
  if v_prov is null or v_prov <= 0 then
    raise exception 'PRECONDITION FAIL: provisions route Haven->Slagworks not profitable (profit=%)', v_prov;
  end if;
  if v_mach is null or v_mach <= 0 then
    raise exception 'PRECONDITION FAIL: machinery route Slagworks->Driftmarch not profitable (profit=%)', v_mach;
  end if;

  -- the DEPLOYED trade RPC bodies are the 0138 re-creates (both prosrc pins per function, see header).
  foreach fn in array array[
    'public.get_market_offers(uuid)',
    'public.market_buy(uuid, text, numeric, uuid)',
    'public.market_sell(uuid, text, numeric, uuid)'] loop
    select prosrc into v_src from pg_proc where oid = to_regprocedure(fn)::oid;
    if v_src is null then
      raise exception 'PRECONDITION FAIL: trade RPC % does not exist', fn;
    end if;
    if position('public.mainship_resolve_docked_location(v_ship)' in v_src) = 0 then
      raise exception 'PRECONDITION FAIL: the deployed % body is not the 0138 one — the shared docked-resolve helper call is missing (the 0136 stale-body regression would be live); deploy 0138', fn;
    end if;
    if position('trade_effective_price(' in v_src) = 0 then
      raise exception 'PRECONDITION FAIL: the deployed % body lacks the P19 trade_effective_price composition (a pre-0136 body is live); deploy 0136+0138', fn;
    end if;
  end loop;

  -- the two keys this script writes + every read-only knob it depends on must already exist.
  select string_agg(sk, ', ') into v_missing
    from unnest(array['trade_market_enabled','trade_relief_enabled',
                      'relief_credits','relief_cooldown_seconds','relief_max_lifetime_claims',
                      'main_ship_price','starting_credits']) sk
   where not exists (select 1 from public.game_config g where g.key = sk);
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: game_config key(s) missing: %', v_missing;
  end if;

  -- relief-knob sanity, READ-ONLY (0094 seeds 250 / 86400 / 3; this script never retunes them).
  v_start  := public.cfg_num('starting_credits');
  v_relief := public.cfg_num('relief_credits');
  v_cap    := public.cfg_num('relief_max_lifetime_claims');
  v_cool   := public.cfg_num('relief_cooldown_seconds');
  v_price  := public.cfg_num('main_ship_price');
  if v_start is null or v_start <= 0 then
    raise exception 'PRECONDITION FAIL: starting_credits % is not sane (want > 0; 0093 seeds 1000)', v_start;
  end if;
  if v_relief is null or v_relief <= 0 or v_relief > v_start then
    raise exception 'PRECONDITION FAIL: relief_credits % is not sane (want 0 < x <= starting_credits %; 0094 seeds 250) — relief must never out-pay the wallet seed', v_relief, v_start;
  end if;
  if v_cap is null or v_cap < 1 or v_cap > 10 then
    raise exception 'PRECONDITION FAIL: relief_max_lifetime_claims % is not sane (want 1..10; 0094 seeds 3)', v_cap;
  end if;
  if v_cool is null or v_cool < 3600 then
    raise exception 'PRECONDITION FAIL: relief_cooldown_seconds % is not sane (want >= 3600; 0094 seeds 86400)', v_cool;
  end if;
  if v_price is null or v_price <= 0 then
    raise exception 'PRECONDITION FAIL: main_ship_price % is not sane (want > 0; 250 on prod runtime since the team activation)', v_price;
  end if;

  raise notice 'ACTIVATE_TRADE_PASS_PRECONDITIONS ok: head %, 0173 recorded, 3 ports x 6 active offers, anti-pump holds, routes recomputed profitable (ore +%, provisions +%, machinery +%), 0138 bodies prosrc-pinned, relief knobs sane (credits % / cooldown %s / cap % — untouched), starting_credits %, main_ship_price % left untouched', v_head, v_ore, v_prov, v_mach, v_relief, v_cool, v_cap, v_start, v_price;
end $$;

-- ══════════ STAGE 1 — the switch (plan §B rung 3: market + relief light TOGETHER; the ONLY writes) ══════════
do $$
declare v_before text;
begin
  select value::text into v_before from public.game_config where key = 'trade_market_enabled';
  perform public.set_game_config('trade_market_enabled', 'true'::jsonb);
  raise notice 'stage 1: trade_market_enabled % -> true', v_before;

  select value::text into v_before from public.game_config where key = 'trade_relief_enabled';
  perform public.set_game_config('trade_relief_enabled', 'true'::jsonb);
  raise notice 'stage 1: trade_relief_enabled % -> true', v_before;

  raise notice 'ACTIVATE_TRADE_PASS_STAGE1 ok: trade_market_enabled=true, trade_relief_enabled=true (the no-softlock backstop lights with the market)';
end $$;

-- ══════════ STAGE 2 — smoke asserts (read-only) ══════════
do $$
declare
  n int; n2 int; sk text; sv text; fn text;
begin
  -- (a) the committed flag values are exactly the activation state (raw + through the reader).
  for sk, sv in select * from (values
      ('trade_market_enabled', 'true'),
      ('trade_relief_enabled', 'true')) t(cfg_key, want) loop
    if (select value #>> '{}' from public.game_config where key = sk) is distinct from sv then
      raise exception 'SMOKE FAIL: % is % (want %)', sk, (select value #>> '{}' from public.game_config where key = sk), sv;
    end if;
  end loop;
  if not public.cfg_bool('trade_market_enabled') then
    raise exception 'SMOKE FAIL: cfg_bool(trade_market_enabled) still false'; end if;
  if not public.cfg_bool('trade_relief_enabled') then
    raise exception 'SMOKE FAIL: cfg_bool(trade_relief_enabled) still false'; end if;

  -- (b) the whole trade function surface exists: the 4 client RPCs (get_market_offers also carries the
  --     displayed prices, composed via trade_effective_price) + the 8 internal leaves the orchestrators
  --     fan out to. Existence, not execution — the behavior proofs are the four trade proofs in
  --     .github/workflows/trade-v1-proof.yml, run against a disposable chain. (The wallet + per-ship
  --     cargo READS the client makes are owner-read table reads — player_wallet, ship_cargo_lots — not
  --     RPCs; see (d) for the table sanity select.)
  foreach fn in array array[
    'public.get_market_offers(uuid)',
    'public.market_buy(uuid, text, numeric, uuid)',
    'public.market_sell(uuid, text, numeric, uuid)',
    'public.market_claim_relief(uuid)',
    'public.mainship_resolve_owned_ship(uuid, uuid)',
    'public.mainship_resolve_docked_location(uuid)',
    'public.trade_effective_price(numeric, uuid)',
    'public.trade_cargo_add_lot(uuid, text, numeric, numeric, uuid)',
    'public.trade_cargo_consume(uuid, text, numeric)',
    'public.wallet_ensure(uuid)',
    'public.wallet_debit(uuid, numeric)',
    'public.wallet_credit(uuid, numeric)'] loop
    if to_regprocedure(fn) is null then
      raise exception 'SMOKE FAIL: function % does not exist', fn; end if;
  end loop;

  -- (c) content sanity: EXACTLY 18 active offers across EXACTLY 3 ports, and the anti-pump CHECK
  --     constraint physically exists on market_offers (matched by definition text — 0085 left it
  --     unnamed, so the auto-generated name is not load-bearing).
  select count(*), count(distinct location_id) into n, n2 from public.market_offers where active;
  if n <> 18 or n2 <> 3 then
    raise exception 'SMOKE FAIL: % active offers across % ports (want exactly 18 across exactly 3)', n, n2;
  end if;
  select count(*) into n from pg_constraint c
    where c.conrelid = 'public.market_offers'::regclass and c.contype = 'c'
      and pg_get_constraintdef(c.oid) like '%sell_price >= buy_price%';
  if n < 1 then
    raise exception 'SMOKE FAIL: the anti-pump CHECK constraint (sell_price >= buy_price) is missing on market_offers';
  end if;

  -- (d) one cheap sanity select (exists + selectable; count is FYI — likely 0 at flip time).
  select count(*) into n from public.ship_cargo_lots;
  raise notice 'smoke: ship_cargo_lots rows = % (likely 0 at flip time)', n;

  raise notice 'ACTIVATE_TRADE_PASS_SMOKE ok: both flags committed true, 12 functions present, 18 active offers across 3 ports, anti-pump constraint live, cargo table selectable';
end $$;

select 'TRADE ACTIVATION PASS — trade market + relief floor LIVE server-side (offers/buy/sell + no-softlock relief). THE REMAINING STEP: the one-line client PR flipping TRADE_MARKET_ENABLED in src/features/map/osnReleaseGates.ts, which mounts MarketPanel on the Port screen (PortScreen.tsx:61 — the only newly visible surface) and completes the ShipSwitcher OR-gate (ShipScreen.tsx:62 — the switcher is ALREADY mounted via MAINSHIP_ADDITIONAL_ENABLED=true since the 2026-07-12 team launch, so it shows no new change). Then the manual smoke: dock Slagworks -> buy ore 12 -> sail Haven -> sell 16; relief probe on a fresh 0-balance/0-cargo account.' as result;

commit;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- To dark the trade surfaces again, run the reverse writes below (uncomment, run once). Notes:
--   • FLAG-ONLY and fully reversible (plan §B rung 3): player_wallet balances, ship_cargo_lots,
--     trade_receipts and trade_relief_claims all PERSIST harmlessly INERT — every trade/relief RPC
--     reject-before-reads on its flag (trade_market_disabled / trade_relief_disabled), the client
--     panel is compile-gated anyway, and the rows become live again exactly as-is on a re-flip.
--   • While the market IS lit, the market_offers CHECK (sell_price >= buy_price) makes single-station
--     buy-then-sell pumping structurally unprofitable by construction (plan §B) — rollback is a
--     product decision, not an exploit response.
--   • The relief knobs, starting_credits and main_ship_price were never touched by this script;
--     nothing to revert there. Roll back the two flags TOGETHER (a lit market with dark relief
--     reopens the softlock the relief floor exists to close).
--   • If the client PR already merged, also revert TRADE_MARKET_ENABLED to `false as const` in a
--     follow-up PR (safe in either order — the server rejects are the authority).
--
-- begin;
-- select public.set_game_config('trade_market_enabled', 'false'::jsonb);
-- select public.set_game_config('trade_relief_enabled', 'false'::jsonb);
-- select key, value from public.game_config
--  where key in ('trade_market_enabled','trade_relief_enabled') order by key;
-- commit;
