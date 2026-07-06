// RANKING-P17 (post-audit UI, panel 1 of 4) — PURE, framework-free types for the dark Ranking
// leaderboard surface.
//
// Mirrors the server contract exactly: get_ranking_seasons() + get_ranking_leaderboard(season,
// dimension, limit) (migration 0131). No React/DOM/fetch here (the eventsTypes.ts / explorationTypes.ts
// idiom). DARK: while ranking_enabled is false BOTH RPCs return { ok:false, code:'feature_disabled' }
// (0131 dark gate), so the panel renders nothing — the UI is never the control (fail-closed law), and
// no client-side flag constant gates visibility (server-driven).

/** One row of get_ranking_seasons().seasons (0131). */
export interface RankingSeason {
  season_id: string
  cadence: string
  label: string
  starts_at: string
  ends_at: string
  status: string
}

/** One row of get_ranking_leaderboard().rows (0131). */
export interface RankingRow {
  rank: number
  player_id: string
  score: number
  events_counted: number
}

/** The leaderboard dimension domain (0131): the four concrete reward_grants.source_type dimensions +
 *  the read-time-derived 'overall'. */
export type RankingDimension = 'overall' | 'combat' | 'trade' | 'exploration' | 'mining'

// get_ranking_seasons() envelope (0131): lit → { ok:true, seasons:[...] }; dark → { ok:false,
// code:'feature_disabled' }; transport error → { ok:false }. A DISCRIMINATED union (the eventsTypes.ts
// idiom), NOT a flat { ok:boolean; seasons? } — so the shared isServerLit() guard narrows to the
// { ok:true } member cleanly (a flat shape would Extract to `never`). `seasons` optional (the events
// `events?` idiom) so a defensive `?? []` read is well-typed.
export type GetRankingSeasonsResult =
  | { ok: true; seasons?: RankingSeason[] }
  | { ok: false; code?: string }

// get_ranking_leaderboard() envelope (0131): lit → { ok:true, season_id, dimension, rows:[...] };
// dark / bad input → { ok:false, code }; transport error → { ok:false }. Same discriminated-union
// shape so isServerLit() narrows the success member.
export type GetRankingLeaderboardResult =
  | { ok: true; season_id: string; dimension: string; rows?: RankingRow[] }
  | { ok: false; code?: string }
