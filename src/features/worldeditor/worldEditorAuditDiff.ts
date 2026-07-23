// WORLD EDITOR V1.5 — pure semantic before/after diff for an audit record. No React/DOM/supabase —
// unit-testable. Operates ONLY on the sanitized snapshots the reader returned (never reconstructs or
// guesses redacted values). Classifies each field added / removed / changed / unchanged, groups fields
// semantically, and summarizes large geometry (boundary_wkt) in the primary view.
import type { AuditSnapshot } from './worldEditorAuditTypes'

export type AuditDiffClass = 'added' | 'removed' | 'changed' | 'unchanged'
export type AuditDiffGroup = 'identity' | 'lifecycle' | 'display' | 'coordinates' | 'geometry' | 'other'

export interface AuditFieldDiff {
  readonly field: string
  readonly group: AuditDiffGroup
  readonly klass: AuditDiffClass
  /** Human display of the before value (or null when the field was absent in `before`). */
  readonly before: string | null
  /** Human display of the after value (or null when absent in `after`). */
  readonly after: string | null
  /** true when the value is a large geometry summarized rather than shown in full. */
  readonly summarized: boolean
}

export interface AuditDiffGroupBlock {
  readonly group: AuditDiffGroup
  readonly fields: readonly AuditFieldDiff[]
}

export interface AuditDiff {
  readonly groups: readonly AuditDiffGroupBlock[]
  readonly changedCount: number
  /** false for a create record (before === null): the detail view labels it "created". */
  readonly hasBefore: boolean
  /** true when after === null (a shape the RPC does not currently emit, but handled without crashing). */
  readonly afterMissing: boolean
}

const GROUP_ORDER: readonly AuditDiffGroup[] = [
  'identity',
  'lifecycle',
  'display',
  'coordinates',
  'geometry',
  'other',
]

const FIELD_GROUP: Readonly<Record<string, AuditDiffGroup>> = {
  id: 'identity',
  name: 'identity',
  status: 'lifecycle',
  is_active: 'lifecycle',
  zone_kind: 'display',
  source: 'display',
  location_type: 'display',
  activity_type: 'display',
  is_public: 'display',
  x: 'coordinates',
  y: 'coordinates',
  space_x: 'coordinates',
  space_y: 'coordinates',
  location_id: 'coordinates',
  zone_id: 'coordinates',
  territory_radius: 'coordinates',
  boundary_wkt: 'geometry',
}
const groupOf = (field: string): AuditDiffGroup => FIELD_GROUP[field] ?? 'other'

/** Summarize a WKT geometry string as "polygon · N points" instead of the full (~130-vertex) ring. */
function summarizeWkt(wkt: string): string {
  const head = wkt.slice(0, 40).toLowerCase()
  const kind = head.startsWith('polygon') ? 'polygon' : head.startsWith('point') ? 'point' : head.startsWith('linestring') ? 'line' : 'geometry'
  // vertex count ≈ coordinate pairs = commas inside the outer parens + 1
  const inner = wkt.slice(wkt.indexOf('('))
  const points = (inner.match(/,/g)?.length ?? 0) + 1
  return `${kind} · ${points} pts`
}

/** Display a snapshot value as a compact string. Geometry is summarized; objects/arrays are JSON. */
function displayValue(field: string, v: unknown): { text: string; summarized: boolean } {
  if (v === null || v === undefined) return { text: '∅', summarized: false }
  if (field === 'boundary_wkt' && typeof v === 'string') return { text: summarizeWkt(v), summarized: true }
  if (typeof v === 'string' || typeof v === 'number' || typeof v === 'boolean') return { text: String(v), summarized: false }
  const json = JSON.stringify(v)
  return json.length > 80 ? { text: json.slice(0, 77) + '…', summarized: true } : { text: json, summarized: false }
}

const eq = (a: unknown, b: unknown): boolean => JSON.stringify(a) === JSON.stringify(b)

/**
 * Derive the semantic diff between two sanitized snapshots. `before === null` is a valid create record;
 * `after === null` is handled without crashing (all fields render as "removed").
 */
export function deriveAuditDiff(before: AuditSnapshot | null, after: AuditSnapshot | null): AuditDiff {
  const b = before ?? {}
  const a = after ?? {}
  const keys = Array.from(new Set([...Object.keys(b), ...Object.keys(a)])).sort()

  const fields: AuditFieldDiff[] = []
  let changedCount = 0
  for (const field of keys) {
    const inB = Object.prototype.hasOwnProperty.call(b, field)
    const inA = Object.prototype.hasOwnProperty.call(a, field)
    let klass: AuditDiffClass
    if (inB && inA) klass = eq(b[field], a[field]) ? 'unchanged' : 'changed'
    else if (inA) klass = 'added'
    else klass = 'removed'
    if (klass !== 'unchanged') changedCount++
    const bd = inB ? displayValue(field, b[field]) : { text: '', summarized: false }
    const ad = inA ? displayValue(field, a[field]) : { text: '', summarized: false }
    fields.push({
      field,
      group: groupOf(field),
      klass,
      before: inB ? bd.text : null,
      after: inA ? ad.text : null,
      summarized: bd.summarized || ad.summarized,
    })
  }

  const groups: AuditDiffGroupBlock[] = GROUP_ORDER.map((group) => ({
    group,
    fields: fields.filter((f) => f.group === group),
  })).filter((g) => g.fields.length > 0)

  return {
    groups,
    changedCount,
    hasBefore: before !== null,
    afterMissing: after === null,
  }
}
