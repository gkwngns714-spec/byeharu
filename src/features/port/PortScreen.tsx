import { useMemo, useState } from 'react'
import { useShellState } from '../../app/shellState'
import { DockedPortCard } from './DockedPortCard'
import { HaulBoardPanel } from './HaulBoardPanel'
import { PortPickerPanel } from './PortPickerPanel'
import { SalvageMarketPanel } from './SalvageMarketPanel'
import { RepairPanel } from './RepairPanel'
import { ShipyardPanel } from './ShipyardPanel'
import { StationHangar } from './StationHangar'
import { derivePortsWithShips, portOfShip, resolveChosenShipId } from './portPicker'
import { InvestmentPanel } from '../investment/InvestmentPanel'
import { MarketPanel } from '../map/MarketPanel'
import { ModulesPanel } from '../modules/ModulesPanel'
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

  // PORT-HUB — the Port tab is a HUB you drive by picking a port where you have docked ships. The ports
  // are derived from the whole-fleet position projection (get_my_fleet_positions, 0200 — REUSED via
  // map.fleetPositions; no new fetcher), grouped by port and named from the world map. A ship in transit
  // or open space is NOT a port entry (honest — you can't act at a port you're not at). This is purely
  // ADDITIVE: in a dark / pre-flip env fleetPositions is [] (the same data-dark gate as its map layer),
  // so `ports` is empty, `chosenShipId` falls to null → the RPC's sole-ship shim, and the screen behaves
  // byte-identically to before the picker existed.
  const portNames = useMemo(() => {
    const m: Record<string, string> = {}
    for (const loc of map.locations) m[loc.id] = loc.name
    return m
  }, [map.locations])
  const ports = useMemo(
    () => derivePortsWithShips(map.fleetPositions, (id) => portNames[id]),
    [map.fleetPositions, portNames],
  )

  // The player's explicit pick (null = follow the default). Effective acting ship = the pick if it is
  // still docked, else the shared selected ship if docked, else the FIRST docked ship (one docked ship →
  // auto-selected, no forced picking). Null when nothing is docked (→ the sole-ship shim / empty state).
  const [pickedShipId, setPickedShipId] = useState<string | null>(null)
  const preferredShipId = pickedShipId ?? shipSelection.selectedShipId ?? map.mainShip?.main_ship_id ?? null
  const chosenShipId = resolveChosenShipId(ports, preferredShipId)

  // The lifecycle refetch key now leads with the CHOSEN ship: switching the picked port/ship re-reads the
  // dock context (useDockServices also refetches on its mainShipId dep) and every lifecycleKey-keyed panel
  // (store, Workshop, salvage, shipyard, invest, haul). The main-ship lifecycle fields ride along so a
  // status/movement transition still ticks a refetch as before.
  // (4C-CLIENT: the legacy spatial_state / space-movement fields left the key with the schema they read.)
  const lifecycleKey = `${chosenShipId ?? 'none'}|${map.mainShip?.status ?? 'n'}|${map.mainShipPresence?.location_id ?? 'none'}`
  const dock = useDockServices(lifecycleKey, { mainShipId: chosenShipId })
  // MAP-INTEGRATION M3 — the chosen ship's BERTHED read (from the same fleet-positions row the port
  // list derives from). A berthed ship is AT its port (so it lists above, consistent with the
  // Fitting tab's "Docked at <port>") but is not at_location server-side until 4c — every paid dock
  // service answers not-docked. The berthed branch below says so honestly (the fitgate-honesty
  // posture: never offer an action that will 100%-fail) instead of the misleading "No docked ships".
  const chosenPos = map.fleetPositions.find((p) => p.main_ship_id === chosenShipId)
  const chosenBerthPort = chosenPos?.place === 'berthed' ? portOfShip(ports, chosenShipId) : null
  const chosenBerthShipName = chosenBerthPort?.ships.find((s) => s.mainShipId === chosenShipId)?.name ?? 'This ship'
  // STATION-STORAGE — the docked port's own hangar (dark by default; server returns empty while the flag is off).
  const store = useDockStore(lifecycleKey)
  // TRADE-UI-1 — selected-ship model for the DARK MarketPanel, now the ONE shell instance (A0 lifted it; Ship
  // reads the SAME selection). Compile-gated false + server-rejected today.

  // UI R3 (composition): desktop ops split — main rail = the port's identity/services card + the
  // Workshop (WORKSHOP: module craft & fit — port-docked work, see below) + the dark market (the
  // trade surface belongs beside the port, not under the hangar); aside rail =
  // the storage/economy surfaces (Hangar, Investment — both dark today). With every aside child
  // null, the rail self-collapses (`empty:hidden`) and the docked-port card takes the full row —
  // no production hole. The not-docked EmptyState stays a single centered focus card (no split:
  // there is deliberately nothing else on that screen state).
  return (
    <Screen wide>
      <PageHeader eyebrow="Ops · Dock" title="Port" subtitle="Dock services & trade" />
      {/* PORT-HUB — the port picker: pick which of your docked ports to act at. Renders only when you
          have at least one docked ship; one ship → its port shows here (highlighted), no forced pick.
          The chosen (port, ship) drives the dock context + every action panel below. */}
      <PortPickerPanel ports={ports} chosenShipId={chosenShipId} onPick={setPickedShipId} />
      {!isDocked(dock) ? (
        chosenBerthPort ? (
          // M3 — the chosen ship is BERTHED here (listed above, consistent with the Fitting tab),
          // but berthed ships can't use paid dock services until 4c makes them at_location
          // server-side. Say so honestly (the fitgate-honesty posture) — never "No docked ships"
          // over a ship the picker just listed, and never a service button that 100%-fails.
          <EmptyState
            data-testid="port-berthed-ship"
            className="mx-auto w-full max-w-3xl"
            icon={<Icon name="anchor" size={28} />}
            title={`Berthed at ${chosenBerthPort.locationName}`}
            body={
              <>
                <p>
                  {chosenBerthShipName} is berthed at {chosenBerthPort.locationName} — moored on its own,
                  not docked with a fleet.
                </p>
                <p className="mt-2 text-xs text-ink-faint">
                  Berthed ships can't use paid dock services yet. Assign the ship to a fleet in{' '}
                  <span className="text-ink">Command</span>, or dock a fleet at this port, to put its
                  services to work.
                </p>
              </>
            }
          />
        ) : (
          // Honest empty state: none of your ships are at a port to act from (or the chosen ship
          // isn't docked). M2 copy reconcile: ships move as FLEETS (the unified mover) — a player
          // with no fleet cannot "send a ship from the Map", so the guidance names the real order
          // of operations (Command → fleet → Map) instead of pointing them in a circle.
          <EmptyState
            data-testid="port-not-docked"
            className="mx-auto w-full max-w-3xl"
            icon={<Icon name="anchor" size={28} />}
            title="No docked ships"
            body={
              <>
                <p>None of your ships are docked at a port right now.</p>
                <p className="mt-2 text-xs text-ink-faint">
                  Ships travel as fleets: send a fleet to a port from the{' '}
                  <span className="text-ink">Map</span> and this screen opens up with its trade, build,
                  and other services. No fleet yet? Create one in{' '}
                  <span className="text-ink">Command</span> and add your ships to it first.
                </p>
              </>
            }
          />
        )
      ) : (
        <div className={screenSplitClass()}>
          <div className={screenRailClass('main')}>
            {/* The docked-port surface (identity → right now → service details). */}
            <DockedPortCard dock={dock} />
            {/* WORKSHOP — module CRAFTING (non-spatial, 0109: player-scoped, no settled
                precondition — reachable wherever the ship is docked). S6: the fit/unfit EDIT
                surface moved to the Fitting tab's per-ship detail (FittingDetail — the ONE
                fitting-edit surface; its enable derives from the ship's own fleet-positions row
                and the server's 0114 settled-safe rule stays the enforcer), so this panel is
                crafting only. Server-lit only, with the Workshop label rendered inside its lit
                branch so a dark read never leaves a label over a void. No onChanged wiring: no
                sibling on this screen reads the player inventory, and the Fitting tab's readers
                refetch on route remount — screens unmount on navigation. */}
            <ModulesPanel lifecycleKey={lifecycleKey} sectionLabel="Workshop" />
            {/* TRADE-MARKET-1 (dark, compile-gated false + server-rejected): buy/sell at the docked port. */}
            {TRADE_MARKET_ENABLED && (
              <MarketPanel key={shipSelection.selectedShipId ?? 'none'} selectedShip={shipSelection.selectedShip} />
            )}
            {/* SALVAGE-2 (dark, flag-gated): the port's item buy-desk — the SECOND market surface
                (items→credits beside MarketPanel's cargo goods), so it rides the main rail with the
                trade family; the aside keeps the storage/economy surfaces. No read RPC exists for
                salvage (0174: port_item_demand is public-read Reference/Config), so the panel gates
                itself on the server's own salvage_market_enabled flag read honestly from
                PUBLIC-READ game_config (the getCommissionConfigRows posture) — flag false
                (production today) → renders null, so production is byte-unchanged. locationId is
                the SERVER dock projection (this docked branch). */}
            <SalvageMarketPanel
              lifecycleKey={lifecycleKey}
              locationId={dock.locationId}
              mainShipId={chosenShipId}
            />
            {/* SHIPYARD-3 (dark, flag-gated): the hull build order desk — a port SERVICE sibling
                on the main rail beside the trade family. No read RPC exists for the shipyard
                (0185/0188: the recipe catalog is public-read Reference/Config), so the panel
                gates itself on the server's own shipyard_enabled flag read honestly from
                PUBLIC-READ game_config (the SalvageMarketPanel posture) — flag false (production
                today) → renders null, so production is byte-unchanged. locationId is the SERVER
                dock projection (this docked branch). ORDER side only — cancel is the SHIPYARD-2
                seam (see the panel header). */}
            <ShipyardPanel
              lifecycleKey={lifecycleKey}
              locationId={dock.locationId}
              mainShipId={chosenShipId}
            />
            {/* REPAIR-ECON (dark, flag-gated): the paid hull-repair desk — a ship-recovery SERVICE on
                the main rail. No read RPC exists for repair (0201), so the panel gates itself on the
                server's own repair_economy_enabled flag read honestly from PUBLIC-READ game_config (the
                SalvageMarketPanel posture) — flag false (production today) → renders null, so production
                is byte-unchanged. THE SEAM: a destroyed ship shows the free-recovery note here, never a
                paid Repair button (the free repair_main_ship safelock handles destroyed ships).
                locationId is the SERVER dock projection (this docked branch). */}
            <RepairPanel
              lifecycleKey={lifecycleKey}
              locationId={dock.locationId}
              mainShipId={chosenShipId}
            />
          </div>
          <div className={screenRailClass('aside')}>
            {/* STATION-STORAGE — this port's own hangar (per-port, per-player storage). Dark by default:
                get_my_docked_store returns empty while station_storage_enabled is off → renders null. */}
            <StationHangar store={store} />
            {/* LOCATION-INVEST-P18 (dark, server-lit only): docked-port investment. Renders null
                unless the server lit get_location_development, so production is byte-unchanged. */}
            <InvestmentPanel
              lifecycleKey={lifecycleKey}
              locationId={dock.locationId}
              mainShipId={chosenShipId}
            />
            {/* HAUL-3 (dark, server-lit only): the port contract bulletin. Renders null unless the
                server lit get_port_contracts (haul_contracts_disabled while dark) — production is
                byte-unchanged. locationId is the SERVER dock projection (this docked branch). */}
            <HaulBoardPanel
              lifecycleKey={lifecycleKey}
              locationId={dock.locationId}
              mainShipId={chosenShipId}
            />
          </div>
        </div>
      )}
    </Screen>
  )
}
