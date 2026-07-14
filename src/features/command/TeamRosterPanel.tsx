import { useCallback, useEffect, useState } from 'react'
import { useShellState } from '../../app/shellState'
import { Card, CardHeader, Badge, SectionLabel, Button, Notice, Skeleton, Icon } from '../../components/ui'
import {
  fetchMyShipGroups,
  fetchMyShipGroupMap,
  fetchMyPresentShipFleets,
  upsertShipGroup,
  assignShipToGroup,
  deleteShipGroup,
  sendShipGroup,
  stopShipGroup,
  sendShipGroupHunt,
  type PresentShipFleetLite,
  type ShipGroupMapEntry,
  type TeamRpcResult,
} from './teamApi'
import { deriveDockedTeamRollups } from './teamRollup'
import {
  buildTeamRoster,
  nextTeamSlot,
  fleetPositionLocationLabel,
  teamGatherState,
  type GroupRow,
  type RosterShip,
} from './teamRoster'
import { groupUpsertAvailability } from './teamMutations'
import { sendableDestinations, groupSendAvailability } from './teamSend'
import { groupStopAvailability } from './teamStop'
import { huntableDestinations, groupHuntAvailability } from './teamCombat'
import { captainsByShip } from './teamCaptains'
import { TeamMemberCaptains } from './TeamMemberCaptains'
import { TeamPreviewSection } from './TeamPreviewSection'
import { TeamDossier } from './TeamDossier'
import { getMyCaptainInstances } from '../captains/captainsApi'
import type { GetMyCaptainInstancesResult } from '../captains/captainsTypes'
import { isServerLit } from '../../lib/useActivityPanelGuards'
import { withPowerGate } from '../map/locationDisplay'
import { fetchMyExpeditionPreview, fetchMyFleetPositions, type FleetPosition } from '../map/mainshipApi'
import { mainShipInstanceStatusLabel } from '../map/mainshipStatusLabel'
import { shipPowerFromPreview } from '../ship/shipDossierView'
import { fetchLaunchFromDockEnabled } from '../../lib/catalog'

// TEAM-COMMAND Slice B1 — INTERACTIVE team roster (backend "group" == UI "team").
//
// DARK: mounted only behind TEAM_COMMAND_ENABLED (see CommandScreen); not mounted while false, so nothing here
// renders or fetches in production yet. B0 added the server write RPCs; B1 wires them: create / rename / delete
// a team and assign / unassign a ship. It still initiates NO team travel and NO combat (later slices).
//
// Selection is the ONE shell source (shellState.selection): the ship LIST + the "selected ship" pointer come
// from it; assign actions target a ship id taken straight from that list — no second selection source. Group
// metadata + membership (which the shell selection doesn't carry) are fetched here. NO optimistic UI: every
// mutation awaits the server then refetches BOTH group reads, so the view can never diverge from server truth
// (a deleted team's ships reappear as ungrouped via ON DELETE SET NULL).
//
// Slice C1 adds two dark sub-surfaces (both inherit this panel's compile-time mount gate):
//   • per-member captains (TeamMemberCaptains) — rendered ONLY when isServerLit(get_my_captain_instances),
//     so while captain_assignment_enabled is false the server's captain_assignment_disabled envelope keeps
//     the roster byte-identical to today (the CaptainsPanel fail-closed posture; the client is never the
//     control). Captain mutations await-then-refetch the captain roster — no optimistic UI.
//   • per-team expedition preview (TeamPreviewSection) — display-only estimate over C0's preview RPC; a
//     rosterVersion stamp invalidates any cached preview whenever the panel reloads (membership ⇒ stale).
//
// Slice D4 adds the team COMBAT surface (same compile-time mount gate; the server additionally rejects
// team_command_disabled while dark):
//   • per-team Hunt — destination <select> over huntableDestinations + a TWO-CLICK send (combat commits
//     ships): 'Hunt' arms an inline confirm (the confirmDelete idiom) whose 'Confirm hunt' submits
//     send_ship_group_hunt via the same run() (await → refetch, never optimistic). Availability per the
//     groupHuntAvailability mirror; an EMPTY hunt list (no hunt_pirates location revealed) degrades to a
//     disabled control + hint, never hides.
//   • TeamPreviewSection gains the authoritative "Server totals" line (D0's totals RPC).
//
// TEAM-UX (owner report: "how do I assign a ship?") — presentation-only redesign of the ASSIGN journey;
// zero RPC/state/logic change: (1) zero teams → a guided empty state (the old layout showed ships with NO
// assign control and never said "create a team first"); (2) each team card gets "+ Add ship" opening a
// one-tap picker of unassigned ships (assign FROM the team); (3) per-ship chips renamed from '→ {team}'
// to explicit 'Add to {team}' / 'Move to {team}' / 'Remove from team'; (4) assigns now surface a success
// notice. All paths share the same assign run key, busy guard, and await-then-refetch discipline.

