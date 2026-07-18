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

// FLEET-CONTROL (0204) runtime gate for the fleet control-model. Same strict jsonb-true fold as
// fetchLaunchFromDockEnabled (the server gates its group RPCs on the SAME flag via cfg_bool FIRST).
// true ⇔ fleet_control_enabled's row exists AND its jsonb value is exactly `true`. Absent / unreadable
// / any non-true shape → OFF, so the client is byte-identical to today until a human flips it: no
// command-ship control, no active/inactive indicator, no 8-cap surfacing, and MainShipCommand keeps
// the per-ship Move affordance. Read only.
export async function fetchFleetControlEnabled(): Promise<boolean> {
  const { data, error } = await supabase.from('game_config').select('key, value')
  if (error) return false
  return strictConfigFlag((data as GameConfigFoldRow[]) ?? [], 'fleet_control_enabled')
}

// FLEET-GO 4a-1 (charter §2 / movement unification) — the runtime gate for the UNIFIED fleet mover
// arms (command_ship_group_go / command_ship_group_stop, 0207-0209). Same strict jsonb-true fold as
// fetchLaunchFromDockEnabled / fetchFleetControlEnabled (the server gates the unified RPCs on the
// SAME flag via cfg_bool FIRST; the row exists in prod, seeded false by 0207). This MUST stay a
// RUNTIME read, never a compile constant: Pages deploys AHEAD of the approval-gated migrations
// (the teamApi.ts deploy-order law), so only a runtime read lets 4b's flag flip switch the already-
// deployed client atomically with the server. Absent / unreadable / any non-true shape → OFF
// (fail-closed): every unified arm stays dormant and the game is byte-identical to today.
export async function fetchFleetMovementUnifiedEnabled(): Promise<boolean> {
  const { data, error } = await supabase.from('game_config').select('key, value')
  if (error) return false
  return strictConfigFlag((data as GameConfigFoldRow[]) ?? [], 'fleet_movement_unified_enabled')
}

// S4 TIMED DOCKING (0219) — the runtime gate for the timed dock verb (command_ship_group_dock) and
// the mover's dockable-target translate. Same strict jsonb-true fold as the three flags above (the
// server gates BOTH sides on the SAME flag via cfg_bool FIRST; the row is seeded false by 0219).
// This MUST stay a RUNTIME read, never a compile constant (the teamApi.ts deploy-order law): Pages
// deploys ahead of the approval-gated migration, and only a runtime read lets the flag flip switch
// the already-deployed client atomically with the server. Absent / unreadable / any non-true shape
// → OFF (fail-closed): the dock row keeps submitting the instant go and the map is byte-identical.
export async function fetchTimedDockingEnabled(): Promise<boolean> {
  const { data, error } = await supabase.from('game_config').select('key, value')
  if (error) return false
  return strictConfigFlag((data as GameConfigFoldRow[]) ?? [], 'timed_docking_enabled')
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
