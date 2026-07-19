// WORLD EDITOR — V1B-1/V1B-2 LOCATION DRAFT PANEL (side rail). The draft form for the ACTIVE draft
// plus the local draft list. CLIENT-SIDE ONLY: every edit goes through the draft store (localStorage)
// — there is NO save-to-server, NO publish button here; publish/enable/disable/archive remain
// EXPLICITLY DISABLED in the shell's deferred-operations block. V1B-2: the active draft surfaces its
// FULL advisory validation report (locationValidation via the store's reportById) as notices —
// error → danger, warning → warning. Values are only ever FLAGGED, never clamped, never thrown.
// Enum option lists come from locationEnums — the ONE runtime CHECK-enum authority (no local copies).
import { useState, type ReactNode } from 'react'
import type { ActivityType, LocationType } from '../map/mapTypes'
import { WORLD_MAX, WORLD_MIN } from '../map/openSpaceTransform'
import { Button, Notice } from '../../components/ui'
import { isDirty } from './locationDraftModel'
import { ACTIVITY_TYPES, LOCATION_TYPES } from './locationEnums'
import { useLocationDrafts } from './useLocationDrafts'
import type { ValidationReport } from './locationValidation'
import type { LocationDraft, LocationDraftPayload } from './locationDraftTypes'

const INPUT = 'w-full rounded-lg border border-edge bg-surface-2 px-2 py-1 text-sm text-ink'
const FIELD_LABEL = 'text-xs text-ink-muted'

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className="flex flex-col gap-0.5">
      <span className={FIELD_LABEL}>{label}</span>
      {children}
    </label>
  )
}

const num = (v: string): number => (v.trim() === '' ? Number.NaN : Number(v))

/** The active draft's advisory validation report as notices: error → danger, warning → warning.
 *  Pure presentation of locationValidation output — no rule logic lives in the panel. */
function ValidationNotices({ report }: { report: ValidationReport }) {
  if (report.issues.length === 0) return null
  return (
    <div className="flex flex-col gap-1">
      {report.issues.map((issue, i) => (
        <Notice
          key={`${issue.code}:${issue.field ?? ''}:${i}`}
          tone={issue.severity === 'error' ? 'danger' : 'warning'}
        >
          {issue.message}
        </Notice>
      ))}
    </div>
  )
}

