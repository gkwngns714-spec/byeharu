-- Byeharu — MODULES-P13 SLICE A: the dark capability flag + the module catalog/recipe config
-- tables + starter seeds (foundations only — NO gameplay logic, NO RPC, NO instances table,
-- NO frontend, NOTHING client-writable).
--
-- Phase 13 "Module instances + crafting" (ROADMAP :88 — "instances, not stack-only") follows the
-- exploration/mining slice template (0097–0101 / 0102–0106). LOCKED DESIGN DECISIONS
-- (owner-directed 2026-07-04; recorded in docs/DEV_LOG.md this slice):
--   1. SYSTEM SHAPE (ROADMAP law 5: "Production=support craft/crafting · Fitting=modules"): a NEW
--      leaf system **Modules** owns the module state tables (`module_types` catalog,
--      `module_recipe_ingredients` config, and — later slices — `module_instances` + ONE mint
--      writer). The craft COMMAND itself will belong to the existing **Production** system,
--      depending one-directionally DOWNWARD on Inventory (`inventory_spend`) and Modules (mint) —
--      acyclic, one sole-writer per table.
--   2. CRAFTING IS INSTANT in Phase 13: an idempotent dark command in the 0099/0104 two-layer
--      idiom with a PLAYER-scoped receipts convention (crafting is non-spatial — the
--      trade_relief_claims (player, request_id) keying, NOT the ship-scoped space receipts).
--      The M4.5 "same queue" note stays FUTURE meaning — integrating with `build_orders` would
--      touch the shipped Production queue and risk the green M4.5 tests, so it is explicitly
--      DEFERRED. RETIREMENT NOTE for that deferral: when module production later moves onto the
--      serial queue, the queued completion path MUST call the SAME Modules mint helper this phase
--      creates — never a second mint path.
--   3. RECIPE ENCODING is a normalized table, NOT jsonb: `module_recipe_ingredients
--      (module_type_id, item_id, qty)` with FKs to `module_types` + `item_types` and `qty > 0` —
--      referential integrity over blob parsing. One implicit recipe per module type (its
--      ingredient rows). Costs are ITEMS-ONLY in Phase 13 (no metal/credits — the pipeline law
--      says crafting consumes INVENTORY; metal would drag in a Base edge this phase doesn't need
--      and can be added forward-only later).
--   4. ONE craft = ONE instance (no batching) — keeps idempotency trivial.
--   5. Flag name `module_crafting_enabled`, seeded 'false' — the exact 0097/0102 config+flag
--      idiom, including the server-side `feature_disabled` rejection posture for every future RPC.
--
-- (a) Capability flag `module_crafting_enabled = false` — the standard server-authoritative dark
--     gate (0070/0071 idiom, same as exploration_enabled/mining_enabled). NO RPC exists yet; the
--     flag simply exists dark. EVERY module-crafting RPC added in later slices MUST check it FIRST
--     and reject-before-any-read (no row read, no lock, no write) while it is false — UI hiding is
--     never the only control. This migration does not flip any flag true.
-- (b) `module_types` is minimal intrinsic catalog identity ONLY (id/name/slot_type/description):
--     NO stats columns — stats wiring is Phase 14's job (`fit_module_to_ship` feeding
--     `calculate_expedition_stats`), added forward-only there. `slot_type` is the intrinsic module
--     archetype (display now; fitting validation in Phase 14); like item_types.category and
--     support_craft_types.role it is unconstrained Reference/Config metadata with no code consumer
--     yet — new archetypes are additive later, no CHECK to migrate.
-- (c) Recipes consume ONLY EXISTING `item_types` rows (0039/0097 seeds: weapon_parts,
--     engine_parts, repair_parts, scrap, pirate_alloy, crystal, scan_data, anomaly_shard,
--     blueprint_fragment) — REUSED, never re-seeded (the 0097 reuse law: re-adding catalog
--     concepts under new ids is forbidden). item_types is NOT touched by this migration.
--
-- RLS/grants — verified, not assumed: both new tables copy the Reference/Config catalog posture
-- verbatim from item_types (0039:23–25) / support_craft_types (0042:32–36) — RLS enabled, ONE
-- public-read select policy, `grant select to anon, authenticated`, NO insert/update/delete policy
-- and NO write grant → clients cannot mutate; only migrations / service_role (admin) write. The
-- game_config row inherits the table-wide public-read posture ("game_config_public_read" —
-- 0003:13–15). No function is created here, so no execute-surface relock is needed (0054
-- precedent). The seeds are inert: no RPC, no reader, no writer references them yet.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced in the SAME step — the 0098/0103 precedent for
-- table-creating slices): §1 matrix gains `module_types` + `module_recipe_ingredients` under the
-- new **Modules** system (catalog/config — seeded by migration only, NO runtime writer yet; the
-- mint writer arrives with `module_instances`); §2 gains the Modules system row including the
-- Production-will-own-the-craft-command note. game_config stays Reference/Config.

