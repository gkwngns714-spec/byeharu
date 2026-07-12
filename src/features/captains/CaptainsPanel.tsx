import { useCallback, useEffect, useState } from 'react'
import { isServerLit, runGuardedCommand, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { assignCaptainToShip, getMyCaptainInstances, unassignCaptainFromShip } from './captainsApi'
import {
  captainCommandErrorMessage,
  type CaptainInstance,
  type GetMyCaptainInstancesResult,
} from './captainsTypes'
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
}: {
  mainShipId: string | null
  lifecycleKey: string
}) {
  const [roster, setRoster] = useState<GetMyCaptainInstancesResult | null>(null)
  // Per-captain (instance-id-keyed) pending + note Records — the ModulesPanel per-row guarded idiom.
  const [pending, setPending] = useState<Record<string, boolean>>({})
  const [rowNote, setRowNote] = useState<Record<string, string | null>>({})

  // Mounted + synchronous in-flight guards — the shared home of the idiom (useActivityPanelGuards).
  const guards = useActivityPanelGuards()
  const { activeRef } = guards

  const refresh = useCallback(async () => {
    const res = await getMyCaptainInstances()
    if (!activeRef.current) return
    setRoster(res)
  }, [activeRef]) // ref identity is stable — dep satisfies the lint rule without changing identity

  // lifecycleKey is a deliberate re-fetch trigger (the ModulesPanel dep idiom).
  useEffect(() => {
    void refresh()
  }, [refresh, lifecycleKey])

  // One intentional Assign per row — the shared guarded-submit body over the per-captain key; the server
  // dedups on (player, request_id) and is the final authority on ownership/slots/settled-safe. request_id
  // is a fresh crypto.randomUUID() STRING (the TEXT wrapper param). Failure copy: server message, else map.
  async function assign(c: CaptainInstance) {
    if (!mainShipId) return
    await runGuardedCommand({
      key: c.instance_id,
      guards,
      setPending: (on) => setPending((p) => ({ ...p, [c.instance_id]: on })),
      setNote: (note) => setRowNote((n) => ({ ...n, [c.instance_id]: note })),
      exec: () => assignCaptainToShip(crypto.randomUUID(), c.instance_id, mainShipId),
      successNote: () => `Assigned ${c.name}.`,
      errorNote: (res) => captainCommandErrorMessage(res),
      refresh,
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
      refresh,
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
