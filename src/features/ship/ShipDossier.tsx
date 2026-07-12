import { useCallback, useEffect, useState } from 'react'
import { isServerLit, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { fetchMyMainShips, resolveOwnedShip, type MainShipRow } from '../map/mainshipApi'
import { getMyShipFittings } from '../modules/modulesApi'
import { getMyCaptainInstances } from '../captains/captainsApi'
import { getShipCargoLots, type ShipCargoLot } from '../map/tradeApi'
import type { SelectableShip } from '../map/useMainShipSelection'
import type { GetMyShipFittingsResult } from '../modules/modulesTypes'
import type { GetMyCaptainInstancesResult } from '../captains/captainsTypes'
import {
  aggregateCargo,
  captainsForShip,
  cargoUsedM3,
  fittedSlotsUsed,
  fittingsForShip,
  formatM3,
} from './shipDossierView'
import { Card, CardHeader, SectionLabel, Skeleton } from '../../components/ui'
import { ItemChip, ItemTile } from '../../components/items'

// SHIP-DOSSIER — the per-ship "what is on THIS ship" card (owner order: "each ship has its own
// modules, captain assigned, with inventory as well — I should be able to SEE this"). READ-ONLY
// composition of three surfaces that all existed but never AT the ship: fitted modules (the 0116
// read ModulesPanel uses for its own fit flow), assigned captains (the 0123 roster read), and the
// cargo hold (the ship_cargo_lots owner-read that previously rendered only inside the docked
// MarketPanel — the RLS is a plain owner-table select via the ship join, so it reads anywhere,
// docked or not). NO commands and NO new server surface — acting on the loadout stays in
// ModulesPanel/CaptainsPanel below/beside; this card is the ship's paper.
//
// Composition: a sibling Card directly under ShipStatusCard in the Ship screen's main rail —
// ShipStatusCard keeps its "no own fetch" contract (it renders the shell's polled state), while
// the dossier owns the three reads it composes (the ModulesPanel fetch idiom: batch on mount /
// refreshKey change, mounted-guarded, non-optimistic).
//
// GATES (each section fails closed independently):
//   · Fitted modules — renders only when get_my_ship_fittings answers ok (module_fitting_enabled
//     — LIT today); dark/error → the section (label included) renders nothing.
//   · Captains — renders only when get_my_captain_instances answers ok (captain_assignment_enabled
//     — DARK today, so this section renders NOTHING in production, exactly like every captain
//     surface; isServerLit is the one predicate).
//   · Cargo hold — plain owner-read data (no feature flag): always shown once loaded.

export function ShipDossier({
  selectedShip,
  // Re-reads on main-ship lifecycle transitions AND after a loadout-changing command elsewhere on
  // the screen (ShipScreen bumps its loadout revision into this key after a successful
  // craft/fit/unfit/assign/unassign/recruit — the non-optimistic await→refetch discipline).
  refreshKey,
}: {
  selectedShip: SelectableShip | null
  refreshKey: string
}) {
  const [fittings, setFittings] = useState<GetMyShipFittingsResult | null>(null)
  const [roster, setRoster] = useState<GetMyCaptainInstancesResult | null>(null)
  const [lots, setLots] = useState<ShipCargoLot[] | null>(null)
  const [ships, setShips] = useState<MainShipRow[] | null>(null)

  // Mounted guard — the shared idiom home (read-only panel: no submit guards needed).
  const { activeRef } = useActivityPanelGuards()

  const shipId = selectedShip?.main_ship_id ?? null

  const refresh = useCallback(async () => {
    if (!shipId) return
    // One batched read wave (the ModulesPanel refresh idiom). The two RPC reads carry their own
    // dark envelopes (each section fails closed on !ok); the two direct selects are owner-read
    // RLS and collapse to []/null on error inside their wrappers.
    const [fit, cap, cargo, myShips] = await Promise.all([
      getMyShipFittings(),
      getMyCaptainInstances(),
      getShipCargoLots(shipId),
      fetchMyMainShips(), // module_slots for the slot-usage line (the ModulesPanel picker source)
    ])
    if (!activeRef.current) return
    setFittings(fit)
    setRoster(cap)
    setLots(cargo)
    setShips(myShips)
  }, [activeRef, shipId]) // activeRef identity is stable — dep satisfies the lint rule

  // refreshKey is a deliberate re-fetch trigger (the ModulesPanel lifecycleKey dep idiom).
  useEffect(() => {
    void refresh()
  }, [refresh, refreshKey])

  // No resolvable selected ship (none commissioned yet, or the selection still loading) → nothing;
  // ShipStatusCard's starter-hull teaser owns the no-ship story.
  if (!selectedShip || !shipId) return null

  // First load (cargo is the always-lit read, so it is the loading sentinel) → skeleton card.
  if (lots === null) {
    return (
      <Card data-testid="ship-dossier" aria-busy="true">
        <Skeleton className="h-5 w-36" />
        <Skeleton className="mt-3 h-8 w-full rounded-lg" />
        <Skeleton className="mt-2 h-8 w-2/3 rounded-lg" />
        <span className="sr-only">Reading the ship&rsquo;s dossier…</span>
      </Card>
    )
  }

  // ── per-ship projections (pure selectors — specs in tests/shipDossier.spec.ts) ────────────────
  const litFittings = isServerLit(fittings) ? fittingsForShip(fittings.fittings ?? [], shipId) : null
  const slotsUsed = litFittings ? fittedSlotsUsed(litFittings) : 0
  const slotLimit = resolveOwnedShip(ships ?? [], shipId)?.module_slots ?? null
  const litCaptains = isServerLit(roster) ? captainsForShip(roster.captains ?? [], shipId) : null
  const stacks = aggregateCargo(lots)
  const usedM3 = cargoUsedM3(lots)

  return (
    <Card data-testid="ship-dossier">
      <CardHeader title="On this ship" subtitle={selectedShip.name} className="mb-2" />

      {/* FITTED MODULES — only while the fitting read surface is lit (module_fitting_enabled). */}
      {litFittings && (
        <>
          <div className="mt-4 flex items-baseline justify-between gap-2">
            <SectionLabel className="mb-0">Fitted modules</SectionLabel>
            <span data-testid="dossier-slot-usage" className="font-mono text-xs tabular-nums text-ink-muted">
              {slotLimit != null ? `${slotsUsed}/${slotLimit} slots` : `${slotsUsed} slots used`}
            </span>
          </div>
          {litFittings.length > 0 ? (
            <div data-testid="dossier-modules" className="mt-2 flex flex-wrap gap-1.5 text-xs">
              {litFittings.map((f) => (
                <ItemChip
                  key={f.module_instance_id}
                  data-testid={`dossier-module-${f.module_instance_id}`}
                  id={f.module_type_id}
                  kind="module"
                  label={f.name}
                />
              ))}
            </div>
          ) : (
            <p data-testid="dossier-modules-empty" className="mt-2 text-sm text-ink-faint">
              No modules fitted — craft &amp; fit below.
            </p>
          )}
        </>
      )}

      {/* CAPTAINS — server-lit gated (captain_assignment_enabled — DARK today → renders NOTHING,
          label included, exactly like every captain surface). */}
      {litCaptains && (
        <>
          <SectionLabel className="mt-4">Captains</SectionLabel>
          {litCaptains.length > 0 ? (
            <ul data-testid="dossier-captains" className="mt-2 space-y-1.5">
              {litCaptains.map((c) => (
                <li
                  key={c.instance_id}
                  data-testid={`dossier-captain-${c.instance_id}`}
                  className="flex items-center justify-between gap-2 text-sm"
                >
                  <span className="truncate text-ink">{c.name}</span>
                  <span className="shrink-0 rounded bg-surface-2 px-1.5 py-0.5 text-[10px] text-ink-muted">
                    {c.specialization}
                  </span>
                </li>
              ))}
            </ul>
          ) : (
            <p data-testid="dossier-captains-empty" className="mt-2 text-sm text-ink-faint">
              No captain assigned.
            </p>
          )}
        </>
      )}

      {/* SHIP-SOUL anchor: the Traits section lands here (between the crew and the hold) when
          ship traits ship — same SectionLabel'd-group shape, same per-selected-ship scope. */}

      {/* CARGO HOLD — plain owner-read data (ship_cargo_lots via the ship-join RLS; reads anywhere,
          docked or not). Volume math is the MarketPanel lot-sum formula — the two surfaces agree. */}
      <div className="mt-4 flex items-baseline justify-between gap-2">
        <SectionLabel className="mb-0">Cargo hold</SectionLabel>
        <span data-testid="dossier-cargo-m3" className="font-mono text-xs tabular-nums text-ink-muted">
          {formatM3(usedM3)} / {formatM3(selectedShip.cargo_capacity_m3)} m³
        </span>
      </div>
      {stacks.length > 0 ? (
        <div data-testid="dossier-cargo" className="mt-2 grid grid-cols-2 gap-2 sm:grid-cols-3">
          {stacks.map((s) => (
            <ItemTile
              key={s.good_id}
              data-testid={`dossier-cargo-${s.good_id}`}
              id={s.good_id}
              kind="good"
              qty={s.qty}
              hint={`${formatM3(s.m3)} m³`}
            />
          ))}
        </div>
      ) : (
        <p data-testid="dossier-cargo-empty" className="mt-2 text-sm text-ink-faint">
          Hold empty.
        </p>
      )}
    </Card>
  )
}
