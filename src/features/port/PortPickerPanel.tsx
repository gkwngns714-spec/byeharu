import type { PortWithShips } from './portPicker'
import { Badge, Card, SectionLabel } from '../../components/ui'

// PORT-HUB — the port picker: the Port screen's hub control. Lists every port where the player
// currently has a docked ship (derivePortsWithShips over the whole-fleet projection) and lets them
// pick which port to act at — trade, build, and the other server-lit services below all follow the
// pick. Picking a port commands its FIRST docked ship by default; when more than one of your ships is
// berthed at the chosen port, a ship sub-picker appears so you choose which one acts. Pure
// presentation over the derived list — the server stays the authority for the actual dock context.
//
// Renders nothing when there are no docked ports (PortScreen shows the empty state instead). With one
// docked ship its single port still shows here (highlighted) — no forced picking, just confirmation.

export function PortPickerPanel({
  ports,
  chosenShipId,
  onPick,
}: {
  ports: PortWithShips[]
  chosenShipId: string | null
  onPick: (shipId: string) => void
}) {
  if (ports.length === 0) return null

  return (
    <Card data-testid="port-picker" className="mx-auto w-full max-w-3xl">
      <SectionLabel>Your docked ports</SectionLabel>
      <p className="mt-0.5 text-sm text-ink-muted">
        Pick a port where your ships are docked to use its services.
      </p>
      <ul className="mt-3 space-y-1.5">
        {ports.map((port) => {
          const active = port.ships.some((s) => s.mainShipId === chosenShipId)
          const shipCount = port.ships.length
          return (
            <li key={port.locationId}>
              <button
                type="button"
                data-testid={`port-pick-${port.locationId}`}
                aria-pressed={active}
                // Picking a port commands its first docked ship — unless one of its ships is ALREADY
                // the chosen ship (keep that pick; the sub-picker below switches between them).
                onClick={() => {
                  if (!active) onPick(port.ships[0].mainShipId)
                }}
                className={`flex w-full items-center justify-between gap-3 rounded-lg border px-3 py-2 text-left transition-colors ${
                  active
                    ? 'border-accent/40 bg-accent/10 text-ink'
                    : 'border-edge bg-surface-2/40 text-ink hover:border-accent/30 hover:bg-surface-2/70'
                }`}
              >
                <span className="min-w-0 truncate font-medium">{port.locationName}</span>
                <span className="flex shrink-0 items-center gap-2">
                  <span className="text-xs text-ink-faint">
                    {shipCount} {shipCount === 1 ? 'ship' : 'ships'}
                  </span>
                  {active && <Badge tone="accent">Selected</Badge>}
                </span>
              </button>

              {/* Multiple of your ships at the CHOSEN port → pick which one acts (default: the first). */}
              {active && shipCount > 1 && (
                <div className="mt-1.5 flex flex-wrap gap-1.5 pl-3">
                  {port.ships.map((s) => {
                    const on = s.mainShipId === chosenShipId
                    return (
                      <button
                        key={s.mainShipId}
                        type="button"
                        data-testid={`port-ship-${s.mainShipId}`}
                        aria-pressed={on}
                        onClick={() => onPick(s.mainShipId)}
                        className={`rounded border px-2 py-1 text-xs transition-colors ${
                          on
                            ? 'border-accent/40 bg-accent/10 text-ink'
                            : 'border-edge bg-surface-2/40 text-ink-muted hover:border-accent/30 hover:text-ink'
                        }`}
                      >
                        {s.name}
                      </button>
                    )
                  })}
                </div>
              )}
            </li>
          )
        })}
      </ul>
    </Card>
  )
}
