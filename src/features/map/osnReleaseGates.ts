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

// ── TRADE-UI-1 — trading surface release gates (compile-time; UI fail-closed control). ──
// These MIRROR the server game_config flags: TRADE_MARKET_ENABLED ↔ `trade_market_enabled`,
// MAINSHIP_ADDITIONAL_ENABLED ↔ `mainship_additional_commission_enabled`. The server already rejects every
// trade / add-ship RPC while those flags are false; the frontend ALSO fails closed behind these constants so
// the trading + ship-switcher UI is invisible until a HUMAN flips BOTH (server flag + this gate). Default OFF
// (DARK). Do NOT set true here — a human owns activation. Double fail-closed: even if a gate were flipped, the
// server still rejects until its own flag is on.
export const TRADE_MARKET_ENABLED = false as const
// ACTIVATED 2026-07-12 (team-command launch): the server flag `mainship_additional_commission_enabled` was
// flipped true by scripts/activate-team-command.sql (PASS). This mounts CommissionShipPanel + the ship
// switcher (ShipScreen). Both fail-closed layers were flipped by a human, per the activation checklist.
export const MAINSHIP_ADDITIONAL_ENABLED = true as const

// ── TEAM-COMMAND Slice A — team-roster surface release gate (compile-time; UI fail-closed control). ──
// "group" is the backend/DB/code word (ship_groups, main_ship_instances.group_id); "team" is the UI word —
// this constant is the UI-side mirror of the server game_config flag `team_command_enabled` (seeded false in
// migration 0160). The CommandScreen team roster stays invisible (and its owner-reads never run — the panel is
// not mounted while this is false) until a HUMAN flips BOTH the server flag AND this constant. Default OFF
// (DARK until activation).
// ACTIVATED 2026-07-12 (team-command launch): the server flag `team_command_enabled` was flipped true by
// scripts/activate-team-command.sql (PASS — price 250, fleets 6, commissioning + modules lit alongside).
// This mounts TeamRosterPanel (teams, captains-when-lit, expedition preview, team send/stop, Hunt).
// Both fail-closed layers were flipped by a human, per docs/TEAM_COMMAND.md's ACTIVATION CHECKLIST.
export const TEAM_COMMAND_ENABLED = true as const
