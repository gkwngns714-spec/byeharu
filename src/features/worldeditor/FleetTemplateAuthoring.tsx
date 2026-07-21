// E4 — COMBAT CONTENT · fleet templates (E1). Owner-only authoring for enemy_fleet_templates + their
// REPLACE-ALL members: list live rows, a New form, per-row Edit + Disable/Enable. The embedded
// MemberSetEditor picks enemy archetypes by UUID (value = archetype.id). Advisory member bounds
// (combatMemberValidation) flag bad rows inline but NEVER block — the server is the authority. Every
// write flows through the injected useCombatAuthoring hook.
import { useState } from 'react'
import { Button } from '../../components/ui'
import { CombatFormField, COMBAT_INPUT } from './CombatFormField'
import { CombatErrorNotices } from './CombatErrorNotices'
import { MemberSetEditor, type RefOption } from './MemberSetEditor'
import { mapCombatError } from './combatErrorMap'
import { fleetAdvisories, validateFleetMembers } from './combatMemberValidation'
import { buildFleetTemplateCreate, buildFleetTemplateUpdate, buildSetActive, type FleetMemberForm, type FleetTemplateForm } from './combatPayloads'
import type { CombatAuthoring } from './useCombatAuthoring'
import type { EnemyArchetypeRow } from './enemyRegistryData'
import type { FleetTemplateRow } from './fleetEncounterData'

const ENTITY = 'fleet_template' as const
const TIER = 'E1' as const

interface Draft {
  key: string
  display_name: string
  notes: string
  members: FleetMemberForm[]
}

const BLANK: Draft = { key: '', display_name: '', notes: '', members: [] }

function draftFromRow(row: FleetTemplateRow): Draft {
  return {
    key: row.key,
    display_name: row.display_name,
    notes: row.notes ?? '',
    members: row.members.map((m) => ({
      enemy_archetype_id: m.enemy_archetype_id,
      min_count: m.min_count,
      max_count: m.max_count,
      weight: m.weight,
      elite_chance: m.elite_chance,
    })),
  }
}

function toForm(d: Draft): FleetTemplateForm {
  return { key: d.key, display_name: d.display_name, notes: d.notes.trim() === '' ? null : d.notes, members: d.members }
}

type Editing = { mode: 'none' } | { mode: 'create' } | { mode: 'edit'; key: string; revision: number }

export function FleetTemplateAuthoring({
  rows,
  archetypes,
  authoring,
}: {
  rows: readonly FleetTemplateRow[]
  archetypes: readonly EnemyArchetypeRow[]
  authoring: CombatAuthoring
}) {
  const [editing, setEditing] = useState<Editing>({ mode: 'none' })
  const [draft, setDraft] = useState<Draft>(BLANK)
  const disabled = authoring.isDisabled(ENTITY)

  // Ref options from the RAW archetype rows (id = the UUID a member ships); inactive shown greyed.
  const options: RefOption[] = archetypes.map((a) => ({ id: a.id, label: a.display_name, active: a.active }))

  const startCreate = () => { setDraft(BLANK); setEditing({ mode: 'create' }) }
  const startEdit = (row: FleetTemplateRow) => { setDraft(draftFromRow(row)); setEditing({ mode: 'edit', key: row.key, revision: row.revision }) }
  const close = () => setEditing({ mode: 'none' })

  const submit = () => {
    if (editing.mode === 'create') authoring.submitCreate(ENTITY, buildFleetTemplateCreate(toForm(draft)), close)
    else if (editing.mode === 'edit') authoring.submitUpdate(ENTITY, editing.key, buildFleetTemplateUpdate(editing.key, editing.revision, toForm(draft)), close)
  }

  const attemptKeyFor =
    editing.mode === 'create' ? authoring.keyFor(ENTITY, 'create')
    : editing.mode === 'edit' ? authoring.keyFor(ENTITY, 'update', editing.key) : null
  const attempt = attemptKeyFor ? authoring.attemptFor(attemptKeyFor) : null
  const errView = attempt?.failure ? mapCombatError(attempt.failure, TIER) : null
  const set = (partial: Partial<Draft>) => setDraft((d) => ({ ...d, ...partial }))
  const memberIssues = editing.mode === 'none' ? [] : validateFleetMembers(draft.members)
  // Advisory-only heads-ups (runtime unit-cap trim, elite-inert) — never gate Save (flag-don't-clamp).
  const memberAdvisories = editing.mode === 'none' ? [] : fleetAdvisories(draft.members)

  return (
    <div className="flex flex-col gap-2">
      {rows.length === 0 ? (
        <p className="text-xs text-ink-faint">No fleet templates yet.</p>
      ) : (
        <div className="flex flex-col gap-1">
          {rows.map((row) => {
            const setActiveKey = authoring.keyFor(ENTITY, 'setactive', row.key)
            return (
              <div key={row.id} className="flex items-center justify-between gap-1.5 rounded-md border border-edge bg-surface-2 px-2 py-1.5">
                <span className={`truncate text-sm ${row.active ? 'text-ink' : 'text-ink-faint line-through'}`}>
                  {row.display_name}
                  <span className="ml-1 text-xs text-ink-faint">· {row.members.length} enemies</span>
                </span>
                <div className="flex shrink-0 gap-1">
                  <Button size="sm" variant="ghost" disabled={disabled} onClick={() => startEdit(row)}>Edit</Button>
                  <Button
                    size="sm"
                    variant={row.active ? 'ghost' : 'primary'}
                    disabled={disabled}
                    busy={authoring.isSending(setActiveKey)}
                    onClick={() => authoring.submitSetActive(ENTITY, row.key, buildSetActive('enemy_fleet_template_set_active', row.key, row.revision, !row.active), () => undefined)}
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
        <Button size="sm" disabled={disabled} onClick={startCreate}>New fleet template</Button>
      ) : (
        <div className="flex flex-col gap-2 rounded-md border border-edge/60 bg-surface p-2">
          {attempt?.failure && (
            <CombatErrorNotices failure={attempt.failure} tier={TIER} boundFields={['key', 'display_name']} />
          )}
          {editing.mode === 'create' && (
            <CombatFormField label="Key (permanent id)" error={errView?.fieldErrors['key']}>
              <input className={COMBAT_INPUT} value={draft.key} placeholder="e.g. pirate_light_pair" onChange={(e) => set({ key: e.target.value })} />
            </CombatFormField>
          )}
          <CombatFormField label="Name" error={errView?.fieldErrors['display_name']}>
            <input className={COMBAT_INPUT} value={draft.display_name} onChange={(e) => set({ display_name: e.target.value })} />
          </CombatFormField>
          <MemberSetEditor kind="fleet" members={draft.members} options={options} issues={memberIssues} advisories={memberAdvisories} disabled={disabled} onChange={(members) => set({ members })} />
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
