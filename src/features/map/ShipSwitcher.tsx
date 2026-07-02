import type { SelectableShip } from './useMainShipSelection'
import { mainShipInstanceStatusLabel } from './mainshipStatusLabel'

// TRADE-UI-1 — DARK ship-switcher (SELECTION ONLY, no trade actions). Renders one entry per owned main ship
// (name + status label + cargo capacity) and lets the player choose which ship the trade surface addresses,
// by calling selectShip(id). It owns NO server truth: selection is client display state (useMainShipSelection),
// and every per-ship RPC still passes the chosen id explicitly + is server-validated. Mounted only behind the
// TRADE_MARKET_ENABLED gate (GalaxyMapScreen), so nothing renders while the trade surface is dark.
//
// N-ready but dark-single-ship-graceful: today every player has exactly one ship, so the sole ship renders as a
// non-interactive already-selected entry (no pointless picker). The moment the add-ship capability flips on and
// a second ship exists, the SAME code path renders selectable buttons — no structural change needed.

function ShipMeta({ ship }: { ship: SelectableShip }) {
  return (
    <>
      <span className="truncate font-medium">{ship.name}</span>
      <span className="ml-2 shrink-0 text-[10px] text-slate-400">
        {mainShipInstanceStatusLabel(ship.status)} · {ship.cargo_capacity_m3.toFixed(0)} m³
      </span>
    </>
  )
}

export function ShipSwitcher({
  ships,
  selectedShipId,
  selectShip,
}: {
  ships: SelectableShip[]
  selectedShipId: string | null
  selectShip: (id: string) => void
}) {
  if (ships.length === 0) return null // no ship → render nothing (fail closed)

  // Dark single-ship reality: the one ship is always the selection; render it as a non-interactive sole entry
  // (no picker) rather than a lone button that does nothing. Kept on the SAME markup as the N-ship case.
  const soleShip = ships.length === 1 ? ships[0] : null

  return (
    <div
      data-testid="ship-switcher"
      className="mt-3 rounded-xl border border-amber-400/20 bg-amber-500/5 p-4 text-sm text-slate-200"
    >
      <h3 className="mb-2 font-medium">🚀 Ships</h3>
      {soleShip ? (
        <div
          data-testid={`ship-entry-${soleShip.main_ship_id}`}
          aria-current="true"
          className="flex items-center justify-between rounded bg-amber-600/70 px-2 py-1 text-left text-xs text-white"
        >
          <ShipMeta ship={soleShip} />
        </div>
      ) : (
        <ul data-testid="ship-switcher-list" className="flex flex-col gap-1">
          {ships.map((ship) => {
            const isSel = ship.main_ship_id === selectedShipId
            return (
              <li key={ship.main_ship_id}>
                <button
                  type="button"
                  data-testid={`ship-entry-${ship.main_ship_id}`}
                  aria-current={isSel}
                  onClick={() => selectShip(ship.main_ship_id)}
                  className={`flex w-full items-center justify-between rounded px-2 py-1 text-left text-xs ${
                    isSel ? 'bg-amber-600/80 text-white' : 'bg-slate-800/80 text-slate-200 hover:bg-slate-700'
                  }`}
                >
                  <ShipMeta ship={ship} />
                </button>
              </li>
            )
          })}
        </ul>
      )}
    </div>
  )
}
