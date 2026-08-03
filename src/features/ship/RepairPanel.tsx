import { useCallback, useEffect, useRef, useState } from 'react'
import { runGuardedCommand, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { getWalletBalance } from '../map/tradeApi'
import { getRepairConfigRows, getShipHull, repairShipHull } from './repairApi'
import { emergencyTowMainShip } from './shipRecoveryApi'
import {
  clampRepairHp,
  isDestroyed,
  missingHull,
  repairAvailability,
  repairBlocks,
  repairConfigFromRows,
  repairCostFor,
  repairPriceLabel,
  repairStickyLit,
  repairWalletDisplay,
  type RepairConfig,
  type RepairDockState,
  type ShipHull,
} from './repairEconomy'
import {
  recoveryReasonMessage,
  repairGate,
  repairPosition,
  repairPositionLine,
  towReasonMessage,
  towSuccessMessage,
  REPAIR_LABEL,
  TOW_LABEL,
  type DisabledShipRow,
} from './shipRecovery'
import type { FleetPosition } from '../map/mainshipApi'
import { Button, Card, CardHeader, Notice, SectionLabel } from '../../components/ui'

// ██ THE ONE REPAIR SURFACE ██ — mounted in the Fitting detail's condition block, right under the
// one hull meter in the game, for EVERY hull the player owns. Named for its ship in the header, so
// the desk is never pointed at a mystery ship.
//
// ── WHY THIS FILE IS NOW THE WHOLE SURFACE ────────────────────────────────────────────────────────
// The owner: "remove the command ship repair section in ships". There was never a COMMAND-SHIP
// repair path — `main_ship_instances` is EVERY ship and no repair path reads is_command_ship (0335's
// header proves this against the deployed bodies). What the owner was seeing was TWO REPAIR BLOCKS:
// this panel, and a separate free-recovery block below it in FittingDetail carrying its own
// "Repair ship" / "Tow" buttons, its own copy, and its own command wired up in ShipScreen. Migration
// 0335 had already collapsed the SERVER into one verb (repair_ship_hull) whose only wreck/dent
// difference is the POLICY it applies — the client simply never followed. It does now: the second
// block is deleted, not hidden, and this component renders a wreck and a dent alike.
//
// The shape mirrors the server body exactly: ONE verb, ONE position authority, ONE reason
// vocabulary, ONE price vocabulary, and TWO clearly-marked POLICY blocks —
//   · A WRECK restores whole and free, ungated by repair_economy_enabled and by the price knob
//     (the 0052 NO-SOFTLOCK rule: no price and no flag may ever stand between a player and their
//     own wreck). So the wreck body renders BEFORE and INDEPENDENT of the config/hull/wallet reads
//     — a dark flag or a failed hull read can never silence a wreck's recovery.
//   · A DENT restores what was asked for, priced by repair_credits_per_hp behind the economy flag,
//     and stays SILENT when it has nothing true and useful to say.
//
// ── THE TOW LIVES HERE, AS THE SECOND ACTION ─────────────────────────────────────────────────────
// mainship_emergency_tow is a different VERB — it MOVES a wreck rather than repairing one — but it
// exists for exactly one reason: it is the way out of this surface's position gate. 0335's own
// precondition block refuses to deploy without it ("the position gate must never exist without its
// recovery route"). A separate panel for it would be a second surface for one player intent, and
// would put the escape hatch somewhere other than the wall it opens. So it renders IN PLACE OF the
// Repair action, exactly when the server would refuse repair for position — never beside it, so the
// player is never offered two repair-ish buttons again.
//
// ── POSITION — ONE VALUE, TWO COMPLEMENTARY READS ────────────────────────────────────────────────
// `repairPosition` (shipRecovery.ts) folds the wreck-readiness gate and the fleet-positions row into
// the single RepairDockState this file branches on. It needs both because the two server projections
// cover DISJOINT ship sets: get_my_fleet_positions excludes destroyed ships outright, and
// get_my_disabled_ships contains only destroyed ships. ZERO new position reads — both already ride
// waves the screen polls.
//
// NO OPTIMISTIC UI: every command awaits the server, then refetches its own wave (hull + wallet) AND
// pings the screen (onChanged) in parallel, so the shared hull meter above re-reads the hp the
// command just changed. And it renders NO hull meter of its own — MeterPairBars directly above is
// the one hull display; two bars for one fact would be the one-authority law broken in pixels.

/**
 * The panel's server surface, injectable so the rendered proof (tests/repairSurface.uispec.ts) can
 * drive the REAL component across server states without a network (the useDockServices `fetcher`
 * idiom). Production always gets LIVE_API; there is no second implementation in app code.
 */
export interface RepairPanelApi {
  getConfigRows: typeof getRepairConfigRows
  getHull: typeof getShipHull
  getWallet: typeof getWalletBalance
  repair: typeof repairShipHull
  tow: typeof emergencyTowMainShip
}

const LIVE_API: RepairPanelApi = {
  getConfigRows: getRepairConfigRows,
  getHull: getShipHull,
  getWallet: getWalletBalance,
  repair: repairShipHull,
  tow: emergencyTowMainShip,
}

export function RepairPanel({
  // The commanded ship (always resolved — the Fitting detail IS a ship) + its display name.
  mainShipId,
  shipName,
  // The FRESHEST status the screen has for this ship (freshestShipStatus — the refetched shared
  // read, falling back to the never-repolled selection row). 'destroyed' is the wreck policy.
  shipStatus,
  // 0297's wreck-readiness read (null = unavailable → the gate fails OPEN and still offers Repair).
  disabledShips,
  // The ship's own fleet-positions row — the living-hull half of the position answer.
  position,
  // Re-reads whenever the screen's read lifecycle changes (the SalvageMarketPanel dep idiom).
  lifecycleKey,
  // A repair/recovery/tow landed — the screen refetches the shared reads (hull meters, roster rows).
  onChanged,
  api = LIVE_API,
}: {
  mainShipId: string
  shipName: string
  shipStatus: string
  disabledShips: DisabledShipRow[] | null
  position: Pick<FleetPosition, 'place'> | undefined
  lifecycleKey: string
  onChanged: () => Promise<void>
  api?: RepairPanelApi
}) {
  // null = flag unread (renders null on the DENT path — no pre-read flash); then the strict fold.
  const [cfg, setCfg] = useState<RepairConfig | null>(null)
  // null = not loaded (renders null — see below) · 'error' = hull read failed (honest line) · the hull.
  const [hull, setHull] = useState<ShipHull | 'error' | null>(null)
  // getWalletBalance semantics verbatim: number | null (lazy wallet) | 'error' (unknown) | undefined = unread.
  const [wallet, setWallet] = useState<number | null | 'error' | undefined>(undefined)
  // The repair amount (whole hp) + a transient text draft (lets the field be EMPTY while typing — the
  // SalvageMarketPanel qty idiom); defaulted to a FULL mend once the hull is known.
  const [amount, setAmount] = useState<number | null>(null)
  const [amountDraft, setAmountDraft] = useState<string | null>(null)
  const [pending, setPending] = useState(false)
  const [note, setNote] = useState<string | null>(null)
  // The tow's own command state — a different verb, so its outcome gets its own line rather than
  // overwriting a repair receipt.
  const [towing, setTowing] = useState(false)
  const [towNote, setTowNote] = useState<string | null>(null)
  // THE SERVER'S OWN POSITION VERDICT. A repair that came back not_at_port outranks a stale or
  // unavailable readiness read: the player is shown the tow immediately rather than a button that
  // just failed. Held here because this is the only surface that both issues the command and
  // renders the consequence.
  const [sawAdrift, setSawAdrift] = useState(false)

  const guards = useActivityPanelGuards()
  const { activeRef } = guards

  // STICKY-LIT (the salvage M1 posture): true once THIS MOUNT saw the flag genuinely enabled, so a
  // later dark config re-read (e.g. a post-repair refresh blip) never unmounts the panel + its success
  // note mid-interaction. First-mount reads stay fail-closed (dark until a POSITIVE strict read).
  const litRef = useRef(false)

  // NOTE RETIREMENT — the lifecycle key this panel has already answered for. A stale command note
  // (a receipt, or a ten-minute-old error) must survive its own command's refetch (runGuardedCommand
  // sets the note and then refreshes under the SAME key) but NOT the player's next journey — a key
  // tick retires it, otherwise the pending-note exception below would hold the silence gate off
  // forever. A ship switch clears notes by remount (the ship-id key on the panel's mount).
  const seenKeyRef = useRef(lifecycleKey)

  const refresh = useCallback(async () => {
    // The gate read comes FIRST (the server's own order): while the flag is dark this panel performs
    // NO hull/wallet read. Once lit, hull + wallet are plain owner reads (RLS) — they work wherever
    // the ship is, which is the point: the missing-hull check must not depend on being docked.
    // Position itself is never read here — it arrives folded, from waves the screen already polls.
    const rows = await api.getConfigRows()
    const nextCfg = repairConfigFromRows(rows)
    if (nextCfg.enabled) litRef.current = true
    // The note-retirement decision (see seenKeyRef above) — settled INSIDE the async wave, never
    // synchronously in the effect body (the set-state-in-effect rule).
    const keyTicked = seenKeyRef.current !== lifecycleKey
    seenKeyRef.current = lifecycleKey
    if (!repairStickyLit(litRef.current, nextCfg.enabled)) {
      if (!activeRef.current) return
      if (keyTicked) {
        setNote(null)
        setTowNote(null)
      }
      setCfg(nextCfg)
      setHull(null)
      setWallet(undefined)
      return
    }
    const [h, w] = await Promise.all([api.getHull(mainShipId), api.getWallet()])
    if (!activeRef.current) return
    if (keyTicked) {
      setNote(null)
      setTowNote(null)
    }
    // On a sticky transient (config unreadable AFTER being lit) keep the PRIOR cfg (the salvage posture).
    setCfg((prev) => (nextCfg.enabled ? nextCfg : (prev ?? nextCfg)))
    setHull(h ?? 'error')
    setWallet(w)
  }, [activeRef, api, mainShipId, lifecycleKey])

  // lifecycleKey is a deliberate re-fetch trigger (the SalvageMarketPanel dep idiom) — and, via
  // refresh's key tracking, the note-retirement tick.
  useEffect(() => {
    void refresh()
  }, [refresh, lifecycleKey])

  // Own wave (hull + wallet) + the screen's shared reads, IN PARALLEL (the runFitting shape): the
  // meter above renders the same hull this command just changed — both sides land together, with no
  // round-trip window where the desk and the meter disagree. Never optimistic.
  const settle = useCallback(async () => {
    await Promise.all([refresh(), onChanged()])
  }, [refresh, onChanged])

  /**
   * THE ONE REPAIR COMMAND, for both policies. `hpAmount` null means "all of it" — which is what a
   * wreck's recovery has always done, and what the server enforces for a wreck regardless of the
   * amount sent. 0335's verb is ENVELOPE-returning and never raises, so this is a plain result
   * check: no try/catch around a thrown Postgres message, and no substring matching of one.
   */
  async function runRepair(hpAmount: number | null) {
    if (hpAmount !== null && (!Number.isInteger(hpAmount) || hpAmount < 1)) {
      setNote(recoveryReasonMessage('invalid_amount'))
      return
    }
    await runGuardedCommand({
      key: 'repair',
      guards,
      setPending: (on) => setPending(on),
      setNote: (n) => setNote(n),
      exec: async () => {
        const res = await api.repair(mainShipId, hpAmount, crypto.randomUUID())
        // The server's position verdict, recorded before any refetch can overwrite it.
        if (activeRef.current) setSawAdrift(!res.ok && res.reason === 'not_at_port')
        if (res.ok) setTowNote(null)
        return res
      },
      // Success feedback with the SERVER's receipted numbers, never the client math — and through
      // the ONE price vocabulary, so a free repair says "Free" rather than "0 cr".
      successNote: (res) =>
        res.recovered
          ? `Recovered — hull restored to full · ${repairPriceLabel(res.total_price)}.`
          : `Repaired +${res.hp_restored} hull · ${repairPriceLabel(res.total_price)}.`,
      // ONE reason vocabulary: recoveryReasonMessage delegates to repairReasonMessage and overrides
      // exactly one key — not_at_port, where the generic "take this ship to a port" is useless
      // advice to a hull that cannot move itself.
      errorNote: (res) => recoveryReasonMessage(res.reason ?? 'unavailable'),
      refresh: settle,
    })
  }

  /** THE RECOVERY ROUTE (0297 §3) — free, always available to exactly the wrecks the position gate
   *  refuses; berths one at the nearest port, which is what unlocks the repair above. */
  async function runTow() {
    await runGuardedCommand({
      key: 'tow',
      guards,
      setPending: (on) => setTowing(on),
      setNote: (n) => setTowNote(n),
      exec: async () => {
        const res = await api.tow(mainShipId)
        if (!activeRef.current) return res
        setNote(null)
        if (res.ok || res.reason === 'already_at_port') setSawAdrift(false)
        // 'already_at_port' means our position view was STALE — settle so the refetched readiness
        // read replaces the tow with the Repair that will actually work. (runGuardedCommand settles
        // on success only, and a stale view is the one failure that still changed what we know.)
        if (!res.ok && res.reason === 'already_at_port') await settle()
        return res
      },
      successNote: (res) => towSuccessMessage(res.location_name),
      errorNote: (res) => towReasonMessage(res.reason),
      refresh: settle,
    })
  }

  // ── THE ONE STATE QUESTION, and the ONE position answer ────────────────────────────────────────
  // A wreck by the screen's freshest status OR by this panel's own (fresher) hull read — so a
  // mid-session destruction is never left on the priced desk waiting for the shared wave, and the
  // stale-status race the old surface had to explain in copy cannot happen.
  const wreck = shipStatus === 'destroyed' || (hull !== null && hull !== 'error' && isDestroyed(hull))
  const gate = repairGate(wreck ? 'destroyed' : shipStatus, disabledShips, mainShipId, sawAdrift)
  const dock: RepairDockState = repairPosition(gate, position)
  const positionLine = repairPositionLine(wreck, dock)

  // ── SILENCE, on the DENT path only ─────────────────────────────────────────────────────────────
  // FAIL CLOSED, AND QUIET: render nothing unless the server's flag read affirmatively lit repairs
  // (strict jsonb true). An unread flag / a first-mount failed read collapse to null the same way.
  // While the hull is UNREAD, also render nothing — no skeleton: a "Condition" card must never flash
  // up for a ship that turns out to have nothing to say (most ships are healthy).
  //
  // NONE OF IT APPLIES TO A WRECK. Its recovery is free and ungated on the server, so gating its
  // ACTION on the economy flag or on a hull read that may fail would be the client hiding a repair
  // the server would happily perform — the one thing NO-SOFTLOCK forbids.
  if (!wreck) {
    if (cfg == null || !cfg.enabled || hull === null) return null
    // With no pending note, the card renders ONLY when it has something true AND useful to say. An
    // UNREADABLE hull is noise, not information (the meter above reads its own query and may be
    // sitting there perfectly healthy — a "hull unavailable" line under a full green bar would be
    // the surface disagreeing with itself); a FULL hull has nothing to act on; an UNKNOWN position
    // permits no dock claim. A pending note always keeps the card up (a just-landed receipt or error
    // must not vanish under the player) — and the lifecycle tick retires stale notes.
    if (note == null && towNote == null) {
      if (hull === 'error') return null
      if (missingHull(hull) <= 0 || dock === 'unknown') return null
    }
  }

  // The warning tone marks an ACTIONABLE desk only (a wreck always is; a dent when damaged + docked).
  const actionable =
    wreck || (hull !== null && hull !== 'error' && missingHull(hull) > 0 && dock === 'at_port')

  return (
    <Card tone={actionable ? 'warning' : 'default'} data-testid="repair-panel" className="mt-3">
      {/* THE SHIP'S NAME IS IN THE HEADER — the desk is never pointed at a mystery ship. */}
      <CardHeader title="Condition" subtitle={shipName} />

      {/* THE ONE POSITION SENTENCE — a wreck always gets one, a dent only when it cannot be mended
          where it is (repairPositionLine; null renders nothing). */}
      {positionLine && (
        <Notice tone={wreck ? 'warning' : 'neutral'} data-testid="repair-position-note" className="mt-2">
          {positionLine}
        </Notice>
      )}

      {wreck ? (
        <RecoveryBody
          dock={dock}
          repairing={pending}
          towing={towing}
          onRepair={() => void runRepair(null)}
          onTow={() => void runTow()}
        />
      ) : hull === 'error' ? (
        <p data-testid="repair-unavailable" className="mt-1 text-[10px] text-ink-muted">
          Hull status unavailable right now.
        </p>
      ) : hull !== null && cfg !== null ? (
        <MendBody
          hull={hull}
          cfg={cfg}
          wallet={wallet}
          dock={dock}
          amount={amount}
          amountDraft={amountDraft}
          pending={pending}
          setAmount={setAmount}
          setAmountDraft={setAmountDraft}
          onRepair={(hp) => void runRepair(hp)}
        />
      ) : null}

      {towNote && (
        <p data-testid="repair-tow-note" className="mt-1 text-[10px] text-accent">
          {towNote}
        </p>
      )}
      {note && (
        <p data-testid="repair-note" className="mt-1 text-[10px] text-accent">
          {note}
        </p>
      )}
    </Card>
  )
}

/**
 * ██ WRECK POLICY ██ — restore whole, free, and never gated. One action: Repair where the server
 * will accept it, the Tow where it will not. Never both, never neither — that mutual exclusion is
 * the NO-SOFTLOCK rule expressed in one ternary over the one position value.
 *
 * NO STEPPER AND NO WALLET HERE, deliberately: 0335 restores a wreck's hull WHOLE and ignores the
 * requested amount, and charges nothing. A stepper would be a control the server does not honour,
 * and a price would be a claim it does not make.
 */
function RecoveryBody({
  dock,
  repairing,
  towing,
  onRepair,
  onTow,
}: {
  dock: RepairDockState
  repairing: boolean
  towing: boolean
  onRepair: () => void
  onTow: () => void
}) {
  return (
    <>
      <div className="mt-2 flex items-center justify-between gap-2 text-[10px]">
        <span className="text-ink-faint">Full hull restore</span>
        {/* The SAME price label the mend uses — a wreck is free by law (0335's cost policy). */}
        <span data-testid="repair-cost" className="font-mono tabular-nums text-warning">
          {repairPriceLabel(0)}
        </span>
      </div>
      {dock === 'away' ? (
        <Button
          variant="warning"
          data-testid="repair-tow"
          busy={towing}
          busyLabel="Towing…"
          onClick={onTow}
          className="mt-2 min-h-11 w-full"
        >
          {TOW_LABEL}
        </Button>
      ) : (
        <Button
          variant="warning"
          data-testid="repair-submit"
          busy={repairing}
          busyLabel="Repairing…"
          onClick={onRepair}
          className="mt-2 min-h-11 w-full"
        >
          {REPAIR_LABEL}
        </Button>
      )}
    </>
  )
}

/**
 * ██ DENT POLICY ██ — restore what was asked for, priced by the knob. EXACTLY ONE branch renders, so
 * the surface always carries one honest statement or one action, never two. NO hull meter here:
 * MeterPairBars directly above the panel is the one hull display (one fact, one rendering); the
 * stepper's bounds still come from this panel's own priced hull read (the numbers the server will
 * clamp against). The not-at-a-port and unknown-position cases say nothing here — the position
 * sentence above already spoke for them, once.
 */
function MendBody({
  hull,
  cfg,
  wallet,
  dock,
  amount,
  amountDraft,
  pending,
  setAmount,
  setAmountDraft,
  onRepair,
}: {
  hull: ShipHull
  cfg: RepairConfig
  wallet: number | null | 'error' | undefined
  dock: RepairDockState
  amount: number | null
  amountDraft: string | null
  pending: boolean
  setAmount: (n: number) => void
  setAmountDraft: (s: string | null) => void
  onRepair: (hp: number) => void
}) {
  const missing = missingHull(hull)

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
    atPort: dock === 'at_port', // the REAL fold of the ship's own position — never hardcoded
    missing,
    affordable,
  })

  // Reachable only with a pending note (a full hull with nothing to show renders no card at all) —
  // this line gives the receipt below its context: the mend finished, the hull is whole.
  if (missing <= 0) {
    return (
      <p data-testid="repair-full" className="mt-2 text-[10px] text-ink-muted">
        {recoveryReasonMessage('nothing_to_repair')}
      </p>
    )
  }
  // Genuinely not at a port / position unknown: the position sentence above is the whole statement.
  // No stepper, no button that would 100%-fail.
  if (dock !== 'at_port') return null

  return (
    <>
      <SectionLabel className="mt-3">Mend this ship&rsquo;s hull</SectionLabel>
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
          {/* Display cost (hp × rate) through the ONE price vocabulary — the server computes the
              receipted total under its lock. A live knob of 0 reads "Free", never "0 cr". */}
          <span data-testid="repair-cost" className="truncate font-mono tabular-nums text-warning">
            {repairPriceLabel(cost)}
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
        <p className="mt-1 text-[10px] text-ink-muted">{recoveryReasonMessage('insufficient_credits')}</p>
      )}
    </>
  )
}
