// ██ WHAT A SHIP LOOKS LIKE — the ONE authority, for every surface that draws one. ██
//
// PURE data + pure functions. No React, no DOM, no fetch, no clock — so tests drive the whole
// contract directly (tests/shipVisual.spec.ts). The renderer is map/shipGlyph.ts and it is the only
// thing that turns a descriptor below into SVG.
//
// ── THE DEFECT THIS REPLACES ────────────────────────────────────────────────────────────────────────
// The owner, playing the live game: "the fleet shape changes when in a combat, and outside combat. I
// want it to be same. Make it like when it is in combat, and for other ships, bigger ships, stronger
// ship, there will be bigger or different graphics. It is only a shape right now, but it will be
// different when i add a space ship image."
//
// One fleet had THREE appearances, each hard-coded at its own draw site:
//   · out of combat  — an accent DIAMOND, `5 / k`, inline in teamMarkers.FleetPointBadge
//   · in combat      — an up-pointing TRIANGLE, `px(7) × 1.35`, inline in spatialCombatLayer
//   · docked         — nothing at all; TeamDockBadge drew a label and no glyph
// Two of those live in the same `<svg>`, under the same camera, through the same `norm`. So the fleet
// did not move or reproject between states — it CHANGED SHAPE, because "what does a ship look like"
// was answered three times by three files and nowhere on purpose.
//
// LOCATIONS already had this fixed: map/markerStyle.ts is a pure policy that answers shape/size/tone
// for a location, and LocationMarker.tsx is a thin renderer of its answer. SHIPS had no equivalent —
// that absence IS the defect. This file is the ships' markerStyle.
//
// ── THE RULE ────────────────────────────────────────────────────────────────────────────────────────
// One descriptor answers WHAT IT LOOKS LIKE; the drawing state answers only DECORATION (a danger
// ring, which side the label sits on, whether a hull pip is drawn). The state never touches the form,
// the size or the tone. A fleet in a fight and the same fleet parked in open space resolve to the
// same `ShipVisual` because they call this same function with the same facts.
//
// ── THE SHAPE→IMAGE SWAP IS A DATA CHANGE IN THIS FILE, AND NOTHING ELSE ────────────────────────────
// `ShipForm` is a union: `paths` today (inline 24×24 line work), `image` the day the owner adds real
// spaceship art. `sizePx`, `tone` and `fillOpacity` are unaffected by which arm is in play, and
// map/shipGlyph.renderShipVisual handles both. So adding art is editing the FORMS table below — no
// consumer changes, no new prop, no second draw path. That is the same server-owns-the-vocabulary /
// client-owns-the-glyph split uiassets/assetGlyphs.ts states as law and components/items/itemGlyphs.ts
// already implements.
//
// ── TOTAL, AND HONEST ABOUT WHAT IT DOES NOT KNOW ───────────────────────────────────────────────────
// `shipVisual` accepts ANY string (the getItemGlyph contract): an id no catalog knows resolves to the
// generic form for its SIDE, with `known: false`. It never throws and it never guesses a class. An
// unknown BULK is drawn at the SMALLEST band, never the largest — an unknown quantity is not flattered.
import { ICON_PATHS } from '../../components/ui/icons'

/** WHAT IS DRAWN, on the 24×24 square the Icon.tsx R0 set already uses. `paths` = inline line work
 *  today; `image` = the owner's own art, later. The two
 *  arms are the ONLY difference between today and that day: every other field below is untouched. */
export type ShipForm =
  | { kind: 'paths'; viewBox: 24; d: readonly string[] }
  | { kind: 'image'; href: string; viewBox: number }

export type ShipSide = 'player' | 'enemy'
/** 'fleet' = one glyph standing for a whole fleet; 'unit' = a single hull (an enemy, a roster ship). */
export type ShipKind = 'fleet' | 'unit'

export interface ShipVisual {
  form: ShipForm
  /** HALF-SIZE in CSS pixels — the glyph spans `2 * sizePx` on screen.
   *
   *  IN CSS PIXELS ON PURPOSE. Every glyph on the galaxy map is drawn `÷ k`, which is constant in
   *  VIEWBOX units — and a viewBox unit is not a pixel. Under `preserveAspectRatio="xMidYMid meet"`
   *  the px-per-viewBox-unit is `min(width, height) / 1000`, so on the 390px phone the owner tests
   *  at, everything ÷k renders at 0.39×: the fleet diamond's nominal 5 arrived as 1.95 CSS px of
   *  half-size, i.e. a FOUR-PIXEL fleet. The combat layer already fixed this for the readout
   *  (spatialCombatLayer's px() and the header above it); the map badge was still on the wrong path.
   *  One size authority means one sizing PATH too, so this is the px one. */
  sizePx: number
  /** A design-token REFERENCE (`var(--color-*)`) — never a raw colour literal (the markerStyle law). */
  tone: string
  /** Fill opacity, 0.35..0.90, from `hpFrac`: a battered actor reads as failing. Carried on the
   *  descriptor rather than applied by a caller so the dimming cannot drift between draw sites. */
  fillOpacity: number
  /** false = the honest fallback form (an id no catalog knows). Never a crash, never a guessed class. */
  known: boolean
}

