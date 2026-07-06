import { useEffect, useState, type ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { Badge, Button, Card, Notice, PageHeader, buttonClasses } from '../../components/ui'
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
      <PageHeader
        title="Combat reports"
        subtitle="Byeharu — battle history"
        actions={
          <Link to="/" className={buttonClasses('ghost', 'sm')}>
            ← Command center
          </Link>
        }
      />

      {loading && <Notice>Loading reports…</Notice>}
      {error && (
        <Notice tone="danger" className="mb-6">{error}</Notice>
      )}
      {!loading && reports.length === 0 && !error && (
        <Notice>No battles fought yet. Send an expedition to a pirate hunt from the Galaxy Map to begin.</Notice>
      )}

      <ul className="space-y-3">
        {reports.map((r) => {
          const won = r.result === 'escaped' || r.result === 'completed'
          const open = openId === r.encounter_id
          return (
            <li key={r.id}>
              <Card>
                <button
                  onClick={() => toggle(r)}
                  className="flex w-full items-center justify-between gap-3 text-left"
                >
                  <span className="text-sm text-ink">{locName(r.location_id)}</span>
                  <Badge tone={won ? 'success' : 'danger'}>
                    {won ? 'Battle complete' : 'Fleet destroyed'}
                  </Badge>
                </button>

                <div className="mt-3 border-t border-edge pt-3 text-xs text-ink-muted">
                  <Fact label="Reported" value={formatDateTime(r.created_at)} />
                  <div>Waves cleared: {r.waves_cleared} · lasted {formatDuration(r.duration_seconds)}</div>
                  {won ? (
                    <>
                      <Fact label="Ships recovered" value={ships(r.survivors_json)} />
                      <Fact label="Ships lost" value={ships(r.total_losses_json)} />
                      <Fact label="Rewards" value={metal(r.total_rewards_json)} note="secured on safe return" />
                    </>
                  ) : (
                    <>
                      <Fact label="Ships lost" value={ships(r.total_losses_json)} />
                      <div className="text-danger">Rewards forfeited — lost with the fleet.</div>
                    </>
                  )}

                  <Button variant="ghost" size="sm" className="mt-2" onClick={() => toggle(r)}>
                    {open ? 'Hide round log' : 'Show round log'}
                  </Button>

                  {open && (
                    <div className="mt-2 rounded-lg border border-edge bg-surface-2 p-3">
                      {ticksLoading ? (
                        <p className="text-ink-muted">Loading rounds…</p>
                      ) : (
                        <RoundLog ticks={ticks} unitTypes={unitTypes} limit={100} />
                      )}
                    </div>
                  )}
                </div>
              </Card>
            </li>
          )
        })}
      </ul>
    </div>
  )
}

// "Label: value" report-detail line — the ONE chrome for this idiom across the row facts.
function Fact({ label, value, note }: { label: string; value: ReactNode; note?: string }) {
  return (
    <div>
      {label}: <span className="text-ink">{value}</span>
      {note && <span className="text-ink-faint"> ({note})</span>}
    </div>
  )
}
