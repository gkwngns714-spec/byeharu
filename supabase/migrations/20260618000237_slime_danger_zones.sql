-- Byeharu — SLIME DANGER ZONES: reshape the auto-seeded circle zones into IRREGULAR organic blobs.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE OWNER'S ASK (repeated, still unmet before this slice): danger zones must be able to be "any
-- shape I decide" / "slime-like", NOT perfect circles. Today the live pirate danger zones
-- (Reaver / Snare / Blackden) are the source='circle' rows 0233 auto-seeded via
-- ST_Buffer(location point, territory_radius) — geometrically exact circles. The arbitrary-polygon
-- machinery already exists end to end (0233): danger_zones.boundary is a PostGIS geometry(Polygon),
-- pirate_zone_create() saves owner-drawn rings, and pirate_intercept_leg_zone_hits /
-- pirate_intercept_evaluate_leg intersect a movement leg against ANY polygon boundary via
-- ST_Intersection — convex, concave, blobby, all handled. The ONLY thing still circular is the SEED.
--
-- WHAT THIS MIGRATION DOES (and nothing else): rewrites boundary for every source='circle' zone from
-- a perfect ST_Buffer circle to an ORGANIC, irregular "slime" polygon centred on the SAME location
-- x/y, wobbling around the SAME territory_radius. Nothing else changes: locations.territory_radius,
-- get_world_map, fleet_in_territory, the client territory ring, the 0233 seed function for FUTURE
-- locations, the intercept geometry / risk formula, and every RLS policy are all UNTOUCHED. This is a
-- pure geometry reshape of three existing data rows — a parallel polygon read repointed to a nicer
-- shape, not a schema, RPC, flag, or cron change.
--
-- LIVE, NOT DARK — SAFETY POSTURE: these zones are live (pirate_intercept_enabled is true in prod),
-- so this migration DOES change what players see and how a leg intersects the zone. It is made safe
-- by construction: the new shapes stay in the SAME world domain (centre = the location's own x/y,
-- radius wobbles 0.6×–1.5× the SAME territory_radius the circle used), so a zone never teleports or
-- explodes in scale — it just gets bumpy at roughly the footprint it already had. It is
-- reversible-in-spirit: a follow-up migration can reshape again (or ST_Buffer back to a circle) with
-- the identical UPDATE-by-source pattern; no shape is load-bearing, only "valid + irregular" is.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SHAPE GENERATION (why it is always a VALID simple polygon, never a self-intersecting mess):
--   • Per zone we emit N ∈ [12, 24] vertices at angles that sweep monotonically ONCE around the
--     centre. Vertex i sits at base angle i·(2π/N) plus a bounded jitter of ±0.4·step. Because the
--     jitter magnitude is < half the step, consecutive angles stay STRICTLY increasing, so the ring
--     is "star-shaped" about the centre — and a star-shaped ring with strictly ordered angles and
--     positive radii is GUARANTEED simple (no self-intersection). This is the structural guarantee;
--     ST_IsValid below is the belt-and-suspenders proof, not the primary defence.
--   • Radius per vertex = territory_radius · uniform(0.6, 1.5) · (1 + 0.18·sin(lobes·θ + phase)),
--     with lobes ∈ [3, 6] and a random phase. The random uniform factor makes the blob organic; the
--     deterministic multi-lobe sine guarantees the radius genuinely VARIES across vertices (distinct
--     θ → distinct sine), so "radius variance > 0" (non-circular) holds structurally, not by luck.
--   • The ring is closed by repeating vertex 1; ST_MakePolygon(ST_MakeLine(pts)) builds it. If the
--     (astronomically unlikely) result is not valid, ST_MakeValid + ST_CollectionExtract(...,3)
--     repairs to a polygon; if even that fails we RAISE and the whole migration aborts (nothing
--     half-applies). Geometries carry NO SRID — a flat game grid, matching every 0233 geometry.
--
-- DETERMINISM NOTE (CI applies this to a disposable Postgres too): random() makes the exact shape
-- differ per apply, BUT it is ALWAYS valid and ALWAYS non-circular by the construction above. The
-- self-assert therefore pins INVARIANTS (valid polygon, >8 vertices, radius variance > 0) — never
-- exact coordinates.
--
-- IDEMPOTENT: re-running reshapes the same source='circle' rows to a fresh (still valid, still
-- irregular) blob and converges to the same invariant state; it never errors on re-apply and never
-- touches drawn or standalone zones.

-- ── 0. dependency gate ───────────────────────────────────────────────────────────────────────────
do $slime0$
begin
  if to_regclass('public.danger_zones') is null then
    raise exception 'SLIME-ZONES: public.danger_zones (0233) is missing — this slice reshapes its circle seeds';
  end if;
  if to_regprocedure('public.st_makepolygon(geometry)') is null then
    raise exception 'SLIME-ZONES: PostGIS (0233 installs it) is missing — ST_MakePolygon unavailable';
  end if;
