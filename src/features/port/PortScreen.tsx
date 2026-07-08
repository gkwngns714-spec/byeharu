import { useShellState } from '../../app/shellState'
import { DockedPortCard } from './DockedPortCard'
import { StationHangar } from './StationHangar'
import { InvestmentPanel } from '../investment/InvestmentPanel'
import { MarketPanel } from '../map/MarketPanel'
import { useDockServices } from '../map/useDockServices'
import { useDockStore } from '../map/useDockStore'
import { isDocked } from '../map/dockServices'
import { useMainShipSelection } from '../map/useMainShipSelection'
import { TRADE_MARKET_ENABLED } from '../map/osnReleaseGates'
import { Card, PageHeader } from '../../components/ui'

// UI-REBUILD (2b, Port interior) — the Port destination, in the Ship-established design language.
// ONE server dock read (useDockServices — the same server-authoritative projection the old
// DockServicesPanel used; that panel's fold into DockedPortCard removed the double read) drives
// the whole screen: docked → the port card (identity → right-now → service details) plus the
// server-lit action panels; not docked → one clear, friendly empty state — never a broken screen.
// Dark panels keep their gates verbatim: surfaced only when lit, omitted otherwise. No flag read
// differently, no command logic changed — presentation only.

export function PortScreen() {
  const { map } = useShellState()
  const lifecycleKey = `${map.mainShip?.status ?? 'n'}|${map.mainShip?.spatial_state ?? 'n'}|${map.mainShipPresence?.location_id ?? 'none'}|${map.mainShipSpaceMovement?.id ?? 'none'}|${map.mainShipSpaceMovement?.status ?? 'none'}`
  const dock = useDockServices(lifecycleKey, { mainShipId: map.mainShip?.main_ship_id ?? null })
  // STATION-STORAGE — the docked port's own hangar (dark by default; server returns empty while the flag is off).
  const store = useDockStore(lifecycleKey)
  // TRADE-UI-1 — selected-ship model for the DARK MarketPanel (compile-gated false + server-rejected).
  const shipSelection = useMainShipSelection()

  return (
    <div className="h-full overflow-y-auto">
      <div className="mx-auto max-w-3xl space-y-4 px-4 py-4 sm:px-6">
        <PageHeader title="Port" subtitle="Dock services & trade" />
        {!isDocked(dock) ? (
          // Friendly empty state (the server says not docked) — the Port has nothing to offer in space.
          <Card data-testid="port-not-docked">
            <div className="flex items-start justify-between gap-3">
              <div>
                <h2 className="text-lg font-semibold text-ink">Not docked</h2>
                <p className="mt-0.5 text-sm text-ink-muted">Dock at a port to access its services.</p>
              </div>
              <p className="text-2xl" aria-hidden>⚓</p>
            </div>
            <p className="mt-3 text-xs text-ink-faint">
              Pick a port on the <span className="text-ink">Map</span> and travel there — this screen
              opens up once you're docked.
            </p>
          </Card>
        ) : (
          <>
            {/* The docked-port surface (identity → right now → service details). */}
            <DockedPortCard dock={dock} />
            {/* STATION-STORAGE — this port's own hangar (per-port, per-player storage). Dark by default:
                get_my_docked_store returns empty while station_storage_enabled is off → renders null. */}
            <StationHangar store={store} />
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
