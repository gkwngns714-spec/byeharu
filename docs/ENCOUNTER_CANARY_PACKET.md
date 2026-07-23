# Encounter Canary — activation packet

Everything the owner needs to decide whether, and how, to take the E3/E5 encounter resolver live on
**one** audited chain — plus the read-only tooling that proves the chain is sound *before* anything is
written.

> **Nothing in this packet has been executed against production.** The verifier is read-only, the proof
> runs only on a disposable CI database, and the two activation scripts are owner-gated and unrun.

---

## 1. The chosen chain — Binding B

| Layer | Id | Key / name | Active | Rev | Notes |
|---|---|---|---|---|---|
| Binding | `2f7bcf88-d810-47b4-8e04-748655688b55` | Reaver ↔ canary_encounter | **false** | 2 | weight 1 |
| Location | `75baf5d7-6b06-4567-84c9-de97938aa251` | **Reaver** | status `active` | — | `activity_type=hunt_pirates`, `base_difficulty` 15, `reward_tier` 2, pos (−135, 120), `min_power_required` 0 |
| Encounter profile | `4d8bd4ee-4b61-454f-b0bc-fbf058ee4dd9` | `canary_encounter` | true | 1 | difficulty 1, `active_encounter_cap` **1**, `cooldown_seconds` **30**, `reward_override_id` null |
| Profile member | `7ec49abe-3b70-46ae-8e89-a748b23c7129` | → canary_fleet | — | — | weight 1 |
| Fleet template | `e8be2946-7509-4751-a738-a01bcf69c67c` | `canary_fleet` | true | 1 | |
| Template member | `16172dce-dc82-41eb-a97d-ae3f336f6755` | → canary_pirate | — | — | `min_count` 1, `max_count` 1, weight 1, **`elite_chance` 0** |
| Archetype | `b7f4a217-939e-4532-ba08-72f3dabba926` | `canary_pirate` | true | **2** | `unit_type_id` `pirate_synthetic`, `behavior_key` `spatial_synthetic`, `base_difficulty` **1**, `stat_overrides` `{}` |
| Reward profile | `b742b762-f902-48c8-bf98-a3791559b497` | `canary_reward` | true | 1 | metal only — base **7**, `danger_coeff` 0.25, `multiplier_ref` `reward_multiplier` |

Flag posture read live (2026-07-23): `encounter_resolver_enabled=false`;
`enemy_content_registry_enabled` / `encounter_authoring_enabled` /
`encounter_binding_authoring_enabled` all **true** (E0–E2 authoring is live);
`spatial_combat_enabled=true`; `pirate_intercept_enabled=true`. Migration head **0271**.

> **Correction to the working notes:** the `canary_pirate` archetype is at **revision 2**, not 1. The
> readiness verifier's default `canary.expect_archetype_rev` is therefore `2`. Everything else in the
> table matches the notes.

---

## 2. Why Binding A was rejected

Binding A (`2d491cde-e6fa-4087-8e80-3029522731cd`, also inactive) points at **Snare**
(`4f668def-…`) → profile `pirate_basic` (`e54dd1de-…`) → template `pirate_light_solo`
(`ddf3fc29-…`) → archetype `pirate_light` (`37e4ab29-…`, `base_difficulty` **10**) → reward
`pirate_standard` (`7fc2ac96-…`, metal base 10).

**`pirate_basic.cooldown_seconds = 0`.** The resolver only consults `encounter_runtime_state` when
`cooldown_seconds > 0` (0261, gate (e)). With cooldown 0 there is **no spawn brake at all**: as soon as
a cleared encounter frees the derived cap, the very next combat tick can resolve a fresh encounter, over
and over. A canary exists to produce *one* observable, bounded outcome — an unthrottled chain cannot do
that. Its archetype is also 10× harder (`base_difficulty` 10 vs 1) and its reward is indistinguishable
from the legacy formula (metal base 10 == `reward_metal_base` 10), so a successful spawn could not even
be told apart from the pre-canary behaviour.

Binding B is throttled (30 s), capped (1), minimal (`base_difficulty` 1), and its reward (base 7) is
**distinguishable** from the legacy base-10 formula — which is what makes the canary readable.

---

## 3. The residual runtime-state finding — do not assume a clean slate

`encounter_runtime_state` already holds **one row**:

