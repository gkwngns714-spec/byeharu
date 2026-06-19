import { useCallback, useEffect, useRef, useState } from 'react'
import {
  deriveMainShipStatus,
  fetchMyMainShip,
  repairMainShip,
  requestMainShipReturn,
  type MainShipFleet,
  type MainShipView,
} from './mainshipApi'

// Main-ship overlay. Phase 10B: READ-ONLY view (name, hull, status, readiness, speed, cargo,
// captain/module slots) — NO support craft, NO support capacity, NO loadout. Phase 10D adds an
// OPTIONAL, flag-gated control block (derived status + Recall) via props: when `sendEnabled` is
// false/omitted it renders exactly as the 10B read-only view. Main ships are never old fleet_units.
// INVARIANT (Phase 10E): this is the ONLY main-ship RECALL surface (request_main_ship_return).
// The legacy leave/return path (request_leave_location) must never act on a main-ship fleet.

function Row({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="flex justify-between">
      <dt className="text-slate-400">{label}</dt>
      <dd className="text-slate-200">{value}</dd>
    </div>
  )
}

export function MainShipPreview({
  sendEnabled = false,
  fleet = null,
  onChanged,
}: {
  sendEnabled?: boolean
  fleet?: MainShipFleet | null
  onChanged?: () => Promise<void>
} = {}) {
  const [view, setView] = useState<MainShipView | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [recallError, setRecallError] = useState<string | null>(null)
  const [recalling, setRecalling] = useState(false)
  const recallRef = useRef(false)
  const [repairError, setRepairError] = useState<string | null>(null)
  const [repairing, setRepairing] = useState(false)
  const repairRef = useRef(false)

  const load = useCallback(() => {
    setLoading(true)
    return fetchMyMainShip().then(
      (v) => { setView(v); setError(null); setLoading(false) },
      (e) => { setError(e instanceof Error ? e.message : String(e)); setLoading(false) },
    )
  }, [])

  useEffect(() => {
    let active = true
    void fetchMyMainShip().then(
      (v) => { if (active) { setView(v); setError(null); setLoading(false) } },
      (e) => { if (active) { setError(e instanceof Error ? e.message : String(e)); setLoading(false) } },
    )
    return () => { active = false }
  }, [])

  const ship = view?.ship
  const hull = view?.hull
  // 10F: status='destroyed' = DISABLED / needs-repair for a PERSISTENT ship (never deletion).
  // It is read from the ship row (a disabled ship has no active fleet), and overrides the
  // fleet-derived status below.
  const isDisabled = ship?.status === 'destroyed'
  // 10D: the active linked fleet is the source of truth for live status (the ship row stays
  // 'traveling' while the fleet is 'present'). Recall is valid ONLY when present.
  const displayStatus = deriveMainShipStatus(fleet)
  const canRecall = sendEnabled && !isDisabled && displayStatus === 'present' && !!fleet

  async function doRecall() {
    if (recallRef.current || !fleet) return // synchronous double-submit guard
    recallRef.current = true
    setRecalling(true)
    setRecallError(null)
    try {
      await requestMainShipReturn(fleet.id) // verified 10C RPC
      if (onChanged) await onChanged()
      await load() // refresh this panel's own view
    } catch (e) {
      setRecallError(e instanceof Error ? e.message : String(e))
    } finally {
      recallRef.current = false
      setRecalling(false)
    }
  }

  async function doRepair() {
    if (repairRef.current) return // synchronous double-submit guard
    repairRef.current = true
    setRepairing(true)
    setRepairError(null)
    try {
      await repairMainShip() // 10F recovery RPC (auth.uid()-scoped; own ship only)
      if (onChanged) await onChanged()
      await load() // refresh this panel's own view → home + full hp
    } catch (e) {
      setRepairError(e instanceof Error ? e.message : String(e))
    } finally {
      repairRef.current = false
      setRepairing(false)
    }
  }

  return (
    <div data-testid="mainship-preview" className="rounded-xl border border-sky-400/20 bg-sky-500/5 p-4 text-sm text-slate-200">
      <div className="flex items-center justify-between">
        <h3 className="font-medium">🛰 Main Ship</h3>
        <span className="rounded bg-slate-700/60 px-2 py-0.5 text-[10px] uppercase tracking-wide text-slate-300">
          {sendEnabled ? 'Command' : 'Read-only'}
        </span>
      </div>

      {loading && <p className="mt-2 text-xs text-slate-500">Loading…</p>}
      {error && <p className="mt-2 text-rose-300">{error}</p>}

      {!loading && !error && view && (
        view.has_ship && ship ? (
          <>
            <dl className="mt-3 space-y-1.5">
              <Row label="Name" value={ship.name} />
              <Row label="Hull" value={hull?.name ?? ship.hull_type_id} />
              {/* When the flag is on, show the live status (disabled wins, else fleet-derived); otherwise the raw ship row. */}
              <Row label="Status" value={sendEnabled ? (isDisabled ? 'Disabled — needs repair' : displayStatus) : ship.status} />
              <Row label="Readiness (HP)" value={`${ship.hp} / ${ship.max_hp}`} />
              <Row label="Speed" value={hull?.base_speed ?? '—'} />
              <Row label="Cargo capacity" value={ship.cargo_capacity} />
              <Row label="Captain slots" value={ship.captain_slots} />
              <Row label="Module slots" value={ship.module_slots} />
            </dl>

            {/* Flag-on control block: 10F repair (when disabled) OR 10D recall (otherwise). */}
            {sendEnabled && (
              <div className="mt-3 border-t border-slate-700/60 pt-3">
                {isDisabled ? (
                  <>
                    <p data-testid="mainship-disabled-note" className="mb-2 rounded border border-amber-600/40 bg-amber-500/10 px-2 py-1.5 text-sm text-amber-200">
                      🛠 Your main ship was disabled and must be repaired before it can travel again.
                    </p>
                    {repairError && (
                      <p data-testid="mainship-repair-error" className="mb-2 rounded border border-rose-600/40 bg-rose-500/10 px-2 py-1.5 text-sm text-rose-300">
                        {repairError}
                      </p>
                    )}
                    <button
                      data-testid="mainship-repair"
                      disabled={repairing}
                      onClick={doRepair}
                      className="w-full rounded-md bg-amber-500 py-2 text-sm font-medium text-white transition hover:bg-amber-400 disabled:cursor-not-allowed disabled:bg-slate-700/60 disabled:text-slate-500"
                    >
                      {repairing ? 'Repairing…' : 'Repair main ship'}
                    </button>
                  </>
                ) : (
                  <>
                    {recallError && (
                      <p data-testid="mainship-recall-error" className="mb-2 rounded border border-rose-600/40 bg-rose-500/10 px-2 py-1.5 text-sm text-rose-300">
                        {recallError}
                      </p>
                    )}
                    <button
                      data-testid="mainship-recall"
                      disabled={!canRecall || recalling}
                      onClick={doRecall}
                      className="w-full rounded-md bg-sky-500 py-2 text-sm font-medium text-white transition hover:bg-sky-400 disabled:cursor-not-allowed disabled:bg-slate-700/60 disabled:text-slate-500"
                    >
                      {recalling ? 'Recalling…' : 'Recall main ship'}
                    </button>
                    {!canRecall && (
                      <p data-testid="mainship-recall-note" className="mt-2 text-center text-xs text-slate-500">
                        {displayStatus === 'home'
                          ? 'Main ship is home.'
                          : `Recall is available once the ship is present (currently ${displayStatus}).`}
                      </p>
                    )}
                  </>
                )}
              </div>
            )}
          </>
        ) : (
          <div className="mt-3">
            <p className="text-xs text-slate-400">No main ship commissioned yet — showing the starter hull.</p>
            {hull && (
              <dl className="mt-2 space-y-1.5">
                <Row label="Hull" value={hull.name} />
                <Row label="Base HP" value={hull.base_hp} />
                <Row label="Speed" value={hull.base_speed} />
                <Row label="Cargo capacity" value={hull.base_cargo_capacity} />
                <Row label="Captain slots" value={hull.base_captain_slots} />
                <Row label="Module slots" value={hull.base_module_slots} />
              </dl>
            )}
          </div>
        )
      )}
    </div>
  )
}
