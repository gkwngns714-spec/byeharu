# Session Handoff — historical snapshot 2026-07-12, **current state refreshed 2026-08-11**

> # ⚠ READ **§0 — CURRENT STATE (2026-08-11)** FIRST. Everything from §1 onward is the 2026-07-12 snapshot.
>
> §0 is the live handoff. §1 (machine setup) and §4–§5 (dev-method laws, process) are still accurate and
> still worth reading. **§2, §3, §0.05 and §0.1 are historical** — superseded, kept so the record survives.
>
> **The newest truth is always `docs/DEV_LOG.md` (top entry), not this file.** §0 is refreshed at the
> end of a session; the dev log is written as the work lands.

---

## 0. CURRENT STATE (verified 2026-08-11)

> **This §0 was rewritten 2026-08-11 because it was FALSE, not merely stale.** It had been left
> claiming `main` head `38cf7e1`, highest migration `0340` and production head `0340` — eleven
> migrations and five days behind. Every line below was re-verified against git and the GitHub API on
> 2026-08-11 by the person writing it, and the evidence (commit sha, run id, file path) is written
> beside each claim. **Anything not re-verified is labelled UNVERIFIED rather than asserted.**

### Repo

| | | how it was verified (2026-08-11) |
|---|---|---|
| `main` head | **`03215ba`** (`03215ba9e7e4c5bb3b807022ee12e00d7b593a31`) — *"Merge pull request #410 … slice-the-fight-you-can-follow"* | `git rev-parse origin/main` after `git fetch` |
| Highest migration on `main` | **`0351`** — `supabase/migrations/20260618000351_the_fleet_fires_as_one.sql`; **333** migration files | directory listing of `supabase/migrations/` on `03215ba` |
| **Production migration head** | **`0351`** — deployed **2026-08-09T17:30:56Z** | *Deploy Supabase migrations* run **`31326599709`** on `main` @ `03215ba`, status `success`; its log reads `Applying migration 20260618000351_the_fleet_fires_as_one.sql...` then `Finished supabase db push.` |
| Frontend on GitHub Pages | **Current with `main`** | *Deploy to GitHub Pages* run **`31326599722`** on `03215ba`, `success` |
| CI on `main` head | **11 green, 1 RED** — see the flaky-proof note below | `gh run list --branch main`: 12 runs on `03215ba`, all `success` except run **`31326599667`** |
| Open PRs | **3.** **#163** (project map, open by design) · **#396** (owner-gated) · **#411** (conflicting) | `gh pr list --state open` |

**Migration numbers `0341`, `0342` and `0345` are absent from `main`.** `0341` is held on the branch of
**closed** PR #397 (`slice-fights-you-can-keep-up-with`, still carries
`20260618000341_fights_you_can_keep_up_with.sql`); `0342` is held on open PR #396's branch
(`20260618000342_the_shop_stops_selling_the_deep_scan_array.sql`). `0345` was **not found on `main` nor
on any ref fetched into this worktree** — 0344's header refers to "the aggregate arm's existence (0345)"
as future work, so the number appears to have been planned and never authored. *(All three checked with
`git ls-tree -r --name-only <ref> -- supabase/migrations`.)*

> Derive the next migration number from **every ref**, not from `main` or production alone —
> `git ls-tree -r --name-only <branch> -- supabase/migrations`. A duplicate version is not a git
> conflict: both files land, `schema_migrations` keys on the VERSION, and the loser is recorded
> already-applied and **silently skipped** on production. `scripts/check-migration-versions.mjs` now
> runs inside `build` and catches collisions *within a branch*, but it cannot see across branches.

### ⚠ TWO OPEN FACTS, RECORDED SO THEY ARE NOT LOST (verified 2026-08-11)

**(a) `main` currently sits on a RED proof, and the evidence says the ASSERT is flaky — not the code.**
The `DANGER-ZONE COMBAT` disposable proof (`scripts/danger-combat-proof.sql`) **failed** on `main` head
`03215ba` in run **`31326599667`** (2026-08-09T17:30:56Z). The failure:

