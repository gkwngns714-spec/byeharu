// COMBAT-S4 — the SPATIAL-COMBAT map layer: renders an active on-map battle (COMBAT-S3 / migration
// 0234's server core) so the player SEES it. Follows the territoryLayer / miningFieldRangeLayer /
// teamMarkersLayer element-helper convention: PURE, hook-free, returns element descriptors, so
// GalaxyMap and the unit test call the SAME function. Mounted ABOVE the location markers (the units
// are the focus of the frame) and every element is pointer-transparent (a battle is a spectacle, not
// a tap surface — the location marker under it stays the tap target).
//
// ── FAIL-CLOSED BY DATA (the flag is never read here) ────────────────────────────────────────────────
// A unit is "spatial" iff it carries a non-NULL pos_x/pos_y. While spatial_combat_enabled is dark (its
// prod state) NO combat_units row is ever written with a position (0234's creator resets the columns to
// NULL every iteration and only computes them when lit), so `units` filtered to spatial rows is ALWAYS
// empty in a dark world and this layer renders NOTHING — zero visible surface, byte-identical to a map
// without it. This is the SAME "data-gated, not flag-gated" posture as the danger-zone / telegraph
// layers: the client reads no game_config flag; the absence of positioned rows IS the gate.
//
// ── COORDINATE TRUTH ─────────────────────────────────────────────────────────────────────────────────
// A spatial unit's pos_x/pos_y live in the SAME fixed WORLD domain as locations.x/y (0234 seeds the
// command ship at the location centre and displaces escorts / enemies in world units), so positions
// project through the map's ONE `norm` = worldToViewBox, exactly like every marker; the weapon RANGE is
// a real world-unit distance, so its ring radius is `range * WORLD_TO_VIEWBOX_SCALE` viewBox units and
// grows/shrinks with zoom (world-true — the SAME idiom as territory / mining rings). Only stroke width
// and glyph size divide by `k` (line weight / glyph are presentation, pinned to a screen size).
//
// ── WHAT ANIMATES, AND HOW ───────────────────────────────────────────────────────────────────────────
// This layer holds no clock. It re-renders whenever `units` / `events` change, and useCombat (mounted
// once in AppShell, exposed via useShellState) re-polls both every ~1.5s — the combat tick cadence. So:
//   • enemy pirates spawn at the location centre and CLOSE toward the fleet → their pos_x/pos_y update
//     each tick → the dots visibly march inward each poll (the "spawn from centre → approach" beat).
//   • kiting player ships back away to their range edge → their dots slide out each tick.
//   • a weapon that fired THIS tick emits a combat_event (missile_salvo, payload {unit_id,target_id})
//     → a fire line is drawn source→target for the latest tick's shots, fading with the next poll.
import { createElement, type ReactElement } from 'react'
import type { CombatEvent, CombatUnit } from '../combat/combatTypes'
import { WORLD_TO_VIEWBOX_SCALE } from './openSpaceTransform'

/** The minimal spatial view of a combat unit — the subset the layer projects. Any CombatUnit with a
 *  position satisfies it. Kept explicit so the pure resolver + spec don't depend on the full row. */
export interface SpatialUnitView {
  id: string
  side: 'player' | 'enemy'
  x: number
  y: number
  /** max weapon range in world units, or null when the unit carries no ranged weapon (→ no ring). */
  range: number | null
  /** 0..1 health fraction (hp_current / hp_max) — dims a battered unit's glyph. 1 when unknown. */
  hpFrac: number
}

/** The unit's range ring radius = the MAX `range` across its frozen weapons_json (world units). A unit
 *  with no ranged weapon (empty/rangeless array) returns null → a dot with no ring (honest: it can't
 *  reach out). Pure. */
export function unitWeaponRange(u: Pick<CombatUnit, 'weapons_json'>): number | null {
  let max: number | null = null
  for (const w of u.weapons_json ?? []) {
    const r = w?.range
    if (typeof r === 'number' && Number.isFinite(r) && r > 0) max = max === null ? r : Math.max(max, r)
  }
  return max
}

/** PURE: combat_units → the spatial views the layer draws. Keeps ONLY rows that are (a) positioned
 *  (non-NULL finite pos_x/pos_y — the fail-closed gate) and (b) still alive (alive_count > 0, so a
 *  destroyed unit vanishes). Order is stable by id so the element tree is deterministic across polls. */
export function resolveSpatialUnits(units: readonly CombatUnit[]): SpatialUnitView[] {
  const out: SpatialUnitView[] = []
  for (const u of units) {
    if (u.pos_x == null || u.pos_y == null) continue // not spatial → dark fail-closed
    if (!Number.isFinite(u.pos_x) || !Number.isFinite(u.pos_y)) continue
    if (u.alive_count <= 0) continue // destroyed → no glyph
    const hpFrac = u.hp_max > 0 ? Math.max(0, Math.min(1, u.hp_current / u.hp_max)) : 1
    out.push({
      id: u.id,
      side: u.side === 'enemy' ? 'enemy' : 'player',
      x: u.pos_x,
      y: u.pos_y,
      range: unitWeaponRange(u),
      hpFrac,
    })
  }
  return out.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
}

/** A fire line to draw this tick: source→target world segment + the firing side (for tone). */
export interface FireLineView {
  key: string
  sourceSide: 'player' | 'enemy'
  x1: number
  y1: number
  x2: number
  y2: number
}

