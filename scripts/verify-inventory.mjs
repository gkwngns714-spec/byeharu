// Inventory foundation verification.  node scripts/verify-inventory.mjs
//
// Service-role drives the locked inventory_* fns; anon clients verify RLS + that clients
// cannot mutate. Regression (M4.5 → M5 → M2/M3/M4) runs unless INVENTORY_SKIP_REGRESS=1.
//
// ── 0333 (ITEMS LIVE AT PORTS) ────────────────────────────────────────────────────────────────
// The global `player_inventory` pool is DROPPED. Items live PER PORT in `base_items`, keyed to the
// player's `bases` row for that port, so a balance is always AT a place and all three leaves now
// take that place as a required argument:
//     inventory_deposit(p_player, p_base, p_item, p_qty, p_key)   -- p_base NULL → oldest active base
//     inventory_spend(p_player, p_base, p_item, p_qty)            -- p_base NULL RAISES
//     inventory_get_balance(p_player, p_base, p_item)             -- p_base NULL RAISES
// A new signup gets a Home Base at Haven from the on_auth_user_created_base trigger, which IS the
// store every check below names.

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

// 0333: every leaf names the PORT it acts on. `store` is resolved once per test user below.
const deposit = (player, base, item, qty, key) =>
  admin.rpc('inventory_deposit', { p_player: player, p_base: base, p_item: item, p_qty: qty, p_key: key ?? null })
const spend = (player, base, item, qty) =>
  admin.rpc('inventory_spend', { p_player: player, p_base: base, p_item: item, p_qty: qty })
const balance = async (player, base, item) =>
  (await admin.rpc('inventory_get_balance', { p_player: player, p_base: base, p_item: item })).data ?? 0

