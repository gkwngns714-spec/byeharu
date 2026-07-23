// E4 — COMBAT CONTENT · encounter profiles (E1). Owner-only authoring for encounter_profiles + their
// REPLACE-ALL fleet members: list live rows, a New form, per-row Edit + Disable/Enable. The
// reward_override_id picker lists ACTIVE reward profiles plus an explicit "Archetype default" (null)
// option. The embedded MemberSetEditor picks fleet templates by UUID (value = fleet.id). Every write flows
// through the injected useCombatAuthoring hook.
import { useState } from 'react'
import { Button } from '../../components/ui'
import { CombatFormField, COMBAT_INPUT } from './CombatFormField'
import { CombatErrorNotices } from './CombatErrorNotices'
import { MemberSetEditor, type RefOption } from './MemberSetEditor'
import { mapCombatError } from './combatErrorMap'
import { validateEncounterMembers } from './combatMemberValidation'
import { buildEncounterProfileCreate, buildEncounterProfileUpdate, buildSetActive, type EncounterMemberForm, type EncounterProfileForm } from './combatPayloads'
import type { CombatAuthoring } from './useCombatAuthoring'
import type { RewardProfileRow } from './enemyRegistryData'
import type { EncounterProfileRow, FleetTemplateRow } from './fleetEncounterData'

const ENTITY = 'encounter_profile' as const
const TIER = 'E1' as const
const num = (v: string): number => (v.trim() === '' ? Number.NaN : Number(v))
const numValue = (v: number): string | number => (Number.isFinite(v) ? v : '')

interface Draft {
  key: string
  display_name: string
  difficulty: number
  active_encounter_cap: number
  cooldown_seconds: number
  reward_override_id: string | null
  notes: string
  members: EncounterMemberForm[]
}

const BLANK: Draft = {
  key: '', display_name: '', difficulty: Number.NaN, active_encounter_cap: Number.NaN,
  cooldown_seconds: Number.NaN, reward_override_id: null, notes: '', members: [],
}

function draftFromRow(row: EncounterProfileRow): Draft {
  return {
    key: row.key,
    display_name: row.display_name,
    difficulty: row.difficulty,
    active_encounter_cap: row.active_encounter_cap,
    cooldown_seconds: row.cooldown_seconds,
    reward_override_id: row.reward_override_id,
    notes: row.notes ?? '',
    members: row.members.map((m) => ({ fleet_template_id: m.fleet_template_id, weight: m.weight })),
  }
}

function toForm(d: Draft): EncounterProfileForm {
  return {
    key: d.key,
    display_name: d.display_name,
    difficulty: d.difficulty,
    active_encounter_cap: d.active_encounter_cap,
    cooldown_seconds: d.cooldown_seconds,
    reward_override_id: d.reward_override_id,
    notes: d.notes.trim() === '' ? null : d.notes,
    members: d.members,
  }
}

type Editing = { mode: 'none' } | { mode: 'create' } | { mode: 'edit'; key: string; revision: number }

