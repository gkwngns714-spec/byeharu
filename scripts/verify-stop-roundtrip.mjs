// Verification — STOP/MOVE FIX end-to-end: send → stop → send → stop, BOTH stop families.
//   node scripts/verify-stop-roundtrip.mjs
//
// Proves goal item (1): Stop works on EVERY in-transit leg, not just the first. This verifier proves
// the SERVER-side end-to-end contract the slice-1 client fix relies on — each stop command sent with a
// FRESH request id halts ITS OWN leg — and documents WHY the client fix was required: the server
// receipt idempotency replays a PREVIOUSLY-CONSUMED request id verbatim and must NOT settle the new
// movement (the regression probe). Slice-1's controller unit tests (spaceStopCommand/portMoveCommand/
// spaceMoveCommand specs) prove the client now emits a fresh key per leg; the two layers together
// close goal (1).
//
// Families covered (the recon STOP_UIRESTRUCTURE_RECON.local.md §D verifier spec):
//   1. OSN coordinate family (the live-reachable defect): command_main_ship_space_move_to_location →
//      command_main_ship_space_stop on main_ship_space_movements. Leg 1 stops with a fresh key
//      (outcome 'stopped', movement terminal, ship held in_space); leg 2 (a re-departure from the
//      held-in-space state) stops with a SECOND fresh key and halts the SECOND movement.
//   2. Legacy fleet family: move_main_ship_to_location → command_main_ship_stop_transit on
//      fleet_movements. Each stop HALTS the ship and HOLDS it in open space (movement row → terminal
//      'cancelled'; ship → stationary/in_space at its own coordinates; fleet → completed with
//      active_movement_id cleared). Leg 2 is a re-departure FROM the held point via
//      move_main_ship_to_location (origin_type 'space', the SAME fleet — hold/resume keeps fleet
//      identity); a duplicate stop on a held ship is an idempotent 'already_held' no-op.
//   3. REGRESSION PROBE (OSN — receipts are the OSN idempotency mechanism; the legacy stop is
//      idempotent by state and carries no key): on a fresh in-transit leg, a stop submitted with the
//      PREVIOUSLY-CONSUMED key must REPLAY the earlier receipt (the OLD movement_id in the envelope)
//      and must NOT settle the new movement — the movement stays 'moving'. That replay WAS the live
//      "second Stop no-ops" bug; a fresh key per leg (the slice-1 fix) is exactly what makes each
//      stop land.
//
// Needs SUPABASE_SERVICE_ROLE_KEY. Captures travel_scale + min_travel_seconds up-front and restores
// them in finally (shared teardownVerifier owns user cleanup; NO capability flag is toggled —
// mainship_send_enabled and mainship_space_movement_enabled are READ ONLY, and a family whose flag is
// dark on the target DB is SKIPPED loudly instead of force-enabled). §11–§13 idiom: SKIPS loudly
// (exit 2) when a required helper/capability is absent — commissioning, the target-legal probe, a
// second dockable port, or a dark family. Exit: 1 on any failed assertion; 2 if anything was skipped
// (not fully proven); 0 only when both families ran green.

import { randomUUID } from 'node:crypto'
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
let pass = 0, fail = 0, skips = 0
const ok = (n) => { console.log('  ✓', n); pass++ }
const bad = (n, d) => { console.log('  ✗', n, d ? `— ${d}` : ''); fail++ }
const skip = (n) => { console.log('  ⤳ SKIPPED —', n); skips++ }
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
const cfgOn = (v) => String(v) === 'true'
const fleetRow = async (id) => (await admin.from('fleets').select('status,current_location_id,main_ship_id,active_movement_id').eq('id', id).maybeSingle()).data
const shipRow = async (id) => (await admin.from('main_ship_instances').select('status,spatial_state,space_x,space_y').eq('main_ship_id', id).maybeSingle()).data
const legacyMvRow = async (id) => (await admin.from('fleet_movements').select('status,mission_type,target_type,origin_type,arrive_at').eq('id', id).maybeSingle()).data
const spaceMvRow = async (id) => (await admin.from('main_ship_space_movements').select('status,target_kind,terminal_reason,target_location_id').eq('id', id).maybeSingle()).data
const NOT_DEPLOYED = /could not find|does not exist|schema cache/i

