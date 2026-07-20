// WORLD EDITOR — EXPLORATION DRAFT PANEL (side rail). The draft form for the ACTIVE exploration
// draft plus the local draft list, mirroring MiningDraftPanel form-for-form. Draft AUTHORING stays
// client-side (the localStorage draft store); the exploration gameplay RPCs are never touched. The
// active draft surfaces its FULL advisory validation report (explorationValidation via the store's
// reportById) as notices — error → danger, warning → warning (the SAME Notice tones the location
// and mining panels use). Values are only ever FLAGGED, never clamped, never thrown.
//
// PUBLISH (0244 + 0247 slices): ONE Publish button for BOTH draft modes, routed by mode through the
// shared command client. A CREATE draft issues the owner-gated exploration_site_create command
// (0244); an EDIT draft issues exploration_site_update (0247) carrying target_id (the forked
// sourceId — the live row's natural-key name), `expected` (the fork-time sourceSnapshot — the
// server's optimistic-concurrency baseline: any live drift is a typed stale_revision, nothing
// overwritten) and the new fields. The server is the ONLY authority (0243 is_owner() guard +
// server-side re-validation); the button's publishable gate is advisory UX, never authorization.
// The requestId is minted ONCE per publish attempt and kept across retries, so a retry REPLAYS
// idempotently instead of double-applying. On success the local draft is discarded (the change is
// live now). Until the migration is deployed the RPC does not exist and the call fails closed as a
// transport error — the capability is dark.
//
// UNPUBLISH/RESTORE (0250 slice): an EDIT draft additionally carries a small Disable/Enable toggle
// that issues the owner-gated exploration_site_set_active command — the canonical SAFE unpublish
// (is_active=false; readers treat the row as nonexistent) and re-publish (is_active=true; the row
// comes back bit-for-bit). NO hard delete exists anywhere. The command carries the SAME
// optimistic-concurrency addressing as an update (target_id + the fork-time sourceSnapshot as
// `expected`), so a drifted live row is a typed stale_revision — never blindly flipped.
//
// The reward-bundle editor authors the CREATE-only local reward_bundle_json (the ONE shared
// pending-bundle shape, lib/rewardBundle.ts). On an EDIT draft the bundle is not authorable: the
// live bundle is never readable client-side (see explorationDraftTypes.ts), so the panel says so
// honestly instead of faking an empty editable bundle.
import { useState, type ReactNode } from 'react'
import { WORLD_MAX, WORLD_MIN } from '../map/openSpaceTransform'
import { Button, Notice } from '../../components/ui'
import type { PendingBundle, PendingBundleItem } from '../../lib/rewardBundle'
import { isDirty } from './explorationDraftModel'
import { useExplorationDrafts } from './useExplorationDrafts'
import type { ExplorationValidationReport } from './explorationValidation'
import type { ExplorationDraft, ExplorationDraftPayload } from './explorationDraftTypes'
import {
  describeWorldEditorError,
  invokeWorldEditorCommand,
  newRequestId,
  type WorldEditorCommandFailure,
} from './commandClient'

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

/** Transient publish state for ONE draft: the requestId is minted ONCE when the attempt starts and
 *  reused on retry (idempotent replay — the server never double-applies a requestId). draftId is
 *  NEVER the requestId: a draft is a local authoring identity, a request is one publish attempt. */
interface PublishAttempt {
  readonly draftId: string
  readonly requestId: string
  readonly phase: 'sending' | 'failed'
  readonly failure: WorldEditorCommandFailure | null
}

/** Transient set-active (unpublish/restore) state for ONE edit draft — the same requestId-once law
 *  as PublishAttempt: a retry of the SAME toggle direction reuses the requestId (idempotent replay);
 *  flipping direction is a NEW command and mints a fresh one. */
interface SetActiveAttempt {
  readonly draftId: string
  readonly requestId: string
  readonly desired: boolean
  readonly phase: 'sending' | 'failed'
  readonly failure: WorldEditorCommandFailure | null
}

