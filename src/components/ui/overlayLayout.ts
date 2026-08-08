// Design-system overlay-slot layout (UI R1) — the PURE class builders behind OverlayPanel/OverlayRail
// (the screenLayout.ts idiom: pure module beside the component so react-refresh stays happy and the
// slot/chrome contract is unit-testable — tests/uiPrimitives.spec.ts). Tokens only.

export const OVERLAY_SLOTS = ['top-left', 'top-right', 'bottom-left', 'bottom-right', 'top-center', 'bottom-center'] as const
export type OverlaySlot = (typeof OVERLAY_SLOTS)[number]

export type OverlayTone = 'default' | 'accent' | 'success' | 'warning' | 'danger'

// Corner anchor (inset 0.75rem — sits just inside the map's rounded-card border).
const SLOT_POS: Record<OverlaySlot, string> = {
  'top-left': 'left-3 top-3',
  'top-right': 'right-3 top-3',
  'bottom-left': 'bottom-3 left-3',
  'bottom-right': 'bottom-3 right-3',
  'top-center': 'left-1/2 top-3 -translate-x-1/2',
  // S5 map-UX: the ONE bottom-center fleet-command slot (FleetCommandPanel).
  'bottom-center': 'bottom-3 left-1/2 -translate-x-1/2',
}

// Cross-axis alignment for a rail's stacked children (right rails hug the right edge, etc.).
const SLOT_ALIGN: Record<OverlaySlot, string> = {
  'top-left': 'items-start',
  'top-right': 'items-end',
  'bottom-left': 'items-start justify-end',
  'bottom-right': 'items-end justify-end',
  'top-center': 'items-center',
  'bottom-center': 'items-center justify-end',
}

// Border tint per tone — mirrors Card's TONE alphas so feature identity reads the same language.
const TONE: Record<OverlayTone, string> = {
  default: 'border-edge',
  accent: 'border-accent/20',
  success: 'border-success/20',
  warning: 'border-warning/25',
  danger: 'border-danger/25',
}

/** The overlay chrome classes (pure — unit-tested). `slot` adds self-positioning for a corner's
 *  sole occupant; `inert` makes the panel pointer-transparent (display-only overlays). */
export function overlayPanelClass(tone: OverlayTone = 'default', slot?: OverlaySlot, extra = '', inert = false): string {
  return [
    inert ? 'pointer-events-none' : 'pointer-events-auto',
    'rounded-lg border bg-surface/90 p-2 shadow-overlay backdrop-blur',
    TONE[tone],
    slot ? `absolute z-10 ${SLOT_POS[slot]}` : '',
    extra,
  ]
    .filter(Boolean)
    .join(' ')
}

// ██ THE REACH LAW — one authority for "a control the player must be able to press". ██
//
// **An action may never live inside a region that can scroll or clip it.** Stated once, here,
// composed by every surface that caps its own height.
//
// WHY (owner, playing the LIVE game, 2026-08-08: *"right now i can't press hunt."*). The button was
// not disabled. Measured at 1440x675: "Hunt at Snare" occupied y 391→435; the top-left rail it rode
// — then `max-h-[60%] overflow-y-auto` at the CALL SITE — ended at y=399 with clientHeight 334
// against scrollHeight 386. **8 of its 44 pixels were on screen.** The rail stacks an exploration
// panel, ambush/near-miss notices, the combat card and the fleet readout; the close-call notice
// ("Slipped past the pirates around Snare.") appears only NEAR A DANGER ZONE — precisely when Hunt is
// needed — and Hunt, being last in the stack, is what the cap cut off.
//
// The rule already existed for the BRAKE and was written down at FleetCommandPanel.tsx:542 — *"Stop
// renders OUTSIDE the scroll container so it can never scroll away."* It was a per-panel habit, so it
// protected exactly one button and nothing else. These two builders are that habit made structural:
//
//   · overlayAccountClass — the CAPPED, SCROLLABLE region. INFORMATION only: notices, readouts,
//     history. It shrinks first and it may scroll, because losing sight of a sentence costs nothing.
//   · overlayReachClass   — the region that is NEVER capped and NEVER scrolled. The controls live
//     here. In a flex column it is the `shrink-0` sibling, so the account collapses to nothing
//     before a single pixel of a button is taken.
//
// The cap therefore lands on the INFORMATION, never on the ACTION. That inversion is the whole fix:
// before it, the last thing in the stack was the victim, and the last thing in the stack is always
// the thing you are trying to press.
//
// A caller may NOT cap or scroll a rail itself — tests/actionsAreReachable.spec.ts fails the build if
// any OverlayRail call site passes `overflow`/`max-h`, because a scroll ancestor above the reach
// region defeats it silently (which is exactly how this defect survived a green UI proof).

