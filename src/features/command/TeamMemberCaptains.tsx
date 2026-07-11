import { useState } from 'react'
import { runGuardedCommand, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { assignCaptainToShip, unassignCaptainFromShip } from '../captains/captainsApi'
import { captainCommandErrorMessage, type CaptainInstance } from '../captains/captainsTypes'
import { Button } from '../../components/ui'
import { captainAssignAvailability } from './teamCaptains'

// TEAM-COMMAND Slice C1 — per-member captain sub-surface (dark UI). Rendered ONLY from
// TeamRosterPanel's ship rows, so it inherits BOTH gates: the compile-time TEAM_COMMAND_ENABLED
// mount gate AND the panel's isServerLit(get_my_captain_instances) guard (the parent renders this
// only when the captain feature is server-lit — captain_assignment_disabled keeps the roster
// byte-identical to today). Submits ONLY the existing CAPTAIN-P15 commands via captainsApi
// (assign_captain_to_ship is already ship-addressed — no new server code) with the EXISTING
// guarded idiom: runGuardedCommand + useActivityPanelGuards, request_id = crypto.randomUUID(),
// error copy via the ONE mapper captainCommandErrorMessage. NO optimistic UI — the parent-supplied
// refresh() refetches the captain roster after every mutation.

// Statuses that CANNOT be captain-settled (in-flight / away / terminal) — a conservative client
// mirror of the 0121 settled-safe rule ("settled at home or docked"). 'home'/'stationary' are only
// CANDIDATES: a stationary-in-open-space ship still fails server-side (the client can't see
// spatial_state here), and the server's ship_not_settled is surfaced via the error mapper. The
// server stays the ONE authority.
const UNSETTLED_STATUSES = new Set([
  'traveling',
  'returning',
  'retreating',
  'hunting',
  'trading',
  'exploring',
  'mining',
  'repairing',
  'destroyed',
])

export function TeamMemberCaptains({
  mainShipId,
  shipStatus,
  assigned,
  unassigned,
  captainSlots,
  refresh,
}: {
  mainShipId: string
  shipStatus: string
  // this ship's assigned captains + the player's unassigned pool (from the ONE captainsByShip split).
  assigned: CaptainInstance[]
  unassigned: CaptainInstance[]
  // SERVER-reported main_ship_instances.captain_slots (owner-RLS read); null = unknown → the
  // client slot precheck is skipped and the server answers captain_slots_full itself.
  captainSlots: number | null
  // await-then-refetch of the captain roster (parent-owned; no optimistic UI).
  refresh: () => Promise<void>
}) {
  // Per-captain (instance-id-keyed) pending + note Records — the CaptainsPanel per-row idiom.
  const [pending, setPending] = useState<Record<string, boolean>>({})
  const [rowNote, setRowNote] = useState<Record<string, string | null>>({})
  const [pick, setPick] = useState('')
  const guards = useActivityPanelGuards()

  const shipSettled = !UNSETTLED_STATUSES.has(shipStatus)
  // A stale pick (assigned meanwhile / roster changed) falls back to the placeholder.
  const pickValid = unassigned.some((c) => c.instance_id === pick)
  const chosen = pickValid ? (unassigned.find((c) => c.instance_id === pick) ?? null) : null

  // DISPLAY-ONLY mirror of the assign reject order (teamCaptains.ts). serverLit is true by
  // construction (the parent only renders this sub-surface when isServerLit); hasFreeSlot comes
  // from the SERVER-reported slot count (never a hardcoded 2/6) — unknown → skip the precheck.
  const avail = captainAssignAvailability({
    serverLit: true,
    shipSettled,
    hasFreeSlot: captainSlots === null ? true : assigned.length < captainSlots,
    captainUnassigned: chosen !== null && chosen.main_ship_id === null,
  })
  const anyPending = Object.values(pending).some(Boolean)

  async function assign(c: CaptainInstance) {
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

  return (
    <div className="mt-2 border-t border-edge/60 pt-2">
      <p className="text-[10px] text-ink-faint">
        Captains{captainSlots !== null ? ` · ${assigned.length}/${captainSlots} slots` : ''}
      </p>

      {assigned.length === 0 ? (
        <p className="text-[10px] text-ink-muted">No captains assigned.</p>
      ) : (
        <ul className="mt-1 space-y-1">
          {assigned.map((c) => (
            <li key={c.instance_id} className="text-[10px]">
              <div className="flex items-center justify-between gap-2">
                <span className="truncate text-ink">{c.name}</span>
                <span className="flex shrink-0 items-center gap-1.5">
                  <span className="rounded bg-surface-2 px-1.5 py-0.5 text-[9px] text-ink-muted">
                    {c.specialization}
                  </span>
                  <Button
                    size="sm"
                    variant="ghost"
                    busy={pending[c.instance_id] ?? false}
                    busyLabel="Unassigning…"
                    disabled={anyPending}
                    onClick={() => void unassign(c)}
                  >
                    Unassign
                  </Button>
                </span>
              </div>
              {rowNote[c.instance_id] && <p className="mt-0.5 text-[10px] text-accent">{rowNote[c.instance_id]}</p>}
            </li>
          ))}
        </ul>
      )}

      {unassigned.length > 0 && (
        <div className="mt-1.5">
          <div className="flex flex-wrap items-center gap-1.5">
            <select
              value={pickValid ? pick : ''}
              onChange={(e) => setPick(e.target.value)}
              disabled={anyPending}
              aria-label={`Assign a captain to ${mainShipId}`}
              className="rounded-lg border border-edge bg-surface-2 px-2 py-1 text-xs text-ink"
            >
              <option value="">Assign captain…</option>
              {unassigned.map((c) => (
                <option key={c.instance_id} value={c.instance_id}>
                  {c.name} · {c.specialization}
                </option>
              ))}
            </select>
            <Button
              size="sm"
              variant="secondary"
              busy={chosen !== null && (pending[chosen.instance_id] ?? false)}
              busyLabel="Assigning…"
              disabled={anyPending || chosen === null || !avail.canAssign}
              onClick={() => chosen && void assign(chosen)}
            >
              Assign
            </Button>
          </div>
          {/* Surface the display-only precheck (ship_not_settled / captain_slots_full) through the ONE
              error-copy mapper — the same wording the server's reject would produce. */}
          {(avail.reason === 'ship_not_settled' || avail.reason === 'captain_slots_full') && (
            <p className="mt-0.5 text-[10px] text-ink-muted">
              {captainCommandErrorMessage({ reason: avail.reason })}
            </p>
          )}
          {chosen !== null && rowNote[chosen.instance_id] && (
            <p className="mt-0.5 text-[10px] text-accent">{rowNote[chosen.instance_id]}</p>
          )}
        </div>
      )}
    </div>
  )
}
