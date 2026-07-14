// ITEM-VIZ — the ONE item/good/module/resource visual catalog (glyphs + labels + category tones).
//
// PURE data + pure functions (no React, no DOM — the icons.ts mold), so tests can prove the
// id→glyph/label contract for the ENTIRE real catalog (tests/itemViz.spec.ts). The subjects are
// the REAL seeded catalogs, hardcoded here as the display-side twin of the migrations (the
// assetGlyphs.ts split: the server owns the vocabulary, this file owns how each id LOOKS):
//   · item_types      — 0039_inventory + 0097_exploration seeds (12 ids)
//   · trade_goods     — 0073_trade_goods_catalog seeds (6 ids)
//   · module_types    — 0107_modules_p13 seeds (4) + 0183_mod2_shield_line seeds (2)
//   · base resources  — metal/energy (base_add_resources / station-store resource codes; crystal
//                       shares the item_types entry — same id, one glyph)
//
// Every glyph is hand-drawn 1.5px-stroke line work on a 24×24 viewBox (the Icon.tsx R0 precedent,
// richer: 2–3 subpath groups each, a distinctive silhouette per subject). Strokes are
// `currentColor` — a glyph always wears token text colors from its category tone (below), never
// its own palette. `soft: true` marks the secondary/accent strokes (rendered at reduced opacity
// by <ItemGlyph> in ItemTile.tsx) — depth without a second color.
//
// UNKNOWN IDS DEGRADE HONESTLY, NEVER CRASH: getItemGlyph/itemLabel accept ANY string. An id not
// in the catalogs resolves to the generic container glyph, a title-cased label, and — when the
// caller states its namespace via `kind` — that namespace's tone (else the neutral 'unknown'
// tone). Future catalog seeds render acceptably before this file learns them.

export type ItemCategory =
  | 'material' // item_types.category 'material' — raw salvage/minerals
  | 'component' // item_types.category 'component' — ship-part classes
  | 'data' // item_types.category 'data' — scan intel
  | 'progression' // item_types.category 'progression' — rare advancement items
  | 'good' // trade_goods — bulk market cargo
  | 'module' // module_types — craftable ship modules
  | 'resource' // base resources (metal/energy)
  | 'unknown' // honest fallback for ids no catalog knows

/** The caller's namespace hint — which catalog to prefer when ids collide (e.g. 'ore' is both an
 *  item_types row ('Ore') and a trade_goods row ('Raw Ore')). Optional everywhere. */
export type ItemKind = 'item' | 'good' | 'module' | 'resource'

export interface GlyphPath {
  d: string
  /** Secondary/accent stroke — rendered at reduced opacity (token color, lower emphasis). */
  soft?: boolean
}

// ── the real catalog ids (the totality spec asserts every one resolves known) ───────────────────

/** item_types seeds — 0039 (10) + 0097 (2). */
export const ITEM_TYPE_IDS = [
  'scrap',
  'ore',
  'crystal',
  'pirate_alloy',
  'weapon_parts',
  'engine_parts',
  'repair_parts',
  'captain_memory_shard',
  'blueprint_fragment',
  'artifact_core',
  'scan_data',
  'anomaly_shard',
] as const

/** trade_goods seeds — 0073. */
export const TRADE_GOOD_IDS = [
  'textiles',
  'ore',
  'provisions',
  'reagents',
  'machinery',
  'luxury_goods',
] as const

/** module_types seeds — 0107 (4) + 0183 mod2 shield line (2) + 0202 mod2-2 Mk-II line (2). */
export const MODULE_TYPE_IDS = [
  'autocannon_battery',
  'vector_thruster_kit',
  'expanded_cargo_lattice',
  'deep_scan_sensor_array',
  'shield_lattice',
  'mining_rig_extension',
  'autocannon_battery_mk2',
  'shield_lattice_mk2',
] as const

/** Base-resource codes that render on player surfaces (combat rewards, station hangar). */
export const RESOURCE_IDS = ['metal', 'energy'] as const

