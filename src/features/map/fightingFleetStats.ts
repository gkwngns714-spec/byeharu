import type { CombatUnit } from '../combat/combatTypes'
// Straight from the pure catalog module, NOT the components barrel: the barrel re-exports ItemTile's
// React components, and this leaf stays renderer-free (its spec pins that).
import { itemLabel } from '../../components/items/itemGlyphs'
import { unitWeaponRange } from './spatialCombatLayer'

// ██ WHAT MY FLEET CAN DO IN THIS FIGHT — what it shoots with, how hard, how far, how fast, and what
//    is left of it — read off the server's own frozen combat rows. ██
//
// ── THE REQUEST ────────────────────────────────────────────────────────────────────────────────────
// Owner: *"the fleets info tab should have info like range, speed, reload time, etc"*, then on
// 2026-08-09, playing: *"the fleets tab on map does not show range, its moving speed, hull, shield,
// shield generation"* and *"the fleets tab should also show attacking power, what weapon system it
// is using"*.
//
// The first four of those were ALREADY on the screen when he wrote that — as "Reach", "Fires" and
// "Combat speed". A stat the player does not recognise as the thing he asked for is a stat that is
// not there, so the labels are now the owner's own plain words (see WORDS below) and the missing
// ones are added here rather than in a second module.
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
//   · RANGE  = MAX weapon range over the living hulls. `combatActors.CombatActorView.range` states
//     this exact fact for the map glyph — *"the FURTHEST this actor can shoot, which is a real fact
//     about it"* — and this is the readout's statement of the same thing. It is a DISPLAY fact only:
//     the fire gate is per weapon, per hull, and nothing here is ever fed back into a decision. (That
//     distinction is the whole of 0336:35-40's defect: an aggregate used as a GATE disabled a shorter
//     gun on the same hull. Used as a sentence, it disables nothing.)
//   · SPEED  = MIN `move_speed` over the living hulls, because that is the fleet's own speed as the
//     ENGINE moves it: 0337's reposition walks the fleet at `min(move_speed)` over its living hulls.
//     This is the client's FIRST and ONLY reader of `combat_units.move_speed`, and it is deliberately
//     NOT the map-travel `speed` stat (a hull-catalog multiplier, a different quantity with a
//     different unit). Two different questions, two different numbers, stated as such — the readout
//     says "in battle" on it for exactly that reason.
//   · ATTACK = the SUM of every living hull's every weapon `power`. Migration 0331
//     (`one_authority_for_attack`) rewrote that field to be the ship's own folded `combat_power`
//     split across its guns in proportion to `module_types.power` — so a ship's weapons sum EXACTLY
//     to its combat_power, and the fleet's weapons sum to the damage the fleet puts out in one round
//     when everything is in range. It is not a fifth definition of "power": it is the engine's own
//     per-volley number, added up over the actor the owner sees. Nothing is scaled, curved or
//     modified here — the defence curve is the server's and is applied on arrival, not on departure.
//   · WEAPONS = the DISTINCT `module_type_id` across those same weapons, with how many guns carry
//     each. *"what weapon system it is using"*, answered off the frozen array rather than from any
//     client-side weapon table — 0331 forbids the latter outright. Humanised through `itemLabel(id,
//     'module')`, the ONE id→name authority the fitting screens and every loot chip already use, so
//     a module is called the same thing everywhere in the client.
//   · HULL   = Σ hp_current / Σ hp_max over the living hulls, which is the SAME quantity and the same
//     summation the engine calls the fleet's integrity (0168:455-458, *"Σ hp_max IS hull integrity"*)
//     and which `combat_encounters.player_integrity_current/max` carries. It is folded here rather
//     than read off the encounter row for one reason: this leaf is handed `units`, and hull sitting
//     beside SHIELD — which has no server-side aggregate at all — keeps the pair readable as one
//     statement. It is the fleet's own hulls only, never the enemy's.
//
// ── ██ "MOVING SPEED": WHY THERE IS NO SECOND, TRAVEL-SPEED NUMBER ██ ─────────────────────────────
// The owner said "moving speed", and in a fight that is the combat speed above. The obvious next
// question is whether the readout should ALSO state how fast the fleet crosses the MAP. It should
// not, and the reason is that neither candidate authority is honest:
//
//   · `fleet_movements.speed_used` is non-null on all 282 live rows, but migration 0149:20 says
//     outright that a leg's clock is NOT derived from it — *"travel_seconds is the DESIGN-fixed
//     symmetric time (not distance/speed_used-derived …); speed_used keeps the outbound hull speed,
//     satisfying its >0 constraint"*. On a stop-transit or a timed dock it is a leftover that
//     satisfies a CHECK constraint. Printing it would state a speed the fleet is not travelling at.
//   · `main_ship_hull_types.base_speed` is a catalog multiplier, and STAT_ARCHITECTURE_CONTRACT
//     records that "fleet speed" already has NINE competing definitions. Folding hull speeds here
//     would be the tenth, which is the one thing this leaf's header forbids.
//
// The honest travel answer is the one the readout ALREADY gives, and the server computes it: while a
// fleet is in flight the row says *"Arriving in 2m 08s"*, from the leg's own `arrive_at` through the
// ONE lead-arrival rule (command/teamStop). That is what a player wants from "how fast does it move"
// and it cannot be wrong. So: one speed while fighting, one arrival while travelling, each labelled
// for what it is, and no number that has to be caveated.
//
// ── ██ SHIELD, AND SHIELD GENERATION: BOTH REAL, BOTH ZERO ON PRODUCTION TODAY ██ ──────────────────
// `combat_units.shield_current/shield_max` exist (migration 0191) and the tick genuinely regenerates
// and absorbs with them (0195: `shield := least(shield_max, shield_current + shield_max ×
// cfg_num('shield_regen_combat_pct'))`, then a shield-absorbs-first subtraction). So both things the
// owner asked for are real mechanics with a real writer.
//
// They are also, MEASURED ON PRODUCTION 2026-08-09, entirely inert:
//     combat_units with a non-null shield_max        0 of 327
//     main_ship_instances with max_shield > 0        0 of 77
//     main_ship_hull_types with base_shield > 0      0 of 3
//     game_config.shield_regen_combat_pct            0
// The shield stack is DATA-GATED, deliberately with no flag: 0191/0195/0197 shipped it dark and
// `scripts/activate-shield.sql` is the human flip that raises the hull values and both knobs.
//
// So the rule here is the fleet readout's own standing one — *a number that changes nothing in the
// game must not appear on the map*. `shield` is null while no living hull carries a pool, and
// `shieldRegenPerRound` is null while there is no pool OR the knob is not positive. TODAY BOTH ARE
// NULL AND THE READOUT SHOWS NEITHER LINE. Printing "Shield 0/0" would draw a bar that can never
// move; printing "Shield regen 0" would name a mechanic that does not run. The day ACT-SHIELD is
// run, both lines appear on their own, with the server's numbers, and nothing here changes.
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
// ── ██ THE WORDS ██ ────────────────────────────────────────────────────────────────────────────────
// The owner listed "range" and "moving speed" as MISSING from a readout that was printing "Reach"
// and "Combat speed" at that exact moment. That is not a data defect and it is not him misreading:
// it is the map-UX law (*no insider jargon*) failing. "Reach" is a word this codebase invented;
// "range" is the word on the weapon. So the labels are his:
//     Reach        → Range
//     Combat speed → Speed in battle
// "in battle" is doing real work and is not decoration — a fleet's map-travel speed and its combat
// `move_speed` are different quantities in different units, and the readout must never let them be
// read as one number. They are named HERE, beside the values, so a surface cannot invent its own.
export const FLEET_STAT_LABEL = {
  hull: 'Hull',
  shield: 'Shield',
  shieldRegen: 'Shield regen',
  attack: 'Attack',
  weapons: 'Weapons',
  range: 'Range',
  fires: 'Fires',
  speed: 'Speed in battle',
} as const

