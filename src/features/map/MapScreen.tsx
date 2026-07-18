import { useState } from 'react'
import { useShellState } from '../../app/shellState'
import { GalaxyMap } from './GalaxyMap'
import type { MapLocation } from './mapTypes'
import { TYPE_LABEL, dangerLabel, rewardLabel } from './locationDisplay'
import { ExplorationPanel } from '../exploration/ExplorationPanel'
import { FleetCommandPanel } from './FleetCommandPanel'
import { fleetGoTargetView } from './fleetGoTarget'
import type { FleetCommandTarget } from './fleetCommandModel'
import { teamDestinationKind } from '../command/teamDestination'
import { TEAM_COMMAND_ENABLED } from './osnReleaseGates'
import { MiningPanel } from '../mining/MiningPanel'
import { WorldEventsPanel } from '../events/WorldEventsPanel'
import type { WorldCoord } from './openSpaceTransform'
import { Badge, OverlayRail, Skeleton, StatRow, type BadgeTone } from '../../components/ui'

// UI-REBUILD (2b, Map interior) — the Map destination: THE primary play surface. The galaxy canvas
// stays the hero; the location detail panel now speaks the shared design language (IDENTITY →
// RIGHT NOW → DETAILS, StatRow rows, plain player language — the raw status/difficulty/tier/
// pressure/coordinate internals are humanized or dropped, see locationDisplay.ts), and the
// server-lit feature panels ride ONE overlay rail instead of floating as raw flow cards. Shared
// polled data comes from the shell; the arrival settle lives in AppShell — never here.
//
// S5 MAP-UX: the three scattered fleet-command surfaces (FleetGoPanel top-right, TeamMapSend in
// this aside, TeamMapStop in the top-left rail) are CONSOLIDATED into the ONE bottom-center
// FleetCommandPanel mounted below. This screen owns the ONE selection source for it — the
// FleetCommandTarget union: a space tap (GalaxyMap's onTargetPoint) yields the point target; the
// existing marker selection (selectedId) DERIVES the port target — never a second selection state.
// NO-SOFTLOCK is carried by the panel's model (Stop first, state-predicated only) + the AppShell
// settle. The detail aside below is now READ-ONLY location info.

// ── Player-facing location display ───────────────────────────────────────────────────────────────
// Humanized: location_type → a plain kind; base_difficulty → a danger word; reward_tier → a reward
// word — the pure mappings live in locationDisplay.ts (ONE home; DIFFICULTY-DISPLAY moved them out
// of this file and extended the bands past the old High/Rich saturation). DROPPED as dev-internal
// noise: raw coordinates, `status` (get_world_map returns only active rows — the row could never
// read anything else), pressure/danger_modifier decimals, and the active-fleets debug count. The
// raw difficulty/tier NUMBERS return as mono metadata next to the words (decision-relevant once
// zones spread across a 0–60 range), and min_power_required gets its own row when a gate exists.
const typeBadge = (l: MapLocation): { tone: BadgeTone; text: string } =>
  l.location_type === 'trade_outpost'
    ? { tone: 'accent', text: 'Port' }
    : l.activity_type === 'none'
      ? { tone: 'success', text: 'Safe' }
      : { tone: 'danger', text: 'Hostile' }

