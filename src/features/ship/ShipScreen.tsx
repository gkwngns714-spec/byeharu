import { useShellState } from '../../app/shellState'
import { MainShipPreview } from '../map/MainShipPreview'
import { MainShipPanel } from '../dashboard/MainShipPanel'
import { ModulesPanel } from '../modules/ModulesPanel'
import { CaptainsPanel } from '../captains/CaptainsPanel'
import { RecruitCaptainPanel } from '../captains/RecruitCaptainPanel'
import { ShipSwitcher } from '../map/ShipSwitcher'
import { useMainShipSelection } from '../map/useMainShipSelection'
import { TRADE_MARKET_ENABLED } from '../map/osnReleaseGates'
import { PageHeader } from '../../components/ui'

// UI-REBUILD (2b) — the Ship destination: the ship's own status. This slice RELOCATES the two
// existing ship-status surfaces unchanged (MainShipPreview: card + repair + the ONLY recall;
// MainShipPanel: derived status + destination countdown) — their MERGE into one surface is the
// Ship interior slice, not this structural one. Dark capabilities (modules, captains, multi-ship
// switching) keep their server-lit gates and are OMITTED while dark — never dead panels.
//
// NO-SOFTLOCK: MainShipPreview mounts UNGATED, so repair (the disabled-ship recovery, 0052
// safelock) is always reachable; only its recall block is flag-gated inside the panel, as before.

export function ShipScreen() {
  const { game, map } = useShellState()
  const lifecycleKey = `${map.mainShip?.status ?? 'n'}|${map.mainShip?.spatial_state ?? 'n'}|${map.mainShipSpaceMovement?.id ?? 'none'}|${map.mainShipSpaceMovement?.status ?? 'none'}`
  // TRADE-UI-1 — client selected-ship model. Consumed by the DARK ShipSwitcher only (compile-gated
  // false + server-rejected). NOTE for the trade lit-path: MarketPanel (Port) mounts its own
  // selection instance — lift the selection to the shell in the SAME change that lights the flag.
  const shipSelection = useMainShipSelection()

  return (
    <div className="h-full overflow-y-auto">
      <div className="mx-auto max-w-3xl space-y-4 px-4 py-4 sm:px-6">
        <PageHeader title="Ship" subtitle="Your main ship" />
        {/* Ship card: name/hull/status/speed/cargo/slots + REPAIR (always) + RECALL (flag-gated inside). */}
        <MainShipPreview
          sendEnabled={map.mainshipSendEnabled}
          fleet={map.mainShipFleet}
          onChanged={map.refresh}
        />
        {/* Phase 10H status view: derived status, destination + travel countdown (flag-gated as before). */}
        {game.mainshipSendEnabled && (
          <MainShipPanel
            mainShip={game.mainShip}
            fleets={game.fleets}
            movements={game.movements}
            locations={game.locations}
            onChanged={game.refresh}
          />
        )}
        {/* MODULES-P13 (dark, server-lit only): module crafting — renders null while the server
            rejects (module_crafting_disabled), so production is byte-unchanged. */}
        <ModulesPanel lifecycleKey={lifecycleKey} />
        {/* CAPTAIN-P15 (dark, server-lit only): assign/unassign captains to this ship. */}
        <CaptainsPanel lifecycleKey={lifecycleKey} mainShipId={map.mainShip?.main_ship_id ?? null} />
        {/* CAPTAIN-P16 (dark, server-lit only): captain recruitment (progression). */}
        <RecruitCaptainPanel lifecycleKey={lifecycleKey} />
        {/* TRADE-UI-1 (dark, compile-gated false + server-rejected): multi-ship selection. */}
        {TRADE_MARKET_ENABLED && (
          <ShipSwitcher
            ships={shipSelection.ships}
            selectedShipId={shipSelection.selectedShipId}
            selectShip={shipSelection.selectShip}
          />
        )}
      </div>
    </div>
  )
}
