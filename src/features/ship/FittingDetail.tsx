import { useCallback, useEffect, useState } from 'react'
import { isServerLit, runGuardedCommand, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import {
  fetchMyExpeditionPreview,
  renameMainShip,
  repairMainShip,
  type FleetPosition,
  type MainShipRow,
} from '../map/mainshipApi'
import { fetchModuleCatalog, fitModuleToShip, getMyModuleInstances, unfitModuleFromShip } from '../modules/modulesApi'
import {
  fittingErrorMessage,
  type FittingCommandResult,
  type GetMyModuleInstancesResult,
  type ModuleCatalogEntry,
  type ModuleInstance,
  type ShipFittingRow,
} from '../modules/modulesTypes'
import { configureShipRoom, getMyShipRoomSlots, getShipStations } from '../captains/captainsApi'
import { roomPickerOptions, roomSlotBoard, stationLabel, type ShipStation } from '../captains/deckStations'
import { CaptainXpBar } from '../captains/CaptainXpBar'
import {
  roomConfigErrorMessage,
  type CaptainInstance,
  type ConfigureRoomResult,
  type GetShipRoomSlotsResult,
} from '../captains/captainsTypes'
import { getShipCargoLots, type ShipCargoLot } from '../map/tradeApi'
import type { SelectableShip } from '../map/useMainShipSelection'
import type { MapLocation } from '../map/mapTypes'
import { fleetPositionLocationLabel } from '../command/teamRoster'
import {
  aggregateCargo,
  cargoUsedM3,
  fittedSlotsUsed,
  fittingsForShip,
  formatM3,
  parseShipStatsPreview,
  shipStatsErrorMessage,
} from './shipDossierView'
import { fitGateMessage, fittingEditability, unfittedModuleInstances } from './fittingView'
import { shipTraitCards } from './shipTraits'
import { moduleInfoView } from './moduleInfoView'
import { fetchShipSoul, type ShipSoulData } from './soulApi'
import { shipCommandBuffCard } from './commandBuff'
import { fetchShipCommandBuff, type ShipCommandBuffData } from './commandBuffApi'
import { shipMeterPair } from './meterPair'
import { MeterPairBars } from './MeterPairBars'
import { normalizeShipName, renameReasonMessage, shipNameProblem, SHIP_NAME_MAX } from './shipName'
import { Badge, Button, Card, CardHeader, Notice, SectionLabel, Skeleton } from '../../components/ui'
import { ItemChip, ItemGlyph, ItemTile } from '../../components/items'

// S6 FITTING DETAIL — the per-ship outfitting surface (retires ShipDossier + ShipStatusCard; this
// is the rebuild, not a third sibling). Opens when a roster row is selected (the ONE shell
// selection); composes, for THAT ship:
//   · identity — class + renameable name (the inline rename re-homed from ShipStatusCard;
//     shipName.ts pure guards; rename_main_ship_self);
//   · location — from the ONE fleet-positions row the screen threads down (ZERO own location
//     reads; the fleetPositionLocationLabel adapter — the same fold every roster row uses);
//   · condition — the shared shield/hull pair (MeterPairBars over shipMeterPair) + the UNGATED
//     free Repair when the ship is disabled (NO-SOFTLOCK: repair_main_ship is the ONLY recovery
//     path for a destroyed ship — RepairPanel's paid desk defers to it — so it must render here
//     regardless of any flag);
//   · THE FITTING EDIT SURFACE — the ONE place fit/unfit renders (moved OUT of ModulesPanel's
//     Workshop in this same slice; ModulesPanel keeps crafting only). The row IS the ship: fit
//     targets this ship directly, no <select>. ENABLED when the ship's place is 'docked' or
//     'berthed' (fittingEditability over the SAME positions row — never a 2nd dockedness query):
//     4c-mig-1 (0221) repointed validate_context onto berth truth, so a berthed ship resolves to
//     state='home' and the settled-safe rule accepts it. The server rule stays the enforcer and
//     its ship_not_settled copy surfaces verbatim on a reject.
//   · traits / command buff (fail-closed gate-first fetchers — dark → byte-identical nothing);
//   · captains & rooms — the ROOMS-8 configurable board re-homed from ShipDossier (room config
//     is per-ship equipment, inside the Fitting boundary; captain assign/unassign stays in
//     CaptainsPanel on the aside);
//   · cargo hold — plain owner-read data (works undocked).
//
// Data: the SHARED roster facts (ships row, per-ship fittings subset, per-ship captains, the
// position row) arrive as props from the screen's one batched read — this component fetches only
// the per-ship surfaces that load ON SELECTION (the brief's trimmed dossier wave): module
// instances (fit candidates), cargo lots, stats preview, room catalog+slots, soul, command buff.
// NO optimistic UI: every command awaits the server then refetches (its own wave + the screen's
// shared reads via onLoadoutChanged / onIdentityChanged).

export function FittingDetail({
  ship,
  shipRow,
  hullName,
  position,
  locations,
  allFittings,
  shipCaptains,
  refreshKey,
  onLoadoutChanged,
  onIdentityChanged,
}: {
  /** The shell-selected ship (the ONE selection source). */
  ship: SelectableShip
  /** This ship's condition row from the screen's shared fetchMyMainShips read (null while loading). */
  shipRow: MainShipRow | null
  /** The hull class display name when the shell resolved it for this ship, else null (falls back to the class id). */
  hullName: string | null
  /** This ship's ONE location fact — its map.fleetPositions row (undefined = not in the projection). */
  position: FleetPosition | undefined
  locations: MapLocation[]
  /** The WHOLE fittings read (server-lit) or null while dark/unloaded — per-ship subset derived here. */
  allFittings: ShipFittingRow[] | null
  /** This ship's assigned captains (server-lit) or null while dark. */
  shipCaptains: CaptainInstance[] | null
  refreshKey: string
  /** A fit/unfit landed — the screen refetches the shared fittings read. */
  onLoadoutChanged: () => Promise<void>
  /** Rename/repair landed — the screen refreshes identity state (selection/game/map + shared reads). */
  onIdentityChanged: () => Promise<void>
}) {
  const shipId = ship.main_ship_id

  // ── per-ship reads (load on selection only — the measured-fan-out budget) ──────────────────────
  const [instancesRes, setInstancesRes] = useState<GetMyModuleInstancesResult | null>(null)
  const [lots, setLots] = useState<ShipCargoLot[] | null>(null)
  const [statsPreview, setStatsPreview] = useState<unknown>(null)
  const [stations, setStations] = useState<ShipStation[]>([])
  const [roomSlotsRes, setRoomSlotsRes] = useState<GetShipRoomSlotsResult | null>(null)
  const [soul, setSoul] = useState<ShipSoulData | null>(null)
  const [commandBuff, setCommandBuff] = useState<ShipCommandBuffData | null>(null)
  // The public module_types catalog (stats/combat attributes/description) — powers the tap-to-info
  // panel on every module row. null while loading / on read error → rows stay non-interactive
  // (nothing to reveal), never a crash: fit/unfit is the always-present surface.
  const [moduleCatalog, setModuleCatalog] = useState<ModuleCatalogEntry[] | null>(null)
  // The module row (by instance id) whose info panel is open — one at a time; tap again to collapse.
  const [openModule, setOpenModule] = useState<string | null>(null)

  // Per-row command state (the ModulesPanel Record idiom — module rows and room slots share the
  // maps; instance uuids and `room-N` keys cannot collide).
  const [pending, setPending] = useState<Record<string, boolean>>({})
  const [rowNote, setRowNote] = useState<Record<string, string | null>>({})

  // Rename (re-homed from ShipStatusCard — same guard idiom, non-optimistic).
  const [renaming, setRenaming] = useState(false)
  const [nameDraft, setNameDraft] = useState('')
  const [renameBusy, setRenameBusy] = useState(false)
  const [renameError, setRenameError] = useState<string | null>(null)

  // Repair (re-homed from ShipStatusCard — the free ungated path).
  const [repairing, setRepairing] = useState(false)
  const [repairError, setRepairError] = useState<string | null>(null)

  const guards = useActivityPanelGuards()
  const { activeRef } = guards

  const refresh = useCallback(async () => {
    // One batched per-ship wave (the ShipDossier refresh idiom): RPC reads carry their own dark
    // envelopes; direct selects collapse to []/null inside their wrappers.
    const [inst, cargo, preview, decks, rooms, soulData, buffData, modCatalog] = await Promise.all([
      getMyModuleInstances(), // fit candidates (module_crafting read; dark → no candidate list)
      getShipCargoLots(shipId),
      fetchMyExpeditionPreview(shipId),
      getShipStations(),
      getMyShipRoomSlots(shipId),
      fetchShipSoul(shipId),
      fetchShipCommandBuff(shipId),
      fetchModuleCatalog(), // public catalog: module stats/attributes/description for tap-to-info
    ])
    if (!activeRef.current) return
    setInstancesRes(inst)
    setLots(cargo)
    setStatsPreview(preview)
    setStations(decks)
    setRoomSlotsRes(rooms)
    setSoul(soulData)
    setCommandBuff(buffData)
    setModuleCatalog(modCatalog)
  }, [activeRef, shipId])

  // refreshKey is a deliberate re-fetch trigger (the ShipDossier dep idiom).
  useEffect(() => {
    void refresh()
  }, [refresh, refreshKey])

  async function doRename() {
    if (!guards.tryClaim('rename')) return
    setRenameBusy(true)
    setRenameError(null)
    try {
      const clean = normalizeShipName(nameDraft)
      if (shipNameProblem(nameDraft) || clean === ship.name) return // Save disabled for these; belt-and-braces
      const res = await renameMainShip(clean, shipId) // explicit ship id; server asserts ownership
      if (!activeRef.current) return
      if (res.ok) {
        await onIdentityChanged() // refetch — the new name arrives from the server, never patched locally
        if (activeRef.current) setRenaming(false)
      } else {
        setRenameError(renameReasonMessage(res.reason))
      }
    } finally {
      guards.release('rename')
      if (activeRef.current) setRenameBusy(false)
    }
  }

  // NO-SOFTLOCK: the free repair path (repair_main_ship — deliberately ungated server-side, 0052).
  async function doRepair() {
    if (!guards.tryClaim('repair')) return
    setRepairing(true)
    setRepairError(null)
    try {
      await repairMainShip(shipId) // explicit ship id; server asserts ownership
      await onIdentityChanged()
    } catch (e) {
      if (activeRef.current) setRepairError(e instanceof Error ? e.message : String(e))
    } finally {
      guards.release('repair')
      if (activeRef.current) setRepairing(false)
    }
  }

  // The ONE guarded fit/unfit body (the ModulesPanel runFitting shape, re-homed with the surface).
  async function runFitting(m: { instance_id: string; name: string }, exec: () => Promise<FittingCommandResult>, verb: string) {
    await runGuardedCommand({
      key: m.instance_id,
      guards,
      setPending: (on) => setPending((p) => ({ ...p, [m.instance_id]: on })),
      setNote: (note) => setRowNote((n) => ({ ...n, [m.instance_id]: note })),
      exec,
      successNote: () => `${verb} ${m.name}.`,
      errorNote: (res) => {
        const base = res.message ?? fittingErrorMessage(res.code)
        return res.code === 'insufficient_slots' && res.limit != null
          ? `${base} (${res.used ?? 0}/${res.limit} used, needs ${res.cost ?? 0})`
          : base
      },
      // own wave (instances) + the screen's shared fittings read — never optimistic.
      refresh: async () => {
        await Promise.all([refresh(), onLoadoutChanged()])
      },
    })
  }

  // Room config (re-homed from ShipDossier — the CaptainsPanel guarded-submit idiom).
  async function configureRoom(slotIndex: number, roomTypeId: string) {
    await runGuardedCommand<ConfigureRoomResult>({
      key: `room-${slotIndex}`,
      guards,
      setPending: (on) => setPending((p) => ({ ...p, [`room-${slotIndex}`]: on })),
      setNote: (note) => setRowNote((n) => ({ ...n, [`room-${slotIndex}`]: note })),
      exec: () => configureShipRoom(shipId, slotIndex, roomTypeId),
      successNote: (res) => `Room set to ${stationLabel(stations, res.room_type_id)}.`,
      errorNote: (res) => roomConfigErrorMessage(res),
      refresh,
    })
  }

  // First load (cargo is the always-lit read → the loading sentinel; the ShipDossier posture).
  if (lots === null) {
    return (
      <Card data-testid="fitting-detail" aria-busy="true">
        <Skeleton className="h-5 w-36" />
        <Skeleton className="mt-3 h-8 w-full rounded-lg" />
        <Skeleton className="mt-2 h-8 w-2/3 rounded-lg" />
        <span className="sr-only">Reading the ship&rsquo;s fitting…</span>
      </Card>
    )
  }

  // ── pure projections (specs: tests/shipDossier.spec.ts, tests/fittingView.spec.ts) ─────────────
  const isDisabled = ship.status === 'destroyed'
  const gate = fittingEditability(position)
  const locLabel = fleetPositionLocationLabel(position, locations)
  const litFittings = allFittings ? fittingsForShip(allFittings, shipId) : null
  const slotsUsed = litFittings ? fittedSlotsUsed(litFittings) : 0
  const slotLimit = shipRow?.module_slots ?? null
  const litInstances = isServerLit(instancesRes) ? (instancesRes.instances ?? []) : null
  const candidates =
    litFittings !== null && litInstances !== null && allFittings !== null
      ? unfittedModuleInstances(litInstances, allFittings)
      : null
  const meters = shipRow ? shipMeterPair(shipRow) : null
  const slots = isServerLit(roomSlotsRes) ? (roomSlotsRes.slots ?? []) : null
  const roomBoard = shipCaptains && slots ? roomSlotBoard(slots, shipCaptains) : null
  const stacks = aggregateCargo(lots)
  const usedM3 = cargoUsedM3(lots)
  const shipStats = parseShipStatsPreview(statsPreview)
  const traitCards = soul && soul.rows.length > 0 ? shipTraitCards(soul.rows, soul.catalog) : null
  const commandBuffCard = commandBuff ? shipCommandBuffCard(commandBuff.buffId, commandBuff.catalog) : null
  // The TeamDossier chip idiom, verbatim classes — ship stats and team stats read as ONE system.
  const chip = (label: string, value: number | string) => (
    <span key={label} className="inline-flex items-baseline gap-1 rounded border border-edge bg-surface px-1.5 py-0.5 text-[10px]">
      <span className="text-ink-faint">{label}</span>
      <span className="font-mono tabular-nums text-ink">{value}</span>
    </span>
  )
  const num = (v: number | null): number | string => v ?? '—'

  // TAP-TO-INFO — the module catalog indexed by type id (null until the public catalog loads; a
  // row is interactive only once its info exists to reveal). Toggling closes any other open row.
  const moduleById = moduleCatalog ? new Map(moduleCatalog.map((m) => [m.id, m])) : null
  const toggleModule = (rowKey: string) => setOpenModule((cur) => (cur === rowKey ? null : rowKey))

  // The inline module-info card (the trait-card block's twin): signed stat effects + plain combat/
  // spatial attribute rows + description. Pure view-model from moduleInfoView; renders nothing when
  // the catalog lacks this type (fail-soft join miss).
  const moduleInfoPanel = (moduleTypeId: string, rowKey: string) => {
    const row = moduleById?.get(moduleTypeId)
    if (!row) return null
    const info = moduleInfoView(row)
    return (
      <div
        data-testid={`module-info-${rowKey}`}
        className="mt-1.5 rounded-lg border border-edge bg-surface-2/50 px-3 py-2"
      >
        <div className="flex flex-wrap items-center gap-1.5">
          <span className="rounded bg-accent/15 px-1.5 py-0.5 text-[10px] text-accent">{info.slotType}</span>
          {info.slotCost != null && (
            <span className="rounded bg-surface-2 px-1.5 py-0.5 text-[10px] text-ink-muted">
              {info.slotCost} {info.slotCost === 1 ? 'slot' : 'slots'}
            </span>
          )}
          {info.effects.map((e) => (
            <span
              key={e.label}
              className={`font-mono text-[10px] tabular-nums ${
                e.tone === 'positive' ? 'text-success' : 'text-danger'
              }`}
            >
              {e.label}
            </span>
          ))}
        </div>
        {info.attributes.length > 0 && (
          <div className="mt-1 flex flex-wrap gap-1.5">
            {info.attributes.map((a) => (
              <span
                key={a.label}
                className="inline-flex items-baseline gap-1 rounded border border-edge bg-surface px-1.5 py-0.5 text-[10px]"
              >
                <span className="text-ink-faint">{a.label}</span>
                <span className="font-mono tabular-nums text-ink">{a.value}</span>
              </span>
            ))}
          </div>
        )}
        {info.description && <p className="mt-1 text-[10px] text-ink-faint">{info.description}</p>}
      </div>
    )
  }

  return (
    <Card tone="accent" data-testid="fitting-detail">
      {/* IDENTITY — the class designator leads (the ShipStatusCard ops-register line), the
          renameable name is the big line; rename re-homed here with the detail. */}
      <CardHeader
        title={
          <span className="block">
            <span
              data-testid="mainship-class"
              className="block font-mono text-sm font-semibold uppercase tracking-widest text-accent"
            >
              {hullName ?? shipRow?.hull_type_id ?? ship.name}
            </span>
            <span className="inline-flex items-baseline gap-2">
              <span data-testid="mainship-name">{ship.name}</span>
              {!renaming && (
                <button
                  type="button"
                  data-testid="mainship-rename-open"
                  aria-label="Rename ship"
                  className="text-xs font-normal text-ink-faint underline-offset-2 hover:text-ink hover:underline"
                  onClick={() => {
                    setNameDraft(ship.name)
                    setRenameError(null)
                    setRenaming(true)
                  }}
                >
                  Rename
                </button>
              )}
            </span>
          </span>
        }
        aside={
          /* The badge tracks the SAME server-decided gate: 4c-mig-1 (0221) made berthed settled
             server-side (validate_context → state='home'), so berthed now reads editable too. */
          gate.editable ? (
            <Badge tone="success">Loadout editable</Badge>
          ) : (
            <Badge tone="neutral">Loadout locked</Badge>
          )
        }
        className="mb-2"
      />
      {renaming && (
        <div className="mb-3" data-testid="mainship-rename-form">
          <div className="flex items-center gap-2">
            <input
              value={nameDraft}
              maxLength={SHIP_NAME_MAX}
              autoFocus
              onChange={(e) => setNameDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') void doRename()
                if (e.key === 'Escape') setRenaming(false)
              }}
              className="min-w-0 flex-1 rounded-lg border border-edge bg-surface-2 px-2 py-1 text-sm text-ink"
              aria-label="Ship name"
              data-testid="mainship-rename-input"
            />
            <Button
              size="sm"
              variant="ghost"
              busy={renameBusy}
              busyLabel="Saving…"
              disabled={shipNameProblem(nameDraft) !== null || normalizeShipName(nameDraft) === ship.name}
              onClick={() => void doRename()}
              data-testid="mainship-rename-save"
            >
              Save
            </Button>
            <Button
              size="sm"
              variant="ghost"
              disabled={renameBusy}
              onClick={() => setRenaming(false)}
              data-testid="mainship-rename-cancel"
            >
              Cancel
            </Button>
          </div>
          {shipNameProblem(nameDraft) === 'name_empty' && nameDraft !== '' && (
            <p className="mt-1 text-xs text-ink-faint">{renameReasonMessage('name_empty')}</p>
          )}
          {renameError && (
            <Notice tone="danger" className="mt-2" data-testid="mainship-rename-error">
              {renameError}
            </Notice>
          )}
        </div>
      )}

      {/* LOCATION — the ONE read (map.fleetPositions), folded by the ONE shared adapter. HONEST:
          no row / hidden place → "Location unavailable", never a guessed port. */}
      <p data-testid="ship-location" className="mb-3 text-sm">
        <span className="text-ink-faint">Location · </span>
        {locLabel ? (
          <span className="font-medium text-ink">{locLabel}</span>
        ) : (
          <span className="text-ink-muted">Location unavailable</span>
        )}
      </p>

      {/* CONDITION — the shared shield/hull pair (shield row data-gated inside). */}
      {meters && (
        <div data-testid="fitting-meters">
          <MeterPairBars pair={meters} hullTone={isDisabled ? 'danger' : meters.hull.pct < 100 ? 'accent' : 'success'} />
        </div>
      )}

      {/* NO-SOFTLOCK — the UNGATED free repair (0052): a destroyed ship recovers ONLY through this
          path (RepairPanel's paid desk explicitly defers to it), so it renders on the detail for
          any disabled ship, independent of every flag. */}
      {isDisabled && (
        <div className="mt-3 rounded-lg border border-edge bg-surface-2/50 p-3">
          <Notice tone="warning" data-testid="mainship-disabled-note" className="mb-2">
            🛠 This ship is disabled. Repair it to get moving again.
          </Notice>
          {repairError && (
            <Notice tone="danger" data-testid="mainship-repair-error" className="mb-2">
              {repairError}
            </Notice>
          )}
          <Button
            variant="warning"
            data-testid="mainship-repair"
            busy={repairing}
            busyLabel="Repairing…"
            onClick={() => void doRepair()}
            className="min-h-11 w-full"
          >
            Repair ship
          </Button>
        </div>
      )}

      {/* SHIP-POWER — the per-ship stats strip (server truth; hidden while dark/no-ship). */}
      {shipStats.kind !== 'hidden' && (
        <div data-testid="ship-stats-strip" className="mt-3 rounded-lg border border-edge bg-surface-2/50 px-3 py-2">
          <p className="text-[10px] text-ink-faint">Ship stats · server truth</p>
          {shipStats.kind === 'invalid' ? (
            <p data-testid="ship-stats-error" className="mt-1 text-[10px] text-warning">
              {shipStatsErrorMessage(shipStats.error)}
            </p>
          ) : (
            <div data-testid="ship-stats" className="mt-1.5 flex flex-wrap gap-1.5">
              {chip('Power', num(shipStats.stats.combat_power))}
              {chip('Survival', num(shipStats.stats.survival))}
              {chip('Speed', num(shipStats.stats.speed))}
              {/* the adapter's ABSTRACT cargo stat — 'cap', never the hold's m³ */}
              {chip('Cargo cap', num(shipStats.stats.cargo_capacity))}
            </div>
          )}
        </div>
      )}

      {/* TRAITS (SOUL-2) — identity before loadout; dark/error → nothing (byte-identical). */}
      {traitCards && (
        <>
          <SectionLabel className="mt-4">Traits</SectionLabel>
          <ul data-testid="soul-traits" className="mt-2 space-y-1.5">
            {traitCards.map((t) =>
              t.kind === 'trait' ? (
                <li
                  key={t.slot}
                  data-testid={`soul-trait-${t.trait_type_id}`}
                  className="rounded-lg border border-edge bg-surface-2/50 px-3 py-2"
                >
                  <div className="flex items-baseline justify-between gap-2">
                    <span className="truncate text-sm text-ink">{t.name}</span>
                    <span className="flex shrink-0 flex-wrap justify-end gap-1.5">
                      {t.effects.map((e) => (
                        <span
                          key={e.label}
                          className={`font-mono text-[10px] tabular-nums ${
                            e.tone === 'positive' ? 'text-success' : 'text-danger'
                          }`}
                        >
                          {e.label}
                        </span>
                      ))}
                    </span>
                  </div>
                  <p className="mt-0.5 text-[10px] text-ink-faint">{t.description}</p>
                </li>
              ) : (
                <li
                  key={t.slot}
                  data-testid={`soul-trait-${t.trait_type_id}`}
                  className="rounded-lg border border-dashed border-edge px-3 py-2 text-[10px] text-ink-faint"
                >
                  Unknown trait
                </li>
              ),
            )}
          </ul>
        </>
      )}

      {/* COMMAND BUFF (0205) — dormant until this ship is its fleet's command ship. */}
      {commandBuffCard && (
        <>
          <SectionLabel className="mt-4">Command buff</SectionLabel>
          {commandBuffCard.kind === 'buff' ? (
            <div
              data-testid="command-buff"
              data-buff-id={commandBuffCard.buff_id}
              className="mt-2 rounded-lg border border-edge bg-surface-2/50 px-3 py-2"
            >
              <div className="flex items-baseline justify-between gap-2">
                <span className="truncate text-sm text-ink">{commandBuffCard.name}</span>
                <span className="flex shrink-0 flex-wrap justify-end gap-1.5">
                  {commandBuffCard.effects.map((e) => (
                    <span
                      key={e.label}
                      className={`font-mono text-[10px] tabular-nums ${
                        e.tone === 'positive' ? 'text-success' : 'text-danger'
                      }`}
                    >
                      {e.label}
                    </span>
                  ))}
                </span>
              </div>
              <p className="mt-0.5 text-[10px] text-ink-faint">{commandBuffCard.description}</p>
              <p data-testid="command-buff-note" className="mt-1 text-[10px] text-ink-muted">
                Applies to the whole fleet when this ship is the command ship.
              </p>
            </div>
          ) : (
            <div
              data-testid="command-buff"
              data-buff-id={commandBuffCard.buff_id}
              className="mt-2 rounded-lg border border-dashed border-edge px-3 py-2 text-[10px] text-ink-faint"
            >
              Unknown command buff
            </div>
          )}
        </>
      )}

      {/* ── THE FITTING SURFACE — the ONE fit/unfit edit surface in the app (Workshop rows retired
          this same slice). Server-lit on get_my_ship_fittings; enable derives from the SAME
          positions row — the server's settled-safe rule stays the enforcer. Docked AND berthed
          ships are editable (4c-mig-1/0221 made berthed resolve to state='home'); transit/in_space/
          hidden stay locked and the gate note explains why. */}
      {litFittings && (
        <>
          <div className="mt-4 flex items-baseline justify-between gap-2">
            <SectionLabel className="mb-0">Fitted modules</SectionLabel>
            <span data-testid="fitting-slot-usage" className="font-mono text-xs tabular-nums text-ink-muted">
              {slotLimit != null ? `${slotsUsed}/${slotLimit} slots` : `${slotsUsed} slots used`}
            </span>
          </div>
          {!gate.editable && gate.reason && (
            <p data-testid="fitting-gate-note" className="mt-1 text-[10px] text-ink-muted">
              {fitGateMessage(gate.reason)}
            </p>
          )}
          {litFittings.length > 0 ? (
            <ul data-testid="fitting-fitted" className="mt-2 space-y-1.5">
              {litFittings.map((f) => {
                const isPending = !!pending[f.module_instance_id]
                const note = rowNote[f.module_instance_id]
                return (
                  <li key={f.module_instance_id} data-testid={`fitting-fitted-${f.module_instance_id}`} className="text-xs">
                    <div className="flex items-center justify-between gap-2">
                      {moduleById ? (
                        <button
                          type="button"
                          data-testid={`fitting-info-toggle-${f.module_instance_id}`}
                          aria-expanded={openModule === f.module_instance_id}
                          onClick={() => toggleModule(f.module_instance_id)}
                          className="flex min-w-0 items-center gap-1 rounded text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent/60"
                        >
                          <ItemChip id={f.module_type_id} kind="module" label={f.name} />
                          <span
                            aria-hidden="true"
                            className={`shrink-0 text-ink-faint transition-transform ${
                              openModule === f.module_instance_id ? 'rotate-180' : ''
                            }`}
                          >
                            ▾
                          </span>
                        </button>
                      ) : (
                        <ItemChip id={f.module_type_id} kind="module" label={f.name} />
                      )}
                      <Button
                        variant="secondary"
                        size="sm"
                        data-testid={`fitting-unfit-${f.module_instance_id}`}
                        disabled={!gate.editable}
                        busy={isPending}
                        busyLabel="Unfitting…"
                        onClick={() =>
                          void runFitting(
                            { instance_id: f.module_instance_id, name: f.name },
                            () => unfitModuleFromShip(f.module_instance_id, crypto.randomUUID()),
                            'Unfitted',
                          )
                        }
                      >
                        Unfit
                      </Button>
                    </div>
                    {openModule === f.module_instance_id && moduleInfoPanel(f.module_type_id, f.module_instance_id)}
                    {note && (
                      <p data-testid={`fitting-note-${f.module_instance_id}`} className="mt-0.5 text-[10px] text-accent">
                        {note}
                      </p>
                    )}
                  </li>
                )
              })}
            </ul>
          ) : (
            <p data-testid="fitting-fitted-empty" className="mt-2 text-sm text-ink-faint">
              No modules fitted.
            </p>
          )}

          {/* Available (unfitted) modules — fit candidates for THIS ship (the row IS the ship;
              no ship picker). Craft new modules in Port → Workshop. */}
          {candidates !== null && (
            <>
              <SectionLabel className="mt-4">Available modules</SectionLabel>
              {candidates.length > 0 ? (
                <ul data-testid="fitting-available" className="mt-2 space-y-1.5">
                  {candidates.map((m: ModuleInstance) => {
                    const isPending = !!pending[m.instance_id]
                    const note = rowNote[m.instance_id]
                    return (
                      <li key={m.instance_id} data-testid={`fitting-available-${m.instance_id}`} className="text-xs">
                        <div className="flex items-center justify-between gap-2">
                          {moduleById ? (
                            <button
                              type="button"
                              data-testid={`fitting-info-toggle-${m.instance_id}`}
                              aria-expanded={openModule === m.instance_id}
                              onClick={() => toggleModule(m.instance_id)}
                              className="flex min-w-0 items-center gap-1.5 rounded text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent/60"
                            >
                              <ItemGlyph id={m.module_type_id} kind="module" size={14} className="shrink-0 text-accent" />
                              <span className="truncate text-ink">{m.name}</span>
                              <span className="shrink-0 rounded bg-accent/15 px-1.5 py-0.5 text-[9px] text-accent">
                                {m.slot_type}
                              </span>
                              <span
                                aria-hidden="true"
                                className={`shrink-0 text-ink-faint transition-transform ${
                                  openModule === m.instance_id ? 'rotate-180' : ''
                                }`}
                              >
                                ▾
                              </span>
                            </button>
                          ) : (
                            <span className="flex min-w-0 items-center gap-1.5">
                              <ItemGlyph id={m.module_type_id} kind="module" size={14} className="shrink-0 text-accent" />
                              <span className="truncate text-ink">{m.name}</span>
                              <span className="shrink-0 rounded bg-accent/15 px-1.5 py-0.5 text-[9px] text-accent">
                                {m.slot_type}
                              </span>
                            </span>
                          )}
                          <Button
                            variant="primary"
                            size="sm"
                            data-testid={`fitting-fit-${m.instance_id}`}
                            disabled={!gate.editable}
                            busy={isPending}
                            busyLabel="Fitting…"
                            onClick={() =>
                              void runFitting(m, () => fitModuleToShip(m.instance_id, shipId, crypto.randomUUID()), 'Fitted')
                            }
                          >
                            Fit
                          </Button>
                        </div>
                        {openModule === m.instance_id && moduleInfoPanel(m.module_type_id, m.instance_id)}
                        {note && (
                          <p data-testid={`fitting-note-${m.instance_id}`} className="mt-0.5 text-[10px] text-accent">
                            {note}
                          </p>
                        )}
                      </li>
                    )
                  })}
                </ul>
              ) : (
                <p data-testid="fitting-available-empty" className="mt-2 text-sm text-ink-faint">
                  No spare modules — craft new ones in Port → Workshop.
                </p>
              )}
            </>
          )}
        </>
      )}

      {/* CAPTAINS & ROOMS — the ROOMS-8 configurable board, re-homed with the detail (server-lit
          gated: captain_assignment_enabled dark → shipCaptains null → nothing renders). */}
      {shipCaptains && (
        <>
          <SectionLabel className="mt-4">Captains &amp; rooms</SectionLabel>
          {roomBoard ? (
            <ul data-testid="fitting-captains" className="mt-2 space-y-1.5">
              {roomBoard.rows.map(({ slot, captain }) => {
                const staffed = captain != null
                const isPending = pending[`room-${slot.slot_index}`] ?? false
                const note = rowNote[`room-${slot.slot_index}`]
                const options = roomPickerOptions(stations, slots ?? [], slot.slot_index)
                return (
                  <li
                    key={slot.slot_index}
                    data-testid={`room-slot-${slot.slot_index}`}
                    className="flex flex-col gap-0.5 text-sm"
                  >
                    <div className="flex items-center justify-between gap-2">
                      <select
                        data-testid={`room-pick-${slot.slot_index}`}
                        aria-label={`Room for slot ${slot.slot_index}`}
                        value={slot.room_type_id}
                        disabled={staffed || isPending}
                        onChange={(e) => void configureRoom(slot.slot_index, e.target.value)}
                        className="w-28 shrink-0 rounded border border-edge bg-surface-2 px-1 py-0.5 text-[10px] text-ink disabled:opacity-70"
                      >
                        {options.map((room) => (
                          <option key={room.station_id} value={room.station_id}>
                            {room.name}
                          </option>
                        ))}
                      </select>
                      {captain ? (
                        <div
                          data-testid={`fitting-captain-${captain.instance_id}`}
                          className="flex min-w-0 flex-1 flex-col gap-0.5"
                        >
                          <span className="flex items-center justify-between gap-2">
                            <span className="truncate text-ink">{captain.name}</span>
                            <span className="shrink-0 rounded bg-surface-2 px-1.5 py-0.5 text-[10px] text-ink-muted">
                              {captain.specialization}
                            </span>
                          </span>
                          <CaptainXpBar xp={captain.xp} level={captain.level} instanceId={captain.instance_id} />
                        </div>
                      ) : (
                        <span
                          data-testid={`room-empty-${slot.slot_index}`}
                          className="flex-1 rounded border border-dashed border-edge px-1.5 py-0.5 text-[10px] text-ink-faint"
                        >
                          Empty room
                        </span>
                      )}
                    </div>
                    {note && (
                      <p data-testid={`room-note-${slot.slot_index}`} className="text-[10px] text-accent">
                        {note}
                      </p>
                    )}
                  </li>
                )
              })}
              {/* general quarters: a captain with no/unknown room still shows — never hidden. */}
              {roomBoard.unstationed.map((c) => (
                <li key={c.instance_id} data-testid={`fitting-captain-${c.instance_id}`} className="text-sm">
                  <div className="flex items-center justify-between gap-2">
                    <span className="truncate text-ink">{c.name}</span>
                    <span className="shrink-0 rounded bg-surface-2 px-1.5 py-0.5 text-[10px] text-ink-muted">
                      {c.specialization}
                    </span>
                  </div>
                  <CaptainXpBar xp={c.xp} level={c.level} instanceId={c.instance_id} />
                </li>
              ))}
            </ul>
          ) : shipCaptains.length > 0 ? (
            <ul data-testid="fitting-captains" className="mt-2 space-y-1.5">
              {shipCaptains.map((c) => (
                <li key={c.instance_id} data-testid={`fitting-captain-${c.instance_id}`} className="text-sm">
                  <div className="flex items-center justify-between gap-2">
                    <span className="truncate text-ink">{c.name}</span>
                    <span className="shrink-0 rounded bg-surface-2 px-1.5 py-0.5 text-[10px] text-ink-muted">
                      {c.specialization}
                    </span>
                  </div>
                  <CaptainXpBar xp={c.xp} level={c.level} instanceId={c.instance_id} />
                </li>
              ))}
            </ul>
          ) : null}
          {!roomBoard && shipCaptains.length === 0 && (
            <p data-testid="fitting-captains-empty" className="mt-2 text-sm text-ink-faint">
              No captain assigned.
            </p>
          )}
        </>
      )}

      {/* CARGO HOLD — plain owner-read data (works undocked; the MarketPanel lot-sum formula). */}
      <div className="mt-4 flex items-baseline justify-between gap-2">
        <SectionLabel className="mb-0">Cargo hold</SectionLabel>
        <span data-testid="fitting-cargo-m3" className="font-mono text-xs tabular-nums text-ink-muted">
          {formatM3(usedM3)} / {formatM3(ship.cargo_capacity_m3)} m³
        </span>
      </div>
      {stacks.length > 0 ? (
        <div data-testid="fitting-cargo" className="mt-2 grid grid-cols-2 gap-2 sm:grid-cols-3">
          {stacks.map((s) => (
            <ItemTile
              key={s.good_id}
              data-testid={`fitting-cargo-${s.good_id}`}
              id={s.good_id}
              kind="good"
              qty={s.qty}
              hint={`${formatM3(s.m3)} m³`}
            />
          ))}
        </div>
      ) : (
        <p data-testid="fitting-cargo-empty" className="mt-2 text-sm text-ink-faint">
          Hold empty.
        </p>
      )}
    </Card>
  )
}
