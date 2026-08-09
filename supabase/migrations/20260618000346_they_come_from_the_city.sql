-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0346 — THEY COME FROM THE CITY  (the city is the ONLY spawn position; an INGRESS phase brings
--        the raider in, in a fixed number of ticks, and clamps it on the engagement boundary)
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- ── THE OWNER, FOR THE SECOND TIME ──────────────────────────────────────────────────────────────
--   "when a wave start, i want ships to appear from the city."
-- and earlier, about reinforcements:
--   "once an enemy fleet is destroyed, it should come out from snare, not on a blank space."
--
-- A repeated instruction is not a clarification. It is evidence that something already built says
-- the opposite, and the standing law is to find that thing and DELETE it rather than soften it.
--
-- ── WHAT SAYS THE OPPOSITE, NAMED ───────────────────────────────────────────────────────────────
-- 0338 introduced public.combat_wave_arrival_phase and chose, in its own words:
--
--     "THE ORIGIN IS A BEARING, NEVER A POSITION. Spawning the wave AT the city would be a
--      forty-unit, forty-tick walk before anyone fired"
--
-- 0339 folded the two spawn arms into public.combat_spawn_wave_units and carried that choice
-- forward as the one placement expression:
--
--     combat_formation_point(ANCHOR, v_extent + p_range + 1, slot,
--                            combat_wave_arrival_phase(ANCHOR, SITE, slot))
--
-- The net effect the owner has now rejected twice: a raider MATERIALISES just outside the player's
-- weapon range, merely FACING the city. It never comes from it. THAT IS WHAT IS DELETED. After this
-- migration there is no expression anywhere in the schema that ORIGINATES an enemy body on a ring
-- around the fight.
--
-- ⛔ combat_spawn_wave_units ITSELF IS NOT DELETED, AND MUST NOT BE. It is the schema's only
--    inserter of an enemy combat_units row, and combat_pressure_step is its only caller — verified
--    read-only against production 2026-08-09 with a comment-stripped catalog sweep, not assumed.
--    This slice changes WHERE it originates a body, not how many authorities exist. Its signature,
--    its security posture and its ACL are untouched.
--
-- ── THE MODEL: ONE ORIGIN, ONE DESTINATION, AND A PHASE BETWEEN THEM ────────────────────────────
--
--     origin      = THE CITY. Always. The only spawn position there is.
--     destination = the current lawful engagement boundary — 0336's MEASURED-extent clearance ring,
--                   at this body's own slot, on 0338's city bearing. Recomputed EVERY TICK.
--     between     = INGRESS, a movement phase of a fixed number of TICKS, clamped on arrival.
--
-- 0338's bearing is not an alternate origin any more. It is GEOMETRY: it says which way the
-- destination lies, and it always did. That is why this is ONE rule and not two — there is no
-- predicate anywhere choosing between "from the city" and "on the bearing".
--
-- ── WHY A FIXED NUMBER OF TICKS AND NOT A FASTER SPEED ──────────────────────────────────────────
-- A raised approach SPEED recreates the very defect it is meant to cure: a constant speed still
-- makes a distant spawn take proportionally longer, so the fix would hold at one distance and fail
-- at another. Measured, against the distances that actually occur:
--
--   * Snare's city is at (-45, 120). The owner's real encounter 49acbae0 fought at about (-57, 101)
--     — 22.5 units out. Snare's zone spans x -89.7..-10.5, y 94.4..141.7, so its far corner is
--     ~51.5 units out.
--   * The ambush corridors the harness actually drives are far longer, because an ambush fires
--     wherever a leg crosses a zone and every fixture launches from Haven Reach (-150, -90):
--     105, 217, 362, 547 and 619 units from the site the encounter resolves to.
--   * A raider's own speed at the live sites is 1.0 / 1.2 / 1.6 per 3-second tick
--     (enemy_synthetic_speed_base 0.6 + base_difficulty x 0.04; difficulties 10 / 15 / 25).
--
-- At 1.0/tick, 51.5 units is 51.5 ticks = 154 SECONDS against a ~130-second average fight, and 217
-- units is 651 seconds. A x4 speed multiplier — the alternative that was designed and measured
-- before this one — bounds the zone cases to ~32 s but leaves the corridor cases at 54 to 155
-- TICKS. THE DISTANCE IS THE PROBLEM, SO THE FIX HAS TO BE THE THING THAT MAKES DISTANCE STOP
-- MATTERING. A fixed tick budget does exactly that: the same ingress from 12 units and from 619.
--
-- combat_enemy_ingress_ticks = 6, i.e. 6 x combat_tick_seconds(3) = 18 SECONDS. Chosen so that:
--   * it is long enough to WATCH — the client polls ~1.5 s and interpolates between observed server
--     positions, so 18 s is a continuous run-in, not a snap;
--   * it is shorter than every site's reinforcement cadence (Snare 45 s, Reaver 36 s, Blackden
--     30 s), so a body always reaches the fight before the next one is due and the field converges
--     on its cap instead of trailing a queue of raiders in transit;
--   * it is ~14% of the ~130-second average fight, so the fight is fought, not waited out.
-- It is DATA: a game_config row with a written description, discoverable through
-- scripts/list-knobs.mjs and writable through scripts/set-knob.mjs.
--
-- ── THE CLAMP IS THE SAFETY PROPERTY, NOT THE SPEED ─────────────────────────────────────────────
-- Each tick an ingressing body steps `distance_to_boundary / remaining_ingress_ticks` toward the
-- boundary, through combat_unit_decide_move with my_range = 0 and target_range = 0 — the engine's
-- ONE step-toward-a-point primitive, asked exactly as 0339's fleet reposition asks it. That leaf's
-- close arm steps `least(speed, dist)`, so:
--   * the step can NEVER carry the body past the boundary point, because the speed it is handed is
--     at most the remaining distance (remaining ticks >= 1);
--   * on the LAST ingress tick remaining is 1, so the speed IS the distance and the body lands
--     EXACTLY on the boundary rather than on a floating-point approach to it;
--   * a body therefore cannot cross the engagement line at any ingress duration, any distance, any
--     tick. High ingress velocity is harmless; an unclamped step would not be.
--
-- AND THE PATH ITSELF STAYS OUTSIDE THE CLEARANCE RING, not just its endpoint — stated with its
-- bound rather than asserted vaguely. The body walks a straight segment from a city that is
-- OUTSIDE the ring (that is the degenerate test below) to a point ON it. For such a segment the
-- nearest approach to the ring's centre is the endpoint itself whenever the angle at that endpoint
-- is at least 90 degrees, which holds while the slot's fan stays under 90 degrees off the
-- city bearing. 0338's fan is half-slot steps, so slot k is (k+1)/4 slots off the bearing, i.e.
-- 67.5 degrees at slot 5 — and the live concurrent caps are 3 / 4 / 6, so slot 5 is the widest a
-- field can reach. The approach therefore touches the clearance ring only where it stops.
-- 0336's clearance invariant survives UNCHANGED and becomes stronger: it was a spawn-time property,
-- and it is now enforced on every tick of the approach.
--
-- ── FIRING DURING INGRESS: NO EXCEPTION, DELIBERATELY ───────────────────────────────────────────
-- There is no "ingress units cannot shoot" branch and there must never be one. The existing gate
-- already produces the right behaviour for free: the tick measures fire distance from the FROZEN
-- PRE-MOVE snapshot (v_units, and the per-weapon re-acquisition reads v_ur.pos_x), so an inbound
-- raider outside its own range simply cannot reach, and one that lands on the boundary on tick k
-- fires on k+1. Targeting and fire are untouched by this migration.
--
-- ── THE DEGENERATE CASE, DECIDED AND STATED ────────────────────────────────────────────────────
-- If the fight is so close to its city that the CITY IS ALREADY AT OR INSIDE the engagement
-- boundary, there is nothing to ingress across. The body is then placed ON the boundary with no
-- ingress at all — exactly today's behaviour, value for value. That covers a fight standing in its
-- own city, a site with no linked location, and a vanished location alike, because the boundary
-- leaf's own fallbacks are 0338's and are unchanged. The test is ONE distance comparison against
-- the boundary the leaf itself returned, so there is no second definition of where the boundary is.
--
-- A LOCATION THAT VANISHES MID-INGRESS does not strand anyone: the anchor is
-- coalesce(engagement_x, loc.x), so a stamped fight keeps its anchor, the bearing leaf falls back
-- to 0338's own constant, and the body completes its ingress onto the plain ring. A fight with
-- NEITHER an anchor nor a site has no position at all and never reaches this arm — v_is_spatial is
-- false for it.
--
-- ── WHAT IS COMPOSED, AND THE ONE THING THAT MOVED ─────────────────────────────────────────────
-- public.combat_ingress_boundary is minted as THE authority for "where does a body coming from the
-- city stop". It contains no new geometry: it is 0336's MEASURED extent (max distance from the
-- anchor to a living player row — the measurement that keeps a LONE hull from waiting out an
-- approach it has no screen to justify), plus 0336's radius (extent + this body's own range + 1),
-- placed through 0336's combat_formation_point on 0338's combat_wave_arrival_phase. Every one of
-- those is the deployed text, relocated.
--
-- THE MEASUREMENT MOVED OUT OF combat_spawn_wave_units AND INTO THAT LEAF, and it had to: the TICK
-- now needs the boundary every tick, and 0339 had already folded the extent measurement into the
-- spawn function precisely so it would exist ONCE. Re-adding a measurement to the tick would make
-- two. So it moves to a leaf that BOTH callers compose, and it is still measured in exactly one
-- place — 0339's law kept, not broken.
--
-- ── PER-UNIT INGRESS STATE, AND WHY IT IS TWO NULLABLE COLUMNS ──────────────────────────────────
--   combat_units.ingress_ticks_left  — how many ticks of ingress remain. NULL = not ingressing.
--   combat_units.ingress_slot        — this body's slot on the boundary ring.
--
-- A COUNTDOWN, NOT A DEADLINE, deliberately. A deadline against the encounter's tick_number would
-- depend on whether the caller had already advanced that column — the exact fragility 0343
-- documented at its own call sites — and a deadline against now() would freeze solid inside a proof
-- transaction, where now() does not advance. A countdown decremented by the same statement that
-- writes the position is immune to both and needs no clock at all.
--
-- THE SLOT IS STORED BECAUSE THE DESTINATION IS PER-BODY. Without it every ingressing raider would
-- steer at the same boundary point and arrive stacked — the pile 0336 removed, re-created at the
-- destination instead of at the origin. With it, each body walks to its own slot on the ring.
--
-- BOTH ARE NULLABLE WITH NO DEFAULT, so the ALTER is a catalog-only change on a live table: no
-- rewrite, no backfill. Every row that already exists — every enemy body standing in a fight right
-- now, and every player row forever — reads NULL and is therefore NOT ingressing, i.e. behaves
-- exactly as it does today.
--
-- ── THE CLIENT NEEDS NOTHING, AND THAT WAS CHECKED, NOT ASSUMED ─────────────────────────────────
-- The owner's whole point is that they can WATCH them come, so "is an inbound raider visible" was
-- answered by reading the client and then PINNED by a spec (tests/citySortie.spec.ts), because "no
-- change was needed" is a claim with no guard:
--   * src/features/combat/combatApi.ts:29-34 — fetchCombatUnits selects every combat_units row for
--     the encounter with NO distance, viewport or count filter. A body at the city is fetched.
--   * src/features/map/spatialCombatLayer.ts:337-349 — combatFocusWorldPoints builds the camera's
--     bounding box from EVERY positioned, alive unit of the fight, each padded by its own reach.
--   * src/features/map/GalaxyMap.tsx:446-466 — the fight camera RE-FRAMES whenever that box leaves
--     the frame, for as long as the player has not taken the camera themselves. The view opens out
--     to include the city the raiders come from. That effect exists because the owner already hit
--     the off-screen version of this once: "When enemy ship is destroyed, i teleport to some random
--     place inside the zone."
--   * src/features/map/combatMotion.ts:96-107 — a NEW id gets a zero-length window, so a raider
--     APPEARS at the city rather than being tweened in from elsewhere, and every step after that is
--     interpolated between two OBSERVED server positions. The ingress animates continuously.
-- So there is no other half to land, and this slice touches no client source file.
--
-- ── THE LIVE ENGINE IS THE AUTHORITY, NOT THE REPO ──────────────────────────────────────────────
-- process_combat_ticks exists in this repository only as a chain of text-patch migrations; no file
-- holds it whole. This migration reads what is actually DEPLOYED (pg_get_functiondef at apply time)
-- and replaces marked hunks in it. It contains NO `create or replace function
-- public.process_combat_ticks` — eleven generators each assert that 0299 is still the newest
-- TEXTUAL re-create of that function, and a full re-emission breaks all eleven at once. 0343
-- established this shape and its header states the rule; this file follows it.
--
-- SIX HUNKS, each required to match its source text EXACTLY ONCE. Zero occurrences means the
-- deployed body is not the one these hunks were cut from and the migration ABORTS rather than
-- silently patching nothing; more than one means the anchor is ambiguous and aborts too.
--
--   [S1] combat_spawn_wave_units  declare block               — locals for the boundary and ingress
--   [S2] combat_spawn_wave_units  extent + placement + INSERT — THE DELETION, and the new origin
--   [T1] process_combat_ticks     declare block               — locals for the ingress step
--   [T2] process_combat_ticks     frozen snapshot             — the two ingress columns join it
--   [T3] process_combat_ticks     the movement decision       — the ingress phase
--   [T4] process_combat_ticks     the position write          — the countdown rides it
--
-- Five generators watch this function for exactly this kind of surgery and each names its later
-- rewriters BY NAME rather than widening a version window; 0346 joins all five (gen-0317, gen-0332,
-- gen-0336, gen-0337, gen-0339) with its disjointness argument written beside it. Every hunk this
-- file cuts from the tick lands in text 0336 or 0339 created — `v_ring_radius`, `v_spawn_slot`,
-- `my_min_range`, the frozen snapshot — none of which exists in the 0299 head those generators
-- slice from, so the disjointness is structural rather than a judgement.
--
-- ── BLAST RADIUS: PRODUCTION IS A LIVE ~30-PLAYER GAME ──────────────────────────────────────────
--   * ONE transaction. Both leaves exist before the tick that names them, so there is never an
--     instant at which the tick calls a function that does not exist.
--   * NO grant on any client-reachable surface, NO flag, NO reward / drop / threshold / range /
--     speed / difficulty value moved, NO row written outside pg_proc, two catalog-only columns and
--     the ONE game_config knob seeded below.
--   * ENCOUNTERS THAT ARE `active` AT THE INSTANT THIS APPLIES: a cron tick already executing
--     finishes on the old bodies and resolves its encounter completely; the next tick uses the new
--     ones and resolves it completely.
--   * EVERY ENEMY ROW ALREADY ON THE FIELD READS ingress_ticks_left = NULL, so it is not ingressing
--     and moves exactly as it does today. No existing row is repositioned, re-ranged, re-sped or
--     re-slotted; this migration writes no combat row at all. There is no state a mid-fight
--     encounter can be left in that no arm can reach, because the new state is the ABSENCE of the
--     new state for everything that predates this commit.
--   * THE ONE OBSERVABLE DELTA: a body placed AFTER this commits appears at its city and takes 6
--     ticks to reach the same engagement boundary it used to be placed on. It is visible for those
--     6 ticks and cannot fire during them, exactly as it could not fire on its spawn tick before.
--
-- ── ROLLBACK BOUNDARY ───────────────────────────────────────────────────────────────────────────
-- Six hunks, one new leaf, two columns and one config row. Every hunk's PRE-IMAGE is in this file,
-- verbatim, in the VALUES list, so nothing has to be reconstructed from a dump or from an older
-- migration (copying from an older FILE is what reverted this tick's mode line three times). In one
-- transaction, in this order:
--   1. re-run the surgery block with old_t and new_t SWAPPED, each still required to match exactly
--      once — this restores 0339's placement expression, its inline extent measurement, the plain
--      frozen snapshot, the ordinary movement block and the plain position write;
--   2. `drop function public.combat_ingress_boundary(uuid, double precision, double precision,
--      double precision, double precision, double precision, integer);`
--   3. `delete from public.game_config where key = 'combat_enemy_ingress_ticks';`
--   4. OPTIONALLY `alter table public.combat_units drop column ingress_ticks_left, drop column
--      ingress_slot;` — safe once step 1 has removed every reader and writer, and safe to LEAVE in
--      place otherwise, because a column nothing reads changes no behaviour.
-- The order matters: the drop must not precede the removal of its callers. Nothing else unwinds —
-- no grant on a client-reachable surface, no data write, no client half. Bodies already ingressing
-- at the moment of a rollback stop ingressing and resume ordinary combat movement from wherever
-- they stand, which is a legal state for any enemy row and needs no repair.
--
-- ── NOTHING DARK ────────────────────────────────────────────────────────────────────────────────
-- There is no feature flag and no way to ship this invisible. The knob is a DURATION, not a gate,
-- and the way this slice could go dark is a duration of 0 — which would place every body straight
-- on the boundary and restore precisely the behaviour the owner rejected. Assert (f) therefore
-- requires the seeded value to be strictly greater than 0, and requires that no gate-shaped key
-- exists for this slice at all.
--
-- ── SELF-ASSERT MAP (one DO block per check — the statement number IS the diagnosis) ────────────
--   (a) the boundary leaf has the engine-internal posture and NO client role can execute it
--   (b) ONE ORIGIN AUTHORITY, and the rejected one is GONE: the spawn writes a body's position from
--       the SITE's own coordinates, the placement authority no longer carries formation geometry or
--       an extent measurement of its own, the boundary leaf is composed by exactly two functions,
--       the tick still contains no formation geometry, no OTHER function places an enemy body, and
--       nothing outside those two touches the ingress countdown
--   (c) THE BOUNDARY LEAF IS 0336's RING, EXECUTED: over eight bearings and four slots it stands at
--       exactly (range + 1) from the anchor for an empty formation, reproduces combat_formation_point
--       value for value, and slot 0 lies on the ray toward the city
--   (d) THE INGRESS ARRIVES, EXACTLY, AND NEVER CROSSES — EXECUTED through the REAL mover, from the
--       owner's measured 22.5 units and from the harness's longest 619-unit corridor: monotone,
--       never past the boundary, landing EXACTLY on it, and taking the SAME number of ticks from
--       both — which is the distance-independence that makes this a duration and not a speed
--   (e) THE COLUMNS ARE THE IN-FLIGHT CONTRACT: both exist, both nullable and default-less, and NO
--       existing row carries a value — so every fight in progress is provably un-ingressed
--   (f) the knob exists, carries a written meaning, and is strictly greater than 0; and no
--       gate-shaped key exists
--   (g) metadata parity: both rewritten functions changed their BODY and nothing else
--
-- WHAT THESE CANNOT PROVE, STATED RATHER THAN IMPLIED: that the real tick then walks a real body
-- from a real city. A self-assert cannot open a fight. That is proven by exactly one layer — the
-- disposable-Postgres apply-proof driving the REAL tick.
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
  v_def   text;
  v_sraw  text;
  v_n     integer;
begin
  select p.prosrc, pg_get_functiondef(p.oid)
    into v_raw, v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if v_raw is null then
    raise exception '0346 PRECONDITION FAIL: public.process_combat_ticks does not exist';
  end if;
  v_code := regexp_replace(v_raw, '--[^' || chr(10) || ']*', '', 'g');
  -- The stripper must have removed something and must have left a body. Both directions, because a
  -- broken strip makes every count below meaningless in a way that reads as success (the 0222 trap).
  if length(v_code) < 40000 or length(v_code) >= length(v_raw) then
    raise exception '0346 PRECONDITION FAIL: the comment strip produced % chars from a % char body — every count below would be measured against nothing', length(v_code), length(v_raw);
  end if;

  -- THE SPAWN AUTHORITY MUST BE THE ONE 0339 MINTED, AND THE ONLY ONE.
  if to_regprocedure('public.combat_spawn_wave_units(uuid, uuid, text, integer, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, integer)') is null then
    raise exception '0346 PRECONDITION FAIL: public.combat_spawn_wave_units is missing at its 0339 signature — this slice moves where it originates a body and cannot patch a function that is not there';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'combat_spawn_wave_units') <> 1 then
    raise exception '0346 PRECONDITION FAIL: public.combat_spawn_wave_units is overloaded — there must be exactly ONE placement authority and this slice refuses to guess which';
  end if;
  select p.prosrc into v_sraw
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_spawn_wave_units';

  -- 0344 IS THE BODY THESE HUNKS WERE CUT FROM: the tick must already read the pressure clock. If it
  -- still carried a wave sizer, this placement would be applied to a spawn model that no longer
  -- exists and the right answer is to stop and look.
  if position('combat_pressure_step' in v_code) = 0 then
    raise exception '0346 PRECONDITION FAIL: the deployed tick does not compose combat_pressure_step — it is older than 0344, i.e. older than the body these hunks were cut from';
  end if;
  -- The expression this slice DELETES as an origin must be present exactly once, in the placement
  -- authority, together with the measurement that feeds it.
  v_n := (length(v_sraw) - length(replace(v_sraw, 'v_extent + p_range + 1', ''))) / length('v_extent + p_range + 1');
  if v_n <> 1 then
    raise exception '0346 PRECONDITION FAIL: 0336''s measured-extent radius appears % time(s) in combat_spawn_wave_units (want exactly 1) — the body has drifted from the parity source and this surgery would land on the wrong text', v_n;
  end if;
  if position('public.combat_wave_arrival_phase(p_anchor_x, p_anchor_y, p_site_x, p_site_y, v_slot)' in v_sraw) = 0 then
    raise exception '0346 PRECONDITION FAIL: combat_spawn_wave_units does not carry 0338''s bearing composition — this slice relocates exactly that expression into a leaf and must not be applied blind';
  end if;
  if to_regproc('public.combat_ingress_boundary') is not null then
    raise exception '0346 PRECONDITION FAIL: public.combat_ingress_boundary already exists — this slice is the only thing that mints it';
  end if;
  if position('ingress_ticks_left' in v_raw) > 0 or position('ingress_ticks_left' in v_sraw) > 0 then
    raise exception '0346 PRECONDITION FAIL: the deployed engine already carries the ingress phase — this migration has already been applied';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'combat_units'
                and column_name in ('ingress_ticks_left', 'ingress_slot')) then
    raise exception '0346 PRECONDITION FAIL: combat_units already carries an ingress column — this slice adds both, and adding one twice would leave two notions of the same phase';
  end if;
  -- The mover call this slice re-routes must be the PER-UNIT one, and there must be exactly one of
  -- it. The FLEET reposition step calls the same leaf with different arguments and is deliberately
  -- excluded by this anchor: a fleet under orders is not a raider and never ingresses.
  v_n := (length(v_code) - length(replace(v_code, 'coalesce(v_ur.my_min_range, v_ur.my_range, 0), coalesce(v_ur.move_speed,0),', '')))
         / length('coalesce(v_ur.my_min_range, v_ur.my_range, 0), coalesce(v_ur.move_speed,0),');
  if v_n <> 1 then
    raise exception '0346 PRECONDITION FAIL: % per-unit mover call(s) pass the raw move_speed (want exactly 1). The fleet reposition step must NOT be re-routed by this slice, so an ambiguous anchor aborts', v_n;
  end if;

  raise notice '0346 parity source: production, 2026-08-09, head 20260618000344. OBSERVED here: process_combat_ticks md5(pg_get_functiondef) = % / % chars (prosrc md5 = % / % chars); combat_spawn_wave_units prosrc md5 = % / % chars. A difference is a REVIEW SIGNAL, not a failure — the CI chain body and production are not required to be byte-equal, and this surgery does not depend on them being so. What is hard-asserted is what must be true: one clearance expression, one 0338 bearing composition, no ingress state yet, one per-unit mover call.',
    md5(v_def), length(v_def), md5(v_raw), length(v_raw), md5(v_sraw), length(v_sraw);
