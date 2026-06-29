-- OSN-COORD-ENABLE-1B — additive runtime coordinate-travel capability on the OSN readiness read-model.
--
-- Extends public.get_osn_movement_readiness() with ONE additive boolean field, `coordinate_travel_available`,
-- WITHOUT changing any existing field, meaning, authorization, or port/location readiness behavior. The field
-- is a UX capability HINT ONLY; the actual security boundary stays the server gate in
-- public.command_main_ship_space_move (migration 0070, key mainship_coordinate_travel_enabled) — UNCHANGED here.
--
-- Semantics (derived from the EXISTING readiness decision, never loosely from raw global config):
--     coordinate_travel_available = osn_available AND cfg_bool('mainship_coordinate_travel_enabled')
-- where osn_available keeps its EXACT existing meaning (mainship_space_movement_enabled AND a resolvable OSN
-- origin for THIS authenticated caller). Because it is a strict refinement of osn_available, a non-actionable /
-- unanchored / in-transit / destroyed / no-ship origin can NEVER report coordinate_travel_available=true, even
-- when both flags are true. On live production (mainship_coordinate_travel_enabled=false) the field is false
-- for everyone.
--
-- This migration WRITES NOTHING (no game_config / player / port / movement / ship / fleet / flag change) and
-- alters NO other function: command_main_ship_space_move, command_main_ship_space_move_to_location, Dock-0
-- (mainship_space_dock_at_location), arrival settlement, map bounds, and location-target semantics are all
-- untouched. It only CREATE OR REPLACEs the readiness projection (preserving every existing field/return path)
-- and re-asserts its authenticated-only ACL.

create or replace function public.get_osn_movement_readiness()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_ship   uuid;
  v_origin jsonb;
  v_cat    text;
  v_cur    uuid;           -- current docked location (excluded from destinations); NULL unless docked
  v_flag   boolean;
  v_avail  boolean := false;
  v_coord  boolean := false;  -- OSN-COORD-ENABLE-1B additive capability (derived strictly from v_avail below)
  v_reason text;
  v_dests  uuid[] := '{}';
begin
  if v_player is null then
    return jsonb_build_object('origin_category', 'no_ship', 'osn_available', false,
                              'coordinate_travel_available', false,
                              'reason', 'no_ship', 'eligible_destination_ids', '[]'::jsonb);
  end if;

  select main_ship_id into v_ship from public.main_ship_instances where player_id = v_player;
  if v_ship is null then
    return jsonb_build_object('origin_category', 'no_ship', 'osn_available', false,
                              'coordinate_travel_available', false,
                              'reason', 'no_ship', 'eligible_destination_ids', '[]'::jsonb);
  end if;

  -- Single authoritative source of origin truth (service_role-only; callable here via SECURITY DEFINER).
  v_origin := public.mainship_space_resolve_origin(v_ship);
  if (v_origin->>'ok')::boolean is true then
    v_cat := 'anchored';
    if v_origin->>'origin_kind' = 'location' then
      v_cur := (v_origin->>'origin_location_id')::uuid;   -- exclude the port we are docked at
    end if;
  else
    v_cat := case v_origin->>'reason'
               when 'origin_not_anchored'  then 'not_anchored'
               when 'in_transit_must_stop' then 'in_transit'
               when 'destroyed'            then 'destroyed'
               else 'not_anchored'   -- contradictory_state / any other → safe generic (cannot move)
             end;
  end if;

  v_flag  := coalesce(public.cfg_bool('mainship_space_movement_enabled'), false);
  v_avail := (v_flag and v_cat = 'anchored');

  -- OSN-COORD-ENABLE-1B: the coordinate-travel capability is a STRICT refinement of osn_available — it can be
  -- true ONLY when the caller is already OSN-actionable (resolvable origin + movement flag) AND the dedicated
  -- coordinate gate is on. It NEVER becomes true for an unanchored / non-actionable origin on flags alone, and
  -- it is always false while mainship_coordinate_travel_enabled is false (production's current dark state).
  v_coord := (v_avail and coalesce(public.cfg_bool('mainship_coordinate_travel_enabled'), false));

  v_reason := case
                when v_cat = 'destroyed'                  then 'destroyed'
                when v_cat = 'in_transit'                 then 'in_transit'
                when v_cat = 'not_anchored'               then 'travel_to_port'
                when v_cat = 'anchored' and not v_flag     then 'feature_disabled'
                else 'none'
              end;

  -- Eligible visible destinations ONLY when anchored (unchanged). mainship_space_location_target_legal requires
  -- the target to be an ACTIVE city|port with activity 'none' + one active docking service + one active anchor,
  -- so hidden ports and ordinary non-port locations are excluded by construction.
  if v_cat = 'anchored' then
    select coalesce(array_agg(l.id), '{}')
      into v_dests
      from public.locations l
      where l.status = 'active'
        and l.id is distinct from v_cur
        and (public.mainship_space_location_target_legal(l.id)->>'ok')::boolean is true;
  end if;

  return jsonb_build_object(
    'origin_category', v_cat,
    'osn_available', v_avail,
    'coordinate_travel_available', v_coord,   -- OSN-COORD-ENABLE-1B additive field
    'reason', v_reason,
    'eligible_destination_ids', to_jsonb(v_dests));
end;
$$;

-- Re-assert the canonical authenticated-only ACL (no PUBLIC / anon execute; intended authenticated execute).
revoke execute on function public.get_osn_movement_readiness() from public, anon;
grant  execute on function public.get_osn_movement_readiness() to authenticated;
