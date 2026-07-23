import { useRef, useState } from 'react'
import { Button } from '../../components/ui'
import { invokeWorldEditorCommand } from './commandClient'
import { describeWorldEditorError, newRequestId, type WorldEditorErrorCode, type WorldEditorFailureDetail } from './commandContract'
import { formatWorldCoord } from './worldEditorCoordinates'
import { fetchWorldEditorEntityDetail } from './worldEditorEntityDetail'
import {
  catalogReactivateEnvelope,
  detailReactivateEnvelope,
  reactivationNeedsDetail,
} from './worldEditorReactivate'
import type { CatalogDomain, WorldEditorCatalogRow } from './worldEditorCatalog'
import { useDraftGuard } from './useWorldEditorDraftGuard'
import { isLiveConflict } from './worldEditorDraftGuard'
import { WorldEditorConflictNotice } from './WorldEditorConflictNotice'

// WORLD EDITOR — V5 LIFECYCLE: the read-only inspector + REACTIVATE action for a selected INACTIVE
// catalog entity. An inactive entity is NOT in any active gameplay reader, so its detail comes from the
// 0269 catalog row (name / point-or-geometry / lifecycle) and — for zone/location — the 0270 detail
// reader supplies the optimistic-concurrency `expected` VERBATIM. This surface shows NO active-only
// edit/publish controls (an inactive entity can only be REACTIVATED); the active inspector + authoring
// controls render for active selections instead. Server is_owner() is the sole authority.
//
// REFINEMENTS (§WE.13 V5): the catalog row's revision is null everywhere → the field is NEVER shown
// and NEVER derived from the history ledger. updated_at is shown ONLY when non-null (zones only). After
// a successful reactivation the shell refreshes BOTH the catalog and the active domain reader
// (onReactivated) and retains selection + camera; the row then reads active and the active inspector
// takes over.

const DOMAIN_LABEL: Record<CatalogDomain, string> = {
  location: 'Location',
  mining: 'Mining field',
  exploration: 'Exploration site',
  zone: 'Zone',
}

type Phase =
  | { readonly kind: 'idle' }
  | { readonly kind: 'sending' }
  | { readonly kind: 'failed'; readonly error: WorldEditorErrorCode; readonly details?: ReadonlyArray<WorldEditorFailureDetail> }

/** A concise text summary of the row's geometry-or-point (never a second projection — display only). */
function representationSummary(row: WorldEditorCatalogRow): string {
  if (row.geometry) {
    const centroid = row.point ? ` · centroid ${formatWorldCoord(row.point.x)}, ${formatWorldCoord(row.point.y)}` : ''
    return `Polygon · ${row.geometry.ring.length} vertices${centroid}`
  }
  if (row.point) return `${formatWorldCoord(row.point.x)}, ${formatWorldCoord(row.point.y)}`
  return '—'
}

