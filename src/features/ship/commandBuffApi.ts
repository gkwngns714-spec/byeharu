import { supabase } from '../../lib/supabase'
import { commandBuffsEnabledFromConfig, type CommandBuffTypeRow } from './commandBuff'

// COMMAND-BUFFS (0205) — typed client API for the dossier's COMMAND BUFF line (read-only; NO command
// exists — a buff is rolled server-side at commission and is immutable). Three reads, all
// already-granted surfaces (no read RPC — the soulApi direct-select posture):
//   · the gate      — PUBLIC-READ game_config (0003 grant; the getShipTraitsConfigRows shape),
//   · the catalog   — PUBLIC-READ command_buff_types (0205 Reference/Config posture),
//   · the instance  — OWNER-READ main_ship_instances.command_buff_id (the ship-owner RLS the rest
//                     of mainshipApi already reads through).
// Fail-closed like soulApi: transport/DB error → null (the line HIDES — never a false 'no buff'
// empty), config error → [] (the strict fold reads dark).

/** Read the command-buff gate row from PUBLIC-READ game_config. Error → [] (fold reads dark). */
export async function getCommandBuffsConfigRows(): Promise<Array<{ key: string; value: unknown }>> {
  const { data, error } = await supabase
    .from('game_config')
    .select('key, value')
    .eq('key', 'command_buffs_enabled')
  if (error) return []
  return (data ?? []) as Array<{ key: string; value: unknown }>
}

/** Read the full command-buff catalog (public-read Reference/Config, 0205). Error → null. */
export async function getCommandBuffCatalog(): Promise<CommandBuffTypeRow[] | null> {
  const { data, error } = await supabase
    .from('command_buff_types')
    .select('buff_id, tier, name, description, stats_json')
    .order('buff_id')
  if (error) return null
  return (data ?? []) as CommandBuffTypeRow[]
}

/** Read ONE ship's rolled command_buff_id (owner-read RLS on main_ship_instances). Error → null;
 *  a rolled-but-null slot (unrolled ship / pool-less tier) → null too (the line hides). */
export async function getMyShipCommandBuffId(mainShipId: string): Promise<string | null> {
  const { data, error } = await supabase
    .from('main_ship_instances')
    .select('command_buff_id')
    .eq('main_ship_id', mainShipId)
    .maybeSingle()
  if (error || !data) return null
  return (data as { command_buff_id: string | null }).command_buff_id ?? null
}

/** The dossier's one command-buff read: catalog + this ship's buff id, or null (dark/error → hidden). */
export interface ShipCommandBuffData {
  catalog: CommandBuffTypeRow[]
  buffId: string | null
}

/**
 * Gate-FIRST composite read (the server's own reject-before-any-read shape, mirrored, exactly the
 * soulApi fetchShipSoul flow): one config select decides; DARK → return null having issued ZERO
 * buff reads (the dossier's dark cost is the config select alone). LIT → the catalog + the ship's
 * buff id in parallel; the catalog failing → null (hidden, never a false empty). A null buff id is
 * carried through — the view hides the line when the ship has no buff.
 */
export async function fetchShipCommandBuff(mainShipId: string): Promise<ShipCommandBuffData | null> {
  const cfgRows = await getCommandBuffsConfigRows()
  if (!commandBuffsEnabledFromConfig(cfgRows)) return null
  const [catalog, buffId] = await Promise.all([getCommandBuffCatalog(), getMyShipCommandBuffId(mainShipId)])
  if (catalog === null) return null
  return { catalog, buffId }
}
