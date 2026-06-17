import type { UnitType } from '../../lib/catalog'

// M7 — client-side PREVIEW math for training cost + ETA. Mirrors the server formula
// in train_units but is NOT authoritative — the server decides the real cost/time.

export function previewMetalCost(unit: UnitType | undefined, quantity: number): number {
  if (!unit || quantity <= 0) return 0
  return unit.metal_cost * quantity
}

// Mirrors: greatest(min_build_seconds, build_time_seconds * qty * build_time_scale).
export function previewBuildSeconds(
  unit: UnitType | undefined,
  quantity: number,
  config: Record<string, number>,
): number {
  if (!unit || quantity <= 0) return 0
  const scale = config['build_time_scale'] ?? 1.0
  const minSecs = config['min_build_seconds'] ?? 5
  return Math.max(minSecs, unit.build_time_seconds * quantity * scale)
}
