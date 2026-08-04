# 0339 — A FIGHT YOU CAN MOVE IN

Design note for migration `20260618000339_a_fight_you_can_move_in.sql`.
Written BEFORE the SQL, as the composition decision record. Read this before reviewing the diff.

Head at authoring time: production `20260618000338`, verified on target 2026-08-04.
The tick body is re-read every 3 s, so the next tick of every running fight — for every player —
runs the new body. There is no drain and no opt-in. Everything below fails closed.

---

## 0. WHAT THIS SLICE IS FOR

Two owner reports, and three pieces of spaghetti that three migrations created in one night.

* **"The enemy ships are not comming out from the location - snare."** — 0338 is INERT on every
  hunt, by construction. Fixed by moving the ANCHOR, not the leaf.
* **"When fighting, i am not able to move my fleet."** — a hunt-site fight could never reposition,
  and the same button silently RETREATED instead. Fixed, not refused.
* Player reposition was ~0.16–0.26 world units per 3 s tick — about 1/16 px at playable zoom, and
  4–10× slower than the pirates chasing it. Fixed with a knob that scales ONLY the fleet-move leaf.
* **Spaghetti A**: two writers of `combat_encounters.engagement_x/y`, with 0301's guard spent.
* **Spaghetti B**: the enemy-spawn loop forked in two, differing only in indentation.

ONE migration. Five things. Splitting them is how last night's three migrations ended up
re-pointing each other's proofs three times.

---

## 1. SPAGHETTI A — TWO WRITERS OF ONE COLUMN, AND A GUARD THAT NEVER RE-RAN

### What is actually there

`20260618000301_intercept_fires_at_zone_entry.sql:820` declares the creator's INSERT
*"the only write of engagement_x/engagement_y in the database"*, and `:2556-2566` ships a schema
sweep that RAISES if any function's source matches `set\s+engagement_x`.

`20260618000337_reposition_is_a_move.sql:486-492` then added exactly that write inside
`process_combat_ticks`. **The 0301 assert does not re-run**, so the drift landed silently. A stated
invariant with no live check is not an invariant — it is a comment.

Say it plainly: **spaghetti**. Two functions writing one column, with the rule asserting there is
one.

### The resolution

The concept is not "who may touch a column". It is **"where does this fight stand, and what moves
when it moves"** — and that answer has three inseparable parts, because a fight that moves its
anchor without moving its formation and its map marker is three positions disagreeing:

```
combat_encounter_move(encounter, fleet, to_x, to_y, from_x, from_y)
  1. combat_translate_player_formation(encounter, to-from)   -- the ONE rigid translate
  2. combat_fleet_track_position(fleet, to)                  -- the map marker (see §4)
  3. update combat_encounters set engagement_x/y = to        -- the anchor
```

**ONE authority. Composed by the tick's reposition step and by nothing else.** 0311's order arm
used to do the same three writes inline; 0337 deleted them from there; this slice makes the
remaining copy a named leaf so a fourth site cannot grow beside it.

The creator's INSERT is untouched and stays the only place a fight's anchor is *established*.
`combat_encounter_move` is the only place it is ever *changed*.

### The guard that actually re-runs

0301's sweep ran once, at 0301's deploy. That is the whole failure. The re-armed guard lives in
**two** places that re-run on every PR and every merge:

* `20260618000339`'s own self-assert (b) — the same schema-wide `set\s+engagement_x` sweep, but it
  now demands the writer set be exactly `{combat_encounter_move}` rather than empty. It runs on
  every apply of the chain, which in this repo means every CI `supabase start`.
* `scripts/danger-combat-proof.sql`, block `DZCOMBAT_PASS_ONEANCHOR` — the same sweep against the
  fully-applied chain on a real Postgres, plus proof that the tick composes the leaf exactly once
  and that the leaf really moves all three things together. That suite is triggered on
  `pull_request` AND on push to `main`, so it gates every route into production.

Honest limitation, stated rather than glossed: this is a **CI-time** guard, not a runtime one. A
trigger on `combat_encounters` could enforce it on production forever, and it was rejected for this
slice: a raise inside a BEFORE UPDATE trigger on that table would fire on every encounter update of
a live 30-player game, which is a strictly worse blast radius than the drift it prevents. CI runs
before every deploy; that is the level at which this class is caught here.

---

## 2. SPAGHETTI B — ONE SPAWN LOOP, WRITTEN TWICE

`20260618000338_enemies_come_from_the_zones_city.sql:252-253` (resolved-plan arm) and `:279-280`
(synthetic arm) are the *same* ~15 lines at two indentations: measure the formation extent, zero the
slot counter, loop the count, ask `combat_formation_point` at
`extent + range + 1` with `combat_wave_arrival_phase`, INSERT, bump the slot.

