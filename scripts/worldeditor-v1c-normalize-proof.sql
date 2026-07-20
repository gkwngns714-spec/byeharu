-- WORLD-EDITOR V1C NORMALIZE (PR-C) — disposable apply-proof (run against a THROWAWAY local
-- Supabase ONLY — the seeded migration chain; NEVER production).
--
-- Proves migration 0251 (20260618000251_worldeditor_v1c_normalize.sql) after `supabase start`
-- applied the FULL chain (0251's own in-migration parity envelope already ran — any failure there
-- turns `supabase start` red before this script even runs). This proof independently re-verifies the
-- DEPLOYED post-normalize world:
--   1  K_IN_BOUNDS                  — the applied scale k is a positive INTEGER, re-derivable from
--                                     the chain's known pre-image, equal to floor(8500 / M) for the
--                                     reconstructed extent M, with M·k < 10000;
--   2  ANCHOR_EQUALS_LOCATION       — every location has exactly ONE active anchor at EXACTLY its
--                                     post-scale (x, y) (count-matched, bijective, no dup-actives);
--   3  ENVELOPE                     — nothing scaled (locations+rings, sectors, zones+radius,
--                                     anchors, every danger-zone vertex) exceeds ±10000;
--   4  RELATIVE_GEOMETRY_PRESERVED  — the 3 starter ports sit EXACTLY at the 0227 chain pre-image
--                                     × k, and every location pair keeps distance ×k + bearing;
--   5  TERRITORY_DISJOINT           — 0227's disjointness sweeps re-run on the post-scale world;
--   6  DANGER_CONTAINS_CENTER       — every source='circle' danger zone still contains its
--                                     location's new center (ST_Scale preserved the 0237 slimes);
--   7  INFLIGHT_RECONCILED          — real-table coherence (every moving location-bound leg matches
--                                     its location exactly; zero rows is a legitimate pass) PLUS a
--                                     seeded REPLAY of the 0251 §7 reconcile idiom on a synthetic
--                                     pre-image leg (non-vacuous by construction);
--   8  REVEAL_PORTS_STRUCTURAL      — reveal_starter_ports() carries the ×k arrays (not the old
--                                     ones), no anchor-id pin, service_role-only exposure;
--   9  GET_WORLD_MAP_UNCHANGED      — signature/body/grants byte-stable at the 0217 head, still NO
--                                     space_anchors read (the cutover is PR-D);
--  10  REVERSIBLE                   — dividing the deployed world by k reconstructs the pre-image
--                                     and re-multiplying by k returns the deployed world BIT-FOR-BIT
--                                     for every scalar coordinate (danger-zone polygon vertices are
--                                     full-mantissa doubles — their round trip is pinned to 1e-9,
--                                     the documented float seam).
--
-- CHAIN-PINNED PRE-IMAGE: this proof runs on the deterministic seeded chain, where the starter
-- ports' pre-0251 coordinates are the 0227 literals (-150,-90) / (210,-30) / (30,240) — k is
-- re-derived from them, never read from the migration. Self-rolling-back: one begin;…rollback;,
-- ZERO persisted state. NEVER point this at production.

\set ON_ERROR_STOP on

begin;

create temporary table _pf_k (k integer not null) on commit drop;

-- ── PROOF 1 — K_IN_BOUNDS: k is a positive integer, consistent across the pre-image pins, and
--    exactly floor((10000·0.85)/M) for the reconstructed extent M, with M·k < 10000. ───────────────
do $$
declare
  v_kf     double precision;
  v_k      integer;
  v_mpost  double precision;
  v_m0     double precision;
