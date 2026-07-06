-- Byeharu — EXPLORATION-P11 SLICE C: exploration domain schema — hidden exploration_sites +
-- per-player exploration_discoveries (tables + seed + RLS ONLY; no RPC, no processor, no client
-- path; the feature stays fully DARK behind exploration_enabled=false from 0097).
--
-- (1) SITES ARE HIDDEN — server-only read, fail-closed by construction. exploration_sites is
--     migration-seeded static world data with NO runtime writer, and — unlike locations/item_types —
--     NO public read: a hidden site's coordinates must never be client-readable before discovery.
--     RLS is ENABLED with NO policies at all and NO grant to anon/authenticated (asserted below);
--     future SECURITY DEFINER exploration functions reach it as owner. Nothing to hide in the UI —
--     the client simply cannot see the table.
-- (2) Per-player discovery state is its own table exploration_discoveries with
--     unique (player_id, site_id). SOLE WRITER = the Exploration system (its future RPC/processor —
--     NOTHING writes it yet). Players read only their own rows (the 0015
--     reward_grants_select_own idiom).
-- (3) v1 reward semantics: each site carries a deterministic reward_bundle_json in the EXACT
--     pending-bundle shape the carrier already transports — { "metal": N, "items": [ { "item_id",
--     "quantity" } ] } (0040/0041) — so the Slice-A activity-agnostic deposit path is reused
--     byte-for-byte with ZERO new roll logic. Weighted "discovery rolls" are an additive later
--     change and, if they come, MUST reuse/extract the combat loot-roll helper as ONE shared leaf,
--     never a copy. Bundles draw ONLY from the Slice-B reward set
--     { scan_data, anomaly_shard, blueprint_fragment, artifact_core } (+ small metal in the 0041
--     combat magnitude range: reward_metal_base=10/wave → sites carry 25–100).
--
-- COORDINATES — copied EXACTLY from the OSN open-space model, no second convention:
--   column names space_x / space_y from main_ship_instances (0054:33–36); type double precision;
--   finite-only via the `<> 'NaN'::double precision` CHECK idiom and the immutable world sanity
--   envelope [-10000, 10000]^2, both verbatim from main_ship_space_movements (0055:56–63) and
--   matching the movement writer's inclusive bounds gate (0057:58–59, 95–96). Seeds use
--   integer-grid values (the 0070 command canonicalizes targets to the integer grid) well inside
--   the envelope, so every site is a legal, reachable open-space target.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): exploration_sites →
-- Reference/Config (admin/migration; no runtime writer; server-only read). exploration_discoveries
-- → Exploration (future RPC/processor; owner-read). No new cross-system edge; nothing reads or
-- writes either table yet. No flag flipped; 0001–0097 unedited.

-- ── 1) exploration_sites — hidden static world data (server-only) ─────────────────────────────────
create table public.exploration_sites (
  id                 uuid primary key default gen_random_uuid(),
  name               text not null unique,           -- natural seed key (0002 world-seed idiom)
  space_x            double precision not null,
  space_y            double precision not null,
  reward_bundle_json jsonb not null,
  -- lets a bad seed be disabled without deleting rows (no destructive cleanup of world data);
  -- future readers/processors must treat is_active=false as nonexistent.
  is_active          boolean not null default true,
  created_at         timestamptz not null default now(),

  -- the pending-bundle payload must be a jsonb OBJECT ({ metal?, items[] } shape; 0040 validates
  -- the interior on deposit)
  check (jsonb_typeof(reward_bundle_json) = 'object'),

  -- coordinate finiteness + world envelope, verbatim idiom from 0055
  check (space_x <> 'NaN'::double precision and space_x <> 'Infinity'::double precision and space_x <> '-Infinity'::double precision
         and space_x >= -10000 and space_x <= 10000),
  check (space_y <> 'NaN'::double precision and space_y <> 'Infinity'::double precision and space_y <> '-Infinity'::double precision
         and space_y >= -10000 and space_y <= 10000)
);

