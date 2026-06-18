import { useEffect, useMemo, useState } from 'react'
import { fetchExpeditionPreview, fetchSupportCraftTypes, type ExpeditionPreview, type LoadoutEntry, type SupportCraftType } from './mainshipApi'

// Phase 10B — READ-ONLY main-ship expedition stats preview. Pick a support-craft loadout +
// activity and see what your main ship WOULD bring. It only calls the read-only preview RPC;
// it never sends, trains, or writes anything. The real send path (Phase 9B) is untouched.

const ACTIVITIES = ['pirate_hunt', 'trade_run', 'exploration', 'mining'] as const
const STAT_FIELDS: { key: keyof NonNullable<ExpeditionPreview['stats']>; label: string }[] = [
  { key: 'combat_power', label: 'Combat power' },
  { key: 'survival', label: 'Survival' },
  { key: 'retreat_safety', label: 'Retreat safety' },
  { key: 'repair', label: 'Repair' },
  { key: 'scouting', label: 'Scouting' },
  { key: 'mining_yield', label: 'Mining yield' },
  { key: 'cargo_capacity', label: 'Cargo capacity' },
  { key: 'speed', label: 'Speed' },
  { key: 'pirate_attention', label: 'Pirate attention' },
]

export function MainShipPreview() {
  const [crafts, setCrafts] = useState<SupportCraftType[]>([])
  const [qty, setQty] = useState<Record<string, number>>({})
  const [activity, setActivity] = useState<string>('pirate_hunt')
  const [preview, setPreview] = useState<ExpeditionPreview | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    fetchSupportCraftTypes().then(setCrafts).catch((e) => setError(e instanceof Error ? e.message : String(e)))
  }, [])

  const loadout: LoadoutEntry[] = useMemo(
    () => Object.entries(qty).filter(([, q]) => q > 0).map(([support_craft_type_id, quantity]) => ({ support_craft_type_id, quantity })),
    [qty],
  )

  useEffect(() => {
    let active = true
    setLoading(true)
    fetchExpeditionPreview(loadout, activity)
      .then((p) => { if (active) { setPreview(p); setError(null) } })
      .catch((e) => { if (active) setError(e instanceof Error ? e.message : String(e)) })
      .finally(() => { if (active) setLoading(false) })
    return () => { active = false }
  }, [loadout, activity])

  const hasShip = preview?.has_ship === true
  const stats = preview?.valid ? preview.stats : undefined
  const used = stats?.support_capacity_used ?? 0
  const limit = stats?.support_capacity_limit ?? preview?.ship?.support_capacity ?? preview?.hull?.base_support_capacity ?? 10

  return (
    <div data-testid="mainship-preview" className="rounded-xl border border-sky-400/20 bg-sky-500/5 p-4 text-sm text-slate-200">
      <div className="flex items-center justify-between">
        <h3 className="font-medium">🛰 Main Ship — expedition preview</h3>
        <span className="rounded bg-slate-700/60 px-2 py-0.5 text-[10px] uppercase tracking-wide text-slate-300">Preview only · does not send</span>
      </div>

      {error && <p className="mt-2 text-rose-300">{error}</p>}

      {/* ship / hull header */}
      {preview && (
        <p className="mt-2 text-xs text-slate-400">
          {hasShip
            ? <>Ship: <span className="text-slate-200">{preview.ship!.name}</span> · {preview.ship!.status} · hull {preview.ship!.hp}/{preview.ship!.max_hp} hp</>
            : <>No main ship commissioned yet — showing the starter hull ({preview.hull?.name}). Loadout preview becomes available once your ship exists.</>}
        </p>
      )}

      {/* activity */}
      <div className="mt-3 flex items-center gap-2">
        <label className="text-xs text-slate-400">Activity</label>
        <select value={activity} onChange={(e) => setActivity(e.target.value)} className="rounded border border-slate-600 bg-slate-900 px-2 py-1 text-xs">
          {ACTIVITIES.map((a) => <option key={a} value={a}>{a.replace('_', ' ')}</option>)}
        </select>
      </div>

      {/* support-craft loadout picker (only meaningful with a commissioned ship) */}
      {hasShip && (
        <div className="mt-3 space-y-1.5">
          <p className="text-xs uppercase tracking-wide text-slate-400">Support craft (capacity-limited)</p>
          {crafts.map((c) => (
            <label key={c.support_craft_type_id} className="flex items-center justify-between gap-2">
              <span className="text-slate-300">{c.name} <span className="text-slate-500">· {c.role} · cap {c.capacity_cost}</span></span>
              <input
                type="number"
                min={0}
                value={qty[c.support_craft_type_id] || ''}
                placeholder="0"
                onChange={(e) => setQty((q) => ({ ...q, [c.support_craft_type_id]: Math.max(0, Number(e.target.value) || 0) }))}
                className="w-16 rounded border border-slate-600 bg-slate-900 px-2 py-1 text-right"
              />
            </label>
          ))}
        </div>
      )}

      {/* capacity bar */}
      <div className="mt-3">
        <div className="flex justify-between text-xs text-slate-400">
          <span>Support capacity</span>
          <span className={used > limit ? 'text-rose-300' : 'text-slate-300'}>{used} / {limit}</span>
        </div>
        <div className="mt-1 h-2 w-full overflow-hidden rounded bg-slate-800">
          <div className={'h-full ' + (used > limit ? 'bg-rose-500' : 'bg-sky-500')} style={{ width: `${Math.min(100, (used / Math.max(1, limit)) * 100)}%` }} />
        </div>
      </div>

      {/* over-capacity / invalid loadout */}
      {hasShip && preview?.valid === false && (
        <p className="mt-2 rounded border border-rose-600/40 bg-rose-500/10 px-2 py-1.5 text-xs text-rose-300">{preview.error}</p>
      )}

      {/* warnings */}
      {stats?.warnings?.length ? (
        <ul className="mt-2 list-disc pl-5 text-xs text-amber-300/80">
          {stats.warnings.map((w, i) => <li key={i}>{w}</li>)}
        </ul>
      ) : null}

      {/* stats grid */}
      {stats && (
        <dl className="mt-3 grid grid-cols-2 gap-x-4 gap-y-1 text-xs sm:grid-cols-3">
          {STAT_FIELDS.map((f) => (
            <div key={f.key} className="flex justify-between">
              <dt className="text-slate-400">{f.label}</dt>
              <dd className="text-slate-200">{stats[f.key]}</dd>
            </div>
          ))}
        </dl>
      )}

      {loading && <p className="mt-2 text-xs text-slate-500">Computing…</p>}
    </div>
  )
}
