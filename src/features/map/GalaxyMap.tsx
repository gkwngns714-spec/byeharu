import { useCallback, useEffect, useMemo, useRef, useState, type PointerEvent as RPointerEvent } from 'react'
import type { MapLocation } from './mapTypes'
import type { FleetMovement } from '../fleets/fleetTypes'
import { LocationMarker } from './LocationMarker'
import { FleetMovementLine } from './FleetMovementLine'
import { isMovementInFlight, interpolateMovementPoint } from './movementInterpolation'
import { fleetLayer } from './teamMarkers'
import { territoryLayer } from './territoryLayer'
import { miningFieldRangeLayer } from './miningFieldLayer'
import { MiningFieldMarker } from './MiningFieldMarker'
import type { MiningField } from '../mining/miningTypes'
import { dangerZoneLayer } from './dangerZoneLayer'
import { combatFocusWorldPoints, focusableEncounterId, spatialCombatLayer } from './spatialCombatLayer'
import { resolveCombatActors } from './combatActors'
import { useCombatMotion } from './useCombatMotion'
import type { CombatEncounter, CombatEvent, CombatUnit } from '../combat/combatTypes'
import type { DangerZoneLite } from './pirateApi'
import type { GroupRow, ShipGroupMapEntry } from '../command/teamRoster'
import type { UnifiedGroupFleetLite } from '../command/teamApi'
import type { FleetPosition } from './mainshipApi'
import { DevFixedSpacePreview } from './DevFixedSpacePreview'
import { SpaceMoveTargetMarker } from './SpaceMoveTarget'
import { classifyPointerGesture } from './spaceMoveCommand'
import { isMapBackground } from './mapBackground'
import { type FleetGoTargetView } from './fleetGoTarget'
import { screenDeltaToViewBox, screenToWorld, viewBoxDisplayRect, worldToViewBox, type ViewBoxCoord, type WorldCoord } from './openSpaceTransform'
import {
  VIEW,
  BUTTON_ZOOM_STEP,
  clampPan,
  fitCameraToWorldPoints,
  focusCamera,
  focusWorldPoints,
  sameCamera,
  worldPointsFramed,
  zoomCameraAbout,
  type Camera,
  type FocusInputs,
} from './galaxyCamera'
import { useWheelZoom } from './useWheelZoom'
import { labelVisible } from './markerStyle'
import { Button, OverlayPanel, OverlayRail } from '../../components/ui'

// Read-only 2D galaxy map (plain SVG — no canvas/WebGL). UNIFIED fixed-coordinate frame (S6B-PRES):
// EVERY spatial object — named locations, base/home, movement lines, legacy + open-space ship states,
// and coordinate targets — is positioned through the fixed `worldToViewBox` domain (openSpaceTransform).
// `buildNormalizer` is gone: the dynamic auto-fit normalizer is no longer the player-facing spatial
// truth. Camera math (zoom/pan limits + content-fit) lives in ./galaxyCamera and feeds ONLY the initial
// view and explicit reset (frozen once the player pans/zooms). Nothing here writes to the database.

// The UNIFIED spatial transform: world → viewBox. Replaces the old dynamic `norm`. Pure; never clamps.
const norm = (p: { x: number; y: number }): { x: number; y: number } => worldToViewBox(p)

// CLEAN-MAP DOUBLE-TAP thresholds: a second empty-space tap within this window + radius of the first
// is a double-tap (matches native double-click timing; generous enough for touch double-tap).
const DOUBLE_TAP_MS = 350
const DOUBLE_TAP_MAX_GAP_PX = 30

