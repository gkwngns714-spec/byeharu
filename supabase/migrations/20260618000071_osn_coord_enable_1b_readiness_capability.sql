-- OSN-COORD-ENABLE-1B — server-derived runtime coordinate-travel READINESS capability (additive, dark, read-only).
--
-- Extends the existing authenticated read-model RPC public.get_osn_movement_readiness() (migration 0068) with ONE
-- additive boolean field, `coordinate_travel_available`, derived from the existing OSN readiness decision AND the
-- server-owned coordinate gate seeded by migration 0070. This does NOT enable coordinate travel, does NOT change
-- any flag, and does NOT change frontend behavior (the current parser ignores unknown additive fields; the
-- compile-time OSN_COORDINATE_TRAVEL_ENABLED const stays false). It is a strict read-model extension.
--
-- DERIVATION (anchored-origin preserving — NOT a loose duplicate of the global flags):
--     coordinate_travel_available = osn_available AND cfg_bool('mainship_coordinate_travel_enabled')
--   where osn_available retains its EXACT existing meaning:
--     osn_available = cfg_bool('mainship_space_movement_enabled') AND origin_category = 'anchored'
--   so a non-actionable / unanchored / in_transit / destroyed / no_ship origin can NEVER receive
--   coordinate_travel_available=true merely because the flags are true (osn_available is already false there).
--   In production today both the movement domain (true) and the coordinate gate (false) yield FALSE for every
--   caller, so production stays dark.
--
-- SECURITY BOUNDARY UNCHANGED: the real gate remains the migration-0070 server check inside
-- command_main_ship_space_move() (returns coordinate_travel_disabled before any side effect while the key is
-- false). This RPC is a UX read projection only; it grants no capability and is never an authority boundary.
--
-- NOT TOUCHED: command_main_ship_space_move, command_main_ship_space_move_to_location, docking, arrival
-- settlement, map bounds, location-target semantics, reveal_starter_ports, every game_config value, ports,
-- movements, ships, fleets, player data, and all other RPC ACLs. Writes NOTHING. Preserves SECURITY DEFINER,
-- the auth.uid() caller derivation, every existing field/meaning, and the authenticated-only ACL.

-- ── Re-create get_osn_movement_readiness() identically to 0068, adding ONLY the additive coordinate field ─────
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
  v_coord_flag  boolean;   -- OSN-COORD-ENABLE-1B: server-owned coordinate gate (migration 0070; false on live)
  v_coord_avail boolean := false;  -- additive readiness capability; never true unless osn_available is true
  v_reason text;
  v_dests  uuid[] := '{}';
begin
  if v_player is null then
    return jsonb_build_object('origin_category', 'no_ship', 'osn_available', false,
                              'reason', 'no_ship', 'eligible_destination_ids', '[]'::jsonb,
                              'coordinate_travel_available', false);
  end if;

  select main_ship_id into v_ship from public.main_ship_instances where player_id = v_player;
  if v_ship is null then
    return jsonb_build_object('origin_category', 'no_ship', 'osn_available', false,
                              'reason', 'no_ship', 'eligible_destination_ids', '[]'::jsonb,
                              'coordinate_travel_available', false);
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

  -- OSN-COORD-ENABLE-1B: the additive coordinate-travel readiness capability. Derived from the EXISTING OSN
  -- readiness decision (v_avail) AND the server-owned coordinate gate, so it inherits the anchored-origin and
  -- movement-domain checks exactly and fails closed for any non-actionable origin. Read-only; writes nothing.
  v_coord_flag  := coalesce(public.cfg_bool('mainship_coordinate_travel_enabled'), false);
  v_coord_avail := (v_avail and v_coord_flag);

  v_reason := case
                when v_cat = 'destroyed'                  then 'destroyed'
                when v_cat = 'in_transit'                 then 'in_transit'
                when v_cat = 'not_anchored'               then 'travel_to_port'
                when v_cat = 'anchored' and not v_flag     then 'feature_disabled'
                else 'none'
              end;

  -- Eligible visible destinations ONLY when anchored. mainship_space_location_target_legal requires the
  -- target to be an ACTIVE city|port with activity 'none' + one active docking service + one active anchor,
  -- so hidden ports (status<>'active') and ordinary non-port locations are excluded by construction — no
  -- hidden-port id, anchor, or coordinate is ever returned.
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
    'reason', v_reason,
    'eligible_destination_ids', to_jsonb(v_dests),
    'coordinate_travel_available', v_coord_avail);
end;
$$;

-- ── Re-assert canonical ACL for THIS function only (CREATE OR REPLACE preserves the prior ACL; re-assert to be
--    explicit and defensive). No PUBLIC / anon execute; authenticated execute only. No other ACL is touched. ──
revoke execute on function public.get_osn_movement_readiness() from public, anon;
grant  execute on function public.get_osn_movement_readiness() to authenticated;
