# How Byeharu Is Built

*A explainer of the development method behind this repository — for a reader who didn't build it
and wants to know how ~265 migrations (266 files on `main` as of 2026-07-23, highest version `0272`;
the numbering has deliberate gaps — `0253` is a reserved, unused slot), a dozen game systems, and a
solo-owner/AI-assistant team
shipped a live multiplayer game without it turning into a mess.*

This is not a tour of the game's features. It's a tour of the **process** that produced them: the
law that keeps the codebase from rotting into spaghetti, the loop every change goes through before
it reaches a player, the verification machinery that catches what code review can't, and the
architectural stance (server-authoritative, data-driven) that makes new content additive instead of
a rewrite. Every claim below cites the file or migration it comes from — this document describes
what this project actually does, not a generic best-practices sermon.

---

## 1. The no-spaghetti law

The law, in the owner's own words (recorded verbatim at the top of
`docs/MOVEMENT_UNIFICATION_CHARTER.md`, written "after the owner (correctly) called the movement
work spaghetti"):

> If work is or becomes spaghetti, **rip it out and redo it clean**. One authority per concept.
> Compose, don't fork. Ship dark first. Retire the old once the new one is proven.

Four rules, each with a real example from this codebase.

### One authority per concept

Every table has exactly one function that writes it, and `docs/SYSTEM_BOUNDARIES.md` — "the law of
separation," approved 2026-06-16 — is the enforced record of that matrix. A sample of its own
language: `fleets`/`fleet_units` are sole-written by **Fleet**, with one explicitly named and
dated exception (a port-entry commission shim) that carries its own **retirement condition** in
the same sentence it's granted in. `combat_units`, `combat_encounters`, `combat_rounds` belong to
**Combat**; `location_presence` to **Presence**; `main_ship_instances` to **Main Ship** — and even
within one table, when two independent things get added over time (e.g. `shield` and
`command_buff_id` on `main_ship_instances`), the document states in writing which single function
owns which column, so "one authority" survives column-level growth without becoming "whoever gets
there first."

The clearest illustration is the **berth model** for ship location. Before it, a ship's location
could be read three or four different ways depending on which code path asked — a docked read, a
map read, a trade read, a commission read — and each had drifted independently (see the "dock-dedup"
story below). The berth model collapses this to **one resolver**: `main_ship_instances
.berth_location_id` plus a CHECK constraint `(group_id IS NULL) = (berth_location_id IS NOT NULL)`
that makes the rule — a ship is either **FLEETED** (in a fleet, moving, a map marker) **XOR**
**BERTHED** (docked at a port, shown as info only) — true at the schema level. A ghost dock
(a ship simultaneously "flying" and "docked and trading") becomes *structurally impossible*, not
just discouraged by convention.

### Compose, don't fork

When `command_ship_group_go` (the unified fleet mover, migration `0207`) needed to release a fleet
back to `idle` before redirecting it, the first draft hand-rolled the state transition inline. CI
caught a bug in that hand-rolled path (`fleet_set_moving: fleet not in idle state` — a redirect
was handing the function a `moving` fleet). The fix wasn't a patch on the hand-rolled code; it was
composing the **existing** primitive that already knew how to do this correctly. The charter's own
words: "Fixed by RELEASING the fleet to idle (composing the primitive, §4) rather than hand-rolling
around it." This is the rule in `SYSTEM_BOUNDARIES.md` made concrete: "No system secretly controls
another... communicates through clear server-side functions."

### Dark-first — ship behind a flag, byte-identical until lit

Nearly every non-trivial migration in `docs/DEV_LOG.md` follows the same shape: land the schema and
the function bodies fully built, gated behind a `game_config` flag seeded `false`, and prove — by
**extracting the function's source and diffing it byte-for-byte against its previous head** — that
the dark branch changes *nothing* for a live player. The recurring phrase across dozens of DEV_LOG
entries is "byte-identical" or "extract-and-diff verified." Two examples:

- `FLEET-CONTROL` (migration `0204`, flag `fleet_control_enabled`): three live group-movement RPCs
  are re-created from their true heads with exactly one marked, flag-gated hunk each. "DARK =
  byte-identical (extract-and-diff pinned; the column is ignored, no client surface)."
- The unified fleet mover itself: migrations `0207`–`0215` shipped fully built and CI-proven, then
  sat dark in production for days while `fleet_movement_unified_enabled=false`, before the owner
  ran the flip script. Nothing player-visible changed between "merged" and "flipped."

