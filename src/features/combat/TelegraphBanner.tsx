import { useCallback, useEffect, useState } from 'react'
import { Button, OverlayPanel } from '../../components/ui'
import { fetchMyPendingEncounter, fleePending, type PendingEncounter } from './telegraphApi'

// COMBAT-S2 TELEGRAPH — the pre-combat warning banner (mounted on MapScreen). Polls the caller's
// pending encounter (~1s), shows "⚠ Combat encounter … in Ns" with a LIVE countdown, and a Flee button
// wired to combat_flee_pending. Renders NOTHING when there is no telegraphed encounter — so while the
// server flag combat_telegraph_enabled is dark (the table is always empty) the banner is invisible
// (fail-closed by data, exactly like the combat panels themselves are data-gated).
//
// Slot: top-center (the urgent-alert corner). WorldEventsPanel also names top-center but the server
// keeps it dark/empty today; if both ever light, a future slice rails them — the telegraph is the more
// urgent occupant and rides z above.

export function TelegraphBanner({ onChange }: { onChange?: () => void }) {
  const [pending, setPending] = useState<PendingEncounter | null>(null)
  const [now, setNow] = useState(() => Date.now())
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    try {
      setPending(await fetchMyPendingEncounter())
    } catch {
      /* transient read error; next poll retries */
    }
  }, [])

  // Poll the pending read (~1s). Dark → always null → the banner stays unmounted.
  useEffect(() => {
    let active = true
    ;(async () => {
      await refresh()
    })()
    const iv = setInterval(() => {
      if (active) void refresh()
    }, 1000)
    return () => {
      active = false
      clearInterval(iv)
    }
  }, [refresh])

  // Local clock for the live countdown between polls (only while a warning is showing).
  useEffect(() => {
    if (!pending) return
    const iv = setInterval(() => setNow(Date.now()), 250)
    return () => clearInterval(iv)
  }, [pending])

  const handleFlee = useCallback(async () => {
    if (!pending) return
    setBusy(true)
    setError(null)
    try {
      await fleePending(pending.fleet_id)
      setPending(null)
      onChange?.()
    } catch (e) {
      // The resolver may have started combat first (no_pending) — surface it and re-read.
      setError(e instanceof Error ? e.message : 'Could not flee')
      void refresh()
    } finally {
      setBusy(false)
    }
  }, [pending, onChange, refresh])

  if (!pending) return null

  const secondsLeft = Math.max(0, Math.ceil((new Date(pending.trigger_at).getTime() - now) / 1000))
  const where = pending.location_name ?? 'this zone'

  return (
    <OverlayPanel
      slot="top-center"
      tone="warning"
      data-testid="telegraph-banner"
      className="z-20 w-[min(92vw,30rem)] text-warning"
    >
      <div className="flex items-center justify-between gap-3">
        <p className="text-sm">
          ⚠ Combat encounter at <span className="font-medium">{where}</span> in{' '}
          <span className="font-mono tabular-nums" data-testid="telegraph-countdown">
            {secondsLeft}s
          </span>
          …
        </p>
        <div className="flex shrink-0 items-center gap-2">
          {error && (
            <span className="text-xs text-danger" data-testid="telegraph-error">
              {error}
            </span>
          )}
          <Button
            variant="warning"
            size="sm"
            onClick={handleFlee}
            busy={busy}
            busyLabel="Fleeing…"
            data-testid="telegraph-flee"
          >
            Flee
          </Button>
        </div>
      </div>
    </OverlayPanel>
  )
}
