import { useShellState } from '../../app/shellState'
import { TeamRosterPanel } from './TeamRosterPanel'
import { CommissionShipPanel } from '../ship/CommissionShipPanel'
import { MAINSHIP_ADDITIONAL_ENABLED, TEAM_COMMAND_ENABLED } from '../map/osnReleaseGates'
import { PageHeader, Screen, screenRailClass, screenSplitClass } from '../../components/ui'

// FLEET-TAB (owner order 2026-08-03: "fleet info, i want fleet tab separately") — the fleet
// destination. Everything about OWNING fleets lives here, moved (not copied — one home per panel)
// from the Command screen:
//   · TeamRosterPanel — fleet composition (create/rename/delete, add/remove ships, command-ship
//     toggle), the per-fleet auto-retreat safety line (0310), the TeamDossier stats strip and the
//     per-ship breakdown. Its compile gate (TEAM_COMMAND_ENABLED) moves with it, verbatim.
//   · CommissionShipPanel — ship ACQUISITION rides with fleet COMPOSITION (the S6 re-home
//     principle: you buy a ship where you crew it); the Ships tab's no-ship empty state still
//     points at Command, because the FIRST ship comes from the Port-entry claim there.
//
// What deliberately does NOT live here (the boundaries that already exist):
//   · MOVEMENT — send/hunt/stop/move stay on the MAP (MOVEMENT_UNIFICATION_CHARTER §2a); this
//     screen renders zero movement controls, exactly like the roster panel it hosts.
//   · Per-ship EQUIPMENT/CONDITION — the Ships tab (ShipScreen), which keeps rendering the
//     grouping READ-ONLY through the same buildTeamRoster fold (a shared pure fold is composition,
//     not a second home).
//   · Live battles + reports — the Command screen (ops: what is happening / what happened).
//
// The nav tab that reaches this screen is gated on the SAME constant (navTabs.ts), so while
// TEAM_COMMAND_ENABLED is dark neither the tab nor the panels exist — never an empty destination.

export function FleetScreen() {
  const { game, map, selection } = useShellState()

  return (
    <Screen wide>
      <PageHeader
        eyebrow="Ops · Fleet"
        title="Fleet"
        subtitle="Group your ships into fleets — orders are given on the Map"
      />
      <div className={screenSplitClass()}>
        <div className={screenRailClass('main')}>
          {/* The fleet roster — the same panel, same gate, same wiring it had on Command. */}
          {TEAM_COMMAND_ENABLED && <TeamRosterPanel />}
        </div>
        <div className={screenRailClass('aside')}>
          {/* Ship acquisition beside composition (S6 principle). Compile-gated + server-rejected
              while the commission flag is dark; await→refetch — the new ship must appear in the
              ONE shell selection list + the game/map state, never optimistically. */}
          {MAINSHIP_ADDITIONAL_ENABLED && (
            <CommissionShipPanel
              ships={selection.ships}
              onCommissioned={async () => {
                await Promise.all([selection.refresh(), game.refresh(), map.refresh()])
              }}
            />
          )}
        </div>
      </div>
    </Screen>
  )
}