export function TeamRosterPanel() {
  const { selection, game } = useShellState()
  const [groups, setGroups] = useState<GroupRow[]>([])
  const [groupMap, setGroupMap] = useState<Record<string, ShipGroupMapEntry>>({})
  // TEAMMAP-0: the docked-location read (a docked ship's 'present' fleet carries its location) —
  // refetched with the group reads so the rollup can never lag a membership/send mutation.
  const [presentFleets, setPresentFleets] = useState<PresentShipFleetLite[]>([])
  // TEAM-FRIENDLY: whole-fleet map positions (FLEETMAP / get_my_fleet_positions, 0200) — read ONCE
  // and mapped to a per-ship location label on every roster row. Refetched with the group reads so a
  // membership/send mutation can never leave a row's location stale.
  const [fleetPositions, setFleetPositions] = useState<FleetPosition[]>([])
  const [captainRoster, setCaptainRoster] = useState<GetMyCaptainInstancesResult | null>(null)
  const [rosterVersion, setRosterVersion] = useState(0) // bumped per reload — stales cached previews
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState<string | null>(null) // key of the mutation in flight (blocks double-submit)
  // last action outcome: a warning (failed) or a success summary (send/stop aggregate). Dark ⇒ rare.
  const [notice, setNotice] = useState<{ tone: 'warning' | 'success'; text: string } | null>(null)
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null) // group_id pending delete confirm
  const [addShipFor, setAddShipFor] = useState<string | null>(null) // group_id whose "+ Add ship" picker is open (TEAM-UX)
  const [drafts, setDrafts] = useState<Record<string, string>>({}) // per-team rename input, keyed by group_id
  const [destChoice, setDestChoice] = useState<Record<string, string>>({}) // per-team send destination id
  const [huntChoice, setHuntChoice] = useState<Record<string, string>>({}) // per-team hunt destination id
  const [confirmHunt, setConfirmHunt] = useState<string | null>(null) // group_id pending hunt confirm (D4)
  const [launchFromDock, setLaunchFromDock] = useState(false) // NO-HOME (0199) runtime gate; dark → home-only readiness

  const reload = useCallback(async () => {
    const [g, m, cr, pf, fp, lfd] = await Promise.all([
      fetchMyShipGroups(), fetchMyShipGroupMap(), getMyCaptainInstances(), fetchMyPresentShipFleets(),
      fetchMyFleetPositions(), fetchLaunchFromDockEnabled(),
    ])
    setGroups(g)
    setGroupMap(m)
    setCaptainRoster(cr)
    setPresentFleets(pf)
    setFleetPositions(fp)
    setLaunchFromDock(lfd)
    setRosterVersion((v) => v + 1) // membership may have changed — any cached preview is stale
    setLoading(false)
  }, [])

  // Initial load: inline .then so setState lands in an async callback, not synchronously in the effect body
  // (react-hooks/set-state-in-effect). reload() reuses the same four fetches after every mutation.
  useEffect(() => {
    let active = true
    void Promise.all([
      fetchMyShipGroups(), fetchMyShipGroupMap(), getMyCaptainInstances(), fetchMyPresentShipFleets(),
      fetchMyFleetPositions(), fetchLaunchFromDockEnabled(),
    ]).then(([g, m, cr, pf, fp, lfd]) => {
      if (!active) return
      setGroups(g)
      setGroupMap(m)
      setCaptainRoster(cr)
      setPresentFleets(pf)
      setFleetPositions(fp)
      setLaunchFromDock(lfd)
      setLoading(false)
    })
    return () => {
      active = false
    }
  }, [])

  // Captain-roster-only refetch, used by TeamMemberCaptains after a completed assign/unassign
  // (await-then-refetch, never optimistic). Group membership can't change on a captain command, so
  // the group reads are not re-run here — but the preview IS staled: calculate_expedition_stats
  // folds captain skills (0122), so an assign/unassign changes member stats and any shown preview
  // is pre-mutation. Bumping rosterVersion hides it the same way a membership change does.
  const refreshCaptains = useCallback(async () => {
    const cr = await getMyCaptainInstances()
    setCaptainRoster(cr)
    setRosterVersion((v) => v + 1)
  }, [])

  // Run a mutation: block re-entry, clear stale notice, await the server, surface any reject, THEN refetch
  // server truth (never optimistic). All mutation controls disable while any run is in flight.
  const run = async (
    key: string,
    op: () => Promise<TeamRpcResult>,
    summarize?: (res: TeamRpcResult & { ok: true }) => string,
  ) => {
    if (busy) return
    setBusy(key)
    setNotice(null)
    try {
      const res = await op()
      if (!res.ok) setNotice({ tone: 'warning', text: `Couldn’t complete that action (${res.reason}).` })
      else if (summarize) setNotice({ tone: 'success', text: summarize(res) })
      await reload()
    } finally {
      setBusy(null) // never wedge the panel, even if a wrapper unexpectedly rejects
    }
  }

  // Merge the shell's ship list (the ONE selection source) with the fetched membership map → roster shapes.
  const rosterShips: RosterShip[] = selection.ships.map((s) => ({
    main_ship_id: s.main_ship_id,
    name: s.name,
    status: s.status,
    group_id: groupMap[s.main_ship_id]?.group_id ?? null,
  }))
  const { teams, ungrouped } = buildTeamRoster(groups, rosterShips)
  const openSlot = nextTeamSlot(groups)

  // SHIP-POWER — per-ship power chips on UNGROUPED rows only (documented decision): a grouped
  // ship's power already surfaces in its TeamDossier Breakdown (the group preview RPC fetches
  // per-member stats), so solo-fetching grouped members would double-read the same numbers. For
  // ungrouped ships nothing else fetches their stats, so we read the SOLO preview
  // (get_my_expedition_preview) once per ship per roster load — cached by rosterVersion (the
  // panel's staleness discipline: a loadout/captain mutation reloads, bumps the version, and
  // stales this map). N = ungrouped-ship count (small: ships arrive one commission at a time),
  // batched in ONE Promise.all wave. A null power (invalid/dark) simply omits the chip.
  const [soloPower, setSoloPower] = useState<{ version: number; byShip: Record<string, number | null> } | null>(null)
  const ungroupedIdsKey = ungrouped.map((s) => s.main_ship_id).join('|') // uuids — '|' never collides
  useEffect(() => {
    // While the roster/group reads are in flight, groupMap is {} and EVERY ship derives as
    // ungrouped — fetching then would fire an N_total preview wave for a set that's about to be
    // wrong, followed by a second (real) wave. Bail until the load settles; `loading` is a dep, so
    // the effect refires with the true ungrouped set the moment it flips false.
    if (loading) return
    if (ungroupedIdsKey === '') return
    const ids = ungroupedIdsKey.split('|')
    let active = true
    void Promise.all(ids.map((id) => fetchMyExpeditionPreview(id))).then((raws) => {
      if (!active) return
      const byShip: Record<string, number | null> = {}
      ids.forEach((id, i) => {
        byShip[id] = shipPowerFromPreview(raws[i])
      })
      setSoloPower({ version: rosterVersion, byShip })
    })
    return () => {
      active = false
    }
  }, [ungroupedIdsKey, rosterVersion, loading])
  // Only data computed at the CURRENT roster version renders (the TeamDossier stamp discipline).
  const curSoloPower = soloPower !== null && soloPower.version === rosterVersion ? soloPower.byShip : null

  // TEAMMAP-0: the pure docked-team rollup (live membership × 'present' fleets); the muted card
  // line renders ONLY for a complete (n/n) dock, with the location named from the SAME shell
  // world read every other panel uses (an unrevealed location shows no line — fail closed).
  const dockRollups = deriveDockedTeamRollups(groups, groupMap, presentFleets)
  // TEAM-FRIENDLY: one FLEETMAP row per owned ship, indexed by id → each roster row resolves its
  // location label through the ONE shared resolver (fleetPositionLocationLabel). A ship missing from
  // the projection has no entry → the row omits the location (honest, never a guessed place).
  const posByShip = new Map(fleetPositions.map((p) => [p.main_ship_id, p]))
  const dockLineFor = (groupId: string): string | null => {
    const r = dockRollups.find((x) => x.groupId === groupId)
    if (!r || r.locationId === null) return null
    const locName = game.locations.find((l) => l.id === r.locationId)?.name
    return locName ? `Docked at ${locName} — ${r.dockedCount}/${r.memberCount}` : null
  }
  const destinations = sendableDestinations(game.locations) // active, non-combat targets (server re-validates)
  const huntZones = huntableDestinations(game.locations) // active hunt_pirates targets — may be EMPTY today

  // FAIL CLOSED (Slice C1): the captain sub-surface exists ONLY when the server affirmatively lit
  // get_my_captain_instances — captain_assignment_disabled (and any transport error) → null → the
  // roster renders byte-identical to today. The split preserves roster order per bucket.
  const captainSplit = isServerLit(captainRoster) ? captainsByShip(captainRoster.captains ?? []) : null

  const shipRow = (s: RosterShip) => {
    const selected = s.main_ship_id === selection.selectedShipId
    // TEAM-FRIENDLY: humanized status (mainShipInstanceStatusLabel — stationary→"Docked", 0199) plus
    // the leak-safe per-ship location from the ONE resolver. Location is OMITTED (never a wrong port)
    // when the ship isn't in the FLEETMAP projection.
    const locLabel = fleetPositionLocationLabel(posByShip.get(s.main_ship_id), game.locations)
    return (
      <div
        key={s.main_ship_id}
        className={`rounded-lg border px-3 py-2 ${
          selected ? 'border-accent/40 bg-accent/5' : 'border-edge bg-surface'
        }`}
      >
        <div className="flex items-center justify-between">
          <button onClick={() => selection.selectShip(s.main_ship_id)} className="truncate text-left text-sm text-ink">
            {s.name}
          </button>
          <span className="ml-3 flex shrink-0 items-center gap-2">
            <span className="text-xs text-ink-faint">{mainShipInstanceStatusLabel(s.status)}</span>
            {selected && <Badge tone="accent">Selected</Badge>}
          </span>
        </div>
        {/* TEAM-FRIENDLY: where the ship IS — "Docked at Haven Reach" / "In transit to …" / "In combat".
            Omitted entirely when unknown, so a row never claims a place it can't prove. */}
        {locLabel && <p className="mt-0.5 text-[11px] text-ink-muted">{locLabel}</p>}
        {/* Remove is the only per-ship membership control that remains on a member row — the ONE add
            surface is each team's "+ Add ship" picker (below). Same assign RPC + run key; await → refetch. */}
        {s.group_id != null && (
          <div className="mt-2">
            <Button
              size="sm"
              variant="ghost"
              busy={busy === `assign:${s.main_ship_id}`}
              disabled={busy !== null}
              onClick={() =>
                void run(
                  `assign:${s.main_ship_id}`,
                  () => assignShipToGroup(s.main_ship_id, null),
                  () => `Removed ${s.name} from its team.`,
                )
              }
            >
              Remove from team
            </Button>
          </div>
        )}
        {/* Slice C1 — per-member captains, ONLY while the captain feature is server-lit (grouped AND
            ungrouped rows). Slot count is the SERVER-reported captain_slots (owner-RLS read) — never
            a hardcoded 2/6; null skips the client precheck and lets the server answer. */}
        {captainSplit && (
          <TeamMemberCaptains
            mainShipId={s.main_ship_id}
            shipStatus={s.status}
            assigned={captainSplit.byShip.get(s.main_ship_id) ?? []}
            unassigned={captainSplit.unassigned}
            captainSlots={groupMap[s.main_ship_id]?.captain_slots ?? null}
            refresh={refreshCaptains}
          />
        )}
      </div>
    )
  }

  return (
    <Card>
      <CardHeader
        title="Teams"
        subtitle="Group your ships into teams and command them together."
        aside={<Badge tone="warning">Preview</Badge>}
      />

      {/* TEAM-UX: the one-line "how" — the old subtitle was a feature laundry list that never told a new
          player the ORDER of operations (create a team FIRST, then add ships). */}
      <p className="mb-3 text-xs text-ink-faint">
        How teams work: create a team, add ships to it, then send or hunt with the whole team in one order.
      </p>

      {notice && (
        <Notice tone={notice.tone} className="mb-3">
          {notice.text}
        </Notice>
      )}

      {loading ? (
        // UI R4: design-system Skeleton rows instead of bare loading text (same condition).
        <div aria-busy="true">
          <Skeleton className="h-8 w-32 rounded-lg" />
          <Skeleton className="mt-3 h-16 w-full rounded-lg" />
          <span className="sr-only">Loading roster…</span>
        </div>
      ) : (
        <div className="space-y-4">
          {/* TEAM-UX: with ZERO teams the panel used to show only a small "+ Create team" button and a list
              of ships with NO assign control at all (assign targets only exist once a team does) — nothing
              said "create a team first". Guided empty state fixes exactly that; same RPC, same run key. */}
          {teams.length === 0 ? (
            <div className="rounded-lg border border-dashed border-edge p-6 text-center">
              <Icon name="command" size={28} className="mx-auto text-ink-faint" />
              <h3 className="mt-2 text-sm font-semibold text-ink">Create your first team</h3>
              <p className="mx-auto mt-1 max-w-xs text-xs text-ink-muted">
                {ungrouped.length > 0
                  ? `You have ${ungrouped.length} ship${ungrouped.length === 1 ? '' : 's'} ready to crew — create a team, then add ${ungrouped.length === 1 ? 'it' : 'them'} with “+ Add ship”.`
                  : 'Ships join teams here — create a team, then add your ships to it.'}
              </p>
              {openSlot !== null && (
                <Button
                  variant="primary"
                  size="sm"
                  className="mt-3"
                  busy={busy === 'create'}
                  disabled={busy !== null}
                  onClick={() => void run('create', () => upsertShipGroup(openSlot, 'Team'))}
                >
                  + Create your first team
                </Button>
              )}
            </div>
          ) : (
            openSlot !== null && (
              <Button
                size="sm"
                variant="secondary"
                busy={busy === 'create'}
                disabled={busy !== null}
                onClick={() => void run('create', () => upsertShipGroup(openSlot, 'Team'))}
              >
                + Create team
              </Button>
            )
          )}

          {teams.map(({ group, ships }) => {
            const draft = drafts[group.group_id] ?? group.name
            const nameOk = groupUpsertAvailability({ gateEnabled: true, groupIndex: group.group_index, name: draft }).canUpsert
            const destId = destChoice[group.group_id] ?? ''
            const destName = destinations.find((d) => d.id === destId)?.name ?? ''
            const sendOk = groupSendAvailability({ gateEnabled: true, groupResolved: true, memberCount: ships.length }).canSend
            const stopOk = groupStopAvailability({ gateEnabled: true, groupResolved: true, memberCount: ships.length }).canStop
            const huntId = huntChoice[group.group_id] ?? ''
            const huntName = huntZones.find((d) => d.id === huntId)?.name ?? ''
            // The D4 mirror (client-mirrorable prefix of 0168; fleet cap/power/stats are server-only —
            // see teamCombat.ts). Readiness folds what the roster knows: every member status 'home'
            // (hp isn't carried here; the server's under-lock hp>0 check is the truth).
            const huntOk = groupHuntAvailability({
              gateEnabled: true,
              groupResolved: true,
              memberCount: ships.length,
              // RESOLVED destination, the send-gate convention: a chosen id that later drops out of
              // game.locations (poll marks it inactive/non-combat) must disarm Hunt too.
              locationValid: huntZones.some((d) => d.id === huntId),
              // NO-HOME (0199): dark → every ship home (byte-identical). Lit → a team fully docked at ONE
              // port (rollup.locationId non-null) is ALSO ready; it launches from and docks back at that
              // port. The server (widened send_ship_group_hunt) defaults the return port to the dock, so
              // the roster passes no extra arg. hp isn't carried here — the server's under-lock check is truth.
              allMembersReady:
                ships.every((s) => s.status === 'home') ||
                (launchFromDock && (dockRollups.find((x) => x.groupId === group.group_id)?.locationId ?? null) !== null),
            }).canHunt
            // TEAM-FRIENDLY: the same-location NOTICE + Send/Hunt-disabled reason. Co-location comes
            // straight from the REUSED dock rollup (never a second fold); teamGatherState folds it with
            // the same all-home check the hunt gate uses. This is a WARN — it never blocks grouping.
            const rollup = dockRollups.find((x) => x.groupId === group.group_id) ?? null
            const gather = teamGatherState({
              memberCount: ships.length,
              allHome: ships.length > 0 && ships.every((s) => s.status === 'home'),
              dockedLocationId: rollup?.locationId ?? null,
            })
            const gatherPort = rollup?.locationId
              ? (game.locations.find((l) => l.id === rollup.locationId)?.name ?? null)
              : null
            return (
              <div key={group.group_id} className="space-y-2 rounded-lg border border-edge/60 p-3">
                <div className="flex items-center justify-between gap-2">
                  <SectionLabel>
                    Team {group.group_index} · {ships.length} ship{ships.length === 1 ? '' : 's'}
                  </SectionLabel>
                  <div className="flex items-center gap-1.5">
                    <input
                      value={draft}
                      onChange={(e) => setDrafts((d) => ({ ...d, [group.group_id]: e.target.value }))}
                      className="w-28 rounded-lg border border-edge bg-surface-2 px-2 py-1 text-xs text-ink"
                      aria-label={`Rename team ${group.group_index}`}
                    />
                    <Button
                      size="sm"
                      variant="ghost"
                      busy={busy === `rename:${group.group_id}`}
                      disabled={busy !== null || !nameOk || draft === group.name}
                      onClick={() => void run(`rename:${group.group_id}`, () => upsertShipGroup(group.group_index, draft))}
                    >
                      Save
                    </Button>
                    <Button
                      size="sm"
                      variant="ghost"
                      disabled={busy !== null}
                      onClick={() => setConfirmDelete(group.group_id)}
                    >
                      Delete
                    </Button>
                  </div>
                </div>

                {/* TEAM-DOSSIER — the always-visible authoritative stats strip (Power/Speed/Cargo/
                    Survival/Members from D0's totals RPC, auto-fetched) + per-ship Breakdown (C0's
                    preview). rosterVersion re-fetches it after every membership/captain mutation —
                    the same invalidation the preview section leans on. captainsLit drives only the
                    "captains included" label copy (the adapter folds captain skills either way). */}
                <TeamDossier
                  groupId={group.group_id}
                  groupIndex={group.group_index}
                  memberCount={ships.length}
                  ships={ships}
                  rosterVersion={rosterVersion}
                  captainsLit={captainSplit !== null}
                  dockRollup={dockLineFor(group.group_id)}
                />

                {/* TEAM-FRIENDLY: same-location notice + the reason Send/Hunt is disabled. Gathered
                    (all home, or docked together with launch-from-dock lit) reads affirmatively; a
                    scattered or docked-but-can't-launch team gets the gather hint (a WARN, never a block). */}
                {gather === 'scattered' && (
                  <Notice tone="warning" data-testid={`team-gather-${group.group_id}`}>
                    Ships are at different ports — gather them at one port, or bring them all home, to send or hunt.
                  </Notice>
                )}
                {gather === 'co_located' &&
                  (launchFromDock ? (
                    <p className="text-xs text-ink-muted" data-testid={`team-gather-${group.group_id}`}>
                      All ships together at {gatherPort ?? 'one port'} — ready to send or hunt from here.
                    </p>
                  ) : (
                    <Notice tone="warning" data-testid={`team-gather-${group.group_id}`}>
                      All ships docked at {gatherPort ?? 'one port'} — bring them home to send or hunt.
                    </Notice>
                  ))}
                {gather === 'all_home' && (
                  <p className="text-xs text-ink-muted" data-testid={`team-gather-${group.group_id}`}>
                    All ships home — ready to send or hunt.
                  </p>
                )}

                {confirmDelete === group.group_id && (
                  <Notice tone="danger">
                    Delete this team? Its ships stay — they’re just un-grouped.
                    <span className="ml-2 inline-flex gap-1.5">
                      <Button
                        size="sm"
                        variant="danger"
                        busy={busy === `delete:${group.group_id}`}
                        disabled={busy !== null}
                        onClick={() =>
                          void run(`delete:${group.group_id}`, () => deleteShipGroup(group.group_id)).then(() =>
                            setConfirmDelete(null),
                          )
                        }
                      >
                        Delete
                      </Button>
                      <Button size="sm" variant="ghost" disabled={busy !== null} onClick={() => setConfirmDelete(null)}>
                        Cancel
                      </Button>
                    </span>
                  </Notice>
                )}

                {ships.length === 0 ? (
                  <p className="text-xs text-ink-faint">No ships in this team yet — use “+ Add ship” below.</p>
                ) : (
                  <div className="space-y-1.5">{ships.map(shipRow)}</div>
                )}

                {/* TEAM-UX: assign FROM the team ("+ Add ship" → one-tap picker of unassigned ships) —
                    more discoverable than hunting for per-ship chips in the Unassigned section. Same
                    assign RPC + run key as the per-ship path; await → refetch, never optimistic. */}
                <div className="space-y-1.5">
                  {addShipFor === group.group_id ? (
                    <div className="space-y-1.5 rounded-lg border border-edge bg-surface-2/50 p-2">
                      <div className="flex items-center justify-between gap-2">
                        <SectionLabel>Unassigned ships — tap Add</SectionLabel>
                        <Button size="sm" variant="ghost" onClick={() => setAddShipFor(null)}>
                          Done
                        </Button>
                      </div>
                      {ungrouped.length === 0 ? (
                        <p className="text-xs text-ink-faint">Every ship is already on a team.</p>
                      ) : (
                        ungrouped.map((s) => {
                          // TEAM-FRIENDLY: the canonical add surface — each pickable ship shows the
                          // same humanized status + leak-safe location + power the roster rows do, so
                          // the player picks with full context. Power chip preserved here (the SHIP-
                          // POWER feature's only render site now the bottom list is gone).
                          const locLabel = fleetPositionLocationLabel(posByShip.get(s.main_ship_id), game.locations)
                          return (
                            <div
                              key={s.main_ship_id}
                              className="flex items-center justify-between gap-2 rounded-lg border border-edge bg-surface px-2 py-1.5"
                            >
                              <span className="min-w-0">
                                <span className="block truncate text-xs text-ink">{s.name}</span>
                                {locLabel && <span className="block truncate text-[10px] text-ink-muted">{locLabel}</span>}
                              </span>
                              <span className="flex shrink-0 items-center gap-2">
                                {curSoloPower?.[s.main_ship_id] != null && (
                                  <span
                                    data-testid={`roster-power-${s.main_ship_id}`}
                                    className="inline-flex items-baseline gap-1 rounded border border-edge bg-surface-2 px-1.5 py-0.5 text-[10px]"
                                  >
                                    <span className="text-ink-faint">Power</span>
                                    <span className="font-mono tabular-nums text-ink">{curSoloPower[s.main_ship_id]}</span>
                                  </span>
                                )}
                                <span className="text-[10px] text-ink-faint">{mainShipInstanceStatusLabel(s.status)}</span>
                                <Button
                                  size="sm"
                                  variant="secondary"
                                  busy={busy === `assign:${s.main_ship_id}`}
                                  disabled={busy !== null}
                                  onClick={() =>
                                    void run(
                                      `assign:${s.main_ship_id}`,
                                      () => assignShipToGroup(s.main_ship_id, group.group_id),
                                      () => `Added ${s.name} to ${group.name}.`,
                                    )
                                  }
                                >
                                  Add
                                </Button>
                              </span>
                            </div>
                          )
                        })
                      )}
                    </div>
                  ) : (
                    <Button
                      size="sm"
                      variant="secondary"
                      disabled={busy !== null || ungrouped.length === 0}
                      onClick={() => setAddShipFor(group.group_id)}
                    >
                      + Add ship
                    </Button>
                  )}
                  {addShipFor !== group.group_id && (
                    <span className="ml-2 text-[10px] text-ink-faint">
                      {ungrouped.length === 0
                        ? 'No unassigned ships.'
                        : `${ungrouped.length} ship${ungrouped.length === 1 ? '' : 's'} available to add.`}
                    </span>
                  )}
                </div>

                {/* Team send/stop (dark). Send needs an active, non-combat destination; Stop needs none. The
                    server re-validates + owns atomicity; this is a convenience surface. */}
                <div className="flex flex-wrap items-center gap-1.5 border-t border-edge/60 pt-2">
                  <select
                    value={destId}
                    onChange={(e) => setDestChoice((d) => ({ ...d, [group.group_id]: e.target.value }))}
                    disabled={busy !== null}
                    aria-label={`Send destination for team ${group.group_index}`}
                    className="rounded-lg border border-edge bg-surface-2 px-2 py-1 text-xs text-ink"
                  >
                    <option value="">Destination…</option>
                    {destinations.map((d) => (
                      <option key={d.id} value={d.id}>
                        {d.name}
                      </option>
                    ))}
                  </select>
                  <Button
                    size="sm"
                    variant="secondary"
                    busy={busy === `send:${group.group_id}`}
                    // gate on a RESOLVED destination: a chosen id that later drops out of game.locations
                    // (poll marks it inactive/combat) must disable Send, not just the empty placeholder.
                    disabled={busy !== null || !sendOk || !destinations.some((d) => d.id === destId)}
                    onClick={() =>
                      void run(
                        `send:${group.group_id}`,
                        () => sendShipGroup(group.group_id, destId),
                        (res) => {
                          const n = (res.sent as unknown[] | undefined)?.length ?? 0
                          return `Sent ${n} ship${n === 1 ? '' : 's'} to ${destName}.`
                        },
                      )
                    }
                  >
                    Send
                  </Button>
                  <Button
                    size="sm"
                    variant="ghost"
                    busy={busy === `stop:${group.group_id}`}
                    disabled={busy !== null || !stopOk}
                    onClick={() =>
                      void run(
                        `stop:${group.group_id}`,
                        () => stopShipGroup(group.group_id),
                        (res) =>
                          `Stopped ${(res.stopped as number | undefined) ?? 0}, skipped ${(res.skipped as number | undefined) ?? 0}, failed ${(res.failed as number | undefined) ?? 0}.`,
                      )
                    }
                  >
                    Stop
                  </Button>
                </div>

                {/* Slice D4 — team hunt (dark): the COMBAT send. Two-click by design (combat commits
                    ships): Hunt arms an inline confirm below (the confirmDelete idiom); Confirm hunt
                    submits via run() (await → refetch, busy-guarded, never optimistic). An empty hunt
                    list (no hunt_pirates location revealed yet) degrades: disabled select + hint. */}
                <div className="flex flex-wrap items-center gap-1.5 border-t border-edge/60 pt-2">
                  <select
                    value={huntId}
                    onChange={(e) => {
                      setHuntChoice((d) => ({ ...d, [group.group_id]: e.target.value }))
                      // retargeting disarms a pending confirm — it must never commit to a stale zone
                      setConfirmHunt((c) => (c === group.group_id ? null : c))
                    }}
                    disabled={busy !== null || huntZones.length === 0}
                    aria-label={`Hunt zone for team ${group.group_index}`}
                    className="rounded-lg border border-edge bg-surface-2 px-2 py-1 text-xs text-ink"
                  >
                    <option value="">Hunt zone…</option>
                    {/* DIFFICULTY-DISPLAY — surface the min_power gate in the option label (e.g.
                        'Ember Gate — power 150+'; gate-free zones render the bare name, byte-
                        identical to before). Read from game.locations, the SAME shell poll
                        huntZones derives from — no new fetch; the server (power_below_required)
                        remains the only real gate. huntName (confirm + summary) stays d.name. */}
                    {huntZones.map((d) => (
                      <option key={d.id} value={d.id}>
                        {withPowerGate(d.name, game.locations.find((l) => l.id === d.id)?.min_power_required ?? 0)}
                      </option>
                    ))}
                  </select>
                  <Button
                    size="sm"
                    variant="secondary"
                    disabled={busy !== null || !huntOk || confirmHunt === group.group_id}
                    onClick={() => setConfirmHunt(group.group_id)}
                  >
                    Hunt
                  </Button>
                  {huntZones.length === 0 && (
                    <span className="text-[10px] text-ink-faint">No hunt zones revealed yet.</span>
                  )}
                </div>

                {confirmHunt === group.group_id && (
                  <Notice tone="danger">
                    Confirm hunt? The whole team commits to combat at {huntName || 'the selected zone'}.
                    <span className="ml-2 inline-flex gap-1.5">
                      <Button
                        size="sm"
                        variant="danger"
                        busy={busy === `hunt:${group.group_id}`}
                        disabled={busy !== null || !huntOk}
                        onClick={() =>
                          void run(
                            `hunt:${group.group_id}`,
                            () => sendShipGroupHunt(group.group_id, huntId),
                            (res) => {
                              const n = (res.member_count as number | undefined) ?? ships.length
                              return `Sent ${n} ship${n === 1 ? '' : 's'} hunting at ${huntName}.`
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

                {/* Slice C1 — per-team expedition preview (display-only estimate; Slice D owns truth).
                    rosterVersion invalidates a cached preview on every reload (membership ⇒ stale). */}
                <TeamPreviewSection
                  groupId={group.group_id}
                  groupIndex={group.group_index}
                  memberCount={ships.length}
                  ships={ships}
                  rosterVersion={rosterVersion}
                />
              </div>
            )
          })}

          {/* TEAM-FRIENDLY: the bottom "Unassigned ships" list (a redundant third add surface) is gone.
              Unassigned ships now live in exactly ONE place — each team's "+ Add ship" picker — so there
              is a single, obvious way to put a ship on a team. A short roll-up keeps them visible. */}
          {teams.length > 0 && (
            <p className="text-xs text-ink-muted">
              {ungrouped.length === 0
                ? 'All ships are assigned to a team.'
                : `${ungrouped.length} ship${ungrouped.length === 1 ? '' : 's'} not on a team yet — open a team’s “+ Add ship” to assign ${ungrouped.length === 1 ? 'it' : 'them'}.`}
            </p>
          )}
        </div>
      )}
    </Card>
  )
}
