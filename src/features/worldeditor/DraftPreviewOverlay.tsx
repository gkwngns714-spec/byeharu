// WORLD EDITOR — V2A PR-1 GENERIC (domain-blind) DRAFT PREVIEW OVERLAY. Extracted
// BEHAVIOR-PRESERVING from DraftPreview.tsx: renders ONE active draft as an authoring-styled glyph in
// an overlay <g> ABOVE the read-only visibleItems — presentation only; it never touches
// WorldEditorData and is never selectable/inspectable as live content. Projection is the ONE shared
// resolver (worldEditorGeometry.resolveToViewBox → worldToViewBox); glyph/tone come through the
// domain's toLayerItem binding (shared markerStyle policy for locations) — no second visual language.
//
// Edit mode additionally shows a DIMMED GHOST at the forked sourceSnapshot's position plus a dashed
// connector line when the draft point has moved — the author always sees "from where → to where".
// The ghost's position/glyph/tone flow through the SAME toLayerItem binding over the sourceSnapshot.
//
// V3A PR-1 extends the SAME overlay to GEOMETRY drafts: a polygon draft renders as a dashed authoring
// ring (through the ONE smoothing authority, smoothClosedPathD — the exact render the zone layer
// uses), a circle draft renders as a dashed authoring <circle> at the resolved center/radius. Both
// reuse the point conventions verbatim: dimmed sourceSnapshot ghost in edit mode, accent dashes that
// read danger when out-of-bounds, and the "(label) (draft)" text. Presentation ONLY — pointerEvents
// stays "none"; geometry GESTURES are a later slice, not this component.
import { resolveToViewBox, type ResolvedRepresentation } from './worldEditorGeometry'
import { smoothClosedPathD, ringCentroid } from '../map/smoothPolygon'
import type { Draft } from './draftTypes'
import type { LayerItem, PointGlyph } from './worldEditorTypes'
import { Glyph } from './WorldEditor'

/** The active draft's map overlay (inside the camera <g>; `k` is the camera zoom for the constant
 *  on-screen-size counter-scale, the `r / k` idiom). The caller renders nothing when no draft is
 *  active. Point drafts render the glyph+ghost+connector; polygon/circle drafts render the dashed
 *  authoring outline (+ dimmed source-geometry ghost in edit mode). */
export function DraftPreviewOverlay<TPayload>({
  activeDraft,
  toLayerItem,
  withinBounds,
  k,
}: {
  activeDraft: Draft<TPayload>
  toLayerItem: (draftId: string, payload: TPayload) => LayerItem
  withinBounds: (payload: TPayload) => boolean
  k: number
}) {
  const item = toLayerItem(activeDraft.draftId, activeDraft.payload)
  const resolved = resolveToViewBox(item.representation)
  const outOfBounds = !withinBounds(activeDraft.payload)

  if (resolved.kind === 'polygon' || resolved.kind === 'circle') {
    // Edit mode: the forked source's resolved geometry, for the dimmed ghost.
    let sourceResolved: ResolvedRepresentation | null = null
    let sourceTone: string | null = null
    if (activeDraft.mode.kind === 'edit') {
      const sourceItem = toLayerItem(activeDraft.draftId, activeDraft.mode.sourceSnapshot)
      sourceResolved = resolveToViewBox(sourceItem.representation)
      sourceTone = sourceItem.tone
    }
    if (resolved.kind === 'polygon') {
      return (
        <PolygonDraftPreview
          ring={resolved.ring}
          ghostRing={sourceResolved?.kind === 'polygon' ? sourceResolved.ring : null}
          ghostTone={sourceTone}
          item={item}
          outOfBounds={outOfBounds}
          k={k}
        />
      )
    }
    return (
      <CircleDraftPreview
        center={resolved.center}
        radius={resolved.radius}
        ghost={sourceResolved?.kind === 'circle' ? sourceResolved : null}
        ghostTone={sourceTone}
        item={item}
        outOfBounds={outOfBounds}
        k={k}
      />
    )
  }

  // ── POINT (the original V2A rendering, unchanged) ─────────────────────────────────────────────────
  const { x, y } = resolved.point
  const r = 8 / k

  // Edit mode: the forked source position, for the dimmed ghost + moved-connector.
  let ghost: { x: number; y: number; glyph: PointGlyph; tone: string } | null = null
  if (activeDraft.mode.kind === 'edit') {
    const sourceItem = toLayerItem(activeDraft.draftId, activeDraft.mode.sourceSnapshot)
    const g = resolveToViewBox(sourceItem.representation)
    if (g.kind === 'point') {
      ghost = { x: g.point.x, y: g.point.y, glyph: sourceItem.glyph, tone: sourceItem.tone }
    }
  }
  const moved = ghost !== null && (ghost.x !== x || ghost.y !== y)

  return (
    <g pointerEvents="none" data-testid="draft-preview">
      {/* dimmed ghost of the live source (edit mode only) */}
      {ghost && (
        <g opacity={0.35}>
          <Glyph x={ghost.x} y={ghost.y} r={r} glyph={ghost.glyph} tone={ghost.tone} />
        </g>
      )}

      {/* connector from the source position to the draft position, only when the point moved */}
      {ghost && moved && (
        <line
          x1={ghost.x}
          y1={ghost.y}
          x2={x}
          y2={y}
          stroke="var(--color-accent)"
          strokeWidth={1.5}
          strokeDasharray="5 4"
          vectorEffect="non-scaling-stroke"
          opacity={0.7}
        />
      )}

      {/* authoring-styled draft glyph: dashed accent ring (out-of-bounds reads danger) + shared Glyph */}
      <circle
        cx={x}
        cy={y}
        r={r * 1.9}
        fill="none"
        stroke={outOfBounds ? 'var(--color-danger)' : 'var(--color-accent)'}
        strokeWidth={1.5}
        strokeDasharray="4 3"
        vectorEffect="non-scaling-stroke"
      />
      <Glyph x={x} y={y} r={r} glyph={item.glyph} tone={item.tone} />
      <text
        x={x}
        y={y - r * 1.6 - 6 / k}
        fontSize={13 / k}
        textAnchor="middle"
        fill="var(--color-ink)"
        stroke="var(--color-map-halo)"
        strokeWidth={3 / k}
        paintOrder="stroke"
        style={{ userSelect: 'none' }}
      >
        {`${item.label} (draft)`}
      </text>
    </g>
  )
}

