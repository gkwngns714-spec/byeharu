import { useReducer } from 'react'
import { useShellState } from '../../app/shellState'
import { ShipStatusCard } from './ShipStatusCard'
import { ShipDossier } from './ShipDossier'
import { CaptainsPanel } from '../captains/CaptainsPanel'
import { RecruitCaptainPanel } from '../captains/RecruitCaptainPanel'
import { InventoryPanel } from '../inventory/InventoryPanel'
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
  // SHIP-DOSSIER — the screen's loadout revision: bumped by any panel AFTER a successful
  // loadout/inventory-changing command (assign/unassign/recruit — the captain panels; WORKSHOP
  // moved craft/fit to Port, whose route remount re-reads this screen's panels on return), folded
  // into the read panels' refresh key so ShipDossier + InventoryPanel re-read the server state the
  // command just changed (non-optimistic: the command panel refetched itself first, then pinged us).
  const [loadoutRev, bumpLoadoutRev] = useReducer((n: number) => n + 1, 0)
  const readRefreshKey = `${lifecycleKey}|r${loadoutRev}`
  // TRADE-UI-1 — client selected-ship model, now the ONE shell instance (A0 lifted it here; Port's MarketPanel
  // reads the SAME selection). Consumed by the DARK ShipSwitcher only (compile-gated false + server-rejected).

  // UI R3 (composition): desktop ops split — main rail = the ship's vitals + the per-ship dossier
  // (SHIP-DOSSIER: fitted modules · captains · cargo hold) + the heavy outfitting surface
  // (Modules); aside rail = the player's item inventory (SHIP-DOSSIER: live data, always lit) +
  // the crew roster surfaces (Captains/Recruit) + the dark ship switcher. The dark panels still
  // render null behind their server gates; the dossier + inventory are lit read surfaces, so both
  // rails now always have content. Mobile keeps top-down order. NO SectionLabels above the dark
  // panels: their lit-ness is server-decided at runtime, so a screen-owned header could label a void.
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
          {/* SHIP-DOSSIER — what is ON the selected ship (the ONE shell selection): the ship's
              own stats strip (SHIP-POWER) · fitted modules (lit, READ-ONLY — editing moved to
              Port → Workshop; seeing ≠ editing) · assigned captains (server-lit gated) · cargo
              hold (owner-read, works undocked). The captain panels beside stay the acting
              surfaces and ping loadoutRev after success. */}
          {/* key=ship id: switching ships (dark ShipSwitcher) REMOUNTS the dossier, so one ship's
              sections can never briefly wear another ship's name while the new reads land. */}
          <ShipDossier
            key={shipSelection.selectedShipId ?? 'no-ship'}
            selectedShip={shipSelection.selectedShip}
            refreshKey={readRefreshKey}
          />
          {/* WORKSHOP: ModulesPanel (craft & fit) moved to PortScreen — fitting is port-work
              (the 0114 settled-SAFE law); the dossier above keeps the read-only fitted view. */}
        </div>
        <div className={screenRailClass('aside')}>
          {/* SHIP-DOSSIER — the player's item inventory (player_inventory), previously visible
              NOWHERE except as 'have n' recipe hints. Live data, no feature flag — always shown.
              Aside home: these items feed RecruitCaptainPanel here and the Port Workshop's
              recipes (WORKSHOP moved ModulesPanel there; this read refetches on route remount). */}
          <InventoryPanel refreshKey={readRefreshKey} />
          {/* CAPTAIN-P15 (dark, server-lit only): assign/unassign captains to this ship. */}
          <CaptainsPanel
            lifecycleKey={lifecycleKey}
            mainShipId={map.mainShip?.main_ship_id ?? null}
            onChanged={bumpLoadoutRev}
          />
          {/* CAPTAIN-P16 (dark, server-lit only): captain recruitment (progression). */}
          <RecruitCaptainPanel lifecycleKey={lifecycleKey} onChanged={bumpLoadoutRev} />
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
