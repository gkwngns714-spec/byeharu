// WORLD EDITOR — V2A PR-1 GENERIC draft STORE (reducer + context factory). Extracted
// BEHAVIOR-PRESERVING from useLocationDrafts.ts: the exact V1B reducer, localStorage mirror,
// rehydrate-wins merge, and mandatory re-validation logic, parameterized by a DomainDraftDescriptor.
// CLIENT-SIDE ONLY: drafts live in React state mirrored to localStorage (keyed per draftId under the
// descriptor's prefix) and NOWHERE else. This store performs ZERO network IO — no client-server call
// of any kind, no RPC, no live-table write.
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
  type Context,
} from 'react'
import type {
  DomainDraftDescriptor,
  Draft,
  DraftSourceStatus,
} from './draftTypes'
import {
  beginCreate,
  draftSourceStatus,
  forkEdit,
  forkEditWithPayload,
  parseStoredDraft,
  patch,
} from './draftModel'

// ── localStorage persistence (keyed PER DRAFT, versioned prefix — the firstOrdersDismissKey idiom) ──

/** The localStorage key one draft persists under: `${descriptor.storageKeyPrefix}${draftId}`. */
export function draftStorageKey<TPayload, TLive, TReport>(
  descriptor: DomainDraftDescriptor<TPayload, TLive, TReport>,
  draftId: string,
): string {
  return `${descriptor.storageKeyPrefix}${draftId}`
}

/** Scan storage for every draft key under the descriptor's prefix and structurally re-parse each blob
 *  (bad blobs are dropped, never thrown into render). Storage unavailability (private mode etc.)
 *  fails closed to no drafts. */
function loadStoredDrafts<TPayload, TLive, TReport>(
  descriptor: DomainDraftDescriptor<TPayload, TLive, TReport>,
): Draft<TPayload>[] {
  const out: Draft<TPayload>[] = []
  try {
    for (let i = 0; i < window.localStorage.length; i++) {
      const key = window.localStorage.key(i)
      if (!key || !key.startsWith(descriptor.storageKeyPrefix)) continue
      const raw = window.localStorage.getItem(key)
      const parsed = raw ? parseStoredDraft(descriptor, raw) : null
      if (parsed && draftStorageKey(descriptor, parsed.draftId) === key) out.push(parsed)
    }
  } catch {
    // storage unavailable → start with no persisted drafts (drafts still work in-memory)
  }
  out.sort((a, b) => a.createdAt - b.createdAt)
  return out
}

function persistDraft<TPayload, TLive, TReport>(
  descriptor: DomainDraftDescriptor<TPayload, TLive, TReport>,
  draft: Draft<TPayload>,
): void {
  try {
    window.localStorage.setItem(draftStorageKey(descriptor, draft.draftId), JSON.stringify(draft))
  } catch {
    // quota/unavailable → draft stays in-memory for this session; never throws into render
  }
}

function unpersistDraft<TPayload, TLive, TReport>(
  descriptor: DomainDraftDescriptor<TPayload, TLive, TReport>,
  draftId: string,
): void {
  try {
    window.localStorage.removeItem(draftStorageKey(descriptor, draftId))
  } catch {
    // ignore — nothing to remove when storage is unavailable
  }
}

// ── reducer (pure; ids/timestamps are made in the callbacks, never in here) ─────────────────────────
interface DraftsState<TPayload> {
  readonly drafts: readonly Draft<TPayload>[]
  readonly activeDraftId: string | null
}

type DraftsAction<TPayload> =
  | { type: 'rehydrate'; drafts: readonly Draft<TPayload>[] }
  | { type: 'upsert'; draft: Draft<TPayload> }
  | { type: 'discard'; draftId: string }
  | { type: 'select'; draftId: string | null }

