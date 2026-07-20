-- Byeharu — WORLD-EDITOR V1C PR-C: COORDINATE NORMALIZE — uniformly scale the map-seed frame
-- (sectors / zones / locations + territory rings + danger-zone polygons + anchors + in-flight legs)
-- by ONE live-computed integer constant k into the OSN ±10000 frame, so public.space_anchors becomes
-- a coherent single coordinate authority over ONE shared world scale.
--
-- ⚠️ WORLD-AFFECTING / PLAYER-VISIBLE / UNDEPLOYED: this migration changes every stored map-seed
-- coordinate. Its deploy is the OWNER'S GATE — it must NOT ride an automatic deploy train. It is the
-- 0227 (world_geometry_rebalance) template generalized: uniform scale + retire/insert anchor
-- relocation + in-flight reconcile + full self-assert envelope, all in ONE transaction that ABORTS
-- WHOLE on any parity failure (nothing half-applies).
--
-- WHY (V1C direction, after 0245): 0245 anchored EVERY location at exactly its (x, y), but the world
-- still lives on two scales — the map seed occupies <3% of the ±10000 OSN frame while
-- mining_fields / exploration_sites (0103/0098) were authored directly in the ±10000 frame. This
-- slice closes the map-seed side: one uniform integer scale k lifts sectors/zones/locations (and
-- everything welded to them) into the same frame. The read-cutover of get_world_map to anchors is a
-- LATER slice (PR-D) — get_world_map's body is deliberately NOT touched here (assert H pins that).
--
-- THE ONE CONSTANT k — COMPUTED FROM LIVE DATA, NEVER HARDCODED:
--   M := the maximum post-would-be extent over every scaled class:
--          locations:  greatest(|x|, |y|, |x| + coalesce(territory_radius, 0), |y| + coalesce(territory_radius, 0))
--          sectors:    greatest(|x|, |y|)
--          zones:      greatest(|x|, |y|, |x| + radius, |y| + radius)   -- radius included: belt-and-suspenders
--          danger_zones: greatest(|ST_XMin|, |ST_XMax|, |ST_YMin|, |ST_YMax|) of every boundary
--   k := floor((10000 * 0.85) / M)   -- 15% headroom below the hard ±10000 envelope
--   Asserted: k >= 1 (integer) and M * k < 10000. k is an INTEGER so the scale is EXACTLY reversible
--   by /k on the integer world grid, and the integer grid + the anchor==location equality survive.
--
-- WHAT IS SCALED (all by the SAME k, all in this one txn):
--   §2 locations.x/y AND locations.territory_radius (numeric × int — exact);
--   §3 sectors.x/y;
--   §4 zones.x/y AND zones.radius;
--   §5 danger_zones.boundary via ST_Scale(boundary, k, k) — NOT re-derived: 0237 minted irregular
--      random "slime" blobs; ST_Scale about the origin is the unique transform that preserves their
--      exact shape AND their center-containment relative to the equally-scaled location centers.
--      (Re-running 0237's generator would mint NEW random shapes — a different world, not a scale.)
--   §6 space_anchors: RETIRE + INSERT every active location-kind anchor at its location's POST-SCALE
--      (x, y) — the 0063 lifecycle (the immutability guard FORBIDS in-place coordinate edits; the
--      0227 §4 idiom, now world-wide per 0245). Deliberately re-synced FROM the location, not scaled
--      from the old anchor value: the 0249 editor location-update writes locations.x/y WITHOUT
--      touching the anchor (a known seam), so any drifted anchor is healed here and assert (A)
--      re-proves anchor == location EXACTLY, world-wide, by construction.
--   §7 in-flight fleet_movements reconcile (the 0227 HAZARD-B idiom on the surviving engine —
--      main_ship_space_movements was DROPPED by 0231/0232; fleet_movements is the sole movement
--      spine): every status='moving' leg's origin/target snapshot whose origin_type/target_type is
--      'location' (or 'zone' — zones scale too) is scaled by k, so movement_position_at
--      interpolation, redirects, and the intercept geometry stay coherent mid-flight. Raw 'space'
--      legs and 'base' endpoints are UNTOUCHED (bases sit at the unscaled player origin; raw space
--      coordinates are the ship's own state, never derived from a location — the 0227 rule).
--      NOTE (disclosed seam): a timed-docking port target is translated to a 'space' leg at the
--      port's coordinate by the 0219 S4 hunk — such a leg is indistinguishable from a raw space leg
--      and keeps its old-frame coordinate; the fleet arrives parked in space near the port's OLD
--      spot and simply re-issues a go. No terminal failure exists on this engine: location arrivals
--      settle purely by target_location_id (0208/0153), never by coordinate equality.
--   §8 reveal_starter_ports() re-created (0227 TRUE HEAD superseded HERE) with its approved-anchor
--      coordinate literals × k — built DYNAMICALLY from the three ports' live post-scale rows (no
--      hardcoded k, no hardcoded product), keeping 0227's dynamic-anchor resolution (no anchor-id
--      pin) and its full self-assert body byte-for-byte otherwise.
--
-- WHAT IS DELIBERATELY NOT SCALED (each asserted or documented below):
--   • get_world_map()'s BODY — unchanged; it still reads locations.x/y, which now carry the new
--     frame. The anchor read-cutover is PR-D. (assert H)
--   • mining_fields / exploration_sites — ALREADY authored in the ±10000 frame (0103/0098); scaling
--     them would double-apply. This is the design's disclosed interim seam until the frames are
--     unified by content design, not by math. (assert I pins them byte-identical.)
--   • combat_units.pos_x/pos_y — a separate LOCAL combat frame, not the world frame.
--   • bases.x/y — every base sits at the player-home origin (0,0); no base-kind anchor exists
--     (0227-verified) — a uniform scale fixes the origin anyway.
--   • fleets.space_x/space_y & raw 'space' movement coordinates — a ship parked in open space stays
--     at its raw coordinate (the standing OSN convention, 0227). Its position RELATIVE to the newly
--     scaled named world changes — a disclosed, self-healing seam (the player just flies on).
--   • fleet_route_legs 'space' waypoints — raw coordinates, same rule.
--
-- PLAYER-VISIBLE CONSEQUENCES (why deploy is the owner's gate):
--   • every stored map coordinate changes (the camera-fit LAYOUT is preserved — the client's
--     fitCameraToWorldPoints frames the content bounding box, and a uniform scale maps to the exact
--     same framed picture — but zoom level, coordinates shown, and positions relative to unscaled
--     mining/exploration/ship points all shift);
--   • travel DISTANCES between named sites grow ×k, so travel TIMES grow ×k until speeds are
--     retuned — a deliberate follow-up owner decision, not smuggled into this migration.
--
-- EXACT-REVERSIBILITY CONTRACT (assert R): after scaling, every scalar coordinate divided by k must
-- equal its snapshotted pre-image BIT-FOR-BIT. On the integer world grid this is guaranteed
-- (x·k is an exact double product; the true quotient x is representable). If any live coordinate
-- cannot round-trip exactly (an exotic non-grid double), this migration REFUSES to apply a lossy
-- scale and ABORTS — fail-closed, nothing half-applies. Danger-zone polygon vertices are
-- full-mantissa doubles by construction (0237's random generator), so their forward scale is pinned
-- bit-for-bit against pre×k and their reverse /k is pinned to a 1e-9 tolerance (documented float
-- seam ~1e-12 relative; the polygons are derived decoration, not the authored grid).

-- ── 0) dependency gate ───────────────────────────────────────────────────────────────────────────
do $v1c0$
begin
  if to_regclass('public.locations') is null or to_regclass('public.zones') is null
     or to_regclass('public.sectors') is null then
    raise exception 'V1C-NORMALIZE: world tables (0002) missing';
  end if;
  if to_regclass('public.space_anchors') is null then
    raise exception 'V1C-NORMALIZE: public.space_anchors (0063) missing';
  end if;
  if to_regclass('public.danger_zones') is null then
    raise exception 'V1C-NORMALIZE: public.danger_zones (0233) missing';
  end if;
  if to_regclass('public.fleet_movements') is null then
    raise exception 'V1C-NORMALIZE: public.fleet_movements (0007) missing';
  end if;
  if to_regclass('public.main_ship_space_movements') is not null then
    raise exception 'V1C-NORMALIZE: main_ship_space_movements still exists — 0231 must have retired it; this migration reconciles the unified engine only';
  end if;
  if to_regprocedure('public.osn_distance(double precision, double precision, double precision, double precision)') is null then
    raise exception 'V1C-NORMALIZE: public.osn_distance (0099) missing — the disjointness sweep composes it';
  end if;
  if to_regprocedure('public.st_scale(geometry, double precision, double precision)') is null then
    raise exception 'V1C-NORMALIZE: PostGIS ST_Scale (0233 installs postgis) missing';
  end if;
  if to_regprocedure('public.reveal_starter_ports()') is null then
    raise exception 'V1C-NORMALIZE: public.reveal_starter_ports() (0068/0227) missing — its coordinate literals must be rescaled here';
  end if;
  if to_regprocedure('public.get_world_map()') is null then
    raise exception 'V1C-NORMALIZE: public.get_world_map() missing';
  end if;
end $v1c0$;

-- ── 1) PRE-IMAGE SNAPSHOT (temp, txn-scoped) + compute k from LIVE data ──────────────────────────
create temporary table _v1c0251_pre_locations on commit drop as
  select id, x, y, territory_radius from public.locations;