begin
  select x / (-150.0) into v_kf from public.locations
   where id = 'b1a00001-0066-4a00-8a00-000000000001';
  if v_kf is null then
    raise exception 'V1C-NORM PROOF FAIL: Haven Reach (chain pre-image (-150,-90)) not found';
  end if;
  if v_kf < 1 or v_kf <> floor(v_kf) then
    raise exception 'V1C-NORM PROOF FAIL: derived scale % is not a positive integer', v_kf;
  end if;
  v_k := v_kf::integer;
  -- the SAME k on the y axis and on a second port — one uniform constant, not per-axis/per-row.
  if (select y from public.locations where id = 'b1a00001-0066-4a00-8a00-000000000001') <> -90 * v_k
     or (select x from public.locations where id = 'b1a00002-0066-4a00-8a00-000000000002') <> 210 * v_k
     or (select y from public.locations where id = 'b1a00003-0066-4a00-8a00-000000000003') <> 240 * v_k then
    raise exception 'V1C-NORM PROOF FAIL: k=% is not the one uniform scale across ports/axes', v_k;
  end if;

  -- reconstruct the pre-image extent M = M_post / k over EVERY class 0251 folded into M, and re-prove
  -- the k formula: k = floor(8500 / M), M·k < 10000.
  select greatest(
    (select coalesce(max(greatest(abs(x), abs(y),
                                  abs(x) + coalesce(territory_radius, 0)::double precision,
                                  abs(y) + coalesce(territory_radius, 0)::double precision)), 0) from public.locations),
    (select coalesce(max(greatest(abs(x), abs(y))), 0) from public.sectors),
    (select coalesce(max(greatest(abs(x), abs(y), abs(x) + radius, abs(y) + radius)), 0) from public.zones),
    (select coalesce(max(greatest(abs(ST_XMin(boundary)), abs(ST_XMax(boundary)),
                                  abs(ST_YMin(boundary)), abs(ST_YMax(boundary)))), 0) from public.danger_zones))
    into v_mpost;
  if v_mpost <= 0 then
    raise exception 'V1C-NORM PROOF FAIL: degenerate post-scale extent %', v_mpost;
  end if;
  v_m0 := v_mpost / v_k;
  if v_k <> floor((10000 * 0.85) / v_m0)::integer then
    raise exception 'V1C-NORM PROOF FAIL: k=% but floor(8500/M)=% for reconstructed M=%', v_k, floor((10000 * 0.85) / v_m0)::integer, v_m0;
  end if;
  if v_m0 * v_k >= 10000 then
    raise exception 'V1C-NORM PROOF FAIL: M·k = % breaches the ±10000 envelope', v_m0 * v_k;
  end if;

  insert into _pf_k (k) values (v_k);
  raise notice 'V1C-NORM proof: k = %, reconstructed pre-image extent M = %, M*k = %', v_k, v_m0, v_m0 * v_k;
  raise notice 'V1C_NORM_PASS_K_IN_BOUNDS';
end $$;

-- reconstructed pre-image (÷k) — the REVERSIBLE / relative-geometry reference frame.
create temporary table _pf_rec_locations on commit drop as
  select l.id, l.x / p.k as x, l.y / p.k as y, l.territory_radius / p.k as territory_radius
    from public.locations l, _pf_k p;
create temporary table _pf_rec_sectors on commit drop as
  select s.id, s.x / p.k as x, s.y / p.k as y from public.sectors s, _pf_k p;
create temporary table _pf_rec_zones on commit drop as
  select z.id, z.x / p.k as x, z.y / p.k as y, z.radius / p.k as radius from public.zones z, _pf_k p;

