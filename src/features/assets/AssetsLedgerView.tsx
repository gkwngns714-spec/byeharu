import { Link } from 'react-router-dom'
import {
  NO_PRICE_HERE,
  WHY_NO_PRICE,
  formatValue,
  stackValueLabel,
  totalIsPartial,
  totalLabel,
  totalParts,
  unitPriceLabel,
  type AssetLedger,
  type Holding,
  type PlaceHoldings,
  type ValuedStack,
} from './assetLedger'
import { formatM3, holdMeter } from '../inventory/hold'
import {
  Badge,
  Card,
  CardHeader,
  EmptyState,
  Meter,
  Notice,
  PageHeader,
  Screen,
  SectionLabel,
  Skeleton,
  StatRow,
} from '../../components/ui'

// ASSETS-TAB — the RENDERED ledger, as a pure-props component.
//
// It is split from AssetsScreen (which owns the reads) for the same reason RepairPanel takes an
// injected server API: it lets tests/assetsLedger.uispec.ts drive the REAL markup across every
// price-coverage state without booting the shell, Supabase or auth. The proof that an unpriced
// stack renders as words and never as a zero has to look at the DOM, because that is where the
// defect would live.
//
// There is NO arithmetic in this file. Every number and every string comes from assetLedger.ts,
// which is the one place a value may be computed or a price may be formatted.

/** One item kind in one place, with what that place will pay — or the honest no-price line. */
function StackRow({ stack }: { stack: ValuedStack }) {
  const unpriced = stack.stackValue === null
  return (
    <div
      data-testid={`asset-stack-${stack.refId}`}
      data-unpriced={unpriced ? 'true' : 'false'}
      className="flex items-baseline justify-between gap-3 border-t border-edge/60 py-1.5 first:border-t-0"
    >
      <span className="min-w-0 flex-1 truncate text-sm text-ink">
        {stack.label}
        <span className="ml-1.5 font-mono text-xs text-ink-muted">×{formatValue(stack.quantity)}</span>
        {stack.stackM3 > 0 && (
          <span className="ml-1.5 text-[10px] text-ink-faint">{formatM3(stack.stackM3)} m³</span>
        )}
      </span>
      <span className="shrink-0 text-right">
        <span
          data-testid={`asset-stack-value-${stack.refId}`}
          className={`block font-mono text-xs ${unpriced ? 'text-ink-faint' : 'text-ink'}`}
        >
          {stackValueLabel(stack)}
        </span>
        {/* The unit price is shown only when there IS one. An unpriced stack says "No price here"
            exactly once, on the value line — repeating it would read as two separate failures. */}
        {!unpriced && (
          <span data-testid={`asset-stack-unit-${stack.refId}`} className="block text-[10px] text-ink-faint">
            {unitPriceLabel(stack)}
          </span>
        )}
      </span>
    </div>
  )
}

/** One pile in one city: the port's storage, a fleet's hold, or a ship's trade cargo. */
function HoldingBlock({ holding }: { holding: Holding }) {
  // A hold has a CAP; port storage does not. The meter runs on the SERVER'S numbers through the
  // same pure fold the retired InventoryPanel used — nothing is recomputed here, because a
  // client-side copy of the capacity formula is the second authority migration 0333 forbids.
  const meter = holding.capacity
    ? holdMeter({
        ok: true,
        items: [],
        usedM3: holding.capacity.usedM3,
        capacityM3: holding.capacity.capacityM3,
        freeM3: Math.max(holding.capacity.capacityM3 - holding.capacity.usedM3, 0),
        overCapacity: holding.capacity.overCapacity,
      })
    : null
  return (
    <div data-testid={`asset-holding-${holding.id}`} className="mt-2 first:mt-0">
      <div className="flex items-baseline justify-between gap-2">
        <SectionLabel className="mb-0">{holding.title}</SectionLabel>
        <span
          data-testid={`asset-holding-total-${holding.id}`}
          className={`font-mono text-[11px] ${
            totalIsPartial(holding.total) ? 'text-warning' : 'text-ink-muted'
          }`}
        >
          {totalLabel(holding.total)}
        </span>
      </div>
      {meter && (
        <div data-testid={`asset-holding-capacity-${holding.id}`} className="mt-1">
          <div className="flex items-baseline justify-between gap-2">
            <span className="text-[10px] text-ink-faint">Hold</span>
            <span className="font-mono text-[10px] text-ink-muted">{meter.label}</span>
          </div>
          <Meter className="mt-0.5" pct={meter.pct} tone={meter.tone} />
          {holding.capacity?.overCapacity && (
            <p data-testid={`asset-holding-over-${holding.id}`} className="mt-1 text-[10px] text-warning">
              Over capacity — dock and move items into this port’s storage to make room.
            </p>
          )}
        </div>
      )}
      <div className="mt-1">
        {holding.stacks.map((s) => (
          <StackRow key={s.refId} stack={s} />
        ))}
      </div>
    </div>
  )
}

