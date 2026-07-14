import { test, expect } from '@playwright/test'
import { teamDestinationKind, returnPortOptions } from '../src/features/command/teamDestination'

// TEAM-MAP-SEND — pure unit proof for the ONE destination-kind classifier the map sheet's
// "Send a team here" section renders from. It REUSES sendableDestinations/huntableDestinations
// (whose own bands are proven in teamSend.spec.ts / teamCombat.spec.ts) — these tests assert only
// what is NEW: the single-location classification and its null (not-a-team-destination) band.
// Run: `npx playwright test teamDestination.spec.ts`.

const loc = (o: Partial<{ id: string; name: string; status: string; activity_type: string }> = {}) => ({
  id: 'l1',
  name: 'Haven',
  status: 'active',
  activity_type: 'none',
  ...o,
})

test('active + activity none → expedition (the safe team send)', () => {
  expect(teamDestinationKind(loc())).toBe('expedition')
})

test('active + hunt_pirates → hunt (the combat team send)', () => {
  expect(teamDestinationKind(loc({ activity_type: 'hunt_pirates' }))).toBe('hunt')
})

test('active non-none, non-hunt activities are NOT team destinations (null)', () => {
  for (const activity of ['trade_visit', 'mine_resource', 'explore_derelict', 'rally']) {
    expect(teamDestinationKind(loc({ activity_type: activity }))).toBe(null)
  }
})

test('non-active locations are never team destinations, whatever the activity (defensive status clause)', () => {
  expect(teamDestinationKind(loc({ status: 'inactive', activity_type: 'none' }))).toBe(null)
  expect(teamDestinationKind(loc({ status: 'inactive', activity_type: 'hunt_pirates' }))).toBe(null)
})

// RETURN-PORT (NO-HOME 0199) — the pure fold behind the map sheet's dock-after-hunt picker. Proves
// only what is NEW: which ports become return options (the dockable band, hunt sites excluded), and
// that the launch port is the default (a convenience — the owner is NEVER forced back to origin, so
// the picker exposes every other dockable port as a live, selectable alternative).
const world = [
  { id: 'haven', name: 'Haven', status: 'active', activity_type: 'none' },
  { id: 'ember', name: 'Ember', status: 'active', activity_type: 'none' },
  { id: 'pit', name: 'Pirate Pit', status: 'active', activity_type: 'hunt_pirates' }, // hunt site — non-dockable
  { id: 'dead', name: 'Dead Port', status: 'inactive', activity_type: 'none' }, // not active — never a dock
]

test('return options are the dockable ports only (active + non-combat); hunt sites and inactive ports are excluded', () => {
  const { options } = returnPortOptions(world, 'haven')
  expect(options.map((o) => o.id)).toEqual(['ember', 'haven']) // sorted by name; pit + dead dropped
})

test('the launch port is the default (pre-selected convenience) and is itself a selectable option', () => {
  const { options, defaultId } = returnPortOptions(world, 'haven')
  expect(defaultId).toBe('haven')
  expect(options.some((o) => o.id === 'haven')).toBe(true)
})

test('a chosen return port other than the launch port is a real option the picker can pass through', () => {
  const { options, defaultId } = returnPortOptions(world, 'haven')
  const chosen = options.find((o) => o.id === 'ember')
  expect(chosen).toBeTruthy() // Ember != launch port (Haven) → freely dockable, never forced home
  expect(chosen!.id).not.toBe(defaultId)
})

test('the launch port is always present as the default even if the world poll momentarily lacks it', () => {
  const { options, defaultId } = returnPortOptions(world, 'ghost') // 'ghost' not in world
  expect(defaultId).toBe('ghost')
  expect(options.some((o) => o.id === 'ghost')).toBe(true) // still selectable — the default never dangles
})
