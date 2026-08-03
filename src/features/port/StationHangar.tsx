import { useCallback, useState } from 'react'
import { hasStore, type DockedStore, type StoreItem } from '../map/dockStore'
import { Button, Card, Meter, Notice, SectionLabel, StatRow } from '../../components/ui'
import { ItemGlyph, ItemTile, itemLabel } from '../../components/items'
import { useActivityPanelGuards, runGuardedCommand } from '../../lib/useActivityPanelGuards'
import { useHold } from '../inventory/useHold'
import { transferItems, type TransferDirection } from '../inventory/holdApi'
import { transferReasonMessage } from '../inventory/transferReasonMessage'
import {
  formatM3,
  holdEntries,
  holdMeter,
  maxUnitsThatFit,
  normalizeMoveQty,
  stackFits,
  type HoldItem,
} from '../inventory/hold'

// STATION-STORAGE + ITEMS-HAVE-A-PLACE (0333) — the docked-port STORAGE surface, and the one place
// the player moves items between the ship's HOLD and THIS PORT's storage.
//
// The owner's laws, made visible here: storage is PER-PORT ("what you see belongs to THIS port
// only"), it is reachable ONLY while docked (this card exists only in the docked branch, and the
// server derives the port from the ship's dock — the client cannot name one), and the hold has a
// VOLUME CAP that is shown, always, because a cap the player cannot see is a trap.
//
// ONE CARD, NOT TWO. The port's stock and the hold sit in the same card because the verb is a move
// BETWEEN them; a second panel for "your hold" would put the two halves of one action on two
// surfaces. Resources and Garrison keep their existing rows untouched below.
//
// Nothing here computes a volume, an occupancy or a capacity: every m³ number comes from the
// server (get_my_hold / get_my_docked_store, both fed by hold_used_m3 / hold_capacity_m3 /
// item_types.volume_m3). stackFits is a display precheck over those server numbers — the server
// REFUSES an over-capacity move (hold_over_capacity) and that refusal is the enforcement.

// Resource labels/glyphs come from the ONE item-visual catalog (components/items) — metal/energy
// resolve as resources, crystal as the item_types material; unknown codes degrade to title-case.
const UNIT_LABELS: Record<string, string> = {
  scout: 'Scouts',
  corvette: 'Corvettes',
  frigate: 'Frigates',
}
const titleCase = (s: string): string => s.charAt(0).toUpperCase() + s.slice(1).replace(/_/g, ' ')

/** One movable row: a glyph, a name, what it weighs, and the mover when it is the open one. */
function MoveRow({
  testId,
  itemId,
  quantity,
  volumeM3,
  actionLabel,
  open,
  onToggle,
  onMove,
  pending,
  disabledReason,
  suggestedQty,
}: {
  testId: string
  itemId: string
  quantity: number
  volumeM3: number
  actionLabel: string
  open: boolean
  onToggle: () => void
  onMove: (qty: number) => void
  pending: boolean
  /** Non-null → the move cannot be made; the row says why instead of offering a dead button. */
  disabledReason: string | null
  /** What the input starts at when the row opens (all of it, or all that fits). */
  suggestedQty: number
}) {
  const [raw, setRaw] = useState<string>(String(suggestedQty > 0 ? suggestedQty : 1))
  const qty = normalizeMoveQty(raw, quantity)

  return (
    <div data-testid={testId} className="rounded-lg border border-edge bg-surface-2/40">
      <button
        type="button"
        onClick={onToggle}
        aria-expanded={open}
        className="flex w-full items-center gap-2 px-2 py-1.5 text-left hover:bg-surface-2"
      >
        <ItemGlyph id={itemId} kind="item" />
        <span className="min-w-0 flex-1 truncate text-sm text-ink">{itemLabel(itemId, 'item')}</span>
        <span className="shrink-0 font-mono text-sm text-ink">{quantity.toLocaleString()}</span>
        <span className="shrink-0 font-mono text-[10px] text-ink-faint">
          {formatM3(volumeM3 * quantity)} m³
        </span>
      </button>

      {open && (
        <div className="border-t border-edge px-2 py-2">
          {disabledReason ? (
            <p data-testid={`${testId}-blocked`} className="text-xs text-ink-muted">
              {disabledReason}
            </p>
          ) : (
            <div className="flex items-center gap-2">
              <label className="sr-only" htmlFor={`${testId}-qty`}>
                How many to move
              </label>
              <input
                id={`${testId}-qty`}
                data-testid={`${testId}-qty`}
                type="number"
                min={1}
                max={quantity}
                step={1}
                value={raw}
                onChange={(e) => setRaw(e.target.value)}
                className="w-20 rounded border border-edge bg-app px-2 py-1 font-mono text-sm text-ink"
              />
              <Button
                data-testid={`${testId}-move`}
                size="sm"
                variant="primary"
                busy={pending}
                disabled={pending || qty === null}
                onClick={() => qty !== null && onMove(qty)}
              >
                {actionLabel}
              </Button>
              <span className="font-mono text-[10px] text-ink-faint">
                {qty !== null ? `${formatM3(qty * volumeM3)} m³` : '—'}
              </span>
            </div>
          )}
        </div>
      )}
    </div>
  )
}

