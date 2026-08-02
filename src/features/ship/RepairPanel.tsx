import { useCallback, useEffect, useRef, useState } from 'react'
import { runGuardedCommand, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { getWalletBalance } from '../map/tradeApi'
import { getRepairConfigRows, getShipHull, repairShipHullAtPort } from '../port/repairApi'
import {
  clampRepairHp,
  isDestroyed,
  missingHull,
  repairAvailability,
  repairBlocks,
  repairConfigFromRows,
  repairCostFor,
  repairStickyLit,
  repairWalletDisplay,
  type RepairConfig,
  type ShipHull,
} from '../port/repairEconomy'
import { repairReasonMessage } from '../port/repairReasonMessage'
import { Button, Card, CardHeader, Meter, SectionLabel, Skeleton } from '../../components/ui'

// REPAIR-WHERE-YOU-ARE — the paid hull-mend surface, mounted in the Fitting detail's condition
// block (its ONE home; the Port-rail mount is retired with this slice — the player mends the ship
// they are LOOKING AT, next to the only per-ship hull meter in the game, without re-picking it at
// a dock desk). Named for its ship in the header, so the desk is never pointed at a mystery ship.
//
// DOCKEDNESS is a PROP: `docked` derives from the ship's own get_my_fleet_positions row
// (repairDockedPlace — place='docked' ONLY; see that function for why berthed stays false), the
// projection the shell already polls. ZERO new dockedness reads — the old locationId prop (the
// Port dock projection) was only ever a client-side is-docked proxy: repair_ship_hull_at_port
// takes no location and resolves the dock server-side (0201 → mainship_resolve_docked_location).
//
// CLIENT-FLAG-GATED on the SERVER'S OWN flag, read honestly from PUBLIC-READ game_config (the
// SalvageMarketPanel posture): 0201 shipped NO read RPC for repair, so the panel reads
// repair_economy_enabled itself and renders NOTHING unless it is jsonb true (strict fold). While
// the flag is false the server would also reject any repair with repair_economy_disabled before
// any read — double fail-closed, the client is never the control. NO optimistic UI: every repair
// awaits the server, refetches hull + wallet, then pings the screen (onMended) so the shared hull
// meters above re-read the hp the mend just changed. The availability mirror (repairEconomy.ts)
// is a display-only precheck; its hints and every server reject flow through the ONE
// repairReasonMessage mapper.
//
// EXACTLY ONE ACTION AT A TIME (the server-enforced mutual exclusion — free repair_main_ship
// gates on status='destroyed', paid repair REJECTS destroyed, 0201): the caller mounts this panel
// for ALIVE ships only (FittingDetail's isDisabled split — the free Repair/Tow block owns
// destroyed), and the branches below keep it honest even against a stale prop: destroyed hull →
// the free-path note, full hull → nothing to mend, damaged but not docked → the take-it-to-a-port
// line, damaged and docked → the mend (stepper + cost + ONE Repair).

export function RepairPanel({
  // The commanded ship (always resolved — the Fitting detail IS a ship) + its display name.
  mainShipId,
  shipName,
  // The ship's own dockedness (repairDockedPlace over its fleet-positions row — never a 2nd read).
  docked,
  // Re-reads whenever the screen's read lifecycle changes (the SalvageMarketPanel dep idiom).
  lifecycleKey,
  // A paid mend landed — the screen refetches the shared reads (hull meters, roster rows).
  onMended,
}: {
  mainShipId: string
  shipName: string
  docked: boolean
  lifecycleKey: string
  onMended: () => Promise<void>
}) {
  // null = flag unread (renders null — no pre-read flash); then the strict fold of the config read.
  const [cfg, setCfg] = useState<RepairConfig | null>(null)
  // null = not loaded · 'error' = hull read failed (honest unavailable line) · the hull otherwise.
  const [hull, setHull] = useState<ShipHull | 'error' | null>(null)
  // getWalletBalance semantics verbatim: number | null (lazy wallet) | 'error' (unknown) | undefined = unread.
  const [wallet, setWallet] = useState<number | null | 'error' | undefined>(undefined)
  // The repair amount (whole hp) + a transient text draft (lets the field be EMPTY while typing — the
  // SalvageMarketPanel qty idiom); defaulted to a FULL mend once the hull is known.
  const [amount, setAmount] = useState<number | null>(null)
  const [amountDraft, setAmountDraft] = useState<string | null>(null)
  const [pending, setPending] = useState(false)
  const [note, setNote] = useState<string | null>(null)

  const guards = useActivityPanelGuards()
  const { activeRef } = guards

  // STICKY-LIT (the salvage M1 posture): true once THIS MOUNT saw the flag genuinely enabled, so a
  // later dark config re-read (e.g. a post-repair refresh blip) never unmounts the panel + its success
  // note mid-interaction. First-mount reads stay fail-closed (dark until a POSITIVE strict read).
  const litRef = useRef(false)

  const refresh = useCallback(async () => {
    // The gate read comes FIRST (the server's own order): while the flag is dark this panel performs
    // NO hull/wallet read. Once lit, hull + wallet are plain owner reads (RLS) — they work wherever
    // the ship is, which is the point: an undamaged or undocked ship still gets an HONEST line
    // instead of a vanished panel. Dockedness itself is the `docked` prop, never a read here.
    const rows = await getRepairConfigRows()
    const nextCfg = repairConfigFromRows(rows)
    if (nextCfg.enabled) litRef.current = true
    if (!repairStickyLit(litRef.current, nextCfg.enabled)) {
      if (!activeRef.current) return
      setCfg(nextCfg)
      setHull(null)
      setWallet(undefined)
      return
    }
    const [h, w] = await Promise.all([getShipHull(mainShipId), getWalletBalance()])
    if (!activeRef.current) return
    // On a sticky transient (config unreadable AFTER being lit) keep the PRIOR cfg (the salvage posture).
    setCfg((prev) => (nextCfg.enabled ? nextCfg : (prev ?? nextCfg)))
    setHull(h ?? 'error')
    setWallet(w)
  }, [activeRef, mainShipId])

  // lifecycleKey is a deliberate re-fetch trigger (the SalvageMarketPanel dep idiom).
  useEffect(() => {
    void refresh()
  }, [refresh, lifecycleKey])

  async function repair(hpAmount: number) {
    if (!Number.isInteger(hpAmount) || hpAmount < 1) {
      setNote(repairReasonMessage('invalid_amount'))
      return
    }
    await runGuardedCommand({
      key: 'repair',
      guards,
      setPending: (on) => setPending(on),
      setNote: (n) => setNote(n),
      exec: () => repairShipHullAtPort(mainShipId, hpAmount, crypto.randomUUID()),
      // Success feedback with the SERVER's receipted numbers, never the client math.
      successNote: (res) =>
        `Repaired +${res.hp_restored} hull — −${res.total_price.toLocaleString('en-US')} credits.`,
      errorNote: (res) => repairReasonMessage(res.reason ?? 'unavailable'),
      // Own wave (hull + wallet) + the screen's shared reads: the meters above render the same
      // hull this mend just changed — both sides of that contract land together, never optimistic.
      refresh: async () => {
        await refresh()
        await onMended()
      },
    })
  }

  // FAIL CLOSED: render nothing unless the server's flag read affirmatively lit repairs (strict jsonb
  // true). An unread flag / a first-mount failed read collapse to null the same way. Once lit this
  // mount, a transient config blip keeps the PRIOR lit cfg (sticky-lit). The server would still
  // reject any repair (gate first).
  if (cfg == null || !cfg.enabled) return null

  return (
    <Card tone="warning" data-testid="repair-panel" className="mt-3">
      {/* THE SHIP'S NAME IS IN THE HEADER — the desk is never pointed at a mystery ship. */}
      <CardHeader title="Condition" subtitle={shipName} />

      {hull === null ? (
        // Transient only (refresh sets cfg + hull together) — a quiet skeleton, never a flash.
        <div className="mt-1" aria-busy="true">
          <Skeleton className="h-8 w-full rounded-lg" />
          <span className="sr-only">Loading the hull…</span>
        </div>
      ) : hull === 'error' ? (
        <p data-testid="repair-unavailable" className="mt-1 text-[10px] text-ink-muted">
          Hull status unavailable right now.
        </p>
      ) : (
        <RepairBody
          hull={hull}
          cfg={cfg}
          wallet={wallet}
          docked={docked}
          amount={amount}
          amountDraft={amountDraft}
          pending={pending}
          note={note}
          setAmount={setAmount}
          setAmountDraft={setAmountDraft}
          onRepair={repair}
        />
      )}
    </Card>
  )
}

// The lit-and-loaded body: destroyed / full / not-docked / mend — EXACTLY ONE branch renders, so
// the surface always carries one honest statement or one action, never two. Split out so the
// null/error/loading gates above stay flat (the SalvageMarketPanel readability posture).
function RepairBody({
  hull,
  cfg,
  wallet,
  docked,
  amount,
  amountDraft,
  pending,
  note,
  setAmount,
  setAmountDraft,
  onRepair,
}: {
  hull: ShipHull
  cfg: RepairConfig
  wallet: number | null | 'error' | undefined
  docked: boolean
  amount: number | null
  amountDraft: string | null
  pending: boolean
  note: string | null
  setAmount: (n: number) => void
  setAmountDraft: (s: string | null) => void
  onRepair: (hp: number) => void
}) {
  const destroyed = isDestroyed(hull)
  const missing = missingHull(hull)
  const pct = hull.maxHp > 0 ? (hull.hp / hull.maxHp) * 100 : 0
  const tone = destroyed ? 'danger' : missing > 0 ? 'accent' : 'success'

  // The default amount = a FULL mend (all missing hull); the player may dial it down. Clamped whole 1..missing.
  const effectiveAmount = missing > 0 ? clampRepairHp(amount ?? missing, missing) : 0
  const cost = repairCostFor(effectiveAmount, cfg.creditsPerHp)
  // Affordability precheck: wallet unknown ('error'/undefined) → null (skip; the server answers). A
  // lazy no-wallet-row player (null balance) rides on the starting-credits seed for the display check.
  const knownCredits =
    typeof wallet === 'number' ? wallet : wallet === null ? cfg.startingCredits : null
  const affordable = knownCredits === null || cost === null ? null : knownCredits >= cost

  const avail = repairAvailability({
    flagOn: true, // by construction: rendered only under the cfg.enabled gate
    amount: effectiveAmount || 1,
    shipResolved: true, // by construction: mainShipId is a required prop
    destroyed,
    docked, // the REAL value (the ship's own position row) — never hardcoded
    missing,
    affordable,
  })

  return (
    <>
      {destroyed ? (
        // THE SEAM: a destroyed ship recovers through the FREE path (repair_main_ship), not the paid
        // desk. Normally unreachable here (the caller mounts this panel for ALIVE ships only) — this
        // covers a stale-props race against the fresher hull read, honestly and button-free.
        <p data-testid="repair-destroyed" className="mt-2 text-[10px] text-ink-muted">
          {repairReasonMessage('ship_destroyed')}
        </p>
      ) : missing <= 0 ? (
        <p data-testid="repair-full" className="mt-2 text-[10px] text-ink-muted">
          {repairReasonMessage('nothing_to_repair')}
        </p>
      ) : !docked ? (
        // Damaged but not at a dock: the ONE honest line (the availability mirror's not_docked copy —
        // the same words a server reject would show). No stepper, no button that would 100%-fail.
        <p data-testid="repair-not-docked" className="mt-2 text-[10px] text-ink-muted">
          {repairReasonMessage('not_docked')}
        </p>
      ) : (
        <>
          <SectionLabel className="mt-3">Mend this ship&rsquo;s hull</SectionLabel>
          <div className="mt-1 flex items-center justify-between gap-2 text-[11px]">
            <Meter pct={pct} tone={tone} className="flex-1" />
            <span data-testid="repair-hull" className="shrink-0 font-mono tabular-nums text-ink-muted">
              {Math.floor(hull.hp)} / {Math.floor(hull.maxHp)}
            </span>
          </div>

          {/* Current credits — the getWalletBalance semantics verbatim ('error'/unread → '—'; no wallet
              row → the effective starting credits; the SalvageMarketPanel honesty posture). */}
          <div className="mt-1 flex items-center justify-between gap-2 text-xs">
            <span className="text-ink-faint">Credits</span>
            <span data-testid="repair-wallet" className="font-mono tabular-nums text-warning">
              {repairWalletDisplay(wallet, cfg.startingCredits)}
            </span>
          </div>

          <div className="mt-2 flex items-center justify-between gap-2 text-[10px]">
            {/* Whole-hp stepper — buttons clamp to 1..missing; typed input floors to whole 1.. and may
                exceed missing (server clamps to the actual missing hull, never over-charges). */}
            <span className="flex shrink-0 items-center gap-1">
              <Button
                variant="secondary"
                size="sm"
                data-testid="repair-dec"
                aria-label="Repair less hull"
                disabled={pending || effectiveAmount <= 1}
                onClick={() => {
                  setAmountDraft(null)
                  setAmount(clampRepairHp(effectiveAmount - 1, missing))
                }}
                className="px-2"
              >
                −
              </Button>
              <input
                type="number"
                min={1}
                step={1}
                data-testid="repair-amount"
                value={amountDraft ?? effectiveAmount}
                onChange={(ev) => {
                  const raw = ev.target.value
                  if (raw === '') {
                    setAmountDraft('')
                    return
                  }
                  setAmountDraft(null)
                  setAmount(clampRepairHp(parseInt(raw, 10), missing))
                }}
                onBlur={() => setAmountDraft(null)}
                className="w-16 rounded border border-edge bg-surface-2 px-1 py-0.5 text-right font-mono tabular-nums text-ink"
              />
              <Button
                variant="secondary"
                size="sm"
                data-testid="repair-inc"
                aria-label="Repair more hull"
                disabled={pending || effectiveAmount >= missing}
                onClick={() => {
                  setAmountDraft(null)
                  setAmount(clampRepairHp(effectiveAmount + 1, missing))
                }}
                className="px-2"
              >
                +
              </Button>
              <Button
                variant="secondary"
                size="sm"
                data-testid="repair-full-btn"
                disabled={pending || effectiveAmount >= missing}
                onClick={() => {
                  setAmountDraft(null)
                  setAmount(missing)
                }}
                className="px-2"
              >
                Full
              </Button>
            </span>
            <span className="flex min-w-0 items-center gap-1.5">
              {/* Display cost (hp × rate) — the server computes the receipted total under its lock. */}
              <span data-testid="repair-cost" className="truncate font-mono tabular-nums text-warning">
                {cost === null ? '—' : `${cost.toLocaleString('en-US')} cr`}
              </span>
              <Button
                variant="primary"
                size="sm"
                data-testid="repair-submit"
                // Hard-disable only on STRUCTURAL blocks (the salvage M2 posture): an unknown/stale
                // wallet only ADVISES below and the server's wallet_debit stays the enforcement.
                disabled={repairBlocks(avail.reason)}
                busy={pending}
                busyLabel="Repairing…"
                onClick={() => onRepair(effectiveAmount)}
                className="shrink-0"
              >
                Repair
              </Button>
            </span>
          </div>
          {/* The insufficient-credits advisory (button stays enabled — the server enforces). */}
          {avail.reason === 'insufficient_credits' && (
            <p className="mt-1 text-[10px] text-ink-muted">{repairReasonMessage('insufficient_credits')}</p>
          )}
        </>
      )}

      {note && (
        <p data-testid="repair-note" className="mt-1 text-[10px] text-accent">
          {note}
        </p>
      )}
    </>
  )
}
