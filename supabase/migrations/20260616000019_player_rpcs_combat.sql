-- Byeharu — M4: extend player RPCs for combat. send_fleet_to_location now allows
-- hunt_pirates locations (with a server-side min_power check) and tags the mission.
-- request_retreat() is the combat-facing leave; it delegates to Presence.

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
  v_power    double precision;
  v_speed    double precision;
  v_mission  text;
  v_movement uuid;
  v_arrive   timestamptz;
begin
  if v_player is null then
    raise exception 'send_fleet_to_location: not authenticated';
  end if;

  select id, x, y, sector_id into v_base
    from bases where id = p_base and player_id = v_player and status = 'active';
  if v_base.id is null then
    raise exception 'send_fleet_to_location: base not found or not owned';
  end if;

  select l.id, l.x, l.y, l.activity_type, l.status, l.zone_id, l.min_power_required, z.sector_id
    into v_loc
    from locations l join zones z on z.id = l.zone_id
    where l.id = p_location;
  if v_loc.id is null or v_loc.status <> 'active' then
    raise exception 'send_fleet_to_location: location not found or inactive';
  end if;
  if v_loc.activity_type not in ('none', 'hunt_pirates') then
    raise exception 'send_fleet_to_location: activity % not available', v_loc.activity_type;
  end if;

  v_max := coalesce(cfg_num('max_active_fleets'), 3);
  select count(*) into v_active
    from fleets where player_id = v_player and status in ('moving','present','returning');
  if v_active >= v_max then
    raise exception 'send_fleet_to_location: active fleet limit reached (%/%)', v_active, v_max;
  end if;

  if p_units is null or jsonb_typeof(p_units) <> 'array' or jsonb_array_length(p_units) = 0 then
    raise exception 'send_fleet_to_location: no units selected';
  end if;

  perform base_reserve_units(p_base, p_units);
  v_fleet := fleet_create(v_player, p_base, p_units);

  v_power := fleet_get_power(v_fleet);
  if v_power < coalesce(v_loc.min_power_required, 0) then
    raise exception 'send_fleet_to_location: fleet power % below required %', v_power, v_loc.min_power_required;
  end if;

  v_speed   := fleet_speed(v_fleet);
  v_mission := case when v_loc.activity_type = 'hunt_pirates' then 'hunt_pirates' else 'rally' end;
  v_movement := movement_create(
    v_player, v_fleet,
    'base', v_base.id, null, null, v_base.x, v_base.y,
    'location', null, null, v_loc.id, v_loc.x, v_loc.y,
    v_mission, v_speed);
  perform fleet_set_moving(v_fleet, v_movement);

  select arrive_at into v_arrive from fleet_movements where id = v_movement;
  return jsonb_build_object('fleet_id', v_fleet, 'movement_id', v_movement, 'arrive_at', v_arrive);
end;
$$;

-- Combat-facing retreat (delegates to Presence's leave/retreat logic).
create or replace function public.request_retreat(p_presence uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_owner  uuid;
  v_status text;
  v_mv     uuid;
begin
  if v_player is null then
    raise exception 'request_retreat: not authenticated';
  end if;
  select player_id, status into v_owner, v_status from location_presence where id = p_presence;
  if v_owner is null then
    raise exception 'request_retreat: presence not found';
  end if;
  if v_owner <> v_player then
    raise exception 'request_retreat: not owned';
  end if;
  if v_status <> 'active' then
    raise exception 'request_retreat: presence not active (is %)', v_status;
  end if;
  v_mv := presence_request_leave(p_presence);
  return jsonb_build_object('return_movement_id', v_mv);
end;
$$;
