// WORLD EDITOR — V2A PR-2 "Mining Validation" (PURE model; draft + context in → report out). No
// React, no DOM, no network IO, no storage IO, no client-server call of any kind — the
// locationValidation.ts pure-module idiom, unit-tested directly (tests/miningValidation.spec.ts,
// tests/miningDraftGuards.spec.ts). Built on the GENERIC draft-validation contract
// (draftValidation.ts) from day one: issue/report shapes, err/warn constructors, and the fold
// aggregator all come from the ONE generic module.
//
// WHAT THIS IS: an ADVISORY, client-side mirror of the `mining_fields` invariants (0103: name NOT
// NULL + unique natural key; coordinates in the fixed open-space domain) plus editor-level sanity
// rules. It exists so a draft author sees exactly what a FUTURE publish would reject — publish
// itself remains in DEFERRED_OPERATIONS, explicitly disabled. The server stays the only authority;
// rules the client cannot decide authoritatively (the client only sees ACTIVE fields, so a clash
// with a hidden/inactive field is invisible) surface as WARNINGS, never fake errors.
//
// HARD BOUNDARIES:
//   • FLAG ONLY — no rule mutates, clamps, or throws on any payload value (no-hidden-clamping law).
//   • ONE bounds authority (openSpaceTransform.isWithinOpenSpaceBounds), ONE distance formula
//     (travelPreview.distance), ONE bundle shape (lib/rewardBundle.ts) — no second copies.
//   • DETERMINISTIC — same draft + context ⇒ deep-equal report, always.
import { isWithinOpenSpaceBounds } from '../map/openSpaceTransform'
import { distance } from '../../game/movement/travelPreview'
import type { MiningField } from '../mining/miningTypes'
import type { MiningDraft, MiningDraftMode, MiningDraftPayload } from './miningDraftTypes'
import {
  draftValidationError,
  draftValidationWarning,
  foldDraftValidationReport,
  type DraftValidationContext,
  type DraftValidationIssue,
  type DraftValidationReport,
} from './draftValidation'

// ── report contract (the generic shapes bound to the mining domain) ─────────────────────────────────

export type MiningValidationCode =
  | 'coord_out_of_bounds'
  | 'numeric_not_finite'
  | 'name_required'
  | 'duplicate_name'
  | 'reward_bundle_invalid'
  | 'reward_bundle_missing'
  | 'field_overlap'
  | 'source_changed'
  | 'source_missing'
  | 'conflicting_draft'

export type MiningValidationField = keyof MiningDraftPayload & string

export type MiningValidationIssue = DraftValidationIssue<MiningValidationCode, MiningValidationField>

export type MiningValidationReport = DraftValidationReport<MiningValidationIssue>

/** Everything a rule may consult beyond the draft itself — the generic store assembles this from
 *  CURRENT live data (DraftValidationEnv bound to the mining domain). `live` is the ACTIVE fields
 *  only (get_active_mining_fields is the client's whole view of mining_fields). */
export type MiningValidationContext = DraftValidationContext<MiningDraftPayload, MiningField>

/** Mirrors the server's own coalesce(cfg_num('mining_extract_radius'), 750) fallback (0104) — the
 *  world-unit radius within which a settled fleet can extract from a field. Two fields closer than
 *  this radius are ambiguous targets for the nearest-field extract, so overlap is flagged (WARNING —
 *  the live runtime reads the tunable from game_config; this pure module cannot, so the server
 *  default is the honest advisory baseline, the same fallback useGalaxyMapData renders rings with). */
export const MINING_FIELD_OVERLAP_RADIUS = 750

/** The generic issue constructors pinned to the mining domain's code/field unions (a null field
 *  would otherwise widen TField to string). */
const err = (
  code: MiningValidationCode,
  field: MiningValidationField | null,
  message: string,
): MiningValidationIssue => draftValidationError<MiningValidationCode, MiningValidationField>(code, field, message)

