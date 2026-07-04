import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useGalaxyMapData } from './useGalaxyMapData'
import { GalaxyMap } from './GalaxyMap'
import { ExpeditionCommand } from './ExpeditionCommand'
import { MainShipPreview } from './MainShipPreview'
import { MainShipCommand } from './MainShipCommand'
import { PortNavPanel } from './PortNavPanel'
import { DockServicesPanel } from './DockServicesPanel'
import { MarketPanel } from './MarketPanel'
import { ShipSwitcher } from './ShipSwitcher'
import { useMainShipSelection } from './useMainShipSelection'
import { TRADE_MARKET_ENABLED } from './osnReleaseGates'
import { ExplorationPanel } from '../exploration/ExplorationPanel'
import { MiningPanel } from '../mining/MiningPanel'
import { ModulesPanel } from '../modules/ModulesPanel'

// Galaxy Map screen. Shows the world, the player's main ship, ports, and active movements; selecting a
// location opens its detail panel + the main-ship expedition/move surface. When the main ship is docked at a
// port, the read-only DockServicesPanel shows that port's active services.

export function GalaxyMapScreen() {
  const {
    loading, error, locations, meta, base, mainShip, movements, locationStates, baseUnits, unitTypes,
    mainshipSendEnabled, mainShipFleet, mainShipPresence, mainShipSpaceMovement, refresh,
  } = useGalaxyMapData()
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [showPreview, setShowPreview] = useState(false)
  // TRADE-UI-1 — client selected-ship model (retires the sole-ship shim). Consumed by the DARK MarketPanel;
  // auto-selects the sole ship today. The panel itself renders only behind the TRADE_MARKET_ENABLED gate.
  const shipSelection = useMainShipSelection()

  const selected = locations.find((l) => l.id === selectedId) ?? null
  const selMeta = selectedId ? meta[selectedId] : null
  const selState = selectedId ? locationStates[selectedId] : undefined

  return (
    <div data-testid="galaxy-map-screen" className="flex h-[100dvh] flex-col bg-slate-950 text-slate-100">
      <header className="flex items-center justify-between border-b border-slate-800 px-4 py-3">
        <div>
          <h1 className="text-lg font-semibold">Galaxy Map</h1>
          <p className="text-xs text-slate-400">Your main ship, ports, and expeditions</p>
        </div>
        <nav className="flex items-center gap-3 text-sm">
          <button
            data-testid="mainship-preview-toggle"
            onClick={() => setShowPreview((s) => !s)}
            className="rounded border border-sky-400/30 bg-sky-500/10 px-2.5 py-1 text-sky-200 hover:bg-sky-500/20"
          >
            🛰 Main Ship
          </button>
          <Link to="/" className="text-slate-300 hover:text-white">Command Center</Link>
          <Link to="/map" className="text-slate-300 hover:text-white">List view</Link>
        </nav>
      </header>

      {/* Main-ship overlay. 10B read-only by default; 10D adds the flag-gated status + recall. */}
      {showPreview && (
        <div className="border-b border-slate-800 bg-slate-900/95 p-3">
          <MainShipPreview sendEnabled={mainshipSendEnabled} fleet={mainShipFleet} onChanged={refresh} />
          {/* TRADE-UI-1 — ship-switcher (selection only) + read-only market view for the selected ship, sharing
              the ONE shipSelection hook instance so switching updates which ship MarketPanel displays. DARK:
              renders ONLY behind the TRADE_MARKET_ENABLED gate (false), and the server rejects the trade reads
              while trade_market_enabled is false — double fail-closed. Wired for when a human flips both. */}
          {TRADE_MARKET_ENABLED && (
            <>
              <ShipSwitcher
                ships={shipSelection.ships}
                selectedShipId={shipSelection.selectedShipId}
                selectShip={shipSelection.selectShip}
              />
              <MarketPanel key={shipSelection.selectedShipId ?? 'none'} selectedShip={shipSelection.selectedShip} />
            </>
          )}
        </div>
      )}

      <main className="relative flex flex-1 flex-col overflow-hidden md:flex-row">
        {/* Map area */}
        <div className="relative flex-1 p-2">
          {loading && (
            <div data-testid="galaxy-map-loading" className="flex h-full items-center justify-center text-slate-400">
              <span className="animate-pulse">Loading galaxy…</span>
            </div>
          )}
          {!loading && error && (
            <div data-testid="galaxy-map-error" className="flex h-full items-center justify-center px-6 text-center">
              <div>
                <p className="font-medium text-rose-400">Couldn't load the map</p>
                <p className="mt-1 text-sm text-slate-400">{error}</p>
              </div>
            </div>
          )}
          {!loading && !error && locations.length === 0 && (
            <div className="flex h-full items-center justify-center px-6 text-center text-slate-400">
              No locations are visible yet.
            </div>
          )}
          {!loading && !error && locations.length > 0 && (
            <>
              <GalaxyMap
                locations={locations}
                base={base}
                mainShip={mainShip}
                mainShipFleet={mainShipFleet}
                mainShipPresence={mainShipPresence}
                mainShipSpaceMovement={mainShipSpaceMovement}
                mainshipSendEnabled={mainshipSendEnabled}
                movements={movements}
                selectedId={selectedId}
                onSelect={setSelectedId}
              />
              {/* PORT-LAUNCH-1B — dark port-to-port navigation. Server-gated (osn_available + anchored): it
                  renders nothing while production is dark, so today's player experience is unchanged. */}
              <PortNavPanel
                visibleLocations={locations}
                shipStatus={mainShip?.status}
                shipSpatialState={mainShip?.spatial_state}
                spaceMovement={mainShipSpaceMovement}
                currentDockedLocationId={mainShipPresence?.location_id}
                mainShipId={mainShip?.main_ship_id ?? null}
                onCommitted={refresh}
              />
              {/* PHASE 9 — read-only docked-port context for the main ship. Renders only when the server
                  reports the ship is docked (at_location); shows the port + its active services (today:
                  Docking). No buy/sell/repair actions; no home-port. */}
              <DockServicesPanel
                lifecycleKey={`${mainShip?.status ?? 'n'}|${mainShip?.spatial_state ?? 'n'}|${mainShipPresence?.location_id ?? 'none'}|${mainShipSpaceMovement?.id ?? 'none'}|${mainShipSpaceMovement?.status ?? 'none'}`}
                mainShipId={mainShip?.main_ship_id ?? null}
              />
              {/* EXPLORATION-P11 — dark exploration surface (scan + discoveries). SERVER-driven
                  visibility: it renders ONLY when get_my_exploration_discoveries answers ok; while
                  the server returns exploration_disabled it renders nothing, so today's player
                  experience is unchanged. Scan itself is legal only settled in space; the server
                  rejects everything else (fail-closed both sides). */}
              <ExplorationPanel
                lifecycleKey={`${mainShip?.status ?? 'n'}|${mainShip?.spatial_state ?? 'n'}|${mainShipSpaceMovement?.id ?? 'none'}|${mainShipSpaceMovement?.status ?? 'none'}`}
                mainShipId={mainShip?.main_ship_id ?? null}
                shipStatus={mainShip?.status}
                shipSpatialState={mainShip?.spatial_state}
              />
              {/* MINING-P12 — dark mining surface (extract + extraction history). SERVER-driven
                  visibility: it renders ONLY when get_my_mining_extractions answers ok; while
                  the server returns mining_disabled it renders nothing, so today's player
                  experience is unchanged. Extract itself is legal only settled in space; the
                  server rejects everything else (fail-closed both sides). */}
              <MiningPanel
                lifecycleKey={`${mainShip?.status ?? 'n'}|${mainShip?.spatial_state ?? 'n'}|${mainShipSpaceMovement?.id ?? 'none'}|${mainShipSpaceMovement?.status ?? 'none'}`}
                mainShipId={mainShip?.main_ship_id ?? null}
                shipStatus={mainShip?.status}
                shipSpatialState={mainShip?.spatial_state}
              />
              {/* MODULES-P13 — dark module-crafting surface (catalog + craft + instances). SERVER-driven
                  visibility: it renders ONLY when get_my_module_instances answers ok; while the server
                  returns module_crafting_disabled it renders nothing, so today's player experience is
                  unchanged. Crafting is non-spatial (player-scoped) — no ship props; the server rejects
                  everything while dark (fail-closed both sides). */}
              <ModulesPanel
                lifecycleKey={`${mainShip?.status ?? 'n'}|${mainShip?.spatial_state ?? 'n'}|${mainShipSpaceMovement?.id ?? 'none'}|${mainShipSpaceMovement?.status ?? 'none'}`}
              />
            </>
          )}
        </div>

        {/* Read-only detail panel */}
        {selected && (
          <aside data-testid="galaxy-location-detail-panel" className="border-t border-slate-800 bg-slate-900/95 p-4 md:w-80 md:border-l md:border-t-0">
            <div className="flex items-start justify-between">
              <h2 className="text-base font-semibold">{selected.name}</h2>
              <button onClick={() => setSelectedId(null)} className="text-slate-400 hover:text-white" aria-label="Close details">✕</button>
            </div>
            <dl className="mt-3 space-y-1.5 text-sm">
              <Row label="Type" value={selected.location_type.replace(/_/g, ' ')} />
              {selMeta && <Row label="Sector" value={selMeta.sectorName} />}
              {selMeta && <Row label="Zone" value={selMeta.zoneName} />}
              <Row label="Coordinates" value={`${Math.round(selected.x)}, ${Math.round(selected.y)}`} />
              <Row label="Status" value={selected.status} />
              <Row label="Difficulty" value={String(selected.base_difficulty)} />
              <Row label="Reward tier" value={String(selected.reward_tier)} />
              {selState && <Row label="Pressure" value={selState.pressure.toFixed(2)} />}
              {selState && <Row label="Danger mod" value={selState.danger_modifier.toFixed(2)} />}
              {selState && <Row label="Active fleets" value={String(selState.active_fleets)} />}
            </dl>
            <ExpeditionCommand
              key={selected.id}
              location={selected}
              base={base}
              units={baseUnits}
              unitTypes={unitTypes}
              onSent={refresh}
            />
            {/* Phase 10D: separate main-ship send surface, ONLY when the flag is on. The old
                disposable fleet send above stays untouched and always available. */}
            {mainshipSendEnabled && (
              <MainShipCommand
                key={`ms-${selected.id}`}
                location={selected}
                mainShip={mainShip}
                fleet={mainShipFleet}
                onSent={refresh}
              />
            )}
          </aside>
        )}
      </main>
    </div>
  )
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between gap-3">
      <dt className="text-slate-400">{label}</dt>
      <dd className="text-right text-slate-200">{value}</dd>
    </div>
  )
}