export function EncounterProfileAuthoring({
  rows,
  fleetTemplates,
  rewardProfiles,
  authoring,
}: {
  rows: readonly EncounterProfileRow[]
  fleetTemplates: readonly FleetTemplateRow[]
  rewardProfiles: readonly RewardProfileRow[]
  authoring: CombatAuthoring
}) {
  const [editing, setEditing] = useState<Editing>({ mode: 'none' })
  const [draft, setDraft] = useState<Draft>(BLANK)
  const disabled = authoring.isDisabled(ENTITY)

  const options: RefOption[] = fleetTemplates.map((f) => ({ id: f.id, label: f.display_name, active: f.active }))
  const activeProfiles = rewardProfiles.filter((p) => p.active)

  const startCreate = () => { setDraft(BLANK); setEditing({ mode: 'create' }) }
  const startEdit = (row: EncounterProfileRow) => { setDraft(draftFromRow(row)); setEditing({ mode: 'edit', key: row.key, revision: row.revision }) }
  const close = () => setEditing({ mode: 'none' })

  const submit = () => {
    if (editing.mode === 'create') authoring.submitCreate(ENTITY, buildEncounterProfileCreate(toForm(draft)), close)
    else if (editing.mode === 'edit') authoring.submitUpdate(ENTITY, editing.key, buildEncounterProfileUpdate(editing.key, editing.revision, toForm(draft)), close)
  }

  const attemptKeyFor =
    editing.mode === 'create' ? authoring.keyFor(ENTITY, 'create')
    : editing.mode === 'edit' ? authoring.keyFor(ENTITY, 'update', editing.key) : null
  const attempt = attemptKeyFor ? authoring.attemptFor(attemptKeyFor) : null
  const errView = attempt?.failure ? mapCombatError(attempt.failure, TIER) : null
  const set = (partial: Partial<Draft>) => setDraft((d) => ({ ...d, ...partial }))
  const memberIssues = editing.mode === 'none' ? [] : validateEncounterMembers(draft.members)

  return (
    <div className="flex flex-col gap-2">
      {rows.length === 0 ? (
        <p className="text-xs text-ink-faint">No encounter profiles yet.</p>
      ) : (
        <div className="flex flex-col gap-1">
          {rows.map((row) => {
            const setActiveKey = authoring.keyFor(ENTITY, 'setactive', row.key)
            return (
              <div key={row.id} className="flex items-center justify-between gap-1.5 rounded-md border border-edge bg-surface-2 px-2 py-1.5">
                <span className={`truncate text-sm ${row.active ? 'text-ink' : 'text-ink-faint line-through'}`}>
                  {row.display_name}
                  <span className="ml-1 text-xs text-ink-faint">· {row.members.length} fleets</span>
                </span>
                <div className="flex shrink-0 gap-1">
                  <Button size="sm" variant="ghost" disabled={disabled} onClick={() => startEdit(row)}>Edit</Button>
                  <Button
                    size="sm"
                    variant={row.active ? 'ghost' : 'primary'}
                    disabled={disabled}
                    busy={authoring.isSending(setActiveKey)}
                    onClick={() => authoring.submitSetActive(ENTITY, row.key, buildSetActive('encounter_profile_set_active', row.key, row.revision, !row.active), () => undefined)}
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
        <Button size="sm" disabled={disabled} onClick={startCreate}>New encounter profile</Button>
      ) : (
        <div className="flex flex-col gap-2 rounded-md border border-edge/60 bg-surface p-2">
          {attempt?.failure && (
            <CombatErrorNotices failure={attempt.failure} tier={TIER} boundFields={['key', 'display_name', 'difficulty', 'active_encounter_cap', 'cooldown_seconds', 'reward_override_id']} />
          )}
          {editing.mode === 'create' && (
            <CombatFormField label="Key (permanent id)" error={errView?.fieldErrors['key']}>
              <input className={COMBAT_INPUT} value={draft.key} placeholder="e.g. pirate_ambush" onChange={(e) => set({ key: e.target.value })} />
            </CombatFormField>
          )}
          <CombatFormField label="Name" error={errView?.fieldErrors['display_name']}>
            <input className={COMBAT_INPUT} value={draft.display_name} onChange={(e) => set({ display_name: e.target.value })} />
          </CombatFormField>
          <div className="grid grid-cols-3 gap-2">
            {/* M2 — the E5 resolver (0261) reads only ep.active_encounter_cap/cooldown_seconds/reward_override_id
                (lines 116-119); it never reads encounter_profiles.difficulty. Advisory, non-blocking. */}
            <CombatFormField
              label="Difficulty (1–1000)"
              error={errView?.fieldErrors['difficulty']}
              hint="Recorded, but has no runtime effect yet (danger scales from wave/time)."
            >
              <input className={COMBAT_INPUT} type="number" value={numValue(draft.difficulty)} onChange={(e) => set({ difficulty: num(e.target.value) })} />
            </CombatFormField>
            <CombatFormField label="Active limit (1–100)" error={errView?.fieldErrors['active_encounter_cap']}>
              <input className={COMBAT_INPUT} type="number" value={numValue(draft.active_encounter_cap)} onChange={(e) => set({ active_encounter_cap: num(e.target.value) })} />
            </CombatFormField>
            <CombatFormField label="Cooldown (sec)" error={errView?.fieldErrors['cooldown_seconds']}>
              <input className={COMBAT_INPUT} type="number" value={numValue(draft.cooldown_seconds)} onChange={(e) => set({ cooldown_seconds: num(e.target.value) })} />
            </CombatFormField>
          </div>
          <CombatFormField label="Reward override" error={errView?.fieldErrors['reward_override_id']}>
            <select
              className={COMBAT_INPUT}
              value={draft.reward_override_id ?? ''}
              onChange={(e) => set({ reward_override_id: e.target.value === '' ? null : e.target.value })}
            >
              <option value="">Archetype default (no override)</option>
              {activeProfiles.map((p) => (
                <option key={p.id} value={p.id}>{p.display_name}</option>
              ))}
            </select>
          </CombatFormField>
          <MemberSetEditor kind="encounter" members={draft.members} options={options} issues={memberIssues} disabled={disabled} onChange={(members) => set({ members })} />
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
