import { useEffect, useRef, useState } from 'react'
import { Button, Notice } from '../../components/ui'
import { fetchWorldEditorAudit } from './worldEditorAuditData'
import { auditRecordWorldPoints } from './worldEditorAuditFocus'
import { safeCommandLabel, deriveInactive } from './worldEditorAuditView'
import {
  applyFailure,
  applyInitialSuccess,
  applyNextPageSuccess,
  beginInitial,
  beginNextPage,
  dispose,
  initialAuditRequestState,
  selectEntry,
  type AuditRequestState,
} from './worldEditorAuditRequestState'
import { describeAuditError, type WorldEditorAuditEntry, type WorldEditorAuditFilters } from './worldEditorAuditTypes'
import type { WorldEditorCommandResult } from './commandContract'
import type { WorldPoint } from './worldEditorTypes'
import { WorldEditorHistoryFilters } from './WorldEditorHistoryFilters'
import { WorldEditorHistoryList, type HistoryListPhase } from './WorldEditorHistoryList'
import { WorldEditorHistoryDetail } from './WorldEditorHistoryDetail'
import { useDraftGuard } from './useWorldEditorDraftGuard'

// WORLD EDITOR V1.5 — the History container. It owns the filter form + the historical-overlay callbacks
// and DRIVES the pure request-lifecycle coordinator (worldEditorAuditRequestState) — it keeps NO
// duplicate sequencing logic of its own. The coordinator (held in a ref, for synchronous generation
// tracking inside async callbacks) decides which responses are still current; a snapshot mirror drives
// rendering. The ONLY read path is fetchWorldEditorAudit → world_editor_audit_list (no table read, no
// service-role, no mutation). Presentation children never call the RPC.

/** What the History panel asks the shell to frame/outline as an EPHEMERAL historical overlay. */
export interface HistoricalFocus {
  readonly points: readonly WorldPoint[]
  readonly label: string
  readonly inactive: boolean
}

interface Props {
  readonly onFocusHistorical: (focus: HistoricalFocus) => void
  readonly onClearHistorical: () => void
  /** V4 — invoke the ONE server-authoritative revert (world_editor_revert, 0267) for an audit record.
   *  The shell issues the command + refetches the map on success; the panel then refetches its OWN
   *  History list (below). Returns the typed command result for the detail's inline notice. */
  readonly onRevert: (entry: WorldEditorAuditEntry) => Promise<WorldEditorCommandResult>
  /** V5 — re-read the live snapshot for the conflict "Reload live version" action (a revert hit an
   *  optimistic-concurrency conflict); never discards a draft. Passed straight to the detail. */
  readonly onReloadLive: () => void
}

const PAGE_SIZE = 25

