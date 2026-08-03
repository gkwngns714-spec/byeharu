// Phase 8 verification — calculate_expedition_stats().  node scripts/verify-phase8.mjs
//
// The deterministic stat adapter: reads main_ship_instances (+ hull, ship traits, command buffs,
// fitted modules, assigned captains) and returns normalized stats. It is read/compute only — these
// tests prove it never mutates the ship or inventory.
// 0317 — the SUPPORT-CRAFT path this file was originally written against is DELETED (it was
// unreachable: p_loadout is '[]' at every call site). Tests 3–15 exercised it and are retired with
// it; what replaces them is the one property that now holds — a non-empty loadout is REFUSED. The
// output no longer carries warnings / support_capacity_used / support_capacity_limit. Regression
// (verify-phase7 → … → m2/m3/m4) proves the engine is untouched, unless PHASE8_SKIP_REGRESS=1.

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
if (!serviceKey) { console.error('phase8 verify needs SUPABASE_SERVICE_ROLE_KEY (server-side).'); process.exit(2) }

const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
const anonKeyClient = () => createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })

let pass = 0, fail = 0
const ok = (n) => { console.log('  ✓', n); pass++ }
const bad = (n, d) => { console.log('  ✗', n, d ? `— ${d}` : ''); fail++ }
class Abort extends Error {}
const die = (m) => { throw new Abort(m) }

// 0317 — support_capacity_used / support_capacity_limit left the adapter's output together with the
// support-craft path that computed them (nothing in the database or the client ever read either).
const NUM_FIELDS = ['speed', 'cargo_capacity', 'combat_power', 'survival', 'retreat_safety',
  'scouting', 'mining_yield', 'repair', 'pirate_attention']

async function calc(player, shipId, loadout, activity = 'pirate_hunt') {
  return admin.rpc('calculate_expedition_stats', { p_player: player, p_main_ship_id: shipId, p_loadout: loadout, p_activity_type: activity })
}

