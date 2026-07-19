// WORLD EDITOR — V1B-1 location-draft PURE MODEL, now the LOCATION BINDING of the V2A GENERIC draft
// core (draftModel.ts). Every function below keeps its EXACT V1B name, signature, and behavior
// (proven by the unchanged tests/locationDraftModel.spec.ts) — the lifecycle logic itself lives ONCE
// in the generic core, reached through the ONE LOCATION_DRAFT_DESCRIPTOR. No React, no DOM, no
// network IO, no storage IO, no client-server call of any kind; every function is DETERMINISTIC (ids
// and timestamps are passed IN by the store layer, never generated here).
//
// HARD BOUNDARIES (unchanged):
//   • Drafts NEVER write anywhere — no live-table mutation, no publish, no grant. This module cannot
//     even express a write (guarded by tests/locationDraftGuards.spec.ts).
//   • Draft x/y are DRAFT-ONLY values. Bounds problems are FLAGGED (validateDraftBounds), NEVER
//     clamped and NEVER thrown — the openSpaceTransform no-hidden-clamping law.
//   • Map representation goes through the SAME shape locationLayerAdapter.readItems produces, with
//     glyph/tone chosen by the SHARED markerStyle policy — one visual language, no fork.
import { isWithinOpenSpaceBounds } from '../map/openSpaceTransform'
import { markerStyle } from '../map/markerStyle'
import type { MapLocation } from '../map/mapTypes'
import type { LayerItem, PointGlyph } from './worldEditorTypes'
import type { DomainDraftDescriptor } from './draftTypes'
import type {
  DraftSourceStatus,
  LocationDraft,
  LocationDraftPayload,
} from './locationDraftTypes'
import { validateLocationDraft, type ValidationReport } from './locationValidation'
import {
  beginCreate as coreBeginCreate,
  computeSourceFingerprint as coreComputeSourceFingerprint,
  draftSourceStatus as coreDraftSourceStatus,
  draftToLayerItem as coreDraftToLayerItem,
  forkEdit as coreForkEdit,
  isDirty as coreIsDirty,
  parseStoredDraft as coreParseStoredDraft,
  patch as corePatch,
  projectPayload,
} from './draftModel'

/** The payload keys in ONE canonical order — the single authority the fingerprint, the snapshot
 *  extractor, and the stored-draft validator all share (so they can never drift apart). */
export const LOCATION_DRAFT_PAYLOAD_KEYS = [
  'name',
  'location_type',
  'activity_type',
  'x',
  'y',
  'reward_tier',
  'base_difficulty',
  'min_power_required',
  'is_public',
  'territory_radius',
  'status',
] as const satisfies readonly (keyof LocationDraftPayload)[]

/** Project a live MapLocation (or anything payload-shaped) onto exactly the draft payload keys. */
export function draftPayloadFrom(source: LocationDraftPayload): LocationDraftPayload {
  return projectPayload(LOCATION_DRAFT_PAYLOAD_KEYS, source)
}

/** The blank payload a create-draft starts from (and the isDirty baseline for creates). World origin
 *  (0,0) — always in bounds; the author drags/types real coordinates before any future publish. */
export const EMPTY_CREATE_PAYLOAD: LocationDraftPayload = {
  name: '',
  location_type: 'safe_zone',
  activity_type: 'none',
  x: 0,
  y: 0,
  reward_tier: 0,
  base_difficulty: 0,
  min_power_required: 0,
  is_public: true,
  territory_radius: null,
  status: 'active',
}

/** Structural payload check for rehydration (presence + primitive kinds; domain unions are trusted
 *  as strings — a stale enum value renders honestly and simply fails any FUTURE server validation). */
function isPayloadShaped(p: unknown): boolean {
  if (typeof p !== 'object' || p === null) return false
  const o = p as Record<string, unknown>
  return (
    typeof o.name === 'string' &&
    typeof o.location_type === 'string' &&
    typeof o.activity_type === 'string' &&
    typeof o.x === 'number' &&
    typeof o.y === 'number' &&
    typeof o.reward_tier === 'number' &&
    typeof o.base_difficulty === 'number' &&
    typeof o.min_power_required === 'number' &&
    typeof o.is_public === 'boolean' &&
    (o.territory_radius === null || typeof o.territory_radius === 'number') &&
    typeof o.status === 'string'
  )
}

/** The ONE location binding of the generic draft core (V2A): payload projection, identity, storage
 *  keying, LayerItem resolution (SHARED markerStyle policy), bounds (ONE shared predicate), and the
 *  UNCHANGED advisory validator (validateLocationDraft — locationValidation.ts stays byte-identical;
 *  structural typing flows its ValidationReport into the generic store). */
export const LOCATION_DRAFT_DESCRIPTOR: DomainDraftDescriptor<
  LocationDraftPayload,
  MapLocation,
  ValidationReport
