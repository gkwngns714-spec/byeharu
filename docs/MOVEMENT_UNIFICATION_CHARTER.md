# Byeharu — Movement Unification Charter

> Written 2026-07-16 after the owner (correctly) called the movement work spaghetti.
> Companion to `MAINSHIP_TRANSITION.md` §12 (OSN) and `SYSTEM_BOUNDARIES.md`.
> This is the spec the movement build follows. No movement change ships that is not
> a step toward the ONE model below.

## RESUME — read this first (the owner switched computers; assistant memory does NOT travel, this doc does)

**Where we are (2026-07-16):**
- The owner's movement model is settled and recorded below (§2): **the FLEET is the only unit of
  movement; a ship never moves on its own; all movement interaction is on the MAP; the per-ship
  movement layer is DELETED, not wrapped.** Build to §2/§3. Do NOT re-propose "group composes
  single-ship movement" — that was the recorded mistake (§0).
- **Branch `osn3-fleetmove-fromspace` — progress so far:**
  - The charter (this doc).
  - **Step 1 DONE + VERIFIED (commit `a4ba96b`, WIP, NOT merged):** movement controls removed from
    the Command screen (`TeamRosterPanel`) — no Send/Hunt/Stop/gather-hints; it is roster-only now.
    Verified: `tsc -b` exit 0, `vite build` exit 0, 66 team specs pass.
  - **Step 2 DONE + VERIFIED — the step-1 gap is CLOSED.** The map now has a fleet **Stop**, so all
    four movement verbs (Send/Hunt/Move/Stop) live on the map and §2a holds end-to-end.
    - `TeamMapStop.tsx` (new) + the derivation folded into the EXISTING `teamStop.ts` — no new server
      surface: `stopShipGroup` (teamApi → `stop_ship_group_transit`, 0164) and `groupStopAvailability`
      were already built and **orphaned with no caller**; step 2 is the caller.
    - `resolveStoppableFleets` is deliberately **NOT** `teamMarkers.resolveTeamMarkers`: that one drops
      any fleet whose segment can't be interpolated (right for drawing a badge, wrong for a brake — an
      un-drawable fleet is the one you most need to stop) and takes a `nowMs` a stop must not depend on.
      Same inputs, different question. A spec pins exactly this (`resolveTeamMarkers` → `[]` while
      `resolveStoppableFleets` → 1 row, on the same broken segment).
    - Placement: the top-left **rail**, mounted FIRST. All five overlay slots were taken; `bottom-right`
      (the intuitive home) works for its two per-SHIP stops only because they are mutually exclusive BY
      STATE — a fleet stop is a different movement owner and can be live alongside either, so a third
      absolute-positioned occupant would collide. A rail stacks and can't. First in the rail because a
      stop is a NO-SOFTLOCK safety CTA and must not hide below scrollable feature panels.
    - Stop is ONE click (no confirm): a hunt commits ships to combat, a stop is the recovery from a
      commitment and is idempotent server-side. A confirm in front of the brake is a hazard.
    - Verified: `tsc -b` exit 0, `vite build` exit 0, `eslint` exit 0, **703 specs pass** across 58 files
      (15 new). `tests/galaxy.spec.ts` fails on this machine — PRE-EXISTING and unrelated (it builds a
      Supabase client at module load and the runner has no `VITE_SUPABASE_URL`); confirmed identical on
      clean HEAD via `git stash`. Do not chase it as a regression.
  - **Merge status (steps 1-2):** the step-1 blocker is gone (the game no longer loses stop). Open as
    **PR #165**. Admin-merge and any deploy remain the owner's call.
  - **Step 3a BUILT + CI-PROVEN GREEN 2026-07-16 (migration `0207`, `command_ship_group_go`).** The owner
    decided "§2 wins, rewrite §3"; §3 above is the rewrite and this is its first step. **The ONE
    fleet-level mover**: one fleet per group (`main_ship_id NULL` — the hunt's proven shape), ONE
    movement, launches from wherever the group is, redirect = re-issue (cancels the live leg at its
    interpolated point). **It writes NOTHING to `main_ship_instances` — that omission IS §2**, and it
    composes no per-ship mover. DARK behind `fleet_movement_unified_enabled` (seeded false); purely
    additive — no existing function re-created, no table altered, so it cannot change prod behavior.
    - Proof: `scripts/fleetgo-proof.{sql,sh}` + `.github/workflows/osn3-fleetgo-realchain-proof.yml`
      (the `osn3-**` disposable-Postgres pattern; sources the shared `lib/trade-proof-lib.sh`).
      Markers: DARK / ONEFLEET / **NOSHIPWRITE** / SPEEDMIN / REDIRECT / GUARDS / ISOLATION.
    - **NOSHIPWRITE is the crown jewel**: every ship row is snapshotted and diffed BOTH ways across the
      go, the redirect, AND the rejected guards — if anyone ever adds an `update main_ship_instances`
      to the mover, it fails loudly. The selftest ALSO greps the migration statically for a ship
      UPDATE and for any composed per-ship mover; both greps were **mutation-tested** (inject the
      violation → the guard fires → restore → green), so they are not vacuous.
    - **CI: BOTH jobs green — all 7 markers pass on a real Postgres** (run `29500020505`). The §2
      crown jewel is CONFIRMED on the real chain: ship rows byte-identical across the go, the
      redirect, and the rejected guards. Speed independently = min(members). The redirect departs the
      exact interpolated midpoint on the SAME fleet, old leg cancelled.
    - **The proof earned its keep — it found 3 real bugs the local selftest could not.** Recorded so
      nobody reintroduces them:
      1. `record "v_fleet_row" is not assigned yet` — the origin branch was
         `if v_fleet is not null and v_fleet_row.status = ...`, relying on `AND` to short-circuit.
         **SQL's `AND` does not guarantee left-to-right evaluation**, and reading a field of an
         unassigned RECORD raises regardless. The `v_fleet is null` bootstrap must stay the FIRST
         branch. (A structure note in the file says so.)
      2. `stats_invalid` — 0166 nests its folds under **`totals`**; `v_stats->>'speed'` is NULL at the
         top level. Worse, the (correct) null-speed guard turned a plumbing mistake into a
         plausible-looking domain rejection. A proof that only checked rejections would have passed
         happily; it was caught only because the proof asserts the go SUCCEEDS on a healthy fixture.
      3. `fleet_set_moving: fleet not in idle state` — its frozen contract is `and status = 'idle'`.
         A redirect hands it a `moving` fleet, a port departure a `present` one. Fixed by RELEASING
         the fleet to idle (composing the primitive, §4) rather than hand-rolling around it — and that
         path was also **leaking an active dock presence**, so a departing fleet was docked and moving
         at once.
  - **Step 3b BUILT + CI-PROVEN GREEN 2026-07-16 (migration `0208`) — the fleet has a POSITION.**
    All **12** markers pass on the real chain (run `29503899715`).
    - **§3 undersold this step.** It framed 3b as "widen `target_type` + a settle branch". The real
      blocker, found against live prod: **`fleets` had NO position column at all.** A fleet's position
      was always IMPLIED (at a base / at a location / interpolated along a live leg). "Park the fleet
      at a coordinate" had nowhere to be written down — the OSN domain kept that on
      `main_ship_instances.space_x`, i.e. on the SHIP, which is exactly what §2 abolishes. So: new
      `fleets.space_x/space_y` + `location_mode='space'` + `target_type='space'` + the
      `fleet_set_in_space` leaf (the `fleet_set_present` sibling; `idle`, never `present` — open space
      has no presence row).
    - **The model now CLOSES:** a fleet flies to a raw coordinate, parks there, and sets off again
      from it with no port involved (marker FROMSPACE). Departing clears the parked coords, so a
      fleet is never both parked and under way.
    - **The live-cron delta:** `movement_settle_arrival` is re-created with exactly ONE inserted
      `elsif target_type='space'` before the final else; `location`/`base`/the `failed` fall-through
      are byte-identical to the 0153 head. Pinned at RUNTIME (SETTLEPARITY), not promised — and the
      0153 dock hunk is asserted as an **IFF against `mainship_space_location_target_legal`**, so it
      pins the RULE rather than a guess about which seed port qualifies (it resolved `legal=t`).
      No unsafe window existed: an unknown `target_type` settles as `failed`, but a `'space'` row
      could not exist before the CHECK widening, and the widening ships with the branch.
    - **The coherence CHECK is an IMPLICATION, not a biconditional — deliberately.**
      "`location_mode='space'` IFF coords present" is the natural constraint and would be WRONG:
      `fleet_complete` (frozen, shared) sets `location_mode='base'` **without** clearing coords, so a
      group fleet that parked in space and later completed would violate it and make that frozen
      helper start raising **for everyone**. §4 in practice: compose the frozen primitives; don't
      force them to change.
    - Bounds (±10000) are **copied** from `mainship_space_begin_move_core` (0067:133-134) so a fleet
      and a ship agree on the world's edges — **not a second authority**. Step 4 retires 0067; fold
      them into ONE bound then rather than leaving two copies. ⚠ Until then this is a knowing duplicate.
    - **ISOLATION now states §2 in one assertion:** after a fleet has flown to a coordinate, parked,
      and departed again, **ZERO ships carry a position** — with a vacuity guard proving a fleet
      really did (that guard fired on its own author first: the original asserted live coords, which
      the departure had correctly cleared).
    - Three more proof-harness bugs the matrix caught, all mine, all recorded so they don't recur:
      the `member_busy` fixture didn't restore itself and poisoned every later block; backdating only
      `arrive_at` violates `fleet_movements_check (arrive_at > depart_at)` because `now()` is
      txn-constant (both ends must move); and the vacuity guard above.
  - **⚠ THE `osn3-*` PROOF FLEET IS MOSTLY RED — AND WAS BEFORE ANY OF THIS WORK.** 8 of 9 osn3
    real-chain proofs FAIL on this branch (anchor1a, s2, s3, s4, s5, s6a, dock0, osn4; only anchor1b
    is green). **Not caused by 0207**: each fails identically at `d8ed494`, the frontend-only step-2
    commit that contains no migration at all. The cause is fixture rot — e.g. anchor1a dies on
    `null value in column "cargo_capacity_m3"`, an old fixture that INSERTs a ship row directly and
    predates that column's NOT NULL constraint. These workflows only trigger on `osn3-**` branches, so
    they never run on `main` and have been rotting unnoticed.
    **Consequence for this charter:** "CI-proven on the osn3-* real chain" is NOT a gate you can lean
    on today — most of that fleet is red for unrelated reasons, so a red X there means nothing until
    someone repairs the fixtures. `osn3-fleetgo-realchain-proof` is green and is the only one that
    speaks to this work. Do NOT read the PR's red checks as "step 3a is broken", and do NOT "fix" them
    by weakening a proof. Repairing the fixture rot is its own task, out of this charter's scope.
  - **Step 3b-3d NOT built** (coordinate target / group settle+reconciler / retire). Movement is NOT
    fixed until step 4: the four overlapping paths are all still live and untouched.

**Production state changed TODAY (verified from prod game_config):**
- Deploy backlog cleared: prod resynced to main; migrations through 0206 deployed.
- Flags flipped ON: `mainship_coordinate_travel_enabled`, `launch_from_dock_enabled`
  (both via the Supabase SQL editor, owner-run). Coordinate travel + launch-from-dock are LIVE.
- PR #164 **merged** to main: fleet-row status colours + whole-row select + ghost-path fix.
- PR #163 **open**: the project map / 조직도 (`tools/projectmap`).

**Known live problem — DIAGNOSED 2026-07-16 (the pending question is ANSWERED; see below):**
- 4 ships sit at `status='traveling', spatial_state=null`. **Nothing is holding them.** The
  diagnostic ran against prod and the verdict is unambiguous:
  - **Zero unresolved movements exist anywhere.** All 125 `fleet_movements` rows are terminal:
    106 `arrived`, 19 `cancelled`. `where resolved_at is null and arrive_at < now()` → **0 rows**.
  - **Every stuck ship's fleet has `active_movement_id = NULL` AND `active_space_movement_id = NULL`.**
    No dangling pointer, nothing to settle. (This is why `process_fleet_movements()` returned 0 —
    not a stall: there is genuinely nothing due.)
  - **Each ship's live fleet is `status='present'` at a real port** — `8f59d19c`/`209f7d66`/`268d904e`
    at `e834ad2a-eafa-43ea-9cee-0d0d86c2d33a`, `2aaec01b` at `99275d54-bff4-4ab0-82d0-86841b22fc01`.
    (`268d904e` and `209f7d66` also carry older `destroyed` fleet rows; `8f59d19c` carries ~10
    `completed` ones — fleet rows are per-trip history, so join on `status='present'` for the live one.)
- **The ships' `traveling` status is a LIE with nothing behind it.** The fleet layer already knows they
  arrived and are parked. This is §2 proving itself from live data: the fleet holds the truth, the
  per-ship status is orphaned wreckage of the retired layer. **Step 4 is therefore a plain status
  reset to match what the fleet already says — NOT a movement fix, no settle, no cron.**

**DB access — the earlier claim in this section was WRONG; corrected 2026-07-16 by direct test:**
- The assistant does **NOT** hold only the anon key. `.env.local` in the repo root carries
  `SUPABASE_SECRET_KEY`, `SUPABASE_ACCESS_TOKEN`, and `SUPABASE_DB_PASSWORD`, and they **work** — the
  diagnostic above was run with them, live against prod.
- **The working path:** `POST https://api.supabase.com/v1/projects/{SUPABASE_PROJECT_ID}/database/query`
  with `Authorization: Bearer {SUPABASE_ACCESS_TOKEN}` and body `{"query": "<sql>"}`. Node + `fetch`,
  no psql, no Docker, no `db.env`. Arbitrary SQL, reads and writes.
- So "SQL can't run locally" is true but **irrelevant** — prod's SQL endpoint is reachable over HTTPS.
  `byeharu-activate/db.env` is **not needed** and does not exist here. Do not ask the owner for a
  connection string; read `.env.local` first and test before claiming to be blocked.
- Migrations still go through the `osn3-*` real-chain CI on a disposable Postgres and deploy through
  the owner's production gate — that is a **process** rule (proof before prod), not a lack of access.
- **Still the owner's, not the assistant's:** prod WRITES (never run without an explicit go-ahead),
  `gh pr merge --admin`, and production deploy approvals. `gh` is authed here as `gkwngns714-spec`
  with `admin: true`, so the capability exists — the gate is authority, not credentials.

> **Lesson for the next fresh session:** this section previously listed three blockers that were all
> false. A handoff note claiming "the assistant lacks X" is a point-in-time guess and **decays** —
> spend the 30 seconds to TEST access before believing it and asking the owner for what you already
> have.

**Next actions on resume (in order):**
1. Re-read §2 (the model) + §0 (the mistake) before touching anything movement-related.
2. ~~Step 2 — add a fleet Stop to the map~~ — **DONE 2026-07-16** (see the progress block above). The
   map now owns Send/Hunt/Move/Stop; §2a holds end-to-end. **Step 3 is the next build.**
3. ~~Awaiting real data~~ — **DONE 2026-07-16.** The diagnostic was run by the assistant directly
   against prod (see the DIAGNOSED block above). No dangling `active_movement_id`, no unresolved
   `fleet_movements`, fleets `present` at real ports. Do not re-request it from the owner.
4. **Step 3 (server, big):** the ship_group (the player's "fleet") becomes the ATOMIC mover — one
   command, port OR coordinate, from any state, redirectable. Per-ship movement DELETED, not wrapped.
   Each its own migration, CI-proven on the `osn3-*` real-chain, owner-approved deploy.
   *Grounding from the diagnostic:* the live fleet is the `status='present'` row (fleet rows are
   per-trip history — `completed`/`destroyed` rows accumulate per ship), and movement state is
   already fleet-side only. The model in §2 is not a rewrite of live behavior so much as deleting a
   ship-side signal that is already carrying nothing.
5. **Step 4:** reset the 4 orphaned `traveling` ships to match their fleet's truth + retire dead
   per-ship movement RPCs. A plain status write — no settle path involved. **Owner go-ahead required
   (prod write).**
6. Never touch the protected dirty checkout `C:\Users\디폴리스\byeharu`; work in a fresh clone off main.
   The working clone on the owner's current machine is `C:\Users\gkwng\dev\byeharu`.
   Prod DB access WORKS from `.env.local` (see the corrected DB-access note above) — reads are free;
   **writes wait for the owner's explicit go-ahead**, as do admin-merges and deploy approvals.

## 0. The mistake this exists to stop repeating

Asked to make fleets move freely (port **or** open space), from anywhere, and change
course mid-flight, the assistant answered with **patches on the existing tangle**:
widen the group-move "docked" gate, flip `launch_from_dock_enabled`, bolt stop+move
together. Every patch fed the tangle. The owner had an explicit **no-spaghetti** rule
and a written plan (§12). The right move was to build **to** the plan, not around it.

## 1. The tangle (what exists today)

Movement is **four overlapping paths pretending to be one**:

- **Legacy single-ship:** `move_main_ship_to_location(p_fleet, p_location)`, settled by
  `process_fleet_movements` (the 30s cron; froze ships when it aborted pre-0206).
- **OSN single-ship:** `command_main_ship_space_move(x,y,req)` /
  `command_main_ship_space_move_to_location(loc,req)` / `command_main_ship_space_stop(req)`,
  settled by `process_mainship_space_arrivals`.
- **Group:** `move_ship_group_to_location` (port-only; composes the LEGACY mover; imposes a
  stricter "every member docked together at one port" gate) + `send_ship_group_*`.
- **Readiness rules diverged:** NO-HOME (0199) taught **Send** and **Hunt** to launch from a
  docked port, but **Move** never learned it — so Move still demands docked-at-home-port.

### ~~The foundational blocker (found 2026-07-16)~~ — **RETRACTED: this was FALSE**

> This section claimed the OSN single-ship commands resolve the ship with
> `select main_ship_id ... where player_id = v_player` — no ship id, no LIMIT — and were therefore
> not ship-addressable. **Checked against live prod 2026-07-16: they already are.**
> `command_main_ship_space_move(p_target_x, p_target_y, p_request_id, p_main_ship_id)`,
> `command_main_ship_space_move_to_location(p_location, p_request_id, p_main_ship_id)` and
> `command_main_ship_space_stop(p_request_id, p_main_ship_id)` all take a trailing `p_main_ship_id`
> and resolve through `mainship_resolve_owned_ship` (0083 for stop/move-to-location, 0178 for the
> coordinate move). The old §3's step 1 ("OSN-SHIP-ADDR — **Foundation**") was already done before
> it was written down.
>
> It is retracted rather than deleted because the *conclusion drawn from it* was the damage: it made
> "compose the per-ship movers" look like the natural next move, which is the §0 mistake. Under §2
> ship-addressability is **irrelevant** — the per-ship movers are being retired, so it does not
> matter whether a group *could* address them. It must not.

Group movement is stuck on the legacy port-only mover because `move_ship_group_to_location` **loops
`move_main_ship_to_location` per member** (0204:446) and inherits its docked-at-port gate — not
because of any addressability limit.

## 2. The ONE model (target — owner directive 2026-07-16, CORRECTED)

**THE FLEET IS THE ONLY UNIT OF MOVEMENT. A SHIP DOES NOT MOVE. Ships have no independent
position, no independent travel status, no per-ship move command.** A ship is a *member of a
fleet*; its location is simply its fleet's location. You command a **fleet**; the ships go
with it.

- **One moving thing:** the fleet. It has one position and one spatial state.
- **One command:** "fleet, go there." Target is a **port OR a world coordinate**.
- The fleet moves from **wherever it is** — no home/docked precondition.
- Re-issuable **mid-flight** to change course.
- **All movement interaction is on the MAP.** The Command screen has zero movement controls.

> **CORRECTION — the earlier draft of this charter was wrong.** It said "group movement
> *composes* single-ship movement," which keeps a per-ship movement layer alive. That duality
> (ship moves AND fleet moves) is the spaghetti. There is only the fleet. The per-ship movement
> layer is **retired**, not composed. This is what the owner meant by "the movement of ship is
> gone — ONLY FLEETS."

### What "retired" means (§11: transition, not hybrid-forever)

Delete the per-ship movement surface, do not wrap it:
- Per-ship move commands (`move_main_ship_to_location`, `command_main_ship_space_move`,
  `command_main_ship_space_move_to_location`, per-ship stop) are removed from the player path.
- A ship's `status`/`spatial_state` stops being a *movement* signal. Movement state lives on the
  **fleet**, once. (The orphaned `traveling` ships in prod are wreckage of the retired layer —
  cleaned up as part of the retirement, not settled as if they were real trips.)
- The map commands **fleets**. One resolver reads fleet position; ship markers derive from it.

### 2a. UI boundary — movement is a MAP concern (owner directive, 2026-07-16)

**ALL movement interaction lives on the map.** You move / redirect / stop a fleet by acting
on the map — tap a destination (port or open-space point), tap to redirect, tap to stop. The
**Command screen carries NO movement commands** — it owns roster, fleet composition, command
ship, and captains only. Any move/stop/redirect control currently in Command
(`TeamMapSend` / `TeamRosterPanel` send-hunt-move affordances) is **removed** and replaced by
map interaction. One surface owns movement; this is the anti-spaghetti boundary at the UI
layer, mirroring the one-command / one-resolver rule in the server.

## 3. Build steps (each its own migration; each CI-proven on real Postgres before deploy)

> **REWRITTEN 2026-07-16 (owner decision: "§2 wins, rewrite §3").** The previous §3 was written
> under the pre-correction draft and told the builder to make GROUP-GO "loop members and **compose**
> the ship-addressable OSN mover from each member's own state" — i.e. exactly the duality §2's
> CORRECTION repudiates. Composing N per-member movers yields N movements and N positions; §2 says
> **one** moving thing with **one** position. Building the old §3 would have built the §0 mistake
> while calling it progress. It also opened with OSN-SHIP-ADDR as "the foundation" — **already done**
> (see the stale-claims note below). These steps replace it. **Compose the frozen fleet-level
> primitives; never compose the per-ship movers — they are being retired, not wrapped.**

SQL cannot run locally (**verified 2026-07-16: no `psql`, no Docker**; the Supabase CLI is present
but `supabase start` needs Docker) — every step is proven by the `osn3-*` real-chain CI on a
disposable Postgres, then deployed through the owner's production approval. Nothing here flips a
flag or deploys as a side effect. **Prod DB access exists for READS** (see the DB-access note) —
that is how the ground truth below was established; it does not change the proof-before-prod rule.

### Ground truth this plan is built on (all verified against live prod, 2026-07-16)

- **The DB's `fleets` is NOT the owner's "fleet".** `fleets` is a per-ship, per-trip movement
  envelope (61 rows; 24 carry `main_ship_id`; a single ship accumulates ~10 historical rows). The
  owner's "fleet" is **`ship_groups`** (UI "team" → "fleet"). Never conflate them in code or prose.
- **`ship_groups` carries no position** (`group_id, player_id, group_index, name, created_at,
  updated_at`) — the mover has nowhere to stand yet.
- **The seam already exists and is proven.** `send_ship_group_hunt` (0168 → 0204) already builds
  **ONE fleet for the whole group** (`main_ship_id NULL`, `group_id` set), dissolving members' own
  fleets. That is §2's shape, already shipped and CI-proven. **GROUP-GO copies this, minus the ship
  writes.**
- **Retiring the per-ship coordinate layer is nearly free.** ZERO ships have a position
  (`space_x/space_y` null on all 76; `spatial_state` null×73 / `at_location`×3 — none `in_space`),
  `main_ship_space_movements` holds **3 rows** total (2 arrived, 1 stopped), `group_sortie_members`
  is **empty**. There is no data to migrate. The layer is dead weight carrying nothing.
- **`fleet_movements.target_type` allows only `base|location|zone` — NO coordinate target.**
  (`origin_type` DOES allow `'space'`, widened by 0156.) So §2's "port **OR** coordinate" target is
  **not** a single step: the port target rides the existing spine; the coordinate target needs the
  CHECK widened plus a settle branch. This is why 3a/3b split.
- **`fleets.group_id` is NOT a reliable "the group's fleet" key.** The legacy expedition send tags
  it onto **per-member** fleets (0204:316, display-only, "routing never reads it"). The unified
  mover's fleet is identified by `group_id = <g> AND main_ship_id IS NULL` — the hunt's shape.
- **Live flags (via the server's own `cfg_bool`, NOT the migration seeds — seeds are all `false`
  with `on conflict do nothing` and are NOT the truth):** ON = `mainship_send_enabled`,
  `mainship_space_movement_enabled`, `mainship_coordinate_travel_enabled`, `team_command_enabled`,
  `launch_from_dock_enabled`. OFF = `fleet_control_enabled`.
- **Stale claims removed from this doc:** §1's "foundational blocker — the OSN commands are not
  ship-addressable" is **FALSE**. `command_main_ship_space_move` / `_move_to_location` / `_space_stop`
  all already take a trailing `p_main_ship_id` and resolve via `mainship_resolve_owned_ship`
  (0083, 0178). The old §3 step 1 was already done before it was written.

### The steps

1. **GROUP-GO (port target)** — `command_ship_group_go(group, location)`. **The ONE fleet-level
   mover.** Resolves/creates the group's single fleet (`main_ship_id NULL`, `group_id` set — the
   hunt's proven shape), creates **ONE** `fleet_movements` row for it, and **writes NOTHING to
   `main_ship_instances`** — that omission *is* §2. Launches from wherever the group already is (its
   fleet's own state), with no home/docked precondition. **Redirect is the same call**: an active
   movement is cancelled at its interpolated point and a new leg departs from there — change-course
   is not a separate step, it is a property of having one mover. DARK behind a new
   `fleet_movement_unified_enabled`. Composes only fleet-level primitives (`movement_create`,
   `fleet_set_moving`) and D0's `calculate_group_expedition_stats` for speed (= min over members).
   **Locks: `ship_groups` FOR UPDATE → the group's fleet FOR UPDATE. NO member-ship locks** — the
   mover writes no ship rows, so 0164's lock-order-inversion deadlock class *disappears by
   construction* rather than being dodged.
2. ~~**GROUP-GO (coordinate target)**~~ — **DONE 2026-07-16, migration `0208`, CI-green.** Note the
   step as written UNDERSOLD the work: the blocker was not the CHECK, it was that **`fleets` had no
   position column at all**. The fleet now owns its position (`space_x/space_y` +
   `location_mode='space'`), `target_type` accepts `'space'`, `movement_settle_arrival` gained ONE
   parity-pinned branch, and the mover is `(group, {location | x,y})`. §2's "port OR world
   coordinate" is complete and the model closes (a parked fleet departs again with no port involved).
3. **GROUP-SETTLE (NEXT)** — the group fleet's arrival docks **the group** (presence keyed to the
   group fleet), and `process_mainship_expeditions` (the zombie reconciler) is taught that a member of
   a flying group is not a zombie. Guards the 0199 wedge below.
   *Grounding from 3b:* a coordinate arrival already settles cleanly (the fleet parks itself, no
   presence, no ship write). A **port** arrival already reuses the legacy `fleet_set_present` +
   `presence_create` and — because a unified fleet has `main_ship_id NULL` — skips the 0153 ship-dock
   hunk for free, so §2 holds through the settle today. What 3c actually owes: the members are
   currently invisible at the port the group docked at (nothing keys a member to the group's presence),
   and the reconciler has not been told that a `home`-status member of a flying group is not a zombie.
4. **RETIRE** (this absorbs the old step 4 and §2's "retired, not composed") — repoint the client to
   `command_ship_group_go`; drop `move_ship_group_to_location`, `send_ship_group_expedition`'s
   per-member loop, `move_main_ship_to_location`, `command_main_ship_space_move`,
   `command_main_ship_space_move_to_location`, `command_main_ship_space_stop`; then drop
   `main_ship_instances.space_x/space_y/spatial_state` as movement signals and retire the
   `process_mainship_space_arrivals` cron. Reset the 4 orphaned `traveling` ships here (a plain
   status write — the diagnostic proved there is nothing to settle). No dead path, no leftover flag.

### Known landmines (found 2026-07-16 — do not rediscover these the hard way)

- **The 0199 wedge (the real work of step 3).** `send_ship_group_hunt` makes one team fleet, but
  every *re-launch* path keys on a per-ship `main_ship_id`-tagged **present** fleet — so the 0199
  reconciler must **split** the team fleet back into per-member fleets. That per-ship assumption is
  baked into the re-launch surface and is what step 3c/4 must dismantle.
- **Lock-order asymmetry is load-bearing and unenforced.** `stop_ship_group_transit` deliberately
  takes NO ship lock (0164) to match the settle's movement→ship order, while
  `send_ship_group_expedition` and `move_ship_group_to_location` lock ships FIRST. They escape
  deadlock only because `movement_create` INSERTS a new movement rather than locking one. Nothing
  enforces this. GROUP-GO sidesteps it entirely by taking no ship locks at all.
- **`process_mainship_space_arrivals` lacks 0206's per-row subtransaction guard.** Its failure
  branches are `continue`-based so it is mostly safe, but an unexpected raise inside
  `mainship_space_dock_at_location` / `mainship_space_settle_space_arrival` would abort the whole
  100-row batch — exactly the failure 0206 was written to eliminate. Step 4 retires this cron; until
  then it is a latent batch-abort.
- **Two parallel movement domains that never share a row:** legacy (`fleet_movements` +
  `fleets.active_movement_id`, cron `process_fleet_movements` → `movement_settle_arrival`) and OSN
  (`main_ship_space_movements` + `fleets.active_space_movement_id`, cron
  `process_mainship_space_arrivals`). `main_ship_instances` is the shared ship-level state both
  write — which is precisely the duality §2 kills. **GROUP-GO lives in the legacy/fleet domain only.**

## 4. Standing rule

Before touching movement: re-read §12 + this charter. If a change adds a per-command
readiness branch or a new movement path, it is spaghetti — **stop**. Compose the frozen
primitives; never gate around them.
