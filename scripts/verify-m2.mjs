// M2 live verification — run against a real Supabase project using ONLY the public
// anon key (no secrets). Checks: world-map data counts, get_world_map() nested
// shape, RLS read access, and RLS write-denial (insert/update/delete).
//
//   node scripts/verify-m2.mjs      (reads .env.local for VITE_SUPABASE_URL / _ANON_KEY)
//
// Exit code 0 = all checks passed, 1 = a check failed or config missing.

import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'

function loadEnv(path) {
  const env = {}
  try {
    for (const line of readFileSync(path, 'utf8').split('\n')) {
      const m = line.match(/^\s*([\w.]+)\s*=\s*(.*)\s*$/)
      if (m) env[m[1]] = m[2].trim().replace(/^['"]|['"]$/g, '')
    }
  } catch {
    /* no .env.local */
  }
  return env
}

const env = { ...loadEnv('.env.local'), ...process.env }
const url = env.VITE_SUPABASE_URL
const anon = env.VITE_SUPABASE_ANON_KEY

if (!url || !anon) {
  console.error('✖ Missing VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY (set .env.local first).')
  process.exit(1)
}

const supabase = createClient(url, anon)
let pass = 0
let fail = 0
const ok = (name) => {
  console.log('  ✓', name)
  pass++
}
const bad = (name, detail) => {
  console.log('  ✗', name, detail ? `— ${detail}` : '')
  fail++
}

console.log(`\nVerifying M2 against ${url}\n`)

// 1) get_world_map() shape + seed counts
console.log('get_world_map() shape & seed counts:')
const { data: world, error: wErr } = await supabase.rpc('get_world_map')
if (wErr) {
  bad('get_world_map() call', wErr.message)
} else {
  const sectors = world?.sectors ?? []
  const zones = sectors.flatMap((s) => s.zones ?? [])
  const locs = zones.flatMap((z) => z.locations ?? [])
  sectors.length === 2 ? ok('2 sectors') : bad('2 sectors', `got ${sectors.length}`)
  zones.length === 2 ? ok('2 zones') : bad('2 zones', `got ${zones.length}`)
  const nested =
    sectors.length > 0 &&
    sectors.every((s) => Array.isArray(s.zones)) &&
    zones.every((z) => Array.isArray(z.locations))
  nested ? ok('nested sectors → zones → locations') : bad('nested shape', 'missing nesting')

  // World pin (reconciled 2026-07-05 — see DEV_LOG). The seed is 8 locations, not the obsolete 5:
  // the 5 waypoints (0002) are ALWAYS active, while the 3 starter ports (0066) are seeded HIDDEN and
  // enter get_world_map() (active-only) ONLY after the human-gated one-way reveal_starter_ports()
  // (0068) — run in production, so the live expectation is all 8. Exact names AND types are pinned
  // (never a loose count); the ports are all-or-nothing so the pin is also correct against a fresh
  // pre-reveal seed, and a PARTIAL port set always fails.
  //
  // TRANSITIONAL (retire once forward-only 0148 is applied to every verified env): each location is
  // matched under EXACTLY one of its two known names — the 0002/0066 seed name OR the 0148 one-word
  // rename — because 0148 is human-applied and may lag this checkout (live today: post-reveal,
  // pre-0148). Collapse each pair to the new name only after the human applies 0148.
  const WAYPOINTS = [
    { names: ['Refuge', 'Safe Rally Point'], type: 'safe_zone' },
    { names: ['Snare', 'Pirate Ambush Point'], type: 'pirate_hunt' },
    { names: ['Reaver', 'Raider Outpost'], type: 'pirate_hunt' },
    { names: ['Lull', 'Quiet Drift'], type: 'safe_zone' },
    { names: ['Blackden', 'Pirate Den'], type: 'pirate_hunt' },
  ]
  const PORTS = [
    { names: ['Haven', 'Haven Reach'], type: 'trade_outpost' },
    { names: ['Slagworks', 'Slagworks Anchorage'], type: 'trade_outpost' },
    { names: ['Driftmarch', 'Driftmarch Waypost'], type: 'trade_outpost' },
  ]
  const byName = new Map(locs.map((l) => [l.name, l.location_type]))
  const matchedOnce = (e) => e.names.filter((n) => byName.get(n) === e.type).length === 1
  const era = byName.has('Refuge') || byName.has('Haven') ? 'post-0148 one-word names' : 'pre-0148 seed names'
  const wpMisses = WAYPOINTS.filter((e) => !matchedOnce(e))
  wpMisses.length === 0
    ? ok(`the 5 seeded waypoints, exact names+types (${era}; Refuge/Lull safe_zone, Snare/Reaver/Blackden pirate_hunt)`)
    : bad('5 waypoints', `missing/mismatched: ${wpMisses.map((e) => e.names[0]).join(', ')}`)
  const portsPresent = PORTS.filter(matchedOnce).length
  portsPresent === 3
    ? ok(`the 3 starter ports revealed, exact names+type (${era}; Haven/Slagworks/Driftmarch trade_outpost)`)
    : portsPresent === 0
      ? ok('starter ports hidden (pre-reveal seed state — reveal_starter_ports not run in this env)')
      : bad('starter ports', `PARTIAL reveal: ${portsPresent}/3 matched`)
  const expected = 5 + (portsPresent === 3 ? 3 : 0)
  locs.length === expected
    ? ok(`${expected} locations total (5 waypoints + ${expected - 5} revealed ports; no strays)`)
    : bad('location count', `got ${locs.length}, expected ${expected}`)
  const hunt = locs.filter((l) => l.location_type === 'pirate_hunt').length
  const safe = locs.filter((l) => l.location_type === 'safe_zone').length
  const trade = locs.filter((l) => l.location_type === 'trade_outpost').length
  hunt === 3 && safe === 2 && trade === expected - 5
    ? ok(`location types (3 pirate_hunt + 2 safe_zone + ${expected - 5} trade_outpost)`)
    : bad('location types', `pirate_hunt=${hunt}, safe_zone=${safe}, trade_outpost=${trade}`)
}

// 2) RLS read access (anon)
console.log('\nRLS read access (anon):')
for (const tbl of ['sectors', 'zones', 'locations']) {
  const { data, error } = await supabase.from(tbl).select('id').limit(5)
  error ? bad(`read ${tbl}`, error.message) : ok(`anon can read ${tbl} (${data.length} rows sampled)`)
}

// 3) RLS write-denial (anon must NOT be able to mutate map tables)
console.log('\nRLS write-denial (anon):')
// insert → expect an error (no insert policy)
const { error: insErr } = await supabase
  .from('sectors')
  .insert({ name: '__HACK__', sector_index: 99999, x: 0, y: 0 })
insErr
  ? ok(`insert blocked (${insErr.code ?? 'error'})`)
  : bad('insert blocked', 'INSERT SUCCEEDED — RLS hole!')

// update → expect 0 rows affected (no update policy → USING filters all rows out)
const { data: updData, error: updErr } = await supabase
  .from('sectors')
  .update({ name: '__HACK__' })
  .eq('sector_index', 1)
  .select()
if (updErr) ok(`update blocked (${updErr.code ?? 'error'})`)
else if ((updData?.length ?? 0) === 0) ok('update affected 0 rows')
else bad('update blocked', `UPDATED ${updData.length} row(s) — RLS hole!`)

// delete → expect 0 rows affected
const { data: delData, error: delErr } = await supabase
  .from('sectors')
  .delete()
  .eq('sector_index', 1)
  .select()
if (delErr) ok(`delete blocked (${delErr.code ?? 'error'})`)
else if ((delData?.length ?? 0) === 0) ok('delete affected 0 rows')
else bad('delete blocked', `DELETED ${delData.length} row(s) — RLS hole!`)

console.log(`\n${fail === 0 ? '✅ ALL PASSED' : '❌ FAILURES'}: ${pass} passed, ${fail} failed\n`)
process.exit(fail === 0 ? 0 : 1)
