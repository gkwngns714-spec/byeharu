-- Byeharu — M3a: unit_types catalog (Reference system).
--
-- OWNERSHIP: static unit definitions. The SERVER is the authority for unit stats;
-- the client may mirror these for previews only. Public read, no client writes.
-- id is the unit code (stable, human-readable) used as the FK target elsewhere.

create table public.unit_types (
  id                 text primary key,
  name               text not null,
  attack             double precision not null default 0 check (attack  >= 0),
  defense            double precision not null default 0 check (defense >= 0),
  hull               double precision not null default 1 check (hull    >  0),
  speed              double precision not null check (speed > 0),
  cargo              double precision not null default 0 check (cargo   >= 0),
  power_score        double precision not null default 0 check (power_score >= 0),
  build_time_seconds integer not null default 0 check (build_time_seconds >= 0),
  status             text not null default 'active' check (status in ('active', 'disabled')),
  created_at         timestamptz not null default now()
);

alter table public.unit_types enable row level security;
create policy "unit_types_public_read" on public.unit_types for select using (true);
grant select on public.unit_types to anon, authenticated;

-- Seed the starter roster. Slowest unit's speed governs fleet travel time, so
-- frigates are strong but slow (the "fast & weak vs slow & strong" choice).
insert into public.unit_types
  (id, name, attack, defense, hull, speed, cargo, power_score, build_time_seconds) values
  ('scout',    'Scout',     5,  3,  20, 10, 10,  10, 30),
  ('corvette', 'Corvette', 15, 10,  60,  8, 20,  35, 90),
  ('frigate',  'Frigate',  40, 30, 200,  5, 50, 120, 300)
on conflict (id) do nothing;
