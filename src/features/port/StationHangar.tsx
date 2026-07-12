import { hasStore, type DockedStore } from '../map/dockStore'
import { Card, SectionLabel, StatRow } from '../../components/ui'
import { ItemTile } from '../../components/items'

// STATION-STORAGE — the docked-port HANGAR surface, in the Ship/Port design language: IDENTITY (this port's
// own store) → DETAILS (its stored resources + units as plain StatRows). EVE model: assets are location-bound —
// what you see here belongs to THIS port only. PURE presentation over the server store projection (the one read
// lives in PortScreen via useDockStore); renders nothing unless the ship is docked at a storable port with a
// materialized store (hasStore — the fail-closed gate; dark → the server returns empty → this is null).
//
// Read-only for now: depositing/withdrawing needs ship cargo + hauling (a deferred follow-up). Today the hangar
// simply shows what is stored at the port you are docked at.

// Resource labels/glyphs come from the ONE item-visual catalog (components/items) — metal/energy
// resolve as resources, crystal as the item_types material; unknown codes degrade to title-case.
const UNIT_LABELS: Record<string, string> = {
  scout: 'Scouts',
  corvette: 'Corvettes',
  frigate: 'Frigates',
}
const titleCase = (s: string): string => s.charAt(0).toUpperCase() + s.slice(1).replace(/_/g, ' ')

export function StationHangar({ store }: { store: DockedStore }) {
  // Not docked at a storable port (in transit / in space / dark / storeless) → nothing.
  if (!hasStore(store)) return null

  const nothingStored = store.resources.length === 0 && store.units.length === 0

  return (
    <Card data-testid="station-hangar">
      {/* 1 · IDENTITY — this port's own store */}
      <div className="flex items-start justify-between gap-3">
        <div>
          <h2 className="text-lg font-semibold text-ink">Hangar</h2>
          <p className="mt-0.5 text-sm text-ink-muted">
            Stored at {store.locationName ?? 'this port'} — assets stay here until you move them.
          </p>
        </div>
        <p className="text-2xl" aria-hidden>📦</p>
      </div>

      {/* 2 · DETAILS — resources then units, plain-language rows */}
      {nothingStored ? (
        <p data-testid="station-hangar-empty" className="mt-4 text-sm text-ink-faint">
          This hangar is empty.
        </p>
      ) : (
        <>
          {store.resources.length > 0 && (
            <>
              <SectionLabel className="mt-4">Resources</SectionLabel>
              {/* ITEM-VIZ: stored resources as ItemTiles (glyph in a tinted square + name + mono
                  qty) — the grid-density "tablet" replaces the plain label/value rows. Testids
                  unchanged: station-hangar-resources + station-hangar-resource-<code>. */}
              <div data-testid="station-hangar-resources" className="mt-2 grid grid-cols-2 gap-2 sm:grid-cols-3">
                {store.resources.map((r) => (
                  <ItemTile
                    key={r.resourceCode}
                    data-testid={`station-hangar-resource-${r.resourceCode}`}
                    id={r.resourceCode}
                    kind="resource"
                    qty={Math.round(r.amount)}
                  />
                ))}
              </div>
            </>
          )}
          {store.units.length > 0 && (
            <>
              <SectionLabel className="mt-4">Garrison</SectionLabel>
              <dl data-testid="station-hangar-units" className="mt-2 space-y-1.5 text-sm">
                {store.units.map((u) => (
                  <StatRow
                    key={u.unitTypeId}
                    data-testid={`station-hangar-unit-${u.unitTypeId}`}
                    label={UNIT_LABELS[u.unitTypeId] ?? titleCase(u.unitTypeId)}
                    value={u.quantity.toLocaleString()}
                  />
                ))}
              </dl>
            </>
          )}
        </>
      )}
    </Card>
  )
}
