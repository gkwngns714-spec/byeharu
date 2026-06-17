// Phase 6 verification — Support Craft Reframe (metadata foundation).  node scripts/verify-phase6.mjs
//
// Pure metadata: support_craft_types is seeded, public-read, client-write-blocked, and a
// SEPARATE namespace from combat unit_types (so nothing in the engine changed). The
// regression chain (verify-phase5 → phase4 → inventory → m45 → m5 → m2/m3/m4) proves
// combat + the serial build queue still behave exactly as before, unless PHASE6_SKIP_REGRESS=1.

import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'
import { execSync } from 'node:child_process'

function loadEnv(p) {
  const e = {}
  try {
    for (const l of readFileSync(p, 'utf8').split('\n')) {
      const m = l.match(/^\s*([\w.]+)\s*=\s*(.*)\s*$/)
      if (m) e[m[1]] = m[2].trim().replace(/^['"]|['"]$/g, '')
    }
  } catch {}
  return e
}
const env = { ...loadEnv('.env.local'), ...process.env }
const url = env.VITE_SUPABASE_URL
const anonKey = env.VITE_SUPABASE_ANON_KEY
const serviceKey = env.SUPABASE_SERVICE_ROLE_KEY || env.SUPABASE_SERVICE_KEY || env.SUPABASE_SECRET_KEY
if (!url || !anonKey) { console.error('Missing VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY'); process.exit(2) }

const anon = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
const admin = serviceKey ? createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } }) : anon

let pass = 0, fail = 0
const ok = (n) => { console.log('  ✓', n); pass++ }
const bad = (n, d) => { console.log('  ✗', n, d ? `— ${d}` : ''); fail++ }
class Abort extends Error {}
const die = (m) => { throw new Abort(m) }

const EXPECTED = {
  scout_escort: 1, missile_boat: 3, repair_drone: 2, cargo_drone: 2,
  survey_drone: 2, decoy_drone: 1, mining_drone: 2, trade_barge: 5,
}

async function main() {
  console.log(`\nPhase 6 (Support Craft Reframe) verification against ${url}\n`)

  // 1. definitions exist (public read).
  const { data: rows, error } = await anon.from('support_craft_types').select('*')
  if (error) die(`support_craft_types not readable: ${error.message}`)
  const byId = Object.fromEntries((rows ?? []).map((r) => [r.support_craft_type_id, r]))
  const missing = Object.keys(EXPECTED).filter((id) => !byId[id])
  missing.length === 0 ? ok(`1. all 8 support craft definitions exist & are publicly readable (${Object.keys(byId).length} rows)`) : bad('1. definitions', `missing ${missing}`)

  // 2. capacity_cost > 0 (and matches the documented loadout cost).
  const capBad = Object.entries(EXPECTED).filter(([id, c]) => !byId[id] || byId[id].capacity_cost !== c)
  capBad.length === 0 ? ok('2. every craft has capacity_cost > 0 matching the documented cost (1–5)') : bad('2. capacity_cost', JSON.stringify(capBad))
  Object.values(byId).every((r) => Number.isInteger(r.capacity_cost) && r.capacity_cost > 0)
    ? ok('2. all capacity_cost are positive integers (DB check holds)') : bad('2. capacity positivity', 'non-positive found')

  // 3. each has a non-empty role.
  Object.values(byId).every((r) => typeof r.role === 'string' && r.role.length > 0)
    ? ok(`3. every craft has a role (${Object.values(byId).map((r) => r.role).join(', ')})`) : bad('3. role', 'missing role')

  // 4. each has activity tags + tradeoff/stat metadata.
  const metaBad = Object.values(byId).filter((r) => !Array.isArray(r.activity_tags) || r.activity_tags.length === 0)
  metaBad.length === 0 ? ok('4. every craft has non-empty activity_tags') : bad('4. activity_tags', JSON.stringify(metaBad.map((r) => r.support_craft_type_id)))
  Object.values(byId).every((r) => r.tradeoffs_json && typeof r.tradeoffs_json === 'object')
    ? ok('4. every craft carries tradeoffs_json metadata (loadout choice, not pure power)') : bad('4. tradeoffs', 'missing')

  // 5. no combat behavior changed — support_craft_types is a SEPARATE namespace from
  //    combat unit_types (scout/corvette/frigate still the combat units).
  const { data: units } = await anon.from('unit_types').select('id')
  const unitIds = new Set((units ?? []).map((u) => u.id))
  const overlap = Object.keys(byId).filter((id) => unitIds.has(id))
  ;['scout', 'corvette', 'frigate'].every((u) => unitIds.has(u)) && overlap.length === 0
    ? ok('5. combat unit_types intact (scout/corvette/frigate); zero overlap with support craft — engine untouched') : bad('5. namespace', `overlap ${overlap}`)

  // 8. clients cannot write support metadata (RLS: read-only, no write policy/grant).
  if (!serviceKey) console.log('  · (skipping authed client-write check — no service key to make a user)')
  const c = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: su } = await c.auth.signUp({ email: `p6test.${Date.now()}@example.com`, password: 'Test123456!' })
  if (su?.session) {
    const ins = await c.from('support_craft_types').insert({ support_craft_type_id: `hack_${Date.now()}`, name: 'X', role: 'x', capacity_cost: 1 })
    const upd = await c.from('support_craft_types').update({ capacity_cost: 999 }).eq('support_craft_type_id', 'trade_barge')
    ins.error ? ok('8. client INSERT into support_craft_types blocked') : bad('8. client insert', 'EXECUTED — hole!')
    // verify the update did not actually change the row (RLS write-blocked)
    const stillFive = (await anon.from('support_craft_types').select('capacity_cost').eq('support_craft_type_id', 'trade_barge').maybeSingle()).data?.capacity_cost === 5
    upd.error || stillFive ? ok('8. client UPDATE of support_craft_types blocked (trade_barge capacity still 5)') : bad('8. client update', 'mutated!')
  } else { console.log('  · (no session — email confirmation ON; skipped client-write assertions)') }

  // 6/7. regression — proves build queue + combat unchanged end-to-end.
  console.log('\n6/7. Regression (Phase5 → Phase4 → Inventory → M4.5 → M5 → M2/M3/M4):')
  if (env.PHASE6_SKIP_REGRESS === '1') console.log('  · skipped (PHASE6_SKIP_REGRESS=1)')
  else { try { execSync('node scripts/verify-phase5.mjs', { stdio: 'inherit' }); ok('verify:phase5 (chains phase4/inventory/m45/m5/m2/m3/m4) passed — combat + serial build queue unchanged') } catch { bad('regression', 'verify:phase5 non-zero exit') } }
}

main()
  .catch((e) => { if (e instanceof Abort) bad('ABORTED', e.message); else bad('UNEXPECTED', e?.message ?? String(e)) })
  .finally(() => { console.log(`\nPhase 6: ${pass} passed, ${fail} failed\n`); process.exitCode = fail > 0 ? 1 : 0 })
