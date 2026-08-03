// COMBAT MAP CARD — the map-side combat readout. These tests pin the ONE property that matters
// architecturally: it is a VIEW of server rows, never a second source of combat truth. The database
// owns damage, power and outcomes; this component may only format what it is given.
import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const src = (rel: string) => readFileSync(join(here, '..', 'src', rel), 'utf8')
const card = src('features/map/CombatMapCard.tsx')
const mapScreen = src('features/map/MapScreen.tsx')

test('the card is mounted on the MAP, over the shell state that is already polled', () => {
  expect(mapScreen).toContain("import { CombatMapCard } from './CombatMapCard'")
  expect(mapScreen).toContain('<CombatMapCard encounters={combat.encounters} units={combat.units} />')
})

test('the ops-side panel is NOT replaced — the map card is a second VIEW, not a move', () => {
  // ActiveCombatPanel remains the ops destination's (MissionScreen — renamed from CommandScreen
  // in the MISSION-TAB slice); removing it would trade one gap for another.
  const missionScreen = src('features/command/MissionScreen.tsx')
  expect(missionScreen).toContain('<ActiveCombatPanel')
})

test('NO combat math lives in the client', () => {
  // The database is the authority for every combat number (combat_ticks are the authoritative log).
  // A client that derives damage/hit/power would be a second, silently-drifting rules engine.
  for (const forbidden of [
    'Math.random',      // no rolls
    'damage =',         // no damage derivation
    'hitChance',
    'attack *',         // no stat math
    'defense *',
    'power =',          // power is read, never computed
  ]) {
    expect(card, `CombatMapCard must not compute ${forbidden}`).not.toContain(forbidden)
  }
})

test('it renders nothing when nothing is fighting (clean-map law)', () => {
  expect(card).toMatch(/if \(live\.length === 0\) return null/)
})

test('a RETREATING encounter still shows — that is when the readout matters most', () => {
  expect(card).toMatch(/status === 'active' \|\| e\.status === 'retreating'/)
})

test('both sides are shown, each with power and integrity', () => {
  expect(card).toContain('player_power_current')
  expect(card).toContain('enemy_power_current')
  expect(card).toContain('player_integrity_current')
  expect(card).toContain('enemy_integrity_current')
})

test('ship counts sum alive_count — a unit row is a STACK, not one ship', () => {
  expect(card).toMatch(/reduce\(\(n, u\) => n \+ \(u\.alive_count \?\? 0\), 0\)/)
})

test('integrity percentage is guarded against a zero max rather than rendering NaN', () => {
  expect(card).toMatch(/integrityMax > 0 \?/)
})

test('an encounter with no positions SAYS so instead of leaving the map silently empty', () => {
  // The spatial layer draws nothing for null pos_x. Without this line the player sees a fight
  // reported in the card and no ships on the map, with no explanation.
  expect(card).toContain('no ship positions')
  expect(card).toMatch(/pos_x !== null/)
})
