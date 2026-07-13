import { supabase } from '../../lib/supabase'
import {
  shipTraitsEnabledFromConfig,
  type MainShipTraitRow,
  type ShipTraitTypeRow,
} from './shipTraits'

// SOUL-2 — typed client API for the dossier's TRAITS section (read-only; NO command exists —
// traits are rolled server-side at commission, 0193, and are immutable, 0186). Three reads, all
// already-granted surfaces (no read RPC exists — the salvageApi direct-select posture):
//   · the gate      — PUBLIC-READ game_config (0003 grant; the getSalvageConfigRows shape),
//   · the catalog   — PUBLIC-READ ship_trait_types (0186 Reference/Config posture),
//   · the instance  — OWNER-READ main_ship_traits (0186 main_ship_traits_select_own via the
//                     owning-ship EXISTS join + grant select to authenticated).
// Fail-closed like haulApi/salvageApi: transport/DB error → null (the section HIDES — never a
// false 'no traits' empty), config error → [] (the strict fold reads dark).

/** Read the trait gate row from PUBLIC-READ game_config. Error → [] (fold reads dark). */
export async function getShipTraitsConfigRows(): Promise<Array<{ key: string; value: unknown }>> {
  const { data, error } = await supabase
    .from('game_config')
    .select('key, value')
    .eq('key', 'ship_traits_enabled')
  if (error) return []
  return (data ?? []) as Array<{ key: string; value: unknown }>
}

/** Read the full trait catalog (8 rows — public-read Reference/Config, 0186). Error → null. */
export async function getShipTraitCatalog(): Promise<ShipTraitTypeRow[] | null> {
  const { data, error } = await supabase
    .from('ship_trait_types')
    .select('trait_type_id, name, description, stats_json, hp_mult')
    .order('trait_type_id')
  if (error) return null
  return (data ?? []) as ShipTraitTypeRow[]
}

/** Read ONE ship's rolled trait rows (owner-read RLS via the ship join, 0186). Error → null. */
export async function getMyShipTraitRows(mainShipId: string): Promise<MainShipTraitRow[] | null> {
  const { data, error } = await supabase
    .from('main_ship_traits')
    .select('slot, trait_type_id')
    .eq('main_ship_id', mainShipId)
    .order('slot')
  if (error) return null
  return (data ?? []) as MainShipTraitRow[]
}

/** The dossier's one soul read: catalog + this ship's rows, or null (dark/error → hidden). */
export interface ShipSoulData {
  catalog: ShipTraitTypeRow[]
  rows: MainShipTraitRow[]
}

/**
 * Gate-FIRST composite read (the server's own reject-before-any-read shape, mirrored):
 * one config select decides; DARK → return null having issued ZERO trait reads (the dossier's
 * dark cost is the config select alone — no catalog/instance traffic pre-flip). LIT → the two
 * trait selects in parallel; either failing → null (hidden, never a false empty).
 */
export async function fetchShipSoul(mainShipId: string): Promise<ShipSoulData | null> {
  const cfgRows = await getShipTraitsConfigRows()
  if (!shipTraitsEnabledFromConfig(cfgRows)) return null
  const [catalog, rows] = await Promise.all([getShipTraitCatalog(), getMyShipTraitRows(mainShipId)])
  if (catalog === null || rows === null) return null
  return { catalog, rows }
}