export function WorldEditorHistoryPanel({ onFocusHistorical, onClearHistorical, onRevert, onReloadLive }: Props) {
  const guard = useDraftGuard()
  const [filters, setFilters] = useState<WorldEditorAuditFilters>({})

  // pure coordinator = source of truth (ref); snapshot mirror = render state
  const stateRef = useRef<AuditRequestState>(initialAuditRequestState())
  const [snapshot, setSnapshot] = useState<AuditRequestState>(stateRef.current)
  const commit = (s: AuditRequestState) => {
    stateRef.current = s
    setSnapshot(s)
  }

  const clearRef = useRef(onClearHistorical)
  clearRef.current = onClearHistorical
  const filtersRef = useRef(filters)
  filtersRef.current = filters

  const loadFirst = async (f: WorldEditorAuditFilters) => {
    const { state, gen } = beginInitial(stateRef.current)
    commit(state)
    clearRef.current() // any prior historical overlay is now stale
    const res = await fetchWorldEditorAudit({ ...f, limit: PAGE_SIZE })
    if (stateRef.current.disposed) return // no setState after unmount
    commit(res.ok ? applyInitialSuccess(stateRef.current, gen, res) : applyFailure(stateRef.current, gen, res))
  }

  const loadMore = async () => {
    const begun = beginNextPage(stateRef.current)
    if (!begun) return // no cursor, disposed, or a next-page already in flight
    const cursor = stateRef.current.cursor
    commit(begun.state)
    const res = await fetchWorldEditorAudit({ ...filtersRef.current, limit: PAGE_SIZE, cursor })
    if (stateRef.current.disposed) return
    commit(res.ok ? applyNextPageSuccess(stateRef.current, begun.gen, res) : applyFailure(stateRef.current, begun.gen, res))
  }

  // V4 — after a successful server revert, refetch the History list so the NEW audit row (the revert is
  // recorded as a normal, itself-revertable domain update) + the reverted values appear — WITHOUT clearing
  // the current selection, so the detail (and its success notice, keyed on the unchanged entry.id) stays
  // mounted. Single atomic commit (no loading-spinner intermediate) → the detail never unmounts. Reuses the
  // pure coordinator transitions (generation bump + applyInitialSuccess) — no duplicate sequencing.
  const refetchPreservingSelection = async () => {
    const keepId = stateRef.current.selectedId
    const { state, gen } = beginInitial(stateRef.current)
    stateRef.current = state // bump generation to invalidate any in-flight page; DO NOT render the cleared selection
    const res = await fetchWorldEditorAudit({ ...filtersRef.current, limit: PAGE_SIZE })
    if (stateRef.current.disposed) return
    let next = res.ok
      ? applyInitialSuccess(stateRef.current, gen, res)
      : applyFailure(stateRef.current, gen, res)
    if (res.ok && keepId && next.entries.some((e) => e.id === keepId)) next = selectEntry(next, keepId)
    commit(next)
  }

  // Invoke the shell's server revert (it refetches the map on success), then refetch OUR list on success.
  const handleRevert = async (entry: WorldEditorAuditEntry): Promise<WorldEditorCommandResult> => {
    const result = await onRevert(entry)
    if (result.ok) await refetchPreservingSelection()
    return result
  }

  useEffect(() => {
    void loadFirst({})
    return () => {
      stateRef.current = dispose(stateRef.current) // reject in-flight responses; no re-render after unmount
      clearRef.current()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const onFiltersChange = (next: WorldEditorAuditFilters) => {
    setFilters(next)
    void loadFirst(next) // beginInitial clears entries / cursor / selection / error
  }

  const onSelect = (id: string) => {
    // V5 GUARD — opening another history record is a context change; a dirty draft in the active domain
    // is confirmed away first (Keep editing / Discard and continue). Clean context opens immediately.
    guard.requestAction('open-history', () => {
      commit(selectEntry(stateRef.current, id))
      clearRef.current() // selecting a different record clears the previous historical overlay
    })
  }

  const selected = snapshot.selectedId
    ? snapshot.entries.find((e) => e.id === snapshot.selectedId) ?? null
    : null

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

  const listPhase: HistoryListPhase = snapshot.loadingInitial
    ? 'loading'
    : snapshot.nextPageInFlight
      ? 'loadingMore'
      : snapshot.entries.length === 0
        ? 'empty'
        : 'loaded'

  return (
    <section className="rounded-card border border-edge bg-surface p-3" data-testid="history-panel">
      <div className="mb-2 text-xs font-semibold uppercase tracking-wide text-ink-muted">History</div>

      <WorldEditorHistoryFilters filters={filters} onChange={onFiltersChange} disabled={snapshot.loadingInitial} />

      <div className="mt-2">
        {snapshot.error ? (
          <div className="flex flex-col gap-1.5">
            <Notice tone="danger">{describeAuditError(snapshot.error.error)}</Notice>
            <Button size="sm" onClick={() => void loadFirst(filters)}>
              Retry
            </Button>
          </div>
        ) : (
          <WorldEditorHistoryList
            entries={snapshot.entries}
            selectedId={snapshot.selectedId}
            onSelect={onSelect}
            phase={listPhase}
            hasMore={!!snapshot.cursor}
            onLoadMore={() => void loadMore()}
          />
        )}
      </div>

      {selected ? (
        <WorldEditorHistoryDetail
          entry={selected}
          onFocusMap={focusSelectedOnMap}
          onRevert={handleRevert}
          onReloadLive={onReloadLive}
        />
      ) : null}
    </section>
  )
}