// ── TONE ────────────────────────────────────────────────────────────────────────────────────────────
/** The ONE side→token map. spatialCombatLayer imports this rather than keeping its own copy — two
 *  tables holding the same two values is the disease, at the smallest possible scale. */
export const SIDE_TONE: Record<ShipSide, string> = {
  player: 'var(--color-accent)',
  enemy: 'var(--color-danger)',
}

// ── THE FORMS ───────────────────────────────────────────────────────────────────────────────────────
// 24×24, centred on (12,12), the Icon.tsx mould. Rendered as ONE filled silhouette knocked out from
// the canvas (map/shipGlyph), so the shape reads at 8 CSS px where 1.5px line work would not.
//
// `frigate` IS the design system's own ship glyph (components/ui/icons.ts `ship`) — a 24×24
// upward-nose silhouette that already existed and already meant "a ship" on the Ship destination.
// Authoring a second one for the map would have been two answers to "what does a ship look like",
// which is the whole defect. The other three are new subjects, not new answers.

const FRIGATE: ShipForm = { kind: 'paths', viewBox: 24, d: ICON_PATHS.ship }

/** Lean nose delta + a small swept tail — a fast gun platform (speed 1.3, 4 slots, 20 m³). */
const CORVETTE: ShipForm = {
  kind: 'paths',
  viewBox: 24,
  d: ['M12 2.5 17 14 12 11.8 7 14Z', 'M12 12.6 14.6 21.5 12 19.8 9.4 21.5Z'],
}

/** Blunt slab hull with two side pods — bulk (650 hp, 140 m³, speed 0.8, only 2 slots). */
const HAULER: ShipForm = {
  kind: 'paths',
  viewBox: 24,
  d: ['M12 3 16 8.5V19H8V8.5L12 3Z', 'M5.5 10.5H8V18H5.5Z', 'M16 10.5H18.5V18H16Z'],
}

/** Barbed delta pointing DOWN — hostile, inbound. The down-nose silhouette is what tells the two
 *  sides apart at a glance without relying on hue alone; it is the one thing the retired inline
 *  triangles got right and it is preserved here as DATA rather than as an `if (side === 'enemy')`. */
const RAIDER: ShipForm = {
  kind: 'paths',
  viewBox: 24,
  d: ['M12 21.5 5.5 9H18.5Z', 'M5.5 9 3 4.5 8.5 6.5Z', 'M18.5 9 21 4.5 15.5 6.5Z'],
}

/** The generic fallback per SIDE. An unknown hostile still reads hostile; an unknown ship of ours
 *  still reads as a ship. Neither pretends to know which class it is (`known: false`). */
const FALLBACK_FORM: Record<ShipSide, ShipForm> = { player: FRIGATE, enemy: RAIDER }

// ── THE SUBJECT TABLE ───────────────────────────────────────────────────────────────────────────────
// Keyed on the SERVER's own ids. The server owns WHICH hull a ship is (`main_ship_hull_types` /
// `combat_units.unit_type_id`); this file owns how that id LOOKS. There is deliberately NO fetch of
// `main_ship_hull_types` from the map: a new hull is a seed row plus one entry here.
//
// MEASURED against production 2026-08-04 (read-only): `main_ship_hull_types` holds exactly these
// three player hulls, and all 77 live ships are `starter_frigate` with `max_hp` exactly 500
// (min = max), which is why `baseHp` and a row's own `hp_max` agree in today's world.
//
// `tier` IS NOT AN ORDERING FOR SIZE and is therefore not stored here: the T1 `strike_corvette`
// (420 hp) is SMALLER than the T0 `starter_frigate` (500 hp). Bulk orders size; role orders form.

interface HullSubject {
  form: ShipForm
  /** `main_ship_hull_types.base_hp` — the hull's nominal bulk, which is what SIZE is ranked by. */
  baseHp: number
}

