import { test, expect } from '@playwright/test'
import { NAV_TABS, navGridClass, COMBAT_TAB_TO } from '../src/app/navTabs'
import { ICON_NAMES } from '../src/components/ui/icons'
import { TEAM_COMMAND_ENABLED } from '../src/features/map/osnReleaseGates'

// The bottom-nav contract (src/app/navTabs.ts) — AppShell renders exactly this table (through
// NavBar.tsx, its only mount), so these specs pin the table's SHAPE. What the table costs in
// PIXELS is a different question, and it is MEASURED rather than argued, in
// tests/navFits.uispec.ts — the stale "five is the ceiling" estimate that used to live in a
// comment, and was never rendered, is exactly why.

test('the six destinations, in order: Map · Ships · Fleet · Assets · Port · Mission', () => {
  // TEAM_COMMAND_ENABLED is a compile-time `true` (activated 2026-07-12); if that gate is ever
  // re-darkened this spec must change WITH the table (the Fleet tab legitimately disappears).
  // ASSETS-TAB (2026-08-04): the owner asked to "see my assets… the estimate price, on which
  // city". It sits beside Ships/Fleet because those three answer "what do I have"; Port and
  // Mission are places you go to DO something.
  expect(TEAM_COMMAND_ENABLED).toBe(true)
  expect(NAV_TABS.map((t) => t.label)).toEqual(['Map', 'Ships', 'Fleet', 'Assets', 'Port', 'Mission'])
  expect(NAV_TABS.map((t) => t.to)).toEqual(['/map', '/ship', '/fleet', '/assets', '/port', '/mission'])
})

test('every tab wears a real design-system icon', () => {
  for (const t of NAV_TABS) expect(ICON_NAMES).toContain(t.icon)
})

test('the Assets tab reuses an EXISTING glyph — no new icon entered the set for it', () => {
  expect(NAV_TABS.find((t) => t.label === 'Assets')?.icon).toBe('layers')
})

test('tab testids (nav-<label lowercased>) are unique — no two tabs collide in a spec selector', () => {
  const ids = NAV_TABS.map((t) => `nav-${t.label.toLowerCase()}`)
  expect(new Set(ids).size).toBe(ids.length)
})

test('routes are unique — one destination per tab, one tab per destination', () => {
  const tos = NAV_TABS.map((t) => t.to)
  expect(new Set(tos).size).toBe(tos.length)
})

test('the combat alert still marks a destination that exists in the table', () => {
  // The dot is drawn on ONE cell. If a future edit renamed or dropped /mission, the dot would
  // silently stop rendering and a live battle would go unannounced again.
  expect(NAV_TABS.map((t) => t.to)).toContain(COMBAT_TAB_TO)
})

test('navGridClass matches the tab count (both legal widths are static Tailwind literals)', () => {
  // ASSETS-TAB moved both legal counts up by one: 5 when the Fleet gate is dark, 6 when it is lit.
  // grid-cols-4 retired with the four-cell bar — the table can no longer produce four.
  expect(navGridClass(6)).toBe('grid-cols-6')
  expect(navGridClass(5)).toBe('grid-cols-5')
  // The class AppShell actually renders agrees with the live table.
  expect(navGridClass(NAV_TABS.length)).toBe(NAV_TABS.length === 6 ? 'grid-cols-6' : 'grid-cols-5')
})

test('the table stays inside the width the fit proof has actually been RUN against', () => {
  // tests/navFits.uispec.ts measures the RENDERED bar at 320px and asserts a 44px touch floor; it
  // measured a cell as exactly viewport ÷ count (53.33px at six). By that measured divisor, seven
  // cells would be 45.7px (still above the floor) and eight would be 40px (below it). This guard
  // fails FIRST, in the fast pure suite, if the table ever grows past the count the rendered proof
  // has been run against — so nobody discovers it from a clipped label on a phone instead.
  expect(NAV_TABS.length).toBeLessThanOrEqual(6)
  expect(320 / NAV_TABS.length).toBeGreaterThanOrEqual(44)
})
