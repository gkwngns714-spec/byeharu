import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// TYPED-ZONE EXPLORATION SUCCESSORS (slice 8). The structure mirrors mining deliberately, but the
// point of the slice is what must NOT be shared: exploration gets its own gate, its own config key
// and its own successor set. Sharing any of those because two systems happen to use point tables
// would couple two independent gameplay decisions.
// Run: `npx playwright test zoneExplorationSuccessors.spec.ts`.

const here = dirname(fileURLToPath(import.meta.url))
const repo = join(here, '..')
const m = (f: string) => readFileSync(join(repo, 'supabase', 'migrations', f), 'utf8')
const exploration = m('20260618000281_typed_zone_exploration_successors.sql')
const mining = m('20260618000280_typed_zone_mining_successors.sql')

// ── independence from mining ────────────────────────────────────────────────────────────────────
test('exploration has its OWN flag and never reuses the mining one', () => {
  expect(exploration).toMatch(/'typed_zone_exploration_runtime_enabled',\s*'false'::jsonb/)
  // it may ASSERT mining's flag is undisturbed, but must never insert or update it
  expect(exploration).not.toMatch(/insert into public\.game_config[\s\S]{0,200}typed_zone_mining_runtime_enabled/)
  expect(exploration).not.toMatch(/update public\.game_config/i)
  expect(exploration).toMatch(/mining's flag was disturbed|mining''s flag was disturbed/)
})

test('exploration reads its OWN radius key, so retuning one never moves the other', () => {
  expect(exploration).toMatch(/cfg_num\('exploration_scan_radius'\)/)
  expect(exploration).not.toMatch(/mining_extract_radius/)
  expect(mining).toMatch(/cfg_num\('mining_extract_radius'\)/)
  expect(mining).not.toMatch(/exploration_scan_radius/)
})

test('no zone may carry BOTH point-successor effects', () => {
  expect(exploration).toMatch(/a zone carries BOTH point-successor effects/)
})

// ── the same load-bearing safety as mining ──────────────────────────────────────────────────────
test('every successor is INACTIVE and the active zone set is proven unchanged', () => {
  expect(exploration).toMatch(/create temporary table _tz0281_before/)
  expect(exploration).toMatch(/'inactive'\)/)
  expect(exploration).toMatch(/the ACTIVE zone count moved/)
  expect(exploration).toMatch(/a NEW zone is active/)
})

test('the footprint is documented, not invented, and it refuses to guess', () => {
  expect(exploration).toMatch(/the footprint would have to be invented/)
  expect(exploration).toMatch(/st_buffer\(public\.st_makepoint\(v_s\.space_x, v_s\.space_y\), v_radius, 32\)/)
})

test('it references its site and copies no reward payload', () => {
  expect(exploration).toMatch(
    /exploration_site_id\s+uuid not null unique references public\.exploration_sites \(id\)/,
  )
  expect(exploration).not.toMatch(/reward_bundle_json/)
  expect(exploration).toMatch(/copies a reward payload/)
})

test('pairing is exact by construction, not re-joined on a truncatable name', () => {
  expect(exploration).toMatch(/left\('Exploration: ' \|\| v_s\.name, 60\)/)
  expect(exploration).toMatch(/returning id into v_zone/)
  expect(exploration).not.toMatch(/join src on/)
})

test('only ACTIVE sites get a successor, and backfills are neutral', () => {
  expect(exploration).toMatch(/where is_active/)
  expect(exploration).toMatch(/discovery_multiplier\s+double precision not null default 1/)
  expect(exploration).toMatch(/a backfilled successor carries a non-neutral multiplier/)
})

test('it lands dark, adds no runtime, and is fail-closed', () => {
  expect(exploration).not.toMatch(/create or replace function/i)
  expect(exploration).toMatch(/alter table public\.zone_effect_exploration enable row level security/)
  expect(exploration).toMatch(/revoke all on table public\.zone_effect_exploration from anon, authenticated/)
  expect(exploration).not.toMatch(/create policy .* on public\.zone_effect_exploration/)
})

test('it depends on slice 7 for the widened zone_kind rather than re-widening it', () => {
  expect(exploration).toMatch(/slice 7 \(0280\) must land first — it widens zone_kind/)
  expect(exploration).not.toMatch(/add constraint danger_zones_zone_kind_check/)
})
