// WORLD EDITOR — V3A PR-2 "Zone Validation" (PURE model; draft + context in → report out). No React,
// no DOM, no network IO, no storage IO, no client-server call of any kind — the miningValidation.ts
// pure-module idiom, unit-tested directly (tests/zoneValidation.spec.ts, tests/zoneDraftGuards.spec.ts).
// Built on the GENERIC draft-validation contract (draftValidation.ts): issue/report shapes, err/warn
// constructors, and the fold aggregator all come from the ONE generic module; the geometry decisions
// all come from the ONE zone geometry authority (zoneGeometryMath.ts — PR-1).
//
// WHAT THIS IS: an ADVISORY, client-side mirror of what a FUTURE zone publish (PR-3) would reject —
// plus editor-level sanity rules for owner-drawn geometry. Publish does not exist in this slice; the
// server stays the only authority. Rules the client cannot decide authoritatively (danger_zones.name
// has NO unique constraint; the zone read is dark behind pirate_intercept_enabled so hidden rows are
// invisible) surface as WARNINGS, never fake errors.
//
// HARD BOUNDARIES:
//   • FLAG ONLY — no rule mutates, clamps, or throws on any payload value (no-hidden-clamping law).
//   • ONE bounds authority (openSpaceTransform.isWithinOpenSpaceBounds), ONE geometry authority
//     (zoneGeometryMath: polygonSelfIntersects / polygonArea / pointInPolygon / pointInCircle) — no
//     second copies.
//   • DETERMINISTIC — same draft + context ⇒ deep-equal report, always.
import { WORLD_MAX, WORLD_MIN, isWithinOpenSpaceBounds } from '../map/openSpaceTransform'
import type { MapLocation } from '../map/mapTypes'
import {
  pointInCircle,
  pointInPolygon,
  polygonArea,
  polygonSelfIntersects,
} from './zoneGeometryMath'
import type {
  LiveDangerZone,
  ZoneDraft,
  ZoneDraftMode,
  ZoneDraftPayload,
  ZoneGeometry,
} from './zoneDraftTypes'
import {
  draftValidationError,
  draftValidationWarning,
  foldDraftValidationReport,
  type DraftValidationContext,
  type DraftValidationIssue,
  type DraftValidationReport,
} from './draftValidation'

// ── report contract (the generic shapes bound to the zone domain) ───────────────────────────────────

export type ZoneValidationCode =
  | 'coord_out_of_bounds'
  | 'radius_not_positive'
  | 'polygon_too_few_vertices'
  | 'polygon_too_many_vertices'
  | 'degenerate_polygon'
  | 'self_intersection'
  | 'name_required'
  | 'duplicate_name'
  | 'affected_locations'
  | 'source_changed'
  | 'source_missing'
  | 'conflicting_draft'

export type ZoneValidationField = keyof ZoneDraftPayload & string

export type ZoneValidationIssue = DraftValidationIssue<ZoneValidationCode, ZoneValidationField>

export type ZoneValidationReport = DraftValidationReport<ZoneValidationIssue>

/** The affected-locations advisory's input: the id/name/world-coord slice of the live location rows
 *  (a Pick over the REAL MapLocation contract — never a redefinition). */
export type ZoneAffectedLocation = Pick<MapLocation, 'id' | 'name' | 'x' | 'y'>

/** Everything a rule may consult beyond the draft itself: the generic env (live zone rows +
 *  sourceStatus + other drafts) EXTENDED with the read snapshot's locations slice for the
 *  affected-locations advisory. The generic store env carries zones only, so the descriptor binding
 *  passes `locations: []`; the shell-side panel re-runs this SAME validator with the real slice. */
export type ZoneValidationContext = DraftValidationContext<ZoneDraftPayload, LiveDangerZone> & {
  readonly locations: readonly ZoneAffectedLocation[]
}

/** Vertex-count ceiling for an owner-drawn ring — an editor sanity bound (authoring-scale rings; the
 *  O(n²) self-intersection scan and the server's materialization both stay trivial under it). */
export const ZONE_POLYGON_MAX_VERTICES = 64

/** Below this shoelace area (world units²) a ring is too thin to be a zone — collinear or
 *  near-collinear vertices enclose nothing. */
export const ZONE_DEGENERATE_AREA_EPS = 1e-6

/** The generic issue constructors pinned to the zone domain's code/field unions. */
const err = (
  code: ZoneValidationCode,
  field: ZoneValidationField | null,
  message: string,
): ZoneValidationIssue => draftValidationError<ZoneValidationCode, ZoneValidationField>(code, field, message)

