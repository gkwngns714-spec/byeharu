import { useState } from 'react'
import { Badge, Button, Notice, OverlayPanel, SectionLabel } from '../../components/ui'
import type { GroupRow } from '../command/teamRoster'
import { commandShipGroupGo, type TeamRpcResult, type UnifiedGroupFleetLite } from '../command/teamApi'
import { teamReasonMessage } from '../command/teamReasonMessage'
import {
  classifyFleetCoordinateGo,
  fleetGoButtonLabel,
  fleetGoRpcTarget,
  fleetGoSuccessMessage,
  formatWorldPoint,
  type FleetGoTargetView,
} from './fleetGoTarget'

// FLEET-GO 4a-2 — the fleet COORDINATE-GO confirm panel (charter §2a: tap a destination, ON THE MAP).
// The owner's headline surface: "move anywhere in open space" — the coordinate sibling of 4a-1's
// port-target rows in TeamMapSend, mounted by GalaxyMap in the top-right rail ONLY while the unified
// world owns open-space taps (resolveSpaceTapOwner === 'fleet') AND a target exists.
//
// PROPS-FED, NO fetches of its own: groups + unified fleets arrive from useGalaxyMapData's polled
// reads (already combat-excluded upstream), the target view from GalaxyMap's tap. The ONLY call out
// is the ONE unified mover wrapper (commandShipGroupGo), fed the RAW tapped point via fleetGoRpcTarget
// (0208 rounds to the integer grid server-side — the client must not pre-round the wire).
//
// Discipline = the TeamMapSend run() idiom verbatim: per-group busy key blocking double-submit,
// NON-optimistic (await the server, then onCommanded → the map refetch — TeamMapStop's onStopped
// precedent), rejects through the ONE teamReasonMessage copy map, success naming fleet + coordinate,
// try/finally so the panel never wedges. Per-group classification comes from the ONE pure classifier
// (classifyFleetCoordinateGo): 'already_here' renders a muted badge instead of a pointless no-op go
// (re-issuing a go to a fleet's own parked point; the server would run it as a harmless 5s
// zero-distance trip — min_travel_seconds floor — not raise, but it's still a wasted command).
//
// ⚠ DELIBERATE §2a DEVIATION, recorded: the charter's literal reading is "tap to redirect" — a bare
// re-tap re-routing the moving fleet. This surface instead requires tap (new point) + ONE click on
// the group's row ("Redirect fleet here"). Two reasons: (a) accidental-redirect hazard — every stray
// map tap would instantly re-route a committed fleet with no way to distinguish exploration from
// command; (b) N-group disambiguation — a bare tap cannot say WHICH of up to three fleets it
// commands. A go still CREATES commitment, so it keeps one explicit click (unlike the stop's
// zero-confirm recovery and the hunt's two-click combat gate).

export function FleetGoPanel({
  groups,
  unifiedFleets,
  view,
  onCommanded,
  onClear,
}: {
  groups: GroupRow[]
  /** The group fleets (combat-sortie rows already excluded upstream — the one-authority filter). */
  unifiedFleets: UnifiedGroupFleetLite[]
  view: FleetGoTargetView
  /** Fired after a confirmed go/redirect — the map refetch (TeamMapStop's onStopped precedent). */
  onCommanded: () => void
  onClear: () => void
}) {
  const [busy, setBusy] = useState<string | null>(null)
  const [notice, setNotice] = useState<{ tone: 'warning' | 'success'; text: string } | null>(null)

  const run = async (key: string, op: () => Promise<TeamRpcResult>, summarize: (res: TeamRpcResult & { ok: true }) => string) => {
    if (busy) return
    setBusy(key)
    setNotice(null)
    try {
      const res = await op()
      if (!res.ok) setNotice({ tone: 'warning', text: teamReasonMessage(res.reason) })
      else {
        setNotice({ tone: 'success', text: summarize(res) })
        onCommanded() // map reads (movements/fleets) — non-optimistic, the server already answered
      }
    } finally {
      setBusy(null) // never wedge the panel, even if a wrapper unexpectedly rejects
    }
  }

  return (
    <OverlayPanel tone="accent" data-testid="fleet-go-panel" className="w-56">
      <SectionLabel>Fleet destination</SectionLabel>
      {view.withinBounds ? (
        <>
          <p data-testid="fleet-go-target-readout" className="mt-1 text-xs text-ink">
            Destination: <span className="font-mono font-medium">{formatWorldPoint(view.canonical)}</span>
          </p>
          <p className="mt-0.5 text-[11px] text-ink-faint">
            Open-space point — the whole fleet travels here from wherever it is.
          </p>
          {notice && (
            <Notice tone={notice.tone} className="mt-1.5">
              {notice.text}
            </Notice>
          )}
          <div className="mt-2 space-y-1.5">
            {groups.map((g) => {
              // The group's ONE unified fleet (main_ship_id NULL + group_id — the 0207/0208 shape);
              // absent → bootstrap 'go' (0208 creates it). Server stays authoritative for everything
              // the client cannot see (member_busy, group_on_sortie, group_scattered, …).
              const fleet = unifiedFleets.find((f) => f.group_id === g.group_id) ?? null
              const intent = classifyFleetCoordinateGo(fleet, view.canonical)
              return (
                <div key={g.group_id} className="flex items-center justify-between gap-2">
                  <span className="min-w-0">
                    <span className="block truncate text-xs text-ink">{g.name}</span>
                  </span>
                  {intent === 'already_here' ? (
                    // Badge takes no DOM attrs — the testid rides a wrapper span (Badge stays pure).
                    <span data-testid={`fleet-go-here-${g.group_id}`}>
                      <Badge>Fleet is here</Badge>
                    </span>
                  ) : (
                    <Button
                      size="sm"
                      variant="secondary"
                      data-testid={`fleet-go-${g.group_id}`}
                      busy={busy === `go:${g.group_id}`}
                      busyLabel="Sending…"
                      disabled={busy !== null}
                      onClick={() =>
                        void run(
                          `go:${g.group_id}`,
                          // THE RAW-COORDS LAW: the wire carries the tapped point, not the preview.
                          () => commandShipGroupGo(g.group_id, fleetGoRpcTarget(view)),
                          (res) =>
                            fleetGoSuccessMessage({
                              fleetName: g.name,
                              shipCount: typeof res.member_count === 'number' ? res.member_count : undefined,
                              canonical: view.canonical,
                              // The SERVER says whether a live leg was cancelled (0208 redirected).
                              redirected: res.redirected === true,
                            }),
                        )
                      }
                    >
                      {fleetGoButtonLabel(intent)}
                    </Button>
                  )}
                </div>
              )
            })}
          </div>
          <Button
            variant="ghost"
            size="sm"
            data-testid="fleet-go-clear"
            disabled={busy !== null}
            onClick={onClear}
            className="mt-2 w-full"
          >
            Clear target
          </Button>
        </>
      ) : (
        // Out-of-bounds tap: the RAW point is what 0208 bound-checks, so this mirrors the server's
        // target_out_of_bounds verdict before a doomed round-trip. No marker renders for it either.
        <div className="mt-1">
          <Notice tone="danger" data-testid="fleet-go-oob">
            That point lies outside charted space.
          </Notice>
          <Button variant="secondary" size="sm" data-testid="fleet-go-clear" onClick={onClear} className="mt-2 w-full">
            Clear
          </Button>
        </div>
      )}
    </OverlayPanel>
  )
}
