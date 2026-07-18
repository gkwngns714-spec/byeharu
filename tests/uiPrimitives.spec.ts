import { test, expect } from '@playwright/test'
import { ICON_NAMES, ICON_PATHS } from '../src/components/ui/icons'
import { screenBodyClass, screenRailClass, screenSplitClass } from '../src/components/ui/screenLayout'
import { OVERLAY_SLOTS, overlayPanelClass, overlayRailClass } from '../src/components/ui/overlayLayout'

// UI-R0 (Mission Control foundation) — pure unit proof for the design-system primitives' logic:
// the Icon name→glyph contract (every name resolves to valid stroked path data) and the Screen
// scaffold's width variant. Run: `npx playwright test uiPrimitives.spec.ts`.

test('every icon name resolves to at least one SVG path', () => {
  for (const name of ICON_NAMES) {
    const paths = ICON_PATHS[name]
    expect(paths.length, `icon "${name}" has no paths`).toBeGreaterThan(0)
    for (const d of paths) {
      // Valid path data: starts with a moveto command (absolute or relative).
      expect(d, `icon "${name}" has a malformed path`).toMatch(/^[Mm]/)
    }
  }
})

test('the four AppShell tab glyphs exist in the set', () => {
  for (const name of ['map', 'ship', 'anchor', 'command'] as const) {
    expect(ICON_NAMES).toContain(name)
  }
})

test('icon path map has no extra or missing keys', () => {
  expect(Object.keys(ICON_PATHS).sort()).toEqual([...ICON_NAMES].sort())
})

test('Screen default variant: centered max-w-3xl column with the space-y-4 rhythm', () => {
  const cls = screenBodyClass()
  expect(cls).toContain('max-w-3xl')
  expect(cls).not.toContain('max-w-6xl')
  for (const part of ['mx-auto', 'space-y-4', 'px-4', 'py-4', 'sm:px-6']) {
    expect(cls).toContain(part)
  }
})

test('Screen wide variant swaps ONLY the max width', () => {
  expect(screenBodyClass(true)).toBe(screenBodyClass(false).replace('max-w-3xl', 'max-w-6xl'))
})

// ── UI R3: the desktop ops split (Ship/Port/Command screen composition) ───────────────────────────

test('Screen split: single column on mobile, side-by-side top-aligned rails at lg', () => {
  const cls = screenSplitClass()
  for (const part of ['flex', 'flex-col', 'gap-4', 'lg:flex-row', 'lg:items-start']) {
    expect(cls).toContain(part)
  }
  // Deliberately FLEX, never a grid template — reserved grid tracks cannot collapse when a
  // rail's dark children all render null; a hidden flex rail hands its width to the sibling.
  expect(cls).not.toContain('grid')
})

test('Screen split rails: 2:1 at lg, panel rhythm, and dark-rail self-collapse (empty:hidden)', () => {
  const main = screenRailClass('main')
  const aside = screenRailClass('aside')
  for (const cls of [main, aside]) {
    for (const part of ['min-w-0', 'space-y-4', 'empty:hidden']) {
      expect(cls).toContain(part) // empty:hidden = an all-dark rail leaves NO production hole
    }
  }
  expect(main).toContain('lg:flex-[2_1_0%]')
  expect(aside).toContain('lg:flex-[1_1_0%]')
  // The rails differ ONLY in their flex ratio — one pattern, two widths.
  expect(aside).toBe(main.replace('lg:flex-[2_1_0%]', 'lg:flex-[1_1_0%]'))
})

// ── UI R1: OverlayPanel — the map-overlay chrome + per-corner slot layout ─────────────────────────

test('OverlayPanel chrome: tokenized surface, edge border, overlay shadow, blur — interactive by default', () => {
  const cls = overlayPanelClass()
  for (const part of ['pointer-events-auto', 'rounded-lg', 'border', 'bg-surface/90', 'shadow-overlay', 'backdrop-blur', 'border-edge']) {
    expect(cls).toContain(part)
  }
  expect(cls).not.toContain('absolute') // no slot → rail-positioned, never self-absolute
})

test('OverlayPanel slot prop self-positions each corner distinctly', () => {
  const seen = new Set<string>()
  for (const slot of OVERLAY_SLOTS) {
    const cls = overlayPanelClass('default', slot)
    expect(cls).toContain('absolute')
    expect(cls).toContain('z-10')
    seen.add(cls)
  }
  expect(seen.size).toBe(OVERLAY_SLOTS.length) // every slot maps to a unique position
  expect(overlayPanelClass('default', 'top-center')).toContain('-translate-x-1/2')
})

// ── S5 map-UX: the bottom-center slot (the ONE FleetCommandPanel anchor) ──────────────────────────

test('bottom-center slot: horizontally centered at the bottom edge, content packed to the bottom', () => {
  expect(OVERLAY_SLOTS).toContain('bottom-center')
  const panel = overlayPanelClass('default', 'bottom-center')
  for (const part of ['bottom-3', 'left-1/2', '-translate-x-1/2']) {
    expect(panel).toContain(part)
  }
  const rail = overlayRailClass('bottom-center')
  expect(rail).toContain('items-center')
  expect(rail).toContain('justify-end')
})

test('OverlayPanel tones swap ONLY the border tint; inert panels are pointer-transparent', () => {
  expect(overlayPanelClass('accent')).toBe(overlayPanelClass('default').replace('border-edge', 'border-accent/20'))
  expect(overlayPanelClass('warning')).toContain('border-warning/25')
  const inert = overlayPanelClass('default', undefined, '', true)
  expect(inert).toContain('pointer-events-none')
  expect(inert).not.toContain('pointer-events-auto')
})

test('OverlayRail: pointer-transparent positioned flex column per slot (co-corner overlays stack)', () => {
  for (const slot of OVERLAY_SLOTS) {
    const cls = overlayRailClass(slot)
    for (const part of ['pointer-events-none', 'absolute', 'z-10', 'flex', 'flex-col', 'gap-2']) {
      expect(cls).toContain(part)
    }
  }
  // right-edge rails hug the right; bottom rails pack content to the bottom
  expect(overlayRailClass('top-right')).toContain('items-end')
  expect(overlayRailClass('bottom-right')).toContain('justify-end')
  expect(overlayRailClass('bottom-left')).toContain('justify-end')
})
