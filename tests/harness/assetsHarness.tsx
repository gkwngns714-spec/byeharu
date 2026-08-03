import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { MemoryRouter } from 'react-router-dom'
import { AssetsLedgerView } from '../../src/features/assets/AssetsLedgerView'
import { emptyLedger, fullyPricedLedger, mixedLedger, unpricedLedger } from './assetsFixtures'
import './harness.css'

// ASSETS-TAB — the harness for tests/assetsLedger.uispec.ts. It mounts the REAL
// <AssetsLedgerView> — the component the game ships — with an INJECTED ledger (the RepairPanel
// harness pattern). Nothing is stubbed but the data and the router.
//
// Only a rendered proof can show that a missing price reaches the SCREEN as words rather than as a
// zero. The pure specs prove the model returns null; this proves null never becomes "0" on its way
// through the DOM, which is where a formatter, a `?? 0`, or a `toLocaleString` on a null would put
// it back.
//
// ?state=mixed|unpriced|priced|empty|loading|unavailable|noprices

const params = new URLSearchParams(window.location.search)
const state = params.get('state') ?? 'mixed'

const ledger =
  state === 'unpriced'
    ? unpricedLedger()
    : state === 'priced'
      ? fullyPricedLedger()
      : state === 'empty'
        ? emptyLedger()
        : state === 'loading'
          ? null
          : state === 'unavailable'
            ? null
            : state === 'noprices'
              ? unpricedLedger()
              : mixedLedger()

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <MemoryRouter initialEntries={['/assets']}>
      <div className="h-[100dvh] bg-app text-ink">
        <AssetsLedgerView
          ledger={ledger}
          unavailable={state === 'unavailable'}
          pricesUnavailable={state === 'noprices'}
          shipCount={4}
          fleetCount={2}
          creditsLabel="1,250"
        />
      </div>
    </MemoryRouter>
  </StrictMode>,
)
