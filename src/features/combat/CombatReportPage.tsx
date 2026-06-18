import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { fetchUnitTypes, type UnitType } from '../../lib/catalog'
import { fetchWorldMap } from '../map/mapApi'
import { formatDateTime, formatDuration } from '../../lib/time'
import { fetchCombatReports, fetchTicksForEncounter } from './combatApi'
import { RoundLog } from './RoundLog'
import type { CombatReport, CombatTick } from './combatTypes'

// M6: dedicated combat history page (/reports). Read-only. Lists every battle and,
// on expand, loads that encounter's real combat_ticks into the player-facing RoundLog.
export function CombatReportPage() {
  const [reports, setReports] = useState<CombatReport[]>([])
  const [locNames, setLocNames] = useState<Record<string, string>>({})
  const [unitTypes, setUnitTypes] = useState<UnitType[]>([])
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  const [openId, setOpenId] = useState<string | null>(null)
  const [ticks, setTicks] = useState<CombatTick[]>([])
  const [ticksLoading, setTicksLoading] = useState(false)

  useEffect(() => {
    Promise.all([fetchCombatReports(), fetchWorldMap(), fetchUnitTypes()])
      .then(([reps, world, uts]) => {
        setReports(reps)
        setUnitTypes(uts)
        const names: Record<string, string> = {}
        world.sectors.forEach((s) => s.zones.forEach((z) => z.locations.forEach((l) => { names[l.id] = l.name })))
        setLocNames(names)
      })
      .catch((e: unknown) => setError(e instanceof Error ? e.message : String(e)))
      .finally(() => setLoading(false))
  }, [])

  async function toggle(r: CombatReport) {
    if (openId === r.encounter_id) {
      setOpenId(null)
      setTicks([])
      return
    }
    setOpenId(r.encounter_id)
    setTicks([])
    setTicksLoading(true)
    try {
      setTicks(await fetchTicksForEncounter(r.encounter_id))
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setTicksLoading(false)
    }
  }

  const typeName = (id: string) => unitTypes.find((t) => t.id === id)?.name ?? id
  const ships = (obj: Record<string, number>) => {
    const e = Object.entries(obj ?? {}).filter(([, v]) => v > 0)
    return e.length ? e.map(([k, v]) => `${v} ${typeName(k)}`).join(', ') : 'none'
  }
  const metal = (obj: Record<string, number>) => {
    const m = obj?.metal ?? 0
    return m > 0 ? `${m} metal` : 'none'
  }
  const locName = (id: string | null) => (id && locNames[id]) || 'unknown'

  return (
    <div className="mx-auto max-w-3xl px-4 py-6 sm:px-6 sm:py-10">
      <header className="mb-8 flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight text-indigo-200">Combat reports</h1>
          <p className="text-sm text-white/40">Byeharu — battle history</p>
        </div>
        <Link
          to="/"
          className="rounded-lg border border-white/10 px-3 py-1.5 text-sm text-white/70 transition hover:bg-white/5"
        >
          ← Command center
        </Link>
      </header>

      {loading && <p className="text-white/40">Loading reports…</p>}
      {error && (
        <div className="mb-6 rounded-xl border border-red-500/30 bg-red-500/10 p-4 text-sm text-red-300">{error}</div>
      )}
      {!loading && reports.length === 0 && !error && (
        <p className="text-white/40">No battles fought yet. Send an expedition to a pirate hunt from the Galaxy Map to begin.</p>
      )}

      <ul className="space-y-3">
        {reports.map((r) => {
          const won = r.result === 'escaped' || r.result === 'completed'
          const open = openId === r.encounter_id
          return (
            <li key={r.id} className="rounded-lg border border-white/10 bg-white/5">
              <button
                onClick={() => toggle(r)}
                className="flex w-full items-center justify-between px-4 py-3 text-left"
              >
                <span className="text-sm text-white/80">{locName(r.location_id)}</span>
                <span className={`text-xs font-semibold uppercase ${won ? 'text-emerald-300' : 'text-red-300'}`}>
                  {won ? 'Battle complete' : 'Fleet destroyed'}
                </span>
              </button>

              <div className="border-t border-white/10 px-4 py-3 text-xs text-white/55">
                <div>Reported: <span className="text-white/75">{formatDateTime(r.created_at)}</span></div>
                <div>Waves cleared: {r.waves_cleared} · lasted {formatDuration(r.duration_seconds)}</div>
                {won ? (
                  <>
                    <div>Ships recovered: <span className="text-white/75">{ships(r.survivors_json)}</span></div>
                    <div>Ships lost: <span className="text-white/75">{ships(r.total_losses_json)}</span></div>
                    <div>Rewards: <span className="text-white/75">{metal(r.total_rewards_json)}</span> <span className="text-white/35">(secured on safe return)</span></div>
                  </>
                ) : (
                  <>
                    <div>Ships lost: <span className="text-white/75">{ships(r.total_losses_json)}</span></div>
                    <div className="text-red-300/70">Rewards forfeited — lost with the fleet.</div>
                  </>
                )}

                <button
                  onClick={() => toggle(r)}
                  className="mt-2 text-[11px] uppercase tracking-wide text-indigo-300/80 transition hover:text-indigo-200"
                >
                  {open ? 'Hide round log' : 'Show round log'}
                </button>

                {open && (
                  <div className="mt-2 rounded-lg border border-white/10 bg-black/20 p-3">
                    {ticksLoading ? (
                      <p className="text-white/40">Loading rounds…</p>
                    ) : (
                      <RoundLog ticks={ticks} unitTypes={unitTypes} limit={100} />
                    )}
                  </div>
                )}
              </div>
            </li>
          )
        })}
      </ul>
    </div>
  )
}
