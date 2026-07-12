import { useCallback, useEffect, useRef, useState } from 'react'
import { runGuardedCommand, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { fetchMyItemBalances } from '../modules/modulesApi'
import { fetchMyMainShips } from '../map/mainshipApi'
import { getMyCaptainInstances } from '../captains/captainsApi'
import { getWalletBalance } from '../map/tradeApi'
import {
  getHullBuildRecipes,
  getHullRecipeIngredients,
  getHullTypeNames,
  getMyActiveBuildOrders,
  getShipyardConfigRows,
  startHullBuild,
} from './shipyardApi'
import {
  activeOrderCount,
  bestCaptainLevel,
  captainGateState,
  hullGateState,
  hullOrderViews,
  shipyardConfigFromRows,
  shipyardEffectiveCredits,
  shipyardOrderAvailability,
  shipyardOrderBlocks,
  shipyardRecipeEntries,
  shipyardRejectNote,
  shipyardSuccessNote,
  type BuildOrderRow,
  type HullBuildRecipeRow,
  type HullRecipeIngredientRow,
  type ShipyardConfig,
} from './shipyard'
import { shipyardReasonMessage } from './shipyardReasonMessage'
import { salvageStickyLit, salvageWalletDisplay } from './salvageMarket'
import { formatDateTime, formatDuration } from '../../lib/time'
import { Badge, Button, Card, CardHeader, SectionLabel, Skeleton } from '../../components/ui'
import { ItemChip, titleCaseId } from '../../components/items'

// SHIPYARD-3 — the dark shipyard ORDER surface: the port's hull build catalog (hull_build_recipes
// + hull_recipe_ingredients, 0185 — public Reference/Config) as per-recipe cards with the full
// price (credits + build time + the ingredient bill against your own stock) and ONE intentional
// Order per recipe (start_hull_build, 0188 — the only shipyard command), plus a read-only MY
// ORDERS strip over the owner build_orders rows. CLIENT-FLAG-GATED on the SERVER'S OWN flag, read
// honestly from PUBLIC-READ game_config (the SalvageMarketPanel posture verbatim): 0185/0188
// shipped NO read RPC for the shipyard — the catalog is public Reference/Config — so there is no
// server-lit read envelope to gate on; instead the panel reads shipyard_enabled itself and
// renders NOTHING unless it is jsonb true (strict fail-closed coercion). While the flag is false
// (production today) the panel is null AND the server would reject any order with
// feature_disabled before any read, in BOTH its layers — double fail-closed, the client is never
// the control. NO optimistic UI: every order awaits the server then refetches the catalog +
// inventory + wallet + the order strip; the success note carries the SERVER-receipted
// credits_spent and exact ingredient bill, never client math. All prechecks are ADVISORY (the M2
// posture — every one flows through the ONE shipyardReasonMessage mapper; 0188 enforces under its
// per-player lock).
//
// ── THE SHIPYARD-2 SEAM (scope freeze — deliberate, load-bearing) ────────────────────────────────
// This panel is the ORDER side ONLY (the 0188 charter seam): validate → spend → enqueue →
// receipt. There is deliberately NO CANCEL affordance on the MY ORDERS strip: SHIPYARD-2 (in
// flight in a sibling worktree) owns build COMPLETION/DELIVERY *and* the hull-aware cancel-refund
// semantics — today's live cancel_build_order (0038) would refund only metal_spent (= 0 on a hull
// order) and EAT the ingredients/credits, so surfacing it here would be a player trap. A
// follow-up slice wires the cancel button once SHIPYARD-2's refund semantics are deployed.
// Likewise no countdown/progress: a hull order sits 'waiting' (paid up front, the M4.5 law) until
// the SHIPYARD-2 engine promotes it — the strip states the status honestly and nothing more.
//
// GATE HONESTY (no false greens): the T1 seeds carry NULL progression gates (dormant). If a
// future recipe sets required_hull_type_id, the client CAN answer it (main_ship_instances is
// owner-read) → met/unmet is shown; required_captain_level rides get_my_captain_instances, which
// is captain-gate-DARK today → the gate renders as a STATIC requirement line with no met/unmet
// claim until captains light (shipyard.ts GateState 'unknown'). Both reads happen ONLY when a
// loaded recipe actually carries the gate — zero extra reads on the T1 catalog.

export function ShipyardPanel({
  // The ship's server-reported docked location (PortScreen's dock projection). mainShipId rides
  // the port-service sibling props contract (SalvageMarketPanel/HaulBoardPanel) but is unused
  // here BY DESIGN: start_hull_build is player-scoped (0188 — no ship/dock parameter); the
  // SHIPYARD-2 cancel follow-up is the expected consumer.
  locationId,
  // Re-reads whenever the main-ship dock lifecycle changes (the SalvageMarketPanel dep idiom).
  lifecycleKey,
}: {
  locationId: string | null
  mainShipId: string | null
  lifecycleKey: string
}) {
  // null = flag unread (renders null — no pre-read flash); then the strict fold of the config read.
  const [cfg, setCfg] = useState<ShipyardConfig | null>(null)
  // null = not loaded · 'error' = catalog read failed (honest unavailable line) · rows otherwise.
  const [recipes, setRecipes] = useState<HullBuildRecipeRow[] | 'error' | null>(null)
  // [] doubles as "unreadable" (the bill still shows from the recipe view; the server charges it).
  const [ingredients, setIngredients] = useState<HullRecipeIngredientRow[]>([])
  const [hullNames, setHullNames] = useState<Record<string, string>>({})
  // null = own balances unreadable → stock hidden, the shortfall precheck SKIPPED (server answers).
  const [balances, setBalances] = useState<Record<string, number> | null>(null)
  // getWalletBalance semantics preserved verbatim (the salvage wallet posture): number | null
  // (lazy wallet — starting credits) | 'error' (unknown — never a false 0); undefined = unread.
  const [wallet, setWallet] = useState<number | null | 'error' | undefined>(undefined)
  // null = orders unreadable → strip hidden AND the cap precheck skipped (server answers).
  const [orders, setOrders] = useState<BuildOrderRow[] | null>(null)
  // Gate subjects — read ONLY when a loaded recipe carries the gate (see refresh); null = unknown.
  const [ownedHulls, setOwnedHulls] = useState<string[] | null>(null)
  const [captainLevel, setCaptainLevel] = useState<number | null>(null)
  // Per-recipe (id-keyed) pending + note Records — the SalvageMarketPanel per-row idiom.
  const [pending, setPending] = useState<Record<string, boolean>>({})
  const [rowNote, setRowNote] = useState<Record<string, string | null>>({})

  // Mounted + synchronous in-flight guards — the shared home of the idiom (useActivityPanelGuards).
  const guards = useActivityPanelGuards()
  const { activeRef } = guards

  // STICKY-LIT (the SalvageMarketPanel M1 posture, same fold): true once THIS MOUNT has seen the
  // flag genuinely enabled. A later failed/dark config re-read (a post-order refresh blip) must
  // not unmount the panel — and its freshly-set receipted success note — mid-interaction. First
  // mount reads stay fail-closed: dark until a POSITIVE strict read, so pre-flip production is
  // byte-unchanged.
  const litRef = useRef(false)

  const refresh = useCallback(async () => {
    // The gate read comes FIRST (the server's own order: flag before any read, 0188 both layers):
    // while the flag is dark — or the ship isn't docked — this panel performs NO catalog/
    // inventory/wallet/order read.
    const rows = await getShipyardConfigRows()
    const nextCfg = shipyardConfigFromRows(rows)
    if (nextCfg.enabled) litRef.current = true
    if (!salvageStickyLit(litRef.current, nextCfg.enabled) || locationId == null) {
      if (!activeRef.current) return
      setCfg(nextCfg)
      setRecipes(null)
      setIngredients([])
      setHullNames({})
      setBalances(null)
      setWallet(undefined)
      setOrders(null)
      setOwnedHulls(null)
      setCaptainLevel(null)
      return
    }
    const [rec, ing, names, b, w, ord] = await Promise.all([
      getHullBuildRecipes(),
      getHullRecipeIngredients(),
      getHullTypeNames(),
      fetchMyItemBalances(),
      getWalletBalance(),
      getMyActiveBuildOrders(),
    ])
    // Gate-subject reads ONLY when a loaded recipe carries the gate (both T1 seeds are NULL-gated,
    // so production performs neither read; the day a T2 recipe lands, the reads light with it).
    let owned: string[] | null = null
    if (rec?.some((r) => r.required_hull_type_id !== null)) {
      const ships = await fetchMyMainShips()
      // fetchMyMainShips folds errors to [] — but a docked player owns ≥1 ship, so [] can only
      // mean the read failed → treat as UNKNOWN (gate line goes static), never a false unmet.
      owned = ships.length > 0 ? ships.filter((s) => s.status !== 'destroyed').map((s) => s.hull_type_id) : null
    }
    let level: number | null = null
    if (rec?.some((r) => r.required_captain_level !== null)) {
      const roster = await getMyCaptainInstances()
      // Captains are gate-dark today → { ok:false } → null → the STATIC requirement line (honest).
      level = bestCaptainLevel(roster.ok ? (roster.captains ?? []) : null)
    }
    if (!activeRef.current) return
    // On a sticky transient (config unreadable AFTER being lit) keep the PRIOR cfg — the panel
    // stays rendered and the startingCredits seed isn't wiped; a genuine lit re-read updates it.
    setCfg((prev) => (nextCfg.enabled ? nextCfg : (prev ?? nextCfg)))
    setRecipes(rec ?? 'error')
    setIngredients(ing ?? [])
    setHullNames(names)
    setBalances(b)
    setWallet(w)
    setOrders(ord)
    setOwnedHulls(owned)
    setCaptainLevel(level)
  }, [activeRef, locationId]) // locationId is a real dep — refetch when the docked port changes

  // lifecycleKey is a deliberate re-fetch trigger (the SalvageMarketPanel dep idiom).
  useEffect(() => {
    void refresh()
  }, [refresh, lifecycleKey])

  // One intentional Order per recipe card — the shared guarded-submit body over the per-recipe
  // key; fresh crypto.randomUUID() per submit (the server dedups on (player_id, request_id)).
  // NON-OPTIMISTIC: success refetches the catalog + inventory + wallet + orders via refresh().
  async function order(hullTypeId: string) {
    await runGuardedCommand({
      key: hullTypeId,
      guards,
      setPending: (on) => setPending((p) => ({ ...p, [hullTypeId]: on })),
      setNote: (note) => setRowNote((n) => ({ ...n, [hullTypeId]: note })),
      exec: () => startHullBuild(crypto.randomUUID(), hullTypeId),
      // Success feedback from the SERVER receipt (credits_spent + the exact bill) — never client
      // math. Rejects render the mapped copy PLUS the server's own reject context (have/need,
      // the cap, the gate identities — 0188's truthfulness channel, shipyardRejectNote).
      successNote: (res) => shipyardSuccessNote(res),
      errorNote: (res) => shipyardRejectNote(res, hullNames),
      refresh,
    })
  }

  // FAIL CLOSED: render nothing unless the server's flag read affirmatively lit the shipyard
  // (strict jsonb true). This is the dark path in production today (shipyard_enabled=false); an
  // unread flag, a FIRST-MOUNT failed config read ([] → dark) and an undocked ship collapse to
  // null the same way. Once lit this mount, a transient config blip keeps the PRIOR lit cfg
  // (sticky-lit, see refresh) so the panel never unmounts mid-interaction. The server would still
  // reject any order (feature_disabled, gate first, both layers).
  if (cfg == null || !cfg.enabled || locationId == null) return null

  const entries = recipes !== null && recipes !== 'error' ? shipyardRecipeEntries(recipes, ingredients, hullNames) : []
  const myOrders = orders !== null ? hullOrderViews(orders, hullNames) : []
  const effectiveCredits = shipyardEffectiveCredits(wallet, cfg.startingCredits)

  return (
    // The Card primitive owns the chrome (accent tone = the ship/production-family identity —
    // ShipStatusCard's register; the trade family keeps warning).
    <Card tone="accent" data-testid="shipyard-panel">
      <CardHeader title="Shipyard" subtitle="Order a new hull built from materials & credits." />

      {/* Current credits — the getWalletBalance semantics verbatim, through the ONE wallet display
          helper (salvageWalletDisplay — reused, not re-folded: same sentinels, same seed honesty;
          the commission walletBalanceLabel is shaped for its affordability object and lacks the
          'error'/unread sentinels, so the salvage helper is the one). */}
      <div className="mt-1 flex items-center justify-between gap-2 text-xs">
        <span className="text-ink-faint">Credits</span>
        <span data-testid="shipyard-wallet" className="font-mono tabular-nums text-accent">
          {salvageWalletDisplay(wallet, cfg.startingCredits)}
        </span>
      </div>

      <SectionLabel className="mt-3">Build catalog</SectionLabel>
      {recipes === null ? (
        // Transient only (refresh sets cfg + recipes together) — a quiet skeleton, never a flash.
        <div className="mt-1" aria-busy="true">
          <Skeleton className="h-16 w-full rounded-lg" />
          <span className="sr-only">Loading the build catalog…</span>
        </div>
      ) : recipes === 'error' ? (
        <p data-testid="shipyard-unavailable" className="mt-1 text-[10px] text-ink-muted">
          Build catalog unavailable right now.
        </p>
      ) : entries.length === 0 ? (
        <p data-testid="shipyard-empty" className="mt-1 text-[10px] text-ink-muted">
          No hulls can be built here right now.
        </p>
      ) : (
        <ul data-testid="shipyard-list" className="mt-1 space-y-1.5">
          {entries.map((e) => {
            const avail = shipyardOrderAvailability({
              flagOn: true, // by construction: this list renders only under the cfg.enabled gate
              requiredHullTypeId: e.required_hull_type_id,
              ownedHullTypeIds: ownedHulls,
              requiredCaptainLevel: e.required_captain_level,
              bestCaptainLevel: captainLevel,
              queuedCount: orders !== null ? activeOrderCount(orders) : null,
              maxOrders: cfg.maxBuildOrders,
              ingredients: e.ingredients,
              balances,
              creditsCost: e.credits_cost,
              credits: effectiveCredits,
            })
            const hullGate = hullGateState(e.required_hull_type_id, ownedHulls)
            const captainGate = captainGateState(e.required_captain_level, captainLevel)
            const isPending = pending[e.hull_type_id] ?? false
            const note = rowNote[e.hull_type_id]
            return (
              <li
                key={e.hull_type_id}
                data-testid={`shipyard-recipe-${e.hull_type_id}`}
                className="rounded border border-edge/60 bg-surface-2/40 px-2 py-1.5"
              >
                {/* Identity — the ShipStatusCard class-designator loudness ('MULE-CLASS HAULER'):
                    no hull glyphs exist in the item catalog (itemGlyphs.ts is items/goods/modules/
                    resources), so the class NAME is the mark, in the accent ops register. */}
                <div className="flex items-baseline justify-between gap-2">
                  <span className="truncate font-mono text-xs font-semibold uppercase tracking-widest text-accent">
                    {e.name}
                  </span>
                  <span className="shrink-0 font-mono text-[10px] tabular-nums text-ink-muted">
                    {e.credits_cost.toLocaleString('en-US')} cr · {formatDuration(e.build_seconds)}
                  </span>
                </div>
                {/* The ingredient bill as ItemChips — ×qty = the recipe NEED; the hint = YOUR
                    stock (own-row read; hidden when balances are unreadable — precheck skipped,
                    server answers); alert = a KNOWN shortfall (advisory — the server enforces). */}
                <div className="mt-1 flex flex-wrap gap-1 text-[10px]">
                  {e.ingredients.map((ing) => {
                    const have = balances !== null ? (balances[ing.item_id] ?? 0) : null
                    return (
                      <ItemChip
                        key={ing.item_id}
                        id={ing.item_id}
                        kind="item"
                        qty={ing.qty}
                        hint={have !== null ? `have ${have.toLocaleString('en-US')}` : undefined}
                        alert={have !== null && have < ing.qty}
                      />
                    )
                  })}
                </div>
                {/* Progression gates, HONESTLY (no false greens): 'unknown' renders the STATIC
                    requirement line (captains are gate-dark → their levels are unreadable);
                    met/unmet only when the client could genuinely read the subject. */}
                {hullGate !== 'none' && (
                  <p className="mt-1 text-[10px] text-ink-muted">
                    Requires hull:{' '}
                    {hullNames[e.required_hull_type_id ?? ''] ?? titleCaseId(e.required_hull_type_id ?? '')}
                    {hullGate === 'met' ? ' — owned' : hullGate === 'unmet' ? ' — not owned' : ''}
                  </p>
                )}
                {captainGate !== 'none' && (
                  <p className="mt-1 text-[10px] text-ink-muted">
                    Requires a level {e.required_captain_level} captain
                    {captainGate === 'met' ? ' — met' : captainGate === 'unmet' ? ' — not met' : ''}
                  </p>
                )}
                <div className="mt-1.5 flex items-center justify-end gap-2">
                  <Button
                    variant="primary"
                    size="sm"
                    data-testid={`shipyard-order-${e.hull_type_id}`}
                    // Hard-disable ONLY on the structural dark gate (shipyardOrderBlocks — the M2
                    // posture, taken whole): balances/credits/queue/gates can all be STALE, so
                    // every player-state shortfall only ADVISES below and the server's
                    // under-lock re-check stays the enforcement.
                    disabled={shipyardOrderBlocks(avail.reason)}
                    busy={isPending}
                    busyLabel="Ordering…"
                    onClick={() => void order(e.hull_type_id)}
                    className="shrink-0"
                  >
                    Order build
                  </Button>
                </div>
                {/* Surface the display-only precheck through the ONE reason mapper — the same
                    wording the server's reject would produce (the SalvageMarketPanel idiom).
                    Advisory: the button above stays enabled. */}
                {avail.reason !== 'ok' && (
                  <p className="mt-0.5 text-[10px] text-ink-muted">{shipyardReasonMessage(avail.reason)}</p>
                )}
                {note && (
                  <p data-testid={`shipyard-note-${e.hull_type_id}`} className="mt-0.5 text-[10px] text-accent">
                    {note}
                  </p>
                )}
              </li>
            )
          })}
        </ul>
      )}

      {/* MY ORDERS — read-only strip over the owner build_orders rows (hull kind only,
          non-terminal). Empty/unreadable → nothing (the catalog is the panel's subject). NO
          cancel affordance — the SHIPYARD-2 seam (see the header comment): today's
          cancel_build_order would eat a hull order's ingredients/credits. */}
      {myOrders.length > 0 && (
        <>
          <SectionLabel className="mt-3">My build orders</SectionLabel>
          <ul data-testid="shipyard-orders" className="mt-1 space-y-1">
            {myOrders.map((o) => (
              <li
                key={o.id}
                data-testid={`shipyard-order-row-${o.id}`}
                className="flex items-center justify-between gap-2 rounded border border-edge/60 bg-surface-2/40 px-2 py-1 text-xs"
              >
                <span className="truncate font-mono text-[10px] font-semibold uppercase tracking-widest text-accent">
                  {o.name}
                </span>
                <span className="flex shrink-0 items-center gap-2">
                  <span className="font-mono text-[10px] tabular-nums text-ink-faint">
                    {formatDateTime(o.queued_at)}
                  </span>
                  <Badge tone={o.statusLabel === 'Building' ? 'accent' : 'neutral'}>{o.statusLabel}</Badge>
                </span>
              </li>
            ))}
          </ul>
        </>
      )}
    </Card>
  )
}