create temporary table _v1c0251_pre_sectors on commit drop as
  select id, x, y from public.sectors;
create temporary table _v1c0251_pre_zones on commit drop as
  select id, x, y, radius from public.zones;
create temporary table _v1c0251_pre_danger on commit drop as
  select id, boundary from public.danger_zones;
create temporary table _v1c0251_pre_moves on commit drop as
  select id, origin_type, origin_x, origin_y, target_type, target_x, target_y
    from public.fleet_movements where status = 'moving';
create temporary table _v1c0251_pre_mining on commit drop as
  select id, space_x, space_y from public.mining_fields;
create temporary table _v1c0251_pre_exploration on commit drop as
  select id, space_x, space_y from public.exploration_sites;

create temporary table _v1c0251_scale (k integer not null) on commit drop;

do $v1c1$
declare
  v_m_loc    double precision;
  v_m_sec    double precision;
  v_m_zone   double precision;
  v_m_danger double precision;
  v_m        double precision;
  v_k        integer;
begin
  select coalesce(max(greatest(abs(x), abs(y),
                               abs(x) + coalesce(territory_radius, 0)::double precision,
                               abs(y) + coalesce(territory_radius, 0)::double precision)), 0)
    into v_m_loc from public.locations;
  select coalesce(max(greatest(abs(x), abs(y))), 0) into v_m_sec from public.sectors;
  select coalesce(max(greatest(abs(x), abs(y), abs(x) + radius, abs(y) + radius)), 0)
    into v_m_zone from public.zones;
  select coalesce(max(greatest(abs(ST_XMin(boundary)), abs(ST_XMax(boundary)),
                               abs(ST_YMin(boundary)), abs(ST_YMax(boundary)))), 0)
    into v_m_danger from public.danger_zones;

  v_m := greatest(v_m_loc, v_m_sec, v_m_zone, v_m_danger);
  if v_m <= 0 then
    raise exception 'V1C-NORMALIZE FAIL: world extent M = % — an empty/degenerate world cannot be normalized (vacuous scale)', v_m;
  end if;

  v_k := floor((10000 * 0.85) / v_m)::integer;
  if v_k < 1 then
    raise exception 'V1C-NORMALIZE FAIL: computed k = % from extent M = % — the world is already at (or beyond) the target frame; nothing to normalize', v_k, v_m;
  end if;
  if v_m * v_k >= 10000 then
    raise exception 'V1C-NORMALIZE FAIL: M·k = % × % = % would breach the ±10000 envelope', v_m, v_k, v_m * v_k;
  end if;

  insert into _v1c0251_scale (k) values (v_k);
  raise notice 'V1C-NORMALIZE: live extent M = % (loc %, sec %, zone %, danger %) -> integer scale k = % (M·k = %, envelope 10000)',
    v_m, v_m_loc, v_m_sec, v_m_zone, v_m_danger, v_k, v_m * v_k;
