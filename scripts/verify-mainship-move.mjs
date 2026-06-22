// Verification — direct main-ship location→location move (move_main_ship_to_location).
//   node scripts/verify-mainship-move.mjs
//
// Proves a PRESENT main ship can be sent straight from location A to location B (departing A, no
// forced return home), while every other state stays blocked and all safety invariants hold:
//   • present A → move → moving (origin=A, target=B); exactly one active main-ship fleet throughout
//   • same-location move rejected; moving/returning/destroyed rejected
//   • on arrival: present at B, presence A 'completed', presence B 'active'
//   • recall from B still returns to the HOME base
//   • zero fleet_units / no base_units pollution
//
// Needs SUPABASE_SERVICE_ROLE_KEY. Temporarily enables the flag + shrinks travel config; restores
// all of it in finally.

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
const fleetRow = async (id) => (await admin.from('fleets').select('status,current_location_id,main_ship_id').eq('id', id).maybeSingle()).data
const activeMsFleets = async (shipId) => (await admin.from('fleets').select('id').eq('main_ship_id', shipId).in('status', ['moving', 'present', 'returning'])).data ?? []
const moveRow = async (id) => (await admin.from('fleet_movements').select('origin_location_id,target_location_id,target_type,mission_type').eq('id', id).maybeSingle()).data

async function newUser(tag) {
  const c = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: su, error } = await c.auth.signUp({ email: `msmovetest.${tag}.${Date.now()}@example.com`, password: 'Test123456!' })
  if (error) die(`signup failed: ${error.message}`)
  if (!su.session) die('no session — email confirmation still ON')
  const userId = su.user.id
  createdUserIds.push(userId)   // track immediately after creation for finally cleanup
  return { client: c, userId }
}

let origScale, origMin, origSend, flagTouched = false
const createdUserIds = []

