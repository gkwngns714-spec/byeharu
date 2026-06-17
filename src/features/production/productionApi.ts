import { supabase } from '../../lib/supabase'
import type { BuildOrder } from './productionTypes'

// M7 — Training client API. The only mutation is the train_units RPC; the server
// validates ownership/unit/quantity/metal and queues the order. Reads are owner-RLS.

export async function fetchBuildOrders(): Promise<BuildOrder[]> {
  const { data, error } = await supabase
    .from('build_orders')
    .select('id, base_id, unit_type_id, quantity, metal_spent, status, queued_at, complete_at, resolved_at')
    .order('queued_at', { ascending: false })
  if (error) throw new Error(error.message)
  return (data as BuildOrder[]) ?? []
}

export async function trainUnits(baseId: string, unitTypeId: string, quantity: number): Promise<string> {
  const { data, error } = await supabase.rpc('train_units', {
    p_base: baseId,
    p_unit_type: unitTypeId,
    p_quantity: quantity,
  })
  if (error) throw new Error(error.message)
  return data as string
}
