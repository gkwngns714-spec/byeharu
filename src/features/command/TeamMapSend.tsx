import { useEffect, useState } from 'react'
import { useShellState } from '../../app/shellState'
import { Badge, Button, Notice, SectionLabel } from '../../components/ui'
import type { MapLocation } from '../map/mapTypes'
import {
  fetchMyShipGroups,
  fetchMyShipGroupMap,
  fetchMyPresentShipFleets,
  fetchGroupExpeditionTotals,
  sendShipGroup,
  sendShipGroupHunt,
  moveShipGroup,
  type PresentShipFleetLite,
  type ShipGroupMapEntry,
  type TeamRpcResult,
} from './teamApi'
import type { GroupRow } from './teamRoster'
import { teamDestinationKind } from './teamDestination'
import { groupSendAvailability } from './teamSend'
import { groupHuntAvailability } from './teamCombat'
import { deriveDockedTeamRollups } from './teamRollup'
import { teamMapSendAction } from './teamMove'
import { teamReasonMessage } from './teamReasonMessage'

// TEAM-MAP-SEND — "Send a team here" on MapScreen's location detail sheet (owner order: send
// teams FROM THE MAP by clicking locations). Mounted by MapScreen behind the compile-time
// TEAM_COMMAND_ENABLED gate (the CommandScreen idiom); renders NOTHING unless the selected
// location is a legal team destination (teamDestinationKind — the pure reuse of the roster's
// sendable/huntable predicates) AND the player has at least one team (a team-less player's map
// sheet must never nag about teams).
//
// Wiring (the cheapest correct one — NO new server surface): ONE fetch of the existing owner
// reads (fetchMyShipGroups + fetchMyShipGroupMap) when the sheet section mounts — the sheet stays
// mounted across location switches, so switching targets costs zero refetches. Member names +
// statuses come from the shell's ONE ship list (selection.ships), merged with the membership map
// exactly like TeamRosterPanel. Each team's power is D0's authoritative totals
// (fetchGroupExpeditionTotals(groupId,'none')) fetched ONCE per open sheet per team — never per
// click/keystroke; a failed/opaque totals read just omits the power hint (the row still works).
//
// Command discipline = the TeamRosterPanel idiom verbatim: submit via the SAME wrappers
// (sendShipGroup / sendShipGroupHunt), NON-optimistic (await the server, then refresh the shell
// reads), per-control busy key blocking double-submit, rejects mapped through the ONE
// teamReasonMessage copy map, success feedback naming team + destination. Hunts take the
// two-click confirm (combat commits ships); the armed confirm carries the location id it was
// armed FOR, so switching the selected location disarms it by derivation — a confirm can never
// commit to a stale destination.
//
// TEAMMOVE-1 — the docked-team arm (owner directive: "docked or move as a whole"): the sheet also
// fetches the present-fleet read (the TEAMMAP rollup input) and folds it through the ONE
// deriveDockedTeamRollups reuse; each expedition row then takes its action from the ONE pure
// classifier teamMapSendAction (teamMove.ts) — 'move' (fully docked at another port → "Move team
// here", moveShipGroup → move_ship_group_to_location 0190, new testid team-move-<groupId>),
// 'docked_here' (muted badge, nothing to do), 'docked_unready' (any docked member → the home send
// is DOOMED server-side, so the Send control renders DISABLED with a gather hint — a docked team
// never gets an enabled Send), or 'send' (the original arm). Same run() discipline, same reason
// map, existing testids untouched; the server re-checks everything under its locks and stays
// authoritative.

