import { useRef } from 'react'
import { usePortEntry, type UsePortEntryOverrides } from './usePortEntry'
import type { PortEntryKnownLocation } from './portEntry'
import { isDockablePortForDisplay } from '../map/mapTypes'
import type { PortEntryActionKind } from './portEntryCommand'
import { Card, Button } from '../../components/ui'

// PORT-ENTRY player UI — the single onboarding / finish-docking surface for the caller's OWN main ship.
//
// Renders exactly ONE affordance derived from server-authoritative state:
//   • no ship            → "Claim First Ship"  (commission_first_main_ship)
//   • legacy_present at a dockable port → "Finish Docking" (normalize_main_ship_dock)
//   • legacy_present at a non-dock waypoint → a read-only explanation (no doomed docking button;
//     display-classified via isDockablePortForDisplay — the server target_legal stays the authority)
//   • at_location        → nothing (the ordinary docked experience is the Port destination’s DockedPortCard)
//   • home / legacy_home → a read-only explanation (no in-place docking path exists yet — travel to a port)
//   • in_transit / in_space / destroyed / contradictory → a read-only safe explanation, no action
//
// The two actions are zero-arg and auth.uid()-scoped; the client sends no ids/coords/status. Duplicate
// submits are prevented (a synchronous ref guard + the controller's single-in-flight phase guard); the button
// is disabled while working. On success the panel re-reads authoritative state and notifies the parent. It
// NEVER fabricates eligibility or performs a client-side transition — the server is the sole authority.

export function PortEntryPanel({
  deps,
  locations,
}: {
  deps?: UsePortEntryOverrides
  // The parent's already-polled get_world_map list (Dashboard has it in scope) — display classification
  // only, no fetch here. Optional: omitted → the pre-existing affordance behavior.
  locations?: readonly PortEntryKnownLocation[]
}) {
  const pe = usePortEntry(deps, locations)
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
              Claim your main ship. It will begin docked at <span className="font-medium text-ink">Haven</span>, ready to explore.
            </p>
            {errorText && actionKind === 'commission' && (
              <p data-testid="port-entry-error" className="mt-2 text-danger">{errorText}</p>
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

    case 'normalize':
      return (
        <div data-testid="port-entry-panel">
          <Card tone="success" className="text-sm" data-testid="port-entry-finish-docking">
            <p className="font-medium text-success">Finish docking</p>
            <p className="mt-1 text-ink-muted">
              Your ship is at a port but not fully docked. Complete docking to use this port’s services.
            </p>
            {errorText && actionKind === 'normalize' && (
              <p data-testid="port-entry-error" className="mt-2 text-danger">{errorText}</p>
            )}
            <Button
              variant="primary"
              data-testid="port-entry-finish-docking-button"
              busy={busy}
              busyLabel="Docking…"
              onClick={() => void run('normalize')}
              className="mt-3"
            >
              Finish Docking
            </Button>
          </Card>
        </div>
      )

    case 'at_waypoint': {
      // Honest read-only state: holding position at a non-dock waypoint. Port names come from the SAME
      // classifier over the threaded world map — no hardcoded location names.
      const portNames = (locations ?? [])
        .filter((l) => isDockablePortForDisplay(l.location_type))
        .map((l) => l.name)
      const portHint = portNames.length > 0 ? ` (${portNames.join(', ')})` : ''
      return (
        <div data-testid="port-entry-panel">
          <Card className="text-sm text-ink-muted" data-testid="port-entry-at-waypoint">
            <p className="font-medium text-ink">Holding position at {affordance.locationName}</p>
            <p className="mt-1">
              This is a waypoint, not a port — there is no docking here. Travel to a port{portHint} to dock
              and use port services.
            </p>
          </Card>
        </div>
      )
    }

    case 'at_home':
      return (
        <div data-testid="port-entry-panel">
          <Card className="text-sm text-ink-muted" data-testid="port-entry-at-home">
            <p className="font-medium text-ink">Ship at home base</p>
            <p className="mt-1">
              Your ship is at your home base. Travel to a port before it can be docked there.
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
