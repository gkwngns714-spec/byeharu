// WORLD EDITOR — Foundation V1 (READ-ONLY). The typed contracts the ONE World Editor shell speaks to
// every content-layer ADAPTER. Grounded in docs/ZONE_TEMPLATES_ARCH.md §WE.0–§WE.2: the shell owns
// everything domain-agnostic (the real map, the ONE coordinate projection, camera, selection, layer
// visibility, the inspector shell); each adapter is the typed bridge that teaches the shell how to
// READ, RESOLVE (map representation), and INSPECT one domain's REAL rows — it is NOT a second editor.
//
// V1 SCOPE (hard): an adapter implements ONLY read/resolve/inspect. The authoring operations
// (create / edit / publish / enable / disable / archive) are DELIBERATELY ABSENT from the contract —
// per §WE.2 an unsupported operation must be EXPLICIT and DISABLED, never simulated. They are listed
// in DEFERRED_OPERATIONS so the shell can render them disabled-with-a-reason, and they are NOT methods
// on the adapter (there is nothing to accidentally call). No mutation, no write RPC, no flag write.
//
// Pure module: no React, no DOM, no fetch, no supabase — so every adapter's read/resolve/inspect is a
// pure function unit-tested directly (the markerStyle.ts / galaxyCamera.ts idiom).
import type { WorldCoord } from '../map/openSpaceTransform'

/** One canonical world point (x,y ∈ [-10000,10000]); the projection authority is openSpaceTransform. */
export type WorldPoint = WorldCoord

/** The four V1 content layers (§WE.1). A layer differs from another ONLY in its typed adapter. */
export type LayerId = 'locations' | 'mining' | 'exploration' | 'zones'

/** How a content item is drawn on the real map (§WE.5 geometry-form matrix): a point → an anchor
 *  coordinate; a polygon → a materialized boundary ring; a circle → a world-coord center + a
 *  world-unit radius (V3A — the seed geometry a circular zone is authored from, BEFORE it is
 *  materialized into a vertex ring). Coordinates are CANONICAL WORLD coords — the shell projects them
 *  to viewBox through the ONE shared transform (worldEditorGeometry.resolveToViewBox), never a second
 *  projection; a world-unit LENGTH (the circle radius) converts through WORLD_TO_VIEWBOX_SCALE, the
 *  one length authority. */
export type MapRepresentation =
  | { readonly kind: 'point'; readonly world: WorldPoint }
  | { readonly kind: 'polygon'; readonly ring: readonly WorldPoint[] }
  | { readonly kind: 'circle'; readonly center: WorldPoint; readonly radius: number }

/** The point-glyph a layer draws for a point item (the adapter chooses; the shell just renders it).
 *  Mirrors markerStyle's shape vocabulary + a hex for resource fields. Ignored for polygon items. */
export type PointGlyph = 'circle' | 'diamond' | 'triangle' | 'hex'

/** One selectable content item, as the adapter resolves it for the shell. Carries its map
 *  representation (world coords) and the visual tokens the adapter picks — the adapter "teaches the
 *  shell how to draw" (§WE.0) without the shell knowing anything domain-specific. */
export interface LayerItem {
  readonly layer: LayerId
  readonly id: string
  readonly label: string
  readonly representation: MapRepresentation
  /** A design-system token reference (var(--color-*)) — NEVER a raw color literal (markerStyle law). */
  readonly tone: string
  /** Point glyph; unused for polygon representations. */
  readonly glyph: PointGlyph
}

/** One typed field in the read-only inspector (§WE.2 shared inspector shell). Value is pre-formatted
 *  text — the inspector renders label/value pairs and nothing editable. */
export interface InspectorField {
  readonly label: string
  readonly value: string
}

/** The READ-ONLY adapter contract every layer implements in V1. `TSource` is the unified read-only
 *  WorldEditorData the shell fetches once — so the registry is homogeneous and every adapter reads a
 *  slice of the same snapshot. NOTE the ABSENCE of any create/edit/publish/enable/disable/archive
 *  method: that absence IS the V1 read-only guarantee (§WE.2 — deferred ops are explicit, not stubs). */
export interface ReadOnlyLayerAdapter<TSource> {
  readonly id: LayerId
  readonly title: string
  /** read visible content → typed, resolvable, inspectable items (§WE.2 "read visible content"). */
  readItems(source: TSource): LayerItem[]
  /** select & inspect → typed fields for one item, or null when the id is not in this layer. */
  inspect(source: TSource, itemId: string): InspectorField[] | null
}

/** The authoring operations DEFERRED past V1 (§WE.2, §WE.13 roadmap). They are NOT on the adapter
 *  contract; the shell renders them as disabled controls with DEFERRED_OPERATION_REASON so the boundary
 *  is explicit and honest — never a stub that pretends to work. */
export type DeferredOperation = 'create' | 'edit' | 'publish' | 'enable' | 'disable' | 'archive'

export const DEFERRED_OPERATIONS: readonly DeferredOperation[] = [
  'create',
  'edit',
  'publish',
  'enable',
  'disable',
  'archive',
]

export const DEFERRED_OPERATION_REASON =
  'Authoring is deferred to a later World Editor slice. Foundation V1 is strictly read-only.'
