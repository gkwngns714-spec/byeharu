-- Byeharu — WORLD GEOMETRY REBALANCE: uniform 3x spread of the populated map + territory rings,
-- and a coherent 0.25x pull-in of the mining fields — ONE world-layout data-fix, the 0220
-- (territory_radius_retune) precedent: guarded UPDATEs + a self-assert do-block, no schema/RPC/flag
-- change, no client change.
--
-- THE BUG (owner-observed): the whole populated map (0002 waypoints + 0066 starter ports, all
-- status IN ('active','hidden')) sits within dist 33.5–85.1 of origin, while the mining_fields
-- (0103, hidden/server-only) sit 1500–4200 out — two unrelated scales on one game board. The owner
-- also wants every location/zone pulled FURTHER apart (~3x) and the lowest-tier mining site (Sparse
-- Ore Belt) brought CLOSER, not farther.
--
-- THE FIX — three uniform scalings, world-wide (every status; hidden rows go active later and must
-- already be coherent — the 0220 rule):
--   1) locations.x / locations.y            × 3   (spread every named site 3x from origin)
--   2) locations.territory_radius           × 3   (every non-null ring — 10/12/8 → 30/36/24)
--   3) mining_fields.space_x / .space_y     × 0.25 (pulls the whole mining band in; the starter site
--                                                    Sparse Ore Belt 1500,900 → 375,225, dist ≈437 —
--                                                    just beyond the new ~255-radius active ring, a
--                                                    short first trip instead of a 1500-unit hike)
-- PROPORTIONAL-SCALING PROOF (no re-derivation needed, but re-checked live below anyway): positions
-- and territory radii both scale by the SAME constant k=3, so for every pair (a,b),
-- osn_distance(a,b) and (r_a + r_b) both scale by k — the sign of (distance − radius_sum), i.e.
-- overlap-or-not, is UNCHANGED by a uniform scale. 0220's proof (min inter-location distance 29.15 >
-- every radius-sum ≤ 24) therefore continues to hold at 3x (87.45 > every radius-sum ≤ 72). Assert
-- (D) below re-runs the disjointness sweep on the DEPLOYED post-scale world rather than trusting the
-- algebra alone (the 0220 idiom: pin the deployed state, not just the argument).
--
-- ZONES/SECTORS DELIBERATELY UNTOUCHED: zones.x/y/radius and sectors.x/y are a dormant container
-- concept — 0217 established zones.radius is "not drawn anywhere", and 0175 independently verified
-- "zones are not rendered client-side (no shape needs anchoring)". The owner's "make zones larger"
-- ask is the territory-ring concept (locations.territory_radius, item 2 above), already covered;
-- rescaling the unused container geometry too would be scope creep with no player-visible effect.
--
-- ══════════════════════════════════════════════════════════════════════════════════════════════════
-- LIVE-STATE SAFETY — the two hazards a pure "UPDATE locations" migration would silently break:
-- ══════════════════════════════════════════════════════════════════════════════════════════════════
--
-- HAZARD A — space_anchors is a SECOND coordinate copy, and it is IMMUTABLE while active.
-- OSN-HUB-1A (0067) made public.space_anchors (0063), NOT locations.x/y, the sole coordinate
-- authority for the coordinate-domain (main-ship) location-docking path: mainship_space_dock_at_
-- location (0067:499-583) resolves the target's dockable coordinate from space_anchors via
-- mainship_space_location_target_legal — "locations.x/y is intentionally NOT selected: the
-- canonical anchor is the sole coordinate authority" (0067:527). 0066 seeded exactly THREE active
-- location-kind anchors (Haven/Slagworks/Driftmarch, the only anchored — hence only ever dockable —
-- locations), with the explicit invariant "space_x/space_y EXACTLY equal locations.x/y" (0066), and
-- 0154 wrote down the STANDING INVARIANT for exactly this future situation: "move locations.x/y and
-- retire+insert the port's anchor in ONE migration (0063 lifecycle), same values both places". A
-- plain UPDATE space_anchors SET space_x=... would additionally be REJECTED outright:
-- space_anchors_immutability_guard (0063) raises on any coordinate edit to an active row ("retire +
-- insert to relocate" is not optional, it is enforced by a BEFORE UPDATE trigger). So §4 below
-- retires each active location anchor and inserts its replacement at the SAME 3x coordinate the
-- location just received — the 0154 standing invariant, invoked for real for the first time.
--
-- HAZARD B — an in-flight coordinate-domain leg snapshots its target and re-derives at arrival.
-- main_ship_space_movements.target_x/target_y is a SNAPSHOT taken at departure (mainship_space_
-- begin_move_core, 0067). At arrival, mainship_space_dock_at_location re-resolves the target's
-- CURRENT anchor coordinate and requires it to EXACTLY equal the movement's frozen snapshot
-- (0067:564-573): "if v_ax is distinct from v_mv.target_x or v_ay is distinct from v_mv.target_y
-- then v_reason := 'target_anchor_changed'" — a DETERMINISTIC TERMINAL FAILURE (ship stranded
-- in_space at the STALE pre-migration coordinate, never docked, no presence). So: arrival does NOT
-- re-derive from the location id — it re-derives from the anchor and then demands the snapshot still
-- matches, which is exactly the case that breaks the instant §1/§4 move the location/anchor without
-- also updating any movement already in flight to it. §5 below reconciles every such leg.
-- (The LEGACY fleet_movements engine, by contrast, is unaffected: process_fleet_movements, 0009,
-- resolves a location arrival purely by target_location_id — fleet_set_present/presence_create never
-- read m.target_x/target_y — so a legacy hunt/return leg in flight when this migration lands settles
-- exactly as before. Open-space (target_kind='space' / target_type≠'location') legs carry a raw
-- coordinate with no location backing at all and are correctly left untouched by both §4 and §5.)
--
-- OUT OF SCOPE / VERIFIED INERT: bases.x/y stays untouched (every base sits at the player-home origin
-- (0,0); no space_anchors kind='base' row exists in any migration — grep-verified — so there is no
-- base-side analogue of Hazard A/B to fix). main_ship_instances.space_x/space_y and fleets in open
-- space are independent of locations by design (a ship parked in raw space stays at its raw
-- coordinate; only named-site geometry moves here) — untouched, per the standing OSN convention that
-- at_location requires NULL ship coordinates and in_space coordinates are the ship's own state, never
-- derived from a location. location_presence keys on location_id, not coordinates — docked/berthed
-- fleets do not move off their dock by construction. The dark pirate-intercept prototype (branch-only,
-- not deployed) auto-seeds from territory_radius but has no live table here to reconcile.

