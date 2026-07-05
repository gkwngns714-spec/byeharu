import { useCallback, useEffect, useRef, useState } from 'react'
import {
  deriveMainShipStatus,
  fetchMyMainShip,
  repairMainShip,
  requestMainShipReturn,
  type MainShipFleet,
  type MainShipView,
} from './mainshipApi'
import { Card, Badge, Button, Notice } from '../../components/ui'

// Main-ship overlay. Phase 10B: READ-ONLY view (name, hull, status, readiness, speed, cargo,
// captain/module slots) — NO support craft, NO support capacity, NO loadout. Phase 10D adds an
// OPTIONAL, flag-gated control block (derived status + Recall) via props: when `sendEnabled` is
// false/omitted it renders exactly as the 10B read-only view. Main ships are never old fleet_units.
// INVARIANT (Phase 10E): this is the ONLY main-ship RECALL surface (request_main_ship_return).
// The legacy leave/return path (request_leave_location) must never act on a main-ship fleet.

function Row({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="flex justify-between">
      <dt className="text-ink-faint">{label}</dt>
      <dd className="text-ink">{value}</dd>
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
      await repairMainShip(ship?.main_ship_id ?? null) // §2.5: explicit ship id; server asserts ownership (own ship only); null → shim
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
    <Card tone="accent" data-testid="mainship-preview" className="text-sm">
      <div className="flex items-center justify-between">
        <h3 className="font-medium text-ink">🛰 Main Ship</h3>
        <Badge tone="neutral">{sendEnabled ? 'Command' : 'Read-only'}</Badge>
      </div>

      {loading && <p className="mt-2 text-xs text-ink-faint">Loading…</p>}
      {error && <p className="mt-2 text-danger">{error}</p>}

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
              <div className="mt-3 border-t border-edge pt-3">
                {isDisabled ? (
                  <>
                    <Notice tone="warning" data-testid="mainship-disabled-note" className="mb-2">
                      🛠 Your main ship was disabled and must be repaired before it can travel again.
                    </Notice>
                    {repairError && (
                      <Notice tone="danger" data-testid="mainship-repair-error" className="mb-2">
                        {repairError}
                      </Notice>
                    )}
                    <Button
                      variant="warning"
                      data-testid="mainship-repair"
                      busy={repairing}
                      busyLabel="Repairing…"
                      onClick={doRepair}
                      className="w-full"
                    >
                      Repair main ship
                    </Button>
                  </>
                ) : (
                  <>
                    {recallError && (
                      <Notice tone="danger" data-testid="mainship-recall-error" className="mb-2">
                        {recallError}
                      </Notice>
                    )}
                    <Button
                      variant="primary"
                      data-testid="mainship-recall"
                      disabled={!canRecall}
                      busy={recalling}
                      busyLabel="Recalling…"
                      onClick={doRecall}
                      className="w-full"
                    >
                      Recall main ship
                    </Button>
                    {!canRecall && (
                      <p data-testid="mainship-recall-note" className="mt-2 text-center text-xs text-ink-faint">
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
            <p className="text-xs text-ink-muted">No main ship commissioned yet — showing the starter hull.</p>
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
    </Card>
  )
}
