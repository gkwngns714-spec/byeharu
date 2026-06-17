// Phase 4 verification — Pending Loot Bundle.  node scripts/verify-phase4.mjs
//
// reward_grant() is the secured-deposit owner: on home arrival it splits the bundle
//   { metal, items:[{item_id,quantity}] }  →  metal to base_resources, items to player_inventory.
// Service-role drives reward_grant directly (it is server-only; clients are denied).
// The timing law (pending while travelling · secured once on arrival · forfeited on
// defeat · retreat doesn't secure · reports keep metal) is proven end-to-end by the
// regression chain (verify-inventory → m45 → m5 → m2/m3/m4), run last unless
// PHASE4_SKIP_REGRESS=1.

import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'
import { execSync } from 'node:child_process'
import { randomUUID } from 'node:crypto'

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
if (!serviceKey) { console.error('phase4 verify needs SUPABASE_SERVICE_ROLE_KEY (server-side).'); process.exit(2) }

const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })

let pass = 0, fail = 0
const ok = (n) => { console.log('  ✓', n); pass++ }
const bad = (n, d) => { console.log('  ✗', n, d ? `— ${d}` : ''); fail++ }
class Abort extends Error {}
const die = (m) => { throw new Abort(m) }

// reward_grant is server-only → drive it as service_role.
const grant = (src, player, base, rewards) =>
  admin.rpc('reward_grant', { p_source_type: 'test', p_source_id: src, p_player: player, p_base: base, p_rewards: rewards })
const invBal = async (player, item) => (await admin.rpc('inventory_get_balance', { p_player: player, p_item: item })).data ?? 0

async function newUser(tag) {
  const c = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: su, error } = await c.auth.signUp({ email: `p4test.${tag}.${Date.now()}@example.com`, password: 'Test123456!' })
  if (error) die(`signup failed: ${error.message}`)
  if (!su.session) die('no session — email confirmation still ON')
  return { client: c, userId: su.user.id }
}

