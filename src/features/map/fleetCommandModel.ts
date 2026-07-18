// S5 MAP-UX — the PURE composition model for the ONE bottom-center FleetCommandPanel (the
// overlayLayout/screenLayout idiom: pure module beside the component so react-refresh stays happy
// and the panel's section CONTRACT is unit-testable — tests/fleetCommandPanel.spec.ts). No
// React/DOM/fetch/state. The panel is a SHELL: it renders `sections` IN ARRAY ORDER and submits
// each row's prebuilt wire target verbatim — every verb decision below is a COMPOSE of the proven
// pure classifiers (classifyFleetCoordinateGo, unifiedMapSendAction, resolveStoppableFleets,
// teamDestinationKind, territoryAt, groupHuntAvailability, …), never a rewrite.
//
// ── NO-SOFTLOCK (the TeamMapStop law, carried) ────────────────────────────────────────────────────
// The stop section is derived from movement STATE ONLY (resolveStoppableFleets) — independent of
// target/tap/selection — and is ALWAYS the FIRST section whenever any owned fleet is in flight, so
// the brake can never hide behind a target gate or a scroll. The mount predicate deliberately ORs
// three independent legs: `stop rows ∨ target ∨ dockable parked fleets`.
//
// ── THE RAW-COORDS LAW (fleetGoTarget.ts, restated) ──────────────────────────────────────────────
// A point row's wire target is fleetGoRpcTarget(view) — the RAW tapped point, never the canonical
// preview (0208 rounds server-side). The spec pins the exact value (3.5 in → 3.5 out, never 4).

import type { FleetMovement } from '../fleets/fleetTypes'
import { fleetCommandState, type GroupRow, type ShipGroupMapEntry } from '../command/teamRoster'
import type { UnifiedGroupFleetLite } from '../command/teamApi'
import type { DockedTeamRollup } from '../command/teamRollup'
import {
  groupStopAvailability,
  resolveStoppableFleets,
  type StoppableFleetDescriptor,
} from '../command/teamStop'
import { unifiedMapSendAction, type GroupGoTarget } from '../command/teamMove'
import { returnPortOptions, teamDestinationKind, type ReturnPortOption } from '../command/teamDestination'
import { groupHuntAvailability } from '../command/teamCombat'
import {
  classifyFleetCoordinateGo,
  fleetGoButtonLabel,
  fleetGoRpcTarget,
  type FleetGoTargetView,
} from './fleetGoTarget'
import { territoryAt } from './territoryAt'
import { isDockablePortForDisplay, type MapLocation } from './mapTypes'

// ── THE ONE selection source (charter: kill the two-selection-source spaghetti) ───────────────────
// MapScreen owns this union: a space tap yields 'point' (GalaxyMap's onTargetPoint → the RAW world
// point resolved once through fleetGoTargetView); the existing marker selection (selectedId) DERIVES
// 'port' when the location is a legal fleet destination. Never two live targets: selecting a marker
// clears the point (MapScreen), and a bare-space tap clears the selection (GalaxyMap's svg onClick).
export type FleetCommandTarget =
  | { kind: 'point'; view: FleetGoTargetView }
  | { kind: 'port'; locationId: string }
  | null

export interface FleetCommandStopRow extends StoppableFleetDescriptor {
  canStop: boolean
}

/** One go/redirect row. `wire` is the EXACT commandShipGroupGo target the panel submits (raw point
 *  or {locationId}); null ⇔ the action is suppressed (already_here / docked_here badge). */
export interface FleetCommandGoRow {
  groupId: string
  name: string
  action: 'go' | 'redirect' | 'already_here' | 'docked_here'
  label: string
  wire: GroupGoTarget | null
}

export interface FleetCommandDockRow {
  groupId: string
  name: string
  portId: string
  portName: string
  /** Dock v1 wire = the existing instant go-to-port ({locationId}); see FleetCommandPanel's S4 note. */
  wire: { locationId: string }
}

export interface FleetCommandHuntRow {
  groupId: string
  name: string
  memberCount: number
  canHunt: boolean
  cmdActive: boolean
  /** Non-null → render the not-ready hint (memberCount > 0 and the readiness mirror failed). */
  readyHint: string | null
  /** Non-null → render the return-port picker (NO-HOME 0199: launch-from-dock lit + docked together). */
  returnPicker: { launchPortId: string; options: ReturnPortOption[] } | null
}

export type FleetCommandSection =
  | { kind: 'guidance' } // MAP-INTEGRATION M2: ships but NO fleet + a live target → point at Command
  | { kind: 'stop'; rows: FleetCommandStopRow[] }
  | { kind: 'context'; target: { kind: 'point'; view: FleetGoTargetView } | { kind: 'port'; locationId: string; locationName: string } }
  | { kind: 'go'; destination: { kind: 'point'; view: FleetGoTargetView } | { kind: 'port'; locationId: string; locationName: string }; rows: FleetCommandGoRow[] }
  | { kind: 'dock'; rows: FleetCommandDockRow[] }
  | { kind: 'hunt'; locationId: string; locationName: string; rows: FleetCommandHuntRow[] }

