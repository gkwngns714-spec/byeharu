-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0351 — THE FLEET FIRES AS ONE  (one point, one reach, one circle — and the circle IS the gate)
--        plus: the attack interval becomes 5 seconds, on both sides, as DATA
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- ── THE OWNER, VERBATIM ─────────────────────────────────────────────────────────────────────────
--   "the fleet range shape is like a cloud, make it circle."
-- and earlier, about the same shape:
--   "my fleet range shape in blue is weird."
--   "i want fires to be 5s."
--
-- A REPEATED INSTRUCTION IS NOT A CLARIFICATION. It is evidence that something already built says
-- the opposite, and the standing law is to find that thing and DELETE it rather than soften it.
--
-- ── WHAT SAYS THE OPPOSITE, NAMED ───────────────────────────────────────────────────────────────
-- The reach is drawn as the UNION OF PER-HULL DISCS (src/features/map/combatActors.ts:198,
-- `alive.map(m => ({ dx: m.x - px, dy: m.y - py, range: m.range }))`). That union is honest — it is
-- exactly what this engine enforces, because the fire gate measures EVERY hull from ITS OWN frozen
-- position against ITS OWN weapon's range. A union of four discs is not a circle and cannot be made
-- into one by drawing it differently.
--
-- IT WAS NOT ALWAYS A UNION, AND THE OLD SHAPE IS NOT THE ANSWER EITHER. The reach was once ONE
-- circle on the fleet's elected lead carrying the fleet's LONGEST range. That LIED: measured on a
-- real encounter it enclosed 2 of 6 enemies that were legitimately shootable, because escorts sit
-- forward of the lead and each fires from where IT stands. Going back to it would restore a circle
-- that is not the rule, which is the same defect wearing the owner's preferred shape.
--
-- ── SO THE RULE CHANGES, NOT THE PICTURE ────────────────────────────────────────────────────────
-- The owner's own standing design law is that THE FLEET IS ONE ACTOR — one thing that moves, drawn
-- as one thing. A single actor has a single position and a single reach. Once the fire gate measures
-- from the fleet's own point against the fleet's own range, ONE CIRCLE GENUINELY IS THE REACH — not
-- an approximation of it, not a simplification of it, and not a lie about it.
--
-- ── THE FLEET'S ONE POINT — COMPOSED, NEVER INVENTED ────────────────────────────────────────────
-- It is the fleet's ELECTED LEAD: the living, positioned player row with the highest
-- `aggro_priority`, ties broken by lowest id. That election is 0315's, made once per encounter and
-- written onto the row (`combat_create_group_encounter`: `v_aggro_priority := case when v_is_lead
-- then 100 else 0 end`), and it is ALREADY the point the client draws the fleet glyph on
-- (src/features/map/fleetFightPosition.ts, whose own header states the rule and the two owner bugs
-- that produced it). Choosing anything else would put the guns somewhere other than the glyph.
--
-- WHY NOT `combat_encounters.engagement_x/y`, the other candidate: it is where the fight STARTED,
-- not where the fleet IS. Measured read-only on production 2026-08-09, encounter 9855381f: the
-- anchor sat at (-24, 102) while all five player hulls stood 21.2-22.0 units away. Firing from a
-- point 21 units from every one of your own ships is not "one actor", it is a third position.
--
-- ── THE FLEET'S ONE RANGE — THE SHORTEST GUN ────────────────────────────────────────────────────
-- `min` over the living hulls' weapon ranges, so NOTHING DRAWN IS OUT OF REACH.
--
-- 0336:35-40 is the shipped defect caused by aggregating ranges, and it is read here rather than
-- rediscovered: the freeze carried `my_range = max(range)` while the fire gate was PER WEAPON, so a
-- range-6 Mk-II fitted beside a range-5 autocannon held the hull at ~6 and the autocannon NEVER
-- FIRED — a better gun buying less damage, through geometry. 0336 fixed it by giving the MOVER the
-- shortest gun (`my_min_range`, "NEVER RETREAT PAST YOUR SHORTEST GUN").
--
-- THE LESSON IS NOT "DO NOT AGGREGATE". It is that the gate and the mover must aggregate THE SAME
-- WAY; 0336's defect existed precisely because they did not. This migration takes `min` for BOTH,
-- so the class cannot recur through it.
--
-- WHAT IT COSTS, STATED PLAINLY: a fleet's reach is its shortest gun, so fitting a LONGER-ranged gun
-- buys power but no extra reach. That is the honest price of being one actor, and it is strictly the
-- safe direction on a live game — this change can only ever REMOVE reach that a hull had, never
-- grant reach that none had. On production today it is a NO-OP: every player weapon in every live
-- fight is `basic_player_weapon` at range 5, so min = max = 5.
--
-- ── THE ENEMY SIDE IS DELIBERATELY NOT FOLDED ───────────────────────────────────────────────────
-- src/features/map/combatActors.ts:38-42 states why, and it is a gameplay read, not an oversight:
-- "how many are still shooting" is the player's central read of a fight. An enemy is ONE HULL and
-- keeps its own circle, its own range and its own position. What changes for it is only WHAT IT
-- MEASURES TO — the fleet's point rather than whichever hull happens to be nearest — so that its
-- circle becomes true in exactly the sense the fleet's now is. `v_target_id` still names the hull
-- that ABSORBS the damage, so 0301's aggro screening (escorts shield the lead) is untouched.
--
-- ── WHY THE MOVER HAD TO MOVE TOO, OR THE FIGHT DEADLOCKS ───────────────────────────────────────
-- This is the part that makes the change non-optional rather than a matter of taste. If the gate
-- measured from the fleet point while each hull still closed until IT was in range, the two would
-- stop at different places: `spatial_formation_ring_radius` is 6 against a player reach of 5, so a
-- hull satisfied at 5 can leave the FLEET POINT as much as 6 further out than the gate allows. The
-- formation would halt, believing itself in range, and never fire a shot.
--
-- So the player side's movement decision is made ONCE, at the fleet point, at the fleet's speed, and
-- applied to every hull as a RIGID TRANSLATION. That is not a second mover: it composes the same
-- pure leaf (`combat_unit_decide_move`) with fleet arguments, and rigidity falls out of the delta
-- depending only on fleet quantities — the same property 0339's `combat_translate_player_formation`
-- gives an ORDERED reposition, obtained here without forking anything.
--
-- ⛔ THE ORDERED-REPOSITION ARM IS UNTOUCHED. `v_rp_live` still stands the per-unit write down while
--    a course is live, and the foot-of-arm reposition step remains the sole authority for a fleet
--    under orders — including its exclusive right to write `engagement_x/y` through
--    `combat_encounter_move`, which 0339's assert and DZCOMBAT_PASS_ONEANCHOR both pin. This slice
--    adds no writer of that column.
--
-- ── WHAT STILL HOLDS, AND WHAT MOVES (asked explicitly, answered explicitly) ────────────────────
--   * 0336's MEASURED-EXTENT SPAWN CLEARANCE — HOLDS, UNCHANGED. It measures the max distance from
--     the anchor to a living PLAYER row and adds the arriving body's own range + 1. Both quantities
--     are per-hull player geometry that this slice does not touch: hulls still have their own
--     positions, they merely all receive the same step.
--   * 0346's INGRESS BOUNDARY — HOLDS, UNCHANGED, and is deliberately excluded from the new arm: the
--     ingress branch is tested BEFORE the ordinary movement block and returns from it, so an
--     ingressing raider still walks to its own boundary slot. An enemy never enters the fleet arm.
--   * 0336's KITE BAND — MOVES, and is now a FLEET band rather than a hull band. The fleet closes
--     while the fleet point is outside the fleet reach and kites while the enemy cannot reach it.
--     Because gate and mover share one point and one aggregate, the band is the same interval on
--     both sides of the decision for the first time.
--   * THE STANDOFF (0336 defect 8, The Furnace: enemy range 6.0 > player reach 5) — STILL RESOLVED,
--     and by the same mechanism: the fleet closes because the fleet point is outside the fleet
--     reach. It is now decided once for the formation instead of four times.
--   * WHO OPENS A FIGHT — MOVES, and this is the one player-visible behaviour change beyond the
--     shape. Today an escort opens, because the lead is a full RADIUS from an arriving wave where an
--     escort is a CHORD. After this, the FLEET opens, when the fleet point is in reach. That is the
--     direct consequence of the owner's law and it is what makes the circle honest.
--
-- ── ITEM 2: "I WANT FIRES TO BE 5s" — DATA, AND THE ARITHMETIC HE NEEDS TOLD ────────────────────
-- ⚠ THE ENGINE ALREADY HONOURS `cooldown_seconds`. 0314 fixed that ("THE ATTACK INTERVAL: arm the
--   weapon with ITS OWN cooldown_seconds"), and the deployed body arms
--   `next_ready_at := now() + make_interval(secs => cooldown_seconds)`. The old claim that firing
--   stamps a bare `now()` describes `0299:947`, a body two hundred migrations superseded. VERIFIED
--   read-only against production before this file was written, not inherited from a note. So "5s" is
--   a value change and nothing else — there is no engine repair hiding inside it.
--
-- ⚠ 5 SECONDS YIELDS A 6-SECOND CADENCE, AND THAT IS NOT A ROUNDING ERROR. `combat_tick_seconds` is
--   3. Fire at t=0, ready at t=5; the tick at t=3 finds the weapon not ready, the tick at t=6 fires.
--   Under a 3-second scheduler the only reachable cadences are 3, 6, 9, ... — 5 is not one of them.
--   The owner asked for 5, so 5 is what is written; the observed rhythm will be 6. Substituting 6
--   silently would make the knob disagree with the fight, which is worse than the honest gap.
--
-- BOTH SIDES, SYMMETRICALLY. Every fitted weapon and both synthetic weapons carry 2 today (the Mk-II
-- carries 2.5, which at a 3-second tick is indistinguishable from 2 — every value at or under the
-- tick fires every tick). Applying it to one side only would be a balance change nobody asked for,
-- hidden inside a feel change.
--
-- WHAT IT DOES TO THE BALANCE, MEASURED RATHER THAN REASONED: today every weapon on the field fires
-- on EVERY 3-second tick, so this exactly HALVES the rate of fire on both sides. Relative power is
-- unchanged; wall-clock time to kill doubles. That matters because of what was measured on the
-- owner's two long fights (see the finding below): he kills at almost exactly the reinforcement
-- cadence. Halving his rate of fire pushes kills BELOW arrivals, so the field will grow where it
-- used to hold level. THAT IS A REAL AND INTENDED-LOOKING CONSEQUENCE OF A KNOB THE OWNER CHOSE, and
-- it interacts directly with `combat_pressure_step`'s cadence, which this slice does not own.
--
-- ── ITEM 3: PROJECTILE SPEED ÷10 IS DELIBERATELY *NOT* IN THIS MIGRATION ────────────────────────
-- The owner asked for it in the same breath ("i want the ammo speed to be slower, 10 times slower —
-- graphic also"), and it is one line of data. It is held out because shipping it here would make a
-- real, measured, already-dominant visual defect about ten times worse:
--
--   * `impact_delay_ms = round(1000 * dist / projectile_speed)` is 55-82 ms in live fights; ÷10
--     makes it 550-820 ms.
--   * The client is the sole consumer and derives flight time as
--     `max(280, min(900, impact_delay_ms * 4))` (map/combatMotion.ts:227-229 + :444-447). Today that
--     clamps UP to 280 ms; after ÷10 it clamps DOWN at the 900 ms ceiling. The graphic would move
--     3.2x, not 10x, and would then stop tracking the server value entirely — the drift the owner's
--     "graphic also" exists to prevent.
--   * MEASURED on his two long fights: 29.7% and 33.2% of all player salvos land on a body that dies
--     on that same tick. A killed enemy stops drawing a glyph immediately, so roughly one shot in
--     three is already drawn flying into empty space. Stretching every round's flight ten-fold over a
--     body that has already vanished turns an occasional seam into the fight's dominant visual.
--
-- Its other half is a client change this slice may not make, so per the standing law the whole item
-- waits and lands with the render fix. The spec is written and handed over.
--
-- ── THE LIVE ENGINE IS THE AUTHORITY, NOT THE REPO ──────────────────────────────────────────────
-- `process_combat_ticks` exists in this repository only as a chain of text-patch migrations; no file
-- holds it whole. This migration reads what is actually DEPLOYED (`pg_get_functiondef` at apply
-- time) and replaces marked hunks in it. It contains NO `create or replace function
-- public.process_combat_ticks` — eleven generators each assert that 0299 is still the newest TEXTUAL
-- re-create of that function, and a full re-emission breaks all eleven at once. 0343 established
-- this shape and 0346 refined it; this file follows both.
--
-- SIX HUNKS, every pre-image SLICED VERBATIM out of the deployed body (production, head
-- 20260618000349, read 2026-08-09) and required to match EXACTLY ONCE. Zero occurrences means the
-- deployed body is not the one these hunks were cut from and the migration ABORTS rather than
-- silently patching nothing; more than one means the anchor is ambiguous and aborts too.
--
--   [1] declare block          — the four fleet locals
--   [2] before the unit loop   — read the fleet's actor ONCE per encounter
--   [3] first acquisition      — the player acquires from the fleet point; the enemy measures to it
--   [4] the movement decision  — the fleet's step, applied as a rigid translation
--   [5] re-acquisition         — the same measurement, so a re-aimed gun cannot fall back
--   [6] the fire gate          — the circle
--
-- ⚠ THE SURGERY ACCUMULATES AND EXECUTES ONCE PER FUNCTION. Hunk [1] DECLARES four locals that hunks
--   [2]-[6] USE. Executing per hunk would create an intermediate body carrying the uses without the
--   declaration, and Postgres validates a plpgsql body at CREATE time — that is exactly the 42601
--   that made 0346 red on all 22 legs. `scripts/check-surgery-identifiers.mjs` fails the build on
--   the other shape.
--
-- ⚠ 0346's OWN PRECONDITION ANCHOR IS PRESERVED. It requires exactly ONE per-unit mover call passing
--   the raw `move_speed`. Hunk [4] adds a FLEET arm in front of the existing one and leaves that
--   call textually intact, so the count stays 1 and a future ingress rewriter still finds its anchor.
--
-- ── BLAST RADIUS: PRODUCTION IS A LIVE ~30-PLAYER GAME ──────────────────────────────────────────
--   * ONE transaction. The leaf exists before the tick that names it, so there is never an instant
--     at which the tick calls a function that does not exist.
--   * NO grant on any client-reachable surface, NO flag, NO new column, NO row written outside
--     pg_proc, game_config and module_types.
--   * THE TICK BODY IS READ FRESH EVERY 3 SECONDS, so the very next tick of every running fight runs
--     the new body. There is no per-fight opt-in and no drain.
--   * AN ENCOUNTER ACTIVE AT THE INSTANT THIS APPLIES keeps every row it has. Nothing is
--     repositioned, re-ranged, re-sped or re-slotted; this migration writes no combat_units row at
--     all. From the next tick its player hulls fire from the fleet point and step together instead
--     of individually — a fleet mid-chase will close as one from wherever its hulls happen to stand,
--     and the formation freezes in whatever shape the old per-hull chase had left it (measured: hulls
--     converge to within ~0.8 units of each other, so the visible change is small).
--   * WEAPONS ALREADY IN A FIGHT KEEP THEIR OLD COOLDOWN. `combat_units.weapons_json` is a SNAPSHOT
--     frozen at encounter creation; the 5-second interval reaches a weapon only when its encounter is
--     created. THIS IS DELIBERATE AND NOT LAZINESS: rewriting the runtime rows would change the
--     rhythm of a fight already in progress, which is the opposite of legible, and it would be a
--     write to live player state in a 30-player game to no one's benefit. Read read-only while
--     writing this: production had ZERO encounters in status 'active', so in practice nothing is
--     mid-fight — but the rule holds either way and does not depend on that.
--   * `next_ready_at` VALUES STAMPED UNDER THE OLD RULE ARE HARMLESS. They are absolute timestamps
--     at most 2 seconds in the future; the gate is `now() >= next_ready_at`, so every one of them
--     matures on schedule and the NEXT stamp uses whatever cooldown that weapon's snapshot carries.
--     No weapon is left permanently un-ready and none becomes ready early.
--
-- ── ROLLBACK BOUNDARY ───────────────────────────────────────────────────────────────────────────
-- Six hunks, one new leaf, one re-created leaf and four data values. Every hunk's PRE-IMAGE is in
-- this file, verbatim, in the VALUES list, so nothing has to be reconstructed from a dump or from an
-- older migration (copying from an older FILE is what reverted this tick's mode line three times).
-- In one transaction, in this order:
--   1. re-run the surgery block with old_t and new_t SWAPPED, each still required to match exactly
--      once — this restores the per-hull acquisition, the per-hull mover and the per-weapon gate;
--   2. `create or replace function public.combat_fleet_move_speed(uuid)` from its 0337 text (it is
--      quoted in full in assert (e) below, so it need not be fetched from anywhere);
--   3. `drop function public.combat_fleet_actor(uuid);`
--   4. restore the four values: `module_types.cooldown_seconds` 5 -> 2 (autocannon_battery) and
--      5 -> 2.5 (autocannon_battery_mk2); `combat_player_fallback_weapon_cooldown_seconds` and
--      `enemy_synthetic_cooldown_seconds` 5 -> 2.
-- The order matters: the drop must not precede the removal of its callers. Nothing else unwinds — no
-- grant, no schema change, no client half. Encounters in progress at the moment of a rollback resume
-- per-hull fire from wherever their hulls stand, which is a legal state for any formation and needs
-- no repair. Steps 1-3 and step 4 are independently revertible: the geometry and the cadence share a
-- migration but not a mechanism.
--
-- ── NOTHING DARK ────────────────────────────────────────────────────────────────────────────────
-- There is no feature flag and no way to ship this invisible. The reach is not a knob and cannot be
-- set to a value that restores the union; the cadence is a DURATION, not a gate. Assert (f) requires
-- that no gate-shaped key exists for this slice.
--
-- ── SELF-ASSERT MAP (one DO block per check — the statement number IS the diagnosis) ────────────
--   (a) the actor leaf has the engine-internal posture and NO client role can execute it
--   (b) ONE POINT AND ONE REACH, and the per-hull gate is GONE: the tick composes the actor exactly
--       once, the player fire gate no longer compares against a bare per-weapon range, 0346's
--       one-per-unit-mover anchor still holds, and no other function composes the actor
--   (c) THE LEAF IS THE CLIENT'S OWN RULE, EXECUTED: over a staged formation it answers the elected
--       lead's coordinates exactly, follows the election when the lead changes, falls back to the
--       lowest-id living hull when the lead is dead, reports the SHORTEST gun and the SLOWEST hull,
--       and answers NOTHING (not a guess) for a fleet with no living positioned hull
--   (d) THE CIRCLE IS THE GATE, EXECUTED: over a ring of candidate enemy positions, "inside the one
--       circle" and "the engine's own fire predicate" agree at EVERY point, including on the edge
--   (e) metadata parity: the tick and combat_fleet_move_speed changed their BODY and nothing else,
--       and combat_fleet_move_speed still returns the identical value it did before
--   (f) the cadence is DATA, it is 5 on every firing weapon and both synthetic sides, the engine
--       still arms next_ready_at from the weapon's OWN cooldown (0314's property, restated so a
--       regression fails the DEPLOY), and no gate-shaped key exists for this slice
--
-- WHAT THESE CANNOT PROVE, STATED RATHER THAN IMPLIED: that the real tick then walks a real fleet and
-- opens fire on the circle's edge. A self-assert cannot open a fight. That is proven by exactly one
-- layer — the disposable-Postgres apply-proof driving the REAL tick.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ── 0. PRECONDITIONS (read-only) — refuse to build on a base we did not slice from ──────────────
do $pre$
declare
  v_raw   text;
  v_code  text;
  v_n     integer;
begin
  select p.prosrc into v_raw
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if v_raw is null then
    raise exception '0351 PRECONDITION FAIL: public.process_combat_ticks does not exist';
  end if;
  v_code := regexp_replace(v_raw, '--[^' || chr(10) || ']*', '', 'g');
  -- The stripper must have removed something and must have left a body. BOTH directions, because a
  -- broken strip makes every count below meaningless in a way that reads as success (the 0222 trap).
  if length(v_code) < 40000 or length(v_code) >= length(v_raw) then
    raise exception '0351 PRECONDITION FAIL: the comment strip produced % chars from a % char body — every count below would be measured against nothing', length(v_code), length(v_raw);
  end if;

  -- 0346 IS THE BODY THESE HUNKS WERE CUT FROM. Anything older does not carry the ingress phase, so
  -- hunk [4]'s else-arm anchor would not exist and the surgery would land on the wrong text.
  if position('ingress_ticks_left' in v_raw) = 0 then
    raise exception '0351 PRECONDITION FAIL: the deployed tick does not carry 0346''s ingress phase — it is older than the body these hunks were cut from';
  end if;
  -- 0346's OWN ANCHOR, asserted here so this slice proves it is preserving it rather than claiming to.
  v_n := (length(v_code) - length(replace(v_code, 'coalesce(v_ur.my_min_range, v_ur.my_range, 0), coalesce(v_ur.move_speed,0),', '')))
         / length('coalesce(v_ur.my_min_range, v_ur.my_range, 0), coalesce(v_ur.move_speed,0),');
  if v_n <> 1 then
    raise exception '0351 PRECONDITION FAIL: % per-unit mover call(s) pass the raw move_speed (want exactly 1) — 0346''s precondition anchor is not where this slice expects it', v_n;
  end if;
  -- THE PER-HULL GATE THIS SLICE REPLACES must be present exactly once.
  v_n := (length(v_code) - length(replace(v_code, 'if v_w_range is not null and v_target_dist <= v_w_range', '')))
         / length('if v_w_range is not null and v_target_dist <= v_w_range');
  if v_n <> 1 then
    raise exception '0351 PRECONDITION FAIL: the per-weapon fire gate occurs % time(s) (want exactly 1) — the body has drifted from the parity source', v_n;
  end if;
  -- THE PER-HULL ACQUISITION ORIGIN this slice re-points, at BOTH its sites.
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_acquire_target(v_units, v_ur.pos_x, v_ur.pos_y, v_ur.side)', '')))
         / length('public.combat_acquire_target(v_units, v_ur.pos_x, v_ur.pos_y, v_ur.side)');
  if v_n <> 2 then
    raise exception '0351 PRECONDITION FAIL: the per-hull acquisition occurs % time(s) (want exactly 2 — first acquisition and per-weapon re-acquisition)', v_n;
  end if;
  if position('v_fleet_reach' in v_raw) > 0 then
    raise exception '0351 PRECONDITION FAIL: the deployed engine already carries the fleet actor — this migration has already been applied';
  end if;
  if to_regproc('public.combat_fleet_actor') is not null then
    raise exception '0351 PRECONDITION FAIL: public.combat_fleet_actor already exists — this slice is the only thing that mints it';
  end if;
  if to_regprocedure('public.combat_fleet_move_speed(uuid)') is null then
    raise exception '0351 PRECONDITION FAIL: public.combat_fleet_move_speed(uuid) is missing at its 0337 signature — this slice re-points it onto the new leaf and cannot patch a function that is not there';
  end if;

  raise notice '0351 parity source: production, 2026-08-09, head 20260618000349. OBSERVED here: process_combat_ticks prosrc md5 = % / % chars. A difference is a REVIEW SIGNAL, not a failure — the CI chain body and production are not required to be byte-equal. What is hard-asserted is what must be true: one per-weapon gate, two per-hull acquisitions, one raw-move_speed mover call, no fleet actor yet.',
    md5(v_raw), length(v_raw);
end $pre$;

-- ── 1. CAPTURE METADATA BEFORE ANYTHING IS TOUCHED (for parity check e) ─────────────────────────
-- Taken here, not after section 2, because section 2 re-creates combat_fleet_move_speed: a snapshot
-- read afterwards would be of the NEW body and would prove nothing.
create temp table _0351_before (
  fname text primary key, body_md5 text, owner text, secdef boolean, volatility "char",
  parallel "char", proconfig text, args text, result text, acl text
) on commit drop;

insert into _0351_before
select p.proname, md5(p.prosrc), pg_get_userbyid(p.proowner), p.prosecdef, p.provolatile,
       p.proparallel, coalesce(array_to_string(p.proconfig, ','), ''),
       pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid),
       coalesce(p.proacl::text, '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('process_combat_ticks', 'combat_fleet_move_speed');

-- ── 2. THE ATTACK INTERVAL IS DATA — 5 SECONDS, BOTH SIDES, BEFORE ANYTHING READS IT ────────────
-- The engine has honoured cooldown_seconds since 0314; this is a value change and nothing else.
-- Effective cadence is 6s, not 5s, because combat_tick_seconds is 3 — see the header.
update public.module_types
   set cooldown_seconds = 5
 where slot_type = 'weapon'
   and range is not null
   and cooldown_seconds is distinct from 5;

update public.game_config
   set value = '5'::jsonb,
       description = 'COMBAT-FALLBACK (0262, retuned to 5s at 0351): seconds between shots for the synthesized basic player weapon. The owner asked for a 5-second attack interval. combat_tick_seconds is 3, so the OBSERVED cadence is 6 seconds — fire at t=0, ready at t=5, the t=3 tick finds it not ready and the t=6 tick fires. Under a 3-second scheduler the only reachable cadences are 3, 6, 9, ...; 5 is written because 5 is what was asked for, and the honest 6-second rhythm is stated rather than silently substituted.',
       updated_at = now()
 where key = 'combat_player_fallback_weapon_cooldown_seconds';

update public.game_config
   set value = '5'::jsonb,
       description = 'COMBAT-S3 (0234, retuned to 5s at 0351): synthetic pirate weapon cooldown between shots. Held EQUAL to the player interval deliberately — applying the owner''s 5 seconds to one side only would be a balance change hidden inside a feel change. Read by combat_pressure_step when it originates a body, so it reaches a weapon at spawn, never mid-fight.',
       updated_at = now()
 where key = 'enemy_synthetic_cooldown_seconds';

-- ── 3. THE FLEET ACTOR — THE ONE AUTHORITY FOR "WHAT AND WHERE IS THIS FLEET, AS ONE THING" ─────
-- Where it stands, how far it reaches, how fast it moves. One function, because they are one
-- concept: a single actor's position, reach and speed are not three independent facts, and splitting
-- them is how the three drift apart.
--
-- THE POINT mirrors src/features/map/fleetFightPosition.ts's PRIMARY arm exactly — the living,
-- positioned player row with the highest aggro_priority, ties by lowest id, which is 0315's election
-- read back off the row. The client's own FALLBACK arm (when the lead is dead it picks the hull
-- nearest an enemy) is deliberately NOT mirrored: an enemy-dependent fleet position is the teleport
-- that file's header exists to describe, and the server must not acquire one. This leaf falls back
-- to the next hull in the SAME total order instead, and the client is specified to follow.
--
-- THE REACH is the SHORTEST gun over living hulls, so nothing drawn is out of reach. THE SPEED is
-- the SLOWEST living hull — a fleet moves at its slowest ship, which is the rule
-- combat_fleet_move_speed already used and which is why that function is re-pointed onto this leaf
-- below rather than keeping a second min().
--
-- ALWAYS EXACTLY ONE ROW, so a caller's `select ... into` reads NULLs rather than leaving its
-- locals at whatever they held. STABLE, not IMMUTABLE: it reads combat_units. SECURITY DEFINER and
-- revoked from every client role — an engine internal, not a new surface.
create or replace function public.combat_fleet_actor(p_encounter uuid)
returns table(x double precision, y double precision, reach double precision, speed double precision)
language sql
stable
security definer
set search_path to 'public'
as $cfa$
  with living as (
    select cu.id, cu.pos_x, cu.pos_y, cu.aggro_priority, cu.move_speed, cu.weapons_json
      from public.combat_units cu
     where cu.encounter_id = p_encounter
       and cu.side = 'player'
       and cu.alive_count > 0
  ),
  stand as (
    select l.pos_x, l.pos_y
      from living l
     where l.pos_x is not null and l.pos_y is not null
     order by l.aggro_priority desc nulls last, l.id asc
     limit 1
  )
  select s.pos_x,
         s.pos_y,
         (select min(g.r)
            from living la
            cross join lateral (
              select (e->>'range')::double precision as r
                from jsonb_array_elements(la.weapons_json) e
            ) g
           where g.r > 0),
         (select min(la.move_speed) from living la)
    from (select 1) one
    left join stand s on true;
$cfa$;

comment on function public.combat_fleet_actor(uuid) is
  'THE ONE AUTHORITY for "what and where is this fleet, as ONE actor" (0351). Returns exactly one '
  'row: the fleet''s POINT (its 0315-elected lead — highest aggro_priority, ties by lowest id, over '
  'living POSITIONED player rows — which is the point src/features/map/fleetFightPosition.ts draws '
  'the glyph on, so the guns and the glyph cannot disagree), its REACH (the SHORTEST weapon range '
  'over its living hulls, so nothing drawn is out of reach — the same aggregate 0336 gave the mover, '
  'which is why gate and mover cannot recreate 0336''s defect 7) and its SPEED (the slowest living '
  'hull). Composed by process_combat_ticks and by combat_fleet_move_speed, and by nothing else. '
  'All four values are NULL for a fleet with no living hull; every caller guards on the point.';

revoke all on function public.combat_fleet_actor(uuid) from public;
revoke all on function public.combat_fleet_actor(uuid) from anon, authenticated;
grant execute on function public.combat_fleet_actor(uuid) to service_role;

-- 0337's leaf, RE-POINTED onto the actor so `min(move_speed) over living player rows` exists ONCE.
-- Value-identical by construction: same set, same aggregate, same scale expression. Its meaning is
-- unchanged — "how fast a fleet under an ORDERED reposition covers ground" — and its only caller,
-- the foot-of-arm reposition step, is untouched by this slice.
create or replace function public.combat_fleet_move_speed(p_encounter uuid)
returns double precision
language sql
stable
security definer
set search_path to 'public'
as $cfms$
  select (a.speed * greatest(coalesce(public.cfg_num('combat_reposition_speed_scale'), 8.0), 0))::double precision
    from public.combat_fleet_actor(p_encounter) a;
$cfms$;

-- ── 4. THE SURGERY — six hunks, each sliced VERBATIM from the deployed body ─────────────────────

do $rewrite$
declare
  r record;
  v_oid oid;
  v_src text;
  v_new text;
  v_n integer;
  v_done integer := 0;
  v_exec integer := 0;
  v_fn   text;
  -- THE WORKING SET. Every function this block edits, read ONCE into v_orig, patched in v_texts and
  -- written back to the catalog once at the end.
  v_fns  text[] := array['process_combat_ticks'];
  v_orig jsonb  := '{}'::jsonb;
  v_texts jsonb := '{}'::jsonb;
begin
  foreach v_fn in array v_fns loop
    select p.oid into v_oid
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fn;
    if v_oid is null then
      raise exception '0351 REWRITE FAIL: function public.% not found', v_fn;
    end if;
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = v_fn) <> 1 then
      raise exception '0351 REWRITE FAIL: public.% is overloaded — refusing to guess', v_fn;
    end if;
    v_src   := pg_get_functiondef(v_oid);
    v_orig  := jsonb_set(v_orig,  array[v_fn], to_jsonb(v_src));
    v_texts := jsonb_set(v_texts, array[v_fn], to_jsonb(v_src));
  end loop;

  for r in
    select * from (values

    (1, 'process_combat_ticks',
     $h1o$  v_target_dist            double precision;
  v_move_action            text;$h1o$,
     $h1n$  v_target_dist            double precision;
  -- ██ 0351 THE FLEET IS ONE ACTOR — ONE POINT, ONE REACH, ONE SPEED ██
  -- Read ONCE per encounter from combat_fleet_actor, BEFORE the unit loop, so the point cannot
  -- drift as hulls are processed (a hull writes its own position inside that loop; reading the
  -- actor inside it would make the fleet's own position depend on iteration order).
  -- ALL FOUR ARE NULL when the fleet has no living positioned hull, and every use below is guarded
  -- on v_fleet_x — so a fleet with nothing left behaves exactly as it does today.
  v_fleet_x                double precision;
  v_fleet_y                double precision;
  v_fleet_reach            double precision;
  v_fleet_speed            double precision;
  v_move_action            text;$h1n$),

    (2, 'process_combat_ticks',
     $h2o$        v_dmg_player_total := 0; v_dmg_enemy_total := 0;$h2o$,
     $h2n$        -- 0351: the fleet's own actor, from the same pre-move world as the freeze above. Both are
        -- read before the loop and neither is re-read inside it.
        select a.x, a.y, a.reach, a.speed
          into v_fleet_x, v_fleet_y, v_fleet_reach, v_fleet_speed
          from public.combat_fleet_actor(e.id) a;

        v_dmg_player_total := 0; v_dmg_enemy_total := 0;$h2n$),

    (3, 'process_combat_ticks',
     $h3o$          v_target_id := null; v_target_x := null; v_target_y := null; v_target_range := null; v_target_dist := null;
          select t.id, t.pos_x, t.pos_y, t.my_range, t.dist
            into v_target_id, v_target_x, v_target_y, v_target_range, v_target_dist
            from public.combat_acquire_target(v_units, v_ur.pos_x, v_ur.pos_y, v_ur.side) t;

          if v_target_id is null then
            continue;
          end if;$h3o$,
     $h3n$          -- ██ 0351 ONE ACTOR, SO ONE CIRCLE IS ITS REACH ██
          -- THE OWNER, TWICE: "my fleet range shape in blue is weird", then "the fleet range shape
          -- is like a cloud, make it circle." The reach was drawn as the UNION OF PER-HULL DISCS
          -- because that is what the engine actually enforced: the gate measured EVERY hull from
          -- ITS OWN position. A union of four discs is not a circle and cannot be made into one by
          -- drawing it differently — so the RULE changes, not the picture.
          -- The owner's own standing law is that the fleet is ONE actor. One actor has one position
          -- and one reach. The player side therefore acquires, measures and fires from the FLEET
          -- POINT, and one circle of radius v_fleet_reach about that point is EXACTLY the set of
          -- enemies it can hit — not an approximation of it.
          -- THE ENEMY SIDE IS NOT FOLDED, DELIBERATELY (combatActors.ts:38-42: "how many are still
          -- shooting" is the player's central read). An enemy is one hull and keeps its own circle.
          -- What changes for it is only WHAT IT MEASURES TO: the fleet's point, not whichever hull
          -- happens to be nearest — so its circle is true in the same sense the fleet's now is.
          v_target_id := null; v_target_x := null; v_target_y := null; v_target_range := null; v_target_dist := null;
          select t.id, t.pos_x, t.pos_y, t.my_range, t.dist
            into v_target_id, v_target_x, v_target_y, v_target_range, v_target_dist
            from public.combat_acquire_target(v_units,
                   case when v_ur.side = 'player' then coalesce(v_fleet_x, v_ur.pos_x) else v_ur.pos_x end,
                   case when v_ur.side = 'player' then coalesce(v_fleet_y, v_ur.pos_y) else v_ur.pos_y end,
                   v_ur.side) t;

          if v_target_id is null then
            continue;
          end if;

          -- THE ENEMY MEASURES TO THE FLEET, NOT TO A HULL. v_target_id still names the hull that
          -- will ABSORB the damage, so 0301's aggro screening (escorts shield the lead) is untouched
          -- — only the distance and the steering point become the fleet's.
          if v_ur.side = 'enemy' and v_fleet_x is not null then
            v_target_dist  := public.osn_distance(v_ur.pos_x, v_ur.pos_y, v_fleet_x, v_fleet_y);
            v_target_x     := v_fleet_x;
            v_target_y     := v_fleet_y;
            v_target_range := v_fleet_reach;
          end if;$h3n$),

    (4, 'process_combat_ticks',
     $h4o$          else
            v_ing_left := 0;
          -- MOVEMENT — combat_unit_decide_move, the pure leaf.
          select action, new_x, new_y into v_move_action, v_new_x, v_new_y
            from public.combat_unit_decide_move(
              -- 0336 NEVER RETREAT PAST YOUR SHORTEST GUN. The mover uses this argument for BOTH
              -- the close decision and the kite cap, so passing the LONGEST gun made a ship hold at
              -- its longest reach and silently disable every shorter one: the fire gate below is
              -- per weapon, so an Mk-II (range 6) fitted beside an autocannon (range 5) parks the
              -- hull at ~6 and the autocannon never fires — a better gun buying LESS damage, which
              -- is the very defect 0331 was written to end, recreated through geometry.
              -- my_min_range is MY engagement range; the target's my_range stays the LONGEST, because
              -- what I must respect about the enemy is its full reach. Two questions, two values.
              -- Single-weapon ships have min = max, so their movement is byte-identical to the head.
              v_ur.pos_x, v_ur.pos_y, coalesce(v_ur.my_min_range, v_ur.my_range, 0), coalesce(v_ur.move_speed,0),
              v_target_x, v_target_y, coalesce(v_target_range,0));
          end if;$h4o$,
     $h4n$          else
            v_ing_left := 0;
          if v_ur.side = 'player' and v_fleet_x is not null then
            -- ██ 0351 THE FLEET MOVES AS ONE BODY ██
            -- The gate above measures from the fleet point, so the MOVER has to steer the same
            -- quantity or the two disagree and the fight deadlocks: with the escort ring at
            -- spatial_formation_ring_radius = 6 against a reach of 5, a hull that stopped when IT
            -- was in range could leave the fleet point up to 6 further out than the gate allows —
            -- the formation would halt, satisfied, and never fire a shot. One decision, one delta.
            -- THE DECISION IS MADE ONCE, AT THE FLEET POINT, and applied to this hull as a RIGID
            -- TRANSLATION. The delta depends only on fleet quantities, so every hull receives the
            -- identical step and the formation the encounter builder laid out survives the journey
            -- by construction — the same property 0339's combat_translate_player_formation gives
            -- an ORDERED reposition, obtained here by composing the same pure leaf rather than by
            -- forking a second mover.
            select action, new_x, new_y into v_move_action, v_new_x, v_new_y
              from public.combat_unit_decide_move(
                v_fleet_x, v_fleet_y, coalesce(v_fleet_reach, 0), coalesce(v_fleet_speed, 0),
                v_target_x, v_target_y, coalesce(v_target_range, 0));
            v_new_x := v_ur.pos_x + (v_new_x - v_fleet_x);
            v_new_y := v_ur.pos_y + (v_new_y - v_fleet_y);
          else
          -- MOVEMENT — combat_unit_decide_move, the pure leaf.
          select action, new_x, new_y into v_move_action, v_new_x, v_new_y
            from public.combat_unit_decide_move(
              -- 0336 NEVER RETREAT PAST YOUR SHORTEST GUN. The mover uses this argument for BOTH
              -- the close decision and the kite cap, so passing the LONGEST gun made a ship hold at
              -- its longest reach and silently disable every shorter one: the fire gate below is
              -- per weapon, so an Mk-II (range 6) fitted beside an autocannon (range 5) parks the
              -- hull at ~6 and the autocannon never fires — a better gun buying LESS damage, which
              -- is the very defect 0331 was written to end, recreated through geometry.
              -- my_min_range is MY engagement range; the target's my_range stays the LONGEST, because
              -- what I must respect about the enemy is its full reach. Two questions, two values.
              -- Single-weapon ships have min = max, so their movement is byte-identical to the head.
              v_ur.pos_x, v_ur.pos_y, coalesce(v_ur.my_min_range, v_ur.my_range, 0), coalesce(v_ur.move_speed,0),
              v_target_x, v_target_y, coalesce(v_target_range,0));
          end if;
          end if;$h4n$),

    (5, 'process_combat_ticks',
     $h5o$            if not exists (select 1 from combat_units cu3 where cu3.id = v_target_id and cu3.alive_count > 0) then
              select t.id, t.pos_x, t.pos_y, t.my_range, t.dist
                into v_target_id, v_target_x, v_target_y, v_target_range, v_target_dist
                from public.combat_acquire_target(v_units, v_ur.pos_x, v_ur.pos_y, v_ur.side) t;
              if v_target_id is null then
                exit;
              end if;
            end if;$h5o$,
     $h5n$            if not exists (select 1 from combat_units cu3 where cu3.id = v_target_id and cu3.alive_count > 0) then
              select t.id, t.pos_x, t.pos_y, t.my_range, t.dist
                into v_target_id, v_target_x, v_target_y, v_target_range, v_target_dist
                from public.combat_acquire_target(v_units,
                       case when v_ur.side = 'player' then coalesce(v_fleet_x, v_ur.pos_x) else v_ur.pos_x end,
                       case when v_ur.side = 'player' then coalesce(v_fleet_y, v_ur.pos_y) else v_ur.pos_y end,
                       v_ur.side) t;
              -- 0351: the RE-acquisition measures the same quantity the first one did. Without this
              -- the volley's later guns would fall back to a per-hull distance the instant a kill
              -- re-aimed them, and the circle would be true for the first shot of a tick and a lie
              -- for the rest. (v_target_x/y and v_target_range are not read again after the mover,
              -- which has already run for this unit, so only the distance has to be restated.)
              if v_ur.side = 'enemy' and v_fleet_x is not null then
                v_target_dist := public.osn_distance(v_ur.pos_x, v_ur.pos_y, v_fleet_x, v_fleet_y);
              end if;
              if v_target_id is null then
                exit;
              end if;
            end if;$h5n$),

    (6, 'process_combat_ticks',
     $h6o$            if v_w_range is not null and v_target_dist <= v_w_range
               and (v_w_next_ready is null or now() >= v_w_next_ready) then$h6o$,
     $h6n$            -- 0351 THE GATE IS THE CIRCLE. For the player side the radius is the FLEET's reach —
            -- its SHORTEST gun — so every gun on every hull fires exactly when the one drawn circle
            -- contains the target, and never otherwise. Picking the shortest rather than the longest
            -- is the same choice 0336 made for the mover (my_min_range, "NEVER RETREAT PAST YOUR
            -- SHORTEST GUN"): gate and mover now aggregate identically, so 0336's defect 7 — a
            -- longer gun silently disabling a shorter one — cannot recur through this change.
            -- v_w_range is still required to be non-null, so an entry that is not a gun still cannot
            -- fire; the coalesce is unreachable while any living hull carries a positive range.
            if v_w_range is not null
               and v_target_dist <= case when v_ur.side = 'player'
                                         then coalesce(v_fleet_reach, v_w_range)
                                         else v_w_range end
               and (v_w_next_ready is null or now() >= v_w_next_ready) then$h6n$)

    ) as t(idx, fname, old_t, new_t)
    order by 1
  loop
    -- ██ EVERY HUNK IS APPLIED TO AN IN-MEMORY TEXT, NEVER TO THE CATALOG ██
    -- 0346 shipped the opposite and CI went red on all 22 legs: executing per hunk creates one
    -- intermediate body per hunk, Postgres validates a plpgsql body at CREATE time, and a hunk that
    -- moves a DECLARATION away from its USES is rejected (42601) even when the final text is
    -- correct. Hunk [1] here declares four locals that hunks [2]-[6] use — precisely that shape.
    -- Accumulating and executing ONCE per function makes the class impossible rather than avoided,
    -- and scripts/check-surgery-identifiers.mjs fails the build on the other shape.
    if not v_texts ? r.fname then
      raise exception '0351 REWRITE FAIL [%]: public.% was not read into the working set', r.idx, r.fname;
    end if;
    v_src := v_texts ->> r.fname;
    v_n := (length(v_src) - length(replace(v_src, r.old_t, ''))) / length(r.old_t);
    if v_n <> 1 then
      raise exception '0351 REWRITE FAIL [%]: hunk text occurs % time(s) in public.%, expected exactly 1 — the deployed body is not what this migration was sliced against',
        r.idx, v_n, r.fname;
    end if;
    v_new := replace(v_src, r.old_t, r.new_t);
    if length(v_new) <> length(v_src) - length(r.old_t) + length(r.new_t) then
      raise exception '0351 REWRITE FAIL [%]: unexpected length delta rewriting public.%', r.idx, r.fname;
    end if;
    if v_new = v_src then
      raise exception '0351 REWRITE FAIL [%]: the rewrite of public.% produced a byte-identical body — the hunk did not land', r.idx, r.fname;
    end if;
    v_texts := jsonb_set(v_texts, array[r.fname], to_jsonb(v_new));
    v_done := v_done + 1;
  end loop;

  -- The number of rows in this block's own VALUES list. Not a count of anything in the world.
  if v_done <> 6 then
    raise exception '0351 REWRITE FAIL: applied % hunk(s), expected 6 (the number of rows in this block''s own VALUES list)', v_done;
  end if;

  foreach v_fn in array v_fns loop
    if (v_texts ->> v_fn) = (v_orig ->> v_fn) then
      raise exception '0351 REWRITE FAIL: public.% is byte-identical to the body that was read', v_fn;
    end if;
    execute v_texts ->> v_fn;
    v_exec := v_exec + 1;
  end loop;
  if v_exec <> 1 then
    raise exception '0351 REWRITE FAIL: re-created % function(s), expected 1', v_exec;
  end if;
end $rewrite$;

-- ── 5. SELF-ASSERTS — one DO block per check; every prosrc probe strips comments first ──────────

-- (a) the actor leaf has the engine-internal posture, and NO client role can execute it
do $a$
declare v_oid oid;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_fleet_actor';
  if v_oid is null then
    raise exception '0351 ASSERT (a) FAIL: leaf public.combat_fleet_actor was not created';
  end if;
  if not exists (select 1 from pg_proc p where p.oid = v_oid
                  and p.provolatile = 's' and p.prosecdef = true
                  and coalesce(array_to_string(p.proconfig, ','), '') = 'search_path=public') then
    raise exception '0351 ASSERT (a) FAIL: the leaf has the wrong volatility / security / search_path posture — it READS combat_units, so it must be STABLE and SECURITY DEFINER with a pinned search_path';
  end if;
  if has_function_privilege('anon', v_oid, 'EXECUTE')
     or has_function_privilege('authenticated', v_oid, 'EXECUTE') then
    raise exception '0351 ASSERT (a) FAIL: the leaf is EXECUTE-able by a client role — it is an engine internal, not a new surface';
  end if;
end $a$;

-- (b) ONE POINT AND ONE REACH, and the per-hull gate is GONE
-- ⚠ NON-VACUITY FIRST. Every count is taken over a COMMENT-STRIPPED body, and the banners this
-- migration inserts NAME the expressions they replaced — so an un-stripped probe would count prose
-- as code, and an over-eager strip would count nothing at all. Both directions are checked before
-- any count is believed.
do $b$
declare v_raw text; v_code text; v_n integer;
begin
  select p.prosrc into v_raw from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  v_code := regexp_replace(v_raw, '--[^' || chr(10) || ']*', '', 'g');
  if length(v_code) < 40000 or length(v_code) >= length(v_raw) then
    raise exception '0351 ASSERT (b) FAIL: the comment strip produced % chars from a % char tick body — every count below would be measured against nothing', length(v_code), length(v_raw);
  end if;

  -- THE PER-HULL GATE IS GONE. This is the assert that fails the deploy if the union comes back:
  -- the player side must no longer be able to fire on a bare per-weapon range comparison.
  if position('if v_w_range is not null and v_target_dist <= v_w_range' in v_code) > 0 then
    raise exception '0351 ASSERT (b) FAIL: the per-hull/per-weapon fire gate is still present — the fleet would again reach in a UNION OF DISCS rather than the one circle the owner asked for, twice';
  end if;
  -- ...and the fleet's reach is what the player side is gated on, exactly once.
  v_n := (length(v_code) - length(replace(v_code, 'then coalesce(v_fleet_reach, v_w_range)', '')))
         / length('then coalesce(v_fleet_reach, v_w_range)');
  if v_n <> 1 then
    raise exception '0351 ASSERT (b) FAIL: the player fire gate reads the fleet reach % time(s), want exactly 1', v_n;
  end if;

  -- THE ACTOR IS READ ONCE PER ENCOUNTER, AND ONLY THERE. More than one read inside the tick would
  -- mean the fleet's own position could change while its hulls are being processed.
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_fleet_actor(', '')))
         / length('public.combat_fleet_actor(');
  if v_n <> 1 then
    raise exception '0351 ASSERT (b) FAIL: the tick composes the fleet actor % time(s), want exactly 1 (once per encounter, before the unit loop)', v_n;
  end if;

  -- 0346's ANCHOR SURVIVES: exactly one per-unit mover call still passes the raw move_speed, so a
  -- future ingress rewriter still finds the text it slices against.
  v_n := (length(v_code) - length(replace(v_code, 'coalesce(v_ur.my_min_range, v_ur.my_range, 0), coalesce(v_ur.move_speed,0),', '')))
         / length('coalesce(v_ur.my_min_range, v_ur.my_range, 0), coalesce(v_ur.move_speed,0),');
  if v_n <> 1 then
    raise exception '0351 ASSERT (b) FAIL: % per-unit mover call(s) pass the raw move_speed (want exactly 1) — 0346''s precondition anchor was destroyed by this slice', v_n;
  end if;

  -- BOTH ACQUISITION SITES MEASURE THE SAME QUANTITY. If only one were re-pointed, the circle would
  -- be true for a tick's first shot and a lie for every later gun in the same volley.
  v_n := (length(v_code) - length(replace(v_code, 'case when v_ur.side = ''player'' then coalesce(v_fleet_x, v_ur.pos_x) else v_ur.pos_x end', '')))
         / length('case when v_ur.side = ''player'' then coalesce(v_fleet_x, v_ur.pos_x) else v_ur.pos_x end');
  if v_n <> 2 then
    raise exception '0351 ASSERT (b) FAIL: the fleet-point acquisition origin appears % time(s), want exactly 2 (first acquisition and per-weapon re-acquisition)', v_n;
  end if;

  -- THE FLEET MOVES AS ONE: the rigid translation is present exactly once, and the tick still holds
  -- no second position formula of its own.
  v_n := (length(v_code) - length(replace(v_code, 'v_new_x := v_ur.pos_x + (v_new_x - v_fleet_x);', '')))
         / length('v_new_x := v_ur.pos_x + (v_new_x - v_fleet_x);');
  if v_n <> 1 then
    raise exception '0351 ASSERT (b) FAIL: the fleet''s rigid translation appears % time(s), want exactly 1', v_n;
  end if;

  -- EXACTLY TWO COMPOSERS OF THE ACTOR IN THE WHOLE SCHEMA — the tick and combat_fleet_move_speed.
  -- The sweep CANNOT pass vacuously: the count must be exactly 0, measured over every OTHER function.
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname not in ('process_combat_ticks', 'combat_fleet_move_speed', 'combat_fleet_actor')
     and position('combat_fleet_actor(' in regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')) > 0;
  if v_n <> 0 then
    raise exception '0351 ASSERT (b) FAIL: % other function(s) compose the fleet actor — what and where a fleet is must be decided in exactly two places, the tick and the reposition speed leaf', v_n;
  end if;

  -- THIS SLICE ADDS NO WRITER OF engagement_x. 0339 made combat_encounter_move the sole one and both
  -- its assert and DZCOMBAT_PASS_ONEANCHOR pin it; restating it here means a bad shape fails the
  -- DEPLOY rather than a CI round.
  if position('engagement_x =' in v_code) > 0 then
    raise exception '0351 ASSERT (b) FAIL: the tick now writes engagement_x directly — combat_encounter_move is the only function permitted to, and this slice must not have added a second';
  end if;
end $b$;

-- (c) THE LEAF'S CONTRACT, EXECUTED — shape, fail-closed, and the election rule it must follow
do $c$
declare v_x double precision; v_y double precision; v_r double precision; v_s double precision;
        v_rows integer; v_src text;
begin
  -- ALWAYS EXACTLY ONE ROW, even for an encounter that does not exist. A caller's `select ... into`
  -- must read NULLs rather than silently leaving its locals at whatever the previous unit left.
  select count(*) into v_rows from public.combat_fleet_actor('00000000-0000-0000-0000-000000000000'::uuid);
  if v_rows <> 1 then
    raise exception '0351 ASSERT (c) FAIL: the leaf returned % row(s) for an encounter that does not exist, want exactly 1 — a zero-row answer would leave a caller''s locals stale', v_rows;
  end if;
  select a.x, a.y, a.reach, a.speed into v_x, v_y, v_r, v_s
    from public.combat_fleet_actor('00000000-0000-0000-0000-000000000000'::uuid) a;
  if v_x is not null or v_y is not null or v_r is not null or v_s is not null then
    raise exception '0351 ASSERT (c) FAIL: the leaf invented a point/reach/speed for a fleet that does not exist — it must fail closed to NULL, never to a guessed value or (0,0)';
  end if;

  -- THE ELECTION RULE IS THE CLIENT'S. Asserted on the leaf's own text because the rows needed to
  -- execute it do not exist in a migration, and fabricating a world here would be a write to live
  -- player data. The BEHAVIOURAL proof is danger-combat-proof's DZCOMBAT_PASS_FLEETACTOR block.
  select p.prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_fleet_actor';
  if position('order by l.aggro_priority desc nulls last, l.id asc' in v_src) = 0 then
    raise exception '0351 ASSERT (c) FAIL: the leaf does not order by the 0315 election (aggro_priority desc, id asc) — the server would stand the fleet on a different hull than the client draws it on';
  end if;
  if position('l.pos_x is not null and l.pos_y is not null' in v_src) = 0 then
    raise exception '0351 ASSERT (c) FAIL: the leaf can stand the fleet on an unpositioned row — fleetFightPosition.ts requires a living POSITIONED hull and the two must agree';
  end if;
  if position('min(g.r)' in v_src) = 0 or position('min(la.move_speed)' in v_src) = 0 then
    raise exception '0351 ASSERT (c) FAIL: the leaf does not take the SHORTEST gun and the SLOWEST hull — a max() reach would draw a circle claiming reach the fleet does not have';
  end if;
end $c$;

-- (d) combat_fleet_move_speed IS RE-POINTED, NOT REDEFINED — one min(move_speed) in the schema
do $d$
declare v_src text; v_n integer;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_fleet_move_speed';
  if position('public.combat_fleet_actor(p_encounter)' in v_src) = 0 then
    raise exception '0351 ASSERT (d) FAIL: combat_fleet_move_speed does not compose the actor — there would be two independent min(move_speed) definitions of one fleet''s speed';
  end if;
  if position('min(' in v_src) > 0 then
    raise exception '0351 ASSERT (d) FAIL: combat_fleet_move_speed still computes an aggregate of its own — the measurement moved to the leaf and must not have multiplied';
  end if;
  -- the ordered-reposition scale is UNCHANGED, value for value
  if position('combat_reposition_speed_scale' in v_src) = 0 then
    raise exception '0351 ASSERT (d) FAIL: combat_fleet_move_speed lost its ordered-reposition scale — its meaning is unchanged by this slice and its value must be identical';
  end if;
  -- exactly one function in the schema aggregates a fleet's combat move_speed
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname <> 'combat_fleet_actor'
     and position('min(cu.move_speed)' in regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')) > 0;
  if v_n <> 0 then
    raise exception '0351 ASSERT (d) FAIL: % function(s) besides the leaf aggregate a fleet''s move_speed', v_n;
  end if;
end $d$;

-- (e) METADATA PARITY — the rewritten functions changed their BODY and nothing else
do $e$
declare r record;
begin
  for r in
    select b.fname, b.body_md5, b.owner, b.secdef, b.volatility, b.parallel, b.proconfig,
           b.args, b.result, b.acl,
           md5(p.prosrc) as now_md5, pg_get_userbyid(p.proowner) as now_owner,
           p.prosecdef as now_secdef, p.provolatile as now_volatility, p.proparallel as now_parallel,
           coalesce(array_to_string(p.proconfig, ','), '') as now_proconfig,
           pg_get_function_identity_arguments(p.oid) as now_args,
           pg_get_function_result(p.oid) as now_result,
           coalesce(p.proacl::text, '') as now_acl
      from _0351_before b
      join pg_proc p on p.proname = b.fname
      join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
  loop
    if r.body_md5 = r.now_md5 then
      raise exception '0351 ASSERT (e) FAIL: public.% has a byte-identical body — its edits are missing rather than applied', r.fname;
    end if;
    if r.owner is distinct from r.now_owner or r.secdef is distinct from r.now_secdef
       or r.volatility is distinct from r.now_volatility or r.parallel is distinct from r.now_parallel
       or r.proconfig is distinct from r.now_proconfig or r.args is distinct from r.now_args
       or r.result is distinct from r.now_result or r.acl is distinct from r.now_acl then
      raise exception '0351 ASSERT (e) FAIL: public.% changed something other than its body (owner/secdef/volatility/parallel/search_path/args/result/acl) — this slice re-creates two function BODIES and must move nothing else', r.fname;
    end if;
  end loop;
end $e$;

-- (f) THE CADENCE IS DATA, IT IS 5 EVERYWHERE, THE ENGINE STILL READS IT, AND NOTHING IS DARK
do $f$
declare v_n integer; v_code text;
begin
  -- every firing weapon in the catalog
  select count(*) into v_n from public.module_types
   where slot_type = 'weapon' and range is not null and cooldown_seconds is distinct from 5;
  if v_n <> 0 then
    raise exception '0351 ASSERT (f) FAIL: % firing weapon(s) in module_types do not carry the 5-second interval', v_n;
  end if;
  -- and the check cannot pass vacuously on an empty catalog
  select count(*) into v_n from public.module_types where slot_type = 'weapon' and range is not null;
  if v_n < 1 then
    raise exception '0351 ASSERT (f) FAIL: module_types holds no firing weapon at all — the check above would have passed over nothing';
  end if;

  -- both synthesized weapons, player and pirate, held EQUAL
  if (select value from public.game_config where key = 'combat_player_fallback_weapon_cooldown_seconds') is distinct from '5'::jsonb then
    raise exception '0351 ASSERT (f) FAIL: the synthesized player weapon does not carry the 5-second interval';
  end if;
  if (select value from public.game_config where key = 'enemy_synthetic_cooldown_seconds') is distinct from '5'::jsonb then
    raise exception '0351 ASSERT (f) FAIL: the synthetic pirate weapon does not carry the 5-second interval — the owner''s interval applies to BOTH sides, and a one-sided cadence is a balance change hidden in a feel change';
  end if;

  -- 0314's PROPERTY, RESTATED: the engine must still arm next_ready_at from the weapon's OWN
  -- cooldown. If this ever regresses to a bare now(), every cooldown in the catalog silently stops
  -- meaning anything and the owner's 5 seconds becomes 3 with no visible cause.
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if position('now() + make_interval(secs => coalesce((v_weapon->>''cooldown_seconds'')::double precision, 0))' in v_code) = 0 then
    raise exception '0351 ASSERT (f) FAIL: the tick no longer arms next_ready_at from the weapon''s own cooldown_seconds (0314) — a cooldown nothing reads is not a cadence';
  end if;

  -- NOTHING DARK: no gate-shaped key exists for this slice.
  select count(*) into v_n from public.game_config
   where key in ('fleet_fires_as_one_enabled', 'combat_fleet_actor_enabled', 'combat_one_circle_enabled');
  if v_n <> 0 then
    raise exception '0351 ASSERT (f) FAIL: a gate-shaped key exists for this slice — it ships lit or not at all';
  end if;
end $f$;

commit;
