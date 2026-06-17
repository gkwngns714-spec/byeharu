// Phase 8 verification — calculate_expedition_stats().  node scripts/verify-phase8.mjs
//
// The deterministic stat adapter: reads main_ship_instances (+ hull) + support_craft_types,
// validates a support loadout, enforces support_capacity, returns normalized stats. It is
// read/compute only — these tests prove it never mutates the ship or inventory. Regression
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

const NUM_FIELDS = ['speed', 'cargo_capacity', 'combat_power', 'survival', 'retreat_safety',
  'scouting', 'mining_yield', 'repair', 'pirate_attention', 'support_capacity_used', 'support_capacity_limit']

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

  // 1/2. starter ship, empty loadout → base stats, 0/10 capacity.
  const base = (await calc(userId, ship.main_ship_id, [])).data
  base && base.support_capacity_used === 0 && base.support_capacity_limit === 10 &&
    base.combat_power === 0 && Number(base.speed) === 1 && base.cargo_capacity === ship.cargo_capacity
    ? ok(`1/2. empty loadout → base stats (speed 1, cargo ${base.cargo_capacity}, combat 0, used 0/10)`) : bad('1/2. base stats', JSON.stringify(base))

  // 16. no NaN, all numeric fields present & finite.
  NUM_FIELDS.every((f) => typeof base[f] === 'number' && Number.isFinite(base[f]))
    ? ok('16. every numeric field is a finite number (no NaN/null)') : bad('16. NaN check', JSON.stringify(base))

  // 3. valid mixed loadout → expected capacity used (2×1 + 1×3 + 1×2 = 7).
  const mixed = (await calc(userId, ship.main_ship_id, [
    { support_craft_type_id: 'scout_escort', quantity: 2 },
    { support_craft_type_id: 'missile_boat', quantity: 1 },
    { support_craft_type_id: 'repair_drone', quantity: 1 },
  ])).data
  mixed && mixed.support_capacity_used === 7 ? ok('3. valid mixed loadout → support_capacity_used 7/10') : bad('3. capacity used', JSON.stringify(mixed))

  // 4. over-capacity rejected (trade_barge ×3 = 15 > 10).
  ;(await calc(userId, ship.main_ship_id, [{ support_craft_type_id: 'trade_barge', quantity: 3 }])).error
    ? ok('4. over-capacity loadout rejected (15 > 10)') : bad('4. over-capacity', 'accepted')

  // 5/6/7/8. unknown type, zero, negative, non-integer all rejected.
  ;(await calc(userId, ship.main_ship_id, [{ support_craft_type_id: 'does_not_exist', quantity: 1 }])).error ? ok('5. unknown support craft type rejected') : bad('5. unknown', 'accepted')
  ;(await calc(userId, ship.main_ship_id, [{ support_craft_type_id: 'scout_escort', quantity: 0 }])).error ? ok('6. zero quantity rejected') : bad('6. zero', 'accepted')
  ;(await calc(userId, ship.main_ship_id, [{ support_craft_type_id: 'scout_escort', quantity: -2 }])).error ? ok('7. negative quantity rejected') : bad('7. negative', 'accepted')
  ;(await calc(userId, ship.main_ship_id, [{ support_craft_type_id: 'scout_escort', quantity: 1.5 }])).error ? ok('8. non-integer quantity rejected') : bad('8. non-integer', 'accepted')

  // 9. duplicate entries combined deterministically (scout_escort 1 + 1 → used 2).
  const dup = (await calc(userId, ship.main_ship_id, [
    { support_craft_type_id: 'scout_escort', quantity: 1 },
    { support_craft_type_id: 'scout_escort', quantity: 1 },
  ])).data
  dup && dup.support_capacity_used === 2 ? ok('9. duplicate entries combined (scout_escort 1+1 → used 2)') : bad('9. dedup', JSON.stringify(dup))

  // 10. missile_boat: combat_power up AND (pirate_attention up OR speed penalty).
  const mb = (await calc(userId, ship.main_ship_id, [{ support_craft_type_id: 'missile_boat', quantity: 1 }])).data
  mb.combat_power > base.combat_power && (mb.pirate_attention > base.pirate_attention || Number(mb.speed) < Number(base.speed))
    ? ok(`10. missile_boat → combat_power ${mb.combat_power}, pirate_attention ${mb.pirate_attention}, speed ${mb.speed}`) : bad('10. missile_boat', JSON.stringify(mb))

  // 11. cargo_drone: cargo_capacity up AND pirate_attention up.
  const cd = (await calc(userId, ship.main_ship_id, [{ support_craft_type_id: 'cargo_drone', quantity: 1 }], 'trade_run')).data
  cd.cargo_capacity > base.cargo_capacity && cd.pirate_attention > base.pirate_attention
    ? ok(`11. cargo_drone → cargo_capacity ${cd.cargo_capacity}, pirate_attention ${cd.pirate_attention}`) : bad('11. cargo_drone', JSON.stringify(cd))

  // 12/13/14/15. survey/mining/decoy/repair effects.
  const sv = (await calc(userId, ship.main_ship_id, [{ support_craft_type_id: 'survey_drone', quantity: 1 }], 'exploration')).data
  sv.scouting > base.scouting ? ok(`12. survey_drone → scouting ${sv.scouting}`) : bad('12. survey', JSON.stringify(sv))
  const md = (await calc(userId, ship.main_ship_id, [{ support_craft_type_id: 'mining_drone', quantity: 1 }], 'mining')).data
  md.mining_yield > base.mining_yield ? ok(`13. mining_drone → mining_yield ${md.mining_yield}`) : bad('13. mining', JSON.stringify(md))
  const dd = (await calc(userId, ship.main_ship_id, [{ support_craft_type_id: 'decoy_drone', quantity: 1 }])).data
  dd.retreat_safety > base.retreat_safety ? ok(`14. decoy_drone → retreat_safety ${dd.retreat_safety}`) : bad('14. decoy', JSON.stringify(dd))
  const rd = (await calc(userId, ship.main_ship_id, [{ support_craft_type_id: 'repair_drone', quantity: 1 }])).data
  rd.repair > base.repair && rd.survival > base.survival ? ok(`15. repair_drone → repair ${rd.repair}, survival ${rd.survival}`) : bad('15. repair', JSON.stringify(rd))

  // 17. deterministic — same input twice → identical output.
  const a = (await calc(userId, ship.main_ship_id, [{ support_craft_type_id: 'missile_boat', quantity: 2 }])).data
  const b = (await calc(userId, ship.main_ship_id, [{ support_craft_type_id: 'missile_boat', quantity: 2 }])).data
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
  .finally(() => { console.log(`\nPhase 8: ${pass} passed, ${fail} failed\n`); process.exitCode = fail > 0 ? 1 : 0 })
