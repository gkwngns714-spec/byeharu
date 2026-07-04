-- Byeharu — CAPTAIN-P16 SLICE 1: the dark capability flag for Phase-16 captain progression
-- (flag-only — NO recipe table, NO command, NO writer, NO adapter change, NO frontend, NOTHING
-- client-writable, NO flag flipped true). This is the 0107/0117 flag-seed idiom verbatim: the
-- capability exists dark, inert, with no reader/writer referencing it yet.
--
-- Phase 16 "Captain progression (consumes inventory)" (ROADMAP :91) is the captain analogue of
-- module crafting (Phase 13 / 0109 `craft_module`).
-- SELF-APPROVED LOCKED DESIGN DECISION (owner-directed 2026-07-04; recorded in docs/DEV_LOG.md
-- this slice so later slices are grounded):
--   1. MECHANISM = captain RECRUITMENT that CONSUMES `player_inventory`. A dark, idempotent
--      command spends a per-captain-type item recipe through the Inventory `inventory_spend`
--      leaf (0039) and mints ONE `captain_instances` row through the already-built
--      `captains_mint_instance` leaf (0118 — built explicitly for "Phase-16 progression consuming
--      inventory"). This is the truest reading of ROADMAP law 3 (Progression = the
--      inventory-consuming acquisition system): "inventory is the bridge".
--   2. REUSE, NO NEW WRITER. Recruitment NEVER touches `player_inventory` / `inventory_ledger` /
--      `captain_instances` directly — ONLY through the two pre-built leaves. No second writer to
--      `captain_instances` (its sole writer stays `captains_mint_instance`), no schema change to
--      it, and no adapter change (the 0122 stats feed reads the minted rows unchanged). Edges are
--      all DOWNWARD (Progression command → Inventory `inventory_spend` · Captain
--      `captains_mint_instance` · Reference/Config catalog + this flag), acyclic — the exact
--      0109 `craft_module` fan-out shape.
--   3. LATER SLICES (all gated on THIS flag, reject-before-any-read while false): a
--      Production-owned recruitment receipts table + its private writer + a two-layer public
--      wrapper command (the 0109/0113 two-layer idiom, PLAYER-scoped request_id idempotency),
--      plus a per-captain-type recipe catalog. A NEW progression-owned table with its OWN sole
--      writer carries any recruitment bookkeeping that would otherwise need a second writer to an
--      existing table — read DOWNWARD by the adapter, never a second writer.
--   4. FLAG — `captain_progression_enabled` seeded 'false', the exact 0097/0102/0107/0117 idiom,
--      including the server-side `feature_disabled` rejection posture for every future RPC. This
--      migration does not flip any flag true.
--
-- THIS SLICE IS FLAG-ONLY AND INERT: no RPC, no recipe table, no writer, no reader references the
-- flag yet — mirroring the 0117 "flag exists dark, no RPC yet" posture. The game_config row
-- inherits the table-wide public-read posture ("game_config_public_read" — 0003:13-15). No
-- function/table is created here, so no execute-surface relock is needed (0054 precedent).
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md): a pure `game_config` key seed changes NO architectural
-- fact — `game_config` is already Reference/Config public-read (§1 matrix), and a new key row adds
-- no table, no writer, no cross-system edge. SYSTEM_BOUNDARIES is intentionally UNTOUCHED this
-- slice (the 0117-analogue deferral: no §2 Captain-progression system row until a writer/function
-- actually exists — a doc must never describe state that isn't real, the 0111:57-58 posture). The
-- deferral is recorded in DEV_LOG.

-- ── the dark capability gate (OFF / inert; no writer/reader exists yet) ───────────────────────────
insert into public.game_config (key, value, description) values
  ('captain_progression_enabled', 'false',
   'CAPTAIN-P16: server-authoritative dark gate for Phase-16 captain progression — captain '
   'recruitment that consumes `player_inventory` (the 0109 craft_module analogue). OFF until the '
   'feature is explicitly enabled by the owner. Every Phase-16 RPC must check this FIRST '
   'and reject-before-any-read while false; the UI surface stays hidden independently (fails '
   'closed both sides).')
on conflict (key) do nothing;
