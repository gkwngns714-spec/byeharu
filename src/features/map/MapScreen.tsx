import { useEffect, useState } from 'react'
import { useShellState } from '../../app/shellState'
import { GalaxyMap } from './GalaxyMap'
import type { MapLocation } from './mapTypes'
import { TYPE_LABEL, dangerLabel, rewardLabel } from './locationDisplay'
import { ExplorationPanel } from '../exploration/ExplorationPanel'
import { FleetCommandPanel } from './FleetCommandPanel'
import { fleetGoTargetView } from './fleetGoTarget'
import type { FleetCommandTarget } from './fleetCommandModel'
import { teamDestinationKind } from '../command/teamDestination'
import { TEAM_COMMAND_ENABLED } from './osnReleaseGates'
import { MiningPanel } from '../mining/MiningPanel'
import type { MiningField } from '../mining/miningTypes'
import { WorldEventsPanel } from '../events/WorldEventsPanel'
import { TelegraphBanner } from '../combat/TelegraphBanner'
import { CombatMapCard } from './CombatMapCard'
import { FleetStatusPanel } from './FleetStatusPanel'
import { ambushEncounterNotices } from './ambushEncounterNotice'
import { nearMissNotices, NEAR_MISS_MAP_WINDOW_MS } from './nearMissNotice'
import { distance } from '../../game/movement/travelPreview'
import type { WorldCoord } from './openSpaceTransform'
import { Badge, Button, OverlayPanel, OverlayRail, Skeleton, StatRow, type BadgeTone } from '../../components/ui'
import { PirateInterceptPanel } from './PirateInterceptPanel'
import { ZoneInfoPanel } from './ZoneInfoPanel'
import { buildZoneInfo, zoneAtPoint } from './zoneInfoModel'
import type { DangerZoneLite } from './pirateApi'

// UI-REBUILD (2b, Map interior) — the Map destination: THE primary play surface. The galaxy canvas
// stays the hero; the location detail panel now speaks the shared design language (IDENTITY →
// RIGHT NOW → DETAILS, StatRow rows, plain player language — the raw status/difficulty/tier/
// pressure/coordinate internals are humanized or dropped, see locationDisplay.ts), and the
// server-lit feature panels ride ONE overlay rail instead of floating as raw flow cards. Shared
// polled data comes from the shell; the arrival settle lives in AppShell — never here.
//
// S5 MAP-UX: the three scattered fleet-command surfaces (FleetGoPanel top-right, TeamMapSend in
// this aside, TeamMapStop in the top-left rail) are CONSOLIDATED into the ONE bottom-center
// FleetCommandPanel mounted below. This screen owns the ONE selection source for it — the
// FleetCommandTarget union: a double-tap (GalaxyMap's onDoubleTapPoint) yields the point target; the
// existing marker selection (selectedId) DERIVES the port target — never a second selection state.
// NO-SOFTLOCK is carried by the panel's model (Stop first, state-predicated only) + the AppShell
// settle. The detail aside below is now READ-ONLY location info.

// ── Player-facing location display ───────────────────────────────────────────────────────────────
// Humanized: location_type → a plain kind; base_difficulty → a danger word; reward_tier → a reward
// word — the pure mappings live in locationDisplay.ts (ONE home; DIFFICULTY-DISPLAY moved them out
// of this file and extended the bands past the old High/Rich saturation). DROPPED as dev-internal
// noise: raw coordinates, `status` (get_world_map returns only active rows — the row could never
// read anything else), pressure/danger_modifier decimals, and the active-fleets debug count. The
// raw difficulty/tier NUMBERS return as mono metadata next to the words (decision-relevant once
// zones spread across a 0–60 range), and min_power_required gets its own row when a gate exists.
const typeBadge = (l: MapLocation): { tone: BadgeTone; text: string } =>
  l.location_type === 'trade_outpost'
    ? { tone: 'accent', text: 'Port' }
    : l.activity_type === 'none'
      ? { tone: 'success', text: 'Safe' }
      : { tone: 'danger', text: 'Hostile' }

