-- Byeharu — M4: Combat tables (Combat system, sole writer).
--
--   combat_encounters = the whole battle (attached to location_presence)
--   combat_ticks      = one 2s server-authoritative simulation step (the truth/log)
--   combat_events     = cosmetic visual stream generated from each tick (NOT truth)
--
-- All owner-read via player_id; no client writes (writes via SECURITY DEFINER fns).

-- ── combat_encounters ────────────────────────────────────────────────────────
create table public.combat_encounters (
  id                  uuid primary key default gen_random_uuid(),
  player_id           uuid not null references auth.users (id) on delete cascade,
  fleet_id            uuid not null references public.fleets (id) on delete cascade,
  presence_id         uuid not null references public.location_presence (id) on delete cascade,
  location_id         uuid references public.locations (id),
  status              text not null default 'active'
                        check (status in ('active','retreating','escaped','defeat','completed')),
  tick_number         integer not null default 0 check (tick_number >= 0),
  danger_level        integer not null default 1 check (danger_level >= 1),
  waves_cleared       integer not null default 0 check (waves_cleared >= 0),
  player_power_start  double precision not null default 0,
  player_power_current double precision not null default 0,
  enemy_power_current double precision not null default 0,
  total_rewards_json  jsonb not null default '{}'::jsonb,
  started_at          timestamptz not null default now(),
  last_resolved_at    timestamptz,
  ended_at            timestamptz,
  report_created_at   timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index combat_encounters_active_idx on public.combat_encounters (status)
  where status in ('active','retreating');
-- One active encounter per fleet and per presence.
create unique index one_active_encounter_per_fleet
  on public.combat_encounters (fleet_id) where status in ('active','retreating');
create unique index one_active_encounter_per_presence
  on public.combat_encounters (presence_id) where status in ('active','retreating');

-- ── combat_ticks (authoritative per-step log) ────────────────────────────────
create table public.combat_ticks (
  id                  bigint generated always as identity primary key,
  encounter_id        uuid not null references public.combat_encounters (id) on delete cascade,
  player_id           uuid not null,
  tick_number         integer not null,
  danger_level        integer not null,
  player_power_before double precision not null default 0,
  enemy_power         double precision not null default 0,
  player_damage       double precision not null default 0,
  enemy_damage        double precision not null default 0,
  player_losses_json  jsonb not null default '{}'::jsonb,
  pirate_losses_json  jsonb not null default '{}'::jsonb,
  reward_delta_json   jsonb not null default '{}'::jsonb,
  result              text not null
                        check (result in ('ongoing','wave_cleared','retreat_started',
                                          'escaped','defeat','completed')),
  resolved_at         timestamptz not null default now(),
  unique (encounter_id, tick_number)
);
create index combat_ticks_encounter_idx on public.combat_ticks (encounter_id, tick_number);

-- ── combat_events (cosmetic visual stream) ───────────────────────────────────
create table public.combat_events (
  id               bigint generated always as identity primary key,
  encounter_id     uuid not null references public.combat_encounters (id) on delete cascade,
  player_id        uuid not null,
  tick_number      integer not null,
  seq              integer not null default 0,
  event_type       text not null
                     check (event_type in (
                       'missile_salvo','laser_burst','shield_hit','hull_damage',
                       'explosion','unit_destroyed','wave_spawned',
                       'retreat_started','retreat_completed')),
  source           text,
  target           text,
  projectile_type  text,
  projectile_count integer,
  impact_delay_ms  integer,
  payload_json     jsonb not null default '{}'::jsonb,
  created_at       timestamptz not null default now()
);
create index combat_events_encounter_idx on public.combat_events (encounter_id, id);

-- ── RLS: owner-read only, no client writes ───────────────────────────────────
alter table public.combat_encounters enable row level security;
alter table public.combat_ticks      enable row level security;
alter table public.combat_events     enable row level security;

create policy "combat_encounters_select_own" on public.combat_encounters
  for select using (player_id = auth.uid());
create policy "combat_ticks_select_own" on public.combat_ticks
  for select using (player_id = auth.uid());
create policy "combat_events_select_own" on public.combat_events
  for select using (player_id = auth.uid());

grant select on public.combat_encounters, public.combat_ticks, public.combat_events to authenticated;
