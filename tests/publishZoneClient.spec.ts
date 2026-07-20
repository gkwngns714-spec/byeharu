import { test, expect } from '@playwright/test'
import {
  commandRpcName,
  normalizeEnvelope,
  type RawServerEnvelope,
  type WorldEditorCommandEnvelope,
} from '../src/features/worldeditor/commandContract'

// WORLD EDITOR PUBLISH SLICE (0254) — client contract unit tests for the zone command union member:
// the RPC-name mapping and envelope normalization for zone_create (the 4th/final publish domain —
// geometry publish; fields carry the draft's ZoneGeometry union verbatim and the SERVER
// materializes/validates it: invalid_geometry / invalid_attach arrive as validation_failed
// details[] and ride the existing details pipeline — no new error code). The SHARED vocabulary
// (error codes, details[] carriage, transport fallback, request-id minting) is already covered
// command-agnostically by tests/publishExplorationClient.spec.ts — not re-proven here. PURE:
// commandContract.ts performs no network IO — no live RPC is touched (the server behavior is proven
// by the disposable-matrix CI proof, scripts/worldeditor-publish-zone-create-proof.sql).
// Run: `npx playwright test publishZoneClient.spec.ts`.

const CIRCLE_ENVELOPE: WorldEditorCommandEnvelope = {
  requestId: 'req-zonecre-1',
  commandType: 'zone_create',
  payload: {
    // NO target_id / expected — a create has no live source row. fields are the zone draft payload
    // VERBATIM: the server materializes the circle (ST_Buffer) — the client sends seed geometry only.
    fields: {
      name: 'Crimson Reach',
      zone_kind: 'pirate',
      attach_location_id: '7c4d2e1a-0000-4000-8000-000000000031',
      geometry: { kind: 'circle', center: { x: 800, y: -800 }, radius: 120 },
    },
  },
}

const POLYGON_ENVELOPE: WorldEditorCommandEnvelope = {
  requestId: 'req-zonecre-2',
  commandType: 'zone_create',
  payload: {
    // a standalone drawn blob: attach_location_id null is a REAL authored value (warning-only zone);
    // the vertices ring is OPEN (the server closes it before ST_MakePolygon).
    fields: {
      name: 'Slime Verge',
      zone_kind: 'pirate',
      attach_location_id: null,
      geometry: {
        kind: 'polygon',
        vertices: [
          { x: 0, y: 0 },
          { x: 200, y: 40 },
          { x: 260, y: 220 },
          { x: 80, y: 300 },
          { x: -60, y: 160 },
        ],
      },
    },
  },
}

// ── command union → RPC entrypoint map ──────────────────────────────────────────────────────────────
test('commandRpcName maps zone_create to its server entrypoint', () => {
  expect(commandRpcName('zone_create')).toBe('zone_create')
})

// ── envelope normalization ──────────────────────────────────────────────────────────────────────────
test('normalizeEnvelope: a zone create success carries {created,id,name} + command_type through', () => {
  const raw: RawServerEnvelope = {
    ok: true,
    request_id: 'req-zonecre-1',
    command_type: 'zone_create',
    result: { created: true, id: '2f8a1b3c-0000-4000-8000-000000000099', name: 'Crimson Reach' },
  }
  const r = normalizeEnvelope(CIRCLE_ENVELOPE, raw)
  expect(r.ok).toBe(true)
  if (!r.ok) throw new Error('unreachable')
  expect(r.requestId).toBe('req-zonecre-1')
  expect(r.commandType).toBe('zone_create')
  expect(r.result).toEqual({
    created: true,
    id: '2f8a1b3c-0000-4000-8000-000000000099',
    name: 'Crimson Reach',
  })
  expect(r.replayed).toBeUndefined()
})

test('normalizeEnvelope: a zone create idempotent replay keeps replayed + duplicate_request code', () => {
  const r = normalizeEnvelope(POLYGON_ENVELOPE, {
    ok: true,
    request_id: 'req-zonecre-2',
    command_type: 'zone_create',
    replayed: true,
    code: 'duplicate_request',
    result: { created: true, id: '2f8a1b3c-0000-4000-8000-000000000099', name: 'Slime Verge' },
  })
  if (!r.ok) throw new Error('replay must normalize as ok')
  expect(r.replayed).toBe(true)
  expect(r.code).toBe('duplicate_request')
})

test('normalizeEnvelope: a zone validation_failed envelope carries the zoneValidation codes through', () => {
  const r = normalizeEnvelope(POLYGON_ENVELOPE, {
    ok: false,
    request_id: 'req-zonecre-2',
    error: 'validation_failed',
    details: [
      { code: 'name_required', field: 'name' },
      { code: 'polygon_too_few_vertices', field: 'geometry' },
      { code: 'coord_out_of_bounds', field: 'geometry' },
    ],
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('validation_failed')
  expect(r.details?.map((d) => d.code)).toEqual([
    'name_required',
    'polygon_too_few_vertices',
    'coord_out_of_bounds',
  ])
})

test('normalizeEnvelope: the authoritative invalid_geometry rejection rides the validation_failed details', () => {
  // the server's ST_IsValid + area gate — a self-intersecting ring the advisory client scan may
  // have missed. A DETAIL code under validation_failed, not a new error union member: the existing
  // details rendering covers it with zero client special-casing.
  const r = normalizeEnvelope(POLYGON_ENVELOPE, {
    ok: false,
    request_id: 'req-zonecre-2',
    error: 'validation_failed',
    details: [
      {
        code: 'invalid_geometry',
        field: 'geometry',
        message: 'The materialized boundary is not a valid, positive-area polygon — untangle the ring.',
      },
    ],
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('validation_failed')
  expect(r.details?.[0]?.code).toBe('invalid_geometry')
  expect(r.details?.[0]?.field).toBe('geometry')
  expect(r.details?.[0]?.message).toContain('untangle')
})

test('normalizeEnvelope: the invalid_attach rejection rides the validation_failed details', () => {
  const r = normalizeEnvelope(CIRCLE_ENVELOPE, {
    ok: false,
    request_id: 'req-zonecre-1',
    error: 'validation_failed',
    details: [{ code: 'invalid_attach', field: 'attach_location_id' }],
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('validation_failed')
  expect(r.details?.[0]?.code).toBe('invalid_attach')
  expect(r.details?.[0]?.field).toBe('attach_location_id')
})

test('normalizeEnvelope: a zone create not_authorized failure normalizes with no details', () => {
  const r = normalizeEnvelope(CIRCLE_ENVELOPE, {
    ok: false,
    request_id: 'req-zonecre-1',
    error: 'not_authorized',
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('not_authorized')
  expect(r.details).toBeUndefined()
})
