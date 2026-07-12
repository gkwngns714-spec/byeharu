import type { LocationType } from './mapTypes'

// DIFFICULTY-DISPLAY — the PURE player-facing display mappings for map-location internals. No React,
// no DOM: numbers/enums in, plain player words out, unit-tested directly (tests/locationDisplay.spec.ts).
// ONE home (moved out of MapScreen's inline block): MapScreen's detail sheet and TeamRosterPanel's
// hunt select both read from here — never re-derive these bands inline.
//
// WHY the extended bands: the ZONES2 review found the old buckets saturated — bd>20 all read 'High'
// and tier≥3 all read 'Rich', and min_power_required rendered NOWHERE, so the Ember Reach zones
// (bd 40/50/60, min_power 150/220/300) would read pixel-identical to Blackden (bd 25) when revealed.
// Words stay primary (plain player language); callers add the real numbers as mono metadata.
// Display-only over data get_world_map already returns for ACTIVE locations — nothing hidden leaks.
//
// markerStyle.ts keeps its own importance thresholds (>20 / >10) — the marker hierarchy deliberately
// stays coarser than these words (High/Severe/Extreme are all "major" markers). If these bands move,
// re-check markerImportance's comment there.

export const TYPE_LABEL: Record<LocationType, string> = {
  pirate_hunt: 'Pirate hunting ground',
  pirate_den: 'Pirate den',
  mining_site: 'Mining site',
  derelict_station: 'Derelict station',
  trade_outpost: 'Trade port',
  rally_point: 'Rally point',
  safe_zone: 'Safe waypoint',
  event_site: 'Event site',
}

/** base_difficulty → danger word. Bands: ≤0 safe · ≤10 Low · ≤20 Moderate · ≤35 High · ≤50 Severe · >50 Extreme. */
export const dangerLabel = (difficulty: number): string =>
  difficulty <= 0
    ? 'None — safe space'
    : difficulty <= 10
      ? 'Low'
      : difficulty <= 20
        ? 'Moderate'
        : difficulty <= 35
          ? 'High'
          : difficulty <= 50
            ? 'Severe'
            : 'Extreme'

/** reward_tier → reward word. 0 None · 1 Modest · 2 Good · 3 Rich · 4 Bountiful · ≥5 Legendary. */
export const rewardLabel = (tier: number): string =>
  tier <= 0
    ? 'None'
    : tier === 1
      ? 'Modest'
      : tier === 2
        ? 'Good'
        : tier === 3
          ? 'Rich'
          : tier === 4
            ? 'Bountiful'
            : 'Legendary'

/**
 * Append the team-combat power gate to a zone name when one exists — the hunt-select option label
 * (e.g. 'Ember Gate — power 150+'). Gate-free zones (min_power_required ≤ 0) render the bare name,
 * so today's live option labels are byte-identical. The server (send_ship_group_hunt,
 * power_below_required) stays the authority — this is a display hint, never a client gate.
 */
export const withPowerGate = (name: string, minPowerRequired: number): string =>
  minPowerRequired > 0 ? `${name} — power ${minPowerRequired}+` : name