/** PURE: combat_events + the current unit positions → the fire lines for the LATEST tick only. A
 *  spatial fire event is a 'missile_salvo' whose payload carries {unit_id, target_id} (0234's spatial
 *  fire hunk); the aggregate-combat missile_salvo (dark path) has no unit_id, so it is naturally
 *  ignored. Both endpoints must resolve to a live positioned unit — a shot at an already-vanished
 *  target draws nothing (never a guessed line). Only the highest tick_number present is drawn, so old
 *  salvos fade as the poll advances. */
export function resolveFireLines(
  events: readonly CombatEvent[],
  units: readonly SpatialUnitView[],
): FireLineView[] {
  const posById = new Map(units.map((u) => [u.id, u]))
  let latestTick = -Infinity
  for (const e of events) {
    if (e.event_type === 'missile_salvo' && e.payload_json && e.payload_json['unit_id'] != null) {
      if (e.tick_number > latestTick) latestTick = e.tick_number
    }
  }
  if (!Number.isFinite(latestTick)) return []
  const out: FireLineView[] = []
  for (const e of events) {
    if (e.event_type !== 'missile_salvo' || e.tick_number !== latestTick) continue
    const p = e.payload_json ?? {}
    const src = posById.get(String(p['unit_id'] ?? ''))
    const tgt = posById.get(String(p['target_id'] ?? ''))
    if (!src || !tgt) continue // one endpoint gone → no line
    out.push({ key: `${e.id}`, sourceSide: src.side, x1: src.x, y1: src.y, x2: tgt.x, y2: tgt.y })
  }
  return out
}

const SIDE_COLOR = { player: 'var(--color-accent)', enemy: 'var(--color-danger)' } as const

/** The pure, hook-free GalaxyMap spatial-combat layer (the element-helper convention). Returns element
 *  DESCRIPTORS only — no hooks — so the unit spec calls this SAME function and inspects the tree. No
 *  spatial units → [] (the map is byte-identical to today; dark by data). Order: range rings first
 *  (scenery), then fire lines, then unit glyphs on top. */
export function spatialCombatLayer(args: {
  units: readonly CombatUnit[]
  events: readonly CombatEvent[]
  norm: (p: { x: number; y: number }) => { x: number; y: number }
  k: number
}): ReactElement[] {
  const views = resolveSpatialUnits(args.units)
  if (views.length === 0) return [] // dark / no active spatial battle → nothing

  const out: ReactElement[] = []

  // ── 1) Weapon RANGE rings (world-true, faint, under the glyphs) ──
  for (const u of views) {
    if (u.range == null) continue // no ranged weapon → no ring
    const p = args.norm({ x: u.x, y: u.y })
    const ringR = u.range * WORLD_TO_VIEWBOX_SCALE // world-true: viewBox units, NOT /k
    const color = SIDE_COLOR[u.side]
    out.push(
      createElement('circle', {
        key: `spatial-range-${u.id}`,
        'data-testid': `spatial-combat-range-${u.id}`,
        cx: p.x,
        cy: p.y,
        r: ringR,
        fill: 'none',
        stroke: color,
        strokeOpacity: 0.35,
        strokeWidth: 1 / args.k,
        strokeDasharray: `${3 / args.k} ${3 / args.k}`,
        style: { pointerEvents: 'none' as const },
      }),
    )
  }

  // ── 2) FIRE lines (source→target, this tick's salvos), over rings, under glyphs ──
  const lines = resolveFireLines(args.events, views)
  if (lines.length > 0) {
    out.push(
      createElement(
        'g',
        { key: 'spatial-fire', 'data-testid': 'spatial-combat-fire', style: { pointerEvents: 'none' as const } },
        ...lines.map((l) => {
          const a = args.norm({ x: l.x1, y: l.y1 })
          const b = args.norm({ x: l.x2, y: l.y2 })
          return createElement('line', {
            key: l.key,
            x1: a.x,
            y1: a.y,
            x2: b.x,
            y2: b.y,
            stroke: SIDE_COLOR[l.sourceSide],
            strokeWidth: 1.25,
            strokeOpacity: 0.9,
            strokeLinecap: 'round' as const,
            vectorEffect: 'non-scaling-stroke' as const,
          })
        }),
      ),
    )
  }

  // ── 3) Unit GLYPHS on top: player = accent chevron, enemy = danger triangle (screen-constant /k) ──
  for (const u of views) {
    const p = args.norm({ x: u.x, y: u.y })
    const r = 4 / args.k
    const color = SIDE_COLOR[u.side]
    // Enemy pirates point DOWN (inbound from centre); player ships point UP — a distinct silhouette at
    // a glance, not just a hue. Health dims the fill (a battered unit reads as failing).
    const points =
      u.side === 'enemy'
        ? `${p.x},${p.y + r} ${p.x + r},${p.y - r} ${p.x - r},${p.y - r}` // down-pointing triangle
        : `${p.x},${p.y - r} ${p.x + r},${p.y + r} ${p.x - r},${p.y + r}` // up-pointing triangle
    out.push(
      createElement(
        'g',
        {
          key: `spatial-unit-${u.id}`,
          'data-testid': `spatial-combat-unit-${u.id}`,
          'data-side': u.side,
          style: { pointerEvents: 'none' as const },
        },
        createElement('polygon', {
          points,
          fill: color,
          fillOpacity: 0.35 + 0.55 * u.hpFrac, // battered = fainter
          stroke: color,
          strokeWidth: 1,
          vectorEffect: 'non-scaling-stroke' as const,
        }),
      ),
    )
  }

  return out
}