-- ── PROOF 2 — ANCHOR_EQUALS_LOCATION: bijective, exact, no dup-actives, non-vacuous (>3, the 0245
--    floor: equality above the 3 seeded port anchors proves the world-wide invariant, not a relic). ─
do $$
declare v_locations int; v_anchors int; v_n int;
begin
  select count(*) into v_locations from public.locations;
  select count(*) into v_anchors from public.space_anchors where kind = 'location' and status = 'active';
  if v_locations <= 3 then
    raise exception 'V1C-NORM PROOF FAIL: only % location(s) — the sweep would be vacuous', v_locations;
  end if;
  if v_anchors <> v_locations then
    raise exception 'V1C-NORM PROOF FAIL: % active location anchor(s) for % location(s)', v_anchors, v_locations;
  end if;
  if exists (select 1 from public.locations l
              where not exists (select 1 from public.space_anchors a
                                 where a.location_id = l.id and a.kind = 'location' and a.status = 'active')) then
    raise exception 'V1C-NORM PROOF FAIL: a location has no active anchor despite matching counts';
  end if;
  select count(*) into v_n
    from public.space_anchors a
    join public.locations l on l.id = a.location_id
   where a.kind = 'location' and a.status = 'active'
     and (a.space_x is distinct from l.x or a.space_y is distinct from l.y);
  if v_n <> 0 then
    raise exception 'V1C-NORM PROOF FAIL: % active anchor(s) differ from their location''s exact post-scale (x,y)', v_n;
  end if;
  select count(*) into v_n
    from (select location_id from public.space_anchors
           where kind = 'location' and status = 'active'
           group by location_id having count(*) > 1) dup;
  if v_n <> 0 then
    raise exception 'V1C-NORM PROOF FAIL: % location(s) with more than one active anchor', v_n;
  end if;
  raise notice 'V1C_NORM_PASS_ANCHOR_EQUALS_LOCATION';
end $$;

-- ── PROOF 3 — ENVELOPE: nothing scaled exceeds ±10000 (ring/radius extents and every polygon
--    vertex included). ──────────────────────────────────────────────────────────────────────────────
do $$
declare v_n int;
begin
  select count(*) into v_n from public.locations
   where greatest(abs(x), abs(y),
                  abs(x) + coalesce(territory_radius, 0)::double precision,
                  abs(y) + coalesce(territory_radius, 0)::double precision) > 10000;
  if v_n <> 0 then raise exception 'V1C-NORM PROOF FAIL: % location(s)/ring(s) outside ±10000', v_n; end if;
  select count(*) into v_n from public.sectors where greatest(abs(x), abs(y)) > 10000;
  if v_n <> 0 then raise exception 'V1C-NORM PROOF FAIL: % sector(s) outside ±10000', v_n; end if;
  select count(*) into v_n from public.zones
   where greatest(abs(x), abs(y), abs(x) + radius, abs(y) + radius) > 10000;
  if v_n <> 0 then raise exception 'V1C-NORM PROOF FAIL: % zone(s) outside ±10000', v_n; end if;
  select count(*) into v_n from public.space_anchors
   where status = 'active' and greatest(abs(space_x), abs(space_y)) > 10000;
  if v_n <> 0 then raise exception 'V1C-NORM PROOF FAIL: % anchor(s) outside ±10000', v_n; end if;
  select count(*) into v_n from public.danger_zones
   where greatest(abs(ST_XMin(boundary)), abs(ST_XMax(boundary)),
                  abs(ST_YMin(boundary)), abs(ST_YMax(boundary))) > 10000;
  if v_n <> 0 then raise exception 'V1C-NORM PROOF FAIL: % danger zone(s) outside ±10000', v_n; end if;
  raise notice 'V1C_NORM_PASS_ENVELOPE';
end $$;

