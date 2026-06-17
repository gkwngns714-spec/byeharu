import type { UnitType } from '../../lib/catalog'
import { formatLocationLabel } from '../../lib/location'
import type { Base, BaseResource, BaseUnit } from './baseTypes'

// Presentational base view. Renders backend state only — no calculations of game
// outcomes. "At base" quantities reflect units NOT currently reserved in fleets
// (reserve happens server-side on dispatch, so base_units already excludes them).

export function BasePanel({
  base,
  units,
  resources,
  unitTypes,
}: {
  base: Base
  units: BaseUnit[]
  resources: BaseResource[]
  unitTypes: UnitType[]
}) {
  const typeName = (id: string) => unitTypes.find((t) => t.id === id)?.name ?? id

  return (
    <section className="rounded-2xl border border-white/10 bg-white/5 p-6">
      <div className="mb-4 flex items-baseline justify-between">
        <h2 className="text-lg font-medium">{base.name}</h2>
        <span className="text-xs text-white/40">
          {formatLocationLabel({ x: base.x, y: base.y })}
        </span>
      </div>

      <div className="grid gap-6 sm:grid-cols-2">
        <div>
          <h3 className="mb-2 text-xs uppercase tracking-wide text-white/40">Resources</h3>
          <ul className="space-y-1 text-sm">
            {resources.length === 0 && <li className="text-white/40">none</li>}
            {resources
              .slice()
              .sort((a, b) => a.resource_code.localeCompare(b.resource_code))
              .map((r) => (
                <li key={r.id} className="flex justify-between">
                  <span className="capitalize text-white/70">{r.resource_code}</span>
                  <span className="tabular-nums">{r.amount}</span>
                </li>
              ))}
          </ul>
        </div>

        <div>
          <h3 className="mb-2 text-xs uppercase tracking-wide text-white/40">Units at base</h3>
          <ul className="space-y-1 text-sm">
            {units.filter((u) => u.quantity > 0).length === 0 && (
              <li className="text-white/40">all units are deployed</li>
            )}
            {units
              .slice()
              .sort((a, b) => a.unit_type_id.localeCompare(b.unit_type_id))
              .map((u) => (
                <li key={u.id} className="flex justify-between">
                  <span className="text-white/70">{typeName(u.unit_type_id)}</span>
                  <span className="tabular-nums">{u.quantity}</span>
                </li>
              ))}
          </ul>
        </div>
      </div>
    </section>
  )
}