/** The player's oldest ACTIVE base — the store a NULL-base deposit falls back to (0333). */
async function storeOf(player) {
  const { data } = await admin.from('bases').select('id').eq('player_id', player).eq('status', 'active')
    .order('created_at', { ascending: true }).limit(1)
  return data?.[0]?.id ?? null
}

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

  // 0333: the store each user's items LIVE in. The signup trigger creates it; if it is missing the
  // whole model has no place to key on, so this aborts rather than silently testing nothing.
  const s1 = await storeOf(u1.userId)
  const s2 = await storeOf(u2.userId)
  if (!s1 || !s2) die('a fresh signup has no active base — initialize_new_player did not run')
  s1 !== s2 ? ok('0. each player has their OWN port store (items live per-port, per-player)') : bad('0. store isolation', 'both users share a base id')

  // 1. item_types seeded
  const { data: items } = await admin.from('item_types').select('item_id')
  const ids = (items ?? []).map((r) => r.item_id)
  SEEDED.every((s) => ids.includes(s)) ? ok(`1. item_types seeded (${SEEDED.length} starter items present)`) : bad('1. seed', `missing ${SEEDED.filter((s) => !ids.includes(s))}`)

  // 5. deposit adds (do this first so there's data to read)
  await deposit(u1.userId, s1, 'scrap', 5)
  await deposit(u1.userId, s1, 'scrap', 3)
  ;(await balance(u1.userId, s1, 'scrap')) === 8 ? ok('5. deposit adds quantity (5 + 3 = 8)') : bad('5. deposit', `${await balance(u1.userId, s1, 'scrap')}`)

  // 2. owner reads own port store
  const ownRows = (await u1.client.from('base_items').select('item_id, quantity')).data ?? []
  ownRows.find((r) => r.item_id === 'scrap')?.quantity === 8 ? ok('2. owner can read own port store') : bad('2. owner read', JSON.stringify(ownRows))

  // 3. cannot read another player's port store
  await deposit(u2.userId, s2, 'crystal', 7)
  const u1Sees = (await u1.client.from('base_items').select('item_id')).data ?? []
  !u1Sees.some((r) => r.item_id === 'crystal') ? ok("3. cannot read another user's stored items") : bad('3. cross-user RLS', "u1 saw u2's crystal")
  ;((await u2.client.from('base_items').select('item_id')).data ?? []).some((r) => r.item_id === 'crystal') ? ok('   (u2 can read its own crystal)') : bad('   u2 own read', 'missing')

  // 3b. 0333: a store belongs to exactly ONE player — the leaves refuse a cross-player base.
  ;(await deposit(u1.userId, s2, 'scrap', 1)).error ? ok("3b. deposit into another player's store rejected") : bad('3b. cross-store deposit', 'accepted')
  ;(await spend(u1.userId, s2, 'crystal', 1)).error ? ok("3b. spend from another player's store rejected") : bad('3b. cross-store spend', 'accepted')

  // 4. client cannot directly mutate inventory
  for (const [fn, args] of [
    ['inventory_deposit', { p_player: u1.userId, p_base: s1, p_item: 'scrap', p_qty: 1 }],
    ['inventory_spend', { p_player: u1.userId, p_base: s1, p_item: 'scrap', p_qty: 1 }],
    ['inventory_get_balance', { p_player: u1.userId, p_base: s1, p_item: 'scrap' }],
  ]) {
    ;(await u1.client.rpc(fn, args)).error ? ok(`4. ${fn} denied to client`) : bad(`4. ${fn} denied`, 'EXECUTED — hole!')
  }
  const before = await balance(u1.userId, s1, 'scrap')
  await u1.client.from('base_items').insert({ base_id: s1, item_id: 'scrap', quantity: 999 })
  await u1.client.from('base_items').update({ quantity: 999 }).eq('base_id', s1).eq('item_id', 'scrap')
  ;(await balance(u1.userId, s1, 'scrap')) === before ? ok('4. client direct table writes blocked (unchanged)') : bad('4. table write', 'client mutated a port store!')

  // 6. idempotent deposit
  const key = `inv-${Date.now()}`
  await deposit(u1.userId, s1, 'ore', 10, key)
  await deposit(u1.userId, s1, 'ore', 10, key)
  ;(await balance(u1.userId, s1, 'ore')) === 10 ? ok('6. deposit with same idempotency key does NOT double-add') : bad('6. idempotency', `${await balance(u1.userId, s1, 'ore')}`)

  // 7. spend subtracts
  await spend(u1.userId, s1, 'scrap', 2)
  ;(await balance(u1.userId, s1, 'scrap')) === 6 ? ok('7. spend subtracts quantity (8 - 2 = 6)') : bad('7. spend', `${await balance(u1.userId, s1, 'scrap')}`)

  // 8/9. spend insufficient → rejected, never negative
  ;(await spend(u1.userId, s1, 'scrap', 9999)).error ? ok('8. spend fails on insufficient quantity') : bad('8. insufficient', 'accepted')
  ;(await balance(u1.userId, s1, 'scrap')) === 6 ? ok('9. spend never created negative / changed balance on failure') : bad('9. no-negative', `${await balance(u1.userId, s1, 'scrap')}`)

  // 10. unknown item fails safely
  ;(await deposit(u1.userId, s1, 'does_not_exist', 5)).error ? ok('10. deposit of unknown item rejected') : bad('10. unknown deposit', 'accepted')
  ;(await spend(u1.userId, s1, 'does_not_exist', 1)).error ? ok('10. spend of unknown item rejected') : bad('10. unknown spend', 'accepted')
  ;(await spend(ZERO, await storeOf(ZERO), 'scrap', 1)).error ? ok('   spend for a player with no balance rejected') : bad('   no-balance spend', 'accepted')

  // 10b. 0333 THE ASYMMETRY: a deposit with NO port never strands (it falls back to the oldest
  //      active base); a spend with no port is REFUSED outright. Never destroy an asset to satisfy
  //      a rule, and never let a spend happen without a place.
  const preFallback = await balance(u1.userId, s1, 'artifact_core')
  ;(await deposit(u1.userId, null, 'artifact_core', 2)).error
    ? bad('10b. placeless deposit', 'refused — it must fall back, not strand')
    : ((await balance(u1.userId, s1, 'artifact_core')) === preFallback + 2
        ? ok('10b. a deposit with NO port lands at the oldest active base (never nowhere)')
        : bad('10b. placeless deposit', 'landed somewhere other than the oldest active base'))
  ;(await spend(u1.userId, null, 'scrap', 1)).error ? ok('10b. a spend with NO port is REFUSED (law 3 as a shape)') : bad('10b. placeless spend', 'accepted — remote retrieval is expressible!')
  ;(await balance(u1.userId, null, 'scrap')).valueOf === undefined ? null : null
  ;(await admin.rpc('inventory_get_balance', { p_player: u1.userId, p_base: null, p_item: 'scrap' })).error
    ? ok('10b. a balance with NO port is REFUSED (a balance is always AT a place)')
    : bad('10b. placeless balance', 'answered — law 2 is a rule instead of a shape')

  // 11. regression
  console.log('\n11. Regression (M4.5 → M5 → M2/M3/M4):')
  if (env.INVENTORY_SKIP_REGRESS === '1') console.log('  · skipped (INVENTORY_SKIP_REGRESS=1)')
  else { try { execSync('node scripts/verify-m45.mjs', { stdio: 'inherit' }); ok('verify:m45 (chains m5/m2/m3/m4) passed') } catch { bad('regression', 'verify:m45 non-zero exit') } }
}

main()
  .catch((e) => { if (e instanceof Abort) bad('ABORTED', e.message); else bad('UNEXPECTED', e?.message ?? String(e)) })
  .finally(() => { console.log(`\nInventory: ${pass} passed, ${fail} failed\n`); process.exitCode = fail > 0 ? 1 : 0 })
