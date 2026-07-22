// WORLD EDITOR — ZONE DRAFT PANEL (side rail). The draft form for the ACTIVE zone draft plus the
// local draft list, mirroring MiningDraftPanel form-for-form.
//
// PUBLISH (V3A PR-3, migration 0254): a CREATE draft publishes through the owner-gated zone_create
// command — the 4th/final publish domain (the geometry twin of location_create 0252). The command
// sends fields = {name, zone_kind, attach_location_id, geometry} (the draft payload verbatim: the
// circle {center,radius} or OPEN polygon ring); the SERVER materializes the boundary (ST_Buffer /
// ST_MakePolygon) and PostGIS is the ONE geometry authority — the client's self-intersection scan
// is advisory, the server's ST_IsValid+area gate is a typed validation_failed detail
// {invalid_geometry}; a bad attach target is {invalid_attach} (both render through the shared
// details pipeline). The requestId is minted ONCE per publish attempt and kept across retries, so a
// retry REPLAYS idempotently instead of double-applying. On success the local draft is discarded
// (the zone is live now — visible on the map only while pirate_intercept_enabled is lit, the
// documented read-side dark coupling). An EDIT draft publishes through the owner-gated zone_update
// command (0266) — addressed by the forked sourceId (the live zone's uuid) with the fork-time
// sourceSnapshot as the server's optimistic-concurrency `expected` baseline; only the MUTABLE fields
// (name, attach_location_id, geometry) are sent (zone_kind is fixed 'pirate'). A seeded source<>'drawn'
// zone is rejected server-side (validation_failed {protected_zone}). The 0239-LOCKED legacy zone-write
// RPCs are never referenced or reused (guard-enforced) —
// this panel speaks ONLY the 0243-spine command client, the sanctioned command path
// (tests/locationDraftGuards.spec.ts COMMAND_PATH_FILES; tests/zoneDraftGuards.spec.ts).
//
// The active draft surfaces its FULL advisory validation report (zoneValidation) as notices —
// error → danger, warning → warning (the SAME Notice tones every other panel uses). The report is
// recomputed HERE with the read snapshot's locations slice (the affected-locations advisory needs
// it; the generic store env carries the zone rows only) — same validator, ONE authority, richer
// context. Values are only ever FLAGGED, never clamped, never thrown.
//
// Geometry is authored on the MAP (ZoneGeometryHandles gestures); this panel owns the draw-mode
// buttons (the gesture mode is SHELL state passed down — never store state), the geometry summary,
// and the polygon Undo/Close controls.
import { useMemo, useState, type ReactNode } from 'react'
import { Button, Notice } from '../../components/ui'
import type { MapLocation } from '../map/mapTypes'
import { isDirty } from './zoneDraftModel'
import { useZoneDrafts } from './useZoneDrafts'
import { validateZoneDraft, type ZoneValidationReport } from './zoneValidation'
import type { LiveDangerZone, ZoneDraft, ZoneDraftPayload } from './zoneDraftTypes'
import type { ZoneGestureMode } from './ZoneGeometryHandles'
import {
  describeWorldEditorError,
  invokeWorldEditorCommand,
  newRequestId,
  type WorldEditorCommandFailure,
} from './commandClient'

const INPUT = 'w-full rounded-lg border border-edge bg-surface-2 px-2 py-1 text-sm text-ink'
const FIELD_LABEL = 'text-xs text-ink-muted'

/** The attachable location types — a zone attached to a hostile site is DANGEROUS (spawns combat),
 *  standalone is warning-only (the ZoneEditor's exact vocabulary, carried over). */
const ZONE_ATTACH_HOSTILE_TYPES = new Set(['pirate_hunt', 'pirate_den'])

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className="flex flex-col gap-0.5">
      <span className={FIELD_LABEL}>{label}</span>
      {children}
    </label>
  )
}

/** Transient publish state for ONE draft: the requestId is minted ONCE when the attempt starts and
 *  reused on retry (idempotent replay — the server never double-applies a requestId). draftId is
 *  NEVER the requestId: a draft is a local authoring identity, a request is one publish attempt. */
