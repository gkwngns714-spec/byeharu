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
- **Slice B0 — DARK group create/assign write path (the writer A omitted). ← this slice (migration 0161).**
- Slice B — send/stop **by team** (generalize `send_main_ship_expedition` to N ships over the fleets spine;
  plus the group **delete** RPC and the interactive team UI). *Not started.*
- Slice C — captains (wire the dark CAPTAIN-P15/P16 system; captain skills → team skillset via
  `calculate_expedition_stats`; bump `main_ship_hull_types.base_captain_slots` 2 → 6–8). *Not started.*
- Slice D — team combat (largest; main-ship combat was never built — resolve a team into the existing combat
  engine per the law). *Not started.*

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
- **Group DELETE RPC + interactive team UI (`teamApi` wrappers, assign/rename controls)** → Slice B. The delete
  RPC must lock the group row `FOR UPDATE` and rely on `ON DELETE SET NULL` to un-group members.
- **CI `.mjs` verifier** for the write path → lands with Slice B's verify step (must flip
  `team_command_enabled` true in an ephemeral/rolled-back txn, exercise upsert/assign/unassign + every reject,
  and assert player A cannot assign A's ship to B's group).
- **`base_captain_slots` 2 → 6–8** → Slice C (needed only when captains are wired; not needed by the group
  model).
- **Folding `ModulesPanel.shipPick` into the shell selection** → deferred. It changes module-fitting behavior
  (per-instance pick → global selection) inside the dark trade/modules feature and is not adjacent to the team
  model; folding it here would be scope creep into a behavior change.
- **Send/stop by team, captains, team combat** → Slices B/C/D.
