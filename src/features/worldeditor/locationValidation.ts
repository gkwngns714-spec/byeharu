// WORLD EDITOR — V1B-2 "Location Validation" (PURE model; props in → report out). No React, no DOM,
// no network IO, no storage IO, no client-server call of any kind — the locationDraftModel.ts
// pure-module idiom, unit-tested directly (tests/locationValidation.spec.ts,
// tests/locationValidationGuards.spec.ts).
//
// WHAT THIS IS: an ADVISORY, client-side mirror of the server's `locations` CHECK constraints
// (20260616000002_world_map.sql) plus editor-level sanity rules. It exists so a draft author sees
// exactly what a FUTURE publish would reject — publish itself remains in DEFERRED_OPERATIONS,
// explicitly disabled. The server stays the only authority; rules the client cannot decide
// authoritatively (name uniqueness is unique(zone_id, name) and MapLocation carries no zone_id)
// surface as WARNINGS, never fake errors.
//
// HARD BOUNDARIES:
//   • FLAG ONLY — no rule mutates, clamps, or throws on any payload value (no-hidden-clamping law).
//   • ONE bounds authority (openSpaceTransform.isWithinOpenSpaceBounds), ONE distance formula
//     (travelPreview.distance), ONE enum authority (locationEnums) — no second copies.
//   • DETERMINISTIC — same payload + context ⇒ deep-equal report, always.
import { isWithinOpenSpaceBounds } from '../map/openSpaceTransform'
import { distance } from '../../game/movement/travelPreview'
import { ACTIVITY_TYPES, LOCATION_STATUSES, LOCATION_TYPES } from './locationEnums'
import type { MapLocation } from '../map/mapTypes'
import type {
  DraftMode,
  DraftSourceStatus,
  LocationDraft,
  LocationDraftPayload,
} from './locationDraftTypes'

// ── report contract ─────────────────────────────────────────────────────────────────────────────────

/** 'error' = a future publish WOULD be rejected (live CHECK / hard invariant) → blocks publishable.
 *  'warning' = advisory (convention, server-only-decidable, or visibility risk) → never blocks. */
export type ValidationSeverity = 'error' | 'warning'

export type ValidationCode =
  | 'coord_out_of_bounds'
  | 'name_required'
  | 'name_not_single_word'
  | 'invalid_location_type'
  | 'invalid_activity_type'
  | 'invalid_status'
  | 'reward_tier_negative'
  | 'reward_tier_not_integer'
  | 'base_difficulty_negative'
  | 'min_power_negative'
  | 'territory_radius_not_positive'
  | 'numeric_not_finite'
  | 'duplicate_name'
  | 'territory_overlap'
  | 'status_transition_risky'
  | 'source_changed'
  | 'source_missing'
  | 'conflicting_draft'

export interface ValidationIssue {
  readonly code: ValidationCode
  readonly severity: ValidationSeverity
  /** The payload field the issue points at, or null when it spans fields / the whole draft. */
  readonly field: keyof LocationDraftPayload | null
  readonly message: string
}

export interface ValidationReport {
  readonly issues: readonly ValidationIssue[]
  /** True iff NO error-severity issue exists. Warnings never block. */
  readonly publishable: boolean
}

/** Everything a rule may consult beyond the payload itself. Assembled by the store layer
 *  (useLocationDrafts) from CURRENT live data — never persisted, never trusted from storage. */
export interface ValidationContext {
  readonly liveLocations: readonly MapLocation[]
  /** This draft's live-source relationship (draftSourceStatus output, recomputed by the store). */
  readonly sourceStatus: DraftSourceStatus
  readonly draftMode: DraftMode
  /** Every OTHER local draft (this draft excluded) — for conflicting-draft detection. */
  readonly otherDrafts: readonly LocationDraft[]
}

const err = (
  code: ValidationCode,
  field: keyof LocationDraftPayload | null,
  message: string,
): ValidationIssue => ({ code, severity: 'error', field, message })

const warn = (
  code: ValidationCode,
  field: keyof LocationDraftPayload | null,
  message: string,
): ValidationIssue => ({ code, severity: 'warning', field, message })

// ── rules (each PURE: (payload, ctx) → issue | null, or a list) ─────────────────────────────────────

/** Coordinates must sit inside the fixed open-space domain — decided by the ONE shared predicate.
 *  Out-of-domain values are FLAGGED with their exact values intact (never clamped, never thrown). */
export function ruleCoordBounds(p: LocationDraftPayload): ValidationIssue | null {
  if (isWithinOpenSpaceBounds({ x: p.x, y: p.y })) return null
  return err(
    'coord_out_of_bounds',
    null,
    'Coordinates are outside the world: x and y must be finite and within ±10000.',
  )
}

