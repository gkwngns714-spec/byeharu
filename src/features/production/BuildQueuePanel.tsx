import { useEffect, useState } from 'react'
import type { UnitType } from '../../lib/catalog'
import { formatCountdown } from '../../lib/time'
import type { BuildOrder } from './productionTypes'

// M7 — player-facing "Training Queue": active training orders with a live countdown.
// Read-only; the server cron deposits finished ships into the base.
export function BuildQueuePanel({ orders, unitTypes }: { orders: BuildOrder[]; unitTypes: UnitType[] }) {
  // 1s tick drives the countdown display only (lazy init keeps it pure).
  const [, setNow] = useState(() => Date.now())
  useEffect(() => {
    const iv = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(iv)
  }, [])

  const typeName = (id: string) => unitTypes.find((t) => t.id === id)?.name ?? id
  const queued = orders.filter((o) => o.status === 'queued')

  return (
    <section className="rounded-2xl border border-white/10 bg-white/5 p-4 sm:p-6">
      <h2 className="mb-4 text-lg font-medium">Training Queue</h2>
      {queued.length === 0 ? (
        <p className="text-sm text-white/40">No ships training. Use Train Ships above.</p>
      ) : (
        <ul className="space-y-2">
          {queued.map((o) => {
            const left = formatCountdown(o.complete_at)
            return (
              <li
                key={o.id}
                className="flex items-center justify-between rounded-lg border border-white/10 bg-black/20 p-3 text-sm"
              >
                <span className="text-white/80">
                  {o.quantity}× {typeName(o.unit_type_id)}
                </span>
                <span className="text-xs text-white/50">
                  {left ? `ready in ${left}` : 'Training complete — arriving…'}
                </span>
              </li>
            )
          })}
        </ul>
      )}
    </section>
  )
}
