// WORLD EDITOR — the PURE command contract: the ONE typed envelope + result/error vocabulary every
// World Editor command shares, mirroring the server entrypoint contract (migration 0243
// world_editor_ping, extended by 0244 exploration_site_create). PURE MODULE: no React, no DOM, no
// supabase, no network IO of any kind — so the contract (unions, RPC-name map, envelope
// normalization, error copy) is unit-testable directly (tests/publishExplorationClient.spec.ts).
// The transport binding (the supabase.rpc call) lives in ONE sibling module that re-exports this
// contract; server-authoritative security lives in the RPC (is_owner() guard) — this contract
// grants no authority.

/** Command kinds. world_editor_ping is the guarded no-op contract proof (0243);
 *  exploration_site_create is the FIRST live-world-write publish command (0244, owner-gated);
 *  mining_field_create is its mining twin — the SECOND publish command (0246, owner-gated);
 *  exploration_site_update is the FIRST UPDATE publish command (0247, owner-gated, optimistic
 *  concurrency: payload carries target_id + the fork-time `expected` snapshot);
 *  mining_field_update is its mining twin — the SECOND UPDATE publish command (0248, same
 *  owner-gated optimistic-concurrency contract over mining_fields);
 *  location_update is the THIRD publish DOMAIN (0249, owner-gated): the location UPDATE command —
 *  uuid-addressed (target_id = the MapLocation id the edit fork pinned) with the same
 *  optimistic-concurrency contract over all 11 location draft fields;
 *  exploration_site_set_active / mining_field_set_active are the UNPUBLISH/RESTORE commands (0250,
 *  owner-gated): they toggle ONE row's is_active flag — the canonical safe unpublish (false) and
 *  re-publish (true), NO hard delete — under the same optimistic-concurrency contract (payload
 *  carries target_id + the fork-time `expected` snapshot + the boolean is_active direction);
 *  location_create is the LAST publishing gap (0252, owner-gated): creates ONE new location from a
 *  CREATE draft — fields carry a REQUIRED zone_id (uuid of an existing zone, server-validated as a
 *  typed validation_failed {invalid_zone}) beside the 11 location draft fields; no target_id /
 *  expected (a create has no live source row);
 *  zone_create is the FOURTH/final publish DOMAIN (0254, owner-gated): materializes a zone draft's
 *  seed geometry (circle {center,radius} | open polygon ring) into a live danger_zones row — fields
 *  = {name, zone_kind, attach_location_id, geometry}; server-side PostGIS is the geometry authority
 *  (a bad materialized ring is a typed validation_failed detail {invalid_geometry}; a bad attach
 *  target {invalid_attach}); NO conflict code (danger_zones.name has no unique constraint). NOT the
 *  0239-locked pirate_zone_create — a new 0243-spine surface;
 *  zone_unpublish is the zone UNPUBLISH command and twin of zone_create (0255, owner-gated): flips
 *  ONE danger_zones row from status 'active' to 'inactive' (the canonical safe unpublish — the row,
 *  geometry, name and attach survive for a future republish; NO hard delete) under the same
 *  optimistic-concurrency contract (payload = {target_id: the zone uuid, expected: {name, source,
 *  location_id}}). Ineligible targets are a typed not_unpublishable (protected_zone for seeded
 *  source<>'drawn' zones; already_inactive for non-active zones); a vanished target is not_found. */
