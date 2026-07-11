import type { HTMLAttributes } from 'react'

// Design-system Skeleton: the ONE loading placeholder — a pulsing tokenized block. Size it via
// className (h-32, w-24, rounded-card, …); decorative (aria-hidden) — keep a sr-only status
// line next to a skeleton group for screen readers.

export function Skeleton({ className = '', ...rest }: HTMLAttributes<HTMLDivElement>) {
  return <div className={`animate-pulse rounded bg-surface-2 ${className}`} aria-hidden="true" {...rest} />
}