Every migration since 0299 has had to patch both in lockstep. Most of 0338's guard machinery exists
only to police that fork (assert (b) counts the leaf composition *twice*, and the radius expression
*twice*). **Spaghetti.** Ripped out here, not written up.

### The fold

```
combat_spawn_wave_units(encounter, player, unit_type_id, count,
                        unit_hp, speed, range, projectile_speed, unit_power, cooldown,
                        anchor_x, anchor_y, site_x, site_y, slot_from) -> next slot
```

The **placement** is inside: the measured extent, the radius, the formation point, the arrival
phase, the INSERT, the slot walk. Each arm becomes ONE call.

**The difference between the arms is real and it survives.** It is exactly the STATS: the resolved
arm takes `unit_type_id`, hp, attack, range and speed from the authored plan's unit archetype; the
synthetic arm derives them from `loc.base_difficulty` and the knobs. Those are the arguments. What
is deleted is the duplicated *loop*, which never differed at all.

Consequences that follow for free:

* the extent is measured in ONE place, so the two arms can no longer drift apart on it;
* the wave radius `extent + range + 1` — 0336's structural clearance — appears ONCE;
* `v_formation_extent`, `v_slot_x`, `v_slot_y` leave the tick's declare block with their last use.

`v_spawn_slot` stays in the tick, because the resolved arm carries it ACROSS archetypes so a plan of
several unit types still lays out one ring. That is the one piece of state the fold cannot own.

---

## 3. THE OWNER'S BUG — "THE ENEMY SHIPS ARE NOT COMMING OUT FROM THE LOCATION - SNARE"

They are right, and 0338 could never have worked on a hunt.

### The measured cause

1. A hunt arrival leaves the fleet `present` at the site.
2. `20260618000301:924-933` therefore takes the `else` branch and stamps
   `engagement_x/y` = **the site's own coordinates**.
3. The tick resolves `v_anchor := coalesce(e.engagement_x, loc.x)` (`20260618000299:477-478`) —
   both operands are now the same point.
4. `combat_wave_arrival_phase` hits its exact-equality guard (`20260618000338:199`) and returns the
   neutral `0.5`.
5. So raiders lay out on a plain 225° ring instead of a 112.5° arc from the city. **Permanently, on
   every hunt.**

The ambush path works only because the resolver parks the fleet in open space first, so its anchor
is tens of units from the site.

### Root cause: one datum doing two jobs

`locations.x/y` is simultaneously **where the fight is** and **where the enemy comes from**. No
amount of work in `combat_wave_arrival_phase` can separate them — the leaf is correct and is not
touched except for the epsilon in §3b.

### The fix — ONE leaf, at the point the anchor is decided

```
combat_site_standoff_point(site_x, site_y, territory_radius, seed) -> (x, y)
```

*"Where does a fight AT a site stand?"* On the EDGE of that site's own territory — the datum the
world already carries for "how far out does this place reach" (`locations.territory_radius`, 0217;
12 for Snare in production, 35 for `pirate_hunt` in a fresh chain). The bearing is a deterministic
hash of the presence id, so two fleets hunting the same site do not stack, and the same fleet's
fight is stable across ticks.

It is composed by `combat_create_encounter`'s `else` branch — the ONE place that decides where a
site fight stands — and by nothing else. **No inline branch in the tick. No second spawn path.**
0301's own rule survives verbatim in a sharper form: *a fight happens where its fleet is; a fleet
present at a location fights on that location's edge, facing it.*

Fail-closed arms, all of which reduce to today's behaviour:

* `territory_radius` NULL or ≤ 0 → there is no edge to stand off, so the fight anchors ON the site
  and the wave falls back to 0336's plain ring. Honest, and unchanged from today.
* the location row is gone → the lateral yields no row and both coordinates stay NULL, which is the
  exact shape the creator has always produced for a vanished location.

Live fights are unaffected: they carry a stamped anchor already and nothing rewrites it.

### 3b. THE EXACT FLOAT EQUALITY

`20260618000338:199` asks `p_site_x = p_anchor_x and p_site_y = p_anchor_y`. A fight one ulp off the
site therefore computes a *real* bearing from a sub-unit displacement — i.e. an arbitrary direction
that flips with the last bit of a subtraction.

Replaced with a separation test against **0.5 world units**. Why 0.5 and not 1e-9: ordered
coordinates are canonicalised onto the INTEGER world grid before anything reads them
(`command_ship_group_go` step 3), so half a grid cell is the point below which "the fight" and "the
site" are the same place at the resolution the world actually stores. A bearing taken from less than
that is float noise, not a direction, and it must fall back to the ring. The standoff of §3 puts a
real site fight a whole `territory_radius` out, so this test never fires on the path it protects.

