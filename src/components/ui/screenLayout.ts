// Design-system Screen scaffold logic — pure (no React) so tests can prove the width-variant
// contract (see tests/uiPrimitives.spec.ts) and react-refresh keeps Screen.tsx component-only.

/** The Screen content column: centered, padded, space-y-4 panel rhythm. `wide` = desktop two-column width (pair with screenSplitClass). */
export function screenBodyClass(wide = false): string {
  return `mx-auto ${wide ? 'max-w-6xl' : 'max-w-3xl'} space-y-4 px-4 py-4 sm:px-6`
}

// UI R3 (screen composition) — the ONE desktop ops split used by Ship/Port/Command: a single
// column on mobile, a 2:1 main/aside rail pair at lg. FLEX, not a grid template, deliberately:
// grid tracks stay reserved even when a cell's content renders null, but a flex rail marked
// `empty:hidden` disappears entirely when EVERY child renders null (the dark-gate posture —
// Modules/Captains/Recruit/Investment/StationHangar/Ranking all return null while unlit), and its
// sibling rail then takes the full row. Production with all-dark rails therefore shows NO hole,
// no off-center column, and no phantom gap. RULES: rails may contain ONLY element children (JSX
// strips whitespace-only lines, so an all-null rail is truly `:empty`), and a screen-owned
// SectionLabel may sit above a rail child ONLY when that child is statically known to render
// (never above a server-lit dark panel).

/** The split wrapper: stacked with the screen's 1rem rhythm on mobile, side-by-side top-aligned rails at lg. */
export function screenSplitClass(): string {
  return 'flex flex-col gap-4 lg:flex-row lg:items-start'
}

/** One rail of the split: `main` (2fr-ish, the primary status/action column) or `aside` (1fr-ish,
 *  secondary/history). Self-collapses via `empty:hidden` when every child renders null. */
export function screenRailClass(rail: 'main' | 'aside'): string {
  return `min-w-0 space-y-4 empty:hidden ${rail === 'main' ? 'lg:flex-[2_1_0%]' : 'lg:flex-[1_1_0%]'}`
}
