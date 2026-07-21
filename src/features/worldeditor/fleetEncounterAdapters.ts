// FLEET TEMPLATES + ENCOUNTER PROFILES (0258) — the two READ-ONLY adapters (fleet templates + encounter
// profiles). Each mirrors the enemyRegistryAdapters.ts read/inspect shape: it READS its catalog's rows
// from the shared snapshot, RESOLVES each to a typed list item, and INSPECTS one row into typed authoring
// fields (including a members summary). It implements NOTHING ELSE — no create/edit/publish/enable/disable
// (deferred authoring ops are explicit + absent, never simulated). Every inspector field is grounded in a
// REAL column fleetEncounterData.ts returns; nothing runtime is invented.
//
// WHY A REGISTRY-SPECIFIC ADAPTER SHAPE (not the map's ReadOnlyLayerAdapter/LayerItem): a fleet template /
// encounter profile is a CATALOG row, not a map feature — it has NO world coordinate, so the map contract's
// mandatory `representation` (point/polygon/circle) + LayerId would have to be FABRICATED. The "no
// fabricated field" law forbids that, so these adapters expose the SAME pure read/inspect surface over a
// coordinate-free item, identical in shape to the E0 registry adapters.
//
// PURE: no React/DOM/fetch/supabase — every read/inspect is a pure function unit-tested directly
// (tests/fleetEncounterAdapters.spec.ts). The tables are DARK; this READS only.
import type { InspectorField } from './worldEditorTypes'
import type {
  FleetEncounterData,
  FleetTemplateRow,
  EncounterProfileRow,
} from './fleetEncounterData'

/** One selectable composition row, as an adapter resolves it (coordinate-free — a catalog row, §above). */
export interface FleetEncounterItem {
  readonly registry: 'enemy_fleet_templates' | 'encounter_profiles'
  /** the stable natural key (both parents' `key` column — the RPC target_id addresses by this). */
  readonly id: string
  readonly label: string
  /** false ⇒ the row was soft-disabled via *_set_active (it survives; it is not deleted). */
  readonly active: boolean
}

/** The READ-ONLY adapter contract (the worldEditorTypes.ReadOnlyLayerAdapter shape, minus the map-only
 *  bits). NOTE the ABSENCE of any create/edit/publish/enable/disable method: that absence IS the
 *  read-only guarantee — authoring is the owner-gated 0258 RPC surface, never here. */
export interface RegistryReadAdapter<TSource> {
  readonly id: 'enemy_fleet_templates' | 'encounter_profiles'
  readonly title: string
  readItems(source: TSource): FleetEncounterItem[]
  inspect(source: TSource, itemId: string): InspectorField[] | null
}

// ── Fleet templates ────────────────────────────────────────────────────────────────────────────────
export const fleetTemplateLayerAdapter: RegistryReadAdapter<FleetEncounterData> = {
  id: 'enemy_fleet_templates',
  title: 'Fleet Templates',
  readItems(source) {
    return source.fleetTemplates.map((f: FleetTemplateRow): FleetEncounterItem => ({
      registry: 'enemy_fleet_templates',
      id: f.key,
      label: f.display_name,
      active: f.active,
    }))
  },
  inspect(source, itemId) {
    const f = source.fleetTemplates.find((x) => x.key === itemId)
    if (!f) return null
    const memberSummary =
      f.members.length === 0
        ? '—'
        : f.members
            .map((m) => `${m.enemy_archetype_id} ×${m.min_count}-${m.max_count}`)
            .join(', ')
    return [
      { label: 'Key', value: f.key },
      { label: 'Display name', value: f.display_name },
      { label: 'Members', value: String(f.members.length) },
      { label: 'Composition', value: memberSummary },
      { label: 'Active', value: f.active ? 'yes' : 'no' },
      { label: 'Revision', value: String(f.revision) },
      { label: 'Notes', value: f.notes ?? '—' },
    ]
  },
}

// ── Encounter profiles ───────────────────────────────────────────────────────────────────────────────
export const encounterProfileLayerAdapter: RegistryReadAdapter<FleetEncounterData> = {
  id: 'encounter_profiles',
  title: 'Encounter Profiles',
  readItems(source) {
    return source.encounterProfiles.map((e: EncounterProfileRow): FleetEncounterItem => ({
      registry: 'encounter_profiles',
      id: e.key,
      label: e.display_name,
      active: e.active,
    }))
  },
  inspect(source, itemId) {
    const e = source.encounterProfiles.find((x) => x.key === itemId)
    if (!e) return null
    const memberSummary =
      e.members.length === 0
        ? '—'
        : e.members.map((m) => `${m.fleet_template_id} @${m.weight}`).join(', ')
    return [
      { label: 'Key', value: e.key },
      { label: 'Display name', value: e.display_name },
      { label: 'Difficulty', value: String(e.difficulty) },
      { label: 'Active cap', value: String(e.active_encounter_cap) },
      { label: 'Cooldown (s)', value: String(e.cooldown_seconds) },
      { label: 'Reward override', value: e.reward_override_id ?? 'archetype default' },
      { label: 'Members', value: String(e.members.length) },
      { label: 'Fleets', value: memberSummary },
      { label: 'Active', value: e.active ? 'yes' : 'no' },
      { label: 'Revision', value: String(e.revision) },
    ]
  },
}
