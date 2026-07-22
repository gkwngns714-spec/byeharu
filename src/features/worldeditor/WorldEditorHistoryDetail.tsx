import { useEffect, useState } from 'react'
import { Badge, Button, Notice } from '../../components/ui'
import { deriveAuditDiff, type AuditDiffClass } from './worldEditorAuditDiff'
import { auditRecordHasFocus } from './worldEditorAuditFocus'
import type { WorldEditorAuditEntry } from './worldEditorAuditTypes'
import { deriveInactive, formatAuditTime, safeCommandLabel, safeTargetLabel } from './worldEditorAuditView'
import { canRevertEntry } from './worldEditorHistoryRevert'
import { describeWorldEditorError, type WorldEditorCommandResult } from './commandContract'
import { useDraftGuard } from './useWorldEditorDraftGuard'
import { isLiveConflict } from './worldEditorDraftGuard'
import { WorldEditorConflictNotice } from './WorldEditorConflictNotice'

// WORLD EDITOR V1.5 — History record detail: operational metadata + semantic before/after diff +
// redaction metadata + a historical map-focus action + (V4) a "Revert to this version" action.
// The focus action is read-only (camera only). The revert action asks the SHELL to invoke the ONE
// server-authoritative revert (public.world_editor_revert, 0267) for this record — the detail itself
// opens no command/rpc path (the shell owns the transport; guarded by the History-slice source guards).
// It is offered ONLY for revertable rows (a location/mining/exploration/zone UPDATE with a non-null
// before — canRevertEntry). Because a revert is an IMMEDIATE server overwrite of the current live row, a
// one-step inline confirm precedes the fire; the outcome (success / typed error) renders as an inline
// notice. Historical state is clearly labelled so a snapshot never masquerades as the current live
// object; redactions are NEVER inferred.

interface Props {
  readonly entry: WorldEditorAuditEntry
  readonly onFocusMap: () => void
  /** Ask the shell to invoke world_editor_revert for this record (server overwrite → refetch map +
   *  History). Returns the typed command result — ok, or a typed error the notice surfaces via
   *  describeWorldEditorError. */
  readonly onRevert: (entry: WorldEditorAuditEntry) => Promise<WorldEditorCommandResult>
  /** V5 — re-read the live snapshot for the conflict "Reload live version" action (the revert hit an
   *  optimistic-concurrency conflict); never discards a draft. */
  readonly onReloadLive: () => void
}

const CLASS_TONE: Record<AuditDiffClass, string> = {
  added: 'text-success',
  removed: 'text-ink-faint line-through',
  changed: 'text-warning',
  unchanged: 'text-ink-muted',
}