function reducer<TPayload>(
  state: DraftsState<TPayload>,
  action: DraftsAction<TPayload>,
): DraftsState<TPayload> {
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
export interface DraftsStore<TPayload, TLive, TReport> {
  readonly drafts: readonly Draft<TPayload>[]
  readonly activeDraft: Draft<TPayload> | null
  /** Per-draft source status vs CURRENT live rows (recomputed every render — never stored). */
  readonly statusById: ReadonlyMap<string, DraftSourceStatus>
  /** Per-draft ADVISORY validation report — recomputed from CURRENT live data + the other local
   *  drafts on every change, never stored. Flag-only: publish stays deferred and disabled. */
  readonly reportById: ReadonlyMap<string, TReport>
  beginCreateDraft(): void
  forkEditDraft(live: TLive): void
  /** Fork an edit draft off `live` AND seed its payload in ONE step, returning the new draftId. The
   *  fork source stays the CURRENT live row (so `expected`/optimistic concurrency is the live row);
   *  only the editable payload is overlaid. The V4 revert flow's ONE net-new primitive — a plain
   *  forkEditDraft+patchDraft can't work here (the new draft is not yet in state for the patch). */
  forkEditWithPayload(live: TLive, payload: Partial<TPayload>): string
  patchDraft(draftId: string, partial: Partial<TPayload>): void
  discardDraft(draftId: string): void
  selectDraft(draftId: string | null): void
}

/** Build the ONE draft store instance for a domain (the shell calls this and provides it via the
 *  domain's context). `live` is the CURRENT read snapshot's rows for this domain — used ONLY to
 *  re-validate edit drafts (fingerprint comparison); drafts never flow back into it. The descriptor
 *  must be a stable module-level constant (it is a binding, not data). */
export function useDraftsStore<TPayload, TLive, TReport>(
  descriptor: DomainDraftDescriptor<TPayload, TLive, TReport>,
  live: readonly TLive[] | null,
  // C1: the domain's server-authoritative overlap radius from the read snapshot (null when the
  // config row is absent) — passed INTO the validation env so the pure validators never fetch.
  overlapRadius: number | null = null,
): DraftsStore<TPayload, TLive, TReport> {
  const [state, dispatch] = useReducer(reducer<TPayload>, {
    drafts: [],
    activeDraftId: null,
  })

  // Mirror for callbacks that need the latest draft without re-binding (patchDraft). Synced in an
  // effect (post-commit) — event handlers fire after commit, so they always read the latest state.
  const stateRef = useRef(state)
  useEffect(() => {
    stateRef.current = state
  }, [state])

  // Rehydrate ONCE on mount; re-validation against live data is continuous via statusById below.
  useEffect(() => {
    const stored = loadStoredDrafts(descriptor)
    if (stored.length > 0) dispatch({ type: 'rehydrate', drafts: stored })
  }, [descriptor])

  const beginCreateDraft = useCallback(() => {
    const draft = beginCreate(descriptor, crypto.randomUUID(), Date.now())
    persistDraft(descriptor, draft)
    dispatch({ type: 'upsert', draft })
  }, [descriptor])

  const forkEditDraft = useCallback(
    (liveRow: TLive) => {
      const draft = forkEdit(descriptor, liveRow, crypto.randomUUID(), Date.now())
      persistDraft(descriptor, draft)
      dispatch({ type: 'upsert', draft })
    },
    [descriptor],
  )

  const forkEditWithPayloadDraft = useCallback(
    (liveRow: TLive, payload: Partial<TPayload>): string => {
      const draftId = crypto.randomUUID()
      const draft = forkEditWithPayload(descriptor, liveRow, payload, draftId, Date.now())
      persistDraft(descriptor, draft)
      dispatch({ type: 'upsert', draft }) // upsert selects it → it becomes the active draft
      return draftId
    },
    [descriptor],
  )

  const patchDraft = useCallback(
    (draftId: string, partial: Partial<TPayload>) => {
      const current = stateRef.current.drafts.find((d) => d.draftId === draftId)
      if (!current) return
      const next = patch(current, partial, Date.now())
      persistDraft(descriptor, next)
      dispatch({ type: 'upsert', draft: next })
    },
    [descriptor],
  )

  const discardDraft = useCallback(
    (draftId: string) => {
      unpersistDraft(descriptor, draftId)
      dispatch({ type: 'discard', draftId })
    },
    [descriptor],
  )

  const selectDraft = useCallback((draftId: string | null) => {
    dispatch({ type: 'select', draftId })
  }, [])

  // MANDATORY re-validation: recompute every edit draft's source status against the CURRENT live
  // rows (fingerprint comparison) — a rehydrated draft surfaces as stale the moment live data says so.
  const statusById = useMemo(() => {
    const liveById = new Map((live ?? []).map((l) => [descriptor.liveId(l), l] as const))
    const m = new Map<string, DraftSourceStatus>()
    for (const d of state.drafts) {
      const liveRow = d.mode.kind === 'edit' ? liveById.get(d.mode.sourceId) : undefined
      m.set(d.draftId, draftSourceStatus(descriptor, d, liveRow))
    }
    return m
  }, [state.drafts, live, descriptor])

  // ADVISORY validation (parallel to statusById; pure + derived, never stored): each draft is
  // validated against the CURRENT live rows, its own recomputed source status, and every OTHER draft.
  const reportById = useMemo(() => {
    const liveRows = live ?? []
    const m = new Map<string, TReport>()
    for (const d of state.drafts) {
      m.set(
        d.draftId,
        descriptor.validate(d, {
          live: liveRows,
          sourceStatus: statusById.get(d.draftId) ?? 'current',
          otherDrafts: state.drafts.filter((o) => o.draftId !== d.draftId),
          overlapRadius,
        }),
      )
    }
    return m
  }, [state.drafts, live, statusById, descriptor, overlapRadius])

  const activeDraft = state.drafts.find((d) => d.draftId === state.activeDraftId) ?? null

  return useMemo(
    () => ({
      drafts: state.drafts,
      activeDraft,
      statusById,
      reportById,
      beginCreateDraft,
      forkEditDraft,
      forkEditWithPayload: forkEditWithPayloadDraft,
      patchDraft,
      discardDraft,
      selectDraft,
    }),
    [state.drafts, activeDraft, statusById, reportById, beginCreateDraft, forkEditDraft, forkEditWithPayloadDraft, patchDraft, discardDraft, selectDraft],
  )
}

// ── context factory (one context + guarded hook per domain) ─────────────────────────────────────────
export interface DraftsContextBinding<TPayload, TLive, TReport> {
  /** The context the domain's shell provides its store instance through. */
  readonly Context: Context<DraftsStore<TPayload, TLive, TReport> | null>
  /** The guarded consumer hook (throws the domain's message outside a Provider). */
  useStore(): DraftsStore<TPayload, TLive, TReport>
}

/** Create ONE domain-bound context + guarded consumer hook pair. `missingProviderMessage` preserves
 *  each domain's exact outside-a-Provider error text. */
export function createDraftsContext<TPayload, TLive, TReport>(
  missingProviderMessage: string,
): DraftsContextBinding<TPayload, TLive, TReport> {
  const DraftsContext = createContext<DraftsStore<TPayload, TLive, TReport> | null>(null)
  const useStore = (): DraftsStore<TPayload, TLive, TReport> => {
    const store = useContext(DraftsContext)
    if (!store) throw new Error(missingProviderMessage)
    return store
  }
  return { Context: DraftsContext, useStore }
}
