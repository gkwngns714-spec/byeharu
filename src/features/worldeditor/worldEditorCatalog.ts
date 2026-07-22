// WORLD EDITOR — V5 LIFECYCLE: the PURE model of the owner-only entity CATALOG (the 0269
// world_editor_entity_catalog read). Raw server rows in → typed rows / nav LayerItems out. No React,
// no DOM, no supabase, no network IO — so normalization, the domain↔layer mapping, the per-row
// selection id, and the row→LayerItem projection are unit-tested directly
// (tests/worldEditorCatalog.spec.ts).
//
// WHY THIS IS THE ONE LIFECYCLE/NAV INDEX (§WE.13 V5): every gameplay reader (get_world_map,
// get_active_mining_fields, get_danger_zones, exploration SELECT) is ACTIVE-ONLY, so the editor could
// never see or select an INACTIVE entity. The 0269 catalog returns BOTH active and inactive entities
// across all four domains with a normalized {point|geometry, lifecycle_status}. This module turns that
// ONE read into the SOLE source for map visibility, list visibility, search, camera jump, lifecycle
// filtering, selecting inactive entities, and the reactivate decision. The gameplay readers stay the
// authority for full ACTIVE-entity EDITING detail (adapter.inspect + the edit-draft fork) — this index
// is never merged into them; the two planes compose at render time only.
import { markerStyle } from '../map/markerStyle'
import type { ActivityType, LocationType } from '../map/mapTypes'
import type { WorldEntityStatusFilter } from './worldEditorFilters'
import type { LayerId, LayerItem, MapRepresentation, PointGlyph, WorldPoint } from './worldEditorTypes'

/** The lifecycle a catalog row carries — the normalized 0269 vocabulary (locations map their
 *  active|locked|hidden enum to active|inactive server-side; the rest use is_active / status). */
export type CatalogLifecycleStatus = 'active' | 'inactive'

/** The catalog's per-domain tag (SINGULAR — the exact server value), distinct from the plural LayerId
 *  the registry/map speak. `catalogDomainToLayer` is the ONE bridge. */
export type CatalogDomain = 'location' | 'mining' | 'exploration' | 'zone'

/** ONE normalized catalog row (the 0269 row contract, camelCased). `revision` is null for every row
 *  (no domain table carries a per-entity revision — 0269 header); `updatedAt` is non-null only for
 *  zones (danger_zones.updated_at); `point` is the entity's anchor/centroid; `geometry` is the closed
 *  vertex ring for zones (null for point domains). */
export interface WorldEditorCatalogRow {
  readonly domain: CatalogDomain
  readonly entityId: string
  readonly name: string
  readonly lifecycleStatus: CatalogLifecycleStatus
  readonly revision: number | null
  readonly point: WorldPoint | null
  readonly geometry: { readonly kind: 'ring'; readonly ring: readonly WorldPoint[] } | null
  readonly updatedAt: string | null
  // V5 MARKER-STYLE (0271): the four fields markerStyle reads, populated ONLY for domain='location'
  // (both active + inactive); null for mining/exploration/zone. Fed VERBATIM into the SHARED
  // markerStyle policy so location markers keep their semantic glyph/tone/hub-ring — never re-derived.
  readonly locationType: string | null
  readonly activityType: string | null
  readonly rewardTier: number | null
  readonly baseDifficulty: number | null
}

/** Map the catalog's SINGULAR domain tag to the plural LayerId the registry/map/search speak. */
export function catalogDomainToLayer(domain: CatalogDomain): LayerId {
  return domain === 'location' ? 'locations' : domain === 'zone' ? 'zones' : domain
}

/** The map/inspector SELECTION id for a row — the SAME natural key the domain's read adapter and its
 *  command path use, so an ACTIVE catalog selection resolves through the existing adapter.inspect and a
 *  reactivation targets the right key:
 *    • mining / exploration → the NAME (mining_fields.name / exploration_sites.name is the unique
 *      natural key; both *_set_active address the row by name — 0250);
 *    • location / zone      → the UUID entityId (locations.id / danger_zones.id; location_update and
 *      zone_set_active address by uuid — 0249 / 0268).
 *  Keeping the id identical to the adapter's means switching the map source to the catalog does NOT
 *  break active selection/inspection, and reactivation gets exactly the target_id its command wants. */
export function catalogRowSelectionId(row: WorldEditorCatalogRow): string {
  return row.domain === 'mining' || row.domain === 'exploration' ? row.name : row.entityId
}

