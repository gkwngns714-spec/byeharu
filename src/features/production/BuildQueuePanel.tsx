import { useEffect, useState } from 'react'
import type { UnitType } from '../../lib/catalog'
import { formatCountdown } from '../../lib/time'
import { cancelBuildOrder } from './productionApi'
import type { BuildOrder } from './productionTypes'

// M4.5 — serial Training Queue. Only the ACTIVE item counts down (complete_at);
// WAITING items do not progress. Each item can be cancelled (server-authoritative).
export function BuildQueuePanel({
  orders,
  unitTypes,
  onChanged,
}: {
  orders: BuildOrder[]
  unitTypes: UnitType[]
  onChanged: () => void
}) {
  // 1s tick drives the active countdown only (lazy init keeps it pure).
  const [, setNow] = useState(() => Date.now())
  useEffect(() => {
    const iv = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(iv)
  }, [])

  const [cancelling, setCancelling] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const typeName = (id: string) => unitTypes.find((t) => t.id === id)?.name ?? id
  // Active first, then waiting in queue order; terminal states are hidden here.
  const active = orders.filter((o) => o.status === 'active')
  const waiting = orders.filter((o) => o.status === 'waiting')
  const items = [...active, ...waiting]

  async function handleCancel(id: string) {
    setCancelling(id)
    setError(null)
    try {
      await cancelBuildOrder(id)
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
            const left = isActive ? formatCountdown(o.complete_at) : null
            return (
              <li
                key={o.id}
                className="flex items-center justify-between gap-3 rounded-lg border border-white/10 bg-black/20 p-3 text-sm"
              >
                <div className="flex flex-col">
                  <span className="text-white/80">
                    {o.quantity}× {typeName(o.unit_type_id)}
                  </span>
                  <span className="text-xs text-white/45">
                    {isActive
                      ? left
                        ? `Building · ready in ${left}`
                        : 'Training complete — arriving…'
                      : 'Waiting'}
                  </span>
                </div>
                <button
                  onClick={() => handleCancel(o.id)}
                  disabled={cancelling === o.id}
                  className="rounded-md border border-white/15 px-3 py-1 text-xs text-white/80 transition hover:bg-white/10 disabled:opacity-40"
                >
                  {cancelling === o.id ? 'Cancelling…' : 'Cancel'}
                </button>
              </li>
            )
          })}
        </ul>
      )}
    </section>
  )
}
