// WORLD EDITOR — V2A PR-2 "Mining Drafts" TYPES (CLIENT-SIDE ONLY, ZERO live mutation), expressed
// over the V2A GENERIC draft core (draftTypes.ts) exactly like the location domain
// (locationDraftTypes.ts): MiningDraftMode / MiningDraft / MiningDraftSourceStatus are the generic
// Draft contracts bound to the mining payload.
//
// A draft is a local, unpublished authoring intent for ONE mining field: it lives in the draft store
// (localStorage) and NEVER touches the read snapshot, the `mining_fields` table, or any RPC. Publish
// does not exist in this slice — the deferred-operations boundary (worldEditorTypes.
// DEFERRED_OPERATIONS) still owns publish/enable/disable/archive as EXPLICITLY DISABLED. The mining
// gameplay RPCs (the extract command and the securing processor, 0104/0106) are NOT a mutation path
// for this surface and are never reused here (guarded by tests/miningDraftGuards.spec.ts).
//
// The three read-contract fields are a Pick over the REAL MiningField contract (miningTypes.ts) —
// never a redefinition — so a draft can only carry fields the live read actually has, and a future
// publish slice diffs draft ↔ live field-for-field with no translation layer.
import type { MiningField } from '../mining/miningTypes'
import type { PendingBundle } from '../../lib/rewardBundle'
import type {
  Draft,
  DraftMode as GenericDraftMode,
  DraftSourceStatus as GenericDraftSourceStatus,
} from './draftTypes'

/** The editable slice of a mining field a draft carries.
 *
 *  `name` / `space_x` / `space_y` follow the Pick-over-live law: their types come from MiningField
 *  VERBATIM, so an edit draft is forkable/diffable against the live row field-for-field.
 *
 *  `reward_bundle_json` is DELIBERATELY DIFFERENT — a CREATE-only, LOCAL-AUTHORED field that is NOT
 *  readable from any live row: get_active_mining_fields never returns it (0226) and RLS forbids
 *  reading it (composition is revealed only by the caller's own extraction read, 0106). So
 *  `projectFromLive` sets it to null (an edit fork starts with no bundle — the client cannot know
 *  the live one) and `emptyCreatePayload` starts it at null (no reward configured yet). The shape is
 *  the ONE shared pending-bundle contract (lib/rewardBundle.ts) — never re-declared here. */
export type MiningDraftPayload = Pick<MiningField, 'name' | 'space_x' | 'space_y'> & {
  readonly reward_bundle_json: PendingBundle | null
}

/** Why the draft exists: a brand-new field, or an edit forked FROM a live row — the generic
 *  DraftMode bound to the mining payload (see draftTypes.ts for the staleness/dirtiness law). */
export type MiningDraftMode = GenericDraftMode<MiningDraftPayload>

/** One local mining-field draft — the generic Draft bound to the mining payload. `draftId` is
 *  client-generated (crypto.randomUUID) and is NOT a server id. Timestamps are epoch-ms, supplied by
 *  the store layer (pure model functions take them as inputs). */
export type MiningDraft = Draft<MiningDraftPayload>

/** Draft ↔ live-source relationship, recomputed against CURRENT live data (never trusted from
 *  storage): 'current' | 'source_changed' | 'source_missing' (see draftTypes.ts). */
export type MiningDraftSourceStatus = GenericDraftSourceStatus