---

## 4. THE OWNER'S BUG — "WHEN FIGHTING, I AM NOT ABLE TO MOVE MY FLEET"

Two separate defects.

### 4a. A hunt-site fight could NEVER reposition, and the same button RETREATED

The reposition arm (`20260618000337:306-364`) required all three of:

| condition | hunt fight |
|---|---|
| (a) encounter `status = 'active'` | ok |
| (b) `combat_encounter_zone_admits_point` — an ACTIVE danger zone containing both anchor and destination | **fails** (a hunt site need not be inside any drawn zone) |
| (c) `fleets.location_mode = 'space'` | **fails** (the fleet is `present`) |

Control then fell through to the 0298 retreat arms (`20260618000301:1718-1740`), which returned
`ok:true` / `retreat_started`. **The player asked to move and broke off the fight instead.**

0337 kept reposition open-space-only because the `fleet_set_in_space` ↔ live-`present`-presence
interaction was **explicitly UNVERIFIED** (`20260618000337:355-361`).

**Verified now, from the deployed body:** `fleet_set_in_space`
(`20260618000231_movement_schema_drop.sql:1146-1170`) writes `status = 'idle'`,
`location_mode = 'space'` and **`current_location_id = null`**. Calling it on a fleet that holds a
live `location_presence` row would leave the presence dangling against an `idle` fleet with no
location, while the tick still runs the fight and later calls `presence_complete` on it. The
concern was correct. So this slice does not do it.

**The resolution is composition, not a gate.** The fleet's map marker is only *expressed* in
`fleets.space_x/y` while `location_mode = 'space'`; a `present` fleet's position is the site's, and
combat does not own it. That is one rule and it gets one leaf:

```
combat_fleet_track_position(fleet, x, y)
  -- put the fleet marker on the fight, iff the fleet's position is expressed in space.
  -- composes fleet_set_in_space (still the ONE writer of fleets.space_x/y); no-ops otherwise.
```

With un-docking made impossible by construction, **the reason for condition (c) is gone, so
condition (c) is gone** — from the order arm and from the tick step's `join fleets … location_mode
= 'space'` alike.

Condition (b) is the owner's actual law — *"only an order OUT of the zone breaks combat"* — and it
must keep binding. A hunt site is not inside a zone, but it has the same shape of boundary already:
its **territory radius**. So the admission becomes ONE authority over both region kinds:

```
combat_encounter_admits_point(encounter, x, y)
  = combat_encounter_zone_admits_point(encounter, x, y)          -- 0311, composed unchanged
 or (the encounter's own site holds BOTH the anchor and the point
     within locations.territory_radius)                          -- the site's own boundary
```

Inclusive on the site arm, deliberately: after §3 the anchor sits EXACTLY on `territory_radius`, and
a strict test would refuse the fight its own standing point.

**Outcome: a fight at Snare can now be moved anywhere inside Snare's territory, and an order outside
it still breaks off — the same law, now stated once for both kinds of region.**

### 4b. The latent phantom — a non-spatial encounter

The order arm never checked that the encounter is SPATIAL, but the tick's reposition step lives
inside `if v_is_spatial then`. On a non-spatial encounter the columns were written,
`'repositioning'` was returned, the client printed "Moving to (x, y)", and **nothing ever moved and
the order was never consumed**.

Fixed **in the order arm, as an explicit typed refusal** — not by folding spatiality into the
admission. Reason: the three honest outcomes of "move here" are

* it repositions → `repositioning`;
* the destination is outside the fight's region, so it IS a break-off order → `retreat_started`;
* the engine cannot move this fight at all → **refuse and say so**.

Folding spatiality into the admission would produce the second answer for the third situation, which
is the same silent reclassification this slice exists to end. So an admitted destination on a
non-spatial fight returns `ok:false` / `reason: 'reposition_needs_positions'` and writes nothing.

Unreachable in production today (`spatial_combat_enabled` is on, and mode is sticky per encounter at
creation), so this removes no live capability; it closes the path before it becomes reachable.

---

## 5. MAKE THE MOVE PERCEPTIBLE — AND THE DEV_LOG NAMES THE WRONG KNOB

`docs/DEV_LOG.md:259-262` says the fix for "combat movement feels too slow" is **one knob**,
`combat_player_speed_scale`. **That is wrong and this slice does not follow it.**

`20260618000316:761-765` (invariant f7) requires
`enemy_slowest >= 2 × max(base_speed) × combat_player_speed_scale`. At live numbers that caps the
knob at ≈0.38 — under a 2× improvement — and raising it also speeds up every per-unit CLOSE and
KITE decision, which is precisely how a player kites a pirate out of the fight. It is the wrong
lever twice over. The DEV_LOG line is corrected in this slice.

The right lever already exists. `combat_fleet_move_speed(uuid)` (`20260618000337:133-145`) is a
dedicated leaf with **exactly one reader** — the tick's reposition step — asserted unique at
`20260618000337:674-678`. Scaling *only that leaf* moves ordered repositions and nothing else.

```
combat_reposition_speed_scale   default 8.0
combat_fleet_move_speed(enc) = min(move_speed over living player hulls)
                               * greatest(coalesce(cfg_num('combat_reposition_speed_scale'), 8.0), 0)
