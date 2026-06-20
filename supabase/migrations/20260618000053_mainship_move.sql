-- Byeharu — Main-ship direct location→location move (depart-after-arrival).
--
-- New rule: a main ship that is PRESENT at location A can be sent directly to a valid location B
-- WITHOUT first returning home. Return Home stays an optional action, never a prerequisite.
--
-- This is a NEW, focused RPC that mirrors request_main_ship_return (present → base) but targets
-- another LOCATION and ends the fleet in 'moving' so the existing movement processor can set it
-- present on arrival at B. It does NOT modify send_main_ship_expedition, request_main_ship_return,
-- movement_create, process_fleet_movements, or the generic fleet state-machine functions. The only
-- fleet-state nuance (present → moving — a transition the generic machine doesn't have) is a
-- tightly scoped direct update on THIS main-ship fleet, inside this RPC only (same convention as
-- the 10C direct insert / 10F cleanup). No combat, no fleet_units, no base_units, no legacy change.

create or replace function public.move_main_ship_to_location(p_fleet uuid, p_location uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_fleet    record;
  v_presence record;
  v_loc      record;  -- destination B
  v_cur      record;  -- current location A (movement origin)
  v_speed    double precision;
  v_movement uuid;
  v_arrive   timestamptz;
begin
  if v_player is null then
    raise exception 'move_main_ship_to_location: not authenticated';
  end if;

  if not cfg_bool('mainship_send_enabled') then
    raise exception 'move_main_ship_to_location: feature disabled';
  end if;

  -- Must be the caller's main-ship fleet, currently PRESENT at a location (the new sendable state).
  select * into v_fleet from fleets where id = p_fleet and player_id = v_player;
  if v_fleet.id is null then
    raise exception 'move_main_ship_to_location: fleet not found or not owned';
  end if;
  if v_fleet.main_ship_id is null then
    raise exception 'move_main_ship_to_location: not a main-ship fleet';
  end if;
  if v_fleet.status <> 'present' then
    -- moving / returning / (no active fleet → destroyed/home) are all rejected here.
    raise exception 'move_main_ship_to_location: ship not present (status %)', v_fleet.status;
  end if;

  -- Active presence pins the current location A (movement origin).
  select * into v_presence from location_presence
    where fleet_id = p_fleet and status = 'active';
  if v_presence.id is null then
    raise exception 'move_main_ship_to_location: no active presence for fleet';
  end if;

  -- Defensive same-location reject (UI also excludes the current location).
  if p_location = v_presence.location_id then
    raise exception 'move_main_ship_to_location: main ship is already at that location';
  end if;

  -- Destination B: exists, active, NON-COMBAT only.
  select l.id, l.x, l.y, l.activity_type, l.status, l.zone_id, z.sector_id
    into v_loc
    from locations l join zones z on z.id = l.zone_id
    where l.id = p_location;
  if v_loc.id is null or v_loc.status <> 'active' then
    raise exception 'move_main_ship_to_location: location not found or inactive';
  end if;
  if v_loc.activity_type <> 'none' then
    raise exception 'move_main_ship_to_location: only non-combat locations supported (got %)', v_loc.activity_type;
  end if;

  -- Current location A coords for the movement origin (depart from A, not from base).
  select x, y into v_cur from locations where id = v_presence.location_id;
  if v_cur.x is null then
    raise exception 'move_main_ship_to_location: current location missing';
  end if;

  -- Hull speed via the canonical resolver (the fleet carries no units).
  v_speed := resolve_fleet_movement_speed(p_fleet);

  -- Close presence at A, then depart A → B (mission 'rally' = non-combat).
  perform presence_complete(v_presence.id);
  v_movement := movement_create(
    v_player, p_fleet,
    'location', null, v_presence.zone_id, v_presence.location_id, v_cur.x, v_cur.y,
    'location', null, null, v_loc.id, v_loc.x, v_loc.y,
    'rally', v_speed);

  -- Dedicated present → moving transition (the generic state machine has no such transition).
  -- Scoped to THIS main-ship fleet only; mirrors fleet_set_returning's field changes but to
  -- 'moving' so process_fleet_movements' outbound branch can fleet_set_present on arrival at B.
  update fleets
    set status = 'moving', location_mode = 'movement', active_movement_id = v_movement,
        current_location_id = null, current_zone_id = null, current_sector_id = null,
        updated_at = now()
    where id = p_fleet and status = 'present';
  if not found then
    raise exception 'move_main_ship_to_location: fleet % no longer present', p_fleet;
  end if;

  -- Main ship stays "traveling" (en route again).
  update main_ship_instances set status = 'traveling', updated_at = now()
    where main_ship_id = v_fleet.main_ship_id;

  select arrive_at into v_arrive from fleet_movements where id = v_movement;
  return jsonb_build_object(
    'fleet_id', p_fleet, 'movement_id', v_movement, 'main_ship_id', v_fleet.main_ship_id,
    'from_location_id', v_presence.location_id, 'to_location_id', v_loc.id, 'arrive_at', v_arrive);
end;
$$;

-- ── Re-lock execute surface (anti-cheat) ──────────────────────────────────────
-- New client RPC: move_main_ship_to_location. Re-grant the canonical client surface (carried from
-- migration 0052) plus the new move RPC. Prior service_role grants survive the revoke.
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
grant execute on function public.get_world_map()                                  to anon, authenticated;
grant execute on function public.bootstrap_me()                                   to authenticated;
grant execute on function public.send_fleet_to_location(uuid, uuid, jsonb)        to authenticated;
grant execute on function public.request_leave_location(uuid)                     to authenticated;
grant execute on function public.request_retreat(uuid)                            to authenticated;
grant execute on function public.get_combat_reports()                             to authenticated;
grant execute on function public.train_units(uuid, text, integer)                 to authenticated;
grant execute on function public.cancel_build_order(uuid)                         to authenticated;
grant execute on function public.get_my_expedition_preview(jsonb, text)           to authenticated;
grant execute on function public.send_main_ship_expedition(jsonb, uuid)           to authenticated;
grant execute on function public.request_main_ship_return(uuid)                   to authenticated;
grant execute on function public.repair_main_ship()                               to authenticated;
grant execute on function public.move_main_ship_to_location(uuid, uuid)           to authenticated;
-- Server / CI only (service_role); NEVER clients:
grant execute on function public.dev_set_main_ship_destroyed(uuid)                to service_role;
grant execute on function public.resolve_fleet_movement_speed(uuid)               to service_role;
grant execute on function public.process_mainship_expeditions()                   to service_role;
