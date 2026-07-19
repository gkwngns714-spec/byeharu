// DEV ZONE EDITOR (owner-only authoring surface) — DARK by default.
//
// The owner draws danger-zone polygons here instead of me auto-generating them. This is NOT a player
// screen: it renders `null` unless game_config.dev_zone_editor_enabled is exactly jsonb `true`
// (fetchDevZoneEditorEnabled, fail-closed), and it is never linked from the shell nav — the owner
// reaches it only by navigating to /dev/zones directly.
//
// It FORKS NOTHING. Map data comes from the same get_world_map RPC the player map uses (fetchWorldMap),
// existing zones from get_danger_zones, and saves/deletes go through the already-deployed pirate-
// intercept slice RPCs (pirateZoneCreate / pirateZoneDelete, 0233) via the shared pirateApi wrappers.
// Those RPCs additionally gate on pirate_intercept_enabled at the SERVER boundary, so a save while
// that slice is still dark returns { ok:false, reason:'pirate_intercept_disabled' } — surfaced here
// honestly so the owner knows to flip that flag too.
//
// Coordinate note: the world domain is [-10000,10000] but seeded locations cluster near the origin, so
// a full-domain projection would render them as a dot. This surface therefore uses a local FIT-TO-
// CONTENT linear transform (bbox of locations + existing zones, framed with padding) — usable for a
// dev tool without reproducing GalaxyMap's camera. Clicks invert through the same transform; the map
// is unbounded, so the owner may draw vertices anywhere, including beyond the current content frame.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { fetchWorldMap } from '../map/mapApi'
import type { MapLocation, WorldMap } from '../map/mapTypes'
import {
  fetchDangerZones,
  pirateZoneCreate,
  pirateZoneDelete,
  type DangerZoneLite,
} from '../map/pirateApi'
import { fetchDevZoneEditorEnabled, fetchPirateInterceptEnabled } from '../../lib/catalog'

const SVG = 1000
const HOSTILE_TYPES = new Set(['pirate_hunt', 'pirate_den'])

type Vertex = [number, number]

function flattenLocations(world: WorldMap): MapLocation[] {
  const out: MapLocation[] = []
  for (const sector of world.sectors ?? [])
    for (const zone of sector.zones ?? []) for (const loc of zone.locations ?? []) out.push(loc)
  return out
}

interface Fit {
  toSvg: (w: { x: number; y: number }) => { x: number; y: number }
  toWorld: (s: { x: number; y: number }) => { x: number; y: number }
  scale: number
}

/** Fit-to-content world↔SVG transform. Frames all supplied world points inside the 1000×1000 viewBox
 *  with padding; y is inverted (world +y up → SVG +y down). Linear and unbounded — clicks outside the
 *  frame still map to valid world coords. */
function makeFit(points: { x: number; y: number }[]): Fit {
  let minX = -300
  let maxX = 300
  let minY = -300
  let maxY = 300
  if (points.length > 0) {
    minX = Infinity
    maxX = -Infinity
    minY = Infinity
    maxY = -Infinity
    for (const p of points) {
      if (p.x < minX) minX = p.x
      if (p.x > maxX) maxX = p.x
      if (p.y < minY) minY = p.y
      if (p.y > maxY) maxY = p.y
    }
  }
  const cx = (minX + maxX) / 2
  const cy = (minY + maxY) / 2
  const span = Math.max(maxX - minX, maxY - minY, 1)
  const scale = (SVG * 0.8) / span
  return {
    scale,
    toSvg: (w) => ({ x: SVG / 2 + (w.x - cx) * scale, y: SVG / 2 - (w.y - cy) * scale }),
    toWorld: (s) => ({ x: (s.x - SVG / 2) / scale + cx, y: cy - (s.y - SVG / 2) / scale }),
  }
}