```
scripts/danger-combat-proof.sql:6857: ERROR:  FLEETKITE FAIL: on retreat tick 4 the formation moved
0.499999999999865 but combat_unit_decide_move's kite step at the FLEET's arguments is
least(speed 0.5, reach 5 - gap 5.00000000000015) = -1.49213974509621e-13
— the retreat is not being decided at the fleet point
```

That is a **floating-point exactness assert**: `gap` came back as `5.00000000000015` instead of `5`, so
`reach - gap` went negative by 1.5e-13 and the block declared a failure the engine had not committed.
**The identical tree passed twice, minutes earlier:** commit `8f81b41` and the merge commit `03215ba`
have the **same tree** (`git diff --stat 8f81b41 03215ba` is empty; both are tree
`dcc5aca2be33ee8a6e47d5d6718059b2a9429c3d`), and on that tree the same workflow ran **`31326337950`**
(push, `success`, 17:25:05Z) and **`31326339939`** (pull_request, `success`, 17:25:07Z) before failing at
17:30:56Z. Same code, same proof, two passes and one fail ⇒ **a flaky harness assert, not a code
regression.** *What is NOT verified: the exact tolerance fix. The `FLEETKITE` block needs an epsilon on
its exactness comparison; nobody has written it yet. Until then `main` shows a red check.*

**(b) PR #411 is CONFLICTING against `main` and needs both a rebase and a real fixture fix.**
`gh pr view 411` reports `mergeable: CONFLICTING`, `mergeStateStatus: DIRTY`, last updated
2026-08-09T15:11:12Z — i.e. **before** 0350 and 0351 landed. Its branch
(`slice-a-sortie-knows-where-home-is`) carries `…0348`, `…0349`, then jumps to
`20260618000352_a_sortie_knows_where_home_is.sql`, so it was cut when `main` still ended at `0349`.
Its `disposable-matrix` is also genuinely red, and **not** for a numbering reason — run
**`31320410428`**:

```
scripts/fleetgo-proof.sql:2138: ERROR:  new row for relation "fleets"
violates check constraint "fleets_group_fleet_has_anchor"
FAIL: real-chain FLEET-GO proof failed
```

The fixture inserts a group fleet without the anchor the constraint now requires. **A rebase alone will
not make it green** — the fixture has to be fixed. *(The rest of #411's checks are green: `build`,
`frontend-tests`, `rendered-ui`, `selftest` and the other 20 `disposable-matrix` legs all pass.)*

### Open PRs — verified state 2026-08-11

| PR | state | what it is | disposition |
|---|---|---|---|
| **#163** | OPEN | PROJECTMAP standalone 3D codebase map (`feat-project-map`) | **Open by design** — intentionally never merged to `main` |
| **#396** | OPEN, **`mergeable: CONFLICTING`** | Dormant stats tell the truth + migration **`0342`** withdrawing the Deep-scan array from all three shops. Head is now `6693394` (`669339492d00847c1e0e1e78fc55965b52d9ca6e`), not the `346d3800` this file used to name | **Still held at an owner gate** *and* it no longer merges cleanly — it has sat since 2026-08-04 while eleven migrations landed. Needs owner authorization **and** a rebase. |
| **#411** | OPEN, **`mergeable: CONFLICTING`** | Migration **`0352`** — *"a sortie knows where home is"* | Conflicting since 0351 landed; red fixture. See (b) above. |

**PR #397 is CLOSED — closed 2026-08-08T14:15:30Z** (`gh pr view 397`). This file previously listed it
as an open, owner-gated PR; that was wrong. It was closed *deliberately*: migration **0344** deletes the
kill-driven escalation outright, and #397's banded ramp (`ceil(v_danger/5)`) was rejected because a ramp
that fires every fifth kill is still a ramp. `0344`'s own header (`…0344_killing_well_is_not_punished.sql`)
states that reasoning.

