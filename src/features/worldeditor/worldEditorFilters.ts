// WORLD EDITOR — V5 LIFECYCLE: the ONE shared LIFECYCLE VIEW filter. Items in → the filtered,
// flattened view out. This is the ONE filter authority the map render loop, the search index, and the
// per-layer counts all consume; it SUBSUMES the shell's former inline `visibleItems` compute AND
// REPLACES the location-only status filter (PR #274) with a SINGLE cross-domain lifecycle narrow.
// Pure NAVIGATION/VIEW state: it NEVER mutates its inputs, writes no coordinate, reads no source row,
// and issues no IO — it reads only the adapter/catalog-resolved LayerItems the shell already holds. No
// React, no DOM, no fetch: unit-tested directly (tests/worldEditorFilters.spec.ts).
//
// LIFECYCLE, NOT PER-DOMAIN STATUS: the item source is now the 0269 lifecycle CATALOG
// (worldEditorCatalog), so EVERY item carries a normalized lifecycle_status ('active' | 'inactive')
// across all four domains — locations, mining, exploration, AND zones. One shared filter honors it
// everywhere: 'active' shows active, 'inactive' shows only inactive, 'all' shows both.
import { WORLD_EDITOR_LAYERS } from './worldEditorRegistry'
import type { LayerId, LayerItem } from './worldEditorTypes'

/** The ONE shared lifecycle filter across every domain (§WE.13 V5). Default 'active' — the editor
 *  normally shows the live world; switch to 'inactive'/'all' to see + reactivate inactive entities. */
export type WorldEntityStatusFilter = 'active' | 'inactive' | 'all'

/** The ordered lifecycle-selector options (ONE authority). */
export const WORLD_ENTITY_STATUS_FILTERS: readonly WorldEntityStatusFilter[] = ['active', 'inactive', 'all']

/** The default filter — 'active' (the live world), NOT 'all'. */
export const DEFAULT_WORLD_ENTITY_STATUS_FILTER: WorldEntityStatusFilter = 'active'

/** Human labels for the filter selector (ONE authority). */
export const WORLD_ENTITY_STATUS_LABELS: Record<WorldEntityStatusFilter, string> = {
  active: 'Active',
  inactive: 'Inactive',
  all: 'All',
}

/** The filter's input view state: which layers are visible + the lifecycle narrow. `visibleLayers`
 *  REUSES the shell's existing `visible: Set<LayerId>` — the one layer-visibility authority. */
export interface WorldEditorFilterState {
  readonly visibleLayers: ReadonlySet<LayerId>
  readonly status: WorldEntityStatusFilter
}

/** Does one item pass the lifecycle narrow? 'active' → only active; 'inactive' → only inactive; 'all'
 *  → everything. An item with NO status (should not occur for catalog-sourced items) passes ONLY under
 *  'all' — never fabricated into a lifecycle bucket. */
export function itemPassesStatus(item: LayerItem, status: WorldEntityStatusFilter): boolean {
  if (status === 'all') return true
  return item.status === status
}

/** Filter one per-layer item map by the lifecycle narrow ONLY (layer visibility untouched) — the
 *  source for per-layer counts and the search index. Preserves the input map's layer keys + order. */
export function statusFilteredByLayer(
  itemsByLayer: ReadonlyMap<LayerId, readonly LayerItem[]>,
  status: WorldEntityStatusFilter,
): Map<LayerId, LayerItem[]> {
  const out = new Map<LayerId, LayerItem[]>()
  for (const [layer, items] of itemsByLayer) {
    out.set(layer, items.filter((it) => itemPassesStatus(it, status)))
  }
  return out
}

/** The ONE map-render authority: flatten the per-layer items in REGISTRY order (locations → mining →
 *  exploration → zones), keeping only VISIBLE layers and lifecycle-passing items. The map render loop
 *  consumes this exact list. Pure: never mutates `itemsByLayer` or any item. */
export function filterVisibleItems(
  itemsByLayer: ReadonlyMap<LayerId, readonly LayerItem[]>,
  filter: WorldEditorFilterState,
): LayerItem[] {
  const out: LayerItem[] = []
  for (const { adapter } of WORLD_EDITOR_LAYERS) {
    if (!filter.visibleLayers.has(adapter.id)) continue
    for (const it of itemsByLayer.get(adapter.id) ?? []) {
      if (itemPassesStatus(it, filter.status)) out.push(it)
    }
  }
  return out
}
