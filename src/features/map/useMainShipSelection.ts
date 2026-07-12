import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../../lib/supabase'

// TRADE-UI-1 — the client "selected ship" model. Owner-reads the player's main_ship_instances (now possibly N
// after the 0C multi-ship core) and tracks a selectedShipId, defaulting to the sole/first ship. This is what
// retires the client-side sole-ship shim: the UI addresses a CHOSEN ship and passes its id explicitly to the
// per-ship RPCs (tradeApi). Today (dark) every player has exactly one ship, so the sole ship is auto-selected;
// the model is already N-ship-ready for when the human flips the add-ship + trade gates.

export interface SelectableShip {
  main_ship_id: string
  name: string
  status: string
  cargo_capacity_m3: number // the authoritative per-ship volume capacity (numeric arrives as string → coerced)
}

interface RawShipRow {
  main_ship_id: string
  name: string
  status: string
  cargo_capacity_m3: number | string | null
}

export interface MainShipSelection {
  ships: SelectableShip[]
  selectedShipId: string | null
  selectedShip: SelectableShip | null
  selectShip: (id: string) => void
  loading: boolean
  // TEAM-ACTIVATION PREP — re-read the owner's ship list on demand (e.g. after commissioning a
  // new ship: the non-optimistic await→refetch discipline). Keeps a still-valid prior selection.
  refresh: () => Promise<void>
}

// The ONE ship-list fetch (owner-read RLS → the caller's ship(s)); shared by the mount effect and
// the on-demand refresh so the row shape/coercion is defined once. Pure IO — no React state.
async function fetchShipRows(): Promise<SelectableShip[]> {
  const { data, error } = await supabase
    .from('main_ship_instances')
    .select('main_ship_id, name, status, cargo_capacity_m3')
    .order('created_at', { ascending: true })
  if (error || !data) return []
  return (data as RawShipRow[]).map((r) => ({
    main_ship_id: r.main_ship_id,
    name: r.name,
    status: r.status,
    cargo_capacity_m3: Number(r.cargo_capacity_m3 ?? 0) || 0,
  }))
}

export function useMainShipSelection(): MainShipSelection {
  const [ships, setShips] = useState<SelectableShip[]>([])
  const [selectedShipId, setSelectedShipId] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  const applyRows = useCallback((rows: SelectableShip[]) => {
    setShips(rows)
    // default to the sole/first ship; keep a still-valid prior selection across refetches.
    setSelectedShipId((prev) =>
      prev && rows.some((s) => s.main_ship_id === prev) ? prev : (rows[0]?.main_ship_id ?? null),
    )
    setLoading(false)
  }, [])

  // Initial load: inline .then so setState lands in an async callback, not synchronously in the
  // effect body (react-hooks/set-state-in-effect — the TeamRosterPanel idiom).
  useEffect(() => {
    let active = true
    void fetchShipRows().then((rows) => {
      if (active) applyRows(rows)
    })
    return () => {
      active = false
    }
  }, [applyRows])

  // TEAM-ACTIVATION PREP — the on-demand refetch (post-commission await→refetch discipline).
  const refresh = useCallback(async () => {
    applyRows(await fetchShipRows())
  }, [applyRows])

  const selectShip = useCallback((id: string) => setSelectedShipId(id), [])
  const selectedShip = ships.find((s) => s.main_ship_id === selectedShipId) ?? null

  return { ships, selectedShipId, selectedShip, selectShip, loading, refresh }
}
