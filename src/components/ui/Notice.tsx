import type { HTMLAttributes } from 'react'

// Design-system inline notice (soft tinted callout for warnings/errors/confirmations).
// Spreads rest props so data-testid passes through untouched.

export type NoticeTone = 'accent' | 'success' | 'warning' | 'danger' | 'neutral'

const TONE: Record<NoticeTone, string> = {
  accent: 'border-accent/30 bg-accent/10 text-accent',
  success: 'border-success/30 bg-success/10 text-success',
  warning: 'border-warning/30 bg-warning/10 text-warning',
  danger: 'border-danger/30 bg-danger/10 text-danger',
  neutral: 'border-edge bg-surface-2 text-ink-muted',
}

export function Notice({
  tone = 'neutral',
  className = '',
  children,
  ...rest
}: HTMLAttributes<HTMLElement> & { tone?: NoticeTone }) {
  return (
    <p className={`rounded-lg border px-3 py-2 text-sm ${TONE[tone]} ${className}`} {...rest}>
      {children}
    </p>
  )
}
