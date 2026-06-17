// Phase 5 verification — Multi-Item Pirate Loot.  node scripts/verify-phase5.mjs
//
// Pirate combat now accrues server-side item drops alongside metal, riding the proven
// Phase 4 bundle. This checks: (1) the deterministic loot table + merge helpers, and
// (2) a REAL combat run — items appear in total_rewards_json, stay pending through
// retreat, and deposit to player_inventory + base_resources on home arrival; defeat
// forfeits both. Then chains verify-phase4 (→ inventory → m45 → m5 → m2/m3/m4) for the
// full regression, unless PHASE5_SKIP_REGRESS=1.

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
if (!serviceKey) { console.error('phase5 verify needs SUPABASE_SERVICE_ROLE_KEY (server-side).'); process.exit(2) }

const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
const supabase = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })

let pass = 0, fail = 0
const ok = (n) => { console.log('  ✓', n); pass++ }
const bad = (n, d) => { console.log('  ✗', n, d ? `— ${d}` : ''); fail++ }
class Abort extends Error {}
const die = (m) => { throw new Abort(m) }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
async function poll(fn, { timeoutMs = 120000, intervalMs = 3000 } = {}) {
  const start = Date.now()
  while (Date.now() - start < timeoutMs) { const v = await fn(); if (v) return v; await sleep(intervalMs) }
  return null
}

const KNOWN = new Set(['scrap', 'ore', 'crystal', 'pirate_alloy', 'weapon_parts', 'engine_parts', 'repair_parts',
  'captain_memory_shard', 'blueprint_fragment', 'artifact_core'])
const loot = async (wave, danger = 0) => (await admin.rpc('pirate_loot_for_wave', { p_wave: wave, p_danger: danger })).data ?? []
const invBal = async (player, item) => (await admin.rpc('inventory_get_balance', { p_player: player, p_item: item })).data ?? 0
const idsOf = (items) => (items ?? []).map((i) => i.item_id)
const qtyOf = (items, id) => (items ?? []).find((i) => i.item_id === id)?.quantity ?? 0
const encounterFor = async (fleetId) => (await supabase.from('combat_encounters').select('*')
  .eq('fleet_id', fleetId).order('created_at', { ascending: false }).limit(1).maybeSingle()).data
const allValid = (items) => (items ?? []).every((i) => KNOWN.has(i.item_id) && Number.isInteger(i.quantity) && i.quantity > 0)

