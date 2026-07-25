// TYPED-ZONE — the DISPATCH CONTRACT (slice 2). TYPES AND CONSTANTS ONLY.
//
// ── THIS FILE CONTAINS NO EXECUTABLE DECISION LOGIC, ON PURPOSE ─────────────────────────────────
// Byeharu is server-authoritative. The live geometry and interception runtime are already PL/pgSQL,
// and slice 3 compares the new planner against the deployed 0233 path INSIDE the database. A
// TypeScript implementation of coalescing, selection or risk would therefore either become a second
// authority or be thrown away — so the planner is `typed_zone_effect_dispatch_v1` in SQL, and this
// file is only the shape of the conversation with it: request in, plan or typed failure out.
//
// If you find yourself adding a function here that decides ANYTHING about a plan, it belongs in the
// migration instead. The only code permitted in this file is type-level.
//
// ── VERSIONING ──────────────────────────────────────────────────────────────────────────────────
// `contract_version` and `behavior_version` are pinned to 1 as LITERAL types. When dispatch semantics
// change materially the answer is a NEW versioned pair — `typed_zone_effect_dispatch_v2` plus a V2
// contract — never a CREATE OR REPLACE of V1 and never a widened union here. V1 remains immutable
// historical behaviour, so an already-planned effect can always be re-derived exactly.
// `behavior_version` therefore comes from the versioned IMPLEMENTATION, not from a mutable schema
// column: it describes executable semantics, not content configuration, and must never be added to
// zone_effect_pirate_intercept.

export type Uuid = string

export type ZoneStatus = 'active' | 'inactive'

/** Identity/rendering classification. Deliberately NOT constrained to 'pirate': dispatch is driven by
 *  EFFECTS, never by zone_kind. It rides along purely for rendering, traceability and audit. */
export type ZoneKindCode = string

// ── events ──────────────────────────────────────────────────────────────────────────────────────

/** A fleet leg crossing zone geometry — the only event V1 knows. */
export type FleetLegTraversalEventV1 = Readonly<{
  event_type: 'fleet_leg_traversal'
  /** For the current pirate runtime this is `movement_id`: the stable identity of this one gameplay
   *  event, so re-planning it yields identical idempotency keys. */
  event_id: Uuid
  /** The same combined stat input the 0233 risk function takes (combat_power + survival). */
  combined_stats: number
}>

export type ZoneEventV1 = FleetLegTraversalEventV1

// ── candidates ──────────────────────────────────────────────────────────────────────────────────

/** How the event's geometry met this zone. Computed by the spatial candidate-builder BEFORE the
 *  dispatcher runs — the pure dispatcher performs no geometry operations whatsoever. */
export type FleetLegIntersectionMatchV1 = Readonly<{
  match_type: 'fleet_leg_intersection'
  /** Must be finite and within [0, 1]. */
  exposure_fraction: number
  ambush_x: number
  ambush_y: number
}>

/** The five risk knobs, fully RESOLVED (no nulls). Produced by the caller coalescing each per-zone
 *  override against its global; the dispatcher never reads game_config itself. */
export type PirateInterceptKnobsV1 = Readonly<{
  base_risk: number
  min_risk: number
  max_risk: number
  exposure_floor: number
  stat_reference: number
}>

/** The per-zone overrides exactly as stored: null means inherit. */
export type PirateInterceptOverridesV1 = Readonly<{
  base_risk: number | null
  min_risk: number | null
  max_risk: number | null
  exposure_floor: number | null
  stat_reference: number | null
}>

export type PirateInterceptEffectCandidateV1 = Readonly<{
  effect_type: 'pirate_intercept'
  overrides: PirateInterceptOverridesV1
}>

/** V1's effect union has exactly one member. A request carrying any other effect_type is a typed
 *  failure, never silently dropped. */
export type ZoneEffectCandidateV1 = PirateInterceptEffectCandidateV1

export type CandidateZoneV1 = Readonly<{
  zone_id: Uuid
  /** Retained for rendering, traceability and audit context. It MUST NOT participate in effect
   *  applicability or selection. */
  zone_kind: ZoneKindCode
  zone_status: ZoneStatus
  /** Aggregate revision of the zone INCLUDING its effect set, so a plan can be tied to the exact
   *  configuration it was derived from. */
  zone_revision: number
  match: FleetLegIntersectionMatchV1
  /** A SET keyed by effect_type. Duplicate effect_type entries are invalid, not merged. An empty
   *  array is valid and simply plans nothing. */
  effects: readonly ZoneEffectCandidateV1[]
}>

