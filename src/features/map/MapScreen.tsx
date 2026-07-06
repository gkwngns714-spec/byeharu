import { useState } from 'react'
import { useShellState } from '../../app/shellState'
import { GalaxyMap } from './GalaxyMap'
import { PortNavPanel } from './PortNavPanel'
import { SpaceStopControls } from './SpaceStopControls'
import { isActiveLegacyOutboundTransit } from './spaceStopCommand'
import { useLegacyStopTransitCommand } from './useSpaceStopCommand'
import { MainShipCommand } from './MainShipCommand'
import { ExplorationPanel } from '../exploration/ExplorationPanel'
import { MiningPanel } from '../mining/MiningPanel'
import { WorldEventsPanel } from '../events/WorldEventsPanel'

// UI-REBUILD (2b) — the Map destination: THE primary play surface and the single route to the
// galaxy. See the ship, move, Stop, dock, and select a destination → send (MainShipCommand in the
// detail panel — the send flow lives IN the map; the retired ExpeditionLauncher had nothing to
// fold). Panel interiors are relocated UNCHANGED this slice; shared polled data comes from the
// shell (useShellState), and the on-demand arrival settle lives in AppShell — never here.
//
// NO-SOFTLOCK: every stop/recovery surface stays on this always-reachable destination — the
// legacy transit stop CTA below, PortNavPanel's own OSN stop + the held-in-space re-departure
// surface, and GalaxyMap's coordinate-transit stop CTA — all mounted independent of feature flags
// (their own state predicates decide, exactly as before).

export function MapScreen() {
  const {
    map: {
      loading, error, locations, meta, base, mainShip, movements, locationStates,
      mainshipSendEnabled, mainShipFleet, mainShipPresence, mainShipSpaceMovement, refresh,
    },
  } = useShellState()
  const [selectedId, setSelectedId] = useState<string | null>(null)

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

  return (
    <div data-testid="galaxy-map-screen" className="relative flex h-full flex-col overflow-hidden md:flex-row">
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

      {/* Read-only detail panel + the ONE send/move flow (pick a destination on the map → send). */}
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
          {/* Phase 10D: main-ship send surface, ONLY when the flag is on. */}
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