export function WorldEditorHistoryDetail({ entry, onFocusMap, onRevert, onReloadLive }: Props) {
  const guard = useDraftGuard()
  const [showUnchanged, setShowUnchanged] = useState(false)
  const [showRaw, setShowRaw] = useState(false)
  // Revert control state: whether the one-step confirm is armed, whether a revert is in flight, and the
  // last attempt's typed result (for the inline notice). All reset whenever a different record is selected
  // (this component instance is reused across selections). Selection is PRESERVED across the post-success
  // refetch (same entry.id), so the success notice persists after the History list refreshes.
  const [confirming, setConfirming] = useState(false)
  const [reverting, setReverting] = useState(false)
  const [revertResult, setRevertResult] = useState<WorldEditorCommandResult | null>(null)
  useEffect(() => {
    setConfirming(false)
    setReverting(false)
    setRevertResult(null)
  }, [entry.id])

  const runRevert = async () => {
    setConfirming(false)
    setReverting(true)
    const result = await onRevert(entry)
    setRevertResult(result)
    setReverting(false)
  }

  const diff = deriveAuditDiff(entry.before, entry.after)
  const canFocus = auditRecordHasFocus(entry)
  const canRevert = canRevertEntry(entry)
  const inactive = deriveInactive(entry)

  return (
    <div className="mt-2 flex flex-col gap-2 border-t border-edge/60 pt-2" data-testid="history-detail">
      <div className="flex flex-wrap items-center gap-1.5">
        <span className="font-mono text-sm text-ink">{safeCommandLabel(entry.commandType)}</span>
        <Badge tone="neutral">historical</Badge>
        {!diff.hasBefore ? <Badge tone="success">created</Badge> : null}
        {inactive ? <Badge tone="warning">inactive / unpublished</Badge> : null}
      </div>
      <p className="text-[11px] text-ink-faint">
        Historical snapshot — this is a past record, not the current live world state.
      </p>

      {/* operational metadata */}
      <dl className="flex flex-col gap-0.5 text-xs">
        {(
          [
            ['Request ID', entry.requestId],
            ['Actor', entry.actorIsOwner ? 'owner' : 'other'],
            ['When', formatAuditTime(entry.createdAt)],
            ['Target', `${safeTargetLabel(entry.targetType)} · ${entry.targetId ?? '—'}`],
            ['Source revision', entry.sourceRevision ?? '—'],
          ] as const
        ).map(([k, v]) => (
          <div key={k} className="flex items-baseline justify-between gap-3 border-b border-edge/40 pb-0.5">
            <dt className="text-ink-muted">{k}</dt>
            <dd className="break-all text-right font-mono text-ink">{v}</dd>
          </div>
        ))}
      </dl>

      {entry.redactions.length > 0 ? (
        <Notice tone="neutral">
          Server-withheld fields (not shown): {entry.redactions.join(', ')}
        </Notice>
      ) : null}

      {canFocus ? (
        <Button size="sm" onClick={onFocusMap} title="Move the camera to this record's historical location (does not change the live selection).">
          Focus on map
        </Button>
      ) : null}

      {/* V4 — "Revert to this version": invoke the ONE server-authoritative revert (world_editor_revert,
          0267) for this record via the shell's onRevert prop — one click restores the entity to its
          before_snapshot server-side, then the map + History refetch. Offered ONLY for revertable rows (a
          location/mining/exploration/zone UPDATE with a non-null before). Because it IMMEDIATELY overwrites
          the current live row (owner + existence gated, NOT optimistic concurrency), a one-step inline
          confirm precedes the fire. The outcome renders inline: success, or a typed error via
          describeWorldEditorError. */}
      {canRevert ? (
        <div className="flex flex-col gap-1" data-testid="history-revert">
          {!confirming ? (
            <Button
              size="sm"
              disabled={reverting}
              onClick={() => {
                setRevertResult(null)
                setConfirming(true)
              }}
              title="Restore this item to its state before this change. This immediately overwrites the current live values on the server (owner-gated); the map and history then refresh."
            >
              {reverting ? 'Reverting…' : 'Revert to this version'}
            </Button>
          ) : (
            <div className="flex flex-col gap-1 rounded-md border border-warning/50 bg-surface-2 p-1.5">
              <p className="text-[11px] text-ink-muted">
                Immediately overwrite the current live values with this historical version? This cannot be undone
                except by another revert.
              </p>
              <div className="flex gap-1.5">
                <Button
                  size="sm"
                  variant="danger"
                  onClick={() =>
                    // V5 GUARD — reverting overwrites the live world (a context change); a dirty draft in
                    // the active domain is confirmed away first (Keep editing / Discard and continue).
                    guard.requestAction('revert', () => void runRevert())
                  }
                >
                  Confirm revert
                </Button>
                <Button size="sm" variant="ghost" onClick={() => setConfirming(false)}>
                  Cancel
                </Button>
              </div>
            </div>
          )}
          {revertResult?.ok ? (
            <Notice tone="success">Reverted — the live world and history now reflect the restored version.</Notice>
          ) : null}
          {revertResult && !revertResult.ok ? (
            isLiveConflict(revertResult.error) ? (
              // V5 CONFLICT — the live row changed under the revert (source_missing / not_found /
              // conflict): keep the record + offer an EXPLICIT "Reload live version" (no auto-overwrite).
              <WorldEditorConflictNotice error={revertResult.error} onReload={onReloadLive} />
            ) : (
              <Notice tone="danger">{describeWorldEditorError(revertResult.error)}</Notice>
            )
          ) : null}
        </div>
      ) : null}

      {/* semantic before/after diff */}
      <div className="flex flex-col gap-1">
        <div className="flex items-center justify-between">
          <span className="text-[10px] uppercase tracking-wide text-ink-faint">
            {diff.hasBefore ? 'Before → after' : 'Created values'} · {diff.changedCount} changed
          </span>
          <button
            type="button"
            className="text-[10px] uppercase tracking-wide text-ink-faint underline"
            onClick={() => setShowUnchanged((s) => !s)}
          >
            {showUnchanged ? 'hide unchanged' : 'show unchanged'}
          </button>
        </div>
        {diff.groups.map((g) => {
          const fields = g.fields.filter((f) => showUnchanged || f.klass !== 'unchanged')
          if (fields.length === 0) return null
          return (
            <div key={g.group} className="rounded-md border border-edge/50 bg-surface-2 p-1.5">
              <div className="mb-0.5 text-[10px] uppercase tracking-wide text-ink-faint">{g.group}</div>
              <dl className="flex flex-col gap-0.5 text-xs">
                {fields.map((f) => (
                  <div key={f.field} className="flex items-baseline justify-between gap-2">
                    <dt className="text-ink-muted">
                      {f.field}
                      {f.summarized ? <span className="ml-1 text-ink-faint">(summary)</span> : null}
                    </dt>
                    <dd className={`text-right ${CLASS_TONE[f.klass]}`}>
                      {f.klass === 'changed' ? (
                        <span>
                          <span className="text-ink-faint line-through">{f.before}</span>{' '}
                          <span className="text-ink">→ {f.after}</span>
                        </span>
                      ) : f.klass === 'removed' ? (
                        f.before
                      ) : (
                        f.after
                      )}
                    </dd>
                  </div>
                ))}
              </dl>
            </div>
          )
        })}
      </div>

      {/* secondary sanitized raw view — only the already-normalized (server-sanitized) fields */}
      <div>
        <button
          type="button"
          className="text-[10px] uppercase tracking-wide text-ink-faint underline"
          onClick={() => setShowRaw((s) => !s)}
        >
          {showRaw ? 'hide sanitized JSON' : 'show sanitized JSON'}
        </button>
        {showRaw ? (
          <pre className="mt-1 max-h-48 overflow-auto rounded-md border border-edge/50 bg-app p-1.5 text-[10px] text-ink-muted">
            {JSON.stringify({ before: entry.before, after: entry.after, result: entry.result, redactions: entry.redactions }, null, 2)}
          </pre>
        ) : null}
      </div>
    </div>
  )
}
