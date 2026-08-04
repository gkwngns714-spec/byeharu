import { useEffect, useState } from 'react'
import { Badge, Button, Collapsible, OverlayPanel, StatRow } from '../../components/ui'
import { teamReasonMessage } from '../command/teamReasonMessage'
import { resolveStoppableFleets } from '../command/teamStop'
import { RetreatControl } from '../combat/RetreatControl'
import { buildFleetStatusModel, type FleetStatusModelInput, type FleetStatusRow } from './fleetStatusModel'

// ██ THE FLEET READOUT ON THE MAP — where each fleet is, what it is doing, and the fight control. ██
//
// Owner, playing, 2026-08-04: "in map, i want to see information regarding fleet, where it is, stats,
// what it is currently doing. I am in snare but in no fight is occuring, i want also a toggle combat
// on map as well when i arrive at the combat zone on the fleet information on map"
//
// PROPS-FED AND DECIDES NOTHING (the FleetCommandPanel law). Every phrase, every stat, every refusal
// and the single action per fleet come from the ONE pure model (map/fleetStatusModel — spec-pinned),
// which itself only composes proven authorities. The only state this file owns is a clock, and only
// while a fleet is actually in flight — the TeamMovingMarkers idiom, for the same reason: an ETA that
// re-reads `Date.now()` in the render body is impure, and one that ticks while nothing is travelling
// re-renders the map for no one.
//
// ── WHERE IT SITS, AND WHY ─────────────────────────────────────────────────────────────────────────
// The top-left rail, the map's INFORMATION corner (alerts, the exploration panel, the combat card) —
// never the centre, which is the owner's standing map-UX law, and never a corner that already owns a
// gesture (zoom is top-right, the map key bottom-left, the command hub bottom-right). It is FOLDABLE
// and remembers the choice, so a player who wants a clean map gets one and keeps it; a player with no
// fleets sees nothing at all.
//
// ── ONE ACTION SLOT, TWO STATES — the owner's "toggle" ─────────────────────────────────────────────
// A fleet standing in a zone that wraps a huntable site is offered the SITE (a zone is not a target —
// howAFightStarts). The button SUBMITS NOTHING: it hands the location id to the map's own marker
// selection, exactly as tapping that marker would, which opens the EXISTING hunt control with its
// armed confirm and its return-port picker. So there is still exactly ONE hunt call site in the whole
// client, and this is not it (tests/howAFightStarts.spec.ts proves it stays that way).
//
// A fleet already fighting gets the way OUT instead, and it is the ONE RetreatControl — the same
// component the mission panel and the map's combat card mount. Retreat and auto-exit are
// owner-preserved design; this adds a third way IN to that control and no way around it.
//
// ── WHAT IT DELIBERATELY DOES NOT SHOW ─────────────────────────────────────────────────────────────
// The fight's NUMBERS. Hull bars, the last exchange, the auto-retreat line and the reposition
// distance are all already on this screen, on CombatMapCard, from these same server rows. A second
// rendering of them three inches away would be the duplication this slice exists to avoid — so the
// row states the fight's phase and lets the card carry the detail. The stats that are refused
// outright (the five dormant fold outputs, the deprecated integer cargo, any client-folded power or
// speed) are enumerated in the model's header with the ruling behind each.

