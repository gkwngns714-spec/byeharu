import { Link } from 'react-router-dom'
import { useAuthStore } from '../../store/authStore'
import { useGameState } from './useGameState'
import { useSettleDueArrival } from '../map/useSettleDueArrival'
import { BasePanel } from '../base/BasePanel'
import { PortEntryPanel } from '../portentry/PortEntryPanel'
import { MainShipPanel } from './MainShipPanel'
import { ExpeditionLauncher } from '../map/ExpeditionLauncher'
import { FleetStatusPanel } from '../fleets/FleetStatusPanel'
import { useCombat } from '../combat/useCombat'
import { ActiveCombatPanel } from '../combat/ActiveCombatPanel'
import { CombatReportsView } from '../combat/CombatReportsView'
import { RankingPanel } from '../ranking/RankingPanel'
import { PageHeader, Notice, buttonClasses } from '../../components/ui'

/**
 * Command Center (home). Composes the M3 feature panels — base, send-fleet, fleet
 * status — over a single polled game-state hook. Each panel is presentational;
 * all mutations go through RPCs in the feature APIs. M2 map stays read-only.
 */
export function Dashboard() {
  const user = useAuthStore((s) => s.user)
  const signOut = useAuthStore((s) => s.signOut)
  const game = useGameState()
  const combat = useCombat()
  const locName = (id: string | null) =>
    (id && game.locations.find((l) => l.id === id)?.name) || 'unknown'

  // UX-CLEANUP item 6 (part B) — on-demand LEGACY arrival settle from the Command Center too: the
  // first-trip player usually waits HERE (MainShipPanel countdown), so when the main-ship fleet's
  // movement is due, settle it immediately instead of waiting on the 30s cron + poll. Same hook as the
  // Galaxy Map (routes are exclusive — only one instance is ever mounted); OSN movement isn't in this
  // screen's scope, so part A stays inert here (movement: null).
  const msFleet = game.fleets.find((f) => f.main_ship_id !== null && (f.status === 'moving' || f.status === 'returning')) ?? null
  const msMove = msFleet ? (game.movements.find((mv) => mv.fleet_id === msFleet.id && mv.status === 'moving') ?? null) : null
  useSettleDueArrival({
    mainShipId: game.mainShip?.ship?.main_ship_id ?? null,
    movement: null,
    legacyMovement: msMove,
    legacyFleetId: msFleet?.id ?? null,
    onSettled: () => void game.refresh(),
  })

  return (
    <div className="mx-auto max-w-3xl px-4 py-6 sm:px-6 sm:py-10">
      <PageHeader
        title="Byeharu"
        subtitle={user?.email}
        actions={
          <>
            <Link to="/galaxy" className={buttonClasses('primary', 'sm')}>
              🗺 Galaxy map
            </Link>
            <Link to="/reports" className={buttonClasses('ghost', 'sm')}>
              Reports
            </Link>
            <button onClick={signOut} className={buttonClasses('ghost', 'sm')}>
              Sign out
            </button>
          </>
        }
      />

      {game.error && (
        <Notice tone="danger" className="mb-6">
          {game.error}
        </Notice>
      )}

      {game.loading && !game.base ? (
        <p className="text-ink-muted">Loading command center…</p>
      ) : !game.base ? (
        <p className="text-ink-muted">No base found. Try reloading.</p>
      ) : (
        <div className="space-y-6">
          <BasePanel
            base={game.base}
            units={game.units}
            resources={game.resources}
            unitTypes={game.unitTypes}
          />
          {/* PORT-ENTRY: onboarding claim + finish-docking. Self-hides unless the caller's own ship state
              needs an action (server-authoritative; not flag-gated). Refreshes the command center on success.
              `locations` = the already-polled world map, for the display-only waypoint-vs-port split. */}
          <PortEntryPanel deps={{ onChanged: game.refresh }} locations={game.locations} />
          {/* Phase 10H: main-ship status in Command Center, gated by the master flag (hidden until launch). */}
          {game.mainshipSendEnabled && (
            <MainShipPanel
              mainShip={game.mainShip}
              fleets={game.fleets}
              movements={game.movements}
              locations={game.locations}
              onChanged={game.refresh}
            />
          )}
          {combat.encounters.map((enc) => (
            <ActiveCombatPanel
              key={enc.id}
              encounter={enc}
              locationName={locName(enc.location_id)}
              units={combat.units.filter((u) => u.encounter_id === enc.id)}
              unitTypes={game.unitTypes}
              events={combat.events.filter((e) => e.encounter_id === enc.id)}
              ticks={combat.ticks.filter((t) => t.encounter_id === enc.id)}
              retreatDelaySeconds={game.config['retreat_delay_seconds'] ?? 20}
              onChanged={() => {
                void combat.refresh()
                void game.refresh()
              }}
            />
          ))}
          <ExpeditionLauncher
            hasActive={game.fleets.some((f) => f.status === 'moving' || f.status === 'present' || f.status === 'returning')}
          />
          <FleetStatusPanel
            fleets={game.fleets}
            movements={game.movements}
            presences={game.presences}
            fleetUnits={game.fleetUnits}
            locations={game.locations}
            onChanged={game.refresh}
          />
          <CombatReportsView reports={combat.reports} locations={game.locations} unitTypes={game.unitTypes} fleets={game.fleets} />
          {/* RANKING-P17 (dark): server-lit leaderboard. Renders null while ranking_enabled is false
              (get_ranking_seasons → feature_disabled → not server-lit), so the Dashboard is byte-unchanged
              in production today. Reads ONLY the existing 0131 read RPCs; own standing derived client-side. */}
          <RankingPanel lifecycleKey={user?.id ?? 'anon'} />
        </div>
      )}
    </div>
  )
}
