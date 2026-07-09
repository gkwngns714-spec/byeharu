import { useEffect, useState } from 'react'
import { useShellState } from '../../app/shellState'
import { Card, CardHeader, Badge, SectionLabel } from '../../components/ui'
import { fetchMyShipGroups, fetchMyShipGroupMap } from './teamApi'
import { buildTeamRoster, type GroupRow, type RosterShip } from './teamRoster'

// TEAM-COMMAND Slice A — READ-ONLY team roster (backend "group" == UI "team").
//
// DARK: mounted only behind TEAM_COMMAND_ENABLED (see CommandScreen); tree-shaken while false, so nothing here
// renders or fetches in production yet. Scope is visibility ONLY — it lists the player's ships grouped into
// teams and lets the player pick which ship is selected. It initiates NO team travel and NO combat (later
// slices). Selection is the ONE shell source (shellState.selection): the roster reads `ships`/`selectedShipId`
// from it and calls `selectShip` — it never mounts a second selection source. Group membership + team names
// (which the shell selection does not carry) are fetched here and merged for display only.

export function TeamRosterPanel() {
  const { selection } = useShellState()
  const [groups, setGroups] = useState<GroupRow[]>([])
  const [groupMap, setGroupMap] = useState<Record<string, string | null>>({})
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    let active = true
    void Promise.all([fetchMyShipGroups(), fetchMyShipGroupMap()]).then(([g, m]) => {
      if (!active) return
      setGroups(g)
      setGroupMap(m)
      setLoading(false)
    })
    return () => {
      active = false
    }
  }, [])

  // Merge the shell's ship list (the ONE selection source) with the fetched membership map → roster shapes.
  const rosterShips: RosterShip[] = selection.ships.map((s) => ({
    main_ship_id: s.main_ship_id,
    name: s.name,
    status: s.status,
    group_id: groupMap[s.main_ship_id] ?? null,
  }))
  const { teams, ungrouped } = buildTeamRoster(groups, rosterShips)

  const shipButton = (s: RosterShip) => {
    const selected = s.main_ship_id === selection.selectedShipId
    return (
      <button
        key={s.main_ship_id}
        onClick={() => selection.selectShip(s.main_ship_id)}
        className={`flex w-full items-center justify-between rounded-md border px-3 py-2 text-left text-sm ${
          selected ? 'border-accent/40 bg-accent/5' : 'border-edge bg-surface hover:border-edge-strong'
        }`}
      >
        <span className="truncate text-ink">{s.name}</span>
        <span className="ml-3 flex shrink-0 items-center gap-2">
          <span className="text-xs text-ink-faint">{s.status}</span>
          {selected && <Badge tone="accent">Selected</Badge>}
        </span>
      </button>
    )
  }

  return (
    <Card>
      <CardHeader
        title="Teams"
        subtitle="Command roster — select a ship. Team travel & combat arrive in later slices."
        aside={<Badge tone="warning">Preview</Badge>}
      />
      {loading ? (
        <p className="text-sm text-ink-muted">Loading roster…</p>
      ) : (
        <div className="space-y-4">
          {teams.map(({ group, ships }) => (
            <div key={group.group_id} className="space-y-2">
              <SectionLabel>
                {group.name} · Team {group.group_index} · {ships.length} ship{ships.length === 1 ? '' : 's'}
              </SectionLabel>
              {ships.length === 0 ? (
                <p className="text-xs text-ink-faint">No ships assigned.</p>
              ) : (
                <div className="space-y-1.5">{ships.map(shipButton)}</div>
              )}
            </div>
          ))}

          <div className="space-y-2">
            <SectionLabel>
              Unassigned · {ungrouped.length} ship{ungrouped.length === 1 ? '' : 's'}
            </SectionLabel>
            {ungrouped.length === 0 ? (
              <p className="text-xs text-ink-faint">All ships are assigned to a team.</p>
            ) : (
              <div className="space-y-1.5">{ungrouped.map(shipButton)}</div>
            )}
          </div>
        </div>
      )}
    </Card>
  )
}
