// WORLD EDITOR — V2C exploration-draft PURE MODEL, the EXPLORATION BINDING of the V2A GENERIC draft
// core (draftModel.ts), shaped exactly like the mining binding (miningDraftModel.ts): the lifecycle
// logic lives ONCE in the generic core, reached through the ONE EXPLORATION_DRAFT_DESCRIPTOR; the
// thin wrappers below give the domain the same convenient module surface. No React, no DOM, no
// network IO, no storage IO, no client-server call of any kind; every function is DETERMINISTIC
// (ids and timestamps are passed IN by the store layer, never generated here).
//
// HARD BOUNDARIES (the location/mining-domain laws, unchanged):
//   • Drafts NEVER write anywhere — no live-table mutation, no publish, no grant, and NO reuse of
//     the exploration gameplay RPCs as a mutation path. This module cannot even express a write
//     (guarded by tests/explorationDraftGuards.spec.ts).
//   • Draft space_x/space_y are DRAFT-ONLY values. Bounds problems are FLAGGED (validateDraftBounds),
//     NEVER clamped and NEVER thrown — the openSpaceTransform no-hidden-clamping law.
//   • Map representation matches explorationLayerAdapter.readItems exactly (diamond glyph,
//     --color-accent tone) — one visual language, no fork.
import { isWithinOpenSpaceBounds } from '../map/openSpaceTransform'
import type { ExplorationSiteLite } from '../exploration/explorationTypes'
import type { LayerItem } from './worldEditorTypes'
import type { DomainDraftDescriptor } from './draftTypes'
import type {
  ExplorationDraft,
  ExplorationDraftPayload,
  ExplorationDraftSourceStatus,
} from './explorationDraftTypes'
import { validateExplorationDraft, type ExplorationValidationReport } from './explorationValidation'
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
export const EXPLORATION_DRAFT_PAYLOAD_KEYS = [
  'name',
  'space_x',
  'space_y',
  'reward_bundle_json',
] as const satisfies readonly (keyof ExplorationDraftPayload)[]

/** The blank payload a create-draft starts from (and the isDirty baseline for creates). World origin
 *  (0,0) — always in bounds; reward_bundle_json starts null (no reward configured yet — the
 *  CREATE-only local field, see explorationDraftTypes.ts). */
export const EMPTY_EXPLORATION_CREATE_PAYLOAD: ExplorationDraftPayload = {
  name: '',
  space_x: 0,
  space_y: 0,
  reward_bundle_json: null,
}

/** Structural payload check for rehydration (presence + primitive kinds; the bundle's deep shape is
 *  advisory-validated by explorationValidation, never trusted structurally beyond object-or-null — a
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

/** The ONE exploration binding of the generic draft core (V2C): payload projection, identity,
 *  storage keying (its own versioned prefix, distinct from the location and mining domains'),
 *  LayerItem resolution (explorationLayerAdapter's diamond/--color-accent language), bounds (ONE
 *  shared predicate), and the domain's advisory validator (validateExplorationDraft, built on the
 *  generic draftValidation contract). */
export const EXPLORATION_DRAFT_DESCRIPTOR: DomainDraftDescriptor<
  ExplorationDraftPayload,
  ExplorationSiteLite,
  ExplorationValidationReport
> = {
  domainId: 'exploration',
  payloadKeys: EXPLORATION_DRAFT_PAYLOAD_KEYS,
  emptyCreatePayload: EMPTY_EXPLORATION_CREATE_PAYLOAD,
  storageKeyPrefix: 'byeharu.worldEditor.explorationDraft.v1:',
  // The editor's live read (the exploration_sites SELECT) carries name + coords ONLY —
  // reward_bundle_json is NEVER readable from a live row (RLS server-only, 0098; revealed only by
  // the caller's own discovery read, 0101), so an edit fork honestly starts with null, exactly like
  // emptyCreatePayload does.
  projectFromLive: (live) => ({
    name: live.name,
    space_x: live.space_x,
    space_y: live.space_y,
    reward_bundle_json: null,
  }),
  // exploration_sites.name is the unique natural key (0098) — the editor's read contract exposes NO
  // client-visible uuid (ExplorationSiteLite is name + coords only).
  liveId: (live) => live.name,
  toLayerItem: (draftId, payload) => ({
    layer: 'exploration',
    id: draftId,
    label: payload.name || 'New site',
    representation: { kind: 'point', world: { x: payload.space_x, y: payload.space_y } },
    tone: 'var(--color-accent)',
    glyph: 'diamond',
  }),
  isPayloadShaped,
  withinBounds: (payload) => isWithinOpenSpaceBounds({ x: payload.space_x, y: payload.space_y }),
  validate: (draft, env) => validateExplorationDraft(draft, env),
}

