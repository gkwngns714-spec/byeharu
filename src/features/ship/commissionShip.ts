// TEAM-ACTIVATION PREP — pure logic for the DARK commission-ship affordance (no React/DOM/IO).
//
// The activation packet (docs/TEAM_ACTIVATION_PACKET.md §2, approved) flips multi-ship
// commissioning WITH team command — but until this slice no component could reach
// commission_additional_main_ship at all (tradeApi.commissionAdditionalMainShip had zero .tsx
// callers), so the flip would have shipped a teams UI with no in-client way to buy ship #2.
// CommissionShipPanel.tsx composes these helpers; they follow the tradeReasonMessage /
// mainshipStatusLabel pure-module pattern and are unit-tested in tests/commissionShip.spec.ts.

// ── server-config coercion (public-read game_config rows → display context) ──────────────────────
// The three knobs the affordance displays/mirrors are all public-read (game_config RLS, 0003):
//   mainship_additional_commission_enabled (bool) · max_main_ships_per_player (int) ·
//   main_ship_price (numeric). Values arrive as jsonb (boolean/number, historically sometimes a
//   numeric string) — coerce defensively and FAIL CLOSED: unknown/absent flag → dark; absent
//   numbers → the SERVER's own fallbacks (cap 3 per 0080, price 1000 per 0091), so the display
//   mirror can never be more permissive than the server.
export interface CommissionContext {
  serverEnabled: boolean
  cap: number
  price: number
}

export function commissionContextFromConfig(rows: Array<{ key: string; value: unknown }>): CommissionContext {
  const byKey = new Map(rows.map((r) => [r.key, r.value]))
  const num = (v: unknown, fallback: number): number => {
    if (v === null || v === undefined || v === '') return fallback
    const n = Number(v)
    return Number.isFinite(n) ? n : fallback
  }
  return {
    // strict boolean: anything but jsonb true (including 'true' the string) reads as DARK.
    serverEnabled: byKey.get('mainship_additional_commission_enabled') === true,
    cap: num(byKey.get('max_main_ships_per_player'), 3), // the 0080 server-side coalesce fallback
    price: num(byKey.get('main_ship_price'), 1000), // the 0091 server-side coalesce fallback
  }
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
