import { useState } from 'react'
import { Link } from 'react-router-dom'
import { Badge, Button, Notice, OverlayPanel, SectionLabel, buttonClasses } from '../../components/ui'
import {
  commandShipGroupDock,
  commandShipGroupGo,
  commandShipGroupStop,
  sendShipGroupHunt,
  type TeamRpcResult,
} from '../command/teamApi'
import { teamReasonMessage } from '../command/teamReasonMessage'
import { unifiedStopOutcomeMessage } from '../command/teamStop'
import { fleetGoSuccessMessage } from './fleetGoTarget'
import {
  buildFleetCommandModel,
  fleetCommandLocks,
  type FleetCommandModelInput,
  type FleetCommandSection,
} from './fleetCommandModel'

// S5 MAP-UX — THE fleet-command surface: ONE bottom-center panel consolidating the three scattered
// on-map command surfaces (FleetGoPanel top-right, TeamMapSend in the detail aside, TeamMapStop in
// the top-left rail — all three DELETED with this panel's landing). The panel is a SHELL: section
// content, order, and every wire payload come from the ONE pure composition model
// (fleetCommandModel.ts — spec-pinned), which itself only COMPOSES the proven classifiers. This file
// owns nothing but React state (busy/notice/armed-hunt/return-choice) and the submit wrappers.
//
// PROPS-FED, NO fetches of its own (the FleetGoPanel law): everything arrives from the shell's
// polled reads. ONE notice pair; namespaced busy keys (stop:/go:/dock:/hunt:) in TWO lock
// namespaces — see the brake decoupling below.
//
// NO-SOFTLOCK: the stop section is model-guaranteed FIRST and target-independent, and it renders
// OUTSIDE the internal scroll container below, so the brake can never scroll away and never hides
// behind a target/selection gate. Stop stays ONE CLICK, no confirm (the TeamMapStop law: a stop is
// the recovery FROM a commitment; a confirm in front of the brake is a hazard, not a safeguard).
// And the brake is NEVER locked by another verb's in-flight request (fleetCommandLocks — the pure,
// spec-pinned verdict): pre-S5 TeamMapStop had its OWN busy state, so a wedged go/send could never
// disable it; the consolidated panel keeps that property with a dedicated stop lock (supabase-js
// has no client timeout — a mover request that never settles must not take the brake down with it).
//
// DOCK — the S4 REPOINT (landed, 0219): the Dock row submit branches on the RUNTIME
// timedDockingEnabled flag — lit → commandShipGroupDock (the 45s timed leg; the map line shows
// "Docking m:ss"), dark → the EXISTING instant commandShipGroupGo(gid, { locationId }), byte-
// identical to pre-S4. Exactly as the v1 marker promised: ONLY the submit repointed — the shell,
// the model's dock-row derivation (fleetCommandModel.ts), and every other section stand untouched.
//
// HUNT — absorbed from TeamMapSend VERBATIM so no second command surface survives: two-click armed
// confirm carrying the location id it was armed FOR (switching targets disarms by derivation), the
// groupHuntAvailability mirror, and the NO-HOME return-port picker (never forced back to origin).

