import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  ZONE_EFFECT_BEHAVIOR_VERSION_V1,
  ZONE_EFFECT_CONTRACT_VERSION_V1,
  ZONE_EFFECT_DISPATCH_FUNCTION_V1,
  ZONE_EFFECT_RISK_FUNCTION_V1,
  ZONE_EFFECT_SELECTION_POLICY_V1,
  ZONE_EFFECT_SUPPORTED_EFFECT_TYPES_V1,
  ZONE_EFFECT_SUPPORTED_EVENT_TYPES_V1,
} from '../src/features/worldeditor/zoneEffectDispatchContract'

// TYPED-ZONE DISPATCH V1 (slice 2). The decision logic is a versioned PostgreSQL function; the
// TypeScript side is a CONTRACT ONLY. These tests therefore guard two things a type-checker cannot:
//   1. that the contract file stays free of executable decision logic — no second authority;
//   2. that the SQL actually implements the contract the TypeScript declares (names, versions,
//      supported unions, selection policy, purity, and immutability of V1).
// The behavioural matrix itself runs against real Postgres in
// scripts/typed-zone-dispatch-proof.sql — it cannot be meaningfully faked here.
// Run: `npx playwright test zoneEffectDispatchContract.spec.ts`.

const here = dirname(fileURLToPath(import.meta.url))
const repo = join(here, '..')
const contract = readFileSync(
  join(repo, 'src', 'features', 'worldeditor', 'zoneEffectDispatchContract.ts'),
  'utf8',
)
const migration = readFileSync(
  join(repo, 'supabase', 'migrations', '20260618000274_typed_zone_effect_dispatch_v1.sql'),
  'utf8',
)
const proof = readFileSync(join(repo, 'scripts', 'typed-zone-dispatch-proof.sql'), 'utf8')

// ── 1. the contract file holds NO executable decision logic ─────────────────────────────────────
test('the contract is types and constants only — no functions, no branching, no arithmetic', () => {
  const code = contract.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')
  expect(code).not.toMatch(/\bfunction\b/)
  expect(code).not.toMatch(/=>/)
  expect(code).not.toMatch(/\bif\b|\bfor\b|\bwhile\b|\bswitch\b/)
  expect(code).not.toMatch(/Math\./)
  // every export is a type, an interface, or a pinned const
  for (const line of code.split('\n').filter((l) => l.startsWith('export '))) {
    expect(line, `unexpected export: ${line}`).toMatch(/^export (type|interface|const) /)
  }
})

