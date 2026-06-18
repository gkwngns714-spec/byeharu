// M5 integration verification — Living World (pressure / danger / world-state tick).
//   node scripts/verify-m5.mjs
//
// Needs a SERVICE-ROLE key to drive the locked worldstate_tick() / dev helper on
// demand (clients are denied by design). Put it in .env.local as one of:
//   SUPABASE_SERVICE_ROLE_KEY=...   (or SUPABASE_SERVICE_KEY / SUPABASE_SECRET_KEY)
// The anon key is still used for a throwaway player (send fleet / retreat).
//
// Regression suite (M2/M3/M4) runs at the end unless M5_SKIP_REGRESS=1.

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

if (!url || !anonKey) {
  console.error('Missing VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY in .env.local')
  process.exit(2)
}
if (!serviceKey) {
  console.error(`
M5 verification needs a service-role key to invoke the locked worldstate_tick()
and dev helper (browser clients are denied by design — that is the anti-cheat law).

Add to .env.local (Supabase dashboard → Project Settings → API → service_role key):
  SUPABASE_SERVICE_ROLE_KEY=sb_secret_...

This key is server-side only and is never shipped to the frontend.`)
  process.exit(2)
}

const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
const user = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })

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

const lsFor = async (loc) => (await admin.from('location_state').select('*').eq('location_id', loc).maybeSingle()).data
const tick = async () => { const { error } = await admin.rpc('worldstate_tick'); if (error) die(`worldstate_tick failed: ${error.message}`) }
const prime = async (loc, fleets, age, pressure = null) => {
  const { error } = await admin.rpc('dev_worldstate_prime', { p_location: loc, p_active_fleets: fleets, p_age_seconds: age, p_pressure: pressure })
  if (error) die(`dev_worldstate_prime failed: ${error.message}`)
}
const encounterFor = async (fleetId) => (await admin.from('combat_encounters').select('*')
  .eq('fleet_id', fleetId).order('created_at', { ascending: false }).limit(1).maybeSingle()).data
const ticksFor = async (encId) => (await admin.from('combat_ticks').select('*').eq('encounter_id', encId)).data ?? []
const isFiniteNum = (x) => typeof x === 'number' && Number.isFinite(x)
// Phase A: combat_ticks logging is off by default; this test inspects ticks, so enable
// it for the run and restore the default in finally (shared DB).
const setTickLogging = async (on) => { try { await admin.rpc('set_game_config', { p_key: 'combat_tick_logging', p_value: on }) } catch {} }

