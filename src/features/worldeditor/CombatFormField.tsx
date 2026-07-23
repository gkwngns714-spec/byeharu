// E4 — COMBAT CONTENT: the labeled field primitive (extends the ExplorationDraftPanel `Field` idiom) with
// an inline per-field error slot. Pure presentation — it holds no state and issues no command; the error
// string is resolved upstream by combatErrorMap. Kept deliberately tiny so every authoring sub-panel
// wears the exact same field skin (one visual language, map-UX plain-language law).
import type { ReactNode } from 'react'

export const COMBAT_INPUT =
  'w-full rounded-lg border border-edge bg-surface-2 px-2 py-1 text-sm text-ink disabled:opacity-45'
const FIELD_LABEL = 'text-xs text-ink-muted'
const FIELD_ERROR = 'text-xs text-danger'
// Subtle non-blocking authoring note (mirrors the MemberSetEditor elite_inert hint skin) — used to mark a
// knob the runtime resolver ignores today ("no runtime effect yet"). NEVER a Save gate, never an error.
const FIELD_HINT = 'text-xs text-ink-faint'

/** A labeled input/select wrapper with an inline error line and an optional advisory `hint` (a faint,
 *  non-blocking note, e.g. "recorded but has no runtime effect yet"). `error`/`hint` render only when set. */
export function CombatFormField({
  label,
  error,
  hint,
  children,
}: {
  label: string
  error?: string
  hint?: string
  children: ReactNode
}) {
  return (
    <label className="flex flex-col gap-0.5">
      <span className={FIELD_LABEL}>{label}</span>
      {children}
      {hint ? <span className={FIELD_HINT}>{hint}</span> : null}
      {error ? <span className={FIELD_ERROR}>{error}</span> : null}
    </label>
  )
}
