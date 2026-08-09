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

/** Source with comment lines stripped — so an assertion about what the component RENDERS is not
 *  satisfied by the paragraph that explains what it deliberately does not render. */
// BLOCK comments go too: a JSX `{/* ... */}` paragraph is the form most of this file's reasoning
// takes, and a probe that trips over its own justification fails the build for saying the right thing.
const codeOnly = (text: string) =>
  text
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .split(/\r?\n/)
    .filter((l) => !l.trim().startsWith('//') && !l.trim().startsWith('*'))
    .join('\n')

test('the card is mounted on the MAP, over the shell state that is already polled', () => {
  expect(mapScreen).toContain("import { CombatMapCard } from './CombatMapCard'")
  // Every prop is the shell state already polled for the map — no second fetch, no second poll.
  expect(mapScreen).toContain(`<CombatMapCard`)
  for (const prop of ['encounters={combat.encounters}', 'units={combat.units}', 'ticks={combat.ticks}', 'autoExit={combat.autoExit}']) {
    expect(mapScreen, `the card must be fed ${prop} from the shell`).toContain(prop)
  }
})

test('THE ENGINE DECIDES WHETHER A SHIP ARRIVES -- the card never does', () => {
  // The spawn rule is `population < effective_cap` and BOTH operands are on the wire, so the client
  // could compute it. It must not: one rule in two places drifts, and the answer is about a moment
  // that has not happened (a full field can lose a hull two seconds before the slot). The card shows
  // the countdown, the ordinal, the population and the STAMPED cap, and states the rule as a rule.
  const code = codeOnly(card)
  expect(code, 'the cap is shown, never derived').not.toMatch(/concurrent_cap|cap_growth_every/)
  // Whitespace-dense so a line break cannot hide a comparison. Both directions of both operands.
  const dense = code.replace(/\s+/g, '')
  for (const bad of [
    'wave.population<', 'wave.population<=', 'wave.population>', 'wave.population>=',
    '<wave.cap', '<=wave.cap', '>wave.cap', '>=wave.cap',
  ]) {
    expect(dense, `the card must not compute the engine's spawn decision (${bad})`).not.toContain(bad)
  }
  expect(code, 'and no promise of an arrival').not.toMatch(/arriving|will arrive|incoming ship/i)
  // The two numbers ARE both printed -- that is the point; the player reads them against the rule.
  expect(code).toContain('wave.population')
  expect(code).toContain('wave.cap')
  expect(code).toContain('REINFORCEMENT_RULE')
})

test('the DEAD wave counter is gone from the header', () => {
  // Since 0344 `wave_number` only moves when the whole field is EMPTIED, which under a reinforcement
  // clock is rare -- it sat on 1 for entire fights. What moves is the field against the cap.
  const code = codeOnly(card)
  expect(code, 'wave_number must not be printed here').not.toContain('wave_number')
  expect(code, 'and the dead next_wave_at clock must not be read').not.toContain('next_wave_at')
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

// REPOINTED, and STRENGTHENED. The old assertion required the card to READ both power columns;
// that was asserting the defect. `enemy_power_current` is the enemy's remaining INTEGRITY, not
// power — 0299:150-156 says so in the migration that deliberately left it that way, and on every
// production row it equals `enemy_integrity_current` exactly. Printing it beside the player's real
// attack power under one word made a winning fight read as a hopeless one. The property that
// matters now is the opposite one: both sides show the SAME comparable quantity, and the
// non-comparable column is not rendered at all.
test('both sides show the same comparable quantity — hull, never "power"', () => {
  expect(card).toContain('player_integrity_current')
  expect(card).toContain('enemy_integrity_current')
  expect(card).toContain('player_integrity_max')
  expect(card).toContain('enemy_integrity_max')
  // the mislabelled column may appear ONLY in the comment that explains why it is not rendered
  const code = codeOnly(card)
  expect(code, 'the card must not render enemy_power_current').not.toContain('enemy_power_current')
  expect(code, 'the card must not render player_power_current either — the two are not comparable').not.toContain('player_power_current')
})

test('the card carries the LAST EXCHANGE and the auto-retreat line, from the ONE derivations', () => {
  // "am I winning" needs a rate, not two static bars; the exchange comes straight off combat_ticks.
  expect(card).toContain('player_damage')
  expect(card).toContain('enemy_damage')
  // …and the safety line is the shared resolver, never re-derived here
  expect(card).toContain('resolveAutoExitLine')
  expect(card).not.toContain('auto_exit_hp_pct')
})

test('retreat is the ONE shared control -- and it is no longer inside this readout', () => {
  // MOVED, and the move is the point. The card is now the FIGHT TAB'S BODY, and a tab can be closed.
  // A way out of a fight that disappears when the player folds a panel away is a way out they do not
  // have, so RetreatControl is pinned by the tab shell OUTSIDE the tabs, per live encounter.
  expect(card, 'the readout carries no control at all now').not.toContain('<RetreatControl')
  // a hand-rolled retreat here would mean two busy flags and two readings of the server reject
  expect(card).not.toContain('requestRetreat')
  const shell = src('features/map/MapOverlayTabs.tsx')
  expect(shell, 'the map mounts the shared control in the tab shell').toContain('<RetreatControl')
  expect(shell).not.toContain('requestRetreat')
  const panel = src('features/combat/ActiveCombatPanel.tsx')
  expect(panel).toContain('<RetreatControl')
  expect(panel).not.toContain('requestRetreat')
})

test('THE FIGHT TAB is where this readout is mounted, with the reads its haul needs', () => {
  // Every prop is state the shell already holds -- no second fetch and no second poll for the card.
  for (const prop of ['itemVolumes={itemVolumes}', 'holds={combat.holds}', 'siteLoot={combat.siteLoot}']) {
    expect(mapScreen, `the fight tab must be fed ${prop}`).toContain(prop)
  }
  // ...and the haul is read through the ONE reader, never by touching the payload's keys inline.
  expect(card).toContain('resolveFightHaul(e.total_rewards_json')
  expect(card, 'the payload must never be iterated here').not.toContain("total_rewards_json['")
  // The cargo numbers are the SERVER's. A client-side sum of per-ship capacities is the exact fold
  // fleetStatusModel refuses, and get_my_hold is the authority it points at.
  expect(card).toContain('holdMeter(hold)')
  expect(card).not.toContain('cargo_capacity_m3')
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
