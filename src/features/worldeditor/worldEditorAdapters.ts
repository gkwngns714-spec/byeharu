// WORLD EDITOR — the four V1 typed content-layer ADAPTERS (§WE.6–§WE.9). Each is a pure
// ReadOnlyLayerAdapter<WorldEditorData>: it READS its domain's real rows from the shared snapshot,
// RESOLVES each to a canonical-world map representation, and INSPECTS one item into typed fields. It
// implements NOTHING ELSE — no create/edit/publish/enable/disable/archive (§WE.2: deferred ops are
// explicit + absent, never simulated). Every inspector field is grounded in a REAL column that the
// read source actually returns; properties with no runtime today (mining richness/depletion,
// exploration reveal/cooldown, §WE.7/§WE.8) are NOT invented here.
//
// PURE: no React/DOM/fetch. GalaxyMap's shared `markerStyle` picks the location glyph/tone so the
// editor speaks the same visual language as the player map (§WE.11 reuse the real primitives).
import { markerStyle } from '../map/markerStyle'
import type { MapLocation } from '../map/mapTypes'
import type { MiningField } from '../mining/miningTypes'
import type { ExplorationSiteLite } from '../exploration/explorationApi'
import type { DangerZoneLite } from '../map/pirateApi'
import type { WorldEditorData } from './worldEditorData'
import { formatWorldCoord } from './worldEditorCoordinates'
import type {
  InspectorField,
  LayerItem,
  PointGlyph,
  ReadOnlyLayerAdapter,
  WorldPoint,
} from './worldEditorTypes'

// C1: coordinate presentation goes through the ONE formatter (worldEditorCoordinates) — the local
// fmtCoord moved there; the inspector renders STORED gameplay coordinates read-only, always.
const coordFields = (w: WorldPoint): InspectorField[] => [
  { label: 'World X', value: formatWorldCoord(w.x) },
  { label: 'World Y', value: formatWorldCoord(w.y) },
]

// ── Locations (§WE.6) — get_world_map rows. Glyph/tone from the shared markerStyle policy. ───────────
// GROUNDED HONESTY: get_world_map surfaces only the MapLocation fields below — physical_role /
// location_services (§WE.6) are NOT in this read payload, so they are NOT shown (no fabricated field).
export const locationLayerAdapter: ReadOnlyLayerAdapter<WorldEditorData> = {
  id: 'locations',
  title: 'Locations',
  readItems(source) {
    return source.locations.map((l: MapLocation): LayerItem => {
      const s = markerStyle(l)
      return {
        layer: 'locations',
        id: l.id,
        label: l.name,
        representation: { kind: 'point', world: { x: l.x, y: l.y } },
        tone: s.color,
        glyph: s.shape as PointGlyph,
      }
    })
  },
  inspect(source, itemId) {
    const l = source.locations.find((x) => x.id === itemId)
    if (!l) return null
    return [
      { label: 'Name', value: l.name },
      { label: 'Location type', value: l.location_type },
      { label: 'Activity', value: l.activity_type },
      { label: 'Status', value: l.status },
      { label: 'Reward tier', value: String(l.reward_tier) },
      { label: 'Base difficulty', value: String(l.base_difficulty) },
      { label: 'Min power required', value: String(l.min_power_required) },
      { label: 'Public', value: l.is_public ? 'yes' : 'no' },
      { label: 'Territory radius', value: l.territory_radius == null ? '—' : String(l.territory_radius) },
      ...coordFields({ x: l.x, y: l.y }),
    ]
  },
}

// ── Mining (§WE.7) — get_active_mining_fields rows (name + coords ONLY; NEVER reward_bundle_json). ────
export const miningLayerAdapter: ReadOnlyLayerAdapter<WorldEditorData> = {
  id: 'mining',
  title: 'Mining',
  readItems(source) {
    return source.miningFields.map((f: MiningField): LayerItem => ({
      layer: 'mining',
      id: f.name, // mining_fields.name is the unique natural key (0103); no client-visible uuid here
      label: f.name,
      representation: { kind: 'point', world: { x: f.space_x, y: f.space_y } },
      tone: 'var(--color-warning)',
      glyph: 'hex',
    }))
  },
  inspect(source, itemId) {
    const f = source.miningFields.find((x) => x.name === itemId)
    if (!f) return null
    return [
      { label: 'Name', value: f.name },
      ...coordFields({ x: f.space_x, y: f.space_y }),
      { label: 'Reward bundle', value: 'server-revealed after extraction only' },
    ]
  },
}

// ── Exploration (§WE.8) — exploration_sites SELECT (RLS server-only → typically empty; built LAST). ──
export const explorationLayerAdapter: ReadOnlyLayerAdapter<WorldEditorData> = {
  id: 'exploration',
  title: 'Exploration',
  readItems(source) {
    return source.explorationSites.map((s: ExplorationSiteLite): LayerItem => ({
      layer: 'exploration',
      id: s.name,
      label: s.name,
      representation: { kind: 'point', world: { x: s.space_x, y: s.space_y } },
      tone: 'var(--color-accent)',
      glyph: 'diamond',
    }))
  },
  inspect(source, itemId) {
    const s = source.explorationSites.find((x) => x.name === itemId)
    if (!s) return null
    return [
      { label: 'Name', value: s.name },
      ...coordFields({ x: s.space_x, y: s.space_y }),
      { label: 'Reward bundle', value: 'server-revealed after discovery only' },
    ]
  },
}

// ── Zones (§WE.9) — get_danger_zones rows. Polygon representation from the closed boundary ring. ──────
export const zoneLayerAdapter: ReadOnlyLayerAdapter<WorldEditorData> = {
  id: 'zones',
  title: 'Zones',
  readItems(source) {
    const out: LayerItem[] = []
    for (const z of source.zones) {
      if (!z.ring || z.ring.length < 3) continue
      out.push({
        layer: 'zones',
        id: z.id,
        label: z.name,
        representation: { kind: 'polygon', ring: z.ring.map(([x, y]) => ({ x, y })) },
        // Matches dangerZoneLayer: a seeded 'circle' zone reads danger, a hand-'drawn' one reads warning.
        tone: z.source === 'circle' ? 'var(--color-danger)' : 'var(--color-warning)',
        glyph: 'circle', // unused for polygons
      })
    }
    return out
  },
  inspect(source, itemId) {
    const z = source.zones.find((x: DangerZoneLite) => x.id === itemId)
    if (!z) return null
    return [
      { label: 'Name', value: z.name },
      { label: 'Source', value: z.source },
      { label: 'Boundary', value: z.location_id ? 'attached to a location' : 'standalone' },
      { label: 'Attached location', value: z.location_id ?? '—' },
      { label: 'Vertices', value: z.ring ? String(z.ring.length) : '0' },
    ]
  },
}
