-- Byeharu — TRADE-MARKET-1: atomic SELL path (Trade-Cargo FIFO consume + Wallet credit + market_sell).
--
-- Symmetric to the BUY path (0089): one commit adds the FIFO consume writer, the lazy Wallet credit writer,
-- and the market_sell orchestrator — same structure, sole-writer boundaries, per-ship lock, and
-- (main_ship_id, request_id) idempotency. DARK + server-rejected via trade_market_enabled. No flag set true.
--
-- ── DESIGN (planner authority; §1d/§2.1/§2.4/§2.6) ────────────────────────────────────────────────
-- SOLE WRITERS PRESERVED (extended, not duplicated):
--   • ship_cargo_lots  ← Trade Cargo only: trade_cargo_add_lot (insert, 0089) + trade_cargo_consume (FIFO
--       delete/update, new). Together they are the sole writer SYSTEM for ship_cargo_lots.
--   • player_wallet    ← Wallet only: wallet_debit (0089) + wallet_credit (new).
--   • trade_receipts   ← the market_sell orchestrator directly (Trade Market owns it).
-- FIFO + PER-LOT COST BASIS (§1d): trade_cargo_consume consumes oldest-first (acquired_at asc, lot_id asc)
--   and returns the SUMMED cost basis of the consumed lots, so market_sell reports a realized margin
--   (total_price − cost_basis_consumed). No separate valuation table — the lot sum is the source of truth.
-- ORCHESTRATOR FAN-OUT: market_sell validates via Main Ship (ownership + at_location, READ-ONLY), consumes
--   lots via Trade Cargo, credits Wallet, records the receipt — a one-directional, ACYCLIC fan-out. It NEVER
--   writes ship_cargo_lots/player_wallet directly and NEVER writes main_ship_instances → no second writer.
-- ATOMIC + IDEMPOTENT, ALL UNDER THE PER-SHIP LOCK: same guarantees as buy — one SECURITY DEFINER function =
--   one transaction; a retry replays the receipt and never double-credits/double-consumes.

