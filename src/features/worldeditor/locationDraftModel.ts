// WORLD EDITOR — V1B-1 location-draft PURE MODEL (props in → decision out). No React, no DOM, no
// network IO, no storage IO, no client-server call of any kind — the markerStyle.ts / firstOrders.ts
// pure-module idiom, unit-tested directly (tests/locationDraftModel.spec.ts). Every function is
// DETERMINISTIC: ids and timestamps are passed IN by the store layer (useLocationDrafts), never
// generated here.
//
// HARD BOUNDARIES (this slice's acceptance criteria):
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
import type {
  DraftSourceStatus,
  LocationDraft,
  LocationDraftPayload,
} from './locationDraftTypes'

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
  return {
    name: source.name,
    location_type: source.location_type,
    activity_type: source.activity_type,
    x: source.x,
    y: source.y,
    reward_tier: source.reward_tier,
    base_difficulty: source.base_difficulty,
    min_power_required: source.min_power_required,
    is_public: source.is_public,
    territory_radius: source.territory_radius,
    status: source.status,
  }
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

/** Stable fingerprint over the LocationDraftPayload keys (canonical key order + JSON-encoded values →
 *  FNV-1a 32-bit hex). Same field values ⇒ same fingerprint, on any object carrying the payload keys
 *  (extra properties like a live row's `id` are ignored). Used as the edit fork's `sourceRevision`
 *  and recomputed against CURRENT live rows to detect staleness. */
export function computeSourceFingerprint(source: LocationDraftPayload): string {
  const canonical = LOCATION_DRAFT_PAYLOAD_KEYS.map(
    (k) => `${k}=${JSON.stringify(source[k] ?? null)}`,
  ).join('|')
  let h = 0x811c9dc5
  for (let i = 0; i < canonical.length; i++) {
    h ^= canonical.charCodeAt(i)
    h = Math.imul(h, 0x01000193)
  }
  return (h >>> 0).toString(16).padStart(8, '0')
}

/** Start a brand-new location draft (mode 'create') at the blank payload. Deterministic — the caller
 *  supplies the id and clock. */
export function beginCreate(draftId: string, now: number): LocationDraft {
  return {
    draftId,
    mode: { kind: 'create' },
    payload: { ...EMPTY_CREATE_PAYLOAD },
    createdAt: now,
    updatedAt: now,
  }
}

/** Fork an edit draft off a LIVE location row: payload starts as a copy of the row, and the mode
 *  pins sourceId + the row's fingerprint + a full snapshot so dirtiness/staleness stay decidable. */
export function forkEdit(loc: MapLocation, draftId: string, now: number): LocationDraft {
  const snapshot = draftPayloadFrom(loc)
  return {
    draftId,
    mode: {
      kind: 'edit',
      sourceId: loc.id,
      sourceRevision: computeSourceFingerprint(loc),
      sourceSnapshot: snapshot,
    },
    payload: { ...snapshot },
    createdAt: now,
    updatedAt: now,
  }
}

/** Apply a partial payload change immutably; bumps updatedAt to the supplied clock. */
export function patch(
  draft: LocationDraft,
  partial: Partial<LocationDraftPayload>,
  now: number,
): LocationDraft {
  return { ...draft, payload: { ...draft.payload, ...partial }, updatedAt: now }
}

/** True when the draft's payload differs from its baseline: the forked snapshot for edits, the blank
 *  create payload for creates. Fingerprint equality — so patching a field back to its original value
 *  cleanly returns to not-dirty. */
export function isDirty(draft: LocationDraft): boolean {
  const baseline =
    draft.mode.kind === 'edit' ? draft.mode.sourceSnapshot : EMPTY_CREATE_PAYLOAD
  return computeSourceFingerprint(draft.payload) !== computeSourceFingerprint(baseline)
}

/** Draft ↔ CURRENT live-row relationship (recomputed, never stored): a create is always 'current';
 *  an edit whose live row vanished is 'source_missing'; an edit whose live row's fingerprint moved
 *  since the fork is 'source_changed'. */
export function draftSourceStatus(
  draft: LocationDraft,
  liveLoc: MapLocation | undefined,
): DraftSourceStatus {
  if (draft.mode.kind !== 'edit') return 'current'
  if (!liveLoc) return 'source_missing'
  return computeSourceFingerprint(liveLoc) === draft.mode.sourceRevision
    ? 'current'
    : 'source_changed'
}

/** Bounds check for the draft's coordinates via the ONE domain predicate
 *  (openSpaceTransform.isWithinOpenSpaceBounds). Returns a FLAG — an out-of-bounds or non-finite
 *  coordinate is reported, NEVER clamped and NEVER thrown (no-hidden-clamping law). */
export function validateDraftBounds(payload: LocationDraftPayload): boolean {
  return isWithinOpenSpaceBounds({ x: payload.x, y: payload.y })
}

/** Resolve a draft to the SAME LayerItem shape locationLayerAdapter.readItems produces — point
 *  representation at the draft's canonical world x/y, glyph/tone via the SHARED markerStyle policy —
 *  so the preview speaks the map's visual language with zero adapter-contract change. */
export function draftToLayerItem(draft: LocationDraft): LayerItem {
  const s = markerStyle(draft.payload)
  return {
    layer: 'locations',
    id: draft.draftId,
    label: draft.payload.name || 'New location',
    representation: { kind: 'point', world: { x: draft.payload.x, y: draft.payload.y } },
    tone: s.color,
    glyph: s.shape as PointGlyph,
  }
}

/** Parse + structurally validate ONE stored draft JSON string (localStorage rehydration path).
 *  Returns null on anything malformed — a bad stored blob is dropped, never trusted, never thrown
 *  into the render path. Staleness is NOT decided here: the store re-validates every rehydrated
 *  edit draft against CURRENT live rows via draftSourceStatus (mandatory re-validation). */
export function parseStoredDraft(json: string): LocationDraft | null {
  let raw: unknown
  try {
    raw = JSON.parse(json)
  } catch {
    return null
  }
  if (typeof raw !== 'object' || raw === null) return null
  const d = raw as Record<string, unknown>
  if (typeof d.draftId !== 'string' || d.draftId.length === 0) return null
  if (typeof d.createdAt !== 'number' || typeof d.updatedAt !== 'number') return null
  if (!isPayloadShaped(d.payload)) return null
  const mode = d.mode as Record<string, unknown> | null | undefined
  if (typeof mode !== 'object' || mode === null) return null
  if (mode.kind === 'create') {
    return {
      draftId: d.draftId,
      mode: { kind: 'create' },
      payload: draftPayloadFrom(d.payload as LocationDraftPayload),
      createdAt: d.createdAt,
      updatedAt: d.updatedAt,
    }
  }
  if (mode.kind === 'edit') {
    if (typeof mode.sourceId !== 'string' || typeof mode.sourceRevision !== 'string') return null
    if (!isPayloadShaped(mode.sourceSnapshot)) return null
    return {
      draftId: d.draftId,
      mode: {
        kind: 'edit',
        sourceId: mode.sourceId,
        sourceRevision: mode.sourceRevision,
        sourceSnapshot: draftPayloadFrom(mode.sourceSnapshot as LocationDraftPayload),
      },
      payload: draftPayloadFrom(d.payload as LocationDraftPayload),
      createdAt: d.createdAt,
      updatedAt: d.updatedAt,
    }
  }
  return null
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
