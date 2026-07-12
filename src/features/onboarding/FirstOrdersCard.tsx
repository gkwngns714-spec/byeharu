import { useState } from 'react'
import { useShellState } from '../../app/shellState'
import { useAuthStore } from '../../store/authStore'
import { MAINSHIP_ADDITIONAL_ENABLED } from '../map/osnReleaseGates'
import { Button, Card, CardHeader, Icon } from '../../components/ui'
import {
  deriveFirstOrders,
  firstOrdersComplete,
  firstOrdersDismissKey,
  projectFirstOrders,
} from './firstOrders'

// OB-1 (plan §C P10) — the "First Orders" checklist card, mounted at the TOP of CommandScreen's
// main rail (the first thing a new player sees). READ-ONLY: it renders deriveFirstOrders over the
// shell's already-polled state — zero fetches of its own, zero writes, zero new server surface.
// It self-hides when every visible step is done (nothing left to order) and can be dismissed.
//
// DISMISSAL — the codebase's first client-side persistence (grep confirmed no prior localStorage
// use). Scope kept deliberately minimal: ONE per-user, versioned boolean key (firstOrdersDismissKey)
// holding '1'; reads/writes are try/catch-guarded so a blocked storage (private mode, disabled
// cookies) degrades to a session-only dismissal. Game state itself is never persisted client-side —
// dismissal is pure UI preference, exactly the boundary the P10 guard draws ("onboarding reads game
// state; it never grants").

function readDismissed(key: string): boolean {
  try {
    return window.localStorage.getItem(key) === '1'
  } catch {
    return false
  }
}

function writeDismissed(key: string): void {
  try {
    window.localStorage.setItem(key, '1')
  } catch {
    /* storage unavailable → dismissal lives only for this session's state */
  }
}

export function FirstOrdersCard() {
  const { game, combat, map, selection } = useShellState()
  const userId = useAuthStore((s) => s.user?.id ?? null)
  // RequireAuth guarantees a stable user for this mount, so the key is fixed for the card's life;
  // lazy init reads storage exactly once (no effect, no flicker).
  const [dismissed, setDismissed] = useState(() => readDismissed(firstOrdersDismissKey(userId)))

  if (dismissed) return null
  // Don't flash a not-done checklist while the shell's first reads are still in flight.
  if (game.loading || selection.loading) return null

  const steps = deriveFirstOrders(
    projectFirstOrders({
      selectionShipCount: selection.ships.length,
      polledShipKnown: map.mainShip !== null,
      spatialState: map.mainShip?.spatial_state,
      reports: combat.reports,
      expeditionsLit: game.mainshipSendEnabled,
      additionalShipsLit: MAINSHIP_ADDITIONAL_ENABLED,
    }),
  )
  // All done → auto-hide (the checklist has nothing left to say; no storage write needed).
  if (firstOrdersComplete(steps)) return null

  const dismiss = () => {
    writeDismissed(firstOrdersDismissKey(userId))
    setDismissed(true)
  }

  return (
    <Card tone="accent" data-testid="first-orders-card">
      <CardHeader
        eyebrow="First orders"
        title="Welcome aboard, commander"
        subtitle="Your first session, step by step"
        aside={
          <Button variant="ghost" size="icon" aria-label="Dismiss checklist" onClick={dismiss}>
            <Icon name="close" size={16} />
          </Button>
        }
      />
      <ol className="space-y-2.5">
        {steps.map((step, i) => (
          <li
            key={step.id}
            data-testid={`first-orders-step-${step.id}`}
            className="flex items-start gap-3"
          >
            {/* Mono step designator; flips to a success tick when the server state says done. */}
            <span
              aria-hidden="true"
              className={`mt-0.5 w-6 shrink-0 text-center font-mono text-xs tabular-nums ${
                step.done ? 'text-success' : 'text-ink-faint'
              }`}
            >
              {step.done ? '✓' : String(i + 1).padStart(2, '0')}
            </span>
            <div className="min-w-0">
              <p className={`text-sm ${step.done ? 'text-ink-muted' : 'text-ink'}`}>
                {step.label}
                {step.done && <span className="sr-only"> — done</span>}
              </p>
              {/* The hint guides only the steps still ahead; done rows stay quiet. */}
              {!step.done && <p className="mt-0.5 text-xs text-ink-faint">{step.hint}</p>}
            </div>
          </li>
        ))}
      </ol>
    </Card>
  )
}
