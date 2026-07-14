import { test, expect } from '@playwright/test'
import {
  commandBuffsEnabledFromConfig,
  shipCommandBuffCard,
  type CommandBuffTypeRow,
} from '../src/features/ship/commandBuff'
import { strictConfigFlag } from '../src/lib/gameConfigFold'

// COMMAND-BUFFS (0205) — pure-logic specs for the dossier COMMAND BUFF line (no app/Supabase).
// Asserts the house mold: the STRICT jsonb-true config fold (the shared strictConfigFlag — the
// trait/commission/salvage posture, ONE implementation), the fail-closed single-buff × catalog join
// (unknown id → muted line, null id → hidden, never a crash), and effect-label reuse (the shared
// traitEffects formatter, no hp_mult line). The client renders the STORED buff id only — no
// derivation logic exists here to test, by design (the server-truth law).
// Run: `npx playwright test commandBuff.spec.ts`.

// ── the strict fold (shared helper + the COMMAND-BUFFS wrapper) ───────────────────────────────────

test('fold: ONLY jsonb true reads as lit', () => {
  expect(commandBuffsEnabledFromConfig([{ key: 'command_buffs_enabled', value: true }])).toBe(true)
})

test('fold: everything else fails CLOSED to dark', () => {
  for (const value of ['true', 1, 'enabled', {}, [], null, undefined, false]) {
    expect(commandBuffsEnabledFromConfig([{ key: 'command_buffs_enabled', value }])).toBe(false)
  }
  expect(commandBuffsEnabledFromConfig([])).toBe(false) // failed config read → [] → dark
  expect(commandBuffsEnabledFromConfig([{ key: 'other_flag', value: true }])).toBe(false)
  // duplicate key (unreachable — key is a PK) LAST wins (the strict fold direction; an any-true scan
  // would fail OPEN here).
  expect(
    commandBuffsEnabledFromConfig([
      { key: 'command_buffs_enabled', value: true },
      { key: 'command_buffs_enabled', value: false },
    ]),
  ).toBe(false)
})

test('fold: the shared helper is key-scoped (a different lit flag never leaks in)', () => {
  const rows = [
    { key: 'fleet_control_enabled', value: true },
    { key: 'command_buffs_enabled', value: false },
  ]
  expect(strictConfigFlag(rows, 'fleet_control_enabled')).toBe(true)
  expect(strictConfigFlag(rows, 'command_buffs_enabled')).toBe(false)
})

// ── the single-buff view-model join ────────────────────────────────────────────────────────────────

const catalog: CommandBuffTypeRow[] = [
  {
    buff_id: 't0_gunnery_command',
    tier: 'T0',
    name: 'Gunnery Command',
    description: 'Every hull shoots a shade truer.',
    stats_json: { attack: 3 },
  },
  {
    buff_id: 't1_convoy_doctrine',
    tier: 'T1',
    name: 'Convoy Doctrine',
    description: 'The fleet hauls more, faster.',
    stats_json: { cargo: 6, speed_mult_bonus: 0.02 },
  },
]

test('card: joins the stored buff id against the catalog, effects via the shared formatter', () => {
  expect(shipCommandBuffCard('t0_gunnery_command', catalog)).toEqual({
    kind: 'buff',
    buff_id: 't0_gunnery_command',
    tier: 'T0',
    name: 'Gunnery Command',
    description: 'Every hull shoots a shade truer.',
    effects: [{ label: '+3 attack', tone: 'positive' }],
  })
  // a two-key buff: flat cargo precedes the multiplier percent (the pinned vocabulary order), and
  // there is NEVER an hp_mult hull line (a command buff carries no hp_mult).
  expect(shipCommandBuffCard('t1_convoy_doctrine', catalog)).toEqual({
    kind: 'buff',
    buff_id: 't1_convoy_doctrine',
    tier: 'T1',
    name: 'Convoy Doctrine',
    description: 'The fleet hauls more, faster.',
    effects: [
      { label: '+6 cargo', tone: 'positive' },
      { label: '+2% speed', tone: 'positive' },
    ],
  })
})

test('card: a null / empty buff id → null (the dossier hides the line — never invents a buff)', () => {
  expect(shipCommandBuffCard(null, catalog)).toBeNull()
  expect(shipCommandBuffCard(undefined, catalog)).toBeNull()
  expect(shipCommandBuffCard('', catalog)).toBeNull()
})

test('card: an unknown buff id fails CLOSED to a muted unknown card — never a crash, never dropped', () => {
  expect(shipCommandBuffCard('not_in_catalog', catalog)).toEqual({ kind: 'unknown', buff_id: 'not_in_catalog' })
})
