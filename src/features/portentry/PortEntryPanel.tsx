import { useRef } from 'react'
import { usePortEntry, type UsePortEntryOverrides } from './usePortEntry'
import type { PortEntryActionKind } from './portEntryCommand'
import { Card, Button, Notice } from '../../components/ui'

// PORT-ENTRY player UI — the single onboarding surface for the caller's OWN main ship.
//
// Renders exactly ONE affordance derived from server-authoritative state (the ship's
// get_my_fleet_positions `place` — 4C-CLIENT repointed this off the retired spatial_state column,
// and the legacy "Finish Docking" / waypoint arms left with the extinct legacy_present state):
//   • no ship             → "Claim First Ship"  (commission_first_main_ship)
//   • docked / berthed    → nothing (the ordinary docked experience is the Port destination's DockedPortCard)
//   • hidden (idle)       → a read-only explanation (travel to a port)
//   • transit / in_space / destroyed / indeterminate → a read-only safe explanation, no action
//
// The action is zero-arg and auth.uid()-scoped; the client sends no ids/coords/status. Duplicate
// submits are prevented (a synchronous ref guard + the controller's single-in-flight phase guard); the button
// is disabled while working. On success the panel re-reads authoritative state and notifies the parent. It
// NEVER fabricates eligibility or performs a client-side transition — the server is the sole authority.

export function PortEntryPanel({ deps }: { deps?: UsePortEntryOverrides }) {
  const pe = usePortEntry(deps)
  const { affordance, phase, actionKind, message } = pe
  const busy = phase === 'submitting'
  const sendingRef = useRef(false)

  async function run(kind: PortEntryActionKind) {
    if (sendingRef.current) return // synchronous duplicate-click guard (belt-and-suspenders with the controller)
    sendingRef.current = true
    try {
      await pe.submit(kind)
    } finally {
      sendingRef.current = false
    }
  }

  // A successful action persists a brief confirmation until dismissed (the affordance underneath has already
  // moved to 'docked' → null, so without this the success would vanish instantly).
  if (phase === 'success') {
    return (
      <div data-testid="port-entry-panel">
        <Card tone="success" className="text-sm text-success" data-testid="port-entry-success">
          <p data-testid="port-entry-success-message">{message}</p>
          <Button size="sm" data-testid="port-entry-success-dismiss" onClick={() => pe.reset()} className="mt-3">
            Done
          </Button>
        </Card>
      </div>
    )
  }

  const errorText = phase === 'error' ? message : null

  switch (affordance.kind) {
    case 'commission':
      return (
        <div data-testid="port-entry-panel">
          <Card tone="accent" className="text-sm" data-testid="port-entry-claim">
            <p className="font-medium text-accent">Commission your first ship</p>
            <p className="mt-1 text-ink-muted">
              Claim your ship. It will begin docked at <span className="font-medium text-ink">Haven</span>, ready to explore.
            </p>
            {/* UI R4: the ONE error callout (Notice) instead of a hand-rolled line — same testid/string. */}
            {errorText && actionKind === 'commission' && (
              <Notice tone="danger" data-testid="port-entry-error" className="mt-2">{errorText}</Notice>
            )}
            <Button
              variant="primary"
              data-testid="port-entry-claim-button"
              busy={busy}
              busyLabel="Claiming…"
              onClick={() => void run('commission')}
              className="mt-3"
            >
              Claim First Ship
            </Button>
          </Card>
        </div>
      )

    case 'at_home':
      return (
        <div data-testid="port-entry-panel">
          <Card className="text-sm text-ink-muted" data-testid="port-entry-at-home">
            <p className="font-medium text-ink">Ship not yet docked</p>
            <p className="mt-1">
              Your ship hasn't docked yet. Travel to a port to dock there.
            </p>
          </Card>
        </div>
      )

    case 'in_transit':
      return (
        <div data-testid="port-entry-panel">
          <Card className="text-sm text-ink-muted" data-testid="port-entry-in-transit">
            <p className="font-medium text-ink">Ship in transit</p>
            <p className="mt-1">Your ship is travelling. It can be docked once it has arrived at a port.</p>
          </Card>
        </div>
      )

    case 'unavailable': {
      const detailText =
        affordance.detail === 'destroyed'
          ? 'Your ship needs to be repaired before it can be docked.'
          : affordance.detail === 'in_space'
            ? 'Your ship is parked in open space. Travel to a port before it can be docked.'
            : 'Your ship is not in a state where it can be docked right now.'
      return (
        <div data-testid="port-entry-panel">
          <Card className="text-sm text-ink-muted" data-testid="port-entry-unavailable">
            <p className="font-medium text-ink">Docking unavailable</p>
            <p className="mt-1">{detailText}</p>
          </Card>
        </div>
      )
    }

    // 'loading' (not yet read) and 'docked' (ordinary docked experience elsewhere) render nothing.
    default:
      return null
  }
}
