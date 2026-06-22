-- Byeharu — OSN-DOCK-0: explicit named-location ARRIVAL (docking) for the coordinate domain. flag-dark.
--
-- The smallest missing replacement capability identified by PRES-0: when a main ship completes an OSN
-- coordinate movement that EXPLICITLY targets a named location (target_kind='location' + target_location_id),
-- the arrival processor performs location docking (presence + at_location) instead of settling only to the
-- generic in_space state. Every other target_kind keeps the existing in_space settlement byte-for-byte.
--
-- This pass adds:
--   1. ONE private, service_role-only docking primitive  public.mainship_space_dock_at_location(ship, mv)
--      that, for an already-locked due location-targeted movement, either DOCKS (valid+active+'none' target)
--      or applies a DETERMINISTIC, NON-RETRIABLE TERMINAL FAILURE (status='failed' + terminal_reason +
--      ship left in_space at the destination) for any non-dockable target.
--   2. The minimum branch in public.process_mainship_space_arrivals() to invoke the primitive for location
--      targets. The S4 lock → validate(in_transit) → cross-domain-exclusion → re-read-under-lock → linkage
--      frame is UNCHANGED; only step 7's settlement branches.
--
-- HARD BOUNDARIES (PRES-0 / DOCK-0 charter):
--   • supported dock predicate EXACTLY: target_kind='location' AND target_location_id present AND target
--     location.status='active' AND target location.activity_type='none' AND target_x/target_y EQUAL the
--     location's x/y (explicit-target integrity; NEVER coordinate-proximity docking inference);
--   • NEVER reads / writes / locks / depends on fleet_movements; NEVER calls or alters legacy
--     process_fleet_movements (no shared helper); generic unit fleets are untouched;
--   • runs ONLY under the S4 processor's existing transaction + canonical S2 lock order
--     (ship → fleets → main_ship_space_movements → location_presence); preserves exactly-once;
--   • dark: mainship_space_movement_enabled and mainship_send_enabled are NEITHER read NOR changed here;
--     the current writer (S3/S6A) only ever creates target_kind='space' moves, so in production NO location
--     target is created and this branch is never reached (double-dark);
--   • no new public RPC, no client grant, no UI, no flag flip, no legacy deletion, no coordinate/data change.