### ⚠ `docs/TARGET_CAPACITY_RULING.md` is PENDING DELETION — do not delete it yet

`docs/COMBAT_OWNER_DIRECTIVES_CONTRACT.md:844-849` schedules that file for deletion (its capacity model
is superseded by D5: capacity is per SHIP from WEAPON COUNT, not from a captain-level unlock table). The
same instruction says what must happen **first**, and it has not happened: its **two trailing standing
owner rulings must be re-homed verbatim** into `docs/COMBAT_DESIGN_LAWS.md` —

1. **"Rejected: a player-configurable combat-speed control"** — it carries the **anti-kite invariant**
   (`20260618000316:754-762`), which the contract calls load-bearing for Q2.
2. **"Rejected: a fleet-level range slider"** — range stays a property of weapon and content choices.

**Verified 2026-08-11: `docs/COMBAT_DESIGN_LAWS.md` DOES NOT EXIST yet** (`ls docs/` — no such file), so
there is nowhere to re-home them to. Deleting `TARGET_CAPACITY_RULING.md` today would destroy two owner
rulings on subjects that are *not* superseded. Create the laws file, move both sections verbatim, and
only then delete.

### THE LESSON OF 2026-08-04 — a disabled button is not a rule

PR #396's first head marked the Deep-scan array "not currently implemented" and disabled its Buy
button **in React only**. All three production offers were still `active = true` at 90 credits, and
`buy_shop_offer_at_port` authorizes purchase from `port_shop_offers.active` — so an authenticated
client calling the RPC directly would still have been sold it. The owner rejected the head at review.

**The general rule this is an instance of:** when a change claims to *prevent* something, prove it at
the **authoritative boundary**, not at the surface a player happens to touch. And prove non-mutation
by **before/after comparison** — a returned reason string is not evidence that nothing was written.

**Verified on target 2026-08-04, not taken from CI green:** `stat_definitions` returned HTTP 200 with
its ten seeded rows (it answered `404 PGRST205` before the deploy — a real before/after, not a bare
assertion); `game_config` was **byte-identical, 141 rows, before and after**; all eight new resolvers
answer `42501 permission denied` when probed with their **real parameter names**. *The probe must use
the real names — an invented argument returns `404 PGRST202` for a function that is present, because
PostgREST resolves overloads by argument name. That 404 means "no matching signature", not "absent".*

**Verified on target 2026-08-04, not taken from CI green:** production was probed over anon REST for
`combat_wave_arrival_phase` — 0338's new leaf — using the malformed-argument technique (PostgREST
fails at argument coercion, so no function body can execute). It answers **`42501 permission denied
for function`**, raised only for a function that **exists**, while a control name answers
`404 PGRST202`. *Note the trap: the probe must use the function's **real parameter names**. A probe
with a made-up `p` argument returns `404 PGRST202` for a function that is perfectly present, because
PostgREST resolves overloads by argument name — that 404 is "no matching signature", NOT "absent".*

**Open-PR disposition — verified at the blob level, then ACTED ON. 14 PRs closed 2026-07-31.**
Every file of every open PR was compared against `main` blob-by-blob first; nothing was closed on a
guess.

| PRs | Finding | Outcome |
|---|---|---|
| **#305, #310, #311, #313, #314, #315** | Every file **byte-identical** to `main` | **CLOSED** — superseded |
| **#306, #307, #309, #312, #316, #317** | Migration on `main`; remaining differences are **net deletions** in the `main → branch` direction, i.e. `main` carries this content *and more* | **CLOSED** — superseded; merging would have moved the tree **backwards** |
| **#299, #300** | Files are **not** on `main` (resolver preflight audit + rollback-only pre-flip damage canary). Their purpose lapsed when `0302` lit `encounter_resolver_enabled` on 07-27 | **CLOSED** — lapsed. Branches left in place, so the harness is recoverable if a future flip needs it |
| **#163** | PROJECTMAP standalone tool | **OPEN by design** — intentionally never merged to `main` |

