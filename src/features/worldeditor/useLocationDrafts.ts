// WORLD EDITOR — V1B-1 location-draft STORE, now the LOCATION BINDING of the V2A GENERIC draft store
// (useDrafts.ts). Same reducer, same localStorage keys, same rehydrate-wins merge, same mandatory
// re-validation, same store surface under the SAME exported names — zero behavior change. CLIENT-SIDE
// ONLY: drafts live in React state mirrored to localStorage and NOWHERE else; this store performs
// ZERO network IO — no client-server call of any kind, no RPC, no live-table write (guarded by
// tests/locationDraftGuards.spec.ts).
//
// STRUCTURAL LAW: this store is a SEPARATE structure fully apart of the read snapshot. Drafts must
// NEVER be merged into WorldEditorData (worldEditorData.ts stays draft-free — pinned by the
// read-snapshot integrity test); the shell composes "live items + draft preview" at RENDER time only.
//
// REHYDRATION LAW: a stored draft is never trusted as fresh — see useDrafts.ts (the ONE generic
// authority for the store lifecycle this module binds to the location domain).
import type { MapLocation } from '../map/mapTypes'
import type { LocationDraftPayload } from './locationDraftTypes'
import type { ValidationReport } from './locationValidation'
import { LOCATION_DRAFT_DESCRIPTOR } from './locationDraftModel'
import {
  createDraftsContext,
  draftStorageKey as genericDraftStorageKey,
  useDraftsStore,
  type DraftsStore,
} from './useDrafts'

/** The localStorage key one draft persists under. */
export function draftStorageKey(draftId: string): string {
  return genericDraftStorageKey(LOCATION_DRAFT_DESCRIPTOR, draftId)
}

/** The store surface the shell provides and the panel/preview consume — the generic DraftsStore
 *  bound to the location domain (drafts, activeDraft, statusById, reportById + the five actions;
 *  identical member-for-member to the V1B interface). */
export type LocationDraftsStore = DraftsStore<LocationDraftPayload, MapLocation, ValidationReport>

/** Build the ONE draft store instance (the WorldEditor shell calls this and provides it via
 *  LocationDraftsContext). `liveLocations` is the CURRENT read snapshot's location list — used ONLY
 *  to re-validate edit drafts (fingerprint comparison); drafts never flow back into it. */
export function useLocationDraftsStore(
  liveLocations: readonly MapLocation[] | null,
): LocationDraftsStore {
  return useDraftsStore(LOCATION_DRAFT_DESCRIPTOR, liveLocations)
}

const binding = createDraftsContext<LocationDraftPayload, MapLocation, ValidationReport>(
  'useLocationDrafts must be used inside LocationDraftsContext.Provider',
)

/** Context the WorldEditor shell provides; LocationDraftPanel / DraftPreview consume via the hook. */
export const LocationDraftsContext = binding.Context

export function useLocationDrafts(): LocationDraftsStore {
  return binding.useStore()
}