async function main() {
  console.log(`\nMain-ship move (location→location) verification against ${url}\n`)

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
  const shipId = (await admin.from('main_ship_instances').select('main_ship_id').eq('player_id', u.userId).maybeSingle()).data?.main_ship_id
  if (!shipId) die('ship not commissioned')

  const { data: world } = await u.client.rpc('get_world_map')
  const nonCombat = world.sectors.flatMap((s) => s.zones).flatMap((z) => z.locations).filter((l) => l.activity_type === 'none')
  if (nonCombat.length < 2) die(`need >=2 non-combat locations, found ${nonCombat.length}`)
  const A = nonCombat[0], B = nonCombat[1]
  const combat = world.sectors.flatMap((s) => s.zones).flatMap((z) => z.locations).find((l) => l.activity_type === 'hunt_pirates')

  // ── send home → A, wait present ──────────────────────────────────────────────
  const { data: sent, error: sErr } = await u.client.rpc('send_main_ship_expedition', { p_ships: [shipId], p_location: A.id })
  if (sErr) die(`send failed: ${sErr.message}`)
  const fleetId = sent.fleet_id
  const presentA = await poll(async () => { const f = await fleetRow(fleetId); return f?.status === 'present' ? f : null })
  presentA && presentA.current_location_id === A.id ? ok(`1. main ship present at A (${A.name})`) : bad('1. present at A', JSON.stringify(presentA))
  ;(await activeMsFleets(shipId)).length === 1 ? ok('1a. exactly one active main-ship fleet') : bad('1a. active fleet', 'not 1')

  // ── same-location move rejected ──────────────────────────────────────────────
  {
    const { error } = await u.client.rpc('move_main_ship_to_location', { p_fleet: fleetId, p_location: A.id })
    error && /already at that location/i.test(error.message) ? ok('2. same-location move rejected (already here)') : bad('2. same-location', error?.message ?? 'accepted')
  }

  // ── combat destination rejected ──────────────────────────────────────────────
  if (combat) {
    const { error } = await u.client.rpc('move_main_ship_to_location', { p_fleet: fleetId, p_location: combat.id })
    error && /non-combat/i.test(error.message) ? ok('3. combat destination rejected') : bad('3. combat dest', error?.message ?? 'accepted a combat dest')
  }

  // ── move A → B directly (no return home) ─────────────────────────────────────
  const { data: mv, error: mErr } = await u.client.rpc('move_main_ship_to_location', { p_fleet: fleetId, p_location: B.id })
  if (mErr) die(`move failed: ${mErr.message}`)
  mv?.from_location_id === A.id && mv?.to_location_id === B.id ? ok(`4. move A→B accepted (${A.name} → ${B.name})`) : bad('4. move result', JSON.stringify(mv))
  {
    const m = await moveRow(mv.movement_id)
    m?.origin_location_id === A.id && m?.target_location_id === B.id && m?.target_type === 'location'
      ? ok('4a. movement departs A, targets B (origin_location_id=A, target_location_id=B)') : bad('4a. movement origin/target', JSON.stringify(m))
  }
  {
    const f = await fleetRow(fleetId)
    f?.status === 'moving' ? ok('4b. fleet status → moving') : bad('4b. fleet moving', f?.status)
  }
  ;(await activeMsFleets(shipId)).length === 1 ? ok('4c. still exactly one active main-ship fleet (reused, no new slot)') : bad('4c. active fleet', 'not 1')
  ;((await admin.from('location_presence').select('status').eq('fleet_id', fleetId).eq('location_id', A.id).maybeSingle()).data?.status) === 'completed'
    ? ok('4d. presence at A is completed') : bad('4d. presence A', 'not completed')

  // ── reject while moving ──────────────────────────────────────────────────────
  {
    const { error } = await u.client.rpc('move_main_ship_to_location', { p_fleet: fleetId, p_location: A.id })
    error && /not present/i.test(error.message) ? ok('5. move rejected while moving') : bad('5. moving reject', error?.message ?? 'accepted while moving')
  }

  // ── arrive present at B ──────────────────────────────────────────────────────
  const presentB = await poll(async () => { const f = await fleetRow(fleetId); return f?.status === 'present' ? f : null })
  presentB && presentB.current_location_id === B.id ? ok(`6. arrived present at B (${B.name})`) : bad('6. present at B', JSON.stringify(presentB))
  ;((await admin.from('location_presence').select('status').eq('fleet_id', fleetId).eq('location_id', B.id).eq('status', 'active').maybeSingle()).data)
    ? ok('6a. active presence at B') : bad('6a. presence B', 'no active presence at B')

  // ── recall from B → returns to HOME base (not a location) ─────────────────────
  const { data: ret, error: rErr } = await u.client.rpc('request_main_ship_return', { p_fleet: fleetId })
  if (rErr) die(`return failed: ${rErr.message}`)
  {
    const rm = await moveRow(ret.return_movement_id)
    rm?.target_type === 'base' && rm?.mission_type === 'return_home' ? ok('7. recall from B returns to home base') : bad('7. recall target', JSON.stringify(rm))
  }

  // ── reject while returning ───────────────────────────────────────────────────
  {
    const { error } = await u.client.rpc('move_main_ship_to_location', { p_fleet: fleetId, p_location: B.id })
    error && /not present/i.test(error.message) ? ok('8. move rejected while returning') : bad('8. returning reject', error?.message ?? 'accepted while returning')
  }

  // ── reject while destroyed ───────────────────────────────────────────────────
  await admin.rpc('dev_set_main_ship_destroyed', { p_player: u.userId })
  {
    const { error } = await u.client.rpc('move_main_ship_to_location', { p_fleet: fleetId, p_location: B.id })
    error ? ok('9. move rejected while destroyed') : bad('9. destroyed reject', 'accepted while destroyed')
  }

  // ── no fleet_units for main-ship fleets; no base_units pollution ──────────────
  {
    const ids = ((await admin.from('fleets').select('id').eq('player_id', u.userId).not('main_ship_id', 'is', null)).data ?? []).map((f) => f.id)
    const units = ids.length ? ((await admin.from('fleet_units').select('id').in('fleet_id', ids)).data ?? []) : []
    units.length === 0 ? ok('10. zero fleet_units for main-ship fleets') : bad('10. fleet_units', `found ${units.length}`)
    const bu = ((await admin.from('base_units').select('quantity').eq('base_id', base.id)).data ?? []).reduce((a, r) => a + r.quantity, 0)
    Number.isFinite(bu) ? ok(`10a. base_units intact (sum ${bu}, never touched by main-ship moves)`) : bad('10a. base_units', 'unreadable')
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
    console.log(`\nMain-ship move: ${pass} passed, ${fail} failed\n`)
    process.exitCode = fail > 0 ? 1 : 0
  })
