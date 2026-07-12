import { useCallback, useEffect, useState } from 'react'
import { isServerLit, runGuardedCommand, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { getShipCargoLots, type ShipCargoLot } from '../map/tradeApi'
import { getPortContracts, haulAcceptContract, haulDeliverContract } from './haulApi'
import {
  haulAcceptAvailability,
  haulDeadlineLabel,
  haulDeliverAvailability,
  type GetPortContractsResult,
} from './haulBoard'
import { haulReasonMessage } from './haulReasonMessage'
import { Button, Card, CardHeader, SectionLabel } from '../../components/ui'

// HAUL-3 — the dark port bulletin board: the docked port's fresh contract offers (good, qty,
// reward, pickup deadline; one intentional Accept per row) and the caller's accepted contracts
// (destination, delivery countdown, Deliver at the destination). SERVER-DRIVEN visibility (no
// client flag constant): on mount / lifecycle change it reads get_port_contracts (0181) and
// renders NOTHING unless the server affirmatively lit the feature ({ok:true}); while
// haul_contracts_enabled is false the server returns haul_contracts_disabled → not server-lit →
// null, so today's production experience is byte-unchanged. Submits ONLY the existing HAUL-2
// commands (0179) — NO new server authority: the server owns docking, contract state, the active
// cap, the deadline, and the cargo debit (via Trade-Cargo) + credit (via Wallet). NO optimistic
// UI: every command awaits the server then refetches the board (+ cargo). The availability
// mirrors (haulBoard.ts) are display-only prechecks; their hints and every server reject flow
// through the ONE haulReasonMessage mapper. Cargo shown against a contract is a display-only
// lot-sum over the owner-read ship_cargo_lots — the server's under-lock sum is the truth.

const titleGood = (goodId: string): string =>
  goodId.charAt(0).toUpperCase() + goodId.slice(1).replace(/_/g, ' ')

export function HaulBoardPanel({
  // The ship's server-reported docked location (PortScreen's dock projection) + the commanded ship.
  locationId,
  mainShipId,
  // Re-reads whenever the main-ship dock lifecycle changes (the InvestmentPanel dep idiom).
  lifecycleKey,
}: {
  locationId: string | null
  mainShipId: string | null
  lifecycleKey: string
}) {
  const [board, setBoard] = useState<GetPortContractsResult | null>(null)
  const [lots, setLots] = useState<ShipCargoLot[]>([])
  // Per-contract (id-keyed) pending + note Records — the MarketPanel/ModulesPanel per-row idiom.
  const [pending, setPending] = useState<Record<string, boolean>>({})
  const [rowNote, setRowNote] = useState<Record<string, string | null>>({})
  // Countdown clock — ticks only while the panel is lit (30s granularity; deadlines are hours-scale).
  const [nowMs, setNowMs] = useState(() => Date.now())

  // Mounted + synchronous in-flight guards — the shared home of the idiom (useActivityPanelGuards).
  const guards = useActivityPanelGuards()
  const { activeRef } = guards

  const refresh = useCallback(async () => {
    // Not docked → no port to scope the bulletin; fail closed to null (the render guard below).
    if (locationId == null) {
      if (!activeRef.current) return
      setBoard(null)
      setLots([])
      return
    }
    const [b, l] = await Promise.all([
      getPortContracts(locationId),
      mainShipId ? getShipCargoLots(mainShipId) : Promise.resolve([] as ShipCargoLot[]),
    ])
    if (!activeRef.current) return
    setBoard(b)
    setLots(l)
    setNowMs(Date.now())
  }, [activeRef, locationId, mainShipId]) // real deps — refetch when the docked port / ship changes

  // lifecycleKey is a deliberate re-fetch trigger (the InvestmentPanel/DockServicesPanel dep idiom).
  useEffect(() => {
    void refresh()
  }, [refresh, lifecycleKey])

  // Tick the countdown clock only while the server lit the board (a dark panel renders null and
  // needs no clock).
  useEffect(() => {
    if (!isServerLit(board)) return
    const t = setInterval(() => setNowMs(Date.now()), 30_000)
    return () => clearInterval(t)
  }, [board])

  // One intentional Accept per offered row — the shared guarded-submit body over the per-contract
  // key; fresh crypto.randomUUID() per submit (the server dedups on (main_ship_id, request_id)).
  async function accept(contractId: string, destName: string | null) {
    if (!mainShipId) return
    await runGuardedCommand({
      key: contractId,
      guards,
      setPending: (on) => setPending((p) => ({ ...p, [contractId]: on })),
      setNote: (note) => setRowNote((n) => ({ ...n, [contractId]: note })),
      exec: () => haulAcceptContract(mainShipId, contractId, crypto.randomUUID()),
      successNote: () => `Contract accepted — deliver to ${destName ?? 'the destination port'}.`,
      errorNote: (res) => haulReasonMessage(res.reason ?? 'unavailable'),
      refresh,
    })
  }

  // One intentional Deliver per accepted row — same guarded body; the server verifies the docked
  // destination, the deadline, and the cargo under its own lock (consume + credit + receipt atomic).
  async function deliver(contractId: string, reward: number) {
    if (!mainShipId) return
    await runGuardedCommand({
      key: contractId,
      guards,
      setPending: (on) => setPending((p) => ({ ...p, [contractId]: on })),
      setNote: (note) => setRowNote((n) => ({ ...n, [contractId]: note })),
      exec: () => haulDeliverContract(mainShipId, contractId, crypto.randomUUID()),
      successNote: () => `Delivered — ${reward.toLocaleString()} credits paid.`,
      errorNote: (res) => haulReasonMessage(res.reason ?? 'unavailable'),
      refresh,
    })
  }

  // FAIL CLOSED: render nothing unless the server affirmatively lit the board read. This is the
  // dark path in production today (haul_contracts_disabled → not server-lit); transport errors
  // collapse to null the same way. The client is never the control.
  if (!isServerLit(board)) return null

  const offered = board.offered ?? []
  const mine = board.mine ?? []
  const maxActive = typeof board.max_active === 'number' ? board.max_active : null
  // Display-only lot-sum of the commanded ship's cargo for a good (the server owns the real check).
  const cargoFor = (goodId: string): number =>
    lots.filter((l) => l.good_id === goodId).reduce((sum, l) => sum + l.qty, 0)

  return (
    // UI R2: the Card primitive owns the chrome (warning tone = the trade-family identity).
    <Card tone="warning" data-testid="haul-board">
      <CardHeader title="Contract Board" subtitle="Haul goods between ports for posted rewards." />

      {/* Tab 1 — this port's fresh offers (the 0181 read already excludes stale rows). */}
      <SectionLabel className="mt-2">On the board</SectionLabel>
      {offered.length === 0 ? (
        <p data-testid="haul-board-empty" className="mt-1 text-[10px] text-ink-muted">
          No contracts on offer at this port right now.
        </p>
      ) : (
        <ul data-testid="haul-offers" className="mt-1 space-y-1.5">
          {offered.map((o) => {
            const avail = haulAcceptAvailability({
              serverLit: true, // by construction: this list renders only under isServerLit
              shipResolved: mainShipId !== null,
              dockedAtOrigin: locationId !== null, // the bulletin is port-scoped — this port IS the origin
              offerFresh: new Date(o.expires_at).getTime() > nowMs,
              activeCount: mine.length,
              maxActive,
            })
            const isPending = pending[o.contract_id] ?? false
            const note = rowNote[o.contract_id]
            return (
              <li
                key={o.contract_id}
                data-testid={`haul-offer-${o.contract_id}`}
                className="rounded border border-edge/60 bg-surface-2/40 px-2 py-1.5 text-[10px]"
              >
                <div className="flex items-center justify-between gap-2">
                  <span className="min-w-0 truncate text-ink">
                    {titleGood(o.good_id)}{' '}
                    <span className="font-mono tabular-nums text-ink-muted">×{o.quantity}</span>
                  </span>
                  <span className="shrink-0 font-mono tabular-nums text-warning">
                    {o.reward_credits.toLocaleString()} cr
                  </span>
                </div>
                <div className="mt-1 flex items-center justify-between gap-2">
                  <span className="min-w-0 truncate text-ink-faint">
                    → {o.dest_name ?? 'Unknown port'} ·{' '}
                    <span className="font-mono tabular-nums">{haulDeadlineLabel(o.expires_at, nowMs)}</span>
                  </span>
                  <Button
                    variant="secondary"
                    size="sm"
                    data-testid={`haul-accept-${o.contract_id}`}
                    disabled={!avail.canAccept}
                    busy={isPending}
                    busyLabel="Accepting…"
                    onClick={() => void accept(o.contract_id, o.dest_name)}
                    className="shrink-0"
                  >
                    Accept
                  </Button>
                </div>
                {/* Surface the display-only precheck through the ONE reason mapper — the same
                    wording the server's reject would produce (the TeamMemberCaptains idiom). */}
                {(avail.reason === 'too_many_active' || avail.reason === 'contract_not_found') && (
                  <p className="mt-0.5 text-[10px] text-ink-muted">{haulReasonMessage(avail.reason)}</p>
                )}
                {note && (
                  <p data-testid={`haul-offer-note-${o.contract_id}`} className="mt-0.5 text-[10px] text-accent">
                    {note}
                  </p>
                )}
              </li>
            )
          })}
        </ul>
      )}

      {/* Tab 2 — my accepted contracts (all ports; deliver at each contract's destination). */}
      <SectionLabel className="mt-3">
        Your contracts{maxActive !== null ? ` · ${mine.length}/${maxActive}` : ''}
      </SectionLabel>
      {mine.length === 0 ? (
        <p data-testid="haul-mine-empty" className="mt-1 text-[10px] text-ink-muted">
          No active contracts. Accept one from the board.
        </p>
      ) : (
        <ul data-testid="haul-mine" className="mt-1 space-y-1.5">
          {mine.map((m) => {
            const avail = haulDeliverAvailability({
              serverLit: true,
              shipResolved: mainShipId !== null,
              docked: locationId !== null,
              atDestination: locationId !== null && locationId === m.dest_location_id,
              deadlineAhead: new Date(m.deliver_by).getTime() > nowMs,
              hasCargo: cargoFor(m.good_id) >= m.quantity,
            })
            const isPending = pending[m.contract_id] ?? false
            const note = rowNote[m.contract_id]
            return (
              <li
                key={m.contract_id}
                data-testid={`haul-mine-${m.contract_id}`}
                className="rounded border border-edge/60 bg-surface-2/40 px-2 py-1.5 text-[10px]"
              >
                <div className="flex items-center justify-between gap-2">
                  <span className="min-w-0 truncate text-ink">
                    {titleGood(m.good_id)}{' '}
                    <span className="font-mono tabular-nums text-ink-muted">×{m.quantity}</span>
                    <span className="text-ink-faint"> → {m.dest_name ?? 'Unknown port'}</span>
                  </span>
                  <span className="shrink-0 font-mono tabular-nums text-warning">
                    {m.reward_credits.toLocaleString()} cr
                  </span>
                </div>
                <div className="mt-1 flex items-center justify-between gap-2">
                  <span
                    data-testid={`haul-deadline-${m.contract_id}`}
                    className="shrink-0 font-mono tabular-nums text-ink-faint"
                  >
                    due {haulDeadlineLabel(m.deliver_by, nowMs)}
                  </span>
                  <span className="flex min-w-0 items-center gap-1.5">
                    <span className="truncate font-mono tabular-nums text-[9px] text-ink-muted">
                      hold {cargoFor(m.good_id)}/{m.quantity}
                    </span>
                    <Button
                      variant="primary"
                      size="sm"
                      data-testid={`haul-deliver-${m.contract_id}`}
                      disabled={!avail.canDeliver}
                      busy={isPending}
                      busyLabel="Delivering…"
                      onClick={() => void deliver(m.contract_id, m.reward_credits)}
                      className="shrink-0"
                    >
                      Deliver
                    </Button>
                  </span>
                </div>
                {(avail.reason === 'wrong_port' ||
                  avail.reason === 'deadline_passed' ||
                  avail.reason === 'insufficient_cargo') && (
                  <p className="mt-0.5 text-[10px] text-ink-muted">{haulReasonMessage(avail.reason)}</p>
                )}
                {note && (
                  <p data-testid={`haul-mine-note-${m.contract_id}`} className="mt-0.5 text-[10px] text-accent">
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
