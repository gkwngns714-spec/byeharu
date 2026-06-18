import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useGalaxyMapData } from './useGalaxyMapData'
import { GalaxyMap } from './GalaxyMap'

// Read-only Galaxy Map screen (Phase 9A). Shows the world, the player's home/ship, and
// active fleet movements. Selecting a location opens a read-only detail panel. NO writes,
// NO expedition commands — those arrive in Phase 9B.

export function GalaxyMapScreen() {
  const { loading, error, locations, meta, base, mainShip, movements, locationStates } = useGalaxyMapData()
  const [selectedId, setSelectedId] = useState<string | null>(null)

  const selected = locations.find((l) => l.id === selectedId) ?? null
  const selMeta = selectedId ? meta[selectedId] : null
  const selState = selectedId ? locationStates[selectedId] : undefined

  return (
    <div className="flex h-[100dvh] flex-col bg-slate-950 text-slate-100">
      <header className="flex items-center justify-between border-b border-slate-800 px-4 py-3">
        <div>
          <h1 className="text-lg font-semibold">Galaxy Map</h1>
          <p className="text-xs text-slate-400">Read-only view · expeditions coming in Phase 9B</p>
        </div>
        <nav className="flex gap-3 text-sm">
          <Link to="/" className="text-slate-300 hover:text-white">Command Center</Link>
          <Link to="/map" className="text-slate-300 hover:text-white">List view</Link>
        </nav>
      </header>

      <main className="relative flex flex-1 flex-col overflow-hidden md:flex-row">
        {/* Map area */}
        <div className="relative flex-1 p-2">
          {loading && (
            <div className="flex h-full items-center justify-center text-slate-400">
              <span className="animate-pulse">Loading galaxy…</span>
            </div>
          )}
          {!loading && error && (
            <div className="flex h-full items-center justify-center px-6 text-center">
              <div>
                <p className="font-medium text-rose-400">Couldn't load the map</p>
                <p className="mt-1 text-sm text-slate-400">{error}</p>
              </div>
            </div>
          )}
          {!loading && !error && locations.length === 0 && (
            <div className="flex h-full items-center justify-center px-6 text-center text-slate-400">
              No locations are visible yet.
            </div>
          )}
          {!loading && !error && locations.length > 0 && (
            <GalaxyMap
              locations={locations}
              base={base}
              mainShip={mainShip}
              movements={movements}
              selectedId={selectedId}
              onSelect={setSelectedId}
            />
          )}
        </div>

        {/* Read-only detail panel */}
        {selected && (
          <aside className="border-t border-slate-800 bg-slate-900/95 p-4 md:w-80 md:border-l md:border-t-0">
            <div className="flex items-start justify-between">
              <h2 className="text-base font-semibold">{selected.name}</h2>
              <button onClick={() => setSelectedId(null)} className="text-slate-400 hover:text-white" aria-label="Close details">✕</button>
            </div>
            <dl className="mt-3 space-y-1.5 text-sm">
              <Row label="Type" value={selected.location_type.replace(/_/g, ' ')} />
              {selMeta && <Row label="Sector" value={selMeta.sectorName} />}
              {selMeta && <Row label="Zone" value={selMeta.zoneName} />}
              <Row label="Coordinates" value={`${Math.round(selected.x)}, ${Math.round(selected.y)}`} />
              <Row label="Status" value={selected.status} />
              <Row label="Difficulty" value={String(selected.base_difficulty)} />
              <Row label="Reward tier" value={String(selected.reward_tier)} />
              {selState && <Row label="Pressure" value={selState.pressure.toFixed(2)} />}
              {selState && <Row label="Danger mod" value={selState.danger_modifier.toFixed(2)} />}
              {selState && <Row label="Active fleets" value={String(selState.active_fleets)} />}
            </dl>
            <div className="mt-4 rounded-md border border-slate-700 bg-slate-800/60 p-3 text-xs text-slate-400">
              Expedition selection coming in Phase 9B.
            </div>
            <button
              disabled
              className="mt-3 w-full cursor-not-allowed rounded-md border border-slate-700 bg-slate-800/40 py-2 text-sm text-slate-500"
            >
              Send expedition (Phase 9B)
            </button>
          </aside>
        )}
      </main>
    </div>
  )
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between gap-3">
      <dt className="text-slate-400">{label}</dt>
      <dd className="text-right text-slate-200">{value}</dd>
    </div>
  )
}
