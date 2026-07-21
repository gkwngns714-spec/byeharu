import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type PointerEvent as RPointerEvent,
} from 'react'
import { fetchDevZoneEditorEnabled, fetchIsOwner } from '../../lib/catalog'
import { VIEW, clampK, clampPan, fitCameraToWorldPoints, type Camera } from '../map/galaxyCamera'
import { smoothClosedPathD } from '../map/smoothPolygon'
import { fetchWorldEditorData, type WorldEditorData } from './worldEditorData'
import { WORLD_EDITOR_LAYERS, defaultVisibleLayerIds } from './worldEditorRegistry'
import { resolveToViewBox } from './worldEditorGeometry'
import { cameraForDomain, focusPointsForDomain } from './worldEditorFocus'
import type { FocusDomain } from './worldEditorCoordinates'
import {
  DEFERRED_OPERATIONS,
  DEFERRED_OPERATION_REASON,
  type DeferredOperation,
  type InspectorField,
  type LayerId,
  type LayerItem,
  type PointGlyph,
} from './worldEditorTypes'
import { LocationDraftsContext, useLocationDraftsStore } from './useLocationDrafts'
import { LocationDraftPanel } from './LocationDraftPanel'
import { DraftPreview } from './DraftPreview'
import { MiningDraftsContext, useMiningDraftsStore } from './useMiningDrafts'
import { MiningDraftPanel } from './MiningDraftPanel'
import { MINING_DRAFT_DESCRIPTOR } from './miningDraftModel'
import { ExplorationDraftsContext, useExplorationDraftsStore } from './useExplorationDrafts'
import { ExplorationDraftPanel } from './ExplorationDraftPanel'
import { EXPLORATION_DRAFT_DESCRIPTOR } from './explorationDraftModel'
import { ZoneDraftsContext, useZoneDraftsStore } from './useZoneDrafts'
import { ZoneDraftPanel } from './ZoneDraftPanel'
import { ZONE_DRAFT_DESCRIPTOR } from './zoneDraftModel'
import { ZoneGeometryHandles, type ZoneGestureMode } from './ZoneGeometryHandles'
import { DraftPreviewOverlay } from './DraftPreviewOverlay'
import { ZoneInspectorActions } from './ZoneInspectorActions'
import { WorldEditorHistoryPanel, type HistoricalFocus } from './WorldEditorHistoryPanel'
import { CombatContentPanel } from './CombatContentPanel'
import { worldToViewBox } from '../map/openSpaceTransform'
import { Button } from '../../components/ui'

// WORLD EDITOR — Foundation V1 shell + V1B-1 "Location Drafts & Preview". ONE owner-only surface on
// the REAL game map: it renders on the SHARED map primitives — the fixed `worldToViewBox` projection
// (via worldEditorGeometry) and `galaxyCamera` camera math — NEVER a bespoke fit-to-content transform
// (the retired ZoneEditor's spaghetti this replaced, §WE.11). It toggles the four typed content
// layers, selects any item, and inspects its typed fields.
//
// C1 (coordinate contract, worldEditorCoordinates.ts): STORED gameplay coordinates NEVER change —
// how the world reads in the editor is controlled by typed display adapters + the CAMERA only. The
// Focus control below frames ONE domain at a time via worldEditorFocus.cameraForDomain (pure,
// reusing the shared galaxyCamera fit) — a camera derivation, never a data write.
//
// V1B-1: create/edit open a LOCAL LocationDraft (useLocationDrafts store — localStorage only, a
// SEPARATE structure never merged into WorldEditorData) previewed as an overlay ABOVE the read-only
// layers. NOTHING here writes to the live world: no RPC write, no game_config write, no mutation —
// publish/enable/disable/archive remain EXPLICITLY DISABLED (§WE.2), never faked.
//
// V2A-2: a SECOND authoring domain — mining-field drafts — beside the location domain, both bound
// to the SAME generic draft core through their one descriptor each. A domain toggle selects which
// panel + which draft preview overlay is active; the location domain's behavior is unchanged.
// Mining drafts are equally local-only: zero mining_fields writes, zero mining gameplay RPCs.
//
// V2C: a THIRD authoring domain — exploration-site drafts — bound to the same generic core through
// the ONE exploration descriptor, mirroring mining exactly. The locations and mining domains'
// behavior is unchanged. Exploration drafts are equally local-only: zero exploration_sites writes,
// zero exploration gameplay RPCs (command_exploration_scan is a PLAYER command, never an editor
// mutation path).
//
// V3A PR-2: a FOURTH authoring domain — zone drafts (circle/polygon geometry) — bound to the same
// generic core through the ONE zone descriptor. Geometry is authored via map GESTURES
// (ZoneGeometryHandles: draw circle / draw polygon / edit vertices — gesture mode is SHELL state,
// never store state) that write EXCLUSIVELY through store.patchDraft. Zone drafts are equally
// local-only: zero danger_zones writes, zero pirate_zone_* RPCs (locked), NO publish (PR-3). The
// locations/mining/exploration domains' behavior is unchanged.
//
// Gate: identical to ZoneEditor — renders null unless game_config.dev_zone_editor_enabled is exactly
// jsonb `true` (fetchDevZoneEditorEnabled, fail-closed). Reached only by navigating to /dev/world.