```
location_id          = 75baf5d7-…   (Reaver)
encounter_profile_id = 4d8bd4ee-…   (canary_encounter)
last_spawn_at        = 2026-07-22T06:03:27.318703+00:00
active_count         = 2
```

This chain was briefly live on 2026-07-22 before `encounter_resolver_enabled` was set back to false at
06:07:02Z.

**`active_count = 2` does NOT mean two live encounters.** `active_count` is only ever *incremented*
(0261, resolved-spawn arm: `on conflict … do update set … active_count = active_count + 1`) and is never
decremented when an encounter ends. It is a **cumulative spawn counter**. The **cap authority** is
derived at resolve time by counting rows in `combat_encounters` at the location with status
`active`/`retreating` whose `resolved_plan_json->>'encounter_profile_id'` equals the profile.

What *is* load-bearing on that row is **`last_spawn_at`**: it is the cooldown anchor. If it were newer
than `cooldown_seconds` ago, the first canary spawn after activation would be silently suppressed. Both
the readiness verifier (`CH22_COOLDOWN_VIOLATION`) and Script B refuse in that case and print the
remaining wait. Given `last_spawn_at` is a day old and the cooldown is 30 s, the anchor is clear.

---

## 4. The read-only preflight

```bash
DB_URL="postgres://…prod…" ./scripts/encounter-canary-readiness.sh
```

`scripts/encounter-canary-readiness.sql` opens `begin transaction read only` and ends with `rollback`.
It contains **no** `INSERT` / `UPDATE` / `DELETE` / DDL / `set_game_config` — PostgreSQL itself would
reject one. It is safe to run against production, and CI grep-asserts that posture on every push.

It **fails closed** on every one of:

| Code | Blocks when |
|---|---|
| `CH01_MIGRATION_HEAD` | head < `20260618000261` (E3/E5 resolver not deployed) |
| `CH25_FUNCTIONS_MISSING` / `CH25_TABLES_MISSING` / `CH25_TICK_BODY` | resolver surface incomplete, or the deployed `process_combat_ticks` lacks the E5 seeded resolved branch |
| `CH02_RESOLVER_ALREADY_ON` | `encounter_resolver_enabled` is already true |
| `CH03_QUAD_PREREQ_OFF` | any of E0/E1/E2 is false (the flip would be inert) |
| `CH04_BINDING_MISSING` / `CH04_BINDING_AMBIGUOUS` | the target binding cannot be resolved |
| `CH05_BINDING_ALREADY_ACTIVE` | the binding is already active |
| `CH06_BINDING_REVISION` | binding revision ≠ expected (the chain changed since audit) |
| `CH07_OTHER_ACTIVE_BINDING` | **any** additional active binding anywhere — one line per offending row |
| `CH08_LOCATION_MISSING` / `CH09_LOCATION_INACTIVE` | the bound location is missing or not `active` |
| `CH11_PROFILE_MISSING` / `_INACTIVE` / `_REVISION` | the encounter profile |
| `CH12_COOLDOWN_VIOLATION` | `cooldown_seconds` below the minimum (default 1 — i.e. cooldown 0 is rejected) |
| `CH13_CAP_VIOLATION` | `active_encounter_cap` above the maximum (default 1) |
| `CH14_PROFILE_MEMBERSHIP_EMPTY` | the profile has no members |
| `CH15_TEMPLATE_MISSING` / `_INACTIVE` / `_REVISION` | the fleet template |
| `CH16_TEMPLATE_MEMBERSHIP_EMPTY` / `CH16_MEMBER_COUNTS` / `CH16_FLEET_CAP_VIOLATION` | empty template membership, unusable count range, or a max-count sum above `enemy_synthetic_max_units` (it would be silently clamped) |
| `CH17_ARCHETYPE_MISSING` / `_INACTIVE` / `_REVISION` / `_UNIT_TYPE` / `_DIFFICULTY` | invalid or inactive archetype |
| `CH18_ELITE_WITHOUT_0272` | a reachable member has `elite_chance > 0` while migration `20260618000272` is **not** deployed |
| `CH19_REWARD_CONFLICT` / `_MISSING` / `_INVALID` / `_INACTIVE` / `_REVISION` | reward profile cannot be resolved, or is missing/inactive |
| `CH20_REWARD_NO_METAL` / `_UNSUPPORTED_RESOURCE` / `_BASE` / `_DANGER_COEFF` / `_MULTIPLIER_REF` | unsupported reward resource type or malformed grant (`resolve_encounter_reward_inputs` honours **metal only**) |
| `CH22_COOLDOWN_VIOLATION` | the residual `last_spawn_at` is inside the cooldown window |
| `CH23_CAP_VIOLATION` | the derived cap is already reached at the location |

