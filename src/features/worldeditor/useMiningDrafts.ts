// WORLD EDITOR — V2A PR-2 mining-draft STORE, the MINING BINDING of the V2A GENERIC draft store
// (useDrafts.ts), shaped exactly like the location binding (useLocationDrafts.ts): same reducer,
// same localStorage mirror (under the mining domain's own versioned prefix), same rehydrate-wins
// merge, same mandatory re-validation, same store surface. CLIENT-SIDE ONLY: drafts live in React
// state mirrored to localStorage and NOWHERE else; this store performs ZERO network IO — no
// client-server call of any kind, no RPC, no live-table write (guarded by
// tests/miningDraftGuards.spec.ts).
//
// STRUCTURAL LAW: this store is a SEPARATE structure fully apart of the read snapshot. Drafts must
// NEVER be merged into WorldEditorData (worldEditorData.ts stays draft-free — pinned by the
// read-snapshot integrity tests); the shell composes "live items + draft preview" at RENDER time only.
//
// REHYDRATION LAW: a stored draft is never trusted as fresh — see useDrafts.ts (the ONE generic
// authority for the store lifecycle this module binds to the mining domain).
import type { MiningField } from '../mining/miningTypes'
import type { MiningDraftPayload } from './miningDraftTypes'
import type { MiningValidationReport } from './miningValidation'
import { MINING_DRAFT_DESCRIPTOR } from './miningDraftModel'
import {
  createDraftsContext,
  draftStorageKey as genericDraftStorageKey,
  useDraftsStore,
  type DraftsStore,
} from './useDrafts'

/** The localStorage key one mining draft persists under. */
export function draftStorageKey(draftId: string): string {
  return genericDraftStorageKey(MINING_DRAFT_DESCRIPTOR, draftId)
}

/** The store surface the shell provides and the panel/preview consume — the generic DraftsStore
 *  bound to the mining domain (drafts, activeDraft, statusById, reportById + the five actions;
 *  member-for-member the same surface as the location store). */
export type MiningDraftsStore = DraftsStore<MiningDraftPayload, MiningField, MiningValidationReport>

/** Build the ONE mining draft store instance (the WorldEditor shell calls this and provides it via
 *  MiningDraftsContext). `liveFields` is the CURRENT read snapshot's mining-field list
 *  (data.miningFields) — used ONLY to re-validate edit drafts (fingerprint comparison); drafts never
 *  flow back into it. */
export function useMiningDraftsStore(
  liveFields: readonly MiningField[] | null,
): MiningDraftsStore {
  return useDraftsStore(MINING_DRAFT_DESCRIPTOR, liveFields)
}

const binding = createDraftsContext<MiningDraftPayload, MiningField, MiningValidationReport>(
  'useMiningDrafts must be used inside MiningDraftsContext.Provider',
)

/** Context the WorldEditor shell provides; MiningDraftPanel consumes via the hook. */
export const MiningDraftsContext = binding.Context

export function useMiningDrafts(): MiningDraftsStore {
  return binding.useStore()
}
