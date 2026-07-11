# Team-Command System

The player's designed endgame: command up to **3 teams × 6–8 ships** (~18–24 ships), each ship crewed by
6–8 captains; a team's skillset = ship attributes + captain skills. This is the game's own trajectory
(`docs/MAINSHIP_TRANSITION.md`, `docs/ROADMAP.md` — "expedition groups"), built in slices.

## Terminology — `group` (backend) == `team` (UI)

This mapping is **non-negotiable and kept explicit** everywhere:

| Layer | Word | Where |
|---|---|---|
| DB / SQL / server code | **group** | `ship_groups`, `main_ship_instances.group_id`, `group_index`, future `*_group` RPCs |
| Frontend / player-facing | **team** | "Teams" roster, "Team 1/2/3", team labels |

The DB never says "team"; the UI never says "group". Code that bridges the two (e.g. `teamRoster.ts`) carries
`group_id` on its data types but produces a "team" view for rendering.

## Anti-spaghetti law (enforced across ALL team slices)

1. A group must eventually resolve into the **existing `fleet_units` / `combat_units` combat input** — never a
   second combat engine.
2. Reuse the **existing `fleets` movement spine** — never a second movement engine.
3. RPCs stay `main_ship_id` / group-shaped (e.g. the existing `send_main_ship_expedition(p_ships jsonb, …)`).
4. group (code) = team (UI); **one** client selection source (`shellState.selection`).

## Slice status

- **Slice A — team/group data model + multi-ship enablement foundation (DARK). Done (migration 0160).**
- **Slice B0 — DARK group create/assign write path (the writer A omitted). Done (migration 0161).**
- **Slice B1 — DARK group delete RPC + interactive team UI. Done (migration 0162).**
- Slice B — send/stop **by team**, over the existing fleets spine. Broken into sub-slices:
  - **B-send — DARK group-send RPC (`send_ship_group_expedition`, loops the *unmodified* live send). Done
    (migration 0163).**
  - **B-stop — DARK group-stop RPC (`stop_ship_group_transit`, loops the *unmodified* live stop per member
    fleet). Done (migration 0164).**
  - **B-ui — team send/stop controls in the roster (dark, frontend-only). Done.**
  - **B-verify — disposable write-then-ROLLBACK proof of the dark team surface. Done
    (`scripts/team-command-proof.{sql,sh}` + `.github/workflows/team-command-proof.yml`, merged in #84 —
    a `.sql`/`.sh` proof, not the once-planned `.mjs`).**
- Slice C — captains (wire the dark CAPTAIN-P15/P16 system into teams). Broken into sub-slices:
  - **C0 — DARK read-only group expedition preview (`get_my_group_expedition_preview`, delegates per member
    to `calculate_expedition_stats`). RPC-only, zero data change — the captain-slot 2 → 6 bump (hull +
    instance) is deferred to activation. Done (migration 0165).**
  - **C1 — captain UI in the team roster (assignment surface per member ship + expedition-preview UI,
    dark, frontend-only, no migration). Done. ← this slice.**
  - C2 — captain progression wiring / lit-time polish (and any 6 → 8 slot raise). *Not started.*
