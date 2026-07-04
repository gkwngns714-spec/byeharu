-- Byeharu — WORLD-BALANCE-P19 SLICE 2: PRICE DRIFT (dark-gated; one coherent producer+consumer slice).
--
-- Phase 19 second mechanic. Prices at a station now BREATHE with local danger — but `market_offers`
-- stays STATIC Reference/Config (NO runtime writer). Drift is NEW World-State-owned state, FOLDED into
-- the existing World-State-owned `location_state` (the tick already iterates it — no parallel table),
-- and COMPOSED with the static base price at read/transaction time. Producer (the tick writes the
-- multiplier) and consumer (all three Trade Market functions read it through one composition helper)
-- ship together in this ONE revertible commit, so nothing is dead.
--
-- GROUNDED IN THE REAL CODE (read first, not guessed):
--   · `location_state` (0031) is the World-State-owned per-location row the 60s tick iterates.
--   · post-0135 `worldstate_tick()` decays `pressure` toward `baseline + gated danger_term`, clamped
--     to [min,max]; `world_balance_enabled` (0135) is the Phase-19 master gate.
--   · `get_market_offers` (0087) displays `market_offers.buy_price`/`sell_price`; `market_buy` (0089)
--     charges `sell_price`; `market_sell` (0090) pays `buy_price`. All three resolve the docked
--     location `v_loc` inline (`mainship_space_validate_context` + the present/location fleet), which is
--     preserved verbatim — only the PRICE read is composed.
--
-- DESIGN (self-approved; "world-state owns world-state" + no-second-writer / no-cycle):
--   1. NO runtime writer to `market_offers` — it stays static Reference/Config, the SOLE source of the
--      BASE price. Drift is composed on top at read time; the composed value is the ONLY price the
--      player ever sees OR is charged/paid (no drift-vs-transaction exploit).
--   2. FOLD drift into `location_state`: ONE new column `price_multiplier numeric not null default 1.0
--      check (> 0)`. `add column … default 1.0 not null` backfills every existing row to a no-op 1.0.
--      World State stays the SOLE writer of `location_state` — only the tick writes this column.
--   3. Drive it in `worldstate_tick()`, gated by `world_balance_enabled`, with STEP 1's
--      target-based / bounded / self-correcting philosophy: the multiplier nudges toward
--        target = 1.0 + world_balance_price_pressure_coeff * normalized_pressure
--        normalized_pressure = clamp((pressure - baseline)/(max - baseline), 0, 1)   [reuses the
--          existing baseline/max pressure config — NOT duplicated]
--      by `world_balance_price_drift_rate` per applied tick, hard-clamped to
--      [world_balance_price_multiplier_min, world_balance_price_multiplier_max]. While the flag is
--      false the tick does NOT touch the column (stays 1.0) and NONE of the normalized/premium math
--      runs — so the tick stays BYTE-IDENTICAL while dark (STEP 1's guarantee extended).
--   4. ONE World-State read helper `worldstate_current_price_multiplier(loc)` — flag-gated: returns
--      1.0 while dark (the provable dark guarantee, independent of the stored column), else the row's
--      `price_multiplier` (1.0 if no row). Internal/service-role (the World State read idiom).
--   5. ONE shared Trade Market composition helper `trade_effective_price(base, loc)` =
--      greatest(1, round(base * worldstate_current_price_multiplier(loc))) — integer credits, never
--      zero/negative (the ≥1 floor + round rule decided HERE, once). ALL THREE trade functions route
--      every price through it, so display == charged/paid always, single-sourced in one place.
--
-- OWNERSHIP / ACYCLICITY (docs/SYSTEM_BOUNDARIES.md, synced SAME step):
--   · World State remains the SOLE writer of `location_state` (tick writes the new column); Trade
--     Market only READS the multiplier via `worldstate_current_price_multiplier`. NEW edge:
--     Trade Market → World State (read) — DOWNWARD and ACYCLIC: World State reads only its own
--     `location_state` + `combat_reports` (0135) and NEVER reads Trade Market, so no cycle. NO new
--     edge into `market_offers` (still static, no runtime writer, no second writer).
--
-- CONFIG (all consumed this slice — no dead config; reuse `world_balance_enabled`, do NOT re-seed):
--   world_balance_price_pressure_coeff='0.5'   (up to +50% premium at max danger)
--   world_balance_price_drift_rate='0.1'       (10%/tick toward target — breathes, never jumps)
--   world_balance_price_multiplier_min='0.5'   (hard floor)
--   world_balance_price_multiplier_max='2.0'   (hard ceiling)
--
-- RETIREMENT / ACTIVATION: same as 0135 — `world_balance_enabled` is the permanent Phase-19 gate.
-- Lit-path verification (flag on a DEV DB → drive the tick under danger → multiplier breathes toward
-- the bounded target → composed buy/sell prices track it → display == charged/paid) is deferred to the
-- human's activation checklist. This migration flips NO flag.

-- ── (a) config: the drift tunables (all NEW, all consumed this slice) ─────────────────────────────
insert into public.game_config (key, value, description) values
  ('world_balance_price_pressure_coeff', '0.5',
   'WORLD-BALANCE-P19 (price drift): danger premium coefficient. The price multiplier target is '
   '1.0 + this * normalized_pressure, so at max danger the target is +50%. Only used when '
   'world_balance_enabled=true.'),
  ('world_balance_price_drift_rate', '0.1',
   'WORLD-BALANCE-P19 (price drift): fraction of the gap to the target the multiplier closes each '
   'applied tick (0<rate<=1; asymptotes, never overshoots). Only used when world_balance_enabled=true.'),
  ('world_balance_price_multiplier_min', '0.5',
   'WORLD-BALANCE-P19 (price drift): hard floor on location_state.price_multiplier (the tick clamps to '
   'this). > 0 so composed prices stay positive. Only used when world_balance_enabled=true.'),
  ('world_balance_price_multiplier_max', '2.0',
   'WORLD-BALANCE-P19 (price drift): hard ceiling on location_state.price_multiplier (the tick clamps '
   'to this — a bounded premium, never runaway). Only used when world_balance_enabled=true.')
on conflict (key) do nothing;

-- ── (b) location_state: fold in the World-State-owned price multiplier (backfills to a no-op 1.0) ──
alter table public.location_state
  add column if not exists price_multiplier numeric not null default 1.0 check (price_multiplier > 0);

comment on column public.location_state.price_multiplier is
  'WORLD-BALANCE-P19: World-State-owned market price multiplier for this location (SOLE writer = '
  'worldstate_tick). Composed with the static market_offers base price at read/transaction time via '
  'trade_effective_price. 1.0 = no drift. DARK/no-op while world_balance_enabled=false (the tick never '
  'touches it, and worldstate_current_price_multiplier returns 1.0 regardless of the stored value).';

-- ── (c) worldstate_tick: EXACTLY the 0135 body except a flag-gated price_multiplier drift ──────────
-- Every unchanged line is byte-for-byte 0135. Differences: the four price-drift config locals + the
-- drift locals (v_new_mult/v_norm/v_mult_target), the gated multiplier computation inside the existing
-- `if v_drifted`/`if v_wb_enabled` structure, and `price_multiplier = case when v_wb_enabled …` in the
-- UPDATE (the 0135 `last_tick_at` self-assign idiom → untouched while dark).
create or replace function public.worldstate_tick()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_min        double precision := coalesce(cfg_num('worldstate_pressure_min'), 0);
  v_max        double precision := coalesce(cfg_num('worldstate_pressure_max'), 100);
  v_baseline   double precision := coalesce(cfg_num('worldstate_pressure_baseline'), 50);
  v_decay_rate double precision := coalesce(cfg_num('worldstate_pressure_decay_rate'), 0.1);
  v_relief     double precision := coalesce(cfg_num('worldstate_pressure_relief_per_active_fleet'), 3);
  v_min_mod    double precision := coalesce(cfg_num('worldstate_danger_min_modifier'), 0.95);
  v_max_mod    double precision := coalesce(cfg_num('worldstate_danger_max_modifier'), 1.20);
  v_min_secs   double precision := coalesce(cfg_num('worldstate_min_tick_seconds'), 30);
  -- Phase-19 pirate pressure (dark unless world_balance_enabled). Resolved once per tick. (0135)
  v_wb_enabled    boolean          := coalesce(cfg_bool('world_balance_enabled'), false);
  v_defeat_inc    double precision := coalesce(cfg_num('worldstate_pressure_defeat_increase'), 4);      -- reused 0032 key
  v_defeat_window double precision := coalesce(cfg_num('world_balance_defeat_window_seconds'), 3600);   -- 0135 tunable
  -- Phase-19 price drift (dark unless world_balance_enabled). Reuses baseline/max above. (0136)
  v_price_coeff   double precision := coalesce(cfg_num('world_balance_price_pressure_coeff'), 0.5);
  v_price_rate    double precision := coalesce(cfg_num('world_balance_price_drift_rate'), 0.1);
  v_mult_min      double precision := coalesce(cfg_num('world_balance_price_multiplier_min'), 0.5);
  v_mult_max      double precision := coalesce(cfg_num('world_balance_price_multiplier_max'), 2.0);
  r            location_state%rowtype;
  v_real       integer;
  v_elapsed    double precision;
  v_drifted    boolean;
  v_pressure   double precision;
  v_decay      double precision;
  v_defeats    integer;
  v_danger_term double precision;
  v_target     double precision;
  v_norm       double precision;
  v_mult_target double precision;
  v_new_mult   numeric;
  v_mod        double precision;
  v_count      integer := 0;
begin
  for r in select * from location_state for update skip locked loop
    -- (1) Reconcile active_fleets from the source of truth (active presences).
    select count(*) into v_real
      from location_presence
      where location_id = r.location_id and status in ('active','retreating','leaving');

    v_elapsed  := extract(epoch from (now() - r.last_tick_at));
    v_pressure := r.pressure;
    v_drifted  := v_elapsed >= v_min_secs;
    v_new_mult := r.price_multiplier;   -- unchanged unless the gated branch below recomputes it

    -- (2) Apply the passive change only when enough time has passed → double-call is a no-op
    --     (idempotent). Pressure decays toward a TARGET: `baseline + danger_term`. The danger term is
    --     0 (target = baseline, the exact 0034 behavior) UNLESS world_balance_enabled — then it rises
    --     with recent DEFEATS at this location (read DOWNWARD from combat_reports history, read-only).
    --     Being a target (not an accumulator) it is self-correcting and stays bounded by the cap below.
    if v_drifted then
      v_danger_term := 0;
      if v_wb_enabled then
        select count(*) into v_defeats
          from combat_reports
          where location_id = r.location_id
            and result = 'defeat'
            and created_at >= now() - make_interval(secs => v_defeat_window);
        v_danger_term := coalesce(v_defeats, 0) * v_defeat_inc;
      end if;
      v_target   := v_baseline + v_danger_term;
      -- Decay a fraction of the gap to target, so it asymptotes and NEVER overshoots
      -- (decay_rate in (0,1]). Active fleets still relieve pressure (can push below target).
      v_decay    := (v_target - v_pressure) * v_decay_rate;
      v_pressure := v_pressure + v_decay - (v_real * v_relief);
      v_pressure := least(v_max, greatest(v_min, v_pressure));

      -- (2b) PRICE DRIFT (0136): the market price multiplier breathes toward a bounded danger premium.
      --      ALL of this runs ONLY when world_balance_enabled — while dark, v_new_mult stays the row's
      --      current value and the column is left untouched (see the UPDATE case), so the tick's output
      --      is byte-identical to pre-slice. Same target-based / self-correcting / clamped philosophy
      --      as pressure. normalized_pressure reuses the SAME baseline/max (no duplicated config).
      if v_wb_enabled then
        v_norm        := least(1, greatest(0, (v_pressure - v_baseline) / nullif(v_max - v_baseline, 0)));
        v_mult_target := 1.0 + v_price_coeff * coalesce(v_norm, 0);
        v_new_mult    := r.price_multiplier + (v_mult_target - r.price_multiplier) * v_price_rate;
        v_new_mult    := least(v_mult_max, greatest(v_mult_min, v_new_mult));
      end if;
    end if;

    -- (3) Danger modifier from pressure — piecewise so baseline maps to exactly
    --     1.0. Bounded both ends. (Unchanged from 0032/0034/0135.)
    if v_pressure >= v_baseline then
      v_mod := 1.0 + ((v_pressure - v_baseline) / nullif(v_max - v_baseline, 0)) * (v_max_mod - 1.0);
    else
      v_mod := v_min_mod + ((v_pressure - v_min) / nullif(v_baseline - v_min, 0)) * (1.0 - v_min_mod);
    end if;
    v_mod := least(v_max_mod, greatest(v_min_mod, coalesce(v_mod, 1.0)));

    update location_state set
      active_fleets    = v_real,
      pressure         = round(v_pressure)::integer,
      danger_modifier  = v_mod,
      -- DARK guarantee: while world_balance_enabled=false the column is left exactly as-is (the 0135
      -- `last_tick_at` self-assign idiom) — no drift math ran, so the multiplier stays 1.0.
      price_multiplier = case when v_wb_enabled then v_new_mult else price_multiplier end,
      last_tick_at     = case when v_drifted then now() else last_tick_at end,
      updated_at       = now()
    where location_id = r.location_id;

    v_count := v_count + 1;
  end loop;

  -- (4) Roll up zone_state from its member locations. (Unchanged from 0032/0034/0135.)
  update zone_state z set
    avg_pressure        = sub.avg_p,
    avg_danger_modifier = sub.avg_d,
    active_fleets       = sub.sum_f,
    last_tick_at        = now(),
    updated_at          = now()
  from (
    select l.zone_id,
           avg(ls.pressure)        as avg_p,
           avg(ls.danger_modifier) as avg_d,
           coalesce(sum(ls.active_fleets), 0) as sum_f
    from location_state ls
    join locations l on l.id = ls.location_id
    group by l.zone_id
  ) sub
  where z.zone_id = sub.zone_id;

  return v_count;
end;
$$;

-- Re-assert anti-cheat lockdown for the replaced function (CREATE OR REPLACE keeps the prior ACL; the
-- 0034/0135 precedent). Server/cron + the service-role test runner only; never clients.
revoke execute on function public.worldstate_tick() from public, anon, authenticated;
grant execute on function public.worldstate_tick() to service_role;

-- ── (d) worldstate_current_price_multiplier: the World-State read helper (flag-gated; internal) ────
-- Returns 1.0 while dark REGARDLESS of the stored column (the provable dark guarantee); else the
-- location's clamped multiplier (default 1.0 if no location_state row). World State reads its OWN
-- location_state — no cross-system read. Service-role/internal (the World State read idiom).
create or replace function public.worldstate_current_price_multiplier(p_location uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select case
           when not coalesce(public.cfg_bool('world_balance_enabled'), false) then 1.0::numeric
           else coalesce(
             (select ls.price_multiplier from public.location_state ls where ls.location_id = p_location),
             1.0::numeric)
         end;
$$;
revoke execute on function public.worldstate_current_price_multiplier(uuid) from public, anon, authenticated;
grant  execute on function public.worldstate_current_price_multiplier(uuid) to service_role;

-- ── (e) trade_effective_price: the ONE Trade Market price-composition helper (internal) ────────────
-- The single place the static base price is composed with the World-State multiplier. Integer credits,
-- floored at 1 (never zero/negative). Called by all three trade functions so display == charged/paid.
create or replace function public.trade_effective_price(p_base_price numeric, p_location uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select greatest(1, round(p_base_price * public.worldstate_current_price_multiplier(p_location)));
$$;
revoke execute on function public.trade_effective_price(numeric, uuid) from public, anon, authenticated;

-- ── (f) get_market_offers: compose BOTH displayed prices through trade_effective_price ─────────────
-- EXACTLY the 0087 body except the two displayed prices are now composed (so what the player sees is
-- what buy/sell will charge/pay). While dark the multiplier is 1.0 → composed = round(base) = the base
-- integer prices; display is unchanged. Docking resolution / dark gate / grants all preserved verbatim.
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

  if not public.cfg_bool('trade_market_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'trade_market_disabled');
  end if;

  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then
    return jsonb_build_object('ok', false, 'reason', 'no_ship');
  end if;

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

-- ── (g) market_buy: charge the COMPOSED sell_price ─────────────────────────────────────────────────
-- EXACTLY the 0089 body except the offer price read is composed via trade_effective_price. Everything
-- downstream (v_total, unit_cost_basis lot, receipt unit_price) uses the composed integer automatically,
-- so the charged price == the displayed price. offer_unavailable still fires on no row (v_sell null).
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

  v_ctx := public.mainship_space_validate_context(v_ship);
  if (v_ctx->>'ok')::boolean is not true or (v_ctx->>'state') is distinct from 'at_location' then
    return jsonb_build_object('ok', false, 'reason', 'not_docked');
  end if;
  select f.current_location_id into v_loc
    from public.fleets f
    where f.main_ship_id = v_ship and f.status = 'present' and f.location_mode = 'location'
    limit 1;
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

-- ── (h) market_sell: pay the COMPOSED buy_price ────────────────────────────────────────────────────
-- EXACTLY the 0090 body except the offer price read is composed via trade_effective_price. The paid
-- price == the displayed price; realized_margin uses the composed total automatically.
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

  v_ctx := public.mainship_space_validate_context(v_ship);
  if (v_ctx->>'ok')::boolean is not true or (v_ctx->>'state') is distinct from 'at_location' then
    return jsonb_build_object('ok', false, 'reason', 'not_docked');
  end if;
  select f.current_location_id into v_loc
    from public.fleets f
    where f.main_ship_id = v_ship and f.status = 'present' and f.location_mode = 'location'
    limit 1;
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
