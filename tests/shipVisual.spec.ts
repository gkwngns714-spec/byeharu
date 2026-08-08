import { test, expect } from '@playwright/test'
import type { ReactElement } from 'react'
import { ICON_PATHS } from '../src/components/ui/icons'
import {
  FLEET_SIZE_CAP_PX,
  SHIP_SIZE_BANDS,
  SIDE_TONE,
  fleetFormHull,
  hullBaseHp,
  nominalFleetMass,
  shipSizePx,
  shipVisual,
  type ShipVisual,
} from '../src/features/map/shipVisual'
import { renderShipVisual, shipGlyphFillsBox, shipGlyphHalf } from '../src/features/map/shipGlyph'

// ██ WHAT A SHIP LOOKS LIKE — the pure proof of the ONE authority. ██
//
// WHY IT IS TABLE-DRIVEN, and why the table is the ONLY proof available: `main_ship_hull_types` holds
// three player hulls, and **all 77 live production ships are `starter_frigate`**. So the corvette and
// the hauler variants are UNVERIFIABLE BY PLAYING the game — nobody owns one. A screenshot of the
// owner's map can only ever confirm the baseline. This spec drives every catalog subject plus an
// UNKNOWN id (the fallback arm), which is what makes the day a second hull exists a data change
// rather than a discovery.
//
// The owner: "for other ships, bigger ships, stronger ship, there will be bigger or different
// graphics. It is only a shape right now, but it will be different when i add a space ship image."
// Both halves of that are properties below: bulk → size, id → form, and an `image` form drawn by the
// same renderer at the same place and size as the `paths` one.

const props = (el: ReactElement) => el.props as Record<string, unknown>

// ── THE CATALOG, driven ─────────────────────────────────────────────────────────────────────────────
// Every subject the server can name today, plus the honest fallback. `known` is the whole contract:
// a class this file has learned resolves to its own form; one it has not says so instead of guessing.
const SUBJECTS = [
  { typeId: 'starter_frigate', side: 'player', known: true, baseHp: 500 },
  { typeId: 'strike_corvette', side: 'player', known: true, baseHp: 420 },
  { typeId: 'bulk_hauler', side: 'player', known: true, baseHp: 650 },
  { typeId: 'pirate_synthetic', side: 'enemy', known: true, baseHp: 142 },
  { typeId: 'warp_dreadnought_mk9', side: 'player', known: false, baseHp: null },
  { typeId: '', side: 'enemy', known: false, baseHp: null },
] as const

