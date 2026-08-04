import { useCallback, useEffect, useReducer, useState } from 'react'
import { Link } from 'react-router-dom'
import { useShellState } from '../../app/shellState'
import { fetchHullTypes, fetchMyMainShips, type HullRow, type MainShipRow } from '../map/mainshipApi'
import { getMyShipFittings } from '../modules/modulesApi'
import type { GetMyShipFittingsResult } from '../modules/modulesTypes'
import { getMyCaptainInstances } from '../captains/captainsApi'
import type { GetMyCaptainInstancesResult } from '../captains/captainsTypes'
import { fetchMyShipGroups, fetchMyShipGroupMap, type ShipGroupMapEntry } from '../command/teamApi'
import type { GroupRow, RosterShip } from '../command/teamRoster'
import { isServerLit, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { captainsForShip } from './shipDossierView'
import { FittingDetail } from './FittingDetail'
import { ShipsView } from './ShipsView'
import { type DisabledShipRow } from './shipRecovery'
import { fetchMyDisabledShips } from './shipRecoveryApi'
import { CaptainsPanel } from '../captains/CaptainsPanel'
import { RecruitCaptainPanel } from '../captains/RecruitCaptainPanel'
import { Button, EmptyState, Icon, PageHeader, Screen, buttonClasses } from '../../components/ui'

// S6 — the FITTING tab (rebuilt from the old Ship tab; ShipStatusCard + ShipDossier + ShipSwitcher
// are RETIRED, not shipped alongside). The destination answers "what is ON each of my ships, and
// where is it" — ships grouped BY FLEET plus the "Berthed — not in a fleet" bucket, each row
// showing location / condition / captains, and a per-ship fitting detail on selection.
//
// SIDE BY SIDE (owner order 2026-08-04: "i want the ships of fleet info, and ship as individual
// info side by side on ships tab"). THIS FILE OWNS THE READS AND NOTHING ELSE — the layout, the
// roster markup and the fleet↔ship link are ShipsView (props-only, so tests/shipsSideBySide.uispec.ts
// can MEASURE the rendered columns), the AssetsScreen/AssetsLedgerView split. Nothing was
// duplicated in the move: the roster markup left this file, and the per-ship surface is still the
// ONE <FittingDetail> that already existed, handed to the view as its ship-column slot together
// with the captain panels that address the same selection.
//
// BOUNDARY (charter §2a; FLEET-TAB moved the composition home): the FLEET tab owns fleet
// COMPOSITION (create/rename/delete fleet, add/remove ship, command-ship toggle —
// TeamRosterPanel); this screen renders the grouping READ-ONLY through
// the SAME pure fold (buildTeamRoster — never a second grouping implementation) with ZERO
// membership and ZERO movement controls. Fitting owns per-ship EQUIPMENT + CONDITION (modules,
// rename, repair, rooms, captains-at-the-ship, trade cargo, traits/buffs); the fleet HOLD moved to
// the Assets tab (ASSETS-TAB), because it was never per-ship and reaching it via a ship said it was.
//
// ONE READ PER FACT:
//   · LOCATION — solely map.fleetPositions (the shell's already-polled get_my_fleet_positions
//     projection; fleeted → the fleet's place, berthed → the S1 'berthed' place at the berth
//     port). ZERO new location/dockedness queries; the old sole-ship mainShipFleet+movements
//     derivation this screen carried is DELETED with ShipStatusCard. An empty projection (both
//     movement gates dark) shows "Location unavailable" — honest, never a guess.
//   · GROUPING — buildTeamRoster over the shell ship list × the membership map. Post-S1 the
//     `ungrouped` bucket IS the berthed set (the 0216 XOR: group_id NULL ⇔ berth set).
//   · SELECTION — the shell's ONE selection (selection.selectShip); no local selected-ship state.
//
// ONE REPAIR SURFACE: this screen renders NO repair action of its own. It used to carry two — a
// Repair/Tow block on every destroyed roster ROW, and the commands behind the detail's free
// recovery block — so a selected wreck put two repair buttons on screen at once for one ship. Both
// are gone. This screen now supplies repair with FACTS only (the fetchMyDisabledShips readiness
// read, riding the same batched wave) and RepairPanel owns the concept end to end: both position
// reads, both commands, one vocabulary. A wreck's row still SHOWS it is wrecked (danger hull meter
// + the "Disabled" status badge) and selecting the row — the roster's whole purpose — opens the one
// surface directly beneath it. NO-SOFTLOCK is intact: recovery is never hidden, never flag-gated,
// and never more than a row click away.
//
// Fan-out (the brief's measured budget): the shared roster facts are ~6 requests total regardless
// of ship count (ships 1 + groups 1 + group-map 2 + fittings 1 + captains 1; location costs 0 —
// already polled). The per-ship dossier surfaces load ONLY in the selected ship's detail. No new
// server RPC.

export function ShipScreen() {
  const { game, map, selection } = useShellState()
  // (4C-CLIENT: the legacy spatial_state / space-movement fields left the key with the schema they read.)
  const lifecycleKey = `${map.mainShip?.status ?? 'n'}`
  // Bumped by any panel after a successful loadout-changing command (captain assign/recruit on the
  // aside, fit/unfit in the detail) so the read surfaces re-read the state the command just changed
  // (non-optimistic: the command's own refetch ran first, then pinged us).
  const [loadoutRev, bumpLoadoutRev] = useReducer((n: number) => n + 1, 0)
  const readRefreshKey = `${lifecycleKey}|r${loadoutRev}`

  // ── the shared roster facts (one batched wave; re-read on lifecycle/loadout changes) ───────────
  const [ships, setShips] = useState<MainShipRow[] | null>(null)
  const [groups, setGroups] = useState<GroupRow[]>([])
  const [groupMap, setGroupMap] = useState<Record<string, ShipGroupMapEntry>>({})
  const [fittingsRes, setFittingsRes] = useState<GetMyShipFittingsResult | null>(null)
  const [captainsRes, setCaptainsRes] = useState<GetMyCaptainInstancesResult | null>(null)
  // 0297 RECOVERY — where each disabled ship is (null = read unavailable → the gate fails OPEN and
  // still offers Repair). A plain FACT threaded to the one repair surface; this screen holds no
  // repair/tow command state, because it issues neither.
  const [disabledShips, setDisabledShips] = useState<DisabledShipRow[] | null>(null)
  // The hull catalog (public-read Reference/Config) — fetched ONCE per mount (static data), so
  // every ship's class name resolves from ITS OWN hull_type_id. REVIEW FIX (S6 major 1): the
  // first cut read game.mainShip.hull — the NO-ID sole-ship view, which at N≥2 fail-closes to the
  // starter-frigate teaser and would wear the WRONG class on every non-starter ship.
  const [hullTypes, setHullTypes] = useState<HullRow[]>([])

  // Only the mounted guard is needed now: this screen issues no commands (the one repair surface
  // owns the repair/tow claims), it only batches reads.
  const { activeRef } = useActivityPanelGuards()

  const refreshShared = useCallback(async () => {
    const [myShips, g, m, fit, cap, disabled] = await Promise.all([
      fetchMyMainShips(),
      fetchMyShipGroups(),
      fetchMyShipGroupMap(),
      getMyShipFittings(),
      getMyCaptainInstances(),
      // 0297: the recovery readiness of every disabled ship — rides the SAME batched wave (one more
      // owner-read, no new poll). null on error/pre-deploy → the gate degrades to 'unknown'.
      fetchMyDisabledShips(),
    ])
    if (!activeRef.current) return
    setShips(myShips)
    setGroups(g)
    setGroupMap(m)
    setFittingsRes(fit)
    setCaptainsRes(cap)
    setDisabledShips(disabled)
  }, [activeRef])

  // readRefreshKey is a deliberate re-fetch trigger (the ShipDossier dep idiom).
  useEffect(() => {
    void refreshShared()
  }, [refreshShared, readRefreshKey])

  // Static hull catalog — once per mount (inline .then so setState lands async, the
  // TeamRosterPanel effect idiom). [] on error → rows fall back to the raw class id.
  useEffect(() => {
    let active = true
    void fetchHullTypes().then((rows) => {
      if (active) setHullTypes(rows)
    })
    return () => {
      active = false
    }
  }, [])

  // ── pure projections ───────────────────────────────────────────────────────────────────────────
  // The SAME roster fold Command uses (buildTeamRoster) over the SAME shell ship list — never a
  // second grouping implementation. `ungrouped` IS the berthed bucket post-S1.
  const rosterShips: RosterShip[] = selection.ships.map((s) => ({
    main_ship_id: s.main_ship_id,
    name: s.name,
    status: s.status,
    group_id: groupMap[s.main_ship_id]?.group_id ?? null,
    is_command_ship: groupMap[s.main_ship_id]?.is_command_ship ?? false,
  }))
  // The grouping fold itself (and the n3 dangling-group_id guard that goes with it) lives in
  // ShipsView, which is the only thing that renders it — one place, not two.
  const posByShip = new Map(map.fleetPositions.map((p) => [p.main_ship_id, p]))
  const shipRowById = new Map((ships ?? []).map((r) => [r.main_ship_id, r]))
  const litFittingRows = isServerLit(fittingsRes) ? (fittingsRes.fittings ?? []) : null
  const litCaptainRows = isServerLit(captainsRes) ? (captainsRes.captains ?? []) : null

  const selectedShip = selection.selectedShip
  const selectedPos = selectedShip ? posByShip.get(selectedShip.main_ship_id) : undefined
  // The hull class display name — resolved from the SELECTED SHIP'S OWN hull_type_id against the
  // catalog (per-ship-correct at any N; never the sole-ship-resolved polled view). Catalog miss /
  // read error → null → the detail falls back to the raw class id.
  const selectedShipRow = selectedShip ? (shipRowById.get(selectedShip.main_ship_id) ?? null) : null
  const selectedHullName = selectedShipRow
    ? (hullTypes.find((h) => h.hull_type_id === selectedShipRow.hull_type_id)?.name ?? null)
    : null

  // No commissioned ship yet → EmptyState pointing at Command (acquisition = composition; the
  // CommissionShipPanel lives there). REVIEW FIX (S6 minor 3, NO-SOFTLOCK-adjacent): the shell
  // ship-list read collapses a transient error to [] and never re-polls, so this state could
  // stick for a ship-OWNING player (hiding a destroyed ship's repair CTA) with no way back but a
  // reload — the "Check again" retry re-runs selection.refresh() so one bad read never strands
  // the roster.
  if (!selection.loading && selection.ships.length === 0) {
    return (
      <Screen wide>
        <PageHeader eyebrow="Ops · Ships" title="Ships" subtitle="Your ships & their equipment" />
        <EmptyState
          data-testid="fitting-no-ship"
          icon={<Icon name="ship" size={28} />}
          title="No ship yet"
          body="Claim your first ship on the Mission tab — its equipment, captains, and cargo appear here."
          action={
            <span className="inline-flex items-center gap-2">
              <Link to="/mission" className={buttonClasses('primary', 'md')}>
                Go to Mission
              </Link>
              <Button
                variant="ghost"
                data-testid="fitting-no-ship-retry"
                onClick={() => void selection.refresh()}
              >
                Check again
              </Button>
            </span>
          }
        />
      </Screen>
    )
  }

  return (
    <ShipsView
      loading={selection.loading}
      groups={groups}
      rosterShips={rosterShips}
      shipRows={ships}
      fleetPositions={map.fleetPositions}
      locations={game.locations}
      fittings={litFittingRows}
      captains={litCaptainRows}
      selectedShipId={selection.selectedShipId}
      onSelectShip={selection.selectShip}
      /* THE SHIP COLUMN, composed not re-implemented: the ONE <FittingDetail> that already
         existed, plus the two captain panels that address the SAME selection and so belong beside
         it rather than in a third column of their own. All three are null when nothing is
         selected / while their gates are dark, which is what lets the rail self-collapse. */
      detail={
        <>
          {/* key = ship id: switching ships REMOUNTS the detail, so one ship’s sections never
              briefly wear another’s name. */}
          {selectedShip && (
            <FittingDetail
              key={selectedShip.main_ship_id}
              ship={selectedShip}
              shipRow={selectedShipRow}
              hullName={selectedHullName}
              position={selectedPos}
              locations={game.locations}
              /* 0297’s readiness read as a plain FACT — the one repair surface folds it with the
                 positions row into its single position answer. No decision is made up here. */
              disabledShips={disabledShips}
              allFittings={litFittingRows}
              shipCaptains={litCaptainRows ? captainsForShip(litCaptainRows, selectedShip.main_ship_id) : null}
              refreshKey={readRefreshKey}
              onLoadoutChanged={refreshShared}
              onIdentityChanged={async () => {
                await Promise.all([selection.refresh(), game.refresh(), map.refresh(), refreshShared()])
              }}
            />
          )}
          {/* CAPTAIN-P15 (dark, server-lit only): assign/unassign captains to the SELECTED ship.
              The target is the shell selection DIRECTLY — the same source the detail uses — never
              the polled map.mainShip, which lags a roster click and would briefly show/mutate the
              PREVIOUS ship’s captains (wrong-target once captains light). */}
          <CaptainsPanel
            lifecycleKey={lifecycleKey}
            mainShipId={selection.selectedShipId}
            onChanged={bumpLoadoutRev}
          />
          {/* CAPTAIN-P16 (dark, server-lit only): captain recruitment (progression). */}
          <RecruitCaptainPanel
            lifecycleKey={lifecycleKey}
            mainShipId={selection.selectedShipId}
            onChanged={bumpLoadoutRev}
          />
        </>
      }
    />
  )
}