```

**Numbers.** Production player combat speeds are 0.16–0.26/tick, so an ordered fleet now covers
1.28–2.08/tick. A 20-unit reposition takes 10–16 ticks = **30–48 seconds**, against 77–125 ticks =
**4–6 minutes** today. f7 is untouched: it constrains per-unit `move_speed`, which this does not
change.

**The balance consequence, stated honestly rather than smuggled.** Pirates move 1.0–1.6/tick. A
fleet under orders now moves 1.28–2.08, so the fastest fleets can slightly OUT-PACE the slowest
raiders while an order stands. Three things bound it, and none of them is a hope:

1. the destination must be inside the fight's own region (§4a), so a reposition can never leave the
   fight — an order outside it is a retreat and takes the retreat's damage window;
2. the enemy side is never fenced — pirates close on the fleet's new position every tick through the
   same leaf they always did (`20260618000337:392-394`), so walking away cannot make a fleet
   unreachable by standing still;
3. the order is consumed on arrival and the fleet immediately reverts to its per-unit speed.

A negative or missing knob folds to hold-still / the shipped default. Fail closed.

---

## 6. WHAT WAS DELIBERATELY NOT BUILT

* **No lock-on delay.** Audited and rejected before this slice: `combat_acquire_target` is
  stateless, there is no target column, and a 3-second invisible delay makes a fight the owner
  already calls too slow strictly worse.
* **No wave-escalation change.** `1 + waves_cleared`, `enemy_synthetic_max_units`,
  `enemy_attack_danger_scale`, `danger_time_divisor_seconds` and every reward/drop value are
  untouched. Wave easing is a knob, deliberately not an unproven balance edit riding a bug fix.
* **This migration writes exactly ONE `game_config` row**, the new `combat_reposition_speed_scale`,
  and no other config value anywhere.
* **Nothing under `src/`.** The `reposition_needs_positions` reason token is a new, unreachable
  string the client will render generically; no contract moves, so there is no other half to land.
* **No runtime trigger** for the anchor authority — see §1, rejected on blast radius.

---

## 7. BLAST RADIUS

* `CREATE OR REPLACE` of `process_combat_ticks`, `command_ship_group_go`, `combat_create_encounter`
  and `combat_fleet_move_speed`, plus five new leaves and one new `game_config` row: an atomic
  catalog swap in one transaction. The tick is re-read every 3 s, so the next tick of every running
  fight runs the new body. No per-fight opt-in, no drain.
* **Fights already in flight**: their anchor is already stamped and nothing rewrites it, so §3
  changes only fights created after the deploy. §2 changes where the NEXT wave of any fight lays out
  — same radius, same count, same stats; only the code path is folded.
* **Orders**: a site fight that used to answer `retreat_started` now answers `repositioning`. That
  is the fix, and it is the one live behaviour change a player can trigger deliberately.
* **Speed**: every reposition ordered after the deploy is ~8× faster. Repositions already in flight
  pick up the new speed on their next tick.
* No schema change. No grant widening — all five leaves are revoked from `public`, `anon` and
  `authenticated` by establishment, never by assertion (the 0254 lesson). No reward, drop, threshold,
  range, difficulty or enemy-speed value moved.

## 8. ROLLBACK

```sql
-- re-apply the deployed bodies with the hunks reverted (0301/0336/0337/0338 text), then:
drop function public.combat_spawn_wave_units(uuid, uuid, text, integer, double precision, double precision,
                                             double precision, double precision, double precision, double precision,
                                             double precision, double precision, double precision, double precision, integer);
drop function public.combat_encounter_move(uuid, uuid, double precision, double precision, double precision, double precision);
drop function public.combat_fleet_track_position(uuid, double precision, double precision);
drop function public.combat_encounter_admits_point(uuid, double precision, double precision);
drop function public.combat_site_standoff_point(double precision, double precision, numeric, uuid);
delete from public.game_config where key = 'combat_reposition_speed_scale';
-- and restore combat_fleet_move_speed / combat_wave_arrival_phase to their 0337 / 0338 bodies.
```

Nothing else to unwind: no combat row, no player state, no other config.
