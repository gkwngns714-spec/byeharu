// WORLD EDITOR — V5: the PURE unsaved-draft NAVIGATION-GUARD decision authority. Props in → decision
// out. NO React, no DOM, no storage, no network — the markerStyle.ts / worldEditorPendingDrafts.ts
// pure-module idiom, unit-tested directly (tests/worldEditorDraftGuard.spec.ts).
//
// WHY: the four per-domain draft stores hold locally-authored UNPUBLISHED edits; the pending-drafts
// indicator (worldEditorPendingDrafts) shows how much is sitting there but does NOT prevent loss. This
// module is the ONE authority that decides, for any context-changing action, whether that action would
// ABANDON unsaved work and therefore must first prompt the owner — and exactly WHICH draft(s) a
// "Discard and continue" would drop (never any unrelated pending draft).
//
// HONEST DEFINITION OF "AT RISK" (§WE.guard): only a DIRTY draft is unsaved work worth guarding. A draft
// whose payload equals its baseline (a blank create, or an edit patched back to the live values) carries
// nothing to lose — discarding it loses nothing — so it NEVER triggers the guard. Dirtiness is decided
// upstream by the ONE pure predicate draftModel.isDirty; this module reasons only over the resulting
// dirty-draft ids, so it stays domain-blind and trivially testable.
import type { WorldEditorErrorCode } from './commandContract'
import { PENDING_DRAFT_DOMAINS, type PendingDraftDomain } from './worldEditorPendingDrafts'

/** A reference to one specific DIRTY draft a guarded action would abandon — the exact (domain, draftId)
 *  a "Discard and continue" drops. */
export interface AffectedDraft {
  readonly domain: PendingDraftDomain
  readonly draftId: string
}

/** Per-domain lists of the draftIds that are currently DIRTY (payload ≠ baseline). The hook computes
 *  these from each store's `drafts` via the domain descriptor's isDirty; the pure layer only reasons
 *  over the ids (every domain key ALWAYS present, [] when clean — so it can be indexed without a
 *  fallback). */
export type DirtyDraftsByDomain = Record<PendingDraftDomain, readonly string[]>

/** The context-changing actions the guard protects. Each names an owner intent that would move away
 *  from — or tear down — the current authoring context:
 *    • select-entity  — pick another entity from the map (or deselect);
 *    • search-jump     — pick a search result (WorldEditorSearchBox);
 *    • camera-jump     — coordinate-jump selection (WorldEditorGotoBox);
 *    • switch-domain   — switch the authoring-domain tabs;
 *    • change-filter   — change the lifecycle filter WHEN it hides the selection;
 *    • open-history    — open another History record;
 *    • revert          — invoke a History revert;
 *    • unpublish       — unpublish a live zone;
 *    • reactivate      — reactivate an inactive entity;
 *    • leave-route     — leave /dev/world (route change);
 *    • before-unload   — browser refresh / close.
 *  A domain switch endangers the domain being LEFT, which is exactly the active authoring domain, so
 *  every SCOPED action shares one rule (active-domain drafts). leave-route / before-unload tear down the
 *  WHOLE surface, so they endanger EVERY domain's dirty work. */
export type GuardedActionKind =
  | 'select-entity'
  | 'search-jump'
  | 'camera-jump'
  | 'switch-domain'
  | 'change-filter'
  | 'open-history'
  | 'revert'
  | 'unpublish'
  | 'reactivate'
  | 'leave-route'
  | 'before-unload'

/** The two actions that tear down the whole editor surface (page leave) rather than just changing the
 *  in-page context — they endanger EVERY domain's unsaved work, not only the active domain's. */
const WHOLE_SURFACE_ACTIONS: ReadonlySet<GuardedActionKind> = new Set<GuardedActionKind>([
  'leave-route',
  'before-unload',
])

/** All dirty drafts across EVERY domain, in registry order — the affected set for a whole-surface leave. */
export function allDirtyDrafts(dirty: DirtyDraftsByDomain): AffectedDraft[] {
  return PENDING_DRAFT_DOMAINS.flatMap((domain) =>
    dirty[domain].map((draftId) => ({ domain, draftId })),
  )
}

/** The dirty drafts a specific action would abandon — the EXACT set a "Discard and continue" drops.
 *  A whole-surface leave (leave-route / before-unload) endangers every domain's dirty work; every other
 *  action endangers only the ACTIVE authoring domain's dirty drafts (switching a tab leaves the active
 *  domain; selecting/jumping/reverting/etc. all happen while the active domain's panel is on screen).
 *  Never returns a draft from an unrelated domain, and never a clean one (dirty ids only). */
export function draftsAbandonedBy(
  kind: GuardedActionKind,
  activeDomain: PendingDraftDomain,
  dirty: DirtyDraftsByDomain,
): AffectedDraft[] {
  if (WHOLE_SURFACE_ACTIONS.has(kind)) return allDirtyDrafts(dirty)
  return dirty[activeDomain].map((draftId) => ({ domain: activeDomain, draftId }))
}

/** The ONE guard decision: does this action need a confirm dialog first? True iff it would abandon at
 *  least one DIRTY draft. A CLEAN authoring context (no dirty draft in the endangered scope) proceeds
 *  WITHOUT a dialog. */
export function actionNeedsConfirm(
  kind: GuardedActionKind,
  activeDomain: PendingDraftDomain,
  dirty: DirtyDraftsByDomain,
): boolean {
  return draftsAbandonedBy(kind, activeDomain, dirty).length > 0
}

/** The browser `beforeunload` decision, isolated for the native handler: warn (block the unload) iff
 *  ANY domain holds a dirty draft. Refresh/close tears the whole surface down, so it is scoped to every
 *  domain — never just the active one. Clean everywhere → let the unload proceed silently. */
export function beforeUnloadShouldWarn(dirty: DirtyDraftsByDomain): boolean {
  return allDirtyDrafts(dirty).length > 0
}

/** OPTIMISTIC-CONCURRENCY / LIVE-DRIFT conflict codes for a publish / reactivate / revert command: the
 *  live entity changed under the attempt, so the client must NOT auto-overwrite or rebase — it retains
 *  the local draft AND the attempted values and offers an EXPLICIT "Reload live version". These are the
 *  four codes that mean "the live row moved / is gone", as opposed to a plain validation or auth error:
 *    • stale_revision — the live row drifted from the draft's fork-time `expected` snapshot;
 *    • conflict       — a unique natural key is now taken in the live world;
 *    • source_missing — the live row a revert would overwrite no longer exists;
 *    • not_found      — the update target no longer exists.
 *  Pure predicate — the ONE authority the conflict-notice UI consults, so no component re-lists codes. */
export function isLiveConflict(error: WorldEditorErrorCode): boolean {
  return (
    error === 'stale_revision' ||
    error === 'conflict' ||
    error === 'source_missing' ||
    error === 'not_found'
  )
}
