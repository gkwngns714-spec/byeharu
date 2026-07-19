import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type PointerEvent as RPointerEvent,
} from 'react'
import { fetchDevZoneEditorEnabled } from '../../lib/catalog'
import { VIEW, clampK, clampPan, fitCameraToWorldPoints, type Camera } from '../map/galaxyCamera'
import { smoothClosedPathD } from '../map/smoothPolygon'
import { fetchWorldEditorData, type WorldEditorData } from './worldEditorData'
import { WORLD_EDITOR_LAYERS, defaultVisibleLayerIds } from './worldEditorRegistry'
import { representationWorldPoints, resolveToViewBox } from './worldEditorGeometry'
import {
  DEFERRED_OPERATIONS,
  DEFERRED_OPERATION_REASON,
  type InspectorField,
  type LayerId,
  type LayerItem,
  type PointGlyph,
  type WorldPoint,
} from './worldEditorTypes'
import { Button } from '../../components/ui'

// WORLD EDITOR — Foundation V1 shell (READ-ONLY). ONE owner-only surface on the REAL game map: it
// renders on the SHARED map primitives — the fixed `worldToViewBox` projection (via
// worldEditorGeometry) and `galaxyCamera` camera math — NEVER a bespoke fit-to-content transform (the
// ZoneEditor `makeFit` spaghetti this replaces, §WE.11). It toggles the four typed content layers,
// selects any item, and inspects its typed fields. NOTHING here writes: no RPC write, no game_config
// write, no mutation. Authoring controls are rendered EXPLICITLY DISABLED (§WE.2), never faked.
//
// Gate: identical to ZoneEditor — renders null unless game_config.dev_zone_editor_enabled is exactly
// jsonb `true` (fetchDevZoneEditorEnabled, fail-closed). Reached only by navigating to /dev/world.

interface Selection {
  readonly layer: LayerId
  readonly id: string
}

/** A point glyph as SVG, counter-scaled so it holds a constant on-screen size (the LocationMarker
 *  `r / k` idiom). Presentation-only — the parent <g> owns the click. */
function Glyph({ x, y, r, glyph, tone }: { x: number; y: number; r: number; glyph: PointGlyph; tone: string }) {
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
  const [data, setData] = useState<WorldEditorData | null>(null)
  const [visible, setVisible] = useState<Set<LayerId>>(() => defaultVisibleLayerIds())
  const [selected, setSelected] = useState<Selection | null>(null)
  const [view, setView] = useState<Camera>({ k: 1, tx: 0, ty: 0 })

  const svgRef = useRef<SVGSVGElement | null>(null)
  const drag = useRef<{ x: number; y: number; tx: number; ty: number } | null>(null)
  const userMovedRef = useRef(false)
  const fittedRef = useRef(false)

  // Gate FIRST (fail-closed): read the dev flag; only if lit do we fetch any map data.
  useEffect(() => {
    let alive = true
    void (async () => {
      const on = await fetchDevZoneEditorEnabled()
      if (!alive) return
      setEnabled(on)
      if (on) {
        const d = await fetchWorldEditorData()
        if (alive) setData(d)
      }
    })()
    return () => {
      alive = false
    }
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
  // via the SHARED galaxyCamera fit over every item's canonical world points (§WE.11). Frames the whole
  // world; the ZoneEditor `makeFit` is gone.
  useEffect(() => {
    if (!data || fittedRef.current || userMovedRef.current) return
    const pts: WorldPoint[] = []
    for (const list of itemsByLayer.values()) for (const it of list) pts.push(...representationWorldPoints(it.representation))
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

  const resetView = () => {
    userMovedRef.current = false
    const pts: WorldPoint[] = []
    for (const list of itemsByLayer.values()) for (const it of list) pts.push(...representationWorldPoints(it.representation))
    setView(pts.length ? fitCameraToWorldPoints(pts) : { k: 1, tx: 0, ty: 0 })
  }

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

  // DARK by default — render nothing while loading the gate or when the flag is off (fail-closed).
  if (enabled !== true) return null

  const k = view.k

  return (
    <div className="flex min-h-screen flex-col gap-3 bg-app p-4 text-ink">
      <header className="flex flex-wrap items-center gap-3">
        <h1 className="text-xl font-bold">World Editor</h1>
        <span className="rounded-md bg-surface-2 px-2 py-0.5 text-xs text-ink-muted">dev · owner-only</span>
        <span className="rounded-md bg-surface-2 px-2 py-0.5 text-xs text-accent">Foundation V1 · read-only</span>
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

                {/* Authoring is DEFERRED (§WE.2): shown EXPLICITLY DISABLED, never simulated. */}
                <div className="mt-2">
                  <div className="mb-1 text-xs font-semibold uppercase tracking-wide text-ink-faint">Authoring (deferred)</div>
                  <div className="flex flex-wrap gap-1.5">
                    {DEFERRED_OPERATIONS.map((op) => (
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
                  <p className="mt-1.5 text-xs text-ink-faint">{DEFERRED_OPERATION_REASON}</p>
                </div>
              </div>
            )}
          </section>
        </aside>
      </div>
    </div>
  )
}
