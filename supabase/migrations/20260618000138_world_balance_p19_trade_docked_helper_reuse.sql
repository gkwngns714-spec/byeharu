-- Byeharu — WORLD-BALANCE-P19 cleanup: restore the 0092 docked-resolve dedup that 0136 regressed.
--
-- ROOT CAUSE. Migration 0092 (trade_market_1) extracted the copy-pasted ~10-line "resolve docked
-- location" block (validate_context → require at_location → read the present/location fleet's
-- current_location_id) into ONE shared read-only helper `public.mainship_resolve_docked_location(ship)`
-- and repointed all three Trade Market RPCs to it. Migration 0136 (price drift) rebuilt those three
-- functions from the STALE pre-0092 bodies (0087/0089/0090) to add the `trade_effective_price` price
-- composition, and in doing so RE-INLINED the docked block into all three (get_market_offers,
-- market_buy, market_sell) and re-declared the `v_ctx jsonb` local 0092 had dropped — silently reverting
-- the dedup and leaving the helper orphaned from the trade path (it stayed in use only by 0133).
--
-- THIS FIX (forward-only, edits NO shipped migration — 0092/0136 are superseded by create-or-replace).
-- Re-create the three functions to the EXACT 0136 bodies, changing ONLY:
--   (a) each re-inlined docked block → `v_loc := public.mainship_resolve_docked_location(v_ship);`
--       followed by the SAME `if v_loc is null then … 'not_docked' … end if;` each function already had
--       (both inline null-paths — not at_location, and no matching fleet row — collapsed to one NULL →
--       one 'not_docked' reason, exactly as before, so this is BEHAVIOR-IDENTICAL); and
--   (b) drop the now-unused `v_ctx jsonb;` local from each declare block.
-- EVERYTHING else is byte-for-byte 0136: the dark `trade_market_enabled` server-reject, the
-- `mainship_resolve_owned_ship` resolve, the per-ship `mainship_space_lock_context`, the idempotency
-- replay, the `trade_effective_price` composition on EVERY price (display == charged/paid), the receipt
-- writes, and the same `revoke … from public, anon` / `grant … to authenticated` ACLs.
--
-- POSTURE. Adds NO table / column / writer / flag / cross-system edge — the helper and the Trade Market
-- → Main-Ship read edge already exist and are already documented (SYSTEM_BOUNDARIES §2/§3). The feature
-- stays DARK behind `trade_market_enabled='false'`; this migration flips NO flag. It re-makes the
-- SYSTEM_BOUNDARIES Trade-Market ("docked-location context via the shared Main-Ship helper
-- `mainship_resolve_docked_location`") and Main-Ship ("called DOWNWARD by the Trade Market RPCs")
-- statements true again (they described the intended end-state; 0136 was the drift, this restores it).

-- ── A. get_market_offers — EXACTLY the 0136 body; inline docked block → helper call, v_ctx local dropped.
create or replace function public.get_market_offers(p_main_ship_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_ship   uuid;
  v_loc    uuid;
  v_offers jsonb;
  c_empty  constant jsonb := '[]'::jsonb;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  if not public.cfg_bool('trade_market_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'trade_market_disabled');
  end if;

  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then
    return jsonb_build_object('ok', false, 'reason', 'no_ship');
  end if;

  v_loc := public.mainship_resolve_docked_location(v_ship);
  if v_loc is null then
    return jsonb_build_object('ok', false, 'reason', 'not_docked');
  end if;

  -- read-only: aggregate this station's ACTIVE offers (Reference/Config market_offers). Writes nothing.
  -- Prices are composed with the World-State multiplier (WORLD-BALANCE-P19) so display == charged/paid.
  select coalesce(jsonb_agg(jsonb_build_object(
           'offer_id',   o.offer_id,
           'good_id',    o.good_id,
           'buy_price',  public.trade_effective_price(o.buy_price,  v_loc),
           'sell_price', public.trade_effective_price(o.sell_price, v_loc)) order by o.good_id), c_empty)
    into v_offers
    from public.market_offers o
    where o.location_id = v_loc and o.active;

  return jsonb_build_object('ok', true, 'main_ship_id', v_ship, 'location_id', v_loc,
                            'offers', coalesce(v_offers, c_empty));
end;
$$;
revoke execute on function public.get_market_offers(uuid) from public, anon;
grant  execute on function public.get_market_offers(uuid) to authenticated;

-- ── B. market_buy — EXACTLY the 0136 body; inline docked block → helper call, v_ctx local dropped.
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

  if not public.cfg_bool('trade_market_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'trade_market_disabled');
  end if;

  if p_request_id is null then return jsonb_build_object('ok', false, 'reason', 'invalid_request'); end if;
  if p_good_id   is null then return jsonb_build_object('ok', false, 'reason', 'invalid_good');    end if;
  if p_qty is null or p_qty <= 0 then return jsonb_build_object('ok', false, 'reason', 'invalid_qty'); end if;

  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then return jsonb_build_object('ok', false, 'reason', 'no_ship'); end if;

  perform public.mainship_space_lock_context(v_ship);

  select * into v_existing from public.trade_receipts
    where main_ship_id = v_ship and request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'idempotent_replay', true,
      'receipt_id', v_existing.receipt_id, 'side', v_existing.side, 'good_id', v_existing.good_id,
      'qty', v_existing.qty, 'unit_price', v_existing.unit_price, 'total_price', v_existing.total_price,
      'location_id', v_existing.location_id);
  end if;

  v_loc := public.mainship_resolve_docked_location(v_ship);
  if v_loc is null then return jsonb_build_object('ok', false, 'reason', 'not_docked'); end if;

  -- OFFER for this good at this station — COMPOSED sell_price (base * World-State multiplier, ≥1).
  select public.trade_effective_price(o.sell_price, v_loc) into v_sell from public.market_offers o
    where o.location_id = v_loc and o.good_id = p_good_id and o.active;
  if v_sell is null then return jsonb_build_object('ok', false, 'reason', 'offer_unavailable'); end if;

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

  if not public.wallet_debit(v_player, v_total) then
    return jsonb_build_object('ok', false, 'reason', 'insufficient_credits', 'price', v_total);
  end if;

  v_lot := public.trade_cargo_add_lot(v_ship, p_good_id, p_qty, v_sell, v_loc);

  insert into public.trade_receipts
    (main_ship_id, request_id, side, good_id, location_id, qty, unit_price, total_price)
    values (v_ship, p_request_id, 'buy', p_good_id, v_loc, p_qty, v_sell, v_total)
    returning receipt_id into v_receipt;

  return jsonb_build_object('ok', true, 'receipt_id', v_receipt, 'lot_id', v_lot,
    'side', 'buy', 'good_id', p_good_id, 'qty', p_qty, 'unit_price', v_sell, 'total_price', v_total,
    'location_id', v_loc);
end;
$$;
revoke execute on function public.market_buy(uuid, text, numeric, uuid) from public, anon;
grant  execute on function public.market_buy(uuid, text, numeric, uuid) to authenticated;

-- ── C. market_sell — EXACTLY the 0136 body; inline docked block → helper call, v_ctx local dropped.
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

  if not public.cfg_bool('trade_market_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'trade_market_disabled');
  end if;

  if p_request_id is null then return jsonb_build_object('ok', false, 'reason', 'invalid_request'); end if;
  if p_good_id   is null then return jsonb_build_object('ok', false, 'reason', 'invalid_good');    end if;
  if p_qty is null or p_qty <= 0 then return jsonb_build_object('ok', false, 'reason', 'invalid_qty'); end if;

  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then return jsonb_build_object('ok', false, 'reason', 'no_ship'); end if;

  perform public.mainship_space_lock_context(v_ship);

  select * into v_existing from public.trade_receipts
    where main_ship_id = v_ship and request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'idempotent_replay', true,
      'receipt_id', v_existing.receipt_id, 'side', v_existing.side, 'good_id', v_existing.good_id,
      'qty', v_existing.qty, 'unit_price', v_existing.unit_price, 'total_price', v_existing.total_price,
      'location_id', v_existing.location_id);
  end if;

  v_loc := public.mainship_resolve_docked_location(v_ship);
  if v_loc is null then return jsonb_build_object('ok', false, 'reason', 'not_docked'); end if;

  -- OFFER: the station's buy_price for this good — COMPOSED (base * World-State multiplier, ≥1).
  select public.trade_effective_price(o.buy_price, v_loc) into v_buy from public.market_offers o
    where o.location_id = v_loc and o.good_id = p_good_id and o.active;
  if v_buy is null then return jsonb_build_object('ok', false, 'reason', 'offer_unavailable'); end if;

  select coalesce(sum(qty), 0) into v_avail from public.ship_cargo_lots
    where main_ship_id = v_ship and good_id = p_good_id;
  if v_avail < p_qty then
    return jsonb_build_object('ok', false, 'reason', 'insufficient_cargo', 'available', v_avail);
  end if;

  v_total := v_buy * p_qty;

  v_cost := public.trade_cargo_consume(v_ship, p_good_id, p_qty);

  perform public.wallet_credit(v_player, v_total);

  insert into public.trade_receipts
    (main_ship_id, request_id, side, good_id, location_id, qty, unit_price, total_price)
    values (v_ship, p_request_id, 'sell', p_good_id, v_loc, p_qty, v_buy, v_total)
    returning receipt_id into v_receipt;

  return jsonb_build_object('ok', true, 'receipt_id', v_receipt,
    'side', 'sell', 'good_id', p_good_id, 'qty', p_qty, 'unit_price', v_buy, 'total_price', v_total,
    'location_id', v_loc, 'cost_basis_consumed', v_cost, 'realized_margin', v_total - v_cost);
end;
$$;
revoke execute on function public.market_sell(uuid, text, numeric, uuid) from public, anon;
grant  execute on function public.market_sell(uuid, text, numeric, uuid) to authenticated;
