import type { HTMLAttributes, ReactNode } from 'react'
import {
  overlayAccountClass,
  overlayPanelClass,
  overlayRailClass,
  overlayReachStackClass,
  overlaySlotAlignClass,
  type OverlaySlot,
  type OverlayTone,
} from './overlayLayout'

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

/**
 * THE RAIL — and THE REACH LAW it enforces (see overlayLayout.ts for the measurement that earned it).
 *
 * A rail has TWO regions and a caller chooses which one a panel rides in:
 *   · `children` — the ACCOUNT: information. Capped and scrollable; it shrinks first.
 *   · `reach`    — the CONTROLS. Never capped, never scrolled, never clipped.
 *
 * The rail itself never scrolls and never takes a height cap from a call site. That is not a style
 * rule: a scroll ancestor ABOVE the reach region silently defeats it, which is exactly how "I can't
 * press hunt" survived a green UI proof. tests/actionsAreReachable.spec.ts fails the build if a call
 * site tries.
 *
 * `reach` omitted ⇒ the rail is pure information and everything scrolls. That is the honest default
 * for a legend or an alert stack; the moment a panel in a rail grows a button, it moves to `reach`.
 */
export function OverlayRail({
  slot,
  className = '',
  reach,
  children,
  ...rest
}: Omit<HTMLAttributes<HTMLDivElement>, 'slot'> & { slot: OverlaySlot; reach?: ReactNode }) {
  const align = overlaySlotAlignClass(slot)
  return (
    <div className={overlayRailClass(slot, className)} {...rest}>
      {children !== undefined && children !== null && children !== false && (
        // `shrink-[999]` is the LAW made arithmetic: information yields FIRST. Flexbox shrinks
        // items in proportion to their size, so with equal factors a 160px notice stack would take
        // only a third of the squeeze and hand the rest to the controls — which is the original bug
        // in slow motion. The overwhelming factor makes the account collapse to nothing before the
        // reach region gives up a single pixel.
        <div className={overlayAccountClass(`${align} shrink-[999]`)} data-overlay-region="account">
          {children}
        </div>
      )}
      {reach !== undefined && reach !== null && reach !== false && (
        <div className={overlayReachStackClass(align)} data-overlay-region="reach">
          {reach}
        </div>
      )}
    </div>
  )
}