// ── the glyphs (24×24, stroke currentColor; soft = reduced-opacity accent strokes) ──────────────

const GLYPHS = {
  // Bent offcut fragments — three scattered angular plates.
  scrap: [
    { d: 'M4 10l4-4 3 3-4 4-3-3Z' },
    { d: 'M14 4l6 2.5-1.5 4L14 9V4Z' },
    { d: 'M8 16l4 4.5 6-1.5-1-4.5-5-1-4 2.5Z', soft: true },
  ],
  // Rough rock — irregular hexagonal boulder with inner facet lines.
  ore: [
    { d: 'M12 3l8 5-1.5 8L12 21l-6.5-5L4 8l8-5Z' },
    { d: 'M12 3v9l-8-4M12 12l8-4M12 12v9', soft: true },
  ],
  // Angular shard cluster — a tall crystal and a smaller companion.
  crystal: [
    { d: 'M10 3l4 4-3.5 14L6 10l4-7Z' },
    { d: 'M16 8l3.5 3-3 9-1.5-7 1-5Z' },
    { d: 'M14 7l-3.5 3H6', soft: true },
  ],
  // Riveted hull plate — rounded plate, corner rivets, diagonal weld seams.
  pirate_alloy: [
    { d: 'M6 4h12a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2Z' },
    { d: 'M7.5 7.5h.01M16.5 7.5h.01M7.5 16.5h.01M16.5 16.5h.01' },
    { d: 'M4.5 14 14 4.5M10 19.5 19.5 10', soft: true },
  ],
  // Barrel + receiver — a disassembled gun: barrel plate above the grip block.
  weapon_parts: [
    { d: 'M3 7.5h13.5L19 8.75 16.5 10H3V7.5Z' },
    { d: 'M7 13h10v3.5H12l-1.2 4H8l1.2-4H7V13Z' },
    { d: 'M20 8.75h1.5M5 13v3.5', soft: true },
  ],
  // Turbine — hub, four swept blades, outer housing ring.
  engine_parts: [
    { d: 'M12 9.5a2.5 2.5 0 1 1 0 5 2.5 2.5 0 0 1 0-5Z' },
    { d: 'M12 9.5c.5-4 3-5.5 6.5-5M14.5 12c4-.5 5.5 2 5 5.5M12 14.5c-.5 4-3 5.5-6.5 5M9.5 12c-4 .5-5.5-2-5-5.5' },
    { d: 'M12 3a9 9 0 1 1 0 18 9 9 0 0 1 0-18Z', soft: true },
  ],
  // Wrench + hex nut — the maintenance kit.
  repair_parts: [
    {
      d: 'M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76Z',
    },
    { d: 'M18.6 16.2l2.4 1.4v2.8l-2.4 1.4-2.4-1.4v-2.8l2.4-1.4Z', soft: true },
  ],
  // Brain-chip — a chip package whose die carries a memory-trace wave; pins all around.
  captain_memory_shard: [
    { d: 'M7 7h10v10H7V7Z' },
    { d: 'M9.5 13c.7-2.2 1.9-2.7 2.5-1.2s1.8 1.1 2.5-.6' },
    {
      d: 'M9 7V4.5M12 7V4.5M15 7V4.5M9 19.5V17M12 19.5V17M15 19.5V17M7 9H4.5M7 12H4.5M7 15H4.5M19.5 9H17M19.5 12H17M19.5 15H17',
      soft: true,
    },
  ],
  // Rolled schematic — the sheet unrolls from a left-hand roll; plan marks on the sheet.
  blueprint_fragment: [
    { d: 'M10 7a2.5 2.5 0 0 0-5 0v10a2.5 2.5 0 0 0 5 0V7Z' },
    { d: 'M7.5 4.5H19V19.5h-9' },
    { d: 'M12.5 8.5H16M12.5 11.5h2.5M12.5 14.5H16', soft: true },
  ],
  // Orb-in-ring — a core sphere inside an orbital band, venting along its axis.
  artifact_core: [
    { d: 'M12 8a4 4 0 1 1 0 8 4 4 0 0 1 0-8Z' },
    { d: 'M2.5 12a9.5 3.8 0 1 0 19 0 9.5 3.8 0 1 0-19 0Z', soft: true },
    { d: 'M12 3.5V5M12 19v1.5', soft: true },
  ],
  // Waveform — a signal trace inside scanner frame brackets.
  scan_data: [
    { d: 'M3 13h3l2-6 3 10 2.5-8 1.5 4h6' },
    { d: 'M3 5V3h3M21 5V3h-3M3 19v2h3M21 19v2h-3', soft: true },
  ],
  // Glitched crystal — the shard's lower half is displaced along a static line.
  anomaly_shard: [
    { d: 'M10 2l4.5 1.5 1.5 5-3 2.5-5-2 2-7Z' },
    { d: 'M8 13.5l5 2 1.5 6.5-4.5-1.5-3-4.5 1-2.5Z' },
    { d: 'M4 11.5h5M15.5 11.5H20', soft: true },
  ],
  // Folded cloth — three stacked folds, the middle bolt recessed.
  textiles: [
    { d: 'M4 9a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2v1.5H4V9Z' },
    { d: 'M4 12.5h16V15H4v-2.5Z', soft: true },
    { d: 'M4 17h16v.5a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V17Z' },
  ],
  // Crate + leaf — a supply crate with a fresh sprig above it.
  provisions: [
    { d: 'M4 9.5h16V20H4V9.5Z' },
    { d: 'M12 9.5V20M4 14.75h16', soft: true },
    { d: 'M12 8c0-3.5 2.5-5.5 6-5.5C18 6 15.5 8 12 8Z' },
  ],
  // Erlenmeyer flask — tank chemistry: mouth, body, liquid line with a bubble.
  reagents: [
    { d: 'M10 3v5.5L4.6 18a2 2 0 0 0 1.8 3h11.2a2 2 0 0 0 1.8-3L14 8.5V3' },
    { d: 'M8.5 3h7' },
    { d: 'M7.2 14.5h9.6M11 17.5h.01M13.5 16h.01', soft: true },
  ],
  // Gearbox — a toothed gear with hub.
  machinery: [
    { d: 'M12 7.2a4.8 4.8 0 1 1 0 9.6 4.8 4.8 0 0 1 0-9.6Z' },
    {
      d: 'M12 4v2.2M12 17.8V20M4 12h2.2M17.8 12H20M6.34 6.34 7.9 7.9M16.1 16.1l1.56 1.56M17.66 6.34 16.1 7.9M7.9 16.1l-1.56 1.56',
    },
    { d: 'M12 10.6a1.4 1.4 0 1 1 0 2.8 1.4 1.4 0 0 1 0-2.8Z', soft: true },
  ],
  // Cut gemstone — crown, girdle line, pavilion facets.
  luxury_goods: [
    { d: 'M8 5h8l4 5-8 10L4 10l4-5Z' },
    { d: 'M4 10h16M12 20 9 10l3-5 3 5-3 10', soft: true },
  ],
  // Ingot stack — two below, one bridging above (trapezoid cross-sections).
  metal: [
    { d: 'M9 5.5h6l1.5 5h-9l1.5-5Z' },
    { d: 'M4.5 13.5h6l1.5 5H3l1.5-5Z' },
    { d: 'M13.5 13.5h6l1.5 5h-9l1.5-5Z' },
  ],
  // Power bolt.
  energy: [{ d: 'M13 2 5 13.5h5.5L9 22l9.5-11.5h-5.5L13 2Z' }],
  // Gun turret — armored dome on a deck line, twin parallel barrels raised skyward.
  autocannon_battery: [
    { d: 'M5.5 17a6.5 6.5 0 0 1 13 0v1.5h-13V17Z' },
    { d: 'M9 11.5l4-8M13.5 11.5l4-8' },
    { d: 'M3 21h18', soft: true },
  ],
  // Mk-II autocannon — the SAME turret silhouette (dome + twin raised barrels + deck), stamped with a
  // small "II" on the dome so it reads as the upgraded battery (0202 mod2-2).
  autocannon_battery_mk2: [
    { d: 'M5.5 17a6.5 6.5 0 0 1 13 0v1.5h-13V17Z' },
    { d: 'M9 11.5l4-8M13.5 11.5l4-8' },
    { d: 'M11 16v-2.2M13 16v-2.2', soft: true },
    { d: 'M3 21h18', soft: true },
  ],
  // Expansion lattice — a reinforced 3×3 structural grid in its frame.
  expanded_cargo_lattice: [
    { d: 'M4.5 4.5h15v15h-15v-15Z' },
    { d: 'M4.5 9.5h15M4.5 14.5h15M9.5 4.5v15M14.5 4.5v15', soft: true },
  ],
  // Thruster bell — nozzle cone over an exhaust plume.
  vector_thruster_kit: [
    { d: 'M9.5 3h5l3.5 8.5c-2 1.7-4 2.5-6 2.5s-4-.8-6-2.5L9.5 3Z' },
    { d: 'M9 17.5c.6 1.5 1.6 2.8 3 4 1.4-1.2 2.4-2.5 3-4' },
    { d: 'M8 7.5h8M12 16.5V19', soft: true },
  ],
  // Layered shield lattice — a shield outline around a central hex node with lattice spokes.
  shield_lattice: [
    { d: 'M12 3l7 2.5v5c0 4.5-2.8 8-7 10.5C7.8 18.5 5 15 5 10.5v-5L12 3Z' },
    { d: 'M12 8l2.6 1.5v3L12 14l-2.6-1.5v-3L12 8Z' },
    { d: 'M12 8V5.5M12 14v3M9.4 9.5 7 8.2M14.6 9.5 17 8.2M9.4 12.5l-2.2 1.3M14.6 12.5l2.2 1.3', soft: true },
  ],
  // Mk-II shield lattice — the SAME shield + hex-node + spokes silhouette, but the lower spoke is
  // replaced by a small "II" beneath the node so it reads as the reinforced upgrade (0202 mod2-2).
  shield_lattice_mk2: [
    { d: 'M12 3l7 2.5v5c0 4.5-2.8 8-7 10.5C7.8 18.5 5 15 5 10.5v-5L12 3Z' },
    { d: 'M12 8l2.6 1.5v3L12 14l-2.6-1.5v-3L12 8Z' },
    { d: 'M12 8V5.5M9.4 9.5 7 8.2M14.6 9.5 17 8.2M9.4 12.5l-2.2 1.3M14.6 12.5l2.2 1.3', soft: true },
    { d: 'M11 18.4v-2.6M13 18.4v-2.6', soft: true },
  ],
  // Mining rig arm — mast + boom + cable over a drill cone, chips on the ground line.
  mining_rig_extension: [
    { d: 'M6 20V5h5l4 3v4' },
    { d: 'M12.5 12h5L15 18.5 12.5 12Z' },
    { d: 'M3 20.5h9M18 20.5h3M15.5 20.5h.01', soft: true },
  ],
  // Sensor dish — a parabolic quarter-dish, feed arm to the focal point, signal arc.
  deep_scan_sensor_array: [
    { d: 'M5 5a10 10 0 0 0 14 14L5 5Z' },
    { d: 'M12 12l5.5-5.5M17.5 6.5h.01' },
    { d: 'M16.5 2.5a5 5 0 0 1 5 5', soft: true },
  ],
  // Honest generic container — a sealed hex canister with an id plate dot. Used ONLY for ids no
  // catalog knows; deliberately unlike any real subject so a fallback is visibly a fallback.
  unknown: [
    { d: 'M12 3l7 4v10l-7 4-7-4V7l7-4Z' },
    { d: 'M12 11.5h.01M12 14.5h.01', soft: true },
  ],
} satisfies Record<string, readonly GlyphPath[]>

