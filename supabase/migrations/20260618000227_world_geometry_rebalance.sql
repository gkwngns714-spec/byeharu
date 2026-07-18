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
-- HAZARD C (found via CI: team-command-proof.sql:311 → "reveal_starter_ports: port ... missing
-- approved active anchor ... at (-50, -30)") — reveal_starter_ports() (0068) hardcodes BOTH the
-- approved anchor COORDINATE (v_ax/v_ay literals, pre-rebalance values) AND, more subtly, the
-- approved anchor's own ROW ID (c_a1/c_a2/c_a3 / v_anchors, matched via `a.id = v_anchors[i]`).
-- The coordinate literal is the obviously stale one — but the id pin is independently broken by
-- HAZARD A's fix: §4's mandatory retire+insert relocation mints a FRESH anchor id every time (0063's
-- lifecycle, by design), so pinning a specific historical anchor id can never again match after ANY
-- legitimate relocation, this one or a future one. §6 below re-creates reveal_starter_ports() with
-- the ×3 coordinates AND drops the id pin in favor of the invariant it was standing in for (exactly
-- one ACTIVE location-kind anchor for this port, at the approved coordinate) — resolved dynamically,
-- so the function survives this relocation and any future one. Full grep sweep for every other
-- hardcoded starter-port/anchor coordinate or id literal (locations.x/y and space_anchors.space_x/y
-- old values -50/-30, 70/-10, 10/80, and the b1a0a00{1,2,3} anchor ids) across every migration and
-- proof script found exactly ONE other class of hit, and neither needs a code change:
--   • 0066 (the original seed), 0154 (a one-time relocation of the OTHER five waypoints, whose own
--     read-back guard pins the THREE PORTS unchanged at their 0066 seed) and 0175 (a one-time content
--     bbox check) are migrations that already RAN — historical record, never re-executed against a
--     live chain, no live behavior to break.
--   • 0218's movement_position_at test uses -50/-30/80/-10 as arbitrary literal INPUTS to a pure
--     interpolation-math unit assertion, not a read of real world data — unaffected by any world edit.
--   • scripts/osn-hub1a-production-catalog-verify.sql hardcodes the OLD port/anchor coordinates too,
--     but by its own design (`chk "A1 migration head 0068" ... N_AFTER=0`) it REFUSES to run against
--     any chain with a migration after 0068 — it can never see 0227's schema and is structurally
--     inert here, not merely unlikely to run.
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

-- ── 6) HAZARD C fix — re-create reveal_starter_ports() (0068 TRUE HEAD superseded HERE): the ×3
--    approved coordinates, AND the id-pin removed in favor of a dynamic "current active anchor"
--    resolution (§4's retire+insert relocation mints a fresh anchor id — no literal survives it).
--    Byte-copy of the 0068 body with exactly the two marked HUNKs; every lock order, error message
--    shape, and the all-or-nothing hidden→active decision are unchanged.
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
  c_s1 constant uuid := 'b1a05001-0066-4a00-8a00-000000000051';
  c_s2 constant uuid := 'b1a05002-0066-4a00-8a00-000000000052';
  c_s3 constant uuid := 'b1a05003-0066-4a00-8a00-000000000053';
  v_ports    uuid[] := array[c_p1, c_p2, c_p3];
  v_services uuid[] := array[c_s1, c_s2, c_s3];
  -- 0227 HUNK 1: the approved anchor coordinate is now the 3x-rescaled value (0066's -50/-30,
  -- 70/-10, 10/80 times 3). The anchor's own row id is INTENTIONALLY no longer a fixed literal here
  -- (see 0227 HUNK 2 below and the file header's HAZARD C note).
  v_ax double precision[] := array[-150, 210, 30];
  v_ay double precision[] := array[-90, -30, 240];
  r record;
  i int;
  v_hidden int;
  v_active int;
begin
  -- Acquire the FULL target hierarchy in the canonical deterministic order BEFORE any read / validation /
  -- decision / write, so no privileged concurrent mutation can alter a validated hierarchy, anchor, or
  -- service between validation and the reveal update (TOCTOU-closed). Order = sector → zone → location →
  -- anchor → docking service (same order as mainship_space_dock_at_location / assign_home_port), and within
  -- each class the rows are locked in ascending id order (deadlock-free).
  --   • read-only dependencies (sectors, zones, anchors, services) → FOR SHARE: a SHARE row lock conflicts
  --     with the FOR NO KEY UPDATE a concurrent status disable/retire takes, so a validated row cannot change
  --     while this function holds its locks;
  --   • the three target locations → FOR UPDATE, because their status is what this function mutates.
  perform 1 from public.sectors se
    where se.id in (select distinct z.sector_id
                      from public.locations l join public.zones z on z.id = l.zone_id
                      where l.id = any(v_ports))
    order by se.id for share;
  perform 1 from public.zones z
    where z.id in (select distinct l.zone_id from public.locations l where l.id = any(v_ports))
    order by z.id for share;
  perform 1 from public.locations     where id = any(v_ports)    order by id for update;
  -- 0227 HUNK 2: lock whichever location-kind anchor is CURRENTLY active for these ports — a fixed
  -- literal anchor id cannot survive the §4 retire+insert relocation (or any future one), so the set
  -- to lock is resolved dynamically instead of from a hardcoded array.
  perform 1 from public.space_anchors
    where kind = 'location' and status = 'active' and location_id = any(v_ports)
    order by id for share;
  perform 1 from public.location_services where id = any(v_services) order by id for share;

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
    -- 0227 HUNK 2 (cont.): exactly one active canonical anchor owned by THIS port, kind location, at
    -- the approved (now 3x) coordinate — no fixed anchor-id literal in the predicate anymore; the
    -- "exactly one" check right below independently re-proves there is no ambiguity to exploit.
    if (select count(*) from public.space_anchors a
          where a.location_id = v_ports[i] and a.kind = 'location' and a.status = 'active'
            and a.space_x = v_ax[i] and a.space_y = v_ay[i]
            and a.space_x between -10000 and 10000 and a.space_y between -10000 and 10000) <> 1 then
      raise exception 'reveal_starter_ports: port % missing approved active anchor at (%, %)', v_ports[i], v_ax[i], v_ay[i]; end if;
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

-- ── Self-assert (deploy-time; a raise aborts the migration txn — nothing half-applies) ───────────────
do $$
declare
  v_n           int;
  v_locations   int;
  v_territory   int;
  v_fields      int;
  v_anchors     int;
  v_moving_locs int;
  v_src         text;
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

  -- (F2) HAZARD C closed, proven STRUCTURALLY on the deployed function body — never INVOKED here (a
  --      live hidden→active status flip is a deliberate human/operation-script action, out of scope
  --      for a geometry migration, exactly per 0068's own dark-by-default charter). The re-created
  --      reveal_starter_ports() must carry the ×3 arrays and must NOT carry the old pre-rebalance
  --      arrays or the retired fixed anchor-id predicate.
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.reveal_starter_ports()')::oid;
  if v_src is null then
    raise exception '0227 self-assert FAIL: public.reveal_starter_ports() does not exist';
  end if;
  if position('array[-150, 210, 30]' in v_src) = 0 or position('array[-90, -30, 240]' in v_src) = 0 then
    raise exception '0227 self-assert FAIL: reveal_starter_ports() does not carry the rebalanced (x3) anchor coordinate arrays';
  end if;
  if position('array[-50, 70, 10]' in v_src) > 0 or position('array[-30, -10, 80]' in v_src) > 0 then
    raise exception '0227 self-assert FAIL: reveal_starter_ports() still carries a pre-rebalance coordinate array — the re-create did not land';
  end if;
  if position('a.id = v_anchors[i]' in v_src) > 0 then
    raise exception '0227 self-assert FAIL: reveal_starter_ports() still pins a fixed anchor-id literal — it cannot survive the §4 relocation';
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

  raise notice '0227 self-assert ok: % locations spread 3x (envelope-clean); % territory rings retuned 30/36/24 class-complete with zero overlaps/center-hits on the deployed world; % mining_fields rescaled 0.25x (Sparse Ore Belt->(375,225), Singularity Scar->(1050,775)); % active location anchor(s) relocated in lockstep (0066 invariant intact, no dup-actives); % in-flight location-targeted leg(s) reconciled to their new anchor (zero mismatches); reveal_starter_ports() re-created with the x3 anchor coordinates and no fixed anchor-id pin (structurally proven, not invoked)',
    v_locations, v_territory, v_fields, v_anchors, v_moving_locs;
end $$;
