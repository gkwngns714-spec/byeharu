import { useState } from 'react'
import { Button } from '../../components/ui'
import { invokeWorldEditorCommand } from './commandClient'
import { describeWorldEditorError, newRequestId, type WorldEditorCommandFailure } from './commandContract'
import type { DangerZoneLite } from '../map/pirateApi'
import {
  isZoneToggleable,
  zoneLifecycleAction,
  zoneStatusCommandPayload,
  type ZoneLifecycleStatus,
  type ZoneStatusCommandPayload,
} from './zoneLifecycle'
import { useDraftGuard } from './useWorldEditorDraftGuard'
import { isLiveConflict } from './worldEditorDraftGuard'
import { WorldEditorConflictNotice } from './WorldEditorConflictNotice'

// WORLD EDITOR — the owner-only LIFECYCLE actions for a selected LIVE danger zone. Two COMPLEMENTARY
// owner-gated commands over ONE danger_zones row's status: zone_unpublish (0255, active → inactive — the
// SOLE unpublish path, unchanged) and zone_set_active (0268, inactive → active — the reactivate that
// closes the parity gap). Each issues the REAL owner-gated command through the ONE command transport; the
// server is_owner() guard is the sole authority — this control grants nothing. NO client-side success
// simulation: the row only changes after the server applies and returns the new status.
//
// The editor's live read (get_danger_zones) is active-rows-only, so a freshly-selected zone starts
// ACTIVE (Unpublish shown). A successful command flips the LOCAL presentational `status` (server is the
// authority), so the complementary action (Reactivate) becomes reachable in the SAME session — the exact
// 0250 exploration/mining set_active precedent (a successful toggle flips a local assumption). Selection
// and camera are untouched. One idempotency key per DIRECTION attempt; a retry of the same direction
// replays idempotently, never double-applies; switching direction mints a fresh key.

type Phase =
  | { readonly kind: 'idle' }
  | { readonly kind: 'sending' }
  | { readonly kind: 'failed'; readonly failure: WorldEditorCommandFailure }

interface ZoneStatusResult {
  readonly id: string
  readonly name: string
  readonly status: ZoneLifecycleStatus
  /** zone_set_active carries set_active:true; zone_unpublish carries unpublished:true. */
  readonly set_active?: boolean
  readonly unpublished?: boolean
}

export function ZoneInspectorActions({
  zone,
  onApplied,
  onReloadLive,
}: {
  zone: DangerZoneLite
  /** Fired after a successful status change with the row's NEW status — the shell may refresh History
   *  and any dependent view. Selection + camera are intentionally NOT touched here. */
  onApplied?: (status: ZoneLifecycleStatus) => void
  /** V5 — re-read the live snapshot for the conflict "Reload live version" action (the live zone changed
   *  under the unpublish/reactivate); never discards a draft. */
  onReloadLive: () => void
}) {
  const guard = useDraftGuard()
  // LOCAL presentational status — the live read is active-only, so a selected zone starts active; a
  // successful command flips this so the complementary action becomes reachable (0250 precedent).
  const [status, setStatus] = useState<ZoneLifecycleStatus>('active')
  const [phase, setPhase] = useState<Phase>({ kind: 'idle' })
  // One idempotency key per DIRECTION; a retry of the SAME direction reuses it (idempotent replay).
  const [attempt, setAttempt] = useState<{ readonly to: ZoneLifecycleStatus; readonly requestId: string } | null>(null)

  const toggleable = isZoneToggleable(zone) // seeded 'circle' zones are protected server-side
  const action = zoneLifecycleAction(status)
  const busy = phase.kind === 'sending'

  const onRun = async () => {
    const to = action.nextStatus
    const requestId = attempt && attempt.to === to ? attempt.requestId : newRequestId()
    setAttempt({ to, requestId })
    setPhase({ kind: 'sending' })
    const result = await invokeWorldEditorCommand<ZoneStatusResult, ZoneStatusCommandPayload>({
      requestId,
      commandType: action.commandType,
      payload: zoneStatusCommandPayload(zone),
    })
    if (result.ok) {
      // Replace the local status from the server's authoritative response (fallback to the intended
      // direction on a bare replay), clear the action state, and notify the shell. Selection persists.
      const next: ZoneLifecycleStatus = result.result?.status ?? to
      setStatus(next)
      setPhase({ kind: 'idle' })
      setAttempt(null)
      onApplied?.(next)
    } else {
      setPhase({ kind: 'failed', failure: result })
    }
  }

  return (
    <div className="mt-2 flex flex-col gap-1.5">
      <div className="flex items-center gap-2">
        <span className="text-xs font-semibold uppercase tracking-wide text-ink-faint">Live zone</span>
        <span
          className={
            status === 'active'
              ? 'rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-emerald-300 bg-emerald-500/10'
              : 'rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-ink-faint bg-surface-2'
          }
        >
          {status}
        </span>
      </div>
      <Button
        size="sm"
        disabled={!toggleable || busy}
        title={
          toggleable ? action.title : 'Only editor-created (drawn) zones can be reactivated or unpublished; this is a seeded zone.'
        }
        onClick={() => {
          // V5 GUARD — unpublish/reactivate is a context-changing live command; a dirty draft in the
          // active domain is confirmed away first (Keep editing / Discard and continue).
          guard.requestAction(status === 'active' ? 'unpublish' : 'reactivate', () => {
            void onRun()
          })
        }}
      >
        {busy ? action.busyLabel : action.label}
      </Button>
      {phase.kind === 'failed' && (
        <>
          {/* V5 CONFLICT — the live zone changed under the command (optimistic concurrency): keep the
              local work and offer an EXPLICIT "Reload live version" (self-hides for non-conflict errors). */}
          <WorldEditorConflictNotice error={phase.failure.error} onReload={onReloadLive} />
          {!isLiveConflict(phase.failure.error) && (
            <div className="rounded-md border border-edge bg-surface-2 px-2 py-1 text-xs text-ink">
              <div>{describeWorldEditorError(phase.failure.error)}</div>
              {phase.failure.details?.map((d, i) => (
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
