import { useCallback, useEffect, useRef, useState } from 'react'
import {
  fetchActiveEncounters,
  fetchAutoExitByEncounter,
  fetchCombatEvents,
  fetchCombatReports,
  fetchCombatUnits,
  fetchRecentTicks,
} from './combatApi'
import type { AutoExitSetting } from './autoExitLine'
import type { CombatEncounter, CombatEvent, CombatReport, CombatTick, CombatUnit } from './combatTypes'

export interface CombatState {
  encounters: CombatEncounter[]
  events: CombatEvent[]
  ticks: CombatTick[]
  units: CombatUnit[]
  reports: CombatReport[]
  /** the 0310 auto-retreat setting keyed by ENCOUNTER id; {} while nothing is fighting, and {} on a
   *  failed/pre-0310 read — surfaces must say nothing about the line rather than deny it. */
  autoExit: Record<string, AutoExitSetting>
  refresh: () => Promise<void>
}

/**
 * Polls combat state faster (~1.5s) than the main dashboard so active battles feel alive.
 * Read-only: encounters/ticks/events/reports come straight from the server.
 *
 * ── ONE REFRESH AT A TIME, AND ONLY THE NEWEST ONE WINS ────────────────────────────────────────────
 * The poll had no in-flight guard and no sequence token. Six requests go out per cycle; the interval
 * fires every 1.5s regardless of whether the previous cycle has come back. On a slow connection —
 * exactly the case where a mid-fight readout matters — cycle N could resolve AFTER cycle N+1 and
 * overwrite fresher rows with older ones, so hull bars jumped backwards, dead ships reappeared and
 * splats replayed a tick that had already passed. Two mechanisms, both needed:
 *   · `inFlight` stops a new cycle starting while one is still out (the fix for pile-up);
 *   · `seq` stamps each cycle and a late reply whose stamp is not the newest one is DROPPED before
 *     it can call setState (the fix for out-of-order, which the guard alone cannot give — an
 *     explicit `refresh()` from a retreat press legitimately races the interval).
 * A dropped reply costs nothing: the next cycle is at most 1.5s away and carries the same rows.
 */
export function useCombat(pollMs = 1500): CombatState {
  const [encounters, setEncounters] = useState<CombatEncounter[]>([])
  const [events, setEvents] = useState<CombatEvent[]>([])
  const [ticks, setTicks] = useState<CombatTick[]>([])
  const [units, setUnits] = useState<CombatUnit[]>([])
  const [reports, setReports] = useState<CombatReport[]>([])
  const [autoExit, setAutoExit] = useState<Record<string, AutoExitSetting>>({})
  const inFlight = useRef(false)
  const seq = useRef(0)
  const applied = useRef(0)

  const refresh = useCallback(async () => {
    if (inFlight.current) return // a cycle is already out; the next tick will pick up its result
    inFlight.current = true
    const mine = ++seq.current
    try {
      const encs = await fetchActiveEncounters()
      const ids = encs.map((e) => e.id)
      const [evs, tks, uts, reps, ae] = await Promise.all([
        fetchCombatEvents(ids),
        fetchRecentTicks(ids),
        fetchCombatUnits(ids),
        fetchCombatReports(),
        // Only while something is fighting — a quiet map makes no extra request.
        encs.length > 0 ? fetchAutoExitByEncounter(encs) : Promise.resolve({}),
      ])
      // A reply older than one already applied is stale by definition — drop it whole rather than
      // let a subset of the six arrays regress.
      if (mine <= applied.current) return
      applied.current = mine
      setEncounters(encs)
      setEvents(evs)
      setTicks(tks)
      setUnits(uts)
      setReports(reps)
      setAutoExit(ae)
    } catch {
      /* transient read error; next poll retries */
    } finally {
      inFlight.current = false
    }
  }, [])

  useEffect(() => {
    let active = true
    // Initial fetch wrapped in an async IIFE so the effect body doesn't call
    // setState synchronously (satisfies react-hooks/set-state-in-effect). Same
    // poll-on-mount behavior as before; mirrors useGameState's pattern.
    ;(async () => {
      await refresh()
    })()
    const iv = setInterval(() => {
      if (active) void refresh()
    }, pollMs)
    return () => {
      active = false
      clearInterval(iv)
    }
  }, [refresh, pollMs])

  return { encounters, events, ticks, units, reports, autoExit, refresh }
}