export type WorldEditorCommandType =
  | 'world_editor_ping'
  | 'exploration_site_create'
  | 'mining_field_create'
  | 'exploration_site_update'
  | 'mining_field_update'
  | 'location_update'
  | 'location_create'
  | 'zone_create'
  | 'zone_unpublish'
  | 'exploration_site_set_active'
  | 'mining_field_set_active'
  // ENEMY CONTENT REGISTRY (0257, owner-gated, DARK behind enemy_content_registry_enabled): the six
  // net-new owner-authored catalog commands over reward_profiles + enemy_archetypes. create carries
  // the content fields; update/set_active address the live row by p_payload.target_id (the key) with
  // optimistic concurrency on p_payload.expected_revision. No runtime combat path reads these tables.
  | 'reward_profile_create'
  | 'reward_profile_update'
  | 'reward_profile_set_active'
  | 'enemy_archetype_create'
  | 'enemy_archetype_update'
  | 'enemy_archetype_set_active'
  // FLEET TEMPLATES + ENCOUNTER PROFILES (0258, owner-gated, DARK behind BOTH enemy_content_registry_enabled
  // AND encounter_authoring_enabled): the six net-new owner-authored composition commands over
  // enemy_fleet_templates + encounter_profiles (each with a normalized members child, REPLACE-ALL keyed to
  // the parent revision). create carries content + members; update/set_active address the live row by
  // p_payload.target_id (the key) with optimistic concurrency on p_payload.expected_revision. The new
  // per-member failure codes (invalid_archetype_ref / archetype_inactive / invalid_fleet_ref /
  // fleet_inactive / invalid_reward_override / invalid_count_range / duplicate_member / members_required …)
  // live in WorldEditorFailureDetail.code (free-text) inside details[] — NOT the top-level error union. No
  // runtime combat path reads these tables.
  | 'enemy_fleet_template_create'
  | 'enemy_fleet_template_update'
  | 'enemy_fleet_template_set_active'
  | 'encounter_profile_create'
  | 'encounter_profile_update'
  | 'encounter_profile_set_active'
  // LOCATION → ENCOUNTER BINDINGS (0259, owner-gated, DARK behind the TRI-FLAG chain
  // enemy_content_registry_enabled AND encounter_authoring_enabled AND encounter_binding_authoring_enabled):
  // the three net-new owner-authored commands over location_encounter_bindings — a join table binding a
  // live location (locations, 0002) to an E1 encounter_profile (0258). create carries {location_id,
  // encounter_profile_id, weight?}; update/set_active address the live row by p_payload.target_id (the
  // binding UUID) with optimistic concurrency on p_payload.expected_revision (only weight/notes/active
  // mutate — the (location, encounter) address is stable). The new per-binding failure codes
  // (invalid_location / location_inactive / invalid_encounter_ref / encounter_inactive / invalid_weight /
  // duplicate_binding) live in WorldEditorFailureDetail.code (free-text) inside details[] — NOT the
  // top-level error union. No runtime combat path reads this table.
  | 'location_encounter_binding_create'
  | 'location_encounter_binding_update'
  | 'location_encounter_binding_set_active'

/**
 * The typed command envelope every World Editor command is issued with. `requestId` is the idempotency
 * key (server-enforced UNIQUE): re-issuing the same requestId returns the prior result, never re-applies.
 */
export interface WorldEditorCommandEnvelope<P = Record<string, unknown>> {
  readonly requestId: string
  readonly commandType: WorldEditorCommandType
  readonly targetType?: string | null
  readonly targetId?: string | null
  readonly payload?: P
}

/** The typed error vocabulary returned by the server guard (must match the 0243/0244 contract). */
export type WorldEditorErrorCode =
  | 'not_authenticated' // no JWT subject (anonymous)
  | 'not_authorized' // authenticated, but not in the app_owners allow-list
  | 'invalid_request' // missing / blank requestId
  | 'duplicate_request' // idempotent replay (surfaced on a successful replay envelope)
  | 'validation_failed' // the authoritative payload subset failed server-side re-validation (0244)
  | 'stale_revision' // the live row drifted from the draft's fork-time `expected` snapshot (0247 optimistic concurrency)
  | 'not_found' // the update target no longer exists (0247; details carry source_missing)
  | 'conflict' // a unique natural key (exploration_sites.name / mining_fields.name / locations unique(zone_id,name)) is already taken (0244/0246/0249)
  | 'not_unpublishable' // the zone exists but may not be unpublished (0255; details carry protected_zone | already_inactive)
  | 'not_enabled' // the fail-closed feature flag is off (0257 enemy_content_registry_enabled — reject-before-any-read)
  | 'transport_error' // client-side: the RPC call itself failed (network / permission)

/** One structured issue inside a failure envelope (the 0244 details[] vocabulary — e.g. a
 *  validation_failed field report or a conflict's duplicate_name pointer). */
export interface WorldEditorFailureDetail {
  readonly code: string
  readonly field?: string | null
  readonly message?: string
}

export interface WorldEditorCommandSuccess<R = unknown> {
  readonly ok: true
  readonly requestId: string
  readonly commandType: WorldEditorCommandType
  readonly result: R
  /** true when this is an idempotent replay of a prior identical requestId. */
  readonly replayed?: boolean
  /** set to 'duplicate_request' on a replay; otherwise absent. */
  readonly code?: WorldEditorErrorCode
}

export interface WorldEditorCommandFailure {
  readonly ok: false
  readonly requestId: string
  readonly error: WorldEditorErrorCode
  /** structured per-issue details (0244: validation_failed / conflict envelopes); absent otherwise. */
  readonly details?: ReadonlyArray<WorldEditorFailureDetail>
}

export type WorldEditorCommandResult<R = unknown> =
  | WorldEditorCommandSuccess<R>
  | WorldEditorCommandFailure

/** Raw server envelope (snake_case) as returned by the RPC, before normalization. */
export interface RawServerEnvelope {
  ok?: boolean
  request_id?: string
  command_type?: WorldEditorCommandType
  result?: unknown
  error?: WorldEditorErrorCode
  replayed?: boolean
  code?: WorldEditorErrorCode
  details?: ReadonlyArray<WorldEditorFailureDetail>
}

