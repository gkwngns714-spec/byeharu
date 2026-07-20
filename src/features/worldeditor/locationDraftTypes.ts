// WORLD EDITOR — V1B-1 "Location Drafts" TYPES (CLIENT-SIDE ONLY, ZERO live mutation), now expressed
// over the V2A GENERIC draft core (draftTypes.ts): the SAME shapes under the SAME names — DraftMode /
// LocationDraft / DraftSourceStatus are the generic Draft contracts bound to the location payload.
// Zero behavior change; every importer and test keeps working unmodified.
//
// A draft is a local, unpublished authoring intent for ONE location: it lives in the draft store
// (localStorage) and NEVER touches the read snapshot, the `locations` table, or any RPC. Publish does
// not exist in this slice — the deferred-operations boundary (worldEditorTypes.DEFERRED_OPERATIONS)
// still owns publish/enable/disable/archive as EXPLICITLY DISABLED.
//
// The payload is a Pick over the REAL MapLocation contract (mapTypes.ts) — never a redefinition — so a
// draft can only carry fields the live read actually has, and a future publish slice diffs draft ↔ live
// field-for-field with no translation layer.
import type { MapLocation } from '../map/mapTypes'
import type {
  Draft,
  DraftMode as GenericDraftMode,
  DraftSourceStatus as GenericDraftSourceStatus,
} from './draftTypes'

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

/** Why the draft exists: a brand-new location, or an edit forked FROM a live row — the generic
 *  DraftMode bound to the location payload (see draftTypes.ts for the staleness/dirtiness law). */
export type DraftMode = GenericDraftMode<LocationDraftPayload>

/** One local location draft — the generic Draft bound to the location payload. `draftId` is
 *  client-generated (crypto.randomUUID) and is NOT a server id. Timestamps are epoch-ms, supplied by
 *  the store layer (pure model functions take them as inputs). */
export type LocationDraft = Draft<LocationDraftPayload>

/** Draft ↔ live-source relationship, recomputed against CURRENT live data (never trusted from
 *  storage): 'current' | 'source_changed' | 'source_missing' (see draftTypes.ts). */
export type DraftSourceStatus = GenericDraftSourceStatus