end $v1c1$;

-- ── 2) locations: x/y AND territory_radius × k (every row, every status — hidden rows must already
--       be coherent, the 0220/0227 rule). numeric × integer is exact; double × integer is exact on
--       the integer grid (assert R re-proves the round-trip). ────────────────────────────────────
update public.locations
   set x = x * (select k from _v1c0251_scale),
       y = y * (select k from _v1c0251_scale),
       territory_radius = territory_radius * (select k from _v1c0251_scale);

-- ── 3) sectors × k ───────────────────────────────────────────────────────────────────────────────
update public.sectors
   set x = x * (select k from _v1c0251_scale),
       y = y * (select k from _v1c0251_scale);

-- ── 4) zones: x/y AND radius × k ─────────────────────────────────────────────────────────────────
update public.zones
   set x = x * (select k from _v1c0251_scale),
       y = y * (select k from _v1c0251_scale),
       radius = radius * (select k from _v1c0251_scale);

-- ── 5) danger_zones: ST_Scale about the origin — shape + center-containment preserving (see header;
--       every row, every status; source='circle' AND source='drawn' alike — both live in the same
--       world frame as the locations they wrap). ─────────────────────────────────────────────────
update public.danger_zones
   set boundary = ST_Scale(boundary,
                           (select k from _v1c0251_scale)::double precision,
                           (select k from _v1c0251_scale)::double precision),
       updated_at = now();

-- ── 6) space_anchors: retire + insert EVERY active location-kind anchor at its location's new
--       post-scale (x, y) — the mandatory 0063 lifecycle (the immutability guard forbids in-place
--       coordinate edits), the 0227 §4 idiom generalized to the whole 0245-anchored world. Re-synced
--       FROM the location (not ×k from the old anchor value) so any 0249-editor drift is healed and
--       anchor == location holds world-wide BY CONSTRUCTION (assert A re-proves it). ─────────────
do $v1c6$
declare
  v_retired  integer;
  v_inserted integer;
