import { test, expect } from '@playwright/test'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  DORMANT_MARKER,
  DORMANT_STAT_IDS,
  LEGACY_STAT_IDS,
  LEGACY_ENVELOPE_STAT_IDS,
  PLAYER_VISIBLE_STAT_IDS,
  STAT_DEFINITIONS,
  catalogKeyDisplayName,
  isEffectiveStatId,
  isLegacyStatId,
  isPlayerVisibleStatId,
  standingOfCatalogKey,
  standingOfLifecycle,
  standingOfStatId,
  statByCatalogKey,
  statById,
  statDisplayName,
} from '../src/features/stats/statLifecycle.ts'
import { ADDITIVE_STAT_KEYS, EFFECTIVE_STAT_KEYS } from '../src/features/command/teamSkillset.ts'

// STAT LIFECYCLE — the client's ONE authority on whether a stat may be shown as a benefit.
//
// THE RULING (owner, 2026-08-04): "A dormant stat must not be represented as an effective player
// benefit," and: "Do not fix this by adding another hardcoded list of dead stat identifiers…  The
// frontend must not independently maintain a conflicting active-stat allowlist."
//
// Run: `npx playwright test statLifecycle.spec.ts`

const here = dirname(fileURLToPath(import.meta.url))
const repo = join(here, '..')
const src = join(repo, 'src')

// ── THE MAPPING, AND ITS FAIL-CLOSED END ────────────────────────────────────────────────────────

test('the three declared lifecycles map to the three presentation standings', () => {
  expect(standingOfLifecycle('active')).toBe('effective')
  expect(standingOfLifecycle('dormant')).toBe('dormant')
  expect(standingOfLifecycle('deprecated')).toBe('legacy')
})

test('AN UNKNOWN LIFECYCLE FAILS CLOSED — it is never effective', () => {
  // The client mirror of stat_lifecycle_in_scope (0340:791-801): "an unknown lifecycle is NOT in any
  // scope: a value the table somehow admitted is treated as absent rather than as active." A
  // permissive default here is how a future lifecycle value would advertise a dead stat.
  for (const bogus of ['experimental', 'ACTIVE', 'Active', 'enabled', 'true', '', ' active', 'legacy']) {
    expect(standingOfLifecycle(bogus), `${JSON.stringify(bogus)} must not be effective`).toBe('unknown')
  }
})

test('an UNREGISTERED stat id or catalog key is unknown, and never player-visible', () => {
  for (const id of ['not_a_stat', 'attack', 'luck', '__proto__', 'constructor', 'toString']) {
    expect(standingOfStatId(id), `${id}`).toBe('unknown')
    expect(isEffectiveStatId(id)).toBe(false)
    expect(isPlayerVisibleStatId(id)).toBe(false)
    expect(statById(id)).toBeNull()
    expect(statDisplayName(id)).toBeNull()
  }
  for (const key of ['not_a_key', 'combat_power', 'survival', '__proto__']) {
    expect(standingOfCatalogKey(key), `${key}`).toBe('unknown')
    expect(statByCatalogKey(key)).toBeNull()
    expect(catalogKeyDisplayName(key)).toBeNull()
  }
})

// ── DORMANT STATS ARE NOT ADVERTISED AS EFFECTIVE ───────────────────────────────────────────────

test('every dormant stat is refused as an effective benefit, at both vocabularies', () => {
  expect(DORMANT_STAT_IDS.length).toBeGreaterThan(0)
  for (const statId of DORMANT_STAT_IDS) {
    expect(isEffectiveStatId(statId), `${statId} is advertised as effective`).toBe(false)
    expect(isPlayerVisibleStatId(statId), `${statId} may still carry a player number`).toBe(false)
    expect(PLAYER_VISIBLE_STAT_IDS).not.toContain(statId)
    const def = statById(statId)
    expect(def).toBeTruthy()
    // and by its INPUT key too — a catalog writes `mining`, not `mining_yield`
    expect(standingOfCatalogKey(def?.catalogKey ?? '')).toBe('dormant')
  }
})

test('mining_yield in particular is dormant, by both its names', () => {
  // The named residual violation of the 0340 ruling: `mining` was advertised as a working benefit.
  expect(standingOfStatId('mining_yield')).toBe('dormant')
  expect(standingOfCatalogKey('mining')).toBe('dormant')
  expect(isEffectiveStatId('mining_yield')).toBe(false)
  expect(statById('mining_yield')?.engineConsumer).toBeNull()
  expect(statById('mining_yield')?.presentationConsumer).toBeNull()
})

test('NO DORMANT STAT REACHES A PLAYER TOTAL — the team fold drops every one of them', () => {
  for (const statId of DORMANT_STAT_IDS) {
    expect(EFFECTIVE_STAT_KEYS as readonly string[], `${statId} is still a player total`).not.toContain(statId)
  }
})

// ── ACTIVE STATS STAY VISIBLE ───────────────────────────────────────────────────────────────────

