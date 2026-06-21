import { useMemo, useRef, useState, type PointerEvent as RPointerEvent, type WheelEvent as RWheelEvent } from 'react'
import type { MapLocation } from './mapTypes'
import type { Base } from '../base/baseTypes'
import type { FleetMovement } from '../fleets/fleetTypes'
import type { MainShipLite } from './useGalaxyMapData'
import type { MainShipFleet, MainShipPresence, MainShipSpaceMovement } from './mainshipApi'
import { LocationMarker } from './LocationMarker'
import { FleetMovementLine } from './FleetMovementLine'
import { MainShipMarker } from './MainShipMarker'

// Read-only 2D galaxy map (plain SVG — no canvas/WebGL). World coordinates are normalized
// once into a 0..1000 viewBox; a transform group provides pan (drag) + zoom (wheel/buttons).
// Nothing here writes to the database.

const VIEW = 1000
const PAD = 0.08

interface Pt { x: number; y: number }

function buildNormalizer(points: Pt[]): (p: Pt) => Pt {
  const xs = points.map((p) => p.x)
  const ys = points.map((p) => p.y)
  const minX = points.length ? Math.min(...xs) : 0
  const maxX = points.length ? Math.max(...xs) : 0
  const minY = points.length ? Math.min(...ys) : 0
  const maxY = points.length ? Math.max(...ys) : 0
  const span = Math.max(maxX - minX, maxY - minY) || 1
  const inner = VIEW * (1 - 2 * PAD)
  const scale = inner / span
  const offX = VIEW * PAD + (inner - (maxX - minX) * scale) / 2
  const offY = VIEW * PAD + (inner - (maxY - minY) * scale) / 2
  // Flip Y so larger world-y renders upward (screen y grows downward).
  return (p: Pt) => ({ x: offX + (p.x - minX) * scale, y: VIEW - (offY + (p.y - minY) * scale) })
}

const clampK = (k: number) => Math.min(8, Math.max(0.4, k))

// Camera pan bounds: keep the transformed content overlapping the 0..VIEW viewBox so the map can
// never be dragged/zoomed completely off-screen (fixes the "black screen on pan" bug). When zoomed
// in (content ≥ viewport) the viewport stays fully covered; when zoomed out, content stays inside.
// This only bounds the camera — future gameplay overlays (trading/mining/combat/routes) should be
// added as separate layers later, not folded into this clamp.
function clampPan(tx: number, ty: number, k: number): { tx: number; ty: number } {
  const content = k * VIEW
  const [minT, maxT] = content >= VIEW ? [VIEW - content, 0] : [0, VIEW - content]
  const cl = (t: number) => Math.min(maxT, Math.max(minT, t))
  return { tx: cl(tx), ty: cl(ty) }
}

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
  const [view, setView] = useState({ k: 1, tx: 0, ty: 0 })
  const drag = useRef<{ x: number; y: number; tx: number; ty: number } | null>(null)

  const norm = useMemo(() => {
    const pts: Pt[] = locations.map((l) => ({ x: l.x, y: l.y }))
    if (base) pts.push({ x: base.x, y: base.y })
    for (const m of movements) {
      pts.push({ x: m.origin_x, y: m.origin_y })
      pts.push({ x: m.target_x, y: m.target_y })
    }
    return buildNormalizer(pts)
  }, [locations, base, movements])

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
  }
  const onPointerMove = (e: RPointerEvent) => {
    // Capture the drag snapshot locally. The setView updater runs LATER (React render phase), and
    // drag.current can be null by then (pointer already released) — dereferencing it inside the
    // updater crashed the whole tree ("Cannot read properties of null (reading 'tx')"), which with
    // no error boundary blanked the page on pan. The captured `d` is guaranteed non-null here.
    const d = drag.current
    if (!d) return
    const dx = toSvgUnits(e.clientX - d.x)
    const dy = toSvgUnits(e.clientY - d.y)
    setView((v) => ({ ...v, ...clampPan(d.tx + dx, d.ty + dy, v.k) }))
  }
  const onPointerUp = () => { drag.current = null }
  const onWheel = (e: RWheelEvent) => {
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
  const zoomBtn = (factor: number) =>
    setView((v) => {
      const k = clampK(v.k * factor)
      const ratio = k / v.k
      const cx = VIEW / 2
      const cy = VIEW / 2
      return { k, ...clampPan(cx - (cx - v.tx) * ratio, cy - (cy - v.ty) * ratio, k) }
    })
  // Reset is already a safe state (k=1 → clampPan bounds force tx=ty=0).
  const reset = () => setView({ k: 1, tx: 0, ty: 0 })

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
        onPointerLeave={onPointerUp}
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
        </g>
      </svg>

      <div className="pointer-events-none absolute bottom-2 left-2 z-10 text-[10px] text-slate-500">
        {locations.length} locations · {movements.length} moving · drag to pan · scroll/buttons to zoom
      </div>
    </div>
  )
}
