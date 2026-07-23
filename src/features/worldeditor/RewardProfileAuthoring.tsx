// E4 — COMBAT CONTENT · reward profiles (E0). Owner-only authoring for the reward_profiles catalog: list
// the live rows (public read), a New form, per-row Edit + Disable/Enable. Pure presentation + form state;
// EVERY write goes through the injected useCombatAuthoring hook (the ONE command path) — this file never
// touches the command client. resource_grants is authored as friendly fields (metal base + optional danger
// coefficient) and always carries the fixed multiplier_ref the server whitelists.
import { useState } from 'react'
import { Button } from '../../components/ui'
import { CombatFormField, COMBAT_INPUT } from './CombatFormField'
import { CombatErrorNotices } from './CombatErrorNotices'
import { mapCombatError } from './combatErrorMap'
import { buildRewardProfileCreate, buildRewardProfileUpdate, buildSetActive, type RewardProfileForm } from './combatPayloads'
import type { CombatAuthoring } from './useCombatAuthoring'
import type { RewardProfileRow } from './enemyRegistryData'

const ENTITY = 'reward_profile' as const
const TIER = 'E0' as const
const num = (v: string): number => (v.trim() === '' ? Number.NaN : Number(v))
const numValue = (v: number): string | number => (Number.isFinite(v) ? v : '')

interface Draft {
  key: string
  display_name: string
  metal_base: number
  danger_coeff: number
  notes: string
}

const BLANK: Draft = { key: '', display_name: '', metal_base: Number.NaN, danger_coeff: Number.NaN, notes: '' }

function draftFromRow(row: RewardProfileRow): Draft {
  const metal = (row.resource_grants?.metal ?? {}) as Record<string, unknown>
  return {
    key: row.key,
    display_name: row.display_name,
    metal_base: typeof metal.base === 'number' ? metal.base : Number.NaN,
    danger_coeff: typeof metal.danger_coeff === 'number' ? metal.danger_coeff : Number.NaN,
    notes: row.notes ?? '',
  }
}

function toForm(d: Draft): RewardProfileForm {
  const resource_grants: Record<string, unknown> = {}
  if (Number.isFinite(d.metal_base)) {
    const metal: Record<string, unknown> = { base: d.metal_base, multiplier_ref: 'reward_multiplier' }
    if (Number.isFinite(d.danger_coeff)) metal.danger_coeff = d.danger_coeff
    resource_grants.metal = metal
  }
  return { key: d.key, display_name: d.display_name, resource_grants, notes: d.notes.trim() === '' ? null : d.notes }
}

type Editing = { mode: 'none' } | { mode: 'create' } | { mode: 'edit'; key: string; revision: number }

export function RewardProfileAuthoring({
  rows,
  authoring,
}: {
  rows: readonly RewardProfileRow[]
  authoring: CombatAuthoring
}) {
  const [editing, setEditing] = useState<Editing>({ mode: 'none' })
  const [draft, setDraft] = useState<Draft>(BLANK)
  const disabled = authoring.isDisabled(ENTITY)

  const startCreate = () => {
    setDraft(BLANK)
    setEditing({ mode: 'create' })
  }
  const startEdit = (row: RewardProfileRow) => {
    setDraft(draftFromRow(row))
    setEditing({ mode: 'edit', key: row.key, revision: row.revision })
  }
  const close = () => setEditing({ mode: 'none' })

  const submit = () => {
    if (editing.mode === 'create') {
      authoring.submitCreate(ENTITY, buildRewardProfileCreate(toForm(draft)), close)
    } else if (editing.mode === 'edit') {
      authoring.submitUpdate(ENTITY, editing.key, buildRewardProfileUpdate(editing.key, editing.revision, toForm(draft)), close)
    }
  }

  const attemptKeyFor =
    editing.mode === 'create'
      ? authoring.keyFor(ENTITY, 'create')
      : editing.mode === 'edit'
        ? authoring.keyFor(ENTITY, 'update', editing.key)
        : null
  const attempt = attemptKeyFor ? authoring.attemptFor(attemptKeyFor) : null
  const errView = attempt?.failure ? mapCombatError(attempt.failure, TIER) : null
  const set = (partial: Partial<Draft>) => setDraft((d) => ({ ...d, ...partial }))

  return (
    <div className="flex flex-col gap-2">
      {rows.length === 0 ? (
        <p className="text-xs text-ink-faint">No reward profiles yet.</p>
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
                    onClick={() =>
                      authoring.submitSetActive(
                        ENTITY,
                        row.key,
                        buildSetActive('reward_profile_set_active', row.key, row.revision, !row.active),
                        () => undefined,
                      )
                    }
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
        <Button size="sm" disabled={disabled} onClick={startCreate}>New reward profile</Button>
      ) : (
        <div className="flex flex-col gap-2 rounded-md border border-edge/60 bg-surface p-2">
          {attempt?.failure && errView && (
            <CombatErrorNotices failure={attempt.failure} tier={TIER} boundFields={['key', 'display_name']} />
          )}
          {editing.mode === 'create' && (
            <CombatFormField label="Key (permanent id)" error={errView?.fieldErrors['key']}>
              <input className={COMBAT_INPUT} value={draft.key} placeholder="e.g. pirate_standard" onChange={(e) => set({ key: e.target.value })} />
            </CombatFormField>
          )}
          <CombatFormField label="Name" error={errView?.fieldErrors['display_name']}>
            <input className={COMBAT_INPUT} value={draft.display_name} placeholder="e.g. Standard Pirate Reward" onChange={(e) => set({ display_name: e.target.value })} />
          </CombatFormField>
          <div className="grid grid-cols-2 gap-2">
            <CombatFormField label="Metal base">
              <input className={COMBAT_INPUT} type="number" value={numValue(draft.metal_base)} onChange={(e) => set({ metal_base: num(e.target.value) })} />
            </CombatFormField>
            <CombatFormField label="Danger coeff (optional)">
              <input className={COMBAT_INPUT} type="number" step={0.1} value={numValue(draft.danger_coeff)} onChange={(e) => set({ danger_coeff: num(e.target.value) })} />
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
