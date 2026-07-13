import { itemLabel, titleCaseId } from '../../components/items'
import { strictConfigFlag } from '../../lib/gameConfigFold'
import { foldStartingCredits } from './salvageMarket'
import { shipyardReasonMessage } from './shipyardReasonMessage'

// SHIPYARD-3 — PURE, framework-free types + client mirrors for the shipyard order surface (dark
// UI). Mirrors the server contracts exactly: the 0185 public-read recipe catalog
// (hull_build_recipes + hull_recipe_ingredients), the 0036 owner-read build_orders rows, and the
// `start_hull_build` reject ORDER (migration 0188). No React/DOM/fetch here (the salvageMarket.ts
// / haulBoard.ts idiom). DISPLAY-ONLY: the server stays authoritative and re-checks the gate,
// catalog, progression gates, queue cap, ingredients (inventory_spend's own FOR UPDATE) and
// credits (wallet_debit's conditional UPDATE) — these mirrors only let the panel annotate an
// affordance and fail closed without a round-trip. Reason names reuse the wrapper's PUBLIC code
// vocabulary (0188 §(d): the client sees `code`, the writer's internal `reason` never leaves the
// wrapper) so availability hints flow through the ONE shipyardReasonMessage mapper.
// Unit-tested in tests/shipyard.spec.ts.

// ── server-row shapes (the 0185 catalog + the 0036/0188 build_orders projection) ─────────────────

/** One `hull_build_recipes` header row (0185 — Reference/Config, public-read, migration-seeded
 *  only). The two gate columns are honestly NULL on the T1 seeds (dormant until a T2 recipe). */
export interface HullBuildRecipeRow {
  hull_type_id: string
  credits_cost: number
  build_seconds: number
  required_hull_type_id: string | null
  required_captain_level: number | null
}

/** One `hull_recipe_ingredients` row (0185 — normalized, FK-checked; qty integral by the 0188
 *  catalog law). */
export interface HullRecipeIngredientRow {
  hull_type_id: string
  item_id: string
  qty: number
}

/** One owner-read `build_orders` row (0036 select grant; 0188 added hull_type_id — a hull order
 *  carries hull_type_id and NULL unit/base, the kind-coherence CHECK). */
export interface BuildOrderRow {
  id: string
  hull_type_id: string | null
  status: string
  queued_at: string
}

// ── config fold (public-read game_config rows → the dark gate + display seeds) ───────────────────
// The panel's dark gate is the server's OWN flag read honestly from PUBLIC-READ game_config
// (0003 grant; the salvageConfigFromRows posture — 0185/0188 shipped no read RPC for the shipyard;
// the catalog is public Reference/Config). STRICT boolean: anything but jsonb true (absent row,
// 'true' the STRING, read error → []) reads as DARK. starting_credits reuses the ONE null-honest
// fold (foldStartingCredits, extracted from the salvage config fold — no third copy).
// max_build_orders feeds the queue-cap ADVISORY only (the server coalesces its own fallback of 5;
// absent/junk here → null → the precheck is skipped, never a client-side hardcode of the 5).
export interface ShipyardConfig {
  enabled: boolean
  /** The 0093 lazy-wallet seed — a no-wallet-row player's EFFECTIVE balance (null = unknown). */
  startingCredits: number | null
  /** The shared M4.5 queue cap (0188 §7 reads the same key); null = unknown → precheck skipped. */
  maxBuildOrders: number | null
}

export function shipyardConfigFromRows(rows: Array<{ key: string; value: unknown }>): ShipyardConfig {
  const byKey = new Map(rows.map((r) => [r.key, r.value]))
  const rawMax = byKey.get('max_build_orders')
  const max = rawMax === null || rawMax === undefined || rawMax === '' ? NaN : Number(rawMax)
  return {
    // strict boolean via the ONE shared fold (lib/gameConfigFold): only jsonb true lights;
    // 'true' the string / absent / [] read DARK.
    enabled: strictConfigFlag(rows, 'shipyard_enabled'),
    startingCredits: foldStartingCredits(byKey.get('starting_credits')),
    maxBuildOrders: Number.isFinite(max) && max > 0 ? Math.floor(max) : null,
  }
}

