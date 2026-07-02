-- Byeharu — TRADE-MARKET-1: per-ship child FKs → ON DELETE CASCADE (integrity; empty/dark tables).
--
-- Small, isolated integrity fix, made BEFORE the atomic buy/sell writers land. The two per-ship child tables
-- ship_cargo_lots (0074) and trade_receipts (0086) each reference main_ship_instances(main_ship_id) with a
-- plain (NO ACTION / restrict) FK. Once those tables hold rows, that restrict FK would BLOCK the existing
-- auth.users → main_ship_instances on-delete cascade, softlocking account deletion. Both tables are DARK and
-- EMPTY (no seed, no writer yet), so re-creating the FK now is a clean, behavior-free change.
--
-- ── DESIGN DECISION (planner authority — "no account softlock / no destructive cleanup") ─────────
-- The per-ship child FKs (ship_cargo_lots.main_ship_id, trade_receipts.main_ship_id) become ON DELETE
-- CASCADE. Rationale:
--   • A DESTROYED ship KEEPS its row (§1e — cargo/receipts survive destruction, reachable after repair), so
--     the cascade NEVER fires on gameplay destruction. It fires ONLY on a true main_ship_instances ROW
--     deletion, which happens only via the auth.users account-deletion cascade
--     (main_ship_instances.player_id is already ON DELETE CASCADE — 0043:47, retained after the 0079 UNIQUE
--     drop; player_wallet.player_id already cascades too — 0086).
--   • Cascading the ship's lots + receipts on that DELIBERATE account deletion keeps account removal clean
--     and softlock-free, while NEVER auto-truncating any live gameplay data.
--   • good_id / location_id / offer FKs stay RESTRICT (reference/map data is never deleted).
--
-- Changes ONLY the main_ship_id FK on-delete behavior on these two empty, Trade-owned tables. No writer, no
-- cycle, no behavior change (tables empty). Constraint names are the deterministic <table>_<column>_fkey
-- auto-names (both FKs were declared inline, unnamed).

-- ship_cargo_lots.main_ship_id → on delete cascade
alter table public.ship_cargo_lots drop constraint if exists ship_cargo_lots_main_ship_id_fkey;
alter table public.ship_cargo_lots
  add constraint ship_cargo_lots_main_ship_id_fkey
  foreign key (main_ship_id) references public.main_ship_instances (main_ship_id) on delete cascade;

-- trade_receipts.main_ship_id → on delete cascade
alter table public.trade_receipts drop constraint if exists trade_receipts_main_ship_id_fkey;
alter table public.trade_receipts
  add constraint trade_receipts_main_ship_id_fkey
  foreign key (main_ship_id) references public.main_ship_instances (main_ship_id) on delete cascade;
