// WORLD EDITOR V4 — "Revert to this version" DECISION MODEL (pure; props in → decision out). No React,
// no DOM, no network IO, no storage IO, no client-server call of any kind — the draftModel.ts idiom.
//
// A revert is NOT a new mechanism: it is an ordinary EDIT draft whose fields are a historical
// `before_snapshot`, published through the EXISTING owner-gated location_update RPC. This module owns
// ONLY the three pure decisions the shell composes on that path:
//   1. canRevertEntry  — the button-visibility rule (WHICH audit rows can be reverted at all).
//   2. revertSeedFromEntry — project a historical `before` onto exactly the location draft payload keys.
//   3. resolveLocationRevert — pair a revert against the CURRENT live location by targetId (or refuse).
//
// THE LOAD-BEARING RULE (enforced by the fork the shell then runs, proven in the spec): the edit draft
// is forked off the CURRENT LIVE location, so its `expected`/sourceSnapshot is the current live
// projection (optimistic concurrency still guards); only the editable payload is overlaid with the
// historical values. `expected` = current-live, `fields` = historical.
//
// SCOPE: ONLY location_update entries are revertable. CREATEs (no before), set_active / unpublish, and
// ALL exploration / mining / zone reverts are EXCLUDED (their snapshots are server-only or not
// client-replayable) — canRevertEntry refuses them, so the button never shows.
import type { MapLocation } from '../map/mapTypes'
import type { LocationDraftPayload } from './locationDraftTypes'
import { LOCATION_DRAFT_PAYLOAD_KEYS } from './locationDraftModel'
import type { WorldEditorAuditEntry } from './worldEditorAuditTypes'

/** The ONE command type a revert can target (a revert republishes through this exact RPC). */
export const REVERTABLE_COMMAND_TYPE = 'location_update' as const

/** The outcome the shell reports back to the History detail for inline notice rendering. */
export type RevertOutcome = 'reverted' | 'source_missing'

/**
 * True iff this audit row can be reverted: it must be a `location_update` (the only command whose
 * `before_snapshot` is a fully client-replayable location draft) AND carry a non-null `before` (a
 * create has none — there is no prior state to restore). Every other command type — location_create,
 * zone_*, exploration_*, mining_*, *_set_active, zone_unpublish, or any unknown-preserved string —
 * returns false, so the button is never offered for them.
 */
export function canRevertEntry(entry: WorldEditorAuditEntry): boolean {
  return entry.commandType === REVERTABLE_COMMAND_TYPE && entry.before != null
}

/**
 * Project a historical `before` snapshot onto EXACTLY the 11 location draft payload keys (name,
 * location_type, activity_type, x, y, reward_tier, base_difficulty, min_power_required, is_public,
 * territory_radius, status). Extra snapshot keys the reader carries (id, zone_id, max_presence_seconds,
 * created_at, …) are dropped — they are not editable draft fields. Values are trusted as-shaped at this
 * boundary exactly as a rehydrated draft is (the server re-validates every field on publish); a null
 * `before` yields an empty seed. Returned as a Partial so it overlays the live projection field-for-field.
 */
export function revertSeedFromEntry(entry: WorldEditorAuditEntry): Partial<LocationDraftPayload> {
  const before = entry.before
  if (!before) return {}
  const seed: Record<string, unknown> = {}
  for (const k of LOCATION_DRAFT_PAYLOAD_KEYS) {
    if (Object.prototype.hasOwnProperty.call(before, k)) seed[k] = before[k]
  }
  return seed as Partial<LocationDraftPayload>
}

/** The decision the shell acts on: fork onto `live` seeded with `seed`, or refuse (the source is gone). */
export type RevertResolution =
  | { readonly kind: 'ready'; readonly live: MapLocation; readonly seed: Partial<LocationDraftPayload> }
  | { readonly kind: 'source_missing' }

/**
 * Pair a revertable entry against the CURRENT live locations by `targetId`. When the live row still
 * exists, return it (the fork source — so `expected` is the current live projection) plus the historical
 * seed. When it is gone (targetId absent from the snapshot, or null), refuse: there is nothing to revert
 * onto. This NEVER forks off the audit snapshot — the live row is always the optimistic-concurrency base.
 */
export function resolveLocationRevert(
  entry: WorldEditorAuditEntry,
  liveLocations: readonly MapLocation[],
): RevertResolution {
  const live = entry.targetId ? liveLocations.find((l) => l.id === entry.targetId) ?? null : null
  if (!live) return { kind: 'source_missing' }
  return { kind: 'ready', live, seed: revertSeedFromEntry(entry) }
}
