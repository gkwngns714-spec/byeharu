import { supabase } from './supabase'
import { strictConfigFlag, type GameConfigFoldRow } from './gameConfigFold'

// Shared reference data (Reference/Config system, read-only on the client).
// Unit stats come from the server; the client mirrors them only for display/preview.

export interface UnitType {
  id: string
  name: string
  attack: number
  defense: number
  hull: number
  speed: number
  cargo: number
  power_score: number
  build_time_seconds: number
  metal_cost: number
  status: string
}

export async function fetchUnitTypes(): Promise<UnitType[]> {
  const { data, error } = await supabase
    .from('unit_types')
    .select('*')
    .eq('status', 'active')
    .order('power_score', { ascending: true })
  if (error) throw new Error(error.message)
  return (data as UnitType[]) ?? []
}

// Public read-only tunables (server is authority; client uses these for display,
// e.g. the retreat countdown length).
export async function fetchGameConfig(): Promise<Record<string, number>> {
  const { data, error } = await supabase.from('game_config').select('key, value')
  if (error) throw new Error(error.message)
  const out: Record<string, number> = {}
  for (const row of (data as Array<{ key: string; value: number }>) ?? []) {
    out[row.key] = Number(row.value)
  }
  return out
}

// Phase 10D feature gate. `game_config.value` is jsonb, so the flag comes back as a real
// boolean — read it as a boolean (NOT via the numeric fetchGameConfig above). Absent or
// unreadable → treated as OFF, so the UI falls back to today's behavior. Read only.
export async function fetchMainshipSendEnabled(): Promise<boolean> {
  const { data, error } = await supabase
    .from('game_config')
    .select('value')
    .eq('key', 'mainship_send_enabled')
    .maybeSingle()
  if (error) return false
  return (data?.value as unknown) === true
}

// NO-HOME (0199) runtime gate for launch-from-dock. Unlike the two single-flag maybeSingle reads
// above, the design REUSES the strict jsonb-true fold (strictConfigFlag, gameConfigFold.ts): fetch the
// public-read game_config rows and fold the one key. true ⇔ the row exists AND its jsonb value is
// exactly `true` (the server gates its own functions on the SAME flag via cfg_bool FIRST). Absent /
// unreadable / any non-true shape → OFF, so the UI is byte-identical to today until a human flips it.
export async function fetchLaunchFromDockEnabled(): Promise<boolean> {
  const { data, error } = await supabase.from('game_config').select('key, value')
  if (error) return false
  return strictConfigFlag((data as GameConfigFoldRow[]) ?? [], 'launch_from_dock_enabled')
}

// OSN-3 S6A feature gate for the coordinate-movement (open-space) command surface. Same safe public
// read path + boolean semantics as fetchMainshipSendEnabled above. Absent or unreadable → OFF. Read
// only. NOTE (S6A): nothing renders coordinate-command UI yet — this is a typed seed for S6B's gating;
// the production flag stays false, so this returns false in production.
export async function fetchMainshipSpaceMovementEnabled(): Promise<boolean> {
  const { data, error } = await supabase
    .from('game_config')
    .select('value')
    .eq('key', 'mainship_space_movement_enabled')
    .maybeSingle()
  if (error) return false
  return (data?.value as unknown) === true
}
