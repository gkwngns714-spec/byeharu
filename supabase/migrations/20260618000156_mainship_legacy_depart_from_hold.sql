-- Byeharu — LEGACY RESUME: send a HELD-in-open-space main ship on a new leg (Slice B of the Stop=hold fix).
--
-- CONTEXT. Slice A (0155) made Stop HALT AND HOLD: a stopped legacy main-ship transit now parks the ship in
-- open space (main_ship_instances status='stationary', spatial_state='in_space', space_x/y = halt point) with
-- its fleet settled to the movement-less terminal (status='completed', active_movement_id=NULL) and its
-- fleet_movements row terminated 'cancelled'. But NO legacy Send could re-depart from that held state:
-- send_main_ship_expedition requires ship status='home'; move_main_ship_to_location and
-- request_main_ship_return require fleet status='present' + an active location_presence. A held ship has
-- neither — it is out in open space with no presence. This slice adds the resume.
--
-- DESIGN DECISION (self-approved): converge on ONE send-to-location path, do NOT add a parallel resume RPC.
-- EXTEND move_main_ship_to_location to depart from EITHER validated departure state — the existing
-- "present at a location" state OR the new "held in open space" state — deriving the movement ORIGIN
-- accordingly. "Depart from a held point" is simply a different ORIGIN for the same location-target 'rally'
-- movement, so extending this one RPC keeps ONE movement path (reusing its destination-validation / speed /
-- movement_create / in-flight-marking machinery) instead of standing up a second parallel system.
--
-- WHY A 'space' ORIGIN IS LOW-RIPPLE AND HONEST (not a new movement system):
--   • origin_type is PROVENANCE METADATA ONLY. Settlement branches solely on target_type
--     (process_fleet_movements 0030:53,60,74; movement_settle_arrival 0151/0153) — NOTHING anywhere reads
--     origin_type to make a decision (verified: migrations switch on target_type; src/ has only a passive
--     `fleetTypes.ts` string field, no comparison). So widening the origin_type domain is additive.
--   • A held departure has NO base/location/zone anchor — its only truthful origin is the raw coordinate the
--     ship was holding at. origin_type='space' with origin_base_id/origin_location_id/origin_zone_id all NULL
--     and origin_x/y = the held coordinates records exactly that, in the SAME fleet_movements table, written
--     by the SAME sole writer (Movement), settled by the SAME target_type-driven arrival path. It is NOT the
--     OSN coordinate domain (main_ship_space_movements is untouched); it is an honest legacy origin value.
--
-- BOUNDARIES (unchanged): Movement stays the SOLE writer of fleet_movements; Main Ship stays the SOLE writer
-- of main_ship_instances (the in-flight mark still routes through the one 0152 Main-Ship-owned helper). No
-- new table, no new RPC, no OSN function/table touched, no flag created/read-differently/flipped
-- (mainship_send_enabled gate preserved verbatim; mainship_space_movement_enabled stays dark). Non-combat
-- destinations only (activity_type='none') — unchanged. send_main_ship_expedition (home departure) is NOT
-- touched: a held→location send goes through this one location RPC.
--
-- ACCEPTED MICRO-DELTAS on the PRESENT path (documented; observable behavior preserved — the 0153 precedent):
--   • The present→moving fleet transition and the held→moving one share ONE guarded UPDATE (the no-duplication
--     hard rule; the SET clause is not copy-pasted per branch). Its guard adds `active_movement_id is null` to
--     the present case — a NO-OP, since a present fleet always has active_movement_id NULL (fleet_set_present,
--     0006:133) — and the race-only raise message generalizes from "no longer present" to "no longer in its
--     <state> departure state".
--   • presence_complete now runs immediately AFTER movement_create instead of immediately before. Both write
--     independent tables inside the same atomic function (presence_complete → location_presence + world-state
--     cache; movement_create → fleet_movements); no coupling, identical committed state.
--   • The success envelope gains an additive `from` marker ('present' | 'hold'); existing keys
--     (from_location_id, to_location_id, arrive_at) are unchanged (from_location_id is NULL for a held
--     departure). Slice C consumes `from`.
--
-- SLICE C updates the client (find/select the held fleet, the `from` marker) + rewrites the stop-roundtrip
-- verifier's legacy section to send→stop(held)→send→stop(held). This migration is server + doc sync only.

-- ── 1) Extend the fleet_movements origin_type domain (forward-only; additive) ──────────────────────────────
-- Drop the inline column CHECK (auto-named <table>_<column>_check — the 0055 idiom) and re-add it with the new
-- 'space' value. target_type is intentionally NOT touched. Nothing branches on origin_type (see header), so
-- this cannot change any settlement/read path.
alter table public.fleet_movements drop constraint if exists fleet_movements_origin_type_check;
alter table public.fleet_movements
  add constraint fleet_movements_origin_type_check
  check (origin_type in ('base','location','zone','space'));

