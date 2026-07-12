import { useCallback, useEffect, useState } from 'react'
import { Button, Card, CardHeader, Notice } from '../../components/ui'
import { commissionAvailability } from '../command/teamRoster'
import { commissionAdditionalMainShip, getCommissionConfigRows, getWalletBalance } from '../map/tradeApi'
import type { SelectableShip } from '../map/useMainShipSelection'
import {
  commissionAffordability,
  commissionContextFromConfig,
  commissionReasonMessage,
  commissionShortfallMessage,
  formatCredits,
  walletBalanceLabel,
  type CommissionContext,
} from './commissionShip'

// TEAM-ACTIVATION PREP — the DARK commission-ship affordance (the in-client path to ship #2+).
//
// Mounted by ShipScreen ONLY behind the compile-time MAINSHIP_ADDITIONAL_ENABLED gate (false — a
// human flips it in the activation follow-up PR), and the server independently rejects
// commission_additional_main_ship while mainship_additional_commission_enabled is false — double
// fail-closed, so production is byte-unchanged today. Lives on the Ship screen's aside rail next
// to the (equally dark) ShipSwitcher: ship ACQUISITION beside ship SELECTION — the fleet grows
// where the fleet is managed, and it works whether or not the teams UI is mounted (independent
// gates; the packet flips both in one window, but neither surface depends on the other).
//
// Availability is the EXISTING pure mirror commissionAvailability (teamRoster.ts — dark gate
// BEFORE cap BEFORE credits, the exact server order), fed from SERVER data only: ship count from
// the shell selection's owner-read list, cap + server flag + price + starting credits from
// public-read game_config (never hardcoded — commissionContextFromConfig falls back to the
// server's own fallbacks, fail closed).
//
// WALLET HONESTY (owner defect): the wallet row is LAZY (0093 — seeded with starting_credits at
// first debit), so getWalletBalance returns null for a no-row player and this panel shows the
// EFFECTIVE starting balance with an explicit "(starting credits)" hint instead of a false 0.
// The buy button disables when the effective balance can't cover the price, with the shortfall
// shown (commissionShortfallMessage) — DISPLAY-ONLY: the SERVER still owns the credit check
// (wallet_debit under the commission advisory lock, 0091), and a server reject still surfaces
// through commissionReasonMessage (insufficient_credits → "Not enough credits.").
//
// NON-OPTIMISTIC: submit awaits the RPC, then refetches the ship list/game state (onCommissioned)
// AND its own context (balance moved, cap state may have) — the view never diverges from server
// truth. Busy-guarded (no double-submit; the server's advisory lock is the real serializer).
// commission_additional_main_ship takes NO request_id (idempotence = the cap re-check under the
// lock), so none is invented here.

export function CommissionShipPanel({
  ships,
  onCommissioned,
}: {
  ships: SelectableShip[]
  onCommissioned: () => Promise<void>
}) {
  const [ctx, setCtx] = useState<CommissionContext | null>(null)
  // undefined = not fetched yet; null = fetched, NO wallet row (lazy 0093 — effectively on
  // starting credits); number = the seeded wallet's actual balance.
  const [balance, setBalance] = useState<number | null | undefined>(undefined)
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState<{ tone: 'success' | 'warning'; text: string } | null>(null)

  const loadContext = useCallback(async () => {
    const [rows, balRaw] = await Promise.all([getCommissionConfigRows(), getWalletBalance()])
    // 'error' = transient read failure — treat as UNKNOWN (no starting-credits claim, no shortfall
    // block; the server stays the authority on an actual buy attempt).
    const bal = balRaw === 'error' ? undefined : balRaw
    setCtx(commissionContextFromConfig(rows))
    setBalance(bal)
  }, [])
  // Initial load: inline .then so setState lands in an async callback, not synchronously in the
  // effect body (react-hooks/set-state-in-effect — the TeamRosterPanel idiom). loadContext()
  // reuses the same fetch pair after a commission.
  useEffect(() => {
    let active = true
    void Promise.all([getCommissionConfigRows(), getWalletBalance()]).then(([rows, balRaw]) => {
      if (!active) return
      setCtx(commissionContextFromConfig(rows))
      setBalance(balRaw === 'error' ? undefined : balRaw) // 'error' = unknown, never a claim
    })
    return () => {
      active = false
    }
  }, [])

  // Effective balance + shortfall (pure, display-only) — only once BOTH fetches landed; until
  // then the mirror gets no credit inputs (unknown must never block) and the gate fails closed.
  const aff = ctx && balance !== undefined ? commissionAffordability(balance, ctx) : null

  // Fail closed while the context loads: cap 0 + gate false → gate_dark, the server's own order
  // (gate → cap → credits). The credit inputs mirror 0091's debit-after-cap, display-only.
  const avail = commissionAvailability({
    shipCount: ships.length,
    cap: ctx?.cap ?? 0,
    gateEnabled: ctx?.serverEnabled === true,
    ...(aff && ctx ? { effectiveBalance: aff.effectiveBalance, price: ctx.price } : {}),
  })

  const submit = async () => {
    if (busy || !avail.canCommission) return
    setBusy(true)
    setNotice(null)
    try {
      const res = await commissionAdditionalMainShip()
      if (res.ok) {
        setNotice({
          tone: 'success',
          text: `Ship commissioned — ${res.price} cr debited. It is docked at the port.`,
        })
        await onCommissioned() // refetch ship list + game state (never optimistic)
        await loadContext() // balance + cap headroom moved
      } else {
        setNotice({ tone: 'warning', text: commissionReasonMessage(res.reason) })
      }
    } finally {
      setBusy(false)
    }
  }

  return (
    <Card tone="warning" data-testid="commission-ship-panel">
      <CardHeader title="Commission ship" subtitle="Grow your fleet — teams need ships" />
      <div className="flex items-center justify-between gap-3 text-xs text-ink-muted">
        {/* Price + balance are SERVER data (public-read game_config / owner-read wallet).
            No wallet row ≠ broke: the lazy wallet (0093) means the effective balance is the
            starting_credits seed — shown honestly as e.g. "1,000 cr (starting credits)". */}
        <span data-testid="commission-price">
          {ctx ? `Price ${formatCredits(ctx.price)} cr` : 'Price —'}
          {aff ? ` · Balance ${walletBalanceLabel(aff)}` : ''}
        </span>
        <Button
          size="sm"
          variant="warning"
          disabled={!avail.canCommission}
          busy={busy}
          busyLabel="Commissioning…"
          onClick={() => void submit()}
          data-testid="commission-ship-button"
        >
          Commission
        </Button>
      </div>
      {!avail.canCommission && (
        <Notice tone="neutral" className="mt-2" data-testid="commission-availability-note">
          {avail.reason === 'insufficient_credits' && aff
            ? commissionShortfallMessage(aff.shortfall) // the shortfall, not just "not enough"
            : commissionReasonMessage(avail.reason)}
        </Notice>
      )}
      {notice && (
        <Notice tone={notice.tone} className="mt-2" data-testid="commission-notice">
          {notice.text}
        </Notice>
      )}
    </Card>
  )
}
