// WORLD EDITOR — V5: the OPTIMISTIC-CONCURRENCY conflict notice + explicit "Reload live version" action.
// When a publish / reactivate / revert command comes back with a LIVE-DRIFT conflict (stale_revision /
// conflict / source_missing / not_found — the ONE authority worldEditorDraftGuard.isLiveConflict), the
// client must NOT auto-overwrite or rebase the owner's work. This component states that the live entity
// changed, keeps the local draft AND the attempted values intact (it holds no draft state itself — it
// only surfaces the outcome), and offers "Reload live version" as an EXPLICIT owner action (re-reads the
// live snapshot). It renders nothing for a non-conflict error, so a command surface can mount it
// unconditionally beside its existing error copy. Presentation only — no store, no RPC, no draft mutation.
import { Button } from '../../components/ui'
import { describeWorldEditorError, type WorldEditorErrorCode } from './commandContract'
import { isLiveConflict } from './worldEditorDraftGuard'

export function WorldEditorConflictNotice({
  error,
  onReload,
  reloading = false,
}: {
  readonly error: WorldEditorErrorCode
  /** Re-read the live entity/snapshot (the shell's reloadData/reloadCatalog). Never discards the draft. */
  readonly onReload: () => void
  readonly reloading?: boolean
}) {
  if (!isLiveConflict(error)) return null
  return (
    <div
      className="flex flex-col gap-1.5 rounded-lg border border-warning/30 bg-warning/10 px-3 py-2 text-sm text-warning"
      data-testid="worldeditor-conflict-notice"
    >
      <span>
        {describeWorldEditorError(error)} The live version changed — your draft and the values you entered
        are kept, and nothing was overwritten.
      </span>
      <div>
        <Button
          variant="secondary"
          size="sm"
          onClick={onReload}
          busy={reloading}
          busyLabel="Reloading…"
          data-testid="worldeditor-reload-live"
        >
          Reload live version
        </Button>
      </div>
    </div>
  )
}