// Per-domain visual tokens for the nav LayerItem (mirrors the read adapters' vocabulary so the map
// keeps one visual language). INACTIVE rows are dimmed to a faint token regardless of domain, so the
// active/inactive split reads honestly on the map.
const DOMAIN_STYLE: Record<LayerId, { readonly tone: string; readonly glyph: LayerItem['glyph'] }> = {
  locations: { tone: 'var(--color-accent)', glyph: 'circle' },
  mining: { tone: 'var(--color-warning)', glyph: 'hex' },
  exploration: { tone: 'var(--color-accent)', glyph: 'diamond' },
  zones: { tone: 'var(--color-danger)', glyph: 'circle' },
}
const INACTIVE_TONE = 'var(--color-ink-faint)'

/** The world representation a row draws as: a zone's closed ring → a polygon; anything with a point →
 *  a point. null when the row carries neither (a malformed row is dropped by the caller). */
function rowRepresentation(row: WorldEditorCatalogRow): MapRepresentation | null {
  if (row.geometry && row.geometry.ring.length >= 3) {
    return { kind: 'polygon', ring: row.geometry.ring.map((p) => ({ x: p.x, y: p.y })) }
  }
  if (row.point) return { kind: 'point', world: { x: row.point.x, y: row.point.y } }
  return null
}

/** The semantic marker (glyph / tone / hub-ring) for a LOCATION row — computed through the SHARED
 *  markerStyle policy (never re-implemented), exactly as the read adapter's location path did. Falls
 *  back SAFELY to the flat domain style when the 0271 marker fields are absent (defensive — a location
 *  row should always carry them). */
function locationMarker(row: WorldEditorCatalogRow): { tone: string; glyph: PointGlyph; hubRing: boolean } {
  if (row.locationType == null) {
    const style = DOMAIN_STYLE.locations
    return { tone: style.tone, glyph: style.glyph, hubRing: false }
  }
  const s = markerStyle({
    location_type: row.locationType as LocationType,
    activity_type: (row.activityType ?? 'none') as ActivityType,
    reward_tier: row.rewardTier ?? 0,
    base_difficulty: row.baseDifficulty ?? 0,
  })
  return { tone: s.color, glyph: s.shape as PointGlyph, hubRing: s.hubRing }
}

/** Project ONE catalog row to the SAME LayerItem shape the read adapters produce — carrying its
 *  lifecycle `status` (so the filter/search/inspector can honor it and badge INACTIVE) and its natural
 *  selection id. LOCATION rows keep their SEMANTIC markerStyle marker (glyph/tone/hub-ring, dimmed when
 *  inactive); mining/exploration/zones keep their flat per-domain styling. Returns null for a row with
 *  no drawable representation (never rendered). */
export function catalogRowToLayerItem(row: WorldEditorCatalogRow): LayerItem | null {
  const representation = rowRepresentation(row)
  if (!representation) return null
  const layer = catalogDomainToLayer(row.domain)
  const inactive = row.lifecycleStatus === 'inactive'
  // Locations resolve their glyph/tone/hub-ring through markerStyle; other domains use the flat style.
  const marker =
    layer === 'locations'
      ? locationMarker(row)
      : { tone: DOMAIN_STYLE[layer].tone, glyph: DOMAIN_STYLE[layer].glyph, hubRing: false }
  return {
    layer,
    id: catalogRowSelectionId(row),
    label: row.name,
    representation,
    // INACTIVE dims the tone to the faint token but KEEPS the semantic glyph + hub-ring.
    tone: inactive ? INACTIVE_TONE : marker.tone,
    glyph: marker.glyph,
    status: row.lifecycleStatus,
    hubRing: marker.hubRing,
  }
}

/** Group every catalog row into the per-layer LayerItem map the map render loop, search index, and
 *  layer counts all consume — the ONE nav index. Registry order (locations → mining → exploration →
 *  zones) so the map/search share the catalog's deterministic ordering; drops undrawable rows. */
export function catalogItemsByLayer(
  rows: readonly WorldEditorCatalogRow[],
): Map<LayerId, LayerItem[]> {
  const map = new Map<LayerId, LayerItem[]>([
    ['locations', []],
    ['mining', []],
    ['exploration', []],
    ['zones', []],
  ])
  for (const row of rows) {
    const item = catalogRowToLayerItem(row)
    if (!item) continue
    map.get(item.layer)!.push(item)
  }
  return map
}