// ── effective credits for the wallet PRECHECK (advisory-only — the M2 posture) ───────────────────
// getWalletBalance sentinels preserved: 'error'/undefined (unknown) → null → the credits precheck
// is SKIPPED (the server answers insufficient_credits itself — never a false block on an unknown
// balance); null (no wallet row — the 0093 LAZY wallet) → the effective balance is the
// starting_credits seed (which itself may be null = unknown). The wallet DISPLAY string reuses
// salvageWalletDisplay directly (see ShipyardPanel) — one fold, one display helper.
export function shipyardEffectiveCredits(
  wallet: number | null | 'error' | undefined,
  startingCredits: number | null,
): number | null {
  if (wallet === 'error' || wallet === undefined) return null
  if (wallet === null) return startingCredits
  return wallet
}

// ── progression-gate views (HONEST — no false greens) ────────────────────────────────────────────
// 'none'    → the recipe carries no such gate (both T1 seeds — the gates are dormant-NULL).
// 'met'/'unmet' → the client could genuinely read the subject and answer.
// 'unknown' → the subject is UNREADABLE client-side → the panel shows the gate as a STATIC
//             requirement line with no met/unmet claim (the honesty posture): captain data rides
//             get_my_captain_instances, which is DARK while captain_assignment_enabled is false —
//             so a required_captain_level gate on a lit shipyard renders as a plain requirement
//             until captains light. The server enforces either way (0188 §6).

export type GateState = 'none' | 'met' | 'unmet' | 'unknown'

/** required_hull_type_id gate vs the player's owned (non-destroyed) hulls; owned=null = the
 *  own-ship read failed → 'unknown' (never a false unmet). */
export function hullGateState(required: string | null, ownedHullTypeIds: string[] | null): GateState {
  if (required === null) return 'none'
  if (ownedHullTypeIds === null) return 'unknown'
  return ownedHullTypeIds.includes(required) ? 'met' : 'unmet'
}

/** required_captain_level gate vs the player's best captain level; best=null = captains dark or
 *  levels absent from the envelope → 'unknown' (the static-requirement-line path). */
export function captainGateState(required: number | null, bestLevel: number | null): GateState {
  if (required === null) return 'none'
  if (bestLevel === null) return 'unknown'
  return bestLevel >= required ? 'met' : 'unmet'
}

/**
 * The player's best captain level from a LIT roster read, or null when unknowable.
 * captains=null → the roster RPC answered dark/error (get_my_captain_instances is
 * captain-gate-dark today) → null. An EMPTY lit roster → 0 (genuinely no captain — every level
 * gate is honestly unmet, the server's `not exists` arm). Captains present but with no numeric
 * `level` field (a pre-0181 envelope shape) → null — unknown, never a false unmet.
 */
export function bestCaptainLevel(captains: Array<{ level?: number }> | null): number | null {
  if (captains === null) return null
  if (captains.length === 0) return 0
  const levels = captains
    .map((c) => c.level)
    .filter((l): l is number => typeof l === 'number' && Number.isFinite(l))
  return levels.length > 0 ? Math.max(...levels) : null
}

// ── order availability mirror (the 0188 reject order) ────────────────────────────────────────────
export type ShipyardOrderReason =
  | 'ok'
  | 'feature_disabled'
  | 'hull_prerequisite_not_met'
  | 'captain_level_too_low'
  | 'queue_full'
  | 'insufficient_items'
  | 'insufficient_credits'

