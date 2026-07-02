import { useEffect, useState } from 'react'
import {
  getMarketOffers,
  getShipCargoLots,
  getWalletBalance,
  type GetMarketOffersResult,
  type ShipCargoLot,
} from './tradeApi'
import type { SelectableShip } from './useMainShipSelection'

// TRADE-UI-1 — READ-ONLY market view for the SELECTED ship. Shows the ship's name, wallet balance, occupied
// cargo volume vs capacity (m³, computed from the ship_cargo_lots lot-sum — the authoritative volume model),
// and the docked station's offers (get_market_offers). NO buy/sell actions yet (next step). DARK: mounted only
// behind TRADE_MARKET_ENABLED (osnReleaseGates.ts) AND the server rejects get_market_offers while
// trade_market_enabled is false — double fail-closed. Server-reject shapes ({ok:false, reason}) collapse to a
// quiet muted note; nothing throws into the render path.

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between gap-3">
      <dt className="text-slate-400">{label}</dt>
      <dd className="text-right text-slate-200">{value}</dd>
    </div>
  )
}

// Map a fail-closed offers result to a quiet player-facing note (never a raw error).
function unavailableNote(offers: GetMarketOffersResult | null): string {
  if (offers && !offers.ok && offers.reason === 'not_docked') return 'Dock at a station to trade.'
  return 'Trading is not available here yet.'
}

export function MarketPanel({ selectedShip }: { selectedShip: SelectableShip | null }) {
  const [wallet, setWallet] = useState<number>(0)
  const [lots, setLots] = useState<ShipCargoLot[]>([])
  const [offers, setOffers] = useState<GetMarketOffersResult | null>(null)
  const [loading, setLoading] = useState(true)

  const shipId = selectedShip?.main_ship_id ?? null

  useEffect(() => {
    if (!shipId) return // no ship → the component returns null anyway; nothing to fetch
    let active = true
    // owner-read wallet + cargo, plus the (server-gated) offers projection — all fail closed. State is set
    // ONLY in this async callback (loading starts true); the mount keys this panel by ship id so a future ship
    // switch remounts with a fresh loading state.
    void Promise.all([getWalletBalance(), getShipCargoLots(shipId), getMarketOffers(shipId)]).then(
      ([w, l, o]) => {
        if (!active) return
        setWallet(w)
        setLots(l)
        setOffers(o)
        setLoading(false)
      },
    )
    return () => {
      active = false
    }
  }, [shipId])

  if (!selectedShip) return null // no ship → render nothing (fail closed)

  const usedM3 = lots.reduce((sum, lot) => sum + lot.qty * lot.unit_volume_m3, 0)
  const capM3 = selectedShip.cargo_capacity_m3

  return (
    <div
      data-testid="market-panel"
      className="mt-3 rounded-xl border border-amber-400/20 bg-amber-500/5 p-4 text-sm text-slate-200"
    >
      <div className="flex items-center justify-between">
        <h3 className="font-medium">🪙 Market — {selectedShip.name}</h3>
        <span className="rounded bg-slate-700/60 px-2 py-0.5 text-[10px] uppercase tracking-wide text-slate-300">
          Read-only
        </span>
      </div>

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
                  </tr>
                </thead>
                <tbody>
                  {offers.offers.map((o) => (
                    <tr key={o.offer_id} className="border-t border-slate-800/60">
                      <td className="py-1 text-slate-200">{o.good_id.replace(/_/g, ' ')}</td>
                      <td className="py-1 text-right text-slate-300">{o.buy_price.toLocaleString()}</td>
                      <td className="py-1 text-right text-slate-300">{o.sell_price.toLocaleString()}</td>
                    </tr>
                  ))}
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
