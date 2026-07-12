import { useCallback, useEffect, useRef, useState } from 'react'
import { runGuardedCommand, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { fetchMyItemBalances } from '../modules/modulesApi'
import { getWalletBalance } from '../map/tradeApi'
import { getPortItemDemand, getSalvageConfigRows, sellItemAtPort } from './salvageApi'
import {
  clampSellQty,
  salvageConfigFromRows,
  salvageEntries,
  salvageSellAvailability,
  salvageSellBlocks,
  salvageStickyLit,
  salvageWalletDisplay,
  sellTotal,
  type PortItemDemandRow,
  type SalvageConfig,
} from './salvageMarket'
import { salvageReasonMessage } from './salvageReasonMessage'
import { Button, Card, CardHeader, SectionLabel, Skeleton } from '../../components/ui'
import { ItemTile } from '../../components/items'

// SALVAGE-2 — the dark salvage-market surface: the docked port's item buy-list (port_item_demand,
// 0174) as ItemTiles with unit prices + the caller's own sellable stock, a qty stepper and ONE
// intentional Sell per item (sell_item_at_port — the only salvage command). CLIENT-FLAG-GATED on
// the SERVER'S OWN flag, read honestly from PUBLIC-READ game_config (0003 grant; the
// getCommissionConfigRows posture): 0174 shipped NO read RPC for salvage — the demand rows are
// public Reference/Config (the market_offers posture) — so there is no server-lit read envelope
// to gate on; instead the panel reads salvage_market_enabled itself and renders NOTHING unless it
// is jsonb true (strict — the commissionContextFromConfig fail-closed coercion). While the flag
// is false (production today) the panel is null AND the server would reject any sell with
// salvage_market_disabled before any read — double fail-closed, the client is never the control.
// NO optimistic UI: every sell awaits the server then refetches inventory + wallet + the
// buy-list. The availability mirror (salvageMarket.ts) is a display-only precheck; its hints and
// every server reject flow through the ONE salvageReasonMessage mapper. Progression items never
// appear: the server seeds no demand row for them (0174's self-assert) — no client hardcode.

export function SalvageMarketPanel({
  // The ship's server-reported docked location (PortScreen's dock projection) + the commanded ship.
  locationId,
  mainShipId,
  // Re-reads whenever the main-ship dock lifecycle changes (the InvestmentPanel/HaulBoardPanel dep idiom).
  lifecycleKey,
}: {
  locationId: string | null
  mainShipId: string | null
  lifecycleKey: string
}) {
  // null = flag unread (renders null — no pre-read flash); then the strict fold of the config read.
  const [cfg, setCfg] = useState<SalvageConfig | null>(null)
  // null = not loaded · 'error' = buy-list read failed (honest unavailable line) · rows otherwise.
  const [demand, setDemand] = useState<PortItemDemandRow[] | 'error' | null>(null)
  // null = own balances unreadable → stock hidden, the insufficient precheck SKIPPED (server answers).
  const [balances, setBalances] = useState<Record<string, number> | null>(null)
  // getWalletBalance semantics preserved verbatim: number | null (lazy wallet — starting credits)
  // | 'error' (unknown — never a false 0); undefined = not read yet.
  const [wallet, setWallet] = useState<number | null | 'error' | undefined>(undefined)
  // Per-item (id-keyed) qty + pending + note Records — the MarketPanel/HaulBoardPanel per-row idiom.
  const [qty, setQty] = useState<Record<string, number>>({})
  // Transient text drafts for the qty inputs — lets a field be EMPTY while the player types
  // (review nit: the parseInt snap-to-1 fought direct typing); total/submit keep the last valid qty.
  const [qtyDraft, setQtyDraft] = useState<Record<string, string | null>>({})
  const [pending, setPending] = useState<Record<string, boolean>>({})
  const [rowNote, setRowNote] = useState<Record<string, string | null>>({})

  // Mounted + synchronous in-flight guards — the shared home of the idiom (useActivityPanelGuards).
  const guards = useActivityPanelGuards()
  const { activeRef } = guards

  // STICKY-LIT (hostile-review M1): true once THIS MOUNT has seen the flag genuinely enabled. A
  // later failed/dark config re-read (e.g. a post-sale refresh blip: [] → enabled:false) must not
  // unmount the panel — and its freshly-set success note — mid-interaction (salvageStickyLit).
  // First-mount reads stay fail-closed: dark until a POSITIVE strict read, so pre-flip production
  // is byte-unchanged.
  const litRef = useRef(false)

  const refresh = useCallback(async () => {
    // The gate read comes FIRST (the server's own order: flag before any read): while the flag is
    // dark — or the ship isn't docked — this panel performs NO demand/inventory/wallet read.
    const rows = await getSalvageConfigRows()
    const nextCfg = salvageConfigFromRows(rows)
    if (nextCfg.enabled) litRef.current = true
    if (!salvageStickyLit(litRef.current, nextCfg.enabled) || locationId == null) {
      if (!activeRef.current) return
      setCfg(nextCfg)
      setDemand(null)
      setBalances(null)
      setWallet(undefined)
      return
    }
    const [d, b, w] = await Promise.all([
      getPortItemDemand(locationId),
      fetchMyItemBalances(),
      getWalletBalance(),
    ])
    if (!activeRef.current) return
    // On a sticky transient (config unreadable AFTER being lit) keep the PRIOR cfg — the panel
    // stays rendered and the startingCredits seed isn't wiped; a genuine lit re-read updates it.
    setCfg((prev) => (nextCfg.enabled ? nextCfg : (prev ?? nextCfg)))
    setDemand(d ?? 'error')
    setBalances(b)
    setWallet(w)
  }, [activeRef, locationId]) // locationId is a real dep — refetch when the docked port changes

  // lifecycleKey is a deliberate re-fetch trigger (the InvestmentPanel/HaulBoardPanel dep idiom).
  useEffect(() => {
    void refresh()
  }, [refresh, lifecycleKey])

  // One intentional Sell per buy-list row — the shared guarded-submit body over the per-item key;
  // fresh crypto.randomUUID() per submit (the server dedups on (main_ship_id, request_id)).
  // NON-OPTIMISTIC: success refetches inventory + wallet + the buy-list via refresh().
  async function sell(itemId: string, quantity: number) {
    if (!mainShipId) return
    if (!Number.isInteger(quantity) || quantity < 1) {
      // Defensive — the stepper clamps to whole 1.. values; surface the server's own vocab if not.
      setRowNote((n) => ({ ...n, [itemId]: salvageReasonMessage('invalid_quantity') }))
      return
    }
    await runGuardedCommand({
      key: itemId,
      guards,
      setPending: (on) => setPending((p) => ({ ...p, [itemId]: on })),
      setNote: (note) => setRowNote((n) => ({ ...n, [itemId]: note })),
      exec: () => sellItemAtPort(mainShipId, itemId, quantity, crypto.randomUUID()),
      // Success feedback with the credits gained — the SERVER's receipted total, never the client math.
      successNote: (res) => `Sold ×${res.qty} — +${res.total_price.toLocaleString('en-US')} credits.`,
      errorNote: (res) => salvageReasonMessage(res.reason ?? 'unavailable'),
      refresh,
    })
  }

  // FAIL CLOSED: render nothing unless the server's flag read affirmatively lit the market
  // (strict jsonb true). This is the dark path in production today (salvage_market_enabled=false);
  // an unread flag, a FIRST-MOUNT failed config read ([] → dark) and an undocked ship collapse to
  // null the same way. Once lit this mount, a transient config blip keeps the PRIOR lit cfg
  // (sticky-lit, see refresh) so the panel never unmounts mid-interaction. The server would still
  // reject any sell (salvage_market_disabled, gate first).
  if (cfg == null || !cfg.enabled || locationId == null) return null

  const entries = demand !== null && demand !== 'error' ? salvageEntries(demand, balances) : []

  return (
    // UI R2: the Card primitive owns the chrome (warning tone = the trade-family identity).
    <Card tone="warning" data-testid="salvage-panel">
      <CardHeader title="Salvage Buyer" subtitle="Sell combat salvage to this port for credits." />

      {/* Current credits — the getWalletBalance semantics verbatim: 'error'/unread → honest '—',
          no wallet row → the effective starting credits (the CommissionShipPanel honesty posture). */}
      <div className="mt-1 flex items-center justify-between gap-2 text-xs">
        <span className="text-ink-faint">Credits</span>
        <span data-testid="salvage-wallet" className="font-mono tabular-nums text-warning">
          {salvageWalletDisplay(wallet, cfg.startingCredits)}
        </span>
      </div>

      <SectionLabel className="mt-3">This port buys</SectionLabel>
      {demand === null ? (
        // Transient only (refresh sets cfg + demand together) — a quiet skeleton, never a flash.
        <div className="mt-1" aria-busy="true">
          <Skeleton className="h-8 w-full rounded-lg" />
          <span className="sr-only">Loading the buy-list…</span>
        </div>
      ) : demand === 'error' ? (
        <p data-testid="salvage-unavailable" className="mt-1 text-[10px] text-ink-muted">
          Buy-list unavailable right now.
        </p>
      ) : entries.length === 0 ? (
        <p data-testid="salvage-empty" className="mt-1 text-[10px] text-ink-muted">
          This port isn&apos;t buying salvage right now.
        </p>
      ) : (
        <ul data-testid="salvage-list" className="mt-1 space-y-1.5">
          {entries.map((e) => {
            // Balance unknown (own-row read failed) → null: stock hidden, insufficiency precheck
            // skipped (the mirror's null-balance idiom — the server answers insufficient_items).
            const balance = balances !== null ? e.balance : null
            // Whole-1.. floor only at render (no balance clamp): a typed/stale qty past the known
            // balance stays visible and draws the shortfall ADVISORY instead of a silent snap-down
            // (review M2) — the STEPPER buttons are what clamp to the known balance.
            const q = clampSellQty(qty[e.item_id] ?? 1, null)
            const avail = salvageSellAvailability({
              flagOn: true, // by construction: this list renders only under the cfg.enabled gate
              quantity: q,
              shipResolved: mainShipId !== null,
              docked: true, // by construction: locationId !== null in this branch
              demandActive: true, // by construction: the select returns only ACTIVE demand rows
              balance,
            })
            const isPending = pending[e.item_id] ?? false
            const note = rowNote[e.item_id]
            // cap = balance for the stepper buttons (they clamp to the known stock); null for
            // typed input (past-balance typing gets the advisory, the server enforces — M2).
            const commitQty = (raw: number, cap: number | null) => {
              setQtyDraft((d) => ({ ...d, [e.item_id]: null })) // a committed qty ends the draft
              setQty((prev) => ({ ...prev, [e.item_id]: clampSellQty(raw, cap) }))
            }
            return (
              <li
                key={e.item_id}
                data-testid={`salvage-item-${e.item_id}`}
                className="rounded border border-edge/60 bg-surface-2/40 px-2 py-1.5"
              >
                {/* ITEM-VIZ: the buy-list row as an ItemTile — mono ×qty = YOUR sellable stock;
                    hint = the port's unit price (server-seeded, never hardcoded). */}
                <ItemTile
                  id={e.item_id}
                  kind="item"
                  qty={balance ?? undefined}
                  hint={`pays ${e.unit_price.toLocaleString('en-US')} cr each`}
                  className="border-0 bg-transparent px-0 py-0"
                />
                <div className="mt-1 flex items-center justify-between gap-2 text-[10px]">
                  {/* Qty stepper — the BUTTONS clamp to whole 1..balance (clampSellQty; specs in
                      the mold); TYPED input floors to whole 1.. only and may exceed the balance
                      (drawing the shortfall advisory — M2). */}
                  <span className="flex shrink-0 items-center gap-1">
                    <Button
                      variant="secondary"
                      size="sm"
                      data-testid={`salvage-qty-dec-${e.item_id}`}
                      aria-label={`Sell one fewer ${e.item_id}`}
                      disabled={isPending || q <= 1}
                      onClick={() => commitQty(q - 1, null)}
                      className="px-2"
                    >
                      −
                    </Button>
                    <input
                      type="number"
                      min={1}
                      step={1}
                      data-testid={`salvage-qty-${e.item_id}`}
                      // The field may be transiently EMPTY while the player types (review nit —
                      // no snap-to-1 fight); total/submit keep the last valid clamped qty (q).
                      value={qtyDraft[e.item_id] ?? q}
                      onChange={(ev) => {
                        const raw = ev.target.value
                        if (raw === '') {
                          setQtyDraft((d) => ({ ...d, [e.item_id]: '' }))
                          return
                        }
                        commitQty(parseInt(raw, 10), null)
                      }}
                      onBlur={() => setQtyDraft((d) => ({ ...d, [e.item_id]: null }))}
                      className="w-12 rounded border border-edge bg-surface-2 px-1 py-0.5 text-right font-mono tabular-nums text-ink"
                    />
                    <Button
                      variant="secondary"
                      size="sm"
                      data-testid={`salvage-qty-inc-${e.item_id}`}
                      aria-label={`Sell one more ${e.item_id}`}
                      disabled={isPending || (balance !== null && q >= Math.max(1, Math.floor(balance)))}
                      onClick={() => commitQty(q + 1, balance)}
                      className="px-2"
                    >
                      +
                    </Button>
                  </span>
                  <span className="flex min-w-0 items-center gap-1.5">
                    {/* Display price math (qty × unit) — the server computes the receipted total. */}
                    <span
                      data-testid={`salvage-total-${e.item_id}`}
                      className="truncate font-mono tabular-nums text-warning"
                    >
                      = {sellTotal(q, e.unit_price).toLocaleString('en-US')} cr
                    </span>
                    <Button
                      variant="primary"
                      size="sm"
                      data-testid={`salvage-sell-${e.item_id}`}
                      // Hard-disable only on STRUCTURAL blocks (review M2 — salvageSellBlocks):
                      // a known balance may be STALE-LOW (lifecycleKey doesn't tick when loot
                      // settles mid-dock), so a shortfall only ADVISES below and the server's
                      // under-lock inventory_spend stays the enforcement.
                      disabled={salvageSellBlocks(avail.reason)}
                      busy={isPending}
                      busyLabel="Selling…"
                      onClick={() => void sell(e.item_id, q)}
                      className="shrink-0"
                    >
                      Sell
                    </Button>
                  </span>
                </div>
                {/* Surface the display-only precheck through the ONE reason mapper — the same
                    wording the server's reject would produce (the HaulBoardPanel idiom).
                    insufficient_items is ADVISORY (button stays enabled — M2); the others
                    annotate their hard-disabled button. */}
                {(avail.reason === 'insufficient_items' ||
                  avail.reason === 'invalid_quantity' ||
                  avail.reason === 'ship_not_found') && (
                  <p className="mt-0.5 text-[10px] text-ink-muted">{salvageReasonMessage(avail.reason)}</p>
                )}
                {note && (
                  <p data-testid={`salvage-note-${e.item_id}`} className="mt-0.5 text-[10px] text-accent">
                    {note}
                  </p>
                )}
              </li>
            )
          })}
        </ul>
      )}
    </Card>
  )
}
