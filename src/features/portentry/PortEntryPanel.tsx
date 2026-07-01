import { useRef } from 'react'
import { usePortEntry, type UsePortEntryOverrides } from './usePortEntry'
import type { PortEntryActionKind } from './portEntryCommand'

// PORT-ENTRY player UI — the single onboarding / finish-docking surface for the caller's OWN main ship.
//
// Renders exactly ONE affordance derived from server-authoritative state:
//   • no ship            → "Claim First Ship"  (commission_first_main_ship)
//   • legacy_present     → "Finish Docking"    (normalize_main_ship_dock)
//   • at_location        → nothing (the ordinary docked experience is the Phase-9 DockServicesPanel)
//   • home / legacy_home → a read-only explanation (no in-place docking path exists yet — travel to a port)
//   • in_transit / in_space / destroyed / contradictory → a read-only safe explanation, no action
//
// The two actions are zero-arg and auth.uid()-scoped; the client sends no ids/coords/status. Duplicate
// submits are prevented (a synchronous ref guard + the controller's single-in-flight phase guard); the button
// is disabled while working. On success the panel re-reads authoritative state and notifies the parent. It
// NEVER fabricates eligibility or performs a client-side transition — the server is the sole authority.

const CARD = 'rounded-xl border p-4 text-sm'

export function PortEntryPanel({ deps }: { deps?: UsePortEntryOverrides }) {
  const pe = usePortEntry(deps)
  const { affordance, phase, actionKind, message } = pe
  const busy = phase === 'submitting'
  const sendingRef = useRef(false)

  async function run(kind: PortEntryActionKind) {
    if (sendingRef.current) return // synchronous duplicate-click guard (belt-and-suspenders with the controller)
    sendingRef.current = true
    try {
      await pe.submit(kind)
    } finally {
      sendingRef.current = false
    }
  }

  // A successful action persists a brief confirmation until dismissed (the affordance underneath has already
  // moved to 'docked' → null, so without this the success would vanish instantly).
  if (phase === 'success') {
    return (
      <div data-testid="port-entry-panel">
        <div className={`${CARD} border-emerald-500/30 bg-emerald-500/10 text-emerald-200`} data-testid="port-entry-success">
          <p data-testid="port-entry-success-message">{message}</p>
          <button
            data-testid="port-entry-success-dismiss"
            onClick={() => pe.reset()}
            className="mt-3 rounded-lg border border-emerald-400/40 px-3 py-1.5 text-emerald-100 transition hover:bg-emerald-500/20"
          >
            Done
          </button>
        </div>
      </div>
    )
  }

  const errorText = phase === 'error' ? message : null

  switch (affordance.kind) {
    case 'commission':
      return (
        <div data-testid="port-entry-panel">
          <div className={`${CARD} border-indigo-400/30 bg-indigo-500/10 text-indigo-100`} data-testid="port-entry-claim">
            <p className="font-medium text-indigo-200">Commission your first ship</p>
            <p className="mt-1 text-indigo-100/80">
              Claim your main ship. It will begin docked at <span className="font-medium">Haven Reach</span>, ready to explore.
            </p>
            {errorText && actionKind === 'commission' && (
              <p data-testid="port-entry-error" className="mt-2 text-rose-300">{errorText}</p>
            )}
            <button
              data-testid="port-entry-claim-button"
              disabled={busy}
              onClick={() => void run('commission')}
              className="mt-3 rounded-lg border border-indigo-400/40 px-3 py-1.5 text-indigo-50 transition hover:bg-indigo-500/20 disabled:cursor-not-allowed disabled:opacity-50"
            >
              {busy ? 'Claiming…' : 'Claim First Ship'}
            </button>
          </div>
        </div>
      )

    case 'normalize':
      return (
        <div data-testid="port-entry-panel">
          <div className={`${CARD} border-emerald-500/30 bg-emerald-500/10 text-emerald-100`} data-testid="port-entry-finish-docking">
            <p className="font-medium text-emerald-200">Finish docking</p>
            <p className="mt-1 text-emerald-100/80">
              Your ship is at a port but not fully docked. Complete docking to use this port’s services.
            </p>
            {errorText && actionKind === 'normalize' && (
              <p data-testid="port-entry-error" className="mt-2 text-rose-300">{errorText}</p>
            )}
            <button
              data-testid="port-entry-finish-docking-button"
              disabled={busy}
              onClick={() => void run('normalize')}
              className="mt-3 rounded-lg border border-emerald-400/40 px-3 py-1.5 text-emerald-50 transition hover:bg-emerald-500/20 disabled:cursor-not-allowed disabled:opacity-50"
            >
              {busy ? 'Docking…' : 'Finish Docking'}
            </button>
          </div>
        </div>
      )

    case 'at_home':
      return (
        <div data-testid="port-entry-panel">
          <div className={`${CARD} border-white/10 bg-white/5 text-white/70`} data-testid="port-entry-at-home">
            <p className="font-medium text-white/80">Ship at home base</p>
            <p className="mt-1">
              Your ship is at your home base. Travel to a port before it can be docked there.
            </p>
          </div>
        </div>
      )

    case 'in_transit':
      return (
        <div data-testid="port-entry-panel">
          <div className={`${CARD} border-white/10 bg-white/5 text-white/70`} data-testid="port-entry-in-transit">
            <p className="font-medium text-white/80">Ship in transit</p>
            <p className="mt-1">Your ship is travelling. It can be docked once it has arrived at a port.</p>
          </div>
        </div>
      )

    case 'unavailable': {
      const detailText =
        affordance.detail === 'destroyed'
          ? 'Your ship needs to be repaired before it can be docked.'
          : affordance.detail === 'in_space'
            ? 'Your ship is parked in open space. Travel to a port before it can be docked.'
            : 'Your ship is not in a state where it can be docked right now.'
      return (
        <div data-testid="port-entry-panel">
          <div className={`${CARD} border-white/10 bg-white/5 text-white/70`} data-testid="port-entry-unavailable">
            <p className="font-medium text-white/80">Docking unavailable</p>
            <p className="mt-1">{detailText}</p>
          </div>
        </div>
      )
    }

    // 'loading' (not yet read) and 'docked' (ordinary docked experience elsewhere) render nothing.
    default:
      return null
  }
}
