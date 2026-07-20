// WORLD EDITOR — V2A PR-1 GENERIC DRAFT CORE — TYPES. Extracted BEHAVIOR-PRESERVING from the merged
// V1B location framework (locationDraftTypes.ts): the draft lifecycle — create / fork-edit / patch /
// dirtiness / staleness / persistence / preview / advisory validation — is domain-agnostic. A domain
// (locations today; mining fields etc. in later slices) binds itself to the core through exactly ONE
// DomainDraftDescriptor and re-expresses its old module surface as thin wrappers over the core
// (single-authority law: the lifecycle logic lives HERE, once).
//
// CLIENT-SIDE ONLY, ZERO live mutation: a draft is a local, unpublished authoring intent. It lives in
// the draft store (localStorage) and NEVER touches a read snapshot, a live table, or any RPC. Publish
// does not exist in this layer — the deferred-operations boundary (worldEditorTypes.DEFERRED_OPERATIONS)
// still owns publish/enable/disable/archive as EXPLICITLY DISABLED.
import type { LayerItem } from './worldEditorTypes'

/** Why a draft exists: a brand-new item, or an edit forked FROM a live row. An edit remembers its
 *  source id, the fingerprint (revision) of the live row at fork time, and a full snapshot of the
 *  forked payload — so staleness ("the live row changed under me") and dirtiness ("I changed
 *  something") are both decidable offline, purely from the draft. */
export type DraftMode<TPayload> =
  | { readonly kind: 'create' }
  | {
      readonly kind: 'edit'
      readonly sourceId: string
      readonly sourceRevision: string
      readonly sourceSnapshot: TPayload
    }

/** One local draft over a domain payload. `draftId` is client-generated (crypto.randomUUID) and is
 *  NOT a server id. Timestamps are epoch-ms, supplied by the store layer (pure model functions take
 *  them as inputs). */
export interface Draft<TPayload> {
  readonly draftId: string
  readonly mode: DraftMode<TPayload>
  readonly payload: TPayload
  readonly createdAt: number
  readonly updatedAt: number
}

/** Draft ↔ live-source relationship, recomputed against CURRENT live data (never trusted from
 *  storage): 'current' — the live source still matches the forked revision (or the draft is a
 *  create); 'source_changed' — the live row's fingerprint moved since the fork (stale draft);
 *  'source_missing' — the live row no longer exists in the read snapshot. */
export type DraftSourceStatus = 'current' | 'source_changed' | 'source_missing'

/** Everything a domain validator may consult beyond the draft itself. Assembled by the generic store
 *  (useDrafts) from CURRENT live data on every change — never persisted, never trusted from storage. */
export interface DraftValidationEnv<TPayload, TLive> {
  /** The CURRENT live rows of this domain (the read snapshot's slice). */
  readonly live: readonly TLive[]
  /** This draft's live-source relationship (draftSourceStatus output, recomputed by the store). */
  readonly sourceStatus: DraftSourceStatus
  /** Every OTHER local draft (this draft excluded) — for conflicting-draft detection. */
  readonly otherDrafts: readonly Draft<TPayload>[]
  /** C1: the SERVER-AUTHORITATIVE overlap radius for this domain's proximity rule (game_config's
   *  mining_extract_radius / exploration_scan_radius, threaded from the read snapshot by the shell).
   *  Absent/null → the domain validator falls back to its clearly-labeled NON-AUTHORITATIVE
   *  default. Domains without a proximity rule (locations, zones) ignore it. The value arrives AS
   *  CONTEXT — the pure validators never fetch. */
  readonly overlapRadius?: number | null
}

/** The ONE binding a domain hands the generic core. Everything the lifecycle needs to know about a
 *  domain lives here — payload projection, identity, storage keying, map representation, bounds, and
 *  the domain's own advisory validator. The core stays 100% domain-blind. */
export interface DomainDraftDescriptor<TPayload, TLive, TReport> {
  /** Stable domain identifier (e.g. 'location'). */
  readonly domainId: string
  /** The payload keys in ONE canonical order — the single authority the fingerprint, the payload
   *  projector, and the stored-draft validator all share (so they can never drift apart). */
  readonly payloadKeys: readonly (keyof TPayload & string)[]
  /** The blank payload a create-draft starts from (and the isDirty baseline for creates). */
  readonly emptyCreatePayload: TPayload
  /** localStorage key prefix; one draft persists under `${storageKeyPrefix}${draftId}`. */
  readonly storageKeyPrefix: string
  /** Project a live row onto exactly the draft payload (extra live-row fields are dropped). */
  projectFromLive(live: TLive): TPayload
  /** The live row's server id (an edit draft's fork source). */
  liveId(live: TLive): string
  /** Structural payload check for rehydration (presence + primitive kinds; domain unions are trusted
   *  as strings — a stale value renders honestly and simply fails any FUTURE server validation). */
  isPayloadShaped(p: unknown): boolean
  /** Resolve a draft payload to the SAME LayerItem shape the domain's read adapter produces — so the
   *  preview speaks the map's visual language with zero adapter-contract change. */
  toLayerItem(draftId: string, payload: TPayload): LayerItem
  /** Bounds FLAG for the payload's coordinates (never clamped, never thrown — the openSpaceTransform
   *  no-hidden-clamping law). */
  withinBounds(payload: TPayload): boolean
  /** The domain's ADVISORY validator (pure; flag-only). The generic store recomputes this per draft
   *  on every change and surfaces the report opaquely (TReport) — the core never inspects it. */
  validate(draft: Draft<TPayload>, env: DraftValidationEnv<TPayload, TLive>): TReport
}
