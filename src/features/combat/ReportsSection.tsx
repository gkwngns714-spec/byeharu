import { useState } from 'react'
import { Badge, Collapsible, CollapsibleCard, Notice, Skeleton, StatRow } from '../../components/ui'
import type { UnitType } from '../../lib/catalog'
import type { MapLocation } from '../map/mapTypes'
import { formatDateTime, formatDuration } from '../../lib/time'
import { fetchTicksForEncounter } from './combatApi'
import { RoundLog } from './RoundLog'
import type { CombatReport, CombatTick } from './combatTypes'
import { combatUnitLabel } from './combatLabels'
import { ItemChip } from '../../components/items'
import { newestReportId, reportRowOpen } from './reportFold'

// UI-REBUILD (2b) — the ONE combat-reports surface, mounted in the Command destination. Merges the
// old /reports page (CombatReportPage) and the inline dashboard list (CombatReportsView): the M6
// report list + on-expand real combat_ticks RoundLog, presented as a section. Reports/locations/
// unit types come from the shell's already-polled state (no own polling); only the expanded
// encounter's ticks are fetched on demand, exactly as the old page did.
//
// FOLDABLE (owner order 2026-08-03: "combat report, mission report, … separate them and make it
// foldable") — three fold layers, ALL through the one design-system Collapsible (never a
// hand-rolled show/hide):
//   · the SECTION — CollapsibleCard, persisted under storageKey 'command.reports' (default open:
//     a fresh report should be visible without a tap; the player's choice is remembered).
//   · each REPORT row — controlled Collapsible; the newest report defaults open, older ones
//     collapsed (reportFold.ts carries the policy + why row state is session-local, not stored).
//     The old layout rendered EVERY report fully expanded, which is the run-together wall the
//     owner called out.
//   · the ROUND LOG — controlled Collapsible whose opening triggers the on-demand tick fetch
//     (the one fold that is also a fetch trigger, so its state stays with the fetch bookkeeping).
//
// HONESTY NOTE — there is no separate "mission report" surface or table in the game: every
// expedition/hunt outcome lands in combat_reports and renders here. This card IS the whole report
// archive; a combat/mission SPLIT would be invented structure over one dataset.

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
  const [openId, setOpenId] = useState<string | null>(null) // round-log open (its fetch trigger)
  const [ticks, setTicks] = useState<CombatTick[]>([])
  const [ticksLoading, setTicksLoading] = useState(false)
  // Per-row fold overrides (the player's explicit taps this session); the default is the
  // reportFold policy — newest open, older collapsed.
  const [rowOverrides, setRowOverrides] = useState<Record<string, boolean>>({})
  const newestId = newestReportId(reports)

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
    <CollapsibleCard
      title="Combat reports"
      subtitle="Battle history"
      storageKey="command.reports"
      data-testid="combat-reports-section"
    >
      {error && (
        <Notice tone="danger" className="mb-3">{error}</Notice>
      )}
      {reports.length === 0 && !error && (
        <p className="text-sm text-ink-muted">No battles fought yet.</p>
      )}

      <ul className="space-y-3">
        {reports.map((r) => {
          const won = r.result === 'escaped' || r.result === 'completed'
          const rowOpen = reportRowOpen(rowOverrides, r.encounter_id, newestId)
          const logOpen = openId === r.encounter_id
          return (
            <li key={r.id} className="rounded-lg border border-edge bg-surface-2/50 p-3">
              <Collapsible
                data-testid={`report-row-${r.encounter_id}`}
                open={rowOpen}
                onToggle={(next) =>
                  setRowOverrides((o) => ({ ...o, [r.encounter_id]: next }))
                }
                header={
                  <span className="flex min-w-0 flex-1 items-center justify-between gap-3">
                    <span className="truncate text-sm text-ink">{locName(r.location_id)}</span>
                    <Badge tone={won ? 'success' : 'danger'}>
                      {won ? 'Battle complete' : 'Fleet destroyed'}
                    </Badge>
                  </span>
                }
              >
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

                  {/* The round log — the one fold that is also a FETCH trigger (ticks load on
                      open, exactly as before); state stays with the fetch bookkeeping above. */}
                  <Collapsible
                    data-testid={`report-roundlog-${r.encounter_id}`}
                    open={logOpen}
                    onToggle={() => void toggle(r)}
                    headerClassName="mt-2"
                    header={<span className="text-xs font-medium text-ink">Round log</span>}
                  >
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
                  </Collapsible>
                </div>
              </Collapsible>
            </li>
          )
        })}
      </ul>
    </CollapsibleCard>
  )
}
