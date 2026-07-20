// WORLD EDITOR — V3A PR-2 zone-draft STORE, the ZONE BINDING of the generic draft store
// (useDrafts.ts), shaped exactly like the mining binding (useMiningDrafts.ts): same reducer, same
// localStorage mirror (under the zone domain's own versioned prefix), same rehydrate-wins merge,
// same mandatory re-validation, same store surface. ZERO new store code — this module is bindings
// only. CLIENT-SIDE ONLY: drafts live in React state mirrored to localStorage and NOWHERE else;
// this store performs ZERO network IO — no client-server call of any kind, no RPC, no live-table
// write (guarded by tests/zoneDraftGuards.spec.ts).
//
// STRUCTURAL LAW: this store is a SEPARATE structure fully apart of the read snapshot. Drafts must
// NEVER be merged into WorldEditorData (worldEditorData.ts stays draft-free — pinned by the
// read-snapshot integrity tests); the shell composes "live items + draft preview" at RENDER time only.
//
// REHYDRATION LAW: a stored draft is never trusted as fresh — see useDrafts.ts (the ONE generic
// authority for the store lifecycle this module binds to the zone domain).
import type { LiveDangerZone, ZoneDraftPayload } from './zoneDraftTypes'
import type { ZoneValidationReport } from './zoneValidation'
import { ZONE_DRAFT_DESCRIPTOR } from './zoneDraftModel'
import {
  createDraftsContext,
  draftStorageKey as genericDraftStorageKey,
  useDraftsStore,
  type DraftsStore,
} from './useDrafts'

/** The localStorage key one zone draft persists under. */
export function draftStorageKey(draftId: string): string {
  return genericDraftStorageKey(ZONE_DRAFT_DESCRIPTOR, draftId)
}

/** The store surface the shell provides and the panel/preview/gesture layer consume — the generic
 *  DraftsStore bound to the zone domain (drafts, activeDraft, statusById, reportById + the five
 *  actions; member-for-member the same surface as every other domain store). Geometry gestures write
 *  EXCLUSIVELY through patchDraft. */
export type ZoneDraftsStore = DraftsStore<ZoneDraftPayload, LiveDangerZone, ZoneValidationReport>

/** Build the ONE zone draft store instance (the WorldEditor shell calls this and provides it via
 *  ZoneDraftsContext). `liveZones` is the CURRENT read snapshot's zone list (data.zones — [] while
 *  pirate_intercept_enabled is dark) — used ONLY to re-validate edit drafts (fingerprint
 *  comparison); drafts never flow back into it. */
export function useZoneDraftsStore(liveZones: readonly LiveDangerZone[] | null): ZoneDraftsStore {
  return useDraftsStore(ZONE_DRAFT_DESCRIPTOR, liveZones)
}

const binding = createDraftsContext<ZoneDraftPayload, LiveDangerZone, ZoneValidationReport>(
  'useZoneDrafts must be used inside ZoneDraftsContext.Provider',
)

/** Context the WorldEditor shell provides; ZoneDraftPanel consumes via the hook. */
export const ZoneDraftsContext = binding.Context

export function useZoneDrafts(): ZoneDraftsStore {
  return binding.useStore()
}