export function MapScreen() {
  const {
    map: {
      loading, error, locations, meta, mainShip, movements,
      teamGroups, teamGroupsOk, teamGroupMap, dockedTeamRollups, fleetPositions,
      fleetMovementUnifiedEnabled, unifiedGroupFleets, combatSortieFleets,
      launchFromDockEnabled, fleetControlEnabled, timedDockingEnabled,
      miningFields, miningExtractRadius,
      pirateInterceptEnabled, dangerZones, refresh,
    },
    // COMBAT-S4: the shell's already-mounted combat poll (useCombat, ~1.5s — the tick cadence). Its
    // units/events feed the map's spatial-combat layer; dark today (no positioned rows exist while
    // spatial_combat_enabled is off) → the layer renders nothing.
    combat,
    // THE NEAR MISS — `game` is taken whole for its interceptMisses AND its movements, which must
    // come from ONE cycle: a miss becomes announceable exactly when its leg leaves the active list
    // (nearMissNotice rule 3), so pairing the two across two different polls (game 3s, map 4s)
    // would make the notice flicker on and off at the seam. useGameState fetches both in one wave.
    game,
    selection,
  } = useShellState()
  const [selectedId, setSelectedId] = useState<string | null>(null)
  // S5 MAP-UX: the fleet's tapped open-space destination (RAW world point — the wire value). The
  // ONLY point-target state; the port target derives from selectedId below (ONE selection source).
  const [pointTarget, setPointTarget] = useState<WorldCoord | null>(null)
  // MINING-FIELD-MARKERS: a tapped field's OWN selection (a field is not a MapLocation, so it is not
  // part of selectedId's id-space) — mutually exclusive with the location selection + the point
  // target below, same "only one live selection" posture as the rest of this screen.
  const [selectedFieldName, setSelectedFieldName] = useState<string | null>(null)
  // PIRATE INTERCEPT: the route-planner tap mode + its accumulated waypoints. 'off' by default — the
  // map's tap handling is byte-identical to today until the player arms route plotting via
  // PirateInterceptPanel (mounted inside the command hub while the flag is lit). Zone-DRAWING is a
  // dev/admin authoring tool and has no player UI here, so 'draw' is not a player mode.
  const [pirateMode, setPirateMode] = useState<'off' | 'route'>('off')
  const [pirateDraftPoints, setPirateDraftPoints] = useState<WorldCoord[]>([])
  // THE NEAR MISS — a coarse clock for the map alert's expiry window, the house idiom
  // (GalaxyMap/ActiveCombatPanel/TelegraphBanner). Reading `Date.now()` in the render body would be
  // an impure read; 30s is far finer than a ten-minute edge needs and costs one setState a minute.
  const [nearMissNowMs, setNearMissNowMs] = useState(() => Date.now())
  useEffect(() => {
    const iv = setInterval(() => setNearMissNowMs(Date.now()), 30_000)
    return () => clearInterval(iv)
  }, [])
  // CLEAN-MAP COMMAND HUB — the ONE authority (ONE hub, TWO stages):
  //   stage 1 (hubView='menu') — a double-tap on empty space floats a COMPACT ICON CLUSTER AT the
  //     double-tapped point ON THE MAP: a couple of small tappable icons (Send fleet + Pirate
  //     intercept — plus a Mining icon ONLY when the point is inside a field's range). NO crosshair
  //     yet — the double-tap places nothing on the map, it only asks "what do you want to do here?".
  //   stage 2 (hubView='fleet'|'pirate'|'mining') — tapping an icon opens THAT one detailed panel,
  //     with a back arrow (→ icons) + a ✕ (→ clean map). Choosing the Send icon is what PLACES the
  //     go-destination crosshair (pointTarget) — the destination is a consequence of choosing to send,
  //     never of the double-tap itself. Pirate/Mine open with NO crosshair.
  // hubOpen is presence (the ONE on/off); hubView is the stage; hubPoint is the double-tapped WORLD
  // point (drives the in-range mining check + becomes the send destination); hubScreen is the SCREEN
  // px of the tap (relative to the map box) that anchors the stage-1 icon cluster over that point.
  const [hubOpen, setHubOpen] = useState(false)
  const [hubView, setHubView] = useState<'menu' | 'fleet' | 'pirate' | 'mining' | 'zone'>('menu')
  const [hubPoint, setHubPoint] = useState<WorldCoord | null>(null)
  const [hubScreen, setHubScreen] = useState<{ x: number; y: number } | null>(null)
  // ZONE INFO — which danger zone's panel is open, held as an ID and re-derived from the live zone
  // list below. Deliberately NOT the row: the list re-polls, and a captured row would go stale the
  // moment a zone is edited (its ring/name are exactly what the panel shows). Keeping the id means
  // the live read stays the one source, and a zone that is deleted or deactivated simply stops
  // resolving — the panel closes itself instead of describing something that no longer exists.
  const [zoneInfoId, setZoneInfoId] = useState<string | null>(null)
  // ZONE FOLD — the zone (if any) whose ring CONTAINS the double-tapped point. Non-null → the icon
  // menu offers "What's here". Exactly the shape the mining fold already uses (tapFieldInRange), and
  // keyed on hubPoint for the same reason: the offer is decided by WHERE the player double-tapped.
  //
  // The containment decision lives in the pure model (zoneInfoModel.zoneAtPoint) with the rest of the
  // zone-info wording, so it is unit-pinned and there is no second copy of the geometry here.
  const tapZone: DangerZoneLite | null = zoneAtPoint(hubPoint, dangerZones)
  // The double-tap summon (GalaxyMap.onDoubleTapPoint): remember WHERE (world + screen px), drop any
  // marker/field selection, open the hub on its MENU stage. Deliberately does NOT set pointTarget — no
  // crosshair is placed until the player actually taps the Send icon (openFleetPanel below).
  const openHubAt = (world: WorldCoord, screen: { x: number; y: number }) => {
    setHubPoint(world)
    setHubScreen(screen)
    setHubView('menu')
    setSelectedId(null)
    setSelectedFieldName(null)
    // A fresh summon retires any open zone panel — otherwise a zone would stay highlighted on the map
    // with the icon menu (not its panel) showing, i.e. a highlight with nothing explaining it.
    setZoneInfoId(null)
    setHubOpen(true)
  }
  // Stage-2 openers. "Send fleet here" is the ONLY one that places the go-destination: it sets the SAME
  // pointTarget the fleet command + crosshair consume, from the remembered double-tap point.
  const openFleetPanel = () => {
    if (hubPoint) setPointTarget(hubPoint)
    setHubView('fleet')
  }
  const openPiratePanel = () => setHubView('pirate')
  const openMiningPanel = () => setHubView('mining')
  // ZONE INFO — a stage-2 opener exactly like the other three, reached from the icon menu when the
  // double-tapped point lies inside a zone (tapZone below). It is NOT its own gesture any more: the
  // zone blob used to own a click, which stole the map's double-tap across the whole zone area and so
  // made it impossible to send a fleet to a point inside a zone. One gesture, one hub. Full account in
  // dangerZoneLayer's header.
  const openZonePanel = () => {
    if (tapZone) setZoneInfoId(tapZone.id)
    setHubView('zone')
  }
  // The ONE dismissal: ✕ closes the hub AND returns the map to plain navigation (clear the point/
  // crosshair and disarm any pirate tap mode + draft).
  const closeHub = () => {
    setHubOpen(false)
    setHubView('menu')
    setHubPoint(null)
    setHubScreen(null)
    setPointTarget(null)
    // PORT-SEND: a port summon's destination IS the marker selection, so the ONE dismissal has to
    // clear that too — otherwise ✕ would leave a live destination with no surface left to act on it.
    setSelectedId(null)
    setPirateMode('off')
    setPirateDraftPoints([])
    // ZONE INFO: the ✕ must also drop the open zone, or the map would keep a zone highlighted with
    // no panel explaining why.
    setZoneInfoId(null)
  }
  // Back arrow → the button menu: drop the crosshair/target and disarm any pirate draft so the menu is
  // a clean slate again (re-choosing Send re-places the destination). A PORT summon has NO icon menu
  // behind it (nothing was double-tapped, so hubScreen is null) — there the same control is simply the
  // dismissal, and the header renders no arrow at all (see the stage-2 header below).
  const backToMenu = () => {
    if (hubScreen === null) {
      closeHub()
      return
    }
    setHubView('menu')
    setPointTarget(null)
    setPirateMode('off')
    setPirateDraftPoints([])
    setZoneInfoId(null)
  }

  const selected = locations.find((l) => l.id === selectedId) ?? null
  const selMeta = selectedId ? meta[selectedId] : null
  const selectedField: MiningField | null = miningFields.find((f) => f.name === selectedFieldName) ?? null

  // ZONE INFO — resolved from the LIVE zone list every render (see the zoneInfoId comment above), so
  // an edited zone re-describes itself and a removed one resolves to null: the panel and the map's
  // highlight both fall away together, with no stale copy to clean up.
  const zoneInfoRow = zoneInfoId ? (dangerZones.find((z) => z.id === zoneInfoId) ?? null) : null
  const zoneInfo = zoneInfoRow ? buildZoneInfo(zoneInfoRow, locations) : null

  // Selecting a marker retires any live point target (never two live targets); a bare-space tap
  // already clears the selection on GalaxyMap's own svg click path — the two stay exclusive by
  // construction. NB the svg click that FOLLOWS a space tap calls onSelect(null), so clearing the
  // point target here is gated on an actual (non-null) marker selection.
  //
  // PORT-SEND (owner play-test, verbatim: "i cannot even send any ship to a city — haven, slagworks,
  // driftwatch because there is no UI"): TAPPING A PORT IS NOW A SUFFICIENT GESTURE. It was not
  // before — the send row only mounts while the hub is on its fleet stage, and the ONLY way there was
  // double-tap EMPTY SPACE → Send icon → then tap the port, because openHubAt clears the selection, so
  // the obvious order (pick the port first) could never work. The fix COMPOSES the same ONE hub
  // authority rather than forking a second command surface: no new state, no button in the read-only
  // aside — the port target still DERIVES from selectedId exactly as before, and this only opens the
  // hub on the stage that consumes it. hubPoint/hubScreen are cleared because a port summon has no
  // double-tapped map point behind it (no crosshair to place, no icon menu to go back to), and any
  // armed pirate draft is disarmed so the map's tap handling matches the stage that is now showing.
  const handleSelect = (id: string | null) => {
    setSelectedId(id)
    if (id !== null) {
      setPointTarget(null)
      setSelectedFieldName(null)
      const loc = locations.find((l) => l.id === id)
      if (TEAM_COMMAND_ENABLED && loc && teamDestinationKind(loc) !== null) {
        setHubPoint(null)
        setHubScreen(null)
        setPirateMode('off')
        setPirateDraftPoints([])
        setHubView('fleet')
        setHubOpen(true)
      }
    }
  }
  const handleSelectMiningField = (name: string | null) => {
    setSelectedFieldName(name)
    if (name !== null) setSelectedId(null)
  }

  // PIRATE INTERCEPT: appends a tapped point to the route draft, capped at 3 waypoints + 1 final = 4.
  // Only fires while pirateMode is 'route' — with the mode 'off' a single tap does nothing and a
  // double-tap summons the hub, so this never runs then.
  const handlePirateTap = (world: WorldCoord) => {
    setPirateDraftPoints((pts) => (pts.length >= 4 ? pts : [...pts, world]))
  }

  // The point target resolved ONCE (raw + canonical preview + bounds verdict); feeds both the
  // GalaxyMap crosshair marker and the command panel's target union.
  const pointView = pointTarget ? fleetGoTargetView(pointTarget) : null
  // THE FleetCommandTarget union — point (from the tap) XOR port (derived from the existing
  // selectedId when the location is a legal fleet destination) XOR null. No second selection state.
  const target: FleetCommandTarget = pointView
    ? { kind: 'point', view: pointView }
    : selected && teamDestinationKind(selected) !== null
      ? { kind: 'port', locationId: selected.id }
      : null

  // MINING FOLD: the field (if any) whose extraction range contains the DOUBLE-TAPPED point — SAME
  // geometry as the map's range ring (miningFieldRangeLayer: within `miningExtractRadius` world-units
  // of the field centre, the shared `distance` helper, never a second formula). Non-null → the menu
  // offers a "Mine here" button; pressing it opens the mining surface. Keyed on hubPoint (not
  // pointTarget) so the button is decided by WHERE the player double-tapped, before any crosshair.
  const tapFieldInRange: MiningField | null =
    hubPoint && Number.isFinite(miningExtractRadius) && miningExtractRadius > 0
      ? (miningFields.find((f) => distance(hubPoint.x, hubPoint.y, f.space_x, f.space_y) <= miningExtractRadius) ?? null)
      : null

  // 4C-CLIENT: the legacy spatial_state / space-movement fields left the key with the schema they
  // read — the ship's own status transition still ticks a refetch.
  const panelLifecycleKey = `${mainShip?.status ?? 'n'}`

  return (
    <div data-testid="galaxy-map-screen" className="relative flex h-full flex-col overflow-hidden md:flex-row">
      {/* Map area — the hero */}
      <div className="relative flex-1 p-2">
        {loading && (
          // UI R1: the design-system Skeleton stands in for the map canvas while the world loads.
          <div data-testid="galaxy-map-loading" className="relative h-full w-full">
            <Skeleton className="h-full w-full rounded-card" />
            <p className="absolute inset-0 flex items-center justify-center text-sm text-ink-muted" role="status">
              Loading galaxy…
            </p>
          </div>
        )}
        {!loading && error && (
          <div data-testid="galaxy-map-error" className="flex h-full items-center justify-center px-6 text-center">
            <div>
              <p className="font-medium text-danger">Couldn't load the map</p>
              <p className="mt-1 text-sm text-ink-muted">{error}</p>
            </div>
          </div>
        )}
        {!loading && !error && locations.length === 0 && (
          <div className="flex h-full items-center justify-center px-6 text-center text-ink-muted">
            No locations are visible yet.
          </div>
        )}
        {!loading && !error && locations.length > 0 && (
          // ONE positioned wrapper the size of the map canvas: every screen-level overlay shares the
          // SAME slot coordinate frame as GalaxyMap's own overlays (UI R1 overlay-slot layout).
          <div className="relative h-full w-full">
            <GalaxyMap
              locations={locations}
              movements={movements}
              teamGroups={teamGroups}
              teamGroupMap={teamGroupMap}
              fleetPositions={fleetPositions}
              unifiedGroupFleets={unifiedGroupFleets}
              combatSortieFleets={combatSortieFleets}
              fleetGoView={pointView}
              onDoubleTapPoint={openHubAt}
              selectedId={selectedId}
              onSelect={handleSelect}
              miningFields={miningFields}
              miningExtractRadius={miningExtractRadius}
              selectedMiningFieldName={selectedFieldName}
              onSelectMiningField={handleSelectMiningField}
              dangerZones={dangerZones}
              // ZONE INFO: this switch makes the blobs hover + name themselves. They are NOT clickable —
              // the info panel is reached from the command hub's "What's here", so the map's own
              // double-tap and pirate taps keep working inside a zone.
              zonesInteractive
              selectedDangerZoneId={zoneInfoId}
              combatUnits={combat.units}
              combatEvents={combat.events}
              // The encounters those units belong to — they carry the engagement anchor that says
              // WHERE each fight is, which the in-combat fleet badge stands on.
              combatEncounters={combat.encounters}
              pirateMode={pirateMode}
              pirateDraftPoints={pirateDraftPoints}
              onPirateTap={handlePirateTap}
            />
            {/* ██ THE TOP-LEFT RAIL — and THE REACH LAW ██
                Corner map: zoom top-right · legend bottom-left · command hub bottom-right ·
                alerts/features/fleets top-left. One container per corner, so nothing collides at
                hand-tuned offsets and the combat card can never bury the zoom buttons again.

                Owner, playing the LIVE game 2026-08-08: "right now i can't press hunt." This rail
                used to carry `max-h-[60%] overflow-y-auto` RIGHT HERE, so the whole stack — notices,
                exploration, combat card, fleet readout — shared ONE capped scroll box, and whatever
                came LAST in it was what got cut. At 1440x675 that was the Hunt button: 8 of its 44
                pixels inside a 334px box holding 386px of content. Enabled, present, unpressable.
                The close-call notice that tipped it over only appears NEAR A DANGER ZONE — exactly
                when the player needs Hunt.

                So the cap now lands on the INFORMATION and never on the ACTION:
                  · `children` = the ACCOUNT — notices. Pure text; it may scroll, because losing
                    sight of a sentence costs nothing.
                  · `reach`    = every panel that carries a CONTROL. Pinned outside any scroll
                    region by the primitive itself; the account collapses before a button does.
                The rail takes NO height cap from this call site — it bounds itself to the map box,
                and tests/actionsAreReachable.spec.ts fails the build if anyone puts one back. This
                is the rule the BRAKE already had (FleetCommandPanel.tsx:542 — "Stop renders OUTSIDE
                the scroll container") generalised from one button to every action.

                Every panel keeps its server-lit `return null` gate verbatim: a dark capability
                renders nothing and the pointer-transparent rail never intercepts map gestures. */}
            <OverlayRail
              slot="top-left"
              className="w-72 max-w-[calc(100vw-5rem)]"
              reach={
                <>
                  {/* EXPLORATION-P11 — the Scan action; legal only settled in space (server-lit).
                      It is in `reach` because it has a BUTTON: the law is about controls, not about
                      which feature a panel belongs to. MINING-P12's persistent panel was REMOVED
                      from this rail in the clean-map redesign — the extract surface folds into the
                      double-tap command hub, appearing only when the summon point sits inside a
                      mining field's range (see the hub below). */}
                  <ExplorationPanel
                    lifecycleKey={panelLifecycleKey}
                    mainShipId={mainShip?.main_ship_id ?? null}
                    shipStatus={mainShip?.status}
                    shipSpatialState={null}
                  />
                  {/* COMBAT — the fight is a thing happening in SPACE, so its live standing belongs
                      on the MAP, not only on the ops screen. Reads the shell's already-polled combat
                      state (no new fetch); renders nothing when nothing is fighting (clean-map law
                      #1). A SECOND VIEW of the same server rows — ActiveCombatPanel stays the
                      Mission-side detail. It carries the ONE RetreatControl: leaving a fight is the
                      most reachable thing on this screen, so it is in `reach` by definition. */}
                  <CombatMapCard
                    encounters={combat.encounters}
                    units={combat.units}
                    ticks={combat.ticks}
                    autoExit={combat.autoExit}
                    onChanged={() => void combat.refresh()}
                  />
                  {/* MY FLEETS, ON THE MAP (owner, 2026-08-04, playing: "in map, i want to see
                      information regarding fleet, where it is, stats, what it is currently doing. I
                      am in snare but in no fight is occuring, i want also a toggle combat on map…").

                      LAST in the stack, which is precisely why it was the victim — and now precisely
                      why it must be pinned: it carries the one action slot per fleet (into the fight
                      under its feet, or out of the one it is in). Props only, from reads the shell
                      already polls: no new fetch, no new poll, no state of its own.

                      The hunt handoff is the SAME one the command panel and the zone panel use —
                      `handleSelect`, the map's own marker-selection path — so a fleet parked on top
                      of a fight reaches the EXISTING hunt control by exactly the route a tap on that
                      site's marker takes. No second hunt path, no new RPC. */}
                  <FleetStatusPanel
                    groups={teamGroups}
                    membership={teamGroupMap}
                    positions={fleetPositions}
                    locations={locations}
                    movements={movements}
                    unifiedFleets={unifiedGroupFleets}
                    dangerZones={dangerZones}
                    encounters={combat.encounters}
                    units={combat.units}
                    fleetControlEnabled={fleetControlEnabled}
                    onSelectHuntSite={(locationId) => handleSelect(locationId)}
                    onCombatChanged={() => void combat.refresh()}
                  />
                </>
              }
            >
              {ambushEncounterNotices({ encounters: combat.encounters, locations }).map((n) => (
                <OverlayPanel
                  key={n.encounterId}
                  tone="danger"
                  data-testid={`map-ambush-notice-${n.encounterId}`}
                  className="w-64"
                >
                  <p className="text-xs font-semibold text-danger">{n.text}</p>
                </OverlayPanel>
              ))}
              {/* THE NEAR MISS — the ambush notice's missing twin, in the same rail because it is
                  the same news: what the pirates did to you on that trip. An ambush that HITS has
                  always been loud (an encounter, a map card, a report); an ambush that MISSES said
                  nothing at all, which with a ~55% roll is indistinguishable from a broken game —
                  and is exactly what the owner hit. Reads shell state only (no fetch here), and
                  expires by NEAR_MISS_MAP_WINDOW_MS so the clean map is never permanently occupied.

                  The clock is the 30s `nearMissNowMs` above, not a render-time `Date.now()`: the
                  window has to keep expiring even if the shell poll stalls, and an impure read in
                  the render body is unstable the moment React re-renders for another reason. */}
              {nearMissNotices({
                misses: game.interceptMisses,
                locations,
                activeMovementIds: game.movements.map((m) => m.id),
                nowMs: nearMissNowMs,
                withinMs: NEAR_MISS_MAP_WINDOW_MS,
                limit: 3,
              }).map((n) => (
                <OverlayPanel key={n.id} data-testid={`map-near-miss-${n.id}`} className="w-64">
                  <p className="text-xs font-semibold text-warning">{n.text}</p>
                </OverlayPanel>
              ))}
            </OverlayRail>
            {/* PHASE20-POLISH — dark world-events feed (top-center slot; server empties it while dark). */}
            <WorldEventsPanel lifecycleKey={panelLifecycleKey} />
            {/* COMBAT-S2 TELEGRAPH — the pre-combat warning beat (top-center, urgent). Renders nothing
                unless the caller has a telegraphed encounter; while combat_telegraph_enabled is dark the
                pending table is empty so this is invisible (fail-closed by data). Flee withdraws the
                fleet home, then re-polls the map + ship reads. */}
            <TelegraphBanner
              onChange={() => {
                void refresh()
                void selection.refresh()
              }}
            />
            {/* CLEAN-MAP COMMAND HUB — TWO stages, ONE authority (hubOpen presence + hubView stage).
                While `hubOpen` is false the map is unobstructed — nothing below mounts. */}

            {/* STAGE 1 — the compact ICON CLUSTER, floated AT the double-tapped point ON THE MAP (not a
                corner menu): a small row of tappable icons for what the player can do at this spot. NO
                crosshair yet (the double-tap placed nothing on the map). Each icon is gated the SAME
                way its panel is, so a dark capability shows no icon; the Mine icon shows only when the
                point sits inside a field's range. Anchored by hubScreen (the tap px, relative to this
                map box) and centered ON the point via the -50%/-50% pill transform. The outer wrapper
                is pointer-transparent (its empty margin never blocks map gestures); the pill re-enables
                pointer events. A lone ✕ returns to a clean map. */}
            {hubOpen && hubView === 'menu' && hubScreen && (
              <div
                data-testid="map-command-icons"
                className="pointer-events-none absolute z-20"
                style={{ left: hubScreen.x, top: hubScreen.y }}
              >
                <div className="pointer-events-auto flex -translate-x-1/2 -translate-y-1/2 items-center gap-1 rounded-full border border-edge bg-surface/95 p-1 shadow-overlay backdrop-blur">
                  {TEAM_COMMAND_ENABLED && (
                    <button
                      type="button"
                      onClick={openFleetPanel}
                      data-testid="map-action-send"
                      aria-label="Send fleet here"
                      title="Send fleet here"
                      className="flex h-11 w-11 items-center justify-center rounded-full text-accent transition hover:bg-accent/15 active:bg-accent/25"
                    >
                      <svg viewBox="0 0 24 24" className="h-5 w-5" aria-hidden="true">
                        {/* paper-plane / send */}
                        <path d="M2.5 21.5 22 12 2.5 2.5v7L16 12 2.5 14.5z" fill="currentColor" />
                      </svg>
                    </button>
                  )}
                  {tapFieldInRange && (
                    <button
                      type="button"
                      onClick={openMiningPanel}
                      data-testid="map-action-mine"
                      aria-label="Mine here"
                      title="Mine here"
                      className="flex h-11 w-11 items-center justify-center rounded-full text-warning transition hover:bg-warning/15 active:bg-warning/25"
                    >
                      <svg viewBox="0 0 24 24" className="h-5 w-5" aria-hidden="true">
                        {/* gem hexagon — mirrors the mining-field glyph */}
                        <polygon points="23.3,12 16.1,24 8,24 0.7,12 8,0 16.1,0" fill="currentColor" />
                      </svg>
                    </button>
                  )}
                  {/* ZONE INFO — offered only when the double-tapped point is INSIDE a zone, the same
                      way "Mine here" is offered only in range. This is the whole gesture for zone info:
                      the blob itself is not clickable, because a click on it stole the map's double-tap
                      and made a point inside a zone unreachable as a destination. */}
                  {tapZone && (
                    <button
                      type="button"
                      onClick={openZonePanel}
                      data-testid="map-action-zone"
                      aria-label="What's here"
                      title="What's here"
                      className="flex h-11 w-11 items-center justify-center rounded-full text-danger transition hover:bg-danger/15 active:bg-danger/25"
                    >
                      <svg viewBox="0 0 24 24" className="h-5 w-5" fill="none" stroke="currentColor" strokeWidth={2} aria-hidden="true">
                        {/* info disc — "tell me about this place" */}
                        <circle cx="12" cy="12" r="9" />
                        <line x1="12" y1="11" x2="12" y2="16.5" />
                        <circle cx="12" cy="7.75" r="1.1" fill="currentColor" stroke="none" />
                      </svg>
                    </button>
                  )}
                  {pirateInterceptEnabled && (
                    <button
                      type="button"
                      onClick={openPiratePanel}
                      data-testid="map-action-pirate"
                      /* PLAIN-WORDS: the action is plotting a course around danger — "Pirate
                         intercept" named the SERVER mechanic, not what the button does. */
                      aria-label="Plot a route"
                      title="Plot a route"
                      className="flex h-11 w-11 items-center justify-center rounded-full text-danger transition hover:bg-danger/15 active:bg-danger/25"
                    >
                      <svg viewBox="0 0 24 24" className="h-5 w-5" fill="none" stroke="currentColor" strokeWidth={2} aria-hidden="true">
                        {/* crosshair — intercept target */}
                        <circle cx="12" cy="12" r="7" />
                        <line x1="12" y1="1.5" x2="12" y2="5.5" />
                        <line x1="12" y1="18.5" x2="12" y2="22.5" />
                        <line x1="1.5" y1="12" x2="5.5" y2="12" />
                        <line x1="18.5" y1="12" x2="22.5" y2="12" />
                        <circle cx="12" cy="12" r="1.5" fill="currentColor" stroke="none" />
                      </svg>
                    </button>
                  )}
                  {!TEAM_COMMAND_ENABLED && !pirateInterceptEnabled && !tapFieldInRange && !tapZone && (
                    <span className="px-2 text-xs text-ink-muted">Nothing to do here</span>
                  )}
                  {/* dismiss — return to a clean map */}
                  <button
                    type="button"
                    onClick={closeHub}
                    data-testid="map-command-icons-close"
                    aria-label="Close"
                    title="Close"
                    className="flex h-11 w-11 items-center justify-center rounded-full text-ink-faint transition hover:bg-edge/40 hover:text-ink active:bg-edge/60"
                  >
                    ✕
                  </button>
                </div>
              </div>
            )}

            {/* STAGE 2 — the one chosen detailed panel (bottom-right, never the map's center — the
                play-test rule), under a slim header: a back arrow (← the icons) and a ✕ (clean map).
                The title NAMES the action. Reuses the existing FleetCommand/Mining/PirateIntercept
                panels verbatim. */}
            {/* THE COMMAND HUB — every single thing in it is a CONTROL (the header's ✕ is the only
                way to dismiss the panel; the panel below is nothing but verbs), so the whole rail
                rides `reach` and NOTHING here scrolls. It used to carry `max-h-[85%]
                overflow-y-auto` at this call site, which put a second scroll ancestor ABOVE
                FleetCommandPanel's own careful stop-outside-the-scroll split and silently defeated
                it: the brake was pinned inside a box that could itself be scrolled away. One
                authority now — the panel caps and scrolls its own SECTIONS (its account), the rail
                caps nothing. See components/ui/overlayLayout.ts for the law. */}
            {hubOpen && hubView !== 'menu' && (
              <OverlayRail
                slot="bottom-right"
                className="max-w-[calc(100vw-1.5rem)]"
                reach={
                  <>
                    <OverlayPanel data-testid="map-command-panel-header" className="flex w-72 max-w-full items-center gap-2">
                      {/* PORT-SEND: the arrow only exists when there IS an icon menu behind this stage
                          (a double-tap summon). A port summon opens straight on the fleet stage, so a
                          "back" there would lead to an empty menu — the ✕ is the only exit it needs. */}
                      {hubScreen !== null && (
                      <button
                        type="button"
                        onClick={backToMenu}
                        aria-label="Back to actions"
                        title="Back"
                        data-testid="map-command-back"
                        className="-ml-1 flex h-7 w-7 shrink-0 items-center justify-center rounded text-ink-faint transition hover:bg-edge/40 hover:text-ink"
                      >
                        ←
                      </button>
                      )}
                      <p className="min-w-0 flex-1 truncate text-sm font-semibold text-ink">
                        {hubView === 'fleet'
                          ? 'Send fleet'
                          : hubView === 'mining'
                            ? 'Mine here'
                            : hubView === 'zone'
                              ? // The zone NAMES itself in the header, so the panel body needs no title row.
                                (zoneInfo?.title ?? 'Danger zone')
                              : 'Plot a route'}
                      </p>
                      <button
                        type="button"
                        onClick={closeHub}
                        aria-label="Close"
                        title="Close"
                        data-testid="map-command-panel-close"
                        className="-mr-1 flex h-7 w-7 shrink-0 items-center justify-center rounded text-ink-faint transition hover:bg-edge/40 hover:text-ink"
                      >
                        ✕
                      </button>
                    </OverlayPanel>

                    {/* THE fleet-command surface: Stop (NO-SOFTLOCK, first, state-predicated) + go/
                        redirect + dock + hunt, from the ONE pure model. onCommanded refreshes the map +
                        ship reads; Clear drops the destination and returns to the menu (a clean slate). */}
                    {hubView === 'fleet' && TEAM_COMMAND_ENABLED && (
                      <FleetCommandPanel
                        target={target}
                        movements={movements}
                        groups={teamGroups}
                        groupsLoaded={teamGroupsOk}
                        unifiedEnabled={fleetMovementUnifiedEnabled}
                        unifiedFleets={unifiedGroupFleets}
                        rollups={dockedTeamRollups}
                        locations={locations}
                        dangerZones={dangerZones}
                        ships={selection.ships}
                        membership={teamGroupMap}
                        launchFromDock={launchFromDockEnabled}
                        fleetControlEnabled={fleetControlEnabled}
                        timedDockingEnabled={timedDockingEnabled}
                        onCommanded={() => {
                          void refresh()
                          void selection.refresh()
                        }}
                        onClearTarget={backToMenu}
                        // STANDING HUNT (owner, 2026-08-04: "i am in combat zone, and the fight
                        // does not start") — the SAME handoff the zone panel below uses, for the
                        // same reason: `handleSelect` is the map's own marker-selection path, so a
                        // fleet parked inside a zone reaches the EXISTING hunt section by exactly
                        // the route a tap on that site's marker takes. No new state, no new RPC.
                        onSelectHuntSite={(locationId) => handleSelect(locationId)}
                      />
                    )}

                    {/* MINING FOLD — the extract surface (the ex-top-left panel, reused verbatim).
                        Extract once a ship is settled in the field's range. */}
                    {hubView === 'mining' && tapFieldInRange && (
                      <MiningPanel
                        lifecycleKey={panelLifecycleKey}
                        mainShipId={mainShip?.main_ship_id ?? null}
                        shipStatus={mainShip?.status}
                        shipSpatialState={null}
                      />
                    )}

                    {/* ZONE INFO — what this danger zone is, in plain words. The header already
                        carries the name and the ✕, so the panel is body-only.

                        THE SIGNPOST (owner, 2026-08-03: "i went to snare, zone, no fighting
                        happens"). The panel's hunt-site button hands the location id to
                        `handleSelect` — the map's OWN marker-selection path, the very one a tap on
                        that marker takes — which swings the hub onto its fleet stage, where the
                        EXISTING FleetCommandPanel hunt section renders. No second hunt control, no
                        new state, no new RPC: the zone panel retires itself by handing over the one
                        selection the command surface already consumes. */}
                    {hubView === 'zone' && zoneInfo && (
                      <ZoneInfoPanel
                        info={zoneInfo}
                        onHuntSite={(locationId) => {
                          setZoneInfoId(null)
                          handleSelect(locationId)
                        }}
                      />
                    )}

                    {/* PIRATE INTERCEPT — plot a route around danger zones. Reused as-is; the
                        header owns dismissal, so no per-panel close here. */}
                    {hubView === 'pirate' && pirateInterceptEnabled && (
                      <PirateInterceptPanel
                        groupId={teamGroups[0]?.group_id ?? null}
                        mode={pirateMode}
                        onModeChange={setPirateMode}
                        draftPoints={pirateDraftPoints}
                        onUndoDraft={() => setPirateDraftPoints((pts) => pts.slice(0, -1))}
                        onClearDraft={() => setPirateDraftPoints([])}
                        onCommanded={() => void refresh()}
                      />
                    )}
                  </>
                }
              />
            )}
          </div>
        )}
      </div>

      {/* MINING-FIELD-MARKERS — the field detail panel: name + a "send fleet here to mine" affordance
          that REUSES the existing open-space go (sets the SAME pointTarget the GalaxyMap space-tap
          path sets — no second command surface). Mutually exclusive with the location panel below
          (handleSelect/handleSelectMiningField keep only one selection live). Gated on
          TEAM_COMMAND_ENABLED like the FleetCommandPanel itself — setting a point target with no
          command surface mounted to consume it would be a dead click. */}
      {selectedField && (
        <aside
          data-testid="mining-field-detail-panel"
          className="max-h-[45dvh] overflow-y-auto border-t border-edge bg-surface p-4 md:max-h-none md:w-80 md:border-l md:border-t-0"
        >
          <div className="mx-auto mb-3 h-1 w-10 rounded-full bg-edge md:hidden" aria-hidden="true" />
          <div className="flex items-start justify-between gap-3">
            <div>
              <h2 className="text-base font-semibold text-ink">{selectedField.name}</h2>
              <p className="mt-0.5 text-xs text-ink-muted">Mining field</p>
            </div>
            <div className="flex shrink-0 items-center gap-2">
              <Badge tone="warning">Resource</Badge>
              <button
                onClick={() => setSelectedFieldName(null)}
                className="flex min-h-6 min-w-6 items-center justify-center text-ink-faint transition hover:text-ink"
                aria-label="Close details"
              >
                ✕
              </button>
            </div>
          </div>
          <dl className="mt-4 space-y-1.5 text-sm">
            <StatRow
              label="Extraction range"
              value={`${Math.round(miningExtractRadius)} units`}
              hint="settle a fleet within range to extract"
            />
          </dl>
          {TEAM_COMMAND_ENABLED && (
            <Button
              variant="warning"
              size="sm"
              data-testid="mining-field-send-fleet"
              className="mt-4 w-full"
              onClick={() => {
                setPointTarget({ x: selectedField.space_x, y: selectedField.space_y })
                setSelectedFieldName(null)
              }}
            >
              Send fleet here to mine
            </Button>
          )}
        </aside>
      )}

      {/* Location detail panel — IDENTITY → DETAILS. READ-ONLY since S5 MAP-UX: every command verb
          lives in the bottom-center FleetCommandPanel (the port target derives from this selection).
          Bottom sheet on phones (capped height, scrollable), side panel on md+. */}
      {selected && (
        <aside
          data-testid="galaxy-location-detail-panel"
          className="max-h-[45dvh] overflow-y-auto border-t border-edge bg-surface p-4 md:max-h-none md:w-80 md:border-l md:border-t-0"
        >
          {/* bottom-sheet drag-handle affordance (phones only — the md+ side panel doesn't sheet) */}
          <div className="mx-auto mb-3 h-1 w-10 rounded-full bg-edge md:hidden" aria-hidden="true" />
          {/* 1 · IDENTITY */}
          <div className="flex items-start justify-between gap-3">
            <div>
              <h2 className="text-base font-semibold text-ink">{selected.name}</h2>
              <p className="mt-0.5 text-xs text-ink-muted">
                {TYPE_LABEL[selected.location_type] ?? selected.location_type.replace(/_/g, ' ')}
                {selMeta && <> · {selMeta.zoneName}</>}
              </p>
            </div>
            <div className="flex shrink-0 items-center gap-2">
              <Badge tone={typeBadge(selected).tone}>{typeBadge(selected).text}</Badge>
              <button
                onClick={() => setSelectedId(null)}
                className="flex min-h-6 min-w-6 items-center justify-center text-ink-faint transition hover:text-ink"
                aria-label="Close details"
              >
                ✕
              </button>
            </div>
          </div>

          {/* 2 · DETAILS — humanized, decision-relevant facts only */}
          <dl className="mt-4 space-y-1.5 text-sm">
            <StatRow
              label="Danger"
              value={dangerLabel(selected.base_difficulty)}
              hint={
                selected.base_difficulty > 0 ? (
                  <span className="font-mono tabular-nums">({selected.base_difficulty})</span>
                ) : undefined
              }
            />
            <StatRow
              label="Rewards"
              value={rewardLabel(selected.reward_tier)}
              hint={
                selected.reward_tier > 0 ? (
                  <span className="font-mono tabular-nums">(tier {selected.reward_tier})</span>
                ) : undefined
              }
            />
            {/* DIFFICULTY-DISPLAY — the team-combat power gate, previously rendered nowhere. Display
                of data get_world_map already returns for this active row; the server RPC
                (power_below_required) stays the only real gate. */}
            {selected.min_power_required > 0 && (
              <StatRow
                label="Required power"
                value={<span className="font-mono tabular-nums">{selected.min_power_required}</span>}
                hint="(fleet combat gate)"
              />
            )}
            {selMeta && <StatRow label="Region" value={selMeta.sectorName} />}
          </dl>
        </aside>
      )}
    </div>
  )
}
