// GENERATED FILE — DO NOT EDIT BY HAND.
//
// THE ONE CLIENT PROJECTION of public.stat_definitions, generated from the seed in
// supabase/migrations/20260618000340_stats_have_one_authority.sql.
//
// Regenerate by re-running tests/statRegistryProjection.spec.ts: it re-derives this file from the
// migration and byte-compares, so the migration is this file's SOLE authority and drift is a red
// test rather than a wrong number on a player's screen.
//
// Editing this file by hand would recreate exactly what migration 0340 exists to delete: a second
// place that decides whether a stat is in play.

/** One projected stat_definitions row.
 *
 *  `lifecycle` is DELIBERATELY typed `string`, not the three-value union. The union lives in
 *  statLifecycle.ts, behind a mapping that FAILS CLOSED — an unknown lifecycle must be unrepresentable
 *  as an effective player benefit, and typing this field as the union would let the compiler assume
 *  a value the database is the only authority on. */
export interface StatDefinitionRow {
  readonly statId: string
  readonly catalogKey: string
  readonly displayName: string
  readonly displayOrder: number
  readonly lifecycle: string
  readonly valueKind: string
  readonly combinationClass: string
  readonly fleetAggregation: string
  readonly unit: string
  readonly supersedesStatId: string | null
  readonly engineConsumer: string | null
  readonly presentationConsumer: string | null
  readonly deprecatedReason: string | null
}

/** The migration that owns every row below. */
export const STAT_REGISTRY_SOURCE_MIGRATION = '20260618000340_stats_have_one_authority.sql'

/** The seeded registry, in display_order. */
export const STAT_DEFINITION_ROWS: readonly StatDefinitionRow[] = [
  {
    statId: "combat_power",
    catalogKey: "attack",
    displayName: "Combat Power",
    displayOrder: 10,
    lifecycle: "active",
    valueKind: "flat",
    combinationClass: "additive",
    fleetAggregation: "sum",
    unit: "points",
    supersedesStatId: null,
    engineConsumer: "combat_create_group_encounter",
    presentationConsumer: "src/features/command/TeamPreviewSection.tsx",
    deprecatedReason: null,
  },
  {
    statId: "survival",
    catalogKey: "defense",
    displayName: "Survival",
    displayOrder: 20,
    lifecycle: "active",
    valueKind: "flat",
    combinationClass: "additive",
    fleetAggregation: "sum",
    unit: "points",
    supersedesStatId: null,
    engineConsumer: "combat_create_group_encounter",
    presentationConsumer: "src/features/command/TeamPreviewSection.tsx",
    deprecatedReason: null,
  },
  {
    statId: "speed",
    catalogKey: "speed_mult_bonus",
    displayName: "Speed",
    displayOrder: 30,
    lifecycle: "active",
    valueKind: "multiplier",
    combinationClass: "multiplier_bonus",
    fleetAggregation: "min",
    unit: "wu_per_second",
    supersedesStatId: null,
    engineConsumer: "command_ship_group_go",
    presentationConsumer: null,
    deprecatedReason: null,
  },
  {
    statId: "cargo_capacity",
    catalogKey: "cargo",
    displayName: "Cargo Capacity (legacy, display-only)",
    displayOrder: 40,
    lifecycle: "deprecated",
    valueKind: "flat",
    combinationClass: "additive",
    fleetAggregation: "sum",
    unit: "points",
    supersedesStatId: null,
    engineConsumer: null,
    presentationConsumer: "src/features/command/TeamDossier.tsx",
    deprecatedReason: "DEPRECATED legacy display integer, non-authoritative. The canonical cargo authority is the ship-bound volume capacity in m3 (cargo_volume_m3 here; fleet_hold_capacity_m3 / fleet_hold_used_m3 in migration 20260618000333). This unitless number is differently unitised, drives no decision, takes no contributions, and must not be given new consumers. The unit conversion, any hold-size change, the treatment of already-fitted modules and the player-impact proof are a SEPARATE migration.",
  },
  {
    statId: "cargo_volume_m3",
    catalogKey: "cargo_volume_m3",
    displayName: "Cargo Volume",
    displayOrder: 45,
    lifecycle: "dormant",
    valueKind: "flat",
    combinationClass: "additive",
    fleetAggregation: "sum",
    unit: "m3",
    supersedesStatId: "cargo_capacity",
    engineConsumer: null,
    presentationConsumer: null,
    deprecatedReason: null,
  },
  {
    statId: "repair",
    catalogKey: "repair",
    displayName: "Repair",
    displayOrder: 50,
    lifecycle: "dormant",
    valueKind: "flat",
    combinationClass: "additive",
    fleetAggregation: "sum",
    unit: "points",
    supersedesStatId: null,
    engineConsumer: null,
    presentationConsumer: null,
    deprecatedReason: null,
  },
  {
    statId: "scouting",
    catalogKey: "scan",
    displayName: "Scouting",
    displayOrder: 60,
    lifecycle: "dormant",
    valueKind: "flat",
    combinationClass: "additive",
    fleetAggregation: "max",
    unit: "points",
    supersedesStatId: null,
    engineConsumer: null,
    presentationConsumer: null,
    deprecatedReason: null,
  },
  {
    statId: "mining_yield",
    catalogKey: "mining",
    displayName: "Mining Yield",
    displayOrder: 70,
    lifecycle: "dormant",
    valueKind: "flat",
    combinationClass: "additive",
    fleetAggregation: "sum",
    unit: "points",
    supersedesStatId: null,
    engineConsumer: null,
    presentationConsumer: null,
    deprecatedReason: null,
  },
  {
    statId: "retreat_safety",
    catalogKey: "evasion",
    displayName: "Retreat Safety",
    displayOrder: 80,
    lifecycle: "dormant",
    valueKind: "flat",
    combinationClass: "additive",
    fleetAggregation: "min",
    unit: "points",
    supersedesStatId: null,
    engineConsumer: null,
    presentationConsumer: null,
    deprecatedReason: null,
  },
  {
    statId: "pirate_attention",
    catalogKey: "pirate_attention",
    displayName: "Pirate Attention",
    displayOrder: 90,
    lifecycle: "dormant",
    valueKind: "flat",
    combinationClass: "additive",
    fleetAggregation: "sum",
    unit: "points",
    supersedesStatId: null,
    engineConsumer: null,
    presentationConsumer: null,
    deprecatedReason: null,
  },
]
