// OB-1 (FULL_CAPACITY_PLAN §C P10) — "First Orders": the client-side first-session checklist,
// PURE core (no React/DOM/fetch/writes; the teamRoster.ts pure-module pattern).
//
// HARD BOUNDARY — zero new server surface, zero new fetches. Every done-condition here is derived
// ONLY from state the shell already polls/holds (src/app/shellState.ts):
//   · ship count        → selection.ships (the ONE shell ship list) ∨ map.mainShip (polled sole-ship read)
//   · docked            → map.mainShip.spatial_state === 'at_location' (the polled OSN spatial mode)
//   · won a battle      → combat.reports (polled; the SAME won-rule ReportsSection renders)
//   · expeditions lit   → game.mainshipSendEnabled (the server-lit send flag, already in the shell)
//   · additional ships  → MAINSHIP_ADDITIONAL_ENABLED (the compile gate mirroring the server flag)
//
// FLAG-AWARE: a step for a dark feature is OMITTED (never greyed, never a placeholder — the
// RankingPanel/TeamRosterPanel dark-surface convention), using the same lit signals the panels use.
//
// DROPPED FROM v1 (done-signal not client-derivable without a NEW fetch — honesty over coverage):
//   · "craft + fit a module" — fit/craft state is known only inside ShipScreen's ModulesPanel
//     fetches (panel-scoped, not shell-polled).
//   · "create a team" — group membership is known only inside TeamRosterPanel's owner-reads
//     (fetchOwnGroups/fetchShipMemberships, panel-scoped); the shell ship list carries no group_id.
//   · "hunt at the Snare" SPECIFICITY — generalized to "win your first hunt" (any won report);
//     pinning the done-condition to one location's name/id is brittle. The Snare stays in the HINT
//     copy (it is the seeded starter d10 hunting ground).
//
// LIVE-STATE SEMANTICS (documented, deliberate): done flags are derived from CURRENT server state,
// so a non-monotone signal can un-tick (a docked ship that launches is no longer docked). The one
// mitigation is structural, not stored: see the dock step's shipCount>=2 disjunct below.

// ── the structural input (a cheap projection of already-polled shell state) ─────────────────────
export interface FirstOrdersInput {
  /** Owned main ships (0 = pre-claim, 1 = starter, 2+ = fleet). */
  shipCount: number
  /** The (sole/selected) main ship is canonically docked at a port right now. */
  docked: boolean
  /** Any combat report the player would read as won exists (see isWonReport). */
  wonBattle: boolean
  /** Server-lit: expeditions/travel available (game.mainshipSendEnabled — already shell-polled). */
  expeditionsLit: boolean
  /** Lit: additional-ship commissioning (MAINSHIP_ADDITIONAL_ENABLED compile gate ↔ server flag). */
  additionalShipsLit: boolean
}

export type FirstOrderStepId = 'claim-ship' | 'dock-port' | 'first-hunt' | 'second-ship'

export interface FirstOrderStep {
  id: FirstOrderStepId
  label: string
  done: boolean
  hint: string
}

// ── the checklist derivation (order = the intended first session, plan §C P10) ──────────────────
/**
 * Derive the First Orders checklist from the structural projection. Steps for dark features are
 * OMITTED entirely; done flags mirror current server state (read-only — this module never grants,
 * never predicts, never persists).
 */