export function StationHangar({
  store,
  mainShipId,
  refreshKey,
  onChanged,
}: {
  store: DockedStore
  /** The CHOSEN ship — the same one the store read resolved through. */
  mainShipId: string | null
  /** Bumped by the screen on every lifecycle/port change; also re-reads the hold. */
  refreshKey: string
  /** Called after a successful move so the screen re-reads THIS port's storage. */
  onChanged: () => void
}) {
  const hold = useHold(refreshKey)
  const guards = useActivityPanelGuards()
  const [openRow, setOpenRow] = useState<string | null>(null)
  const [pending, setPending] = useState<Record<string, boolean>>({})
  const [note, setNote] = useState<string | null>(null)

  const move = useCallback(
    async (direction: TransferDirection, itemId: string, qty: number) => {
      const key = `${direction}:${itemId}`
      await runGuardedCommand({
        key,
        guards,
        setPending: (on) => setPending((p) => ({ ...p, [key]: on })),
        setNote,
        exec: () => transferItems(mainShipId, direction, itemId, qty, crypto.randomUUID()),
        successNote: (res) =>
          res.direction === 'to_storage'
            ? `Stored ${res.qty} × ${itemLabel(res.item_id, 'item')}.`
            : `Loaded ${res.qty} × ${itemLabel(res.item_id, 'item')} into the hold.`,
        // The server's reason, in plain words. Over-capacity also says how much room is left,
        // because "won't fit" without a number is the trap this whole slice removes.
        errorNote: (res) =>
          res.reason === 'hold_over_capacity' && typeof res.hold_free_m3 === 'number'
            ? `${transferReasonMessage(res.reason)} ${formatM3(res.hold_free_m3)} m³ free.`
            : transferReasonMessage(res.reason ?? 'unavailable'),
        refresh: async () => {
          setOpenRow(null)
          onChanged()
        },
      })
    },
    [guards, mainShipId, onChanged],
  )

  // Not docked at a storable port (in transit / in space / dark / storeless) → nothing.
  if (!hasStore(store)) return null

  const meter = holdMeter(hold)
  const carried: HoldItem[] = holdEntries(hold)
  const stored: StoreItem[] = store.items.filter((i) => i.quantity > 0)
  const nothingStored = store.resources.length === 0 && store.units.length === 0 && stored.length === 0

  return (
    <Card data-testid="station-hangar">
      {/* 1 · IDENTITY — this port's own store */}
      <div className="flex items-start justify-between gap-3">
        <div>
          {/* PLAIN-WORDS: "Hangar" → "Storage" — what a typical game calls per-town item storage. */}
          <h2 className="text-lg font-semibold text-ink">Storage</h2>
          <p className="mt-0.5 text-sm text-ink-muted">
            Stored at {store.locationName ?? 'this port'} — assets stay here until you move them.
          </p>
        </div>
        <p className="text-2xl" aria-hidden>📦</p>
      </div>

      {/* 2 · THE HOLD — how full the ship is, always visible. A cap you cannot see is a trap. */}
      <div data-testid="hold-capacity" className="mt-4 rounded-lg border border-edge bg-surface-2/40 p-2">
        <div className="flex items-baseline justify-between gap-2">
          <SectionLabel className="mb-0">Hold</SectionLabel>
          <span data-testid="hold-capacity-label" className="font-mono text-xs text-ink">
            {meter.label}
          </span>
        </div>
        <Meter className="mt-1.5" pct={meter.pct} tone={meter.tone} />
        {hold.capacityM3 === 0 && (
          <p data-testid="hold-no-capacity" className="mt-1.5 text-[11px] text-ink-muted">
            You own no ship, so there is nothing to carry with. You can still put what you hold into
            storage.
          </p>
        )}
        {hold.overCapacity && hold.capacityM3 > 0 && (
          <p data-testid="hold-over-capacity" className="mt-1.5 text-[11px] text-warning">
            Your hold is over capacity. You can move items into storage, but not out, until it fits.
          </p>
        )}
      </div>

      {note && (
        <Notice data-testid="station-hangar-note" className="mt-2" tone="neutral">
          {note}
        </Notice>
      )}

      {/* 3 · MOVE — carried items out to this port, stored items in to the hold. */}
      <SectionLabel className="mt-4">Carrying</SectionLabel>
      {carried.length === 0 ? (
        <p data-testid="hold-empty" className="mt-1 text-sm text-ink-faint">
          Your hold is empty.
        </p>
      ) : (
        <div data-testid="hold-items" className="mt-1 space-y-1.5">
          {carried.map((i) => (
            <MoveRow
              // Quantity is in the key on purpose: the mover's prefill is initial state, so the
              // row must REMOUNT when the stack behind it changes or a stale default would linger.
              key={`hold-${i.itemId}-${i.quantity}`}
              testId={`hold-item-${i.itemId}`}
              itemId={i.itemId}
              quantity={i.quantity}
              volumeM3={i.volumeM3}
              actionLabel="Move to storage"
              open={openRow === `to_storage:${i.itemId}`}
              onToggle={() =>
                setOpenRow((cur) => (cur === `to_storage:${i.itemId}` ? null : `to_storage:${i.itemId}`))
              }
              onMove={(qty) => void move('to_storage', i.itemId, qty)}
              pending={pending[`to_storage:${i.itemId}`] === true}
              // Unloading is ALWAYS available: it only ever reduces the hold's load, so it is the
              // way out for a player who is over capacity.
              disabledReason={null}
              suggestedQty={i.quantity}
            />
          ))}
        </div>
      )}

      <SectionLabel className="mt-4">Items stored here</SectionLabel>
      {stored.length === 0 ? (
        <p data-testid="station-hangar-items-empty" className="mt-1 text-sm text-ink-faint">
          No items stored at this port.
        </p>
      ) : (
        <div data-testid="station-hangar-items" className="mt-1 space-y-1.5">
          {stored.map((i) => (
            <MoveRow
              key={`store-${i.itemId}-${i.quantity}-${hold.usedM3}`}
              testId={`store-item-${i.itemId}`}
              itemId={i.itemId}
              quantity={i.quantity}
              volumeM3={i.volumeM3}
              actionLabel="Move to hold"
              open={openRow === `to_hold:${i.itemId}`}
              onToggle={() =>
                setOpenRow((cur) => (cur === `to_hold:${i.itemId}` ? null : `to_hold:${i.itemId}`))
              }
              onMove={(qty) => void move('to_hold', i.itemId, qty)}
              pending={pending[`to_hold:${i.itemId}`] === true}
              disabledReason={
                stackFits(hold, i.volumeM3, 1)
                  ? null
                  : hold.capacityM3 === 0
                    ? 'You need a ship to carry this.'
                    : `Your hold is full — ${formatM3(hold.freeM3)} m³ free, and one of these needs ${formatM3(i.volumeM3)} m³.`
              }
              suggestedQty={maxUnitsThatFit(hold, i.volumeM3, i.quantity)}
            />
          ))}
        </div>
      )}

      {/* 4 · DETAILS — the port's resources then units, plain-language rows (unchanged) */}
      {nothingStored ? (
        <p data-testid="station-hangar-empty" className="mt-4 text-sm text-ink-faint">
          Nothing stored here yet.
        </p>
      ) : (
        <>
          {store.resources.length > 0 && (
            <>
              <SectionLabel className="mt-4">Resources</SectionLabel>
              {/* ITEM-VIZ: stored resources as ItemTiles (glyph in a tinted square + name + mono
                  qty) — the grid-density "tablet" replaces the plain label/value rows. Testids
                  unchanged: station-hangar-resources + station-hangar-resource-<code>. */}
              <div data-testid="station-hangar-resources" className="mt-2 grid grid-cols-2 gap-2 sm:grid-cols-3">
                {store.resources.map((r) => (
                  <ItemTile
                    key={r.resourceCode}
                    data-testid={`station-hangar-resource-${r.resourceCode}`}
                    id={r.resourceCode}
                    kind="resource"
                    qty={Math.round(r.amount)}
                  />
                ))}
              </div>
            </>
          )}
          {store.units.length > 0 && (
            <>
              <SectionLabel className="mt-4">Garrison</SectionLabel>
              <dl data-testid="station-hangar-units" className="mt-2 space-y-1.5 text-sm">
                {store.units.map((u) => (
                  <StatRow
                    key={u.unitTypeId}
                    data-testid={`station-hangar-unit-${u.unitTypeId}`}
                    label={UNIT_LABELS[u.unitTypeId] ?? titleCase(u.unitTypeId)}
                    value={u.quantity.toLocaleString()}
                  />
                ))}
              </dl>
            </>
          )}
        </>
      )}
    </Card>
  )
}
