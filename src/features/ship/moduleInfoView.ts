import { traitEffects, type TraitEffect } from './shipTraits'
import type { ModuleTypeRow } from '../modules/modulesTypes'

// FITTING TAP-TO-INFO — PURE view logic for a module's info panel (no React/DOM/fetch — the
// shipTraits.ts / shipDossierView.ts mold). Turns one module_types catalog row into the two
// display groups the inline info card renders:
//   · effects    — the fitted stat contributions, formatted by the SHARED traitEffects formatter
//                  (stats_json keys attack/defense/repair/cargo/scan/mining/evasion/
//                  speed_mult_bonus → signed +N/-N labels). Modules carry NO hp_mult, so we pass
//                  1 (the "no hull birthmark" value traitEffects skips) — never a hull line.
//   · attributes — the COMBAT-S0 (0229) spatial/combat attributes as plain labeled rows
//                  (Range/Volley share/Projectile speed/Cooldown/Ammo), each shown ONLY when present and
//                  meaningful (NULL / 0 = the module has none of that reach → skipped, never a
//                  "Range 0" line). numeric columns arrive as strings over PostgREST — coerced here.
// Display only: every number is the catalog's stored truth; this module invents nothing.

/** A plain labeled attribute row (combat/spatial reach that has no signed-effect shape). */
export interface ModuleAttr {
  label: string
  value: string
}

export interface ModuleInfoView {
  slotType: string
  /** Σ-slot-cost when fitted (0111); null only if the column read back non-numeric. */
  slotCost: number | null
  /** Signed stat-contribution labels from stats_json (the shared traitEffects formatter). */
  effects: TraitEffect[]
  /** Combat/spatial attributes present on this module, in a fixed display order. */
  attributes: ModuleAttr[]
  description: string
}

/** Coerce a possibly-string PostgREST numeric to a finite number, else null. */
function toNum(v: number | string | null | undefined): number | null {
  if (v == null) return null
  const n = Number(v)
  return Number.isFinite(n) ? n : null
}

/** ammo_type is an item_types(item_id) — humanize the id for display (no catalog lookup needed;
 *  no ammo item exists in the seed catalog yet, so this is a forward-only, honest fallback). */
function humanizeId(id: string): string {
  return id.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase())
}

/** Build the info view-model for one module_types row. Malformed/NULL fields collapse to the
 *  "absent" shape (skipped rows) — never a throw, never a NaN in the render path. */
export function moduleInfoView(row: ModuleTypeRow): ModuleInfoView {
  const attributes: ModuleAttr[] = []

  const range = toNum(row.range)
  if (range != null && range > 0) attributes.push({ label: 'Range', value: String(range) })

  // 0317 — module_types.power is a unitless SHARE WEIGHT for a firing weapon: the fraction of its
  // ship's folded combat_power that THIS gun delivers, not an amount of damage. A module's damage
  // contribution is its stats_json.attack, which the `effects` list above already renders as a
  // signed "+N Attack" line. Labelling the weight "Power" told the player that fitting this module
  // made the ship hit for that number — the second damage authority the server stopped believing.
  // Only weapons show it (as a share the player can compare between their own guns); no other
  // archetype does, because nothing in the game reads this column for them — mining_extract sizes
  // its radius from .range and never touches .power.
  const power = toNum(row.power)
  if (row.slot_type === 'weapon' && power != null && power > 0) {
    attributes.push({ label: 'Volley share', value: String(power) })
  }

  const speed = toNum(row.projectile_speed)
  if (speed != null && speed > 0) attributes.push({ label: 'Projectile speed', value: String(speed) })

  const cooldown = toNum(row.cooldown_seconds)
  if (cooldown != null && cooldown > 0) attributes.push({ label: 'Cooldown', value: `${cooldown}s` })

  if (row.ammo_type) {
    attributes.push({ label: 'Ammo', value: humanizeId(row.ammo_type) })
    const perShot = toNum(row.ammo_per_shot)
    if (perShot != null && perShot > 0) attributes.push({ label: 'Ammo per shot', value: String(perShot) })
  }

  return {
    slotType: row.slot_type,
    slotCost: toNum(row.slot_cost),
    effects: traitEffects(row.stats_json, 1), // modules have no hp_mult; 1 = no hull line
    attributes,
    description: row.description,
  }
}
