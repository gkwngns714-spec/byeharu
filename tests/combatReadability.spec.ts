import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { fleetLabel } from '../src/features/command/fleetLabel'
import { feedRows } from '../src/features/combat/combatFeed'
import type { CombatEvent } from '../src/features/combat/combatTypes'

const here = dirname(fileURLToPath(import.meta.url))
const src = (rel: string) => readFileSync(join(here, '..', 'src', rel), 'utf8')

// THE SMALL LIES THE PLAYER READS — each of these was live on screen.

// ── "Fleet Fleet 2" ────────────────────────────────────────────────────────────────────────────────
test('a group already named "Fleet 2" is not announced as "Fleet Fleet 2"', () => {
  expect(fleetLabel('Fleet 2')).toBe('Fleet 2')
  expect(fleetLabel('fleet 2')).toBe('fleet 2')
  expect(fleetLabel('FLEET 2')).toBe('FLEET 2')
  expect(fleetLabel('  Fleet 2 ')).toBe('Fleet 2')
})

test('a group named anything else still gets the word', () => {
  expect(fleetLabel('Vanguard')).toBe('Fleet Vanguard')
  // "Fleet Ghost Fleet" is the wrong repair — the word only leads, it is not merely present
  expect(fleetLabel('Ghost Fleet')).toBe('Fleet Ghost Fleet')
  expect(fleetLabel('')).toBe('Fleet')
  expect(fleetLabel(null)).toBe('Fleet')
})

test('all four map badges compose the ONE label rule — no inline prefix survives', () => {
  const markers = src('features/map/teamMarkers.ts')
  expect(markers).toContain("import { fleetLabel } from '../command/fleetLabel'")
  expect((markers.match(/fleetLabel\(/g) ?? []).length).toBeGreaterThanOrEqual(6)
  expect(markers, 'no badge may build the prefix by hand').not.toMatch(/`Fleet \$\{/)
})

// ── "1  destroyed" ─────────────────────────────────────────────────────────────────────────────────
test('a destroyed ship is named — no noun-less, double-spaced line', () => {
  const layer = src('features/combat/CombatEventLayer.tsx')
  // the spatial payload is {count, unit_id}; `cap(p.group)` was empty, so the row read "1  destroyed"
  expect(layer).not.toContain('${num(p.count)} ${cap(p.group)} destroyed')
  expect(layer).toContain('of our ships destroyed')
  expect(layer).toContain('Pirate ship destroyed')
})

// ── wave 1, announced twice ────────────────────────────────────────────────────────────────────────
const ev = (o: Partial<CombatEvent> & { id: number }): CombatEvent => ({
  encounter_id: 'e1',
  tick_number: 0,
  seq: 0,
  event_type: 'wave_spawned',
  source: 'pirate',
  target: 'player',
  projectile_type: null,
  projectile_count: null,
  impact_delay_ms: null,
  payload_json: { wave: 1 },
  created_at: '',
  ...o,
})

test('a wave announces itself ONCE, however many times the server emits it', () => {
  const rows = feedRows([
    ev({ id: 1, tick_number: 0 }),
    ev({ id: 2, tick_number: 1 }), // production emits wave 1 twice
    ev({ id: 3, tick_number: 9, payload_json: { wave: 2 } }),
  ])
  expect(rows.map((r) => r.id)).toEqual([3, 2]) // newest first; one row per wave
})

test('a wave in a DIFFERENT fight is its own announcement', () => {
  const rows = feedRows([ev({ id: 1 }), ev({ id: 2, encounter_id: 'e2' })])
  expect(rows).toHaveLength(2)
})

test('nothing else is merged — two hits really are two hits', () => {
  const hit = (id: number) =>
    ev({ id, event_type: 'hull_damage', tick_number: 17, payload_json: { unit_id: 'a', damage: 4 } })
  expect(feedRows([hit(1), hit(2)])).toHaveLength(2)
})

// ── a battle is announced on every screen ─────────────────────────────────────────────────────────
test('the nav carries a combat alert, keyed off the ONE tab table', () => {
  const shell = src('app/AppShell.tsx')
  const tabs = src('app/navTabs.ts')
  expect(tabs).toContain('export const COMBAT_TAB_TO')
  expect(shell).toContain('COMBAT_TAB_TO')
  expect(shell).toContain('nav-combat-alert')
  // it must ride the already-polled state, never its own read
  expect(shell).toContain('combat.encounters.length > 0')
  expect(shell, 'the shell must not hardcode which destination owns combat').not.toContain("t.to === '/mission'")
})

// ── the poll cannot regress the readout ───────────────────────────────────────────────────────────
test('the combat poll has an in-flight guard AND a sequence token', () => {
  const hook = src('features/combat/useCombat.ts')
  expect(hook).toContain('inFlight')
  expect(hook).toContain('if (inFlight.current) return')
  // the guard alone cannot order an explicit refresh against the interval — the stamp can
  expect(hook).toContain('if (mine <= applied.current) return')
})
