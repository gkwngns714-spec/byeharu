import { useCallback, useEffect, useState } from 'react'
import { Button, Card, CardHeader, Notice } from '../../components/ui'
import { commissionAvailability } from '../command/teamRoster'
import { commissionAdditionalMainShip, getCommissionConfigRows, getWalletBalance } from '../map/tradeApi'
import type { SelectableShip } from '../map/useMainShipSelection'
import { commissionContextFromConfig, commissionReasonMessage, type CommissionContext } from './commissionShip'

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
// BEFORE cap, the exact server order), fed from SERVER data only: ship count from the shell
// selection's owner-read list, cap + server flag + price from public-read game_config (never
// hardcoded — commissionContextFromConfig falls back to the server's own fallbacks, fail closed).
// The button stays enabled on `ok` even when the balance looks short — the SERVER owns the credit
// check (wallet_debit under the commission advisory lock, 0091); a reject surfaces through
// commissionReasonMessage (insufficient_credits → "Not enough credits.").
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
  const [balance, setBalance] = useState<number | null>(null)
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState<{ tone: 'success' | 'warning'; text: string } | null>(null)

  const loadContext = useCallback(async () => {
    const [rows, bal] = await Promise.all([getCommissionConfigRows(), getWalletBalance()])
    setCtx(commissionContextFromConfig(rows))
    setBalance(bal)
  }, [])
  // Initial load: inline .then so setState lands in an async callback, not synchronously in the
  // effect body (react-hooks/set-state-in-effect — the TeamRosterPanel idiom). loadContext()
  // reuses the same fetch pair after a commission.
  useEffect(() => {
    let active = true
    void Promise.all([getCommissionConfigRows(), getWalletBalance()]).then(([rows, bal]) => {
      if (!active) return
      setCtx(commissionContextFromConfig(rows))
      setBalance(bal)
    })
    return () => {
      active = false
    }
  }, [])

  // Fail closed while the context loads: cap 0 + gate false → gate_dark, the server's own order.
  const avail = commissionAvailability({
    shipCount: ships.length,
    cap: ctx?.cap ?? 0,
    gateEnabled: ctx?.serverEnabled === true,
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
        {/* Price + balance are SERVER data (public-read game_config / owner-read wallet). */}
        <span data-testid="commission-price">
          {ctx ? `Price ${ctx.price} cr` : 'Price —'}
          {balance != null ? ` · Balance ${balance} cr` : ''}
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
          {commissionReasonMessage(avail.reason)}
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
