# COMBAT — THE OWNER'S FIVE DIRECTIVES, AS AN IMPLEMENTATION CONTRACT

**Status:** design only. Nothing here is built. No production write, no migration, no merge has
happened in producing it. Every number marked *measured* was read read-only off production on
2026-08-08; everything else is marked **UNMEASURED** and is not to be treated as fact.

**Ground truth used.** The live engine is the authority, not the repo. `process_combat_ticks` was
dumped from production with `pg_get_functiondef` (1,396 lines, 99,286 chars,
`md5 = 3806e89a97237bf00f593ad38a834580`, captured this session) and every "live N" below indexes
that dump at `C:/Users/gkwng/AppData/Local/Temp/pct.sql`. Leaf bodies were dumped the same way
(`leaf_combat_acquire_target.sql`, `leaf_combat_spawn_wave_units.sql`,
`leaf_combat_wave_arrival_phase.sql`, `leaves2.txt`, `ccge.sql`, `cce2.sql`, same directory).

**Migration numbers.** `0341` and `0342` are held by unmerged PRs #397 and #396 at an explicit owner
gate. I re-derived the maximum across **all 271 `origin` refs** this session: `20260618000342`.
**This programme starts at 0343.** Re-derive again at the moment each branch is cut — a duplicate
version is not a git conflict; both files land, `schema_migrations` keys on the version, and the
loser is silently skipped.

---

## 1. THE FIVE DIRECTIVES, IN THE OWNER'S WORDS

### D3 — first, because it has been said three times

> *"I told you that it will be not +1 fleets when fleet is destroyed."*

**Clearing a wave literally spawns one more enemy.** Two lines do it:

| live | code |
|---|---|
| `pct.sql:442` (spatial arm) | `v_danger := 1 + e.waves_cleared + floor(v_secs_inside/180)` |
| `pct.sql:1192` (aggregate arm) | the same line, copied |
| `pct.sql:571` | `v_enemy_count := least(cfg_num('enemy_synthetic_max_units',6), greatest(1, v_danger))` |

So `waves_cleared` feeds `v_danger` feeds the number of bodies. **Measured firing in production:**
Snare encounter `520a35c0` went wave→bodies→hp of 1→1→203, 2→2→319, 3→3→427, 4→4→505, 5→5→545,
6→6→587, then pinned at the cap of 6 while hp climbed to 1036 (5.1×). Encounter `953fe570` is
identical (223→957). On the aggregate arm, Reaver `6b6f5ff0` ran danger 1→19 and wave hp 362→2860.

The same term also multiplies enemy toughness — HP `× (1 + v_danger*0.6)` at live 519/521 (resolved),
568/570 (synthetic), 1194 (aggregate); attack `× (1 + v_danger*0.25)` at live 521/570/1212.

**Killing well is the thing that kills you.** That is the defect, and it is deleted, not tuned.
PR #397's banded ramp (`0341:279-288`) keeps `waves_cleared` inside `v_danger` and slows the ramp to
every fifth kill behind a new knob — that is the adapter the standing law forbids, and its own
assert (d) at `0341:432-437` exists to prove the ramp still fires. Do not merge it.

### D1 — the range circle lies

> *"the range circle, outer circle when fighting, did not even touch a fleet yet it shot."*

There is ONE fleet glyph and FOUR hull positions. The fire gate measures escort→pirate; the client
draws the ring on an elected LEAD somewhere else entirely.

- The gate: `pct.sql:770-771` compares `v_target_dist` against the weapon's range, where
  `v_target_dist` comes from `combat_acquire_target` called with the actor's **frozen pre-move**
  coordinates (freeze `pct.sql:623-632`, acquisition `:698-701`).
- The drawing: `src/features/map/spatialCombatLayer.ts:115-133` `resolveRenderPoints` substitutes a
  unit's own point for its **actor's** point, and `src/features/map/fleetFightPosition.ts` (19 KB,
  the whole file) exists only to choose WHICH hull the one glyph stands on.
- The aggregation: `src/features/map/combatActors.ts:142` makes the fleet's `range` a `Math.max`
  over living hulls; `spatialCombatLayer.ts:73-80` makes a ship's range a max over its weapons.

**Measured magnitude, on the owner's own fight:** pirate `3d849ba6` fired at escort `7581ea02` at a
true gate distance of **3.20** (inside its range of 4 — the engine was right); the fleet glyph and
its ring stood **6.86** away, so the pirate's drawn ring of radius 4 fell **2.86 world units short of
the fleet it had just shot — 71% of its entire drawn reach**. The other direction: escort `7581ea02`
fired at 3.95 (inside 5) while the fleet's ring of radius 5 was drawn 6.47 from that target — 29%
past its own ring. Player formation spread on that fight was 1.31–5.19, the same order as the weapon
range of 5. The known related defect `0336:35-40` is the same class on the server, and it was already
fixed once.

### D2 — enemies must come out of the zone's city

> *"once an enemy fleet is destroyed, it should come out from snare, not on a blank space."*

0338 and 0339 both shipped and the owner still sees blank-space arrivals. **The cause is verified,
and it is not the bearing leaf.** `combat_spawn_wave_units` places every unit on a ring centred on
the **PLAYER anchor**:

```
leaf_combat_spawn_wave_units.sql:30-31
  combat_formation_point(p_anchor_x, p_anchor_y, v_extent + p_range + 1, v_slot,
    combat_wave_arrival_phase(p_anchor_x, p_anchor_y, p_site_x, p_site_y, v_slot))
```

The site contributes a **bearing and nothing else**. Measured: spawn radius 12.10 against an
anchor→Snare distance of 23.85, putting every pirate 11.75–26.75 from Snare — blank space, exactly
as reported. `combat_wave_arrival_phase` itself is a pure, origin-agnostic bearing-plus-fan function
(read in full at `leaf_combat_wave_arrival_phase.sql`); it is **not** the defect and is not deleted.

Second half of D2: 0339's standoff has never once run. **Measured: 0 of 44 encounters ever started at
a standoff point** — because `combat_create_encounter` resolves the anchor from the fleet's own
spatial state first (`cce2.sql:28-30`), which wins on every ambush, and 8 of the 14 most recent
encounters are ambushes. And `cce2.sql:44-49` claims the standoff bearing is *"hashed from the
presence so two fleets hunting one site do not stack"* — the deployed body hashes site coordinates
only. A stated invariant with no live check.

### D4 — a lock takes time

> *"I want a lock in system, where it takes time for every fleet to lock a target, then attack.
> right now it just attacks every fleet simultaneously."*

**There is no held target anywhere in the schema.** `v_target_id` is a PL/pgSQL local, declared at
live 78 and nulled at live 698 on every pass of every tick. No table carries a target, a capacity or
a lock column — verified against production's `information_schema`.

### D5 — attack count is weapon count

> *"when a ship is equipped with one weapon, it can only attack one target, but if it has two weapons
> on a ship, it can attack once two fleets same time, or attack a fleet twice each time, and so on
> for third weapon."*

Each weapon is **one attack and one lock**. Today targeting is per HULL, resolved once above the
weapon loop at live 698-701 — every gun on a ship shoots the same row.

**This supersedes `docs/TARGET_CAPACITY_RULING.md`.** That document derives capacity from the command
captain's LEVEL through an unlock table on `ship_groups` (`:53-76`), with a hand-set ceiling of 6
(`:78-83`) and a fleet-level allocator (`:85-98`). Capacity is now **per ship, from weapon count**.
The ruling is superseded, not reconciled. (Measured, its ceiling was wrong anyway: every hull has
`module_slots = 3` and weapon `slot_cost` is 1 or 2, so the real ceiling is 3 and it is derived.)

---

## 2. WHAT GETS DELETED

Every row is a deletion because the thing itself is what contradicts the owner. Where a knob could
"turn it off", that is called out as the adapter it would be.

