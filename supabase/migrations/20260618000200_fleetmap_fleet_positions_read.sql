-- Byeharu — FLEETMAP: whole-fleet map positions READ surface (additive, owner-read, no live function changed).
--
-- THE HONEST FIX for the "I can't see any ship I own on the map" bug. The map's single-ship resolver returns
-- NULL the moment a player owns 2+ ships (client resolveOwnedShip: `ships.length === 1 ? ships[0] : null`), so
-- the whole fleet goes invisible once a second ship is commissioned — and multi-ship is LIVE in production
-- (mainship_additional_enabled, max_active_fleets 6). This RPC replaces the N-fanout of the singular per-ship
-- fetchers (fetchActiveMainShipFleet / Presence / SpaceMovement) with ONE projection: for EVERY owned
-- non-destroyed ship it returns the placeable position fields the client marker resolver needs.
--
-- SERVER TRUTH: each ship's placement is decided by the CANONICAL coherence oracle
-- mainship_space_validate_context (0056) — the SAME authority the single-ship dock/store reads use — never by
-- re-deriving coherence here. An incoherent/home/destroyed ship projects place='hidden' (the client draws no
-- marker), exactly like the single-ship resolver returns null. No position is invented: docked ships carry
-- their present fleet's location id (client looks up the port coords), in-transit ships carry the committed
-- movement SEGMENT (client interpolates via the ONE shared lerp helper), held ships carry space_x/space_y.
--
-- ADDITIVE + DEPLOY-SAFE: a brand-new SECURITY DEFINER read; it re-creates NO live function, adds no writer,
-- and changes no gameplay. Owner-read posture (get_my_docked_store 0158 pattern): auth.uid() scoping,
-- authenticated-only execute. The client read fails closed to [] pre-deploy, so ship order is irrelevant.
--
-- MIGRATION NUMBER: 0200. Coordinated with the parallel slice-nohome worktree, which takes the next-free
-- 0199 — this slice deliberately skips to 0200 so the two additive migrations never collide.

create or replace function public.get_my_fleet_positions()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_out    jsonb := '[]'::jsonb;
  s        record;
  v_ctx    jsonb;
  v_ok     boolean;
  v_state  text;
  v_place  text;
  v_loc    uuid;
  v_seg    jsonb;
  v_mv     record;
  v_lm     record;
begin
  if v_player is null then
    return v_out;
  end if;

  -- Every owned, non-destroyed ship (owner-read scope). `order by created_at` is stable enumeration only —
  -- the marker placement per ship is decided below, never by row order.
  for s in
    select main_ship_id, name, hull_type_id, status, spatial_state, space_x, space_y
      from public.main_ship_instances
     where player_id = v_player
       and status <> 'destroyed'
       and coalesce(spatial_state, '') <> 'destroyed'
     order by created_at asc
  loop
    v_place := 'hidden';
    v_loc   := null;
    v_seg   := null;

    -- Canonical coherence oracle — the SAME authority the single-ship dock/store reads trust. It fully
    -- validates fleet + presence + movement coherence and returns the ship's honest state (or ok=false).
    v_ctx   := public.mainship_space_validate_context(s.main_ship_id);
    v_ok    := coalesce((v_ctx->>'ok')::boolean, false);
    v_state := v_ctx->>'state';

    if v_ok then
      if v_state = 'in_space' then
        -- Held in open space (durable ship-owned coordinates; coords asserted present by the oracle).
        if s.space_x is not null and s.space_y is not null then
          v_place := 'in_space';
        end if;

      elsif v_state in ('at_location', 'legacy_present') then
        -- Docked/present at a named location (the oracle already asserted the matching active presence).
        select f.current_location_id
          into v_loc
          from public.fleets f
         where f.main_ship_id = s.main_ship_id and f.status = 'present'
         order by f.created_at desc
         limit 1;
        if v_loc is not null then
          v_place := 'docked';
        end if;

      elsif v_state = 'in_transit' then
        -- Coordinate (OSN) transit — the committed movement segment for client-side interpolation.
        select origin_x, origin_y, target_x, target_y, target_kind, depart_at, arrive_at
          into v_mv
          from public.main_ship_space_movements
         where main_ship_id = s.main_ship_id and status = 'moving'
         limit 1;
        if found then
          v_place := 'transit';
          v_seg   := jsonb_build_object(
            'origin_x', v_mv.origin_x, 'origin_y', v_mv.origin_y,
            'target_x', v_mv.target_x, 'target_y', v_mv.target_y,
            'target_kind', v_mv.target_kind,
            'depart_at', v_mv.depart_at, 'arrive_at', v_mv.arrive_at);
        end if;

      elsif v_state = 'legacy_transit' then
        -- Legacy (spatial_state NULL) transit — the committed fleet_movements segment.
        select fm.origin_x, fm.origin_y, fm.target_x, fm.target_y, fm.target_type, fm.depart_at, fm.arrive_at
          into v_lm
          from public.fleet_movements fm
          join public.fleets f on f.id = fm.fleet_id
         where f.main_ship_id = s.main_ship_id and fm.status = 'moving'
         order by fm.depart_at desc
         limit 1;
        if found then
          v_place := 'transit';
          v_seg   := jsonb_build_object(
            'origin_x', v_lm.origin_x, 'origin_y', v_lm.origin_y,
            'target_x', v_lm.target_x, 'target_y', v_lm.target_y,
            'target_kind', v_lm.target_type,
            'depart_at', v_lm.depart_at, 'arrive_at', v_lm.arrive_at);
        end if;

      -- 'home' / 'legacy_home' → hidden: a ship idle at home is NOT drawn on the port map (mirrors the
      -- single-ship resolver §E/§F). Any other ok state falls through to hidden too (fail closed).
      end if;
    end if;

    -- Append as a single-element ARRAY (array || array is unambiguous concatenation).
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'main_ship_id', s.main_ship_id,
      'name',         s.name,
      'class',        s.hull_type_id,
      'status',       s.status,
      'spatial_state', s.spatial_state,
      'place',        v_place,
      'location_id',  v_loc,
      'space_x',      case when v_place = 'in_space' then s.space_x else null end,
      'space_y',      case when v_place = 'in_space' then s.space_y else null end,
      'segment',      v_seg
    ));
  end loop;

  return v_out;
end;
$$;

-- Authenticated-only owner read (strip the default PUBLIC/anon grant that a new function receives on create,
-- then grant to authenticated). SECURITY DEFINER, so the nested validate_context call runs as owner regardless
-- of its own service_role-only grant — the get_my_docked_store (0158) posture exactly.
revoke all on function public.get_my_fleet_positions() from public;
grant execute on function public.get_my_fleet_positions() to authenticated;