export function LocationDraftPanel() {
  const {
    drafts,
    activeDraft,
    statusById,
    reportById,
    beginCreateDraft,
    patchDraft,
    discardDraft,
    selectDraft,
  } = useLocationDrafts()
  const [confirmingDiscardId, setConfirmingDiscardId] = useState<string | null>(null)

  const set = (partial: Partial<LocationDraftPayload>) => {
    if (activeDraft) patchDraft(activeDraft.draftId, partial)
  }

  const onDiscard = (draft: LocationDraft) => {
    // Discarding a dirty draft loses local work → two-step confirm (no blocking browser dialog).
    if (isDirty(draft) && confirmingDiscardId !== draft.draftId) {
      setConfirmingDiscardId(draft.draftId)
      return
    }
    setConfirmingDiscardId(null)
    discardDraft(draft.draftId)
  }

  const p = activeDraft?.payload
  const report = activeDraft ? reportById.get(activeDraft.draftId) : undefined

  return (
    <section className="rounded-card border border-edge bg-surface p-3">
      <div className="mb-2 flex items-center justify-between">
        <div className="text-xs font-semibold uppercase tracking-wide text-ink-muted">
          Location drafts
        </div>
        <Button size="sm" variant="primary" onClick={beginCreateDraft}>
          New draft
        </Button>
      </div>

      <p className="mb-2 text-xs text-ink-faint">
        Drafts are local to this browser (never written to the live world). Publish is a later slice.
      </p>

      {/* ── draft list ── */}
      {drafts.length === 0 ? (
        <p className="text-sm text-ink-faint">
          No drafts yet — create one, or open a selected location as an edit draft.
        </p>
      ) : (
        <div className="mb-2 flex flex-col gap-1">
          {drafts.map((d) => {
            const active = activeDraft?.draftId === d.draftId
            const st = statusById.get(d.draftId) ?? 'current'
            return (
              <div key={d.draftId} className="flex items-center gap-1.5">
                <button
                  onClick={() => selectDraft(active ? null : d.draftId)}
                  className={`flex flex-1 items-center justify-between rounded-md border px-2 py-1.5 text-sm ${
                    active ? 'border-accent/60 bg-accent-soft text-ink' : 'border-edge bg-surface-2 text-ink-muted'
                  }`}
                  aria-pressed={active}
                >
                  <span className="truncate">{d.payload.name || 'New location'}</span>
                  <span className="ml-2 shrink-0 text-xs text-ink-faint">
                    {d.mode.kind === 'edit' ? 'edit' : 'new'}
                    {st !== 'current' ? ' · stale' : isDirty(d) ? ' · dirty' : ''}
                  </span>
                </button>
                <Button
                  size="sm"
                  variant={confirmingDiscardId === d.draftId ? 'danger' : 'ghost'}
                  onClick={() => onDiscard(d)}
                >
                  {confirmingDiscardId === d.draftId ? 'Confirm?' : 'Discard'}
                </Button>
              </div>
            )
          })}
        </div>
      )}

      {/* ── active draft form ── */}
      {activeDraft && p && (
        <div className="mt-2 flex flex-col gap-2 border-t border-edge/50 pt-2">
          {report && <ValidationNotices report={report} />}

          <Field label="Name">
            <input
              className={INPUT}
              value={p.name}
              maxLength={60}
              placeholder="e.g. Amber Shoal"
              onChange={(e) => set({ name: e.target.value })}
            />
          </Field>

          <div className="grid grid-cols-2 gap-2">
            <Field label="Location type">
              <select
                className={INPUT}
                value={p.location_type}
                onChange={(e) => set({ location_type: e.target.value as LocationType })}
              >
                {LOCATION_TYPES.map((t) => (
                  <option key={t} value={t}>
                    {t}
                  </option>
                ))}
              </select>
            </Field>
            <Field label="Activity">
              <select
                className={INPUT}
                value={p.activity_type}
                onChange={(e) => set({ activity_type: e.target.value as ActivityType })}
              >
                {ACTIVITY_TYPES.map((t) => (
                  <option key={t} value={t}>
                    {t}
                  </option>
                ))}
              </select>
            </Field>
          </div>

          <div className="grid grid-cols-2 gap-2">
            <Field label={`World X (${WORLD_MIN}…${WORLD_MAX})`}>
              <input
                className={INPUT}
                type="number"
                value={Number.isFinite(p.x) ? p.x : ''}
                onChange={(e) => set({ x: num(e.target.value) })}
              />
            </Field>
            <Field label={`World Y (${WORLD_MIN}…${WORLD_MAX})`}>
              <input
                className={INPUT}
                type="number"
                value={Number.isFinite(p.y) ? p.y : ''}
                onChange={(e) => set({ y: num(e.target.value) })}
              />
            </Field>
          </div>

          <div className="grid grid-cols-3 gap-2">
            <Field label="Reward tier">
              <input
                className={INPUT}
                type="number"
                min={0}
                step={1}
                value={Number.isFinite(p.reward_tier) ? p.reward_tier : ''}
                onChange={(e) => set({ reward_tier: num(e.target.value) })}
              />
            </Field>
            <Field label="Difficulty">
              <input
                className={INPUT}
                type="number"
                min={0}
                step={1}
                value={Number.isFinite(p.base_difficulty) ? p.base_difficulty : ''}
                onChange={(e) => set({ base_difficulty: num(e.target.value) })}
              />
            </Field>
            <Field label="Min power">
              <input
                className={INPUT}
                type="number"
                min={0}
                step={1}
                value={Number.isFinite(p.min_power_required) ? p.min_power_required : ''}
                onChange={(e) => set({ min_power_required: num(e.target.value) })}
              />
            </Field>
          </div>

          <div className="grid grid-cols-2 gap-2">
            <Field label="Territory radius (blank = none)">
              <input
                className={INPUT}
                type="number"
                min={0}
                value={p.territory_radius ?? ''}
                onChange={(e) =>
                  set({ territory_radius: e.target.value.trim() === '' ? null : Number(e.target.value) })
                }
              />
            </Field>
            <Field label="Status">
              <input
                className={INPUT}
                value={p.status}
                maxLength={30}
                onChange={(e) => set({ status: e.target.value })}
              />
            </Field>
          </div>

          <label className="flex items-center gap-2 text-sm text-ink">
            <input
              type="checkbox"
              checked={p.is_public}
              onChange={(e) => set({ is_public: e.target.checked })}
            />
            Public location
          </label>
        </div>
      )}
    </section>
  )
}