/** Find the catalog row backing a map SELECTION ({layer, id}) — the lookup the inspector uses to
 *  decide active-vs-inactive and to drive the reactivate flow. Matches on the row's layer + its
 *  natural selection id (the SAME id the map item carries). */
export function findCatalogRow(
  rows: readonly WorldEditorCatalogRow[],
  layer: LayerId,
  selectionId: string,
): WorldEditorCatalogRow | null {
  for (const row of rows) {
    if (catalogDomainToLayer(row.domain) === layer && catalogRowSelectionId(row) === selectionId) {
      return row
    }
  }
  return null
}

/** Does a catalog row pass the shared lifecycle filter? The SAME semantics itemPassesStatus applies to
 *  a LayerItem — 'all' passes; else the row's lifecycle must equal the filter. Used by the shell to
 *  decide whether a SELECTED entity survives a filter change (draft-safe selection clear). */
export function catalogRowPassesStatus(
  row: WorldEditorCatalogRow,
  filter: WorldEntityStatusFilter,
): boolean {
  return filter === 'all' || row.lifecycleStatus === filter
}

// ── normalization (untrusted server jsonb → typed rows; fail-closed, drop malformed) ────────────────

function asFiniteNumber(v: unknown): number | null {
  return typeof v === 'number' && Number.isFinite(v) ? v : null
}

function normalizePoint(v: unknown): WorldPoint | null {
  if (!v || typeof v !== 'object') return null
  const o = v as Record<string, unknown>
  const x = asFiniteNumber(o.x)
  const y = asFiniteNumber(o.y)
  return x === null || y === null ? null : { x, y }
}

function normalizeGeometry(v: unknown): WorldEditorCatalogRow['geometry'] {
  if (!v || typeof v !== 'object') return null
  const o = v as Record<string, unknown>
  if (o.kind !== 'ring' || !Array.isArray(o.ring)) return null
  const ring: WorldPoint[] = []
  for (const pair of o.ring) {
    if (!Array.isArray(pair) || pair.length < 2) return null
    const x = asFiniteNumber(pair[0])
    const y = asFiniteNumber(pair[1])
    if (x === null || y === null) return null
    ring.push({ x, y })
  }
  return ring.length >= 3 ? { kind: 'ring', ring } : null
}

const CATALOG_DOMAINS: readonly CatalogDomain[] = ['location', 'mining', 'exploration', 'zone']

/** Normalize ONE untrusted server row into a typed catalog row, or null when it is malformed (unknown
 *  domain, missing id/name, bad lifecycle). A bad row is dropped, never thrown into render. */
export function normalizeCatalogRow(raw: unknown): WorldEditorCatalogRow | null {
  if (!raw || typeof raw !== 'object') return null
  const o = raw as Record<string, unknown>
  const domain = o.domain
  if (typeof domain !== 'string' || !CATALOG_DOMAINS.includes(domain as CatalogDomain)) return null
  const entityId = o.entity_id
  const name = o.name
  const lifecycle = o.lifecycle_status
  if (typeof entityId !== 'string' || entityId === '') return null
  if (typeof name !== 'string') return null
  if (lifecycle !== 'active' && lifecycle !== 'inactive') return null
  return {
    domain: domain as CatalogDomain,
    entityId,
    name,
    lifecycleStatus: lifecycle,
    revision: asFiniteNumber(o.revision), // always null today; kept for a stable contract
    point: normalizePoint(o.point),
    geometry: normalizeGeometry(o.geometry),
    updatedAt: typeof o.updated_at === 'string' ? o.updated_at : null,
    // 0271 marker-style fields — location-only (null for other domains). Kept nullable + defensive.
    locationType: typeof o.location_type === 'string' ? o.location_type : null,
    activityType: typeof o.activity_type === 'string' ? o.activity_type : null,
    rewardTier: asFiniteNumber(o.reward_tier),
    baseDifficulty: asFiniteNumber(o.base_difficulty),
  }
}

/** The typed result of a catalog read: the normalized rows, or a fail-closed empty set. A row that
 *  fails normalization is dropped (never trusted, never thrown). */
export function normalizeCatalogRows(raw: unknown): WorldEditorCatalogRow[] {
  const rows =
    raw && typeof raw === 'object' && Array.isArray((raw as Record<string, unknown>).rows)
      ? ((raw as Record<string, unknown>).rows as unknown[])
      : []
  const out: WorldEditorCatalogRow[] = []
  for (const r of rows) {
    const row = normalizeCatalogRow(r)
    if (row) out.push(row)
  }
  return out
}
