# S5 map-UX consolidation — grounded brief (banked 2026-07-18, against main @ 2a81e51)

Consolidate the three scattered on-map fleet-command surfaces into ONE bottom-center
`FleetCommandPanel`. The panel is a SHELL — all verb logic is the existing pure classifiers,
composed, not rewritten. Frontend-only. Net −2 components (−3 with fleetShipsLayer).

## The three surfaces to DELETE (and their mounts)
- **FleetGoPanel** `src/features/map/FleetGoPanel.tsx` — top-right rail, Go/Redirect to a tapped
  point. Mount GalaxyMap.tsx:489-497 (+ import :20). Verb: commandShipGroupGo(gid, fleetGoRpcTarget(view)).
- **TeamMapSend** `src/features/command/TeamMapSend.tsx` — right-side detail aside, Send-to-port +
  HUNT + legacy-dark arms. Mount MapScreen.tsx:219 (+ import :7). Does its OWN 7 fetches (:101-128) —
  DELETE those, feed from shell props.
- **TeamMapStop** `src/features/command/TeamMapStop.tsx` — top-left rail (FIRST = NO-SOFTLOCK), Stop.
  Mount MapScreen.tsx:118-125 (+ import :8). Verb: unifiedEnabled ? commandShipGroupStop : stopShipGroup.
- Also (charter line 674): the redundant per-ship chevron layer `fleetShipsLayer` (mount
  GalaxyMap.tsx:424-434, file src/features/map/fleetShipsLayer.ts, spec tests/galaxyFleetLayer.spec.ts) —
  S1's fleeted-XOR-berthed makes team badges + shipLayer cover all markers. Delete it, or note as
  an S5-follow-up if scoping tight.

## KEEP-and-compose (pure classifiers — the panel composes these, rewrites NOTHING)
- fleetGoTarget.ts: resolveSpaceTapOwner(:38), fleetGoTargetView(:60), fleetGoRpcTarget(:70, the RAW
  wire point — RAW-COORDS LAW), classifyFleetCoordinateGo(:93 → go|redirect|already_here),
  fleetGoButtonLabel/fleetGoSuccessMessage/formatWorldPoint.
- spaceMoveCommand.ts: canonicalizeWorldTarget/roundHalfAwayFromZero(:17-23), classifyPointerGesture(:38).
- teamMove.ts: unifiedMapSendAction(:96 → go|docked_here), teamMapSendAction(:60 legacy — KEEP module),
  buildCommandShipGroupGoArgs/GroupGoTarget(:112, {locationId} XOR {x,y}).
- teamStop.ts: resolveStoppableFleets(:102 → descriptors with sortie flag), groupStopAvailability(:19),
  unifiedStopOutcomeMessage/stopOutcomeMessage/parseUnifiedStopResult(:154-206) — envelope parsers stay
  TWO (0209 boolean vs 0164 count, spec-pinned; do NOT merge).
- teamDestination.ts: teamDestinationKind(:46 → expedition|hunt|null), returnPortOptions(:29).
- teamCombat.ts groupHuntAvailability; teamSend.ts groupSendAvailability.
- territoryAt.ts territoryAt(:28, inclusive, smallest-radius) — Dock gating + "in orbit of X".
- teamReasonMessage.ts (the ONE reject copy map); teamRollup.ts deriveDockedTeamRollups/excludeCombatSortieFleets.
- RPC wrappers (teamApi.ts, unchanged): commandShipGroupGo:214, commandShipGroupStop:225,
  sendShipGroupHunt:270, legacy sendShipGroup:168/moveShipGroup:183/stopShipGroup:194.
  UnifiedGroupFleetLite shape teamApi.ts:93-100.

## THE ONE new file: src/features/map/FleetCommandPanel.tsx
A single bottom-center OverlayPanel (components/ui: OverlayPanel/Button/Badge/Notice/SectionLabel),
props-fed from the shell (NO own fetches), ONE busy/notice pair, ONE run() (FleetGoPanel.tsx:59-73 idiom).

TARGET MODEL — ONE union, lifted to MapScreen (kills the two-selection-source spaghetti):
```ts
type FleetCommandTarget =
  | { kind: 'point'; view: FleetGoTargetView }   // from a space tap
  | { kind: 'port'; locationId: string }          // derived from selectedId when the location is a legal dest
  | null
```
GalaxyMap STOPS owning fleetGoTarget (delete GalaxyMap.tsx:122-123): onPointerUp(:225) becomes
onTargetPoint(world); MapScreen holds the target + derives view = fleetGoTargetView(world). The crosshair
marker (SpaceMoveTargetMarker reuse, GalaxyMap.tsx:453-460, testId fleet-go-target) STAYS in GalaxyMap,
driven by a fleetGoView prop. Port target derives from existing selectedId — NO second selection source
(bare-svg-click already clears selection, GalaxyMap.tsx:281).

