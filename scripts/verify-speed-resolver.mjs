// Regression test — canonical movement-speed resolver (resolve_fleet_movement_speed).
//   node scripts/verify-speed-resolver.mjs
//
// Proves:
//   1. legacy fleet speed still works UNCHANGED (resolver == slowest unit speed; movement.speed_used too)
//   2. main-ship OUTBOUND movement speed resolves from the hull (starter_frigate → 1.0)
//   3. main-ship RETURN movement speed resolves from the hull (1.0)
//   4. request_main_ship_return passes a real positive speed to movement_create (no NULL)
//   5. (see note) the invalid/missing-hull raise is a defensive guard that is STRUCTURALLY
//      unreachable via the API (base_speed NOT NULL CHECK>0, hull FK, fleet→ship FK ON DELETE
//      SET NULL). We assert the success side of that branch and report #5 honestly.
//
// Needs SUPABASE_SERVICE_ROLE_KEY (commission ship, call the resolver directly, flip the flag).
// Temporarily enables mainship_send_enabled + shrinks travel config; restores ALL of it in finally.

import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'

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
const note = (n) => console.log('  •', n)
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
const speedOf = async (fleetId) => Number((await admin.rpc('resolve_fleet_movement_speed', { p_fleet: fleetId })).data)
const movementSpeed = async (fleetId, mission) => {
  const { data } = await admin.from('fleet_movements').select('speed_used,mission_type,created_at')
    .eq('fleet_id', fleetId).eq('mission_type', mission).order('created_at', { ascending: false }).limit(1).maybeSingle()
  return data ? Number(data.speed_used) : null
}

async function newUser(tag) {
  const c = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: su, error } = await c.auth.signUp({ email: `speedrestest.${tag}.${Date.now()}@example.com`, password: 'Test123456!' })
  if (error) die(`signup failed: ${error.message}`)
  if (!su.session) die('no session — email confirmation still ON')
  return { client: c, userId: su.user.id }
}

let origScale, origMin, flagTouched = false

async function main() {
  console.log(`\nSpeed-resolver regression test against ${url}\n`)

  origScale = await cfgVal('travel_scale')
  origMin   = await cfgVal('min_travel_seconds')
  await setCfg('travel_scale', 0.001)
  await setCfg('min_travel_seconds', 2)
  await setCfg('mainship_send_enabled', true); flagTouched = true

  const u = await newUser('a')
  const base = await poll(async () => (await u.client.from('bases').select('id, status').eq('status', 'active').maybeSingle()).data, { timeoutMs: 20000, intervalMs: 1500 })
  if (!base) die('no active base for new user')
  await admin.rpc('ensure_main_ship_for_player', { p_player: u.userId })
  const shipId = (await admin.from('main_ship_instances').select('main_ship_id').eq('player_id', u.userId).maybeSingle()).data?.main_ship_id
  if (!shipId) die('main ship not commissioned')

  const { data: world } = await u.client.rpc('get_world_map')
  const safe = world.sectors.flatMap((s) => s.zones).flatMap((z) => z.locations).find((l) => l.location_type === 'safe_zone')
  if (!safe) die('no safe_zone location')

  // ── 1) Legacy fleet speed unchanged ─────────────────────────────────────────
  // scout speed 10, frigate speed 5 → slowest-unit governs → 5 (same as before the refactor).
  {
    const { data: sent, error } = await u.client.rpc('send_fleet_to_location', {
      p_base: base.id, p_location: safe.id, p_units: [{ unit_type_id: 'scout', quantity: 1 }, { unit_type_id: 'frigate', quantity: 1 }],
    })
    if (error) die(`legacy send failed: ${error.message}`)
    const resolver = await speedOf(sent.fleet_id)
    const mv = await movementSpeed(sent.fleet_id, 'rally')
    resolver === 5 && mv === 5
      ? ok(`1. legacy speed unchanged (resolver ${resolver}, movement.speed_used ${mv} = slowest unit)`)
      : bad('1. legacy speed', `resolver=${resolver}, movement=${mv} (want 5/5)`)
  }

  // ── 2) Main-ship OUTBOUND speed from hull ────────────────────────────────────
  const { data: sentMs, error: msErr } = await u.client.rpc('send_main_ship_expedition', { p_ships: [shipId], p_location: safe.id })
  if (msErr) die(`main-ship send failed: ${msErr.message}`)
  const mainFleet = sentMs.fleet_id
  {
    const resolver = await speedOf(mainFleet)
    const mv = await movementSpeed(mainFleet, 'rally')
    resolver === 1 && mv === 1
      ? ok(`2. main-ship outbound speed from hull (resolver ${resolver}, movement.speed_used ${mv} = starter_frigate 1.0)`)
      : bad('2. main outbound speed', `resolver=${resolver}, movement=${mv} (want 1/1)`)
  }

  // ── 3) Main-ship RETURN speed from hull ──────────────────────────────────────
  const present = await poll(async () => {
    const f = (await u.client.from('fleets').select('status').eq('id', mainFleet).maybeSingle()).data
    return f?.status === 'present' ? f : null
  })
  present ? ok('   (main ship reached present)') : die('3. main ship never became present')

  const { data: ret, error: rErr } = await u.client.rpc('request_main_ship_return', { p_fleet: mainFleet })
  if (rErr) die(`return failed: ${rErr.message}`)
  const retMv = await movementSpeed(mainFleet, 'return_home')
  retMv === 1
    ? ok(`3. main-ship return speed from hull (return movement.speed_used ${retMv} = 1.0)`)
    : bad('3. main return speed', `return movement speed_used=${retMv} (want 1)`)

  // ── 4) request_main_ship_return passed a real positive speed (no NULL) ────────
  ret?.return_movement_id && Number.isFinite(retMv) && retMv > 0
    ? ok('4. return movement created with a finite positive speed (no NULL reached movement_create)')
    : bad('4. no-NULL speed', `return_movement_id=${ret?.return_movement_id}, speed_used=${retMv}`)

  // ── 5) invalid/missing-hull raise: structurally unreachable via the API ───────
  // base_speed is NOT NULL CHECK (>0); main_ship_instances.hull_type_id FK → hull; fleets.main_ship_id
  // FK is ON DELETE SET NULL. So a main-ship fleet can never resolve to null/<=0 hull speed. The raise
  // is a defensive guard verified by inspection. We assert the SUCCESS side returns a valid positive.
  {
    const resolver = await speedOf(mainFleet)
    resolver > 0
      ? ok(`5. main-ship hull branch returns a valid positive speed (${resolver}); the invalid-hull raise is a guard (unreachable via API — see note)`)
      : bad('5. hull branch', `resolver=${resolver}`)
    note('5. NOTE: the invalid/missing-hull raise cannot be triggered with valid data (NOT NULL + CHECK>0 + FKs); verified by code inspection.')
  }
}

main()
  .catch((e) => { if (e instanceof Abort) bad('ABORTED', e.message); else bad('UNEXPECTED', e?.message ?? String(e)) })
  .finally(async () => {
    try { if (flagTouched) await setCfg('mainship_send_enabled', false) } catch {}
    try { if (origScale !== undefined) await setCfg('travel_scale', origScale) } catch {}
    try { if (origMin !== undefined) await setCfg('min_travel_seconds', origMin) } catch {}
    console.log(`\nSpeed resolver: ${pass} passed, ${fail} failed\n`)
    process.exitCode = fail > 0 ? 1 : 0
  })
