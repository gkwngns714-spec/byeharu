import { useDockServices } from './useDockServices'
import { isDocked, type DockServices } from './dockServices'

// PHASE 9 — read-only docked-port context for the player's MAIN SHIP. Renders ONLY when the server reports the
// main ship is docked at a port (state='at_location'); it shows that port and its ACTIVE explicit services.
// It is NOT a port-action surface: there are no buy/sell/repair/refit/recruitment controls, no prices, no
// cargo — those arrive with their own systems. It never shows a "home port" and never derives a dock from
// names/coordinates/affiliation; the server is the sole authority (free-port law: current dock + capability).
// With today's data this normally shows "Docking" only.

const SERVICE_LABELS: Record<string, string> = {
  docking: 'Docking',
  market: 'Market',
  repair: 'Repair',
  refit: 'Refit',
  recruitment: 'Recruitment',
}

export function DockServicesPanel({
  lifecycleKey,
  mainShipId = null,
  deps,
}: {
  // Re-validates the dock surface whenever the main-ship lifecycle changes.
  lifecycleKey: string
  // TRADE-FLEET-0C §2.5: the current/sole main-ship id, threaded to the dock read as an explicit
  // p_main_ship_id. Optional (defaults null → server sole-ship shim → behavior-identical while single-ship).
  mainShipId?: string | null
  // Injection seam for tests; defaults to the real authenticated server read.
  deps?: { fetcher?: () => Promise<DockServices> }
}) {
  const dock = useDockServices(lifecycleKey, { mainShipId, fetcher: deps?.fetcher })

  // Not docked (in transit / in space / destroyed / no ship / home / legacy / contradictory) → no port surface.
  if (!isDocked(dock)) return null

  return (
    <div
      data-testid="dock-services-panel"
      // Top-right; capped to under half the viewport so it never overlaps the top-left OSN PortNav panel on
      // narrow mobile widths (both can show at once while docked). Name truncates rather than overflowing.
      // UX-CLEANUP item 5: design-system tokens (success tone = the "safely docked" state), matching the
      // compact map-overlay idiom (token-styled container, primitives for interactive elements).
      className="pointer-events-auto absolute right-2 top-2 z-10 w-56 max-w-[calc(50vw-0.75rem)] rounded-lg border border-success/25 bg-surface/90 p-2 text-ink shadow-card"
    >
      <p data-testid="dock-services-title" className="truncate text-[11px] font-medium text-success">
        Main ship docked at {dock.locationName ?? 'this port'}
      </p>
      {dock.services.length > 0 ? (
        <ul data-testid="dock-services-list" className="mt-1 flex flex-wrap gap-1">
          {dock.services.map((s) => (
            <li
              key={s}
              data-testid={`dock-service-${s}`}
              className="rounded bg-surface-2 px-2 py-0.5 text-[10px] text-ink-muted"
            >
              {SERVICE_LABELS[s] ?? s}
            </li>
          ))}
        </ul>
      ) : (
        <p data-testid="dock-services-none" className="mt-1 text-[10px] text-ink-faint">
          No services available at this port yet.
        </p>
      )}
    </div>
  )
}
