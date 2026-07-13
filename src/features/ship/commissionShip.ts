import { strictConfigFlag } from '../../lib/gameConfigFold'

// TEAM-ACTIVATION PREP — pure logic for the DARK commission-ship affordance (no React/DOM/IO).
//
// The activation packet (docs/TEAM_ACTIVATION_PACKET.md §2, approved) flips multi-ship
// commissioning WITH team command — but until this slice no component could reach
// commission_additional_main_ship at all (tradeApi.commissionAdditionalMainShip had zero .tsx
// callers), so the flip would have shipped a teams UI with no in-client way to buy ship #2.
// CommissionShipPanel.tsx composes these helpers; they follow the tradeReasonMessage /
// mainshipStatusLabel pure-module pattern and are unit-tested in tests/commissionShip.spec.ts.

// ── server-config coercion (public-read game_config rows → display context) ──────────────────────
// The four knobs the affordance displays/mirrors are all public-read (game_config RLS, 0003):
//   mainship_additional_commission_enabled (bool) · max_main_ships_per_player (int) ·
//   main_ship_price (numeric) · starting_credits (numeric — the 0093 lazy-wallet seed, needed to
//   show a no-wallet-row player their EFFECTIVE balance instead of a false 0). Values arrive as
//   jsonb (boolean/number, historically sometimes a numeric string) — coerce defensively and FAIL
//   CLOSED: unknown/absent flag → dark; absent numbers → the SERVER's own fallbacks (cap 3 per
//   0080, price 1000 per 0091, starting credits 0 per wallet_ensure's coalesce in 0093), so the
//   display mirror can never be more permissive than the server.
export interface CommissionContext {
  serverEnabled: boolean
  cap: number
  price: number
  startingCredits: number
}

export function commissionContextFromConfig(rows: Array<{ key: string; value: unknown }>): CommissionContext {
  const byKey = new Map(rows.map((r) => [r.key, r.value]))
  const num = (v: unknown, fallback: number): number => {
    if (v === null || v === undefined || v === '') return fallback
    const n = Number(v)
    return Number.isFinite(n) ? n : fallback
  }
  return {
    // strict boolean (the ONE shared fold — lib/gameConfigFold): anything but jsonb true
    // (including 'true' the string) reads as DARK.
    serverEnabled: strictConfigFlag(rows, 'mainship_additional_commission_enabled'),
    cap: num(byKey.get('max_main_ships_per_player'), 3), // the 0080 server-side coalesce fallback
    price: num(byKey.get('main_ship_price'), 1000), // the 0091 server-side coalesce fallback
    startingCredits: num(byKey.get('starting_credits'), 0), // wallet_ensure's coalesce fallback (0093)
  }
}

// ── effective-balance affordability (display-only; the server's wallet_debit owns truth) ─────────
// The wallet row is LAZY (0093: seeded with starting_credits at first debit), so a null balance
// from getWalletBalance means "no row yet" → the player's EFFECTIVE balance is the server-config
// starting_credits, not 0 ("I can buy a ship even though I have no money?" — owner; the truth was
// the opposite: they HAD money and the display said 0). Pure: no IO, unit-tested.
export interface CommissionAffordability {
  effectiveBalance: number
  fromStartingCredits: boolean // true → the wallet is unseeded; the balance shown is the seed value
  shortfall: number // max(0, price − effectiveBalance); 0 ⇔ affordable
}

export function commissionAffordability(
  balance: number | null,
  ctx: Pick<CommissionContext, 'startingCredits' | 'price'>,
): CommissionAffordability {
  const fromStartingCredits = balance === null
  const effectiveBalance = balance ?? ctx.startingCredits
  return {
    effectiveBalance,
    fromStartingCredits,
    shortfall: Math.max(0, ctx.price - effectiveBalance),
  }
}

/** Grouped credit amount for display ('1,000') — deterministic, locale-pinned. */
export function formatCredits(n: number): string {
  return n.toLocaleString('en-US')
}

/** The balance line: '1,000 cr (starting credits)' for an unseeded wallet, else '250 cr'. */
export function walletBalanceLabel(aff: CommissionAffordability): string {
  return `${formatCredits(aff.effectiveBalance)} cr${aff.fromStartingCredits ? ' (starting credits)' : ''}`
}

/** The insufficient-credits note WITH the shortfall — display-only; the server re-checks. */
export function commissionShortfallMessage(shortfall: number): string {
  return `Not enough credits — ${formatCredits(shortfall)} cr short.`
}

// ── reason → player copy (the tradeReasonMessage pattern) ────────────────────────────────────────
// Maps BOTH vocabularies to short player-facing text: the ACTUAL server reject strings of
// commission_additional_main_ship (0080/0091) + the tradeApi transport fallback ('unavailable'),
// and the client availability mirror's reasons (commissionAvailability in teamRoster.ts:
// gate_dark / cap_reached). Unknown → a generic line; never a raw code, never a throw.
const REASON_MESSAGES: Record<string, string> = {
  // server rejects (commission_additional_main_ship, 0080/0091) + transport fallback
  not_authenticated: 'Sign in to commission a ship.',
  additional_commission_disabled: 'Commissioning is not available yet.',
  no_first_ship: 'Your first ship comes with port entry — nothing to commission yet.',
  ship_cap_reached: 'Ship cap reached.',
  insufficient_credits: 'Not enough credits.',
  unavailable: 'Commissioning unavailable.',
  // client availability mirror (commissionAvailability — display-only, server stays authoritative)
  gate_dark: 'Commissioning is not available yet.',
  cap_reached: 'Ship cap reached.',
}

/** Short player-facing message for a commission reason; unknown → generic (never a raw code). */
export function commissionReasonMessage(reason: string): string {
  return REASON_MESSAGES[reason] ?? 'Commissioning unavailable.'
}
