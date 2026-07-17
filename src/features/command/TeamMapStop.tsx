import { useState } from 'react'
import { Button, Notice, OverlayPanel, SectionLabel } from '../../components/ui'
import type { FleetMovement } from '../fleets/fleetTypes'
import { commandShipGroupStop, stopShipGroup, type TeamRpcResult } from './teamApi'
import type { GroupRow } from './teamRoster'
import { groupStopAvailability, resolveStoppableFleets, stopOutcomeMessage, unifiedStopOutcomeMessage } from './teamStop'
import { teamReasonMessage } from './teamReasonMessage'

// MOVEMENT-ON-MAP step 2 — the map's fleet STOP (charter §2a: all movement interaction on the map).
//
// WHY THIS EXISTS: step 1 (a4ba96b) removed Send/Hunt/Stop from the Command roster. Send/Hunt/Move
// already had a map home (TeamMapSend); Stop did NOT — stopShipGroup + groupStopAvailability were
// fully built and ORPHANED with no caller, so the branch had no group-stop UI at all. This is the
// caller. It adds NO server surface: the RPC (0164), the wrapper, and the pure reject mirror all
// predate it untouched.
//
// The pure derivation + the outcome copy live in teamStop.ts (the ONE home for group-stop purity —
// this file adds no second fold and no parallel module).
//
// PLACEMENT — the one real decision here. All five overlay slots were already occupied: top-left
// (MapScreen's command/feature rail), top-right (GalaxyMap zoom), bottom-left (legend), top-center
// (world events), bottom-right (the per-SHIP stops — GalaxyMap's coordinate stop and MapScreen's
// legacy transit stop). bottom-right is the intuitive home for a "stop", but those two occupants can
// share it only because they are mutually exclusive BY STATE (one movement owner per ship) — a FLEET
// stop is a different owner and can be live at the same time as either (a player's main ship can sit
// in a legacy transit while a team flies), so a third absolute-positioned occupant there would
// genuinely collide. So this rides the top-left RAIL, which stacks its children and cannot collide,
// and MapScreen mounts it FIRST in that rail: a stop is a safety CTA and must not be reachable only
// by scrolling past dark feature panels (the NO-SOFTLOCK posture in MapScreen's header).
//
// Discipline = the TeamMapSend/TeamRosterPanel idiom verbatim: submit via the SAME wrapper,
// NON-optimistic (await the server, then refresh the shell reads), per-fleet busy key blocking
// double-submit, try/finally so the panel never wedges, rejects mapped through the ONE
// teamReasonMessage copy map. Renders NOTHING when no owned fleet is in flight (a still player's map
// is byte-identical to today).
//
// Stop is deliberately ONE CLICK, unlike the hunt's two-click confirm: a hunt commits ships to combat
// (destructive, needs a gate), while a stop is the recovery FROM a commitment and is idempotent
// server-side (0164 is best-effort and skips whoever is already stopped). Putting a confirm in front
// of the brake is a hazard, not a safeguard.
//
// FLEET-GO 4a-1 — BOTH-WORLDS BRAKE, branched at RUNTIME on fleet_movement_unified_enabled
// (`unifiedEnabled`, threaded from useGalaxyMapData's one flag read; default false → the dark arm is
// byte-identical to today). LIT → command_ship_group_stop (0209: ONE brake for the group's ONE
// fleet; `stopped` is a BOOLEAN) with the unified outcome copy. DARK → stop_ship_group_transit
// (0164: loops the per-ship stop; `stopped` is a COUNT) with the 0164 copy, verbatim. The two
// envelopes disagree on the same key, so each arm keeps its own parser — see teamStop.ts.
// The derivation (resolveStoppableFleets) is shared unchanged: a unified fleet's movement carries
// group_id like any other, so the lit world needs no second selector.

export function TeamMapStop({
  movements,
  groups,
  unifiedEnabled = false,
  onStopped,
}: {
  movements: FleetMovement[]
  groups: GroupRow[]
  unifiedEnabled?: boolean
  onStopped: () => void
}) {
  const [busy, setBusy] = useState<string | null>(null)
  const [notice, setNotice] = useState<{ tone: 'warning' | 'success'; text: string } | null>(null)

  // Pure, time-independent, no interpolation — an un-drawable fleet is still stoppable (see teamMapStop.ts).
  const stoppable = resolveStoppableFleets(movements, groups)
  if (stoppable.length === 0) return null

  const run = async (fleetName: string, key: string, op: () => Promise<TeamRpcResult>) => {
    if (busy) return
    setBusy(key)
    setNotice(null)
    try {
      const res = await op()
      if (!res.ok) setNotice({ tone: 'warning', text: teamReasonMessage(res.reason) })
      else {
        // Each arm parses ITS OWN envelope: 0209's `stopped` is a boolean, 0164's a count — the
        // 0164 parser would read a successful unified stop as "nothing was in flight" (spec-pinned).
        setNotice({
          tone: 'success',
          text: unifiedEnabled ? unifiedStopOutcomeMessage(fleetName, res) : stopOutcomeMessage(fleetName, res),
        })
        onStopped() // map reads (movements/fleets) — the halted fleets leave the in-flight set
      }
    } finally {
      setBusy(null) // never wedge the panel, even if a wrapper unexpectedly rejects
    }
  }

  return (
    <OverlayPanel tone="warning" data-testid="team-map-stop" className="w-full">
      <SectionLabel>Fleets in flight</SectionLabel>
      {notice && (
        <Notice tone={notice.tone} className="mt-1.5">
          {notice.text}
        </Notice>
      )}
      <div className="mt-1.5 space-y-1.5">
        {stoppable.map((f) => {
          // The pure reject mirror (teamStop.ts) — the gate is lit for anything this component can
          // see (a dark gate keeps the groups read empty upstream), and a group with an in-flight
          // fleet is resolved and non-empty by construction. The server re-checks all of it.
          const canStop = groupStopAvailability({
            gateEnabled: true,
            groupResolved: true,
            memberCount: f.fleetCount,
          }).canStop
          return (
            <div key={f.groupId} className="flex items-center justify-between gap-2">
              <span className="min-w-0">
                <span className="block truncate text-xs text-ink">{f.name}</span>
                <span className="text-[10px] text-ink-faint">
                  {f.fleetCount} ship{f.fleetCount === 1 ? '' : 's'} in flight
                </span>
              </span>
              <Button
                size="sm"
                variant="warning"
                data-testid={`team-stop-${f.groupId}`}
                busy={busy === `stop:${f.groupId}`}
                busyLabel="Stopping…"
                disabled={busy !== null || !canStop}
                onClick={() =>
                  void run(f.name, `stop:${f.groupId}`, () =>
                    // LIT → the ONE unified brake (0209); DARK → the legacy per-member loop (0164), verbatim.
                    unifiedEnabled ? commandShipGroupStop(f.groupId) : stopShipGroup(f.groupId),
                  )
                }
              >
                Stop — hold here
              </Button>
            </div>
          )
        })}
      </div>
    </OverlayPanel>
  )
}