test('the three ACTIVE stats remain effective and visible', () => {
  const active = STAT_DEFINITIONS.filter((d) => d.lifecycle === 'active').map((d) => d.statId)
  expect(active.sort()).toEqual(['combat_power', 'speed', 'survival'])
  for (const statId of active) {
    expect(isEffectiveStatId(statId), `${statId} lost its effective standing`).toBe(true)
    expect(isPlayerVisibleStatId(statId)).toBe(true)
    expect(PLAYER_VISIBLE_STAT_IDS).toContain(statId)
  }
  // …and the two the team fold carries are still in the player totals. `speed` is folded as the
  // fleet MINIMUM and rendered on its own row, so it is correctly not an additive total.
  expect(EFFECTIVE_STAT_KEYS as readonly string[]).toContain('combat_power')
  expect(EFFECTIVE_STAT_KEYS as readonly string[]).toContain('survival')
  expect(ADDITIVE_STAT_KEYS as readonly string[]).not.toContain('speed')
})

// ── DEPRECATED IS LEGACY, NEVER A NEW GAMEPLAY EFFECT ───────────────────────────────────────────

test('a DEPRECATED stat is labelled legacy and never offered as a new gameplay effect', () => {
  expect(LEGACY_STAT_IDS).toEqual(['cargo_capacity'])
  for (const statId of LEGACY_STAT_IDS) {
    expect(isLegacyStatId(statId)).toBe(true)
    // it is never presented as a working benefit…
    expect(isEffectiveStatId(statId), `${statId} is presented as an active effect`).toBe(false)
    // …it keeps its existing display reader (the ruling: legacy where shown, not deleted)…
    expect(isPlayerVisibleStatId(statId)).toBe(true)
    // …and the registry itself forbids it a gameplay consumer, forever (0340:239-241).
    expect(statById(statId)?.engineConsumer).toBeNull()
    expect(statById(statId)?.deprecatedReason).toContain('DEPRECATED legacy display integer')
  }
})

test('the team preview marks the legacy stat rather than printing it as a live number', () => {
  const panel = readFileSync(join(src, 'features', 'command', 'TeamPreviewSection.tsx'), 'utf8')
  expect(panel).toContain('isLegacyStatId')
  expect(panel).toContain('legacyHint')
  // and the mark is applied on BOTH stat lists the section renders (server totals + estimate)
  expect((panel.match(/hint=\{legacyHint\(k\)\}/g) ?? []).length).toBe(2)
})

// ── THE DERIVED SETS ARE DERIVED ────────────────────────────────────────────────────────────────

test('every derived set partitions the registry with no overlap and no leftovers', () => {
  const all = STAT_DEFINITIONS.map((d) => d.statId)
  const buckets = [...PLAYER_VISIBLE_STAT_IDS, ...DORMANT_STAT_IDS]
  expect(buckets.slice().sort()).toEqual(all.slice().sort())
  for (const statId of DORMANT_STAT_IDS) expect(PLAYER_VISIBLE_STAT_IDS).not.toContain(statId)
})

test('the legacy envelope set is registry-derived, not asserted', () => {
  // The 0122/0166 envelope carries the additive stats and neither the multiplier one (speed, folded
  // as a minimum) nor a superseding canonical target whose conversion is not activated
  // (cargo_volume_m3, whose permitted lists 0340 deliberately leaves empty).
  expect(LEGACY_ENVELOPE_STAT_IDS).not.toContain('speed')
  expect(LEGACY_ENVELOPE_STAT_IDS).not.toContain('cargo_volume_m3')
  expect(LEGACY_ENVELOPE_STAT_IDS).toEqual([
    'combat_power',
    'survival',
    'cargo_capacity',
    'repair',
    'scouting',
    'mining_yield',
    'retreat_safety',
    'pirate_attention',
  ])
  // …and the client's additive totals are exactly that, plus the two non-stat slot counters.
  expect(ADDITIVE_STAT_KEYS as readonly string[]).toEqual([
    ...LEGACY_ENVELOPE_STAT_IDS,
    'captain_slots_used',
    'captain_slots_limit',
  ])
})

test('EFFECTIVE_STAT_KEYS is exactly the non-dormant envelope plus the slot counters', () => {
  expect(EFFECTIVE_STAT_KEYS as readonly string[]).toEqual([
    'combat_power',
    'survival',
    'cargo_capacity',
    'captain_slots_used',
    'captain_slots_limit',
  ])
})

// ── NO SECOND ALLOWLIST, ANYWHERE UNDER src/ ────────────────────────────────────────────────────

function walk(dir: string): string[] {
  const out: string[] = []
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, entry.name)
    if (entry.isDirectory()) out.push(...walk(p))
    else if (/\.(ts|tsx)$/.test(entry.name)) out.push(p)
  }
  return out
}

/** Source with line comments and block comments stripped — the 0333:1975-1977 idiom. A file is
 *  allowed to DOCUMENT the rule (this whole change is prose about dormant stats); it is not allowed
 *  to EXECUTE a second copy of it. */