export function WorldEditorInactiveInspector({
  row,
  onReactivated,
  onReloadLive,
}: {
  readonly row: WorldEditorCatalogRow
  /** Fired after a successful reactivation — the shell refreshes the catalog AND the active domain
   *  reader (reloadData) and retains selection + camera. */
  readonly onReactivated: () => void | Promise<void>
  /** V5 — re-read the live snapshot for the conflict "Reload live version" action (the live entity
   *  changed under the reactivate); never discards a draft. */
  readonly onReloadLive: () => void
}) {
  const guard = useDraftGuard()
  const [phase, setPhase] = useState<Phase>({ kind: 'idle' })
  // One idempotency key per entity attempt; a retry of the SAME entity reuses it (idempotent replay).
  // The shell keys this component by the selection id, so the ref resets when a different entity is picked.
  const requestIdRef = useRef<string | null>(null)
  const busy = phase.kind === 'sending'

  const onReactivate = async () => {
    if (busy) return
    setPhase({ kind: 'sending' })
    const requestId = requestIdRef.current ?? newRequestId()
    requestIdRef.current = requestId

    if (reactivationNeedsDetail(row)) {
      // ZONE / LOCATION: fetch the 0270 detail snapshot, then invoke with `expected` VERBATIM.
      const detail = await fetchWorldEditorEntityDetail(row.domain, row.entityId)
      if (!detail.ok) {
        setPhase({ kind: 'failed', error: detail.error, details: detail.details })
        return
      }
      const result = await invokeWorldEditorCommand(
        detailReactivateEnvelope(row.domain, row.entityId, detail.reactivationExpected, requestId),
      )
      if (result.ok) {
        requestIdRef.current = null
        setPhase({ kind: 'idle' })
        await onReactivated()
      } else {
        setPhase({ kind: 'failed', error: result.error, details: result.details })
      }
      return
    }

    // MINING / EXPLORATION: reactivate straight from the catalog row (NO detail call).
    const result = await invokeWorldEditorCommand(catalogReactivateEnvelope(row, requestId))
    if (result.ok) {
      requestIdRef.current = null
      setPhase({ kind: 'idle' })
      await onReactivated()
    } else {
      setPhase({ kind: 'failed', error: result.error, details: result.details })
    }
  }

  return (
    <div className="mt-2 flex flex-col gap-2" data-testid="worldeditor-inactive-inspector">
      <div className="flex items-center gap-2">
        <span className="text-xs text-accent">{DOMAIN_LABEL[row.domain]}</span>
        <span
          className="rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-ink-faint bg-surface-2"
          data-testid="worldeditor-inactive-badge"
        >
          Inactive
        </span>
      </div>

      <dl className="flex flex-col gap-1">
        <div className="flex items-baseline justify-between gap-3 border-b border-edge/50 pb-1 text-sm">
          <dt className="text-ink-muted">Name</dt>
          <dd className="text-right text-ink">{row.name}</dd>
        </div>
        <div className="flex items-baseline justify-between gap-3 border-b border-edge/50 pb-1 text-sm">
          <dt className="text-ink-muted">ID</dt>
          <dd className="text-right text-ink break-all">{row.entityId}</dd>
        </div>
        <div className="flex items-baseline justify-between gap-3 border-b border-edge/50 pb-1 text-sm">
          <dt className="text-ink-muted">{row.geometry ? 'Geometry' : 'Coordinates'}</dt>
          <dd className="text-right text-ink">{representationSummary(row)}</dd>
        </div>
        {/* revision is null for every catalog row → NEVER rendered. updated_at ONLY when non-null. */}
        {row.updatedAt != null && (
          <div className="flex items-baseline justify-between gap-3 border-b border-edge/50 pb-1 text-sm">
            <dt className="text-ink-muted">Updated</dt>
            <dd className="text-right text-ink">{row.updatedAt}</dd>
          </div>
        )}
      </dl>

      <div>
        <Button
          size="sm"
          disabled={busy}
          onClick={() => {
            // V5 GUARD — reactivating is a context-changing live command; a dirty draft in the active
            // domain is confirmed away first (Keep editing / Discard and continue).
            guard.requestAction('reactivate', () => {
              void onReactivate()
            })
          }}
          data-testid="worldeditor-reactivate"
          title="Reactivate this entity: it returns to the live world. Owner-only; the server applies and returns the new status."
        >
          {busy ? 'Reactivating…' : 'Reactivate'}
        </Button>
        <p className="mt-1.5 text-xs text-ink-faint">
          Inactive entities can only be reactivated — active-only editing is unavailable until it is live again.
        </p>
      </div>

      {phase.kind === 'failed' && (
        <>
          {/* V5 CONFLICT — the live entity changed under the reactivate (optimistic concurrency): keep the
              local work and offer an EXPLICIT "Reload live version" (self-hides for non-conflict errors). */}
          <WorldEditorConflictNotice error={phase.error} onReload={onReloadLive} />
          {!isLiveConflict(phase.error) && (
            <div className="rounded-md border border-edge bg-surface-2 px-2 py-1 text-xs text-ink" data-testid="worldeditor-reactivate-error">
              <div>{describeWorldEditorError(phase.error)}</div>
              {phase.details?.map((d, i) => (
                <div key={`${d.code}-${i}`} className="text-ink-faint">
                  {d.message ?? d.code}
                </div>
              ))}
            </div>
          )}
        </>
      )}
    </div>
  )
}
