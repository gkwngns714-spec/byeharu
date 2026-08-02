import { useCallback, useEffect, useReducer, useState } from 'react'
import { Link } from 'react-router-dom'
import { useShellState } from '../../app/shellState'
import { fetchHullTypes, fetchMyMainShips, repairMainShip, type HullRow, type MainShipRow } from '../map/mainshipApi'
import { getMyShipFittings } from '../modules/modulesApi'
import type { GetMyShipFittingsResult } from '../modules/modulesTypes'
import { getMyCaptainInstances } from '../captains/captainsApi'
import type { GetMyCaptainInstancesResult } from '../captains/captainsTypes'
import { fetchMyShipGroups, fetchMyShipGroupMap, type ShipGroupMapEntry } from '../command/teamApi'
import {
  buildTeamRoster,
  commandFleetState,
  fleetPositionLocationLabel,
  type GroupRow,
  type RosterShip,
} from '../command/teamRoster'
import { isServerLit, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { captainsForShip, fittingsForShip } from './shipDossierView'
import { shipMeterPair } from './meterPair'
import { MeterPairBars } from './MeterPairBars'
import { FittingDetail, type ShipRecoveryView } from './FittingDetail'
import {
  canRepair,
  canTow,
  isAdriftError,
  repairErrorMessage,
  repairGate,
  repairGateNote,
  towReasonMessage,
  towSuccessMessage,
  REPAIR_LABEL,
  TOW_LABEL,
  type DisabledShipRow,
} from './shipRecovery'
import { emergencyTowMainShip, fetchMyDisabledShips } from './shipRecoveryApi'
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
// NO-SOFTLOCK, POSITION-GATED (0297): every destroyed ship's row (and the detail) always carries A
// RECOVERY ACTION — never none. Which one is decided by the ONE pure gate (shipRecovery.repairGate)
// over get_my_disabled_ships, the same authority repair_main_ship gates on server-side:
//   · in port  → "Repair ship"  (the free 0052 safelock — unchanged, no cost, no flag)
//   · adrift   → "Tow to the nearest port" (the free 0297 tow), Repair disabled with the reason
//   · unknown  → Repair, enabled: the readiness read failed or the client is ahead of the migration,
//                and the SERVER is the enforcer. The UI never hides recovery it cannot rule out.
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
  const [repairNote, setRepairNote] = useState<Record<string, string | null>>({})
  const [repairPending, setRepairPending] = useState<Record<string, boolean>>({})
  // 0297 RECOVERY — where each disabled ship is (null = read unavailable → the gate says 'unknown'),
  // the tow's own per-ship command state, and the ships the SERVER has told us are adrift (a repair
  // that came back ship_not_at_port outranks a stale/absent readiness read).
  const [disabledShips, setDisabledShips] = useState<DisabledShipRow[] | null>(null)
  const [towPending, setTowPending] = useState<Record<string, boolean>>({})
  const [towNote, setTowNote] = useState<Record<string, string | null>>({})
  const [adriftSeen, setAdriftSeen] = useState<Record<string, boolean>>({})
  // The hull catalog (public-read Reference/Config) — fetched ONCE per mount (static data), so
  // every ship's class name resolves from ITS OWN hull_type_id. REVIEW FIX (S6 major 1): the
  // first cut read game.mainShip.hull — the NO-ID sole-ship view, which at N≥2 fail-closes to the
  // starter-frigate teaser and would wear the WRONG class on every non-starter ship.
  const [hullTypes, setHullTypes] = useState<HullRow[]>([])

  const guards = useActivityPanelGuards()
  const { activeRef } = guards

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

  // NO-SOFTLOCK — the ONE free-repair implementation in this screen (see header). The detail
  // composes this same function rather than carrying a second copy. Throw-style wrapper → try/catch,
  // keyed per ship so rows never share pending state. 0297: the raw raise NEVER reaches the screen —
  // repairErrorMessage turns it into player words, and a ship_not_at_port reject flips this ship to
  // 'adrift' so the tow appears in place of the button that just failed.
  async function repairShip(shipId: string) {
    const key = `repair:${shipId}`
    if (!guards.tryClaim(key)) return
    setRepairPending((p) => ({ ...p, [shipId]: true }))
    setRepairNote((n) => ({ ...n, [shipId]: null }))
    setTowNote((n) => ({ ...n, [shipId]: null }))
    try {
      await repairMainShip(shipId) // explicit ship id; server asserts ownership
      if (activeRef.current) setAdriftSeen((a) => ({ ...a, [shipId]: false }))
      await Promise.all([game.refresh(), map.refresh(), selection.refresh(), refreshShared()])
    } catch (e) {
      if (activeRef.current) {
        setRepairNote((n) => ({ ...n, [shipId]: repairErrorMessage(e) }))
        if (isAdriftError(e)) setAdriftSeen((a) => ({ ...a, [shipId]: true }))
      }
    } finally {
      guards.release(key)
      if (activeRef.current) setRepairPending((p) => ({ ...p, [shipId]: false }))
    }
  }

  // 0297 — THE RECOVERY ROUTE. The free emergency tow: hauls an adrift wreck to the nearest port and
  // berths it there, which is what unlocks the position-gated repair. Envelope-style RPC (never
  // throws), so every outcome maps through the ONE reason→copy table.
  async function towShip(shipId: string) {
    const key = `tow:${shipId}`
    if (!guards.tryClaim(key)) return
    setTowPending((p) => ({ ...p, [shipId]: true }))
    setTowNote((n) => ({ ...n, [shipId]: null }))
    setRepairNote((n) => ({ ...n, [shipId]: null }))
    try {
      const res = await emergencyTowMainShip(shipId)
      if (!activeRef.current) return
      if (res.ok) {
        setTowNote((n) => ({ ...n, [shipId]: towSuccessMessage(res.location_name) }))
        setAdriftSeen((a) => ({ ...a, [shipId]: false }))
      } else {
        setTowNote((n) => ({ ...n, [shipId]: towReasonMessage(res.reason) }))
        // 'already_at_port' means our view was stale — clear the override and let the refetch decide.
        if (res.reason === 'already_at_port') setAdriftSeen((a) => ({ ...a, [shipId]: false }))
      }
      // Non-optimistic: the new berth arrives from the server, never patched locally.
      await Promise.all([game.refresh(), map.refresh(), selection.refresh(), refreshShared()])
    } finally {
      guards.release(key)
      if (activeRef.current) setTowPending((p) => ({ ...p, [shipId]: false }))
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
  // MAP-INTEGRATION n3 GUARD — buildTeamRoster (correctly) folds a DANGLING group_id into
  // `ungrouped`, but labeling such a ship "Berthed — not in a fleet" is a LIE when the dangle is a
  // transient groups-read failure (fetchMyShipGroups collapses errors to []): every fleeted ship
  // would briefly claim to be berthed. Partition for display only: `berthedShips` (group_id null —
  // the true 0216 berth XOR) keep the Berthed heading; `fleetUnresolved` (a non-null group_id whose
  // fleet didn't resolve) render under an honest "fleet unavailable" heading, never a berth claim.
  const berthedShips = ungrouped.filter((s) => s.group_id === null)
  const fleetUnresolved = ungrouped.filter((s) => s.group_id !== null)
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

  // One roster row (the TeamRosterPanel role="button" selected-row idiom — READ-ONLY here: no
  // membership/movement controls; the only action a row ever carries is the destroyed-ship Repair).
  const shipRow = (s: RosterShip) => {
    const selected = s.main_ship_id === selection.selectedShipId
    const row = shipRowById.get(s.main_ship_id)
    const meters = row ? shipMeterPair(row) : null
    // REPAIR-WHERE-YOU-ARE review fix: recovery decisions read the REFETCHED shared status
    // (fetchMyMainShips — re-read after every command wave), falling back to the selection row
    // only pre-load. The selection list never re-polls, so keying off s.status alone hid a
    // mid-session destruction's Repair/Tow button until a full reload.
    const rowStatus = row?.status ?? s.status
    const isDisabled = rowStatus === 'destroyed'
    // 0297 — the ONE gate decision for this ship (pure; specs in tests/shipRecovery.spec.ts).
    const gate = repairGate(rowStatus, disabledShips, s.main_ship_id, adriftSeen[s.main_ship_id] ?? false)
    const locLabel = fleetPositionLocationLabel(posByShip.get(s.main_ship_id), game.locations)
    // Fleet-aware state (same selector the Command roster uses): a moving/docked ship no longer
    // reads the raw 'home' status as "Ready to launch" — that shows only when genuinely idle.
    const fleetState = commandFleetState(posByShip.get(s.main_ship_id), game.locations, s.status, Date.now())
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
            <Badge tone={fleetState.tone}>{fleetState.label}</Badge>
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
        {/* NO-SOFTLOCK — a destroyed ship's recovery path is ALWAYS on screen, whatever is selected.
            0297: which action that is comes from the gate — Repair in port, Tow when adrift — so the
            row never shows a button the server would refuse without saying why.
            stopPropagation: recovering must not double as a selection change. */}
        {isDisabled && (
          <div className="mt-2" onClick={(e) => e.stopPropagation()}>
            <p
              data-testid={`fitting-row-recovery-note-${s.main_ship_id}`}
              className="mb-1 text-[11px] text-ink-muted"
            >
              {repairGateNote(gate)}
            </p>
            {canTow(gate) ? (
              <Button
                variant="warning"
                size="sm"
                data-testid={`fitting-row-tow-${s.main_ship_id}`}
                busy={towPending[s.main_ship_id] ?? false}
                busyLabel="Towing…"
                onClick={() => void towShip(s.main_ship_id)}
              >
                {TOW_LABEL}
              </Button>
            ) : (
              <Button
                variant="warning"
                size="sm"
                data-testid={`fitting-row-repair-${s.main_ship_id}`}
                disabled={!canRepair(gate)}
                busy={repairPending[s.main_ship_id] ?? false}
                busyLabel="Repairing…"
                onClick={() => void repairShip(s.main_ship_id)}
              >
                {REPAIR_LABEL}
              </Button>
            )}
            {towNote[s.main_ship_id] && (
              <Notice tone="neutral" className="mt-1" data-testid={`fitting-row-tow-note-${s.main_ship_id}`}>
                {towNote[s.main_ship_id]}
              </Notice>
            )}
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
  // CommissionShipPanel lives there). REVIEW FIX (S6 minor 3, NO-SOFTLOCK-adjacent): the shell
  // ship-list read collapses a transient error to [] and never re-polls, so this state could
  // stick for a ship-OWNING player (hiding a destroyed ship's repair CTA) with no way back but a
  // reload — the "Check again" retry re-runs selection.refresh() so one bad read never strands
  // the roster.
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
            <span className="inline-flex items-center gap-2">
              <Link to="/command" className={buttonClasses('primary', 'md')}>
                Go to Command
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
                {/* n3 GUARD — ships whose fleet did NOT resolve (a dangling group_id, e.g. a
                    transient groups-read failure). Rendered under an honest heading — NEVER in the
                    Berthed bucket below, which would mislabel a fleeted ship. Normally empty. */}
                {fleetUnresolved.length > 0 && (
                  <div data-testid="fitting-fleet-unresolved">
                    <SectionLabel>In a fleet — fleet details unavailable</SectionLabel>
                    <div className="mt-1.5 space-y-1.5">{fleetUnresolved.map(shipRow)}</div>
                  </div>
                )}
                {/* THE BERTHED BUCKET — the truly-unfleeted ships (group_id NULL ⇔ berthed at a
                    port, the 0216 XOR; the n3 partition keeps dangling-fleet ships OUT). Rows
                    resolve their berth port through the SAME location fold ('berthed' place →
                    "Docked at <port>"). */}
                <div data-testid="fitting-berthed">
                  <SectionLabel>Berthed — not in a fleet</SectionLabel>
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
          </Card>

          {/* THE FITTING DETAIL — the selected ship's outfitting surface. key = ship id: switching
              ships REMOUNTS the detail, so one ship's sections never briefly wear another's name. */}
          {selectedShip && (
            <FittingDetail
              key={selectedShip.main_ship_id}
              ship={selectedShip}
              shipRow={selectedShipRow}
              hullName={selectedHullName}
              position={selectedPos}
              locations={game.locations}
              /* 0297 — the detail COMPOSES this screen's one recovery implementation (it no longer
                 carries a second copy of the repair command). */
              recovery={{
                /* REPAIR-WHERE-YOU-ARE review fix: the same freshest-status source the detail's
                   repairConcept uses (the refetched shared read, selection as pre-load fallback) —
                   so the gate and the mount decision can never disagree about destroyed. */
                gate: repairGate(
                  selectedShipRow?.status ?? selectedShip.status,
                  disabledShips,
                  selectedShip.main_ship_id,
                  adriftSeen[selectedShip.main_ship_id] ?? false,
                ),
                repairing: repairPending[selectedShip.main_ship_id] ?? false,
                repairError: repairNote[selectedShip.main_ship_id] ?? null,
                towing: towPending[selectedShip.main_ship_id] ?? false,
                towNote: towNote[selectedShip.main_ship_id] ?? null,
                onRepair: () => repairShip(selectedShip.main_ship_id),
                onTow: () => towShip(selectedShip.main_ship_id),
              } satisfies ShipRecoveryView}
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
          {/* CAPTAIN-P15 (dark, server-lit only): assign/unassign captains to the SELECTED ship.
              REVIEW FIX (S6 major 2): the target is the shell selection DIRECTLY — the same source
              the detail uses — never the polled map.mainShip, which lags a roster click and would
              briefly show/mutate the PREVIOUS ship's captains (wrong-target once captains light). */}
          <CaptainsPanel
            lifecycleKey={lifecycleKey}
            mainShipId={selection.selectedShipId}
            onChanged={bumpLoadoutRev}
          />
          {/* CAPTAIN-P16 (dark, server-lit only): captain recruitment (progression). */}
          <RecruitCaptainPanel lifecycleKey={lifecycleKey} onChanged={bumpLoadoutRev} />
        </div>
      </div>
    </Screen>
  )
}
