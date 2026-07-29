import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// TYPED-ZONE MINING SUCCESSORS (slice 7) — structural guards. This is the first slice that WRITES
// rows to a live gameplay table, so the guards are about what those rows must not be:
//   * never ACTIVE — leg_zone_hits filters on status alone and ignores zone_kind, so an active
//     "mining" zone would be a pirate ambush region around every ore field;
//   * never a COPY of a reward payload — two authorities for a payout is how a migration
//     double-grants;
//   * never an INVENTED footprint — the radius must be the one the game already uses.
// Run: `npx playwright test zoneMiningSuccessors.spec.ts`.

const here = dirname(fileURLToPath(import.meta.url))
const repo = join(here, '..')
const migration = readFileSync(
  join(repo, 'supabase', 'migrations', '20260618000280_typed_zone_mining_successors.sql'),
  'utf8',
)
const pirate = readFileSync(
  join(repo, 'supabase', 'migrations', '20260618000233_pirate_intercept_danger_zones.sql'),
  'utf8',
)
const v2 = readFileSync(
  join(repo, 'supabase', 'migrations', '20260618000279_typed_zone_effect_dispatch_v2.sql'),
  'utf8',
)

// ── the trap this slice exists around ───────────────────────────────────────────────────────────
test('PRECONDITION: leg_zone_hits really does filter on status alone, with no zone_kind filter', () => {
  const start = pirate.indexOf('create or replace function public.pirate_intercept_leg_zone_hits')
  const body = pirate.slice(start, pirate.indexOf('$$;', start))
  expect(body).toMatch(/where z\.status = 'active'/)
  // if this ever gains a zone_kind filter the whole "must be inactive" rationale changes
  expect(body).not.toMatch(/zone_kind/)
})

test('every successor is created INACTIVE — never live geometry', () => {
  expect(migration).toMatch(/'inactive'\s*\)/)
  expect(migration).not.toMatch(/,\s*'active'\s*\)\s*;/)
  // and the assert is a real count comparison, not a comment
  expect(migration).toMatch(/the ACTIVE zone count moved/)
  expect(migration).toMatch(/a NEW zone is active/)
})

test('the migration captures a pre-image so "no live geometry added" is provable', () => {
  expect(migration).toMatch(/create temporary table _tz0280_before/)
  expect(migration).toMatch(/where status = 'active'/)
})

// ── no invented footprint ───────────────────────────────────────────────────────────────────────
test('the footprint is the documented interaction radius, not a new constant', () => {
  expect(migration).toMatch(/cfg_num\('mining_extract_radius'\)/)
  // it refuses to run if that radius is not configured, rather than inventing one
  expect(migration).toMatch(/the footprint would have to be invented/)
  // the same ST_Buffer idiom zone geometry already uses
  expect(migration).toMatch(/st_buffer\(public\.st_makepoint\(v_f\.space_x, v_f\.space_y\), v_radius, 32\)/)
})

// ── no second authority for payouts ─────────────────────────────────────────────────────────────
test('the mining effect REFERENCES its field and copies no reward payload', () => {
  expect(migration).toMatch(/mining_field_id\s+uuid not null unique references public\.mining_fields \(id\)/)
  expect(migration).not.toMatch(/reward_bundle_json/)
  expect(migration).toMatch(/that is a second authority/)
})

test('backfilled successors are behaviour-neutral', () => {
  expect(migration).toMatch(/yield_multiplier double precision not null default 1/)
  expect(migration).toMatch(/a backfilled successor carries a non-neutral yield/)
})

// ── correctness of the pairing ──────────────────────────────────────────────────────────────────
test('zone/field pairing is exact by construction, never re-joined on a truncatable name', () => {
  // danger_zones.name is CHECKed to 60 chars, so a join on the derived name could collide
  expect(migration).toMatch(/left\('Mining: ' \|\| v_f\.name, 60\)/)
  expect(migration).toMatch(/returning id into v_zone/)
  expect(migration).not.toMatch(/join src on/)
})

test('the zone_kind widen discovers the old constraint rather than guessing its name', () => {
  expect(migration).toMatch(/from pg_constraint con/)
  expect(migration).toMatch(/pg_get_constraintdef\(con\.oid\) ilike '%zone_kind%'/)
  expect(migration).toMatch(/execute format\('alter table public\.danger_zones drop constraint %I', v_name\)/)
  // a widen can only admit — assert no existing row fell outside
  expect(migration).toMatch(/an existing zone_kind falls outside the widened set/)
})

test('widening identity does not make identity dispatch anything', () => {
  expect(migration).toMatch(/it still dispatches nothing/)
  // V2 stays mining-blind; a mining effect would need a V3. Scoped to the FUNCTION BODY, which is
  // what 0280 actually asserts via pg_get_functiondef — the V2 migration file legitimately mentions
  // "mining_yield" as the fixture for its unknown-effect-type case.
  const start = v2.indexOf('create function public.typed_zone_effect_dispatch_v2(')
  const end = v2.indexOf('revoke execute on function public.typed_zone_effect_dispatch_v2', start)
  expect(v2.slice(start, end)).not.toMatch(/mining/i)
  expect(migration).toMatch(/V2 mentions mining — V2 is immutable/)
})

// ── dark + fail-closed ──────────────────────────────────────────────────────────────────────────
test('it lands dark and the point rows keep authority', () => {
  expect(migration).toMatch(/'typed_zone_mining_runtime_enabled',\s*'false'::jsonb/)
  expect(migration).toMatch(/the mining runtime reads the successor table/)
  // no existing runtime function is re-created
  expect(migration).not.toMatch(/create or replace function/i)
})

test('the new table is fail-closed', () => {
  expect(migration).toMatch(/alter table public\.zone_effect_mining enable row level security/)
  expect(migration).toMatch(/revoke all on table public\.zone_effect_mining from anon, authenticated/)
  expect(migration).not.toMatch(/create policy .* on public\.zone_effect_mining/)
})

test('only ACTIVE mining fields get a successor', () => {
  expect(migration).toMatch(/where is_active/)
  expect(migration).toMatch(/active fields but % successors/)
})
