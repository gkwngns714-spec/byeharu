import { useCallback, useEffect, useMemo, useRef, useState, type PointerEvent as RPointerEvent } from 'react'
import type { MapLocation } from './mapTypes'
import type { FleetMovement } from '../fleets/fleetTypes'
import { LocationMarker } from './LocationMarker'
import { FleetMovementLine } from './FleetMovementLine'
import { isMovementInFlight, interpolateMovementPoint } from './movementInterpolation'
import { teamMarkersLayer } from './teamMarkers'
import { territoryLayer } from './territoryLayer'
import { miningFieldRangeLayer } from './miningFieldLayer'
import { MiningFieldMarker } from './MiningFieldMarker'
import type { MiningField } from '../mining/miningTypes'
import { dangerZoneLayer } from './dangerZoneLayer'
import { spatialCombatLayer } from './spatialCombatLayer'
import type { CombatEvent, CombatUnit } from '../combat/combatTypes'
import type { DangerZoneLite } from './pirateApi'
import type { GroupRow } from '../command/teamRoster'
import type { DockedTeamRollup } from '../command/teamRollup'
import type { UnifiedGroupFleetLite } from '../command/teamApi'
import { DevFixedSpacePreview } from './DevFixedSpacePreview'
import { SpaceMoveTargetMarker } from './SpaceMoveTarget'
import { classifyPointerGesture } from './spaceMoveCommand'
import { type FleetGoTargetView } from './fleetGoTarget'
import { screenToWorld, worldToViewBox, type WorldCoord } from './openSpaceTransform'
import { VIEW, clampK, clampPan, focusCamera, focusWorldPoints, type Camera, type FocusInputs } from './galaxyCamera'
import { labelVisible } from './markerStyle'
import { Button, OverlayPanel, OverlayRail } from '../../components/ui'

// Read-only 2D galaxy map (plain SVG — no canvas/WebGL). UNIFIED fixed-coordinate frame (S6B-PRES):
// EVERY spatial object — named locations, base/home, movement lines, legacy + open-space ship states,
// and coordinate targets — is positioned through the fixed `worldToViewBox` domain (openSpaceTransform).
// `buildNormalizer` is gone: the dynamic auto-fit normalizer is no longer the player-facing spatial
// truth. Camera math (zoom/pan limits + content-fit) lives in ./galaxyCamera and feeds ONLY the initial
// view and explicit reset (frozen once the player pans/zooms). Nothing here writes to the database.

// The UNIFIED spatial transform: world → viewBox. Replaces the old dynamic `norm`. Pure; never clamps.
const norm = (p: { x: number; y: number }): { x: number; y: number } => worldToViewBox(p)

// CLEAN-MAP DOUBLE-TAP thresholds: a second empty-space tap within this window + radius of the first
// is a double-tap (matches native double-click timing; generous enough for touch double-tap).
const DOUBLE_TAP_MS = 350
const DOUBLE_TAP_MAX_GAP_PX = 30

