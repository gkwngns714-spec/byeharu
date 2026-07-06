import type { ReactNode } from 'react'

// Design-system status pill (uppercase micro-badge). Tones are semantic — callers map their
// domain states (moving/present/destroyed…) to a tone, never to raw colors.

export type BadgeTone = 'neutral' | 'accent' | 'success' | 'warning' | 'danger'

const TONE: Record<BadgeTone, string> = {
  neutral: 'bg-surface-2 text-ink-muted',
  accent: 'bg-accent/15 text-accent',
  success: 'bg-success/15 text-success',
  warning: 'bg-warning/15 text-warning',
  danger: 'bg-danger/15 text-danger',
}

export function Badge({ tone = 'neutral', children }: { tone?: BadgeTone; children: ReactNode }) {
  return (
    <span className={`rounded px-2 py-0.5 text-[10px] uppercase tracking-wide ${TONE[tone]}`}>
      {children}
    </span>
  )
}
