import { useEffect, useState } from 'react'
import type { UnitType } from '../../lib/catalog'
import { formatCountdown, formatDuration } from '../../lib/time'
import { perShipBuildSeconds, previewBuildSeconds } from '../../game/production/buildPreview'
import { cancelBuildOrder } from './productionApi'
import type { BuildOrder } from './productionTypes'

// M4.5 — serial Training Queue. Only the ACTIVE item progresses (per-ship tick +
// total countdown); WAITING items show times but no countdown. The per-ship tick is
// VISUAL ONLY — ships are delivered when the full order completes. Cancel shows a
// refund/penalty preview (refund = server rule: waiting 100% / active 50%).
export function BuildQueuePanel({
  orders,
  unitTypes,
  config,
  onChanged,
}: {
  orders: BuildOrder[]
  unitTypes: UnitType[]
  config: Record<string, number>
  onChanged: () => void
}) {
  // 1s tick drives the live displays (lazy init keeps it pure).
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const iv = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(iv)
  }, [])

  const [cancelling, setCancelling] = useState<string | null>(null)
  const [confirmId, setConfirmId] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const typeName = (id: string) => unitTypes.find((t) => t.id === id)?.name ?? id
  const active = orders.filter((o) => o.status === 'active')
  const waiting = orders.filter((o) => o.status === 'waiting')
  const items = [...active, ...waiting]

  async function handleCancel(id: string) {
    setCancelling(id)
    setError(null)
    try {
      await cancelBuildOrder(id)
      setConfirmId(null)
      onChanged()
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setCancelling(null)
    }
  }

  return (
    <section className="rounded-2xl border border-white/10 bg-white/5 p-4 sm:p-6">
      <h2 className="mb-4 text-lg font-medium">Training Queue</h2>
      {error && <p className="mb-3 text-sm text-red-400">{error}</p>}
      {items.length === 0 ? (
        <p className="text-sm text-white/40">No ships training. Use Train Ships above.</p>
      ) : (
        <ul className="space-y-2">
          {items.map((o) => {
            const isActive = o.status === 'active'
            const unit = unitTypes.find((u) => u.id === o.unit_type_id)
            const perShip = perShipBuildSeconds(unit, config)
            const total = previewBuildSeconds(unit, o.quantity, config)
            const left = isActive ? formatCountdown(o.complete_at) : null

            // Per-ship progress (active + valid timestamps). All values clamped so we
            // never show "Ship 6 of 5", negative time, or NaN.
            let shipLine: string | null = null
            if (isActive && o.started_at && perShip > 0) {
              const startMs = new Date(o.started_at).getTime()
              if (!Number.isNaN(startMs)) {
                const elapsed = Math.max(0, (now - startMs) / 1000)
                const shipNum = Math.min(o.quantity, Math.floor(elapsed / perShip) + 1)
                const shipElapsed = Math.min(perShip, Math.max(0, elapsed - (shipNum - 1) * perShip))
                shipLine = `Ship ${shipNum} of ${o.quantity}: ${formatDuration(Math.floor(shipElapsed))} / ${formatDuration(perShip)}`
              }
            }

            // Refund preview — mirrors cancel_build_order exactly (uses metal_spent).
            const refund = o.status === 'waiting' ? o.metal_spent : Math.floor(o.metal_spent * 0.5)
            const penalty = o.metal_spent - refund

            return (
              <li key={o.id} className="rounded-lg border border-white/10 bg-black/20 p-3 text-sm">
                <div className="flex items-start justify-between gap-3">
                  <div className="flex flex-col gap-0.5">
                    <span className="text-white/80">
                      {typeName(o.unit_type_id)} ×{o.quantity}
                    </span>
                    <span className="text-xs text-white/45">
                      Per ship: {formatDuration(perShip)} · Total order: {formatDuration(total)}
                    </span>
                    {isActive ? (
                      <>
                        {shipLine && <span className="text-xs text-white/55">{shipLine}</span>}
                        <span className="text-xs text-white/45">Remaining: {left ?? '—'}</span>
                        <span className="text-[10px] text-white/30">Ships delivered when the full order completes.</span>
                      </>
                    ) : (
                      <span className="text-xs text-white/45">Waiting</span>
                    )}
                  </div>
                  {confirmId !== o.id && (
                    <button
                      onClick={() => setConfirmId(o.id)}
                      className="shrink-0 rounded-md border border-white/15 px-3 py-1 text-xs text-white/80 transition hover:bg-white/10"
                    >
                      Cancel
                    </button>
                  )}
                </div>

                {confirmId === o.id && (
                  <div className="mt-2 rounded-lg border border-amber-400/30 bg-amber-400/10 p-3">
                    <p className="text-xs text-amber-100">
                      Cancel {typeName(o.unit_type_id)} ×{o.quantity}?
                    </p>
                    <p className="mt-0.5 text-xs text-white/70">
                      Refund: <span className="text-white/90">{refund} metal</span>
                      {penalty > 0 ? (
                        <> · Penalty: <span className="text-red-300">{penalty} metal lost</span></>
                      ) : (
                        ' · Penalty: none'
                      )}
                    </p>
                    <div className="mt-2 flex gap-2">
                      <button
                        onClick={() => setConfirmId(null)}
                        className="rounded-md border border-white/15 px-3 py-1 text-xs text-white/80 transition hover:bg-white/10"
                      >
                        Keep Building
                      </button>
                      <button
                        onClick={() => handleCancel(o.id)}
                        disabled={cancelling === o.id}
                        className="rounded-md bg-red-500/80 px-3 py-1 text-xs font-medium text-white transition hover:bg-red-500 disabled:opacity-40"
                      >
                        {cancelling === o.id ? 'Cancelling…' : 'Confirm Cancel'}
                      </button>
                    </div>
                  </div>
                )}
              </li>
            )
          })}
        </ul>
      )}
    </section>
  )
}
