// WORLD EDITOR — V3A PR-2 ZONE GEOMETRY HANDLES (the ONE interactive geometry-gesture layer). An
// interactive <g> rendered INSIDE the camera <g> (unlike DraftPreviewOverlay it takes pointer
// events): vertex grips, edge-midpoint insert grips, circle center/radius grips, and the draw-mode
// capture surface. Every gesture converts pointer → world through the ONE shared inverse projection
// (openSpaceTransform.screenToWorld with the live camera + the svg's real pixel bbox — never a
// bespoke transform, §WE.11: the retired ZoneEditor's fit-to-content fork was exactly that) and
// writes EXCLUSIVELY via `patchGeometry` → store.patchDraft(draftId, { geometry }) — a LOCAL draft
// patch. ZERO live zone write: no RPC, no zone-RPC-client or publish-transport import (guarded by
// tests/zoneDraftGuards.spec.ts).
//
// INTERACTION MODES are SHELL state (WorldEditor useState), never store state — the store holds
// authoring INTENT (the draft), not gesture ephemera:
//   idle         — nothing interactive; the map pans/selects as usual.
//   drawCircle   — pointerdown sets the center, dragging grows the radius, release finishes
//                  (→ editVertices).
//   drawPolygon  — click appends a vertex; clicking the FIRST vertex (or the panel's Close button)
//                  finalizes (→ editVertices); the panel's Undo pops the last vertex.
//   editVertices — drag a vertex grip to move it; click an edge-midpoint grip to insert a vertex
//                  (and immediately drag it); double-click a vertex to delete it (guarded: a ring
//                  keeps ≥3 vertices); drag the circle's center/radius grips to move/resize.
// Grips counter-scale by /view.k (the constant on-screen-size `r / k` idiom).
import { useEffect, useRef, useState, type PointerEvent as RPointerEvent, type RefObject } from 'react'
import { VIEW, type Camera } from '../map/galaxyCamera'
import {
  screenToWorld,
  worldToViewBox,
  type WorldCoord,
} from '../map/openSpaceTransform'
import type { WorldPoint } from './worldEditorTypes'
import type { ZoneDraft, ZoneGeometry } from './zoneDraftTypes'

/** The zone gesture mode — SHELL/component state (WorldEditor owns it; the panel's draw-mode buttons
 *  set it; this layer consumes it). Deliberately NOT part of the draft store. */
export type ZoneGestureMode = 'idle' | 'drawCircle' | 'drawPolygon' | 'editVertices'

/** Snap authored world coords to 0.01 world units (the ZoneEditor precision) — keeps stored payloads
 *  small and diffs readable; a snap of the AUTHORED value is input shaping, not hidden clamping. */
const snap = (n: number): number => Math.round(n * 100) / 100

type DragState =
  | { readonly kind: 'circle-new'; readonly center: WorldPoint }
  | { readonly kind: 'circle-center' }
  | { readonly kind: 'circle-radius' }
  | { readonly kind: 'vertex'; readonly index: number }

