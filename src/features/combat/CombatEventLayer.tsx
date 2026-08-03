import type { ReactNode } from 'react'
import type { CombatEvent } from './combatTypes'
import { feedRows } from './combatFeed'
import { SectionLabel } from '../../components/ui'
import { ItemChip } from '../../components/items'

// COSMETIC ONLY. Animates the server-generated combat_events into a readable feed.
// Decides nothing — all values come from the server.

const cap = (s: unknown) => {
  const str = String(s ?? '')
  return str.charAt(0).toUpperCase() + str.slice(1)
}
const num = (v: unknown) => (typeof v === 'number' ? v : Number(v ?? 0))

function describe(e: CombatEvent): { icon: string; text: ReactNode } {
  const p = e.payload_json ?? {}
  switch (e.event_type) {
    case 'wave_spawned':
      return { icon: '👾', text: `Wave ${num(p.wave)} incoming (danger ${num(p.danger)}${p.hp ? `, ${num(p.hp)} HP` : ''})` }
    case 'missile_salvo':
      // The AGGREGATE (legacy) salvo carries its damage in the payload; the SPATIAL salvo is the
      // LAUNCH event ({unit_id, target_id}, no damage — the impact lands as hull_damage). The old
      // copy printed "for 0 damage" on every spatial salvo and claimed every salvo was ours.
      if (p.damage != null) return { icon: '🚀', text: `Missile salvo hit the pirate wave for ${Math.round(num(p.damage))} damage` }
      return e.source === 'pirate'
        ? { icon: '🚀', text: 'Pirate salvo inbound' }
        : { icon: '🚀', text: 'Missile salvo away' }
    case 'laser_burst':
      return { icon: '⚡', text: 'Pirates opened fire' }
    case 'hull_damage': {
      // 0314: the per-hit hitsplat now arrives for BOTH directions (source tells whose shot landed);
      // the spatial payload is {unit_id, damage} while the legacy aggregate one carries {group}.
      // Damage is the server's unrounded fact — display rounds.
      const dmg = Math.round(num(p.damage))
      const who = p.group ? `${cap(p.group)} group` : e.source === 'pirate' ? 'our hull' : 'the pirate'
      return e.source === 'pirate'
        ? { icon: '🔧', text: `Pirate hit landed — ${who} took ${dmg} damage` }
        : { icon: '💢', text: `Our hit landed — ${who} took ${dmg} damage` }
    }
    case 'unit_destroyed': {
      // The SPATIAL payload is {count, unit_id} — it has no `group`, so the old line read
      // `${count} ${cap(undefined)} destroyed` and printed "1  destroyed": no noun, two spaces.
      // `source` is the side that FIRED the killing shot (0299:931-933), so the side that LOST the
      // ship is the other one — which is the fact worth saying and the one thing the payload
      // reliably supports. The aggregate arm still carries `group`; it keeps its own wording.
      const n = num(p.count) || 1
      if (p.group) return { icon: '☠️', text: `${n} ${cap(p.group)} destroyed` }
      return e.source === 'pirate'
        ? { icon: '☠️', text: n > 1 ? `${n} of our ships destroyed` : 'One of our ships was destroyed' }
        : { icon: '☠️', text: n > 1 ? `${n} pirate ships destroyed` : 'Pirate ship destroyed' }
    }
    case 'explosion':
      // ITEM-VIZ: the metal reward as an ItemChip (glyph + name + mono qty) — same payload data.
      if (p.wave_cleared)
        return {
          icon: '💥',
          text: (
            <>
              Wave {num(p.wave)} cleared. +<ItemChip id="metal" kind="resource" qty={num(p.reward_metal)} /> pending
            </>
          ),
        }
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
  if (source === 'player') return 'border-l-accent/70'
  if (source === 'pirate') return 'border-l-danger/70'
  return 'border-l-edge'
}

export function CombatEventLayer({ events }: { events: CombatEvent[] }) {
  const recent = feedRows(events)

  return (
    <div>
      {/* UI R4: the ONE micro-label primitive instead of the hand-rolled heading (same string). */}
      <SectionLabel>Battle feed</SectionLabel>
      {recent.length === 0 ? (
        <p className="text-xs text-ink-faint">awaiting combat events…</p>
      ) : (
        <ul className="space-y-1">
          {recent.map((e) => {
            const d = describe(e)
            return (
              <li
                key={e.id}
                className={`bh-fade-in flex items-center gap-2 border-l-2 ${sideColor(e.source)} bg-surface-2/60 px-2 py-1 text-xs`}
              >
                <span>{d.icon}</span>
                <span className="text-ink-muted">{d.text}</span>
                {/* UI R4: ops telemetry — tick stamps read in mono numerals. */}
                <span className="ml-auto font-mono tabular-nums text-ink-faint/70">t{e.tick_number}</span>
              </li>
            )
          })}
        </ul>
      )}
    </div>
  )
}
