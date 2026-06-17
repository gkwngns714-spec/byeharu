// Phase 3 verification — generic inventory foundation.  node scripts/verify-inventory.mjs
//
// Service-role drives the locked inventory_* fns; anon clients verify RLS + that clients
// cannot mutate. Regression (M4.5 → M5 → M2/M3/M4) runs unless INVENTORY_SKIP_REGRESS=1.

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
if (!serviceKey) { console.error('inventory verify needs SUPABASE_SERVICE_ROLE_KEY (server-side).'); process.exit(2) }

const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })

let pass = 0, fail = 0
const ok = (n) => { console.log('  ✓', n); pass++ }
const bad = (n, d) => { console.log('  ✗', n, d ? `— ${d}` : ''); fail++ }
class Abort extends Error {}
const die = (m) => { throw new Abort(m) }
const ZERO = '00000000-0000-0000-0000-000000000000'

const SEEDED = ['scrap', 'ore', 'crystal', 'pirate_alloy', 'weapon_parts', 'engine_parts', 'repair_parts',
  'captain_memory_shard', 'blueprint_fragment', 'artifact_core']

const deposit = (player, item, qty, key) => admin.rpc('inventory_deposit', { p_player: player, p_item: item, p_qty: qty, p_key: key ?? null })
const spend = (player, item, qty) => admin.rpc('inventory_spend', { p_player: player, p_item: item, p_qty: qty })
const balance = async (player, item) => (await admin.rpc('inventory_get_balance', { p_player: player, p_item: item })).data ?? 0

async function newUser(tag) {
  const c = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: su, error } = await c.auth.signUp({ email: `invtest.${tag}.${Date.now()}@example.com`, password: 'Test123456!' })
  if (error) die(`signup failed: ${error.message}`)
  if (!su.session) die('no session — email confirmation still ON')
  return { client: c, userId: su.user.id }
}

async function main() {
  console.log(`\nInventory (Phase 3) verification against ${url}\n`)
  const u1 = await newUser('a')
  const u2 = await newUser('b')
  ok('signed up two throwaway users')

  // 1. item_types seeded
  const { data: items } = await admin.from('item_types').select('item_id')
  const ids = (items ?? []).map((r) => r.item_id)
  SEEDED.every((s) => ids.includes(s)) ? ok(`1. item_types seeded (${SEEDED.length} starter items present)`) : bad('1. seed', `missing ${SEEDED.filter((s) => !ids.includes(s))}`)

  // 5. deposit adds (do this first so there's data to read)
  await deposit(u1.userId, 'scrap', 5)
  await deposit(u1.userId, 'scrap', 3)
  ;(await balance(u1.userId, 'scrap')) === 8 ? ok('5. deposit adds quantity (5 + 3 = 8)') : bad('5. deposit', `${await balance(u1.userId, 'scrap')}`)

  // 2. owner reads own inventory
  const ownRows = (await u1.client.from('player_inventory').select('item_id, quantity')).data ?? []
  ownRows.find((r) => r.item_id === 'scrap')?.quantity === 8 ? ok('2. owner can read own inventory') : bad('2. owner read', JSON.stringify(ownRows))

  // 3. cannot read another player's inventory
  await deposit(u2.userId, 'crystal', 7)
  const u1Sees = (await u1.client.from('player_inventory').select('item_id')).data ?? []
  !u1Sees.some((r) => r.item_id === 'crystal') ? ok("3. cannot read another user's inventory rows") : bad('3. cross-user RLS', "u1 saw u2's crystal")
  ;((await u2.client.from('player_inventory').select('item_id')).data ?? []).some((r) => r.item_id === 'crystal') ? ok('   (u2 can read its own crystal)') : bad('   u2 own read', 'missing')

  // 4. client cannot directly mutate inventory
  for (const [fn, args] of [
    ['inventory_deposit', { p_player: u1.userId, p_item: 'scrap', p_qty: 1 }],
    ['inventory_spend', { p_player: u1.userId, p_item: 'scrap', p_qty: 1 }],
    ['inventory_get_balance', { p_player: u1.userId, p_item: 'scrap' }],
  ]) {
    ;(await u1.client.rpc(fn, args)).error ? ok(`4. ${fn} denied to client`) : bad(`4. ${fn} denied`, 'EXECUTED — hole!')
  }
  const before = await balance(u1.userId, 'scrap')
  await u1.client.from('player_inventory').insert({ player_id: u1.userId, item_id: 'scrap', quantity: 999 })
  await u1.client.from('player_inventory').update({ quantity: 999 }).eq('player_id', u1.userId).eq('item_id', 'scrap')
  ;(await balance(u1.userId, 'scrap')) === before ? ok('4. client direct table writes blocked (unchanged)') : bad('4. table write', 'client mutated inventory!')

  // 6. idempotent deposit
  const key = `inv-${Date.now()}`
  await deposit(u1.userId, 'ore', 10, key)
  await deposit(u1.userId, 'ore', 10, key)
  ;(await balance(u1.userId, 'ore')) === 10 ? ok('6. deposit with same idempotency key does NOT double-add') : bad('6. idempotency', `${await balance(u1.userId, 'ore')}`)

  // 7. spend subtracts
  await spend(u1.userId, 'scrap', 2)
  ;(await balance(u1.userId, 'scrap')) === 6 ? ok('7. spend subtracts quantity (8 - 2 = 6)') : bad('7. spend', `${await balance(u1.userId, 'scrap')}`)

  // 8/9. spend insufficient → rejected, never negative
  ;(await spend(u1.userId, 'scrap', 9999)).error ? ok('8. spend fails on insufficient quantity') : bad('8. insufficient', 'accepted')
  ;(await balance(u1.userId, 'scrap')) === 6 ? ok('9. spend never created negative / changed balance on failure') : bad('9. no-negative', `${await balance(u1.userId, 'scrap')}`)

  // 10. unknown item fails safely
  ;(await deposit(u1.userId, 'does_not_exist', 5)).error ? ok('10. deposit of unknown item rejected') : bad('10. unknown deposit', 'accepted')
  ;(await spend(u1.userId, 'does_not_exist', 1)).error ? ok('10. spend of unknown item rejected') : bad('10. unknown spend', 'accepted')
  ;(await spend(ZERO, 'scrap', 1)).error ? ok('   spend for a player with no balance rejected') : bad('   no-balance spend', 'accepted')

  // 11. regression
  console.log('\n11. Regression (M4.5 → M5 → M2/M3/M4):')
  if (env.INVENTORY_SKIP_REGRESS === '1') console.log('  · skipped (INVENTORY_SKIP_REGRESS=1)')
  else { try { execSync('node scripts/verify-m45.mjs', { stdio: 'inherit' }); ok('verify:m45 (chains m5/m2/m3/m4) passed') } catch { bad('regression', 'verify:m45 non-zero exit') } }
}

main()
  .catch((e) => { if (e instanceof Abort) bad('ABORTED', e.message); else bad('UNEXPECTED', e?.message ?? String(e)) })
  .finally(() => { console.log(`\nInventory: ${pass} passed, ${fail} failed\n`); process.exitCode = fail > 0 ? 1 : 0 })
