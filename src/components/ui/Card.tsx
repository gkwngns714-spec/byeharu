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

/** Card title row: title (+ optional subtitle) on the left, an aside (badge/action/meta) on the right. */
export function CardHeader({
  title,
  subtitle,
  aside,
  className = '',
}: {
  title: ReactNode
  subtitle?: ReactNode
  aside?: ReactNode
  className?: string
}) {
  return (
    <div className={`mb-4 flex items-start justify-between gap-3 ${className}`}>
      <div>
        <h2 className="text-lg font-semibold text-ink">{title}</h2>
        {subtitle && <p className="mt-0.5 text-sm text-ink-muted">{subtitle}</p>}
      </div>
      {aside && <div className="shrink-0">{aside}</div>}
    </div>
  )
}
