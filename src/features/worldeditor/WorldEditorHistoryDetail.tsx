import { useState } from 'react'
import { Badge, Button, Notice } from '../../components/ui'
import { deriveAuditDiff, type AuditDiffClass } from './worldEditorAuditDiff'
import { auditRecordHasFocus } from './worldEditorAuditFocus'
import type { WorldEditorAuditEntry } from './worldEditorAuditTypes'
import { deriveInactive, formatAuditTime, safeCommandLabel, safeTargetLabel } from './worldEditorAuditView'

// WORLD EDITOR V1.5 — History record detail: operational metadata + semantic before/after diff +
// redaction metadata + a historical map-focus action. STRICTLY read-only: the only interactive controls
// are display toggles (show/hide unchanged, sanitized JSON) and the camera focus action — never a
// state-changing control of any kind. Historical state is clearly labelled so a snapshot never
// masquerades as the current live object. Redacted values are NEVER inferred.

interface Props {
  readonly entry: WorldEditorAuditEntry
  readonly onFocusMap: () => void
}

const CLASS_TONE: Record<AuditDiffClass, string> = {
  added: 'text-success',
  removed: 'text-ink-faint line-through',
  changed: 'text-warning',
  unchanged: 'text-ink-muted',
}

export function WorldEditorHistoryDetail({ entry, onFocusMap }: Props) {
  const [showUnchanged, setShowUnchanged] = useState(false)
  const [showRaw, setShowRaw] = useState(false)
  const diff = deriveAuditDiff(entry.before, entry.after)
  const canFocus = auditRecordHasFocus(entry)
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
