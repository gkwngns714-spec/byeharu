// The bottom-nav destination table — PURE data + policy (no React), extracted from AppShell so the
// nav contract is spec-pinned (tests/navTabs.spec.ts) the way markerStyle pins the map's marker
// policy. AppShell renders EXACTLY this list; it never carries a second tab table.
//
// FLEET-TAB (owner order 2026-08-03: "fleet info, i want fleet tab separately") — the fleet
// surfaces (TeamRosterPanel + CommissionShipPanel) left the Command screen for their own /fleet
// destination. The tab is gated on the SAME compile constant that has always gated the roster
// panel (TEAM_COMMAND_ENABLED): while that gate is dark the tab is absent and the nav is the old
// four-destination bar — a tab may never lead to an empty screen.
//
// MISSION-TAB (owner order 2026-08-03: "make another tab of account - showing info as a whole,
// mission tab") — Command's slot became Mission. Command's forces surfaces had ALREADY folded
// into /fleet (the FLEET-TAB move above); what remained on /command was ops — onboarding, live
// battles, battle reports, standings — which is exactly what a mission tab is. So /mission is the
// renamed home of that content (MissionScreen), /command redirects there (bookmarks resolve), and
// ACCOUNT deliberately did NOT take a cell: it is the top-corner profile affordance in AppShell
// (AccountMenu) — identity/credits/totals are things you CHECK, not things you DO, and the
// thumb-reachable bar stays reserved for destinations you act on.
//
// FIVE ON A PHONE — measured, not assumed: at the 320px floor each of five cells is 64px wide ×
// the bar's min-h-14 (56px) — both beyond the 44px touch floor — and the longest label
// ("Mission", 7ch at text-[11px] ≈ 39px — same length "Command" measured before it) fits its
// cell. Six would drop cells to 53px and start clipping labels; five is the ceiling, so any
// FUTURE destination must merge into an existing tab, not extend this table.

import { TEAM_COMMAND_ENABLED } from '../features/map/osnReleaseGates'
import type { IconName } from '../components/ui'

export interface NavTab {
  to: string
  label: string
  icon: IconName
}

const ALL_TABS: readonly (NavTab & { enabled: boolean })[] = [
  { to: '/map', label: 'Map', icon: 'map', enabled: true },
  // PLAIN-WORDS: the destination is your SHIPS (roster by fleet + per-ship equipment + inventory).
  // "Fitting" was EVE jargon — a typical game calls this Ships. Route kept at /ship so old
  // bookmarks keep resolving. nav testid follows the label → `nav-ships`.
  { to: '/ship', label: 'Ships', icon: 'ship', enabled: true },
  // FLEET-TAB: fleet composition + ship acquisition (see FleetScreen). Same gate as the panels.
  { to: '/fleet', label: 'Fleet', icon: 'fleet', enabled: TEAM_COMMAND_ENABLED },
  { to: '/port', label: 'Port', icon: 'anchor', enabled: true },
  // MISSION-TAB: ops — what you're doing now and what happened (MissionScreen).
  { to: '/mission', label: 'Mission', icon: 'mission', enabled: true },
]

/** The tabs AppShell renders, in order (dark-gated destinations already dropped). */
export const NAV_TABS: readonly NavTab[] = ALL_TABS.filter((t) => t.enabled).map(
  ({ to, label, icon }) => ({ to, label, icon }),
)

/** The nav grid class for a tab count. STATIC literals (Tailwind sees both), one per legal count —
 *  4 (fleet gate dark) or 5 (lit). Anything else is a table bug the spec catches first. */
export function navGridClass(count: number): 'grid-cols-4' | 'grid-cols-5' {
  return count === 5 ? 'grid-cols-5' : 'grid-cols-4'
}
