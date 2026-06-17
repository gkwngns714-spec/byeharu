// M7 — Training (ship production) client row types (read-only mirror). The server
// is authoritative; the client only requests training via the train_units RPC and
// reads its own build_orders. Player-facing wording is "Training".

export type BuildOrderStatus = 'waiting' | 'active' | 'completed' | 'cancelled'

export interface BuildOrder {
  id: string
  base_id: string
  unit_type_id: string
  quantity: number
  metal_spent: number
  status: BuildOrderStatus
  queued_at: string
  started_at: string | null
  complete_at: string | null
  resolved_at: string | null
}
