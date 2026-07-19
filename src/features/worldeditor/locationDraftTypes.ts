// WORLD EDITOR — V1B-1 "Location Drafts" TYPES (CLIENT-SIDE ONLY, ZERO live mutation). A draft is a
// local, unpublished authoring intent for ONE location: it lives in the draft store (localStorage) and
// NEVER touches the read snapshot, the `locations` table, or any RPC. Publish does not exist in this
// slice — the deferred-operations boundary (worldEditorTypes.DEFERRED_OPERATIONS) still owns
// publish/enable/disable/archive as EXPLICITLY DISABLED.
//
// The payload is a Pick over the REAL MapLocation contract (mapTypes.ts) — never a redefinition — so a
// draft can only carry fields the live read actually has, and a future publish slice diffs draft ↔ live
// field-for-field with no translation layer.
import type { MapLocation } from '../map/mapTypes'

/** The editable slice of a location a draft carries. Field types come from MapLocation VERBATIM. */
export type LocationDraftPayload = Pick<
  MapLocation,
  | 'name'
  | 'location_type'
  | 'activity_type'
  | 'x'
  | 'y'
  | 'reward_tier'
  | 'base_difficulty'
  | 'min_power_required'
  | 'is_public'
  | 'territory_radius'
  | 'status'
>

/** Why the draft exists: a brand-new location, or an edit forked FROM a live row. An edit remembers
 *  its source id, the fingerprint (revision) of the live row at fork time, and a full snapshot of the
 *  forked payload — so staleness ("the live row changed under me") and dirtiness ("I changed something")
 *  are both decidable offline, purely from the draft. */
export type DraftMode =
  | { readonly kind: 'create' }
  | {
      readonly kind: 'edit'
      readonly sourceId: string
      readonly sourceRevision: string
      readonly sourceSnapshot: LocationDraftPayload
    }

/** One local location draft. `draftId` is client-generated (crypto.randomUUID) and is NOT a server id.
 *  Timestamps are epoch-ms, supplied by the store layer (pure model functions take them as inputs). */
export interface LocationDraft {
  readonly draftId: string
  readonly mode: DraftMode
  readonly payload: LocationDraftPayload
  readonly createdAt: number
  readonly updatedAt: number
}

/** Draft ↔ live-source relationship, recomputed against CURRENT live data (never trusted from storage):
 *  'current' — the live source still matches the forked revision (or the draft is a create);
 *  'source_changed' — the live row's fingerprint moved since the fork (stale draft);
 *  'source_missing' — the live row no longer exists in the read snapshot. */
export type DraftSourceStatus = 'current' | 'source_changed' | 'source_missing'
