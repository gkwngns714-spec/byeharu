import { Link } from 'react-router-dom'
import type { LocationState, MapLocation } from './mapTypes'
import { activityFromPressure, dangerFromModifier, dangerWarningText } from '../../game/worldstate/danger'

// M6: read-only location detail. Surfaces M5 World State (pirate activity / danger)
// clearly, with a warning when danger is High/Severe. No writes; sending a fleet
// happens from the Command Center.
export function LocationPanel({
  loc,
  state,
  onClose,
}: {
  loc: MapLocation
  state?: LocationState
  onClose: () => void
}) {
  const isHunt = loc.location_type === 'pirate_hunt'
  const warning = isHunt ? dangerWarningText(state) : null

  return (
    <div className="rounded-2xl border border-white/15 bg-white/[0.06] p-5">
      <div className="mb-3 flex items-start justify-between">
        <div>
          <h3 className="text-base font-medium text-white/90">{loc.name}</h3>
          <p className="text-xs text-white/40">{loc.location_type.replace('_', ' ')}</p>
        </div>
        <button onClick={onClose} className="text-xs text-white/40 transition hover:text-white/70">
          ✕ close
        </button>
      </div>

      {isHunt ? (
        <div className="space-y-2">
          <Row label="Difficulty" value={String(loc.base_difficulty)} />
          <Row label="Reward tier" value={String(loc.reward_tier)} />
          {state ? (
            <>
              <Row
                label="Pirate activity"
                value={activityFromPressure(state.pressure).label}
                cls={activityFromPressure(state.pressure).cls}
              />
              <Row
                label="Danger"
                value={dangerFromModifier(state.danger_modifier).label}
                cls={dangerFromModifier(state.danger_modifier).cls}
              />
            </>
          ) : (
            <p className="text-xs text-white/40">Live danger data unavailable.</p>
          )}
          {warning && (
            <p className="rounded-lg border border-red-400/30 bg-red-400/10 px-3 py-2 text-xs text-red-200">
              {warning}
            </p>
          )}
        </div>
      ) : (
        <p className="text-sm text-white/50">Safe zone — no pirate activity. A good place to rally.</p>
      )}

      <Link to="/" className="mt-4 inline-block text-xs text-indigo-300 transition hover:text-indigo-200">
        → Send a fleet from the Command Center
      </Link>
    </div>
  )
}

function Row({ label, value, cls }: { label: string; value: string; cls?: string }) {
  return (
    <div className="flex items-baseline justify-between">
      <span className="text-xs uppercase tracking-wide text-white/35">{label}</span>
      <span className={'text-sm ' + (cls ?? 'text-white/75')}>{value}</span>
    </div>
  )
}