// PURE. No React, no fetch, no clock.

/** ONE weapon system the fleet is fitted with, and how many guns carry it. */
export interface FleetWeaponSystem {
  /** the catalog `module_types.id`, frozen onto weapons_json at spawn. */
  id: string
  /** humanised through the ONE client id→name authority (components/items.itemLabel). */
  name: string
  /** how many guns across the fleet's living hulls are this system. */
  count: number
}

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
  /** what the fleet's guns put out in one round, by 0331's own per-weapon `power`; null when no
   *  living hull carries a weapon that states one. Never a 0 — that would read as "it does no
   *  damage" when the truth is "the rows do not say". */
  attack: number | null
  /** every distinct weapon system across the living hulls, most-fitted first then by id (stable, so
   *  the line does not reshuffle between polls). Empty when nothing is fitted. */
  weapons: FleetWeaponSystem[]
  /** Σ hp_current / Σ hp_max over the living hulls; null when the rows carry no usable max. */
  hull: { current: number; max: number } | null
  /** Σ shield_current / Σ shield_max over the living hulls that HAVE a pool; null when none does —
   *  which is every fight on production today (see the header). Never 0/0. */
  shield: { current: number; max: number } | null
  /** what the shield pool regains per combat round: `Σ shield_max × shield_regen_combat_pct`. Null
   *  when there is no pool or the knob is not positive — never a 0, which would name a mechanic that
   *  does not run. */
  shieldRegenPerRound: number | null
}

