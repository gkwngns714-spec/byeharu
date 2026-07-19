// WORLD EDITOR — V1B-1 DRAFT PREVIEW overlay, now the LOCATION BINDING of the V2A GENERIC
// DraftPreviewOverlay (domain-blind rendering: ghost + connector + dashed authoring ring + label,
// same testid, zero behavior change). The active location draft's glyph/tone/ghost all flow through
// the ONE location descriptor's toLayerItem (shared markerStyle policy) and the ONE shared projection
// (worldEditorGeometry.resolveToViewBox) — no second visual language, no second coordinate system.
// Presentation only, drawn from the draft store; it never touches WorldEditorData and is never
// selectable/inspectable as live content.
import { LOCATION_DRAFT_DESCRIPTOR } from './locationDraftModel'
import { useLocationDrafts } from './useLocationDrafts'
import { DraftPreviewOverlay } from './DraftPreviewOverlay'

/** The active draft's map overlay (inside the camera <g>; `k` is the camera zoom for the constant
 *  on-screen-size counter-scale, the `r / k` idiom). Renders nothing when no draft is active. */
export function DraftPreview({ k }: { k: number }) {
  const { activeDraft } = useLocationDrafts()
  if (!activeDraft) return null

  return (
    <DraftPreviewOverlay
      activeDraft={activeDraft}
      toLayerItem={LOCATION_DRAFT_DESCRIPTOR.toLayerItem}
      withinBounds={LOCATION_DRAFT_DESCRIPTOR.withinBounds}
      k={k}
    />
  )
}
