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
  - **OPEN GAP (blocks merge):** the map has fleet Send/Hunt/Move (`TeamMapSend`) but **no fleet Stop**.
    Removing Stop from Command left NO group-stop UI anywhere. Step 2 must add a map fleet-Stop before
    this branch can merge (or the game loses stop). Do not admin-merge this branch until then.

**Production state changed TODAY (verified from prod game_config):**
- Deploy backlog cleared: prod resynced to main; migrations through 0206 deployed.
- Flags flipped ON: `mainship_coordinate_travel_enabled`, `launch_from_dock_enabled`
  (both via the Supabase SQL editor, owner-run). Coordinate travel + launch-from-dock are LIVE.
- PR #164 **merged** to main: fleet-row status colours + whole-row select + ghost-path fix.
- PR #163 **open**: the project map / 조직도 (`tools/projectmap`).

**Known live problem (needs the owner's DB, not fixable by the assistant alone):**
- ~4 orphaned ships stuck at `status='traveling', spatial_state=null` with NO live movement
  (wreckage of the pre-0206 cron abort). `select public.process_fleet_movements();` returned 0 —
  nothing due to settle. They need a direct state reset as part of retiring the per-ship layer (§2).

**Hard constraint — DB access:** the assistant holds only the public **read-only anon key**. Writing
flags / fixing ships / running migrations needs a write credential (session-pooler URI or service key)
that lives only in the owner's Supabase account. On THIS machine the owner was asked to drop it in
`byeharu-activate/db.env` (machine-local, NOT in git — so it will NOT be on the new computer; ask again
there if direct DB work is needed). SQL can't run locally (no psql/Docker) → migrations are proven by
the `osn3-*` real-chain CI on a disposable Postgres, then deployed through the owner's production gate.

**Next actions on resume (in order):**
1. Re-read §2 (the model) + §0 (the mistake) before touching anything movement-related.
2. **Step 2 (frontend, next):** add a fleet **Stop** to the map, closing the gap above. Then the map
   has Send/Hunt/Move/Stop — all movement on one surface. Verifiable locally (tsc/build/specs).
3. **Awaiting real data:** the owner was asked to run (SQL editor, read-only) a diagnostic joining
   `main_ship_instances` → `fleets` → `fleet_movements` for the ~4 ships stuck at `status='traveling'`
   — to see whether a dangling `fleet.active_movement_id`/`fleet_movements` row is holding them, and to
   ground the fleet↔group↔movement model for step 3. If the answer is in the chat history, use it;
   else re-request it. (`process_fleet_movements()` returned 0 — nothing due — so it is orphaned state.)
4. **Step 3 (server, big):** the ship_group (the player's "fleet") becomes the ATOMIC mover — one
   command, port OR coordinate, from any state, redirectable. Per-ship movement DELETED, not wrapped.
   Each its own migration, CI-proven on the `osn3-*` real-chain, owner-approved deploy.
5. **Step 4:** clean up the orphaned `traveling` ships + retire dead per-ship movement RPCs.
6. Never touch the protected dirty checkout `C:\Users\디폴리스\byeharu`; work in a fresh clone off main.
   DB writes need a credential the owner holds (see the "Hard constraint" note above); `db.env` is
   machine-local and will NOT be on the new computer — ask again there if direct DB work is needed.

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
