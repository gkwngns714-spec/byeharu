import type { ReactNode } from 'react'
import { fleetLabel } from '../command/fleetLabel'
import {
  buildTeamRoster,
  commandFleetState,
  fleetPositionLocationLabel,
  type GroupRow,
  type RosterShip,
} from '../command/teamRoster'
import type { FleetPosition, MainShipRow } from '../map/mainshipApi'
import { renderShipVisual, shipGlyphFillsBox } from '../map/shipGlyph'
import { shipVisual } from '../map/shipVisual'
import type { MapLocation } from '../map/mapTypes'
import type { ShipFittingRow } from '../modules/modulesTypes'
import type { CaptainInstance } from '../captains/captainsTypes'
import { captainsForShip, fittingsForShip } from './shipDossierView'
import { shipMeterPair } from './meterPair'
import { MeterPairBars } from './MeterPairBars'
import { freshestShipStatus } from './shipRecovery'
import {
  Badge,
  CollapsibleCard,
  PageHeader,
  Screen,
  SectionLabel,
  Skeleton,
  screenRailClass,
  screenSplitClass,
} from '../../components/ui'

// ██ SIDE BY SIDE ██ — the Ships tab's layout, PROPS-ONLY (owner order 2026-08-04: "i want the
// ships of fleet info, and ship as individual info side by side on ships tab").
//
// WHAT IT WAS. Both surfaces already existed and both already lived on this tab — but STACKED in
// the SAME rail: ShipScreen rendered the fleet roster card, then <FittingDetail> underneath it, so
// picking a ship pushed the ship you were reading about below the entire fleet list. On the owner's
// live game that list is 5 ships across 2 fleets, so "which fleet is this ship in" and "what is on
// this ship" could not be read at once at any viewport width. The right-hand rail beside them held
// only the two dark captain panels, i.e. an empty column sat next to a doubly-tall one.
//
// WHAT CHANGED. Nothing was re-implemented. The two surfaces were moved into the TWO RAILS the
// design system already ships (screenSplitClass/screenRailClass — the ONE ops split Port/Mission/
// Fleet use): the fleet roster takes the narrow track, the selected ship takes the wide one. The
// per-ship detail is a SLOT (`detail`) — this file never renders a second ship dossier; ShipScreen
// passes the one <FittingDetail> that already existed, together with the captain panels that
// address the same selection and therefore belong in the same column as it.
//
// THE RESPONSIVE RULE (the whole point, because this game is played on a phone): the split is
// `flex-col` below lg and `flex-row` at lg and up. So it is side-by-side on a wide viewport and
// stacked — roster first, then the ship — on a narrow one. It is NEVER a horizontally scrolling
// page; tests/shipsSideBySide.uispec.ts MEASURES both claims in the DOM, at 1280px and at the
// 320px phone floor, and no layout claim here is made in prose alone.
//
// WHY THE ROSTER TAKES THE **NARROW** TRACK. The roster is the index; the ship panel is the
// content (modules, rooms, cargo, repair). The narrow track at lg is ~320px wide — exactly the
// phone floor this same file is proven to render at — so the list is provably not being squeezed
// into a width it has never survived.
//
// TRACK NAMES ARE WIDTHS, NOT RANKS: screenRailClass('main'|'aside') are the design system's 2fr
// and 1fr tracks. 'aside' here means "the 1fr column", not "the less important one".
//
// FOLDABLE (the owner's standing UI law: foldable/dismissible sections): the roster is a
// CollapsibleCard, so on a phone — where the two panels stack — the list can be folded away to put
// the selected ship at the top of the screen. Default open, and the choice persists.
//
// ONE AUTHORITY PER FACT, all COMPOSED, none re-derived here: grouping = buildTeamRoster;
// fleet naming = fleetLabel; per-ship location = fleetPositionLocationLabel; per-ship state =
// commandFleetState; freshest status = freshestShipStatus; the meters = shipMeterPair. This file
// contains no I/O and no arithmetic — ShipScreen owns every read.

