-- Byeharu — OSN-3 S4: private coordinate-ARRIVAL processor (settles due coordinate moves). flag-dark.
--
-- Adds ONE internal, service_role-only, SECURITY DEFINER processor that settles a due, still-coherent
-- S3 coordinate movement exactly once, plus a pg_cron job to drive it on the established cadence. It
-- composes the deployed S2 boundary (lock → validate → cross-domain exclusion) and NEVER:
--   • gates on mainship_space_movement_enabled (that flag gates NEW-move admission only; settling an
--     already-created movement must always proceed so disabling the flag can't strand in-transit ships);
--   • touches mainship_send_enabled or the legacy named-location path;
--   • locks legacy fleet_movements (S2 canonical order only: ship → fleets → main_ship_space_movements
--     → location_presence);
--   • calls fleet_complete() (it assumes a return-to-base shape and would leave an invalid coordinate
--     pointer) — S4 uses a focused scoped update of the already-locked S3 fleet;
--   • mutates a contradictory / malformed / destroyed / non-in_transit context (frozen failure policy:
--     leave every affected row UNTOUCHED, emit a concise log, defer to a later hardening slice);
--   • creates a receipt (the S3 creation receipt stays immutable), creates/leaves any location_presence,
--     deletes history, repairs, or normalizes anything.
--
-- Arrival truthful terminal state (verified permitted by the actual fleets CHECK constraints —
-- status='completed' with location_mode='movement' is legal once active_space_movement_id is cleared):
--   movement: moving → arrived, resolved_at=now(), terminal_reason='auto_arrival' (history immutable)
--   ship:     traveling/in_transit/(x,y NULL) → stationary/in_space/(x,y = movement.target_x/target_y)
--   fleet:    moving/movement/active_space=mv → completed/movement/active_space=NULL/active_movement=NULL,
--             all named-location & base fields cleared (arrival is in OPEN SPACE, not at a base).

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
  -- 1) NON-LOCKING candidate scan: due, still-moving rows only. A plain plpgsql FOR-cursor takes NO
  --    row locks, so no coordinate movement is ever locked before its ship.
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
      -- 3) skipped (ship held by another worker) or not_found → no-op this tick (retries next tick).
      continue;
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

    -- 7) settle atomically (movement → fleet → ship; all rows already locked).
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

    v_settled := v_settled + 1;
  end loop;

  -- 8) count of movements actually settled this run.
  return v_settled;
end;
$$;

-- ── pg_cron: drive the arrival processor on the established cadence (same convention as
--    process-fleet-movements / process-mainship-expeditions). Unschedule-by-name first so a re-run
--    cannot create a duplicate job. Only the cron job calls the processor; clients never do.
create extension if not exists pg_cron;
do $$
begin
  perform cron.unschedule(jobid) from cron.job where jobname = 'process-mainship-space-arrivals';
exception
  when undefined_table then null;  -- cron schema not ready yet (first run handles it)
end;
$$;
select cron.schedule(
  'process-mainship-space-arrivals',
  '30 seconds',
  $$select public.process_mainship_space_arrivals();$$
);

-- ── Re-lock execute surface (anti-cheat). The new processor default-grants to PUBLIC on create →
--    revoke and re-grant ONLY the canonical client RPC list (carried verbatim from 0057). The new
--    processor + the S3 writer + the four S2 helpers + the existing server fns are service_role ONLY.
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