-- ── PROOF 4 — RELATIVE_GEOMETRY_PRESERVED: (a) the chain-pinned pre-image spot-check — the three
--    starter ports sit EXACTLY at the 0227 coordinates × k (proves 0251 scaled the REAL historical
--    frame, not an arbitrary similar one); (b) every location pair keeps distance ×k (float
--    tolerance) and bearing (a uniform positive scale is a similarity transform). ──────────────────
do $$
declare v_k int; v_n int;
begin
  select k into v_k from _pf_k;
  if (select count(*) from public.locations
       where (id = 'b1a00001-0066-4a00-8a00-000000000001' and x = -150 * v_k and y = -90 * v_k)
          or (id = 'b1a00002-0066-4a00-8a00-000000000002' and x =  210 * v_k and y = -30 * v_k)
          or (id = 'b1a00003-0066-4a00-8a00-000000000003' and x =   30 * v_k and y = 240 * v_k)) <> 3 then
    raise exception 'V1C-NORM PROOF FAIL: a starter port is not at its 0227 pre-image × k';
  end if;
  select count(*) into v_n
    from public.locations a
    join public.locations b on a.id < b.id
    join _pf_rec_locations ra on ra.id = a.id
    join _pf_rec_locations rb on rb.id = b.id
   where abs(public.osn_distance(a.x, a.y, b.x, b.y)
             - v_k * public.osn_distance(ra.x, ra.y, rb.x, rb.y))
         > 1e-6 * greatest(v_k * public.osn_distance(ra.x, ra.y, rb.x, rb.y), 1.0);
  if v_n <> 0 then
    raise exception 'V1C-NORM PROOF FAIL: % pair(s) broke distance-×k parity', v_n;
  end if;
  select count(*) into v_n
    from public.locations a
    join public.locations b on a.id < b.id
    join _pf_rec_locations ra on ra.id = a.id
    join _pf_rec_locations rb on rb.id = b.id
   where (ra.x, ra.y) is distinct from (rb.x, rb.y)
     and abs(atan2(b.y - a.y, b.x - a.x) - atan2(rb.y - ra.y, rb.x - ra.x)) > 1e-9;
  if v_n <> 0 then
    raise exception 'V1C-NORM PROOF FAIL: % pair(s) changed bearing — the scale is not uniform', v_n;
  end if;
  raise notice 'V1C_NORM_PASS_RELATIVE_GEOMETRY_PRESERVED';
end $$;

-- ── PROOF 5 — TERRITORY_DISJOINT: 0227's sweeps re-run verbatim on the deployed post-scale world
--    (non-vacuous: territory-bearing rows must exist). ──────────────────────────────────────────────
do $$
declare v_n int;
begin
  select count(*) into v_n from public.locations where territory_radius is not null;
  if v_n = 0 then raise exception 'V1C-NORM PROOF FAIL: no territory-bearing locations — sweep vacuous'; end if;
  select count(*) into v_n
    from public.locations a
    join public.locations b on a.id < b.id
   where a.territory_radius is not null and b.territory_radius is not null
     and public.osn_distance(a.x, a.y, b.x, b.y) <= (a.territory_radius + b.territory_radius);
  if v_n <> 0 then raise exception 'V1C-NORM PROOF FAIL: % overlapping territory pair(s)', v_n; end if;
  select count(*) into v_n
    from public.locations a
    join public.locations b on a.id <> b.id
   where a.territory_radius is not null and b.territory_radius is not null
     and public.osn_distance(a.x, a.y, b.x, b.y) <= a.territory_radius;
  if v_n <> 0 then raise exception 'V1C-NORM PROOF FAIL: % ring(s) reach another center', v_n; end if;
  raise notice 'V1C_NORM_PASS_TERRITORY_DISJOINT';
end $$;

-- ── PROOF 6 — DANGER_CONTAINS_CENTER: every source='circle' zone (the 0237 slimes) still contains
--    its location's new center, and the class is non-vacuous. ────────────────────────────────────────
do $$
declare v_total int; v_n int;
begin
  select count(*) into v_total from public.danger_zones where source = 'circle';
  if v_total = 0 then raise exception 'V1C-NORM PROOF FAIL: no circle danger zones — containment sweep vacuous'; end if;
  select count(*) into v_n
    from public.danger_zones dz
    join public.locations l on l.id = dz.location_id
   where dz.source = 'circle'
     and not ST_Contains(dz.boundary, ST_MakePoint(l.x, l.y));
  if v_n <> 0 then
    raise exception 'V1C-NORM PROOF FAIL: %/% circle zone(s) no longer contain their center', v_n, v_total;
  end if;
  raise notice 'V1C_NORM_PASS_DANGER_CONTAINS_CENTER';