Informational findings also report the location/ambush posture (`CH10`), the residual runtime state
(`CH22`), the derived cap (`CH23`), and the **expected wave-1 outcome** (`CH21`). Every blocking row is
emitted — the run does not stop at the first — and the script ends with a `RAISE` (non-zero exit) if the
blocker count is above zero.

Output markers: `CANARY_FINDING [BLOCK|WARN|INFO] <code> …`, then either `CANARY_READY_PASS` or
`CANARY_READY_BLOCKED n=<N>`.

Overrides without editing the file (connection GUCs, so the SQL also pastes into the Supabase editor):
`CANARY_BINDING_ID`, `CANARY_PROFILE_KEY`, `CANARY_EXPECT_*_REV`, `CANARY_MIN_COOLDOWN_SECONDS`,
`CANARY_MAX_ACTIVE_CAP`, `CANARY_ELITE_MIGRATION`.

---

## 5. The disposable exact-chain proof

`.github/workflows/encounter-canary-proof.yml` runs `supabase start` (whole-migration-chain apply, so
every in-migration self-assert of 0257→0271 runs against real Postgres), then:

1. **Readiness selftest** — `./scripts/encounter-canary-readiness.sh --expect-blocked` against a
   database with no canary content. It MUST report `CANARY_READY_BLOCKED` / `CH04_BINDING_MISSING`.
   This proves the verifier fails closed instead of vacuously passing.
2. **Read-only posture assertion** — comments are stripped and the file is grepped for any write verb.
3. **`scripts/encounter-canary-proof.sql`** — reproduces the exact chain through the real owner RPCs
   (`reward_profile_create` → `enemy_archetype_create` → `enemy_fleet_template_create` →
   `encounter_profile_create` → `location_encounter_binding_create` + `…_set_active(false)`, giving the
   same `active=false, revision=2` posture as production) at a hunt location normalised to Reaver's
   shape (`base_difficulty` 15, `reward_tier` 2), with every other binding deactivated. Five separate
   players each drive one scenario end to end through `send_ship_group_hunt` →
   `movement_settle_arrival` → `process_combat_ticks`.

| Marker | Proves |
|---|---|
| `ECP_PASS_INACTIVE_BINDING_NO_SPAWN` | the inactive binding causes no runtime encounter |
| `ECP_PASS_RESOLVER_OFF_NO_SPAWN` | resolver off causes no runtime encounter |
| `ECP_PASS_BINDING_ONLY_NO_SPAWN` | activating **only** the binding while the resolver is off causes no runtime encounter |
| `ECP_PASS_ACTIVATED_SPAWN` | resolver on + valid active binding produces the expected encounter (tagged, cap 1, cooldown 30) |
| `ECP_PASS_ONE_RUNTIME_ROW` | exactly **one** `encounter_runtime_state` row is created, `active_count = 1` |
| `ECP_PASS_COOLDOWN_BLOCKS` | the cooldown prevents duplicate spawning, and releases once elapsed |
| `ECP_PASS_FLEET_COMPOSITION` | the wave is exactly 1 `canary_pirate`, hp derived from the archetype (not the location), at the location centre |
| `ECP_PASS_REWARD_MATCHES` | metal-only, base 7 — literally 18 at `reward_tier` 2 / danger 1, provably distinct from the legacy 25 |
| `ECP_PASS_NON_ELITE` | `elite_policy=disabled_v1`, no `is_elite` key, no `is_elite` column |
| `ECP_PASS_BINDING_DISABLED_STOPS` | disabling the binding stops future spawns (resolver still on) |
| `ECP_PASS_RESOLVER_DISABLED_STOPS` | disabling the resolver stops all resolver behaviour (binding still on) |
| `ECP_PASS_NO_NEW_ACTIVE_CONTENT` | at end of transaction nothing authored is left active |
| `ECP_PASS_ROLLBACK_CLEAN` | asserted **after** the rollback, from a fresh connection: no canary content, empty runtime ledger, resolver still false, no audit rows |