export function FleetCommandPanel({
  onCommanded,
  onClearTarget,
  timedDockingEnabled,
  ...inputs
}: FleetCommandModelInput & {
  /** Fired after any confirmed command — the shell refetch (non-optimistic, the house discipline). */
  onCommanded: () => void
  /** Clears the live target (point AND port selection) — the model re-derives to no target. */
  onClearTarget: () => void
  /** S4 (0219): runtime timed-dock gate — branches ONLY the dock-row submit (see the header). */
  timedDockingEnabled: boolean
}) {
  // THE BRAKE DECOUPLING (S5 review): TWO lock namespaces. `busy` locks the non-safety verbs
  // (go/dock/hunt); `stopBusy` locks ONLY the brake. The pure verdicts (fleetCommandLocks) make the
  // asymmetry structural: stopDisabled never reads `busy`, so a wedged mover request can never
  // disable Stop; non-safety verbs stay one-at-a-time and also yield to a firing brake.
  const [busy, setBusy] = useState<string | null>(null)
  const [stopBusy, setStopBusy] = useState<string | null>(null)
  const [notice, setNotice] = useState<{ tone: 'warning' | 'success'; text: string } | null>(null)
  // armed hunt confirm — carries the location it was armed for (stale-destination disarm by derivation)
  const [confirmHunt, setConfirmHunt] = useState<{ groupId: string; locationId: string } | null>(null)
  // RETURN-PORT (NO-HOME 0199): the player's chosen dock-after-hunt port, per fleet.
  const [returnChoice, setReturnChoice] = useState<Record<string, string>>({})

  const model = buildFleetCommandModel(inputs)
  const locks = fleetCommandLocks({ busy, stopBusy })
  if (!model.mount) return null

  // The shared submit body (ONE notice pair, non-optimistic await→refetch) — the lock discipline
  // lives in the two runners below, never here.
  const dispatch = async (op: () => Promise<TeamRpcResult>, summarize: (res: TeamRpcResult & { ok: true }) => string) => {
    const res = await op()
    if (!res.ok) setNotice({ tone: 'warning', text: teamReasonMessage(res.reason) })
    else {
      setNotice({ tone: 'success', text: summarize(res) })
      onCommanded() // shell reads (movements/fleets/ships) — non-optimistic, the server answered
    }
  }

  const run = async (key: string, op: () => Promise<TeamRpcResult>, summarize: (res: TeamRpcResult & { ok: true }) => string) => {
    if (locks.verbDisabled) return
    setBusy(key)
    setNotice(null)
    try {
      await dispatch(op, summarize)
    } finally {
      setBusy(null) // never wedge the panel, even if a wrapper unexpectedly rejects
    }
  }

  // The brake's OWN runner: gated on the stop namespace ONLY — a pending go/dock/hunt never blocks
  // it. A stop fired over a pending go is the intended outcome (the server serializes on the fleet
  // lock and the brake cancels the leg).
  const runStop = async (key: string, op: () => Promise<TeamRpcResult>, summarize: (res: TeamRpcResult & { ok: true }) => string) => {
    if (locks.stopDisabled) return
    setStopBusy(key)
    setNotice(null)
    try {
      await dispatch(op, summarize)
    } finally {
      setStopBusy(null)
    }
  }

  const shipCount = (res: TeamRpcResult & { ok: true }, fallback?: number): number | undefined =>
    typeof res.member_count === 'number' ? res.member_count : fallback

  const section = (s: FleetCommandSection) => {
    switch (s.kind) {
      case 'guidance':
        // MAP-INTEGRATION M2 — the groupless-player guidance (model-decided: ships + a live target +
        // zero fleets). Read-only pointer to Command (charter §2a: composition is Command's — this
        // panel gains NO create/assign controls); the link is the only affordance.
        return (
          <div key="guidance" data-testid="fleet-command-guidance">
            <SectionLabel>No fleet yet</SectionLabel>
            <p className="mt-1 text-sm text-ink-muted">
              Ships travel as fleets — yours wait at port until they join one.
            </p>
            <p className="mt-1 text-sm text-ink-muted">
              Create a fleet in <span className="text-ink">Command</span> and add your ships, then pick a
              destination here to send it.
            </p>
            <Link to="/command" className={`${buttonClasses('secondary', 'sm')} mt-2 w-full`}>
              Create a fleet in Command
            </Link>
          </div>
        )
      case 'prompt':
        // DISCOVERABILITY: has a sendable fleet, no destination picked. Name the gesture so the
        // send flow reads as an intentional step instead of appearing out of nowhere on a tap.
        return (
          <div key="prompt" data-testid="fleet-command-prompt">
            <SectionLabel>Send a fleet</SectionLabel>
            <p className="mt-1 text-sm text-ink-muted">
              Double-tap the map to set a destination, then send a fleet there.
            </p>
          </div>
        )
      case 'stop':
        // NO-SOFTLOCK: one click, no confirm; sortie rows get a non-actionable hint (server brake law).
        return (
          <div key="stop">
            <SectionLabel>Fleets in flight</SectionLabel>
            <div className="mt-1.5 space-y-1.5">
              {s.rows.map((f) => (
                <div key={f.groupId} className="flex items-center justify-between gap-2">
                  <span className="min-w-0">
                    <span className="block truncate text-sm text-ink">{f.name}</span>
                    <span className="text-xs text-ink-faint">{f.fleetCount} in flight</span>
                  </span>
                  {f.sortie !== null ? (
                    <span data-testid={`team-sortie-hint-${f.groupId}`} className="shrink-0 text-right text-xs text-ink-faint">
                      {f.sortie === 'outbound' ? 'On a hunt' : 'Returning'}
                    </span>
                  ) : (
                    // Word-economy: Stop is a compact icon button (■). aria-label + title keep it
                    // accessible and unambiguous. Still the safety brake — see BRAKE DECOUPLING below.
                    <Button
                      size="icon"
                      variant="warning"
                      data-testid={`team-stop-${f.groupId}`}
                      busy={stopBusy === `stop:${f.groupId}`}
                      busyLabel="…"
                      aria-label={`Stop ${f.name}`}
                      title="Stop — hold the fleet here"
                      // BRAKE DECOUPLING: the safety CTA answers ONLY to its own in-flight stop —
                      // never to `busy` (a pending go/dock/hunt must not disable the brake).
                      disabled={locks.stopDisabled || !f.canStop}
                      onClick={() =>
                        void runStop(
                          `stop:${f.groupId}`,
                          // The ONE unified brake (0209) — fleet_movement_unified_enabled is on in prod
                          // and the legacy per-member stop (0164) was retired with the signal cleanup.
                          () => commandShipGroupStop(f.groupId),
                          (res) => unifiedStopOutcomeMessage(f.name, res),
                        )
                      }
                    >
                      ■
                    </Button>
                  )}
                </div>
              ))}
            </div>
          </div>
        )
      case 'context':
        return (
          <div key="context" className="border-t border-edge/60 pt-2 first:border-t-0 first:pt-0">
            <SectionLabel>Destination</SectionLabel>
            {s.target.kind === 'point' ? (
              s.target.view.withinBounds ? (
                // Word-economy: the raw-coordinate preview is dropped — the on-map crosshair already
                // shows WHERE. "Open space" is the only label a player needs here.
                <p data-testid="fleet-go-target-readout" className="mt-1 text-sm font-medium text-ink">
                  Open space
                </p>
              ) : (
                // OOB mirror of 0208's RAW-point bound check — saves the doomed round-trip.
                <Notice tone="danger" data-testid="fleet-go-oob" className="mt-1">
                  That point lies outside charted space.
                </Notice>
              )
            ) : (
              <p data-testid="fleet-go-target-readout" className="mt-1 text-sm font-medium text-ink">
                {s.target.locationName}
              </p>
            )}
            <Button
              variant="ghost"
              size="sm"
              data-testid="fleet-go-clear"
              disabled={locks.verbDisabled}
              onClick={onClearTarget}
              className="mt-1.5 w-full"
            >
              Clear
            </Button>
          </div>
        )
      case 'go':
        return (
          <div key="go" className="space-y-1.5">
            {s.rows.map((r) => (
              <div key={r.groupId} className="flex items-center justify-between gap-2">
                <span className="min-w-0">
                  <span className="block truncate text-sm text-ink">{r.name}</span>
                </span>
                {r.wire === null ? (
                  // Badge takes no DOM attrs — the testid rides a wrapper span (Badge stays pure).
                  <span data-testid={r.action === 'already_here' ? `fleet-go-here-${r.groupId}` : undefined}>
                    <Badge>{r.action === 'already_here' ? 'Fleet is here' : 'Docked here'}</Badge>
                  </span>
                ) : (
                  <Button
                    size="sm"
                    variant="secondary"
                    data-testid={s.destination.kind === 'point' ? `fleet-go-${r.groupId}` : `team-go-${r.groupId}`}
                    busy={busy === `go:${r.groupId}`}
                    busyLabel="Sending…"
                    disabled={locks.verbDisabled}
                    onClick={() => {
                      const wire = r.wire
                      if (!wire) return
                      const dest = s.destination
                      void run(
                        `go:${r.groupId}`,
                        // The wire target is the model's — RAW point (raw-coords law) or {locationId}.
                        () => commandShipGroupGo(r.groupId, wire),
                        (res) => {
                          if (dest.kind === 'point') {
                            return fleetGoSuccessMessage({
                              fleetName: r.name,
                              shipCount: shipCount(res),
                              canonical: dest.view.canonical,
                              // The SERVER says whether a live leg was cancelled (0208 redirected).
                              redirected: res.redirected === true,
                            })
                          }
                          const n = shipCount(res)
                          const count = typeof n === 'number' ? ` — ${n} ship${n === 1 ? '' : 's'} —` : ''
                          return `${res.redirected === true ? 'Redirected' : 'Sent'} ${r.name}${count} to ${dest.locationName}.`
                        },
                      )
                    }}
                  >
                    {r.label}
                  </Button>
                )}
              </div>
            ))}
          </div>
        )
      case 'dock':
        return (
          <div key="dock" className="border-t border-edge/60 pt-2 first:border-t-0 first:pt-0">
            <SectionLabel>In orbit</SectionLabel>
            <div className="mt-1.5 space-y-1.5">
              {s.rows.map((r) => (
                <div key={r.groupId} className="flex items-center justify-between gap-2">
                  <span className="min-w-0">
                    <span className="block truncate text-sm text-ink">{r.name}</span>
                    <span className="text-xs text-ink-faint">in orbit of {r.portName}</span>
                  </span>
                  <Button
                    size="sm"
                    variant="secondary"
                    data-testid={`team-dock-${r.groupId}`}
                    busy={busy === `dock:${r.groupId}`}
                    busyLabel="Docking…"
                    disabled={locks.verbDisabled}
                    onClick={() =>
                      void run(
                        // THE S4 REPOINT (header): lit → the timed dock verb (server resolves the
                        // port from the territory — no client-asserted target); dark → the instant
                        // go-to-port, byte-identical to pre-S4.
                        `dock:${r.groupId}`,
                        () => (timedDockingEnabled ? commandShipGroupDock(r.groupId) : commandShipGroupGo(r.groupId, r.wire)),
                        () =>
                          timedDockingEnabled
                            ? `${r.name} is docking at ${r.portName}.`
                            : `Sent ${r.name} to dock at ${r.portName}.`,
                      )
                    }
                  >
                    Dock at {r.portName}
                  </Button>
                </div>
              ))}
            </div>
          </div>
        )
      case 'hunt':
        return (
          <div key="hunt" className="border-t border-edge/60 pt-2 first:border-t-0 first:pt-0">
            <div className="flex items-center justify-between gap-2">
              <SectionLabel>Hunt at {s.locationName}</SectionLabel>
              <Badge tone="danger">Combat</Badge>
            </div>
            <div className="mt-1.5 space-y-1.5">
              {s.rows.map((r) => {
                const armed = confirmHunt?.groupId === r.groupId && confirmHunt.locationId === s.locationId
                const picker = r.returnPicker
                const returnLocationId = picker ? (returnChoice[r.groupId] ?? picker.launchPortId) : null
                return (
                  <div key={r.groupId} className="rounded-lg border border-edge bg-surface-2/50 px-2.5 py-2">
                    <div className="flex items-center justify-between gap-2">
                      <span className="min-w-0">
                        <span className="block truncate text-sm text-ink">{r.name}</span>
                        <span className="text-xs text-ink-faint">
                          {r.memberCount} ship{r.memberCount === 1 ? '' : 's'}
                        </span>
                      </span>
                      <Button
                        size="sm"
                        variant="secondary"
                        disabled={locks.verbDisabled || !r.canHunt || armed || !r.cmdActive}
                        onClick={() => setConfirmHunt({ groupId: r.groupId, locationId: s.locationId })}
                      >
                        Hunt here
                      </Button>
                    </div>
                    {/* FLEET-CONTROL (0204): dark → cmdActive is always true and this never renders. */}
                    {r.memberCount > 0 && !r.cmdActive && (
                      <p className="mt-1 text-xs text-warning/90" data-testid={`team-inactive-${r.groupId}`}>
                        This fleet has no command ship — set one in the Fleets panel to move, send, or hunt.
                      </p>
                    )}
                    {r.readyHint && <p className="mt-1 text-xs text-ink-faint">{r.readyHint}</p>}
                    {/* RETURN-PORT (NO-HOME 0199): never forced back to origin — the launch port is
                        only the pre-selected convenience. */}
                    {picker && (
                      <div className="mt-1.5" data-testid={`team-hunt-return-${r.groupId}`}>
                        <label className="block text-xs text-ink-faint" htmlFor={`return-port-${r.groupId}`}>
                          Dock the fleet after the hunt at
                        </label>
                        <select
                          id={`return-port-${r.groupId}`}
                          data-testid="fleet-return-port-picker"
                          value={returnChoice[r.groupId] ?? picker.launchPortId}
                          onChange={(e) => setReturnChoice((c) => ({ ...c, [r.groupId]: e.target.value }))}
                          disabled={locks.verbDisabled}
                          aria-label={`Return port for ${r.name}`}
                          className="mt-1 rounded-lg border border-edge bg-surface-2 px-2 py-1 text-xs text-ink"
                        >
                          {picker.options.map((o) => (
                            <option key={o.id} value={o.id} data-testid={`fleet-return-port-option-${o.id}`}>
                              {o.id === picker.launchPortId ? `${o.name} (launch port)` : o.name}
                            </option>
                          ))}
                        </select>
                      </div>
                    )}
                    {armed && (
                      <Notice tone="danger" className="mt-2">
                        Confirm hunt? {r.name} commits to combat at {s.locationName}.
                        <span className="ml-2 inline-flex gap-1.5">
                          <Button
                            size="sm"
                            variant="danger"
                            busy={busy === `hunt:${r.groupId}`}
                            busyLabel="Sending…"
                            disabled={locks.verbDisabled || !r.canHunt || !r.cmdActive}
                            onClick={() =>
                              void run(
                                `hunt:${r.groupId}`,
                                () => sendShipGroupHunt(r.groupId, s.locationId, returnLocationId),
                                (res) => {
                                  const n = shipCount(res, r.memberCount)
                                  return `Sent ${r.name} — ${n} ship${n === 1 ? '' : 's'} — hunting at ${s.locationName}.`
                                },
                              ).then(() => setConfirmHunt(null))
                            }
                          >
                            Confirm hunt
                          </Button>
                          <Button size="sm" variant="ghost" disabled={locks.verbDisabled} onClick={() => setConfirmHunt(null)}>
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
  }

  // Stop (model-guaranteed FIRST when present) renders OUTSIDE the scroll container so it can never
  // scroll away; every later section shares the capped, scrollable body below it.
  const [first, ...rest] = model.sections
  const stopSection = first?.kind === 'stop' ? first : null
  const scrollable = stopSection ? rest : model.sections

  return (
    <OverlayPanel
      data-testid="fleet-command-panel"
      // Play-test move: the command surfaces live in the bottom-RIGHT corner, out of the map's
      // center. Rides MapScreen's bottom-right OverlayRail (shared with the pirate-intercept panel,
      // which stacks above it) — no self-positioning, so it omits `slot`.
      className="flex max-h-[45%] w-72 max-w-[calc(100vw-1.5rem)] flex-col"
    >
      {notice && (
        <Notice tone={notice.tone} className="mb-1.5 shrink-0">
          {notice.text}
        </Notice>
      )}
      {stopSection && <div className="shrink-0">{section(stopSection)}</div>}
      {scrollable.length > 0 && (
        <div className={`min-h-0 space-y-2 overflow-y-auto ${stopSection ? 'mt-2' : ''}`}>
          {scrollable.map(section)}
        </div>
      )}
    </OverlayPanel>
  )
}
