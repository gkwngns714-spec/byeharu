import { test, expect } from '@playwright/test'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  buyActionable,
  buyAvailability,
  buyBlocks,
  isOfferedByServer,
  offerEffectStanding,
  offeredRefIds,
  portShopReasonMessage,
  type ShopOffer,
} from '../src/features/port/portShop.ts'

// THE PURCHASE GATE — a withdrawn offer is withdrawn on the SERVER, and the client never claims
// otherwise.
//
// THE VERDICT (owner, 2026-08-04): "A disabled React button is not purchase prevention."
//
// The slice before this one hid a Buy button in React while all three of the Deep-Scan Sensor
// Array's offers were still `active = true` at 90 credits in production — so the RPC would still
// have sold it to anything that reached it. The fix is migration 20260618000342, which sets those
// three rows inactive; `buy_shop_offer_at_port` then answers its own `no_offer` (0235:258-260) and
// `get_port_shop` stops listing them (0235:355-358).
//
// NOTHING IN THIS FILE TYPES THE WITHDRAWN ITEM'S NAME. The ref is READ OUT OF THE MIGRATION, so
// these tests describe the rule ("what the server withdrew, the client does not sell") rather than
// the instance, and they follow the catalog when it moves.
//
// Run: `npx playwright test shopPurchaseGate.spec.ts`

const here = dirname(fileURLToPath(import.meta.url))
const repo = join(here, '..')
const migrationsDir = join(repo, 'supabase', 'migrations')

/** SQL with `--` line comments removed. The withdrawal migration documents its own rollback (an
 *  `update … set active = true`) in a comment; a scanner that reads comments would find a second,
 *  imaginary statement. Normalised to LF on read — this checkout can hand back CRLF. */
function sqlCode(text: string): string {
  return text.replace(/\r\n/g, '\n').replace(/^\s*--.*$/gm, '')
}

interface Withdrawal {
  file: string
  ref: string
  locations: string[]
}

/** Every forward deactivation of a port shop offer in the whole migration chain, derived from the
 *  SQL itself. This is the ONE place the withdrawn set is decided in this suite. */
function withdrawals(): Withdrawal[] {
  const out: Withdrawal[] = []
  for (const name of readdirSync(migrationsDir).filter((f) => f.endsWith('.sql')).sort()) {
    const code = sqlCode(readFileSync(join(migrationsDir, name), 'utf8'))
    const re =
      /update\s+public\.port_shop_offers\s+set\s+active\s*=\s*false\s+where\s+ref_id\s*=\s*'([a-z0-9_]+)'\s+and\s+location_id\s+in\s*\(([^)]*)\)\s*;/gi
    for (const m of code.matchAll(re)) {
      out.push({
        file: name,
        ref: m[1],
        locations: [...m[2].matchAll(/'([0-9a-f-]{36})'/gi)].map((x) => x[1]),
      })
    }
  }
  return out
}

const WITHDRAWALS = withdrawals()
const WITHDRAWN_REFS = [...new Set(WITHDRAWALS.map((w) => w.ref))]

// ── THE GATE IS A MIGRATION, NOT A BUTTON ───────────────────────────────────────────────────────

test('THE WITHDRAWAL EXISTS ON THE SERVER — a forward migration deactivates the offer rows', () => {
  // Without this, every derived assertion below is vacuously true and the whole file proves nothing.
  expect(
    WITHDRAWALS.length,
    'no migration deactivates a port_shop_offers row — the purchase gate is React-only again',
  ).toBe(1)
  expect(WITHDRAWN_REFS).toHaveLength(1)
  expect(WITHDRAWALS[0].file).toMatch(/^20260618000342_/)
})

test('it withdraws exactly three rows, at the three starter ports, and no fourth', () => {
  const w = WITHDRAWALS[0]
  expect(w.locations).toHaveLength(3)
  expect(new Set(w.locations).size, 'a port id is repeated').toBe(3)
  // the three seeded starter ports (0235:148-150) — the PK is (location_id, ref_id), so the location
  // set IS the row set.
  expect(w.locations.slice().sort()).toEqual([
    'b1a00001-0066-4a00-8a00-000000000001',
    'b1a00002-0066-4a00-8a00-000000000002',
    'b1a00003-0066-4a00-8a00-000000000003',
  ])
})