> **The project map does NOT ship via GitHub Pages.** `pages.yml` builds the **game** from `main`;
> the repo has one Pages site and the map is not it. The map is shared by a **temporary Cloudflare
> tunnel** — `powershell.exe -File tools\projectmap\share.ps1` — whose URL dies with the window.
> Pushing `feat-project-map` is the whole delivery; there is nothing to deploy.

### What is LIVE right now

| | |
|---|---|
| `encounter_resolver_enabled` | **`true`** — lit by `0302` (2026-07-27) under an explicit owner order, as a fail-closed migration, after a blast-radius audit (0 live encounters; ONE active binding: `canary_encounter` at Reaver, difficulty 1 / cap 1 / cooldown 30s). Rollback is a set-to-false. |
| Every other capability flag | **`true`** — `0300` "lights on" flipped ~44 of them |
| `timed_docking_enabled` | **`false`** — the ONLY flag still dark |
| Combat / ambush | `0303` fixed the ambush teleport + no-fight-on-re-entry (the manifest guard counted inserts, not rows); `0304` gave every pirate zone its typed effect (zones drawn after `0273` had been inert) |
| Fleet Stop | `0305` — the brake answers **every** press: it halts ordinary travel and pre-contact sorties (releasing the aborted roster), and composes with the retreat authority in a real fight. It can no longer return `group_on_sortie` at all. |
| Empty fleets | `0306` — an emptied fleet no longer bricks itself. One docked authority (`fleet_docked_location`) replaced eleven hand-copied predicates; the last ship out retires the fleet, assign self-heals a ghost, and a backfill retired every already-orphaned fleet. **Live.** |
| Map | Danger zones name themselves on hover; **zone info lives on the double-tap command hub** ("What's here"), not on a click — the zone fill declares `data-map-passthrough` so it can hover-test without swallowing the map's gestures (PR **#336**, fixing the regression PR #334 introduced) |
| **Combat engine (0336)** | Eight defects fixed in the fight itself: multi-gun ships no longer discard guns on kill ticks; a wave spawns **spread on a ring**, not stacked on one point; retreating no longer spawns a wave that shoots a fleet which cannot shoot back (**this was destroying the whole haul**); the four terminal arms are confined and all four consume the retreat target; the actor loop is ordered; the kite is capped by the **shortest** gun; The Furnace is no longer a mathematically unwinnable standoff. **No knob moved.** |
| **Reposition (0337)** | In-combat movement is a **journey, not a teleport**. 0311's three instant writes are gone; the fleet translates rigidly toward `combat_encounters.reposition_x/y` at `combat_fleet_move_speed` (min over living hulls). **Consequence, stated:** at live speeds (0.2–1.0 units/3 s tick against zone spans of 29–79) crossing a zone under fire takes **minutes**, and a repositioning fleet **cannot outrun its pursuers**. If it plays too slowly the fix is one knob — `combat_player_speed_scale` — deliberately NOT changed in that slice. |
| **Enemy origin (0338)** | Enemies **come out of the zone's own city**. `combat_wave_arrival_phase` is the one authority for a wave's arrival bearing; the wave opens as a compact arc centred on the owning settlement (6 pirates span 112.5°) instead of encircling. The origin is a **bearing, never a position** — a distant city must not become a forty-tick walk. It is DATA: re-pointing a zone's raiders at another city is one row. |
| Client (2026-08-03/04) | Combat **animates** between ticks (one lerp authority, `smoothCombatUnits` moves the rows so glyph and badge cannot disagree); the fleet renders as **one actor**, not four ships; real ordnance is drawn from the gun's share of its ship's volley. A fleet **always** has a map marker (four existence resolvers deleted for one presence-per-group; the badge is honest about partial placement, e.g. "Fleet 1 1/4"). New **`/assets`** destination — what you own, where, and what that city pays. **One** repair surface. Hunting is signposted from the zone panel, and a near-missed ambush is no longer silence. |

