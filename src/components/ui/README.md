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
| Accent/semantic | `accent`, `success`, `warning`, `danger` (+ `-hover` fills) | `text-accent`, `bg-danger/10`, … |
| Type | `--font-sans`, `--font-mono` | `font-sans`, `font-mono` (numeric readouts) |
| Shape | `--radius-card`, `--shadow-card` | `rounded-card`, `shadow-card` |

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
- **`SectionLabel`** — uppercase micro group heading inside panels.
- **`PageHeader`** — screen title + actions row.

Add a primitive ONLY when a screen needs it (no speculative components). Converted so far:
**Command Center** (Dashboard + its panels). Next: galaxy map, dock/port, market screens.
