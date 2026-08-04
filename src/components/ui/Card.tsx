import type { HTMLAttributes, ReactNode } from 'react'

// Design-system Card/Panel: the ONE panel treatment (surface + edge + radius + elevation).
// `tone` gives a feature panel its subtle identity tint WITHOUT per-screen palettes.
// Rendered as <section> (the panels' existing landmark role); spreads rest props so
// data-testid and aria-* pass through untouched.

export type CardTone = 'default' | 'accent' | 'success' | 'warning' | 'danger'

const TONE: Record<CardTone, string> = {
  default: 'border-edge bg-surface',
  accent: 'border-accent/20 bg-surface',
  success: 'border-success/20 bg-surface',
  warning: 'border-warning/25 bg-surface',
  danger: 'border-danger/25 bg-surface',
}

export function Card({
  tone = 'default',
  className = '',
  children,
  ...rest
}: HTMLAttributes<HTMLElement> & { tone?: CardTone }) {
  return (
    <section className={`rounded-card border ${TONE[tone]} p-4 shadow-card sm:p-6 ${className}`} {...rest}>
      {children}
    </section>
  )
}

/** Card title row: title (+ optional subtitle) on the left, an aside (badge/action/meta) on the right.
 * `eyebrow` (UI R4) — the same mono ops-console micro-designator PageHeader carries, for the rare
 * card that IS the screen (e.g. the auth focus card): one idiom, defined once, never hand-rolled.
 *
 * `flex-wrap` IS LOAD-BEARING (2026-08-04, CI-measured). The row is title | aside, and the aside is
 * `shrink-0` (a badge that truncates says nothing). Without wrapping, the row's MINIMUM width is
 * `min-content(title) + gap + width(aside)` — a number made of GLYPHS, so it is not the same number
 * on every platform. tests/shipsSideBySide.uispec.ts measured 245px for the Ships tab's detail
 * header on Windows, leaving 9px of slack inside a 320px phone; the SAME markup measured ~257px on
 * CI's Linux Chromium and pushed the page 3px sideways — the one thing the house rule says a page
 * may never do. Wrapping removes the sum from the equation entirely: when the badge will not fit
 * beside the title it drops below it, and the row's minimum becomes the WIDER OF THE TWO rather
 * than their total. It is a no-op whenever they fit, and it cannot clip anything. */
export function CardHeader({
  eyebrow,
  title,
  subtitle,
  aside,
  className = '',
}: {
  eyebrow?: ReactNode
  title: ReactNode
  subtitle?: ReactNode
  aside?: ReactNode
  className?: string
}) {
  return (
    <div className={`mb-4 flex flex-wrap items-start justify-between gap-3 ${className}`}>
      <div>
        {eyebrow && (
          <p className="mb-0.5 font-mono text-xs uppercase tracking-wider text-ink-faint">{eyebrow}</p>
        )}
        <h2 className="text-lg font-semibold text-ink">{title}</h2>
        {subtitle && <p className="mt-0.5 text-sm text-ink-muted">{subtitle}</p>}
      </div>
      {aside && <div className="shrink-0">{aside}</div>}
    </div>
  )
}