/** Generate a fresh idempotency key. Uses the platform UUID (browser + Node 18+). */
export function newRequestId(): string {
  return crypto.randomUUID()
}

/** Map a command kind to its server RPC entrypoint. One entrypoint per command, no client dispatch logic. */
export function commandRpcName(commandType: WorldEditorCommandType): string {
  switch (commandType) {
    case 'world_editor_ping':
      return 'world_editor_ping'
    case 'exploration_site_create':
      return 'exploration_site_create'
    case 'mining_field_create':
      return 'mining_field_create'
    case 'exploration_site_update':
      return 'exploration_site_update'
    case 'mining_field_update':
      return 'mining_field_update'
    case 'location_update':
      return 'location_update'
    case 'location_create':
      return 'location_create'
    case 'zone_create':
      return 'zone_create'
    case 'zone_unpublish':
      return 'zone_unpublish'
    case 'exploration_site_set_active':
      return 'exploration_site_set_active'
    case 'mining_field_set_active':
      return 'mining_field_set_active'
    case 'reward_profile_create':
      return 'reward_profile_create'
    case 'reward_profile_update':
      return 'reward_profile_update'
    case 'reward_profile_set_active':
      return 'reward_profile_set_active'
    case 'enemy_archetype_create':
      return 'enemy_archetype_create'
    case 'enemy_archetype_update':
      return 'enemy_archetype_update'
    case 'enemy_archetype_set_active':
      return 'enemy_archetype_set_active'
    case 'enemy_fleet_template_create':
      return 'enemy_fleet_template_create'
    case 'enemy_fleet_template_update':
      return 'enemy_fleet_template_update'
    case 'enemy_fleet_template_set_active':
      return 'enemy_fleet_template_set_active'
    case 'encounter_profile_create':
      return 'encounter_profile_create'
    case 'encounter_profile_update':
      return 'encounter_profile_update'
    case 'encounter_profile_set_active':
      return 'encounter_profile_set_active'
    case 'location_encounter_binding_create':
      return 'location_encounter_binding_create'
    case 'location_encounter_binding_update':
      return 'location_encounter_binding_update'
    case 'location_encounter_binding_set_active':
      return 'location_encounter_binding_set_active'
    default:
      // exhaustiveness: adding a command kind without an entrypoint is a compile error.
      return assertNever(commandType)
  }
}

/** Normalize the raw snake_case server envelope into the typed camelCase result. */
export function normalizeEnvelope<R>(
  envelope: WorldEditorCommandEnvelope<unknown>,
  raw: RawServerEnvelope | null,
): WorldEditorCommandResult<R> {
  if (!raw || typeof raw.ok !== 'boolean') {
    return { ok: false, requestId: envelope.requestId, error: 'transport_error' }
  }
  if (raw.ok) {
    return {
      ok: true,
      requestId: raw.request_id ?? envelope.requestId,
      commandType: raw.command_type ?? envelope.commandType,
      result: raw.result as R,
      replayed: raw.replayed,
      code: raw.code,
    }
  }
  return {
    ok: false,
    requestId: raw.request_id ?? envelope.requestId,
    error: raw.error ?? 'transport_error',
    details: raw.details,
  }
}

/** Human-readable, exhaustive description of every error code (compile-enforces the union stays covered). */
export function describeWorldEditorError(code: WorldEditorErrorCode): string {
  switch (code) {
    case 'not_authenticated':
      return 'You must be signed in to run World Editor commands.'
    case 'not_authorized':
      return 'This account is not a World Editor owner.'
    case 'invalid_request':
      return 'The command request was malformed (missing request id).'
    case 'duplicate_request':
      return 'This command was already applied; the prior result was returned.'
    case 'validation_failed':
      return 'The server rejected the draft — fix the flagged fields and retry.'
    case 'stale_revision':
      return 'The live row changed since this draft was forked — review the draft before retrying.'
    case 'not_found':
      return 'The live row this draft edits no longer exists — it may have been renamed or removed.'
    case 'conflict':
      return 'The name is already taken in the live world.'
    case 'not_unpublishable':
      return 'This zone cannot be unpublished — it is a seeded zone or is already inactive.'
    case 'not_enabled':
      return 'The enemy content registry is not enabled — an owner must turn it on first.'
    case 'transport_error':
      return 'The command could not reach the server.'
    default:
      return assertNever(code)
  }
}

/** Compile-time exhaustiveness guard: unreachable at runtime for a fully-covered union. */
function assertNever(value: never): never {
  throw new Error(`Unhandled World Editor command variant: ${String(value)}`)
}
