// M4.5 integration verification — SERIAL ship training + cancellation. Supersedes
// the parallel-model verify-m7.  node scripts/verify-m45.mjs
//
// Needs the SERVICE-ROLE key (seed metal, backdate timestamps, drive the locked
// process_build_queue). Anon key drives throwaway players (train/cancel RPCs).
// Regression (M2/M3/M4/M5) runs at the end unless M45_SKIP_REGRESS=1.

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
if (!serviceKey) { console.error('M4.5 verify needs SUPABASE_SERVICE_ROLE_KEY (server-side).'); process.exit(2) }

const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })

let pass = 0, fail = 0
const ok = (n) => { console.log('  ✓', n); pass++ }
const bad = (n, d) => { console.log('  ✗', n, d ? `— ${d}` : ''); fail++ }
class Abort extends Error {}
const die = (m) => { throw new Abort(m) }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
async function poll(fn, { timeoutMs = 40000, intervalMs = 2000 } = {}) {
  const start = Date.now()
  while (Date.now() - start < timeoutMs) { const v = await fn(); if (v) return v; await sleep(intervalMs) }
  return null
}

const setMetal = async (b, a) => admin.from('base_resources').update({ amount: a }).eq('base_id', b).eq('resource_code', 'metal')
const getMetal = async (b) => (await admin.from('base_resources').select('amount').eq('base_id', b).eq('resource_code', 'metal').maybeSingle()).data?.amount ?? 0
const getShips = async (b, u) => (await admin.from('base_units').select('quantity').eq('base_id', b).eq('unit_type_id', u).maybeSingle()).data?.quantity ?? 0
const getOrder = async (id) => (await admin.from('build_orders').select('*').eq('id', id).maybeSingle()).data
const ordersFor = async (pid) => ((await admin.from('build_orders').select('*').eq('player_id', pid).order('queued_at', { ascending: true })).data ?? [])

async function newUser(tag) {
  const c = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: su, error } = await c.auth.signUp({ email: `m45test.${tag}.${Date.now()}@example.com`, password: 'Test123456!' })
  if (error) die(`signup failed: ${error.message}`)
  if (!su.session) die('no session — email confirmation still ON')
  const { data: base } = await c.from('bases').select('*').limit(1).maybeSingle()
  if (!base) die('no base for throwaway user')
  return { client: c, base, userId: su.user.id }
}
const train = (cl, base, unit, qty = 1) => cl.rpc('train_units', { p_base: base, p_unit_type: unit, p_quantity: qty })
const cancel = (cl, id) => cl.rpc('cancel_build_order', { p_order: id })

