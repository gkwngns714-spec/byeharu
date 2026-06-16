-- Byeharu — M3b: player action RPCs (orchestrators).
--
-- These are the ONLY write entry points for the client. They validate ownership /
-- state / limits, then call each system's functions in order. They never write
-- another system's tables directly. Server is authoritative — the client supplies
-- only intent (which base, which location, which units); the server decides
-- travel time, arrival, and all state.

-- send_fleet_to_location: base → reserve units → create fleet → create movement → moving
create or replace function public.send_fleet_to_location(
  p_base uuid, p_location uuid, p_units jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_base     record;
  v_loc      record;
  v_max      integer;
  v_active   integer;
  v_fleet    uuid;
  v_speed    double precision;
  v_movement uuid;
  v_arrive   timestamptz;
begin
  if v_player is null then
    raise exception 'send_fleet_to_location: not authenticated';
  end if;

  -- Ownership + base.
  select id, x, y, sector_id into v_base
    from bases where id = p_base and player_id = v_player and status = 'active';
  if v_base.id is null then
    raise exception 'send_fleet_to_location: base not found or not owned';
  end if;

  -- Location validity.
  select l.id, l.x, l.y, l.activity_type, l.status, l.zone_id, z.sector_id
    into v_loc
    from locations l join zones z on z.id = l.zone_id
    where l.id = p_location;
  if v_loc.id is null or v_loc.status <> 'active' then
    raise exception 'send_fleet_to_location: location not found or inactive';
  end if;

  -- M3 supports only safe zones (activity 'none'); combat arrives in M4.
  if v_loc.activity_type <> 'none' then
    raise exception 'send_fleet_to_location: only safe zones are available in M3 (combat is M4)';
  end if;

  -- Fleet limit.
  v_max := coalesce(cfg_num('max_active_fleets'), 3);
  select count(*) into v_active
    from fleets where player_id = v_player and status in ('moving','present','returning');
  if v_active >= v_max then
    raise exception 'send_fleet_to_location: active fleet limit reached (%/%)', v_active, v_max;
  end if;

  -- Units must be a non-empty array.
  if p_units is null or jsonb_typeof(p_units) <> 'array' or jsonb_array_length(p_units) = 0 then
    raise exception 'send_fleet_to_location: no units selected';
  end if;

  -- Reserve units (raises if insufficient), build fleet, compute speed, dispatch.
  perform base_reserve_units(p_base, p_units);
  v_fleet := fleet_create(v_player, p_base, p_units);
  v_speed := fleet_speed(v_fleet);

  v_movement := movement_create(
    v_player, v_fleet,
    'base', v_base.id, null, null, v_base.x, v_base.y,
    'location', null, null, v_loc.id, v_loc.x, v_loc.y,
    'rally', v_speed);

  perform fleet_set_moving(v_fleet, v_movement);

  select arrive_at into v_arrive from fleet_movements where id = v_movement;
  return jsonb_build_object(
    'fleet_id', v_fleet, 'movement_id', v_movement, 'arrive_at', v_arrive);
end;
$$;

grant execute on function public.send_fleet_to_location(uuid, uuid, jsonb) to authenticated;

-- request_leave_location: validate ownership/state, then delegate to Presence.
create or replace function public.request_leave_location(p_presence uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_owner    uuid;
  v_status   text;
  v_movement uuid;
begin
  if v_player is null then
    raise exception 'request_leave_location: not authenticated';
  end if;

  select player_id, status into v_owner, v_status
    from location_presence where id = p_presence;
  if v_owner is null then
    raise exception 'request_leave_location: presence not found';
  end if;
  if v_owner <> v_player then
    raise exception 'request_leave_location: not owned';
  end if;
  if v_status <> 'active' then
    raise exception 'request_leave_location: presence not active (is %)', v_status;
  end if;

  v_movement := presence_request_leave(p_presence);
  return jsonb_build_object('return_movement_id', v_movement);
end;
$$;

grant execute on function public.request_leave_location(uuid) to authenticated;
