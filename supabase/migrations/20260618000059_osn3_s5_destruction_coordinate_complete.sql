-- Byeharu — OSN-3 S5: make the trusted main-ship destruction primitive COORDINATE-COMPLETE.
--
-- Narrow, final coordinate-state compatibility hardening for ONE demonstrated defect: the trusted
-- destruction writer public.dev_set_main_ship_destroyed(p_player) predates the coordinate domain
-- (0055) and therefore cannot destroy a main ship that is in a valid coordinate state without
-- violating a coordinate constraint:
--   • in_transit → the fleet→'destroyed' update leaves fleets.active_space_movement_id set, violating
--     fleets_active_space_movement_requires_moving (pointer set but status<>'moving');
--   • in_space / at_location → the ship→'destroyed' update leaves a non-null spatial_state, violating
--     main_ship_instances_ss_{in_space,at_location}_status (those states require status='stationary').
--
-- dev_set_main_ship_destroyed is the UNIQUE trusted main-ship destruction writer (audited: the only fn
-- that sets main_ship_instances.status='destroyed'/hp=0; combat destroys legacy unit-fleets via
-- fleet_destroy, never main ships; repair_main_ship only recovers → 'home'). So fixing it fixes the
-- whole destruction surface. This re-creates that function ONLY — same signature, same SECURITY
-- DEFINER / owner / search_path / service-role-only boundary. It does NOT add a player wrapper, a cron
-- job, a scheduler, a reconciler, or any frontend change, and it does NOT modify repair_main_ship,
-- process_mainship_space_arrivals, mainship_space_begin_move, or any legacy writer. It NEVER reads or
-- changes a feature flag. Migrations 0052/0055/0056/0057/0058 are untouched.
--
-- Frozen decisions: D-1 destroyed spatial_state=NULL (keeps repair_main_ship valid — repair sets
-- status='home' but never resets spatial_state, and NULL is valid for both destroyed and legacy_home);
-- D-2 active coordinate movement → status='cancelled', terminal_reason='ship_destroyed', resolved_at;
-- D-3 acquire mainship_space_lock_context(id,false) first (canonical order ship→fleets→
-- main_ship_space_movements→location_presence; never locks fleet_movements); D-4 only a COHERENT
-- trusted-path state may be auto-destroyed — any generic contradiction ABORTS atomically (raise →
-- full rollback, every row unchanged); D-5 all existing legacy destruction cleanup is preserved,
-- coordinate cleanup is purely additive. Coordinate movement history is preserved (cancelled, not
-- deleted); the S3 command receipt is immutable.

create or replace function public.dev_set_main_ship_destroyed(p_player uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ship    main_ship_instances%rowtype;
  v_lock    jsonb;
  v_val     jsonb;
  v_state   text;
  v_fleet   record;
  v_cleaned integer := 0;
  v_coord_cancelled integer := 0;
begin
  select * into v_ship from main_ship_instances where player_id = p_player;
  if v_ship.main_ship_id is null then
    raise exception 'dev_set_main_ship_destroyed: no main ship for player %', p_player;
  end if;

  -- D-3: acquire the canonical S2 lock context FIRST (ship → fleets → coordinate movement → presence;
  -- legacy fleet_movements is never locked). Serializes against the S4 arrival processor.
  v_lock := public.mainship_space_lock_context(v_ship.main_ship_id, false);
  if (v_lock->>'status') is distinct from 'locked' then
    raise exception 'dev_set_main_ship_destroyed: could not acquire lock context for ship % (status %)', v_ship.main_ship_id, v_lock->>'status';
  end if;
  select * into v_ship from main_ship_instances where main_ship_id = v_ship.main_ship_id;  -- re-read under lock

  -- D-4: only a COHERENT state (legacy or coordinate) may be auto-destroyed. A generic cross-domain
  -- contradiction / malformed coordinate linkage is left ENTIRELY untouched: abort atomically so the
  -- whole operation rolls back with every row unchanged. The primitive cleans only the coherent state
  -- created by its own trusted lifecycle operation; it never reconciles/normalizes/guesses.
  v_val := public.mainship_space_validate_context(v_ship.main_ship_id);
  if (v_val->>'ok')::boolean is not true then
    raise exception 'dev_set_main_ship_destroyed: refusing to destroy a contradictory/malformed coordinate state (reason=%); all rows left unchanged', coalesce(v_val->>'reason', 'contradictory_state');
  end if;
  v_state := v_val->>'state';

  -- (1) coherent ACTIVE coordinate movement (in_transit only): cancel it (D-2). History preserved.
  if v_state = 'in_transit' then
    update main_ship_space_movements
      set status = 'cancelled', resolved_at = now(), terminal_reason = 'ship_destroyed'
      where main_ship_id = v_ship.main_ship_id and status = 'moving';
    get diagnostics v_coord_cancelled = row_count;
  end if;

  -- (2) per active linked main-ship fleet: PRESERVED legacy cleanup (cancel in-flight legacy movement,
  --     close presence, mark the zero-unit fleet terminal) + ADDITIVE coordinate pointer clear.
  for v_fleet in
    select id from fleets
    where main_ship_id = v_ship.main_ship_id and status in ('idle','moving','present','returning')
  loop
    update fleet_movements set status = 'cancelled', resolved_at = now()
      where fleet_id = v_fleet.id and status = 'moving';
    update location_presence set status = 'completed', updated_at = now()
      where fleet_id = v_fleet.id and status in ('active','retreating','leaving');
    update fleets
      set status = 'destroyed', location_mode = 'destroyed',
          active_movement_id = null, active_space_movement_id = null,
          current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
          updated_at = now()
      where id = v_fleet.id;
    v_cleaned := v_cleaned + 1;
  end loop;

  -- (3) ship terminal: destroyed wins; persistent row kept; hp 0; coordinate spatial state cleared.
  --     D-1: spatial_state=NULL (not 'destroyed') so repair_main_ship (status→'home', no spatial reset)
  --     stays valid → a repaired ship is a clean legacy_home.
  update main_ship_instances
    set status = 'destroyed', hp = 0, spatial_state = null, space_x = null, space_y = null, updated_at = now()
    where main_ship_id = v_ship.main_ship_id;

  return jsonb_build_object(
    'main_ship_id', v_ship.main_ship_id, 'status', 'destroyed', 'hp', 0,
    'fleets_cleaned', v_cleaned, 'coordinate_movements_cancelled', v_coord_cancelled);
end;
$$;

-- ── Re-lock execute surface (anti-cheat). The re-created function default-grants to PUBLIC → revoke and
--    re-grant ONLY the canonical client RPC list (carried verbatim from 0058). dev_set_main_ship_destroyed
--    + the S4 processor + S3 writer + four S2 helpers + existing server fns stay service_role ONLY.
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
grant execute on function public.mainship_space_lock_context(uuid, boolean)       to service_role;
grant execute on function public.mainship_space_validate_context(uuid)            to service_role;
grant execute on function public.mainship_space_resolve_origin(uuid)              to service_role;
grant execute on function public.mainship_space_assert_cross_domain_exclusion(uuid) to service_role;
grant execute on function public.mainship_space_begin_move(uuid, uuid, double precision, double precision, uuid) to service_role;
grant execute on function public.process_mainship_space_arrivals()               to service_role;
