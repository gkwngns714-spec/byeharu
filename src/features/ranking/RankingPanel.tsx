import { useCallback, useEffect, useMemo, useState } from 'react'
import { isServerLit, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { useAuthStore } from '../../store/authStore'
import { getRankingLeaderboard, getRankingSeasons } from './rankingApi'
import type {
  GetRankingLeaderboardResult,
  GetRankingSeasonsResult,
  RankingDimension,
} from './rankingTypes'

// RANKING-P17 (post-audit UI, panel 1 of 4) — the dark Ranking leaderboard: a read-only, server-driven
// standings surface. SERVER-DRIVEN visibility (no client flag constant): on mount / lifecycle change it
// reads get_ranking_seasons (0131) and renders NOTHING unless the server affirmatively lit the feature
// AND at least one season exists. While ranking_enabled is false the server returns
// { ok:false, code:'feature_disabled' } → not server-lit → null, so today's production Dashboard is
// byte-unchanged; when the human later lights the flag and opens a season, the board appears. The server
// (dark gate + validation) is the SOLE control; the client never decides visibility. Reads ONLY the two
// existing RPCs — NO new server authority. The player's OWN standing is derived purely client-side by
// matching the signed-in user id against the returned rows (there is no get_my_standing RPC by design).

const DIMENSIONS: RankingDimension[] = ['overall', 'combat', 'trade', 'exploration', 'mining']

export function RankingPanel({
  // Re-reads the board whenever the lifecycle key changes (the WorldEventsPanel idiom).
  lifecycleKey,
}: {
  lifecycleKey: string
}) {
  const [seasons, setSeasons] = useState<GetRankingSeasonsResult | null>(null)
  const [board, setBoard] = useState<GetRankingLeaderboardResult | null>(null)
  const [seasonId, setSeasonId] = useState<string | null>(null)
  const [dimension, setDimension] = useState<RankingDimension>('overall')

  // Signed-in player id — used ONLY to derive/highlight the own standing client-side (no RPC).
  const userId = useAuthStore((s) => s.user?.id ?? null)

  // Mounted guard — the shared home of the idiom (useActivityPanelGuards).
  const guards = useActivityPanelGuards()
  const { activeRef } = guards

  // 1) load the season list (fail-closed) on mount / lifecycle change.
  const refreshSeasons = useCallback(async () => {
    const res = await getRankingSeasons()
    if (!activeRef.current) return
    setSeasons(res)
  }, [activeRef]) // ref identity is stable — dep satisfies the lint rule without changing identity

  useEffect(() => {
    void refreshSeasons()
  }, [refreshSeasons, lifecycleKey])

  // The lit season list (empty while dark / on a failed read → the panel renders null below).
  const litSeasons = useMemo(
    () => (isServerLit(seasons) ? (seasons.seasons ?? []) : []),
    [seasons],
  )

  // 2) default-select the active season (else the first) once the lit list arrives; keep the current
  //    selection if it is still present in the list.
  useEffect(() => {
    if (litSeasons.length === 0) return
    if (seasonId != null && litSeasons.some((s) => s.season_id === seasonId)) return
    const active = litSeasons.find((s) => s.status === 'active')
    setSeasonId((active ?? litSeasons[0]).season_id)
  }, [litSeasons, seasonId])

  // 3) fetch the selected season + dimension board (fail-closed); re-runs on selection/lifecycle change.
  useEffect(() => {
    if (seasonId == null) {
      setBoard(null)
      return
    }
    let cancelled = false
    void (async () => {
      const res = await getRankingLeaderboard(seasonId, dimension)
      if (cancelled || !activeRef.current) return
      setBoard(res)
    })()
    return () => {
      cancelled = true
    }
  }, [seasonId, dimension, activeRef, lifecycleKey])

  // FAIL CLOSED: render nothing unless the server affirmatively lit the surface AND at least one season
  // exists. This is the dark path in production today (feature_disabled → not server-lit); transport
  // errors collapse to { ok:false } the same way. The client is never the control.
  if (!isServerLit(seasons) || litSeasons.length === 0) return null

  const rows = isServerLit(board) ? (board.rows ?? []) : []
  const ownRow = userId != null ? rows.find((r) => r.player_id === userId) : undefined
  const shortId = (id: string) => id.slice(0, 8)

  return (
    <div
      data-testid="ranking-panel"
      className="rounded-card border border-accent/20 bg-surface p-4 text-ink shadow-card"
    >
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-sm font-medium text-accent">Leaderboard</p>
        <div className="flex items-center gap-2">
          <select
            data-testid="ranking-season-select"
            value={seasonId ?? ''}
            onChange={(e) => setSeasonId(e.target.value)}
            className="rounded border border-edge bg-surface-2 px-2 py-1 text-xs text-ink"
          >
            {litSeasons.map((s) => (
              <option key={s.season_id} value={s.season_id}>
                {s.label} · {s.cadence}
                {s.status === 'active' ? ' (active)' : ''}
              </option>
            ))}
          </select>
          <select
            data-testid="ranking-dimension-select"
            value={dimension}
            onChange={(e) => setDimension(e.target.value as RankingDimension)}
            className="rounded border border-edge bg-surface-2 px-2 py-1 text-xs text-ink"
          >
            {DIMENSIONS.map((d) => (
              <option key={d} value={d}>
                {d}
              </option>
            ))}
          </select>
        </div>
      </div>

      <ul data-testid="ranking-list" className="mt-3 space-y-1 border-t border-edge pt-2">
        {rows.length === 0 ? (
          <li className="text-xs text-ink-faint">No standings yet for this board.</li>
        ) : (
          rows.map((r) => {
            const isSelf = userId != null && r.player_id === userId
            return (
              <li
                key={r.player_id}
                data-testid={`ranking-row-${r.player_id}`}
                className={`flex items-center justify-between gap-2 rounded px-2 py-1 text-xs ${
                  isSelf ? 'bg-accent/15 text-ink' : 'text-ink-muted'
                }`}
              >
                <span className="w-8 shrink-0 tabular-nums text-ink-faint">#{r.rank}</span>
                <span className="min-w-0 flex-1 truncate font-mono">
                  {shortId(r.player_id)}
                  {isSelf && <span className="ml-1 text-accent">(you)</span>}
                </span>
                <span className="shrink-0 tabular-nums">{r.score}</span>
                <span className="w-10 shrink-0 text-right tabular-nums text-ink-faint">{r.events_counted}</span>
              </li>
            )
          })
        )}
      </ul>

      {/* OWN STANDING — derived purely client-side from the returned rows (no get_my_standing RPC): the
          player's row is highlighted above; here we summarise its rank/score, or note "unranked" when the
          player is outside the returned top-N. */}
      {userId != null && rows.length > 0 && (
        ownRow ? (
          <p data-testid="ranking-own-standing" className="mt-2 text-xs text-accent">
            Your standing: #{ownRow.rank} · {ownRow.score} pts · {ownRow.events_counted} events
          </p>
        ) : (
          <p data-testid="ranking-own-standing-unranked" className="mt-2 text-xs text-ink-faint">
            Unranked — outside the top {rows.length}.
          </p>
        )
      )}
    </div>
  )
}
