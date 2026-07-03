-- Byeharu — EXPLORATION-P11 SLICE B: exploration reward-item catalog entries + the dark capability
-- flag (foundations only — NO gameplay logic, NO RPC, NO table, NOTHING client-reachable).
--
-- (1) Exploration rewards reuse the EXISTING item catalog + player_inventory path pirate loot uses
--     (0039/0040/0041): no new inventory table, no new depositor. reward_grant stays the sole
--     depositor — its item validation is catalog-driven (`exists (select 1 from item_types …)`,
--     0040:78; same in inventory_deposit, 0039:81), so it recognizes the new ids with NO code change.
-- (2) The docs/ACTIVITIES.md §3 exploration reward classes — "data / shards / blueprint fragments /
--     artifact cores" — become EXACTLY FOUR catalog items. Two classes already have exact catalog
--     matches seeded in 0039 and reserved by ACTIVITIES.md §5 for precisely these later progression
--     drops: `blueprint_fragment` (progression, rare) and `artifact_core` (progression, epic).
--     Re-adding them under exploration-specific ids would duplicate catalog concepts, so they are
--     REUSED, and only the two missing classes are seeded here:
--       · scan_data     — the "data" class   (common bulk scan yield; category 'data' — the class
--                         name the ACTIVITIES.md row uses; category is unconstrained Reference/Config
--                         metadata with no code consumer)
--       · anomaly_shard — the "shards" class (uncommon; named from the exploration ownership row's
--                         "anomalies"; deliberately NOT captain_memory_shard, which is
--                         captain-progression material — a different concept)
--     Exploration reward set = { scan_data, anomaly_shard, blueprint_fragment, artifact_core }.
--     More variants are additive later. Smallest closed set covering the documented classes.
-- (3) Capability flag `exploration_enabled = false` — the standard server-authoritative dark gate
--     (0070/0071 idiom, same as trade_market_enabled/trade_relief_enabled). NO RPC exists yet; the
--     flag simply exists dark. EVERY exploration RPC added in later slices MUST check it FIRST and
--     reject-before-any-read (no ship/row read, no lock, no write) while it is false — UI hiding is
--     never the only control. This migration does not flip any flag true.
--
-- RLS/grants — verified, not assumed: item_types rows inherit the table-wide public-read posture
-- ("item_types_public_read" for select using (true) + grant select to anon, authenticated —
-- 0039:23–25); game_config rows likewise ("game_config_public_read" — 0003:13–15). The items are
-- inert without any exploration RPC. No function is created here, so no execute-surface relock is
-- needed (the relock pattern applies only when a new function default-grants — 0054 precedent).
--
-- Ownership unchanged (docs/SYSTEM_BOUNDARIES.md §1): item_types and game_config remain
-- Reference/Config (admin/migration sole writer, public read-only). No doc contradiction arises —
-- SYSTEM_BOUNDARIES enumerates dark gates only inside per-system rows (none exists for Exploration
-- yet; its system row arrives with its tables in a later slice), so no boundaries edit this step.

-- ── 1) the two missing exploration reward classes (0039 seeding idiom; idempotent) ────────────────
insert into public.item_types (item_id, name, category, rarity) values
  ('scan_data',     'Scan Data',     'data',     'common'),
  ('anomaly_shard', 'Anomaly Shard', 'material', 'uncommon')
on conflict (item_id) do nothing;

-- ── 2) the dark capability gate (OFF; no writer/reader exists yet) ────────────────────────────────
insert into public.game_config (key, value, description) values
  ('exploration_enabled', 'false',
   'EXPLORATION-P11: server-authoritative dark gate for the Exploration activity. OFF until the '
   'feature is explicitly enabled by the owner. Every exploration RPC must check this FIRST and '
   'reject-before-any-read while false; the UI surface stays hidden independently (fails closed '
   'both sides).')
on conflict (key) do nothing;
