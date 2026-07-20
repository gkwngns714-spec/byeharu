// WORLD EDITOR — V3A PR-2 zone-draft PURE MODEL, the ZONE BINDING of the generic draft core
// (draftModel.ts), shaped exactly like the mining binding (miningDraftModel.ts): the lifecycle logic
// lives ONCE in the generic core, reached through the ONE ZONE_DRAFT_DESCRIPTOR; the thin wrappers
// below give the domain the same convenient module surface. No React, no DOM, no network IO, no
// storage IO, no client-server call of any kind; every function is DETERMINISTIC (ids and timestamps
// are passed IN by the store layer, never generated here).
//
// HARD BOUNDARIES (the mining-domain laws, unchanged):
//   • Drafts NEVER write anywhere — no live-table mutation, no publish, no grant, and NO reuse of the
//     locked legacy zone-write RPCs. This module cannot even express a write (guarded by
//     tests/zoneDraftGuards.spec.ts — which also proves no zone-RPC-client/publish-transport import).
//   • Draft geometry is DRAFT-ONLY. Bounds problems are FLAGGED (validateDraftBounds), NEVER clamped
//     and NEVER thrown — the openSpaceTransform no-hidden-clamping law.
//   • Map representation matches zoneLayerAdapter.readItems' language (polygon ring; --color-warning,
//     the hand-'drawn' zone tone — a draft is by definition not a seeded 'circle' row) and maps the
//     geometry union 1:1 onto MapRepresentation (circle→circle, polygon→polygon).
import { WORLD_MAX, WORLD_MIN, isWithinOpenSpaceBounds } from '../map/openSpaceTransform'
import type { LayerItem } from './worldEditorTypes'
import type { DomainDraftDescriptor } from './draftTypes'
import type {
  LiveDangerZone,
  ZoneDraft,
  ZoneDraftPayload,
  ZoneDraftSourceStatus,
  ZoneGeometry,
} from './zoneDraftTypes'
import { validateZoneDraft, type ZoneValidationReport } from './zoneValidation'
import {
  beginCreate as coreBeginCreate,
  computeSourceFingerprint as coreComputeSourceFingerprint,
  draftSourceStatus as coreDraftSourceStatus,
  draftToLayerItem as coreDraftToLayerItem,
  forkEdit as coreForkEdit,
  isDirty as coreIsDirty,
  parseStoredDraft as coreParseStoredDraft,
  patch as corePatch,
} from './draftModel'

/** The payload keys in ONE canonical order — the single authority the fingerprint, the snapshot
 *  extractor, and the stored-draft validator all share (so they can never drift apart). */
export const ZONE_DRAFT_PAYLOAD_KEYS = [
  'name',
  'zone_kind',
  'attach_location_id',
  'geometry',
] as const satisfies readonly (keyof ZoneDraftPayload)[]

/** The blank payload a create-draft starts from (and the isDirty baseline for creates): an EMPTY open
 *  polygon — the author draws vertices (or switches to the circle tool) from nothing. Vertex-count /
 *  degeneracy problems are validation FLAGS, never a reason to invent a default shape. */
export const EMPTY_ZONE_CREATE_PAYLOAD: ZoneDraftPayload = {
  name: '',
  zone_kind: 'pirate',
  attach_location_id: null,
  geometry: { kind: 'polygon', vertices: [] },
}

/** Structural check for ONE world point (presence + primitive kinds; values themselves are advisory-
 *  validated by zoneValidation, never trusted structurally beyond number-ness). */
function isPointShaped(p: unknown): boolean {
  if (typeof p !== 'object' || p === null) return false
  const o = p as Record<string, unknown>
  return typeof o.x === 'number' && typeof o.y === 'number'
}

/** Structural check for the nested ZoneGeometry union (rehydration path): a malformed stored
 *  geometry drops the whole blob (parseStoredDraft's fail-closed contract), never throws. */
function isGeometryShaped(g: unknown): boolean {
  if (typeof g !== 'object' || g === null) return false
  const o = g as Record<string, unknown>
  if (o.kind === 'circle') return isPointShaped(o.center) && typeof o.radius === 'number'
  if (o.kind === 'polygon') return Array.isArray(o.vertices) && o.vertices.every(isPointShaped)
  return false
}

