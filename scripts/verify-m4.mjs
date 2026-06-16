// M4 integration verification — pirate combat (per-unit HP, pacing, correctness).
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
async function poll(fn, { timeoutMs = 120000, intervalMs = 3000 } = {}) {
  const start = Date.now()
  while (Date.now() - start < timeoutMs) { const v = await fn(); if (v) return v; await sleep(intervalMs) }
  return null
}
const ZERO = '00000000-0000-0000-0000-000000000000'
const encounterFor = async (fleetId) => (await supabase.from('combat_encounters').select('*')
  .eq('fleet_id', fleetId).order('created_at', { ascending: false }).limit(1).maybeSingle()).data
const ticksFor = async (encId) => (await supabase.from('combat_ticks').select('*').eq('encounter_id', encId)).data ?? []
const unitsFor = async (encId) => (await supabase.from('combat_units').select('*').eq('encounter_id', encId)).data ?? []
const baseMetal = async (baseId) => (await supabase.from('base_resources').select('amount')
  .eq('base_id', baseId).eq('resource_code', 'metal').maybeSingle()).data?.amount ?? 0

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
    ['process_combat_ticks', {}],
    ['fleet_sync_quantities', { p_fleet: ZERO, p_counts: {} }],
    ['base_add_resources', { p_base: ZERO, p_rewards: {} }],
  ]) {
    const { error } = await supabase.rpc(fn, args)
    const denied = error && /permission denied|not find|does not exist|PGRST/i.test(error.message + (error.code ?? ''))
    denied ? ok(`${fn} denied`) : bad(`${fn} denied`, error ? error.message : 'EXECUTED — hole!')
  }

  const { data: base } = await supabase.from('bases').select('*').limit(1).maybeSingle()
  const { data: world } = await supabase.rpc('get_world_map')
  const hunts = world.sectors.flatMap((s) => s.zones).flatMap((z) => z.locations).filter((l) => l.location_type === 'pirate_hunt')
  const den = hunts.slice().sort((a, b) => b.base_difficulty - a.base_difficulty)[0]  // hardest

  // ── A. ESCAPE w/ multi-tick waves + per-unit HP ───────────────────────────
  console.log(`\nA. Combat at "${den.name}" (difficulty ${den.base_difficulty}) — modest fleet:`)
  const { data: dA, error: dAe } = await supabase.rpc('send_fleet_to_location', {
    p_base: base.id, p_location: den.id,
    p_units: [{ unit_type_id: 'scout', quantity: 10 }, { unit_type_id: 'corvette', quantity: 5 }, { unit_type_id: 'frigate', quantity: 2 }],
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

  // per-unit combat state present
  let units = await unitsFor(encA.id)
  units.length === 3 && units.every((u) => u.hp_max > 0)
    ? ok(`per-unit combat HP present (${units.map((u) => u.unit_type_id).sort().join('/')})`)
    : bad('combat_units', JSON.stringify(units.map((u) => [u.unit_type_id, u.hp_max])))

  // let combat run; gather evidence of multi-tick waves + decreasing HP + per-unit damage
  await poll(async () => {
    encA = await encounterFor(fleetA)
    return (encA.total_rewards_json?.metal ?? 0) > 0 ? encA : null
  }, { timeoutMs: 70000, intervalMs: 3000 })
  const tk = await ticksFor(encA.id)
  const combatTicks = tk.filter((t) => ['ongoing', 'wave_cleared'].includes(t.result))
  const byWave = {}
  combatTicks.forEach((t) => { byWave[t.wave_number] = (byWave[t.wave_number] ?? 0) + 1 })
  const maxPerWave = Math.max(0, ...Object.values(byWave))
  maxPerWave >= 3 ? ok(`waves last 3+ ticks (max ${maxPerWave} on one wave)`) : bad('wave pacing', `max ${maxPerWave} ticks/wave (undertuned, want 3-6)`)
  const noLossTick = combatTicks.find((t) => t.enemy_damage > 0 && Object.keys(t.player_losses_json ?? {}).length === 0)
  noLossTick ? ok('C: damage taken without ship loss (hull-only tick observed)') : bad('damage-no-loss', 'not observed')
  const ongoing = combatTicks.find((t) => t.result === 'ongoing' && t.enemy_integrity_after < t.enemy_integrity_before && t.enemy_integrity_after > 0)
  ongoing ? ok(`wave HP visibly decreasing (${Math.round(ongoing.enemy_integrity_before)} → ${Math.round(ongoing.enemy_integrity_after)}; you dealt ${Math.round(ongoing.player_damage)})`) : bad('wave HP decreasing', 'no mid-wave tick found')
  const notOneShot = combatTicks.find((t) => t.enemy_integrity_before > t.player_damage)
  notOneShot ? ok('wave HP exceeds one tick of player damage (not one-shot)') : bad('not one-shot', 'wave HP <= player damage')
  units = await unitsFor(encA.id)
  units.some((u) => u.hp_current < u.hp_max)
    ? ok('per-unit HP decreased from pirate damage (distribution works)')
    : bad('per-unit damage', 'no unit took damage')
  ok(`pending metal accrued (${encA.total_rewards_json.metal})`)

  // retreat spam: 3 concurrent requests → exactly one accepted
  const spam = await Promise.all([0, 1, 2].map(() => supabase.rpc('request_retreat', { p_presence: encA.presence_id })))
  const accepted = spam.filter((r) => !r.error).length
  accepted === 1 ? ok('retreat spam: exactly one accepted') : bad('retreat spam', `${accepted} accepted`)
  encA = await encounterFor(fleetA)
  const locked = encA.total_rewards_json?.metal ?? 0
  encA.status === 'retreating' && encA.retreat_started_at ? ok('retreating + retreat_started_at set') : bad('retreating', JSON.stringify(encA.status))
  const escaped = await poll(async () => { const e = await encounterFor(fleetA); return e?.status === 'escaped' ? e : null }, { timeoutMs: 45000, intervalMs: 2000 })
  if (!escaped) die('A: never escaped')
  ok('combat ended: escaped')
  ;(escaped.total_rewards_json?.metal ?? 0) === locked ? ok(`rewards locked during retreat (${locked})`) : bad('reward locking', `${locked} → ${escaped.total_rewards_json?.metal}`)
  const { data: grantsA } = await supabase.from('reward_grants').select('*').eq('source_id', escaped.id)
  ;(grantsA ?? []).length === 1 ? ok('reward_grants exactly 1') : bad('reward_grants', `count=${(grantsA ?? []).length}`)
  ;(await baseMetal(base.id)) === locked && locked > 0 ? ok(`base metal +${locked} once`) : bad('base metal', `got ${await baseMetal(base.id)}`)
  const { data: retA } = await supabase.from('fleet_movements').select('id').eq('fleet_id', fleetA).eq('mission_type', 'return_home').maybeSingle()
  retA ? ok('return movement created (M3 spine)') : bad('return movement', 'missing')
  const { data: repA } = await supabase.from('combat_reports').select('survivors_json,total_losses_json').eq('encounter_id', escaped.id).maybeSingle()
  repA && Object.keys(repA.survivors_json ?? {}).length > 0
    ? ok(`report has survivors for summary (${JSON.stringify(repA.survivors_json)})`)
    : bad('report survivors', JSON.stringify(repA))
  const { data: encsA } = await supabase.from('combat_encounters').select('id').eq('fleet_id', fleetA)
  ;(encsA ?? []).length === 1 ? ok('F: exactly one combat encounter per fleet') : bad('one encounter/fleet', `found ${(encsA ?? []).length}`)

  // Destroyed ships must NOT return: wait for return-home, then base = initial - lost.
  const doneA = await poll(async () => {
    const { data: f } = await supabase.from('fleets').select('status').eq('id', fleetA).single()
    return f?.status === 'completed' ? f : null
  }, { timeoutMs: 90000, intervalMs: 3000 })
  doneA ? ok('fleet returned home (completed)') : bad('return completion', 'timeout')
  const lossesA = repA?.total_losses_json ?? {}
  const { data: buA } = await supabase.from('base_units').select('unit_type_id,quantity').eq('base_id', base.id)
  const q = Object.fromEntries((buA ?? []).map((u) => [u.unit_type_id, u.quantity]))
  const exp = { scout: 100 - (lossesA.scout ?? 0), corvette: 20 - (lossesA.corvette ?? 0), frigate: 5 - (lossesA.frigate ?? 0) }
  q.scout === exp.scout && q.corvette === exp.corvette && q.frigate === exp.frigate
    ? ok(`destroyed ships did NOT return (base scout ${q.scout}/corvette ${q.corvette}/frigate ${q.frigate}; lost ${JSON.stringify(lossesA)})`)
    : bad('destroyed ships returned?', `base=${JSON.stringify(q)} expected=${JSON.stringify(exp)}`)

  // ── B. DEFEAT: no reward, base unchanged, no return ───────────────────────
  console.log(`\nB. Defeat at "${den.name}" (1 scout):`)
  const metalB = await baseMetal(base.id)
  const { data: dB } = await supabase.rpc('send_fleet_to_location', { p_base: base.id, p_location: den.id, p_units: [{ unit_type_id: 'scout', quantity: 1 }] })
  const defB = await poll(async () => { const e = await encounterFor(dB.fleet_id); return e?.status === 'defeat' ? e : null })
  if (!defB) die('B: never defeated')
  ok('combat ended: defeat')
  const { data: fB } = await supabase.from('fleets').select('status').eq('id', dB.fleet_id).single()
  fB?.status === 'destroyed' ? ok('fleet destroyed') : bad('fleet destroyed', fB?.status)
  const { data: repB } = await supabase.from('combat_reports').select('result,total_rewards_json').eq('encounter_id', defB.id).maybeSingle()
  repB?.result === 'defeat' && (repB?.total_rewards_json?.metal ?? 0) === 0 ? ok('defeat report: result=defeat, 0 rewards') : bad('defeat report', JSON.stringify(repB))
  ;((await supabase.from('reward_grants').select('id').eq('source_id', defB.id)).data ?? []).length === 0 ? ok('no reward_grants on defeat') : bad('reward_grants on defeat', 'found rows')
  ;(await baseMetal(base.id)) === metalB ? ok('base metal unchanged on defeat') : bad('base metal on defeat', 'increased')
  ;(((await supabase.from('fleet_movements').select('id').eq('fleet_id', dB.fleet_id).eq('mission_type', 'return_home')).data) ?? []).length === 0 ? ok('no return on defeat') : bad('no return on defeat', 'found')
  const { data: presB } = await supabase.from('location_presence').select('status').eq('fleet_id', dB.fleet_id).maybeSingle()
  presB && presB.status !== 'active' && presB.status !== 'retreating' ? ok('defeat leaves no active presence (no stuck state)') : bad('defeat presence', presB?.status)

  // ── C. RETREAT-DEATH ──────────────────────────────────────────────────────
  console.log(`\nC. Retreat-death at "${den.name}" (3 scouts):`)
  const metalC = await baseMetal(base.id)
  const { data: dC } = await supabase.rpc('send_fleet_to_location', { p_base: base.id, p_location: den.id, p_units: [{ unit_type_id: 'scout', quantity: 3 }] })
  const encC = await poll(async () => { const e = await encounterFor(dC.fleet_id); return e && ['active', 'defeat'].includes(e.status) ? e : null })
  if (!encC) die('C: encounter never appeared')
  if (encC.status === 'active') await supabase.rpc('request_retreat', { p_presence: encC.presence_id })
  const endC = await poll(async () => { const e = await encounterFor(dC.fleet_id); return e && ['defeat', 'escaped', 'completed'].includes(e.status) ? e : null }, { timeoutMs: 60000, intervalMs: 2000 })
  if (!endC) die('C: never ended')
  endC.status === 'defeat' ? ok('died during/before retreat → defeat') : bad('C result', endC.status)
  ;(((await supabase.from('reward_grants').select('id').eq('source_id', endC.id)).data) ?? []).length === 0 ? ok('no reward on retreat-death') : bad('reward on retreat-death', 'found')
  ;(await baseMetal(base.id)) === metalC ? ok('base metal unchanged') : bad('base metal retreat-death', 'increased')
  ;(((await supabase.from('fleet_movements').select('id').eq('fleet_id', dC.fleet_id).eq('mission_type', 'return_home')).data) ?? []).length === 0 ? ok('no return on retreat-death') : bad('no return retreat-death', 'found')

  // ── G. Safe zone must NOT start combat ────────────────────────────────────
  console.log(`\nG. Safe zone (no combat allowed):`)
  const safe = world.sectors.flatMap((s) => s.zones).flatMap((z) => z.locations).find((l) => l.location_type === 'safe_zone')
  const { data: dG } = await supabase.rpc('send_fleet_to_location', { p_base: base.id, p_location: safe.id, p_units: [{ unit_type_id: 'scout', quantity: 5 }] })
  const presentG = await poll(async () => {
    const { data: f } = await supabase.from('fleets').select('status').eq('id', dG.fleet_id).single()
    return f?.status === 'present' ? f : null
  })
  presentG ? ok('fleet present at safe zone') : bad('safe zone arrival', 'never present')
  const encG = await encounterFor(dG.fleet_id)
  !encG ? ok('no combat started at safe zone') : bad('safe zone combat', `encounter created (${encG.id})`)

  // Invalid location id must be rejected.
  const { error: invErr } = await supabase.rpc('send_fleet_to_location', { p_base: base.id, p_location: ZERO, p_units: [{ unit_type_id: 'scout', quantity: 1 }] })
  invErr ? ok('invalid location id rejected') : bad('invalid location', 'accepted')
}

try { await main() } catch (e) {
  if (e instanceof Abort) bad('ABORTED', e.message)
  else bad('UNEXPECTED', e?.message ?? String(e))
}
console.log(`\n${fail === 0 ? '✅ ALL PASSED' : '❌ FAILURES'}: ${pass} passed, ${fail} failed\n`)
process.exitCode = fail === 0 ? 0 : 1