end $pre$;

-- ── 1. THE INGRESS STATE — two nullable columns, catalog-only on a live table ───────────────────
alter table public.combat_units
  add column ingress_ticks_left integer,
  add column ingress_slot       integer;

comment on column public.combat_units.ingress_ticks_left is
  '0346: ticks of INGRESS remaining for an enemy body travelling in from its zone''s city. NULL = not ingressing, which is every player row and every row that predates 0346. Counted DOWN by the same statement that writes the position — never a deadline against tick_number (which depends on whether the caller has advanced it) and never against now() (which is frozen inside a proof transaction).';
comment on column public.combat_units.ingress_slot is
  '0346: this body''s slot on the engagement boundary ring, so two raiders ingressing at once steer at DIFFERENT points and cannot arrive stacked. NULL = not ingressing.';

-- ── 2. THE KNOB — the ingress duration is DATA, with a written meaning, before anything reads it ─
insert into public.game_config (key, value, description)
values ('combat_enemy_ingress_ticks', '6'::jsonb,
        '0346: how many combat ticks an enemy body spends travelling in from its zone''s own city before it reaches the engagement boundary and starts fighting. 6 ticks x combat_tick_seconds(3) = 18 seconds. It is a fixed number of TICKS rather than a speed precisely so that DISTANCE STOPS MATTERING: the same 18 seconds from a city 12 units away and from one 619 units away. A speed instead of a duration was designed and measured first and rejected — at the live raider speeds (1.0/1.2/1.6 per tick) even a 4x sortie leaves the long ambush corridors at 54 to 155 ticks, which is the 154-second walk 0338 refused to allow and the reason it never spawned at the city at all. 0 disables the ingress and puts every body straight on the boundary, i.e. restores exactly the behaviour the owner has rejected twice. 6 is shorter than every site''s reinforcement cadence (Snare 45s, Reaver 36s, Blackden 30s), so a body always reaches the fight before the next one is due.')
