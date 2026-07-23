// E4 — COMBAT CONTENT: the ONE foldable rail <section> that mounts in the World Editor side rail after the
// History panel. It is the container: it fetches the read-only snapshot (combatContentData — the three
// already-built E0-E2 read adapters) on mount, owns reload(), and owns the fold state (the whole section
// is COLLAPSED by default; ONE sub-panel open at a time, mirroring the layer-toggle idiom). It holds NO
// command logic — it owns the ONE useCombatAuthoring hook and threads it (plus rows + reload) down to the
// pure authoring sub-panels. Map-UX law: one foldable section, plain words, no map-canvas clutter.
import { useCallback, useEffect, useState } from 'react'
import { fetchCombatContentData, type CombatContentData } from './combatContentData'
import { useCombatAuthoring } from './useCombatAuthoring'
import { RewardProfileAuthoring } from './RewardProfileAuthoring'
import { EnemyArchetypeAuthoring } from './EnemyArchetypeAuthoring'
import { FleetTemplateAuthoring } from './FleetTemplateAuthoring'
import { EncounterProfileAuthoring } from './EncounterProfileAuthoring'
import { LocationBindingAuthoring } from './LocationBindingAuthoring'
import type { MapLocation } from '../map/mapTypes'

type SubPanel = 'reward' | 'enemy' | 'fleet' | 'encounter' | 'binding'

const SUBPANEL_ORDER: readonly SubPanel[] = ['reward', 'enemy', 'fleet', 'encounter', 'binding']
const SUBPANEL_LABEL: Record<SubPanel, string> = {
  reward: 'Rewards',
  enemy: 'Enemies',
  fleet: 'Fleets',
  encounter: 'Encounters',
  binding: 'Placements',
}

function countFor(sub: SubPanel, data: CombatContentData | null): number {
  if (!data) return 0
  switch (sub) {
    case 'reward': return data.rewardProfiles.length
    case 'enemy': return data.enemyArchetypes.length
    case 'fleet': return data.fleetTemplates.length
    case 'encounter': return data.encounterProfiles.length
    case 'binding': return data.bindings.length
  }
}

export function CombatContentPanel({
  locations,
  defaultOpen = false,
}: {
  locations: readonly MapLocation[]
  /** The shell passes `true` when the section is ALREADY the summoned dock tool (the owner asked for it
   *  explicitly, so a second click to unfold would be pure friction). Default stays collapsed. */
  defaultOpen?: boolean
}) {
  const [open, setOpen] = useState(defaultOpen) // collapsed by default (map-UX), unless summoned
  const [sub, setSub] = useState<SubPanel | null>(null) // one sub-panel open at a time
  const [data, setData] = useState<CombatContentData | null>(null)

  const reload = useCallback(async () => {
    const d = await fetchCombatContentData()
    setData(d)
  }, [])

  useEffect(() => {
    let alive = true
    void (async () => {
      const d = await fetchCombatContentData()
      if (alive) setData(d)
    })()
    return () => {
      alive = false
    }
  }, [])

  const authoring = useCombatAuthoring(reload)

  return (
    <section className="rounded-card border border-edge bg-surface p-3" data-testid="combat-content-panel">
      <button
        onClick={() => setOpen((v) => !v)}
        className="flex w-full items-center justify-between text-xs font-semibold uppercase tracking-wide text-ink-muted"
        aria-expanded={open}
      >
        <span>Combat content</span>
        <span className="text-ink-faint">{open ? '−' : '+'}</span>
      </button>

      {open && (
        <div className="mt-2 flex flex-col gap-2">
          <p className="text-xs text-ink-faint">
            Owner-only. Author enemies and where they appear. Changes save to the live world only if the
            server allows it — nothing here turns a feature on.
          </p>

          {/* sub-panel toggles — one open at a time (layer-toggle idiom) */}
          <div className="grid grid-cols-3 gap-1.5">
            {SUBPANEL_ORDER.map((s) => {
              const active = sub === s
              return (
                <button
                  key={s}
                  onClick={() => setSub(active ? null : s)}
                  className={`flex items-center justify-between rounded-md border px-2 py-1.5 text-xs ${
                    active ? 'border-accent/60 bg-accent-soft text-ink' : 'border-edge bg-surface-2 text-ink-muted'
                  }`}
                  aria-pressed={active}
                >
                  <span>{SUBPANEL_LABEL[s]}</span>
                  <span className="text-ink-faint">{countFor(s, data)}</span>
                </button>
              )
            })}
          </div>

          {sub === 'reward' && (
            <RewardProfileAuthoring rows={data?.rewardProfiles ?? []} authoring={authoring} />
          )}
          {sub === 'enemy' && (
            <EnemyArchetypeAuthoring
              rows={data?.enemyArchetypes ?? []}
              rewardProfiles={data?.rewardProfiles ?? []}
              authoring={authoring}
            />
          )}
          {sub === 'fleet' && (
            <FleetTemplateAuthoring
              rows={data?.fleetTemplates ?? []}
              archetypes={data?.enemyArchetypes ?? []}
              authoring={authoring}
            />
          )}
          {sub === 'encounter' && (
            <EncounterProfileAuthoring
              rows={data?.encounterProfiles ?? []}
              fleetTemplates={data?.fleetTemplates ?? []}
              rewardProfiles={data?.rewardProfiles ?? []}
              authoring={authoring}
            />
          )}
          {sub === 'binding' && (
            <LocationBindingAuthoring
              rows={data?.bindings ?? []}
              locations={locations}
              encounterProfiles={data?.encounterProfiles ?? []}
              authoring={authoring}
            />
          )}
        </div>
      )}
    </section>
  )
}
