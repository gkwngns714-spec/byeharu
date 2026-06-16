-- Byeharu — M2: World Map (Map system).
--
-- OWNERSHIP (see docs/SYSTEM_BOUNDARIES.md): the Map system is the sole writer of
-- sectors / zones / locations. These are STATIC world structure, seeded here.
-- Map must NOT move fleets, create presence, start combat, give rewards, or touch
-- units/resources. Dynamic state (zone_state/location_state) belongs to the World
-- State system and is intentionally NOT created in this milestone.
--
-- RLS: world map is public-read; there are no write policies, so only the service
-- role / migrations can write (no client writes).

-- ── sectors ────────────────────────────────────────────────────────────────
create table public.sectors (
  id                  uuid primary key default gen_random_uuid(),
  name                text not null,
  sector_index        integer not null unique,
  x                   double precision not null,
  y                   double precision not null,
  danger_tier         integer not null default 1 check (danger_tier >= 1),
  unlock_requirement  text,
  status              text not null default 'active'
                        check (status in ('active', 'locked', 'hidden')),
  created_at          timestamptz not null default now()
);

-- ── zones ──────────────────────────────────────────────────────────────────
create table public.zones (
  id               uuid primary key default gen_random_uuid(),
  sector_id        uuid not null references public.sectors (id) on delete cascade,
  name             text not null,
  x                double precision not null,
  y                double precision not null,
  radius           double precision not null default 1 check (radius > 0),
  base_difficulty  double precision not null default 0 check (base_difficulty >= 0),
  max_danger_level integer not null default 1 check (max_danger_level >= 1),
  reward_tier      integer not null default 1 check (reward_tier >= 0),
  visibility       text not null default 'visible'
                     check (visibility in ('visible', 'hidden', 'scouted')),
  status           text not null default 'active'
                     check (status in ('active', 'locked', 'hidden')),
  created_at       timestamptz not null default now(),
  unique (sector_id, name)
);

create index zones_sector_id_idx on public.zones (sector_id);

-- ── locations ──────────────────────────────────────────────────────────────
create table public.locations (
  id                  uuid primary key default gen_random_uuid(),
  zone_id             uuid not null references public.zones (id) on delete cascade,
  name                text not null,
  location_type       text not null
                        check (location_type in (
                          'pirate_hunt', 'pirate_den', 'mining_site',
                          'derelict_station', 'trade_outpost', 'rally_point',
                          'safe_zone', 'event_site')),
  x                   double precision not null,
  y                   double precision not null,
  base_difficulty     double precision not null default 0 check (base_difficulty >= 0),
  reward_tier         integer not null default 1 check (reward_tier >= 0),
  activity_type       text not null default 'none'
                        check (activity_type in (
                          'hunt_pirates', 'mine_resource', 'explore_derelict',
                          'trade_visit', 'rally', 'none')),
  min_power_required  double precision not null default 0 check (min_power_required >= 0),
  max_presence_seconds integer check (max_presence_seconds is null or max_presence_seconds > 0),
  is_public           boolean not null default true,
  status              text not null default 'active'
                        check (status in ('active', 'locked', 'hidden')),
  created_at          timestamptz not null default now(),
  unique (zone_id, name)
);

create index locations_zone_id_idx on public.locations (zone_id);

-- ── RLS: public read, no client writes ───────────────────────────────────────
alter table public.sectors   enable row level security;
alter table public.zones     enable row level security;
alter table public.locations enable row level security;

create policy "sectors_public_read"   on public.sectors   for select using (true);
create policy "zones_public_read"      on public.zones      for select using (true);
create policy "locations_public_read"  on public.locations  for select using (true);

-- ── get_world_map(): nested read of the static world (display fields only) ────
create or replace function public.get_world_map()
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'sectors',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', se.id, 'name', se.name, 'sector_index', se.sector_index,
          'x', se.x, 'y', se.y, 'danger_tier', se.danger_tier, 'status', se.status,
          'zones', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'id', z.id, 'name', z.name, 'x', z.x, 'y', z.y, 'radius', z.radius,
                'base_difficulty', z.base_difficulty,
                'max_danger_level', z.max_danger_level,
                'reward_tier', z.reward_tier, 'visibility', z.visibility,
                'status', z.status,
                'locations', coalesce((
                  select jsonb_agg(
                    jsonb_build_object(
                      'id', l.id, 'name', l.name, 'location_type', l.location_type,
                      'x', l.x, 'y', l.y, 'base_difficulty', l.base_difficulty,
                      'reward_tier', l.reward_tier, 'activity_type', l.activity_type,
                      'min_power_required', l.min_power_required,
                      'is_public', l.is_public, 'status', l.status
                    ) order by l.name)
                  from public.locations l
                  where l.zone_id = z.id and l.status = 'active'
                ), '[]'::jsonb)
              ) order by z.name)
            from public.zones z
            where z.sector_id = se.id and z.status = 'active'
          ), '[]'::jsonb)
        ) order by se.sector_index)
      from public.sectors se
      where se.status = 'active'
    ), '[]'::jsonb)
  );
$$;

grant execute on function public.get_world_map() to anon, authenticated;

-- ── Seed data (static world) ─────────────────────────────────────────────────
insert into public.sectors (name, sector_index, x, y, danger_tier) values
  ('Outer Haven',    1,   0,   0, 1),
  ('Crimson Nebula', 2,  30,  20, 2)
on conflict (sector_index) do nothing;

insert into public.zones (sector_id, name, x, y, radius, base_difficulty, max_danger_level, reward_tier)
select s.id, v.name, v.x, v.y, v.radius, v.base_difficulty, v.max_danger_level, v.reward_tier
from (values
  (1, 'Wreck Belt',      10.0,  5.0, 5.0, 10.0, 5, 1),
  (2, 'Ion Storm Route', 32.0, 22.0, 6.0, 20.0, 8, 2)
) as v(sector_index, name, x, y, radius, base_difficulty, max_danger_level, reward_tier)
join public.sectors s on s.sector_index = v.sector_index
on conflict (sector_id, name) do nothing;

insert into public.locations
  (zone_id, name, location_type, x, y, base_difficulty, reward_tier, activity_type, min_power_required)
select z.id, v.name, v.location_type, v.x, v.y, v.base_difficulty, v.reward_tier, v.activity_type, v.min_power_required
from (values
  ('Wreck Belt',      'Safe Rally Point',    'safe_zone',   11.0,  5.0,  0.0, 0, 'none',         0.0),
  ('Wreck Belt',      'Pirate Ambush Point', 'pirate_hunt', 12.0,  6.0, 10.0, 1, 'hunt_pirates', 0.0),
  ('Wreck Belt',      'Raider Outpost',      'pirate_hunt',  9.0,  4.0, 15.0, 2, 'hunt_pirates', 0.0),
  ('Ion Storm Route', 'Quiet Drift',         'safe_zone',   31.0, 22.0,  0.0, 0, 'none',         0.0),
  ('Ion Storm Route', 'Pirate Den',          'pirate_hunt', 33.0, 23.0, 25.0, 3, 'hunt_pirates', 0.0)
) as v(zone_name, name, location_type, x, y, base_difficulty, reward_tier, activity_type, min_power_required)
join public.zones z on z.name = v.zone_name
on conflict (zone_id, name) do nothing;