end $$;

-- ── PROOF 7 — INFLIGHT_RECONCILED: (a) real-table coherence — every MOVING location-bound leg's
--    frozen snapshot equals its target/origin location's live post-scale coordinate (count-equality,
--    the 0227 (F) idiom; ZERO in-flight rows is a legitimate pass on the seeded chain); (b) REPLAY —
--    seed a synthetic pre-image leg and run the EXACT 0251 §7 reconcile expression, proving the
--    idiom itself non-vacuously. ────────────────────────────────────────────────────────────────────
do $$
declare v_k int; v_moving int; v_ok int; v_hx double precision; v_hy double precision;
        v_rx double precision; v_ry double precision;
begin
  select k into v_k from _pf_k;

  -- (a) real table: a moving location-targeted row must match EXACTLY its target location's live
  -- coordinate (INNER join — a row whose location vanished fails the equality-of-counts).
  select count(*) into v_moving
    from public.fleet_movements where status = 'moving' and target_type = 'location';
  select count(*) into v_ok
    from public.fleet_movements m
    join public.locations l on l.id = m.target_location_id
   where m.status = 'moving' and m.target_type = 'location'
     and m.target_x = l.x and m.target_y = l.y;
  if v_ok <> v_moving then
    raise exception 'V1C-NORM PROOF FAIL: only %/% moving location-targeted leg(s) match their location''s live coordinate', v_ok, v_moving;
  end if;

  -- (b) replay: a synthetic pre-image leg to Haven Reach (rec coords), reconciled by the 0251 §7
  -- expression, must land bit-for-bit on the deployed post-scale coordinate.
  select x, y into v_hx, v_hy from public.locations where id = 'b1a00001-0066-4a00-8a00-000000000001';
  create temporary table _pf_replay (origin_type text, origin_x double precision, origin_y double precision,
                                     target_type text, target_x double precision, target_y double precision,
                                     status text) on commit drop;
  insert into _pf_replay values ('base', 0, 0, 'location', v_hx / v_k, v_hy / v_k, 'moving');
  update _pf_replay
     set target_x = target_x * v_k, target_y = target_y * v_k
   where status = 'moving' and target_type in ('location', 'zone');
  update _pf_replay
     set origin_x = origin_x * v_k, origin_y = origin_y * v_k
   where status = 'moving' and origin_type in ('location', 'zone');
  select target_x, target_y into v_rx, v_ry from _pf_replay;
  if v_rx is distinct from v_hx or v_ry is distinct from v_hy then
    raise exception 'V1C-NORM PROOF FAIL: replayed reconcile landed at (%, %) — expected (%, %)', v_rx, v_ry, v_hx, v_hy;
  end if;
  if (select origin_x from _pf_replay) <> 0 or (select origin_y from _pf_replay) <> 0 then
    raise exception 'V1C-NORM PROOF FAIL: replayed reconcile touched a base-origin coordinate — out of scope';
  end if;
  raise notice 'V1C_NORM_PASS_INFLIGHT_RECONCILED';
end $$;

