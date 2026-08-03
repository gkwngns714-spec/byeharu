import { useCallback, useMemo, useState } from 'react'
import { useShellState } from '../../app/shellState'
import { DockedPortCard } from './DockedPortCard'
import { HaulBoardPanel } from './HaulBoardPanel'
import { PortPickerPanel } from './PortPickerPanel'
import { SalvageMarketPanel } from './SalvageMarketPanel'
import { ShopPanel } from './ShopPanel'
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

  // ONE SELECTION AUTHORITY (repair-where-you-are): a pick here IS the shell selection
  // (selection.selectShip — the same model the Fitting tab reads), so both tabs always agree on
  // which ship is being commanded; the old Port-local pickedShipId (a second selection model that
  // never told the shell) is DELETED. Effective acting ship = the shared selected ship if it is at
  // a port, else the FIRST docked ship (resolveChosenShipId stays the one validator of a
  // preference against the at-port set). Null when nothing is docked (→ the empty state).
  const preferredShipId = shipSelection.selectedShipId ?? map.mainShip?.main_ship_id ?? null
  const chosenShipId = resolveChosenShipId(ports, preferredShipId)
  // TRADE-MOUNT — the acting ship as a SelectableShip row (name + cargo_capacity_m3), taken from the
  // shell's ONE ship list. MarketPanel used to be handed `shipSelection.selectedShip` directly while
  // every other panel on this screen acted on `chosenShipId` — two acting ships on one screen. That
  // diverges the moment the shared selection points at a ship that is NOT at a port (a pick made on
  // the Fitting tab): resolveChosenShipId falls back to a docked ship for the dock read, the shop,
  // salvage, the shipyard and the contract board, while the market alone addressed the undocked one
  // and answered `not_docked` — a market that says "not available here" on a screen whose every other
  // panel is working. One acting ship per screen, and it is the one the picker resolved.
  const chosenShip = shipSelection.ships.find((s) => s.main_ship_id === chosenShipId) ?? null

  // The lifecycle refetch key now leads with the CHOSEN ship: switching the picked port/ship re-reads the
  // dock context (useDockServices also refetches on its mainShipId dep) and every lifecycleKey-keyed panel
  // (store, Workshop, salvage, shipyard, invest, haul). The main-ship lifecycle fields ride along so a
  // status/movement transition still ticks a refetch as before.
  // (4C-CLIENT: the legacy spatial_state / space-movement fields left the key with the schema they read.)
  // TRADE-MOUNT — a completed market trade is a lifecycle event for this screen, not just for the
  // market. The contract board reads the SAME ship's cargo lots to render "hold 3/29" and to enable
  // Deliver; buying the haul at the origin used to leave that line reading the pre-purchase hold
  // until the screen remounted, i.e. the surface that tells you whether you can fulfil a contract
  // lied immediately after the one action that changes the answer. Rather than add a second refresh
  // path between two sibling panels, the trade bumps the ONE refetch trigger every panel here
  // already keys off (the lifecycleKey idiom) — compose the existing primitive, no new wiring.
  const [cargoEpoch, setCargoEpoch] = useState(0)
  const onCargoChanged = useCallback(() => setCargoEpoch((n) => n + 1), [])
  const lifecycleKey = `${chosenShipId ?? 'none'}|${map.mainShip?.status ?? 'n'}|${map.mainShipPresence?.location_id ?? 'none'}|c${cargoEpoch}`
  const dock = useDockServices(lifecycleKey, { mainShipId: chosenShipId })
  // MAP-INTEGRATION M3 — the chosen ship's BERTHED read (from the same fleet-positions row the port
  // list derives from). A berthed ship is AT its port (so it lists above, consistent with the
  // Fitting tab's "Docked at <port>") but is not at_location server-side until 4c — every paid dock
  // service answers not-docked. The berthed branch below says so honestly (the fitgate-honesty
  // posture: never offer an action that will 100%-fail) instead of the misleading "No docked ships".
  const chosenPos = map.fleetPositions.find((p) => p.main_ship_id === chosenShipId)
  const chosenBerthPort = chosenPos?.place === 'berthed' ? portOfShip(ports, chosenShipId) : null
  const chosenBerthShipName = chosenBerthPort?.ships.find((s) => s.mainShipId === chosenShipId)?.name ?? 'This ship'
  // STATION-STORAGE — the docked port's own hangar.
  // ITEMS-HAVE-A-PLACE (0333): the read now carries the CHOSEN ship, the same way the dock-services
  // read above always has. Without it the server's sole-ship shim resolved to NULL for anyone with
  // two or more ships and this card never rendered at all. `storageRevision` re-reads THIS port's
  // storage after a move; it is deliberately NOT folded into `lifecycleKey`, so moving an item does
  // not make every other panel on the screen refetch — but it BUILDS ON lifecycleKey, so TRADE-MOUNT's
  // cargoEpoch (and every other lifecycle trigger) still reaches the storage read unchanged.
  const [storageRevision, setStorageRevision] = useState(0)
  const storageKey = `${lifecycleKey}|s${storageRevision}`
  const store = useDockStore(storageKey, { mainShipId: chosenShipId })
  const onStorageChanged = useCallback(() => setStorageRevision((r) => r + 1), [])
  // UI R3 (composition): desktop ops split — main rail = the port's identity/services card + the
  // Workshop (WORKSHOP: module craft & fit — port-docked work, see below) + the market (the
  // trade surface belongs beside the port, not under the hangar); aside rail =
  // the storage/economy surfaces (Hangar, Investment — both dark today). With every aside child
  // null, the rail self-collapses (`empty:hidden`) and the docked-port card takes the full row —
  // no production hole. The not-docked EmptyState stays a single centered focus card (no split:
  // there is deliberately nothing else on that screen state).
  return (
    <Screen wide>
      <PageHeader eyebrow="Ops · Port" title="Port" subtitle="Port services & trade" />
      {/* PORT-HUB — the port picker: pick which of your docked ports to act at. Renders only when you
          have at least one docked ship; one ship → its port shows here (highlighted), no forced pick.
          The chosen (port, ship) drives the dock context + every action panel below. */}
      <PortPickerPanel ports={ports} chosenShipId={chosenShipId} onPick={shipSelection.selectShip} />
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
            title={`Docked at ${chosenBerthPort.locationName}`}
            body={
              <>
                {/* PLAIN-WORDS: "berthed"/"moored" was dockside jargon — say docked, and keep the
                    honest limit (a solo ship can't use paid port services until it joins a fleet). */}
                <p>
                  {chosenBerthShipName} is docked at {chosenBerthPort.locationName} on its own — it
                  isn&apos;t part of a fleet.
                </p>
                <p className="mt-2 text-xs text-ink-faint">
                  Ships docked on their own can't use paid port services yet. Add the ship to a fleet
                  on the <span className="text-ink">Fleet</span> tab, or dock a fleet at this port, to
                  use them.
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
                  <span className="text-ink">Map</span> and this screen opens up with its port services.
                  No fleet yet? Create one on the <span className="text-ink">Fleet</span> tab and add
                  your ships to it first.
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
            {/* WORKSHOP — module CRAFTING. 0333: crafting is SPATIAL now — it consumes the stock
                of the port this ship is DOCKED at, because that is where items live. The panel
                addresses `chosenShipId`, the SAME acting ship as every other panel on this screen.
                S6: the fit/unfit EDIT
                surface moved to the Fitting tab's per-ship detail (FittingDetail — the ONE
                fitting-edit surface; its enable derives from the ship's own fleet-positions row
                and the server's 0114 settled-safe rule stays the enforcer), so this panel is
                crafting only. Server-lit only, with the Workshop label rendered inside its lit
                branch so a dark read never leaves a label over a void. No onChanged wiring: no
                sibling on this screen reads the player inventory, and the Fitting tab's readers
                refetch on route remount — screens unmount on navigation. */}
            <ModulesPanel
              lifecycleKey={lifecycleKey}
              mainShipId={chosenShipId}
              sectionLabel="Workshop"
            />
            {/* TRADE-MARKET-1 (LIVE since 2026-08-03; server flag `trade_market_enabled` is lit and
                re-checked on every RPC): buy/sell the port's cargo goods. This is the ONLY player-
                reachable producer of ship_cargo_lots — the haul contract board below consumes them,
                so a trade here bumps the shared lifecycleKey and the board re-reads the hold. The
                panel addresses `chosenShip`, the SAME acting ship as every other panel on this
                screen (see the derivation above) — never the raw shell selection. */}
            {TRADE_MARKET_ENABLED && (
              <MarketPanel key={chosenShipId ?? 'none'} selectedShip={chosenShip} onCargoChanged={onCargoChanged} />
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
            {/* REPAIR-WHERE-YOU-ARE — the paid hull-repair desk MOVED to the Fitting detail's
                condition block (its ONE mount: the surface that shows per-ship hull damage is the
                surface that mends it; the RPC never needed this screen's dock projection — it
                resolves the dock server-side). The DockedPortCard service row above says where. */}
            {/* PORT-SHOP (dark, flag-gated): the port outfitter — buy entry-level fitting modules +
                ammo for credits. A port SERVICE on the main rail beside repair/salvage. Unlike those,
                the shop has its OWN gated read RPC (get_port_shop, 0235) which rejects
                port_shop_disabled before any read, so the panel reads its lit/dark signal straight
                from that RPC — flag false (production today) → renders null, so production is
                byte-unchanged. Bought modules land in the fittable module pool (module_instances);
                bought ammo lands in inventory. locationId is the SERVER dock projection. */}
            <ShopPanel
              lifecycleKey={lifecycleKey}
              locationId={dock.locationId}
              mainShipId={chosenShipId}
            />
          </div>
          <div className={screenRailClass('aside')}>
            {/* STATION-STORAGE + ITEMS-HAVE-A-PLACE (0333) — this port's own storage AND the one
                surface that moves items between it and the ship's hold. Both halves live in one
                card because the verb is a move BETWEEN them. Renders null unless the ship is
                docked at a storable port (get_my_docked_store returns empty otherwise). */}
            <StationHangar
              store={store}
              mainShipId={chosenShipId}
              refreshKey={storageKey}
              onChanged={onStorageChanged}
            />
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
