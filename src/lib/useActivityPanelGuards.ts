import { useCallback, useEffect, useRef } from 'react'

// The MarketPanel idiom, extracted — the activity-panel guard scaffold (mounted guard +
// synchronous in-flight submit guard + server-lit fail-closed predicate) that MarketPanel,
// ExplorationPanel, and MiningPanel each carried as a local copy. Extraction is the sanctioned
// "adopt-on-next-real-change" recorded in the MINING-P12 SLICE F DEV_LOG entry. Future activity
// panels (trade/exploration/mining sequels) use this hook instead of re-copying the pattern.

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
