# Session Handoff — 2026-07-09

Snapshot of where development stands, so work can continue on another computer. This file is committed
to the repo (it travels via GitHub); the per-machine plan/memory files do NOT travel.

## 1. Moving to a new computer — checklist
1. `git clone https://github.com/gkwngns714-spec/byeharu.git && cd byeharu`
2. `npm install` (native binaries must be installed fresh — do NOT copy `node_modules`).
3. **Bring `.env.local`** — it is gitignored, so it is NOT in GitHub. Copy the file from the old machine
   (or recreate it from the Supabase dashboard). It contains: `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`,
   `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD`, `SUPABASE_PROJECT_ID`
   (project ref `dlkbwztrdvnnjlvaydut`). Without it, the app + verify/activation scripts can't reach the DB.
4. Tooling: **Node.js LTS** (`winget install -e --id OpenJS.NodeJS.LTS`), **Supabase CLI** (standalone
   binary from GitHub releases, add to PATH), **GitHub CLI** (`winget install -e --id GitHub.cli` then
   `gh auth login` → github.com / HTTPS / browser). `psql` is NOT required (the OSN runbook is CI-only;
   direct SQL is done via the Supabase REST API + service-role key in the `.mjs` scripts).
5. Run: `npm run dev` → `http://localhost:5173/byeharu/` (base path `/byeharu/` is required). Live site:
   `https://gkwngns714-spec.github.io/byeharu/` (auto-deploys from `main` via Pages).

## 2. Current live state of the game (port-centric — activated 2026-07-08)
The game is now **port-centric**, not home-base-centric. On the LIVE prod DB (`game_config`):
- `mainship_space_movement_enabled = true` — OSN port-to-port travel + docking is ON.
- 3 starter ports REVEALED (active on the map): **Haven** (`b1a00001-…`), **Slagworks** (`…02`),
  **Driftmarch** (`…03`). Reveal is one-way.
- `station_storage_enabled = true` — per-port, per-player storage (the docked-port "Hangar").
- Migration head `20260618000158`. `mainship_send_enabled = true` (legacy send loop). Coordinate free-travel
  (`mainship_coordinate_travel_enabled`), trade, captains, multi-ship commission, ranking, world-balance =
  still DARK.
- Rollback (flags only; port reveal persists): flip `station_storage_enabled` / `mainship_space_movement_enabled`
  false via the `set_game_config` RPC (pattern: `scripts/dev-mainship-flag.mjs`).
- Activation utility (reusable): `scripts/activate-port-centric.mjs --confirm`.

## 3. Open / in-flight work
- **PR #75 `fix-remove-recall`** — OPEN, NOT merged. Contains: recall/return-home removed (no home base to
  return to), the (0,0) "home" ship marker suppressed, full spaghetti cleanup + all unit-test fixes, and the
  **stop-zoom camera fix** (single focus point → gentle neighbourhood zoom, not MAX_K). Verified: `tsc -b`
  clean, `vite build` green, 214 pure-logic specs pass. Merge with an admin merge (branch protection needs a
  review): `gh pr merge 75 --merge --admin --delete-branch -R gkwngns714-spec/byeharu`.
- Everything else this session is merged to `main` (bigger map markers, wheel-zoom fix, station storage
  migrations 0157/0158, port-centric UI removal of home base).

## 4. NEXT WORK — Team-command system (roadmap approved)
Vision: the player commands **3 teams × 6–8 ships** (~18–24 ships), each ship with **6–8 captains**; a team's
skillset = ship attributes + captain skills. This is the game's **own designed trajectory** (`docs/MAINSHIP_TRANSITION.md`,
`docs/ROADMAP.md` — "multiple persistent main ships in expedition **groups**"), backend ~90% scaffolded.

**Anti-spaghetti law (from the docs — non-negotiable):** (1) a group resolves into the EXISTING
`fleet_units`/`combat_units` combat input — never a second combat system; (2) reuse the `fleets`/movement
spine; (3) RPCs stay `main_ship_id`/group-shaped (`send_main_ship_expedition(p_ships jsonb,…)` already is);
(4) "group" in code, "team" in UI.

