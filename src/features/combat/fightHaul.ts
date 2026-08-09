import { resolveRewardEntries, type RewardPayload } from './rewardPayload'

// ██ THE HAUL — what this fight has earned so far, what it would cost to die, and how much room it
//    takes. ██
//
// ── WHY THE HAUL IS THE MOST DECISION-RELEVANT NUMBER IN A FIGHT ───────────────────────────────────
// The owner's standing combat law: *"the whole point of this game is never to win, but exit
// appropriately."* Migration 0347 made the field GROW without bound on purpose, so no fight is ever
// won; and a DEFEAT zeroes `combat_encounters.total_rewards_json` outright — measured on production,
// one death destroyed 10 of the 11 engine_parts and all 1,115 metal an account had ever earned at
// Reaver. So the only question the fight actually asks is *stay for one more kill, or leave and bank
// this*, and the player cannot weigh it without seeing what "this" is.
//
// ── ONE READER, COMPOSED ───────────────────────────────────────────────────────────────────────────
// The payload is `{"metal": N, "items":[{item_id, quantity}, …]}` — a scalar key BESIDE an array key.
// Reading it inline is how two surfaces once rendered `Items ×[object Object]` and silently dropped
// every looted item. `combat/rewardPayload.resolveRewardEntries` is the ONE reader and this file
// composes it; it never touches the raw json.
//
// ── VOLUME: A CATALOG FACT, NOT A HOLD READING ─────────────────────────────────────────────────────
// `item_types.volume_m3` says how much ONE unit of an item takes up, anywhere it is stored. That is
// what is multiplied here, and it is the only arithmetic in this file. It is NOT a reading of how
// full anything IS: occupancy and capacity are the server's (`get_my_hold`, 0333) and are never
// recomputed on the client — the same law `features/inventory/hold.ts` states for itself.
//
// A reward code with no catalog volume is counted separately and NEVER treated as zero. `metal` is
// the live example: it is a currency, it has no `item_types` row, and folding it in at 0 m³ would
// quietly under-report a haul. An unknown volume is reported as unknown.
//
// PURE. No React, no fetch, no clock.

/** One thing this fight has won, with what it occupies. */
export interface HaulEntry {
  /** the reward code — `metal`, or an `item_types.item_id` */
  id: string
  /** the server's own quantity */
  qty: number
  /** `qty × item_types.volume_m3`, or null when the catalog does not price this code by volume. */
  m3: number | null
}

export interface FightHaulView {
  /** every reward in the payload, in the ONE reader's deterministic order. */
  entries: HaulEntry[]
  /** the summed m³ of the entries that HAVE a catalog volume, or null when none of them does. */
  m3: number | null
  /** how many entries carry no catalog volume (currencies and anything not in item_types). Non-zero
   *  means `m3` is a floor, not a total, and the surface must not present it as exact. */
  unmeasured: number
  /** nothing has been won yet — the ONE "no haul" test, never a probe of a single key. */
  empty: boolean
}

/**
 * The haul for one encounter.
 *
 * `volumeByItem` is `item_types.item_id → volume_m3`, from the existing catalog read
 * (`features/modules/modulesApi.fetchItemCatalog`). An empty map is legal and honest: every entry
 * comes back `m3: null`, the total is null, and the surface says nothing about volume rather than
 * printing a zero it cannot defend.
 */
export function resolveFightHaul(
  payload: RewardPayload,
  volumeByItem: ReadonlyMap<string, number>,
): FightHaulView {
  const entries: HaulEntry[] = []
  let total: number | null = null
  let unmeasured = 0

  for (const r of resolveRewardEntries(payload)) {
    const unit = volumeByItem.get(r.id)
    const priced = typeof unit === 'number' && Number.isFinite(unit) && unit > 0
    const m3 = priced ? unit * r.qty : null
    if (m3 === null) unmeasured += 1
    else total = (total ?? 0) + m3
    entries.push({ id: r.id, qty: r.qty, m3 })
  }

  return { entries, m3: total, unmeasured, empty: entries.length === 0 }
}

// ── ██ WHERE THE HAUL ACTUALLY GOES — AND WHY THE OLD SENTENCE WAS THE BUG ██ ──────────────────────
// Owner, playing 2026-08-09: *"fleet hold is not updated when fight is done"*.
//
// He is reading the card correctly; the card was telling him the wrong thing. TRACED THROUGH THE
// DEPLOYED SERVER, end to end:
//   1. a kill folds `reward_delta` into `combat_encounters.total_rewards_json` (0344's payout arm);
//   2. leaving the fight calls `movement_attach_cargo(v_mv, e.id, e.total_rewards_json)`, which
//      copies the payload onto the RETURN LEG as `fleet_movements.reward_payload_json` (0030:30);
//   3. the leg's arrival calls `reward_grant(source_type, source, player, base, payload)` (0307:172),
//      and reward_grant deposits into a BASE — `base_items` / the base's resources, i.e. that PORT's
//      storage. 0333 states the destination outright: *"reward_grant (loot) → the base it is already
//      handed; and where that is NULL (loot secured in open space) the player's OLDEST ACTIVE base"*.
//
// `fleet_items` — THE FLEET HOLD — is never written by any arm of that chain. Items live at PORTS
// and the hold is purely what a fleet carries between them (0333's settled model). So the hold does
// not change when a fight ends, cannot change while one is running, and the old sentence — "Banked
// when the fleet leaves and arrives", printed directly above a "Fleet hold 0.0/240 m³" meter —
// promised a relationship the database does not have. That is the whole defect, and it is CLIENT
// SIDE: nothing on the server is missing or late.
//
// The sentence therefore names the destination. Present tense and unconditional: it is true of every
// live fight, not a warning that appears at some threshold.
export const HAUL_AT_STAKE =
  'Banked into the port’s storage when the fleet arrives. Lost entirely if it is destroyed.'
