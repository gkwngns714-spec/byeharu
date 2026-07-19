// WORLD EDITOR — V2C "Exploration Drafts" TYPES (CLIENT-SIDE ONLY, ZERO live mutation), expressed
// over the V2A GENERIC draft core (draftTypes.ts) exactly like the mining domain
// (miningDraftTypes.ts): ExplorationDraftMode / ExplorationDraft / ExplorationDraftSourceStatus are
// the generic Draft contracts bound to the exploration payload.
//
// A draft is a local, unpublished authoring intent for ONE exploration site: it lives in the draft
// store (localStorage) and NEVER touches the read snapshot, the `exploration_sites` table, or any
// RPC. Publish does not exist in this slice — the deferred-operations boundary (worldEditorTypes.
// DEFERRED_OPERATIONS) still owns publish/enable/disable/archive as EXPLICITLY DISABLED. The
// exploration gameplay RPCs (the scan command and the securing processor, 0099/0100) are NOT a
// mutation path for this surface and are never reused here (guarded by
// tests/explorationDraftGuards.spec.ts).
//
// The three read-contract fields are a Pick over the REAL ExplorationSiteLite contract
// (explorationTypes.ts) — never a redefinition — so a draft can only carry fields the live read
// actually has, and a future publish slice diffs draft ↔ live site field-for-field with no
// translation layer.
import type { ExplorationSiteLite } from '../exploration/explorationTypes'
import type { PendingBundle } from '../../lib/rewardBundle'
import type {
  Draft,
  DraftMode as GenericDraftMode,
  DraftSourceStatus as GenericDraftSourceStatus,
} from './draftTypes'

/** The editable slice of an exploration site a draft carries.
 *
 *  `name` / `space_x` / `space_y` follow the Pick-over-live law: their types come from
 *  ExplorationSiteLite VERBATIM, so an edit draft is forkable/diffable against the live row
 *  field-for-field.
 *
 *  `reward_bundle_json` is DELIBERATELY DIFFERENT — a CREATE-only, LOCAL-AUTHORED field that is NOT
 *  readable from any live row: exploration_sites is RLS server-only (0098 — no client policy, no
 *  grant) and the editor's SELECT reads name + coords ONLY (composition is revealed only by the
 *  caller's own discovery read, 0101). So `projectFromLive` sets it to null (an edit fork starts
 *  with no bundle — the client cannot know the live one) and `emptyCreatePayload` starts it at null
 *  (no reward configured yet). The shape is the ONE shared pending-bundle contract
 *  (lib/rewardBundle.ts) — never re-declared here. */
export type ExplorationDraftPayload = Pick<ExplorationSiteLite, 'name' | 'space_x' | 'space_y'> & {
  readonly reward_bundle_json: PendingBundle | null
}

/** Why the draft exists: a brand-new site, or an edit forked FROM a live row — the generic
 *  DraftMode bound to the exploration payload (see draftTypes.ts for the staleness/dirtiness law). */
export type ExplorationDraftMode = GenericDraftMode<ExplorationDraftPayload>

/** One local exploration-site draft — the generic Draft bound to the exploration payload. `draftId`
 *  is client-generated (crypto.randomUUID) and is NOT a server id. Timestamps are epoch-ms, supplied
 *  by the store layer (pure model functions take them as inputs). */
export type ExplorationDraft = Draft<ExplorationDraftPayload>

/** Draft ↔ live-source relationship, recomputed against CURRENT live data (never trusted from
 *  storage): 'current' | 'source_changed' | 'source_missing' (see draftTypes.ts). */
export type ExplorationDraftSourceStatus = GenericDraftSourceStatus
