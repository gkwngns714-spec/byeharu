-- Byeharu — PORT-LAUNCH-1A: dark port-launch backend/readiness boundaries. Additive, dark, no data change.
--
-- Adds exactly two new server functions and re-locks the execute surface. Seeds NOTHING, reveals NOTHING,
-- assigns NO home port, changes NO flag, alters NO migration/resolver/Dock-0/Stop/movement/arrival behavior.
-- Production stays dark on deploy: reveal_starter_ports() is service_role-only and NOT invoked here, and
-- get_osn_movement_readiness() reports osn_available=false while mainship_space_movement_enabled=false.
--
--   • A. reveal_starter_ports()           — Map/World-owned, service_role-only ONE-WAY reveal primitive. Flips
--        the three fixed 0066 hidden starter ports hidden→active ATOMICALLY, fail-closed against the fixed
--        port/anchor/service identities + hierarchy/role/activity/coordinate invariants. Idempotent when all
--        three are already active. NO unreveal (public reveal is a one-way transition once players interact;
--        rollback is the OSN flag or a forward fix, never hiding a port under a docked/en-route ship).
--   • B. get_osn_movement_readiness()      — authenticated read-only UX projection. Derives the caller from
--        auth.uid() ONLY; reuses the authoritative resolver + target-legality rules (never duplicated client
--        side); returns ONLY a safe category + availability + generic reason + already-visible eligible port
--        ids. Never returns a hidden-port id, anchor id, coordinate, or internal row. The command RPC remains
--        the sole authority and stays independently flag-gated; this RPC NEVER makes movement "available"
--        while the flag is false (osn_available is false whenever the flag is false).
--   • G. Re-lock the execute surface → canonical authenticated client surface becomes EXACTLY 17
--        (16 + get_osn_movement_readiness). reveal_starter_ports joins the service_role-only server set.

-- ── A. One-way starter-port reveal primitive (Map/World owner; service_role only) ──────────────────────────
create or replace function public.reveal_starter_ports()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c_p1 constant uuid := 'b1a00001-0066-4a00-8a00-000000000001';  -- Haven Reach (city)
  c_p2 constant uuid := 'b1a00002-0066-4a00-8a00-000000000002';  -- Slagworks Anchorage (port)
  c_p3 constant uuid := 'b1a00003-0066-4a00-8a00-000000000003';  -- Driftmarch Waypost (port)
  c_a1 constant uuid := 'b1a0a001-0066-4a00-8a00-0000000000a1';
  c_a2 constant uuid := 'b1a0a002-0066-4a00-8a00-0000000000a2';
  c_a3 constant uuid := 'b1a0a003-0066-4a00-8a00-0000000000a3';
  c_s1 constant uuid := 'b1a05001-0066-4a00-8a00-000000000051';
  c_s2 constant uuid := 'b1a05002-0066-4a00-8a00-000000000052';
  c_s3 constant uuid := 'b1a05003-0066-4a00-8a00-000000000053';
  v_ports    uuid[] := array[c_p1, c_p2, c_p3];
  v_anchors  uuid[] := array[c_a1, c_a2, c_a3];
  v_services uuid[] := array[c_s1, c_s2, c_s3];
  v_ax double precision[] := array[-50, 70, 10];   -- approved 0066 anchor coordinates, per port
  v_ay double precision[] := array[-30, -10, 80];
  r record;
  i int;
  v_hidden int;
  v_active int;
begin
  -- Serialize against any concurrent status disable/enable on the three rows (fixed id order).
  perform 1 from public.locations where id = any(v_ports) order by id for update;

  if (select count(*) from public.locations where id = any(v_ports)) <> 3 then
    raise exception 'reveal_starter_ports: expected exactly the 3 fixed starter-port locations';
  end if;

  -- Per-port structural invariants (assert EVERYTHING except status, which is what we may flip).
  for i in 1..3 loop
    select l.status as lstatus, l.physical_role as role, l.activity_type as activity,
           z.status as zstatus, se.status as sstatus
      into r
      from public.locations l
      join public.zones   z  on z.id  = l.zone_id
      join public.sectors se on se.id = z.sector_id
      where l.id = v_ports[i];
    if not found then raise exception 'reveal_starter_ports: port % not found', v_ports[i]; end if;
    if r.lstatus not in ('hidden', 'active') then
      raise exception 'reveal_starter_ports: port % unexpected status % (abort, no write)', v_ports[i], r.lstatus; end if;
    if r.zstatus <> 'active' or r.sstatus <> 'active' then
      raise exception 'reveal_starter_ports: port % parent hierarchy not active', v_ports[i]; end if;
    if r.role not in ('city', 'port') then
      raise exception 'reveal_starter_ports: port % physical_role % invalid', v_ports[i], r.role; end if;
    if r.activity <> 'none' then
      raise exception 'reveal_starter_ports: port % activity_type % invalid', v_ports[i], r.activity; end if;
    -- exactly one active canonical anchor: the approved fixed id, kind location, owned by THIS port, at the
    -- approved in-bounds coordinate; and no other active anchor for the port.
    if (select count(*) from public.space_anchors a
          where a.id = v_anchors[i] and a.location_id = v_ports[i] and a.kind = 'location' and a.status = 'active'
            and a.space_x = v_ax[i] and a.space_y = v_ay[i]
            and a.space_x between -10000 and 10000 and a.space_y between -10000 and 10000) <> 1 then
      raise exception 'reveal_starter_ports: port % missing approved active anchor % at (%, %)', v_ports[i], v_anchors[i], v_ax[i], v_ay[i]; end if;
    if (select count(*) from public.space_anchors a
          where a.location_id = v_ports[i] and a.kind = 'location' and a.status = 'active') <> 1 then
      raise exception 'reveal_starter_ports: port % must have exactly one active location anchor', v_ports[i]; end if;
    -- exactly one active docking service: the approved fixed id, owned by THIS port; and no other.
    if (select count(*) from public.location_services s
          where s.id = v_services[i] and s.location_id = v_ports[i] and s.service = 'docking' and s.status = 'active') <> 1 then
      raise exception 'reveal_starter_ports: port % missing approved active docking service %', v_ports[i], v_services[i]; end if;
    if (select count(*) from public.location_services s
          where s.location_id = v_ports[i] and s.service = 'docking' and s.status = 'active') <> 1 then
      raise exception 'reveal_starter_ports: port % must have exactly one active docking service', v_ports[i]; end if;
  end loop;

  -- All-or-nothing status decision (coherent hidden set → reveal; coherent active set → idempotent no-op).
  select count(*) filter (where status = 'hidden'), count(*) filter (where status = 'active')
    into v_hidden, v_active
    from public.locations where id = any(v_ports);

  if v_active = 3 then
    return jsonb_build_object('ok', true, 'revealed', 0, 'already_active', true);
  elsif v_hidden = 3 then
    update public.locations set status = 'active' where id = any(v_ports);
    return jsonb_build_object('ok', true, 'revealed', 3, 'already_active', false);
  else
    raise exception 'reveal_starter_ports: mixed port states (hidden=%, active=%) — abort with no write', v_hidden, v_active;
  end if;
