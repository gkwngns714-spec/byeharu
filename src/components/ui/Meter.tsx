// Design-system progress/integrity meter (track + tonal fill). Display-only.

export type MeterTone = 'accent' | 'success' | 'danger' | 'neutral'

const TONE: Record<MeterTone, string> = {
  accent: 'bg-accent',
  success: 'bg-success',
  danger: 'bg-danger',
  neutral: 'bg-ink-faint/40',
}

export function Meter({
  pct,
  tone = 'accent',
  className = '',
}: {
  /** 0–100; clamped. */
  pct: number
  tone?: MeterTone
  className?: string
}) {
  const clamped = Math.max(0, Math.min(100, pct))
  return (
    <div className={`h-2 w-full overflow-hidden rounded bg-surface-2 ${className}`}>
      <div className={`h-full ${TONE[tone]} transition-all duration-300`} style={{ width: `${clamped}%` }} />
    </div>
  )
}