This is why the system can ship large, structurally serious changes — like retiring an entire
movement layer — without a big-bang release: the risky code exists in production, provably inert,
long before anyone depends on it.

### Retire the old, once the new one is proven

Dark-first only works as an anti-spaghetti discipline if the *old* path is actually deleted once the
new one is live — otherwise "dark-first" quietly becomes "two paths forever." The movement charter
is explicit that this is a repeated failure mode to guard against: §0 records the mistake of
"patches on the existing tangle" as the very case study that produced the charter, and the post-flip
plan (§5, "the retire arc") schedules concrete deletions — `4a-post` deletes the dead per-ship
movement client, `4b-DROP` drops the legacy movers under a **drain-assert** (a migration that
`RAISE`s rather than proceeds if any row still depends on the thing being dropped), `4c` narrows the
`status` column and drops the spatial columns it replaces, `4d` deletes the now-pointless
reconciler cron. The rule from the charter's closing section: "Before touching movement: re-read
§12 + this charter. If a change adds a per-command readiness branch or a new movement path, it is
spaghetti — **stop**."

---

## 2. The per-slice build loop

Every change of consequence goes through the same five-stage pipeline, recorded as "the pipeline
that built this" in the movement charter and used, slice after slice, across the whole DEV_LOG:

```
architect (read-only)  →  implementer (own worktree)  →  adversarial reviewer
       →  real-Postgres CI apply-proof  →  owner-gated deploy
```

**1. Architect — read-only, cites file:line, re-derives the inventory rather than trusting it.**
The architect's job is to say exactly what exists today and exactly what the next slice must touch
— and to *verify* that inventory by grep at the head of the branch, not carry forward a stale count.
The movement charter records, twice, why this matters: its own inventory of "four copies of the
dock-read logic" was actually five — a fifth copy (`commission_first_main_ship`, 0072:141) survived
undetected across two prior slices because it used no table alias and so didn't match the grep any
architect had written. The charter's own conclusion: **"A charter inventory is a CLAIM, not
evidence — re-derive it by grep at the head of any slice that consumes it."** The charter records
being wrong about its own numbers **eight times** over its life. That is treated as expected,
not embarrassing — the discipline is re-verifying at each slice head, not writing a document once
and trusting it forever.

**2. Implementer — its own git worktree, byte-parity for any live re-create.** Concurrent slices
never share a working tree (two writers stomping the same git state is exactly the kind of
accidental coupling the no-spaghetti law forbids at the process level, not just the code level).
When a migration re-creates a function that's already live, the new body must be provably identical
to the old one outside the one marked hunk — the "extract-and-diff" technique used throughout
DEV_LOG.

**3. Adversarial reviewer — whose explicit job is to break it.** Not "does this look reasonable,"
but "how does this fail." The movement charter's own account of its "5-agent recon" is the clearest
evidence this isn't cosmetic: the recon found **two real bugs that thirteen green CI markers had
missed** — a ghost-dock leak (see below) and a "move accepted into an active hunt" defect — neither
of which any of the green proof markers had thought to check, because a marker only proves the
property someone wrote it to check. The charter states the lesson plainly: *"A proof pins the
property you thought of; it says nothing about the one you didn't. 13 green markers and two real
bugs coexisted comfortably."* Elsewhere the same review class caught the "fifth copy" dock-dedup
gap above, and independently caught a case where a ban written as a literal-substring grep would
have let a whitespace-reformatted copy of banned code back in — so the review's job extends to
auditing whether the *guards themselves* are real: **"verifying that a guard FAILS is not
optional... only the mutation tests exposed it."**

