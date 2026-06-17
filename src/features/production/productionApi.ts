import { supabase } from '../../lib/supabase'
import type { BuildOrder } from './productionTypes'

// M7 — Training client API. The only mutation is the train_units RPC; the server
// validates ownership/unit/quantity/metal and queues the order. Reads are owner-RLS.

export async function fetchBuildOrders(): Promise<BuildOrder[]> {
  const { data, error } = await supabase
    .from('build_orders')
    .select('id, base_id, unit_type_id, quantity, metal_spent, status, queued_at, started_at, complete_at, resolved_at')
    .order('queued_at', { ascending: true })
  if (error) throw new Error(error.message)
  return (data as BuildOrder[]) ?? []
}

// M4.5 — cancel a waiting/active training order (server-authoritative; validates
// ownership + status, refunds metal, and starts the next waiting item).
export async function cancelBuildOrder(orderId: string): Promise<void> {
  const { error } = await supabase.rpc('cancel_build_order', { p_order: orderId })
  if (error) throw new Error(error.message)
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
