-- Byeharu — TRADE-MARKET-1 cleanup: extract the copy-pasted "resolve docked location" block into ONE helper.
--
-- The identical ~10-line docked-location resolve (validate_context → require at_location → read the present/
-- location fleet's current_location_id) was copy-pasted verbatim into get_market_offers (0087), market_buy
-- (0089), and market_sell (0090). This forward-only migration adds ONE shared read-only helper,
-- public.mainship_resolve_docked_location, and repoints all three RPCs to it via create-or-replace. It is
-- BEHAVIOR-IDENTICAL: the helper returns the docked location id or NULL, and each caller maps NULL to the same
-- {ok:false, reason:'not_docked'} it already returned. No flag/behavior change; the feature stays DARK.
--
-- It does NOT edit 0087/0089/0090 — the create-or-replace here supersedes them forward-only. Everything in each
-- function is byte-for-byte the same as its original EXCEPT (a) the inline docked block → the helper call, and
-- (b) the now-unused `v_ctx jsonb;` local is dropped (it was assigned only inside the extracted block; removing
-- dead code keeps the extraction clean and is behavior-identical).
--
-- BOUNDARY (SYSTEM_BOUNDARIES §2/§3): the helper is a Main-Ship-domain read leaf (reads
-- mainship_space_validate_context + fleets; writes nothing). The Trade Market → Main-Ship-reads edge already
-- existed inline; it is now a single named function called DOWNWARD. No new writer, no new table, graph stays
-- acyclic. INTERNAL ACL (revoke from public/anon/authenticated, no grant): it does NOT assert ownership — the
-- orchestrators do that via mainship_resolve_owned_ship BEFORE calling it — so it must never be client-callable
-- (that would leak any ship's dock). Mirrors its true siblings mainship_space_validate_context /
-- mainship_resolve_owned_ship, both revoked from authenticated. Called only inside the SECURITY DEFINER trade
-- RPCs, which run as owner, so the internal ACL does not change any call path.

-- ── A. The shared read-only helper: docked location id, or NULL. ──
create or replace function public.mainship_resolve_docked_location(p_main_ship_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_ctx jsonb;
  v_loc uuid;
begin
  -- The ship must be canonically DOCKED (at_location): validate_context proves fleet + presence + movement
  -- coherence, then the dock comes STRICTLY from the validated present/location fleet's current_location_id
  -- (never the client). Returns the docked location id, or NULL if not at_location or no matching fleet row —
  -- both null paths collapse to one NULL (each caller already returned the same 'not_docked' reason for both).
  v_ctx := public.mainship_space_validate_context(p_main_ship_id);
  if (v_ctx->>'ok')::boolean is not true or (v_ctx->>'state') is distinct from 'at_location' then
    return null;
  end if;
  select f.current_location_id into v_loc
    from public.fleets f
    where f.main_ship_id = p_main_ship_id and f.status = 'present' and f.location_mode = 'location'
    limit 1;
  return v_loc;
end;
$$;
-- INTERNAL: no client grant. Called only from within the SECURITY DEFINER trade orchestrators (they run as
-- owner and assert ownership via mainship_resolve_owned_ship BEFORE this call). It does NOT assert ownership,
-- so it must not be client-callable — mirrors mainship_space_validate_context / mainship_resolve_owned_ship.
revoke execute on function public.mainship_resolve_docked_location(uuid) from public, anon, authenticated;

-- ── B. get_market_offers — 0087 body, docked block → helper call (v_ctx local dropped). ──
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

  -- DARK server-reject: the whole trade surface is gated OFF until a human flips trade_market_enabled.
  -- Reject deterministically BEFORE any ship read/lock/query — no ship/offer access while dark.
  if not public.cfg_bool('trade_market_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'trade_market_disabled');
  end if;

  -- resolve the SELECTED owned ship (explicit p_main_ship_id, ownership asserted) or the sole ship (shim);
  -- UI selection is never trusted. Null (unowned / zero / ambiguous >1) → no_ship.
  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then
    return jsonb_build_object('ok', false, 'reason', 'no_ship');
  end if;

  -- docked-location resolve via the shared helper (was an inline block; behavior-identical).
  v_loc := public.mainship_resolve_docked_location(v_ship);
  if v_loc is null then
    return jsonb_build_object('ok', false, 'reason', 'not_docked');
  end if;

  -- read-only: aggregate this station's ACTIVE offers (Reference/Config market_offers). Writes nothing.
  select coalesce(jsonb_agg(jsonb_build_object(
           'offer_id',   o.offer_id,
           'good_id',    o.good_id,
           'buy_price',  o.buy_price,
           'sell_price', o.sell_price) order by o.good_id), c_empty)
    into v_offers
    from public.market_offers o
    where o.location_id = v_loc and o.active;

  return jsonb_build_object('ok', true, 'main_ship_id', v_ship, 'location_id', v_loc,
                            'offers', coalesce(v_offers, c_empty));
end;
$$;

-- ACL preserved from 0087 (create-or-replace does not reset grants; re-emitted for an explicit posture).
revoke execute on function public.get_market_offers(uuid) from public, anon;
grant  execute on function public.get_market_offers(uuid) to authenticated;

-- ── C. market_buy — 0089 body, docked block → helper call (v_ctx local dropped). ──
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

  -- docked-location resolve via the shared helper (was an inline block; behavior-identical).
  v_loc := public.mainship_resolve_docked_location(v_ship);
  if v_loc is null then
    return jsonb_build_object('ok', false, 'reason', 'not_docked');
  end if;

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
-- ACL preserved from 0089 (authenticated client RPC, server-rejected while dark; helpers stay internal).
revoke execute on function public.market_buy(uuid, text, numeric, uuid) from public, anon;
grant  execute on function public.market_buy(uuid, text, numeric, uuid) to authenticated;

-- ── D. market_sell — 0090 body, docked block → helper call (v_ctx local dropped). ──
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

  -- docked-location resolve via the shared helper (was an inline block; behavior-identical).
  v_loc := public.mainship_resolve_docked_location(v_ship);
  if v_loc is null then
    return jsonb_build_object('ok', false, 'reason', 'not_docked');
  end if;

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
-- ACL preserved from 0090 (authenticated client RPC, server-rejected while dark; helpers stay internal).
revoke execute on function public.market_sell(uuid, text, numeric, uuid) from public, anon;
grant  execute on function public.market_sell(uuid, text, numeric, uuid) to authenticated;
