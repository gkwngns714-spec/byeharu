// E4 — COMBAT CONTENT: the generic REPLACE-ALL member-set editor (add/remove rows; whole members array
// ships on save — never a per-member patch RPC). Pure presentation: it holds no state and issues no
// command; the parent owns the array and passes onChange. The ref dropdown is built from the RAW active
// rows because a member ref is the UUID `id` (NOT the human key) — fleet members choose an enemy archetype
// (value = archetype.id), encounter members choose a fleet template (value = fleet.id). Inactive rows are
// shown GREYED + non-selectable so an existing member that points at a now-disabled row still reads, but a
// new selection can only land on an active one. Advisory member issues (combatMemberValidation) render
// inline; they are FLAGS, never clamps.
import { Button } from '../../components/ui'
import { COMBAT_INPUT } from './CombatFormField'
import type { EncounterMemberForm, FleetMemberForm } from './combatPayloads'
import type { MemberIssue } from './combatMemberValidation'

/** One selectable ref row for the dropdown (id = the UUID the payload ships; active gates selection). */
export interface RefOption {
  readonly id: string
  readonly label: string
  readonly active: boolean
}

const num = (v: string): number => (v.trim() === '' ? Number.NaN : Number(v))
const numValue = (v: number): string | number => (Number.isFinite(v) ? v : '')

/** The message for a given row index from the issues[] (first match), or undefined. */
function issueFor(issues: readonly MemberIssue[], index: number): string | undefined {
  return issues.find((i) => i.index === index)?.message
}

/** Advisory (non-blocking) messages bound to a given row index. */
function rowAdvisories(advisories: readonly MemberIssue[], index: number): MemberIssue[] {
  return advisories.filter((a) => a.index === index)
}

/** Advisory (non-blocking) messages that apply to the whole set (no row index). */
function setAdvisories(advisories: readonly MemberIssue[]): MemberIssue[] {
  return advisories.filter((a) => a.index === undefined)
}

function RefSelect({
  value,
  options,
  disabled,
  onChange,
}: {
  value: string
  options: readonly RefOption[]
  disabled?: boolean
  onChange: (id: string) => void
}) {
  return (
    <select className={COMBAT_INPUT} value={value} disabled={disabled} onChange={(e) => onChange(e.target.value)}>
      <option value="">Choose…</option>
      {options.map((o) => (
        <option key={o.id} value={o.id} disabled={!o.active}>
          {o.label}
          {o.active ? '' : ' (disabled)'}
        </option>
      ))}
    </select>
  )
}

type MemberSetEditorProps =
  | {
      readonly kind: 'fleet'
      readonly members: readonly FleetMemberForm[]
      readonly options: readonly RefOption[]
      readonly issues: readonly MemberIssue[]
      /** Purely non-blocking heads-up notes (never disable Save). */
      readonly advisories?: readonly MemberIssue[]
      readonly disabled?: boolean
      readonly onChange: (members: FleetMemberForm[]) => void
    }
  | {
      readonly kind: 'encounter'
      readonly members: readonly EncounterMemberForm[]
      readonly options: readonly RefOption[]
      readonly issues: readonly MemberIssue[]
      readonly advisories?: readonly MemberIssue[]
      readonly disabled?: boolean
      readonly onChange: (members: EncounterMemberForm[]) => void
    }

