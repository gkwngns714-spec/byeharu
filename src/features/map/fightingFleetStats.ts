import type { CombatUnit } from '../combat/combatTypes'
import { unitWeaponRange } from './spatialCombatLayer'

// ██ WHAT MY FLEET CAN DO IN THIS FIGHT — reach, speed and rate of fire, read off the server's own
//    frozen combat rows. ██
//
// ── THE REQUEST ────────────────────────────────────────────────────────────────────────────────────
// Owner: *"the fleets info tab should have info like range, speed, reload time, etc"*.
//
// ── ⚠ THESE ARE NOT REGISTRY STATS, AND THEY MUST NOT BECOME ANOTHER VOCABULARY ────────────────────
// `docs/STAT_ARCHITECTURE_CONTRACT.md` §11.3 (:995-997) lists, among the things the stat architecture
// will NOT do: *"Model weapon range, projectile speed, cooldown or ammo as registry stats. They are
// per-weapon geometry in weapons_json"*. Migration 0340 (:512-515) says the same and names the
// shipped defect that earned the rule. `get_stat_definitions()` carries four routine stats —
// combat_power, survival, speed, cargo_capacity — and NONE of them is any of these three.
//
// So this file reads RUNTIME COMBAT FACTS off `combat_units`, which the server froze at spawn, and it
// adds no fourth label vocabulary: the reach derivation is the existing ONE authority
// (`spatialCombatLayer.unitWeaponRange`), and the labels are the ones the fleet readout already
// renders through its own StatRow list.
//
// ── THE FLEET IS THE ACTOR (combat design law #1) ──────────────────────────────────────────────────
// *"why are there four ships? because i have 4 ships in fleet? no, show only fleet. it is as a
// whole."* So every number here is ONE number for the whole fleet, never a per-hull table:
//
//   · REACH  = MAX weapon range over the living hulls. `combatActors.CombatActorView.range` states
//     this exact fact for the map glyph — *"the FURTHEST this actor can shoot, which is a real fact
//     about it"* — and this is the readout's statement of the same thing. It is a DISPLAY fact only:
//     the fire gate is per weapon, per hull, and nothing here is ever fed back into a decision. (That
//     distinction is the whole of 0336:35-40's defect: an aggregate used as a GATE disabled a shorter
//     gun on the same hull. Used as a sentence, it disables nothing.)
//   · SPEED  = MIN `move_speed` over the living hulls, because that is the fleet's own speed as the
//     ENGINE moves it: 0337's reposition walks the fleet at `min(move_speed)` over its living hulls.
//     This is the client's FIRST and ONLY reader of `combat_units.move_speed`, and it is deliberately
//     NOT the map-travel `speed` stat (a hull-catalog multiplier, a different quantity with a
//     different unit). Two different questions, two different numbers, stated as such.
//
// ── ██ RATE OF FIRE: WHY `cooldown_seconds` IS NOT SHOWN ██ ────────────────────────────────────────
// Every fitted weapon carries `cooldown_seconds` in `weapons_json`, and the engine NEVER READS IT.
// Measured in the deployed tick body (0299:870-873 and :947, unchanged through 0336's surgery — the
// same two lines appear in every re-create back to 0234):
//
//     v_w_next_ready := nullif(v_weapon->>'next_ready_at','')::timestamptz;
//     if … and (v_w_next_ready is null or now() >= v_w_next_ready) then …
//     … v_weapon || jsonb_build_object('next_ready_at', now(), …)
//
// The gate is stamped `now()` — NOT `now() + cooldown_seconds`. So the condition `now() >= now()` is
// satisfied on every subsequent tick whatever the cooldown says, and every weapon in range fires
// every round. Printing "Reload 2s" would put a number on screen that changes nothing in the game,
// which is exactly what the fleet readout already refuses for the dormant fold stats.
//
// What IS true, and what the player experiences, is the ROUND: the engine runs every
// `game_config.combat_tick_seconds` (live 3), and a weapon in range fires on each one. So the honest
// answer to "reload time" is *every round*, with the round's own length beside it — and it stays
// honest the day the engine starts honouring a cooldown, because then the line's VALUE changes
// rather than its meaning. An unreadable knob yields `roundSeconds: null` and the sentence drops the
// number instead of inventing one (the retreatCountdown law).
//
// PURE. No React, no fetch, no clock.

export interface FightingFleetStats {
  /** the furthest this fleet can shoot, world units; null when no living hull carries a ranged gun. */
  reach: number | null
  /** the speed the engine moves this fleet at in the fight, world units per tick; null when no living
   *  hull reports one. */
  speed: number | null
  /** how long one combat round lasts, seconds; null when game_config could not be read. */
  roundSeconds: number | null
  /** how many of the fleet's hulls are still standing in this fight. */
  hullsAlive: number
}

/** The ONE phrase for the fire cadence, so the readout and any later surface say it identically. */
export function fireRateText(roundSeconds: number | null): string {
  return roundSeconds === null || !(roundSeconds > 0)
    ? 'every round'
    : `every round · ${trim(roundSeconds)}s`
}

/**
 * The fight stats for ONE encounter's player side, or null when that encounter has no living player
 * hull on the wire (nothing honest to say).
 */
export function resolveFightingFleetStats(
  units: readonly CombatUnit[],
  encounterId: string,
  roundSeconds: number | null,
): FightingFleetStats | null {
  const hulls = units.filter(
    (u) => u.encounter_id === encounterId && u.side === 'player' && (u.alive_count ?? 0) > 0,
  )
  if (hulls.length === 0) return null

  let reach: number | null = null
  let speed: number | null = null
  for (const u of hulls) {
    const r = unitWeaponRange(u)
    if (r !== null) reach = reach === null ? r : Math.max(reach, r)
    const s = u.move_speed
    if (typeof s === 'number' && Number.isFinite(s) && s > 0) speed = speed === null ? s : Math.min(speed, s)
  }

  return {
    reach,
    speed,
    roundSeconds: typeof roundSeconds === 'number' && Number.isFinite(roundSeconds) && roundSeconds > 0
      ? roundSeconds
      : null,
    hullsAlive: hulls.reduce((n, u) => n + (u.alive_count ?? 0), 0),
  }
}

/** Two decimals at most, and no trailing zeros — a speed of 0.6 is not "0.60" and a reach of 6 is not
 *  "6.00". Display only. */
export function trim(n: number): string {
  return String(Math.round(n * 100) / 100)
}
