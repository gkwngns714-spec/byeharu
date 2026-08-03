import { useCallback, useEffect, useState } from 'react'
import { useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { fetchItemCatalog } from '../modules/modulesApi'
import type { ItemTypeRow } from '../modules/modulesTypes'
import { fetchMyHold } from './holdApi'
import { formatM3, holdEntries, holdMeter, HOLD_EMPTY, type Hold } from './hold'
import { Card, CardHeader, Meter, SectionLabel, Skeleton } from '../../components/ui'
import { ItemTile } from '../../components/items'

/** Title-case a bare catalog token (category/rarity) for display. */
const cap = (s: string) => s.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase())

// INVENTORY-PANEL (SHIP-DOSSIER slice) — the player's item inventory, finally VISIBLE (owner
// order: "…with inventory as well — I should be able to SEE this"). READ-ONLY: the moving is done
// at a port, in the Storage card (the hold and the port's storage sit in one place because the
// verb is a move between them).
//
// ITEMS LIVE AT PORTS (0333): this is the FLEET'S HOLD — what the selected ship's fleet is
// CARRYING — not a player-wide pool. There is no player-wide pool: items LIVE in port storage, and
// the hold is the transient thing you load at one port and unload at another. It computes no
// numbers: used/capacity/free all arrive from the server (hold_used_m3 / hold_capacity_m3), because
// a client-side copy of the capacity formula would be a second authority for "how full is my hold",
// which is the defect 0333 exists to prevent. What a PORT is holding is a different question with a
// different authority (get_my_docked_store) and a different surface (the port's Storage card).
//
// NOT server-lit gated: the hold has no feature flag — it is live player data (combat salvage
// already lands there in production), so the panel always renders. A read failure degrades to an
// honest unavailable line, never a silent empty.

