import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useGalaxyMapData } from './useGalaxyMapData'
import { GalaxyMap } from './GalaxyMap'
import { MainShipPreview } from './MainShipPreview'
import { MainShipCommand } from './MainShipCommand'
import { PortNavPanel } from './PortNavPanel'
import { SpaceStopControls } from './SpaceStopControls'
import { isActiveLegacyOutboundTransit } from './spaceStopCommand'
import { useLegacyStopTransitCommand } from './useSpaceStopCommand'
import { useSettleDueArrival } from './useSettleDueArrival'
import { buttonClasses } from '../../components/ui'
import { DockServicesPanel } from './DockServicesPanel'
import { MarketPanel } from './MarketPanel'
import { ShipSwitcher } from './ShipSwitcher'
import { useMainShipSelection } from './useMainShipSelection'
import { TRADE_MARKET_ENABLED } from './osnReleaseGates'
import { ExplorationPanel } from '../exploration/ExplorationPanel'
import { MiningPanel } from '../mining/MiningPanel'
import { InvestmentPanel } from '../investment/InvestmentPanel'
import { CaptainsPanel } from '../captains/CaptainsPanel'
import { RecruitCaptainPanel } from '../captains/RecruitCaptainPanel'
import { ModulesPanel } from '../modules/ModulesPanel'
import { WorldEventsPanel } from '../events/WorldEventsPanel'

// Galaxy Map screen. Shows the world, the player's main ship, ports, and active movements; selecting a
// location opens its detail panel + the flag-gated main-ship send/move surface (MainShipCommand). When the
// main ship is docked at a port, the read-only DockServicesPanel shows that port's active services.

