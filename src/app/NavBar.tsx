import { NavLink } from 'react-router-dom'
import { Icon } from '../components/ui'
import { COMBAT_TAB_TO, NAV_TABS, navGridClass } from './navTabs'

// THE ONE bottom navigation. Extracted from AppShell by ASSETS-TAB so it can be RENDERED and
// MEASURED on its own (tests/navFits.uispec.ts) at a 320px viewport — the nav's width budget used
// to be defended by a paragraph of arithmetic in navTabs.ts that had never actually been rendered,
// and that estimate was wrong. A number in a comment is not a measurement; a proof is. Extracting
// the markup is what makes the measurement possible without booting the whole shell (which needs
// auth, Supabase and four polling hooks).
//
// AppShell renders THIS and nothing else — there is no second copy of the bar. The destinations
// and the grid width still come from navTabs.ts, which stays the one table.

export function NavBar({ combatCount }: { combatCount: number }) {
  return (
    <nav aria-label="Primary" data-testid="app-nav" className="border-t border-edge bg-surface">
      <div className={`mx-auto grid max-w-3xl ${navGridClass(NAV_TABS.length)}`}>
        {NAV_TABS.map((t) => {
          // A LIVE BATTLE IS ANNOUNCED ON EVERY SCREEN. The nav is the only chrome that is always
          // mounted, and combat.encounters is already polled by the shell — no new read.
          const fighting = t.to === COMBAT_TAB_TO && combatCount > 0
          return (
            <NavLink
              key={t.to}
              to={t.to}
              data-testid={`nav-${t.label.toLowerCase()}`}
              className={({ isActive }) =>
                `relative flex min-h-14 flex-col items-center justify-center gap-0.5 text-[11px] transition ${
                  isActive ? 'font-medium text-accent' : 'text-ink-muted hover:text-ink'
                }`
              }
            >
              <span className="relative">
                <Icon name={t.icon} size={20} />
                {fighting && (
                  <span
                    data-testid="nav-combat-alert"
                    aria-label={`${combatCount} battle${combatCount === 1 ? '' : 's'} under way`}
                    title="Battle under way"
                    className="absolute -right-1.5 -top-1 h-2.5 w-2.5 animate-pulse rounded-full bg-danger ring-2 ring-surface"
                  />
                )}
              </span>
              {/* The label is its own measurable box: the fit proof reads scrollWidth vs
                  clientWidth on THIS element, which is what "the label clips" actually means.
                  `truncate` would hide a clip instead of failing, so it is deliberately absent —
                  an overflowing label must be visible to the proof. */}
              <span data-testid={`nav-label-${t.label.toLowerCase()}`} className="whitespace-nowrap">
                {t.label}
              </span>
            </NavLink>
          )
        })}
      </div>
    </nav>
  )
}
