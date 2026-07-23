# Session Handoff — historical snapshot 2026-07-12, **current state refreshed 2026-07-23**

> # ⚠ READ **§0 — CURRENT STATE (2026-07-23)** FIRST. Everything from §1 onward is the 2026-07-12 snapshot.
>
> §0 is the live handoff. §1 (machine setup) and §4–§5 (dev-method laws, process) are still accurate and
> still worth reading. **§2 and §3 are historical** — superseded by §0, kept so the record survives.

---

## 0. CURRENT STATE (verified 2026-07-23)

### Repo

| | |
|---|---|
| `main` head | **`ce26486`** (merge of PR **#287**) |
| Open PRs | **#163** only (PROJECTMAP tool, branch `feat-project-map` — **intentionally not on `main`**) |
| Merged this session | **#282** `68ea475` · **#283** `86c2c73` · **#286** `b9e2560` · **#288** `a086800` · **#285** `2279b45` · **#284** `b11b3bd` (mig `0272`) · **#287** `ce26486` |
| Closed unmerged | **#162** (edits an already-applied migration → guaranteed prod no-op; re-author as a *forward* migration) · **#245** (×17 coordinate normalize — rejected direction; slot `0253` is intentionally reserved and absent from `main`) · **#221** (Zone Templates plan — predates the whole V1→V5 program; rewrite against current architecture) |

### Migrations — **`main` and production are NOT in sync**

| | |
|---|---|
| Highest migration on `main` | **`0272`** (`20260618000272_encounter_elite_stat_wiring.sql`) |
| **Production migration head** | **`0271`** |
| Why | The `Deploy Supabase migrations` run for the `0272` merge (**`29979341800`**) is **`waiting` at the `production` environment approval gate.** The owner **deliberately deferred** the approval. |

> **`0272` is MERGED TO `main` BUT NOT DEPLOYED.** Nothing in it is live. Do not describe elite
> encounters as a production behaviour. Deployment is pending owner approval at the production gate.

### Movement — **classification B, evidence incomplete**

Unified fleet movement is live (`fleet_movement_unified_enabled = true` since 2026-07-17T22:56:59Z), and
its *code-level* correctness is proven. What is **not** proven is any **runtime observation** — `fleets`,
`fleet_movements`, `main_ship_instances`, `ship_groups` and `location_presence` are all RLS-scoped and
return zero rows to an anonymous reader, and the real-Postgres `osn3-fleetgo-realchain-proof` could not
run (no Docker / Supabase CLI / `psql` on this machine).

> **The unified-movement production smoke has NOT been performed.**
> `docs/MOVEMENT_SMOKE_PACKET.md` is a **prepared, unexecuted** packet. Running it requires the owner to
> name an **expendable** fleet and explicitly authorise a production write.

Two corrections worth carrying forward:

- **The canonical mover's TRUE HEAD is `20260618000233_…:589`**, not `0207` / `0208` (superseded bodies).
- **`fleet_control_enabled = false` is VALID** alongside unified movement — `0204:24-25` records that it
  gates only the command-ship-required movement check and the 8-ship assign cap, neither of which the
  unified mover reads.

### Pirate interception is INTENDED — do not "fix" it

`20260618000236_pirate_intercept_reliable_ambush.sql` deliberately set `base_risk = 1.0` (`:51`),
`min_risk = 0.98` (`:52`), `max_risk = 1.0` (`:53`), `exposure_floor = 1.0` (`:54`) per an explicit owner
directive in the migration header (`:15`). Any leg touching an active danger zone is intercepted with
probability ∈ **[0.98, 1.0] regardless of fleet strength**, by design; the ~2% escape is deliberate.
Live-verified: `pirate_intercept_enabled = true`, `spatial_combat_enabled = true`.

### The rollback story (superseding §2's rollback line)

The legacy per-ship movement path is **dropped, not merely darkened** (`0231` dropped the columns, `0232`
dropped 20 functions), so a flag-only rollback cannot restore it. **PR #288 made that rollback fail
closed**: the four inverse `set_game_config` writes are deleted and the remaining commented block raises
on its first statement if run. The **activation path is unchanged** (proven byte-identical). Full
analysis: **`docs/MOVEMENT_ROLLBACK_DEFECT.md`**.

### Combat content — what is lit in production

`enemy_content_registry_enabled`, `encounter_authoring_enabled` and `encounter_binding_authoring_enabled`
are **`true`** (owner authoring surfaces only). **`encounter_resolver_enabled` is `false`** — the one
behaviour-changing flag. Two encounter bindings exist, both inactive; the `canary_encounter` chain
(binding `2f7bcf88`) is the selected canary. See `docs/COMBAT_CONTENT_PROGRAM.md` §7.

### THE NEXT STEPS (this supersedes §3)

1. **Approve the `production` gate for `0272`** — owner-only; until then prod stays at `0271`.
2. **Execute the unified-movement smoke** (`docs/MOVEMENT_SMOKE_PACKET.md`) with an owner-named
   **expendable** fleet — moves movement from classification **B** to **A**.
3. **Encounter canary** — activate the `canary_encounter` chain, **not** `pirate_basic` (its
   `cooldown_seconds = 0`, i.e. no spawn throttle).
4. **Team-command activation** (the old §3) is still an open human gate, still per
   `docs/TEAM_COMMAND.md` + `docs/TEAM_ACTIVATION_PACKET.md`, but it is **no longer "THE ONE next step"**
   — items 1–3 above sit in front of it.

---

> # ⚠ EVERYTHING BELOW IS THE 2026-07-12 SNAPSHOT — read §0 above first (banner added 2026-07-23)
>
> The snapshot below is from **2026-07-12** and its **movement and live-flag statements are FALSE today.**
> The rest (dev-method laws, machine setup) is still broadly useful. Corrections are marked inline as
> **SUPERSEDED 2026-07-23**; the original text is kept so the historical record survives.
>
> **The headline correction:** §2 says `mainship_send_enabled=true` and that OSN port-to-port travel +
> docking are live. On **2026-07-18** the unified-fleet mover was flipped on and the per-ship movement
> path was closed and then **physically dropped**. In production today:
>
> | flag | value | `updated_at` |
> |---|---|---|
> | `fleet_movement_unified_enabled` | **true** | 2026-07-17T22:56:59Z |
> | `mainship_send_enabled` | **false** | 2026-07-17T22:56:59Z |
> | `mainship_space_movement_enabled` | **false** | 2026-07-17T22:56:59Z |
> | `mainship_coordinate_travel_enabled` | **false** | 2026-07-17T22:56:59Z |
>
> The per-ship travel path is **not merely gated — it is dropped** (`0231` dropped the columns, `0232`
> dropped 20 functions). Consequently **the documented rollback is broken**: see
> **`docs/MOVEMENT_ROLLBACK_DEFECT.md`**.
>
> **The cutover was an ACT SCRIPT, not a migration.** All four flag writes are in
> `scripts/activate-unified-movement.sql:242-256` (`set_game_config`, one transaction), commit `56a84c3`
> (2026-07-18). Grepping `supabase/migrations/` for the flag change will find **nothing**.
>
> Current movement truth lives in **`docs/MOVEMENT_UNIFICATION_CHARTER.md`** (true heads, post-flip
> cleanup actual state, live pirate-intercept characteristic, and the **classification-B** verification
> status — no live gameplay has been observed).

Snapshot of where development stands, so work can continue on another computer. This file is committed
to the repo (it travels via GitHub); the per-machine plan/memory files do NOT travel.

## 1. Moving to a new computer — checklist
1. `git clone https://github.com/gkwngns714-spec/byeharu.git && cd byeharu`
2. `npm install` (native binaries must be installed fresh — do NOT copy `node_modules`).
3. **Bring `.env.local`** — it is gitignored, so it is NOT in GitHub. Copy the file from the old machine
   (or recreate it from the Supabase dashboard). It contains: `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`,
   `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD`, `SUPABASE_PROJECT_ID`
   (project ref `dlkbwztrdvnnjlvaydut`). Without it, the app + verify/activation scripts can't reach the DB.
   > **⚠ MACHINE-SPECIFIC (noted 2026-07-23):** the contents listed above are what *one* machine had. On
   > the machine that ran the 2026-07-23 movement audit, `.env.local` held exactly two lines —
   > `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` — i.e. **anon only, no prod credentials**. Read the
   > file and test before assuming service-role/Management-API access. (Same correction applies to
   > `MOVEMENT_UNIFICATION_CHARTER.md`'s "DB access" section.)
4. Tooling: **Node.js LTS** (`winget install -e --id OpenJS.NodeJS.LTS`), **Supabase CLI** (standalone
   binary from GitHub releases, add to PATH), **GitHub CLI** (`winget install -e --id GitHub.cli` then
   `gh auth login` → github.com / HTTPS / browser). `psql` is NOT required (the OSN runbook is CI-only;
   direct SQL is done via the Supabase REST API + service-role key in the `.mjs` scripts).
5. Run: `npm run dev` → `http://localhost:5173/byeharu/` (base path `/byeharu/` is required). Live site:
   `https://gkwngns714-spec.github.io/byeharu/` (auto-deploys from `main` via Pages).

## 2. Current state — repo & prod (verified 2026-07-12) — ⚠ **SUPERSEDED 2026-07-23 by §0**
> The head, PR and migration numbers in this section are **eleven days stale**. Current truth is in §0:
> `main` @ **`ce26486`**, one open PR (**#163**), highest migration on `main` **`0272`**, **production
> head `0271`** with the `0272` deploy **waiting at the production approval gate**. Original text kept.

- **`main` @ `9a292ed`** (merge of PR #97). **Zero open PRs.** Everything below is merged.
  **SUPERSEDED 2026-07-23** — see §0.
- **Prod migration head = `20260618000169`** (the owner approved 0165 + 0166–0169 to production
  2026-07-12; the Deploy workflow's production-environment gate is the approval mechanism).
  **SUPERSEDED 2026-07-23** — prod head is **`0271`**; `main` carries **`0272`**, undeployed.
- **Pages deploy is live** — players see the new **Mission Control UI** (renewal R0–R4).

### Live game (port-centric — activated 2026-07-08) — ⚠ **MOVEMENT LINES SUPERSEDED 2026-07-23**
> The two movement flags below are **FALSE in prod today** (both since 2026-07-17T22:56:59Z) and the
> per-ship path they gated has been **dropped**, not just darkened. Movement is now the unified fleet
> mover (`fleet_movement_unified_enabled=true`). The port reveals and `station_storage_enabled` lines are
> unaffected. The rollback line at the end of this block is **broken** —
> see `docs/MOVEMENT_ROLLBACK_DEFECT.md`. Original text kept below.

On the LIVE prod DB (`game_config`):
- ~~`mainship_space_movement_enabled = true` — OSN port-to-port travel + docking is ON.~~
  **FALSE since 2026-07-17T22:56:59Z.**
- 3 starter ports REVEALED (active on the map): **Haven** (`b1a00001-…`), **Slagworks** (`…02`),
  **Driftmarch** (`…03`). Reveal is one-way.
- `station_storage_enabled = true` — per-port, per-player storage (the docked-port "Hangar").
- ~~`mainship_send_enabled = true` — the legacy expedition send loop.~~
  **FALSE since 2026-07-17T22:56:59Z.** The legacy expedition RPCs it gated
  (`send_main_ship_expedition`, `move_main_ship_to_location`, `request_main_ship_return`, and the whole
  OSN coordinate command surface) were **dropped** by `20260618000232_movement_function_drop.sql:231-264`.
- ~~Rollback (flags only; port reveal persists): flip flags false via the `set_game_config` RPC
  (pattern: `scripts/dev-mainship-flag.mjs`).~~ **⚠ NOT VALID for the movement flags.** Flag-only rollback
  cannot restore dropped functions/columns, and re-lighting `mainship_send_enabled` would turn
  `command_main_ship_stop_transit`'s clean `feature_disabled` reject into a runtime
  `column does not exist` raise. **See `docs/MOVEMENT_ROLLBACK_DEFECT.md`.**

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
| ~~OSN free coordinate travel~~ **SUPERSEDED 2026-07-23** — the per-ship coordinate surface was dropped by `0232`; free-coordinate travel is now a property of the unified fleet mover (`command_ship_group_go`, true head `20260618000233_…:589`), not of this dark slice | arbitrary-coordinate movement | `mainship_coordinate_travel_enabled` = **false** since 2026-07-17T22:56:59Z + `OSN_COORDINATE_TRAVEL_ENABLED` |

## 3. THE ONE NEXT STEP — team-command activation — ⚠ **SUPERSEDED 2026-07-23 by §0**
> Still an open human gate and still accurate about *how* to do it, but it is **no longer the single next
> step**: the `0272` production-gate approval, the unified-movement smoke, and the encounter canary all
> sit in front of it (§0). "Nothing is in flight" was true on 2026-07-12 and is **false today**.

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
