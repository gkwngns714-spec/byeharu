// HOW A FIGHT STARTS — the ONE description, used by every surface that explains combat.
//
// ── WHY THIS FILE EXISTS (owner, 2026-08-03, playing) ────────────────────────────────────────────
// "i went to snare, zone, no fighting happens. why are you keep messing things up? spaghetti of
// course. do it properly"
//
// They were right and the cause was ours. Four trips were made that afternoon; every one of them
// was `mission_type='rally'` to `target_type='space'` — plain travel to a bare coordinate at
// (-45,88), (-43,94), (-43,98), (-35,99). The Snare SITE is a location at (-45,120). They were
// aiming at the shaded SNARE ZONE (a danger_zones blob that shares the site's name and, per the
// 2026-08-03 audit, covers 7.2x its declared area) and never once targeted the site itself. Two of
// the four rolled an ambush and MISSED (risk 0.545 vs roll 0.697; risk 0.240 vs roll 0.336); two
// rolled nothing at all. No encounter was ever created. The server behaved correctly the whole time.
//
// What made it look broken was that THREE different screens described combat three different ways,
// and the one the owner read named the zone:
//   · MissionScreen  — "send a fleet ... into a pirate zone to hunt"      (false: a zone is not a target)
//   · zoneInfoModel  — "A fleet crossing this zone is almost always attacked" (false: 0.24 and 0.55,
//                       and the 0.98 pin that sentence was written against is long gone from prod)
//   · the map prompt — named ports and open space, and never mentioned hunting at all
//
// ── THE RULE, VERIFIED ON PRODUCTION (head 20260618000335) ────────────────────────────────────────
// A fight starts EXACTLY one way: `send_ship_group_hunt`, reached by selecting a `hunt_pirates`
// LOCATION on the map (MapScreen.handleSelect -> teamDestinationKind -> the FleetCommandPanel hunt
// section). The unified mover refuses a combat destination outright — the deployed
// `command_ship_group_go` returns reason `combat_destination` for any location whose activity_type
// is not 'none', and its own comment says so: "A move is not a hunt: hunts go through
// send_ship_group_hunt". That refusal is a SERVER RULE and is not to be fought; it is to be
// explained.
//
// A pirate ZONE is a separate thing entirely: an area that may ambush a fleet crossing it. The roll
// can miss. Any copy that treats crossing a zone as a way to pick a fight is describing a mechanic
// the game does not have.
//
// ── THE LAW THIS FILE CARRIES ────────────────────────────────────────────────────────────────────
// ONE description, composed everywhere. If a screen wants to say how a fight starts, it imports
// from here. A second wording is the defect, not a style choice — that is exactly the state this
// file replaced. tests/howAFightStarts.spec.ts scans src/ and FAILS on any surface that re-invents
// it, including the specific phrase that misled the owner.
//
// Pure: constants and one string builder. No React, no DOM, no fetch, no state.

/**
 * The ONE sentence for "how do I get into a fight?". Names the gesture (tap the SITE) and the verb
 * (Hunt), because naming only the place is what left the owner tapping empty space for an afternoon.
 */
export const HOW_A_FIGHT_STARTS = 'To fight, tap a pirate site on the Map and choose Hunt.'

/**
 * The ONE sentence for what a pirate ZONE is. Deliberately paired with the sentence above wherever
 * a zone is in front of the player: the whole failure was reading the shaded area as the target.
 *
 * "may be ambushed" and not "is almost always attacked": the risk is computed per crossing from
 * fleet strength and exposure (pirate_intercept_base_risk 1, min_risk 0.02, exposure_floor 0.15,
 * stat_reference 120 — read from production), and the two most recent live crossings rolled 0.545
 * and 0.240 and both MISSED. A promise the engine does not keep reads as a broken game.
 */
export const A_ZONE_IS_NOT_A_HUNT =
  'The shaded zone around a site is not a hunt — flying through it may get you ambushed, or may not.'

/** The signpost label that takes a player from a zone to the site inside it. */
export function huntSiteActionLabel(siteName: string): string {
  return `Hunt at ${siteName}`
}
