import { supabase } from '../../lib/supabase'

// ASSETS-TAB — the reads behind the ledger. Thin wrappers only; every one of them fails CLOSED to
// a value the renderer can show honestly, and none of them throws into the render path (the
// salvageApi / holdApi convention).
//
// ═══ WHY THESE ARE DIRECT SELECTS, AND WHERE THE BOUNDARY IS ═══════════════════════════════════
// Verified read-only against production 2026-08-04 (prod head 20260618000335): there is NO server
// RPC that answers "what do I own across every port" — the item RPCs are `get_my_hold` (one
// fleet's hold) and `get_my_docked_store` (the ONE port you are standing in). Both are
// deliberately narrow, because the design law is that you can only REACH a port's storage while
// docked there.
//
// SEEING is not REACHING, and this slice needs no new server surface to see: `bases` and
// `base_items` are already granted SELECT to `authenticated` and already RLS-scoped to the owner
// (`bases_select_own` → player_id = auth.uid(); `base_items_select_own` → EXISTS over that). So
// the whole ledger is a CLIENT-ONLY read. No migration, no grant change, nothing written.
//
// THE BOUNDARY vs get_my_docked_store, stated so it is not re-litigated as a second authority:
//   · `get_my_docked_store` is the state of the store you are STANDING IN. It backs the transfer
//     surface, it is what `transfer_items` validates against, and it is server-authoritative for
//     everything you may MOVE. It stays the only input to any mutation.
//   · this read is a READ-ONLY LEDGER of everywhere at once. It drives no command, gates no
//     button, and can never be the basis of a write. Nothing here computes an occupancy or a
//     capacity — those are the server's numbers and this file does not have an opinion about them.
// One authority per QUESTION: "what may I move right now" and "what do I own, everywhere" are two
// questions, and they are answered in two places on purpose.

/** One (port, item, quantity) row of the player's own per-port storage. */
export interface PortStockRow {
  baseId: string
  locationId: string
  itemId: string
  quantity: number
}

interface RawBaseRow {
  id: string
  location_id: string | null
  base_items: Array<{ item_id: string; quantity: number | string }> | null
}

/**
 * Read every item the player has in storage, at every port — `bases` ⋈ `base_items`, owner-scoped
 * by RLS (the client never passes a player id; `auth.uid()` is the filter and the server owns it).
 *
 * A base with a NULL `location_id` is DROPPED: storage is per-PORT, so a stockpile with no port is
 * not something the ledger can place or price, and inventing a city for it would be a lie. (Prod
 * 2026-08-04: zero such rows exist — every one of the 157 item-holders has a base with a port —
 * so this is a guard against a future shape, not a live filter.)
 *
 * Zero and negative quantities are dropped: a spent stack is not held.
 * Transport/DB error → null, which the screen renders as an honest unavailable line. It must NOT
 * be [] — an empty ledger and an unreadable one look identical on screen and mean opposite things.
 */
export async function fetchMyPortStock(): Promise<PortStockRow[] | null> {
  const { data, error } = await supabase
    .from('bases')
    .select('id, location_id, base_items(item_id, quantity)')
  if (error) return null
  const rows: PortStockRow[] = []
  for (const b of (data ?? []) as RawBaseRow[]) {
    if (!b.location_id) continue
    for (const it of b.base_items ?? []) {
      const quantity = Number(it.quantity)
      if (!Number.isFinite(quantity) || quantity <= 0) continue
      rows.push({ baseId: b.id, locationId: b.location_id, itemId: it.item_id, quantity })
    }
  }
  return rows
}
