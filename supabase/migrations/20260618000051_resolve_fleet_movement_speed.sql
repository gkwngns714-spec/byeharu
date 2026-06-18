-- Byeharu — Phase 10C/10D hardening: ONE canonical movement-speed resolver.
--
-- Before this, send_main_ship_expedition and request_main_ship_return each carried their OWN copy
-- of "speed = the ship's hull base_speed" SQL (duplication), and the legacy path used fleet_speed().
-- This migration introduces a single resolver that both kinds of fleet go through:
--
--   resolve_fleet_movement_speed(p_fleet) returns numeric
--     • main-ship fleet (fleets.main_ship_id is not null): speed = main_ship_hull_types.base_speed
--       (starter_frigate → 1.0); raises a clear error if the hull speed is missing/null/<= 0.
--     • legacy fleet: returns fleet_speed(p_fleet) UNCHANGED (the existing fleet_units min-speed calc).
--
-- It does NOT special-case NULL inside movement_create, and it does NOT insert fake fleet_units —
-- the unit-less main-ship fleet simply never reaches the legacy branch.
--
-- Call sites switched to the resolver:
--   • send_main_ship_expedition  (was inline hull SQL)        → resolver
--   • request_main_ship_return   (was inline hull SQL)        → resolver
--   • send_fleet_to_location     (legacy; fleet always has units + main_ship_id NULL → identical) → resolver
--
-- Deliberately NOT switched (documented):
--   • presence_request_leave — can be handed a MAIN-SHIP fleet's presence (via request_leave_location);
--     today that errors on NULL fleet_speed. Routing it through the resolver would CHANGE main-ship
--     behavior (silently leave without the main-ship status transition), so it is not behavior-neutral.
--   • process_combat_ticks — combat fleets are always legacy (units present, main_ship_id NULL), so it
--     is already correct via fleet_speed; re-emitting a ~300-line battle-tested combat function purely
--     to swap one provably-equivalent call is high risk / no behavior change. Left as-is intentionally.
--
-- OWNERSHIP: the resolver is a read-only helper (STABLE) that the existing SECURITY DEFINER writers
-- call as their owner. It is NOT a client RPC (server/internal + service_role for tests only).

-- ── 1) The canonical resolver ────────────────────────────────────────────────────
create or replace function public.resolve_fleet_movement_speed(p_fleet uuid)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_main_ship uuid;
  v_speed     numeric;
begin
  select main_ship_id into v_main_ship from fleets where id = p_fleet;

  if v_main_ship is not null then
    -- Main-ship fleet: speed comes from the hull (never fleet_units; it has none).
    select h.base_speed
      into v_speed
      from main_ship_instances s
      join main_ship_hull_types h on h.hull_type_id = s.hull_type_id
      where s.main_ship_id = v_main_ship;
    if v_speed is null or v_speed <= 0 then
      raise exception 'resolve_fleet_movement_speed: main ship % has no valid hull speed (got %)', v_main_ship, v_speed;
    end if;
    return v_speed;
  end if;

  -- Legacy fleet: the existing fleet_units-based slowest-unit speed, UNCHANGED.
  return fleet_speed(p_fleet);
end;
$$;

-- ── 2) send_main_ship_expedition → resolver (was inline hull SQL) ─────────────────
-- Note the reorder: the fleet row is inserted FIRST, then the resolver reads its main_ship_id.
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

  if not cfg_bool('mainship_send_enabled') then
    raise exception 'send_main_ship_expedition: feature disabled';
  end if;

  if p_ships is null or jsonb_typeof(p_ships) <> 'array' or jsonb_array_length(p_ships) <> 1 then
    raise exception 'send_main_ship_expedition: exactly one ship required';
  end if;
  v_ship_id := (p_ships->>0)::uuid;
  if v_ship_id is null then
    raise exception 'send_main_ship_expedition: invalid ship id';
  end if;

  select * into v_ship from main_ship_instances
    where main_ship_id = v_ship_id and player_id = v_player;
  if v_ship.main_ship_id is null then
    raise exception 'send_main_ship_expedition: ship not found or not owned';
  end if;
  if v_ship.status <> 'home' then
    raise exception 'send_main_ship_expedition: ship not available (status %)', v_ship.status;
  end if;

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

  v_max := coalesce(cfg_num('max_active_fleets'), 3);
  select count(*) into v_active
    from fleets where player_id = v_player and status in ('moving','present','returning');
  if v_active >= v_max then
    raise exception 'send_main_ship_expedition: active fleet limit reached (%/%)', v_active, v_max;
  end if;

  select id, x, y, sector_id into v_base
    from bases where player_id = v_player and status = 'active'
    order by created_at limit 1;
  if v_base.id is null then
    raise exception 'send_main_ship_expedition: no active home base';
  end if;

  -- Insert the fleets row DIRECTLY (no fleet_units), tagged with main_ship_id.
  insert into fleets (player_id, origin_base_id, status, location_mode, current_base_id, main_ship_id)
    values (v_player, v_base.id, 'idle', 'base', v_base.id, v_ship_id)
    returning id into v_fleet;

  -- Canonical speed resolver (main-ship branch → hull base_speed).
  v_speed := resolve_fleet_movement_speed(v_fleet);

  v_movement := movement_create(
    v_player, v_fleet,
    'base', v_base.id, null, null, v_base.x, v_base.y,
    'location', null, null, v_loc.id, v_loc.x, v_loc.y,
    'rally', v_speed);
  perform fleet_set_moving(v_fleet, v_movement);

  update main_ship_instances set status = 'traveling', updated_at = now()
    where main_ship_id = v_ship_id;

  select arrive_at into v_arrive from fleet_movements where id = v_movement;
  return jsonb_build_object(
    'fleet_id', v_fleet, 'movement_id', v_movement,
    'main_ship_id', v_ship_id, 'arrive_at', v_arrive);