/** The resolved global fallbacks, passed IN. Slice 3's candidate builder resolves these using the
 *  current `cfg_num(..., fallback)` behaviour; the pure dispatcher must never substitute the 0233
 *  literal defaults itself. */
export type ZoneEffectRuntimeConfigV1 = Readonly<{
  pirate_intercept_globals: PirateInterceptKnobsV1
}>

export type ZoneEffectDispatchRequestV1 = Readonly<{
  contract_version: 1
  event: ZoneEventV1
  runtime_config: ZoneEffectRuntimeConfigV1
  candidates: readonly CandidateZoneV1[]
}>

// ── the plan ────────────────────────────────────────────────────────────────────────────────────

/** All four parts are required. Dropping any one lets two effects on the same zone collide when both
 *  happen to use behavior version 1. */
export type EffectIdempotencyIdentityV1 = Readonly<{
  event_id: Uuid
  zone_id: Uuid
  effect_type: 'pirate_intercept'
  behavior_version: 1
}>

export type PlannedPirateInterceptEffectV1 = Readonly<{
  effect_type: 'pirate_intercept'
  behavior_version: 1
  zone_id: Uuid
  zone_kind: ZoneKindCode
  zone_revision: number
  idempotency: EffectIdempotencyIdentityV1
  selection: Readonly<{
    policy: 'max_exposure_then_zone_id_asc'
    exposure_fraction: number
    ambush_x: number
    ambush_y: number
  }>
  /** The knobs this risk was computed from — carried so a shadow diff shows WHY two risks differ,
   *  not merely that they do. */
  resolved_config: PirateInterceptKnobsV1
  risk: number
}>

export type PlannedZoneEffectV1 = PlannedPirateInterceptEffectV1

export type ZoneEffectPlanV1 = Readonly<{
  contract_version: 1
  event_id: Uuid
  /** Canonically ordered for stable comparison and serialisation. Array order is NOT an
   *  execution-precedence contract. */
  planned_effects: readonly PlannedZoneEffectV1[]
}>

// ── typed failures ──────────────────────────────────────────────────────────────────────────────

export type ZoneEffectDispatchErrorCodeV1 =
  | 'invalid_contract_version'
  | 'invalid_event'
  | 'invalid_runtime_config'
  | 'invalid_candidate'
  | 'duplicate_zone_id'
  | 'duplicate_effect_type'
  | 'unsupported_event_type'
  | 'unsupported_effect_type'
  | 'invalid_resolved_effect_config'

export type ZoneEffectDispatchErrorV1 = Readonly<{
  code: ZoneEffectDispatchErrorCodeV1
  /** JSON-style path, e.g. `candidates[1].effects[0].overrides.min_risk`. */
  path: string
  /** Diagnostic only. Callers must branch on `code`, never on this message. */
  message: string
}>

export type ZoneEffectDispatchResultV1 =
  | Readonly<{ ok: true; plan: ZoneEffectPlanV1 }>
  | Readonly<{ ok: false; error: ZoneEffectDispatchErrorV1 }>

// ── pinned constants (shared vocabulary, not decisions) ─────────────────────────────────────────

export const ZONE_EFFECT_CONTRACT_VERSION_V1 = 1 as const
export const ZONE_EFFECT_BEHAVIOR_VERSION_V1 = 1 as const

/** The one event/effect pair V1 supports. Anything else is `unsupported_*`, never ignored. */
export const ZONE_EFFECT_SUPPORTED_EVENT_TYPES_V1 = ['fleet_leg_traversal'] as const
export const ZONE_EFFECT_SUPPORTED_EFFECT_TYPES_V1 = ['pirate_intercept'] as const

/** The selection policy, as named data rather than an accident of query shape. Transcribed from
 *  0233's `order by exposure_fraction desc, zone_id asc`. */
export const ZONE_EFFECT_SELECTION_POLICY_V1 = 'max_exposure_then_zone_id_asc' as const

/** The versioned SQL functions this contract talks to. Changing semantics means adding `_v2`
 *  siblings, never editing these. */
export const ZONE_EFFECT_DISPATCH_FUNCTION_V1 = 'typed_zone_effect_dispatch_v1' as const
export const ZONE_EFFECT_RISK_FUNCTION_V1 = 'typed_zone_pirate_intercept_risk_v1' as const
