import { useRef, useState } from 'react'
import type { MapLocation } from './mapTypes'
import type { MainShipLite } from './useGalaxyMapData'
import { deriveMainShipStatus, sendMainShipExpedition, type MainShipFleet } from './mainshipApi'

// Phase 10D — main-ship send surface. Deliberately SEPARATE from ExpeditionCommand: it has no
// unit pickers and never touches old fleet_units. Non-combat only (activity_type === 'none').
// INVARIANT (Phase 10E): this is the ONLY main-ship SEND surface (send_main_ship_expedition).
// The legacy expedition send (ExpeditionCommand → send_fleet_to_location) is a separate system.
// Rendered by GalaxyMapScreen ONLY when mainship_send_enabled is true, so when the flag is off
// the location panel is byte-for-byte today's behavior. The single write is the verified 10C
// RPC, fired once behind a synchronous ref guard + confirm step. The server re-validates all of
// flag / ownership / availability / non-combat — this UI gate is convenience, not trust.

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
  // Available only when the ship row is genuinely home AND there is no in-flight linked fleet —
  // matches send_main_ship_expedition's server check, so the button never shows a doomed send.
  const available = !!mainShip && !fleet && mainShip.status === 'home'

  async function doSend() {
    if (sendingRef.current || !mainShip) return // synchronous double-submit guard
    sendingRef.current = true
    setSending(true)
    setError(null)
    try {
      await sendMainShipExpedition(mainShip.main_ship_id, location.id) // verified 10C RPC
      setSuccess(`Main ship dispatched to ${location.name}.`)
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

          {!available ? (
            <p data-testid="mainship-send-unavailable" className="mt-3 text-center text-xs text-slate-500">
              Main ship is currently {status} — recall it before sending again.
            </p>
          ) : !confirming ? (
            <button
              data-testid="mainship-send"
              disabled={sending}
              onClick={() => { setSuccess(null); setError(null); setConfirming(true) }}
              className="mt-3 w-full rounded-md bg-sky-500 py-2 text-sm font-medium text-white transition hover:bg-sky-400 disabled:cursor-not-allowed disabled:bg-slate-700/60 disabled:text-slate-500"
            >
              {sending ? 'Sending…' : 'Send main ship'}
            </button>
          ) : (
            <div className="mt-3 rounded border border-sky-500/40 bg-sky-500/5 p-2.5">
              <p className="text-sm text-slate-200">
                Send your main ship to <span className="font-medium">{location.name}</span>?
              </p>
              <div className="mt-2 flex gap-2">
                <button
                  data-testid="mainship-send-confirm"
                  disabled={sending}
                  onClick={doSend}
                  className="flex-1 rounded-md bg-sky-500 py-1.5 text-sm font-medium text-white transition hover:bg-sky-400 disabled:cursor-not-allowed disabled:opacity-50"
                >
                  {sending ? 'Sending…' : 'Confirm'}
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