export function GalaxyMapScreen() {
  const {
    loading, error, locations, meta, base, mainShip, movements, locationStates,
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

  // UX-CLEANUP item 3 — stop for a LEGACY in-transit main-ship move (MainShipCommand sends create
  // fleet_movements, invisible to the OSN stop mounts). Reuses the ONE stop controller/CTA, wired to
  // command_main_ship_stop_transit (0149: halt → symmetric return home; server-gated on
  // mainship_send_enabled, idempotent by state). Renders only for an OUTBOUND transit of the main-ship
  // fleet — a return leg has nothing to stop.
  const legacyMove = mainShipFleet
    ? (movements.find((mv) => mv.fleet_id === mainShipFleet.id && mv.status === 'moving') ?? null)
    : null
  const inLegacyOutboundTransit = isActiveLegacyOutboundTransit({
    fleetStatus: mainShipFleet?.status,
    missionType: legacyMove?.mission_type,
  })
  const legacyStop = useLegacyStopTransitCommand(inLegacyOutboundTransit ? (mainShipFleet?.id ?? null) : null)

  // UX-CLEANUP item 6 — on-demand arrival settles, BOTH families: the moment the ship's active movement
  // is due (part A: the OSN movement; part B: the legacy main-ship fleet movement — the `legacyMove`
  // computed above), fire the matching settle RPC once (server re-validates under the crons' locks; the
  // 30s crons stay the backstop) and refresh — arrivals settle in ~a second instead of up to ~34s.
  useSettleDueArrival({
    mainShipId: mainShip?.main_ship_id ?? null,
    movement: mainShipSpaceMovement,
    legacyMovement: legacyMove,
    legacyFleetId: mainShipFleet?.id ?? null,
    onSettled: () => void refresh(),
  })

  return (
    <div data-testid="galaxy-map-screen" className="flex h-[100dvh] flex-col bg-app text-ink">
      <header className="flex items-center justify-between border-b border-edge px-4 py-3">
        <div>
          <h1 className="text-lg font-semibold text-ink">Galaxy Map</h1>
          <p className="text-xs text-ink-muted">Your main ship, ports, and expeditions</p>
        </div>
        <nav className="flex items-center gap-2 text-sm">
          <button
            data-testid="mainship-preview-toggle"
            onClick={() => setShowPreview((s) => !s)}
            className={buttonClasses('secondary', 'sm')}
          >
            🛰 Main Ship
          </button>
          <Link to="/" className={buttonClasses('ghost', 'sm')}>Command Center</Link>
        </nav>
      </header>

      {/* Main-ship overlay. 10B read-only by default; 10D adds the flag-gated status + recall. */}
      {showPreview && (
        <div className="border-b border-edge bg-surface p-3">
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
            <div data-testid="galaxy-map-loading" className="flex h-full items-center justify-center text-ink-muted">
              <span className="animate-pulse">Loading galaxy…</span>
            </div>
          )}
          {!loading && error && (
            <div data-testid="galaxy-map-error" className="flex h-full items-center justify-center px-6 text-center">
              <div>
                <p className="font-medium text-danger">Couldn't load the map</p>
                <p className="mt-1 text-sm text-ink-muted">{error}</p>
              </div>
            </div>
          )}
          {!loading && !error && locations.length === 0 && (
            <div className="flex h-full items-center justify-center px-6 text-center text-ink-muted">
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
              {/* UX-CLEANUP item 3 — the legacy in-transit stop CTA (see the hook block above). Same
                  component/controller as the OSN stops; mutually exclusive with them by state (one active
                  movement owner per ship). Refreshes the polled data after the command settles. */}
              {inLegacyOutboundTransit && (
                <SpaceStopControls
                  phase={legacyStop.state.phase}
                  errorMessage={legacyStop.state.errorMessage}
                  outcome={legacyStop.state.outcome}
                  onStop={() => void legacyStop.submit().finally(() => void refresh())}
                  title="Main ship in transit"
                  stopLabel="Stop — return home"
                  stoppedMessage="Turning around — returning home."
                />
              )}
              {/* PHASE 9 — read-only docked-port context for the main ship. Renders only when the server
                  reports the ship is docked (at_location); shows the port + its active services (today:
                  Docking). No buy/sell/repair actions; no home-port. */}
              <DockServicesPanel
                lifecycleKey={`${mainShip?.status ?? 'n'}|${mainShip?.spatial_state ?? 'n'}|${mainShipPresence?.location_id ?? 'none'}|${mainShipSpaceMovement?.id ?? 'none'}|${mainShipSpaceMovement?.status ?? 'none'}`}
                mainShipId={mainShip?.main_ship_id ?? null}
              />
              {/* LOCATION-INVEST-P18 (dark): docked-port investment surface. Mounted here (not the
                  Dashboard) because BOTH the server-reported docked location (mainShipPresence.location_id,
                  the same id PortNavPanel uses) and the player's main_ship_id are in scope — the reads are
                  location-scoped and the invest command uses the ship whose docked location the server
                  derives. Renders null unless the server lit get_location_development (feature_disabled →
                  not server-lit while dark; also null when not docked), so production is byte-unchanged. */}
              <InvestmentPanel
                lifecycleKey={`${mainShip?.status ?? 'n'}|${mainShip?.spatial_state ?? 'n'}|${mainShipPresence?.location_id ?? 'none'}|${mainShipSpaceMovement?.id ?? 'none'}|${mainShipSpaceMovement?.status ?? 'none'}`}
                locationId={mainShipPresence?.location_id ?? null}
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
              {/* CAPTAIN-P15 (dark): assign/unassign the player's captains to their main ship. Mounted here
                  (like ModulesPanel) because the player's main_ship_id is in scope — captains are assigned to
                  that ship; the server derives ownership + enforces slots + the settled-safe rule. SERVER-driven
                  visibility: renders null unless get_my_captain_instances answers ok; while
                  captain_assignment_enabled is false the server returns captain_assignment_disabled → not
                  server-lit → null, so today's player experience is byte-unchanged (fail-closed both sides). */}
              <CaptainsPanel
                lifecycleKey={`${mainShip?.status ?? 'n'}|${mainShip?.spatial_state ?? 'n'}|${mainShipSpaceMovement?.id ?? 'none'}|${mainShipSpaceMovement?.status ?? 'none'}`}
                mainShipId={mainShip?.main_ship_id ?? null}
              />
              {/* CAPTAIN-P16 (dark): captain recruitment (progression). Non-spatial (inventory→captain) —
                  no ship id needed. Visibility derives from the captain-system roster read (fail-closed);
                  the recruit COMMAND is the authoritative captain_progression_enabled gate (feature_disabled
                  while dark, surfaced inline). Renders null while dark, so production is byte-unchanged. */}
              <RecruitCaptainPanel
                lifecycleKey={`${mainShip?.status ?? 'n'}|${mainShip?.spatial_state ?? 'n'}|${mainShipSpaceMovement?.id ?? 'none'}|${mainShipSpaceMovement?.status ?? 'none'}`}
              />
              {/* PHASE20-POLISH — dark World Events display (read-only, presentational). SERVER-driven
                  visibility: it renders ONLY when get_world_events returns live events; while
                  phase20_polish_enabled is false the server empties the feed, so it renders nothing and
                  today's player experience is unchanged. No actions — the server (flag gate + live-window
                  filter) is the sole control. Same lifecycleKey as its siblings (a re-fetch trigger). */}
              <WorldEventsPanel
                lifecycleKey={`${mainShip?.status ?? 'n'}|${mainShip?.spatial_state ?? 'n'}|${mainShipSpaceMovement?.id ?? 'none'}|${mainShipSpaceMovement?.status ?? 'none'}`}
              />
            </>
          )}
        </div>

        {/* Read-only detail panel */}
        {selected && (
          <aside data-testid="galaxy-location-detail-panel" className="border-t border-edge bg-surface p-4 md:w-80 md:border-l md:border-t-0">
            <div className="flex items-start justify-between">
              <h2 className="text-base font-semibold text-ink">{selected.name}</h2>
              <button onClick={() => setSelectedId(null)} className="text-ink-faint transition hover:text-ink" aria-label="Close details">✕</button>
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
            {/* Phase 10D: main-ship send surface, ONLY when the flag is on. (The legacy disposable
                fleet send — ExpeditionCommand — was retired in the UX cleanup pass; its RPC remains
                server-side.) */}
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
      <dt className="text-ink-faint">{label}</dt>
      <dd className="text-right text-ink">{value}</dd>
    </div>
  )
}
