// E4 — COMBAT CONTENT · enemy archetypes (E0). Owner-only authoring for the enemy_archetypes catalog:
// list live rows, a New form, per-row Edit + Disable/Enable. The default_reward_profile_id picker lists
// ACTIVE reward profiles only (value = profile.id — the UUID the payload ships, NOT the key). Pure
// presentation + form state; every write flows through the injected useCombatAuthoring hook.
import { useState } from 'react'
import { Button } from '../../components/ui'
import { CombatFormField, COMBAT_INPUT } from './CombatFormField'
import { CombatErrorNotices } from './CombatErrorNotices'
import { mapCombatError } from './combatErrorMap'
import { buildEnemyArchetypeCreate, buildEnemyArchetypeUpdate, buildSetActive } from './combatPayloads'
import {
  BLANK_ARCHETYPE_DRAFT,
  archetypeDraftFromRow,
  archetypeDraftToForm,
  type ArchetypeDraft,
} from './enemyArchetypeDraft'
import type { CombatAuthoring } from './useCombatAuthoring'
import type { EnemyArchetypeRow, RewardProfileRow } from './enemyRegistryData'

const ENTITY = 'enemy_archetype' as const
const TIER = 'E0' as const
const num = (v: string): number => (v.trim() === '' ? Number.NaN : Number(v))
const numValue = (v: number): string | number => (Number.isFinite(v) ? v : '')
// M2 — knobs the E5 resolver does NOT read (0261 archetype join, lines 164-170, selects only
// enemy_archetype_id/min_count/max_count/elite_chance + a.unit_type_id/base_difficulty/stat_overrides/
// default_reward_profile_id — NEITHER difficulty_rating NOR behavior_key). Advisory, non-blocking.
const INERT_HINT = 'Recorded, but has no runtime effect yet.'

type Editing = { mode: 'none' } | { mode: 'create' } | { mode: 'edit'; key: string; revision: number }