on conflict (key) do update
  set value = excluded.value, description = excluded.description, updated_at = now();

-- ── 3. THE BOUNDARY LEAF — the ONE authority for "where does a body coming from the city stop" ──
-- NO NEW GEOMETRY. This is 0336's MEASURED extent, 0336's radius (extent + this body's own range
-- + 1), 0336's combat_formation_point and 0338's combat_wave_arrival_phase — the deployed text,
-- relocated so that BOTH the placement authority and the tick can ask the same question and get the
-- same answer. It is recomputed every tick on purpose: the fleet moves (0337/0339 made a reposition
-- a real multi-tick journey) and hulls die, so the anchor and the extent both breathe, and a
-- destination solved once at spawn would be stale by the time the body arrived.
--
-- WHY THE MEASUREMENT MOVED HERE RATHER THAN BACK INTO THE TICK: 0339 folded it out of the tick's
-- two spawn arms precisely so it would exist ONCE. Re-adding it to the tick would make two. One
-- leaf, two callers, one measurement.
--
-- STABLE, not IMMUTABLE: it reads combat_units. SECURITY DEFINER and revoked from every client role,
-- matching combat_spawn_wave_units, whose reads it now performs.
create or replace function public.combat_ingress_boundary(
  p_encounter uuid,
  p_anchor_x  double precision,
  p_anchor_y  double precision,
  p_site_x    double precision,
  p_site_y    double precision,
  p_range     double precision,
  p_slot      integer)