-- ── PROOF 8 — REVEAL_PORTS_STRUCTURAL: the deployed function body carries the ×k arrays (built from
--    the live post-scale port rows), NOT the pre-normalize arrays, no anchor-id pin; service_role-
--    only exposure intact. Structural — never invoked (a live reveal is an operator action). ────────
do $$
declare v_k int; v_src text; v_ax_txt text; v_ay_txt text;
begin
  select k into v_k from _pf_k;
  select l1.x::text || ', ' || l2.x::text || ', ' || l3.x::text,
         l1.y::text || ', ' || l2.y::text || ', ' || l3.y::text
    into v_ax_txt, v_ay_txt
    from public.locations l1, public.locations l2, public.locations l3
   where l1.id = 'b1a00001-0066-4a00-8a00-000000000001'
     and l2.id = 'b1a00002-0066-4a00-8a00-000000000002'
     and l3.id = 'b1a00003-0066-4a00-8a00-000000000003';
  if v_ax_txt is null or v_ay_txt is null then
    raise exception 'V1C-NORM PROOF FAIL: a starter-port row is missing — the array pin cannot be built';
  end if;
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.reveal_starter_ports()')::oid;
  if v_src is null then
    raise exception 'V1C-NORM PROOF FAIL: public.reveal_starter_ports() does not exist';
  end if;
  if position('array[' || v_ax_txt || ']' in v_src) = 0 or position('array[' || v_ay_txt || ']' in v_src) = 0 then
    raise exception 'V1C-NORM PROOF FAIL: reveal_starter_ports() lacks the ×k arrays [%] / [%]', v_ax_txt, v_ay_txt;
  end if;
  if v_k <= 1 then
    raise exception 'V1C-NORM PROOF FAIL: k=% on this chain — the old-array-absent check would be meaningless', v_k;
  end if;
  if position('array[-150, 210, 30]' in v_src) > 0 or position('array[-90, -30, 240]' in v_src) > 0 then
    raise exception 'V1C-NORM PROOF FAIL: reveal_starter_ports() still carries a pre-normalize coordinate array';
  end if;
  if position('a.id = v_anchors[i]' in v_src) > 0 then
    raise exception 'V1C-NORM PROOF FAIL: reveal_starter_ports() pins a fixed anchor-id literal';
  end if;
  if has_function_privilege('anon', 'public.reveal_starter_ports()', 'execute')
     or has_function_privilege('authenticated', 'public.reveal_starter_ports()', 'execute')
     or not has_function_privilege('service_role', 'public.reveal_starter_ports()', 'execute') then
    raise exception 'V1C-NORM PROOF FAIL: reveal_starter_ports() exposure drifted from service_role-only';
  end if;
  raise notice 'V1C_NORM_PASS_REVEAL_PORTS_STRUCTURAL';
end $$;

