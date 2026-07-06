-- Byeharu — MAP DECLUTTER: relocate the FIVE waypoint locations — display/legacy-pacing data only.
--
-- Root cause being fixed (recon MAP_DECLUTTER_RECON.local.md §1): the 0002 waypoints were seeded
-- 1–3.6 world units apart on the tiny legacy map scale, while the 0066 starter ports sit on the OSN
-- scale (−50…80). The content-fit camera frames the 120-unit port spread, compressing the two
-- waypoint clusters to ~8–20 screen px — overlapping markers and unreadable labels at default zoom
-- (min pairwise separation 1.2% of the content span vs the ~9% no-overlap threshold).
--
-- THE CHANGE (recon §7 layout — waypoints ONLY, matched by their post-0148 one-word names):
--   Refuge   (Wreck Belt,      safe_zone)        (11, 5)  → (−30, 15)
--   Snare    (Wreck Belt,      pirate_hunt d10)  (12, 6)  → (−15, 40)
--   Reaver   (Wreck Belt,      pirate_hunt d15)  ( 9, 4)  → (−45, 40)
--   Lull     (Ion Storm Route, safe_zone)        (31, 22) → ( 40, 30)
--   Blackden (Ion Storm Route, pirate_hunt d25)  (33, 23) → ( 65, 55)
-- Content bbox (x −50…70, y −30…80) is UNCHANGED (the new points stay inside the port envelope), so
-- the default content-fit zoom is unchanged; min pairwise separation over all nine map points
-- (8 locations + the (0,0) home base) becomes 29.2 world units ≈ 24% of span — no overlapping
-- labels/markers at default zoom, viewport-independent. Distance-from-home now orders by difficulty
-- (Refuge 33.5 < Snare 42.7 < Lull 50 < Reaver 60.2 < Blackden 85.1 — the old seed had the d15 site
-- as the CLOSEST point on the map). Zone geography preserved (Wreck Belt trio west with Haven; Ion
-- Storm pair east with Slagworks/Driftmarch).
--
-- BLAST RADIUS (proven in the recon; the reason this migration touches ONLY these five rows):
--   • locations.x/y is display layout + the LIVE-read legacy travel-distance input at send time
--     (0050/0053/0152 read l.x/l.y at command time; in-flight fleet_movements rows keep their
--     per-trip snapshot and settle by IDs — deliberately NOT backfilled, rewriting in-flight
--     geometry would teleport moving ships). Future legacy trips to the waypoints get ~2.8× longer
--     on average; travel_scale / min_travel_seconds stay the human-owned pacing knobs (NO config
--     value is changed here).
--   • The OSN domain consults locations.x/y NOWHERE (0067:36/498/527 — anchors are the sole
--     coordinate authority), and Dock-0's exact-match compares the ANCHOR to the movement snapshot
--     (0067:564-572). The five waypoints have NO anchor and NO docking service; the three anchored
--     ports are NOT moved — so every Dock-0 predicate and the 0066 anchor==location alignment hold
--     by construction. NO space_anchors row, port row, snapshot, function, flag, or grant changes.
--   • STANDING INVARIANT for any FUTURE port relocation (out of scope here): move locations.x/y and
--     retire+insert the port's anchor in ONE migration (0063 lifecycle), same values both places
--     (0066 invariant), accepting target_anchor_changed terminal failures for routes in flight.
--
-- Fail-closed + atomic (the 0148 idiom): the whole relocation runs in one do-block transaction;
-- a missing waypoint, a wrong update count, a failed read-back, or a drifted port row aborts with
-- NO partial relocation. Re-running is a tolerated no-op (a same-value UPDATE still matches all
-- five rows, and the read-back accepts already-at-target coordinates).

do $$
declare
  v_count integer;
begin
  -- ── All five post-0148 one-word waypoints must exist under their zones (run 0148 first) ───────────
  if (select count(*) from public.locations l join public.zones z on z.id = l.zone_id
       where (z.name, l.name) in (('Wreck Belt','Refuge'), ('Wreck Belt','Snare'), ('Wreck Belt','Reaver'),
                                  ('Ion Storm Route','Lull'), ('Ion Storm Route','Blackden'))) <> 5 then
    raise exception 'map_declutter_waypoints: the five 0148 one-word waypoints are not all present (apply 0148 first; abort, no partial relocation)';
  end if;

  -- ── Relocate by the zone-scoped unique (zone_id, name) key (the exact 0148 matching pattern) ──────
  update public.locations l
     set x = m.new_x, y = m.new_y
    from (values
      ('Refuge',   'Wreck Belt',      -30.0, 15.0),
      ('Snare',    'Wreck Belt',      -15.0, 40.0),
      ('Reaver',   'Wreck Belt',      -45.0, 40.0),
      ('Lull',     'Ion Storm Route',  40.0, 30.0),
      ('Blackden', 'Ion Storm Route',  65.0, 55.0)
    ) as m(name, zone_name, new_x, new_y)
    join public.zones z on z.name = m.zone_name
   where l.zone_id = z.id and l.name = m.name;

  -- ── Row-count guard: EXACTLY five rows updated (a same-value re-run still matches all five) ───────
  get diagnostics v_count = row_count;
  if v_count <> 5 then
    raise exception 'map_declutter_waypoints: expected exactly 5 waypoint rows updated, got % (abort, no partial relocation)', v_count;
  end if;

  -- ── Read-back guard: every waypoint sits at its exact recon-§7 target coordinate ───────────────────
  if (select count(*) from public.locations l join public.zones z on z.id = l.zone_id
       where (z.name, l.name, l.x, l.y) in (
         ('Wreck Belt','Refuge',   -30.0, 15.0),
         ('Wreck Belt','Snare',    -15.0, 40.0),
         ('Wreck Belt','Reaver',   -45.0, 40.0),
         ('Ion Storm Route','Lull',     40.0, 30.0),
         ('Ion Storm Route','Blackden', 65.0, 55.0))) <> 5 then
    raise exception 'map_declutter_waypoints: read-back failed — a waypoint is not at its target coordinate (abort)';
  end if;

  -- ── Untouched guard: the three anchored starter ports (fixed 0066 UUIDs) keep their 0066 coords, so
  --    every anchor stays exactly aligned with its location (the 0066 invariant) with zero co-move. ──
  if (select count(*) from public.locations
       where (id, x, y) in (
         ('b1a00001-0066-4a00-8a00-000000000001'::uuid, -50.0, -30.0),
         ('b1a00002-0066-4a00-8a00-000000000002'::uuid,  70.0, -10.0),
         ('b1a00003-0066-4a00-8a00-000000000003'::uuid,  10.0,  80.0))) <> 3 then
    raise exception 'map_declutter_waypoints: a starter-port coordinate is not at its 0066 seed value — ports must NOT move here (abort)';
  end if;
end $$;
