# Combat-Content Program (E0–E4) — architecture, ship order, and go-live

Status: **built and stacked, DARK.** Every migration in this program is seeded `false` and read by
nothing at runtime; existing pirate combat is **byte-identical** until the owner runs the activation
scripts. (Merge/deploy state is tracked by the approval-gated `deploy-migrations.yml` runs, not by
this document — an earlier "UNDEPLOYED" here went stale. What keeps the program inert is the flags,
which are still `false`, not the deploy state.) This document is the reviewer- and
owner-facing map of the whole program: what it is, the exact merge/deploy/flag-flip order, the
byte-identity guarantee, and the deferred items.

> **Deploy state (2026-07-23).** `0257`–`0271` are deployed; **production migration head is `0271`.**
> **`0272` (elite stat wiring) is merged to `main` but NOT deployed** — its `Deploy Supabase migrations`
> run (`29979341800`) is waiting at the `production` approval gate, deferred by the owner. In production
> today `enemy_content_registry_enabled` / `encounter_authoring_enabled` /
> `encounter_binding_authoring_enabled` are **`true`** (owner authoring surfaces only) and
> **`encounter_resolver_enabled` is `false`** — combat is unchanged. See §7 / §7a.

The activation scripts that flip these flags are authored (not run) in `scripts/activate-*.sql`
(one per flag, plus a combined runner). They are **AUTHORED-NOT-RUN** — the owner runs them at
go-live, in order.

---

## 1. What the program builds — the content chain

The program adds an **owner-authored content authoring system** for combat encounters, plus the
**runtime resolver** that consumes it. It is a five-slice stack (E0–E4). The content flows in one
direction:

```
enemy archetypes + reward profiles        (E0 — the reusable enemy TEMPLATES + reward formulas)
        └──► fleet templates + encounter profiles   (E1 — compose archetypes into fleets/encounters)
                    └──► location → encounter bindings   (E2 — bind an encounter profile to a place)
                                └──► runtime resolver         (E3 — plan an encounter from the chain, in-tick)
                                            └──► World Editor UI  (E4 — the owner authors all of the above)
```

- **E0 — Enemy Content Registry** (migration `0257_enemy_content_registry.sql`).
  Two net-new owner-authored catalog tables — `public.reward_profiles` (reusable reward-formula
  parameterization) and `public.enemy_archetypes` (reusable enemy template; carries no
  runtime-instance state) — plus **six** owner-gated write RPCs (`reward_profile_create/update/set_active`,
  `enemy_archetype_create/update/set_active`, each `(text, jsonb)`). Flag: **`enemy_content_registry_enabled`**.
  Seeds mirror today's scalars (`pirate_standard` reward profile, `pirate_light`/`pirate_heavy`
  archetypes) but are read by nothing at runtime.

- **E1 — Fleet Templates + Encounter Profiles** (migration `0258_fleet_templates_encounter_profiles.sql`).
  Four net-new tables — `enemy_fleet_templates` (+ normalized child `enemy_fleet_template_members`)
  and `encounter_profiles` (+ normalized child `encounter_profile_members`) — that **compose** the E0
  catalog. **Six** owner-gated RPCs (`enemy_fleet_template_create/update/set_active`,
  `encounter_profile_create/update/set_active`). Flag: **`encounter_authoring_enabled`**. The RPCs are
  **dual-gated**: each checks `cfg_bool(enemy_content_registry_enabled)` **AND**
  `cfg_bool(encounter_authoring_enabled)` first (E1 references E0's tables, so E0 must be live too).
  Also adds cross-slice deactivation-guard triggers on E0's tables (can't soft-disable an archetype/
  reward profile still referenced by an active downstream entity).

