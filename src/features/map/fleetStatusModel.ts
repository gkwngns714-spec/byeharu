import type { FleetMovement } from '../fleets/fleetTypes'
import type { GroupRow, ShipGroupMapEntry } from '../command/teamRoster'
import { fleetCommandState } from '../command/teamRoster'
import type { UnifiedGroupFleetLite } from '../command/teamApi'
import type { CombatEncounter, CombatUnit } from '../combat/combatTypes'
import { liveEncounterForFleet } from '../combat/encounterAnchor'
import { selectCombatPhase } from '../combat/combatPhase'
import { resolveRepositionCourse } from '../combat/repositionCourse'
import { resolveStoppableFleets } from '../command/teamStop'
import { formatDuration } from '../../lib/time'
import type { MapLocation } from './mapTypes'
import type { DangerZoneLite } from './pirateApi'
import { resolveFleetPresence, fleetWhereText, type FleetPresenceState, type PositionRow } from './fleetPresence'
import { resolveFleetStandingHunts } from './fleetStandingHunt'
import { fireRateText, resolveFightingFleetStats, trim } from './fightingFleetStats'

// ██ MY FLEETS, ON THE MAP — where each one is, what it is doing, and why it cannot fight. ██
//
// ── THE REQUEST (owner, 2026-08-04, playing) ───────────────────────────────────────────────────────
// "in map, i want to see information regarding fleet, where it is, stats, what it is currently
//  doing. I am in snare but in no fight is occuring, i want also a toggle combat on map as well when
//  i arrive at the combat zone on the fleet information on map"
//
// Three things and a standing complaint. The complaint is the real bug, so it is answered FIRST.
//
// ── WHY NO FIGHT IS HAPPENING ──────────────────────────────────────────────────────────────────────
// A fight starts EXACTLY one way (command/howAFightStarts): `send_ship_group_hunt` on a hunt_pirates
// SITE. Standing in a zone starts nothing, by design. But the likeliest blocker on production today
// is a SILENT REFUSAL: send_ship_group_hunt answers `fleet_inactive_no_command` when no ship in the
// group carries `is_command_ship` — and it answers it BEFORE the destination is even read. Of the 77
// ships live on production, 2 carry the flag (measured in migration 0335's header). So the most
// likely thing standing between the owner and a fight is a flag on a ship, and NOTHING on the map
// said so.
//
// This model therefore carries a `blockedReason` per fleet. Three rules about it:
//   1. It is a SERVER REASON CODE, never prose. The words come from `teamReasonMessage`, the ONE
//      reject-copy map — so the sentence the panel shows before an attempt is the SAME sentence the
//      server's own refusal shows after one. A second vocabulary here would be a client re-invention
//      of the server's rules, which is exactly what is forbidden.
//   2. It is derived ONLY from the two mirrors that already exist and are already proven:
//      `fleetCommandState` (0204's control model) and the member count. Nothing is guessed.
//   3. It stays NULL for everything the client genuinely cannot see. A wrecked ship, a partial dock
//      and a fleet split across ports all come back as one `member_not_ready` and the map shell
//      polls no hp at all, so this model does not pretend to distinguish them — the attempt gets the
//      server's answer, which is the honest place for it.
//
// ── STATS: WHAT IS DELIBERATELY NOT HERE ───────────────────────────────────────────────────────────
// The 2026-08-04 stat audit (docs/STAT_ARCHITECTURE_CONTRACT.md) and the owner's ruling on it:
//   · evasion/retreat_safety, scouting, mining_yield, repair, pirate_attention — computed by the
//     0122 fold and consumed by NO engine. Dormant. "The client must not describe it as effective."
//     A number that changes nothing in the game must not appear on the map, so none is rendered.
//   · the integer `cargo_capacity` is deprecated and non-authoritative — fitting a cargo module
//     raises it and expands no hold, because both real capacity gates read the m³ volume. Canonical
//     cargo is the ship-bound m³ hold. The only FLEET-scope m³ authority is `get_my_hold` (0333) and
//     the map shell does not poll it; summing the per-ship `cargo_capacity_m3` here would be a
//     client-side fold beside a server authority — the very pattern teamSkillset already regrets.
//     So NO cargo number appears on the map. Sparse is correct.
//   · "power" has six competing definitions and "fleet speed" has nine. This adds no tenth: nothing
//     here is folded, and every number below is either a COUNT of rows the server sent or a value
//     the server itself computed.
// What remains has a real consumer, and each is named where it is built.
//
// ── ██ THE FIGHT STATS ARE THE EXCEPTION, AND HERE IS WHY THEY ARE NOT A TENTH DEFINITION ██ ──────
// Owner: *"the fleets info tab should have info like range, speed, reload time, etc"*. Those three
// exist ONLY while the fleet is in a fight, they are frozen onto `combat_units` by the server at
// spawn, and they are read here through ONE leaf — map/fightingFleetStats — which composes the
// EXISTING range authority (spatialCombatLayer.unitWeaponRange) and states the engine's own
// aggregation rules rather than inventing any:
//   · REACH is `max(range)` over the living hulls, which is exactly what combatActors already calls
//     "the FURTHEST this actor can shoot" for the map glyph. A DISPLAY fact; it gates nothing.
//   · SPEED is `min(move_speed)` over the living hulls, because that is the speed 0337's tick walks
//     the fleet at. It is a COMBAT speed in world-units-per-tick and is deliberately NOT the
//     map-travel `speed` stat — a different quantity, a different unit, and it says so on screen.
//   · RELOAD is the ROUND, not `cooldown_seconds`: the engine stamps `next_ready_at := now()` and
//     never adds a cooldown, so every weapon in range fires every tick whatever the column says.
//     Printing the column would be printing a number that changes nothing, which is the very thing
//     the dormant fold stats are refused for above.
// None of the three is a registry stat and none may become one — STAT_ARCHITECTURE_CONTRACT §11.3.
//
// ── WHAT IT IS DOING: COMPOSED, NEVER A SECOND VOCABULARY ──────────────────────────────────────────
//   · the state + the place  → map/fleetPresence (the ONE "where is my fleet" answer, whose `place`
//     domain is exhaustive and spec-iterated) and its `fleetWhereText`.
//   · a fight's phase        → combat/combatPhase.selectCombatPhase — the SAME 'In combat' /
//     'Retreating' / 'Next wave incoming' label the mission panel and the map's combat card print.
//   · a fight that is moving → combat/repositionCourse, read as a PREDICATE only. Its sentence is
//     already on this screen, on CombatMapCard; printing it again three inches away would be the
//     duplication this file exists to avoid. So the row says the fleet is moving and lets the card
//     say how far. (Not even the wording is quoted here — tests/repositionOnMap.spec.ts holds this
//     module to one producer of that sentence in all of src/, comments included.)
//   · an ETA                 → command/teamStop.resolveStoppableFleets, the ONE lead-arrival rule
//     (earliest arrive_at, tie-broken on movement id) the Stop rows and the map badge already share,
//     formatted by lib/time.formatDuration.
//   · a fight to pick up     → map/fleetStandingHunt, the ONE containment+huntability answer, shared
//     with the command panel's own signpost.
// The fight's NUMBERS — hull bars, the last exchange, the auto-retreat line — are deliberately NOT
// restated here. CombatMapCard owns them, on this same screen, from these same rows.
//
// PURE. No React, no DOM, no fetch, no clock (`nowMs` is passed in).

