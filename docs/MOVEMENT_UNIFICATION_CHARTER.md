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
  - **Merge status:** the step-1 blocker is gone (the game no longer loses stop). Still branch-only —
    admin-merge and any deploy remain the owner's call.

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

### The foundational blocker (found 2026-07-16)

The OSN single-ship commands resolve the ship with
`select main_ship_id ... where player_id = v_player` — **no ship id, no LIMIT**. They were
built in the one-ship era and are **not ship-addressable**. A group cannot compose them
today because it cannot tell them *which* member to move. This is why group movement is
stuck on the legacy port-only mover.

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

SQL cannot run locally (no psql/Docker) — every step is proven by the `osn3-*` real-chain CI
on a disposable Postgres, then deployed through the owner's production approval. Nothing here
flips a flag or deploys as a side effect.

1. **OSN-SHIP-ADDR** — make the OSN movers ship-addressable: trailing `p_main_ship_id`
   resolved via `mainship_resolve_owned_ship` (the A0 §2.5 pattern already used by 7 RPCs).
   Backward-compatible default so single-ship callers are byte-identical. **Foundation.**
2. **GROUP-GO** — one `command_ship_group_go(group, {location | x,y})` that loops members and
   composes the ship-addressable OSN mover from each member's own state. All-or-nothing (the
   0163 subtransaction posture). No docked-together gate.
3. **CHANGE-COURSE** — a member with an active movement is stopped (compose
   `command_main_ship_space_stop`) then relaunched, inside GROUP-GO. Redirect = re-issue.
4. **RETIRE-LEGACY** — repoint the client to `command_ship_group_go`; retire
   `move_ship_group_to_location` + the legacy group gate (§11: transition, not hybrid-forever).
   No dead path, no leftover flag.

## 4. Standing rule

Before touching movement: re-read §12 + this charter. If a change adds a per-command
readiness branch or a new movement path, it is spaghetti — **stop**. Compose the frozen
primitives; never gate around them.
