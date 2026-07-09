import { createContext, useContext } from 'react'
import { useGameState } from '../features/dashboard/useGameState'
import type { CombatState } from '../features/combat/useCombat'
import type { GalaxyMapData } from '../features/map/useGalaxyMapData'
import type { MainShipSelection } from '../features/map/useMainShipSelection'

// UI-REBUILD (2b) — the shell's shared-state contract, in its own non-component module (the
// react-refresh rule forbids exporting hooks from a component file). AppShell provides this
// context (the polled hooks + the ONE selection, mounted exactly once); every destination consumes
// it via useShellState instead of mounting its own useGameState/useCombat/useGalaxyMapData/useMainShipSelection.

export interface ShellState {
  game: ReturnType<typeof useGameState>
  combat: CombatState
  map: GalaxyMapData
  // A0 FOUNDATION FIXUP — the SINGLE client selected-ship model. Previously ShipScreen and PortScreen each
  // mounted their own useMainShipSelection, so a selection made on one screen was invisible to the other. Lifted
  // here so there is ONE source of truth (the documented TODO in ShipScreen). Drives the dark ShipSwitcher /
  // MarketPanel today; ready for the multi-ship lit path.
  selection: MainShipSelection
}

export const ShellStateContext = createContext<ShellState | null>(null)

export function useShellState(): ShellState {
  const v = useContext(ShellStateContext)
  if (!v) throw new Error('useShellState must be used within AppShell')
  return v
}
