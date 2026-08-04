import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { buildZoneEffectPanel } from '../src/features/worldeditor/zoneEffectPanelModel.ts'
import {
  ZONE_EFFECT_KINDS,
  ZONE_EFFECT_LABELS,
  ZONE_EFFECT_STAT_ID,
  zoneEffectDormantNote,
  zoneEffectStatStanding,
} from '../src/features/worldeditor/zoneEffects.ts'
import {
  DORMANT_MARKER,
  DORMANT_NOTE,
  standingOfStatId,
} from '../src/features/stats/statLifecycle.ts'

// WORLD EDITOR — EXPOSE, BUT DO NOT MISREPRESENT.
//
// THE RULING (owner, 2026-08-04): the owner-facing editor MAY keep showing dormant definitions —
// authoring and diagnostics need them — but it must render lifecycle truth explicitly: a Dormant
// marker, the fact that there is currently no gameplay consumer, never a label that reads as an
// active effect, and the definition preserved for future authoring and audit.
//
// The residual violation was zoneEffects.ts:48 — `mining: 'Mining yield'`, an authoring row named
// after a stat migration 0340 seeds DORMANT, offered with nothing saying so.
//
// Run: `npx playwright test zoneEffectLifecycle.spec.ts`

const here = dirname(fileURLToPath(import.meta.url))
const source = readFileSync(
  join(here, '..', 'src', 'features', 'worldeditor', 'zoneEffects.ts'),
  'utf8',
)

const live = { carried: [], authoringEnabled: true, zoneActive: true, busy: false } as const

// ── THE EDITOR SHOWS DORMANT CONTENT, WITH ITS MARKER ───────────────────────────────────────────

test('the mining effect is still OFFERED — nothing is removed from the editor', () => {
  expect(ZONE_EFFECT_KINDS).toContain('mining')
  expect(ZONE_EFFECT_LABELS.mining).toBe('Mining yield')
  const row = buildZoneEffectPanel(live).rows.find((r) => r.effect === 'mining')
  expect(row, 'the dormant effect must stay authorable').toBeTruthy()
  expect(row?.enabled).toBe(true)
  expect(row?.action).toBe('add')
})

test('…but it now carries the Dormant marker and says there is no gameplay consumer', () => {
  const row = buildZoneEffectPanel(live).rows.find((r) => r.effect === 'mining')!
  expect(row.dormantMarker).toBe(DORMANT_MARKER)
  expect(row.dormantNote).toBe(DORMANT_NOTE)
  expect(row.dormantNote).toContain('No gameplay consumer today')
})

test('the marker travels with the label wherever the row goes — carried or not, blocked or not', () => {
  for (const carried of [[], ['mining'] as const]) {
    for (const authoringEnabled of [true, false]) {
      for (const zoneActive of [true, false]) {
        const p = buildZoneEffectPanel({
          carried: [...carried] as never,
          authoringEnabled,
          zoneActive,
          busy: false,
        })
        const row = p.rows.find((r) => r.effect === 'mining')!
        expect(row.dormantMarker, `carried=${carried} auth=${authoringEnabled}`).toBe(DORMANT_MARKER)
      }
    }
  }
})

// ── A LIVE EFFECT IS NEVER MARKED ───────────────────────────────────────────────────────────────

test('effects that are NOT denominated in a dormant stat carry no marker', () => {
  const rows = buildZoneEffectPanel(live).rows
  for (const effect of ['pirate_intercept', 'combat', 'exploration'] as const) {
    const row = rows.find((r) => r.effect === effect)!
    expect(row.dormantMarker, `${effect} was marked dormant without cause`).toBeNull()
    expect(row.dormantNote).toBeNull()
  }
  // pirate_intercept and combat are not denominated in ONE registered stat at all — the pirate chain
  // reads combat_power + survival together — so the map claims nothing about them.
  expect(zoneEffectStatStanding('pirate_intercept')).toBeNull()
  expect(zoneEffectStatStanding('combat')).toBeNull()
})

// ── THE STANDING COMES FROM THE REGISTRY, NOT FROM THIS FILE ────────────────────────────────────

test('the lifecycle answer is looked up in the 0340 registry, every time', () => {
  expect(zoneEffectStatStanding('mining')).toBe('dormant')
  expect(zoneEffectStatStanding('mining')).toBe(standingOfStatId('mining_yield'))
  // the map holds ONE join key and no verdict of its own
  expect(ZONE_EFFECT_STAT_ID.mining).toBe('mining_yield')
  expect(source).toContain('standingOfStatId')
  expect(source).not.toMatch(/dormant\s*:\s*(true|false)/)
})

test('an effect naming a stat the registry does not know FAILS CLOSED — marked, not waved through', () => {
  // The map is data, so a future entry can name anything. An unknown lifecycle must be marked
  // exactly like a dormant one: the client mirror of stat_lifecycle_in_scope (0340:791-801).
  const map = ZONE_EFFECT_STAT_ID as Record<string, string>
  const restore = map.exploration
  try {
    map.exploration = 'a_stat_that_does_not_exist'
    expect(zoneEffectStatStanding('exploration')).toBe('unknown')
    expect(zoneEffectDormantNote('exploration')).toEqual({ marker: DORMANT_MARKER, note: DORMANT_NOTE })
    expect(buildZoneEffectPanel(live).rows.find((r) => r.effect === 'exploration')!.dormantMarker).toBe(
      DORMANT_MARKER,
    )
  } finally {
    if (restore === undefined) delete map.exploration
    else map.exploration = restore
  }
})

// ── WHAT WAS NOT DONE ───────────────────────────────────────────────────────────────────────────

test('NO dormant stat definition is removed, and no mining behaviour is activated', () => {
  expect(ZONE_EFFECT_KINDS.length).toBe(4)
  expect([...ZONE_EFFECT_KINDS]).toEqual(['pirate_intercept', 'combat', 'mining', 'exploration'])
  // the module is still PURE — the marker must not have dragged in state or I/O
  expect(source).not.toMatch(/\bfrom 'react'|useState|useEffect|localStorage|document\.|fetch\(|supabase/)
  // and it still contains no runtime risk mathematics
  expect(source).not.toMatch(/yield_multiplier\s*\*/)
})
