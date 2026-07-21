// LOCATION → ENCOUNTER BINDINGS (0259) — the READ-ONLY data snapshot for the ONE net-new owner-authored
// join table (location_encounter_bindings). Mirrors fleetEncounterData.ts: it composes a SELECT-only read
// of the public-read catalog into ONE typed object the adapter reads a slice of. NO write RPC, NO
// game_config write, NO mutation. The source fails CLOSED to [] on any transport error (the mapApi.ts
// never-throw-into-render convention) — the surface renders honestly-empty rather than throwing. The
// table is DARK: authoring goes through the owner-gated 0259 RPCs behind the fail-closed TRI-FLAG chain
// (enemy_content_registry_enabled + encounter_authoring_enabled + encounter_binding_authoring_enabled);
// this module only READS the resulting rows.
//
// PURE-ish IO boundary: like fleetEncounterData.ts this is the ONE module that issues the catalog SELECT;
// the adapter (locationEncounterBindingAdapters.ts) that projects these rows into typed fields is pure.
import { supabase } from '../../lib/supabase'

/** One location_encounter_bindings row (authoring fields only; public-read catalog). The
 *  (location_id, encounter_profile_id) pair is the stable UNIQUE address; only weight/active/notes mutate. */
export interface LocationEncounterBindingRow {
  readonly id: string
  readonly location_id: string
  readonly encounter_profile_id: string
  readonly weight: number
  readonly active: boolean
  readonly revision: number
  readonly notes: string | null
}

/** The read-only snapshot the adapter reads a slice of. */
export interface LocationEncounterBindingData {
  readonly bindings: LocationEncounterBindingRow[]
}

/** SELECT-only read of location_encounter_bindings (public read, 0259). Fails CLOSED to []. */
export async function getLocationEncounterBindings(): Promise<LocationEncounterBindingRow[]> {
  const { data, error } = await supabase
    .from('location_encounter_bindings')
    .select('id, location_id, encounter_profile_id, weight, active, revision, notes')
  if (error || !Array.isArray(data)) return []
  return data as unknown as LocationEncounterBindingRow[]
}

/** Fetch the binding catalog. Read-only throughout — no argument mutates state. */
export async function fetchLocationEncounterBindingData(): Promise<LocationEncounterBindingData> {
  const bindings = await getLocationEncounterBindings()
  return { bindings }
}
