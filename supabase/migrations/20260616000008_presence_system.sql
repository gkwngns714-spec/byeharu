-- Byeharu — M3b: Presence system.
--
-- OWNERSHIP (docs/SYSTEM_BOUNDARIES.md): sole writer of location_presence. Presence
-- only describes "this fleet is currently at this location and exposed to its
-- rules." It does NOT calculate combat damage or grant resources. It routes the
-- location's activity via activity_start(); for M3 the only activity is 'none'.
-- The 'hunt_pirates' branch is the extension point Combat (M4) plugs into.

create table public.location_presence (
  id                  uuid primary key default gen_random_uuid(),
  player_id           uuid not null references auth.users (id) on delete cascade,
  fleet_id            uuid not null references public.fleets (id) on delete cascade,
  sector_id           uuid references public.sectors (id),
  zone_id             uuid references public.zones (id),
  location_id         uuid references public.locations (id),

  activity_type       text not null default 'none'
                        check (activity_type in (
                          'hunt_pirates','mine_resource','explore_derelict','trade_visit','rally','none')),
  status              text not null default 'active'
                        check (status in ('active','retreating','leaving','completed','destroyed','expired')),

  entered_at          timestamptz not null default now(),
  last_tick_at        timestamptz,
  danger_level        integer not null default 1 check (danger_level >= 1),
  waves_cleared       integer not null default 0 check (waves_cleared >= 0),

  retreat_requested_at timestamptz,
  leave_requested_at   timestamptz,
  forced_exit_at       timestamptz,
  expires_at           timestamptz,

  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index location_presence_location_idx on public.location_presence (location_id);

-- One active presence per fleet — a fleet can't be present in two places at once.
create unique index one_active_presence_per_fleet
  on public.location_presence (fleet_id)
  where status in ('active','retreating','leaving');

-- ── RLS: owner-read only, no client writes ───────────────────────────────────
alter table public.location_presence enable row level security;
create policy "location_presence_select_own" on public.location_presence
  for select using (player_id = auth.uid());
grant select on public.location_presence to authenticated;

-- ── Activity router (extension point) ─────────────────────────────────────────
-- 'none' = nothing happens (safe zone). Future activities (combat/mining/trade)
-- register here without movement or presence needing to know about them.
create or replace function public.activity_start(p_presence uuid, p_activity text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_activity = 'none' then
    return;  -- safe zone: just be present
  elsif p_activity = 'hunt_pirates' then
    -- M4: perform combat_create_encounter(p_presence);
    raise exception 'activity_start: hunt_pirates not implemented until M4';
  else
    raise exception 'activity_start: unknown activity %', p_activity;
  end if;
end;
$$;

-- Create a presence at a location and start its activity. Called by the movement
-- processor on outbound arrival. (WorldState.register_presence will be added when
-- the World State system lands — clean extension point, not needed for M3.)
create or replace function public.presence_create(
  p_player uuid, p_fleet uuid, p_sector uuid, p_zone uuid, p_location uuid, p_activity text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  insert into location_presence
    (player_id, fleet_id, sector_id, zone_id, location_id, activity_type, status, last_tick_at)
    values (p_player, p_fleet, p_sector, p_zone, p_location, p_activity, 'active', now())
    returning id into v_id;

  perform activity_start(v_id, p_activity);
  return v_id;
end;
$$;

-- Mark a presence completed (used internally and by Combat in M4).
create or replace function public.presence_complete(p_presence uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update location_presence
    set status = 'completed', updated_at = now()
    where id = p_presence and status in ('active','retreating','leaving');
  if not found then
    raise exception 'presence_complete: presence % not in an active state', p_presence;
  end if;
end; $$;

-- Player-initiated leave. For the 'none' activity (safe zone) this is immediate:
-- close the presence and create the return movement. For 'hunt_pirates' (M4) this
-- will instead start a retreat timer and let the combat tick create the return.
create or replace function public.presence_request_leave(p_presence uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  p           record;
  v_base      record;
  v_loc       record;
  v_speed     double precision;
  v_movement  uuid;
begin
  select * into p from location_presence where id = p_presence for update;
  if not found then
    raise exception 'presence_request_leave: presence % not found', p_presence;
  end if;
  if p.status <> 'active' then
    raise exception 'presence_request_leave: presence % not active (is %)', p_presence, p.status;
  end if;

  if p.activity_type <> 'none' then
    -- Combat retreat path is implemented in M4.
    raise exception 'presence_request_leave: only safe-zone leave supported in M3';
  end if;

  select b.id, b.x, b.y into v_base
    from fleets f join bases b on b.id = f.origin_base_id
    where f.id = p.fleet_id;
  select l.x, l.y into v_loc from locations l where l.id = p.location_id;
  v_speed := fleet_speed(p.fleet_id);

  -- Close presence (no longer at the location), then travel home.
  perform presence_complete(p_presence);

  v_movement := movement_create(
    p.player_id, p.fleet_id,
    'location', null, p.zone_id, p.location_id, v_loc.x, v_loc.y,
    'base', v_base.id, null, null, v_base.x, v_base.y,
    'return_home', v_speed);

  perform fleet_set_returning(p.fleet_id, v_movement);
  return v_movement;
end;
$$;