for (const s of SUBJECTS) {
  test(`the catalog resolves '${s.typeId || '(empty id)'}' — total, tone-correct, and honest about what it knows`, () => {
    const v = shipVisual({ typeId: s.typeId, side: s.side, kind: 'unit', mass: s.baseHp })
    expect(v.known, 'known must state whether the CATALOG has this id, never whether a glyph exists').toBe(s.known)
    // A form is ALWAYS produced — an unrecognised id renders acceptably rather than crashing or
    // rendering nothing (the getItemGlyph contract this file follows).
    expect(v.form.kind).toBe('paths')
    if (v.form.kind === 'paths') {
      expect(v.form.viewBox).toBe(24)
      expect(v.form.d.length).toBeGreaterThan(0)
    }
    // Tone is a design-token REFERENCE, never a raw colour literal (the markerStyle law).
    expect(v.tone).toBe(SIDE_TONE[s.side])
    expect(v.tone).toMatch(/^var\(--color-/)
    expect(hullBaseHp(s.typeId)).toBe(s.baseHp)
  })
}

test('TODAY’S LIVE WORLD — starter_frigate resolves to the BASELINE form, the design system’s own ship', () => {
  // All 77 live ships are this hull, so this is the one arm the owner can actually see on their map.
  // It is not a shape authored for the map: it is components/ui/icons.ts `ship`, the 24×24 upward-nose
  // silhouette that already meant "a ship" on the Ship destination. Two answers to "what does a ship
  // look like" is the defect this whole slice deletes, so the map does not get its own.
  const v = shipVisual({ typeId: 'starter_frigate', side: 'player', kind: 'unit', mass: 500 })
  expect(v.form.kind === 'paths' && v.form.d).toEqual(ICON_PATHS.ship)
})

test('an unrecognised id falls back BY SIDE — an unknown hostile still reads hostile', () => {
  const ours = shipVisual({ typeId: 'nope', side: 'player', kind: 'unit', mass: 500 })
  const theirs = shipVisual({ typeId: 'nope', side: 'enemy', kind: 'unit', mass: 500 })
  expect(ours.known).toBe(false)
  expect(theirs.known).toBe(false)
  expect(ours.form).not.toEqual(theirs.form) // ours noses UP; a raider comes DOWN at us
  expect(ours.form.kind === 'paths' && ours.form.d).toEqual(ICON_PATHS.ship)
})

test('the three player hulls are three DIFFERENT forms — role orders the shape', () => {
  const formOf = (typeId: string) => {
    const f = shipVisual({ typeId, side: 'player', kind: 'unit', mass: 500 }).form
    return f.kind === 'paths' ? f.d.join(' ') : f.href
  }
  const forms = ['starter_frigate', 'strike_corvette', 'bulk_hauler'].map(formOf)
  expect(new Set(forms).size).toBe(3)
})

// ── SIZE: BULK, MEASURED — never tier, and never difficulty ─────────────────────────────────────────

test('the size bands are ORDERED and monotone, and they are CAPPED at what already shipped', () => {
  const cuts = SHIP_SIZE_BANDS.map((b) => b.maxMass)
  expect([...cuts].sort((a, b) => a - b)).toEqual(cuts) // ordered rows, so the first hit is the answer
  const sizes = SHIP_SIZE_BANDS.map((b) => b.px)
  expect([...sizes].sort((a, b) => a - b)).toEqual(sizes) // bigger bulk is never a smaller glyph
  // The retired inline fleet triangle was px(7) × 1.35 = 9.45. Nothing may exceed it: the bands only
  // spread what is SMALLER than what the map already drew.
  expect(Math.max(...sizes)).toBe(FLEET_SIZE_CAP_PX)
  expect(FLEET_SIZE_CAP_PX).toBeCloseTo(7 * 1.35, 10)
})

test('TIER DOES NOT ORDER SIZE — the T1 corvette is smaller than the T0 frigate', () => {
  // The trap this pins: `main_ship_hull_types` has a `tier` column and ranking size by it would make
  // the fast T1 gunship (420 hp) LOOK bigger than the T0 starter (500 hp). Bulk orders size; tier and
  // role order the form.
  expect(hullBaseHp('strike_corvette')!).toBeLessThan(hullBaseHp('starter_frigate')!)
  expect(hullBaseHp('bulk_hauler')!).toBeGreaterThan(hullBaseHp('starter_frigate')!)
  const px = (id: string) => shipVisual({ typeId: id, side: 'player', kind: 'unit', mass: hullBaseHp(id) }).sizePx
  expect(px('strike_corvette')).toBeLessThanOrEqual(px('bulk_hauler'))
})

test('the MEASURED enemy bands separate the real production spread', () => {
  // Measured read-only on production: 115 enemy rows, hp_max in 25 distinct values, p50 141.7,
  // max 368.8 — 61% at or below 150, a further 33% to 240, the last 6% above it.
  expect(shipSizePx(120)).toBeLessThan(shipSizePx(200)) // the 61% band vs the 33% band
  expect(shipSizePx(200)).toBeLessThan(shipSizePx(368.8)) // …vs the fattest 6%
  // …and no hostile hull, even the fattest measured one, is ever drawn as big as a real fleet.
  expect(shipSizePx(368.8)).toBeLessThan(FLEET_SIZE_CAP_PX)
  expect(shipSizePx(4 * 500)).toBe(FLEET_SIZE_CAP_PX) // the owner's 4-hull fleet
})

test('an UNKNOWN bulk is drawn as the SMALLEST thing, never the biggest — never flattered', () => {
  const smallest = SHIP_SIZE_BANDS[0].px
  for (const mass of [null, undefined, 0, -5, Number.NaN, Number.POSITIVE_INFINITY === 0 ? 1 : -0]) {
    expect(shipSizePx(mass as number | null | undefined)).toBe(smallest)
  }
})

test('a fleet grows with what is IN it — one hull, two hulls, four hulls', () => {
  const size = (n: number) =>
    shipVisual({
      typeId: 'starter_frigate',
      side: 'player',
      kind: 'fleet',
      mass: nominalFleetMass(Array.from({ length: n }, () => 'starter_frigate')),
    }).sizePx
  expect(size(1)).toBeLessThan(size(2))
  expect(size(2)).toBeLessThan(size(4))
  expect(size(4)).toBe(FLEET_SIZE_CAP_PX)
  expect(size(40)).toBe(FLEET_SIZE_CAP_PX) // the cap holds — nothing outgrows the map
})

test('nominalFleetMass matches the MEASURED mass, which is why the badge and the glyph agree', () => {
  // Production: every live ship's `max_hp` is exactly its hull's `base_hp` (500, min = max on all 77).
  // So the roster-side mass (this function) and the combat-side mass (Σ hp_max) are the same number,
  // which is how the map badge is the same SIZE as the combat glyph WITHOUT the map reading any HP.
  expect(nominalFleetMass(['starter_frigate', 'starter_frigate'])).toBe(1000)
  // An unrecognised class counts for the SMALLEST bulk in the catalog: it exists, so it counts for
  // something, and it must not count for more than it might be.
  expect(nominalFleetMass(['who_knows'])).toBe(420)
  expect(nominalFleetMass([])).toBe(0)
})

// ── WHICH HULL SPEAKS FOR THE FLEET ─────────────────────────────────────────────────────────────────

test('the fleet wears its BULKIEST hull, and a tie is broken by key — never by array order', () => {
  const members = [
    { typeId: 'starter_frigate', key: 'b' },
    { typeId: 'bulk_hauler', key: 'c' },
    { typeId: 'strike_corvette', key: 'a' },
  ]
  expect(fleetFormHull(members)).toBe('bulk_hauler')
  expect(fleetFormHull([...members].reverse())).toBe('bulk_hauler') // order is not an input
  // A tie answers the LOWEST key in either order, so a fleet of identical hulls never flickers.
  const tie = [
    { typeId: 'starter_frigate', key: 's2' },
    { typeId: 'starter_frigate', key: 's1' },
  ]
  expect(fleetFormHull(tie)).toBe('starter_frigate')
  expect(fleetFormHull([])).toBeNull()
})

test('a MEASURED mass outranks the catalog when a fight is in play', () => {
  // In a fight the bulk is `hp_max` off the row, not a catalog lookup, so a hull the catalog does not
  // know can still be the one that speaks for the fleet.
  expect(
    fleetFormHull([
      { typeId: 'starter_frigate', mass: 500, key: 'a' },
      { typeId: 'something_new', mass: 900, key: 'b' },
    ]),
  ).toBe('something_new')
})

// ── THE DIMMING ─────────────────────────────────────────────────────────────────────────────────────

test('condition dims the fill, and an ABSENT condition is drawn as whole (never as damaged)', () => {
  const at = (hpFrac: number | null | undefined) =>
    shipVisual({ typeId: 'starter_frigate', side: 'player', kind: 'fleet', mass: 500, hpFrac }).fillOpacity
  expect(at(1)).toBeCloseTo(0.9, 10) // the retired inline formula, 0.35 + 0.55 * hpFrac
  expect(at(0)).toBeCloseTo(0.35, 10)
  expect(at(0.5)).toBeCloseTo(0.625, 10)
  expect(at(1.4)).toBeCloseTo(0.9, 10) // clamped, never over-bright
  // The map does NOT read a ship's HP out of combat (there is none on that read, and duplicating the
  // Ships-tab read onto the map is what FleetStatusPanel refuses). Absent must therefore be WHOLE.
  expect(at(null)).toBeCloseTo(0.9, 10)
  expect(at(undefined)).toBeCloseTo(0.9, 10)
})

// ── THE RENDERER: one function, both form arms ──────────────────────────────────────────────────────

const IMAGE: ShipVisual = {
  form: { kind: 'image', href: 'ships/frigate.png', viewBox: 64 },
  sizePx: 9.45,
  tone: 'var(--color-accent)',
  fillOpacity: 0.9,
  known: true,
}

test('THE SWAP IS A DATA CHANGE — an image form draws at the SAME place and the SAME size as paths', () => {
  // This is the property that makes the owner's art a one-file edit: `sizePx`, `tone` and the point are
  // untouched by which arm the form is on, and ONE renderer handles both, so no consumer changes.
  const at = { x: 100, y: 200, k: 1, pxScale: 1 }
  const paths = shipVisual({ typeId: 'starter_frigate', side: 'player', kind: 'fleet', mass: 2000 })
  expect(paths.sizePx).toBe(IMAGE.sizePx) // the SAME fleet, the same bulk, the same size
  const half = shipGlyphHalf(IMAGE, at)
  expect(half).toBe(IMAGE.sizePx)

  const img = renderShipVisual(IMAGE, at)
  expect(img.type).toBe('image')
  expect(props(img)).toMatchObject({
    href: 'ships/frigate.png',
    x: 100 - half,
    y: 200 - half,
    width: half * 2,
    height: half * 2,
    opacity: IMAGE.fillOpacity,
  })

  const p = renderShipVisual(paths, at)
  expect(p.type).toBe('path')
  // the paths arm covers the same span: scaled from its own 24-box onto 2 × half, re-centred on the point
  expect(props(p)['transform']).toBe(`translate(100 200) scale(${(half * 2) / 24}) translate(-12 -12)`)
  // both arms are pointer-transparent and both say which arm they are, so a spec can tell them apart
  for (const el of [img, p]) {
    expect((props(el)['style'] as { pointerEvents: string }).pointerEvents).toBe('none')
  }
  expect(props(img)['data-ship-form']).toBe('image')
  expect(props(p)['data-ship-form']).toBe('paths')
})

test('SIZE IS IN CSS PIXELS — ÷k alone is what made the fleet marker 4 pixels wide on the phone', () => {
  const v = shipVisual({ typeId: 'starter_frigate', side: 'player', kind: 'fleet', mass: 2000 })
  // The owner's 390px phone: pxScale = 390/1000 = 0.39, so a CSS-px size must be DIVIDED by it to
  // survive the letterbox. A glyph sized ÷k only would render at 0.39× — measured, and unreadable.
  expect(shipGlyphHalf(v, { x: 0, y: 0, k: 1, pxScale: 0.39 })).toBeCloseTo(v.sizePx / 0.39, 10)
  // zoom still divides, so the glyph stays a constant on-screen size at any camera
  expect(shipGlyphHalf(v, { x: 0, y: 0, k: 4, pxScale: 1 })).toBeCloseTo(v.sizePx / 4, 10)
  // an unmeasured caller keeps the historic ÷k behaviour rather than collapsing to nothing
  for (const bad of [undefined, 0, -1, Number.NaN]) {
    expect(shipGlyphHalf(v, { x: 0, y: 0, k: 1, pxScale: bad as number | undefined })).toBe(v.sizePx)
  }
})

test('shipGlyphFillsBox makes a glyph exactly fill an inline 24-box (the roster row’s icon)', () => {
  const v = shipVisual({ typeId: 'bulk_hauler', side: 'player', kind: 'unit', mass: 650 })
  expect(shipGlyphHalf(v, shipGlyphFillsBox(v))).toBeCloseTo(12, 10)
  const el = renderShipVisual(v, shipGlyphFillsBox(v))
  expect(props(el)['transform']).toBe('translate(12 12) scale(1) translate(-12 -12)')
})