**Verified on target 2026-07-31** (not from CI green): `0306`'s `group_retire_empty_fleet` and
`group_fleet_retire` probed on production over anon REST with a **deliberately malformed uuid**, so
PostgREST fails at argument coercion and no function body can execute. Both answer `42501 permission
denied for function` — raised only for a function that **exists** — while a control name answers
`404 PGRST202`. Earlier, 2026-07-29: prod `game_config` read over anon REST for the flag posture, and
`rpc/group_sortie_is_open` called on production through the owner's own session (HTTP 200) for `0305`.

### Known red / debt

- ~~**`TEAM-COMMAND` disposable proof fails at `SHIELD1`**~~ — **RESOLVED.** The workflow runs green on the current chain (runs `30839137155`, `30838218555`, 2026-08-03).
- **The ECONOMY findings of the four-domain audit are still open, and they are deferred by the owner** until combat is playable (RS3 is the stated target). Measured, not guessed: Reaver and Blackden declare `min_power_required = 0` but actually need ~16 and ~26, so **a starter fleet is guaranteed a zero-reward loss**; the reward curve is **inverted** (Snare pays ~10× Blackden for identical hull cost, because loot gates on wave DEPTH); **metal is a dead currency** — 179,599 banked and `build_orders` empty since launch.
- **`repair_credits_per_hp` is `0` (repair is FREE) — the owner's call, and explicitly TEMPORARY**, pending the loot economy. Restoring a price is one `npm run knob:set` call; 0335 made `0` mean free, while null/negative still fail closed.
- **A DEV_LOG entry can be flatly wrong, not just stale.** The `0336` entry shipped carrying a **verbatim copy of the `slice-hunting-is-findable` body** — it described a client-only slice and said *"no migration"* about a migration. Rewritten 2026-08-04 from the deployed migration header. When recording several slices at once, the copy-paste risk is the entry BODY, not just the deploy line.
- **`docs/DEV_LOG.md` has no entries for migrations `0273`–`0302`** — the typed-zone platform and the combat overhaul. Detail lives in the migration headers and PR bodies.
- **The dev log went four migrations blind between 2026-08-08 and 2026-08-09, and it was found on 2026-08-11.** `0344`, `0346`, `0347` and `0351` all shipped **and deployed** with **no `DEV_LOG.md` entry at all** — only their migration headers and PR bodies recorded them. All four were written on 2026-08-11 from those two sources. **Still missing, verified by grepping `^## ` over `DEV_LOG.md` against the merged-PR list:** migration **`0343`** (PR #398, *one way to die*), and the client-only PRs **#399** (*one fleet, one shape*) and **#402** (*the fight reads true*). They were out of the scope of the 2026-08-11 correction and are named here so they are not lost a second time. *The pattern: entries get skipped when several slices land in one day.*
- **`docs/HANDOFF.md` §0 itself was FALSE for five days**, not merely stale — it asserted `main` head `38cf7e1` / migration `0340` / prod `0340` while `main` was `03215ba` and production was on `0351`, and it listed a PR closed on 2026-08-08 as open and owner-gated. Corrected 2026-08-11. **A §0 that is not re-verified becomes an actively misleading document, because it is written in the voice of something that was checked.** Re-verify it — `git rev-parse origin/main`, the migrations directory listing, `gh run list --workflow=deploy-migrations.yml`, `gh pr list --state all` — before trusting a single line of it.
- **The "What is LIVE right now" table below stops at `0338`.** Everything from `0343` onward (`0343` wreck authority, `0344` time-driven pressure, `0346` city ingress, `0347` growing field, `0348`–`0351`) is **deployed to production** but is described only in `DEV_LOG.md` and the migration headers, not in that table. Read the dev log, not the table, for the current combat engine.
- **A log entry can outlive the state it describes.** The `0306` entry sat at the top of `DEV_LOG.md` reading *"NOT DEPLOYED — PR open"* for a day **after** it was merged and applied to production, and PR #336 shipped with no entry at all. Both corrected 2026-07-31. The entry is written when the work lands; **the deploy line has to be revisited when it actually deploys**, or the newest doc in the repo becomes the most misleading one. *(This bites fast: the first version of this very §0 said the 14 PR closes were "blocked, not performed" — true when written, false twenty minutes later. **Re-read §0 against reality before trusting it**, and it is cheap to re-verify: `gh pr list`, `git rev-parse origin/main`, and the malformed-uuid prod probe.)*
- **`tools/projectmap` drifts silently and nothing warns you.** As of **2026-08-04 it is 215 commits behind `main`** — it is drawing a codebase that no longer exists. (For scale: on 2026-07-31 it was 54 commits / **34 migrations** behind `main` — it was drawing a codebase that no longer existed (`266→300` migrations, `743→817` nodes after the refresh).) Nothing in CI checks this. Refresh it after any game change: merge `origin/main` in, then `npm run scan` + `npm run wip` in `tools/projectmap`, commit `public/graph.json` + `public/wip.json`, push. `npm run live` is the third leg but writes gitignored `public/live.json`, so it never ships.
- **Six docked-test copies remain** (`0210:178-186`, `0210:299-303`, `0231:1069-1073`, `0231:1486-1501`, `0297:126-131`) — all read-side projections, named as an explicit non-goal by `0306` rather than silently skipped. They now have `fleet_docked_location` to fold onto.

### ⚠ Fleet 1 was destroyed 2026-07-29T05:37:22Z — **and its wrecks are now recoverable**

Encounter `d16f308d` ran to tick 130 (player power 60 → 0 vs 872). All four ships `destroyed`; only
Sparrow II (Fleet 2) survives. The Stop refusal that `0305` fixes is what denied the escape.

**Since then:** `0334` gave a wreck a port (a grouped ship's port is the single port its group's live
fleets are docked at) — Sparrow IV/V went `null` → **Haven** on production — and `0335` made repair one
action at `repair_credits_per_hp = 0`. **So Fleet 1 can be restored, free, at Haven.** It had not been
done as of this refresh.

---

## 0.1 PRIOR STATE (historical — 2026-07-23, kept for the record)

### Repo, as of 2026-07-23

| | |
|---|---|
| `main` head | **`ce26486`** (merge of PR **#287**) |
| Open PRs | **#163** only (PROJECTMAP tool, branch `feat-project-map` — **intentionally not on `main`**) |
| Merged that session | **#282** `68ea475` · **#283** `86c2c73` · **#286** `b9e2560` · **#288** `a086800` · **#285** `2279b45` · **#284** `b11b3bd` (mig `0272`) · **#287** `ce26486` |
| Closed unmerged | **#162** (edits an already-applied migration → guaranteed prod no-op; re-author as a *forward* migration) · **#245** (×17 coordinate normalize — rejected direction; slot `0253` is intentionally reserved and absent from `main`) · **#221** (Zone Templates plan — predates the whole V1→V5 program; rewrite against current architecture) |

### Migrations — `main` and production were in sync at `0272`

| | |
|---|---|
| Highest migration on `main` | **`0272`** (`20260618000272_encounter_elite_stat_wiring.sql`) |
| **Production migration head** | **`0272`** |
| How | The owner approved the `production` gate. Deployment **`5566872965`** (created 2026-07-23T04:21:27Z, ref `main`, commit **`b11b3bd`**) / workflow run **`29979341800`** completed **`success`** at **2026-07-23T06:48:43Z**. The deploy log shows `Applying migration 20260618000272_encounter_elite_stat_wiring.sql…` then `Finished supabase db push.` |

> **`0272` IS DEPLOYED — and it landed DARK.** Its in-transaction self-assert **passed on live
> Postgres**: `encounter_resolver_enabled` still `false`, no new flag, `process_combat_ticks` not
> re-created, no elite column anywhere, ACL unchanged. The before/after verifier returned
> **`PD0272S_DIFF_PASS` — 2 intended changes, 0 unintended** (`encounter_elite_difficulty_multiplier`
> absent → `2`; `game_config` row count `139 → 140`); every `must_not_change.*` value was byte-identical.
> **No player-visible behaviour became reachable** — both bindings are still inactive and no member has
> `elite_chance > 0`. Elite is deployed *code*, not observed *behaviour*: do not describe elite
> encounters as something players can meet today. Full record: `docs/DEV_LOG.md` §9.

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

### Combat content — what was lit in production **as of 2026-07-23**

> **SUPERSEDED 2026-07-29 — see §0.** `encounter_resolver_enabled` is now **`true`** (lit by `0302`
> on 07-27), so the paragraph below is history. It is kept because it records *why* the flag was held
> dark for so long.

`enemy_content_registry_enabled`, `encounter_authoring_enabled` and `encounter_binding_authoring_enabled`
are **`true`** (owner authoring surfaces only). **`encounter_resolver_enabled` is `false`** — the one
behaviour-changing flag. Two encounter bindings exist, both inactive; the `canary_encounter` chain
(binding `2f7bcf88`) is the selected canary. See `docs/COMBAT_CONTENT_PROGRAM.md` §7.

### THE NEXT STEPS (as of 2026-07-23 — all resolved; kept for the record)

1. ~~**Approve the `production` gate for `0272`**~~ — **DONE 2026-07-23**.
2. ~~**Execute the unified-movement smoke**~~ — **DONE 2026-07-24**, full pass on production with an
   expendable fleet (Fleet 2), including the decisive no-crossing proof (empty `pirate_intercepts`
   for the movement). Movement moved from classification **B** to **A**.
3. ~~**Encounter canary**~~ — **OVERTAKEN 2026-07-27.** The owner ordered "don't make anything dark",
   and `0302` lit the resolver through the deploy pipeline as a fail-closed migration instead of via
   the canary scripts. The canary packets remain as the record of the method.
4. ~~**Team-command activation**~~ — lit with everything else by `0300`.

### THE NEXT STEPS (2026-07-29)

1. **Play-test the map's zone info and the new Stop** — both are live and neither has had a real
   player session yet.
2. **Decide `timed_docking_enabled`**, the last dark flag. The owner's "don't make anything dark"
   order did not include it and `0300` deliberately left it out.
3. **Close the stale PRs** (#305–#317 already on `main`; #299/#300 lapsed).
4. **Back-fill `DEV_LOG.md` for `0273`–`0302`** — the one real documentation gap.
5. **Fix `TEAM-COMMAND`'s `SHIELD1`** red (harness debt, pre-existing).

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
> `main` @ **`ce26486`**, one open PR (**#163**), highest migration on `main` **`0272`**, and **production
> head `0272`** — the `0272` deploy was approved by the owner and completed `success` on 2026-07-23.
> Original text kept.

- **`main` @ `9a292ed`** (merge of PR #97). **Zero open PRs.** Everything below is merged.
  **SUPERSEDED 2026-07-23** — see §0.
- **Prod migration head = `20260618000169`** (the owner approved 0165 + 0166–0169 to production
  2026-07-12; the Deploy workflow's production-environment gate is the approval mechanism).
  **SUPERSEDED 2026-07-23** — prod head is **`0272`**, in sync with `main`.
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
> step**: the unified-movement smoke and the encounter canary still sit in front of it (§0). (The `0272`
> production-gate approval, previously listed here, is **done** — prod head is `0272`.) "Nothing is in flight" was true on 2026-07-12 and is **false today**.

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
