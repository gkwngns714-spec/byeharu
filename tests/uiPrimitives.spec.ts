import { test, expect } from '@playwright/test'
import { ICON_NAMES, ICON_PATHS } from '../src/components/ui/icons'
import { screenBodyClass } from '../src/components/ui/screenLayout'

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
