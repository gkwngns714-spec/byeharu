# S2 TERRITORY — grounded implementation brief (banked 2026-07-18)

Hands to the S2 implementer once S1 (berth) merges. Serializes behind S1 (shares
`scripts/fleetgo-proof.*`, `src/features/map/GalaxyMap.tsx`, `mapTypes.ts`).

## Schema + enum (the real values)
- `public.locations` authority: `supabase/migrations/20260616000002_world_map.sql:48-72`.
- `location_type` CHECK (0002:52-56): `pirate_hunt, pirate_den, mining_site, derelict_station,
  trade_outpost, rally_point, safe_zone, event_site`. (NOT port/hostile/waypoint. `physical_role`
  is a separate identity column — do not confuse.)
- Decided radius map: `trade_outpost`→25; `pirate_hunt` AND `pirate_den`→35 (all live hostiles are
  pirate_hunt; pirate_den has 0 rows — seed both); `safe_zone`/`rally_point`→15; else NULL.
- New migration: `supabase/migrations/20260618000217_territory_radius.sql` — `alter table locations
  add column territory_radius numeric;` + a CASE-on-location_type seeding update + the get_world_map
  parity re-create. Migrations are the declared sole writer of locations (0002:9-10).

## The one read to edit (PARITY)
- `get_world_map()` is `language sql stable` (NOT plpgsql, NOT a view), TRUE head at 0002:91-132,
  NEVER re-created (all later mentions are grant re-emits). Byte-copy it; ONE hunk: in the inner
  `jsonb_build_object` (0002:113-119) add `'territory_radius', l.territory_radius` beside
  `'status', l.status` (:118). PRESERVE the three `status='active'` filters (0002:121/125/129) —
  20260618000175:161-180 structurally pins all three (hidden-port leak safety). Re-emit grant to
  `anon, authenticated` (0002:134).
- `get_my_fleet_positions` (0212 head) returns coords/location_id only — NO change.
- No client does `.from('locations')` — wire-through is automatic; just widen `MapLocation` in
  `src/features/map/mapTypes.ts:36-48` with `territory_radius: number | null`.

## Client render
- Scale: `WORLD_TO_VIEWBOX_SCALE = 1000/20000 = 0.05` at `src/features/map/openSpaceTransform.ts:36-40`.
  A territory ring is WORLD-TRUE → SVG radius = `territory_radius * 0.05` viewBox units (NOT `/k` —
  opposite of screen-constant marker glyphs).
- Mount a hook-free `territoryLayer({locations, norm, k})` (new `src/features/map/territoryLayer.ts`,
  follow the `fleetShipsLayer`/`teamMarkersLayer` element-helper convention, GalaxyMap.tsx:466-476)
  as FIRST child of the camera `<g>` at GalaxyMap.tsx:393 (before movements at :401 → under lines +
  markers). Every element `pointerEvents:'none'`. Center `norm({x:loc.x,y:loc.y})`, skip null radius.
- Orbit label: extend the LIVE parked-fleet badge in `resolveFleetSpaceBadges`
  (`src/features/map/teamMarkers.ts:119-145`, label at :139). DO NOT use `resolveMainShipStatusLabel`
  (`mainshipStatusLabel.ts` — ORPHANED, zero prod call sites; mounting there ships dead code).

## Compose, don't fork
- Distance: the ONLY client Euclidean helper is `distance()` at `src/game/movement/travelPreview.ts:9-11`.
- In-flight position: `interpolateMovementPoint` (`src/features/map/movementInterpolation.ts:31-49`).
- New pure `territoryAt(point, locations): MapLocation|null` beside movementInterpolation.ts —
  composes `distance()`, smallest-containing-radius deterministic tiebreak. Parked fleet feeds
  space_x/space_y; in-flight feeds interpolateMovementPoint.
- Dock coupling: classify with existing `isDockablePortForDisplay` (`mapTypes.ts:32-34`), don't
  re-implement dockability.
- Future server territory check composes `public.osn_distance` (0099:42-58) + territory_radius —
  never a 3rd formula.

## CI proof (scripts/fleetgo-proof.*)
- Add 2 markers to `MARKERS` (fleetgo-proof.sh:32) + DO blocks in fleetgo-proof.sql (raise notice,
  one begin..rollback txn):
  - `TERRITORY_PASS_SEEDED` — slag(trade_outpost)=25, an active hunt site=35, safe_zone=15/NULL;
    vacuity guard (raise if probed rows absent).
  - `TERRITORY_PASS_MAPREAD` — call get_world_map(), assert a known active location's JSON carries
    territory_radius with the seeded value, AND a NULL-territory location still returns the key
    (additive, never conditional).
- Optional sh-side static grep: the 0217 get_world_map retains all three `status='active'` filters.

## Spaghetti traps (do NOT step in)
1. `zones.radius` exists (0002:33), is returned (get_world_map :106, mapTypes.ts:55), drawn NOWHERE.
   Territory is a NEW `locations` column — say in the 0217 header WHY the dormant sibling isn't reused.
2. `exploration_scan_radius`/`mining_extract_radius` are ship-centered config scalars; territory is
   location-centered → one column per location, NOT a game_config key.
3. `LocationMarker` is the ONLY location renderer — one ring layer suffices; territory does NOT force
   a parallel system.