begin
  update public.space_anchors
     set status = 'retired'
   where kind = 'location' and status = 'active';
  get diagnostics v_retired = row_count;

  insert into public.space_anchors (kind, location_id, space_x, space_y, status)
  select 'location', l.id, l.x, l.y, 'active'
    from public.locations l
   order by l.id;
  get diagnostics v_inserted = row_count;

  raise notice 'V1C-NORMALIZE §6: % active location anchor(s) retired, % fresh anchor(s) inserted at the post-scale location coordinates', v_retired, v_inserted;
end $v1c6$;

-- ── 7) in-flight reconcile (0227 HAZARD-B idiom, unified engine): scale the frozen origin/target
--       snapshots of every MOVING leg whose endpoint is a named location (or zone — zones scaled
--       too). Raw 'space' legs and 'base' endpoints untouched (see header). ──────────────────────
update public.fleet_movements
   set target_x = target_x * (select k from _v1c0251_scale),
       target_y = target_y * (select k from _v1c0251_scale)
 where status = 'moving' and target_type in ('location', 'zone');

update public.fleet_movements
   set origin_x = origin_x * (select k from _v1c0251_scale),
       origin_y = origin_y * (select k from _v1c0251_scale)
 where status = 'moving' and origin_type in ('location', 'zone');

-- ── 8) reveal_starter_ports() re-created (0227 TRUE HEAD superseded HERE): the SAME body — dynamic
--       anchor resolution, no anchor-id pin, full per-port self-assert — with the approved anchor
--       coordinate literals rebuilt ×k from the three ports' LIVE post-scale rows (never a
--       hardcoded product). ──────────────────────────────────────────────────────────────────────
do $v1c8$
declare
  c_p1 constant uuid := 'b1a00001-0066-4a00-8a00-000000000001';  -- Haven Reach (city)
  c_p2 constant uuid := 'b1a00002-0066-4a00-8a00-000000000002';  -- Slagworks Anchorage (port)
  c_p3 constant uuid := 'b1a00003-0066-4a00-8a00-000000000003';  -- Driftmarch Waypost (port)
  v_x1 double precision; v_y1 double precision;
  v_x2 double precision; v_y2 double precision;
  v_x3 double precision; v_y3 double precision;
  v_ax_txt text;
  v_ay_txt text;
  v_body   text;
begin
  select x, y into v_x1, v_y1 from public.locations where id = c_p1;
  if not found then raise exception 'V1C-NORMALIZE §8: starter port % missing', c_p1; end if;
  select x, y into v_x2, v_y2 from public.locations where id = c_p2;
  if not found then raise exception 'V1C-NORMALIZE §8: starter port % missing', c_p2; end if;
  select x, y into v_x3, v_y3 from public.locations where id = c_p3;
  if not found then raise exception 'V1C-NORMALIZE §8: starter port % missing', c_p3; end if;

  v_ax_txt := v_x1::text || ', ' || v_x2::text || ', ' || v_x3::text;
  v_ay_txt := v_y1::text || ', ' || v_y2::text || ', ' || v_y3::text;

  -- The 0227 body verbatim, with the two coordinate arrays as placeholders (0251 HUNK) and the HUNK
  -- comments updated to name this migration. Everything else — lock order, error message shapes, the
  -- dynamic-anchor resolution, the all-or-nothing hidden→active decision — is byte-identical.
  v_body := $rsp$
declare
  c_p1 constant uuid := 'b1a00001-0066-4a00-8a00-000000000001';  -- Haven Reach (city)
  c_p2 constant uuid := 'b1a00002-0066-4a00-8a00-000000000002';  -- Slagworks Anchorage (port)
  c_p3 constant uuid := 'b1a00003-0066-4a00-8a00-000000000003';  -- Driftmarch Waypost (port)
  c_s1 constant uuid := 'b1a05001-0066-4a00-8a00-000000000051';
  c_s2 constant uuid := 'b1a05002-0066-4a00-8a00-000000000052';
  c_s3 constant uuid := 'b1a05003-0066-4a00-8a00-000000000053';
  v_ports    uuid[] := array[c_p1, c_p2, c_p3];
  v_services uuid[] := array[c_s1, c_s2, c_s3];
  -- 0251 HUNK 1: the approved anchor coordinate is the V1C-normalized (×k) value, injected from the
  -- ports' live post-scale rows at migration time. The anchor's own row id remains INTENTIONALLY
  -- dynamic (the 0227 HAZARD-C rule: retire+insert relocation mints a fresh id every time).
  v_ax double precision[] := array[__AX__];
  v_ay double precision[] := array[__AY__];
  r record;
  i int;
  v_hidden int;
  v_active int;
