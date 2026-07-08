// STATION-STORAGE — PURE, framework-free parsing of the docked-port hangar (get_my_docked_store()).
//
// No React/DOM/fetch here. Owns (1) the typed shape of the server store projection; (2) a strict validator
// that accepts ONLY a genuine docked store and treats anything else (dark 'disabled', not docked, malformed)
// as EMPTY (never throws, never invents a store). Mirrors dockServices.ts so the hangar reads by the same
// fail-closed discipline as the rest of the port surface.

export interface StoreResource {
  resourceCode: string
  amount: number
}
export interface StoreUnit {
  unitTypeId: string
  quantity: number
}
export interface DockedStore {
  docked: boolean
  locationId: string | null
  locationName: string | null
  storeId: string | null
  resources: StoreResource[]
  units: StoreUnit[]
}

// Safe default for loading / error / dark / non-docked / malformed: nothing renders.
export const DOCK_STORE_EMPTY: DockedStore = {
  docked: false, locationId: null, locationName: null, storeId: null, resources: [], units: [],
}

function parseResource(raw: unknown): StoreResource[] {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return []
  const o = raw as Record<string, unknown>
  const code = typeof o.resource_code === 'string' && o.resource_code.length > 0 ? o.resource_code : null
  const amount = typeof o.amount === 'number' && Number.isFinite(o.amount) ? o.amount : null
  return code !== null && amount !== null ? [{ resourceCode: code, amount }] : []
}

function parseUnit(raw: unknown): StoreUnit[] {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return []
  const o = raw as Record<string, unknown>
  const id = typeof o.unit_type_id === 'string' && o.unit_type_id.length > 0 ? o.unit_type_id : null
  const qty = typeof o.quantity === 'number' && Number.isFinite(o.quantity) ? o.quantity : null
  return id !== null && qty !== null ? [{ unitTypeId: id, quantity: qty }] : []
}

/**
 * Strict validator for the raw get_my_docked_store() jsonb. Returns a sanitized DockedStore, or the empty
 * default for ANY non-docked / dark / malformed shape. Only a genuine at_location + docked payload with a real
 * location carries a hangar; a storeless docked port (store_id null) is still surfaced but with no assets.
 */
export function parseDockedStore(raw: unknown): DockedStore {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return DOCK_STORE_EMPTY
  const o = raw as Record<string, unknown>
  if (o.state !== 'at_location' || o.docked !== true) return DOCK_STORE_EMPTY
  const locationId = typeof o.location_id === 'string' && o.location_id.length > 0 ? o.location_id : null
  if (!locationId) return DOCK_STORE_EMPTY // docked with no real port → fail-safe empty
  const locationName = typeof o.location_name === 'string' ? o.location_name : null
  const storeId = typeof o.store_id === 'string' && o.store_id.length > 0 ? o.store_id : null
  const resources = Array.isArray(o.resources) ? o.resources.flatMap(parseResource) : []
  const units = Array.isArray(o.units) ? o.units.flatMap(parseUnit) : []
  return { docked: true, locationId, locationName, storeId, resources, units }
}

/** Render gate: the ship is docked at a storable port (has a materialized store). */
export function hasStore(s: DockedStore): boolean {
  return s.docked && s.storeId !== null
}
