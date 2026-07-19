import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  validateLocationDraft,
  type ValidationContext,
} from '../src/features/worldeditor/locationValidation'
import type { MapLocation } from '../src/features/map/mapTypes'
import type { LocationDraftPayload } from '../src/features/worldeditor/locationDraftTypes'
import { forkEdit } from '../src/features/worldeditor/locationDraftModel'

// WORLD EDITOR V1B-2 — STRUCTURAL GUARDS for the validator (source-text + behavioral proofs):
//   1. PURITY — locationValidation.ts performs ZERO IO (no supabase/fetch/rpc/table/localStorage,
//      no React/DOM) and imports ONLY the sanctioned pure modules.
//   2. DETERMINISM — same payload + context ⇒ deep-equal report, every time.
//   3. IMMUTABILITY — deep-frozen inputs validate without a throw and without a single mutation.
//   4. FLAG-ONLY — out-of-domain values are reported, NEVER clamped (no-hidden-clamping law).
// Run: `npx playwright test locationValidationGuards.spec.ts`.

const WE_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'src', 'features', 'worldeditor')

// ── 1. purity guard (source text) ───────────────────────────────────────────────────────────────────
test('locationValidation.ts contains no supabase/fetch/rpc/table/localStorage access and no React/DOM', () => {
  const src = readFileSync(join(WE_DIR, 'locationValidation.ts'), 'utf8')
  expect(src, 'must not touch supabase').not.toMatch(/supabase/i)
  expect(src, 'must not fetch').not.toMatch(/\bfetch\s*\(/)
  expect(src, 'must not call an RPC').not.toMatch(/\.rpc\s*\(/)
  expect(src, 'must not open a table query').not.toMatch(/\.from\s*\(/)
  expect(src, 'must not write').not.toMatch(/\.(insert|upsert|update|delete)\s*\(/)
  expect(src, 'must not touch storage').not.toMatch(/localStorage|sessionStorage/)
  expect(src, 'must not import react').not.toMatch(/from 'react'/)
  expect(src, 'must not touch the DOM').not.toMatch(/\b(document|window)\./)

  // import allowlist — ONLY the sanctioned pure modules (shared predicate, shared distance, the enum
  // authority, and type-only contracts). Anything else is a boundary violation.
  const specifiers = [...src.matchAll(/from '([^']+)'/g)].map((m) => m[1])
  expect(specifiers.length).toBeGreaterThan(0)
  const allowed = [
    '../map/openSpaceTransform',
    '../../game/movement/travelPreview',
    './locationEnums',
    './locationDraftTypes',
    '../map/mapTypes',
  ]
  for (const s of specifiers)
    expect(allowed, `unexpected import in locationValidation.ts: ${s}`).toContain(s)
})

// ── fixtures for the behavioral guards ──────────────────────────────────────────────────────────────
const livePayload = (): MapLocation => ({
  id: 'loc-1',
  name: 'Aurelia',
  location_type: 'trade_outpost',
  x: 100,
  y: 100,
  base_difficulty: 5,
  reward_tier: 3,
  activity_type: 'trade_visit',
  min_power_required: 0,
  is_public: true,
  status: 'active',
  territory_radius: 400,
})

/** A payload that trips MANY rules at once — the worst honest input the guards run through. */
const messyPayload = (): LocationDraftPayload => ({
  name: 'Aurelia Prime Station',
  location_type: 'safe_zone',
  activity_type: 'none',
  x: 20_000,
  y: -30_000,
  reward_tier: 1.5,
  base_difficulty: -1,
  min_power_required: 0,
  is_public: true,
  territory_radius: 0,
  status: 'archived',
})

const makeCtx = (): ValidationContext => ({
  liveLocations: [livePayload()],
  sourceStatus: 'source_changed',
  draftMode: forkEdit(livePayload(), 'draft-a', 0).mode,
  otherDrafts: [forkEdit(livePayload(), 'draft-b', 0)],
})

function deepFreeze<T>(value: T): T {
  if (value !== null && typeof value === 'object') {
    for (const v of Object.values(value)) deepFreeze(v)
    Object.freeze(value)
  }
  return value
}

// ── 2. determinism ──────────────────────────────────────────────────────────────────────────────────
test('determinism: identical payload + context produce deep-equal reports on repeat runs', () => {
  const a = validateLocationDraft(messyPayload(), makeCtx())
  const b = validateLocationDraft(messyPayload(), makeCtx())
  expect(a).toEqual(b)
  // and running twice on the SAME instances changes nothing either
  const p = messyPayload()
  const c = makeCtx()
  expect(validateLocationDraft(p, c)).toEqual(validateLocationDraft(p, c))
})

// ── 3. input immutability (deep-frozen inputs: no throw, no mutation) ───────────────────────────────
test('immutability: deep-frozen payload and context validate without throwing and without mutation', () => {
  const p = deepFreeze(messyPayload())
  const c = deepFreeze(makeCtx())
  const before = JSON.stringify({ p, c })
  const report = validateLocationDraft(p, c) // a mutation attempt on frozen input would throw here
  expect(report.issues.length).toBeGreaterThan(0)
  expect(JSON.stringify({ p, c })).toBe(before)
})

// ── 4. flag-only: no rule clamps or rewrites a coordinate ───────────────────────────────────────────
test('no clamping: out-of-bounds coordinates are flagged and keep their EXACT values', () => {
  const p = messyPayload() // x=20000, y=-30000 — both far outside ±10000
  const report = validateLocationDraft(p, makeCtx())
  expect(report.issues.map((i) => i.code)).toContain('coord_out_of_bounds')
  expect(report.publishable).toBe(false)
  expect(p.x).toBe(20_000) // NOT snapped to the edge
  expect(p.y).toBe(-30_000)
  expect(p.territory_radius).toBe(0) // not rewritten to null/positive
  expect(p.status).toBe('archived') // not coerced into the enum
})
