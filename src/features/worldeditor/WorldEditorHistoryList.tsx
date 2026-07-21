import { Badge, Button, EmptyState, Skeleton } from '../../components/ui'
import type { WorldEditorAuditEntry } from './worldEditorAuditTypes'
import {
  deriveInactive,
  formatAuditTime,
  safeCommandLabel,
  safeTargetLabel,
  shortId,
  summarizeResult,
} from './worldEditorAuditView'

// WORLD EDITOR V1.5 — History list. Presentation only (no RPC). Read-only rows: NO mutation-like control
// of any kind — a row only SELECTS a record. Unknown command/target values render as `Unsupported: …`.

export type HistoryListPhase = 'loading' | 'loadingMore' | 'loaded' | 'empty'

interface Props {
  readonly entries: readonly WorldEditorAuditEntry[]
  readonly selectedId: string | null
  readonly onSelect: (id: string) => void
  readonly phase: HistoryListPhase
  readonly hasMore: boolean
  readonly onLoadMore: () => void
}

export function WorldEditorHistoryList({ entries, selectedId, onSelect, phase, hasMore, onLoadMore }: Props) {
  if (phase === 'loading') {
    return (
      <div className="flex flex-col gap-1.5" aria-busy="true" data-testid="history-loading">
        {[0, 1, 2].map((i) => (
          <Skeleton key={i} className="h-10 w-full" />
        ))}
      </div>
    )
  }
  if (phase === 'empty') {
    return <EmptyState title="No history" body="No audit records match these filters." />
  }
  return (
    <div className="flex flex-col gap-1.5">
      <ul className="flex flex-col gap-1">
        {entries.map((e) => {
          const inactive = deriveInactive(e)
          const on = selectedId === e.id
          return (
            <li key={e.id}>
              <button
                type="button"
                onClick={() => onSelect(e.id)}
                aria-pressed={on}
                className={`w-full rounded-md border px-2 py-1.5 text-left text-xs ${
                  on ? 'border-accent/60 bg-accent-soft text-ink' : 'border-edge bg-surface-2 text-ink-muted hover:border-accent/40'
                }`}
              >
                <div className="flex items-center justify-between gap-2">
                  <span className="font-mono text-ink">{safeCommandLabel(e.commandType)}</span>
                  <span className="text-ink-faint">{formatAuditTime(e.createdAt)}</span>
                </div>
                <div className="mt-0.5 flex flex-wrap items-center gap-1.5 text-ink-faint">
                  <Badge tone="neutral">{safeTargetLabel(e.targetType)}</Badge>
                  <span className="font-mono">{shortId(e.targetId)}</span>
                  <span>· {summarizeResult(e.result)}</span>
                  {e.sourceRevision ? <span>· rev {e.sourceRevision}</span> : null}
                  {inactive ? <Badge tone="warning">inactive</Badge> : null}
                  {e.redactions.length > 0 ? <Badge tone="neutral">redacted</Badge> : null}
                </div>
              </button>
            </li>
          )
        })}
      </ul>
      {hasMore ? (
        <Button size="sm" busy={phase === 'loadingMore'} disabled={phase === 'loadingMore'} onClick={onLoadMore}>
          {phase === 'loadingMore' ? 'Loading…' : 'Load more'}
        </Button>
      ) : (
        <p className="text-center text-[10px] uppercase tracking-wide text-ink-faint">End of results</p>
      )}
    </div>
  )
}
