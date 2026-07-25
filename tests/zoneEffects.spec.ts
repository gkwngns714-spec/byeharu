import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  EMPTY_PIRATE_EFFECT,
  PIRATE_RISK_GLOBAL_DEFAULTS,
  ZONE_EFFECT_KINDS,
  ZONE_EFFECT_LABELS,
  computePirateRisk,
  isInheritedPirateEffect,
  resolvePirateKnobs,
  validatePirateEffect,
  type PirateEffectConfig,
} from '../src/features/worldeditor/zoneEffects'

// TYPED-ZONE EFFECTS (slice 1). Three proof layers:
//   1. PARITY — an all-null config resolves to the globals and reproduces the 0233 risk curve, so the
//      foundation is behaviour-neutral by construction.
//   2. VALIDATION — the advisory validator mirrors the zone_effect_pirate CHECK constraints exactly.
//   3. STRUCTURAL — the module stays pure, the client formula stays in step with the SQL it mirrors,
//      and the migration really is dark (no runtime function reads the new table).
// Run: `npx playwright test zoneEffects.spec.ts`.

const here = dirname(fileURLToPath(import.meta.url))
const repo = join(here, '..')
const effects = readFileSync(join(repo, 'src', 'features', 'worldeditor', 'zoneEffects.ts'), 'utf8')
const migration = readFileSync(
  join(repo, 'supabase', 'migrations', '20260618000273_typed_zone_effect_foundation.sql'),
  'utf8',
)

// ── 1. parity ───────────────────────────────────────────────────────────────────────────────────
test('a fresh effect inherits everything — the backfill shape is behaviour-neutral', () => {
  expect(isInheritedPirateEffect(EMPTY_PIRATE_EFFECT)).toBe(true)
  expect(resolvePirateKnobs(EMPTY_PIRATE_EFFECT)).toEqual(PIRATE_RISK_GLOBAL_DEFAULTS)
})

test('null means INHERIT for every knob, independently', () => {
  const globals = { base_risk: 0.4, min_risk: 0.05, max_risk: 0.8, exposure_floor: 0.2, stat_reference: 200 }
  for (const key of Object.keys(globals) as (keyof PirateEffectConfig)[]) {
    const config: PirateEffectConfig = { ...EMPTY_PIRATE_EFFECT, [key]: key === 'stat_reference' ? 999 : 0.11 }
    const resolved = resolvePirateKnobs(config, globals)
    expect(resolved[key]).toBe(key === 'stat_reference' ? 999 : 0.11)
    for (const other of Object.keys(globals) as (keyof PirateEffectConfig)[]) {
      if (other !== key) expect(resolved[other]).toBe(globals[other])
    }
  }
})

test('the risk curve reproduces the 0233 formula across the proof sweep', () => {
  const k = PIRATE_RISK_GLOBAL_DEFAULTS
  // the same (stats, exposure) pairs the disposable SQL proof drives through the real function
  for (const [stats, exposure] of [[0, 0], [10, 0.05], [60, 0.25], [120, 0.5], [400, 0.9], [5000, 1]]) {
    const expected = Math.max(
      k.min_risk,
      Math.min(
        k.max_risk,
        k.base_risk *
          (k.stat_reference / (k.stat_reference + Math.max(stats, 0))) *
          Math.min(1, Math.max(k.exposure_floor, exposure)),
      ),
    )
    expect(computePirateRisk(k, stats, exposure)).toBe(expected)
  }
})

test('the curve is clamped by the band and floors negative stats at zero', () => {
  const k = PIRATE_RISK_GLOBAL_DEFAULTS
  expect(computePirateRisk(k, 1e9, 0)).toBe(k.min_risk) // vanishing falloff → min
  expect(computePirateRisk({ ...k, min_risk: 0.5 }, 1e9, 0)).toBe(0.5)
  expect(computePirateRisk({ ...k, base_risk: 1, max_risk: 0.3 }, 0, 1)).toBe(0.3) // capped at max
  expect(computePirateRisk(k, -50, 1)).toBe(computePirateRisk(k, 0, 1)) // negative stats floored
})

test('exposure below the floor is lifted to the floor, and above 1 is capped', () => {
  const k = PIRATE_RISK_GLOBAL_DEFAULTS
  expect(computePirateRisk(k, 120, 0)).toBe(computePirateRisk(k, 120, k.exposure_floor))
  expect(computePirateRisk(k, 120, 5)).toBe(computePirateRisk(k, 120, 1))
})

// ── 2. validation mirrors the CHECK constraints ──────────────────────────────────────────────────
test('an all-null config is always valid — inheriting can never be a validation error', () => {
  expect(validatePirateEffect(EMPTY_PIRATE_EFFECT)).toEqual([])
})

