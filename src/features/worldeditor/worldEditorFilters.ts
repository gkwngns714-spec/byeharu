// WORLD EDITOR — V5: the PURE layer/status VIEW filter. Items in → the filtered, flattened view out.
// This is the ONE filter authority the map render loop consumes: it SUBSUMES the shell's former inline
// `visibleItems` compute (which filtered by layer visibility ONLY) and composes the new STATUS narrow
// onto it, WITHOUT forking the renderer or adding a parallel store. Pure NAVIGATION/VIEW state: it
// NEVER mutates its inputs, writes no coordinate, reads no source row, and issues no IO — it reads only
// the adapter-resolved LayerItems the shell already holds (the SAME `itemsByLayer` map Focus/Search
// consume). No React, no DOM, no fetch: unit-tested directly (tests/worldEditorFilters.spec.ts).
//
// GROUNDED HONESTY (§WE.6–§WE.9): only LOCATIONS carry a real client-side status (locations.status ∈
// {active,locked,hidden} — LOCATION_STATUSES is the ONE authority for that domain). Mining/exploration/
// zones expose NO status column in their read contract, so their LayerItems leave `status` undefined
// and the status narrow can never match on a value that was never read — those domains ALWAYS pass a
// status filter (an honest no-op, never a fabricated status). The status vocabulary is reused from
// locationEnums, never re-declared here.
import { WORLD_EDITOR_LAYERS } from './worldEditorRegistry'
import { LOCATION_STATUSES } from './locationEnums'
import type { LayerId, LayerItem } from './worldEditorTypes'

/** The "no status narrow" sentinel — the default, and today's whole-world behavior. */
export const STATUS_FILTER_ALL = 'all' as const

/** The status-filter domain: the neutral 'all', or exactly one legal location status. */
export type StatusFilter = typeof STATUS_FILTER_ALL | (typeof LOCATION_STATUSES)[number]

/** The ordered status-selector options (ONE authority — reuses LOCATION_STATUSES). */
export const STATUS_FILTER_OPTIONS: readonly StatusFilter[] = [STATUS_FILTER_ALL, ...LOCATION_STATUSES]

/** The default status filter — 'all' preserves today's behavior (no narrow until the owner picks one). */
export const DEFAULT_STATUS_FILTER: StatusFilter = STATUS_FILTER_ALL

/** The filter's input view state: which layers are visible + the status narrow. `visibleLayers` REUSES
 *  the shell's existing `visible: Set<LayerId>` — the one layer-visibility authority — so this module
 *  adds NO second visibility store. */
export interface WorldEditorFilterState {
  readonly visibleLayers: ReadonlySet<LayerId>
  readonly status: StatusFilter
}

/** Does one item pass the status narrow? 'all' passes everything; otherwise the item passes when its
 *  status equals the chosen value. An item with NO status (a domain without a client-side status
 *  column) ALWAYS passes — the filter can't match on a value that was never read (grounded honesty). */
export function itemPassesStatus(item: LayerItem, status: StatusFilter): boolean {
  if (status === STATUS_FILTER_ALL) return true
  if (item.status === undefined) return true
  return item.status === status
}

/** The ONE filter authority: flatten the per-layer items in REGISTRY order (locations → mining →
 *  exploration → zones), keeping only VISIBLE layers and status-passing items. The map render loop
 *  consumes this exact list. Pure: never mutates `itemsByLayer` or any item. DEFAULT state (every
 *  layer visible + status 'all') reproduces the shell's former inline flatten byte-for-byte. */
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
