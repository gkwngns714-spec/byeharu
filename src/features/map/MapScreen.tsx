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
import type { MiningField } from '../mining/miningTypes'
import { WorldEventsPanel } from '../events/WorldEventsPanel'
import { TelegraphBanner } from '../combat/TelegraphBanner'
import { distance } from '../../game/movement/travelPreview'
import type { WorldCoord } from './openSpaceTransform'
import { Badge, Button, OverlayPanel, OverlayRail, Skeleton, StatRow, type BadgeTone } from '../../components/ui'
import { PirateInterceptPanel } from './PirateInterceptPanel'

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
// FleetCommandTarget union: a double-tap (GalaxyMap's onDoubleTapPoint) yields the point target; the
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
      teamGroups, teamGroupsOk, teamGroupMap, dockedTeamRollups,
      fleetMovementUnifiedEnabled, unifiedGroupFleets, combatSortieFleets,
      launchFromDockEnabled, fleetControlEnabled, timedDockingEnabled,
      miningFields, miningExtractRadius,
      pirateInterceptEnabled, dangerZones, refresh,
    },
    // COMBAT-S4: the shell's already-mounted combat poll (useCombat, ~1.5s — the tick cadence). Its
    // units/events feed the map's spatial-combat layer; dark today (no positioned rows exist while
    // spatial_combat_enabled is off) → the layer renders nothing.
    combat,
    selection,
  } = useShellState()
  const [selectedId, setSelectedId] = useState<string | null>(null)
  // S5 MAP-UX: the fleet's tapped open-space destination (RAW world point — the wire value). The
  // ONLY point-target state; the port target derives from selectedId below (ONE selection source).
  const [pointTarget, setPointTarget] = useState<WorldCoord | null>(null)
  // MINING-FIELD-MARKERS: a tapped field's OWN selection (a field is not a MapLocation, so it is not
  // part of selectedId's id-space) — mutually exclusive with the location selection + the point
  // target below, same "only one live selection" posture as the rest of this screen.
  const [selectedFieldName, setSelectedFieldName] = useState<string | null>(null)
  // PIRATE INTERCEPT (prototype): the route-planner / zone-drawing tap mode + its accumulated points.
  // 'off' by default — the map's tap handling is byte-identical to today until the player arms one of
  // the two modes via PirateInterceptPanel (mounted inside the command hub while the flag is lit).
  const [pirateMode, setPirateMode] = useState<'off' | 'route' | 'draw'>('off')
  const [pirateDraftPoints, setPirateDraftPoints] = useState<WorldCoord[]>([])
  // CLEAN-MAP COMMAND HUB — the ONE authority: a single boolean controls whether the summoned command
  // surface is on screen; WHAT it contains is derived (the fleet command panel + pirate panel always;
  // the mining panel only when the summon point lies inside a mining field's extraction range —
  // `tapFieldInRange` below). Default false → the map is unobstructed. A double-tap on empty space
  // opens it AT the tapped point (reusing the existing pointTarget flow); the hub's ✕ returns to clean.
  const [hubOpen, setHubOpen] = useState(false)
  // The double-tap summon (GalaxyMap.onDoubleTapPoint): set the go-target here (the SAME pointTarget the
  // fleet command consumes), drop any marker/field selection, and open the hub.
  const openHubAt = (world: WorldCoord) => {
    setPointTarget(world)
    setSelectedId(null)
    setSelectedFieldName(null)
    setHubOpen(true)
  }
  // The ONE dismissal: close the hub AND return the map to plain navigation (clear the target/crosshair
  // and disarm any pirate tap mode + draft).
  const closeHub = () => {
    setHubOpen(false)
    setPointTarget(null)
    setPirateMode('off')
    setPirateDraftPoints([])
  }

  const selected = locations.find((l) => l.id === selectedId) ?? null
  const selMeta = selectedId ? meta[selectedId] : null
  const selectedField: MiningField | null = miningFields.find((f) => f.name === selectedFieldName) ?? null

  // Selecting a marker retires any live point target (never two live targets); a bare-space tap
  // already clears the selection on GalaxyMap's own svg click path — the two stay exclusive by
  // construction. NB the svg click that FOLLOWS a space tap calls onSelect(null), so clearing the
  // point target here is gated on an actual (non-null) marker selection.
  const handleSelect = (id: string | null) => {
    setSelectedId(id)
    if (id !== null) {
      setPointTarget(null)
      setSelectedFieldName(null)
    }
  }
  const handleSelectMiningField = (name: string | null) => {
    setSelectedFieldName(name)
    if (name !== null) setSelectedId(null)
  }

  // PIRATE INTERCEPT (prototype): appends a tapped point to the active draft, capped per mode (route:
  // 3 waypoints + 1 final = 4; draw: the server's pirate_zone_create vertex ceiling is 64, capped lower
  // here for a usable tap-to-add UX). Only fires while pirateMode is 'route'/'draw' — with the mode
  // 'off' a single tap does nothing and a double-tap summons the hub, so this never runs then.
  const handlePirateTap = (world: WorldCoord) => {
    const cap = pirateMode === 'route' ? 4 : 24
    setPirateDraftPoints((pts) => (pts.length >= cap ? pts : [...pts, world]))
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

  // MINING FOLD: the field (if any) whose extraction range contains the summon point — SAME geometry
  // as the map's range ring (miningFieldRangeLayer: within `miningExtractRadius` world-units of the
  // field centre, the shared `distance` helper, never a second formula). When non-null, the hub folds
  // in the mining surface so the player can extract there — replacing the old persistent top-left panel.
  const tapFieldInRange: MiningField | null =
    pointTarget && Number.isFinite(miningExtractRadius) && miningExtractRadius > 0
      ? (miningFields.find((f) => distance(pointTarget.x, pointTarget.y, f.space_x, f.space_y) <= miningExtractRadius) ?? null)
      : null

  // 4C-CLIENT: the legacy spatial_state / space-movement fields left the key with the schema they
  // read — the ship's own status transition still ticks a refetch.
  const panelLifecycleKey = `${mainShip?.status ?? 'n'}`

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
              movements={movements}
              teamGroups={teamGroups}
              dockedTeamRollups={dockedTeamRollups}
              unifiedGroupFleets={unifiedGroupFleets}
              combatSortieFleets={combatSortieFleets}
              fleetGoView={pointView}
              onDoubleTapPoint={openHubAt}
              selectedId={selectedId}
              onSelect={handleSelect}
              miningFields={miningFields}
              miningExtractRadius={miningExtractRadius}
              selectedMiningFieldName={selectedFieldName}
              onSelectMiningField={handleSelectMiningField}
              dangerZones={dangerZones}
              combatUnits={combat.units}
              combatEvents={combat.events}
              pirateMode={pirateMode}
              pirateDraftPoints={pirateDraftPoints}
              onPirateTap={handlePirateTap}
            />
            {/* top-left overlay rail: the server-lit feature panels ride ONE stacked, scrollable
                slot so that WHEN a capability lights they read as coherent map overlays instead of
                colliding at hand-tuned offsets. All keep their server-lit `return null` gates
                verbatim (dark today → the rail renders empty and, being pointer-transparent, never
                intercepts map gestures). GalaxyMap owns top-right (zoom) and bottom-left (legend);
                WorldEvents takes top-center; the FleetCommandPanel takes bottom-right. */}
            <OverlayRail slot="top-left" className="max-h-[60%] w-72 max-w-[calc(100vw-5rem)] overflow-y-auto">
              {/* EXPLORATION-P11 — dark scan; legal only settled in space (server-lit, renders nothing
                  in prod). MINING-P12's persistent panel was REMOVED from this rail in the clean-map
                  redesign — the extract surface now folds into the double-tap command hub, appearing
                  only when the summon point sits inside a mining field's range (see the hub below). */}
              <ExplorationPanel
                lifecycleKey={panelLifecycleKey}
                mainShipId={mainShip?.main_ship_id ?? null}
                shipStatus={mainShip?.status}
                shipSpatialState={null}
              />
            </OverlayRail>
            {/* PHASE20-POLISH — dark world-events feed (top-center slot; server empties it while dark). */}
            <WorldEventsPanel lifecycleKey={panelLifecycleKey} />
            {/* COMBAT-S2 TELEGRAPH — the pre-combat warning beat (top-center, urgent). Renders nothing
                unless the caller has a telegraphed encounter; while combat_telegraph_enabled is dark the
                pending table is empty so this is invisible (fail-closed by data). Flee withdraws the
                fleet home, then re-polls the map + ship reads. */}
            <TelegraphBanner
              onChange={() => {
                void refresh()
                void selection.refresh()
              }}
            />
            {/* CLEAN-MAP COMMAND HUB (bottom-right) — summoned by a double-tap, dismissed by its own ✕.
                ONE header owns the dismissal; below it ride the EXISTING command surfaces, reused as-is
                and gated only on WHEN they appear: the fleet command panel (send/stop/dock/hunt), the
                mining extract surface (only inside a field's range), and the pirate-intercept panel.
                Bottom-right, never the map's center (play-test rule). While `hubOpen` is false the map
                is unobstructed — the whole rail is unmounted. */}
            {hubOpen && (
              <OverlayRail slot="bottom-right" className="max-h-[85%] max-w-[calc(100vw-1.5rem)] overflow-y-auto">
                <OverlayPanel data-testid="map-command-hub-header" className="flex w-72 max-w-full items-center justify-between gap-2">
                  <div className="min-w-0">
                    <p className="text-xs font-semibold text-ink">Commands</p>
                    {tapFieldInRange ? (
                      <p className="truncate text-[10px] text-warning">In range of {tapFieldInRange.name}</p>
                    ) : (
                      <p className="text-[10px] text-ink-faint">Double-tapped point</p>
                    )}
                  </div>
                  <button
                    type="button"
                    onClick={closeHub}
                    aria-label="Close commands"
                    title="Close"
                    data-testid="map-command-hub-close"
                    className="flex h-7 w-7 shrink-0 items-center justify-center rounded text-ink-faint transition hover:bg-edge/40 hover:text-ink"
                  >
                    ✕
                  </button>
                </OverlayPanel>

                {/* THE fleet-command surface: Stop (NO-SOFTLOCK, first, state-predicated) + go/redirect +
                    dock + hunt, from the ONE pure model. Renders nothing unless a fleet is in flight, a
                    target is live, or a fleet sits in a dockable port — so an empty double-tap shows only
                    the header + whatever else is relevant. onCommanded refreshes the map + ship reads. */}
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

                {/* MINING FOLD — the extract surface, only when the summon point is inside a field's
                    range (the ex-top-left panel, reused verbatim). Send a fleet here to mine via the
                    fleet panel above; extract once a ship is settled in range. */}
                {tapFieldInRange && (
                  <MiningPanel
                    lifecycleKey={panelLifecycleKey}
                    mainShipId={mainShip?.main_ship_id ?? null}
                    shipStatus={mainShip?.status}
                    shipSpatialState={null}
                  />
                )}

                {/* PIRATE INTERCEPT — plot an ambush route / draw a danger zone. Reused as-is; the hub
                    header owns dismissal, so no per-panel close here. */}
                {pirateInterceptEnabled && (
                  <PirateInterceptPanel
                    groupId={teamGroups[0]?.group_id ?? null}
                    locations={locations}
                    mode={pirateMode}
                    onModeChange={setPirateMode}
                    draftPoints={pirateDraftPoints}
                    onUndoDraft={() => setPirateDraftPoints((pts) => pts.slice(0, -1))}
                    onClearDraft={() => setPirateDraftPoints([])}
                    onCommanded={() => void refresh()}
                  />
                )}
              </OverlayRail>
            )}
          </div>
        )}
      </div>

      {/* MINING-FIELD-MARKERS — the field detail panel: name + a "send fleet here to mine" affordance
          that REUSES the existing open-space go (sets the SAME pointTarget the GalaxyMap space-tap
          path sets — no second command surface). Mutually exclusive with the location panel below
          (handleSelect/handleSelectMiningField keep only one selection live). Gated on
          TEAM_COMMAND_ENABLED like the FleetCommandPanel itself — setting a point target with no
          command surface mounted to consume it would be a dead click. */}
      {selectedField && (
        <aside
          data-testid="mining-field-detail-panel"
          className="max-h-[45dvh] overflow-y-auto border-t border-edge bg-surface p-4 md:max-h-none md:w-80 md:border-l md:border-t-0"
        >
          <div className="mx-auto mb-3 h-1 w-10 rounded-full bg-edge md:hidden" aria-hidden="true" />
          <div className="flex items-start justify-between gap-3">
            <div>
              <h2 className="text-base font-semibold text-ink">{selectedField.name}</h2>
              <p className="mt-0.5 text-xs text-ink-muted">Mining field</p>
            </div>
            <div className="flex shrink-0 items-center gap-2">
              <Badge tone="warning">Resource</Badge>
              <button
                onClick={() => setSelectedFieldName(null)}
                className="flex min-h-6 min-w-6 items-center justify-center text-ink-faint transition hover:text-ink"
                aria-label="Close details"
              >
                ✕
              </button>
            </div>
          </div>
          <dl className="mt-4 space-y-1.5 text-sm">
            <StatRow
              label="Extraction range"
              value={`${Math.round(miningExtractRadius)} units`}
              hint="settle a fleet within range to extract"
            />
          </dl>
          {TEAM_COMMAND_ENABLED && (
            <Button
              variant="warning"
              size="sm"
              data-testid="mining-field-send-fleet"
              className="mt-4 w-full"
              onClick={() => {
                setPointTarget({ x: selectedField.space_x, y: selectedField.space_y })
                setSelectedFieldName(null)
              }}
            >
              Send fleet here to mine
            </Button>
          )}
        </aside>
      )}

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
