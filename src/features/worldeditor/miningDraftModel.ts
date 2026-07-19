// WORLD EDITOR — V2A PR-2 mining-draft PURE MODEL, the MINING BINDING of the V2A GENERIC draft core
// (draftModel.ts), shaped exactly like the location binding (locationDraftModel.ts): the lifecycle
// logic lives ONCE in the generic core, reached through the ONE MINING_DRAFT_DESCRIPTOR; the thin
// wrappers below give the domain the same convenient module surface. No React, no DOM, no network
// IO, no storage IO, no client-server call of any kind; every function is DETERMINISTIC (ids and
// timestamps are passed IN by the store layer, never generated here).
//
// HARD BOUNDARIES (the location-domain laws, unchanged):
//   • Drafts NEVER write anywhere — no live-table mutation, no publish, no grant, and NO reuse of the
//     mining gameplay RPCs as a mutation path. This module cannot even express a write (guarded by
//     tests/miningDraftGuards.spec.ts).
//   • Draft space_x/space_y are DRAFT-ONLY values. Bounds problems are FLAGGED (validateDraftBounds),
//     NEVER clamped and NEVER thrown — the openSpaceTransform no-hidden-clamping law.
//   • Map representation matches miningLayerAdapter.readItems exactly (hex glyph, --color-warning
//     tone) — one visual language, no fork.
import { isWithinOpenSpaceBounds } from '../map/openSpaceTransform'
import type { MiningField } from '../mining/miningTypes'
import type { LayerItem } from './worldEditorTypes'
import type { DomainDraftDescriptor } from './draftTypes'
import type {
  MiningDraft,
  MiningDraftPayload,
  MiningDraftSourceStatus,
} from './miningDraftTypes'
import { validateMiningDraft, type MiningValidationReport } from './miningValidation'
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
export const MINING_DRAFT_PAYLOAD_KEYS = [
  'name',
  'space_x',
  'space_y',
  'reward_bundle_json',
] as const satisfies readonly (keyof MiningDraftPayload)[]

/** The blank payload a create-draft starts from (and the isDirty baseline for creates). World origin
 *  (0,0) — always in bounds; reward_bundle_json starts null (no reward configured yet — the
 *  CREATE-only local field, see miningDraftTypes.ts). */
export const EMPTY_MINING_CREATE_PAYLOAD: MiningDraftPayload = {
  name: '',
  space_x: 0,
  space_y: 0,
  reward_bundle_json: null,
}

/** Structural payload check for rehydration (presence + primitive kinds; the bundle's deep shape is
 *  advisory-validated by miningValidation, never trusted structurally beyond object-or-null — a
 *  malformed stored bundle renders honestly and is flagged, not thrown). */
function isPayloadShaped(p: unknown): boolean {
  if (typeof p !== 'object' || p === null) return false
  const o = p as Record<string, unknown>
  const b = o.reward_bundle_json
  return (
    typeof o.name === 'string' &&
    typeof o.space_x === 'number' &&
    typeof o.space_y === 'number' &&
    (b === null || (typeof b === 'object' && b !== undefined && !Array.isArray(b)))
  )
}

/** The ONE mining binding of the generic draft core (V2A): payload projection, identity, storage
 *  keying (its own versioned prefix, distinct from the location domain's), LayerItem resolution
 *  (miningLayerAdapter's hex/--color-warning language), bounds (ONE shared predicate), and the
 *  domain's advisory validator (validateMiningDraft, built on the generic draftValidation contract). */
export const MINING_DRAFT_DESCRIPTOR: DomainDraftDescriptor<
  MiningDraftPayload,
  MiningField,
  MiningValidationReport
> = {
  domainId: 'mining',
  payloadKeys: MINING_DRAFT_PAYLOAD_KEYS,
  emptyCreatePayload: EMPTY_MINING_CREATE_PAYLOAD,
  storageKeyPrefix: 'byeharu.worldEditor.miningDraft.v1:',
  // The live read (get_active_mining_fields) carries name + coords ONLY — reward_bundle_json is
  // NEVER readable from a live row (RLS-forbidden; revealed only by the caller's own extraction
  // read, 0106), so an edit fork honestly starts with null, exactly like emptyCreatePayload does.
  projectFromLive: (live) => ({
    name: live.name,
    space_x: live.space_x,
    space_y: live.space_y,
    reward_bundle_json: null,
  }),
  // mining_fields.name is the unique natural key (0103) — mining exposes NO client-visible uuid.
  liveId: (live) => live.name,
  isPayloadShaped,
  toLayerItem: (draftId, payload) => ({
    layer: 'mining',
    id: draftId,
    label: payload.name || 'New field',
    representation: { kind: 'point', world: { x: payload.space_x, y: payload.space_y } },
    tone: 'var(--color-warning)',
    glyph: 'hex',
  }),
  withinBounds: (payload) => isWithinOpenSpaceBounds({ x: payload.space_x, y: payload.space_y }),
  validate: (draft, env) => validateMiningDraft(draft, env),
}

