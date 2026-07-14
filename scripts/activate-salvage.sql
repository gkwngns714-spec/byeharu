-- SALVAGE ACTIVATION — the sell-loot-at-ports flip (docs/ACTIVATION_GUIDE.md → ACT-SALVAGE; the
-- SALVAGE packet's human activation step). The port item-salvage market is FULLY BUILT DARK: 0174
-- seeds the port_item_demand buy-list (3 starter ports × 5 combat-droppable items), the
-- salvage_receipts idempotency ledger, and the flag-gated sell RPC sell_item_at_port; the SALVAGE-2
-- UI (#128) mounts it. Everything is dark behind salvage_market_enabled='false'.
--
-- ██ HUMAN ACTIVATION TOOL ██ — run BY THE HUMAN, deliberately, against prod. NOT CI; nothing flips
-- at build/deploy time. Each run of this file IS the recorded human go decision.
--
-- ── WHAT IT DOES (one transaction; COMMIT only if every assert passes) ────────────────────────────
--   PRECONDITIONS (no write until these hold):
--     • migration head >= 20260618000174 AND 0174 recorded as deployed;
--     • the port_item_demand + salvage_receipts tables exist;
--     • the sell RPC + its downward leaves exist via to_regprocedure (sell_item_at_port + the
--       resolvers/inventory_spend/wallet_credit it fans out to) — the REAL signatures;
--     • the DEPLOYED sell RPC is the 0174 head, prosrc-pinned: it carries the gate reject
--       (salvage_market_disabled) BEFORE any read;
--     • ██ THE SEEDED PRICE TABLE (accept, do NOT re-seed) ██: the 3 starter ports each carry
--       exactly 5 ACTIVE demand rows (the 0174 role-differentiated buy-list — scrap/pirate_alloy/
--       repair_parts/engine_parts/weapon_parts). This script REFERENCES the seeded prices; it never
--       rewrites them (a price retune is a separate migration/reseed, per the 0174 charter);
--     • the 'salvage_market_enabled' key exists (0174 seeds it false). Its VALUE is not asserted
--       false — a RE-RUN after success is a supported no-op;
--     • ACL: the sell RPC is authenticated-only, never anon.
--   STAGE 1 — the switch (the ONE flag write, via the owned set_game_config writer):
--     salvage_market_enabled → true. The sell RPC dark-gates on cfg_bool('salvage_market_enabled')
--     FIRST and rejects salvage_market_disabled while false — it physically cannot sell/credit dark.
--   SMOKE (read-only + a zero-write gate probe): flag committed (raw + cfg_bool); the demand table
--     is populated (15 active rows across the 3 ports); the sell RPC no longer gate-rejects — called
--     under a TRANSACTION-LOCAL fake JWT (the proofs' set_config technique) with a valid item/qty/
--     request but a random subject that owns NO ship, so it advances PAST the gate to ship_not_found
--     (NOT salvage_market_disabled), proving the gate opened while writing nothing; salvage_receipts
--     selectable.
--   Emits ACTIVATE_SALVAGE_PASS_* markers per stage and one final PASS line; any failed assert
--   RAISES → the whole transaction rolls back → NOTHING is applied (all-or-nothing activation).
--
-- RE-RUN SEMANTICS (decided, documented): safe no-op success. The flag write is a set_game_config
-- upsert to the same value; no other state is touched. No path double-applies.
--
-- ── NO NEW CLIENT PR IS NEEDED (the SALVAGE-2 UI already ships) ───────────────────────────────────
--   The SalvageMarketPanel (SALVAGE-2, #128) is already mounted on the Port screen and gated on the
--   SAME server flag it reads from public game_config — flag false → renders null. The moment this
--   commits, its next docked-Port read sees salvage_market_enabled=true and the sell desk appears.
--
-- ── NOTE: SELLS COMBAT LOOT — PAIRS WITH HUNTING ─────────────────────────────────────────────────
--   The demand table buys EXACTLY the five combat droppables (scrap w>=1, pirate_alloy w>=3,
--   weapon_parts w>=5, engine_parts w>=8, repair_parts w>=10). It is the economy EXIT for combat
--   loot — flip it alongside the hunting loop (a player who never fights has nothing to sell).
--
-- ── INVOCATION (Management-API compatible: NO psql meta-commands; one BEGIN..COMMIT) ─────────────
--   psql "<prod session-pooler conn>" -X -v ON_ERROR_STOP=1 -f scripts/activate-salvage.sql
--   Or paste into the Supabase Dashboard SQL editor / management-API runner, or:
--     bash scripts/activate-salvage.sh run ACTIVATE_SALVAGE      # DB_URL required
--   AFTER a green run: manual smoke — dock with combat loot aboard → the salvage desk lists the port
--   demand → sell → wallet credits by qty × the seeded unit_price and the items leave inventory.
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
--   See the marked ROLLBACK section (commented). FLAG-ONLY: salvage_market_enabled → false. The sell
--   RPC rejects gate-first again and the panel fails closed to null. Past sales stand (receipts +
--   credits are never reverted); the seeded demand table is untouched either way.

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
  v_head text; fn text; v_src text; n int;
  v_drops constant text[] := array['scrap','pirate_alloy','weapon_parts','engine_parts','repair_parts'];
begin
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  if v_head is null or v_head < '20260618000174' then
    raise exception 'PRECONDITION FAIL: migration head % < 20260618000174 (SALVAGE) — deploy the salvage stack first', coalesce(v_head, '(none)');
  end if;
  if not exists (select 1 from supabase_migrations.schema_migrations s where s.version = '20260618000174') then
    raise exception 'PRECONDITION FAIL: migration 20260618000174 not recorded as deployed';
  end if;

  -- the tables exist.
  if to_regclass('public.port_item_demand') is null then
    raise exception 'PRECONDITION FAIL: table public.port_item_demand missing (deploy 0174)'; end if;
  if to_regclass('public.salvage_receipts') is null then
    raise exception 'PRECONDITION FAIL: table public.salvage_receipts missing (deploy 0174)'; end if;

  -- the sell RPC + its downward leaves — the REAL signatures.
  foreach fn in array array[
    'public.sell_item_at_port(uuid, text, numeric, uuid)',
    'public.mainship_resolve_owned_ship(uuid, uuid)',
    'public.mainship_resolve_docked_location(uuid)',
    'public.inventory_spend(uuid, text, integer)',
    'public.wallet_credit(uuid, numeric)',
    'public.cfg_bool(text)',
    'public.set_game_config(text, jsonb)'] loop
    if to_regprocedure(fn) is null then
      raise exception 'PRECONDITION FAIL: function % does not exist', fn;
    end if;
  end loop;

  -- the DEPLOYED sell RPC is the 0174 head: gate-first reject.
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.sell_item_at_port(uuid, text, numeric, uuid)')::oid;
  if position('salvage_market_disabled' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed sell_item_at_port lacks the dark gate reject (deploy 0174)';
  end if;

  -- ██ THE SEEDED PRICE TABLE ██ — each starter port carries exactly 5 ACTIVE demand rows for the
  -- combat droppables (referenced, NEVER re-seeded here).
  select count(*) into n from unnest(array[c_haven, c_slag, c_drift]) p
    where (select count(*) from public.port_item_demand d
             where d.location_id = p and d.item_id = any(v_drops) and d.active) <> 5;
  if n <> 0 then
    raise exception 'PRECONDITION FAIL: % starter port(s) do not carry exactly 5 active demand rows (the 0174 seed drifted — re-seed via a migration, not this script)', n;
  end if;

  -- the ONE key this script writes must already exist. Its VALUE is not asserted (re-run no-op).
  if not exists (select 1 from public.game_config where key = 'salvage_market_enabled') then
    raise exception 'PRECONDITION FAIL: game_config key salvage_market_enabled missing (0174 seeds it false)';
  end if;

  -- ACL posture: the sell RPC is authenticated-only, never anon.
  if not has_function_privilege('authenticated', 'public.sell_item_at_port(uuid,text,numeric,uuid)', 'execute')
     or has_function_privilege('anon', 'public.sell_item_at_port(uuid,text,numeric,uuid)', 'execute') then
    raise exception 'PRECONDITION FAIL: sell_item_at_port ACL drifted (want authenticated-only, never anon)';
  end if;

  raise notice 'ACTIVATE_SALVAGE_PASS_PRECONDITIONS ok: head %, 0174 recorded, tables present, sell RPC + leaves present (real signatures), sell body gate-pinned, 3 ports × 5 active demand rows seeded (referenced not re-seeded), key present, ACL authenticated-only', v_head;
end $$;

-- ══════════ STAGE 1 — the switch (the ONE flag write, via the owned set_game_config writer) ══════════
do $$
declare v_before text;
begin
  select value::text into v_before from public.game_config where key = 'salvage_market_enabled';
  perform public.set_game_config('salvage_market_enabled', 'true'::jsonb);
  raise notice 'stage 1: salvage_market_enabled % -> true', v_before;
  raise notice 'ACTIVATE_SALVAGE_PASS_STAGE1 ok: salvage_market_enabled=true (uncommitted until smoke passes — one all-or-nothing txn)';
end $$;

-- ══════════ SMOKE — read-only + a zero-write gate probe ══════════
do $$
declare v_res jsonb; n int;
begin
  -- (a) the committed flag value.
  if (select value #>> '{}' from public.game_config where key = 'salvage_market_enabled') is distinct from 'true' then
    raise exception 'SMOKE FAIL: salvage_market_enabled is % (want true)',
      (select value #>> '{}' from public.game_config where key = 'salvage_market_enabled');
  end if;
  if not public.cfg_bool('salvage_market_enabled') then
    raise exception 'SMOKE FAIL: cfg_bool(salvage_market_enabled) still false'; end if;

  -- (b) the demand table is populated (15 active rows across the 3 starter ports).
  select count(*) into n from public.port_item_demand where active;
  if n < 15 then
    raise exception 'SMOKE FAIL: only % active demand rows (want >= 15 — the 3×5 seeded buy-list)', n; end if;
  raise notice 'smoke: % active port_item_demand rows', n;

  -- (c) THE GATE OPENED (zero-write probe): the sell RPC no longer rejects salvage_market_disabled.
  --     Called under a TRANSACTION-LOCAL fake JWT (the proofs' set_config technique) with a VALID
  --     request_id/item/quantity but a random subject that owns NO ship, so the reject advances past
  --     the gate to ship_not_found — proving the gate is open WITHOUT writing anything (the subject
  --     owns nothing; the reject path is read-only). Claims cleared after (and the txn-local setting
  --     evaporates at COMMIT regardless).
  perform set_config('request.jwt.claims',
    json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
  v_res := public.sell_item_at_port(gen_random_uuid(), 'scrap', 1, gen_random_uuid());
  if (v_res ->> 'reason') is distinct from 'ship_not_found' then
    raise exception 'SMOKE FAIL: the sell RPC did not advance past the gate to ship_not_found (got %) — the flip did not open the gate', v_res;
  end if;
  perform set_config('request.jwt.claims', '', true);

  -- (d) salvage_receipts selectable (count FYI — 0 at flip time; fills as players sell).
  select count(*) into n from public.salvage_receipts;
  raise notice 'smoke: salvage_receipts rows = % (0 expected at flip time)', n;

  raise notice 'ACTIVATE_SALVAGE_PASS_SMOKE ok: flag committed true, demand table populated, sell RPC gate OPEN (advances to ship_not_found for a no-ship subject, zero writes), receipts selectable';
end $$;

select 'SALVAGE ACTIVATION PASS — the port item-salvage market is LIVE server-side (sell_item_at_port no longer gate-rejects). NO new client PR is needed: the SalvageMarketPanel (SALVAGE-2, #128) already mounts on the Port screen gated on salvage_market_enabled and appears the moment this commits. The seeded 0174 price table (3 ports × 5 combat droppables, role-differentiated) is accepted as-is. Players dock with combat loot, see each port''s buy-list, and sell for qty × the seeded unit_price via Wallet with idempotent receipts. Sells COMBAT loot — pair with the hunting loop.' as result;

commit;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- To dark the salvage market again, run the reverse write below (uncomment, run once). Notes:
--   • FLAG-ONLY: salvage_market_enabled → false. The sell RPC rejects gate-first again
--     (salvage_market_disabled) and the SalvageMarketPanel fails closed to null on its next read.
--   • Past sales STAND: salvage_receipts rows + credited wallets are never reverted.
--   • The seeded port_item_demand table is untouched either way (a price retune is a separate reseed
--     migration — never this script).
--
-- begin;
-- select public.set_game_config('salvage_market_enabled', 'false'::jsonb);
-- select key, value from public.game_config where key = 'salvage_market_enabled';
-- commit;