// DISPLAY-ONLY mirror of start_hull_build's reject order (0188, wrapper-code vocabulary):
//   gate FIRST (before ANY read — 0188 checks it in BOTH layers)
//   → [replay]                 CLIENT-UNREACHABLE: the panel mints a fresh crypto.randomUUID()
//                              per intentional submit; the server owns replay semantics.
//   → [unknown_hull/no_recipe] CLIENT-UNREACHABLE: every orderable hull id comes FROM a
//                              hull_build_recipes row the panel just read (a card exists only for
//                              a recipe), so the catalog-validation slot can't fire on our input.
//   → hull prerequisite gate (required_hull_type_id — owned, non-destroyed)
//   → captain level gate (required_captain_level — any owned captain at level)
//   → the SHARED queue cap (waiting+active across BOTH kinds — hull AND unit orders, one queue)
//   → ingredients (in item_id order — the server's pinned deterministic order; FIRST shortfall)
//   → credits (against the effective balance — the 0093 lazy-wallet honesty)
//   → ok.
// Also not mirrored: not_authenticated / invalid_request (server-only guards — the panel renders
// only for a signed-in session and always sends a fresh uuid). EVERY null input SKIPS its clause
// (unknown ≠ failing — the server answers itself; the haulAcceptAvailability null-cap idiom).
export function shipyardOrderAvailability(input: {
  flagOn: boolean
  requiredHullTypeId: string | null
  /** Owned non-destroyed hull type ids; null = unreadable → skip the prereq precheck. */
  ownedHullTypeIds: string[] | null
  requiredCaptainLevel: number | null
  /** Best owned captain level; null = captains dark/unknown → skip the level precheck. */
  bestCaptainLevel: number | null
  /** Waiting+active build_orders count (both kinds); null = unreadable → skip the cap precheck. */
  queuedCount: number | null
  /** The max_build_orders config value; null = unknown → skip the cap precheck. */
  maxOrders: number | null
  /** The recipe bill (any order; checked in item_id order like the server). */
  ingredients: Array<{ item_id: string; qty: number }>
  /** Own item balances; null = unreadable → skip the ingredient precheck. */
  balances: Record<string, number> | null
  creditsCost: number
  /** Effective credits (shipyardEffectiveCredits); null = unknown → skip the credits precheck. */
  credits: number | null
}): { canOrder: boolean; reason: ShipyardOrderReason; itemId?: string } {
  if (!input.flagOn) return { canOrder: false, reason: 'feature_disabled' }
  if (
    input.requiredHullTypeId !== null &&
    input.ownedHullTypeIds !== null &&
    !input.ownedHullTypeIds.includes(input.requiredHullTypeId)
  ) {
    return { canOrder: false, reason: 'hull_prerequisite_not_met' }
  }
  if (
    input.requiredCaptainLevel !== null &&
    input.bestCaptainLevel !== null &&
    input.bestCaptainLevel < input.requiredCaptainLevel
  ) {
    return { canOrder: false, reason: 'captain_level_too_low' }
  }
  if (input.queuedCount !== null && input.maxOrders !== null && input.queuedCount >= input.maxOrders) {
    return { canOrder: false, reason: 'queue_full' }
  }
  if (input.balances !== null) {
    // the server's pinned `order by item_id` — the FIRST shortfall is the one it would report.
    const bill = [...input.ingredients].sort((a, b) => a.item_id.localeCompare(b.item_id, 'en'))
    for (const ing of bill) {
      if ((input.balances[ing.item_id] ?? 0) < ing.qty) {
        return { canOrder: false, reason: 'insufficient_items', itemId: ing.item_id }
      }
    }
  }
  if (input.credits !== null && input.credits < input.creditsCost) {
    return { canOrder: false, reason: 'insufficient_credits' }
  }
  return { canOrder: true, reason: 'ok' }
}

