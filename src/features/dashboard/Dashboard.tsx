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
      <header className="mb-8 flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight text-indigo-200">Byeharu</h1>
          <p className="text-sm text-white/40">{user?.email}</p>
        </div>
        <div className="flex items-center gap-2">
          <Link
            to="/galaxy"
            className="rounded-lg border border-indigo-400/30 bg-indigo-500/10 px-3 py-1.5 text-sm text-indigo-200 transition hover:bg-indigo-500/20"
          >
            🗺 Galaxy map
          </Link>
          <Link
            to="/map"
            className="rounded-lg border border-white/10 px-3 py-1.5 text-sm text-white/70 transition hover:bg-white/5"
          >
            List view
          </Link>
          <Link
            to="/reports"
            className="rounded-lg border border-white/10 px-3 py-1.5 text-sm text-white/70 transition hover:bg-white/5"
          >
            Reports
          </Link>
          <button
            onClick={signOut}
            className="rounded-lg border border-white/10 px-3 py-1.5 text-sm text-white/70 transition hover:bg-white/5"
          >
            Sign out
          </button>
        </div>
      </header>

      {game.error && (
        <div className="mb-6 rounded-xl border border-red-500/30 bg-red-500/10 p-4 text-sm text-red-300">
          {game.error}
        </div>
      )}

      {game.loading && !game.base ? (
        <p className="text-white/40">Loading command center…</p>
      ) : !game.base ? (
        <p className="text-white/40">No base found. Try reloading.</p>
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