/** The ONE phrase for the fire cadence, so the readout and any later surface say it identically. */
export function fireRateText(roundSeconds: number | null): string {
  return roundSeconds === null || !(roundSeconds > 0)
    ? 'every round'
    : `every round · ${trim(roundSeconds)}s`
}

/** The ONE phrase for a fitted weapon system list: "Basic Player Weapon ×5", joined. A count of 1 is
 *  printed bare — "×1" is noise on a single gun. */
export function weaponSystemsText(weapons: readonly FleetWeaponSystem[]): string {
  return weapons.map((w) => (w.count > 1 ? `${w.name} ×${w.count}` : w.name)).join(', ')
}

/** A positive finite number, or null. The ONE reading of a numeric column in this file — a 0, a NaN
 *  and an absent column are all "the row does not say", never a value. */
const positive = (v: unknown): number | null =>
  typeof v === 'number' && Number.isFinite(v) && v > 0 ? v : null

/**
 * The fight stats for ONE encounter's player side, or null when that encounter has no living player
 * hull on the wire (nothing honest to say).
 *
 * `shieldRegenCombatPct` is `game_config.shield_regen_combat_pct`, the very knob the tick reads
 * (0195). Absent/unreadable/0 → no regen line at all.
 */
export function resolveFightingFleetStats(
  units: readonly CombatUnit[],
  encounterId: string,
  roundSeconds: number | null,
  shieldRegenCombatPct: number | null = null,
): FightingFleetStats | null {
  const hulls = units.filter(
    (u) => u.encounter_id === encounterId && u.side === 'player' && (u.alive_count ?? 0) > 0,
  )
  if (hulls.length === 0) return null

  let reach: number | null = null
  let speed: number | null = null
  let attack: number | null = null
  let hullCur = 0
  let hullMax = 0
  let shieldCur = 0
  let shieldMax = 0
  const byWeapon = new Map<string, number>()

  for (const u of hulls) {
    const r = unitWeaponRange(u)
    if (r !== null) reach = reach === null ? r : Math.max(reach, r)
    const s = positive(u.move_speed)
    if (s !== null) speed = speed === null ? s : Math.min(speed, s)

    // ATTACK + WEAPONS, from the ONE authority for what a ship shoots (0331's weapons_json). A
    // weapon with no stated power contributes no damage and is still a fitted SYSTEM, so the two
    // reads are independent — an unpowered gun must not vanish from "what am I shooting with".
    for (const w of u.weapons_json ?? []) {
      if (!w) continue
      const p = positive(w.power)
      if (p !== null) attack = (attack ?? 0) + p
      const id = typeof w.module_type_id === 'string' && w.module_type_id !== '' ? w.module_type_id : null
      if (id !== null) byWeapon.set(id, (byWeapon.get(id) ?? 0) + 1)
    }

    // HULL — hp_max is what the engine sums as integrity, so a row with no positive max contributes
    // neither side of the fraction rather than dragging the total toward a wrong denominator.
    const hMax = positive(u.hp_max)
    if (hMax !== null) {
      hullMax += hMax
      hullCur += Math.max(0, Math.min(hMax, typeof u.hp_current === 'number' && Number.isFinite(u.hp_current) ? u.hp_current : 0))
    }

    // SHIELD — 0191 pairs shield_max/shield_current by CHECK, and a shieldless hull carries NULL/NULL
    // rather than 0/0 precisely so "no shield machinery" is distinguishable from "shield down". Only
    // a positive max is a pool.
    const sMax = positive(u.shield_max)
    if (sMax !== null) {
      shieldMax += sMax
      shieldCur += Math.max(0, Math.min(sMax, typeof u.shield_current === 'number' && Number.isFinite(u.shield_current) ? u.shield_current : 0))
    }
  }

  const regenPct = positive(shieldRegenCombatPct)

  return {
    reach,
    speed,
    roundSeconds: positive(roundSeconds),
    hullsAlive: hulls.reduce((n, u) => n + (u.alive_count ?? 0), 0),
    attack,
    weapons: [...byWeapon.entries()]
      .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
      .map(([id, count]) => ({ id, name: itemLabel(id, 'module'), count })),
    hull: hullMax > 0 ? { current: hullCur, max: hullMax } : null,
    shield: shieldMax > 0 ? { current: shieldCur, max: shieldMax } : null,
    shieldRegenPerRound: shieldMax > 0 && regenPct !== null ? shieldMax * regenPct : null,
  }
}

/** Two decimals at most, and no trailing zeros — a speed of 0.6 is not "0.60" and a reach of 6 is not
 *  "6.00". Display only. */
export function trim(n: number): string {
  return String(Math.round(n * 100) / 100)
}