> = {
  domainId: 'location',
  payloadKeys: LOCATION_DRAFT_PAYLOAD_KEYS,
  emptyCreatePayload: EMPTY_CREATE_PAYLOAD,
  storageKeyPrefix: 'byeharu.worldEditor.locationDraft.v1:',
  projectFromLive: (live) => draftPayloadFrom(live),
  liveId: (live) => live.id,
  isPayloadShaped,
  toLayerItem: (draftId, payload) => {
    const s = markerStyle(payload)
    return {
      layer: 'locations',
      id: draftId,
      label: payload.name || 'New location',
      representation: { kind: 'point', world: { x: payload.x, y: payload.y } },
      tone: s.color,
      glyph: s.shape as PointGlyph,
    }
  },
  withinBounds: (payload) => isWithinOpenSpaceBounds({ x: payload.x, y: payload.y }),
  validate: (draft, env) =>
    validateLocationDraft(draft.payload, {
      liveLocations: env.live,
      sourceStatus: env.sourceStatus,
      draftMode: draft.mode,
      otherDrafts: env.otherDrafts,
    }),
}

/** Stable fingerprint over the LocationDraftPayload keys (canonical key order + JSON-encoded values →
 *  FNV-1a 32-bit hex). Same field values ⇒ same fingerprint, on any object carrying the payload keys
 *  (extra properties like a live row's `id` are ignored). Used as the edit fork's `sourceRevision`
 *  and recomputed against CURRENT live rows to detect staleness. */
export function computeSourceFingerprint(source: LocationDraftPayload): string {
  return coreComputeSourceFingerprint(LOCATION_DRAFT_DESCRIPTOR, source)
}

/** Start a brand-new location draft (mode 'create') at the blank payload. Deterministic — the caller
 *  supplies the id and clock. */
export function beginCreate(draftId: string, now: number): LocationDraft {
  return coreBeginCreate(LOCATION_DRAFT_DESCRIPTOR, draftId, now)
}

/** Fork an edit draft off a LIVE location row: payload starts as a copy of the row, and the mode
 *  pins sourceId + the row's fingerprint + a full snapshot so dirtiness/staleness stay decidable. */
export function forkEdit(loc: MapLocation, draftId: string, now: number): LocationDraft {
  return coreForkEdit(LOCATION_DRAFT_DESCRIPTOR, loc, draftId, now)
}

/** Apply a partial payload change immutably; bumps updatedAt to the supplied clock. */
export function patch(
  draft: LocationDraft,
  partial: Partial<LocationDraftPayload>,
  now: number,
): LocationDraft {
  return corePatch(draft, partial, now)
}

/** True when the draft's payload differs from its baseline: the forked snapshot for edits, the blank
 *  create payload for creates. Fingerprint equality — so patching a field back to its original value
 *  cleanly returns to not-dirty. */
export function isDirty(draft: LocationDraft): boolean {
  return coreIsDirty(LOCATION_DRAFT_DESCRIPTOR, draft)
}

/** Draft ↔ CURRENT live-row relationship (recomputed, never stored): a create is always 'current';
 *  an edit whose live row vanished is 'source_missing'; an edit whose live row's fingerprint moved
 *  since the fork is 'source_changed'. */
export function draftSourceStatus(
  draft: LocationDraft,
  liveLoc: MapLocation | undefined,
): DraftSourceStatus {
  return coreDraftSourceStatus(LOCATION_DRAFT_DESCRIPTOR, draft, liveLoc)
}

/** Bounds check for the draft's coordinates via the ONE domain predicate
 *  (openSpaceTransform.isWithinOpenSpaceBounds). Returns a FLAG — an out-of-bounds or non-finite
 *  coordinate is reported, NEVER clamped and NEVER thrown (no-hidden-clamping law). */
export function validateDraftBounds(payload: LocationDraftPayload): boolean {
  return LOCATION_DRAFT_DESCRIPTOR.withinBounds(payload)
}

/** Resolve a draft to the SAME LayerItem shape locationLayerAdapter.readItems produces — point
 *  representation at the draft's canonical world x/y, glyph/tone via the SHARED markerStyle policy —
 *  so the preview speaks the map's visual language with zero adapter-contract change. */
export function draftToLayerItem(draft: LocationDraft): LayerItem {
  return coreDraftToLayerItem(LOCATION_DRAFT_DESCRIPTOR, draft)
}

/** Parse + structurally validate ONE stored draft JSON string (localStorage rehydration path).
 *  Returns null on anything malformed — a bad stored blob is dropped, never trusted, never thrown
 *  into the render path. Staleness is NOT decided here: the store re-validates every rehydrated
 *  edit draft against CURRENT live rows via draftSourceStatus (mandatory re-validation). */
export function parseStoredDraft(json: string): LocationDraft | null {
  return coreParseStoredDraft(LOCATION_DRAFT_DESCRIPTOR, json)
}
