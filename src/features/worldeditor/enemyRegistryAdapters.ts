// ENEMY CONTENT REGISTRY (0257) — the two READ-ONLY registry adapters (reward profiles + enemy
// archetypes). Each mirrors the worldEditorAdapters.ts read/resolve/inspect shape: it READS its
// catalog's rows from the shared snapshot, RESOLVES each to a typed list item, and INSPECTS one row
// into typed authoring fields. It implements NOTHING ELSE — no create/edit/publish/enable/disable
// (§WE.2: deferred authoring ops are explicit + absent, never simulated). Every inspector field is
// grounded in a REAL column enemyRegistryData.ts returns; nothing runtime is invented.
//
// WHY A REGISTRY-SPECIFIC ADAPTER SHAPE (not the map's ReadOnlyLayerAdapter/LayerItem): a reward
// profile / enemy archetype is a CATALOG row, not a map feature — it has NO world coordinate, so the
// map contract's mandatory `representation` (point/polygon/circle) + LayerId would have to be
// FABRICATED. The codebase's "no fabricated field" law (worldEditorAdapters.ts header) forbids that,
// so these adapters expose the SAME pure read/resolve/inspect surface over a coordinate-free item.
//
// PURE: no React/DOM/fetch/supabase — every read/resolve/inspect is a pure function unit-tested
// directly (tests/enemyRegistryAdapters.spec.ts). The tables are DARK; this READS only.
import type { InspectorField } from './worldEditorTypes'
import type {
  EnemyRegistryData,
  EnemyArchetypeRow,
  RewardProfileRow,
} from './enemyRegistryData'

/** One selectable registry row, as an adapter resolves it (coordinate-free — a catalog row, §above). */
export interface RegistryItem {
  readonly registry: 'reward_profiles' | 'enemy_archetypes'
  /** the stable natural key (both tables' `key` column — the RPC target_id addresses by this). */
  readonly id: string
  readonly label: string
  /** false ⇒ the row was soft-disabled via *_set_active (it survives; it is not deleted). */
  readonly active: boolean
}

/** The READ-ONLY registry adapter contract (the worldEditorTypes.ReadOnlyLayerAdapter shape, minus
 *  the map-only bits). NOTE the ABSENCE of any create/edit/publish/enable/disable method: that
 *  absence IS the read-only guarantee — authoring is the owner-gated 0257 RPC surface, never here. */
export interface RegistryReadAdapter<TSource> {
  readonly id: 'reward_profiles' | 'enemy_archetypes'
  readonly title: string
  readItems(source: TSource): RegistryItem[]
  inspect(source: TSource, itemId: string): InspectorField[] | null
}

// ── Reward profiles ──────────────────────────────────────────────────────────────────────────────
export const rewardProfileLayerAdapter: RegistryReadAdapter<EnemyRegistryData> = {
  id: 'reward_profiles',
  title: 'Reward Profiles',
  readItems(source) {
    return source.rewardProfiles.map((p: RewardProfileRow): RegistryItem => ({
      registry: 'reward_profiles',
      id: p.key,
      label: p.display_name,
      active: p.active,
    }))
  },
  inspect(source, itemId) {
    const p = source.rewardProfiles.find((x) => x.key === itemId)
    if (!p) return null
    return [
      { label: 'Key', value: p.key },
      { label: 'Display name', value: p.display_name },
      { label: 'Resources', value: Object.keys(p.resource_grants).sort().join(', ') || '—' },
      { label: 'Active', value: p.active ? 'yes' : 'no' },
      { label: 'Revision', value: String(p.revision) },
      { label: 'Notes', value: p.notes ?? '—' },
    ]
  },
}

// ── Enemy archetypes ─────────────────────────────────────────────────────────────────────────────
export const enemyArchetypeLayerAdapter: RegistryReadAdapter<EnemyRegistryData> = {
  id: 'enemy_archetypes',
  title: 'Enemy Archetypes',
  readItems(source) {
    return source.enemyArchetypes.map((a: EnemyArchetypeRow): RegistryItem => ({
      registry: 'enemy_archetypes',
      id: a.key,
      label: a.display_name,
      active: a.active,
    }))
  },
  inspect(source, itemId) {
    const a = source.enemyArchetypes.find((x) => x.key === itemId)
    if (!a) return null
    return [
      { label: 'Key', value: a.key },
      { label: 'Display name', value: a.display_name },
      { label: 'Faction', value: a.faction },
      { label: 'Unit type', value: a.unit_type_id },
      { label: 'Behavior', value: a.behavior_key },
      { label: 'Base difficulty', value: String(a.base_difficulty) },
      { label: 'Difficulty rating', value: String(a.difficulty_rating) },
      { label: 'Reward profile', value: a.default_reward_profile_id },
      { label: 'Active', value: a.active ? 'yes' : 'no' },
      { label: 'Revision', value: String(a.revision) },
    ]
  },
}