/**
 * Which mirrored verdicts hard-DISABLE the Order button vs advise-only — the salvage M2 posture,
 * taken further: ONLY the dark gate blocks (structural — and by construction the panel is null
 * while dark, so a lit panel's button is effectively never hard-disabled). EVERY player-state
 * precheck ADVISES instead of blocking: balances/credits can be STALE-LOW (out-of-band loot or a
 * sale settling mid-dock doesn't tick lifecycleKey), the queue count can be stale-high (an order
 * completing), and the progression gates read snapshots — a hard disable could block a
 * genuinely-valid order. The hint shows through the ONE reason mapper and the SERVER is the
 * enforcement (0188 re-checks everything under its per-player advisory lock).
 */
export function shipyardOrderBlocks(reason: ShipyardOrderReason): boolean {
  return reason === 'feature_disabled'
}

// ── catalog view-model (recipes ⋈ ingredients ⋈ hull display names) ──────────────────────────────
export interface ShipyardRecipeEntry {
  hull_type_id: string
  /** Display name from the public hull register (main_ship_hull_types.name — e.g. 'Mule-class
   *  Hauler'); register row unreadable → honest title-cased id (never a crash, never a blank). */
  name: string
  credits_cost: number
  build_seconds: number
  required_hull_type_id: string | null
  required_captain_level: number | null
  /** The bill, pinned to item_id order (the server's deterministic spend order, 0188). */
  ingredients: Array<{ item_id: string; qty: number }>
}

/**
 * One card per recipe header (the recipe IS the orderable catalog — the strict 0188 FK means only
 * recipe-carrying hulls can ever be ordered), each joined with its ingredient rows and its hull
 * display name, sorted by display name with the raw id as the deterministic tiebreaker (the
 * salvageEntries idiom, locale pinned 'en'). A header with no loaded ingredient rows still shows
 * (the 0185 self-assert guarantees none exists server-side; an empty bill here just means the
 * ingredient read degraded — the server still charges the full bill).
 */
export function shipyardRecipeEntries(
  recipes: HullBuildRecipeRow[],
  ingredients: HullRecipeIngredientRow[],
  hullNames: Record<string, string>,
): ShipyardRecipeEntry[] {
  return recipes
    .map((r) => ({
      hull_type_id: r.hull_type_id,
      name: hullNames[r.hull_type_id] ?? titleCaseId(r.hull_type_id),
      credits_cost: r.credits_cost,
      build_seconds: r.build_seconds,
      required_hull_type_id: r.required_hull_type_id,
      required_captain_level: r.required_captain_level,
      ingredients: ingredients
        .filter((i) => i.hull_type_id === r.hull_type_id)
        .map((i) => ({ item_id: i.item_id, qty: i.qty }))
        .sort((a, b) => a.item_id.localeCompare(b.item_id, 'en')),
    }))
    .sort((a, b) => a.name.localeCompare(b.name, 'en') || a.hull_type_id.localeCompare(b.hull_type_id, 'en'))
}

// ── my-orders view-model (owner build_orders rows → the hull-order strip) ────────────────────────
export interface HullOrderView {
  id: string
  hull_type_id: string
  /** Hull display name (register name or honest title-case). */
  name: string
  /** waiting → 'Waiting' (paid, in the serial queue) · active → 'Building' (SHIPYARD-2's engine
   *  promotes; cannot exist while that engine is unshipped — shown honestly if it ever does). */
  statusLabel: string
  queued_at: string
}

/**
 * The MY ORDERS strip rows: HULL orders only (hull_type_id not null — unit training rows belong
 * to the base surfaces), non-terminal only (waiting/active), oldest first (queue order; id
 * tiebreak for determinism). No cancel affordance — see the ShipyardPanel seam note (SHIPYARD-2
 * owns cancel-refund semantics).
 */
export function hullOrderViews(orders: BuildOrderRow[], hullNames: Record<string, string>): HullOrderView[] {
  return orders
    .filter(
      (o): o is BuildOrderRow & { hull_type_id: string } =>
        o.hull_type_id !== null && (o.status === 'waiting' || o.status === 'active'),
    )
    .map((o) => ({
      id: o.id,
      hull_type_id: o.hull_type_id,
      name: hullNames[o.hull_type_id] ?? titleCaseId(o.hull_type_id),
      statusLabel: o.status === 'waiting' ? 'Waiting' : 'Building',
      queued_at: o.queued_at,
    }))
    .sort((a, b) => a.queued_at.localeCompare(b.queued_at, 'en') || a.id.localeCompare(b.id, 'en'))
}

