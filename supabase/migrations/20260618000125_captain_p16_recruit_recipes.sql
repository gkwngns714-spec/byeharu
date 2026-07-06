-- Byeharu — CAPTAIN-P16 SLICE 2: the recruitment recipe catalog `captain_recipe_ingredients` +
-- seeds (the 0107 `module_recipe_ingredients` analogue, captain domain). Catalog/config ONLY —
-- NO command, NO writer, NO RPC, NO adapter change, NO frontend, NO flag flipped. The table is
-- INERT this slice (nothing reads it yet).
--
-- Phase 16 "Captain progression (consumes inventory)" — captain RECRUITMENT that consumes
-- `player_inventory`, the 0109 `craft_module` analogue (design self-approved 2026-07-04, recorded
-- in 0124's header + DEV_LOG). This slice adds the recipe CONFIG, mirroring how Modules owns
-- `module_recipe_ingredients` (0107) while the craft COMMAND lives in Production.
--
-- LOCKED DECISIONS (self-approved 2026-07-04; recorded in docs/DEV_LOG.md this slice):
--   1. NORMALIZED-TABLE recipe encoding, NOT jsonb — the 0107 decision-3 posture verbatim: one
--      implicit recipe per captain type = its ingredient rows, with real referential integrity
--      (FK to captain_types + item_types, qty > 0 CHECK, composite PK). No parallel jsonb recipe
--      vocabulary.
--   2. ITEMS-ONLY cost — every ingredient is an existing `item_types` row; NO metal, NO credits,
--      NO Base/Wallet edge. This is the pipeline law: progression consumes INVENTORY (the 0109
--      items-only craft cost), so recruitment's cost lands ONLY in `player_inventory` via the
--      Inventory `inventory_spend` leaf (the next-slice command), never in Base/Wallet.
--   3. `captain_memory_shard` (0039 — 'progression'/'rare', seeded expressly for this) is the
--      SHARED gating progression ingredient across all five captain types — the progression-class
--      cost analogue of the module recipes' `blueprint_fragment`/`anomaly_shard` gate. Each type
--      then adds two specialization-flavored materials from the existing catalog.
--   4. EXISTING item_types ONLY — every recipe item id already exists (0039 + 0097): no new item
--      is invented here (the 0107:114 posture). Quantities sit in the 0107 1–8 small-count band.
--
-- Ownership: the recipe CONFIG belongs to the **Captain** system (a public-read catalog like
-- `captain_types`), exactly as `module_recipe_ingredients` belongs to Modules. Captain stays a
-- pure instance-leaf: NO Captain→Inventory edge is introduced. The recipe's FIRST consumer is the
-- NEXT-slice **Production**-owned recruit command (ROADMAP law 5 "Production = crafting"), which
-- reads this config DOWNWARD — the acyclic 0109 fan-out: Production → Captain recipe read ·
-- Production → Inventory `inventory_spend` · Production → Captain `captains_mint_instance` mint.
-- One sole-writer per table; this slice adds NO writer and NO cross-system edge.
--
-- RLS/grants — verified, not assumed: copied VERBATIM from the module analogue (0107:96–98) which
-- copies item_types (0039:23–25) — RLS enabled, ONE public-read select policy, `grant select to
-- anon, authenticated`, NO insert/update/delete policy and NO write grant → clients cannot mutate;
-- only migrations / service_role (admin) write (the 0039/0107 catalog posture). No function is
-- created here, so no execute-surface relock is needed (0054 precedent).
--
-- SYSTEM_BOUNDARIES doc-sync (SAME step — the 0107 precedent for a catalog-table-creating slice):
-- §1 matrix gains `captain_recipe_ingredients` under **Captain** (catalog/config — seeded by
-- migration only, NO runtime writer; public read-only); the §2 Captain row notes the recruit
-- recipe config now exists, its first consumer the next-slice Production recruit command. NO writer
-- and NO edge are added this slice.

-- ── captain_recipe_ingredients — normalized recipe config (Captain; public read-only) ────────────
-- One implicit recipe per captain type = its ingredient rows. Items-only costs (decision 2).
create table public.captain_recipe_ingredients (
  captain_type_id text not null references public.captain_types (id),
  item_id         text not null references public.item_types (item_id),
  qty             integer not null check (qty > 0),
  created_at      timestamptz not null default now(),
  primary key (captain_type_id, item_id)
);

alter table public.captain_recipe_ingredients enable row level security;
create policy "captain_recipe_ingredients_public_read" on public.captain_recipe_ingredients for select using (true);
grant select on public.captain_recipe_ingredients to anon, authenticated;

-- ── seeds — one recipe per captain type (idempotent) ─────────────────────────────────────────────
-- Every item id already exists (0039 + 0097); quantities sit in the 0107 1–8 band.
-- `captain_memory_shard` 1 is the shared gating progression ingredient on every recipe (decision 3).
insert into public.captain_recipe_ingredients (captain_type_id, item_id, qty) values
  -- combat: the combat-component class + pirate salvage
  ('gunnery_veteran',     'captain_memory_shard', 1),
  ('gunnery_veteran',     'weapon_parts',         3),
  ('gunnery_veteran',     'pirate_alloy',         2),
  -- trade: bulk salvage + repair components
  ('trade_broker',        'captain_memory_shard', 1),
  ('trade_broker',        'scrap',                8),
  ('trade_broker',        'repair_parts',         2),
  -- exploration: survey yields + anomaly material
  ('survey_cartographer', 'captain_memory_shard', 1),
  ('survey_cartographer', 'scan_data',            4),
  ('survey_cartographer', 'anomaly_shard',        2),
  -- mining: raw extraction yields
  ('extraction_foreman',  'captain_memory_shard', 1),
  ('extraction_foreman',  'ore',                  6),
  ('extraction_foreman',  'crystal',              2),
  -- support: repair + drive components
  ('fleet_quartermaster', 'captain_memory_shard', 1),
  ('fleet_quartermaster', 'repair_parts',         3),
  ('fleet_quartermaster', 'engine_parts',         2)
on conflict (captain_type_id, item_id) do nothing;