- **E2 — Location → Encounter Bindings** (migration `0259_location_encounter_bindings.sql`).
  One net-new join table `location_encounter_bindings` binding a live `locations` row to an
  `encounter_profiles` row with a per-binding weight. **Three** owner-gated RPCs
  (`location_encounter_binding_create/update/set_active`). Flag:
  **`encounter_binding_authoring_enabled`**. **Tri-gated**: E0 **AND** E1 **AND** E2 must be true.
  Create requires the location to exist but not to be active (liveness is deferred to the E3
  resolver).

- **E3 — Encounter Runtime Resolver** (migration `0260_encounter_runtime_resolver.sql`).
  The runtime consumer. Adds `resolve_location_encounter(uuid)` (deterministic, quad-flag-gated
  encounter planner, returns a plan or NULL — **E5/0261 replaces this signature with
  `resolve_location_encounter(uuid, text)`**), `resolve_encounter_reward_inputs(jsonb, integer, integer)`
  (the algebraic mirror of the legacy reward formula), the `encounter_runtime_state` table
  (cooldown/active_count anchor), and **re-creates `process_combat_ticks()`** as the 0234 body
  **verbatim** plus a one-read `v_resolver_engaged` flag and two wrapped arms. Flag:
  **`encounter_resolver_enabled`**. **Quad-gated**: the resolved branch is reachable only when all
  four flags (E0+E1+E2+E3) are true. **This is the one flag whose flip changes combat behavior.**

- **E4 — World Editor Combat-Authoring UI** (frontend only; PR #261 / branch
  `slice-e4-worldeditor-combat-ui`). The owner-only, fail-closed World Editor screens that author
  everything above. No migration, no runtime combat path.

- **E5 — Resolver Per-Encounter Variety + Zero-Elite Readiness** (migration
  `0261_encounter_variety_zero_elite.sql`; branch `slice-e5-resolver-variety-zero-elite`, stacked on the
  activation-prep branch). Resolver-only, DARK behind the same `encounter_resolver_enabled` quad-flag.
  (1) **Variety** — `resolve_location_encounter` gains a per-encounter **seed** (`uuid, text`) that
  `process_combat_ticks` fills with `e.id::text`, so two encounters at one location resolve different
  (still fully deterministic) compositions; E3's roll was location-static. (2) **Zero-elite readiness** —
  the resolver **drops the inert `is_elite` roll** (elite has no combat effect until the elite stat-wiring
  slice); no `is_elite` is persisted and the plan carries a single honest marker `elite_policy=disabled_v1`.
  `process_combat_ticks` is re-emitted **byte-identical** except the one seeded resolver-call line, so combat
  is unchanged while the flag is off. The `activate-encounter-resolver` act gained a **zero-elite readiness
  guard** that refused to flip while any active binding reached a fleet member with `elite_chance>0` —
  **removed again by 0272**, which wires elite for real (below).

- **COMBAT-FALLBACK — player basic weapon** (migration `0262_combat_player_fallback_weapon.sql`).
  Not an E-slice, but it sits in this program's blast radius: in spatial combat a player ship with no
  fitted range-weapon module landed `weapons_json='[]'` and dealt **zero damage** while still being shot
  at. 0262 redefines `combat_create_group_encounter` to synthesize ONE fallback basic weapon from the
  ship's `attack_snapshot` at combat-unit creation. `process_combat_ticks` is untouched (it stays a pure
  consumer of `weapons_json`). This is the regression the elite proof guards against re-introducing.

- **ELITE STAT WIRING** (migration `0272_encounter_elite_stat_wiring.sql`; branch
  `slice-elite-stat-wiring`). Resolver-only, DARK, **no new flag** — elite rides the same
  `encounter_resolver_enabled` quad-flag. The elite roll happens **once, at encounter materialization**,
  inside `resolve_location_encounter`: each of a member's rolled units takes one deterministic
  `':enc:elite:'` roll against the authored `elite_chance`, and the elite subset is emitted as its **own
  `units[]` entry** carrying `base_difficulty x encounter_elite_difficulty_multiplier` (default `2`).
  Because `process_combat_ticks` derives every enemy stat of a resolved wave from that single
  `base_difficulty` field, the existing spawn arm materialises both entries through its **identical
  existing insert** — so **`process_combat_ticks` is NOT re-created** and the damage resolver never learns
  what "elite" means. The plan tag becomes `elite_policy=multiplier_v1`; an elite entry carries an
  informational `elite: true` (display/audit only, never a combat input). With `elite_chance = 0` the
  emitted `units[]` is **byte-identical to 0261's**. Two honest v1 tradeoffs: elite is a **coupled buff**
  (`base_difficulty` scales hp *and* attack *and* range *and* speed together — decoupling would require
  re-creating `process_combat_ticks`), and **rewards do not scale** with elites (the reward comes from
  `reward_profile`/`reward_tier`/danger, not `units[]`).

