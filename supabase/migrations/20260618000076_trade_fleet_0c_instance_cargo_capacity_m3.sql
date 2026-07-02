-- Byeharu — TRADE-FLEET-0C: instance volume-capacity column (additive, nullable, backfilled).
--
-- Fourth additive step of Trading V1: add the per-instance VOLUME capacity to
-- `main_ship_instances`, copied (conceptually) from the hull's `base_cargo_capacity_m3`
-- (added in 0075) so larger/specialized hulls can diverge later (§2.3). Purely additive and
-- DELIBERATELY TRANSITIONAL: the column is added NULLABLE and backfilled here; the
-- commission-writer population + `SET NOT NULL` are the NEXT coordinated step (which also
-- carries the PORT-ENTRY md5 re-pin). This step touches NO function body and NO verifier, so
-- the PORT-ENTRY prosrc-md5 pins and D2 OID-inventory stay valid.
--
-- DESIGN LAW (TRADE-FLEET-0B §2.3): volume-only m³; per-instance capacity is copied from the
-- hull at commission. Occupied volume is the ship_cargo_lots sum (never cached here), so no
-- second writer to this table is introduced. The abstract `cargo_used` / `cargo_capacity`
-- int columns are KEPT this step (their commission-copy readers migrate in the next slice).
--
-- OWNERSHIP (SYSTEM_BOUNDARIES): main_ship_instances stays Main-Ship-owned. It is written
-- here ONLY by this migration's one-time backfill — a migration/admin DDL operation, not a
-- cross-system runtime writer; no cycle introduced. The existing owner-read policy
-- "main_ship_instances_select_own" (player_id = auth.uid()) + `grant select ... to
-- authenticated` already cover the new column, so NO new policy or grant is needed.
-- This is DARK: no reader consumes cargo_capacity_m3 yet.

-- 1) add the volume column NULLABLE (commission writers do not populate it yet; the copy +
--    SET NOT NULL land in the next coordinated step, alongside the writer md5 re-pin).
alter table public.main_ship_instances
  add column if not exists cargo_capacity_m3 numeric;

-- 2) backfill every existing instance from its hull's volume capacity (0075). A fresh DB has
--    ZERO instance rows, so this is a no-op on fresh apply, but correct for any existing row.
update public.main_ship_instances i
   set cargo_capacity_m3 = h.base_cargo_capacity_m3
  from public.main_ship_hull_types h
 where h.hull_type_id = i.hull_type_id
   and i.cargo_capacity_m3 is null;

-- 3) NULL-tolerant >0 check for the transitional window: SQL CHECK is not-false semantics, so
--    a bare `> 0` PASSES on NULL rows — it enforces >0 on populated rows and permits NULL only
--    until the next step populates every row and adds SET NOT NULL. House-named, re-runnable.
alter table public.main_ship_instances drop constraint if exists main_ship_instances_cargo_capacity_m3_check;
alter table public.main_ship_instances
  add constraint main_ship_instances_cargo_capacity_m3_check
  check (cargo_capacity_m3 > 0);