/** Waiting+active orders across BOTH kinds — the shared M4.5 cap counts hull and unit orders
 *  together (0188 §7, the train_units predicate verbatim); feeds the queue-cap ADVISORY. */
export function activeOrderCount(orders: BuildOrderRow[]): number {
  return orders.filter((o) => o.status === 'waiting' || o.status === 'active').length
}

// ── reject note (mapped copy + the SERVER's own reject context — 0188's truthfulness channel) ────
/**
 * The post-reject note: the mapped player copy (shipyardReasonMessage) plus the reject envelope's
 * context pass-throughs — 0188 §(d) deliberately rides item_id/have/need, the credit need, the
 * cap, and the gate identities on the failure envelope "so the SHIPYARD-3 UI can be truthful".
 * Context is ADDITIVE: any absent field leaves the base copy unchanged (partial/transport
 * envelopes degrade cleanly to the mapped line). queue_full's envelope carries only `max` — and
 * the reject MEANS the queue is at (or past) it, so "max of max slots used" is the
 * server-truthful render (never a client-side count). hullNames is the public register (display
 * names); a missing register row → honest title-case, the catalog's own fallback.
 */
export function shipyardRejectNote(
  res: {
    code?: string
    item_id?: string
    have?: number
    need?: number
    max?: number
    required_hull_type_id?: string
    required_captain_level?: number
  },
  hullNames: Record<string, string> = {},
): string {
  const base = shipyardReasonMessage(res.code ?? 'unavailable')
  switch (res.code) {
    case 'insufficient_items':
      return res.item_id !== undefined && res.have !== undefined && res.need !== undefined
        ? `${base} (${itemLabel(res.item_id, 'item')}: have ${res.have.toLocaleString('en-US')}, need ${res.need.toLocaleString('en-US')})`
        : base
    case 'insufficient_credits':
      return res.need !== undefined ? `${base} (need ${res.need.toLocaleString('en-US')})` : base
    case 'queue_full':
      return res.max !== undefined
        ? `${base} (${res.max.toLocaleString('en-US')} of ${res.max.toLocaleString('en-US')} slots used)`
        : base
    case 'hull_prerequisite_not_met':
      return res.required_hull_type_id !== undefined
        ? `${base} (requires ${hullNames[res.required_hull_type_id] ?? titleCaseId(res.required_hull_type_id)})`
        : base
    case 'captain_level_too_low':
      return res.required_captain_level !== undefined
        ? `${base} (requires captain level ${res.required_captain_level})`
        : base
    default:
      return base
  }
}

// ── success note (SERVER-receipted values ONLY — never client math) ──────────────────────────────
/**
 * The post-order note, built from the start_hull_build success envelope verbatim: the receipted
 * credits_spent and the receipted ingredient bill (ingredients_spent — already in the server's
 * item_id order). A replay (idempotent_replay) reads "already queued" — the receipt is the
 * ORIGINAL order's, nothing was spent twice. Locale pinned 'en-US' (the formatCredits posture).
 */
export function shipyardSuccessNote(res: {
  idempotent_replay?: boolean
  credits_spent: number
  ingredients_spent: Array<{ item_id: string; quantity: number }>
}): string {
  const bill = res.ingredients_spent
    .map((s) => `${itemLabel(s.item_id, 'item')} ×${s.quantity.toLocaleString('en-US')}`)
    .join(', ')
  const spent = `${res.credits_spent.toLocaleString('en-US')} credits${bill ? ` + ${bill}` : ''}`
  return res.idempotent_replay
    ? `Build already queued — original order: ${spent}.`
    : `Build queued — spent ${spent}.`
}
