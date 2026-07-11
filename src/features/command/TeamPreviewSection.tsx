import { useState } from 'react'
import { Button, Notice, StatRow } from '../../components/ui'
import { fetchGroupExpeditionPreview, type GroupPreviewResult } from './teamApi'
import { ADDITIVE_STAT_KEYS, aggregateTeamStats, groupPreviewAvailability } from './teamSkillset'
import { isPreviewActivity, PREVIEW_ACTIVITY_TYPES } from './teamCaptains'

// TEAM-COMMAND Slice C1 — per-team expedition PREVIEW (dark UI). Rendered ONLY from TeamRosterPanel,
// so it inherits the compile-time TEAM_COMMAND_ENABLED gate (never mounted in prod); the server
// additionally rejects team_command_disabled while dark. Activity <select> over EXACTLY the 0165
// set (PREVIEW_ACTIVITY_TYPES) + a Preview button gated by C0's groupPreviewAvailability mirror; on
// success it renders C0's aggregateTeamStats — an ESTIMATE, display-only (authoritative team stats
// are Slice D's, defined beside the combat consumer). A fetched preview is stamped with the
// roster version it was computed at and only renders while CURRENT: any panel reload (membership
// change ⇒ stale members) bumps the version and the cached preview disappears — no effect-driven
// clearing, pure derivation.

// Pretty label for a stats key ('captain_slots_used' → 'captain slots used').
const statLabel = (k: string) => k.replace(/_/g, ' ')

export function TeamPreviewSection({
  groupId,
  groupIndex,
  memberCount,
  ships,
  rosterVersion,
}: {
  groupId: string
  groupIndex: number
  memberCount: number
  // roster names for the per-member lines (display convenience — members are keyed by id).
  ships: { main_ship_id: string; name: string }[]
  // bumped by the panel on every reload — a preview stamped with an older version is stale.
  rosterVersion: number
}) {
  const [activity, setActivity] = useState<string>('none')
  const [busy, setBusy] = useState(false)
  const [preview, setPreview] = useState<{ version: number; res: GroupPreviewResult } | null>(null)

  // C0's availability mirror verbatim: the panel is only mounted behind the compile-time gate
  // (gateEnabled true here), the group is an owned roster row (resolved), so the live inputs are
  // the activity + member count. The server re-checks everything.
  const { canPreview } = groupPreviewAvailability({
    gateEnabled: true,
    activityKnown: isPreviewActivity(activity),
    groupResolved: true,
    memberCount,
  })

  const runPreview = async () => {
    if (busy) return
    setBusy(true)
    try {
      const res = await fetchGroupExpeditionPreview(groupId, activity)
      setPreview({ version: rosterVersion, res })
    } finally {
      setBusy(false)
    }
  }

  // Only a preview computed at the CURRENT roster version renders — a reload invalidates it.
  const current = preview !== null && preview.version === rosterVersion ? preview.res : null
  const shipName = (id: string) => ships.find((s) => s.main_ship_id === id)?.name ?? id

  return (
    <div className="space-y-2 border-t border-edge/60 pt-2">
      <div className="flex flex-wrap items-center gap-1.5">
        <select
          value={activity}
          onChange={(e) => setActivity(e.target.value)}
          disabled={busy}
          aria-label={`Preview activity for team ${groupIndex}`}
          className="rounded-lg border border-edge bg-surface-2 px-2 py-1 text-xs text-ink"
        >
          {PREVIEW_ACTIVITY_TYPES.map((a) => (
            <option key={a} value={a}>
              {a === 'none' ? 'none (idle)' : statLabel(a)}
            </option>
          ))}
        </select>
        <Button size="sm" variant="secondary" busy={busy} disabled={busy || !canPreview} onClick={() => void runPreview()}>
          Preview
        </Button>
        <span className="text-[10px] text-ink-faint">Estimate — display-only.</span>
      </div>

      {current && !current.ok && (
        <Notice tone="warning">Couldn’t preview this team ({current.reason}).</Notice>
      )}

      {current && current.ok && (() => {
        const agg = aggregateTeamStats(current.members)
        return (
          <div className="space-y-2 rounded-lg border border-edge bg-surface-2/50 px-3 py-2">
            <p className="text-[10px] text-ink-faint">
              Expedition preview · {current.activity_type} · {agg.validCount} valid / {agg.invalidCount} invalid of{' '}
              {agg.memberCount} member{agg.memberCount === 1 ? '' : 's'} · estimate, display-only
            </p>
            <dl className="space-y-0.5 text-xs">
              {ADDITIVE_STAT_KEYS.map((k) => (
                <StatRow key={k} label={statLabel(k)} value={agg.totals[k]} />
              ))}
              <StatRow
                label="slowest speed"
                value={agg.slowestSpeed ?? '—'}
                hint={agg.slowestSpeed !== null ? '(the team moves at its slowest member)' : undefined}
              />
            </dl>
            <ul className="space-y-0.5 border-t border-edge/60 pt-1.5 text-[10px]">
              {current.members.map((m) => (
                <li key={m.main_ship_id} className="flex items-baseline justify-between gap-2">
                  <span className="truncate text-ink">{shipName(m.main_ship_id)}</span>
                  {m.valid ? (
                    <span className="shrink-0 text-success">valid</span>
                  ) : (
                    <span className="shrink-0 text-warning">invalid{m.error ? ` — ${m.error}` : ''}</span>
                  )}
                </li>
              ))}
            </ul>
          </div>
        )
      })()}
    </div>
  )
}
