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
  locs.length === 5 ? ok('5 locations') : bad('5 locations', `got ${locs.length}`)
  const nested =
    sectors.length > 0 &&
    sectors.every((s) => Array.isArray(s.zones)) &&
    zones.every((z) => Array.isArray(z.locations))
  nested ? ok('nested sectors → zones → locations') : bad('nested shape', 'missing nesting')
  const hunt = locs.filter((l) => l.location_type === 'pirate_hunt').length
  const safe = locs.filter((l) => l.location_type === 'safe_zone').length
  hunt === 3 && safe === 2
    ? ok('location types (3 pirate_hunt + 2 safe_zone)')
    : bad('location types', `pirate_hunt=${hunt}, safe_zone=${safe}`)
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