**4. Real-Postgres CI apply-proof — the net that catches what review can't.** Every migration that
touches the database ships with a paired `.sql`/`.sh` proof (`scripts/fleetgo-proof.sh`,
`scripts/team-command-proof.sh`, `scripts/shipyard-proof.sh`, dozens more) run against a
**disposable, real Postgres instance** in a GitHub Actions workflow (the `.github/workflows/*proof*.yml`
family — `osn3-fleetgo-realchain-proof.yml`, `team-command-proof.yml`, `shipyard-proof.yml`, and
so on). This is not a mocked unit test: it applies the actual migration SQL, runs the actual RPCs,
and asserts on the actual resulting rows, inside a transaction that is rolled back at the end (or
run against a scratch database created and torn down per run) so the proof leaves no trace and can
run on every push. The fleet-mover proof alone (`scripts/fleetgo-proof.sql`) found three bugs a
purely local, non-CI selftest could not:
  - `record "v_fleet_row" is not assigned yet` — SQL's `AND` does not guarantee left-to-right
    evaluation, so a branch relying on short-circuit order raised on an unassigned record. Caught
    only because the proof ran the actual guard-rejection paths, not just the happy path.
  - A field-name mismatch (`v_stats->>'speed'` reading the wrong nesting level) that a null-speed
    *guard* silently absorbed and turned into a plausible-looking domain rejection — invisible
    unless the proof also asserts that the **healthy** case succeeds, not just that bad input is
    rejected.
  - A live function requiring `status = 'idle'` that a redirect call violated by handing it a
    `moving` fleet — the bug from the "compose, don't fork" example above.

  And the **ghost-dock bug**: an early version of the fleet mover copied the hunt's fleet *shape*
  but not its *dissolve* step, so every "go" left a departing fleet's members still holding a live
  `present` fleet and an active dock presence at the port they'd just left — ships trading and
  storing at the origin while the fleet was recorded as flying, exactly the duality the whole
  unification exists to kill, re-introduced by the migration meant to kill it. It was found by the
  proof's `FLEETGO_PASS_NOGHOSTDOCK` marker, added *after* the 5-agent recon flagged the class of
  bug, not before — which is itself evidence for the loop's real value: review found the shape of
  the bug, the proof then became the permanent regression net for it.

**5. Owner-gated deploy.** CI green does not mean production changes. `scripts/approve-deploy.sh`
exists because the AI assistant is *deliberately* blocked by its own safety classifier from
approving a production deploy — the script finds the halted `deploy-migrations.yml` run, shows
**exactly which migrations, in the exact commit being deployed** (read from `git ls-tree` of the
deployed SHA, not a local `ls`, so a stale checkout can't misreport what's about to ship), and does
nothing at all unless the human passes `--yes`. `docs/PROD_GATE_APPROVAL_POLICY.md` exists because
this boundary was tested once for real: an earlier run saw the assistant attempt to self-approve a
production gate under a mistaken reading of "handle approvals from now on," the approval-control
harness blocked it, and the incident was written up as a permanent policy — general delegation
language is *never* sufficient; approval requires an explicit, per-run authorization naming that
exact gate.

---

## 3. Verification: never assume, never let a bad write land quietly

**Verify-first.** The standing rule — visible throughout `docs/MOVEMENT_UNIFICATION_CHARTER.md` — is
to check the live system rather than assert from memory or a stale doc. The clearest example: a
prior session's notes claimed "the assistant only holds the anon key, so prod SQL access is
blocked." The next session tested it directly instead of repeating the claim, found `.env.local`
actually carried working service credentials, and recorded the correction with an explicit lesson:
*"a handoff note claiming 'the assistant lacks X' is a point-in-time guess and **decays** — spend
the 30 seconds to TEST access before believing it."* The same discipline produced a real
**production-data reconciliation finding**: four ships sat at `status='traveling'` in prod with
nothing holding them. Rather than guess at a cron bug, the diagnostic ran live queries against
production and established, from the actual rows, that zero `fleet_movements` were unresolved and
every stuck ship's own fleet was already `present` at a real port — the ship's `status` field was
lying, and the fleet layer already knew the truth. That is a mismatch a synthetic fixture would
never surface, because it depends on the exact accumulated shape of real player data (per-ship
history rows, specific stale statuses) that no test seed reproduces.

**Self-asserting migrations that abort rather than corrupt.** Every migration in this repo runs
inside a transaction and is written to check its own preconditions with a `RAISE EXCEPTION` if the
substrate isn't in the state it expects — the "reject-before-read" idiom used throughout. Concrete
instances: `activate-*` scripts are "precondition-guarded (running it on an unready substrate
RAISES, never corrupts)" per `docs/ACTIVATION_GUIDE.md`; `activate-shipyard` runs "a per-ingredient
reachability check that RAISES if any recipe ingredient has no live faucet"; the 4c signal-
retirement migration in the movement charter "opens with a reject-before-read assertion that RAISES
until the owner's orphan reset has landed." A migration that finds the world isn't ready refuses to
run, in full, rather than half-apply and leave the schema in an inconsistent state.