// ── the per-namespace subject tables (label + category + glyph, straight from the seeds) ────────

interface Subject {
  label: string
  category: ItemCategory
  glyph: readonly GlyphPath[]
}

const ITEM_SUBJECTS: Record<string, Subject> = {
  scrap: { label: 'Scrap', category: 'material', glyph: GLYPHS.scrap },
  ore: { label: 'Ore', category: 'material', glyph: GLYPHS.ore },
  crystal: { label: 'Crystal', category: 'material', glyph: GLYPHS.crystal },
  pirate_alloy: { label: 'Pirate Alloy', category: 'material', glyph: GLYPHS.pirate_alloy },
  weapon_parts: { label: 'Weapon Parts', category: 'component', glyph: GLYPHS.weapon_parts },
  engine_parts: { label: 'Engine Parts', category: 'component', glyph: GLYPHS.engine_parts },
  repair_parts: { label: 'Repair Parts', category: 'component', glyph: GLYPHS.repair_parts },
  captain_memory_shard: {
    label: 'Captain Memory Shard',
    category: 'progression',
    glyph: GLYPHS.captain_memory_shard,
  },
  blueprint_fragment: {
    label: 'Blueprint Fragment',
    category: 'progression',
    glyph: GLYPHS.blueprint_fragment,
  },
  artifact_core: { label: 'Artifact Core', category: 'progression', glyph: GLYPHS.artifact_core },
  scan_data: { label: 'Scan Data', category: 'data', glyph: GLYPHS.scan_data },
  anomaly_shard: { label: 'Anomaly Shard', category: 'material', glyph: GLYPHS.anomaly_shard },
}

