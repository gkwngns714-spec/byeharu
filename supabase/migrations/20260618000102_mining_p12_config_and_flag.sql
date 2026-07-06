-- Byeharu — MINING-P12 SLICE A: the dark capability flag + mining tunables (foundations only —
-- NO gameplay logic, NO RPC, NO table, NO catalog rows, NOTHING client-reachable).
--
-- Phase 12 Mining mirrors the exploration 0097–0101 five-slice template (see
-- MINING_P12_RECON.local.md §8–§9, decisions self-approved 2026-07-04):
--   slice B adds the hidden mining_fields + per-extraction mining_extractions schema, slice C the
--   dark command_mining_extract write path (S2 lock + receipts + osn_distance proximity + the
--   cooldown below), slice D the flag-ignoring securing processor, slice E the read surface.
--   All of them build on the three keys seeded here and stay server-rejected while
--   mining_enabled='false'.
--
-- (1) NO item_types rows are seeded (unlike 0097): recon decision 3 — mining rewards reuse the
--     EXISTING catalog entries `ore` / `crystal` (0039:30–31) and `artifact_core` (0039:38) via
--     reward_grant('mining', extraction_id, …), whose item validation is catalog-driven (0040:78)
--     and whose source_type is already permitted ('mining' is in the 0096 CHECK; reward_grants.
--     source_type itself is unconstrained text, 0015:9). NOTHING lands in base_resources — that
--     would add a second landing path to the Base-owned economy scalars. The trade_goods 'ore'
--     (0073:42) is the SEPARATE Trade Market cargo catalog and is not touched.
-- (2) Capability flag `mining_enabled = false` — the standard server-authoritative dark gate
--     (0070/0071 idiom, same as exploration_enabled/trade_market_enabled). NO RPC exists yet; the
--     flag simply exists dark. EVERY mining RPC added in later slices MUST check it FIRST and
--     reject-before-any-read (no ship/row read, no lock, no write) while it is false — UI hiding is
--     never the only control. This migration does not flip any flag true.
-- (3) Tunables follow the game_config philosophy (balance without redeploy; 0099 radius precedent):
--     · mining_extract_radius = 750 — same order as exploration_scan_radius (0099:76); the slice-C
--       command measures it with the existing osn_distance leaf (0099:43 — "Mining later").
--     · mining_extract_cooldown_seconds = 300 — per-(player, field) repeat pacing (recon decision
--       2: mining is repeatable, so the server enforces a cooldown from the latest extraction's
--       created_at; exploration needed none because unique(player_id, site_id) makes discovery
--       one-shot).
--
-- RLS/grants — verified, not assumed: game_config rows inherit the table-wide public-read posture
-- ("game_config_public_read" — 0003:13–15). The keys are inert without any mining RPC. No function
-- is created here, so no execute-surface relock is needed (0054 precedent).
--
-- Ownership unchanged (docs/SYSTEM_BOUNDARIES.md §1): game_config remains Reference/Config
-- (admin/migration sole writer, public read-only). No boundaries edit this step — the Mining
-- system row arrives with its tables in slice B (the 0097 precedent: dark gates are enumerated
-- inside per-system rows, and no Mining system row exists yet).

-- ── the dark capability gate + tunables (OFF / inert; no writer/reader exists yet) ────────────────
insert into public.game_config (key, value, description) values
  ('mining_enabled', 'false',
   'MINING-P12: server-authoritative dark gate for the Mining activity. OFF until the feature is '
   'explicitly enabled by the owner. Every mining RPC must check this FIRST and '
   'reject-before-any-read while false; the UI surface stays hidden independently (fails closed '
   'both sides).'),
  ('mining_extract_radius', '750',
   'MINING-P12: maximum osn_distance (world units) between a settled in-space main ship and an '
   'active mining_fields row for command_mining_extract to extract from it (slice C).'),
  ('mining_extract_cooldown_seconds', '300',
   'MINING-P12: minimum seconds between two extractions by the same player from the same '
   'mining_fields row, enforced server-side from the latest extraction''s created_at (slice C). '
   'Mining is repeatable (unlike one-shot exploration discovery); this is the pacing control.')
on conflict (key) do nothing;
