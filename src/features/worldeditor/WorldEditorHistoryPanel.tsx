import { useEffect, useRef, useState } from 'react'
import { Button, Notice } from '../../components/ui'
import { fetchWorldEditorAudit } from './worldEditorAuditData'
import { auditRecordWorldPoints } from './worldEditorAuditFocus'
import { safeCommandLabel, deriveInactive, mergePageDedup } from './worldEditorAuditView'
import {
  describeAuditError,
  type WorldEditorAuditEntry,
  type WorldEditorAuditFailure,
  type WorldEditorAuditFilters,
} from './worldEditorAuditTypes'
import type { WorldPoint } from './worldEditorTypes'
import { WorldEditorHistoryFilters } from './WorldEditorHistoryFilters'
import { WorldEditorHistoryList, type HistoryListPhase } from './WorldEditorHistoryList'
import { WorldEditorHistoryDetail } from './WorldEditorHistoryDetail'

// WORLD EDITOR V1.5 — the History container. Owns filters / entries / cursor / selection / loading &
// error state / REQUEST SEQUENCING (a monotonic generation token bumped on every filter change so a
// stale first-load or next-page can never replace a newer result) / the historical-overlay callbacks.
// Presentation children never call the RPC. The ONLY read path is fetchWorldEditorAudit → the deployed
// world_editor_audit_list RPC (no direct table read, no service-role, no mutation).

/** What the History panel asks the shell to frame/outline as an EPHEMERAL historical overlay. */
export interface HistoricalFocus {
  readonly points: readonly WorldPoint[]
  readonly label: string
  readonly inactive: boolean
}

interface Props {
  readonly onFocusHistorical: (focus: HistoricalFocus) => void
  readonly onClearHistorical: () => void
}

const PAGE_SIZE = 25

export function WorldEditorHistoryPanel({ onFocusHistorical, onClearHistorical }: Props) {
  const [filters, setFilters] = useState<WorldEditorAuditFilters>({})
  const [entries, setEntries] = useState<readonly WorldEditorAuditEntry[]>([])
  const [nextCursor, setNextCursor] = useState<WorldEditorAuditFilters['cursor']>(null)
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [phase, setPhase] = useState<'loading' | 'loadingMore' | 'loaded' | 'error'>('loading')
  const [error, setError] = useState<WorldEditorAuditFailure | null>(null)

  // monotonic request generation (bumped ONLY on a fresh first-load, so a next-page never invalidates it)
  const genRef = useRef(0)
  const mountedRef = useRef(true)
  const clearRef = useRef(onClearHistorical)
  clearRef.current = onClearHistorical

  const loadFirst = async (f: WorldEditorAuditFilters) => {
    const gen = ++genRef.current
    setEntries([])
    setNextCursor(null)
    setSelectedId(null)
    clearRef.current() // any prior historical overlay is stale
    setError(null)
    setPhase('loading')
    const res = await fetchWorldEditorAudit({ ...f, limit: PAGE_SIZE })
    if (!mountedRef.current || gen !== genRef.current) return // superseded by a newer filter change
    if (!res.ok) {
      setError(res)
      setPhase('error')
      return
    }
    setEntries(res.items)
    setNextCursor(res.nextCursor)
    setPhase('loaded')
  }

  const loadMore = async () => {
    if (!nextCursor || phase !== 'loaded') return
    const gen = genRef.current // do NOT bump — a filter change (which bumps) must invalidate this
    setPhase('loadingMore')
    const res = await fetchWorldEditorAudit({ ...filters, limit: PAGE_SIZE, cursor: nextCursor })
    if (!mountedRef.current || gen !== genRef.current) return // a filter change superseded this page
    if (!res.ok) {
      setError(res)
      setPhase('error')
      return
    }
    setEntries((prev) => mergePageDedup(prev, res.items)) // dedup by id — never duplicate rows across pages
    setNextCursor(res.nextCursor)
    setPhase('loaded')
  }

  // initial load + unmount guard (invalidate in-flight requests, clear the overlay)
  useEffect(() => {
    mountedRef.current = true
    void loadFirst({})
    return () => {
      mountedRef.current = false
      genRef.current++
      clearRef.current()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const onFiltersChange = (next: WorldEditorAuditFilters) => {
    setFilters(next)
    void loadFirst(next) // resets entries/cursor/selection/overlay via loadFirst
  }

  const onSelect = (id: string) => {
    setSelectedId(id)
    clearRef.current() // selecting a different record clears the previous historical overlay
  }

  const selected = selectedId ? entries.find((e) => e.id === selectedId) ?? null : null

  const focusSelectedOnMap = () => {
    if (!selected) return
    const points = auditRecordWorldPoints(selected)
    if (points.length === 0) return
    onFocusHistorical({
      points,
      label: `${safeCommandLabel(selected.commandType)} · ${selected.targetId ?? ''}`,
      inactive: deriveInactive(selected),
    })
  }

  const listPhase: HistoryListPhase =
    phase === 'loading'
      ? 'loading'
      : phase === 'loadingMore'
        ? 'loadingMore'
        : entries.length === 0
          ? 'empty'
          : 'loaded'

  return (
    <section className="rounded-card border border-edge bg-surface p-3" data-testid="history-panel">
      <div className="mb-2 text-xs font-semibold uppercase tracking-wide text-ink-muted">History</div>

      <WorldEditorHistoryFilters filters={filters} onChange={onFiltersChange} disabled={phase === 'loading'} />

      <div className="mt-2">
        {phase === 'error' && error ? (
          <div className="flex flex-col gap-1.5">
            <Notice tone="danger">{describeAuditError(error.error)}</Notice>
            <Button size="sm" onClick={() => void loadFirst(filters)}>
              Retry
            </Button>
          </div>
        ) : (
          <WorldEditorHistoryList
            entries={entries}
            selectedId={selectedId}
            onSelect={onSelect}
            phase={listPhase}
            hasMore={!!nextCursor}
            onLoadMore={() => void loadMore()}
          />
        )}
      </div>

      {selected ? <WorldEditorHistoryDetail entry={selected} onFocusMap={focusSelectedOnMap} /> : null}
    </section>
  )
}