const GOOD_SUBJECTS: Record<string, Subject> = {
  textiles: { label: 'Textiles', category: 'good', glyph: GLYPHS.textiles },
  ore: { label: 'Raw Ore', category: 'good', glyph: GLYPHS.ore }, // 0073's name; same rock glyph
  provisions: { label: 'Provisions', category: 'good', glyph: GLYPHS.provisions },
  reagents: { label: 'Reagents', category: 'good', glyph: GLYPHS.reagents },
  machinery: { label: 'Machinery', category: 'good', glyph: GLYPHS.machinery },
  luxury_goods: { label: 'Luxury Goods', category: 'good', glyph: GLYPHS.luxury_goods },
}

const MODULE_SUBJECTS: Record<string, Subject> = {
  autocannon_battery: {
    label: 'Autocannon Battery',
    category: 'module',
    glyph: GLYPHS.autocannon_battery,
  },
  vector_thruster_kit: {
    label: 'Vector Thruster Kit',
    category: 'module',
    glyph: GLYPHS.vector_thruster_kit,
  },
  expanded_cargo_lattice: {
    label: 'Expanded Cargo Lattice',
    category: 'module',
    glyph: GLYPHS.expanded_cargo_lattice,
  },
  deep_scan_sensor_array: {
    label: 'Deep-Scan Sensor Array', // 0107's exact display name (hyphenated)
    category: 'module',
    glyph: GLYPHS.deep_scan_sensor_array,
  },
  shield_lattice: {
    label: 'Shield Lattice', // 0183 mod2 seed
    category: 'module',
    glyph: GLYPHS.shield_lattice,
  },
  mining_rig_extension: {
    label: 'Mining Rig Extension', // 0183 mod2 seed
    category: 'module',
    glyph: GLYPHS.mining_rig_extension,
  },
  autocannon_battery_mk2: {
    label: 'Autocannon Battery Mk-II', // 0202 mod2-2 — the upgraded autocannon
    category: 'module',
    glyph: GLYPHS.autocannon_battery_mk2,
  },
  shield_lattice_mk2: {
    label: 'Shield Lattice Mk-II', // 0202 mod2-2 — the reinforced shield lattice
    category: 'module',
    glyph: GLYPHS.shield_lattice_mk2,
  },
}

