-- Byeharu — M5: World State tables (location_state, zone_state).
--
-- OWNERSHIP (docs/SYSTEM_BOUNDARIES.md): the World State system is the SOLE writer
-- of location_state + zone_state. These are the dynamic counterpart to the static
-- Map tables (sectors/zones/locations), deliberately deferred until M5 (see
-- 0002_world_map.sql header). Other systems may READ these (Combat reads
-- danger_modifier), but only worldstate_* functions may write them.
--
-- active_fleets is a CACHE for display/perf — the real source of truth is the
-- active location_presence rows; worldstate_tick() reconciles it every tick.

-- ── location_state: one row per location (pressure / danger live here) ────────
create table public.location_state (
  location_id     uuid primary key references public.locations (id) on delete cascade,
  pressure        integer    not null default 50  check (pressure >= 0),     -- 0 calm · 50 normal · 100 severe
  danger_modifier numeric    not null default 1.0 check (danger_modifier > 0),
  active_fleets   integer    not null default 0   check (active_fleets >= 0),
  last_tick_at    timestamptz not null default now(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- ── zone_state: one row per zone (rolled up from its locations each tick) ─────
create table public.zone_state (
  zone_id             uuid primary key references public.zones (id) on delete cascade,
  avg_pressure        numeric    not null default 50,
  avg_danger_modifier numeric    not null default 1.0,
  active_fleets       integer    not null default 0 check (active_fleets >= 0),
  last_tick_at        timestamptz not null default now(),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- ── RLS: public read (previews/UI), NO client write policy ───────────────────
alter table public.location_state enable row level security;
create policy "location_state_public_read" on public.location_state for select using (true);
grant select on public.location_state to anon, authenticated;

alter table public.zone_state enable row level security;
create policy "zone_state_public_read" on public.zone_state for select using (true);
grant select on public.zone_state to anon, authenticated;

-- ── Seed: one state row per existing location / zone (idempotent) ────────────
-- Seeded for ALL locations (not just pirate_hunt) so register/unregister never
-- needs a special case; pressure on a safe zone is simply inert (combat never
-- reads it there). Defaults give pressure = baseline → danger_modifier 1.0.
insert into public.location_state (location_id)
  select id from public.locations
on conflict (location_id) do nothing;

insert into public.zone_state (zone_id)
  select id from public.zones
on conflict (zone_id) do nothing;