end;
$$;
revoke all on function public.reveal_starter_ports() from public, anon, authenticated;
grant execute on function public.reveal_starter_ports() to service_role;

-- ── B. Authenticated read-only OSN readiness projection (UX read-model; NOT an authority boundary) ─────────
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
  v_reason text;
  v_dests  uuid[] := '{}';
begin
  if v_player is null then
    return jsonb_build_object('origin_category', 'no_ship', 'osn_available', false,
                              'reason', 'no_ship', 'eligible_destination_ids', '[]'::jsonb);
  end if;

  select main_ship_id into v_ship from public.main_ship_instances where player_id = v_player;
  if v_ship is null then
    return jsonb_build_object('origin_category', 'no_ship', 'osn_available', false,
                              'reason', 'no_ship', 'eligible_destination_ids', '[]'::jsonb);
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
    'eligible_destination_ids', to_jsonb(v_dests));
end;
$$;

-- ── G. Re-lock execute surface (anti-cheat). New functions default-grant EXECUTE to PUBLIC on create →
--    revoke ALL and re-grant ONLY the canonical client RPC list (carried verbatim from 0067) PLUS the ONE new
--    PORT-LAUNCH-1A authenticated read RPC get_osn_movement_readiness → EXACTLY 17 authenticated client RPCs.
--    reveal_starter_ports joins the service_role-only server set; clients NEVER gain it or any OSN internal.
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
grant execute on function public.get_osn_movement_readiness()                     to authenticated;  -- NEW (PORT-LAUNCH-1A)
grant execute on function public.send_main_ship_expedition(jsonb, uuid)           to authenticated;
grant execute on function public.request_main_ship_return(uuid)                   to authenticated;
grant execute on function public.repair_main_ship()                               to authenticated;
grant execute on function public.move_main_ship_to_location(uuid, uuid)           to authenticated;
grant execute on function public.command_main_ship_space_move(double precision, double precision, uuid) to authenticated;
grant execute on function public.command_main_ship_space_stop(uuid)               to authenticated;
grant execute on function public.command_main_ship_space_move_to_location(uuid, uuid) to authenticated;
-- Server / CI only (service_role); NEVER clients:
grant execute on function public.reveal_starter_ports()                           to service_role;  -- NEW (PORT-LAUNCH-1A)
grant execute on function public.dev_set_main_ship_destroyed(uuid)                to service_role;
grant execute on function public.resolve_fleet_movement_speed(uuid)               to service_role;
grant execute on function public.process_mainship_expeditions()                   to service_role;
grant execute on function public.mainship_space_lock_context(uuid, boolean)       to service_role;
grant execute on function public.mainship_space_validate_context(uuid)            to service_role;
grant execute on function public.mainship_space_resolve_origin(uuid)              to service_role;
grant execute on function public.mainship_space_assert_cross_domain_exclusion(uuid) to service_role;
grant execute on function public.mainship_space_begin_move(uuid, uuid, double precision, double precision, uuid) to service_role;
grant execute on function public.mainship_space_begin_move_core(uuid, uuid, text, double precision, double precision, uuid, uuid) to service_role;
grant execute on function public.mainship_space_location_target_legal(uuid)       to service_role;
grant execute on function public.process_mainship_space_arrivals()               to service_role;
grant execute on function public.mainship_space_dock_at_location(uuid, uuid)      to service_role;
grant execute on function public.mainship_space_settle_space_arrival(uuid, uuid, timestamptz) to service_role;
grant execute on function public.mainship_space_stop(uuid, uuid, uuid)            to service_role;
