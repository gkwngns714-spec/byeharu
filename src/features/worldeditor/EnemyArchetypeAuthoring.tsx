// E4 — COMBAT CONTENT · enemy archetypes (E0). Owner-only authoring for the enemy_archetypes catalog:
// list live rows, a New form, per-row Edit + Disable/Enable. The default_reward_profile_id picker lists
// ACTIVE reward profiles only (value = profile.id — the UUID the payload ships, NOT the key). Pure
// presentation + form state; every write flows through the injected useCombatAuthoring hook.
import { useState } from 'react'
import { Button } from '../../components/ui'
import { CombatFormField, COMBAT_INPUT } from './CombatFormField'
import { CombatErrorNotices } from './CombatErrorNotices'
import { mapCombatError } from './combatErrorMap'
import { buildEnemyArchetypeCreate, buildEnemyArchetypeUpdate, buildSetActive, type EnemyArchetypeForm } from './combatPayloads'
import type { CombatAuthoring } from './useCombatAuthoring'
import type { EnemyArchetypeRow, RewardProfileRow } from './enemyRegistryData'

const ENTITY = 'enemy_archetype' as const
const TIER = 'E0' as const
const num = (v: string): number => (v.trim() === '' ? Number.NaN : Number(v))
const numValue = (v: number): string | number => (Number.isFinite(v) ? v : '')

interface Draft {
  key: string
  display_name: string
  faction: string
  unit_type_id: string
  behavior_key: string
  base_difficulty: number
  difficulty_rating: number
  default_reward_profile_id: string
  notes: string
}

const BLANK: Draft = {
  key: '', display_name: '', faction: '', unit_type_id: '', behavior_key: '',
  base_difficulty: Number.NaN, difficulty_rating: Number.NaN, default_reward_profile_id: '', notes: '',
}

function draftFromRow(row: EnemyArchetypeRow): Draft {
  return {
    key: row.key,
    display_name: row.display_name,
    faction: row.faction ?? '',
    unit_type_id: row.unit_type_id,
    behavior_key: row.behavior_key ?? '',
    base_difficulty: row.base_difficulty,
    difficulty_rating: row.difficulty_rating,
    default_reward_profile_id: row.default_reward_profile_id,
    notes: row.notes ?? '',
  }
}

function toForm(d: Draft): EnemyArchetypeForm {
  return {
    key: d.key,
    display_name: d.display_name,
    faction: d.faction,
    unit_type_id: d.unit_type_id,
    behavior_key: d.behavior_key,
    base_difficulty: d.base_difficulty,
    default_reward_profile_id: d.default_reward_profile_id,
    difficulty_rating: d.difficulty_rating,
    stat_overrides: {},
    notes: d.notes.trim() === '' ? null : d.notes,
  }
}

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
  const [draft, setDraft] = useState<Draft>(BLANK)
  const disabled = authoring.isDisabled(ENTITY)
  const activeProfiles = rewardProfiles.filter((p) => p.active)

  const startCreate = () => { setDraft(BLANK); setEditing({ mode: 'create' }) }
  const startEdit = (row: EnemyArchetypeRow) => { setDraft(draftFromRow(row)); setEditing({ mode: 'edit', key: row.key, revision: row.revision }) }
  const close = () => setEditing({ mode: 'none' })

  const submit = () => {
    if (editing.mode === 'create') authoring.submitCreate(ENTITY, buildEnemyArchetypeCreate(toForm(draft)), close)
    else if (editing.mode === 'edit') authoring.submitUpdate(ENTITY, editing.key, buildEnemyArchetypeUpdate(editing.key, editing.revision, toForm(draft)), close)
  }

  const attemptKeyFor =
    editing.mode === 'create' ? authoring.keyFor(ENTITY, 'create')
    : editing.mode === 'edit' ? authoring.keyFor(ENTITY, 'update', editing.key) : null
  const attempt = attemptKeyFor ? authoring.attemptFor(attemptKeyFor) : null
  const errView = attempt?.failure ? mapCombatError(attempt.failure, TIER) : null
  const set = (partial: Partial<Draft>) => setDraft((d) => ({ ...d, ...partial }))

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
            <CombatFormField label="Difficulty rating" error={errView?.fieldErrors['difficulty_rating']}>
              <input className={COMBAT_INPUT} type="number" value={numValue(draft.difficulty_rating)} onChange={(e) => set({ difficulty_rating: num(e.target.value) })} />
            </CombatFormField>
          </div>
          <div className="grid grid-cols-2 gap-2">
            <CombatFormField label="Faction (optional)">
              <input className={COMBAT_INPUT} value={draft.faction} placeholder="e.g. pirate" onChange={(e) => set({ faction: e.target.value })} />
            </CombatFormField>
            <CombatFormField label="Behavior (optional)">
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