interface Selection {
  readonly layer: LayerId
  readonly id: string
}

/** The four live draft-authoring domains (V2A-2 + V2C + V3A-2). The toggle picks which panel/preview
 *  is active — every store stays mounted (drafts persist per-domain either way). */
type AuthoringDomain = 'locations' | 'mining' | 'exploration' | 'zones'

/** Toggle labels for the four authoring domains (ONE authority for the toggle row). */
const AUTHORING_DOMAIN_LABELS: Record<AuthoringDomain, string> = {
  locations: 'Locations',
  mining: 'Mining fields',
  exploration: 'Exploration sites',
  zones: 'Zones',
}

/** C1 Focus control — the camera-only domain framer's button row ('all' keeps today's
 *  content-fit-everything frame; each domain frames its own cluster at its true tier). */
const FOCUS_DOMAINS: readonly FocusDomain[] = ['all', 'locations', 'mining', 'exploration', 'zones']
const FOCUS_DOMAIN_LABELS: Record<FocusDomain, string> = {
  all: 'All',
  locations: 'Locations',
  mining: 'Mining',
  exploration: 'Exploration',
  zones: 'Zones',
}

/** V1B-1: create/edit are LIVE (they open a local draft); the rest of DEFERRED_OPERATIONS stays
 *  rendered disabled-with-reason. The constant itself is untouched (worldEditorTypes is the boundary
 *  authority) — this is a shell-side split, pinned by tests/locationDraftGuards.spec.ts. */
const LIVE_DRAFT_OPERATIONS: readonly DeferredOperation[] = ['create', 'edit']

/** A point glyph as SVG, counter-scaled so it holds a constant on-screen size (the LocationMarker
 *  `r / k` idiom). Presentation-only — the parent <g> owns the click. Exported for DraftPreview so
 *  the draft overlay reuses the exact same glyph renderer (one visual language). */
export function Glyph({ x, y, r, glyph, tone }: { x: number; y: number; r: number; glyph: PointGlyph; tone: string }) {
  const stroke = { stroke: 'var(--color-app)', strokeWidth: 1.5, vectorEffect: 'non-scaling-stroke' as const }
  if (glyph === 'diamond')
    return <polygon points={`${x},${y - r} ${x + r},${y} ${x},${y + r} ${x - r},${y}`} fill={tone} {...stroke} />
  if (glyph === 'triangle')
    return <polygon points={`${x},${y - r} ${x + r * 0.9},${y + r * 0.75} ${x - r * 0.9},${y + r * 0.75}`} fill={tone} {...stroke} />
  if (glyph === 'hex') {
    const pts = [0, 1, 2, 3, 4, 5]
      .map((i) => {
        const a = (Math.PI / 3) * i - Math.PI / 2
        return `${x + r * Math.cos(a)},${y + r * Math.sin(a)}`
      })
      .join(' ')
    return <polygon points={pts} fill={tone} {...stroke} />
  }
  return <circle cx={x} cy={y} r={r} fill={tone} {...stroke} />
}

