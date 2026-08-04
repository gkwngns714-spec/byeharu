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

test('the SHIP roster heading no longer says the fleet twice', () => {
  // Live on screen, 2026-08-04: "FLEET 1 · FLEET 1 · 4 SHIPS". The heading printed the group's NAME
  // and then re-announced it as "Fleet <group_index>" — and the owner's fleets are named "Fleet 1"
  // and "Fleet 2", so the slot index said nothing the name had not already said. The prefix-by-hand
  // is gone; the name comes from the ONE rule.
  //
  // REPOINTED 2026-08-04 (SIDE BY SIDE): the roster markup moved out of ShipScreen.tsx into
  // ShipsView.tsx — ShipScreen now owns the reads only. The invariant is unchanged and is asserted
  // against the file that actually renders the heading; ShipScreen is additionally held to building
  // NO fleet name at all, so the rule cannot quietly grow a second home.
  const view = src('features/ship/ShipsView.tsx')
  expect(view, 'the roster heading must not re-announce the slot index').not.toMatch(
    /\{group\.name\} · Fleet \{group\.group_index\}/,
  )
  expect(view).toContain("import { fleetLabel } from '../command/fleetLabel'")
  expect(view).toContain('{fleetLabel(group.name)}')
  expect(src('features/ship/ShipScreen.tsx'), 'the reads file names no fleet').not.toContain(
    'fleetLabel',
  )
})

test('the map builds a fleet name in exactly ONE place, through the ONE rule', () => {
  // STRONGER than the assertion it replaces. That one required the FOUR badge resolvers to each
  // COMPOSE fleetLabel (>= 6 call sites) — the best check available while four resolvers each built
  // their own label. There is now ONE presence authority, so the honest property is sharper: the name
  // is built ONCE, and the presentation file that draws the badges does not build it at all.
  const presence = src('features/map/fleetPresence.ts')
  const markers = src('features/map/teamMarkers.ts')
  expect(presence).toContain("import { fleetLabel } from '../command/fleetLabel'")
  expect((presence.match(/fleetLabel\(/g) ?? []).length).toBe(1)
  expect(markers, 'the badge layer renders labels, it does not compose them').not.toContain('fleetLabel')
  for (const [name, file] of [['fleetPresence', presence], ['teamMarkers', markers]] as const) {
    expect(file, `${name}: no badge may build the prefix by hand`).not.toMatch(/`Fleet \$\{/)
  }
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
// REPOINTED (ASSETS-TAB, 2026-08-04): the nav markup moved out of AppShell into NavBar.tsx so the
// bar could be rendered and MEASURED on its own at 320px (tests/navFits.uispec.ts). The property
// this test protects is unchanged — a live battle is announced on every screen, keyed off the one
// tab table, riding already-polled state — it just holds one file down now. Repointed to the real
// structure and STRENGTHENED while here: the shell owns the polled count, the bar owns the alert,
// neither hardcodes which destination is the combat one, and there is exactly ONE bar.
test('the nav carries a combat alert, keyed off the ONE tab table', () => {
  const shell = src('app/AppShell.tsx')
  const nav = src('app/NavBar.tsx')
  const tabs = src('app/navTabs.ts')
  expect(tabs).toContain('export const COMBAT_TAB_TO')
  // The BAR draws the alert, and asks the TABLE which destination owns it.
  expect(nav).toContain('COMBAT_TAB_TO')
  expect(nav).toContain('nav-combat-alert')
  // It rides the already-polled shell state, never its own read: the shell reads combat.encounters
  // and hands the count down as a prop; the bar queries nothing.
  expect(shell).toContain('combat.encounters.length')
  expect(nav, 'the bar must not fetch combat state itself').not.toContain('useCombat')
  // Neither file may hardcode which destination owns combat — that is the table's job.
  expect(nav, 'the bar must not hardcode which destination owns combat').not.toContain("t.to === '/mission'")
  expect(shell, 'the shell must not hardcode which destination owns combat').not.toContain("'/mission'")
  // ONE bar: the extraction must not have left a second copy behind in the shell.
  expect(shell).toContain('<NavBar')
  expect(shell, 'the shell must not still carry its own copy of the bar').not.toContain('data-testid="app-nav"')
})

// ── the poll cannot regress the readout ───────────────────────────────────────────────────────────
test('the combat poll has an in-flight guard AND a sequence token', () => {
  const hook = src('features/combat/useCombat.ts')
  expect(hook).toContain('inFlight')
  expect(hook).toContain('if (inFlight.current) return')
  // the guard alone cannot order an explicit refresh against the interval — the stamp can
  expect(hook).toContain('if (mine <= applied.current) return')
})
