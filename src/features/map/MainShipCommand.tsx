import { useRef, useState } from 'react'
import type { MapLocation } from './mapTypes'
import type { MainShipLite } from './useGalaxyMapData'
import { deriveMainShipStatus, moveMainShipToLocation, sendMainShipExpedition, type MainShipFleet } from './mainshipApi'

// Phase 10D/10H — main-ship send/move surface. Deliberately SEPARATE from ExpeditionCommand: no
// unit pickers, never touches old fleet_units. Non-combat only (activity_type === 'none').
// INVARIANT (Phase 10E): this is the ONLY main-ship send/move surface.
//   • Home (no active fleet)      → send_main_ship_expedition (depart from base)
//   • Present at another location → move_main_ship_to_location (depart current location directly, 10H)
//   • Current location            → no button ("Main ship is already here")
//   • Moving / returning          → unavailable (accurate status text; Return Home is optional, not required)
//   • Destroyed                   → unavailable ("repair it first")
// Rendered by GalaxyMapScreen ONLY when mainship_send_enabled is true. The server re-validates all
// of flag / ownership / state / non-combat / same-location — this UI gate is convenience, not trust.

export function MainShipCommand({
  location,
  mainShip,
  fleet,
  onSent,
}: {
  location: MapLocation
  mainShip: MainShipLite | null
  fleet: MainShipFleet | null
  onSent: () => Promise<void>
}) {
  const [confirming, setConfirming] = useState(false)
  const [sending, setSending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [success, setSuccess] = useState<string | null>(null)
  const sendingRef = useRef(false)

  const isCombat = location.activity_type !== 'none'
  // Effective status: the live linked fleet wins; otherwise fall back to the ship row (covers
  // the brief completed-fleet → pre-reconciler gap where the ship row still reads 'returning').
  const status = fleet ? deriveMainShipStatus(fleet) : (mainShip?.status ?? 'home')
  // Home (no fleet, ship row home) → send from base. Present at ANOTHER location → move here directly.
  const canSendFromHome = !!mainShip && !fleet && mainShip.status === 'home'
  const presentFleet = fleet && fleet.status === 'present' ? fleet : null
  const isHere = !!presentFleet && presentFleet.current_location_id === location.id
  const canMoveHere = !!presentFleet && !isHere
  const actionable = canSendFromHome || canMoveHere
  const actionLabel = canMoveHere ? 'Move main ship here' : 'Send main ship'
  const actionVerb = canMoveHere ? 'Move' : 'Send'

  async function doAction() {
    if (sendingRef.current) return // synchronous double-submit guard
    sendingRef.current = true
    setSending(true)
    setError(null)
    try {
      // Re-read which action applies at click time (props are live-polled); the server re-validates,
      // so a stale present→moving transition is rejected cleanly rather than mis-firing.
      if (canMoveHere && presentFleet) {
        await moveMainShipToLocation(presentFleet.id, location.id) // 10H: depart current location → here
        setSuccess(`Main ship moving to ${location.name}.`)
      } else if (canSendFromHome && mainShip) {
        await sendMainShipExpedition(mainShip.main_ship_id, location.id) // verified 10C RPC (from base)
        setSuccess(`Main ship dispatched to ${location.name}.`)
      } else {
        return // not actionable (state changed under us) — server would reject anyway
      }
      setConfirming(false)
      await onSent() // refetch — live status comes from real data, not optimistic state
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
      setConfirming(false)
    } finally {
      sendingRef.current = false
      setSending(false)
    }
  }

  return (
    <div data-testid="mainship-command" className="mt-3 rounded-md border border-sky-500/30 bg-sky-500/5 p-3">
      <p className="text-xs uppercase tracking-wide text-sky-300/80">🛰 Send main ship</p>

      {/* No commissioned ship → neutral read-only note (NO commission action in 10D). */}
      {!mainShip ? (
        <p data-testid="mainship-command-none" className="mt-2 text-sm text-slate-400">No main ship yet.</p>
      ) : isCombat ? (
        <p data-testid="mainship-command-combat" className="mt-2 text-sm text-slate-400">
          Main ships can't enter combat zones yet.
        </p>
      ) : (
        <>
          <p className="mt-1 text-sm text-slate-200">
            Destination: <span className="font-medium">{location.name}</span>
          </p>

          {success && (
            <p data-testid="mainship-send-success" className="mt-3 rounded border border-emerald-600/40 bg-emerald-500/10 px-2 py-1.5 text-sm text-emerald-300">
              ✓ {success}
            </p>
          )}
          {error && (
            <p data-testid="mainship-send-error" className="mt-3 rounded border border-rose-600/40 bg-rose-500/10 px-2 py-1.5 text-sm text-rose-300">
              {error}
            </p>
          )}

          {isHere ? (
            <p data-testid="mainship-already-here" className="mt-3 text-center text-xs text-slate-400">
              Main ship is already here.
            </p>
          ) : status === 'destroyed' ? (
            <p data-testid="mainship-send-disabled" className="mt-3 text-center text-xs text-amber-300/80">
              Main ship is disabled. Repair it before sending.
            </p>
          ) : !actionable ? (
            <p data-testid="mainship-send-unavailable" className="mt-3 text-center text-xs text-slate-500">
              Main ship is currently {status}.
            </p>
          ) : !confirming ? (
            <button
              data-testid="mainship-send"
              disabled={sending}
              onClick={() => { setSuccess(null); setError(null); setConfirming(true) }}
              className="mt-3 w-full rounded-md bg-sky-500 py-2 text-sm font-medium text-white transition hover:bg-sky-400 disabled:cursor-not-allowed disabled:bg-slate-700/60 disabled:text-slate-500"
            >
              {sending ? 'Working…' : actionLabel}
            </button>
          ) : (
            <div className="mt-3 rounded border border-sky-500/40 bg-sky-500/5 p-2.5">
              <p className="text-sm text-slate-200">
                {actionVerb} your main ship to <span className="font-medium">{location.name}</span>?
              </p>
              <div className="mt-2 flex gap-2">
                <button
                  data-testid="mainship-send-confirm"
                  disabled={sending}
                  onClick={doAction}
                  className="flex-1 rounded-md bg-sky-500 py-1.5 text-sm font-medium text-white transition hover:bg-sky-400 disabled:cursor-not-allowed disabled:opacity-50"
                >
                  {sending ? 'Working…' : 'Confirm'}
                </button>
                <button
                  data-testid="mainship-send-cancel"
                  disabled={sending}
                  onClick={() => setConfirming(false)}
                  className="flex-1 rounded-md border border-slate-600 py-1.5 text-sm text-slate-300 transition hover:bg-slate-700/50 disabled:opacity-50"
                >
                  Cancel
                </button>
              </div>
            </div>
          )}
        </>
      )}
    </div>
  )
}
