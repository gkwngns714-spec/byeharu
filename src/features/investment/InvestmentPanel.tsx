import { useCallback, useEffect, useState } from 'react'
import { isServerLit, runGuardedCommand, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { useAuthStore } from '../../store/authStore'
import {
  getLocationDevelopment,
  getLocationInvestmentLeaderboard,
  getMyLocationInvestments,
  investInLocation,
} from './investmentApi'
import {
  investErrorMessage,
  type GetLocationDevelopmentResult,
  type GetLocationInvestmentLeaderboardResult,
  type GetMyLocationInvestmentsResult,
} from './investmentTypes'
import { Button, Card, CardHeader } from '../../components/ui'

// LOCATION-INVEST-P18 (post-audit UI, panel 2 of 4) — the dark Port Investment surface: the docked
// port's persistent development + seasonal score board + the caller's own history, and ONE Invest
// action. SERVER-DRIVEN visibility (no client flag constant): on mount / lifecycle change it reads
// get_location_development (0134) and renders NOTHING unless the server affirmatively lit the feature
// ({ok:true}); while location_investment_enabled is false the server returns feature_disabled → not
// server-lit → null, so today's production experience is byte-unchanged. Reads ONLY the three existing
// 0134 RPCs and submits ONLY the existing invest_in_location command (0133) — NO new server authority.
// The server derives the location from where the ship is docked and is authoritative on
// docked/amount/wallet; the own standing is derived client-side from the returned rows (no RPC).

export function InvestmentPanel({
  // The ship's server-reported docked location (null when not docked) and the ship id for the command.
  locationId,
  mainShipId,
  // Re-reads whenever the main-ship dock lifecycle changes (the DockServicesPanel idiom).
  lifecycleKey,
}: {
  locationId: string | null
  mainShipId: string | null
  lifecycleKey: string
}) {
  const [development, setDevelopment] = useState<GetLocationDevelopmentResult | null>(null)
  const [leaderboard, setLeaderboard] = useState<GetLocationInvestmentLeaderboardResult | null>(null)
  const [history, setHistory] = useState<GetMyLocationInvestmentsResult | null>(null)
  const [amount, setAmount] = useState('')
  const [investPending, setInvestPending] = useState(false)
  const [investNote, setInvestNote] = useState<string | null>(null)

  // Signed-in player id — used ONLY to derive/highlight the own standing client-side (no RPC).
  const userId = useAuthStore((s) => s.user?.id ?? null)

  // Mounted + synchronous in-flight guards — the shared home of the idiom (useActivityPanelGuards).
  const guards = useActivityPanelGuards()
  const { activeRef } = guards

  const refresh = useCallback(async () => {
    // Not docked → no location to scope the reads; fail closed to null (the render guard below).
    if (locationId == null) {
      if (!activeRef.current) return
      setDevelopment(null)
      setLeaderboard(null)
      setHistory(null)
      return
    }
    const [dev, board, mine] = await Promise.all([
      getLocationDevelopment(locationId),
      getLocationInvestmentLeaderboard(locationId),
      getMyLocationInvestments(),
    ])
    if (!activeRef.current) return
    setDevelopment(dev)
    setLeaderboard(board)
    setHistory(mine)
  }, [activeRef, locationId]) // locationId is a real dep — refetch when the docked port changes

  // lifecycleKey is a deliberate re-fetch trigger (the DockServicesPanel/MiningPanel dep idiom).
  useEffect(() => {
    void refresh()
  }, [refresh, lifecycleKey])

  // ONE intentional Invest — the shared guarded-submit body (runGuardedCommand); the server dedups on
  // (player, request_id) and derives the location itself. Client generates a fresh uuid per submit.
  async function invest() {
    if (!mainShipId) return
    const amt = Number(amount)
    if (!Number.isFinite(amt) || amt <= 0) {
      setInvestNote(investErrorMessage('invalid_amount'))
      return
    }
    await runGuardedCommand({
      key: 'invest',
      guards,
      setPending: setInvestPending,
      setNote: setInvestNote,
      exec: () => investInLocation(mainShipId, amt, crypto.randomUUID()),
      successNote: (res) => `Invested ${res.amount} credits.`,
      errorNote: (res) => investErrorMessage(res.code ?? 'unavailable'),
      refresh,
    })
  }

  // FAIL CLOSED: render nothing unless the server affirmatively lit the development read. This is the
  // dark path in production today (feature_disabled → not server-lit); an undocked ship (unknown_location)
  // and transport errors collapse to null the same way. The client is never the control.
  if (!isServerLit(development)) return null

  const rows = isServerLit(leaderboard) ? (leaderboard.rows ?? []) : []
  const myRows = isServerLit(history) ? (history.rows ?? []) : []
  const ownRow = userId != null ? rows.find((r) => r.player_id === userId) : undefined
  const shortId = (id: string) => id.slice(0, 8)
  const windowRange = `${new Date(development.window_start).toLocaleDateString()} – ${new Date(development.window_end).toLocaleDateString()}`

  return (
    // UI R2: the Card primitive owns the chrome (accent tone = the investment identity; ex-cyan).
    // Screen-embedded — rides PortScreen's Screen stack (space-y-4), so the legacy map-corner
    // absolute offset (bottom-2 left-2) is gone with the hand-rolled skin. Tokens only.
    <Card tone="accent" data-testid="investment-panel">
      <CardHeader title="Port Investment" />

      {/* Persistent development (all-time) vs seasonal score (current window). */}
      <div data-testid="investment-development" className="mt-1 grid grid-cols-2 gap-1 text-[10px]">
        <span className="text-ink-muted">Development (all-time)</span>
        <span className="text-right font-mono tabular-nums text-ink">{development.all_time_total}</span>
        <span className="text-ink-muted">Contributors</span>
        <span className="text-right font-mono tabular-nums text-ink">{development.contributor_count}</span>
        <span className="text-ink-muted">Season score</span>
        <span className="text-right font-mono tabular-nums text-accent">{development.season_total}</span>
      </div>
      <p data-testid="investment-window" className="mt-1 text-[9px] text-ink-faint">
        Season window #{development.window_index}: {windowRange}
      </p>

      {/* Invest action — the ONE command; server derives the docked location + is authoritative. */}
      <div className="mt-2 flex items-center gap-1">
        <input
          data-testid="investment-amount-input"
          type="number"
          min={1}
          step={1}
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          placeholder="Amount"
          className="min-w-0 flex-1 rounded border border-edge bg-surface-2 px-2 py-1 text-xs font-mono tabular-nums text-ink"
        />
        <Button
          variant="primary"
          size="sm"
          data-testid="investment-invest-button"
          disabled={!mainShipId}
          busy={investPending}
          busyLabel="Investing…"
          onClick={() => void invest()}
          className="shrink-0"
        >
          Invest
        </Button>
      </div>
      {investNote && (
        <p data-testid="investment-invest-note" className="mt-1 text-[10px] text-accent">
          {investNote}
        </p>
      )}

      {/* Seasonal leaderboard, own row highlighted (client-side match on the auth uid). */}
      <ul data-testid="investment-leaderboard" className="mt-2 space-y-1 border-t border-edge pt-2">
        {rows.length === 0 ? (
          <li className="text-[10px] text-ink-muted">No investors this season yet.</li>
        ) : (
          rows.map((r) => {
            const isSelf = userId != null && r.player_id === userId
            return (
              <li
                key={r.player_id}
                data-testid={`investment-row-${r.player_id}`}
                className={`flex items-center justify-between gap-2 rounded px-1.5 py-0.5 text-[10px] ${
                  isSelf ? 'bg-accent/15 text-ink' : 'text-ink'
                }`}
              >
                <span className="w-6 shrink-0 font-mono tabular-nums text-ink-muted">#{r.rank}</span>
                <span className="min-w-0 flex-1 truncate font-mono">
                  {shortId(r.player_id)}
                  {isSelf && <span className="ml-1 text-accent">(you)</span>}
                </span>
                <span className="shrink-0 font-mono tabular-nums">{r.season_score}</span>
              </li>
            )
          })
        )}
      </ul>

      {/* OWN STANDING — derived purely client-side from the returned rows (no RPC): summarise the
          player's rank/score, or note "unranked" when outside the returned top-N. */}
      {userId != null && rows.length > 0 && (
        ownRow ? (
          <p data-testid="investment-own-standing" className="mt-1 text-[10px] text-accent">
            Your standing: #{ownRow.rank} · {ownRow.season_score} this season
          </p>
        ) : (
          <p data-testid="investment-own-standing-unranked" className="mt-1 text-[10px] text-ink-muted">
            Unranked — outside the top {rows.length}.
          </p>
        )
      )}

      {/* The caller's own contribution history (from get_my_location_investments). */}
      {myRows.length > 0 && (
        <ul data-testid="investment-history" className="mt-2 space-y-0.5 border-t border-edge pt-2">
          {myRows.map((m) => (
            <li key={m.investment_id} data-testid={`investment-history-${m.investment_id}`} className="flex items-center justify-between gap-2 text-[10px] text-ink-muted">
              <span className="min-w-0 truncate">{m.location_name}</span>
              <span className="shrink-0 font-mono tabular-nums text-ink">
                {m.amount} · {new Date(m.invested_at).toLocaleDateString()}
              </span>
            </li>
          ))}
        </ul>
      )}
    </Card>
  )
}
