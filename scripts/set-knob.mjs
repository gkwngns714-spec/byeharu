// SET ONE GAME KNOB. The generic tool the game never had.
//
//   node scripts/set-knob.mjs <key> <value> [--dry-run] [--create] [--force] [--why "<reason>"]
//
//   node scripts/set-knob.mjs mining_extract_radius 90
//   node scripts/set-knob.mjs mining_extract_radius 90 --dry-run     # read + report, write nothing
//   node scripts/set-knob.mjs combat_hit_variance_pct 0.25
//   node scripts/set-knob.mjs timed_docking_enabled true
//
// WHAT IT DOES, in order:
//   1. READS the row first and prints its current value, description, and when it last changed;
//   2. prints the LIVE/FROZEN tier, so you know whether the change bites now or at the next fight;
//   3. REFUSES the write if the key does not exist (unless --create) or if the new value's JSON
//      type differs from the stored one (unless --force);
//   4. writes through public.set_game_config — the owned writer, never a raw table write;
//   5. RE-READS and prints the confirmed stored value, and exits non-zero if it does not match.
//
// WHY 3 IS NOT PARANOIA. set_game_config is a bare UPSERT with no description column and no key
// whitelist, so a typo does not fail — it MINTS a new row nothing reads. Production still carries
// one such orphan (`combat_hit_variance_pct`, description NULL, seeded by no migration).
//
// THIS IS A DEV TOOL, NOT GAME CODE. It needs the service-role key, so it can only run where
// .env.local lives. Production is a live multiplayer game: a knob write here is visible to every
// player immediately (LIVE) or at their next fight (FROZEN).

import { basename } from 'node:path'
import {
  resolveKnobEnv,
  readKnob,
  writeKnob,
  parseKnobValue,
  jsonTypeOf,
  readersByKey,
  clientRefsByKey,
  tierOf,
  domainOf,
} from './lib/knobs.mjs'

const USAGE = `usage: node scripts/set-knob.mjs <key> <value> [--dry-run] [--create] [--force] [--why "<reason>"]

  <value>     JSON: 60, 0.5, true, false, null, '"some text"'
  --dry-run   read, report and validate — write nothing
  --create    allow minting a key that does not exist yet (set_game_config is an UPSERT, so
              without this a typo would silently create a row no reader looks up)
  --force     allow changing the value's JSON type (number -> boolean, etc.)
  --why       a note echoed into the output; use it when the change is not self-explanatory

  See every key with:  node scripts/list-knobs.mjs [filter]`

async function main() {
  const argv = process.argv.slice(2)
  const flags = new Set(argv.filter((a) => a.startsWith('--')))
  const whyIdx = argv.indexOf('--why')
  const why = whyIdx >= 0 ? argv[whyIdx + 1] : null
  // `--why`'s argument is the only positional that is NOT a knob operand. Guard on whyIdx >= 0:
  // with no --why, whyIdx is -1 and `whyIdx + 1` would swallow argv[0], i.e. the key itself.
  const whyArgIdx = whyIdx >= 0 ? whyIdx + 1 : -1
  const positional = argv.filter((a, i) => !a.startsWith('--') && i !== whyArgIdx)

  if (positional.length !== 2) {
    console.error(USAGE)
    process.exit(2)
  }
  const [key, rawValue] = positional

  const parsed = parseKnobValue(rawValue)
  if (parsed.error) {
    console.error(`Refusing to run: ${parsed.error}`)
    process.exit(2)
  }
  const next = parsed.value

  const ctx = resolveKnobEnv()
  const repoRoot = process.cwd()

  // ── 1. read first ─────────────────────────────────────────────────────────────────────────────
  const before = await readKnob(ctx, key)

  console.log(`KEY       ${key}   (domain: ${domainOf(key)})`)
  if (before) {
    console.log(`CURRENT   ${JSON.stringify(before.value)}   (${jsonTypeOf(before.value)})`)
    console.log(`CHANGED   ${before.updated_at ?? '(never)'}`)
    console.log(`MEANING   ${before.description ?? '(no description — this row was written by a bare UPSERT, not a migration)'}`)
  } else {
    console.log('CURRENT   (key does not exist)')
  }

  // ── 2. the tier ───────────────────────────────────────────────────────────────────────────────
  const readers = await readersByKey(ctx, [key]).catch((e) => {
    console.log(`READERS   (could not inspect: ${e.message})`)
    return null
  })
  const clientRefs = clientRefsByKey(repoRoot, [key]).get(key) ?? []
  const { tier, note } = tierOf(key, readers ? (readers.get(key) ?? []) : null, clientRefs)
  console.log(`TIER      ${tier}`)
  console.log(`          ${note}`)
  if (clientRefs.length && tier !== 'LIVE (client only)') {
    console.log(`          also read by the client at: ${clientRefs.join(', ')}`)
  }
  console.log('')

  // ── 3. refuse before writing ──────────────────────────────────────────────────────────────────
  if (!before && !flags.has('--create')) {
    console.error(
      `REFUSED: '${key}' does not exist. set_game_config is an UPSERT, so writing it would MINT a new\n` +
        '         row that no reader looks up — which is how production ended up with an unversioned\n' +
        `         key already. If the key is genuinely new, pass --create (and seed it in a migration\n` +
        '         with a description, or the next fresh database will not have it).\n' +
        '         Check the spelling with: node scripts/list-knobs.mjs ' +
        key.split('_')[0],
    )
    process.exit(1)
  }
  if (before && jsonTypeOf(before.value) !== jsonTypeOf(next) && !flags.has('--force')) {
    console.error(
      `REFUSED: type change ${jsonTypeOf(before.value)} -> ${jsonTypeOf(next)}. Every reader of this key\n` +
        `         expects ${jsonTypeOf(before.value)} (cfg_num casts to double precision, cfg_bool to boolean —\n` +
        '         a wrong type either raises inside a game function or reads as false forever).\n' +
        '         Pass --force if the type change is genuinely what you mean.',
    )
    process.exit(1)
  }

  const unchanged = before && JSON.stringify(before.value) === JSON.stringify(next)
  if (why) console.log(`WHY       ${why}`)
  console.log(`WRITE     ${before ? JSON.stringify(before.value) : '(absent)'} -> ${JSON.stringify(next)}${unchanged ? '   (no change)' : ''}`)

  if (flags.has('--dry-run')) {
    console.log('\nDRY RUN — nothing was written. Re-run without --dry-run to apply.')
    return
  }

  // ── 4. write through the owned writer ─────────────────────────────────────────────────────────
  await writeKnob(ctx, key, next)

  // ── 5. re-read and confirm ────────────────────────────────────────────────────────────────────
  const after = await readKnob(ctx, key)
  const stored = after?.value
  const ok = JSON.stringify(stored) === JSON.stringify(next)
  console.log(`CONFIRMED ${JSON.stringify(stored)}   (re-read from the database, not assumed)`)
  if (!ok) {
    console.error(`\n❌ STORED VALUE DOES NOT MATCH. Wanted ${JSON.stringify(next)}, database holds ${JSON.stringify(stored)}.`)
    process.exitCode = 1
    return
  }
  console.log(`\n✅ ${key} = ${JSON.stringify(stored)}.`)
  if (tier.startsWith('FROZEN')) console.log(`   Remember: ${note}`)
  if (tier === 'DEAD') console.log('   Warning: nothing reads this key, so the game will not change.')
}

main().catch((e) => {
  console.error(`ERROR (${basename(process.argv[1])}): ${e.message}`)
  process.exitCode = 1
})
