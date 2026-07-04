// LOCATION-INVEST-P18 (post-audit UI, panel 2 of 4) — PURE, framework-free types + player-facing copy
// for the dark Port Investment surface.
//
// Mirrors the server contracts exactly: get_location_development / get_location_investment_leaderboard /
// get_my_location_investments (migration 0134) and the invest_in_location wrapper (0133). No
// React/DOM/fetch here (the miningTypes.ts / rankingTypes.ts idiom). DARK: while
// location_investment_enabled is false EVERY RPC returns { ok:false, code:'feature_disabled' } (the 0133
// /0134 dark gate), so the panel renders nothing — the UI is never the control (fail-closed law), and no
// client-side flag constant gates visibility (server-driven). The player's own standing is derived
// client-side from the returned leaderboard rows (no get_my_standing RPC exists — 0134).

/** One row of get_location_investment_leaderboard().rows (0134): seasonal-window score board. */
export interface InvestmentLeaderboardRow {
  rank: number
  player_id: string
  season_score: number
}

/** One row of get_my_location_investments().rows (0134): the caller's own contribution history. */
export interface MyInvestmentRow {
  investment_id: string
  location_id: string
  location_name: string
  amount: number
  invested_at: string
}

// get_location_development(location) envelope (0134): persistent development (all-time) + seasonal score
// (current window) for ONE location. Discriminated union (the miningTypes.ts idiom) so isServerLit()
// narrows to the { ok:true } member cleanly.
export type GetLocationDevelopmentResult =
  | {
      ok: true
      location_id: string
      all_time_total: number
      contributor_count: number
      season_total: number
      window_index: number
      window_start: string
      window_end: string
    }
  | { ok: false; code?: string }

// get_location_investment_leaderboard(location, limit) envelope (0134): the seasonal score board. `rows`
// optional (the events `events?` idiom) so a defensive `?? []` read is well-typed.
export type GetLocationInvestmentLeaderboardResult =
  | {
      ok: true
      location_id: string
      window_index: number
      window_start: string
      window_end: string
      rows?: InvestmentLeaderboardRow[]
    }
  | { ok: false; code?: string }

// get_my_location_investments() envelope (0134): the caller's own history.
export type GetMyLocationInvestmentsResult =
  | { ok: true; rows?: MyInvestmentRow[] }
  | { ok: false; code?: string }

// invest_in_location(ship, amount, request_id) wrapper envelope (0133): the ONE command. Success carries
// the appended ledger row; a same-(player, request_id) replay adds idempotent_replay. Failure is
// code-keyed (0133 has NO message layer — the UI owns copy via investErrorMessage below).
export type InvestInLocationResult =
  | {
      ok: true
      investment_id: string
      location_id: string
      amount: number
      invested_at: string
      idempotent_replay?: boolean
    }
  | { ok: false; code?: string }

// Player-facing copy for the EXACT code set invest_in_location can return (enumerated from 0133 — the
// writer + wrapper): feature_disabled · invalid_request · not_docked · invalid_amount ·
// insufficient_credits (the real wallet code — NOT "insufficient_funds") · not_authenticated ·
// ship_not_owned. Same tone/shape as miningExtractErrorMessage; the invest envelope has no server
// message layer, so this map is the sole copy source. 'unavailable' is the client-side fallback.
const INVEST_ERROR_COPY: Record<string, string> = {
  feature_disabled: 'Port investment is not available yet.',
  not_authenticated: 'You must be signed in.',
  ship_not_owned: 'You do not have a main ship.',
  not_docked: 'Dock at a port to invest.',
  invalid_amount: 'Enter a valid investment amount.',
  invalid_request: 'Invalid command request.',
  insufficient_credits: 'You do not have enough credits.',
  unavailable: 'You cannot invest right now.',
}
export function investErrorMessage(code: string): string {
  return INVEST_ERROR_COPY[code] ?? INVEST_ERROR_COPY.unavailable
}