function codeOnly(text: string): string {
  return text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')
}

const SOURCES = walk(src).filter(
  (f) => !f.endsWith(join('features', 'stats', 'statRegistry.generated.ts')),
)

test('NO FILE UNDER src/ REBUILDS THE LIFECYCLE ANSWER — one authority, checked by scanning', () => {
  // The failure this closes is literal: the previous slice fixed a dormant-stat leak by ADDING
  // `DORMANT_STAT_KEYS = ['repair','scouting','mining_yield',…]` to teamSkillset.ts. Two files
  // deciding "is this stat in play?" is the duplicate authority migration 0340 exists to delete, so
  // it is now a red test rather than a review note.
  //
  // The rule: no source file may write an ARRAY LITERAL holding two or more registered stat
  // identifiers. One id in a literal is a legitimate join key (zoneEffects.ts maps a zone-effect
  // kind onto `mining_yield` and then ASKS the registry); a list of them is a vocabulary, and the
  // registry is the only place a vocabulary may live.
  const registered = new Set<string>([
    ...STAT_DEFINITIONS.map((d) => d.statId),
    ...STAT_DEFINITIONS.map((d) => d.catalogKey),
  ])
  const offenders: string[] = []
  for (const file of SOURCES) {
    const code = codeOnly(readFileSync(file, 'utf8'))
    for (const m of code.matchAll(/\[([^[\]{}();]*)\]/g)) {
      const ids = [...m[1].matchAll(/'([a-z0-9_]+)'/g)].map((x) => x[1]).filter((x) => registered.has(x))
      if (new Set(ids).size >= 2) {
        offenders.push(
          `${relative(repo, file).replace(/\\/g, '/')} → [${[...new Set(ids)].join(', ')}]`,
        )
      }
    }
  }

  // ── THE ONE PRE-EXISTING COPY, PINNED RATHER THAN EXCUSED ─────────────────────────────────────
  // shipTraits.ts's STAT_KEY_ORDER is the second unshared stat vocabulary in this repository. It is
  // NOT folded here, deliberately, and this is not a carve-out — it is a baseline the test holds
  // EXACTLY, so the list can neither grow, nor change, nor be copied into a third file without
  // going red.
  //
  // WHY IT IS LEFT: that list orders traitEffects(), the ONE formatter shared by ship traits,
  // command buffs (commandBuff.ts) and module detail (moduleInfoView.ts). Reading it through the
  // registry is trivial; the honest consequence is not. The live catalogs really do carry dormant
  // keys (production, 2026-08-04: steady_rigger {"mining":4,"repair":2}, keen_arrays {"scan":5},
  // ill_omened {"evasion":6}, and eight command buffs), so hiding dormant effects there would empty
  // a whole trait card, and marking them inactive is a UX decision on trait/captain surfaces — the
  // scope exclusion for this slice names "captain or trait changes" outright. It is the same bug
  // class as the one fixed here and it is reported, not smuggled.
  const KNOWN_DEBT = [
    'src/features/ship/shipTraits.ts → [attack, defense, repair, cargo, scan, mining, evasion, speed_mult_bonus]',
  ]
  expect(
    offenders.sort(),
    `a hardcoded stat vocabulary was re-introduced or the known one moved:\n${offenders.join('\n')}`,
  ).toEqual(KNOWN_DEBT)
})

test('statLifecycle.ts itself contains no list of stat identifiers', () => {
  // The authority must be a PROJECTION, not a transcription. If this file ever spells a stat name in
  // code, it has become the fifth copy instead of the last one.
  const code = codeOnly(readFileSync(join(src, 'features', 'stats', 'statLifecycle.ts'), 'utf8'))
  for (const d of STAT_DEFINITIONS) {
    expect(code, `statLifecycle.ts names the stat ${d.statId}`).not.toContain(`'${d.statId}'`)
    expect(code, `statLifecycle.ts names the catalog key ${d.catalogKey}`).not.toContain(`'${d.catalogKey}'`)
  }
  // it does, of course, name the three lifecycle VALUES — that is the mapping, and it is the point.
  expect(code).toContain("case 'active'")
  expect(code).toContain("case 'dormant'")
  expect(code).toContain("case 'deprecated'")
})

test('the retired duplicate is really gone from the client', () => {
  for (const file of SOURCES) {
    const code = codeOnly(readFileSync(file, 'utf8'))
    expect(code, `${relative(repo, file)} still exports DORMANT_STAT_KEYS`).not.toContain(
      'DORMANT_STAT_KEYS',
    )
    expect(code, `${relative(repo, file)} still carries the retired STAT_LABELS map`).not.toContain(
      'STAT_LABELS',
    )
  }
})

test('the dormant marker is a word, not a code', () => {
  // map-UX law: the owner's words, no schema keys, no jargon.
  expect(DORMANT_MARKER).toBe('Dormant')
})