export function MemberSetEditor(props: MemberSetEditorProps) {
  const { options, issues, disabled } = props
  const advisories = props.advisories ?? []

  if (props.kind === 'fleet') {
    const { members, onChange } = props
    const patch = (index: number, partial: Partial<FleetMemberForm>) =>
      onChange(members.map((m, i) => (i === index ? { ...m, ...partial } : m)))
    const remove = (index: number) => onChange(members.filter((_, i) => i !== index))
    const add = () =>
      onChange([...members, { enemy_archetype_id: '', min_count: 1, max_count: 1, weight: 1, elite_chance: 0 }])
    return (
      <div className="flex flex-col gap-1.5">
        <div className="text-xs text-ink-muted">Enemies in this fleet</div>
        {members.map((m, i) => (
          <div key={i} className="flex flex-col gap-1 rounded-md border border-edge/60 bg-surface-2 p-1.5">
            <RefSelect
              value={m.enemy_archetype_id}
              options={options}
              disabled={disabled}
              onChange={(id) => patch(i, { enemy_archetype_id: id })}
            />
            <div className="grid grid-cols-4 gap-1">
              <input className={COMBAT_INPUT} type="number" aria-label="Min count" title="Min count" disabled={disabled}
                value={numValue(m.min_count)} onChange={(e) => patch(i, { min_count: num(e.target.value) })} />
              <input className={COMBAT_INPUT} type="number" aria-label="Max count" title="Max count" disabled={disabled}
                value={numValue(m.max_count)} onChange={(e) => patch(i, { max_count: num(e.target.value) })} />
              <input className={COMBAT_INPUT} type="number" aria-label="Weight" title="Weight" disabled={disabled}
                value={numValue(m.weight)} onChange={(e) => patch(i, { weight: num(e.target.value) })} />
              <input className={COMBAT_INPUT} type="number" step={0.05} aria-label="Elite chance" title="Elite chance (0–1)" disabled={disabled}
                value={numValue(m.elite_chance)} onChange={(e) => patch(i, { elite_chance: num(e.target.value) })} />
            </div>
            {issueFor(issues, i) ? <div className="text-xs text-danger">{issueFor(issues, i)}</div> : null}
            {/* per-row ADVISORY notes (non-blocking, e.g. elite-inert) — subtle, never a Save gate */}
            {rowAdvisories(advisories, i).map((a) => (
              <div key={a.code} className="text-xs text-ink-faint">{a.message}</div>
            ))}
            <Button size="sm" variant="ghost" disabled={disabled} onClick={() => remove(i)}>
              Remove
            </Button>
          </div>
        ))}
        {/* whole-set ADVISORY notes (non-blocking, e.g. runtime unit-cap trimming) near the members block */}
        {setAdvisories(advisories).map((a) => (
          <div key={a.code} className="text-xs text-warning">{a.message}</div>
        ))}
        <Button size="sm" variant="ghost" disabled={disabled} onClick={add}>
          Add enemy
        </Button>
      </div>
    )
  }

  const { members, onChange } = props
  const patch = (index: number, partial: Partial<EncounterMemberForm>) =>
    onChange(members.map((m, i) => (i === index ? { ...m, ...partial } : m)))
  const remove = (index: number) => onChange(members.filter((_, i) => i !== index))
  const add = () => onChange([...members, { fleet_template_id: '', weight: 1 }])
  return (
    <div className="flex flex-col gap-1.5">
      <div className="text-xs text-ink-muted">Fleets in this encounter</div>
      {members.map((m, i) => (
        <div key={i} className="flex flex-col gap-1 rounded-md border border-edge/60 bg-surface-2 p-1.5">
          <RefSelect
            value={m.fleet_template_id}
            options={options}
            disabled={disabled}
            onChange={(id) => patch(i, { fleet_template_id: id })}
          />
          <input className={COMBAT_INPUT} type="number" aria-label="Weight" title="Weight" disabled={disabled}
            value={numValue(m.weight)} onChange={(e) => patch(i, { weight: num(e.target.value) })} />
          {issueFor(issues, i) ? <div className="text-xs text-danger">{issueFor(issues, i)}</div> : null}
          <Button size="sm" variant="ghost" disabled={disabled} onClick={() => remove(i)}>
            Remove
          </Button>
        </div>
      ))}
      <Button size="sm" variant="ghost" disabled={disabled} onClick={add}>
        Add fleet
      </Button>
    </div>
  )
}