export function ZoneGeometryHandles({
  draft,
  mode,
  onModeChange,
  patchGeometry,
  view,
  svgRef,
}: {
  draft: ZoneDraft
  mode: ZoneGestureMode
  onModeChange: (mode: ZoneGestureMode) => void
  /** The ONLY write path: shell-bound store.patchDraft(draft.draftId, { geometry }). */
  patchGeometry: (geometry: ZoneGeometry) => void
  view: Camera
  svgRef: RefObject<SVGSVGElement | null>
}) {
  const [drag, setDrag] = useState<DragState | null>(null)
  // The latest geometry for pointer-move handlers, synced post-commit (the useDrafts stateRef
  // idiom): event handlers fire after commit, so they always read the latest patched geometry.
  const geometryRef = useRef(draft.payload.geometry)
  useEffect(() => {
    geometryRef.current = draft.payload.geometry
  }, [draft.payload.geometry])

  const k = view.k
  const geometry = draft.payload.geometry

  /** Pointer event → canonical world coords via the ONE shared inverse (camera + real svg bbox). */
  const toWorld = (e: { clientX: number; clientY: number }): WorldPoint | null => {
    const svg = svgRef.current
    if (!svg) return null
    const rect = svg.getBoundingClientRect()
    const w: WorldCoord = screenToWorld(
      { x: e.clientX - rect.left, y: e.clientY - rect.top },
      view,
      { width: rect.width, height: rect.height },
    )
    return { x: snap(w.x), y: snap(w.y) }
  }

  const grab = (e: RPointerEvent, next: DragState) => {
    e.stopPropagation()
    ;(e.currentTarget as Element).setPointerCapture?.(e.pointerId)
    setDrag(next)
  }

  const onGripMove = (e: RPointerEvent) => {
    if (!drag) return
    const w = toWorld(e)
    if (!w) return
    const g = geometryRef.current
    if (drag.kind === 'circle-new' || drag.kind === 'circle-radius') {
      if (drag.kind === 'circle-new') {
        patchGeometry({
          kind: 'circle',
          center: drag.center,
          radius: snap(Math.hypot(w.x - drag.center.x, w.y - drag.center.y)),
        })
        return
      }
      if (g.kind !== 'circle') return
      patchGeometry({
        kind: 'circle',
        center: g.center,
        radius: snap(Math.hypot(w.x - g.center.x, w.y - g.center.y)),
      })
      return
    }
    if (drag.kind === 'circle-center') {
      if (g.kind !== 'circle') return
      patchGeometry({ kind: 'circle', center: w, radius: g.radius })
      return
    }
    // vertex move
    if (g.kind !== 'polygon' || drag.index >= g.vertices.length) return
    patchGeometry({
      kind: 'polygon',
      vertices: g.vertices.map((v, i) => (i === drag.index ? w : v)),
    })
  }

  const onGripUp = (e: RPointerEvent) => {
    if (!drag) return
    e.stopPropagation()
    const wasNewCircle = drag.kind === 'circle-new'
    setDrag(null)
    if (wasNewCircle) onModeChange('editVertices')
  }

  // ── draw-mode capture surface: the visible viewport in camera coords (this <g> lives INSIDE the
  // camera transform, so the on-screen square is (0,0)..(VIEW,VIEW) mapped back through it). ─────────
  const captureRect = (
    <rect
      x={-view.tx / k}
      y={-view.ty / k}
      width={VIEW / k}
      height={VIEW / k}
      fill="transparent"
      style={{ cursor: 'crosshair' }}
      data-testid="zone-gesture-capture"
      onPointerDown={(e) => {
        const w = toWorld(e)
        if (!w) return
        if (mode === 'drawCircle') {
          // click sets the center, dragging grows the radius (finalized on release)
          grab(e, { kind: 'circle-new', center: w })
          patchGeometry({ kind: 'circle', center: w, radius: 0 })
          return
        }
        // drawPolygon: click appends a vertex (the first-vertex close grip renders ON TOP of this
        // rect, so a close-click never reaches here)
        e.stopPropagation()
        const g = geometryRef.current
        const vertices = g.kind === 'polygon' ? g.vertices : []
        patchGeometry({ kind: 'polygon', vertices: [...vertices, w] })
      }}
      onPointerMove={onGripMove}
      onPointerUp={onGripUp}
    />
  )

  const gripStroke = {
    stroke: 'var(--color-app)',
    strokeWidth: 1.5,
    vectorEffect: 'non-scaling-stroke' as const,
  }

  // ── circle grips (editVertices; the in-progress drawCircle disc is DraftPreviewOverlay's render) ──
  const circleGrips =
    geometry.kind === 'circle' && mode === 'editVertices'
      ? (() => {
          const c = worldToViewBox(geometry.center)
          const rEdge = worldToViewBox({
            x: geometry.center.x + geometry.radius,
            y: geometry.center.y,
          })
          return (
            <g data-testid="zone-circle-grips">
              {/* center grip — drag moves the whole circle */}
              <circle
                cx={c.x}
                cy={c.y}
                r={7 / k}
                fill="var(--color-accent)"
                {...gripStroke}
                style={{ cursor: 'move' }}
                onPointerDown={(e) => grab(e, { kind: 'circle-center' })}
                onPointerMove={onGripMove}
                onPointerUp={onGripUp}
              />
              {/* radius grip on the rim — drag resizes */}
              <circle
                cx={rEdge.x}
                cy={rEdge.y}
                r={6 / k}
                fill="var(--color-warning)"
                {...gripStroke}
                style={{ cursor: 'ew-resize' }}
                onPointerDown={(e) => grab(e, { kind: 'circle-radius' })}
                onPointerMove={onGripMove}
                onPointerUp={onGripUp}
              />
            </g>
          )
        })()
      : null

  // ── polygon grips + in-progress outline ───────────────────────────────────────────────────────────
  let polygonLayer: React.ReactNode = null
  if (geometry.kind === 'polygon') {
    const pts = geometry.vertices.map((v) => worldToViewBox(v))
    const canClose = mode === 'drawPolygon' && pts.length >= 3
    const canDelete = mode === 'editVertices' && pts.length > 3

    polygonLayer = (
      <g data-testid="zone-polygon-grips">
        {/* in-progress straight outline while drawing (<3 vertices renders nothing in the preview
            overlay, so the author still sees every placed edge honestly, un-smoothed) */}
        {mode === 'drawPolygon' && pts.length >= 2 && (
          <polyline
            points={pts.map((p) => `${p.x},${p.y}`).join(' ')}
            fill="none"
            stroke="var(--color-accent)"
            strokeWidth={1.5}
            strokeDasharray="4 3"
            vectorEffect="non-scaling-stroke"
            pointerEvents="none"
          />
        )}

        {/* edge-midpoint insert grips (edit mode): click inserts a vertex and starts dragging it */}
        {mode === 'editVertices' &&
          pts.length >= 2 &&
          pts.map((p, i) => {
            const q = pts[(i + 1) % pts.length]
            const mid = { x: (p.x + q.x) / 2, y: (p.y + q.y) / 2 }
            return (
              <circle
                key={`mid-${i}`}
                cx={mid.x}
                cy={mid.y}
                r={4.5 / k}
                fill="var(--color-surface)"
                stroke="var(--color-accent)"
                strokeWidth={1.5}
                vectorEffect="non-scaling-stroke"
                opacity={0.8}
                style={{ cursor: 'copy' }}
                onPointerDown={(e) => {
                  const g = geometryRef.current
                  if (g.kind !== 'polygon') return
                  const a = g.vertices[i]
                  const b = g.vertices[(i + 1) % g.vertices.length]
                  const inserted = { x: snap((a.x + b.x) / 2), y: snap((a.y + b.y) / 2) }
                  patchGeometry({
                    kind: 'polygon',
                    vertices: [...g.vertices.slice(0, i + 1), inserted, ...g.vertices.slice(i + 1)],
                  })
                  grab(e, { kind: 'vertex', index: i + 1 })
                }}
                onPointerMove={onGripMove}
                onPointerUp={onGripUp}
              />
            )
          })}

        {/* vertex grips: draggable in edit mode; in draw mode only the FIRST vertex is interactive
            (the close target) and the rest are passive dots */}
        {pts.map((p, i) => {
          const isCloseTarget = canClose && i === 0
          const interactive = mode === 'editVertices' || isCloseTarget
          return (
            <circle
              key={`v-${i}`}
              cx={p.x}
              cy={p.y}
              r={(isCloseTarget ? 9 : 6) / k}
              fill={isCloseTarget ? 'var(--color-success)' : 'var(--color-accent)'}
              {...gripStroke}
              pointerEvents={interactive ? 'all' : 'none'}
              style={interactive ? { cursor: isCloseTarget ? 'pointer' : 'move' } : undefined}
              onPointerDown={(e) => {
                if (isCloseTarget) {
                  // clicking the first vertex closes the ring — no vertex appended
                  e.stopPropagation()
                  onModeChange('editVertices')
                  return
                }
                if (mode === 'editVertices') grab(e, { kind: 'vertex', index: i })
              }}
              onPointerMove={onGripMove}
              onPointerUp={onGripUp}
              onDoubleClick={(e) => {
                // double-click deletes a vertex — guarded: a ring keeps at least 3
                if (!canDelete) return
                e.stopPropagation()
                const g = geometryRef.current
                if (g.kind !== 'polygon' || g.vertices.length <= 3) return
                patchGeometry({ kind: 'polygon', vertices: g.vertices.filter((_, j) => j !== i) })
              }}
            />
          )
        })}
      </g>
    )
  }

  if (mode === 'idle') return null

  return (
    <g data-testid="zone-geometry-handles">
      {(mode === 'drawCircle' || mode === 'drawPolygon') && captureRect}
      {circleGrips}
      {polygonLayer}
    </g>
  )
}