export interface FleetCommandModel {
  /** `stop rows ∨ target ∨ dockable parked fleets` (with groups), or the M2 groupless-guidance leg
   *  (`ships ∧ target` with zero groups) — the panel renders nothing when false. */
  mount: boolean
  /** Render IN ORDER. Stop (when present) is ALWAYS index 0 — the NO-SOFTLOCK pin. */
  sections: FleetCommandSection[]
}

// ── THE BRAKE DECOUPLING (S5 review fix) ─────────────────────────────────────────────────────────
// Consolidating the three panels put every verb behind ONE busy lock — which coupled the SAFETY
// BRAKE to go/dock/hunt requests. supabase-js has no client timeout, so a mover request that never
// settles would have left `busy` stuck and Stop disabled forever: a NEW softlock vector on the one
// control that must always work (pre-S5, TeamMapStop had its OWN busy state). The law, made pure
// and spec-pinned here: the brake's disabled verdict depends ONLY on the stop namespace — NEVER on
// another verb's in-flight request. The asymmetry is one-directional: non-safety verbs stay
// one-at-a-time AND yield to a firing brake. A stop racing a pending go is safe — the server
// serializes on the fleet lock, and the brake cancelling a go is the intended outcome.
export interface FleetCommandLocks {
  /** The brake's disabled verdict — true ONLY while a stop itself is in flight. */
  stopDisabled: boolean
  /** Non-safety verbs (go/dock/hunt + target-clearing chrome): any in-flight command blocks them. */
  verbDisabled: boolean
}

export function fleetCommandLocks(input: { busy: string | null; stopBusy: string | null }): FleetCommandLocks {
  return {
    stopDisabled: input.stopBusy !== null, // deliberately NEVER reads `busy` (the go/dock/hunt lock)
    verbDisabled: input.busy !== null || input.stopBusy !== null,
  }
}

export interface FleetCommandModelInput {
  target: FleetCommandTarget
  movements: readonly FleetMovement[]
  groups: readonly GroupRow[]
  /** The RUNTIME fleet_movement_unified_enabled flag (branches the stop verb + gates the go arms). */
  unifiedEnabled: boolean
  /** The group fleets, combat-sortie rows already excluded upstream (useGalaxyMapData's one filter). */
  unifiedFleets: readonly UnifiedGroupFleetLite[]
  rollups: readonly DockedTeamRollup[]
  locations: readonly MapLocation[]
  /** The shell's ONE ship list (selection.ships) — hunt-readiness statuses. */
  ships: readonly { main_ship_id: string; status: string }[]
  /** The live membership map (main_ship_id → group/command flags), from the shell's polled read. */
  membership: Readonly<Record<string, ShipGroupMapEntry>>
  launchFromDock: boolean
  fleetControlEnabled: boolean
}

