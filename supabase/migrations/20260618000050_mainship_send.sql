-- Byeharu — Phase 10C: the FIRST main-ship write path (narrow, additive, flag-gated).
--
-- GOAL: let a persistent main ship go on a NON-COMBAT expedition and come home, WITHOUT
-- pretending to be a disposable old-style unit fleet. This is the first brick of the
-- Main Ship transition (docs/MAINSHIP_TRANSITION.md). It is deliberately small:
--   • NON-COMBAT ONLY  — destination location.activity_type must be 'none' (safe zone).
--   • FLAG-GATED       — off by default (game_config 'mainship_send_enabled').
--   • ADDITIVE         — the proven send_fleet_to_location / fleet_create / fleet_speed /
--                        presence_request_leave / process_fleet_movements paths are
--                        COMPLETELY UNTOUCHED. No combat, no destruction, no support craft.
--
-- DESIGN — "narrow main-ship bridge, not a fake old-unit fleet":
--   A main-ship expedition reuses the movement SPINE (movement_create / fleet_set_moving /
--   process_fleet_movements) but its fleet carries NO fleet_units. Because the row has zero
--   fleet_units:
--     • base_reserve_units / fleet_create are NOT used (fleet_create rejects empty fleets) —
--       the fleets row is inserted DIRECTLY, tagged with main_ship_id.
--     • fleet_speed() is NOT used (it is NULL for a unit-less fleet) — speed comes from the
--       hull (main_ship_hull_types.base_speed).
--     • presence_request_leave() is NOT used (it reads fleet_speed) — a dedicated main-ship
--       return helper computes return speed from the hull.
--     • process_fleet_movements' return branch already no-ops base_merge_units when there are
--       no units (jsonb_agg → NULL) and deposits no reward (no cargo attached), so a
--       unit-less main-ship fleet completes cleanly with ZERO base/unit pollution.
--   fleet_create / fleet_speed / presence_request_leave / send_fleet_to_location are NOT
--   modified — main ships are a separate, parallel write path, not a hybrid adapter.
--
-- OWNERSHIP (SYSTEM_BOUNDARIES): still Fleet/Movement/Presence as sole writers of their
-- tables via their existing state-machine functions. This migration only ADDS a nullable
-- fleets.main_ship_id tag + three SECURITY DEFINER functions that compose those existing
-- writers. The Main Ship system owns main_ship_instances.status transitions for expeditions.

-- ── 1) Feature flag (OFF by default) ─────────────────────────────────────────────
insert into public.game_config (key, value, description) values
  ('mainship_send_enabled', 'false', 'Phase 10C: enable the non-combat main-ship expedition write path')
on conflict (key) do nothing;

-- ── 2) Tag a fleet as a main-ship expedition (nullable; old fleets stay NULL) ─────
alter table public.fleets
  add column if not exists main_ship_id uuid
    references public.main_ship_instances (main_ship_id) on delete set null;
create index if not exists fleets_main_ship_id_idx
  on public.fleets (main_ship_id) where main_ship_id is not null;

