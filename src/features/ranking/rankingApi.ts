import { supabase } from '../../lib/supabase'
import type { GetRankingLeaderboardResult, GetRankingSeasonsResult } from './rankingTypes'

// RANKING-P17 (post-audit UI, panel 1 of 4) — typed client API for the dark Ranking read surface
// (get_ranking_seasons + get_ranking_leaderboard, 0131). Mirrors eventsApi.ts / assetsApi.ts
// conventions: thin supabase.rpc wrappers; on a transport/DB error resolve to a normalized fail-closed
// value ({ ok:false }) — never throw a raw error into the render path. Reads ONLY these two EXISTING
// RPCs — NO new server authority. DARK: while ranking_enabled is false the server returns
// { ok:false, code:'feature_disabled' } for both, so the panel stays hidden (server-driven, no client
// flag constant). There is no get_my_standing RPC by design — the own standing is derived client-side
// from the returned leaderboard rows (see RankingPanel).

/** Read the browsable season list. Dark → { ok:false, code:'feature_disabled' }; error → { ok:false }. */
export async function getRankingSeasons(): Promise<GetRankingSeasonsResult> {
  const { data, error } = await supabase.rpc('get_ranking_seasons', {})
  if (error) return { ok: false }
  return data as GetRankingSeasonsResult
}

/**
 * Read one season's ranked board for a dimension. `limit` omitted → the server default (100). Dark /
 * invalid input → { ok:false, code }; transport error → { ok:false } (fail-closed).
 */
export async function getRankingLeaderboard(
  seasonId: string,
  dimension: string,
  limit?: number,
): Promise<GetRankingLeaderboardResult> {
  const { data, error } = await supabase.rpc('get_ranking_leaderboard', {
    p_season_id: seasonId,
    p_dimension: dimension,
    p_limit: limit ?? null,
  })
  if (error) return { ok: false }
  return data as GetRankingLeaderboardResult
}