/** Structural payload check for rehydration (presence + primitive kinds; `zone_kind` is trusted as a
 *  string per the descriptor law — a stale value renders honestly and fails future server checks). */
function isPayloadShaped(p: unknown): boolean {
  if (typeof p !== 'object' || p === null) return false
  const o = p as Record<string, unknown>
  return (
    typeof o.name === 'string' &&
    typeof o.zone_kind === 'string' &&
    (o.attach_location_id === null || typeof o.attach_location_id === 'string') &&
    isGeometryShaped(o.geometry)
  )
}

/** Drop the closing duplicate from a live CLOSED ring (first point repeated last) — a draft polygon
 *  is an OPEN ring. A null/short ring projects to no vertices (the honest empty polygon). */
function openRingFromLive(ring: LiveDangerZone['ring']): readonly { x: number; y: number }[] {
  if (!ring || ring.length === 0) return []
  const first = ring[0]
  const last = ring[ring.length - 1]
  const closed = ring.length > 1 && first[0] === last[0] && first[1] === last[1]
  const open = closed ? ring.slice(0, -1) : ring
  return open.map(([x, y]) => ({ x, y }))
}

/** True iff a geometry sits fully inside the fixed open-space domain: every polygon vertex passes the
 *  ONE shared predicate; a circle needs an in-bounds center, a finite positive radius, AND its whole
 *  extent (center ± radius on both axes) inside ±10000. FLAG only — never clamped, never thrown. */
function geometryWithinBounds(geometry: ZoneGeometry): boolean {
  if (geometry.kind === 'polygon') return geometry.vertices.every((v) => isWithinOpenSpaceBounds(v))
  const { center, radius } = geometry
  return (
    isWithinOpenSpaceBounds(center) &&
    Number.isFinite(radius) &&
    radius > 0 &&
    center.x - radius >= WORLD_MIN &&
    center.x + radius <= WORLD_MAX &&
    center.y - radius >= WORLD_MIN &&
    center.y + radius <= WORLD_MAX
  )
}

/** The ONE zone binding of the generic draft core (V3A): payload projection, identity (danger_zones
 *  has a REAL uuid — the first draft domain whose liveId is not a natural-key name), storage keying
 *  (its own versioned prefix), LayerItem resolution (geometry→representation 1:1, --color-warning),
 *  bounds (the ONE shared predicate + circle extent), and the domain's advisory validator. */
export const ZONE_DRAFT_DESCRIPTOR: DomainDraftDescriptor<
  ZoneDraftPayload,
  LiveDangerZone,
  ZoneValidationReport
> = {
  domainId: 'zones',
  payloadKeys: ZONE_DRAFT_PAYLOAD_KEYS,
  emptyCreatePayload: EMPTY_ZONE_CREATE_PAYLOAD,
  storageKeyPrefix: 'byeharu.worldEditor.zoneDraft.v1:',
  // A live zone ALWAYS materializes to an editable polygon: get_danger_zones returns the closed
  // vertex ring for every row — even source='circle' rows read back as their materialized ring
  // (circle authoring is CREATE-only seed geometry and never round-trips). zone_kind is the one
  // 'pirate' kind of this runtime; location_id maps onto attach_location_id verbatim.
  projectFromLive: (z) => ({
    name: z.name,
    zone_kind: 'pirate',
    attach_location_id: z.location_id,
    geometry: { kind: 'polygon', vertices: openRingFromLive(z.ring) },
  }),
  // danger_zones exposes a REAL uuid through the read (unlike mining/exploration's name keys).
  liveId: (z) => z.id,
  isPayloadShaped,
  toLayerItem: (draftId, payload) => ({
    layer: 'zones',
    id: draftId,
    label: payload.name || 'New zone',
    representation:
      payload.geometry.kind === 'circle'
        ? { kind: 'circle', center: payload.geometry.center, radius: payload.geometry.radius }
        : { kind: 'polygon', ring: payload.geometry.vertices },
    // The hand-authored zone tone (zoneLayerAdapter draws source='drawn' rows --color-warning; a
    // draft is authored, not seeded).
    tone: 'var(--color-warning)',
    glyph: 'circle', // unused for polygon/circle representations
  }),
  withinBounds: (payload) => geometryWithinBounds(payload.geometry),
  // The generic store env carries the zone rows only; the shell-side panel re-runs the SAME
  // validator with the real locations slice for the affected-locations advisory (see zoneValidation).
  validate: (draft, env) => validateZoneDraft(draft, { ...env, locations: [] }),
}