/** Stable fingerprint over the MiningDraftPayload keys (canonical key order + JSON-encoded values →
 *  FNV-1a 32-bit hex, via the ONE generic implementation). Used as the edit fork's `sourceRevision`
 *  and recomputed against CURRENT live rows to detect staleness. */
export function computeSourceFingerprint(source: MiningDraftPayload): string {
  return coreComputeSourceFingerprint(MINING_DRAFT_DESCRIPTOR, source)
}

/** Start a brand-new mining-field draft (mode 'create') at the blank payload. Deterministic — the
 *  caller supplies the id and clock. */
export function beginCreate(draftId: string, now: number): MiningDraft {
  return coreBeginCreate(MINING_DRAFT_DESCRIPTOR, draftId, now)
}

/** Fork an edit draft off a LIVE mining field: payload starts as the projection of the row (bundle
 *  null — never readable), and the mode pins sourceId (the name) + the row's fingerprint + a full
 *  snapshot so dirtiness/staleness stay decidable. */
export function forkEdit(field: MiningField, draftId: string, now: number): MiningDraft {
  return coreForkEdit(MINING_DRAFT_DESCRIPTOR, field, draftId, now)
}

/** Apply a partial payload change immutably; bumps updatedAt to the supplied clock. */
export function patch(
  draft: MiningDraft,
  partial: Partial<MiningDraftPayload>,
  now: number,
): MiningDraft {
  return corePatch(draft, partial, now)
}

/** True when the draft's payload differs from its baseline: the forked snapshot for edits, the blank
 *  create payload for creates. Fingerprint equality — so patching a field back to its original value
 *  cleanly returns to not-dirty. */
export function isDirty(draft: MiningDraft): boolean {
  return coreIsDirty(MINING_DRAFT_DESCRIPTOR, draft)
}

/** Draft ↔ CURRENT live-row relationship (recomputed, never stored): a create is always 'current';
 *  an edit whose live row vanished is 'source_missing'; an edit whose live row's fingerprint moved
 *  since the fork is 'source_changed'. */
export function draftSourceStatus(
  draft: MiningDraft,
  liveField: MiningField | undefined,
): MiningDraftSourceStatus {
  return coreDraftSourceStatus(MINING_DRAFT_DESCRIPTOR, draft, liveField)
}

/** Bounds check for the draft's coordinates via the ONE domain predicate
 *  (openSpaceTransform.isWithinOpenSpaceBounds). Returns a FLAG — an out-of-bounds or non-finite
 *  coordinate is reported, NEVER clamped and NEVER thrown (no-hidden-clamping law). */
export function validateDraftBounds(payload: MiningDraftPayload): boolean {
  return MINING_DRAFT_DESCRIPTOR.withinBounds(payload)
}

/** Resolve a draft to the SAME LayerItem shape miningLayerAdapter.readItems produces — point
 *  representation at the draft's canonical world space_x/space_y, hex glyph, --color-warning tone —
 *  so the preview speaks the map's visual language with zero adapter-contract change. */
export function draftToLayerItem(draft: MiningDraft): LayerItem {
  return coreDraftToLayerItem(MINING_DRAFT_DESCRIPTOR, draft)
}

/** Parse + structurally validate ONE stored draft JSON string (localStorage rehydration path).
 *  Returns null on anything malformed — a bad stored blob is dropped, never trusted, never thrown
 *  into the render path. Staleness is NOT decided here: the store re-validates every rehydrated
 *  edit draft against CURRENT live rows via draftSourceStatus (mandatory re-validation). */
export function parseStoredDraft(json: string): MiningDraft | null {
  return coreParseStoredDraft(MINING_DRAFT_DESCRIPTOR, json)
}
