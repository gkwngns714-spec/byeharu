import type { CombatEvent } from './combatTypes'

// COSMETIC ONLY. Animates the server-generated combat_events into a readable feed.
// Decides nothing — all values come from the server.

const cap = (s: unknown) => {
  const str = String(s ?? '')
  return str.charAt(0).toUpperCase() + str.slice(1)
}
const num = (v: unknown) => (typeof v === 'number' ? v : Number(v ?? 0))

function describe(e: CombatEvent): { icon: string; text: string } {
  const p = e.payload_json ?? {}
  switch (e.event_type) {
    case 'wave_spawned':
      return { icon: '👾', text: `Wave ${num(p.wave)} incoming (danger ${num(p.danger)}${p.hp ? `, ${num(p.hp)} HP` : ''})` }
    case 'missile_salvo':
      return { icon: '🚀', text: `Missile salvo hit the pirate wave for ${num(p.damage)} damage` }
    case 'laser_burst':
      return { icon: '⚡', text: 'Pirates opened fire' }
    case 'hull_damage':
      return { icon: '🔧', text: `Pirates damaged ${cap(p.group)} group for ${num(p.damage)} hull` }
    case 'unit_destroyed':
      return { icon: '☠️', text: `${num(p.count)} ${cap(p.group)} destroyed` }
    case 'explosion':
      if (p.wave_cleared) return { icon: '💥', text: `Wave ${num(p.wave)} cleared. +${num(p.reward_metal)} metal pending` }
      if (p.reason === 'fleet_lost') return { icon: '💀', text: 'Fleet destroyed' }
      return { icon: '💥', text: 'Explosion' }
    case 'retreat_started':
      return { icon: '🏳️', text: 'Retreat ordered — disengaging' }
    case 'retreat_completed':
      return { icon: '🟢', text: p.forced ? 'Auto-extracted to safety' : 'Escaped to safety' }
    case 'shield_hit':
      return { icon: '🛡️', text: 'Shields absorbed a hit' }
    default:
      return { icon: '•', text: e.event_type }
  }
}

function sideColor(source: string | null) {
  if (source === 'player') return 'border-l-indigo-400/70'
  if (source === 'pirate') return 'border-l-red-400/70'
  return 'border-l-white/30'
}

export function CombatEventLayer({ events }: { events: CombatEvent[] }) {
  const recent = events.slice().sort((a, b) => b.id - a.id).slice(0, 14)

  return (
    <div>
      <h4 className="mb-2 text-[10px] uppercase tracking-wide text-white/35">Battle feed</h4>
      {recent.length === 0 ? (
        <p className="text-xs text-white/30">awaiting combat events…</p>
      ) : (
        <ul className="space-y-1">
          {recent.map((e) => {
            const d = describe(e)
            return (
              <li
                key={e.id}
                className={`bh-fade-in flex items-center gap-2 border-l-2 ${sideColor(e.source)} bg-black/20 px-2 py-1 text-xs`}
              >
                <span>{d.icon}</span>
                <span className="text-white/75">{d.text}</span>
                <span className="ml-auto text-white/25">t{e.tick_number}</span>
              </li>
            )
          })}
        </ul>
      )}
    </div>
  )
}
