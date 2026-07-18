import { useCallback, useEffect, useRef, useState } from 'react'
import { runGuardedCommand, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { getWalletBalance } from '../map/tradeApi'
import { buyShopOfferAtPort, getPortShop } from './shopApi'
import {
  buyAvailability,
  buyBlocks,
  buyTotal,
  clampBuyQty,
  offerStatChips,
  portShopReasonMessage,
  shopWalletDisplay,
  type ShopOffer,
} from './portShop'
import { salvageStickyLit } from './salvageMarket'
import { Button, Card, CardHeader } from '../../components/ui'

// PORT-SHOP — the dark port outfitter: the docked port's beginner buy-list (get_port_shop, 0235) as
// rows — each offer's name, archetype badge, stat/attribute chips, one-line description, and price —
// with a whole-quantity stepper for ammo (modules are one instance per buy) and ONE Buy per row
// (buy_shop_offer_at_port). GATED on the server's OWN flag: get_port_shop rejects port_shop_disabled
// (gate FIRST, before any read) while dark, so the panel reads its lit/dark signal straight from the
// RPC and renders NOTHING while dark (double fail-closed — the buy RPC also rejects). NO optimistic
// UI: every buy awaits the server then refetches the shop + wallet. Bought MODULES land in the
// player's fittable module pool (module_instances → the existing fitting flow); bought AMMO lands in
// inventory. The availability mirror (portShop.ts) is a display-only precheck; every reject flows
// through the ONE portShopReasonMessage mapper.

export function ShopPanel({
  locationId,
  mainShipId,
  lifecycleKey,
}: {
  locationId: string | null
  mainShipId: string | null
  lifecycleKey: string
}) {
  // null = unread (renders null — no pre-read flash); then the RPC's lit/dark result.
  const [offers, setOffers] = useState<ShopOffer[] | null>(null)
  const [enabled, setEnabled] = useState(false)
  const [loadError, setLoadError] = useState(false)
  // getWalletBalance semantics verbatim: number | null (lazy wallet) | 'error' | undefined = unread.
  const [wallet, setWallet] = useState<number | null | 'error' | undefined>(undefined)
  // per-item (ammo) quantity draft; modules ignore it (always 1).
  const [qty, setQty] = useState<Record<string, number>>({})
  const [pending, setPending] = useState<string | null>(null) // ref_id being bought
  const [note, setNote] = useState<Record<string, string>>({})

  const guards = useActivityPanelGuards()
  const { activeRef } = guards

  // STICKY-LIT (the salvage/repair posture): true once THIS MOUNT saw the shop genuinely open, so a
  // later dark/failed re-read (e.g. a post-buy refresh blip) never unmounts the panel mid-interaction.
  const litRef = useRef(false)

  const refresh = useCallback(async () => {
    if (locationId == null || mainShipId == null) {
      if (!activeRef.current) return
      setOffers(null)
      setEnabled(false)
      setWallet(undefined)
      return
    }
    const [res, w] = await Promise.all([getPortShop(locationId), getWalletBalance()])
    if (!activeRef.current) return
    if (res.ok) {
      litRef.current = true
      setEnabled(true)
      setOffers(res.offers)
      setLoadError(false)
    } else if (res.reason === 'port_shop_disabled') {
      // genuinely dark — fail closed (sticky-lit keeps a prior-lit mount rendered; the server still enforces).
      setEnabled(salvageStickyLit(litRef.current, false))
      if (!litRef.current) setOffers(null)
      setLoadError(false)
    } else {
      // transport/unknown — keep prior offers if lit, flag the honest unavailable line.
      setEnabled(salvageStickyLit(litRef.current, false))
      setLoadError(true)
    }
    setWallet(w)
  }, [activeRef, locationId, mainShipId])

  useEffect(() => {
    void refresh()
  }, [refresh, lifecycleKey])

  async function buy(offer: ShopOffer, quantity: number) {
    if (!mainShipId) return
    await runGuardedCommand({
      key: `buy:${offer.ref_id}`,
      guards,
      setPending: (on) => setPending(on ? offer.ref_id : null),
      setNote: (n) => setNote((prev) => ({ ...prev, [offer.ref_id]: n ?? '' })),
      exec: () => buyShopOfferAtPort(mainShipId, offer.ref_id, quantity, crypto.randomUUID()),
      successNote: (res) =>
        res.kind === 'module'
          ? `Bought ${offer.name ?? offer.ref_id} — −${res.total_price.toLocaleString('en-US')} credits. Fit it from the Fitting tab.`
          : `Bought ${res.quantity}× ${offer.name ?? offer.ref_id} — −${res.total_price.toLocaleString('en-US')} credits.`,
      errorNote: (res) => portShopReasonMessage(res.reason ?? 'unavailable'),
      refresh,
    })
  }

  // FAIL CLOSED: render nothing unless the server's gated read affirmatively opened the shop AND we
  // have a docked, resolved ship. This is the dark path in production today (port_shop_enabled=false).
  if (!enabled || offers == null || locationId == null || mainShipId == null) return null

  const knownCredits = typeof wallet === 'number' ? wallet : null

  return (
    <Card tone="accent" data-testid="shop-panel">
      <CardHeader title="Outfitter" subtitle="Buy entry-level fitting modules and ammo for your ship." />

      <div className="mt-1 flex items-center justify-between gap-2 text-xs">
        <span className="text-ink-faint">Credits</span>
        <span data-testid="shop-wallet" className="font-mono tabular-nums text-accent">
          {shopWalletDisplay(wallet, null)}
        </span>
      </div>

      {loadError && (
        <p data-testid="shop-unavailable" className="mt-1 text-[10px] text-ink-muted">
          Some prices may be out of date — the outfitter is briefly unavailable.
        </p>
      )}

      {offers.length === 0 ? (
        <p className="mt-2 text-[10px] text-ink-muted">This port has nothing in stock right now.</p>
      ) : (
        <ul className="mt-2 space-y-2" data-testid="shop-offers">
          {offers.map((offer) => (
            <ShopRow
              key={offer.ref_id}
              offer={offer}
              qty={offer.kind === 'item' ? (qty[offer.ref_id] ?? 1) : 1}
              setQty={(n) => setQty((prev) => ({ ...prev, [offer.ref_id]: clampBuyQty(n, null) }))}
              pending={pending === offer.ref_id}
              anyPending={pending !== null}
              note={note[offer.ref_id] ?? null}
              knownCredits={knownCredits}
              onBuy={(n) => buy(offer, n)}
            />
          ))}
        </ul>
      )}
    </Card>
  )
}

// One offer row: identity + attribute chips + description + price + (ammo) qty stepper + Buy.
function ShopRow({
  offer,
  qty,
  setQty,
  pending,
  anyPending,
  note,
  knownCredits,
  onBuy,
}: {
  offer: ShopOffer
  qty: number
  setQty: (n: number) => void
  pending: boolean
  anyPending: boolean
  note: string | null
  knownCredits: number | null
  onBuy: (qty: number) => void
}) {
  const isModule = offer.kind === 'module'
  const effectiveQty = isModule ? 1 : Math.max(1, Math.floor(qty))
  const total = buyTotal(effectiveQty, offer.price)
  const affordable = knownCredits === null ? null : knownCredits >= total
  const chips = offerStatChips(offer)
  const badge = isModule ? (offer.slot_type ?? 'module') : (offer.category ?? 'item')

  const avail = buyAvailability({
    flagOn: true, // by construction: rendered only under the lit gate
    quantity: effectiveQty,
    isModule,
    shipResolved: true,
    docked: true,
    offerExists: true,
    affordable,
  })

  return (
    <li className="rounded-lg border border-edge bg-surface-2 px-2 py-1.5" data-testid={`shop-offer-${offer.ref_id}`}>
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <div className="flex items-center gap-1.5">
            <span className="truncate text-xs font-medium text-ink">{offer.name ?? offer.ref_id}</span>
            <span className="shrink-0 rounded bg-surface px-1 text-[9px] uppercase tracking-wide text-ink-faint">
              {badge}
              {isModule && offer.slot_cost ? ` · ${offer.slot_cost} slot${offer.slot_cost > 1 ? 's' : ''}` : ''}
            </span>
          </div>
          {chips.length > 0 && (
            <div className="mt-0.5 flex flex-wrap gap-1">
              {chips.map((c) => (
                <span key={c} className="rounded bg-surface px-1 text-[9px] font-mono tabular-nums text-ink-muted">
                  {c}
                </span>
              ))}
            </div>
          )}
          {offer.description && <p className="mt-0.5 text-[10px] leading-tight text-ink-faint">{offer.description}</p>}
        </div>
        <span data-testid={`shop-price-${offer.ref_id}`} className="shrink-0 font-mono tabular-nums text-[11px] text-accent">
          {offer.price.toLocaleString('en-US')} cr{!isModule ? ' ea' : ''}
        </span>
      </div>

      <div className="mt-1 flex items-center justify-between gap-2">
        {!isModule ? (
          <span className="flex items-center gap-1">
            <Button
              variant="secondary"
              size="sm"
              aria-label="Buy fewer"
              disabled={anyPending || effectiveQty <= 1}
              onClick={() => setQty(effectiveQty - 1)}
              className="px-2"
            >
              −
            </Button>
            <input
              type="number"
              min={1}
              step={1}
              data-testid={`shop-qty-${offer.ref_id}`}
              value={effectiveQty}
              onChange={(ev) => setQty(ev.target.value === '' ? 1 : parseInt(ev.target.value, 10))}
              className="w-14 rounded border border-edge bg-surface-2 px-1 py-0.5 text-right font-mono tabular-nums text-ink"
            />
            <Button
              variant="secondary"
              size="sm"
              aria-label="Buy more"
              disabled={anyPending}
              onClick={() => setQty(effectiveQty + 1)}
              className="px-2"
            >
              +
            </Button>
          </span>
        ) : (
          <span className="text-[10px] text-ink-faint">One per purchase</span>
        )}

        <span className="flex min-w-0 items-center gap-1.5">
          <span data-testid={`shop-total-${offer.ref_id}`} className="truncate font-mono tabular-nums text-[11px] text-accent">
            {total.toLocaleString('en-US')} cr
          </span>
          <Button
            variant="primary"
            size="sm"
            data-testid={`shop-buy-${offer.ref_id}`}
            disabled={buyBlocks(avail.reason)}
            busy={pending}
            busyLabel="Buying…"
            onClick={() => onBuy(effectiveQty)}
            className="shrink-0"
          >
            Buy
          </Button>
        </span>
      </div>

      {avail.reason === 'insufficient_credits' && (
        <p className="mt-0.5 text-[10px] text-ink-muted">{portShopReasonMessage('insufficient_credits')}</p>
      )}
      {note && (
        <p data-testid={`shop-note-${offer.ref_id}`} className="mt-0.5 text-[10px] text-accent">
          {note}
        </p>
      )}
    </li>
  )
}