-- ── 3) send_main_ship_expedition: outbound, NON-COMBAT, exactly one ship ──────────
-- Group-ready signature (p_ships jsonb) but validates EXACTLY ONE ship for Phase 10C.
-- Ship-id-parameterised (never assumes "the player's one ship").
create or replace function public.send_main_ship_expedition(p_ships jsonb, p_location uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_ship_id  uuid;
  v_ship     record;
  v_hull     record;
  v_base     record;
  v_loc      record;
  v_max      integer;
  v_active   integer;
  v_speed    double precision;
  v_fleet    uuid;
  v_movement uuid;
  v_arrive   timestamptz;
begin
  if v_player is null then
    raise exception 'send_main_ship_expedition: not authenticated';
  end if;

  -- Flag gate (off by default).
  if not cfg_bool('mainship_send_enabled') then
    raise exception 'send_main_ship_expedition: feature disabled';
  end if;

  -- Exactly one ship in Phase 10C (the param is group-ready for later phases).
  if p_ships is null or jsonb_typeof(p_ships) <> 'array' or jsonb_array_length(p_ships) <> 1 then
    raise exception 'send_main_ship_expedition: exactly one ship required';
  end if;
  v_ship_id := (p_ships->>0)::uuid;
  if v_ship_id is null then
    raise exception 'send_main_ship_expedition: invalid ship id';
  end if;

  -- Ownership + availability (must be the caller's ship, currently home).
  select * into v_ship from main_ship_instances
    where main_ship_id = v_ship_id and player_id = v_player;
  if v_ship.main_ship_id is null then
    raise exception 'send_main_ship_expedition: ship not found or not owned';
  end if;
  if v_ship.status <> 'home' then
    raise exception 'send_main_ship_expedition: ship not available (status %)', v_ship.status;
  end if;

  -- Destination must exist, be active, and be NON-COMBAT (safe zone) for Phase 10C.
  select l.id, l.x, l.y, l.activity_type, l.status, l.zone_id, z.sector_id
    into v_loc
    from locations l join zones z on z.id = l.zone_id
    where l.id = p_location;
  if v_loc.id is null or v_loc.status <> 'active' then
    raise exception 'send_main_ship_expedition: location not found or inactive';
  end if;
  if v_loc.activity_type <> 'none' then
    raise exception 'send_main_ship_expedition: only non-combat locations supported in Phase 10C (got %)', v_loc.activity_type;
  end if;

  -- Active-fleet limit (shared budget with old fleets, by design).
  v_max := coalesce(cfg_num('max_active_fleets'), 3);
  select count(*) into v_active
    from fleets where player_id = v_player and status in ('moving','present','returning');
  if v_active >= v_max then
    raise exception 'send_main_ship_expedition: active fleet limit reached (%/%)', v_active, v_max;
  end if;

  -- The player's home base anchors the trip's origin + return target.
  select id, x, y, sector_id into v_base
    from bases where player_id = v_player and status = 'active'
    order by created_at limit 1;
  if v_base.id is null then
    raise exception 'send_main_ship_expedition: no active home base';
  end if;

  -- Speed comes from the HULL, never fleet_speed (the fleet has no units).
  select base_speed into v_hull from main_ship_hull_types where hull_type_id = v_ship.hull_type_id;
  if v_hull.base_speed is null then
    raise exception 'send_main_ship_expedition: hull % not found', v_ship.hull_type_id;
  end if;
  v_speed := v_hull.base_speed::double precision;

  -- Insert the fleets row DIRECTLY (fleet_create rejects empty fleets; we want zero units).
  -- Tagged with main_ship_id so the return helper + reconciler can recognise it.
  insert into fleets (player_id, origin_base_id, status, location_mode, current_base_id, main_ship_id)
    values (v_player, v_base.id, 'idle', 'base', v_base.id, v_ship_id)
    returning id into v_fleet;

  -- Reuse the movement spine (geometry/time only; mission 'rally' = non-combat).
  v_movement := movement_create(
    v_player, v_fleet,
    'base', v_base.id, null, null, v_base.x, v_base.y,
    'location', null, null, v_loc.id, v_loc.x, v_loc.y,
    'rally', v_speed);
  perform fleet_set_moving(v_fleet, v_movement);

  -- Mark the ship as out (Main Ship system owns this status).
  update main_ship_instances set status = 'traveling', updated_at = now()
    where main_ship_id = v_ship_id;

  select arrive_at into v_arrive from fleet_movements where id = v_movement;
  return jsonb_build_object(
    'fleet_id', v_fleet, 'movement_id', v_movement,
    'main_ship_id', v_ship_id, 'arrive_at', v_arrive);
end;
$$;

-- ── 4) request_main_ship_return: dedicated non-combat return (no fleet_units, no base_units)
-- Main-ship analogue of presence_request_leave, but speed comes from the hull. ONLY operates
-- on fleets tagged with main_ship_id. Does NOT touch base_units (there are none).
create or replace function public.request_main_ship_return(p_fleet uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_fleet    record;
  v_presence record;
  v_base     record;
  v_loc      record;
  v_hull     record;
  v_ship     record;
  v_speed    double precision;
  v_movement uuid;
begin
  if v_player is null then
    raise exception 'request_main_ship_return: not authenticated';
  end if;

  -- Must be the caller's main-ship fleet, currently present at a location.
  select * into v_fleet from fleets where id = p_fleet and player_id = v_player;
  if v_fleet.id is null then
    raise exception 'request_main_ship_return: fleet not found or not owned';
  end if;
  if v_fleet.main_ship_id is null then
    raise exception 'request_main_ship_return: not a main-ship fleet';
  end if;
  if v_fleet.status <> 'present' then
    raise exception 'request_main_ship_return: fleet not present (status %)', v_fleet.status;
  end if;

  -- The active presence pins the current location.
  select * into v_presence from location_presence
    where fleet_id = p_fleet and status = 'active';
  if v_presence.id is null then
    raise exception 'request_main_ship_return: no active presence for fleet';
  end if;

  select id, x, y into v_base from bases where id = v_fleet.origin_base_id;
  if v_base.id is null then
    raise exception 'request_main_ship_return: origin base missing';
  end if;
  select x, y into v_loc from locations where id = v_presence.location_id;

  -- Return speed from the HULL (the fleet has no units → fleet_speed would be NULL).
  select * into v_ship from main_ship_instances where main_ship_id = v_fleet.main_ship_id;
  select base_speed into v_hull from main_ship_hull_types where hull_type_id = v_ship.hull_type_id;
  if v_hull.base_speed is null then
    raise exception 'request_main_ship_return: hull speed unavailable';
  end if;
  v_speed := v_hull.base_speed::double precision;

  -- Close presence, then travel home (no base_units merge — there are none).
  perform presence_complete(v_presence.id);
  v_movement := movement_create(
    v_player, p_fleet,
    'location', null, v_presence.zone_id, v_presence.location_id, v_loc.x, v_loc.y,
    'base', v_base.id, null, null, v_base.x, v_base.y,
    'return_home', v_speed);
  perform fleet_set_returning(p_fleet, v_movement);

  -- Mark the ship as heading home (Main Ship system owns this status).
  update main_ship_instances set status = 'returning', updated_at = now()
    where main_ship_id = v_fleet.main_ship_id;

  return jsonb_build_object('return_movement_id', v_movement, 'main_ship_id', v_fleet.main_ship_id);
end;
$$;

-- ── 5) process_mainship_expeditions: tiny additive status reconciler (cron) ────────
-- The movement engine already drives the fleet (moving → present → returning → completed).
-- This reconciler ONLY syncs the ship's status back to 'home' once its tagged fleet is no
-- longer in flight. It writes NOTHING the movement engine owns — purely main_ship_instances.
create or replace function public.process_mainship_expeditions()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  -- A ship that is out (traveling/returning) but has no in-flight tagged fleet has come
  -- home (fleet completed) or lost its fleet → set it home. Idempotent.
  with homed as (
    update main_ship_instances s
      set status = 'home', updated_at = now()
      where s.status in ('traveling','returning')
        and not exists (
          select 1 from fleets f
          where f.main_ship_id = s.main_ship_id
            and f.status in ('moving','present','returning')
        )
      returning 1)
  select count(*) into v_count from homed;
  return v_count;
end;
$$;

-- Run the reconciler on the same 30s cadence as the movement processor.
create extension if not exists pg_cron;
select cron.schedule(
  'process-mainship-expeditions',
  '30 seconds',
  $$select public.process_mainship_expeditions();$$
);

-- ── 6) Re-lock execute surface (anti-cheat) ──────────────────────────────────────
-- New client RPCs: send_main_ship_expedition + request_main_ship_return. The reconciler is
-- server-only. Re-grant the full canonical client surface (carried from migration 0049) plus
-- the two new client RPCs; prior service_role grants survive a public/anon/authenticated revoke.
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
-- Server / CI only (service_role); NEVER clients:
grant execute on function public.process_mainship_expeditions()                   to service_role;
