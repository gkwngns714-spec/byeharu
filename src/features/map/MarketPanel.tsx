import { Fragment, useCallback, useEffect, useState } from 'react'
import { useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import {
  getMarketOffers,
  getShipCargoLots,
  getWalletBalance,
  marketBuy,
  marketSell,
  type GetMarketOffersResult,
  type ShipCargoLot,
} from './tradeApi'
import { tradeReasonMessage } from './tradeReasonMessage'
import type { SelectableShip } from './useMainShipSelection'

// TRADE-UI-1 — trade surface for the SELECTED ship. Shows the ship's name, wallet balance, occupied cargo
// volume vs capacity (m³, from the ship_cargo_lots lot-sum — the authoritative volume model), and the docked
// station's offers, with per-offer Buy/Sell actions (market_buy / market_sell). Each intentional click is one
// idempotent command keyed by a fresh crypto.randomUUID() request id; the row's buttons disable while its
// request is in flight so a double-click can't double-submit, and a success re-reads wallet/cargo/offers via
// refresh(). DARK: mounted only behind TRADE_MARKET_ENABLED (osnReleaseGates.ts) AND the server rejects every
// trade RPC while trade_market_enabled is false — double fail-closed. All {ok:false, reason} shapes collapse to
// a quiet note via tradeReasonMessage; nothing throws into the render path.

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between gap-3">
      <dt className="text-slate-400">{label}</dt>
      <dd className="text-right text-slate-200">{value}</dd>
    </div>
  )
}

// Whole-panel fail-closed note (offers not readable): reuse the shared reason map; null/initial → generic.
function unavailableNote(offers: GetMarketOffersResult | null): string {
  if (offers && !offers.ok) return tradeReasonMessage(offers.reason)
  return 'Trading is not available here yet.'
}

