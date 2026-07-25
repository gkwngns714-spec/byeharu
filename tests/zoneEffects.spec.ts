import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  EMPTY_PIRATE_INTERCEPT_OVERRIDES,
  PIRATE_INTERCEPT_FIELD_LABELS,
  PIRATE_INTERCEPT_OVERRIDE_FIELDS,
  ZONE_EFFECT_KINDS,
  ZONE_EFFECT_LABELS,
  isInheritedPirateInterceptEffect,
  projectPirateInterceptOverrides,
  validatePirateInterceptOverrides,
} from '../src/features/worldeditor/zoneEffects'

// TYPED-ZONE EFFECTS (slice 1). Three proof layers:
//   1. AUTHORING SEMANTICS — inheriting is the neutral default, and the advisory validator mirrors
//      the zone_effect_pirate_intercept CHECK constraints.
//   2. AUTHORITY BOUNDARY — src/ must hold NO runtime knob-coalescing and NO risk mathematics. Those
//      are versioned PostgreSQL functions; a second implementation here would compete with the one
//      that decides real player outcomes.
//   3. MIGRATION STRUCTURE — 0273 lands dark, effects live in a side table, the table is fail-closed,
//      and identity is never welded to effect presence by a constraint.
// Run: `npx playwright test zoneEffects.spec.ts`.

const here = dirname(fileURLToPath(import.meta.url))
const repo = join(here, '..')
const effects = readFileSync(join(repo, 'src', 'features', 'worldeditor', 'zoneEffects.ts'), 'utf8')
const migration = readFileSync(
  join(repo, 'supabase', 'migrations', '20260618000273_typed_zone_effect_foundation.sql'),
  'utf8',
)

// ── 1. authoring semantics ──────────────────────────────────────────────────────────────────────
test('a fresh effect inherits everything — the backfill shape is behaviour-neutral', () => {
  expect(isInheritedPirateInterceptEffect(EMPTY_PIRATE_INTERCEPT_OVERRIDES)).toBe(true)
  for (const field of PIRATE_INTERCEPT_OVERRIDE_FIELDS) {
    expect(EMPTY_PIRATE_INTERCEPT_OVERRIDES[field]).toBeNull()
  }
})

test('setting ANY single knob makes the effect no longer purely inherited', () => {
  for (const field of PIRATE_INTERCEPT_OVERRIDE_FIELDS) {
    const value = field === 'stat_reference' ? 200 : 0.5
    expect(
      isInheritedPirateInterceptEffect({ ...EMPTY_PIRATE_INTERCEPT_OVERRIDES, [field]: value }),
    ).toBe(false)
  }
})

test('projection carries overrides verbatim and never a resolved value', () => {
  const overrides = { ...EMPTY_PIRATE_INTERCEPT_OVERRIDES, base_risk: 0.5, stat_reference: 200 }
  expect(projectPirateInterceptOverrides(overrides)).toEqual(overrides)
  // exactly the five override keys — nothing resolved, nothing extra
  expect(Object.keys(projectPirateInterceptOverrides(overrides)).sort()).toEqual(
    [...PIRATE_INTERCEPT_OVERRIDE_FIELDS].sort(),
  )
})

test('every override field has an owner-facing label', () => {
  for (const field of PIRATE_INTERCEPT_OVERRIDE_FIELDS) {
    expect(PIRATE_INTERCEPT_FIELD_LABELS[field]).toBeTruthy()
    expect(PIRATE_INTERCEPT_FIELD_LABELS[field]).not.toMatch(/_/)
  }
})

// ── 2. validation mirrors the CHECK constraints ──────────────────────────────────────────────────
test('an all-null override set is always valid — inheriting can never be a validation error', () => {
  expect(validatePirateInterceptOverrides(EMPTY_PIRATE_INTERCEPT_OVERRIDES)).toEqual([])
})

test('the four unit knobs are rejected outside [0,1]', () => {
  for (const field of ['base_risk', 'min_risk', 'max_risk', 'exposure_floor'] as const) {
    expect(validatePirateInterceptOverrides({ ...EMPTY_PIRATE_INTERCEPT_OVERRIDES, [field]: 1.5 })).toHaveLength(1)
    expect(validatePirateInterceptOverrides({ ...EMPTY_PIRATE_INTERCEPT_OVERRIDES, [field]: -0.1 })).toHaveLength(1)
    expect(validatePirateInterceptOverrides({ ...EMPTY_PIRATE_INTERCEPT_OVERRIDES, [field]: 0 })).toEqual([])
    expect(validatePirateInterceptOverrides({ ...EMPTY_PIRATE_INTERCEPT_OVERRIDES, [field]: 1 })).toEqual([])
  }
})

test('stat_reference must be strictly positive', () => {
  expect(validatePirateInterceptOverrides({ ...EMPTY_PIRATE_INTERCEPT_OVERRIDES, stat_reference: 0 })).toHaveLength(1)
  expect(validatePirateInterceptOverrides({ ...EMPTY_PIRATE_INTERCEPT_OVERRIDES, stat_reference: -1 })).toHaveLength(1)
  expect(validatePirateInterceptOverrides({ ...EMPTY_PIRATE_INTERCEPT_OVERRIDES, stat_reference: 0.001 })).toEqual([])
})

