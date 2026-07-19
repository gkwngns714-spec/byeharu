// WORLD EDITOR — V1B-1 location-draft STORE (reducer + context hook). CLIENT-SIDE ONLY: drafts live
// in React state mirrored to localStorage (keyed per draftId) and NOWHERE else. This store performs
// ZERO network IO — no client-server call of any kind, no RPC, no live-table write (guarded by
// tests/locationDraftGuards.spec.ts).
//
// STRUCTURAL LAW: this store is a SEPARATE structure from the read snapshot. Drafts must NEVER be
// merged into WorldEditorData (worldEditorData.ts stays draft-free — pinned by the read-snapshot
// integrity test); the shell composes "live items + draft preview" at RENDER time only.
//
// REHYDRATION LAW: a stored draft is never trusted as fresh. On rehydrate every blob is structurally
// re-parsed (parseStoredDraft drops garbage), and every edit draft is MANDATORILY re-validated against
// the CURRENT live rows — `statusById` recomputes each draft's fingerprint-based source status
// (current / source_changed / source_missing) from live data on every render, never from storage.
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useReducer,
  useRef,
} from 'react'
import type { MapLocation } from '../map/mapTypes'
import type {
  DraftSourceStatus,
  LocationDraft,
  LocationDraftPayload,
} from './locationDraftTypes'
import {
  beginCreate,
  draftSourceStatus,
  forkEdit,
  parseStoredDraft,
  patch,
} from './locationDraftModel'
import { validateLocationDraft, type ValidationReport } from './locationValidation'

// ── localStorage persistence (keyed PER DRAFT, versioned — the firstOrdersDismissKey idiom) ─────────
const KEY_PREFIX = 'byeharu.worldEditor.locationDraft.v1:'

/** The localStorage key one draft persists under. */
export function draftStorageKey(draftId: string): string {
  return `${KEY_PREFIX}${draftId}`
}

/** Scan storage for every draft key and structurally re-parse each blob (bad blobs are dropped, never
 *  thrown into render). Storage unavailability (private mode etc.) fails closed to no drafts. */
function loadStoredDrafts(): LocationDraft[] {
  const out: LocationDraft[] = []
  try {
    for (let i = 0; i < window.localStorage.length; i++) {
      const key = window.localStorage.key(i)
      if (!key || !key.startsWith(KEY_PREFIX)) continue
      const raw = window.localStorage.getItem(key)
      const parsed = raw ? parseStoredDraft(raw) : null
      if (parsed && draftStorageKey(parsed.draftId) === key) out.push(parsed)
    }
  } catch {
    // storage unavailable → start with no persisted drafts (drafts still work in-memory)
  }
  out.sort((a, b) => a.createdAt - b.createdAt)
  return out
}

function persistDraft(draft: LocationDraft): void {
  try {
    window.localStorage.setItem(draftStorageKey(draft.draftId), JSON.stringify(draft))
  } catch {
    // quota/unavailable → draft stays in-memory for this session; never throws into render
  }
}

function unpersistDraft(draftId: string): void {
  try {
    window.localStorage.removeItem(draftStorageKey(draftId))
  } catch {
    // ignore — nothing to remove when storage is unavailable
  }
}

// ── reducer (pure; ids/timestamps are made in the callbacks, never in here) ─────────────────────────
interface LocationDraftsState {
  readonly drafts: readonly LocationDraft[]
  readonly activeDraftId: string | null
}

type LocationDraftsAction =
  | { type: 'rehydrate'; drafts: readonly LocationDraft[] }
  | { type: 'upsert'; draft: LocationDraft }
  | { type: 'discard'; draftId: string }
  | { type: 'select'; draftId: string | null }

const EMPTY_STATE: LocationDraftsState = { drafts: [], activeDraftId: null }

function reducer(state: LocationDraftsState, action: LocationDraftsAction): LocationDraftsState {
  switch (action.type) {
    case 'rehydrate': {
      // In-memory drafts (created before rehydration landed) win over stored ones by draftId.
      const liveIds = new Set(state.drafts.map((d) => d.draftId))
      const restored = action.drafts.filter((d) => !liveIds.has(d.draftId))
      return { ...state, drafts: [...restored, ...state.drafts] }
    }
    case 'upsert': {
      const exists = state.drafts.some((d) => d.draftId === action.draft.draftId)
      const drafts = exists
        ? state.drafts.map((d) => (d.draftId === action.draft.draftId ? action.draft : d))
        : [...state.drafts, action.draft]
      return { drafts, activeDraftId: action.draft.draftId }
    }
    case 'discard':
      return {
        drafts: state.drafts.filter((d) => d.draftId !== action.draftId),
        activeDraftId: state.activeDraftId === action.draftId ? null : state.activeDraftId,
      }
    case 'select':
      return { ...state, activeDraftId: action.draftId }
  }
}

