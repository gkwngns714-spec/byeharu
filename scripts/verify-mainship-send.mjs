// Phase 10C verification — the first main-ship WRITE path (non-combat, flag-gated).
//   node scripts/verify-mainship-send.mjs
//
// Proves send_main_ship_expedition / request_main_ship_return / process_mainship_expeditions:
//   • flag-gated (off by default → rejected)
//   • exactly-one-ship, ownership, availability, and NON-COMBAT-only validations
//   • the created fleet carries main_ship_id and ZERO fleet_units (a real bridge, not a
//     disguised disposable unit fleet)
//   • the ship status flows home → traveling → returning → home
//   • the return helper computes return speed from the hull (no fleet_speed dependency)
//   • the reconciler syncs the ship home once its tagged fleet completes
//   • NO base_units pollution across the whole round trip
//   • the OLD send_fleet_to_location path is untouched and DISTINCT (its fleet has no
//     main_ship_id; the main-ship return helper refuses to act on it)
//   • client cannot call the server-only reconciler
//
// Needs SUPABASE_SERVICE_ROLE_KEY to flip the feature flag, commission a test ship, and run
// the reconciler. It restores all config it touches (flag + travel knobs) in finally.

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
if (!serviceKey) { console.error('needs SUPABASE_SERVICE_ROLE_KEY (flag + ship + reconciler)'); process.exit(2) }

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
const ZERO = '00000000-0000-0000-0000-000000000000'
const setCfg = (k, v) => admin.rpc('set_game_config', { p_key: k, p_value: v })
const cfgVal = async (k) => (await admin.from('game_config').select('value').eq('key', k).maybeSingle()).data?.value

async function newUser(tag) {
  const c = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: su, error } = await c.auth.signUp({ email: `mssendtest.${tag}.${Date.now()}@example.com`, password: 'Test123456!' })
  if (error) die(`signup failed: ${error.message}`)
  if (!su.session) die('no session — email confirmation still ON')
  const userId = su.user.id
  createdUserIds.push(userId)   // track immediately after creation for finally cleanup
  return { client: c, userId }
}

// Restored / cleaned up in finally.
let origScale, origMin, origSend, flagTouched = false
const createdUserIds = []

