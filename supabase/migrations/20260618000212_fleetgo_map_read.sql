-- FLEET-GO 3c-3 — MAP-READ: the map projects the GROUP's fleet in transit and in open space.
--
-- Charter: docs/MOVEMENT_UNIFICATION_CHARTER.md §2 + §3 step 3c-3. Follows 0211 (the dock dedup).
--
-- WHY THIS MIGRATION EXISTS. Two blind spots remained in get_my_fleet_positions after 0211 (its own
-- header deliberately deferred the first one to this step):
--   • TRANSIT: the legacy_transit arm still keyed fleet_movements through `f.main_ship_id =
--     s.main_ship_id` — NULL on a unified fleet by construction — so every member of a FLYING group
--     drew place='hidden' even though the oracle (0210) already answered legacy_transit for it: the
--     whole group vanished from the map for the duration of every flight.
--   • OPEN SPACE: the in_space arm read s.space_x/s.space_y — SHIP columns. The unified world parks
--     the FLEET (fleet_set_in_space, 0208:61-87 — status 'idle', location_mode 'space', coords on
--     fleets) and writes NOTHING to ships (§2; NOSHIPWRITE pins it), so a parked or braked fleet's
--     members all drew place='hidden': the fleet the STOP brake (0209) just held went INVISIBLE at
--     the exact moment the player most needs to see where it is.
-- Fixed by ONE function re-create carrying exactly THREE marked hunks (plus the v_sx/v_sy declares
-- and their per-iteration reset): the transit rekey, the fleet-first in_space read, and the emit
-- reading the resolved coordinate. Fleet-first is §2 stated as a read (0210:188-189: the position is
-- read from the FLEET, never the ship). The ship-coordinate fallback is DELIBERATELY preserved: it is
-- the dark parity path (an OSN-held ship still draws its own coords) and dies at step 4c with the
-- ship columns, not before.
--
-- ★★ TRUE-HEAD DECLARATION — READ THIS BEFORE TOUCHING THIS FUNCTION AGAIN ★★
-- As of this migration the TRUE head of get_my_fleet_positions is THIS FILE (previously 0211:225-353,
-- before that 0200:24-148). Any later step that touches it — a 3c-3 follow-up, 4a's client repoint,
-- 4c's column retirement — MUST copy from 0212, not from 0211, not from 0200. Rebuilding from a stale
-- head is exactly how 0136 silently re-inlined the dock block and forced 0138 to exist. Do not make a
-- 0138 for this file. (0211's docked hunk survives here VERBATIM — the selftest's stale-head tripwire
-- greps this file for it, so a rebuild from 0200 goes red instantly.)
--
-- DARK ⇒ BYTE-IDENTICAL — argued on states the dark world can REACH (the 3c-1 lesson):
--   • HUNK 1 (transit rekey) is reached only when the oracle answered 'legacy_transit'. Dark, that
--     answer comes only from the 0056 head, whose guard pins EXACTLY ONE per-ship fleet in an active
--     status carrying a moving fleet_movements row (0210:265-267). Dark, the resolver's group branch
--     is gated off (0210:85) and its transition fallback returns exactly that one fleet — so the new
--     key selects the SAME movement row the old key selected. HONEST RESIDUAL: the old key scanned
--     ALL the ship's fleets INCLUDING terminal-status history (completed/destroyed), `order by
--     fm.depart_at desc` — so old and new could differ only if a 'moving' movement existed on a
--     completed/destroyed fleet. No live writer can produce that shape (every settle/cancel resolves
--     the movement together with its fleet), and on that corrupt shape the new code answers from the
--     oracle-coherent ACTIVE fleet while the old code could have drawn the corpse's leg — fail-honest.
--   • HUNKS 2-3 (fleet-first in_space + emit): dark, 'in_space' comes only from the 0056 head, which
--     REQUIRES ZERO active fleets (0210:234: v_count > 0 → contradictory_state) → the resolver's
--     fallback counts those same zero rows and returns NULL → `f.id = NULL` matches nothing →
--     v_sx/v_sy stay NULL → the elsif runs the OLD arm verbatim on the ship's own coordinates. The
--     fleet-first read is dark-UNREACHABLE by proof, not by promise.
--
-- POSTURE. ONE function re-create and NOTHING else: no table change, no drop, no signature change,
-- no flag flip, no seed, no ship write. The body below is 0211:225-353 byte-for-byte except the three
-- hunks marked "FLEET-GO 3c-3" and the v_sx/v_sy declares + their reset; ACLs re-emitted verbatim
-- from 0211:352-353. The in_transit (OSN) arm is deliberately NOT touched: the unified mover never
-- creates main_ship_space_movements rows, so the oracle can never answer 'in_transit' for a group
-- (0210:197-198) — a group hunk there would be dead code wearing a live face. The docked arm was
-- 3c-2's hunk and survives verbatim (the stale-head tripwire above).

-- ── get_my_fleet_positions — the 0211:225-353 body; THREE hunks: the legacy_transit rekey (hunk 1),
--    the fleet-first in_space read (hunk 2), and the emit reading the resolved coordinate (hunk 3). ──
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
  -- FLEET-GO 3c-3 additions: the resolved in_space coordinate (fleet-first, ship fallback).
  v_sx     double precision;
  v_sy     double precision;
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
    -- FLEET-GO 3c-3: reset WITH the others. plpgsql variables persist across loop iterations, so a
    -- coordinate surviving into a later row is a ship drawn where a DIFFERENT fleet parked.
    v_sx    := null;
    v_sy    := null;

    -- Canonical coherence oracle — the SAME authority the single-ship dock/store reads trust. It fully
    -- validates fleet + presence + movement coherence and returns the ship's honest state (or ok=false).
    v_ctx   := public.mainship_space_validate_context(s.main_ship_id);
    v_ok    := coalesce((v_ctx->>'ok')::boolean, false);
    v_state := v_ctx->>'state';

    if v_ok then
      if v_state = 'in_space' then
        -- FLEET-GO 3c-3 (hunk 2 of 3): FLEET-FIRST. The unified world parks the FLEET
        -- (fleet_set_in_space, 0208) and never writes a ship coordinate, so a parked/braked group was
        -- INVISIBLE here — the old arm read only the ship's own columns. The fleet's coordinate now
        -- answers first (0210:188-189: the position is read from the FLEET, never the ship). The SHIP
        -- fallback below is the dark parity path — dark, 'in_space' requires ZERO active fleets, so
        -- the resolver returns NULL, the fleet read matches nothing, and the elsif is the pre-0212
        -- arm verbatim. DO NOT "clean up" the elsif: it is load-bearing until step 4c retires the
        -- ship columns, and the selftest pins its presence.
        select f.space_x, f.space_y
          into v_sx, v_sy
          from public.fleets f
         where f.id = public.mainship_resolve_fleet(s.main_ship_id) and f.location_mode = 'space'
         limit 1;
        if v_sx is not null and v_sy is not null then
          v_place := 'in_space';
        elsif s.space_x is not null and s.space_y is not null then
          -- held in open space on the ship's own (retired-layer) coordinates — the pre-0212 arm.
          v_place := 'in_space';
          v_sx    := s.space_x;
          v_sy    := s.space_y;
        end if;

      elsif v_state in ('at_location', 'legacy_present') then
        -- FLEET-GO 3c-2 (the ONE hunk): rekeyed from `f.main_ship_id = <ship>` (NULL on a unified
        -- fleet — the whole group vanished on arrival) to the ONE ship→fleet resolver, KEEPING this
        -- site's own status='present' read: 'legacy_present' reaches here too, and the at_location-only
        -- dock helper would return NULL for every legacy-shaped prod ship (a live map regression).
        -- Dark → both oracle guards pin exactly ONE active per-ship fleet, the resolver's fallback
        -- returns it, and f.id = <that one row> makes the old `order by created_at desc` dead weight.
        select f.current_location_id
          into v_loc
          from public.fleets f
         where f.id = public.mainship_resolve_fleet(s.main_ship_id) and f.status = 'present'
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
        -- FLEET-GO 3c-3 (hunk 1 of 3): rekeyed from `f.main_ship_id = s.main_ship_id` (NULL on a
        -- unified fleet — a flying group's members drew hidden for the whole flight) to the ONE
        -- ship→fleet resolver. Dark → the oracle's legacy_transit guard pins exactly ONE active
        -- per-ship fleet carrying a moving leg, the resolver's fallback returns it, and this join
        -- selects the same movement row the old key did (the honest residual is in the header). The
        -- host's own join, its `order by fm.depart_at desc`, and its `limit 1` are KEPT.
        select fm.origin_x, fm.origin_y, fm.target_x, fm.target_y, fm.target_type, fm.depart_at, fm.arrive_at
          into v_lm
          from public.fleet_movements fm
          join public.fleets f on f.id = fm.fleet_id
         where f.id = public.mainship_resolve_fleet(s.main_ship_id) and fm.status = 'moving'
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
      -- FLEET-GO 3c-3 (hunk 3 of 3): the emit reads the RESOLVED coordinate (fleet-first, ship
      -- fallback) instead of the ship columns. Dark, v_sx/v_sy carry exactly s.space_x/s.space_y
      -- (hunk 2's elsif) → byte-identical.
      'space_x',      case when v_place = 'in_space' then v_sx else null end,
      'space_y',      case when v_place = 'in_space' then v_sy else null end,
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