/** OURS — `main_ship_hull_types.hull_type_id`. */
const PLAYER_HULLS: Record<string, HullSubject> = {
  starter_frigate: { form: FRIGATE, baseHp: 500 }, // T0 · speed 1.0 · 3 slots · 50 m³ — every live ship
  strike_corvette: { form: CORVETTE, baseHp: 420 }, // T1 · speed 1.3 · 4 slots · 20 m³ — the gun role
  bulk_hauler: { form: HAULER, baseHp: 650 }, // T1 · speed 0.8 · 2 slots · 140 m³ — the freight role
}

/** THEIRS — `combat_units.unit_type_id`. A SEPARATE vocabulary, deliberately: it is a different column
 *  on a different table, and the only reason the two share a lookup below is that their ids cannot
 *  collide. Keeping them one table would let a pirate's bulk leak into a fleet's fallback. */
const ENEMY_TYPES: Record<string, HullSubject> = {
  // ALL 115 live enemy rows carry this ONE id, so it is useless as a variant key: the spread that
  // exists is `hp_max` (25 distinct values, p50 141.7, max 368.8), and that is what the size bands
  // below read. `baseHp` here is the measured p50 and is only reached when a caller has no row of its
  // own to measure — an enemy always has one.
  pirate_synthetic: { form: RAIDER, baseHp: 142 },
}

const HULLS: Record<string, HullSubject> = { ...PLAYER_HULLS, ...ENEMY_TYPES }

/** The smallest bulk any of OUR hulls has. An unknown class contributes THIS to a fleet's mass, so a
 *  fleet carrying something this file has never heard of is never drawn bigger than the truth.
 *  Derived from the table, not typed a second time. */
const MIN_PLAYER_BASE_HP = Math.min(...Object.values(PLAYER_HULLS).map((h) => h.baseHp))

// ── THE SIZE BANDS ──────────────────────────────────────────────────────────────────────────────────
// ORDERED ROWS, not a switch: "bigger ship, bigger graphic" is content, and content is data. A new
// band is a row. Cut points are the MEASURED production distributions, so the bands describe the
// world that exists rather than a guess about it:
//   · enemy `hp_max` — ≤150 covers 61% of live rows, 150–240 a further 33%, >240 the last 6%.
//   · player — a lone `starter_frigate` is 500; the owner's 4-ship fleet is 2000.
//
// ⚠ SIZE MEANS BULK, NEVER DIFFICULTY. Measured on production: enemy `hp_max` does NOT track
// `danger_level` (danger 1 → avg 217; danger 5 → avg 104.6). A fatter glyph says "this hull can soak
// more", and it must never be presented — in copy, in a legend, anywhere — as "this zone is harder".
export interface ShipSizeBand {
  /** inclusive upper bound on mass (Σ hull bulk) for this band */
  maxMass: number
  /** half-size in CSS px */
  px: number
}

/** The ceiling, and where it comes from: the retired inline fleet triangle was `px(7) × 1.35`, so a
 *  fleet glyph is capped at exactly the size the map already drew one at. Nothing gets bigger than
 *  what shipped; the bands only spread what is SMALLER than it. */
export const FLEET_SIZE_CAP_PX = 9.45

export const SHIP_SIZE_BANDS: readonly ShipSizeBand[] = [
  { maxMass: 150, px: 5.6 }, // 61% of live enemies
  { maxMass: 240, px: 6.6 }, // the next 33%
  { maxMass: 500, px: 7.6 }, // the fattest 6% of enemies, and a single starter frigate
  { maxMass: 1200, px: 8.6 }, // a two-hull fleet
  { maxMass: Number.POSITIVE_INFINITY, px: FLEET_SIZE_CAP_PX }, // a real fleet — and the ceiling
]

const clamp01 = (v: number): number => (v < 0 ? 0 : v > 1 ? 1 : v)

/** Bulk → half-size, by the first band that contains it. Non-finite/negative mass falls in the FIRST
 *  band: an unknown quantity is drawn as the smallest thing, never as the biggest. */
export function shipSizePx(mass: number | null | undefined): number {
  const m = typeof mass === 'number' && Number.isFinite(mass) && mass > 0 ? mass : 0
  for (const band of SHIP_SIZE_BANDS) if (m <= band.maxMass) return band.px
  return FLEET_SIZE_CAP_PX // unreachable: the last band is unbounded
}

/** One hull id → its catalog bulk, or null when this file has never heard of it. */
export function hullBaseHp(typeId: string | null | undefined): number | null {
  if (!typeId) return null
  return HULLS[typeId]?.baseHp ?? null
}

