import { useState, type ReactNode } from 'react'
import { Badge, Button, Card, CardHeader, Notice } from '../../components/ui'
import type { UnitType } from '../../lib/catalog'
import type { MapLocation } from '../map/mapTypes'
import { formatDateTime, formatDuration } from '../../lib/time'
import { fetchTicksForEncounter } from './combatApi'
import { RoundLog } from './RoundLog'
import type { CombatReport, CombatTick } from './combatTypes'

// UI-REBUILD (2b) — the ONE combat-reports surface, mounted in the Command destination. Merges the
// old /reports page (CombatReportPage) and the inline dashboard list (CombatReportsView): the M6
// report list + on-expand real combat_ticks RoundLog, presented as a section. Reports/locations/
// unit types come from the shell's already-polled state (no own polling); only the expanded
// encounter's ticks are fetched on demand, exactly as the old page did.

export function ReportsSection({
  reports,
  locations,
  unitTypes,
}: {
  reports: CombatReport[]
  locations: MapLocation[]
  unitTypes: UnitType[]
}) {
  const [error, setError] = useState<string | null>(null)
  const [openId, setOpenId] = useState<string | null>(null)
  const [ticks, setTicks] = useState<CombatTick[]>([])
  const [ticksLoading, setTicksLoading] = useState(false)

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
  const locName = (id: string | null) =>
    (id && locations.find((l) => l.id === id)?.name) || 'unknown'

  return (
    <section data-testid="combat-reports-section">
      <Card>
        <CardHeader title="Combat reports" subtitle="Battle history" className="mb-2" />
        {error && (
          <Notice tone="danger" className="mb-3">{error}</Notice>
        )}
        {reports.length === 0 && !error && (
          <p className="text-sm text-ink-muted">No battles fought yet.</p>
        )}

        <ul className="space-y-3">
          {reports.map((r) => {
            const won = r.result === 'escaped' || r.result === 'completed'
            const open = openId === r.encounter_id
            return (
              <li key={r.id} className="rounded-lg border border-edge bg-surface-2/50 p-3">
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
              </li>
            )
          })}
        </ul>
      </Card>
    </section>
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
