import { supabase } from '../../lib/supabase'
import type { Base } from './baseTypes'

// Base system client API — reads owner-scoped state (RLS enforces ownership) and
// the bootstrap RPC. No game logic on the client; the server owns all mutations.

/** Ensure the signed-in player has a starter base (idempotent, server-side). */
export async function ensureBase(): Promise<void> {
  const { error } = await supabase.rpc('bootstrap_me')
  if (error) throw new Error(error.message)
}

// Player has ≥1 base row (their per-port store) — used only as the Command-screen "loaded" gate now
// (the home-base resources/garrison view is gone; per-port assets are read via get_my_docked_store).
export async function fetchBase(): Promise<Base | null> {
  const { data, error } = await supabase.from('bases').select('*').limit(1).maybeSingle()
  if (error) throw new Error(error.message)
  return (data as Base) ?? null
}