-- ── 1) Locations spread 3x — every row, every status (hidden sites must already be coherent) ──────
update public.locations
set x = x * 3,
    y = y * 3;

-- ── 2) Territory rings 3x — every non-null radius (10/12/8 → 30/36/24) ──────────────────────────────
update public.locations
set territory_radius = territory_radius * 3
where territory_radius is not null;

-- ── 3) Mining fields pulled in 0.25x — the starter tier becomes a short first trip ──────────────────
update public.mining_fields
set space_x = space_x * 0.25,
    space_y = space_y * 0.25;

-- ── 4) HAZARD A fix — relocate every active location-kind space_anchor by the SAME 3x factor, via the
--    mandatory retire+insert lifecycle (space_anchors_immutability_guard forbids a direct coordinate
--    UPDATE on an active row). Keeps the 0066 invariant (anchor coords == location coords) intact.
do $$
declare
  r record;
begin
  for r in
    select a.id, a.location_id, a.space_x, a.space_y
      from public.space_anchors a
     where a.kind = 'location' and a.status = 'active'
     order by a.id
  loop
    update public.space_anchors set status = 'retired' where id = r.id;

    insert into public.space_anchors (kind, location_id, space_x, space_y, status)
    values ('location', r.location_id, r.space_x * 3, r.space_y * 3, 'active');
  end loop;
end $$;

-- ── 5) HAZARD B fix — reconcile every IN-FLIGHT coordinate-domain leg whose target is a named
--    location, so its frozen target_x/target_y snapshot still matches the (now 3x) anchor at
--    arrival. Scope is exactly target_kind='location' AND status='moving' — a raw open-space leg has
--    no location backing and is untouched; an already-arrived/cancelled/failed row is history, not
--    live state, and is untouched.
update public.main_ship_space_movements
set target_x = target_x * 3,
    target_y = target_y * 3
