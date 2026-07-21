// LOCATION → ENCOUNTER BINDINGS (0259) — the ONE READ-ONLY adapter. Mirrors the fleetEncounterAdapters.ts
// read/inspect shape: it READS the binding rows from the shared snapshot, RESOLVES each to a typed list
// item, and INSPECTS one row into typed authoring fields. It implements NOTHING ELSE — no
// create/edit/publish/enable/disable (deferred authoring ops are explicit + absent, never simulated).
// Every inspector field is grounded in a REAL column locationEncounterBindingData.ts returns; nothing is
// invented.
//
// WHY A REGISTRY-SPECIFIC ADAPTER SHAPE (not the map's ReadOnlyLayerAdapter/LayerItem): a binding is a
// CATALOG row, not a map feature — it has NO world coordinate of its own (it references a location by id,
// but carries no x/y), so the map contract's mandatory `representation` (point/polygon/circle) + LayerId
// would have to be FABRICATED. The "no fabricated field" law forbids that, so this adapter exposes the
// SAME pure read/inspect surface over a coordinate-free item, identical in shape to the E0/E1 adapters.
//
// PURE: no React/DOM/fetch/supabase — every read/inspect is a pure function unit-tested directly
// (tests/locationEncounterBindingAdapters.spec.ts). The table is DARK; this READS only.
import type { InspectorField } from './worldEditorTypes'
import type {
  LocationEncounterBindingData,
  LocationEncounterBindingRow,
} from './locationEncounterBindingData'

/** One selectable binding row, as the adapter resolves it (coordinate-free — a catalog row, §above). */
export interface LocationEncounterBindingItem {
  readonly registry: 'location_encounter_bindings'
  /** the stable binding UUID (the RPC target_id addresses update/set_active by this). */
  readonly id: string
  readonly label: string
  /** false ⇒ the row was soft-disabled via set_active (it survives; it is not deleted). */
  readonly active: boolean
}

/** The READ-ONLY adapter contract (the fleetEncounterAdapters.ts RegistryReadAdapter shape). NOTE the
 *  ABSENCE of any create/edit/publish/enable/disable method: that absence IS the read-only guarantee —
 *  authoring is the owner-gated 0259 RPC surface, never here. */
export interface RegistryReadAdapter<TSource> {
  readonly id: 'location_encounter_bindings'
  readonly title: string
  readItems(source: TSource): LocationEncounterBindingItem[]
  inspect(source: TSource, itemId: string): InspectorField[] | null
}

export const locationEncounterBindingLayerAdapter: RegistryReadAdapter<LocationEncounterBindingData> = {
  id: 'location_encounter_bindings',
  title: 'Location Encounter Bindings',
  readItems(source) {
    return source.bindings.map(
      (b: LocationEncounterBindingRow): LocationEncounterBindingItem => ({
        registry: 'location_encounter_bindings',
        id: b.id,
        // coordinate-free catalog row: the honest label is the binding's own address (location ↔ encounter).
        label: `${b.location_id} → ${b.encounter_profile_id}`,
        active: b.active,
      }),
    )
  },
  inspect(source, itemId) {
    const b = source.bindings.find((x) => x.id === itemId)
    if (!b) return null
    return [
      { label: 'Location', value: b.location_id },
      { label: 'Encounter profile', value: b.encounter_profile_id },
      { label: 'Weight', value: String(b.weight) },
      { label: 'Active', value: b.active ? 'yes' : 'no' },
      { label: 'Revision', value: String(b.revision) },
      { label: 'Notes', value: b.notes ?? '—' },
    ]
  },
}