const warn = (
  code: MiningValidationCode,
  field: MiningValidationField | null,
  message: string,
): MiningValidationIssue => draftValidationWarning<MiningValidationCode, MiningValidationField>(code, field, message)

// ── rules (each PURE: (payload/mode, ctx) → issue | null, or a list) ────────────────────────────────

/** Coordinates must sit inside the fixed open-space domain — decided by the ONE shared predicate.
 *  Out-of-domain values are FLAGGED with their exact values intact (never clamped, never thrown). */
function ruleCoordBounds(p: MiningDraftPayload): MiningValidationIssue | null {
  if (isWithinOpenSpaceBounds({ x: p.space_x, y: p.space_y })) return null
  return err(
    'coord_out_of_bounds',
    null,
    'Coordinates are outside the world: space_x and space_y must be finite and within ±10000.',
  )
}

/** A non-finite coordinate (NaN/±Infinity) is its own per-field error, so one bad keystroke reads
 *  honestly instead of only as a generic bounds failure. */
function ruleNumericFiniteness(p: MiningDraftPayload): MiningValidationIssue[] {
  const issues: MiningValidationIssue[] = []
  if (!Number.isFinite(p.space_x))
    issues.push(err('numeric_not_finite', 'space_x', 'space_x must be a finite number.'))
  if (!Number.isFinite(p.space_y))
    issues.push(err('numeric_not_finite', 'space_y', 'space_y must be a finite number.'))
  return issues
}

/** `name` is NOT NULL on mining_fields (0103); an all-whitespace name is empty in practice. */
function ruleNameRequired(p: MiningDraftPayload): MiningValidationIssue | null {
  if (p.name.trim() !== '') return null
  return err('name_required', 'name', 'Name is required (mining_fields.name is NOT NULL).')
}

/** Case-insensitive name scan across the live ACTIVE fields. WARNING only: the client's whole view
 *  of mining_fields is get_active_mining_fields, so a clash with a hidden/inactive field is
 *  invisible here — the server (unique natural key) stays the authority. An edit draft ignores its
 *  own source row (liveId is the name — mining has no client-visible uuid). */
function ruleDuplicateName(
  p: MiningDraftPayload,
  mode: MiningDraftMode,
  ctx: MiningValidationContext,
): MiningValidationIssue | null {
  const name = p.name.trim().toLowerCase()
  if (name === '') return null
  const sourceId = mode.kind === 'edit' ? mode.sourceId : null
  const dup = ctx.live.find((f) => f.name !== sourceId && f.name.trim().toLowerCase() === name)
  if (!dup) return null
  return warn(
    'duplicate_name',
    'name',
    `An active field named '${dup.name}' already exists — names are a unique key (server-checked; hidden fields are invisible to this scan).`,
  )
}

/** The CREATE-only local reward bundle. Shape rule (present ⇒ ERROR on violation): a non-empty
 *  items[] of { item_id: non-empty string, quantity: positive integer } — the ONE shared
 *  pending-bundle contract. Absent bundle: on a CREATE draft it is a WARNING (a future publish
 *  would make a field with no reward); on an EDIT draft null is the only honest value (the live
 *  bundle is never readable — see miningDraftTypes.ts) so it raises nothing. */
function ruleRewardBundle(
  p: MiningDraftPayload,
  mode: MiningDraftMode,
): MiningValidationIssue | readonly MiningValidationIssue[] | null {
  const b = p.reward_bundle_json
  if (b === null) {
    if (mode.kind !== 'create') return null
    return warn(
      'reward_bundle_missing',
      'reward_bundle_json',
      'No reward configured — a future publish would create a field with an empty reward bundle.',
    )
  }
  const issues: MiningValidationIssue[] = []
  const items = b.items
  if (!Array.isArray(items) || items.length === 0) {
    issues.push(
      err(
        'reward_bundle_invalid',
        'reward_bundle_json',
        'Reward bundle must carry a non-empty items[] list.',
      ),
    )
    return issues
  }
  items.forEach((it, i) => {
    if (typeof it.item_id !== 'string' || it.item_id.trim() === '')
      issues.push(
        err(
          'reward_bundle_invalid',
          'reward_bundle_json',
          `Reward item #${i + 1}: item_id must be a non-empty string.`,
        ),
      )
    if (typeof it.quantity !== 'number' || !Number.isInteger(it.quantity) || it.quantity <= 0)
      issues.push(
        err(
          'reward_bundle_invalid',
          'reward_bundle_json',
          `Reward item #${i + 1}: quantity must be a positive integer.`,
        ),
      )
  })
  return issues
}