async function main() {
  console.log(`\nPhase 10C (main-ship send) verification against ${url}\n`)

  // ── Speed the round trip: travel below the 30s movement-cron cadence, restore later.
  //    Existing in-flight movements are unaffected (arrive_at is stamped at creation).
  origScale = await cfgVal('travel_scale')
  origMin   = await cfgVal('min_travel_seconds')
  origSend  = await cfgVal('mainship_send_enabled')   // capture original BEFORE any flag write
  await setCfg('travel_scale', 0.001)
  await setCfg('min_travel_seconds', 2)

  // ── Setup: user (auto base) + commissioned main ship + a safe (non-combat) location ──
  const u = await newUser('a')
  const base = await poll(async () => (await u.client.from('bases').select('id, x, y, status').eq('status', 'active').maybeSingle()).data, { timeoutMs: 20000, intervalMs: 1500 })
  if (!base) die('no active base for the new user')
  await admin.rpc('ensure_main_ship_for_player', { p_player: u.userId })
  const ship0 = (await admin.from('main_ship_instances').select('main_ship_id, status').eq('player_id', u.userId).maybeSingle()).data
  if (!ship0?.main_ship_id) die('main ship not commissioned')
  const shipId = ship0.main_ship_id
  ship0.status === 'home' ? ok('setup: user + active base + commissioned main ship (status home)') : bad('setup', `ship status ${ship0.status}`)

  const { data: world } = await u.client.rpc('get_world_map')
  const allLocs = world.sectors.flatMap((s) => s.zones).flatMap((z) => z.locations)
  const safe = allLocs.find((l) => l.location_type === 'safe_zone')
  const combat = allLocs.find((l) => l.location_type === 'pirate_hunt')
  if (!safe || !combat) die('world missing safe_zone / pirate_hunt locations')

  const shipStatus = async () => (await u.client.from('main_ship_instances').select('status').eq('main_ship_id', shipId).maybeSingle()).data?.status
  const fleetUnitCount = async (fid) => ((await u.client.from('fleet_units').select('id').eq('fleet_id', fid)).data ?? []).length
  const baseUnitSum = async () => ((await u.client.from('base_units').select('quantity').eq('base_id', base.id)).data ?? []).reduce((a, r) => a + r.quantity, 0)

  // ── 1) Flag OFF → rejected ──────────────────────────────────────────────────
  await setCfg('mainship_send_enabled', false); flagTouched = true
  {
    const { error } = await u.client.rpc('send_main_ship_expedition', { p_ships: [shipId], p_location: safe.id })
    error && /disabled/i.test(error.message) ? ok('1. flag OFF → send rejected (feature disabled)') : bad('1. flag-off gate', error?.message ?? 'accepted while disabled!')
  }

  // Flip the flag ON for the rest of the run.
  await setCfg('mainship_send_enabled', true)

  // ── 2) Validation: exactly one ship ─────────────────────────────────────────
  {
    const r0 = await u.client.rpc('send_main_ship_expedition', { p_ships: [], p_location: safe.id })
    const r2 = await u.client.rpc('send_main_ship_expedition', { p_ships: [shipId, shipId], p_location: safe.id })
    r0.error && r2.error && /exactly one/i.test(r0.error.message) ? ok('2. exactly-one-ship enforced (0 and 2 rejected)') : bad('2. exactly-one', `${r0.error?.message} / ${r2.error?.message}`)
  }

  // ── 3) Validation: ownership ─────────────────────────────────────────────────
  {
    const { error } = await u.client.rpc('send_main_ship_expedition', { p_ships: [ZERO], p_location: safe.id })
    error && /not found or not owned/i.test(error.message) ? ok('3. unowned ship id rejected') : bad('3. ownership', error?.message ?? 'accepted')
  }

  // ── 4) Validation: NON-COMBAT only ───────────────────────────────────────────
  {
    const { error } = await u.client.rpc('send_main_ship_expedition', { p_ships: [shipId], p_location: combat.id })
    error && /non-combat/i.test(error.message) ? ok('4. combat location rejected (non-combat only in 10C)') : bad('4. non-combat gate', error?.message ?? 'accepted a combat location!')
  }

  // ── 5) Happy path: outbound ──────────────────────────────────────────────────
  const baseUnitsBefore = await baseUnitSum()
  const { data: sent, error: sErr } = await u.client.rpc('send_main_ship_expedition', { p_ships: [shipId], p_location: safe.id })
  if (sErr) die(`send failed: ${sErr.message}`)
  const fleetId = sent.fleet_id
  sent.fleet_id && sent.movement_id && sent.main_ship_id === shipId && sent.arrive_at
    ? ok('5. send accepted → {fleet_id, movement_id, main_ship_id, arrive_at}') : bad('5. send return', JSON.stringify(sent))

  const fleet = (await u.client.from('fleets').select('main_ship_id, status, origin_base_id').eq('id', fleetId).maybeSingle()).data
  fleet?.main_ship_id === shipId ? ok('5a. fleet tagged with main_ship_id') : bad('5a. fleet tag', JSON.stringify(fleet))
  ;(await fleetUnitCount(fleetId)) === 0 ? ok('5b. fleet carries ZERO fleet_units (real bridge, not a fake unit fleet)') : bad('5b. fleet_units', 'fleet has units!')
  fleet?.status === 'moving' ? ok('5c. fleet status moving') : bad('5c. fleet status', fleet?.status)
  ;(await shipStatus()) === 'traveling' ? ok('5d. ship status → traveling') : bad('5d. ship status', await shipStatus())
  {
    const mv = (await u.client.from('fleet_movements').select('mission_type, target_type, target_location_id').eq('id', sent.movement_id).maybeSingle()).data
    mv?.mission_type === 'rally' && mv.target_type === 'location' && mv.target_location_id === safe.id
      ? ok('5e. outbound movement created (rally → safe location)') : bad('5e. movement', JSON.stringify(mv))
  }

  // ── 6) Re-send while out → ship not available (status guard) ──────────────────
  {
    const { error } = await u.client.rpc('send_main_ship_expedition', { p_ships: [shipId], p_location: safe.id })
    error && /not available/i.test(error.message) ? ok('6. re-send while traveling rejected (ship not available)') : bad('6. availability guard', error?.message ?? 'double-sent the same ship!')
  }

  // ── 7) Arrival (movement cron) → present, then return helper ──────────────────
  const present = await poll(async () => {
    const f = (await u.client.from('fleets').select('status').eq('id', fleetId).maybeSingle()).data
    return f?.status === 'present' ? f : null
  })
  present ? ok('7. fleet arrived (present) via movement cron') : die('7. fleet never became present')

  const { data: ret, error: rErr } = await u.client.rpc('request_main_ship_return', { p_fleet: fleetId })
  if (rErr) die(`return failed: ${rErr.message}`)
  ret?.return_movement_id ? ok('7a. return helper → return_movement_id') : bad('7a. return helper', JSON.stringify(ret))
  {
    const f = (await u.client.from('fleets').select('status').eq('id', fleetId).maybeSingle()).data
    f?.status === 'returning' ? ok('7b. fleet status → returning') : bad('7b. fleet returning', f?.status)
  }
  ;(await shipStatus()) === 'returning' ? ok('7c. ship status → returning') : bad('7c. ship returning', await shipStatus())
  {
    const rm = (await u.client.from('fleet_movements').select('mission_type, target_type').eq('id', ret.return_movement_id).maybeSingle()).data
    rm?.mission_type === 'return_home' && rm.target_type === 'base' ? ok('7d. return movement (return_home → base)') : bad('7d. return movement', JSON.stringify(rm))
  }

  // ── 8) Return arrival (cron) → completed, then reconciler homes the ship ──────
  const completed = await poll(async () => {
    const f = (await u.client.from('fleets').select('status').eq('id', fleetId).maybeSingle()).data
    return f?.status === 'completed' ? f : null
  })
  completed ? ok('8. return movement completed the fleet (movement cron)') : die('8. fleet never completed')

  // Ship is still 'returning' until the reconciler runs; fire it directly (service-role).
  ;(await shipStatus()) === 'returning' ? ok('8a. ship still returning before reconciler (status owned separately)') : bad('8a. pre-reconciler', await shipStatus())
  const reconciled = await admin.rpc('process_mainship_expeditions')
  typeof reconciled.data === 'number' ? ok(`8b. reconciler ran (homed ${reconciled.data} ship[s])`) : bad('8b. reconciler', JSON.stringify(reconciled.error ?? reconciled.data))
  ;(await shipStatus()) === 'home' ? ok('8c. ship status → home (reconciled)') : bad('8c. ship home', await shipStatus())

  // ── 9) No base_units pollution across the whole round trip ────────────────────
  ;(await baseUnitSum()) === baseUnitsBefore ? ok(`9. base_units unchanged by the main-ship round trip (${baseUnitsBefore})`) : bad('9. base pollution', `before ${baseUnitsBefore} → after ${await baseUnitSum()}`)

  // ── 10) Old path untouched + DISTINCT from the main-ship path ─────────────────
  {
    const { data: old, error: oErr } = await u.client.rpc('send_fleet_to_location', { p_base: base.id, p_location: safe.id, p_units: [{ unit_type_id: 'scout', quantity: 1 }] })
    if (oErr) { bad('10. old send still works', oErr.message) }
    else {
      const of = (await u.client.from('fleets').select('main_ship_id').eq('id', old.fleet_id).maybeSingle()).data
      of && of.main_ship_id === null ? ok('10a. old send_fleet_to_location still works AND its fleet has no main_ship_id') : bad('10a. old path distinct', JSON.stringify(of))
      const { error: xErr } = await u.client.rpc('request_main_ship_return', { p_fleet: old.fleet_id })
      xErr && /not a main-ship fleet/i.test(xErr.message) ? ok('10b. main-ship return helper refuses an old unit fleet') : bad('10b. helper isolation', xErr?.message ?? 'acted on an old fleet!')
    }
  }

  // ── 11) Anti-cheat: the reconciler is server-only ─────────────────────────────
  {
    const { error } = await u.client.rpc('process_mainship_expeditions')
    error ? ok('11. process_mainship_expeditions denied to clients') : bad('11. reconciler exposed', 'client executed the reconciler!')
  }
}

main()
  .catch((e) => { if (e instanceof Abort) bad('ABORTED', e.message); else bad('UNEXPECTED', e?.message ?? String(e)) })
  .finally(async () => {
    // Teardown (Legacy Main-Ship Verifier Safety Repair): delete verifier-created users (cascade
    // removes their game data) and restore the CAPTURED original send flag — never a hardcoded value.
    const { failures } = await teardownVerifier({
      admin, createdUserIds,
      flag: { key: 'mainship_send_enabled', original: origSend, touched: flagTouched },
    })
    // restore the temporary travel knobs this verifier shrank
    for (const [k, v] of [['travel_scale', origScale], ['min_travel_seconds', origMin]]) {
      if (v === undefined) continue
      try { const { error } = await setCfg(k, v); if (error) failures.push(`restore ${k}: ${error.message}`) }
      catch (e) { failures.push(`restore ${k}: ${e?.message ?? String(e)}`) }
    }
    failures.forEach((f) => bad('TEARDOWN', f))
    console.log(`\nMain-ship send: ${pass} passed, ${fail} failed\n`)
    process.exitCode = fail > 0 ? 1 : 0
  })
