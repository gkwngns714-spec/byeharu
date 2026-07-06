import type { UnitType } from '../../lib/catalog'
import type { Base, BaseResource, BaseUnit } from './baseTypes'
import { Card, CardHeader, SectionLabel, StatRow } from '../../components/ui'

// UI-REBUILD (2b, Command interior) — the home-base card in the shared design language:
// IDENTITY (base name) → RIGHT NOW (a quiet all-clear line when nothing at the base needs
// attention — CommandScreen suppresses it while a battle is live, when the combat panels above
// are the focus) → DETAILS (stored resources + garrison as StatRows). Presentation only: renders
// backend state verbatim, no RPC, no calculation of game outcomes. "Garrison" quantities reflect
// units NOT currently reserved in fleets (reserve happens server-side on dispatch, so base_units
// already excludes them). NOTE: no client production/build surface exists today (the training UI
// was retired with the legacy fleet surfaces; train_units/cancel_build_order have no client call
// site) — none is invented here (a new command surface is a capability decision, not presentation).

export function BasePanel({
  base,
  units,
  resources,
  unitTypes,
  quiet = false,
}: {
  base: Base
  units: BaseUnit[]
  resources: BaseResource[]
  unitTypes: UnitType[]
  /** Show the all-clear right-now line (the screen passes false while a battle is live). */
  quiet?: boolean
}) {
  const typeName = (id: string) => unitTypes.find((t) => t.id === id)?.name ?? id
  const garrison = units.filter((u) => u.quantity > 0)

  return (
    <Card>
      {/* 1 · IDENTITY */}
      <CardHeader title={base.name} subtitle="Your home base" className="mb-3" />

      {/* 2 · RIGHT NOW — the base is quiet (suppressed while combat panels above hold the focus) */}
      {quiet && (
        <div data-testid="base-right-now" className="rounded-lg border border-edge bg-surface-2/50 p-3">
          <p className="text-sm text-ink-muted">All quiet — nothing here needs your attention.</p>
          <p className="mt-1 text-xs text-ink-faint">
            Set out from the <span className="text-ink">Map</span>; your battle history is below.
          </p>
        </div>
      )}

      {/* 3 · DETAILS — stored resources + garrison, plain language */}
      <div className="mt-4 grid gap-6 sm:grid-cols-2">
        <div>
          <SectionLabel>Stored resources</SectionLabel>
          {resources.length === 0 ? (
            <p className="mt-2 text-sm text-ink-faint">Nothing stored yet.</p>
          ) : (
            <dl className="mt-2 space-y-1.5 text-sm">
              {resources
                .slice()
                .sort((a, b) => a.resource_code.localeCompare(b.resource_code))
                .map((r) => (
                  <StatRow
                    key={r.id}
                    label={<span className="capitalize">{r.resource_code}</span>}
                    value={<span className="font-mono tabular-nums">{r.amount}</span>}
                  />
                ))}
            </dl>
          )}
        </div>

        <div>
          <SectionLabel>Garrison</SectionLabel>
          {garrison.length === 0 ? (
            <p className="mt-2 text-sm text-ink-faint">No units stationed at the base.</p>
          ) : (
            <dl className="mt-2 space-y-1.5 text-sm">
              {garrison
                .slice()
                .sort((a, b) => a.unit_type_id.localeCompare(b.unit_type_id))
                .map((u) => (
                  <StatRow
                    key={u.id}
                    label={typeName(u.unit_type_id)}
                    value={<span className="font-mono tabular-nums">{u.quantity}</span>}
                  />
                ))}
            </dl>
          )}
        </div>
      </div>
    </Card>
  )
}
