import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { MemoryRouter } from 'react-router-dom'
import { NavBar } from '../../src/app/NavBar'
import './harness.css'

// ASSETS-TAB — the harness for tests/navFits.uispec.ts. It mounts the REAL <NavBar> (which renders
// the REAL NAV_TABS table and the REAL navGridClass width) so the proof measures the shipped bar,
// not a replica of it. The app design system IS loaded (harness.css — which carries the `@source '../../src'`
// Tailwind v4 needs, since the harness Vite root is tests/harness) because this proof MEASURES
// pixels: min-h-14, text-[11px] and the grid columns all come from Tailwind, and approximating
// them would make the measurement meaningless.
//
// The only thing stubbed is the router (MemoryRouter — NavLink needs a routing context) and the
// combat count, which is a plain prop.
//
// ?combat=1 turns the live-battle dot on, so the proof can also check the widest state: the dot is
// absolutely positioned and must not push a label out of its cell.

const params = new URLSearchParams(window.location.search)
const combatCount = Number(params.get('combat') ?? '0') || 0

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <MemoryRouter initialEntries={['/map']}>
      {/* The bar sits at the bottom of a flex column in the real shell; the width is what matters
          here, so the harness gives it the full viewport width and nothing else. */}
      <div className="flex h-[100dvh] flex-col bg-app text-ink">
        <div className="flex-1" />
        <NavBar combatCount={combatCount} />
      </div>
    </MemoryRouter>
  </StrictMode>,
)
