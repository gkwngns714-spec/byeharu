-- Byeharu — CAPTAIN-P15 SLICE A: the dark capability flag + the captain catalog table + starter
-- seeds (foundations only — NO gameplay logic, NO RPC, NO instances/assignment/receipt tables,
-- NO adapter change, NO frontend, NOTHING client-writable).
--
-- Phase 15 "Captain instances + assignment" (ROADMAP :90 — "effects via
-- `calculate_expedition_stats`") follows the P13/P14 slice template (0107–0110 / 0111–0116).
-- LOCKED DESIGN DECISIONS (owner-directed 2026-07-04; recorded in docs/DEV_LOG.md this slice):
--   1. CATALOG COLUMNS are id / name / specialization / description / stats_json. Unlike
--      `module_types.slot_type` (0107 — deliberately unconstrained display metadata),
--      `specialization` carries a CHECK ('combat','trade','exploration','mining','support')
--      BECAUSE it is not free metadata: it is the captain analogue of the module slot_type
--      tradeoff CASE required by ROADMAP law 4 (capacity + tradeoffs, never a plain sum), to be
--      consumed by the adapter in a later slice — a constrained mechanism input, not display
--      copy. A new specialization later is an additive forward-only catalog migration that
--      extends the CHECK.
--   2. STATS ENCODING reuses the ONE shared stat vocabulary (0042 base_stats_json / 0111
--      stats_json): `stats_json jsonb not null default '{}'` with the SAME keys the adapter
--      already reads — attack/defense/repair/cargo/scan/mining/evasion plus optional
--      speed_mult_bonus (0115:173–180). ONE stat pipeline; no parallel captain vocabulary.
--   3. NO slot_cost column: every assigned captain occupies exactly ONE captain slot.
--      `main_ship_instances.captain_slots` (0043:58; starter_frigate seeds 2) is a HEADCOUNT,
--      not a point budget — the later adapter slice's hard cap is count(*) <= captain_slots
--      (reject, never clamp — the 0044:112–115 idiom), never a Σ slot_cost sum.
--   4. FLAG — `captain_assignment_enabled` seeded 'false', the exact 0097/0102/0107/0111 idiom,
--      including the server-side `feature_disabled` rejection posture for every future RPC.
--      This migration does not flip any flag true.
--
-- (a) Capability flag `captain_assignment_enabled = false` — the standard server-authoritative
--     dark gate (0070/0071 idiom, same as exploration_enabled/mining_enabled/
--     module_crafting_enabled/module_fitting_enabled). NO RPC exists yet; the flag simply exists
--     dark. EVERY captain RPC added in later slices MUST check it FIRST and
--     reject-before-any-read (no row read, no lock, no write) while it is false — UI hiding is
--     never the only control. This migration does not flip any flag true.
-- (b) `captain_types` is catalog identity + the INERT mechanism inputs only (specialization +
--     stats_json). Nothing reads either yet — their first code consumer is the later Phase-15
--     adapter slice (`create or replace` of calculate_expedition_stats in a new migration, the
--     0115 idiom). No instances table, no assignment table, no receipts, no writer function.
-- (c) SEED MAGNITUDES: captains COMPLEMENT fitting, never replace it — Phase 16 progression
--     (consumes inventory) is the growth path, so base numbers stay modest. Every seed is
--     clearly weaker than the same-role module in the 0111 band (autocannon attack 10 ·
--     cargo lattice cargo 25 · sensor array scan 8 · thruster evasion 3 + speed 0.1):
--     combat → attack 4 · trade → cargo 8 · exploration → scan 3 · mining → mining 4 (no module
--     seeds mining; 4 sits below the smallest module contribution band) · support → repair 3.
--     Conservative, not final balance (the 0043 hull-seed posture).
--
-- RLS/grants — verified, not assumed: the new table copies the Reference/Config catalog posture
-- verbatim from item_types (0039:23–25) / support_craft_types (0042:32–36) / module_types
-- (0107:80–84) — RLS enabled, ONE public-read select policy, `grant select to anon,
-- authenticated`, NO insert/update/delete policy and NO write grant → clients cannot mutate;
-- only migrations / service_role (admin) write. The game_config row inherits the table-wide
-- public-read posture ("game_config_public_read" — 0003:13–15). No function is created here, so
-- no execute-surface relock is needed (0054 precedent). The seeds are inert: no RPC, no reader,
-- no writer references them yet.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced in the SAME step — the 0098/0103/0107 precedent
-- for table-creating slices): §1 matrix gains `captain_types` under the new **Captain** system
-- (catalog/config — seeded by migration only, NO runtime writer; public read-only). NO §2
-- Captain system row yet — no writer/function exists until the instances slice, and a doc must
-- never describe state that isn't real (the 0111:57–58 no-Fitting-row-yet posture); the deferral
-- is recorded in DEV_LOG.

