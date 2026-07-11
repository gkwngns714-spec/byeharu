# Session Handoff — 2026-07-12

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

## 2. Current state — repo & prod (verified 2026-07-12)
- **`main` @ `9a292ed`** (merge of PR #97). **Zero open PRs.** Everything below is merged.
- **Prod migration head = `20260618000169`** (the owner approved 0165 + 0166–0169 to production
  2026-07-12; the Deploy workflow's production-environment gate is the approval mechanism).
- **Pages deploy is live** — players see the new **Mission Control UI** (renewal R0–R4).

### Live game (port-centric — activated 2026-07-08)
On the LIVE prod DB (`game_config`):
- `mainship_space_movement_enabled = true` — OSN port-to-port travel + docking is ON.
- 3 starter ports REVEALED (active on the map): **Haven** (`b1a00001-…`), **Slagworks** (`…02`),
  **Driftmarch** (`…03`). Reveal is one-way.
- `station_storage_enabled = true` — per-port, per-player storage (the docked-port "Hangar").
- `mainship_send_enabled = true` — the legacy expedition send loop.
- Rollback (flags only; port reveal persists): flip flags false via the `set_game_config` RPC
  (pattern: `scripts/dev-mainship-flag.mjs`).

### Built DARK — the complete inventory (all merged + deployed, nothing player-visible)
Every system below is implemented, proven by its verify script / disposable proof, and gated
server-side (reject-before-read) + client-side (compile-time or server-lit UI). Flag flips are
**human activation decisions, never part of a slice**.

| System | Scope | Dark gate(s) |
|---|---|---|
| **Team command — COMPLETE (A → D4)** | teams (1–3) of owned ships; group send/stop; captains-in-teams preview; authoritative team stats; **team combat over the existing engine** (ONE fleet + manifest + member `combat_units`); dark Hunt UI. Migrations 0160–0169. See `docs/TEAM_COMMAND.md`. | `team_command_enabled` + compile-time `TEAM_COMMAND_ENABLED` |
| Captains (P15/P16) | catalog, mint/assign sole writers, stats via `calculate_expedition_stats`, recruit + progression | `captain_assignment_enabled`, `captain_progression_enabled` |
| Trade V1 (TRADE-FLEET-0C + MARKET-1 + UI-1) | multi-ship, m³ ship-bound cargo, server market, wallet/credits, relief floor | `trade_market_enabled`, `trade_relief_enabled` + `TRADE_MARKET_ENABLED` |
| Multi-ship commissioning | `commission_additional_main_ship` (credit-priced, `main_ship_price` = 1000) | `mainship_additional_commission_enabled` + `MAINSHIP_ADDITIONAL_ENABLED` |
| Exploration (P11) | 5 seeded sites, OSN-proximity scan, discovery rewards | `exploration_enabled` (UI is server-lit) |
| Mining (P12) | extraction + double-extract guard | `mining_enabled` |
| Modules (P13) + Fitting (P14) | module crafting, instances, fitting, stats via the adapter | `module_crafting_enabled`, `module_fitting_enabled` |
| Ranking (P17) | seasons, counted grants, accrue cron | `ranking_enabled` |
| Location investment (P18) | invest command | `location_investment_enabled` |
| World balance (P19) | price drift | `world_balance_enabled` |
| World events / Phase-20 polish | world-events writer + read surface, UI asset catalog | `phase20_polish_enabled` |
| OSN free coordinate travel | arbitrary-coordinate movement | `mainship_coordinate_travel_enabled` + `OSN_COORDINATE_TRAVEL_ENABLED` |

## 3. THE ONE NEXT STEP — team-command activation
The dark build is complete; nothing is in flight. What remains is the **human-gated activation** per
`docs/TEAM_COMMAND.md` → **"ACTIVATION CHECKLIST — the single source of truth"**: the flag flips
(`team_command_enabled`, `TEAM_COMMAND_ENABLED`, optionally `captain_assignment_enabled`), the deferred
captain-slot bump migration (hull 2 → 6 + instance backfill — exact SQL pinned in TEAM_COMMAND.md),
the lit-time balance decisions (enemy scaling vs team power, `max_active_fleets`, partial-destruction,
`retreat_safety`), and the post-flip smoke (`scripts/team-command-proof.sh` against the lit env).

**Decision support: `docs/TEAM_ACTIVATION_PACKET.md`** — computed balance numbers per hunt zone,
commissioning economics, and a staged flip plan (including a low-risk `exploration_enabled` flip that
can go first).

Pre-activation blockers: **all closed** (M1 — the live single send's lost-update race — fixed in D3,
migration 0169). Optional, non-gating: the Low-2 lock-ordering polish from D3's adversarial review.

## 4. Dev-method laws (how work is done in this repo — non-negotiable)
1. **Anti-spaghetti (team command, from the docs):** (1) a group resolves into the EXISTING
   `fleet_units`/`combat_units` combat input — never a second combat engine; (2) reuse the
   `fleets`/movement spine — never a second movement engine; (3) RPCs stay `main_ship_id`/group-shaped;
   (4) "group" in code, "team" in UI; ONE client selection source (`shellState.selection`).
2. **Dark-first:** every feature ships fully gated — server flag checked FIRST, reject-before-any-read;
   UI compile-time-gated or server-lit; **flag flips are human activation, never part of a slice**.
   Live function re-creates follow the D1 parity discipline (copy the grep-verified TRUE head; every
   delta provably inert; diff-verified).
3. **One green PR per slice:** small vertical slices, each its own branch + PR with
   `Build (frontend typecheck)` + `Verify` green, merged before the next slice starts.
4. **CI disposable proof:** DB-touching slices carry a write-then-ROLLBACK proof
   (`scripts/*-proof.{sql,sh}` wired into a workflow) that exercises the real chain in one rolled-back
   txn — never trust-by-reading. Sole-writer laws are grep-enforced in proof selftests.
5. **Fable implementer/reviewer loop:** each slice is implemented, then adversarially reviewed
   (findings fixed or explicitly deferred with severity, e.g. D3's Low-2), then merged as one green PR;
   the **human owner gates deploys and every flag flip** (the GitHub production-environment approval).

## 5. Environment / process notes (this repo)
- Migrations do NOT fully auto-deploy: the `Deploy Supabase migrations` workflow waits on a **production**
  GitHub environment approval (owner must approve the pending deployment). PR merges need an **admin merge**
  (branch protection requires a review; as sole dev, use `gh pr merge … --admin`).
- CI on PRs: `Build (frontend typecheck)` + a `Verify` check; both must be green.
- Full local checks: `npx tsc -b && npx vite build`; unit specs: `npx playwright test <spec>` (the `*.uispec.ts`
  and `galaxy.spec.ts` need a running app + Supabase env, so run the pure `*.spec.ts` set locally;
  team specs: `npm run verify:team:unit`).