/** One labelled stat. Kept as strings: the model decides WHAT is honest to show, the panel decides
 *  nothing. A stat only exists here if something in the game actually reads it. */
export interface FleetStatusStat {
  label: string
  value: string
}

/**
 * The ONE action the fleet readout offers, and there is at most one — the owner asked for a "toggle
 * combat", so the same slot either takes the fleet INTO the fight under its feet or OUT of the one
 * it is in.
 *
 * `hunt` submits NOTHING. It hands a location id to the map's own marker selection, exactly as
 * tapping that site's marker would, which renders the EXISTING hunt control with its armed confirm
 * and its return-port picker. There is still exactly ONE call site for the hunt RPC in the client
 * (tests/howAFightStarts.spec.ts proves it), and this is not it.
 *
 * `retreat` names the presence the ONE RetreatControl acts on — the same component the mission panel
 * and the map's combat card already mount. Retreat and auto-exit are owner-preserved design; this
 * adds a way IN to the control, never a way around it.
 */
export type FleetStatusAction =
  | { kind: 'hunt'; locationId: string; siteName: string; label: string }
  | { kind: 'retreat'; encounterId: string; presenceId: string; retreating: boolean }
  | null

export interface FleetStatusRow {
  groupId: string
  /** The fleet's name, from the ONE naming rule (fleetLabel, via the presence). */
  name: string
  state: FleetPresenceState
  /** WHERE IT IS — one plain phrase, from the presence's own state + place. */
  where: string
  /** WHAT IT IS DOING — one plain phrase. Never a second combat vocabulary (see the header). */
  doing: string
  /** ITS STATS — only what something in the game reads (see the header for what is refused). */
  stats: FleetStatusStat[]
  /** A SERVER reason code the client can already prove this fleet will be refused with, or null when
   *  it cannot honestly say. The panel renders it through `teamReasonMessage` — never its own words. */
  blockedReason: string | null
  action: FleetStatusAction
}

