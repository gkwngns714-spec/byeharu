// WORLD EDITOR V1.5 — the PURE request-lifecycle coordinator for the History panel. No React / DOM /
// supabase — a plain immutable state + pure transitions, so the stale-response / pagination / filter-
// reset / retry / disposal rules are unit-testable directly (structural guards are not sufficient
// evidence for these behaviors). It is NOT a data store or state framework: it makes ONE thing —
// "should this response be applied, and how" — a pure decision the panel drives.
import type {
  WorldEditorAuditCursor,
  WorldEditorAuditEntry,
  WorldEditorAuditFailure,
  WorldEditorAuditPage,
} from './worldEditorAuditTypes'
import { mergePageDedup } from './worldEditorAuditView'

export interface AuditRequestState {
  /** Monotonic generation. Bumped ONLY by a fresh initial request (filter change / first load / retry),
   *  so a next-page keeps the same generation and is invalidated the moment filters change. */
  readonly generation: number
  readonly entries: readonly WorldEditorAuditEntry[]
  readonly cursor: WorldEditorAuditCursor | null
  readonly selectedId: string | null
  readonly error: WorldEditorAuditFailure | null
  readonly loadingInitial: boolean
  readonly nextPageInFlight: boolean
  readonly disposed: boolean
}

export function initialAuditRequestState(): AuditRequestState {
  return {
    generation: 0,
    entries: [],
    cursor: null,
    selectedId: null,
    error: null,
    loadingInitial: false,
    nextPageInFlight: false,
    disposed: false,
  }
}

/** A response for `gen` is still current iff the coordinator is not disposed and the generation is unchanged. */
export function isCurrent(s: AuditRequestState, gen: number): boolean {
  return !s.disposed && gen === s.generation
}

/**
 * Begin a fresh INITIAL request (filter change / first load / retry). Bumps the generation and CLEARS the
 * result set, cursor, selection, and error (the filter-reset contract). Returns the new state + the
 * generation token the caller must present with the eventual response.
 */
export function beginInitial(s: AuditRequestState): { state: AuditRequestState; gen: number } {
  const gen = s.generation + 1
  return {
    state: {
      ...s,
      generation: gen,
      entries: [],
      cursor: null,
      selectedId: null,
      error: null,
      loadingInitial: true,
      nextPageInFlight: false,
    },
    gen,
  }
}

/**
 * Begin a NEXT-PAGE request. Does NOT bump the generation (a later filter change invalidates it). Returns
 * null when not allowed — disposed, no cursor, or a next-page is already in flight (prevents a second
 * simultaneous load-more).
 */
export function beginNextPage(s: AuditRequestState): { state: AuditRequestState; gen: number } | null {
  if (s.disposed || s.nextPageInFlight || s.cursor === null) return null
  return { state: { ...s, nextPageInFlight: true }, gen: s.generation }
}

/** Apply a CURRENT initial success: replace entries + cursor, clear error + loading. Stale → unchanged. */
export function applyInitialSuccess(s: AuditRequestState, gen: number, page: WorldEditorAuditPage): AuditRequestState {
  if (!isCurrent(s, gen)) return s
  return { ...s, entries: page.items, cursor: page.nextCursor, error: null, loadingInitial: false }
}

/** Apply a CURRENT next-page success: append (dedup, stable order) + advance cursor, clear in-flight.
 *  Ignored unless a next-page was actually in flight for this generation. Stale → unchanged. */
export function applyNextPageSuccess(s: AuditRequestState, gen: number, page: WorldEditorAuditPage): AuditRequestState {
  if (!isCurrent(s, gen) || !s.nextPageInFlight) return s
  return { ...s, entries: mergePageDedup(s.entries, page.items), cursor: page.nextCursor, nextPageInFlight: false }
}

/** Apply a CURRENT failure: set the controlled error, clear the loading/in-flight flags. A STALE failure
 *  never overwrites current state. */
export function applyFailure(s: AuditRequestState, gen: number, failure: WorldEditorAuditFailure): AuditRequestState {
  if (!isCurrent(s, gen)) return s
  return { ...s, error: failure, loadingInitial: false, nextPageInFlight: false }
}

export function selectEntry(s: AuditRequestState, id: string | null): AuditRequestState {
  return { ...s, selectedId: id }
}

/** Mark the coordinator disposed (panel unmount). Every subsequent response is then rejected by isCurrent. */
export function dispose(s: AuditRequestState): AuditRequestState {
  return { ...s, disposed: true }
}
