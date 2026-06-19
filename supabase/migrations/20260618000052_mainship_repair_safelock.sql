-- Byeharu — Phase 10F: main-ship destroyed/repair SAFELOCK foundation.
--
-- A persistent main ship must be able to LOSE (later, in 10G combat) without ever deleting the
-- player's core ship or soft-locking the account. This migration adds the safe landing + recovery
-- path. It does NOT add combat, a damage formula, a cost, a cooldown, a timer, or any trigger.
--
-- SEMANTICS (important): main_ship_instances.status = 'destroyed' is REUSED to mean
-- "disabled / needs repair" for a PERSISTENT main ship. The row is NEVER deleted. The UI shows it
-- as "Disabled / Needs repair". repair_main_ship() is the ONLY normal player recovery path.
-- (No new enum/status, no new columns — 'destroyed', hp, max_hp already exist in migration 0043.)
--
-- Scope decisions (documented, intentional):
--   • process_mainship_expeditions is LEFT UNTOUCHED — it only reconciles status in
--     ('traveling','returning') → 'home', so it can never flip a 'destroyed' ship home. Only
--     repair_main_ship() recovers destroyed → home.
--   • send_main_ship_expedition / request_main_ship_return are LEFT UNTOUCHED — they already
--     require status='home' / an active present fleet, so a destroyed ship is naturally blocked.
--   • resolve_fleet_movement_speed / movement_create / presence_request_leave / process_combat_ticks
--     / fleet_destroy / fleet_create / fleet_speed / send_fleet_to_location — all UNTOUCHED.

-- ── 1) repair_main_ship: the only normal player recovery path (instant, free, no cooldown) ──────
create or replace function public.repair_main_ship()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_ship   main_ship_instances%rowtype;
begin
  if v_player is null then
    raise exception 'repair_main_ship: not authenticated';
  end if;

  -- auth.uid()-scoped: a player can only repair their OWN ship (no griefing of others).
  select * into v_ship from main_ship_instances where player_id = v_player;
  if v_ship.main_ship_id is null then
    raise exception 'repair_main_ship: no main ship found';
  end if;
  if v_ship.status <> 'destroyed' then
    raise exception 'repair_main_ship: ship is not disabled (status %) — nothing to repair', v_ship.status;
  end if;
  if v_ship.max_hp is null or v_ship.max_hp <= 0 then
    raise exception 'repair_main_ship: invalid max_hp (%)', v_ship.max_hp;
  end if;

  -- Restore to full readiness, back home. No fleets/fleet_units/movements/presences created.
  update main_ship_instances
    set hp = v_ship.max_hp, status = 'home', updated_at = now()
    where main_ship_id = v_ship.main_ship_id;

  return jsonb_build_object(
    'main_ship_id', v_ship.main_ship_id, 'status', 'home',
    'hp', v_ship.max_hp, 'max_hp', v_ship.max_hp);
end;
$$;

-- ── 2) dev_set_main_ship_destroyed: server/service-role-ONLY disable + cleanup helper ───────────
-- Because combat does not destroy main ships yet, 10F needs a controlled way to put a ship into
-- the destroyed/needs-repair state for verification. This is the SAME primitive 10G combat will
-- reuse. It is NOT a player RPC: it is granted to service_role ONLY (the relock below revokes it
-- from public/anon/authenticated), so a normal user can never call it.
--
-- DEDICATED main-ship cleanup (NOT legacy fleet_destroy): for each active linked main-ship fleet
-- (zero fleet_units), cancel its in-flight movement, close its presence, and mark the fleet
-- terminal — so no stale movement/presence can later revive the destroyed ship, and the reconciler
-- (which only touches traveling/returning) sees no active fleet. "Destroyed" wins over in-flight.
create or replace function public.dev_set_main_ship_destroyed(p_player uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ship    main_ship_instances%rowtype;
  v_fleet   record;
  v_cleaned integer := 0;
begin
  select * into v_ship from main_ship_instances where player_id = p_player;
  if v_ship.main_ship_id is null then
    raise exception 'dev_set_main_ship_destroyed: no main ship for player %', p_player;
  end if;

  for v_fleet in
    select id from fleets
    where main_ship_id = v_ship.main_ship_id
      and status in ('idle','moving','present','returning')
  loop
    -- cancel any in-flight movement so process_fleet_movements never resolves it
    update fleet_movements set status = 'cancelled', resolved_at = now()
      where fleet_id = v_fleet.id and status = 'moving';
    -- close any presence so it is no longer "at" a location
    update location_presence set status = 'completed', updated_at = now()
      where fleet_id = v_fleet.id and status in ('active','retreating','leaving');
    -- mark the (zero-unit) main-ship fleet terminal (mirrors fleet_destroy's fields, no unit logic)
    update fleets
      set status = 'destroyed', location_mode = 'destroyed', active_movement_id = null,
          current_location_id = null, current_zone_id = null, current_sector_id = null,
          updated_at = now()
      where id = v_fleet.id;
    v_cleaned := v_cleaned + 1;
  end loop;

  -- Destroyed wins: persistent row kept; hp 0; recoverable only via repair_main_ship().
  update main_ship_instances
    set status = 'destroyed', hp = 0, updated_at = now()
    where main_ship_id = v_ship.main_ship_id;

  return jsonb_build_object(
    'main_ship_id', v_ship.main_ship_id, 'status', 'destroyed', 'hp', 0, 'fleets_cleaned', v_cleaned);
end;
$$;

-- ── 3) Re-lock execute surface (anti-cheat) ──────────────────────────────────────
-- New functions default-grant to PUBLIC → revoke and re-grant only the canonical client RPCs
-- (carried from migration 0051) plus repair_main_ship (player recovery). dev_set_main_ship_destroyed
-- is service_role ONLY. Prior service_role grants (resolver/reconciler) survive the revoke; re-stated
-- for clarity. repair_main_ship is intentionally NOT flag-gated — recovery must always be possible
-- (the safelock guarantee), even if mainship_send_enabled is false.
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
-- Server / CI only (service_role); NEVER clients:
grant execute on function public.dev_set_main_ship_destroyed(uuid)                to service_role;
grant execute on function public.resolve_fleet_movement_speed(uuid)               to service_role;
grant execute on function public.process_mainship_expeditions()                   to service_role;
