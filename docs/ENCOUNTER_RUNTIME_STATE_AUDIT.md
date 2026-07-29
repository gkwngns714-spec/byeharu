# `encounter_runtime_state` — authority audit + residual-row classification

**Date:** 2026-07-23 · **Repo head audited:** `main` @ `8270142` · **Production migration head at audit time:** `0271`

> **Update 2026-07-23 (post-deploy).** **Production migration head is now `0272`** — the DARK elite
> stat-wiring migration deployed successfully (`docs/DEV_LOG.md` §9). This audit's conclusions are
> **unaffected**: §6 already establishes that `0272` contains **no DML** against
> `encounter_runtime_state`, and the before/after verifier confirmed every `must_not_change.*` value —
> including the residual runtime-state row — **byte-identical** across the deploy. The classification
> stays **`HISTORICAL-HARMLESS`**, and it still rests on the **one RLS-blocked read the owner must
> run** (§5). That read is now packaged copy-paste-ready as
> **`docs/ENCOUNTER_CANARY_PACKET.md` §3A**, which returns the scalar `cap_consuming_encounter_count`.
**Posture of this document:** READ-ONLY investigation. Nothing here was written to production. No cleanup
script accompanies it (see [§6](#6-classification)) and none is permitted at this classification.

---

## 1. What the table is

Created by migration `0260` (E3, the encounter runtime resolver):

```
supabase/migrations/20260618000260_encounter_runtime_resolver.sql:88-104
  create table if not exists public.encounter_runtime_state (
    location_id          uuid …,
    encounter_profile_id uuid …,
    last_spawn_at        timestamptz …,
    active_count         integer not null default 0,
    primary key (location_id, encounter_profile_id)
  );
  … RLS on; select granted to anon, authenticated;
    insert/update/delete REVOKED from anon, authenticated.
```

Its own table comment (`…0260…:96-99`) calls it "the per (location, profile) cooldown anchor +
`active_count`", "Written ONLY by `process_combat_ticks`' resolved spawn arm".

**Three files in the entire repository reference the table.** Verified:

```
$ grep -rln "encounter_runtime_state" supabase/migrations src
supabase/migrations/20260618000260_encounter_runtime_resolver.sql
supabase/migrations/20260618000261_encounter_variety_zero_elite.sql
supabase/migrations/20260618000272_encounter_elite_stat_wiring.sql
```

No frontend code, no other migration, no edge function, no scheduled job.

---

## 2. Writer / reader matrix (from the TRUE current head)

Current function heads: `process_combat_ticks()` is defined by **0261** (`…0261…:268`); it is *not*
re-created by 0272 — 0272's own header says so in as many words and defines exactly one function
(`…0272…:90`, `resolve_location_encounter(uuid,text)`).

| # | Behaviour | Authority at head | Verdict |
|---|---|---|---|
| 1 | **Creates** a runtime-state row | `process_combat_ticks` resolved-spawn arm — `insert … on conflict do update`, `…0261…:591-594` (was `…0260…:688-691`) | **EXISTS.** Only inside `if v_fresh_resolve then` (`…0261…:588`), i.e. only at an encounter's FIRST resolution. Wave 2+ reuses the stored plan and re-upserts nothing. |
| 2 | **Increments** `active_count` | the same upsert's `do update set … active_count = encounter_runtime_state.active_count + 1` (`…0261…:594`) | **EXISTS.** `+1` per *fresh resolution*, not per live encounter. |
| 3 | **Decrements** `active_count` | — | **DOES NOT EXIST ANYWHERE.** `grep -rn "active_count" --include=*.sql --include=*.ts --include=*.tsx --include=*.mjs .` returns writes at only two lines in the whole repo, both the `+1` upsert above. |
| 4 | **Updates** `last_spawn_at` | the same upsert (`…0261…:591,594`), set to `now()` on both insert and conflict paths | **EXISTS.** Same single site; anchors on the FIRST spawn of an encounter. |
| 5 | Reads it for the **cap** | — | **DOES NOT EXIST.** The cap is *derived*: `select count(*) from combat_encounters ce where ce.location_id = … and ce.status in ('active','retreating') and ce.resolved_plan_json->>'encounter_profile_id' = …` then `if v_active_cnt >= v_cap then return null` — `…0261…:126-134` (step (e)). `active_count` is never consulted. |
| 6 | Reads it for the **cooldown** | `resolve_location_encounter` step (e), `…0261…:135-139`; identical probe re-emitted by 0272 at `…0272…:176-181`; original `…0260…:230-236` | **EXISTS — the ONLY reader in the codebase.** `if v_cooldown > 0 and exists (select 1 … where now() - s.last_spawn_at < make_interval(secs => v_cooldown)) then return null`. It reads **`last_spawn_at` only**; it does not select `active_count`. |
| 7 | **Cleans it up** after an encounter completes | — | **DOES NOT EXIST.** No `delete`, no reset, no zeroing anywhere. |
| 8 | Reacts to **binding deactivation** | — | **DOES NOT EXIST.** Deactivating a binding leaves the row untouched. |
| 9 | Reacts to **resolver disablement** | — | **DOES NOT EXIST.** Flipping `encounter_resolver_enabled` false leaves the row untouched. |
| 10 | Handles **destroyed / retreated / expired / orphaned** encounters | — | **DOES NOT EXIST** for this table. Encounter lifecycle is settled entirely in `combat_encounters.status`; the runtime-state row is never revisited. |
| 11 | Client write path | none — `revoke insert, update, delete … from anon, authenticated` (`…0260…:104`), asserted at `…0260…:1209-1215` | **CLOSED.** The row can only ever move via `process_combat_ticks` (SECURITY DEFINER). |

**Reader set: exactly one** (row 6, the cooldown probe, reading only `last_spawn_at`).
**Writer set: exactly one** (rows 1/2/4 — a single upsert statement, reachable only from the
resolved-spawn arm of the combat tick, itself quad-flag gated behind `encounter_resolver_enabled`).

### 2.1 The prior finding — CONFIRMED, with one correction

> *"`active_count` appears to only ever increment and never decrement, and the cap authority appears to
> be derived from `combat_encounters` rather than from `active_count` (`…0261…:124-133`)."*

**Both halves are correct.** Correction to the citation only: in `main` @ `8270142` the derived-cap
`select` occupies `…0261…:126-131` and its enforcement `if` is `…0261…:132-134`; lines 124-125 are the
step-(e) comment. Nothing about the substance changes.

Two consequences worth stating plainly:

* `active_count` is **dead weight as a runtime authority** — nothing reads it. It is a *cumulative
  lifetime spawn counter* for the pair, and it is honest only under that reading. Interpreting it as
  "how many encounters are live right now" is wrong at every value above its first.
* Because nothing reads it, an "inflated" `active_count` **cannot block anything**. The only field of
  this table that can ever change behaviour is `last_spawn_at`.

---

## 3. The residual production row

Read live from production over PostgREST with the anon key on 2026-07-23 (`encounter_runtime_state` is
public-select by design, `…0260…:102-103`):

```
GET /rest/v1/encounter_runtime_state?select=*
[{"location_id":"75baf5d7-6b06-4567-84c9-de97938aa251",
  "encounter_profile_id":"4d8bd4ee-4b61-454f-b0bc-fbf058ee4dd9",
  "last_spawn_at":"2026-07-22T06:03:27.318703+00:00",
  "active_count":2}]
```

Exactly one row: Reaver × `canary_encounter`. Its dependencies, also read live:

| Dependency | Live value | Source |
|---|---|---|
| location `75baf5d7-…` | `Reaver`, `status=active`, `activity_type=hunt_pirates`, `base_difficulty=15`, `reward_tier=2` | `locations` |
| profile `4d8bd4ee-…` | `canary_encounter`, `active=true`, `revision=1`, **`cooldown_seconds=30`**, `active_encounter_cap=1` | `encounter_profiles` |
| binding for the pair | `2f7bcf88-…`, **`active=false`**, `revision=2`, `updated_at=2026-07-22T06:11:30.832Z` | `location_encounter_bindings` |
| other binding | `2d491cde-…`, `active=false`, `revision=2` | `location_encounter_bindings` |
| `encounter_resolver_enabled` | **`false`**, `updated_at=2026-07-22T06:07:02.588Z` | `game_config` |

Timeline: last spawn **06:03:27Z** → resolver disabled **06:07:02Z** (+3m35s) → binding deactivated
**06:11:30Z** (+8m03s). The row is a fossil of that ~8-minute live window.

---

## 4. Can this row affect anything? (mechanism-by-mechanism)

1. **Cap** — no. `active_count` is not the cap authority (matrix row 5). The cap is derived from
   `combat_encounters` at resolve time.
2. **Cooldown** — this is the *only* mechanism, and it has lapsed. `cooldown_seconds = 30`; measured
   elapsed since `last_spawn_at` at audit time was **84,076 s (≈ 23.4 h)**, i.e. 2,802× the cooldown.
   `now() - last_spawn_at < interval '30 s'` is false and will stay false forever.
3. **Reachability** — no. The single reader is inside `resolve_location_encounter`, which returns early
   unless all four flags are true (`encounter_resolver_enabled` is `false`) *and* an active binding
   exists for the location (both bindings are `active=false`). The row is not even reached today.
4. **Growth / drift** — no. Nothing writes it while the resolver is dark. On the next fresh resolution
   the same upsert overwrites `last_spawn_at = now()` and sets `active_count = 3`; the row never
   disappears and never needs to.
5. **Schema / deployment** — no. Deploying 0272 cannot touch it: 0272 re-creates exactly one function,
   whose only interaction with the table is the read at `…0272…:176-181`. There is no DML against the
   table anywhere in 0272.

---

## 5. What this audit CANNOT settle, and the exact read that settles it

`active_count = 2` is **not** evidence that two encounters are live — see matrix row 3. But the audit
must not therefore assume the opposite either. The genuinely open question is a `combat_encounters`
question, not a runtime-state question:

> *Are there still `combat_encounters` rows at Reaver, tagged with the `canary_encounter` profile, in
> status `active` or `retreating`?*

`combat_encounters` is RLS-blocked to the anon key (a select returns `[]`, which must **not** be read as
"none exist"), and this machine holds no service-role key and no access token. **The owner must run,
as `service_role` (Supabase SQL editor or `psql`) — both are SELECTs, neither writes:**

> The fuller, copy-paste-ready version of exactly this read — with the cap predicate quoted from the
> **deployed** resolver and a final `cap_consuming_encounter_count` scalar — is
> **`docs/ENCOUNTER_CANARY_PACKET.md` §3A**. Either settles the question; §3A also names the chain.

```sql
-- (A) the row that settles the classification
select ce.id, ce.status, ce.created_at, ce.updated_at, ce.player_id,
       ce.resolved_plan_json->>'encounter_profile_id' as profile_id
  from public.combat_encounters ce
 where ce.location_id = '75baf5d7-6b06-4567-84c9-de97938aa251'
   and ce.resolved_plan_json->>'encounter_profile_id' = '4d8bd4ee-4b61-454f-b0bc-fbf058ee4dd9'
 order by ce.created_at;

-- (B) the same question world-wide, so no OTHER pair carries live resolved state
select ce.location_id,
       ce.resolved_plan_json->>'encounter_profile_id' as profile_id,
       ce.status, count(*)
  from public.combat_encounters ce
 where ce.resolved_plan_json is not null
 group by 1,2,3 order by 1,2,3;
```

Reading the result:

* **(A) returns 0 rows in `active`/`retreating`** → the classification below stands unchanged and the
  derived cap at Reaver is clear.
* **(A) returns ≥ 1 row in `active`/`retreating`** → the *runtime-state row* is still harmless, but the
  **derived cap is already consumed** (`active_encounter_cap = 1`), so the resolver would return `null`
  and a canary would silently never fire. That is a `combat_encounters` defect, to be handled through
  the combat-encounter lifecycle — **not** by editing `encounter_runtime_state`.

The readiness verifier already tests exactly this at `CH23_CAP_VIOLATION`
(`scripts/encounter-canary-readiness.sql:676-686` — corrected 2026-07-23; the previously cited
`:594-604` is the CH22 cooldown block, not CH23) when run with a role that can read the table, and
this PR additionally makes it fail closed on *any* live encounter at the canary location (CH26/CH27,
[§7](#7-readiness-verifier-gaps-closed)).

---

## 6. Classification

## `HISTORICAL-HARMLESS`

**Evidence, in order of force:**

1. **The only reader reads only `last_spawn_at`** (matrix row 6). `active_count` — the field that looks
   alarming — is read by nothing at all (matrix rows 3, 5). Two independent greps confirm it: only three
   files reference the table, and only two lines in the repo write `active_count`, both the same `+1`.
2. **The single load-bearing effect has lapsed by ~2,800×.** Cooldown 30 s; elapsed ≈ 23.4 h at audit
   time and monotonically increasing while the resolver is dark.
3. **It is unreachable today.** Resolver flag `false` (06:07:02Z) and both bindings `active=false` —
   `resolve_location_encounter` returns before the cooldown probe.
4. **It cannot grow, drift, or corrupt.** One writer, gated behind the dark resolver; client roles hold
   no write grant (`…0260…:104`, asserted `…0260…:1209-1215`).
5. **Deploying 0272 cannot move it** — 0272 contains no DML against the table.

**Why not the other three:**

* not **`VALID`** — it does not describe present reality: `active_count=2` describes a lifetime spawn
  count from a window that closed on 2026-07-22, not live state.
* not **`SELF-HEALING`** — nothing heals it. There is no cleanup, no decrement, no reaction to binding
  deactivation or resolver disablement (matrix rows 3, 7, 8, 9). The row persists indefinitely. Its
  *harmlessness* comes from cooldown expiry, not from a repair path — those are different claims and
  only the second would justify the `SELF-HEALING` label.
* not **`BLOCKING-STALE`** — the one mechanism by which a runtime-state row can block (cooldown
  suppression of the first canary spawn) is inert, and the field that would suggest blocking
  (`active_count`) is not a cap authority.

**Consequence: no cleanup tooling is written, and none is authorised.** Deleting or resetting this row
would change nothing observable, and would require a production write against a table whose entire
design intent is that only `process_combat_ticks` writes it. Leaving it is the correct action. Should
read (A) later show live resolved encounters, the correct remedy is still not a runtime-state edit.

---

## 7. Readiness-verifier gaps closed

The audit did identify real gaps in `scripts/encounter-canary-readiness.sql`, all patched in this PR
without adding any write:

| Gap | Before | After |
|---|---|---|
| runtime state referencing a **missing** binding (a true orphan) | not checked at all | **CH24** BLOCK — a runtime row whose `(location, profile)` pair has no `location_encounter_bindings` row. An *inactive* binding is the intended pre-activation state and is deliberately NOT flagged. |
| **another** pair carrying live resolved state | `CH22_RUNTIME_STATE_OTHER` WARN only | **CH24** BLOCK when another pair has live tagged `combat_encounters`; still WARN when it is merely historical. |
| **unresolved encounters** at the canary location | `CH23` reported `all_live_at_location` as INFO | **CH26** BLOCK — any `active`/`retreating` encounter at the canary location, tagged or not. |
| live **resolved** encounter anywhere while the resolver is dark | not checked | **CH27** BLOCK. |
| migration head **below 0272** | `CH01` blocked only below `0261`; `CH18` blocked only if elite content existed — vacuous at the live posture (0 of 2 members carry `elite_chance > 0`) | **CH01** BLOCK when head < `canary.elite_migration` (default `20260618000272`). *Satisfied in production since 2026-07-23: head is `0272`.* |
| canary pair carrying **unexplained** runtime state | `CH22` INFO always | **CH22** BLOCK when `active_count` / `last_spawn_at` differ from the pinned expectation (`canary.expect_runtime_active_count` = 2, `canary.expect_runtime_last_spawn_at`). The *known* residual therefore still passes — intentionally retained harmless state is not rejected. |

Unchanged and deliberately so: `active_count` remains INFO-and-pin only, never a cap input; the file
still opens `begin transaction read only` and gains **no** write of any kind.