| # | What | Where | Why a deletion, not an adapter |
|---|---|---|---|
| 1 | `+ e.waves_cleared` inside `v_danger` — **both copies** | live `pct.sql:442`, `:1192`; repo `20260618000299_...:647`, `:1035` | The kill-escalation term the owner rejected three times. A knob scaling it to zero preserves the mechanism. |
| 2 | The whole `v_danger` concept: the time term, the HP/attack multipliers, and the reward scale | live `pct.sql:442/519/521/568/570/1192/1194/1212/883/886`; knobs `enemy_hp_danger_scale`, `enemy_attack_danger_scale`, `reward_danger_scale` | With #1 gone, `v_danger`'s only surviving consumer is the **reward line** — it would become a pure loiter-for-metal multiplier and a second authority for payout beside the site's `reward_tier`. Difficulty is the SITE ROW. |
| 3 | `v_enemy_count := least(cfg_num('enemy_synthetic_max_units',6), greatest(1, v_danger))` | live `pct.sql:571` | The literal "+1 enemy per kill", measured firing. Also a second authority for wave size beside the authored plan's count at live 516. |
| 4 | `v_resolver_engaged` used as the **branch between two sizers** | live `pct.sql:163-166`, `:486`, `:494` | Two live authorities for wave size, selected by a global flag read per invocation. It has already stepped a live fight 18× mid-flight (Reaver `7f56967e`: wave 13→14, units 1→6, hp 123→2213, fleet died). The tick's own header at live 204-212 forbids exactly this pattern one line above. |
| 5 | PR #397 / `0341`'s banded ramp, `v_band`, `v_pirate_danger`, and `enemy_synthetic_units_per_danger_band` | `20260618000341_...:183`, `:279-288` (unmerged, owner-gated) | `waves_cleared` stays in `v_danger`; killing still escalates, every fifth kill, with a knob on the rejected axis. Also physically incompatible: its precondition (a) at `:143` text-anchors the exact line slice 0344 deletes. **Do not merge, do not modify.** Only its fire-rate half (`:53-56`, four rows/knobs) is worth re-cutting separately. |
| 6 | The entire 0228 aggregate / no-positions combat arm | live `pct.sql:1188-1376` — its `v_danger` copy, its aggregate damage split `:1256-1297`, its `order by aggro_priority` targeting `:1246-1253`, its `projectile_count` cosmetic `:1241`, its **bodiless** `wave_spawned` `:1210-1219`, its wreck copy `:1371-1381`, its wave-clear copy `:1302-1346` | The parallel path that keeps minting dead knobs and duplicated arms. `jsonb_array_length(v_weapons_json)` occurs exactly ONCE in the whole live body (`:741`) — the aggregate arm has no per-weapon concept at all, so under D5 it cannot express the rule. Measured: 15 of 44 encounters ran it, last on 2026-08-02. |
| 7 | The **non-manifest arm** of `combat_create_encounter` and the bodiless `wave_spawned` it emits at creation | `cce2.sql:61-84` | It inserts `combat_units` with **no `pos_x` column in the INSERT at all** — the only remaining producer of a positionless encounter. **Measured: 0 encounters through it since 2026-07-05**; all 21 since are member-based. One encounter creator. |
| 8 | The `spatial_combat_enabled` gate inside the creator | `ccge.sql:31`, `:67`, `:171` | A dark-first flag whose dark side is the arm being retired. Once there is one arm, this flag is a switch that breaks combat. Prod value `true` (measured). |
| 9 | `per_ship_targeting_enabled` (row + declaration + read) | live `pct.sql:71`, `:155`, only use `:1246-1253`; prod value `true` | One reader in the entire database, inside the retired arm — and **misnamed**: it redirects ENEMY damage onto one player hull. Leaving it invites the next slice to repurpose it and ship a no-op. |
| 10 | `pirate_loot_for_wave`'s `p_danger` parameter and both arguments passed to it | live `pct.sql:888`, `:1306`; declared `20260617000041_pirate_loot.sql:19-20` | Declared, passed twice, **never read** by the deployed body. A lie in a signature that has already been mistaken for a real coupling. |
| 11 | The hard-coded loot ladder `if p_wave >= 3 / 5 / 8 / 10` | deployed body of `pirate_loot_for_wave` | Gates content on DEPTH with **no site-tier term**, so a tier-3 site pays the same items as a tier-1 site. Adding loot must be inserting a row, not editing a function. |
| 12 | The **per-hull player position write** | live `pct.sql:733-735` | THE ROOT of D1. The owner's law is "show only fleet. it is as a whole", yet the invisible formation is the only thing the fire gate measures. Correcting the drawing on top of a retained formation is the adapter. |
| 13 | `combat_translate_player_formation` | `leaves2.txt:53-73`, composed at `combat_encounter_move` step 1 (`leaves2.txt:14`) | A rigid-translate primitive exists only to keep four invisible offsets consistent. With one position there is nothing to translate. |
| 14 | The player escort ring built by `combat_formation_point` in the creator, and the knob `spatial_formation_ring_radius` (=6, measured) | `ccge.sql:198`; `game_config` | Same reason. **`combat_formation_point` itself SURVIVES** — it is still the ring primitive for enemy emergence. Only the player-side call dies. |
| 15 | `src/features/map/fleetFightPosition.ts` in full and both callers | the file; `combatActors.ts:127-132` and the team-badge caller | It exists solely to choose which hull the one glyph stands on — and by this project's own measured lesson it picks the hull FARTHEST from the wave. Give the fleet one position and the question disappears. |
| 16 | `resolveRenderPoints` and every consumer of the substitution | `spatialCombatLayer.ts:115-133`; `resolveFireLines :193-196`; `combatMotion.resolveOrdnance :439-441`; `resolveHitSplats` | A unit-id→actor-point substitution table is a translation layer between two positional truths. It is the mechanism of D1's lie, implemented deliberately. |
| 17 | `combatActors.ts:142` — the fleet actor's `range` as `Math.max` over hulls | `src/features/map/combatActors.ts` | A fleet-aggregated range is the class `0336:35-40` proved wrong on the server, re-created on the client as a PROMISE to the player. |
| 18 | `spatialCombatLayer.ts:73-80` `unitWeaponRange` and its consumer at `:100` | same file | It answers "the range" for a thing that has W ranges. Under D5 a single max ring would hide W−1 of the ship's reaches. Not kept as a fallback. |
| 19 | `docs/TARGET_CAPACITY_RULING.md`'s capacity model **in full** — the fleet-level definition `:8-14`, the `ship_groups` columns `1 ≤ selected ≤ unlocked ≤ 6` `:39-51`, the captain-LEVEL unlock table `:53-76`, the ceiling of 6 `:78-83`, the fleet-level allocator `:85-98`, the progression prerequisite `:100-118` | the file | D5 says capacity is per SHIP from WEAPON COUNT. A captain-level unlock table is a competing authority for the same number, and it would make fitting a third gun do nothing until a captain hit level 25 — the exact defect 0331 was written to end. **Verified unshipped:** no target/capacity/lock column exists in any production table, so this is doc-only. No reconciliation section, no level table behind a flag. |
| 20 | The `v_extent + p_range + 1` term as a **placement radius** | `leaf_combat_spawn_wave_units.sql:30` | It anchors the spawn to the PLAYER, which is D2's root cause. With the formation gone, `v_extent` does not exist. It survives only as a clearance **assertion**. |
| 21 | The false comment claiming the standoff bearing is presence-hashed | live `cce2.sql:44-49`; repo `0339:702-706` | The deployed body hashes site coordinates only. Implement it or delete the sentence; a stated invariant with no live check is a recorded failure class. |
| 22 | The three "One leaf, called by all four arms" comments that are themselves copies | live `pct.sql:248`, `:310`, `:943`, `:1359` | The sentence is false in three of the four places it appears, because it was copied along with the block it describes. After 0343 it is true once. |
| 23 | The idea of a `combat_weapon_locks` table or a `target_unit_id` column on `combat_units` | not written — rejected here | `weapons_json[i]` is already the per-weapon mutable-state store (one writer live 870, one reader live 739, stable index). A lock table is a second home for per-weapon state; a column on `combat_units` stores a per-WEAPON fact at per-SHIP grain and quietly re-creates the per-ship targeting D5 deletes. |
| 24 | `danger_level` as a written column, and the client's `Danger N` readout | live `pct.sql:912`, `:1330`; `ActiveCombatPanel.tsx:99-101` | A number that went UP because the player played well, with no way to know why. With #2 the concept is gone; the column stops being written in 0344 and is dropped in 0349. |

**Deletion count: 24.**

---

## 3. THE SINGLE AUTHORITIES

One row per concept. This table is the anti-spaghetti core: after this programme, every one of these
concepts has exactly one place it is decided.

| Concept | THE authority | Consumers | What it replaces |
|---|---|---|---|
| **A wreck** (the fleet died) | `public.combat_encounter_wreck(p_encounter uuid)` — new leaf, 0343. Wraps `combat_encounter_release(..., true)` + `fleet_consume_retreat_target` + the `mainship_mark_combat_destroyed` loop + the terminal UPDATE. **It does NOT log a `combat_ticks` row.** | arm A (live 240-279), arm C (live 935-966), the aggregate arm's copy (live 1371-1381, until 0345 deletes it) | The two byte-identical blocks at live 955-959 / 1371-1375, and arm A's copy at 260-264. **Verified difference, and it is real:** arm A's UPDATE (live 265-267) writes `tick_number, last_resolved_at, player_integrity_current=0, player_power_current=0` and inserts a `combat_ticks` row (`:269-272`); arms C/D write only `status/ended_at/total_rewards_json/updated_at` (live 960, 1376) and log no tick. The leaf adopts arm A's fuller UPDATE (a strict superset, correct on a terminal row); **arm A keeps its own `combat_ticks` insert at the call site**, because arm C's tick was already logged at live 899-907 and folding it in would double-insert. |
| **A departure** (the fleet leaves alive) | Arm B, live `pct.sql:289-434`, unchanged and **not folded into any leaf** | itself; and the new no-anchor guard (0345), which reaches it by setting the forced-extract condition | Nothing. It is a different concept: `release(..., false)`, `report_create` BEFORE release, the retreat target **read** while consumed (`:373-376`), a per-hull `mainship_mark_legacy_in_flight('returning')` vs `mainship_mark_combat_destroyed` branch (`:414-418`), `movement_create` + `fleet_set_returning`, `movement_attach_cargo(v_mv, e.id, e.total_rewards_json)` (`:420-422`), and a `retreat_completed` event. Folding it into the wreck leaf would zero a live player's haul and destroy their surviving ships. |
| **How big and how tough a wave is** | The SITE ROW and its authored plan: `locations.base_difficulty`/`reward_tier` → `encounter_profiles` → `encounter_profile_members` → `fleet_templates`, resolved by `resolve_location_encounter`, instantiated by `combat_spawn_wave_units` (count already taken from the plan at live 516) | the wave composition block (live 486-598, after the synthetic sizer is deleted); `combat_spawn_wave_units`; the reward line's `greatest(loc.reward_tier,1)` | deletions #1, #2, #3, #4, #5 |
| **Where enemies come from** | `public.combat_spawn_wave_units(...)` — already the schema's SOLE inserter of an `side='enemy'` row. Its **origin** moves to `(p_site_x, p_site_y)` on a data-driven emergence ring | the resolved-plan arm (live 541-544), the synthetic arm (live 595-598), `combat_unit_decide_move` (the existing per-tick mover carries them in), the client (`wave_spawned` gains its origin coordinate) | deletion #20 and the aggregate arm's bodiless `wave_spawned`. **`combat_wave_arrival_phase` and `combat_formation_point` are KEPT and composed with swapped arguments** — the site becomes the ring centre, the engagement point becomes the far end of the bearing. |
| **Where a fight physically stands** | `combat_encounters.engagement_x/engagement_y`, sole writer `public.combat_encounter_move` (live 1166; leaf `leaves2.txt:2-24`), resolving ONE rule: **a fight stands where its fleet is, and a fleet present at a site stands on that site's territory edge** | the tick's `v_anchor` (live 199-200) and both retreat-leg origins; the fleet's per-tick chase step (new, 0346); `combat_spawn_wave_units`'s bearing endpoint; the client fleet actor via `src/features/combat/encounterAnchor.ts`; `spatialCombatLayer`'s ring/fire-line/splat passes | `combat_units.pos_x/pos_y` as player-side spatial state (#12), `combat_translate_player_formation` (#13), the escort ring (#14), `fleetFightPosition.ts` (#15), `resolveRenderPoints` (#16). **The `location_mode='space'` arm (`cce2.sql:28-30`) is NOT deleted** — see §4/0347. |
| **Target acquisition** | `public.combat_acquire_target(p_units, p_my_x, p_my_y, p_my_side, p_exclude uuid[])` — the existing leaf, **dropped and re-created** (never overloaded), asked once per WEAPON | the per-weapon loop (replacing live 698-701 and 765); the FLEET's chase destination, asked once from the fleet's one point | the per-SHIP acquisition above the weapon loop (live 698-701); the aggregate arm's `order by aggro_priority asc, id asc` selection with no distance and no tier screen (live 1246-1253); the fleet-level allocator in `TARGET_CAPACITY_RULING.md:85-98` |
| **Attack count, and the lock** | `combat_units.weapons_json[i]` — the per-weapon array element. One writer (live 870), one reader (live 739), stable index (only `jsonb_set` on the same index, live 865-867). Gains `lock_target_id` + `lock_ready_tick` beside `next_ready_at`/`ammo_remaining`. **Attack count IS the array length.** | the fire gate (live 770-771), which gains one conjunct and no new branch; the three freeze sites — real player weapons `ccge.sql:206-214`, the player fallback `ccge.sql:239-253`, the enemy `leaf_combat_spawn_wave_units.sql:38-42`; the client (`combatTypes.ts` `CombatWeapon`, a lock pass in `spatialCombatLayer.ts`, one lock row per weapon in `CombatMapCard.tsx`) | deletion #19 and #23; and the fact that no held target exists today at all |
| **Range and the fire decision** | `weapons_json[i].range` compared against ONE actor-to-actor distance, `osn_distance(engagement point, enemy pos)`, taken from the **post-move** snapshot — the state the DB row holds and the client polls | the fire gate (live 770-771); `impact_delay_ms` (live 780); `combat_unit_decide_move`; the client range-ring pass `spatialCombatLayer.ts:443-464`, redrawn as ONE RING PER WEAPON at the fleet's one point; the ordnance flight `combatMotion.ts:439-461` | deletions #17, #18; and the pre-move frame of reference (freeze live 620-632 read by a gate whose result the client draws post-tick) |
| **Which combat arm runs** | After 0346: `v_is_spatial := e.engagement_x is not null`. There is one arm; the predicate exists only to catch an unrepresentable legacy row and route it to a **departure** | the tick | live `pct.sql:213` (`exists(... pos_x is not null)`) and the aggregate arm it selects |

