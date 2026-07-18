import { useEffect, useState } from 'react'
import { Button } from '../../components/ui'
import {
  fetchGroupExpeditionPreview,
  fetchGroupExpeditionTotals,
  type GroupPreviewResult,
  type GroupTotalsResult,
} from './teamApi'
import { teamReasonMessage } from './teamReasonMessage'

// TEAM-DOSSIER — the always-visible per-team stats strip on TeamRosterPanel's team cards (owner
// order: "power, haul, capacity — every info of that team — the combined power and properties of
// each ship + captains"). Two surfaces, both fed by the EXISTING dark reads (no new server piece):
//
//   • The strip: D0's AUTHORITATIVE totals — fetchGroupExpeditionTotals(groupId,'none') — as five
//     mono chips: Power (combat) · Speed (slowest member) · Cargo cap (the adapter's ABSTRACT
//     cargo_capacity total — NOT the cargo_capacity_m3 hold volume, 0076's abstract-vs-volume
//     split; SHIP-POWER fixed the old 'Cargo m³' mislabel here) · Survival · Members.
//     Fetched on panel load and re-fetched whenever rosterVersion bumps (the panel bumps it after
//     EVERY membership/captain mutation — the existing invalidation), so the strip can never show
//     pre-mutation numbers; a result stamped with an older version renders as loading, never stale.
//     The label says server truth ('authoritative'), and — because the ONE stat adapter (0122)
//     folds captain skills into every number — notes captains are included when that surface is lit.
//   • The Breakdown toggle: per-ship contributions from C0's preview
//     (fetchGroupExpeditionPreview) — combat/cargo/speed per member, the friendly per-member
//     diagnosing surface (an invalid member shows its server error where the strict totals would
//     go opaque with stats_invalid). Fetched only while OPEN, re-fetched on version bump.
//
// An EMPTY team fetches nothing (the RPCs would only answer empty_group — the
// groupPreviewAvailability mirror's memberCount clause) and renders a quiet hint instead.

const chip = (label: string, value: number | string) => (
  <span key={label} className="inline-flex items-baseline gap-1 rounded border border-edge bg-surface px-1.5 py-0.5 text-[10px]">
    <span className="text-ink-faint">{label}</span>
    <span className="font-mono tabular-nums text-ink">{value}</span>
  </span>
)

const num = (v: unknown): number | string => (typeof v === 'number' && Number.isFinite(v) ? v : '—')

