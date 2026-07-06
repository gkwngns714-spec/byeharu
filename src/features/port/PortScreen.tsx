import { useShellState } from '../../app/shellState'
import { DockServicesPanel } from '../map/DockServicesPanel'
import { InvestmentPanel } from '../investment/InvestmentPanel'
import { MarketPanel } from '../map/MarketPanel'
import { useDockServices } from '../map/useDockServices'
import { isDocked } from '../map/dockServices'
import { useMainShipSelection } from '../map/useMainShipSelection'
import { TRADE_MARKET_ENABLED } from '../map/osnReleaseGates'
import { Card, PageHeader } from '../../components/ui'

// UI-REBUILD (2b) — the Port destination: docked-port surfaces only. Keyed off the SAME
// server-authoritative docked projection DockServicesPanel already uses (get_my_current_dock_services
// → isDocked): docked → services (+ dark market/investment behind their server-lit gates); NOT
// docked → a friendly empty state, never a broken/dead screen. Panel interiors relocated unchanged.
// NOTE for the Port interior slice: DockServicesPanel fetches the dock projection internally, so
// this screen's own useDockServices (for the empty-state branch) is a second read of the same tiny
// RPC per lifecycle change — consolidate to one read when the panel interior is rebuilt.

export function PortScreen() {
  const { map } = useShellState()
  const lifecycleKey = `${map.mainShip?.status ?? 'n'}|${map.mainShip?.spatial_state ?? 'n'}|${map.mainShipPresence?.location_id ?? 'none'}|${map.mainShipSpaceMovement?.id ?? 'none'}|${map.mainShipSpaceMovement?.status ?? 'none'}`
  const dock = useDockServices(lifecycleKey, { mainShipId: map.mainShip?.main_ship_id ?? null })
  // TRADE-UI-1 — selected-ship model for the DARK MarketPanel (compile-gated false + server-rejected).
  const shipSelection = useMainShipSelection()

  return (
    <div className="h-full overflow-y-auto">
      <div className="mx-auto max-w-3xl space-y-4 px-4 py-4 sm:px-6">
        <PageHeader title="Port" subtitle="Dock services & trade" />
        {!isDocked(dock) ? (
          // Friendly empty state (server says not docked) — the Port has nothing to offer in space.
          <Card data-testid="port-not-docked" className="text-center">
            <p className="text-2xl" aria-hidden>⚓</p>
            <p className="mt-2 text-sm font-medium text-ink">Not docked</p>
            <p className="mt-1 text-sm text-ink-muted">
              Dock at a port to access its services. Pick a port on the Map and travel there.
            </p>
          </Card>
        ) : (
          <>
            {/* PHASE 9 — read-only docked-port context (port + its active services). */}
            <DockServicesPanel lifecycleKey={lifecycleKey} mainShipId={map.mainShip?.main_ship_id ?? null} />
            {/* LOCATION-INVEST-P18 (dark, server-lit only): docked-port investment. Renders null
                unless the server lit get_location_development, so production is byte-unchanged. */}
            <InvestmentPanel
              lifecycleKey={lifecycleKey}
              locationId={map.mainShipPresence?.location_id ?? null}
              mainShipId={map.mainShip?.main_ship_id ?? null}
            />
            {/* TRADE-MARKET-1 (dark, compile-gated false + server-rejected): buy/sell at the docked port. */}
            {TRADE_MARKET_ENABLED && (
              <MarketPanel key={shipSelection.selectedShipId ?? 'none'} selectedShip={shipSelection.selectedShip} />
            )}
          </>
        )}
      </div>
    </div>
  )
}
