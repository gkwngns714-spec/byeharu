import { supabase } from '../../lib/supabase'
import type {
  GetLocationDevelopmentResult,
  GetLocationInvestmentLeaderboardResult,
  GetMyLocationInvestmentsResult,
  InvestInLocationResult,
} from './investmentTypes'

// LOCATION-INVEST-P18 (post-audit UI, panel 2 of 4) — typed client API for the dark Port Investment
// surface: three read RPCs (0134) + the ONE invest command (0133). Mirrors miningApi.ts / rankingApi.ts
// conventions: thin supabase.rpc wrappers; on a transport/DB error resolve to a normalized fail-closed
// value (never throw a raw error into the render path). Reads ONLY these existing RPCs and submits ONLY
// the existing command — NO new server authority. DARK: the server rejects every RPC while
// location_investment_enabled is false (feature_disabled) — visibility is server-driven, no client flag
// constant.

/** Persistent development + seasonal score for one location. Dark/unknown → { ok:false, code }; error → { ok:false }. */
export async function getLocationDevelopment(locationId: string): Promise<GetLocationDevelopmentResult> {
  const { data, error } = await supabase.rpc('get_location_development', { p_location_id: locationId })
  if (error) return { ok: false }
  return data as GetLocationDevelopmentResult
}

/** One location's seasonal leaderboard. `limit` omitted → server default (100). Fail-closed on error. */
export async function getLocationInvestmentLeaderboard(
  locationId: string,
  limit?: number,
): Promise<GetLocationInvestmentLeaderboardResult> {
  const { data, error } = await supabase.rpc('get_location_investment_leaderboard', {
    p_location_id: locationId,
    p_limit: limit ?? null,
  })
  if (error) return { ok: false }
  return data as GetLocationInvestmentLeaderboardResult
}

/** The caller's own contribution history (authenticated). Fail-closed on error. */
export async function getMyLocationInvestments(): Promise<GetMyLocationInvestmentsResult> {
  const { data, error } = await supabase.rpc('get_my_location_investments', {})
  if (error) return { ok: false }
  return data as GetMyLocationInvestmentsResult
}

/**
 * Invest credits in the ship's CURRENTLY DOCKED port (idempotent on (player, request_id); the server
 * derives the location from where the ship is docked and is authoritative on docked/amount/wallet).
 * Server-rejected while dark. On transport error → { ok:false, code:'unavailable' } (fail-closed).
 */
export async function investInLocation(
  shipId: string,
  amount: number,
  requestId: string,
): Promise<InvestInLocationResult> {
  const { data, error } = await supabase.rpc('invest_in_location', {
    p_ship: shipId,
    p_amount: amount,
    p_request_id: requestId,
  })
  if (error) return { ok: false, code: 'unavailable' }
  return data as InvestInLocationResult
}
