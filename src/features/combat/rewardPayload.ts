// THE ONE READING OF A COMBAT REWARD PAYLOAD.
//
// ── WHAT THE SERVER ACTUALLY WRITES ────────────────────────────────────────────────────────────────
// `combat_encounters.total_rewards_json` and `combat_ticks.reward_delta_json` are built by the SAME
// two lines of the tick (0299:1006-1010 / :1185-1189, and 0299:969 for the per-tick delta):
//
//     total_rewards_json || jsonb_build_object('metal', <accumulated metal>)
//                        || jsonb_build_object('items', loot_merge_items(...))
//
// so the payload is `{"metal": 12, "items": [{"item_id":"…","quantity":3}, …]}` — a scalar key
// beside an ARRAY key. `loot_merge_items` (20260617000041:51-66) is the authority on the array's
// element shape: `{item_id, quantity}`, id-sorted, quantities summed.
//
// ── THE DEFECT THIS FILE DELETES ───────────────────────────────────────────────────────────────────
// Every client reader typed the payload `Record<string, number>` and mapped its ENTRIES straight
// into an ItemChip, so the `items` ARRAY was handed to a component expecting a number:
//   · ActiveCombatPanel rendered the pending haul as `Items ×[object Object]`;
//   · ReportsSection filtered entries on `v > 0`, which is FALSE for an array, so every dropped item
//     vanished silently from the battle report — the player was never told what they had won.
// Both surfaces were re-deriving the payload's shape inline, and both got it wrong in different
// ways. That is exactly the second-source-of-truth the anti-spaghetti law forbids: there is ONE
// payload, so there is ONE function that reads it, here, and every surface composes it.
//
// PURE. No React, no fetch, no clock. It invents nothing: an entry appears only because the server
// wrote it, and its quantity is the server's own number. Unknown scalar keys are passed through
// (a future reward code surfaces instead of hiding); anything that is not a positive finite
// quantity is dropped rather than rendered as `NaN` or `[object Object]`.

/** One thing the player won, ready for an ItemChip: the item's code and how many. */
export interface RewardEntry {
  /** the reward code — `metal`, or an `item_types.id` out of the `items` array */
  id: string
  /** the server's own quantity; always finite and > 0 */
  qty: number
}

/** The payload as it arrives over PostgREST. Deliberately `unknown`-valued: the keys are a mix of
 *  scalars and an array, and a caller that types it `Record<string, number>` is asserting a shape
 *  the server does not write. */
export type RewardPayload = Record<string, unknown> | null | undefined

const ITEMS_KEY = 'items'

const positive = (v: unknown): number | null => {
  const n = typeof v === 'string' ? Number(v) : v
  return typeof n === 'number' && Number.isFinite(n) && n > 0 ? n : null
}

/**
 * Every reward in the payload, flattened to one list a chip row can render directly.
 *
 * Order is DETERMINISTIC and meaningful rather than object-key order: scalar codes first (metal is
 * the only one the server writes today), then the `items` array in the id-sorted order
 * `loot_merge_items` already produced. Duplicate codes across the two halves are summed — the same
 * merge rule the server itself applies — so a code can never appear twice in one row.
 *
 * Returns [] for an absent, empty or wholly-zero payload. A caller renders "none" from an empty
 * list; it must never conclude "none" by looking at a single key.
 */
export function resolveRewardEntries(payload: RewardPayload): RewardEntry[] {
  if (!payload || typeof payload !== 'object') return []
  const order: string[] = []
  const byId = new Map<string, number>()
  const add = (id: string, qty: number) => {
    if (!id) return
    if (!byId.has(id)) order.push(id)
    byId.set(id, (byId.get(id) ?? 0) + qty)
  }

  // 1) scalar codes (metal today; anything else the server starts writing surfaces automatically)
  for (const [key, value] of Object.entries(payload)) {
    if (key === ITEMS_KEY) continue
    const qty = positive(value)
    if (qty !== null) add(key, qty)
  }

  // 2) the items array — the half every previous reader dropped
  const items = payload[ITEMS_KEY]
  if (Array.isArray(items)) {
    for (const raw of items) {
      if (!raw || typeof raw !== 'object') continue
      const row = raw as Record<string, unknown>
      const id = typeof row['item_id'] === 'string' ? row['item_id'] : ''
      const qty = positive(row['quantity'])
      if (id && qty !== null) add(id, qty)
    }
  }

  return order.map((id) => ({ id, qty: byId.get(id) as number }))
}

/** True when the payload carries nothing worth showing — the ONE "no rewards" test, so no surface
 *  decides it by probing a single key (`metal <= 0` used to hide a full hold of looted items). */
export function rewardPayloadIsEmpty(payload: RewardPayload): boolean {
  return resolveRewardEntries(payload).length === 0
}