/** `name` is NOT NULL on the live table; an all-whitespace name is empty in practice. */
export function ruleNameRequired(p: LocationDraftPayload): ValidationIssue | null {
  if (p.name.trim() !== '') return null
  return err('name_required', 'name', 'Name is required.')
}

/** Seeded live names are single words BY CONVENTION only — no CHECK enforces it, so a multi-word
 *  name is a warning, never an error. */
export function ruleNameSingleWord(p: LocationDraftPayload): ValidationIssue | null {
  const name = p.name.trim()
  if (name === '' || !/\s/.test(name)) return null
  return warn(
    'name_not_single_word',
    'name',
    'Name contains whitespace — existing locations use single-word names by convention.',
  )
}

/** location_type / activity_type / status must be members of the live CHECK enums (locationEnums is
 *  the single runtime authority). A stale rehydrated draft can carry any string — flag, never throw. */
export function ruleEnumMembership(p: LocationDraftPayload): ValidationIssue[] {
  const issues: ValidationIssue[] = []
  if (!(LOCATION_TYPES as readonly string[]).includes(p.location_type))
    issues.push(
      err(
        'invalid_location_type',
        'location_type',
        `Location type '${p.location_type}' is not allowed by the live CHECK constraint.`,
      ),
    )
  if (!(ACTIVITY_TYPES as readonly string[]).includes(p.activity_type))
    issues.push(
      err(
        'invalid_activity_type',
        'activity_type',
        `Activity type '${p.activity_type}' is not allowed by the live CHECK constraint.`,
      ),
    )
  if (!(LOCATION_STATUSES as readonly string[]).includes(p.status))
    issues.push(
      err(
        'invalid_status',
        'status',
        `Status '${p.status}' is not allowed — must be one of ${LOCATION_STATUSES.join(', ')}.`,
      ),
    )
  return issues
}

/** Numeric domain rules mirroring the live CHECKs. A non-finite value (NaN/±Infinity) is its own
 *  error (numeric_not_finite); domain checks only judge finite values so one bad keystroke does not
 *  cascade into misleading extra issues. territory_radius mirrors 0217: NULL = no territory (legal),
 *  otherwise strictly positive. */
export function ruleNumericDomains(p: LocationDraftPayload): ValidationIssue[] {
  const issues: ValidationIssue[] = []
  const finite = (field: keyof LocationDraftPayload, v: number): boolean => {
    if (Number.isFinite(v)) return true
    issues.push(err('numeric_not_finite', field, `${String(field)} must be a finite number.`))
    return false
  }
  finite('x', p.x)
  finite('y', p.y)
  if (finite('reward_tier', p.reward_tier)) {
    if (p.reward_tier < 0)
      issues.push(err('reward_tier_negative', 'reward_tier', 'Reward tier must be ≥ 0.'))
    else if (!Number.isInteger(p.reward_tier))
      issues.push(err('reward_tier_not_integer', 'reward_tier', 'Reward tier must be an integer.'))
  }
  if (finite('base_difficulty', p.base_difficulty) && p.base_difficulty < 0)
    issues.push(err('base_difficulty_negative', 'base_difficulty', 'Difficulty must be ≥ 0.'))
  if (finite('min_power_required', p.min_power_required) && p.min_power_required < 0)
    issues.push(err('min_power_negative', 'min_power_required', 'Min power must be ≥ 0.'))
  if (p.territory_radius !== null && finite('territory_radius', p.territory_radius)) {
    if (p.territory_radius <= 0)
      issues.push(
        err(
          'territory_radius_not_positive',
          'territory_radius',
          'Territory radius must be greater than 0 (leave blank for no territory).',
        ),
      )
  }
  return issues
}

/** Case-insensitive name scan across ALL live locations, world-wide. WARNING only: the authoritative
 *  constraint is unique(zone_id, name) and MapLocation carries no zone_id, so the client cannot decide
 *  a true collision — the server stays the authority. An edit draft ignores its own source row. */
export function ruleDuplicateName(
  p: LocationDraftPayload,
  ctx: ValidationContext,
): ValidationIssue | null {
  const name = p.name.trim().toLowerCase()
  if (name === '') return null
  const sourceId = ctx.draftMode.kind === 'edit' ? ctx.draftMode.sourceId : null
  const dup = ctx.liveLocations.find(
    (l) => l.id !== sourceId && l.name.trim().toLowerCase() === name,
  )
  if (!dup) return null
  return warn(
    'duplicate_name',
    'name',
    `A live location named '${dup.name}' already exists — names must be unique within a zone (server-checked).`,
  )
}

