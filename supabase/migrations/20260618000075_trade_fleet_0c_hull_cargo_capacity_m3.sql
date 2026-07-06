-- Byeharu — TRADE-FLEET-0C: hull volume-capacity column (additive; abstract column KEPT).
--
-- Third additive step of Trading V1: add the per-hull VOLUME capacity to the static
-- Reference/Config catalog `main_ship_hull_types`. Purely additive — a new nullable column,
-- backfilled, then constrained NOT NULL + (> 0). It touches NO RPC and NO reader.
--
-- DESIGN LAW (TRADE-FLEET-0B §2.3, §1c): capacity is VOLUME-ONLY, canonical m³. The starter
-- hull's abstract `50` maps 1:1 to `50.0 m³` (≈ 50 crates / ≈ 6 containers) — zero balance
-- drift. Per-instance `cargo_capacity_m3` will be COPIED from this at commission (next 0C
-- sub-slice); this step only lands the hull column.
--
-- ABSTRACT COLUMN KEPT: the abstract `base_cargo_capacity integer` is DELIBERATELY NOT
-- dropped/altered here — its readers still depend on it and are migrated in later 0C steps:
--   • main_ship_instance.sql (ensure_main_ship_for_player copies h.base_cargo_capacity)
--   • port_entry_commission_normalize.sql:46 (commission writer copies it)
--   • mainship_preview.sql:48 (preview output reads v_hull.base_cargo_capacity)
--   • scripts/verify-phase7.mjs, scripts/port-entry-1-proof.sql (test inserts)
-- Removing it now would break them; the abstract → volume swap is a coordinated later slice.
--
-- OWNERSHIP (SYSTEM_BOUNDARIES): main_ship_hull_types stays Reference/Config-owned
-- (migration/admin sole writer). The existing "main_ship_hull_types_public_read" policy
-- already covers all columns of the table, so the new column needs NO new policy or grant.
-- This is DARK: no gameplay/RPC reads the new column yet.

-- 1) add the volume column (nullable first, so the backfill can populate it).
alter table public.main_ship_hull_types
  add column if not exists base_cargo_capacity_m3 numeric;

-- 2) backfill the starter hull: abstract 50 → 50.0 m³ (§1c, exact scale, no drift).
update public.main_ship_hull_types
   set base_cargo_capacity_m3 = 50.0
 where hull_type_id = 'starter_frigate'
   and base_cargo_capacity_m3 is null;

-- 3) safety backfill for any OTHER hull (none expected — starter_frigate is the only seed):
--    carry the abstract capacity across 1:1 so no row is left null before SET NOT NULL.
update public.main_ship_hull_types
   set base_cargo_capacity_m3 = base_cargo_capacity
 where base_cargo_capacity_m3 is null;

-- 4) enforce the §2.3 contract AFTER backfill: NOT NULL + (> 0), house-named check.
alter table public.main_ship_hull_types
  alter column base_cargo_capacity_m3 set not null;
alter table public.main_ship_hull_types drop constraint if exists main_ship_hull_types_base_cargo_capacity_m3_check;
alter table public.main_ship_hull_types
  add constraint main_ship_hull_types_base_cargo_capacity_m3_check
  check (base_cargo_capacity_m3 > 0);
