import type { UnitType } from '../../lib/catalog'

// M7/M4.5 — client-side PREVIEW math for training cost + time. Build times come from
// unit_types.build_time_seconds + game_config (no hardcoded values). Not authoritative
// — the server decides the real cost/time.

export function previewMetalCost(unit: UnitType | undefined, quantity: number): number {
  if (!unit || quantity <= 0) return 0
  return unit.metal_cost * quantity
}

// Time for ONE ship of this type (build_time_seconds × build_time_scale).
export function perShipBuildSeconds(unit: UnitType | undefined, config: Record<string, number>): number {
  if (!unit) return 0
  return unit.build_time_seconds * (config['build_time_scale'] ?? 1.0)
}

// Total order time. Mirrors server: greatest(min_build_seconds, perShip × qty).
export function previewBuildSeconds(
  unit: UnitType | undefined,
  quantity: number,
  config: Record<string, number>,
): number {
  if (!unit || quantity <= 0) return 0
  const minSecs = config['min_build_seconds'] ?? 5
  return Math.max(minSecs, perShipBuildSeconds(unit, config) * quantity)
}
