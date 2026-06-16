import { Link } from 'react-router-dom'
import { useAuthStore } from '../../store/authStore'
import { useGameState } from './useGameState'
import { BasePanel } from '../base/BasePanel'
import { SendFleetPanel } from '../fleets/SendFleetPanel'
import { FleetStatusPanel } from '../fleets/FleetStatusPanel'
import { useCombat } from '../combat/useCombat'
import { ActiveCombatPanel } from '../combat/ActiveCombatPanel'
import { CombatReportsView } from '../combat/CombatReportsView'

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

  return (
    <div className="mx-auto max-w-3xl px-6 py-10">
      <header className="mb-8 flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight text-indigo-200">Byeharu</h1>
          <p className="text-sm text-white/40">{user?.email}</p>
        </div>
        <div className="flex items-center gap-2">
          <Link
            to="/map"
            className="rounded-lg border border-white/10 px-3 py-1.5 text-sm text-white/70 transition hover:bg-white/5"
          >
            Galaxy map
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
          <SendFleetPanel
            base={game.base}
            units={game.units}
            unitTypes={game.unitTypes}
            locations={game.locations}
            onSent={game.refresh}
          />
          <FleetStatusPanel
            fleets={game.fleets}
            movements={game.movements}
            presences={game.presences}
            fleetUnits={game.fleetUnits}
            locations={game.locations}
            onChanged={game.refresh}
          />
          <CombatReportsView reports={combat.reports} locations={game.locations} unitTypes={game.unitTypes} />
        </div>
      )}
    </div>
  )
}
