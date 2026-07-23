// WORLD EDITOR V1.5 — pure extraction of the world points to frame for an audit record's HISTORICAL map
// focus. No React/DOM. Operates ONLY on the sanitized snapshot the reader returned. The camera itself is
// the existing authority (galaxyCamera.fitCameraToWorldPoints); this only derives the points to fit, so
// no second camera-control system is introduced.
import type { WorldPoint } from './worldEditorTypes'
import type { AuditSnapshot, WorldEditorAuditEntry } from './worldEditorAuditTypes'

/** Reasonable input bounds so a malformed/oversized geometry string can never cause expensive parsing
 *  in render. A well-formed 130-vertex circle WKT is ~2.8 KB and ~130 points — these caps sit well above. */
const MAX_WKT_LENGTH = 20_000
const MAX_WKT_POINTS = 2_000

/** Parse a WKT POLYGON exterior ring into world points. PURE and fail-safe: returns [] for any malformed,
 *  unsupported, or oversized input — never throws, never does unbounded work. */
function parseWktPolygon(wkt: string): WorldPoint[] {
  if (typeof wkt !== 'string' || wkt.length === 0 || wkt.length > MAX_WKT_LENGTH) return []
  if (!/^\s*polygon\s*\(\(/i.test(wkt)) return [] // only POLYGON is supported here
  const m = /\(\(([^()]*)\)\)/.exec(wkt) // outer ring of POLYGON((x y,x y,...))
  if (!m) return []
  const pts: WorldPoint[] = []
  const pairs = m[1].split(',')
  for (const pair of pairs) {
    if (pts.length >= MAX_WKT_POINTS) break
    const parts = pair.trim().split(/\s+/)
    const x = Number(parts[0])
    const y = Number(parts[1])
    if (Number.isFinite(x) && Number.isFinite(y)) pts.push({ x, y })
  }
  return pts
}

const num = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? v : null)

/** World points from ONE sanitized snapshot: prefer boundary geometry, then legacy x/y, then OSN space_x/y. */
function pointsFromSnapshot(snap: AuditSnapshot | null): WorldPoint[] {
  if (!snap) return []
  if (typeof snap.boundary_wkt === 'string') return parseWktPolygon(snap.boundary_wkt)
  const x = num(snap.x)
  const y = num(snap.y)
  if (x !== null && y !== null) return [{ x, y }]
  const sx = num(snap.space_x)
  const sy = num(snap.space_y)
  if (sx !== null && sy !== null) return [{ x: sx, y: sy }]
  return []
}

/** The world points to frame for a record's historical focus — prefers `after`, falls back to `before`.
 *  Returns [] when the sanitized record carries no usable coordinates/geometry (focus is then disabled). */
export function auditRecordWorldPoints(entry: WorldEditorAuditEntry): WorldPoint[] {
  const after = pointsFromSnapshot(entry.after)
  return after.length > 0 ? after : pointsFromSnapshot(entry.before)
}

/** Whether an audit record has usable geometry/coordinates for a historical map focus. */
export function auditRecordHasFocus(entry: WorldEditorAuditEntry): boolean {
  return auditRecordWorldPoints(entry).length > 0
}
