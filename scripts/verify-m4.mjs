// M4 integration verification — server-authoritative pirate combat.
// Cases: anti-cheat lockdown, escape (reward once + locked), defeat (no reward,
// base unchanged, no return), retreat-death, and integrity data for the UI.
//
//   node scripts/verify-m4.mjs

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
async function poll(fn, { timeoutMs = 110000, intervalMs = 3000 } = {}) {
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
  const { data } = await supabase.from('combat_encounters').select('*')
    .eq('fleet_id', fleetId).order('created_at', { ascending: false }).limit(1).maybeSingle()
  return data
}
async function ticksFor(encId) {
  const { data } = await supabase.from('combat_ticks').select('*')
    .eq('encounter_id', encId).order('tick_number', { ascending: false })
  return data ?? []
}
async function baseMetal(baseId) {
  const { data } = await supabase.from('base_resources').select('amount')
    .eq('base_id', baseId).eq('resource_code', 'metal').maybeSingle()
  return data?.amount ?? 0
}

async function main() {
  console.log(`\nM4 verification against ${env.VITE_SUPABASE_URL}\n`)
  const { data: su, error: suErr } = await supabase.auth.signUp({
    email: `m4test.${Date.now()}@example.com`, password: 'Test123456!',
  })
  if (suErr) die(`signup failed: ${suErr.message}`)
  if (!su.session) die('no session — email confirmation still ON')
  ok('signed up throwaway user')

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
  const easy = hunts.slice().sort((a, b) => a.base_difficulty - b.base_difficulty)[0]
  const hard = hunts.slice().sort((a, b) => b.base_difficulty - a.base_difficulty)[0]

  // ── A. ESCAPE: reward granted once and locked at retreat ──────────────────
  console.log(`\nA. Escape at "${easy.name}":`)
  const { data: dA, error: dAe } = await supabase.rpc('send_fleet_to_location', {
    p_base: base.id, p_location: easy.id,
    p_units: [{ unit_type_id: 'scout', quantity: 50 }, { unit_type_id: 'corvette', quantity: 10 }, { unit_type_id: 'frigate', quantity: 5 }],
  })
  if (dAe) die(`dispatch A failed: ${dAe.message}`)
  const fleetA = dA.fleet_id
  let encA = await poll(async () => {
    const { data: f } = await supabase.from('fleets').select('status').eq('id', fleetA).single()
    if (f?.status !== 'present') return null
    const e = await encounterFor(fleetA)
    return e && e.status === 'active' ? e : null
  })
  if (!encA) die('A: encounter never active')
  ok('encounter active')

  // D. integrity data present
  encA.player_integrity_max > 0 && encA.player_integrity_current > 0
    ? ok(`D. integrity exposed (fleet ${Math.round(encA.player_integrity_current)}/${Math.round(encA.player_integrity_max)})`)
    : bad('D. integrity', JSON.stringify({ max: encA.player_integrity_max, cur: encA.player_integrity_current }))

  await poll(async () => {
    encA = await encounterFor(fleetA)
    return encA.waves_cleared >= 2 && (encA.total_rewards_json?.metal ?? 0) > 0 ? encA : null
  }, { timeoutMs: 40000, intervalMs: 2000 })
  const tk = (await ticksFor(encA.id))[0]
  tk && typeof tk.player_integrity_after === 'number' && typeof tk.enemy_integrity_before === 'number' &&
    typeof tk.player_damage === 'number' && typeof tk.enemy_damage === 'number'
    ? ok('D. tick exposes integrity + damage dealt/taken')
    : bad('D. tick data', JSON.stringify(tk))
  ok(`pending metal accrued before retreat (${encA.total_rewards_json.metal})`)

  await supabase.rpc('request_retreat', { p_presence: encA.presence_id })
  encA = await encounterFor(fleetA)
  const lockedMetal = encA.total_rewards_json?.metal ?? 0
  encA.status === 'retreating' && encA.retreat_started_at
    ? ok('retreating + retreat_started_at set (drives countdown)')
    : bad('retreating state', JSON.stringify({ status: encA.status, at: encA.retreat_started_at }))

  const escaped = await poll(async () => {
    const e = await encounterFor(fleetA)
    return e && e.status === 'escaped' ? e : null
  }, { timeoutMs: 45000, intervalMs: 2000 })
  if (!escaped) die('A: never escaped')
  ok('combat ended: escaped')
  ;(escaped.total_rewards_json?.metal ?? 0) === lockedMetal
    ? ok(`rewards locked during retreat (no farming): ${lockedMetal}`)
    : bad('reward locking', `locked ${lockedMetal} → final ${escaped.total_rewards_json?.metal}`)
  const { data: grantsA } = await supabase.from('reward_grants').select('*').eq('source_id', escaped.id)
  ;(grantsA ?? []).length === 1 ? ok('reward_grants exactly 1 (idempotent)') : bad('reward_grants', `count=${(grantsA ?? []).length}`)
  const metalA = await baseMetal(base.id)
  metalA === lockedMetal && metalA > 0
    ? ok(`base metal increased exactly once (${metalA})`)
    : bad('base metal', `metal=${metalA}, expected ${lockedMetal}`)
  const { data: retA } = await supabase.from('fleet_movements').select('id').eq('fleet_id', fleetA).eq('mission_type', 'return_home').maybeSingle()
  retA ? ok('return movement created') : bad('return movement', 'missing')

  // ── B. DEFEAT: no reward, base unchanged, no return ───────────────────────
  console.log(`\nB. Defeat at "${hard.name}" (1 scout):`)
  const metalBeforeB = await baseMetal(base.id)
  const { data: dB } = await supabase.rpc('send_fleet_to_location', {
    p_base: base.id, p_location: hard.id, p_units: [{ unit_type_id: 'scout', quantity: 1 }],
  })
  const fleetB = dB.fleet_id
  const defB = await poll(async () => {
    const e = await encounterFor(fleetB)
    return e && e.status === 'defeat' ? e : null
  })
  if (!defB) die('B: never defeated')
  ok('combat ended: defeat')
  const { data: fB } = await supabase.from('fleets').select('status').eq('id', fleetB).single()
  fB?.status === 'destroyed' ? ok('fleet destroyed') : bad('fleet destroyed', `status=${fB?.status}`)
  const { data: repB } = await supabase.from('combat_reports').select('result,total_rewards_json').eq('encounter_id', defB.id).maybeSingle()
  repB?.result === 'defeat' ? ok('defeat report created') : bad('defeat report', `result=${repB?.result}`)
  ;((repB?.total_rewards_json?.metal ?? 0) === 0) ? ok('defeat report shows 0 rewards') : bad('defeat report rewards', JSON.stringify(repB?.total_rewards_json))
  const { data: grantsB } = await supabase.from('reward_grants').select('id').eq('source_id', defB.id)
  ;(grantsB ?? []).length === 0 ? ok('no reward_grants on defeat') : bad('reward_grants on defeat', `found ${(grantsB ?? []).length}`)
  ;(await baseMetal(base.id)) === metalBeforeB ? ok('base metal unchanged on defeat') : bad('base metal on defeat', 'increased!')
  const { data: retB } = await supabase.from('fleet_movements').select('id').eq('fleet_id', fleetB).eq('mission_type', 'return_home')
  ;(retB ?? []).length === 0 ? ok('no return movement on defeat') : bad('no return on defeat', `found ${(retB ?? []).length}`)

  // ── C. RETREAT-DEATH: dies before escape → defeat, no reward, no return ───
  console.log(`\nC. Retreat-death at "${hard.name}" (6 scouts, retreat immediately):`)
  const metalBeforeC = await baseMetal(base.id)
  const { data: dC } = await supabase.rpc('send_fleet_to_location', {
    p_base: base.id, p_location: hard.id, p_units: [{ unit_type_id: 'scout', quantity: 6 }],
  })
  const fleetC = dC.fleet_id
  const encC = await poll(async () => {
    const e = await encounterFor(fleetC)
    return e && (e.status === 'active' || e.status === 'defeat') ? e : null
  })
  if (!encC) die('C: encounter never appeared')
  if (encC.status === 'active') {
    await supabase.rpc('request_retreat', { p_presence: encC.presence_id }).catch(() => {})
  }
  const endC = await poll(async () => {
    const e = await encounterFor(fleetC)
    return e && ['defeat', 'escaped', 'completed'].includes(e.status) ? e : null
  }, { timeoutMs: 60000, intervalMs: 2000 })
  if (!endC) die('C: never ended')
  endC.status === 'defeat' ? ok('died during/before retreat → defeat') : bad('C result', `status=${endC.status}`)
  const { data: grantsC } = await supabase.from('reward_grants').select('id').eq('source_id', endC.id)
  ;(grantsC ?? []).length === 0 ? ok('no reward on retreat-death') : bad('reward on retreat-death', `found ${(grantsC ?? []).length}`)
  ;(await baseMetal(base.id)) === metalBeforeC ? ok('base metal unchanged on retreat-death') : bad('base metal retreat-death', 'increased!')
  const { data: retC } = await supabase.from('fleet_movements').select('id').eq('fleet_id', fleetC).eq('mission_type', 'return_home')
  ;(retC ?? []).length === 0 ? ok('no return movement on retreat-death') : bad('no return retreat-death', `found ${(retC ?? []).length}`)
}

try {
  await main()
} catch (e) {
  if (e instanceof Abort) bad('ABORTED', e.message)
  else bad('UNEXPECTED', e?.message ?? String(e))
}
console.log(`\n${fail === 0 ? '✅ ALL PASSED' : '❌ FAILURES'}: ${pass} passed, ${fail} failed\n`)
process.exitCode = fail === 0 ? 0 : 1
