// ZONE INFO PANEL — what a danger zone IS, in a player's words.
//
// Owner ask (2026-07-29): "when i put my mouse over a zone in a game, i want to be able to click it,
// and see the info."
//
// PLACEMENT: this renders INSIDE MapScreen's existing bottom-right command-hub rail, as one more
// hub view beside Send fleet / Mine here / Pirate intercept. It does NOT position itself and it owns
// no close button — the hub header already provides both. That is deliberate: the play-test rules
// forbid a panel over the map centre and the codebase has ONE command-hub authority; adding a second
// self-positioning overlay would fork it.
//
// WORDS: the model decides them (zoneInfoModel). This file only lays them out, so the copy stays
// unit-testable and there is exactly one place where a zone is described.
import type { ZoneInfo } from './zoneInfoModel'

export function ZoneInfoPanel({ info }: { info: ZoneInfo }) {
  return (
    <div data-testid="zone-info-panel" className="w-72 max-w-full space-y-2 text-sm">
      {/* The warning leads: it is the only thing that changes what a player does next. */}
      <p data-testid="zone-info-warning" className="text-ink">
        {info.warning}
      </p>
      <dl className="space-y-1">
        {info.rows.map((row) => (
          <div key={row.label} className="flex items-baseline justify-between gap-3">
            <dt className="shrink-0 text-ink-faint">{row.label}</dt>
            <dd className="min-w-0 truncate text-right text-ink-muted">{row.value}</dd>
          </div>
        ))}
      </dl>
    </div>
  )
}