returns table(x double precision, y double precision)
language sql
stable
security definer
set search_path to 'public'
as $fib$
  select fp.x, fp.y
    from (
      -- THE EXTENT THE BODY MUST STAND CLEAR OF, MEASURED — never assumed from the ring knob (0336).
      -- Max over the LIVING player rows of their distance from the anchor: the lead sits ON it (0),
      -- escorts sit out on the escort ring, and a lone hull IS its own lead, so its extent is 0.
      -- Every player ship is therefore within this of the anchor, which is exactly what makes the
      -- clearance structural: the minimum separation between any player ship and any enemy is
      -- (extent + range + 1) - extent = range + 1, whatever the formation's shape.
      select coalesce(max(public.osn_distance(p_anchor_x, p_anchor_y, u.pos_x, u.pos_y)), 0) as extent
        from public.combat_units u
       where u.encounter_id = p_encounter and u.side = 'player' and u.alive_count > 0
         and u.pos_x is not null and u.pos_y is not null
    ) m,
    lateral public.combat_formation_point(
      p_anchor_x, p_anchor_y, m.extent + p_range + 1, p_slot,
      public.combat_wave_arrival_phase(p_anchor_x, p_anchor_y, p_site_x, p_site_y, p_slot)) fp;
$fib$;

comment on function public.combat_ingress_boundary(uuid, double precision, double precision, double precision, double precision, double precision, integer) is
  'THE ONE AUTHORITY for "where does a body coming from the city stop" (0346). Returns the point on '
  '0336''s clearance ring — the MEASURED player-formation extent plus this body''s own weapon range '
  'plus 1 — at the given slot, on 0338''s bearing toward the zone''s own city. It is the DESTINATION '
  'of the ingress phase and the placement of a body that has no ingress to make. Composed by '
  'combat_spawn_wave_units and by process_combat_ticks, and by nothing else. It contains no new '
  'geometry: every part of it is the text 0336 and 0338 deployed, moved here so one measurement '
  'serves both callers (0339 folded that measurement out of the tick to make it singular; this '
  'keeps it singular). Recomputed per tick because the anchor and the extent both move in a fight.';

revoke all on function public.combat_ingress_boundary(uuid, double precision, double precision, double precision, double precision, double precision, integer) from public;
revoke all on function public.combat_ingress_boundary(uuid, double precision, double precision, double precision, double precision, double precision, integer) from anon, authenticated;
grant execute on function public.combat_ingress_boundary(uuid, double precision, double precision, double precision, double precision, double precision, integer) to service_role;

-- ── 4. CAPTURE METADATA BEFORE THE SURGERY (for parity check g) ─────────────────────────────────
create temp table _0346_before (
  fname text primary key, body_md5 text, owner text, secdef boolean, volatility "char",
  parallel "char", proconfig text, args text, result text, acl text
) on commit drop;

