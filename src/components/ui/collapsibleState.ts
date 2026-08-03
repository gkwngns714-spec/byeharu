// Collapsible fold-state persistence — PURE helpers (no React/DOM; the markerStyle/overlayLayout
// pure-policy pattern, pinned by tests/collapsible.spec.ts). The <Collapsible> primitive composes
// these over window.localStorage; specs drive them with an injected reader so nothing here ever
// touches the real storage.
//
// KEY CONVENTION — follows the codebase's one existing client-side persistence
// (firstOrdersDismissKey, src/features/onboarding/firstOrders.ts): a `byeharu.` prefix + a
// versioned namespace. Fold state is pure UI preference (which sections a player keeps open),
// carries no game state and no per-account meaning, so it is deliberately NOT user-scoped — two
// accounts on one browser sharing "I like the reports card folded" is harmless, and scoping would
// force every caller through the auth store for a cosmetic bit.

/** The one localStorage key builder for a persisted fold. `id` is the caller's stable section id
 *  (e.g. 'command.reports'); never a per-row/per-entity id — unbounded ids would grow storage
 *  forever (the reason report ROWS keep session-local state instead of a storageKey). */
export function foldStorageKey(id: string): string {
  return `byeharu.fold.v1:${id}`
}

/** Serialize an open/closed state for storage ('1' open / '0' closed). */
export function foldStateValue(open: boolean): '1' | '0' {
  return open ? '1' : '0'
}

/**
 * Read a persisted fold state through an injected reader (localStorage.getItem-shaped).
 * ONLY the two values this module writes are trusted; absence, garbage, or a throwing reader
 * (private-mode storage) all fall back to `defaultOpen` — a corrupt byte can never wedge a
 * section shut.
 */
export function readFoldState(
  read: (key: string) => string | null,
  id: string,
  defaultOpen: boolean,
): boolean {
  try {
    const raw = read(foldStorageKey(id))
    if (raw === '1') return true
    if (raw === '0') return false
    return defaultOpen
  } catch {
    return defaultOpen
  }
}
