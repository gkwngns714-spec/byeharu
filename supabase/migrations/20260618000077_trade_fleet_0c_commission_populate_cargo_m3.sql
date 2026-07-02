-- Byeharu — TRADE-FLEET-0C: populate instance cargo_capacity_m3 at commission + enforce NOT NULL.
--
-- Fifth §2.3 step: both commission insert paths now supply the volume capacity `cargo_capacity_m3`
-- (copied from the hull's `base_cargo_capacity_m3`, added in 0075), and the instance column is
-- promoted to NOT NULL. This completes §2.3 for the instance: every new ship is born with a
-- volume capacity, and no row can be null. The abstract `cargo_capacity`/`cargo_used` int columns
-- are KEPT (dropped in a later coordinated step, once their remaining readers migrate).
--
-- ── DESIGN DECISION (planner authority — refines contract §2.7) ──────────────────────────────────
-- The PORT-ENTRY-1 production verifier (scripts/port-entry-1-production-verify.{sql,sh}) is
-- INTENTIONALLY LEFT FROZEN at head 0072. It is a PRODUCTION GATE that truthfully describes the
-- DEPLOYED production surface — which is still 0072 and which we are NOT changing. It hardcodes
-- HEAD=20260618000072 / N_AFTER=0, derives its prosrc-md5 pins from the 0072 file, and asserts an
-- EXACT authenticated-RPC OID inventory. We do NOT mutate its head assertion / md5 pins / D2
-- inventory to describe the UNDEPLOYED 0C surface: doing so would desync the production gate from
-- real production and churn it on every migration. Its DB-free `selftest` reads only the unchanged
-- 0072 file, so it stays green; its `production` run stays valid against real production.
--   → The POST-0C surface (new command signatures, commission_additional_main_ship, per-ship
--     idempotency, the §2.7 eight properties) is proven by a NEW TRADE-FLEET verifier that lands
--     later in 0C. Repointing/retiring the PORT-ENTRY gate at the new head is a DEPLOY-TIME human
--     action, honoring "new capability ships dark" and avoiding partial/churny verifier rewrites.
-- Consequently THIS migration touches NO verifier file. The two writers below change body (prosrc),
-- but the PORT-ENTRY md5 pins derive from the 0072 file (unchanged), so those pins stay valid.
--
-- OWNERSHIP (SYSTEM_BOUNDARIES): main_ship_instances stays Main-Ship-owned; its writers stay
-- Main-Ship writers. No new cross-system writer, no cycle. Still DARK: nothing reads
-- cargo_capacity_m3 at runtime yet (first reader is the TRADE-MARKET-1 volume check). ACLs are
-- preserved by `create or replace` (no grant/revoke here): ensure_main_ship_for_player → service_role,
-- port_entry_commission_writer → service_role, exactly as before.

-- ── A. ensure_main_ship_for_player — verbatim 0043 body; ONLY the insert gains cargo_capacity_m3.
create or replace function public.ensure_main_ship_for_player(p_player uuid)
returns public.main_ship_instances
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ship public.main_ship_instances%rowtype;
begin
  -- Idempotent + concurrency-safe: the player_id UNIQUE constraint guards duplicates.
  insert into main_ship_instances
    (player_id, hull_type_id, hp, max_hp, cargo_capacity, cargo_capacity_m3, support_capacity, captain_slots, module_slots)
  select p_player, h.hull_type_id, h.base_hp, h.base_hp, h.base_cargo_capacity, h.base_cargo_capacity_m3,
         h.base_support_capacity, h.base_captain_slots, h.base_module_slots
    from main_ship_hull_types h
    where h.hull_type_id = 'starter_frigate'
  on conflict (player_id) do nothing;

  select * into v_ship from main_ship_instances where player_id = p_player;
  return v_ship;
end;
$$;

-- ── B. port_entry_commission_writer — verbatim 0072 body; ONLY the Phase-A insert gains cargo_capacity_m3.
create or replace function public.port_entry_commission_writer(p_player uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c_haven  constant uuid := 'b1a00001-0066-4a00-8a00-000000000001';
  v_ship   uuid;
  v_zone   uuid;
  v_sector uuid;
  v_base   uuid;
  v_fleet  uuid;
begin
  -- ── Phase A: create-or-detect the ship. The player_id UNIQUE serializes concurrent first-claims; only the
  --    INSERTING caller (RETURNING non-null) proceeds to build the dock. A conflict (ship already exists)
  --    returns created=false and writes NOTHING — the caller re-classifies the existing state. The ship is
  --    inserted DIRECTLY in canonical at_location shape (status='stationary', spatial_state='at_location',
  --    x/y NULL) so there is never a committed intermediate bare home/legacy_home row.
  insert into public.main_ship_instances
    (player_id, hull_type_id, name, status, spatial_state, space_x, space_y,
     hp, max_hp, cargo_capacity, cargo_capacity_m3, support_capacity, captain_slots, module_slots)
  select p_player, h.hull_type_id, 'Byeharu', 'stationary', 'at_location', null, null,
         h.base_hp, h.base_hp, h.base_cargo_capacity, h.base_cargo_capacity_m3, h.base_support_capacity, h.base_captain_slots, h.base_module_slots
    from public.main_ship_hull_types h
    where h.hull_type_id = 'starter_frigate'
  on conflict (player_id) do nothing
  returning main_ship_id into v_ship;

  if v_ship is null then
    return jsonb_build_object('created', false);     -- ship already existed; no write performed
  end if;

  -- ── Phase B: lock the Haven Reach target hierarchy in the canonical order (sector → zone → location →
  --    anchor → docking service, FOR SHARE — conflicts with a status disable/retire) and REVALIDATE legality
  --    through the single canonical rule AFTER the locks are held, immediately before the fleet/presence write.
  select l.zone_id, z.sector_id into v_zone, v_sector
    from public.locations l join public.zones z on z.id = l.zone_id
    where l.id = c_haven;
  if v_zone is null then
    raise exception 'port_entry_commission: Haven Reach location not found';
  end if;
  perform 1 from public.sectors           where id = v_sector for share;
  perform 1 from public.zones             where id = v_zone   for share;
  perform 1 from public.locations         where id = c_haven  for share;
  perform 1 from public.space_anchors     where location_id = c_haven and kind = 'location' and status = 'active' for share;
  perform 1 from public.location_services where location_id = c_haven and service = 'docking' and status = 'active' for share;

  if (public.mainship_space_location_target_legal(c_haven)->>'ok')::boolean is not true then
    raise exception 'port_entry_commission: Haven Reach is not dockable';   -- rolls back the ship insert (atomic)
  end if;

  -- exactly ONE present/location fleet at Haven (origin_base_id = the player's base if one exists, else NULL —
  -- NOT a home-port assignment; current_base_id stays NULL, matching a docked OSN fleet).
  select id into v_base from public.bases where player_id = p_player and status = 'active' order by created_at limit 1;
  v_fleet := gen_random_uuid();
  insert into public.fleets
    (id, player_id, origin_base_id, status, location_mode, current_base_id,
     current_location_id, current_zone_id, current_sector_id, main_ship_id)
  values (v_fleet, p_player, v_base, 'present', 'location', null,
          c_haven, v_zone, v_sector, v_ship);

  -- exactly ONE active presence through the established presence path (activity 'none', like the dock writer).
  perform public.presence_create(p_player, v_fleet, v_sector, v_zone, c_haven, 'none');

  -- final coherence gate: the ship MUST now be canonical at_location, else abort the whole transaction.
  if (public.mainship_space_validate_context(v_ship)->>'state') is distinct from 'at_location' then
    raise exception 'port_entry_commission: post-write state is not canonical at_location';
  end if;

  return jsonb_build_object('created', true, 'main_ship_id', v_ship, 'location_id', c_haven);
end;
$$;

-- ── C. Defensive backfill (idempotent no-op on fresh DB / already-populated rows), then enforce NOT NULL.
--    The >0 check added in 0076 now becomes fully enforcing: no NULLs remain and every insert supplies it.
update public.main_ship_instances i
   set cargo_capacity_m3 = h.base_cargo_capacity_m3
  from public.main_ship_hull_types h
 where h.hull_type_id = i.hull_type_id
   and i.cargo_capacity_m3 is null;

alter table public.main_ship_instances
  alter column cargo_capacity_m3 set not null;
