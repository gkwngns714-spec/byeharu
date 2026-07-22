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

// ── the 0255 zone_unpublish (twin of zone_create) command envelope ────────────────────────────────
// zone_unpublish flips ONE danger_zones row from status 'active'→'inactive' (soft unpublish; the row
// is preserved). Payload = {target_id: the zone uuid, expected: {name, source, location_id}}. Its
// server behavior is proven by scripts/worldeditor-publish-zone-unpublish-proof.sql; here we only pin
// the RPC mapping + the envelope normalization for its result and its typed rejections, including the
// NEW not_unpublishable code (details: protected_zone | already_inactive).
const UNPUBLISH_ENVELOPE: WorldEditorCommandEnvelope = {
  requestId: 'req-zoneunpub-1',
  commandType: 'zone_unpublish',
  payload: {
    target_id: '2f8a1b3c-0000-4000-8000-000000000099',
    expected: { name: 'Crimson Reach', source: 'drawn', location_id: null },
  },
}

test('commandRpcName maps zone_unpublish to its server entrypoint', () => {
  expect(commandRpcName('zone_unpublish')).toBe('zone_unpublish')
})

test('normalizeEnvelope: a zone_unpublish success carries {unpublished,id,name,status} + command_type through', () => {
  const raw: RawServerEnvelope = {
    ok: true,
    request_id: 'req-zoneunpub-1',
    command_type: 'zone_unpublish',
    result: {
      unpublished: true,
      id: '2f8a1b3c-0000-4000-8000-000000000099',
      name: 'Crimson Reach',
      status: 'inactive',
    },
  }
  const r = normalizeEnvelope(UNPUBLISH_ENVELOPE, raw)
  expect(r.ok).toBe(true)
  if (!r.ok) throw new Error('unreachable')
  expect(r.commandType).toBe('zone_unpublish')
  expect(r.result).toEqual({
    unpublished: true,
    id: '2f8a1b3c-0000-4000-8000-000000000099',
    name: 'Crimson Reach',
    status: 'inactive',
  })
})

test('normalizeEnvelope: a zone_unpublish idempotent replay keeps replayed + duplicate_request code', () => {
  const r = normalizeEnvelope(UNPUBLISH_ENVELOPE, {
    ok: true,
    request_id: 'req-zoneunpub-1',
    command_type: 'zone_unpublish',
    replayed: true,
    code: 'duplicate_request',
    result: { unpublished: true, id: '2f8a1b3c-0000-4000-8000-000000000099', name: 'Crimson Reach', status: 'inactive' },
  })
  if (!r.ok) throw new Error('replay must normalize as ok')
  expect(r.replayed).toBe(true)
  expect(r.code).toBe('duplicate_request')
})

