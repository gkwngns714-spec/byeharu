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
import { teamDestinationKind } from '../command/teamDestination'
import { A_ZONE_IS_NOT_A_HUNT, HOW_A_FIGHT_STARTS, huntSiteActionLabel } from '../command/howAFightStarts'

export interface ZoneInfoRow {
  label: string
  value: string
}

/** The site inside this zone that a fleet can actually be sent to fight at. */
export interface ZoneHuntSite {
  locationId: string
  name: string
  /** The signpost's words, from the ONE hunt-copy authority. */
  label: string
}

export interface ZoneInfo {
  id: string
  /** The zone's own name, or a plain fallback — never an id shown to a player. */
  title: string
  /** One sentence: what happens to you here. This is the whole reason the panel exists. */
  warning: string
  /**
   * THE SIGNPOST (owner, 2026-08-03: "i went to snare, zone, no fighting happens").
   *
   * Non-null ⇔ this zone is wrapped around a location the player can legally HUNT at, so the panel
   * can offer the one step that turns "what is this place" into a fight. Null whenever that cannot
   * be PROVEN — no attached location, a location this client has not loaded, or a location that is
   * not a hunt destination — because an offer that leads nowhere is worse than no offer.
   *
   * It carries no action of its own: the panel hands the location id back to the map, which selects
   * it exactly as tapping its marker would, and the EXISTING FleetCommandPanel hunt section renders.
   * One hunt control, reached from one more place — never a second path to send_ship_group_hunt.
   */
  huntSite: ZoneHuntSite | null
  rows: ZoneInfoRow[]
}

/** Fallback title for a zone the server sent with a blank name (authoring can leave it empty). */
const UNNAMED = 'Unnamed danger zone'

/**
 * THE ONE ANSWER to "does this zone wrap a site a fleet can actually be sent to fight at?"
 *
 * WHY IT IS ITS OWN FUNCTION (owner, 2026-08-04, second report: "i am in combat zone, and the fight
 * does not start"): the offer now has to be made in TWO places — the zone panel a player reaches by
 * asking "what is this place", and the fleet command panel for a fleet already PARKED inside the
 * blob (fleetCommandModel's standing-hunt section). Two places asking the same question is exactly
 * how the site/zone copy became three different answers in the first place. So the predicate is
 * extracted rather than repeated: `buildZoneInfo` composes it, the command model composes it, and a
 * change to what counts as huntable lands in both surfaces at once. tests/zoneInfoModel.spec.ts pins
 * that the two agree on every case.
 *
 * `teamDestinationKind` is the SAME classifier the map uses to decide whether selecting a marker
 * opens the hunt section — asked here rather than re-tested, so no surface can offer a hunt the
 * command surface would then refuse to render. 'expedition' (a port) and null (not a legal
 * destination, e.g. an inactive site) both yield no offer: only a real hunt site earns one.
 *
 * Fails closed: no attached location, or a location this client has not loaded, is NO offer — an
 * offer that leads nowhere is worse than no offer.
 */
export function zoneHuntSite(
  zone: DangerZoneLite,
  locations: readonly MapLocation[],
): ZoneHuntSite | null {
  const near = zone.location_id ? locations.find((l) => l.id === zone.location_id) : undefined
  return near && teamDestinationKind(near) === 'hunt'
    ? { locationId: near.id, name: near.name, label: huntSiteActionLabel(near.name) }
    : null
}

/**
 * WHY THE WARNING IS NOT A PERCENTAGE: the risk is computed per crossing from exposure and fleet
 * strength, and the client cannot read it — printing a number would be inventing precision.
 *
 * WHY IT NO LONGER SAYS "ALMOST ALWAYS" (2026-08-03): that wording was written against 0236's
 * [0.98, 1.0] pin, which production has long since left — `pirate_intercept_base_risk` is 1 with
 * `min_risk` 0.02, `exposure_floor` 0.15 and `stat_reference` 120, so a strong fleet on a shallow
 * crossing rolls low. The owner's last two crossings of the Snare rolled risk 0.545 and 0.240 and
 * BOTH missed. Told "almost always attacked" and then attacked never, a player concludes the game
 * is broken — which is exactly what happened. The sentence now states the mechanic honestly and,
 * paired with the second one, says plainly that this is not how you pick a fight.
 */
const WARNING = `Pirates raid this zone. ${A_ZONE_IS_NOT_A_HUNT}`

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

  // THE SIGNPOST — composed from the ONE huntable-site authority above, never re-tested here. This
  // panel and the fleet command panel's standing-hunt section must agree by construction.
  const huntSite: ZoneHuntSite | null = zoneHuntSite(zone, locations)
  // Say HOW, right where the confusion happens, but only when there is somewhere to say it about —
  // a loose zone with no site would be handed an instruction it cannot act on.
  const warning = huntSite ? `${WARNING} ${HOW_A_FIGHT_STARTS}` : WARNING

  return {
    id: zone.id,
    title: zone.name?.trim() ? zone.name.trim() : UNNAMED,
    warning,
    huntSite,
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
