import { test, expect } from '@playwright/test'
import {
  markerStyle,
  markerImportance,
  isCombatMarker,
  labelTier,
  labelVisible,
  LABEL_REVEAL_K,
  MARKER_BELOW_LABEL_OFFSET,
  MARKER_BELOW_LABEL_STEP,
  type MarkerStyleInputs,
} from '../src/features/map/markerStyle'
import { isDockablePortForDisplay, type ActivityType, type LocationType } from '../src/features/map/mapTypes'

// UI R1 (galaxy map) — pure unit proofs for the marker-hierarchy + label-declutter policy. No
// browser/page/DB: markerStyle.ts is a pure module (props in → style/visibility decision out).
// Run: `npx playwright test markerStyle.spec.ts`.

const loc = (over: Partial<MarkerStyleInputs> = {}): MarkerStyleInputs => ({
  location_type: 'safe_zone' as LocationType,
  activity_type: 'none' as ActivityType,
  reward_tier: 0,
  base_difficulty: 0,
  ...over,
})

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

// ── Type treatment: ports/hazards/waypoints get DISTINCT glyphs, colored by semantic tokens ─────────
test('ports are accent diamonds with the hub ring and are always major', () => {
  const s = markerStyle(loc({ location_type: 'trade_outpost', activity_type: 'trade_visit' }))
  expect(s.shape).toBe('diamond')
  expect(s.hubRing).toBe(true)
  expect(s.color).toBe('var(--color-accent)')
  expect(s.importance).toBe(2)
})

test('combat/hazard locations are danger-toned triangles', () => {
  for (const l of [
    loc({ location_type: 'pirate_hunt', activity_type: 'hunt_pirates', base_difficulty: 15 }),
    loc({ location_type: 'pirate_den', activity_type: 'hunt_pirates', base_difficulty: 25 }),
  ]) {
    expect(isCombatMarker(l)).toBe(true)
    const s = markerStyle(l)
    expect(s.shape).toBe('triangle')
    expect(s.color).toBe('var(--color-danger)')
    expect(s.hubRing).toBe(false)
  }
})

test('plain waypoints stay circles (success tone for safe zones)', () => {
  const s = markerStyle(loc())
  expect(s.shape).toBe('circle')
  expect(s.color).toBe('var(--color-success)')
  expect(s.hubRing).toBe(false)
  expect(s.importance).toBe(0)
})

test('every seed location type resolves to a design-token color reference (never a raw literal)', () => {
  for (const t of ALL_TYPES) {
    const s = markerStyle(loc({ location_type: t }))
    expect(s.color).toMatch(/^var\(--color-[a-z-]+\)$/)
  }
})

// ── Importance: derived from the REAL MapLocation fields (reward_tier / base_difficulty / activity) ──
test('importance ranks by the reward/danger bands', () => {
  expect(markerImportance(loc())).toBe(0) // nothing notable
  expect(markerImportance(loc({ reward_tier: 1 }))).toBe(1) // some reward
  expect(markerImportance(loc({ base_difficulty: 12 }))).toBe(1) // moderate danger
  expect(markerImportance(loc({ activity_type: 'mine_resource' }))).toBe(1) // has an activity
  expect(markerImportance(loc({ reward_tier: 3 }))).toBe(2) // "Rich" band
  expect(markerImportance(loc({ base_difficulty: 25 }))).toBe(2) // "High" danger band
})

// DIFFICULTY-DISPLAY — the extended ZONES2 range (Ember Reach: bd 40/50/60, tiers 4/5) stays inside
// the existing TOP band: already-major markers, always labelled. The marker hierarchy deliberately
// stays coarse (locationDisplay.ts's Severe/Extreme words + the detail sheet carry the finer read).
test('the extended difficulty/reward range (bd 40–60, tiers 4–5) maps to the top importance band', () => {
  for (const l of [
    loc({ location_type: 'pirate_hunt', activity_type: 'hunt_pirates', base_difficulty: 40, reward_tier: 4 }),
    loc({ location_type: 'pirate_hunt', activity_type: 'hunt_pirates', base_difficulty: 50, reward_tier: 4 }),
    loc({ location_type: 'pirate_hunt', activity_type: 'hunt_pirates', base_difficulty: 60, reward_tier: 5 }),
  ]) {
    expect(markerImportance(l)).toBe(2)
    expect(markerStyle(l).radius).toBe(12) // same top size as bd 25 — no runaway growth
    expect(labelTier(l)).toBe(0) // labelled at ANY zoom
    expect(labelVisible(l, 0.4)).toBe(true)
  }
})

test('size and halo scale monotonically with importance (hierarchy reads at a glance)', () => {
  const minor = markerStyle(loc())
  const notable = markerStyle(loc({ reward_tier: 1 }))
  const major = markerStyle(loc({ reward_tier: 3 }))
  expect(minor.radius).toBeLessThan(notable.radius)
  expect(notable.radius).toBeLessThan(major.radius)
  expect(minor.haloRadius).toBeLessThan(major.haloRadius)
  expect(minor.haloOpacity).toBeLessThan(major.haloOpacity)
})

