import type { HTMLAttributes } from 'react'
import { overlayPanelClass, overlayRailClass, type OverlaySlot, type OverlayTone } from './overlayLayout'

// Design-system OverlayPanel (UI R1) — the ONE map-overlay chrome. Deferred from R0 until the galaxy
// map needed it; consumes tokens only (bg-surface/90, border-edge + semantic tone tints,
// --shadow-overlay, backdrop-blur). Two pieces compose the map's overlay-slot layout (the pure class
// builders live in ./overlayLayout.ts — the screenLayout idiom):
//
//   • OverlayPanel — the floating chrome. Give it a `slot` when it is the corner's ONLY occupant
//     (it positions itself); omit `slot` when it rides inside an OverlayRail. `inert` renders it
//     pointer-transparent (read-only surfaces like the map legend never block map gestures).
//   • OverlayRail — the positioned per-corner flex rail: multiple overlays sharing a corner stack
//     cleanly in a column instead of colliding at hand-tuned `absolute left-[Nrem]` offsets.

export function OverlayPanel({
  tone = 'default',
  slot,
  inert = false,
  className = '',
  children,
  ...rest
}: Omit<HTMLAttributes<HTMLDivElement>, 'slot'> & { tone?: OverlayTone; slot?: OverlaySlot; inert?: boolean }) {
  return (
    <div className={overlayPanelClass(tone, slot, className, inert)} {...rest}>
      {children}
    </div>
  )
}

export function OverlayRail({
  slot,
  className = '',
  children,
  ...rest
}: Omit<HTMLAttributes<HTMLDivElement>, 'slot'> & { slot: OverlaySlot }) {
  return (
    <div className={overlayRailClass(slot, className)} {...rest}>
      {children}
    </div>
  )
}
