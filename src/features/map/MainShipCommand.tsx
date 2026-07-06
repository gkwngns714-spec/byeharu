import { useRef, useState } from 'react'
import type { MapLocation } from './mapTypes'
import type { MainShipLite } from './useGalaxyMapData'
import { deriveMainShipStatus, moveMainShipToLocation, sendMainShipExpedition, type MainShipFleet } from './mainshipApi'
import { Button, Notice, SectionLabel } from '../../components/ui'

// Phase 10D/10H — main-ship send/move surface. Deliberately SEPARATE from the retired legacy
// ExpeditionCommand (disposable-fleet send, removed in the UX cleanup pass): no unit pickers,
// never touches old fleet_units. Non-combat only (activity_type === 'none').
// INVARIANT (Phase 10E): this is the ONLY main-ship send/move surface.
//   • Home (no active fleet)      → send_main_ship_expedition (depart from base)
//   • Present at another location → move_main_ship_to_location (depart current location directly, 10H)
//   • Held in open space (Slice D1) → move_main_ship_to_location (depart from the held point; the
//                                     Slice-B held-departure branch, addressed by the held fleet id)
//   • Current location            → no button ("Main ship is already here")
//   • Moving / returning          → unavailable (accurate status text; Return Home is optional, not required)
//   • Destroyed                   → unavailable ("repair it first")
// Rendered by MapScreen ONLY when mainship_send_enabled is true. The server re-validates all
// of flag / ownership / state / non-combat / same-location — this UI gate is convenience, not trust.

export function MainShipCommand({
  location,
  mainShip,
  fleet,
  heldFleet,
  onSent,
}: {
  location: MapLocation
  mainShip: MainShipLite | null
  fleet: MainShipFleet | null
  heldFleet: MainShipFleet | null
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
  // Held in open space (Slice D1) → depart from the held point via the held fleet id. Gated on the ship
  // being genuinely held (spatial_state='in_space', no active fleet) AND its held fleet being resolved.
  const canSendFromHold = !!mainShip && mainShip.spatial_state === 'in_space' && !fleet && !!heldFleet
  const actionable = canSendFromHome || canMoveHere || canSendFromHold
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
      } else if (canSendFromHold && heldFleet) {
        await moveMainShipToLocation(heldFleet.id, location.id) // Slice B: depart from the held point
        setSuccess(`Main ship departing to ${location.name}.`)
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
    <div data-testid="mainship-command" className="mt-3 rounded-lg border border-accent/20 bg-surface-2/50 p-3">
      <SectionLabel className="mb-0 text-accent/90">🛰 Send main ship</SectionLabel>

      {/* No commissioned ship → neutral read-only note (NO commission action in 10D). */}
      {!mainShip ? (
        <p data-testid="mainship-command-none" className="mt-2 text-sm text-ink-muted">No main ship yet.</p>
      ) : isCombat ? (
        <p data-testid="mainship-command-combat" className="mt-2 text-sm text-ink-muted">
          Main ships can't enter combat zones yet.
        </p>
      ) : (
        <>
          <p className="mt-1 text-sm text-ink">
            Destination: <span className="font-medium">{location.name}</span>
          </p>

          {success && (
            <Notice tone="success" data-testid="mainship-send-success" className="mt-3">
              ✓ {success}
            </Notice>
          )}
          {error && (
            <Notice tone="danger" data-testid="mainship-send-error" className="mt-3">
              {error}
            </Notice>
          )}

          {isHere ? (
            <p data-testid="mainship-already-here" className="mt-3 text-center text-xs text-ink-muted">
              Main ship is already here.
            </p>
          ) : status === 'destroyed' ? (
            <p data-testid="mainship-send-disabled" className="mt-3 text-center text-xs text-warning/90">
              Main ship is disabled. Repair it before sending.
            </p>
          ) : !actionable ? (
            <p data-testid="mainship-send-unavailable" className="mt-3 text-center text-xs text-ink-faint">
              Main ship is currently {status}.
            </p>
          ) : !confirming ? (
            <Button
              variant="primary"
              data-testid="mainship-send"
              busy={sending}
              busyLabel="Working…"
              onClick={() => { setSuccess(null); setError(null); setConfirming(true) }}
              className="mt-3 w-full"
            >
              {actionLabel}
            </Button>
          ) : (
            <div className="mt-3 rounded-lg border border-accent/30 bg-surface-2/60 p-2.5">
              <p className="text-sm text-ink">
                {actionVerb} your main ship to <span className="font-medium">{location.name}</span>?
              </p>
              <div className="mt-2 flex gap-2">
                <Button
                  variant="primary"
                  data-testid="mainship-send-confirm"
                  busy={sending}
                  busyLabel="Working…"
                  onClick={doAction}
                  className="flex-1"
                >
                  Confirm
                </Button>
                <Button
                  data-testid="mainship-send-cancel"
                  disabled={sending}
                  onClick={() => setConfirming(false)}
                  className="flex-1"
                >
                  Cancel
                </Button>
              </div>
            </div>
          )}
        </>
      )}
    </div>
  )
}
