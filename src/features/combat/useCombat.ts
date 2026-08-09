import { useCallback, useEffect, useRef, useState } from 'react'
import {
  fetchActiveEncounters,
  fetchAutoExitByEncounter,
  fetchCombatEvents,
  fetchCombatReports,
  fetchCombatUnits,
  fetchRecentTicks,
  fetchSiteLoot,
  type SiteLootEntry,
} from './combatApi'
import { fetchMyHold } from '../inventory/holdApi'
import type { Hold } from '../inventory/hold'
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
  /** what each fighting fleet is CARRYING, keyed by ENCOUNTER id, exactly as `get_my_hold` (0333)
   *  reports it. The map shell deliberately does not poll the hold; this is fetched ONCE per
   *  encounter because a hold does not change while a fight is running — only the haul does, and the
   *  haul is on the encounter row. Missing key = unread, and the surface then says nothing about
   *  cargo space rather than printing a zero. */
  holds: Record<string, Hold>
  /** what each fighting SITE drops per enemy destroyed (0348), keyed by LOCATION id. Site content is
   *  static, so it is fetched once per location per session. Missing key = unread. */
  siteLoot: Record<string, SiteLootEntry[]>
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
  const [holds, setHolds] = useState<Record<string, Hold>>({})
  const [siteLoot, setSiteLoot] = useState<Record<string, SiteLootEntry[]>>({})
  const inFlight = useRef(false)
  const seq = useRef(0)
  const applied = useRef(0)
  // The two ONCE-PER-KEY reads. They are refs, not state, because they are a record of what has
  // already been ASKED — including keys that came back unreadable, so a failing read is retried by
  // the next mount rather than hammered every 1.5s.
  const askedHold = useRef<Set<string>>(new Set())
  const askedLoot = useRef<Set<string>>(new Set())

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

      // ── THE TWO ONCE-PER-KEY READS ────────────────────────────────────────────────────────────
      // Deliberately AFTER the state above and outside the sequence guard's all-or-nothing set: they
      // are slow-moving facts (a fleet's hold does not change mid-fight; a site's loot table is
      // content), so they must never delay or invalidate a hull bar. Each key is asked at most once
      // per mount, so a fight of any length adds exactly one request per fleet and one per site.
      const holdTargets = encs
        .map((e) => ({
          encounterId: e.id,
          // The PROBE SHIP: get_my_hold is ship-addressed and resolves the FLEET behind it
          // (mainship_resolve_fleet, 0210), so any one of this fight's own player hulls answers for
          // the whole hold. The same idiom useAssetLedger uses — reading per SHIP would double-count.
          shipId: uts.find((u) => u.encounter_id === e.id && u.side === 'player' && u.main_ship_id)
            ?.main_ship_id ?? null,
        }))
        .filter((t) => t.shipId !== null && !askedHold.current.has(t.encounterId))
      for (const t of holdTargets) askedHold.current.add(t.encounterId)
      if (holdTargets.length > 0) {
        const rows = await Promise.all(holdTargets.map((t) => fetchMyHold(t.shipId)))
        setHolds((prev) => {
          const next = { ...prev }
          holdTargets.forEach((t, i) => {
            const h = rows[i]
            // Only a SUCCESSFUL read lands. `ok:false` is "we could not read it", and storing that
            // would let the surface print a 0/0 hold it cannot defend.
            if (h.ok) next[t.encounterId] = h
          })
          return next
        })
      }

      const lootTargets = [
        ...new Set(encs.map((e) => e.location_id).filter((id): id is string => typeof id === 'string')),
      ].filter((id) => !askedLoot.current.has(id))
      for (const id of lootTargets) askedLoot.current.add(id)
      if (lootTargets.length > 0) {
        const rows = await Promise.all(lootTargets.map((id) => fetchSiteLoot(id)))
        setSiteLoot((prev) => {
          const next = { ...prev }
          lootTargets.forEach((id, i) => {
            const r = rows[i]
            // null = unreadable (no 0348 on this server, or a transport error). Leaving the key
            // ABSENT is what makes the surface say nothing, which is different from "drops nothing".
            if (r !== null) next[id] = r
          })
          return next
        })
      }
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

  return { encounters, events, ticks, units, reports, autoExit, holds, siteLoot, refresh }
}
