// WORLD EDITOR — V1B-1 DRAFT PREVIEW overlay. Renders the ACTIVE location draft as an authoring-styled
// glyph in an overlay <g> ABOVE the read-only visibleItems — presentation only, drawn from the draft
// store; it never touches WorldEditorData and is never selectable/inspectable as live content.
// Projection is the ONE shared resolver (worldEditorGeometry.resolveToViewBox → worldToViewBox);
// glyph/tone come through draftToLayerItem (shared markerStyle policy) — no second visual language.
//
// Edit mode additionally shows a DIMMED GHOST at the forked sourceSnapshot's coordinates plus a dashed
// connector line when the draft point has moved — the author always sees "from where → to where".
import { markerStyle } from '../map/markerStyle'
import { resolveToViewBox } from './worldEditorGeometry'
import { draftToLayerItem, validateDraftBounds } from './locationDraftModel'
import { useLocationDrafts } from './useLocationDrafts'
import type { PointGlyph } from './worldEditorTypes'
import { Glyph } from './WorldEditor'

/** The active draft's map overlay (inside the camera <g>; `k` is the camera zoom for the constant
 *  on-screen-size counter-scale, the `r / k` idiom). Renders nothing when no draft is active. */
export function DraftPreview({ k }: { k: number }) {
  const { activeDraft } = useLocationDrafts()
  if (!activeDraft) return null

  const item = draftToLayerItem(activeDraft)
  const resolved = resolveToViewBox(item.representation)
  if (resolved.kind !== 'point') return null
  const { x, y } = resolved.point
  const r = 8 / k
  const outOfBounds = !validateDraftBounds(activeDraft.payload)

  // Edit mode: the forked source position, for the dimmed ghost + moved-connector.
  let ghost: { x: number; y: number; glyph: PointGlyph; tone: string } | null = null
  if (activeDraft.mode.kind === 'edit') {
    const snap = activeDraft.mode.sourceSnapshot
    const g = resolveToViewBox({ kind: 'point', world: { x: snap.x, y: snap.y } })
    if (g.kind === 'point') {
      const s = markerStyle(snap)
      ghost = { x: g.point.x, y: g.point.y, glyph: s.shape as PointGlyph, tone: s.color }
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