insert into _0346_before
select p.proname, md5(p.prosrc), pg_get_userbyid(p.proowner), p.prosecdef, p.provolatile,
       p.proparallel, coalesce(array_to_string(p.proconfig, ','), ''),
       pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid),
       coalesce(p.proacl::text, '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('process_combat_ticks', 'combat_spawn_wave_units');

-- ── 5. THE SURGERY — six hunks, each sliced VERBATIM from its own deployed body ─────────────────
do $rewrite$
declare
  r record;
  v_oid oid;
  v_src text;
  v_new text;
  v_n integer;
  v_done integer := 0;
begin
  for r in
    select * from (values

    -- ── [S1] combat_spawn_wave_units — locals for the boundary and the ingress ──────────────────
    (1, 'combat_spawn_wave_units',
     $s1o$declare
  v_extent double precision;
  v_slot   integer := coalesce(p_slot_from, 0);
  v_i      integer;
  v_x      double precision;
  v_y      double precision;
begin$s1o$,
     $s1n$declare
  v_slot   integer := coalesce(p_slot_from, 0);
  v_i      integer;
  v_x      double precision;
  v_y      double precision;
  -- 0346: v_bx/v_by are this body's engagement BOUNDARY — where it is going, and where it is placed
  -- outright when there is nothing to travel across. v_ing is how many ticks of ingress it gets,
  -- read once from the knob rather than per body. v_extent is GONE: the measurement it held lives in
  -- combat_ingress_boundary now, so it is made once and read by both callers.
  v_bx     double precision;
  v_by     double precision;
  v_ing    integer;
begin$s1n$),

    -- ── [S2] combat_spawn_wave_units — THE DELETION, and the new origin ─────────────────────────
    (2, 'combat_spawn_wave_units',
     $s2o$  -- THE EXTENT THE WAVE MUST STAND CLEAR OF, MEASURED — never assumed from the ring knob (0336).
  -- Max over the LIVING player rows of their distance from the anchor: the lead sits ON it (0),
  -- escorts sit out on the escort ring, and a lone hull IS its own lead, so its extent is 0. Every
  -- player ship is therefore within v_extent of the anchor, which is exactly what makes the
  -- clearance structural: the minimum separation between any player ship and any enemy is
  -- (extent + range + 1) - extent = range + 1, whatever the formation's shape.
  select coalesce(max(public.osn_distance(p_anchor_x, p_anchor_y, u.pos_x, u.pos_y)), 0)
    into v_extent
    from public.combat_units u
   where u.encounter_id = p_encounter and u.side = 'player' and u.alive_count > 0
     and u.pos_x is not null and u.pos_y is not null;
  for v_i in 1 .. p_count loop
    select fp.x, fp.y into v_x, v_y
      from public.combat_formation_point(p_anchor_x, p_anchor_y, v_extent + p_range + 1, v_slot,
             public.combat_wave_arrival_phase(p_anchor_x, p_anchor_y, p_site_x, p_site_y, v_slot)) fp;
    insert into public.combat_units (
      encounter_id, player_id, unit_type_id, side, ship_hp, initial_count, alive_count,
      hp_max, hp_current, pos_x, pos_y, move_speed, weapons_json)
    values (
      p_encounter, p_player, p_unit_type_id, 'enemy', p_unit_hp, 1, 1,
      p_unit_hp, p_unit_hp, v_x, v_y, p_speed,
      jsonb_build_array(jsonb_build_object(
        'module_type_id', 'pirate_synthetic_weapon', 'range', p_range,
        'projectile_speed', p_projectile_speed, 'power', p_unit_power,
        'ammo_type', null, 'ammo_per_shot', 0, 'cooldown_seconds', p_cooldown,
        'next_ready_at', null, 'ammo_remaining', null)));$s2o$,
     $s2n$  -- 0346 THE CITY IS THE ONLY SPAWN POSITION.
  -- 0338 chose "THE ORIGIN IS A BEARING, NEVER A POSITION" and 0339 carried that choice here as the
  -- one placement expression: a ring around the FIGHT, merely ORIENTED by the city. The owner has now
  -- rejected that twice — "when a wave start, i want ships to appear from the city", and before it
  -- "once an enemy fleet is destroyed, it should come out from snare, not on a blank space". So a
  -- body is now ORIGINATED AT ITS CITY and travels in, and 0338's bearing stops being an origin and
  -- becomes what it always was underneath: the direction of the DESTINATION.
  -- THE MEASUREMENT MOVED, IT DID NOT MULTIPLY. 0339 folded the extent measurement into this
  -- function so it would exist once; the tick now needs the same boundary every tick, so the
  -- measurement moved into combat_ingress_boundary and BOTH callers compose it. Still one.
  v_ing := greatest(coalesce(cfg_num('combat_enemy_ingress_ticks'), 6)::integer, 0);
  for v_i in 1 .. p_count loop
    -- WHERE THIS BODY IS GOING — 0336's clearance ring at its own slot, on 0338's city bearing.
    select b.x, b.y into v_bx, v_by
      from public.combat_ingress_boundary(p_encounter, p_anchor_x, p_anchor_y, p_site_x, p_site_y, p_range, v_slot) b;
    -- THE DEGENERATE CASE, DECIDED: if the city is at or inside the boundary there is nothing to
    -- travel across, so the body is placed ON the boundary with no ingress — exactly today's
    -- behaviour, value for value. That covers a fight standing in its own city, a site with no
    -- linked location and a vanished location alike, because the boundary leaf's own fallbacks are
    -- 0338's and are unchanged. ONE comparison, against the boundary the leaf itself returned, so
    -- there is no second definition of where the boundary is.
    if v_ing <= 0
       or p_site_x is null or p_site_y is null or v_bx is null or v_by is null
       or public.osn_distance(p_anchor_x, p_anchor_y, p_site_x, p_site_y)
          <= public.osn_distance(p_anchor_x, p_anchor_y, v_bx, v_by) then
      v_x := v_bx; v_y := v_by;
      insert into public.combat_units (
        encounter_id, player_id, unit_type_id, side, ship_hp, initial_count, alive_count,
        hp_max, hp_current, pos_x, pos_y, move_speed, weapons_json)
      values (
        p_encounter, p_player, p_unit_type_id, 'enemy', p_unit_hp, 1, 1,
        p_unit_hp, p_unit_hp, v_x, v_y, p_speed,
        jsonb_build_array(jsonb_build_object(
          'module_type_id', 'pirate_synthetic_weapon', 'range', p_range,
          'projectile_speed', p_projectile_speed, 'power', p_unit_power,
          'ammo_type', null, 'ammo_per_shot', 0, 'cooldown_seconds', p_cooldown,
          'next_ready_at', null, 'ammo_remaining', null)));
    else
      -- IT COMES OUT OF THE CITY. The position is the site's own coordinate — not a ring around it,
      -- not a bearing from it, the place itself — and the ingress state says where it is headed and
      -- how long it has to get there.
      insert into public.combat_units (
        encounter_id, player_id, unit_type_id, side, ship_hp, initial_count, alive_count,
        hp_max, hp_current, pos_x, pos_y, move_speed, weapons_json,
        ingress_ticks_left, ingress_slot)
      values (
        p_encounter, p_player, p_unit_type_id, 'enemy', p_unit_hp, 1, 1,
        p_unit_hp, p_unit_hp, p_site_x, p_site_y, p_speed,
        jsonb_build_array(jsonb_build_object(
          'module_type_id', 'pirate_synthetic_weapon', 'range', p_range,
          'projectile_speed', p_projectile_speed, 'power', p_unit_power,
          'ammo_type', null, 'ammo_per_shot', 0, 'cooldown_seconds', p_cooldown,
          'next_ready_at', null, 'ammo_remaining', null)),
        v_ing, v_slot);
    end if;$s2n$),

    -- ── [T1] process_combat_ticks — locals for the ingress step ─────────────────────────────────
    (3, 'process_combat_ticks',
     $t1o$  v_ring_radius            double precision;
  v_spawn_slot             integer;$t1o$,
     $t1n$  v_ring_radius            double precision;
  -- 0346 THE INGRESS: a body travelling in from its city steers at its own boundary point rather
  -- than at its target. These three locals are the phase's entire footprint inside this function —
  -- where it is going, and whether it is still going there.
  v_ing_left               integer;
  v_ing_bx                 double precision;
  v_ing_by                 double precision;
  v_spawn_slot             integer;$t1n$),

    -- ── [T2] process_combat_ticks — the two ingress columns join the frozen snapshot ────────────
    (4, 'process_combat_ticks',
     $t2o$        select coalesce(jsonb_agg(jsonb_build_object(
                 'id', cu2.id, 'side', cu2.side, 'pos_x', cu2.pos_x, 'pos_y', cu2.pos_y,
                 'my_range', (select max((w->>'range')::double precision) from jsonb_array_elements(cu2.weapons_json) w),
                 'my_min_range', (select min((w->>'range')::double precision) from jsonb_array_elements(cu2.weapons_json) w),
                 'move_speed', coalesce(cu2.move_speed, 0),
                 'aggro_priority', cu2.aggro_priority,
                 'main_ship_id', cu2.main_ship_id) order by cu2.id), '[]'::jsonb)
          into v_units
          from combat_units cu2
          where cu2.encounter_id = e.id and cu2.alive_count > 0;

        v_dmg_player_total := 0; v_dmg_enemy_total := 0;

        for v_ur in
          select * from jsonb_to_recordset(v_units) as x(
            id uuid, side text, pos_x double precision, pos_y double precision,
            my_range double precision, my_min_range double precision,
            move_speed double precision, aggro_priority integer, main_ship_id uuid)$t2o$,
     $t2n$        -- 0346: the INGRESS STATE joins the frozen snapshot. It is read here with everything else,
        -- from the same pre-move world, so a body's phase is decided by the same freeze that decides
        -- its position and its target — never re-read live inside the loop, which would let a body
        -- processed earlier change what a later one sees.
        select coalesce(jsonb_agg(jsonb_build_object(
                 'id', cu2.id, 'side', cu2.side, 'pos_x', cu2.pos_x, 'pos_y', cu2.pos_y,
                 'my_range', (select max((w->>'range')::double precision) from jsonb_array_elements(cu2.weapons_json) w),
                 'my_min_range', (select min((w->>'range')::double precision) from jsonb_array_elements(cu2.weapons_json) w),
                 'move_speed', coalesce(cu2.move_speed, 0),
                 'aggro_priority', cu2.aggro_priority,
                 'ingress_left', cu2.ingress_ticks_left,
                 'ingress_slot', cu2.ingress_slot,
                 'main_ship_id', cu2.main_ship_id) order by cu2.id), '[]'::jsonb)
          into v_units
          from combat_units cu2
          where cu2.encounter_id = e.id and cu2.alive_count > 0;

        v_dmg_player_total := 0; v_dmg_enemy_total := 0;

        for v_ur in
          select * from jsonb_to_recordset(v_units) as x(
            id uuid, side text, pos_x double precision, pos_y double precision,
            my_range double precision, my_min_range double precision,
            move_speed double precision, aggro_priority integer,
            ingress_left integer, ingress_slot integer, main_ship_id uuid)$t2n$),

    -- ── [T3] process_combat_ticks — the ingress phase ───────────────────────────────────────────
    (5, 'process_combat_ticks',
     $t3o$          -- MOVEMENT — combat_unit_decide_move, the pure leaf.
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
              v_target_x, v_target_y, coalesce(v_target_range,0));$t3o$,
     $t3n$          -- 0346 INGRESS — A RAIDER COMING FROM ITS CITY STEERS AT THE BOUNDARY, NOT AT YOU.
          -- A body placed at its zone's city has a journey to make before it is in the fight at all.
          -- For those ticks its destination is its OWN slot on the engagement boundary, recomputed
          -- here every tick, because the fleet moves and hulls die, so both the anchor and the
          -- measured extent breathe and a destination solved once at spawn would arrive stale.
          -- THE STEP IS distance / remaining ticks, WHICH IS WHY THIS IS A DURATION AND NOT A SPEED:
          -- the same 6 ticks from a city 12 units away and from one 619 units away. A speed was
          -- designed and measured first and rejected — at the live raider speeds even a 4x sortie
          -- leaves the long ambush corridors at 54 to 155 ticks, which is the walk 0338 refused.
          -- THE CLAMP IS THE SAFETY PROPERTY, NOT THE SPEED. combat_unit_decide_move's close arm
          -- steps least(speed, dist), and the speed handed to it here is at most the remaining
          -- distance, so no ingress step can cross the boundary at any duration or any distance. On
          -- the LAST tick remaining is 1, the speed IS the distance, and the body lands EXACTLY on
          -- the boundary instead of on a floating-point approach to it. That is what protects
          -- 0336's clearance, which was a spawn-time property and is now enforced every tick.
          -- NO FIRE EXCEPTION IS ADDED, DELIBERATELY. The ordinary gate already decides: fire
          -- distance is measured from this frozen PRE-MOVE snapshot, so an inbound raider outside
          -- its own range simply cannot reach, and one that lands on the boundary on tick k fires on
          -- k+1. Targeting and fire below are untouched.
          -- THE PLAYER SIDE CAN NEVER ENTER THIS PHASE: ingress_ticks_left is written by exactly one
          -- statement, in combat_spawn_wave_units, which writes only enemy rows.
          v_ing_left := coalesce(v_ur.ingress_left, 0);
          if v_ing_left > 0 then
            select b.x, b.y into v_ing_bx, v_ing_by
              from public.combat_ingress_boundary(e.id, v_anchor_x, v_anchor_y, loc.x, loc.y,
                     coalesce(v_ur.my_range, 0), coalesce(v_ur.ingress_slot, 0)) b;
          else
            v_ing_bx := null; v_ing_by := null;
          end if;
          if v_ing_bx is not null and v_ing_by is not null then
            -- my_range 0 and target_range 0 is "walk at this point, capped by my speed, stop when
            -- you get there" — the same composition 0339's fleet reposition step asks for. No second
            -- clamp, no second distance formula.
            select action, new_x, new_y into v_move_action, v_new_x, v_new_y
              from public.combat_unit_decide_move(
                v_ur.pos_x, v_ur.pos_y, 0,
                public.osn_distance(v_ur.pos_x, v_ur.pos_y, v_ing_bx, v_ing_by) / greatest(v_ing_left, 1),
                v_ing_bx, v_ing_by, 0);
          else
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
          end if;$t3n$),

    -- ── [T4] process_combat_ticks — the countdown rides the position write ──────────────────────
    (6, 'process_combat_ticks',
     $t4o$          if not (v_ur.side = 'player' and v_rp_live) then
            update combat_units set pos_x = v_new_x, pos_y = v_new_y, updated_at = now() where id = v_ur.id;
          end if;$t4o$,
     $t4n$          if not (v_ur.side = 'player' and v_rp_live) then
            -- 0346 THE COUNTDOWN RIDES THE POSITION WRITE. One statement moves the body and spends
            -- the tick it used to move, so the phase can never disagree with the travel. A countdown
            -- rather than a deadline: it needs no clock, so it is immune both to whether the caller
            -- has advanced tick_number and to the frozen now() inside a proof transaction. Reaching
            -- 0 CLEARS both columns back to NULL — the body has arrived, it is an ordinary raider
            -- from here, and "not ingressing" has exactly one representation.
            update combat_units
               set pos_x = v_new_x, pos_y = v_new_y,
                   ingress_ticks_left = case when v_ing_left > 0
                                             then nullif(v_ing_left - 1, 0)
                                             else ingress_ticks_left end,
                   ingress_slot       = case when v_ing_left = 1 then null else ingress_slot end,
                   updated_at = now()
             where id = v_ur.id;
          end if;$t4n$)

    ) as t(idx, fname, old_t, new_t)
    order by 1
  loop
    select p.oid into v_oid
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = r.fname;
    if v_oid is null then
      raise exception '0346 REWRITE FAIL [%]: function public.% not found', r.idx, r.fname;
    end if;
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = r.fname) <> 1 then
      raise exception '0346 REWRITE FAIL [%]: public.% is overloaded — refusing to guess', r.idx, r.fname;
    end if;

    v_src := pg_get_functiondef(v_oid);
    v_n := (length(v_src) - length(replace(v_src, r.old_t, ''))) / length(r.old_t);
    if v_n <> 1 then
      raise exception '0346 REWRITE FAIL [%]: hunk text occurs % time(s) in public.%, expected exactly 1 — the deployed body is not what this migration was sliced against',
        r.idx, v_n, r.fname;
    end if;

    v_new := replace(v_src, r.old_t, r.new_t);
    if length(v_new) <> length(v_src) - length(r.old_t) + length(r.new_t) then
      raise exception '0346 REWRITE FAIL [%]: unexpected length delta rewriting public.%', r.idx, r.fname;
    end if;
    if v_new = v_src then
      raise exception '0346 REWRITE FAIL [%]: the rewrite of public.% produced a byte-identical body — the hunk did not land', r.idx, r.fname;
    end if;
    execute v_new;
    v_done := v_done + 1;
  end loop;

  if v_done <> 6 then
    raise exception '0346 REWRITE FAIL: rewrote % site(s), expected 6', v_done;
  end if;
