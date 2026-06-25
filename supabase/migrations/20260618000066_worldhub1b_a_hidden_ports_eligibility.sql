-- Byeharu — WORLD-HUB-1B-A: dark world-catalog + home-port eligibility foundation.
--
-- Authorized scope ONLY: (1) three fresh HIDDEN starter-port locations; (2) their aligned canonical
-- location anchors; (3) their active docking-service rows; (4) the six-part is_home_port_eligible(location)
-- predicate; (5) the narrow privileged assign_home_port writer; (6) the player_home_port validity trigger.
--
-- Dark + disconnected: ports are status='hidden' (absent from get_world_map's status='active' filter); NO
-- player affiliation is assigned (the predicate's status='active' term makes hidden ports ineligible); NO
-- reveal; NO OSN/Dock-0/movement/presence/repair/UI change; NO feature flag. Existing locations untouched.
-- activity_type='none' here is LEGACY COMPATIBILITY ONLY (the column is NOT NULL and today's Dock-0 settles
-- only activity_type='none') — it is NOT port identity, dockability, or eligibility authority.

-- ── 1. Three fresh HIDDEN ports + aligned anchors + active docking services (fail-closed) ────────────────
do $$
declare
  v_sector_oh uuid; v_zone_wb  uuid;
  v_sector_cn uuid; v_zone_isr uuid;
  v_p1 uuid; v_p2 uuid; v_p3 uuid;
begin
  -- Fail-closed parent resolution: EXACTLY ONE active sector by immutable index, EXACTLY ONE active child
  -- zone by name under it. Zero/multiple/inactive ⇒ abort. No sector/zone is created/moved/reclassified.
  if (select count(*) from public.sectors where sector_index = 1) <> 1 then raise exception 'WH1BA: sector_index=1 not unique'; end if;
  select id into v_sector_oh from public.sectors where sector_index = 1 and status = 'active';
  if not found then raise exception 'WH1BA: Outer Haven (sector_index=1) missing or inactive'; end if;
  if (select count(*) from public.zones where sector_id = v_sector_oh and name = 'Wreck Belt') <> 1 then raise exception 'WH1BA: Wreck Belt not unique under Outer Haven'; end if;
  select id into v_zone_wb from public.zones where sector_id = v_sector_oh and name = 'Wreck Belt' and status = 'active';
  if not found then raise exception 'WH1BA: Wreck Belt missing or inactive'; end if;

  if (select count(*) from public.sectors where sector_index = 2) <> 1 then raise exception 'WH1BA: sector_index=2 not unique'; end if;
  select id into v_sector_cn from public.sectors where sector_index = 2 and status = 'active';
  if not found then raise exception 'WH1BA: Crimson Nebula (sector_index=2) missing or inactive'; end if;
  if (select count(*) from public.zones where sector_id = v_sector_cn and name = 'Ion Storm Route') <> 1 then raise exception 'WH1BA: Ion Storm Route not unique under Crimson Nebula'; end if;
  select id into v_zone_isr from public.zones where sector_id = v_sector_cn and name = 'Ion Storm Route' and status = 'active';
  if not found then raise exception 'WH1BA: Ion Storm Route missing or inactive'; end if;

  -- Fail-closed seed with STABLE LITERAL identity: each port/anchor/service row carries a fixed literal UUID
  -- PK (the schema's id columns accept explicit values), so identity no longer depends on the mutable display
  -- name. Plain INSERT — a duplicate PK OR the unique(zone_id,name) / one-active-anchor / one-per-kind
  -- constraints ABORT the migration (NO ON CONFLICT DO NOTHING — never silently create ambiguous world data).
  -- Fixed IDs (embed 0066, valid v4): location b1a000{01,02,03}-…, anchor b1a0a00{1,2,3}-…, service b1a0500{1,2,3}-….
  v_p1 := 'b1a00001-0066-4a00-8a00-000000000001';  -- Haven Reach   (STARTER_PORT_1, starter-home)
  v_p2 := 'b1a00002-0066-4a00-8a00-000000000002';  -- Slagworks Anchorage (STARTER_PORT_2)
  v_p3 := 'b1a00003-0066-4a00-8a00-000000000003';  -- Driftmarch Waypost  (STARTER_PORT_3)

  insert into public.locations (id, zone_id, name, location_type, x, y, activity_type, status, physical_role) values
    (v_p1, v_zone_wb,  'Haven Reach',         'trade_outpost', -50, -30, 'none', 'hidden', 'city'),
    (v_p2, v_zone_isr, 'Slagworks Anchorage', 'trade_outpost',  70, -10, 'none', 'hidden', 'port'),
    (v_p3, v_zone_isr, 'Driftmarch Waypost',  'trade_outpost',  10,  80, 'none', 'hidden', 'port');

  -- Aligned canonical anchors: space_x/space_y EXACTLY equal locations.x/y (no marker-anchor mismatch).
  insert into public.space_anchors (id, kind, location_id, space_x, space_y, status) values
    ('b1a0a001-0066-4a00-8a00-0000000000a1', 'location', v_p1, -50, -30, 'active'),
    ('b1a0a002-0066-4a00-8a00-0000000000a2', 'location', v_p2,  70, -10, 'active'),
    ('b1a0a003-0066-4a00-8a00-0000000000a3', 'location', v_p3,  10,  80, 'active');

  -- One active docking service per port (dockability authority lives here, not in activity_type).
  insert into public.location_services (id, location_id, service, status) values
    ('b1a05001-0066-4a00-8a00-000000000051', v_p1, 'docking', 'active'),
    ('b1a05002-0066-4a00-8a00-000000000052', v_p2, 'docking', 'active'),
    ('b1a05003-0066-4a00-8a00-000000000053', v_p3, 'docking', 'active');
end $$;

-- ── 2. Six-part eligibility predicate — the SINGLE shared definition (function + trigger both call it) ───
-- role ∈ {city,port} + location/zone/sector all active + active docking service + EXACTLY ONE active anchor.
-- 'station' excluded. Hidden ports fail (status≠active). SECURITY DEFINER so it reads server-owned tables.
create or replace function public.is_home_port_eligible(p_location_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.locations l
    join public.zones    z  on z.id  = l.zone_id
    join public.sectors  se on se.id = z.sector_id
    where l.id = p_location_id
      and l.physical_role in ('city', 'port')
      and l.status  = 'active'
      and z.status  = 'active'
      and se.status = 'active'
      and exists (select 1 from public.location_services svc
                    where svc.location_id = l.id and svc.service = 'docking' and svc.status = 'active')
      and (select count(*) from public.space_anchors a
             where a.location_id = l.id and a.kind = 'location' and a.status = 'active') = 1
  );
$$;
revoke all on function public.is_home_port_eligible(uuid) from public, anon, authenticated;
grant execute on function public.is_home_port_eligible(uuid) to service_role;

-- ── 3. Direct-write validity trigger — BACKSTOP only (not concurrency protection) ───────────────────────
create or replace function public.player_home_port_eligibility_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if not public.is_home_port_eligible(new.location_id) then
    raise exception 'player_home_port: location % is not home-port eligible', new.location_id
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
revoke execute on function public.player_home_port_eligibility_guard() from public, anon, authenticated;

create trigger player_home_port_eligibility
  before insert or update on public.player_home_port
  for each row execute function public.player_home_port_eligibility_guard();

-- ── 4. Narrow privileged assignment function — the normal race-safe writer (service_role only) ──────────
-- Locks each dependency FOR SHARE in the canonical order sector → zone → location → anchor → service
-- (FOR SHARE conflicts with the FOR NO KEY UPDATE of a status disable/retire), RE-validates the shared
-- predicate under those locks, then upserts the affiliation. NO client grant. (Inert for hidden ports.)
create or replace function public.assign_home_port(p_player uuid, p_location uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_zone uuid; v_sector uuid;
begin
  select l.zone_id, z.sector_id into v_zone, v_sector
    from public.locations l join public.zones z on z.id = l.zone_id
    where l.id = p_location;
  if not found then raise exception 'assign_home_port: location % not found', p_location; end if;

  perform 1 from public.sectors        where id = v_sector   for share;
  perform 1 from public.zones          where id = v_zone     for share;
  perform 1 from public.locations      where id = p_location for share;
  perform 1 from public.space_anchors  where location_id = p_location and kind = 'location' and status = 'active' for share;
  perform 1 from public.location_services where location_id = p_location and service = 'docking' and status = 'active' for share;

  if not public.is_home_port_eligible(p_location) then
    raise exception 'assign_home_port: location % is not home-port eligible', p_location
      using errcode = 'check_violation';
  end if;

  insert into public.player_home_port (player_id, location_id)
    values (p_player, p_location)
    on conflict (player_id) do update set location_id = excluded.location_id, affiliated_at = now();
end;
$$;
revoke all on function public.assign_home_port(uuid, uuid) from public, anon, authenticated;
grant execute on function public.assign_home_port(uuid, uuid) to service_role;