### Slice A0 — FOUNDATION FIXUP (do FIRST, from the pre-team audit)
The dark multi-ship/captain scaffolding is sound but incomplete. Fix these before the team UI (all masked
today only because multi-ship is dark):
- **[blocker] `get_my_docked_store` (migration 0158) reads an ARBITRARY ship at N>1** — it uses
  `select … where player_id=…` with no guard. Convert to a trailing `p_main_ship_id uuid default null` +
  `mainship_resolve_owned_ship` (the 0082 pattern used by the twin `get_my_current_dock_services`). *This is a
  real latent bug in our own station-storage RPC.*
- **[blocker] `get_my_expedition_preview` (migration 0049)** — same unguarded read; convert the same way.
- **[blocker] 3 client `.maybeSingle()` ship reads throw/ghost at N≥2**: `fetchMyMainShip` (`mainshipApi.ts`),
  `useGalaxyMapData.fetchMainShip`, `portEntryApi.fetchPortEntryShipState`. Make them plural + selection-aware.
- **[blocker] Selection is 3 disagreeing instances** (`ShipScreen`, `PortScreen`, `ModulesPanel` each mount
  their own `useMainShipSelection`). Lift it into `shellState.ts` = ONE source of truth (the code has a TODO
  saying exactly this).
- **[blocker] No authoritative "list my ships" surface** — enumeration is only the frontend `fetchMyMainShips`
  table read; the team roster needs an authoritative list.
- Cleanups: bump `main_ship_hull_types.base_captain_slots` 2 → 6–8 (data only); decide/ wire or drop the dead
  `MAINSHIP_ADDITIONAL_ENABLED` gate; fold `ModulesPanel.shipPick` onto the shell selection; fix the
  recruit-panel flag drift; drop/convert the dead `get_main_ship` (0043).

### Then the team slices
- **Slice A** — team model + enable multi-ship: `ship_groups (id, player_id, group_index 1–3, name)` +
  `main_ship_instances.group_id`; raise `max_main_ships_per_player` (3 → target); flip
  `mainship_additional_commission_enabled`; `CommandScreen.tsx` becomes the roster.
- **Slice B** — send/stop BY TEAM (generalize `send_main_ship_expedition` to N ships; group movement over the
  fleets spine; `MainShipCommand.tsx` team-aware). This is where "pick which ship" is answered — as team
  selection, not a throwaway per-ship picker.
- **Slice C** — captains: wire the (dark, clean) CAPTAIN-P15/P16 system; captain skills → ship/team skillset
  via the existing `calculate_expedition_stats` aggregator (already the right building block).
- **Slice D** — team combat (largest; prerequisite): main-ship combat was NEVER built (main-ship fleet carries
  zero combat units). Per the law, resolve a team into the existing `fleet_units`/`combat_units` input and run
  the existing combat engine (`…0023`). NOTE: today `calculate_expedition_stats` feeds only a read-only
  *preview* (`…0049`), not live combat — same for modules/support craft; a live consumer is net-new here.

### Clean foundations to REUSE (don't fork)
Captain sole-writer law (`captains_mint_instance`, `captain_assign_apply`); the ONE shared stat vocabulary
(`calculate_expedition_stats`); reject-never-clamp caps; reject-before-any-read dark gating; the 7 converted
`p_main_ship_id` RPCs + `mainship_resolve_owned_ship`.

## 5. Environment / process notes (this repo)
- Migrations do NOT fully auto-deploy: the `Deploy Supabase migrations` workflow waits on a **production**
  GitHub environment approval (owner must approve the pending deployment). PR merges need an **admin merge**
  (branch protection requires a review; as sole dev, use `gh pr merge … --admin`).
- CI on PRs: `Build (frontend typecheck)` + a `Verify` check; both must be green.
- Full local checks: `npx tsc -b && npx vite build`; unit specs: `npx playwright test <spec>` (the `*.uispec.ts`
  and `galaxy.spec.ts` need a running app + Supabase env, so run the pure `*.spec.ts` set locally).