async function main() {
  console.log(`\nM5 verification against ${url}\n`)
  await setTickLogging(true)

  // Anti-cheat: the worldstate writers must be client-denied.
  console.log('Anti-cheat: world-state functions must be client-denied:')
  for (const [fn, args] of [
    ['worldstate_tick', {}],
    ['process_location_state_ticks', {}],
    ['dev_worldstate_prime', { p_location: '00000000-0000-0000-0000-000000000000', p_active_fleets: 0, p_age_seconds: 0 }],
    ['worldstate_register_presence', { p_location: '00000000-0000-0000-0000-000000000000' }],
  ]) {
    const { error } = await user.rpc(fn, args)
    const denied = error && /permission denied|not find|does not exist|PGRST/i.test(error.message + (error.code ?? ''))
    denied ? ok(`${fn} denied to client`) : bad(`${fn} denied`, error ? error.message : 'EXECUTED — hole!')
  }

  const { data: su, error: suErr } = await user.auth.signUp({ email: `m5test.${Date.now()}@example.com`, password: 'Test123456!' })
  if (suErr) die(`signup failed: ${suErr.message}`)
  if (!su.session) die('no session — email confirmation still ON')
  ok('signed up throwaway user')

  const { data: base } = await user.from('bases').select('*').limit(1).maybeSingle()
  if (!base) die('no base for throwaway user (initialize_new_player?)')
  const { data: world } = await user.rpc('get_world_map')
  const hunts = world.sectors.flatMap((s) => s.zones).flatMap((z) => z.locations).filter((l) => l.location_type === 'pirate_hunt')
  if (hunts.length < 1) die('no pirate_hunt locations seeded')
  const locDrift = hunts[0]                      // tests 2, 6, 8 (no fleet)
  const locActive = hunts[1] ?? hunts[0]         // tests 3, 4, 5 (fleet present)
  const locDanger = hunts[2] ?? hunts[0]         // test 7 (high pressure)

  // ── Test 1: world-state rows exist ──────────────────────────────────────────
  console.log('\n1. World-state rows:')
  const { count: locCount } = await admin.from('locations').select('id', { count: 'exact', head: true })
  const { count: lsCount } = await admin.from('location_state').select('location_id', { count: 'exact', head: true })
  const { count: zoneCount } = await admin.from('zones').select('id', { count: 'exact', head: true })
  const { count: zsCount } = await admin.from('zone_state').select('zone_id', { count: 'exact', head: true })
  lsCount === locCount ? ok(`location_state row per location (${lsCount}/${locCount})`) : bad('location_state rows', `${lsCount}/${locCount}`)
  zsCount === zoneCount ? ok(`zone_state row per zone (${zsCount}/${zoneCount})`) : bad('zone_state rows', `${zsCount}/${zoneCount}`)
  let allHunts = true
  for (const h of hunts) { if (!(await lsFor(h.id))) allHunts = false }
  allHunts ? ok('every pirate_hunt location has a location_state row') : bad('hunt rows', 'missing')

  // ── Test 2: pure decay toward baseline (Option A — replaces old drift-up) ────
  console.log('\n2. Pressure decays toward baseline (no fleet):')
  // (a) above baseline → decays DOWN, never overshoots below baseline
  await prime(locDrift.id, 0, 120, 90)
  const a0 = (await lsFor(locDrift.id)).pressure
  await tick()
  const a1 = (await lsFor(locDrift.id)).pressure
  a1 < a0 && a1 >= 50 ? ok(`above baseline decays down, no overshoot (${a0} → ${a1}, ≥50)`) : bad('decay above', `${a0} → ${a1}`)
  // (b) below baseline → rises UP toward baseline, never overshoots above baseline
  await prime(locDrift.id, 0, 120, 10)
  const b0 = (await lsFor(locDrift.id)).pressure
  await tick()
  const b1 = (await lsFor(locDrift.id)).pressure
  b1 > b0 && b1 <= 50 ? ok(`below baseline rises toward baseline, no overshoot (${b0} → ${b1}, ≤50)`) : bad('decay below', `${b0} → ${b1}`)
  // (c) at baseline → stays; danger_modifier exactly 1.0
  await prime(locDrift.id, 0, 120, 50)
  await tick()
  const atB = await lsFor(locDrift.id)
  atB.pressure === 50 ? ok('at baseline stays baseline (50)') : bad('baseline stay', `${atB.pressure}`)
  Number(atB.danger_modifier) === 1 ? ok('danger_modifier at baseline is exactly 1.0') : bad('baseline modifier', `${atB.danger_modifier}`)
  // (d) clamp + finite modifier
  atB.pressure >= 0 && atB.pressure <= 100 ? ok(`pressure clamped in [0,100] (${atB.pressure})`) : bad('clamp', `${atB.pressure}`)
  isFiniteNum(Number(atB.danger_modifier)) && Number(atB.danger_modifier) > 0
    ? ok('danger_modifier finite & > 0') : bad('danger_modifier', `${atB.danger_modifier}`)

  // ── Test 8: double-tick idempotency ─────────────────────────────────────────
  console.log('\n8. Double-tick idempotency:')
  await prime(locDrift.id, 0, 120, 60)
  await tick()
  const p8a = (await lsFor(locDrift.id)).pressure
  await tick()                                  // immediate second tick → should be a no-op (too recent)
  const p8b = (await lsFor(locDrift.id)).pressure
  p8b === p8a ? ok(`second immediate tick applied no extra drift (${p8a} == ${p8b})`) : bad('idempotency', `${p8a} → ${p8b}`)

  // ── Test 6: reconciliation of active_fleets ─────────────────────────────────
  console.log('\n6. Reconciliation (cache vs real presences):')
  await prime(locDrift.id, 99, 0)               // wrong cache, no real presence here
  ;(await lsFor(locDrift.id)).active_fleets === 99 ? ok('primed active_fleets=99 (mismatch)') : bad('prime', 'cache not set')
  await tick()
  const r6 = await lsFor(locDrift.id)
  r6.active_fleets === 0 ? ok('worldstate_tick reconciled active_fleets to real count (0)') : bad('reconcile', `got ${r6.active_fleets}`)

  // ── Test 3: register on presence creation ───────────────────────────────────
  console.log(`\n3. Register on arrival at "${locActive.name}":`)
  const { data: d3, error: e3 } = await user.rpc('send_fleet_to_location', {
    p_base: base.id, p_location: locActive.id,
    p_units: [{ unit_type_id: 'scout', quantity: 8 }, { unit_type_id: 'corvette', quantity: 4 }, { unit_type_id: 'frigate', quantity: 2 }],
  })
  if (e3) die(`dispatch failed: ${e3.message}`)
  const fleet = d3.fleet_id
  const arrived = await poll(async () => {
    const ls = await lsFor(locActive.id)
    return ls && ls.active_fleets >= 1 ? ls : null
  }, { timeoutMs: 90000, intervalMs: 3000 })
  arrived ? ok(`active_fleets incremented on arrival (${arrived.active_fleets})`) : bad('register', 'active_fleets never rose')

  // ── Test 4: active-fleet relief ─────────────────────────────────────────────
  console.log('\n4. Active-fleet relief:')
  await prime(locActive.id, 0, 120, 60)         // known mid pressure; age so the tick applies
  const p4a = (await lsFor(locActive.id)).pressure
  await tick()                                  // tick reconciles active_fleets to real (>=1) → relief
  const r4 = await lsFor(locActive.id)
  r4.pressure < p4a ? ok(`pressure relieved by active fleet (${p4a} → ${r4.pressure})`) : bad('relief', `${p4a} → ${r4.pressure}`)
  r4.pressure >= 0 ? ok(`pressure not below min (${r4.pressure})`) : bad('relief floor', `${r4.pressure}`)

  // ── Test 5: unregister on presence end (retreat → return) ───────────────────
  console.log('\n5. Unregister on presence end:')
  const enc = await poll(async () => { const e = await encounterFor(fleet); return e && e.status === 'active' ? e : null }, { timeoutMs: 60000, intervalMs: 2000 })
  if (!enc) die('no active encounter to retreat from')
  await user.rpc('request_retreat', { p_presence: enc.presence_id })
  const cleared = await poll(async () => {
    const ls = await lsFor(locActive.id)
    return ls && ls.active_fleets === 0 ? ls : null
  }, { timeoutMs: 90000, intervalMs: 3000 })
  cleared ? ok('active_fleets decremented to 0 after presence ended') : bad('unregister', 'active_fleets stuck')
  const neg = (await lsFor(locActive.id)).active_fleets
  neg >= 0 ? ok(`active_fleets never negative (${neg})`) : bad('floor', `${neg}`)
  // let the fleet finish returning so we stay under the active-fleet cap
  await poll(async () => { const { data: f } = await admin.from('fleets').select('status').eq('id', fleet).single(); return f?.status === 'completed' ? f : null }, { timeoutMs: 90000, intervalMs: 3000 })

  // ── Test 7: danger_modifier feeds combat safely ─────────────────────────────
  console.log(`\n7. Danger feeds combat at "${locDanger.name}" (high pressure):`)
  await prime(locDanger.id, 0, 0, 100)          // force severe pressure
  await tick()
  const r7 = await lsFor(locDanger.id)
  Number(r7.danger_modifier) >= 1.15 ? ok(`danger_modifier elevated at high pressure (${r7.danger_modifier})`) : bad('danger scaling', `${r7.danger_modifier}`)
  const { data: d7, error: e7 } = await user.rpc('send_fleet_to_location', {
    p_base: base.id, p_location: locDanger.id,
    p_units: [{ unit_type_id: 'scout', quantity: 10 }, { unit_type_id: 'corvette', quantity: 6 }, { unit_type_id: 'frigate', quantity: 3 }],
  })
  if (e7) die(`dispatch (danger) failed: ${e7.message}`)
  const enc7 = await poll(async () => { const e = await encounterFor(d7.fleet_id); return e && e.status === 'active' ? e : null }, { timeoutMs: 90000, intervalMs: 3000 })
  if (!enc7) die('high-danger encounter never active')
  const combatTicks = await poll(async () => { const t = (await ticksFor(enc7.id)).filter((x) => ['ongoing', 'wave_cleared'].includes(x.result)); return t.length > 0 ? t : null }, { timeoutMs: 60000, intervalMs: 3000 })
  if (!combatTicks) die('no combat ticks at high-danger location')
  const sane = combatTicks.every((t) => isFiniteNum(t.enemy_power) && t.enemy_power > 0 && isFiniteNum(t.enemy_damage) && t.enemy_damage >= 0 && isFiniteNum(t.player_integrity_after) && t.player_integrity_after >= 0)
  sane ? ok(`combat ran with valid scaling (no NaN / negatives; enemy_power e.g. ${Math.round(combatTicks[0].enemy_power)})`) : bad('combat sanity', JSON.stringify(combatTicks[0]))
  ok('combat read danger_modifier without crashing')
  // clean up: retreat the danger fleet (best effort)
  await user.rpc('request_retreat', { p_presence: enc7.presence_id })

  // ── Test 9: regression suite ────────────────────────────────────────────────
  console.log('\n9. Regression suite (M2/M3/M4):')
  if (env.M5_SKIP_REGRESS === '1') {
    console.log('  · skipped (M5_SKIP_REGRESS=1) — run: npm run verify:m2 / verify:m3 / verify:m4')
  } else {
    for (const m of ['m2', 'm3', 'm4']) {
      try {
        execSync(`node scripts/verify-${m}.mjs`, { stdio: 'inherit' })
        ok(`verify:${m} passed`)
      } catch {
        bad(`verify:${m}`, 'non-zero exit (see output above)')
      }
    }
  }
}

main()
  .catch((e) => { if (e instanceof Abort) bad('ABORTED', e.message); else bad('UNEXPECTED', e?.message ?? String(e)) })
  .finally(async () => {
    await setTickLogging(false)  // Phase A: restore production default (logging off)
    console.log(`\nM5: ${pass} passed, ${fail} failed\n`)
    process.exitCode = fail > 0 ? 1 : 0
  })