The proof SQL is self-rolling-back (`begin; … rollback;`) — every flag flip lives inside that
transaction. The job carries **no `environment:` key**, so it cannot reach production secrets.

---

## 6. Activation — two separate owner approvals

**These scripts have not been run. An agent must never run them.**

### Script A — `scripts/activate-canary-binding.sql`

Sets `active = true` on exactly one binding row. Refuses unless `encounter_resolver_enabled` is false,
refuses if any other binding is active, re-verifies the whole chain first, prints BEFORE/AFTER
snapshots. Safe on its own: the resolver is quad-gated, so an active binding with the resolver dark is
inert (proved by `ECP_PASS_BINDING_ONLY_NO_SPAWN`).

**Rollback (in the file, commented):**
```sql
begin;
update public.location_encounter_bindings
   set active = false, revision = revision + 1, updated_at = now()
 where id = '2f7bcf88-d810-47b4-8e04-748655688b55'::uuid and active is true;
commit;
```

### Script B — `scripts/activate-encounter-resolver-canary.sql`

Flips `encounter_resolver_enabled` to true. Refuses unless **exactly one** binding is active **and it is
the canary**; refuses if any active binding reaches `elite_chance > 0` while migration
`20260618000272` is undeployed; refuses if the residual cooldown anchor or the derived cap would block
the first spawn. Prints the expected combat result before writing.

**Rollback (in the file, commented):**
```sql
begin;
select public.set_game_config('encounter_resolver_enabled', 'false'::jsonb);
commit;
```

Roll back **B first, then A**. Neither rollback destroys content; the resolved branch simply becomes
unreachable on the next tick and combat returns to byte-identical.

---

## 7. Expected combat result

At Reaver, wave 1 (`danger = 1 + waves_cleared = 1`), with the live tunables
(`enemy_hp_base` 14, `enemy_hp_danger_scale` 0.6, `enemy_attack_base` 1.0,
`reward_metal_base` 10, `reward_danger_scale` 0.25, `reward_multiplier` 1.0,
`combat_damage_variance_pct` 0.10):

| | Canary (resolved) | Legacy synthetic (today) |
|---|---|---|
| enemy units | **1 ×** `pirate_synthetic` | 1 × `pirate_synthetic` |
| scaling base | archetype `base_difficulty` **1** | location `base_difficulty` **15** |
| enemy hp | `1 × 14 × (1 + 1×0.6)` = **22.4** (± variance) | `15 × 14 × 1.6` = **336** |
| enemy attack | `1 × 1.0 × (1 + 1×0.25)` = **1.25** | **18.75** |
| metal on clear | `round(7 × 2 × 1.25 × 1.0)` = **18** | `round(10 × 2 × 1.25 × 1.0)` = **25** |
| cap / cooldown | 1 concurrent / 30 s | n/a |

The canary is roughly **15× weaker** than what Reaver spawns today, and its reward (18) is
unambiguously distinguishable from the legacy value (25) — that is the whole point of the reward base
being 7 rather than 10.

**How to confirm a canary encounter fired:** `combat_encounters.resolved_plan_json` is non-NULL and
`resolved_plan_json->>'encounter_profile_id' = '4d8bd4ee-4b61-454f-b0bc-fbf058ee4dd9'`, and
`combat_units` holds exactly one enemy row for that encounter.

---

## 8. ⚠ Travel to Reaver can itself trigger an ambush — use an expendable fleet

Reaver has `activity_type = hunt_pirates`, which is the `send_ship_group_hunt` entry point. But
**`pirate_intercept_enabled = true` and `spatial_combat_enabled = true` in production**, so the *journey*
to Reaver can start an en-route interception that has nothing whatsoever to do with the canary chain —
an ordinary pirate ambush at full location difficulty, not the 22.4-hp canary.