test('the contract is PURE — no React, no DOM, no storage, no network, no imports at all', () => {
  const code = contract.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')
  expect(code).not.toMatch(/\bfrom 'react'|useState|localStorage|document\.|fetch\(|supabase/)
  expect(code.match(/^import /gm) ?? []).toHaveLength(0)
})

// ── 2. the declared vocabulary ──────────────────────────────────────────────────────────────────
test('V1 registers exactly one event type and one effect type', () => {
  expect(ZONE_EFFECT_SUPPORTED_EVENT_TYPES_V1).toEqual(['fleet_leg_traversal'])
  expect(ZONE_EFFECT_SUPPORTED_EFFECT_TYPES_V1).toEqual(['pirate_intercept'])
})

test('contract and behavior versions are pinned to 1', () => {
  expect(ZONE_EFFECT_CONTRACT_VERSION_V1).toBe(1)
  expect(ZONE_EFFECT_BEHAVIOR_VERSION_V1).toBe(1)
})

test('the selection policy is named data, matching 0233 exposure-desc then zone_id-asc', () => {
  expect(ZONE_EFFECT_SELECTION_POLICY_V1).toBe('max_exposure_then_zone_id_asc')
})

// ── 3. the SQL implements what the TypeScript declares ──────────────────────────────────────────
test('both versioned functions named by the contract actually exist in 0274', () => {
  expect(migration).toMatch(new RegExp(`create function public\\.${ZONE_EFFECT_DISPATCH_FUNCTION_V1}\\(`))
  expect(migration).toMatch(new RegExp(`create function public\\.${ZONE_EFFECT_RISK_FUNCTION_V1}\\(`))
})

test('V1 is immutable: the migration CREATEs, never CREATE OR REPLACEs', () => {
  expect(migration).not.toMatch(/create or replace function/i)
  // and it refuses to run if a V1 already exists, rather than silently redefining it
  expect(migration).toMatch(/V1 is immutable; ship a _v2 sibling instead/)
})

test('the dispatcher is declared pure at the SQL level', () => {
  const start = migration.indexOf(`create function public.${ZONE_EFFECT_DISPATCH_FUNCTION_V1}(`)
  expect(start).toBeGreaterThan(-1)
  const header = migration.slice(start, start + 400)
  expect(header).toMatch(/\bimmutable\b/)
  expect(header).toMatch(/\bparallel safe\b/)
  expect(header).toMatch(/\bsecurity invoker\b/)
})

test('the dispatcher reads no state and rolls no dice', () => {
  const start = migration.indexOf(`create function public.${ZONE_EFFECT_DISPATCH_FUNCTION_V1}(`)
  const end = migration.indexOf('revoke execute on function public.typed_zone_effect_dispatch_v1', start)
  const body = migration.slice(start, end)
  for (const forbidden of [
    /\bfrom\s+public\.danger_zones\b/i,
    /\bfrom\s+public\.zone_effect_pirate_intercept\b/i,
    /\bgame_config\b/i,
    /\bcfg_num\(/i,
    /\bcfg_bool\(/i,
    /\brandom\(/i,
    /\bnow\(\)/i,
    /\bclock_timestamp\b/i,
    /\binsert\s+into\b/i,
    /\bupdate\s+public\./i,
    /\bdelete\s+from\b/i,
    /\bst_intersects\b/i,
  ]) {
    expect(body, `dispatcher body must not contain ${forbidden}`).not.toMatch(forbidden)
  }
})

test('neither V1 function is client-executable', () => {
  expect(migration).toMatch(
    /revoke execute on function public\.typed_zone_effect_dispatch_v1\(jsonb\) from public, anon, authenticated/,
  )
  expect(migration).toMatch(/revoke execute on function public\.typed_zone_pirate_intercept_risk_v1[\s\S]{0,220}from public, anon, authenticated/)
  expect(migration).not.toMatch(/grant execute on function public\.typed_zone_/)
})

test('0274 adds no table, no flag and no runtime wiring', () => {
  expect(migration).not.toMatch(/create table/i)
  expect(migration).not.toMatch(/insert into public\.game_config/i)
  expect(migration).not.toMatch(/alter table/i)
})

test('every error code the contract declares is produced somewhere in the SQL', () => {
  const codes = [
    'invalid_contract_version',
    'invalid_event',
    'invalid_runtime_config',
    'invalid_candidate',
    'duplicate_zone_id',
    'duplicate_effect_type',
    'unsupported_event_type',
    'unsupported_effect_type',
    'invalid_resolved_effect_config',
  ]
  for (const code of codes) {
    expect(migration, `${code} must be reachable in the dispatcher`).toMatch(new RegExp(`'${code}'`))
  }
})

// ── 4. the behavioural proof covers what matters ────────────────────────────────────────────────
test('the disposable proof asserts parity, overlap, determinism and every typed failure', () => {
  for (const marker of [
    'TZD_PASS_HAPPY_PATH_PARITY',
    'TZD_PASS_HIGHEST_EXPOSURE_WINS',
    'TZD_PASS_EQUAL_EXPOSURE_LOWEST_UUID',
    'TZD_PASS_INPUT_ORDER_INVARIANT',
    'TZD_PASS_DETERMINISTIC',
    'TZD_PASS_INACTIVE_IGNORED',
    'TZD_PASS_EMPTY_EFFECT_SET_INERT',
    'TZD_PASS_TYPED_FAILURES',
    'TZD_PASS_RESOLVED_CONFIG_DISTINCT',
    'TZD_PASS_IDENTITY_DOES_NOT_DISPATCH',
    'TZD_PASS_EDGE_PARITY',
  ]) {
    expect(proof, `proof must emit ${marker}`).toMatch(marker)
  }
  // parity is COMPUTED against the deployed function, not asserted in the abstract
  expect(proof).toMatch(/pirate_intercept_compute_risk\(/)
})
