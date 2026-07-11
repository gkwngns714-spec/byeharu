import type { ReactNode } from 'react'
import { screenBodyClass } from './screenLayout'

// Design-system Screen: the ONE page scaffold every destination mounts (owns its scroll inside
// the shell, centers the content column, and sets the space-y-4 panel rhythm that PageHeader and
// the cards rely on). Screens NEVER hand-copy this frame again. `wide` switches to the desktop
// two-column width (future R1+ layouts); class logic lives in ./screenLayout.ts (pure, tested).

export function Screen({
  children,
  wide = false,
  className = '',
}: {
  children: ReactNode
  wide?: boolean
  className?: string
}) {
  return (
    <div className={`h-full overflow-y-auto ${className}`}>
      <div className={screenBodyClass(wide)}>{children}</div>
    </div>
  )
}