-- DECISION 1 ASSERTION: RLS enabled with NO policies and NO anon/authenticated grant — there is
-- deliberately no client read path (hidden sites stay hidden until a future server function reveals
-- a discovered one). Owner/SECURITY DEFINER access only.
alter table public.exploration_sites enable row level security;

comment on table public.exploration_sites is
  'EXPLORATION-P11: hidden static exploration sites (migration-seeded; no runtime writer). '
  'SERVER-ONLY: RLS enabled with no client policies/grants — coordinates are never client-readable '
  'before discovery. reward_bundle_json is the deterministic pending bundle ({metal?, items[]}) the '
  'engine carrier deposits on home arrival. Coordinates use the OSN open-space convention '
  '(space_x/space_y double precision, finite, within [-10000,10000]^2).';

-- ── 2) exploration_discoveries — per-player discovery state (Exploration-owned) ───────────────────
create table public.exploration_discoveries (
  id            uuid primary key default gen_random_uuid(),
  player_id     uuid not null references auth.users (id) on delete cascade,
  site_id       uuid not null references public.exploration_sites (id) on delete cascade,
  discovered_at timestamptz not null default now(),
  unique (player_id, site_id)
);
create index exploration_discoveries_player_idx
  on public.exploration_discoveries (player_id, discovered_at desc);

-- Own-row read only (0015 reward_grants_select_own idiom); NO insert/update/delete policy and NO
-- write grant — the sole writer is the Exploration system's future SECURITY DEFINER RPC/processor
-- (DARK behind exploration_enabled=false). Nothing writes this table yet.
alter table public.exploration_discoveries enable row level security;
create policy "exploration_discoveries_select_own" on public.exploration_discoveries
  for select using (player_id = auth.uid());
grant select on public.exploration_discoveries to authenticated;

comment on table public.exploration_discoveries is
  'EXPLORATION-P11: per-player site-discovery ledger. Sole writer = the Exploration system''s '
  'future server RPC/processor (nothing writes it yet; feature DARK behind exploration_enabled). '
  'Players read only their own rows.';

-- ── 3) seed sites (idempotent by the natural name key, 0002 idiom; all inside the OSN envelope) ──
-- Bundles draw only from { scan_data, anomaly_shard, blueprint_fragment, artifact_core } (Slice B);
-- metal is calibrated to the 0041-era combat scale (~10–40/wave): common ~25–40, rare 60, epic 100.
insert into public.exploration_sites (name, space_x, space_y, reward_bundle_json) values
  ('Derelict Listening Post',  -1200,   850,
   '{"metal": 25,  "items": [{"item_id": "scan_data",     "quantity": 3}]}'::jsonb),
  ('Shattered Survey Buoy',     2100, -1400,
   '{"metal": 30,  "items": [{"item_id": "scan_data",     "quantity": 2},
                             {"item_id": "anomaly_shard", "quantity": 1}]}'::jsonb),
  ('Anomalous Debris Field',   -2600, -1900,
   '{"metal": 40,  "items": [{"item_id": "anomaly_shard", "quantity": 2}]}'::jsonb),
  ('Silent Foundry Wreck',      3300,  2500,
   '{"metal": 60,  "items": [{"item_id": "scan_data",           "quantity": 2},
                             {"item_id": "blueprint_fragment",  "quantity": 1}]}'::jsonb),
  ('Precursor Vault Signal',   -4100,  3600,
   '{"metal": 100, "items": [{"item_id": "anomaly_shard", "quantity": 1},
                             {"item_id": "artifact_core", "quantity": 1}]}'::jsonb)
on conflict (name) do nothing;

-- No function is created here → no execute-surface relock needed (0054 precedent). No flag is
-- added, read, or flipped; every exploration capability remains server-rejected (0097 gate).
