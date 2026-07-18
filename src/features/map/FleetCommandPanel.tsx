import { useState } from 'react'
import { Badge, Button, Notice, OverlayPanel, SectionLabel } from '../../components/ui'
import {
  commandShipGroupGo,
  commandShipGroupStop,
  sendShipGroupHunt,
  stopShipGroup,
  type TeamRpcResult,
} from '../command/teamApi'
import { teamReasonMessage } from '../command/teamReasonMessage'
import { stopOutcomeMessage, unifiedStopOutcomeMessage } from '../command/teamStop'
import { fleetGoSuccessMessage, formatWorldPoint } from './fleetGoTarget'
import {
  buildFleetCommandModel,
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
// polled reads. ONE busy/notice pair, ONE run() (the FleetGoPanel.tsx idiom verbatim), namespaced
// busy keys (stop:/go:/dock:/hunt:) — one in-flight command at a time.
//
// NO-SOFTLOCK: the stop section is model-guaranteed FIRST and target-independent, and it renders
// OUTSIDE the internal scroll container below, so the brake can never scroll away and never hides
// behind a target/selection gate. Stop stays ONE CLICK, no confirm (the TeamMapStop law: a stop is
// the recovery FROM a commitment; a confirm in front of the brake is a hazard, not a safeguard).
//
// ⚠ DOCK v1 — S4 REPOINT MARKER: the Dock row submits the EXISTING instant mover
// (commandShipGroupGo(gid, { locationId: orbit.id }) — arrival docks via 0208's location branch).
// When S4/timed_docking lands (NOT merged — a later slice), ONLY this submit repoints to the dock
// RPC (+ a countdown); the shell, the model's dock-row derivation, and every other section stand.
//
// HUNT — absorbed from TeamMapSend VERBATIM so no second command surface survives: two-click armed
// confirm carrying the location id it was armed FOR (switching targets disarms by derivation), the
// groupHuntAvailability mirror, and the NO-HOME return-port picker (never forced back to origin).

export function FleetCommandPanel({
  onCommanded,
  onClearTarget,
  ...inputs
}: FleetCommandModelInput & {
  /** Fired after any confirmed command — the shell refetch (non-optimistic, the house discipline). */
  onCommanded: () => void
  /** Clears the live target (point AND port selection) — the model re-derives to no target. */
  onClearTarget: () => void
}) {
  const [busy, setBusy] = useState<string | null>(null)
  const [notice, setNotice] = useState<{ tone: 'warning' | 'success'; text: string } | null>(null)
  // armed hunt confirm — carries the location it was armed for (stale-destination disarm by derivation)
  const [confirmHunt, setConfirmHunt] = useState<{ groupId: string; locationId: string } | null>(null)
  // RETURN-PORT (NO-HOME 0199): the player's chosen dock-after-hunt port, per fleet.
  const [returnChoice, setReturnChoice] = useState<Record<string, string>>({})

  const model = buildFleetCommandModel(inputs)
  if (!model.mount) return null

  const run = async (key: string, op: () => Promise<TeamRpcResult>, summarize: (res: TeamRpcResult & { ok: true }) => string) => {
    if (busy) return
    setBusy(key)
    setNotice(null)
    try {
      const res = await op()
      if (!res.ok) setNotice({ tone: 'warning', text: teamReasonMessage(res.reason) })
      else {
        setNotice({ tone: 'success', text: summarize(res) })
        onCommanded() // shell reads (movements/fleets/ships) — non-optimistic, the server answered
      }
    } finally {
      setBusy(null) // never wedge the panel, even if a wrapper unexpectedly rejects
    }
  }

  const shipCount = (res: TeamRpcResult & { ok: true }, fallback?: number): number | undefined =>
    typeof res.member_count === 'number' ? res.member_count : fallback

  const section = (s: FleetCommandSection) => {
    switch (s.kind) {
      case 'stop':
        // NO-SOFTLOCK: one click, no confirm; sortie rows get a non-actionable hint (server brake law).
        return (
          <div key="stop">
            <SectionLabel>Fleets in flight</SectionLabel>
            <div className="mt-1.5 space-y-1.5">
              {s.rows.map((f) => (
                <div key={f.groupId} className="flex items-center justify-between gap-2">
                  <span className="min-w-0">
                    <span className="block truncate text-xs text-ink">{f.name}</span>
                    <span className="text-[10px] text-ink-faint">
                      {f.fleetCount} ship{f.fleetCount === 1 ? '' : 's'} in flight
                    </span>
                  </span>
                  {f.sortie !== null ? (
                    <span data-testid={`team-sortie-hint-${f.groupId}`} className="shrink-0 text-right text-[10px] text-ink-faint">
                      {f.sortie === 'outbound' ? 'On a hunt — committed until arrival' : 'Returning from a hunt'}
                    </span>
                  ) : (
                    <Button
                      size="sm"
                      variant="warning"
                      data-testid={`team-stop-${f.groupId}`}
                      busy={busy === `stop:${f.groupId}`}
                      busyLabel="Stopping…"
                      disabled={busy !== null || !f.canStop}
                      onClick={() =>
                        void run(
                          `stop:${f.groupId}`,
                          // LIT → the ONE unified brake (0209); DARK → the legacy per-member loop (0164).
                          () => (inputs.unifiedEnabled ? commandShipGroupStop(f.groupId) : stopShipGroup(f.groupId)),
                          // Each arm parses ITS OWN envelope: 0209's `stopped` is a boolean, 0164's a
                          // count — the parsers stay TWO (spec-pinned in teamStop.spec).
                          (res) => (inputs.unifiedEnabled ? unifiedStopOutcomeMessage(f.name, res) : stopOutcomeMessage(f.name, res)),
                        )
                      }
                    >
                      Stop — hold here
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
            {s.target.kind === 'point' ? (
              s.target.view.withinBounds ? (
                <>
                  <p data-testid="fleet-go-target-readout" className="text-xs text-ink">
                    Destination: <span className="font-mono font-medium">{formatWorldPoint(s.target.view.canonical)}</span>
                  </p>
                  <p className="mt-0.5 text-[11px] text-ink-faint">
                    Open-space point — the whole fleet travels here from wherever it is.
                  </p>
                </>
              ) : (
                // OOB mirror of 0208's RAW-point bound check — saves the doomed round-trip.
                <Notice tone="danger" data-testid="fleet-go-oob">
                  That point lies outside charted space.
                </Notice>
              )
            ) : (
              <p data-testid="fleet-go-target-readout" className="text-xs text-ink">
                Destination: <span className="font-medium">{s.target.locationName}</span>
              </p>
            )}
            <Button
              variant="ghost"
              size="sm"
              data-testid="fleet-go-clear"
              disabled={busy !== null}
              onClick={onClearTarget}
              className="mt-1.5 w-full"
            >
              Clear target
            </Button>
          </div>
        )
      case 'go':
        return (
          <div key="go" className="space-y-1.5">
            {s.rows.map((r) => (
              <div key={r.groupId} className="flex items-center justify-between gap-2">
                <span className="min-w-0">
                  <span className="block truncate text-xs text-ink">{r.name}</span>
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
                    disabled={busy !== null}
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
                    <span className="block truncate text-xs text-ink">{r.name}</span>
                    <span className="text-[10px] text-ink-faint">in orbit of {r.portName}</span>
                  </span>
                  <Button
                    size="sm"
                    variant="secondary"
                    data-testid={`team-dock-${r.groupId}`}
                    busy={busy === `dock:${r.groupId}`}
                    busyLabel="Docking…"
                    disabled={busy !== null}
                    onClick={() =>
                      void run(
                        // DOCK v1 (S4 repoint marker in the header): the existing instant go-to-port.
                        `dock:${r.groupId}`,
                        () => commandShipGroupGo(r.groupId, r.wire),
                        () => `Sent ${r.name} to dock at ${r.portName}.`,
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
                        <span className="block truncate text-xs text-ink">{r.name}</span>
                        <span className="text-[10px] text-ink-faint">
                          {r.memberCount} ship{r.memberCount === 1 ? '' : 's'}
                        </span>
                      </span>
                      <Button
                        size="sm"
                        variant="secondary"
                        disabled={busy !== null || !r.canHunt || armed || !r.cmdActive}
                        onClick={() => setConfirmHunt({ groupId: r.groupId, locationId: s.locationId })}
                      >
                        Hunt here
                      </Button>
                    </div>
                    {/* FLEET-CONTROL (0204): dark → cmdActive is always true and this never renders. */}
                    {r.memberCount > 0 && !r.cmdActive && (
                      <p className="mt-1 text-[10px] text-warning/90" data-testid={`team-inactive-${r.groupId}`}>
                        This fleet has no command ship — set one in the Fleets panel to move, send, or hunt.
                      </p>
                    )}
                    {r.readyHint && <p className="mt-1 text-[10px] text-ink-faint">{r.readyHint}</p>}
                    {/* RETURN-PORT (NO-HOME 0199): never forced back to origin — the launch port is
                        only the pre-selected convenience. */}
                    {picker && (
                      <div className="mt-1.5" data-testid={`team-hunt-return-${r.groupId}`}>
                        <label className="block text-[10px] text-ink-faint" htmlFor={`return-port-${r.groupId}`}>
                          Dock the fleet after the hunt at
                        </label>
                        <select
                          id={`return-port-${r.groupId}`}
                          data-testid="fleet-return-port-picker"
                          value={returnChoice[r.groupId] ?? picker.launchPortId}
                          onChange={(e) => setReturnChoice((c) => ({ ...c, [r.groupId]: e.target.value }))}
                          disabled={busy !== null}
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
                            disabled={busy !== null || !r.canHunt || !r.cmdActive}
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
  }

  // Stop (model-guaranteed FIRST when present) renders OUTSIDE the scroll container so it can never
  // scroll away; every later section shares the capped, scrollable body below it.
  const [first, ...rest] = model.sections
  const stopSection = first?.kind === 'stop' ? first : null
  const scrollable = stopSection ? rest : model.sections

  return (
    <OverlayPanel
      data-testid="fleet-command-panel"
      slot="bottom-center"
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
