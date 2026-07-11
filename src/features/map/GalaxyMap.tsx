import { useCallback, useEffect, useMemo, useRef, useState, type PointerEvent as RPointerEvent } from 'react'
import type { MapLocation } from './mapTypes'
import type { FleetMovement } from '../fleets/fleetTypes'
import type { MainShipLite } from './useGalaxyMapData'
import type { MainShipFleet, MainShipPresence, MainShipSpaceMovement } from './mainshipApi'
import { LocationMarker } from './LocationMarker'
import { FleetMovementLine } from './FleetMovementLine'
import { shipLayer } from './SpaceRouteLine'
import { DevFixedSpacePreview } from './DevFixedSpacePreview'
import { useSpaceMoveCommand } from './useSpaceMoveCommand'
import { useSpaceStopCommand } from './useSpaceStopCommand'
import { SpaceMoveTargetMarker, SpaceMoveControls, type SpaceMoveEligibility } from './SpaceMoveTarget'
import { SpaceStopControls } from './SpaceStopControls'
import { isActiveCoordinateTransit } from './spaceStopCommand'
import { classifyPointerGesture } from './spaceMoveCommand'
import { screenToWorld, worldToViewBox, type WorldCoord } from './openSpaceTransform'
import { VIEW, clampK, clampPan, focusCamera, focusWorldPoints, type Camera, type FocusInputs } from './galaxyCamera'
import { useOsnReadiness } from './useOsnReadiness'
import { isCoordinateTargetingActionable, type OsnReadiness } from './osnReadiness'
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