export function InventoryPanel({
  // Re-reads on main-ship lifecycle transitions AND after an item-consuming command elsewhere on
  // the screen (craft/recruit — ShipScreen bumps its loadout revision into this key).
  refreshKey,
  // 0333: whose hold. The fleet is resolved server-side from this ship; null falls back to the
  // sole-ship shim.
  mainShipId,
}: {
  refreshKey: string
  mainShipId: string | null
}) {
  // null = first load pending · 'error' = read failed · Hold = the server's hold projection.
  const [hold, setHold] = useState<Hold | 'error' | null>(null)
  // The public item_types display catalog (name/category/rarity/description/stackable) — powers the
  // tap-to-info panel. null while loading / on read error → tiles stay non-interactive (no info to
  // show), never a crash: the balances grid is the always-present surface.
  const [catalog, setCatalog] = useState<ItemTypeRow[] | null>(null)
  // The item id whose info panel is open (only one at a time); tap again to collapse.
  const [openItem, setOpenItem] = useState<string | null>(null)

  // Mounted guard — the shared idiom home (read-only panel: no submit guards needed).
  const { activeRef } = useActivityPanelGuards()

  const refresh = useCallback(async () => {
    const [h, cat] = await Promise.all([fetchMyHold(mainShipId), fetchItemCatalog()])
    if (!activeRef.current) return
    // fetchMyHold is fail-closed: a transport error resolves to HOLD_EMPTY (ok:false), which is
    // indistinguishable from "signed out". Both are an honest unavailable line, never a fake empty.
    setHold(h.ok ? h : 'error')
    setCatalog(cat)
  }, [activeRef, mainShipId]) // ref identity is stable; mainShipId is a real dep — the fleet decides the hold

  // refreshKey is a deliberate re-fetch trigger (the ModulesPanel lifecycleKey dep idiom).
  useEffect(() => {
    void refresh()
  }, [refresh, refreshKey])

  const loaded = hold !== null && hold !== 'error' ? hold : null
  const entries = loaded ? holdEntries(loaded) : null
  const meter = holdMeter(loaded ?? HOLD_EMPTY)
  const byId = catalog ? new Map(catalog.map((c) => [c.item_id, c])) : null
  const toggle = (id: string) => setOpenItem((cur) => (cur === id ? null : id))
  const openInfo = openItem != null ? byId?.get(openItem) : undefined

  return (
    <Card data-testid="inventory-panel" aria-busy={hold === null || undefined}>
      <CardHeader title="Inventory" subtitle="Items you carry — crafting & recruiting materials." className="mb-2" />
      {hold === null ? (
        <>
          <Skeleton className="mt-2 h-8 w-full rounded-lg" />
          <Skeleton className="mt-2 h-8 w-2/3 rounded-lg" />
          <span className="sr-only">Checking your inventory…</span>
        </>
      ) : hold === 'error' ? (
        <p data-testid="inventory-unavailable" className="mt-2 text-sm text-ink-muted">
          Inventory unavailable right now.
        </p>
      ) : (
        <>
          {/* HOW FULL THE HOLD IS — always shown. A volume cap the player cannot see is a trap. */}
          <div data-testid="inventory-capacity" className="mt-1">
            <div className="flex items-baseline justify-between gap-2">
              <SectionLabel className="mb-0">Hold</SectionLabel>
              <span data-testid="inventory-capacity-label" className="font-mono text-xs text-ink">
                {meter.label}
              </span>
            </div>
            <Meter className="mt-1.5" pct={meter.pct} tone={meter.tone} />
            {loaded !== null && loaded.overCapacity && (
              <p data-testid="inventory-over-capacity" className="mt-1.5 text-[11px] text-warning">
                Over capacity — dock at a port and move items into storage to make room.
              </p>
            )}
          </div>

          {entries && entries.length > 0 ? (
            <>
              <div data-testid="inventory-grid" className="mt-3 grid grid-cols-2 gap-2">
                {entries.map((e) => {
                  const info = byId?.get(e.itemId)
                  return (
                    <ItemTile
                      key={e.itemId}
                      id={e.itemId}
                      kind="item"
                      qty={e.quantity}
                      label={info?.name}
                      // Tappable only when the catalog has this item's info to reveal.
                      onSelect={info ? () => toggle(e.itemId) : undefined}
                      expanded={openItem === e.itemId}
                      selected={openItem === e.itemId}
                    />
                  )
                })}
              </div>
              {openInfo && (
                <div
                  data-testid={`inventory-info-${openInfo.item_id}`}
                  className="mt-2 rounded-lg border border-edge bg-surface-2/50 px-3 py-2"
                >
                  <div className="flex items-baseline justify-between gap-2">
                    <span className="truncate text-sm text-ink">{openInfo.name}</span>
                    <span className="flex shrink-0 flex-wrap justify-end gap-1.5">
                      <span className="rounded bg-surface-2 px-1.5 py-0.5 text-[10px] text-ink-muted">
                        {cap(openInfo.category)}
                      </span>
                      <span className="rounded bg-accent/15 px-1.5 py-0.5 text-[10px] text-accent">
                        {cap(openInfo.rarity)}
                      </span>
                    </span>
                  </div>
                  {openInfo.description && (
                    <p className="mt-0.5 text-[10px] text-ink-faint">{openInfo.description}</p>
                  )}
                  <p className="mt-1 text-[10px] text-ink-muted">
                    {openInfo.stackable ? 'Stackable' : 'Not stackable'}
                    {' · '}
                    {/* The volume comes from the same server projection the cap is measured in. */}
                    {formatM3(entries.find((e) => e.itemId === openInfo.item_id)?.volumeM3 ?? 0)} m³ each
                  </p>
                </div>
              )}
            </>
          ) : (
            <p data-testid="inventory-empty" className="mt-3 text-sm text-ink-faint">
              No items yet — hunt pirates to salvage materials.
            </p>
          )}
        </>
      )}
    </Card>
  )
}
