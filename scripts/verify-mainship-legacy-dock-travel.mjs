// Verification — MAINSHIP LEGACY SPATIAL-STATE FIX end-to-end (migrations 0152 + 0153).
//   node scripts/verify-mainship-legacy-dock-travel.mjs
//
// Proves THE exact live scenario that was failing: a canonically DOCKED ship (status='stationary',
// spatial_state='at_location' — the commission_first_main_ship starting state) departs via the LEGACY
// path, travels, and arrives docked again, with the 0055 lifecycle CHECK constraints never violated:
//   • docked → move_main_ship_to_location accepted (pre-0152 this raised ss_at_location_status) and the
//     ship drops to the legacy in-flight representation (traveling / spatial_state NULL / coords NULL —
//     mainship_mark_legacy_in_flight)
//   • arrival at a DOCKABLE port re-docks the SHIP to the canonical pair (0153's shared
//     mainship_mark_docked_at_location, gated on mainship_space_location_target_legal)
//   • arrival at a NON-dockable active 'none' safe-zone settles to coherent legacy_present
//     (spatial_state stays NULL; nothing writes the ship)
//   • request_main_ship_return from a DOCKED ship accepted (the second pre-0152 live bug) → returning /
//     spatial_state NULL → settles home
//   • the six 0055 lifecycle constraints still EXIST and ENFORCE (behavioral probes — see §7 note below)
//
// CONSTRAINT-NEVER-VIOLATED PROOF: every RPC returning WITHOUT error across steps 3–6 IS the proof — a
// write violating any 0055 lifecycle CHECK raises inside the RPC and fails it (that raise WAS the live
// bug), so "no error + asserted end state" means no violating write ever executed.
//
// §7 NOTE (behavioral, not pg_constraint metadata): PostgREST exposes no pg_catalog path and this repo
// deliberately ships no introspection RPC, so the "constraints not weakened" guard is BEHAVIORAL — each
// probe attempts one illegal direct write (service-role, bypassing RLS but never CHECKs) and asserts
// Postgres REJECTS it naming the specific constraint. Rejection-with-name proves the constraint exists
// AND still enforces — strictly stronger than a metadata presence check. The fix corrected the WRITERS
// (0152/0153); the constraints themselves are untouched and these probes pin that.
//
// Needs SUPABASE_SERVICE_ROLE_KEY. Captures mainship_send_enabled + travel_scale + min_travel_seconds
// up-front and restores them in finally (teardownVerifier restores the flag; NO OSN flag is toggled —
// commission_first_main_ship is ungated and every RPC exercised here rides mainship_send_enabled only).
// Deployment probes (§11–§13 idiom of verify-mainship-move.mjs): SKIPS loudly if the 0152/0153 helpers
// or commissioning (starter ports revealed) are not present on the target DB.

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
const shipRow = async (id) => (await admin.from('main_ship_instances').select('status,spatial_state,space_x,space_y').eq('main_ship_id', id).maybeSingle()).data
const ZERO = '00000000-0000-0000-0000-000000000000'
const NOT_DEPLOYED = /could not find|does not exist|schema cache/i

// The canonical docked pair / legacy in-flight shapes (assert helpers keep the checks in ONE place).
const isDocked = (s) => s?.status === 'stationary' && s?.spatial_state === 'at_location' && s?.space_x === null && s?.space_y === null
const isLegacyInFlight = (s, st) => s?.status === st && s?.spatial_state === null && s?.space_x === null && s?.space_y === null

// One illegal direct write → must be REJECTED naming the given constraint (see §7 NOTE).
async function expectRejected(label, shipId, patch, constraint) {
  const { error } = await admin.from('main_ship_instances').update(patch).eq('main_ship_id', shipId)
  error && error.message.includes(constraint)
    ? ok(`${label} rejected by ${constraint}`)
    : bad(label, error ? `wrong error: ${error.message}` : 'ACCEPTED — constraint missing or weakened')
}

