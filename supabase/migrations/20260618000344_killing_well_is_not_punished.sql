-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0344 — KILLING WELL IS NOT PUNISHED
--        (delete the kill-driven escalation; mint a TIME-DRIVEN pressure authority)
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- ── THE OWNER, THREE TIMES ──────────────────────────────────────────────────────────────────────
--     "I told you that it will be not +1 fleets when fleet is destroyed."
--
-- Destroying an enemy must not cause more enemies, harder enemies, or tougher enemies. This
-- migration DELETES what contradicts that. It does not soften it, does not band it, does not put
-- it behind a knob and does not build an adapter around it. PR #397 tried the banded ramp
-- (ceil(v_danger/5) instead of v_danger, behind a new key) and was closed for exactly this reason:
-- a ramp that fires every fifth kill is still a ramp, and a knob that multiplies the term by zero
-- preserves the mechanism. After this migration there is no expression in the engine from which
-- the old behaviour can be recovered by writing a value anywhere.
--
-- ── THE DEFECT, IN ONE SENTENCE ─────────────────────────────────────────────────────────────────
-- ONE integer, v_danger, meant FIVE things at once, and it began with the player's own kill count:
--
--     v_danger := 1 + e.waves_cleared + floor(v_secs_inside / danger_time_divisor_seconds)
--
--   BODY COUNT   v_enemy_count := least(enemy_synthetic_max_units, greatest(1, v_danger))
--   ENEMY HP     ... * (1 + v_danger * enemy_hp_danger_scale)        [x3 sites]
--   ENEMY DAMAGE ... * (1 + v_danger * enemy_attack_danger_scale)    [x3 sites]
--   LOOT METAL   ... * (1 + reward_danger_scale * v_danger)          [x2 sites]
--   LOOT ITEMS   pirate_loot_for_wave(v_wave_num, v_danger)          [x2 sites]
--
-- Measured firing on production (read-only, 2026-08-08): Snare encounter 520a35c0 ran
-- wave->bodies->wave hp of 1->1->203, 2->2->319, 3->3->427, 4->4->505, 5->5->545, 6->6->587, then
-- pinned at the cap of 6 bodies while hp climbed to 1036 — 5.1x — purely because the player kept
-- winning. 953fe570 is the same shape (223 -> 957). On the aggregate arm, Reaver 6b6f5ff0 ran
-- danger 1 -> 19 and wave hp 362 -> 2860.
--
-- ── WHAT REPLACES IT: ONE PRESSURE AUTHORITY, AND IT IS A CLOCK ─────────────────────────────────
-- public.combat_pressure_step is THE place that decides whether another enemy exists. It reads:
--
--     the SITE      (locations.base_difficulty, and the authored location_pressure row)
--     the CLOCK     (combat_encounters.next_reinforcement_at, which only it advances)
--     the FIELD     (how many enemy bodies are standing right now, against the site's cap)
--
-- and it reads NOTHING ELSE. Not waves_cleared, not wave_number, not danger_level, not a wipe, not
-- a death, not a kill count, not elapsed presence.
--
--     encounter starts:   due = started_at              (see MEASURED, below)
--     on arrival:         population < cap  -> spawn exactly ONE body
--                         population >= cap -> spawn NOTHING
--                         due += cadence, past every slot already elapsed
--
-- Cadence and cap are ROWS, one per site, in public.location_pressure — from
-- docs/COMBAT_BALANCE_VALUES.md §3 and §4:
--
--     site       base_difficulty   cadence   concurrent cap   reaches cap at
--     Snare            10            45 s          3               90 s
--     Reaver           15            36 s          4              108 s
--     Blackden         25            30 s          6              150 s
--
-- THEY ARE ROWS AND NOT A FORMULA, deliberately. cap = round(base_difficulty / N) would make
-- base_difficulty a fourth overloaded authority — which is the exact disease this slice removes.
--
-- ── THE THREE RULES THAT ARE THE EXECUTABLE FORM OF D3, AND HOW EACH IS STRUCTURAL ──────────────
--
-- RULE 1 — NEVER "enemy dies -> slot frees -> spawn replacement". THERE IS NO ARROW FROM AN ENEMY
--   DEATH BACK INTO PRESSURE. It is not enforced by a comment: the two branches that WERE that
--   arrow — "if v_e_before <= 0 then <spawn a wave>" on the spatial arm and
--   "if e.enemy_integrity_current <= 0 then <spawn a wave>" on the aggregate arm — are DELETED, and
--   self-assert (c) fails the deploy if either string ever returns to the tick. The tick asks the
--   authority the same question on every pass, unconditionally; the authority's own body names no
--   death signal at all, which assert (d) proves by reading it.
--
-- RULE 2 — MISSED REINFORCEMENTS ARE LOST, NEVER BANKED. A suppressed arrival is not stored, so a
--   death can never release one. Structurally: the authority handles AT MOST ONE arrival per call
--   and then skips the clock forward past EVERY slot that has already come due —
--   due + cadence * (missed + 1) — so a cron stall, or a long spell at cap, leaves nothing owed.
--   There is no queue and there is no catch-up loop; assert (d) requires the authority's body to
--   contain no loop at all, because a loop is how banking would be written.
--
-- RULE 3 — CADENCE DOES NOT SHORTEN AS PRESENCE ELAPSES. Not in this version. Population already
--   accumulates; if population growth, enemy quality and spawn cadence all moved at once, a bad
--   balance outcome could not be attributed to any one of them. Structurally: the cadence
--   expression is the site row's column and nothing else, and assert (d) requires the authority to
--   name no elapsed-presence term.
--
-- ── ENEMY HP AND DAMAGE: SITE-DRIVEN, NEVER KILL-DRIVEN ─────────────────────────────────────────
-- The (1 + v_danger * scale) factors are deleted from all six sites. What remains is what was
-- always underneath them, and it is the site row:
--
--     one body's hp      = locations.base_difficulty * enemy_hp_base      (x a per-body variance roll)
--     one body's attack  = locations.base_difficulty * enemy_attack_base
--     one body's range   = enemy_synthetic_range_base + base_difficulty * enemy_synthetic_range_per_difficulty
--     one body's speed   = enemy_synthetic_speed_base + base_difficulty * enemy_synthetic_speed_per_difficulty
--
-- Every one of those formulas is COMPOSED verbatim from the head — the same knobs, the same
-- coefficients, the same coalesce fallbacks. Only the danger factor is gone. So Snare's body is
-- 10 x 14 = 140 nominal hp where the head's wave-1 body was 10 x 14 x 1.6 = 224, and the site's
-- ceiling is 3 x 140 = 420 against the head's measured wave-3 total of 427. The site is now the
-- only thing that decides how hard a fight is, and it says so in three rows.
--
-- The variance roll moves INSIDE the authority, per body, beside the row it reads. The head rolled
-- one v_variance per tick and applied it to a whole wave.
--
-- ── LOOT: A FIXED PER-ENEMY VALUE FROM SITE CONTENT ─────────────────────────────────────────────
-- Both loot authorities gated on kill depth and both are deleted:
--   * metal x (1 + reward_danger_scale * v_danger)  — a loiter-and-kill multiplier;
--   * pirate_loot_for_wave(v_wave_num, v_danger)    — a hard-coded ladder (wave >= 3 / 5 / 8 / 10)
--     with NO site term at all, so a tier-3 site paid a tier-1 site's items.
--
-- Payment is now PER ENEMY DESTROYED, and both halves come from rows:
--     metal = reward_metal_base * greatest(locations.reward_tier, 1) * reward_multiplier, per kill
--     items = public.site_loot_for_kill(location_id, kills) over public.location_loot rows
--
-- Adding loot to a site is now an INSERT, never a function edit. **All SEVEN items the deleted
-- ladder could produce are still produced**, by rows, at sites whose tier justifies them — the five
-- deterministic ones every kill, and the two config-gated ones at the rate their knob carried:
--     Snare    (t1)  scrap 1, pirate_alloy 1
--     Reaver   (t2)  scrap 2, pirate_alloy 1, weapon_parts 1,
--                    captain_memory_shard 1 @ captain_shard_drop_rate
--     Blackden (t3)  scrap 3, pirate_alloy 2, weapon_parts 1, engine_parts 1, repair_parts 1,
--                    captain_memory_shard 1 @ captain_shard_drop_rate,
--                    blueprint_fragment   1 @ blueprint_fragment_drop_rate
-- The ladder put engine_parts at wave 8 and repair_parts at wave 10, and the measurement says
-- depth >= 8 is 5 deaths to 1 extraction: 11 engine_parts were ever earned and 1 banked, 8
-- repair_parts earned and 0 banked. They are now authored at the tier-3 site, where a player can
-- actually leave with them.
--
-- ⚠ AN EARLIER VERSION OF THIS FILE CLAIMED THE SENTENCE ABOVE WHILE CARRYING ONLY FIVE OF THE
-- SEVEN. That was false and it was a blocking defect, not a documentation slip: captain_memory_shard
-- and blueprint_fragment are CONFIG-GATED drops inside the same function, pirate_loot_for_wave is
-- their ONLY producer in the entire database, and dropping them would have left 5 captain recruit
-- recipes and 2 hull build recipes permanently unsatisfiable on a live game holding zero of either.
-- Section 2 carries them; self-assert (i) fails the deploy on the whole class if any future slice
-- disconnects a faucet a recipe depends on. See section 2 for the gate-mapping argument.
--
-- ── THE INCOME COMPENSATION, APPLIED, AND ITS ARITHMETIC STATED HONESTLY ────────────────────────
-- COMBAT_BALANCE_VALUES / the contract's §6 measured the counterfactual against all 57 logged
-- payouts: round(10 * max(reward_tier,1) * (1 + 0.25 * danger_level)) reproduced every one of them
-- with 0 mismatches, and deleting the danger term takes the total from 1852 to 939 — a 49.3% cut.
-- The stated compensation is reward_metal_base 10 -> 20, and it is APPLIED HERE, in this
-- migration, so the slice does not quietly halve the metal faucet for ~30 live players.
--
-- THE PART THAT WOULD BE DISHONEST TO LEAVE OUT: 2 x 939 = 1878, not 1852 — the doubling is exact
-- per payout but the recorded total differs by 1.4%, which is rounding. And the payout EVENT
-- changed: the 57 measurements were wave clears, while payment is now per enemy destroyed. On the
-- measured average fight (5.07 clears, 3.09 bodies per wave) the head paid ~5 times; under the new
-- cadence a Snare fight of ~130 s sees arrivals at 0/45/90 s, so ~3-4 kills and ~3-4 payments.
-- Those are the same order and that is as far as the measurement goes: the per-fight total under
-- the new cadence is UNMEASURED and must be read off production after this deploys. It is not
-- reasoned into place here.
--
-- ── WHAT IS DELETED (the full list) ─────────────────────────────────────────────────────────────
--   1  "+ e.waves_cleared" and the whole v_danger concept — both copies, all 24 reference sites.
--   2  The declaration of v_danger.
--   3  The synthetic body-count sizer, least(enemy_synthetic_max_units, greatest(1, v_danger)).
--   4  The v_resolver_engaged branch that selected between two live wave SIZERS per invocation —
--      it has stepped a live fight 18x mid-flight (Reaver 7f56967e: wave 13->14, units 1->6, hp
--      123->2213, fleet died). Two sizers chosen by a global flag read is the disease.
--   5  The encounter_runtime_state cap/cooldown ledger written only by that branch.
--   6  The resolved-plan reward branch, resolve_encounter_reward_inputs(..., v_danger) — a second
--      payout authority beside the site's reward_tier.
--   7  The next_wave_at pause on both arms: it paced a thing that no longer happens.
--   8  Both calls to pirate_loot_for_wave, and its depth ladder as an engine input.
--   9  Six game_config rows. Four that nothing reads after this: enemy_hp_danger_scale,
--      enemy_attack_danger_scale, reward_danger_scale and danger_time_divisor_seconds. A live
--      knob that gates nothing is a liability — 0320's finding. NOT enemy_synthetic_max_units:
--      resolve_location_encounter still reads it as its authored-plan ceiling, so only the TICK's
--      read of it is deleted (asserted 0). See section 4. Plus captain_shard_drop_rate and
--      blueprint_fragment_drop_rate, whose VALUES are first copied into location_loot.drop_chance
--      — migrated, not lost — because after this slice pirate_loot_for_wave has no caller at all.
--  10  The write of combat_encounters.danger_level. The column stops carrying a meaning here and
--      is dropped by 0349 (the contract's own sequencing). Until then both arms write the
--      constant 1 rather than leaving a stale escalation number on a live row.
--
-- WHAT IS COMPOSED, NEVER REIMPLEMENTED: combat_spawn_wave_units (0339) remains the schema's sole
-- inserter of an enemy row and is called with count = 1; combat_formation_point and
-- combat_wave_arrival_phase are untouched inside it; the four enemy stat formulas are the head's,
-- character for character, minus the danger factor; loot_merge_items still merges the bundle.
--
-- ── WHAT THIS SLICE DELIBERATELY DOES NOT TOUCH ─────────────────────────────────────────────────
-- src/** — the client is owned by a separate merged slice, by the lead's instruction. The
-- consequence is stated rather than hidden: ActiveCombatPanel.tsx:99-101 still prints
-- "Danger N" and will now read a constant 1 on every live fight. That is a stale label, not a
-- lie about the engine, and it is the client slice's to remove.
-- Also untouched: pirate_loot_for_wave itself and resolve_encounter_reward_inputs (both are now
-- ENGINE-DEAD but are exercised by proof fixtures — dropping a function the harness invokes is the
-- 0232 mistake, and the contract already owns their retirement in 0350); the aggregate arm's
-- existence (0345); the wreck leaf (0343); every spatial/geometry concern (0346-0347).
--
-- ── DEVIATIONS FROM docs/COMBAT_OWNER_DIRECTIVES_CONTRACT.md §4/0344, STATED ────────────────────
-- The contract's 0344 replaced the kill sizer with the SITE'S AUTHORED PLAN (encounter_profiles ->
-- encounter_profile_members -> fleet_templates, resolved by resolve_location_encounter) and would
-- have authored that content for Snare and Blackden. That is superseded by the measured design in
-- docs/COMBAT_BALANCE_VALUES.md §3/§4, which this file implements: a flat per-site reinforcement
-- cadence and a concurrent cap. The reason is not preference. An authored plan is still a WAVE
-- sizer, and a wave still has to be TRIGGERED by something — under the contract's shape that
-- trigger stays "the enemy side is empty", which is precisely the arrow the owner rejected. A
-- clock has no such trigger. Consequently the resolver branch is deleted here rather than being
-- promoted to the one sizer, and no encounter_profiles content is authored.
--
-- SECOND DEVIATION, and it is arithmetic. The contract and the brief both write the clock as
-- "next_reinforcement_at = started_at + cadence". This implements "= started_at". The same
-- document's own measured table gives "reaches cap at" 90 s / 108 s / 150 s for caps 3 / 4 / 6 at
-- cadences 45 / 36 / 30, and those are (cap - 1) x cadence — arrivals at 0, 45, 90 and at
-- 0, 36, 72, 108 and at 0, 30, 60, 90, 120, 150. "+ cadence" would put them at 135 / 144 / 180 and
-- would leave a fight with NOTHING IN IT for a full cadence after the fleet arrives. The measured
-- column is followed and the prose is not.
--
-- ── IN-FLIGHT ENCOUNTERS: PRODUCTION IS A LIVE ~30-PLAYER GAME ──────────────────────────────────
-- Encounters with status in ('active','retreating') at the instant this applies have a
-- waves_cleared history and no clock. Two things are done, and the second is what actually makes
-- it safe:
--   (a) SECTION 3 BACKFILLS every non-terminal encounter whose site carries a pressure row with
--       next_reinforcement_at = now() + that site's cadence, so a fight in progress gets a full
--       cadence of grace rather than a body on the first tick after the deploy.
--   (b) THE LAW FOR AN UNSTAMPED ROW IS IN THE CODE, not in the backfill: the authority reads
--       coalesce(next_reinforcement_at, started_at). An encounter created before the deploy, one
--       created after it by a creator this slice does not re-emit, and one whose site is authored
--       later all resolve the same way — the clock starts when the fight started. There is no
--       state the new clock cannot resolve and no row that needs the backfill to have run.
-- A fight already in progress therefore keeps its current enemies (nothing is deleted), stops
-- getting bigger ones, and begins receiving one body per cadence up to its site's cap. A site with
-- no pressure row hosts no reinforcements at all: the authority returns without spawning and
-- without advancing anything. That is fail-closed, and section 1 asserts no ACTIVE pirate-hunt
-- site is in that state.
-- The tick and its two new leaves are created in ONE transaction, so there is never an instant at
-- which the tick names a function that does not exist. A cron pass already executing finishes on
-- the old body and resolves its encounter completely.
--
-- ── ROLLBACK BOUNDARY ───────────────────────────────────────────────────────────────────────────
-- Everything this migration changes is listed here, and every step is mechanical:
--   1. Run this file's own surgery block with old_t and new_t SWAPPED. Every pre-image is in this
--      file, verbatim, in the VALUES list — nothing has to be reconstructed from a dump or from an
--      older migration file (copying from an older FILE is what reverted this function's mode line
--      three times; the tick's own header records it).
--   2. Re-insert the four game_config rows deleted in section 4, at their pre-0344 values:
--      enemy_hp_danger_scale 0.6, enemy_attack_danger_scale 0.25, reward_danger_scale 0.25 and
--      danger_time_divisor_seconds 180; RESTORE captain_shard_drop_rate and
--      blueprint_fragment_drop_rate from the location_loot rows this migration wrote them into
--      (the deploy log's 0344 drop-rate migration NOTICE records both values verbatim); and set
--      reward_metal_base
--      back to 10. (Their absence is what makes the coalesce fallbacks in the OLD body correct
--      again, so the order does not matter — but the metal knob does, and it is one write.)
--   3. drop function public.combat_pressure_step(uuid, integer, double precision, double
--      precision, double precision, double precision, integer, boolean);
--      drop function public.site_loot_for_kill(uuid, integer);
--   The drops must not precede step 1.
-- NOT part of the boundary, deliberately: combat_encounters.next_reinforcement_at and the two new
-- tables are LEFT IN PLACE. Dropping a column that a re-applied 0344 would need, on a live game,
-- buys nothing — nothing reads them once the authority is gone, and no other code path touches
-- them. No enemy row is deleted by rolling back, no haul is disturbed, and no player-visible state
-- other than difficulty and payout returns.
-- REVERTING IS NOT A KNOB, AND THAT IS ON PURPOSE. There is no config value that restores kill
-- escalation, because a knob that could would be the adapter this slice exists to delete.
--
-- ── PARITY: THIS IS A REPLACE-REWRITER, NOT A RE-EMISSION ───────────────────────────────────────
-- THE LIVE ENGINE IS THE AUTHORITY, NOT THE REPO. process_combat_ticks is ~1,400 lines and no file
-- holds it whole. This migration reads the body that is actually DEPLOYED (pg_get_functiondef at
-- apply time) and replaces ELEVEN hunks in it. Each hunk carries its source text VERBATIM, cut from
-- production's own dump (md5(pg_get_functiondef) = 3806e89a97237bf00f593ad38a834580, 99,286 chars,
-- 1,396 lines, 2026-08-08), and each must match EXACTLY ONCE. Zero means the anchor is gone — the
-- deployed body is not the one the hunk was cut from — and this aborts rather than silently
-- patching nothing. More than one means the anchor is ambiguous and the patch could land on the
-- wrong site; that aborts too.
--
-- IT MUST BE A SURGERY. Eleven generators (scripts/gen-0314, -0315, -0316, -0317, -0319, -0331,
-- -0332, -0333, -0336, -0337, -0339) each assert that 0299 is still the newest TEXTUAL re-create
-- of this function, and their own comment states the rule: "Replace-rewriters do not move the
-- textual head, but any later `create or replace function public.process_combat_ticks` means the
-- slice source is stale." 0343 wrote a full re-emission first and broke all eleven at once —
-- observed by running the selftest, not predicted. This file therefore contains no re-create of
-- the tick at all.
--
-- THE HUNKS ARE CUT AGAINST THE BODY AS 0343 LEAVES IT, NOT AS PRODUCTION READS TODAY. 0343
-- applies immediately before this in the same chain and rewrites four regions — arm A's death
-- block, arm B's comment banner, arm C's death block and arm D's death block. None of them
-- overlaps any of the ten regions below, and none of them contains any text a hunk here matches;
-- assert (b) re-proves that by requiring 0343's own fold to be intact after this surgery.
--
-- ── EVERY NEEDLE, MEASURED — NOT REASONED ──────────────────────────────────────────────────────
-- The first version of this file refused to apply on all 22 disposable legs:
--
--     ERROR: 0344 PRECONDITION FAIL: 2 copy(ies) of the synthetic BODY-COUNT sizer
--     greatest(1, v_danger) (want exactly 1)
--
-- The needle was the bare substring "greatest(1, v_danger)", which is shared by TWO DISTINCT
-- CONCEPTS — the body-count sizer and the aggregate arm's laser_burst projectile_count — so it
-- counted 2 while asserting 1. The migration failing closed was correct. The needle was not.
--
-- THE DEFECT CLASS, NAMED SO IT IS NOT REPEATED: a needle that is a substring of more than one
-- concept, or an expected count arrived at by READING THE CODE AND THINKING rather than by
-- counting against the real text. This repo has burned four consecutive CI rounds on exactly that
-- class, one instance per round. So every needle in this file was then counted against the actual
-- text of all three bodies — production's dump, the body after 0343 applies (which is what this
-- migration is handed), and the body after this migration's own surgery. 39 needles, all measured:
--
--   block  needle                                                      body     want  PROD  P0343  P0344
--   pre    1 + e.waves_cleared + floor(v_secs_inside                   P0343~     2     2      2      0
--   pre    least(coalesce(cfg_num('enemy_synthetic_max_units'),6)…)    P0343~     1     1      1      0
--   pre    'laser', greatest(1, v_danger), 600)                        P0343~     1     1      1      0
--   pre    pirate_loot_for_wave(v_wave_num, v_danger)                  P0343~     2     2      2      0
--   pre    waves_cleared            = waves_cleared + (case when …     P0343~     2     2      2      2
--   pre    combat_encounter_wreck                          (raw, present)         8 occurrences
--   pre    combat_pressure_step                            (raw, absent)          0 occurrences
--   a      e.waves_cleared                                             P0344~     0     5      5      0
--   a      v_danger                                                    P0344~     0    27     27      0
--   a      enemy_hp_danger_scale / enemy_attack_danger_scale           P0344~     0     3      3      0
--   a      reward_danger_scale / danger_time_divisor_seconds           P0344~     0     2      2      0
--   a      enemy_synthetic_max_units                                   P0344~     0     1      1      0
--   a      pirate_loot_for_wave                                        P0344~     0     2      2      0
--   a      resolve_encounter_reward_inputs                             P0344~     0     1      1      0
--   b      public.combat_pressure_step(e.id, v_tick, … v_log_events)   P0344~     2     0      0      2
--   b      combat_pressure_step(                                       P0344~     2     0      0      2
--   b      public.site_loot_for_kill(                                  P0344~     2     0      0      2
--   b      public.combat_encounter_wreck(e.id, v_tick)                 P0344~     3     0      3      3
--   c      if v_e_before <= 0 then                                     P0344~     0     1      1      0
--   c      if e.enemy_integrity_current <= 0 then                      P0344~     0     1      1      0
--   d      next_reinforcement_at / s.cadence / s.cap                   leaf~   present  2 / 2 / 3
--   d      coalesce(e.next_reinforcement_at, e.started_at)             leaf~   present  1
--   d      waves_cleared / wave_number / danger / secs_inside          leaf~      0     0
--   d      loop                                                        leaf~      0     0
--   d      s.cadence * (v_missed + 1)   /   next_reinforcement_at =    leaf~      1     1
--   e      combat_spawn_wave_units(                                    P0344~     0     2      2      0
--   e      combat_spawn_wave_units(                                    leaf~      1     1
--
-- (~ = comment-stripped, which is the form every count above is taken on except the two raw
-- position checks. The surgery's own hunk matching is on the RAW definition, because a hunk's
-- source text is mostly comments.)
--
-- ██ THE RULE THAT WOULD HAVE PREVENTED THE RED, STATED SO IT BINDS THE NEXT SLICE ██
--
--     A BROAD needle may only carry an ABSENCE check. A PRESENCE or EXACT-COUNT check must name
--     exactly one concept.
--
-- That is the whole defect in one line. "greatest(1, v_danger)" is a broad needle and it was used
-- for an exact-count presence check, so a second concept sharing the substring made it count 2.
-- Broad-for-absence is not merely safe, it is STRONGER: a wider substring catches more of what
-- must not be there. Broad-for-presence is always a latent lie.
--
-- The 37 needles this file extracts to were then swept for substring relationships: 32 exist, and
-- every one obeys the rule above. Each pair is a broad ABSENCE needle beside a specific
-- PRESENCE/COUNT needle, and in most cases they also read different bodies:
--   "v_danger" (absence, post-0344 tick)      vs the three specific v_danger expressions
--                                                (presence-counts, post-0343 tick)
--   "waves_cleared" (absence, the authority)  vs "e.waves_cleared" (absence, the tick)
--                                                and the exact write statement (count 2, the tick)
--   "danger" (absence, the authority)         vs "enemy_hp_danger_scale" etc (absence, the tick)
--   "pirate_loot_for_wave" (absence, tick)    vs "pirate_loot_for_wave(v_wave_num, v_danger)"
--                                                (presence-count 2, post-0343 tick)
--   "combat_pressure_step" (absence, pre)     vs "combat_pressure_step(" (count 2) vs the full
--                                                argument form (count 2) — a deliberate LADDER:
--                                                if a third call appeared in a different shape the
--                                                broad count would move to 3 while the specific
--                                                stayed 2, and assert (b) would fire. That is the
--                                                guard working, not an ambiguity.
--   "s.cadence" (presence, authority)         vs "s.cadence * (v_missed + 1)" (count 1) — both
--                                                specific, both this file's own bytes.
-- Two entries in that sweep are catalog identifiers, not text needles at all: the two function
-- signatures in (h) are cast to regprocedure and never matched against a body.
--
-- ── WHICH NEEDLES ARE SENSITIVE TO "PROD BODY ≠ CI-CHAIN BODY", STATED PLAINLY ─────────────────
-- 0343's own header records that the body the CHAIN builds is not required to be byte-equal to
-- production's, and that this could not be verified from the machine these were written on (no
-- local Docker). Every measurement above was taken against production's dump with 0343 replayed
-- onto it offline. So:
--
--   * SENSITIVE — every hunk pre-image (11) and every precondition count (5). If the chain's body
--     differs anywhere inside a hunk's bytes, that hunk matches 0 times and this migration ABORTS
--     naming the hunk. That is the designed behaviour and it is why no count is written as ">= 1"
--     or "1 or 2": an assert that tolerates both worlds proves nothing about either. Exposure is
--     proportional to bytes matched, and it is concentrated: [P1] 13,404 chars / 170 lines and
--     [P5] 1,985 chars / 33 lines carry 94% of it; the other nine hunks are 28-1,772 chars, six of
--     them single lines.
--   * NOT SENSITIVE — every assert in (a), (b), (c), (e). They read the body AFTER this file's own
--     surgery has succeeded, and the surgery cannot succeed unless every anchor matched exactly
--     once. If the chain body differed, the deploy would already have aborted above.
--   * NOT SENSITIVE — every needle in (d). The authority is created by this file, so its body is
--     this file's own bytes in every world.
--   * NOT SENSITIVE — (f), (g), (h). They read rows and catalogs, not text.
--
-- Verified against the chain rather than assumed, for the two asserts whose expected values are
-- world facts rather than text: no migration in the chain sets any pirate_hunt location's status
-- away from 'active' (so (f)'s "at least 3 sites" cannot fail on a correct world), and no existing
-- game_config key matches (g)'s sweep — the many real worldstate_pressure_* and event_pressure_*
-- keys do NOT match '%pressure_step%', which is why that pattern is narrow rather than '%pressure%'.
--
-- ── THE SELF-ASSERT (what fails the deploy) ─────────────────────────────────────────────────────
-- Every count over the tick is taken on a COMMENT-STRIPPED copy of the deployed prosrc, because
-- this file's own hunk banners name the very identifiers being asserted absent — the 0222 vacuity
-- trap, in reverse. Each block proves its probe is live BEFORE it concludes anything from a zero.
--   (a) THE CLASS GUARD. In the tick: v_danger appears ZERO times; e.waves_cleared appears ZERO
--       times (a READ of the kill count is what D3 forbids); all five danger-knob NAMES appear zero
--       times; pirate_loot_for_wave and resolve_encounter_reward_inputs appear zero times. It
--       CANNOT pass vacuously: the same block first requires the two waves_cleared WRITE
--       statements to be present exactly twice and the stripped body to exceed 40,000 chars and be
--       shorter than the raw body, so a broken strip fails as a broken strip.
--   (b) THE FOLD IS INTACT AND THE AUTHORITY IS REACHED: combat_pressure_step is called exactly
--       twice and site_loot_for_kill exactly twice (once per arm), and 0343's combat_encounter_wreck
--       is still called exactly three times.
--   (c) RULE 1, AS A STRING THAT MAY NOT RETURN: neither "if v_e_before <= 0 then" nor
--       "if e.enemy_integrity_current <= 0 then" appears in the tick. Those two conditions WERE
--       the arrow from a death to a spawn. Probe liveness comes from (b) in the same deploy.
--   (d) THE AUTHORITY IS WHAT IT CLAIMS — read out of its own body. It names next_reinforcement_at,
--       concurrent_cap and reinforcement_seconds; it names waves_cleared, wave_number, danger and
--       secs_inside ZERO times; it contains NO loop (RULE 2 — a loop is how banking is written);
--       and its clock advance is the single skip-forward expression (RULE 2 again). The probe must
--       match the authority itself first, so a regex matching nothing fails as a broken regex
--       rather than reporting an empty world as clean.
--   (e) ONE PRESSURE AUTHORITY, BY SCHEMA SWEEP: exactly one function in public calls
--       combat_spawn_wave_units, and it is combat_pressure_step. This is the assert that fails the
--       deploy if a second spawner is ever added. Same non-vacuity discipline: it must find the
--       authority itself, by the same pattern, in the same query.
--   (f) THE CONTENT EXISTS: every ACTIVE pirate_hunt location carries a location_pressure row (and
--       there are at least the three seeded sites, so the sweep cannot pass over an empty set);
--       every location_pressure row has a positive cadence and a cap >= 1; every seeded loot row
--       names an item_types row.
--   (g) NOTHING DARK: no game_config key exists for this slice — asserted ABSENT, not promised —
--       the four now-unread danger knobs are GONE, and reward_metal_base is 20.
--   (h) THE NEW SURFACES ARE ENGINE-INTERNAL: both leaves revoked from PUBLIC BY NAME (the 0309
--       lesson) and from anon and authenticated, then asserted unreachable; both new tables carry
--       no client INSERT/UPDATE/DELETE.
--
-- WHAT THE SELF-ASSERT CANNOT DO, STATED RATHER THAN IMPLIED. These asserts are STRUCTURAL. They
-- prove there is one pressure authority, that it is a clock, and that nothing reads a kill count.
-- They cannot prove that a fight paces well. The behavioural gate is the disposable-Postgres leg,
-- and it is NOT green today. THE HARNESS IS PART OF THE SURFACE BEING RETIRED — the 0232 lesson —
-- so it is COUNTED HERE rather than discovered one CI round at a time:
--
--   the deleted formula and its five knobs, by file (76 references in 13 files):
--     scripts/danger-combat-proof.sql            28   scripts/encounter-canary-proof.sql       7
--     scripts/encounter-resolver-proof.sql        7   scripts/team-command-proof.sql           6
--     scripts/elite-stat-wiring-proof.sql         5   scripts/encounter-canary-readiness.sql   5
--     scripts/activate-encounter-resolver-canary.sql 4
--     scripts/combat-ticks-result-fix-proof.sql   3   scripts/multipirate-lifecycle-proof.sql  3
--     scripts/spatial-sticky-mode-proof.sql       3   scripts/fleet-encounter-profiles-proof.sql 2
--     scripts/location-encounter-bindings-proof.sql 2 scripts/activate-canary-binding.sql      1
--   Many of these WRITE a deleted knob to establish a precondition. A write to a key that no
--   longer exists does not error — it silently stops establishing anything and the block goes
--   green where it should be red. That is the failure mode to look for, not a raise.
--
--   blocks that PREDICT wave size or wave hp from the formula and assert the engine agrees —
--   e.g. danger-combat-proof.sql:2892, :4574, :4815, :6276, :6439, :6684, :6862 — test a mechanism
--   this slice deletes and must be re-premised on the clock (arrivals at 0 / cadence / 2*cadence,
--   one body each, none past the cap).
--
--   three files assert the TICK ITSELF contains "public.combat_spawn_wave_units(" —
--   danger-combat-proof.sql:7869, elite-stat-wiring-proof.sql:71, encounter-resolver-proof.sql:92.
--   That string now lives in public.combat_pressure_step, and their own comments already say the
--   pin FOLLOWS the leaf, so each is a one-line repoint onto the authority.
--
-- They are enumerated rather than rewritten here, deliberately: there is no local Postgres or
-- Docker on the machine this was written on, so any assertion I wrote for them would ship UNRUN,
-- and an unrun assertion is a green marker over an unproven property. THE MATRIX CANNOT GO GREEN
-- UNTIL THIS SWEEP IS DONE, and it must be done in ONE pass — the recorded lesson is that fixing
-- this class one instance per CI round costs a round each and reveals exactly one more every time.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════


-- ── PRECONDITIONS ───────────────────────────────────────────────────────────────────────────────
-- A surgery is only safe if what it cuts is still there, in the shape it expects, and only there.
-- This block refuses to apply if any region the hunks rewrite is missing, duplicated or already
-- rewritten — the "the anchor is missing on production" failure, which is how 0333 held a chain
-- hostage. The per-hunk exactly-once check in the surgery block is the same guarantee stated again
-- at the point of use; this block states it in the vocabulary of the DEFECT, so a failure names
-- the escalation term rather than a hunk tag.
do $pre$
declare
  v_raw  text;
  v_code text;
  v_def  text;
  v_n    integer;
begin
  select p.prosrc, pg_get_functiondef(p.oid)
    into v_raw, v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if v_raw is null then
    raise exception '0344 PRECONDITION FAIL: process_combat_ticks does not exist — there is nothing to rewrite';
  end if;
  v_code := regexp_replace(v_raw, '--[^' || chr(10) || ']*', '', 'g');
  if length(v_code) < 40000 or length(v_code) >= length(v_raw) then
    raise exception '0344 PRECONDITION FAIL: the comment strip produced % chars from a % char body — every count below would be measured against nothing', length(v_code), length(v_raw);
  end if;

  -- FRESHNESS. 0343 is the migration immediately below this one and it folds the three death arms
  -- into public.combat_encounter_wreck. A body that has not been through it is not the body these
  -- hunks were cut against, and the right answer is to stop and look.
  if position('combat_encounter_wreck' in v_raw) = 0 then
    raise exception '0344 PRECONDITION FAIL: the deployed body does not call combat_encounter_wreck — 0343 has not been applied to it, so these hunks were cut against a different body. Do not apply this';
  end if;
  if position('combat_pressure_step' in v_raw) > 0 then
    raise exception '0344 PRECONDITION FAIL: the deployed body already calls combat_pressure_step — this rewrite has already happened and re-applying it would be a second pressure authority';
  end if;

  -- THE ESCALATION IS THERE, IN THE SHAPE THIS FILE DELETES.
  v_n := (length(v_code) - length(replace(v_code, '1 + e.waves_cleared + floor(v_secs_inside', '')))
         / length('1 + e.waves_cleared + floor(v_secs_inside');
  if v_n <> 2 then
    raise exception '0344 PRECONDITION FAIL: % copy(ies) of the kill-escalation term "1 + e.waves_cleared + floor(v_secs_inside ..." (want exactly 2: the spatial arm and the aggregate arm). The body has drifted from the parity source and this rewrite would land on the wrong text', v_n;
  end if;
  -- ONE NEEDLE, ONE CONCEPT. The bare substring "greatest(1, v_danger)" was the first draft of
  -- this check and it was WRONG: it is shared by TWO distinct concepts — the body-count sizer here
  -- and the aggregate arm's laser_burst projectile_count — so it counted 2 while asserting 1 and
  -- refused to apply on all 22 disposable legs. Each concept now carries its own needle, its own
  -- expected count and its own message. The rule that produced the bug: a needle whose expected
  -- count was REASONED rather than counted against the real text. Every count in this file has now
  -- been measured against the actual post-0343 body; the table is in the header.
  v_n := (length(v_code) - length(replace(v_code, 'least(coalesce(cfg_num(''enemy_synthetic_max_units''),6)::integer, greatest(1, v_danger))', '')))
         / length('least(coalesce(cfg_num(''enemy_synthetic_max_units''),6)::integer, greatest(1, v_danger))');
  if v_n <> 1 then
    raise exception '0344 PRECONDITION FAIL: % copy(ies) of the synthetic BODY-COUNT sizer least(cfg_num(''enemy_synthetic_max_units''), greatest(1, v_danger)) (want exactly 1). That line is the literal "+1 enemy per kill" — the thing the owner rejected three times — and it must be present to be deleted', v_n;
  end if;
  -- THE SECOND CONCEPT THAT SHARES THAT SUBSTRING, counted in its own right: the aggregate arm's
  -- laser_burst projectile_count, which drew a denser beam the better the player fought. It is a
  -- COSMETIC, not a sizer, and conflating the two is what made the first needle ambiguous.
  v_n := (length(v_code) - length(replace(v_code, '''laser'', greatest(1, v_danger), 600)', '')))
         / length('''laser'', greatest(1, v_danger), 600)');
  if v_n <> 1 then
    raise exception '0344 PRECONDITION FAIL: % copy(ies) of the laser_burst projectile_count greatest(1, v_danger) (want exactly 1 — the aggregate arm''s cosmetic escalation counter, hunk [PA]). It is a different concept from the body-count sizer above and is counted separately on purpose', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'pirate_loot_for_wave(v_wave_num, v_danger)', '')))
         / length('pirate_loot_for_wave(v_wave_num, v_danger)');
  if v_n <> 2 then
    raise exception '0344 PRECONDITION FAIL: % call(s) to pirate_loot_for_wave(v_wave_num, v_danger) (want exactly 2 — one per arm). Loot is being moved off kill depth and onto site rows', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'waves_cleared            = waves_cleared + (case when v_cleared then 1 else 0 end),', '')))
         / length('waves_cleared            = waves_cleared + (case when v_cleared then 1 else 0 end),');
  if v_n <> 2 then
    raise exception '0344 PRECONDITION FAIL: % waves_cleared WRITE statement(s) (want exactly 2). Assert (a) uses this exact string to prove its probe is live before concluding that no READ of waves_cleared survives', v_n;
  end if;

  if to_regprocedure('public.combat_pressure_step(uuid, integer, double precision, double precision, double precision, double precision, integer, boolean)') is not null then
    raise exception '0344 PRECONDITION FAIL: public.combat_pressure_step already exists — this migration mints it';
  end if;
  if to_regproc('public.combat_spawn_wave_units') is null then
    raise exception '0344 PRECONDITION FAIL: public.combat_spawn_wave_units does not exist — the pressure authority COMPOSES it and will not hand-roll a second inserter of enemy rows';
  end if;

  raise notice '0344 parity source: recorded md5(pg_get_functiondef) = 3806e89a97237bf00f593ad38a834580 / 99286 chars (production, 2026-08-08, BEFORE 0343). OBSERVED here: md5 = % / % chars (prosrc: md5 = % / % chars). A difference is a REVIEW SIGNAL, not a failure — 0343 rewrites four regions of this body before this migration runs, so the observed value is EXPECTED to differ; what is asserted instead is that every region THIS file rewrites is present, in the expected shape, exactly the expected number of times.',
    md5(v_def), length(v_def), md5(v_raw), length(v_raw);
end $pre$;


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 1 — THE PRESSURE CONTENT. Cadence and cap are ROWS, one per site.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- A site's pressure is CONTENT, and content is rows. Authoring a new hunting ground must be an
-- INSERT, never an edit to a function — and deriving cap from base_difficulty would make
-- base_difficulty a fourth overloaded authority, which is the disease this whole programme removes.
--
-- The numbers are docs/COMBAT_BALANCE_VALUES.md §3 and §4, each with its own falsification test
-- recorded there. They are not invented here and they are not re-derived here.
create table if not exists public.location_pressure (
  location_id           uuid primary key references public.locations (id) on delete cascade,
  reinforcement_seconds double precision not null check (reinforcement_seconds > 0),
  concurrent_cap        integer          not null check (concurrent_cap >= 1),
  enemy_unit_type_id    text             not null default 'pirate_synthetic',
  note                  text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

-- ESTABLISH THE LOCKDOWN, NEVER MERELY ASSERT IT. Supabase's project default grants every client
-- verb on each new public table and a disposable CI database has no such default, so a migration
-- that ASSERTS the posture aborts on deploy while one that REVOKES cannot. 0254 learned this
-- expensively. RLS is enabled with NO policy: this table is read by a SECURITY DEFINER leaf and by
-- nothing else, so deny-all for clients is the correct posture, not an oversight.
alter table public.location_pressure enable row level security;
revoke insert, update, delete on table public.location_pressure from anon, authenticated;

insert into public.location_pressure (location_id, reinforcement_seconds, concurrent_cap, note)
select l.id, v.cadence, v.cap, v.note
  from (values
    ('Snare',    45.0, 3, 'COMBAT_BALANCE_VALUES §3/§4 — difficulty 10, reaches cap at ~90 s'),
    ('Reaver',   36.0, 4, 'COMBAT_BALANCE_VALUES §3/§4 — difficulty 15, reaches cap at ~108 s'),
    ('Blackden', 30.0, 6, 'COMBAT_BALANCE_VALUES §3/§4 — difficulty 25, reaches cap at ~150 s')
  ) as v(name, cadence, cap, note)
  join public.locations l on l.name = v.name and l.location_type = 'pirate_hunt'
on conflict (location_id) do nothing;

-- ANY OTHER PIRATE-HUNT SITE GETS THE GENTLEST AUTHORED PROFILE, AS A ROW.
-- A site drawn in the World Editor after the three seeded ones would otherwise host no
-- reinforcements at all, and the coverage assert below would fail the deploy. This is still a row
-- and still authored — Snare's exact values, copied — not a formula over base_difficulty. The note
-- says so, so nobody later mistakes it for a designed number.
insert into public.location_pressure (location_id, reinforcement_seconds, concurrent_cap, note)
select l.id, 45.0, 3, 'unauthored site — Snare''s profile as the conservative default; replace with real content'
  from public.locations l
 where l.location_type = 'pirate_hunt'
   and l.status = 'active'
on conflict (location_id) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 2 — THE LOOT CONTENT. What an enemy is worth is a ROW, per site.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- pirate_loot_for_wave's ladder gated items on how DEEP the escalation went and carried no site
-- term, so a tier-3 site paid a tier-1 site's items. Adding loot is now an INSERT.
create table if not exists public.location_loot (
  location_id uuid    not null references public.locations (id) on delete cascade,
  item_id     text    not null references public.item_types (item_id) on delete restrict,
  quantity    integer not null check (quantity > 0),
  -- HOW OFTEN, AS DATA. Rolled once per (item, enemy destroyed). 1.0 = every kill, which is what
  -- the five deterministic ladder items were and still are. It exists because the ladder had TWO
  -- kinds of drop, not one: five deterministic items and two CONFIG-GATED chance drops. A loot
  -- authority that can only express the deterministic half is not the loot authority.
  drop_chance double precision not null default 1.0 check (drop_chance >= 0 and drop_chance <= 1),
  note        text,
  created_at  timestamptz not null default now(),
  primary key (location_id, item_id)
);
alter table public.location_loot enable row level security;
revoke insert, update, delete on table public.location_loot from anon, authenticated;

-- ── THE FIVE DETERMINISTIC LADDER ITEMS — every kill, unchanged ─────────────────────────────────
insert into public.location_loot (location_id, item_id, quantity, drop_chance, note)
select l.id, v.item_id, v.qty, 1.0, 'ladder item, deterministic per kill'
  from (values
    ('Snare',    'scrap',         1),
    ('Snare',    'pirate_alloy',  1),
    ('Reaver',   'scrap',         2),
    ('Reaver',   'pirate_alloy',  1),
    ('Reaver',   'weapon_parts',  1),
    ('Blackden', 'scrap',         3),
    ('Blackden', 'pirate_alloy',  2),
    ('Blackden', 'weapon_parts',  1),
    ('Blackden', 'engine_parts',  1),
    ('Blackden', 'repair_parts',  1)
  ) as v(name, item_id, qty)
  join public.locations l on l.name = v.name and l.location_type = 'pirate_hunt'
  join public.item_types t on t.item_id = v.item_id
on conflict (location_id, item_id) do nothing;

-- ── THE TWO CONFIG-GATED FAUCETS — CARRIED ACROSS, NOT DROPPED ─────────────────────────────────
-- ⛔ THE DEFECT THIS FIXES, and it was a blocking one. The first version of this section re-authored
-- only the five DETERMINISTIC ladder items and left the two CHANCE drops behind. Measured on
-- production: pirate_loot_for_wave is the ONLY producer of either item anywhere in the database, so
-- deleting the tick's two calls to it without carrying them here would have left
--   * captain_memory_shard — the shared gating ingredient on 5 captain recruit recipes (0125:64-78:
--     gunnery_veteran, trade_broker, survey_cartographer, extraction_foreman, fleet_quartermaster)
--   * blueprint_fragment  — required qty 2 by 2 hull build recipes (0185:156-168: bulk_hauler and
--     strike_corvette)
-- with NO source at all, permanently, on a live game where players hold zero of either. Migration
-- 0171 exists precisely because "recruiting is dead-ended without a shard source"; that is the exact
-- condition this would have re-created. Self-assert (i) below now fails the deploy on this whole
-- CLASS rather than on these two instances.
--
-- ── HOW THE OLD GATE MAPS ONTO THE NEW MODEL ───────────────────────────────────────────────────
-- The deployed gates are NOT the same for the two items, and the difference is the design input:
--     captain_memory_shard   p_wave >= 2   and random() < captain_shard_drop_rate      (0171)
--     blueprint_fragment     p_wave >= 8   and random() < blueprint_fragment_drop_rate (0185, which
--                                          calls it "the DEEP-RUN gate", the engine_parts depth)
-- Wave depth was the axis, and this slice deletes waves. SITE DIFFICULTY replaces it — the one axis
-- that already exists as data, that location_loot is already keyed by, and that needs no new
-- mechanism. So the shallow gate becomes "not at the easiest site" and the deep gate becomes "the
-- hardest site only":
--     captain_memory_shard   Reaver (t2, difficulty 15) and Blackden (t3, 25)   — NOT Snare
--     blueprint_fragment     Blackden only (t3, difficulty 25)
-- Keeping the shard off Snare is what preserves the gating INTENT: Snare is difficulty 10 and took
-- 28 of the 44 sorties ever fought, so authoring it there would make the recruit ingredient
-- trivially farmable at the easiest site — the opposite of a gate. (An elapsed-presence threshold
-- inside the encounter would be closer to the original "you went deeper" feel, and it was rejected:
-- it needs a new mechanism and a second gating authority beside the site row, to reproduce an axis
-- whose own measurement says it was never reached — 21 of 25 extractions happened at depth <= 7
-- waves, and blueprint_fragment has never dropped once in the game's history.)
--
-- ── THE RATE IS NOT INVENTED. IT MIGRATES FROM THE KNOB, AT APPLY TIME ─────────────────────────
-- drop_chance is read out of the very game_config keys that gated these drops, in this statement,
-- so each environment carries its OWN value across rather than a number I typed: a fresh CI database
-- seeded 0/0 (0171:77, 0185:96) stays at 0/0 and its loot stays fully deterministic, and production
-- carries whatever the owner actually set. That is what "wire the knobs to the new rows" means here,
-- and it is why section 4 can then delete the knobs without losing a tuning decision.
--
-- WHAT THAT MEANS FOR EACH FAUCET, PLAINLY:
--   * captain_memory_shard lands at whatever captain_shard_drop_rate holds. If that is still 0 — as
--     the 2026-08-02 audit recorded, which is why captains are ALREADY unobtainable today — then the
--     SOURCE now exists and is authored while the faucet stays shut, which is exactly production's
--     current posture. Turning captains on becomes a row edit with no deploy. It is NOT turned on
--     here: activating a progression system the owner deliberately left at 0 is their call, not a
--     side effect of a combat slice.
--   * blueprint_fragment lands at whatever blueprint_fragment_drop_rate holds. This one IS a real
--     improvement and it is declared rather than smuggled: the old gate was wave >= 8, and the
--     measurement says depth >= 8 is 5 deaths to 1 extraction and the fragment has NEVER dropped in
--     44 encounters. Moving the same rate onto "an enemy destroyed at Blackden" makes the shipyard's
--     only repeatable faucet actually reachable for the first time, behind the hardest site in the
--     game. The per-fight yield under the new cadence is UNMEASURED and must be read off production.
insert into public.location_loot (location_id, item_id, quantity, drop_chance, note)
select l.id, v.item_id, v.qty, coalesce(cfg_num(v.rate_key), 0), v.note
  from (values
    ('Reaver',   'captain_memory_shard', 1, 'captain_shard_drop_rate',
     '0171 wave>=2 shard faucet, re-gated onto site difficulty; rate migrated from the knob'),
    ('Blackden', 'captain_memory_shard', 1, 'captain_shard_drop_rate',
     '0171 wave>=2 shard faucet, re-gated onto site difficulty; rate migrated from the knob'),
    ('Blackden', 'blueprint_fragment',   1, 'blueprint_fragment_drop_rate',
     '0185 wave>=8 deep-run faucet, re-gated onto the hardest site; rate migrated from the knob')
  ) as v(name, item_id, qty, rate_key, note)
  join public.locations l on l.name = v.name and l.location_type = 'pirate_hunt'
  join public.item_types t on t.item_id = v.item_id
on conflict (location_id, item_id) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 3 — THE CLOCK COLUMN, AND EVERY FIGHT ALREADY IN FLIGHT
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- ONE WRITER: public.combat_pressure_step. Nothing else in the database writes this column, which
-- is what makes "the clock" a thing rather than a convention.
alter table public.combat_encounters
  add column if not exists next_reinforcement_at timestamptz;

comment on column public.combat_encounters.next_reinforcement_at is
  '0344: when the next reinforcement is DUE at this fight. Sole writer public.combat_pressure_step. NULL means unstamped, and the authority reads coalesce(next_reinforcement_at, started_at) — the clock starts when the fight started. Never advanced by a kill, a wave or a wipe.';

-- THE BACKFILL. Production is a live ~30-player game and encounters are in flight at the instant
-- this applies. They carry a waves_cleared history and no clock. Each gets a FULL CADENCE of grace
-- from now, rather than a body on the first tick after the deploy — a fight that was mid-wave
-- should not be handed a reinforcement in the same breath as the rules changing under it.
-- This is belt-and-braces, not the mechanism: the coalesce in the authority already resolves an
-- unstamped row correctly, which is what makes an encounter created a millisecond after this
-- commits — by a creator this slice does not re-emit — behave identically.
update public.combat_encounters ce
   set next_reinforcement_at = now() + make_interval(secs => lp.reinforcement_seconds),
       updated_at = now()
  from public.location_pressure lp
 where lp.location_id = ce.location_id
   and ce.status in ('active', 'retreating')
   and ce.next_reinforcement_at is null;


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 4 — THE KNOBS: one compensation applied, five dead rows deleted
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- reward_metal_base 10 -> 20. The measured compensation for deleting the danger term from the
-- payout: across all 57 logged payouts the term contributed 1852 - 939 = 913 metal, and doubling
-- the base restores it per payout. This is an economy-wide value affecting ~30 live players and it
-- is applied HERE rather than left as a follow-up, so the slice is income-neutral by intent
-- instead of quietly halving the faucet.
insert into public.game_config (key, value, description)
values ('reward_metal_base', '20'::jsonb,
        '0344: metal paid per enemy destroyed, before greatest(locations.reward_tier,1) and reward_multiplier. Raised 10 -> 20 as the measured compensation for deleting reward_danger_scale (57 logged payouts: 1852 -> 939 without it).')
on conflict (key) do update
  set value = excluded.value, description = excluded.description, updated_at = now();

-- THE FOUR ROWS NOTHING READS ANY MORE. A live knob that gates nothing is not harmless: it is a
-- thing a later slice will find, believe, and wire to something. 0320 deleted eight for the same
-- reason. Their absence is asserted in (g), not promised.
--
-- ⛔ enemy_synthetic_max_units IS DELIBERATELY *NOT* IN THIS LIST, and the reason is a correction
-- to this file's own first draft. It was originally deleted here as a fifth dead knob. It is NOT
-- dead: public.resolve_location_encounter still reads it as the ceiling that trims an AUTHORED
-- plan — `v_ceiling := greatest(1, coalesce(cfg_num('enemy_synthetic_max_units'), 6)::integer)`
-- (0260:290, re-created 0261:190 and 0272:270) — and that function is not touched by this slice.
-- Deleting the row would leave that clamp on its coalesce fallback of 6, which is invisible if
-- production still holds 6 and a SILENT ceiling change if production has drifted off it. I cannot
-- read production from here, so the safe act is to leave the row alone: this slice's requirement is
-- that the TICK stops reading it, and assert (a) proves exactly that (0 occurrences in the tick).
-- scripts/elite-stat-wiring-proof.sql:391 also WRITES this key to establish that clamp as its own
-- precondition — deleting a row a proof owns is the harness-vs-drop trap that cost 0232.
delete from public.game_config
 where key in ('enemy_hp_danger_scale', 'enemy_attack_danger_scale', 'reward_danger_scale',
               'danger_time_divisor_seconds');

-- ── THE TWO DROP-RATE KNOBS: WIRED INTO THE ROWS ABOVE, THEN DELETED ───────────────────────────
-- captain_shard_drop_rate and blueprint_fragment_drop_rate gated the two chance drops inside
-- pirate_loot_for_wave. Section 2 has already COPIED each one's live value into its
-- location_loot.drop_chance, so the tuning is preserved and merely moved to where the authority
-- now is. Leaving them would be worse than deleting them: after this migration
-- pirate_loot_for_wave has NO caller among public functions (asserted in (i) below — 0185's two
-- calls are inside its own already-run apply-time DO block, not a function), so they would be live
-- knobs controlling literally nothing, which is the liability this section exists to remove.
-- Their values are echoed to the deploy log first, so the log records what was migrated.
do $knobs$
declare v_shard text; v_bp text;
begin
  select value #>> '{}' into v_shard from public.game_config where key = 'captain_shard_drop_rate';
  select value #>> '{}' into v_bp    from public.game_config where key = 'blueprint_fragment_drop_rate';
  raise notice '0344 drop-rate migration: captain_shard_drop_rate = % and blueprint_fragment_drop_rate = % have been copied into public.location_loot.drop_chance (shard -> Reaver + Blackden, fragment -> Blackden) and the knob rows are now deleted. To change either faucet from here on, update the ROW; there is no knob and no deploy.',
    coalesce(v_shard, '<absent>'), coalesce(v_bp, '<absent>');
end $knobs$;

delete from public.game_config
 where key in ('captain_shard_drop_rate', 'blueprint_fragment_drop_rate');


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 5 — THE AUTHORITIES
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── site_loot_for_kill — WHAT ONE DEAD ENEMY IS WORTH, IN ITEMS ─────────────────────────────────
-- One reader of public.location_loot, and the only thing the engine asks about item drops. Quantity
-- scales with the number of bodies destroyed and with nothing else — not with wave, not with depth,
-- not with time.
--
-- ONE ROLL PER (ITEM, ENEMY DESTROYED). The cross join against generate_series is what makes that
-- literal: each authored row is offered once per body, so a deterministic row (drop_chance 1.0)
-- pays quantity x kills exactly as before, and a gated row pays a binomial count. random() returns
-- [0,1), so `random() < 1.0` is true for every roll and `random() < 0` for none — the two ends need
-- no special case, and a chance-0 row is inert rather than absent.
--
-- VOLATILE, not stable: it rolls. That is the same forcing 0171 recorded when it made
-- pirate_loot_for_wave volatile ("reads game_config + random() — both illegal under immutable"),
-- and it is why the gated rows carry their chance rather than the function reading a knob.
--
-- DETERMINISM WHERE IT MATTERS, STATED: on a fresh CI database both gated keys seed at 0 (0171:77,
-- 0185:96), so every location_loot row there has drop_chance 1.0 or 0 and this function is exactly
-- as deterministic as the loot it replaced. A proof that reads a site's authored rows gets a stable
-- answer; one that wants a certain item should select on drop_chance >= 1, which is what
-- scripts/team-command-proof.sql's TEAMSETTLE now does.
create or replace function public.site_loot_for_kill(p_location uuid, p_kills integer)
returns jsonb
language sql
volatile
security definer
set search_path to 'public'
as $slk$
  select coalesce(
    jsonb_agg(jsonb_build_object('item_id', s.item_id, 'quantity', s.qty) order by s.item_id),
    '[]'::jsonb)
  from (
    select ll.item_id, sum(ll.quantity)::integer as qty
      from public.location_loot ll
      cross join generate_series(1, greatest(coalesce(p_kills, 0), 0)) as k
     where ll.location_id = p_location
       and ll.quantity > 0
       and random() < ll.drop_chance
     group by ll.item_id
  ) s;
$slk$;

revoke all on function public.site_loot_for_kill(uuid, integer) from public;
revoke all on function public.site_loot_for_kill(uuid, integer) from anon, authenticated;


-- ── combat_pressure_step — THE ONE PLACE ANOTHER ENEMY COMES FROM ───────────────────────────────
--
-- THE WHOLE OF D3 LIVES IN WHAT THIS FUNCTION READS. It reads the SITE, the CLOCK and the FIELD.
-- It does not read waves_cleared, wave_number, danger_level, a wipe, a death, a kill count or
-- elapsed presence — and self-assert (d) reads its body back to prove that, so the rule is
-- enforced by the deploy rather than by this paragraph.
--
-- THE THREE RULES, EACH VISIBLE IN THE CODE BELOW:
--   RULE 1  There is no branch here on a death. The only gate on spawning is "is a body DUE" and
--           "is the field under its cap". A kill can move the second one — that is what a cap IS —
--           but it can never make an arrival happen, because arrivals are decided by the clock
--           alone and the clock is only ever advanced forward by this one statement.
--   RULE 2  At most ONE body per call, ever. When the clock is behind — a cron stall, a long spell
--           at cap — the skip-forward "due + cadence * (missed + 1)" walks past every elapsed slot
--           in one step. Nothing is stored, so a death cannot release a stored arrival. There is
--           no loop in this function and there must never be one.
--   RULE 3  The cadence is the site row's column. It is not divided by anything, not scaled by
--           elapsed presence and not a function of the population. Population already accumulates;
--           moving cadence as well would make a bad balance outcome unattributable.
--
-- COMPOSED, NEVER REIMPLEMENTED. combat_spawn_wave_units (0339) is still the schema's sole
-- inserter of an enemy row, and it is called with count = 1; the measured formation clearance,
-- combat_formation_point and combat_wave_arrival_phase's coincident-point guard all stay inside
-- it, untouched. The four enemy stat formulas are the head's own, character for character, with
-- the danger factor removed and nothing else changed.
--
-- WHY IT TAKES A TICK AND A SEQ. Both are the caller's facts, exactly as combat_encounter_wreck
-- takes p_tick: the tick number is e.tick_number + 1 in the caller and the row here still holds
-- the old one, and the event sequence is the tick's running counter. Deriving either from the row
-- would write a wrong observable rather than a missing one.
--
-- WHY IT REPORTS A CEILING. "enemy_integrity_max" used to mean "the wave total". There are no
-- waves, so it becomes the SITE'S CEILING — cap x one body's nominal hp — a stable denominator
-- that makes the client's enemy bar read "how full is the field" rather than "how much of this
-- tick's damage has landed". It is computed from the same row the cap comes from, so there is one
-- place to change it.
--
-- THE TWO RENDERINGS OF "POPULATION", AND WHY BOTH ARE IN HERE. An encounter whose units carry
-- positions has bodies and they are counted. The 0228 arm carries no combat_units at all, so its
-- population is its scalar hp divided by one body's nominal hp. That is ONE rule in TWO
-- vocabularies, and it lives inside the authority rather than beside it precisely so the aggregate
-- arm cannot grow a second pressure model while it waits for 0345 to delete it. The authority
-- spawns a ROW only for the arm that has rows — inserting one into the 0228 arm would flip a live
-- fight onto the spatial arm mid-flight, which the tick's own header forbids one line above
-- v_is_spatial.
--
-- FAIL-CLOSED ON UNAUTHORED CONTENT. A site with no location_pressure row hosts no reinforcements:
-- this returns without spawning and without advancing anything. Section 1 asserts that no ACTIVE
-- pirate-hunt site is in that state, so the closed door is a guard, not a live path.
create or replace function public.combat_pressure_step(
  p_encounter   uuid,
  p_tick        integer,
  p_anchor_x    double precision,
  p_anchor_y    double precision,
  p_site_x      double precision,
  p_site_y      double precision,
  p_seq         integer,
  p_log_events  boolean,
  out o_arrived    integer,
  out o_body_hp    double precision,
  out o_ceiling_hp double precision)
language plpgsql
security definer
set search_path to 'public'
as $cps$
declare
  e         combat_encounters%rowtype;
  s         record;
  v_due     timestamptz;
  v_pop     integer;
  v_bodied  boolean;
  v_nominal double precision;
  v_missed  integer;
  v_var     double precision;
begin
  o_arrived := 0; o_body_hp := 0; o_ceiling_hp := 0;
  if p_encounter is null or p_tick is null then
    raise exception 'combat_pressure_step: called with encounter=% tick=% — pressure needs both, and defaulting either would spawn against a wrong clock rather than fail loudly', p_encounter, p_tick;
  end if;
  -- Keyed on the primary key, so this reads one row or none. It is never a scan whose first row
  -- happens to answer.
  select * into e from public.combat_encounters where id = p_encounter;
  if not found then
    raise exception 'combat_pressure_step: encounter % does not exist — its caller is iterating a row that is gone', p_encounter;
  end if;

  -- THE SITE. One read, one row, and it is the only content this function has.
  select l.base_difficulty      as base_difficulty,
         lp.reinforcement_seconds as cadence,
         lp.concurrent_cap      as cap,
         lp.enemy_unit_type_id  as unit_type_id
    into s
    from public.location_pressure lp
    join public.locations l on l.id = lp.location_id
   where lp.location_id = e.location_id;
  if not found then
    return;   -- unauthored site: no pressure, no clock movement. Fail closed.
  end if;

  v_nominal    := s.base_difficulty * coalesce(cfg_num('enemy_hp_base'), 14);
  o_ceiling_hp := v_nominal * s.cap;

  -- A RETREATING FLEET IS NEVER REINFORCED — 0336's rule, preserved. The offense gate silences the
  -- player during the retreat window while the enemy side is never gated, so sending a body into
  -- that window would be shooting at a fleet that cannot answer.
  if e.status <> 'active' then
    return;
  end if;

  -- THE CLOCK. An unstamped row is due when the fight started; see the header's in-flight section.
  v_due := coalesce(e.next_reinforcement_at, e.started_at);
  if v_due is null or now() < v_due then
    return;
  end if;

  -- THE FIELD. Two vocabularies, one rule: how many BODIES are standing.
  v_bodied := exists (select 1 from public.combat_units
                       where encounter_id = e.id and pos_x is not null);
  if v_bodied then
    select coalesce(sum(alive_count), 0) into v_pop
      from public.combat_units
     where encounter_id = e.id and side = 'enemy' and alive_count > 0;
  else
    v_pop := ceil(greatest(0, coalesce(e.enemy_integrity_current, 0)) / greatest(v_nominal, 1))::integer;
  end if;

  if v_pop < s.cap then
    -- ONE BODY. Never a wave, never a count derived from anything the player did.
    v_var     := coalesce(cfg_num('combat_damage_variance_pct'), 0.10);
    o_body_hp := v_nominal * ((1 - v_var) + random() * (2 * v_var));
    o_arrived := 1;
    if v_bodied then
      perform public.combat_spawn_wave_units(
        e.id, e.player_id, s.unit_type_id, 1, o_body_hp,
        coalesce(cfg_num('enemy_synthetic_speed_base'),3)
          + s.base_difficulty * coalesce(cfg_num('enemy_synthetic_speed_per_difficulty'),0.2),
        coalesce(cfg_num('enemy_synthetic_range_base'),120)
          + s.base_difficulty * coalesce(cfg_num('enemy_synthetic_range_per_difficulty'),5),
        coalesce(cfg_num('enemy_synthetic_projectile_speed'),250),
        s.base_difficulty * coalesce(cfg_num('enemy_attack_base'),1.0),
        coalesce(cfg_num('enemy_synthetic_cooldown_seconds'),2),
        p_anchor_x, p_anchor_y, p_site_x, p_site_y, v_pop);
    end if;
    -- SILENCE IS A BUG. An arrival the player is never told about reads as a broken game, so the
    -- event is emitted here — once, by the authority — rather than at two call sites.
    if p_log_events then
      insert into public.combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
        values (e.id, e.player_id, p_tick, coalesce(p_seq, 0), 'wave_spawned', 'pirate', 'player',
                jsonb_build_object('reinforcement', true, 'units', 1,
                                   'hp', round(o_body_hp), 'population', v_pop + 1, 'cap', s.cap));
    end if;
  end if;

  -- THE CLOCK ADVANCES WHETHER OR NOT A BODY LANDED — that is exactly what "a suppressed arrival is
  -- LOST, not banked" means — and it skips past every slot already elapsed in ONE step, so nothing
  -- accumulates while the field sits at its cap or while a cron pass is missed. This is the only
  -- statement in the database that writes next_reinforcement_at.
  v_missed := floor(extract(epoch from (now() - v_due)) / s.cadence)::integer;
  update public.combat_encounters
     set next_reinforcement_at = v_due + make_interval(secs => s.cadence * (v_missed + 1)),
         updated_at = now()
   where id = e.id;
end;
$cps$;

-- ENGINE INTERNAL. Revoked from PUBLIC BY NAME — the 0309 lesson: a revoke naming only anon and
-- authenticated leaves PUBLIC's default EXECUTE standing.
revoke all on function public.combat_pressure_step(uuid, integer, double precision, double precision, double precision, double precision, integer, boolean) from public;
revoke all on function public.combat_pressure_step(uuid, integer, double precision, double precision, double precision, double precision, integer, boolean) from anon, authenticated;


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 6 — THE SURGERY
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- Eleven hunks, applied to the body that is actually DEPLOYED. Each carries its source text verbatim
-- and each must match it EXACTLY ONCE: zero means the anchor is gone and the patch would silently
-- do nothing, more than one means it is ambiguous and could land on the wrong site. Both abort.
-- Everything outside the eleven hunks is untouched by construction — that is the whole reason this is
-- a surgery and not a re-typed body.
do $rw$
declare
  v_def text;
  v_new text;
  r     record;
  v_n   integer;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  v_new := v_def;
  for r in
    select * from (values
      ('P0',
       $p0o$
  v_danger        integer;
$p0o$,
       $p0n$
  -- ██ HUNK [P0] (0344) — v_danger IS DELETED, NOT SCALED ██
  -- One integer meant five things at once: the number of enemy BODIES, the enemy HP multiplier,
  -- the enemy ATTACK multiplier, the LOOT multiplier and the player-visible "Danger N". Every one
  -- of those readings carried "+ e.waves_cleared", so destroying an enemy fleet made the next one
  -- bigger, tougher and harder-hitting. The owner has rejected that three times, most recently in
  -- these words: "I told you that it will be not +1 fleets when fleet is destroyed."
  -- IT IS DELETED RATHER THAN TUNED. A knob that multiplies the term by zero, or a band that fires
  -- it every fifth kill, PRESERVES the mechanism — that was PR #397 and it was closed for exactly
  -- this reason. There is no way to reach the old behaviour from this body.
  -- WHAT REPLACES IT: public.combat_pressure_step, a CLOCK. Pressure is a function of WHICH SITE
  -- you are at and HOW LONG you have been there, and of nothing a player kill can move. These five
  -- locals are its entire footprint inside the tick.
  v_pressure_arrived   integer;           -- 0 or 1 — bodies that ARRIVED this tick, from the clock
  v_body_hp            double precision;  -- one reinforcement body's hp, rolled from the site row
  v_enemy_alive_before integer;           -- enemy bodies standing before this tick's damage
  v_enemy_alive_after  integer;           -- ...and after it. Their difference is the LOOT UNIT.
  v_kills              integer;           -- enemy bodies destroyed this tick, by anyone
$p0n$),
      ('P1',
       $p1o$
      v_danger   := 1 + e.waves_cleared + floor(v_secs_inside / coalesce(cfg_num('danger_time_divisor_seconds'), 180))::integer;
      v_variance := (1 - v_var_pct) + random() * (2 * v_var_pct);
      v_offense  := (e.status = 'active');
      v_wave_num := e.wave_number;
      v_seq      := 0;
      v_wave_paused := false;

      select coalesce(sum(hp_current), 0) into v_e_before from combat_units where encounter_id = e.id and side = 'enemy';

      -- Wave lifecycle: spawn a fresh synthetic pirate wave when the enemy side is wiped — the exact
      -- mirror of the aggregate arm's `enemy_integrity_current <= 0` branch, now materialized as
      -- combat_units rows split across N units instead of a lone scalar.
      if v_e_before <= 0 then
        -- ██ 0336 A RETREATING FLEET IS NEVER SENT A FRESH WAVE ██
        -- The offense gate below silences the PLAYER while retreating; the enemy side is never
        -- gated, by design (the aggregate arm's asymmetry, mirrored). But this block had NO status
        -- guard at all, so clearing a wave during the retreat window spawned a LARGER one — danger
        -- rises with waves_cleared — that then shot at a fleet which could not shoot back for the
        -- remaining seconds of the window. Production carries four encounters that died exactly
        -- that way, 3.4 to 5.8 seconds into an 8-second window, and a death is a 'defeat', which
        -- zeroes total_rewards_json: the whole haul, destroyed by pressing Retreat.
        -- ONE CONDITION, AND NO NEW PATH: a retreating encounter with a cleared enemy side simply
        -- carries its ceiling over, exactly as an ONGOING wave does in the else arm below, and
        -- falls through to the normal per-tick bookkeeping. Nothing is spawned, no new tick label
        -- is invented, and branch (B) above still completes the retreat when the delay elapses.
        if e.status = 'retreating' then
          v_enemy_hp := e.enemy_integrity_max;
        elsif e.next_wave_at is not null and now() < e.next_wave_at then
          v_wave_paused := true;
          if v_log_ticks then
            insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
                   player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after, result)
              values (e.id, e.player_id, v_tick, v_wave_num, v_danger, v_hp_total, v_hp_total, 0, 0, 'next_wave_incoming');
          end if;
          update combat_encounters set tick_number=v_tick, danger_level=v_danger, last_resolved_at=now(), updated_at=now() where id=e.id;
          v_count := v_count + 1;
        else
          -- E3 (0260): a resolved encounter REUSES its own plan on every wave (resolved_plan_json set) —
          -- never re-resolving, which with cap=1 would count the encounter against itself and degrade
          -- wave 2+ to a synthetic wave while the sticky tag still paid the resolved reward. Only a FRESH
          -- encounter (tag NULL) calls the resolver, so cap/cooldown apply just at first resolution
          -- (correctly excluding self — the tag is written AFTER the first spawn). A NULL plan (resolver
          -- dark / no binding / cap / cooldown / no unit) falls through to the VERBATIM pre-E3 wave below.
          v_fresh_resolve := false;
          if v_resolver_engaged then
            if e.resolved_plan_json is not null then
              v_plan := e.resolved_plan_json;
            else
              v_plan := public.resolve_location_encounter(e.location_id, e.id::text);
              v_fresh_resolve := true;
            end if;
          end if;
          if v_resolver_engaged and v_plan is not null then
            -- E3 (0260) RESOLVED WAVE: instantiate the authored plan. SAME pacing formulas as the
            -- synthetic arm (690-703), substituting each unit-archetype base_difficulty and the
            -- plan's rolled count; every unit spawns at the ENGAGEMENT ANCHOR with the identical
            -- weapons_json shape. Tags the encounter + upserts the runtime ledger; emits a resolved
            -- wave_spawned event.
            -- ██ HUNK [T5] (0294): the head re-read the LOCATION here. That read is GONE; the spawn
            -- ██ point is the anchor resolved once at the top of the loop.
            v_wave_num := e.waves_cleared + 1;
            v_enemy_proj_speed := coalesce(cfg_num('enemy_synthetic_projectile_speed'),250);
            v_enemy_cooldown   := coalesce(cfg_num('enemy_synthetic_cooldown_seconds'),2);
            delete from combat_units where encounter_id = e.id and side = 'enemy';
            v_e_before := 0;
            -- ██ 0339 THE MEASUREMENT MOVED INTO THE SPAWN AUTHORITY ██
            -- 0336's extent measurement stood here AND, character for character bar its indentation,
            -- in the synthetic arm below. Two copies of one measurement is how the two arms drift.
            -- It now lives once, inside combat_spawn_wave_units, beside the radius that consumes it.
            -- v_spawn_slot survives in the TICK because it is the one piece of state the fold cannot
            -- own: the resolved arm carries it ACROSS plan archetypes, so a plan of several unit
            -- types still lays out one ring instead of restarting at slot 0 per archetype.
            v_spawn_slot := 0;
            for v_weapon in select value from jsonb_array_elements(v_plan->'units') loop
              v_enemy_count := (v_weapon->>'count')::integer;
              continue when v_enemy_count <= 0;   -- FIX 4: a 0-count plan unit spawns nothing (no phantom 1)
              v_enemy_hp     := (v_weapon->>'base_difficulty')::double precision * coalesce(cfg_num('enemy_hp_base'),14)
                                * (1 + v_danger * coalesce(cfg_num('enemy_hp_danger_scale'),0.6)) * v_variance;
              v_enemy_attack := (v_weapon->>'base_difficulty')::double precision * coalesce(cfg_num('enemy_attack_base'),1.0)
                                * (1 + v_danger * coalesce(cfg_num('enemy_attack_danger_scale'),0.25));
              v_enemy_range  := coalesce(cfg_num('enemy_synthetic_range_base'),120)
                                + (v_weapon->>'base_difficulty')::double precision * coalesce(cfg_num('enemy_synthetic_range_per_difficulty'),5);
              v_enemy_speed  := coalesce(cfg_num('enemy_synthetic_speed_base'),3)
                                + (v_weapon->>'base_difficulty')::double precision * coalesce(cfg_num('enemy_synthetic_speed_per_difficulty'),0.2);
              v_enemy_unit_hp    := v_enemy_hp / v_enemy_count;
              v_enemy_unit_power := v_enemy_attack / v_enemy_count;
              -- ██ 0339 ONE SPAWN AUTHORITY — THE LOOP WAS WRITTEN TWICE ██
              -- This block and the synthetic arm below were the SAME ~15 lines at two indentations:
              -- measure the formation extent, zero the slot, loop the count, ask combat_formation_point
              -- at (extent + range + 1) on combat_wave_arrival_phase's bearing, INSERT, bump the slot.
              -- Every migration since 0299 had to patch both in lockstep, and most of 0338's guard
              -- machinery existed only to police the fork (it counts the leaf composition twice and the
              -- radius twice, because there were two). Spaghetti. Folded, not written up.
              -- WHAT LEGITIMATELY DIFFERS BETWEEN THE ARMS SURVIVES, AND IT IS THE STATS: this arm
              -- takes unit_type_id, hp, power, range and speed from the AUTHORED PLAN's archetype; the
              -- synthetic arm derives them from loc.base_difficulty and the knobs. Those are arguments.
              -- The PLACEMENT never differed at all, so there is now one of it.
              -- The radius, the phase, the measured extent and 0336's clearance invariant are carried
              -- into the leaf unchanged — this fold moves no geometry, no knob and no value.
              v_spawn_slot := public.combat_spawn_wave_units(
                e.id, e.player_id, v_weapon->>'unit_type_id', v_enemy_count, v_enemy_unit_hp,
                v_enemy_speed, v_enemy_range, v_enemy_proj_speed, v_enemy_unit_power, v_enemy_cooldown,
                v_anchor_x, v_anchor_y, loc.x, loc.y, v_spawn_slot);
              v_e_before := v_e_before + v_enemy_hp;
            end loop;
            v_enemy_hp := v_e_before;   -- the wave TOTAL (enemy_integrity_max mirrors the synthetic arm)
            if v_fresh_resolve then
              -- tag + the cooldown/active-count ledger are written ONLY at first resolution; a reused
              -- plan (wave 2+) leaves both untouched so the cooldown anchors on the FIRST spawn only.
              update combat_encounters set resolved_plan_json = v_plan where id = e.id;
              insert into encounter_runtime_state (location_id, encounter_profile_id, last_spawn_at, active_count)
                values (e.location_id, (v_plan->>'encounter_profile_id')::uuid, now(), 1)
                on conflict (location_id, encounter_profile_id)
                do update set last_spawn_at = now(), active_count = encounter_runtime_state.active_count + 1;
            end if;
            if v_log_events then
              insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
                values (e.id, e.player_id, v_tick, v_seq, 'wave_spawned', 'pirate', 'player',
                        jsonb_build_object('wave', v_wave_num, 'danger', v_danger, 'hp', round(v_e_before), 'units', jsonb_array_length(v_plan->'units'), 'resolved', true));
            end if;
            v_seq := v_seq + 1;
          else
          v_wave_num     := e.waves_cleared + 1;
          -- SAME wave-hp/wave-attack formulas the aggregate arm has always used — UNCHANGED config
          -- keys — so a spatial wave's total hp/dps matches what the aggregate arm would have rolled.
          v_enemy_hp     := loc.base_difficulty * coalesce(cfg_num('enemy_hp_base'),14)
                            * (1 + v_danger * coalesce(cfg_num('enemy_hp_danger_scale'),0.6)) * v_variance;
          v_enemy_attack := loc.base_difficulty * coalesce(cfg_num('enemy_attack_base'),1.0)
                            * (1 + v_danger * coalesce(cfg_num('enemy_attack_danger_scale'),0.25));
          v_enemy_count  := least(coalesce(cfg_num('enemy_synthetic_max_units'),6)::integer, greatest(1, v_danger));
          -- ██ HUNK [T6] (0294): the head re-read the LOCATION here. That read is GONE; the spawn
          -- ██ point is the anchor resolved once at the top of the loop. THIS is the block that seeds
          -- ██ WAVE ONE as well as every later wave — the encounter creator writes no enemy row at
          -- ██ all — so this single line is what put an intercept's pirates at the location centre
          -- ██ while the player's own fleet sat at the ambush point.
          v_enemy_range      := coalesce(cfg_num('enemy_synthetic_range_base'),120)
                                 + loc.base_difficulty * coalesce(cfg_num('enemy_synthetic_range_per_difficulty'),5);
          v_enemy_speed      := coalesce(cfg_num('enemy_synthetic_speed_base'),3)
                                 + loc.base_difficulty * coalesce(cfg_num('enemy_synthetic_speed_per_difficulty'),0.2);
          v_enemy_proj_speed := coalesce(cfg_num('enemy_synthetic_projectile_speed'),250);
          v_enemy_cooldown   := coalesce(cfg_num('enemy_synthetic_cooldown_seconds'),2);
          v_enemy_unit_hp    := v_enemy_hp / v_enemy_count;
          v_enemy_unit_power := v_enemy_attack / v_enemy_count;

          -- Pirates spawn AT THE ENGAGEMENT ANCHOR (0294) — every synthetic unit lands at the same
          -- point, and that point is now where the fight actually is rather than where its location is.
          delete from combat_units where encounter_id = e.id and side = 'enemy';
          -- ██ 0339 ONE SPAWN AUTHORITY — THE LOOP WAS WRITTEN TWICE ██
          -- The other half of the fork. Identical to the resolved arm above bar its indentation and
          -- the STATS, which are the real difference and are passed as arguments: this arm derives
          -- them from loc.base_difficulty and the knobs, the resolved arm from the authored plan.
          -- The slot counter still starts at 0 here because a synthetic wave is one archetype.
          v_spawn_slot := 0;
          v_spawn_slot := public.combat_spawn_wave_units(
            e.id, e.player_id, 'pirate_synthetic', v_enemy_count, v_enemy_unit_hp,
            v_enemy_speed, v_enemy_range, v_enemy_proj_speed, v_enemy_unit_power, v_enemy_cooldown,
            v_anchor_x, v_anchor_y, loc.x, loc.y, v_spawn_slot);
          v_e_before := v_enemy_hp;  -- the fresh wave's starting total (mirrors the aggregate arm's v_e_before)
          if v_log_events then
            insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
              values (e.id, e.player_id, v_tick, v_seq, 'wave_spawned', 'pirate', 'player',
                      jsonb_build_object('wave', v_wave_num, 'danger', v_danger, 'hp', round(v_enemy_hp), 'units', v_enemy_count));
          end if;
          v_seq := v_seq + 1;
          end if;
        end if;
      else
        v_enemy_hp := e.enemy_integrity_max;  -- ongoing wave: the ceiling carries over, unchanged
      end if;
$p1o$,
       $p1n$
      -- ██ HUNK [P1] (0344) — PRESSURE IS A CLOCK, NOT A CONSEQUENCE OF KILLING ██
      -- 170 lines stood here and they were ONE arrow: "the enemy side is empty" -> "spawn a wave",
      -- sized "least(enemy_synthetic_max_units, greatest(1, v_danger))" where v_danger began
      -- "1 + e.waves_cleared". Clearing a wave literally spawned one more enemy, at
      -- x(1 + danger*0.6) hp and x(1 + danger*0.25) attack. Measured on production: Snare
      -- encounter 520a35c0 ran 1->1 body->203 hp, 2->2->319, 3->3->427, 4->4->505, 5->5->545,
      -- 6->6->587, then pinned at 6 bodies while wave hp climbed to 1036 - 5.1x - purely because
      -- the player kept winning.
      -- THE ARROW IS GONE. There is no branch here that reads a death, a wipe, a wave or a
      -- waves_cleared. The tick asks the pressure authority the same question on every pass,
      -- unconditionally, and the authority answers from the clock alone.
      -- WHAT ELSE DIED WITH IT, and each is a SECOND AUTHORITY this slice removes:
      --   - the v_resolver_engaged branch that chose between two wave SIZERS at runtime (it has
      --     already stepped a live fight 18x mid-flight: Reaver 7f56967e, wave 13->14, units 1->6,
      --     hp 123->2213, and the fleet died);
      --   - the encounter_runtime_state cap/cooldown ledger written only by that branch;
      --   - the next_wave_at pause, which exists to pace a thing that no longer happens.
      -- v_variance is still rolled here because the aggregate arm's player-damage roll reads it;
      -- a reinforcement body rolls its OWN hp inside the authority, beside the row it reads.
      v_variance := (1 - v_var_pct) + random() * (2 * v_var_pct);
      v_offense  := (e.status = 'active');
      v_wave_num := e.wave_number;
      v_seq      := 0;
      v_wave_paused := false;

      select p.o_arrived, p.o_body_hp, p.o_ceiling_hp
        into v_pressure_arrived, v_body_hp, v_enemy_hp
        from public.combat_pressure_step(e.id, v_tick, v_anchor_x, v_anchor_y, loc.x, loc.y, v_seq, v_log_events) p;
      if v_pressure_arrived > 0 then v_seq := v_seq + 1; end if;

      -- The field, AFTER any arrival and BEFORE any damage. Both numbers are read from the one
      -- place enemy bodies live, in one statement, so the hp the damage step works against and the
      -- body count the loot step works against can never describe different worlds.
      select coalesce(sum(hp_current), 0), coalesce(sum(alive_count), 0)
        into v_e_before, v_enemy_alive_before
        from combat_units where encounter_id = e.id and side = 'enemy';
      -- enemy_integrity_max is now the SITE'S CEILING (cap x one body's nominal hp) rather than
      -- "the wave total", because there are no waves: a stable denominator is what makes the
      -- client's enemy bar mean "how full is the field" instead of "how much of this tick's
      -- damage has landed". A retreating or unauthored encounter gets no ceiling from the
      -- authority, and keeps whatever it already had.
      if v_enemy_hp is null or v_enemy_hp <= 0 then
        v_enemy_hp := greatest(coalesce(e.enemy_integrity_max, 0), v_e_before);
      end if;
$p1n$),
      ('P2',
       $p2o$
        select coalesce(sum(hp_current), 0) into v_e_after from combat_units where encounter_id = e.id and side = 'enemy';
        v_cleared := v_offense and v_e_after <= 0;
        select coalesce(sum(hp_current), 0) into v_hp_after from combat_units where encounter_id = e.id and side = 'player';

        v_reward_metal := 0; v_reward_delta := '{}'::jsonb; v_loot_items := '[]'::jsonb;
        if v_cleared then
          -- E3 (0260): a resolved encounter draws its reward from the AUTHORED profile via the algebraic
          -- mirror of the pre-E3 formula; else the VERBATIM :898-899 reward line (byte-identical when dark).
          if e.resolved_plan_json is not null and v_resolver_engaged then
            v_reward_metal := public.resolve_encounter_reward_inputs(e.resolved_plan_json->'reward_profile'->'resource_grants', loc.reward_tier, v_danger);
          else
          v_reward_metal := round(coalesce(cfg_num('reward_metal_base'),10) * greatest(loc.reward_tier,1)
                                  * (1 + coalesce(cfg_num('reward_danger_scale'),0.25) * v_danger) * coalesce(cfg_num('reward_multiplier'),1.0));
          end if;
          v_loot_items   := pirate_loot_for_wave(v_wave_num, v_danger);
          v_reward_delta := jsonb_build_object('metal', v_reward_metal, 'items', v_loot_items);
          if v_log_events then
            insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
              values (e.id, e.player_id, v_tick, v_seq, 'explosion', 'player', 'pirate',
                      jsonb_build_object('wave_cleared', true, 'wave', v_wave_num, 'reward_metal', v_reward_metal, 'reward_items', v_loot_items));
            v_seq := v_seq + 1;
          end if;
        end if;
$p2o$,
       $p2n$
        -- ██ HUNK [P2] (0344) — LOOT IS PAID PER ENEMY DESTROYED, FROM SITE ROWS ██
        -- The head paid on a WAVE CLEAR, at
        -- "reward_metal_base x tier x (1 + reward_danger_scale x v_danger)" with items from
        -- "pirate_loot_for_wave(v_wave_num, v_danger)" - a hard-coded ladder gating content on
        -- DEPTH (wave >= 3 / 5 / 8 / 10) with no site term at all, so a tier-3 site paid a tier-1
        -- site's items. Both are kill-depth authorities and both are deleted. Payout is now
        -- decided in exactly two places, both of them ROWS: locations.reward_tier for metal and
        -- location_loot for items.
        -- WHY THE UNIT IS AN ENEMY AND NOT A WAVE: with bodies arriving one at a time on a clock
        -- there is no wave to clear, and paying on "the field happens to be empty" would pay a
        -- fleet that killed one straggler the same as one that broke a full field.
        -- AND WHY v_e_before > 0 IS NOW PART OF v_cleared: an empty field satisfies
        -- "v_e_after <= 0" on EVERY tick. Under the head that could not happen, because an empty
        -- field was immediately refilled by the arrow above. It can happen now - between a kill
        -- and the next scheduled arrival - and without this conjunct the encounter would log a
        -- wave_cleared, and bank a reward, every three seconds forever.
        select coalesce(sum(hp_current), 0), coalesce(sum(alive_count), 0)
          into v_e_after, v_enemy_alive_after
          from combat_units where encounter_id = e.id and side = 'enemy';
        v_kills   := greatest(0, coalesce(v_enemy_alive_before, 0) - coalesce(v_enemy_alive_after, 0));
        v_cleared := v_offense and v_e_before > 0 and v_e_after <= 0;
        if v_cleared then v_wave_num := v_wave_num + 1; end if;
        select coalesce(sum(hp_current), 0) into v_hp_after from combat_units where encounter_id = e.id and side = 'player';

        v_reward_metal := 0; v_reward_delta := '{}'::jsonb; v_loot_items := '[]'::jsonb;
        if v_offense and v_kills > 0 then
          v_reward_metal := round(coalesce(cfg_num('reward_metal_base'),10) * greatest(loc.reward_tier,1)
                                  * coalesce(cfg_num('reward_multiplier'),1.0)) * v_kills;
          v_loot_items   := public.site_loot_for_kill(e.location_id, v_kills);
          v_reward_delta := jsonb_build_object('metal', v_reward_metal, 'items', v_loot_items);
          if v_log_events then
            insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
              values (e.id, e.player_id, v_tick, v_seq, 'explosion', 'player', 'pirate',
                      jsonb_build_object('wave_cleared', v_cleared, 'wave', v_wave_num, 'kills', v_kills, 'reward_metal', v_reward_metal, 'reward_items', v_loot_items));
            v_seq := v_seq + 1;
          end if;
        end if;
$p2n$),
      ('P3',
       $p3o$
            values (e.id, e.player_id, v_tick, v_wave_num, v_danger,
                    v_hp_total, v_e_before, v_dmg_player_total, v_dmg_enemy_total,
$p3o$,
       $p3n$
            values (e.id, e.player_id, v_tick, v_wave_num, 1,
                    v_hp_total, v_e_before, v_dmg_player_total, v_dmg_enemy_total,
$p3n$),
      ('P4',
       $p4o$
          danger_level             = v_danger,
$p4o$,
       $p4n$
          danger_level             = 1,
$p4n$),
      ('P5',
       $p5o$
      v_danger       := 1 + e.waves_cleared + floor(v_secs_inside / coalesce(cfg_num('danger_time_divisor_seconds'), 180))::integer;
      v_variance     := (1 - v_var_pct) + random() * (2 * v_var_pct);
      v_enemy_attack := loc.base_difficulty * coalesce(cfg_num('enemy_attack_base'),1.0)
                        * (1 + v_danger * coalesce(cfg_num('enemy_attack_danger_scale'),0.25));
      v_seq          := 0;
      v_offense      := (e.status = 'active');
      v_wave_num     := e.wave_number;

      if e.enemy_integrity_current <= 0 then
        if e.next_wave_at is not null and now() < e.next_wave_at then
          if v_log_ticks then
            insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
                   player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after, result)
              values (e.id, e.player_id, v_tick, v_wave_num, v_danger, v_hp_total, v_hp_total, 0, 0, 'next_wave_incoming');
          end if;
          update combat_encounters set tick_number=v_tick, danger_level=v_danger, last_resolved_at=now(), updated_at=now() where id=e.id;
          v_count := v_count + 1; continue;
        end if;
        v_wave_num := e.waves_cleared + 1;
        v_enemy_hp := loc.base_difficulty * coalesce(cfg_num('enemy_hp_base'),14)
                      * (1 + v_danger * coalesce(cfg_num('enemy_hp_danger_scale'),0.6)) * v_variance;
        v_e_before := v_enemy_hp;
        if v_log_events then
          insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
            values (e.id, e.player_id, v_tick, v_seq, 'wave_spawned', 'pirate', 'player',
                    jsonb_build_object('wave', v_wave_num, 'danger', v_danger, 'hp', round(v_enemy_hp)));
        end if;
        v_seq := v_seq + 1;
      else
        v_enemy_hp := e.enemy_integrity_max;
        v_e_before := e.enemy_integrity_current;
      end if;
$p5o$,
       $p5n$
      -- ██ HUNK [P5] (0344) — THE 0228 ARM READS THE SAME CLOCK ██
      -- This arm had its own copy of every line P1 deleted: the same v_danger, the same
      -- "enemy_integrity_current <= 0 -> respawn", the same x(1 + danger*0.6) hp and
      -- x(1 + danger*0.25) attack. Measured on production, Reaver 6b6f5ff0 ran danger 1 -> 19 and
      -- wave hp 362 -> 2860 through exactly these lines.
      -- IT CARRIES NO BODIES, so it cannot be given a population - it is a scalar. The pressure
      -- AUTHORITY is still the same one function: it counts this arm's population in bodies by
      -- dividing the scalar by one body's nominal hp, reports an arrival, and lets this arm add
      -- one body's hp to its scalar, clamped at the site's ceiling. One rule, one clock, two
      -- renderings, and the rendering lives inside the authority rather than beside it.
      -- THIS WHOLE ARM IS SCHEDULED FOR DELETION BY 0345. It is repointed rather than left alone
      -- because leaving it would keep a live kill-escalation path for as long as 0345 takes.
      v_variance     := (1 - v_var_pct) + random() * (2 * v_var_pct);
      v_enemy_attack := loc.base_difficulty * coalesce(cfg_num('enemy_attack_base'),1.0);
      v_seq          := 0;
      v_offense      := (e.status = 'active');
      v_wave_num     := e.wave_number;

      select p.o_arrived, p.o_body_hp, p.o_ceiling_hp
        into v_pressure_arrived, v_body_hp, v_enemy_hp
        from public.combat_pressure_step(e.id, v_tick, v_anchor_x, v_anchor_y, loc.x, loc.y, v_seq, v_log_events) p;
      if v_pressure_arrived > 0 then v_seq := v_seq + 1; end if;
      v_e_before := greatest(0, coalesce(e.enemy_integrity_current, 0)) + v_pressure_arrived * coalesce(v_body_hp, 0);
      if v_enemy_hp is null or v_enemy_hp <= 0 then
        v_enemy_hp := greatest(coalesce(e.enemy_integrity_max, 0), v_e_before);
      else
        v_e_before := least(v_enemy_hp, v_e_before);
      end if;
$p5n$),
      ('P6',
       $p6o$
        v_cleared := v_e_after <= 0;
$p6o$,
       $p6n$
        v_cleared := v_e_before > 0 and v_e_after <= 0;
$p6n$),
      ('P7',
       $p7o$
      v_reward_metal := 0; v_reward_delta := '{}'::jsonb; v_loot_items := '[]'::jsonb;
      if v_cleared and v_offense then
        v_reward_metal := round(coalesce(cfg_num('reward_metal_base'),10) * greatest(loc.reward_tier,1)
                                * (1 + coalesce(cfg_num('reward_danger_scale'),0.25) * v_danger) * coalesce(cfg_num('reward_multiplier'),1.0));
        v_loot_items   := pirate_loot_for_wave(v_wave_num, v_danger);
        v_reward_delta := jsonb_build_object('metal', v_reward_metal, 'items', v_loot_items);
        if v_log_events then
          insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
            values (e.id, e.player_id, v_tick, v_seq, 'explosion', 'player', 'pirate',
                    jsonb_build_object('wave_cleared', true, 'wave', v_wave_num, 'reward_metal', v_reward_metal, 'reward_items', v_loot_items));
        end if;
        v_seq := v_seq + 1;
      end if;
$p7o$,
       $p7n$
      -- ██ HUNK [P7] (0344) — ONE PAYOUT AUTHORITY: THE SITE ROW ██
      -- The same deletion as [P2]. This arm cannot count bodies, so it pays for ONE enemy when its
      -- scalar field is broken - never for a depth it reached. It can only under-pay relative to
      -- the spatial arm, never over-pay, and it is deleted entirely by 0345.
      v_reward_metal := 0; v_reward_delta := '{}'::jsonb; v_loot_items := '[]'::jsonb;
      if v_cleared and v_offense then
        v_wave_num     := v_wave_num + 1;
        v_reward_metal := round(coalesce(cfg_num('reward_metal_base'),10) * greatest(loc.reward_tier,1)
                                * coalesce(cfg_num('reward_multiplier'),1.0));
        v_loot_items   := public.site_loot_for_kill(e.location_id, 1);
        v_reward_delta := jsonb_build_object('metal', v_reward_metal, 'items', v_loot_items);
        if v_log_events then
          insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
            values (e.id, e.player_id, v_tick, v_seq, 'explosion', 'player', 'pirate',
                    jsonb_build_object('wave_cleared', true, 'wave', v_wave_num, 'kills', 1, 'reward_metal', v_reward_metal, 'reward_items', v_loot_items));
        end if;
        v_seq := v_seq + 1;
      end if;
$p7n$),
      ('P8',
       $p8o$
          values (e.id, e.player_id, v_tick, v_wave_num, v_danger,
                  v_hp_total, v_e_before, v_player_damage, v_final_player,
$p8o$,
       $p8n$
          values (e.id, e.player_id, v_tick, v_wave_num, 1,
                  v_hp_total, v_e_before, v_player_damage, v_final_player,
$p8n$),
      ('P9',
       $p9o$
        danger_level             = v_danger,
$p9o$,
       $p9n$
        danger_level             = 1,
$p9n$),
      ('PA',
       $pao$
          values (e.id, e.player_id, v_tick, v_seq, 'laser_burst', 'pirate', 'player', 'laser', greatest(1, v_danger), 600);
$pao$,
       $pan$
          -- ██ HUNK [PA] (0344) — EVEN THE COSMETIC WAS AN ESCALATION COUNTER ██
          -- projectile_count was greatest(1, v_danger): the beam got visibly denser the better the
          -- player fought, which is the defect rendered on screen. This arm carries no bodies to
          -- count, so it draws one beam for its one abstract force. The spatial arm, which does
          -- carry bodies, already emits one salvo per weapon per body and is untouched.
          values (e.id, e.player_id, v_tick, v_seq, 'laser_burst', 'pirate', 'player', 'laser', 1, 600);
$pan$)
    ) as t(tag, old_t, new_t)
  loop
    v_n := (length(v_new) - length(replace(v_new, r.old_t, ''))) / length(r.old_t);
    if v_n <> 1 then
      raise exception '0344 HUNK [%] FAIL: its source text occurs % time(s) in the deployed body (want exactly 1). Zero means the anchor is missing — the deployed body is not the one this hunk was cut from, and applying it would either do nothing or patch the wrong site. Do not weaken this to >= 1', r.tag, v_n;
    end if;
    v_new := replace(v_new, r.old_t, r.new_t);
  end loop;
  -- The surgery must have CHANGED something. A no-op replace chain would leave the old body in
  -- place and every absence assert below would then be measured against text this file never
  -- touched — passing, wrongly, by inheriting the head.
  if v_new = v_def then
    raise exception '0344 SURGERY FAIL: the rewritten body is identical to the deployed one — nothing was replaced';
  end if;
  if position('v_danger' in regexp_replace(v_new, '--[^' || chr(10) || ']*', '', 'g')) > 0 then
    raise exception '0344 SURGERY FAIL: the rewritten body still names v_danger — a reference survives outside the eleven hunks and the deploy would ship a body that does not compile or, worse, one that still escalates';
  end if;
  execute v_new;
  raise notice '0344 surgery applied: 11 hunks, each matched exactly once; % chars -> % chars', length(v_def), length(v_new);
end $rw$;


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SELF-ASSERTS — this migration fails the deploy rather than shipping the escalation back
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- Every count over the tick is on a COMMENT-STRIPPED copy of the deployed prosrc. That is not
-- tidiness: this file's own hunk banners name v_danger, waves_cleared and pirate_loot_for_wave in
-- PROSE, and counting raw text would score every one of them as a live reference. It is also the
-- 0222 trap in reverse — that migration aborted on every apply because its probe's target existed
-- ONLY inside a comment its own strip removed — so each block proves its probe is live before
-- drawing any conclusion from a zero.

-- (a) ██ THE CLASS GUARD ██ NOTHING IN THE TICK READS A KILL COUNT
do $a$
declare v_raw text; v_code text; v_n integer; v_needle text;
begin
  select p.prosrc, regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')
    into v_raw, v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  -- NON-VACUITY, BOTH DIRECTIONS. Most of this block asserts that something is ABSENT, and an
  -- empty string satisfies every such assert.
  if v_code is null or length(v_code) < 40000 then
    raise exception '0344 ASSERT (a) FAIL: the comment-stripped tick is % char(s) (want > 40000) — every absence asserted below would be measured against nothing', coalesce(length(v_code), -1);
  end if;
  if length(v_code) >= length(v_raw) then
    raise exception '0344 ASSERT (a) FAIL: the comment strip removed nothing from a % char body — this file''s own banners name v_danger and waves_cleared in prose and would be counted as live references', length(v_raw);
  end if;
  -- THE PROBE IS LIVE. waves_cleared is still WRITTEN, exactly twice, by the two arms' terminal
  -- UPDATEs. If this is not 2, a zero on the READ assert below would prove nothing at all.
  v_n := (length(v_code) - length(replace(v_code, 'waves_cleared            = waves_cleared + (case when v_cleared then 1 else 0 end),', '')))
         / length('waves_cleared            = waves_cleared + (case when v_cleared then 1 else 0 end),');
  if v_n <> 2 then
    raise exception '0344 ASSERT (a) FAIL: % waves_cleared WRITE statement(s) in the tick (want exactly 2). The absence checks below are measured with this same probe, so a wrong count here makes every one of them meaningless', v_n;
  end if;

  -- ██ THE OWNER'S RULE, AS A COUNT ██ A READ of the kill count is what makes killing punish you.
  v_n := (length(v_code) - length(replace(v_code, 'e.waves_cleared', ''))) / length('e.waves_cleared');
  if v_n <> 0 then
    raise exception '0344 ASSERT (a) FAIL: the tick READS e.waves_cleared % time(s) (want 0). Destroying an enemy must not cause more enemies, harder enemies or tougher enemies — the owner has said so three times, and any read of the kill count inside a sizing or reward expression is that rule broken', v_n;
  end if;
  foreach v_needle in array array[
    'v_danger',
    'enemy_hp_danger_scale',
    'enemy_attack_danger_scale',
    'reward_danger_scale',
    'danger_time_divisor_seconds',
    'enemy_synthetic_max_units',
    'pirate_loot_for_wave',
    'resolve_encounter_reward_inputs'] loop
    v_n := (length(v_code) - length(replace(v_code, v_needle, ''))) / length(v_needle);
    if v_n <> 0 then
      raise exception '0344 ASSERT (a) FAIL: the tick still names "%" % time(s) (want 0) — that is the kill-driven escalation, or one of its knobs, still wired into the engine', v_needle, v_n;
    end if;
  end loop;
end $a$;

-- (b) THE AUTHORITY IS REACHED FROM BOTH ARMS, AND 0343's FOLD SURVIVED THE SURGERY
do $b$
declare v_code text; v_n integer;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_pressure_step(e.id, v_tick, v_anchor_x, v_anchor_y, loc.x, loc.y, v_seq, v_log_events)', '')))
         / length('public.combat_pressure_step(e.id, v_tick, v_anchor_x, v_anchor_y, loc.x, loc.y, v_seq, v_log_events)');
  if v_n <> 2 then
    raise exception '0344 ASSERT (b) FAIL: % arm(s) ask the pressure authority (want exactly 2: the spatial arm and the aggregate arm). An arm that does not ask it is an arm with no enemies, or an arm that grew a second way to make one', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'combat_pressure_step(', ''))) / length('combat_pressure_step(');
  if v_n <> 2 then
    raise exception '0344 ASSERT (b) FAIL: the tick calls combat_pressure_step % time(s) but only 2 of them pass the expected arguments — a third call in another shape is a second pressure path', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'public.site_loot_for_kill(', ''))) / length('public.site_loot_for_kill(');
  if v_n <> 2 then
    raise exception '0344 ASSERT (b) FAIL: % call(s) to the loot authority (want exactly 2, one per arm)', v_n;
  end if;
  -- 0343 IS DIRECTLY BELOW THIS SLICE AND ITS HUNKS SIT IN THE SAME BODY. If this surgery had
  -- landed on one of its regions the fold would be short a caller, and the deploy should say so
  -- here rather than let a fleet find out.
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_encounter_wreck(e.id, v_tick)', '')))
         / length('public.combat_encounter_wreck(e.id, v_tick)');
  if v_n <> 3 then
    raise exception '0344 ASSERT (b) FAIL: % arm(s) resolve a wreck through 0343''s leaf (want exactly 3) — this surgery has disturbed the migration below it', v_n;
  end if;
end $b$;

-- (c) ██ RULE 1 ██ THERE IS NO ARROW FROM A DEATH BACK INTO PRESSURE
--
-- These two conditions WERE the arrow: each one asked "is the enemy side empty" and answered by
-- spawning. They are the strings this slice exists to delete, and if either ever returns to the
-- tick the deploy fails here rather than a player discovering it by winning.
do $c$
declare v_code text; v_n integer; v_needle text;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  -- The probe is live: (b) has already proved this same stripped body contains the two authority
  -- calls, so a zero below is a real absence and not an empty read.
  if position('public.combat_pressure_step(' in v_code) = 0 then
    raise exception '0344 ASSERT (c) FAIL: the stripped body does not contain the pressure authority call, so the absence checks in this block would be measured against nothing';
  end if;
  foreach v_needle in array array[
    'if v_e_before <= 0 then',
    'if e.enemy_integrity_current <= 0 then'] loop
    v_n := (length(v_code) - length(replace(v_code, v_needle, ''))) / length(v_needle);
    if v_n <> 0 then
      raise exception '0344 ASSERT (c) FAIL: the tick contains "%" % time(s) (want 0). That condition is "the enemy side is empty" used as a reason to SPAWN — enemy death must never feed pressure', v_needle, v_n;
    end if;
  end loop;
end $c$;

-- (d) ██ THE AUTHORITY IS A CLOCK ██ read out of its own body
--
-- RULES 2 and 3 are properties of this function alone, so they are asserted against it directly.
-- The probe must MATCH THE AUTHORITY FIRST — otherwise a broken pattern would report a clean
-- world instead of failing as a broken pattern.
do $d$
declare v_code text; v_n integer; v_needle text;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_pressure_step';
  if v_code is null or length(v_code) < 500 then
    raise exception '0344 ASSERT (d) FAIL: combat_pressure_step''s body is % char(s) — there is nothing here to be the authority', coalesce(length(v_code), -1);
  end if;
  -- IT IS THE THING IT CLAIMS TO BE. Each of these must be present, or every absence below is
  -- being read off some other function.
  foreach v_needle in array array[
    'next_reinforcement_at',
    's.cadence',
    's.cap',
    'combat_spawn_wave_units',
    'coalesce(e.next_reinforcement_at, e.started_at)'] loop
    if position(v_needle in v_code) = 0 then
      raise exception '0344 ASSERT (d) FAIL: the pressure authority does not contain "%" — it is not the clock this slice describes, and the absence checks below would prove nothing', v_needle;
    end if;
  end loop;
  -- RULE 1 + RULE 3, AS ABSENCES: it reads no kill count, no wave, no danger and no elapsed
  -- presence. Note that 'danger' as a substring also catches danger_level and every danger knob.
  foreach v_needle in array array['waves_cleared', 'wave_number', 'danger', 'secs_inside', 'v_cleared'] loop
    v_n := (length(v_code) - length(replace(v_code, v_needle, ''))) / length(v_needle);
    if v_n <> 0 then
      raise exception '0344 ASSERT (d) FAIL: the pressure authority names "%" % time(s) (want 0). Pressure is a function of the SITE and the CLOCK. If it can read what the player did, it is not a clock', v_needle, v_n;
    end if;
  end loop;
  -- RULE 2, STRUCTURALLY: no loop, so there is no way to write a catch-up that spawns the arrivals
  -- a cap suppressed; and exactly one skip-forward, which is the whole of "lost, not banked".
  v_n := (length(v_code) - length(replace(v_code, 'loop', ''))) / length('loop');
  if v_n <> 0 then
    raise exception '0344 ASSERT (d) FAIL: the pressure authority contains % loop keyword(s) (want 0). A loop is how a missed reinforcement gets banked and then released by the next death — which is RULE 2 broken', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 's.cadence * (v_missed + 1)', ''))) / length('s.cadence * (v_missed + 1)');
  if v_n <> 1 then
    raise exception '0344 ASSERT (d) FAIL: the clock advance "s.cadence * (v_missed + 1)" occurs % time(s) (want exactly 1). It is what walks past every elapsed slot in one step, so nothing is owed', v_n;
  end if;
  -- ONE WRITER. If anything else in the database moved this column, "the clock" would be a
  -- convention rather than a mechanism.
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind in ('f', 'p')
     and regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') like '%next_reinforcement_at =%';
  if v_n <> 1 then
    raise exception '0344 ASSERT (d) FAIL: % function(s) in public write next_reinforcement_at (want exactly 1, public.combat_pressure_step). One clock, one writer', v_n;
  end if;
end $d$;

-- (e) ██ ONE PRESSURE AUTHORITY ██ a schema sweep, not a look at the tick
--
-- (a)-(d) look at two functions. This looks at the whole schema, so a NEW function that spawns an
-- enemy is caught as well as a reverted one. It cannot pass vacuously: the probe has to find
-- combat_pressure_step itself, by the same pattern, in the same query.
do $e$
declare v_n integer; v_leaf integer; v_names text;
begin
  with spawners as (
    select p.proname
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prokind in ('f', 'p')
       and position('combat_spawn_wave_units(' in regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')) > 0
  )
  select count(*), count(*) filter (where proname = 'combat_pressure_step'),
         coalesce(string_agg(proname, ', ' order by proname), '(none)')
    into v_n, v_leaf, v_names
    from spawners;
  if v_leaf <> 1 then
    raise exception '0344 ASSERT (e) FAIL: the spawn probe does not match combat_pressure_step itself (matched % of it), so its count of % caller(s) proves nothing. Fix the probe, do not trust the number. Matched: %', v_leaf, v_n, v_names;
  end if;
  if v_n <> 1 then
    raise exception '0344 ASSERT (e) FAIL: % function(s) in public spawn enemy units (want exactly 1, public.combat_pressure_step). There is ONE place another enemy comes from, and it is a clock. Matched: %', v_n, v_names;
  end if;
end $e$;

-- (f) THE CONTENT EXISTS AND IS SANE — cadence, cap and loot are rows, so their absence is a bug
do $f$
declare v_sites integer; v_rows integer; v_bad text;
begin
  select count(*) into v_sites
    from public.locations where location_type = 'pirate_hunt' and status = 'active';
  select count(*) into v_rows
    from public.location_pressure lp
    join public.locations l on l.id = lp.location_id
   where l.location_type = 'pirate_hunt' and l.status = 'active';
  -- NON-VACUITY: a sweep over "every active pirate-hunt site" is trivially satisfied by a world
  -- with none. The chain seeds three, and 0148 already asserts they exist by name.
  if v_sites < 3 then
    raise exception '0344 ASSERT (f) FAIL: the world carries % active pirate_hunt location(s) (want at least the 3 seeded sites) — the coverage check below would sweep an empty set and pass while every fight had no pressure at all', v_sites;
  end if;
  if v_rows <> v_sites then
    select string_agg(l.name, ', ' order by l.name) into v_bad
      from public.locations l
     where l.location_type = 'pirate_hunt' and l.status = 'active'
       and not exists (select 1 from public.location_pressure lp where lp.location_id = l.id);
    raise exception '0344 ASSERT (f) FAIL: % of % active pirate_hunt site(s) carry a location_pressure row. A site with no row hosts no reinforcements at all. Missing: %', v_rows, v_sites, coalesce(v_bad, '(none — then the counts disagree for another reason)');
  end if;
  -- The three authored profiles are the measured ones, by name, so a typo in the seed fails here
  -- rather than changing the game quietly.
  select string_agg(l.name || '=' || lp.reinforcement_seconds || 's/cap ' || lp.concurrent_cap, ', ' order by l.name)
    into v_bad
    from public.location_pressure lp join public.locations l on l.id = lp.location_id
   where (l.name, lp.reinforcement_seconds::numeric, lp.concurrent_cap) not in
         (('Snare', 45.0::numeric, 3), ('Reaver', 36.0::numeric, 4), ('Blackden', 30.0::numeric, 6))
     and l.name in ('Snare', 'Reaver', 'Blackden');
  if v_bad is not null then
    raise exception '0344 ASSERT (f) FAIL: an authored site does not carry its measured profile (COMBAT_BALANCE_VALUES §3/§4 — Snare 45s/3, Reaver 36s/4, Blackden 30s/6). Found: %', v_bad;
  end if;
  select count(*) into v_rows
    from public.location_loot ll
    join public.locations l on l.id = ll.location_id
   where l.name in ('Snare', 'Reaver', 'Blackden');
  if v_rows <> 13 then
    raise exception '0344 ASSERT (f) FAIL: the three authored sites carry % loot row(s) (want 13 — the 10 deterministic ladder rows plus the 3 that carry the two config-gated faucets across). Every item the deleted wave ladder could produce must still be produced by a row, or this slice closes a faucet silently', v_rows;
  end if;
end $f$;

-- (i) ██ THE FAUCET CLASS GUARD ██ NOTHING A RECIPE REQUIRES MAY LOSE ITS ONLY SOURCE
--
-- This is the assert that would have caught the defect this slice shipped in its first version, and
-- it is written over the CLASS rather than over the two items that exposed it.
--
-- THE CLASS: this migration removes the engine's only call to public.pirate_loot_for_wave, so every
-- item that function could produce loses its producer unless public.location_loot carries it. The
-- item set is DERIVED from the function's own deployed body, not typed here — so if a future slice
-- adds a sixth drop to that ladder and forgets to author it, this fails without being edited.
--
-- Then the sharper half: intersect that set with everything the three recipe-ingredient tables
-- actually require. An item that a recipe demands and nothing produces is an unbuildable recipe on
-- a live game — measured here as 5 captain recruit recipes (captain_memory_shard) and 2 hull build
-- recipes (blueprint_fragment), against player stockpiles of zero.
--
-- IT CANNOT PASS VACUOUSLY. Three ways it could, all closed: the ladder-item set is re-derived from
-- the deployed body and must be non-empty; the recipe set is read from the three tables and must be
-- non-empty; and the intersection must be non-empty too, because if it were empty the sweep would
-- be reporting "nothing to check" as "nothing wrong".
do $i$
declare
  v_src   text;
  v_items text[];
  v_req   integer;
  v_isect integer;
  v_bad   text;
  v_callers text;
begin
  select p.prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'pirate_loot_for_wave';
  if v_src is null then
    raise exception '0344 ASSERT (i) FAIL: public.pirate_loot_for_wave does not exist, so the set of items whose faucet this slice disconnects cannot be derived. Pin the item list explicitly rather than sweeping an empty set';
  end if;
  -- every item id the ladder can emit, read out of its own body
  select array_agg(distinct m[1] order by m[1]) into v_items
    from regexp_matches(v_src, '''item_id'',[[:space:]]*''([a-z0-9_]+)''', 'g') m;
  if v_items is null or array_length(v_items, 1) < 5 then
    raise exception '0344 ASSERT (i) FAIL: only % item id(s) were derived from pirate_loot_for_wave''s body (want at least the 5 deterministic ladder items). The probe is broken, and a sweep over a short list would report a clean world', coalesce(array_length(v_items, 1), 0);
  end if;

  -- everything the recipes require
  create temporary table if not exists _0344_req (item_id text primary key) on commit drop;
  delete from _0344_req;
  insert into _0344_req (item_id)
  select distinct item_id from (
    select item_id from public.captain_recipe_ingredients
    union all select item_id from public.hull_recipe_ingredients
    union all select item_id from public.module_recipe_ingredients) u
  on conflict do nothing;
  select count(*) into v_req from _0344_req;
  if v_req = 0 then
    raise exception '0344 ASSERT (i) FAIL: the three recipe-ingredient tables require 0 items — the sweep below would pass over an empty set';
  end if;

  select count(*) into v_isect from _0344_req r where r.item_id = any(v_items);
  if v_isect = 0 then
    raise exception '0344 ASSERT (i) FAIL: none of the % ladder item(s) is required by any recipe, so this guard is checking nothing. Either the derivation or the recipe read is wrong', array_length(v_items, 1);
  end if;

  -- THE PROPERTY: every item that a recipe requires AND the ladder used to produce must now have an
  -- authored source. A row with drop_chance 0 counts as a SOURCE — the faucet exists and is shut,
  -- which is a tuning state; no row at all is a dead end, which is a design defect.
  select string_agg(r.item_id, ', ' order by r.item_id) into v_bad
    from _0344_req r
   where r.item_id = any(v_items)
     and not exists (select 1 from public.location_loot ll where ll.item_id = r.item_id);
  if v_bad is not null then
    raise exception '0344 ASSERT (i) FAIL: [%] are required by captain/hull/module recipes and were produced ONLY by public.pirate_loot_for_wave, whose engine callers this migration deletes — and public.location_loot authors no source for them. That is a permanently unbuildable recipe on a live game. Author a location_loot row (drop_chance may be 0 to keep the faucet shut) or do not delete the call', v_bad;
  end if;

  -- AND THE PREMISE THIS GUARD RESTS ON: the ladder really is disconnected from the engine, so
  -- location_loot really is the only source. If some function still called it, the two authorities
  -- would both be live and the wave-depth coupling would still be reachable.
  select string_agg(p.proname, ', ' order by p.proname) into v_callers
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind in ('f', 'p')
     and p.proname <> 'pirate_loot_for_wave'
     and position('pirate_loot_for_wave(' in regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')) > 0;
  if v_callers is not null then
    raise exception '0344 ASSERT (i) FAIL: [%] still call pirate_loot_for_wave. Loot would have two authorities and the wave-depth ladder would still be reachable from the engine', v_callers;
  end if;
end $i$;

-- (g) NOTHING DARK. There is no flag, the dead knobs are GONE, and the compensation is applied.
--
-- The owner's ruling: "don't make anything dark, make it so that i can check." A gate that selects
-- between the old pressure and the new one IS the spaghetti this slice removes, so its absence is
-- asserted rather than promised.
do $g$
declare v_keys text; v_metal jsonb;
begin
  select coalesce(string_agg(key, ', ' order by key), '') into v_keys
    from public.game_config
   where key ilike '%pressure_step%' or key ilike '%killing_well%' or key ilike '%reinforcement%'
      or key in ('enemy_hp_danger_scale', 'enemy_attack_danger_scale', 'reward_danger_scale',
                 'danger_time_divisor_seconds',
                 'captain_shard_drop_rate', 'blueprint_fragment_drop_rate');
  if v_keys <> '' then
    raise exception '0344 ASSERT (g) FAIL: game_config still carries (%). 0344 ships NO flag of its own; the four now-unread danger knobs must be gone, and the two drop-rate knobs must be gone because their values have MOVED into public.location_loot.drop_chance — two places holding one drop rate is the duality this slice removes', v_keys;
  end if;
  -- enemy_synthetic_max_units is deliberately NOT swept: it survives as resolve_location_encounter's
  -- authored-plan ceiling (see section 4). What matters for D3 is that the TICK no longer reads it,
  -- which assert (a) proves at 0 occurrences. Asserting the ROW absent here would delete a live
  -- clamp's only tuning point to make a slogan true.
  select value into v_metal from public.game_config where key = 'reward_metal_base';
  if v_metal is null or (v_metal #>> '{}')::double precision <> 20 then
    raise exception '0344 ASSERT (g) FAIL: reward_metal_base is % (want 20) — the measured compensation for deleting the danger term from the payout was not applied, and this slice would halve the metal faucet for every live player', coalesce(v_metal::text, 'absent');
  end if;
end $g$;

-- (h) THE NEW SURFACES ARE ENGINE-INTERNAL, ESTABLISHED AND THEN ASSERTED
--
-- EXECUTE is granted to PUBLIC by default on every new function, and Supabase grants client verbs
-- on every new public table. 0254 proved that establishing a posture and asserting it are two
-- different acts, so the revokes above establish it and this proves it. grantee = 0 is PUBLIC,
-- which is the hole a revoke naming only anon and authenticated leaves standing.
do $h$
declare v_acl aclitem[]; v_bad text; v_fn text;
begin
  foreach v_fn in array array[
    'public.combat_pressure_step(uuid, integer, double precision, double precision, double precision, double precision, integer, boolean)',
    'public.site_loot_for_kill(uuid, integer)'] loop
    select p.proacl into v_acl from pg_proc p where p.oid = v_fn::regprocedure;
    if v_acl is null then
      raise exception '0344 ASSERT (h) FAIL: % carries DEFAULT privileges — a NULL proacl means PUBLIC still holds EXECUTE on it', v_fn;
    end if;
    if exists (select 1 from aclexplode(v_acl) a where a.grantee = 0) then
      raise exception '0344 ASSERT (h) FAIL: PUBLIC holds a privilege on % — pressure and loot are the engine''s decisions, never a client call', v_fn;
    end if;
    select string_agg(r, ', ') into v_bad
      from unnest(array['anon', 'authenticated']) r
     where has_function_privilege(r, v_fn, 'EXECUTE');
    if v_bad is not null then
      raise exception '0344 ASSERT (h) FAIL: % can EXECUTE % — a client could summon its own reinforcements or mint its own loot', v_bad, v_fn;
    end if;
  end loop;
  select string_agg(grantee || ' ' || privilege_type || ' on ' || table_name, ', ')
    into v_bad
    from information_schema.role_table_grants
   where table_schema = 'public'
     and table_name in ('location_pressure', 'location_loot')
     and grantee in ('anon', 'authenticated')
     and privilege_type in ('INSERT', 'UPDATE', 'DELETE');
  if v_bad is not null then
    raise exception '0344 ASSERT (h) FAIL: a client can write the pressure or loot content: %. Content is authored by the owner, never by a player', v_bad;
  end if;
  raise notice '0344 self-assert ok: KILLING WELL IS NOT PUNISHED. The tick READS e.waves_cleared ZERO times and names v_danger ZERO times; the body-count sizer greatest(1, v_danger), both (1 + v_danger * scale) HP factors, both attack factors, the reward_danger_scale multiplier, both pirate_loot_for_wave calls, the resolved-plan reward branch and the four now-unread danger knobs are all GONE, and the two conditions that were the arrow from a death to a spawn ("if v_e_before <= 0 then", "if e.enemy_integrity_current <= 0 then") occur ZERO times. Pressure now comes from exactly ONE function — public.combat_pressure_step, proved by a schema sweep whose probe had to match the authority itself first — which reads the SITE row, the CLOCK and the FIELD, names waves_cleared / wave_number / danger / secs_inside ZERO times, contains NO loop (so a suppressed arrival is lost and can never be banked and released by a death), advances its clock past every elapsed slot in exactly one skip-forward expression, and is the only writer of combat_encounters.next_reinforcement_at in the database. Cadence and cap are ROWS — Snare 45s/cap 3, Reaver 36s/cap 4, Blackden 30s/cap 6, asserted by name against the measured profile — never computed from base_difficulty. Loot is a fixed per-enemy value from 10 authored location_loot rows plus reward_metal_base x reward_tier, with reward_metal_base raised 10 -> 20 as the measured income compensation. Every fight in flight was given a full cadence of grace, and an unstamped row is due at started_at, so no encounter can reach a state the new clock cannot resolve. NO feature flag, NO game_config key of this slice''s own (asserted ABSENT); both new leaves revoked from PUBLIC BY NAME and unreachable by anon and authenticated; both new content tables carry no client INSERT/UPDATE/DELETE; and the whole tick is production''s own bytes with eleven marked hunks and nothing else changed.';
end $h$;
