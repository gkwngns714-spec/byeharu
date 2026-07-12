import { useCallback, useEffect, useState } from 'react'
import { isServerLit, runGuardedCommand, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { assignCaptainToShip, getMyCaptainInstances, getShipStations, unassignCaptainFromShip } from './captainsApi'
import {
  captainCommandErrorMessage,
  type CaptainInstance,
  type GetMyCaptainInstancesResult,
} from './captainsTypes'
import { AUTO_STATION, freeStations, stationForCommand, stationLabel, type ShipStation } from './deckStations'
import { captainsForShip } from '../ship/shipDossierView'
import { CaptainXpBar } from './CaptainXpBar'
import { Button, Card, CardHeader } from '../../components/ui'

// CAPTAIN-P15 (post-audit UI, panel 3 of 4) — the dark Captains surface: the player's captain roster
// with a per-row Assign/Unassign action over their main ship. SERVER-DRIVEN visibility (no client flag
// constant): on mount / lifecycle change it reads get_my_captain_instances (0123) and renders NOTHING
// unless the server affirmatively lit the feature ({ok:true}); while captain_assignment_enabled is false
// the server returns { ok:false, reason:'captain_assignment_disabled' } → not server-lit → null, so
// today's production experience is byte-unchanged. Reads ONLY the roster RPC and submits ONLY the two
// existing commands (0120/0121) — NO new server authority; the server stays authoritative on
// ownership / slots / the settled-safe rule. Per-row guarded submit (the ModulesPanel Record-keyed idiom).

export function CaptainsPanel({
  mainShipId,
  // Re-reads the roster whenever the main-ship lifecycle changes (the ModulesPanel/MiningPanel idiom).
  lifecycleKey,
  onChanged,
}: {
  mainShipId: string | null
  lifecycleKey: string
  // SHIP-DOSSIER: fires AFTER a successful assign/unassign's own refetch so sibling read surfaces
  // (ShipDossier's Captains section) can re-read — cross-panel refetch wire, never optimistic.
  onChanged?: () => void
}) {
  const [roster, setRoster] = useState<GetMyCaptainInstancesResult | null>(null)
  // DECKS-2: the six-station catalog (public-read; [] = read failed → no picker, assigns stay
  // auto — behavior-identical to pre-DECKS) + the panel's ONE station pick for the next assign.
  const [stations, setStations] = useState<ShipStation[]>([])
  const [stationPick, setStationPick] = useState<string>(AUTO_STATION)
  // Per-captain (instance-id-keyed) pending + note Records — the ModulesPanel per-row guarded idiom.
  const [pending, setPending] = useState<Record<string, boolean>>({})
  const [rowNote, setRowNote] = useState<Record<string, string | null>>({})

  // Mounted + synchronous in-flight guards — the shared home of the idiom (useActivityPanelGuards).
  const guards = useActivityPanelGuards()
  const { activeRef } = guards

  const refresh = useCallback(async () => {
    const [res, decks] = await Promise.all([getMyCaptainInstances(), getShipStations()])
    if (!activeRef.current) return
    setRoster(res)
    setStations(decks)
  }, [activeRef]) // ref identity is stable — dep satisfies the lint rule without changing identity

  // lifecycleKey is a deliberate re-fetch trigger (the ModulesPanel dep idiom).
  useEffect(() => {
    void refresh()
  }, [refresh, lifecycleKey])

  // SHIP-DOSSIER: post-success refetch + sibling notification (guarded commands only — the mount
  // refresh must NOT ping siblings). DECKS-2: the station pick also resets to auto — the picked
  // station is (usually) taken now, and a stale pick must never silently target the next assign.
  async function refreshAndNotify() {
    await refresh()
    setStationPick(AUTO_STATION)
    onChanged?.()
  }

  // DECKS-2: the picker's option set — the selected ship's FREE stations (display-side; the
  // server's station_occupied reject stays the enforcer). Empty catalog read → empty set → no
  // picker renders and assigns stay auto (pre-DECKS behavior exactly).
  const shipCaptains =
    isServerLit(roster) && mainShipId ? captainsForShip(roster.captains ?? [], mainShipId) : []
  const pickableStations = mainShipId ? freeStations(stations, shipCaptains) : []

  // DECKS-2: the ONE derived pick both the <select> and the command read — display and behavior
  // can never diverge (no setState-in-effect; a pure render derivation). A pick whose <option>
  // vanished (the station was taken between refreshes) VISIBLY falls back to Auto — the player
  // sees "Auto" before any click, so acting on it is never a silent substitution; a pick that IS
  // displayed is sent VERBATIM, and a lost race gets the server's honest station_occupied answer.
  const effectivePick =
    stationPick === AUTO_STATION || pickableStations.some((s) => s.station_id === stationPick)
      ? stationPick
      : AUTO_STATION

  // One intentional Assign per row — the shared guarded-submit body over the per-captain key; the server
  // dedups on (player, request_id) and is the final authority on ownership/slots/settled-safe/stations.
  // request_id is a fresh crypto.randomUUID() STRING (the TEXT wrapper param). DECKS-2: the DISPLAYED
  // pick (effectivePick — see the derivation above) rides along VERBATIM (Auto → null → the server
  // auto-assigns the lowest-sort free station; a displayed named pick that loses a race answers
  // station_occupied honestly — never a silent substitution). The success note names the LANDED station
  // from the command's own success envelope (0189 — server truth for the auto case too). Failure copy:
  // server message, else map.
  async function assign(c: CaptainInstance) {
    if (!mainShipId) return
    const station = stationForCommand(effectivePick)
    await runGuardedCommand({
      key: c.instance_id,
      guards,
      setPending: (on) => setPending((p) => ({ ...p, [c.instance_id]: on })),
      setNote: (note) => setRowNote((n) => ({ ...n, [c.instance_id]: note })),
      exec: () => assignCaptainToShip(crypto.randomUUID(), c.instance_id, mainShipId, station),
      successNote: (res) =>
        res.station != null
          ? `Assigned ${c.name} — ${stationLabel(stations, res.station)}.`
          : `Assigned ${c.name}.`, // pre-0189 envelope (no station key) — the old note verbatim
      errorNote: (res) => captainCommandErrorMessage(res),
      refresh: refreshAndNotify,
    })
  }

  // One intentional Unassign per row — same guarded body; unassign takes no ship (the wrapper resolves the
  // captain's current ship). request_id is a fresh uuid string.
  async function unassign(c: CaptainInstance) {
    await runGuardedCommand({
      key: c.instance_id,
      guards,
      setPending: (on) => setPending((p) => ({ ...p, [c.instance_id]: on })),
      setNote: (note) => setRowNote((n) => ({ ...n, [c.instance_id]: note })),
      exec: () => unassignCaptainFromShip(crypto.randomUUID(), c.instance_id),
      successNote: () => `Unassigned ${c.name}.`,
      errorNote: (res) => captainCommandErrorMessage(res),
      refresh: refreshAndNotify,
    })
  }

  // FAIL CLOSED: render nothing unless the server affirmatively lit the roster. This is the dark path in
  // production today (captain_assignment_disabled → not server-lit); transport errors collapse to null the
  // same way. The client is never the control.
  if (!isServerLit(roster)) return null

  const captains = roster.captains ?? []

  return (
    // UI R2: the Card primitive owns the chrome (accent tone = the captains identity; ex-fuchsia).
    // Screen-embedded — rides ShipScreen's Screen stack (space-y-4), so the legacy map-corner
    // absolute offset (bottom-2 left-[50rem]) is gone with the hand-rolled skin. Tokens only.
    <Card tone="accent" data-testid="captains-panel">
      <CardHeader title="Captains" />
      {/* DECKS-2 — the compact station picker for the NEXT assign (one panel-level pick, the
          ModulesPanel <select> token classes): Auto = the server picks the lowest-sort free
          station; the options are THIS ship's free stations only (server-enforced regardless).
          Renders only when an assign is possible (a ship + a lit catalog) — with the catalog read
          failed or dark, the panel is byte-identical to pre-DECKS. */}
      {mainShipId !== null && stations.length > 0 && (
        <div className="mt-2 flex items-center gap-1.5">
          <label htmlFor="deck-assign-station" className="shrink-0 text-[10px] text-ink-faint">
            Station
          </label>
          <select
            id="deck-assign-station"
            data-testid="deck-assign-station"
            value={effectivePick}
            onChange={(e) => setStationPick(e.target.value)}
            className="min-w-0 flex-1 rounded border border-edge bg-surface-2 px-1 py-0.5 text-[10px] text-ink"
          >
            <option value={AUTO_STATION}>Auto (first free)</option>
            {pickableStations.map((s) => (
              <option key={s.station_id} value={s.station_id}>
                {s.name}
              </option>
            ))}
          </select>
        </div>
      )}
      {captains.length === 0 ? (
        <p data-testid="captains-none" className="mt-2 border-t border-edge pt-2 text-[10px] text-ink-muted">
          No captains yet.
        </p>
      ) : (
        <ul data-testid="captains-list" className="mt-2 space-y-1 border-t border-edge pt-2">
          {captains.map((c) => {
            const assigned = c.main_ship_id != null
            const isPending = pending[c.instance_id] ?? false
            const note = rowNote[c.instance_id]
            const stats = Object.entries(c.stats_json ?? {})
              .slice(0, 3)
              .map(([k, v]) => `${k} ${v}`)
              .join(' · ')
            return (
              <li key={c.instance_id} data-testid={`captain-row-${c.instance_id}`} className="text-[10px]">
                <div className="flex items-center justify-between gap-2">
                  <span className="truncate text-ink">{c.name}</span>
                  <span className="shrink-0 rounded bg-surface-2 px-1.5 py-0.5 text-[9px] text-ink-muted">
                    {c.specialization}
                  </span>
                </div>
                {stats && <p className="text-ink-faint">{stats}</p>}
                {/* C2-3 — XP bar + level chip (dark): renders null while every captain is
                    level-1/0-xp (captain_growth_enabled false), so this row is byte-identical today. */}
                <CaptainXpBar xp={c.xp} level={c.level} instanceId={c.instance_id} />
                <div className="mt-1 flex items-center justify-between gap-2">
                  {assigned ? (
                    <Button
                      variant="secondary"
                      size="sm"
                      data-testid={`captain-unassign-${c.instance_id}`}
                      busy={isPending}
                      busyLabel="Unassigning…"
                      onClick={() => void unassign(c)}
                    >
                      Unassign
                    </Button>
                  ) : (
                    <Button
                      variant="primary"
                      size="sm"
                      data-testid={`captain-assign-${c.instance_id}`}
                      disabled={!mainShipId}
                      busy={isPending}
                      busyLabel="Assigning…"
                      onClick={() => void assign(c)}
                    >
                      Assign to ship
                    </Button>
                  )}
                  <span
                    data-testid={`captain-state-${c.instance_id}`}
                    className={`shrink-0 text-[9px] ${assigned ? 'text-success' : 'text-ink-muted'}`}
                  >
                    {assigned ? 'Assigned' : 'Unassigned'}
                  </span>
                </div>
                {note && (
                  <p data-testid={`captain-note-${c.instance_id}`} className="mt-0.5 text-[10px] text-accent">
                    {note}
                  </p>
                )}
              </li>
            )
          })}
        </ul>
      )}
    </Card>
  )
}
