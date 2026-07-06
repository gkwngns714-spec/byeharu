import { useCallback, useEffect, useRef } from 'react'

// The MarketPanel idiom, extracted — the activity-panel guard scaffold (mounted guard +
// synchronous in-flight submit guard + server-lit fail-closed predicate) that MarketPanel,
// ExplorationPanel, and MiningPanel each carried as a local copy. Extraction is the sanctioned
// "adopt-on-next-real-change" recorded in the MINING-P12 SLICE F DEV_LOG entry. Future activity
// panels (trade/exploration/mining sequels) use this hook instead of re-copying the pattern.
// runGuardedCommand is the guarded command-submit BODY built on these guards — the shared
// claim → pending → exec → note/refresh → finally-release shape every submit handler runs.

/**
 * Mounted guard + synchronous in-flight guard for an activity panel.
 *
 * - `activeRef` — mounted guard: replaces the per-effect `active` flag so a single refresh()
 *   (called on mount AND after a completed command) never sets state after unmount. StrictMode's
 *   mount→cleanup→mount re-arms it correctly (the effect sets `true` again on remount).
 * - `tryClaim(key)` — synchronous in-flight guard. Pending state drives DISABLED buttons, but
 *   state updates async — two clicks in the SAME render tick both read a stale pending=false and
 *   would each mint a DISTINCT request id (which the server, keyed on (main_ship_id, request_id),
 *   would NOT dedup → a real double-submit). The claim mutates a ref synchronously BEFORE any
 *   await, so the second same-tick call bails before firing. Returns false if `key` is already
 *   claimed. The Set-of-string keys serve BOTH granularities: per-row locks (MarketPanel's
 *   good_id) and a single-action lock (a fixed key like 'scan' / 'extract').
 * - `release(key)` — drops the claim; callers invoke it in `finally` so the lock always releases.
 */
export function useActivityPanelGuards() {
  const activeRef = useRef(true)
  useEffect(() => {
    activeRef.current = true
    return () => {
      activeRef.current = false
    }
  }, [])

  const inFlightRef = useRef<Set<string>>(new Set())

  const tryClaim = useCallback((key: string): boolean => {
    if (inFlightRef.current.has(key)) return false
    inFlightRef.current.add(key) // claim synchronously, before any await
    return true
  }, [])

  const release = useCallback((key: string): void => {
    inFlightRef.current.delete(key)
  }, [])

  return { activeRef, tryClaim, release }
}

/**
 * The guarded command-submit body shared by every activity-panel submit handler
 * (ExplorationPanel `scan` · MiningPanel `extract` · ModulesPanel `craft`/`runFitting`) —
 * extracted because the same tryClaim / try-finally / mounted-guard shape lived at four sites.
 * Semantics and ORDER preserved exactly:
 * - bail unless `tryClaim(key)` — the synchronous double-submit guard (two same-tick clicks
 *   would otherwise each mint a DISTINCT request id, which the server would NOT dedup);
 * - pending on, note cleared, then `exec()` runs ONCE per accepted claim — each site mints its
 *   fresh `crypto.randomUUID()` request id inside the thunk, so ids stay fresh per submit;
 * - after the await, the mounted guard (`activeRef`) stops any state write on an unmounted
 *   panel; ok → success note + `refresh()`, else → the site's decorated error note;
 * - `finally` ALWAYS releases the claim; pending clears only while still mounted.
 * Site-specific pieces stay AT the call sites as closures: pre-guards (e.g. `!mainShipId`),
 * boolean vs per-row-Record setters over the fixed/per-row key, and error-copy decoration.
 */
export async function runGuardedCommand<R extends { ok: boolean }>({
  key,
  guards,
  setPending,
  setNote,
  exec,
  successNote,
  errorNote,
  refresh,
}: {
  key: string
  guards: ReturnType<typeof useActivityPanelGuards>
  setPending: (on: boolean) => void
  setNote: (note: string | null) => void
  exec: () => Promise<R>
  successNote: (res: Extract<R, { ok: true }>) => string
  errorNote: (res: Extract<R, { ok: false }>) => string
  refresh: () => Promise<void>
}): Promise<void> {
  const { activeRef, tryClaim, release } = guards
  if (!tryClaim(key)) return
  setPending(true)
  setNote(null)
  try {
    const res = await exec()
    if (!activeRef.current) return
    if (res.ok) {
      // `res.ok` alone cannot narrow the GENERIC R — the Extract casts hand each callback the
      // discriminated member, keeping the isServerLit stance (typed success/error payloads).
      setNote(successNote(res as Extract<R, { ok: true }>))
      await refresh()
    } else {
      setNote(errorNote(res as Extract<R, { ok: false }>))
    }
  } finally {
    release(key)
    if (activeRef.current) setPending(false)
  }
}

/**
 * The shared fail-closed check for SERVER-LIT panels only — surfaces that render NOTHING unless
 * the server affirmatively lit the feature ({ok:true}); the dark envelope and any other failure
 * collapse to null the same way (Exploration/Mining style). Explicitly NOT for MarketPanel's
 * posture (client-flag-mounted shell that stays rendered and shows an unavailable note on a
 * non-ok read) — do not migrate that panel onto this predicate.
 */
export function isServerLit<T extends { ok: boolean }>(
  result: T | null | undefined,
): result is Extract<T, { ok: true }> {
  // Extract<> keeps the discriminated-union narrowing the inline `!result || !result.ok` checks
  // gave callers: after the guard, `result` is the {ok:true} member (discoveries/extractions safe).
  return result != null && result.ok
}
