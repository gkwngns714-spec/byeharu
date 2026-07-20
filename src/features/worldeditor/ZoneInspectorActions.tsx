import { useState } from 'react'
import { Button } from '../../components/ui'
import { invokeWorldEditorCommand } from './commandClient'
import { describeWorldEditorError, newRequestId, type WorldEditorCommandFailure } from './commandContract'
import type { DangerZoneLite } from '../map/pirateApi'

// WORLD EDITOR — the owner-only UNPUBLISH action for a selected LIVE danger zone (0255 zone_unpublish,
// the twin of 0254 zone_create). It issues the REAL owner-gated command through the ONE command
// transport; the server is_owner() guard is the sole authority — this control grants nothing. NO
// client-side success simulation: the zone only leaves the player map + interception after the server
// applies status='inactive' and the snapshot reloads. Until the 0255 RPC is deployed the call returns
// a typed error (transport/undefined-function) and the map is unchanged — never a faked success.
//
// The requestId is minted ONCE per mounted action and reused on retry, so a retry after a transient
// failure is an idempotent replay of the SAME command, never a second apply.

type Phase =
  | { readonly kind: 'idle' }
  | { readonly kind: 'sending' }
  | { readonly kind: 'failed'; readonly failure: WorldEditorCommandFailure }
  | { readonly kind: 'done' }

interface ZoneUnpublishResult {
  readonly unpublished: boolean
  readonly id: string
  readonly name: string
  readonly status: string
}

export function ZoneInspectorActions({
  zone,
  onUnpublished,
}: {
  zone: DangerZoneLite
  onUnpublished: () => void
}) {
  const [phase, setPhase] = useState<Phase>({ kind: 'idle' })
  // One idempotency key per mounted action — a retry replays, never double-applies.
  const [requestId] = useState(() => newRequestId())

  // Only editor-created ('drawn') zones are unpublishable; seeded 'circle' zones are protected
  // server-side (not_unpublishable / protected_zone). Reflect that in the control rather than inviting
  // an action the server will reject.
  const eligible = zone.source === 'drawn'
  const busy = phase.kind === 'sending' || phase.kind === 'done'

  const onUnpublish = async () => {
    setPhase({ kind: 'sending' })
    const result = await invokeWorldEditorCommand<ZoneUnpublishResult>({
      requestId,
      commandType: 'zone_unpublish',
      payload: {
        target_id: zone.id,
        // the fork-time sourceSnapshot the server compares value-by-value (optimistic concurrency):
        // the stable identity the zone read exposes. Geometry is not compared (an unpublish never
        // touches it, and a float ring compare is fragile).
        expected: { name: zone.name, source: zone.source, location_id: zone.location_id },
      },
    })
    if (result.ok) {
      setPhase({ kind: 'done' })
      onUnpublished()
    } else {
      setPhase({ kind: 'failed', failure: result })
    }
  }

  return (
    <div className="mt-2 flex flex-col gap-1.5">
      <div className="text-xs font-semibold uppercase tracking-wide text-ink-faint">Live zone</div>
      <Button
        size="sm"
        disabled={!eligible || busy}
        title={
          eligible
            ? 'Unpublish this zone (status → inactive): it leaves the player map and pirate interception at once; the row, geometry and attachment are preserved for a future republish.'
            : 'Only editor-created (drawn) zones can be unpublished; this is a seeded zone.'
        }
        onClick={() => {
          void onUnpublish()
        }}
      >
        {phase.kind === 'sending' ? 'Unpublishing…' : phase.kind === 'done' ? 'Unpublished' : 'Unpublish zone'}
      </Button>
      {phase.kind === 'failed' && (
        <div className="rounded-md border border-edge bg-surface-2 px-2 py-1 text-xs text-ink">
          <div>{describeWorldEditorError(phase.failure.error)}</div>
          {phase.failure.details?.map((d, i) => (
            <div key={`${d.code}-${i}`} className="text-ink-faint">
              {d.message ?? d.code}
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
