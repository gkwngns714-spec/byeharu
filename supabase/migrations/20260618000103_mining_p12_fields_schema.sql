-- Byeharu — MINING-P12 SLICE B: mining domain schema — hidden mining_fields + per-extraction
-- mining_extractions (tables + seed + RLS ONLY; no RPC, no processor, no client path; the feature
-- stays fully DARK behind mining_enabled=false from 0102 — NOTHING can write these tables until the
-- slice-C command exists).
--
-- Mirrors the exploration schema slice 0098 (structure, idioms, coordinate convention, RLS
-- posture), deviating ONLY where the recon decisions require it (MINING_P12_RECON.local.md §8):
--
-- (1) FIELDS ARE HIDDEN — server-only read, fail-closed by construction (0098 posture verbatim).
--     mining_fields is migration-seeded static world data with NO runtime writer and NO public
--     read: a field's coordinates and composition must never be client-readable before the player
--     has extracted from it. RLS is ENABLED with NO policies at all and NO grant to
--     anon/authenticated; future SECURITY DEFINER mining functions reach it as owner. The read
--     surface (slice E) reveals only fields the player has extracted from.
-- (2) REPEATABILITY — THE deliberate deviation from 0098: mining_extractions has NO
--     unique (player_id, field_id). Extraction is inherently repeatable (recon decision 2), so
--     each extraction is its OWN row; idempotency lives in the slice-C command's receipt
--     convention (main_ship_space_command_receipts), and pacing is a per-(player, field) cooldown
--     the slice-C writer enforces from the latest extraction's created_at against
--     cfg_num('mining_extract_cooldown_seconds') (0102) — hence the (player_id, field_id,
--     created_at desc) index below.
-- (3) v1 reward semantics: each field carries a deterministic reward_bundle_json in the
--     pending-bundle shape the engine already validates ({ "items": [ { "item_id", "quantity" } ] }
--     — 0040) — ITEMS-ONLY, no metal scalar (recon decision 3): mining rewards land in item
--     inventory via reward_grant('mining', extraction_id, …) reusing the EXISTING catalog rows
--     ore / crystal / artifact_core (0039); NOTHING lands in base_resources (that would add a
--     second landing path to the Base-owned economy scalars). Item quantities stay in the 0098
--     seed magnitude (1–3 per entry). Weighted/depleting yields are an additive later change.
-- (4) PENDING → SECURED lifecycle exactly as exploration's as-built discoveries model it
--     (0099/0100): pending_bundle_json snapshot + secured_at (NULL = pending; set ONLY by the
--     slice-D securing processor) + main_ship_id (the extracting ship; FK on delete set null with
--     the 0100 resolver fallback). NO FORFEITURE in this slice: a pending extraction simply WAITS
--     (the 0100 posture) — destruction semantics for pending mining value are a future product
--     decision, deliberately not invented here.
--
-- COORDINATES — copied EXACTLY from the OSN open-space model via 0098, no second convention:
--   column names space_x / space_y (0054:33–36); type double precision; finite-only via the
--   `<> 'NaN'::double precision` CHECK idiom and the immutable world sanity envelope
--   [-10000, 10000]^2, verbatim from 0055:56–63 / 0098:54–57. Seeds use integer-grid values well
--   inside the envelope (the 0070 command canonicalizes targets to the integer grid), spread
--   near/far like the 0098 sites and distinct from them, so every field is a legal, reachable
--   open-space target.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): mining_fields → Reference/Config
-- (admin/migration; no runtime writer; server-only read). mining_extractions → Mining (its
-- forthcoming slice-C command inserts · slice-D processor sets secured_at; owner-read). No new
-- cross-system edge; nothing reads or writes either table yet. No flag flipped; 0001–0102 unedited.

-- ── 1) mining_fields — hidden static world data (server-only) ─────────────────────────────────────
create table public.mining_fields (
  id                 uuid primary key default gen_random_uuid(),
  name               text not null unique,           -- natural seed key (0002 world-seed idiom)
  space_x            double precision not null,
  space_y            double precision not null,
  reward_bundle_json jsonb not null,
  -- lets a bad seed be disabled without deleting rows (no destructive cleanup of world data);
  -- future readers/processors must treat is_active=false as nonexistent.
  is_active          boolean not null default true,
  created_at         timestamptz not null default now(),

  -- the pending-bundle payload must be a jsonb OBJECT ({ items[] } shape; 0040 validates the
  -- interior on deposit)
  check (jsonb_typeof(reward_bundle_json) = 'object'),

  -- coordinate finiteness + world envelope, verbatim idiom from 0055/0098
  check (space_x <> 'NaN'::double precision and space_x <> 'Infinity'::double precision and space_x <> '-Infinity'::double precision
         and space_x >= -10000 and space_x <= 10000),
  check (space_y <> 'NaN'::double precision and space_y <> 'Infinity'::double precision and space_y <> '-Infinity'::double precision
         and space_y >= -10000 and space_y <= 10000)
);

-- 0098 DECISION-1 ASSERTION, reused: RLS enabled with NO policies and NO anon/authenticated grant —
-- there is deliberately no client read path (hidden fields stay hidden until the slice-E read
-- surface reveals ones the player has extracted from). Owner/SECURITY DEFINER access only.
alter table public.mining_fields enable row level security;

