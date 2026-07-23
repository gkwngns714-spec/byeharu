// WORLD EDITOR — V5: the unsaved-draft confirm DIALOG. Rendered once at the shell; it reads the shared
// guard from context and shows ONLY when a context-changing action was intercepted because it would
// abandon a DIRTY draft. Exactly TWO actions, per spec:
//   • "Keep editing"        → cancel the requested action; selection, camera and every draft are preserved.
//   • "Discard and continue" → discard ONLY the affected draft(s), then perform the original action.
// It adds NO autosave and NEVER discards a draft on its own — every discard is an explicit owner choice
// routed through the guard's discardAndContinue (which calls the SAME store.discardDraft the panels use).
import { Button } from '../../components/ui'
import type { GuardedActionKind } from './worldEditorDraftGuard'
import { useDraftGuard } from './useWorldEditorDraftGuard'

/** What the owner was trying to do — the ONE authority for the dialog's headline copy (per action). */
const ACTION_HEADLINE: Record<GuardedActionKind, string> = {
  'select-entity': 'Select another entity?',
  'search-jump': 'Jump to this search result?',
  'camera-jump': 'Jump to this coordinate?',
  'switch-domain': 'Switch authoring domain?',
  'change-filter': 'Change the lifecycle filter?',
  'open-history': 'Open this history record?',
  revert: 'Revert to this version?',
  unpublish: 'Unpublish this zone?',
  reactivate: 'Reactivate this entity?',
  'leave-route': 'Leave the World Editor?',
  'before-unload': 'Leave this page?',
}

export function PendingDraftsDialog() {
  const guard = useDraftGuard()
  const pending = guard.pending
  if (!pending) return null

  const count = pending.affected.length
  const draftWord = count === 1 ? 'draft' : 'drafts'

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
      role="dialog"
      aria-modal="true"
      aria-labelledby="pending-drafts-title"
      data-testid="pending-drafts-dialog"
      onClick={(e) => {
        // click on the backdrop = keep editing (safe default: never discards)
        if (e.target === e.currentTarget) guard.keepEditing()
      }}
    >
      <div className="w-full max-w-sm rounded-card border border-edge bg-surface p-4 text-ink shadow-card">
        <h2 id="pending-drafts-title" className="text-base font-semibold">
          {ACTION_HEADLINE[pending.kind]}
        </h2>
        <p className="mt-2 text-sm text-ink-muted">
          You have {count} unsaved {draftWord} in the current authoring context. Continuing will discard{' '}
          {count === 1 ? 'it' : 'them'}. Unpublished work in other domains is not affected.
        </p>
        <div className="mt-4 flex justify-end gap-2">
          <Button
            variant="secondary"
            size="sm"
            onClick={guard.keepEditing}
            data-testid="pending-drafts-keep"
            autoFocus
          >
            Keep editing
          </Button>
          <Button
            variant="danger"
            size="sm"
            onClick={guard.discardAndContinue}
            data-testid="pending-drafts-discard"
          >
            Discard and continue
          </Button>
        </div>
      </div>
    </div>
  )
}
