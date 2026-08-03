import { test, expect } from '@playwright/test'
import { NAV_TABS, navGridClass } from '../src/app/navTabs'
import { ICON_NAMES } from '../src/components/ui/icons'
import { TEAM_COMMAND_ENABLED } from '../src/features/map/osnReleaseGates'

// The bottom-nav contract (src/app/navTabs.ts) — AppShell renders exactly this table, so these
// specs pin the FLEET-TAB change: five destinations while the fleet gate is lit, the /fleet tab
// between Ships and Port, and a grid class that always matches the tab count.

test('the five destinations, in order: Map · Ships · Fleet · Port · Command', () => {
  // TEAM_COMMAND_ENABLED is a compile-time `true` (activated 2026-07-12); if that gate is ever
  // re-darkened this spec must change WITH the table (the tab legitimately disappears).
  expect(TEAM_COMMAND_ENABLED).toBe(true)
  expect(NAV_TABS.map((t) => t.label)).toEqual(['Map', 'Ships', 'Fleet', 'Port', 'Command'])
  expect(NAV_TABS.map((t) => t.to)).toEqual(['/map', '/ship', '/fleet', '/port', '/command'])
})

test('every tab wears a real design-system icon', () => {
  for (const t of NAV_TABS) expect(ICON_NAMES).toContain(t.icon)
})

test('tab testids (nav-<label lowercased>) are unique — no two tabs collide in a spec selector', () => {
  const ids = NAV_TABS.map((t) => `nav-${t.label.toLowerCase()}`)
  expect(new Set(ids).size).toBe(ids.length)
})

test('routes are unique — one destination per tab, one tab per destination', () => {
  const tos = NAV_TABS.map((t) => t.to)
  expect(new Set(tos).size).toBe(tos.length)
})

test('navGridClass matches the tab count (both legal widths are static Tailwind literals)', () => {
  expect(navGridClass(5)).toBe('grid-cols-5')
  expect(navGridClass(4)).toBe('grid-cols-4')
  // The class AppShell actually renders agrees with the live table.
  expect(navGridClass(NAV_TABS.length)).toBe(NAV_TABS.length === 5 ? 'grid-cols-5' : 'grid-cols-4')
})
