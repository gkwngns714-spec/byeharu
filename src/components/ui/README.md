# Byeharu design system

**The rule: screens compose primitives, never re-define styles.** Panel chrome, buttons, badges,
meters, and notices come from this directory; their colors come ONLY from the `@theme` tokens in
`src/index.css`. No screen hardcodes palette literals (`slate-900`, `white/40`, hex values) for
chrome after conversion — feature identity is expressed through the primitives' `tone` props.

## Tokens (`src/index.css` `@theme` — the canonical source)

| Group | Tokens | Utilities |
|---|---|---|
| Layers | `app` < `surface` < `surface-2`, border `edge` | `bg-app`, `bg-surface`, `bg-surface-2`, `border-edge` |
| Text | `ink`, `ink-muted`, `ink-faint` | `text-ink`, `text-ink-muted`, `text-ink-faint` |
| Accent/semantic | `accent`, `success`, `warning`, `danger` (+ `-hover` fills, `-soft` alpha panel tints) | `text-accent`, `bg-danger/10`, `bg-accent-soft`, … |
| Map aliases | `map-grid`, `map-halo` (R1 galaxy-map overlays) | `stroke-map-grid`, `bg-map-halo`, … |
| Type | `--font-sans` (Inter), `--font-mono` (JetBrains Mono) — both self-hosted via `@fontsource`, imported in `src/main.tsx` | `font-sans`, `font-mono` (numeric readouts + `SectionLabel`) |
| Shape | `--radius-card`, `--shadow-card`, `--shadow-overlay` (map overlays) | `rounded-card`, `shadow-card`, `shadow-overlay` |

Skin: **Mission Control** (UI R0) — graphite-teal layers, cyan accent, mono micro-labels.
Re-skins happen ONLY by retuning token values in `src/index.css`; token names never change.

Type conventions: page title `text-2xl font-semibold` · panel title `text-lg font-semibold` ·
body `text-sm` · metadata `text-xs` · micro-labels via `<SectionLabel>`.

## Primitives

- **`Button`** — variants `primary | secondary | ghost | danger | warning`, sizes `sm | md`,
  `busy`/`busyLabel` loading state. `buttonClasses(variant, size)` for router `<Link>`s.
- **`Card` / `CardHeader`** — the panel treatment (`<section>` + surface/edge/radius/elevation);
  `tone` for feature identity tints. Spreads `data-testid`/aria props.
- **`Badge`** — uppercase status pill, semantic tones.
- **`Meter`** — progress/integrity bar, tonal fill.
- **`Notice`** — inline tinted callout (errors, warnings, confirmations). Spreads `data-testid`.
- **`SectionLabel`** — uppercase mono micro group heading inside panels (the ops-console label).
- **`PageHeader`** — screen title + actions row; no own bottom margin (the `Screen` stack's
  `space-y-4` owns the rhythm).
- **`Screen`** — the page scaffold every destination mounts (scroll owner + centered column +
  `space-y-4` stack). `wide` switches `max-w-3xl` → `max-w-6xl` for future desktop two-column
  layouts. Screens never hand-copy this frame.
- **`EmptyState`** — Card-based "nothing here" surface: icon slot + title + optional body/action.
- **`Skeleton`** — pulsing tokenized loading block; size via className.
- **`OverlayPanel` / `OverlayRail`** — the map-overlay chrome + per-corner slot layout (UI R1).
  `OverlayPanel` = `bg-surface/90` + tone border + `shadow-overlay` + `backdrop-blur`; give it a
  `slot` (`top-left | top-right | bottom-left | bottom-right | top-center`) when it is the corner's
  only occupant, or omit `slot` and stack several panels inside an `OverlayRail slot=…` (a
  pointer-transparent positioned flex column) so co-corner overlays never collide. `inert` renders
  a panel pointer-transparent (e.g. the map legend). `overlayPanelClass`/`overlayRailClass` are the
  pure class builders (unit-tested in `tests/uiPrimitives.spec.ts`).
- **`Icon`** — the ONE inline-SVG line-icon set (`./icons.ts` holds the glyph data:
  `map ship anchor command combat repair compass chevron close plus`). `currentColor` strokes —
  icons wear token text colors, never their own palette. `size` prop (px, default 20).

Add a primitive ONLY when a screen needs it (no speculative components). Converted so far:
**Command Center** (Dashboard + its panels), **Galaxy map** (UI R1: backdrop/markers/labels via the
pure `features/map/markerStyle.ts` policy + the OverlayPanel slot system). Next: dock/port, market
screens (incl. the map feature panels' INNER skins — R2).
