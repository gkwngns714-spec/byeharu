import { useShellState } from '../../app/shellState'
import { useAuthStore } from '../../store/authStore'
import { BasePanel } from '../base/BasePanel'
import { PortEntryPanel } from '../portentry/PortEntryPanel'
import { ActiveCombatPanel } from '../combat/ActiveCombatPanel'
import { ReportsSection } from '../combat/ReportsSection'
import { RankingPanel } from '../ranking/RankingPanel'
import { PageHeader, Notice, buttonClasses } from '../../components/ui'

// UI-REBUILD (2b) — the Command destination: home base. Relocates the Dashboard's kept panels
// unchanged (base/production/resources, port-entry onboarding, live combat, dark ranking) and
// hosts the ONE merged Reports section (the old /reports page + the inline dashboard list folded
// into ReportsSection — reports come from the shell's combat state, expandable round logs fetch
// on demand). The retired surfaces (ExpeditionLauncher — the duplicate map path; FleetStatusPanel
// — all legacy fleets UI) are DELETED, not relocated. Shared polled data comes from the shell.

export function CommandScreen() {
  const { game, combat } = useShellState()
  const user = useAuthStore((s) => s.user)
  const signOut = useAuthStore((s) => s.signOut)
  const locName = (id: string | null) =>
    (id && game.locations.find((l) => l.id === id)?.name) || 'unknown'

  return (
    <div className="h-full overflow-y-auto">
      <div className="mx-auto max-w-3xl px-4 py-4 sm:px-6">
        <PageHeader
          title="Command"
          subtitle={user?.email}
          actions={
            <button onClick={signOut} className={buttonClasses('ghost', 'sm')}>
              Sign out
            </button>
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
                needs an action (server-authoritative; not flag-gated). Refreshes on success. */}
            <PortEntryPanel deps={{ onChanged: game.refresh }} locations={game.locations} />
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
            {/* The ONE reports surface (merged /reports page + inline dashboard list). */}
            <ReportsSection reports={combat.reports} locations={game.locations} unitTypes={game.unitTypes} />
            {/* RANKING-P17 (dark, server-lit only): renders null while ranking_enabled is false. */}
            <RankingPanel lifecycleKey={user?.id ?? 'anon'} />
          </div>
        )}
      </div>
    </div>
  )
}