// Settle a due legacy arrival: on-demand RPC when deployed (0151), cron poll as the backstop either way.
async function settleLegacy(client, fleetId, arriveAt, wantStatus) {
  await sleep(Math.max(0, new Date(arriveAt ?? 0).getTime() - Date.now()) + 400)
  const { error } = await client.rpc('command_main_ship_settle_arrival_legacy', { p_fleet: fleetId })
  if (error && !NOT_DEPLOYED.test(error.message)) die(`legacy settle failed: ${error.message}`)
  return poll(async () => { const f = await fleetRow(fleetId); return f?.status === wantStatus ? f : null })
}

let origScale, origMin, origSend, flagTouched = false
const createdUserIds = []

async function main() {
  console.log(`\nMain-ship legacy dock→travel→dock verification against ${url}\n`)

  origScale = await cfgVal('travel_scale')
  origMin   = await cfgVal('min_travel_seconds')
  origSend  = await cfgVal('mainship_send_enabled')   // capture original BEFORE any flag write
  await setCfg('travel_scale', 0.001)
  await setCfg('min_travel_seconds', 2)
  await setCfg('mainship_send_enabled', true); flagTouched = true

  // ── Deployment probes (the verify-mainship-move §11–§13 idiom): both fix halves must be present. ────
  // The helpers are service_role-only; probing them with the ZERO uuid updates zero rows (safe no-op).
  {
    const p152 = await admin.rpc('mainship_mark_legacy_in_flight', { p_main_ship_id: ZERO, p_status: 'traveling' })
    if (p152.error && NOT_DEPLOYED.test(p152.error.message)) {
      console.log('  ⤳ SKIPPED — mainship_mark_legacy_in_flight not deployed (apply migration 0152, then re-run)'); return
    }
    const p153 = await admin.rpc('mainship_mark_docked_at_location', { p_main_ship_id: ZERO })
    if (p153.error && NOT_DEPLOYED.test(p153.error.message)) {
      console.log('  ⤳ SKIPPED — mainship_mark_docked_at_location not deployed (apply migration 0153, then re-run)'); return
    }
  }

  // ── 1. Commission into the CANONICAL docked state (the live bug's exact starting point) ─────────────
  const u = await newUser('a')
  await poll(async () => (await u.client.from('bases').select('id').limit(1).maybeSingle()).data, { timeoutMs: 20000, intervalMs: 1500 })
  const { data: comm, error: cErr } = await u.client.rpc('commission_first_main_ship', {})
  if (cErr && NOT_DEPLOYED.test(cErr.message)) {
    console.log('  ⤳ SKIPPED — commission_first_main_ship not deployed (apply migration 0072+, then re-run)'); return
  }
  if (cErr) die(`commission failed: ${cErr.message}`)
  if (comm?.ok !== true) {
    // commission_unavailable ⇒ the port-entry world isn't provisioned here (starter ports not revealed).
    console.log(`  ⤳ SKIPPED — commissioning unavailable (${comm?.reason ?? 'unknown'}; starter ports revealed?)`); return
  }
  const shipId = (await admin.from('main_ship_instances').select('main_ship_id').eq('player_id', u.userId).maybeSingle()).data?.main_ship_id
  if (!shipId) die('no commissioned ship row')
  isDocked(await shipRow(shipId))
    ? ok('1. commissioned ship is canonically DOCKED (stationary / at_location / coords NULL)')
    : bad('1. docked start', JSON.stringify(await shipRow(shipId)))
  const fleet = (await admin.from('fleets').select('id,current_location_id').eq('main_ship_id', shipId).eq('status', 'present').maybeSingle()).data
  if (!fleet) die('no present fleet for the commissioned ship')
  const fleetId = fleet.id, dockId = fleet.current_location_id

  // ── 7 (probes a–b at the DOCKED state). Illegal writes must be REJECTED by name. Each probe is run
  // from a ship state where EXACTLY ONE lifecycle constraint is violated, so the rejection error names
  // that constraint deterministically (a docked ship's spatial_state→in_transit/home/destroyed would
  // violate stationary_spatial_state TOO — ambiguous which fires — so those three probe from the
  // in-flight/returning states below instead; in_space carries coords 1,1 to satisfy 0054 space_coords
  // and isolate the lifecycle rule).
  await expectRejected('7a. bare status→traveling on a docked ship (THE pre-0152 live write)', shipId,
    { status: 'traveling' }, 'main_ship_instances_ss_at_location_status')
  await expectRejected('7b. stationary with spatial_state→NULL', shipId,
    { spatial_state: null }, 'main_ship_instances_stationary_spatial_state')
  isDocked(await shipRow(shipId)) ? ok('7·. probes left the docked state untouched') : bad('7·. probe side-effect', 'state changed')

  // ── 2. Destinations: dockable port D (target_legal ok) + non-dockable safe-zone N (ok:false) ────────
  const { data: world } = await u.client.rpc('get_world_map')
  const candidates = world.sectors.flatMap((s) => s.zones).flatMap((z) => z.locations)
    .filter((l) => l.activity_type === 'none' && l.id !== dockId)
  let D = null, N = null
  for (const c of candidates) {
    const { data: legal, error } = await admin.rpc('mainship_space_location_target_legal', { p_location_id: c.id })
    if (error) die(`target_legal probe failed: ${error.message}`)
    if (legal?.ok === true && !D) D = c
    if (legal?.ok !== true && !N) N = c
    if (D && N) break
  }
  if (!D) die('no DOCKABLE active \'none\' destination distinct from the current dock (starter ports revealed?)')
  if (!N) die('no NON-dockable active \'none\' destination (expected e.g. Safe Rally Point / Quiet Drift)')
  ok(`2. destinations picked — dockable D=${D.name}, non-dockable N=${N.name}`)

  // ── 3. THE REGRESSION GUARD: docked ship departs via the legacy path ────────────────────────────────
  const { data: mv, error: mErr } = await u.client.rpc('move_main_ship_to_location', { p_fleet: fleetId, p_location: D.id })
  mErr ? bad('3. docked→D move accepted (pre-0152: ss_at_location_status violation)', mErr.message)
       : ok('3. docked→D move accepted with NO error (the reported live bug is fixed)')
  if (mErr) die('regression guard failed — aborting the round trip')
  isLegacyInFlight(await shipRow(shipId), 'traveling')
    ? ok('3a. ship dropped to legacy in-flight (traveling / spatial_state NULL / coords NULL)')
    : bad('3a. legacy in-flight', JSON.stringify(await shipRow(shipId)))
  // Probes c–e from the legacy in-flight (traveling / ss NULL) state — the only state where each write
  // violates exactly its one target constraint (see the §7 placement note above). NOTE: in_transit is NOT
  // probed here — traveling+in_transit is the LEGAL OSN pair (the write would succeed); it probes from
  // the 'returning' state in §6 instead.
  await expectRejected('7c. spatial_state→home while traveling', shipId,
    { spatial_state: 'home' }, 'main_ship_instances_ss_home_status')
  await expectRejected('7d. spatial_state→destroyed while traveling', shipId,
    { spatial_state: 'destroyed' }, 'main_ship_instances_ss_destroyed_status')
  await expectRejected('7e. spatial_state→in_space (with coords) while traveling', shipId,
    { spatial_state: 'in_space', space_x: 1, space_y: 1 }, 'main_ship_instances_ss_in_space_status')

  // ── 4. Arrive at D: fleet present + presence active + SHIP RE-DOCKED (the 0153 half) ────────────────
  const atD = await settleLegacy(u.client, fleetId, mv.arrive_at, 'present')
  atD && atD.current_location_id === D.id ? ok(`4. fleet present at D (${D.name})`) : bad('4. present at D', JSON.stringify(atD))
  ;((await admin.from('location_presence').select('id').eq('fleet_id', fleetId).eq('location_id', D.id).eq('status', 'active').maybeSingle()).data)
    ? ok('4a. active presence at D') : bad('4a. presence D', 'no active presence')
  isDocked(await shipRow(shipId))
    ? ok('4b. SHIP re-docked canonically (stationary / at_location / coords NULL) — docked→send→travel→arrive→docked closed')
    : bad('4b. re-docked', JSON.stringify(await shipRow(shipId)))

  // ── 5. Non-dock fallback: D → N settles to coherent legacy_present (no ship write) ──────────────────
  const { data: mvN, error: nErr } = await u.client.rpc('move_main_ship_to_location', { p_fleet: fleetId, p_location: N.id })
  if (nErr) die(`move D→N failed: ${nErr.message}`)
  const atN = await settleLegacy(u.client, fleetId, mvN.arrive_at, 'present')
  atN && atN.current_location_id === N.id ? ok(`5. fleet present at N (${N.name})`) : bad('5. present at N', JSON.stringify(atN))
  {
    const s = await shipRow(shipId)
    s?.spatial_state === null && s?.space_x === null && s?.space_y === null
      ? ok('5a. non-dockable arrival stays legacy (spatial_state NULL — coherent legacy_present, no violation)')
      : bad('5a. legacy_present', JSON.stringify(s))
  }

  // ── 6. SECOND live bug guard: return from a DOCKED ship ─────────────────────────────────────────────
  // Re-dock at D first so the return departs the exact at_location state the second live bug fired from.
  const { data: mvB, error: bErr } = await u.client.rpc('move_main_ship_to_location', { p_fleet: fleetId, p_location: D.id })
  if (bErr) die(`move N→D failed: ${bErr.message}`)
  await settleLegacy(u.client, fleetId, mvB.arrive_at, 'present')
  if (!isDocked(await shipRow(shipId))) die('6: could not re-establish the docked state for the return guard')
  const { data: ret, error: rErr } = await u.client.rpc('request_main_ship_return', { p_fleet: fleetId })
  rErr ? bad('6. return from a DOCKED ship accepted (pre-0152: ss_at_location_status violation)', rErr.message)
       : ok('6. return from a DOCKED ship accepted with NO error (second live bug fixed)')
  if (rErr) die('return regression guard failed')
  isLegacyInFlight(await shipRow(shipId), 'returning')
    ? ok('6a. ship → returning / spatial_state NULL (legacy in-flight)')
    : bad('6a. returning state', JSON.stringify(await shipRow(shipId)))
  // Final §7 probe, from the 'returning' state (in_transit requires status='traveling', so ONLY the
  // in_transit lifecycle rule is violated here — from 'traveling' this write would be legal).
  await expectRejected('7f. spatial_state→in_transit while returning', shipId,
    { spatial_state: 'in_transit' }, 'main_ship_instances_ss_in_transit_status')
  const retArrive = (await admin.from('fleet_movements').select('arrive_at').eq('id', ret.return_movement_id).maybeSingle()).data?.arrive_at
  const home = await settleLegacy(u.client, fleetId, retArrive, 'completed')
  home ? ok('6b. return settled — fleet completed at home') : bad('6b. settle home', 'fleet never completed')
}

async function newUser(tag) {
  const c = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: su, error } = await c.auth.signUp({ email: `msdocktest.${tag}.${Date.now()}@example.com`, password: 'Test123456!' })
  if (error) die(`signup failed: ${error.message}`)
  if (!su.session) die('no session — email confirmation still ON')
  const userId = su.user.id
  createdUserIds.push(userId)   // track immediately after creation for finally cleanup
  return { client: c, userId }
}

main()
  .catch((e) => { if (e instanceof Abort) bad('ABORTED', e.message); else bad('UNEXPECTED', e?.message ?? String(e)) })
  .finally(async () => {
    // Teardown: delete verifier-created users (cascade) and restore the CAPTURED original send flag —
    // never a hardcoded value (the shared teardownVerifier owns user deletion + flag restore).
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
    console.log(`\nMain-ship legacy dock→travel→dock: ${pass} passed, ${fail} failed\n`)
    process.exitCode = fail > 0 ? 1 : 0
  })