async function main() {
  console.log(`\nPhase 4 (Pending Loot Bundle) verification against ${url}\n`)
  const u1 = await newUser('a')
  const { data: base } = await u1.client.from('bases').select('id').limit(1).maybeSingle()
  if (!base) die('no base for throwaway user (initialize trigger?)')
  const baseId = base.id
  const baseMetal = async () => (await u1.client.from('base_resources').select('amount')
    .eq('base_id', baseId).eq('resource_code', 'metal').maybeSingle()).data?.amount ?? 0
  const grantsFor = async (src) => ((await u1.client.from('reward_grants').select('id').eq('source_id', src)).data ?? []).length
  ok('signed up throwaway user + base ready')

  // 0. SECURITY — clients cannot call reward_grant (server-only).
  ;(await u1.client.rpc('reward_grant', { p_source_type: 'x', p_source_id: randomUUID(), p_player: u1.userId, p_base: baseId, p_rewards: { metal: 1 } })).error
    ? ok('0. reward_grant denied to client (server-only)') : bad('0. anti-cheat', 'client EXECUTED reward_grant — hole!')

  // 1. Metal-only bundle still works (metal → base_resources; inventory untouched).
  {
    const src = randomUUID()
    const m0 = await baseMetal(), scrap0 = await invBal(u1.userId, 'scrap')
    const { error } = await grant(src, u1.userId, baseId, { metal: 50 })
    if (error) bad('1. metal-only', error.message)
    else {
      const dm = (await baseMetal()) - m0
      dm === 50 && (await invBal(u1.userId, 'scrap')) === scrap0 && (await grantsFor(src)) === 1
        ? ok('1. metal-only bundle deposits metal (+50), no inventory change')
        : bad('1. metal-only', `Δmetal=${dm}, grants=${await grantsFor(src)}`)
    }
  }

  // 2/3/4. metal+items bundle: stored & processed → metal to base, items to inventory.
  const srcB = randomUUID()
  {
    const m0 = await baseMetal(), sc0 = await invBal(u1.userId, 'scrap'), wp0 = await invBal(u1.userId, 'weapon_parts')
    const bundle = { metal: 30, items: [{ item_id: 'scrap', quantity: 3 }, { item_id: 'weapon_parts', quantity: 1 }] }
    const { error } = await grant(srcB, u1.userId, baseId, bundle)
    error ? bad('2. bundle accepted', error.message) : ok('2. metal+items bundle accepted as a pending reward structure')
    ;(await baseMetal()) - m0 === 30 ? ok('3. home-arrival deposit adds metal to base_resources (+30)') : bad('3. metal path', `Δ=${(await baseMetal()) - m0}`)
    const dsc = (await invBal(u1.userId, 'scrap')) - sc0, dwp = (await invBal(u1.userId, 'weapon_parts')) - wp0
    dsc === 3 && dwp === 1 ? ok('4. home-arrival deposit adds items to player_inventory (scrap+3, weapon_parts+1)') : bad('4. item path', `scrap+${dsc}, weapon_parts+${dwp}`)
  }

  // 5. Idempotent: re-running the SAME source does NOT double-add metal or items.
  {
    const m0 = await baseMetal(), sc0 = await invBal(u1.userId, 'scrap'), wp0 = await invBal(u1.userId, 'weapon_parts')
    await grant(srcB, u1.userId, baseId, { metal: 30, items: [{ item_id: 'scrap', quantity: 3 }, { item_id: 'weapon_parts', quantity: 1 }] })
    const same = (await baseMetal()) === m0 && (await invBal(u1.userId, 'scrap')) === sc0 && (await invBal(u1.userId, 'weapon_parts')) === wp0
    same && (await grantsFor(srcB)) === 1
      ? ok('5. re-grant of same source double-deposits NOTHING (metal + items idempotent)')
      : bad('5. idempotency', `metalΔ=${(await baseMetal()) - m0}, grants=${await grantsFor(srcB)}`)
  }

  // 6. Different source, same item → applies again (idempotency key is per-source).
  {
    const sc0 = await invBal(u1.userId, 'scrap')
    await grant(randomUUID(), u1.userId, baseId, { items: [{ item_id: 'scrap', quantity: 4 }] })
    ;(await invBal(u1.userId, 'scrap')) - sc0 === 4 ? ok('6. a NEW source deposits the same item again (key is per source+item)') : bad('6. per-source key', 'did not apply')
  }

  // 7. Unknown item is skipped safely — bundle does NOT fail; metal + valid items still deposit.
  {
    const src = randomUUID()
    const m0 = await baseMetal(), or0 = await invBal(u1.userId, 'ore')
    const { error } = await grant(src, u1.userId, baseId, { metal: 10, items: [{ item_id: 'ore', quantity: 2 }, { item_id: 'does_not_exist', quantity: 5 }] })
    error ? bad('7. unknown item safe', `bundle threw: ${error.message}`) : ok('7. bundle with an unknown item does NOT throw (fails safely)')
    ;(await baseMetal()) - m0 === 10 && (await invBal(u1.userId, 'ore')) - or0 === 2 && (await invBal(u1.userId, 'does_not_exist')) === 0
      ? ok('7. unknown item skipped; metal (+10) and valid item ore (+2) still deposited')
      : bad('7. partial deposit', `metalΔ=${(await baseMetal()) - m0}, oreΔ=${(await invBal(u1.userId, 'ore')) - or0}`)
    const ledgerBad = (await u1.client.from('inventory_ledger').select('id').eq('item_id', 'does_not_exist')).data ?? []
    ledgerBad.length === 0 ? ok('7. unknown item left no ledger / balance row') : bad('7. ledger leak', 'unknown item logged')
  }

  // 8. Duplicate item entries are combined deterministically (no double-bug).
  {
    const cr0 = await invBal(u1.userId, 'crystal')
    await grant(randomUUID(), u1.userId, baseId, { items: [{ item_id: 'crystal', quantity: 2 }, { item_id: 'crystal', quantity: 3 }] })
    ;(await invBal(u1.userId, 'crystal')) - cr0 === 5 ? ok('8. duplicate item entries combined once (crystal +5, not doubled)') : bad('8. dedup', `Δ=${(await invBal(u1.userId, 'crystal')) - cr0}`)
  }

  // 9. Negative / zero / NaN quantities are rejected per-item; valid siblings deposit.
  {
    const m0 = await baseMetal(), sc0 = await invBal(u1.userId, 'scrap'), or0 = await invBal(u1.userId, 'ore'), pa0 = await invBal(u1.userId, 'pirate_alloy')
    const { error } = await grant(randomUUID(), u1.userId, baseId, {
      metal: 5, items: [{ item_id: 'scrap', quantity: -1 }, { item_id: 'ore', quantity: 0 }, { item_id: 'crystal', quantity: 'NaN' }, { item_id: 'pirate_alloy', quantity: 2 }],
    })
    error ? bad('9. bad-qty safe', `threw: ${error.message}`) : ok('9. negative/zero/NaN quantities do not throw the bundle')
    const dsc = (await invBal(u1.userId, 'scrap')) - sc0, dor = (await invBal(u1.userId, 'ore')) - or0, dpa = (await invBal(u1.userId, 'pirate_alloy')) - pa0
    dsc === 0 && dor === 0 && dpa === 2 && (await baseMetal()) - m0 === 5
      ? ok('9. invalid quantities skipped (scrap/ore unchanged); valid pirate_alloy +2, metal +5')
      : bad('9. bad-qty filter', `scrapΔ=${dsc}, oreΔ=${dor}, pirate_alloyΔ=${dpa}`)
  }

  // 10. Empty bundle / metal:0 is a no-op (defeat sets total_rewards_json='{}').
  {
    const src = randomUUID()
    await grant(src, u1.userId, baseId, {})
    ;(await grantsFor(src)) === 0 ? ok('10. empty bundle grants nothing (defeat-forfeit shape)') : bad('10. empty bundle', 'created a grant')
  }

  // 11. Regression: M2/M3/M4/M4.5/M5/Inventory must stay green (proves the end-to-end
  //     timing law: pending→secured-on-arrival, defeat forfeits, retreat doesn't secure,
  //     reports keep metal). verify-inventory chains m45 → m5 → m2/m3/m4.
  console.log('\n11. Regression (Inventory → M4.5 → M5 → M2/M3/M4):')
  if (env.PHASE4_SKIP_REGRESS === '1') console.log('  · skipped (PHASE4_SKIP_REGRESS=1)')
  else { try { execSync('node scripts/verify-inventory.mjs', { stdio: 'inherit' }); ok('verify:inventory (chains m45/m5/m2/m3/m4) passed') } catch { bad('regression', 'verify:inventory non-zero exit') } }
}

main()
  .catch((e) => { if (e instanceof Abort) bad('ABORTED', e.message); else bad('UNEXPECTED', e?.message ?? String(e)) })
  .finally(() => { console.log(`\nPhase 4: ${pass} passed, ${fail} failed\n`); process.exitCode = fail > 0 ? 1 : 0 })