export function deriveFirstOrders(input: FirstOrdersInput): FirstOrderStep[] {
  const steps: FirstOrderStep[] = [
    {
      // First-ship commissioning is always lit (the PORT-ENTRY claim path owns the action).
      id: 'claim-ship',
      label: 'Commission your first ship',
      done: input.shipCount >= 1,
      hint: 'Claim your ship below — it docks at Haven, ready for orders.',
    },
  ]

  if (input.expeditionsLit) {
    steps.push({
      id: 'dock-port',
      label: 'Dock at a port',
      // `docked` is the live signal. The shipCount>=2 disjunct is NOT progression inference for
      // its own sake: the polled sole-ship read (map.mainShip) fails closed to null at N≥2 ships,
      // so the dock signal becomes unresolvable exactly when the LAST step completes — without
      // this, an unresolvable signal would pin the card open forever. Every commission docks the
      // ship, so the disjunct never invents a dock that didn't happen.
      done: input.docked || input.shipCount >= 2,
      hint: 'Pick a port on the Map — Haven, Slagworks or Driftmarch — and travel there.',
    })
    steps.push({
      id: 'first-hunt',
      label: 'Win your first hunt',
      done: input.wonBattle,
      hint: 'Send your ship to hunt pirates at the Snare (Wreck Belt) and come home in one piece.',
    })
  }

  if (input.additionalShipsLit) {
    steps.push({
      id: 'second-ship',
      label: 'Commission a second ship',
      done: input.shipCount >= 2,
      hint: 'Buy a second hull on the Ship screen and start building a team.',
    })
  }

  return steps
}

/** All visible steps done → the card auto-hides (nothing left to order). */
export function firstOrdersComplete(steps: readonly FirstOrderStep[]): boolean {
  return steps.length > 0 && steps.every((s) => s.done)
}

// ── projection helpers (still pure; the card composes these over shell state) ───────────────────

/** The canonical docked spatial mode (OSN-2, migration 0054) — the map resolver's docked signal. */
export const DOCKED_SPATIAL_STATE = 'at_location'

/**
 * The ONE player-facing "won" rule, mirrored from ReportsSection (src/features/combat/
 * ReportsSection.tsx: `won = r.result === 'escaped' || r.result === 'completed'`). The checklist
 * must never claim a battle was won that the reports card renders as "Fleet destroyed" — or vice
 * versa — so the rule is duplicated verbatim here and pinned by tests/firstOrders.spec.ts.
 */
export function isWonReport(result: string): boolean {
  return result === 'escaped' || result === 'completed'
}

/**
 * Project the already-polled shell state into the structural checklist input. Structural params
 * only (no shell types imported) so the boundary logic is unit-testable without React/Supabase.
 */
export function projectFirstOrders(args: {
  /** selection.ships.length — the ONE shell ship list (refetched on commission). */
  selectionShipCount: number
  /** map.mainShip presence — the POLLED sole-ship read (covers the pre-selection-refresh window). */
  polledShipKnown: boolean
  /** map.mainShip?.spatial_state — null/undefined for legacy or unresolved ships. */
  spatialState: string | null | undefined
  /** combat.reports — already polled by the shell (only `result` is read). */
  reports: readonly { result: string }[]
  expeditionsLit: boolean
  additionalShipsLit: boolean
}): FirstOrdersInput {
  return {
    // Two already-polled views of "how many ships": the selection list is authoritative but
    // fetch-once+refresh-on-commission, while map.mainShip is polled — max() lets the first
    // claim tick within a poll cycle instead of waiting for a reload.
    shipCount: Math.max(args.selectionShipCount, args.polledShipKnown ? 1 : 0),
    docked: args.spatialState === DOCKED_SPATIAL_STATE,
    wonBattle: args.reports.some((r) => isWonReport(r.result)),
    expeditionsLit: args.expeditionsLit,
    additionalShipsLit: args.additionalShipsLit,
  }
}

// ── dismissal key (pure builder; storage IO lives in FirstOrdersCard) ────────────────────────────
/**
 * localStorage key for the player's checklist dismissal — scoped PER USER so two accounts on one
 * browser never share a dismissal, and versioned so a future checklist revision can re-surface.
 * This is the codebase's FIRST client-side persistence (no prior localStorage use existed);
 * dismissal is pure UI preference — game state stays 100% server-authoritative.
 */
export function firstOrdersDismissKey(userId: string | null | undefined): string {
  return `byeharu.firstOrders.v1.dismissed:${userId || 'anon'}`
}