/** Two fields closer than the extraction radius are ambiguous targets for the nearest-field extract
 *  — a design-smell WARNING, not a live constraint. ONE shared distance formula
 *  (travelPreview.distance); d == radius (touching) is NOT an overlap. An edit draft ignores its own
 *  source row. Skipped entirely on non-finite draft coordinates (the finiteness rule already fired). */
function ruleFieldOverlap(
  p: MiningDraftPayload,
  mode: MiningDraftMode,
  ctx: MiningValidationContext,
): MiningValidationIssue[] {
  if (!Number.isFinite(p.space_x) || !Number.isFinite(p.space_y)) return []
  const sourceId = mode.kind === 'edit' ? mode.sourceId : null
  const issues: MiningValidationIssue[] = []
  for (const live of ctx.live) {
    if (live.name === sourceId) continue
    const d = distance(p.space_x, p.space_y, live.space_x, live.space_y)
    if (d < MINING_FIELD_OVERLAP_RADIUS)
      issues.push(
        warn(
          'field_overlap',
          null,
          `Within extraction range of '${live.name}' (distance ${Math.round(d)} < radius ${MINING_FIELD_OVERLAP_RADIUS}) — nearest-field extraction becomes ambiguous.`,
        ),
      )
  }
  return issues
}

/** Stale-source surfacing (the store computes sourceStatus via draftSourceStatus): a moved live row
 *  is a review-me WARNING; a vanished live row makes the edit unpublishable (ERROR). */
function ruleSourceFreshness(ctx: MiningValidationContext): MiningValidationIssue | null {
  if (ctx.sourceStatus === 'source_changed')
    return warn(
      'source_changed',
      null,
      'The live field changed since this draft was forked — review before any future publish.',
    )
  if (ctx.sourceStatus === 'source_missing')
    return err(
      'source_missing',
      null,
      'The live field this draft was forked from is no longer active.',
    )
  return null
}

/** Two local drafts aiming at the same target: another EDIT of the same live row (edit mode), or
 *  another draft carrying the same name (create mode). WARNING — drafts are local and cheap. */
function ruleConflictingDraft(
  p: MiningDraftPayload,
  mode: MiningDraftMode,
  ctx: MiningValidationContext,
): MiningValidationIssue | null {
  if (mode.kind === 'edit') {
    const sourceId = mode.sourceId
    const clash = ctx.otherDrafts.find((d) => d.mode.kind === 'edit' && d.mode.sourceId === sourceId)
    if (!clash) return null
    return warn(
      'conflicting_draft',
      null,
      'Another local draft also edits this live field — only one can win a future publish.',
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

/** Run every rule in canonical order and fold the issues into ONE report via the generic
 *  aggregator. publishable is true iff no error-severity issue exists — warnings advise, they never
 *  block. Pure and deterministic. */
export function validateMiningDraft(
  draft: MiningDraft,
  ctx: MiningValidationContext,
): MiningValidationReport {
  const p = draft.payload
  return foldDraftValidationReport<MiningValidationIssue>([
    ruleCoordBounds(p),
    ruleNumericFiniteness(p),
    ruleNameRequired(p),
    ruleDuplicateName(p, draft.mode, ctx),
    ruleRewardBundle(p, draft.mode),
    ruleFieldOverlap(p, draft.mode, ctx),
    ruleSourceFreshness(ctx),
    ruleConflictingDraft(p, draft.mode, ctx),
  ])
}