export function GalaxyMap({
  locations,
  mainShip,
  mainShipFleet,
  mainShipPresence,
  mainShipSpaceMovement,
  mainshipSendEnabled,
  movements,
  selectedId,
  onSelect,
  deps,
}: {
  locations: MapLocation[]
  mainShip: MainShipLite | null
  mainShipFleet: MainShipFleet | null
  mainShipPresence: MainShipPresence | null
  mainShipSpaceMovement: MainShipSpaceMovement | null
  mainshipSendEnabled: boolean
  movements: FleetMovement[]
  selectedId: string | null
  onSelect: (id: string | null) => void
  // Test/integration injection seam; defaults to the real server readiness + movement-flag reads.
  deps?: {
    readinessFetcher?: () => Promise<OsnReadiness>
    spaceMoveEnabled?: boolean
  }
}) {
  const svgRef = useRef<SVGSVGElement | null>(null)
  const [view, setView] = useState<Camera>({ k: 1, tx: 0, ty: 0 })
  const drag = useRef<{ x: number; y: number; tx: number; ty: number } | null>(null)
  // S6B-PRES camera policy: content-fit is applied for the initial view + explicit reset only; once the
  // player pans/zooms (`userMovedRef`) the camera is frozen. `lastFitSig` makes the fit fire once per
  // meaningful focus change rather than per animation frame.
  const userMovedRef = useRef(false)
  const lastFitSig = useRef<string | null>(null)

  // ── OSN-3 S6C — empty-space coordinate command surface (flag-dark by default) ──
  // The hook reads `mainship_space_movement_enabled` itself; while dark `sm.enabled` is false and the
  // whole surface stays unmounted → zero production visual change. Coordinate-target taps are only
  // captured when the flag is on AND the ship is eligible. Camera behavior is unchanged either way.
  const sm = useSpaceMoveCommand()
  // OSN-4 — Stop safety. The CTA mounts ONLY for a real active coordinate transit and is INDEPENDENT of the
  // initiation flag (in-flight safety): an emergency flag disable must never strand an in-flight ship.
  const stop = useSpaceStopCommand({ mainShipId: mainShip?.main_ship_id ?? null })
  const inCoordinateTransit = isActiveCoordinateTransit({
    spatialState: mainShip?.spatial_state,
    spaceMovementStatus: mainShipSpaceMovement?.status,
    spaceMovementTargetKind: mainShipSpaceMovement?.target_kind,
  })
  const eligibility: SpaceMoveEligibility = !mainShip
    ? 'no_ship'
    : mainShip.status === 'destroyed' || mainShip.spatial_state === 'destroyed'
      ? 'destroyed'
      : mainShip.status === 'traveling' ||
          mainShip.spatial_state === 'in_transit' ||
          mainShipFleet?.status === 'moving' ||
          mainShipFleet?.status === 'returning' ||
          mainShipSpaceMovement?.status === 'moving'
        ? 'in_transit'
        : 'eligible'
  // OSN-COORD-ENABLE-1C — runtime coordinate capability. The empty-space command surface is driven SOLELY by
  // the server-derived readiness projection (coordinate_travel_available), NOT the retired compile-time const.
  // Readiness re-validates on mount, on any main-ship/movement lifecycle change, and on a manual refresh after
  // a coordinate command completes. While production stays dark (mainship_coordinate_travel_enabled=false) the
  // server returns coordinate_travel_available=false → canTarget is false → the whole surface stays unmounted.
  const readinessLifecycleKey = `${mainShip?.status ?? 'n'}|${mainShip?.spatial_state ?? 'n'}|${mainShipPresence?.location_id ?? 'none'}|${mainShipSpaceMovement?.id ?? 'none'}|${mainShipSpaceMovement?.status ?? 'none'}`
  const { readiness, refresh: refreshReadiness } = useOsnReadiness(readinessLifecycleKey, { mainShipId: mainShip?.main_ship_id ?? null, fetcher: deps?.readinessFetcher })
  const spaceMoveEnabled = deps?.spaceMoveEnabled ?? sm.enabled
  const canTarget = isCoordinateTargetingActionable(readiness, spaceMoveEnabled, eligibility)
  // Gesture bookkeeping: a single short near-stationary pointer on EMPTY space is a target tap; drags
  // and multi-touch stay map pan. Tracked alongside (never replacing) the existing pan snapshot.
  const tap = useRef<{ x: number; y: number; t: number; maxPointers: number } | null>(null)
  const pointers = useRef<Set<number>>(new Set())

  // ── S6B-PRES content-fit camera (presentation only; never alters world/marker coordinates) ──
  // Deterministic focus: open-space / in-transit ships and their active movement segment take focus
  // priority so the player is always visible. Derived PURELY from ship state (no clock / interpolation),
  // so it is render-pure and the focus signature stays stable per move (not per animation frame).
  const focusInputs: FocusInputs = useMemo(() => {
    const sx = mainShip?.space_x
    const sy = mainShip?.space_y
    const shipWorld: WorldCoord | null =
      mainShip?.spatial_state === 'in_space' && typeof sx === 'number' && Number.isFinite(sx) && typeof sy === 'number' && Number.isFinite(sy)
        ? { x: sx, y: sy }
        : null
    const seg: readonly [WorldCoord, WorldCoord] | null =
      mainShipSpaceMovement && mainShipSpaceMovement.status === 'moving'
        ? [
            { x: mainShipSpaceMovement.origin_x, y: mainShipSpaceMovement.origin_y },
            { x: mainShipSpaceMovement.target_x, y: mainShipSpaceMovement.target_y },
          ]
        : null
    return {
      shipWorld,
      movementSegment: seg,
      locations: locations.map((l) => ({ x: l.x, y: l.y })),
    }
  }, [mainShip?.spatial_state, mainShip?.space_x, mainShip?.space_y, mainShipSpaceMovement, locations])

  // Stable focus signature: changes only on a MEANINGFUL focus change (open-space mode / active
  // movement id / parked point / named-content set), never per animation frame — so the fit is applied
  // once per context. Uses the static space_x/space_y + movement id, never the live interpolated point.
  const focusSignature = useMemo(() => {
    if (focusInputs.shipWorld || focusInputs.movementSegment) {
      const seg = mainShipSpaceMovement?.status === 'moving' ? mainShipSpaceMovement.id : 'noseg'
      return `os:${mainShip?.spatial_state ?? 'n'}:${seg}:${mainShip?.space_x ?? 'n'},${mainShip?.space_y ?? 'n'}`
    }
    return `named:${locations.map((l) => l.id).join(',')}`
  }, [focusInputs, mainShip?.spatial_state, mainShip?.space_x, mainShip?.space_y, mainShipSpaceMovement, locations])

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
    // S6C: a single short near-stationary tap on EMPTY space (the <svg> itself — markers/backdrop don't
    // hit here) selects a coordinate target. Only when the flag is on and the ship is eligible.
    const svg = svgRef.current
    if (!canTarget || !t || !svg || e.target !== svg) return
    const travelPx = Math.hypot(e.clientX - t.x, e.clientY - t.y)
    const durationMs = e.timeStamp - t.t
    if (classifyPointerGesture({ travelPx, durationMs, maxPointers: t.maxPointers }) !== 'tap') return
    const rect = svg.getBoundingClientRect()
    sm.selectTarget(
      screenToWorld(
        { x: e.clientX - rect.left, y: e.clientY - rect.top },
        { k: view.k, tx: view.tx, ty: view.ty },
        { width: rect.width, height: rect.height },
      ),
    )
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
        onClick={() => onSelect(null)}
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
          {/* movement paths (under markers) */}
          {movements.map((m) => {
            const a = norm({ x: m.origin_x, y: m.origin_y })
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

          {/* OSN-1 + OSN-3 S6B-ROUTE: the local player's own ship overlay layer, composed by the pure,
              hook-free `shipLayer` helper (route UNDER the main-ship marker, in that order). Gated by the
              existing `mainshipSendEnabled` data-dark gate — NOT the space-movement flag; both children are
              naturally empty in production (no coherent active coordinate route can exist while
              mainship_space_movement_enabled = false). Read-only; coherence comes solely from the resolvers.
              The single helper is what the GalaxyMap-wiring unit test exercises (no duplicated wiring). */}
          {shipLayer({
            mainshipSendEnabled,
            inputs: { mainShip, mainShipFleet, presence: mainShipPresence, spaceMovement: mainShipSpaceMovement, movements, locations },
            norm,
            k: view.k,
          })}

          {/* OSN-3 S6C — empty-space coordinate target preview (fixed-domain transform, pointer-transparent).
              Mounted only when the flag is on, the ship is eligible, and a within-bounds target is chosen. */}
          {canTarget && sm.state.target && sm.state.targetWithinBounds && (
            <SpaceMoveTargetMarker target={sm.state.target} k={view.k} />
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
          colliding at hand-tuned absolute offsets. MapScreen owns the remaining corners (top-left =
          port nav + feature rail, top-center = world events, bottom-right = the legacy stop, which is
          mutually exclusive by state with the coordinate stop below — one active movement owner). ── */}

      {/* top-right: zoom cluster + (when server-lit) the coordinate-move controls, stacked */}
      <OverlayRail slot="top-right">
        <OverlayPanel className="flex flex-col gap-1">
          <Button size="icon" onClick={() => zoomByFactor(1.25)} aria-label="Zoom in">+</Button>
          <Button size="icon" onClick={() => zoomByFactor(1 / 1.25)} aria-label="Zoom out">−</Button>
          <Button size="icon" onClick={reset} aria-label="Reset view" className="text-xs">⟲</Button>
        </OverlayPanel>

        {/* OSN-3 S6C / OSN-COORD-ENABLE-1C — overlay controls. Mounts ONLY when the SERVER readiness
            capability is true AND the movement domain is enabled AND the ship is eligible (canTarget).
            While production is dark (coordinate_travel_available=false) it never mounts; a non-'eligible'
            ship also keeps it hidden. Port-to-port travel is a separate release surface (PortNavPanel). */}
        {canTarget && (
          <SpaceMoveControls
            enabled={spaceMoveEnabled}
            eligibility={eligibility}
            phase={sm.state.phase}
            target={sm.state.target}
            targetWithinBounds={sm.state.targetWithinBounds}
            serverTarget={sm.state.serverTarget}
            errorMessage={sm.state.errorMessage}
            onConfirm={() => void sm.submit().finally(() => refreshReadiness())}
            onClear={sm.clear}
          />
        )}
      </OverlayRail>

      {/* OSN-4 — Stop safety CTA (bottom-right slot). Mounted ONLY for a real active coordinate transit,
          INDEPENDENT of the initiation flag (in-flight safety). Today this condition is unreachable (no
          coordinate moves exist while the flag is false) → dark in production. */}
      {inCoordinateTransit && (
        <SpaceStopControls
          slot="bottom-right"
          phase={stop.state.phase}
          errorMessage={stop.state.errorMessage}
          outcome={stop.state.outcome}
          onStop={() => void stop.submit()}
        />
      )}

      {/* bottom-left: player-facing marker key + hint (pointer-transparent — never blocks map gestures).
          Mirrors the markerStyle glyph semantics exactly: diamond port / circle waypoint / triangle hostile. */}
      <OverlayPanel slot="bottom-left" inert className="flex flex-wrap items-center gap-x-3 gap-y-1 text-[10px] text-ink-faint">
        <span className="flex items-center gap-1">
          <svg viewBox="0 0 10 10" className="h-2.5 w-2.5" aria-hidden="true">
            <polygon points="5,0 10,5 5,10 0,5" fill="var(--color-accent)" />
          </svg>
          Port — dock &amp; trade
        </span>
        <span className="flex items-center gap-1">
          <svg viewBox="0 0 10 10" className="h-2.5 w-2.5" aria-hidden="true">
            <circle cx="5" cy="5" r="4" fill="var(--color-success)" />
          </svg>
          Safe
        </span>
        <span className="flex items-center gap-1">
          <svg viewBox="0 0 10 10" className="h-2.5 w-2.5" aria-hidden="true">
            <polygon points="5,0.5 9.5,9 0.5,9" fill="var(--color-danger)" />
          </svg>
          Hostile
        </span>
        <span className="basis-full">Tap a marker for details · drag to pan · scroll to zoom</span>
      </OverlayPanel>
    </div>
  )
}
