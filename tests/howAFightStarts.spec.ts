import { test, expect } from '@playwright/test'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  A_ZONE_IS_NOT_A_HUNT,
  HOW_A_FIGHT_STARTS,
  huntSiteActionLabel,
} from '../src/features/command/howAFightStarts'
import { buildZoneInfo } from '../src/features/map/zoneInfoModel'
import { deriveFirstOrders } from '../src/features/onboarding/firstOrders'
import { teamReasonMessage } from '../src/features/command/teamReasonMessage'
import { teamDestinationKind } from '../src/features/command/teamDestination'

// ═══════════════════════════════════════════════════════════════════════════════════════════════
// HOW A FIGHT STARTS — the spec that stops this recurring.
//
// Owner, 2026-08-03, playing: "i went to snare, zone, no fighting happens. why are you keep
// messing things up? spaghetti of course. do it properly"
//
// They were right, and every part of the cause was ours. Verified against production
// (head 20260618000335): their four trips that afternoon were `mission_type='rally'`,
// `target_type='space'`, aimed at bare coordinates near — never at — the Snare SITE. Two rolled an
// ambush and MISSED; two never rolled. No fight could have started, because a fight starts EXACTLY
// one way and no screen said what it was. Three screens described combat three different ways and
// the one the owner read named the zone.
//
// This file exists so that cannot come back. It is deliberately a SOURCE SCAN and not a set of
// string equality checks: the failure was never one wrong sentence, it was a SECOND sentence.
// ═══════════════════════════════════════════════════════════════════════════════════════════════

const here = dirname(fileURLToPath(import.meta.url))
const SRC = join(here, '..', 'src')

/** Every .ts/.tsx under src/ — the whole player-facing surface, not a hand-kept list that rots. */
function sourceFiles(dir: string = SRC): string[] {
  return readdirSync(dir).flatMap((entry) => {
    const full = join(dir, entry)
    if (statSync(full).isDirectory()) return sourceFiles(full)
    return /\.tsx?$/.test(entry) ? [full] : []
  })
}

const FILES = sourceFiles().map((f) => ({ path: relative(SRC, f).replace(/\\/g, '/'), text: readFileSync(f, 'utf8') }))

/**
 * Comment-stripped source. Every rule below is about what a PLAYER reads, and this file's own
 * account of the incident necessarily quotes the sentences it bans — as do the notes left at each
 * repaired site. Scanning raw text would make the explanations illegal, which is how a guard like
 * this ends up deleted instead of obeyed.
 */
function playerFacing(text: string): string {
  return text
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .split('\n')
    .filter((l) => !/^\s*(\/\/|\*)/.test(l))
    .join('\n')
}

const PLAYER_TEXT = FILES.map((f) => ({ ...f, text: playerFacing(f.text) }))

// ── 1 · THE SENTENCE THE OWNER FOLLOWED IS GONE, AND CANNOT COME BACK ─────────────────────────────

test('no source anywhere tells a player that going INTO a zone starts a hunt', () => {
  // MissionScreen.tsx:93 said "send a fleet to a port to trade, or into a pirate zone to hunt."
  // The player did that. `command_ship_group_go` refuses a combat destination outright (reason
  // `combat_destination`) and a bare coordinate inside a zone is simply travel, so the instruction
  // could not work on either reading. The patterns catch the SHAPE, not the one sentence.
  const banned: [RegExp, string][] = [
    [/into a pirate zone to hunt/i, 'the exact instruction the owner followed'],
    [/\bhunt\b[^.]{0,40}\bby (?:flying|travelling|traveling|moving)\b/i, 'travel dressed up as a hunt'],
    [/(?:send|move|travel)[^.]{0,40}\binto\b[^.]{0,20}\bzone\b[^.]{0,20}\bto (?:hunt|fight|attack)\b/i, 'zone-as-destination'],
    [/almost always attacked/i, 'a certainty the roll does not deliver'],
  ]
  for (const { path, text } of PLAYER_TEXT) {
    for (const [pattern, why] of banned) {
      expect(text, `${path} — ${why}`).not.toMatch(pattern)
    }
  }
})

// ── 2 · ONE DESCRIPTION, NOT SEVERAL ─────────────────────────────────────────────────────────────

test('every surface that explains how to fight COMPOSES the one authority — none writes its own', () => {
  // The defect was three screens with three answers. Any file that hands a player instructions
  // about fighting must import them; a hand-written variant is the thing this test forbids.
  const mustCompose = [
    'features/command/MissionScreen.tsx', // the ops empty state — the one the owner read
    'features/command/TeamRosterPanel.tsx', // the fleet roster's "how fleets work" line
    'features/command/teamReasonMessage.ts', // the map's own refusal copy
    'features/map/zoneInfoModel.ts', // "what's here" over a pirate zone
    'features/map/FleetCommandPanel.tsx', // the map's idle prompt
    'features/onboarding/firstOrders.ts', // a new player's literal first orders
  ]
  for (const path of mustCompose) {
    const file = FILES.find((f) => f.path === path)
    expect(file, `${path} must exist — the sweep is keyed to it`).toBeTruthy()
    expect(file!.text, `${path} must import the hunt-copy authority, not restate it`).toMatch(
      // Any relative depth — './', '../command/', '../../command/' — one module either way.
      /from '[^']*howAFightStarts'/,
    )
  }
})