-- ── PROOF 9 — GET_WORLD_MAP_UNCHANGED: signature, hidden-invisibility body pins, territory field,
--    NO space_anchors read, client grants — the 0217/0245 head, byte-stable through 0251. ───────────
do $$
declare v_src text;
begin
  if to_regprocedure('public.get_world_map()') is null then
    raise exception 'V1C-NORM PROOF FAIL: public.get_world_map() does not exist';
  end if;
  select p.prosrc into v_src from pg_proc p where p.oid = to_regprocedure('public.get_world_map()')::oid;
  if (select pg_get_function_identity_arguments(to_regprocedure('public.get_world_map()')::oid)) <> '' then
    raise exception 'V1C-NORM PROOF FAIL: get_world_map() signature gained arguments';
  end if;
  if (select t.typname from pg_proc p join pg_type t on t.oid = p.prorettype
       where p.oid = to_regprocedure('public.get_world_map()')::oid) <> 'jsonb' then
    raise exception 'V1C-NORM PROOF FAIL: get_world_map() no longer returns jsonb';
  end if;
  if (select l.lanname from pg_proc p join pg_language l on l.oid = p.prolang
       where p.oid = to_regprocedure('public.get_world_map()')::oid) <> 'sql'
     or (select p.provolatile from pg_proc p
          where p.oid = to_regprocedure('public.get_world_map()')::oid) <> 's'
     or (select p.prosecdef from pg_proc p
          where p.oid = to_regprocedure('public.get_world_map()')::oid) then
    raise exception 'V1C-NORM PROOF FAIL: get_world_map() language/volatility/security changed';
  end if;
  if position('l.zone_id = z.id and l.status = ''active''' in v_src) = 0
     or position('z.sector_id = se.id and z.status = ''active''' in v_src) = 0
     or position('se.status = ''active''' in v_src) = 0
     or position('''territory_radius'', l.territory_radius' in v_src) = 0 then
    raise exception 'V1C-NORM PROOF FAIL: get_world_map() body drifted from the 0217 head';
  end if;
  if position('space_anchors' in v_src) > 0 then
    raise exception 'V1C-NORM PROOF FAIL: get_world_map() reads space_anchors — the cutover must be PR-D';
  end if;
  if not has_function_privilege('anon', 'public.get_world_map()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_world_map()', 'execute') then
    raise exception 'V1C-NORM PROOF FAIL: get_world_map() lost a client execute grant';
  end if;
  raise notice 'V1C_NORM_PASS_GET_WORLD_MAP_UNCHANGED';
end $$;

-- ── PROOF 10 — REVERSIBLE: ÷k reconstructs the pre-image and ×k returns the deployed world
--    BIT-FOR-BIT for every scalar coordinate (locations incl. territory_radius, sectors, zones incl.
--    radius, active anchors). Danger-zone polygon vertices (full-mantissa doubles by 0237's random
--    construction) round-trip within 1e-9 — the documented float seam. On the integer world grid the
--    scalar round trip is EXACT: x·k is an exact double product and the true quotient is
--    representable, so /k recovers the pre-image with zero loss. ────────────────────────────────────
do $$
declare v_k int; v_n int;
begin
  select k into v_k from _pf_k;
  select count(*) into v_n
    from public.locations l join _pf_rec_locations r on r.id = l.id
   where l.x is distinct from r.x * v_k or l.y is distinct from r.y * v_k
      or l.territory_radius is distinct from r.territory_radius * v_k;
  if v_n <> 0 then raise exception 'V1C-NORM PROOF FAIL: % location(s) failed the exact ÷k→×k round trip', v_n; end if;
  select count(*) into v_n
    from public.sectors s join _pf_rec_sectors r on r.id = s.id
   where s.x is distinct from r.x * v_k or s.y is distinct from r.y * v_k;
  if v_n <> 0 then raise exception 'V1C-NORM PROOF FAIL: % sector(s) failed the round trip', v_n; end if;
  select count(*) into v_n
    from public.zones z join _pf_rec_zones r on r.id = z.id
   where z.x is distinct from r.x * v_k or z.y is distinct from r.y * v_k
      or z.radius is distinct from r.radius * v_k;
  if v_n <> 0 then raise exception 'V1C-NORM PROOF FAIL: % zone(s) failed the round trip', v_n; end if;
  select count(*) into v_n
    from public.space_anchors a join _pf_rec_locations r on r.id = a.location_id
   where a.kind = 'location' and a.status = 'active'
     and (a.space_x is distinct from r.x * v_k or a.space_y is distinct from r.y * v_k);
  if v_n <> 0 then raise exception 'V1C-NORM PROOF FAIL: % anchor(s) failed the round trip', v_n; end if;
  select count(*) into v_n
    from public.danger_zones dz,
         generate_series(1, ST_NPoints(ST_ExteriorRing(dz.boundary))) g(n)
   where abs((ST_X(ST_PointN(ST_ExteriorRing(dz.boundary), g.n)) / v_k) * v_k
             - ST_X(ST_PointN(ST_ExteriorRing(dz.boundary), g.n))) > 1e-9
      or abs((ST_Y(ST_PointN(ST_ExteriorRing(dz.boundary), g.n)) / v_k) * v_k
             - ST_Y(ST_PointN(ST_ExteriorRing(dz.boundary), g.n))) > 1e-9;
  if v_n <> 0 then raise exception 'V1C-NORM PROOF FAIL: % danger-zone vertex(es) failed the ÷k→×k round trip beyond 1e-9', v_n; end if;
  raise notice 'V1C_NORM_PASS_REVERSIBLE';
end $$;

do $$ begin raise notice 'WORLD-EDITOR V1C NORMALIZE PROOF PASSED'; end $$;

rollback;   -- leave ZERO persisted state.
