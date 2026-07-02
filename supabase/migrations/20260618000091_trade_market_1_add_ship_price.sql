-- Byeharu — TRADE-MARKET-1 §1b: credit-priced additional-ship debit (ships = the first credit sink).
--
-- Now that the Wallet writer exists (0089), commission_additional_main_ship becomes the "first credit sink":
-- it debits a flat, tunable price from player_wallet (via the existing wallet_debit) under the commission
-- advisory lock, before building the ship. This is a small, focused change to the 0C add-ship RPC.
--
-- ── DESIGN DECISION (planner authority; §1b) ─────────────────────────────────────────────────────
-- • `main_ship_price` is a game_config TUNABLE (PLACEHOLDER, balance-non-final — e.g. 1000 credits), tunable
--   without redeploy per the game_config pattern. It is a price knob, NOT a capability flag.
-- • ONLY additional ships are priced; the FIRST-ship path (commission_first_main_ship /
--   port_entry_commission_writer / port_entry_commission_build) is UNCHANGED and FREE.
-- • ATOMICITY via ordering: check flag → advisory lock → cap/count checks → DEBIT price (if wallet_debit
--   returns false → insufficient_credits, and NO debit occurred so it is safe to return) → BUILD. If the build
--   fails AFTER a successful debit, RAISE so the whole transaction (including the debit) rolls back — a plain
--   `return` would COMMIT the debit without a ship. One SECURITY DEFINER function = one transaction.
-- • Capability stays DARK: still gated by mainship_additional_commission_enabled (= false); no flag set true.
--
-- Boundary: commission_additional_main_ship stays Main-Ship-owned (builds via port_entry_commission_build),
-- now debiting via the Wallet writer (Trade Market) — a one-directional call, no cycle, no second writer.

-- 1) main_ship_price tunable (placeholder; balance non-final). game_config numeric-seed idiom (0003).
insert into public.game_config (key, value, description) values
  ('main_ship_price', '1000',
   'TRADE-MARKET-1 §1b: flat credit price for commissioning an ADDITIONAL main ship (first ship is free). '
   'Placeholder — balance non-final; tunable via game_config.')
on conflict (key) do nothing;

-- 2) commission_additional_main_ship — 0080 body; ONLY: + price read, + debit-before-build, + raise-on-post-
--    debit-build-failure, + price in the success payload. Everything else byte-for-byte. ACL preserved by
--    create or replace (authenticated grant from 0080 §E is untouched — no revoke/grant here).
create or replace function public.commission_additional_main_ship()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_cap    int;
  v_count  int;
  v_price  numeric;
  v_res    jsonb;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK server-reject: refuse to create a 2nd ship until a HUMAN gate flips this flag (default false).
  if not public.cfg_bool('mainship_additional_commission_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'additional_commission_disabled');
  end if;

  -- Serialize per-player commission (same primitive as first-ship), then enforce the cap UNDER the lock.
  perform pg_advisory_xact_lock(hashtext('main_ship_commission'), hashtext(v_player::text));
  select coalesce((select (value #>> '{}')::int from public.game_config where key = 'max_main_ships_per_player'), 3)
    into v_cap;
  select count(*) into v_count from public.main_ship_instances where player_id = v_player;

  if v_count = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_first_ship');          -- must use the first-ship path
  elsif v_count >= v_cap then
    return jsonb_build_object('ok', false, 'reason', 'ship_cap_reached', 'cap', v_cap);
  end if;

  -- §1b: ships are the first credit sink. Debit the (tunable, placeholder) additional-ship price UNDER the
  -- advisory lock BEFORE building. wallet_debit is atomic-conditional: false → too poor, NO debit occurred.
  v_price := coalesce((select (value #>> '{}')::numeric from public.game_config where key = 'main_ship_price'), 1000);
  if v_price > 0 and not public.wallet_debit(v_player, v_price) then
    return jsonb_build_object('ok', false, 'reason', 'insufficient_credits', 'price', v_price);
  end if;

  -- Build the ship. A build failure AFTER the debit must ROLL BACK the whole txn (debit included) → raise,
  -- never a plain return (which would commit the debit without a ship).
  v_res := public.port_entry_commission_build(v_player);
  if (v_res->>'created')::boolean is not true then
    raise exception 'commission_additional_main_ship: build failed after wallet debit';
  end if;
  return jsonb_build_object('ok', true, 'created', true, 'docked', true,
                            'main_ship_id', v_res->'main_ship_id', 'location_id', v_res->'location_id',
                            'price', v_price);
end;
$$;
