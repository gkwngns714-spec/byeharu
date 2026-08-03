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
// ASSETS-TAB (owner order 2026-08-04: "i need to be able to see my assets. make a assets tab and
// show what i have, the estimate price, on which city etc.") — asked immediately after "where is
// my ship's cargo?", which they could not find. The old answer was "open Ships, pick a ship, then
// look in the right rail": the hold was fleet-wide UNDERNEATH but you could only REACH it by
// choosing a ship first, which is the per-ship framing the owner already rejected once ("make
// inventory not per ship, but for total fleet"). A thing you cannot reach without first picking a
// ship is not findable, so the ledger gets its own destination and ShipScreen's rail copy is gone.
//
// ── SIX ON A PHONE — RE-MEASURED 2026-08-04. The paragraph that used to sit here said five was the
// ceiling and that six "would start clipping labels". That number was an ESTIMATE that had never
// been rendered, and a stale numeric justification is exactly how the reposition-teleport bug
// survived (0311 justified a teleport with "weapon range 120+"; 0316 cut every range to 5-6; the
// comment was never revisited). So this is no longer an argument — it is the readout of a proof
// that runs in CI on every push.
//
// tests/navFits.uispec.ts renders THIS table through the real nav markup (NavBar.tsx) at a 320px
// viewport with the real design system loaded, and asserts per cell: width ≥ 44, height ≥ 44, and
// label scrollWidth ≤ clientWidth (nothing clipped) — plus that the bar never scrolls
// horizontally, and that the live-battle dot (the widest state the bar renders) changes none of it.
// MEASURED at six, 2026-08-04:
//
//     each cell 53.33px wide (> 53, < 54 — i.e. exactly 320 ÷ 6) × 56px tall (min-h-14).
//     Both clear the 44px touch floor. No label clips — including "Mission", the longest.
//
// So six fits, and the old comment's "six would start clipping labels" was simply wrong.
//
// WHERE THE REAL CEILING IS, and how sure we are: the proof measured cell width to be exactly
// viewport ÷ count, so by that measured divisor seven cells is 45.7px (above the floor, 1.7px of
// headroom) and eight is 40px (below it). That last step is ARITHMETIC ON A MEASURED DIVISOR, not
// a rendered result — seven has never been rendered, and label clipping at seven is untested. So
// the rule from here on is the proof, not this paragraph: a future destination either keeps
// navFits.uispec.ts green at its new count or merges into an existing tab.

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
  // ASSETS-TAB: the ledger — what you own, which city it sits in, and what it is worth THERE
  // (AssetsScreen). Sits beside Ships/Fleet because those three answer the same question ("what do
  // I have"); Port and Mission are places you go to DO something. `layers` is the existing
  // stacked-stock glyph — no new icon enters the set for this.
  { to: '/assets', label: 'Assets', icon: 'layers', enabled: true },
  { to: '/port', label: 'Port', icon: 'anchor', enabled: true },
  // MISSION-TAB: ops — what you're doing now and what happened (MissionScreen).
  { to: '/mission', label: 'Mission', icon: 'mission', enabled: true },
]

/** The tabs AppShell renders, in order (dark-gated destinations already dropped). */
export const NAV_TABS: readonly NavTab[] = ALL_TABS.filter((t) => t.enabled).map(
  ({ to, label, icon }) => ({ to, label, icon }),
)

/** The nav grid class for a tab count. STATIC literals (Tailwind sees all three, so none of them
 *  is tree-shaken out of the stylesheet), one per legal count — 5 (fleet gate dark) or 6 (lit).
 *  ASSETS-TAB moved both legal counts up by one; `grid-cols-4` is retired with the four-cell bar it
 *  described, because the table can no longer produce four. Anything else is a table bug, and
 *  tests/navTabs.spec.ts catches it before this function has to guess. */
export function navGridClass(count: number): 'grid-cols-5' | 'grid-cols-6' {
  return count === 6 ? 'grid-cols-6' : 'grid-cols-5'
}

/** WHERE A LIVE BATTLE LIVES — the destination the combat alert dot marks.
 *
 *  A fight can start anywhere: an ambush fires mid-leg, and a hunt's combat opens on arrival. A
 *  player sitting on Ships or Port had NOTHING telling them a battle had begun — no badge, no dot,
 *  nothing — so the first they knew of it was a destroyed fleet in the reports. The nav is the only
 *  chrome present on every screen, so that is where the alert belongs. Exported as a constant rather
 *  than compared inline in AppShell, so this table stays the ONE authority on which destination
 *  owns combat. */
export const COMBAT_TAB_TO = '/mission'
