import { supabase } from '../../lib/supabase'
import type { Base, BaseResource, BaseUnit } from './baseTypes'

// Base system client API — reads owner-scoped state (RLS enforces ownership) and
// the bootstrap RPC. No game logic on the client; the server owns all mutations.

/** Ensure the signed-in player has a starter base (idempotent, server-side). */
export async function ensureBase(): Promise<void> {
  const { error } = await supabase.rpc('bootstrap_me')
  if (error) throw new Error(error.message)
}

export async function fetchBase(): Promise<Base | null> {
  const { data, error } = await supabase.from('bases').select('*').limit(1).maybeSingle()
  if (error) throw new Error(error.message)
  return (data as Base) ?? null
}

export async function fetchBaseUnits(baseId: string): Promise<BaseUnit[]> {
  const { data, error } = await supabase.from('base_units').select('*').eq('base_id', baseId)
  if (error) throw new Error(error.message)
  return (data as BaseUnit[]) ?? []
}

export async function fetchBaseResources(baseId: string): Promise<BaseResource[]> {
  const { data, error } = await supabase.from('base_resources').select('*').eq('base_id', baseId)
  if (error) throw new Error(error.message)
  return (data as BaseResource[]) ?? []
}