begin
  -- Acquire the FULL target hierarchy in the canonical deterministic order BEFORE any read / validation /
  -- decision / write, so no privileged concurrent mutation can alter a validated hierarchy, anchor, or
  -- service between validation and the reveal update (TOCTOU-closed). Order = sector → zone → location →
  -- anchor → docking service (same order as assign_home_port), and within each class the rows are locked
  -- in ascending id order (deadlock-free).
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
  -- 0251 HUNK 2 (unchanged from 0227): lock whichever location-kind anchor is CURRENTLY active for
  -- these ports — a fixed literal anchor id cannot survive a retire+insert relocation, so the set to
  -- lock is resolved dynamically instead of from a hardcoded array.
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
    -- 0251 HUNK 2 (cont., unchanged from 0227): exactly one active canonical anchor owned by THIS
    -- port, kind location, at the approved (now ×k) coordinate — no fixed anchor-id literal; the
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
$rsp$;

  v_body := replace(v_body, '__AX__', v_ax_txt);
  v_body := replace(v_body, '__AY__', v_ay_txt);

  execute 'create or replace function public.reveal_starter_ports() returns jsonb language plpgsql security definer set search_path = public as '
          || quote_literal(v_body);

  raise notice 'V1C-NORMALIZE §8: reveal_starter_ports() re-created with approved anchor arrays [%] / [%]', v_ax_txt, v_ay_txt;
end $v1c8$;

revoke all on function public.reveal_starter_ports() from public, anon, authenticated;
grant execute on function public.reveal_starter_ports() to service_role;

-- ── 9) FULL PARITY SELF-ASSERT (deploy-time; ANY raise aborts the WHOLE txn — nothing half-applies) ─
do $v1c9$
declare
  v_k          integer;
  v_n          integer;
  v_n2         integer;
  v_locations  integer;
  v_anchors    integer;
  v_moving     integer;
  v_danger     integer;
  v_src        text;
  v_ax_txt     text;
  v_ay_txt     text;
