-- Byeharu — M3b: Fleet system.
--
-- OWNERSHIP (docs/SYSTEM_BOUNDARIES.md): sole writer of fleets / fleet_units.
-- Movement, Presence, and (later) Combat change a fleet ONLY through the
-- state-machine functions here — they never write these tables directly.
-- Clients get owner SELECT only; all writes go through SECURITY DEFINER functions.

create table public.fleets (
  id                 uuid primary key default gen_random_uuid(),
  player_id          uuid not null references auth.users (id) on delete cascade,
  origin_base_id     uuid references public.bases (id) on delete set null,
  status             text not null default 'idle'
                       check (status in ('idle','moving','present','returning','completed','destroyed')),
  location_mode      text not null default 'base'
                       check (location_mode in ('base','movement','location','destroyed')),
  current_base_id    uuid references public.bases (id) on delete set null,
  current_sector_id  uuid references public.sectors (id),
  current_zone_id    uuid references public.zones (id),
  current_location_id uuid references public.locations (id),
  active_movement_id uuid,  -- FK added in the movement migration (forward ref)
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index fleets_player_id_idx on public.fleets (player_id);
create index fleets_status_idx on public.fleets (status);

create table public.fleet_units (
  id           uuid primary key default gen_random_uuid(),
  fleet_id     uuid not null references public.fleets (id) on delete cascade,
  unit_type_id text not null references public.unit_types (id),
  quantity     integer not null default 0 check (quantity >= 0),
  updated_at   timestamptz not null default now(),
  unique (fleet_id, unit_type_id)
);

-- ── RLS: owner-read only, no client writes ───────────────────────────────────
alter table public.fleets      enable row level security;
alter table public.fleet_units enable row level security;

create policy "fleets_select_own" on public.fleets
  for select using (player_id = auth.uid());

create policy "fleet_units_select_own" on public.fleet_units
  for select using (exists (
    select 1 from public.fleets f where f.id = fleet_units.fleet_id and f.player_id = auth.uid()
  ));

grant select on public.fleets, public.fleet_units to authenticated;

-- ── Fleet functions (SECURITY DEFINER; the only writers) ──────────────────────

-- Create a fleet from already-reserved units. Caller (send RPC) must have called
-- base_reserve_units first. Returns the new fleet id.
create or replace function public.fleet_create(p_player uuid, p_origin_base uuid, p_units jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_fleet uuid;
  item    jsonb;
  v_qty   integer;
begin
  insert into fleets (player_id, origin_base_id, status, location_mode, current_base_id)
    values (p_player, p_origin_base, 'idle', 'base', p_origin_base)
    returning id into v_fleet;

  for item in select * from jsonb_array_elements(p_units) loop
    v_qty := (item->>'quantity')::integer;
    if v_qty is null or v_qty <= 0 then
      raise exception 'fleet_create: invalid quantity for %', item->>'unit_type_id';
    end if;
    insert into fleet_units (fleet_id, unit_type_id, quantity)
      values (v_fleet, item->>'unit_type_id', v_qty);
  end loop;

  if not exists (select 1 from fleet_units where fleet_id = v_fleet) then
    raise exception 'fleet_create: empty fleet';
  end if;

  return v_fleet;
end;
$$;

-- Slowest unit speed governs the whole fleet (strategic fast-weak vs slow-strong).
create or replace function public.fleet_speed(p_fleet uuid)
returns double precision
language sql
stable
security definer
set search_path = public
as $$
  select min(ut.speed)
  from fleet_units fu
  join unit_types ut on ut.id = fu.unit_type_id
  where fu.fleet_id = p_fleet and fu.quantity > 0;
$$;

-- Total combat power (used by previews now, combat in M4).
create or replace function public.fleet_get_power(p_fleet uuid)
returns double precision
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(ut.power_score * fu.quantity), 0)
  from fleet_units fu
  join unit_types ut on ut.id = fu.unit_type_id
  where fu.fleet_id = p_fleet;
$$;

-- ── State-machine transitions (each validates the from-state) ─────────────────
create or replace function public.fleet_set_moving(p_fleet uuid, p_movement uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update fleets
    set status = 'moving', location_mode = 'movement', active_movement_id = p_movement,
        current_location_id = null, current_zone_id = null, current_sector_id = null,
        updated_at = now()
    where id = p_fleet and status = 'idle';
  if not found then
    raise exception 'fleet_set_moving: fleet % not in idle state', p_fleet;
  end if;
end; $$;

create or replace function public.fleet_set_present(
  p_fleet uuid, p_sector uuid, p_zone uuid, p_location uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update fleets
    set status = 'present', location_mode = 'location', active_movement_id = null,
        current_sector_id = p_sector, current_zone_id = p_zone, current_location_id = p_location,
        current_base_id = null, updated_at = now()
    where id = p_fleet and status = 'moving';
  if not found then
    raise exception 'fleet_set_present: fleet % not in moving state', p_fleet;
  end if;
end; $$;

create or replace function public.fleet_set_returning(p_fleet uuid, p_movement uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update fleets
    set status = 'returning', location_mode = 'movement', active_movement_id = p_movement,
        current_location_id = null, current_zone_id = null, current_sector_id = null,
        updated_at = now()
    where id = p_fleet and status = 'present';
  if not found then
    raise exception 'fleet_set_returning: fleet % not in present state', p_fleet;
  end if;
end; $$;

create or replace function public.fleet_complete(p_fleet uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update fleets
    set status = 'completed', location_mode = 'base', active_movement_id = null,
        current_base_id = origin_base_id,
        current_location_id = null, current_zone_id = null, current_sector_id = null,
        updated_at = now()
    where id = p_fleet and status = 'returning';
  if not found then
    raise exception 'fleet_complete: fleet % not in returning state', p_fleet;
  end if;
end; $$;

-- Used by Combat in M4.
create or replace function public.fleet_destroy(p_fleet uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update fleets
    set status = 'destroyed', location_mode = 'destroyed', active_movement_id = null,
        updated_at = now()
    where id = p_fleet and status in ('moving','present','returning');
  if not found then
    raise exception 'fleet_destroy: fleet % not in a destroyable state', p_fleet;
  end if;
end; $$;