test('the authority itself is the ONLY place the sentences are written', () => {
  const authored = PLAYER_TEXT.filter(
    (f) => f.path !== 'features/command/howAFightStarts.ts' && f.text.includes(HOW_A_FIGHT_STARTS),
  )
  expect(authored.map((f) => f.path), 'a literal copy of the sentence is a second authority').toEqual([])
  const zoneAuthored = PLAYER_TEXT.filter(
    (f) => f.path !== 'features/command/howAFightStarts.ts' && f.text.includes(A_ZONE_IS_NOT_A_HUNT),
  )
  expect(zoneAuthored.map((f) => f.path)).toEqual([])
})

// ── 3 · THE DESCRIPTION IS TRUE ──────────────────────────────────────────────────────────────────

test('the sentence names the SITE and the verb — the two facts whose absence cost the afternoon', () => {
  // "at the Snare" named a place and left the player to guess the gesture; they guessed the zone.
  expect(HOW_A_FIGHT_STARTS).toMatch(/\bsite\b/i)
  expect(HOW_A_FIGHT_STARTS).toMatch(/\bHunt\b/)
  expect(HOW_A_FIGHT_STARTS).toMatch(/\bMap\b/)
  // It must NOT tell a player to aim at a zone, which is the whole defect.
  expect(HOW_A_FIGHT_STARTS.toLowerCase()).not.toContain('zone')
})

test('the zone sentence separates a zone from a hunt, and promises no certainty', () => {
  expect(A_ZONE_IS_NOT_A_HUNT).toMatch(/\bnot a hunt\b/i)
  // The owner kept the probabilistic ambush; copy that says "always" would be the old lie renamed.
  expect(A_ZONE_IS_NOT_A_HUNT).not.toMatch(/\balways\b/i)
  expect(A_ZONE_IS_NOT_A_HUNT).toMatch(/\bmay\b/i)
})

test('no player-facing copy prints a raw risk or roll number', () => {
  // Rule 2 of the near-miss design, applied to the whole vocabulary: probabilities are a debug
  // readout. A percentage invites the player to argue with the dice instead of feeling them.
  for (const s of [HOW_A_FIGHT_STARTS, A_ZONE_IS_NOT_A_HUNT, huntSiteActionLabel('Snare')]) {
    expect(s).not.toMatch(/\d+\s*%|0\.\d+/)
  }
})

// ── 4 · THE SURFACES AGREE ───────────────────────────────────────────────────────────────────────

test('the zone panel, the first-orders checklist and the map refusal all say the same thing', () => {
  const site = {
    id: 'loc-snare',
    name: 'Snare',
    status: 'active',
    activity_type: 'hunt_pirates',
    location_type: 'pirate_hunt',
    x: -45,
    y: 120,
    base_difficulty: 10,
    reward_tier: 2,
    min_power_required: 0,
    is_public: true,
    territory_radius: null,
  }
  // …the same classifier the MAP uses to decide the hunt section renders at all.
  expect(teamDestinationKind(site)).toBe('hunt')

  const zoneInfo = buildZoneInfo(
    {
      id: 'z-snare',
      name: 'Snare',
      source: 'drawn',
      location_id: 'loc-snare',
      ring: [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]],
      revision: 1,
    },
    [site as never],
  )
  expect(zoneInfo.warning).toContain(HOW_A_FIGHT_STARTS)
  expect(zoneInfo.huntSite?.label).toBe(huntSiteActionLabel('Snare'))

  const firstHunt = deriveFirstOrders({
    shipCount: 1,
    docked: true,
    wonBattle: false,
    expeditionsLit: true,
    additionalShipsLit: false,
  }).find((s) => s.id === 'first-hunt')
  expect(firstHunt?.hint).toContain(HOW_A_FIGHT_STARTS)

  // The SERVER's refusal is a rule, not a bug to route around — `command_ship_group_go`'s own
  // comment says "A move is not a hunt: hunts go through send_ship_group_hunt". The copy explains
  // it in the same words rather than arguing with it, and never surfaces the raw code.
  const refusal = teamReasonMessage('combat_destination')
  expect(refusal).toContain(HOW_A_FIGHT_STARTS)
  expect(refusal).not.toContain('combat_destination')
})

test('the checklist step still points at the starter site, without the map-zone name that confused it', () => {
  const hint = deriveFirstOrders({
    shipCount: 1,
    docked: true,
    wonBattle: false,
    expeditionsLit: true,
    additionalShipsLit: false,
  }).find((s) => s.id === 'first-hunt')!.hint
  expect(hint).toContain('Snare')
  // "the Snare (Wreck Belt)" put a map-zone name inside a sentence about a site — the exact
  // site/zone conflation this whole slice exists to end.
  expect(hint).not.toContain('Wreck Belt')
})
