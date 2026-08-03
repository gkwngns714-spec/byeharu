// THE NEAR-MISS RECORD — the Mission tab's half of "what the pirates did to you".
//
// The map alert (MapScreen) is the NEWS and expires after NEAR_MISS_MAP_WINDOW_MS, because the map
// is clean by law. This is the RECORD, beside the battle reports, and does not expire: a player who
// was elsewhere when a trip landed can still find out that it was a near miss rather than a nothing.
//
// A SECOND VIEW OF THE SAME ROWS, NOT A SECOND AUTHORITY — the exact posture CombatMapCard and
// ActiveCombatPanel already share over encounters (MapScreen's own note says so). Every word and
// every eligibility rule comes from the ONE pure model (nearMissNotice); this file chooses the
// window and lays the rows out. It fetches NOTHING: the rows arrive on the shell wave that
// useGameState already runs, so the Mission tab adds no request.
//
// SELF-HIDING: no near misses ⇒ renders null. The Mission rail must never carry a card that says
// "nothing happened" beside a card that already says "Nothing under way".
import { useState } from 'react'
import { Card, CardHeader } from '../../components/ui'
import { nearMissNotices, NEAR_MISS_KEEP_ALL } from '../map/nearMissNotice'
import type { InterceptMissLite } from '../map/pirateApi'
import type { NearMissLocationLite } from '../map/nearMissNotice'

export function NearMissSection({
  misses,
  locations,
  activeMovementIds,
}: {
  misses: readonly InterceptMissLite[]
  locations: readonly NearMissLocationLite[]
  activeMovementIds: readonly string[]
}) {
  // The mount-time clock, the house idiom (ActiveCombatPanel/TelegraphBanner/GalaxyMap all read
  // `useState(() => Date.now())`) — and deliberately WITHOUT an interval, unlike them. This record
  // keeps every miss (NEAR_MISS_KEEP_ALL), so the only thing the clock still decides is that a
  // future-stamped row (clock skew) is rejected; that verdict cannot change as time passes, so a
  // ticking clock here would re-render the card for nothing. `Date.now()` in the render body would
  // be an impure read — same result today, unstable under a re-render tomorrow.
  const [nowMs] = useState(() => Date.now())
  const notices = nearMissNotices({
    misses,
    locations,
    activeMovementIds,
    nowMs,
    withinMs: NEAR_MISS_KEEP_ALL,
    limit: 5,
  })
  if (notices.length === 0) return null
  return (
    <Card data-testid="near-miss-section">
      <CardHeader title="Close calls" subtitle="Crossings where the pirates rolled for you and missed." />
      <ul className="space-y-1">
        {notices.map((n) => (
          <li key={n.id} data-testid={`near-miss-${n.id}`} className="text-sm text-ink-muted">
            {n.text}
          </li>
        ))}
      </ul>
    </Card>
  )
}
