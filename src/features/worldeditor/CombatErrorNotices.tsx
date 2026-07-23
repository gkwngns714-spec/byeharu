// E4 — COMBAT CONTENT: the typed error surface (mirrors ExplorationDraftPanel's PublishFailureNotices).
// Pure presentation: it renders the banner + any field messages a CombatErrorView already computed
// (combatErrorMap.mapCombatError). It issues no command and interprets no code itself — describe/translate
// happened upstream. Field-specific messages also render inline via CombatFormField; this surface shows
// the banner plus any messages that did NOT bind to a visible field, so nothing is silently dropped.
import { Notice } from '../../components/ui'
import type { WorldEditorCommandFailure } from './commandContract'
import { mapCombatError, type CombatTier } from './combatErrorMap'

/** Render a command failure as a danger banner + any un-fielded detail messages. `boundFields` are the
 *  fields already shown inline on the form, so their messages are not repeated here. */
export function CombatErrorNotices({
  failure,
  tier,
  boundFields = [],
}: {
  failure: WorldEditorCommandFailure
  tier: CombatTier
  boundFields?: readonly string[]
}) {
  const view = mapCombatError(failure, tier)
  const bound = new Set(boundFields)
  const leftover = Object.entries(view.fieldErrors).filter(([field]) => !bound.has(field))
  return (
    <div className="flex flex-col gap-1">
      <Notice tone="danger">{view.banner}</Notice>
      {leftover.map(([field, message]) => (
        <Notice key={field} tone="danger">
          {message}
        </Notice>
      ))}
    </div>
  )
}