test('an inverted risk band is rejected, but only when BOTH ends are set', () => {
  expect(
    validatePirateInterceptOverrides({ ...EMPTY_PIRATE_INTERCEPT_OVERRIDES, min_risk: 0.8, max_risk: 0.2 }),
  ).toEqual([{ field: null, message: 'Minimum risk cannot exceed maximum risk.' }])
  expect(validatePirateInterceptOverrides({ ...EMPTY_PIRATE_INTERCEPT_OVERRIDES, min_risk: 0.8 })).toEqual([])
  expect(validatePirateInterceptOverrides({ ...EMPTY_PIRATE_INTERCEPT_OVERRIDES, max_risk: 0.2 })).toEqual([])
  expect(
    validatePirateInterceptOverrides({ ...EMPTY_PIRATE_INTERCEPT_OVERRIDES, min_risk: 0.2, max_risk: 0.8 }),
  ).toEqual([])
})

test('NaN and both infinities are rejected for EVERY knob, never silently coerced', () => {
  for (const field of PIRATE_INTERCEPT_OVERRIDE_FIELDS) {
    for (const bad of [NaN, Infinity, -Infinity]) {
      expect(
        validatePirateInterceptOverrides({ ...EMPTY_PIRATE_INTERCEPT_OVERRIDES, [field]: bad }),
        `${field} must reject ${bad}`,
      ).toHaveLength(1)
    }
  }
})

// ── 3. the authority boundary ───────────────────────────────────────────────────────────────────
test('src/ holds NO runtime knob-coalescing and NO risk mathematics — the database owns those', () => {
  expect(effects).not.toMatch(/resolvePirateKnobs|computePirateRisk/)
  // the coalescing shape and the risk curve must not reappear under any name
  expect(effects).not.toMatch(/\?\?\s*globals?\./)
  expect(effects).not.toMatch(/Math\.(min|max)\s*\(/)
  expect(effects).not.toMatch(/stat_reference\s*\+/)
})

test('the module is PURE — no React, no DOM, no storage, no network', () => {
  expect(effects).not.toMatch(/\bfrom 'react'|useState|useEffect|localStorage|document\.|fetch\(|supabase/)
})

test('effects are named for BEHAVIOUR, not zone identity, and never branch on zone_kind', () => {
  expect(ZONE_EFFECT_KINDS).toContain('pirate_intercept')
  for (const kind of ZONE_EFFECT_KINDS) expect(ZONE_EFFECT_LABELS[kind]).toBeTruthy()
  expect(effects).not.toMatch(/zone_kind\s*===/)
})

// ── 4. migration structure ──────────────────────────────────────────────────────────────────────
test('the migration lands DARK: two flags seeded false, no runtime function created or replaced', () => {
  expect(migration).toMatch(/'typed_zone_authoring_enabled',\s*'false'::jsonb/)
  expect(migration).toMatch(/'typed_zone_pirate_intercept_runtime_enabled',\s*'false'::jsonb/)
  expect(migration).not.toMatch(/create or replace function/i)
  expect(migration).not.toMatch(/update public\.danger_zones|delete from public\.danger_zones/i)
})

test('the runtime flag names the executable capability, not the zone identity', () => {
  expect(migration).toMatch(/typed_zone_pirate_intercept_runtime_enabled/)
  expect(migration).not.toMatch(/typed_zone_pirate_runtime_enabled/)
})

test('effect config lives in a side table, never as columns on the core zone row', () => {
  expect(migration).toMatch(/create table public\.zone_effect_pirate_intercept/)
  expect(migration).toMatch(/zone_id\s+uuid primary key references public\.danger_zones \(id\) on delete cascade/)
  expect(migration).not.toMatch(/alter table public\.danger_zones\s+add column/i)
})

test('the table rejects NaN and the infinities in SQL, not merely in the advisory validator', () => {
  expect(migration).toMatch(/constraint zone_effect_pirate_intercept_finite/)
  for (const field of PIRATE_INTERCEPT_OVERRIDE_FIELDS) {
    // `x = x` is false only for NaN; the infinity comparisons cover the rest
    expect(migration, `${field} needs a NaN guard`).toMatch(
      new RegExp(`${field}\\s*=\\s*${field}`),
    )
  }
  expect(migration).toMatch(/<>\s*'Infinity'::double precision/)
  expect(migration).toMatch(/<>\s*'-Infinity'::double precision/)
})

test('identity is NOT welded to effect presence by any constraint or trigger', () => {
  // the backfill is a one-time parity step; a standing invariant would re-fuse kind to behaviour
  expect(migration).not.toMatch(/create trigger/i)
  expect(migration).not.toMatch(/check\s*\([^)]*zone_kind/i)
})

test('the new table is fail-closed: RLS on, no policy, no client grant', () => {
  expect(migration).toMatch(/alter table public\.zone_effect_pirate_intercept enable row level security/)
  expect(migration).toMatch(/revoke all on table public\.zone_effect_pirate_intercept from anon, authenticated/)
  expect(migration).not.toMatch(/create policy .* on public\.zone_effect_pirate_intercept/)
  expect(migration).not.toMatch(/grant (select|insert|update|delete).* on (table )?public\.zone_effect_pirate_intercept/i)
})