-- ── (a) the dark capability gate (OFF / inert; no writer/reader exists yet) ───────────────────────
insert into public.game_config (key, value, description) values
  ('captain_assignment_enabled', 'false',
   'CAPTAIN-P15: server-authoritative dark gate for captain assignment (Captain). OFF until the '
   'feature is explicitly enabled by the owner. Every captain RPC must check this FIRST '
   'and reject-before-any-read while false; the UI surface stays hidden independently (fails '
   'closed both sides).')
on conflict (key) do nothing;

-- ── (b) captain_types — the captain archetype catalog (Captain; public read-only) ────────────────
create table public.captain_types (
  id             text primary key,
  name           text not null,
  specialization text not null
                   check (specialization in ('combat','trade','exploration','mining','support')),
  description    text not null,
  stats_json     jsonb not null default '{}'::jsonb,
  created_at     timestamptz not null default now()
);

alter table public.captain_types enable row level security;
-- Public read-only; NO insert/update/delete policy and NO write grant → clients cannot mutate.
-- Only migrations / service_role (admin) write (the 0039/0042/0107 catalog posture).
create policy "captain_types_public_read" on public.captain_types for select using (true);
grant select on public.captain_types to anon, authenticated;

comment on column public.captain_types.specialization is
  'CAPTAIN-P15: the constrained tradeoff archetype (the module slot_type CASE analogue, per '
  'ROADMAP law 4 — never a plain sum). To be consumed by the Phase-15 adapter slice; nothing '
  'reads it yet. Extending the set is an additive forward-only migration on the CHECK.';
comment on column public.captain_types.stats_json is
  'CAPTAIN-P15: assigned stat contributions in the ONE shared vocabulary '
  '(attack/defense/repair/cargo/scan/mining/evasion + optional speed_mult_bonus — 0115:173–180). '
  'First consumer arrives with the Phase-15 adapter slice — nothing reads this yet.';

-- ── (c) starter seeds — five captain types, one per specialization (idempotent) ──────────────────
-- Names/copy match the existing catalog tone (0042 support craft / 0107 modules). Magnitudes are
-- deliberately below the same-role module band (header decision (c)) — captains complement
-- fitting; Phase 16 progression is the growth path.
insert into public.captain_types (id, name, specialization, description, stats_json) values
  ('gunnery_veteran',     'Gunnery Veteran',       'combat',
   'A scarred line officer who squeezes real firepower out of any mounted battery.',
   '{"attack": 4}'::jsonb),
  ('trade_broker',        'Licensed Trade Broker', 'trade',
   'Knows every port ledger trick and stows cargo tighter than the manual allows.',
   '{"cargo": 8}'::jsonb),
  ('survey_cartographer', 'Survey Cartographer',   'exploration',
   'Charts the sensor noise other crews discard into usable survey data.',
   '{"scan": 3}'::jsonb),
  ('extraction_foreman',  'Extraction Foreman',    'mining',
   'Runs the rig cycle by ear and never wastes a bite of the seam.',
   '{"mining": 4}'::jsonb),
  ('fleet_quartermaster', 'Fleet Quartermaster',   'support',
   'Keeps hull patches and spare parts moving before anyone has to ask.',
   '{"repair": 3}'::jsonb)
on conflict (id) do nothing;