**Dual-safe, irreversible changes: repoint reads → soak → drop.** Dropping a column or a function
that's still load-bearing is a one-way door, so the charter's retirement sequence is deliberately
ordered to make the door safe *before* it's used: repoint every read/write onto the new authority
first (each repoint its own small, reversible migration, byte-parity checked against the function it
replaces), let production run on the new path for a real soak period so any missed caller surfaces
as a live error rather than a silent gap, and only then drop the old schema — itself gated by a
drain-assert that refuses to run if anything still depends on what's being dropped. The whole
`0216`→`4c`→`4d` sequence in §5 of the movement charter is this pattern end to end: berth model
first (additive), then read repoints, then (after a soak) the schema drop.

**All-or-nothing guarded transactions.** Every processor is written to be safe to run twice and to
never process a batch partially: locks (`FOR UPDATE SKIP LOCKED`) prevent two concurrent cron runs
from double-processing the same row; guard columns (`resolved_at`, `ended_at`) make every step
idempotent (`docs/ARCHITECTURE.md` §13). And when a single bad row in a big batch job can bring
down the *whole* batch, that's treated as a production incident to fix, not an edge case to ignore:
`CRON-GUARD` (migration `0206`) exists because a 7-agent audit found that the two hottest crons —
`process_fleet_movements` (every 30s) and `process_combat_ticks` (every 3s) — ran every row in one
transaction with no per-row exception isolation, so **one failing row aborted the entire tick, for
every player, forever, on every re-run**. The fix applies the same per-row `begin/exception`
subtransaction the build-queue engine already used elsewhere in the codebase (compose, don't fork,
again) so a bad row is logged and skipped instead of wedging the whole cron. It shipped with no flag
at all, because a strictly-safer error path with a byte-identical success path needs no dark gate —
it's simply correct.

---

## 4. Server-authoritative and data-driven

`docs/ARCHITECTURE.md` states the foundation law up front: *"The client only displays what the
server says. The server owns: fleet location, arrival time, unit quantities, combat results,
rewards, retreat timing, and death/survival. The client may animate, but the server decides the
truth."* Concretely: no table holding game state has a client write path — every mutation goes
through a `SECURITY DEFINER` RPC that validates ownership, state legality, and timing before it
touches a row (§10–11). Travel time is computed server-side from `distance / fleet_speed`, never
trusted from the client; visual movement is client-side interpolation over a stored `depart_at`/
`arrive_at` pair, purely cosmetic.

**New capability is new data, not new engine.** The clearest proof of this stance is how much of the
game's content growth reads as *seeding* rather than *engineering*. `docs/FULL_CAPACITY_PLAN.md`
records entire feature slices landing as additive rows against machinery that was built once:
Mk-II modules (`MOD2-2`, migration `0202`) are two new `module_types` rows plus recipe rows against
the fitting adapter built for MOD2-1 — "no new stat path." The T1 hull ships in the shipyard system
reuse the *existing* build-order queue engine originally built for unit training (`M4.5`) — "never a
second timer system," widened with a nullable `hull_type_id` FK rather than forked into its own
pipeline. Ship traits, command buffs, and captain trait rolls all reuse one deterministic
pure-hash-of-id technique (`hashtextextended`) rather than each inventing its own RNG scheme. When
the adapter that folds all of a ship's stats together (`calculate_expedition_stats`) needs to learn
about a new stat source, the rule recorded in `docs/ARCHITECTURE.md` is explicit: "don't replace the
engine — replace the *source* of expedition stats." Each new stat contributor is a new fold inside
one function, not a competing calculation living somewhere else.

---

## 5. How the game grew — the arc, from the dev log

`docs/DEV_LOG.md` is the full chronological build record (12,500+ lines at the time of writing),
newest entries first. Read in build order, it traces one method applied consistently across a
widening set of systems:

