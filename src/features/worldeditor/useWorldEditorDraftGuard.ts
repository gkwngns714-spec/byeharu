// WORLD EDITOR — V5: the unsaved-draft NAVIGATION-GUARD hook + its context. This is the ONE shared
// guard the whole editor routes context-changing actions through: it COMPOSES the four already-mounted
// per-domain draft stores (it adds NO store, NO persistence, NO autosave), derives which drafts are
// DIRTY (via the ONE pure predicate draftModel.isDirty + each domain descriptor), and — for any guarded
// action — either runs it immediately (clean context) or defers it behind the confirm dialog
// (PendingDraftsDialog) when it would abandon unsaved work.
//
// The pure DECISION (which actions abandon which drafts, and the beforeunload warn rule) lives in
// worldEditorDraftGuard.ts and is unit-tested there; this hook is the thin React binding (dialog state,
// the discard-then-run wiring, and the native `beforeunload` listener). NO network IO, NO live-table
// write — discarding an affected draft is the SAME store.discardDraft the panels already call, scoped to
// exactly the abandoned draft(s) so no unrelated pending draft is ever touched.
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react'
import { isDirty } from './draftModel'
import { LOCATION_DRAFT_DESCRIPTOR } from './locationDraftModel'
import { MINING_DRAFT_DESCRIPTOR } from './miningDraftModel'
import { EXPLORATION_DRAFT_DESCRIPTOR } from './explorationDraftModel'
import { ZONE_DRAFT_DESCRIPTOR } from './zoneDraftModel'
import type { LocationDraftsStore } from './useLocationDrafts'
import type { MiningDraftsStore } from './useMiningDrafts'
import type { ExplorationDraftsStore } from './useExplorationDrafts'
import type { ZoneDraftsStore } from './useZoneDrafts'
import type { PendingDraftDomain } from './worldEditorPendingDrafts'
import {
  beforeUnloadShouldWarn,
  draftsAbandonedBy,
  type AffectedDraft,
  type DirtyDraftsByDomain,
  type GuardedActionKind,
} from './worldEditorDraftGuard'

/** The four already-mounted domain stores the guard composes (never a new store — it reads the SAME
 *  ones the panels/previews render). */
export interface DraftGuardStores {
  readonly locations: LocationDraftsStore
  readonly mining: MiningDraftsStore
  readonly exploration: ExplorationDraftsStore
  readonly zones: ZoneDraftsStore
}

/** A pending confirm request the dialog renders: the action that was intercepted + the exact dirty
 *  drafts a "Discard and continue" would drop. `run` is the deferred original action. */
export interface PendingGuardRequest {
  readonly kind: GuardedActionKind
  readonly affected: readonly AffectedDraft[]
  readonly run: () => void
}

/** The guard surface the shell provides and every context-changing call site consumes. */
export interface DraftGuard {
  /** Route a context-changing action through the guard: run it NOW when the endangered context is clean,
   *  otherwise open the confirm dialog and defer it. `kind` selects the endangered scope (active domain
   *  for in-page changes; every domain for a whole-surface leave). */
  requestAction(kind: GuardedActionKind, action: () => void): void
  /** The open confirm request (drives PendingDraftsDialog); null when no dialog is open. */
  readonly pending: PendingGuardRequest | null
  /** "Keep editing" — cancel the intercepted action; selection, camera and every draft are preserved. */
  keepEditing(): void
  /** "Discard and continue" — discard ONLY the affected draft(s), then perform the original action. */
  discardAndContinue(): void
}

/** Derive the per-domain DIRTY-draft id lists from the live stores via the ONE isDirty predicate. A
 *  clean create (blank) or an edit patched back to its source is NOT dirty and never guards. */
function dirtyDraftsByDomain(stores: DraftGuardStores): DirtyDraftsByDomain {
  return {
    locations: stores.locations.drafts
      .filter((d) => isDirty(LOCATION_DRAFT_DESCRIPTOR, d))
      .map((d) => d.draftId),
    mining: stores.mining.drafts
      .filter((d) => isDirty(MINING_DRAFT_DESCRIPTOR, d))
      .map((d) => d.draftId),
    exploration: stores.exploration.drafts
      .filter((d) => isDirty(EXPLORATION_DRAFT_DESCRIPTOR, d))
      .map((d) => d.draftId),
    zones: stores.zones.drafts
      .filter((d) => isDirty(ZONE_DRAFT_DESCRIPTOR, d))
      .map((d) => d.draftId),
  }
}

/** Build the ONE draft guard for the editor. `activeDomain` is the authoring domain whose panel is on
 *  screen (the endangered scope for every in-page action). */