/** The capped, scrollable INFORMATION region. Never put a control in it. */
export function overlayAccountClass(extra = ''): string {
  return ['flex min-h-0 w-full flex-col gap-2 overflow-y-auto', extra].filter(Boolean).join(' ')
}

/** The pinned region: controls the player must always be able to press. Never capped, never scrolled,
 *  never shrunk. This is the LEAF — a row of controls inside a panel (the command panel's brake, a
 *  card's Retreat, the exploration Scan). */
export function overlayReachClass(extra = ''): string {
  return ['flex w-full shrink-0 flex-col gap-2', extra].filter(Boolean).join(' ')
}

/**
 * The rail's reach region — the CONTAINER of reach panels, which is a different job from the leaf
 * above and must not be confused with it.
 *
 * It carries NO overflow (it can never scroll a control out of sight) but it IS squeezable, because
 * each panel inside it applies the law to itself: the panel's own account gives way, its own
 * controls do not. So pressure travels DOWN into the information and never lands on a button. A
 * `shrink-0` region would instead push the whole stack off the bottom of the phone the moment the
 * panels total more than the map box — which they do the instant a fight starts (measured: an
 * exploration panel + a live combat card + the fleet readout is 583px against a 505px map box at
 * the owner's own 1440x675).
 *
 * THE YIELD ORDER, declared by the panels themselves (a flex `shrink` factor each) so that pressure
 * lands on the least urgent information first, and each panel FLOORS at its own pinned row:
 *   1. `shrink-[999]` ExplorationPanel — a discoveries list nobody is reading mid-fight;
 *   2. `shrink-[99]`  CombatMapCard    — the fight's numbers, which the Mission screen also carries;
 *   3. `shrink` (1)   FleetStatusPanel — where the fleets are and what they can do. Last to give.
 * Each panel's `min-h-[…]` is its own pinned content (padding + the 44px control), so no amount of
 * pressure can ever squeeze a panel down past its button. tests/actionsAreReachable.spec.ts pins
 * the order; tests/actionsAreReachable.uispec.ts measures that the squeeze always succeeds.
 */
export function overlayReachStackClass(extra = ''): string {
  return ['flex min-h-0 w-full flex-col gap-2', extra].filter(Boolean).join(' ')
}

/** The per-corner rail classes (pure — unit-tested). The rail itself is pointer-transparent (an
 *  empty rail never intercepts map gestures); its OverlayPanel children re-enable pointer events.
 *
 *  THE RAIL OWNS ITS OWN BOUND: `max-h-[calc(100%-1.5rem)]` — the map box minus the rail's own
 *  0.75rem insets, so a rail can never grow past the surface it floats on. That bound used to be a
 *  hand-tuned percentage at each call site (`max-h-[60%]`, `max-h-[85%]`), which is two authorities
 *  for one rule and is what put the cap on top of the actions. The rail carries NO overflow: the
 *  scrolling belongs to the account region inside it (see the reach law above). */
export function overlayRailClass(slot: OverlaySlot, extra = ''): string {
  return [
    'pointer-events-none absolute z-10 flex max-h-[calc(100%-1.5rem)] flex-col gap-2',
    SLOT_POS[slot],
    SLOT_ALIGN[slot],
    extra,
  ]
    .filter(Boolean)
    .join(' ')
}

/** Cross-axis alignment for a rail's inner regions — exported so OverlayRail composes the SAME
 *  per-slot rule its children already follow, instead of re-stating it. */
export function overlaySlotAlignClass(slot: OverlaySlot): string {
  return SLOT_ALIGN[slot]
}
