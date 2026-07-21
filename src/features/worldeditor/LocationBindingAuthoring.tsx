// E4 — COMBAT CONTENT · location → encounter bindings (E2). Owner-only authoring for
// location_encounter_bindings: list live rows, a New form, per-row Edit (weight only — the
// (location, encounter) pair is the stable address) + Disable/Enable. The location picker lists ALL
// locations (a binding may be PRECONFIGURED against an inactive location — liveness is a runtime filter, so
// there is no location_inactive rejection; a small hint says so). The encounter picker lists ACTIVE
// encounter profiles only. On update/set_active the target is the binding UUID (row.id). Every write flows
// through the injected useCombatAuthoring hook.
import { useState } from 'react'
import { Button } from '../../components/ui'
import { CombatFormField, COMBAT_INPUT } from './CombatFormField'
import { CombatErrorNotices } from './CombatErrorNotices'
import { mapCombatError } from './combatErrorMap'
import { buildLocationBindingCreate, buildLocationBindingUpdate, buildSetActive, type LocationBindingForm } from './combatPayloads'
import type { CombatAuthoring } from './useCombatAuthoring'
import type { EncounterProfileRow } from './fleetEncounterData'
import type { LocationEncounterBindingRow } from './locationEncounterBindingData'
import type { MapLocation } from '../map/mapTypes'

const ENTITY = 'location_binding' as const
const TIER = 'E2' as const
const num = (v: string): number => (v.trim() === '' ? Number.NaN : Number(v))
const numValue = (v: number): string | number => (Number.isFinite(v) ? v : '')

interface Draft {
  location_id: string
  encounter_profile_id: string
  weight: number
}

const BLANK: Draft = { location_id: '', encounter_profile_id: '', weight: 1 }

function toForm(d: Draft): LocationBindingForm {
  return { location_id: d.location_id, encounter_profile_id: d.encounter_profile_id, weight: d.weight }
}

type Editing =
  | { mode: 'none' }
  | { mode: 'create' }
  | { mode: 'edit'; id: string; revision: number }

export function LocationBindingAuthoring({
  rows,
  locations,
  encounterProfiles,
  authoring,
}: {
  rows: readonly LocationEncounterBindingRow[]
  locations: readonly MapLocation[]
  encounterProfiles: readonly EncounterProfileRow[]
  authoring: CombatAuthoring
}) {
  const [editing, setEditing] = useState<Editing>({ mode: 'none' })
  const [draft, setDraft] = useState<Draft>(BLANK)
  const disabled = authoring.isDisabled(ENTITY)
  const activeEncounters = encounterProfiles.filter((e) => e.active)

  const locName = (id: string) => locations.find((l) => l.id === id)?.name ?? id
  const encName = (id: string) => encounterProfiles.find((e) => e.id === id)?.display_name ?? id

  const startCreate = () => { setDraft(BLANK); setEditing({ mode: 'create' }) }
  const startEdit = (row: LocationEncounterBindingRow) => {
    setDraft({ location_id: row.location_id, encounter_profile_id: row.encounter_profile_id, weight: row.weight })
    setEditing({ mode: 'edit', id: row.id, revision: row.revision })
  }
  const close = () => setEditing({ mode: 'none' })

  const submit = () => {
    if (editing.mode === 'create') authoring.submitCreate(ENTITY, buildLocationBindingCreate(toForm(draft)), close)
    else if (editing.mode === 'edit') authoring.submitUpdate(ENTITY, editing.id, buildLocationBindingUpdate(editing.id, editing.revision, toForm(draft)), close)
  }

  const attemptKeyFor =
    editing.mode === 'create' ? authoring.keyFor(ENTITY, 'create')
    : editing.mode === 'edit' ? authoring.keyFor(ENTITY, 'update', editing.id) : null
  const attempt = attemptKeyFor ? authoring.attemptFor(attemptKeyFor) : null
  const errView = attempt?.failure ? mapCombatError(attempt.failure, TIER) : null
  const set = (partial: Partial<Draft>) => setDraft((d) => ({ ...d, ...partial }))

  return (
    <div className="flex flex-col gap-2">
      {rows.length === 0 ? (
        <p className="text-xs text-ink-faint">No location bindings yet.</p>
      ) : (
        <div className="flex flex-col gap-1">
          {rows.map((row) => {
            const setActiveKey = authoring.keyFor(ENTITY, 'setactive', row.id)
            return (
              <div key={row.id} className="flex items-center justify-between gap-1.5 rounded-md border border-edge bg-surface-2 px-2 py-1.5">
                <span className={`truncate text-sm ${row.active ? 'text-ink' : 'text-ink-faint line-through'}`}>
                  {locName(row.location_id)} → {encName(row.encounter_profile_id)}
                  <span className="ml-1 text-xs text-ink-faint">· w{row.weight}</span>
                </span>
                <div className="flex shrink-0 gap-1">
                  <Button size="sm" variant="ghost" disabled={disabled} onClick={() => startEdit(row)}>Edit</Button>
                  <Button
                    size="sm"
                    variant={row.active ? 'ghost' : 'primary'}
                    disabled={disabled}
                    busy={authoring.isSending(setActiveKey)}
                    onClick={() => authoring.submitSetActive(ENTITY, row.id, buildSetActive('location_encounter_binding_set_active', row.id, row.revision, !row.active), () => undefined)}
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
        <Button size="sm" disabled={disabled} onClick={startCreate}>New location binding</Button>
      ) : (
        <div className="flex flex-col gap-2 rounded-md border border-edge/60 bg-surface p-2">
          {attempt?.failure && (
            <CombatErrorNotices failure={attempt.failure} tier={TIER} boundFields={['location_id', 'encounter_profile_id', 'weight']} />
          )}
          {editing.mode === 'edit' ? (
            <p className="text-xs text-ink-faint">
              {locName(draft.location_id)} → {encName(draft.encounter_profile_id)} (the pairing is fixed — only weight can change)
            </p>
          ) : (
            <>
              <CombatFormField label="Location" error={errView?.fieldErrors['location_id']}>
                <select className={COMBAT_INPUT} value={draft.location_id} onChange={(e) => set({ location_id: e.target.value })}>
                  <option value="">Choose…</option>
                  {locations.map((l) => (
                    <option key={l.id} value={l.id}>{l.name}</option>
                  ))}
                </select>
              </CombatFormField>
              <p className="text-xs text-ink-faint">An inactive location is OK — the binding is preconfigured and takes effect when the location goes live.</p>
              <CombatFormField label="Encounter" error={errView?.fieldErrors['encounter_profile_id']}>
                <select className={COMBAT_INPUT} value={draft.encounter_profile_id} onChange={(e) => set({ encounter_profile_id: e.target.value })}>
                  <option value="">Choose…</option>
                  {activeEncounters.map((en) => (
                    <option key={en.id} value={en.id}>{en.display_name}</option>
                  ))}
                </select>
              </CombatFormField>
            </>
          )}
          <CombatFormField label="Weight (> 0)" error={errView?.fieldErrors['weight']}>
            <input className={COMBAT_INPUT} type="number" value={numValue(draft.weight)} onChange={(e) => set({ weight: num(e.target.value) })} />
          </CombatFormField>
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
