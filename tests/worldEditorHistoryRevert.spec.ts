import { test, expect } from '@playwright/test'
import {
  canRevertEntry,
  revertCommandEnvelope,
  REVERTABLE_COMMAND_TYPES,
} from '../src/features/worldeditor/worldEditorHistoryRevert'
import {
  commandRpcArgs,
  commandRpcName,
  describeWorldEditorError,
} from '../src/features/worldeditor/commandContract'
import type { AuditSnapshot, WorldEditorAuditEntry } from '../src/features/worldeditor/worldEditorAuditTypes'

// WORLD EDITOR V4 (client cutover) — pure proofs for the "Revert to this version" slice AFTER it was cut
// over to the ONE server-authoritative revert (public.world_editor_revert, 0267). No browser/DB: the
// frontend spec suite runs these as deterministic Node/TS proofs. They pin (1) the button-visibility rule
// now spanning ALL FOUR revertable UPDATE domains, (2) the command envelope shape (a world_editor_revert
// carrying the entry's audit id + a fresh request_id per attempt), (3) the UNIQUE audit-id RPC arg shape
// (p_audit_id, not p_payload), and (4) the new typed error copy. The retired PR #269 client-side location
// reconstruction (resolveLocationRevert / revertSeedFromEntry / forkEditWithPayload seed) is GONE — there
// is ONE revert path and no client-side field reconstruction to test.

const HISTORICAL_BEFORE: AuditSnapshot = Object.freeze({
  id: 'loc-1',
  name: 'Aurelia Port',
  x: 120,
  y: -80,
})

const entry = (over: Partial<WorldEditorAuditEntry> = {}): WorldEditorAuditEntry => ({
  id: 'audit-1',
  requestId: 'req-1',
  commandType: 'location_update',
  targetType: 'location',
  targetId: 'loc-1',
  createdAt: '2026-02-01T00:00:00Z',
  sourceRevision: 'abcd1234',
  result: null,
  actorIsOwner: true,
  before: HISTORICAL_BEFORE,
  after: Object.freeze({ ...HISTORICAL_BEFORE, name: 'Aurelia Prime', x: 300 }),
  redactions: [],
  ...over,
})

// ── (1) button-visibility rule — ALL FOUR revertable UPDATE domains ──────────────────────────────────
test('canRevertEntry is TRUE for every revertable UPDATE command with a non-null before', () => {
  expect([...REVERTABLE_COMMAND_TYPES].sort()).toEqual(
    ['exploration_site_update', 'location_update', 'mining_field_update', 'zone_update'].sort(),
  )
  for (const commandType of REVERTABLE_COMMAND_TYPES) {
    expect(canRevertEntry(entry({ commandType })), `${commandType} must be revertable`).toBe(true)
  }
})

test('canRevertEntry is FALSE for a revertable command type with a null before (a create record)', () => {
  for (const commandType of REVERTABLE_COMMAND_TYPES) {
    expect(canRevertEntry(entry({ commandType, before: null }))).toBe(false)
  }
})

test('canRevertEntry is FALSE for every non-revertable command — even with a before present', () => {
  for (const commandType of [
    'location_create',
    'zone_create',
    'zone_unpublish',
    'exploration_site_create',
    'exploration_site_set_active',
    'mining_field_create',
    'mining_field_set_active',
    'world_editor_ping',
    'some_future_unknown_command', // unknown-preserved strings are never revertable
  ]) {
    expect(canRevertEntry(entry({ commandType }))).toBe(false)
  }
})

// ── (2) the revert command envelope shape ─────────────────────────────────────────────────────────────
test('revertCommandEnvelope builds a world_editor_revert command carrying the entry audit id', () => {
  const env = revertCommandEnvelope(entry())
  expect(env.commandType).toBe('world_editor_revert')
  expect(env.payload).toEqual({ audit_id: 'audit-1' }) // the AUDIT id, not target_id/expected/fields
  expect(env.targetType).toBe('location')
  expect(env.targetId).toBe('loc-1')
  expect(typeof env.requestId).toBe('string')
  expect(env.requestId.length).toBeGreaterThan(0)
})

test('revertCommandEnvelope mints a FRESH request_id per attempt (idempotent-retry key)', () => {
  const a = revertCommandEnvelope(entry())
  const b = revertCommandEnvelope(entry())
  expect(a.requestId).not.toBe(b.requestId)
})

test('the revert command carries the SAME audit id across attempts (a re-attempt reverts the same record)', () => {
  const a = revertCommandEnvelope(entry({ id: 'audit-77' }))
  const b = revertCommandEnvelope(entry({ id: 'audit-77' }))
  expect(a.payload).toEqual({ audit_id: 'audit-77' })
  expect(b.payload).toEqual({ audit_id: 'audit-77' })
})

// ── (3) the UNIQUE audit-id RPC arg shape ─────────────────────────────────────────────────────────────
test('commandRpcName maps world_editor_revert to its own entrypoint', () => {
  expect(commandRpcName('world_editor_revert')).toBe('world_editor_revert')
})

test('commandRpcArgs sends {p_request_id, p_audit_id} for a revert — NOT the p_payload bag', () => {
  const env = revertCommandEnvelope(entry({ id: 'audit-9' }))
  const args = commandRpcArgs(env)
  expect(args).toEqual({ p_request_id: env.requestId, p_audit_id: 'audit-9' })
  expect(args).not.toHaveProperty('p_payload') // the revert signature takes an audit id, not a payload
})

test('commandRpcArgs still sends {p_request_id, p_payload} for a normal command (shape divergence is isolated)', () => {
  const args = commandRpcArgs({
    requestId: 'req-x',
    commandType: 'location_update',
    payload: { target_id: 'loc-1', expected: {}, fields: {} },
  })
  expect(args).toEqual({ p_request_id: 'req-x', p_payload: { target_id: 'loc-1', expected: {}, fields: {} } })
  expect(args).not.toHaveProperty('p_audit_id')
})

// ── (4) the new typed error copy ─────────────────────────────────────────────────────────────────────
test('describeWorldEditorError covers the revert error codes (not_revertable / source_missing)', () => {
  expect(describeWorldEditorError('not_revertable')).toMatch(/revert/i)
  expect(describeWorldEditorError('source_missing')).toMatch(/no longer exists/i)
})
