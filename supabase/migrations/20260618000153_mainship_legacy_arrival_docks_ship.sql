-- Byeharu — MAINSHIP LEGACY SPATIAL-STATE FIX, slice 2 of 2: ARRIVAL docks the ship.
-- (docs/MAINSHIP_LEGACY_SPATIAL_STATE_FIX.md §5/§6 — 0152 shipped the DEPARTURE/HALT half; this migration
--  ships the ARRIVAL half. The docked→send→travel→arrive→docked round-trip verifier is the NEXT step.)
--
-- GAP BEING CLOSED: movement_settle_arrival's location branch (0151) settles the FLEET (fleet_set_present +
-- presence_create) but never the SHIP — a legacy-arrived main ship sat status='traveling', spatial_state=NULL
-- forever while "present" (the legacy_present quirk; decision doc §2 writer #6). Post-0152, departures from a
-- canonical dock drop the ship to the legacy NULL representation, so without this slice a docked→send→arrive
-- trip would END in legacy_present instead of returning to the canonical docked pair.
--
-- DESIGN (decision doc §5 arrival rule):
--   • DOCKABLE target (the SINGLE canonical legality rule mainship_space_location_target_legal, 0067) →
--     settle the ship to the canonical docked pair (status='stationary', spatial_state='at_location',
--     space_x/y=NULL) via ONE shared docked-ship write helper — extracted from the OSN Dock-0 writer's dock
--     branch so BOTH routes (OSN dock + legacy settle) share the ONE write; no duplicated copy anywhere.
--   • NON-dockable target (REACHABLE, not defensive — decision doc §3: the seed safe-zones Safe Rally Point /
--     Quiet Drift are active, activity_type='none', legal legacy targets with no role/docking service/anchor)
--     → write NOTHING: the ship stays in the legacy spatial_state=NULL representation from its 0152 departure
--     write — constraint-legal, coherent legacy_present.
--
-- SOURCE-BODY NOTE (the 0152 precedent of recreating LATEST bodies): the goal names the OSN dock writer by its
-- birth migration (0061), but mainship_space_dock_at_location was RE-CREATED in 0067:499 (anchor-backed Dock-0:
-- FOR SHARE target-hierarchy revalidation + anchor-snapshot match + the captured v_settled_at settlement
-- clock). 0067 is the shipped body at head (nothing later re-emits it — verified by grep), so THAT body is
-- recreated verbatim here. Its dock-branch ship write (0067:618-621) is the extraction source.
--
-- ACCEPTED MICRO-DELTA (documented, bookkeeping-only): 0067's dock branch stamped the SHIP row's updated_at
-- with v_settled_at; the shared helper stamps now() (the same stamp every other main_ship_instances writer —
-- including 0152's in-flight helper — uses). main_ship_instances.updated_at is row-touch bookkeeping: no
-- constraint, reader, or settlement record depends on it (the settlement record is the movement row's
-- resolved_at + the fleets stamps, which KEEP v_settled_at exactly). The in-function comments are amended
-- where this made them inaccurate.
--
-- The 0055 lifecycle CHECKs stay untouched (writers-only fix). No flag is created, read differently, or
-- flipped. No client/RPC signature changes (frontend untouched). Forward-only; no shipped migration edited.
-- process_mainship_space_arrivals and process_fleet_movements are NOT touched: both delegate to the two
-- functions recreated here (0067's processor → dock primitive; 0151's cron loop → movement_settle_arrival),
-- so the cron and on-demand callers inherit the fix automatically.
--
-- BOUNDARIES: main_ship_instances keeps ONE writer route — the docked-ship write now lives in exactly one
-- Main-Ship-owned leaf, called DOWNWARD by both the OSN dock writer and Movement's settle. Movement gains one
-- new READ-ONLY downward edge (movement_settle_arrival → mainship_space_location_target_legal, the STABLE
-- dockability predicate leaf). Both new edges point at leaves that call nothing → the call graph stays acyclic.

-- ── 1) THE one canonical docked-ship write (Main-Ship-owned leaf; service_role/internal only) ──────────────
-- This helper is the ONE place expressing "main ship → canonically docked at a location" (the at_location /
-- stationary pair; at_location REQUIRES NULL coordinates — main_ship_instances_space_coords, 0055). It is
-- shared by BOTH docking routes:
--   • the OSN Dock-0 writer mainship_space_dock_at_location (recreated below), and
--   • the legacy arrival settle movement_settle_arrival (recreated below);
-- no second copy of this write exists anywhere. It is the arrival-side mirror of 0152's
-- mainship_mark_legacy_in_flight (the ONE legacy in-flight write).
--   • Callers own the decision that docking is legal (Dock-0's arrival-time revalidation; the legacy settle's
--     mainship_space_location_target_legal gate) — the helper only expresses the resulting ship state.
--   • Missing-ship semantics match the inline write it replaces: an unknown p_main_ship_id updates zero rows.
-- RETIREMENT CONDITION: retires when the legacy fleet_movements main-ship family is replaced by the OSN
-- coordinate domain — at that point Dock-0 is its only caller and the write can fold back inline (remove it
-- in the same change that retires the legacy family; 0152's helper carries the same condition).
create or replace function public.mainship_mark_docked_at_location(p_main_ship_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.main_ship_instances
    set status = 'stationary', spatial_state = 'at_location', space_x = null, space_y = null, updated_at = now()
    where main_ship_id = p_main_ship_id;
end;
$$;

-- ── 2) mainship_space_dock_at_location — 0067:499 body VERBATIM; only the dock-branch ship write changes ────
-- (Header contract unchanged from 0067: the ONE dock resolver; only private callers are
-- process_mainship_space_arrivals for due location routes and mainship_space_stop at/after a location route's
-- arrive_at; NO client call path. Full arrival-time revalidation under deterministic FOR SHARE locks; any
-- failed condition is a deterministic terminal failure — ship parked in_space at the stored snapshot, no
-- presence, never redirects. The coordinate authority is the canonical anchor; locations.x/y consulted NOWHERE.)
create or replace function public.mainship_space_dock_at_location(p_main_ship_id uuid, p_movement_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mv         main_ship_space_movements%rowtype;
  v_fleet      fleets%rowtype;
  v_loc        record;
  v_legal      jsonb;
  v_ax         double precision;
  v_ay         double precision;
  v_reason     text;
  v_settled_at timestamptz;   -- the ONE real settlement wall-clock (never now()/transaction-start)
begin
  select * into v_mv from main_ship_space_movements
    where id = p_movement_id and main_ship_id = p_main_ship_id and status = 'moving';
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'movement_not_moving');
  end if;
  if v_mv.target_kind <> 'location' or v_mv.target_location_id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_location_target');
  end if;

  select * into v_fleet from fleets where id = v_mv.fleet_id;

  -- Resolve the target location's identity + zone/sector (for the FOR SHARE locks and, on success, presence).
  -- locations.x/y is intentionally NOT selected: the canonical anchor is the sole coordinate authority.
  select l.id as id, l.zone_id as zone_id, z.sector_id as sector_id
    into v_loc
    from locations l join zones z on z.id = l.zone_id
    where l.id = v_mv.target_location_id;

  -- ── Dock predicate → DOCK (v_reason NULL) vs deterministic TERMINAL FAILURE (v_reason set) ───────────────
  if v_loc.id is null then
    v_reason := 'undockable_invalid_target';                   -- FK-prevented; defensive only
  else
    -- Re-acquire the TARGET hierarchy under deterministic FOR SHARE locks (same order as the writer /
    -- assign_home_port: sector → zone → location → anchor → docking service). FOR SHARE conflicts with the
    -- FOR NO KEY UPDATE of a status disable/retire, so a concurrent de-activation/retirement serializes here.
    perform 1 from public.sectors           where id = v_loc.sector_id for share;
    perform 1 from public.zones             where id = v_loc.zone_id   for share;
    perform 1 from public.locations         where id = v_loc.id        for share;
    perform 1 from public.space_anchors     where location_id = v_loc.id and kind = 'location' and status = 'active' for share;
    perform 1 from public.location_services where location_id = v_loc.id and service = 'docking' and status = 'active' for share;

    -- FULL arrival-time revalidation through the SINGLE canonical legality rule (active sector/zone/location +
    -- role city|port + activity 'none' + one active docking service + one active in-bounds anchor). A route
    -- legal at departure that became non-dockable in transit terminally fails here — never docks on a partial.
    v_legal := public.mainship_space_location_target_legal(v_loc.id);
    if (v_legal->>'ok')::boolean is not true then
      v_reason := case v_legal->>'reason'
        when 'target_not_found'            then 'undockable_invalid_target'
        when 'target_inactive_location'    then 'undockable_inactive_location'
        when 'target_inactive_zone'        then 'undockable_inactive_zone'
        when 'target_inactive_sector'      then 'undockable_inactive_sector'
        when 'target_unsupported_role'     then 'undockable_unsupported_role'
        when 'target_unsupported_activity' then 'undockable_unsupported_activity'
        when 'target_no_docking_service'   then 'undockable_no_docking_service'
        when 'target_anchor_not_unique'    then 'undockable_no_active_anchor'   -- >1 active is schema-impossible → count 0
        when 'target_anchor_out_of_bounds' then 'undockable_anchor_out_of_bounds'
        else 'undockable_target_illegal'
      end;
    else
      -- The canonical anchor must STILL exactly match the movement's stored target snapshot (never redirect to
      -- a moved anchor). The legality rule already proved exactly one active anchor and returned its coords.
      v_ax := (v_legal->>'anchor_x')::double precision;
      v_ay := (v_legal->>'anchor_y')::double precision;
      if v_ax is distinct from v_mv.target_x or v_ay is distinct from v_mv.target_y then
        v_reason := 'target_anchor_changed';
      else
        v_reason := null;                                       -- fully dockable: legal AND anchor matches snapshot
      end if;
    end if;
  end if;

  -- Capture the ONE real settlement timestamp AFTER the target-hierarchy locks + final dockability decision are
  -- complete and IMMEDIATELY before the first settlement write. clock_timestamp() (current wall-clock), NOT
  -- now()/transaction_timestamp(): a Stop txn can BEGIN before arrive_at, block on the S2 ship lock, cross
  -- arrive_at, and correctly take the due path — its now() would be < arrive_at, so persisting now() could
  -- record a settlement BEFORE the route's own arrival time. clock_timestamp() here is monotonically ≥ the
  -- caller's at/after-arrival boundary check, so resolved_at is never earlier than arrive_at. The SAME value
  -- drives every resolved_at / updated_at in both branches, EXCEPT the dock-success ship write: since 0153
  -- that is the shared docked-ship helper, which stamps the ship's bookkeeping updated_at with now() like
  -- every other main_ship_instances writer (the settlement record — the movement row's resolved_at and the
  -- fleets stamps — keeps v_settled_at exactly).
  v_settled_at := clock_timestamp();

  if v_reason is not null then
    update main_ship_space_movements
      set status = 'failed', resolved_at = v_settled_at, terminal_reason = v_reason
      where id = v_mv.id and status = 'moving';

    update fleets
      set status = 'completed', location_mode = 'movement',
          active_space_movement_id = null, active_movement_id = null,
          current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
          updated_at = v_settled_at
      where id = v_fleet.id;

    update main_ship_instances
      set status = 'stationary', spatial_state = 'in_space',
          space_x = v_mv.target_x, space_y = v_mv.target_y, updated_at = v_settled_at
      where main_ship_id = p_main_ship_id;

    return jsonb_build_object('ok', true, 'docked', false, 'reason', v_reason, 'resolved_at', v_settled_at);
  end if;

  -- ── DOCK: settle the movement, dock the fleet at the location, create exactly one active presence ────────
  update main_ship_space_movements
    set status = 'arrived', resolved_at = v_settled_at, terminal_reason = 'auto_arrival'
    where id = v_mv.id and status = 'moving';

  update fleets
    set status = 'present', location_mode = 'location',
        active_space_movement_id = null, active_movement_id = null,
        current_base_id = null,
        current_location_id = v_loc.id, current_zone_id = v_loc.zone_id, current_sector_id = v_loc.sector_id,
        updated_at = v_settled_at
    where id = v_fleet.id;

  -- Ship → docked, via the ONE shared docked-ship write (0153 helper; extraction of the inline write that
  -- lived here since 0061/0067). at_location REQUIRES NULL coordinates (main_ship_instances_space_coords);
  -- the destination coordinate remains immutably recorded on the now-arrived movement row.
  perform public.mainship_mark_docked_at_location(p_main_ship_id);

  perform public.presence_create(v_mv.player_id, v_mv.fleet_id, v_loc.sector_id, v_loc.zone_id, v_loc.id, 'none');

  return jsonb_build_object('ok', true, 'docked', true, 'location_id', v_loc.id, 'resolved_at', v_settled_at);
end;
$$;

-- ── 3) movement_settle_arrival — 0151:45 body VERBATIM; the location branch gains the main-ship dock settle ─
-- (Contract unchanged from 0151: THE extracted per-movement settle; cron loop body + on-demand RPC both call
-- it; guarded locked re-read status='moving' AND due — cron-vs-RPC races settle exactly once.)
create or replace function public.movement_settle_arrival(p_movement uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  m           fleet_movements%rowtype;
  v_loc       record;
  v_units     jsonb;
  v_main_ship uuid;
begin
  -- Guarded locked re-read: still moving AND due. For the cron this is a no-op re-take of a lock it
  -- already holds on a row it already proved due (now() is constant within the txn) — byte-equivalent.
  -- For the on-demand RPC it is the authoritative claim.
  select * into m from fleet_movements
    where id = p_movement and status = 'moving' and arrive_at <= now()
    for update;
  if not found then
    return jsonb_build_object('settled', false, 'reason', 'not_settleable');
  end if;

  if m.target_type = 'location' then
    select l.activity_type as activity, l.zone_id as zone_id, z.sector_id as sector_id
      into v_loc from locations l join zones z on z.id = l.zone_id where l.id = m.target_location_id;
    update fleet_movements set status = 'arrived', resolved_at = now() where id = m.id;
    perform fleet_set_present(m.fleet_id, v_loc.sector_id, v_loc.zone_id, m.target_location_id);
    perform presence_create(m.player_id, m.fleet_id, v_loc.sector_id, v_loc.zone_id, m.target_location_id, v_loc.activity);

    -- Main-ship fleets: settle the SHIP too (0153; decision doc §5 arrival rule). Dock-vs-legacy split:
    --   • DOCKABLE target — the SINGLE canonical legality rule (mainship_space_location_target_legal: active
    --     sector/zone/location + role city|port + activity 'none' + one active docking service + one active
    --     in-bounds anchor) — → the canonical docked pair via the ONE shared docked-ship helper.
    --     fleet_set_present already set the fleet present/location-mode with active_movement_id=NULL and
    --     presence_create added the matching active presence (legacy fleets never carry an
    --     active_space_movement_id), so the ship reads as a coherent at_location per
    --     mainship_space_validate_context.
    --   • otherwise — a main-ship fleet arriving at an active 'none' but NON-dockable target (REACHABLE:
    --     the seed safe-zones Safe Rally Point / Quiet Drift have no role/docking service/anchor) — write
    --     NOTHING to main_ship_instances: the ship is already in the legacy spatial_state=NULL
    --     representation from its departure write (0152's mainship_mark_legacy_in_flight), which is
    --     constraint-legal, coherent legacy_present.
    -- The v_main_ship IS NOT NULL gate keeps ordinary unit fleets (main_ship_id NULL) untouched.
    select main_ship_id into v_main_ship from fleets where id = m.fleet_id;
    if v_main_ship is not null
       and (public.mainship_space_location_target_legal(m.target_location_id)->>'ok')::boolean is true then
      perform public.mainship_mark_docked_at_location(v_main_ship);
    end if;

    return jsonb_build_object('settled', true, 'outcome', 'present', 'movement_id', m.id);

  elsif m.target_type = 'base' then
    select jsonb_agg(jsonb_build_object('unit_type_id', unit_type_id, 'quantity', quantity))
      into v_units from fleet_units where fleet_id = m.fleet_id and quantity > 0;
    update fleet_movements set status = 'arrived', resolved_at = now() where id = m.id;
    if v_units is not null then
      perform base_merge_units(m.target_base_id, v_units);
    end if;
    perform fleet_complete(m.fleet_id);
    -- Deposit carried rewards now that the fleet is safely home (idempotent via
    -- reward_grants unique source), under the movement's activity source type.
    if m.reward_payload_json is not null and m.reward_payload_json <> '{}'::jsonb and m.reward_grant_source is not null then
      perform reward_grant(m.reward_source_type, m.reward_grant_source, m.player_id, m.target_base_id, m.reward_payload_json);
    end if;
    return jsonb_build_object('settled', true, 'outcome', 'completed', 'movement_id', m.id);

  else
    update fleet_movements set status = 'failed', resolved_at = now() where id = m.id;
    return jsonb_build_object('settled', true, 'outcome', 'failed', 'movement_id', m.id);
  end if;
end;
$$;

-- ── 4) Execute surface ─────────────────────────────────────────────────────────────────────────────────────
-- CREATE OR REPLACE on the two EXISTING functions PRESERVES their owner and grants (both are internal:
-- mainship_space_dock_at_location and movement_settle_arrival were revoked from all client roles at creation —
-- 0061/0067 and 0151), so no re-lock is needed for them and deliberately NO blanket
-- `revoke execute on all functions ...` re-lock is emitted (that idiom belongs to migrations adding NEW client
-- RPCs). Only the NEWLY-CREATED helper default-grants EXECUTE to PUBLIC on create and must be locked down
-- (the 0152 helper idiom): SECURITY DEFINER orchestrators invoke it as owner; no client path. Note:
-- movement_settle_arrival now calls the EXISTING service_role predicate mainship_space_location_target_legal —
-- invoked as function owner inside SECURITY DEFINER, so NO client grant surface changes anywhere.
revoke execute on function public.mainship_mark_docked_at_location(uuid) from public, anon, authenticated;
grant  execute on function public.mainship_mark_docked_at_location(uuid) to service_role;