where target_kind = 'location'
  and status = 'moving';

-- ── Self-assert (deploy-time; a raise aborts the migration txn — nothing half-applies) ───────────────
do $$
declare
  v_n           int;
  v_locations   int;
  v_territory   int;
  v_fields      int;
  v_anchors     int;
  v_moving_locs int;
begin
  -- (A) vacuity: the probed classes exist (a world with none would green every sweep below while
  --     proving nothing — the 0220 rule, re-applied).
  select count(*) into v_n from public.locations where location_type = 'trade_outpost';
  if v_n = 0 then raise exception '0227 self-assert FAIL: no trade_outpost rows — the rebalance sweep would be vacuous'; end if;
  select count(*) into v_n from public.locations where location_type in ('pirate_hunt', 'pirate_den');
  if v_n = 0 then raise exception '0227 self-assert FAIL: no hostile rows — the rebalance sweep would be vacuous'; end if;
  select count(*) into v_n from public.locations where location_type in ('safe_zone', 'rally_point');
  if v_n = 0 then raise exception '0227 self-assert FAIL: no safe/rally rows — the rebalance sweep would be vacuous'; end if;
  select count(*) into v_n from public.mining_fields;
  if v_n = 0 then raise exception '0227 self-assert FAIL: no mining_fields rows — the rescale sweep would be vacuous'; end if;

  -- (B) world-wide envelope sanity on locations.x/y (the table itself carries no bounds CHECK, unlike
  --     mining_fields/space_anchors/main_ship_space_movements — assert it explicitly here since a 3x
  --     spread is exactly the kind of edit that could someday push a site out of a sane range).
  select count(*) into v_n from public.locations
   where x < -10000 or x > 10000 or y < -10000 or y > 10000;
  if v_n <> 0 then
    raise exception '0227 self-assert FAIL: % location(s) fell outside the [-10000,10000]^2 sanity envelope after the 3x spread', v_n;
  end if;

  -- (C) mining_fields stayed inside their OWN table CHECK envelope (belt-and-suspenders — the CHECK
  --     itself would already have aborted the UPDATE on any breach; this pins the post-state).
  select count(*) into v_n from public.mining_fields
   where space_x < -10000 or space_x > 10000 or space_y < -10000 or space_y > 10000;
  if v_n <> 0 then
    raise exception '0227 self-assert FAIL: % mining field(s) outside the [-10000,10000]^2 envelope after the 0.25x rescale', v_n;
  end if;
  select count(*) into v_fields from public.mining_fields;
  select count(*) into v_n from public.mining_fields
   where name = 'Sparse Ore Belt' and space_x = 375 and space_y = 225;
  if v_n <> 1 then raise exception '0227 self-assert FAIL: Sparse Ore Belt did not land at (375,225)'; end if;
  select count(*) into v_n from public.mining_fields
   where name = 'Singularity Scar' and space_x = 1050 and space_y = 775;
  if v_n <> 1 then raise exception '0227 self-assert FAIL: Singularity Scar did not land at (1050,775)'; end if;

  -- (D) GENERIC TERRITORY DISJOINTNESS, re-verified on the DEPLOYED post-scale world (every status,
  --     hidden included — the 0220 rule): no two territory-bearing locations may overlap, and no ring
  --     may reach another territory-bearing location's center. Composes public.osn_distance (0099) —
  --     never a second distance formula.
  select count(*) into v_n
    from public.locations a
    join public.locations b on a.id < b.id
   where a.territory_radius is not null and b.territory_radius is not null
     and public.osn_distance(a.x, a.y, b.x, b.y) <= (a.territory_radius + b.territory_radius);
  if v_n <> 0 then
    raise exception '0227 self-assert FAIL: % overlapping territory pair(s) after the 3x spread — the proportional-scaling proof does not hold on the live data', v_n;
  end if;
  select count(*) into v_n
    from public.locations a
    join public.locations b on a.id <> b.id
   where a.territory_radius is not null and b.territory_radius is not null
     and public.osn_distance(a.x, a.y, b.x, b.y) <= a.territory_radius;
  if v_n <> 0 then
    raise exception '0227 self-assert FAIL: % ring(s) reach another location''s center after the 3x spread', v_n;
  end if;

  -- (E) HAZARD A closed: every ACTIVE location-kind anchor's coordinate EXACTLY equals its location's
  --     (now 3x) coordinate — the 0066 invariant, re-proven after the retire+insert relocation — and
  --     exactly one active anchor survives per anchored location (no double-active, no orphan-retire).
  select count(*) into v_anchors from public.space_anchors where kind = 'location' and status = 'active';
  select count(*) into v_n
    from public.space_anchors a
    join public.locations l on l.id = a.location_id
   where a.kind = 'location' and a.status = 'active'
     and (a.space_x is distinct from l.x or a.space_y is distinct from l.y);
  if v_n <> 0 then
    raise exception '0227 self-assert FAIL: % active location anchor(s) drifted from their location''s coordinate after relocation', v_n;
  end if;
  select count(*) into v_n
    from (select location_id from public.space_anchors
           where kind = 'location' and status = 'active'
           group by location_id having count(*) > 1) dup;
  if v_n <> 0 then
    raise exception '0227 self-assert FAIL: % location(s) ended up with more than one active anchor', v_n;
  end if;

  -- (F) HAZARD B closed: every currently in-flight location-targeted leg's frozen target snapshot
  --     EXACTLY matches its target's live active anchor coordinate — the exact equality Dock-0
  --     (0067:568) demands at arrival, so no en-route ship can terminally fail with
  --     'target_anchor_changed' as a result of THIS migration. (Zero in-flight rows is a legitimate,
  --     expected pass — the coordinate-domain send path is still flag-dark per 0067/0068 — so this is
  --     an existence-free correctness check, not a vacuity-guarded count.)
  select count(*) into v_moving_locs
    from public.main_ship_space_movements where target_kind = 'location' and status = 'moving';
  -- INNER join on purpose: a moving row must match EXACTLY ONE active anchor at the CORRECT
  -- coordinate to count — a row targeting a location with no active anchor at all (which would
  -- silently vanish from a mismatch-only count) fails this equality-of-counts check instead.
  select count(*) into v_n
    from public.main_ship_space_movements m
    join public.space_anchors a on a.location_id = m.target_location_id and a.kind = 'location' and a.status = 'active'
   where m.target_kind = 'location' and m.status = 'moving'
     and m.target_x = a.space_x and m.target_y = a.space_y;
  if v_n <> v_moving_locs then
    raise exception '0227 self-assert FAIL: only %/% in-flight location-targeted movement(s) match their target''s live active anchor after reconciliation — the rest would terminally fail at arrival', v_n, v_moving_locs;
  end if;

  -- (G) exact retuned-radius class map still holds post-scale (30/36/24/NULL — the 0220 map times 3).
  select count(*) into v_territory from public.locations where territory_radius is not null;
  select count(*) into v_n from public.locations
   where (location_type = 'trade_outpost' and territory_radius is distinct from 30)
      or (location_type in ('pirate_hunt', 'pirate_den') and territory_radius is distinct from 36)
      or (location_type in ('safe_zone', 'rally_point') and territory_radius is distinct from 24)
      or (location_type in ('mining_site', 'derelict_station', 'event_site') and territory_radius is not null);
  if v_n <> 0 then
    raise exception '0227 self-assert FAIL: % location(s) off the rebalanced radius map (30/36/24/NULL)', v_n;
  end if;

  select count(*) into v_locations from public.locations;

  raise notice '0227 self-assert ok: % locations spread 3x (envelope-clean); % territory rings retuned 30/36/24 class-complete with zero overlaps/center-hits on the deployed world; % mining_fields rescaled 0.25x (Sparse Ore Belt->(375,225), Singularity Scar->(1050,775)); % active location anchor(s) relocated in lockstep (0066 invariant intact, no dup-actives); % in-flight location-targeted leg(s) reconciled to their new anchor (zero mismatches)',
    v_locations, v_territory, v_fields, v_anchors, v_moving_locs;
end $$;