const RESOURCE_SUBJECTS: Record<string, Subject> = {
  metal: { label: 'Metal', category: 'resource', glyph: GLYPHS.metal },
  energy: { label: 'Energy', category: 'resource', glyph: GLYPHS.energy },
}

// Resolution: the caller's preferred namespace first (when given), then the rest in a stable
// item → good → module → resource order (matches how surfaces encounter ids today).
const NAMESPACES: Record<ItemKind, Record<string, Subject>> = {
  item: ITEM_SUBJECTS,
  good: GOOD_SUBJECTS,
  module: MODULE_SUBJECTS,
  resource: RESOURCE_SUBJECTS,
}
const DEFAULT_ORDER: readonly ItemKind[] = ['item', 'good', 'module', 'resource']

function resolveSubject(id: string, kind?: ItemKind): Subject | null {
  if (kind && NAMESPACES[kind][id]) return NAMESPACES[kind][id]
  for (const ns of DEFAULT_ORDER) {
    if (ns !== kind && NAMESPACES[ns][id]) return NAMESPACES[ns][id]
  }
  return null
}

// ── the public contract ─────────────────────────────────────────────────────────────────────────

export interface ItemVisual {
  paths: readonly GlyphPath[]
  category: ItemCategory
  /** false = the honest fallback path (generic glyph + kind-or-unknown tone). */
  known: boolean
}

