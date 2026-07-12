import { test, expect } from '@playwright/test'
import { TYPE_LABEL, dangerLabel, rewardLabel, withPowerGate } from '../src/features/map/locationDisplay'
import type { LocationType } from '../src/features/map/mapTypes'

// DIFFICULTY-DISPLAY — pure unit proofs for the player-facing location display mappings (no
// browser/page/DB: locationDisplay.ts is a pure module — numbers/enums in, player words out).
// The markerStyle.spec.ts mold. Run: `npx playwright test locationDisplay.spec.ts`.

// ── dangerLabel — every band EDGE, both sides ────────────────────────────────────────────────────
test('dangerLabel: band edges — ≤0 safe · ≤10 Low · ≤20 Moderate · ≤35 High · ≤50 Severe · >50 Extreme', () => {
  expect(dangerLabel(-5)).toBe('None — safe space')
  expect(dangerLabel(0)).toBe('None — safe space')
  expect(dangerLabel(1)).toBe('Low')
  expect(dangerLabel(10)).toBe('Low')
  expect(dangerLabel(11)).toBe('Moderate')
  expect(dangerLabel(20)).toBe('Moderate')
  expect(dangerLabel(21)).toBe('High')
  expect(dangerLabel(35)).toBe('High')
  expect(dangerLabel(36)).toBe('Severe')
  expect(dangerLabel(50)).toBe('Severe')
  expect(dangerLabel(51)).toBe('Extreme')
  expect(dangerLabel(1000)).toBe('Extreme')
})

test('dangerLabel: the ZONES2 legibility fix — Blackden (bd 25) no longer reads identical to Ember Reach (bd 40/50/60)', () => {
  expect(dangerLabel(25)).toBe('High') // Blackden keeps its old word
  expect(dangerLabel(40)).toBe('Severe')
  expect(dangerLabel(50)).toBe('Severe') // same word as 40 — the sheet's mono "(50)" disambiguates
  expect(dangerLabel(60)).toBe('Extreme')
  expect(dangerLabel(40)).not.toBe(dangerLabel(25))
  expect(dangerLabel(60)).not.toBe(dangerLabel(25))
})

// ── rewardLabel — every tier, extended past the old Rich saturation ─────────────────────────────
test('rewardLabel: tier words — 0 None · 1 Modest · 2 Good · 3 Rich · 4 Bountiful · ≥5 Legendary', () => {
  expect(rewardLabel(-1)).toBe('None')
  expect(rewardLabel(0)).toBe('None')
  expect(rewardLabel(1)).toBe('Modest')
  expect(rewardLabel(2)).toBe('Good')
  expect(rewardLabel(3)).toBe('Rich')
  expect(rewardLabel(4)).toBe('Bountiful')
  expect(rewardLabel(5)).toBe('Legendary')
  expect(rewardLabel(9)).toBe('Legendary')
})

// ── withPowerGate — the hunt-select option label ─────────────────────────────────────────────────
test('withPowerGate: appends the gate only when min_power_required > 0 (gate-free names byte-identical)', () => {
  expect(withPowerGate('Ember Gate', 150)).toBe('Ember Gate — power 150+')
  expect(withPowerGate('Ember Throat', 300)).toBe('Ember Throat — power 300+')
  expect(withPowerGate('Blackden', 0)).toBe('Blackden')
  expect(withPowerGate('Blackden', -1)).toBe('Blackden')
})

// ── TYPE_LABEL — total over the LocationType union (moved here from MapScreen; ONE home) ────────
test('TYPE_LABEL: every seed location type has a plain player label', () => {
  const ALL_TYPES: LocationType[] = [
    'pirate_hunt',
    'pirate_den',
    'mining_site',
    'derelict_station',
    'trade_outpost',
    'rally_point',
    'safe_zone',
    'event_site',
  ]
  for (const t of ALL_TYPES) {
    expect(typeof TYPE_LABEL[t]).toBe('string')
    expect(TYPE_LABEL[t].length).toBeGreaterThan(0)
    expect(TYPE_LABEL[t]).not.toContain('_') // humanized, never the raw enum
  }
})