// ── Label declutter: zoom-tiered reveal (no more "everything labels at k=0.9" dump) ─────────────────
test('ports and major locations are labelled at ANY zoom', () => {
  for (const l of [loc({ location_type: 'trade_outpost' }), loc({ reward_tier: 3 })]) {
    expect(labelTier(l)).toBe(0)
    for (const k of [0.4, 0.9, 8, 1024]) expect(labelVisible(l, k)).toBe(true)
  }
})

test('notable locations reveal at the tier-1 zoom, minor ones only when zoomed right in', () => {
  const notable = loc({ reward_tier: 1 })
  expect(labelTier(notable)).toBe(1)
  expect(labelVisible(notable, LABEL_REVEAL_K[1] - 0.01)).toBe(false)
  expect(labelVisible(notable, LABEL_REVEAL_K[1])).toBe(true)

  const minor = loc()
  expect(labelTier(minor)).toBe(2)
  expect(labelVisible(minor, LABEL_REVEAL_K[1])).toBe(false) // still hidden at the tier-1 zoom
  expect(labelVisible(minor, LABEL_REVEAL_K[2] - 0.01)).toBe(false)
  expect(labelVisible(minor, LABEL_REVEAL_K[2])).toBe(true)
})

test('label reveal is monotonic in k (zooming in never HIDES a label)', () => {
  const tiers = [loc({ location_type: 'trade_outpost' }), loc({ reward_tier: 1 }), loc()]
  const ks = [0.4, 0.8, 0.9, 1.6, 4, 64]
  for (const l of tiers) {
    let seen = false
    for (const k of ks) {
      const v = labelVisible(l, k)
      if (seen) expect(v).toBe(true) // once visible, stays visible at deeper zoom
      seen = seen || v
    }
    expect(labelVisible(l, 1024)).toBe(true) // everything is labelled at max zoom
  }
})

test('the reveal thresholds keep the tiers strictly ordered', () => {
  expect(LABEL_REVEAL_K[1]).toBeLessThan(LABEL_REVEAL_K[2])
})

// ── isDockablePortForDisplay — the ONE display-dockability classifier (mapTypes) ─────────────────
// Rehomed from portEntry.spec.ts when 4c-client deleted the normalize affordance; the classifier
// stays LIVE (fleetCommandModel dock legality, the port glyph above), so its pin lives with a
// live consumer's spec.
test('dockability classifier: trade_outpost is the ONLY display-dockable type', () => {
  expect(isDockablePortForDisplay('trade_outpost')).toBe(true)
  expect(isDockablePortForDisplay('safe_zone')).toBe(false)
  expect(isDockablePortForDisplay('pirate_hunt')).toBe(false)
})

// ── BELOW-THE-MARKER TEXT clears the marker's own ink ─────────────────────────────────────────────
// A fleet badge is drawn under the port its fleet is standing at. It was drawn at 14, which is INSIDE
// the biggest marker's halo — measured on the owner's live map on 2026-08-04, where "Fleet 2 1/1" sat
// struck through by the Slagworks diamond. This is the invariant that keeps that from coming back, and
// it is stated against the marker geometry rather than against a screenshot, so it holds for a marker
// size nobody has drawn yet.
test('a label drawn BELOW a marker clears the widest ink any marker can draw', () => {
  // Every marker the policy can produce, at its own size (all measurements are on-screen px, before
  // the shared 1/k zoom division that both the marker and the label apply identically).
  const extents = ALL_TYPES.flatMap((location_type) =>
    [0, 1, 2].map((importance) => {
      const l = loc({
        location_type,
        activity_type: importance > 0 ? ('hunt_pirates' as ActivityType) : ('none' as ActivityType),
        reward_tier: importance,
        base_difficulty: importance * 6,
      })
      const s = markerStyle(l)
      // The two visible reaches: the identity halo, and the dockable port's hub ring (r * 1.45).
      return Math.max(s.radius * s.haloRadius, s.hubRing ? s.radius * 1.45 : 0)
    }),
  )
  const widest = Math.max(...extents)
  // The label's own ink rises above its baseline: ~10px of font plus the 3px halo stroke it paints
  // under itself. The offset is a BASELINE, so the ascent has to clear too.
  const LABEL_ASCENT = 10 + 3
  expect(MARKER_BELOW_LABEL_OFFSET).toBeGreaterThanOrEqual(widest + LABEL_ASCENT)
  // And stacked fleets at one port must not write over each other either.
  expect(MARKER_BELOW_LABEL_STEP).toBeGreaterThanOrEqual(LABEL_ASCENT - 3)
})
