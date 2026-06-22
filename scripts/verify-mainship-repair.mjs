// Phase 10F verification — main-ship destroyed/repair safelock.
//   node scripts/verify-mainship-repair.mjs
//
// Proves the safe landing + recovery path (NO combat, NO trigger — uses the service-role-only
// dev_set_main_ship_destroyed helper to simulate a future defeat):
//   • destroying a ship mid-expedition cleans up its linked fleet/movement/presence and wins over
//     in-flight state (status='destroyed', hp=0, no active main-ship fleet remains)
//   • send is blocked while destroyed; request_main_ship_return cannot return from it
//   • repair_main_ship() restores status='home', hp=max_hp (instant, free)
//   • send works again after repair
//   • no fleet_units were ever created for main-ship fleets
//
// Needs SUPABASE_SERVICE_ROLE_KEY (commission ship, dev-destroy, flip flag). Temporarily enables
// mainship_send_enabled + shrinks travel config; restores ALL of it in finally.

import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'
import { teardownVerifier } from './lib/verifier-teardown.mjs'

function loadEnv(p) {
  const e = {}
  try { for (const l of readFileSync(p, 'utf8').split('\n')) { const m = l.match(/^\s*([\w.]+)\s*=\s*(.*)\s*$/); if (m) e[m[1]] = m[2].trim().replace(/^['"]|['"]$/g, '') } } catch {}
  return e
}
const env = { ...loadEnv('.env.local'), ...process.env }
const url = env.VITE_SUPABASE_URL
const anonKey = env.VITE_SUPABASE_ANON_KEY
const serviceKey = env.SUPABASE_SERVICE_ROLE_KEY || env.SUPABASE_SERVICE_KEY || env.SUPABASE_SECRET_KEY
if (!url || !anonKey) { console.error('Missing VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY'); process.exit(2) }
if (!serviceKey) { console.error('needs SUPABASE_SERVICE_ROLE_KEY'); process.exit(2) }

const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
let pass = 0, fail = 0
const ok = (n) => { console.log('  ✓', n); pass++ }
const bad = (n, d) => { console.log('  ✗', n, d ? `— ${d}` : ''); fail++ }
class Abort extends Error {}
const die = (m) => { throw new Abort(m) }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
async function poll(fn, { timeoutMs = 75000, intervalMs = 3000 } = {}) {
  const start = Date.now()
  while (Date.now() - start < timeoutMs) { const v = await fn(); if (v) return v; await sleep(intervalMs) }
  return null
}
const setCfg = (k, v) => admin.rpc('set_game_config', { p_key: k, p_value: v })
const cfgVal = async (k) => (await admin.from('game_config').select('value').eq('key', k).maybeSingle()).data?.value
const shipRow = async (userId) => (await admin.from('main_ship_instances').select('main_ship_id,status,hp,max_hp').eq('player_id', userId).maybeSingle()).data
const activeMsFleets = async (shipId) => (await admin.from('fleets').select('id,status').eq('main_ship_id', shipId).in('status', ['moving', 'present', 'returning'])).data ?? []

async function newUser(tag) {
  const c = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: su, error } = await c.auth.signUp({ email: `msrepairtest.${tag}.${Date.now()}@example.com`, password: 'Test123456!' })
  if (error) die(`signup failed: ${error.message}`)
  if (!su.session) die('no session — email confirmation still ON')
  const userId = su.user.id
  createdUserIds.push(userId)   // track immediately after creation for finally cleanup
  return { client: c, userId }
}

let origScale, origMin, origSend, flagTouched = false
const createdUserIds = []

async function main() {
  console.log(`\nPhase 10F (main-ship repair/safelock) verification against ${url}\n`)

  origScale = await cfgVal('travel_scale')
  origMin   = await cfgVal('min_travel_seconds')
  origSend  = await cfgVal('mainship_send_enabled')   // capture original BEFORE any flag write
  await setCfg('travel_scale', 0.001)
  await setCfg('min_travel_seconds', 2)
  await setCfg('mainship_send_enabled', true); flagTouched = true

  const u = await newUser('a')
  const base = await poll(async () => (await u.client.from('bases').select('id, status').eq('status', 'active').maybeSingle()).data, { timeoutMs: 20000, intervalMs: 1500 })
  if (!base) die('no active base')
  await admin.rpc('ensure_main_ship_for_player', { p_player: u.userId })
  const ship0 = await shipRow(u.userId)
  if (!ship0?.main_ship_id) die('ship not commissioned')
  const shipId = ship0.main_ship_id
  const maxHp = ship0.max_hp
  ship0.status === 'home' && ship0.hp === maxHp ? ok(`setup: ship home, hp ${ship0.hp}/${maxHp}`) : bad('setup', JSON.stringify(ship0))

  const { data: world } = await u.client.rpc('get_world_map')
  const safe = world.sectors.flatMap((s) => s.zones).flatMap((z) => z.locations).find((l) => l.location_type === 'safe_zone')
  if (!safe) die('no safe_zone')

  // ── Send the ship out so we can prove destroy cleans up an ACTIVE linked fleet ───────────────
  const { data: sent, error: sErr } = await u.client.rpc('send_main_ship_expedition', { p_ships: [shipId], p_location: safe.id })
  if (sErr) die(`send failed: ${sErr.message}`)
  const fleetId = sent.fleet_id
  ;(await activeMsFleets(shipId)).some((f) => f.id === fleetId)
    ? ok('sent: active main-ship fleet exists (moving)') : bad('send setup', 'no active fleet')

  // ── 1) dev-destroy (service-role) → destroyed + cleanup; destroyed wins over in-flight ───────
  const { data: dz, error: dzErr } = await admin.rpc('dev_set_main_ship_destroyed', { p_player: u.userId })
  if (dzErr) die(`dev destroy failed: ${dzErr.message}`)
  const s1 = await shipRow(u.userId)
  s1.status === 'destroyed' && s1.hp === 0 ? ok(`1. ship destroyed (disabled), hp 0 (cleaned ${dz.fleets_cleaned} fleet[s])`) : bad('1. destroyed', JSON.stringify(s1))
  const fleetAfter = (await admin.from('fleets').select('status').eq('id', fleetId).maybeSingle()).data
  fleetAfter?.status === 'destroyed' ? ok('1a. linked fleet marked terminal (destroyed)') : bad('1a. fleet cleanup', JSON.stringify(fleetAfter))
  ;((await admin.from('fleet_movements').select('id').eq('fleet_id', fleetId).eq('status', 'moving')).data ?? []).length === 0
    ? ok('1b. no in-flight movement remains (cancelled)') : bad('1b. movement cleanup', 'a moving movement survived')
  ;(await activeMsFleets(shipId)).length === 0 ? ok('1c. no active main-ship fleet remains (reconciler can\'t revive it)') : bad('1c. active fleet', 'still active')

  // ── 2) send blocked while destroyed ──────────────────────────────────────────────────────────
  {
    const { error } = await u.client.rpc('send_main_ship_expedition', { p_ships: [shipId], p_location: safe.id })
    error ? ok('2. send blocked while destroyed') : bad('2. send block', 'send accepted while destroyed!')
  }

  // ── 3) request_main_ship_return cannot return from a destroyed/inactive fleet ────────────────
  {
    const { error } = await u.client.rpc('request_main_ship_return', { p_fleet: fleetId })
    error ? ok('3. request_main_ship_return fails (no active present fleet)') : bad('3. return block', 'return accepted!')
  }

  // ── 4) repair_main_ship (as the authenticated player) → home + full hp ───────────────────────
  const { data: rep, error: rErr } = await u.client.rpc('repair_main_ship', {})
  if (rErr) die(`repair failed: ${rErr.message}`)
  const s2 = await shipRow(u.userId)
  rep?.status === 'home' && s2.status === 'home' && s2.hp === maxHp
    ? ok(`4. repair → home, hp restored ${s2.hp}/${maxHp}`) : bad('4. repair', JSON.stringify({ rep, s2 }))

  // ── 5) repair again now fails clearly (not destroyed) ────────────────────────────────────────
  {
    const { error } = await u.client.rpc('repair_main_ship', {})
    error && /not disabled|nothing to repair/i.test(error.message) ? ok('5. repair on a healthy ship fails clearly') : bad('5. repair guard', error?.message ?? 'repaired a healthy ship')
  }

  // ── 6) send works again after repair ─────────────────────────────────────────────────────────
  {
    const { data, error } = await u.client.rpc('send_main_ship_expedition', { p_ships: [shipId], p_location: safe.id })
    error ? bad('6. post-repair send', error.message) : (data?.fleet_id ? ok('6. send works again after repair') : bad('6. post-repair send', JSON.stringify(data)))
  }

  // ── 7) anti-cheat: dev_set_main_ship_destroyed is NOT callable by a normal user ──────────────
  {
    const { error } = await u.client.rpc('dev_set_main_ship_destroyed', { p_player: u.userId })
    error ? ok('7. dev_set_main_ship_destroyed denied to clients (service-role only)') : bad('7. dev helper exposed', 'a client destroyed a ship!')
  }

  // ── 8) no fleet_units ever created for main-ship fleets ──────────────────────────────────────
  {
    const ids = ((await admin.from('fleets').select('id').eq('player_id', u.userId).not('main_ship_id', 'is', null)).data ?? []).map((f) => f.id)
    const units = ids.length ? ((await admin.from('fleet_units').select('id').in('fleet_id', ids)).data ?? []) : []
    units.length === 0 ? ok('8. zero fleet_units for main-ship fleets') : bad('8. fleet_units', `found ${units.length}`)
  }
}

main()
  .catch((e) => { if (e instanceof Abort) bad('ABORTED', e.message); else bad('UNEXPECTED', e?.message ?? String(e)) })
  .finally(async () => {
    // Teardown (Legacy Main-Ship Verifier Safety Repair): delete verifier-created users (cascade)
    // and restore the CAPTURED original send flag — never a hardcoded value.
    const { failures } = await teardownVerifier({
      admin, createdUserIds,
      flag: { key: 'mainship_send_enabled', original: origSend, touched: flagTouched },
    })
    for (const [k, v] of [['travel_scale', origScale], ['min_travel_seconds', origMin]]) {
      if (v === undefined) continue
      try { const { error } = await setCfg(k, v); if (error) failures.push(`restore ${k}: ${error.message}`) }
      catch (e) { failures.push(`restore ${k}: ${e?.message ?? String(e)}`) }
    }
    failures.forEach((f) => bad('TEARDOWN', f))
    console.log(`\nMain-ship repair: ${pass} passed, ${fail} failed\n`)
    process.exitCode = fail > 0 ? 1 : 0
  })
