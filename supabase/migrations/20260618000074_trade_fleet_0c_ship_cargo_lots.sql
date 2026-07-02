-- Byeharu — TRADE-FLEET-0C: ship_cargo_lots (per-ship locality anchor; additive ONLY).
--
-- Second additive step of Trading V1: the per-ship cargo table. Purely additive — a new
-- table with FKs to the now-existing `trade_goods` (good catalog, 0073) and to
-- `main_ship_instances` (the Main Ship system). It adds NOTHING to combat, production,
-- fleets, movement, and does NOT touch the instance/hull capacity columns, the
-- `player_id UNIQUE` constraint, or any command signature — those coordinated changes are
-- the next 0C sub-slice.
--
-- DESIGN LAW (TRADE-FLEET-0B §2.4, 0A §2–§3): cargo is KEYED BY `main_ship_id`, NEVER
-- `player_id`. Player identity is derived THROUGH the ship (`main_ship_instances.player_id`),
-- never stored redundantly — there is no account-scoped trade read. Per-ship occupied
-- volume is the LOT SUM (`sum(qty * trade_goods.unit_volume_m3)` over a ship's lots),
-- computed under the ship lock at trade time — it is NEVER cached on the instance, so no
-- second writer to `main_ship_instances` is introduced. Per-lot `unit_cost_basis` (§1d) is
-- the source of truth for cost; no weighted-average running figure exists.
--
-- OWNERSHIP (SYSTEM_BOUNDARIES): ship_cargo_lots = Trade Cargo (new system) — sole writer.
-- Owner-read only (via join to `main_ship_instances.player_id`). This table is DARK: no
-- writer exists yet. Trade Cargo's SECURITY DEFINER write RPCs arrive in TRADE-MARKET-1;
-- NONE this step. No client write path (no insert/update/delete policy or grant).

create table if not exists public.ship_cargo_lots (
  lot_id             uuid    primary key default gen_random_uuid(),
  main_ship_id       uuid    not null references public.main_ship_instances (main_ship_id),  -- NEVER player_id
  good_id            text    not null references public.trade_goods (good_id),
  qty                numeric not null check (qty > 0),                 -- in denomination units
  unit_cost_basis    numeric not null check (unit_cost_basis >= 0),    -- per-lot cost basis (§1d)
  origin_location_id uuid    references public.locations (id),         -- locations PK is `id` (not `location_id`)
  acquired_at        timestamptz not null default now()
);

-- Every occupied-volume computation and per-ship lookup filters on main_ship_id.
create index if not exists ship_cargo_lots_main_ship_id_idx on public.ship_cargo_lots (main_ship_id);

alter table public.ship_cargo_lots enable row level security;
-- Owner-read only: a lot is visible to the player who owns the ship it hangs on. Join to
-- main_ship_instances (owner-scoping idiom `player_id = auth.uid()`); no direct player_id
-- column to leak a pooled read. NO insert/update/delete policy and NO write grant → clients
-- cannot mutate. Owner data — granted to authenticated only, NOT anon/public.
create policy "ship_cargo_lots_select_own" on public.ship_cargo_lots
  for select using (
    exists (
      select 1 from public.main_ship_instances m
      where m.main_ship_id = ship_cargo_lots.main_ship_id
        and m.player_id = auth.uid()
    )
  );
grant select on public.ship_cargo_lots to authenticated;
