import type { LocationType, MapLocation } from './mapTypes'
import { isDockablePortForDisplay } from './mapTypes'

// UI R1 (galaxy map) — the PURE marker-hierarchy + label-declutter policy. No React, no DOM: props in,
// a style/visibility decision out, so LocationMarker stays a thin renderer and this file is unit-tested
// directly (tests/markerStyle.spec.ts).
//
// Derived ONLY from real MapLocation fields (mapTypes.ts): location_type, activity_type, reward_tier,
// base_difficulty. Colors are design-system token REFERENCES (var(--color-*)) — never raw literals —
// so the map speaks the same semantic language as the rest of the UI:
//   danger  → hostile (pirate hunt/den, hunt_pirates activity) — triangle glyph
//   success → safe (safe_zone)
//   accent  → dockable port (trade_outpost — diamond glyph + hub ring) + rally
//   warning → resource/event (mining_site / event_site)
//   muted   → derelict / unknown

export type MarkerShape = 'circle' | 'diamond' | 'triangle'
export type MarkerImportance = 0 | 1 | 2

/** The subset of MapLocation this policy reads (everything it needs really exists on the type). */
export type MarkerStyleInputs = Pick<MapLocation, 'location_type' | 'activity_type' | 'reward_tier' | 'base_difficulty'>

const TYPE_TOKEN: Record<LocationType, string> = {
  pirate_hunt: 'var(--color-danger)',
  pirate_den: 'var(--color-danger)',
  mining_site: 'var(--color-warning)',
  trade_outpost: 'var(--color-accent)',
  derelict_station: 'var(--color-ink-muted)',
  rally_point: 'var(--color-accent)',
  safe_zone: 'var(--color-success)',
  event_site: 'var(--color-warning)',
}
const FALLBACK_TOKEN = 'var(--color-ink-faint)'

/** Combat/hazard read: a hostile-activity location (danger tone + triangle glyph). */
export function isCombatMarker(l: MarkerStyleInputs): boolean {
  return l.activity_type === 'hunt_pirates' || l.location_type === 'pirate_hunt' || l.location_type === 'pirate_den'
}

/** Importance rank (0 minor · 1 notable · 2 major). Ports are always major (the dockable hubs the
 *  player navigates by); otherwise rank by reward/danger bands aligned with the humanized words in
 *  locationDisplay.ts (reward_tier ≥3 = Rich+ , base_difficulty >20 = High+ → major; any
 *  reward/danger/activity → notable). DIFFICULTY-DISPLAY note: the marker hierarchy deliberately
 *  stays this coarse — the extended word bands (Severe/Extreme, bd 35/50; Bountiful/Legendary,
 *  tier 4/5) all fall inside the existing top band here, so the new high-difficulty zones already
 *  render as major markers; the finer read lives in the detail sheet's words + numbers. */
export function markerImportance(l: MarkerStyleInputs): MarkerImportance {
  if (isDockablePortForDisplay(l.location_type)) return 2
  if (l.reward_tier >= 3 || l.base_difficulty > 20) return 2
  if (l.reward_tier >= 1 || l.base_difficulty > 10 || l.activity_type !== 'none') return 1
  return 0
}

export interface MarkerStyle {
  shape: MarkerShape
  /** token reference (var(--color-*)) — never a raw color literal */
  color: string
  /** core glyph radius in on-screen px (the renderer divides by the zoom factor k) */
  radius: number
  /** identity-halo radius as a multiple of `radius` */
  haloRadius: number
  haloOpacity: number
  /** dockable ports get the second "hub" ring */
  hubRing: boolean
  importance: MarkerImportance
}

/** The one glyph/size/halo decision for a location marker. */
export function markerStyle(l: MarkerStyleInputs): MarkerStyle {
  const importance = markerImportance(l)
  const port = isDockablePortForDisplay(l.location_type)
  return {
    shape: port ? 'diamond' : isCombatMarker(l) ? 'triangle' : 'circle',
    color: TYPE_TOKEN[l.location_type] ?? FALLBACK_TOKEN,
    radius: 8 + importance * 2, // 8 / 10 / 12 px — importance reads at a glance, not all-identical dots
    haloRadius: 1.6 + importance * 0.35,
    haloOpacity: 0.1 + importance * 0.05,
    hubRing: port,
    importance,
  }
}

// ── Label declutter: zoom-tiered reveal (replaces the old single global `k >= 0.9` dump) ────────────
// Tier 0 (ports + major locations) is ALWAYS labelled; tier 1 reveals at a modest zoom; tier 2 (minor
// waypoints) only when the player zooms right in. Selected markers are always labelled by the caller.

export type LabelTier = 0 | 1 | 2
export const LABEL_REVEAL_K: Record<Exclude<LabelTier, 0>, number> = { 1: 0.8, 2: 1.6 }

export function labelTier(l: MarkerStyleInputs): LabelTier {
  const importance = markerImportance(l)
  return importance === 2 ? 0 : importance === 1 ? 1 : 2
}

export function labelVisible(l: MarkerStyleInputs, k: number): boolean {
  const tier = labelTier(l)
  return tier === 0 ? true : k >= LABEL_REVEAL_K[tier]
}