---

## 2. The five stacked PRs and their branches

The program is a **linear stack** — each PR is based on the previous one, ultimately on `main`:

| Slice | PR   | Branch                              | Base branch                          | Migration |
|-------|------|-------------------------------------|--------------------------------------|-----------|
| E0    | #257 | `slice-e0-enemy-content-registry`   | `main`                               | 0257      |
| E1    | #258 | `slice-e1-fleet-encounter-profiles` | `slice-e0-enemy-content-registry`    | 0258      |
| E2    | #259 | `slice-e2-location-encounter-bindings` | `slice-e1-fleet-encounter-profiles` | 0259      |
| E3    | #260 | `slice-e3-encounter-resolver`       | `slice-e2-location-encounter-bindings` | 0260    |
| E4    | #261 | `slice-e4-worldeditor-combat-ui`    | `slice-e3-encounter-resolver`        | — (UI)    |

This activation-prep change (the `scripts/activate-*` + this doc) is stacked on top of E4.

---

## 3. MERGE order

Merge bottom-up so each PR's base has already landed:

```
#257 (E0) → #258 (E1) → #259 (E2) → #260 (E3) → #261 (E4)
```

Each merges into its base; as the base lands on `main`, retarget/merge the next. Do **not** merge a
higher slice before its base — the diffs are cumulative.

---

## 4. DEPLOY order (migrations 0257–0260)

Merging to `main` does **not** deploy the database. Migrations land in prod through the
**approval-gated** `deploy-migrations.yml` workflow (push to `main` under `supabase/migrations/**`,
halted for the required reviewer's approval on the protected `production` GitHub Environment — the
approval, not the PR merge, is the deploy authorization).

Because migrations apply in filename (version) order, deploying is simply landing them in ascending
order:

```
0257  →  0258  →  0259  →  0260
```