export function ZoneEditor() {
  const [enabled, setEnabled] = useState<boolean | null>(null)
  const [interceptLit, setInterceptLit] = useState(false)
  const [locations, setLocations] = useState<MapLocation[]>([])
  const [zones, setZones] = useState<DangerZoneLite[]>([])
  const [draft, setDraft] = useState<Vertex[]>([])
  const [name, setName] = useState('')
  const [attachId, setAttachId] = useState('')
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<{ text: string; ok: boolean } | null>(null)
  const svgRef = useRef<SVGSVGElement | null>(null)

  const loadData = useCallback(async () => {
    const [world, dz, lit] = await Promise.all([
      fetchWorldMap(),
      fetchDangerZones(),
      fetchPirateInterceptEnabled(),
    ])
    setLocations(flattenLocations(world))
    setZones(dz)
    setInterceptLit(lit)
  }, [])

  // Gate FIRST: read the dev flag; only if lit do we fetch any map data. Dark → render null.
  useEffect(() => {
    let alive = true
    void (async () => {
      const on = await fetchDevZoneEditorEnabled()
      if (!alive) return
      setEnabled(on)
      if (on) await loadData()
    })()
    return () => {
      alive = false
    }
  }, [loadData])

  const fit = useMemo(() => {
    const pts: { x: number; y: number }[] = locations.map((l) => ({ x: l.x, y: l.y }))
    for (const z of zones) if (z.ring) for (const [x, y] of z.ring) pts.push({ x, y })
    return makeFit(pts)
  }, [locations, zones])

  const hostiles = useMemo(
    () => locations.filter((l) => HOSTILE_TYPES.has(l.location_type) && l.status === 'active'),
    [locations],
  )

  const addVertex = useCallback(
    (evt: React.MouseEvent<SVGSVGElement>) => {
      const svg = svgRef.current
      if (!svg) return
      const ctm = svg.getScreenCTM()
      if (!ctm) return
      const pt = svg.createSVGPoint()
      pt.x = evt.clientX
      pt.y = evt.clientY
      const local = pt.matrixTransform(ctm.inverse())
      const w = fit.toWorld({ x: local.x, y: local.y })
      setDraft((d) => [...d, [Math.round(w.x * 100) / 100, Math.round(w.y * 100) / 100]])
    },
    [fit],
  )

  const save = useCallback(async () => {
    if (busy) return
    const trimmed = name.trim()
    if (trimmed.length < 1) {
      setMsg({ text: 'Give the zone a name first.', ok: false })
      return
    }
    if (draft.length < 3) {
      setMsg({ text: 'A polygon needs at least 3 vertices — click the map to add them.', ok: false })
      return
    }
    setBusy(true)
    const res = await pirateZoneCreate(trimmed, draft, attachId || null)
    setBusy(false)
    if (res.ok) {
      const standalone = (res as { standalone?: boolean }).standalone
      setMsg({
        text: standalone
          ? `Saved "${trimmed}" as a STANDALONE zone (warning-only, no combat).`
          : `Saved "${trimmed}" as a DANGEROUS zone (attached — spawns combat).`,
        ok: true,
      })
      setDraft([])
      setName('')
      setAttachId('')
      await loadData()
    } else {
      const reason = (res as { reason?: string }).reason ?? 'unknown'
      const hint =
        reason === 'pirate_intercept_disabled'
          ? 'Also flip game_config.pirate_intercept_enabled → true so zones can persist.'
          : ''
      setMsg({ text: `Save failed: ${reason}. ${hint}`.trim(), ok: false })
    }
  }, [busy, name, draft, attachId, loadData])

  const remove = useCallback(
    async (zoneId: string) => {
      setBusy(true)
      const res = await pirateZoneDelete(zoneId)
      setBusy(false)
      if (res.ok) {
        setMsg({ text: 'Zone deleted.', ok: true })
        await loadData()
      } else {
        setMsg({ text: `Delete failed: ${(res as { reason?: string }).reason ?? 'unknown'}.`, ok: false })
      }
    },
    [loadData],
  )

  // DARK by default — render nothing while loading the gate or when the flag is off.
  if (enabled !== true) return null

  const vertexR = 7
  const draftSvg = draft.map(([x, y]) => fit.toSvg({ x, y }))

  return (
    <div style={S.page}>
      <div style={S.header}>
        <h1 style={S.h1}>Danger-Zone Editor</h1>
        <span style={S.badge}>dev · owner-only</span>
      </div>
      <p style={S.sub}>
        Click the map to drop polygon vertices, name the zone, choose whether it attaches to a hostile
        site, then Save. Attached → DANGEROUS (spawns combat). Standalone → warning-only.
        {!interceptLit && (
          <span style={S.warn}>
            {' '}
            Note: pirate_intercept_enabled is OFF, so existing zones are hidden and saves will be
            rejected until you flip it.
          </span>
        )}
      </p>

      <div style={S.body}>
        <div style={S.canvasWrap}>
          <svg
            ref={svgRef}
            viewBox={`0 0 ${SVG} ${SVG}`}
            style={S.svg}
            onClick={addVertex}
            role="img"
            aria-label="Zone editor map"
          >
            <rect x={0} y={0} width={SVG} height={SVG} fill="#0a0e17" />

            {/* existing danger zones */}
            {zones.map((z) =>
              z.ring ? (
                <polygon
                  key={z.id}
                  points={z.ring.map(([x, y]) => { const p = fit.toSvg({ x, y }); return `${p.x},${p.y}` }).join(' ')}
                  fill={z.source === 'drawn' ? 'rgba(239,68,68,0.16)' : 'rgba(148,163,184,0.10)'}
                  stroke={z.source === 'drawn' ? 'rgba(239,68,68,0.75)' : 'rgba(148,163,184,0.55)'}
                  strokeWidth={2}
                />
              ) : null,
            )}

            {/* locations + territory rings */}
            {locations.map((l) => {
              const p = fit.toSvg({ x: l.x, y: l.y })
              const hostile = HOSTILE_TYPES.has(l.location_type)
              return (
                <g key={l.id} pointerEvents="none">
                  {l.territory_radius != null && (
                    <circle
                      cx={p.x}
                      cy={p.y}
                      r={l.territory_radius * fit.scale}
                      fill="none"
                      stroke={hostile ? 'rgba(239,68,68,0.30)' : 'rgba(148,163,184,0.20)'}
                      strokeDasharray="4 4"
                      strokeWidth={1}
                    />
                  )}
                  <circle cx={p.x} cy={p.y} r={5} fill={hostile ? '#ef4444' : '#64748b'} />
                  <text x={p.x + 8} y={p.y + 4} fontSize={13} fill="#cbd5e1">
                    {l.name}
                  </text>
                </g>
              )
            })}

            {/* draft polygon */}
            {draftSvg.length >= 3 && (
              <polygon
                points={draftSvg.map((p) => `${p.x},${p.y}`).join(' ')}
                fill="rgba(56,189,248,0.18)"
                stroke="none"
                pointerEvents="none"
              />
            )}
            {draftSvg.length >= 2 && (
              <polyline
                points={draftSvg.map((p) => `${p.x},${p.y}`).join(' ')}
                fill="none"
                stroke="#38bdf8"
                strokeWidth={2}
                pointerEvents="none"
              />
            )}
            {draftSvg.map((p, i) => (
              <circle key={i} cx={p.x} cy={p.y} r={vertexR} fill="#38bdf8" stroke="#0a0e17" strokeWidth={2} pointerEvents="none" />
            ))}
          </svg>
        </div>

        <div style={S.panel}>
          <label style={S.label}>Zone name</label>
          <input
            style={S.input}
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="e.g. Crimson Reach"
            maxLength={60}
          />

          <label style={S.label}>Attach to</label>
          <select style={S.input} value={attachId} onChange={(e) => setAttachId(e.target.value)}>
            <option value="">Standalone — warning only (no combat)</option>
            {hostiles.map((h) => (
              <option key={h.id} value={h.id}>
                {h.name} ({h.location_type}) → DANGEROUS
              </option>
            ))}
          </select>

          <div style={S.stat}>Vertices: {draft.length} {draft.length > 0 && draft.length < 3 ? '(need ≥3)' : ''}</div>

          <div style={S.row}>
            <button style={S.btn} onClick={() => setDraft((d) => d.slice(0, -1))} disabled={draft.length === 0}>
              Undo vertex
            </button>
            <button style={S.btn} onClick={() => setDraft([])} disabled={draft.length === 0}>
              Clear
            </button>
          </div>
          <button style={S.btnPrimary} onClick={save} disabled={busy}>
            {busy ? 'Saving…' : 'Save zone'}
          </button>

          {msg && <div style={{ ...S.msg, color: msg.ok ? '#4ade80' : '#f87171' }}>{msg.text}</div>}

          <div style={S.divider} />
          <div style={S.label}>Existing zones ({zones.length})</div>
          <div style={S.list}>
            {zones.length === 0 && <div style={S.empty}>None visible. (Lit only when pirate_intercept_enabled is true.)</div>}
            {zones.map((z) => (
              <div key={z.id} style={S.listRow}>
                <span style={S.zoneName}>
                  <span style={{ color: z.source === 'drawn' ? '#ef4444' : '#94a3b8' }}>●</span> {z.name}
                  <span style={S.zoneMeta}>
                    {' '}
                    {z.source}
                    {z.location_id ? ' · attached' : ' · standalone'}
                  </span>
                </span>
                {z.source === 'drawn' ? (
                  <button style={S.btnDanger} onClick={() => remove(z.id)} disabled={busy}>
                    Delete
                  </button>
                ) : (
                  <span style={S.seeded}>seeded</span>
                )}
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  )
}

const S: Record<string, React.CSSProperties> = {
  page: { minHeight: '100vh', background: '#060910', color: '#e2e8f0', padding: 20, fontFamily: 'system-ui, sans-serif' },
  header: { display: 'flex', alignItems: 'center', gap: 12 },
  h1: { fontSize: 22, fontWeight: 700, margin: 0 },
  badge: { fontSize: 12, background: '#1e293b', color: '#94a3b8', padding: '2px 8px', borderRadius: 6 },
  sub: { color: '#94a3b8', fontSize: 13, maxWidth: 760, lineHeight: 1.5 },
  warn: { color: '#fbbf24' },
  body: { display: 'flex', gap: 16, alignItems: 'flex-start', flexWrap: 'wrap' },
  canvasWrap: { flex: '1 1 520px', minWidth: 320, maxWidth: 760, aspectRatio: '1 / 1' },
  svg: { width: '100%', height: '100%', borderRadius: 10, border: '1px solid #1e293b', cursor: 'crosshair', touchAction: 'none' },
  panel: { flex: '0 1 320px', minWidth: 280, display: 'flex', flexDirection: 'column', gap: 8 },
  label: { fontSize: 12, color: '#94a3b8', marginTop: 6, fontWeight: 600 },
  input: { background: '#0f172a', color: '#e2e8f0', border: '1px solid #334155', borderRadius: 8, padding: '8px 10px', fontSize: 14 },
  stat: { fontSize: 13, color: '#cbd5e1', marginTop: 4 },
  row: { display: 'flex', gap: 8 },
  btn: { flex: 1, background: '#1e293b', color: '#e2e8f0', border: '1px solid #334155', borderRadius: 8, padding: '8px 10px', fontSize: 13, cursor: 'pointer' },
  btnPrimary: { background: '#0ea5e9', color: '#04121c', border: 'none', borderRadius: 8, padding: '10px 12px', fontSize: 14, fontWeight: 700, cursor: 'pointer' },
  btnDanger: { background: 'transparent', color: '#f87171', border: '1px solid #7f1d1d', borderRadius: 6, padding: '3px 8px', fontSize: 12, cursor: 'pointer' },
  msg: { fontSize: 13, marginTop: 4 },
  divider: { height: 1, background: '#1e293b', margin: '12px 0 4px' },
  list: { display: 'flex', flexDirection: 'column', gap: 4, maxHeight: 260, overflowY: 'auto' },
  listRow: { display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8, padding: '4px 0' },
  zoneName: { fontSize: 13 },
  zoneMeta: { color: '#64748b', fontSize: 11 },
  empty: { color: '#64748b', fontSize: 12 },
  seeded: { color: '#64748b', fontSize: 11 },
}
