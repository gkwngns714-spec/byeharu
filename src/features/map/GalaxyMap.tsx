import { useEffect, useMemo, useRef, useState, type PointerEvent as RPointerEvent, type WheelEvent as RWheelEvent } from 'react'
import type { MapLocation } from './mapTypes'
import type { Base } from '../base/baseTypes'
import type { FleetMovement } from '../fleets/fleetTypes'
import type { MainShipLite } from './useGalaxyMapData'
import type { MainShipFleet, MainShipPresence, MainShipSpaceMovement } from './mainshipApi'
import { LocationMarker } from './LocationMarker'
import { FleetMovementLine } from './FleetMovementLine'
import { MainShipMarker } from './MainShipMarker'
import { DevFixedSpacePreview } from './DevFixedSpacePreview'
import { useSpaceMoveCommand } from './useSpaceMoveCommand'
import { useSpaceStopCommand } from './useSpaceStopCommand'
import { SpaceMoveTargetMarker, SpaceMoveControls, type SpaceMoveEligibility } from './SpaceMoveTarget'
import { SpaceStopControls } from './SpaceStopControls'
import { isActiveCoordinateTransit } from './spaceStopCommand'
import { classifyPointerGesture } from './spaceMoveCommand'
import { screenToWorld, worldToViewBox, type WorldCoord } from './openSpaceTransform'
import { VIEW, clampK, clampPan, focusCamera, focusWorldPoints, type Camera, type FocusInputs } from './galaxyCamera'

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
  base,
  mainShip,
  mainShipFleet,
  mainShipPresence,
  mainShipSpaceMovement,
  mainshipSendEnabled,
  movements,
  selectedId,
  onSelect,
}: {
  locations: MapLocation[]
  base: Base | null
  mainShip: MainShipLite | null
  mainShipFleet: MainShipFleet | null
  mainShipPresence: MainShipPresence | null
  mainShipSpaceMovement: MainShipSpaceMovement | null
  mainshipSendEnabled: boolean
  movements: FleetMovement[]
  selectedId: string | null
  onSelect: (id: string | null) => void
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
  const stop = useSpaceStopCommand()
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
  const canTarget = sm.enabled && eligibility === 'eligible'
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
      base: base ? { x: base.x, y: base.y } : null,
    }
  }, [mainShip?.spatial_state, mainShip?.space_x, mainShip?.space_y, mainShipSpaceMovement, locations, base])

  // Stable focus signature: changes only on a MEANINGFUL focus change (open-space mode / active
  // movement id / parked point / named-content set), never per animation frame — so the fit is applied
  // once per context. Uses the static space_x/space_y + movement id, never the live interpolated point.
  const focusSignature = useMemo(() => {
    if (focusInputs.shipWorld || focusInputs.movementSegment) {
      const seg = mainShipSpaceMovement?.status === 'moving' ? mainShipSpaceMovement.id : 'noseg'
      return `os:${mainShip?.spatial_state ?? 'n'}:${seg}:${mainShip?.space_x ?? 'n'},${mainShip?.space_y ?? 'n'}`
    }
    return `named:${locations.map((l) => l.id).join(',')}|${base ? `${base.x},${base.y}` : ''}`
  }, [focusInputs, mainShip?.spatial_state, mainShip?.space_x, mainShip?.space_y, mainShipSpaceMovement, locations, base])

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

  const showLabels = view.k >= 0.9

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
  const onWheel = (e: RWheelEvent) => {
    userMovedRef.current = true // player took camera control → freeze auto-fit
    const factor = e.deltaY < 0 ? 1.15 : 1 / 1.15
    setView((v) => {
      const k = clampK(v.k * factor)
      const ratio = k / v.k
      // zoom around viewBox centre (500,500) — keeps it simple + stable on mobile.
      const cx = VIEW / 2
      const cy = VIEW / 2
      return { k, ...clampPan(cx - (cx - v.tx) * ratio, cy - (cy - v.ty) * ratio, k) }
    })
  }
  const zoomBtn = (factor: number) => {
    userMovedRef.current = true // player took camera control → freeze auto-fit
    setView((v) => {
      const k = clampK(v.k * factor)
      const ratio = k / v.k
      const cx = VIEW / 2
      const cy = VIEW / 2
      return { k, ...clampPan(cx - (cx - v.tx) * ratio, cy - (cy - v.ty) * ratio, k) }
    })
  }
  // Reset re-enables the deterministic content-fit camera (frames the player ship / active movement,
  // else named content). NOT k=1/origin — at k=1 the fixed frame would show current seed content as a
  // tiny central cluster.
  const reset = () => {
    userMovedRef.current = false
    const pts = focusWorldPoints(focusInputs)
    lastFitSig.current = focusSignature
    setView(pts.length ? focusCamera(focusInputs) : { k: 1, tx: 0, ty: 0 })
  }

  const homePt = base ? norm({ x: base.x, y: base.y }) : null

  return (
    <div className="relative h-full w-full overflow-hidden rounded-lg border border-slate-700 bg-[#070b14]">
      {/* zoom controls */}
      <div className="absolute right-2 top-2 z-10 flex flex-col gap-1">
        <button onClick={() => zoomBtn(1.25)} className="h-8 w-8 rounded bg-slate-800/90 text-lg text-slate-200 hover:bg-slate-700" aria-label="Zoom in">+</button>
        <button onClick={() => zoomBtn(1 / 1.25)} className="h-8 w-8 rounded bg-slate-800/90 text-lg text-slate-200 hover:bg-slate-700" aria-label="Zoom out">−</button>
        <button onClick={reset} className="h-8 w-8 rounded bg-slate-800/90 text-xs text-slate-200 hover:bg-slate-700" aria-label="Reset view">⟲</button>
      </div>

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
        onWheel={onWheel}
        onClick={() => onSelect(null)}
      >
        {/* Static backdrop (NOT transformed): the map area always renders a deliberate background,
            even at the camera bounds. Visual safety layer only — not a map-layer framework. */}
        <rect x={0} y={0} width={VIEW} height={VIEW} fill="#070b14" pointerEvents="none" />
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

          {/* home base + main-ship anchor */}
          {homePt && (
            <g style={{ pointerEvents: 'none' }}>
              <rect
                x={homePt.x - 6 / view.k}
                y={homePt.y - 6 / view.k}
                width={12 / view.k}
                height={12 / view.k}
                fill="#22d3ee"
                stroke="#0b1220"
                strokeWidth={1}
                vectorEffect="non-scaling-stroke"
                transform={`rotate(45 ${homePt.x} ${homePt.y})`}
              />
              {showLabels && (
                <text x={homePt.x} y={homePt.y + 16 / view.k} fontSize={11 / view.k} textAnchor="middle" fill="#67e8f9">
                  {base?.name ?? 'Home'}
                  {mainShip ? ` · ${mainShip.name}` : ''}
                </text>
              )}
            </g>
          )}

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
                showLabel={showLabels}
                onSelect={onSelect}
              />
            )
          })}

          {/* OSN-1: local player's own main-ship marker — top of the transform group, pointer-transparent,
              flag-gated. Read-only; position comes solely from resolveMainShipMarker. */}
          {mainshipSendEnabled && (
            <MainShipMarker
              inputs={{ mainShip, mainShipFleet, presence: mainShipPresence, spaceMovement: mainShipSpaceMovement, movements, base, locations }}
              norm={norm}
              k={view.k}
            />
          )}

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

      {/* OSN-3 S6C — overlay controls. Mounted only when coordinate movement is enabled (dark = absent →
          zero production change). Empty-space only; copy never implies docking at a named location. */}
      {sm.enabled && mainShip && (
        <SpaceMoveControls
          enabled={sm.enabled}
          eligibility={eligibility}
          phase={sm.state.phase}
          target={sm.state.target}
          targetWithinBounds={sm.state.targetWithinBounds}
          serverTarget={sm.state.serverTarget}
          errorMessage={sm.state.errorMessage}
          onConfirm={() => void sm.submit()}
          onClear={sm.clear}
        />
      )}

      {/* OSN-4 — Stop safety CTA. Mounted ONLY for a real active coordinate transit, INDEPENDENT of the
          initiation flag (in-flight safety). Today this condition is unreachable (no coordinate moves exist
          while the flag is false) → dark in production. Target selection / new-move stay flag-gated above. */}
      {inCoordinateTransit && (
        <SpaceStopControls
          phase={stop.state.phase}
          errorMessage={stop.state.errorMessage}
          outcome={stop.state.outcome}
          onStop={() => void stop.submit()}
        />
      )}

      <div className="pointer-events-none absolute bottom-2 left-2 z-10 text-[10px] text-slate-500">
        {locations.length} locations · {movements.length} moving · drag to pan · scroll/buttons to zoom
      </div>
    </div>
  )
}