// An unknown id in a STATED namespace honestly wears that namespace's tone (the surface knows
// what family it is rendering); with no kind stated it stays the neutral 'unknown'.
const KIND_FALLBACK_CATEGORY: Record<ItemKind, ItemCategory> = {
  item: 'unknown',
  good: 'good',
  module: 'module',
  resource: 'resource',
}

/** id → glyph + category. Total: EVERY string resolves (catalog hit or the generic fallback). */
export function getItemGlyph(id: string, kind?: ItemKind): ItemVisual {
  const subject = resolveSubject(id, kind)
  if (subject) return { paths: subject.glyph, category: subject.category, known: true }
  return {
    paths: GLYPHS.unknown,
    category: kind ? KIND_FALLBACK_CATEGORY[kind] : 'unknown',
    known: false,
  }
}

/** Humanized title-case for ids outside the catalogs ('warp_coil' → 'Warp Coil'). */
export function titleCaseId(id: string): string {
  return id
    .split(/[_\s]+/)
    .filter(Boolean)
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(' ')
}

/** id → display name. Catalog names first ('pirate_alloy' → 'Pirate Alloy', ('ore','good') →
 *  'Raw Ore'), honest title-case fallback for unknown ids. Total — never throws. */
export function itemLabel(id: string, kind?: ItemKind): string {
  return resolveSubject(id, kind)?.label ?? titleCaseId(id)
}

/** Category → token utility classes (NEVER raw colors): `text` for inline glyphs/chips, `tile`
 *  for the tinted rounded square behind a tile glyph. Materials read muted (bulk), parts/data/
 *  modules take the accent (tech), progression takes warning (rare), goods take success (trade). */
export const CATEGORY_TONE: Record<ItemCategory, { text: string; tile: string }> = {
  material: { text: 'text-ink-muted', tile: 'bg-surface-2 text-ink-muted' },
  component: { text: 'text-accent', tile: 'bg-accent-soft text-accent' },
  data: { text: 'text-accent', tile: 'bg-accent-soft text-accent' },
  progression: { text: 'text-warning', tile: 'bg-warning-soft text-warning' },
  good: { text: 'text-success', tile: 'bg-success-soft text-success' },
  module: { text: 'text-accent', tile: 'bg-accent-soft text-accent' },
  resource: { text: 'text-ink-muted', tile: 'bg-surface-2 text-ink-muted' },
  unknown: { text: 'text-ink-faint', tile: 'bg-surface-2 text-ink-faint' },
}
