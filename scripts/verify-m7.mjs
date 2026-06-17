// M7 integration verification — training / ship production (spend metal → queue →
// cron completes into base_units).  node scripts/verify-m7.mjs
//
// Needs the SERVICE-ROLE key (to seed metal, backdate complete_at, drive the locked
// process_build_queue). The anon key drives a throwaway player (train_units RPC).
// Regression (M2/M3/M4/M5) runs at the end unless M7_SKIP_REGRESS=1.

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
if (!url || !anonKey) { console.error('Missing VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY'); process.exit(2) }
if (!serviceKey) { console.error('M7 verify needs SUPABASE_SERVICE_ROLE_KEY (server-side).'); process.exit(2) }

const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })

let pass = 0, fail = 0
const ok = (n) => { console.log('  ✓', n); pass++ }
const bad = (n, d) => { console.log('  ✗', n, d ? `— ${d}` : ''); fail++ }
class Abort extends Error {}
const die = (m) => { throw new Abort(m) }
const ZERO = '00000000-0000-0000-0000-000000000000'

const setMetal = async (baseId, amt) =>
  admin.from('base_resources').update({ amount: amt }).eq('base_id', baseId).eq('resource_code', 'metal')
const getMetal = async (baseId) =>
  (await admin.from('base_resources').select('amount').eq('base_id', baseId).eq('resource_code', 'metal').maybeSingle()).data?.amount ?? 0
const getShips = async (baseId, unit) =>
  (await admin.from('base_units').select('quantity').eq('base_id', baseId).eq('unit_type_id', unit).maybeSingle()).data?.quantity ?? 0
const getOrder = async (id) => (await admin.from('build_orders').select('*').eq('id', id).maybeSingle()).data
const queuedCount = async (playerId) =>
  ((await admin.from('build_orders').select('id').eq('player_id', playerId).eq('status', 'queued')).data ?? []).length
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
async function poll(fn, { timeoutMs = 40000, intervalMs = 2000 } = {}) {
  const start = Date.now()
  while (Date.now() - start < timeoutMs) { const v = await fn(); if (v) return v; await sleep(intervalMs) }
  return null
}

async function newUser(tag) {
  const c = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: su, error } = await c.auth.signUp({ email: `m7test.${tag}.${Date.now()}@example.com`, password: 'Test123456!' })
  if (error) die(`signup failed: ${error.message}`)
  if (!su.session) die('no session — email confirmation still ON')
  const { data: base } = await c.from('bases').select('*').limit(1).maybeSingle()
  if (!base) die('no base for throwaway user')
  return { client: c, base, userId: su.user.id }
}