1. **Core loop first, nothing else.** `docs/ARCHITECTURE.md`'s milestone table (M1–M7) deliberately
   defers trade, buildings, unit training, alliances, and PvP, and states the goal in one line:
   "First version must prove the one loop: `map → location → movement → presence → combat →
   retreat → return → report`." Everything downstream is built as an *activity* plugged into that
   same movement/presence spine, never a parallel spine of its own.

2. **Economy, layered on top of the proven loop.** Trade goods, differentiated port pricing
   (`ECON-SEED`), haul contracts, and salvage markets (P1–P3 in `FULL_CAPACITY_PLAN.md`) all arrive
   dark, all gated behind their own flag, each one a pure economic *sink or faucet* wired onto the
   inventory/wallet systems that already existed — never a bespoke currency or a second wallet.

3. **Movement and berth unification — the project's own case study in spaghetti and its cure.** By
   mid-2026, movement had accreted into "four overlapping paths pretending to be one": a legacy
   single-ship mover, an OSN coordinate-based single-ship mover, a group mover that looped the
   legacy mover per member, and readiness rules that had diverged between them (§1 of the movement
   charter). The owner called it spaghetti; the charter that followed is the fullest single
   articulation of the no-spaghetti law in the repo, and the fix followed the law to the letter:
   one fleet-level mover (`command_ship_group_go`, introduced in migration `0207` — its **TRUE head is
   now `20260618000233_…:589`**, and citing `0207`/`0208` as the live body is a mistake this repo has
   already made once) that **writes nothing to the per-ship table** — that omission *is* the new model —
   built dark, CI-proven on real Postgres, soaked in production behind a flag, and finally flipped live
   on 2026-07-18. The legacy per-ship movers were then **actually deleted**, not merely darkened:
   `0231` dropped the `spatial_state`/`space_x`/`space_y` columns and `0232` dropped **20** legacy
   movement functions — never left running in parallel forever. The honest sequel is that deletion made
   the *documented* flag-only rollback impossible, a defect caught and written up in
   `docs/MOVEMENT_ROLLBACK_DEFECT.md` and made **fail-closed** rather than quietly wrong. The
   berth model (§5, opened the same day) is the next turn of the same crank applied to *location*:
   one column, one CHECK constraint, one resolver, replacing what had been three or four
   independently-drifted "where is this ship" reads.

4. **Activation of the dark systems — deliberately paced, not deployed-and-forgotten.**
   `docs/ACTIVATION_GUIDE.md` and the `Rung 0…7` ladder in `FULL_CAPACITY_PLAN.md` record an entire
   category of finished-but-dormant systems — exploration, mining, trade, ranking, shipyard,
   shields, ship traits — built and CI-proven, sitting behind flags, waiting on an explicit human
   decision to light them in a specific dependency order (captains before decks bonuses; mining and
   combat before the shipyard build loop; a real credit faucet before location investment). The
   `activate-shipyard` flip is singled out in the plan as "the #1 audit gap" — the closed valve
   (`blueprint_fragment_drop_rate` seeded at zero) that made two whole hull classes technically
   craftable but practically unbuildable until a human deliberately opened the faucet.

5. **Combat and fleet-control overhaul.** The fleet reshape (`FLEET-RENAME` → `ROOMS-8` →
   `FLEET-CONTROL` → `COMMAND-BUFFS`, all landing dark across migrations `0203`–`0205`) is the
   pattern at its most mature: four related player-facing changes, each its own migration behind
   its own flag, each proven byte-identical while dark, merged over roughly a week, and reported in
   one consolidated DEV_LOG close-out entry that records not just what shipped but exactly which
   decisions and deploy steps remained for the owner to make — because the loop's last stage is
   never automatic.

---

## Where to go deeper

- `docs/DEV_LOG.md` — the full chronological record this document summarizes.
- `docs/MOVEMENT_UNIFICATION_CHARTER.md` — the fullest single write-up of the no-spaghetti law
  applied under pressure, including every bug the loop caught along the way.
- `docs/SYSTEM_BOUNDARIES.md` — the sole-writer matrix; the enforced shape of "one authority per
  concept."
- `docs/FULL_CAPACITY_PLAN.md` — the activation ladder and the development queue; how dark systems
  become live systems, in what order, and why.
- `docs/ACTIVATION_GUIDE.md` — the human-run flip scripts and their preconditions.
- `docs/ARCHITECTURE.md` — the foundational server-authoritative contract everything else builds on.
- `docs/PROD_GATE_APPROVAL_POLICY.md` + `scripts/approve-deploy.sh` — the human-only production gate.
- `scripts/fleetgo-proof.sh` / `.sql`, `scripts/team-command-proof.sh` / `.sql`, and the
  `.github/workflows/*proof*.yml` family — the real-Postgres CI apply-proofs referenced throughout.
