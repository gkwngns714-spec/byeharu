// Display-only time formatting (M6). NOT game logic: never authoritative, never
// computes combat results or rewards. All helpers are null/undefined-safe and only
// reformat values the server already produced.

export function formatShortTime(ts: string | null | undefined): string {
  if (!ts) return '—'
  const d = new Date(ts)
  if (Number.isNaN(d.getTime())) return '—'
  return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
}

export function formatDateTime(ts: string | null | undefined): string {
  if (!ts) return '—'
  const d = new Date(ts)
  if (Number.isNaN(d.getTime())) return '—'
  return d.toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })
}

export function formatDuration(seconds: number | null | undefined): string {
  if (seconds == null || !Number.isFinite(seconds) || seconds < 0) return '—'
  const s = Math.floor(seconds)
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const sec = s % 60
  if (h > 0) return `${h}h ${m}m`
  if (m > 0) return `${m}m ${sec.toString().padStart(2, '0')}s`
  return `${sec}s`
}

// Remaining time until a target timestamp, e.g. "2m 08s". Returns null when the
// target is missing/invalid/already elapsed, so callers pick the verb + fallback
// (e.g. `Arriving in ${formatCountdown(t) ?? '…'}`).
export function formatCountdown(targetTime: string | null | undefined): string | null {
  if (!targetTime) return null
  const t = new Date(targetTime).getTime()
  if (Number.isNaN(t)) return null
  const remainingMs = t - Date.now()
  if (remainingMs <= 0) return null
  const total = Math.ceil(remainingMs / 1000)
  const m = Math.floor(total / 60)
  const sec = total % 60
  return m > 0 ? `${m}m ${sec.toString().padStart(2, '0')}s` : `${sec}s`
}
