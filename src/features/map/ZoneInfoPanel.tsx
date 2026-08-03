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
//
// ── THE SIGNPOST (owner, 2026-08-03: "i went to snare, zone, no fighting happens") ────────────────
// This panel is the surface a player reaches by asking "what IS this place?" while standing in a
// pirate zone — and it was a dead end: it named the danger and never said what to do about it. The
// zone already knows the site it wraps (danger_zones.location_id, which the model resolves for the
// "Where" row), and the map already turns selecting that site into the hunt surface. So the fix is
// one button that hands the id back — NOT a second way to send a hunt.
//
// `onHuntSite` is REQUIRED, not optional. An optional callback would let a future caller mount this
// panel with a hunt site it cannot act on, which is the dead end all over again; a required prop
// makes the compiler the guard.
import type { ZoneInfo } from './zoneInfoModel'
import { Button } from '../../components/ui'

export function ZoneInfoPanel({
  info,
  onHuntSite,
}: {
  info: ZoneInfo
  /** Select the zone's hunt site — the map's OWN marker-selection path, which opens the one hunt control. */
  onHuntSite: (locationId: string) => void
}) {
  // Bound once so the click handler closes over a proven-non-null site (no `!` assertion).
  const site = info.huntSite
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
      {/* Rendered ONLY when the model proved a hunt site exists (see ZoneInfo.huntSite). */}
      {site && (
        <Button
          size="sm"
          variant="secondary"
          className="w-full"
          data-testid="zone-info-hunt-site"
          onClick={() => onHuntSite(site.locationId)}
        >
          {site.label}
        </Button>
      )}
    </div>
  )
}