end $rewrite$;

-- ── 6. SELF-ASSERTS — one DO block per check; every prosrc probe strips comments first ──────────

-- (a) the boundary leaf has the engine-internal posture, and NO client role can execute it
do $a$
declare v_oid oid;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_ingress_boundary';
  if v_oid is null then
    raise exception '0346 ASSERT (a) FAIL: leaf public.combat_ingress_boundary was not created';
  end if;
  if not exists (select 1 from pg_proc p where p.oid = v_oid
                  and p.provolatile = 's' and p.prosecdef = true
                  and coalesce(array_to_string(p.proconfig, ','), '') = 'search_path=public') then
    raise exception '0346 ASSERT (a) FAIL: the leaf has the wrong volatility / security / search_path posture — it READS combat_units, so it must be STABLE and SECURITY DEFINER with a pinned search_path, matching the placement authority whose reads it performs';
  end if;
  if has_function_privilege('anon', v_oid, 'EXECUTE')
     or has_function_privilege('authenticated', v_oid, 'EXECUTE') then
    raise exception '0346 ASSERT (a) FAIL: the leaf is EXECUTE-able by a client role — it is an engine internal, not a new surface';
  end if;
end $a$;

-- (b) ONE ORIGIN AUTHORITY, and the rejected one is GONE
-- ⚠ NON-VACUITY FIRST. Every count is taken over a COMMENT-STRIPPED body, and the banners this
-- migration inserts NAME the expressions they replaced — so an un-stripped probe would count prose
-- as code, and an over-eager strip would count nothing at all. Both directions are checked before
-- any count is believed.
do $b$
declare v_code text; v_raw text; v_tick text; v_traw text; v_n integer;
begin
  select p.prosrc into v_raw from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_spawn_wave_units';
  v_code := regexp_replace(v_raw, '--[^' || chr(10) || ']*', '', 'g');
  if length(v_code) < 400 or length(v_code) >= length(v_raw) then
    raise exception '0346 ASSERT (b) FAIL: the comment strip produced % chars from a % char placement body — every count below would be measured against nothing', length(v_code), length(v_raw);
  end if;
  select p.prosrc into v_traw from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  v_tick := regexp_replace(v_traw, '--[^' || chr(10) || ']*', '', 'g');
  if length(v_tick) < 40000 or length(v_tick) >= length(v_traw) then
    raise exception '0346 ASSERT (b) FAIL: the comment strip produced % chars from a % char tick body', length(v_tick), length(v_traw);
  end if;

  -- THE ORIGIN IS THE CITY. This is the assert that fails the deploy if the bearing-only placement
  -- ever comes back: a body's position must be written from the SITE's own coordinates, which the
  -- rejected design does not and cannot contain.
  v_n := (length(v_code) - length(replace(v_code, 'p_unit_hp, p_unit_hp, p_site_x, p_site_y, p_speed,', '')))
         / length('p_unit_hp, p_unit_hp, p_site_x, p_site_y, p_speed,');
  if v_n <> 1 then
    raise exception '0346 ASSERT (b) FAIL: % placement(s) originate a body AT THE SITE (want exactly 1). 0 means a body is once again laid out around the FIGHT and merely pointed at the city — the design the owner has rejected twice and which this slice exists to delete', v_n;
  end if;
  -- ...and the geometry it used to inline is GONE from it: the placement authority no longer
  -- measures an extent or composes a formation point of its own. One measurement, in one leaf.
  if position('combat_formation_point' in v_code) > 0 or position('combat_wave_arrival_phase' in v_code) > 0 then
    raise exception '0346 ASSERT (b) FAIL: combat_spawn_wave_units still composes the formation geometry directly — it must ask combat_ingress_boundary, or there are two places that decide where the boundary is';
  end if;
  if position('v_extent' in v_code) > 0 then
    raise exception '0346 ASSERT (b) FAIL: combat_spawn_wave_units still measures a formation extent — 0339 made that measurement singular and this slice moves it to the boundary leaf; two copies is how the two drift apart';
  end if;

  -- EXACTLY TWO COMPOSERS OF THE BOUNDARY, and they are the placement authority and the tick. The
  -- sweep CANNOT pass vacuously: each count must be exactly 1, so a probe that matches nothing
  -- fails rather than reporting "no others".
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_ingress_boundary(', '')))
         / length('public.combat_ingress_boundary(');
  if v_n <> 1 then
    raise exception '0346 ASSERT (b) FAIL: the placement authority composes the boundary leaf % time(s), want exactly 1', v_n;
  end if;
  v_n := (length(v_tick) - length(replace(v_tick, 'public.combat_ingress_boundary(', '')))
         / length('public.combat_ingress_boundary(');
  if v_n <> 1 then
    raise exception '0346 ASSERT (b) FAIL: the tick composes the boundary leaf % time(s), want exactly 1 (the per-unit ingress step)', v_n;
  end if;
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname not in ('combat_spawn_wave_units', 'process_combat_ticks', 'combat_ingress_boundary')
     and position('combat_ingress_boundary(' in regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')) > 0;
  if v_n <> 0 then
    raise exception '0346 ASSERT (b) FAIL: % other function(s) compose the boundary leaf — the destination of an ingress is decided in exactly two places, the one that places a body and the one that walks it', v_n;
  end if;

  -- THE TICK STILL CONTAINS NO FORMATION GEOMETRY OF ITS OWN. danger-combat-proof's ONEANCHOR sweep
  -- pins this too; restating it here means a bad shape fails the DEPLOY rather than a CI round.
  if position('combat_formation_point(' in v_tick) > 0
     or position('combat_wave_arrival_phase(' in v_tick) > 0
     or position('v_formation_extent' in v_tick) > 0 then
    raise exception '0346 ASSERT (b) FAIL: the tick now carries formation geometry of its own — the ingress destination must come from combat_ingress_boundary, or the tick becomes a second place that decides where a body stands';
  end if;

  -- AND EXACTLY ONE FUNCTION IN public PLACES AN ENEMY BODY. Broader than the authority's own
  -- spelling — `insert into combat_units` with or without the schema prefix — because the two
  -- encounter creators write the unprefixed form and a guard that knows one spelling is a guard a
  -- second placer walks past. Verified read-only against production 2026-08-09: this exact sweep
  -- returns combat_spawn_wave_units and nothing else.
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'combat_spawn_wave_units'
       and regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') ~ 'insert into (public\.)?combat_units'
       and position('''enemy''' in regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')) > 0) then
    raise exception '0346 ASSERT (b) FAIL: the placement probe does not match combat_spawn_wave_units itself — the sweep below would report "no other placers" while testing nothing';
  end if;
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname <> 'combat_spawn_wave_units'
     and regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') ~ 'insert into (public\.)?combat_units'
     and position('''enemy''' in regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')) > 0;
  if v_n <> 0 then
    raise exception '0346 ASSERT (b) FAIL: % other function(s) in public insert an enemy combat_units row — a second placer is a second origin authority, and this slice moves the origin in exactly one place', v_n;
  end if;

  -- ONE WRITER OF THE INGRESS COUNTDOWN, AND ONE SPENDER. Anything else is a second notion of the
  -- phase, which is how a body ends up half-arrived.
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname not in ('combat_spawn_wave_units', 'process_combat_ticks')
     and position('ingress_ticks_left' in regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')) > 0;
  if v_n <> 0 then
    raise exception '0346 ASSERT (b) FAIL: % other function(s) touch ingress_ticks_left — it is written once, at the spawn, and spent once, in the tick', v_n;
  end if;
end $b$;

-- (c) THE BOUNDARY LEAF IS 0336's RING, EXECUTED — against the real deployed geometry leaves
-- It reads combat_units for the extent; an encounter id that exists nowhere yields no player row, so
-- the extent is 0 and the boundary is exactly (range + 1) out. A real read of a real table, writing
-- nothing.
do $c$
declare
  i integer; k integer; th double precision;
  ax double precision := 12.5; ay double precision := -3.25;
  rng double precision := 4.0;
  nowhere uuid := '00000000-0000-0000-0000-000000000000'::uuid;
  sx double precision; sy double precision;
  v_bx double precision; v_by double precision;
  fx double precision; fy double precision;
  d double precision;
begin
  for i in 0 .. 7 loop
    th := 2 * pi() * i / 8.0 + 0.37;   -- eight bearings, deliberately not axis-aligned
    sx := ax + 137.0 * cos(th);
    sy := ay + 137.0 * sin(th);
    for k in 0 .. 3 loop
      select b.x, b.y into v_bx, v_by
        from public.combat_ingress_boundary(nowhere, ax, ay, sx, sy, rng, k) b;
      if v_bx is null or v_by is null then
        raise exception '0346 ASSERT (c) FAIL: the boundary leaf answered NULL at bearing %, slot % — a body would be placed nowhere', round(th::numeric, 4), k;
      end if;
      -- 1. IT IS 0336'S RADIUS: with an empty formation the extent is 0, so exactly (range + 1).
      d := public.osn_distance(ax, ay, v_bx, v_by);
      if abs(d - (rng + 1)) > 1e-9 then
        raise exception '0346 ASSERT (c) FAIL: bearing %, slot % — the boundary stands % from the anchor, want exactly % (measured extent 0 + its own range + 1). 0336''s clearance is not being reproduced', round(th::numeric, 4), k, d, rng + 1;
      end if;
      -- 2. IT IS THE SAME POINT combat_formation_point PRODUCES on 0338's bearing — value for value.
      --    The leaf must be a relocation of the deployed geometry, not a second version of it.
      select fp.x, fp.y into fx, fy
        from public.combat_formation_point(ax, ay, rng + 1, k,
               public.combat_wave_arrival_phase(ax, ay, sx, sy, k)) fp;
      if v_bx is distinct from fx or v_by is distinct from fy then
        raise exception '0346 ASSERT (c) FAIL: bearing %, slot % — the boundary leaf answered (%,%) but combat_formation_point on the 0338 arrival phase answers (%,%). The leaf must be the deployed geometry relocated, not a rewrite of it', round(th::numeric, 4), k, v_bx, v_by, fx, fy;
      end if;
    end loop;
    -- 3. SLOT 0 LIES ON THE RAY TOWARD THE CITY — the destination still has the city's direction.
    select b.x, b.y into v_bx, v_by
      from public.combat_ingress_boundary(nowhere, ax, ay, sx, sy, rng, 0) b;
    if abs(v_bx - (ax + (rng + 1) * cos(th))) > 1e-9 or abs(v_by - (ay + (rng + 1) * sin(th))) > 1e-9 then
      raise exception '0346 ASSERT (c) FAIL: at bearing % slot 0 landed at (%,%), not on the ray from the anchor toward the city — the destination has lost its direction', round(th::numeric, 4), v_bx, v_by;
    end if;
  end loop;
end $c$;

-- (d) THE INGRESS ARRIVES, EXACTLY, AND NEVER CROSSES — EXECUTED through the REAL mover
-- This is the block that gates "an inbound unit must not skip past the engagement point" and the
-- distance-independence that makes this a duration rather than a speed. It runs the actual
-- recurrence the tick runs: step = distance / remaining, through combat_unit_decide_move with
-- my_range 0 and target_range 0. The boundary is placed at the origin and the body starts on the
-- positive x axis, so "crossed it" is exactly "x went negative" — a signed test, not a distance,
-- because a distance cannot tell an arrival from an overshoot.
do $d$
declare
  budget integer;
  runs   integer := 0;
  d0     double precision;
  px double precision; py double precision;
  nx double precision; ny double precision;
  rem integer; ticks integer; prev double precision; dist double precision;
begin
  budget := coalesce((select (value::text)::double precision from public.game_config
                       where key = 'combat_enemy_ingress_ticks'), 0)::integer;
  if budget < 1 then
    raise exception '0346 ASSERT (d) FAIL: the seeded ingress budget is % — with no ticks to spend there is no ingress to prove, and every body would be placed straight on the boundary', budget;
  end if;
  -- Two cities, orders of magnitude apart: the owner's measured 22.5-unit Snare case, and the
  -- longest ambush corridor the harness actually drives. The SAME budget must land both.
  foreach d0 in array array[22.5::double precision, 619.0::double precision] loop
    px := d0; py := 0;            -- the body starts AT its city, d0 from the boundary at the origin
    rem := budget; ticks := 0; prev := d0;
    while rem > 0 loop
      dist := public.osn_distance(px, py, 0, 0);
      select m.new_x, m.new_y into nx, ny
        from public.combat_unit_decide_move(px, py, 0, dist / greatest(rem, 1), 0, 0, 0) m;
      px := nx; py := ny;
      -- NEVER PAST THE BOUNDARY: a signed test. An overshoot puts x on the far side.
      if px < -1e-9 then
        raise exception '0346 ASSERT (d) FAIL: from % the body overshot the boundary on tick % (x = %) — the step must be clamped by the remaining distance', d0, ticks + 1, px;
      end if;
      dist := public.osn_distance(px, py, 0, 0);
      -- MONOTONE, AND NEVER AWAY.
      if dist > prev + 1e-9 then
        raise exception '0346 ASSERT (d) FAIL: from % the body moved AWAY on tick % (% -> %)', d0, ticks + 1, prev, dist;
      end if;
      prev := dist; rem := rem - 1; ticks := ticks + 1;
    end loop;
    -- ARRIVES EXACTLY, on the last tick of the budget — not near it, and not before it.
    if abs(prev) > 1e-9 then
      raise exception '0346 ASSERT (d) FAIL: from % the body finished % from the boundary after % tick(s) — the final step must land it EXACTLY on the boundary', d0, prev, ticks;
    end if;
    if ticks <> budget then
      raise exception '0346 ASSERT (d) FAIL: from % the ingress took % tick(s), want exactly the seeded budget of %', d0, ticks, budget;
    end if;
    runs := runs + 1;
  end loop;
  -- NON-VACUITY: both distances were actually run. Otherwise "distance-independent" would be
  -- asserting one case twice.
  if runs <> 2 then
    raise exception '0346 ASSERT (d) FAIL: ran % ingress(es), want 2 — the distance-independence claim needs two genuinely different distances', runs;
  end if;
end $d$;

-- (e) THE COLUMNS ARE THE IN-FLIGHT CONTRACT — every fight in progress is provably un-ingressed
do $e$
declare v_n integer;
begin
  select count(*) into v_n from information_schema.columns
   where table_schema = 'public' and table_name = 'combat_units'
     and column_name in ('ingress_ticks_left', 'ingress_slot') and is_nullable = 'YES'
     and column_default is null;
  if v_n <> 2 then
    raise exception '0346 ASSERT (e) FAIL: % of 2 ingress column(s) are present, nullable and default-less. A default would rewrite a live table and would put every existing enemy body into a phase it never entered', v_n;
  end if;
  select count(*) into v_n from public.combat_units
   where ingress_ticks_left is not null or ingress_slot is not null;
  if v_n <> 0 then
    raise exception '0346 ASSERT (e) FAIL: % existing combat_units row(s) already carry ingress state. Every body standing in a fight at this instant must read NULL, i.e. must keep behaving exactly as it does today', v_n;
  end if;
end $e$;

-- (f) THE KNOB EXISTS, MEANS SOMETHING, AND CANNOT SHIP INERT
do $f$
declare v_v jsonb; v_d text; v_n integer;
begin
  select value, description into v_v, v_d from public.game_config where key = 'combat_enemy_ingress_ticks';
  if v_v is null then
    raise exception '0346 ASSERT (f) FAIL: combat_enemy_ingress_ticks was not seeded — the one number that bounds the ingress would live nowhere a designer can find it';
  end if;
  if v_d is null or length(v_d) < 80 then
    raise exception '0346 ASSERT (f) FAIL: the knob carries no written meaning. scripts/list-knobs.mjs reads the description; a knob nobody can find is a knob that does not exist';
  end if;
  if jsonb_typeof(v_v) <> 'number' or (v_v::text)::double precision <= 0 then
    raise exception '0346 ASSERT (f) FAIL: combat_enemy_ingress_ticks is %, which places every body straight on the engagement boundary — exactly the behaviour the owner has rejected twice, shipped inert', v_v::text;
  end if;
  -- NOTHING DARK: there is no flag for this slice, and its absence is asserted rather than promised.
  select count(*) into v_n from public.game_config
   where key in ('enemies_come_from_the_city_enabled', 'combat_city_origin_enabled', 'combat_ingress_enabled');
  if v_n <> 0 then
    raise exception '0346 ASSERT (f) FAIL: % gate-shaped key(s) exist for this slice. Nothing here is behind a flag — a capability the owner cannot see is worthless to them, and a flag nobody flips is a second dead path', v_n;
  end if;
end $f$;

-- (g) metadata parity: both rewritten functions changed their BODY and nothing else
do $g$
declare r record; v_n integer := 0;
begin
  for r in
    select b.fname, b.body_md5 as old_md5, md5(p.prosrc) as new_md5,
           b.owner as old_owner, pg_get_userbyid(p.proowner) as new_owner,
           b.secdef as old_secdef, p.prosecdef as new_secdef,
           b.volatility as old_vol, p.provolatile as new_vol,
           b.parallel as old_par, p.proparallel as new_par,
           b.proconfig as old_cfg, coalesce(array_to_string(p.proconfig, ','), '') as new_cfg,
           b.args as old_args, pg_get_function_identity_arguments(p.oid) as new_args,
           b.result as old_result, pg_get_function_result(p.oid) as new_result,
           b.acl as old_acl, coalesce(p.proacl::text, '') as new_acl
      from _0346_before b
      join pg_proc p on p.proname = b.fname
      join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
  loop
    v_n := v_n + 1;
    if r.old_md5 = r.new_md5 then
      raise exception '0346 ASSERT (g) FAIL: public.% is byte-identical to before the surgery — its hunks did not land', r.fname;
    end if;
    if r.old_owner is distinct from r.new_owner or r.old_secdef is distinct from r.new_secdef
       or r.old_vol is distinct from r.new_vol or r.old_par is distinct from r.new_par
       or r.old_cfg is distinct from r.new_cfg or r.old_args is distinct from r.new_args
       or r.old_result is distinct from r.new_result or r.old_acl is distinct from r.new_acl then
      raise exception '0346 ASSERT (g) FAIL: public.% changed more than its body (owner %/%, secdef %/%, volatility %/%, parallel %/%, config %/%, args %/%, result %/%, acl %/%)',
        r.fname, r.old_owner, r.new_owner, r.old_secdef, r.new_secdef, r.old_vol, r.new_vol,
        r.old_par, r.new_par, r.old_cfg, r.new_cfg, r.old_args, r.new_args,
        r.old_result, r.new_result, r.old_acl, r.new_acl;
    end if;
  end loop;
  if v_n <> 2 then
    raise exception '0346 ASSERT (g) FAIL: compared % function(s), want 2 (process_combat_ticks and combat_spawn_wave_units)', v_n;
  end if;
end $g$;

commit;