export function GalaxyMap({
  locations,
  movements,
  teamGroups,
  teamGroupMap,
  fleetPositions,
  unifiedGroupFleets,
  combatSortieFleets,
  fleetGoView,
  onDoubleTapPoint,
  selectedId,
  onSelect,
  miningFields,
  miningExtractRadius,
  selectedMiningFieldName,
  onSelectMiningField,
  dangerZones = [],
  zonesInteractive = false,
  selectedDangerZoneId = null,
  combatUnits = [],
  combatEvents = [],
  combatEncounters = [],
  pirateMode = 'off',
  pirateDraftPoints = [],
  onPirateTap,
}: {
  locations: MapLocation[]
  movements: FleetMovement[]
  // WHERE-IS-MY-FLEET: the three inputs the ONE fleet-presence authority reads — the owner's groups,
  // the live membership map, and the SERVER's own per-ship place projection (get_my_fleet_positions,
  // already polled by this hook for the Port hub). Zero groups → no fleet layer at all.
  teamGroups: GroupRow[]
  teamGroupMap: Record<string, ShipGroupMapEntry>
  fleetPositions: FleetPosition[]
  // IDENTITY ONLY — the group's own `fleets.id`, so a fleet can find its OWN fight (the encounter join
  // is on fleets.id). Never a position source: the positions projection above is already fleet-first
  // for open space (0210). The two arrays are the partition useGalaxyMapData makes of ONE read; the
  // layer re-unions them, because for identity the partition is irrelevant.
  unifiedGroupFleets: UnifiedGroupFleetLite[]
  combatSortieFleets: UnifiedGroupFleetLite[]
  // CLEAN-MAP HUB: the map is unobstructed by default. The ONE gesture that summons commands is a
  // DOUBLE-TAP on empty space (mouse double-click OR touch double-tap — both flow through pointer
  // events). MapScreen's handler opens the command hub — a compact ICON CLUSTER anchored AT the
  // double-tapped point — so the tap reports BOTH the RAW world point (drives the eventual go-target
  // crosshair + the in-range mining check) AND the SCREEN px of the tap (relative to this map's box)
  // so the caller can float the icons exactly where the player double-tapped. A single tap on empty
  // space does nothing (the map stays clean); a marker tap still selects; the pirate route mode still
  // consumes single taps (onPirateTap, below).
  fleetGoView: FleetGoTargetView | null
  onDoubleTapPoint: (world: WorldCoord, screen: { x: number; y: number }) => void
  selectedId: string | null
  onSelect: (id: string | null) => void
  // MINING-FIELD-MARKERS: the active fields ([] while mining is disabled — 0226 fail-closed) + the
  // world-unit extraction radius (game_config mining_extract_radius) for the range-ring layer.
  // Selection is its OWN state (a field is not a MapLocation) — MapScreen owns it, mutually
  // exclusive with `selectedId` the same way point-target vs. port-selection already are.
  miningFields: MiningField[]
  miningExtractRadius: number
  selectedMiningFieldName: string | null
  onSelectMiningField: (name: string | null) => void
  // PIRATE INTERCEPT (prototype) — [] / 'off' / [] / undefined while the flag is dark (the caller's
  // gate), so every prop below defaults to a no-op shape and the map is byte-identical to today.
  /** Active danger_zones (get_danger_zones) — rendered as smooth blobs, UNDER movement lines/markers. */
  dangerZones?: DangerZoneLite[]
  /** ZONE INFO: true = zones become HOVERABLE (they brighten and name themselves) and hand map
   *  gestures through. False = they stay scenery, byte-identical to before. They are never clickable —
   *  zone info is reached through the command hub, see dangerZoneLayer's header. */
  zonesInteractive?: boolean
  /** The zone currently open in the info panel — drawn strongest so map and panel agree. */
  selectedDangerZoneId?: string | null
  // COMBAT-S4 — the caller's active combat_units + recent combat_events (both already polled every
  // ~1.5s by the shell's useCombat and exposed via useShellState().combat). The spatial-combat layer
  // draws the units that carry positions (their range rings, side-distinct glyphs, and this tick's fire
  // lines). [] defaults → the layer renders nothing, so a map with no active battle — or ANY map while
  // spatial_combat_enabled is dark (no positioned rows can exist) — is byte-identical to today.
  /** Active combat units (RLS-scoped to the caller — enemy pirate rows carry the caller's own
   *  player_id, so they arrive in the SAME read). Only positioned+alive rows render. */
  combatUnits?: CombatUnit[]
  /** Recent combat events; the layer consumes only the latest tick's spatial `missile_salvo`s (fire
   *  lines between units), ignoring the aggregate/dark-path events that carry no unit_id. */
  combatEvents?: CombatEvent[]
  /** The caller's live encounters (the SAME rows the units above belong to — useCombat polls them
   *  together). With `combatUnits` they let the team layer place a fighting fleet's badge on that
   *  fleet's own formation instead of on a resting point its ships have already left. [] → badges
   *  keep their resting position, byte-identical to before. */
  combatEncounters?: CombatEncounter[]
  /** 'off' = normal ship-go tap handling (byte-identical to pre-slice behavior). 'route' TAKES OVER
   *  the entire empty-space tap surface (mutually exclusive with the fleet-go tap) — each tap appends
   *  a route waypoint via onPirateTap instead of setting a fleet-go target. */
  pirateMode?: 'off' | 'route'
  /** The in-progress route waypoints, drawn as a connected polyline + vertex dots while plotting. */
  pirateDraftPoints?: WorldCoord[]
  /** Called with the tapped RAW world point whenever pirateMode !== 'off' (ownership/group checks do
   *  NOT apply — route planning is not gated on owning a fleet the way ship-go is). */
  onPirateTap?: (world: WorldCoord) => void
}) {
  const svgRef = useRef<SVGSVGElement | null>(null)
  // The SAME element, held BOTH ways on purpose: the ref for the imperative readers that run inside
  // event handlers (they must not re-render anything), and the state for `useWheelZoom`, which must
  // react to the element MOUNTING rather than sample a ref once. One assignment site keeps them from
  // diverging. (Same idiom as WorldEditor's attachSvg.)
  const [svgEl, setSvgEl] = useState<SVGSVGElement | null>(null)
  const attachSvg = useCallback((el: SVGSVGElement | null) => {
    svgRef.current = el
    setSvgEl(el)
  }, [])
  const [view, setView] = useState<Camera>({ k: 1, tx: 0, ty: 0 })
  const drag = useRef<{ x: number; y: number; tx: number; ty: number } | null>(null)

  // ZONE INFO — which danger zone the pointer is over. Pure presentation state, owned here rather
  // than lifted: nothing outside the map cares which blob is under the cursor, and keeping it local
  // means a hover cannot re-render the screen's panels.
  const [hoveredDangerZoneId, setHoveredDangerZoneId] = useState<string | null>(null)

  // 1s clock for the in-flight path filter below. Same idiom as TeamMovingMarkers: Date.now()
  // stays OUT of render (it is impure and would re-read unpredictably on any re-render), and the interval
  // runs ONLY while there is a movement to time — with none, no timer exists and the map is idle as before.
  // COMBAT THAT FLOWS — the battle's own clock. `liveCombatUnits` is `combatUnits` with each
  // position moved to where it is at this instant (map/combatMotion.ts, composing the ONE
  // interpolation primitive). It is passed to the TEAM layer as well as the combat layer on purpose:
  // teamMarkers → fleetFightPosition stands the fleet badge on a real ship by copying that ship's
  // x/y, so smoothing the rows once here is what keeps the badge and the glyphs from separating.
  // The camera framing below deliberately keeps the RAW rows — a frame must not chase a tween.
  const { units: liveCombatUnits, sightings: shotSightings, nowMs: combatNowMs } = useCombatMotion(
    combatUnits,
    combatEvents,
  )
  // WHICH HULL IS WHICH CLASS — `hull_type_id` off the position projection the map already fetches
  // (get_my_fleet_positions carries it as `class`). `combat_units` names the ship but not its class,
  // so this is the join that lets a fleet's combat glyph wear the SAME ship the map badge wears. No
  // extra read, and no client fetch of `main_ship_hull_types`.
  const hullTypeByShip = useMemo(
    () => new Map(fleetPositions.map((p) => [p.main_ship_id, p.class ?? null])),
    [fleetPositions],
  )
  // THE FLEET IS THE COMBAT ACTOR — "show only fleet. it is as a whole." One glyph per player fleet
  // (placed by the same fleetFightPosition rule that places its badge), one per living enemy hull.
  const combatActors = useMemo(
    () => resolveCombatActors(liveCombatUnits, combatEncounters, hullTypeByShip),
    [liveCombatUnits, combatEncounters, hullTypeByShip],
  )
  const [nowMs, setNowMs] = useState(() => Date.now())
  const anyMovement = movements.length > 0
  useEffect(() => {
    if (!anyMovement) return
    const iv = setInterval(() => setNowMs(Date.now()), 1000)
    return () => clearInterval(iv)
  }, [anyMovement])
  // S6B-PRES camera policy: content-fit is applied for the initial view + explicit reset only; once the
  // player pans/zooms (`userMovedRef`) the camera is frozen. `lastFitSig` makes the fit fire once per
  // meaningful focus change rather than per animation frame.
  const userMovedRef = useRef(false)
  const lastFitSig = useRef<string | null>(null)

  // Gesture bookkeeping: a single short near-stationary pointer on EMPTY space is a candidate tap;
  // drags and multi-touch stay map pan. Tracked alongside (never replacing) the existing pan snapshot.
  const tap = useRef<{ x: number; y: number; t: number; maxPointers: number } | null>(null)
  const pointers = useRef<Set<number>>(new Set())
  // CLEAN-MAP DOUBLE-TAP: the last committed empty-space tap (screen px + timestamp). A second tap
  // close in time + space is a double-tap → summon. Pointer events fire for BOTH mouse and touch, so
  // this ONE mechanism covers mouse double-click and touch double-tap without a separate onDoubleClick.
  const lastTap = useRef<{ x: number; y: number; t: number } | null>(null)

  // ── S6B-PRES content-fit camera (presentation only; never alters world/marker coordinates) ──
  // 4C-CLIENT: the per-ship open-space focus arm (spatial_state='in_space' point / legacy coordinate
  // movement segment) is DELETED with the per-ship movement client — those states can no longer
  // exist. Focus derives from the named world content; the FocusInputs ship/segment slots stay null.
  const focusInputs: FocusInputs = useMemo(
    () => ({
      shipWorld: null,
      movementSegment: null,
      locations: locations.map((l) => ({ x: l.x, y: l.y })),
    }),
    [locations],
  )

  // Stable focus signature: changes only on a MEANINGFUL focus change (the named-content set),
  // never per animation frame — so the fit is applied once per context.
  const focusSignature = useMemo(() => `named:${locations.map((l) => l.id).join(',')}`, [locations])

  // location_ids that own an active danger_zone polygon — the gate for territory-ring suppression
  // (a hostile site shows its polygon INSTEAD of a ring only when it actually has one; otherwise it
  // keeps its ring, so every pirate site shows exactly one region, never zero). See territoryLayer.
  const zonedLocationIds = useMemo(
    () => new Set(dangerZones.flatMap((z) => (z.location_id ? [z.location_id] : []))),
    [dangerZones],
  )

  // Apply the content-fit camera for the INITIAL view (once per focus change), never after the player
  // has interacted. Explicit reset re-enables it.
  useEffect(() => {
    if (userMovedRef.current) return
    if (lastFitSig.current === focusSignature) return
    if (focusWorldPoints(focusInputs).length === 0) return
    lastFitSig.current = focusSignature
    // Intentional: one-time content-fit of the camera when async data / focus first arrives. Gated by
    // refs (userMoved + lastFitSig) so it fires once per focus context, never continuously — the valid
    // "derive initial view from external data" effect use, not a render-loop.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setView(focusCamera(focusInputs))
  }, [focusSignature, focusInputs])

  // ── pan / zoom handlers (read-only camera; no data mutation) ──
  const onPointerDown = (e: RPointerEvent) => {
    ;(e.target as Element).setPointerCapture?.(e.pointerId)
    drag.current = { x: e.clientX, y: e.clientY, tx: view.tx, ty: view.ty }
    pointers.current.add(e.pointerId)
    tap.current = { x: e.clientX, y: e.clientY, t: e.timeStamp, maxPointers: pointers.current.size }
  }
  const onPointerMove = (e: RPointerEvent) => {
    // Capture the drag snapshot locally. The setView updater runs LATER (React render phase), and
    // drag.current can be null by then (pointer already released) — dereferencing it inside the
    // updater crashed the whole tree ("Cannot read properties of null (reading 'tx')"), which with
    // no error boundary blanked the page on pan. The captured `d` is guaranteed non-null here.
    const d = drag.current
    if (!d) return
    if (tap.current) tap.current.maxPointers = Math.max(tap.current.maxPointers, pointers.current.size)
    // Pan through the ONE shared pan scale. The old local `toSvgUnits` divided by rect.WIDTH, but the
    // svg is `xMidYMid meet`, so px-per-viewBox-unit is set by min(width,height) — on any landscape
    // viewport the map crawled behind the pointer (0.5625× on 1600×900).
    const rect = svgRef.current?.getBoundingClientRect()
    if (!rect || rect.width === 0 || rect.height === 0) return
    const vp = { width: rect.width, height: rect.height }
    const dx = screenDeltaToViewBox(e.clientX - d.x, vp)
    const dy = screenDeltaToViewBox(e.clientY - d.y, vp)
    if (dx !== 0 || dy !== 0) userMovedRef.current = true // player took camera control → freeze auto-fit
    setView((v) => ({ ...v, ...clampPan(d.tx + dx, d.ty + dy, v.k) }))
  }
  const onPointerUp = (e: RPointerEvent) => {
    const t = tap.current
    pointers.current.delete(e.pointerId)
    drag.current = null
    tap.current = null
    // A single short near-stationary tap on the map's NAVIGABLE BACKGROUND is the gesture candidate.
    // Drags/multi-touch already returned as pan.
    //
    // "Background" is asked of ONE authority (mapBackground.isMapBackground), not tested here by
    // element identity. It used to be `e.target !== svg`, which silently assumed every drawn layer was
    // `pointerEvents:'none'`; the moment the danger-zone fill became hit-testable, that assumption made
    // BOTH map gestures — the double-tap hub summon and the pirate waypoint tap — dead across the whole
    // area of every zone. A layer that draws over the map now either takes the gesture or declares
    // itself passthrough. See mapBackground.ts for the full account.
    const svg = svgRef.current
    if (!t || !svg || !isMapBackground(e.target, svg)) return
    const travelPx = Math.hypot(e.clientX - t.x, e.clientY - t.y)
    const durationMs = e.timeStamp - t.t
    if (classifyPointerGesture({ travelPx, durationMs, maxPointers: t.maxPointers }) !== 'tap') return
    const rect = svg.getBoundingClientRect()
    const world = screenToWorld(
      { x: e.clientX - rect.left, y: e.clientY - rect.top },
      { k: view.k, tx: view.tx, ty: view.ty },
      { width: rect.width, height: rect.height },
    )
    // PIRATE INTERCEPT: route-planning TAKES OVER the tap surface — each SINGLE tap appends a
    // waypoint. Double-tap detection is suspended in this mode so a plotted point is never swallowed
    // as the first half of a "double". 'off' (the default) falls through to the summon path.
    if (pirateMode !== 'off') {
      lastTap.current = null
      onPirateTap?.(world)
      return
    }
    // CLEAN-MAP: a lone single tap does NOTHING (the map stays unobstructed). A second tap close in
    // time + space is a DOUBLE-TAP → summon the command hub (MapScreen) AT this point. This one
    // pointer-driven path serves mouse double-click and touch double-tap alike. Report the world
    // point AND the screen px (relative to this map's box, the SAME rect screenToWorld used) so the
    // caller floats the action icons exactly where the player double-tapped.
    const prev = lastTap.current
    const gapMs = e.timeStamp - (prev?.t ?? -Infinity)
    const gapPx = prev ? Math.hypot(e.clientX - prev.x, e.clientY - prev.y) : Infinity
    if (prev && gapMs <= DOUBLE_TAP_MS && gapPx <= DOUBLE_TAP_MAX_GAP_PX) {
      lastTap.current = null
      onDoubleTapPoint(world, { x: e.clientX - rect.left, y: e.clientY - rect.top })
      return
    }
    lastTap.current = { x: e.clientX, y: e.clientY, t: e.timeStamp }
  }
  // pointerleave/cancel: end the pan and abandon any tap candidate (never a selection).
  const onPointerLeave = (e: RPointerEvent) => {
    pointers.current.delete(e.pointerId)
    drag.current = null
    tap.current = null
  }
  // Zoom by a factor about an ANCHOR — the cursor for a wheel notch, the viewBox centre for the +/−
  // buttons (no anchor). All the camera math lives in galaxyCamera.zoomCameraAbout; this only records
  // that the player took camera control.
  const zoomByFactor = useCallback((factor: number, anchor?: ViewBoxCoord | null) => {
    userMovedRef.current = true // player took camera control → freeze auto-fit
    setView((v) => zoomCameraAbout(v, factor, anchor))
  }, [])

  // Cursor-anchored wheel zoom — the ONE binding, shared with the World Editor. The map now zooms
  // toward the point under the pointer instead of the viewBox centre.
  useWheelZoom(svgEl, zoomByFactor)

  // ── HOW BIG IS A PIXEL HERE ────────────────────────────────────────────────────────────────────
  // CSS px per viewBox unit, from the ONE letterbox authority (openSpaceTransform.viewBoxDisplayRect)
  // applied to this element's real box. The combat readout needs it because `÷ k` is constant in
  // VIEWBOX units, not pixels: on a 390px-wide map that is 0.39×, which rendered a nominally-10
  // damage number at 3.9 CSS px. Measured, never assumed — and re-measured on resize/rotate, the only
  // time it can change. Nothing else consumes it and no POSITION depends on it: this corrects
  // screen-constant chrome only.
  const [pxPerViewBox, setPxPerViewBox] = useState(1)
  useEffect(() => {
    if (!svgEl) return
    const measure = () => {
      const r = svgEl.getBoundingClientRect()
      if (r.width === 0 || r.height === 0) return
      const s = viewBoxDisplayRect({ width: r.width, height: r.height }).scale
      if (Number.isFinite(s) && s > 0) setPxPerViewBox(s)
    }
    measure()
    const ro = new ResizeObserver(measure)
    ro.observe(svgEl)
    return () => ro.disconnect()
  }, [svgEl])

  // ── FOCUS THE FIGHT ────────────────────────────────────────────────────────────────────────────
  // A battle is 5-6 world units of weapon range and a 6-unit formation ring (0316) inside a 20000-unit
  // world, so at the map's own default camera the whole engagement is a handful of pixels — smaller
  // than the damage number drawn over it. Nothing in the map offered to go there: a grep for
  // focusCamera/zoomTo/centerOn across src/features/map found no combat caller at all, so seeing your
  // own fight required knowing to scroll ~25 wheel notches at the right spot.
  //
  // The camera goes to the fight; the fight is NOT redrawn larger than it is (see
  // combatFocusWorldPoints' header for why an arena presentation scale was rejected). It composes
  // the SAME `fitCameraToWorldPoints` the initial view and the reset button already use — one
  // framing authority, given different points.
  //
  // AUTOMATIC ON A NEW BATTLE, whatever the camera was doing. Deliberately NOT gated on
  // `userMovedRef`: a fight starting is the one event that outranks a camera the player set earlier,
  // and it is exactly the case the content-fit's "frozen once touched" rule would have silently
  // skipped for every player who has ever panned. ⟲ still resets.
  //
  // ── AND THEN THE FIGHT WALKS OUT OF THE FRAME ─────────────────────────────────────────────────
  // The owner, playing: "When enemy ship is destroyed, i teleport to some random place inside the
  // zone." Nothing teleported. The frame was applied ONCE per encounter id, around the anchor the
  // battle opened on, and at that fit the visible window is only ~33 world units across. Since 0337
  // an in-combat reposition is a real multi-tick MOVE that translates the formation, the fleet row
  // AND the encounter anchor by the same vector every tick (0337:486-492), and later waves form
  // around the MOVED anchor. So the battle walks straight out of the box the camera is holding and
  // keeps fighting off-screen, while the player stares at empty space — which is what a teleport
  // looks like from inside the frame.
  //
  // THE RULE, and why it is this one and not "re-fit every tick":
  //
  //   FOLLOW ONLY A CAMERA WE OURSELVES SET. `framedCameraRef` holds the exact Camera OBJECT the
  //   last fight-framing produced. While `view` is still that object — the player has not panned,
  //   zoomed or reset since, because every one of those builds a new object — the camera is the
  //   fight's, so the fight is re-framed whenever it leaves the frame. The instant the player moves
  //   the camera themselves, identity differs and following stops dead: someone who deliberately
  //   panned away is looking at something else on purpose, and yanking them back every tick would
  //   be worse than the bug. ⌖ goes through this same path, so it re-ENTERS following — the manual
  //   control is still the way back, it is just no longer the only way.
  //
  //   FIT ON THE RAW SERVER ROWS, NEVER `liveCombatUnits`. The smoothed rows move every animation
  //   frame (useCombatMotion), so framing off those would re-evaluate the box ~30×/s and chase its
  //   own tween. `combatUnits` changes once per poll, which bounds this to one re-frame per tick.
  //
  //   ONE BOUNDING BOX. `combatFocusWorldPoints` already answers "what box is the fight in" (each
  //   unit padded by its own reach) and `fitCameraToWorldPoints` already answers "frame these
  //   points". The off-screen test is the INVERSE of that fit over the SAME projection
  //   (galaxyCamera.worldPointsFramed). No second bbox exists anywhere on this path.
  //
  //   IT CANNOT OSCILLATE. A fit leaves the box at (1−2·PAD) of the frame, strictly inside it, so
  //   the next evaluation answers "framed" and stops. `sameCamera` is the belt-and-braces for the
  //   one case where that reasoning does not hold — a fit whose k had to be CLAMPED need not
  //   satisfy the framed test, and without the guard it would re-set the camera on every render.
  const fightId = useMemo(
    () => focusableEncounterId(combatEncounters, combatUnits),
    [combatEncounters, combatUnits],
  )
  /** The camera the last fight-framing produced. Compared by IDENTITY on purpose — see the rule. */
  const framedCameraRef = useRef<Camera | null>(null)
  const applyFightCamera = useCallback((cam: Camera) => {
    userMovedRef.current = true // the battle framing is now the camera; no content fit may override it
    framedCameraRef.current = cam
    setView(cam)
  }, [])
  const focusFight = useCallback(
    (id: string | null) => {
      const pts = combatFocusWorldPoints(combatUnits, id)
      if (pts.length === 0) return
      applyFightCamera(fitCameraToWorldPoints(pts))
    },
    [combatUnits, applyFightCamera],
  )
  const focusedFightRef = useRef<string | null>(null)
  useEffect(() => {
    if (!fightId) return
    // Intentional: derive the view from newly-arrived data. Both arms are gated so this is a poll-rate
    // decision, never a render loop.
    if (focusedFightRef.current !== fightId) {
      focusedFightRef.current = fightId
      focusFight(fightId) // a new battle: frame it once, unconditionally
      return
    }
    if (framedCameraRef.current !== view) return // the camera is the player's now — leave it alone
    const pts = combatFocusWorldPoints(combatUnits, fightId)
    if (pts.length === 0 || worldPointsFramed(pts, view)) return
    const cam = fitCameraToWorldPoints(pts)
    if (sameCamera(cam, view)) return
    // The SAME sanctioned "derive the view from newly-arrived data" case as the content-fit effect
    // above: the rows land from a poll, so this runs at most once per server tick, and every path
    // that could re-enter it is closed by the three guards above (camera identity, already-framed,
    // sameCamera). It cannot cascade.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    applyFightCamera(cam)
  }, [fightId, focusFight, applyFightCamera, combatUnits, view])
  // Reset re-enables the deterministic content-fit camera (frames the player ship / active movement,
  // else named content). NOT k=1/origin — at k=1 the fixed frame would show current seed content as a
  // tiny central cluster.
  const reset = () => {
    userMovedRef.current = false
    const pts = focusWorldPoints(focusInputs)
    lastFitSig.current = focusSignature
    setView(pts.length ? focusCamera(focusInputs) : { k: 1, tx: 0, ty: 0 })
  }

  // ── THE FLEET LAYER, resolved ONCE per render ─────────────────────────────────────────────────────
  // Two presentations, one authority: the world badges go inside the camera group; the fleets the world
  // cannot place go in the overlay rail. Splitting them here — rather than letting each renderer decide
  // who it draws — is what keeps "does this fleet appear?" a question with exactly one answer.
  const fleetLayerView = fleetLayer({
    groups: teamGroups,
    membership: teamGroupMap,
    positions: fleetPositions,
    // The union of the two partitions useGalaxyMapData makes of ONE fleets read — identity only.
    fleets: [...unifiedGroupFleets, ...combatSortieFleets],
    locations,
    norm,
    k: view.k,
    // The SAME letterbox scale the combat readout is sized from, so a fleet's badge and that fleet's
    // combat glyph are one size on one screen — see ShipVisual.sizePx.
    pxScale: pxPerViewBox,
    nowMs,
    encounters: combatEncounters,
    // The SMOOTHED rows, exactly as the spatial layer below receives them. The fleet layer stands a
    // fleet's badge on one of its own real hulls (fleetFightPosition), so handing it the raw rows
    // while the glyphs ride the interpolated ones would put the badge and that fleet's own ships in
    // two different places between ticks — the very defect both slices exist to kill.
    units: liveCombatUnits,
  })

  return (
    <div className="relative h-full w-full overflow-hidden rounded-card border border-edge bg-app shadow-card">
      <svg
        ref={attachSvg}
        viewBox={`0 0 ${VIEW} ${VIEW}`}
        preserveAspectRatio="xMidYMid meet"
        className="h-full w-full cursor-grab touch-none select-none active:cursor-grabbing"
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerLeave={onPointerLeave}
        onPointerCancel={onPointerLeave}
        onClick={() => {
          onSelect(null)
          onSelectMiningField(null)
        }}
      >
        {/* Static backdrop (NOT transformed): the map area always renders a deliberate background,
            even at the camera bounds. Visual safety layer only — not a map-layer framework.
            UI R1 depth treatment (tokens ONLY — no raw color literals, no WebGL, no animation):
            app-dark canvas (darker than the surface chrome) → soft surface lift + faint accent
            nebula → static tiled starfield → major/minor grid on --color-map-grid → vignette. */}
        <defs>
          <radialGradient id="bh-space-glow" cx="50%" cy="42%" r="75%">
            <stop offset="0%" stopColor="var(--color-surface)" stopOpacity={0.55} />
            <stop offset="70%" stopColor="var(--color-surface)" stopOpacity={0} />
          </radialGradient>
          <radialGradient id="bh-space-nebula" cx="30%" cy="28%" r="50%">
            <stop offset="0%" stopColor="var(--color-accent)" stopOpacity={0.05} />
            <stop offset="100%" stopColor="var(--color-accent)" stopOpacity={0} />
          </radialGradient>
          <radialGradient id="bh-space-vignette" cx="50%" cy="50%" r="72%">
            <stop offset="0%" stopColor="var(--color-app)" stopOpacity={0} />
            <stop offset="62%" stopColor="var(--color-app)" stopOpacity={0} />
            <stop offset="100%" stopColor="var(--color-app)" stopOpacity={0.6} />
          </radialGradient>
          {/* static starfield tile — a fixed set of faint ink dots (no script, no animation loop) */}
          <pattern id="bh-space-stars" width={VIEW / 4} height={VIEW / 4} patternUnits="userSpaceOnUse">
            <g fill="var(--color-ink)">
              <circle cx={12} cy={40} r={1.1} opacity={0.35} />
              <circle cx={58} cy={15} r={0.7} opacity={0.2} />
              <circle cx={90} cy={80} r={1.4} opacity={0.45} />
              <circle cx={140} cy={30} r={0.8} opacity={0.25} />
              <circle cx={170} cy={110} r={1.1} opacity={0.3} />
              <circle cx={30} cy={150} r={0.7} opacity={0.2} />
              <circle cx={105} cy={170} r={1.3} opacity={0.4} />
              <circle cx={200} cy={60} r={0.9} opacity={0.25} />
              <circle cx={230} cy={140} r={0.7} opacity={0.2} />
              <circle cx={65} cy={210} r={1} opacity={0.3} />
              <circle cx={160} cy={225} r={0.8} opacity={0.22} />
              <circle cx={220} cy={205} r={1.2} opacity={0.35} />
              <circle cx={15} cy={95} r={0.9} opacity={0.28} />
              <circle cx={245} cy={20} r={0.8} opacity={0.2} />
            </g>
          </pattern>
          {/* minor/major grid — both painted with --color-map-grid at two weights/opacities */}
          <pattern id="bh-space-grid-minor" width={VIEW / 20} height={VIEW / 20} patternUnits="userSpaceOnUse">
            <path
              d={`M ${VIEW / 20} 0 L 0 0 0 ${VIEW / 20}`}
              fill="none"
              stroke="var(--color-map-grid)"
              strokeWidth={0.5}
              opacity={0.5}
            />
          </pattern>
          <pattern id="bh-space-grid-major" width={VIEW / 5} height={VIEW / 5} patternUnits="userSpaceOnUse">
            <path d={`M ${VIEW / 5} 0 L 0 0 0 ${VIEW / 5}`} fill="none" stroke="var(--color-map-grid)" strokeWidth={1.25} />
          </pattern>
        </defs>
        <rect x={0} y={0} width={VIEW} height={VIEW} fill="var(--color-app)" pointerEvents="none" />
        <rect x={0} y={0} width={VIEW} height={VIEW} fill="url(#bh-space-glow)" pointerEvents="none" />
        <rect x={0} y={0} width={VIEW} height={VIEW} fill="url(#bh-space-nebula)" pointerEvents="none" />
        <rect x={0} y={0} width={VIEW} height={VIEW} fill="url(#bh-space-stars)" pointerEvents="none" />
        <rect x={0} y={0} width={VIEW} height={VIEW} fill="url(#bh-space-grid-minor)" pointerEvents="none" />
        <rect x={0} y={0} width={VIEW} height={VIEW} fill="url(#bh-space-grid-major)" pointerEvents="none" />
        <rect x={0} y={0} width={VIEW} height={VIEW} fill="url(#bh-space-vignette)" pointerEvents="none" />
        <g transform={`translate(${view.tx} ${view.ty}) scale(${view.k})`}>
          {/* S2 TERRITORY — world-true territory rings, composed by the pure, hook-free
              `territoryLayer` element helper (the fleetShipsLayer/teamMarkersLayer convention; the
              unit test calls the SAME function). FIRST child of the camera group: a territory is a
              region of space, so it renders UNDER movement lines and every marker. World-true
              radius (territory_radius * WORLD_TO_VIEWBOX_SCALE — scales with zoom, deliberately
              NOT /k); every element pointer-transparent. Locations without territory_radius render
              nothing — the pre-0217 map is byte-identical. */}
          {territoryLayer({ locations, norm, k: view.k, zonedLocationIds })}

          {/* MINING-FIELD-MARKERS — the extraction-range ring per active field, same "world-true
              region, under every marker" placement as the territory rings just above (pure,
              hook-free `miningFieldRangeLayer`, unit-tested the SAME way). [] fields (mining
              disabled) or a non-positive radius → renders nothing. */}
          {miningFieldRangeLayer({ fields: miningFields, norm, k: view.k, radius: miningExtractRadius })}

          {/* PIRATE INTERCEPT (prototype) — smooth danger-zone blobs (get_danger_zones), ABOVE the
              plain circle territoryLayer rings (untouched) and UNDER movement lines/markers. []
              while the flag is dark (the caller's gate) → renders nothing, byte-identical to today. */}
          {dangerZoneLayer({
            zones: dangerZones,
            norm,
            k: view.k,
            // Interactivity is opt-in: without the caller's switch the layer stays scenery.
            selectedId: selectedDangerZoneId,
            hoveredId: hoveredDangerZoneId,
            onHoverChange: zonesInteractive ? setHoveredDangerZoneId : undefined,
          })}

          {/* Movement paths (under markers) — IN-FLIGHT ONLY.
              The rows arrive already filtered to status='moving', but that status is settled by the 30s
              `process_fleet_movements` cron, so a finished trip keeps its row for up to ~30s and used to
              leave a stale path hanging on the map from a journey already over (with no ETA, since the
              countdown expires at arrive_at). The filter is display-only — it settles nothing and claims
              no arrival; it just stops drawing a path whose time is up. The 1s clock above retires the
              path within a second of arrival rather than waiting on the next poll. */}
          {movements.filter((m) => isMovementInFlight(m, nowMs)).map((m) => {
            // Draw the path from the fleet's CURRENT interpolated position (not the origin), so the
            // traversed portion disappears in real time as it advances — a shrinking remaining-path,
            // not a fixed origin→target trail. The 1s clock (nowMs) re-renders it each tick.
            const cur = interpolateMovementPoint(m, nowMs) ?? { x: m.origin_x, y: m.origin_y }
            const a = norm(cur)
            const b = norm({ x: m.target_x, y: m.target_y })
            return (
              <FleetMovementLine
                key={m.id}
                x1={a.x}
                y1={a.y}
                x2={b.x}
                y2={b.y}
                k={view.k}
                isReturn={m.target_type === 'base'}
                arriveAt={m.arrive_at}
                // S4 TIMED DOCKING: a 'dock' leg labels "Docking m:ss" (FleetMovementLine).
                missionType={m.mission_type}
              />
            )
          })}

          {/* locations */}
          {locations.map((loc) => {
            const p = norm({ x: loc.x, y: loc.y })
            return (
              <LocationMarker
                key={loc.id}
                x={p.x}
                y={p.y}
                k={view.k}
                location={loc}
                selected={loc.id === selectedId}
                // UI R1 label declutter: zoom-tiered reveal (pure policy in markerStyle.ts) — ports/
                // important locations are always labelled, lesser ones reveal as the player zooms in;
                // the selected marker is always labelled.
                showLabel={loc.id === selectedId || labelVisible(loc, view.k)}
                onSelect={onSelect}
              />
            )
          })}

          {/* MINING-FIELD-MARKERS — the interactive field glyphs (hexagon "gem", distinct from every
              LocationMarker shape). Positioned through the SAME `norm` world→viewBox projection as
              every other spatial object; a field is OPEN-SPACE world data (space_x/space_y), not a
              MapLocation, so it is not part of the `locations` list above. Always labelled (a
              handful of fields, world-wide — the whole point is to be found), unlike the zoom-tiered
              LocationMarker declutter built for a much denser location set. */}
          {miningFields.map((f) => {
            const p = norm({ x: f.space_x, y: f.space_y })
            return (
              <MiningFieldMarker
                key={f.name}
                x={p.x}
                y={p.y}
                k={view.k}
                field={f}
                selected={f.name === selectedMiningFieldName}
                onSelect={(field) => onSelectMiningField(field.name)}
              />
            )
          })}

          {/* ██ THE FLEET LAYER — one fleet, one marker, in EVERY state. ██ Composed by the pure,
              hook-free `fleetLayer` helper (the shipLayer element-tree convention; the unit tests call
              the SAME function). It replaced four badge resolvers that each decided for themselves
              whether a fleet EXISTS, which is how a fleet docked at a port with only some of its ships
              placed ended up drawn nowhere at all. Existence is now unconditional — one presence per
              group — and the state picks the glyph. Encounters + units are the VERY SAME arrays the
              spatial layer below is drawn from, so a fleet's badge and that fleet's own ships come
              from ONE source and can never render as two things standing in two places. */}
          {fleetLayerView.elements}

          {/* COMBAT-S4 — the SPATIAL-COMBAT layer, composed by the pure, hook-free `spatialCombatLayer`
              helper (the territoryLayer/teamMarkersLayer element-tree convention; the unit test calls
              the SAME function). Renders the caller's active on-map battle: each positioned unit at its
              world pos (player accent chevrons vs enemy danger triangles), its weapon RANGE ring, and
              this tick's fire lines between units. Above the markers (the battle is the focus of the
              frame) and pointer-transparent (the location under it stays the tap target). DARK BY DATA:
              while spatial_combat_enabled is off, no combat_units row carries a position, so `combatUnits`
              has no positioned rows and this renders NOTHING — byte-identical to today.

              WHAT ANIMATES (this used to claim "approach + kiting + fire animate as ticks land",
              which was false: a position updated on tick arrival is a step function — three seconds
              at A, then B, which is the "laggy, not smooth" the owner reported). The rows arriving
              here have ALREADY been interpolated to `combatNowMs` by useCombatMotion, so each
              server step is played out over the server's own measured tick interval and the ships
              are SEEN crossing. `sightings` dates each fire event so the round a gun throws travels
              its lane and its damage number appears when the round lands. */}
          {spatialCombatLayer({
            actors: combatActors,
            units: liveCombatUnits,
            events: combatEvents,
            norm,
            k: view.k,
            pxScale: pxPerViewBox,
            sightings: shotSightings,
            nowMs: combatNowMs,
          })}

          {/* 4C-CLIENT: the per-ship overlay layer (shipLayer — route + MainShipMarker) is DELETED
              with the per-ship movement client (S5 already deleted the redundant fleetShipsLayer).
              Owned ships are represented by the team badges above (fleeted) or as INFO surfaces
              (berthed — roster/Port labels); the legacy per-ship spatial states can no longer exist. */}

          {/* FLEET-GO 4a-2 — the FLEET's coordinate-go target (the same crosshair geometry, reused
              under its own testid + accent tone). Shows the CANONICAL point — the integer-grid
              destination 0208 will store — never the raw tap (which still rides the wire untouched).
              S5 MAP-UX: driven by the fleetGoView PROP (MapScreen owns the target union); renders
              only while a point target exists AND lies within bounds. */}
          {fleetGoView && fleetGoView.withinBounds && (
            <SpaceMoveTargetMarker
              target={fleetGoView.canonical}
              k={view.k}
              testId="fleet-go-target"
              stroke="var(--color-accent)"
            />
          )}

          {/* PIRATE INTERCEPT — the in-progress route draft: a connected polyline through the tapped
              waypoints + a dot per vertex. 'off' or an empty draft renders nothing. */}
          {pirateMode !== 'off' && pirateDraftPoints.length > 0 && (
            <g data-testid="pirate-draft-layer" style={{ pointerEvents: 'none' }}>
              {pirateDraftPoints.length > 1 && (
                <polyline
                  points={pirateDraftPoints.map((p) => { const s = norm(p); return `${s.x},${s.y}` }).join(' ')}
                  fill="none"
                  stroke="var(--color-accent)"
                  strokeWidth={1.5 / view.k}
                  strokeDasharray={`${4 / view.k} ${3 / view.k}`}
                />
              )}
              {pirateDraftPoints.map((p, i) => {
                const s = norm(p)
                return <circle key={i} cx={s.x} cy={s.y} r={4 / view.k} fill="var(--color-accent)" />
              })}
            </g>
          )}

          {/* OSN-3 S6B3 — DEVELOPMENT-ONLY, non-interactive fixed-space preview. Final visual child of the
              camera <g> (top z), pointer-transparent. `import.meta.env.DEV` is statically `false` in
              `vite build`, so this branch (and the imported module + its sentinel) is compile-time
              eliminated from the production bundle. It does not alter camera/viewBox/pan or the ordering
              of any existing production marker. */}
          {import.meta.env.DEV && <DevFixedSpacePreview k={view.k} />}
        </g>
      </svg>

      {/* ── UI R1 overlay slots: one positioned rail per corner; co-corner overlays stack instead of
          colliding at hand-tuned absolute offsets. MapScreen owns the remaining slots (top-left =
          the feature rail, top-center = world events, bottom-right = the ONE FleetCommandPanel). ── */}

      {/* top-right: the zoom cluster. S5 MAP-UX: the fleet coordinate-go confirm panel that used to
          stack here moved into the ONE bottom-center FleetCommandPanel (MapScreen). */}
      <OverlayRail slot="top-right">
        {/* ── FLEETS THE WORLD CANNOT PLACE ────────────────────────────────────────────────────────
            A fleet whose every ship reports `place='hidden'` has no coordinate anywhere in the game,
            so a world badge would be a fabricated position. It still belongs ON the map — the owner
            asked to be told where their fleets are, and "we don't know" is an answer; silence is not.
            It rides the rail this corner already owns (the design-system rule for co-corner overlays)
            and carries the SAME `fleet-marker-<groupId>` testid every placed badge does, so "exactly
            one marker per fleet, in every state" stays a single query. Nothing to say → nothing
            rendered; a clean map is unchanged. */}
        {fleetLayerView.unplaced.length > 0 && (
          <OverlayPanel className="flex flex-col gap-0.5" data-testid="fleet-unplaced-rail">
            {fleetLayerView.unplaced.map((p) => (
              <span
                key={p.groupId}
                data-testid={`fleet-marker-${p.groupId}`}
                className="whitespace-nowrap text-[10px] text-ink-muted"
              >
                {p.label}
              </span>
            ))}
          </OverlayPanel>
        )}
        <OverlayPanel className="flex flex-col gap-1">
          {/* FOCUS THE FIGHT — a CAMERA control, so it lives with the other camera controls rather
              than forking a second place that moves the view. Mounted only while a battle actually
              has ships on the map; a clean map is unchanged. It is ALSO how a player who panned away
              re-enters the follow above: it sets the camera through the same `applyFightCamera`, so
              the frame starts keeping up with the battle again from that click. */}
          {fightId && (
            <Button
              size="icon"
              variant="warning"
              data-testid="map-focus-fight"
              onClick={() => focusFight(fightId)}
              aria-label="Focus the battle"
              title="Focus the battle"
            >
              ⌖
            </Button>
          )}
          <Button size="icon" onClick={() => zoomByFactor(BUTTON_ZOOM_STEP)} aria-label="Zoom in">+</Button>
          <Button size="icon" onClick={() => zoomByFactor(1 / BUTTON_ZOOM_STEP)} aria-label="Zoom out">−</Button>
          <Button size="icon" onClick={reset} aria-label="Reset view" className="text-xs">⟲</Button>
        </OverlayPanel>
      </OverlayRail>

      {/* bottom-left: player-facing marker key + hint (pointer-transparent — never blocks map gestures).
          Mirrors the markerStyle glyph semantics exactly: diamond port / circle waypoint / triangle hostile. */}
      {/* bottom-left: collapsible marker key — a small "Map key" chip by default so it never
          covers the map; expands to a readable vertical list (was a tiny wrapping block that
          sprawled across the bottom on narrow screens). */}
      <OverlayPanel slot="bottom-left" className="pointer-events-auto max-w-[calc(100vw-1.5rem)] text-sm text-ink-muted">
        <details>
          <summary className="cursor-pointer select-none list-none font-medium">Map key</summary>
          <div className="mt-2 flex flex-col gap-1.5 text-ink-faint">
            <span className="flex items-center gap-1.5">
              <svg viewBox="0 0 10 10" className="h-3 w-3" aria-hidden="true">
                <polygon points="5,0 10,5 5,10 0,5" fill="var(--color-accent)" />
              </svg>
              Port — dock &amp; trade
            </span>
            <span className="flex items-center gap-1.5">
              <svg viewBox="0 0 10 10" className="h-3 w-3" aria-hidden="true">
                <circle cx="5" cy="5" r="4" fill="var(--color-success)" />
              </svg>
              Safe
            </span>
            <span className="flex items-center gap-1.5">
              <svg viewBox="0 0 10 10" className="h-3 w-3" aria-hidden="true">
                <polygon points="5,0.5 9.5,9 0.5,9" fill="var(--color-danger)" />
              </svg>
              Hostile
            </span>
            {miningFields.length > 0 && (
              <span className="flex items-center gap-1.5">
                <svg viewBox="0 0 10 10" className="h-3 w-3" aria-hidden="true">
                  <polygon points="9.7,5 6.7,10 3.3,10 0.3,5 3.3,0 6.7,0" fill="var(--color-warning)" />
                </svg>
                Mining field — settle within range to extract
              </span>
            )}
            <span className="mt-1">Double-tap the map to command · tap a marker for details · drag to pan · scroll to zoom</span>
          </div>
        </details>
      </OverlayPanel>
    </div>
  )
}
