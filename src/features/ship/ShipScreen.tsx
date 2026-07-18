import { useCallback, useEffect, useReducer, useState } from 'react'
import { Link } from 'react-router-dom'
import { useShellState } from '../../app/shellState'
import { fetchMyMainShips, repairMainShip, type MainShipRow } from '../map/mainshipApi'
import { getMyShipFittings } from '../modules/modulesApi'
import type { GetMyShipFittingsResult } from '../modules/modulesTypes'
import { getMyCaptainInstances } from '../captains/captainsApi'
import type { GetMyCaptainInstancesResult } from '../captains/captainsTypes'
import { fetchMyShipGroups, fetchMyShipGroupMap, type ShipGroupMapEntry } from '../command/teamApi'
import {
  buildTeamRoster,
  fleetPositionLocationLabel,
  type GroupRow,
  type RosterShip,
} from '../command/teamRoster'
import { mainShipInstanceStatusLabel, mainShipInstanceStatusTone } from '../map/mainshipStatusLabel'
import { isServerLit, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { captainsForShip, fittingsForShip } from './shipDossierView'
import { shipMeterPair } from './meterPair'
import { MeterPairBars } from './MeterPairBars'
import { FittingDetail } from './FittingDetail'
import { CaptainsPanel } from '../captains/CaptainsPanel'
import { RecruitCaptainPanel } from '../captains/RecruitCaptainPanel'
import { InventoryPanel } from '../inventory/InventoryPanel'
import {
  Badge,
  Button,
  Card,
  CardHeader,
  EmptyState,
  Icon,
  Notice,
  PageHeader,
  Screen,
  SectionLabel,
  Skeleton,
  buttonClasses,
  screenRailClass,
  screenSplitClass,
} from '../../components/ui'

// S6 — the FITTING tab (rebuilt from the old Ship tab; ShipStatusCard + ShipDossier + ShipSwitcher
// are RETIRED, not shipped alongside). The destination answers "what is ON each of my ships, and
// where is it" — ships grouped BY FLEET plus the "Berthed — not in a fleet" bucket, each row
// showing location / condition / captains, and a per-ship fitting detail on selection.
//
// BOUNDARY (charter §2a): Command owns fleet COMPOSITION (create/rename/delete fleet, add/remove
// ship, command-ship toggle — TeamRosterPanel); this screen renders the grouping READ-ONLY through
// the SAME pure fold (buildTeamRoster — never a second grouping implementation) with ZERO
// membership and ZERO movement controls. Fitting owns per-ship EQUIPMENT + CONDITION (modules,
// rename, repair, rooms, captains-at-the-ship, cargo, traits/buffs).
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
// NO-SOFTLOCK: the free repair CTA (repair_main_ship — server-side deliberately UNGATED, 0052)
// renders on EVERY destroyed ship's row (and again in the detail): a disabled ship must always
// have its recovery path on screen, independent of selection and of every feature flag.
//
// Fan-out (the brief's measured budget): the shared roster facts are ~6 requests total regardless
// of ship count (ships 1 + groups 1 + group-map 2 + fittings 1 + captains 1; location costs 0 —
// already polled). The per-ship dossier surfaces load ONLY in the selected ship's detail. No new
// server RPC.

export function ShipScreen() {
  const { game, map, selection } = useShellState()
  const lifecycleKey = `${map.mainShip?.status ?? 'n'}|${map.mainShip?.spatial_state ?? 'n'}|${map.mainShipSpaceMovement?.id ?? 'none'}|${map.mainShipSpaceMovement?.status ?? 'none'}`
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
  const [repairNote, setRepairNote] = useState<Record<string, string | null>>({})
  const [repairPending, setRepairPending] = useState<Record<string, boolean>>({})

  const guards = useActivityPanelGuards()
  const { activeRef } = guards

  const refreshShared = useCallback(async () => {
    const [myShips, g, m, fit, cap] = await Promise.all([
      fetchMyMainShips(),
      fetchMyShipGroups(),
      fetchMyShipGroupMap(),
      getMyShipFittings(),
      getMyCaptainInstances(),
    ])
    if (!activeRef.current) return
    setShips(myShips)
    setGroups(g)
    setGroupMap(m)
    setFittingsRes(fit)
    setCaptainsRes(cap)
  }, [activeRef])

  // readRefreshKey is a deliberate re-fetch trigger (the ShipDossier dep idiom).
  useEffect(() => {
    void refreshShared()
  }, [refreshShared, readRefreshKey])

  // NO-SOFTLOCK — the row-level free repair (see header). Throw-style wrapper → try/catch, the
  // ShipStatusCard doRepair shape, keyed per ship so rows never share pending state.
  async function repairShip(shipId: string) {
    const key = `repair:${shipId}`
    if (!guards.tryClaim(key)) return
    setRepairPending((p) => ({ ...p, [shipId]: true }))
    setRepairNote((n) => ({ ...n, [shipId]: null }))
    try {
      await repairMainShip(shipId) // explicit ship id; server asserts ownership
      await Promise.all([game.refresh(), map.refresh(), selection.refresh(), refreshShared()])
    } catch (e) {
      if (activeRef.current) {
        setRepairNote((n) => ({ ...n, [shipId]: e instanceof Error ? e.message : String(e) }))
      }
    } finally {
      guards.release(key)
      if (activeRef.current) setRepairPending((p) => ({ ...p, [shipId]: false }))
    }
  }

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
  const { teams, ungrouped } = buildTeamRoster(groups, rosterShips)
  const posByShip = new Map(map.fleetPositions.map((p) => [p.main_ship_id, p]))
  const shipRowById = new Map((ships ?? []).map((r) => [r.main_ship_id, r]))
  const litFittingRows = isServerLit(fittingsRes) ? (fittingsRes.fittings ?? []) : null
  const litCaptainRows = isServerLit(captainsRes) ? (captainsRes.captains ?? []) : null

  const selectedShip = selection.selectedShip
  const selectedPos = selectedShip ? posByShip.get(selectedShip.main_ship_id) : undefined
  // The hull class display name — only when the shell's single-ship read resolved THIS ship
  // (map.mainShip is fetchMainShip(selectedShipId)); otherwise the detail falls back to the id.
  const selectedHullName =
    selectedShip && map.mainShip?.main_ship_id === selectedShip.main_ship_id
      ? (game.mainShip?.hull?.name ?? null)
      : null

  // One roster row (the TeamRosterPanel role="button" selected-row idiom — READ-ONLY here: no
  // membership/movement controls; the only action a row ever carries is the destroyed-ship Repair).
  const shipRow = (s: RosterShip) => {
    const selected = s.main_ship_id === selection.selectedShipId
    const row = shipRowById.get(s.main_ship_id)
    const meters = row ? shipMeterPair(row) : null
    const isDisabled = s.status === 'destroyed'
    const locLabel = fleetPositionLocationLabel(posByShip.get(s.main_ship_id), game.locations)
    const rowCaptains = litCaptainRows ? captainsForShip(litCaptainRows, s.main_ship_id) : null
    const fittedCount = litFittingRows ? fittingsForShip(litFittingRows, s.main_ship_id).length : null
    const note = repairNote[s.main_ship_id]
    const pick = () => selection.selectShip(s.main_ship_id)
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
          <span className={`truncate text-sm ${selected ? 'text-ink' : 'text-ink-muted'}`}>{s.name}</span>
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
            <Badge tone={mainShipInstanceStatusTone(s.status)}>{mainShipInstanceStatusLabel(s.status)}</Badge>
            {selected && <Badge tone="accent">Selected</Badge>}
          </span>
        </div>
        {/* LOCATION — the ONE read. A missing/hidden projection row shows the honest fallback,
            never a guessed place (the projection is [] while both movement gates are dark). */}
        <p data-testid={`fitting-row-location-${s.main_ship_id}`} className="mt-0.5 text-[11px] text-ink-muted">
          {locLabel ?? 'Location unavailable'}
        </p>
        {/* CONDITION — the shared shield/hull pair (shield row data-gated inside). */}
        {meters && (
          <div className="mt-1.5">
            <MeterPairBars pair={meters} hullTone={isDisabled ? 'danger' : meters.hull.pct < 100 ? 'accent' : 'success'} />
          </div>
        )}
        {/* Captains aboard — from the ONE shared captains read (server-lit; dark → nothing). */}
        {rowCaptains && rowCaptains.length > 0 && (
          <p data-testid={`fitting-row-captains-${s.main_ship_id}`} className="mt-1 truncate text-[10px] text-ink-faint">
            Captains · {rowCaptains.map((c) => c.name).join(', ')}
          </p>
        )}
        {/* NO-SOFTLOCK — the UNGATED free repair on the ROW: a destroyed ship's recovery path is
            always on screen, whatever is selected. stopPropagation: repairing must not double as
            a selection change. */}
        {isDisabled && (
          <div className="mt-2" onClick={(e) => e.stopPropagation()}>
            <Button
              variant="warning"
              size="sm"
              data-testid={`fitting-row-repair-${s.main_ship_id}`}
              busy={repairPending[s.main_ship_id] ?? false}
              busyLabel="Repairing…"
              onClick={() => void repairShip(s.main_ship_id)}
            >
              Repair ship
            </Button>
            {note && (
              <Notice tone="danger" className="mt-1" data-testid={`fitting-row-repair-error-${s.main_ship_id}`}>
                {note}
              </Notice>
            )}
          </div>
        )}
      </div>
    )
  }

  // No commissioned ship yet → EmptyState pointing at Command (acquisition = composition; the
  // CommissionShipPanel lives there).
  if (!selection.loading && selection.ships.length === 0) {
    return (
      <Screen wide>
        <PageHeader eyebrow="Ops · Vessel" title="Fitting" subtitle="Your ships' loadouts" />
        <EmptyState
          data-testid="fitting-no-ship"
          icon={<Icon name="ship" size={28} />}
          title="No ship yet"
          body="Commission your first ship from Command — its fitting, captains, and cargo appear here."
          action={
            <Link to="/command" className={buttonClasses('primary', 'md')}>
              Go to Command
            </Link>
          }
        />
      </Screen>
    )
  }

  return (
    <Screen wide>
      <PageHeader eyebrow="Ops · Vessel" title="Fitting" subtitle="Your ships, by fleet — select one to outfit it" />
      <div className={screenSplitClass()}>
        <div className={screenRailClass('main')}>
          {/* THE ROSTER — grouped by fleet (read-only; composition lives in Command). */}
          <Card data-testid="fitting-roster">
            <CardHeader
              title="Ships"
              subtitle="Grouped by fleet. Manage fleet membership in Command."
              className="mb-2"
            />
            {ships === null || selection.loading ? (
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
                      {group.name} · Fleet {group.group_index} · {members.length} ship{members.length === 1 ? '' : 's'}
                    </SectionLabel>
                    {members.length > 0 ? (
                      <div className="mt-1.5 space-y-1.5">{members.map(shipRow)}</div>
                    ) : (
                      <p className="mt-1.5 text-xs text-ink-faint">No ships in this fleet.</p>
                    )}
                  </div>
                ))}
                {/* THE BERTHED BUCKET — buildTeamRoster's `ungrouped`, which post-S1 is exactly
                    the berthed ships (group_id NULL ⇔ berthed at a port, the 0216 XOR). Rows
                    resolve their berth port through the SAME location fold ('berthed' place →
                    "Docked at <port>"). */}
                <div data-testid="fitting-berthed">
                  <SectionLabel>Berthed — not in a fleet</SectionLabel>
                  {ungrouped.length > 0 ? (
                    <div className="mt-1.5 space-y-1.5">{ungrouped.map(shipRow)}</div>
                  ) : (
                    <p data-testid="fitting-berthed-empty" className="mt-1.5 text-xs text-ink-faint">
                      Every ship is with a fleet.
                    </p>
                  )}
                </div>
              </div>
            )}
          </Card>

          {/* THE FITTING DETAIL — the selected ship's outfitting surface. key = ship id: switching
              ships REMOUNTS the detail, so one ship's sections never briefly wear another's name. */}
          {selectedShip && (
            <FittingDetail
              key={selectedShip.main_ship_id}
              ship={selectedShip}
              shipRow={shipRowById.get(selectedShip.main_ship_id) ?? null}
              hullName={selectedHullName}
              position={selectedPos}
              locations={game.locations}
              allFittings={litFittingRows}
              shipCaptains={litCaptainRows ? captainsForShip(litCaptainRows, selectedShip.main_ship_id) : null}
              refreshKey={readRefreshKey}
              onLoadoutChanged={refreshShared}
              onIdentityChanged={async () => {
                await Promise.all([selection.refresh(), game.refresh(), map.refresh(), refreshShared()])
              }}
            />
          )}
        </div>
        <div className={screenRailClass('aside')}>
          {/* The player's item inventory — live data, always lit (feeds RecruitCaptainPanel here
              and the Port Workshop's recipes). */}
          <InventoryPanel refreshKey={readRefreshKey} />
          {/* CAPTAIN-P15 (dark, server-lit only): assign/unassign captains to the resolved ship. */}
          <CaptainsPanel
            lifecycleKey={lifecycleKey}
            mainShipId={map.mainShip?.main_ship_id ?? null}
            onChanged={bumpLoadoutRev}
          />
          {/* CAPTAIN-P16 (dark, server-lit only): captain recruitment (progression). */}
          <RecruitCaptainPanel lifecycleKey={lifecycleKey} onChanged={bumpLoadoutRev} />
        </div>
      </div>
    </Screen>
  )
}