export function TeamMapSend({ location, onSent }: { location: MapLocation; onSent: () => void }) {
  const { selection } = useShellState()
  const [groups, setGroups] = useState<GroupRow[] | null>(null) // null = loading (render nothing yet)
  const [groupMap, setGroupMap] = useState<Record<string, ShipGroupMapEntry>>({})
  const [presentFleets, setPresentFleets] = useState<PresentShipFleetLite[]>([]) // docked-team rollup input
  const [powers, setPowers] = useState<Record<string, number>>({}) // group_id → authoritative combat power
  const [busy, setBusy] = useState<string | null>(null) // key of the command in flight
  const [notice, setNotice] = useState<{ tone: 'warning' | 'success'; text: string } | null>(null)
  // armed hunt confirm — carries the location it was armed for (stale-destination disarm by derivation)
  const [confirmHunt, setConfirmHunt] = useState<{ groupId: string; locationId: string } | null>(null)

  // ONE membership fetch per open sheet (see module header). Inline .then so setState lands in an
  // async callback, not synchronously in the effect body (react-hooks/set-state-in-effect).
  useEffect(() => {
    let active = true
    void Promise.all([fetchMyShipGroups(), fetchMyShipGroupMap(), fetchMyPresentShipFleets()]).then(
      ([g, m, pf]) => {
        if (!active) return
        setGroups(g)
        setGroupMap(m)
        setPresentFleets(pf)
      },
    )
    return () => {
      active = false
    }
  }, [])

  // ONE totals read per team per open sheet — the power hint beside each team name. 'none' is the
  // neutral activity (the dossier strip's choice); the server folds captains into combat_power
  // (0122 via 0166). Opaque/reject reads simply leave the hint off — display-only, never a gate.
  useEffect(() => {
    if (!groups || groups.length === 0) return
    let active = true
    for (const g of groups) {
      void fetchGroupExpeditionTotals(g.group_id, 'none').then((res) => {
        if (!active || !res.ok || typeof res.totals.combat_power !== 'number') return
        setPowers((p) => ({ ...p, [g.group_id]: res.totals.combat_power }))
      })
    }
    return () => {
      active = false
    }
  }, [groups])

  const kind = teamDestinationKind(location)
  // Hidden entirely: not a team destination, teams still loading, or the player has zero teams.
  if (kind === null || groups === null || groups.length === 0) return null

  // TEAMMOVE-1 — the docked-team rollup (the ONE TEAMMAP fold, reused verbatim): a team whose every
  // member is docked at the SAME location gets a non-null locationId, and — for an expedition
  // destination that isn't that port — the row below offers "Move team here" (the 0190 onward move)
  // instead of the home-team send.
  const dockRollups = deriveDockedTeamRollups(groups, groupMap, presentFleets)

  // The TeamRosterPanel run() discipline: block re-entry, await the server, map any reject through
  // the ONE copy map, THEN refresh the shell reads (never optimistic).
  const run = async (key: string, op: () => Promise<TeamRpcResult>, summarize: (res: TeamRpcResult & { ok: true }) => string) => {
    if (busy) return
    setBusy(key)
    setNotice(null)
    try {
      const res = await op()
      if (!res.ok) setNotice({ tone: 'warning', text: teamReasonMessage(res.reason) })
      else {
        setNotice({ tone: 'success', text: summarize(res) })
        onSent() // map data (movements/fleets)
        await selection.refresh() // ship statuses (members just left home / their dock)
        setPresentFleets(await fetchMyPresentShipFleets()) // docked rollups (a moved team left its port)
      }
    } finally {
      setBusy(null) // never wedge the sheet, even if a wrapper unexpectedly rejects
    }
  }

  return (
    <div data-testid="team-map-send" className="mt-4 border-t border-edge/60 pt-3">
      <div className="flex items-center justify-between gap-2">
        <SectionLabel>Send a team here</SectionLabel>
        {kind === 'hunt' && <Badge tone="danger">Combat</Badge>}
      </div>

      {notice && (
        <Notice tone={notice.tone} className="mt-2">
          {notice.text}
        </Notice>
      )}

      <div className="mt-2 space-y-1.5">
        {groups.map((g) => {
          // Members = the shell's ONE ship list merged with the fetched membership map (the
          // TeamRosterPanel wiring) — carries live statuses for the hunt-readiness mirror.
          const members = selection.ships.filter((s) => groupMap[s.main_ship_id]?.group_id === g.group_id)
          const power = powers[g.group_id]
          const allHome = members.length > 0 && members.every((s) => s.status === 'home')
          const sendOk = groupSendAvailability({
            gateEnabled: true,
            groupResolved: true,
            memberCount: members.length,
          }).canSend
          // TEAMMOVE-1 — the expedition-arm action from the ONE pure classifier (teamMove.ts):
          // 'move' (fully docked elsewhere), 'docked_here' (muted, nothing to do),
          // 'docked_unready' (any docked member → the home send is DOOMED server-side, never
          // render it enabled), or 'send' (the original arm). kind==='expedition' already proved
          // the destination legal; the server (0190) stays the sole authority under its locks.
          const rollup = dockRollups.find((d) => d.groupId === g.group_id)
          const arm =
            kind === 'expedition'
              ? teamMapSendAction({
                  memberCount: rollup?.memberCount ?? members.length,
                  dockedCount: rollup?.dockedCount ?? 0,
                  dockedLocationId: rollup?.locationId ?? null,
                  destinationId: location.id,
                })
              : null
          // kind==='hunt' already proved the destination active + hunt_pirates → locationValid true.
          const huntOk = groupHuntAvailability({
            gateEnabled: true,
            groupResolved: true,
            memberCount: members.length,
            locationValid: true,
            allMembersReady: allHome,
          }).canHunt
          const armed = confirmHunt?.groupId === g.group_id && confirmHunt.locationId === location.id
          return (
            <div key={g.group_id} className="rounded-lg border border-edge bg-surface-2/50 px-2.5 py-2">
              <div className="flex items-center justify-between gap-2">
                <span className="min-w-0">
                  <span className="block truncate text-xs text-ink">{g.name}</span>
                  <span className="text-[10px] text-ink-faint">
                    {members.length} ship{members.length === 1 ? '' : 's'}
                    {typeof power === 'number' && (
                      <>
                        {' · '}
                        <span className="font-mono tabular-nums">power {power}</span>
                      </>
                    )}
                  </span>
                </span>
                {arm === 'move' ? (
                  /* TEAMMOVE-1 — a fully-docked team moves ONWARD as one (0190): same run()
                     discipline as the send; the server re-checks docked-together under its locks. */
                  <Button
                    size="sm"
                    variant="secondary"
                    data-testid={`team-move-${g.group_id}`}
                    busy={busy === `move:${g.group_id}`}
                    busyLabel="Moving…"
                    disabled={busy !== null}
                    onClick={() =>
                      void run(
                        `move:${g.group_id}`,
                        () => moveShipGroup(g.group_id, location.id),
                        (res) => {
                          const n = (res.sent as unknown[] | undefined)?.length ?? members.length
                          return `Moved ${g.name} — ${n} ship${n === 1 ? '' : 's'} — to ${location.name}.`
                        },
                      )
                    }
                  >
                    Move team here
                  </Button>
                ) : arm === 'docked_here' ? (
                  /* TEAMMOVE-1 — the team already sits docked at THIS port: nothing to do (a send
                     would be doomed — docked ≠ home; a move-here is a no-op the server rejects). */
                  <Badge>Docked here</Badge>
                ) : arm === 'send' || arm === 'docked_unready' ? (
                  /* 'docked_unready' keeps the familiar Send control but DISABLED: any docked
                     member dooms the home send to member_send_failed (the classifier's law). */
                  <Button
                    size="sm"
                    variant="secondary"
                    busy={busy === `send:${g.group_id}`}
                    busyLabel="Sending…"
                    disabled={busy !== null || !sendOk || arm === 'docked_unready'}
                    onClick={() =>
                      void run(
                        `send:${g.group_id}`,
                        () => sendShipGroup(g.group_id, location.id),
                        (res) => {
                          const n = (res.sent as unknown[] | undefined)?.length ?? members.length
                          return `Sent ${g.name} — ${n} ship${n === 1 ? '' : 's'} — to ${location.name}.`
                        },
                      )
                    }
                  >
                    Send team
                  </Button>
                ) : (
                  <Button
                    size="sm"
                    variant="secondary"
                    disabled={busy !== null || !huntOk || armed}
                    onClick={() => setConfirmHunt({ groupId: g.group_id, locationId: location.id })}
                  >
                    Hunt here
                  </Button>
                )}
              </div>
              {kind === 'hunt' && members.length > 0 && !allHome && (
                <p className="mt-1 text-[10px] text-ink-faint">Every ship must be home to hunt.</p>
              )}
              {arm === 'docked_unready' && (
                <p className="mt-1 text-[10px] text-ink-faint">
                  Some ships are docked away — gather the team at one port to move it, or bring every
                  ship home to send it.
                </p>
              )}
              {armed && (
                <Notice tone="danger" className="mt-2">
                  Confirm hunt? {g.name} commits to combat at {location.name}.
                  <span className="ml-2 inline-flex gap-1.5">
                    <Button
                      size="sm"
                      variant="danger"
                      busy={busy === `hunt:${g.group_id}`}
                      busyLabel="Sending…"
                      disabled={busy !== null || !huntOk}
                      onClick={() =>
                        void run(
                          `hunt:${g.group_id}`,
                          () => sendShipGroupHunt(g.group_id, location.id),
                          (res) => {
                            const n = (res.member_count as number | undefined) ?? members.length
                            return `Sent ${g.name} — ${n} ship${n === 1 ? '' : 's'} — hunting at ${location.name}.`
                          },
                        ).then(() => setConfirmHunt(null))
                      }
                    >
                      Confirm hunt
                    </Button>
                    <Button size="sm" variant="ghost" disabled={busy !== null} onClick={() => setConfirmHunt(null)}>
                      Cancel
                    </Button>
                  </span>
                </Notice>
              )}
            </div>
          )
        })}
      </div>
    </div>
  )
}