end $slime0$;

-- ── 1. reshape every source='circle' zone into an irregular organic slime polygon ─────────────────
do $slime1$
declare
  z        record;
  v_n      integer;
  v_i      integer;
  v_step   double precision;
  v_theta  double precision;
  v_r      double precision;
  v_lobes  double precision;
  v_phase  double precision;
  v_pts    geometry[];
  v_poly   geometry;
begin
  for z in
    select dz.id, l.x as cx, l.y as cy, l.territory_radius as base
      from public.danger_zones dz
      join public.locations l on l.id = dz.location_id
     where dz.source = 'circle'
       and l.territory_radius is not null
       and l.territory_radius > 0
  loop
    v_n     := 12 + floor(random() * 13)::int;          -- 12..24 vertices
    v_step  := 2 * pi() / v_n;
    v_lobes := 3 + floor(random() * 4)::int;            -- 3..6 organic lobes
    v_phase := random() * 2 * pi();
    v_pts   := array[]::geometry[];

    for v_i in 0 .. v_n - 1 loop
      -- angle: monotonic sweep + bounded jitter (< half a step => strictly increasing => simple ring)
      v_theta := v_i * v_step + (random() - 0.5) * 0.8 * v_step;
      -- radius: wobble 0.6x..1.5x of territory_radius, modulated by a deterministic multi-lobe sine
      v_r := z.base
             * (0.6 + random() * 0.9)
             * (1 + 0.18 * sin(v_lobes * v_theta + v_phase));
      v_pts := v_pts || ST_MakePoint(z.cx + v_r * cos(v_theta), z.cy + v_r * sin(v_theta));
    end loop;
    v_pts := v_pts || v_pts[1];                          -- close the ring

    v_poly := ST_MakePolygon(ST_MakeLine(v_pts));
    if v_poly is null or not ST_IsValid(v_poly) then
      -- belt-and-suspenders repair (dead path given the star-shaped construction above):
      -- ST_CollectionExtract(...,3) yields a MultiPolygon; take its first ring as a plain Polygon.
      v_poly := ST_GeometryN(ST_CollectionExtract(ST_MakeValid(v_poly), 3), 1);
    end if;
    if v_poly is null or not ST_IsValid(v_poly) or ST_GeometryType(v_poly) <> 'ST_Polygon' then
      raise exception 'SLIME-ZONES: could not build a valid polygon for zone % (n=%, base=%)', z.id, v_n, z.base;
    end if;

    update public.danger_zones
       set boundary   = v_poly::geometry(Polygon),
           updated_at = now()
     where id = z.id;
  end loop;
end $slime1$;

-- ── 2. self-assert (deploy-time; a raise aborts the migration txn — nothing half-applies) ──────────
-- Pins INVARIANTS, not coordinates (random shapes differ per apply): every circle zone is now a
-- valid polygon with > 8 distinct vertices (ring NPoints > 9) and a strictly positive vertex-radius
-- variance (i.e. demonstrably NOT a circle).
do $slime2$
declare
  v_total integer;
  v_bad   integer;
begin
  select count(*) into v_total from public.danger_zones where source = 'circle';
  if v_total < 1 then
    raise exception 'SLIME-ZONES self-assert FAIL: no source=circle zones to reshape — the seed sweep is vacuous (0233 did not seed)';
  end if;

  with pts as (
    select dz.id,
           ST_NPoints(dz.boundary)                                        as npts,
           ST_IsValid(dz.boundary)                                        as valid,
           ST_GeometryType(dz.boundary)                                   as gtype,
           ST_Distance((ST_DumpPoints(dz.boundary)).geom,
                       ST_Centroid(dz.boundary))                          as vradius
      from public.danger_zones dz
     where dz.source = 'circle'
  ),
  agg as (
    select id,
           bool_and(valid)          as valid,
           min(npts)                as npts,
           bool_and(gtype = 'ST_Polygon') as is_polygon,
           coalesce(stddev(vradius), 0) as rvar
      from pts
     group by id
  )
  select count(*) into v_bad
    from agg
   where not valid
      or not is_polygon
      or npts <= 9            -- ring has N+1 points; > 8 distinct vertices <=> NPoints > 9
      or rvar <= 0;           -- zero radius variance would mean a perfect circle/regular polygon

  if v_bad > 0 then
    raise exception 'SLIME-ZONES self-assert FAIL: % of % circle zone(s) are not valid irregular polygons (need valid ST_Polygon, >8 vertices, radius variance > 0)', v_bad, v_total;
  end if;

  raise notice 'SLIME-ZONES self-assert ok: % circle zone(s) reshaped to valid, non-circular (>8 vertices, radius-variance>0) organic slime polygons', v_total;
end $slime2$;
