import { useRef, useState } from 'react'
import type { MapLocation } from './mapTypes'
import type { Base, BaseUnit } from '../base/baseTypes'
import type { UnitType } from '../../lib/catalog'
import { sendFleetToLocation, type SelectedUnit } from '../fleets/fleetApi'

// Map command surface (Phase 9B). Picks a loadout for the selected destination and sends an
// expedition through the EXISTING verified RPC (send_fleet_to_location) — no new backend, no
// direct table writes, no optimistic movement. The only write is the approved send call, fired
// exactly once (synchronous sendingRef guard + confirmation step). On success it calls onSent()
// so the parent refetches; the real movement line comes from that refetch, not from here.

const DISPATCHABLE = new Set(['none', 'hunt_pirates'])

export function ExpeditionCommand({
  location,
  base,
  units,
  unitTypes,
  onSent,
}: {
  location: MapLocation
  base: Base | null
  units: BaseUnit[]
  unitTypes: UnitType[]
  onSent: () => Promise<void>
}) {
  const [qty, setQty] = useState<Record<string, number>>({})
  const [confirming, setConfirming] = useState(false)
  const [sending, setSending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [success, setSuccess] = useState<string | null>(null)
  const sendingRef = useRef(false)
  // Note: the parent remounts this component with key={location.id}, so each destination
  // gets fresh state — no reset effect needed.

  const dispatchable = DISPATCHABLE.has(location.activity_type)
  const nameOf = (id: string) => unitTypes.find((t) => t.id === id)?.name ?? id
  const availableOf = (id: string) => units.find((u) => u.unit_type_id === id)?.quantity ?? 0

  const selected: SelectedUnit[] = Object.entries(qty)
    .filter(([, q]) => q > 0)
    .map(([unit_type_id, quantity]) => ({ unit_type_id, quantity }))
  const totalSelected = selected.reduce((n, s) => n + s.quantity, 0)
  const tooMany = selected.some((s) => s.quantity > availableOf(s.unit_type_id))
  const canSend = dispatchable && !!base && totalSelected > 0 && !tooMany && !sending

  const disabledReason = !base
    ? 'Expedition source unavailable (no home base).'
    : !dispatchable
      ? "This destination can't be sent to yet."
      : tooMany
        ? 'Not enough ships available.'
        : totalSelected === 0
          ? 'Select ships to send.'
          : null

  async function doSend() {
    if (sendingRef.current || !base) return // synchronous double-submit guard
    sendingRef.current = true
    setSending(true)
    setError(null)
    try {
      await sendFleetToLocation(base.id, location.id, selected) // the only UI write — verified RPC
      setSuccess(`Expedition dispatched to ${location.name}.`)
      setQty({})
      setConfirming(false)
      await onSent() // refetch — the new movement line comes from real data, not optimistic state
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
      setConfirming(false)
    } finally {
      sendingRef.current = false
      setSending(false)
    }
  }

  return (
    <div data-testid="galaxy-expedition-command" className="mt-4 rounded-md border border-slate-700 bg-slate-800/50 p-3">
      <p className="text-xs uppercase tracking-wide text-slate-400">Send expedition</p>
      <p className="mt-0.5 text-sm text-slate-200">
        Destination: <span className="font-medium">{location.name}</span>
      </p>

      {dispatchable && base && (
        <div className="mt-3 space-y-1.5">
          {units.slice().sort((a, b) => a.unit_type_id.localeCompare(b.unit_type_id)).map((u) => (
            <label key={u.unit_type_id} className="flex items-center justify-between gap-2 text-sm">
              <span className="text-slate-300">{nameOf(u.unit_type_id)}</span>
              <span className="flex items-center gap-1">
                <input
                  data-testid={`galaxy-unit-${u.unit_type_id}`}
                  type="number"
                  min={0}
                  max={u.quantity}
                  value={qty[u.unit_type_id] || ''}
                  placeholder="0"
                  disabled={sending}
                  onChange={(e) => setQty((q) => ({ ...q, [u.unit_type_id]: Math.max(0, Number(e.target.value) || 0) }))}
                  className="w-16 rounded border border-slate-600 bg-slate-900 px-2 py-1 text-right text-sm outline-none focus:border-indigo-400 disabled:opacity-50"
                />
                <span className="w-14 text-right text-xs text-slate-500">/ {u.quantity}</span>
              </span>
            </label>
          ))}
        </div>
      )}

      {success && (
        <p data-testid="galaxy-send-success" className="mt-3 rounded border border-emerald-600/40 bg-emerald-500/10 px-2 py-1.5 text-sm text-emerald-300">
          ✓ {success}
        </p>
      )}
      {error && (
        <p data-testid="galaxy-send-error" className="mt-3 rounded border border-rose-600/40 bg-rose-500/10 px-2 py-1.5 text-sm text-rose-300">
          {error}
        </p>
      )}

      {!confirming ? (
        <>
          <button
            data-testid="galaxy-send-expedition"
            disabled={!canSend}
            onClick={() => { setSuccess(null); setError(null); setConfirming(true) }}
            className="mt-3 w-full rounded-md bg-indigo-500 py-2 text-sm font-medium text-white transition hover:bg-indigo-400 disabled:cursor-not-allowed disabled:bg-slate-700/60 disabled:text-slate-500"
          >
            {sending ? 'Sending…' : 'Send expedition'}
          </button>
          {disabledReason && (
            <p data-testid="galaxy-send-disabled-reason" className="mt-2 text-center text-xs text-slate-500">{disabledReason}</p>
          )}
        </>
      ) : (
        <div className="mt-3 rounded border border-indigo-500/40 bg-indigo-500/5 p-2.5">
          <p className="text-sm text-slate-200">
            Send {totalSelected} ship{totalSelected === 1 ? '' : 's'} to <span className="font-medium">{location.name}</span>?
          </p>
          <div className="mt-2 flex gap-2">
            <button
              data-testid="galaxy-send-confirm"
              disabled={sending}
              onClick={doSend}
              className="flex-1 rounded-md bg-indigo-500 py-1.5 text-sm font-medium text-white transition hover:bg-indigo-400 disabled:cursor-not-allowed disabled:opacity-50"
            >
              {sending ? 'Sending…' : 'Confirm'}
            </button>
            <button
              data-testid="galaxy-send-cancel"
              disabled={sending}
              onClick={() => setConfirming(false)}
              className="flex-1 rounded-md border border-slate-600 py-1.5 text-sm text-slate-300 transition hover:bg-slate-700/50 disabled:opacity-50"
            >
              Cancel
            </button>
          </div>
        </div>
      )}
    </div>
  )
}
