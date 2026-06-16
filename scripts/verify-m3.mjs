// M3 integration verification — drives the full movement+presence spine against
// the live DB as a throwaway authenticated user (publishable/anon key only).
//
//   node scripts/verify-m3.mjs
//
// Relies on the pg_cron processor (every 30s) to resolve arrivals, so it polls.
// Exit 0 = all passed, 1 = a failure or config block (e.g. email confirmation on).

import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'

function loadEnv(path) {
  const env = {}
  try {
    for (const line of readFileSync(path, 'utf8').split('\n')) {
      const m = line.match(/^\s*([\w.]+)\s*=\s*(.*)\s*$/)
      if (m) env[m[1]] = m[2].trim().replace(/^['"]|['"]$/g, '')
    }
  } catch {}
  return env
}

const env = { ...loadEnv('.env.local'), ...process.env }
const url = env.VITE_SUPABASE_URL
const anon = env.VITE_SUPABASE_ANON_KEY
if (!url || !anon) {
  console.error('✖ Missing VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY')
  process.exitCode = 1
}

const supabase = createClient(url, anon, {
  auth: { persistSession: false, autoRefreshToken: false },
})

let pass = 0,
  fail = 0
const ok = (n) => { console.log('  ✓', n); pass++ }
const bad = (n, d) => { console.log('  ✗', n, d ? `— ${d}` : ''); fail++ }
class Abort extends Error {}
const die = (msg) => { throw new Abort(msg) }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function poll(fn, { timeoutMs = 90000, intervalMs = 4000 } = {}) {
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    const v = await fn()
    if (v) return v
    await sleep(intervalMs)
  }
  return null
}

async function main() {
  console.log(`\nM3 verification against ${url}\n`)

  // 1) Throwaway player bootstrap (signup → session)
  const email = `m3test.${Date.now()}@example.com`
  const password = 'Test123456!'
  const { data: su, error: suErr } = await supabase.auth.signUp({ email, password })
  if (suErr) die(`signup failed: ${suErr.message}`)
  if (!su.session) {
    die(
      'signup returned no session — email confirmation is ON. Turn it off ' +
        '(Supabase → Authentication → Sign In/Providers → Email → "Confirm email" off) and re-run.',
    )
  }
  ok(`1. bootstrap: signed up throwaway user ${email}`)

  await supabase.rpc('bootstrap_me') // idempotent safety net

  // 2) Base creation
  const { data: bases, error: bErr } = await supabase.from('bases').select('*')
  if (bErr) bad('2. base read', bErr.message)
  else if (bases.length === 1) ok(`2. base created (at ${bases[0].x},${bases[0].y})`)
  else bad('2. exactly one base', `got ${bases.length}`)
  const base = bases?.[0]
  if (!base) die('no base — cannot continue')

  // 3) Starting units + resources
  const { data: bUnits } = await supabase.from('base_units').select('*')
  const unitMap = Object.fromEntries((bUnits ?? []).map((u) => [u.unit_type_id, u.quantity]))
  unitMap.scout === 100 && unitMap.corvette === 20 && unitMap.frigate === 5
    ? ok('3. starting units (scout 100 / corvette 20 / frigate 5)')
    : bad('3. starting units', JSON.stringify(unitMap))
  const { data: bRes } = await supabase.from('base_resources').select('*')
  ;(bRes ?? []).length === 3
    ? ok('3. starting resources seeded (3 codes)')
    : bad('3. starting resources', `got ${(bRes ?? []).length}`)

  // 4/5/6) Dispatch a fleet to a safe_zone → creates fleet + movement
  const { data: world } = await supabase.rpc('get_world_map')
  const safe = world.sectors
    .flatMap((s) => s.zones)
    .flatMap((z) => z.locations)
    .find((l) => l.location_type === 'safe_zone')
  if (!safe) die('no safe_zone location found in world map')

  const { data: dispatch, error: dErr } = await supabase.rpc('send_fleet_to_location', {
    p_base: base.id,
    p_location: safe.id,
    p_units: [{ unit_type_id: 'scout', quantity: 10 }],
  })
  if (dErr) die(`5. send_fleet_to_location failed: ${dErr.message}`)
  ok(`4/5. fleet dispatched to "${safe.name}"`)
  const fleetId = dispatch.fleet_id

  const { data: mv } = await supabase
    .from('fleet_movements').select('*').eq('id', dispatch.movement_id).single()
  mv && mv.status === 'moving' && mv.target_location_id === safe.id && mv.travel_seconds > 0
    ? ok(`6. movement row created (moving, ${mv.travel_seconds.toFixed(1)}s, dist ${mv.travel_distance.toFixed(1)})`)
    : bad('6. movement row', JSON.stringify(mv))

  const { data: bu2 } = await supabase
    .from('base_units').select('quantity').eq('base_id', base.id).eq('unit_type_id', 'scout').single()
  bu2?.quantity === 90 ? ok('   units reserved from base (scout 100 → 90)') : bad('units reserved', `scout=${bu2?.quantity}`)

  // 7/8) Wait for processor to resolve arrival → fleet present + presence active
  console.log('  … waiting for movement processor (cron ~30s) to resolve arrival')
  const presence = await poll(async () => {
    const { data: f } = await supabase.from('fleets').select('status').eq('id', fleetId).single()
    if (f?.status !== 'present') return null
    const { data: p } = await supabase
      .from('location_presence').select('*').eq('fleet_id', fleetId).eq('status', 'active').maybeSingle()
    return p ?? null
  })
  if (!presence) die('7/8. fleet never reached present within timeout — check cron job process-fleet-movements')
  ok('7. travel completed via processor (fleet → present)')
  presence.location_id === safe.id && presence.activity_type === 'none'
    ? ok('8. presence active at destination (activity none)')
    : bad('8. presence', JSON.stringify(presence))

  // 9/10) Leave → return movement created
  const { data: leave, error: lErr } = await supabase.rpc('request_leave_location', { p_presence: presence.id })
  if (lErr) die(`9. request_leave_location failed: ${lErr.message}`)
  ok('9. leave requested')
  const { data: rmv } = await supabase
    .from('fleet_movements').select('*').eq('id', leave.return_movement_id).single()
  rmv && rmv.mission_type === 'return_home' && rmv.target_type === 'base'
    ? ok('10. return movement created (return_home → base)')
    : bad('10. return movement', JSON.stringify(rmv))

  // 11) Wait for return arrival → fleet completed + units merged back
  console.log('  … waiting for return arrival (cron ~30s)')
  const done = await poll(async () => {
    const { data: f } = await supabase.from('fleets').select('status').eq('id', fleetId).single()
    return f?.status === 'completed' ? f : null
  })
  if (!done) die('11. fleet never completed within timeout — check cron')
  ok('11. fleet returned home (status completed)')
  const { data: bu3 } = await supabase
    .from('base_units').select('quantity').eq('base_id', base.id).eq('unit_type_id', 'scout').single()
  bu3?.quantity === 100 ? ok('   survivors merged back (scout 90 → 100)') : bad('units merged back', `scout=${bu3?.quantity}`)
}

try {
  await main()
} catch (e) {
  if (e instanceof Abort) bad('ABORTED', e.message)
  else bad('UNEXPECTED', e?.message ?? String(e))
}

console.log(`\n${fail === 0 ? '✅ ALL PASSED' : '❌ FAILURES'}: ${pass} passed, ${fail} failed\n`)
process.exitCode = fail === 0 ? 0 : 1