export function useWorldEditorDraftGuard(
  stores: DraftGuardStores,
  activeDomain: PendingDraftDomain,
): DraftGuard {
  const [pending, setPending] = useState<PendingGuardRequest | null>(null)

  const dirty = useMemo(
    () => dirtyDraftsByDomain(stores),
    [stores.locations.drafts, stores.mining.drafts, stores.exploration.drafts, stores.zones.drafts],
  )

  // Refs so the guard callbacks keep a STABLE identity (no re-wrap per keystroke) while always reading
  // the latest dirty set / active domain / pending request.
  const dirtyRef = useRef(dirty)
  dirtyRef.current = dirty
  const activeDomainRef = useRef(activeDomain)
  activeDomainRef.current = activeDomain
  const pendingRef = useRef(pending)
  pendingRef.current = pending

  // Per-domain discard binding — the SAME store.discardDraft the panels use, so a discard removes ONLY
  // the abandoned draft and never touches an unrelated pending draft in another store.
  const discardByDomain = useRef<Record<PendingDraftDomain, (draftId: string) => void>>({
    locations: () => {},
    mining: () => {},
    exploration: () => {},
    zones: () => {},
  })
  discardByDomain.current = {
    locations: stores.locations.discardDraft,
    mining: stores.mining.discardDraft,
    exploration: stores.exploration.discardDraft,
    zones: stores.zones.discardDraft,
  }

  const requestAction = useCallback((kind: GuardedActionKind, action: () => void) => {
    const affected = draftsAbandonedBy(kind, activeDomainRef.current, dirtyRef.current)
    if (affected.length === 0) {
      action() // clean context — no dialog, run immediately
      return
    }
    setPending({ kind, affected, run: action })
  }, [])

  const keepEditing = useCallback(() => setPending(null), [])

  const discardAndContinue = useCallback(() => {
    const req = pendingRef.current
    if (!req) return
    for (const a of req.affected) discardByDomain.current[a.domain](a.draftId)
    setPending(null)
    req.run()
  }, [])

  // Native browser refresh/close guard: warn (block the unload) iff ANY domain holds a dirty draft. The
  // decision is the pure beforeUnloadShouldWarn; the ref keeps this listener bound once for the surface's
  // lifetime while always reading the latest dirty set.
  useEffect(() => {
    const handler = (e: BeforeUnloadEvent) => {
      if (beforeUnloadShouldWarn(dirtyRef.current)) {
        e.preventDefault()
        // legacy Chrome/Firefox require returnValue to be set for the native prompt to show
        e.returnValue = ''
      }
    }
    window.addEventListener('beforeunload', handler)
    return () => window.removeEventListener('beforeunload', handler)
  }, [])

  // SPA route-leave guard (back/forward away from /dev/world — the ONLY same-document leave beforeunload
  // can't catch). It is ARMED ONLY while unsaved work exists (warnOnLeave), so a clean back press is never
  // intercepted: on the false→true edge it pushes ONE history sentinel; a subsequent back press pops that
  // sentinel, firing popstate, which we undo (re-push, so the surface stays put) and route through the
  // confirm dialog. "Discard and continue" then performs the real back navigation (history.go(-1)); by
  // then the drafts are discarded so the follow-up popstate is no longer intercepted. NEVER touches a
  // draft on its own — the leave is decided entirely by the owner's dialog choice.
  const warnOnLeave = beforeUnloadShouldWarn(dirty)
  useEffect(() => {
    if (!warnOnLeave) return
    window.history.pushState(null, document.title, window.location.href)
    const onPop = () => {
      if (!beforeUnloadShouldWarn(dirtyRef.current)) return // clean now → let the navigation proceed
      window.history.pushState(null, document.title, window.location.href) // undo the pop: stay put
      requestAction('leave-route', () => window.history.go(-1))
    }
    window.addEventListener('popstate', onPop)
    return () => window.removeEventListener('popstate', onPop)
  }, [warnOnLeave, requestAction])

  return useMemo(
    () => ({ requestAction, pending, keepEditing, discardAndContinue }),
    [requestAction, pending, keepEditing, discardAndContinue],
  )
}

// ── context: one guard instance provided by the shell, consumed by every descendant call site ─────────
const DraftGuardContext = createContext<DraftGuard | null>(null)

/** Provider value the shell wraps the editor tree with (set to the useWorldEditorDraftGuard result). */
export const WorldEditorDraftGuardContext = DraftGuardContext

/** Consume the shared guard from a descendant call site (SearchBox / History detail / inspectors).
 *  Throws outside the provider so a mis-wired call site fails loudly, never silently unguarded. */
export function useDraftGuard(): DraftGuard {
  const guard = useContext(DraftGuardContext)
  if (!guard) throw new Error('useDraftGuard must be used inside WorldEditorDraftGuardContext.Provider')
  return guard
}
