-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0347 — THE FIELD GROWS
--        (every third SCHEDULED reinforcement slot raises the site's concurrent cap by one body)
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- ── THE OWNER ───────────────────────────────────────────────────────────────────────────────────
--     "every 3 wave, i want wave to add one fleet"
-- and, when the consequence for the cap was put to him:
--     "yes, cap should grow. go ahead"
--
-- 0344 made pressure a CLOCK: public.combat_pressure_step fires on a due slot and spawns exactly ONE
-- body while the field is under its site's concurrent cap; a suppressed slot is LOST, never banked;
-- and there is NO arrow from an enemy death back into pressure. All three survive this migration
-- untouched. What changes is one number: the cap the clock measures the field against is no longer
-- the site row's constant. It is
--
--     effective_cap = base_cap + floor(pressure_wave_index / cap_growth_every)
--
-- where pressure_wave_index is THE SCHEDULED ORDINAL — how many reinforcement slots have come due at
-- this fight — and cap_growth_every is a column on the site's own content row, seeded 3.
--
-- ── ██ THE TRAP THIS FILE EXISTS TO AVOID, AND IT WAS THE FIRST DESIGN ██ ───────────────────────
-- The obvious counter is "how many bodies have ARRIVED". It is wrong, and it is wrong in exactly the
-- way the owner has now rejected three times. Follow it on a full field:
--
--     at cap -> no arrival -> the counter cannot reach the next increase -> nothing changes until
--     AN ENEMY DIES and frees a slot -> an arrival happens -> the counter moves -> the cap grows.
--
-- That is an indirect arrow from a death back into pressure, re-created inside the very number that
-- was supposed to be independent of it. An arrival-driven counter makes killing well the thing that
-- unlocks a bigger field, which is [PR #397] wearing a third costume.
--
-- SO THE COUNTER COUNTS SLOTS, NOT BODIES. It advances on EVERY scheduled slot, whether or not a
-- body spawned, and it is advanced by the same arithmetic — and in the same statement — that moves
-- the clock. A suppressed slot still spends its ordinal. The worked example the owner was shown, on
-- a site whose base cap is 3 and whose field is full, is the behaviour this file reproduces:
--
--     slot 1 -> cap 3 -> suppressed        slot 4 -> cap 4 -> suppressed
--     slot 2 -> cap 3 -> suppressed        slot 5 -> cap 4 -> suppressed
--     slot 3 -> cap 4 -> SPAWNS            slot 6 -> cap 5 -> SPAWNS
--
-- After six slots the counter reads 6 and exactly TWO bodies have arrived. An arrival-driven counter
-- would read 2 and the cap would still be 3. That gap is not cosmetic — it is the whole difference
-- between a clock and a kill ladder — and DZCOMBAT_PASS_FIELDGROWS asserts it as a number.
--
-- THE NAME IS DELIBERATE. It is `pressure_wave_index`, NOT `arrivals` and NOT `waves_cleared`.
-- combat_encounters.waves_cleared still exists and is still written by the tick, but 0344 deleted its
-- authority over anything; nothing in this slice reads it, and self-assert (c) fails the deploy if
-- either the authority or the step ever names it again.
--
-- ── WHERE ONE SLOT'S ORDINAL COMES FROM WHEN THE CLOCK SKIPS ────────────────────────────────────
-- 0344's RULE 2 is that a stalled clock skips past EVERY elapsed slot in ONE step and owes nothing.
-- The ordinal advances by exactly that same count — `slots_due` — so the two can never disagree:
-- they are one quantity, computed once, written by one UPDATE. A cron stall that swallows five slots
-- therefore advances the ordinal by five and delivers ONE body, which is the honest reading of "five
-- slots came and went". It is stated here rather than left to be discovered, because it is the one
-- place the ordinal moves faster than the number of ticks.
--
-- ── ⚠ THE CEILING IS UNBOUNDED TODAY. THAT IS A DECISION, AND IT IS VISIBLE ─────────────────────
-- base_cap + floor(index / 3) grows without limit, and the fight is deliberately endless — the
-- owner's standing law is "the whole point of this game is never to win, but exit appropriately".
-- So this ships UNBOUNDED, and `location_pressure.cap_ceiling` is seeded NULL at every site.
--
-- IT IS A DATA ROW, NOT A MISSING FEATURE. Capping a site later is one UPDATE and no deploy:
--     update public.location_pressure set cap_ceiling = 12 where location_id = <site>;
-- The apply raises a NOTICE naming every site and its ceiling, so the deploy log records the
-- unbounded state rather than burying it. What is NOT done here is inventing a number the owner has
-- not ruled on: a silent hardcoded ceiling would be a balance decision smuggled in as an
-- implementation detail, and a ceiling nobody can find is the same thing as no ceiling (0320's
-- finding, from the other direction).
--
-- ── THE STEP IS A PERIOD, NOT A STEP SIZE, AND THAT IS ONE AXIS ON PURPOSE ──────────────────────
-- The owner said "one fleet" every three waves. There is a `cap_growth_every` column and there is NO
-- `cap_growth_step` column, because a step of k is the same axis as a period of every/k: two bodies
-- per three slots IS one body per 1.5 slots. A second column would be a second spelling of one
-- design decision, which is how a knob nobody can reconcile gets born.
--
-- ── ONE AUTHORITY FOR "HOW BIG CAN THIS FIELD GET", AND THE UI DOES NOT RECOMPUTE IT ────────────
-- Before this migration NOTHING exposed the cap to the client — verified by grep over src/**, not
-- assumed: no client module names location_pressure or concurrent_cap. A wave-timer readout is being
-- built in a separate slice and it must show the EFFECTIVE cap, or it will say "3 max" while four
-- ships stand on the field. So this file establishes the read path as part of the same slice:
--
--   public.combat_pressure_field(p_encounter) is minted as THE leaf that answers "what is this
--   fight's site, cap, ordinal, population and next slot". It computes the effective cap ONCE.
--   * public.combat_pressure_step COMPOSES it — the spawn decision no longer reads the site row at
--     all, and self-assert (b) fails the deploy if it ever names concurrent_cap or cap_growth_every.
--   * The step STAMPS the leaf's own answer onto combat_encounters.pressure_effective_cap, in the
--     SAME statement that advances the clock and the ordinal. That column is a PROJECTION, never an
--     input: nothing reads it back, and self-assert (c) proves exactly one function writes it.
--   * The client already selects combat_encounters with `select('*')` under the owner-scoped RLS
--     policy combat_encounters_select_own (0014), so the readout slice reads the effective cap, the
--     ordinal and next_reinforcement_at off a row it already has — no new RPC, no new grant, no
--     client-side arithmetic. Self-assert (h) asserts that column-level SELECT reachability rather
--     than assuming it.
--
-- THE SHAPE IS THE CONCURRENT SLICE'S, NOT A COMPETING ONE. That slice specced
-- combat_pressure_field(p_encounter) as a read-only leaf returning (authored, cadence, cap, …,
-- population, arriving) and intended to repoint combat_pressure_step onto it. This file mints
-- exactly that leaf, with those column names, and does the repointing — so that slice COMPOSES this
-- one instead of duplicating it. The one naming departure is stated so it cannot be mistaken: the
-- spec's `cap` is returned as TWO columns, `base_cap` and `effective_cap`, because a single column
-- named `cap` that silently means one or the other is precisely the "3 max while 4 stand" defect in
-- the type system. `effective_cap` IS the cap the spawn decision uses and the cap the UI must show.
--
-- THE ENEMY BAR ALREADY CARRIED THE CAP, AND IT IS FIXED HERE TOO. 0344 made
-- combat_encounters.enemy_integrity_max the SITE'S CEILING — cap x one body's nominal hp — precisely
-- so the client's enemy bar reads "how full is the field". It is fed from this authority's
-- o_ceiling_hp (measured on the deployed tick: `enemy_integrity_max = v_enemy_hp` on both arms). If
-- the ceiling kept using the BASE cap, a grown field would drive that bar past 100%. o_ceiling_hp is
-- therefore computed from the EFFECTIVE cap, and the proof asserts the bar's denominator moves with
-- the cap on the very slot the cap grows.
--
-- ── PARITY: THE TICK IS NOT TOUCHED AT ALL ─────────────────────────────────────────────────────
-- process_combat_ticks is ~1,400 lines, no file holds it whole, and eleven generators (scripts/
-- gen-0314, -0315, -0316, -0317, -0319, -0331, -0332, -0333, -0336, -0337, -0339) each assert that
-- 0299 is still the newest TEXTUAL re-create of it. 0343 wrote a full re-emission first and broke all
-- eleven at once. This file contains NO `create or replace` of public.process_combat_ticks — the
-- phrase is deliberately not written here as one literal string, so a grep for it over the migrations
-- directory keeps meaning what it means — and no surgery on it either — everything this slice changes lives inside the LEAF the tick already
-- composes, at the same signature and with the same three OUT parameters, so the tick's two call
-- sites are byte-identical before and after. Self-assert (f) captures md5(prosrc) of the tick before
-- the first DDL statement and requires it UNCHANGED afterwards, which is a stronger statement than
-- "no re-create appears in this file" because it also catches a re-create arriving by any other route.
--
-- ── WHICH BODY EACH NEEDLE TARGETS, STATED EXPLICITLY ───────────────────────────────────────────
-- 0346 is on this branch and is NOT deployed (production head verified read-only 2026-08-09:
-- 20260618000344). Migrations apply in order, so the body this file is handed is the body as 0346
-- leaves it. Every count below was MEASURED, not reasoned:
--
--   needle                                                    body        want   measured
--   combat_pressure_step(                                     TICK@0346     2     2 on P0344 *
--   public.combat_pressure_step(e.id, v_tick, … v_log_events) TICK@0346     2     2 on P0344 *
--   ingress_ticks_left                                        TICK@0346   present 0 on P0344 **
--   coalesce(e.next_reinforcement_at, e.started_at)           LEAF@0344     1     1
--   public.combat_spawn_wave_units(                           LEAF@0344     1     1
--   loop                                                      LEAF@0344     0     0
--   s.cadence * (v_missed + 1)                                LEAF@0344     1     1
--   everything in (a)-(h) that reads combat_pressure_field    THIS FILE   this file's own bytes
--
--   *  Measured on production's tick (P0344, prosrc md5 63495b69bb5a481fbf065f4b067c55a1, 87,646
--      chars, comment-stripped 41,716). 0346's SIX hunks are [S1][S2] inside combat_spawn_wave_units
--      and [T1] the declare block, [T2] the frozen snapshot, [T3] the movement decision and [T4] the
--      position write inside the tick. NONE of the four tick hunks contains the string
--      "combat_pressure_step" in either its pre-image or its replacement — checked against 0346's own
--      VALUES list, character by character — so the count is 2 in the P0344 body AND in the P0346
--      body this file actually meets.
--   ** This is the needle that PROVES the base. `ingress_ticks_left` is absent from P0344 (measured:
--      position = 0 on production) and present in P0346 ([T2] and [T4] both write it). Requiring it
--      present is what makes "applied on top of 0346" an assertion instead of an assumption.
--
-- THE LEAF'S PRE-IMAGE IS NOT SENSITIVE TO A CHAIN-VS-PRODUCTION DIFFERENCE, and that was checked
-- rather than hoped: public.combat_pressure_step is created WHOLE by 0344, in one dollar-quoted
-- block, so its prosrc is that file's own bytes in every environment. Measured both ways today —
-- production's deployed prosrc md5 = b83ee01752dea16e3ee2d22525e57594 / 4,787 chars, and the md5 of
-- that function's dollar-quoted body as it stands in this repository's own git blob of
-- 20260618000344_killing_well_is_not_punished.sql = b83ee01752dea16e3ee2d22525e57594 / 4,787 chars.
-- They are the same. The md5 is nevertheless raised as a NOTICE rather than asserted, following the
-- rule 0343 and 0346 set: 0345 is reserved by another slice and may legitimately re-emit this leaf
-- before this file runs, and a hard md5 gate would then hold the whole chain hostage over a
-- difference that does not affect this rewrite. What IS hard-asserted is what must be true of the
-- body whatever wrote it: it is the 0344 CLOCK (it reads coalesce(next_reinforcement_at, started_at)
-- exactly once), it composes the one spawner exactly once, and it contains no loop.
--
-- ── IN-FLIGHT ENCOUNTERS: PRODUCTION IS A LIVE ~30-PLAYER GAME ──────────────────────────────────
-- Every fight running at the instant this applies has a history and no ordinal. THE ORDINAL STARTS
-- AT ZERO FOR ALL OF THEM, and that is a decision, not a default that happened:
--   * `pressure_wave_index integer NOT NULL DEFAULT 0` is a catalog-only ALTER on PostgreSQL 11+
--     (a non-volatile default is not a table rewrite), so every existing row reads 0 immediately and
--     there is NO state the clock cannot resolve — the column can never be NULL, at any age of row,
--     so no coalesce is needed anywhere and none is written.
--   * The alternative — DERIVING the ordinal from elapsed time or from how far
--     next_reinforcement_at has already been advanced — is REJECTED explicitly. 0344's own backfill
--     stamped in-flight encounters with `now() + cadence`, which is not on the started_at lattice, so
--     any such derivation would be arithmetic over an incomparable value; and even where it did
--     divide cleanly it would hand a long-running fight an instant cap jump for slots that happened
--     under rules that had no cap growth in them. A fight in progress gets its first cap increase on
--     its THIRD slot after this deploys, exactly like a fight that starts a minute later.
--   * `pressure_effective_cap` is a stamp and is therefore NULL until a slot is evaluated. SECTION 5
--     backfills every non-terminal encounter at an authored site BY CALLING THE AUTHORITY — not by
--     re-deriving the number in SQL — so the readout has a value from the first moment and there is
--     still exactly one place the cap is computed. A fresh fight stamps on its own first tick, since
--     0344 makes its first slot due at started_at.
--   * A site with no location_pressure row is unchanged: the authority returns authored=false, the
--     step returns without spawning and without writing anything, and the stamp stays NULL. Fail
--     closed, exactly as 0344 left it.
-- Everything is created in ONE transaction, so the tick never names a function that does not exist.
-- A cron pass already executing finishes on the old leaf and resolves its encounter completely.
--
-- ── ROLLBACK BOUNDARY ───────────────────────────────────────────────────────────────────────────
-- Four objects. In one transaction, in this order:
--   1. Re-run the `create or replace function public.combat_pressure_step` block from
--      supabase/migrations/20260618000344_killing_well_is_not_punished.sql:879-993, verbatim. THAT IS
--      THE COMPLETE PRE-IMAGE and it is held WHOLE in one file — which is why 0344's rule against
--      restoring from an older migration file (the rule that exists because no file holds the TICK
--      whole, and copying an old fragment reverted its mode line three times) does not apply to this
--      leaf. Its md5 is recorded above, so the restore is verifiable rather than trusted.
--   2. `drop function public.combat_pressure_field(uuid);`
--   3. `alter table public.location_pressure drop column cap_growth_every, drop column cap_ceiling;`
--      Safe only after step 1 has removed the reader.
--   4. OPTIONAL: `alter table public.combat_encounters drop column pressure_wave_index, drop column
--      pressure_effective_cap;` — safe to LEAVE, because after step 1 nothing writes them and nothing
--      reads them, and dropping a column a re-applied 0347 would need buys nothing on a live game.
-- The drops must not precede step 1. Rolling back deletes no enemy row, disturbs no haul, and
-- changes no player-visible state other than the cap returning to its site constant. There is NO
-- config value that switches the growth off, and that is deliberate: a knob that could is the
-- adapter this project has a law against.
--
-- ── NOTHING DARK ────────────────────────────────────────────────────────────────────────────────
-- No feature flag, and this slice creates NO game_config key at all — asserted ABSENT in (e), not
-- promised. The two thresholds are COLUMNS on the site's own content row, seeded live at every
-- active hunting ground, and (e) fails the deploy if any active pirate-hunt site is left without the
-- growth authored. The way this could have shipped invisible is a NULL growth period, so that is the
-- state the assert forbids on real content.
--
-- ── SELF-ASSERT MAP (one DO block per check — the statement number IS the diagnosis) ────────────
--   (a) the leaf exists, is STABLE + SECURITY DEFINER + pinned search_path, and NO client role can
--       execute it
--   (b) ONE AUTHORITY FOR THE CAP: the step composes the leaf exactly once and names neither
--       concurrent_cap nor cap_growth_every itself; exactly one function in public names
--       cap_growth_every and it is the leaf
--   (c) THE COUNTER IS CLOCK-DRIVEN AND CANNOT BE KILL-DERIVED: the ordinal is assigned in exactly
--       ONE place, from the stored ordinal plus the CLOCK's slot count; the leaf and the step name
--       waves_cleared / wave_number / danger / arrivals / o_arrived ZERO times; the step writes
--       pressure_wave_index exactly once and writes the LEAF's value; exactly one function in public
--       writes the ordinal and exactly one writes the stamp
--   (d) THE CAP IS NOT HARDCODED: the growth divisor is the site row's own column, the growth
--       expression occurs exactly once, and no literal divisor appears in the leaf
--   (e) NOTHING DARK: no game_config key for this slice, and every ACTIVE pirate-hunt site carries an
--       authored growth period (over at least the three seeded sites, so the sweep cannot pass over
--       an empty set)
--   (f) THE TICK IS UNTOUCHED: md5(prosrc) of process_combat_ticks is identical before and after,
--       and it still composes the authority exactly twice
--   (g) THE IN-FLIGHT CONTRACT: the ordinal column is NOT NULL with default 0 and no row carries a
--       NULL ordinal, so no fight can land in a state the clock cannot resolve
--   (h) THE READOUT CONTRACT: `authenticated` can SELECT both new columns of combat_encounters (that
--       is how the wave-timer readout gets the EFFECTIVE cap without recomputing it), while
--       location_pressure keeps 0344's client-write lockdown. (h) also RECORDS, without asserting, a
--       pre-existing finding: production's combat_encounters still carries Supabase's project-default
--       client INSERT/UPDATE grant from 0014 — inert behind RLS, three hundred migrations older than
--       this slice, and not this slice's to revoke. The block says why in full.
--
-- WHAT THE SELF-ASSERT CANNOT DO, STATED RATHER THAN IMPLIED. These are STRUCTURAL. They prove the
-- counter is the clock's and that one place computes the cap. They CANNOT prove that six slots on a
-- full field yield the owner's 3,3,4,4,4,5 — only a real fight can, and that is
-- DZCOMBAT_PASS_FIELDGROWS on the disposable-Postgres leg, which is the only real gate.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';


-- ── 0. PRECONDITIONS (read-only) — refuse to build on a base we did not slice from ──────────────
do $pre$
declare
  v_traw text;
  v_tick text;
  v_tdef text;
  v_lraw text;
  v_leaf text;
  v_n    integer;
begin
  select p.prosrc, pg_get_functiondef(p.oid) into v_traw, v_tdef
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if v_traw is null then
    raise exception '0347 PRECONDITION FAIL: public.process_combat_ticks does not exist';
  end if;
  v_tick := regexp_replace(v_traw, '--[^' || chr(10) || ']*', '', 'g');
  -- The stripper must have removed something and must have left a body. BOTH directions, because a
  -- broken strip makes every count below meaningless in a way that reads as success (the 0222 trap).
  if length(v_tick) < 40000 or length(v_tick) >= length(v_traw) then
    raise exception '0347 PRECONDITION FAIL: the comment strip produced % chars from a % char tick body — every count below would be measured against nothing', length(v_tick), length(v_traw);
  end if;

  -- 0344 IS APPLIED: the tick asks the pressure authority, twice, in the shape 0344 wrote. Counted
  -- with a LADDER — the broad call form and the full-argument form must agree at 2 — so a third call
  -- in a different shape moves one count and not the other, and this aborts.
  v_n := (length(v_tick) - length(replace(v_tick, 'combat_pressure_step(', ''))) / length('combat_pressure_step(');
  if v_n <> 2 then
    raise exception '0347 PRECONDITION FAIL: the tick composes combat_pressure_step % time(s) (want exactly 2 — one per arm). Either 0344 is not applied to this body, or a third caller has appeared and there is more than one place another enemy can come from', v_n;
  end if;
  v_n := (length(v_tick) - length(replace(v_tick, 'public.combat_pressure_step(e.id, v_tick, v_anchor_x, v_anchor_y, loc.x, loc.y, v_seq, v_log_events)', '')))
         / length('public.combat_pressure_step(e.id, v_tick, v_anchor_x, v_anchor_y, loc.x, loc.y, v_seq, v_log_events)');
  if v_n <> 2 then
    raise exception '0347 PRECONDITION FAIL: % of the tick''s calls to the pressure authority pass 0344''s arguments (want 2). This slice keeps the authority''s SIGNATURE byte-identical precisely so the tick is not touched; a call in another shape means that assumption is already false', v_n;
  end if;

  -- 0346 IS APPLIED: this is the base this slice was cut from. `ingress_ticks_left` is ABSENT from
  -- the 0344 body (measured on production, position = 0) and PRESENT in the 0346 body ([T2] and [T4]
  -- both name it), so this is the needle that turns "applied on top of 0346" into an assertion.
  if position('ingress_ticks_left' in v_traw) = 0 then
    raise exception '0347 PRECONDITION FAIL: the deployed tick does not carry 0346''s ingress phase — this migration is being applied to a body older than the one it was sliced against. Do not apply this out of order';
  end if;

  -- THE AUTHORITY IS THE ONE 0344 MINTED, AT ITS EXACT SIGNATURE, AND THERE IS ONLY ONE OF IT.
  if to_regprocedure('public.combat_pressure_step(uuid, integer, double precision, double precision, double precision, double precision, integer, boolean)') is null then
    raise exception '0347 PRECONDITION FAIL: public.combat_pressure_step is missing at its 0344 signature — this slice re-emits exactly that function and will not create a second one beside it';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'combat_pressure_step') <> 1 then
    raise exception '0347 PRECONDITION FAIL: public.combat_pressure_step is overloaded — there must be exactly ONE pressure authority and this slice refuses to guess which';
  end if;
  select p.prosrc into v_lraw from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_pressure_step';
  v_leaf := regexp_replace(v_lraw, '--[^' || chr(10) || ']*', '', 'g');
  if length(v_leaf) < 1500 or length(v_leaf) >= length(v_lraw) then
    raise exception '0347 PRECONDITION FAIL: the comment strip produced % chars from a % char authority body', length(v_leaf), length(v_lraw);
  end if;

  -- IT IS A CLOCK, IN THE SHAPE 0344 WROTE. Three specific, single-concept needles rather than an
  -- md5, so a legitimate earlier re-emission (0345 is reserved by another slice) does not hold the
  -- chain hostage while a body that is NOT the clock still aborts.
  v_n := (length(v_leaf) - length(replace(v_leaf, 'coalesce(e.next_reinforcement_at, e.started_at)', '')))
         / length('coalesce(e.next_reinforcement_at, e.started_at)');
  if v_n <> 1 then
    raise exception '0347 PRECONDITION FAIL: the authority reads the unstamped-row clock % time(s) (want exactly 1). This slice keeps 0344''s clock exactly as it is and changes only the cap it measures the field against — a body without that read is not the body this was written for', v_n;
  end if;
  v_n := (length(v_leaf) - length(replace(v_leaf, 'public.combat_spawn_wave_units(', ''))) / length('public.combat_spawn_wave_units(');
  if v_n <> 1 then
    raise exception '0347 PRECONDITION FAIL: the authority composes the sole enemy-row inserter % time(s) (want exactly 1)', v_n;
  end if;
  v_n := (length(v_leaf) - length(replace(v_leaf, 'loop', ''))) / length('loop');
  if v_n <> 0 then
    raise exception '0347 PRECONDITION FAIL: the authority already contains % loop token(s) (want 0) — a loop is how BANKING is written, and 0344''s RULE 2 forbids it. The body has drifted', v_n;
  end if;

  -- NOTHING THIS SLICE MINTS MAY ALREADY EXIST.
  if to_regproc('public.combat_pressure_field') is not null then
    raise exception '0347 PRECONDITION FAIL: public.combat_pressure_field already exists. This slice MINTS it, at the shape the concurrent readout slice specced. If that slice landed first, reconcile the two by hand — do not let two files create one authority';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'location_pressure'
                and column_name in ('cap_growth_every', 'cap_ceiling')) then
    raise exception '0347 PRECONDITION FAIL: public.location_pressure already carries a cap-growth column — this slice adds both, and adding one twice would leave two notions of the same threshold';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'combat_encounters'
                and column_name in ('pressure_wave_index', 'pressure_effective_cap')) then
    raise exception '0347 PRECONDITION FAIL: public.combat_encounters already carries a pressure ordinal or stamp column — this migration has already been applied';
  end if;
  if to_regclass('public.location_pressure') is null then
    raise exception '0347 PRECONDITION FAIL: public.location_pressure does not exist — 0344 is not applied and there is no site content to grow';
  end if;

  raise notice '0347 parity source: production, read-only 2026-08-09, head 20260618000344. RECORDED combat_pressure_step prosrc md5 = b83ee01752dea16e3ee2d22525e57594 / 4787 chars (identical to the md5 of that function''s dollar-quoted body in this repo''s own 0344 blob). OBSERVED here: authority prosrc md5 = % / % chars; tick prosrc md5 = % / % chars (functiondef md5 = % / % chars). A difference is a REVIEW SIGNAL, not a failure — 0345 is reserved by another slice and may re-emit the authority before this runs, and this rewrite does not depend on byte equality. What is hard-asserted is what must be true: it is a clock, it composes one spawner, and it contains no loop.',
    md5(v_lraw), length(v_lraw), md5(v_traw), length(v_traw), md5(v_tdef), length(v_tdef);
end $pre$;


-- ── 1. CAPTURE THE TICK'S FINGERPRINT BEFORE ANY DDL (for parity check (f)) ─────────────────────
-- Taken BEFORE the first DDL statement so the comparison in (f) spans everything this file does.
create temp table _0347_tick_before (fname text primary key, body_md5 text, body_len integer)
  on commit drop;
insert into _0347_tick_before
select p.proname, md5(p.prosrc), length(p.prosrc)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'process_combat_ticks';


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 1 — THE THRESHOLDS ARE COLUMNS ON THE SITE'S OWN CONTENT ROW
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0344 made cadence and cap ROWS rather than a formula over base_difficulty, on the argument that
-- deriving them would make base_difficulty a fourth overloaded authority. The growth period and the
-- ceiling belong on the same row for the same reason: authoring a hunting ground stays an INSERT,
-- and retuning one stays an UPDATE with no deploy.
--
-- BOTH ARE NULLABLE, AND EACH NULL MEANS EXACTLY ONE THING:
--   cap_growth_every NULL -> this site's cap does NOT grow (0344's behaviour, value for value)
--   cap_ceiling      NULL -> the growth is UNBOUNDED (today, at every site — see the header)
-- `cap_growth_every` carries DEFAULT 3, which on PostgreSQL 11+ is a catalog-only ALTER that fills
-- every existing row with 3 without a rewrite. So the owner's rule is LIVE at every authored site
-- the instant this commits, and assert (e) fails the deploy if any active pirate-hunt site is left
-- without it — that is what makes "nothing dark" checkable rather than promised.
--
-- WHY NULL-MEANS-FIXED EXISTS AT ALL, since every real site carries 3: the proof harness needs to
-- state its own precondition. scripts/lib/pressure-staging.sql's pg_temp.pressure_site sets it NULL,
-- so every block that is about the CAP keeps measuring the cap and only the block that is about the
-- GROWTH turns the growth on and says so. A proof that inherits an ambient default is asserting a
-- world rather than a property, and this repository has paid for that lesson repeatedly.
alter table public.location_pressure
  add column cap_growth_every integer default 3,
  add column cap_ceiling      integer;

alter table public.location_pressure
  add constraint location_pressure_cap_growth_every_positive
    check (cap_growth_every is null or cap_growth_every >= 1),
  add constraint location_pressure_cap_ceiling_not_below_base
    check (cap_ceiling is null or cap_ceiling >= concurrent_cap);

comment on column public.location_pressure.cap_growth_every is
  '0347: how many SCHEDULED reinforcement slots this site takes to admit one more concurrent body. The owner: "every 3 wave, i want wave to add one fleet". effective_cap = concurrent_cap + floor(combat_encounters.pressure_wave_index / this). NULL means the cap does not grow, which is 0344''s behaviour value for value; every authored site carries 3 and self-assert (e) of 0347 fails the deploy if an active pirate-hunt site does not. There is deliberately NO step-size column: a step of k is the same axis as a period of every/k.';
comment on column public.location_pressure.cap_ceiling is
  '0347: the largest effective_cap this site will ever reach. NULL means UNBOUNDED, which is what every site carries today — the fight is endless by design ("the whole point of this game is never to win, but exit appropriately") and the owner has not ruled on a ceiling. It is a row so that ruling is one UPDATE and no deploy. CHECK forbids a ceiling below concurrent_cap, so setting one can never shrink a site below its own authored floor.';

-- THE UNBOUNDED STATE IS RECORDED IN THE DEPLOY LOG, not buried. A human reading the apply output
-- sees every site, its base cap, its growth period and its ceiling.
do $ceil$
declare r record;
begin
  for r in
    select l.name, l.status, lp.concurrent_cap, lp.cap_growth_every, lp.cap_ceiling
      from public.location_pressure lp join public.locations l on l.id = lp.location_id
     order by l.name
  loop
    raise notice '0347 pressure content: % (%) base cap %, +1 body every % slot(s), ceiling %',
      r.name, r.status, r.concurrent_cap, coalesce(r.cap_growth_every::text, 'NEVER'),
      coalesce(r.cap_ceiling::text, 'UNBOUNDED (no ruling; set location_pressure.cap_ceiling to bound it — one UPDATE, no deploy)');
  end loop;
end $ceil$;


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 2 — THE SCHEDULED ORDINAL, AND THE CLIENT-VISIBLE PROJECTION OF THE CAP
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- ONE WRITER for both: public.combat_pressure_step, in the same UPDATE that advances the clock.
-- Assert (c) proves that by sweeping pg_proc, not by asking anyone to believe this comment.
--
-- NOT NULL DEFAULT 0 on the ordinal is the in-flight contract. It is catalog-only on PostgreSQL 11+,
-- every row that predates this commit reads 0, and because the column can never be NULL there is no
-- coalesce anywhere and no fight can be handed to a clock that cannot resolve it.
alter table public.combat_encounters
  add column pressure_wave_index    integer not null default 0,
  add column pressure_effective_cap integer;

comment on column public.combat_encounters.pressure_wave_index is
  '0347: how many SCHEDULED reinforcement slots have come due at this fight — the clock''s own ordinal, advanced by public.combat_pressure_step (its sole writer) on EVERY slot whether or not a body arrived, by exactly the number of slots the clock skipped. It is NOT a count of arrivals and NOT waves_cleared: an arrival-driven counter cannot advance while the field is at its cap, so it would only move again when an enemy DIED — the arrow from a death back into pressure that 0344 deleted. Starts at 0 for every fight, including those already in flight when 0347 applied.';
comment on column public.combat_encounters.pressure_effective_cap is
  '0347: how many enemy bodies this fight''s field can hold RIGHT NOW — concurrent_cap + floor(pressure_wave_index / cap_growth_every), bounded by cap_ceiling when one is set. A STAMP, not an input: it is computed by public.combat_pressure_field and written by public.combat_pressure_step in the same statement that makes the spawn decision, and nothing reads it back. It exists so a client surface can SHOW the effective cap without recomputing it — combat_encounters is already client-readable under combat_encounters_select_own (0014). NULL only before this fight has evaluated its first slot.';


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 3 — combat_pressure_field: THE ONE PLACE "HOW BIG CAN THIS FIELD GET" IS DECIDED
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- Read-only. It writes nothing, spawns nothing and advances nothing — it ANSWERS. Every number the
-- pressure decision needs comes out of here in one row, so the engine and any surface that shows the
-- fight are looking at one computation rather than two that agree today.
--
-- THE SHAPE IS THE CONCURRENT READOUT SLICE'S SPEC (authored, cadence, cap, …, population,
-- arriving), so that slice composes this instead of minting a rival. `cap` is returned as base_cap
-- AND effective_cap on purpose: one column called `cap` that silently means the base is exactly the
-- "3 max while four ships stand" defect, encoded in the return type.
--
-- THE ORDINAL IS COMPUTED HERE AND NOWHERE ELSE. `wave_index` is the STORED ordinal plus `slots_due`
-- — the number of scheduled slots that have come due — and `slots_due` is a pure function of the
-- clock. Nothing in this body reads a death, a kill, an arrival, a wave counter or an elapsed
-- presence, and assert (c) reads the body back to prove it.
--
-- STABLE, not IMMUTABLE and not VOLATILE: it reads combat_encounters, location_pressure, locations,
-- combat_units and game_config (through cfg_num, which is itself STABLE — checked on the deployed
-- catalog, not assumed) and it writes nothing. SECURITY DEFINER because location_pressure carries
-- RLS with no policy at all, and revoked from every client role below: it is an engine internal, and
-- the client's view of the cap is the STAMP on its own encounter row, not this function.
create or replace function public.combat_pressure_field(p_encounter uuid)
returns table(
  authored        boolean,
  cadence         double precision,
  base_cap        integer,
  growth_every    integer,
  cap_ceiling     integer,
  wave_index      integer,
  effective_cap   integer,
  unit_type_id    text,
  base_difficulty double precision,
  body_hp_nominal double precision,
  ceiling_hp      double precision,
  bodied          boolean,
  population      integer,
  due_at          timestamptz,
  slots_due       integer,
  arriving        boolean)
language plpgsql
stable
security definer
set search_path to 'public'
as $cpf$
declare
  e combat_encounters%rowtype;
  s record;
begin
  -- THE UNAUTHORED ANSWER, STATED FIRST. Every column has a value before any read happens, so the
  -- "this site hosts no reinforcements" row is a real row rather than a set of NULLs a caller has to
  -- interpret. authored=false is the ONLY signal a caller needs to check.
  authored        := false;
  cadence         := null;
  base_cap        := null;
  growth_every    := null;
  cap_ceiling     := null;
  wave_index      := 0;
  effective_cap   := null;
  unit_type_id    := null;
  base_difficulty := null;
  body_hp_nominal := 0;
  ceiling_hp      := 0;
  bodied          := false;
  population      := 0;
  due_at          := null;
  slots_due       := 0;
  arriving        := false;

  if p_encounter is null then
    raise exception 'combat_pressure_field: called with a null encounter — answering for "no fight in particular" would report a cap that belongs to nobody, so this fails loudly instead';
  end if;
  -- Keyed on the primary key, so this reads one row or none. It is never a scan whose first row
  -- happens to answer.
  select * into e from public.combat_encounters ce where ce.id = p_encounter;
  if not found then
    raise exception 'combat_pressure_field: encounter % does not exist — its caller is iterating a row that is gone', p_encounter;
  end if;

  -- THE SITE. One read, one row, and it is the only content this function has. Every field is
  -- aliased with an r_ prefix so no record member can be confused with an OUT parameter of the same
  -- name — plpgsql resolves those by error, and an error here would be a deploy-time abort in a
  -- function nothing had exercised yet.
  select l.base_difficulty        as r_difficulty,
         lp.reinforcement_seconds as r_cadence,
         lp.concurrent_cap        as r_base_cap,
         lp.enemy_unit_type_id    as r_unit_type,
         lp.cap_growth_every      as r_growth_every,
         lp.cap_ceiling           as r_ceiling
    into s
    from public.location_pressure lp
    join public.locations l on l.id = lp.location_id
   where lp.location_id = e.location_id;
  if not found then
    return next;   -- unauthored site: no pressure, no cap, no clock. Fail closed.
    return;
  end if;

  authored        := true;
  cadence         := s.r_cadence;
  base_cap        := s.r_base_cap;
  growth_every    := s.r_growth_every;
  cap_ceiling     := s.r_ceiling;
  unit_type_id    := s.r_unit_type;
  base_difficulty := s.r_difficulty;
  body_hp_nominal := s.r_difficulty * coalesce(cfg_num('enemy_hp_base'), 14);

  -- ── THE CLOCK. 0344's rule, unchanged: an unstamped row is due when the fight started, and a
  -- stalled clock has every elapsed slot come due AT ONCE. slots_due is that count, and it is the
  -- single quantity from which BOTH the clock advance and the ordinal advance are made — so the two
  -- cannot drift apart, because there is only one of them.
  due_at := coalesce(e.next_reinforcement_at, e.started_at);
  if due_at is not null and s.r_cadence > 0 and now() >= due_at then
    slots_due := floor(extract(epoch from (now() - due_at)) / s.r_cadence)::integer + 1;
  else
    slots_due := 0;
  end if;

  -- ── ██ THE SCHEDULED ORDINAL — THE ONE PLACE IT IS COMPUTED ██
  -- The stored ordinal plus the slots that just came due. It advances on a slot that spawns nothing
  -- exactly as it does on one that spawns a body, which is the whole reason it is a slot count and
  -- not an arrival count: an arrival counter stalls at the cap and can only move again when
  -- something DIES, which is the arrow 0344 deleted and this slice must not re-create.
  wave_index := e.pressure_wave_index + slots_due;

  -- ── ██ THE EFFECTIVE CAP — DERIVED HERE, USED BY THE SPAWN DECISION AND SHOWN BY THE CLIENT ██
  -- The divisor is the site row's own column. There is no literal period in this expression and
  -- assert (d) fails the deploy if one appears.
  if s.r_growth_every is null then
    effective_cap := base_cap;
  else
    effective_cap := base_cap + floor(wave_index::numeric / s.r_growth_every)::integer;
  end if;
  if s.r_ceiling is not null and effective_cap > s.r_ceiling then
    effective_cap := s.r_ceiling;
  end if;

  -- THE CEILING THE CLIENT'S ENEMY BAR DIVIDES BY. It is the EFFECTIVE cap x one body's nominal hp:
  -- a bar whose denominator stayed on the base cap would run past 100% the moment the field grew.
  ceiling_hp := body_hp_nominal * effective_cap;

  -- ── THE FIELD. Two vocabularies, one rule: how many BODIES are standing. 0344's text, composed
  -- rather than restated — an encounter whose units carry positions has bodies and they are counted;
  -- the 0228 arm carries no combat_units at all, so its population is its scalar hp over one body's
  -- nominal hp.
  bodied := exists (select 1 from public.combat_units cu
                     where cu.encounter_id = e.id and cu.pos_x is not null);
  if bodied then
    select coalesce(sum(cu.alive_count), 0) into population
      from public.combat_units cu
     where cu.encounter_id = e.id and cu.side = 'enemy' and cu.alive_count > 0;
  else
    population := ceil(greatest(0, coalesce(e.enemy_integrity_current, 0)) / greatest(body_hp_nominal, 1))::integer;
  end if;

  -- A RETREATING FLEET IS NEVER REINFORCED — 0336's rule, preserved as part of the ANSWER so every
  -- caller gets the same one. The offense gate silences the player during the retreat window while
  -- the enemy side is never gated, so sending a body into that window would be shooting at a fleet
  -- that cannot answer.
  arriving := (e.status = 'active') and slots_due > 0 and population < effective_cap;

  return next;
end
$cpf$;

comment on function public.combat_pressure_field(uuid) is
  'THE ONE AUTHORITY for "how big can this fight''s field get, and is a body due" (0347). Read-only: '
  'it writes nothing, spawns nothing and advances no clock. effective_cap = the site row''s '
  'concurrent_cap + floor(the fight''s SCHEDULED slot ordinal / the site row''s cap_growth_every), '
  'bounded by cap_ceiling when one is authored. The ordinal counts SLOTS, never arrivals: an '
  'arrival-driven counter cannot advance at the cap, so it would resume only when an enemy died, '
  'which is the arrow from a death back into pressure that 0344 deleted. Composed by '
  'public.combat_pressure_step for the spawn decision, and by that function alone — the client sees '
  'the same number as the STAMP combat_pressure_step writes onto '
  'combat_encounters.pressure_effective_cap, so no surface recomputes it.';

-- ENGINE INTERNAL. Revoked from PUBLIC BY NAME — the 0309 lesson: a revoke naming only anon and
-- authenticated leaves PUBLIC's default EXECUTE standing.
revoke all on function public.combat_pressure_field(uuid) from public;
revoke all on function public.combat_pressure_field(uuid) from anon, authenticated;
grant execute on function public.combat_pressure_field(uuid) to service_role;


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 4 — combat_pressure_step, REPOINTED ONTO THE AUTHORITY
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SAME NAME, SAME ARGUMENTS, SAME THREE OUT PARAMETERS — so the tick is not touched and its two call
-- sites are byte-identical before and after this migration.
--
-- WHAT CHANGED, EXHAUSTIVELY:
--   1. It no longer reads location_pressure or locations. It asks combat_pressure_field, once, and
--      every number it uses is that answer's. Assert (b) fails the deploy if this body ever names
--      concurrent_cap or cap_growth_every again.
--   2. The cap the field is measured against is f.effective_cap, and the ceiling it reports is
--      computed from that same cap.
--   3. The one UPDATE now advances the ordinal and stamps the cap beside the clock. All three come
--      from the same `slots_due`, in one statement, so they cannot disagree.
--
-- WHAT IS UNCHANGED, AND WHY EACH MATTERS:
--   * 0344's THREE RULES. There is still no branch on a death; still at most ONE body per call and no
--     loop, so nothing is banked; still a cadence that is the site row's column and nothing else.
--   * The clock arithmetic is the same value: 0344 wrote `v_due + cadence * (v_missed + 1)` and this
--     writes `f.due_at + cadence * f.slots_due`, where slots_due IS v_missed + 1 by construction.
--   * The status gate still stands AFTER the ceiling is reported and BEFORE the clock moves, so a
--     retreating fight still gets its denominator and still has its clock left alone.
--   * The four enemy stat formulas, the per-body variance roll and the wave_spawned event are 0344's
--     own, character for character, with two additions to the event PAYLOAD (`cap` now carries the
--     effective cap it always claimed to, and `wave` carries the ordinal). The client reads
--     wave_spawned by event_type only — combatFeed.ts:28, CombatEventLayer.tsx:19 — so the payload is
--     additive, checked rather than assumed.
--   * WITH cap_growth_every NULL, this function is behaviourally identical to 0344's, value for
--     value. That is what lets every existing proof block keep measuring what it measured.
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
  e     combat_encounters%rowtype;
  f     record;
  v_var double precision;
begin
  o_arrived := 0; o_body_hp := 0; o_ceiling_hp := 0;
  if p_encounter is null or p_tick is null then
    raise exception 'combat_pressure_step: called with encounter=% tick=% — pressure needs both, and defaulting either would spawn against a wrong clock rather than fail loudly', p_encounter, p_tick;
  end if;
  -- Keyed on the primary key, so this reads one row or none. It is never a scan whose first row
  -- happens to answer.
  select * into e from public.combat_encounters ce where ce.id = p_encounter;
  if not found then
    raise exception 'combat_pressure_step: encounter % does not exist — its caller is iterating a row that is gone', p_encounter;
  end if;

  -- ── THE ONE QUESTION, ASKED ONCE. INTO STRICT rather than INTO: an unqualified SELECT INTO takes
  -- the first row SILENTLY, and this repository has already paid for that. The authority returns
  -- exactly one row by construction, so STRICT turns "it did not" into an abort instead of a wrong
  -- cap nobody notices.
  select * into strict f from public.combat_pressure_field(p_encounter) pf;
  if not f.authored then
    return;   -- unauthored site: no pressure, no clock movement. Fail closed, exactly as 0344 left it.
  end if;

  -- The denominator is reported even for a fight that will not be reinforced, which is why it is set
  -- before the status gate — 0344's ordering, preserved.
  o_ceiling_hp := f.ceiling_hp;

  if e.status <> 'active' then
    return;
  end if;
  if f.slots_due <= 0 then
    return;   -- nothing is due: the clock is read and left alone, so the cadence cannot drift with
              -- the tick rate.
  end if;

  if f.arriving then
    -- ONE BODY. Never a wave, never a count derived from anything the player did.
    v_var     := coalesce(cfg_num('combat_damage_variance_pct'), 0.10);
    o_body_hp := f.body_hp_nominal * ((1 - v_var) + random() * (2 * v_var));
    o_arrived := 1;
    if f.bodied then
      perform public.combat_spawn_wave_units(
        e.id, e.player_id, f.unit_type_id, 1, o_body_hp,
        coalesce(cfg_num('enemy_synthetic_speed_base'),3)
          + f.base_difficulty * coalesce(cfg_num('enemy_synthetic_speed_per_difficulty'),0.2),
        coalesce(cfg_num('enemy_synthetic_range_base'),120)
          + f.base_difficulty * coalesce(cfg_num('enemy_synthetic_range_per_difficulty'),5),
        coalesce(cfg_num('enemy_synthetic_projectile_speed'),250),
        f.base_difficulty * coalesce(cfg_num('enemy_attack_base'),1.0),
        coalesce(cfg_num('enemy_synthetic_cooldown_seconds'),2),
        p_anchor_x, p_anchor_y, p_site_x, p_site_y, f.population);
    end if;
    -- SILENCE IS A BUG. An arrival the player is never told about reads as a broken game, so the
    -- event is emitted here — once, by the authority — rather than at two call sites. `cap` is the
    -- EFFECTIVE cap, which is what the number always claimed to mean.
    if p_log_events then
      insert into public.combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
        values (e.id, e.player_id, p_tick, coalesce(p_seq, 0), 'wave_spawned', 'pirate', 'player',
                jsonb_build_object('reinforcement', true, 'units', 1,
                                   'hp', round(o_body_hp), 'population', f.population + 1,
                                   'cap', f.effective_cap, 'wave', f.wave_index));
    end if;
  end if;

  -- ██ THE CLOCK, THE ORDINAL AND THE STAMP MOVE TOGETHER OR NOT AT ALL ██
  -- All three are made from ONE quantity, f.slots_due, in ONE statement. The clock skips past every
  -- elapsed slot in one step — that is what "a suppressed arrival is LOST, not banked" means — and
  -- the ordinal advances by exactly the same count, so a slot that spawned nothing has still been
  -- SPENT in both senses. This is the only statement in the database that writes any of the three.
  update public.combat_encounters
     set next_reinforcement_at  = f.due_at + make_interval(secs => f.cadence * f.slots_due),
         pressure_wave_index    = f.wave_index,
         pressure_effective_cap = f.effective_cap,
         updated_at = now()
   where id = e.id;
end;
$cps$;

comment on function public.combat_pressure_step(uuid, integer, double precision, double precision, double precision, double precision, integer, boolean) is
  'THE ONE PLACE ANOTHER ENEMY COMES FROM (0344), repointed by 0347 onto public.combat_pressure_field '
  'so the cap it measures the field against and the cap a client surface shows are one computation. '
  'It reads the SITE, the CLOCK and the FIELD through that leaf and nothing else — no kill count, no '
  'waves_cleared, no wave number, no elapsed presence. At most ONE body per call; a suppressed slot is '
  'spent, never banked; and the SCHEDULED slot ordinal it advances is what makes the cap grow, so cap '
  'growth is never unlocked by an enemy dying.';

revoke all on function public.combat_pressure_step(uuid, integer, double precision, double precision, double precision, double precision, integer, boolean) from public;
revoke all on function public.combat_pressure_step(uuid, integer, double precision, double precision, double precision, double precision, integer, boolean) from anon, authenticated;


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 5 — EVERY FIGHT ALREADY IN FLIGHT GETS ITS STAMP FROM THE AUTHORITY
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- The ordinal needs no backfill: NOT NULL DEFAULT 0 already gave every existing row a value the
-- clock can resolve, and 0 is the value this slice deliberately chooses (see the header — a derived
-- ordinal would hand a long fight a cap jump for slots fought under rules that had no growth).
--
-- The STAMP does need one, or a readout would show nothing for up to a full cadence on a fight that
-- is already running. It is taken BY CALLING THE AUTHORITY, per encounter, rather than by writing
-- the formula a second time in SQL — that would be exactly the second source of truth this slice
-- exists to prevent. A fight whose site is unauthored is skipped and keeps a NULL stamp, which is
-- the same fail-closed answer the authority gives.
update public.combat_encounters ce
   set pressure_effective_cap = (select f.effective_cap from public.combat_pressure_field(ce.id) f)
 where ce.status in ('active', 'retreating')
   and ce.pressure_effective_cap is null
   and exists (select 1 from public.location_pressure lp where lp.location_id = ce.location_id);


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SELF-ASSERTS — one DO block per check; every prosrc probe strips comments first
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- ⚠ NON-VACUITY IS CHECKED IN EVERY BLOCK. The banners above name the very identifiers asserted
-- ABSENT below, so an un-stripped probe would count prose as code and an over-eager strip would
-- count nothing at all (the 0222 trap, in both directions). Each block proves its probe is live
-- BEFORE it concludes anything from a zero.

-- (a) THE LEAF EXISTS AND IS ENGINE-INTERNAL
do $a$
declare v_oid oid;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_pressure_field';
  if v_oid is null then
    raise exception '0347 ASSERT (a) FAIL: leaf public.combat_pressure_field was not created';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'combat_pressure_field') <> 1 then
    raise exception '0347 ASSERT (a) FAIL: public.combat_pressure_field is overloaded — "how big can this field get" must have exactly ONE answer, not one per signature';
  end if;
  if not exists (select 1 from pg_proc p where p.oid = v_oid
                  and p.provolatile = 's' and p.prosecdef = true
                  and coalesce(array_to_string(p.proconfig, ','), '') = 'search_path=public') then
    raise exception '0347 ASSERT (a) FAIL: the leaf has the wrong volatility / security / search_path posture — it READS combat_encounters, location_pressure and combat_units and writes nothing, so it must be STABLE and SECURITY DEFINER with a pinned search_path. A VOLATILE answer would also be a licence for it to start writing';
  end if;
  if has_function_privilege('anon', v_oid, 'EXECUTE')
     or has_function_privilege('authenticated', v_oid, 'EXECUTE') then
    raise exception '0347 ASSERT (a) FAIL: the leaf is EXECUTE-able by a client role — it is an engine internal. The client''s view of the cap is the STAMP on its own encounter row, which is owner-scoped by RLS; a client-callable leaf keyed on an arbitrary encounter id would be a second, unguarded read path';
  end if;
end $a$;

-- (b) ONE AUTHORITY FOR THE CAP
do $b$
declare v_step text; v_sraw text; v_leaf text; v_lraw text; v_n integer;
begin
  select p.prosrc into v_sraw from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_pressure_step';
  v_step := regexp_replace(v_sraw, '--[^' || chr(10) || ']*', '', 'g');
  select p.prosrc into v_lraw from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_pressure_field';
  v_leaf := regexp_replace(v_lraw, '--[^' || chr(10) || ']*', '', 'g');
  if length(v_step) < 800 or length(v_step) >= length(v_sraw)
     or length(v_leaf) < 800 or length(v_leaf) >= length(v_lraw) then
    raise exception '0347 ASSERT (b) FAIL: the comment strip produced %/% chars from %/% char bodies — every count below would be measured against nothing', length(v_step), length(v_leaf), length(v_sraw), length(v_lraw);
  end if;

  -- THE STEP ASKS, EXACTLY ONCE. Two calls would be two answers on one tick, and a fight whose
  -- population changed between them would spawn against a cap it was not measured with.
  v_n := (length(v_step) - length(replace(v_step, 'public.combat_pressure_field(', '')))
         / length('public.combat_pressure_field(');
  if v_n <> 1 then
    raise exception '0347 ASSERT (b) FAIL: the spawn decision composes the cap authority % time(s) (want exactly 1)', v_n;
  end if;
  -- ...AND IT DOES NOT ANSWER FOR ITSELF. These are ABSENCE checks on broad needles, which is the
  -- direction the 0344 rule permits: a wider substring catches more of what must not be there.
  if position('concurrent_cap' in v_step) > 0 or position('cap_growth_every' in v_step) > 0
     or position('cap_ceiling' in v_step) > 0 or position('location_pressure' in v_step) > 0 then
    raise exception '0347 ASSERT (b) FAIL: the spawn decision reads the site''s pressure content directly — it must ask public.combat_pressure_field, or there are two places that decide how big a field may get and they will drift';
  end if;

  -- EXACTLY ONE FUNCTION IN public NAMES THE GROWTH PERIOD, AND IT IS THE LEAF. The sweep CANNOT
  -- pass vacuously: it must find the leaf itself, by the same pattern, in the same query.
  select count(*) filter (where p.proname = 'combat_pressure_field')
    into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and position('cap_growth_every' in regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')) > 0;
  if v_n <> 1 then
    raise exception '0347 ASSERT (b) FAIL: the growth-period sweep does not find public.combat_pressure_field itself — it would report "no other readers" while testing nothing';
  end if;
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname <> 'combat_pressure_field'
     and position('cap_growth_every' in regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')) > 0;
  if v_n <> 0 then
    raise exception '0347 ASSERT (b) FAIL: % other function(s) in public read cap_growth_every — the effective cap is derived in exactly ONE place, and a second derivation is how a UI comes to say "3 max" while four ships stand on the field', v_n;
  end if;
end $b$;

-- (c) THE COUNTER IS CLOCK-DRIVEN AND CANNOT BE KILL-DERIVED
-- ██ THIS IS THE BLOCK THAT FAILS THE DEPLOY ON THE TRAP. An arrival-driven ordinal cannot advance
-- while the field is at its cap, so the cap would resume growing only when an enemy DIED — the
-- indirect arrow from a death back into pressure that 0344 deleted. Here it is forbidden
-- structurally: the ordinal is assigned in exactly one place, out of the stored ordinal and the
-- CLOCK's slot count, and neither body may so much as name an arrival or a kill signal.
do $c$
declare v_leaf text; v_lraw text; v_step text; v_sraw text; v_n integer; v_probe integer;
begin
  select p.prosrc into v_lraw from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_pressure_field';
  v_leaf := regexp_replace(v_lraw, '--[^' || chr(10) || ']*', '', 'g');
  select p.prosrc into v_sraw from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_pressure_step';
  v_step := regexp_replace(v_sraw, '--[^' || chr(10) || ']*', '', 'g');
  if length(v_leaf) < 800 or length(v_leaf) >= length(v_lraw)
     or length(v_step) < 800 or length(v_step) >= length(v_sraw) then
    raise exception '0347 ASSERT (c) FAIL: the comment strip produced %/% chars from %/% char bodies', length(v_leaf), length(v_step), length(v_lraw), length(v_sraw);
  end if;

  -- NON-VACUITY, FIRST: the probe must find the ordinal at all. A regex that matched nothing would
  -- otherwise report an empty world as a clean one.
  v_probe := (length(v_leaf) - length(replace(v_leaf, 'wave_index', ''))) / length('wave_index');
  if v_probe < 3 then
    raise exception '0347 ASSERT (c) FAIL: the ordinal appears % time(s) in the authority — the probe is not live and every count below would be meaningless', v_probe;
  end if;

  -- THE ORDINAL IS DERIVED IN EXACTLY ONE PLACE, AND FROM THE CLOCK. One needle, one concept — the
  -- whole derivation, verbatim — so a PRESENCE count of 1 is unambiguous (0344's rule: a broad needle
  -- may only carry an absence check).
  v_n := (length(v_leaf) - length(replace(v_leaf, 'wave_index := e.pressure_wave_index + slots_due;', '')))
         / length('wave_index := e.pressure_wave_index + slots_due;');
  if v_n <> 1 then
    raise exception '0347 ASSERT (c) FAIL: the authority derives the scheduled ordinal from the stored ordinal plus the clock''s slot count % time(s) (want exactly 1). If the ordinal is computed anywhere else, or from anything else, the number that grows the cap is no longer the clock''s', v_n;
  end if;
  -- ...AND THE STORED ORDINAL IS READ EXACTLY ONCE, in that derivation and nowhere else. This is the
  -- count that moves if a second reading of the ordinal is ever introduced — including one that
  -- reconciles it against an arrival count.
  v_n := (length(v_leaf) - length(replace(v_leaf, 'pressure_wave_index', ''))) / length('pressure_wave_index');
  if v_n <> 1 then
    raise exception '0347 ASSERT (c) FAIL: the authority reads the stored ordinal % time(s) (want exactly 1 — the derivation above). A second read is a second rule for what the ordinal means', v_n;
  end if;
  -- THE SLOT COUNT IS THE CLOCK'S, EXACTLY. This is the expression the ordinal is made out of; if it
  -- ever stops being a pure function of due_at, now() and the site's cadence, the ordinal stops being
  -- a schedule.
  v_n := (length(v_leaf) - length(replace(v_leaf, 'slots_due := floor(extract(epoch from (now() - due_at)) / s.r_cadence)::integer + 1;', '')))
         / length('slots_due := floor(extract(epoch from (now() - due_at)) / s.r_cadence)::integer + 1;');
  if v_n <> 1 then
    raise exception '0347 ASSERT (c) FAIL: the authority computes the due-slot count from the clock % time(s) (want exactly 1). The ordinal advances by exactly this number, so a slot count derived from anything but the clock makes the cap grow for a reason the owner did not ask for', v_n;
  end if;

  -- NEITHER BODY MAY NAME A KILL SIGNAL OR AN ARRIVAL. Broad needles, ABSENCE only — the direction
  -- 0344's rule permits, and the stronger one: a wider substring catches more of what must not be
  -- there. `o_arrived` is the step's own OUT parameter and is deliberately in this list for the
  -- LEAF: the leaf must never learn whether a body arrived.
  if position('waves_cleared' in v_leaf) > 0 or position('wave_number' in v_leaf) > 0
     or position('danger' in v_leaf) > 0 or position('o_arrived' in v_leaf) > 0
     or position('arrivals' in v_leaf) > 0 or position('destroyed' in v_leaf) > 0
     or position('secs_inside' in v_leaf) > 0 then
    raise exception '0347 ASSERT (c) FAIL: the cap authority names a kill/wave/arrival signal. The ordinal must be the CLOCK''s scheduled slot count: an arrival-driven counter stalls at the cap and resumes only when an enemy dies, which is the arrow from a death back into pressure that 0344 deleted and the owner has rejected three times';
  end if;
  if position('waves_cleared' in v_step) > 0 or position('wave_number' in v_step) > 0
     or position('danger' in v_step) > 0 or position('secs_inside' in v_step) > 0 then
    raise exception '0347 ASSERT (c) FAIL: the spawn decision names a kill/wave signal';
  end if;
  -- ...and there is no loop in either, because a loop is how BANKING is written (0344 RULE 2).
  if position('loop' in v_leaf) > 0 or position('loop' in v_step) > 0 then
    raise exception '0347 ASSERT (c) FAIL: a loop has appeared in the pressure path — at most ONE body per call and nothing stored, or a suppressed slot becomes a debt that a death can call in';
  end if;

  -- THE STEP NAMES THE ORDINAL EXACTLY ONCE — the write — AND THE VALUE IT WRITES IS THE LEAF'S.
  v_n := (length(v_step) - length(replace(v_step, 'pressure_wave_index', ''))) / length('pressure_wave_index');
  if v_n <> 1 then
    raise exception '0347 ASSERT (c) FAIL: the spawn decision names the ordinal % time(s) (want exactly 1 — the write). Reading it here as well would let this function form its own opinion of the ordinal beside the authority''s', v_n;
  end if;
  if v_step !~ 'pressure_wave_index[[:space:]]*=[[:space:]]*f\.wave_index' then
    raise exception '0347 ASSERT (c) FAIL: the spawn decision does not write the ordinal from the authority''s own answer (f.wave_index). An increment computed here would be a second definition of the ordinal, and the two would drift the first time a slot was skipped';
  end if;

  -- ONE WRITER FOR THE ORDINAL AND ONE FOR THE STAMP, ACROSS THE WHOLE SCHEMA. The sweep must find
  -- the step itself first, so a pattern that matched nothing fails as a broken pattern.
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') ~ 'pressure_wave_index[[:space:]]*=';
  if v_n <> 1 then
    raise exception '0347 ASSERT (c) FAIL: % function(s) in public write pressure_wave_index (want exactly 1, public.combat_pressure_step). One clock, one ordinal, one writer', v_n;
  end if;
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') ~ 'pressure_effective_cap[[:space:]]*=';
  if v_n <> 1 then
    raise exception '0347 ASSERT (c) FAIL: % function(s) in public write pressure_effective_cap (want exactly 1, public.combat_pressure_step). The stamp is a PROJECTION of the authority''s answer; a second writer makes it a second opinion', v_n;
  end if;
  -- AND NOTHING READS THE STAMP BACK. It is shown, never consumed — a decision that read it would be
  -- reading its own last answer instead of asking the authority.
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname <> 'combat_pressure_step'
     and position('pressure_effective_cap' in regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')) > 0;
  if v_n <> 0 then
    raise exception '0347 ASSERT (c) FAIL: % other function(s) in public name pressure_effective_cap — the stamp exists so a CLIENT can show the cap without recomputing it, and an engine function that reads it has made a cached number into an input', v_n;
  end if;
end $c$;

-- (d) THE CAP IS NOT HARDCODED — the growth period is the site row's own column
do $d$
declare v_leaf text; v_lraw text; v_n integer;
begin
  select p.prosrc into v_lraw from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_pressure_field';
  v_leaf := regexp_replace(v_lraw, '--[^' || chr(10) || ']*', '', 'g');
  if length(v_leaf) < 800 or length(v_leaf) >= length(v_lraw) then
    raise exception '0347 ASSERT (d) FAIL: the comment strip produced % chars from a % char body', length(v_leaf), length(v_lraw);
  end if;

  -- THE ONE GROWTH EXPRESSION, AND ITS DIVISOR IS A COLUMN.
  v_n := (length(v_leaf) - length(replace(v_leaf, 'base_cap + floor(wave_index::numeric / s.r_growth_every)::integer', '')))
         / length('base_cap + floor(wave_index::numeric / s.r_growth_every)::integer');
  if v_n <> 1 then
    raise exception '0347 ASSERT (d) FAIL: the effective cap is derived from the site row''s growth period % time(s) (want exactly 1). "every 3 waves" is CONTENT — a period written into the function is a balance decision nobody can find and nobody can change without a deploy', v_n;
  end if;
  -- ...AND NO LITERAL DIVISOR ANYWHERE IN THE BODY. The only two divisions in this function are by
  -- the site's cadence and by one body's nominal hp, so a literal divisor can only be a hardcoded
  -- threshold. This is a broad ABSENCE needle and is therefore allowed to be broad.
  if v_leaf ~ '/[[:space:]]*[0-9]' then
    raise exception '0347 ASSERT (d) FAIL: the cap authority divides by a numeric literal — the growth period and the ceiling are DATA (location_pressure.cap_growth_every / .cap_ceiling), and a literal here is the hardcoded threshold this assert exists to refuse';
  end if;
  -- THE CEILING IS READ FROM THE ROW, and it is applied by comparison rather than by a clamp against
  -- some invented maximum.
  if position('s.r_ceiling' in v_leaf) = 0 then
    raise exception '0347 ASSERT (d) FAIL: the cap authority does not read the site''s cap_ceiling — an unbounded growth with no data row to bound it later is the "decide it in code" outcome the header refuses';
  end if;

  -- AND THE CONTENT IS SHAPED THE WAY THE COLUMNS PROMISE.
  if exists (select 1 from public.location_pressure where cap_growth_every is not null and cap_growth_every < 1) then
    raise exception '0347 ASSERT (d) FAIL: a location_pressure row carries a growth period below 1 — the CHECK should have made this unreachable';
  end if;
  if exists (select 1 from public.location_pressure where cap_ceiling is not null and cap_ceiling < concurrent_cap) then
    raise exception '0347 ASSERT (d) FAIL: a location_pressure row carries a ceiling below its own base cap — setting a ceiling must never shrink a site below the floor it was authored with';
  end if;
end $d$;

-- (e) NOTHING DARK
do $e$
declare v_n integer; v_keys text;
begin
  -- NO game_config KEY FOR THIS SLICE — asserted ABSENT, not promised. The pattern is narrow on
  -- purpose: many real worldstate_/event_ keys contain "pressure", and a broad pattern would make
  -- this assert unsatisfiable rather than strict.
  select count(*), coalesce(string_agg(key, ', '), '') into v_n, v_keys
    from public.game_config
   where key like '%cap_growth%' or key like '%pressure_wave%' or key like '%field_grow%'
      or key like '%cap_ceiling%';
  if v_n <> 0 then
    raise exception '0347 ASSERT (e) FAIL: % game_config key(s) exist for this slice (%) — the growth period and the ceiling are COLUMNS on the site''s content row. A knob beside them would be a second authority, and a knob that could switch the growth off would be the adapter this project has a law against', v_n, v_keys;
  end if;

  -- AND THE OWNER'S RULE IS LIVE AT EVERY REAL SITE. This is the assert that makes shipping it dark
  -- impossible: a NULL growth period is exactly what "authored but inert" would look like.
  select count(*) into v_n
    from public.location_pressure lp join public.locations l on l.id = lp.location_id
   where l.location_type = 'pirate_hunt' and l.status = 'active';
  if v_n < 3 then
    raise exception '0347 ASSERT (e) FAIL: only % active pirate-hunt site(s) carry a pressure row (want at least the three seeded ones) — the coverage sweep below would be quantifying over a near-empty set and would pass while proving nothing', v_n;
  end if;
  select count(*) into v_n
    from public.location_pressure lp join public.locations l on l.id = lp.location_id
   where l.location_type = 'pirate_hunt' and l.status = 'active'
     and lp.cap_growth_every is null;
  if v_n <> 0 then
    raise exception '0347 ASSERT (e) FAIL: % active pirate-hunt site(s) carry no growth period — the owner asked for a field that grows every third wave and a NULL there means it never does. That is this slice shipped dark', v_n;
  end if;
end $e$;

-- (f) THE TICK IS UNTOUCHED
do $f$
declare v_before text; v_len integer; v_after text; v_code text; v_raw text; v_n integer;
begin
  select body_md5, body_len into v_before, v_len from _0347_tick_before where fname = 'process_combat_ticks';
  if v_before is null or v_len is null or v_len < 40000 then
    raise exception '0347 ASSERT (f) FAIL: no usable pre-image of the tick was captured (md5 %, length %) — the comparison below would be between two nothings', coalesce(v_before, '<null>'), coalesce(v_len, -1);
  end if;
  select p.prosrc, md5(p.prosrc) into v_raw, v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if v_after is distinct from v_before then
    raise exception '0347 ASSERT (f) FAIL: process_combat_ticks changed during this migration (% -> %). This slice changes only the LEAF the tick already composes, at an identical signature, precisely because eleven generators assert that 0299 is still the newest textual re-create of that function — 0343 broke all eleven at once by re-emitting it', v_before, v_after;
  end if;
  -- ...and it still reaches the authority, twice. Without this the assert above would be satisfied by
  -- a tick that had lost the call entirely, as long as it lost it before this migration started.
  v_code := regexp_replace(v_raw, '--[^' || chr(10) || ']*', '', 'g');
  v_n := (length(v_code) - length(replace(v_code, 'combat_pressure_step(', ''))) / length('combat_pressure_step(');
  if v_n <> 2 then
    raise exception '0347 ASSERT (f) FAIL: the tick composes the pressure authority % time(s) (want exactly 2)', v_n;
  end if;
end $f$;

-- (g) THE IN-FLIGHT CONTRACT — no fight can land in a state the clock cannot resolve
do $g$
declare v_n integer; v_notnull boolean; v_default text;
begin
  select a.attnotnull, pg_get_expr(d.adbin, d.adrelid)
    into v_notnull, v_default
    from pg_attribute a
    left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
   where a.attrelid = 'public.combat_encounters'::regclass
     and a.attname = 'pressure_wave_index' and a.attnum > 0 and not a.attisdropped;
  if v_notnull is null then
    raise exception '0347 ASSERT (g) FAIL: combat_encounters.pressure_wave_index does not exist';
  end if;
  if not v_notnull or coalesce(v_default, '') <> '0' then
    raise exception '0347 ASSERT (g) FAIL: the ordinal is nullable or its default is % (want NOT NULL DEFAULT 0). Nullability is the whole in-flight contract: every fight running when this applied reads 0, so no coalesce is needed anywhere and no row exists that the clock cannot resolve', coalesce(v_default, '<none>');
  end if;
  -- The catalog facts above can never be vacuous. This row count can be, on an empty database, and
  -- that is stated rather than dressed up: it is a belt-and-braces check on real data.
  select count(*) into v_n from public.combat_encounters where pressure_wave_index is null;
  if v_n <> 0 then
    raise exception '0347 ASSERT (g) FAIL: % encounter(s) carry a NULL ordinal', v_n;
  end if;
  select count(*) into v_n
    from public.combat_encounters ce
   where ce.status in ('active', 'retreating')
     and ce.pressure_effective_cap is null
     and exists (select 1 from public.location_pressure lp where lp.location_id = ce.location_id);
  if v_n <> 0 then
    raise exception '0347 ASSERT (g) FAIL: % in-flight fight(s) at an AUTHORED site carry no cap stamp — section 5''s backfill did not reach them, and a readout would show nothing for up to a full cadence', v_n;
  end if;
  raise notice '0347 in-flight: % non-terminal encounter(s), all at ordinal 0 by construction; % of them stamped with a cap by section 5',
    (select count(*) from public.combat_encounters where status in ('active','retreating')),
    (select count(*) from public.combat_encounters where status in ('active','retreating') and pressure_effective_cap is not null);
end $g$;

-- (h) THE READOUT CONTRACT — the effective cap is REACHABLE by the client, and only as a projection
do $h$
begin
  -- This is the other half of the slice, asserted rather than assumed. A wave-timer readout must be
  -- able to READ the effective cap off the encounter row it already fetches; if it cannot, it will
  -- recompute one, and a recomputed cap is a second authority.
  if not has_column_privilege('authenticated', 'public.combat_encounters', 'pressure_effective_cap', 'SELECT')
     or not has_column_privilege('authenticated', 'public.combat_encounters', 'pressure_wave_index', 'SELECT') then
    raise exception '0347 ASSERT (h) FAIL: an authenticated client cannot SELECT the cap stamp or the ordinal on combat_encounters. The readout would then have to derive the cap itself, which is exactly the "3 max while four ships stand" defect this slice exists to prevent';
  end if;
  -- ⚠ WHAT IS DELIBERATELY *NOT* ASSERTED HERE, AND THE FINDING BEHIND IT. The obvious companion
  -- check — "no client role may UPDATE combat_encounters" — is NOT made, because it would ABORT this
  -- deploy on production. Measured read-only, 2026-08-09:
  --     has_table_privilege('authenticated','public.combat_encounters','UPDATE') = TRUE
  --     has_table_privilege('anon',         'public.combat_encounters','UPDATE') = TRUE
  -- That is Supabase's project-level GRANT ALL on new public tables, applied when 0014 created the
  -- table and never revoked — the same latent drift 0254 hit on danger_zones, and it PREDATES this
  -- slice by three hundred migrations. It is not live-exploitable: combat_encounters carries RLS with
  -- exactly one policy, combat_encounters_select_own (SELECT), so every client write is already
  -- default-denied. Asserting a posture a migration does not ESTABLISH is precisely the 0254 mistake,
  -- and REVOKING here would be this slice silently changing the privilege surface of the central
  -- combat table while claiming to be about a cap. So it is REPORTED rather than asserted or
  -- repaired, and it wants its own slice. What IS asserted is the lockdown 0344 actually established
  -- by revoking, on the table this slice adds columns to.
  if has_table_privilege('authenticated', 'public.location_pressure', 'INSERT')
     or has_table_privilege('authenticated', 'public.location_pressure', 'UPDATE')
     or has_table_privilege('authenticated', 'public.location_pressure', 'DELETE')
     or has_table_privilege('anon', 'public.location_pressure', 'INSERT')
     or has_table_privilege('anon', 'public.location_pressure', 'UPDATE')
     or has_table_privilege('anon', 'public.location_pressure', 'DELETE') then
    raise exception '0347 ASSERT (h) FAIL: a client role can write location_pressure — 0344 established that lockdown by REVOKING it (the 0254 lesson) and adding two columns must not have reopened it';
  end if;
end $h$;

commit;