async function main() {
  console.log(`\nM4.5 verification against ${url}\n`)
  const u = await newUser('a')
  const me = u.client
  const base = u.base.id
  await setMetal(base, 5000)
  ok('signed up throwaway user + base, seeded metal')

  // insufficient metal
  await setMetal(base, 10)
  ;(await train(me, base, 'scout', 1)).error ? ok('insufficient metal rejected') : bad('insufficient metal', 'accepted')
  await setMetal(base, 5000)

  // ── Test 1: queue is serial (1 active, rest waiting, waiting has no complete_at) ─
  console.log('\n1. Serial queue:')
  const s = (await train(me, base, 'scout', 1)).data
  const c = (await train(me, base, 'corvette', 1)).data
  const f = (await train(me, base, 'frigate', 1)).data
  let rows = await ordersFor(u.userId)
  const actives = rows.filter((o) => o.status === 'active')
  const waits = rows.filter((o) => o.status === 'waiting')
  actives.length === 1 && actives[0].id === s ? ok('only the first item (scout) is active') : bad('one active', `${actives.length} active`)
  actives[0]?.complete_at && actives[0]?.started_at ? ok('active item has started_at + complete_at') : bad('active timestamps', 'missing')
  waits.length === 2 && waits.every((o) => o.complete_at == null) ? ok('waiting items have NO complete_at (do not tick)') : bad('waiting no timestamp', JSON.stringify(waits.map((w) => w.complete_at)))

  // ── Test 2: completion starts the next item ─────────────────────────────────
  console.log('\n2. Completion starts next:')
  const scoutBefore = await getShips(base, 'scout')
  await admin.from('build_orders').update({
    queued_at: new Date(Date.now() - 300000).toISOString(),
    started_at: new Date(Date.now() - 200000).toISOString(),
    complete_at: new Date(Date.now() - 60000).toISOString(),
  }).eq('id', s)
  await admin.rpc('process_build_queue')
  const done = await poll(async () => { const o = await getOrder(s); return o?.status === 'completed' ? o : null })
  done ? ok('first item completed') : bad('first completed', 'still not completed')
  ;(await getShips(base, 'scout')) === scoutBefore + 1 ? ok('completed item produced ships (+1 scout)') : bad('ships added', 'no +1')
  const cOrd = await getOrder(c)
  cOrd.status === 'active' && cOrd.started_at && cOrd.complete_at ? ok('next item (corvette) became active with started_at + complete_at') : bad('next active', cOrd.status)
  ;(await getOrder(f)).status === 'waiting' ? ok('third item (frigate) still waiting') : bad('third waiting', 'not waiting')

  // ── Test 3: cancel waiting item (100% refund) ───────────────────────────────
  console.log('\n3. Cancel waiting item:')
  const mBefore = await getMetal(base)
  ;(await cancel(me, f)).error ? bad('cancel waiting', 'rejected') : ok('waiting item cancelled')
  ;(await getOrder(f)).status === 'cancelled' ? ok('cancelled status set (never completes)') : bad('cancelled status', 'not cancelled')
  ;(await getMetal(base)) === mBefore + 400 ? ok('100% metal refunded for waiting cancel (+400)') : bad('waiting refund', `${mBefore} → ${await getMetal(base)}`)

  // ── Test 4: cancel active item → next waiting starts (50% refund) ────────────
  console.log('\n4. Cancel active item:')
  const s2 = (await train(me, base, 'scout', 1)).data  // waiting behind active corvette
  ;(await getOrder(s2)).status === 'waiting' ? ok('new order queued as waiting (active slot busy)') : bad('serial enqueue', 'not waiting')
  const corvBefore = await getShips(base, 'corvette')
  const m2 = await getMetal(base)
  ;(await cancel(me, c)).error ? bad('cancel active', 'rejected') : ok('active item (corvette) cancelled')
  ;(await getShips(base, 'corvette')) === corvBefore ? ok('cancelled active produced NO ships') : bad('no ships from cancel', 'corvettes added')
  ;(await getOrder(s2)).status === 'active' ? ok('next waiting (scout) promoted to active') : bad('next starts', (await getOrder(s2)).status)
  ;(await getMetal(base)) === m2 + 75 ? ok('50% metal refunded for active cancel (+75 of 150)') : bad('active refund', `${m2} → ${await getMetal(base)}`)

  // ── Test 5: cannot cancel a completed item ──────────────────────────────────
  console.log('\n5. Cannot cancel completed:')
  const m3 = await getMetal(base)
  ;(await cancel(me, s)).error ? ok('cancelling a completed order is rejected') : bad('cancel completed', 'accepted')
  ;(await getOrder(s)).status === 'completed' && (await getMetal(base)) === m3 ? ok('completed order unchanged, no refund') : bad('completed integrity', 'changed')

  // ── Test 6: ownership protection ────────────────────────────────────────────
  console.log('\n6. Ownership protection:')
  const u2 = await newUser('b')
  ;(await cancel(u2.client, s2)).error ? ok('user B cannot cancel user A\'s order') : bad('ownership', 'cross-user cancel allowed!')

  // invalid unit / quantity + anti-cheat
  ;(await train(me, base, 'battleship', 1)).error ? ok('invalid unit rejected') : bad('invalid unit', 'accepted')
  ;(await train(me, base, 'scout', 0)).error ? ok('invalid quantity rejected') : bad('invalid qty', 'accepted')
  const ZERO = '00000000-0000-0000-0000-000000000000'
  for (const [fn, args] of [['process_build_queue', {}], ['base_spend_resources', { p_base: ZERO, p_resource: 'metal', p_amount: 1 }], ['production_start_next', { p_player: ZERO }]]) {
    ;(await me.rpc(fn, args)).error ? ok(`${fn} denied to client`) : bad(`${fn} denied`, 'EXECUTED — hole!')
  }
  ;(await me.from('build_orders').insert({ player_id: u.userId, base_id: base, unit_type_id: 'scout', quantity: 1 })).error
    ? ok('client cannot insert build_orders') : bad('build_orders write', 'allowed!')

  // ── Test 9: regression (verify-m5 chains m2/m3/m4) ──────────────────────────
  console.log('\n9. Regression (M2/M3/M4/M5):')
  if (env.M45_SKIP_REGRESS === '1') console.log('  · skipped (M45_SKIP_REGRESS=1)')
  else { try { execSync('node scripts/verify-m5.mjs', { stdio: 'inherit' }); ok('verify:m5 (chains m2/m3/m4) passed') } catch { bad('regression', 'verify:m5 non-zero exit') } }
}

main()
  .catch((e) => { if (e instanceof Abort) bad('ABORTED', e.message); else bad('UNEXPECTED', e?.message ?? String(e)) })
  .finally(() => { console.log(`\nM4.5: ${pass} passed, ${fail} failed\n`); process.exitCode = fail > 0 ? 1 : 0 })