// Ship-shape assert helpers (ONE place per shape, the sibling verifier's idiom).
const isDocked = (s) => s?.status === 'stationary' && s?.spatial_state === 'at_location' && s?.space_x === null && s?.space_y === null
const isLegacyInFlight = (s, st) => s?.status === st && s?.spatial_state === null && s?.space_x === null && s?.space_y === null
const isHeldInSpace = (s) => s?.status === 'stationary' && s?.spatial_state === 'in_space' && s?.space_x !== null && s?.space_y !== null
// Legacy held fleet (0155 Stop-hold shape): the movement-less terminal — completed, pointer cleared.
const isLegacyHeldFleet = (f) => f?.status === 'completed' && f?.active_movement_id === null

// The OSN public wrappers gained p_main_ship_id in 0083; older deployments carry the pre-0083 shape.
// Try each argument shape in order; a schema-cache miss on one shape falls through to the next.
async function rpcFlex(client, fn, variants) {
  let last = null
  for (const args of variants) {
    last = await client.rpc(fn, args)
    if (!(last.error && NOT_DEPLOYED.test(last.error.message))) return last
  }
  return last
}
const osnMove = (client, locationId, requestId) => rpcFlex(client, 'command_main_ship_space_move_to_location', [
  { p_location: locationId, p_request_id: requestId, p_main_ship_id: null },
  { p_location: locationId, p_request_id: requestId },
])
const osnStop = (client, requestId) => rpcFlex(client, 'command_main_ship_space_stop', [
  { p_request_id: requestId, p_main_ship_id: null },
  { p_request_id: requestId },
])

// Settle a due legacy arrival: on-demand RPC when deployed (0151), cron poll as the backstop either way.
async function settleLegacy(client, fleetId, arriveAt, wantStatus) {
  await sleep(Math.max(0, new Date(arriveAt ?? 0).getTime() - Date.now()) + 400)
  const { error } = await client.rpc('command_main_ship_settle_arrival_legacy', { p_fleet: fleetId })
  if (error && !NOT_DEPLOYED.test(error.message)) die(`legacy settle failed: ${error.message}`)
  return poll(async () => { const f = await fleetRow(fleetId); return f?.status === wantStatus ? f : null })
}

let origScale, origMin
const createdUserIds = []