export function GalaxyMap({
  locations,
  movements,
  teamGroups,
  dockedTeamRollups,
  unifiedGroupFleets,
  combatSortieFleets,
  fleetGoView,
  onDoubleTapPoint,
  selectedId,
  onSelect,
  miningFields,
  miningExtractRadius,
  selectedMiningFieldName,
  onSelectMiningField,
  dangerZones = [],
  combatUnits = [],
  combatEvents = [],
  pirateMode = 'off',
  pirateDraftPoints = [],
  onPirateTap,
}: {
  locations: MapLocation[]
  movements: FleetMovement[]
  // TEAMMAP-2: the owner's teams + the pure docked-team rollup (both empty while TEAM_COMMAND is
  // dark — the additive team layer then renders nothing and the map is byte-identical to today).
  teamGroups: GroupRow[]
  dockedTeamRollups: DockedTeamRollup[]
  // FLEET-GO 4a-1: the group's own unified fleets (charter §2). Feeds the in-space fleet badge in the
  // team layer. [] while the unified flag is dark (useGalaxyMapData gates the read) → byte-identical.
  unifiedGroupFleets: UnifiedGroupFleetLite[]
  // MAP-INTEGRATION M1: the COMBAT-PRESENT group fleets (the dock fold's exact complement, partitioned
  // once in useGalaxyMapData). Feeds the team layer's "in combat at X" badge so a fleet mid-hunt-combat
  // never vanishes from the map. [] while the unified fetch is dark → byte-identical.
  combatSortieFleets: UnifiedGroupFleetLite[]
  // CLEAN-MAP HUB: the map is unobstructed by default. The ONE gesture that summons commands is a
  // DOUBLE-TAP on empty space (mouse double-click OR touch double-tap — both flow through pointer
  // events). MapScreen's handler sets the go-target (the crosshair the fleetGoView prop drives) AND
  // opens the command hub. A single tap on empty space does nothing (the map stays clean); a marker
  // tap still selects; pirate route/draw modes still consume single taps (onPirateTap, below).
  fleetGoView: FleetGoTargetView | null
  onDoubleTapPoint: (world: WorldCoord) => void
  selectedId: string | null
  onSelect: (id: string | null) => void
  // MINING-FIELD-MARKERS: the active fields ([] while mining is disabled — 0226 fail-closed) + the
  // world-unit extraction radius (game_config mining_extract_radius) for the range-ring layer.
  // Selection is its OWN state (a field is not a MapLocation) — MapScreen owns it, mutually
  // exclusive with `selectedId` the same way point-target vs. port-selection already are.
  miningFields: MiningField[]
  miningExtractRadius: number
  selectedMiningFieldName: string | null
  onSelectMiningField: (name: string | null) => void
  // PIRATE INTERCEPT (prototype) — [] / 'off' / [] / undefined while the flag is dark (the caller's
  // gate), so every prop below defaults to a no-op shape and the map is byte-identical to today.
  /** Active danger_zones (get_danger_zones) — rendered as smooth blobs, UNDER movement lines/markers. */
  dangerZones?: DangerZoneLite[]
  // COMBAT-S4 — the caller's active combat_units + recent combat_events (both already polled every
  // ~1.5s by the shell's useCombat and exposed via useShellState().combat). The spatial-combat layer
  // draws the units that carry positions (their range rings, side-distinct glyphs, and this tick's fire
  // lines). [] defaults → the layer renders nothing, so a map with no active battle — or ANY map while
  // spatial_combat_enabled is dark (no positioned rows can exist) — is byte-identical to today.
  /** Active combat units (RLS-scoped to the caller — enemy pirate rows carry the caller's own
   *  player_id, so they arrive in the SAME read). Only positioned+alive rows render. */
  combatUnits?: CombatUnit[]
  /** Recent combat events; the layer consumes only the latest tick's spatial `missile_salvo`s (fire
   *  lines between units), ignoring the aggregate/dark-path events that carry no unit_id. */
  combatEvents?: CombatEvent[]
  /** 'off' = normal ship-go tap handling (byte-identical to pre-slice behavior). 'route' / 'draw' TAKE
   *  OVER the entire empty-space tap surface (mutually exclusive with the fleet-go tap) — each tap
   *  appends a point via onPirateTap instead of setting a fleet-go target. */
  pirateMode?: 'off' | 'route' | 'draw'
  /** The in-progress route/zone points, drawn as a connected polyline + vertex dots while plotting. */
  pirateDraftPoints?: WorldCoord[]
  /** Called with the tapped RAW world point whenever pirateMode !== 'off' (ownership/group checks do
   *  NOT apply — route planning and zone drawing are not gated on owning a fleet the way ship-go is). */
  onPirateTap?: (world: WorldCoord) => void
}) {
  const svgRef = useRef<SVGSVGElement | null>(null)
  const [view, setView] = useState<Camera>({ k: 1, tx: 0, ty: 0 })
  const drag = useRef<{ x: number; y: number; tx: number; ty: number } | null>(null)

  // 1s clock for the in-flight path filter below. Same idiom as TeamMovingMarkers: Date.now()
  // stays OUT of render (it is impure and would re-read unpredictably on any re-render), and the interval
  // runs ONLY while there is a movement to time — with none, no timer exists and the map is idle as before.
  const [nowMs, setNowMs] = useState(() => Date.now())
  const anyMovement = movements.length > 0
  useEffect(() => {
    if (!anyMovement) return
    const iv = setInterval(() => setNowMs(Date.now()), 1000)
    return () => clearInterval(iv)
  }, [anyMovement])
  // S6B-PRES camera policy: content-fit is applied for the initial view + explicit reset only; once the
  // player pans/zooms (`userMovedRef`) the camera is frozen. `lastFitSig` makes the fit fire once per
  // meaningful focus change rather than per animation frame.
  const userMovedRef = useRef(false)
  const lastFitSig = useRef<string | null>(null)

  // Gesture bookkeeping: a single short near-stationary pointer on EMPTY space is a candidate tap;
  // drags and multi-touch stay map pan. Tracked alongside (never replacing) the existing pan snapshot.
  const tap = useRef<{ x: number; y: number; t: number; maxPointers: number } | null>(null)
  const pointers = useRef<Set<number>>(new Set())
  // CLEAN-MAP DOUBLE-TAP: the last committed empty-space tap (screen px + timestamp). A second tap
  // close in time + space is a double-tap → summon. Pointer events fire for BOTH mouse and touch, so
  // this ONE mechanism covers mouse double-click and touch double-tap without a separate onDoubleClick.
  const lastTap = useRef<{ x: number; y: number; t: number } | null>(null)

  // ── S6B-PRES content-fit camera (presentation only; never alters world/marker coordinates) ──
  // 4C-CLIENT: the per-ship open-space focus arm (spatial_state='in_space' point / legacy coordinate
  // movement segment) is DELETED with the per-ship movement client — those states can no longer
  // exist. Focus derives from the named world content; the FocusInputs ship/segment slots stay null.
  const focusInputs: FocusInputs = useMemo(
    () => ({
      shipWorld: null,
      movementSegment: null,
      locations: locations.map((l) => ({ x: l.x, y: l.y })),
    }),
    [locations],
  )

  // Stable focus signature: changes only on a MEANINGFUL focus change (the named-content set),
  // never per animation frame — so the fit is applied once per context.
  const focusSignature = useMemo(() => `named:${locations.map((l) => l.id).join(',')}`, [locations])

  // Apply the content-fit camera for the INITIAL view (once per focus change), never after the player
  // has interacted. Explicit reset re-enables it.
  useEffect(() => {
    if (userMovedRef.current) return
    if (lastFitSig.current === focusSignature) return
    if (focusWorldPoints(focusInputs).length === 0) return
    lastFitSig.current = focusSignature
    // Intentional: one-time content-fit of the camera when async data / focus first arrives. Gated by
    // refs (userMoved + lastFitSig) so it fires once per focus context, never continuously — the valid
    // "derive initial view from external data" effect use, not a render-loop.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setView(focusCamera(focusInputs))
  }, [focusSignature, focusInputs])

  const toSvgUnits = (dxPx: number) => {
    const rect = svgRef.current?.getBoundingClientRect()
    const w = rect?.width || 1
    return (dxPx * VIEW) / w
  }

  // ── pan / zoom handlers (read-only camera; no data mutation) ──
  const onPointerDown = (e: RPointerEvent) => {
    ;(e.target as Element).setPointerCapture?.(e.pointerId)
    drag.current = { x: e.clientX, y: e.clientY, tx: view.tx, ty: view.ty }
    pointers.current.add(e.pointerId)
    tap.current = { x: e.clientX, y: e.clientY, t: e.timeStamp, maxPointers: pointers.current.size }
  }
  const onPointerMove = (e: RPointerEvent) => {
    // Capture the drag snapshot locally. The setView updater runs LATER (React render phase), and
    // drag.current can be null by then (pointer already released) — dereferencing it inside the
    // updater crashed the whole tree ("Cannot read properties of null (reading 'tx')"), which with
    // no error boundary blanked the page on pan. The captured `d` is guaranteed non-null here.
    const d = drag.current
    if (!d) return
    if (tap.current) tap.current.maxPointers = Math.max(tap.current.maxPointers, pointers.current.size)
    const dx = toSvgUnits(e.clientX - d.x)
    const dy = toSvgUnits(e.clientY - d.y)
    if (dx !== 0 || dy !== 0) userMovedRef.current = true // player took camera control → freeze auto-fit
    setView((v) => ({ ...v, ...clampPan(d.tx + dx, d.ty + dy, v.k) }))
  }
  const onPointerUp = (e: RPointerEvent) => {
    const t = tap.current
    pointers.current.delete(e.pointerId)
    drag.current = null
    tap.current = null
    // A single short near-stationary tap on EMPTY space (the <svg> itself — markers/backdrop don't hit
    // here) is the gesture candidate. Drags/multi-touch already returned as pan.
    const svg = svgRef.current
    if (!t || !svg || e.target !== svg) return
    const travelPx = Math.hypot(e.clientX - t.x, e.clientY - t.y)
    const durationMs = e.timeStamp - t.t
    if (classifyPointerGesture({ travelPx, durationMs, maxPointers: t.maxPointers }) !== 'tap') return
    const rect = svg.getBoundingClientRect()
    const world = screenToWorld(
      { x: e.clientX - rect.left, y: e.clientY - rect.top },
      { k: view.k, tx: view.tx, ty: view.ty },
      { width: rect.width, height: rect.height },
    )
    // PIRATE INTERCEPT: route-planning / zone-drawing TAKES OVER the tap surface — each SINGLE tap
    // appends a point. Double-tap detection is suspended in these modes so a plotted point is never
    // swallowed as the first half of a "double". 'off' (the default) falls through to the summon path.
    if (pirateMode !== 'off') {
      lastTap.current = null
      onPirateTap?.(world)
      return
    }
    // CLEAN-MAP: a lone single tap does NOTHING (the map stays unobstructed). A second tap close in
    // time + space is a DOUBLE-TAP → set the go-target here and summon the command hub (MapScreen).
    // This one pointer-driven path serves mouse double-click and touch double-tap alike.
    const prev = lastTap.current
    const gapMs = e.timeStamp - (prev?.t ?? -Infinity)
    const gapPx = prev ? Math.hypot(e.clientX - prev.x, e.clientY - prev.y) : Infinity
    if (prev && gapMs <= DOUBLE_TAP_MS && gapPx <= DOUBLE_TAP_MAX_GAP_PX) {
      lastTap.current = null
      onDoubleTapPoint(world)
      return
    }
    lastTap.current = { x: e.clientX, y: e.clientY, t: e.timeStamp }
  }
  // pointerleave/cancel: end the pan and abandon any tap candidate (never a selection).
  const onPointerLeave = (e: RPointerEvent) => {
    pointers.current.delete(e.pointerId)
    drag.current = null
    tap.current = null
  }
  // Zoom by a factor around the viewBox centre (shared by the wheel + the +/− buttons).
  const zoomByFactor = useCallback((factor: number) => {
    userMovedRef.current = true // player took camera control → freeze auto-fit
    setView((v) => {
      const k = clampK(v.k * factor)
      const ratio = k / v.k
      // zoom around viewBox centre (500,500) — keeps it simple + stable on mobile.
      const cx = VIEW / 2
      const cy = VIEW / 2
      return { k, ...clampPan(cx - (cx - v.tx) * ratio, cy - (cy - v.ty) * ratio, k) }
    })
  }, [])

  // Wheel zoom via a NATIVE, non-passive listener so we can preventDefault — otherwise the wheel event
  // bubbles to the browser and scrolls/zooms the whole page while the pointer is over the map. (React's
  // synthetic onWheel is registered passive, so preventDefault there is ignored — hence the manual bind.)
  useEffect(() => {
    const svg = svgRef.current
    if (!svg) return
    const onWheelNative = (e: WheelEvent) => {
      e.preventDefault()
      zoomByFactor(e.deltaY < 0 ? 1.15 : 1 / 1.15)
    }
    svg.addEventListener('wheel', onWheelNative, { passive: false })
    return () => svg.removeEventListener('wheel', onWheelNative)
  }, [zoomByFactor])
  // Reset re-enables the deterministic content-fit camera (frames the player ship / active movement,
  // else named content). NOT k=1/origin — at k=1 the fixed frame would show current seed content as a
  // tiny central cluster.
  const reset = () => {
    userMovedRef.current = false
    const pts = focusWorldPoints(focusInputs)
    lastFitSig.current = focusSignature
    setView(pts.length ? focusCamera(focusInputs) : { k: 1, tx: 0, ty: 0 })
  }

  return (
    <div className="relative h-full w-full overflow-hidden rounded-card border border-edge bg-app shadow-card">
      <svg
        ref={svgRef}
        viewBox={`0 0 ${VIEW} ${VIEW}`}
        preserveAspectRatio="xMidYMid meet"
        className="h-full w-full cursor-grab touch-none select-none active:cursor-grabbing"
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerLeave={onPointerLeave}
        onPointerCancel={onPointerLeave}
        onClick={() => {
          onSelect(null)
          onSelectMiningField(null)
        }}
      >
        {/* Static backdrop (NOT transformed): the map area always renders a deliberate background,
            even at the camera bounds. Visual safety layer only — not a map-layer framework.
            UI R1 depth treatment (tokens ONLY — no raw color literals, no WebGL, no animation):
            app-dark canvas (darker than the surface chrome) → soft surface lift + faint accent
            nebula → static tiled starfield → major/minor grid on --color-map-grid → vignette. */}
        <defs>
          <radialGradient id="bh-space-glow" cx="50%" cy="42%" r="75%">
            <stop offset="0%" stopColor="var(--color-surface)" stopOpacity={0.55} />
            <stop offset="70%" stopColor="var(--color-surface)" stopOpacity={0} />
          </radialGradient>
          <radialGradient id="bh-space-nebula" cx="30%" cy="28%" r="50%">
            <stop offset="0%" stopColor="var(--color-accent)" stopOpacity={0.05} />
            <stop offset="100%" stopColor="var(--color-accent)" stopOpacity={0} />
          </radialGradient>
          <radialGradient id="bh-space-vignette" cx="50%" cy="50%" r="72%">
            <stop offset="0%" stopColor="var(--color-app)" stopOpacity={0} />
            <stop offset="62%" stopColor="var(--color-app)" stopOpacity={0} />
            <stop offset="100%" stopColor="var(--color-app)" stopOpacity={0.6} />
          </radialGradient>
          {/* static starfield tile — a fixed set of faint ink dots (no script, no animation loop) */}
          <pattern id="bh-space-stars" width={VIEW / 4} height={VIEW / 4} patternUnits="userSpaceOnUse">
            <g fill="var(--color-ink)">
              <circle cx={12} cy={40} r={1.1} opacity={0.35} />
              <circle cx={58} cy={15} r={0.7} opacity={0.2} />
              <circle cx={90} cy={80} r={1.4} opacity={0.45} />
              <circle cx={140} cy={30} r={0.8} opacity={0.25} />
              <circle cx={170} cy={110} r={1.1} opacity={0.3} />
              <circle cx={30} cy={150} r={0.7} opacity={0.2} />
              <circle cx={105} cy={170} r={1.3} opacity={0.4} />
              <circle cx={200} cy={60} r={0.9} opacity={0.25} />
              <circle cx={230} cy={140} r={0.7} opacity={0.2} />
              <circle cx={65} cy={210} r={1} opacity={0.3} />
              <circle cx={160} cy={225} r={0.8} opacity={0.22} />
              <circle cx={220} cy={205} r={1.2} opacity={0.35} />
              <circle cx={15} cy={95} r={0.9} opacity={0.28} />
              <circle cx={245} cy={20} r={0.8} opacity={0.2} />
            </g>
          </pattern>
          {/* minor/major grid — both painted with --color-map-grid at two weights/opacities */}
          <pattern id="bh-space-grid-minor" width={VIEW / 20} height={VIEW / 20} patternUnits="userSpaceOnUse">
            <path
              d={`M ${VIEW / 20} 0 L 0 0 0 ${VIEW / 20}`}
              fill="none"
              stroke="var(--color-map-grid)"
              strokeWidth={0.5}
              opacity={0.5}
            />
          </pattern>
          <pattern id="bh-space-grid-major" width={VIEW / 5} height={VIEW / 5} patternUnits="userSpaceOnUse">
            <path d={`M ${VIEW / 5} 0 L 0 0 0 ${VIEW / 5}`} fill="none" stroke="var(--color-map-grid)" strokeWidth={1.25} />
          </pattern>
        </defs>
        <rect x={0} y={0} width={VIEW} height={VIEW} fill="var(--color-app)" pointerEvents="none" />
        <rect x={0} y={0} width={VIEW} height={VIEW} fill="url(#bh-space-glow)" pointerEvents="none" />
        <rect x={0} y={0} width={VIEW} height={VIEW} fill="url(#bh-space-nebula)" pointerEvents="none" />
        <rect x={0} y={0} width={VIEW} height={VIEW} fill="url(#bh-space-stars)" pointerEvents="none" />
        <rect x={0} y={0} width={VIEW} height={VIEW} fill="url(#bh-space-grid-minor)" pointerEvents="none" />
        <rect x={0} y={0} width={VIEW} height={VIEW} fill="url(#bh-space-grid-major)" pointerEvents="none" />
        <rect x={0} y={0} width={VIEW} height={VIEW} fill="url(#bh-space-vignette)" pointerEvents="none" />
        <g transform={`translate(${view.tx} ${view.ty}) scale(${view.k})`}>
          {/* S2 TERRITORY — world-true territory rings, composed by the pure, hook-free
              `territoryLayer` element helper (the fleetShipsLayer/teamMarkersLayer convention; the
              unit test calls the SAME function). FIRST child of the camera group: a territory is a
              region of space, so it renders UNDER movement lines and every marker. World-true
              radius (territory_radius * WORLD_TO_VIEWBOX_SCALE — scales with zoom, deliberately
              NOT /k); every element pointer-transparent. Locations without territory_radius render
              nothing — the pre-0217 map is byte-identical. */}
          {territoryLayer({ locations, norm, k: view.k })}

          {/* MINING-FIELD-MARKERS — the extraction-range ring per active field, same "world-true
              region, under every marker" placement as the territory rings just above (pure,
              hook-free `miningFieldRangeLayer`, unit-tested the SAME way). [] fields (mining
              disabled) or a non-positive radius → renders nothing. */}
          {miningFieldRangeLayer({ fields: miningFields, norm, k: view.k, radius: miningExtractRadius })}

          {/* PIRATE INTERCEPT (prototype) — smooth danger-zone blobs (get_danger_zones), ABOVE the
              plain circle territoryLayer rings (untouched) and UNDER movement lines/markers. []
              while the flag is dark (the caller's gate) → renders nothing, byte-identical to today. */}
          {dangerZoneLayer({ zones: dangerZones, norm, k: view.k })}

          {/* Movement paths (under markers) — IN-FLIGHT ONLY.
              The rows arrive already filtered to status='moving', but that status is settled by the 30s
              `process_fleet_movements` cron, so a finished trip keeps its row for up to ~30s and used to
              leave a stale path hanging on the map from a journey already over (with no ETA, since the
              countdown expires at arrive_at). The filter is display-only — it settles nothing and claims
              no arrival; it just stops drawing a path whose time is up. The 1s clock above retires the
              path within a second of arrival rather than waiting on the next poll. */}
          {movements.filter((m) => isMovementInFlight(m, nowMs)).map((m) => {
            // Draw the path from the fleet's CURRENT interpolated position (not the origin), so the
            // traversed portion disappears in real time as it advances — a shrinking remaining-path,
            // not a fixed origin→target trail. The 1s clock (nowMs) re-renders it each tick.
            const cur = interpolateMovementPoint(m, nowMs) ?? { x: m.origin_x, y: m.origin_y }
            const a = norm(cur)
            const b = norm({ x: m.target_x, y: m.target_y })
            return (
              <FleetMovementLine
                key={m.id}
                x1={a.x}
                y1={a.y}
                x2={b.x}
                y2={b.y}
                k={view.k}
                isReturn={m.target_type === 'base'}
                arriveAt={m.arrive_at}
                // S4 TIMED DOCKING: a 'dock' leg labels "Docking m:ss" (FleetMovementLine).
                missionType={m.mission_type}
              />
            )
          })}

          {/* locations */}
          {locations.map((loc) => {
            const p = norm({ x: loc.x, y: loc.y })
            return (
              <LocationMarker
                key={loc.id}
                x={p.x}
                y={p.y}
                k={view.k}
                location={loc}
                selected={loc.id === selectedId}
                // UI R1 label declutter: zoom-tiered reveal (pure policy in markerStyle.ts) — ports/
                // important locations are always labelled, lesser ones reveal as the player zooms in;
                // the selected marker is always labelled.
                showLabel={loc.id === selectedId || labelVisible(loc, view.k)}
                onSelect={onSelect}
              />
            )
          })}

          {/* MINING-FIELD-MARKERS — the interactive field glyphs (hexagon "gem", distinct from every
              LocationMarker shape). Positioned through the SAME `norm` world→viewBox projection as
              every other spatial object; a field is OPEN-SPACE world data (space_x/space_y), not a
              MapLocation, so it is not part of the `locations` list above. Always labelled (a
              handful of fields, world-wide — the whole point is to be found), unlike the zoom-tiered
              LocationMarker declutter built for a much denser location set. */}
          {miningFields.map((f) => {
            const p = norm({ x: f.space_x, y: f.space_y })
            return (
              <MiningFieldMarker
                key={f.name}
                x={p.x}
                y={p.y}
                k={view.k}
                field={f}
                selected={f.name === selectedMiningFieldName}
                onSelect={(field) => onSelectMiningField(field.name)}
              />
            )
          })}

          {/* TEAMMAP-2 — the team marker layer, composed by the pure, hook-free `teamMarkersLayer`
              helper (the shipLayer element-tree convention; the unit tests call the SAME function).
              ADDITIVE beside the existing layers: in-flight team badges ride the shared movement
              interpolation at the lead fleet's position (individual dashed lines + dots above stay
              untouched), and complete docked teams badge their port's marker position. Empty teams
              (TEAM_COMMAND dark, or no team in flight/docked) render nothing. */}
          {teamMarkersLayer({
            movements,
            groups: teamGroups,
            rollups: dockedTeamRollups,
            locations,
            norm,
            k: view.k,
            // FLEET-GO 4a-1: parked unified fleets → the in-space fleet badge ([] while dark).
            unifiedFleets: unifiedGroupFleets,
            // MAP-INTEGRATION M1: combat-present sorties → the in-combat fleet badge ([] while dark).
            combatFleets: combatSortieFleets,
          })}

          {/* COMBAT-S4 — the SPATIAL-COMBAT layer, composed by the pure, hook-free `spatialCombatLayer`
              helper (the territoryLayer/teamMarkersLayer element-tree convention; the unit test calls
              the SAME function). Renders the caller's active on-map battle: each positioned unit at its
              world pos (player accent chevrons vs enemy danger triangles), its weapon RANGE ring, and
              this tick's fire lines between units. Above the markers (the battle is the focus of the
              frame) and pointer-transparent (the location under it stays the tap target). DARK BY DATA:
              while spatial_combat_enabled is off, no combat_units row carries a position, so `combatUnits`
              has no positioned rows and this renders NOTHING — byte-identical to today. Re-renders each
              ~1.5s poll (useCombat), so approach + kiting + fire animate as ticks land. */}
          {spatialCombatLayer({ units: combatUnits, events: combatEvents, norm, k: view.k })}

          {/* 4C-CLIENT: the per-ship overlay layer (shipLayer — route + MainShipMarker) is DELETED
              with the per-ship movement client (S5 already deleted the redundant fleetShipsLayer).
              Owned ships are represented by the team badges above (fleeted) or as INFO surfaces
              (berthed — roster/Port labels); the legacy per-ship spatial states can no longer exist. */}

          {/* FLEET-GO 4a-2 — the FLEET's coordinate-go target (the same crosshair geometry, reused
              under its own testid + accent tone). Shows the CANONICAL point — the integer-grid
              destination 0208 will store — never the raw tap (which still rides the wire untouched).
              S5 MAP-UX: driven by the fleetGoView PROP (MapScreen owns the target union); renders
              only while a point target exists AND lies within bounds. */}
          {fleetGoView && fleetGoView.withinBounds && (
            <SpaceMoveTargetMarker
              target={fleetGoView.canonical}
              k={view.k}
              testId="fleet-go-target"
              stroke="var(--color-accent)"
            />
          )}

          {/* PIRATE INTERCEPT (prototype) — the in-progress route/zone draft: a connected polyline
              through the tapped points + a dot per vertex. 'off' or an empty draft renders nothing. */}
          {pirateMode !== 'off' && pirateDraftPoints.length > 0 && (
            <g data-testid="pirate-draft-layer" style={{ pointerEvents: 'none' }}>
              {pirateDraftPoints.length > 1 && (
                <polyline
                  points={pirateDraftPoints.map((p) => { const s = norm(p); return `${s.x},${s.y}` }).join(' ')}
                  fill="none"
                  stroke="var(--color-accent)"
                  strokeWidth={1.5 / view.k}
                  strokeDasharray={`${4 / view.k} ${3 / view.k}`}
                />
              )}
              {pirateDraftPoints.map((p, i) => {
                const s = norm(p)
                return <circle key={i} cx={s.x} cy={s.y} r={4 / view.k} fill="var(--color-accent)" />
              })}
            </g>
          )}

          {/* OSN-3 S6B3 — DEVELOPMENT-ONLY, non-interactive fixed-space preview. Final visual child of the
              camera <g> (top z), pointer-transparent. `import.meta.env.DEV` is statically `false` in
              `vite build`, so this branch (and the imported module + its sentinel) is compile-time
              eliminated from the production bundle. It does not alter camera/viewBox/pan or the ordering
              of any existing production marker. */}
          {import.meta.env.DEV && <DevFixedSpacePreview k={view.k} />}
        </g>
      </svg>

      {/* ── UI R1 overlay slots: one positioned rail per corner; co-corner overlays stack instead of
          colliding at hand-tuned absolute offsets. MapScreen owns the remaining slots (top-left =
          the feature rail, top-center = world events, bottom-right = the ONE FleetCommandPanel). ── */}

      {/* top-right: the zoom cluster. S5 MAP-UX: the fleet coordinate-go confirm panel that used to
          stack here moved into the ONE bottom-center FleetCommandPanel (MapScreen). */}
      <OverlayRail slot="top-right">
        <OverlayPanel className="flex flex-col gap-1">
          <Button size="icon" onClick={() => zoomByFactor(1.25)} aria-label="Zoom in">+</Button>
          <Button size="icon" onClick={() => zoomByFactor(1 / 1.25)} aria-label="Zoom out">−</Button>
          <Button size="icon" onClick={reset} aria-label="Reset view" className="text-xs">⟲</Button>
        </OverlayPanel>
      </OverlayRail>

      {/* bottom-left: player-facing marker key + hint (pointer-transparent — never blocks map gestures).
          Mirrors the markerStyle glyph semantics exactly: diamond port / circle waypoint / triangle hostile. */}
      {/* bottom-left: collapsible marker key — a small "Map key" chip by default so it never
          covers the map; expands to a readable vertical list (was a tiny wrapping block that
          sprawled across the bottom on narrow screens). */}
      <OverlayPanel slot="bottom-left" className="pointer-events-auto max-w-[calc(100vw-1.5rem)] text-sm text-ink-muted">
        <details>
          <summary className="cursor-pointer select-none list-none font-medium">Map key</summary>
          <div className="mt-2 flex flex-col gap-1.5 text-ink-faint">
            <span className="flex items-center gap-1.5">
              <svg viewBox="0 0 10 10" className="h-3 w-3" aria-hidden="true">
                <polygon points="5,0 10,5 5,10 0,5" fill="var(--color-accent)" />
              </svg>
              Port — dock &amp; trade
            </span>
            <span className="flex items-center gap-1.5">
              <svg viewBox="0 0 10 10" className="h-3 w-3" aria-hidden="true">
                <circle cx="5" cy="5" r="4" fill="var(--color-success)" />
              </svg>
              Safe
            </span>
            <span className="flex items-center gap-1.5">
              <svg viewBox="0 0 10 10" className="h-3 w-3" aria-hidden="true">
                <polygon points="5,0.5 9.5,9 0.5,9" fill="var(--color-danger)" />
              </svg>
              Hostile
            </span>
            {miningFields.length > 0 && (
              <span className="flex items-center gap-1.5">
                <svg viewBox="0 0 10 10" className="h-3 w-3" aria-hidden="true">
                  <polygon points="9.7,5 6.7,10 3.3,10 0.3,5 3.3,0 6.7,0" fill="var(--color-warning)" />
                </svg>
                Mining field — settle within range to extract
              </span>
            )}
            <span className="mt-1">Double-tap the map to command · tap a marker for details · drag to pan · scroll to zoom</span>
          </div>
        </details>
      </OverlayPanel>
    </div>
  )
}