-- ── 2) move_main_ship_to_location — 0152:221 body, generalized to depart from PRESENT or HELD ───────────────
create or replace function public.move_main_ship_to_location(p_fleet uuid, p_location uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_fleet    record;
  v_presence record;   -- present-departure origin (active presence pins location A)
  v_ship     record;   -- held-departure origin (main ship parked in open space)
  v_loc      record;   -- destination B
  v_cur      record;   -- current location A coordinates (present origin)
  v_speed    double precision;
  v_movement uuid;
  v_arrive   timestamptz;
  -- origin derived per departure state; the depart mechanics below are shared.
  v_depart_from      text;
  v_origin_type      text;
  v_origin_zone      uuid;
  v_origin_location  uuid;
  v_origin_x         double precision;
  v_origin_y         double precision;
  v_from_location_id uuid;
begin
  if v_player is null then
    raise exception 'move_main_ship_to_location: not authenticated';
  end if;

  if not cfg_bool('mainship_send_enabled') then
    raise exception 'move_main_ship_to_location: feature disabled';
  end if;

  -- Must be the caller's main-ship fleet.
  select * into v_fleet from fleets where id = p_fleet and player_id = v_player;
  if v_fleet.id is null then
    raise exception 'move_main_ship_to_location: fleet not found or not owned';
  end if;
  if v_fleet.main_ship_id is null then
    raise exception 'move_main_ship_to_location: not a main-ship fleet';
  end if;

  -- ── ORIGIN: depart from PRESENT-at-a-location OR HELD-in-open-space (the ONLY per-branch difference) ──────
  if v_fleet.status = 'present' then
    -- Present departure (unchanged): active presence pins current location A; reject a same-location send.
    select * into v_presence from location_presence
      where fleet_id = p_fleet and status = 'active';
    if v_presence.id is null then
      raise exception 'move_main_ship_to_location: no active presence for fleet';
    end if;
    if p_location = v_presence.location_id then
      raise exception 'move_main_ship_to_location: main ship is already at that location';
    end if;
    select x, y into v_cur from locations where id = v_presence.location_id;
    if v_cur.x is null then
      raise exception 'move_main_ship_to_location: current location missing';
    end if;
    v_depart_from      := 'present';
    v_origin_type      := 'location';
    v_origin_zone      := v_presence.zone_id;
    v_origin_location  := v_presence.location_id;
    v_origin_x         := v_cur.x;
    v_origin_y         := v_cur.y;
    v_from_location_id := v_presence.location_id;
  else
    -- Held departure (Slice A / 0155): the fleet is not present; the only other departable state is the main
    -- ship parked in open space. Require the exact held shape — status='stationary', spatial_state='in_space',
    -- coordinates set — and depart from those raw coordinates (origin_type='space', no anchor, no presence).
    select status, spatial_state, space_x, space_y into v_ship
      from main_ship_instances where main_ship_id = v_fleet.main_ship_id;
    if not (v_ship.status = 'stationary' and v_ship.spatial_state = 'in_space'
            and v_ship.space_x is not null and v_ship.space_y is not null) then
      raise exception 'move_main_ship_to_location: ship not in a departable state (fleet %, ship %/%)',
        v_fleet.status, v_ship.status, v_ship.spatial_state;
    end if;
    v_depart_from      := 'hold';
    v_origin_type      := 'space';
    v_origin_zone      := null;
    v_origin_location  := null;
    v_origin_x         := v_ship.space_x;
    v_origin_y         := v_ship.space_y;
    v_from_location_id := null;
  end if;

  -- ── DESTINATION B (shared): exists, active, NON-COMBAT only ─────────────────────────────────────────────
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

  -- ── DEPART (shared mechanics): speed → movement_create → close presence → fleet→moving → in-flight mark ──
  -- Hull speed via the canonical resolver (the fleet carries no units). Depart A/hold-point → B, mission
  -- 'rally' (non-combat). origin_base is always NULL here (a present origin is a location; a held origin is
  -- open space — neither is a base).
  v_speed := resolve_fleet_movement_speed(p_fleet);

  v_movement := movement_create(
    v_player, p_fleet,
    v_origin_type, null, v_origin_zone, v_origin_location, v_origin_x, v_origin_y,
    'location', null, null, v_loc.id, v_loc.x, v_loc.y,
    'rally', v_speed);

  -- Close the departed presence (present origin only; a held ship has none).
  if v_depart_from = 'present' then
    perform presence_complete(v_presence.id);
  end if;

  -- Dedicated departure→moving transition, scoped to THIS main-ship fleet, guarded by the captured departure
  -- state (present: status='present'; hold: status='completed' — the 0155 held-fleet shape). Both require
  -- active_movement_id NULL (present fleets already satisfy it; the held fleet's Stop cancelled its movement).
  -- One shared SET clause; raise + roll back on a guarded-update miss (the 0053 discipline).
  update fleets
    set status = 'moving', location_mode = 'movement', active_movement_id = v_movement,
        current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
        updated_at = now()
    where id = p_fleet and active_movement_id is null
      and ( (v_depart_from = 'present' and status = 'present')
         or (v_depart_from = 'hold'    and status = 'completed') );
  if not found then
    raise exception 'move_main_ship_to_location: fleet % no longer in its % departure state', p_fleet, v_depart_from;
  end if;

  -- Main ship → legacy in-flight (status + spatial_state=NULL pair-write; the ONE shared 0152 helper). For a
  -- held departure this same write clears the held space_x/space_y as the ship leaves the hold point.
  perform public.mainship_mark_legacy_in_flight(v_fleet.main_ship_id, 'traveling');

  select arrive_at into v_arrive from fleet_movements where id = v_movement;
  return jsonb_build_object(
    'fleet_id', p_fleet, 'movement_id', v_movement, 'main_ship_id', v_fleet.main_ship_id,
    'from', v_depart_from, 'from_location_id', v_from_location_id, 'to_location_id', v_loc.id,
    'arrive_at', v_arrive);
end;
$$;

-- Execute surface preserved verbatim (authenticated only; CREATE OR REPLACE already preserves it — re-emitted
-- for explicitness). No other grant surface changes.
revoke execute on function public.move_main_ship_to_location(uuid, uuid) from public, anon;
grant  execute on function public.move_main_ship_to_location(uuid, uuid) to authenticated;
