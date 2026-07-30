// ZONE INFO — the pure model behind "click a danger zone, see what it is".
//
// THE ASK (owner, 2026-07-29): "when i put my mouse over a zone in a game, i want to be able to
// click it, and see the info." Zones were scenery: dangerZoneLayer drew them with
// pointerEvents:'none' and nothing else in the client could name one.
//
// WHY A PURE MODEL AND NOT COPY INSIDE THE PANEL: the map's own convention (fleetCommandModel,
// teamStop, markerStyle) is that what to say is decided by a hook-free function a unit test can
// call, and the component only renders it. That keeps the wording assertable and stops a second
// version of it appearing the next time a zone surface is added.
//
// EVERY FIELD COMES FROM DATA THE MAP ALREADY HAS — get_danger_zones (0287) returns id/name/source/
// location_id/revision/provenance/ring, and the locations list is already loaded for the markers.
// No new RPC, no new fetch, nothing to keep in sync.
//
// LANGUAGE RULES (the play-test feedback): plain words, no insider jargon, few of them. A player
// does not know what "source: drawn", "provenance", or "revision" mean, so none of them are shown —
// they are authoring metadata, not player information.
import type { DangerZoneLite } from './pirateApi'
import type { MapLocation } from './mapTypes'
import { polygonArea } from '../worldeditor/zoneGeometryMath'
import { pointInRing } from './routeGeometry'

export interface ZoneInfoRow {
  label: string
  value: string
}

export interface ZoneInfo {
  id: string
  /** The zone's own name, or a plain fallback — never an id shown to a player. */
  title: string
  /** One sentence: what happens to you here. This is the whole reason the panel exists. */
  warning: string
  rows: ZoneInfoRow[]
}

/** Fallback title for a zone the server sent with a blank name (authoring can leave it empty). */
const UNNAMED = 'Unnamed danger zone'

/**
 * WHY THE WARNING IS NOT A PERCENTAGE: 0236 set the intercept risk to [0.98, 1.0] regardless of
 * fleet strength, by explicit owner directive — but that is live config, and printing a number the
 * client cannot read would be inventing precision. "Almost always" is what the design guarantees
 * and what a player can act on.
 */
const WARNING = 'Pirates hunt here. A fleet crossing this zone is almost always attacked.'

/** Rounded to whole world units — a player is judging "can I go around it?", not surveying. */
function describeSize(ring: readonly (readonly [number, number])[] | null): string | null {
  if (!ring || ring.length < 3) return null
  // get_danger_zones returns an ALREADY-CLOSED ring (first point repeats last). polygonArea walks
  // i -> i+1 mod n and closes the ring itself, so the duplicate would contribute a zero-length edge:
  // harmless for area, but dropped anyway so the vertex count in this file means what it says.
  const first = ring[0]
  const last = ring[ring.length - 1]
  const closed = first[0] === last[0] && first[1] === last[1]
  const pts = (closed ? ring.slice(0, -1) : ring).map(([x, y]) => ({ x, y }))
  if (pts.length < 3) return null
  const area = polygonArea(pts)
  if (!(area > 0)) return null
  // Diameter of the circle with the same area — one number instead of a bounding box, and it does
  // not overstate a long thin zone the way a max-dimension would.
  const across = 2 * Math.sqrt(area / Math.PI)
  return `About ${Math.max(1, Math.round(across))} across`
}

/**
 * Build the player-facing description of one danger zone.
 * Pure: same inputs -> same output, no clock, no I/O.
 */
export function buildZoneInfo(
  zone: DangerZoneLite,
  locations: readonly MapLocation[],
): ZoneInfo {
  const rows: ZoneInfoRow[] = []

  // WHERE IT IS. A zone bound to a location is the interesting case ("the danger around Reaver");
  // an unbound one is loose space and says so rather than showing a blank row. Fail closed on a
  // location_id the caller cannot resolve: say nothing rather than guess a name.
  const near = zone.location_id ? locations.find((l) => l.id === zone.location_id) : undefined
  rows.push({ label: 'Where', value: near ? `Around ${near.name}` : 'Open space' })

  const size = describeSize(zone.ring)
  if (size) rows.push({ label: 'Size', value: size })

  return {
    id: zone.id,
    title: zone.name?.trim() ? zone.name.trim() : UNNAMED,
    warning: WARNING,
    rows,
  }
}

/**
 * WHICH ZONE (if any) CONTAINS a world point — the decision behind offering "What's here" on the
 * command hub's icon menu after a double-tap.
 *
 * This is the whole gesture for zone info now. The blob used to own a click, which took the map's
 * double-tap across the entire zone and made a point inside a zone unreachable as a fleet destination
 * (owner, 2026-07-30: "i can't send a fleet to zone since it is pressed and info is shown"). Asking
 * "what is under the point the player double-tapped" composes onto the hub the map already has,
 * instead of a second gesture competing with it.
 *
 * Containment is `routeGeometry.pointInRing` — the map's EXISTING ray-cast, already the client-side
 * mirror of the server's PostGIS zone test used for the route-crossing warning. Deliberately not a
 * second formula: the zone a player is told they are standing in is the same zone the route planner
 * flashes red. Zones overlap rarely; the first containing zone in list order wins, which is the same
 * order the layer paints them in, so the answer matches what the player sees on top.
 *
 * Fails closed: a non-finite point or a degenerate ring contains nothing.
 */
export function zoneAtPoint(
  point: { x: number; y: number } | null,
  zones: readonly DangerZoneLite[],
): DangerZoneLite | null {
  if (!point) return null
  return (
    zones.find((z) => z.ring && z.ring.length >= 3 && pointInRing(point, z.ring.map(([x, y]) => ({ x, y })))) ?? null
  )
}