Each migration has a **dependency gate** at the top that RAISES if its upstream objects are missing
(E1 aborts without E0's tables, etc.), so an out-of-order push fails loudly rather than half-applying.
All four are seeded `false`, so **deploying changes nothing observable** — combat stays
byte-identical. Deploy is a human gate.

---

## 5. FLAG-FLIP order (the activation scripts — run by the owner at go-live)

After the migrations are deployed, the owner runs the activation scripts **in strict dependency
order**. Each is idempotent, self-gating (asserts its migration's objects exist before flipping),
and carries a commented ROLLBACK block. Run via `node scripts/run-activation.mjs <script>` (the
proven Management-API path on the owner's machine — no psql/jq needed), or the matching
`bash scripts/activate-*.sh run <TOKEN>`, or by pasting into the Supabase Dashboard SQL editor.

| Order | Script                                      | Flag set true                          | Guard |
|-------|---------------------------------------------|----------------------------------------|-------|
| 1     | `scripts/activate-enemy-content-registry.sql` | `enemy_content_registry_enabled` (E0)  | root — asserts 0257 objects |
| 2     | `scripts/activate-encounter-authoring.sql`    | `encounter_authoring_enabled` (E1)     | **refuses unless E0 already true** (dual gate) |
| 3     | `scripts/activate-encounter-binding.sql`      | `encounter_binding_authoring_enabled` (E2) | **refuses unless E0+E1 already true** (tri gate) |
| 4     | `scripts/activate-encounter-resolver.sql`     | `encounter_resolver_enabled` (E3)      | **refuses unless E0+E1+E2 already true** (quad gate) — **combat goes live** |

Convenience one-shot: `scripts/activate-combat-content-all.sql` flips all four in one transaction in
the same order (also flips E3 — combat goes live). Use it only for a single go-live; for a staged
rollout run the four per-flag scripts and stop wherever you like (stopping at E2 leaves only the
authoring surfaces lit and combat unchanged).

Steps 1–3 light **only owner authoring surfaces** (still `is_owner()`-gated) and leave combat
byte-identical. **Step 4 is the behavior-changing flip** — see §6.

---

## 6. E3 byte-identity guarantee

While **any** of the four flags is `false`, the resolver's `v_resolver_engaged` read (once per tick
in `process_combat_ticks`) is false, the resolved spawn arm is **unreachable**, and combat is
**byte-identical** to pre-E3. This is enforced adversarially in the 0260 self-assert block, which
pins:

- `process_combat_ticks` keeps the verbatim flag-off arms (the byte-identity anchors);
- the tick carries exactly **2** `random(` calls (the resolver adds none) and `resolve_location_encounter`
  carries **no** session-RNG token (the determinism law — deterministic `hashtextextended`/`:enc:` roll;
  **E5/0261** re-proves this after folding the per-encounter seed `e.id::text` into every salt and pinning
  the tick's one changed line, `resolve_location_encounter(e.location_id, e.id::text)`);
- `resolve_encounter_reward_inputs` is **algebraically** the legacy reward formula, and is NULL-safe
  on a missing `multiplier_ref`;
- no non-resolver path (`combat_create_group_encounter`, report/reward/base paths) references the
  resolver, `resolved_plan_json`, or `encounter_runtime_state`.

**Rollback of the behavior change is a single set-to-false** of `encounter_resolver_enabled`: the
resolved branch goes inert and combat is byte-identical again on the next tick. Authored content and
`encounter_runtime_state` rows persist untouched (the arm that reads them is unreachable while off).

---

## 7. Deferred items (built-but-not-wired / intentionally out of scope)

- **Composition variety** — ~~E3's resolver salts its weighted pick location-static~~ **DONE in E5
  (0261)**: `resolve_location_encounter` folds a per-encounter seed (`e.id::text`) into every salt, so
  encounters at one location vary (still fully deterministic). Time-varying variety remains out of scope.
- **ELITE stat wiring** — ~~deferred~~ **BUILT AND MERGED in `0272`** (`encounter_elite_stat_wiring`,
  PR #284, `b11b3bd`) — **but NOT DEPLOYED.** See the deploy-state box below.
  `enemy_fleet_template_members.elite_chance` is rolled once, at materialization, and amplifies the
  plan's `base_difficulty` for the elite subset. The `activate-encounter-resolver` /
  `activate-combat-content-all` elite **refusal is removed** (now the informational
  `ACTE3_PASS_ELITE_WIRED` notice; a new `ELITE-WIRING FAIL` raise fires only if the *deployed* resolver
  lacks the `':enc:elite:'` salt, i.e. if someone tries to activate before `0272` is deployed).
  Honest note: that old refusal **was not blocking anything today** — production has **0** members with
  `elite_chance > 0`.

  > ### ⚠ DEPLOY STATE — `0272` is MERGED but NOT DEPLOYED
  > `main` carries `0272`. **Production migration head is `0271`.** The `Deploy Supabase migrations` run
  > for the `0272` merge (**`29979341800`**) is **`waiting` at the `production` environment approval
  > gate** — deployment is **deferred, pending owner approval**. **Nothing about elite is live.**

  **Two honest v1 tradeoffs (still deferred, by design):**
  1. **Elite is a COUPLED buff.** `base_difficulty` scales **hp AND attack AND range AND speed**
     together (`0260:658-665`), so a v1 elite is uniformly stronger, never *differently* shaped.
     *Decoupled* elite stats (hp-only or attack-only) would require re-creating `process_combat_ticks`,
     which `0272` deliberately does not do (only `resolve_location_encounter` is `create or replace`d).
  2. **Rewards do NOT scale with elites.** The resolved reward is derived from the reward profile /
     `reward_tier` / danger (`0261:818`), **not** from `units[]`. **An elite wave is harder for the same
     loot** until a reward-adapter slice lands. Decide this before flipping
     `encounter_resolver_enabled` on a binding whose fleet carries `elite_chance > 0`.
- **`stat_overrides` is a DEAD authored field** — `enemy_archetypes.stat_overrides` (`0257:120`) is
  validated on write, carried through the resolver into the plan JSON (`0260:279`, `0260:320`;
  `0272:247`, `0272:304`) — and then **read by nothing at spawn**. The spawn arm computes every enemy
  stat from `base_difficulty` alone (`0260:658-665`). Authoring a `stat_overrides` object today has
  **zero runtime effect**. Either wire it (which means touching `process_combat_ticks`) or stop offering
  it in the editor; do not assume it works.
- **Deactivation-trigger typed envelope** — the cross-slice deactivation guards (E1/E2 triggers on
  E0/E1 tables) RAISE a raw Postgres exception rather than returning the typed `{ok:false, error, details[]}`
  envelope the RPCs use. Fine as defense-in-depth; a typed surface is deferred.
- **`active_count` is a CUMULATIVE SPAWN COUNTER, not a live gauge** — `encounter_runtime_state.active_count`
  is incremented by the resolved spawn arm and **never decremented**, and it is read by no cap or
  observability surface. **The live-encounter cap authority derives from `combat_encounters`, not from
  this column.** Document it as a cumulative spawn counter; **do not build on it** as if it were a count
  of currently-active encounters.

---

## 7a. Encounter-binding audit (read live from production, 2026-07-23)

Two bindings exist. **Both are inactive**, and `encounter_resolver_enabled` is `false`.

| Binding | Location | Encounter profile | Verdict |
|---|---|---|---|
| **`2f7bcf88`** | Reaver | **`canary_encounter`** — difficulty 1, cap 1, **cooldown 30 s** | **SELECTED as the canary.** Complete chain: template `canary_fleet` → archetype `canary_pirate` (`base_difficulty = 1`, `elite_chance = 0`) → reward `canary_reward` (metal-only, base 7). Activation-ready. |
| `2d491cde` | Snare | `pirate_basic` | **REJECTED as first canary** — `cooldown_seconds = 0`, i.e. **no spawn throttle at all**. |

**This is not a clean slate.** `encounter_runtime_state` shows the canary chain **already ran**:
`last_spawn_at = 2026-07-22T06:03:27Z`, `active_count = 2` — about four minutes before
`encounter_resolver_enabled` was set `false` at `06:07:02Z`. Expect pre-existing rows and a non-zero
`active_count` on the next activation; per §7 above, `active_count` is cumulative, so a non-zero value
proves nothing about what is live.

**E0–E2 authoring flags are LIVE in production:** `enemy_content_registry_enabled`,
`encounter_authoring_enabled` and `encounter_binding_authoring_enabled` are all `true`. Only
`encounter_resolver_enabled` (E3, the behaviour-changing flag) remains `false`. The canary decision
packet is a forthcoming `docs/ENCOUNTER_CANARY_PACKET.md`.

---

## 8. What this program does NOT do

No `home base`, no client write-grant widening (all table writes go through `SECURITY DEFINER`
owner-gated RPCs; client INSERT/UPDATE/DELETE are explicitly revoked), no change to the existing
pirate combat scaling (`locations.base_difficulty` + `game_config reward_*` tunables) while the flags
are off, and no activation performed by CI or at deploy time. Activation is exclusively the owner's
manual, recorded go decision via the `scripts/activate-*` acts.
