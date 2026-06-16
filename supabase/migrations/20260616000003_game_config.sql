-- Byeharu — M3a: game_config (Reference/Config system).
--
-- OWNERSHIP (docs/SYSTEM_BOUNDARIES.md): tunable balance values. Writes are
-- admin/migration only; clients get public read for previews. No game-logic here.

create table public.game_config (
  key         text primary key,
  value       jsonb not null,
  description text,
  updated_at  timestamptz not null default now()
);

alter table public.game_config enable row level security;
create policy "game_config_public_read" on public.game_config for select using (true);
grant select on public.game_config to anon, authenticated;

-- Numeric accessor used by server systems (e.g. movement travel time).
create or replace function public.cfg_num(p_key text)
returns double precision
language sql
stable
as $$
  select (value #>> '{}')::double precision
  from public.game_config
  where key = p_key;
$$;

insert into public.game_config (key, value, description) values
  ('travel_scale',          '1.0',  'multiplier applied to computed travel seconds'),
  ('min_travel_seconds',    '5',    'floor on travel time so trips are never instant'),
  ('max_active_fleets',     '3',    'max concurrent non-idle fleets per player'),
  ('movement_tick_seconds', '30',   'cron cadence for process_fleet_movements()'),
  ('combat_tick_seconds',   '12',   'cron cadence for process_combat_ticks() (M4)'),
  ('retreat_delay_seconds', '30',   'retreat delay before return movement (M4)'),
  ('reward_multiplier',     '1.0',  'global reward multiplier (M4)'),
  ('combat_variance',       '0.1',  'random +/- fraction on combat damage (M4)')
on conflict (key) do nothing;
