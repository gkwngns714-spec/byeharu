import { useShellState } from '../../app/shellState'
import { useAuthStore } from '../../store/authStore'
import { PortEntryPanel } from '../portentry/PortEntryPanel'
import { ActiveCombatPanel } from '../combat/ActiveCombatPanel'
import { ReportsSection } from '../combat/ReportsSection'
import { RankingPanel } from '../ranking/RankingPanel'
import { TeamRosterPanel } from './TeamRosterPanel'
import { TEAM_COMMAND_ENABLED } from '../map/osnReleaseGates'
import { PageHeader, Notice, buttonClasses } from '../../components/ui'

// UI-REBUILD (2b, Command interior) — the home-base destination in the shared design language.
// ONE focus per state, top-down: pending onboarding first (PortEntryPanel — server-authoritative
// self-hide, prominent accent card when an action is needed), then any LIVE battle
// (ActiveCombatPanel), then the base card (identity → quiet all-clear line → resources/garrison —
// the all-clear is suppressed while a battle holds the focus). Secondary sections follow: the ONE
// merged Reports history and the dark Ranking board (server-lit gate verbatim — omitted while
// dark, never a placeholder). Sign-out is a quiet account footer, not a primary action.
// Presentation only: every panel keeps its wiring/gating exactly; shared polled data from the shell.

export function CommandScreen() {
  const { game, combat } = useShellState()
  const user = useAuthStore((s) => s.user)
  const signOut = useAuthStore((s) => s.signOut)
  const locName = (id: string | null) =>
    (id && game.locations.find((l) => l.id === id)?.name) || 'unknown'

  return (
    <div className="h-full overflow-y-auto">
      <div className="mx-auto max-w-3xl px-4 py-4 sm:px-6">
        <PageHeader title="Command" subtitle="Overview" />

        {game.error && (
          <Notice tone="danger" className="mb-6">
            {game.error}
          </Notice>
        )}

        {game.loading && !game.base ? (
          <p className="text-ink-muted">Loading…</p>
        ) : (
          <div className="space-y-4">
            {/* RIGHT NOW #1 — onboarding (self-hides unless the server says an action is needed). */}
            <PortEntryPanel deps={{ onChanged: game.refresh }} locations={game.locations} />
            {/* RIGHT NOW #2 — live battles (only while an encounter exists). */}
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
            {/* Resources & garrison now live in the docked port's Hangar (Port tab). */}
            {/* TEAM-COMMAND Slice A (dark): read-only team roster. Not mounted while TEAM_COMMAND_ENABLED is
                false, so it never renders and its owner-reads never run — CommandScreen is visually unchanged
                for players until a human lights the gate. */}
            {TEAM_COMMAND_ENABLED && <TeamRosterPanel />}
            {/* The ONE reports surface (merged /reports page + inline dashboard list). */}
            <ReportsSection reports={combat.reports} locations={game.locations} unitTypes={game.unitTypes} />
            {/* RANKING-P17 (dark, server-lit only): renders null while ranking_enabled is false. */}
            <RankingPanel lifecycleKey={user?.id ?? 'anon'} />

            {/* Quiet account footer — secondary by design (never competes with base actions). */}
            <footer className="flex items-center justify-between border-t border-edge pt-3 text-xs text-ink-faint">
              <span className="truncate">{user?.email}</span>
              <button onClick={signOut} className={buttonClasses('ghost', 'sm')}>
                Sign out
              </button>
            </footer>
          </div>
        )}
      </div>
    </div>
  )
}