async function main() {
  console.log(`\nPhase 8 (calculate_expedition_stats) verification against ${url}\n`)
  const c = anonKeyClient()
  const { data: su, error: suErr } = await c.auth.signUp({ email: `p8test.${Date.now()}@example.com`, password: 'Test123456!' })
  if (suErr) die(`signup failed: ${suErr.message}`)
  if (!su.session) die('no session — email confirmation still ON')
  const userId = su.user.id
  const ens = await admin.rpc('ensure_main_ship_for_player', { p_player: userId })
  if (ens.error) console.log('   · ensure rpc error:', JSON.stringify(ens.error))
  const hullDiag = await admin.from('main_ship_hull_types').select('hull_type_id')
  console.log('   · hull types present:', JSON.stringify(hullDiag.data), hullDiag.error ? `(err ${hullDiag.error.message})` : '')
  let ships = (await admin.from('main_ship_instances').select('*').eq('player_id', userId)).data ?? []
  const ship = ships[0]
  if (!ship) die(`no main ship created — ensure.data=${JSON.stringify(ens.data)} ensure.error=${JSON.stringify(ens.error)}`)
  ok(`set up player + main ship (support_capacity ${ship.support_capacity}, cargo ${ship.cargo_capacity})`)

  // 1/2. starter ship, empty loadout → base stats. Since migration 0170 the hull
  // carries base combat stats (starter_frigate {attack 15, defense 10}) folded by the adapter, so
  // a bare ship's combat_power/survival equal the HULL seed (read live, never hardcoded), not 0.
  const hull = (await admin.from('main_ship_hull_types').select('base_stats_json').eq('hull_type_id', ship.hull_type_id).single()).data
  const hullAtk = Number(hull?.base_stats_json?.attack ?? 0)
  const hullDef = Number(hull?.base_stats_json?.defense ?? 0)
  const base = (await calc(userId, ship.main_ship_id, [])).data
  base && base.combat_power === hullAtk && base.survival === hullDef && Number(base.speed) === 1 && base.cargo_capacity === ship.cargo_capacity
    ? ok(`1/2. empty loadout → base stats (speed 1, cargo ${base.cargo_capacity}, combat ${hullAtk}/survival ${hullDef} = the hull seed)`) : bad('1/2. base stats', JSON.stringify(base))

  // 16. no NaN, all numeric fields present & finite.
  NUM_FIELDS.every((f) => typeof base[f] === 'number' && Number.isFinite(base[f]))
    ? ok('16. every numeric field is a finite number (no NaN/null)') : bad('16. NaN check', JSON.stringify(base))

  // 0317 REPOINT — TESTS 3–15 ARE RETIRED WITH THE PATH THEY TESTED. They exercised the
  // support-craft loadout: capacity accounting, per-craft stat effects, the over-capacity cap and the
  // quantity validations. That whole path was unreachable in production — p_loadout is a literal
  // '[]' at every call site in the database and the one client caller hard-codes [] — and 0317
  // deleted it. The parameter survives (dropping it would re-create five live functions and change a
  // client-granted signature) and is now FAIL-CLOSED, so the property that replaces fifteen tests is
  // a single one: a non-empty loadout is REFUSED, never silently ignored.
  const refused = await calc(userId, ship.main_ship_id, [{ support_craft_type_id: 'scout_escort', quantity: 1 }])
  refused.error ? ok('3. a non-empty p_loadout is REFUSED (support craft retired, 0317 — fail-closed, never silently ignored)')
                : bad('3. retired loadout', `accepted: ${JSON.stringify(refused.data)}`)
  const stillGone = (await calc(userId, ship.main_ship_id, [])).data
  stillGone && !('warnings' in stillGone) && !('support_capacity_used' in stillGone) && !('support_capacity_limit' in stillGone)
    ? ok('4. the retired output fields (warnings / support_capacity_used / support_capacity_limit) are gone')
    : bad('4. retired fields', JSON.stringify(stillGone))

  // 17. deterministic — same input twice → identical output.
  const a = (await calc(userId, ship.main_ship_id, [])).data
  const b = (await calc(userId, ship.main_ship_id, [])).data
  JSON.stringify(a) === JSON.stringify(b) ? ok('17. deterministic output for identical input') : bad('17. determinism', `${JSON.stringify(a)} vs ${JSON.stringify(b)}`)

  // 18/19. read/compute only — ship + inventory unchanged after many calls.
  const shipAfter = (await admin.from('main_ship_instances').select('*').eq('player_id', userId).maybeSingle()).data
  shipAfter.support_capacity === ship.support_capacity && shipAfter.cargo_capacity === ship.cargo_capacity && shipAfter.updated_at === ship.updated_at
    ? ok('18. main_ship_instances NOT mutated by calculate_expedition_stats') : bad('18. ship mutated', JSON.stringify(shipAfter))
  const invRows = (await admin.from('player_inventory').select('item_id').eq('player_id', userId)).data ?? []
  invRows.length === 0 ? ok('19. inventory NOT touched (still empty)') : bad('19. inventory mutated', JSON.stringify(invRows))

  // security: client cannot call the server-only function; cannot calc for another ship.
  ;(await c.rpc('calculate_expedition_stats', { p_player: userId, p_main_ship_id: ship.main_ship_id, p_loadout: [], p_activity_type: 'pirate_hunt' })).error
    ? ok('   calculate_expedition_stats denied to client (server-only)') : bad('   anti-cheat', 'client EXECUTED')

  // 20. regression — fleet/combat/production engine unchanged.
  console.log('\n20. Regression (Phase7 → Phase6 → Phase5 → Phase4 → Inventory → M4.5 → M5 → M2/M3/M4):')
  if (env.PHASE8_SKIP_REGRESS === '1') console.log('  · skipped (PHASE8_SKIP_REGRESS=1)')
  else { try { execSync('node scripts/verify-phase7.mjs', { stdio: 'inherit' }); ok('verify:phase7 (full chain) passed — engine unchanged') } catch { bad('regression', 'verify:phase7 non-zero exit') } }
}

main()
  .catch((e) => { if (e instanceof Abort) bad('ABORTED', e.message); else bad('UNEXPECTED', e?.message ?? String(e)) })
  .finally(() => {
    console.log(`\nPhase 8: ${pass} passed, ${fail} failed`)
    console.log("ℹ Verify created throwaway test data. Run `npm run verify:cleanup` to remove leftover runtime rows (CI does this automatically).\n")
    process.exitCode = fail > 0 ? 1 : 0
  })