/** Circle-circle territory overlap against every live territory-projecting location, using the ONE
 *  shared distance helper. Overlap iff d < r_draft + r_live — touching circles (d == sum) are NOT an
 *  overlap. WARNING: overlapping influence is a design smell, not a live constraint. An edit draft
 *  ignores its own source row. Skipped entirely when the draft projects no (valid) territory. */
export function ruleTerritoryOverlap(
  p: LocationDraftPayload,
  ctx: ValidationContext,
): ValidationIssue[] {
  const r = p.territory_radius
  if (r === null || !Number.isFinite(r) || r <= 0) return []
  if (!Number.isFinite(p.x) || !Number.isFinite(p.y)) return []
  const sourceId = ctx.draftMode.kind === 'edit' ? ctx.draftMode.sourceId : null
  const issues: ValidationIssue[] = []
  for (const live of ctx.liveLocations) {
    if (live.id === sourceId) continue
    if (live.territory_radius === null || live.territory_radius <= 0) continue
    const d = distance(p.x, p.y, live.x, live.y)
    if (d < r + live.territory_radius)
      issues.push(
        warn(
          'territory_overlap',
          'territory_radius',
          `Territory overlaps '${live.name}' (distance ${Math.round(d)} < combined radius ${r + live.territory_radius}).`,
        ),
      )
  }
  return issues
}

/** Edit-only: taking a live 'active' location to 'locked'/'hidden' drops it from the world map
 *  (get_world_map returns active locations only) — a visibility-loss WARNING, never an error. */
export function ruleStatusTransition(
  p: LocationDraftPayload,
  ctx: ValidationContext,
): ValidationIssue | null {
  if (ctx.draftMode.kind !== 'edit') return null
  if (ctx.draftMode.sourceSnapshot.status !== 'active') return null
  if (p.status !== 'locked' && p.status !== 'hidden') return null
  return warn(
    'status_transition_risky',
    'status',
    `Changing status active → ${p.status} removes this location from the world map (get_world_map serves active only).`,
  )
}

/** Stale-source surfacing (the store computes sourceStatus via draftSourceStatus): a moved live row
 *  is a review-me WARNING; a vanished live row makes the edit unpublishable (ERROR). */
export function ruleSourceFreshness(
  _p: LocationDraftPayload,
  ctx: ValidationContext,
): ValidationIssue | null {
  if (ctx.sourceStatus === 'source_changed')
    return warn(
      'source_changed',
      null,
      'The live location changed since this draft was forked — review before any future publish.',
    )
  if (ctx.sourceStatus === 'source_missing')
    return err(
      'source_missing',
      null,
      'The live location this draft was forked from no longer exists.',
    )
  return null
}

/** Two local drafts aiming at the same target: another EDIT of the same live row (edit mode), or
 *  another draft carrying the same name (create mode). WARNING — drafts are local and cheap. */
export function ruleConflictingDraft(
  p: LocationDraftPayload,
  ctx: ValidationContext,
): ValidationIssue | null {
  if (ctx.draftMode.kind === 'edit') {
    const sourceId = ctx.draftMode.sourceId
    const clash = ctx.otherDrafts.find(
      (d) => d.mode.kind === 'edit' && d.mode.sourceId === sourceId,
    )
    if (!clash) return null
    return warn(
      'conflicting_draft',
      null,
      'Another local draft also edits this live location — only one can win a future publish.',
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

/** Run every rule in canonical order and fold the issues into ONE report. publishable is true iff no
 *  error-severity issue exists — warnings advise, they never block. Pure and deterministic. */
export function validateLocationDraft(
  payload: LocationDraftPayload,
  ctx: ValidationContext,
): ValidationReport {
  const issues: ValidationIssue[] = []
  const push = (r: ValidationIssue | ValidationIssue[] | null): void => {
    if (r === null) return
    if (Array.isArray(r)) issues.push(...r)
    else issues.push(r)
  }
  push(ruleCoordBounds(payload))
  push(ruleNameRequired(payload))
  push(ruleNameSingleWord(payload))
  push(ruleEnumMembership(payload))
  push(ruleNumericDomains(payload))
  push(ruleDuplicateName(payload, ctx))
  push(ruleTerritoryOverlap(payload, ctx))
  push(ruleStatusTransition(payload, ctx))
  push(ruleSourceFreshness(payload, ctx))
  push(ruleConflictingDraft(payload, ctx))
  return { issues, publishable: !issues.some((i) => i.severity === 'error') }
}
