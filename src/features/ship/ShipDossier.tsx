import { useCallback, useEffect, useState } from 'react'
import { isServerLit, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { fetchMyExpeditionPreview, fetchMyMainShips, resolveOwnedShip, type MainShipRow } from '../map/mainshipApi'
import { getMyShipFittings } from '../modules/modulesApi'
import { getMyCaptainInstances, getShipStations } from '../captains/captainsApi'
import { deckBoard, type ShipStation } from '../captains/deckStations'
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
  parseShipStatsPreview,
  shipStatsErrorMessage,
} from './shipDossierView'
import { shipTraitCards } from './shipTraits'
import { fetchShipSoul, type ShipSoulData } from './soulApi'
import { shipMeterPair } from './meterPair'
import { MeterPairBars } from './MeterPairBars'
import type { ShipLocationResolved } from './shipLocation'
import { Card, CardHeader, SectionLabel, Skeleton } from '../../components/ui'
import { ItemChip, ItemTile } from '../../components/items'

// SHIP-DOSSIER — the per-ship "what is on THIS ship" card (owner order: "each ship has its own
// modules, captain assigned, with inventory as well — I should be able to SEE this"). READ-ONLY
// composition of three surfaces that all existed but never AT the ship: fitted modules (the 0116
// read ModulesPanel uses for its own fit flow), assigned captains (the 0123 roster read), and the
// cargo hold (the ship_cargo_lots owner-read that previously rendered only inside the docked
// MarketPanel — the RLS is a plain owner-table select via the ship join, so it reads anywhere,
// docked or not). NO commands and NO new server surface — acting on the loadout stays in the
// command panels (modules: Port → Workshop; captains: CaptainsPanel beside); this card is the
// ship's paper.
//
// SHIP-POWER — the strip at the top adds the ship's OWN stats (the owner order: "the team has a
// power value whereas the individual ship does not show anything"): Power / Survival / Speed /
// Cargo cap as mono chips, the TeamDossier visual idiom, so ship stats and team stats read as ONE
// system. Fed by get_my_expedition_preview (0049/0159 — the LIVE per-ship read; empty loadout,
// neutral activity 'none', the EXPLICIT selected ship id) through the PURE parser
// (parseShipStatsPreview — fail-closed on every malformed/dark/no-ship shape). It rides the same
// batched refresh, so refreshKey re-reads it whenever loadout state moves (captain commands bump
// it on this screen; module edits happen at Port → Workshop and land here on route remount).
//
// LABEL HONESTY: the strip's cargo chip is the adapter's ABSTRACT `cargo_capacity` (the int
// column + module `cargo` bonuses, 0122/0180) — labeled 'Cargo cap', NEVER 'm³'. The authoritative
// VOLUME is the separate cargo_capacity_m3 column (0076 abstract-vs-volume split), which the Cargo
// hold line below and the market's buy enforcement (0089) use; the two numbers legitimately
// diverge (e.g. a fitted expanded_cargo_lattice raises the abstract cap, not the hold volume), so
// the strip must not wear the hold's unit.
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
//   · Traits (SOUL-2) — renders only when ship_traits_enabled is STRICTLY jsonb true (the shared
//     strictConfigFlag fold, read from PUBLIC-READ game_config inside fetchShipSoul) AND this ship
//     has stored trait rows. DARK today: fetchShipSoul's gate-first read costs ONE config select
//     and ZERO trait reads, returns null, and the card's DOM stays byte-identical. Transport
//     error while lit → null too (hidden — never a false 'no traits' empty).
//   · Cargo hold — plain owner-read data (no feature flag): always shown once loaded.

