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

// ── ██ HOW BIG A LOCATION IS DRAWN — ONE NUMBER, ONE PLACE ██ ───────────────────────────────────
// Owner, playing, 2026-08-09: *"make each location graphics 3 times larger. for example snare icon
// to be 3 times larger"*.
//
// It is a SCALE on the one radius this module already owns, not a new size table and not a per-call
// multiplier: every other marker measurement in the map — the identity halo (`radius × haloRadius`),
// the hub ring (`radius × 1.45`), the hover halo (`radius × 2.6`), the selection reticle
// (`radius × 2.2`) and the name label's rise (`radius × 1.45/1.75`) — is expressed as a MULTIPLE of
// `radius`, so all of them follow this one constant and stay in proportion. Nothing downstream had
// to learn a new number.
//
// TWO things do NOT scale with it, on purpose, and both are named where they are used:
//   · the TAP TARGET — see markerHitRadius below. It grows to at least the glyph, never shrinks
//     below the 19px it has always been, and it is not multiplied by 3 because a hit disc three
//     times wider would start eating its neighbours' taps.
//   · TEXT — a label's font size and its stroke halo are text metrics, not marker geometry. The
//     clearance BELOW the marker does follow (MARKER_BELOW_LABEL_OFFSET, derived below).
export const MARKER_SCALE = 3

/** Unscaled core radius by importance: 8 / 10 / 12 px — importance reads at a glance, not
 *  all-identical dots. The drawn radius is this times MARKER_SCALE. */
const BASE_RADIUS: Record<MarkerImportance, number> = { 0: 8, 1: 10, 2: 12 }
/** Identity-halo radius, as a multiple of the core radius. */
const HALO_RADIUS: Record<MarkerImportance, number> = { 0: 1.6, 1: 1.95, 2: 2.3 }
/** The dockable port's second ring, as a multiple of the core radius (LocationMarker draws it). */
export const MARKER_HUB_RING_RADIUS = 1.45
/** The hover ring, as a multiple of the core radius. It is opacity-0 until the pointer is over the
 *  marker, so it draws nothing most of the time — but it DOES draw, and it is the OUTERMOST thing a
 *  marker can put on screen, so the below-marker clearance has to account for it or the fleet badge
 *  becomes unreadable exactly while the player is pointing at that port. */
export const MARKER_HOVER_RING_RADIUS = 2.6

/** The one glyph/size/halo decision for a location marker. */
export function markerStyle(l: MarkerStyleInputs): MarkerStyle {
  const importance = markerImportance(l)
  const port = isDockablePortForDisplay(l.location_type)
  return {
    shape: port ? 'diamond' : isCombatMarker(l) ? 'triangle' : 'circle',
    color: TYPE_TOKEN[l.location_type] ?? FALLBACK_TOKEN,
    radius: MARKER_SCALE * BASE_RADIUS[importance],
    haloRadius: HALO_RADIUS[importance],
    haloOpacity: 0.1 + importance * 0.05,
    hubRing: port,
    importance,
  }
}

/** The invisible constant tap disc, ~19px, that the marker has always carried. It is the FLOOR, not
 *  the answer — see markerHitRadius. */
export const MARKER_MIN_HIT_RADIUS = 19

/**
 * How big the marker's tap target is, in on-screen px (the renderer divides by k, like every other
 * marker measurement).
 *
 * ██ WHY THIS EXISTS AT ALL ██ — the hit disc used to be the bare constant 19, which was LARGER than
 * every glyph the policy could draw (8–12), so a constant target was strictly generous and the glyph
 * size was pure presentation. At MARKER_SCALE 3 the glyphs are 24–36 and that relationship INVERTS:
 * a bare 19 would leave the outer two thirds of a marker the player can plainly see refusing to be
 * tapped, which is the worst kind of dead control — one that looks alive.
 *
 * So the target is `max(19, radius)`: never smaller than it has always been, never smaller than what
 * is drawn, and deliberately NOT the halo (`radius × haloRadius`, up to 82.8px), because a tap disc
 * that wide would swallow a neighbouring marker's taps. The halo stays presentation.
 */
export function markerHitRadius(style: Pick<MarkerStyle, 'radius'>): number {
  return Math.max(MARKER_MIN_HIT_RADIUS, style.radius)
}

// ── BELOW-THE-MARKER TEXT ───────────────────────────────────────────────────────────────────
// The location's own NAME is drawn ABOVE its glyph; a fleet badge for a fleet standing there is drawn
// BELOW it, so the two never fight for the same pixels. This is the clearance for that second line,
// and it lives HERE because it is a fact about the marker, not about the badge — the badge has no way
// to know how big the glyph it is standing under actually is.
//
// It was 14, and 14 is INSIDE the glyph: the biggest marker had `radius` 12 with `haloRadius` 2.3, so
// its halo alone reached 27.6px and its hub ring 17.4px. The fleet label therefore rendered ON TOP of
// the port it was naming — measured on the owner's live map on 2026-08-04, where "Fleet 2 1/1" sat
// unreadable across the Slagworks diamond. A badge you cannot read does not tell anyone where their
// fleet is. Both numbers are on-screen px; every caller divides by the zoom factor k, like every other
// marker measurement in this module.
//
// ── ██ IT IS DERIVED NOW, NOT WRITTEN DOWN ██ ───────────────────────────────────────────────────
// It WAS the literal 46, hand-measured against a 27.6px halo. MARKER_SCALE 3 makes that halo 82.8px,
// and a hand-measured constant does not know that — so 46 would have put the fleet badge back INSIDE
// the very glyph it was raised to escape, reproducing the exact 2026-08-04 defect one scale change
// later. A number in a comment is a liability; the same is true of a number in a constant whose
// justification lives in a comment.
//
// So it is COMPUTED from the widest ink any marker can draw, plus the ascent of the text that sits
// under it. Change MARKER_SCALE, change a halo multiple, add an importance band — the clearance
// follows on its own, and tests/markerStyle.spec.ts states the invariant independently.
// EVERY ring a marker can draw is counted, hover included — no element is argued out of the sum.
// (At the old 1× scale the hover ring reached 31.2px against a 46px clearance and the ordering held
// by luck; at 3× it reaches 93.6px, so "it is usually invisible" would have become load-bearing.)
const WIDEST_MARKER_INK = Math.max(
  ...([0, 1, 2] as const).map((i) => {
    const r = MARKER_SCALE * BASE_RADIUS[i]
    return Math.max(r * HALO_RADIUS[i], r * MARKER_HUB_RING_RADIUS, r * MARKER_HOVER_RING_RADIUS)
  }),
)
/** A below-marker label's ink rises above its baseline: ~10px of font plus the 3px halo stroke it
 *  paints under itself. TEXT, so it does NOT scale with the marker. */
const BELOW_LABEL_ASCENT = 10 + 3
/** Breathing room between the marker's outermost ink and the badge under it. Clearing by a hair is
 *  not clearing: the badge and the marker are measured by different code paths (a projected FLEET
 *  point versus a projected LOCATION point) and they are not obliged to land on the same pixel, so a
 *  margin thinner than that difference is a proof that passes on one fixture and fails on the next. */
const BELOW_LABEL_GAP = 8
export const MARKER_BELOW_LABEL_OFFSET = Math.ceil(
  WIDEST_MARKER_INK + BELOW_LABEL_ASCENT + BELOW_LABEL_GAP,
)
/** Line height for stacked below-marker text (several fleets sharing one port). A text metric, so it
 *  is unchanged by MARKER_SCALE. */
export const MARKER_BELOW_LABEL_STEP = 12

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