---

## 4. THE SLICES

Dependency order first, risk ascending within it. Each slice lands server + client + proof together
(`never-ship-half-a-slice`); a slice that cannot land both halves does not land.

### 0343 — `one_way_to_die`

> **IMPLEMENTED 2026-08-08 — amendments made while building it, recorded here so the next slice is
> cut from what is TRUE rather than from what was planned. Each is argued in full in the migration's
> own header (`supabase/migrations/20260618000343_one_way_to_die.sql`).**
>
> 1. **The leaf is `combat_encounter_wreck(p_encounter uuid, p_tick integer)` — two arguments.** This
>    section requires the leaf to adopt arm A's UPDATE, which writes `tick_number=v_tick`, and
>    `v_tick` is `e.tick_number + 1` (live 175). At arm A's call the row still holds the OLD
>    `tick_number`; at arms C and D the UPDATE above has already advanced it. No expression over the
>    row alone is correct at all three sites, so the caller states the tick. It matches the convention
>    of the leaf it composes — `combat_encounter_release` also takes fleet and presence explicitly.
> 2. **0343 is a REPLACE-REWRITER, not a full re-emission of the body.** "Re-emit from the deployed
>    `pg_proc.prosrc`" is implemented as reading `pg_get_functiondef` AT APPLY TIME and replacing four
>    hunks in it, each required to match its source text exactly once. A full textual re-creation was
>    written first and **broke eleven generators at once** — `scripts/gen-0314`, `-0315`, `-0316`,
>    `-0317`, `-0319`, `-0331`, `-0332`, `-0333`, `-0336`, `-0337`, `-0339` each assert that 0299 is
>    still the newest textual re-create of `process_combat_ticks`, and their own comment states the
>    rule: *"Replace-rewriters do not move the textual head, but any later `create or replace
>    function public.process_combat_ticks` means the slice source is stale."* Observed by running
>    `scripts/danger-combat-proof.sh selftest` and reading the failure, not predicted. **Every later
>    slice in this programme must be a replace-rewriter too, or must re-point those eleven generators
>    as part of its own slice.** Consequence for trap C10: the recorded prod md5 is raised as a NOTICE
>    with the observed value beside it, never as an abort — the per-hunk exactly-once match is the
>    real gate, and it is what "the anchor is missing on prod ⟶ 0343 aborts" actually means.
> 3. **Self-asserts 2 and 3 (the behavioural ones) are NOT in the migration and are not claimed.** A
>    migration cannot build a three-encounter fixture without writing rows to production. What DOES
>    gate the fold behaviourally, on the disposable leg: `danger-combat-proof.sql:7086-7110`
>    (NOWEDGE — a real fleet driven to death through the tick; asserts `defeat`, `ended_at`,
>    `last_resolved_at` not rewound, `tick_number` ADVANCED, zero living hulls) and
>    `danger-combat-proof.sql:7683-7698` (RETREATCLEAR A — a fleet that dies holding a recorded
>    retreat destination comes back with all three `retreat_target_*` NULL). Both exercise arm C.
>    **Still unwritten: arm A, arm D, and the departure-shaped assert.** Proof-file work, needs the
>    disposable leg to validate.
> 4. Arm B is untouched except one **comment-only** hunk correcting the now-false "One leaf, called by
>    all four arms" sentence (deletion #22). Assert (a) counts on comment-STRIPPED text, so that
>    correction is not load-bearing.
> 5. **Proof triggers needed no widening** — `combat-spatial-proof.yml` and `danger-combat-proof.yml`
>    already fire on `pull_request`, `main` and `slice-**` (0335/0336 collapsed the hand-maintained
>    lists). Verified in the tree, not assumed.

**Scope.** Mint `public.combat_encounter_wreck(p_encounter uuid)` and route the three fleet-died
blocks through it (arm A live 260-264, arm C live 955-959, aggregate live 1371-1375). Re-emit
`process_combat_ticks` from the **deployed** `pg_proc.prosrc` — never from a migration file; the
tick's own header at live 210-212 records that this line has been reverted three times by copying
from an older file. Arm B is **not touched**. `combat_wave_clear` is **not minted** (see 0345).

**Behaviour delta, stated because it is not zero.** Arms C and D gain four terminal column writes
(`tick_number`, `last_resolved_at`, `player_integrity_current=0`, `player_power_current=0`) — a
strict improvement on a terminal row, and the only observable change. Arm A keeps its `combat_ticks`
insert at the call site.

**Self-assert.**
1. Over a **comment-stripped** copy of the emitted body: `combat_encounter_release` occurs
   **exactly once** in the tick (arm B's call at live 324) and exactly once inside
   `combat_encounter_wreck`. Not zero — asserting zero is what would force arm B into the leaf.
2. Behavioural, per call site: build three disposable encounters shaped for arms A, C and D; drive
   each to death; assert `status='defeat'`, `total_rewards_json='{}'`, a report row, every
   `main_ship_id` marked destroyed — **and a row-count parity check**: the number of `combat_ticks`
   and `combat_events` rows written by the terminal pass equals the pre-0343 count for that arm
   (1 tick row for arm A, 0 for C and D).
3. Behavioural, the **departure** shape — the assert this slice would otherwise be blind to: a fight
   with a non-empty `total_rewards_json` and a living hull, driven through arm B, ends `escaped`
   with the haul **unchanged**, a movement row carrying it as cargo, **zero** ships marked destroyed
   and every survivor marked `'returning'`.
4. Schema sweep: no function in `public` other than `combat_encounter_wreck` sets
   `combat_encounters.status` to `'defeat'`.
5. The proof SETS `combat_tick_logging` and `combat_event_logging` in-txn; it asserts no seed.

**Rollback boundary.** Pure refactor plus four terminal columns. Redeploy the pre-0343 body (retained
verbatim in the migration header as the parity source) and drop the leaf. No column added, no row
written, no knob touched, no client half.

**Proof.** `combat-spatial-proof.sql` + `danger-combat-proof.sql`, triggers widened to `slice-**`.

---

### 0344 — `killing_well_is_not_punished`  *(D3)*

**Scope.** Delete `+ e.waves_cleared` from `v_danger` at live 442 **and** 1192. Delete the whole
`v_danger` concept with it: the time term, the HP and attack multipliers (live 519/521, 568/570,
1194/1212) and the reward scale (live 883, 886). Delete the synthetic sizer at live 571 and the
`v_resolver_engaged` sizer branch (live 486, 494). **One sizer: the site's authored plan.**

- **Plan-less encounters are the normal case and must be handled explicitly.** Measured: only
  **2 of 44** encounters carry a `resolved_plan_json`. So (a) the migration backfills every
  non-terminal encounter by resolving a plan from its location (the 0293 precedent the live header
  at 193-196 cites), and (b) the tick resolves-and-stamps a plan on demand for any row that still
  has none. Without this, 94% of live fights would reach the wave branch with no count source and
  stall on `v_e_before <= 0` forever.
- **Content rows in the same slice.** Author `encounter_profiles` / `encounter_profile_members` /
  `location_encounter_bindings` for **Snare and Blackden** (today only Reaver's binding is
  `active=true`; Snare's is `active=false`; Blackden has none). Reward becomes
  `reward_metal_base × greatest(reward_tier,1)` — the site row, one authority.
- **Client, same slice.** `ActiveCombatPanel.tsx:99-101` stops printing `Danger N`; the panel states
  the wave number and the site instead.

**Self-assert.**
1. Comment-stripped: the `v_danger` identifier occurs **zero** times in the emitted body.
2. **The anti-proof, table-driven over the class and with the observable poisoned.** For
   `waves_cleared` 0..30 and `secs_inside` in {0, 361, 1801}, with `danger_level` **set to 99 on
   every fixture before the tick** (measured: `combat_encounters.danger_level` has
   `column_default = 1, NOT NULL`, so a fixture the tick never reaches would read back `1` and pass
   a naive assert): the number of bodies spawned, their hp, their attack and the metal paid are
   **identical across all 93 cells**. Plus a liveness assert in the same block — exactly 93 rows
   examined, every one with `tick_number` advanced and a `combat_ticks` row from this run — so it
   cannot pass by the tick never executing.
3. The rewind set is stated and applied per simulated tick: `last_resolved_at`, `next_wave_at`,
   `next_ready_at`. `now()` is frozen for the whole transaction (`danger-combat-proof.sql:307`
   records this), so a block that does not rewind proves nothing.
4. The proof SETS `max_presence_seconds_default` and the fixture location's `max_presence_seconds`
   in-txn rather than reading them.
5. Every location with `location_type='pirate_hunt'` and `status='active'` resolves to a plan with
   `count >= 1`; a site that would fall through **fails the deploy**.
6. Behavioural: an encounter created with `resolved_plan_json` NULL, enemy side wiped, ticked once,
   spawns a wave with `>= 1` unit.

**Rollback boundary.** Body change, deliberately not knob-revertible — a knob would preserve the
mechanism. Rollback = redeploy 0343's body and set the new bindings `active=false`. The metal
consequence (−49.3%, measured) is a separate knob (`reward_metal_base`) and is untouched here, so
rolling this back does not disturb the economy.

**Proof.** `danger-combat-proof.sql` (owns the danger sweep), `encounter-resolver-proof.sql` (owns
the plan resolution). Triggers `slice-**`.

---

### 0345 — `one_combat_arm`

**Scope.** Retire the 0228 aggregate arm in full (live 1188-1376) and the non-manifest creator arm
(`cce2.sql:61-84`) with its bodiless `wave_spawned`. Delete the `per_ship_targeting_enabled` knob row
and its three sites (live 71, 155, 1246-1253) and the `spatial_combat_enabled` creator gate
(`ccge.sql:31/67/171`). De-duplicate the wave-clear block **now** — after the aggregate copy is gone
there is one, so no leaf is minted for it.

**THE GUARD, and it must fail safe.** The aggregate arm's reachability condition is *"no unit carries
a position"*, **not** *"nothing is alive"*. **Measured on production: five encounters had 0
positioned rows and living hulls — `cbfbddf3`, `6bb94717`, `883e2f22`, `8a795735` (alive 15 each) and
`7238b0ec` (4 hulls alive, 5 waves cleared)** — and every one of them ended `escaped`. Routing that
condition to `'defeat'` would call `combat_encounter_release(..., true)` and
`mainship_mark_combat_destroyed` on living ships, on a live ~30-player game, irreversibly.

So the guard is: **an encounter the engine cannot represent is a forced extract, not a wreck.**
`if e.engagement_x is null or (no positioned unit) then v_forced := true` — which routes into arm B,
the existing settle path: fleet released without destruction, haul attached as cargo, survivors
marked `'returning'`. No new terminal arm, no new leaf, and the outcome matches what those five
encounters historically got.

**Self-assert.**
1. Comment-stripped: `0228 HEAD` occurs zero times; `v_per_ship_targeting` zero times;
   `order by aggro_priority` zero times.
2. `select count(*) from game_config where key='per_ship_targeting_enabled'` = 0.
3. **Behavioural, the real shape** (not the one arm A already catches): player hulls with
   `alive_count > 0`, `hp_current > 0` and `pos_x/pos_y` NULL. Assert the encounter ends `escaped`
   with **the fleet alive, zero ships marked destroyed, and `total_rewards_json` preserved on the
   movement leg** — and that it terminated (`tick_number` advanced; a second tick finds no due row),
   so it cannot hang.
4. A separate `hp <= 0` fixture, labelled as arm A's, still ends `defeat` through
   `combat_encounter_wreck`.
5. No `wave_spawned` event is ever emitted without a corresponding `combat_units` row. **223 such
   events exist in production today** (measured), none carrying a coordinate.
6. Exactly one `combat_acquire_target` call region survives in the tick.

**Rollback boundary.** Redeploy 0344's body and re-insert the knob row. The retired arm wrote nothing
the surviving arm does not, so no data is stranded. Blast radius bounded by measurement: 15 of 44
encounters ever ran the aggregate arm, last 2026-08-02; the non-manifest creator has produced
**0 encounters since 2026-07-05**.

**Proof.** `multipirate-lifecycle-proof.sql`, `spatial-sticky-mode-proof.sql`,
`combat-ticks-result-fix-proof.sql`. **Harness surface, counted this session and repointed in one
pass, not one CI round at a time:** `spatial_formation_ring_radius` 52 hits across 7 files, `pos_x`
161 hits across 9 files.

---

### 0346 — `the_fleet_is_one_actor_at_one_point`  *(D1 — the root)*

**Scope, server.** The fleet's ordinary chase becomes a FLEET step through the existing
`combat_encounter_move` leaf — one destination per fleet, resolved by asking `combat_acquire_target`
once from the fleet's own point — so the per-hull write at live 733-735 is deleted. The tick becomes
**two phases over one frozen population**: decide every move against the pre-move world, apply every
move, **re-freeze**, decide every shot against the post-move world.

**The freeze substitutes, and this is the load-bearing detail.** The freeze at live 623-632 builds
`v_units` from `combat_units.pos_x` for BOTH sides, and `combat_acquire_target` reads `pos_x` out of
that snapshot — **it is how enemies find the player**. So the freeze now writes the **engagement
point** for every player row. One substitution, server-side, replacing the client's
`resolveRenderPoints`. Without it, player rows enter the snapshot with NULL positions, every
pirate's target distance is NULL, `v_target_dist <= v_w_range` evaluates NULL→false, and **no pirate
ever fires again**.

`v_is_spatial` keys on `engagement_x is not null`. `combat_translate_player_formation`, the escort
ring and `spatial_formation_ring_radius` are deleted. **An ordered reposition outranks the chase**
(the stand-down rule live 733-735 already writes, preserved as an explicit precedence): exactly one
`combat_encounter_move` step is spent per tick.

**Scope, client — same slice, this contract cannot be carved by layer.** `fleetFightPosition.ts` and
both callers deleted; `resolveRenderPoints` deleted; `combatActors.range` and `unitWeaponRange`
deleted; the fleet actor's x/y read from `combat_encounters.engagement_x/y` via `encounterAnchor`;
`resolvePositionedUnits` repointed onto the engagement point for the player side (today
`spatialCombatLayer.ts:88-104` drops any row with `pos_x == null`, so a server-only landing makes the
fleet glyph, its hp bar, its ship count and every hit-splat vanish); range rings drawn **one per
weapon** at that one point, and only while that weapon can fire.

**Self-assert.**
1. Schema sweep, extending 0339's one-anchor sweep: **no function in `public` writes
   `combat_units.pos_x` for `side='player'`.**
2. Every player-side row in the tick's frozen `v_units` carries the engagement point to `<= 1e-9` —
   and the set is asserted **non-empty and NULL-free first** (row count equals the fixture's hull
   count), because a for-all over an empty or NULL set passes vacuously.
3. **The anti-proof for the substitution:** a pirate within range still fires in the same fixture.
   A silent disarm is the failure this assert exists to catch.
4. **The D1 property, with a real channel.** The gate's distance is added to the `missile_salvo`
   `payload_json` (one field; the client ignores unknown keys). Assert
   `payload.dist = osn_distance(engagement, target.pos)` recomputed from the **post-tick** rows to
   `<= 1e-9`, and cross-check `impact_delay_ms = round(1000 * dist / projectile_speed)::integer` as
   exact integer equality. *Without the payload field there is no channel: `v_target_dist` is a
   PL/pgSQL local and `impact_delay_ms` resolves to 0.05 world units at speed 50 — three orders
   coarser than 1e-9. An assert comparing `osn_distance` to itself is a tautology that holds while
   D1 is unfixed.*
5. Over 5 ticks: the anchor moves by **more than 0** and **no more than the fleet speed** per tick —
   the lower bound included so it cannot pass on a fleet that never moved. One of those ticks has a
   live reposition order, asserting **exactly one** step is spent.
6. `spatial_formation_ring_radius` row count = 0; `combat_formation_point` has no player-side caller
   (it survives for enemies).
7. The kite rest distance is asserted **with a stated tolerance**, never a bare float compare —
   player range 5 against pirate range 4 makes the resting distance exactly 5.0, and which side of
   the line it falls on is decided by float error and uuid ordering (the recorded DEADFIRE lesson).

**Rollback boundary.** The columns are **not** dropped and still hold their last values, so
redeploying 0345's body restores the per-hull chase intact and the client's old lead election still
finds real hulls. The client half rolls back by reverting and redeploying Pages. **The one hard
constraint: both halves land in the same wave.** A server reporting one position with a client still
electing a lead draws the fleet on a stale hull — inconsistently wrong, which the player hits
immediately. A green self-assert proves the half and can never prove the seam; only playing it in
Chrome does.

**Balance note, declared rather than smuggled.** Moving the fire decision onto the post-move snapshot
means any unit that closes into range during its own move fires in that same tick — **on both
sides**, one tick earlier than the measured baseline. This is a real balance change and it is
measured separately in §6, not folded into the D3/D4 budget.

---

### 0347 — `enemies_come_out_of_the_city`  *(D2)*

**Scope.** `combat_spawn_wave_units` creates its rows **at the site**, on a data-driven emergence
ring, arc centred on the bearing site→engagement, and the existing `combat_unit_decide_move` carries
them in. This is done by **composing the two frozen primitives with swapped arguments** —
`combat_formation_point(p_site_x, p_site_y, emergence_radius, v_slot, combat_wave_arrival_phase(p_site_x, p_site_y, p_engagement_x, p_engagement_y, v_slot))`
— and renaming the leaf's parameters in place. **`combat_wave_arrival_phase` is NOT dropped:** it is
a pure IMMUTABLE bearing-plus-fan with a coincident-point guard, a NaN screen and the ±slot/4 fan
that stops units stacking. Hand-rolling an arc would re-derive all three; losing the coincident-point
guard reproduces `distinct_enemy_points = 1`, the exact symptom recorded on 2026-08-04.

**The anchor rule is stated once and both resolutions are kept.** *A fight stands where its fleet
is; a fleet present at a site stands on that site's territory edge.* The `location_mode='space'` arm
(`cce2.sql:28-30`) reads the fleet's own spatial state and is **NOT deleted** — deleting it would
make combat a second authority for where a fleet is and would **teleport an ambushed fleet**:
measured anchor→site distance over the 10 most recent encounters is 18.38–32.14 against
`territory_radius = 12`, so forcing both arms to the standoff would snap the glyph up to 20 world
units at the instant of ambush, with no movement row and no interpolation source. That is the
owner's law 2 violated at creation time, on the path they hit most (8 of the 14 most recent
encounters are ambushes). D2 does not need it: the emergence origin is already an independent
argument (`p_site_x/p_site_y`, distinct from `p_anchor_x/p_anchor_y`, verified in the leaf
signature).

The `v_extent + range + 1` term survives only as a **clearance assertion**. `wave_spawned` gains its
origin coordinate so the client animates an arrival instead of a pop-in. The false presence-hash
comment (`cce2.sql:44-49`) is deleted. **A pirate zone with no attached location cannot host a
wave-spawning encounter** — `danger_zones.location_id` is nullable and 10 of 14 rows carry NULL,
including the owner's own `CANARY-0255-LIVEPROOF`; the rule is a content CHECK at activation, and a
NULL anchor never routes to `'defeat'` (0345's guard).

**Self-assert.**
1. Every enemy row a wave inserts is within `emergence_radius` of the **SITE**.
2. Clearance restated against the only player position that exists: every spawned row is at least
   `range + 1` from the **engagement point**. (Asserting it against `combat_units` player rows would
   quantify over an empty set after 0346.)
3. Behavioural, over the following ticks: the wave's distance to the fleet **strictly decreases while
   the pre-tick distance exceeds `my_range + margin`**, and each per-tick step lies in
   `(0, move_speed + 1e-9]`. The window is derived from the fixture's own geometry and speeds, never
   a literal tick count, and the margin is stated — the arrival distance is never compared to a
   range with zero margin.
4. Both creator arms produce a **defensible** anchor: the site arm exactly `territory_radius` from
   the site to 1e-5 (the tolerance `combat_site_standoff_point`'s six-decimal rounding was built
   for); the space arm exactly `fleets.space_x/space_y`, unchanged — the seam 0293 broke.
5. `emergence_radius` is written in-txn by the proof; no ambient read.
6. The proof draws its own zone and site — the seeded zones are rebuilt with `random()` on every
   fresh CI database.

**Rollback boundary.** Redeploy 0346's body. The emergence radius is a row, so its **magnitude** is
revertible without a deploy; only the origin change needs one. **Harness surface:**
`combat_wave_arrival_phase` 16 hits across 5 proof files — repointed, not deleted, so the fixtures
survive an argument rename.

---

### 0348 — `each_weapon_is_one_lock_and_one_attack`  *(D4 + D5 — the riskiest slice)*

**Scope, one slice because they are one mechanism.** A per-weapon lock slot holding a target id IS
the capacity mechanism; shipping D4 alone would store a per-SHIP target in a per-WEAPON place.

- `combat_acquire_target` is **dropped and re-created** with `p_exclude uuid[]` — never overloaded
  (the text-surgery migrations abort on overloads, and `0336:894-895` asserts an exact occurrence
  count of the 4-arg call string, which this slice updates).
- Target resolution moves **inside** the per-weapon loop.
- `weapons_json[i]` gains `lock_target_id` and **`lock_ready_tick`** — a TICK COUNTER, not a
  timestamp. Two reasons, both decided here rather than in CI: `now()` is frozen for a whole
  transaction, so a wall-clock lock can never be proved to elapse in a disposable-Postgres block
  (the cheapest green would be `lock_seconds = 0`, which makes the D4 proof vacuous in both
  directions); and a tick count is what the player can actually read, since the tick is 3.03 s and
  anything sub-tick is invisible.
- The `jsonb_set` write-back moves **out** of the fire block. Today it sits at live 865-867 inside
  the `if` opened at 770, and three `continue` statements skip live 870 — so lock progress, which is
  exactly the *not-fired* case, would never be recorded. The slot is cleared on the no-target path
  so no stale uuid survives.
- `lock_ticks` is frozen at **all three** freeze sites or the slice is half-shipped: the module
  catalog (`ccge.sql:206-214`), the player fallback knob (`ccge.sql:239-253`), the enemy synthetic
  (`leaf_combat_spawn_wave_units.sql:38-42`).
- **Allocation is an order, not a hidden consequence.** Passing `p_exclude` unconditionally would
  force spreading whenever ≥W enemies live, so a player could never concentrate fire — which makes
  fitting more guns strictly worse at reducing incoming damage, the same shape as the defect 0331
  was written to end. The owner's words allow both ("attack once two fleets same time, **or** attack
  a fleet twice each time"), so allocation is a per-fleet value `weapon_allocation ∈ {focus, spread}`
  on a row, defaulting to **focus**, with one toggle on the combat card. See Q4.
- **Client, same slice:** `CombatWeapon` gains the lock fields; a lock pass draws the acquiring
  segment shortening into the existing fire line and becoming it on release (one visual family, not
  a parallel effect); a reticle closes on the locked enemy; the map card lists one lock row per
  weapon.

**Self-assert.**
1. `pg_proc` holds **exactly one** `combat_acquire_target`, with 5 arguments.
2. With `lock_ticks = 2`: a weapon that acquires on tick N emits **no** `missile_salvo` before tick
   N+2 and **does** emit one on N+2 — both directions, so it cannot pass by the weapon never firing.
3. D5 in both directions: a 2-weapon hull facing 2 living enemies produces salvos with **two
   distinct `target_id`s in one tick** under `spread`; the same hull facing ONE enemy produces two
   salvos at the **same** target; under `focus` with 2 enemies both salvos take the same target.
4. A weapon whose lock target dies clears its slot rather than keeping a stale uuid.
5. The proof **fits its own two-weapon ship** — measured, only 2 of 249 `combat_units` rows in the
   game's history have ever carried more than one weapon, and every enemy row ever (115 of 115)
   carries exactly one. A proof that borrows production content asserts production content.
6. Every set read in this block is an aggregate, or an explicitly `order by`-ed and `limit`-ed read
   with the row count asserted first — `select into` in plpgsql takes the first row silently.

**Rollback boundary.** `combat_lock_ticks_default = 0` collapses the lock to instant, restoring
today's timing **without a deploy** — which is why the riskiest slice can be last. The per-weapon
exclusion is a body change and rolls back by redeploying 0347's body. **Residual, stated:** even at
lock 0, a weapon whose target died re-locks to a different enemy than its sibling under `spread`,
where today both take the same nearest. Small on today's content, large the day a second gun is
fitted.

---

### 0349 — `player_hulls_stop_pretending_to_have_places`

**Scope. Cleanup only, and only after 0346 has run a measured window in production.** Null
`combat_units.pos_x/pos_y` for `side='player'`; add a **VALIDATED** CHECK that `side='player'` implies
`pos_x is null`, so the duality becomes impossible rather than merely unused. Drop the now-unwritten
`danger_level` column.

**Self-assert.**
1. **Negative test, inside a savepoint:** inserting a `side='player'` row with a non-NULL `pos_x`
   **raises**, the constraint name is asserted, the savepoint rolls back. Mirror: the same insert
   with `pos_x` NULL succeeds. The constraint is asserted **VALIDATED**, not `NOT VALID`. *A "the
   CHECK exists and 0 rows carry a position" assert is trivially true on a fresh database where the
   proof built nothing.*
2. A frontend selftest **grep** fails the harness if `resolvePositionedUnits` still gates the player
   side on `pos_x` — the static guard that stops the class.
3. A fight created after the CHECK still ticks: arm selection no longer depends on the nulled column.
   *This is exactly why `v_is_spatial` had to move to `engagement_x` in 0346 — nulling these columns
   first would flip every live fight onto the arm 0345 deleted.*

**Rollback boundary.** Drop the CHECK and repopulate player `pos_x/pos_y` from `engagement_x/y` in
one statement, then redeploy 0346's client. Deliberately separated from 0346 so the core change has a
clean rollback boundary that does not depend on restoring data.

---

### 0350 — `a_fight_you_can_finish`  ***GATED ON Q1. DO NOT CUT THIS BRANCH WITHOUT THE OWNER'S WORD.***

**Why it is gated.** The live engine carries the owner's own words on this subject, at
`pct.sql:968-971`:

> *"the whole point of this game is never to win, but exit appropriately, by setting HP limitation or
> something, then it retreats outside the combat zone."* — with the engine's own note: **"Waves are
> endless BY DESIGN; the skill is leaving in time."**

A garrison-based victory condition **contradicts a recorded owner ruling**. Building it on an
assumption is the exact failure this contract exists to end. So it is Q1, not a slice — but it is
specified here so that a "yes" is one branch away.

**Scope if approved.** An authored garrison (a wave count on the encounter profile / binding —
content, not code) with rows for Snare, Reaver and Blackden; `combat_encounter_wreck`'s sibling
`completed` outcome when the last authored wave clears; the 1800 s arm (live 285-290) demoted to a
plain timeout ⇒ `escaped`; `pirate_loot_for_wave`'s depth ladder replaced by a `site_loot` row table
(`location_id, item_id, quantity, weight, min_wave`) with `p_danger` dropped; and the client stating
**"wave 3 of 5"** so the end is visible — a win the player cannot see coming is not a win condition.

**Self-assert if approved.** A garrison-2 site cleared **twice** ends `completed` with a banked haul
(the first `completed` the ledger will ever contain), and the **same** fight held past
`max_presence_seconds` ends `escaped` and never `completed` — both directions, so the assert cannot
pass by the arm never firing. The `next_wave_at` rewind is explicit (live 471 pauses the wave and
`now()` is frozen, so a garrison-2 fixture that does not rewind can never clear wave 2). Garrison
must be ≥ 2 in the fixture; a garrison of 1 does not prove a garrison. `pg_proc` shows exactly one
`pirate_loot_for_wave` arity and no `p_danger`. Every active pirate_hunt site returns ≥ 1
`site_loot` row.

**New-table rule, non-negotiable:** `site_loot` and the garrison carrier must **REVOKE** client
insert/update/delete in their own migration. Supabase's project default grants client verbs on every
new public table and CI has no such default, so a migration that *asserts* the posture aborts on
deploy while one that *revokes* cannot. 0254 learned this expensively.

---

## 5. THE PROOF PLAN

**Only the disposable-Postgres leg is a gate.** `supabase start` applies 0001→head to a real database
and executes every migration's `do $$ … $$` self-asserts. It is the ONLY layer that runs them. The
harness selftest greps and balances blocks and does not parse SQL — a missing `begin` passed it twice
and died only on the real apply. A green selftest, a green merge and an agent's report are all
CLAIMS, not proof.

**Trigger width is part of every slice.** Every combat proof workflow touched here fires on
`slice-**`, not a narrow glob. Four proof suites were found dead in one session because they only ran
on the branches that remembered, and one had been unrunnable for ~100 migrations. When a slice
changes a verb, its proof's trigger widens **in the same slice** — otherwise the proof it just
repointed gates nothing.

### The traps, each disarmed by construction

| Trap | How it bites here | The disarm |
|---|---|---|
| **Ambient defaults** | `combat_encounters.danger_level` has `column_default = 1, NOT NULL` (measured). 0344's headline assert is "danger is exactly 1" — a fixture the tick never reaches reads the default and passes while `+ waves_cleared` is still in the body. | **Poison the observable**: set `danger_level = 99` before every tick, then assert. Plus a liveness assert (rows examined, `tick_number` advanced, a `combat_ticks` row from this run). Every knob a proof depends on is WRITTEN in-txn — `max_presence_seconds_default`, `danger_time_divisor_seconds`, `emergence_radius`, `combat_lock_ticks_default`, `combat_tick_logging`, `combat_event_logging` — never read from the seed. |
| **Vacuous premises** | 0345's "every hull `hp<=0` ends defeat" is caught by arm A at live 240 and passes on today's body. 0346's "every player row is at distance 0" quantifies over a set 0349 empties. 0347's clearance quantifies over player rows that no longer exist. | Every for-all assert first asserts the set is **non-empty and NULL-free** with an expected row count. Every fixture is built to the shape of the code path being tested, and the arm it exercises is named in the block. |
| **Zero-margin compares** | Player range 5 vs pirate range 4 makes the kite rest distance exactly 5.0; which side of the sqrt it lands on is decided by float error and uuid ordering (the recorded DEADFIRE vacuity). "Distance EXACTLY 0" is a bare float equality. | No zero-margin float comparison survives. Tolerances are stated: `<= 1e-9` for identity, `1e-5` for the standoff (its own rounding), an explicit margin band for the kite rest. Arrival windows are derived from the fixture's geometry, never a literal tick count. |
| **Pre-move vs post-tick** | The fire gate reads the frozen pre-move distance (live 620-632, 698-701) while the client draws post-tick positions. An assert that recomputes `osn_distance` from post-tick rows and compares it to itself is a tautology that passes while D1 is broken. | 0346 adds the gate's distance to the `missile_salvo` payload — a real channel — and asserts it against post-tick geometry to 1e-9, cross-checked against `impact_delay_ms` at exact integer equality. |
| **Frozen transaction clock** | `now()` never advances in-txn. A wall-clock lock can never elapse; `next_wave_at` (live 471) permanently pauses wave 2. | The lock is a **tick counter**, not a timestamp. One documented rewind helper applies the full set per simulated tick: `last_resolved_at`, `next_wave_at`, `next_ready_at`. |
| **The Haven (-150,-90) zone-overlap trap** | `port_entry_commission_build` docks every starter at Haven. A proof block that draws a zone over that point makes a *later* block's leg begin inside a zone → entry fraction 0 → `trigger_at = now()` → an ambush fires instantly, reddening a proof ~2,000 lines away. Compounded here: the seeded zones are rebuilt with `random()` on every fresh CI database. | Every proof in this programme **draws its own zone and site**, at a coordinate screened against the port guard at the drawing site. No block asserts the seeded world. |
| **`select into` takes the first row silently** | This programme adds many multi-row fixture reads: per-weapon salvos, per-enemy wave rows, the 93-cell danger sweep. | Every set read is an aggregate, or explicitly `order by` + `limit` with the row count asserted first. A harness selftest grep fails on a bare `select … into` over a set in the new proof files. |
| **Harness-vs-drop** | The harness is part of the surface being retired. Counted this session: `spatial_formation_ring_radius` **52 hits / 7 files**, `pos_x` **161 hits / 9 files**, `combat_formation_point` **45 / 5**, `combat_wave_arrival_phase` **16 / 5**, `combat_translate_player_formation` **1 / 1**. A block writing a deleted knob does not error — it silently stops establishing its precondition and goes green where it should be red. | Enumerate the surface **before** cutting each branch and repoint the whole class in ONE pass. Keeping `combat_wave_arrival_phase` and `combat_formation_point` (§2 #14, §4/0347) removes 61 of those references from the risk. |
| **Prod body ≠ CI chain body** | 0343 re-emits from `pg_proc.prosrc` and every later slice text-patches it. CI patches the body the CHAIN produced. If they differ, either the anchor is missing on prod (0343 aborts and holds 0344-0350 hostage, as 0333 did) or it matches a different site and patches the wrong hunk, green. | The prod hash is captured here: **`md5 = 3806e89a97237bf00f593ad38a834580`, 99,286 chars, 2026-08-08**. 0343 records the same hash before it patches and raises if it differs. **I could not compute the CI-chain hash from this machine — there is no local Docker — so this comparison is UNVERIFIED and is a required pre-flight for the implementer, not a finding.** Every slice asserts its anchor's occurrence count in both directions: found exactly N before, 0 after. |
| **Never weaken to green** | A red apply-proof is diagnosed, never merged past. 0345 deletes an arm and 0348 replaces a function signature; any fixture invoking them is repointed onto the replacement in the same slice. | A migration that cannot deploy holds every later migration hostage. Nothing in this chain merges before it can deploy. |

### The properties proved — what the PLAYER experiences, each with its anti-proof

- **Killing well changes nothing.** 93 cells of (`waves_cleared` × `secs_inside`) produce identical
  wave size, hp, attack and payout — with the observable poisoned and liveness asserted.
- **A fight the engine cannot represent does not kill the fleet.** Living hulls with no positions end
  `escaped`, fleet alive, haul banked, zero ships destroyed — and it terminates rather than hanging.
- **A departure is not a wreck.** A retreat with a haul keeps the haul, marks survivors `'returning'`
  and destroys nothing.
- **The circle is the rule.** The gate's logged distance equals `osn_distance(engagement, target.pos)`
  from the post-tick rows to 1e-9, cross-checked through `impact_delay_ms`, and a pirate still fires.
- **A chase and a reposition are both MOVES.** The anchor moves by more than zero and no more than
  the fleet's speed, over five ticks, with exactly one step spent on the tick that carries an order.
- **Enemies travel from the city.** Every spawned row is within the emergence radius of the SITE and
  clear of the fleet's reach, and its distance strictly decreases with no step larger than its own
  speed, inside a derived window with a stated margin.
- **A weapon aims before it fires.** No salvo before tick N+2 and a salvo ON N+2.
- **W weapons, W locks.** Two distinct target ids under `spread`; two salvos at one target under
  `focus` and when only one enemy lives.
- **Silence is a bug.** No `wave_spawned` without a body — 223 bodiless ones exist today.

**Then, and only then, the live gate.** Prod head is verified by querying
`supabase_migrations.schema_migrations` directly, never from a green CI run; the client half by
grepping the deployed bundle for the new identifiers. Then the fight is **played in Chrome** — send a
fleet, take a wave, watch the ring, watch the emergence, reposition, retreat. That is the step that
has found every real defect in this project, and the owner should never be the one discovering them.

---

## 6. BALANCE, MEASURED

Every number below was read read-only off production this session or by the mapping agents this
session. Anything not measured is marked **UNMEASURED** and is not to be reasoned into place.

### The ledger

**44 encounters, all time: 19 defeat, 25 escaped, 0 completed, 0 currently live.** (Verified by me
this session; the brief said 43 — one further escape has landed.) Escaped average 130 s, defeat
average 138 s, longest fight ever **398 s**.

**0 wins in 44.** What this design does about it, plainly: **it does not silently invent a win.** The
only win arm needs `v_secs_inside >= 1800` (live 285-290) against a longest-ever fight of 398 s —
22% of the clock — and the player cannot heal inside a fight (`shield_regen_combat_pct = 0`,
measured) while wave HP scaled forever. It is arithmetically unreachable, not mistuned. But the
engine also carries the owner's own words that **winning is not the point** (`pct.sql:968-971`,
quoted in §4/0350). Those two facts point in opposite directions, so the contract ships the deletion
that makes *staying* a real choice (D3) and puts the victory condition to the owner as **Q1**. What
0344 changes on its own: the 43% defeat rate. Escalation-on-kill is what makes "leave in time"
impossible to judge — the fight that punished you for winning is the one you could not read.

### Escalation-on-kill, measured firing

| encounter | site | wave → bodies → wave hp |
|---|---|---|
| `520a35c0` | Snare | 1→1→203, 2→2→319, 3→3→427, 4→4→505, 5→5→545, 6→6→587, then capped at 6 bodies while hp → 1036 (5.1×) |
| `953fe570` | Snare | identical shape, 223 → 957 |
| `6b6f5ff0` | Reaver (aggregate arm) | danger 1 → 19, wave hp 362 → 2860 |

### The counterfactual is arithmetic, not an estimate

`round(10 × max(reward_tier,1) × (1 + 0.25 × danger_level))` was validated against **all 57 logged
payouts — 0 mismatches** — and only then used. Deleting the escalation term: metal Reaver 1115→435,
Snare 737→504, **total 1852 → 939, −49.3%**. **Items unchanged** (57 scrap, 38 pirate_alloy, 23
weapon_parts, 11 engine_parts, 8 repair_parts), because `pirate_loot_for_wave` accepts `p_danger` and
never reads it. So "removing kill-escalation zeroes progression" is refuted at the source: the metal
faucet halves and `reward_metal_base` 10→20 restores it exactly. **That is the owner's call — Q3.**

### What the D3 deletion gives back, and what D4 costs

Measured 2026-08-08: every player shot lands (146 salvos / 146 hull_damage events). Player 2.49
salvos/tick at 14.94 damage ≈ **12.3 dps**; pirate 2.39 at 5.12 ≈ **4.0 dps**. 23.8% of player firing
ticks contain a kill and carry 3.09 salvos, so ~29% of all player salvos are thrown on kill-ticks.

- Breaking the whole volley's lock on a kill costs up to **~29%** of dps; breaking only the killing
  weapon's costs **~10%**. (Q4.)
- One lock per weapon per wave: 5.07 waves × 2.49 firing weapons ≈ 12.6 of ~105 salvos ≈ **12%**.
- **Total D4 cost: a 20–40% player dps cut.**
- **D3 pays for it with margin:** at the average fight (43.5 ticks, 3.09 waves cleared) danger fell
  from ~4 to 1, which cuts enemy COUNT 4→1, enemy HP from ×3.4 to ×1.6 (**−53%**) and enemy attack
  from ×2.0 to ×1.25 (**−37%**). **So no compensating damage buff, no extra knob and no reward change
  is introduced** — a third balance authority is how the ledger became unreadable.
- **The cost is NOT symmetric, and saying otherwise would be dishonest:** 347 enemy units destroyed
  by players against 106 player hulls destroyed by pirates — **3.3:1**. A rule that names no side is
  still a player tax.
- **The post-move fire gate (0346) is a separate, unbudgeted change:** both sides land their first
  shot one tick earlier than the baseline these numbers were computed against. **UNMEASURED**; it
  gets its own before/after in 0346's merge-wave note.

### Timing

Tick **3.03 s** (median 3.02, p90 3.03, over 543 consecutive pairs). Client poll ~1500 ms. Weapon
cooldowns are all 2 s — **below the tick**, so the cooldown gate is inert as a rate limiter today and
cannot absorb a lock. **Any lock under ~3 s is invisible**, so the only meaningful values are whole
ticks — which is why `lock_ticks` is a tick count. **Seed it at 1 tick, derived from
`combat_tick_seconds`, never written as a literal 3. Whether 2 ticks reads better than 1 is
UNMEASURED and must be decided by playing.**

### Emergence geometry

`territory_radius = 12.0` at all three active sites, and `combat_site_standoff_point` returns a point
exactly 12.0000 from the site. Snare's enemy speed is `0.6 + 0.04 × 10 = 1.0`/tick, so a wave leaving
the city reaches a fleet at the standoff in **4 ticks ≈ 12 s**, against a measured ~26 s per wave
(130 s ÷ 5.07). Today's spawn radius is 12.10 against an anchor→site distance of 23.85, putting every
pirate 11.75–26.75 from Snare. **The 12-second approach has never been played — the FEEL of it is
UNMEASURED, and 12 s against a 26 s cadence could read as dead air. The emergence radius is a row
precisely so that is a row edit, not a deploy.**

### The reward curve is inverted per sortie

| site | difficulty / tier | sorties | waves | metal | items |
|---|---|---|---|---|---|
| Snare | 10 / t1 | 28 | 98 | 1212 | 121 |
| Reaver | 15 / t2 | 4 | 34 | **0** | **0** |
| Blackden | 25 / t3 | 12 | 4 | 152 | 4 |

Reaver's one tick-logged fight **earned 1115 metal and banked nothing**, dying with 100% of 2040 hull
lost. Snare pays 7.97× Blackden's metal and 30.25× its items; per sortie, 3.4× and 13.1×. Per
*second* the curve is not inverted (Blackden 1.81 metal/s vs Snare 0.44) — the inversion is per
sortie and per hull risked, which is the unit the player spends.

### Depth, and where loot dies

21 of 25 extractions happened at depth ≤ 7 waves. **Depth ≥ 8 is 5 deaths to 1 extraction.** The loot
ladder's deep gates sit exactly on that wall: engine_parts at wave 8 (11 earned, **1 banked**),
repair_parts at 10 (8 earned, **0 banked**), blueprint_fragment at 8 — the shipyard build-gate's only
repeatable faucet, drop rate 0.15 — **has never dropped once**. Garrisons of ~3 / 5 / 8 for
Snare / Reaver / Blackden would sit inside what players actually reach; **these are content
proposals, they cannot be validated against measured wins because there are none, and the real
numbers are the owner's and must live in rows.**

### D5 is nearly inert on today's content — worth saying out loud

**76 of 77 ships have zero fitted weapons**; one (the SpatialCanary hull) has 3. Only **2 of 249**
`combat_units` rows in the game's history carried more than one weapon, and **115 of 115** enemy rows
ever carried exactly one. Player ranges are uniformly 5, pirate uniformly 4 — which is why both
client range aggregations are latent today. They go live the instant a second gun is fitted, which is
exactly why they are deleted now rather than when they start lying.

### Two knobs that exist in no migration and will silently revert

`combat_hit_variance_pct = 0.5` and `travel_scale = 0.1` were set by hand. Deleting either row changes
the game with no migration to explain it.

---

## 7. OPEN QUESTIONS FOR THE OWNER

Five genuine forks. Each has my recommendation, so a "yes" is enough.

**Q1 — Should a site have a finite garrison, so a fight can be WON?**
The engine records your own ruling at `pct.sql:968-971`: *"the whole point of this game is never to
win, but exit appropriately."* A garrison contradicts that, so I will not build it on assumption.
Measured: 0 completed in 44; the only win arm needs 1800 s against a longest-ever fight of 398 s.
**My recommendation: YES — give each site an authored garrison (Snare 3, Reaver 5, Blackden 8, as
rows), and keep the exit as the skill.** "Exit appropriately" and "the garrison is spent" are
compatible: the garrison is what gives the player something to judge the exit *against*. Without it,
after D3 a fight simply never changes, and the only pressure is attrition. Say yes and 0350 is one
branch away; say no and 0350 is deleted from this contract and the 1800 s arm is demoted to a plain
timeout instead.

**Q2 — One fleet combat speed. What is it?**
Once movement is fleet-level there is exactly one fleet, so there must be one number — and today
there are two: an ordered reposition moves at `min(move_speed) × combat_reposition_speed_scale (=8)`
≈ 1.6/tick, a hull chasing its own target at 0.2/tick, while enemies close at 1.0–1.6. Adopting 1.6
for everything makes the player match or exceed every closing enemy — the unbreakable kite your own
recorded ruling forbids (`0316:754-762`; I raised `combat_player_speed_scale` once and reverted
within a minute). Adopting 0.2 makes crossing a zone take minutes.
**My recommendation: ONE speed, set strictly BELOW the slowest pirate at every active site — measured
pirates are 1.0–1.6/tick, so the fleet moves at ~0.7/tick — and shrink the distance instead of
raising the speed.** With the standoff at `territory_radius = 12`, a meaningful reposition is 12–24
units, i.e. **~15–35 seconds**, not minutes. One authority, anti-kite preserved, no boolean that
selects between two speeds. *(I am not blocking 0346 on this — the constraint is derivable and safe —
but the number is yours.)*

**Q3 — Metal after the 49.3% cut.**
Deleting the escalation term takes metal from 1852 to 939 across the 57 measured payouts.
`reward_metal_base` 10 → 20 restores the total **exactly**. Item progression is untouched either way
— that is measured, not estimated. **My recommendation: raise it to 20** and keep the economy where
it is while combat changes underneath, so that if the fights feel wrong you are reading one change,
not two. This is an economy-wide decision affecting ~30 live players and it is not mine to fold
silently into a combat slice.

**Q4 — When a target dies, does the whole volley lose its lock, or only the weapon that killed it?**
This one choice is the difference between a **~29%** and a **~10%** player dps cut, measured. Your
words — *"it takes time for every fleet to lock a target, then attack"* — read as the whole volley.
But that deliberately re-creates, as a game rule, the exact defect 0336 was written to end
(`pct.sql:750-757`: *"A KILL DOES NOT DISARM THE REST OF THE VOLLEY"* — dropping guns 2 and 3 on a
kill tick was two thirds of a ship's damage gone).
**My recommendation: only the killing weapon re-locks.** The other guns keep firing at what they
were already locked onto. It costs ~10% instead of ~29%, and it reads correctly on screen: each gun
has its own reticle, and only the one whose target exploded swings to a new one. Paired with this:
**allocation is your order, not the engine's** — a `focus` / `spread` toggle on the combat card,
defaulting to `focus`, so two guns stack on one enemy unless you tell them to split. That is both
halves of what you described.

**Q5 — If a fight can be completed, is it repeatable?**
Only live if Q1 is yes. Once "the garrison is spent" wins, the site either goes quiet for a cooldown
or re-entering restarts the garrison and the win becomes farmable. That single choice decides whether
`completed` is a one-shot content beat or the game's main income loop, and every reward number after
it depends on the answer. There is no data to infer it from — the ledger contains zero completions.
**My recommendation: repeatable with a per-player site cooldown (a row on the binding), starting at
one real-time hour.** It keeps hunting as the income loop you already have, and the cooldown is a
row, so it is tuned without a deploy.

**Not questions — decided here, stated for the record.** The haul does **not** survive a defeat and no
salvage mechanism is proposed: moving loot onto site rows (0350) breaks the perverse coupling where
deep loot required the depth that kills you, so no wreck-salvage is needed to fix the measured
problem (10 of 11 engine_parts and 8 of 8 repair_parts ever dropped died with the fleet that earned
them). If you want a wreck to leave something behind anyway, that is its own slice with its own
content — say so and it gets one.

---

## 8. DOC CHANGES THAT LAND WITH THE CODE

1. **DELETE `docs/TARGET_CAPACITY_RULING.md`** — superseded, stated plainly in the commit; no
   reconciliation section, no level table behind a flag. **First, re-home its two trailing standing
   rulings verbatim** into `docs/COMBAT_DESIGN_LAWS.md`: *"Rejected: a player-configurable
   combat-speed control"* (`:144-156`) and *"Rejected: a fleet-level range slider"* (`:158-167`).
   Those are owner rulings on other subjects and deleting them by association would lose them; the
   anti-kite invariant they cite (`0316:754-762`) is load-bearing for Q2.
2. **CREATE `docs/COMBAT_DESIGN_LAWS.md`** as the ONE place the combat rules are written: the four
   laws recorded on 2026-08-04 plus D3/D4/D5 in the owner's own words, and the sentence this
   programme is built from — *the fleet is one actor at one point; each weapon is one lock and one
   attack; enemies emerge from the site and travel; a reposition and a chase are both moves*. It
   cites **authorities, never numbers**: a design note that justifies itself with a value dies the
   day that value changes (0311 justified an instant teleport with "weapon range 120+"; 0316 cut
   every range 5× and nobody revisited the comment; the owner found the bug by playing).
3. **REWRITE `combat_create_encounter`'s header** and delete the presence-hash sentence
   (`cce2.sql:44-49`; repo `0339:702-706`). Implement it or delete the claim.
4. **REWRITE the four "One leaf, called by all four arms" comments** (live `pct.sql:248`, `:310`,
   `:943`, `:1359`). After 0343 the sentence is true once, inside `combat_encounter_wreck`.
5. **REWRITE `src/features/map/combatActors.ts`'s header** — its *"WHERE THE ONE GLYPH STANDS —
   composed, not re-derived"* paragraph documents composing `fleetFightPosition`, which 0346 deletes.
6. **REWRITE `src/features/combat/encounterAnchor.ts`'s header** — it says the anchor *"is NOT where
   the fleet currently is"*. After 0346 they are the same question with one answer.
7. **UPDATE `docs/DEV_LOG.md` and `docs/ROADMAP.md` per merge-wave** — the ONE roadmap, never a
   second plan file — recording for each slice what shipped, what was DELETED, and the measured
   before/after.
8. **UPDATE the memory:** add D3/D4/D5 to `byeharu-combat-design-laws.md`, add a resume anchor
   superseding `byeharu-resume-2026-08-04.md` with prod head, this slice order, and the corrections
   verified this session — then update `MEMORY.md`'s index, because an unindexed memory is one nobody
   reads.

---

## 9. APPENDIX — EVERY REVIEW OBJECTION AND ITS DISPOSITION

Three adversarial reviews raised 29 objections (5 blocking). **All five blocking objections are
resolved by amendment. One objection is partially rejected, with a reason.**

### Ground-truth corrections made against the brief and against the design, verified by me

| Claim | Verdict |
|---|---|
| "Three byte-identical fleet-died blocks" | **False as stated.** Live 955-959 and 1371-1375 are identical to each other and to arm A's 260-264, but arm A's UPDATE (265-267) carries four more columns and a `combat_ticks` insert (269-272) that C and D do not. |
| "The two wave-clear blocks DISAGREE" | **False** — the `v_cleared` predicates are equivalent (live 875 vs 1228 nested inside `if v_offense` with 1236 setting false). **But they differ elsewhere**, which the design missed: the spatial arm has the E3 authored-reward branch (882-887) the aggregate arm lacks; `v_hp_after` is side-filtered at 876 and unfiltered at 1300; `enemy_integrity_current` is `greatest(0,…)` at 917 and `case when v_cleared then 0` at 1335; `v_seq` increments inside the log guard at 894 and outside it at 1313. **So `combat_wave_clear` is not minted at all.** |
| "A third wave path at live 1210-1217" | **Not a spawn path** — it inserts no `combat_units` row. It is the aggregate arm announcing a wave with no body. Deleted with the arm. |
| "43 encounters" | **44**, verified this session. |
| "0341/0342 are taken" | **Verified across all 271 origin refs.** Max = `20260618000342`. Next free 0343. |

### Dispositions

| # | Objection (source) | Disposition |
|---|---|---|
| A1 / B2 / C1 | **BLOCKING** — arm B (retreat) is not a copy of the defeat block and cannot go through a `(encounter, outcome)` leaf | **AMENDED, verified myself** at live 289-434: `release(...,false)`, retreat target read while consumed (373-376), per-hull `'returning'` vs destroyed (414-418), `movement_attach_cargo` (420-422), `retreat_completed`. Arm B is removed from every consumer list, named as its own concept ("a departure"), and 0343 gains a departure-shaped self-assert. Assert (a) becomes *exactly once*, not zero. |
| A2 | **BLOCKING** — 0347's asserts are mutually exclusive; NULL player positions disarm every pirate and blank the client | **AMENDED.** The tick's freeze (live 623-632) substitutes the engagement point for player rows — one server-side substitution replacing `resolveRenderPoints`. Assert becomes "every player row in the freeze carries the engagement point" **plus the anti-proof that a pirate still fires**. `resolvePositionedUnits` is repointed in 0346, not deferred. |
| B1 / A9 / C3 | **BLOCKING** — the aggregate arm's replacement guard destroys LIVING fleets | **AMENDED, verified independently against production**: 5 encounters had 0 positioned rows with 15/15/15/4 hulls alive, all ended `escaped`. The guard is now a **forced extract** through arm B — fleet alive, haul banked — never a wreck. Self-assert exercises exactly that shape and asserts the fleet survives. |
| C2 | **BLOCKING** — the danger sweep asserts a column default | **AMENDED, verified**: `danger_level` `default 1, NOT NULL`. The observable is poisoned to 99 before each tick, liveness is asserted, the rewind set is stated, and `max_presence_seconds` is written in-txn. |
| B3 | **BLOCKING-adjacent (high)** — 0344 routes 94% of live fights to a plan that does not exist | **AMENDED, verified**: 2 of 44 encounters carry a plan. 0344 backfills every non-terminal encounter and the tick resolves-and-stamps on demand; a plan-less fixture must spawn ≥1 unit. |
| A3 / B4 | Over-demolition of the `location_mode='space'` creator arm | **AMENDED, verified** at `cce2.sql:27-30`: it reads the fleet's own spatial state, so it is the same rule, not a second authority. **Kept.** One rule stated in the header; the emergence origin is already independent (`p_site_x/p_site_y`). |
| A4 | The three blocks are not identical; the leaf would double-log a tick | **AMENDED, verified.** The leaf takes arm A's UPDATE (a stated behaviour delta) and **no tick insert**; arm A keeps its own. Parity proved by per-call-site row counts. |
| A5 | After the deletions, `v_danger` survives only as a loiter-for-metal multiplier | **AMENDED — accepted and widened.** `v_danger` is deleted **entirely**, including the reward scale. Payout = `reward_metal_base × reward_tier`. Attrition (`shield_regen_combat_pct = 0`, measured) is the only remaining pressure, and that is stated rather than hidden. |
| A6 / B7 | Reorder: retire the aggregate arm before de-duplicating; `combat_wave_clear` would have one caller | **AMENDED, verified** (the two blocks differ in four ways). `combat_wave_clear` is **never minted**; the wave-clear de-duplication happens inside 0345 after the copy is deleted. |
| A7 | `combat_wave_arrival_phase` is origin-agnostic; the defect is the caller | **AMENDED, verified** by reading the leaf in full. It is **kept**, composed with swapped arguments. This also removes 16 fixture references from the harness risk and preserves the coincident-point guard whose loss reproduces `distinct_enemy_points = 1`. |
| A8 | Spread-vs-stack is hardcoded in `p_exclude` | **AMENDED.** Allocation becomes a per-fleet `focus`/`spread` order defaulting to `focus`, plus **Q4**. |
| A10 | The `committed boolean` speed is two speeds in one function's name | **AMENDED, and partially REJECTED.** Accepted: one speed, one authority, no boolean. **Rejected: "do not ship 0346 until the owner answers."** The anti-kite constraint is derivable from measured data (pirates 1.0–1.6/tick ⇒ fleet strictly below), so the slice is not blocked on an answer; the number is stated as **Q2** and the owner can overrule it. Blocking a slice on a question I can answer safely violates the standing "decide and DO" rule. |
| B5 | A pirate zone with no attached site has no stated behaviour | **AMENDED.** A pirate zone cannot be active without a bound location (content CHECK); a NULL anchor never routes to `'defeat'`. Verified: `danger_zones.location_id` is nullable and 10 of 14 rows are NULL, including the owner's own canary zone. |
| B6 | No arbitration between the chase and a live reposition | **AMENDED.** The order outranks the chase; exactly one step per tick; the proof runs a tick with a live order. |
| B8 | The post-move fire gate is an unbudgeted balance change | **AMENDED.** Declared in §4/0346 and in §6 as a separate, **UNMEASURED** change with its own before/after. |
| C4 | 0346/0347 break proof fixtures; only 0345/0348 were named | **AMENDED, counts re-derived myself**: `spatial_formation_ring_radius` 52/7, `pos_x` 161/9, `combat_formation_point` 45/5, `combat_wave_arrival_phase` 16/5, `combat_translate_player_formation` 1/1. Enumerated per slice, repointed in one pass. Keeping two leaves removes 61 references from the risk. |
| C5 | The 1e-9 gate-distance assert has no observation channel | **AMENDED.** The gate distance is added to the `missile_salvo` payload; `impact_delay_ms` is the integer cross-check. |
| C6 | The frozen txn clock defeats the lock and garrison asserts | **AMENDED.** The lock is a **tick counter**; one documented rewind helper covers `last_resolved_at`, `next_wave_at`, `next_ready_at`; the garrison fixture is ≥2 with an explicit `next_wave_at` rewind. |
| C7 | For-all asserts quantify over a set this programme empties | **AMENDED.** Non-empty + NULL-free + expected row count first, everywhere; `EXACTLY 0` becomes `<= 1e-9`; clearance restated against the engagement point. |
| C8 | 0350's CHECK assert is trivially true | **AMENDED.** Savepoint negative test + mirror + `VALIDATED` assertion. (Slice renumbered 0349.) |
| C9 | "Strictly decreases" has no window and a zero margin | **AMENDED.** Bounded to ticks where the pre-tick distance exceeds `my_range + margin`; per-tick step in `(0, move_speed + 1e-9]`; window derived from the fixture. |
| C10 | Prod body may differ from the CI chain body | **AMENDED, partially unverifiable from here.** Prod hash captured (`3806e89a…`, 99,286 chars). 0343 records and compares it. **The CI-chain hash could not be computed on this machine (no local Docker) — that comparison is a required pre-flight, not a finding.** |
| C11 | `select … into` first-row trap is missing from the disarmed list | **AMENDED.** Added to the trap table with a harness grep. |
| A-misc | "The design overstates what per-weapon targeting replaces — live 764-772 already re-acquires when a target dies" | **ACCEPTED as a correction.** §1/D5 says targeting is resolved once per HULL above the loop (live 698-701), which is true; the claim that every gun fires at one row is qualified — it holds while that row lives. |

---

*Written 2026-08-08. Read-only against production throughout: no write, no migration, no merge, no
deploy. Prod head 0340; next free migration 0343.*
