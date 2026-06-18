import { useEffect, useState } from 'react'
import { fetchMyMainShip, type MainShipView } from './mainshipApi'

// Phase 10B (revised) — READ-ONLY main-ship view. Shows the player's persistent main ship and
// its base stats only (name, hull, status, readiness, speed, cargo, captain/module slots).
// NO support craft, NO support capacity, NO loadout. It only reads; it never sends or writes.

function Row({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="flex justify-between">
      <dt className="text-slate-400">{label}</dt>
      <dd className="text-slate-200">{value}</dd>
    </div>
  )
}

export function MainShipPreview() {
  const [view, setView] = useState<MainShipView | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    let active = true
    fetchMyMainShip().then(
      (v) => { if (active) { setView(v); setError(null); setLoading(false) } },
      (e) => { if (active) { setError(e instanceof Error ? e.message : String(e)); setLoading(false) } },
    )
    return () => { active = false }
  }, [])

  const ship = view?.ship
  const hull = view?.hull

  return (
    <div data-testid="mainship-preview" className="rounded-xl border border-sky-400/20 bg-sky-500/5 p-4 text-sm text-slate-200">
      <div className="flex items-center justify-between">
        <h3 className="font-medium">🛰 Main Ship</h3>
        <span className="rounded bg-slate-700/60 px-2 py-0.5 text-[10px] uppercase tracking-wide text-slate-300">Read-only</span>
      </div>

      {loading && <p className="mt-2 text-xs text-slate-500">Loading…</p>}
      {error && <p className="mt-2 text-rose-300">{error}</p>}

      {!loading && !error && view && (
        view.has_ship && ship ? (
          <dl className="mt-3 space-y-1.5">
            <Row label="Name" value={ship.name} />
            <Row label="Hull" value={hull?.name ?? ship.hull_type_id} />
            <Row label="Status" value={ship.status} />
            <Row label="Readiness (HP)" value={`${ship.hp} / ${ship.max_hp}`} />
            <Row label="Speed" value={hull?.base_speed ?? '—'} />
            <Row label="Cargo capacity" value={ship.cargo_capacity} />
            <Row label="Captain slots" value={ship.captain_slots} />
            <Row label="Module slots" value={ship.module_slots} />
          </dl>
        ) : (
          <div className="mt-3">
            <p className="text-xs text-slate-400">No main ship commissioned yet — showing the starter hull.</p>
            {hull && (
              <dl className="mt-2 space-y-1.5">
                <Row label="Hull" value={hull.name} />
                <Row label="Base HP" value={hull.base_hp} />
                <Row label="Speed" value={hull.base_speed} />
                <Row label="Cargo capacity" value={hull.base_cargo_capacity} />
                <Row label="Captain slots" value={hull.base_captain_slots} />
                <Row label="Module slots" value={hull.base_module_slots} />
              </dl>
            )}
          </div>
        )
      )}
    </div>
  )
}