-- ── (a) the dark capability gate (OFF / inert; no writer/reader exists yet) ───────────────────────
insert into public.game_config (key, value, description) values
  ('module_crafting_enabled', 'false',
   'MODULES-P13: server-authoritative dark gate for module crafting (Progression). OFF until the '
   'feature is explicitly enabled by the owner. Every module-crafting RPC must check this FIRST '
   'and reject-before-any-read while false; the UI surface stays hidden independently (fails '
   'closed both sides).')
on conflict (key) do nothing;

-- ── (b) module_types — the module archetype catalog (Modules; public read-only) ──────────────────
create table public.module_types (
  id          text primary key,
  name        text not null,
  slot_type   text not null,
  description text not null,
  created_at  timestamptz not null default now()
);

alter table public.module_types enable row level security;
-- Public read-only; NO insert/update/delete policy and NO write grant → clients cannot mutate.
-- Only migrations / service_role (admin) write (the 0039/0042 catalog posture).
create policy "module_types_public_read" on public.module_types for select using (true);
grant select on public.module_types to anon, authenticated;

-- ── (c) module_recipe_ingredients — normalized recipe config (Modules; public read-only) ─────────
-- One implicit recipe per module type = its ingredient rows. Items-only costs (decision 3).
create table public.module_recipe_ingredients (
  module_type_id text not null references public.module_types (id),
  item_id        text not null references public.item_types (item_id),
  qty            integer not null check (qty > 0),
  created_at     timestamptz not null default now(),
  primary key (module_type_id, item_id)
);

alter table public.module_recipe_ingredients enable row level security;
create policy "module_recipe_ingredients_public_read" on public.module_recipe_ingredients for select using (true);
grant select on public.module_recipe_ingredients to anon, authenticated;

-- ── (d) starter seeds — 4 module types spanning distinct slot archetypes (idempotent) ────────────
-- Names/copy match the existing catalog tone (0042 support craft / 0039 items). Descriptions are
-- player-facing display copy; nothing consumes slot_type until Phase 14 fitting.
insert into public.module_types (id, name, slot_type, description) values
  ('autocannon_battery',    'Autocannon Battery',     'weapon',
   'A rack of salvage-forged autocannons. Raw expedition firepower once fitted (Phase 14).'),
  ('vector_thruster_kit',   'Vector Thruster Kit',    'engine',
   'Reworked drive assembly that sharpens the main ship''s handling and burn efficiency.'),
  ('expanded_cargo_lattice','Expanded Cargo Lattice', 'cargo',
   'A reinforced internal lattice that opens up additional secured cargo volume.'),
  ('deep_scan_sensor_array','Deep-Scan Sensor Array', 'sensor',
   'A long-range survey array tuned on recovered anomaly data. Sees what standard sweeps miss.')
on conflict (id) do nothing;

-- Recipes draw ONLY from existing item_types rows (0039 + 0097); quantities sit in the small-count
-- magnitude those items drop at (0041 combat loot / 0098 site bundles).
insert into public.module_recipe_ingredients (module_type_id, item_id, qty) values
  -- weapon: the combat-component class + pirate salvage
  ('autocannon_battery',     'weapon_parts',       4),
  ('autocannon_battery',     'pirate_alloy',       2),
  ('autocannon_battery',     'scrap',              6),
  -- engine: the drive-component class + crystal
  ('vector_thruster_kit',    'engine_parts',       4),
  ('vector_thruster_kit',    'crystal',            2),
  ('vector_thruster_kit',    'scrap',              4),
  -- cargo: bulk structural materials
  ('expanded_cargo_lattice', 'scrap',             10),
  ('expanded_cargo_lattice', 'pirate_alloy',       3),
  ('expanded_cargo_lattice', 'repair_parts',       2),
  -- sensor: exploration yields + a rare blueprint (the progression-class ingredient)
  ('deep_scan_sensor_array', 'scan_data',          5),
  ('deep_scan_sensor_array', 'anomaly_shard',      2),
  ('deep_scan_sensor_array', 'blueprint_fragment', 1)
on conflict (module_type_id, item_id) do nothing;
