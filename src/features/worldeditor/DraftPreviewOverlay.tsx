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
import { resolveToViewBox } from './worldEditorGeometry'
import type { Draft } from './draftTypes'
import type { LayerItem, PointGlyph } from './worldEditorTypes'
import { Glyph } from './WorldEditor'

/** The active draft's map overlay (inside the camera <g>; `k` is the camera zoom for the constant
 *  on-screen-size counter-scale, the `r / k` idiom). The caller renders nothing when no draft is
 *  active; this component renders nothing for non-point representations. */
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
  if (resolved.kind !== 'point') return null
  const { x, y } = resolved.point
  const r = 8 / k
  const outOfBounds = !withinBounds(activeDraft.payload)

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
