// WORLD EDITOR — V2C exploration-draft STORE, the EXPLORATION BINDING of the V2A GENERIC draft
// store (useDrafts.ts), shaped exactly like the mining binding (useMiningDrafts.ts): same reducer,
// same localStorage mirror (under the exploration domain's own versioned prefix), same
// rehydrate-wins merge, same mandatory re-validation, same store surface. CLIENT-SIDE ONLY: drafts
// live in React state mirrored to localStorage and NOWHERE else; this store performs ZERO network
// IO — no client-server call of any kind, no RPC, no live-table write (guarded by
// tests/explorationDraftGuards.spec.ts).
//
// STRUCTURAL LAW: this store is a SEPARATE structure fully apart of the read snapshot. Drafts must
// NEVER be merged into WorldEditorData (worldEditorData.ts stays draft-free — pinned by the
// read-snapshot integrity tests); the shell composes "live items + draft preview" at RENDER time only.
//
// REHYDRATION LAW: a stored draft is never trusted as fresh — see useDrafts.ts (the ONE generic
// authority for the store lifecycle this module binds to the exploration domain).
import type { ExplorationSiteLite } from '../exploration/explorationTypes'
import type { ExplorationDraftPayload } from './explorationDraftTypes'
import type { ExplorationValidationReport } from './explorationValidation'
import { EXPLORATION_DRAFT_DESCRIPTOR } from './explorationDraftModel'
import {
  createDraftsContext,
  draftStorageKey as genericDraftStorageKey,
  useDraftsStore,
  type DraftsStore,
} from './useDrafts'

/** The localStorage key one exploration draft persists under. */
export function draftStorageKey(draftId: string): string {
  return genericDraftStorageKey(EXPLORATION_DRAFT_DESCRIPTOR, draftId)
}

/** The store surface the shell provides and the panel/preview consume — the generic DraftsStore
 *  bound to the exploration domain (drafts, activeDraft, statusById, reportById + the five actions;
 *  member-for-member the same surface as the location and mining stores). */
export type ExplorationDraftsStore = DraftsStore<
  ExplorationDraftPayload,
  ExplorationSiteLite,
  ExplorationValidationReport
>

/** Build the ONE exploration draft store instance (the WorldEditor shell calls this and provides it
 *  via ExplorationDraftsContext). `liveSites` is the CURRENT read snapshot's exploration-site list
 *  (data.explorationSites) — used ONLY to re-validate edit drafts (fingerprint comparison); drafts
 *  never flow back into it. `scanRadius` (C1) is the snapshot's server-authoritative
 *  game_config.exploration_scan_radius (null when absent) — threaded into the validation context so
 *  the overlap rule uses the real tunable, not the hardcoded fallback. */
export function useExplorationDraftsStore(
  liveSites: readonly ExplorationSiteLite[] | null,
  scanRadius: number | null = null,
): ExplorationDraftsStore {
  return useDraftsStore(EXPLORATION_DRAFT_DESCRIPTOR, liveSites, scanRadius)
}

const binding = createDraftsContext<
  ExplorationDraftPayload,
  ExplorationSiteLite,
  ExplorationValidationReport
>('useExplorationDrafts must be used inside ExplorationDraftsContext.Provider')

/** Context the WorldEditor shell provides; ExplorationDraftPanel consumes via the hook. */
export const ExplorationDraftsContext = binding.Context

export function useExplorationDrafts(): ExplorationDraftsStore {
  return binding.useStore()
}
