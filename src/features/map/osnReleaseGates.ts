// PORT-LAUNCH-1B / OSN-COORD-ENABLE-1C — release gates for the OSN navigation surfaces (PURE constants).
//
// These are COMPILE-TIME constants, NOT runtime/game_config feature flags.

// RETIRED as a UI authority (OSN-COORD-ENABLE-1C). Coordinate targeting is no longer gated by this constant;
// it is now driven SOLELY by the server-derived runtime capability `coordinate_travel_available` from
// get_osn_movement_readiness() (see osnReadiness.isCoordinateTargetingActionable + GalaxyMap). No component
// imports this constant anymore — keeping it referenced would re-introduce a second, contradictory frontend
// gate, which is exactly what 1C removes.
//
// It is retained at `false` for ONE narrow, non-UI purpose: the strictly read-only production verifier
// (scripts/osn-postenable-verify.* → assert_coord_suppressed + the OSN_COORDINATE_TRAVEL_ENABLED_FRONTEND
// marker) greps THIS file to confirm there is no compile-time coordinate escape hatch in the bundle. It must
// never be flipped to `true` and must never re-enter the render path; a future cleanup may remove it together
// with that verifier assertion.
export const OSN_COORDINATE_TRAVEL_ENABLED = false as const