-- ── A. Private docking primitive (service_role-only; invoked inside the S4 lock frame) ───────────────────
-- Contract: the caller (process_mainship_space_arrivals) has already locked + validated a coherent
-- in_transit ship whose single active 'moving' movement is p_movement_id. This primitive re-reads those
-- (already-locked) rows, evaluates the dock predicate, and SETTLES the movement exactly once:
--   • DOCK (predicate holds): movement → arrived/'auto_arrival'; fleet → present/location (pointers cleared);
--     ship → stationary/at_location/(NULL,NULL); presence_create(...,'none') → one active presence, no
--     unsupported activity (activity_start('none') is a no-op).
--   • TERMINAL FAILURE (predicate fails — inactive/coordinate-mismatch/unsupported-activity/incoherent):
--     movement → failed/<deterministic terminal_reason>; fleet → completed/movement (pointers+base cleared);
--     ship → stationary/in_space/(target_x,target_y); NO presence, NO activity. status='failed' is terminal
--     (resolved_at set) so the due-scan and the status='moving' partial indices never re-select it: no loop.
-- Returns a jsonb summary {ok, docked, reason?, location_id?} for the processor's log/telemetry.
create or replace function public.mainship_space_dock_at_location(p_main_ship_id uuid, p_movement_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mv     main_ship_space_movements%rowtype;
  v_fleet  fleets%rowtype;
  v_loc    record;
  v_reason text;
begin
  -- Re-read the candidate movement under the caller's existing lock (same transaction). Defensive: the
  -- caller already proved this is the active, due, coherent movement; bail without mutating if not.
  select * into v_mv from main_ship_space_movements
    where id = p_movement_id and main_ship_id = p_main_ship_id and status = 'moving';
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'movement_not_moving');
  end if;

  -- This primitive handles ONLY explicit location targets (the table CHECK already binds target_location_id
  -- to target_kind='location', but re-assert defensively — never infer a location target).
  if v_mv.target_kind <> 'location' or v_mv.target_location_id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_location_target');
  end if;

  select * into v_fleet from fleets where id = v_mv.fleet_id;

  -- Resolve the target location + its zone/sector. (target_location_id is a NO-ACTION FK → a referenced
  -- location cannot be hard-deleted, so a NULL here is an impossible/corrupt row, handled defensively.)
  select l.id as id, l.x as x, l.y as y, l.zone_id as zone_id, l.status as status,
         l.activity_type as activity_type, z.sector_id as sector_id
    into v_loc
    from locations l join zones z on z.id = l.zone_id
    where l.id = v_mv.target_location_id;

  -- ── Dock predicate → choose DOCK (v_reason NULL) vs deterministic TERMINAL FAILURE (v_reason set) ──────
  if v_loc.id is null then
    v_reason := 'undockable_invalid_target';            -- FK-prevented; defensive only
  elsif v_loc.status <> 'active' then
    v_reason := 'undockable_inactive_location';
  elsif v_loc.x is distinct from v_mv.target_x or v_loc.y is distinct from v_mv.target_y then
    v_reason := 'undockable_coordinate_mismatch';       -- explicit-target integrity (NOT proximity)
  elsif v_loc.activity_type <> 'none' then
    v_reason := 'undockable_unsupported_activity';       -- DOCK-0 supports only activity_type='none'
  else
    v_reason := null;                                    -- dockable
  end if;

  if v_reason is not null then
    -- DETERMINISTIC TERMINAL FAILURE: ship floats in open space at the destination coordinate. This reuses
    -- the in_space settlement shape (the proven S4 space-arrival columns) but marks the movement 'failed'
    -- with an explicit reason — never a silent in_space success, never a partial dock, never a loop.
    update main_ship_space_movements
      set status = 'failed', resolved_at = now(), terminal_reason = v_reason
      where id = v_mv.id and status = 'moving';

    update fleets
      set status = 'completed', location_mode = 'movement',
          active_space_movement_id = null, active_movement_id = null,
          current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
          updated_at = now()
      where id = v_fleet.id;

    update main_ship_instances
      set status = 'stationary', spatial_state = 'in_space',
          space_x = v_mv.target_x, space_y = v_mv.target_y, updated_at = now()
      where main_ship_id = p_main_ship_id;

    return jsonb_build_object('ok', true, 'docked', false, 'reason', v_reason);
  end if;

  -- ── DOCK: settle the movement, dock the fleet at the location, create exactly one active presence ──────
  update main_ship_space_movements
    set status = 'arrived', resolved_at = now(), terminal_reason = 'auto_arrival'
    where id = v_mv.id and status = 'moving';

  -- Fleet → present at the location (mirrors fleet_set_present, additionally clearing the coordinate pointer;
  -- a direct scoped update, never the legacy state-machine, so this path has no legacy coupling).
  update fleets
    set status = 'present', location_mode = 'location',
        active_space_movement_id = null, active_movement_id = null,
        current_base_id = null,
        current_location_id = v_loc.id, current_zone_id = v_loc.zone_id, current_sector_id = v_loc.sector_id,
        updated_at = now()
    where id = v_fleet.id;

  -- Ship → docked. at_location REQUIRES NULL coordinates (main_ship_instances_space_coords); the destination
  -- coordinate remains immutably recorded on the now-arrived movement row.
  update main_ship_instances
    set status = 'stationary', spatial_state = 'at_location',
        space_x = null, space_y = null, updated_at = now()
    where main_ship_id = p_main_ship_id;

  -- Presence + activity via the Presence owner (location-domain reusable effect; activity_type='none' makes
  -- activity_start a no-op — no M4-gated activity is reached). one_active_presence_per_fleet backstops dups.
  perform public.presence_create(v_mv.player_id, v_mv.fleet_id, v_loc.sector_id, v_loc.zone_id, v_loc.id, 'none');

  return jsonb_build_object('ok', true, 'docked', true, 'location_id', v_loc.id);
end;
$$;

-- ── B. process_mainship_space_arrivals — minimum branch to invoke the docking primitive ──────────────────
-- Re-created verbatim from 0058 EXCEPT step 7, which now branches on target_kind: 'location' delegates to the
-- private docking primitive; every other kind keeps the original in_space settlement byte-for-byte. The
-- non-locking due scan, the canonical-order ship claim (skip-locked), the in_transit coherence validate, the
-- cross-domain exclusion, and the re-read-under-lock linkage checks are ALL unchanged → exactly-once and the
-- frozen-failure (leave-untouched) policy for incoherent contexts are preserved.
create or replace function public.process_mainship_space_arrivals()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  cand     record;
  v_lock   jsonb;
  v_val    jsonb;
  v_excl   jsonb;
  v_mv     main_ship_space_movements%rowtype;
  v_fleet  fleets%rowtype;
  v_settled integer := 0;
