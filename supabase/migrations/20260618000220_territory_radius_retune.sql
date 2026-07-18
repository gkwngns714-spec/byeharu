-- Byeharu — TERRITORY RETUNE (cross-slice audit fix): overlap-free territory radii sized to the
-- REAL map geometry. Additive data only — ONE UPDATE of the S2 (0217) column; no flag, no function
-- re-create, no schema change; dark-safe by the same rule as 0217 (display data riding an existing
-- read, a smaller radius renders a smaller ring).
--
-- THE BUG (live on 0217's seed): 25/35/15 were decided without measuring the seeded world.
-- MEASURED GEOMETRY (every territory-bearing location, active AND hidden — hidden sites go active
-- later and their rings must already fit; read back from the deployed world 2026-07-18, matching
-- the migration-seeded coordinates):
--   ports (trade_outpost): Haven (-50,-30) · Slagworks (70,-10) · Driftmarch (10,80)
--   hunts (pirate_hunt):   Reaver (-45,40) · Snare (-15,40) · Blackden (65,55)
--                          Ember Gate (100,90) · Cinder Maw (125,110) · The Furnace (150,130)
--   safe  (safe_zone):     Refuge (-30,15) · Lull (40,30)
-- Closest pairs (Euclidean): Refuge–Reaver 29.15, Refuge–Snare 29.15, Reaver–Snare 30.00,
-- Cinder Maw–Ember Gate 32.02, Cinder Maw–The Furnace 32.02, Blackden–Lull 35.36; every other
-- pair ≥ 47.17. MINIMUM inter-location distance: 29.15. Tightest per-location bound
-- (nearest-neighbour / 2): 14.58 (Reaver, Snare, Refuge).
-- Under 25/35/15 the rings mutually ENGULF: Reaver's 35-ring contains Snare's CENTER (d=30.00)
-- and Refuge's (d=29.15), and vice versa — the parked-fleet orbit badge names the wrong site, the
-- rings render as illegible overlapping mush, and (the S4-review LOW) fleet_in_territory's
-- smallest-radius tie-break can resolve a fleet parked AT a dockable port to a DIFFERENT
-- overlapping territory, refusing the dock from the correct spot.
--
-- THE RETUNE (per-type CASE, the 0217 shape; every value strictly below every member's
-- nearest-neighbour/2 bound, so no two territories can contain the same point):
--   pirate_hunt / pirate_den → 12   (tightest member bound 14.58 — hostile zones stay LARGEST)
--   trade_outpost            → 10   (tightest member bound 23.58 — ports cleanly disjoint; the
--                                    dock guard always resolves the port the fleet is actually at)
--   safe_zone / rally_point  →  8   (tightest member bound 14.58 — waypoints the smallest)
--   everything else          → NULL (unchanged: no territory)
-- OVERLAP-FREE PROOF (containment is INCLUSIVE on both client and server, so disjoint requires
-- r_i + r_j < d for EVERY pair): the worst pair sums are 12+12 = 24 < 30.00 (Reaver–Snare, the
-- closest hostile–hostile pair) and 12+8 = 20 < 29.15 (Refuge–Reaver/Snare, the overall minimum
-- distance); every pair involving a port is ≥ 47.17 apart against sums ≤ 22. No ring reaches
-- another location's CENTER either (max radius 12 < 29.15). The by-type distinction stays
-- meaningful (12 > 10 > 8) and the 0219 CHECK (territory_radius NULL or > 0) stays satisfied.
--
-- SEED TRUE-HEAD DECLARATION: this file supersedes 0217's VALUES only — the column, the
-- get_world_map parity read, and 0217's own deploy-time assert are shipped history; THIS CASE is
-- the radius map now (the runtime proof's TERRITORY_PASS_SEEDED pins these values, and
-- TERRITORY_PASS_NOOVERLAP pins the disjointness generically).
-- OWNERSHIP: migrations remain the sole writer of locations (0002:9-10) — no RPC gains a write
-- path and no client can write the column.

update public.locations
set territory_radius = case location_type
  when 'trade_outpost' then 10
  when 'pirate_hunt' then 12
  when 'pirate_den' then 12
  when 'safe_zone' then 8
  when 'rally_point' then 8
  else null
end;

-- ── Self-assert (deploy-time; a raise aborts the migration txn — nothing half-applies) ───────────
do $$
declare v_n int;
begin
  -- (a) vacuity: the probed classes exist (a world with zero ports/hostiles/safe rows would green
  --     the sweeps below while proving nothing — the 0217 rule).
  select count(*) into v_n from public.locations where location_type = 'trade_outpost';
  if v_n = 0 then raise exception '0220 self-assert FAIL: no trade_outpost rows — the retune sweep would be vacuous'; end if;
  select count(*) into v_n from public.locations where location_type in ('pirate_hunt', 'pirate_den');
  if v_n = 0 then raise exception '0220 self-assert FAIL: no hostile rows — the retune sweep would be vacuous'; end if;
  select count(*) into v_n from public.locations where location_type in ('safe_zone', 'rally_point');
  if v_n = 0 then raise exception '0220 self-assert FAIL: no safe/rally rows — the retune sweep would be vacuous'; end if;

  -- (b) the retune landed, class-complete, world-wide (10/12/8/NULL).
  select count(*) into v_n from public.locations
   where (location_type = 'trade_outpost' and territory_radius is distinct from 10)
      or (location_type in ('pirate_hunt', 'pirate_den') and territory_radius is distinct from 12)
      or (location_type in ('safe_zone', 'rally_point') and territory_radius is distinct from 8)
      or (location_type in ('mining_site', 'derelict_station', 'event_site') and territory_radius is not null);
  if v_n <> 0 then
    raise exception '0220 self-assert FAIL: % location(s) off the retuned radius map (10/12/8/NULL)', v_n;
  end if;

  -- (c) GENERIC DISJOINTNESS on the DEPLOYED world, EVERY status (hidden sites go active later,
  --     their rings must already fit). Composes public.osn_distance (0099) — never a second
  --     distance formula. Inclusive containment means two rings share a point iff
  --     r_i + r_j >= d, so STRICT inequality is required for every territory-bearing pair.
  --     Honesty: this pins the world AS OF THIS DEPLOY; the runtime proof re-runs the same sweep
  --     (TERRITORY_PASS_NOOVERLAP) so a later world edit that breaks disjointness reds in CI.
  select count(*) into v_n
    from public.locations a
    join public.locations b on a.id < b.id
   where a.territory_radius is not null and b.territory_radius is not null
     and public.osn_distance(a.x, a.y, b.x, b.y) <= (a.territory_radius + b.territory_radius);
  if v_n <> 0 then
    raise exception '0220 self-assert FAIL: % overlapping territory pair(s) — two rings would contain the same point', v_n;
  end if;

  -- (d) no ring reaches another territory-bearing location's CENTER (the S4-review wrong-port
  --     hazard, stated explicitly so a red is actionable — (c) already implies it).
  select count(*) into v_n
    from public.locations a
    join public.locations b on a.id <> b.id
   where a.territory_radius is not null and b.territory_radius is not null
     and public.osn_distance(a.x, a.y, b.x, b.y) <= a.territory_radius;
  if v_n <> 0 then
    raise exception '0220 self-assert FAIL: % ring(s) reach another location''s center — a fleet parked AT a site could resolve to a different territory', v_n;
  end if;

  raise notice '0220 self-assert ok: territory_radius retuned 10/12/8/NULL class-complete; every territory pair strictly disjoint (r_i + r_j < d, min inter-location distance 29.15); no ring reaches another location''s center';
end $$;
