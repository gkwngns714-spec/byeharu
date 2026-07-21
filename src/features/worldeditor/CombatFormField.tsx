// E4 — COMBAT CONTENT: the labeled field primitive (extends the ExplorationDraftPanel `Field` idiom) with
// an inline per-field error slot. Pure presentation — it holds no state and issues no command; the error
// string is resolved upstream by combatErrorMap. Kept deliberately tiny so every authoring sub-panel
// wears the exact same field skin (one visual language, map-UX plain-language law).
import type { ReactNode } from 'react'

export const COMBAT_INPUT =
  'w-full rounded-lg border border-edge bg-surface-2 px-2 py-1 text-sm text-ink disabled:opacity-45'
const FIELD_LABEL = 'text-xs text-ink-muted'
const FIELD_ERROR = 'text-xs text-danger'

/** A labeled input/select wrapper with an inline error line. `error` renders only when present. */
export function CombatFormField({
  label,
  error,
  children,
}: {
  label: string
  error?: string
  children: ReactNode
}) {
  return (
    <label className="flex flex-col gap-0.5">
      <span className={FIELD_LABEL}>{label}</span>
      {children}
      {error ? <span className={FIELD_ERROR}>{error}</span> : null}
    </label>
  )
}
