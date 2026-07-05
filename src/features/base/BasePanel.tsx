import type { UnitType } from '../../lib/catalog'
import { formatLocationLabel } from '../../lib/location'
import type { Base, BaseResource, BaseUnit } from './baseTypes'
import { Card, CardHeader, SectionLabel } from '../../components/ui'

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
    <Card>
      <CardHeader
        title={base.name}
        aside={<span className="text-xs text-ink-faint">{formatLocationLabel({ x: base.x, y: base.y })}</span>}
      />

      <div className="grid gap-6 sm:grid-cols-2">
        <div>
          <SectionLabel>Resources</SectionLabel>
          <ul className="space-y-1 text-sm">
            {resources.length === 0 && <li className="text-ink-faint">none</li>}
            {resources
              .slice()
              .sort((a, b) => a.resource_code.localeCompare(b.resource_code))
              .map((r) => (
                <li key={r.id} className="flex justify-between">
                  <span className="capitalize text-ink-muted">{r.resource_code}</span>
                  <span className="font-mono tabular-nums text-ink">{r.amount}</span>
                </li>
              ))}
          </ul>
        </div>

        <div>
          <SectionLabel>Units at base</SectionLabel>
          <ul className="space-y-1 text-sm">
            {units.filter((u) => u.quantity > 0).length === 0 && (
              <li className="text-ink-faint">all units are deployed</li>
            )}
            {units
              .slice()
              .sort((a, b) => a.unit_type_id.localeCompare(b.unit_type_id))
              .map((u) => (
                <li key={u.id} className="flex justify-between">
                  <span className="text-ink-muted">{typeName(u.unit_type_id)}</span>
                  <span className="font-mono tabular-nums text-ink">{u.quantity}</span>
                </li>
              ))}
          </ul>
        </div>
      </div>
    </Card>
  )
}
