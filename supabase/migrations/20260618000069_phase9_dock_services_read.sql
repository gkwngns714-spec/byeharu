-- PHASE 9 — read-only docked-port surface for the authenticated player.
--
-- get_my_current_dock_services() exposes the ALREADY-AUTHORITATIVE current-dock truth to the player's own UI.
-- It accepts NO arguments: it derives player = auth.uid(), the player's one main ship, the validated ship
-- context (public.mainship_space_validate_context), and — ONLY when that context is 'at_location' — the
-- validated fleet.current_location_id and the ACTIVE public.location_services rows there. It writes nothing,
-- never invents a location from stale fields, and is NOT a general-purpose location/world-map RPC.
--
-- Free-port law: current physical dock + active explicit capability = local interaction eligibility. This RPC
-- exposes that fact; it never reads player_home_port, bases, names, coordinates, location_type, activity_type,
-- or physical_role to decide dock access. Only the new-domain 'at_location' state is treated as docked; every
-- other state (in_transit / in_space / destroyed / no ship / home / legacy / contradictory) returns no dock
-- and an empty service list.
--
-- Response (stable contract):
--   { state, docked, location_id, location_name, services }
--   state ∈ { 'no_main_ship', 'at_location', 'in_transit', 'in_space', 'destroyed', 'incoherent_or_unavailable' }
--   - 'at_location'             : docked=true; location_id/location_name = the validated dock; services = the
--                                 ACTIVE location_services there (e.g. ["docking"]).
--   - 'in_transit'/'in_space'/'destroyed' : the player's validated transient state; docked=false; services=[].
--   - 'no_main_ship'           : not authenticated, or the player has no main ship; docked=false; services=[].
--   - 'incoherent_or_unavailable' : any other state (home/legacy_home/legacy_present or any contradictory /
--                                 unrecognized context) — NO port surface; docked=false; services=[].

create or replace function public.get_my_current_dock_services()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_ship     uuid;
  v_ctx      jsonb;
  v_ok       boolean;
  v_vstate   text;
  v_loc      uuid;
  v_name     text;
  v_services jsonb;
  c_empty    constant jsonb := '[]'::jsonb;
begin
  -- (1) auth + ownership derived server-side; no client identifiers exist.
  if v_player is null then
    return jsonb_build_object('state','no_main_ship','docked',false,'location_id',null,'location_name',null,'services',c_empty);
  end if;
  select main_ship_id into v_ship from public.main_ship_instances where player_id = v_player;
  if v_ship is null then
    return jsonb_build_object('state','no_main_ship','docked',false,'location_id',null,'location_name',null,'services',c_empty);
  end if;

  -- (2) the canonical validated ship context (coherence-checked: fleet + presence + movement).
  v_ctx    := public.mainship_space_validate_context(v_ship);
  v_ok     := (v_ctx->>'ok')::boolean;
  v_vstate := v_ctx->>'state';

  -- (3) docked ONLY for the new-domain 'at_location' state.
  if v_ok is true and v_vstate = 'at_location' then
    -- derive the dock STRICTLY from the validated fleet.current_location_id (validate_context already proved
    -- the fleet is present/location with an active presence at this location).
    select f.current_location_id into v_loc
      from public.fleets f
      where f.main_ship_id = v_ship and f.status = 'present' and f.location_mode = 'location'
      limit 1;
    if v_loc is null then
      return jsonb_build_object('state','incoherent_or_unavailable','docked',false,'location_id',null,'location_name',null,'services',c_empty);
    end if;
    select l.name into v_name from public.locations l where l.id = v_loc;
    select coalesce(jsonb_agg(s.service order by s.service), c_empty)
      into v_services
      from public.location_services s
      where s.location_id = v_loc and s.status = 'active';   -- ACTIVE services only
    return jsonb_build_object(
      'state','at_location','docked',true,
      'location_id',v_loc,'location_name',v_name,
      'services',coalesce(v_services, c_empty));
  elsif v_ok is true and v_vstate in ('in_transit','in_space','destroyed') then
    return jsonb_build_object('state',v_vstate,'docked',false,'location_id',null,'location_name',null,'services',c_empty);
  else
    -- home / legacy_home / legacy_present / contradictory_state / unknown / ship_not_found → no port surface.
    return jsonb_build_object('state','incoherent_or_unavailable','docked',false,'location_id',null,'location_name',null,'services',c_empty);
  end if;
end;
$$;

-- Authenticated-only: remove the default PUBLIC (incl. anon) grant, then grant execute to authenticated.
revoke all on function public.get_my_current_dock_services() from public;
grant execute on function public.get_my_current_dock_services() to authenticated;
