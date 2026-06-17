// M6: shared, display-only mappings from M5 World State values to player-facing
// labels. These do NOT change server values or rebalance anything — they only
// translate read-only pressure / danger_modifier into words + colors so the map,
// location panel, and send-fleet panel all speak the same language.

import type { LocationState } from '../../features/map/mapTypes'

export type ActivityLevel = 'Calm' | 'Rising' | 'Severe'
export type DangerLevel = 'Low' | 'Medium' | 'High'

// pressure 0..100 (server-clamped): 0 calm · 50 normal · 100 severe.
export function activityFromPressure(pressure: number): { label: ActivityLevel; cls: string } {
  if (pressure < 34) return { label: 'Calm', cls: 'text-emerald-300' }
  if (pressure < 67) return { label: 'Rising', cls: 'text-amber-300' }
  return { label: 'Severe', cls: 'text-red-300' }
}

// danger_modifier ~0.95..1.20 (server-bounded; baseline pressure → exactly 1.0).
export function dangerFromModifier(mod: number): { label: DangerLevel; cls: string } {
  if (mod <= 1.0) return { label: 'Low', cls: 'text-emerald-300' }
  if (mod < 1.13) return { label: 'Medium', cls: 'text-amber-300' }
  return { label: 'High', cls: 'text-red-300' }
}

// High = either the danger modifier is in the top band OR pirate activity is Severe.
export function isHighDanger(state: LocationState | undefined): boolean {
  if (!state) return false
  return (
    dangerFromModifier(state.danger_modifier).label === 'High' ||
    activityFromPressure(state.pressure).label === 'Severe'
  )
}

export function dangerWarningText(state: LocationState | undefined): string | null {
  if (!isHighDanger(state)) return null
  return '⚠ High pirate activity here — expect heavier waves and ship losses. Retreat early to bank rewards.'
}