export function FleetStatusPanel({
  onSelectHuntSite,
  onCombatChanged,
  ...inputs
}: Omit<FleetStatusModelInput, 'nowMs'> & {
  /** Select a hunt SITE by id — the map's OWN marker-selection path (MapScreen.handleSelect), the
   *  very one a tap on that marker takes. Not a command: it opens the existing hunt control. */
  onSelectHuntSite: (locationId: string) => void
  /** Re-poll after a retreat order lands, so the row shows the new phase on the next frame. */
  onCombatChanged: () => void
  /** Test seam ONLY: a fixed clock, so a rendered-DOM proof can assert an exact countdown instead of
   *  racing one. Absent in the app, where the 1s tick below owns the time. */
  nowMs?: number
}) {
  // Is anything actually travelling? Decided CLOCK-FREE from the movement rows, by the SAME lead-leg
  // rule the model and the Stop section use — so the tick below exists exactly when an ETA does.
  const anyInFlight = resolveStoppableFleets(inputs.movements, inputs.groups).length > 0
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    if (!anyInFlight) return
    const iv = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(iv)
  }, [anyInFlight])

  const model = buildFleetStatusModel({ ...inputs, nowMs: inputs.nowMs ?? now })
  // Clean map, law #1: nothing to say → nothing rendered.
  if (model.rows.length === 0) return null

  return (
    <OverlayPanel data-testid="fleet-status-panel" className="w-72 max-w-full">
      <Collapsible
        data-testid="fleet-status-fold"
        // A STABLE SECTION id (never a per-fleet one) — the collapsibleState convention.
        storageKey="map-fleet-status"
        // Open by default: the owner asked to SEE this, and a fold they have to find first is the
        // same dead end as no panel. Their choice is remembered from the first tap onward.
        defaultOpen
        headerClassName="min-h-11"
        contentClassName="mt-1.5 flex flex-col gap-1.5"
        header={
          <span className="flex min-w-0 flex-1 items-center justify-between gap-2">
            <span className="text-xs font-semibold uppercase tracking-wide text-ink-muted">Fleets</span>
            <Badge>{model.rows.length}</Badge>
          </span>
        }
      >
        {model.rows.map((r) => (
          <FleetStatusCard
            key={r.groupId}
            row={r}
            onSelectHuntSite={onSelectHuntSite}
            onCombatChanged={onCombatChanged}
          />
        ))}
      </Collapsible>
    </OverlayPanel>
  )
}

function FleetStatusCard({
  row,
  onSelectHuntSite,
  onCombatChanged,
}: {
  row: FleetStatusRow
  onSelectHuntSite: (locationId: string) => void
  onCombatChanged: () => void
}) {
  // Bound once so the narrowed union survives into the click handler's closure.
  const action = row.action
  return (
    <div
      data-testid={`fleet-status-${row.groupId}`}
      className="rounded-lg border border-edge bg-surface-2/50 px-2 py-1.5"
    >
      {/* IDENTITY → WHERE → WHAT IT IS DOING. Three lines, in the order the question is asked. */}
      <p className="truncate text-sm font-medium text-ink">{row.name}</p>
      <p data-testid={`fleet-status-where-${row.groupId}`} className="text-xs text-ink-muted">
        {row.where}
      </p>
      <p data-testid={`fleet-status-doing-${row.groupId}`} className="text-xs text-ink-faint">
        {row.doing}
      </p>

      {/* STATS — only what something in the game reads (see fleetStatusModel's header). */}
      <dl data-testid={`fleet-status-stats-${row.groupId}`} className="mt-1 space-y-0.5 text-xs">
        {row.stats.map((s) => (
          <StatRow key={s.label} label={s.label} value={<span className="font-mono tabular-nums">{s.value}</span>} />
        ))}
      </dl>

      {/* WHY IT CANNOT ACT — the SERVER's own sentence for the refusal the client can already prove,
          through the ONE reject-copy map. A disabled control with no reason is what cost the owner a
          whole day; this is the reason, before the attempt, with the fix named in it. */}
      {row.blockedReason && (
        <p data-testid={`fleet-status-blocked-${row.groupId}`} className="mt-1 text-xs text-warning">
          {teamReasonMessage(row.blockedReason)}
        </p>
      )}

      {/* THE ONE ACTION SLOT — into the fight under its feet, or out of the one it is in. */}
      {action?.kind === 'hunt' && (
        <Button
          size="sm"
          variant="danger"
          data-testid={`fleet-status-hunt-${row.groupId}`}
          className="mt-1.5 min-h-11 w-full"
          onClick={() => onSelectHuntSite(action.locationId)}
        >
          {action.label}
        </Button>
      )}
      {action?.kind === 'retreat' && (
        <RetreatControl
          presenceId={action.presenceId}
          retreating={action.retreating}
          onChanged={onCombatChanged}
          // The wrapper takes the class, so the 44px touch floor is asked of the button INSIDE it —
          // RetreatControl stays the one component, unchanged, with one more mount.
          className="mt-1.5 [&_button]:min-h-11 [&_button]:w-full"
          testId={`fleet-status-retreat-${row.groupId}`}
        />
      )}
    </div>
  )
}
