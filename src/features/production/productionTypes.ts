// M7 — Training (ship production) client row types (read-only mirror). The server
// is authoritative; the client only requests training via the train_units RPC and
// reads its own build_orders. Player-facing wording is "Training".

export type BuildOrderStatus = 'queued' | 'completed' | 'cancelled'

export interface BuildOrder {
  id: string
  base_id: string
  unit_type_id: string
  quantity: number
  metal_spent: number
  status: BuildOrderStatus
  queued_at: string
  complete_at: string
  resolved_at: string | null
}
