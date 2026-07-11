import type { HTMLAttributes, ReactNode } from 'react'
import { Card } from './Card'

// Design-system EmptyState: the ONE "nothing here (yet)" surface — a Card with a centered
// icon slot (pass an <Icon>), title, optional body, and optional action. Tokens only; spreads
// rest props so data-testid / aria-* pass through untouched.

export function EmptyState({
  icon,
  title,
  body,
  action,
  className = '',
  ...rest
}: Omit<HTMLAttributes<HTMLElement>, 'title' | 'children'> & {
  icon?: ReactNode
  title: ReactNode // honored as ReactNode (not the native string `title` attr, which is Omitted)
  body?: ReactNode
  action?: ReactNode
}) {
  return (
    <Card className={className} {...rest}>
      <div className="flex flex-col items-center gap-2 py-6 text-center">
        {icon && (
          <div className="text-ink-faint" aria-hidden>
            {icon}
          </div>
        )}
        <h2 className="text-lg font-semibold text-ink">{title}</h2>
        {body && <div className="max-w-sm text-sm text-ink-muted">{body}</div>}
        {action && <div className="mt-2">{action}</div>}
      </div>
    </Card>
  )
}