export function EnemyArchetypeAuthoring({
  rows,
  rewardProfiles,
  authoring,
}: {
  rows: readonly EnemyArchetypeRow[]
  rewardProfiles: readonly RewardProfileRow[]
  authoring: CombatAuthoring
}) {
  const [editing, setEditing] = useState<Editing>({ mode: 'none' })
  const [draft, setDraft] = useState<ArchetypeDraft>(BLANK_ARCHETYPE_DRAFT)
  const disabled = authoring.isDisabled(ENTITY)
  const activeProfiles = rewardProfiles.filter((p) => p.active)

  const startCreate = () => { setDraft(BLANK_ARCHETYPE_DRAFT); setEditing({ mode: 'create' }) }
  const startEdit = (row: EnemyArchetypeRow) => { setDraft(archetypeDraftFromRow(row)); setEditing({ mode: 'edit', key: row.key, revision: row.revision }) }
  const close = () => setEditing({ mode: 'none' })

  const submit = () => {
    if (editing.mode === 'create') authoring.submitCreate(ENTITY, buildEnemyArchetypeCreate(archetypeDraftToForm(draft)), close)
    else if (editing.mode === 'edit') authoring.submitUpdate(ENTITY, editing.key, buildEnemyArchetypeUpdate(editing.key, editing.revision, archetypeDraftToForm(draft)), close)
  }

  const attemptKeyFor =
    editing.mode === 'create' ? authoring.keyFor(ENTITY, 'create')
    : editing.mode === 'edit' ? authoring.keyFor(ENTITY, 'update', editing.key) : null
  const attempt = attemptKeyFor ? authoring.attemptFor(attemptKeyFor) : null
  const errView = attempt?.failure ? mapCombatError(attempt.failure, TIER) : null
  const set = (partial: Partial<ArchetypeDraft>) => setDraft((d) => ({ ...d, ...partial }))

  return (
    <div className="flex flex-col gap-2">
      {rows.length === 0 ? (
        <p className="text-xs text-ink-faint">No enemy archetypes yet.</p>
      ) : (
        <div className="flex flex-col gap-1">
          {rows.map((row) => {
            const setActiveKey = authoring.keyFor(ENTITY, 'setactive', row.key)
            return (
              <div key={row.id} className="flex items-center justify-between gap-1.5 rounded-md border border-edge bg-surface-2 px-2 py-1.5">
                <span className={`truncate text-sm ${row.active ? 'text-ink' : 'text-ink-faint line-through'}`}>{row.display_name}</span>
                <div className="flex shrink-0 gap-1">
                  <Button size="sm" variant="ghost" disabled={disabled} onClick={() => startEdit(row)}>Edit</Button>
                  <Button
                    size="sm"
                    variant={row.active ? 'ghost' : 'primary'}
                    disabled={disabled}
                    busy={authoring.isSending(setActiveKey)}
                    onClick={() => authoring.submitSetActive(ENTITY, row.key, buildSetActive('enemy_archetype_set_active', row.key, row.revision, !row.active), () => undefined)}
                  >
                    {row.active ? 'Disable' : 'Enable'}
                  </Button>
                </div>
              </div>
            )
          })}
        </div>
      )}

      {editing.mode === 'none' ? (
        <Button size="sm" disabled={disabled} onClick={startCreate}>New enemy archetype</Button>
      ) : (
        <div className="flex flex-col gap-2 rounded-md border border-edge/60 bg-surface p-2">
          {attempt?.failure && (
            <CombatErrorNotices failure={attempt.failure} tier={TIER} boundFields={['key', 'display_name', 'unit_type_id', 'base_difficulty', 'default_reward_profile_id']} />
          )}
          {editing.mode === 'create' && (
            <CombatFormField label="Key (permanent id)" error={errView?.fieldErrors['key']}>
              <input className={COMBAT_INPUT} value={draft.key} placeholder="e.g. pirate_light" onChange={(e) => set({ key: e.target.value })} />
            </CombatFormField>
          )}
          <CombatFormField label="Name" error={errView?.fieldErrors['display_name']}>
            <input className={COMBAT_INPUT} value={draft.display_name} onChange={(e) => set({ display_name: e.target.value })} />
          </CombatFormField>
          <CombatFormField label="Unit type" error={errView?.fieldErrors['unit_type_id']}>
            <input className={COMBAT_INPUT} value={draft.unit_type_id} placeholder="e.g. pirate_synthetic" onChange={(e) => set({ unit_type_id: e.target.value })} />
          </CombatFormField>
          <CombatFormField label="Reward profile" error={errView?.fieldErrors['default_reward_profile_id']}>
            <select className={COMBAT_INPUT} value={draft.default_reward_profile_id} onChange={(e) => set({ default_reward_profile_id: e.target.value })}>
              <option value="">Choose…</option>
              {activeProfiles.map((p) => (
                <option key={p.id} value={p.id}>{p.display_name}</option>
              ))}
            </select>
          </CombatFormField>
          <div className="grid grid-cols-2 gap-2">
            <CombatFormField label="Base difficulty (0–1000)" error={errView?.fieldErrors['base_difficulty']}>
              <input className={COMBAT_INPUT} type="number" value={numValue(draft.base_difficulty)} onChange={(e) => set({ base_difficulty: num(e.target.value) })} />
            </CombatFormField>
            <CombatFormField label="Difficulty rating" error={errView?.fieldErrors['difficulty_rating']} hint={INERT_HINT}>
              <input className={COMBAT_INPUT} type="number" value={numValue(draft.difficulty_rating)} onChange={(e) => set({ difficulty_rating: num(e.target.value) })} />
            </CombatFormField>
          </div>
          <div className="grid grid-cols-2 gap-2">
            <CombatFormField label="Faction (optional)">
              <input className={COMBAT_INPUT} value={draft.faction} placeholder="e.g. pirate" onChange={(e) => set({ faction: e.target.value })} />
            </CombatFormField>
            <CombatFormField label="Behavior (optional)" hint={INERT_HINT}>
              <input className={COMBAT_INPUT} value={draft.behavior_key} placeholder="e.g. spatial_synthetic" onChange={(e) => set({ behavior_key: e.target.value })} />
            </CombatFormField>
          </div>
          <div className="flex gap-1.5">
            <Button size="sm" variant="primary" busy={attempt?.phase === 'sending'} busyLabel="Saving…" onClick={submit}>
              {attempt?.phase === 'failed' ? 'Retry save' : 'Save'}
            </Button>
            <Button size="sm" variant="ghost" onClick={close}>Cancel</Button>
          </div>
        </div>
      )}
    </div>
  )
}
