import { useShellState } from '../../app/shellState'
import { ShipStatusCard } from './ShipStatusCard'
import { ModulesPanel } from '../modules/ModulesPanel'
import { CaptainsPanel } from '../captains/CaptainsPanel'
import { RecruitCaptainPanel } from '../captains/RecruitCaptainPanel'
import { ShipSwitcher } from '../map/ShipSwitcher'
import { MAINSHIP_ADDITIONAL_ENABLED, TRADE_MARKET_ENABLED } from '../map/osnReleaseGates'
import { CommissionShipPanel } from './CommissionShipPanel'
import { PageHeader, Screen, screenRailClass, screenSplitClass } from '../../components/ui'

// UI-REBUILD (2b, Ship interior) — the Ship destination: ONE merged ship-status surface
// (ShipStatusCard — the audit-mandated MainShipPreview + MainShipPanel collapse; identity →
// right-now primary action → details), then the dark capabilities behind their server-lit gates,
// verbatim — surfaced only when lit, omitted otherwise (never dead panels).
//
// NO-SOFTLOCK: ShipStatusCard mounts UNGATED and renders Repair whenever the ship is disabled,
// matching the server's ungated repair safelock (0052).

export function ShipScreen() {
  const { game, map, selection: shipSelection } = useShellState()
  const lifecycleKey = `${map.mainShip?.status ?? 'n'}|${map.mainShip?.spatial_state ?? 'n'}|${map.mainShipSpaceMovement?.id ?? 'none'}|${map.mainShipSpaceMovement?.status ?? 'none'}`
  // TRADE-UI-1 — client selected-ship model, now the ONE shell instance (A0 lifted it here; Port's MarketPanel
  // reads the SAME selection). Consumed by the DARK ShipSwitcher only (compile-gated false + server-rejected).

  // UI R3 (composition): desktop ops split — main rail = the ship's vitals + the heavy outfitting
  // surface (Modules); aside rail = the crew roster surfaces (Captains/Recruit) + the dark ship
  // switcher. Everything but ShipStatusCard is dark today, so both extra groups render null and the
  // aside rail self-collapses (`empty:hidden`) — production shows exactly one full-width vitals
  // card, no hole. Mobile keeps today's top-down order. NO SectionLabels above the dark panels:
  // their lit-ness is server-decided at runtime, so a screen-owned header could label a void.
  return (
    <Screen wide>
      <PageHeader eyebrow="Ops · Vessel" title="Ship" subtitle="Your main ship" />
      <div className={screenSplitClass()}>
        <div className={screenRailClass('main')}>
          {/* THE ship surface: identity + hull integrity, the one right-now action (repair /
              travel countdown), cargo & fittings. Port-centric: no recall/return-home. */}
          <ShipStatusCard
            mainShip={game.mainShip}
            fleet={map.mainShipFleet}
            movements={map.movements}
            locations={game.locations}
            onChanged={async () => {
              await Promise.all([game.refresh(), map.refresh()])
            }}
          />
          {/* MODULES-P13 (dark, server-lit only): module crafting — renders null while the server
              rejects (module_crafting_disabled), so production is byte-unchanged. */}
          <ModulesPanel lifecycleKey={lifecycleKey} />
        </div>
        <div className={screenRailClass('aside')}>
          {/* CAPTAIN-P15 (dark, server-lit only): assign/unassign captains to this ship. */}
          <CaptainsPanel lifecycleKey={lifecycleKey} mainShipId={map.mainShip?.main_ship_id ?? null} />
          {/* CAPTAIN-P16 (dark, server-lit only): captain recruitment (progression). */}
          <RecruitCaptainPanel lifecycleKey={lifecycleKey} />
          {/* Multi-ship selection (dark, compile-gated false + server-rejected). TEAM-ACTIVATION
              PREP re-gate: the switcher was born under TRADE_MARKET_ENABLED only because TRADE-UI-1
              was its first multi-ship consumer — the selection itself is generic (modules, captains,
              market all address the selected ship), and a second ship now arrives via multi-ship
              COMMISSIONING, so either gate must light it. OR (not a move): trade can still light it
              independently. Still dark today — both constants are false. */}
          {(TRADE_MARKET_ENABLED || MAINSHIP_ADDITIONAL_ENABLED) && (
            <ShipSwitcher
              ships={shipSelection.ships}
              selectedShipId={shipSelection.selectedShipId}
              selectShip={shipSelection.selectShip}
            />
          )}
          {/* TEAM-ACTIVATION PREP (dark, compile-gated false + server-rejected): commission an
              additional main ship — the in-client path to ship #2+, beside the switcher (ship
              acquisition next to ship selection). Await→refetch: the new ship must appear in the
              ONE shell selection list + the game/map state, never optimistically. */}
          {MAINSHIP_ADDITIONAL_ENABLED && (
            <CommissionShipPanel
              ships={shipSelection.ships}
              onCommissioned={async () => {
                await Promise.all([shipSelection.refresh(), game.refresh(), map.refresh()])
              }}
            />
          )}
        </div>
      </div>
    </Screen>
  )
}
