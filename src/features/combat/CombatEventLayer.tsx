import type { CombatEvent, CombatEventType } from './combatTypes'

// COSMETIC ONLY. Animates the server-generated combat_events. Decides nothing.
// First visual version: an event feed of icon + label streaks (newest on top).

const META: Record<CombatEventType, { icon: string; label: string }> = {
  missile_salvo: { icon: '🚀', label: 'Missile salvo' },
  laser_burst: { icon: '⚡', label: 'Laser burst' },
  shield_hit: { icon: '🛡️', label: 'Shield hit' },
  hull_damage: { icon: '🔧', label: 'Hull damage' },
  explosion: { icon: '💥', label: 'Explosion' },
  unit_destroyed: { icon: '☠️', label: 'Units lost' },
  wave_spawned: { icon: '👾', label: 'Pirate wave' },
  retreat_started: { icon: '🏳️', label: 'Retreat started' },
  retreat_completed: { icon: '🟢', label: 'Retreat complete' },
}

function sideColor(source: string | null) {
  if (source === 'player') return 'border-l-indigo-400/70'
  if (source === 'pirate') return 'border-l-red-400/70'
  return 'border-l-white/30'
}

export function CombatEventLayer({ events }: { events: CombatEvent[] }) {
  const recent = events.slice().sort((a, b) => b.id - a.id).slice(0, 12)

  return (
    <div>
      <h4 className="mb-2 text-[10px] uppercase tracking-wide text-white/35">Battle feed</h4>
      {recent.length === 0 ? (
        <p className="text-xs text-white/30">awaiting combat events…</p>
      ) : (
        <ul className="space-y-1">
          {recent.map((e) => {
            const m = META[e.event_type] ?? { icon: '•', label: e.event_type }
            const count = e.projectile_count ? ` ×${e.projectile_count}` : ''
            return (
              <li
                key={e.id}
                className={`bh-fade-in flex items-center gap-2 border-l-2 ${sideColor(e.source)} bg-black/20 px-2 py-1 text-xs`}
              >
                <span>{m.icon}</span>
                <span className="text-white/75">
                  {m.label}
                  {count}
                </span>
                {e.source && e.target && (
                  <span className="text-white/30">
                    {e.source} → {e.target}
                  </span>
                )}
                <span className="ml-auto text-white/25">t{e.tick_number}</span>
              </li>
            )
          })}
        </ul>
      )}
    </div>
  )
}
