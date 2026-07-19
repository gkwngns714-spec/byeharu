// WORLD EDITOR — the layer registry (§WE.1 layer tree). ONE ordered list of the V1 read-only layers;
// adding a domain later = adding an adapter entry here, never forking the editor (§WE.0 compose don't
// fork). Every layer defaults visible so the foundation shows the whole world at once (§WE.13 phase 2:
// "show current locations, mining records, exploration records, and zones ALL on ONE map").
import {
  locationLayerAdapter,
  miningLayerAdapter,
  explorationLayerAdapter,
  zoneLayerAdapter,
} from './worldEditorAdapters'
import type { WorldEditorData } from './worldEditorData'
import type { LayerId, ReadOnlyLayerAdapter } from './worldEditorTypes'

export interface LayerRegistryEntry {
  readonly adapter: ReadOnlyLayerAdapter<WorldEditorData>
  readonly defaultVisible: boolean
}

/** The ordered V1 layer registry (locations → mining → exploration → zones, §WE.1). */
export const WORLD_EDITOR_LAYERS: readonly LayerRegistryEntry[] = [
  { adapter: locationLayerAdapter, defaultVisible: true },
  { adapter: miningLayerAdapter, defaultVisible: true },
  { adapter: explorationLayerAdapter, defaultVisible: true },
  { adapter: zoneLayerAdapter, defaultVisible: true },
]

/** The layer ids visible by default — the shell seeds its visibility set from this. */
export function defaultVisibleLayerIds(): Set<LayerId> {
  return new Set(WORLD_EDITOR_LAYERS.filter((e) => e.defaultVisible).map((e) => e.adapter.id))
}