/**
 * A fleet's NOMINAL bulk from its members' hull ids — the mass answer for a surface that has no
 * combat rows to measure.
 *
 * WHY IT AGREES WITH THE MEASURED ONE: `combat_units.hp_max` is the hull's own max, and production
 * says every live ship's `max_hp` is exactly its hull's `base_hp` (500, min = max on all 77). So a
 * fleet resolves to the same mass — and therefore the same size — whether it is read off the roster
 * or off a live fight. That is what lets the map badge and the combat glyph be the same size without
 * the map ever reading a ship's HP, which FleetStatusPanel explicitly refuses to duplicate.
 *
 * An unrecognised class contributes the smallest bulk in the catalog rather than being skipped: a
 * member that exists must count for something, and it must not count for more than it might be.
 */
export function nominalFleetMass(typeIds: readonly (string | null | undefined)[]): number {
  let total = 0
  for (const t of typeIds) total += hullBaseHp(t) ?? MIN_PLAYER_BASE_HP
  return total
}

/**
 * WHICH HULL SPEAKS FOR THE FLEET — the bulkiest one; ties break on the lowest key so the answer
 * never flickers between two identical hulls across renders.
 *
 * ONE rule, deliberately, and NOT the fight's elected lead. The lead decides where a fleet STANDS
 * (map/fleetFightPosition, composing 0315's server-side election) and keeps that job — but
 * `aggro_priority` is a `combat_units` column, so a lead exists ONLY inside a fight. A form that came
 * from the lead would be unavailable the moment the fleet left combat, and "the shape must be the
 * same in and out of combat" is the whole requirement. Bulk is a fact both worlds can state: a live
 * fight measures `hp_max`, a docked roster reads the hull catalog, and production says those are the
 * same number. So the fleet looks like its biggest ship, everywhere.
 */
export interface FleetFormMember {
  /** the member's hull id, when anything knows it */
  typeId: string | null | undefined
  /** its measured bulk (`hp_max`) when a fight is in play; omitted → the catalog answers */
  mass?: number | null
  /** the stable tie-break key — a `main_ship_id` or a `combat_units.id`, ascending */
  key: string
}

export function fleetFormHull(members: readonly FleetFormMember[]): string | null {
  let bestId: string | null = null
  let bestMass = -1
  let bestKey: string | null = null
  for (const m of members) {
    const mass = typeof m.mass === 'number' && Number.isFinite(m.mass) ? m.mass : (hullBaseHp(m.typeId) ?? 0)
    if (mass > bestMass || (mass === bestMass && bestKey !== null && m.key < bestKey)) {
      bestId = m.typeId ?? null
      bestMass = mass
      bestKey = m.key
    }
  }
  return bestId
}

/**
 * THE ONE ANSWER: the facts about a ship (or a fleet) → what is drawn for it.
 *
 * Total over every input — any string for `typeId`, any number for `mass`. A caller never has to
 * check whether this file knows a class, and a class it does not know renders acceptably instead of
 * crashing or inventing a category (the getItemGlyph contract, followed exactly).
 */
export function shipVisual(input: {
  /** `main_ship_hull_types.hull_type_id` for ours, `combat_units.unit_type_id` for a hostile. */
  typeId: string | null | undefined
  side: ShipSide
  kind: ShipKind
  /** Σ hull bulk this glyph stands for — `hp_max` summed over a fight's rows, or `nominalFleetMass`. */
  mass: number | null | undefined
  /** 0..1 condition; omitted/unknown → 1 (undimmed). The map NEVER reads a ship's HP to get this —
   *  out of combat there is none on the wire and duplicating the Ships-tab read onto the map is what
   *  FleetStatusPanel refuses. Absent is absent, and absent is drawn as whole. */
  hpFrac?: number | null
}): ShipVisual {
  const subject = input.typeId ? HULLS[input.typeId] : undefined
  const hp = typeof input.hpFrac === 'number' && Number.isFinite(input.hpFrac) ? clamp01(input.hpFrac) : 1
  return {
    form: subject?.form ?? FALLBACK_FORM[input.side],
    sizePx: shipSizePx(input.mass),
    tone: SIDE_TONE[input.side],
    // The retired inline formula, moved rather than re-invented (spatialCombatLayer's glyph pass):
    // full hull = 0.90, an empty one = 0.35, so "battered = fainter" survives the unification.
    fillOpacity: 0.35 + 0.55 * hp,
    known: subject !== undefined,
  }
}
