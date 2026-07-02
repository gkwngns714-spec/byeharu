-- Byeharu — TRADE-MARKET-1: atomic BUY path (Trade-Cargo lot writer + Wallet debit + market_buy orchestrator).
--
-- The heart of TRADE-MARKET-1: one commit adds the three cooperating functions. The two helpers are justified
-- by their market_buy caller (no speculative helpers). Everything is DARK + server-rejected via
-- trade_market_enabled (rejected before any ship read). No flag is set true.
--
-- ── DESIGN (planner authority; §2.1/§2.4/§2.6/§1e) ────────────────────────────────────────────────
-- SOLE WRITERS PRESERVED:
--   • ship_cargo_lots  ← ONLY trade_cargo_add_lot (Trade Cargo, new).
--   • player_wallet    ← ONLY wallet_debit (Wallet, new; lazy ensure + atomic conditional debit).
--   • trade_receipts   ← the market_buy orchestrator directly (Trade Market owns it).
-- ORCHESTRATOR FAN-OUT: market_buy validates via Main Ship (ownership + at_location + capacity, READ-ONLY),
--   writes the lot via Trade Cargo, debits Wallet, records the receipt — a one-directional, ACYCLIC fan-out.
--   It NEVER writes ship_cargo_lots/player_wallet directly and NEVER writes main_ship_instances → no second
--   writer to any table.
-- ATOMIC + IDEMPOTENT + VOLUME-CHECKED, ALL UNDER THE PER-SHIP LOCK: market_buy acquires
--   mainship_space_lock_context(v_ship) (the same pure lock/context substrate the movement commands use — it
--   does `select … for update` and writes nothing), then does the (main_ship_id, request_id) idempotency
--   check, the docked check, the offer lookup, the volume check, the wallet debit, the lot write, and the
--   receipt insert. One SECURITY DEFINER function = one transaction → all writes commit or roll back together;
--   a retry never double-spends and the volume check is race-safe. Occupied volume is the ship_cargo_lots
--   lot-sum (never cached on the instance). unit_cost_basis = the price paid (§1d).