interface PublishAttempt {
  readonly draftId: string
  readonly requestId: string
  readonly phase: 'sending' | 'failed'
  readonly failure: WorldEditorCommandFailure | null
}

/** A publish failure rendered honestly: the shared error copy + every structured server detail
 *  (the zone-specific invalid_geometry / invalid_attach codes arrive as validation_failed details
 *  and render through this same pipeline — no special casing). */
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
 *  Pure presentation of zoneValidation output — no rule logic lives in the panel. */
function ValidationNotices({ report }: { report: ZoneValidationReport }) {
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

/** One-line human summary of the draft's seed geometry. */
function geometrySummary(g: ZoneDraftPayload['geometry']): string {
  if (g.kind === 'circle')
    return `Circle · center (${g.center.x}, ${g.center.y}) · radius ${g.radius}`
  return `Polygon · ${g.vertices.length} ${g.vertices.length === 1 ? 'vertex' : 'vertices'}`
}

export function ZoneDraftPanel({
  locations,
  zones,
  gestureMode,
  onGestureModeChange,
}: {
  /** The read snapshot's locations slice — the attach select + affected-locations advisory input. */
  locations: readonly MapLocation[]
  /** The read snapshot's zones slice — the validator's live rows ([] while intercept is dark). */
  zones: readonly LiveDangerZone[]
  /** SHELL-owned gesture mode (never store state) — this panel's draw buttons set it. */
  gestureMode: ZoneGestureMode
  onGestureModeChange: (mode: ZoneGestureMode) => void
}) {
  const {
    drafts,
    activeDraft,
    statusById,
    beginCreateDraft,
    patchDraft,
    discardDraft,
    selectDraft,
  } = useZoneDrafts()
  const [confirmingDiscardId, setConfirmingDiscardId] = useState<string | null>(null)
  const [publishAttempt, setPublishAttempt] = useState<PublishAttempt | null>(null)

  const set = (partial: Partial<ZoneDraftPayload>) => {
    if (activeDraft) patchDraft(activeDraft.draftId, partial)
  }

  const onSelect = (draft: ZoneDraft, active: boolean) => {
    onGestureModeChange('idle') // gesture mode never outlives its draft context
    selectDraft(active ? null : draft.draftId)
  }

  const onDiscard = (draft: ZoneDraft) => {
    // Discarding a dirty draft loses local work → two-step confirm (no blocking browser dialog).
    if (isDirty(draft) && confirmingDiscardId !== draft.draftId) {
      setConfirmingDiscardId(draft.draftId)
      return
    }
    setConfirmingDiscardId(null)
    if (publishAttempt?.draftId === draft.draftId) setPublishAttempt(null)
    onGestureModeChange('idle')
    discardDraft(draft.draftId)
  }

  // PUBLISH — create → 0254 zone_create; edit → 0266 zone_update. fields are the draft payload's
  // MUTABLE slice; the server materializes the geometry (ST_Buffer / ST_MakePolygon) and re-validates
  // everything (the button's publishable gate is advisory UX, never authorization).
  const onPublish = async (draft: ZoneDraft) => {
    if (publishAttempt?.phase === 'sending') return
    // Mint the requestId ONCE per attempt; a retry of the SAME draft reuses it, so the server
    // replays idempotently instead of double-applying.
    const requestId =
      publishAttempt?.draftId === draft.draftId ? publishAttempt.requestId : newRequestId()
    setPublishAttempt({ draftId: draft.draftId, requestId, phase: 'sending', failure: null })
    // create → zone_create (0254): the draft payload VERBATIM ({name, zone_kind, attach_location_id,
    //   geometry}); no target/expected (nothing live to drift from).
    // edit → zone_update (0266): addressed by the forked sourceId (the live zone's uuid) with the
    //   fork-time sourceSnapshot as the server's optimistic-concurrency `expected` baseline. Only the
    //   MUTABLE fields go over the wire — zone_kind is fixed 'pirate' and is never edited.
    const result =
      draft.mode.kind === 'edit'
        ? await invokeWorldEditorCommand({
            requestId,
            commandType: 'zone_update',
            payload: {
              target_id: draft.mode.sourceId,
              expected: draft.mode.sourceSnapshot,
              fields: {
                name: draft.payload.name,
                attach_location_id: draft.payload.attach_location_id,
                geometry: draft.payload.geometry,
              },
              source_revision: draft.mode.sourceRevision,
            },
          })
        : await invokeWorldEditorCommand({
            requestId,
            commandType: 'zone_create',
            payload: {
              fields: {
                name: draft.payload.name,
                zone_kind: draft.payload.zone_kind,
                attach_location_id: draft.payload.attach_location_id,
                geometry: draft.payload.geometry,
              },
            },
          })
    if (result.ok) {
      // The zone change is live now — the local draft has served its purpose.
      setPublishAttempt(null)
      onGestureModeChange('idle')
      discardDraft(draft.draftId)
      return
    }
    setPublishAttempt({ draftId: draft.draftId, requestId, phase: 'failed', failure: result })
  }

  // The FULL advisory report for the active draft, recomputed with the locations slice (the store's
  // reportById lacks the affected-locations advisory — its env carries zone rows only). Same pure
  // validator, richer context; pure + derived, never stored.
  const report = useMemo(() => {
    if (!activeDraft) return null
    return validateZoneDraft(activeDraft, {
      live: zones,
      sourceStatus: statusById.get(activeDraft.draftId) ?? 'current',
      otherDrafts: drafts.filter((d) => d.draftId !== activeDraft.draftId),
      locations,
    })
  }, [activeDraft, zones, statusById, drafts, locations])

  const attachables = useMemo(
    () =>
      locations.filter(
        (l) => ZONE_ATTACH_HOSTILE_TYPES.has(l.location_type) && l.status === 'active',
      ),
    [locations],
  )

  const p = activeDraft?.payload
  const polygonDraw = gestureMode === 'drawPolygon'
  const polygonVertexCount = p?.geometry.kind === 'polygon' ? p.geometry.vertices.length : 0

  const undoVertex = () => {
    if (!activeDraft || activeDraft.payload.geometry.kind !== 'polygon') return
    const vertices = activeDraft.payload.geometry.vertices
    if (vertices.length === 0) return
    set({ geometry: { kind: 'polygon', vertices: vertices.slice(0, -1) } })
  }

  return (
    <section className="rounded-card border border-edge bg-surface p-3">
      <div className="mb-2 flex items-center justify-between">
        <div className="text-xs font-semibold uppercase tracking-wide text-ink-muted">
          Zone drafts
        </div>
        <Button size="sm" variant="primary" onClick={beginCreateDraft}>
          New draft
        </Button>
      </div>

      <p className="mb-2 text-xs text-ink-faint">
        Drafts are local to this browser until published. Publishing a NEW zone (or an EDIT of a live
        one) writes the live world — owner only, the server decides. Seeded zones cannot be edited.
      </p>
      <p className="mb-2 text-xs text-ink-faint">
        Note: live zones are visible (and forkable) only while pirate_intercept_enabled is lit — the
        zone read is dark-coupled to that flag.
      </p>

      {/* ── draft list ── */}
      {drafts.length === 0 ? (
        <p className="text-sm text-ink-faint">
          No drafts yet — create one, or open a selected zone as an edit draft.
        </p>
      ) : (
        <div className="mb-2 flex flex-col gap-1">
          {drafts.map((d) => {
            const active = activeDraft?.draftId === d.draftId
            const st = statusById.get(d.draftId) ?? 'current'
            return (
              <div key={d.draftId} className="flex items-center gap-1.5">
                <button
                  onClick={() => onSelect(d, active)}
                  className={`flex flex-1 items-center justify-between rounded-md border px-2 py-1.5 text-sm ${
                    active ? 'border-accent/60 bg-accent-soft text-ink' : 'border-edge bg-surface-2 text-ink-muted'
                  }`}
                  aria-pressed={active}
                >
                  <span className="truncate">{d.payload.name || 'New zone'}</span>
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
              placeholder="e.g. Crimson Reach"
              onChange={(e) => set({ name: e.target.value })}
            />
          </Field>

          <Field label="Zone kind">
            <input className={INPUT} value="pirate" disabled readOnly />
          </Field>

          <Field label="Attach to">
            <select
              className={INPUT}
              value={p.attach_location_id ?? ''}
              onChange={(e) => set({ attach_location_id: e.target.value || null })}
            >
              <option value="">Standalone — warning only (no combat)</option>
              {attachables.map((l) => (
                <option key={l.id} value={l.id}>
                  {l.name} ({l.location_type}) → DANGEROUS
                </option>
              ))}
            </select>
          </Field>

          {/* ── geometry: summary + draw-mode buttons (gestures live on the map) ── */}
          <div className="flex flex-col gap-1.5">
            <div className={FIELD_LABEL}>Geometry</div>
            <div className="text-sm text-ink">{geometrySummary(p.geometry)}</div>
            <div className="grid grid-cols-2 gap-1.5">
              <Button
                size="sm"
                variant={gestureMode === 'drawCircle' ? 'primary' : 'ghost'}
                onClick={() => onGestureModeChange(gestureMode === 'drawCircle' ? 'idle' : 'drawCircle')}
              >
                Draw circle
              </Button>
              <Button
                size="sm"
                variant={polygonDraw ? 'primary' : 'ghost'}
                onClick={() => {
                  if (polygonDraw) {
                    onGestureModeChange('idle')
                    return
                  }
                  // starting a polygon draw replaces a circle seed with a blank open ring
                  if (p.geometry.kind !== 'polygon')
                    set({ geometry: { kind: 'polygon', vertices: [] } })
                  onGestureModeChange('drawPolygon')
                }}
              >
                Draw polygon
              </Button>
              <Button
                size="sm"
                variant={gestureMode === 'editVertices' ? 'primary' : 'ghost'}
                onClick={() =>
                  onGestureModeChange(gestureMode === 'editVertices' ? 'idle' : 'editVertices')
                }
              >
                Edit shape
              </Button>
              <Button size="sm" variant="ghost" onClick={() => onGestureModeChange('idle')}>
                Done
              </Button>
            </div>
            {polygonDraw && (
              <div className="flex gap-1.5">
                <Button size="sm" variant="ghost" disabled={polygonVertexCount === 0} onClick={undoVertex}>
                  Undo vertex
                </Button>
                <Button
                  size="sm"
                  variant="ghost"
                  disabled={polygonVertexCount < 3}
                  onClick={() => onGestureModeChange('editVertices')}
                >
                  Close ring
                </Button>
              </div>
            )}
            <p className="text-xs text-ink-faint">
              {gestureMode === 'drawCircle'
                ? 'Click the map to set the center, drag to size the radius.'
                : polygonDraw
                  ? 'Click the map to add vertices; click the first vertex (or Close ring) to finish.'
                  : gestureMode === 'editVertices'
                    ? 'Drag grips to move; click an edge midpoint to insert; double-click a vertex to delete (min 3).'
                    : 'Pick a draw mode to author this zone on the map.'}
            </p>
          </div>

          {/* ── publish (create → 0254 zone_create; edit → 0266 zone_update) ── */}
          {activeDraft.mode.kind === 'edit' ? (
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
                  ? 'Retry publish (Edit)'
                  : 'Publish (Edit)'}
              </Button>
              <p className="text-xs text-ink-faint">
                Updates the live zone shape, name and attachment. Owner-only — the server re-checks
                the zone is unchanged since this draft was forked (a stale draft is rejected, never
                overwritten) and re-materializes the geometry (a tangled ring is rejected, never
                repaired). Seeded zones cannot be edited.
              </p>
            </div>
          ) : (
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
                  ? 'Retry publish (Create)'
                  : 'Publish (Create)'}
              </Button>
              <p className="text-xs text-ink-faint">
                Creates a LIVE danger zone from this geometry. Owner-only — the server materializes
                and re-validates the shape (a tangled ring is rejected, never repaired). The zone
                shows on the map only while the intercept flag is lit.
              </p>
            </div>
          )}
        </div>
      )}
    </section>
  )
}