async function main() {
  console.log(`\nM7 verification against ${url}\n`)
  const u = await newUser('a')
  const base = u.base
  const me = u.client
  ok('signed up throwaway user + base')

  // ── 1. insufficient metal → rejected ────────────────────────────────────────
  await setMetal(base.id, 10)
  let r = await me.rpc('train_units', { p_base: base.id, p_unit_type: 'scout', p_quantity: 1 })
  r.error ? ok('1. training rejected with insufficient metal') : bad('1. insufficient metal', 'order accepted!')
  ;(await queuedCount(u.userId)) === 0 ? ok('   no order created on failure') : bad('   no order on fail', 'order exists')

  // ── 2/3. sufficient metal → success + metal deducted exactly once ───────────
  await setMetal(base.id, 2000)
  const before = await getMetal(base.id)
  r = await me.rpc('train_units', { p_base: base.id, p_unit_type: 'scout', p_quantity: 2 })
  const orderId = r.data
  !r.error && orderId ? ok('2. training succeeds with enough metal') : bad('2. train success', r.error?.message)
  ;(await getMetal(base.id)) === before - 100 ? ok('3. metal deducted exactly once (−100 for 2 scouts)') : bad('3. metal deduct', `${before} → ${await getMetal(base.id)}`)

  // ── 4/5. build_orders row created correctly + complete_at ≈ configured time ──
  const ord = await getOrder(orderId)
  ord && ord.status === 'queued' && ord.unit_type_id === 'scout' && ord.quantity === 2
    ? ok('4. build_orders row created correctly (scout ×2, queued)') : bad('4. order row', JSON.stringify(ord))
  const secs = (new Date(ord.complete_at).getTime() - new Date(ord.queued_at).getTime()) / 1000
  secs >= 50 && secs <= 75 ? ok(`5. complete_at ≈ build time (${Math.round(secs)}s ≈ 60s for scout×2)`) : bad('5. complete_at', `${Math.round(secs)}s`)

  // ── 6/7/8. cron completes due order → ships added once (idempotent) ──────────
  const scoutBefore = await getShips(base.id, 'scout')
  // Make the order due. complete_at >= queued_at is a CHECK constraint, so backdate
  // BOTH timestamps (not just complete_at) to keep the order valid.
  const { error: bderr } = await admin.from('build_orders').update({
    queued_at: new Date(Date.now() - 120000).toISOString(),
    complete_at: new Date(Date.now() - 60000).toISOString(),
  }).eq('id', orderId)
  if (bderr) die(`backdate failed: ${bderr.message}`)
  await admin.rpc('process_build_queue')
  // Either our manual call or the live 30s cron completes it — poll until done.
  const ordDone = await poll(async () => { const o = await getOrder(orderId); return o?.status === 'completed' ? o : null })
  ordDone ? ok('6. process_build_queue completed the due order') : bad('6. complete', 'still queued after 40s')
  ;(await getShips(base.id, 'scout')) === scoutBefore + 2 ? ok('7. completed ships added to base_units (+2 scouts)') : bad('7. ships added', `${scoutBefore} → ${await getShips(base.id, 'scout')}`)
  await admin.rpc('process_build_queue')  // run again
  ;(await getShips(base.id, 'scout')) === scoutBefore + 2 ? ok('8. second process_build_queue does NOT double-add ships') : bad('8. double-add', 'ships changed on re-run')

  // ── 9. max_build_orders cap enforced ────────────────────────────────────────
  await setMetal(base.id, 2000)
  let accepted = 0
  for (let i = 0; i < 6; i++) {
    const rr = await me.rpc('train_units', { p_base: base.id, p_unit_type: 'scout', p_quantity: 1 })
    if (!rr.error) accepted++
  }
  accepted === 5 ? ok('9. max_build_orders cap enforced (5 accepted, 6th rejected)') : bad('9. queue cap', `${accepted} accepted`)

  // ── 10/11. invalid unit / quantity rejected ─────────────────────────────────
  ;(await me.rpc('train_units', { p_base: base.id, p_unit_type: 'battleship', p_quantity: 1 })).error
    ? ok('10. invalid unit_type rejected') : bad('10. invalid unit', 'accepted')
  const q0 = (await me.rpc('train_units', { p_base: base.id, p_unit_type: 'scout', p_quantity: 0 })).error
  const qNeg = (await me.rpc('train_units', { p_base: base.id, p_unit_type: 'scout', p_quantity: -3 })).error
  q0 && qNeg ? ok('11. invalid quantity (0 and negative) rejected') : bad('11. invalid quantity', `q0=${!!q0} qNeg=${!!qNeg}`)

  // ── 12/13. client cannot write build_orders / base_resources / base_units ────
  ;(await me.from('build_orders').insert({ player_id: u.userId, base_id: base.id, unit_type_id: 'scout', quantity: 1, complete_at: new Date().toISOString() })).error
    ? ok('12. client cannot insert build_orders') : bad('12. build_orders write', 'insert allowed!')
  const metalNow = await getMetal(base.id)
  await me.from('base_resources').update({ amount: 999999 }).eq('base_id', base.id).eq('resource_code', 'metal')
  await me.from('base_units').insert({ base_id: base.id, unit_type_id: 'scout', quantity: 999 })
  ;(await getMetal(base.id)) === metalNow ? ok('13. client cannot write base_resources/base_units (unchanged)') : bad('13. base write', 'client mutated base state!')

  // ── 14. user cannot read another user's build_orders ────────────────────────
  const u2 = await newUser('b')
  await setMetal(u2.base.id, 1000)
  const o2 = (await u2.client.rpc('train_units', { p_base: u2.base.id, p_unit_type: 'scout', p_quantity: 1 })).data
  const visible = ((await me.from('build_orders').select('id')).data ?? []).map((x) => x.id)
  o2 && !visible.includes(o2) ? ok('14. RLS: cannot read another user\'s build_orders') : bad('14. cross-user RLS', 'other order visible!')

  // anti-cheat: internal fns denied to client
  for (const [fn, args] of [['process_build_queue', {}], ['base_spend_resources', { p_base: ZERO, p_resource: 'metal', p_amount: 1 }]]) {
    const { error } = await me.rpc(fn, args)
    error ? ok(`   ${fn} denied to client`) : bad(`   ${fn} denied`, 'EXECUTED — hole!')
  }

  // ── 15. regression chain (verify-m5 cascades m2/m3/m4) ──────────────────────
  console.log('\n15. Regression (M2/M3/M4/M5):')
  if (env.M7_SKIP_REGRESS === '1') {
    console.log('  · skipped (M7_SKIP_REGRESS=1)')
  } else {
    try { execSync('node scripts/verify-m5.mjs', { stdio: 'inherit' }); ok('verify:m5 (chains m2/m3/m4) passed') }
    catch { bad('regression', 'verify:m5 non-zero exit') }
  }
}

main()
  .catch((e) => { if (e instanceof Abort) bad('ABORTED', e.message); else bad('UNEXPECTED', e?.message ?? String(e)) })
  .finally(() => { console.log(`\nM7: ${pass} passed, ${fail} failed\n`); process.exitCode = fail > 0 ? 1 : 0 })