export function MapScreen() {
  const {
    map: {
      loading, error, locations, meta, mainShip, movements,
      mainshipSendEnabled, mainShipFleet, mainShipPresence, mainShipSpaceMovement,
      teamGroups, teamGroupsOk, teamGroupMap, dockedTeamRollups,
      fleetMovementUnifiedEnabled, unifiedGroupFleets, combatSortieFleets,
      launchFromDockEnabled, fleetControlEnabled, timedDockingEnabled, refresh,
    },
    selection,
  } = useShellState()
  const [selectedId, setSelectedId] = useState<string | null>(null)
  // S5 MAP-UX: the fleet's tapped open-space destination (RAW world point — the wire value). The
  // ONLY point-target state; the port target derives from selectedId below (ONE selection source).
  const [pointTarget, setPointTarget] = useState<WorldCoord | null>(null)

  const selected = locations.find((l) => l.id === selectedId) ?? null
  const selMeta = selectedId ? meta[selectedId] : null

  // Selecting a marker retires any live point target (never two live targets); a bare-space tap
  // already clears the selection on GalaxyMap's own svg click path — the two stay exclusive by
  // construction. NB the svg click that FOLLOWS a space tap calls onSelect(null), so clearing the
  // point target here is gated on an actual (non-null) marker selection.
  const handleSelect = (id: string | null) => {
    setSelectedId(id)
    if (id !== null) setPointTarget(null)
  }

  // The point target resolved ONCE (raw + canonical preview + bounds verdict); feeds both the
  // GalaxyMap crosshair marker and the command panel's target union.
  const pointView = pointTarget ? fleetGoTargetView(pointTarget) : null
  // THE FleetCommandTarget union — point (from the tap) XOR port (derived from the existing
  // selectedId when the location is a legal fleet destination) XOR null. No second selection state.
  const target: FleetCommandTarget = pointView
    ? { kind: 'point', view: pointView }
    : selected && teamDestinationKind(selected) !== null
      ? { kind: 'port', locationId: selected.id }
      : null

  const panelLifecycleKey = `${mainShip?.status ?? 'n'}|${mainShip?.spatial_state ?? 'n'}|${mainShipSpaceMovement?.id ?? 'none'}|${mainShipSpaceMovement?.status ?? 'none'}`

  return (
    <div data-testid="galaxy-map-screen" className="relative flex h-full flex-col overflow-hidden md:flex-row">
      {/* Map area — the hero */}
      <div className="relative flex-1 p-2">
        {loading && (
          // UI R1: the design-system Skeleton stands in for the map canvas while the world loads.
          <div data-testid="galaxy-map-loading" className="relative h-full w-full">
            <Skeleton className="h-full w-full rounded-card" />
            <p className="absolute inset-0 flex items-center justify-center text-sm text-ink-muted" role="status">
              Loading galaxy…
            </p>
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
          // ONE positioned wrapper the size of the map canvas: every screen-level overlay shares the
          // SAME slot coordinate frame as GalaxyMap's own overlays (UI R1 overlay-slot layout).
          <div className="relative h-full w-full">
            <GalaxyMap
              locations={locations}
              mainShip={mainShip}
              mainShipFleet={mainShipFleet}
              mainShipPresence={mainShipPresence}
              mainShipSpaceMovement={mainShipSpaceMovement}
              mainshipSendEnabled={mainshipSendEnabled}
              movements={movements}
              teamGroups={teamGroups}
              dockedTeamRollups={dockedTeamRollups}
              unifiedGroupFleets={unifiedGroupFleets}
              combatSortieFleets={combatSortieFleets}
              fleetMovementUnifiedEnabled={fleetMovementUnifiedEnabled}
              fleetGoView={pointView}
              onTargetPoint={setPointTarget}
              selectedId={selectedId}
              onSelect={handleSelect}
            />
            {/* top-left overlay rail: the server-lit feature panels ride ONE stacked, scrollable
                slot so that WHEN a capability lights they read as coherent map overlays instead of
                colliding at hand-tuned offsets. All keep their server-lit `return null` gates
                verbatim (dark today → the rail renders empty and, being pointer-transparent, never
                intercepts map gestures). GalaxyMap owns top-right (zoom), bottom-left (legend) and
                bottom-right; WorldEvents takes top-center; the FleetCommandPanel takes bottom-center. */}
            <OverlayRail slot="top-left" className="max-h-[60%] w-72 max-w-[calc(100vw-5rem)] overflow-y-auto">
              {/* EXPLORATION-P11 — dark scan + discoveries; legal only settled in space. */}
              <ExplorationPanel
                lifecycleKey={panelLifecycleKey}
                mainShipId={mainShip?.main_ship_id ?? null}
                shipStatus={mainShip?.status}
                shipSpatialState={mainShip?.spatial_state}
              />
              {/* MINING-P12 — dark extract + extraction history; legal only settled in space. */}
              <MiningPanel
                lifecycleKey={panelLifecycleKey}
                mainShipId={mainShip?.main_ship_id ?? null}
                shipStatus={mainShip?.status}
                shipSpatialState={mainShip?.spatial_state}
              />
            </OverlayRail>
            {/* PHASE20-POLISH — dark world-events feed (top-center slot; server empties it while dark). */}
            <WorldEventsPanel lifecycleKey={panelLifecycleKey} />
            {/* S5 MAP-UX — THE fleet-command surface (bottom-center): Stop (NO-SOFTLOCK, always
                first, state-predicated only) + go/redirect + dock + hunt, all composed from the ONE
                pure model. Mounted behind the same compile-time gate as every team surface; the
                panel renders nothing unless a fleet is in flight, a target is live, or a fleet sits
                in a dockable port's territory. onCommanded refreshes the map reads AND the shell's
                ship statuses (the TeamMapSend post-command discipline, kept). */}
            {TEAM_COMMAND_ENABLED && (
              <FleetCommandPanel
                target={target}
                movements={movements}
                groups={teamGroups}
                groupsLoaded={teamGroupsOk}
                unifiedEnabled={fleetMovementUnifiedEnabled}
                unifiedFleets={unifiedGroupFleets}
                rollups={dockedTeamRollups}
                locations={locations}
                ships={selection.ships}
                membership={teamGroupMap}
                launchFromDock={launchFromDockEnabled}
                fleetControlEnabled={fleetControlEnabled}
                timedDockingEnabled={timedDockingEnabled}
                onCommanded={() => {
                  void refresh()
                  void selection.refresh()
                }}
                onClearTarget={() => {
                  setPointTarget(null)
                  setSelectedId(null)
                }}
              />
            )}
          </div>
        )}
      </div>

      {/* Location detail panel — IDENTITY → DETAILS. READ-ONLY since S5 MAP-UX: every command verb
          lives in the bottom-center FleetCommandPanel (the port target derives from this selection).
          Bottom sheet on phones (capped height, scrollable), side panel on md+. */}
      {selected && (
        <aside
          data-testid="galaxy-location-detail-panel"
          className="max-h-[45dvh] overflow-y-auto border-t border-edge bg-surface p-4 md:max-h-none md:w-80 md:border-l md:border-t-0"
        >
          {/* bottom-sheet drag-handle affordance (phones only — the md+ side panel doesn't sheet) */}
          <div className="mx-auto mb-3 h-1 w-10 rounded-full bg-edge md:hidden" aria-hidden="true" />
          {/* 1 · IDENTITY */}
          <div className="flex items-start justify-between gap-3">
            <div>
              <h2 className="text-base font-semibold text-ink">{selected.name}</h2>
              <p className="mt-0.5 text-xs text-ink-muted">
                {TYPE_LABEL[selected.location_type] ?? selected.location_type.replace(/_/g, ' ')}
                {selMeta && <> · {selMeta.zoneName}</>}
              </p>
            </div>
            <div className="flex shrink-0 items-center gap-2">
              <Badge tone={typeBadge(selected).tone}>{typeBadge(selected).text}</Badge>
              <button
                onClick={() => setSelectedId(null)}
                className="flex min-h-6 min-w-6 items-center justify-center text-ink-faint transition hover:text-ink"
                aria-label="Close details"
              >
                ✕
              </button>
            </div>
          </div>

          {/* 2 · DETAILS — humanized, decision-relevant facts only */}
          <dl className="mt-4 space-y-1.5 text-sm">
            <StatRow
              label="Danger"
              value={dangerLabel(selected.base_difficulty)}
              hint={
                selected.base_difficulty > 0 ? (
                  <span className="font-mono tabular-nums">({selected.base_difficulty})</span>
                ) : undefined
              }
            />
            <StatRow
              label="Rewards"
              value={rewardLabel(selected.reward_tier)}
              hint={
                selected.reward_tier > 0 ? (
                  <span className="font-mono tabular-nums">(tier {selected.reward_tier})</span>
                ) : undefined
              }
            />
            {/* DIFFICULTY-DISPLAY — the team-combat power gate, previously rendered nowhere. Display
                of data get_world_map already returns for this active row; the server RPC
                (power_below_required) stays the only real gate. */}
            {selected.min_power_required > 0 && (
              <StatRow
                label="Required power"
                value={<span className="font-mono tabular-nums">{selected.min_power_required}</span>}
                hint="(fleet combat gate)"
              />
            )}
            {selMeta && <StatRow label="Region" value={selMeta.sectorName} />}
          </dl>
        </aside>
      )}
    </div>
  )
}