export function buildFleetCommandModel(input: FleetCommandModelInput): FleetCommandModel {
  const { groups, locations, unifiedEnabled, target } = input

  // ── MAP-INTEGRATION M2 — the GROUPLESS-player guidance (the prod-majority dead end) ─────────────
  // A player whose ships are all berthed (no fleet) had ZERO movement affordance: this panel needs a
  // group for every verb, so selecting a port produced NOTHING, while PortScreen's empty state sent
  // them back to the Map — a circular dead end. The old posture ("groups.length === 0 → render
  // nothing") is kept for a player with no ships at all (nothing to guide) and for no live target
  // (the panel stays out of the way); but ships + a picked destination + no fleet now mounts ONE
  // guidance section pointing at Command, where TeamRosterPanel creates fleets. Deliberately NO
  // movement/composition controls here (charter §2a: composition is Command's) — guidance only.
  if (groups.length === 0) {
    const guide = input.ships.length > 0 && target !== null
    return { mount: guide, sections: guide ? [{ kind: 'guidance' }] : [] }
  }

  // 1 · STOP — state-predicated ONLY (NO-SOFTLOCK): never touches `target`.
  const stopRows: FleetCommandStopRow[] = resolveStoppableFleets(input.movements, groups, {
    unifiedEnabled,
  }).map((f) => ({
    ...f,
    // The pure reject mirror (TeamMapStop verbatim): lit gate, resolved group, non-empty by construction.
    canStop: groupStopAvailability({ gateEnabled: true, groupResolved: true, memberCount: f.fleetCount }).canStop,
  }))

  // 4 · DOCK — parked-in-space fleets inside a dockable port's territory (S2's territoryAt, the ONE
  // containment test; the smallest-radius overlap rule is its law, not re-derived here). Needs NO
  // target. Dark-inert by construction: unifiedFleets is [] while the flag is dark (the fetch gate).
  const dockRows: FleetCommandDockRow[] = groups.flatMap((g) => {
    const fleet = input.unifiedFleets.find((f) => f.group_id === g.group_id)
    if (!fleet || fleet.status === 'moving' || fleet.location_mode !== 'space') return []
    if (fleet.space_x === null || fleet.space_y === null) return []
    const orbit = territoryAt({ x: fleet.space_x, y: fleet.space_y }, locations)
    if (!orbit || !isDockablePortForDisplay(orbit.location_type)) return []
    return [{ groupId: g.group_id, name: g.name, portId: orbit.id, portName: orbit.name, wire: { locationId: orbit.id } }]
  })

  // 2/3/5 · the target-dependent sections. A port target is resolved through the ONE destination
  // classifier (teamDestinationKind); an unknown/illegal location fails closed to no target.
  let context: Extract<FleetCommandSection, { kind: 'context' }> | null = null
  let go: Extract<FleetCommandSection, { kind: 'go' }> | null = null
  let hunt: Extract<FleetCommandSection, { kind: 'hunt' }> | null = null

  if (target?.kind === 'point') {
    context = { kind: 'context', target: { kind: 'point', view: target.view } }
    if (target.view.withinBounds) {
      go = {
        kind: 'go',
        destination: { kind: 'point', view: target.view },
        rows: groups.map((g) => {
          const fleet = input.unifiedFleets.find((f) => f.group_id === g.group_id) ?? null
          const intent = classifyFleetCoordinateGo(fleet, target.view.canonical)
          return {
            groupId: g.group_id,
            name: g.name,
            action: intent,
            label: fleetGoButtonLabel(intent),
            // THE RAW-COORDS LAW: the wire carries the tapped point, never the canonical preview.
            wire: intent === 'already_here' ? null : fleetGoRpcTarget(target.view),
          }
        }),
      }
    }
  } else if (target?.kind === 'port') {
    const loc = locations.find((l) => l.id === target.locationId)
    const destKind = loc ? teamDestinationKind(loc) : null
    if (loc && destKind !== null) {
      const port = { kind: 'port' as const, locationId: loc.id, locationName: loc.name }
      context = { kind: 'context', target: port }
      if (destKind === 'expedition' && unifiedEnabled) {
        // UNIFIED-ARM-ONLY (the flag is LIVE; 4b-DROP retires legacy). The legacy three-arm
        // classifier (teamMapSendAction) is KEPT as a module — un-flip insurance is this gate.
        go = {
          kind: 'go',
          destination: port,
          rows: groups.map((g) => {
            const rollup = input.rollups.find((d) => d.groupId === g.group_id)
            const action = unifiedMapSendAction({
              dockedLocationId: rollup?.locationId ?? null,
              destinationId: loc.id,
            })
            return {
              groupId: g.group_id,
              name: g.name,
              action,
              label: 'Send fleet here',
              wire: action === 'go' ? { locationId: loc.id } : null,
            }
          }),
        }
      } else if (destKind === 'hunt') {
        // The absorbed TeamMapSend hunt arm (both worlds — hunts are not the unified mover's verb).
        hunt = {
          kind: 'hunt',
          locationId: loc.id,
          locationName: loc.name,
          rows: groups.map((g) => {
            const members = input.ships.filter((s) => input.membership[s.main_ship_id]?.group_id === g.group_id)
            const allHome = members.length > 0 && members.every((s) => s.status === 'home')
            const rollup = input.rollups.find((d) => d.groupId === g.group_id)
            const dockedTogetherId = rollup?.locationId ?? null
            // NO-HOME (0199): docked-together + launch-from-dock is hunt-ready; dark → home-only.
            const allReady = allHome || (input.launchFromDock && members.length > 0 && dockedTogetherId !== null)
            const commandCount = members.filter((s) => input.membership[s.main_ship_id]?.is_command_ship).length
            return {
              groupId: g.group_id,
              name: g.name,
              memberCount: members.length,
              canHunt: groupHuntAvailability({
                gateEnabled: true,
                groupResolved: true,
                memberCount: members.length,
                locationValid: true, // destKind === 'hunt' already proved it
                allMembersReady: allReady,
              }).canHunt,
              cmdActive: fleetCommandState({ commandCount, fleetControlEnabled: input.fleetControlEnabled }).active,
              readyHint:
                members.length > 0 && !allReady
                  ? input.launchFromDock
                    ? 'Every ship must be home, or the whole fleet docked together at one port, to hunt.'
                    : 'Every ship must be home to hunt.'
                  : null,
              returnPicker:
                input.launchFromDock && dockedTogetherId !== null && allReady
                  ? { launchPortId: dockedTogetherId, options: returnPortOptions([...locations], dockedTogetherId).options }
                  : null,
            }
          }),
        }
      }
    }
  }

  const sections: FleetCommandSection[] = []
  if (stopRows.length > 0) sections.push({ kind: 'stop', rows: stopRows }) // ALWAYS first
  if (context) sections.push(context)
  if (go) sections.push(go)
  if (dockRows.length > 0) sections.push({ kind: 'dock', rows: dockRows })
  if (hunt) sections.push(hunt)

  return {
    mount: stopRows.length > 0 || context !== null || dockRows.length > 0,
    sections,
  }
}