comment on table public.mining_fields is
  'MINING-P12: hidden static resource fields (migration-seeded; no runtime writer). SERVER-ONLY: '
  'RLS enabled with no client policies/grants — coordinates/composition are never client-readable '
  'before extraction. reward_bundle_json is the deterministic ITEMS-ONLY pending bundle '
  '({items[]}; never base_resources scalars) reward_grant(''mining'', …) deposits on securing. '
  'Coordinates use the OSN open-space convention (space_x/space_y double precision, finite, '
  'within [-10000,10000]^2).';

-- ── 2) mining_extractions — per-extraction state (Mining-owned; REPEATABLE — no unique pair) ─────
create table public.mining_extractions (
  id                  uuid primary key default gen_random_uuid(),
  player_id           uuid not null references auth.users (id) on delete cascade,
  field_id            uuid not null references public.mining_fields (id) on delete cascade,
  -- the ship that performed the extraction and carries the unsecured yield; NULL only for
  -- deleted-ship rows — the slice-D processor falls back to the player's canonical main ship
  -- (the 0100/0081 resolver idiom).
  main_ship_id        uuid references public.main_ship_instances (main_ship_id) on delete set null,
  -- snapshot of the field's bundle at extraction time — PENDING until secured (0099 idiom). Fresh
  -- table ⇒ no '{}'::jsonb migration-validity default is needed (the 0099 shim existed only for
  -- pre-existing rows); the sole writer ALWAYS snapshots a real field bundle.
  pending_bundle_json jsonb not null,
  secured_at          timestamptz,
  -- created_at is the cooldown anchor: the slice-C writer compares the latest (player, field) row
  -- against cfg_num('mining_extract_cooldown_seconds').
  created_at          timestamptz not null default now(),

  check (jsonb_typeof(pending_bundle_json) = 'object')
);

-- cooldown lookup: latest extraction per (player, field) (recon decision 2)
create index mining_extractions_cooldown_idx
  on public.mining_extractions (player_id, field_id, created_at desc);
-- player history ordering (the 0098 discoveries player-index idiom; serves the slice-E read surface)
create index mining_extractions_player_idx
  on public.mining_extractions (player_id, created_at desc);

-- Own-row read only (0015 reward_grants_select_own idiom, via 0098); NO insert/update/delete
-- policy and NO write grant — the sole writers are the Mining system's forthcoming SECURITY
-- DEFINER command (slice C: inserts) and securing processor (slice D: sets secured_at), both DARK
-- behind mining_enabled=false. NOTHING writes this table yet.
alter table public.mining_extractions enable row level security;
create policy "mining_extractions_select_own" on public.mining_extractions
  for select using (player_id = auth.uid());
grant select on public.mining_extractions to authenticated;

comment on table public.mining_extractions is
  'MINING-P12: per-extraction ledger — REPEATABLE (no unique (player_id, field_id); one row per '
  'extraction; pacing = the slice-C cooldown from the latest created_at). Sole writers = the '
  'Mining system''s forthcoming command (slice C, inserts) and securing processor (slice D, sets '
  'secured_at); nothing writes it yet — feature DARK behind mining_enabled. pending_bundle_json '
  'is the field snapshot; secured_at NULL = pending. Players read only their own rows.';

comment on column public.mining_extractions.pending_bundle_json is
  'Snapshot of the field''s reward bundle ({items[]}) taken at extraction time — PENDING, not '
  'deposited. Secured via reward_grant(''mining'', extraction_id, …) by the slice-D processor.';
comment on column public.mining_extractions.secured_at is
  'NULL = pending. Set ONLY by the slice-D securing processor (never by the extract writer).';
comment on column public.mining_extractions.main_ship_id is
  'The ship that performed the extraction and carries the unsecured yield. NULL only for '
  'deleted-ship rows; the slice-D processor falls back to the player''s canonical main ship.';

-- ── 3) seed fields (idempotent by the natural name key, 0002/0098 idiom; inside the OSN envelope) ─
-- Composition (recon decision 3, items-only): ore in EVERY field (common), crystal in some
-- (uncommon), artifact_core in exactly ONE field at quantity 1 (rare). Quantities match the 0098
-- per-item magnitude (1–3). Coordinates: integer grid, near/far spread, distinct from the 0098
-- exploration sites.
insert into public.mining_fields (name, space_x, space_y, reward_bundle_json) values
  ('Sparse Ore Belt',       1500,   900,
   '{"items": [{"item_id": "ore",     "quantity": 2}]}'::jsonb),
  ('Ferrous Drift Field',  -2200,  1600,
   '{"items": [{"item_id": "ore",     "quantity": 3}]}'::jsonb),
  ('Crystalline Shelf',     2800, -2300,
   '{"items": [{"item_id": "ore",     "quantity": 2},
               {"item_id": "crystal", "quantity": 1}]}'::jsonb),
  ('Deep Vein Cluster',    -3500, -2700,
   '{"items": [{"item_id": "ore",     "quantity": 3},
               {"item_id": "crystal", "quantity": 2}]}'::jsonb),
  ('Singularity Scar',      4200,  3100,
   '{"items": [{"item_id": "ore",           "quantity": 2},
               {"item_id": "crystal",       "quantity": 1},
               {"item_id": "artifact_core", "quantity": 1}]}'::jsonb)
on conflict (name) do nothing;

-- No function is created here → no execute-surface relock needed (0054 precedent, via 0098). No
-- flag is added, read, or flipped; every mining capability remains server-rejected (0102 gate).