export function ShipsView({
  loading,
  groups,
  rosterShips,
  shipRows,
  fleetPositions,
  locations,
  fittings,
  captains,
  selectedShipId,
  onSelectShip,
  detail,
}: {
  /** The shell's ship-list read is still in flight (roster shows its skeleton). */
  loading: boolean
  /** The owner's fleets (empty while the read is in flight or failed). */
  groups: GroupRow[]
  /** Every owned ship + its membership — the input to the ONE grouping fold. */
  rosterShips: RosterShip[]
  /** The condition rows (hull/shield/slots) keyed by ship, or null while the shared read is in flight. */
  shipRows: MainShipRow[] | null
  /** The ONE location projection (get_my_fleet_positions) — zero extra location reads. */
  fleetPositions: FleetPosition[]
  locations: MapLocation[]
  /** The whole server-lit fittings read, or null while dark (rows then show no module count). */
  fittings: ShipFittingRow[] | null
  /** The whole server-lit captains read, or null while dark. */
  captains: CaptainInstance[] | null
  selectedShipId: string | null
  onSelectShip: (mainShipId: string) => void
  /** The selected ship's own surfaces (FittingDetail + the panels that address the same ship).
   *  null when nothing is selected — the rail then self-collapses (`empty:hidden`) and the roster
   *  takes the full row, so an unselected screen shows no empty column. */
  detail: ReactNode
}) {
  // THE ONE grouping fold — the same one the Fleet tab uses. `ungrouped` IS the berthed set post-S1.
  const { teams, ungrouped } = buildTeamRoster(groups, rosterShips)
  // MAP-INTEGRATION n3 GUARD (carried over verbatim): a DANGLING group_id (a transient groups-read
  // failure collapses fetchMyShipGroups to []) must never be labeled "not in a fleet" — that is a
  // lie about a fleeted ship. Partition for display only.
  const berthedShips = ungrouped.filter((s) => s.group_id === null)
  const fleetUnresolved = ungrouped.filter((s) => s.group_id !== null)

  const posByShip = new Map(fleetPositions.map((p) => [p.main_ship_id, p]))
  const shipRowById = new Map((shipRows ?? []).map((r) => [r.main_ship_id, r]))

  // THE FLEET↔SHIP LINK. Side-by-side answers "which fleet is this ship in" by proximity on a wide
  // screen; stacked on a phone it does not, so the ship column names its fleet in one line. Read off
  // the SAME fold above — never a second membership lookup. Three honest outcomes:
  //   · in a resolved fleet → its name through the ONE naming rule;
  //   · group_id NULL       → the 0216 berth XOR, so "Not in a fleet" is a fact, not a guess;
  //   · dangling group_id   → UNKNOWN → null → the line is omitted. Silence over a false claim.
  const selectedFleetLine: string | null = (() => {
    if (selectedShipId === null) return null
    const inTeam = teams.find((t) => t.ships.some((s) => s.main_ship_id === selectedShipId))
    if (inTeam) return fleetLabel(inTeam.group.name)
    if (berthedShips.some((s) => s.main_ship_id === selectedShipId)) return 'Not in a fleet'
    return null
  })()

  // One roster row — READ-ONLY (composition lives on the Fleet tab; repair lives in the one repair
  // surface inside the detail). A row REPORTS: name, module count, state, location, condition,
  // captains. A destroyed hull is never filtered out — a wreck is real state the owner must see, and
  // it is how they reach the repair surface.
  const shipRow = (s: RosterShip) => {
    const selected = s.main_ship_id === selectedShipId
    const row = shipRowById.get(s.main_ship_id)
    const meters = row ? shipMeterPair(row) : null
    const isDisabled = freshestShipStatus(row, s) === 'destroyed'
    const locLabel = fleetPositionLocationLabel(posByShip.get(s.main_ship_id), locations)
    // No explicit `now` argument: the selector defaults it (react-hooks/purity forbids calling
    // Date.now during render, and TeamRosterPanel — the other caller — already omits it).
    const fleetState = commandFleetState(posByShip.get(s.main_ship_id), locations, s.status)
    const rowCaptains = captains ? captainsForShip(captains, s.main_ship_id) : null
    const fittedCount = fittings ? fittingsForShip(fittings, s.main_ship_id).length : null
    const pick = () => onSelectShip(s.main_ship_id)
    return (
      <div
        key={s.main_ship_id}
        role="button"
        tabIndex={0}
        aria-pressed={selected}
        data-testid={`fitting-row-${s.main_ship_id}`}
        onClick={pick}
        onKeyDown={(e) => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault()
            pick()
          }
        }}
        className={`cursor-pointer rounded-lg border px-3 py-2 transition-colors ${
          selected
            ? 'border-accent bg-accent-soft'
            : 'border-edge bg-surface hover:border-accent/40 hover:bg-accent-soft'
        }`}
      >
        <div className="flex items-center justify-between">
          {/* THE SHIP ITSELF — the SAME visual the map draws, from the SAME authority (map/shipVisual,
              rendered by map/shipGlyph). The roster is where the owner will look for their spaceship
              art once they add it ("it will be different when i add a space ship image"), and adding
              it must not mean touching this file: the form arrives on the descriptor, so an `image`
              arm renders here unchanged. `hull_type_id` and `max_hp` come off the condition row this
              screen ALREADY reads — no new fetch, and no hull-catalog read. */}
          <span className={`flex min-w-0 items-center gap-2 ${selected ? 'text-ink' : 'text-ink-muted'}`}>
            {(() => {
              const v = shipVisual({
                typeId: row?.hull_type_id ?? null,
                side: 'player',
                kind: 'unit',
                mass: row?.max_hp ?? null,
                hpFrac: row && row.max_hp > 0 ? row.hp / row.max_hp : null,
              })
              return (
                <svg
                  data-testid={`fitting-row-ship-${s.main_ship_id}`}
                  viewBox="0 0 24 24"
                  width={18}
                  height={18}
                  aria-hidden="true"
                  className="shrink-0"
                >
                  {renderShipVisual(v, shipGlyphFillsBox(v))}
                </svg>
              )
            })()}
            <span className="truncate text-sm">{s.name}</span>
          </span>
          <span className="ml-3 flex shrink-0 items-center gap-2">
            {fittedCount !== null && fittedCount > 0 && (
              <span
                data-testid={`fitting-row-modules-${s.main_ship_id}`}
                className="inline-flex items-baseline gap-1 rounded border border-edge bg-surface-2 px-1.5 py-0.5 text-[10px]"
              >
                <span className="text-ink-faint">Modules</span>
                <span className="font-mono tabular-nums text-ink">{fittedCount}</span>
              </span>
            )}
            {/* The "Selected" word-badge that used to sit here is GONE. In the narrow index column
                it cost ~60px of the row — the same 60px the ship's NAME needs — to repeat what the
                accent border, the accent fill and aria-pressed already say. Decoration lost to
                information. */}
            <Badge tone={fleetState.tone}>{fleetState.label}</Badge>
          </span>
        </div>
        {/* LOCATION — the ONE read. A missing/hidden projection row says so rather than guessing. */}
        <p data-testid={`fitting-row-location-${s.main_ship_id}`} className="mt-0.5 text-[11px] text-ink-muted">
          {locLabel ?? 'Location unavailable'}
        </p>
        {/* CONDITION — the shared shield/hull pair (shield row data-gated inside). */}
        {meters && (
          <div className="mt-1.5">
            <MeterPairBars pair={meters} hullTone={isDisabled ? 'danger' : meters.hull.pct < 100 ? 'accent' : 'success'} />
          </div>
        )}
        {rowCaptains && rowCaptains.length > 0 && (
          <p data-testid={`fitting-row-captains-${s.main_ship_id}`} className="mt-1 truncate text-[10px] text-ink-faint">
            Captains · {rowCaptains.map((c) => c.name).join(', ')}
          </p>
        )}
      </div>
    )
  }

  return (
    <Screen wide>
      <PageHeader eyebrow="Ops · Ships" title="Ships" subtitle="Your fleets, and the ship you pick" />
      <div className={screenSplitClass()} data-testid="ships-split">
        {/* ── THE FLEET COLUMN — what the fleets are and which ships are in them. */}
        <div data-testid="ships-fleet-rail" className={screenRailClass('aside')}>
          <CollapsibleCard
            data-testid="fitting-roster"
            /* Not "Ships": the page header already says that, and a card titled the same as its
               page is the "FLEET 1 · FLEET 1" defect in another costume. This column IS the fleets. */
            title="Fleets"
            subtitle="Pick a ship · membership on the Fleet tab"
            storageKey="ships.roster"
          >
            {shipRows === null || loading ? (
              <div aria-busy="true">
                <Skeleton className="h-8 w-32 rounded-lg" />
                <Skeleton className="mt-3 h-16 w-full rounded-lg" />
                <span className="sr-only">Loading the roster…</span>
              </div>
            ) : (
              <div className="space-y-4">
                {teams.map(({ group, ships: members }) => (
                  <div key={group.group_id} data-testid={`fitting-fleet-${group.group_id}`}>
                    <SectionLabel>
                      {/* THE ONE NAMING RULE (command/fleetLabel), COMPOSED — never a hand-built
                          prefix, and never the slot index beside the name (that printed
                          "FLEET 1 · FLEET 1 · 4 SHIPS" on the live game, 2026-08-04). */}
                      {fleetLabel(group.name)} · {members.length} ship{members.length === 1 ? '' : 's'}
                    </SectionLabel>
                    {members.length > 0 ? (
                      <div className="mt-1.5 space-y-1.5">{members.map(shipRow)}</div>
                    ) : (
                      <p className="mt-1.5 text-xs text-ink-faint">No ships in this fleet.</p>
                    )}
                  </div>
                ))}
                {/* n3 GUARD — a dangling group_id gets an honest heading, never the berth claim. */}
                {fleetUnresolved.length > 0 && (
                  <div data-testid="fitting-fleet-unresolved">
                    <SectionLabel>In a fleet — fleet details unavailable</SectionLabel>
                    <div className="mt-1.5 space-y-1.5">{fleetUnresolved.map(shipRow)}</div>
                  </div>
                )}
                {/* THE BERTHED BUCKET — group_id NULL ⇔ berthed at a port (the 0216 XOR). */}
                <div data-testid="fitting-berthed">
                  <SectionLabel>Docked — not in a fleet</SectionLabel>
                  {berthedShips.length > 0 ? (
                    <div className="mt-1.5 space-y-1.5">{berthedShips.map(shipRow)}</div>
                  ) : (
                    <p data-testid="fitting-berthed-empty" className="mt-1.5 text-xs text-ink-faint">
                      Every ship is with a fleet.
                    </p>
                  )}
                </div>
              </div>
            )}
          </CollapsibleCard>
        </div>
        {/* ── THE SHIP COLUMN — the one selected ship, beside the fleet it belongs to. Self-collapses
            when nothing is selected AND every panel inside it is dark, so no empty column ever
            shows (the `empty:hidden` rail posture: element children only). */}
        <div data-testid="ships-ship-rail" className={screenRailClass('main')}>
          {selectedFleetLine && (
            <p data-testid="ships-selected-fleet" className="text-xs text-ink-muted">
              {selectedFleetLine}
            </p>
          )}
          {detail}
        </div>
      </div>
    </Screen>
  )
}
