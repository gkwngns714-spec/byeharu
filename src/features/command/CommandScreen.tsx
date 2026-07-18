import { useShellState } from '../../app/shellState'
import { useAuthStore } from '../../store/authStore'
import { PortEntryPanel } from '../portentry/PortEntryPanel'
import { FirstOrdersCard } from '../onboarding/FirstOrdersCard'
import { ActiveCombatPanel } from '../combat/ActiveCombatPanel'
import { ReportsSection } from '../combat/ReportsSection'
import { RankingPanel } from '../ranking/RankingPanel'
import { TeamRosterPanel } from './TeamRosterPanel'
import { CommissionShipPanel } from '../ship/CommissionShipPanel'
import { MAINSHIP_ADDITIONAL_ENABLED, TEAM_COMMAND_ENABLED } from '../map/osnReleaseGates'
import { PageHeader, Notice, Screen, SectionLabel, Skeleton, buttonClasses, screenRailClass, screenSplitClass } from '../../components/ui'

// UI-REBUILD (2b, Command interior) — the home-base destination in the shared design language.
// ONE focus per state, top-down: pending onboarding first (PortEntryPanel — server-authoritative
// self-hide, prominent accent card when an action is needed), then any LIVE battle
// (ActiveCombatPanel), then the base card (identity → quiet all-clear line → resources/garrison —
// the all-clear is suppressed while a battle holds the focus). Secondary sections follow: the ONE
// merged Reports history and the dark Ranking board (server-lit gate verbatim — omitted while
// dark, never a placeholder). Sign-out is a quiet account footer, not a primary action.
// Presentation only: every panel keeps its wiring/gating exactly; shared polled data from the shell.

export function CommandScreen() {
  const { game, combat, map, selection } = useShellState()
  const user = useAuthStore((s) => s.user)
  const signOut = useAuthStore((s) => s.signOut)
  const locName = (id: string | null) =>
    (id && game.locations.find((l) => l.id === id)?.name) || 'unknown'

  // UI R3 (composition): desktop ops split — main rail = the right-now surfaces (onboarding, live
  // battles, the dark team roster) over the always-lit battle history; aside rail = the dark
  // standings board + the quiet account block. Both rails keep an always-lit anchor (Reports /
  // Account), so neither is ever empty in production; the dark panels flow in when lit without
  // reshaping the screen. Mobile keeps today's top-down order (account last).
  return (
    <Screen wide>
      <PageHeader eyebrow="Ops · Base" title="Command" subtitle="Overview" />

      {game.error && <Notice tone="danger">{game.error}</Notice>}

      {game.loading && !game.base ? (
        // First-load placeholder in the same split frame (panel-shaped skeletons; sr-only status).
        <div className={screenSplitClass()} aria-busy="true">
          <div className={screenRailClass('main')}>
            <Skeleton className="h-28 rounded-card" />
            <Skeleton className="h-44 rounded-card" />
            <span className="sr-only">Loading…</span>
          </div>
          <div className={screenRailClass('aside')}>
            <Skeleton className="h-12 rounded-card" />
          </div>
        </div>
      ) : (
        <div className={screenSplitClass()}>
          <div className={screenRailClass('main')}>
            {/* OB-1 (plan §C P10) — the First Orders checklist, rail TOP: the first thing a new
                player sees. Read-only over the shell's already-polled state (zero own fetches);
                self-hides when all steps are done or the player dismisses it (localStorage). */}
            <FirstOrdersCard />
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
            {/* S6 re-home: ship ACQUISITION lives with fleet COMPOSITION (the Fitting tab's no-ship
                empty state points here). Compile-gated + server-rejected while the commission flag
                is dark; await→refetch — the new ship must appear in the ONE shell selection list +
                the game/map state, never optimistically. */}
            {MAINSHIP_ADDITIONAL_ENABLED && (
              <CommissionShipPanel
                ships={selection.ships}
                onCommissioned={async () => {
                  await Promise.all([selection.refresh(), game.refresh(), map.refresh()])
                }}
              />
            )}
            {/* The ONE reports surface (merged /reports page + inline dashboard list) — always lit,
                so the main rail is never empty (even "No battles fought yet" renders the card). */}
            <ReportsSection reports={combat.reports} locations={game.locations} unitTypes={game.unitTypes} />
          </div>
          <div className={screenRailClass('aside')}>
            {/* RANKING-P17 (dark, server-lit only): renders null while ranking_enabled is false. */}
            <RankingPanel lifecycleKey={user?.id ?? 'anon'} />

            {/* Quiet account block — always lit, so the aside rail is never empty; secondary by
                design (never competes with base actions). SectionLabel is safe here: it heads a
                statically-known-lit child, never a dark panel. */}
            <div>
              <SectionLabel>Account</SectionLabel>
              <footer className="flex items-center justify-between gap-3 border-t border-edge pt-3 text-xs text-ink-faint">
                <span className="truncate">{user?.email}</span>
                <button onClick={signOut} className={buttonClasses('ghost', 'sm')}>
                  Sign out
                </button>
              </footer>
            </div>
          </div>
        </div>
      )}
    </Screen>
  )
}
