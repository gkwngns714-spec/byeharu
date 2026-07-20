// WORLD EDITOR — ZONE DRAFT PANEL (side rail). The draft form for the ACTIVE zone draft plus the
// local draft list, mirroring MiningDraftPanel form-for-form MINUS publish: this slice (V3A PR-2) is
// draft + validation + gestures ONLY — there is NO Publish button, no command client, no RPC of any
// kind (publish is PR-3; the legacy zone-write RPCs are LOCKED and never reused). Guarded by
// tests/zoneDraftGuards.spec.ts: this file imports no zone RPC client and no publish transport.
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
    onGestureModeChange('idle')
    discardDraft(draft.draftId)
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
        Drafts are local to this browser. Publishing zones arrives in a later slice — nothing here
        writes the live world.
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

          <p className="border-t border-edge/50 pt-2 text-xs text-ink-faint">
            Publish is a later slice (PR-3) — this draft stays local until then.
          </p>
        </div>
      )}
    </section>
  )
}
