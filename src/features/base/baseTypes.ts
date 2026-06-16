// Base system — client-side row types (read-only mirror of server state).

export interface Base {
  id: string
  player_id: string
  name: string
  sector_id: string | null
  x: number
  y: number
  status: string
  created_at: string
}

export interface BaseUnit {
  id: string
  base_id: string
  unit_type_id: string
  quantity: number
}

export interface BaseResource {
  id: string
  base_id: string
  resource_code: string
  amount: number
}