test('the withdrawal DEACTIVATES — it deletes nothing, refunds nothing and moves no price', () => {
  const code = sqlCode(readFileSync(join(migrationsDir, WITHDRAWALS[0].file), 'utf8'))
  expect(code, 'the migration deletes offer rows').not.toMatch(/delete\s+from\s+public\.port_shop_offers/i)
  expect(code, 'the migration deletes a catalog module').not.toMatch(/delete\s+from\s+public\.module_types/i)
  // the ONLY column any UPDATE sets on the offer table is `active`
  for (const m of code.matchAll(/update\s+public\.port_shop_offers\s+set\s+([^;]*?)\s+where/gi)) {
    expect(m[1].trim(), 'the withdrawal writes a column other than `active`').toMatch(/^active\s*=\s*(false|true)$/i)
  }
  // and it goes nowhere near player state
  for (const table of [
    'player_wallet',
    'module_instances',
    'ship_module_fittings',
    'base_items',
    'port_shop_receipts',
  ]) {
    expect(code, `the migration writes public.${table}`).not.toMatch(
      new RegExp(`(insert\\s+into|update|delete\\s+from)\\s+public\\.${table}\\b`, 'i'),
    )
  }
})

test('it GUARDS before it writes, and the guard EXECUTES', () => {
  const code = sqlCode(readFileSync(join(migrationsDir, WITHDRAWALS[0].file), 'utf8'))
  const guardAt = code.search(/do \$pre\$/)
  const writeAt = code.search(/update\s+public\.port_shop_offers\s+set\s+active\s*=\s*false/i)
  expect(guardAt, 'there is no precondition block').toBeGreaterThanOrEqual(0)
  expect(writeAt).toBeGreaterThan(guardAt)
  // preconditions that only warn are not preconditions
  const guard = code.slice(guardAt, writeAt)
  expect((guard.match(/raise exception/gi) ?? []).length).toBeGreaterThanOrEqual(6)
  expect(guard).toContain('PRECONDITION FAIL')
  // the switch is proven wired to the purchase path BEFORE it is thrown
  expect(guard).toContain('ref_id = p_ref_id and active')
  expect(guard).toContain('o.location_id = p_location_id and o.active')
  // and a self-assert runs AFTER the write, in a block, not as text to be grepped
  const post = code.slice(writeAt)
  expect(post).toContain('do $post$')
  expect((post.match(/raise exception/gi) ?? []).length).toBeGreaterThanOrEqual(6)
  expect(post).toContain('SELF-ASSERT FAIL')
})

// ── THE CLIENT NEVER OFFERS WHAT THE SERVER WITHDREW ────────────────────────────────────────────

/** The server's answer for a starter port AFTER the withdrawal: get_port_shop selects
 *  `where o.location_id = … and o.active`, so a deactivated ref is simply absent from the list. */
function serverAnswerAfterWithdrawal(): ShopOffer[] {
  const seeded = [
    'autocannon_battery',
    'shield_generator',
    'shield_lattice',
    'vector_thruster_kit',
    'expanded_cargo_lattice',
    'mining_rig_extension',
    ...WITHDRAWN_REFS,
  ]
  return seeded
    .filter((ref) => !WITHDRAWN_REFS.includes(ref))
    .map((ref) => ({
      kind: 'module' as const,
      ref_id: ref,
      price: 100,
      name: ref,
      slot_type: 'weapon',
      slot_cost: 1,
      stats_json: { attack: 10 },
      range: null,
      power: null,
      ammo_type: null,
      category: null,
      rarity: null,
      description: null,
    }))
}

test('A WITHDRAWN REF IS NOT IN THE SERVER ANSWER, AND THE CLIENT READS AVAILABILITY THERE', () => {
  const answer = serverAnswerAfterWithdrawal()
  expect(answer.length).toBeGreaterThan(0)
  for (const ref of WITHDRAWN_REFS) {
    expect(offeredRefIds(answer).has(ref)).toBe(false)
    expect(isOfferedByServer(answer, ref)).toBe(false)
  }
  // and everything the server DID send is offered — the derivation is not "always false"
  for (const o of answer) expect(isOfferedByServer(answer, o.ref_id)).toBe(true)
})

test('a withdrawn ref reaches the SERVER’s own no_offer, and its Buy is not actionable', () => {
  const answer = serverAnswerAfterWithdrawal()
  for (const ref of WITHDRAWN_REFS) {
    const avail = buyAvailability({
      flagOn: true,
      quantity: 1,
      isModule: true,
      shipResolved: true,
      docked: true,
      offerExists: isOfferedByServer(answer, ref),
      affordable: true,
    })
    expect(avail.reason, `${ref} did not reach no_offer`).toBe('no_offer')
    expect(avail.canBuy).toBe(false)
    expect(buyBlocks(avail.reason)).toBe(true)
    // …and the composed answer the row actually renders from
    expect(buyActionable(avail.reason, false)).toBe(false)
    expect(buyActionable(avail.reason, true)).toBe(false)
  }
  // the player is told, in the shop's existing words, through the ONE mapper
  expect(portShopReasonMessage('no_offer')).toBe('This port does not stock that.')
})

