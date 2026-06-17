-- Byeharu — DEV/OPS one-time cleanup (NOT a schema change).
--
-- The free-tier project went UNHEALTHY (disk full): the REST/PostgREST layer began
-- returning "upstream request timeout" on every request while the DIRECT Postgres
-- connection (this migration path) still worked. Root cause: accumulated throwaway
-- test data from dozens of verify runs — above all the combat LOG tables
-- (combat_events / combat_ticks insert several rows per 2s combat tick).
--
-- This truncates that churn to reclaim disk IMMEDIATELY (TRUNCATE frees storage at once,
-- unlike DELETE, and works even on a near-full disk). It is SAFE: every row here is
-- throwaway test data (byeharu has no real players yet), and on any fresh environment
-- these tables are already empty so this is a harmless no-op. Seeded config/world tables
-- (sectors/zones/locations, unit_types, item_types, support_craft_types,
-- main_ship_hull_types, game_config) are intentionally left untouched.
--
-- CASCADE stays within the churn set (every child of these tables is also listed).

truncate table
  combat_events,
  combat_ticks,
  combat_reports,
  combat_encounters,
  location_presence,
  fleet_movements,
  fleet_units,
  fleets,
  reward_grants,
  build_orders
restart identity cascade;
