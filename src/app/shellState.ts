import { createContext, useContext } from 'react'
import { useGameState } from '../features/dashboard/useGameState'
import type { CombatState } from '../features/combat/useCombat'
import type { GalaxyMapData } from '../features/map/useGalaxyMapData'

// UI-REBUILD (2b) — the shell's shared-state contract, in its own non-component module (the
// react-refresh rule forbids exporting hooks from a component file). AppShell provides this
// context (the three polled hooks mounted exactly once); every destination consumes it via
// useShellState instead of mounting its own useGameState/useCombat/useGalaxyMapData.

export interface ShellState {
  game: ReturnType<typeof useGameState>
  combat: CombatState
  map: GalaxyMapData
}

export const ShellStateContext = createContext<ShellState | null>(null)

export function useShellState(): ShellState {
  const v = useContext(ShellStateContext)
  if (!v) throw new Error('useShellState must be used within AppShell')
  return v
}
