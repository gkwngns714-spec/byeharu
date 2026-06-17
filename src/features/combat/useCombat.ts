import { useCallback, useEffect, useState } from 'react'
import {
  fetchActiveEncounters,
  fetchCombatEvents,
  fetchCombatReports,
  fetchCombatUnits,
  fetchRecentTicks,
} from './combatApi'
import type { CombatEncounter, CombatEvent, CombatReport, CombatTick, CombatUnit } from './combatTypes'

export interface CombatState {
  encounters: CombatEncounter[]
  events: CombatEvent[]
  ticks: CombatTick[]
  units: CombatUnit[]
  reports: CombatReport[]
  refresh: () => Promise<void>
}

/**
 * Polls combat state faster (~1.5s) than the main dashboard so active battles feel
 * alive. Read-only: encounters/ticks/events/reports come straight from the server.
 */
export function useCombat(pollMs = 1500): CombatState {
  const [encounters, setEncounters] = useState<CombatEncounter[]>([])
  const [events, setEvents] = useState<CombatEvent[]>([])
  const [ticks, setTicks] = useState<CombatTick[]>([])
  const [units, setUnits] = useState<CombatUnit[]>([])
  const [reports, setReports] = useState<CombatReport[]>([])

  const refresh = useCallback(async () => {
    try {
      const encs = await fetchActiveEncounters()
      const ids = encs.map((e) => e.id)
      const [evs, tks, uts, reps] = await Promise.all([
        fetchCombatEvents(ids),
        fetchRecentTicks(ids),
        fetchCombatUnits(ids),
        fetchCombatReports(),
      ])
      setEncounters(encs)
      setEvents(evs)
      setTicks(tks)
      setUnits(uts)
      setReports(reps)
    } catch {
      /* transient read error; next poll retries */
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

  return { encounters, events, ticks, units, reports, refresh }
}
