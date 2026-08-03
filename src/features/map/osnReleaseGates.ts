// PORT-LAUNCH-1B / OSN-COORD-ENABLE-1C — release gates for the OSN navigation surfaces (PURE constants).
//
// These are COMPILE-TIME constants, NOT runtime/game_config feature flags.

// RETIRED as a UI authority (OSN-COORD-ENABLE-1C), and the per-ship coordinate surface it once gated was
// DELETED outright in 4A-POST (the osnReadiness module + GalaxyMap's per-ship arm are gone; the unified
// fleet mover owns coordinate travel). No component imports this constant.
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
// the trading + ship-switcher UI is invisible until a HUMAN flips BOTH (server flag + this gate). They SEED
// off (DARK) and a human owns the flip. Double fail-closed: even with a gate flipped, the server still rejects
// until its own flag is on.
//
// THE FAILURE MODE THIS PAIRING HAS (learned the expensive way, 2026-08-03): a gate left dark AFTER its server
// flag was lit is invisible to every proof in the repo — the client suite cannot see production's game_config,
// and the server proofs cannot see a compile-time constant. `TRADE_MARKET_ENABLED` sat false for weeks against
// a lit `trade_market_enabled`, and the only symptom was a player who could accept haul contracts and never
// source the goods. tests/portTradeSurface.spec.ts now makes any dark mirror gate an EXPLICIT, named decision
// instead of a silent default.
// ACTIVATED 2026-08-03 (haul-loop close): the server half was flipped long ago by
// scripts/activate-trade.sql — production game_config carries BOTH keys that script writes,
// `trade_market_enabled = true` AND `trade_relief_enabled = true` (verified against the live DB,
// not against CI). Only the client step documented at scripts/activate-trade.sh:30 ("the ONE-LINE
// client PR: TRADE_MARKET_ENABLED -> true") was never taken, so the buy side of the economy has
// been unreachable while the sell/consume side ran: `market_buy` is the ONLY producer of
// `ship_cargo_lots` a player can reach, and with the panel unmounted production held ZERO cargo
// lots in the entire game — which made every accepted haul contract undeliverable
// (`insufficient_cargo`, 0179:379-382). Flipping this mounts MarketPanel on PortScreen and
// completes the ShipSwitcher OR-gate on ShipScreen. Both fail-closed layers are now flipped; the
// server still re-checks its own flag on every RPC.
export const TRADE_MARKET_ENABLED = true as const
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
