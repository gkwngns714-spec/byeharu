// PIRATE INTERCEPT (prototype) — thin, normalize-don't-throw RPC wrappers over the server slice
// (supabase/migrations/20260618000225_pirate_intercept_danger_zones.sql). Every RPC here is DARK
// behind pirate_intercept_enabled and rejects-before-read while dark, so wiring these wrappers
// changes nothing until the flag is lit. Mirrors the teamApi.ts style verbatim: transport error →
// {ok:false, reason:'unavailable'}, server is the SOLE authority, thin pass-through otherwise.
import { supabase } from '../../lib/supabase'

export type PirateRpcResult = { ok: true; [k: string]: unknown } | { ok: false; reason: string }

// ── get_danger_zones (read) — plain [x,y] vertex rings, never a PostGIS wire type. ──────────────────
export interface DangerZoneLite {
  id: string
  name: string
  source: 'circle' | 'drawn'
  location_id: string | null
  /** Ordered, ALREADY-CLOSED ring (first point repeats as the last) — the exterior boundary as
   *  plain world-unit [x,y] pairs, straight from ST_DumpPoints(ST_ExteriorRing(...)). */
  ring: [number, number][] | null
}

export async function fetchDangerZones(): Promise<DangerZoneLite[]> {
  const { data, error } = await supabase.rpc('get_danger_zones')
  if (error || !Array.isArray(data)) return []
  return data as DangerZoneLite[]
}

// The route target shape shared by the route write wrappers below. (The read-only advisory
// `previewPirateRoute` + its RoutePreviewResult/RoutePreviewLeg types were removed with the
// clean-map redesign — the client no longer shows a route risk-preview; the server RPC
// `pirate_intercept_preview_route` still exists but has no client caller.)
export interface RouteTarget {
  waypoints: { x: number; y: number }[]
  targetLocationId?: string | null
  targetX?: number | null
  targetY?: number | null
}

// ── command_ship_group_go_route (write) — composes command_ship_group_go for leg 1, queues the rest. ──
export async function commandShipGroupGoRoute(groupId: string, route: RouteTarget): Promise<PirateRpcResult> {
  const { data, error } = await supabase.rpc('command_ship_group_go_route', {
    p_group_id: groupId,
    p_waypoints: route.waypoints,
    p_target_location_id: route.targetLocationId ?? null,
    p_target_x: route.targetX ?? null,
    p_target_y: route.targetY ?? null,
  })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as PirateRpcResult
}

// ── command_ship_group_cancel_route (write) — clears any queued waypoints for the group's fleet. ──────
export async function commandShipGroupCancelRoute(groupId: string): Promise<PirateRpcResult> {
  const { data, error } = await supabase.rpc('command_ship_group_cancel_route', { p_group_id: groupId })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as PirateRpcResult
}

// ── pirate_zone_create / pirate_zone_delete (write) — the draw-editor's save/delete. ───────────────────
export async function pirateZoneCreate(
  name: string,
  vertices: [number, number][],
  locationId?: string | null,
): Promise<PirateRpcResult> {
  const { data, error } = await supabase.rpc('pirate_zone_create', {
    p_name: name,
    p_vertices: vertices,
    p_location_id: locationId ?? null,
  })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as PirateRpcResult
}

export async function pirateZoneDelete(zoneId: string): Promise<PirateRpcResult> {
  const { data, error } = await supabase.rpc('pirate_zone_delete', { p_zone_id: zoneId })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as PirateRpcResult
}