/** Stable fingerprint over the ExplorationDraftPayload keys (canonical key order + JSON-encoded
 *  values → FNV-1a 32-bit hex, via the ONE generic implementation). Used as the edit fork's
 *  `sourceRevision` and recomputed against CURRENT live rows to detect staleness. */
export function computeSourceFingerprint(source: ExplorationDraftPayload): string {
  return coreComputeSourceFingerprint(EXPLORATION_DRAFT_DESCRIPTOR, source)
}

/** Start a brand-new exploration-site draft (mode 'create') at the blank payload. Deterministic —
 *  the caller supplies the id and clock. */
export function beginCreate(draftId: string, now: number): ExplorationDraft {
  return coreBeginCreate(EXPLORATION_DRAFT_DESCRIPTOR, draftId, now)
}

/** Fork an edit draft off a LIVE exploration site: payload starts as the projection of the row
 *  (bundle null — never readable), and the mode pins sourceId (the name) + the row's fingerprint +
 *  a full snapshot so dirtiness/staleness stay decidable. */
export function forkEdit(site: ExplorationSiteLite, draftId: string, now: number): ExplorationDraft {
  return coreForkEdit(EXPLORATION_DRAFT_DESCRIPTOR, site, draftId, now)
}

/** Apply a partial payload change immutably; bumps updatedAt to the supplied clock. */
export function patch(
  draft: ExplorationDraft,
  partial: Partial<ExplorationDraftPayload>,
  now: number,
): ExplorationDraft {
  return corePatch(draft, partial, now)
}

/** True when the draft's payload differs from its baseline: the forked snapshot for edits, the blank
 *  create payload for creates. Fingerprint equality — so patching a field back to its original value
 *  cleanly returns to not-dirty. */
export function isDirty(draft: ExplorationDraft): boolean {
  return coreIsDirty(EXPLORATION_DRAFT_DESCRIPTOR, draft)
}

/** Draft ↔ CURRENT live-row relationship (recomputed, never stored): a create is always 'current';
 *  an edit whose live row vanished is 'source_missing'; an edit whose live row's fingerprint moved
 *  since the fork is 'source_changed'. */
export function draftSourceStatus(
  draft: ExplorationDraft,
  liveSite: ExplorationSiteLite | undefined,
): ExplorationDraftSourceStatus {
  return coreDraftSourceStatus(EXPLORATION_DRAFT_DESCRIPTOR, draft, liveSite)
}

/** Bounds check for the draft's coordinates via the ONE domain predicate
 *  (openSpaceTransform.isWithinOpenSpaceBounds). Returns a FLAG — an out-of-bounds or non-finite
 *  coordinate is reported, NEVER clamped and NEVER thrown (no-hidden-clamping law). */
export function validateDraftBounds(payload: ExplorationDraftPayload): boolean {
  return EXPLORATION_DRAFT_DESCRIPTOR.withinBounds(payload)
}

/** Resolve a draft to the SAME LayerItem shape explorationLayerAdapter.readItems produces — point
 *  representation at the draft's canonical world space_x/space_y, diamond glyph, --color-accent
 *  tone — so the preview speaks the map's visual language with zero adapter-contract change. */
export function draftToLayerItem(draft: ExplorationDraft): LayerItem {
  return coreDraftToLayerItem(EXPLORATION_DRAFT_DESCRIPTOR, draft)
}

/** Parse + structurally validate ONE stored draft JSON string (localStorage rehydration path).
 *  Returns null on anything malformed — a bad stored blob is dropped, never trusted, never thrown
 *  into the render path. Staleness is NOT decided here: the store re-validates every rehydrated
 *  edit draft against CURRENT live rows via draftSourceStatus (mandatory re-validation). */
export function parseStoredDraft(json: string): ExplorationDraft | null {
  return coreParseStoredDraft(EXPLORATION_DRAFT_DESCRIPTOR, json)
}