/** A publish failure rendered honestly: the shared error copy + every structured server detail. */
function PublishFailureNotices({ failure }: { failure: WorldEditorCommandFailure }) {
  return (
    <div className="flex flex-col gap-1">
      <Notice tone="danger">{describeWorldEditorError(failure.error)}</Notice>
      {(failure.details ?? []).map((d, i) => (
        <Notice key={`${d.code}:${d.field ?? ''}:${i}`} tone="danger">
          {d.message ?? `${d.code}${d.field ? ` (${d.field})` : ''}`}
        </Notice>
      ))}
    </div>
  )
}

/** The active draft's advisory validation report as notices: error → danger, warning → warning.
 *  Pure presentation of explorationValidation output — no rule logic lives in the panel. */
function ValidationNotices({ report }: { report: ExplorationValidationReport }) {
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

export function ExplorationDraftPanel() {
  const {
    drafts,
    activeDraft,
    statusById,
    reportById,
    beginCreateDraft,
    patchDraft,
    discardDraft,
    selectDraft,
  } = useExplorationDrafts()
  const [confirmingDiscardId, setConfirmingDiscardId] = useState<string | null>(null)
  const [publishAttempt, setPublishAttempt] = useState<PublishAttempt | null>(null)
  const [setActiveAttempt, setSetActiveAttempt] = useState<SetActiveAttempt | null>(null)
  // The editor's live read is active-rows-only, so an edit fork starts assumed ACTIVE; a successful
  // set_active flips this LOCAL assumption (presentation only — the server is the authority).
  const [disabledDraftIds, setDisabledDraftIds] = useState<ReadonlySet<string>>(new Set())

  const set = (partial: Partial<ExplorationDraftPayload>) => {
    if (activeDraft) patchDraft(activeDraft.draftId, partial)
  }

  const onDiscard = (draft: ExplorationDraft) => {
    // Discarding a dirty draft loses local work → two-step confirm (no blocking browser dialog).
    if (isDirty(draft) && confirmingDiscardId !== draft.draftId) {
      setConfirmingDiscardId(draft.draftId)
      return
    }
    setConfirmingDiscardId(null)
    if (publishAttempt?.draftId === draft.draftId) setPublishAttempt(null)
    if (setActiveAttempt?.draftId === draft.draftId) setSetActiveAttempt(null)
    discardDraft(draft.draftId)
  }

  // ── unpublish/restore (0250 exploration_site_set_active): toggle the live row's is_active flag —
  // the safe unpublish (false) / re-publish (true); nothing is ever deleted. Same addressing as an
  // edit publish (target_id + fork-time `expected`), so a drifted live row is a typed stale_revision.
  const onSetActive = async (draft: ExplorationDraft) => {
    if (draft.mode.kind !== 'edit') return
    if (setActiveAttempt?.phase === 'sending' || publishAttempt?.phase === 'sending') return
    const desired = disabledDraftIds.has(draft.draftId) // currently disabled → restore, else unpublish
    // Mint the requestId ONCE per attempt; a retry of the SAME direction reuses it (idempotent replay).
    const requestId =
      setActiveAttempt?.draftId === draft.draftId && setActiveAttempt.desired === desired
        ? setActiveAttempt.requestId
        : newRequestId()
    setSetActiveAttempt({ draftId: draft.draftId, requestId, desired, phase: 'sending', failure: null })
    const result = await invokeWorldEditorCommand({
      requestId,
      commandType: 'exploration_site_set_active',
      payload: {
        target_id: draft.mode.sourceId,
        expected: draft.mode.sourceSnapshot,
        is_active: desired,
        source_revision: draft.mode.sourceRevision,
      },
    })
    if (result.ok) {
      setSetActiveAttempt(null)
      setDisabledDraftIds((prev) => {
        const next = new Set(prev)
        if (desired) next.delete(draft.draftId)
        else next.add(draft.draftId)
        return next
      })
      return
    }
    setSetActiveAttempt({ draftId: draft.draftId, requestId, desired, phase: 'failed', failure: result })
  }

  const onPublish = async (draft: ExplorationDraft) => {
    if (publishAttempt?.phase === 'sending') return
    // Mint the requestId ONCE per attempt; a retry of the SAME draft reuses it, so the server
    // replays idempotently instead of creating twice.
    const requestId =
      publishAttempt?.draftId === draft.draftId ? publishAttempt.requestId : newRequestId()
    setPublishAttempt({ draftId: draft.draftId, requestId, phase: 'sending', failure: null })
    // Mode routes the command: create → exploration_site_create (0244); edit →
    // exploration_site_update (0247), addressed by the forked sourceId with the fork-time
    // sourceSnapshot as the server's optimistic-concurrency `expected` baseline.
    const result = await invokeWorldEditorCommand(
      draft.mode.kind === 'edit'
        ? {
            requestId,
            commandType: 'exploration_site_update',
            payload: {
              target_id: draft.mode.sourceId,
              expected: draft.mode.sourceSnapshot,
              fields: draft.payload,
              source_revision: draft.mode.sourceRevision,
            },
          }
        : {
            requestId,
            commandType: 'exploration_site_create',
            payload: { fields: draft.payload, source_revision: null },
          },
    )
    if (result.ok) {
      // The change is live now — the local draft has served its purpose.
      setPublishAttempt(null)
      discardDraft(draft.draftId)
      return
    }
    setPublishAttempt({ draftId: draft.draftId, requestId, phase: 'failed', failure: result })
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
          Exploration site drafts
        </div>
        <Button size="sm" variant="primary" onClick={beginCreateDraft}>
          New draft
        </Button>
      </div>

      <p className="mb-2 text-xs text-ink-faint">
        Drafts are local to this browser until published. Publishing a draft writes the live world
        (owner only — the server decides).
      </p>

      {/* ── draft list ── */}
      {drafts.length === 0 ? (
        <p className="text-sm text-ink-faint">
          No drafts yet — create one, or open a selected exploration site as an edit draft.
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
                  <span className="truncate">{d.payload.name || 'New site'}</span>
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
              placeholder="e.g. Derelict Listening Post"
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
                            placeholder="e.g. scan_data"
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
              Reward bundle: server-owned for live sites (never readable here) — authorable on
              NEW-site drafts only.
            </p>
          )}

          {/* ── publish (create → 0244 exploration_site_create; edit → 0247 exploration_site_update) ── */}
          <div className="flex flex-col gap-1.5 border-t border-edge/50 pt-2">
            {publishAttempt?.draftId === activeDraft.draftId && publishAttempt.failure && (
              <PublishFailureNotices failure={publishAttempt.failure} />
            )}
            <Button
              size="sm"
              variant="primary"
              busy={
                publishAttempt?.draftId === activeDraft.draftId &&
                publishAttempt.phase === 'sending'
              }
              busyLabel="Publishing…"
              disabled={!(report?.publishable ?? false)}
              onClick={() => void onPublish(activeDraft)}
            >
              {publishAttempt?.draftId === activeDraft.draftId &&
              publishAttempt.phase === 'failed'
                ? 'Retry publish'
                : 'Publish'}
            </Button>
            <p className="text-xs text-ink-faint">
              {activeDraft.mode.kind === 'create'
                ? 'Creates this site in the live world. Owner-only — the server checks, this button grants nothing.'
                : 'Updates the live site. Owner-only — the server re-checks the row is unchanged since this draft was forked (a stale draft is rejected, never overwritten).'}
            </p>
          </div>

          {/* ── unpublish/restore (edit drafts only — 0250 exploration_site_set_active) ── */}
          {activeDraft.mode.kind === 'edit' && (
            <div className="flex flex-col gap-1.5 border-t border-edge/50 pt-2">
              {setActiveAttempt?.draftId === activeDraft.draftId && setActiveAttempt.failure && (
                <PublishFailureNotices failure={setActiveAttempt.failure} />
              )}
              <Button
                size="sm"
                variant="ghost"
                busy={
                  setActiveAttempt?.draftId === activeDraft.draftId &&
                  setActiveAttempt.phase === 'sending'
                }
                busyLabel={
                  disabledDraftIds.has(activeDraft.draftId) ? 'Enabling…' : 'Disabling…'
                }
                onClick={() => void onSetActive(activeDraft)}
              >
                {disabledDraftIds.has(activeDraft.draftId)
                  ? 'Enable this site'
                  : 'Disable this site'}
              </Button>
              <p className="text-xs text-ink-faint">
                Disabling hides the live site from the game (safe unpublish — nothing is deleted);
                enabling restores it exactly. Owner-only — the server decides.
              </p>
            </div>
          )}
        </div>
      )}
    </section>
  )
}