/** Stable fingerprint over the ZoneDraftPayload keys (canonical key order + JSON-encoded values →
 *  FNV-1a 32-bit hex, via the ONE generic implementation). Used as the edit fork's `sourceRevision`
 *  and recomputed against CURRENT live rows to detect staleness. */
export function computeSourceFingerprint(source: ZoneDraftPayload): string {
  return coreComputeSourceFingerprint(ZONE_DRAFT_DESCRIPTOR, source)
}

/** Start a brand-new zone draft (mode 'create') at the blank payload. Deterministic — the caller
 *  supplies the id and clock. */
export function beginCreate(draftId: string, now: number): ZoneDraft {
  return coreBeginCreate(ZONE_DRAFT_DESCRIPTOR, draftId, now)
}

/** Fork an edit draft off a LIVE danger zone: payload starts as the projection of the row (the
 *  materialized OPEN polygon ring), and the mode pins sourceId (the uuid) + the row's fingerprint +
 *  a full snapshot so dirtiness/staleness stay decidable. */
export function forkEdit(zone: LiveDangerZone, draftId: string, now: number): ZoneDraft {
  return coreForkEdit(ZONE_DRAFT_DESCRIPTOR, zone, draftId, now)
}

/** Apply a partial payload change immutably; bumps updatedAt to the supplied clock. Geometry
 *  gestures write EXCLUSIVELY through this path (store.patchDraft → patch) — never a live table. */
export function patch(draft: ZoneDraft, partial: Partial<ZoneDraftPayload>, now: number): ZoneDraft {
  return corePatch(draft, partial, now)
}

/** True when the draft's payload differs from its baseline: the forked snapshot for edits, the blank
 *  create payload for creates. Fingerprint equality — geometry included. */
export function isDirty(draft: ZoneDraft): boolean {
  return coreIsDirty(ZONE_DRAFT_DESCRIPTOR, draft)
}

/** Draft ↔ CURRENT live-row relationship (recomputed, never stored): a create is always 'current';
 *  an edit whose live row vanished is 'source_missing'; an edit whose live row's ring/name/attachment
 *  moved since the fork is 'source_changed'. */
export function draftSourceStatus(
  draft: ZoneDraft,
  liveZone: LiveDangerZone | undefined,
): ZoneDraftSourceStatus {
  return coreDraftSourceStatus(ZONE_DRAFT_DESCRIPTOR, draft, liveZone)
}

/** Bounds check for the draft's geometry via the ONE domain predicate (+ the circle-extent rule).
 *  Returns a FLAG — out-of-bounds geometry is reported, NEVER clamped and NEVER thrown. */
export function validateDraftBounds(payload: ZoneDraftPayload): boolean {
  return ZONE_DRAFT_DESCRIPTOR.withinBounds(payload)
}

/** Resolve a draft to the SAME LayerItem shape zoneLayerAdapter.readItems produces — polygon ring /
 *  circle representation, --color-warning tone — so the preview speaks the map's visual language
 *  with zero adapter-contract change. */
export function draftToLayerItem(draft: ZoneDraft): LayerItem {
  return coreDraftToLayerItem(ZONE_DRAFT_DESCRIPTOR, draft)
}

/** Parse + structurally validate ONE stored draft JSON string (localStorage rehydration path).
 *  Returns null on anything malformed — including a malformed nested geometry — a bad stored blob is
 *  dropped, never trusted, never thrown into the render path. Staleness is NOT decided here (the
 *  store re-validates against CURRENT live rows via draftSourceStatus). */
export function parseStoredDraft(json: string): ZoneDraft | null {
  return coreParseStoredDraft(ZONE_DRAFT_DESCRIPTOR, json)
}
