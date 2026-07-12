import { useState } from 'react'
import { Badge, Button, Card, CardHeader, Notice, Skeleton, StatRow } from '../../components/ui'
import type { UnitType } from '../../lib/catalog'
import type { MapLocation } from '../map/mapTypes'
import { formatDateTime, formatDuration } from '../../lib/time'
import { fetchTicksForEncounter } from './combatApi'
import { RoundLog } from './RoundLog'
import type { CombatReport, CombatTick } from './combatTypes'
import { combatUnitLabel } from './combatLabels'
import { ItemChip } from '../../components/items'

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

  // Slice D4: survivors/losses jsonb keys are coalesce(unit_type_id, main_ship_id::text) since D1 —
  // the ONE combatUnitLabel helper resolves catalog names first and renders uuid-shaped member keys
  // as a "Team ship" label. Data-dark today → legacy report rendering byte-identical.
  const typeName = (id: string) => combatUnitLabel(id, unitTypes)
  const ships = (obj: Record<string, number>) => {
    const e = Object.entries(obj ?? {}).filter(([, v]) => v > 0)
    return e.length ? e.map(([k, v]) => `${v} ${typeName(k)}`).join(', ') : 'none'
  }
  // ITEM-VIZ: every positive reward code as an ItemChip (glyph + humanized name + mono qty).
  // DELIBERATE SUPERSET of the old `metal()` helper, not parity: the old string showed ONLY the
  // metal key ('N metal' / 'none'); this renders ALL positive total_rewards_json codes, and the
  // 'none' gate accordingly changed from metal<=0 to no-positive-code. Identical output today
  // (metal is the only reward code the server writes), but future codes surface instead of hiding.
  const rewardChips = (obj: Record<string, number>) => {
    const e = Object.entries(obj ?? {}).filter(([, v]) => v > 0)
    if (e.length === 0) return 'none'
    return (
      <span className="inline-flex flex-wrap justify-end gap-1">
        {e.map(([code, amt]) => (
          <ItemChip key={code} id={code} kind="resource" qty={amt} />
        ))}
      </span>
    )
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
                  <dl className="space-y-1">
                    <StatRow label="Reported" value={formatDateTime(r.created_at)} />
                    <StatRow label="Waves cleared" value={`${r.waves_cleared} · lasted ${formatDuration(r.duration_seconds)}`} />
                    {won ? (
                      <>
                        <StatRow label="Ships recovered" value={ships(r.survivors_json)} />
                        <StatRow label="Ships lost" value={ships(r.total_losses_json)} />
                        <StatRow label="Rewards" value={rewardChips(r.total_rewards_json)} hint="(secured on safe return)" />
                      </>
                    ) : (
                      <StatRow label="Ships lost" value={ships(r.total_losses_json)} />
                    )}
                  </dl>
                  {!won && <div className="mt-1 text-danger">Rewards forfeited — lost with the fleet.</div>}

                  <Button variant="ghost" size="sm" className="mt-2" onClick={() => toggle(r)}>
                    {open ? 'Hide round log' : 'Show round log'}
                  </Button>

                  {open && (
                    <div className="mt-2 rounded-lg border border-edge bg-surface-2 p-3">
                      {ticksLoading ? (
                        // R3: design-system placeholder instead of bare loading text (same state).
                        <div aria-busy="true">
                          <Skeleton className="h-4 w-2/3" />
                          <Skeleton className="mt-2 h-4 w-1/2" />
                          <span className="sr-only">Loading rounds…</span>
                        </div>
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
