-- PORT-SHOP ACTIVATION — the buy-modules-and-ammo-at-ports flip (PORT-SHOP 0235). The port outfitter is
-- FULLY BUILT DARK: 0235 seeds port_shop_offers (3 starter ports × 8 beginner offers), the two new catalog
-- rows (autocannon_rounds ammo + shield_generator module), the port_shop_receipts idempotency ledger, and
-- the flag-gated RPCs buy_shop_offer_at_port + get_port_shop; the ShopPanel mounts off the same flag.
-- Everything is dark behind port_shop_enabled='false'.
--
-- ██ HUMAN ACTIVATION TOOL ██ — run BY THE HUMAN, deliberately, against prod. NOT CI; nothing flips at
-- build/deploy time. Each run of this file IS the recorded human go decision.
--
-- ── WHAT IT DOES (one transaction; COMMIT only if every assert passes) ────────────────────────────
--   PRECONDITIONS (no write until these hold):
--     • migration head >= 20260618000235 AND 0235 recorded as deployed;
--     • the port_shop_offers + port_shop_receipts tables exist;
--     • the RPCs + their downward leaves exist via to_regprocedure — the REAL signatures;
--     • the DEPLOYED buy RPC is the 0235 head, prosrc-pinned: it carries the gate reject
--       (port_shop_disabled) BEFORE any read;
--     • ██ THE SEEDED OFFER TABLE (accept, do NOT re-seed) ██: the 3 starter ports each carry exactly 8
--       ACTIVE offers. This script REFERENCES the seeded prices; it never rewrites them (a price retune is
--       a separate migration/reseed, per the 0235 charter);
--     • the 'port_shop_enabled' key exists (0235 seeds it false). Its VALUE is not asserted false — a
--       RE-RUN after success is a supported no-op.
--   STAGE 1 — the switch (the ONE flag write, via the owned set_game_config writer):
--     port_shop_enabled → true. Both RPCs dark-gate on cfg_bool('port_shop_enabled') FIRST and reject
--     port_shop_disabled while false — they physically cannot buy/debit/mint dark.
--   SMOKE (read-only + a zero-write gate probe): flag committed (raw + cfg_bool); the offer table is
--     populated (24 active rows across the 3 ports); the buy RPC no longer gate-rejects — called under a
--     TRANSACTION-LOCAL fake JWT with a valid ref/qty/request but a random subject that owns NO ship, so it
--     advances PAST the gate to ship_not_found (NOT port_shop_disabled), proving the gate opened while
--     writing nothing; port_shop_receipts selectable.
--   Emits ACTIVATE_PORTSHOP_PASS_* markers per stage and one final PASS line; any failed assert RAISES →
--   the whole transaction rolls back → NOTHING is applied (all-or-nothing activation).
--
-- RE-RUN SEMANTICS (decided, documented): safe no-op success. The flag write is a set_game_config upsert
-- to the same value; no other state is touched. No path double-applies.
--
-- ── THE UI (ShopPanel) ───────────────────────────────────────────────────────────────────────────
--   The ShopPanel mounts on the Port screen gated on the SAME server flag (via get_port_shop). Flag false
--   → the gated read rejects → the panel renders null. The moment this commits, the next docked-Port read
--   sees port_shop_enabled=true and the outfitter appears.
--
-- ── INVOCATION (Management-API compatible: NO psql meta-commands; one BEGIN..COMMIT) ─────────────
--   psql "<prod session-pooler conn>" -X -v ON_ERROR_STOP=1 -f scripts/activate-port-shop.sql
--   Or paste into the Supabase Dashboard SQL editor, or: bash scripts/activate-port-shop.sh run ACTIVATE_PORT_SHOP
--   AFTER a green run: manual smoke — dock → the outfitter lists the beginner offers → buy a module → it
--   lands in your module pool (fittable) and wallet debits; buy ammo → inventory fills.
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
--   See the marked ROLLBACK section (commented). FLAG-ONLY: port_shop_enabled → false. Both RPCs reject
--   gate-first again and the panel fails closed to null. Past purchases stand (receipts + grants are never
--   reverted); the seeded offer table is untouched either way.

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
begin
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  if v_head is null or v_head < '20260618000235' then
    raise exception 'PRECONDITION FAIL: migration head % < 20260618000235 (PORT-SHOP) — deploy the shop stack first', coalesce(v_head, '(none)');
  end if;
  if not exists (select 1 from supabase_migrations.schema_migrations s where s.version = '20260618000235') then
    raise exception 'PRECONDITION FAIL: migration 20260618000235 not recorded as deployed';
  end if;

  if to_regclass('public.port_shop_offers') is null then
    raise exception 'PRECONDITION FAIL: table public.port_shop_offers missing (deploy 0235)'; end if;
  if to_regclass('public.port_shop_receipts') is null then
    raise exception 'PRECONDITION FAIL: table public.port_shop_receipts missing (deploy 0235)'; end if;

  foreach fn in array array[
    'public.buy_shop_offer_at_port(uuid, text, numeric, uuid)',
    'public.get_port_shop(uuid)',
    'public.mainship_resolve_owned_ship(uuid, uuid)',
    'public.mainship_resolve_docked_location(uuid)',
    'public.modules_mint_instance(uuid, text, text)',
    'public.inventory_deposit(uuid, text, integer, text)',
    'public.wallet_debit(uuid, numeric)',
    'public.cfg_bool(text)',
    'public.set_game_config(text, jsonb)'] loop
    if to_regprocedure(fn) is null then
      raise exception 'PRECONDITION FAIL: function % does not exist', fn;
    end if;
  end loop;

  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.buy_shop_offer_at_port(uuid, text, numeric, uuid)')::oid;
  if position('port_shop_disabled' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed buy_shop_offer_at_port lacks the dark gate reject (deploy 0235)';
  end if;

  -- ██ THE SEEDED OFFER TABLE ██ — each starter port carries exactly 8 ACTIVE offers (referenced, NEVER
  -- re-seeded here).
  select count(*) into n from unnest(array[c_haven, c_slag, c_drift]) p
    where (select count(*) from public.port_shop_offers o where o.location_id = p and o.active) <> 8;
  if n <> 0 then
    raise exception 'PRECONDITION FAIL: % starter port(s) do not carry exactly 8 active offers (the 0235 seed drifted — re-seed via a migration, not this script)', n;
  end if;

  if not exists (select 1 from public.game_config where key = 'port_shop_enabled') then
    raise exception 'PRECONDITION FAIL: game_config key port_shop_enabled missing (0235 seeds it false)';
  end if;

  if not has_function_privilege('authenticated', 'public.buy_shop_offer_at_port(uuid,text,numeric,uuid)', 'execute')
     or has_function_privilege('anon', 'public.buy_shop_offer_at_port(uuid,text,numeric,uuid)', 'execute') then
    raise exception 'PRECONDITION FAIL: buy_shop_offer_at_port ACL drifted (want authenticated-only, never anon)';
  end if;

  raise notice 'ACTIVATE_PORTSHOP_PASS_PRECONDITIONS ok: head %, 0235 recorded, tables present, RPCs + leaves present (real signatures), buy body gate-pinned, 3 ports × 8 active offers seeded (referenced not re-seeded), key present, ACL authenticated-only', v_head;
end $$;

-- ══════════ STAGE 1 — the switch (the ONE flag write, via the owned set_game_config writer) ══════════
do $$
declare v_before text;
begin
  select value::text into v_before from public.game_config where key = 'port_shop_enabled';
  perform public.set_game_config('port_shop_enabled', 'true'::jsonb);
  raise notice 'stage 1: port_shop_enabled % -> true', v_before;
  raise notice 'ACTIVATE_PORTSHOP_PASS_STAGE1 ok: port_shop_enabled=true (uncommitted until smoke passes — one all-or-nothing txn)';
end $$;

-- ══════════ SMOKE — read-only + a zero-write gate probe ══════════
do $$
declare v_res jsonb; n int;
begin
  if (select value #>> '{}' from public.game_config where key = 'port_shop_enabled') is distinct from 'true' then
    raise exception 'SMOKE FAIL: port_shop_enabled is % (want true)',
      (select value #>> '{}' from public.game_config where key = 'port_shop_enabled');
  end if;
  if not public.cfg_bool('port_shop_enabled') then
    raise exception 'SMOKE FAIL: cfg_bool(port_shop_enabled) still false'; end if;

  select count(*) into n from public.port_shop_offers where active;
  if n < 24 then
    raise exception 'SMOKE FAIL: only % active offer rows (want >= 24 — the 3×8 seeded outfit)', n; end if;
  raise notice 'smoke: % active port_shop_offers rows', n;

  -- THE GATE OPENED (zero-write probe): the buy RPC no longer rejects port_shop_disabled. Called under a
  -- TRANSACTION-LOCAL fake JWT with a VALID ref/qty/request but a random subject that owns NO ship, so the
  -- reject advances past the gate to ship_not_found — proving the gate is open WITHOUT writing anything.
  perform set_config('request.jwt.claims',
    json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
  v_res := public.buy_shop_offer_at_port(gen_random_uuid(), 'autocannon_battery', 1, gen_random_uuid());
  if (v_res ->> 'reason') is distinct from 'ship_not_found' then
    raise exception 'SMOKE FAIL: the buy RPC did not advance past the gate to ship_not_found (got %) — the flip did not open the gate', v_res;
  end if;
  perform set_config('request.jwt.claims', '', true);

  select count(*) into n from public.port_shop_receipts;
  raise notice 'smoke: port_shop_receipts rows = % (0 expected at flip time)', n;

  raise notice 'ACTIVATE_PORTSHOP_PASS_SMOKE ok: flag committed true, offer table populated, buy RPC gate OPEN (advances to ship_not_found for a no-ship subject, zero writes), receipts selectable';
end $$;

select 'PORT-SHOP ACTIVATION PASS — the port outfitter is LIVE server-side (buy_shop_offer_at_port no longer gate-rejects). The ShopPanel mounts on the Port screen gated on port_shop_enabled and appears the moment this commits. The seeded 0235 offer table (3 ports × 8 beginner offers: 7 modules + ammo) is accepted as-is. Players dock, see the outfitter, buy a module (minted into their fittable module pool) or ammo (into inventory) for credits via Wallet with idempotent receipts.' as result;

commit;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- To dark the port shop again, run the reverse write below (uncomment, run once). Notes:
--   • FLAG-ONLY: port_shop_enabled → false. Both RPCs reject gate-first again (port_shop_disabled) and the
--     ShopPanel fails closed to null on its next read.
--   • Past purchases STAND: port_shop_receipts rows + minted instances + deposited items + debited wallets
--     are never reverted.
--   • The seeded port_shop_offers table is untouched either way (a price retune is a separate reseed
--     migration — never this script).
--
-- begin;
-- select public.set_game_config('port_shop_enabled', 'false'::jsonb);
-- select key, value from public.game_config where key = 'port_shop_enabled';
-- commit;