test('the four unit knobs are rejected outside [0,1]', () => {
  for (const field of ['base_risk', 'min_risk', 'max_risk', 'exposure_floor'] as const) {
    expect(validatePirateEffect({ ...EMPTY_PIRATE_EFFECT, [field]: 1.5 })).toHaveLength(1)
    expect(validatePirateEffect({ ...EMPTY_PIRATE_EFFECT, [field]: -0.1 })).toHaveLength(1)
    expect(validatePirateEffect({ ...EMPTY_PIRATE_EFFECT, [field]: 0 })).toEqual([])
    expect(validatePirateEffect({ ...EMPTY_PIRATE_EFFECT, [field]: 1 })).toEqual([])
  }
})

test('stat_reference must be strictly positive', () => {
  expect(validatePirateEffect({ ...EMPTY_PIRATE_EFFECT, stat_reference: 0 })).toHaveLength(1)
  expect(validatePirateEffect({ ...EMPTY_PIRATE_EFFECT, stat_reference: -1 })).toHaveLength(1)
  expect(validatePirateEffect({ ...EMPTY_PIRATE_EFFECT, stat_reference: 0.001 })).toEqual([])
})

test('an inverted risk band is rejected, but only when BOTH ends are set', () => {
  expect(validatePirateEffect({ ...EMPTY_PIRATE_EFFECT, min_risk: 0.8, max_risk: 0.2 })).toEqual([
    { field: null, message: 'Minimum risk cannot exceed maximum risk.' },
  ])
  expect(validatePirateEffect({ ...EMPTY_PIRATE_EFFECT, min_risk: 0.8 })).toEqual([])
  expect(validatePirateEffect({ ...EMPTY_PIRATE_EFFECT, max_risk: 0.2 })).toEqual([])
  expect(validatePirateEffect({ ...EMPTY_PIRATE_EFFECT, min_risk: 0.2, max_risk: 0.8 })).toEqual([])
})

test('NaN and Infinity are rejected, never silently coerced', () => {
  expect(validatePirateEffect({ ...EMPTY_PIRATE_EFFECT, base_risk: NaN })).toHaveLength(1)
  expect(validatePirateEffect({ ...EMPTY_PIRATE_EFFECT, stat_reference: Infinity })).toHaveLength(1)
})

// ── 3. structural ───────────────────────────────────────────────────────────────────────────────
test('the module is PURE — no React, no DOM, no storage, no network', () => {
  expect(effects).not.toMatch(/\bfrom 'react'|useState|useEffect|localStorage|document\.|fetch\(|supabase/)
})

test('effects are COMPOSABLE: a kind registry, never a switch on zone identity', () => {
  expect(ZONE_EFFECT_KINDS.length).toBeGreaterThan(0)
  for (const kind of ZONE_EFFECT_KINDS) expect(ZONE_EFFECT_LABELS[kind]).toBeTruthy()
  // no zone_kind branching lives here — identity does not decide behaviour
  expect(effects).not.toMatch(/zone_kind\s*===/)
})

test('the client defaults stay in step with the SQL fallbacks they mirror', () => {
  // 0233's pirate_intercept_compute_risk coalesces to these literals; drift would break parity.
  expect(PIRATE_RISK_GLOBAL_DEFAULTS).toEqual({
    base_risk: 0.35,
    min_risk: 0.02,
    max_risk: 0.9,
    exposure_floor: 0.15,
    stat_reference: 120,
  })
})

test('the migration lands DARK: two flags seeded false and no runtime function reads the table', () => {
  expect(migration).toMatch(/'typed_zone_authoring_enabled',\s*'false'::jsonb/)
  expect(migration).toMatch(/'typed_zone_pirate_runtime_enabled',\s*'false'::jsonb/)
  // it must not (re)create any runtime function
  expect(migration).not.toMatch(/create or replace function/i)
  // and it must not write to the live world
  expect(migration).not.toMatch(/update public\.danger_zones|delete from public\.danger_zones/i)
})

test('effect config lives in a side table, never as columns on the core zone row', () => {
  expect(migration).toMatch(/create table public\.zone_effect_pirate/)
  expect(migration).toMatch(/zone_id\s+uuid primary key references public\.danger_zones \(id\) on delete cascade/)
  expect(migration).not.toMatch(/alter table public\.danger_zones\s+add column/i)
})

test('the new table is fail-closed: RLS on, no policy, no client grant', () => {
  expect(migration).toMatch(/alter table public\.zone_effect_pirate enable row level security/)
  expect(migration).toMatch(/revoke all on table public\.zone_effect_pirate from anon, authenticated/)
  expect(migration).not.toMatch(/create policy .* on public\.zone_effect_pirate/)
  expect(migration).not.toMatch(/grant (select|insert|update|delete).* on (table )?public\.zone_effect_pirate/i)
})
