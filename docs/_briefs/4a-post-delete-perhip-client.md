# 4a-post — VERIFIED deletion plan (banked 2026-07-18)

Delete the dead per-ship movement client. Runs AFTER S1 merges (GalaxyMap.tsx is the rebase
hotspot; serialize behind S1). Frontend-only, no migration. Precondition for S5.

## Ground truth (OFF gates, all proven)
- Flip live: `fleet_movement_unified_enabled=TRUE`; `mainship_send_enabled` /
  `mainship_space_movement_enabled` / `mainship_coordinate_travel_enabled` / `fleet_control_enabled`
  all FALSE (charter:10-18,468, commit d05a780).
- Client reads flags raw (`src/lib/catalog.ts:46-54,73-77`; `useGalaxyMapData.ts:247`). The 93cb823
  fix OR'd only the fleet-positions READ (`useGalaxyMapData.ts:175`), NOT the flag consumers.
- Re-home ALREADY done: location send → TeamMapSend.tsx:293 (command_ship_group_go); coordinate go →
  FleetGoPanel (GalaxyMap.tsx:560); stop → TeamMapStop (MapScreen.tsx:137); repair → ShipStatusCard.tsx:99.
  NEEDS-REHOME = NONE.

## Deletion order
### Step A — unmount from live screens (compile-safe first)
- `MapScreen.tsx`: del imports 4-8; legacy-stop block 60-72 + 177-188; PortNavPanel mount 145-155;
  MainShipCommand mount 223-237; drop unused destructures `mainShipHeldFleet`,`fleetControlEnabled`,
  `mainShipInFleet` (50-51). KEEP `mainshipSendEnabled` (feeds GalaxyMap:112) + `mainShipSpaceMovement`
  (lifecycle key :74).
- `GalaxyMap.tsx`: del per-ship arm — imports 16-21 EXCEPT `classifyPointerGesture`(21); readiness
  26-27; hooks/derivations 119-153 (`sm`,`stop`,`inCoordinateTransit`,`eligibility`,readiness,`canTarget`);
  set `perShipCanTarget: false` at 164; del `else sm.selectTarget(world)` 276; per-ship target marker
  496-498; SpaceMoveControls mount 535-552; coordinate-stop mount 571-582; deps test seam 93-97,151-152.
  DO NOT touch fleet-go mounts (500-511, 554-568) or marker layers (448-489).

### Step B — delete orphaned files entirely
`MainShipCommand.tsx`, `mainshipCommandMode.ts`, `PortNavPanel.tsx`, `SpaceStopControls.tsx`,
`usePortMoveCommand.ts`, `portMoveCommand.ts`, `useSpaceMoveCommand.ts`, `useSpaceStopCommand.ts`,
`useOsnReadiness.ts`, `osnReadiness.ts`.
- `SpaceMoveTarget.tsx`: remove `SpaceMoveControls` (51-173) + unused imports; **KEEP
  `SpaceMoveTargetMarker` (18-49)** — LIVE, reused by fleet-go target (GalaxyMap.tsx:504-511).

### Step C — prune API + data
- `mainshipApi.ts` remove 8 wrappers by SYMBOL (not region): `sendMainShipExpedition`(335-350),
  `moveMainShipToLocation`(352-367), `commandMainShipSpaceMove`(398-411), `commandMainShipSpaceStop`
  (413-423), `commandMainShipStopTransit`(455-465), `commandMainShipSpaceMoveToLocation`(467-491),
  `fetchOsnMovementReadiness`(493-510), `fetchHeldMainShipFleet`(199-220). KEEP settle wrappers 425-453.
- `spaceMoveCommand.ts`: del controller/`SPACE_MOVE_RPC`/`buildSpaceMoveRpcArgs`/`SpaceMoveResult`.
  **KEEP `classifyPointerGesture`(GalaxyMap:268) + `canonicalizeWorldTarget`(fleetGoTarget:24)** — LIVE.
- `spaceStopCommand.ts`: del controllers/RPCs/`isActiveCoordinateTransit`/`isActiveLegacyOutboundTransit`.
  **KEEP `selectActiveLegacyMovement`** (AppShell.tsx:44 — settle wiring).
- `useGalaxyMapData.ts`: del held-fleet read 184-187, `mainShipHeldFleet` field (64,122,249),
  `fetchHeldMainShipFleet` import (9); optionally `fleetControlEnabled`/`mainShipInFleet`. KEEP
  `catalog.fetchFleetControlEnabled` (TeamMapSend/TeamRosterPanel read it themselves).

## KEEP (proven LIVE — do NOT delete)
settle wrappers + `useSettleDueArrival` + `selectActiveLegacyMovement` (AppShell:44-54, the DRAIN path —
4b-DROP's job, not here); `fetchActiveMainShipSpaceMovement`(mainshipApi:247, GalaxyMap focus/route);
`SpaceMoveTargetMarker`; `classifyPointerGesture`; `canonicalizeWorldTarget`; `repairMainShip`;
`deriveMainShipStatus`. The `mainshipSendEnabled` prop chain into GalaxyMap gates the marker layers —
MUST survive (dropping it = the 93cb823 regression).

## OUT OF SCOPE (S5/S6/S1 own these)
SpaceRouteLine/`shipLayer`, `fleetShipsLayer`, MainShipMarker, resolveMainShipMarker, spaceRouteModel,
mainshipStatusLabel, FleetGoPanel, fleetGoTarget, TeamMapSend, TeamMapStop (S5). ShipStatusCard/
ShipDossier (S6). FleetPosition*/fetchMyFleetPositions/`'berthed'` place (S1).

## S1 lines in mainshipApi.ts to NOT touch
`FleetPositionPlace` union (:125, S1 adds 'berthed'); FleetPositionSegment/FleetPosition (127-149);
fetchMyFleetPositions (151-160); FLEETMAP header (117-123). 4a-post removals are at 199-220 + 335-510 —
no overlap if deleting by symbol.

## Tests / CI
- DELETE: mainshipCommandMode.spec, portMoveCommand.spec, osnReadiness.spec, osnPortNavUi.uispec +
  harness/osnPortNavHarness, galaxyCoordUi.uispec + harness/galaxyCoordHarness + harness/galaxy.html.
- TRIM (keep live exports): spaceMoveTarget.spec (keep SpaceMoveTargetMarker), spaceMoveCommand.spec
  (keep classifyPointerGesture/canonicalizeWorldTarget), spaceStopCommand.spec (keep
  selectActiveLegacyMovement). settleArrival.spec KEEP whole.
- CI: osn-enablement-1b-ui-proof.yml (retire w/ PortNavPanel); verify-osn-s6c.yml:18-19 (point at
  trimmed specs); harness/vite.config.ts (drop portnav/galaxy entries, keep dock). No barrels.

## Two prod drain-asserts BEFORE merge (NO-SOFTLOCK residue)
1. Zero `main_ship_space_movements` with status='moving'.
2. Zero legacy outbound `fleet_movements` in flight for main-ship fleets.

## PR-body caveat (POINT OF NO RETURN — tell the owner)
After 4a-post merges, the flip's one-command SQL rollback is CLIENT-INCOMPLETE — a flag rollback
restores the server movers but not their UI. Intended nature of a post-soak cleanup; state it explicitly.