async function main() {
  console.log(`\nStop round-trip (send → stop → send → stop, both families) verification against ${url}\n`)

  origScale = await cfgVal('travel_scale')
  origMin   = await cfgVal('min_travel_seconds')
  await setCfg('travel_scale', 0.001)
  await setCfg('min_travel_seconds', 20) // legs long enough that every mid-flight stop lands before arrival

  // ── Family gates: READ the capability flags; NEVER write them. A dark family is skipped loudly. ─────
  const sendEnabled  = cfgOn(await cfgVal('mainship_send_enabled'))
  const spaceEnabled = cfgOn(await cfgVal('mainship_space_movement_enabled'))
  if (!sendEnabled && !spaceEnabled) {
    skip('both stop families are dark on this DB (mainship_send_enabled AND mainship_space_movement_enabled false) — nothing to prove; flags NOT toggled')
    return
  }

  // ── Commission into the canonical docked start (the shared, ungated entry point) ────────────────────
  const u = await newUser('a')
  await poll(async () => (await u.client.from('bases').select('id').limit(1).maybeSingle()).data, { timeoutMs: 20000, intervalMs: 1500 })
  const { data: comm, error: cErr } = await u.client.rpc('commission_first_main_ship', {})
  if (cErr && NOT_DEPLOYED.test(cErr.message)) { skip('commission_first_main_ship not deployed (apply migration 0072+, then re-run)'); return }
  if (cErr) die(`commission failed: ${cErr.message}`)
  if (comm?.ok !== true) { skip(`commissioning unavailable (${comm?.reason ?? 'unknown'}; starter ports revealed?)`); return }
  const shipId = (await admin.from('main_ship_instances').select('main_ship_id').eq('player_id', u.userId).maybeSingle()).data?.main_ship_id
  if (!shipId) die('no commissioned ship row')
  const fleet0 = (await admin.from('fleets').select('id,current_location_id').eq('main_ship_id', shipId).eq('status', 'present').maybeSingle()).data
  if (!fleet0) die('no present fleet for the commissioned ship')
  const dock0 = fleet0.current_location_id
  if (!isDocked(await shipRow(shipId))) die(`commissioned ship not canonically docked: ${JSON.stringify(await shipRow(shipId))}`)
  ok('0. commissioned ship canonically DOCKED; present fleet captured')

  // Candidate targets: active non-combat locations (the legacy family accepts any; OSN needs dockables).
  const { data: world } = await u.client.rpc('get_world_map')
  const candidates = world.sectors.flatMap((s) => s.zones).flatMap((z) => z.locations)
    .filter((l) => l.activity_type === 'none' && l.status === 'active')
  const A = candidates.find((l) => l.id !== dock0)
  if (!A) die("no active 'none' destination distinct from the commissioning dock")
  let curDock = dock0 // where the ship is anchored whenever it is docked (updated by the re-dock leg)

  // ════ 1. LEGACY family: send → stop → send → stop (fleet_movements / command_main_ship_stop_transit) ═
  if (!sendEnabled) {
    skip('LEGACY family dark (mainship_send_enabled=false) — flag NOT toggled; family not proven here')
  } else {
    // Leg L1 departs the commissioned docked/present state (move_main_ship_to_location).
    const { data: mvL1, error: e1 } = await u.client.rpc('move_main_ship_to_location', { p_fleet: fleet0.id, p_location: A.id })
    if (e1) die(`legacy leg 1 send failed: ${e1.message}`)
    isLegacyInFlight(await shipRow(shipId), 'traveling')
      ? ok('L1. legacy leg 1 in flight (traveling / spatial_state NULL)')
      : bad('L1. leg 1 in-flight shape', JSON.stringify(await shipRow(shipId)))

    // Stop 1 → HALT AND HOLD (0155): no return home; the ship parks at its own coordinates. (The hold
    // envelope carries no movement_id; leg identity is proven by the specific mvL1 row going 'cancelled'.)
    const { data: st1, error: se1 } = await u.client.rpc('command_main_ship_stop_transit', { p_fleet: fleet0.id })
    if (se1) die(`legacy stop 1 failed: ${se1.message}`)
    st1?.ok === true && st1?.stopped === true && st1?.held === true && st1?.space_x != null && st1?.space_y != null
      ? ok('L2. stop 1 HELD the ship in open space (stopped:true, held:true, halt coordinates returned)')
      : bad('L2. stop 1', JSON.stringify(st1))
    ;(await legacyMvRow(mvL1.movement_id))?.status === 'cancelled'
      ? ok("L3. leg-1 movement terminal 'cancelled' (its OWN trip; NOT return_home, NOT moving — the cron never reprocesses it)")
      : bad('L3. leg-1 terminal', JSON.stringify(await legacyMvRow(mvL1.movement_id)))
    isHeldInSpace(await shipRow(shipId))
      ? ok('L4. ship HELD at its own coordinates (stationary / in_space) — not returning home')
      : bad('L4. held shape', JSON.stringify(await shipRow(shipId)))
    isLegacyHeldFleet(await fleetRow(fleet0.id))
      ? ok('L5. fleet settled to the movement-less terminal (completed / active_movement_id cleared)')
      : bad('L5. held fleet shape', JSON.stringify(await fleetRow(fleet0.id)))

    // Duplicate stop on a held ship → idempotent no-op (a stop grants nothing; the hold must not drift).
    const { data: st1dup, error: se1d } = await u.client.rpc('command_main_ship_stop_transit', { p_fleet: fleet0.id })
    if (se1d) die(`legacy duplicate stop failed: ${se1d.message}`)
    st1dup?.ok === true && st1dup?.stopped === false && st1dup?.reason === 'already_held' && isHeldInSpace(await shipRow(shipId))
      ? ok("L6. duplicate stop is an idempotent no-op ({stopped:false, reason:'already_held'}); ship still held")
      : bad('L6. already_held no-op', JSON.stringify({ st1dup, ship: await shipRow(shipId) }))

    // Leg L2 = RESUME from the held point: the SAME fleet re-departs with origin_type 'space' (0156).
    const { data: mvL2, error: e2 } = await u.client.rpc('move_main_ship_to_location', { p_fleet: fleet0.id, p_location: A.id })
    if (e2) die(`legacy leg 2 (resume from held) failed: ${e2.message}`)
    const r2moving = await legacyMvRow(mvL2.movement_id)
    mvL2.movement_id !== mvL1.movement_id && isLegacyInFlight(await shipRow(shipId), 'traveling')
      && r2moving?.origin_type === 'space' && r2moving?.status === 'moving'
      ? ok("L7. leg 2 RESUMED from the held point (same fleet, new movement, origin_type 'space', ship traveling)")
      : bad('L7. resume-from-held shape', JSON.stringify({ mvL1: mvL1.movement_id, mvL2: mvL2.movement_id, r2moving, ship: await shipRow(shipId) }))

    // Stop 2 → THE ROUND-TRIP PROOF: the resumed leg is stoppable and holds again.
    const { data: st2, error: se2 } = await u.client.rpc('command_main_ship_stop_transit', { p_fleet: fleet0.id })
    if (se2) die(`legacy stop 2 failed: ${se2.message}`)
    st2?.ok === true && st2?.stopped === true && st2?.held === true && st2?.space_x != null && st2?.space_y != null
      ? ok('L8. THE ROUND-TRIP PROOF: stop 2 HELD the resumed trip (stopped:true, held:true)')
      : bad('L8. stop 2', JSON.stringify(st2))
    ;(await legacyMvRow(mvL2.movement_id))?.status === 'cancelled'
      ? ok("L9. leg-2 movement terminal 'cancelled' — each stop owns exactly its own trip")
      : bad('L9. leg-2 terminal', JSON.stringify(await legacyMvRow(mvL2.movement_id)))
    isHeldInSpace(await shipRow(shipId))
      ? ok('L10. ship HELD in space again — every leg stoppable; send → stop(held) → send-from-held → stop(held) closed')
      : bad('L10. final held shape', JSON.stringify(await shipRow(shipId)))
  }

  // ════ 2. OSN family: send → stop → send → stop + the consumed-key regression probe ══════════════════
  if (!spaceEnabled) {
    skip('OSN family dark (mainship_space_movement_enabled=false) — flag NOT toggled; family not proven here')
    return
  }
  // Dockable targets via the same admin probe the sibling verifier uses (0067 target-legal predicate).
  const dockables = []
  for (const c of candidates) {
    const { data: legal, error } = await admin.rpc('mainship_space_location_target_legal', { p_location_id: c.id })
    if (error && NOT_DEPLOYED.test(error.message)) { skip('mainship_space_location_target_legal not deployed — OSN family not probeable here'); return }
    if (error) die(`target_legal probe failed: ${error.message}`)
    if (legal?.ok === true) dockables.push(c)
  }
  if (dockables.length === 0) { skip('no dockable port on this DB — OSN family needs one to anchor at'); return }

  // The OSN origin must be ANCHORED. If the legacy family ran, the ship ended HELD in open space (not
  // anchored) — re-establish an anchored origin by sending the HELD ship to a dockable port via the one
  // legacy path (move_main_ship_to_location departs from the held state; 0153 docks it canonically on
  // arrival). If the legacy family was skipped, the ship is still in its commissioned dock — no re-dock.
  if (sendEnabled && !isDocked(await shipRow(shipId))) {
    const D = dockables[0]
    const { data: mvD, error: eD } = await u.client.rpc('move_main_ship_to_location', { p_fleet: fleet0.id, p_location: D.id })
    if (eD) die(`re-dock send failed: ${eD.message}`)
    const atD = await settleLegacy(u.client, mvD.fleet_id, mvD.arrive_at, 'present')
    if (!atD) die('re-dock leg never settled')
    if (!isDocked(await shipRow(shipId))) die(`re-dock did not dock the ship (0153 half): ${JSON.stringify(await shipRow(shipId))}`)
    curDock = D.id
    ok(`O0. re-docked at ${D.name} (anchored OSN origin established)`)
  }
  const T = dockables.find((l) => l.id !== curDock)
  if (!T) { skip('only one dockable port and the ship is docked at it — OSN family needs a second dockable destination'); return }

  // Leg O1 + stop with a FRESH key.
  const rMove1 = randomUUID(), sStop1 = randomUUID()
  const m1res = await osnMove(u.client, T.id, rMove1)
  if (m1res.error) die(`OSN leg 1 send failed: ${m1res.error.message}`)
  if (m1res.data?.ok !== true) die(`OSN leg 1 send rejected: ${JSON.stringify(m1res.data)}`)
  const m1 = m1res.data.movement_id
  const m1row = await spaceMvRow(m1)
  m1row?.status === 'moving' && m1row?.target_kind === 'location' && (await shipRow(shipId))?.spatial_state === 'in_transit'
    ? ok(`O1. OSN leg 1 in flight toward ${T.name} (movement moving / target_kind location / ship in_transit)`)
    : bad('O1. leg 1 in-flight shape', JSON.stringify({ m1row, ship: await shipRow(shipId) }))

  const s1res = await osnStop(u.client, sStop1)
  if (s1res.error) die(`OSN stop 1 failed: ${s1res.error.message}`)
  s1res.data?.ok === true && s1res.data?.outcome === 'stopped' && s1res.data?.movement_id === m1
    ? ok('O2. stop 1 (fresh key) halted ITS OWN movement (outcome stopped, the leg-1 movement id)')
    : bad('O2. stop 1', JSON.stringify(s1res.data))
  const m1after = await spaceMvRow(m1)
  m1after?.status === 'stopped' && m1after?.terminal_reason === 'player_stop'
    ? ok("O3. leg-1 movement terminal (status 'stopped', terminal_reason 'player_stop') — no longer moving")
    : bad('O3. leg-1 terminal', JSON.stringify(m1after))
  isHeldInSpace(await shipRow(shipId))
    ? ok('O4. ship HELD in space (stationary / in_space / own coordinates) — no active coordinate transit')
    : bad('O4. held shape', JSON.stringify(await shipRow(shipId)))

  // Leg O2: THE second-leg scenario — a re-departure from the held-in-space state.
  const rMove2 = randomUUID(), sStop2 = randomUUID()
  const m2res = await osnMove(u.client, T.id, rMove2)
  if (m2res.error) die(`OSN leg 2 send failed: ${m2res.error.message}`)
  if (m2res.data?.ok !== true) die(`OSN leg 2 send rejected: ${JSON.stringify(m2res.data)}`)
  const m2 = m2res.data.movement_id
  m2 !== m1 && (await spaceMvRow(m2))?.status === 'moving' && (await shipRow(shipId))?.spatial_state === 'in_transit'
    ? ok('O5. leg 2 departed from the held point as a NEW movement (fresh id, moving, ship in_transit)')
    : bad('O5. leg 2 shape', JSON.stringify({ m2, m2row: await spaceMvRow(m2), ship: await shipRow(shipId) }))

  // ── REGRESSION PROBE (why slice 1 was required): replay the CONSUMED leg-1 stop key on leg 2. ──────
  const replay = await osnStop(u.client, sStop1)
  if (replay.error) die(`replay probe errored: ${replay.error.message}`)
  replay.data?.ok === true && replay.data?.movement_id === m1
    ? ok('O6. consumed key REPLAYED the leg-1 receipt verbatim (the OLD movement id — the pre-fix client saw this as "success")')
    : bad('O6. replay envelope', JSON.stringify(replay.data))
  ;(await spaceMvRow(m2))?.status === 'moving'
    ? ok('O7. the replay settled NOTHING — leg 2 still moving (THE live "second Stop no-ops" bug, pinned server-side)')
    : bad('O7. replay side-effect', `leg-2 movement mutated: ${JSON.stringify(await spaceMvRow(m2))}`)

  // Stop 2 with a SECOND FRESH key — the second leg must halt (the whole point of goal item 1).
  const s2res = await osnStop(u.client, sStop2)
  if (s2res.error) die(`OSN stop 2 failed: ${s2res.error.message}`)
  s2res.data?.ok === true && s2res.data?.outcome === 'stopped' && s2res.data?.movement_id === m2
    ? ok('O8. THE ROUND-TRIP PROOF: stop 2 (fresh key) halted the SECOND movement (its own movement id)')
    : bad('O8. stop 2', JSON.stringify(s2res.data))
  const m2after = await spaceMvRow(m2)
  m2after?.status === 'stopped' && m2after?.terminal_reason === 'player_stop'
    ? ok('O9. leg-2 movement terminal — the second stop landed')
    : bad('O9. leg-2 terminal', JSON.stringify(m2after))
  isHeldInSpace(await shipRow(shipId))
    ? ok('O10. ship held in space again — every leg stoppable, send → stop → send → stop closed')
    : bad('O10. final held shape', JSON.stringify(await shipRow(shipId)))
}