**The owner must send an expendable fleet.** A canary must never be run with an asset that cannot be
lost. (A previous canary destroyed the owner's main Fleet 1 by driving it into an unproven damage path.)
The readiness verifier surfaces this as `CH10_AMBUSH_POSTURE`, and Script B repeats it in its header.

### Fleet recovery, if the expendable fleet is lost

1. The ships are destroyed, not the player. `main_ship_instances` rows for the lost hulls move out of
   the active fleet; the player keeps wallet, base resources, inventory and every other ship.
2. Re-commission from a port: `commission_additional_main_ship` (behind
   `mainship_additional_commission_enabled`), up to `max_main_ships_per_player` (24). Cost is the
   configured ship price against `player_wallet`.
3. Re-arm: `craft_module` + `fit_module_to_ship`, then `upsert_ship_group` /
   `assign_ship_to_group` / `set_fleet_command_ship` to rebuild the team.
4. If the loss was caused by the canary itself rather than an en-route ambush, **roll back Script B
   first** (one `set_game_config` call, effective on the next tick) before doing anything else.

---

## 9. Post-activation monitoring

Run these read-only queries after Script B. All of them are safe at any time.

```sql
-- 1. Did the canary fire at all? (non-NULL resolved_plan_json tagged with the canary profile)
select ce.id, ce.player_id, ce.status, ce.waves_cleared, ce.total_rewards_json,
       ce.resolved_plan_json->>'encounter_profile_id' as profile,
       ce.created_at, ce.last_resolved_at
  from public.combat_encounters ce
 where ce.location_id = '75baf5d7-6b06-4567-84c9-de97938aa251'::uuid
   and ce.resolved_plan_json->>'encounter_profile_id' = '4d8bd4ee-4b61-454f-b0bc-fbf058ee4dd9'
 order by ce.created_at desc
 limit 20;

-- 2. The wave that actually spawned — must be exactly ONE pirate_synthetic per encounter.
select cu.encounter_id, count(*) as enemy_rows, min(cu.hp_max) as hp_max,
       array_agg(distinct cu.unit_type_id) as unit_types
  from public.combat_units cu
  join public.combat_encounters ce on ce.id = cu.encounter_id
 where cu.side = 'enemy'
   and ce.resolved_plan_json->>'encounter_profile_id' = '4d8bd4ee-4b61-454f-b0bc-fbf058ee4dd9'
 group by cu.encounter_id;

-- 3. The runtime ledger. active_count is CUMULATIVE (never decremented) — read it as "spawns so far",
--    not "live encounters". last_spawn_at is the cooldown anchor.
select location_id, encounter_profile_id, last_spawn_at, active_count,
       extract(epoch from (now() - last_spawn_at)) as seconds_since_last_spawn
  from public.encounter_runtime_state;

-- 4. The DERIVED cap — the real "how many are live right now" answer.
select count(*) as live_canary_encounters
  from public.combat_encounters ce
 where ce.location_id = '75baf5d7-6b06-4567-84c9-de97938aa251'::uuid
   and ce.status in ('active','retreating')
   and ce.resolved_plan_json->>'encounter_profile_id' = '4d8bd4ee-4b61-454f-b0bc-fbf058ee4dd9';

-- 5. Isolation: still exactly ONE active binding, and it is the canary?
select id, location_id, encounter_profile_id, active, revision
  from public.location_encounter_bindings
 where active is true;

-- 6. Flag posture.
select key, value from public.game_config
 where key in ('encounter_resolver_enabled','enemy_content_registry_enabled',
               'encounter_authoring_enabled','encounter_binding_authoring_enabled',
               'spatial_combat_enabled','pirate_intercept_enabled')
 order by key;

-- 7. Blast-radius check: has ANY encounter outside Reaver been tagged with a resolved plan?
select ce.location_id, count(*) 
  from public.combat_encounters ce
 where ce.resolved_plan_json is not null
   and ce.location_id <> '75baf5d7-6b06-4567-84c9-de97938aa251'::uuid
 group by ce.location_id;
```

Query 7 is the one to watch: **any non-empty result means the canary is not isolated** — roll back
Script B immediately.

---

## 10. Files

| File | Role |
|---|---|
| `scripts/encounter-canary-readiness.sql` | read-only readiness verifier (§3.3) |
| `scripts/encounter-canary-readiness.sh` | its runner, with a `--expect-blocked` selftest mode |
| `scripts/encounter-canary-proof.sql` | disposable exact-chain proof (§3.4) |
| `scripts/encounter-canary-proof.sh` | its runner + the post-rollback cleanliness check |
| `.github/workflows/encounter-canary-proof.yml` | CI: selftest + read-only assertion + proof + activation-script separation checks |
| `scripts/activate-canary-binding.sql` | **Script A — owner-run only, unexecuted** |
| `scripts/activate-encounter-resolver-canary.sql` | **Script B — owner-run only, unexecuted** |
| `docs/ENCOUNTER_CANARY_PACKET.md` | this document |
