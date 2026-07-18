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

/** The per-corner rail classes (pure — unit-tested). The rail itself is pointer-transparent (an
 *  empty rail never intercepts map gestures); its OverlayPanel children re-enable pointer events. */
export function overlayRailClass(slot: OverlaySlot, extra = ''): string {
  return ['pointer-events-none absolute z-10 flex flex-col gap-2', SLOT_POS[slot], SLOT_ALIGN[slot], extra]
    .filter(Boolean)
    .join(' ')
}
