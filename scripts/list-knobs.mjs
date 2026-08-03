// LIST EVERY GAME KNOB — value, meaning, and whether anything actually reads it.
//
//   node scripts/list-knobs.mjs                # everything, grouped by domain
//   node scripts/list-knobs.mjs combat         # only keys matching 'combat'
//   node scripts/list-knobs.mjs mining --tiers # ...and ask production which functions read each
//
// The companion to scripts/set-knob.mjs: this is how you find the key before you set it, and how
// you find out that the key you were about to set is read by nothing.
//
// --tiers costs one Management-API query (read-only) and is off by default because the census over
// all ~150 keys is the slow part; the value/description listing is a single PostgREST read.
//
// READ-ONLY. This tool has no write path at all.

import { basename } from 'node:path'
import {
  resolveKnobEnv,
  readAllKnobs,
  readersByKey,
  clientRefsByKey,
  tierOf,
  domainOf,
  jsonTypeOf,
} from './lib/knobs.mjs'

const USAGE = `usage: node scripts/list-knobs.mjs [filter] [--tiers] [--dead]

  filter    substring matched against the key AND the description (case-insensitive)
  --tiers   also report, per key, which production functions read it and whether a change is
            LIVE or FROZEN until the next fight/wave (one read-only Management API query)
  --dead    with --tiers: show ONLY keys that no production function and no file under src/ reads

  Set one with:  node scripts/set-knob.mjs <key> <value>`

function firstLine(s, width) {
  if (!s) return ''
  const one = s.replace(/\s+/g, ' ').trim()
  return one.length <= width ? one : one.slice(0, width - 1) + '…'
}

async function main() {
  const argv = process.argv.slice(2)
  if (argv.includes('--help') || argv.includes('-h')) {
    console.log(USAGE)
    return
  }
  const withTiers = argv.includes('--tiers')
  const deadOnly = argv.includes('--dead')
  const filter = (argv.find((a) => !a.startsWith('--')) ?? '').toLowerCase()

  const ctx = resolveKnobEnv()
  const repoRoot = process.cwd()

  const all = await readAllKnobs(ctx)
  const rows = filter
    ? all.filter(
        (r) => r.key.toLowerCase().includes(filter) || (r.description ?? '').toLowerCase().includes(filter),
      )
    : all

  if (rows.length === 0) {
    console.log(`No key matches '${filter}'. ${all.length} keys exist; run without a filter to see them.`)
    return
  }

  let readers = null
  let clientRefs = new Map()
  if (withTiers || deadOnly) {
    const keys = rows.map((r) => r.key)
    readers = await readersByKey(ctx, keys).catch((e) => {
      console.log(`(reader census unavailable: ${e.message})\n`)
      return null
    })
    clientRefs = clientRefsByKey(repoRoot, keys)
  }

  const byDomain = new Map()
  for (const r of rows) {
    const d = domainOf(r.key)
    if (!byDomain.has(d)) byDomain.set(d, [])
    byDomain.get(d).push(r)
  }

  const keyW = Math.min(48, Math.max(...rows.map((r) => r.key.length)))
  let shown = 0

  for (const domain of [...byDomain.keys()].sort()) {
    const group = byDomain.get(domain)
    const lines = []
    for (const r of group) {
      let tier = null
      if (readers !== null || withTiers || deadOnly) {
        tier = tierOf(r.key, readers ? (readers.get(r.key) ?? []) : null, clientRefs.get(r.key) ?? [])
        if (deadOnly && tier.tier !== 'DEAD') continue
      }
      shown += 1
      const val = JSON.stringify(r.value)
      lines.push(`  ${r.key.padEnd(keyW)}  ${val.padEnd(10)} ${firstLine(r.description, 92) || '(no description)'}`)
      if (tier && (withTiers || deadOnly)) {
        lines.push(`  ${' '.repeat(keyW)}  ${tier.tier} — ${tier.note}`)
      }
    }
    if (lines.length === 0) continue
    console.log(`\n── ${domain.toUpperCase()} ${'─'.repeat(Math.max(0, 76 - domain.length))}`)
    console.log(lines.join('\n'))
  }

  console.log(
    `\n${shown} key(s)${filter ? ` matching '${filter}'` : ''} of ${all.length} in game_config` +
      `${deadOnly ? ' — DEAD only' : ''}.`,
  )
  const noDesc = rows.filter((r) => !r.description).length
  if (noDesc > 0 && !deadOnly) {
    console.log(
      `${noDesc} of them carry NO description — a row with no description was written by a bare ` +
        'set_game_config UPSERT rather than by a migration, so a fresh database will not have it.',
    )
  }
  const types = new Set(rows.map((r) => jsonTypeOf(r.value)))
  console.log(`value types present: ${[...types].sort().join(', ')}`)
}

main().catch((e) => {
  console.error(`ERROR (${basename(process.argv[1])}): ${e.message}`)
  process.exitCode = 1
})