const warn = (
  code: ZoneValidationCode,
  field: ZoneValidationField | null,
  message: string,
): ZoneValidationIssue => draftValidationWarning<ZoneValidationCode, ZoneValidationField>(code, field, message)

// ── rules (each PURE: (payload/mode, ctx) → issue | null, or a list) ────────────────────────────────

/** `name` is required for a zone (the legacy zone save demanded one; all-whitespace is empty). */
function ruleNameRequired(p: ZoneDraftPayload): ZoneValidationIssue | null {
  if (p.name.trim() !== '') return null
  return err('name_required', 'name', 'Name is required — a zone must be nameable on the map.')
}

/** The whole geometry must sit inside the fixed open-space domain — every polygon vertex through the
 *  ONE shared predicate; a circle's center AND full extent (center ± radius, both axes) within
 *  ±10000. Out-of-domain values are FLAGGED with their exact values intact (never clamped). */
function ruleGeometryBounds(g: ZoneGeometry): ZoneValidationIssue | null {
  if (g.kind === 'polygon') {
    const bad = g.vertices.filter((v) => !isWithinOpenSpaceBounds(v)).length
    if (bad === 0) return null
    return err(
      'coord_out_of_bounds',
      'geometry',
      `${bad} vertex${bad === 1 ? ' is' : 'es are'} outside the world: every vertex must be finite and within ±${WORLD_MAX}.`,
    )
  }
  const { center, radius } = g
  const extentOk =
    isWithinOpenSpaceBounds(center) &&
    Number.isFinite(radius) &&
    center.x - radius >= WORLD_MIN &&
    center.x + radius <= WORLD_MAX &&
    center.y - radius >= WORLD_MIN &&
    center.y + radius <= WORLD_MAX
  if (extentOk) return null
  return err(
    'coord_out_of_bounds',
    'geometry',
    `The circle must fit inside the world: center and center ± radius must be finite and within ±${WORLD_MAX}.`,
  )
}

/** A circle needs a finite, strictly positive world-unit radius (a zero/negative/NaN disc encloses
 *  nothing — or everything dishonestly). */
function ruleRadiusPositive(g: ZoneGeometry): ZoneValidationIssue | null {
  if (g.kind !== 'circle') return null
  if (Number.isFinite(g.radius) && g.radius > 0) return null
  return err('radius_not_positive', 'geometry', 'Circle radius must be a finite number greater than 0.')
}

/** An owner-drawn ring needs 3…64 vertices: fewer encloses nothing; more is beyond authoring scale. */
function rulePolygonVertexCount(g: ZoneGeometry): ZoneValidationIssue | null {
  if (g.kind !== 'polygon') return null
  if (g.vertices.length < 3)
    return err(
      'polygon_too_few_vertices',
      'geometry',
      `A zone polygon needs at least 3 vertices (${g.vertices.length} drawn).`,
    )
  if (g.vertices.length > ZONE_POLYGON_MAX_VERTICES)
    return err(
      'polygon_too_many_vertices',
      'geometry',
      `A zone polygon carries at most ${ZONE_POLYGON_MAX_VERTICES} vertices (${g.vertices.length} drawn).`,
    )
  return null
}

/** A ring whose shoelace area is ≈0 is too thin to be a zone (collinear vertices). Decided by the ONE
 *  geometry authority; skipped under 3 vertices (the count rule already fired). */
function ruleDegeneratePolygon(g: ZoneGeometry): ZoneValidationIssue | null {
  if (g.kind !== 'polygon' || g.vertices.length < 3) return null
  if (polygonArea(g.vertices) > ZONE_DEGENERATE_AREA_EPS) return null
  return err('degenerate_polygon', 'geometry', 'The polygon encloses no area — its vertices are collinear.')
}

/** A self-intersecting ring has no well-defined inside — the server-side materialization would make
 *  an invalid boundary. Decided by the ONE geometry authority (proper intersections only; adjacent
 *  edges sharing a vertex are how polygons are built). */
function ruleSelfIntersection(g: ZoneGeometry): ZoneValidationIssue | null {
  if (g.kind !== 'polygon') return null
  if (!polygonSelfIntersects(g.vertices)) return null
  return err('self_intersection', 'geometry', 'The polygon edges cross each other — untangle the ring.')
}

/** Case-insensitive name scan across the live visible zones. WARNING only: danger_zones.name has NO
 *  unique constraint, and the zone read is dark behind pirate_intercept_enabled (hidden rows are
 *  invisible to this scan). An edit draft ignores its own source row (liveId = the zone uuid). */