begin
  select k into v_k from _v1c0251_scale;

  -- (vacuity) the probed classes exist — a world with none would green every sweep while proving
  -- nothing (the 0220/0227 rule).
  select count(*) into v_locations from public.locations;
  if v_locations = 0 then raise exception '0251 self-assert FAIL: no locations — every sweep vacuous'; end if;
  select count(*) into v_n from public.locations where territory_radius is not null;
  if v_n = 0 then raise exception '0251 self-assert FAIL: no territory-bearing locations — the disjointness sweep would be vacuous'; end if;
  select count(*) into v_danger from public.danger_zones where source = 'circle';
  if v_danger = 0 then raise exception '0251 self-assert FAIL: no source=circle danger zones — the containment sweep would be vacuous (0233 did not seed)'; end if;

  -- (A) anchor == location EXACTLY, world-wide, count-matched, no duplicate actives (0066/0227/0245).
  select count(*) into v_anchors from public.space_anchors where kind = 'location' and status = 'active';
  if v_anchors <> v_locations then
    raise exception '0251 self-assert FAIL (A): % active location anchor(s) for % location(s)', v_anchors, v_locations;
  end if;
  select count(*) into v_n
    from public.space_anchors a
    join public.locations l on l.id = a.location_id
   where a.kind = 'location' and a.status = 'active'
     and (a.space_x is distinct from l.x or a.space_y is distinct from l.y);
  if v_n <> 0 then
    raise exception '0251 self-assert FAIL (A): % active anchor(s) differ from their location''s exact post-scale (x,y)', v_n;
  end if;
  select count(*) into v_n
    from (select location_id from public.space_anchors
           where kind = 'location' and status = 'active'
           group by location_id having count(*) > 1) dup;
  if v_n <> 0 then
    raise exception '0251 self-assert FAIL (A): % location(s) with more than one active anchor', v_n;
  end if;

  -- (B) envelope: NOTHING scaled may leave [-10000, 10000] — including ring/radius extents and every
  --     danger-zone vertex.
  select count(*) into v_n from public.locations
   where greatest(abs(x), abs(y),
                  abs(x) + coalesce(territory_radius, 0)::double precision,
                  abs(y) + coalesce(territory_radius, 0)::double precision) > 10000;
  if v_n <> 0 then raise exception '0251 self-assert FAIL (B): % location(s)/ring(s) outside the ±10000 envelope', v_n; end if;
  select count(*) into v_n from public.sectors where greatest(abs(x), abs(y)) > 10000;
  if v_n <> 0 then raise exception '0251 self-assert FAIL (B): % sector(s) outside the envelope', v_n; end if;
  select count(*) into v_n from public.zones
   where greatest(abs(x), abs(y), abs(x) + radius, abs(y) + radius) > 10000;
  if v_n <> 0 then raise exception '0251 self-assert FAIL (B): % zone(s) outside the envelope', v_n; end if;
  select count(*) into v_n from public.danger_zones
   where greatest(abs(ST_XMin(boundary)), abs(ST_XMax(boundary)),
                  abs(ST_YMin(boundary)), abs(ST_YMax(boundary))) > 10000;
  if v_n <> 0 then raise exception '0251 self-assert FAIL (B): % danger zone(s) outside the envelope', v_n; end if;
  -- space_anchors carries its own hard CHECK (0063) — the inserts above already proved it; re-pin:
  select count(*) into v_n from public.space_anchors
   where status = 'active' and greatest(abs(space_x), abs(space_y)) > 10000;
  if v_n <> 0 then raise exception '0251 self-assert FAIL (B): % anchor(s) outside the envelope', v_n; end if;

  -- (C) RELATIVE GEOMETRY preserved — against the true SNAPSHOT pre-image (never a re-derivation):
  --     for EVERY location pair, post-scale osn_distance == k × pre-image distance (float tolerance)
  --     and the bearing is unchanged (uniform positive scale ⇒ a similarity transform).
  select count(*) into v_n
    from public.locations a
    join public.locations b on a.id < b.id
    join _v1c0251_pre_locations pa on pa.id = a.id
    join _v1c0251_pre_locations pb on pb.id = b.id
   where abs(public.osn_distance(a.x, a.y, b.x, b.y)
             - v_k * public.osn_distance(pa.x, pa.y, pb.x, pb.y))
         > 1e-6 * greatest(v_k * public.osn_distance(pa.x, pa.y, pb.x, pb.y), 1.0);
  if v_n <> 0 then
    raise exception '0251 self-assert FAIL (C): % location pair(s) broke distance-×k parity vs the snapshot pre-image', v_n;
  end if;
  select count(*) into v_n
    from public.locations a
    join public.locations b on a.id < b.id
    join _v1c0251_pre_locations pa on pa.id = a.id
    join _v1c0251_pre_locations pb on pb.id = b.id
   where (pa.x, pa.y) is distinct from (pb.x, pb.y)
     and abs(atan2(b.y - a.y, b.x - a.x) - atan2(pb.y - pa.y, pb.x - pa.x)) > 1e-9;
  if v_n <> 0 then
    raise exception '0251 self-assert FAIL (C): % location pair(s) changed bearing — the scale is not uniform', v_n;
  end if;

  -- (D) territory disjointness: (D1) overlap-SIGN preserved pair-for-pair vs the pre-image (the true
  --     parity claim — a uniform scale can neither create nor destroy an overlap), and (D2) the 0227
  --     disjointness sweeps re-run verbatim on the DEPLOYED post-scale world.
  select count(*) into v_n
    from public.locations a
    join public.locations b on a.id < b.id
    join _v1c0251_pre_locations pa on pa.id = a.id
    join _v1c0251_pre_locations pb on pb.id = b.id
   where a.territory_radius is not null and b.territory_radius is not null
     and (public.osn_distance(a.x, a.y, b.x, b.y) <= (a.territory_radius + b.territory_radius))
         is distinct from
         (public.osn_distance(pa.x, pa.y, pb.x, pb.y) <= (pa.territory_radius + pb.territory_radius));
  if v_n <> 0 then
    raise exception '0251 self-assert FAIL (D1): % pair(s) flipped overlap status across the scale', v_n;
  end if;
  select count(*) into v_n
    from public.locations a
    join public.locations b on a.id < b.id
   where a.territory_radius is not null and b.territory_radius is not null
     and public.osn_distance(a.x, a.y, b.x, b.y) <= (a.territory_radius + b.territory_radius);
  if v_n <> 0 then
    raise exception '0251 self-assert FAIL (D2): % overlapping territory pair(s) on the post-scale world', v_n;
  end if;
  select count(*) into v_n
    from public.locations a
    join public.locations b on a.id <> b.id
   where a.territory_radius is not null and b.territory_radius is not null
     and public.osn_distance(a.x, a.y, b.x, b.y) <= a.territory_radius;
  if v_n <> 0 then
    raise exception '0251 self-assert FAIL (D2): % ring(s) reach another location''s center on the post-scale world', v_n;
  end if;

  -- (E) every source='circle' danger zone still CONTAINS its location's new center (ST_Scale about
  --     the origin + the same-k location scale preserve containment; re-proven live, never trusted).
  select count(*) into v_n
    from public.danger_zones dz
    join public.locations l on l.id = dz.location_id
   where dz.source = 'circle'
     and not ST_Contains(dz.boundary, ST_MakePoint(l.x, l.y));
  if v_n <> 0 then
    raise exception '0251 self-assert FAIL (E): % circle danger zone(s) no longer contain their location''s center', v_n;
  end if;

  -- (F) in-flight reconcile: every MOVING location/zone-endpoint snapshot == k × its pre-image
  --     (bit-for-bit; zero in-flight rows is a legitimate pass — an existence-free correctness check,
  --     the 0227 (F) posture).
  select count(*) into v_moving from public.fleet_movements where status = 'moving';
  select count(*) into v_n
    from public.fleet_movements m
    join _v1c0251_pre_moves p on p.id = m.id
   where m.status = 'moving'
     and (   (m.target_type in ('location', 'zone')
              and (m.target_x is distinct from p.target_x * v_k or m.target_y is distinct from p.target_y * v_k))
          or (m.target_type not in ('location', 'zone')
              and (m.target_x is distinct from p.target_x or m.target_y is distinct from p.target_y))
          or (m.origin_type in ('location', 'zone')
              and (m.origin_x is distinct from p.origin_x * v_k or m.origin_y is distinct from p.origin_y * v_k))
          or (m.origin_type not in ('location', 'zone')
              and (m.origin_x is distinct from p.origin_x or m.origin_y is distinct from p.origin_y)));
  if v_n <> 0 then
    raise exception '0251 self-assert FAIL (F): % in-flight leg(s) off their exact ×k (location/zone) or untouched (space/base) pre-image', v_n;
  end if;

  -- (G) reveal_starter_ports structurally carries the new ×k arrays, not the old ones, and no
  --     anchor-id pin — proven on the DEPLOYED function body, never invoked (0227 (F2) posture).
  select l1.x::text || ', ' || l2.x::text || ', ' || l3.x::text,
         l1.y::text || ', ' || l2.y::text || ', ' || l3.y::text
    into v_ax_txt, v_ay_txt
    from public.locations l1, public.locations l2, public.locations l3
   where l1.id = 'b1a00001-0066-4a00-8a00-000000000001'
     and l2.id = 'b1a00002-0066-4a00-8a00-000000000002'
     and l3.id = 'b1a00003-0066-4a00-8a00-000000000003';
  if v_ax_txt is null or v_ay_txt is null then
    raise exception '0251 self-assert FAIL (G): a starter-port row is missing — the array pin cannot be built';
  end if;
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.reveal_starter_ports()')::oid;
  if v_src is null then
    raise exception '0251 self-assert FAIL (G): public.reveal_starter_ports() does not exist';
  end if;
  if position('array[' || v_ax_txt || ']' in v_src) = 0 or position('array[' || v_ay_txt || ']' in v_src) = 0 then
    raise exception '0251 self-assert FAIL (G): reveal_starter_ports() does not carry the normalized (×k) anchor coordinate arrays [%] / [%]', v_ax_txt, v_ay_txt;
  end if;
  if v_k > 1 and (position('array[-150, 210, 30]' in v_src) > 0 or position('array[-90, -30, 240]' in v_src) > 0) then
    raise exception '0251 self-assert FAIL (G): reveal_starter_ports() still carries a pre-normalize coordinate array — the re-create did not land';
  end if;
  if position('a.id = v_anchors[i]' in v_src) > 0 then
    raise exception '0251 self-assert FAIL (G): reveal_starter_ports() pins a fixed anchor-id literal — it cannot survive retire+insert relocation';
  end if;

  -- (H) get_world_map() BODY UNCHANGED (the read-cutover is PR-D, not this slice): the three
  --     status='active' filters + territory_radius intact, NO space_anchors read — the 0245 pins.
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.get_world_map()')::oid;
  if v_src is null then
    raise exception '0251 self-assert FAIL (H): public.get_world_map() does not exist';
  end if;
  if position('l.zone_id = z.id and l.status = ''active''' in v_src) = 0
     or position('z.sector_id = se.id and z.status = ''active''' in v_src) = 0
     or position('se.status = ''active''' in v_src) = 0
     or position('''territory_radius'', l.territory_radius' in v_src) = 0 then
    raise exception '0251 self-assert FAIL (H): get_world_map() body drifted from the 0217 head — this slice must not touch it';
  end if;
  if position('space_anchors' in v_src) > 0 then
    raise exception '0251 self-assert FAIL (H): get_world_map() reads space_anchors — the cutover is a LATER slice (PR-D), not this one';
  end if;

  -- (I) OUT-OF-SCOPE PRESERVED: mining_fields / exploration_sites byte-identical to the snapshot
  --     (already in the ±10000 frame — the disclosed interim seam; scaling them would double-apply).
  select count(*) into v_n
    from public.mining_fields f
    full join _v1c0251_pre_mining p on p.id = f.id
   where f.id is null or p.id is null
      or f.space_x is distinct from p.space_x or f.space_y is distinct from p.space_y;
  if v_n <> 0 then raise exception '0251 self-assert FAIL (I): mining_fields changed — out of scope, must be untouched'; end if;
  select count(*) into v_n
    from public.exploration_sites e
    full join _v1c0251_pre_exploration p on p.id = e.id
   where e.id is null or p.id is null
      or e.space_x is distinct from p.space_x or e.space_y is distinct from p.space_y;
  if v_n <> 0 then raise exception '0251 self-assert FAIL (I): exploration_sites changed — out of scope, must be untouched'; end if;

  -- (R) EXACT REVERSIBILITY — the /k round trip returns the snapshot pre-image BIT-FOR-BIT for every
  --     scalar coordinate (see the header contract: a world that cannot round-trip exactly ABORTS
  --     here rather than accept a lossy scale). Forward parity first (post == pre × k, the same IEEE
  --     product the UPDATEs computed), then the reverse division.
  select count(*) into v_n
    from public.locations l join _v1c0251_pre_locations p on p.id = l.id
   where l.x is distinct from p.x * v_k or l.y is distinct from p.y * v_k
      or l.territory_radius is distinct from p.territory_radius * v_k
      or (l.x / v_k) is distinct from p.x or (l.y / v_k) is distinct from p.y
      or (l.territory_radius / v_k) is distinct from p.territory_radius;
  if v_n <> 0 then raise exception '0251 self-assert FAIL (R): % location(s) failed the exact ×k / ÷k round trip', v_n; end if;
  select count(*) into v_n
    from public.sectors s join _v1c0251_pre_sectors p on p.id = s.id
   where s.x is distinct from p.x * v_k or s.y is distinct from p.y * v_k
      or (s.x / v_k) is distinct from p.x or (s.y / v_k) is distinct from p.y;
  if v_n <> 0 then raise exception '0251 self-assert FAIL (R): % sector(s) failed the exact round trip', v_n; end if;
  select count(*) into v_n
    from public.zones z join _v1c0251_pre_zones p on p.id = z.id
   where z.x is distinct from p.x * v_k or z.y is distinct from p.y * v_k
      or z.radius is distinct from p.radius * v_k
      or (z.x / v_k) is distinct from p.x or (z.y / v_k) is distinct from p.y
      or (z.radius / v_k) is distinct from p.radius;
  if v_n <> 0 then raise exception '0251 self-assert FAIL (R): % zone(s) failed the exact round trip', v_n; end if;
  -- danger polygons: forward bit-for-bit (ST_Scale performs the same coordinate×k product), reverse
  -- to 1e-9 tolerance (full-mantissa vertices — the documented float seam), ring lengths identical.
  select count(*) into v_n
    from public.danger_zones dz
    join _v1c0251_pre_danger p on p.id = dz.id
   where ST_NPoints(dz.boundary) <> ST_NPoints(p.boundary)
      or not ST_OrderingEquals(dz.boundary, ST_Scale(p.boundary, v_k::double precision, v_k::double precision));
  if v_n <> 0 then raise exception '0251 self-assert FAIL (R): % danger zone(s) differ from ST_Scale(pre, k, k)', v_n; end if;
  select count(*) into v_n
    from public.danger_zones dz
    join _v1c0251_pre_danger p on p.id = dz.id,
         generate_series(1, ST_NPoints(ST_ExteriorRing(dz.boundary))) g(n)
   where abs(ST_X(ST_PointN(ST_ExteriorRing(dz.boundary), g.n)) / v_k
             - ST_X(ST_PointN(ST_ExteriorRing(p.boundary), g.n))) > 1e-9
      or abs(ST_Y(ST_PointN(ST_ExteriorRing(dz.boundary), g.n)) / v_k
             - ST_Y(ST_PointN(ST_ExteriorRing(p.boundary), g.n))) > 1e-9;
  if v_n <> 0 then raise exception '0251 self-assert FAIL (R): % danger-zone vertex(es) failed the ÷k round trip beyond 1e-9', v_n; end if;
  -- in-flight scalar round trip for the scaled endpoints.
  select count(*) into v_n
    from public.fleet_movements m join _v1c0251_pre_moves p on p.id = m.id
   where m.status = 'moving'
     and ((m.target_type in ('location', 'zone') and ((m.target_x / v_k) is distinct from p.target_x or (m.target_y / v_k) is distinct from p.target_y))
       or (m.origin_type in ('location', 'zone') and ((m.origin_x / v_k) is distinct from p.origin_x or (m.origin_y / v_k) is distinct from p.origin_y)));
  if v_n <> 0 then raise exception '0251 self-assert FAIL (R): % in-flight leg(s) failed the exact ÷k round trip', v_n; end if;

  select count(*) into v_n2 from public.danger_zones;
  raise notice '0251 self-assert ok: k=% — % location(s) + anchors (anchor==location exact, no dup-actives), % sector(s)/% zone(s) scaled, % danger zone(s) ST_Scaled (circle-center containment intact), % in-flight leg(s) reconciled, distances ×k + bearings preserved pair-wide, territory overlap-signs preserved + disjoint, reveal_starter_ports re-created ×k, get_world_map body untouched, mining/exploration untouched, EXACT ÷k reversibility proven',
    v_k, v_locations,
    (select count(*) from public.sectors), (select count(*) from public.zones),
    v_n2, v_moving;
end $v1c9$;
