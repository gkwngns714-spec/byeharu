-- Byeharu — M3b: Movement system.
--
-- OWNERSHIP (docs/SYSTEM_BOUNDARIES.md): sole writer of fleet_movements. Movement
-- ONLY decides when a fleet departs and arrives. It does NOT compute combat, spawn
-- pirates, give rewards, or apply losses. It is reusable by any system (combat
-- return, trading, captain assignment) because it depends on none of them — callers
-- pass coordinates + speed; movement does the geometry/time only.

create table public.fleet_movements (
  id                 uuid primary key default gen_random_uuid(),
  player_id          uuid not null references auth.users (id) on delete cascade,
  fleet_id           uuid not null references public.fleets (id) on delete cascade,

  origin_type        text not null check (origin_type in ('base','location','zone')),
  origin_base_id     uuid references public.bases (id),
  origin_location_id uuid references public.locations (id),
  origin_zone_id     uuid references public.zones (id),
  origin_x           double precision not null,
  origin_y           double precision not null,

  target_type        text not null check (target_type in ('base','location','zone')),
  target_base_id     uuid references public.bases (id),
  target_location_id uuid references public.locations (id),
  target_zone_id     uuid references public.zones (id),
  target_x           double precision not null,
  target_y           double precision not null,

  mission_type       text not null
                       check (mission_type in (
                         'hunt_pirates','return_home','scout','reinforce',
                         'mine','explore','trade','rally')),
  status             text not null default 'moving'
                       check (status in ('moving','arrived','cancelled','failed')),

  depart_at          timestamptz not null default now(),
  arrive_at          timestamptz not null,
  resolved_at        timestamptz,

  travel_distance    double precision not null check (travel_distance >= 0),
  travel_seconds     double precision not null check (travel_seconds > 0),
  speed_used         double precision not null check (speed_used > 0),

  created_at         timestamptz not null default now(),

  check (arrive_at > depart_at)
);

-- One active (in-flight) movement per fleet — a fleet can't be in two places.
create unique index one_active_movement_per_fleet
  on public.fleet_movements (fleet_id) where status = 'moving';
create index fleet_movements_due_idx
  on public.fleet_movements (arrive_at) where status = 'moving';

-- Now that fleet_movements exists, wire the fleets.active_movement_id FK.
alter table public.fleets
  add constraint fleets_active_movement_fk
  foreign key (active_movement_id) references public.fleet_movements (id) on delete set null;

-- ── RLS: owner-read only, no client writes ───────────────────────────────────
alter table public.fleet_movements enable row level security;
create policy "fleet_movements_select_own" on public.fleet_movements
  for select using (player_id = auth.uid());
grant select on public.fleet_movements to authenticated;

-- ── movement_create: server computes distance, travel time, arrival ───────────
-- Caller passes resolved coordinates + the fleet's speed (from fleet_speed()).
-- NEVER trusts client-supplied travel time. Returns the new movement id.
create or replace function public.movement_create(
  p_player          uuid,
  p_fleet           uuid,
  p_origin_type     text,
  p_origin_base     uuid,
  p_origin_zone     uuid,
  p_origin_location uuid,
  p_origin_x        double precision,
  p_origin_y        double precision,
  p_target_type     text,
  p_target_base     uuid,
  p_target_zone     uuid,
  p_target_location uuid,
  p_target_x        double precision,
  p_target_y        double precision,
  p_mission         text,
  p_speed           double precision
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dist    double precision;
  v_seconds double precision;
  v_scale   double precision;
  v_min     double precision;
  v_id      uuid;
begin
  if p_speed is null or p_speed <= 0 then
    raise exception 'movement_create: invalid fleet speed %', p_speed;
  end if;

  v_scale := coalesce(cfg_num('travel_scale'), 1.0);
  v_min   := coalesce(cfg_num('min_travel_seconds'), 1.0);

  v_dist    := sqrt(power(p_target_x - p_origin_x, 2) + power(p_target_y - p_origin_y, 2));
  v_seconds := greatest(v_min, v_dist / p_speed * v_scale);

  insert into fleet_movements (
    player_id, fleet_id,
    origin_type, origin_base_id, origin_zone_id, origin_location_id, origin_x, origin_y,
    target_type, target_base_id, target_zone_id, target_location_id, target_x, target_y,
    mission_type, status, depart_at, arrive_at,
    travel_distance, travel_seconds, speed_used
  ) values (
    p_player, p_fleet,
    p_origin_type, p_origin_base, p_origin_zone, p_origin_location, p_origin_x, p_origin_y,
    p_target_type, p_target_base, p_target_zone, p_target_location, p_target_x, p_target_y,
    p_mission, 'moving', now(), now() + make_interval(secs => v_seconds),
    v_dist, v_seconds, p_speed
  )
  returning id into v_id;

  return v_id;
end;
$$;