-- ── A. Trade Cargo: the SOLE inserter of ship_cargo_lots (internal; called by the orchestrator). ──
create or replace function public.trade_cargo_add_lot(
  p_main_ship_id uuid, p_good_id text, p_qty numeric, p_unit_cost_basis numeric, p_origin_location_id uuid
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lot uuid;
begin
  insert into public.ship_cargo_lots (main_ship_id, good_id, qty, unit_cost_basis, origin_location_id)
    values (p_main_ship_id, p_good_id, p_qty, p_unit_cost_basis, p_origin_location_id)
    returning lot_id into v_lot;
  return v_lot;
end;
$$;
-- Internal: no client grant. The definer/owner calls it inside the SECURITY DEFINER orchestrator.
revoke execute on function public.trade_cargo_add_lot(uuid, text, numeric, numeric, uuid) from public, anon, authenticated;

-- ── B. Wallet: lazy ensure + ATOMIC conditional debit (the SOLE player_wallet writer). ──
--    The conditional UPDATE (balance >= p_amount) row-locks the wallet, so concurrent debits — even across
--    different ships of the same player — are serialized and can never overdraw. Returns false if too poor.
create or replace function public.wallet_debit(p_player uuid, p_amount numeric)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.player_wallet (player_id) values (p_player) on conflict (player_id) do nothing;
  update public.player_wallet
    set balance = balance - p_amount, updated_at = now()
    where player_id = p_player and balance >= p_amount;
  return found;
end;
$$;
-- Internal: no client grant.
revoke execute on function public.wallet_debit(uuid, numeric) from public, anon, authenticated;

-- ── C. market_buy: the Trade-Market BUY orchestrator (authenticated; atomic under the per-ship lock). ──
create or replace function public.market_buy(
  p_main_ship_id uuid, p_good_id text, p_qty numeric, p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_ship     uuid;
  v_ctx      jsonb;
  v_loc      uuid;
  v_existing public.trade_receipts%rowtype;
  v_sell     numeric;
  v_unit_vol numeric;
  v_used     numeric;
  v_cap      numeric;
  v_total    numeric;
  v_lot      uuid;
  v_receipt  uuid;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK server-reject: reject deterministically BEFORE any ship read/lock/query.
  if not public.cfg_bool('trade_market_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'trade_market_disabled');
  end if;

  -- input validation
  if p_request_id is null then return jsonb_build_object('ok', false, 'reason', 'invalid_request'); end if;
  if p_good_id   is null then return jsonb_build_object('ok', false, 'reason', 'invalid_good');    end if;
  if p_qty is null or p_qty <= 0 then return jsonb_build_object('ok', false, 'reason', 'invalid_qty'); end if;

  -- resolve the SELECTED owned ship (ownership asserted) or the sole ship (shim); UI selection never trusted.
  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then return jsonb_build_object('ok', false, 'reason', 'no_ship'); end if;

  -- PER-SHIP LOCK: serializes concurrent trades on the SAME ship (pure lock/context read; no writes). Held to
  -- txn end, so the idempotency + volume checks and the debit/lot/receipt writes below are all race-safe.
  perform public.mainship_space_lock_context(v_ship);

  -- IDEMPOTENCY: a receipt for (ship, request_id) already exists → replay it verbatim, no write, no re-charge.
  select * into v_existing from public.trade_receipts
    where main_ship_id = v_ship and request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'idempotent_replay', true,
      'receipt_id', v_existing.receipt_id, 'side', v_existing.side, 'good_id', v_existing.good_id,
      'qty', v_existing.qty, 'unit_price', v_existing.unit_price, 'total_price', v_existing.total_price,
      'location_id', v_existing.location_id);
  end if;

  -- DOCKED check (same idiom as get_market_offers): validate_context proves coherence; the dock comes STRICTLY
  -- from the validated present/location fleet (never the client).
  v_ctx := public.mainship_space_validate_context(v_ship);
  if (v_ctx->>'ok')::boolean is not true or (v_ctx->>'state') is distinct from 'at_location' then
    return jsonb_build_object('ok', false, 'reason', 'not_docked');
  end if;
  select f.current_location_id into v_loc
    from public.fleets f
    where f.main_ship_id = v_ship and f.status = 'present' and f.location_mode = 'location'
    limit 1;
  if v_loc is null then return jsonb_build_object('ok', false, 'reason', 'not_docked'); end if;

  -- OFFER for this good at this station.
  select o.sell_price into v_sell from public.market_offers o
    where o.location_id = v_loc and o.good_id = p_good_id and o.active;
  if v_sell is null then return jsonb_build_object('ok', false, 'reason', 'offer_unavailable'); end if;

  -- VOLUME check under the lock: used = lot-sum, cap = instance cargo_capacity_m3.
  select g.unit_volume_m3 into v_unit_vol from public.trade_goods g where g.good_id = p_good_id;
  if v_unit_vol is null then return jsonb_build_object('ok', false, 'reason', 'invalid_good'); end if;
  select coalesce(sum(l.qty * g.unit_volume_m3), 0) into v_used
    from public.ship_cargo_lots l
    join public.trade_goods g on g.good_id = l.good_id
    where l.main_ship_id = v_ship;
  select m.cargo_capacity_m3 into v_cap from public.main_ship_instances m where m.main_ship_id = v_ship;
  if v_used + p_qty * v_unit_vol > v_cap then
    return jsonb_build_object('ok', false, 'reason', 'insufficient_volume',
      'used_m3', v_used, 'capacity_m3', v_cap, 'delta_m3', p_qty * v_unit_vol);
  end if;

  v_total := v_sell * p_qty;

  -- WALLET debit (atomic conditional; false → too poor, no cargo/receipt written).
  if not public.wallet_debit(v_player, v_total) then
    return jsonb_build_object('ok', false, 'reason', 'insufficient_credits', 'price', v_total);
  end if;

  -- LOT write via Trade Cargo (sole writer); unit_cost_basis = the price paid (§1d).
  v_lot := public.trade_cargo_add_lot(v_ship, p_good_id, p_qty, v_sell, v_loc);

  -- RECEIPT (Trade Market writes trade_receipts directly; (main_ship_id, request_id) idempotency key).
  insert into public.trade_receipts
    (main_ship_id, request_id, side, good_id, location_id, qty, unit_price, total_price)
    values (v_ship, p_request_id, 'buy', p_good_id, v_loc, p_qty, v_sell, v_total)
    returning receipt_id into v_receipt;

  return jsonb_build_object('ok', true, 'receipt_id', v_receipt, 'lot_id', v_lot,
    'side', 'buy', 'good_id', p_good_id, 'qty', p_qty, 'unit_price', v_sell, 'total_price', v_total,
    'location_id', v_loc);
end;
$$;
-- ACL: authenticated client RPC (server-rejected while dark); helpers above stay internal.
revoke execute on function public.market_buy(uuid, text, numeric, uuid) from public, anon;
grant  execute on function public.market_buy(uuid, text, numeric, uuid) to authenticated;
