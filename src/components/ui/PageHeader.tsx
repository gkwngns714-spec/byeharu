import type { ReactNode } from 'react'

// Design-system page header: title + optional subtitle on the left, actions (nav links,
// buttons) on the right. One per screen, above the panel stack.

export function PageHeader({
  title,
  subtitle,
  actions,
  className = '',
}: {
  title: ReactNode
  subtitle?: ReactNode
  actions?: ReactNode
  className?: string
}) {
  return (
    <header className={`mb-8 flex flex-wrap items-center justify-between gap-3 ${className}`}>
      <div>
        <h1 className="text-2xl font-semibold tracking-tight text-ink">{title}</h1>
        {subtitle && <p className="mt-0.5 text-sm text-ink-muted">{subtitle}</p>}
      </div>
      {actions && <div className="flex items-center gap-2">{actions}</div>}
    </header>
  )
}