test('normalizeEnvelope: a zone_unpublish not_found envelope carries the source_missing detail through', () => {
  const r = normalizeEnvelope(UNPUBLISH_ENVELOPE, {
    ok: false,
    request_id: 'req-zoneunpub-1',
    error: 'not_found',
    details: [{ code: 'source_missing', field: null }],
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('not_found')
  expect(r.details?.[0]?.code).toBe('source_missing')
})

test('normalizeEnvelope: a zone_unpublish stale_revision envelope carries per-field source_changed details through', () => {
  const r = normalizeEnvelope(UNPUBLISH_ENVELOPE, {
    ok: false,
    request_id: 'req-zoneunpub-1',
    error: 'stale_revision',
    details: [{ code: 'source_changed', field: 'name' }],
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('stale_revision')
  expect(r.details?.[0]).toEqual({ code: 'source_changed', field: 'name' })
})

test('normalizeEnvelope: a zone_unpublish not_unpublishable carries protected_zone / already_inactive details through', () => {
  const protectedZone = normalizeEnvelope(UNPUBLISH_ENVELOPE, {
    ok: false,
    request_id: 'req-zoneunpub-1',
    error: 'not_unpublishable',
    details: [{ code: 'protected_zone', field: 'source' }],
  })
  if (protectedZone.ok) throw new Error('unreachable')
  expect(protectedZone.error).toBe('not_unpublishable')
  expect(protectedZone.details?.[0]?.code).toBe('protected_zone')

  const alreadyInactive = normalizeEnvelope(UNPUBLISH_ENVELOPE, {
    ok: false,
    request_id: 'req-zoneunpub-1',
    error: 'not_unpublishable',
    details: [{ code: 'already_inactive', field: 'status' }],
  })
  if (alreadyInactive.ok) throw new Error('unreachable')
  expect(alreadyInactive.details?.[0]?.code).toBe('already_inactive')
})

// ── the 0266 zone_update (zone EDIT command) envelope ─────────────────────────────────────────────
// zone_update re-materializes an edit draft's geometry onto the SAME danger_zones row. Payload =
// {target_id: the zone uuid, expected: the fork-time {name, zone_kind, attach_location_id, geometry}
// snapshot, fields: {name, attach_location_id, geometry}}. Its server behavior is proven by
// scripts/worldeditor-publish-zone-update-proof.sql; here we only pin the RPC mapping + the envelope
// normalization for its result and its typed rejections (stale_revision, the authoritative
// invalid_geometry, and the seeded-zone protected_zone — all riding the existing pipelines, NO new
// error code).
const UPDATE_ENVELOPE: WorldEditorCommandEnvelope = {
  requestId: 'req-zoneupd-1',
  commandType: 'zone_update',
  payload: {
    target_id: '2f8a1b3c-0000-4000-8000-000000000099',
    // the fork-time sourceSnapshot (zoneDraftModel.projectFromLive) — geometry is an OPEN polygon ring.
    expected: {
      name: 'Crimson Reach',
      zone_kind: 'pirate',
      attach_location_id: null,
      geometry: {
        kind: 'polygon',
        vertices: [
          { x: 0, y: 0 },
          { x: 300, y: 0 },
          { x: 300, y: 300 },
          { x: 0, y: 300 },
        ],
      },
    },
    // only the MUTABLE slice goes over the wire (zone_kind is fixed 'pirate', never edited); the server
    // materializes the geometry (here re-seeded as a circle) and re-validates everything.
    fields: {
      name: 'Crimson Reach (edited)',
      attach_location_id: '7c4d2e1a-0000-4000-8000-000000000031',
      geometry: { kind: 'circle', center: { x: 1000, y: 1000 }, radius: 200 },
    },
    source_revision: 'zoneupd-rev-1',
  },
}

test('commandRpcName maps zone_update to its server entrypoint', () => {
  expect(commandRpcName('zone_update')).toBe('zone_update')
})

test('normalizeEnvelope: a zone_update success carries {updated,id,name} + command_type through', () => {
  const raw: RawServerEnvelope = {
    ok: true,
    request_id: 'req-zoneupd-1',
    command_type: 'zone_update',
    result: { updated: true, id: '2f8a1b3c-0000-4000-8000-000000000099', name: 'Crimson Reach (edited)' },
  }
  const r = normalizeEnvelope(UPDATE_ENVELOPE, raw)
  expect(r.ok).toBe(true)
  if (!r.ok) throw new Error('unreachable')
  expect(r.commandType).toBe('zone_update')
  expect(r.result).toEqual({
    updated: true,
    id: '2f8a1b3c-0000-4000-8000-000000000099',
    name: 'Crimson Reach (edited)',
  })
  expect(r.replayed).toBeUndefined()
})

test('normalizeEnvelope: a zone_update idempotent replay keeps replayed + duplicate_request code', () => {
  const r = normalizeEnvelope(UPDATE_ENVELOPE, {
    ok: true,
    request_id: 'req-zoneupd-1',
    command_type: 'zone_update',
    replayed: true,
    code: 'duplicate_request',
    result: { updated: true, id: '2f8a1b3c-0000-4000-8000-000000000099', name: 'Crimson Reach (edited)' },
  })
  if (!r.ok) throw new Error('replay must normalize as ok')
  expect(r.replayed).toBe(true)
  expect(r.code).toBe('duplicate_request')
})

test('normalizeEnvelope: a zone_update stale_revision carries per-field source_changed details (name/geometry)', () => {
  const r = normalizeEnvelope(UPDATE_ENVELOPE, {
    ok: false,
    request_id: 'req-zoneupd-1',
    error: 'stale_revision',
    details: [
      { code: 'source_changed', field: 'name' },
      { code: 'source_changed', field: 'geometry' },
    ],
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('stale_revision')
  expect(r.details?.map((d) => d.field)).toEqual(['name', 'geometry'])
})

test('normalizeEnvelope: a zone_update not_found carries the source_missing detail through', () => {
  const r = normalizeEnvelope(UPDATE_ENVELOPE, {
    ok: false,
    request_id: 'req-zoneupd-1',
    error: 'not_found',
    details: [{ code: 'source_missing', field: null }],
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('not_found')
  expect(r.details?.[0]?.code).toBe('source_missing')
})

test('normalizeEnvelope: the zone_update invalid_geometry + protected_zone rejections ride validation_failed details', () => {
  const invalidGeom = normalizeEnvelope(UPDATE_ENVELOPE, {
    ok: false,
    request_id: 'req-zoneupd-1',
    error: 'validation_failed',
    details: [{ code: 'invalid_geometry', field: 'geometry', message: 'untangle the ring' }],
  })
  if (invalidGeom.ok) throw new Error('unreachable')
  expect(invalidGeom.error).toBe('validation_failed')
  expect(invalidGeom.details?.[0]?.code).toBe('invalid_geometry')

  // a seeded source<>'drawn' zone is not editable — a DETAIL under validation_failed, not a new code.
  const protectedZone = normalizeEnvelope(UPDATE_ENVELOPE, {
    ok: false,
    request_id: 'req-zoneupd-1',
    error: 'validation_failed',
    details: [{ code: 'protected_zone', field: 'source' }],
  })
  if (protectedZone.ok) throw new Error('unreachable')
  expect(protectedZone.error).toBe('validation_failed')
  expect(protectedZone.details?.[0]?.code).toBe('protected_zone')
})
