// PHASE 9 (UI proof) — mounts the REAL <DockServicesPanel> with its injected fetcher so a Playwright spec can
// drive the rendered docked-port surface across server states. No production access; nothing connects.
import { useReducer } from 'react'
import { createRoot } from 'react-dom/client'
import { DockServicesPanel } from '../../src/features/map/DockServicesPanel'
import type { DockServices } from '../../src/features/map/dockServices'

type HState = { dock: DockServices }
const w = window as unknown as { __state: HState; __set: (p: Partial<HState>) => void; __rerender: () => void }

function Harness() {
  const [, force] = useReducer((n: number) => n + 1, 0)
  w.__rerender = () => force()
  w.__set = (patch) => {
    w.__state = { ...w.__state, ...patch }
    force()
  }
  const s = w.__state
  // lifecycleKey changes when the injected dock state changes, so the panel's fetcher re-reads it.
  const key = `${s.dock.state}|${s.dock.locationId ?? 'n'}|${s.dock.services.join(',')}`
  return (
    <DockServicesPanel
      lifecycleKey={key}
      deps={{
        // a `__fail` flag makes the injected fetcher REJECT, to prove safe failure (panel stays hidden).
        fetcher: async () => {
          const d = w.__state.dock as DockServices & { __fail?: boolean }
          if (d && d.__fail) throw new Error('simulated fetch failure')
          return d
        },
      }}
    />
  )
}

createRoot(document.getElementById('root')!).render(<Harness />)
