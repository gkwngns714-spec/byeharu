import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  addableEffects,
  buildZoneEffectPanel,
  emptyEffectSummary,
  type ZoneEffectPanelInput,
} from '../src/features/worldeditor/zoneEffectPanelModel'
import { ZONE_EFFECT_KINDS, type ZoneEffectKind } from '../src/features/worldeditor/zoneEffects'

// TYPED-ZONE EFFECT PANEL model. The decision layer for the panel that will finally drive the
// authoring commands. The tests that matter are about DISABLED states: this editor already shipped
// one control disabled for a reason it never stated ("Select a location first." while a zone was
// plainly selected), and that cost an afternoon.
// Run: `npx playwright test zoneEffectPanelModel.spec.ts`.

const here = dirname(fileURLToPath(import.meta.url))
const source = readFileSync(
  join(here, '..', 'src', 'features', 'worldeditor', 'zoneEffectPanelModel.ts'),
  'utf8',
)

const live: ZoneEffectPanelInput = {
  carried: [],
  authoringEnabled: true,
  zoneActive: true,
  busy: false,
}

// ── presence drives the offered action ──────────────────────────────────────────────────────────
test('a carried effect offers edit; an absent one offers add', () => {
  const p = buildZoneEffectPanel({ ...live, carried: ['pirate_intercept'] })
  const pirate = p.rows.find((r) => r.effect === 'pirate_intercept')!
  const mining = p.rows.find((r) => r.effect === 'mining')!
  expect(pirate.present).toBe(true)
  expect(pirate.action).toBe('edit')
  expect(pirate.canRemove).toBe(true)
  expect(mining.present).toBe(false)
  expect(mining.action).toBe('add')
  expect(mining.canRemove).toBe(false)
})

test('rows follow the registry order, so the panel never reshuffles', () => {
  const p = buildZoneEffectPanel({ ...live, carried: ['exploration', 'pirate_intercept'] })
  expect(p.rows.map((r) => r.effect)).toEqual([...ZONE_EFFECT_KINDS])
})

test('every registered effect gets a row, carried or not', () => {
  expect(buildZoneEffectPanel(live).rows).toHaveLength(ZONE_EFFECT_KINDS.length)
})

// ── the disabled states, which is the point ─────────────────────────────────────────────────────
test('a dark capability disables every row and SAYS SO', () => {
  const p = buildZoneEffectPanel({ ...live, authoringEnabled: false })
  expect(p.allDisabled).toBe(true)
  expect(p.blockedSummary).toMatch(/authoring is not enabled/i)
  for (const r of p.rows) {
    expect(r.enabled).toBe(false)
    expect(r.reason).toMatch(/authoring is not enabled/i)
    expect(r.canRemove).toBe(false)
  }
})

test('a retired zone is inspected, not authored', () => {
  const p = buildZoneEffectPanel({ ...live, zoneActive: false })
  expect(p.allDisabled).toBe(true)
  expect(p.blockedSummary).toMatch(/retired/i)
})

test('an in-flight command blocks dispatch so the panel cannot double-fire', () => {
  const p = buildZoneEffectPanel({ ...live, busy: true })
  expect(p.allDisabled).toBe(true)
  expect(p.blockedSummary).toMatch(/waiting/i)
})

test('blockers are reported by BLAST RADIUS — the most transient one never masks a real one', () => {
  // authoring off + busy: reporting "waiting…" would send the owner back to retry forever
  expect(
    buildZoneEffectPanel({ ...live, authoringEnabled: false, busy: true }).blockedSummary,
  ).toMatch(/authoring is not enabled/i)
  // inactive + busy: the retirement is the real problem
  expect(buildZoneEffectPanel({ ...live, zoneActive: false, busy: true }).blockedSummary).toMatch(
    /retired/i,
  )
})

test('nothing is enabled while a blocker exists, and everything is when none does', () => {
  expect(buildZoneEffectPanel(live).rows.every((r) => r.enabled)).toBe(true)
  expect(buildZoneEffectPanel(live).allDisabled).toBe(false)
  expect(buildZoneEffectPanel(live).blockedSummary).toBeNull()
})

test('NO disabled reason blames the owner for shell state', () => {
  const states: ZoneEffectPanelInput[] = [
    { ...live, authoringEnabled: false },
    { ...live, zoneActive: false },
    { ...live, busy: true },
  ]
  for (const s of states) {
    const reason = buildZoneEffectPanel(s).blockedSummary!
    // the exact shape of the defect that started all this
    expect(reason).not.toMatch(/select a .* first/i)
    expect(reason).not.toMatch(/switch to .* (tab|domain)/i)
  }
})

// ── the empty case, which is legal ──────────────────────────────────────────────────────────────
test('a zone with no effects is explained, not left looking broken', () => {
  expect(emptyEffectSummary([])).toMatch(/does nothing yet/i)
  expect(emptyEffectSummary(['mining'])).toBeNull()
})

test('addable effects are exactly the ones not carried', () => {
  expect(addableEffects([])).toEqual([...ZONE_EFFECT_KINDS])
  expect(addableEffects([...ZONE_EFFECT_KINDS])).toEqual([])
  const some: ZoneEffectKind[] = ['pirate_intercept']
  expect(addableEffects(some)).not.toContain('pirate_intercept')
  expect(addableEffects(some)).toHaveLength(ZONE_EFFECT_KINDS.length - 1)
})

// ── structural ──────────────────────────────────────────────────────────────────────────────────
test('the module is PURE and dispatches nothing — rows carry INTENTS, not calls', () => {
  expect(source).not.toMatch(/\bfrom 'react'|useState|document\.|fetch\(|localStorage|supabase|\.rpc\(/)
  expect(source).not.toMatch(/zone_effect_set|zone_effect_remove|zone_kind_change/)
})

test('it mirrors the server gate rather than inventing a client-only rule', () => {
  expect(source).toMatch(/typed_zone_authoring_enabled/)
  expect(source).toMatch(/a dark capability must not\n\/\/ present live-looking controls/)
})
