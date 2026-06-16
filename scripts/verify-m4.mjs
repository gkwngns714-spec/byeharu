// M4 integration verification — server-authoritative pirate combat.
// Drives the loop against the live DB as a throwaway authenticated user, and
// confirms internal functions are NOT client-callable (anti-cheat lockdown).
//
//   node scripts/verify-m4.mjs
//
// Polls the 2s combat cron and 30s movement cron, so it takes a couple of minutes.

import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'

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
const supabase = createClient(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_ANON_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
})

let pass = 0, fail = 0
const ok = (n) => { console.log('  ✓', n); pass++ }
const bad = (n, d) => { console.log('  ✗', n, d ? `— ${d}` : ''); fail++ }
class Abort extends Error {}
const die = (m) => { throw new Abort(m) }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
async function poll(fn, { timeoutMs = 90000, intervalMs = 3000 } = {}) {
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    const v = await fn()
    if (v) return v
    await sleep(intervalMs)
  }
  return null
}
const ZERO = '00000000-0000-0000-0000-000000000000'

async function encounterFor(fleetId) {
  const { data } = await supabase
    .from('combat_encounters').select('*').eq('fleet_id', fleetId)
    .order('created_at', { ascending: false }).limit(1).maybeSingle()
  return data
}

async function main() {
  console.log(`\nM4 verification against ${env.VITE_SUPABASE_URL}\n`)

  const { data: su, error: suErr } = await supabase.auth.signUp({
    email: `m4test.${Date.now()}@example.com`, password: 'Test123456!',
  })
  if (suErr) die(`signup failed: ${suErr.message}`)
  if (!su.session) die('no session — email confirmation still ON')
  ok('signed up throwaway user')

  // ── Anti-cheat lockdown: internal functions must be denied to the client ──
  console.log('\nAnti-cheat: internal functions must be client-denied:')
  for (const [fn, args] of [
    ['base_reserve_units', { p_base: ZERO, p_units: [] }],
    ['fleet_set_present', { p_fleet: ZERO, p_sector: null, p_zone: null, p_location: null }],
    ['process_combat_ticks', {}],
    ['base_add_resources', { p_base: ZERO, p_rewards: {} }],
  ]) {
    const { error } = await supabase.rpc(fn, args)
    const denied = error && /permission denied|not find|does not exist|PGRST/i.test(error.message + (error.code ?? ''))
    denied ? ok(`${fn} denied`) : bad(`${fn} denied`, error ? error.message : 'EXECUTED — hole!')
  }

  const { data: base } = await supabase.from('bases').select('*').limit(1).maybeSingle()
  if (!base) die('no base')

  const { data: world } = await supabase.rpc('get_world_map')
  const hunts = world.sectors.flatMap((s) => s.zones).flatMap((z) => z.locations)
    .filter((l) => l.location_type === 'pirate_hunt')
  if (hunts.length === 0) die('no pirate_hunt locations')
  const easy = hunts.slice().sort((a, b) => a.base_difficulty - b.base_difficulty)[0]
  const hard = hunts.slice().sort((a, b) => b.base_difficulty - a.base_difficulty)[0]

  // ── SUCCESS PATH: strong fleet hunts, clears waves, retreats, gets reward ──
  console.log(`\nCombat (success) at "${easy.name}" (difficulty ${easy.base_difficulty}):`)
  const { data: d1, error: d1e } = await supabase.rpc('send_fleet_to_location', {
    p_base: base.id, p_location: easy.id,
    p_units: [{ unit_type_id: 'scout', quantity: 50 }, { unit_type_id: 'corvette', quantity: 10 }, { unit_type_id: 'frigate', quantity: 5 }],
  })
  if (d1e) die(`dispatch failed: ${d1e.message}`)
  ok('fleet dispatched to pirate hunt')
  const fleetA = d1.fleet_id

  console.log('  … waiting for arrival + combat to start (movement cron ~30s)')
  let encA = await poll(async () => {
    const { data: f } = await supabase.from('fleets').select('status').eq('id', fleetA).single()
    if (f?.status !== 'present') return null
    const e = await encounterFor(fleetA)
    return e && e.status === 'active' ? e : null
  }, { timeoutMs: 100000 })
  if (!encA) die('combat encounter never became active')
  ok('arrival → combat_encounter active (activity hooked from presence)')

  console.log('  … letting combat ticks run (2s cron)')
  const progressed = await poll(async () => {
    encA = await encounterFor(fleetA)
    const { count: ticks } = await supabase.from('combat_ticks').select('*', { count: 'exact', head: true }).eq('encounter_id', encA.id)
    const { count: events } = await supabase.from('combat_events').select('*', { count: 'exact', head: true }).eq('encounter_id', encA.id)
    return encA.waves_cleared >= 2 && (ticks ?? 0) >= 2 && (events ?? 0) > 0 ? { ticks, events } : null
  }, { timeoutMs: 40000, intervalMs: 2000 })
  if (!progressed) die('combat did not progress (ticks/waves/events)')
  ok(`combat advancing: ${encA.waves_cleared} waves, danger ${encA.danger_level}, ${progressed.ticks} ticks, ${progressed.events} events`)

  const { data: r1 } = await supabase.rpc('request_retreat', { p_presence: encA.presence_id })
  ok(`retreat requested (return_movement_id ${r1?.return_movement_id ?? 'pending'})`)

  console.log('  … waiting for retreat delay (~20s) then escape')
  const escaped = await poll(async () => {
    const e = await encounterFor(fleetA)
    return e && e.status === 'escaped' ? e : null
  }, { timeoutMs: 45000, intervalMs: 2000 })
  if (!escaped) die('encounter never reached escaped')
  ok('combat ended: escaped')
  const { data: fA } = await supabase.from('fleets').select('status').eq('id', fleetA).single()
  fA?.status === 'returning' ? ok('fleet returning home') : bad('fleet returning', `status=${fA?.status}`)
  const { data: retMv } = await supabase.from('fleet_movements').select('*').eq('fleet_id', fleetA).eq('mission_type', 'return_home').maybeSingle()
  retMv ? ok('return movement created (reuses M3 movement)') : bad('return movement', 'missing')

  const { data: grants } = await supabase.from('reward_grants').select('*').eq('source_id', escaped.id)
  ;(grants ?? []).length === 1 ? ok('reward granted exactly once (idempotent ledger)') : bad('reward_grants', `count=${(grants ?? []).length}`)
  const { data: metal } = await supabase.from('base_resources').select('amount').eq('base_id', base.id).eq('resource_code', 'metal').single()
  ;(metal?.amount ?? 0) > 0 ? ok(`metal reward landed in base (${metal.amount})`) : bad('metal reward', `amount=${metal?.amount}`)

  // ── DEFEAT PATH: tiny fleet vs high difficulty → wiped, no reward, no return ──
  console.log(`\nCombat (defeat) at "${hard.name}" (difficulty ${hard.base_difficulty}):`)
  const { data: d2, error: d2e } = await supabase.rpc('send_fleet_to_location', {
    p_base: base.id, p_location: hard.id, p_units: [{ unit_type_id: 'scout', quantity: 1 }],
  })
  if (d2e) die(`defeat dispatch failed: ${d2e.message}`)
  const fleetB = d2.fleet_id
  ok('tiny fleet dispatched')

  console.log('  … waiting for arrival + defeat')
  const defeated = await poll(async () => {
    const e = await encounterFor(fleetB)
    return e && e.status === 'defeat' ? e : null
  }, { timeoutMs: 110000, intervalMs: 3000 })
  if (!defeated) die('encounter never reached defeat')
  ok('combat ended: defeat')
  const { data: fB } = await supabase.from('fleets').select('status').eq('id', fleetB).single()
  fB?.status === 'destroyed' ? ok('fleet destroyed') : bad('fleet destroyed', `status=${fB?.status}`)
  const { data: rep } = await supabase.from('combat_reports').select('result').eq('encounter_id', defeated.id).maybeSingle()
  rep?.result === 'defeat' ? ok('defeat report created') : bad('defeat report', `result=${rep?.result}`)
  const { data: noRet } = await supabase.from('fleet_movements').select('id').eq('fleet_id', fleetB).eq('mission_type', 'return_home')
  ;(noRet ?? []).length === 0 ? ok('no return movement on defeat') : bad('no return on defeat', `found ${(noRet ?? []).length}`)
  const { data: noGrant } = await supabase.from('reward_grants').select('id').eq('source_id', defeated.id)
  ;(noGrant ?? []).length === 0 ? ok('no reward on defeat') : bad('no reward on defeat', `found ${(noGrant ?? []).length}`)
}

try {
  await main()
} catch (e) {
  if (e instanceof Abort) bad('ABORTED', e.message)
  else bad('UNEXPECTED', e?.message ?? String(e))
}
console.log(`\n${fail === 0 ? '✅ ALL PASSED' : '❌ FAILURES'}: ${pass} passed, ${fail} failed\n`)
process.exitCode = fail === 0 ? 0 : 1