LAYOUT (top→bottom, per-fleet rows):
1. STOP — ALWAYS FIRST, never target-gated (NO-SOFTLOCK). For each resolveStoppableFleets descriptor:
   sortie → non-actionable hint (team-sortie-hint-<gid>); else "Stop — hold here" (team-stop-<gid>) →
   unifiedEnabled ? commandShipGroupStop : stopShipGroup, one-click NO confirm (TeamMapStop.tsx:37-40 law).
2. Target context (when target≠null): point → formatWorldPoint(view.canonical) + OOB notice
   (fleet-go-oob when !view.withinBounds); port → port name. "Clear target" (fleet-go-clear).
3. GO/REDIRECT rows (target≠null), per group: point → classifyFleetCoordinateGo(fleet, view.canonical)
   → already_here badge / button (fleet-go-<gid>) submitting commandShipGroupGo(gid, fleetGoRpcTarget(view));
   port → unifiedMapSendAction({dockedLocationId, destinationId}) → docked_here badge / "Send fleet here"
   (team-go-<gid>) submitting commandShipGroupGo(gid, {locationId}). Redirect verb comes from the envelope
   (redirected:true), never client intent.
4. DOCK rows (no target needed): per fleet with location_mode==='space' AND territoryAt(space_xy, locations)
   hits a dockable port (orbit.location_type==='trade_outpost') → "in orbit of {port}" + "Dock at {port}"
   → v1 = commandShipGroupGo(gid, {locationId: orbit.id}) (existing instant go-to-port; arrival docks via
   0208 location branch). HEADER-FLAG the S4 dependency: when S4/timed_docking lands, this submit repoints
   to the dock RPC + a countdown — the shell doesn't change.
5. HUNT (port target whose teamDestinationKind==='hunt'): absorb TeamMapSend's hunt arm VERBATIM —
   two-click armed confirm carrying the armed location id, groupHuntAvailability, returnPortOptions picker
   (fleet-return-port-picker), sendShipGroupHunt(gid, locationId, returnLocationId). (Absorbing keeps ONE
   surface; leaving hunt in the aside would keep a 2nd command surface — absorb it.)

PLACEMENT: add 'bottom-center' to OVERLAY_SLOTS + SLOT_POS ('bottom-3 left-1/2 -translate-x-1/2') +
SLOT_ALIGN ('items-center justify-end') in src/components/ui/overlayLayout.ts:5,11-26 (pure; the
uniqueness/position loops in tests/uiPrimitives.spec.ts:82-110 extend automatically). Cap height + internal
scroll BELOW the Stop section so Stop never scrolls away. Mount in MapScreen (beside :140) behind
TEAM_COMMAND_ENABLED, onCommanded={refresh}. Panel mount predicate:
`stoppable.length>0 || target!==null || dockableParkedFleets.length>0`.

## NO-SOFTLOCK (preserve exactly)
Today TeamMapStop is FIRST in the top-left rail, state-predicated only (resolveStoppableFleets.length>0),
independent of target/tap, one-click. The new panel MUST keep Stop rendering whenever any owned fleet is
in flight, FIRST, never behind a scroll, never gated on target/selectedId.

## Tests
KEEP untouched (pure): fleetGoTarget.spec, teamStop.spec, teamSend.spec, teamDestination.spec,
territoryAt.spec, teamMarkers.spec, spaceMoveCommand.spec, spaceMoveTarget.spec (pins fleet-go-target
testid reuse — marker survives). Comment-only: teamMove.spec.ts:52 (repoint to FleetCommandPanel).
EXTEND uiPrimitives.spec (82-110) with bottom-center position/align asserts. NEW FleetCommandPanel spec:
(a) Stop rows render with NO target, (b) Stop is FIRST, (c) Dock row only for space+territory-port hit,
(d) point rows use fleetGoRpcTarget (raw wire). No mount tests exist for the 3 deleted panels (grepped).
Preserve ALL testids: team-stop-/team-sortie-hint-/fleet-go-/fleet-go-here-/fleet-go-clear/fleet-go-oob/
fleet-go-target-readout/team-go-/team-hunt-return-/fleet-return-port-picker.

## Spaghetti risks
1. Second selection source: unify to the FleetCommandTarget union in MapScreen; keep selectedId for the
   info aside, derive {kind:'port'} from it.
2. TeamMapSend is also HUNT + legacy arms — absorb hunt; the panel may be unified-arm-only (unified flag
   is LIVE in prod; 4b-DROP retires legacy) but KEEP teamMove/teamSend classifiers. If un-flip insurance
   wanted, gate the row arm on fleetMovementUnifiedEnabled like TeamMapStop.tsx:146.
3. Command-tab: TeamRosterPanel has ZERO movement verbs (charter §2a) — do NOT add movement there.
4. Stop must NOT inherit a target gate (`if(!target) return null` would soft-lock the brake).
5. ONE busy key namespace: prefix keys (stop:/go:/dock:/hunt:) — one in-flight command at a time.

## Green gates
tsc -b 0 · vite build · eslint no NEW errors (base has ~14 pre-existing out-of-scope) · the kept +
new specs pass. The aside (MapScreen.tsx:149-221) becomes read-only location info after TeamMapSend goes.
