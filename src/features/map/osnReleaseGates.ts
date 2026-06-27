// PORT-LAUNCH-1B — release gates for the OSN navigation surfaces (PURE, framework-free constants).
//
// These are COMPILE-TIME constants, NOT runtime/game_config feature flags and NOT production-visible
// escape hatches — `vite build` const-folds any gated branch out of the bundle. They exist so a single
// tested source of truth controls which OSN command surfaces a player can reach.

// The first OSN release is PORT-TO-PORT location travel ONLY. The player-facing empty-space coordinate
// command surface (tap-to-coordinate target + SpaceMoveControls, calling command_main_ship_space_move)
// stays UNMOUNTED even after `mainship_space_movement_enabled` flips on. Re-enabling coordinate travel
// requires a separate future charter tied to exploration/mining/combat gameplay. The underlying coordinate
// transform / route / Stop / resolver code is untouched and stays dark.
export const OSN_COORDINATE_TRAVEL_ENABLED = false as const