test('NO CLIENT FILE DECIDES THIS BY NAME — the port surface never spells a withdrawn ref', () => {
  // A rule that recognises an item id is a second availability authority: it would keep withholding
  // the item after the server put it back, and it would say nothing about the next one.
  const dir = join(repo, 'src', 'features', 'port')
  for (const name of readdirSync(dir).filter((f) => /\.(ts|tsx)$/.test(f))) {
    const text = readFileSync(join(dir, name), 'utf8')
    const code = text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')
    for (const ref of WITHDRAWN_REFS) {
      expect(
        code,
        `${relative(repo, join(dir, name)).replace(/\\/g, '/')} names ${ref} in code`,
      ).not.toContain(ref)
    }
  }
})

// ── THE TWO REFUSALS ARE INDEPENDENT, AND NEITHER MAY WIDEN THE OTHER ───────────────────────────

const dormantOnly: ShopOffer = {
  kind: 'module',
  ref_id: 'probe_dormant_only',
  price: 90,
  name: 'Probe',
  slot_type: 'sensor',
  slot_cost: 1,
  stats_json: { scan: 8 },
  range: null,
  power: null,
  ammo_type: null,
  category: null,
  rarity: null,
  description: null,
}

test('A DORMANT-ONLY OFFER THAT IS STILL ACTIVE IS STILL NOT ACTIONABLE — defence in depth', () => {
  // The server has not withdrawn it, so the availability mirror says ok. The 0340 lifecycle
  // projection says every effect it claims is dead. The row must still not be clickable: the
  // migration is the gate, and this is the second lock on the same door.
  expect(offerEffectStanding(dormantOnly)).toBe('no_live_effect')
  const avail = buyAvailability({
    flagOn: true,
    quantity: 1,
    isModule: true,
    shipResolved: true,
    docked: true,
    offerExists: true,
    affordable: true,
  })
  expect(avail.reason).toBe('ok')
  expect(buyActionable(avail.reason, offerEffectStanding(dormantOnly) === 'no_live_effect')).toBe(false)
})

test('the composition is an AND, in every direction — one yes is never enough', () => {
  const cases: [Parameters<typeof buyActionable>[0], boolean, boolean][] = [
    ['ok', false, true],
    ['ok', true, false],
    ['no_offer', false, false],
    ['no_offer', true, false],
    ['not_docked', false, false],
    ['port_shop_disabled', false, false],
    ['module_qty_must_be_one', false, false],
    ['invalid_quantity', false, false],
    ['ship_not_found', false, false],
    // insufficient_credits ADVISES rather than blocks (the salvage/repair posture, unchanged) — the
    // server's wallet_debit is the enforcement.
    ['insufficient_credits', false, true],
    ['insufficient_credits', true, false],
  ]
  for (const [reason, noLiveEffect, want] of cases) {
    expect(buyActionable(reason, noLiveEffect), `${reason} + noLiveEffect=${noLiveEffect}`).toBe(want)
  }
})

test('an offer the server sent, with a live effect, IS actionable — the gate is not a wall', () => {
  const answer = serverAnswerAfterWithdrawal()
  const live = answer[0]
  const avail = buyAvailability({
    flagOn: true,
    quantity: 1,
    isModule: true,
    shipResolved: true,
    docked: true,
    offerExists: isOfferedByServer(answer, live.ref_id),
    affordable: true,
  })
  expect(avail.reason).toBe('ok')
  expect(offerEffectStanding(live)).toBe('ok')
  expect(buyActionable(avail.reason, false)).toBe(true)
})

// ── THE ROW CANNOT SILENTLY STOP ASKING ─────────────────────────────────────────────────────────

test('the shop row takes its availability from the server answer, not a literal', () => {
  // The exact regression this closes: ShopRow passed `offerExists: true` as a constant, so the
  // client's mirror of the server's reject order could never reach no_offer no matter what the
  // server said.
  const panel = readFileSync(join(repo, 'src', 'features', 'port', 'ShopPanel.tsx'), 'utf8')
  expect(panel).toContain('offerExists: offered')
  expect(panel, 'ShopRow hardcodes offerExists again').not.toContain('offerExists: true')
  expect(panel).toContain('offeredRefIds(offers)')
  // and the Buy is the composed answer, not an expression re-derived in the markup
  expect(panel).toContain('disabled={!actionable}')
  expect(panel).toContain('buyActionable(avail.reason, noLiveEffect)')
})