export interface FleetStatusModel {
  /** Nothing to say → nothing rendered. A player with no fleets keeps a clean map. */
  rows: FleetStatusRow[]
}

export interface FleetStatusModelInput {
  groups: readonly GroupRow[]
  /** main_ship_id → membership. Carries `is_command_ship`, which is what 0204's control model reads. */
  membership: Readonly<Record<string, ShipGroupMapEntry>>
  /** get_my_fleet_positions — the server's own per-ship place projection. */
  positions: readonly PositionRow[]
  locations: readonly MapLocation[]
  movements: readonly FleetMovement[]
  /** Group fleets (combat-sortie rows excluded upstream) — identity for the fight join, and the
   *  parked coordinate the standing-hunt offer stands on. */
  unifiedFleets: readonly UnifiedGroupFleetLite[]
  dangerZones: readonly DangerZoneLite[]
  encounters: readonly CombatEncounter[]
  units: readonly CombatUnit[]
  /** The RUNTIME fleet_control_enabled flag. Dark → a fleet is never inactive (0204's own posture). */
  fleetControlEnabled: boolean
  /** `game_config.combat_tick_seconds` — how long one combat round lasts. Absent/null is a legal and
   *  honest state: the fire-rate line then states the cadence with no number rather than a plausible
   *  one. Only ever read for a fleet that is actually fighting. */
  combatTickSeconds?: number | null
  nowMs: number
}