export function MarketPanel({ selectedShip }: { selectedShip: SelectableShip | null }) {
  const [wallet, setWallet] = useState<number>(0)
  const [lots, setLots] = useState<ShipCargoLot[]>([])
  const [offers, setOffers] = useState<GetMarketOffersResult | null>(null)
  const [loading, setLoading] = useState(true)
  // Per-offer (keyed by good_id) trade state: chosen qty (default 1), in-flight guard, and a quiet row note.
  const [qty, setQty] = useState<Record<string, number>>({})
  const [pending, setPending] = useState<Record<string, boolean>>({})
  const [rowError, setRowError] = useState<Record<string, string | null>>({})

  const shipId = selectedShip?.main_ship_id ?? null

  // Mounted + synchronous per-row in-flight guards — the idiom now lives in src/lib/useActivityPanelGuards.ts;
  // future activity panels use the hook (never a re-copy). MarketPanel is a consumer like the others.
  const { activeRef, tryClaim, release } = useActivityPanelGuards()

  // The single owner-read fetch: wallet + cargo + (server-gated) offers, all fail closed. Does NOT set loading
  // true, so a post-trade refresh updates in place without a flicker; the mount path starts with loading=true.
  const refresh = useCallback(async () => {
    if (!shipId) return
    const [w, l, o] = await Promise.all([getWalletBalance(), getShipCargoLots(shipId), getMarketOffers(shipId)])
    if (!activeRef.current) return
    setWallet(w)
    setLots(l)
    setOffers(o)
    setLoading(false)
  }, [shipId, activeRef]) // ref identity is stable — dep satisfies the lint rule without changing refresh's identity

  useEffect(() => {
    void refresh()
  }, [refresh])

  // One intentional Buy/Sell for a row. Fresh request id per submit (server dedups on (main_ship_id, request_id));
  // the per-row tryClaim (useActivityPanelGuards) + disabled buttons stop double-submits. Success → clear note +
  // refresh; failure → quiet note. try/finally always releases the claim (wrappers never throw, but defensive).
  async function submit(side: 'buy' | 'sell', goodId: string) {
    if (!shipId) return
    if (!tryClaim(goodId)) return // synchronous per-row claim, before any await: bail before minting a 2nd request
    const n = qty[goodId] ?? 1
    if (!Number.isInteger(n) || n < 1) {
      setRowError((e) => ({ ...e, [goodId]: tradeReasonMessage('invalid_qty') }))
      release(goodId) // claim→validate→release, all synchronous (no await yet) — an invalid qty leaves no claim
      return
    }
    setPending((p) => ({ ...p, [goodId]: true }))
    setRowError((e) => ({ ...e, [goodId]: null }))
    const requestId = crypto.randomUUID()
    try {
      const res =
        side === 'buy'
          ? await marketBuy(shipId, goodId, n, requestId)
          : await marketSell(shipId, goodId, n, requestId)
      if (!activeRef.current) return
      if (res.ok) {
        await refresh()
      } else {
        setRowError((e) => ({ ...e, [goodId]: tradeReasonMessage(res.reason) }))
      }
    } finally {
      release(goodId)
      if (activeRef.current) setPending((p) => ({ ...p, [goodId]: false }))
    }
  }

  if (!selectedShip) return null // no ship → render nothing (fail closed)

  const usedM3 = lots.reduce((sum, lot) => sum + lot.qty * lot.unit_volume_m3, 0)
  const capM3 = selectedShip.cargo_capacity_m3

  return (
    <div
      data-testid="market-panel"
      className="mt-3 rounded-xl border border-amber-400/20 bg-amber-500/5 p-4 text-sm text-slate-200"
    >
      <h3 className="font-medium">🪙 Market — {selectedShip.name}</h3>

      {loading && <p className="mt-2 text-xs text-slate-500">Loading…</p>}

      {!loading && (
        <>
          <dl className="mt-3 space-y-1.5">
            <Row label="Credits" value={wallet.toLocaleString()} />
            <Row label="Cargo (m³)" value={`${usedM3.toFixed(2)} / ${capM3.toFixed(2)}`} />
          </dl>

          {offers && offers.ok ? (
            <div className="mt-3 border-t border-slate-700/60 pt-3">
              <table data-testid="market-offers" className="w-full text-left text-xs">
                <thead className="text-slate-400">
                  <tr>
                    <th className="pb-1 font-medium">Good</th>
                    <th className="pb-1 text-right font-medium">Buy</th>
                    <th className="pb-1 text-right font-medium">Sell</th>
                    <th className="pb-1 text-right font-medium">Trade</th>
                  </tr>
                </thead>
                <tbody>
                  {offers.offers.map((o) => {
                    const isPending = !!pending[o.good_id]
                    const err = rowError[o.good_id]
                    return (
                      <Fragment key={o.offer_id}>
                        <tr className="border-t border-slate-800/60">
                          <td className="py-1 text-slate-200">{o.good_id.replace(/_/g, ' ')}</td>
                          {/* Column name != field name: the "Buy" column shows the offer's sell_price (what the
                              buyer PAYS — what market_buy charges), and "Sell" shows buy_price (what the seller
                              RECEIVES — what market_sell pays). Do NOT "correct" these back to matching names. */}
                          <td className="py-1 text-right text-slate-300">{o.sell_price.toLocaleString()}</td>
                          <td className="py-1 text-right text-slate-300">{o.buy_price.toLocaleString()}</td>
                          <td className="py-1 text-right">
                            <div className="flex items-center justify-end gap-1">
                              <input
                                type="number"
                                min={1}
                                step={1}
                                data-testid={`trade-qty-${o.good_id}`}
                                value={qty[o.good_id] ?? 1}
                                onChange={(ev) => {
                                  const parsed = parseInt(ev.target.value, 10)
                                  setQty((q) => ({
                                    ...q,
                                    [o.good_id]: Number.isNaN(parsed) || parsed < 1 ? 1 : parsed,
                                  }))
                                }}
                                className="w-14 rounded bg-slate-800/80 px-1 py-0.5 text-right text-slate-200"
                              />
                              <button
                                type="button"
                                data-testid={`trade-buy-${o.good_id}`}
                                disabled={isPending}
                                onClick={() => void submit('buy', o.good_id)}
                                className="rounded bg-emerald-600/80 px-2 py-0.5 text-[11px] font-medium text-white hover:bg-emerald-500 disabled:opacity-50"
                              >
                                Buy
                              </button>
                              <button
                                type="button"
                                data-testid={`trade-sell-${o.good_id}`}
                                disabled={isPending}
                                onClick={() => void submit('sell', o.good_id)}
                                className="rounded bg-sky-600/80 px-2 py-0.5 text-[11px] font-medium text-white hover:bg-sky-500 disabled:opacity-50"
                              >
                                Sell
                              </button>
                            </div>
                          </td>
                        </tr>
                        {err && (
                          <tr>
                            <td
                              colSpan={4}
                              data-testid={`trade-error-${o.good_id}`}
                              className="pb-1 text-right text-[10px] text-rose-300"
                            >
                              {err}
                            </td>
                          </tr>
                        )}
                      </Fragment>
                    )
                  })}
                </tbody>
              </table>
            </div>
          ) : (
            <p className="mt-3 border-t border-slate-700/60 pt-3 text-center text-xs text-slate-500">
              {unavailableNote(offers)}
            </p>
          )}
        </>
      )}
    </div>
  )
}