/** Shared "(label) (draft)" text — the exact point-draft label conventions (halo stroke, 13/k). */
function DraftLabel({ x, y, label, k }: { x: number; y: number; label: string; k: number }) {
  return (
    <text
      x={x}
      y={y}
      fontSize={13 / k}
      textAnchor="middle"
      fill="var(--color-ink)"
      stroke="var(--color-map-halo)"
      strokeWidth={3 / k}
      paintOrder="stroke"
      style={{ userSelect: 'none' }}
    >
      {`${label} (draft)`}
    </text>
  )
}

/** POLYGON draft: dimmed source-ring ghost (edit mode) + the dashed authoring ring through the ONE
 *  smoothing authority (smoothClosedPathD — exactly the zone layer's render). <3 vertices → nothing
 *  (smoothClosedPathD's fail-closed contract; the caller sees no half-drawn shape). */
function PolygonDraftPreview({
  ring,
  ghostRing,
  ghostTone,
  item,
  outOfBounds,
  k,
}: {
  ring: readonly { x: number; y: number }[]
  ghostRing: readonly { x: number; y: number }[] | null
  ghostTone: string | null
  item: LayerItem
  outOfBounds: boolean
  k: number
}) {
  const d = smoothClosedPathD(ring)
  if (!d) return null
  const ghostD = ghostRing ? smoothClosedPathD(ghostRing) : null
  const edge = outOfBounds ? 'var(--color-danger)' : 'var(--color-accent)'
  const centroid = ringCentroid(ring)
  return (
    <g pointerEvents="none" data-testid="draft-preview">
      {/* dimmed ghost of the live source ring (edit mode only) */}
      {ghostD && (
        <g opacity={0.35}>
          <path d={ghostD} fill={ghostTone ?? item.tone} opacity={0.15} />
          <path
            d={ghostD}
            fill="none"
            stroke={ghostTone ?? item.tone}
            strokeWidth={1.5}
            vectorEffect="non-scaling-stroke"
          />
        </g>
      )}

      {/* authoring-styled draft ring: tone fill + dashed accent edge (out-of-bounds reads danger) */}
      <path d={d} fill={item.tone} opacity={0.12} />
      <path
        d={d}
        fill="none"
        stroke={edge}
        strokeWidth={1.5}
        strokeDasharray="4 3"
        vectorEffect="non-scaling-stroke"
      />
      {centroid && <DraftLabel x={centroid.x} y={centroid.y} label={item.label} k={k} />}
    </g>
  )
}

/** CIRCLE draft: dimmed source-circle ghost (edit mode) + the dashed authoring <circle> at the
 *  resolved viewBox center/radius (radius already length-converted by the ONE resolver). */
function CircleDraftPreview({
  center,
  radius,
  ghost,
  ghostTone,
  item,
  outOfBounds,
  k,
}: {
  center: { x: number; y: number }
  radius: number
  ghost: { center: { x: number; y: number }; radius: number } | null
  ghostTone: string | null
  item: LayerItem
  outOfBounds: boolean
  k: number
}) {
  const edge = outOfBounds ? 'var(--color-danger)' : 'var(--color-accent)'
  return (
    <g pointerEvents="none" data-testid="draft-preview">
      {/* dimmed ghost of the live source circle (edit mode only) */}
      {ghost && (
        <g opacity={0.35}>
          <circle cx={ghost.center.x} cy={ghost.center.y} r={ghost.radius} fill={ghostTone ?? item.tone} opacity={0.15} />
          <circle
            cx={ghost.center.x}
            cy={ghost.center.y}
            r={ghost.radius}
            fill="none"
            stroke={ghostTone ?? item.tone}
            strokeWidth={1.5}
            vectorEffect="non-scaling-stroke"
          />
        </g>
      )}

      {/* authoring-styled draft circle: tone fill + dashed accent edge (out-of-bounds reads danger) */}
      <circle cx={center.x} cy={center.y} r={radius} fill={item.tone} opacity={0.12} />
      <circle
        cx={center.x}
        cy={center.y}
        r={radius}
        fill="none"
        stroke={edge}
        strokeWidth={1.5}
        strokeDasharray="4 3"
        vectorEffect="non-scaling-stroke"
      />
      <DraftLabel x={center.x} y={center.y - radius - 6 / k} label={item.label} k={k} />
    </g>
  )
}
