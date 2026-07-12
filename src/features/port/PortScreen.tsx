import { useShellState } from '../../app/shellState'
import { DockedPortCard } from './DockedPortCard'
import { HaulBoardPanel } from './HaulBoardPanel'
import { StationHangar } from './StationHangar'
import { InvestmentPanel } from '../investment/InvestmentPanel'
import { MarketPanel } from '../map/MarketPanel'
import { useDockServices } from '../map/useDockServices'
import { useDockStore } from '../map/useDockStore'
import { isDocked } from '../map/dockServices'
import { TRADE_MARKET_ENABLED } from '../map/osnReleaseGates'
import { EmptyState, Icon, PageHeader, Screen, screenRailClass, screenSplitClass } from '../../components/ui'

// UI-REBUILD (2b, Port interior) — the Port destination, in the Ship-established design language.
// ONE server dock read (useDockServices — the same server-authoritative projection the old
// DockServicesPanel used; that panel's fold into DockedPortCard removed the double read) drives
// the whole screen: docked → the port card (identity → right-now → service details) plus the
// server-lit action panels; not docked → one clear, friendly empty state — never a broken screen.
// Dark panels keep their gates verbatim: surfaced only when lit, omitted otherwise. No flag read
// differently, no command logic changed — presentation only.

export function PortScreen() {
  const { map, selection: shipSelection } = useShellState()
  const lifecycleKey = `${map.mainShip?.status ?? 'n'}|${map.mainShip?.spatial_state ?? 'n'}|${map.mainShipPresence?.location_id ?? 'none'}|${map.mainShipSpaceMovement?.id ?? 'none'}|${map.mainShipSpaceMovement?.status ?? 'none'}`
  const dock = useDockServices(lifecycleKey, { mainShipId: map.mainShip?.main_ship_id ?? null })
  // STATION-STORAGE — the docked port's own hangar (dark by default; server returns empty while the flag is off).
  const store = useDockStore(lifecycleKey)
  // TRADE-UI-1 — selected-ship model for the DARK MarketPanel, now the ONE shell instance (A0 lifted it; Ship
  // reads the SAME selection). Compile-gated false + server-rejected today.

  // UI R3 (composition): desktop ops split — main rail = the port's identity/services card + the
  // dark market (the trade surface belongs beside the port, not under the hangar); aside rail =
  // the storage/economy surfaces (Hangar, Investment — both dark today). With every aside child
  // null, the rail self-collapses (`empty:hidden`) and the docked-port card takes the full row —
  // no production hole. The not-docked EmptyState stays a single centered focus card (no split:
  // there is deliberately nothing else on that screen state).
  return (
    <Screen wide>
      <PageHeader eyebrow="Ops · Dock" title="Port" subtitle="Dock services & trade" />
      {!isDocked(dock) ? (
        // Friendly empty state (the server says not docked) — the Port has nothing to offer in space.
        <EmptyState
          data-testid="port-not-docked"
          className="mx-auto w-full max-w-3xl"
          icon={<Icon name="anchor" size={28} />}
          title="Not docked"
          body={
            <>
              <p>Dock at a port to access its services.</p>
              <p className="mt-2 text-xs text-ink-faint">
                Pick a port on the <span className="text-ink">Map</span> and travel there — this screen
                opens up once you're docked.
              </p>
            </>
          }
        />
      ) : (
        <div className={screenSplitClass()}>
          <div className={screenRailClass('main')}>
            {/* The docked-port surface (identity → right now → service details). */}
            <DockedPortCard dock={dock} />
            {/* TRADE-MARKET-1 (dark, compile-gated false + server-rejected): buy/sell at the docked port. */}
            {TRADE_MARKET_ENABLED && (
              <MarketPanel key={shipSelection.selectedShipId ?? 'none'} selectedShip={shipSelection.selectedShip} />
            )}
          </div>
          <div className={screenRailClass('aside')}>
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
            {/* HAUL-3 (dark, server-lit only): the port contract bulletin. Renders null unless the
                server lit get_port_contracts (haul_contracts_disabled while dark) — production is
                byte-unchanged. locationId is the SERVER dock projection (this docked branch). */}
            <HaulBoardPanel
              lifecycleKey={lifecycleKey}
              locationId={dock.locationId}
              mainShipId={map.mainShip?.main_ship_id ?? null}
            />
          </div>
        </div>
      )}
    </Screen>
  )
}