export function TeamDossier({
  groupId,
  groupIndex,
  memberCount,
  ships,
  rosterVersion,
  captainsLit,
  dockRollup,
}: {
  groupId: string
  groupIndex: number
  memberCount: number
  // roster names for the breakdown lines (display convenience — members are keyed by id).
  ships: { main_ship_id: string; name: string }[]
  // bumped by the panel on every reload — data stamped with an older version is stale.
  rosterVersion: number
  // whether the captain surface is server-lit (drives the "captains included" label copy only —
  // the totals RPC itself is gated on team_command alone and works regardless).
  captainsLit: boolean
  // TEAMMAP-0: the docked-team rollup line ("Docked at <location> — n/n"), derived by the panel
  // from the pure deriveDockedTeamRollups fold; null (no line) unless the WHOLE team is docked at
  // one location. Display only — never a gate.
  dockRollup?: string | null
}) {
  const [totals, setTotals] = useState<{ version: number; res: GroupTotalsResult } | null>(null)
  const [open, setOpen] = useState(false)
  const [breakdown, setBreakdown] = useState<{ version: number; res: GroupPreviewResult } | null>(null)

  // Authoritative totals: on mount AND on every rosterVersion bump (membership/captain mutation).
  useEffect(() => {
    if (memberCount <= 0) return // empty team — the server would only answer empty_group
    let active = true
    void fetchGroupExpeditionTotals(groupId, 'none').then((res) => {
      if (active) setTotals({ version: rosterVersion, res })
    })
    return () => {
      active = false
    }
  }, [groupId, rosterVersion, memberCount])

  // Per-ship breakdown: only while open; same staleness discipline (re-fetch on version bump).
  useEffect(() => {
    if (!open || memberCount <= 0) return
    let active = true
    void fetchGroupExpeditionPreview(groupId, 'none').then((res) => {
      if (active) setBreakdown({ version: rosterVersion, res })
    })
    return () => {
      active = false
    }
  }, [open, groupId, rosterVersion, memberCount])

  // Only data computed at the CURRENT roster version renders — a reload invalidates it.
  const cur = totals !== null && totals.version === rosterVersion ? totals.res : null
  const curBreakdown = breakdown !== null && breakdown.version === rosterVersion ? breakdown.res : null
  const shipName = (id: string) => ships.find((s) => s.main_ship_id === id)?.name ?? id

  return (
    <div data-testid={`team-dossier-${groupIndex}`} className="rounded-lg border border-edge bg-surface-2/50 px-3 py-2">
      <div className="flex items-center justify-between gap-2">
        <p className="text-[10px] text-ink-faint">
          Fleet stats · authoritative (server truth{captainsLit ? ', captains included' : ''})
        </p>
        {memberCount > 0 && (
          <Button size="sm" variant="ghost" onClick={() => setOpen((o) => !o)}>
            {open ? 'Hide ship details' : 'Ship details'}
          </Button>
        )}
      </div>

      {/* TEAMMAP-0 — the docked-team rollup line (the roster card's "where is my team" answer;
          the map's dock badge reads the same pure fold). Muted, display-only, existing tokens. */}
      {dockRollup && (
        <p data-testid="team-rollup" className="mt-1 text-[10px] text-ink-faint">
          {dockRollup}
        </p>
      )}

      {memberCount <= 0 ? (
        <p className="mt-1 text-[10px] text-ink-faint">No ships yet — add ships to see fleet stats.</p>
      ) : cur === null ? (
        <p className="mt-1 text-[10px] text-ink-faint" aria-busy="true">
          Fetching fleet stats…
        </p>
      ) : !cur.ok ? (
        <p className="mt-1 text-[10px] text-warning">{teamReasonMessage(cur.reason)}</p>
      ) : (
        <div className="mt-1.5 flex flex-wrap gap-1.5">
          {chip('Power', num(cur.totals.combat_power))}
          {chip('Speed', num(cur.totals.speed))}
          {chip('Cargo cap', num(cur.totals.cargo_capacity))}
          {chip('Survival', num(cur.totals.survival))}
          {chip('Members', cur.member_count)}
        </div>
      )}

      {open && memberCount > 0 && (
        <div className="mt-2 border-t border-edge/60 pt-1.5">
          <p className="text-[10px] text-ink-faint">Per-ship contribution (estimate)</p>
          {curBreakdown === null ? (
            <p className="mt-1 text-[10px] text-ink-faint" aria-busy="true">
              Fetching details…
            </p>
          ) : !curBreakdown.ok ? (
            <p className="mt-1 text-[10px] text-warning">{teamReasonMessage(curBreakdown.reason)}</p>
          ) : (
            <ul className="mt-1 space-y-0.5 text-[10px]">
              {curBreakdown.members.map((m) => (
                <li key={m.main_ship_id} className="flex items-baseline justify-between gap-2">
                  <span className="truncate text-ink">{shipName(m.main_ship_id)}</span>
                  {m.valid ? (
                    <span className="shrink-0 font-mono tabular-nums text-ink-muted">
                      pwr {num(m.stats?.combat_power ?? 0)} · cargo {num(m.stats?.cargo_capacity ?? 0)} · spd{' '}
                      {num(m.stats?.speed)}
                    </span>
                  ) : (
                    <span className="shrink-0 text-warning">invalid{m.error ? ` — ${m.error}` : ''}</span>
                  )}
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </div>
  )
}