/** Everything owned in one city — or the honest "not at a port" group, which always sorts last. */
function PlaceCard({ place }: { place: PlaceHoldings }) {
  const nowhere = place.locationId === null
  return (
    <Card data-testid={`asset-place-${place.locationId ?? 'nowhere'}`}>
      <CardHeader
        title={place.locationName}
        subtitle={
          nowhere
            ? 'In transit or in deep space — a port has to be under you before anything has a price.'
            : undefined
        }
        className="mb-1"
      />
      <div className="flex items-baseline justify-between gap-2">
        <span className="text-xs text-ink-muted">
          {place.holdings.length} {place.holdings.length === 1 ? 'pile' : 'piles'}
        </span>
        {/* The number goes in the pill; the caveat gets its own line beneath, in sentence case.
            Both come from totalParts, which hands over the caveat as a required field — so the
            layout can breathe on a 320px phone without the caveat becoming droppable. */}
        <span className="shrink-0 text-right">
          <Badge tone={totalIsPartial(place.total) ? 'warning' : 'neutral'}>
            <span data-testid={`asset-place-total-${place.locationId ?? 'nowhere'}`}>
              {totalParts(place.total).value}
            </span>
          </Badge>
          {totalParts(place.total).caveat && (
            <span
              data-testid={`asset-place-caveat-${place.locationId ?? 'nowhere'}`}
              className="mt-0.5 block text-[10px] text-warning"
            >
              {totalParts(place.total).caveat}
            </span>
          )}
        </span>
      </div>
      <div className="mt-2">
        {place.holdings.map((h) => (
          <HoldingBlock key={h.id} holding={h} />
        ))}
      </div>
    </Card>
  )
}

export interface AssetsLedgerViewProps {
  /** null = the first read is still in flight. */
  ledger: AssetLedger | null
  /** A read FAILED — say so; an unreadable ledger and an empty one mean opposite things. */
  unavailable: boolean
  /** The price catalogues could not be read: values are unknown, not zero. */
  pricesUnavailable: boolean
  shipCount: number
  fleetCount: number
  /** Already folded through the ONE null-honest wallet display helper by the caller. */
  creditsLabel: string
}

export function AssetsLedgerView({
  ledger,
  unavailable,
  pricesUnavailable,
  shipCount,
  fleetCount,
  creditsLabel,
}: AssetsLedgerViewProps) {
  return (
    <Screen>
      <PageHeader
        eyebrow="Ops · Assets"
        title="Assets"
        subtitle="Everything you own, the city it sits in, and what that city will pay for it"
      />

      {/* THE SUMMARY — links, never a second copy of the surfaces that own these facts. */}
      <Card data-testid="assets-summary">
        <StatRow label="Credits" value={<span data-testid="assets-credits">{creditsLabel}</span>} />
        <StatRow
          label="Ships"
          value={
            <Link data-testid="assets-ships-link" to="/ship" className="text-accent hover:underline">
              {shipCount} — open Ships
            </Link>
          }
        />
        <StatRow
          label="Fleets"
          value={
            <Link data-testid="assets-fleets-link" to="/fleet" className="text-accent hover:underline">
              {fleetCount} — open Fleet
            </Link>
          }
        />
        {ledger !== null && (
          <StatRow
            label="Valued"
            value={
              <span
                data-testid="assets-grand-total"
                className={totalIsPartial(ledger.total) ? 'text-warning' : undefined}
              >
                {totalLabel(ledger.total)}
              </span>
            }
          />
        )}
      </Card>

      {/* WHY A NUMBER IS MISSING — said ONCE, at the top, rather than on every unpriced row. */}
      {ledger !== null && totalIsPartial(ledger.total) && (
        <Notice tone="warning" data-testid="assets-price-caveat">
          {WHY_NO_PRICE}
        </Notice>
      )}
      {pricesUnavailable && (
        <Notice tone="warning" data-testid="assets-prices-unavailable">
          Prices could not be read just now, so nothing below is valued. Your goods are still there
          — the numbers are unknown, not zero.
        </Notice>
      )}

      {unavailable ? (
        <Card>
          <p data-testid="assets-unavailable" className="text-sm text-ink-muted">
            Your assets could not be read right now. This is a read failure, not an empty ledger.
          </p>
        </Card>
      ) : ledger === null ? (
        <Card aria-busy>
          <Skeleton className="h-8 w-full rounded-lg" />
          <Skeleton className="mt-2 h-8 w-2/3 rounded-lg" />
          <span className="sr-only">Checking what you own…</span>
        </Card>
      ) : ledger.places.length === 0 ? (
        <EmptyState
          data-testid="assets-empty"
          title="You are not holding anything yet"
          body="Salvage, rewards and anything you buy are banked in the storage of the port you were docked at. Dock somewhere and it will show up here, city by city."
        />
      ) : (
        <div data-testid="assets-places" className="space-y-4">
          {ledger.places.map((p) => (
            <PlaceCard key={p.locationId ?? 'nowhere'} place={p} />
          ))}
        </div>
      )}

      {/* The one line that names the rule, so "No price here" is never read as a bug. */}
      {ledger !== null && ledger.places.length > 0 && (
        <p data-testid="assets-footnote" className="text-[11px] text-ink-faint">
          Prices are per city and come from what that port actually buys — the same number you would
          be paid selling there. “{NO_PRICE_HERE}” means this port does not buy it; it does not mean
          it is worthless.
        </p>
      )}
    </Screen>
  )
}