end;
$$;

-- ── 3) request_main_ship_return → resolver (was inline hull SQL; no more NULL risk) ─
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
  v_speed    double precision;
  v_movement uuid;
begin
  if v_player is null then
    raise exception 'request_main_ship_return: not authenticated';
  end if;

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

  -- Canonical speed resolver (main-ship branch → hull base_speed). Never NULL for a main-ship fleet.
  v_speed := resolve_fleet_movement_speed(p_fleet);

  perform presence_complete(v_presence.id);
  v_movement := movement_create(
    v_player, p_fleet,
    'location', null, v_presence.zone_id, v_presence.location_id, v_loc.x, v_loc.y,
    'base', v_base.id, null, null, v_base.x, v_base.y,
    'return_home', v_speed);
  perform fleet_set_returning(p_fleet, v_movement);

  update main_ship_instances set status = 'returning', updated_at = now()
    where main_ship_id = v_fleet.main_ship_id;

  return jsonb_build_object('return_movement_id', v_movement, 'main_ship_id', v_fleet.main_ship_id);
end;
$$;

-- ── 4) send_fleet_to_location → resolver (legacy fleet: identical value, single entry point) ─
-- Re-emits the current (migration 0019) body verbatim, changing ONLY the speed source. The fleet is
-- freshly created via fleet_create (units present, main_ship_id NULL), so the resolver's legacy
-- branch returns fleet_speed(v_fleet) — the exact same value as before.
create or replace function public.send_fleet_to_location(
  p_base uuid, p_location uuid, p_units jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_base     record;
  v_loc      record;
  v_max      integer;
  v_active   integer;
  v_fleet    uuid;
  v_power    double precision;
  v_speed    double precision;
  v_mission  text;
  v_movement uuid;
  v_arrive   timestamptz;
begin
  if v_player is null then
    raise exception 'send_fleet_to_location: not authenticated';
  end if;

  select id, x, y, sector_id into v_base
    from bases where id = p_base and player_id = v_player and status = 'active';
  if v_base.id is null then
    raise exception 'send_fleet_to_location: base not found or not owned';
  end if;

  select l.id, l.x, l.y, l.activity_type, l.status, l.zone_id, l.min_power_required, z.sector_id
    into v_loc
    from locations l join zones z on z.id = l.zone_id
    where l.id = p_location;
  if v_loc.id is null or v_loc.status <> 'active' then
    raise exception 'send_fleet_to_location: location not found or inactive';
  end if;
  if v_loc.activity_type not in ('none', 'hunt_pirates') then
    raise exception 'send_fleet_to_location: activity % not available', v_loc.activity_type;
  end if;

  v_max := coalesce(cfg_num('max_active_fleets'), 3);
  select count(*) into v_active
    from fleets where player_id = v_player and status in ('moving','present','returning');
  if v_active >= v_max then
    raise exception 'send_fleet_to_location: active fleet limit reached (%/%)', v_active, v_max;
  end if;

  if p_units is null or jsonb_typeof(p_units) <> 'array' or jsonb_array_length(p_units) = 0 then
    raise exception 'send_fleet_to_location: no units selected';
  end if;

  perform base_reserve_units(p_base, p_units);
  v_fleet := fleet_create(v_player, p_base, p_units);

  v_power := fleet_get_power(v_fleet);
  if v_power < coalesce(v_loc.min_power_required, 0) then
    raise exception 'send_fleet_to_location: fleet power % below required %', v_power, v_loc.min_power_required;
  end if;

  v_speed   := resolve_fleet_movement_speed(v_fleet); -- canonical resolver (legacy branch → fleet_speed)
  v_mission := case when v_loc.activity_type = 'hunt_pirates' then 'hunt_pirates' else 'rally' end;
  v_movement := movement_create(
    v_player, v_fleet,
    'base', v_base.id, null, null, v_base.x, v_base.y,
    'location', null, null, v_loc.id, v_loc.x, v_loc.y,
    v_mission, v_speed);
  perform fleet_set_moving(v_fleet, v_movement);

  select arrive_at into v_arrive from fleet_movements where id = v_movement;
  return jsonb_build_object('fleet_id', v_fleet, 'movement_id', v_movement, 'arrive_at', v_arrive);
end;
$$;

-- ── 5) Re-lock execute surface (anti-cheat) ──────────────────────────────────────
-- resolve_fleet_movement_speed is a NEW function → default-granted to PUBLIC on create. Revoke and
-- re-grant only the canonical client RPCs (carried from migration 0050). The resolver is server/
-- internal: granted to service_role ONLY (for the regression tests + definer callers run as owner).
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
grant execute on function public.resolve_fleet_movement_speed(uuid)               to service_role;
grant execute on function public.process_mainship_expeditions()                   to service_role;
