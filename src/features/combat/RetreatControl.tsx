import { useState } from 'react'
import { requestRetreat } from './combatApi'
import { retreatErrorMessage } from './combatReasonMessage'
import { Button, Notice } from '../../components/ui'

// LEAVING IS ONE CLICK, WHEREVER THE FIGHT IS DRAWN — the ONE retreat control.
//
// ── WHY IT EXISTS ──────────────────────────────────────────────────────────────────────────────────
// Retreat lived only inside ActiveCombatPanel, on the Mission screen. The battle is DRAWN on the
// Map, and `grep retreat src/features/map/MapScreen.tsx` returned nothing — so a player watching
// their fleet die had to leave the screen showing the fight to find the button that stops it. The
// map's combat card could not simply grow its own copy of the handler: that would be two components
// owning the same verb, each with its own busy flag and its own reading of the server's rejects.
// This is that verb, once. Both surfaces mount it; neither implements it.
//
// It decides nothing. `request_retreat` (the server) owns whether a retreat is legal, and
// `retreatErrorMessage` owns turning a raise into player words — a double-pressed Retreat used to
// render `request_retreat: presence not active (is retreating)` verbatim. This component only knows
// how to be pressed once at a time and how to say what came back.

export function RetreatControl({
  presenceId,
  retreating,
  onChanged,
  size = 'sm',
  className = '',
  testId = 'combat-retreat',
}: {
  presenceId: string
  /** the encounter is already breaking off — the button stays visible (so the player can see the
   *  order landed) but cannot be pressed again */
  retreating: boolean
  onChanged: () => void
  size?: 'sm' | 'md'
  className?: string
  testId?: string
}) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handleRetreat() {
    setBusy(true)
    setError(null)
    try {
      await requestRetreat(presenceId)
      onChanged()
    } catch (e) {
      setError(retreatErrorMessage(e instanceof Error ? e.message : String(e)))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className={className}>
      <Button
        variant="warning"
        size={size}
        data-testid={testId}
        onClick={handleRetreat}
        disabled={retreating}
        busy={busy}
        busyLabel="Working…"
      >
        {retreating ? 'Retreating…' : 'Retreat'}
      </Button>
      {error && (
        <Notice tone="danger" className="mt-2 text-xs" data-testid={`${testId}-error`}>
          {error}
        </Notice>
      )}
    </div>
  )
}
