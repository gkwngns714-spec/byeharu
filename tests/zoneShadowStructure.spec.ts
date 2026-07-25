import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// TYPED-ZONE SHADOW (slice 3) — structural guards. The behavioural comparison necessarily runs
// against real geometry in scripts/typed-zone-shadow-proof.sql; what CAN be asserted here without a
// database are the properties that make that comparison SAFE to run at all:
//   * the shadow never calls the evaluator that rolls, writes and can mint an encounter;
//   * neither new function writes;
//   * no cutover is wired — the live path stays the sole authority;
//   * the candidate builder resolves globals exactly as 0233 does, so the diff is not rigged.
// Run: `npx playwright test zoneShadowStructure.spec.ts`.

const here = dirname(fileURLToPath(import.meta.url))
const repo = join(here, '..')
const migration = readFileSync(
  join(repo, 'supabase', 'migrations', '20260618000275_typed_zone_pirate_shadow_v1.sql'),
  'utf8',
)
const proof = readFileSync(join(repo, 'scripts', 'typed-zone-shadow-proof.sql'), 'utf8')

test('the shadow NEVER calls the evaluator that rolls, writes and can mint an encounter', () => {
  const start = migration.indexOf('create function public.typed_zone_pirate_shadow_compare_v1')
  expect(start).toBeGreaterThan(-1)
  const end = migration.indexOf('revoke execute on function public.typed_zone_pirate_shadow_compare_v1', start)
  const body = migration.slice(start, end)
  expect(body).not.toMatch(/pirate_intercept_evaluate_leg/)
  // it reproduces the decision from the evaluator's PURE parts instead
  expect(body).toMatch(/pirate_intercept_leg_zone_hits/)
  expect(body).toMatch(/pirate_intercept_compute_risk/)
  // and encodes the evaluator's own inline selection verbatim
  expect(body).toMatch(/order by exposure_fraction desc, zone_id asc/)
})

test('neither new function writes, and the shadow rolls no dice', () => {
  for (const fn of [
    'typed_zone_pirate_candidates_v1',
    'typed_zone_pirate_shadow_compare_v1',
  ]) {
    const start = migration.indexOf(`create function public.${fn}`)
    expect(start, `${fn} must exist`).toBeGreaterThan(-1)
    const end = migration.indexOf(`revoke execute on function public.${fn}`, start)
    const body = migration.slice(start, end)
    expect(body, `${fn} must not write`).not.toMatch(/\binsert\s+into\b|\bupdate\s+public\.|\bdelete\s+from\b|\btruncate\b/i)
    expect(body, `${fn} must not roll`).not.toMatch(/\brandom\(/i)
  }
})

test('no cutover: the migration re-creates no 0233 function and flips no flag', () => {
  expect(migration).not.toMatch(/create or replace function public\.pirate_intercept/i)
  expect(migration).not.toMatch(/update public\.game_config/i)
  expect(migration).not.toMatch(/insert into public\.game_config/i)
})

test('the revision column is additive, defaulted and trigger-free', () => {
  expect(migration).toMatch(/add column if not exists revision integer not null default 0/)
  expect(migration).not.toMatch(/create trigger/i)
})

test('the candidate builder mirrors the 0233 literal fallbacks exactly, so the diff is not rigged', () => {
  const start = migration.indexOf('create function public.typed_zone_pirate_candidates_v1')
  const end = migration.indexOf('revoke execute on function public.typed_zone_pirate_candidates_v1', start)
  const body = migration.slice(start, end)
  for (const [key, fallback] of [
    ['pirate_intercept_base_risk', '0.35'],
    ['pirate_intercept_min_risk', '0.02'],
    ['pirate_intercept_max_risk', '0.90'],
    ['pirate_intercept_exposure_floor', '0.15'],
    ['pirate_intercept_stat_reference', '120'],
  ] as const) {
    expect(body, `${key} must fall back to ${fallback}`).toMatch(
      new RegExp(`cfg_num\\('${key}'\\),\\s*${fallback.replace('.', '\\.')}`),
    )
  }
})

test('the builder emits the effect set from ROW EXISTENCE, never from zone_kind', () => {
  const start = migration.indexOf('create function public.typed_zone_pirate_candidates_v1')
  const end = migration.indexOf('revoke execute on function public.typed_zone_pirate_candidates_v1', start)
  const body = migration.slice(start, end)
  expect(body).toMatch(/from public\.zone_effect_pirate_intercept e/)
  expect(body).not.toMatch(/where\s+z\.zone_kind\s*=/i)
})

test('neither new function is client-executable', () => {
  for (const fn of ['typed_zone_pirate_candidates_v1', 'typed_zone_pirate_shadow_compare_v1']) {
    expect(migration).toMatch(new RegExp(`revoke execute on function public\\.${fn}[\\s\\S]{0,260}from public, anon, authenticated`))
  }
  expect(migration).not.toMatch(/grant execute on function public\.typed_zone_/)
})

test('the proof proves write-freedom by COUNTING rows, not by reading the source', () => {
  expect(proof).toMatch(/select count\(\*\) into v_before from public\.pirate_intercepts/)
  expect(proof).toMatch(/select count\(\*\) into v_after from public\.pirate_intercepts/)
  expect(proof).toMatch(/TZS_FAIL_WRITES/)
})

test('the proof distinguishes a configured divergence from a planner fault', () => {
  expect(proof).toMatch(/risk_diverged_by_override/)
  expect(proof).toMatch(/TZS_PASS_OVERRIDE_ATTRIBUTED/)
  // …and proves parity returns once the override is cleared
  expect(proof).toMatch(/clearing the override did not restore parity/)
})

test('the proof exercises real overlapping geometry, not literals', () => {
  expect(proof).toMatch(/st_makepolygon/)
  expect(proof).toMatch(/TZS_PASS_REAL_GEOMETRY_AGREEMENT/)
  expect(proof).toMatch(/rollback;/)
})