export function buildFleetStatusModel(input: FleetStatusModelInput): FleetStatusModel {
  if (input.groups.length === 0) return { rows: [] }

  // WHERE — the ONE answer, unconditional: every group the player owns produces exactly one presence.
  const presences = resolveFleetPresence({
    groups: input.groups,
    membership: input.membership,
    positions: input.positions,
    fleets: input.unifiedFleets,
    locations: input.locations,
    encounters: input.encounters,
    units: input.units,
    nowMs: input.nowMs,
  })

  // The lead ETA per in-flight group — the SAME rule the Stop rows use, so the panel and the brake
  // can never disagree about which leg a fleet is flying.
  const etaByGroup = new Map(resolveStoppableFleets(input.movements, input.groups).map((f) => [f.groupId, f.arriveAt]))
  // The fight under a parked fleet's feet — the ONE derivation, shared with the command panel.
  const huntByGroup = new Map(
    resolveFleetStandingHunts({
      groups: input.groups,
      unifiedFleets: input.unifiedFleets,
      dangerZones: input.dangerZones,
      locations: input.locations,
    }).map((h) => [h.groupId, h]),
  )
  // Which `fleets.id` is this group's — identity only, for the encounter join (fleetPresence's rule:
  // first wins over a broken second live row, never a coin flip).
  const fleetIdByGroup = new Map<string, string>()
  for (const f of input.unifiedFleets) {
    if (!f.group_id || fleetIdByGroup.has(f.group_id)) continue
    fleetIdByGroup.set(f.group_id, f.id)
  }

  const rows = presences.map((p): FleetStatusRow => {
    const members = Object.keys(input.membership).filter((s) => input.membership[s]?.group_id === p.groupId)
    const commandCount = members.filter((s) => input.membership[s]?.is_command_ship).length
    const cmd = fleetCommandState({ commandCount, fleetControlEnabled: input.fleetControlEnabled })
    const encounter = liveEncounterForFleet(input.encounters, fleetIdByGroup.get(p.groupId) ?? null)

    // ── WHAT IT IS DOING ──────────────────────────────────────────────────────────────────────────
    // Exhaustive over the closed presence-state set; each arm composes an existing authority.
    let doing: string
    if (encounter) {
      // The fight's own label, from the shared phase selector. When a reposition is running the row
      // says so — the DISTANCE stays on CombatMapCard, which is the one place that prints it.
      const phase = selectCombatPhase(encounter)
      doing = resolveRepositionCourse(encounter) ? `${phase.label} — moving into position` : phase.label
    } else if (p.state === 'moving') {
      const arriveAt = etaByGroup.get(p.groupId)
      const remainingMs = arriveAt ? Date.parse(arriveAt) - input.nowMs : NaN
      // "Arriving" and not "ETA": the arrival is the thing the player is waiting for. A leg whose
      // clock has run out (or whose row is unreadable) says it is travelling rather than inventing a
      // countdown — the settle is the server's to announce.
      doing =
        Number.isFinite(remainingMs) && remainingMs > 0
          ? `Arriving in ${formatDuration(remainingMs / 1000)}`
          : 'Travelling'
    } else if (p.state === 'in-space') {
      doing = 'Holding position'
    } else if (p.state === 'docked') {
      doing = 'In port'
    } else if (p.state === 'in-combat') {
      // Placed in a fight the client cannot join to an encounter row (fleetPresence reached this
      // state, liveEncounterForFleet did not) — state what is known and claim no phase.
      doing = 'In combat'
    } else {
      doing = 'Nothing reported'
    }

    // ── ITS STATS ─────────────────────────────────────────────────────────────────────────────────
    const stats: FleetStatusStat[] = []
    // SHIPS — a count of rows the server sent, and the partial-placement count beside it. This is the
    // stat that had a real bug behind it: Fleet 1 stood at 1/4 for a week (three members carrying the
    // abolished `legacy_home` state) and the map drew no marker at all. It is a consumer of the
    // server's own place projection, not a fold.
    stats.push({
      label: 'Ships',
      value: p.placedCount < p.memberCount ? `${p.placedCount} of ${p.memberCount}` : `${p.memberCount}`,
    })
    // COMMAND SHIP — the one "stat" with the hardest consumer in the game: with none, every fleet RPC
    // refuses before it reads anything else (fleet_inactive_no_command). Shown only while 0204's gate
    // is lit, because dark the count decides nothing and a number that decides nothing does not
    // belong on the map. When it is ZERO the blocked line below carries it instead of a bare "0".
    if (input.fleetControlEnabled && commandCount > 0) {
      stats.push({ label: 'Command ship', value: `${commandCount}` })
    }
    // ── WHAT IT CAN DO IN THIS FIGHT — reach, rate of fire, speed. See the header for why these
    // three are read off combat_units and not out of the stat registry, and why "reload" is stated
    // as the ROUND. Only while a fight is actually running: off the field these rows do not exist,
    // and a stale copy of them would be a number with no source.
    if (encounter) {
      const fight = resolveFightingFleetStats(input.units, encounter.id, input.combatTickSeconds ?? null)
      if (fight) {
        if (fight.reach !== null) {
          stats.push({ label: 'Reach', value: `${trim(fight.reach)} units` })
        }
        stats.push({ label: 'Fires', value: fireRateText(fight.roundSeconds) })
        if (fight.speed !== null) {
          stats.push({ label: 'Combat speed', value: `${trim(fight.speed)} units/round` })
        }
      }
    }

    // ── WHY IT CANNOT ACT ─────────────────────────────────────────────────────────────────────────
    // Only the two facts the client can PROVE, in the server's own reject order, as reason CODES.
    const blockedReason =
      p.memberCount === 0 ? 'empty_group' : !cmd.active ? 'fleet_inactive_no_command' : null

    // ── THE ONE ACTION ────────────────────────────────────────────────────────────────────────────
    // Fighting outranks standing on a fight: the way OUT of the battle you are in must never be
    // displaced by an invitation into another one.
    const standing = huntByGroup.get(p.groupId)
    const action: FleetStatusAction = encounter
      ? {
          kind: 'retreat',
          encounterId: encounter.id,
          presenceId: encounter.presence_id,
          retreating: selectCombatPhase(encounter).isRetreating,
        }
      : standing
        ? { kind: 'hunt', locationId: standing.locationId, siteName: standing.siteName, label: standing.label }
        : null

    return {
      groupId: p.groupId,
      name: p.name,
      state: p.state,
      where: fleetWhereText(p.state, p.placeName),
      doing,
      stats,
      blockedReason,
      action,
    }
  })

  return { rows }
}