begin
  -- 1) NON-LOCKING candidate scan: due, still-moving rows only.
  for cand in
    select main_ship_id, id as movement_id
    from main_ship_space_movements
    where status = 'moving' and arrive_at <= now()
    order by arrive_at, id
    limit 100
  loop
    -- 2) claim the SHIP first, skip-locked (canonical order ship → fleet → movement → presence).
    v_lock := public.mainship_space_lock_context(cand.main_ship_id, true);
    if (v_lock->>'status') is distinct from 'locked' then
      continue;  -- 3) held by another worker / not_found → retry next tick
    end if;

    -- 4) the locked context must be a coherent in_transit ship.
    v_val := public.mainship_space_validate_context(cand.main_ship_id);
    if (v_val->>'ok')::boolean is not true or (v_val->>'state') is distinct from 'in_transit' then
      raise notice 'process_mainship_space_arrivals: skip (not coherent in_transit) ship=% movement=% reason=%',
        cand.main_ship_id, cand.movement_id, coalesce(v_val->>'reason', v_val->>'state');
      continue;  -- frozen failure policy: leave every affected row UNTOUCHED
    end if;

    -- 5) cross-domain exclusion: no active legacy movement / pointer conflict / presence conflict.
    v_excl := public.mainship_space_assert_cross_domain_exclusion(cand.main_ship_id);
    if (v_excl->>'ok')::boolean is not true then
      raise notice 'process_mainship_space_arrivals: skip (cross-domain exclusion) ship=% movement=% reason=%',
        cand.main_ship_id, cand.movement_id, v_excl->>'reason';
      continue;
    end if;

    -- 6) re-read UNDER LOCK and confirm the candidate is still the active, due, coherently-linked move.
    select * into v_mv from main_ship_space_movements
      where main_ship_id = cand.main_ship_id and status = 'moving';
    if not found or v_mv.id is distinct from cand.movement_id or v_mv.arrive_at > now() then
      raise notice 'process_mainship_space_arrivals: skip (no longer the active/due movement) ship=% movement=%',
        cand.main_ship_id, cand.movement_id;
      continue;
    end if;
    select * into v_fleet from fleets where id = v_mv.fleet_id;
    if not found
       or v_fleet.main_ship_id is distinct from cand.main_ship_id
       or v_fleet.status <> 'moving'
       or v_fleet.location_mode <> 'movement'
       or v_fleet.active_space_movement_id is distinct from v_mv.id
       or v_fleet.active_movement_id is not null
       or v_mv.player_id is distinct from v_fleet.player_id then
      raise notice 'process_mainship_space_arrivals: skip (fleet/movement linkage mismatch) ship=% movement=%',
        cand.main_ship_id, cand.movement_id;
      continue;
    end if;

    -- 7) settle atomically (all rows already locked). OSN-DOCK-0: an explicit named-location target is
    --    settled by the private docking primitive (dock OR deterministic terminal failure); EVERY other
    --    target_kind keeps the original in_space settlement, byte-for-byte unchanged.
    if v_mv.target_kind = 'location' then
      perform public.mainship_space_dock_at_location(cand.main_ship_id, v_mv.id);
    else
      update main_ship_space_movements
        set status = 'arrived', resolved_at = now(), terminal_reason = 'auto_arrival'
        where id = v_mv.id and status = 'moving';

      update fleets
        set status = 'completed', location_mode = 'movement',
            active_space_movement_id = null, active_movement_id = null,
            current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
            updated_at = now()
        where id = v_fleet.id;

      update main_ship_instances
        set status = 'stationary', spatial_state = 'in_space',
            space_x = v_mv.target_x, space_y = v_mv.target_y, updated_at = now()
        where main_ship_id = cand.main_ship_id;
    end if;

    v_settled := v_settled + 1;
  end loop;

  -- 8) count of movements actually settled this run.
  return v_settled;
end;
$$;

-- ── C. Re-lock execute surface (anti-cheat). The new primitive + the re-created processor default-grant to
--    PUBLIC on create → revoke and re-grant ONLY the canonical client RPC list (carried verbatim from 0060).
--    The new docking primitive joins the service_role-only server set; the client NEVER gains it; there is
--    no public/anon/authenticated callable surface for docking.
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
grant execute on function public.command_main_ship_space_move(double precision, double precision, uuid) to authenticated;
-- Server / CI only (service_role); NEVER clients:
grant execute on function public.dev_set_main_ship_destroyed(uuid)                to service_role;
grant execute on function public.resolve_fleet_movement_speed(uuid)               to service_role;
grant execute on function public.process_mainship_expeditions()                   to service_role;
grant execute on function public.mainship_space_lock_context(uuid, boolean)       to service_role;
grant execute on function public.mainship_space_validate_context(uuid)            to service_role;
grant execute on function public.mainship_space_resolve_origin(uuid)              to service_role;
grant execute on function public.mainship_space_assert_cross_domain_exclusion(uuid) to service_role;
grant execute on function public.mainship_space_begin_move(uuid, uuid, double precision, double precision, uuid) to service_role;
grant execute on function public.process_mainship_space_arrivals()               to service_role;
grant execute on function public.mainship_space_dock_at_location(uuid, uuid)      to service_role;  -- NEW (DOCK-0)