async function main() {
  console.log(`\nPhase 5 (Multi-Item Pirate Loot) verification against ${url}\n`)

  // ── PART 1: deterministic loot table (server-side, no RNG) ────────────────
  console.log('A. Loot table (pirate_loot_for_wave):')
  const w1 = await loot(1), w3 = await loot(3), w5 = await loot(5), w8 = await loot(8), w10 = await loot(10), w0 = await loot(0)
  idsOf(w1).join() === 'scrap' ? ok('wave 1 → scrap only (guaranteed small)') : bad('wave 1', JSON.stringify(w1))
  idsOf(w3).includes('pirate_alloy') && idsOf(w3).includes('scrap') ? ok('wave 3 → + pirate_alloy') : bad('wave 3', JSON.stringify(w3))
  idsOf(w5).includes('weapon_parts') ? ok('wave 5 → + weapon_parts') : bad('wave 5', JSON.stringify(w5))
  idsOf(w8).includes('engine_parts') ? ok('wave 8 → + engine_parts') : bad('wave 8', JSON.stringify(w8))
  idsOf(w10).includes('repair_parts') ? ok('wave 10 → + repair_parts') : bad('wave 10', JSON.stringify(w10))
  ;(Array.isArray(w0) && w0.length === 0) ? ok('wave 0 → [] (no loot below wave 1)') : bad('wave 0', JSON.stringify(w0))
  // 8/9. quantities positive integers; only known seeded ids generated.
  ;[w1, w3, w5, w8, w10].every(allValid) ? ok('8/9. all drops: positive-integer qty, only known seeded item_ids (no NaN/unknown)') : bad('8/9. validity', 'invalid drop found')
  // loot does not explode with survival: quantities stay small/flat.
  ;[...w1, ...w3, ...w5, ...w8, ...w10].every((i) => i.quantity <= 3) ? ok('quantities clamped small (≤3) — loot cannot explode with long survival') : bad('clamp', 'quantity too large')

  // ── PART 2: merge helper combines duplicates ──────────────────────────────
  console.log('\nB. loot_merge_items:')
  const merged = (await admin.rpc('loot_merge_items', {
    p_a: [{ item_id: 'scrap', quantity: 2 }],
    p_b: [{ item_id: 'scrap', quantity: 3 }, { item_id: 'ore', quantity: 1 }],
  })).data ?? []
  qtyOf(merged, 'scrap') === 5 && qtyOf(merged, 'ore') === 1 && merged.length === 2
    ? ok('10. duplicate item drops combined deterministically (scrap 2+3=5, ore 1)') : bad('10. merge', JSON.stringify(merged))

  // ── PART 3: REAL combat — items pending → secured on home arrival ─────────
  console.log('\nC. Real combat (pirate_hunt):')
  const { data: su, error: suErr } = await supabase.auth.signUp({ email: `p5test.${Date.now()}@example.com`, password: 'Test123456!' })
  if (suErr) die(`signup failed: ${suErr.message}`)
  if (!su.session) die('no session — email confirmation still ON')
  const userId = su.user.id
  const { data: base } = await supabase.from('bases').select('id').limit(1).maybeSingle()
  if (!base) die('no base for throwaway user')
  const baseMetal = async () => (await supabase.from('base_resources').select('amount')
    .eq('base_id', base.id).eq('resource_code', 'metal').maybeSingle()).data?.amount ?? 0
  const grantsFor = async (encId) => ((await supabase.from('reward_grants').select('id').eq('source_id', encId)).data ?? []).length
  ok('signed up throwaway user + base ready')

  const { data: world } = await supabase.rpc('get_world_map')
  const hunts = world.sectors.flatMap((s) => s.zones).flatMap((z) => z.locations).filter((l) => l.location_type === 'pirate_hunt')
  const den = hunts.slice().sort((a, b) => b.base_difficulty - a.base_difficulty)[0]

  const { data: dA, error: dAe } = await supabase.rpc('send_fleet_to_location', {
    p_base: base.id, p_location: den.id,
    p_units: [{ unit_type_id: 'scout', quantity: 10 }, { unit_type_id: 'corvette', quantity: 5 }, { unit_type_id: 'frigate', quantity: 2 }],
  })
  if (dAe) die(`dispatch failed: ${dAe.message}`)
  const fleetA = dA.fleet_id
  const metalBefore = await baseMetal()
  const scrapBefore = await invBal(userId, 'scrap')

  // Wait until at least one wave is cleared (pending metal + items accrued).
  const enc = await poll(async () => {
    const e = await encounterFor(fleetA)
    return e && (e.total_rewards_json?.metal ?? 0) > 0 ? e : null
  }, { timeoutMs: 90000, intervalMs: 3000 })
  if (!enc) die('C: combat never accrued a reward (no wave cleared)')
  const pendItems = enc.total_rewards_json?.items ?? []
  ;(enc.total_rewards_json?.metal ?? 0) > 0 ? ok(`1. metal accrued pending (${enc.total_rewards_json.metal})`) : bad('1. metal', 'none')
  Array.isArray(pendItems) && qtyOf(pendItems, 'scrap') >= 1
    ? ok(`1. items[] accrued in total_rewards_json (${JSON.stringify(pendItems)})`) : bad('1. pending items', JSON.stringify(enc.total_rewards_json))
  allValid(pendItems) ? ok('2. pending bundle = metal + valid items[] (positive ints, known ids)') : bad('2. bundle', JSON.stringify(pendItems))

  // 3. Retreat must NOT secure loot — still pending until home.
  if (enc.status === 'active') await supabase.rpc('request_retreat', { p_presence: enc.presence_id })
  ;(await invBal(userId, 'scrap')) === scrapBefore && (await grantsFor(enc.id)) === 0
    ? ok('3. retreat does NOT secure loot (inventory unchanged, no reward_grant yet)') : bad('3. premature secure', 'loot secured on retreat!')

  const escaped = await poll(async () => { const e = await encounterFor(fleetA); return ['escaped', 'completed'].includes(e?.status) ? e : null }, { timeoutMs: 60000, intervalMs: 2000 })
  if (!escaped) die('C: never escaped (fleet may have died — rerun)')
  const lockedItems = escaped.total_rewards_json?.items ?? []
  const lockedMetal = escaped.total_rewards_json?.metal ?? 0
  const { data: ret } = await supabase.from('fleet_movements').select('reward_payload_json').eq('fleet_id', fleetA).eq('mission_type', 'return_home').maybeSingle()
  qtyOf(ret?.reward_payload_json?.items, 'scrap') === qtyOf(lockedItems, 'scrap') && qtyOf(lockedItems, 'scrap') >= 1
    ? ok(`   return movement carries locked items home (${JSON.stringify(ret?.reward_payload_json?.items)})`) : bad('   carry items', JSON.stringify(ret?.reward_payload_json))
  ;(await invBal(userId, 'scrap')) === scrapBefore ? ok('3. still pending after escape (inventory unchanged until arrival)') : bad('3. early deposit', 'deposited before arrival')

  // 4/5. Home arrival secures metal → base_resources and items → player_inventory.
  const done = await poll(async () => {
    const { data: f } = await supabase.from('fleets').select('status').eq('id', fleetA).single()
    return f?.status === 'completed' ? f : null
  }, { timeoutMs: 90000, intervalMs: 3000 })
  done ? ok('fleet returned home (completed)') : bad('return', 'timeout')
  ;(await baseMetal()) === metalBefore + lockedMetal && lockedMetal > 0 ? ok(`4. return-home deposited metal → base_resources (+${lockedMetal})`) : bad('4. metal deposit', `got ${await baseMetal()}, expected ${metalBefore + lockedMetal}`)
  ;(await invBal(userId, 'scrap')) === scrapBefore + qtyOf(lockedItems, 'scrap')
    ? ok(`5. return-home deposited items → player_inventory (scrap +${qtyOf(lockedItems, 'scrap')})`) : bad('5. item deposit', `scrap ${await invBal(userId, 'scrap')}, expected ${scrapBefore + qtyOf(lockedItems, 'scrap')}`)
  ;(await grantsFor(enc.id)) === 1 ? ok('7. exactly one reward_grant on arrival (metal+items deposited once)') : bad('7. idempotency', `${await grantsFor(enc.id)} grants`)
  const { data: rep } = await supabase.from('combat_reports').select('total_rewards_json').eq('encounter_id', escaped.id).maybeSingle()
  ;(rep?.total_rewards_json?.metal ?? 0) === lockedMetal ? ok('11. combat report still includes correct metal (items ride along in jsonb)') : bad('11. report metal', JSON.stringify(rep?.total_rewards_json))

  // ── PART 4: defeat forfeits metal AND items ───────────────────────────────
  console.log('\nD. Defeat forfeits loot:')
  const scrapPreDefeat = await invBal(userId, 'scrap')
  const { data: dB } = await supabase.rpc('send_fleet_to_location', { p_base: base.id, p_location: den.id, p_units: [{ unit_type_id: 'scout', quantity: 1 }] })
  const defeat = await poll(async () => { const e = await encounterFor(dB.fleet_id); return e?.status === 'defeat' ? e : null })
  if (!defeat) die('D: never defeated')
  const noBundle = !defeat.total_rewards_json || Object.keys(defeat.total_rewards_json).length === 0
  noBundle ? ok('6. defeat clears the bundle (total_rewards_json = {}) — metal + items forfeited') : bad('6. forfeit', JSON.stringify(defeat.total_rewards_json))
  ;(await grantsFor(defeat.id)) === 0 ? ok('6. no reward_grant on defeat') : bad('6. defeat grant', 'found')
  ;(await invBal(userId, 'scrap')) === scrapPreDefeat ? ok('6. inventory unchanged on defeat (items not deposited)') : bad('6. defeat inventory', 'changed')

  // ── PART 5: regression ────────────────────────────────────────────────────
  console.log('\nE. Regression (Phase 4 → Inventory → M4.5 → M5 → M2/M3/M4):')
  if (env.PHASE5_SKIP_REGRESS === '1') console.log('  · skipped (PHASE5_SKIP_REGRESS=1)')
  else { try { execSync('node scripts/verify-phase4.mjs', { stdio: 'inherit' }); ok('verify:phase4 (chains inventory/m45/m5/m2/m3/m4) passed') } catch { bad('regression', 'verify:phase4 non-zero exit') } }
}

main()
  .catch((e) => { if (e instanceof Abort) bad('ABORTED', e.message); else bad('UNEXPECTED', e?.message ?? String(e)) })
  .finally(() => { console.log(`\nPhase 5: ${pass} passed, ${fail} failed\n`); process.exitCode = fail > 0 ? 1 : 0 })