- Slice D — team combat (largest; main-ship combat was never built — resolve a team into the existing combat
  engine per the law). Broken into sub-slices:
  - **D0 — DARK authoritative group expedition stats. Done (migration 0166; RPC-only, no flag flipped, no
    data change).** `calculate_group_expedition_stats` (service_role-only team-stats authority: per-member
    delegation to the *unmodified* `calculate_expedition_stats`, team-level folding ONLY — the eight additive
    0122 stat keys summed, `speed = min` member speed; **STRICT**: any member's refuse-don't-clamp raise
    refuses the WHOLE team context) + `get_my_group_expedition_totals` (thin gated client wrapper; any
    authority raise → one opaque `stats_invalid`). **Strict vs preview:** C0's
    `get_my_group_expedition_preview` stays the *friendly* per-member surface (`valid:false` + error per
    member); D0 is the *authoritative* context the combat consumer will read — it never clamps, never
    partial-totals, never leaks member detail.
  - **D1 — combat_units member widening + tick/report parity re-create. Done (migration 0167;
    schema + engine-branch only, NO member-row writer, no flag flipped).** `combat_units` can now carry a
    member main ship (`main_ship_id` XOR `unit_type_id`, frozen `attack_snapshot`/`defense_snapshot`); the
    LIVE `process_combat_ticks` (0046 head) and `report_create` (0026 head) were re-created with
    **legacy-byte-parity deltas only** (every delta is a `coalesce(member, legacy)` or a
    member-row-gated branch — and member rows have NO writer until D2, so live combat is provably
    unchanged). Three new internal leaves: `combat_fleet_return_speed`, `mainship_sync_combat_hp`,
    `mainship_mark_combat_destroyed`.
  - **D2 — hunt send + sortie manifest + encounter routing. Done (migration 0168; dark, no flag
    flipped, no frontend).** `group_sortie_members` (the sortie's membership SNAPSHOT — the
    **manifest-wins law**), `send_ship_group_hunt` (the combat twin of B-send over the 0050 narrow
    bridge: ONE fleet per team; power gate + speed from a per-member adapter fold over the locked
    member set — D0's folding law; members → `'hunting'`), the informational `fleets.group_id` tag,
    and `combat_create_group_encounter` — the FIRST writer of member `combat_units` rows
    (raise-free by construction: a bad member DEGRADES to an inert `alive_count=0` row, never
    poisoning the settle cron), routed by a single manifest-gated branch in the re-created
    `combat_create_encounter` (head 0023, diff-verified).
  - **D3 — team sortie settle semantics. Done (migration 0169; dark, no flag flipped, no
    frontend).** The member lifecycle loop closes: the combat tick's escape/forced-extract branch
    marks surviving members `'returning'` (via the ONE 0152 in-flight leaf), the 0050 reconciler
    re-homes members once their MANIFEST fleet is finished (with the exact-complement race guard:
    a `'moving'`/`'present'`/`'returning'` manifest fleet pins its members untouched), manifest
    rows are RETAINED (they die with their fleet via 0047's retention cascade — the sole-writer
    law keeps the reconciler off the manifest), retreat verified verbatim for team encounters, and
    the **M1 activation blocker is FIXED** (the live single send's ship write is now race-proof).
  - D4 — the frontend mirrors + dark Hunt UI (the client consumers of D0's totals). *Not started.*

---

## Slice A — what shipped

Migration `supabase/migrations/20260618000160_slice_a_ship_groups.sql`:

- **`ship_groups` table** — one row per `(player_id, group_index)`, `group_index ∈ 1..3` (caps a player at three
  teams, deterministic slot), owner-select RLS, **no client write path** (writes arrive with the Slice-B
  assignment RPC). Created empty.
- **`main_ship_instances.group_id`** (nullable, `→ ship_groups on delete set null`) — the ship→team link.
  `null` = ungrouped, which is the default and a valid state. Deleting a team un-groups its ships; it never
  deletes a ship.
- **`max_main_ships_per_player` raised 3 → 24** (3 teams × up to 8).
- **`team_command_enabled` flag seeded `false`** (server mirror of the compile-time gate).
- **Dropped the dead `get_main_ship(uuid)`** (migration 0043) — service_role-only, no caller in `src/`,
  `tests/`, or any RPC; it used the unguarded single-ship shortcut that returns an arbitrary row under
  multi-ship. Removing it clears the last arbitrary-ship reader before multi-ship can ever be lit.

Frontend (all behind the gate below):

- `src/features/map/osnReleaseGates.ts` — `TEAM_COMMAND_ENABLED = false` (compile-time mirror).
- `src/features/command/teamRoster.ts` — pure logic: `buildTeamRoster`, `resolveOwnedGroup`,
  `commissionAvailability` (unit-tested in `tests/teamRoster.spec.ts`, `npm run verify:team:unit`).
- `src/features/command/teamApi.ts` — owner-scoped reads of `ship_groups` + the group-membership map.
- `src/features/command/TeamRosterPanel.tsx` — **read-only** roster; lists ships grouped into teams and lets
  the player pick the selected ship. Uses the ONE shell selection (`shellState.selection`) for the ship list +
  selection — it never mounts a second selection source; it only fetches the group metadata the shell doesn't
  carry. **No team travel, no combat, no commissioning.**
- `src/features/command/CommandScreen.tsx` — mounts the roster behind `TEAM_COMMAND_ENABLED`.

## Slice B0 — what shipped

Migration `supabase/migrations/20260618000161_slice_b0_group_write_path.sql` — the DARK, owner-scoped **write
path** Slice A deliberately omitted (Slice A created `ship_groups` empty with no writer):

- **`mainship_resolve_owned_group(p_player, p_group_id)`** — internal owned-group resolver mirroring
  `mainship_resolve_owned_ship`, but **explicit-only**: it has NO sole-group shim on `null`, because for
  assignment `null` means *unassign*, not *resolve the sole group*. Returns a group only when it exists and
  belongs to `p_player`. No client grant.
- **`upsert_ship_group(p_group_index, p_name)`** — create/rename a team slot (`group_index ∈ 1..3`). Upserts
  on the `(player_id, group_index)` unique key; the unique constraint × the 1..3 CHECK cap a player at three
  teams **declaratively**, so no lock/`count(*)`. Validates index + name in-RPC to exactly match the column
  CHECKs (never accept-then-violate).
- **`assign_ship_to_group(p_main_ship_id, p_group_id)`** — assign an owned ship to an owned team, or
  **unassign** (`p_group_id null`). Resolves the ship via `mainship_resolve_owned_ship` and the group via
  `mainship_resolve_owned_group`, **both against the same `auth.uid()`** — this closes Slice A's single-column-FK
  **same-player gap** by construction (as the sole write path, a cross-player pairing is unreachable).

Both client RPCs **reject-before-read** on `cfg_bool('team_command_enabled')` (still `false`) — dark, no flag
flipped, no `game_config` write. Reject vocabulary: `not_authenticated` → `team_command_disabled` →
`invalid_group_index`/`invalid_name` (upsert) or `ship_not_found`/`group_not_found` (assign) → `ok`.

Frontend (still dark; UI deferred to Slice B):

- `src/features/command/teamMutations.ts` — pure client mirror of the two RPCs' reject order
  (`groupUpsertAvailability`, `assignAvailability`), display-only. Unit-tested in `tests/teamMutations.spec.ts`
  (`npm run verify:team:unit` now runs both team specs). **No `teamApi` wrappers and no interactive assign/rename
  UI this slice** — those land with Slice B's team UI so the roster stays read-only until then.

## Slice B1 — what shipped

Migration `supabase/migrations/20260618000162_slice_b1_group_delete.sql` + the interactive (still dark) UI:

- **`delete_ship_group(p_group_id)`** — DARK, owner-scoped delete of a team slot. Order: auth →
  `cfg_bool('team_command_enabled')` gate → resolve owned group → **lock `FOR UPDATE` + revalidate `FOUND`** →
  delete → `{ok, reason}`. Members are un-grouped by the 0160 `ON DELETE SET NULL` FK — **no manual member
  update**. Reject vocab: `not_authenticated` → `team_command_disabled` → `group_not_found` → `ok`. The
  `FOR UPDATE` conflicts with B0 assign's `FOR SHARE`, so assign and delete **serialize** (and both lock the
  group row before touching child ship rows → no deadlock); a double-delete loser re-reads zero rows under the
  lock and fails closed. ACL: `authenticated`-only. No flag flipped, no `game_config` write.
- **`teamApi` write wrappers** — `upsertShipGroup`, `assignShipToGroup`, `deleteShipGroup` over the B0/B1 RPCs
  (normalize-don't-throw, the dark-RPC style). Server is the sole authority; `{ok:false}` is a normal outcome.
- **`TeamRosterPanel` is now interactive** (still behind `TEAM_COMMAND_ENABLED`): create a team (only when a
  slot 1–3 is free, via `nextTeamSlot`), rename, delete (with an inline confirm), and assign/unassign a ship.
  **No optimistic UI** — every mutation awaits the server then refetches both group reads, so the view can't
  diverge from server truth. Still uses the ONE shell selection for the ship list + selected-ship pointer — no
  second selection source; no team travel/combat.
- **`nextTeamSlot` pure helper** (in `teamRoster.ts`) — lowest free slot 1–3 or null (capped), unit-tested in
  `tests/teamRoster.spec.ts`.

## Slice B (B-send) — what shipped

Migration `supabase/migrations/20260618000163_slice_b_group_send.sql` — the first movement-touching team slice,
DARK, and **without editing any live function**:

- **`send_ship_group_expedition(p_group_id, p_location)`** — resolves an owned team and **loops the unmodified
  live `send_main_ship_expedition` once per member**, inside ONE all-or-nothing subtransaction. It writes **no**
  `fleets`/movement row directly — every movement write is delegated to the live send, so there is no second
  movement engine (anti-spaghetti #2). Order: auth → `cfg_bool('team_command_enabled')` gate → resolve owned
  group → lock group `FOR SHARE` + revalidate → gather members → lock member ships `FOR UPDATE` → loop-send in
  a subtransaction. Reject vocab: `not_authenticated` → `team_command_disabled` → `group_not_found` →
  `empty_group` → `member_send_failed` → `ok`. ACL `authenticated`-only.
- **Why a wrapper, not an N-ship generalization:** `send_main_ship_expedition` is LIVE (gated
  `mainship_send_enabled=true`) and hard-clamps to exactly one ship; widening it would mutate the live
  single-ship path. The wrapper leaves it byte-for-byte unchanged.
- **Atomicity + concurrency:** any member's send raising rolls back the whole team (never half-sent). Group-row
  `FOR SHARE` serializes vs `delete_ship_group`'s `FOR UPDATE`; member-ship `FOR UPDATE` closes the concurrent
  double-send window the live single-ship send leaves open; group-first-then-ships lock order → no deadlock.
- **Frontend:** `src/features/command/teamSend.ts` — pure `groupSendAvailability` mirror (dispatchable-or-not),
  unit-tested in `tests/teamSend.spec.ts`. **No UI this slice.**

## Slice B (B-stop) — what shipped

Migration `supabase/migrations/20260618000164_slice_b_group_stop.sql` — the STOP twin of B-send, DARK, no live
function edited:

- **`stop_ship_group_transit(p_group_id)`** — resolves an owned team and **loops the unmodified live
  `command_main_ship_stop_transit(fleet)`** (STOP=HOLD, 0155) once per member's in-flight fleet. Same pre-read
  guards as B-send (auth → `team_command_enabled` gate → resolve group → group `FOR SHARE` + revalidate →
  gather members → member ships `FOR UPDATE`).
- **Best-effort, NOT all-or-nothing** (the deliberate difference from send): stop is idempotent + monotonic, so
  each member runs in its own subtransaction and a member with no in-flight fleet (home/docked/OSN-parked) or
  already held is a legitimate **skip**, not a team abort. Result is always `ok:true` past the pre-read checks,
  with an aggregate `{results[], stopped, skipped, failed}`. "Stop the team" = halt every haltable
  (moving/returning → held in open space), skip the rest, report the breakdown.
- **Dual gate:** outer `team_command_enabled` (dark) keeps a team-stop from ever driving the inner live stop,
  which has its own `mainship_send_enabled` gate. No second movement engine; writes no movement row directly;
  the client never supplies a fleet id (fleets are derived from owned members only). ACL `authenticated`-only.
- **Frontend:** `src/features/command/teamStop.ts` — pure `groupStopAvailability` mirror (pre-read order only),
  unit-tested in `tests/teamStop.spec.ts`. **No UI this slice.**

## Slice B (B-ui) — what shipped

Frontend-only (no migration) — wires the B-send/B-stop RPCs into the roster, completing Slice B's interactive
surface. Still behind `TEAM_COMMAND_ENABLED` (panel not mounted in prod):

- **`teamApi` wrappers** `sendShipGroup(groupId, locationId)` / `stopShipGroup(groupId)` — normalize-don't-throw
  over `send_ship_group_expedition` / `stop_ship_group_transit`.
- **`sendableDestinations(locations)`** pure helper (in `teamSend.ts`) — filters `game.locations` to
  `status='active' AND activity_type='none'`, mirroring the live send's server predicate; projects to
  `{id,name}`, sorted. Unit-tested in `tests/teamSend.spec.ts`.
- **`TeamRosterPanel`** gains a per-team **Send** (with a destination `<select>` from `sendableDestinations`)
  and **Stop** control, reusing the existing `run()` await→refetch→busy pattern (non-optimistic). Results are a
  short `Notice`: send → `Sent N ships to X`; stop → `Stopped a, skipped b, failed c`. Destination comes from
  the ONE shell `game.locations` (shared game state, not a second selection source); ship list/pointer still
  the ONE shell `selection`. The server re-validates the destination + owns atomicity — the client filter is
  convenience. Deferred (lit-time UX): a send confirm step, per-member `results[]` drill-down.

## Slice C0 — what shipped

Migration `supabase/migrations/20260618000165_slice_c0_captain_slots_and_group_preview.sql` — the first
captain sub-slice, fully DARK (no flag flipped, no activation) and **RPC-ONLY (zero data change)**:

- **Part A — DEFERRED ENTIRELY (RPC-only slice)**: C0 makes **NO data change** — grep the migration for any
  `insert`/`update` on `main_ship_hull_types` or `main_ship_instances` → there is none. **Both** captain-slot
  bumps are deferred to activation: (1) the HULL bump `main_ship_hull_types.base_captain_slots` 2 → 6, **and**
  (2) the existing-instance `main_ship_instances.captain_slots` backfill. **Why both (grep-verified,
  dark-discipline):** the Ship screen's "Captain seats" stat row (`ShipStatusCard.tsx`) renders **both**
  values **ungated** — `hull.base_captain_slots` in the no-ship starter teaser (`:95`) and the ship's
  `captain_slots` (`:213`). So the hull bump is **not** invisible either: a shipless player would see the
  teaser move 2 → 6, and every ship commissioned after the bump (`captain_slots` is copied from the hull at
  commission) would show 6. While captains are dark the slot count is **purely cosmetic** (no assignment can
  exist → no stat can change), so nothing needs the bump now. Deferring both keeps C0 changing **nothing a
  player can see** — it only adds a gated, unreachable-in-prod RPC.
- **Part B — `get_my_group_expedition_preview(p_group_id, p_activity_type default 'none')`** — DARK,
  read-only group stats preview. Reject vocab: `not_authenticated` → `team_command_disabled` (gate FIRST,
  before any read) → `invalid_activity` (exactly the 0122 set: `pirate_hunt`/`trade_run`/`exploration`/
  `mining`/`none`) → `group_not_found` → `empty_group` → `ok`. Per member it calls the **unmodified**
  `calculate_expedition_stats` (0122 — which already folds captain skills + the headcount cap) inside a
  per-member exception scope (a member's raise → `{main_ship_id, valid:false, error}`, never a team 500 —
  the 0159 preview idiom). **Zero stat arithmetic in SQL**: no accumulator, no sum — delegation + collection
  only. Group totals are a client display concern; **authoritative team stats are Slice D's**, defined beside
  the combat consumer. **Read-only, NO locks** (deliberate divergence from B-send/B-stop, which lock because
  they write): the MVCC snapshot is the consistency guarantee. ACL `authenticated`-only;
  `calculate_expedition_stats` stays service_role-only (this SECURITY DEFINER wrapper calls it as owner — the
  `get_my_expedition_preview` posture).
- **Frontend:** `src/features/command/teamSkillset.ts` — pure `groupPreviewAvailability` mirror (RPC reject
  order) + `aggregateTeamStats` (**display-only, not server truth**: sums the additive stat keys across valid
  members, `slowestSpeed = min` member speed since members travel individually, skips + counts invalid
  members, never NaN). Unit-tested in `tests/teamSkillset.spec.ts` (`npm run verify:team:unit`). **No UI this
  slice.**
- **Proof:** `scripts/team-command-proof.{sql,sh}` gained the `TEAMCMD_PASS_CAPTAINS` block — dark reject
  before the in-txn flag flip, every reject token, the captain seed-bonus delta over an uncaptained baseline
  with `captain_slots_limit=6`, uncaptained-member byte-parity with the solo preview, and unassign-reverts —
  with captains provisioned **only via the sole writers** (`captains_mint_instance` /
  `captain_assign_apply`; the selftest greps that no direct Captain-table insert exists).

## Slice C1 — what shipped

Frontend-only (**no migration, no flag flipped, no `game_config` write**) — the captain roster + expedition
preview wired into the team roster, fully DARK (everything below is rendered only from `TeamRosterPanel`,
which is not mounted while `TEAM_COMMAND_ENABLED = false`):

- **`src/features/command/teamCaptains.ts`** — pure (no I/O, types-only import from the captains feature):
  `captainsByShip` (split the ONE `get_my_captain_instances` roster on `main_ship_id`, null → unassigned,
  input order preserved; a captain pointing at a ship not in the roster stays bucketed under that id — the
  server's assignment is truth, never reclassified), `captainAssignAvailability` (**display-only** mirror of
  the assign reject order, 0120/0121 wrapper + 0119 writer: dark FIRST → `ship_not_settled` →
  `already_assigned` (writer step 4) → `captain_slots_full` (writer step 5) → ok; the free-slot input comes
  from the **server-reported** `captain_slots`, never a hardcoded 2/6), and `PREVIEW_ACTIVITY_TYPES`/`isPreviewActivity` (**exactly** the 0165/0122 set:
  `pirate_hunt`/`trade_run`/`exploration`/`mining`/`none`, defined ONCE). Unit-tested in
  `tests/teamCaptains.spec.ts` (`npm run verify:team:unit`).
- **`teamApi.fetchGroupExpeditionPreview(groupId, activityType)`** — the ONE read wrapper over C0's
  `get_my_group_expedition_preview` (normalize-don't-throw, the file's dark-RPC style; transport error →
  `{ok:false, reason:'unavailable'}`). The captain commands are **not** wrapped here — `captainsApi.ts`
  stays the one captain API/envelope/error map. `fetchMyShipGroupMap` widened its owner-RLS SELECT with the
  existing `captain_slots` column (zero server change) to feed the availability mirror a real slot count.
  `PreviewMember` (teamSkillset.ts) gained the optional per-member `error` migration 0165 emits.
- **`TeamMemberCaptains`** — per-member captain sub-surface in every ship row (grouped AND ungrouped):
  assigned captains + Unassign, and an Assign picker over the unassigned pool. Submits ONLY the existing
  CAPTAIN-P15 commands (`assign_captain_to_ship` is already ship-addressed — **no new server code**) via the
  existing guarded idiom (`runGuardedCommand` + `useActivityPanelGuards`, `request_id = crypto.randomUUID()`);
  error copy through the ONE mapper `captainCommandErrorMessage` (incl. `ship_not_settled`). Rendered ONLY
  while `isServerLit(get_my_captain_instances)` — while `captain_assignment_enabled` is false the server's
  `captain_assignment_disabled` envelope keeps the roster **byte-identical to today**. After any captain
  mutation the panel refetches the captain roster (await-then-refetch, no optimistic UI).
- **`TeamPreviewSection`** — per-team activity `<select>` (exactly the five 0165 activities) + Preview
  button gated by C0's `groupPreviewAvailability`; on success renders C0's `aggregateTeamStats`
  (**estimate, display-only** — authoritative team stats are Slice D's): additive totals, `slowestSpeed`,
  valid/invalid counts, and per-member lines (`valid:false` → the server's per-member `error`). A cached
  preview is stamped with the roster version it was computed at and disappears on any panel reload
  (membership change ⇒ stale).
- **RecruitCaptainPanel stays on ShipScreen** (untouched); the 6 → 8 slot raise and progression wiring stay
  C2; the captain-slot 2 → 6 activation bump stays deferred (see "Explicitly deferred").

## Slice D0 — what shipped

Migration `supabase/migrations/20260618000166_slice_d0_group_stats_authority.sql` — the authoritative
server-side team stats 0165/C1 explicitly deferred to Slice D. Fully DARK, **RPC-only, zero data change,
no frontend** (a migration+proof slice):

- **`calculate_group_expedition_stats(p_player, p_group_id, p_activity_type)`** — the internal,
  **service_role-only** authority (the exact 0122 ACL posture). Per member ship of the owned group
  (membership via `main_ship_instances.group_id`, resolution via `mainship_resolve_owned_group` — explicit-only,
  fail closed) it delegates to the **unmodified** `calculate_expedition_stats` (0122 — support craft + modules +
  captains behind their hard caps) and performs **team-level folding only**: the eight additive 0122 stat keys
  (`combat_power`, `survival`, `repair`, `retreat_safety`, `scouting`, `mining_yield`, `cargo_capacity`,
  `pirate_attention`) summed; `speed = min` member speed (members travel individually — the client
  `slowestSpeed` semantics). Zero re-implemented per-ship stat arithmetic. **STRICT** (0122's
  refuse-don't-clamp law, deliberately diverging from 0165's per-member `{valid:false}` preview idiom): any
  member's raise (over-capacity etc.) raises the WHOLE function — an illegal member state means the team has
  NO defined stats. Nonexistent/empty inputs raise clear exceptions (`group_not_found` / `empty_group`), the
  0122 internal posture. Returns `{group_id, activity_type, member_count, members:[{main_ship_id, stats}],
  totals:{speed, …the eight additive keys}}`.
- **`get_my_group_expedition_totals(p_group_id, p_activity_type default 'none')`** — the thin, DARK, gated
  client wrapper over the same truth. Reject vocab (gate FIRST, before any read — the 0165 structure):
  `not_authenticated` → `team_command_disabled` → `invalid_activity` (exactly the 0122/0165 set) →
  `group_not_found` → `empty_group` → `stats_invalid` (ANY authority raise, folded into ONE opaque envelope —
  no member detail leaks; the C0 preview is the friendly diagnosing surface) → `ok`. Read-only, **no locks**
  (the 0165 MVCC posture). ACL `authenticated`-only (new-function-only grant idiom); the internal authority has
  no client grant.
- **Proof:** `scripts/team-command-proof.{sql,sh}` gained the `TEAMCMD_PASS_TEAMSTATS` block — dark reject
  before the in-txn flag flip; every reject token; and the **delegation pin**: every additive total must EQUAL
  the proof's own independent per-member sum over *direct* `calculate_expedition_stats` calls (plus
  `totals.speed = min`, and per-member `stats` byte-parity with the direct adapter call), so the totals RPC can
  only be folding the ONE adapter's outputs; and the strict-vs-preview split — one over-capacity member →
  totals answers opaque `stats_invalid` while the C0 preview still answers `ok` with that member
  `valid:false`. The selftest greps enforce the delegation-pin forms.

## Slice D1 — what shipped

Migration `supabase/migrations/20260618000167_slice_d1_combat_member_units.sql` — the riskiest
team-command phase: it re-creates the **LIVE** combat cron body and the **LIVE** report writer. Fully
DARK, **no member-row writer, no flag flip, no frontend, no backfill**:

- **The parity discipline (the absolute law of this slice):** both bodies were copied VERBATIM from
  their true heads (verified by grepping every migration for each function name and taking the
  latest — `process_combat_ticks` ← 0046, `report_create` ← 0026; nothing later re-creates either).
  Every delta is one of exactly two provably-inert shapes:
  - a `coalesce(member_value, legacy_value)` where the member value is NULL on every existing row
    (snapshot-first stat reads over a `left join`; `coalesce(unit_type_id, main_ship_id::text)` jsonb
    keys; `coalesce(fleet_speed(…), combat_fleet_return_speed(…))` return speed), or
  - a branch reachable ONLY when a `combat_units` row has `main_ship_id IS NOT NULL` — and **no such
    row can exist**: the new columns have NO writer until D2's flag-gated RPC.
  Each delta carries a `-- SLICE D1:` marker; nothing else in either body changed (same variables,
  same order). Verified by extracting the shipped bodies and diffing against the head originals.
- **`combat_units` widening:** `main_ship_id uuid NULL → main_ship_instances` (ON DELETE CASCADE),
  `attack_snapshot`/`defense_snapshot double precision NULL` (matching `unit_types.attack/defense`),
  `unit_type_id` relaxed to NULL, and the exactly-one-identity CHECK
  `((unit_type_id is null) <> (main_ship_id is null))` — every existing row carries `unit_type_id`,
  so the CHECK is trivially satisfied with no backfill. Two hardening invariants complete the schema
  half of the parity law: a snapshot-pairing CHECK (snapshots exist IFF member row — a stray catalog
  snapshot would silently override live stats through the coalesce-first read; a NULL member snapshot
  would contribute silent-zero) and a partial unique index (one member row per encounter+ship — the
  legacy `unique (encounter_id, unit_type_id)` cannot cover member rows because NULLs never collide).
- **Three new leaves** (internal cron/engine only — SECURITY DEFINER, `search_path=public`, revoked
  from public/anon/authenticated, service_role only; the 0153 one-leaf idiom):
  - `combat_fleet_return_speed(p_fleet)` — min member HULL `base_speed` over the fleet's active
    encounter's member rows (the exact hull-speed source `request_main_ship_return` uses, 0050);
    NULL for legacy fleets → the tick's coalesce is a no-op.
  - `mainship_sync_combat_hp(p_main_ship_id, p_hp integer)` — writes `main_ship_instances.hp` ONLY;
    the member mirror of `fleet_sync_quantities` (which now provably receives ONLY catalog-keyed
    counts — the member `else` branch is unreachable today).
  - `mainship_mark_combat_destroyed(p_main_ship_id)` — the combat-side ship terminal after
    `fleet_destroy`: the EXACT 0059 terminal shape (`status='destroyed'`, `hp=0`,
    `spatial_state=NULL` + coords NULL — spatial_state can NOT be left untouched under the 0055
    lifecycle CHECKs). This is now the SECOND trusted destruction writer (0059's uniqueness claim is
    superseded; both write the same terminal).
- **What stays unreachable until D2:** every member branch — the snapshot stat reads, the uuid jsonb
  keys, the hp sync, the member destruction loop, and the hull-speed return fallback. D2's flag-gated
  RPC is the FIRST writer of member `combat_units` rows.
- **Proof:** `scripts/team-command-proof.{sql,sh}` gained the `TEAMCMD_PASS_COMBATPARITY` block
  (positioned after the team blocks, with `team_command_enabled` still ON in-txn — the flag's
  irrelevance to a legacy fleet's combat is itself asserted): a real legacy unit fleet is sent and
  settled through the real chain (`send_fleet_to_location` → `movement_settle_arrival` →
  `combat_create_encounter`), one `process_combat_ticks()` tick's `player_damage` must EQUAL the
  proof's OWN independent `Σ(unit_types.attack × alive_count)` AND its `enemy_damage` must EQUAL the
  proof's own defense-curve value from the independent `Σ(defense × alive)` (variance pinned to 0
  in-txn via the real `set_game_config` — both compares exact, mirroring the tick's operation order),
  every tick/report jsonb key must be a legacy unit_type id, hp accounting and `fleet_units` sync are
  exact, the retreat→escape settle produces a legacy-keyed report with `speed_used = fleet_speed`,
  both illegal identity inserts raise the CHECK, the three leaves smoke-check (NULL return speed for
  a legacy fleet; hp-only sync; the 0059 destruction terminal — on a rolled-back fixture ship), and
  **exactly one** combat cron job exists (`process-combat-ticks` — the no-second-engine pin). The
  selftest greps pin the independent-sum asserts (attack + enemy damage) and the cron-count assert in
  assert form.

## Slice D2 — what shipped

Migration `supabase/migrations/20260618000168_slice_d2_group_hunt_send.sql` — the team enters the
combat engine. Fully DARK (**no flag flipped, no frontend, no backfill, no edit to any shipped
migration**); the FIRST writer of the member `combat_units` rows D1 prepared:

- **The narrow bridge (why not B-send's wrapper idiom):** the live single send hard-rejects combat
  destinations (0050:104/0152:116), and looping it would make N fleets → N encounters — the wrong
  shape for ONE team encounter. So `send_ship_group_hunt(p_group_id, p_location)` composes the spine
  primitives directly, exactly like the 0050 main-ship bridge: ONE direct `fleets` insert (no
  `fleet_units`; the 0050:133-135 shape + the informational `group_id` tag; `main_ship_id` stays
  NULL — one fleet, many ships), `movement_create(…, 'hunt_pirates', speed)`, `fleet_set_moving`,
  members → `status='hunting'` (in the 0043/0055 status domain since day one; ignored by the 0050
  reconciler, which touches only `'traveling'`/`'returning'` — no reconciler race), and the frozen
  manifest rows. Send stats are the **per-member adapter fold over the LOCKED member set** (power =
  Σ `combat_power`, speed = min member speed — D0's exact folding law, and exactly what the
  encounter creator does), deliberately NOT the group-shaped D0 RPC: that re-resolves LIVE
  membership, and a concurrent assign could slip a ship in between the gather and its read — gating
  power over a superset of the manifest about to be frozen (manifest-wins even at send time).
  Reject vocab (gate FIRST): `not_authenticated` → `team_command_disabled` → `group_not_found` →
  `empty_group` → `invalid_location` (must be `status='active'` AND `activity_type='hunt_pirates'`)
  → `member_not_ready` (EVERY member `status='home'` **AND `hp > 0`** — a zero-hp 'home' ship is
  schema-legal since the D1 hp sync can write 0 — checked UNDER the ship locks; also returned when
  the gather→lock window lost a member row, instead of a raw FK 500) → `fleet_limit_reached` (the
  shared `max_active_fleets` budget; the team is ONE fleet) → `power_below_required` (Σ member
  `combat_power` vs `locations.min_power_required`, the 0019:60-63 semantics) → `ok`; plus two
  fail-closed folds: `stats_invalid` (any adapter raise, the 0166 posture) and `no_home_base`.
  Locks: group `FOR SHARE` + revalidate → member ships `FOR UPDATE` (the 0163 order); **NO
  movement-row lock anywhere** (the 0164 lock-order lesson — the settle cron takes movement→ship,
  so this RPC must never take ship→movement). **Honest race scope (M1, see the pre-activation
  checklist):** the under-lock readiness check closes LOCKING racers only (team-send vs team-send /
  assign / delete); the live single send's plain read + unconditional ship UPDATE
  (0050:87-94,146-147) can still overwrite a just-committed `'hunting'` with `'traveling'` in a true
  concurrent interleaving. No `p_request_id` — B-send (0163) has none; the under-lock re-check is
  the dedup.
- **The manifest-wins law:** `group_sortie_members (fleet_id, main_ship_id, player_id)` — the team's
  `fleet_units` analogue, the membership SNAPSHOT from send until return. A mid-flight
  unassign/`delete_ship_group` must NOT orphan the sortie: **routing keys on the manifest, never on
  live group membership and never on `fleets.group_id`** (which is display-only — its comment says
  ROUTING NEVER reads it; `ON DELETE SET NULL` merely unlabels a fleet whose team was deleted).
  Sole writer: `send_ship_group_hunt` (grep-enforced in the proof selftest, the captains sole-writer
  convention). Owner-select RLS (0160 style); rows die with their fleet (CASCADE). One-live-sortie-
  per-ship is enforced behaviorally (a partial unique index cannot express it — "live" is
  `fleets.status`, another table): joining a sortie flips the ship to `'hunting'` in the same
  transaction, and only the D3 return path will set it home again.
- **Encounter routing:** `combat_create_encounter` re-created from its TRUE head (0023:69 —
  grep-verified 0017→0022→0023, nothing later) with ONE marked branch after the presence read: a
  fleet with manifest rows returns `combat_create_group_encounter(p_presence)`; everything else is
  byte-identical (diff-verified — the D1 parity discipline). Unreachable in prod: no manifest row
  can exist while `team_command_enabled` is false.
- **`combat_create_group_encounter`** (internal; service_role/no-client-grant, the D1-leaf posture) —
  SNAPSHOT INPUTS ONLY, zero wave/damage math (the second-engine tripwire). **Manifest-wins design
  choice:** the D0 authority is group-shaped (reads LIVE membership), which can have diverged by
  arrival — so the creator calls the ONE per-ship adapter (`calculate_expedition_stats`, 0122 — the
  same adapter D0 delegates to) directly **per MANIFEST member**: divergence is impossible because
  live membership is never read; when membership is unchanged, `player_power_start` equals D0's
  `totals.combat_power` by construction. Per member it writes one `combat_units` row satisfying all
  three D1 invariants: `main_ship_id` (identity), `attack_snapshot := combat_power`,
  `defense_snapshot := survival`, `alive_count := 1`, and `ship_hp`/`hp_max`/`hp_current` := the
  ship's **REAL CURRENT** `main_ship_instances.hp` — pre-existing damage carries into the encounter.
  Encounter integrity := Σ member hp (the head's `sum(hp_max)` statement pair). **RAISE-FREE BY
  CONSTRUCTION (cron safety):** the creator runs inside `movement_settle_arrival`'s txn and the
  movement cron has **no per-movement subtransaction** — a raise would roll back every other
  player's arrival in that run and leave the poisoned movement re-selected forever. So a member with
  `hp <= 0` or an adapter refuse-don't-clamp raise (over-capacity after a mid-flight fitting/captain
  change) **DEGRADES instead of raising**: its row is still inserted (skipping would orphan the
  ship's `'hunting'` state) as dead-on-arrival — `alive_count 0`, zero snapshots (non-null, so the
  D1 pairing CHECK holds), zero hp — inert in every tick read; an all-degraded roster yields a
  zero-hp encounter the tick's existing defeat pass settles cleanly (fleet_destroy + the D1 member
  loop marking the ships combat-destroyed). No outer exception wrapper on the routing branch —
  deliberate: with every reachable raise degraded it would be dead code, and falling through to the
  legacy zero-unit path would insta-defeat with NO member rows for the D1 defeat loop to settle
  (orphaned `'hunting'` ships — incoherent).
- **What's still unreachable / deferred:** no client UI until **D4** (`send_ship_group_hunt` has no
  caller in `src/`); the sortie **return/settle** is **D3** — after defeat/escape the tick already
  destroys/returns the FLEET (D1's member branches: hp sync, hull-speed return, destruction
  terminal), but surviving ships stay `status='hunting'` until D3's reconciler brings them home.
- **Proof:** `scripts/team-command-proof.{sql,sh}` gained the `TEAMCMD_PASS_TEAMHUNT` block (after
  COMBATPARITY, flag ON in-txn; the dark reject is asserted in BLOCK DARK before the flip): reject
  vocabulary + ORDER (`invalid_location` answers before member readiness), ONE fleet + 2-row
  manifest + `'hunting'` ships, `speed_used` == the proof's OWN independent D0 `totals.speed`,
  live-single-send + double-team-send races reject mid-sortie, member encounter pins
  (`attack_snapshot` == the proof's own direct per-member adapter call, hp carries a pre-send dent,
  `player_power_start` == `totals.combat_power`), one tick's `player_damage` == Σ member
  `attack_snapshot` (variance re-pinned 0) with the D1 leaf syncing damage to
  `main_ship_instances.hp` (the member path's first live execution), the **manifest-wins pin**:
  a real mid-flight unassign leaves the manifest at 2 rows and the next tick still drives BOTH
  members, and the **H1 cron-safety pins**: a zero-hp member rejects `member_not_ready` at send,
  and a sortie whose member's adapter RAISES at arrival (mid-flight `captain_slots→0` surgery)
  still **settles successfully** — the member row lands degraded (`alive_count=0`, zero snapshots,
  zero hp, zero `player_power_start` contribution) and the all-degraded encounter defeats cleanly
  (fleet destroyed, ship combat-destroyed by the D1 member loop). Selftest greps bind the key
  asserts in assert form + the manifest sole-writer negative grep.

## Slice D3 — what shipped

Migration `supabase/migrations/20260618000169_slice_d3_group_settle.sql` — the sortie settle
semantics D2 deferred. Fully DARK (**no flag flipped, no frontend, no backfill, no edit to any
shipped migration, no cron change**); three re-creates from grep-verified TRUE heads, each
diff-verified to exactly its marked hunks:

- **`process_combat_ticks` (head 0167 — the D1 re-create):** ONE hunk in the end branch (the single
  site that creates the `'return_home'` movement, covering both `'escaped'` and forced
  `'completed'`): surviving members (`alive_count > 0`) are marked `'returning'` through the ONE
  0152 leaf `mainship_mark_legacy_in_flight` (`'returning'` is inside its hard domain; the leaf
  gains a fifth caller, never a widening). `alive_count` — not `hp_current` — is the survival
  predicate: a tick-killed member (alive floored to 0) or a D2-degraded member (born 0) is NOT
  flying anything; it stays `'hunting'` hp=0 until the reconciler re-homes it at fleet completion —
  exactly the "zero-hp `'home'` ship" D2's send guard anticipates. The DEFEAT branches were
  verified to already settle members via D1's `mainship_mark_combat_destroyed` — untouched.
- **`process_mainship_expeditions` (head 0050 — its only create site):** two member-only deltas.
  (1) The legacy branch gains a guard — skip a ship whose MANIFEST fleet is still live — because a
  team member marked `'returning'` has no `main_ship_id`-tagged fleet, so the head's not-exists is
  vacuously true and would yank it home MID-FLIGHT (freeing it to join a second sortie, breaking
  D2's one-live-sortie law). Once the manifest fleet finishes, the guard opens and the unchanged
  legacy write re-homes the member (`status='home'`, spatial_state stays NULL — the clean
  legacy_home every legacy expedition ship has always reconciled to). (2) A new team CTE re-homes
  `'hunting'` ships whose manifest fleet is finished — `'hunting'` has exactly ONE writer (D2's
  send), so it can never touch a legacy ship; it also SELF-HEALS partial states (fleet destroyed
  but the D1 loop missed the ship, or the fleet row deleted entirely) — the reconciler NEVER
  destroys a ship. **Race pin:** both predicates test the manifest fleet against exactly
  `('moving','present','returning')` — outbound, mid-combat, in transit home — the exact
  complement of "finished or gone".
- **Manifest retention decision:** `group_sortie_members` rows for a finished sortie are RETAINED,
  not deleted — fleets are not immortal (the 0047 retention cron deletes terminal fleets >14d and
  the manifest CASCADEs with them), deleting would add a second manifest writer (the sole-writer
  law is grep-enforced), and a completed fleet is never reused (no completed→moving edge), so a
  retained manifest can never re-route an encounter. Consequence: every D3 manifest predicate is
  LIVE-scoped (join `fleets.status`), never a bare EXISTS.
- **M1 fix (`send_main_ship_expedition`, head 0152):** the ship write re-claims the row **under a
  `FOR UPDATE` lock re-verifying `status='home'`** immediately before the 0152 leaf call, rejecting
  a miss with the function's own pre-existing not-available raise. The shared leaf is NOT widened —
  the conditional lives in the caller. RACE-CLOSURE-ONLY: every non-racing caller locks instantly
  and performs the byte-identical write/rejects on the byte-identical paths; only a true concurrent
  interleaving (previously a silent `'hunting'` → `'traveling'` lost update) now rejects. No
  lock-order cycle: the single send holds no other existing-row lock, B-send's wrapper already
  holds the same ship lock (re-lock is a no-op), and no movement row is ever locked here.
- **Retreat:** verified verbatim — `request_retreat` (head 0019) is presence-addressed +
  owner-checked and reads nothing team-shaped; exercised live on a team encounter in the proof.
  NO change.
- **Proof:** `scripts/team-command-proof.{sql,sh}` gained the `TEAMCMD_PASS_TEAMSETTLE` block
  (after TEAMHUNT, inside the ONE rolled-back txn): both reconciler race guards (mid-combat +
  in-transit), the escape marking survivors `'returning'` with the member hull return speed
  (`fleet_speed` NULL → the D1 coalesce fallback), a member-keyed report, damage persisted, the
  return settle depositing the carried bundle (reward_grants + base metal delta), the reconciler
  re-home in the legacy shape with the manifest retained, a REAL alive-member defeat
  (boosted-enemy surgery) with the D1 destruction loop + `repair_main_ship` revival, the M1 pin
  (a `'hunting'` ship rejects the live single send with its own error and is NOT moved; a legal
  single send still works), and both self-heal re-homes. The selftest greps bind every pin in
  assert form.

**What remains:** D4 (client mirrors + dark Hunt UI), then the activation checklist (flag flips +
the deferred captain-slot bump — human-gated, never part of a slice).

## Dark state / gate decisions

Everything above is **dark**. Nothing changed for players.

| Gate | State | Meaning |
|---|---|---|
| `team_command_enabled` (game_config) | **false** | Server mirror; future team RPCs will reject-before-read on it. |
| `TEAM_COMMAND_ENABLED` (compile-time) | **false** | Roster panel is not mounted → never renders, never fetches. |
| `mainship_additional_commission_enabled` | **false (untouched)** | **Decision:** left OFF. Raising the cap is the foundation; actual 2nd+ ship creation stays gated so there is **no uncontrolled ship creation**. Lighting multi-ship commissioning is a later, separately-approved step. |

The cap raise (24) is **inert** while `mainship_additional_commission_enabled` is false:
`commission_additional_main_ship()` rejects at the gate before it ever reads the cap. The raise only pre-sizes
the cap so it is not the binding limit once multi-ship is later lit.

## Explicitly deferred

- **Group creation / assignment RPC** → **DONE in Slice B0** (`upsert_ship_group` / `assign_ship_to_group` +
  `mainship_resolve_owned_group`; same-player gap closed via dual same-`auth.uid()` resolution; dark behind
  `team_command_enabled`; no client UI yet).
- **Group DELETE RPC + interactive team UI** → **DONE in Slice B1** (`delete_ship_group` + `teamApi` write
  wrappers + create/rename/delete/assign controls in `TeamRosterPanel`, still dark).
- **CI `.mjs` verifier** for the write path → lands with Slice B's verify step. Must flip `team_command_enabled`
  true in an ephemeral/rolled-back txn and exercise upsert/assign/unassign/**delete** + every reject, assert
  player A cannot assign A's ship to B's group **nor delete B's group**, and cover the **double-delete** and
  **assign-vs-delete** races.
- **Captain-slot capacity bump 2 → 6 (BOTH the hull bump AND the existing-instance backfill)** → **DEFERRED
  to activation** (kept ENTIRELY out of C0 to preserve zero player-visible change — the "Captain seats" row
  in `ShipStatusCard.tsx` renders `hull.base_captain_slots` in the no-ship teaser (`:95`) **and** the ship's
  `captain_slots` (`:213`), both ungated, so either bump would move a player-visible label while dark). C0 is
  RPC-only. When captains are lit, run **both together** alongside the flag flips (idempotent, monotonic):
  ```sql
  update public.main_ship_hull_types
     set base_captain_slots = 6 where hull_type_id = 'starter_frigate' and base_captain_slots < 6;
  update public.main_ship_instances i
     set captain_slots = h.base_captain_slots, updated_at = now()
    from public.main_ship_hull_types h
   where i.hull_type_id = h.hull_type_id and i.captain_slots < h.base_captain_slots;
  ```
  Any later 6 → 8 raise is a separate additive C2 migration, decided at lit-time balance.
- **Authoritative server-side team stats** → **DONE in Slice D0** (`calculate_group_expedition_stats` +
  `get_my_group_expedition_totals`, migration 0166 — strict, delegation-only, dark).
  `get_my_group_expedition_preview` still deliberately does zero arithmetic, and `aggregateTeamStats` is
  still display-only — neither is a source of team-stat truth; D0's authority is.
- **Captain UI in the roster** (assign/unassign per member ship, captain list) → **DONE in Slice C1**
  (dark, frontend-only; reuses the CAPTAIN-P15 commands verbatim — no new server authority). Captain
  progression wiring / lit-time polish (and any 6 → 8 slot raise) → Slice C2.
- **M1 — ACTIVATION BLOCKER → DONE in Slice D3 (migration 0169):** the live single send's ship
  write was a plain read + **unconditional** UPDATE (`send_main_ship_expedition`, 0050:87-94 +
  146-147 / 0152:100-107 + 150) — no ship lock, so a single send that read `status='home'`
  concurrently with a committing team hunt-send could overwrite `'hunting'` → `'traveling'` (a lost
  update desyncing the ship from its live sortie). **Fix shipped:** the re-created send (head 0152)
  re-claims the ship row under a `FOR UPDATE` lock re-verifying `status='home'` immediately before
  the 0152 leaf call and rejects a miss with the send's own not-available raise — the shared leaf
  is NOT widened (conditional in the caller). Race-closure-only: every non-racing caller is
  byte-identical; `team_command_enabled` no longer has this blocker.
- **Every flag flip (`team_command_enabled`, `captain_assignment_enabled`, …) = human activation**, never
  part of a slice. All C0 behavior stays dark behind `team_command_enabled=false` (and the captain fold
  behind `captain_assignment_enabled=false`).
- **Folding `ModulesPanel.shipPick` into the shell selection** → deferred. It changes module-fitting behavior
  (per-instance pick → global selection) inside the dark trade/modules feature and is not adjacent to the team
  model; folding it here would be scope creep into a behavior change.
- **N-ship generalization of `send_main_ship_expedition`** → explicitly NOT done. B-send wraps the unmodified
  live send instead, so the live single-ship path is byte-for-byte unchanged.
- **`max_active_fleets` raise** → deferred. It is LIVE and shared with old fleets, so a team of >3 members
  currently rolls back on the 4th; raising it would alter live behavior and belongs with lighting team-send.
- **A0-fix for the raw OSN coordinate move** — `command_main_ship_space_move` (0070) still derives the ship
  with an unguarded `where player_id = …` (arbitrary at N>1), but it rejects on `mainship_space_movement_enabled`
  + `mainship_coordinate_travel_enabled` (both false) *before* that read → unreachable. NOTE:
  `command_main_ship_space_stop` was ALREADY resolver-guarded in migration 0083 — it is NOT unguarded. Neither
  is on B-stop's path (the legacy stop is fleet-addressed), so the A0-fix is **not** a B-stop prereq; retire it
  when coordinate-travel AND multi-ship commissioning are both lit.
- **B-send/B-stop CI `.mjs` verifier** → with B-verify: flip `team_command_enabled`, exercise group-send +
  every reject, assert all-or-nothing send rollback + the double-send/send-vs-delete races; AND group-stop —
  every pre-read reject, the **best-effort aggregate** on a mixed-state group (some moving, some docked), and
  the stop-vs-cron / stop-vs-delete / stop-vs-send / double-stop races; plus cross-player rejection for both.
- **Send/stop-by-team UI, captains, team combat** → later B sub-slices / Slices C/D.
