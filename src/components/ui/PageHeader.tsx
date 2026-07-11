import type { ReactNode } from 'react'

// Design-system page header: optional mono micro-label (eyebrow — the ops-console screen
// designator, R3) over title + optional subtitle on the left, actions (nav links, buttons) on
// the right. One per screen, first child of <Screen> — the Screen stack's space-y-4 owns the
// rhythm, so PageHeader carries NO bottom margin of its own.

export function PageHeader({
  eyebrow,
  title,
  subtitle,
  actions,
  className = '',
}: {
  eyebrow?: ReactNode
  title: ReactNode
  subtitle?: ReactNode
  actions?: ReactNode
  className?: string
}) {
  return (
    <header className={`flex flex-wrap items-center justify-between gap-3 ${className}`}>
      <div>
        {eyebrow && (
          <p className="mb-0.5 font-mono text-xs uppercase tracking-wider text-ink-faint">{eyebrow}</p>
        )}
        <h1 className="text-2xl font-semibold tracking-tight text-ink">{title}</h1>
        {subtitle && <p className="mt-0.5 text-sm text-ink-muted">{subtitle}</p>}
      </div>
      {actions && <div className="flex items-center gap-2">{actions}</div>}
    </header>
  )
}
