import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { fetchLocationStates, fetchWorldMap } from './mapApi'
import type { LocationState, MapLocation, WorldMap } from './mapTypes'

/**
 * M2: read-only galaxy browser. Shows the static world (sectors → zones →
 * locations). M5 overlays live World State (pirate activity / danger) on
 * pirate_hunt locations — read-only; the server owns those values.
 */
export function MapPage() {
  const [world, setWorld] = useState<WorldMap | null>(null)
  const [states, setStates] = useState<Record<string, LocationState>>({})
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    Promise.all([fetchWorldMap(), fetchLocationStates()])
      .then(([w, s]) => { setWorld(w); setStates(s) })
      .catch((e: unknown) => setError(e instanceof Error ? e.message : String(e)))
      .finally(() => setLoading(false))
  }, [])

  return (
    <div className="mx-auto max-w-4xl px-6 py-10">
      <header className="mb-8 flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight text-indigo-200">
            Galaxy Map
          </h1>
          <p className="text-sm text-white/40">Byeharu — read-only world view</p>
        </div>
        <Link
          to="/"
          className="rounded-lg border border-white/10 px-3 py-1.5 text-sm text-white/70 transition hover:bg-white/5"
        >
          ← Command center
        </Link>
      </header>

      {loading && <p className="text-white/40">Charting the galaxy…</p>}

      {error && (
        <div className="rounded-xl border border-red-500/30 bg-red-500/10 p-4 text-sm text-red-300">
          Couldn't load the map: {error}
          <p className="mt-1 text-red-300/60">
            (Have you applied the migrations and set <code>.env.local</code>?)
          </p>
        </div>
      )}

      {world && world.sectors.length === 0 && !error && (
        <p className="text-white/40">No sectors found. Did the seed data load?</p>
      )}

      <div className="space-y-8">
        {world?.sectors.map((sector) => (
          <section key={sector.id}>
            <div className="mb-3 flex items-baseline gap-3">
              <h2 className="text-lg font-medium text-white/90">{sector.name}</h2>
              <span className="text-xs text-white/40">
                sector {sector.sector_index} · danger tier {sector.danger_tier}
              </span>
            </div>

            <div className="space-y-4 border-l border-white/10 pl-4">
              {sector.zones.map((zone) => (
                <div key={zone.id}>
                  <div className="mb-2 flex items-baseline gap-2">
                    <h3 className="text-sm font-medium text-indigo-300">{zone.name}</h3>
                    <span className="text-xs text-white/35">
                      difficulty {zone.base_difficulty} · reward tier {zone.reward_tier}
                    </span>
                  </div>

                  <ul className="grid gap-2 sm:grid-cols-2">
                    {zone.locations.map((loc) => (
                      <LocationCard key={loc.id} loc={loc} state={states[loc.id]} />
                    ))}
                  </ul>
                </div>
              ))}
            </div>
          </section>
        ))}
      </div>
    </div>
  )
}

// M5: derive friendly labels from live World State (read-only).
function activityLabel(pressure: number): { text: string; cls: string } {
  if (pressure < 34) return { text: 'Calm', cls: 'text-emerald-300' }
  if (pressure < 67) return { text: 'Rising', cls: 'text-amber-300' }
  return { text: 'Severe', cls: 'text-red-300' }
}
function dangerLabel(mod: number): { text: string; cls: string } {
  if (mod <= 1.0) return { text: 'Low', cls: 'text-emerald-300' }
  if (mod < 1.13) return { text: 'Medium', cls: 'text-amber-300' }
  return { text: 'High', cls: 'text-red-300' }
}

function LocationCard({ loc, state }: { loc: MapLocation; state?: LocationState }) {
  const isHunt = loc.location_type === 'pirate_hunt'
  return (
    <li className="rounded-lg border border-white/10 bg-white/5 p-3">
      <div className="flex items-center justify-between">
        <span className="text-sm text-white/90">{loc.name}</span>
        <span
          className={
            'rounded px-1.5 py-0.5 text-[10px] uppercase tracking-wide ' +
            (isHunt
              ? 'bg-red-500/15 text-red-300'
              : 'bg-emerald-500/15 text-emerald-300')
          }
        >
          {loc.location_type.replace('_', ' ')}
        </span>
      </div>
      <div className="mt-1 text-xs text-white/40">
        {isHunt
          ? `difficulty ${loc.base_difficulty} · reward tier ${loc.reward_tier}`
          : 'safe — no activity'}
      </div>
      {isHunt && state && (
        <div className="mt-1.5 flex gap-3 text-[11px] text-white/50">
          <span>
            Pirate activity:{' '}
            <span className={activityLabel(state.pressure).cls}>
              {activityLabel(state.pressure).text}
            </span>
          </span>
          <span>
            Danger:{' '}
            <span className={dangerLabel(state.danger_modifier).cls}>
              {dangerLabel(state.danger_modifier).text}
            </span>
          </span>
        </div>
      )}
    </li>
  )
}
