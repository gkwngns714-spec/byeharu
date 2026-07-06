-- Byeharu — TRADE-MARKET-1: DARK gate flag + get_market_offers read RPC (additive; DARK, server-rejected).
--
-- Establishes the flag-gated RPC surface, starting with the READ path so the pattern + dark gate are proven
-- before the atomic writers. Introduces the DARK gate `trade_market_enabled` (default false) — its FIRST
-- consumer — plus the read-only `get_market_offers` RPC. NO wallet/lot/receipt writes here.
--
-- ── TRADE-MARKET-1 DESIGN DECISIONS (planner authority) ──────────────────────────────────────────
-- 1) The WHOLE trading surface (get_market_offers / buy / sell) is DARK + server-rejected via a NEW
--    game_config boolean `trade_market_enabled` (default false). Every trade RPC rejects deterministically
--    when it is false, BEFORE any ship read/lock/query. It is NOT set true here (no human gate crossed).
-- 2) get_market_offers is a READ projection: it validates ownership + docked state via Main-Ship-owned reads
--    and reads Reference/Config `market_offers` — it WRITES NOTHING. The atomic volume-checked buy/sell
--    writers (wallet debit + lot write via Trade Cargo + trade_receipts) land NEXT.
-- 3) Boundary: Trade Market reads via Main Ship (ownership + at_location), reads market_offers (Reference/
--    Config) — a one-directional read fan-out. No cycle, no writer, no second writer to any table.
--    (Reviewer note carried forward: the trade_receipts→main_ship_instances FK on-delete behavior is made
--    explicit when the WRITERS land, in the buy/sell commit — it does not affect this read-only step.)

-- 1) server-owned trade gate (OFF on live). game_config is server-owned (no client write); bool-flag idiom (0070).
insert into public.game_config (key, value, description) values
  ('trade_market_enabled', 'false',
   'TRADE-MARKET-1: server-authoritative gate for the trading surface (get_market_offers/buy/sell). '
   'OFF on live — dark until a human gate flips it.')
on conflict (key) do nothing;

-- 2) get_market_offers — flag-gated, ownership+docked-validated, read-only offer projection for the docked station.
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
  v_ctx    jsonb;
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

  -- the ship must be canonically DOCKED (at_location) — same idiom as get_my_current_dock_services:
  -- validate_context proves fleet + presence + movement coherence, then the dock comes STRICTLY from the
  -- validated present/location fleet's current_location_id (never the client).
  v_ctx := public.mainship_space_validate_context(v_ship);
  if (v_ctx->>'ok')::boolean is not true or (v_ctx->>'state') is distinct from 'at_location' then
    return jsonb_build_object('ok', false, 'reason', 'not_docked');
  end if;
  select f.current_location_id into v_loc
    from public.fleets f
    where f.main_ship_id = v_ship and f.status = 'present' and f.location_mode = 'location'
    limit 1;
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

-- ACL: new function default-grants EXECUTE to PUBLIC on create → revoke, then grant authenticated only.
revoke execute on function public.get_market_offers(uuid) from public, anon;
grant  execute on function public.get_market_offers(uuid) to authenticated;