export function ShipDossier({
  selectedShip,
  // Re-reads on main-ship lifecycle transitions AND after a loadout-changing command elsewhere on
  // the screen (ShipScreen bumps its loadout revision into this key after a successful
  // assign/unassign/recruit — the non-optimistic await→refetch discipline; craft/fit moved to
  // Port → Workshop with WORKSHOP, and land here via route remount instead).
  refreshKey,
  // SHIPLOC — the selected ship's resolved LOCATION (from the shell's map poll, via the ONE shared
  // resolver in ShipScreen). null = the threaded data does NOT correspond to the selected ship (a
  // non-sole multi-ship selection, or still loading) → the strip shows "Location unavailable"
  // rather than a wrong place. Display-only; the server is the source of truth.
  location,
}: {
  selectedShip: SelectableShip | null
  refreshKey: string
  location: ShipLocationResolved | null
}) {
  const [fittings, setFittings] = useState<GetMyShipFittingsResult | null>(null)
  const [roster, setRoster] = useState<GetMyCaptainInstancesResult | null>(null)
  // DECKS-2: the six-station catalog (public-read Reference/Config; [] = read failed → the
  // captains section falls back to its pre-DECKS list shape, never a broken board).
  const [stations, setStations] = useState<ShipStation[]>([])
  const [lots, setLots] = useState<ShipCargoLot[] | null>(null)
  const [ships, setShips] = useState<MainShipRow[] | null>(null)
  // SHIP-POWER: the raw preview envelope (parsed at render — the parser owns every malformed shape).
  const [statsPreview, setStatsPreview] = useState<unknown>(null)
  // SOUL-2: the ship's rolled traits + catalog (null = dark gate / read error → section hidden).
  const [soul, setSoul] = useState<ShipSoulData | null>(null)

  // Mounted guard — the shared idiom home (read-only panel: no submit guards needed).
  const { activeRef } = useActivityPanelGuards()

  const shipId = selectedShip?.main_ship_id ?? null

  const refresh = useCallback(async () => {
    if (!shipId) return
    // One batched read wave (the ModulesPanel refresh idiom). The two RPC reads carry their own
    // dark envelopes (each section fails closed on !ok); the two direct selects are owner-read
    // RLS and collapse to []/null on error inside their wrappers.
    const [fit, cap, cargo, myShips, preview, decks, soulData] = await Promise.all([
      getMyShipFittings(),
      getMyCaptainInstances(),
      getShipCargoLots(shipId),
      fetchMyMainShips(), // module_slots for the slot-usage line (the ModulesPanel picker source)
      fetchMyExpeditionPreview(shipId), // SHIP-POWER: THIS ship's server stats (transport error → null → hidden)
      getShipStations(), // DECKS-2: the station catalog (public-read; [] on error → list fallback)
      fetchShipSoul(shipId), // SOUL-2: gate-first (dark → one config select, ZERO trait reads → null → hidden)
    ])
    if (!activeRef.current) return
    setFittings(fit)
    setRoster(cap)
    setLots(cargo)
    setShips(myShips)
    setStatsPreview(preview)
    setStations(decks)
    setSoul(soulData)
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
  // The dossier's OWN row for this ship (already fetched for the slot line) — also feeds the
  // SHIELD-2 meter pair below (shield/max_shield ride the same SHIP_COLS owner read).
  const dossierShip = resolveOwnedShip(ships ?? [], shipId)
  const slotLimit = dossierShip?.module_slots ?? null
  // SHIELD-2: the shield/hull pair view-model (pure — specs in tests/shipMeterPair.spec.ts).
  // The dossier had NO integrity bar before this slice, so the WHOLE pair is gated on the shield
  // reading existing (max_shield > 0): every ship is 0/0 on prod until the human ACT-SHIELD flip,
  // so the card's DOM stays byte-identical today — data-gated, no flag needed. (ShipStatusCard
  // beside it keeps its always-on hull bar; this card only joins the pair once shields are real.)
  const meters = dossierShip ? shipMeterPair(dossierShip) : null
  const litCaptains = isServerLit(roster) ? captainsForShip(roster.captains ?? [], shipId) : null
  // DECKS-2: the decks board view-model (pure; specs in tests/deckStations.spec.ts). null while
  // the roster is dark (nothing renders — unchanged posture) or the catalog read failed (list
  // fallback below).
  const board = litCaptains && stations.length > 0 ? deckBoard(stations, litCaptains) : null
  const stacks = aggregateCargo(lots)
  const usedM3 = cargoUsedM3(lots)
  // SHIP-POWER: the strip's parse (pure; specs in tests/shipDossier.spec.ts).
  const shipStats = parseShipStatsPreview(statsPreview)
  // SOUL-2: the traits view-model (pure join of stored rows × catalog, slot order; specs in
  // tests/shipTraits.spec.ts). Non-null ONLY when the gate read lit AND this ship has stored
  // rows — lit-with-zero-rows stays hidden (an unrolled pre-ACT-SOUL ship has no soul section
  // yet, not an empty one), and a null soul (dark / read error) renders nothing.
  const traitCards = soul && soul.rows.length > 0 ? shipTraitCards(soul.rows, soul.catalog) : null
  // The TeamDossier chip idiom, verbatim classes — ship stats and team stats read as ONE system.
  const chip = (label: string, value: number | string) => (
    <span key={label} className="inline-flex items-baseline gap-1 rounded border border-edge bg-surface px-1.5 py-0.5 text-[10px]">
      <span className="text-ink-faint">{label}</span>
      <span className="font-mono tabular-nums text-ink">{value}</span>
    </span>
  )
  const num = (v: number | null): number | string => v ?? '—'

  return (
    <Card data-testid="ship-dossier">
      <CardHeader title="On this ship" subtitle={selectedShip.name} className="mb-2" />

      {/* SHIPLOC — WHERE the ship is (owner: "in ship tab, i should be able to see where the ship
          is, the location as well"). Location is identity, so it leads, right under the name: docked
          port / in-transit destination + ETA / in combat / deep space / home. Resolved by the ONE
          shared helper (shipLocation.ts) that ShipStatusCard beside also uses — server truth, no new
          read. HONEST: a null resolution (a non-sole multi-ship selection today, or first paint)
          shows "Location unavailable", never a wrong place. */}
      <p data-testid="ship-location" className="mb-3 text-sm">
        <span className="text-ink-faint">Location · </span>
        {location ? (
          <>
            <span className="font-medium text-ink">{location.label}</span>
            {location.etaText && <span className="text-ink-muted"> · arrives in {location.etaText}</span>}
          </>
        ) : (
          <span className="text-ink-muted">Location unavailable</span>
        )}
      </p>

      {/* SHIELD-2 — the classic shield/hull pair (shield ABOVE hull), via the ONE shared bar
          component, ONLY once this ship has a real shield capacity (max_shield > 0; see the
          derivation note above — renders NOTHING on prod today). */}
      {meters?.shield && (
        <div className="mb-3" data-testid="dossier-meters">
          <MeterPairBars pair={meters} hullTone={meters.hull.pct < 100 ? 'accent' : 'success'} />
        </div>
      )}

      {/* SHIP-POWER — this ship's own stats strip (top): the same four numbers the TeamDossier
          strip totals across a team, for ONE ship, in the same chip language. Server truth: the
          preview delegates to the ONE stat adapter (0122 — modules + captains folded in). Hidden
          (not '—' noise) while the read is dark/no-ship; an invalid envelope shows its reason. */}
      {shipStats.kind !== 'hidden' && (
        <div data-testid="ship-stats-strip" className="rounded-lg border border-edge bg-surface-2/50 px-3 py-2">
          <p className="text-[10px] text-ink-faint">Ship stats · server truth</p>
          {shipStats.kind === 'invalid' ? (
            // The raw envelope `error` (0159 passes sqlerrm through) NEVER reaches the DOM —
            // shipStatsErrorMessage maps known tokens, unknown → generic (the teamReasonMessage mold).
            <p data-testid="ship-stats-error" className="mt-1 text-[10px] text-warning">
              {shipStatsErrorMessage(shipStats.error)}
            </p>
          ) : (
            <div data-testid="ship-stats" className="mt-1.5 flex flex-wrap gap-1.5">
              {chip('Power', num(shipStats.stats.combat_power))}
              {chip('Survival', num(shipStats.stats.survival))}
              {chip('Speed', num(shipStats.stats.speed))}
              {/* the adapter's ABSTRACT cargo stat — 'cap', not the hold's m³ (see header note) */}
              {chip('Cargo cap', num(shipStats.stats.cargo_capacity))}
            </div>
          )}
        </div>
      )}

      {/* TRAITS (SOUL-2) — the ship's rolled BIRTHMARKS (Uncharted-Waters "this ship is MINE"),
          at the top with the ship's name/stats: identity before loadout. Server truth only: the
          stored main_ship_traits rows joined against the public-read catalog — never a client
          re-derivation of the roll. Name loud, flavor muted, stat effects as signed green/red
          mono tokens (the house success/danger tones); the folded RESULT of these numbers is the
          stats strip above — this section shows the WHY. DARK (ship_traits_enabled false) or any
          read error → traitCards null → nothing renders (byte-identical card). */}
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
                // fail-closed join miss: a stored row whose type is missing from the catalog read
                // still shows (server truth never vanishes) — but only as an honest muted line.
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
              No modules fitted — craft &amp; fit in Port → Workshop.
            </p>
          )}
        </>
      )}

      {/* CAPTAINS — server-lit gated (captain_assignment_enabled — DARK today → renders NOTHING,
          label included, exactly like every captain surface; the decks board changes nothing
          about that posture — the isServerLit gate is unchanged and the one predicate).
          DECKS-2: the section IS the decks board — six named station rows (ship_stations order),
          each holding its captain or an "Empty station" slot (the owner order: "in ship i should
          be able to see decks … with empty slots"). Pure derivation in deckBoard (specs:
          tests/deckStations.spec.ts); catalog read failed ([]) → the exact pre-DECKS list shape
          (fail closed to yesterday, never a broken board). Acting stays in CaptainsPanel beside —
          this card remains the ship's paper. */}
      {litCaptains && (
        <>
          <SectionLabel className="mt-4">Captains</SectionLabel>
          {board ? (
            <ul data-testid="dossier-captains" className="mt-2 space-y-1.5">
              {board.rows.map(({ station, captain }) => (
                <li
                  key={station.station_id}
                  data-testid={`deck-station-${station.station_id}`}
                  className="flex items-center justify-between gap-2 text-sm"
                >
                  <span className="w-24 shrink-0 text-[10px] uppercase tracking-wide text-ink-faint">
                    {station.name}
                  </span>
                  {captain ? (
                    <span
                      data-testid={`dossier-captain-${captain.instance_id}`}
                      className="flex min-w-0 flex-1 items-center justify-between gap-2"
                    >
                      <span className="truncate text-ink">{captain.name}</span>
                      <span className="shrink-0 rounded bg-surface-2 px-1.5 py-0.5 text-[10px] text-ink-muted">
                        {captain.specialization}
                      </span>
                    </span>
                  ) : (
                    <span
                      data-testid={`deck-empty-${station.station_id}`}
                      className="flex-1 rounded border border-dashed border-edge px-1.5 py-0.5 text-[10px] text-ink-faint"
                    >
                      Empty station
                    </span>
                  )}
                </li>
              ))}
              {/* general quarters: a captain with no/unknown station (pre-backfill data or a
                  malformed row) still shows — the board never hides an assigned captain. */}
              {board.unstationed.map((c) => (
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
          ) : litCaptains.length > 0 ? (
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
          ) : null}
          {/* fallback path only (catalog read failed → no board): the pre-DECKS empty note. The
              lit board already SAYS empty — six "Empty station" slots — so the paragraph would be
              redundant noise beside it. */}
          {!board && litCaptains.length === 0 && (
            <p data-testid="dossier-captains-empty" className="mt-2 text-sm text-ink-faint">
              No captain assigned.
            </p>
          )}
        </>
      )}

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
