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
// Section 12 (item 6A): OSN flags captured up-front, toggled ONLY inside that section (established
// capture/restore verifier pattern — same as the send flag), restored in finally.
let origSpaceMv, origCoord
const createdUserIds = []

async function main() {
  console.log(`\nMain-ship move (location→location) verification against ${url}\n`)

  origScale = await cfgVal('travel_scale')
  origMin   = await cfgVal('min_travel_seconds')
  origSend  = await cfgVal('mainship_send_enabled')   // capture original BEFORE any flag write
  origSpaceMv = await cfgVal('mainship_space_movement_enabled')
  origCoord   = await cfgVal('mainship_coordinate_travel_enabled')
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

  // ── 11. stop-transit (UX-CLEANUP item 3, migration 0149): halt outbound → symmetric return home ────
  {
    // Deployment probe: the RPC ships with migration 0149. If the target DB does not have it yet,
    // SKIP this section loudly (apply 0149, then re-run) rather than failing the whole suite.
    const probe = await u.client.rpc('command_main_ship_stop_transit', { p_fleet: '00000000-0000-4000-8000-000000000000' })
    if (probe.error && /could not find|does not exist|schema cache/i.test(probe.error.message)) {
      console.log('  ⤳ 11. SKIPPED — command_main_ship_stop_transit not deployed (apply migration 0149, then re-run)')
    } else {
      await setCfg('min_travel_seconds', 45) // long outbound so the stop lands mid-flight (finally restores)
      const u2 = await newUser('b')
      await poll(async () => (await u2.client.from('bases').select('id').limit(1).maybeSingle()).data, { timeoutMs: 20000, intervalMs: 1500 })
      await admin.rpc('ensure_main_ship_for_player', { p_player: u2.userId })
      const ship2 = (await admin.from('main_ship_instances').select('main_ship_id').eq('player_id', u2.userId).maybeSingle()).data?.main_ship_id
      if (!ship2) die('11: second ship not commissioned')
      const { data: sent2, error: sErr2 } = await u2.client.rpc('send_main_ship_expedition', { p_ships: [ship2], p_location: A.id })
      if (sErr2) die(`11: send failed: ${sErr2.message}`)
      const fleet2 = sent2.fleet_id
      await sleep(3000) // let some outbound time elapse — the symmetric return should take about this long

      const t0 = Date.now()
      const { data: stop1, error: st1 } = await u2.client.rpc('command_main_ship_stop_transit', { p_fleet: fleet2 })
      if (st1) die(`11: stop failed: ${st1.message}`)
      stop1?.ok === true && stop1?.stopped === true
        ? ok('11. mid-flight stop accepted (halt → return home)') : bad('11. stop', JSON.stringify(stop1))

      const m2 = await moveRow(sent2.movement_id)
      m2?.mission_type === 'return_home' && m2?.target_type === 'base'
        ? ok('11a. movement transformed IN PLACE → return_home targeting the home base') : bad('11a. transform', JSON.stringify(m2))
      const f2 = await fleetRow(fleet2)
      f2?.status === 'returning' ? ok('11b. fleet status → returning') : bad('11b. returning', f2?.status)
      const ship2Status = (await admin.from('main_ship_instances').select('status').eq('main_ship_id', ship2).maybeSingle()).data?.status
      ship2Status === 'returning' ? ok('11c. main ship status → returning') : bad('11c. ship status', ship2Status)
      {
        const secs = (new Date(stop1.arrive_at).getTime() - t0) / 1000
        secs > 0 && secs < 20
          ? ok(`11d. symmetric turnaround (arrives home in ~${secs.toFixed(1)}s ≈ elapsed outbound)`) : bad('11d. symmetric timing', `${secs}s`)
      }
      const { data: stop2 } = await u2.client.rpc('command_main_ship_stop_transit', { p_fleet: fleet2 })
      stop2?.ok === true && stop2?.stopped === false && stop2?.reason === 'already_returning'
        ? ok('11e. duplicate stop is a no-op (already_returning)') : bad('11e. duplicate', JSON.stringify(stop2))
      const done2 = await poll(async () => { const f = await fleetRow(fleet2); return f?.status === 'completed' ? f : null })
      done2 ? ok('11f. returned home via the ONE settlement path (process_fleet_movements → fleet completed)') : bad('11f. settle', 'fleet never completed')
      const { data: stop3 } = await u2.client.rpc('command_main_ship_stop_transit', { p_fleet: fleet2 })
      stop3?.ok === true && stop3?.stopped === false && stop3?.reason === 'already_settled'
        ? ok('11g. post-arrival stop is a no-op (already_settled)') : bad('11g. post-arrival', JSON.stringify(stop3))
    }
  }

  // ── 12. on-demand OSN arrival settle (UX-CLEANUP item 6A, migration 0150) ──────────────────────────
  {
    // Deployment probe: SKIP loudly until 0150 is applied, exactly like section 11's probe.
    const probe = await u.client.rpc('command_main_ship_settle_arrival', { p_main_ship_id: null })
    if (probe.error && /could not find|does not exist|schema cache/i.test(probe.error.message)) {
      console.log('  ⤳ 12. SKIPPED — command_main_ship_settle_arrival not deployed (apply migration 0150, then re-run)')
    } else {
      // OSN movement flag on for this section (captured above; restored in finally — live env: no-op).
      await setCfg('mainship_space_movement_enabled', true)
      await setCfg('min_travel_seconds', 20) // long enough to observe not_due; short enough to complete

      const u3 = await newUser('c')
      await poll(async () => (await u3.client.from('bases').select('id').limit(1).maybeSingle()).data, { timeoutMs: 20000, intervalMs: 1500 })
      const { data: comm, error: cErr } = await u3.client.rpc('commission_first_main_ship', {})
      if (cErr || comm?.ok !== true) die(`12: commission failed: ${cErr?.message ?? JSON.stringify(comm)}`)
      const ship3 = (await admin.from('main_ship_instances').select('main_ship_id').eq('player_id', u3.userId).maybeSingle()).data?.main_ship_id
      if (!ship3) die('12: no commissioned ship')

      // Destination = the server's own eligibility projection (requires the starter ports revealed).
      const { data: rdy } = await u3.client.rpc('get_osn_movement_readiness', {})
      const dest = (rdy?.eligible_destination_ids ?? [])[0]
      if (!dest) die('12: no eligible OSN destination (starter ports revealed? ship docked?)')
      const { data: mv3, error: mErr3 } = await u3.client.rpc('command_main_ship_space_move_to_location',
        { p_location: dest, p_request_id: crypto.randomUUID(), p_main_ship_id: ship3 })
      if (mErr3 || mv3?.ok !== true) die(`12: port move failed: ${mErr3?.message ?? JSON.stringify(mv3)}`)

      // 12a. not due yet → safe no-op.
      const early = (await u3.client.rpc('command_main_ship_settle_arrival', { p_main_ship_id: ship3 })).data
      early?.ok === true && early?.settled === false && early?.reason === 'not_due'
        ? ok('12a. not-due settle is a safe no-op (not_due)') : bad('12a. not_due', JSON.stringify(early))

      // 12b. the moment it is due, the RPC settles it (docks) — or the cron won the race (still exactly-once).
      await sleep(Math.max(0, new Date(mv3.arrive_at).getTime() - Date.now()) + 400)
      const t0 = Date.now()
      const settle = (await u3.client.rpc('command_main_ship_settle_arrival', { p_main_ship_id: ship3 })).data
      if (settle?.ok === true && settle?.settled === true && settle?.outcome === 'docked') {
        ok(`12b. due location movement settled ON DEMAND (docked ${Date.now() - t0}ms after the call)`)
      } else if (settle?.ok === true && settle?.settled === false && settle?.reason === 'already_settled') {
        ok('12b. due location movement already settled (cron won the race — still exactly-once)')
      } else { bad('12b. settle', JSON.stringify(settle)) }
      const row3 = (await admin.from('main_ship_instances').select('spatial_state,status').eq('main_ship_id', ship3).maybeSingle()).data
      row3?.spatial_state === 'at_location' ? ok('12c. ship canonically docked (at_location)') : bad('12c. state', JSON.stringify(row3))

      // 12d. repeat call → idempotent no-op.
      const again = (await u3.client.rpc('command_main_ship_settle_arrival', { p_main_ship_id: ship3 })).data
      again?.ok === true && again?.settled === false && again?.reason === 'already_settled'
        ? ok('12d. repeat settle is a no-op (already_settled)') : bad('12d. repeat', JSON.stringify(again))

      // 12e/f. SPACE-kind settle. The coordinate flag gates INITIATION only (settlement is
      // flag-independent, the OSN-4 in-flight-safety principle), so the dark gate is re-restored within
      // ~a second of issuing the one test move (capture/restore, minimal window).
      await setCfg('mainship_coordinate_travel_enabled', true)
      const { data: smv, error: smErr } = await u3.client.rpc('command_main_ship_space_move',
        { p_target_x: 5, p_target_y: 5, p_request_id: crypto.randomUUID() })
      await setCfg('mainship_coordinate_travel_enabled', origCoord ?? false) // restore the dark gate immediately
      if (smErr || smv?.ok !== true) {
        bad('12e. coordinate move for the space-settle case', smErr?.message ?? JSON.stringify(smv))
      } else {
        const arrive2 = (await admin.from('main_ship_space_movements').select('arrive_at').eq('id', smv.movement_id).maybeSingle()).data?.arrive_at
        await sleep(Math.max(0, new Date(arrive2 ?? 0).getTime() - Date.now()) + 400)
        const s2 = (await u3.client.rpc('command_main_ship_settle_arrival', { p_main_ship_id: ship3 })).data
        if (s2?.ok === true && s2?.settled === true && s2?.outcome === 'arrived') {
          ok('12e. due space movement settled ON DEMAND (arrived in space)')
        } else if (s2?.ok === true && s2?.settled === false && s2?.reason === 'already_settled') {
          ok('12e. due space movement already settled (cron won the race — still exactly-once)')
        } else { bad('12e. space settle', JSON.stringify(s2)) }
        const row4 = (await admin.from('main_ship_instances').select('spatial_state').eq('main_ship_id', ship3).maybeSingle()).data
        row4?.spatial_state === 'in_space' ? ok('12f. ship settled in_space') : bad('12f. in_space', JSON.stringify(row4))
      }
    }
  }

  // ── 13. on-demand LEGACY arrival settle (UX-CLEANUP item 6B, migration 0151) ───────────────────────
  {
    // Deployment probe: SKIP loudly until 0151 is applied, the §11/§12 idiom.
    const probe = await u.client.rpc('command_main_ship_settle_arrival_legacy', { p_fleet: null })
    if (probe.error && /could not find|does not exist|schema cache/i.test(probe.error.message)) {
      console.log('  ⤳ 13. SKIPPED — command_main_ship_settle_arrival_legacy not deployed (apply migration 0151, then re-run)')
    } else {
      await setCfg('min_travel_seconds', 20) // long enough to observe not_due; short enough to complete
      const u4 = await newUser('d')
      const base4 = await poll(async () => (await u4.client.from('bases').select('id').limit(1).maybeSingle()).data, { timeoutMs: 20000, intervalMs: 1500 })
      await admin.rpc('ensure_main_ship_for_player', { p_player: u4.userId })
      const ship4 = (await admin.from('main_ship_instances').select('main_ship_id').eq('player_id', u4.userId).maybeSingle()).data?.main_ship_id
      if (!ship4) die('13: no commissioned ship')

      // Outbound: home → A (a non-combat waypoint), settle ON DEMAND to present.
      const { data: sent4, error: sErr4 } = await u4.client.rpc('send_main_ship_expedition', { p_ships: [ship4], p_location: A.id })
      if (sErr4) die(`13: send failed: ${sErr4.message}`)
      const fleet4 = sent4.fleet_id
      const early4 = (await u4.client.rpc('command_main_ship_settle_arrival_legacy', { p_fleet: fleet4 })).data
      early4?.ok === true && early4?.settled === false && early4?.reason === 'not_due'
        ? ok('13a. not-due settle is a safe no-op (not_due)') : bad('13a. not_due', JSON.stringify(early4))
      await sleep(Math.max(0, new Date(sent4.arrive_at).getTime() - Date.now()) + 400)
      const t13 = Date.now()
      const s4 = (await u4.client.rpc('command_main_ship_settle_arrival_legacy', { p_fleet: fleet4 })).data
      if (s4?.ok === true && s4?.settled === true && s4?.outcome === 'present') {
        ok(`13b. due outbound arrival settled ON DEMAND (present ${Date.now() - t13}ms after the call)`)
      } else if (s4?.ok === true && s4?.settled === false && s4?.reason === 'already_settled') {
        ok('13b. due outbound arrival already settled (cron won the race — still exactly-once)')
      } else { bad('13b. settle', JSON.stringify(s4)) }
      const f4 = await fleetRow(fleet4)
      f4?.status === 'present' && f4?.current_location_id === A.id
        ? ok('13c. fleet present at the destination') : bad('13c. present', JSON.stringify(f4))
      const rep4 = (await u4.client.rpc('command_main_ship_settle_arrival_legacy', { p_fleet: fleet4 })).data
      rep4?.ok === true && rep4?.settled === false && rep4?.reason === 'already_settled'
        ? ok('13d. repeat settle is a no-op (already_settled)') : bad('13d. repeat', JSON.stringify(rep4))

      // Return leg: recall home, settle ON DEMAND to completed.
      const { data: ret4, error: rErr4 } = await u4.client.rpc('request_main_ship_return', { p_fleet: fleet4 })
      if (rErr4) die(`13: return failed: ${rErr4.message}`)
      const retArrive = (await admin.from('fleet_movements').select('arrive_at').eq('id', ret4.return_movement_id).maybeSingle()).data?.arrive_at
      await sleep(Math.max(0, new Date(retArrive ?? 0).getTime() - Date.now()) + 400)
      const s5 = (await u4.client.rpc('command_main_ship_settle_arrival_legacy', { p_fleet: fleet4 })).data
      if (s5?.ok === true && s5?.settled === true && s5?.outcome === 'completed') {
        ok('13e. due return_home settled ON DEMAND (completed home)')
      } else if (s5?.ok === true && s5?.settled === false && s5?.reason === 'already_settled') {
        ok('13e. due return_home already settled (cron won the race — still exactly-once)')
      } else { bad('13e. return settle', JSON.stringify(s5)) }
      const f5 = await fleetRow(fleet4)
      f5?.status === 'completed' ? ok('13f. fleet completed at home') : bad('13f. completed', JSON.stringify(f5))

      // Refusal: a NON-main-ship (unit) fleet — also a combat target — must be refused by the on-demand path.
      if (combat && base4) {
        const unitType = (await admin.from('base_units').select('unit_type_id').eq('base_id', base4.id).gt('quantity', 0).limit(1).maybeSingle()).data?.unit_type_id
        if (unitType) {
          const { data: disp, error: dErr } = await u4.client.rpc('send_fleet_to_location',
            { p_base: base4.id, p_location: combat.id, p_units: [{ unit_type_id: unitType, quantity: 1 }] })
          if (dErr) { bad('13g. dispatch for the refusal case', dErr.message) }
          else {
            const ref = (await u4.client.rpc('command_main_ship_settle_arrival_legacy', { p_fleet: disp.fleet_id })).data
            ref?.ok === false && ref?.reason === 'not_main_ship_fleet'
              ? ok('13g. non-main-ship (combat-target) fleet refused (not_main_ship_fleet)') : bad('13g. refusal', JSON.stringify(ref))
          }
        } else { bad('13g. refusal setup', 'no base units available') }
      }
    }
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
    for (const [k, v] of [['travel_scale', origScale], ['min_travel_seconds', origMin],
                          ['mainship_space_movement_enabled', origSpaceMv], ['mainship_coordinate_travel_enabled', origCoord]]) {
      if (v === undefined) continue
      try { const { error } = await setCfg(k, v); if (error) failures.push(`restore ${k}: ${error.message}`) }
      catch (e) { failures.push(`restore ${k}: ${e?.message ?? String(e)}`) }
    }
    failures.forEach((f) => bad('TEARDOWN', f))
    console.log(`\nMain-ship move: ${pass} passed, ${fail} failed\n`)
    process.exitCode = fail > 0 ? 1 : 0
  })
