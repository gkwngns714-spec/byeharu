// WORLD EDITOR — "Revert to this version" DECISION MODEL (pure; entry in → decision/command out). No
// React, no DOM, no network IO, no storage IO, no supabase call — the draftModel.ts idiom.
//
// A revert is ONE concept on ONE authority: the server-side public.world_editor_revert(p_request_id,
// p_audit_id) RPC (migration 0267). It reads the RAW audit row by id and re-applies its before_snapshot
// server-side across ALL FOUR update domains (location / mining_field / exploration_site / zone). The
// client CANNOT reconstruct the historical state — mining/exploration reverts need server-only
// reward_bundle_json the audit READER strips, and zone reverts need the fork-time WKT geometry — so this
// module holds ONLY the two pure decisions the shell composes on that path:
//   1. canRevertEntry     — the button-visibility rule (WHICH audit rows can be reverted at all).
//   2. revertCommandEnvelope — build the world_editor_revert command envelope from an audit entry.
//
// This REPLACES the retired PR #269 client-side location-only reconstruction (the historical-field
// projection + edit-draft seed): there is now ONE revert path — the server RPC — no leftover client field
// reconstruction, and it covers all four domains with a single click.
import { newRequestId, type WorldEditorCommandEnvelope, type RevertCommandPayload } from './commandContract'
import type { WorldEditorAuditEntry } from './worldEditorAuditTypes'

/** The four command types a revert can target — an UPDATE whose before_snapshot the server can re-apply.
 *  Mirrors the RPC's revertable set exactly (create / set_active / unpublish are out of scope → refused
 *  server-side as not_revertable, and never offered here). */
export const REVERTABLE_COMMAND_TYPES = [
  'location_update',
  'mining_field_update',
  'exploration_site_update',
  'zone_update',
] as const

/**
 * True iff this audit row can be reverted: it must be one of the four revertable UPDATE command types AND
 * carry a non-null `before` (a create has none — there is no prior state to restore). Every other command
 * type — *_create, *_set_active, zone_unpublish, world_editor_ping, or any unknown-preserved string —
 * returns false, so the button is never offered for them (the server would also refuse with not_revertable).
 */
export function canRevertEntry(entry: WorldEditorAuditEntry): boolean {
  return (REVERTABLE_COMMAND_TYPES as readonly string[]).includes(entry.commandType) && entry.before != null
}

/**
 * Build the world_editor_revert command envelope for an audit entry. It carries the entry's audit id as
 * the payload (the server takes p_audit_id, not a {target_id, expected, fields} bag) and mints a FRESH
 * request_id per attempt, so a retry after a transient failure is a distinct attempt — while the SERVER's
 * request_id idempotency still makes any accidental exact replay a no-op. targetType/targetId are echoed
 * for the audit envelope's own metadata; the SERVER re-reads the authoritative target from the audit row.
 */
export function revertCommandEnvelope(
  entry: WorldEditorAuditEntry,
): WorldEditorCommandEnvelope<RevertCommandPayload> {
  return {
    requestId: newRequestId(),
    commandType: 'world_editor_revert',
    targetType: entry.targetType,
    targetId: entry.targetId,
    payload: { audit_id: entry.id },
  }
}