async function newUser(tag) {
  const c = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: su, error } = await c.auth.signUp({ email: `stoproundtrip.${tag}.${Date.now()}@example.com`, password: 'Test123456!' })
  if (error) die(`signup failed: ${error.message}`)
  if (!su.session) die('no session — email confirmation still ON')
  const userId = su.user.id
  createdUserIds.push(userId)   // track immediately after creation for finally cleanup
  return { client: c, userId }
}

main()
  .catch((e) => { if (e instanceof Abort) bad('ABORTED', e.message); else bad('UNEXPECTED', e?.message ?? String(e)) })
  .finally(async () => {
    // Teardown: delete verifier-created users (cascade). NO capability flag was touched, so none is
    // restored (flag: null); only the two pacing values are put back to their captured originals.
    const { failures } = await teardownVerifier({ admin, createdUserIds, flag: null })
    for (const [k, v] of [['travel_scale', origScale], ['min_travel_seconds', origMin]]) {
      if (v === undefined) continue
      try { const { error } = await setCfg(k, v); if (error) failures.push(`restore ${k}: ${error.message}`) }
      catch (e) { failures.push(`restore ${k}: ${e?.message ?? String(e)}`) }
    }
    failures.forEach((f) => bad('TEARDOWN', f))
    console.log(`\nStop round-trip: ${pass} passed, ${fail} failed, ${skips} skipped\n`)
    process.exitCode = fail > 0 ? 1 : skips > 0 ? 2 : 0
  })