export function WorldEditor() {
  const [enabled, setEnabled] = useState<boolean | null>(null)
  // OWNER GATE (client exposure control): null=resolving, true=owner, false=not owner / lookup failed
  // (fail-closed). The backend is_owner() boundary still guards every command/read regardless of this.
  const [isOwner, setIsOwner] = useState<boolean | null>(null)
  const [data, setData] = useState<WorldEditorData | null>(null)
  const [visible, setVisible] = useState<Set<LayerId>>(() => defaultVisibleLayerIds())
  const [selected, setSelected] = useState<Selection | null>(null)
  const [view, setView] = useState<Camera>({ k: 1, tx: 0, ty: 0 })
  const [authoringDomain, setAuthoringDomain] = useState<AuthoringDomain>('locations')

  // V1B-1 draft store — a SEPARATE structure (localStorage-backed); live locations are passed ONLY
  // for the mandatory staleness re-validation. Never merged into the read snapshot.
  const draftStore = useLocationDraftsStore(data?.locations ?? null)

  // V2A-2 mining draft store — same law, bound to the mining descriptor; data.miningFields is the
  // live-row slice for staleness re-validation (exactly as data.locations feeds the location store).
  // C1: the snapshot's server-authoritative mining_extract_radius rides into the validation context.
  const miningDraftStore = useMiningDraftsStore(
    data?.miningFields ?? null,
    data?.miningExtractRadius ?? null,
  )

  // V2C exploration draft store — same law, bound to the exploration descriptor;
  // data.explorationSites is the live-row slice for staleness re-validation (typically [] under the
  // server-only RLS — an edit fork then simply reads 'source_missing'-free only while its row stays
  // visible).
  // C1: the server-authoritative exploration_scan_radius rides into the validation context.
  const explorationDraftStore = useExplorationDraftsStore(
    data?.explorationSites ?? null,
    data?.explorationScanRadius ?? null,
  )

  // V3A-2 zone draft store — same law, bound to the zone descriptor; data.zones is the live-row
  // slice for staleness re-validation ([] while pirate_intercept_enabled is dark — the zone read is
  // dark-coupled to that flag).
  const zoneDraftStore = useZoneDraftsStore(data?.zones ?? null)

  // V3A-2 zone GESTURE mode — SHELL state, deliberately NOT in the draft store (the store holds
  // authoring intent; gesture ephemera live and die with the shell). The zone panel's draw buttons
  // set it; ZoneGeometryHandles consumes it.
  const [zoneGestureMode, setZoneGestureMode] = useState<ZoneGestureMode>('idle')

  // V1.5 History — the EPHEMERAL historical map overlay (a past audit record framed on the map). SHELL
  // state only: never persisted to the DB or authoring state, never merged into the live `selected` model.
  const [historicalFocus, setHistoricalFocus] = useState<HistoricalFocus | null>(null)

  const svgRef = useRef<SVGSVGElement | null>(null)
  const drag = useRef<{ x: number; y: number; tx: number; ty: number } | null>(null)
  const userMovedRef = useRef(false)
  const fittedRef = useRef(false)

  // Gate FIRST (fail-closed): resolve BOTH the dev flag (exposure control) AND owner status (the
  // authoritative is_owner() check) before rendering anything; only an owner with the flag lit fetches
  // any map data. A non-owner or any lookup failure fails closed (isOwner=false → no editor, no History).
  useEffect(() => {
    let alive = true
    void (async () => {
      const [on, owner] = await Promise.all([fetchDevZoneEditorEnabled(), fetchIsOwner()])
      if (!alive) return
      setEnabled(on)
      setIsOwner(owner)
      if (on && owner) {
        const d = await fetchWorldEditorData()
        if (alive) setData(d)
      }
    })()
    return () => {
      alive = false
    }
  }, [])

  // Re-fetch the ONE read-only snapshot after an owner command mutates the live world (e.g. a zone
  // unpublish): the server is the authority, so the map only reflects the change after this re-read —
  // never an optimistic client edit. Still read-only (SELECT/read-RPC only, via fetchWorldEditorData).
  const reloadData = useCallback(async () => {
    const d = await fetchWorldEditorData()
    setData(d)
  }, [])

  // Per-layer resolved items (only for visible layers). Each adapter reads a slice of the ONE snapshot.
  const itemsByLayer = useMemo(() => {
    const map = new Map<LayerId, LayerItem[]>()
    if (!data) return map
    for (const { adapter } of WORLD_EDITOR_LAYERS) map.set(adapter.id, adapter.readItems(data))
    return map
  }, [data])

  const visibleItems = useMemo(() => {
    const out: LayerItem[] = []
    for (const { adapter } of WORLD_EDITOR_LAYERS) {
      if (!visible.has(adapter.id)) continue
      out.push(...(itemsByLayer.get(adapter.id) ?? []))
    }
    return out
  }, [itemsByLayer, visible])

  // Content-fit the camera ONCE when data first arrives (unless the user already took camera control) —
  // via the SHARED galaxyCamera fit over every item's canonical world points (§WE.11), collected
  // through the ONE C1 framing helper (worldEditorFocus, domain 'all'). The retired ZoneEditor's
  // bespoke fit is gone. Auto-fit-once semantics are unchanged: 'all' is and stays the default frame.
  useEffect(() => {
    if (!data || fittedRef.current || userMovedRef.current) return
    const pts = focusPointsForDomain(itemsByLayer, 'all')
    if (pts.length === 0) return
    fittedRef.current = true
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setView(fitCameraToWorldPoints(pts))
  }, [data, itemsByLayer])

  const toSvgUnits = (dxPx: number) => {
    const rect = svgRef.current?.getBoundingClientRect()
    return (dxPx * VIEW) / (rect?.width || 1)
  }

  // ── pan / zoom (read-only camera; identical math to GalaxyMap; no data mutation) ──
  const onPointerDown = (e: RPointerEvent) => {
    ;(e.target as Element).setPointerCapture?.(e.pointerId)
    drag.current = { x: e.clientX, y: e.clientY, tx: view.tx, ty: view.ty }
  }
  const onPointerMove = (e: RPointerEvent) => {
    const d = drag.current
    if (!d) return
    const dx = toSvgUnits(e.clientX - d.x)
    const dy = toSvgUnits(e.clientY - d.y)
    if (dx !== 0 || dy !== 0) userMovedRef.current = true
    setView((v) => ({ ...v, ...clampPan(d.tx + dx, d.ty + dy, v.k) }))
  }
  const endDrag = () => {
    drag.current = null
  }

  const zoomByFactor = useCallback((factor: number) => {
    userMovedRef.current = true
    setView((v) => {
      const k = clampK(v.k * factor)
      const ratio = k / v.k
      const c = VIEW / 2
      return { k, ...clampPan(c - (c - v.tx) * ratio, c - (c - v.ty) * ratio, k) }
    })
  }, [])

  useEffect(() => {
    const svg = svgRef.current
    if (!svg) return
    const onWheel = (e: WheelEvent) => {
      e.preventDefault()
      zoomByFactor(e.deltaY < 0 ? 1.15 : 1 / 1.15)
    }
    svg.addEventListener('wheel', onWheel, { passive: false })
    return () => svg.removeEventListener('wheel', onWheel)
  }, [zoomByFactor])

  // Reset stays the ALL-domains content fit (cameraForDomain 'all' — identical camera; empty world
  // yields the identity camera via the fit's own empty rule).
  const resetView = () => {
    userMovedRef.current = false
    setView(cameraForDomain(itemsByLayer, 'all'))
  }

  // C1 Focus — CAMERA-ONLY domain framing: derive the fit for one domain's points and set the view.
  // No stored coordinate is read-modified-written anywhere on this path; 'all' reproduces the reset
  // frame. Marks the camera user-held so the auto-fit-once never fights a chosen focus.
  const focusDomain = (domain: FocusDomain) => {
    userMovedRef.current = true
    setView(cameraForDomain(itemsByLayer, domain))
  }

  // V1.5 — frame a HISTORICAL audit record on the map through the ONE camera authority
  // (fitCameraToWorldPoints). Marks the camera user-held (so the auto-fit-once never overrides it), sets
  // the ephemeral overlay, and PRESERVES the live `selected` authoring model (a historical item is never
  // written into it, and no edit control is opened).
  const focusHistorical = (focus: HistoricalFocus) => {
    if (focus.points.length === 0) return
    userMovedRef.current = true
    setView(fitCameraToWorldPoints(focus.points))
    setHistoricalFocus(focus)
  }
  const clearHistorical = () => setHistoricalFocus(null)

  const toggleLayer = (id: LayerId) =>
    setVisible((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })

  // The inspector fields for the current selection, resolved THROUGH the owning adapter.
  const inspectorFields: InspectorField[] | null = useMemo(() => {
    if (!data || !selected) return null
    const entry = WORLD_EDITOR_LAYERS.find((e) => e.adapter.id === selected.layer)
    return entry ? entry.adapter.inspect(data, selected.id) : null
  }, [data, selected])

  const selectedTitle = selected
    ? WORLD_EDITOR_LAYERS.find((e) => e.adapter.id === selected.layer)?.adapter.title ?? selected.layer
    : null

  // The selected LIVE location row (edit-draft fork source). Drafts fork off locations only in V1B-1.
  const selectedLocation = useMemo(
    () =>
      data && selected?.layer === 'locations'
        ? data.locations.find((l) => l.id === selected.id) ?? null
        : null,
    [data, selected],
  )

  // V2A-2: the selected LIVE mining field (mining edit-draft fork source; name is the natural key).
  const selectedMiningField = useMemo(
    () =>
      data && selected?.layer === 'mining'
        ? data.miningFields.find((f) => f.name === selected.id) ?? null
        : null,
    [data, selected],
  )

  // V2C: the selected LIVE exploration site (exploration edit-draft fork source; name is the
  // natural key — the read contract exposes no client uuid).
  const selectedExplorationSite = useMemo(
    () =>
      data && selected?.layer === 'exploration'
        ? data.explorationSites.find((s) => s.name === selected.id) ?? null
        : null,
    [data, selected],
  )

  // V3A-2: the selected LIVE danger zone (zone edit-draft fork source; danger_zones has a real uuid).
  const selectedZone = useMemo(
    () =>
      data && selected?.layer === 'zones'
        ? data.zones.find((z) => z.id === selected.id) ?? null
        : null,
    [data, selected],
  )

  // DARK by default (fail-closed). Render nothing while the flag is loading or off (exposure gate), and
  // nothing while owner status is still resolving. An authenticated NON-OWNER gets a controlled
  // "Not authorized" surface — the editor and the History panel never render for them. (The backend
  // is_owner() boundary independently rejects any non-owner command/read regardless of this client gate.)
  if (enabled !== true) return null
  if (isOwner === null) return null
  if (isOwner !== true) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-app p-4 text-ink">
        <div
          className="rounded-card border border-edge bg-surface p-4 text-sm text-ink-muted"
          data-testid="worldeditor-not-authorized"
        >
          Not authorized — the World Editor is owner-only.
        </div>
      </div>
    )
  }

  const k = view.k
  // Narrowed const so the zone gesture layer's callbacks close over a non-null draft.
  const zoneActiveDraft = zoneDraftStore.activeDraft

  return (
    <LocationDraftsContext.Provider value={draftStore}>
    <MiningDraftsContext.Provider value={miningDraftStore}>
    <ExplorationDraftsContext.Provider value={explorationDraftStore}>
    <ZoneDraftsContext.Provider value={zoneDraftStore}>
    <div className="flex min-h-screen flex-col gap-3 bg-app p-4 text-ink">
      <header className="flex flex-wrap items-center gap-3">
        <h1 className="text-xl font-bold">World Editor</h1>
        <span className="rounded-md bg-surface-2 px-2 py-0.5 text-xs text-ink-muted">dev · owner-only</span>
        <span className="rounded-md bg-surface-2 px-2 py-0.5 text-xs text-accent">Foundation V1 · read-only live</span>
        <span className="rounded-md bg-surface-2 px-2 py-0.5 text-xs text-accent">V1B-1 · local drafts (no publish)</span>
        <span className="rounded-md bg-surface-2 px-2 py-0.5 text-xs text-accent">V2A-2 · mining drafts (no publish)</span>
        <span className="rounded-md bg-surface-2 px-2 py-0.5 text-xs text-accent">V2C · exploration drafts (no publish)</span>
        <span className="rounded-md bg-surface-2 px-2 py-0.5 text-xs text-accent">V3A-2 · zone drafts (no publish)</span>
      </header>

      <div className="flex flex-1 flex-wrap items-start gap-4">
        {/* ── the ONE real map (shared worldToViewBox + galaxyCamera) ── */}
        <div className="relative aspect-square min-w-[320px] flex-1 basis-[520px] overflow-hidden rounded-card border border-edge bg-app shadow-card">
          <svg
            ref={svgRef}
            viewBox={`0 0 ${VIEW} ${VIEW}`}
            preserveAspectRatio="xMidYMid meet"
            className="h-full w-full cursor-grab touch-none select-none active:cursor-grabbing"
            role="img"
            aria-label="World editor map"
            onPointerDown={onPointerDown}
            onPointerMove={onPointerMove}
            onPointerUp={endDrag}
            onPointerLeave={endDrag}
            onPointerCancel={endDrag}
            onClick={(e) => {
              if (e.target === svgRef.current) setSelected(null)
            }}
          >
            <defs>
              <pattern id="we-grid" width={VIEW / 20} height={VIEW / 20} patternUnits="userSpaceOnUse">
                <path
                  d={`M ${VIEW / 20} 0 L 0 0 0 ${VIEW / 20}`}
                  fill="none"
                  stroke="var(--color-map-grid)"
                  strokeWidth={0.5}
                  opacity={0.5}
                />
              </pattern>
            </defs>
            <rect x={0} y={0} width={VIEW} height={VIEW} fill="var(--color-app)" pointerEvents="none" />
            <rect x={0} y={0} width={VIEW} height={VIEW} fill="url(#we-grid)" pointerEvents="none" />

            <g transform={`translate(${view.tx} ${view.ty}) scale(${k})`}>
              {/* polygons (zones) UNDER points */}
              {visibleItems.map((it) => {
                if (it.representation.kind !== 'polygon') return null
                const resolved = resolveToViewBox(it.representation)
                if (resolved.kind !== 'polygon') return null
                const d = smoothClosedPathD(resolved.ring)
                if (!d) return null
                const isSel = selected?.layer === it.layer && selected.id === it.id
                return (
                  <g key={`${it.layer}:${it.id}`} onClick={(e) => { e.stopPropagation(); setSelected({ layer: it.layer, id: it.id }) }} style={{ cursor: 'pointer' }}>
                    <path d={d} fill={it.tone} opacity={isSel ? 0.22 : 0.1} />
                    <path
                      d={d}
                      fill="none"
                      stroke={it.tone}
                      strokeOpacity={isSel ? 1 : 0.55}
                      strokeWidth={(isSel ? 2.5 : 1.5) / k}
                    />
                  </g>
                )
              })}

              {/* points (locations / mining / exploration) */}
              {visibleItems.map((it) => {
                if (it.representation.kind !== 'point') return null
                const resolved = resolveToViewBox(it.representation)
                if (resolved.kind !== 'point') return null
                const { x, y } = resolved.point
                const isSel = selected?.layer === it.layer && selected.id === it.id
                const r = 8 / k
                return (
                  <g
                    key={`${it.layer}:${it.id}`}
                    onClick={(e) => { e.stopPropagation(); setSelected({ layer: it.layer, id: it.id }) }}
                    style={{ cursor: 'pointer' }}
                  >
                    <circle cx={x} cy={y} r={19 / k} fill="transparent" />
                    {isSel && (
                      <circle cx={x} cy={y} r={r * 2.2} fill="var(--color-map-halo)" stroke="var(--color-accent)" strokeWidth={1.5} vectorEffect="non-scaling-stroke" />
                    )}
                    <Glyph x={x} y={y} r={r} glyph={it.glyph} tone={it.tone} />
                    <text
                      x={x}
                      y={y - r * 1.6 - 3 / k}
                      fontSize={13 / k}
                      textAnchor="middle"
                      fill="var(--color-ink)"
                      stroke="var(--color-map-halo)"
                      strokeWidth={3 / k}
                      paintOrder="stroke"
                      style={{ pointerEvents: 'none', userSelect: 'none' }}
                    >
                      {it.label.length > 18 ? `${it.label.slice(0, 17)}…` : it.label}
                    </text>
                  </g>
                )
              })}

              {/* V1B-1/V2A-2/V2C/V3A-2: the ACTIVE authoring domain's draft preview overlay — ABOVE
                  every read-only layer item. Locations keep their bound DraftPreview unchanged;
                  mining/exploration/zones render the generic overlay through their ONE descriptor
                  binding each; zones ADD the interactive geometry-gesture layer on top. */}
              {authoringDomain === 'locations' ? (
                <DraftPreview k={k} />
              ) : authoringDomain === 'mining' ? (
                miningDraftStore.activeDraft && (
                  <DraftPreviewOverlay
                    activeDraft={miningDraftStore.activeDraft}
                    toLayerItem={MINING_DRAFT_DESCRIPTOR.toLayerItem}
                    withinBounds={MINING_DRAFT_DESCRIPTOR.withinBounds}
                    k={k}
                  />
                )
              ) : authoringDomain === 'exploration' ? (
                explorationDraftStore.activeDraft && (
                  <DraftPreviewOverlay
                    activeDraft={explorationDraftStore.activeDraft}
                    toLayerItem={EXPLORATION_DRAFT_DESCRIPTOR.toLayerItem}
                    withinBounds={EXPLORATION_DRAFT_DESCRIPTOR.withinBounds}
                    k={k}
                  />
                )
              ) : (
                zoneActiveDraft && (
                  <>
                    <DraftPreviewOverlay
                      activeDraft={zoneActiveDraft}
                      toLayerItem={ZONE_DRAFT_DESCRIPTOR.toLayerItem}
                      withinBounds={ZONE_DRAFT_DESCRIPTOR.withinBounds}
                      k={k}
                    />
                    {/* the ONE interactive geometry layer: every gesture converts pointer→world via
                        the shared screenToWorld and writes ONLY store.patchDraft (zero live write) */}
                    <ZoneGeometryHandles
                      draft={zoneActiveDraft}
                      mode={zoneGestureMode}
                      onModeChange={setZoneGestureMode}
                      patchGeometry={(geometry) =>
                        zoneDraftStore.patchDraft(zoneActiveDraft.draftId, { geometry })
                      }
                      view={view}
                      svgRef={svgRef}
                    />
                  </>
                )
              )}
              {/* V1.5 — the EPHEMERAL historical overlay: a distinct dashed outline/marker for the audit
                  record being focused. Non-interactive; visually separate from live layers; never part of
                  the authoring selection. Projected through the ONE shared worldToViewBox transform. */}
              {historicalFocus && historicalFocus.points.length > 0
                ? (() => {
                    const vpts = historicalFocus.points.map((p) => worldToViewBox(p))
                    const stroke = historicalFocus.inactive ? 'var(--color-ink-faint)' : 'var(--color-warning)'
                    return (
                      <g pointerEvents="none" data-testid="history-overlay" aria-label="historical location">
                        {vpts.length >= 3 ? (
                          <path
                            d={vpts.map((v, i) => `${i === 0 ? 'M' : 'L'}${v.x} ${v.y}`).join(' ') + ' Z'}
                            fill="none"
                            stroke={stroke}
                            strokeWidth={2 / k}
                            strokeDasharray={`${6 / k} ${4 / k}`}
                          />
                        ) : (
                          <circle
                            cx={vpts[0].x}
                            cy={vpts[0].y}
                            r={12 / k}
                            fill="none"
                            stroke={stroke}
                            strokeWidth={2 / k}
                            strokeDasharray={`${4 / k} ${3 / k}`}
                          />
                        )}
                      </g>
                    )
                  })()
                : null}
            </g>
          </svg>

          <div className="absolute right-2 top-2 flex flex-col gap-1">
            <Button size="icon" onClick={() => zoomByFactor(1.25)} aria-label="Zoom in">+</Button>
            <Button size="icon" onClick={() => zoomByFactor(1 / 1.25)} aria-label="Zoom out">−</Button>
            <Button size="icon" onClick={resetView} aria-label="Reset view" className="text-xs">⟲</Button>
          </div>
        </div>

        {/* ── side rail: layer toggles + read-only inspector ── */}
        <aside className="flex w-full basis-[320px] flex-col gap-3 md:w-[320px] md:flex-none">
          <section className="rounded-card border border-edge bg-surface p-3">
            <div className="mb-2 text-xs font-semibold uppercase tracking-wide text-ink-muted">Layers</div>
            <div className="flex flex-col gap-1.5">
              {WORLD_EDITOR_LAYERS.map(({ adapter }) => {
                const count = itemsByLayer.get(adapter.id)?.length ?? 0
                const on = visible.has(adapter.id)
                return (
                  <button
                    key={adapter.id}
                    onClick={() => toggleLayer(adapter.id)}
                    className={`flex items-center justify-between rounded-md border px-3 py-2 text-sm ${
                      on ? 'border-accent/60 bg-accent-soft text-ink' : 'border-edge bg-surface-2 text-ink-muted'
                    }`}
                    aria-pressed={on}
                  >
                    <span>{adapter.title}</span>
                    <span className="text-xs text-ink-faint">{on ? count : 'hidden'}</span>
                  </button>
                )
              })}
            </div>
          </section>

          {/* C1 Focus — camera-only domain framing (worldEditorFocus.cameraForDomain over the SAME
              shared galaxyCamera fit). Frames one domain's cluster at its true tier; 'All' is the
              same frame Reset uses. NEVER touches stored coordinates. */}
          <section className="rounded-card border border-edge bg-surface p-3">
            <div className="mb-2 text-xs font-semibold uppercase tracking-wide text-ink-muted">Focus</div>
            <div className="flex flex-wrap gap-1.5">
              {FOCUS_DOMAINS.map((d) => (
                <button
                  key={d}
                  onClick={() => focusDomain(d)}
                  className="rounded-md border border-edge bg-surface-2 px-3 py-1.5 text-sm text-ink-muted hover:border-accent/60 hover:text-ink"
                >
                  {FOCUS_DOMAIN_LABELS[d]}
                </button>
              ))}
            </div>
            <p className="mt-1.5 text-xs text-ink-faint">
              Frames the camera on one domain. Display only — stored world coordinates never change.
            </p>
          </section>

          <section className="rounded-card border border-edge bg-surface p-3">
            <div className="mb-2 text-xs font-semibold uppercase tracking-wide text-ink-muted">Inspector</div>
            {!selected || !inspectorFields ? (
              <p className="text-sm text-ink-faint">Select any item on the map to inspect its typed fields.</p>
            ) : (
              <div className="flex flex-col gap-2">
                <div className="text-xs text-accent">{selectedTitle}</div>
                <dl className="flex flex-col gap-1">
                  {inspectorFields.map((f) => (
                    <div key={f.label} className="flex items-baseline justify-between gap-3 border-b border-edge/50 pb-1 text-sm">
                      <dt className="text-ink-muted">{f.label}</dt>
                      <dd className="text-right text-ink">{f.value}</dd>
                    </div>
                  ))}
                </dl>

                {/* Authoring — V1B-1/V2A-2/V2C: create/edit are LIVE and open a LOCAL draft in the
                    ACTIVE authoring domain (zero live mutation). publish/enable/disable/archive
                    stay EXPLICITLY DISABLED (§WE.2). */}
                <div className="mt-2">
                  <div className="mb-1 text-xs font-semibold uppercase tracking-wide text-ink-faint">Authoring</div>
                  <div className="flex flex-wrap gap-1.5">
                    <Button
                      size="sm"
                      onClick={() =>
                        authoringDomain === 'locations'
                          ? draftStore.beginCreateDraft()
                          : authoringDomain === 'mining'
                            ? miningDraftStore.beginCreateDraft()
                            : authoringDomain === 'exploration'
                              ? explorationDraftStore.beginCreateDraft()
                              : zoneDraftStore.beginCreateDraft()
                      }
                    >
                      Create draft
                    </Button>
                    {authoringDomain === 'locations' ? (
                      <Button
                        size="sm"
                        disabled={!selectedLocation}
                        title={
                          selectedLocation
                            ? 'Fork this location into a local edit draft.'
                            : 'Edit drafts fork off a selected LOCATION in this slice.'
                        }
                        onClick={() => selectedLocation && draftStore.forkEditDraft(selectedLocation)}
                      >
                        Edit as draft
                      </Button>
                    ) : authoringDomain === 'mining' ? (
                      <Button
                        size="sm"
                        disabled={!selectedMiningField}
                        title={
                          selectedMiningField
                            ? 'Fork this mining field into a local edit draft.'
                            : 'Edit drafts fork off a selected MINING FIELD in this domain.'
                        }
                        onClick={() =>
                          selectedMiningField && miningDraftStore.forkEditDraft(selectedMiningField)
                        }
                      >
                        Edit as draft
                      </Button>
                    ) : authoringDomain === 'exploration' ? (
                      <Button
                        size="sm"
                        disabled={!selectedExplorationSite}
                        title={
                          selectedExplorationSite
                            ? 'Fork this exploration site into a local edit draft.'
                            : 'Edit drafts fork off a selected EXPLORATION SITE in this domain.'
                        }
                        onClick={() =>
                          selectedExplorationSite &&
                          explorationDraftStore.forkEditDraft(selectedExplorationSite)
                        }
                      >
                        Edit as draft
                      </Button>
                    ) : (
                      <Button
                        size="sm"
                        disabled={!selectedZone}
                        title={
                          selectedZone
                            ? 'Fork this zone into a local edit draft (its ring materializes to editable vertices).'
                            : 'Edit drafts fork off a selected ZONE in this domain.'
                        }
                        onClick={() => selectedZone && zoneDraftStore.forkEditDraft(selectedZone)}
                      >
                        Edit as draft
                      </Button>
                    )}
                    {DEFERRED_OPERATIONS.filter((op) => !LIVE_DRAFT_OPERATIONS.includes(op)).map((op) => (
                      <button
                        key={op}
                        disabled
                        title={DEFERRED_OPERATION_REASON}
                        className="cursor-not-allowed rounded-md border border-edge bg-surface-2 px-2 py-1 text-xs capitalize text-ink-faint opacity-60"
                      >
                        {op}
                      </button>
                    ))}
                  </div>
                  <p className="mt-1.5 text-xs text-ink-faint">
                    Create/edit open a LOCAL draft (browser-only, never written to the live world).{' '}
                    {DEFERRED_OPERATION_REASON}
                  </p>
                </div>

                {/* V3B: the ONE owner-gated LIVE zone write reachable from the shell — unpublish a
                    selected live danger zone (0255 zone_unpublish). Server is_owner() is the authority;
                    on success the snapshot re-reads and the zone leaves the map. Only shown for a live
                    zone selection; drafts publish through their own panels. */}
                {selectedZone && (
                  <ZoneInspectorActions
                    zone={selectedZone}
                    onUnpublished={() => {
                      setSelected(null)
                      void reloadData()
                    }}
                  />
                )}
              </div>
            )}
          </section>

          {/* V1.5 — read-only History (owner audit ledger, via the world_editor_audit_list RPC only).
              Inherits the /dev/world + RequireAuth + owner + dev_zone_editor_enabled gate (it renders
              inside WorldEditor). Historical map focus reuses the ONE camera authority and never mutates
              the live `selected` authoring model. */}
          <WorldEditorHistoryPanel onFocusHistorical={focusHistorical} onClearHistorical={clearHistorical} />

          {/* E4 — Combat content: ONE foldable rail section (collapsed by default) for owner-only
              authoring of enemies/rewards/fleets/encounters/placements via the existing E0-E2 owner
              RPCs. Frontend-only; reads through the already-built read adapters, writes through the ONE
              command path (useCombatAuthoring). Fail-closed: it never reads or flips any *_enabled flag. */}
          <CombatContentPanel locations={data?.locations ?? []} />

          {/* V2A-2/V2C/V3A-2: the authoring-domain toggle — picks which draft panel + preview is
              active. Every store stays mounted; switching never discards another domain's drafts. */}
          <section className="rounded-card border border-edge bg-surface p-3">
            <div className="mb-2 text-xs font-semibold uppercase tracking-wide text-ink-muted">Authoring domain</div>
            <div className="grid grid-cols-2 gap-1.5">
              {(['locations', 'mining', 'exploration', 'zones'] as const).map((d) => (
                <button
                  key={d}
                  onClick={() => {
                    setAuthoringDomain(d)
                    setZoneGestureMode('idle') // gesture mode never outlives the zone domain view
                  }}
                  className={`rounded-md border px-3 py-2 text-sm ${
                    authoringDomain === d
                      ? 'border-accent/60 bg-accent-soft text-ink'
                      : 'border-edge bg-surface-2 text-ink-muted'
                  }`}
                  aria-pressed={authoringDomain === d}
                >
                  {AUTHORING_DOMAIN_LABELS[d]}
                </button>
              ))}
            </div>
          </section>

          {/* V1B-1/V2A-2/V2C/V3A-2: the ACTIVE domain's local draft list + form (client-side only).
              zoneOptions (0252): the create-location zone picker's source — the zone refs the raw
              get_world_map tree already carries (WorldEditorData.zoneRefs; no extra server read). */}
          {authoringDomain === 'locations' ? (
            <LocationDraftPanel zoneOptions={data?.zoneRefs ?? []} />
          ) : authoringDomain === 'mining' ? (
            <MiningDraftPanel />
          ) : authoringDomain === 'exploration' ? (
            <ExplorationDraftPanel />
          ) : (
            <ZoneDraftPanel
              locations={data?.locations ?? []}
              zones={data?.zones ?? []}
              gestureMode={zoneGestureMode}
              onGestureModeChange={setZoneGestureMode}
            />
          )}
        </aside>
      </div>
    </div>
    </ZoneDraftsContext.Provider>
    </ExplorationDraftsContext.Provider>
    </MiningDraftsContext.Provider>
    </LocationDraftsContext.Provider>
  )
}
