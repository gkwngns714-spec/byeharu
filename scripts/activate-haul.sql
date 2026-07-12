-- HAUL ACTIVATION — the contracts flip (docs/FULL_CAPACITY_PLAN.md §C P2 "HAUL"; queue #12's
-- ACT-HAUL closer; ROADMAP phase-22. The contracts stack is FULLY BUILT DARK: 0176 templates +
-- schema + flag + the deterministic hourly generator ('7 * * * *', jobname 'haul-generate-offers'),
-- 0179 accept/deliver RPCs + haul_receipts + deliver_by + the per-player cap, 0181 the
-- get_port_contracts bulletin read RPC + the server-lit HaulBoardPanel — merged PR #117).
--
-- ██ HUMAN ACTIVATION TOOL ██ — run BY THE HUMAN, deliberately, against prod. NOT CI; nothing
-- flips at build/deploy time. Each run of this file IS the recorded human go decision.
--
-- ── WHAT IT DOES (one transaction; COMMIT only if every assert passes) ───────────────────────────
--   PRECONDITIONS (no write until these hold):
--     • migration head >= 20260618000181 AND every haul migration (0176, 0179, 0181) is actually
--       recorded in supabase_migrations.schema_migrations;
--     • the haul tables + the market/cargo substrate exist (haul_contract_templates /
--       haul_contracts / haul_receipts / market_offers / ship_cargo_lots);
--     • the whole haul function surface exists via to_regprocedure — the REAL signatures — and the
--       DEPLOYED bodies are the CURRENT heads, prosrc-pinned: the generator must carry the 0179
--       (a2) deadline-cancel hunk (deliver_by <= now() → 'cancelled' — the stale 0176 body has
--       neither token) on top of the 0176 pins (offered-only expiry, hashtextextended determinism,
--       natural-key on-conflict mint); accept must carry the gate + cap + the per-player advisory
--       serialization + already_accepted_other; deliver must fan out through trade_cargo_consume +
--       wallet_credit and carry deadline_passed + idempotent_replay; the 0181 read RPC must carry
--       the gate + the fresh-offered predicate + the caller-scoped mine read;
--     • templates seeded: EXACTLY the 10 active 0176 templates, and WORTH TAKING recomputed from
--       the LIVE market rows at BOTH qty endpoints (reward beats the same-haul self-trade AND is an
--       absolute profit over buying the haul at the origin — the 0176 §4 invariants, re-derived);
--     • the 3 starter ports are generator-eligible (active + active docking + an active market) —
--       stage 2's instant offers physically can appear at all 3;
--     • knobs exist + sane, READ-ONLY (never rewritten): haul_offers_per_port in 1..10 (0176 seeds
--       2; 0 would mint an empty board), haul_max_active_per_player >= 1 (0179 seeds 3; 0 is a
--       legal owner FREEZE value but flipping a board nobody can accept is a dead affordance —
--       retune to 0 deliberately AFTER the flip if that is really wanted);
--     • the cron is scheduled EXACTLY ONCE (jobname 'haul-generate-offers', command invoking
--       haul_generate_offers) — 0176 owns the schedule; this script never touches it;
--     • the 'haul_contracts_enabled' key exists (0176 seeds 'false'; a typo can never invent a
--       key). Its VALUE is not asserted false — a RE-RUN after success is a supported no-op;
--     • ██ THE TRADE PRECONDITION (the deliverability dependency — DECIDED: hard gate, not a
--       warning): trade_market_enabled must be COMMITTED true (raw value + cfg_bool). WHY:
--       accepting is trade-independent (a claim moves no cargo/credits — 0179 §1), but DELIVERING
--       consumes the goods from ship_cargo_lots via trade_cargo_consume, and the SOLE producer of
--       ship_cargo_lots is market_buy (grep-verified: trade_cargo_add_lot's only call sites are
--       market_buy and its re-creates — 0089/0092/0136/0138) — which server-rejects while
--       trade_market_enabled is false. THE MINING NOTE (checked, does NOT rescue this): mining
--       rewards land as ITEM-inventory rows ('ore'/'crystal' item_types via reward_grant — the
--       0102 decision (1)), NEVER a ship_cargo_lots row; the trade_goods 'ore' is a separate
--       catalog. So with trade dark there is NO sourcing path AT ALL — a lit board would be a 100%
--       dead affordance (every accept ends in the (a2) cancel at deliver_by). FLIP ORDER:
--       ACT-TRADE first, then this script.
--   STAGE 1 — the switch (the ONE flag write, via the owned set_game_config writer):
--     haul_contracts_enabled → true. ORDERED BEFORE THE GENERATOR INVOKE, DELIBERATELY: the
--     generator dark-gates on cfg_bool('haul_contracts_enabled') FIRST (0176/0179) and returns
--     {ok:false, code:'feature_disabled'} while false — it physically cannot mint dark. Both
--     stages live in the ONE transaction, so if the offer stage fails the flag write rolls back
--     too (all-or-nothing: the flag is never committed without a stocked board).
--   STAGE 2 — ██ INSTANT OFFERS ██ (decided: YES, invoke the generator in-stage): one
--     `perform`-style call of public.haul_generate_offers() — the SANCTIONED sole mint entrypoint
--     (this script never writes haul_contracts directly). WHY IN-STAGE: the cron's hourly cadence
--     ('7 * * * *') means the first lit firing lands up to ~1h after the flip — an empty bulletin
--     hour at every port for no reason. Invoked here (gate open in-txn: the same transaction sees
--     its own stage-1 write), offers exist at all 3 ports the very moment the flip commits.
--     Asserts: the jsonb envelope is {ok:true}; ports == 3 (the generator visited exactly the 3
--     eligible starter ports); offers minted > 0 — with the ONE tolerated exception: a SAME-DAY
--     RE-RUN mints 0 by the idempotency natural key, so 0 minted is accepted only if today's rows
--     already exist; and EVERY starter port carries >= 1 contract row for today (minted now or
--     earlier today — run-time-independent).
--   SMOKE (read-only): flag committed (raw + cfg_bool); the CLIENT read surface answers lit —
--     get_port_contracts(Haven Reach) called under a TRANSACTION-LOCAL fake JWT (the
--     set_config('request.jwt.claims', …, true) technique the 0179/0181 self-asserts and
--     haul-proof.sql use — the RPC needs auth.uid() and this script runs privileged; the random
--     sub owns nothing, so mine == [] and nothing is written; claims are cleared after and would
--     evaporate at COMMIT anyway), asserted {ok:true} with max_active mirroring the cap knob and
--     the offered array EQUAL to the direct fresh-offered count at that port (RPC == table truth);
--     per-port fresh bulletin counts (FYI notices); the cron still scheduled exactly once;
--     haul_receipts selectable (0 rows FYI); the ACL posture (generator service-role-only, the
--     three client RPCs authenticated-only, never anon).
--   Emits ACTIVATE_HAUL_PASS_* markers per stage and one final PASS line; any failed assert
--   RAISES → the whole transaction rolls back → NOTHING is applied (all-or-nothing activation).
--
-- RE-RUN SEMANTICS (decided, documented): safe no-op success. The flag write is a set_game_config
-- upsert to the same value; the generator is idempotent by the (origin, offer_day, slot) natural
-- key — a same-day re-run mints nothing (stage 2 tolerates 0 minted exactly when today's rows
-- already exist), and a later-day re-run mints the new day's board, which is precisely what the
-- hourly cron does anyway. No path double-mints.
--
-- ── NO CLIENT PR IS NEEDED (verified 2026-07-12, this slice) ─────────────────────────────────────
--   The bulletin surface is SERVER-LIT, not compile-gated — there is NO HAUL_* constant in
--   osnReleaseGates.ts and no haul compile gate anywhere in src (grep-verified):
--     • HaulBoardPanel is ALREADY MOUNTED on the Port screen aside rail — PortScreen.tsx:80, in the
--       docked branch next to StationHangar/InvestmentPanel — and renders null unless
--       isServerLit(board) (HaulBoardPanel.tsx:120), i.e. unless get_port_contracts answers
--       {ok:true}. The moment this script commits, the very read it makes answers lit and the
--       board appears.
--   WHAT PLAYERS SEE AT FLIP TIME: docked at any of the 3 starter ports (Haven Reach / Slagworks
--   Anchorage / Driftmarch Waypost), the Contracts bulletin appears on the Port screen aside with
--   ~2 fresh offers each (haul_offers_per_port = 2) — INSTANTLY, because stage 2 pre-stocked the
--   board. Accept while docked at the origin (a claim — source the goods via the market, the 0176
--   reward math prices the origin buy in); "Your contracts n/3" tracks the cap; deliver with ANY
--   owned ship docked at the destination before deliver_by; credits land on delivery via Wallet
--   with an idempotent receipt. The hourly minute-7 cron keeps the board rolling from here (new-day
--   mints; stale offers expire with <= 1h latency; blown deadlines cancel and free cap slots).
--
-- ── WHAT IT DELIBERATELY DOES NOT TOUCH ──────────────────────────────────────────────────────────
--   • haul_contract_templates / haul_contracts / haul_receipts rows — NEVER written directly;
--     offers are minted ONLY through haul_generate_offers (the sanctioned entrypoint; its writes
--     are its own). This script's only direct write is the ONE set_game_config upsert.
--   • The knobs (haul_offers_per_port / haul_max_active_per_player) — asserted sane, never
--     rewritten (a retune is a deliberate separate set_game_config write, no deploy).
--   • The cron schedule (0176 owns it). Every other window's key: trade_* (asserted lit, never
--     written) / exploration_enabled / mining_enabled / captain_* / team_command_enabled /
--     station_storage_enabled / salvage_market_enabled / ranking_enabled /
--     location_investment_enabled / world_balance_enabled / phase20_polish_enabled. Any table
--     other than game_config. Any DDL. Any migration.
--
-- ── INVOCATION (Management-API compatible: NO psql meta-commands; one BEGIN..COMMIT) ─────────────
--   psql "<prod session-pooler conn (pinned CA, sslmode=verify-full)>" -X -v ON_ERROR_STOP=1 \
--        -f scripts/activate-haul.sql
--   Or paste this whole file into the Supabase Dashboard SQL editor / run it through the
--   management-API runner (it contains no backslash commands to strip), or:
--     bash scripts/activate-haul.sh run ACTIVATE_HAUL      # DB_URL required
--   AFTER a green run: manual smoke — dock at Haven Reach → the Contracts bulletin shows ~2 offers
--   → Accept one → buy the goods at the origin market → sail to the destination → Deliver → the
--   wallet moves by exactly reward_credits and the contract leaves the board; a re-click replays
--   idempotent. The next minute-7 cron firing is a cheap no-op (today's slots exist).
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
--   See the marked ROLLBACK section at the BOTTOM (commented out). FLAG-ONLY: haul_contracts_enabled
--   → false. Every haul surface rejects gate-first again and HaulBoardPanel fails closed to null on
--   its next read — INSTANTLY, which is the 0181 rationale for the gated read RPC over a raw RLS
--   select. ██ THE EXPIRY FREEZE ██ (the 0176 forward note, extended by 0179): darkening freezes
--   BOTH generator passes — then-stale 'offered' rows persist un-expired and 'accepted' rows past
--   deliver_by stay un-cancelled, holding their cap slots. Running the generator once after
--   darkening does NOT sweep them — it gate-first no-ops while dark. Accept the frozen state
--   (recommended) or manually expire — both options reasoned at the bottom.

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local idle_in_transaction_session_timeout = '60s';

-- ══════════ PRECONDITIONS (read-only; no write happens unless all pass) ══════════
do $$
declare
  c_haven constant uuid := 'b1a00001-0066-4a00-8a00-000000000001';
  c_slag  constant uuid := 'b1a00002-0066-4a00-8a00-000000000002';
  c_drift constant uuid := 'b1a00003-0066-4a00-8a00-000000000003';
  v_head text; v_missing text; n int; fn text; v_src text;
  v_per_port numeric; v_cap numeric;
begin
  -- every haul migration deployed AND recorded (head alone is not enough).
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  if v_head is null or v_head < '20260618000181' then
    raise exception 'PRECONDITION FAIL: migration head % < 20260618000181 (the haul read surface) — deploy the contracts stack first', coalesce(v_head, '(none)');
  end if;
  select string_agg(mv, ', ') into v_missing
    from unnest(array['20260618000176','20260618000179','20260618000181']) mv
   where not exists (select 1 from supabase_migrations.schema_migrations s where s.version = mv);
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: haul migration(s) not recorded as deployed: %', v_missing;
  end if;

  -- the haul tables + the market/cargo substrate the deliver path stands on.
  select string_agg(t, ', ') into v_missing
    from unnest(array['public.haul_contract_templates','public.haul_contracts',
                      'public.haul_receipts','public.market_offers','public.ship_cargo_lots']) t
   where to_regclass(t) is null;
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: table(s) missing: %', v_missing;
  end if;

  -- the whole haul function surface exists — the REAL signatures, plus the charter leaves the
  -- deliver path fans out to, plus market_buy (the SOLE ship_cargo_lots producer — the sourcing
  -- faucet the trade precondition below guards), plus the config leaves this script relies on.
  foreach fn in array array[
    'public.haul_generate_offers()',
    'public.haul_accept_contract(uuid, uuid, uuid)',
    'public.haul_deliver_contract(uuid, uuid, uuid)',
    'public.get_port_contracts(uuid)',
    'public.trade_cargo_consume(uuid, text, numeric)',
    'public.wallet_credit(uuid, numeric)',
    'public.mainship_resolve_owned_ship(uuid, uuid)',
    'public.mainship_resolve_docked_location(uuid)',
    'public.market_buy(uuid, text, numeric, uuid)',
    'public.cfg_bool(text)',
    'public.cfg_num(text)',
    'public.set_game_config(text, jsonb)'] loop
    if to_regprocedure(fn) is null then
      raise exception 'PRECONDITION FAIL: function % does not exist', fn;
    end if;
  end loop;

  -- the DEPLOYED generator body is the 0179 re-create (the (a2) deadline-cancel hunk — the stale
  -- 0176 body carries neither token) on top of the 0176 pins (offered-only expiry, pure-hash
  -- determinism, natural-key idempotent mint).
  select prosrc into v_src from pg_proc
   where oid = to_regprocedure('public.haul_generate_offers()')::oid;
  if position('deliver_by <= now()' in v_src) = 0 or position('''cancelled''' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed haul_generate_offers body lacks the 0179 (a2) deadline-cancel pass — the stale 0176 body is live; deploy 0179';
  end if;
  if position('status = ''offered''' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed generator body lacks the offered-only expiry predicate (0176)';
  end if;
  if position('hashtextextended' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed generator body lacks the pure-hash determinism (0176)';
  end if;
  if position('on conflict (origin_location_id, offer_day, slot) do nothing' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed generator body lacks the natural-key idempotent mint (0176) — a double-fire could double-mint';
  end if;

  -- the DEPLOYED accept body: gate + cap + the per-player advisory serialization (the 0179 review
  -- fix — a multi-ship count-then-insert race could exceed the cap without it) + the foreign-holder
  -- reject.
  select prosrc into v_src from pg_proc
   where oid = to_regprocedure('public.haul_accept_contract(uuid, uuid, uuid)')::oid;
  if position('haul_contracts_disabled' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed haul_accept_contract body lacks the dark gate reject (0179)';
  end if;
  if position('too_many_active' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed haul_accept_contract body lacks the active-cap reject (0179 §8)';
  end if;
  if position('hashtext(''haul_accept'')' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed haul_accept_contract body lacks the per-player advisory serialization (the 0179 cap-race fix)';
  end if;
  if position('already_accepted_other' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed haul_accept_contract body lacks the foreign-holder reject (0179)';
  end if;

  -- the DEPLOYED deliver body: the charter fan-out (cargo ONLY through Trade-Cargo, credits ONLY
  -- through Wallet) + the reject-only deadline + the replay-before-guards idempotency.
  select prosrc into v_src from pg_proc
   where oid = to_regprocedure('public.haul_deliver_contract(uuid, uuid, uuid)')::oid;
  if position('trade_cargo_consume' in v_src) = 0 or position('wallet_credit' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed haul_deliver_contract body does not fan out through trade_cargo_consume + wallet_credit (the charter guard, 0179)';
  end if;
  if position('deadline_passed' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed haul_deliver_contract body lacks the deadline_passed reject (0179 §6)';
  end if;
  if position('idempotent_replay' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed haul_deliver_contract body lacks the idempotent replay (0179)';
  end if;

  -- the DEPLOYED 0181 read RPC body: gate-first + the fail-closed fresh-offered predicate + the
  -- caller-scoped mine read (the bulletin's load-bearing clauses).
  select prosrc into v_src from pg_proc
   where oid = to_regprocedure('public.get_port_contracts(uuid)')::oid;
  if position('haul_contracts_disabled' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed get_port_contracts body lacks the dark gate reject (0181)';
  end if;
  if position('expires_at > now()' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed get_port_contracts body lacks the fresh-offered predicate (0181) — the board could list rows accept bounces';
  end if;
  if position('accepted_by = v_player' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed get_port_contracts mine read is not caller-scoped (0181)';
  end if;

  -- templates: EXACTLY the 10 active 0176 rows, and WORTH TAKING recomputed from the LIVE market
  -- rows at BOTH qty endpoints (the 0176 §4 invariants, re-derived at flip time): reward(q) must
  -- (a) beat the same-haul self-trade sale (> q x dest.buy) and (b) be an absolute profit after
  -- buying the haul at the origin (> q x origin.sell — covers the Drift backhauls).
  select count(*) into n from public.haul_contract_templates where active;
  if n <> 10 then
    raise exception 'PRECONDITION FAIL: % active haul templates (want exactly the 10 seeded by 0176)', n;
  end if;
  select count(*) into n
    from public.haul_contract_templates t
    join public.market_offers oo on oo.location_id = t.origin_location_id and oo.good_id = t.good_id and oo.active
    join public.market_offers od on od.location_id = t.dest_location_id   and od.good_id = t.good_id and od.active
    cross join lateral (values (t.qty_min), (t.qty_max)) q(qty)
   where t.active;
  if n <> 20 then
    raise exception 'PRECONDITION FAIL: expected 20 (template x endpoint) live-market joins, got % (a template route lost its market row)', n;
  end if;
  select count(*) into n
    from public.haul_contract_templates t
    join public.market_offers oo on oo.location_id = t.origin_location_id and oo.good_id = t.good_id and oo.active
    join public.market_offers od on od.location_id = t.dest_location_id   and od.good_id = t.good_id and od.active
    cross join lateral (values (t.qty_min), (t.qty_max)) q(qty)
   where t.active
     and not ( round(t.reward_base + q.qty * (od.buy_price + t.reward_premium_per_unit)) > q.qty * od.buy_price
           and round(t.reward_base + q.qty * (od.buy_price + t.reward_premium_per_unit)) > q.qty * oo.sell_price );
  if n <> 0 then
    raise exception 'PRECONDITION FAIL: % (template x endpoint) reward(s) no longer worth taking vs the live market (the 0176 invariants) — retune before flipping', n;
  end if;

  -- the 3 starter ports are generator-eligible (the generator''s own port filter, re-derived):
  -- stage 2''s instant offers physically can appear at all 3.
  select count(*) into n from unnest(array[c_haven, c_slag, c_drift]) p
   where not exists (
     select 1 from public.locations l
      where l.id = p and l.status = 'active'
        and exists (select 1 from public.location_services s
                      where s.location_id = l.id and s.service = 'docking' and s.status = 'active')
        and exists (select 1 from public.market_offers o
                      where o.location_id = l.id and o.active));
  if n <> 0 then
    raise exception 'PRECONDITION FAIL: % starter port(s) are not generator-eligible (active + docking + market) — the instant-offer stage would skip them', n;
  end if;

  -- knobs sane, READ-ONLY (never rewritten here). haul_max_active_per_player = 0 is a legal owner
  -- FREEZE value (0179 §8) but flipping a board nobody can accept is a dead affordance — retune to
  -- 0 deliberately AFTER the flip if a freeze is really wanted.
  v_per_port := public.cfg_num('haul_offers_per_port');
  if v_per_port is null or v_per_port < 1 or v_per_port > 10 then
    raise exception 'PRECONDITION FAIL: haul_offers_per_port % is not sane (want 1..10; 0176 seeds 2 — 0 would mint an empty board)', v_per_port;
  end if;
  v_cap := public.cfg_num('haul_max_active_per_player');
  if v_cap is null or v_cap < 1 then
    raise exception 'PRECONDITION FAIL: haul_max_active_per_player % is not sane for a flip (want >= 1; 0179 seeds 3 — 0 is a deliberate post-flip freeze, not a launch state)', v_cap;
  end if;

  -- the cron scheduled EXACTLY once (0176), invoking the generator. This script never touches it.
  select count(*) into n from cron.job where jobname = 'haul-generate-offers';
  if n <> 1 then
    raise exception 'PRECONDITION FAIL: cron job haul-generate-offers scheduled % time(s) (want exactly 1 — 0176)', n;
  end if;
  select count(*) into n from cron.job
   where jobname = 'haul-generate-offers' and command like '%haul_generate_offers%';
  if n <> 1 then
    raise exception 'PRECONDITION FAIL: the haul-generate-offers cron command does not invoke haul_generate_offers';
  end if;

  -- the ONE key this script writes must already exist (refuse to invent config rows via a typo).
  -- Its VALUE is deliberately NOT asserted false: a re-run after success is a supported no-op.
  if not exists (select 1 from public.game_config where key = 'haul_contracts_enabled') then
    raise exception 'PRECONDITION FAIL: game_config key haul_contracts_enabled missing (0176 seeds it false)';
  end if;

  -- ██ THE TRADE PRECONDITION ██ (deliverability — see the header block): trade must be COMMITTED
  -- lit. Accept works dark-trade, but deliver consumes ship_cargo_lots via trade_cargo_consume and
  -- market_buy is the ONLY producer of cargo lots (grep-verified: trade_cargo_add_lot call sites =
  -- market_buy and its re-creates, 0089/0092/0136/0138) — and market_buy server-rejects while
  -- trade_market_enabled is false. Mining does NOT substitute: its 'ore' is an ITEM-inventory
  -- reward_grant (0102 decision (1)), never a cargo lot. With trade dark there is NO sourcing path
  -- at all — every accepted contract would end in the (a2) cancel.
  if (select value #>> '{}' from public.game_config where key = 'trade_market_enabled') is distinct from 'true'
     or not public.cfg_bool('trade_market_enabled') then
    raise exception 'PRECONDITION FAIL: trade_market_enabled is not committed true — run ACT-TRADE (scripts/activate-trade.sql) FIRST. Contracts are acceptable dark-trade but 100%% UNDELIVERABLE: haul_deliver_contract consumes ship_cargo_lots and market_buy (trade-gated) is the sole cargo-lot producer; mining is NOT an alternative (its ore is an inventory ITEM via reward_grant, never a cargo lot)';
  end if;

  -- ACL posture (read-only checks): the generator stays service-role-only; the three client RPCs
  -- are authenticated-only, never anon.
  if has_function_privilege('authenticated', 'public.haul_generate_offers()', 'execute')
     or has_function_privilege('anon', 'public.haul_generate_offers()', 'execute')
     or not has_function_privilege('service_role', 'public.haul_generate_offers()', 'execute') then
    raise exception 'PRECONDITION FAIL: haul_generate_offers ACL drifted (want service-role-only)';
  end if;
  if not has_function_privilege('authenticated', 'public.haul_accept_contract(uuid,uuid,uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.haul_deliver_contract(uuid,uuid,uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.get_port_contracts(uuid)', 'execute')
     or has_function_privilege('anon', 'public.haul_accept_contract(uuid,uuid,uuid)', 'execute')
     or has_function_privilege('anon', 'public.haul_deliver_contract(uuid,uuid,uuid)', 'execute')
     or has_function_privilege('anon', 'public.get_port_contracts(uuid)', 'execute') then
    raise exception 'PRECONDITION FAIL: a haul client RPC ACL drifted (want authenticated-only, never anon)';
  end if;

  raise notice 'ACTIVATE_HAUL_PASS_PRECONDITIONS ok: head %, 3 haul migrations recorded, 5 tables, 12 functions present (real signatures), generator/accept/deliver/read bodies prosrc-pinned to their 0179/0181 heads, 10 templates worth-taking re-derived at both endpoints vs the live market, 3 starter ports generator-eligible, knobs sane (per-port %, cap % — untouched), cron scheduled exactly once, haul_contracts_enabled key present, trade_market_enabled committed true (the deliverability gate), ACLs intact', v_head, v_per_port, v_cap;
end $$;

-- ══════════ STAGE 1 — the switch (the ONE flag write; BEFORE the generator invoke: the generator
--            dark-gates on this flag and returns feature_disabled while false — it physically
--            cannot mint dark; the same txn sees this write, so stage 2 runs lit) ══════════
do $$
declare v_before text;
begin
  select value::text into v_before from public.game_config where key = 'haul_contracts_enabled';
  perform public.set_game_config('haul_contracts_enabled', 'true'::jsonb);
  raise notice 'stage 1: haul_contracts_enabled % -> true', v_before;

  raise notice 'ACTIVATE_HAUL_PASS_STAGE1 ok: haul_contracts_enabled=true (uncommitted until the offer stage passes — one all-or-nothing txn)';
end $$;

-- ══════════ STAGE 2 — ██ INSTANT OFFERS ██ (the sanctioned generator invoked ONCE in-stage: the
--            hourly cron would otherwise leave the bulletin empty for up to ~1h after the flip;
--            invoked here, offers exist at all 3 ports the moment the flip commits) ══════════
do $$
declare
  c_haven constant uuid := 'b1a00001-0066-4a00-8a00-000000000001';
  c_slag  constant uuid := 'b1a00002-0066-4a00-8a00-000000000002';
  c_drift constant uuid := 'b1a00003-0066-4a00-8a00-000000000003';
  v_res     jsonb;
  v_day     date := (now() at time zone 'utc')::date;  -- the generator's own day anchor (GUC-stable)
  v_created int;
  n         int;
begin
  v_res := public.haul_generate_offers();
  if coalesce(v_res ->> 'ok', 'false') <> 'true' then
    raise exception 'STAGE2 FAIL: haul_generate_offers rejected (the gate should be open in-txn): %', v_res;
  end if;
  if coalesce((v_res ->> 'ports')::int, -1) <> 3 then
    raise exception 'STAGE2 FAIL: the generator visited % port(s), want exactly the 3 eligible starter ports: %', v_res ->> 'ports', v_res;
  end if;
  v_created := coalesce((v_res ->> 'offers_created')::int, 0);
  raise notice 'stage 2: generator envelope % (minted %, expired %, cancelled %)',
    v_res ->> 'day', v_created, v_res ->> 'offers_expired', v_res ->> 'accepted_cancelled';

  -- minted > 0, with the ONE tolerated exception — a SAME-DAY RE-RUN mints 0 by the idempotency
  -- natural key; 0 is accepted only if today's rows already exist (anything else = a broken mint).
  if v_created = 0 then
    select count(*) into n from public.haul_contracts where offer_day = v_day;
    if n = 0 then
      raise exception 'STAGE2 FAIL: the generator minted nothing and no rows exist for today (%) — template pools or market rows are broken despite the preconditions', v_day;
    end if;
    raise notice 'stage 2: 0 minted but % row(s) already exist for today — same-day re-run no-op (supported)', n;
  end if;

  -- EVERY starter port carries >= 1 contract row for today (minted now or earlier today) — the
  -- run-time-independent form of "the board is stocked at all 3 ports".
  select count(*) into n from unnest(array[c_haven, c_slag, c_drift]) p
   where not exists (select 1 from public.haul_contracts c
                       where c.origin_location_id = p and c.offer_day = v_day);
  if n <> 0 then
    raise exception 'STAGE2 FAIL: % starter port(s) carry no contract row for today (%) — the bulletin would open empty there', n, v_day;
  end if;

  raise notice 'ACTIVATE_HAUL_PASS_STAGE2 ok: generator envelope ok across exactly 3 ports; today''s slots present at all 3 starter ports (instant offers)';
end $$;

-- ══════════ SMOKE — read-only ══════════
do $$
declare
  c_haven constant uuid := 'b1a00001-0066-4a00-8a00-000000000001';
  c_slag  constant uuid := 'b1a00002-0066-4a00-8a00-000000000002';
  c_drift constant uuid := 'b1a00003-0066-4a00-8a00-000000000003';
  v_res   jsonb;
  n       int;
  n_haven int; n_slag int; n_drift int;
begin
  -- (a) the committed flag value is exactly the activation state (raw + through the reader).
  if (select value #>> '{}' from public.game_config where key = 'haul_contracts_enabled') is distinct from 'true' then
    raise exception 'SMOKE FAIL: haul_contracts_enabled is % (want true)',
      (select value #>> '{}' from public.game_config where key = 'haul_contracts_enabled');
  end if;
  if not public.cfg_bool('haul_contracts_enabled') then
    raise exception 'SMOKE FAIL: cfg_bool(haul_contracts_enabled) still false'; end if;

  -- (b) per-port FRESH bulletin counts (status='offered' AND unexpired — the exact predicate the
  --     0181 read serves). FYI notices: on a first run all 3 show ~2; a same-day re-run hours
  --     later may honestly show fewer (short offers expire — the board's designed tempo).
  select count(*) into n_haven from public.haul_contracts
   where origin_location_id = c_haven and status = 'offered' and expires_at > now();
  select count(*) into n_slag from public.haul_contracts
   where origin_location_id = c_slag and status = 'offered' and expires_at > now();
  select count(*) into n_drift from public.haul_contracts
   where origin_location_id = c_drift and status = 'offered' and expires_at > now();
  raise notice 'smoke: fresh offered — Haven Reach %, Slagworks Anchorage %, Driftmarch Waypost %',
    n_haven, n_slag, n_drift;

  -- (c) the CLIENT read surface answers lit — get_port_contracts is the exact RPC HaulBoardPanel
  --     rides (isServerLit keys off its ok:true). It needs auth.uid() and this script runs
  --     privileged, so call it under a TRANSACTION-LOCAL fake JWT — the set_config technique the
  --     0179/0181 self-asserts and haul-proof.sql use. The random sub owns nothing: mine must be
  --     [] and nothing is written (the RPC is read-only STABLE). Claims cleared after (and the
  --     txn-local setting would evaporate at COMMIT regardless).
  perform set_config('request.jwt.claims',
    json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
  v_res := public.get_port_contracts(c_haven);
  if coalesce(v_res ->> 'ok', 'false') <> 'true' then
    raise exception 'SMOKE FAIL: get_port_contracts(Haven Reach) not lit: %', v_res;
  end if;
  if coalesce((v_res ->> 'max_active')::int, -1) <> public.cfg_num('haul_max_active_per_player')::int then
    raise exception 'SMOKE FAIL: get_port_contracts max_active % does not mirror the cap knob %',
      v_res ->> 'max_active', public.cfg_num('haul_max_active_per_player');
  end if;
  if coalesce(jsonb_array_length(v_res -> 'offered'), -1) <> n_haven then
    raise exception 'SMOKE FAIL: get_port_contracts offered length % != the direct fresh-offered count % at Haven Reach (RPC and table disagree)',
      coalesce(jsonb_array_length(v_res -> 'offered'), -1), n_haven;
  end if;
  if coalesce(jsonb_array_length(v_res -> 'mine'), -1) <> 0 then
    raise exception 'SMOKE FAIL: a fresh random subject sees % ''mine'' contract(s) (want 0 — the mine read leaked)',
      jsonb_array_length(v_res -> 'mine');
  end if;
  perform set_config('request.jwt.claims', '', true);
  raise notice 'smoke: get_port_contracts(Haven Reach) lit — offered % (== table truth), mine 0, max_active mirrored', n_haven;

  -- (d) the cron still scheduled exactly once (this script never touches it).
  select count(*) into n from cron.job where jobname = 'haul-generate-offers';
  if n <> 1 then
    raise exception 'SMOKE FAIL: cron job haul-generate-offers scheduled % time(s) after the flip (want 1)', n; end if;

  -- (e) the receipts table is selectable (count FYI — 0 at flip time; it fills as players accept
  --     and deliver).
  select count(*) into n from public.haul_receipts;
  raise notice 'smoke: haul_receipts rows = % (0 expected at flip time)', n;

  raise notice 'ACTIVATE_HAUL_PASS_SMOKE ok: flag committed true, bulletin read RPC answers lit under a fake JWT and matches the table truth, mine leak-free, max_active mirrored, cron intact, receipts selectable';
end $$;

select 'HAUL ACTIVATION PASS — delivery contracts LIVE server-side WITH a pre-stocked board (stage 2 invoked the sanctioned generator in-txn: fresh offers exist at all 3 starter ports the moment this commits — no empty-bulletin hour waiting for the minute-7 cron, which now keeps the board rolling: new-day mints, <=1h expiry sweeps, deadline cancels). NO client PR is needed: HaulBoardPanel is already mounted server-lit on the Port screen aside rail (PortScreen.tsx:80; isServerLit gate HaulBoardPanel.tsx:120) and appears the moment get_port_contracts answers lit. Players see the Contracts bulletin docked at Haven Reach / Slagworks Anchorage / Driftmarch Waypost with ~2 offers each (haul_offers_per_port=2): Accept at the origin (a claim — buy the goods at the origin market; the 0176 reward math always covers the buy), track "Your contracts n/3", Deliver with ANY owned ship docked at the destination before deliver_by, credits land via Wallet with idempotent receipts.' as result;

commit;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- To dark the contracts surface again, run the reverse write below (uncomment, run once). Notes:
--   • FLAG-ONLY: haul_contracts_enabled → false. Every haul surface rejects gate-first again
--     (accept/deliver/read RPC → haul_contracts_disabled; the generator + its cron → instant
--     no-ops) and HaulBoardPanel fails closed to null on its next read — INSTANTLY. That instant
--     client-side vanish is exactly the 0181 rationale for the gated read RPC: the RLS bulletin
--     policy (status='offered' public read) still exposes stale rows to a RAW table select, but
--     the client only ever rides the gated RPC, so the board disappears with the flag.
--   • ██ THE EXPIRY FREEZE ██ (the 0176 forward note, extended by the 0179 (a2) pass): a lit→dark
--     flip freezes BOTH generator passes — then-stale 'offered' rows persist un-expired
--     (raw-readable per the note above) and 'accepted' rows past deliver_by stay un-cancelled,
--     holding their owners' cap slots. Do NOT try to sweep by running the generator once after
--     darkening — it gate-first no-ops while dark (the gate precedes both passes). Choose ONE:
--       (1) ACCEPT THE FROZEN STATE (recommended): it is harmless — every gated surface is
--           unreachable, and on re-light the first cron firing (or a re-run of activate-haul)
--           sweeps expiry + cancel in one pass with no gap and no double-write; or
--       (2) MANUALLY EXPIRE with the deliberate service-role statements below (the generator's own
--           (a)/(a2) predicates verbatim — the sanctioned transitions, applied by hand) if stale
--           raw-readable offers or frozen cap slots are unacceptable during the dark spell.
--   • haul_contracts / haul_receipts rows persist untouched either way; wallets keep every paid
--     reward; templates and knobs were never written by this script — nothing else to revert.
--
-- begin;
-- select public.set_game_config('haul_contracts_enabled', 'false'::jsonb);
-- select key, value from public.game_config where key = 'haul_contracts_enabled';
-- -- OPTIONAL manual sweep — choice (2) above only (the generator's own predicates, by hand):
-- -- update public.haul_contracts set status = 'expired'   where status = 'offered'  and expires_at <= now();
-- -- update public.haul_contracts set status = 'cancelled' where status = 'accepted' and deliver_by is not null and deliver_by <= now();
-- commit;
