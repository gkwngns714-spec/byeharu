import { supabase } from '../../lib/supabase'

// Phase 10B — READ-ONLY main-ship expedition preview. These calls never write game state.
// They feed a preview panel only; the real send path (Phase 9B) is unchanged.

export interface SupportCraftType {
  support_craft_type_id: string
  name: string
  role: string
  capacity_cost: number
  activity_tags: string[]
}

export interface PreviewStats {
  support_capacity_used: number
  support_capacity_limit: number
  speed: number
  cargo_capacity: number
  combat_power: number
  survival: number
  retreat_safety: number
  scouting: number
  mining_yield: number
  repair: number
  pirate_attention: number
  warnings: string[]
}

export interface ExpeditionPreview {
  has_ship: boolean
  valid?: boolean
  ship?: { name: string; status: string; hp: number; max_hp: number; support_capacity: number; cargo_capacity: number; captain_slots: number; module_slots: number }
  stats?: PreviewStats
  error?: string
  hull?: { name: string; base_hp: number; base_speed: number; base_cargo_capacity: number; base_support_capacity: number; base_captain_slots: number; base_module_slots: number }
}

export type LoadoutEntry = { support_craft_type_id: string; quantity: number }

/** Public-read catalog of capacity-limited support craft (Phase 6 metadata). */
export async function fetchSupportCraftTypes(): Promise<SupportCraftType[]> {
  const { data, error } = await supabase
    .from('support_craft_types')
    .select('support_craft_type_id, name, role, capacity_cost, activity_tags')
    .order('capacity_cost', { ascending: true })
  if (error) throw new Error(error.message)
  return (data as SupportCraftType[]) ?? []
}

/** Read-only preview of the caller's main ship + loadout for an activity. No writes. */
export async function fetchExpeditionPreview(loadout: LoadoutEntry[], activity: string): Promise<ExpeditionPreview> {
  const { data, error } = await supabase.rpc('get_my_expedition_preview', { p_loadout: loadout, p_activity_type: activity })
  if (error) throw new Error(error.message)
  return data as ExpeditionPreview
}
