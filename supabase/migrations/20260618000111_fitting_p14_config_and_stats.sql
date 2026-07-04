-- Byeharu — FITTING-P14 SLICE A: the dark capability flag + the module stats/slot-cost catalog
-- wiring (foundations only — NO gameplay logic, NO RPC, NO fittings table, NO adapter change,
-- NO frontend, NOTHING client-writable).
--
-- Phase 14 "Module fitting" (ROADMAP :89 — "`fit_module_to_ship` | server-validated; feeds stats")
-- follows the Phase-13 slice template (0107–0110). LOCKED DESIGN DECISIONS (planner-approved
-- 2026-07-04; recorded in docs/DEV_LOG.md this slice):
--   1. SYSTEM SHAPE — Phase 14 creates a NEW leaf system **Fitting** per ROADMAP law 5
--      ("Fitting=modules"); fitting state will live in a NEW Fitting-owned junction table
--      `ship_module_fittings` (arrives slice B — NOT this slice) with its own sole writer, never a
--      second writer or new columns on `module_instances`; Fitting depends one-directionally
--      DOWNWARD on Modules (read instances), Main Ship (read `module_slots`), and Reference/Config.
--   2. CAPACITY/TRADEOFF MODEL — mirrors the proven support-craft mechanism in 0044: each module
--      type has an integer `slot_cost ≥ 1`; the adapter (extended in a later slice via
--      `create or replace` in a new migration) will hard-REJECT when Σ slot_cost of fitted modules
--      > `main_ship_instances.module_slots` (exception, never a clamp — the 0044:112–115 idiom),
--      and slot_type-based tradeoff rules (pirate_attention / speed penalty) will apply exactly
--      like 0044's role-based rules — so module power is capacity-limited with tradeoffs, never a
--      raw sum.
--   3. STATS ENCODING — reuse the `support_craft_types.base_stats_json` idiom: add a
--      `stats_json jsonb not null default '{}'` column to `module_types`, using the SAME physical
--      stat keys the adapter already reads (attack/defense/repair/cargo/scan/mining/evasion) plus
--      one new key `speed_mult_bonus` (numeric fraction of hull base speed, applied before
--      penalties — the engine archetype's positive effect; the adapter clamps total speed exactly
--      as today: round(greatest(0.2, …), 3) — 0044:117–118).
--   4. FLAG — `module_fitting_enabled` seeded 'false', the exact 0097/0102/0107 idiom; every
--      Phase 14 RPC must check it FIRST and reject-before-any-read; this migration flips nothing.
--
-- (a) Capability flag `module_fitting_enabled = false` — the standard server-authoritative dark
--     gate (0070/0071 idiom, same as exploration_enabled/mining_enabled/module_crafting_enabled).
--     NO RPC exists yet; the flag simply exists dark. EVERY module-fitting RPC added in later
--     slices MUST check it FIRST and reject-before-any-read (no row read, no lock, no write) while
--     it is false — UI hiding is never the only control. This migration does not flip any flag true.
-- (b) `module_types` gains `slot_cost` + `stats_json` — Reference/Config CATALOG data, exactly
--     like `support_craft_types.capacity_cost`/`base_stats_json` (0042). The table's public-read
--     posture is UNCHANGED: the existing "module_types_public_read" policy + select grants (0107)
--     already cover new columns, and there is still NO write policy/grant → no client write path.
--     Their FIRST code consumer arrives with the Phase 14 adapter slice (`create or replace` of
--     calculate_expedition_stats in a later 0112+ migration); nothing reads them today — inert
--     catalog data, dark by construction.
-- (c) Seed magnitudes were chosen against the 0042 `base_stats_json` band so a full 3-slot module
--     fit is comparable to a similarly-sized support-craft loadout (missile_boat capacity 3 →
--     attack 12 · cargo_drone capacity 2 → cargo 20 · survey_drone capacity 2 → scan 8 ·
--     decoy_drone capacity 1 → evasion 6): autocannon_battery slot 1 → attack 10;
--     vector_thruster_kit slot 1 → evasion 3 + speed_mult_bonus 0.1; expanded_cargo_lattice
--     slot 2 (deliberately multi-slot so the Σ slot_cost cap math is exercised) → cargo 25;
--     deep_scan_sensor_array slot 1 → scan 8. The UPDATEs are the write-once analogue of the seed
--     inserts' `on conflict do nothing`: guarded on `stats_json = '{}'` so a re-run (or a later
--     owner rebalance) is never clobbered.
--
-- RLS/grants: no new table, no new policy, no new grant (the 0075/0076 add-column precedent — an
-- existing table-wide policy covers new columns). No function is created here, so no
-- execute-surface relock is needed (0054 precedent).
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced in the SAME step): the §1 `module_types` row now
-- records `slot_cost` + `stats_json` (still migration-seeded only, NO runtime writer; consumer =
-- the Phase 14 fitting adapter, later slice). NO Fitting system row is added yet — its table does
-- not exist until slice B, and a doc must never describe state that isn't real.

-- ── (a) the dark capability gate (OFF / inert; no writer/reader exists yet) ───────────────────────
insert into public.game_config (key, value, description) values
  ('module_fitting_enabled', 'false',
   'FITTING-P14: server-authoritative dark gate for module fitting (Fitting). OFF until the '
   'feature is explicitly enabled by the owner. Every module-fitting RPC must check this FIRST '
   'and reject-before-any-read while false; the UI surface stays hidden independently (fails '
   'closed both sides).')
on conflict (key) do nothing;

-- ── (b) module_types += slot_cost + stats_json (Reference/Config catalog columns) ─────────────────
alter table public.module_types
  add column slot_cost  integer not null default 1 check (slot_cost >= 1),
  add column stats_json jsonb   not null default '{}'::jsonb;

comment on column public.module_types.slot_cost is
  'FITTING-P14: module slots this type consumes when fitted (the support_craft_types.capacity_cost '
  'analogue). The Phase-14 adapter slice hard-REJECTS when the fitted sum exceeds '
  'main_ship_instances.module_slots (the 0044:112–115 idiom — exception, never a clamp).';
comment on column public.module_types.stats_json is
  'FITTING-P14: fitted stat contributions (the support_craft_types.base_stats_json analogue). Keys '
  'the adapter reads: attack/defense/repair/cargo/scan/mining/evasion + speed_mult_bonus (numeric '
  'fraction of hull base speed, applied before penalties; total speed clamps exactly as today). '
  'First consumer arrives with the Phase-14 adapter slice — nothing reads this yet.';

-- ── (c) seed the four shipped archetypes (write-once; guarded like on-conflict-do-nothing) ────────
update public.module_types
   set slot_cost = 1, stats_json = '{"attack": 10}'::jsonb
 where id = 'autocannon_battery' and stats_json = '{}'::jsonb;

update public.module_types
   set slot_cost = 1, stats_json = '{"evasion": 3, "speed_mult_bonus": 0.1}'::jsonb
 where id = 'vector_thruster_kit' and stats_json = '{}'::jsonb;

update public.module_types
   set slot_cost = 2, stats_json = '{"cargo": 25}'::jsonb
 where id = 'expanded_cargo_lattice' and stats_json = '{}'::jsonb;

update public.module_types
   set slot_cost = 1, stats_json = '{"scan": 8}'::jsonb
 where id = 'deep_scan_sensor_array' and stats_json = '{}'::jsonb;
