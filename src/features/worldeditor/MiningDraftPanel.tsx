// WORLD EDITOR — V2A PR-2 MINING DRAFT PANEL (side rail). The draft form for the ACTIVE mining
// draft plus the local draft list, mirroring LocationDraftPanel form-for-form. CLIENT-SIDE ONLY:
// every edit goes through the mining draft store (localStorage) — there is NO save-to-server, NO
// publish button here; publish/enable/disable/archive remain EXPLICITLY DISABLED in the shell's
// deferred-operations block, and the mining gameplay RPCs are never touched. The active draft
// surfaces its FULL advisory validation report (miningValidation via the store's reportById) as
// notices — error → danger, warning → warning (the SAME Notice tones the location panel uses).
// Values are only ever FLAGGED, never clamped, never thrown.
//
// The reward-bundle editor authors the CREATE-only local reward_bundle_json (the ONE shared
// pending-bundle shape, lib/rewardBundle.ts). On an EDIT draft the bundle is not authorable: the
// live bundle is never readable client-side (see miningDraftTypes.ts), so the panel says so
// honestly instead of faking an empty editable bundle.
import { useState, type ReactNode } from 'react'
import { WORLD_MAX, WORLD_MIN } from '../map/openSpaceTransform'
import { Button, Notice } from '../../components/ui'
import type { PendingBundle, PendingBundleItem } from '../../lib/rewardBundle'
import { isDirty } from './miningDraftModel'
import { useMiningDrafts } from './useMiningDrafts'
import type { MiningValidationReport } from './miningValidation'
import type { MiningDraft, MiningDraftPayload } from './miningDraftTypes'

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
 *  Pure presentation of miningValidation output — no rule logic lives in the panel. */
function ValidationNotices({ report }: { report: MiningValidationReport }) {
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

export function MiningDraftPanel() {
  const {
    drafts,
    activeDraft,
    statusById,
    reportById,
    beginCreateDraft,
    patchDraft,
    discardDraft,
    selectDraft,
  } = useMiningDrafts()
  const [confirmingDiscardId, setConfirmingDiscardId] = useState<string | null>(null)

  const set = (partial: Partial<MiningDraftPayload>) => {
    if (activeDraft) patchDraft(activeDraft.draftId, partial)
  }

  const onDiscard = (draft: MiningDraft) => {
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

  // ── reward-bundle editing (immutable payload patches through the store, like every other field) ──
  const bundle = p?.reward_bundle_json ?? null
  const setBundle = (b: PendingBundle | null) => set({ reward_bundle_json: b })
  const setItem = (index: number, partial: Partial<PendingBundleItem>) => {
    if (!bundle) return
    setBundle({
      ...bundle,
      items: (bundle.items ?? []).map((it, i) => (i === index ? { ...it, ...partial } : it)),
    })
  }
  const removeItem = (index: number) => {
    if (!bundle) return
    setBundle({ ...bundle, items: (bundle.items ?? []).filter((_, i) => i !== index) })
  }
  const addItem = () => {
    if (!bundle) return
    setBundle({ ...bundle, items: [...(bundle.items ?? []), { item_id: '', quantity: 1 }] })
  }

  return (
    <section className="rounded-card border border-edge bg-surface p-3">
      <div className="mb-2 flex items-center justify-between">
        <div className="text-xs font-semibold uppercase tracking-wide text-ink-muted">
          Mining field drafts
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
          No drafts yet — create one, or open a selected mining field as an edit draft.
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
                  <span className="truncate">{d.payload.name || 'New field'}</span>
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
              placeholder="e.g. Ferrite Shoal"
              onChange={(e) => set({ name: e.target.value })}
            />
          </Field>

          <div className="grid grid-cols-2 gap-2">
            <Field label={`Space X (${WORLD_MIN}…${WORLD_MAX})`}>
              <input
                className={INPUT}
                type="number"
                value={Number.isFinite(p.space_x) ? p.space_x : ''}
                onChange={(e) => set({ space_x: num(e.target.value) })}
              />
            </Field>
            <Field label={`Space Y (${WORLD_MIN}…${WORLD_MAX})`}>
              <input
                className={INPUT}
                type="number"
                value={Number.isFinite(p.space_y) ? p.space_y : ''}
                onChange={(e) => set({ space_y: num(e.target.value) })}
              />
            </Field>
          </div>

          {/* ── reward bundle (CREATE-only local field) ── */}
          {activeDraft.mode.kind === 'create' ? (
            <div className="flex flex-col gap-1.5">
              <div className={FIELD_LABEL}>Reward bundle (local, create-only)</div>
              {bundle === null ? (
                <Button size="sm" variant="ghost" onClick={() => setBundle({ items: [{ item_id: '', quantity: 1 }] })}>
                  Add reward bundle
                </Button>
              ) : (
                <>
                  <Field label="Metal (blank = none)">
                    <input
                      className={INPUT}
                      type="number"
                      min={0}
                      value={bundle.metal ?? ''}
                      onChange={(e) =>
                        setBundle({
                          ...bundle,
                          metal: e.target.value.trim() === '' ? undefined : Number(e.target.value),
                        })
                      }
                    />
                  </Field>
                  {(bundle.items ?? []).map((it, i) => (
                    <div key={i} className="flex items-end gap-1.5">
                      <div className="flex-1">
                        <Field label="Item id">
                          <input
                            className={INPUT}
                            value={it.item_id}
                            placeholder="e.g. ore_iron"
                            onChange={(e) => setItem(i, { item_id: e.target.value })}
                          />
                        </Field>
                      </div>
                      <div className="w-20">
                        <Field label="Qty">
                          <input
                            className={INPUT}
                            type="number"
                            min={1}
                            step={1}
                            value={Number.isFinite(it.quantity) ? it.quantity : ''}
                            onChange={(e) => setItem(i, { quantity: num(e.target.value) })}
                          />
                        </Field>
                      </div>
                      <Button size="sm" variant="ghost" onClick={() => removeItem(i)}>
                        Remove
                      </Button>
                    </div>
                  ))}
                  <div className="flex gap-1.5">
                    <Button size="sm" variant="ghost" onClick={addItem}>
                      Add item
                    </Button>
                    <Button size="sm" variant="ghost" onClick={() => setBundle(null)}>
                      Clear bundle
                    </Button>
                  </div>
                </>
              )}
            </div>
          ) : (
            <p className="text-xs text-ink-faint">
              Reward bundle: server-owned for live fields (never readable here) — authorable on
              NEW-field drafts only.
            </p>
          )}
        </div>
      )}
    </section>
  )
}