-- ── A. Trade Cargo: FIFO consume writer (delete/update of ship_cargo_lots; internal). ──
--    Consumes p_qty units of p_good_id oldest-first; whole lot → delete, partial → update qty. Returns the
--    consumed cost basis (Σ consumed_qty * unit_cost_basis). Defensive backstop raises if short (caller
--    pre-checks sufficiency, so it should never fire — the raise rolls the whole txn back).
create or replace function public.trade_cargo_consume(p_main_ship_id uuid, p_good_id text, p_qty numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_remaining numeric := p_qty;
  v_cost      numeric := 0;
  v_take      numeric;
  r           record;
begin
  for r in
    select lot_id, qty, unit_cost_basis
      from public.ship_cargo_lots
      where main_ship_id = p_main_ship_id and good_id = p_good_id
      order by acquired_at asc, lot_id asc
      for update
  loop
    exit when v_remaining <= 0;
    if r.qty <= v_remaining then
      v_take := r.qty;                                        -- consume the whole lot
      delete from public.ship_cargo_lots where lot_id = r.lot_id;
    else
      v_take := v_remaining;                                  -- partial: leave the remainder in the lot
      update public.ship_cargo_lots set qty = qty - v_take where lot_id = r.lot_id;
    end if;
    v_cost := v_cost + v_take * r.unit_cost_basis;
    v_remaining := v_remaining - v_take;
  end loop;

  if v_remaining > 0 then
    raise exception 'trade_cargo_consume: insufficient cargo for ship % good % (short by %)',
      p_main_ship_id, p_good_id, v_remaining;                 -- defensive backstop; rolls back the txn
  end if;
  return v_cost;
end;
$$;
-- Internal: no client grant.
revoke execute on function public.trade_cargo_consume(uuid, text, numeric) from public, anon, authenticated;

-- ── B. Wallet: lazy ensure + ATOMIC credit (the wallet's credit writer). ──
create or replace function public.wallet_credit(p_player uuid, p_amount numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.player_wallet (player_id, balance) values (p_player, p_amount)
    on conflict (player_id) do update
      set balance = public.player_wallet.balance + p_amount, updated_at = now();
end;
$$;
-- Internal: no client grant.
revoke execute on function public.wallet_credit(uuid, numeric) from public, anon, authenticated;

-- ── C. market_sell: the Trade-Market SELL orchestrator (authenticated; atomic under the per-ship lock). ──
create or replace function public.market_sell(
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
  v_buy      numeric;
  v_avail    numeric;
  v_total    numeric;
  v_cost     numeric;
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
  -- txn end, so the idempotency + cargo checks and the consume/credit/receipt writes below are all race-safe.
  perform public.mainship_space_lock_context(v_ship);

  -- IDEMPOTENCY: a receipt for (ship, request_id) already exists → replay it verbatim, no write, no re-credit.
  select * into v_existing from public.trade_receipts
    where main_ship_id = v_ship and request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'idempotent_replay', true,
      'receipt_id', v_existing.receipt_id, 'side', v_existing.side, 'good_id', v_existing.good_id,
      'qty', v_existing.qty, 'unit_price', v_existing.unit_price, 'total_price', v_existing.total_price,
      'location_id', v_existing.location_id);
  end if;

  -- DOCKED check (same idiom as market_buy / get_market_offers): validate_context proves coherence; the dock
  -- comes STRICTLY from the validated present/location fleet (never the client).
  v_ctx := public.mainship_space_validate_context(v_ship);
  if (v_ctx->>'ok')::boolean is not true or (v_ctx->>'state') is distinct from 'at_location' then
    return jsonb_build_object('ok', false, 'reason', 'not_docked');
  end if;
  select f.current_location_id into v_loc
    from public.fleets f
    where f.main_ship_id = v_ship and f.status = 'present' and f.location_mode = 'location'
    limit 1;
  if v_loc is null then return jsonb_build_object('ok', false, 'reason', 'not_docked'); end if;

  -- OFFER: the station's buy_price for this good (credits it PAYS the player).
  select o.buy_price into v_buy from public.market_offers o
    where o.location_id = v_loc and o.good_id = p_good_id and o.active;
  if v_buy is null then return jsonb_build_object('ok', false, 'reason', 'offer_unavailable'); end if;

  -- CARGO sufficiency pre-check under the lock (so the FIFO consume never underflows).
  select coalesce(sum(qty), 0) into v_avail from public.ship_cargo_lots
    where main_ship_id = v_ship and good_id = p_good_id;
  if v_avail < p_qty then
    return jsonb_build_object('ok', false, 'reason', 'insufficient_cargo', 'available', v_avail);
  end if;

  v_total := v_buy * p_qty;

  -- CONSUME FIFO via Trade Cargo (sole writer); returns the consumed cost basis (§1d).
  v_cost := public.trade_cargo_consume(v_ship, p_good_id, p_qty);

  -- CREDIT the wallet (Wallet sole writer).
  perform public.wallet_credit(v_player, v_total);

  -- RECEIPT (Trade Market writes trade_receipts directly; (main_ship_id, request_id) idempotency key).
  insert into public.trade_receipts
    (main_ship_id, request_id, side, good_id, location_id, qty, unit_price, total_price)
    values (v_ship, p_request_id, 'sell', p_good_id, v_loc, p_qty, v_buy, v_total)
    returning receipt_id into v_receipt;

  return jsonb_build_object('ok', true, 'receipt_id', v_receipt,
    'side', 'sell', 'good_id', p_good_id, 'qty', p_qty, 'unit_price', v_buy, 'total_price', v_total,
    'location_id', v_loc, 'cost_basis_consumed', v_cost, 'realized_margin', v_total - v_cost);
end;
$$;
-- ACL: authenticated client RPC (server-rejected while dark); helpers above stay internal.
revoke execute on function public.market_sell(uuid, text, numeric, uuid) from public, anon;
grant  execute on function public.market_sell(uuid, text, numeric, uuid) to authenticated;
