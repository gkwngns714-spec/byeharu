// WORLD EDITOR — V3A PR-2 "Zone Drafts" TYPES (CLIENT-SIDE ONLY, ZERO live mutation), expressed over
// the generic draft core (draftTypes.ts) exactly like the mining domain (miningDraftTypes.ts):
// ZoneDraftMode / ZoneDraft / ZoneDraftSourceStatus are the generic Draft contracts bound to the zone
// payload.
//
// A draft is a local, unpublished authoring intent for ONE danger zone: it lives in the draft store
// (localStorage) and NEVER touches the read snapshot, the `danger_zones` table, or any RPC. Publish
// does not exist in this slice (it is PR-3) — and the legacy ZoneEditor zone-write RPCs are LOCKED
// and never reused here (guarded by tests/zoneDraftGuards.spec.ts: no zone draft file may import
// the zone RPC client or the publish transport).
//
// GEOMETRY: a zone draft is authored as ONE of two seed geometries (V3A §geometry-form matrix):
//   • circle  — center + world-unit radius (CREATE-only convenience; the server materializes a ring)
//   • polygon — an OPEN vertex ring (NO closing duplicate; the wire/live ring closes it, we don't)
// A LIVE zone always materializes back to an editable POLYGON: get_danger_zones returns a closed
// vertex ring for every zone — even source='circle' rows — so projectFromLive drops the closing
// duplicate and hands the author real vertices. Circle authoring never round-trips.
import type { Draft, DraftMode as GenericDraftMode, DraftSourceStatus as GenericDraftSourceStatus } from './draftTypes'
import type { WorldPoint } from './worldEditorTypes'
import type { WorldEditorData } from './worldEditorData'

/** The live zone row (DangerZoneLite: {id, name, source, location_id, ring}) reached through the
 *  read snapshot's TYPE surface only — no zone draft file imports the zone RPC client (the
 *  no-live-write guard, tests/zoneDraftGuards.spec.ts). `ring` is the ordered, ALREADY-CLOSED
 *  world-unit [x,y] boundary (first point repeated last). */
export type LiveDangerZone = WorldEditorData['zones'][number]

/** The zone draft's seed geometry — a tagged union mapping 1:1 onto MapRepresentation's circle and
 *  polygon forms. Polygon `vertices` are an OPEN ring: the closing duplicate the live read carries is
 *  NEVER stored in a draft (dropped by projectFromLive, never appended by any gesture). */
export type ZoneGeometry =
  | { readonly kind: 'circle'; readonly center: WorldPoint; readonly radius: number }
  | { readonly kind: 'polygon'; readonly vertices: readonly WorldPoint[] }

/** The editable slice of a danger zone a draft carries.
 *
 *  `name` / `attach_location_id` mirror the live read contract (DangerZoneLite.name / .location_id).
 *  `zone_kind` is fixed 'pirate' in this slice — the one zone kind the runtime has. `geometry` is the
 *  seed authoring geometry above (a live zone projects to a polygon; circle is CREATE-only). */
export interface ZoneDraftPayload {
  readonly name: string
  readonly zone_kind: 'pirate'
  readonly attach_location_id: string | null
  readonly geometry: ZoneGeometry
}

/** Why the draft exists: a brand-new zone, or an edit forked FROM a live row — the generic DraftMode
 *  bound to the zone payload (see draftTypes.ts for the staleness/dirtiness law). */
export type ZoneDraftMode = GenericDraftMode<ZoneDraftPayload>

/** One local zone draft — the generic Draft bound to the zone payload. `draftId` is client-generated
 *  (crypto.randomUUID) and is NOT a server id. Timestamps are epoch-ms, supplied by the store layer. */
export type ZoneDraft = Draft<ZoneDraftPayload>

/** Draft ↔ live-source relationship, recomputed against CURRENT live data (never trusted from
 *  storage): 'current' | 'source_changed' | 'source_missing' (see draftTypes.ts). */
export type ZoneDraftSourceStatus = GenericDraftSourceStatus
