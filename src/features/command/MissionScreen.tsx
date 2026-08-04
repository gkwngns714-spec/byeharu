import { useShellState } from '../../app/shellState'
import { PortEntryPanel } from '../portentry/PortEntryPanel'
import { FirstOrdersCard } from '../onboarding/FirstOrdersCard'
import { ActiveCombatPanel } from '../combat/ActiveCombatPanel'
import { foldRetreatDelaySeconds } from '../combat/retreatCountdown'
import { ReportsSection } from '../combat/ReportsSection'
import { RankingPanel } from '../ranking/RankingPanel'
import { useAuthStore } from '../../store/authStore'
import { HOW_A_FIGHT_STARTS } from './howAFightStarts'
import { NearMissSection } from '../combat/NearMissSection'
import { EmptyState, Icon, Notice, PageHeader, Screen, Skeleton, screenRailClass, screenSplitClass } from '../../components/ui'

// MISSION-TAB (owner order 2026-08-03: "make another tab of account - showing info as a whole,
// mission tab") — the ops destination, renamed from CommandScreen (one home per panel; /command
// redirects here). WHAT "MISSION" MEANS IN THIS GAME, from the audit rather than invention: the
// things a player is DOING and the record of what HAPPENED —
//   · onboarding steps (FirstOrdersCard checklist + the PortEntryPanel first-ship claim) — a new
//     player's literal first missions;
//   · live battles (ActiveCombatPanel per encounter) — the hunt sorties under way right now;
//   · battle reports (ReportsSection) — the mission history, already separated + foldable.
// Haul contracts are ALSO missions but stay on the Port screen: the contract board is port-scoped
// (get_port_contracts answers only for the docked port), so a global list here would need a new
// server read — out of a client-only slice. Exploration is server-dark. Neither got a stub panel:
// a tab must never open onto promises.
//
// The forces surfaces (roster/acquisition) folded into /fleet in the FLEET-TAB slice — that is
// the "Command folds into Fleet" half, already done. The account footer that used to anchor the
// aside rail moved to the top-corner AccountMenu (AppShell) — identity is checked, not commanded.
// Presentation only: every panel keeps its wiring/gating exactly; shared polled data from the shell.

export function MissionScreen() {
  const { game, combat, selection } = useShellState()
  const user = useAuthStore((s) => s.user)
  const locName = (id: string | null) =>
    (id && game.locations.find((l) => l.id === id)?.name) || 'unknown'

  // FIRST-RUN HONESTY: the "nothing under way" card renders only for a player who HAS a ship —
  // a shipless newcomer already sees the First Orders checklist + the claim-your-ship panel, and
  // a third card saying "nothing is happening" would bury the two that say what to do.
  const showQuietCard = !combat.encounters.length && selection.ships.length > 0

  return (
    <Screen wide>
      <PageHeader
        eyebrow="Ops · Mission"
        title="Mission"
        subtitle="What's under way — and what happened"
      />

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
            {/* OB-1 — the First Orders checklist, rail TOP: the first thing a new player sees.
                Read-only over the shell's already-polled state; self-hides when done/dismissed. */}
            <FirstOrdersCard />
            {/* RIGHT NOW #1 — onboarding (self-hides unless the server says an action is needed). */}
            <PortEntryPanel deps={{ onChanged: game.refresh }} />
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
                retreatDelaySeconds={
                  // THE RETREAT WINDOW, OR NOTHING. This used to read `?? 20`, and production's
                  // value is 8 (20260617000028_retreat_delay_8s.sql set the row; every tick since
                  // coalesces to 8) — a confident countdown 2.5x longer than the real escape
                  // window, shown at the one moment the player is deciding whether they can get
                  // out. fetchGameConfig omits a key entirely on a partial read, so `??` could not
                  // tell "missing" from "never fetched". The fold answers null and the panel then
                  // says nothing about timing — an unknown is never a plausible number.
                  foldRetreatDelaySeconds(game.config['retreat_delay_seconds'])
                }
                autoExit={combat.autoExit[enc.id]}
                onChanged={() => {
                  void combat.refresh()
                  void game.refresh()
                }}
              />
            ))}
            {/* EMPTY STATE with a next action: what this space is and how it fills. */}
            {showQuietCard && (
              <EmptyState
                data-testid="mission-quiet"
                icon={<Icon name="mission" size={28} />}
                title="Nothing under way"
                // HOW-A-FIGHT-STARTS: this used to read "…or into a pirate zone to hunt", which is
                // the instruction the owner followed for four straight trips that could never
                // start a fight — a zone is not a destination and the mover refuses combat
                // destinations outright. The words now come from the ONE authority
                // (howAFightStarts.ts) so this card can never drift from the map's own copy again.
                body={`Send a fleet to a port to trade. ${HOW_A_FIGHT_STARTS} Battles you start appear here live.`}
              />
            )}
            {/* WHAT HAPPENED #0 — near misses. A crossing that rolled an ambush and MISSED used to
                leave no trace anywhere in the game, which with the probabilistic ambush the owner
                chose to keep reads as "the combat system is broken". Self-hides when there are
                none; every word comes from the same model the map alert uses. */}
            <NearMissSection
              misses={game.interceptMisses}
              locations={game.locations}
              activeMovementIds={game.movements.map((m) => m.id)}
            />
            {/* The ONE reports surface — always lit, so the main rail is never empty (even
                "No battles fought yet" renders the card). */}
            <ReportsSection reports={combat.reports} locations={game.locations} unitTypes={game.unitTypes} />
          </div>
          <div className={screenRailClass('aside')}>
            {/* RANKING-P17 (dark, server-lit only): renders null while ranking_enabled is false.
                The rail self-collapses (empty:hidden) — no placeholder for a dark feature. */}
            <RankingPanel lifecycleKey={user?.id ?? 'anon'} />
          </div>
        </div>
      )}
    </Screen>
  )
}