// ── the store surface the shell provides and the panel/preview consume ──────────────────────────────
export interface LocationDraftsStore {
  readonly drafts: readonly LocationDraft[]
  readonly activeDraft: LocationDraft | null
  /** Per-draft source status vs CURRENT live rows (recomputed every render — never stored). */
  readonly statusById: ReadonlyMap<string, DraftSourceStatus>
  /** Per-draft ADVISORY validation report (V1B-2) — recomputed from CURRENT live data + the other
   *  local drafts on every change, never stored. Flag-only: publish stays deferred and disabled. */
  readonly reportById: ReadonlyMap<string, ValidationReport>
  beginCreateDraft(): void
  forkEditDraft(loc: MapLocation): void
  patchDraft(draftId: string, partial: Partial<LocationDraftPayload>): void
  discardDraft(draftId: string): void
  selectDraft(draftId: string | null): void
}

/** Build the ONE draft store instance (the WorldEditor shell calls this and provides it via
 *  LocationDraftsContext). `liveLocations` is the CURRENT read snapshot's location list — used ONLY
 *  to re-validate edit drafts (fingerprint comparison); drafts never flow back into it. */
export function useLocationDraftsStore(
  liveLocations: readonly MapLocation[] | null,
): LocationDraftsStore {
  const [state, dispatch] = useReducer(reducer, EMPTY_STATE)

  // Mirror for callbacks that need the latest draft without re-binding (patchDraft). Synced in an
  // effect (post-commit) — event handlers fire after commit, so they always read the latest state.
  const stateRef = useRef(state)
  useEffect(() => {
    stateRef.current = state
  }, [state])

  // Rehydrate ONCE on mount; re-validation against live data is continuous via statusById below.
  useEffect(() => {
    const stored = loadStoredDrafts()
    if (stored.length > 0) dispatch({ type: 'rehydrate', drafts: stored })
  }, [])

  const beginCreateDraft = useCallback(() => {
    const draft = beginCreate(crypto.randomUUID(), Date.now())
    persistDraft(draft)
    dispatch({ type: 'upsert', draft })
  }, [])

  const forkEditDraft = useCallback((loc: MapLocation) => {
    const draft = forkEdit(loc, crypto.randomUUID(), Date.now())
    persistDraft(draft)
    dispatch({ type: 'upsert', draft })
  }, [])

  const patchDraft = useCallback((draftId: string, partial: Partial<LocationDraftPayload>) => {
    const current = stateRef.current.drafts.find((d) => d.draftId === draftId)
    if (!current) return
    const next = patch(current, partial, Date.now())
    persistDraft(next)
    dispatch({ type: 'upsert', draft: next })
  }, [])

  const discardDraft = useCallback((draftId: string) => {
    unpersistDraft(draftId)
    dispatch({ type: 'discard', draftId })
  }, [])

  const selectDraft = useCallback((draftId: string | null) => {
    dispatch({ type: 'select', draftId })
  }, [])

  // MANDATORY re-validation: recompute every edit draft's source status against the CURRENT live
  // rows (fingerprint comparison) — a rehydrated draft surfaces as stale the moment live data says so.
  const statusById = useMemo(() => {
    const liveById = new Map((liveLocations ?? []).map((l) => [l.id, l] as const))
    const m = new Map<string, DraftSourceStatus>()
    for (const d of state.drafts) {
      const live = d.mode.kind === 'edit' ? liveById.get(d.mode.sourceId) : undefined
      m.set(d.draftId, draftSourceStatus(d, live))
    }
    return m
  }, [state.drafts, liveLocations])

  // V1B-2 ADVISORY validation (parallel to statusById; pure + derived, never stored): each draft is
  // validated against the CURRENT live rows, its own recomputed source status, and every OTHER draft.
  const reportById = useMemo(() => {
    const live = liveLocations ?? []
    const m = new Map<string, ValidationReport>()
    for (const d of state.drafts) {
      m.set(
        d.draftId,
        validateLocationDraft(d.payload, {
          liveLocations: live,
          sourceStatus: statusById.get(d.draftId) ?? 'current',
          draftMode: d.mode,
          otherDrafts: state.drafts.filter((o) => o.draftId !== d.draftId),
        }),
      )
    }
    return m
  }, [state.drafts, liveLocations, statusById])

  const activeDraft = state.drafts.find((d) => d.draftId === state.activeDraftId) ?? null

  return useMemo(
    () => ({
      drafts: state.drafts,
      activeDraft,
      statusById,
      reportById,
      beginCreateDraft,
      forkEditDraft,
      patchDraft,
      discardDraft,
      selectDraft,
    }),
    [state.drafts, activeDraft, statusById, reportById, beginCreateDraft, forkEditDraft, patchDraft, discardDraft, selectDraft],
  )
}

/** Context the WorldEditor shell provides; LocationDraftPanel / DraftPreview consume via the hook. */
export const LocationDraftsContext = createContext<LocationDraftsStore | null>(null)

export function useLocationDrafts(): LocationDraftsStore {
  const store = useContext(LocationDraftsContext)
  if (!store) throw new Error('useLocationDrafts must be used inside LocationDraftsContext.Provider')
  return store
}