function ruleDuplicateName(
  p: ZoneDraftPayload,
  mode: ZoneDraftMode,
  ctx: ZoneValidationContext,
): ZoneValidationIssue | null {
  const name = p.name.trim().toLowerCase()
  if (name === '') return null
  const sourceId = mode.kind === 'edit' ? mode.sourceId : null
  const dup = ctx.live.find((z) => z.id !== sourceId && z.name.trim().toLowerCase() === name)
  if (!dup) return null
  return warn(
    'duplicate_name',
    'name',
    `A zone named '${dup.name}' already exists — names are not unique, but twins confuse the map.`,
  )
}

/** ADVISORY containment scan — "who this zone endangers": every live location inside the drawn
 *  geometry (boundary-inclusive, via the ONE containment authority). One aggregated WARNING naming
 *  up to five of them. Skipped for shapes with no interior (the geometry errors already fired). */
function ruleAffectedLocations(
  p: ZoneDraftPayload,
  ctx: ZoneValidationContext,
): ZoneValidationIssue | null {
  const g = p.geometry
  const contains =
    g.kind === 'circle'
      ? (x: number, y: number) => pointInCircle({ x, y }, g.center, g.radius)
      : (x: number, y: number) => pointInPolygon({ x, y }, g.vertices)
  const inside = ctx.locations.filter((l) => contains(l.x, l.y))
  if (inside.length === 0) return null
  const names = inside.slice(0, 5).map((l) => l.name).join(', ')
  const more = inside.length > 5 ? ` (+${inside.length - 5} more)` : ''
  return warn(
    'affected_locations',
    'geometry',
    `${inside.length} location${inside.length === 1 ? '' : 's'} inside this zone: ${names}${more}.`,
  )
}

/** Stale-source surfacing (the store computes sourceStatus via draftSourceStatus): a moved live row
 *  is a review-me WARNING; a vanished live row makes the edit unpublishable (ERROR). */
function ruleSourceFreshness(ctx: ZoneValidationContext): ZoneValidationIssue | null {
  if (ctx.sourceStatus === 'source_changed')
    return warn(
      'source_changed',
      null,
      'The live zone changed since this draft was forked — review before any future publish.',
    )
  if (ctx.sourceStatus === 'source_missing')
    return err('source_missing', null, 'The live zone this draft was forked from is no longer visible.')
  return null
}

/** Two local drafts aiming at the same target: another EDIT of the same live row (edit mode), or
 *  another draft carrying the same name (create mode). WARNING — drafts are local and cheap. */
function ruleConflictingDraft(
  p: ZoneDraftPayload,
  mode: ZoneDraftMode,
  ctx: ZoneValidationContext,
): ZoneValidationIssue | null {
  if (mode.kind === 'edit') {
    const sourceId = mode.sourceId
    const clash = ctx.otherDrafts.find((d) => d.mode.kind === 'edit' && d.mode.sourceId === sourceId)
    if (!clash) return null
    return warn(
      'conflicting_draft',
      null,
      'Another local draft also edits this live zone — only one can win a future publish.',
    )
  }
  const name = p.name.trim().toLowerCase()
  if (name === '') return null
  const clash = ctx.otherDrafts.find((d) => d.payload.name.trim().toLowerCase() === name)
  if (!clash) return null
  return warn(
    'conflicting_draft',
    'name',
    `Another local draft is also named '${clash.payload.name.trim()}'.`,
  )
}

// ── aggregator ──────────────────────────────────────────────────────────────────────────────────────

/** Run every rule in canonical order and fold the issues into ONE report via the generic aggregator.
 *  publishable is true iff no error-severity issue exists — warnings advise, they never block (and
 *  publish itself does not exist in this slice; the flag is advisory UX for PR-3). Pure and
 *  deterministic. */
export function validateZoneDraft(draft: ZoneDraft, ctx: ZoneValidationContext): ZoneValidationReport {
  const p = draft.payload
  return foldDraftValidationReport<ZoneValidationIssue>([
    ruleNameRequired(p),
    ruleGeometryBounds(p.geometry),
    ruleRadiusPositive(p.geometry),
    rulePolygonVertexCount(p.geometry),
    ruleDegeneratePolygon(p.geometry),
    ruleSelfIntersection(p.geometry),
    ruleDuplicateName(p, draft.mode, ctx),
    ruleAffectedLocations(p, ctx),
    ruleSourceFreshness(ctx),
    ruleConflictingDraft(p, draft.mode, ctx),
  ])
}
