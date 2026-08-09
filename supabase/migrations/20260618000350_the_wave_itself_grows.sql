-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0350 — THE WAVE ITSELF GROWS
--        (every third SCHEDULED wave brings one more body — the thing the owner actually asked for)
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- ── THE OWNER, TWICE ────────────────────────────────────────────────────────────────────────────
--     "every 3 wave, i want wave to add one fleet"
-- and then, playing the deployed result of 0347:
--     "only 1 ships are comming out from the city, whereas i specifically told you to add 1 fleet
--      every three rounds..."
--
-- HE IS RIGHT AND 0347 BUILT THE WRONG THING. 0347 grew the CONCURRENT CAP — the ceiling on how many
-- bodies may stand on the field — while every scheduled slot still spawned exactly ONE body. One
-- arrival per slot can never fill a rising ceiling, so on a field the player is clearing the ceiling
-- is never the binding constraint and the growth is invisible.
--
-- MEASURED ON HIS OWN FIGHT, READ-ONLY, NOT INFERRED. Encounter 9855381f-a105-4e3f-b360-291cf1b88a01
-- at Snare, now completed: pressure_wave_index reached 40, pressure_effective_cap reached 16, and
-- of the 41 wave_spawned events it emitted, the 40 that carry a unit count carry
--
--     1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1
--
-- Forty waves. Forty single bodies. The ceiling climbed from 3 to 16 over the same forty slots and
-- was never once the number that decided anything.
--
-- ── WHAT THIS FILE DOES ─────────────────────────────────────────────────────────────────────────
-- THE WAVE GETS BIGGER. A scheduled slot no longer delivers a body; it delivers a WAVE, and the wave
-- has a SIZE:
--
--     wave_size(n) = 1 + floor((n - 1) / growth_every)
--
-- where n is combat_encounters.pressure_wave_index — THE CLOCK'S SCHEDULED ORDINAL, the same number
-- 0347 minted and for the same reason — and growth_every is a column on the site's own content row,
-- authored 3 at every live hunting ground. On a site authored "every 3", with the cap Snare actually
-- carries (base 3):
--
--     wave n   |  1   2   3   4   5   6   7   8   9  10  11  12
--     ---------+------------------------------------------------
--     bodies   |  1   1   1   2   2   2   3   3   3   4   4   4     <- 0350, the owner's words
--     eff. cap |  3   3   4   4   4   5   5   5   6   6   6   7     <- 0347, unchanged
--
-- Waves 1-3 bring 1, waves 4-6 bring 2, waves 7-9 bring 3. That is the owner's sentence, matched word
-- for word, and the table is written here rather than left to be derived because the last file that
-- claimed to implement this sentence implemented something else.
--
-- ── ⚠ THE TWO COLUMNS ARE ONE NOTCH, HALF A SLOT APART, AND THAT IS DELIBERATE ──────────────────
-- The cap's first notch lands on slot 3 (floor(3/3) = 1) and the wave's first notch lands on slot 4
-- (floor(3/3) + 1 = 2). It is NOT an off-by-one. THE ROOM ARRIVES BEFORE THE BODIES THAT NEED IT: a
-- fight at its cap gets one more slot of headroom on slot 3, and the first bigger wave arrives on
-- slot 4 with somewhere to stand. Reversing the order would mean the very first wave of 2 was
-- clamped to 1 by construction — a growth that could never be seen on the slot it began.
-- 0347's cap expression is preserved character for character (self-assert (d) requires it), because
-- the owner was shown its worked example (3,3,4,4,4,5) and approved it, and re-litigating an
-- approved number while fixing a different defect is how a fix becomes two changes.
--
-- ── ██ THE CAP STILL GROWS, AND IT DOES NOT DOUBLE-COUNT ██ ─────────────────────────────────────
-- The owner explicitly approved it — "yes, cap should grow. go ahead" — so it is not removed, and
-- this paragraph exists so that decision is stated rather than inherited by silence.
--
-- THEY ANSWER DIFFERENT QUESTIONS AND NEITHER IS DERIVED FROM THE OTHER:
--     wave_size      how many bodies ARRIVE in one scheduled wave
--     effective_cap  how many bodies may STAND on the field at once
-- A single number could not do both jobs. Delete the cap growth and a long fight's field is pinned
-- at its authored floor forever no matter how big the waves get, which is the opposite of
-- escalation. Delete the wave growth — which is what shipped — and the ceiling rises over an empty
-- room. Both were needed; only one was built.
--
-- WHICH ONE BINDS, AND WHEN. They compose by CLAMP (below), so at any instant the smaller of "what
-- the wave wants" and "what the field has room for" is what arrives. On a field the player is
-- clearing, the wave is the binding number and the owner sees 1, 1, 1, 2, 2, 2, 3 … — the defect he
-- reported, fixed. On a field the player is NOT clearing, the cap is the binding number and the
-- field stays bounded — which is the cap doing its only job. That is a precedence, not a
-- double-count: the two never add.
--
-- ── ██ THE CLAMP: A WAVE OF 3 AGAINST 1 SLOT OF ROOM DELIVERS 1, NEVER 0 ██ ─────────────────────
-- The decision, and it is the load-bearing one in this file:
--
--     arriving_count = least(wave_size, greatest(effective_cap - population, 0))
--
-- ALL-OR-NOTHING WAS REJECTED, FOR THREE REASONS, THE THIRD OF WHICH IS DISQUALIFYING:
--   1. The owner's complaint is that TOO FEW arrive. A rule under which a bigger wave sometimes
--      delivers NOTHING would make his own report worse, not better.
--   2. It inverts escalation. Under all-or-nothing a wave of 3 is LESS likely to land than a wave of
--      1, so the fight would get quieter as it escalated — a mechanic whose own growth suppresses it.
--   3. ██ IT WOULD RE-CREATE THE ARROW FROM A DEATH BACK INTO PRESSURE. ██ On a full field an
--      all-or-nothing wave of 3 lands nothing until THREE slots open at once, and slots open only
--      when enemies DIE. Killing would become the thing that unlocks the wave — the arrow 0344
--      deleted and the owner has rejected three times, wearing a fourth costume. Under the clamp the
--      relation is monotone and kill-free: one slot of room admits one body, always.
-- A suppressed BODY is lost exactly as 0344's suppressed SLOT is lost: nothing is banked, no debt is
-- created, and a death calls nothing in. The clamp is that same law applied per body.
--
-- IT IS OBSERVABLE, NOT INFERRED. Three places say what happened, and all three read one number:
--   * the `wave_spawned` event payload now carries `units` (what LANDED) beside `wave_size` (what the
--     wave WANTED) and `cap`/`population`, so a clamped wave is legible in the feed rather than
--     indistinguishable from a small one;
--   * combat_encounters.pressure_next_wave_size is STAMPED with the size of the NEXT scheduled wave,
--     which is the number a wave clock must announce;
--   * DZCOMBAT_PASS_WAVEGROWS drives a real fight through a clamped wave and asserts both the
--     delivered count AND that the ordinal still advanced through it.
--
-- ── ⚠ THE WAVE SIZE IS UNBOUNDED TODAY. THAT IS A DECISION AND IT IS A DATA ROW ─────────────────
-- 1 + floor((n-1)/3) grows without limit, and the fight is endless on purpose — the owner's standing
-- law is "the whole point of this game is never to win, but exit appropriately". So this ships
-- UNBOUNDED and location_pressure.wave_size_ceiling is NULL at every site. Bounding a site later is
-- one UPDATE and no deploy:
--     update public.location_pressure set wave_size_ceiling = 6 where location_id = <site>;
-- The apply raises a NOTICE naming every site and its two ceilings, so the deploy log RECORDS the
-- unbounded state instead of burying it. Inventing a number the owner has not ruled on would be a
-- balance decision smuggled in as an implementation detail (0347's argument, unchanged).
--
-- ── ██ ONE COLUMN FOR "EVERY 3", NOT TWO — location_pressure.cap_growth_every IS RENAMED ██ ─────
-- 0347 called the period `cap_growth_every` because the cap was the only thing that grew. It is the
-- SAME "every 3" out of the SAME owner sentence, and it now governs both notches, so a name that
-- says "cap" is a name that lies — and the next person would be right to add `wave_growth_every`
-- beside it, which is two spellings of one design decision and exactly the disease 0347's own header
-- argued against when it refused a `cap_growth_step` column. So the column is RENAMED to
-- `growth_every` and there is exactly one number on the row that means "this site escalates one
-- notch every N scheduled waves". A rename is catalog-only and instant; the column has exactly one
-- reader in the whole schema (public.combat_pressure_field), which this file re-mints anyway.
--
-- ── ONE AUTHORITY FOR "HOW BIG IS WAVE n": public.combat_wave_size ──────────────────────────────
-- The size is needed at TWO ordinals — the slot that is due now, and the next slot, which is what a
-- readout announces — so writing the arithmetic inline would put it in the leaf twice. It is a leaf
-- instead, composed twice, and it is IMMUTABLE with three scalar arguments.
--
-- ██ THAT SIGNATURE IS A TYPE-LEVEL PROOF OF KILL-INDEPENDENCE. ██ An IMMUTABLE function taking only
-- (ordinal, period, ceiling) cannot read a table, cannot see a death, cannot see a kill count and
-- cannot see how the fight is going. It is not a promise in a comment that the wave size is
-- clock-driven; it is a thing the function is structurally incapable of doing, and self-assert (c)
-- fails the deploy if the volatility or the argument count ever changes.
--
-- ── THE ORDINAL IS STILL THE CLOCK'S, AND STILL NOT AN ARRIVAL COUNT ────────────────────────────
-- Nothing about pressure_wave_index changes. It advances on EVERY scheduled slot, by exactly the
-- number of slots the clock skipped, whether or not a body arrived — 0344's RULE 2 and 0347's
-- ordinal, untouched. That property is what this slice inherits and must not break, and it is the
-- reason the wave size is derived FROM THE ORDINAL rather than from arrivals: an arrival-driven
-- counter cannot advance at the cap, so it would resume only when an enemy DIED, and the wave size
-- would then be unlocked by killing. Self-assert (c) re-proves the whole chain — the ordinal's one
-- derivation, its one writer, and the absence of every kill/arrival needle from all three bodies.
--
-- ── HOW THE BODIES ARE PLACED: THE EXISTING SPAWNER, COMPOSED, NOT A SECOND ONE ─────────────────
-- public.combat_spawn_wave_units ALREADY takes a count and already places n bodies on the formation
-- arc, each at its own slot, each with its own 6-tick ingress from the city (0339 + 0346). Verified
-- against the DEPLOYED body, read-only, not from the migration text: it loops 1..p_count, asks
-- combat_ingress_boundary for that slot's point, and returns the next free slot. So the change here
-- is ONE ARGUMENT — the literal 1 becomes f.arriving_count — and nothing about spawning is rewritten.
-- A wave of three comes out of the city as three bodies on three arc slots, not a pile.
--
-- ONE HP ROLL PER WAVE, NOT PER BODY, AND THAT IS THE EXISTING CONTRACT. combat_pressure_step's OUT
-- parameters are (o_arrived, o_body_hp, o_ceiling_hp) and the tick's aggregate arm already computes
-- `v_pressure_arrived * v_body_hp` — i.e. the shape has always meant "n bodies of o_body_hp each".
-- Rolling per body would need a loop in the pressure path, and a loop there is forbidden (it is how
-- BANKING is written — 0344 RULE 2, asserted in (c)).
--
-- ── PARITY: THE TICK IS NOT TOUCHED AT ALL ─────────────────────────────────────────────────────
-- process_combat_ticks is ~92k chars live, no file holds it whole, and eleven generators each assert
-- that 0299 is still the newest TEXTUAL re-create of it; 0343 broke all eleven at once by re-emitting
-- it. This file contains no re-create of it and no surgery on it. Both of the tick's call sites are
-- byte-identical before and after, because combat_pressure_step keeps its name, its eight arguments
-- and its three OUT parameters, and o_arrived simply carries a number that could always have been
-- greater than one. Self-assert (f) captures md5(prosrc) before the first DDL statement and requires
-- it unchanged, which also catches a re-create arriving by any other route.
--
-- ── ⚠ IN-FLIGHT ENCOUNTERS — PRODUCTION IS A LIVE ~30-PLAYER GAME WITH FIGHTS RUNNING NOW ───────
-- Prod head verified read-only at apply-authoring time: 20260618000349. What happens to a fight that
-- is mid-combat at the instant this commits:
--   * NOTHING IS RESET. pressure_wave_index keeps its value. A fight sitting at ordinal 7 gets a wave
--     of 3 on its next slot rather than a wave of 1. That is a real, visible step up mid-fight, and
--     it is the CORRECT one: the ordinal says eight waves have come due, the owner's rule says wave 8
--     brings 3, and the alternative — resetting live fights to ordinal 0 — would delete the schedule
--     of every fight in progress to make a number look smoother. The owner's complaint is that too
--     few arrive; a fight that steps up immediately is the fix arriving, not a surprise.
--   * The step-up is BOUNDED by the field, not unbounded: the clamp means a fight already at its cap
--     still receives only what fits. The worst case is a fight with an empty field at a high ordinal,
--     which receives one full wave — at Snare's authored numbers, at most effective_cap bodies.
--   * pressure_next_wave_size is NULL until a slot is evaluated, so SECTION 5 backfills every
--     non-terminal encounter at an authored site BY CALLING THE AUTHORITY (never by re-deriving the
--     formula in SQL), and a readout has a real number from the first moment.
--   * A site with no location_pressure row is unchanged: the authority answers authored=false, the
--     step returns without spawning and without writing, the stamps stay NULL. Fail closed.
--   * Everything is created in ONE transaction, so no tick ever names a function that does not exist,
--     and a cron pass already executing finishes on the old leaf and resolves its encounter fully.
--
-- ── ROLLBACK BOUNDARY ───────────────────────────────────────────────────────────────────────────
-- Five objects. In ONE transaction, in this order (the drops must not precede the restores):
--   1. `alter table public.location_pressure rename column growth_every to cap_growth_every;`
--      — do this FIRST: steps 2 and 3 restore bodies that name the old column.
--   2. `drop function public.combat_pressure_field(uuid);` then re-run the
--      `create or replace function public.combat_pressure_field` block from
--      supabase/migrations/20260618000347_the_field_grows.sql:457-598 VERBATIM. The drop is required
--      because this file changes the return type (arriving boolean -> arriving_count integer); a
--      `create or replace` cannot. 0347 holds that function WHOLE in one file, which is why 0344's
--      rule against restoring a fragment from an older migration does not apply here.
--   3. Re-run the `create or replace function public.combat_pressure_step` block from
--      20260618000347_the_field_grows.sql:647-741 VERBATIM. That is the complete pre-image and its
--      deployed md5 is recorded in section 0's NOTICE below, so the restore is verifiable.
--   4. `drop function public.combat_wave_size(integer, integer, integer);` — safe only after 2.
--   5. `alter table public.location_pressure drop column wave_size_ceiling;` — safe only after 2.
--   6. OPTIONAL: `alter table public.combat_encounters drop column pressure_next_wave_size;` — safe
--      to LEAVE. After 3 nothing writes it and nothing reads it, and dropping a column a re-applied
--      0350 would need buys nothing on a live game.
-- Rolling back deletes no enemy row, disturbs no haul, resets no ordinal and changes no
-- player-visible state other than the wave returning to one body. There is NO config value that
-- switches the growth off, deliberately: a knob that could is the adapter this project has a law
-- against.
--
-- ── NOTHING DARK ────────────────────────────────────────────────────────────────────────────────
-- No feature flag, and this slice creates NO game_config key at all — asserted ABSENT in (e), not
-- promised. The period is a COLUMN on the site's own content row, live at every active hunting
-- ground the instant this commits, and (e) fails the deploy if any active pirate-hunt site is left
-- without it. The way this could ship invisible is a NULL period, so that is the state (e) forbids
-- on real content.
--
-- ── THE CLIENT HALF, AND WHY IT IS A COLUMN RATHER THAN AN EDIT ─────────────────────────────────
-- src/features/combat/reinforcementClock.ts is the client's ONE reinforcement authority and it is
-- owned by a concurrent slice, so this file does not touch it. It does not have to: combat_encounters
-- is fetched with `select('*')` under combat_encounters_select_own (0014), so the server carries the
-- answer in a column the client already reads. `pressure_next_wave_size` is a STAMP — computed once
-- by combat_pressure_field, written once by combat_pressure_step, read back by nothing — exactly the
-- shape 0347 gave pressure_effective_cap, so no surface recomputes the band and there is no
-- client-side arithmetic to drift. Self-assert (h) asserts that column-level SELECT reachability
-- rather than assuming it.
-- ⚠ ONE SENTENCE IN THAT FILE IS MADE FALSE BY THIS MIGRATION AND MUST CHANGE IN THE SAME LANDING:
-- `REINFORCEMENT_RULE` currently reads "A wave brings one more ship only while the field is under its
-- limit." After this, a wave brings AS MANY AS ITS SIZE, clamped by the room. The required client
-- delta is written out in full in docs/DEV_LOG.md under this slice; it is three lines and it reads
-- the stamp, never the band.
--
-- ── SELF-ASSERT MAP (one DO block per check — the statement number IS the diagnosis) ────────────
--   (a) the size leaf exists, is IMMUTABLE with exactly three scalar arguments, and no client role
--       can execute it
--   (b) ONE AUTHORITY FOR THE WAVE SIZE: the size expression occurs in exactly ONE function in
--       public and it is combat_wave_size; the field leaf composes it exactly twice; the step never
--       computes a size of its own and never passes a literal count to the spawner
--   (c) THE SIZE IS CLOCK-DRIVEN AND CANNOT BE KILL-DERIVED: structurally (IMMUTABLE, 3 scalar
--       args, no table read) and textually (no kill/arrival/wave-counter needle in any of the three
--       bodies, no loop in any of them), plus 0347's ordinal chain re-proved end to end
--   (d) THE THRESHOLDS ARE DATA: the period and both ceilings are columns, no numeric literal
--       divisor appears in either leaf, and 0347's cap expression survives character for character
--   (e) NOTHING DARK: no game_config key for this slice, and every ACTIVE pirate-hunt site carries an
--       authored period (over at least the three seeded sites, so the sweep cannot pass over an
--       empty set)
--   (f) THE TICK IS UNTOUCHED: md5(prosrc) identical before and after, and it still composes the
--       authority exactly twice at 0344's exact argument list
--   (g) THE IN-FLIGHT CONTRACT: no non-terminal fight at an authored site is left without a stamp,
--       and the ordinal column is still NOT NULL DEFAULT 0 with no NULL rows
--   (h) THE READOUT CONTRACT: `authenticated` can SELECT the new stamp on combat_encounters, and
--       location_pressure keeps 0344's client-write lockdown through two column changes
--
-- WHAT THE SELF-ASSERT CANNOT DO, STATED RATHER THAN IMPLIED. These are STRUCTURAL. They prove the
-- size has one authority, is derived from the ordinal, and cannot see a kill. They CANNOT prove that
-- wave 4 puts TWO bodies on the field and wave 7 puts THREE, or that a wave of 3 against one slot of
-- room delivers exactly 1 while still spending its slot. Only a real fight can, and that is
-- DZCOMBAT_PASS_WAVEGROWS on the disposable-Postgres leg, which is the only real gate.
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
  v_lraw text;
  v_leaf text;
  v_sraw text;
  v_step text;
  v_n    integer;
begin
  select p.prosrc into v_traw
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if v_traw is null then
    raise exception '0350 PRECONDITION FAIL: public.process_combat_ticks does not exist';
  end if;
  v_tick := regexp_replace(v_traw, '--[^' || chr(10) || ']*', '', 'g');
  -- The stripper must have removed something and must have left a body. BOTH directions, because a
  -- broken strip makes every count below meaningless in a way that reads as success (the 0222 trap).
  if length(v_tick) < 40000 or length(v_tick) >= length(v_traw) then
    raise exception '0350 PRECONDITION FAIL: the comment strip produced % chars from a % char tick body — every count below would be measured against nothing', length(v_tick), length(v_traw);
  end if;

  -- 0344 IS APPLIED AND THE TICK STILL ASKS THE PRESSURE AUTHORITY, TWICE, AT 0344's EXACT ARGUMENT
  -- LIST. Counted with a LADDER — the broad call form and the full-argument form must agree at 2 — so
  -- a third call in a different shape moves one count and not the other, and this aborts. This slice
  -- keeps that signature byte-identical precisely so the tick is not touched.
  v_n := (length(v_tick) - length(replace(v_tick, 'combat_pressure_step(', ''))) / length('combat_pressure_step(');
  if v_n <> 2 then
    raise exception '0350 PRECONDITION FAIL: the tick composes combat_pressure_step % time(s) (want exactly 2 — one per arm). Either the pressure authority is not the one 0344 minted, or a third caller has appeared and there is more than one place another enemy can come from', v_n;
  end if;
  v_n := (length(v_tick) - length(replace(v_tick, 'public.combat_pressure_step(e.id, v_tick, v_anchor_x, v_anchor_y, loc.x, loc.y, v_seq, v_log_events)', '')))
         / length('public.combat_pressure_step(e.id, v_tick, v_anchor_x, v_anchor_y, loc.x, loc.y, v_seq, v_log_events)');
  if v_n <> 2 then
    raise exception '0350 PRECONDITION FAIL: % of the tick''s calls to the pressure authority pass 0344''s arguments (want 2). This slice changes only what the authority DOES, never its shape; a call in another form means that assumption is already false', v_n;
  end if;
  -- ...and the tick still consumes the arrival COUNT as a count. This is the needle that makes "one
  -- call can now deliver n bodies" safe without touching the tick: the aggregate arm already
  -- multiplies the count by one body's hp, so it has always meant "n bodies of o_body_hp each".
  if position('v_pressure_arrived * coalesce(v_body_hp, 0)' in v_tick) = 0 then
    raise exception '0350 PRECONDITION FAIL: the tick no longer folds the arrival COUNT into its enemy integrity (v_pressure_arrived * v_body_hp). This slice makes that count greater than one; a tick that treats it as a boolean would silently under-count a wave of three on the aggregate arm';
  end if;

  -- 0346 IS APPLIED: the ingress phase this slice relies on to place n bodies out of the city.
  if position('ingress_ticks_left' in v_traw) = 0 then
    raise exception '0350 PRECONDITION FAIL: the deployed tick does not carry 0346''s ingress phase — this migration is being applied to a body older than the one it was sliced against. Do not apply this out of order';
  end if;

  -- 0347 IS APPLIED, AT ITS EXACT SHAPE, AND THERE IS EXACTLY ONE OF EACH.
  if to_regprocedure('public.combat_pressure_step(uuid, integer, double precision, double precision, double precision, double precision, integer, boolean)') is null then
    raise exception '0350 PRECONDITION FAIL: public.combat_pressure_step is missing at its 0344/0347 signature — this slice re-emits exactly that function and will not create a second one beside it';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'combat_pressure_step') <> 1 then
    raise exception '0350 PRECONDITION FAIL: public.combat_pressure_step is overloaded — there must be exactly ONE pressure authority and this slice refuses to guess which';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'combat_pressure_field') <> 1 then
    raise exception '0350 PRECONDITION FAIL: public.combat_pressure_field does not exist exactly once — 0347 is not applied, or the cap authority has been forked';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'location_pressure'
                    and column_name = 'cap_growth_every') then
    raise exception '0350 PRECONDITION FAIL: public.location_pressure carries no cap_growth_every — 0347 is not applied, and this slice RENAMES that column rather than adding a second period beside it';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'combat_encounters'
                    and column_name = 'pressure_wave_index') then
    raise exception '0350 PRECONDITION FAIL: public.combat_encounters carries no pressure_wave_index — the scheduled ordinal is the number this slice derives the wave size FROM, and without it there is nothing to derive from but arrivals';
  end if;

  -- NOTHING THIS SLICE MINTS MAY ALREADY EXIST.
  if to_regproc('public.combat_wave_size') is not null then
    raise exception '0350 PRECONDITION FAIL: public.combat_wave_size already exists. This slice MINTS it as THE one answer to "how many bodies does wave n bring"; two files creating one authority is the disease itself';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'location_pressure'
                and column_name in ('growth_every', 'wave_size_ceiling')) then
    raise exception '0350 PRECONDITION FAIL: public.location_pressure already carries growth_every or wave_size_ceiling — this migration has already been applied, or a second period column has been added beside cap_growth_every';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'combat_encounters'
                and column_name = 'pressure_next_wave_size') then
    raise exception '0350 PRECONDITION FAIL: public.combat_encounters already carries pressure_next_wave_size — this migration has already been applied';
  end if;

  -- THE TWO BODIES THIS FILE REPLACES ARE THE 0347 ONES. Three single-concept needles per body rather
  -- than an md5, so a legitimate earlier re-emission does not hold the chain hostage while a body
  -- that is NOT 0347's still aborts.
  select p.prosrc into v_lraw from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_pressure_field';
  v_leaf := regexp_replace(v_lraw, '--[^' || chr(10) || ']*', '', 'g');
  select p.prosrc into v_sraw from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_pressure_step';
  v_step := regexp_replace(v_sraw, '--[^' || chr(10) || ']*', '', 'g');
  if length(v_leaf) < 1500 or length(v_leaf) >= length(v_lraw)
     or length(v_step) < 1500 or length(v_step) >= length(v_sraw) then
    raise exception '0350 PRECONDITION FAIL: the comment strip produced %/% chars from %/% char bodies', length(v_leaf), length(v_step), length(v_lraw), length(v_sraw);
  end if;
  v_n := (length(v_leaf) - length(replace(v_leaf, 'coalesce(e.next_reinforcement_at, e.started_at)', '')))
         / length('coalesce(e.next_reinforcement_at, e.started_at)');
  if v_n <> 1 then
    raise exception '0350 PRECONDITION FAIL: the cap authority reads the unstamped-row clock % time(s) (want exactly 1). This slice keeps 0344''s clock and 0347''s ordinal exactly as they are and changes only how many bodies one due slot delivers', v_n;
  end if;
  v_n := (length(v_leaf) - length(replace(v_leaf, 'wave_index := e.pressure_wave_index + slots_due;', '')))
         / length('wave_index := e.pressure_wave_index + slots_due;');
  if v_n <> 1 then
    raise exception '0350 PRECONDITION FAIL: the cap authority derives the scheduled ordinal from the stored ordinal plus the clock''s slot count % time(s) (want exactly 1) — that derivation is 0347''s and this slice preserves it verbatim, because the wave size is derived from its result', v_n;
  end if;
  v_n := (length(v_step) - length(replace(v_step, 'public.combat_spawn_wave_units(', ''))) / length('public.combat_spawn_wave_units(');
  if v_n <> 1 then
    raise exception '0350 PRECONDITION FAIL: the spawn decision composes the sole enemy-row inserter % time(s) (want exactly 1)', v_n;
  end if;
  if position('f.unit_type_id, 1, o_body_hp' in v_step) = 0 then
    raise exception '0350 PRECONDITION FAIL: the spawn decision does not pass the literal count 1 to the spawner — that literal IS the defect this migration exists to remove, and if it is already gone then something else has changed this body and the replacement below is not the edit it claims to be';
  end if;

  -- THE SPAWNER ALREADY PLACES n BODIES. Verified against the DEPLOYED body rather than assumed from
  -- a migration file: it must take a count, loop over it, and ask the boundary leaf per slot. This is
  -- the needle that makes "compose it, do not write a second spawn path" an assertion.
  select p.prosrc into v_sraw from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_spawn_wave_units';
  if v_sraw is null then
    raise exception '0350 PRECONDITION FAIL: public.combat_spawn_wave_units does not exist — there is no spawner to compose';
  end if;
  if position('for v_i in 1 .. p_count loop' in v_sraw) = 0
     or position('public.combat_ingress_boundary(' in v_sraw) = 0
     or position('v_slot := v_slot + 1;' in v_sraw) = 0 then
    raise exception '0350 PRECONDITION FAIL: the deployed spawner does not loop over p_count placing one body per formation slot. This slice delivers a wave by passing a COUNT to it; a spawner that ignores the count, or stacks every body on one point, would turn a wave of three into a pile or into one body';
  end if;

  raise notice '0350 parity source: production, read-only 2026-08-09, head 20260618000349. OBSERVED here: combat_pressure_field prosrc md5 = % / % chars; combat_pressure_step prosrc md5 = % / % chars. Those are the PRE-IMAGES the rollback boundary in this header restores from 20260618000347_the_field_grows.sql:457-598 and :647-741. A difference from the deployed md5s is a REVIEW SIGNAL, not a failure — this rewrite does not depend on byte equality, and what is hard-asserted above is what must be TRUE of those bodies whatever wrote them.',
    md5(v_lraw), length(v_lraw), md5(v_sraw), length(v_sraw);
end $pre$;


-- ── 1. CAPTURE THE TICK'S FINGERPRINT BEFORE ANY DDL (for parity check (f)) ─────────────────────
create temp table _0350_tick_before (fname text primary key, body_md5 text, body_len integer)
  on commit drop;
insert into _0350_tick_before
select p.proname, md5(p.prosrc), length(p.prosrc)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'process_combat_ticks';


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 1 — ONE PERIOD COLUMN, AND A CEILING FOR THE WAVE BESIDE THE ONE FOR THE FIELD
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE RENAME IS THE POINT, not housekeeping. After it there is exactly ONE number on a site's
-- content row that means "this site escalates one notch every N scheduled waves", and both notches
-- read it. Two columns each holding 3 would be two spellings of one owner sentence, and the first
-- person to retune one and not the other would ship a half-escalating site.
alter table public.location_pressure rename column cap_growth_every to growth_every;

alter table public.location_pressure
  rename constraint location_pressure_cap_growth_every_positive to location_pressure_growth_every_positive;

comment on column public.location_pressure.growth_every is
  '0350 (renamed from 0347''s cap_growth_every): how many SCHEDULED reinforcement slots this site takes to escalate ONE NOTCH. The owner: "every 3 wave, i want wave to add one fleet". A notch is BOTH of: +1 body in the wave (public.combat_wave_size: 1 + floor((pressure_wave_index - 1) / this), bounded by wave_size_ceiling) and +1 body of room on the field (concurrent_cap + floor(pressure_wave_index / this), bounded by cap_ceiling). It is ONE column because it is ONE decision out of ONE sentence; a second period beside it would be two spellings that drift. NULL means this site does not escalate at all, which is 0344''s behaviour value for value; every authored site carries 3 and self-assert (e) of 0350 fails the deploy if an active pirate-hunt site does not. There is deliberately NO step-size column: a step of k is the same axis as a period of every/k.';

-- THE WAVE'S OWN CEILING. A different quantity from cap_ceiling and therefore its own column: one
-- bounds how many may STAND, this bounds how many may ARRIVE AT ONCE. Both are NULL everywhere today.
alter table public.location_pressure
  add column wave_size_ceiling integer;

alter table public.location_pressure
  add constraint location_pressure_wave_size_ceiling_positive
    check (wave_size_ceiling is null or wave_size_ceiling >= 1);

comment on column public.location_pressure.wave_size_ceiling is
  '0350: the largest number of bodies this site will ever send in ONE scheduled wave. NULL means UNBOUNDED, which is what every site carries today — the fight is endless by design ("the whole point of this game is never to win, but exit appropriately") and the owner has not ruled on a ceiling. It is a ROW so that ruling is one UPDATE and no deploy. Distinct from cap_ceiling on purpose: cap_ceiling bounds how many bodies may STAND on the field, this bounds how many may ARRIVE in one wave, and the two compose by clamp (a wave delivers least(its size, the room left)).';

-- THE UNBOUNDED STATE IS RECORDED IN THE DEPLOY LOG, not buried. A human reading the apply output
-- sees every site, its base cap, its escalation period and BOTH ceilings.
do $ceil$
declare r record;
begin
  for r in
    select l.name, l.status, lp.concurrent_cap, lp.growth_every, lp.cap_ceiling, lp.wave_size_ceiling
      from public.location_pressure lp join public.locations l on l.id = lp.location_id
     order by l.name
  loop
    raise notice '0350 pressure content: % (%) base cap %, one notch every % slot(s), field ceiling %, wave ceiling %',
      r.name, r.status, r.concurrent_cap, coalesce(r.growth_every::text, 'NEVER'),
      coalesce(r.cap_ceiling::text, 'UNBOUNDED'),
      coalesce(r.wave_size_ceiling::text, 'UNBOUNDED (no ruling; set location_pressure.wave_size_ceiling to bound it — one UPDATE, no deploy)');
  end loop;
end $ceil$;


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 2 — THE CLIENT-VISIBLE PROJECTION OF THE WAVE SIZE
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- ONE WRITER: public.combat_pressure_step, in the same UPDATE that advances the clock, the ordinal
-- and the cap stamp. Assert (c) proves that by sweeping pg_proc, not by asking anyone to believe
-- this comment.
--
-- IT IS THE **NEXT** WAVE'S SIZE, not the one just delivered, and that is what a wave clock needs: a
-- readout says "next wave in 12s" and must be able to say how many are in it. It is not a prediction
-- of whether anything will ARRIVE — that depends on the field at a moment that has not happened, and
-- 0347's client leaf refuses to guess it. The SIZE is fully determined by the ordinal and the site
-- row, so it cannot be wrong in that way; what the room does to it is stated by the rule the readout
-- prints, not by a number that would go stale.
alter table public.combat_encounters
  add column pressure_next_wave_size integer;

comment on column public.combat_encounters.pressure_next_wave_size is
  '0350: how many enemy bodies the NEXT scheduled wave will bring at this fight — 1 + floor(pressure_wave_index / location_pressure.growth_every), bounded by wave_size_ceiling when one is authored. A STAMP, not an input: computed by public.combat_pressure_field and written by public.combat_pressure_step in the same statement that made the spawn decision, and nothing reads it back. It exists so a wave clock can ANNOUNCE the real number without recomputing the band client-side — combat_encounters is already client-readable under combat_encounters_select_own (0014). It is the wave''s SIZE, never a promise of arrival: what actually lands is least(this, the room left on the field), because a wave that finds the field full is spent, not banked. NULL only before this fight has evaluated its first slot.';


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 3 — combat_wave_size: THE ONE PLACE "HOW BIG IS WAVE n" IS DECIDED
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- ██ THE SIGNATURE IS THE PROOF. ██ IMMUTABLE, language sql, three scalar integer arguments and no
-- table reference anywhere in the body. Such a function CANNOT read a kill count, an arrival count,
-- combat_units, waves_cleared or how the fight is going, because it cannot read anything at all. The
-- owner's constraint — destroying an enemy must never cause more enemies — is therefore enforced by
-- the type system here rather than by vigilance, and assert (c) fails the deploy if the volatility or
-- the argument list ever changes.
--
-- THE BANDING, IN ONE EXPRESSION: 1 + floor((n - 1) / period). n=1..3 -> 1, n=4..6 -> 2, n=7..9 -> 3.
-- Integer division truncates toward zero and (n - 1) is never negative on the live branch, so it IS
-- floor. The divisor is `greatest(p_period, 1)` — the column's CHECK already forbids a period below
-- 1, and this is the belt that makes a division-by-zero impossible even if that CHECK is ever
-- relaxed. There is no numeric literal divisor, and assert (d) fails the deploy if one appears.
--
-- n < 1 ANSWERS 0, AND THAT IS A REAL ANSWER, NOT A GUARD. The ordinal is 0 on a fight that has never
-- had a slot come due; "the wave that is due now" is then no wave at all, and 0 is what the spawn
-- decision must see. The NEXT wave is asked for separately, at n + 1, and answers 1.
create function public.combat_wave_size(p_wave_index integer, p_period integer, p_size_ceiling integer)
returns integer
language sql
immutable
as $cws$
  -- ONE derivation, then ONE bound applied TO it. The ceiling is not a second copy of the formula.
  select case when p_size_ceiling is null then b.n else least(b.n, p_size_ceiling) end
    from (
      select case
               when p_wave_index is null or p_wave_index < 1 then 0
               when p_period is null then 1
               else 1 + (p_wave_index - 1) / greatest(p_period, 1)
             end as n
    ) b;
$cws$;

comment on function public.combat_wave_size(integer, integer, integer) is
  'THE ONE AUTHORITY for "how many bodies does scheduled wave n bring" (0350). The owner: "every 3 '
  'wave, i want wave to add one fleet" — so 1 + floor((n - 1) / period): waves 1-3 bring 1, 4-6 bring '
  '2, 7-9 bring 3, bounded by the site''s wave_size_ceiling when one is authored, and 0 for n < 1 '
  '(a fight that has had no slot come due). n is the CLOCK''s scheduled ordinal '
  '(combat_encounters.pressure_wave_index), never a count of arrivals and never waves_cleared: an '
  'arrival-driven counter cannot advance while the field is at its cap, so the wave would grow only '
  'when an enemy DIED — the arrow from a death back into pressure that 0344 deleted. It is IMMUTABLE '
  'with three scalar arguments and reads no table, which makes that independence a property of the '
  'signature rather than a promise in a comment. Composed twice by public.combat_pressure_field (the '
  'wave that is due, and the next one) and by nothing else.';

-- ENGINE INTERNAL. Revoked from PUBLIC BY NAME — the 0309 lesson: a revoke naming only anon and
-- authenticated leaves PUBLIC's default EXECUTE standing. The client's view of the wave size is the
-- STAMP on its own encounter row, which is owner-scoped by RLS.
revoke all on function public.combat_wave_size(integer, integer, integer) from public;
revoke all on function public.combat_wave_size(integer, integer, integer) from anon, authenticated;
grant execute on function public.combat_wave_size(integer, integer, integer) to service_role;


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 4 — combat_pressure_field, RE-MINTED: IT NOW ANSWERS "HOW MANY ARRIVE", NOT "DOES ONE"
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- ⚠ DROPPED AND RE-CREATED RATHER THAN REPLACED, because the return type changes: 0347's
-- `arriving boolean` becomes `arriving_count integer`, and `create or replace` cannot change an OUT
-- column. The boolean is REMOVED rather than kept beside the count — a boolean that is exactly
-- `count > 0` is a second spelling of one fact, and the next caller would pick the wrong one. There
-- is exactly one caller in the whole schema (public.combat_pressure_step, asserted in section 0), so
-- there is nothing else to repoint.
--
-- WHAT CHANGED, EXHAUSTIVELY:
--   1. `arriving boolean` -> `arriving_count integer`, the CLAMPED number of bodies this due slot
--      delivers: least(the wave's size, the room left on the field), floored at 0.
--   2. Two new OUT columns, both from the ONE size authority: `wave_size` (what the wave that is due
--      WANTS) and `next_wave_size` (what the NEXT wave will want — the number a readout announces).
--   3. Nothing else. The clock, the ordinal, the effective cap, the population count, the nominal hp
--      and the ceiling hp are 0347's, character for character, and assert (d) requires the cap
--      expression to still be there unchanged.
--
-- STILL STABLE, STILL SECURITY DEFINER, STILL REVOKED FROM EVERY CLIENT ROLE: it reads
-- combat_encounters, location_pressure, locations, combat_units and game_config and writes nothing.
drop function public.combat_pressure_field(uuid);

create function public.combat_pressure_field(p_encounter uuid)
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
  wave_size       integer,
  next_wave_size  integer,
  arriving_count  integer)
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
  wave_size       := 0;
  next_wave_size  := 0;
  arriving_count  := 0;

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
         lp.growth_every          as r_growth_every,
         lp.cap_ceiling           as r_ceiling,
         lp.wave_size_ceiling     as r_wave_ceiling
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

  -- ── ██ THE SCHEDULED ORDINAL — THE ONE PLACE IT IS COMPUTED ██ (0347, verbatim)
  -- The stored ordinal plus the slots that just came due. It advances on a slot that spawns nothing
  -- exactly as it does on one that spawns a body, which is the whole reason it is a slot count and
  -- not an arrival count: an arrival counter stalls at the cap and can only move again when
  -- something DIES, which is the arrow 0344 deleted and this slice must not re-create.
  wave_index := e.pressure_wave_index + slots_due;

  -- ── ██ THE EFFECTIVE CAP — 0347's expression, unchanged ██
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

  -- ── ██ THE WAVE'S SIZE — ASKED, NEVER COMPUTED HERE ██
  -- Both come from the ONE size authority, at two ordinals: the wave that is due now, and the one
  -- after it. Writing the arithmetic here instead would put the owner's banding in the schema twice.
  wave_size      := public.combat_wave_size(wave_index,     s.r_growth_every, s.r_wave_ceiling);
  next_wave_size := public.combat_wave_size(wave_index + 1, s.r_growth_every, s.r_wave_ceiling);

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

  -- ── ██ THE CLAMP — WHAT ACTUALLY ARRIVES ██
  -- The smaller of what the wave wants and what the field has room for, and NEVER negative. A wave
  -- of three against one slot of room delivers ONE, not nothing: all-or-nothing would mean a big
  -- wave lands only once enough enemies have DIED to open its whole size at once, which is the arrow
  -- from a death back into pressure re-created inside the delivery rule (see the header).
  --
  -- A RETREATING FLEET IS NEVER REINFORCED — 0336's rule, preserved as part of the ANSWER so every
  -- caller gets the same one. The offense gate silences the player during the retreat window while
  -- the enemy side is never gated, so sending a body into that window would be shooting at a fleet
  -- that cannot answer.
  if e.status = 'active' and slots_due > 0 then
    arriving_count := least(wave_size, greatest(effective_cap - population, 0));
  else
    arriving_count := 0;
  end if;

  return next;
end
$cpf$;

comment on function public.combat_pressure_field(uuid) is
  'THE ONE AUTHORITY for "how big is this fight''s field, how big is its next wave, and how many '
  'bodies does the slot that is due deliver" (0347, extended by 0350). Read-only: it writes nothing, '
  'spawns nothing and advances no clock. effective_cap = the site row''s concurrent_cap + '
  'floor(the fight''s SCHEDULED slot ordinal / the site row''s growth_every), bounded by cap_ceiling. '
  'wave_size / next_wave_size come from public.combat_wave_size at the due ordinal and the next one — '
  'the owner''s "every 3 wave, i want wave to add one fleet". arriving_count is the CLAMP: '
  'least(wave_size, the room left), so a wave that exceeds the room delivers what fits and the rest '
  'is lost, never banked. The ordinal counts SLOTS, never arrivals: an arrival-driven counter cannot '
  'advance at the cap, so both the cap and the wave would grow only when an enemy died, which is the '
  'arrow from a death back into pressure that 0344 deleted. Composed by public.combat_pressure_step '
  'for the spawn decision, and by that function alone — the client sees the same numbers as the '
  'STAMPS combat_pressure_step writes onto combat_encounters.pressure_effective_cap and '
  '.pressure_next_wave_size, so no surface recomputes them.';

-- ENGINE INTERNAL. Revoked from PUBLIC BY NAME (0309), re-established after the drop — a dropped
-- function takes its ACL with it, so this is not a repeat of something already true.
revoke all on function public.combat_pressure_field(uuid) from public;
revoke all on function public.combat_pressure_field(uuid) from anon, authenticated;
grant execute on function public.combat_pressure_field(uuid) to service_role;


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 5 — combat_pressure_step: THE WAVE, NOT THE BODY
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SAME NAME, SAME EIGHT ARGUMENTS, SAME THREE OUT PARAMETERS — so the tick is not touched and its two
-- call sites are byte-identical before and after this migration.
--
-- WHAT CHANGED, EXHAUSTIVELY:
--   1. The spawner is handed f.arriving_count instead of the literal 1. That single argument IS the
--      owner's fix. combat_spawn_wave_units already loops over the count and places each body on its
--      own formation slot with its own ingress from the city — verified on the DEPLOYED body in
--      section 0 — so a wave of three arrives as three bodies on three arc points, not a pile and not
--      a second spawn path.
--   2. o_arrived carries the count. The tick's aggregate arm already folds it as
--      `v_pressure_arrived * v_body_hp`, so "n bodies of o_body_hp each" is the contract it always
--      had; section 0 asserts that fold is still there.
--   3. The one UPDATE also stamps pressure_next_wave_size, from the same answer, in the same
--      statement as the clock, the ordinal and the cap stamp.
--   4. The wave_spawned payload gains `wave_size` (what the wave WANTED) beside `units` (what
--      LANDED), so a clamped wave is legible instead of looking like a small one.
--
-- WHAT IS UNCHANGED, AND WHY EACH MATTERS:
--   * 0344's THREE RULES. There is still no branch on a death; still no loop, so nothing is banked;
--     still a cadence that is the site row's column and nothing else. A slot still delivers what it
--     delivers ONCE and is then spent.
--   * The clock arithmetic, the status gate's position, the four enemy stat formulas, the per-wave
--     variance roll and the event's other payload keys are 0347's own, character for character.
--   * ONE HP ROLL PER WAVE. Rolling per body would need a loop here, and a loop in the pressure path
--     is forbidden — it is how banking is written (0344 RULE 2, asserted in (c)).
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

  if f.arriving_count > 0 then
    -- ██ THE WAVE. Its size is the CLOCK's — 1 + floor((ordinal - 1) / the site's period) — clamped
    -- to the room left on the field. Never a count derived from anything the player did.
    v_var     := coalesce(cfg_num('combat_damage_variance_pct'), 0.10);
    o_body_hp := f.body_hp_nominal * ((1 - v_var) + random() * (2 * v_var));
    o_arrived := f.arriving_count;
    if f.bodied then
      perform public.combat_spawn_wave_units(
        e.id, e.player_id, f.unit_type_id, f.arriving_count, o_body_hp,
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
    -- event is emitted here — once, by the authority — rather than at two call sites. `units` is what
    -- LANDED and `wave_size` is what the wave WANTED, so a wave clamped by the field is legible in
    -- the feed instead of being indistinguishable from a smaller one.
    if p_log_events then
      insert into public.combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
        values (e.id, e.player_id, p_tick, coalesce(p_seq, 0), 'wave_spawned', 'pirate', 'player',
                jsonb_build_object('reinforcement', true, 'units', f.arriving_count,
                                   'hp', round(o_body_hp), 'population', f.population + f.arriving_count,
                                   'cap', f.effective_cap, 'wave', f.wave_index,
                                   'wave_size', f.wave_size));
    end if;
  end if;

  -- ██ THE CLOCK, THE ORDINAL AND BOTH STAMPS MOVE TOGETHER OR NOT AT ALL ██
  -- All of them are made from ONE answer, in ONE statement. The clock skips past every elapsed slot
  -- in one step — that is what "a suppressed arrival is LOST, not banked" means — and the ordinal
  -- advances by exactly the same count, so a slot that spawned nothing, or spawned fewer bodies than
  -- its wave wanted, has still been SPENT. This is the only statement in the database that writes
  -- any of the four.
  update public.combat_encounters
     set next_reinforcement_at    = f.due_at + make_interval(secs => f.cadence * f.slots_due),
         pressure_wave_index      = f.wave_index,
         pressure_effective_cap   = f.effective_cap,
         pressure_next_wave_size  = f.next_wave_size,
         updated_at = now()
   where id = e.id;
end;
$cps$;

comment on function public.combat_pressure_step(uuid, integer, double precision, double precision, double precision, double precision, integer, boolean) is
  'THE ONE PLACE ANOTHER ENEMY COMES FROM (0344), repointed by 0347 onto public.combat_pressure_field '
  'and taught by 0350 to deliver a WAVE rather than a body. It reads the SITE, the CLOCK and the '
  'FIELD through that leaf and nothing else — no kill count, no waves_cleared, no wave number, no '
  'elapsed presence. A due slot delivers least(the wave''s size, the room left on the field) bodies '
  'in ONE composition of public.combat_spawn_wave_units, each on its own formation slot out of the '
  'city; what did not fit is spent, never banked; and the SCHEDULED slot ordinal it advances is what '
  'makes both the wave and the cap grow, so neither is ever unlocked by an enemy dying.';

revoke all on function public.combat_pressure_step(uuid, integer, double precision, double precision, double precision, double precision, integer, boolean) from public;
revoke all on function public.combat_pressure_step(uuid, integer, double precision, double precision, double precision, double precision, integer, boolean) from anon, authenticated;


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 6 — EVERY FIGHT ALREADY IN FLIGHT GETS ITS NEXT-WAVE STAMP FROM THE AUTHORITY
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- The ordinal needs no backfill and deliberately gets none — see the header: a fight in flight keeps
-- its schedule, and its next wave is the size its own ordinal says it is.
--
-- The STAMP does need one, or a readout would announce nothing for up to a full cadence on a fight
-- that is already running. It is taken BY CALLING THE AUTHORITY, per encounter, rather than by
-- writing the formula a second time in SQL — that would be exactly the second source of truth this
-- slice exists to prevent. A fight whose site is unauthored is skipped and keeps a NULL stamp, which
-- is the same fail-closed answer the authority gives.
update public.combat_encounters ce
   set pressure_next_wave_size = (select f.next_wave_size from public.combat_pressure_field(ce.id) f)
 where ce.status in ('active', 'retreating')
   and ce.pressure_next_wave_size is null
   and exists (select 1 from public.location_pressure lp where lp.location_id = ce.location_id);


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SELF-ASSERTS — one DO block per check; every prosrc probe strips comments first
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- ⚠ NON-VACUITY IS CHECKED IN EVERY BLOCK. The banners above name the very identifiers asserted
-- ABSENT below, so an un-stripped probe would count prose as code and an over-eager strip would
-- count nothing at all (the 0222 trap, in both directions). Each block proves its probe is live
-- BEFORE it concludes anything from a zero.

-- (a) THE SIZE LEAF EXISTS AND IS ENGINE-INTERNAL
do $a$
declare v_oid oid;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_wave_size';
  if v_oid is null then
    raise exception '0350 ASSERT (a) FAIL: leaf public.combat_wave_size was not created';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'combat_wave_size') <> 1 then
    raise exception '0350 ASSERT (a) FAIL: public.combat_wave_size is overloaded — "how many bodies does wave n bring" must have exactly ONE answer, not one per signature';
  end if;
  if has_function_privilege('anon', v_oid, 'EXECUTE')
     or has_function_privilege('authenticated', v_oid, 'EXECUTE') then
    raise exception '0350 ASSERT (a) FAIL: the size leaf is EXECUTE-able by a client role — it is an engine internal. The client''s view of the wave size is the STAMP on its own encounter row, which is owner-scoped by RLS; a client-callable band function is a second place the number can be derived';
  end if;
  -- ...and the FIELD leaf survived its drop-and-recreate with the same posture, because a dropped
  -- function takes its ACL with it and a re-created one starts from PUBLIC's default EXECUTE.
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_pressure_field';
  if v_oid is null then
    raise exception '0350 ASSERT (a) FAIL: public.combat_pressure_field was dropped and not re-created';
  end if;
  if not exists (select 1 from pg_proc p where p.oid = v_oid
                  and p.provolatile = 's' and p.prosecdef = true
                  and coalesce(array_to_string(p.proconfig, ','), '') = 'search_path=public') then
    raise exception '0350 ASSERT (a) FAIL: the re-created cap authority has the wrong volatility / security / search_path posture — it READS combat_encounters, location_pressure and combat_units and writes nothing, so it must be STABLE and SECURITY DEFINER with a pinned search_path';
  end if;
  if has_function_privilege('anon', v_oid, 'EXECUTE')
     or has_function_privilege('authenticated', v_oid, 'EXECUTE') then
    raise exception '0350 ASSERT (a) FAIL: the re-created cap authority is EXECUTE-able by a client role — the drop took 0347''s revoke with it and this file must re-establish it, not assume it';
  end if;
end $a$;

-- (b) ONE AUTHORITY FOR THE WAVE SIZE
do $b$
declare v_size text; v_zraw text; v_leaf text; v_lraw text; v_step text; v_sraw text; v_n integer; v_probe integer;
begin
  select p.prosrc into v_zraw from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_wave_size';
  v_size := regexp_replace(v_zraw, '--[^' || chr(10) || ']*', '', 'g');
  select p.prosrc into v_lraw from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_pressure_field';
  v_leaf := regexp_replace(v_lraw, '--[^' || chr(10) || ']*', '', 'g');
  select p.prosrc into v_sraw from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_pressure_step';
  v_step := regexp_replace(v_sraw, '--[^' || chr(10) || ']*', '', 'g');
  if length(v_size) < 100 or length(v_size) >= length(v_zraw)
     or length(v_leaf) < 800 or length(v_leaf) >= length(v_lraw)
     or length(v_step) < 800 or length(v_step) >= length(v_sraw) then
    raise exception '0350 ASSERT (b) FAIL: the comment strip produced %/%/% chars from %/%/% char bodies — every count below would be measured against nothing', length(v_size), length(v_leaf), length(v_step), length(v_zraw), length(v_lraw), length(v_sraw);
  end if;

  -- ██ THE BANDING EXPRESSION EXISTS EXACTLY ONCE IN THE WHOLE SCHEMA, AND IT IS IN THE SIZE LEAF.
  -- The sweep CANNOT pass vacuously: it must find combat_wave_size itself, by the same pattern, in
  -- the same query — a pattern that matched nothing would otherwise report "no second copy" while
  -- testing nothing.
  select count(*) filter (where p.proname = 'combat_wave_size')
    into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and position('1 + (p_wave_index - 1) / greatest(p_period, 1)'
                  in regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')) > 0;
  if v_n <> 1 then
    raise exception '0350 ASSERT (b) FAIL: the banding sweep does not find public.combat_wave_size itself — either that function no longer carries the owner''s banding expression (the usual cause: the period was replaced by a NUMERIC LITERAL, which assert (d) also refuses) or the needle has drifted, and either way the "no second copy" sweep below would report a clean world while testing nothing';
  end if;
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname <> 'combat_wave_size'
     and position('1 + (p_wave_index - 1) / greatest(p_period, 1)'
                  in regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')) > 0;
  if v_n <> 0 then
    raise exception '0350 ASSERT (b) FAIL: % other function(s) in public carry the wave-size banding — "every 3 waves adds one" is ONE decision and it gets ONE home, or a UI and an engine come to disagree about how many are coming', v_n;
  end if;

  -- THE FIELD LEAF ASKS, EXACTLY TWICE — the wave that is due, and the next one — AND DERIVES NO
  -- SIZE OF ITS OWN.
  v_n := (length(v_leaf) - length(replace(v_leaf, 'public.combat_wave_size(', ''))) / length('public.combat_wave_size(');
  if v_n <> 2 then
    raise exception '0350 ASSERT (b) FAIL: the cap authority composes the size authority % time(s) (want exactly 2 — the due wave and the next one). A third call is a third ordinal nobody asked about; fewer means one of the two numbers is being derived somewhere else', v_n;
  end if;
  -- EVERY assignment to a size in that body is enumerated, and each one is either the "no answer
  -- yet" default of 0 in the opening block or a call to the size authority. Enumerating rather than
  -- pattern-matching a single shape is what makes this an exhaustive statement: a fifth assignment
  -- of any kind moves the count and aborts, whatever it looks like.
  select count(*) into v_probe
    from regexp_matches(v_leaf, '(?:^|[^_[:alnum:]])(?:next_)?wave_size[[:space:]]*:=[[:space:]]*([^;]*);', 'g') m;
  if v_probe <> 4 then
    raise exception '0350 ASSERT (b) FAIL: the cap authority assigns a wave size % time(s) (want exactly 4 — the two "no answer yet" defaults and the two calls to the authority). A fifth assignment is a size arrived at some other way', v_probe;
  end if;
  select count(*) into v_n
    from regexp_matches(v_leaf, '(?:^|[^_[:alnum:]])(?:next_)?wave_size[[:space:]]*:=[[:space:]]*([^;]*);', 'g') m
   where m[1] !~ '^public\.combat_wave_size\(' and m[1] <> '0';
  if v_n <> 0 then
    raise exception '0350 ASSERT (b) FAIL: % assignment(s) in the cap authority give a wave size a value that is neither 0 nor public.combat_wave_size(...). Every size in this schema comes out of the one authority or it is a second banding', v_n;
  end if;

  -- THE STEP NEVER COMPUTES A SIZE AND NEVER PASSES A LITERAL COUNT TO THE SPAWNER. ██ THIS IS THE
  -- ASSERT THAT FAILS THE DEPLOY ON THE DEFECT THIS MIGRATION EXISTS TO FIX. ██
  if position('f.unit_type_id, f.arriving_count, o_body_hp' in v_step) = 0 then
    raise exception '0350 ASSERT (b) FAIL: the spawn decision does not hand the spawner the CLAMPED arrival count. A literal there is the 0347 defect exactly — the owner: "only 1 ships are comming out from the city, whereas i specifically told you to add 1 fleet every three rounds"';
  end if;
  if v_step ~ 'combat_spawn_wave_units\([^;]*,[[:space:]]*[0-9]+[[:space:]]*,[[:space:]]*o_body_hp' then
    raise exception '0350 ASSERT (b) FAIL: the spawn decision passes a NUMERIC LITERAL as the wave''s body count. How many arrive is the site''s content and the clock''s ordinal, never a number written into a function';
  end if;
  if position('combat_wave_size' in v_step) > 0 or position('growth_every' in v_step) > 0
     or position('wave_size_ceiling' in v_step) > 0 or position('concurrent_cap' in v_step) > 0
     or position('location_pressure' in v_step) > 0 then
    raise exception '0350 ASSERT (b) FAIL: the spawn decision reads the site''s pressure content or the size authority directly — it must ask public.combat_pressure_field for one answer, or there are two places that decide how many bodies a wave brings and they will drift';
  end if;

  -- EXACTLY ONE FUNCTION IN public READS THE SITE'S PERIOD COLUMN, AND IT IS THE FIELD LEAF. Same
  -- non-vacuity shape: the sweep must find the leaf first. (`p_period` is the size leaf's parameter
  -- name precisely so it cannot collide with this needle.)
  select count(*) filter (where p.proname = 'combat_pressure_field')
    into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and position('growth_every' in regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')) > 0;
  if v_n <> 1 then
    raise exception '0350 ASSERT (b) FAIL: the period sweep does not find public.combat_pressure_field itself — it would report "no other readers" while testing nothing';
  end if;
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname <> 'combat_pressure_field'
     and position('growth_every' in regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')) > 0;
  if v_n <> 0 then
    raise exception '0350 ASSERT (b) FAIL: % other function(s) in public read location_pressure.growth_every — the escalation period is read in exactly ONE place and passed on, and a second reader is how a wave size and a cap come to escalate on different schedules', v_n;
  end if;
end $b$;

-- (c) THE WAVE SIZE IS CLOCK-DRIVEN AND CANNOT BE KILL-DERIVED
-- ██ THIS IS THE BLOCK THAT FAILS THE DEPLOY ON THE OWNER'S ABSOLUTE CONSTRAINT: destroying an enemy
-- must never cause more enemies. It is proven twice over — STRUCTURALLY, because the size authority
-- is IMMUTABLE with three scalar arguments and can therefore read nothing at all, and TEXTUALLY,
-- because none of the three bodies may so much as name a kill, an arrival or a wave counter.
do $c$
declare v_size text; v_zraw text; v_leaf text; v_lraw text; v_step text; v_sraw text;
        v_n integer; v_probe integer; v_vol "char"; v_args integer; v_types text;
begin
  select p.prosrc, p.provolatile, p.pronargs,
         coalesce(array_to_string(array(select format_type(t, null) from unnest(p.proargtypes) t), ','), '')
    into v_zraw, v_vol, v_args, v_types
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_wave_size';
  v_size := regexp_replace(v_zraw, '--[^' || chr(10) || ']*', '', 'g');

  -- ██ THE STRUCTURAL PROOF. An IMMUTABLE function may not read a table at all, so a size authority
  -- with this posture is INCAPABLE of seeing a death, a kill count or the state of the fight. Its
  -- arguments are the whole world it can see, and they are the ordinal and two content numbers.
  if v_vol <> 'i' then
    raise exception '0350 ASSERT (c) FAIL: public.combat_wave_size is not IMMUTABLE (provolatile %). Its immutability is not an optimisation — it is the guarantee that the wave size cannot be a function of anything that happens in the fight. A STABLE or VOLATILE body may read combat_units, waves_cleared or a kill count, and the owner has rejected that arrow three times', v_vol;
  end if;
  if v_args <> 3 or v_types <> 'integer,integer,integer' then
    raise exception '0350 ASSERT (c) FAIL: public.combat_wave_size takes % argument(s) of types (%) — want exactly (integer, integer, integer): the CLOCK''s scheduled ordinal, the site''s period and the site''s wave ceiling. Any further argument is a channel through which the fight could reach the wave size', v_args, v_types;
  end if;
  -- ...and it references no relation whatsoever. Broad ABSENCE needles, which is the direction that
  -- is always safe: a wider substring catches more of what must not be there.
  if v_size ~ '(from|join|update|insert|delete)[[:space:]]+(public\.|combat_|location_|game_config)' then
    raise exception '0350 ASSERT (c) FAIL: the size authority names a relation. It answers from its three arguments and nothing else; the moment it reads a table it can read the fight';
  end if;

  select p.prosrc into v_lraw from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_pressure_field';
  v_leaf := regexp_replace(v_lraw, '--[^' || chr(10) || ']*', '', 'g');
  select p.prosrc into v_sraw from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_pressure_step';
  v_step := regexp_replace(v_sraw, '--[^' || chr(10) || ']*', '', 'g');
  if length(v_leaf) < 800 or length(v_leaf) >= length(v_lraw)
     or length(v_step) < 800 or length(v_step) >= length(v_sraw) then
    raise exception '0350 ASSERT (c) FAIL: the comment strip produced %/% chars from %/% char bodies', length(v_leaf), length(v_step), length(v_lraw), length(v_sraw);
  end if;

  -- NON-VACUITY, FIRST: the probe must find the ordinal at all. A regex that matched nothing would
  -- otherwise report an empty world as a clean one.
  v_probe := (length(v_leaf) - length(replace(v_leaf, 'wave_index', ''))) / length('wave_index');
  if v_probe < 4 then
    raise exception '0350 ASSERT (c) FAIL: the ordinal appears % time(s) in the cap authority — the probe is not live and every count below would be meaningless', v_probe;
  end if;

  -- 0347's ORDINAL CHAIN, RE-PROVED END TO END. The wave size is derived from this number, so every
  -- property that made it a schedule rather than a kill ladder is this slice's to keep.
  v_n := (length(v_leaf) - length(replace(v_leaf, 'wave_index := e.pressure_wave_index + slots_due;', '')))
         / length('wave_index := e.pressure_wave_index + slots_due;');
  if v_n <> 1 then
    raise exception '0350 ASSERT (c) FAIL: the cap authority derives the scheduled ordinal from the stored ordinal plus the clock''s slot count % time(s) (want exactly 1). The wave size is a function of that ordinal, so an ordinal computed anywhere else, or from anything else, is a wave size that is no longer the clock''s', v_n;
  end if;
  v_n := (length(v_leaf) - length(replace(v_leaf, 'pressure_wave_index', ''))) / length('pressure_wave_index');
  if v_n <> 1 then
    raise exception '0350 ASSERT (c) FAIL: the cap authority reads the stored ordinal % time(s) (want exactly 1 — the derivation above). A second read is a second rule for what the ordinal means', v_n;
  end if;
  v_n := (length(v_leaf) - length(replace(v_leaf, 'slots_due := floor(extract(epoch from (now() - due_at)) / s.r_cadence)::integer + 1;', '')))
         / length('slots_due := floor(extract(epoch from (now() - due_at)) / s.r_cadence)::integer + 1;');
  if v_n <> 1 then
    raise exception '0350 ASSERT (c) FAIL: the cap authority computes the due-slot count from the clock % time(s) (want exactly 1). The ordinal advances by exactly this number, so a slot count derived from anything but the clock makes both the wave and the cap grow for a reason the owner did not ask for', v_n;
  end if;

  -- NO BODY IN THE PRESSURE PATH MAY NAME A KILL SIGNAL OR AN ARRIVAL. Broad needles, ABSENCE only.
  -- `o_arrived` is the step's own OUT parameter and is deliberately in the list for the two LEAVES:
  -- neither may learn whether a body arrived.
  if position('waves_cleared' in v_leaf) > 0 or position('wave_number' in v_leaf) > 0
     or position('danger' in v_leaf) > 0 or position('o_arrived' in v_leaf) > 0
     or position('arrivals' in v_leaf) > 0 or position('destroyed' in v_leaf) > 0
     or position('secs_inside' in v_leaf) > 0 then
    raise exception '0350 ASSERT (c) FAIL: the cap authority names a kill/wave/arrival signal. Both the ordinal and the wave size must be the CLOCK''s: an arrival-driven counter stalls at the cap and resumes only when an enemy dies, which is the arrow from a death back into pressure that 0344 deleted and the owner has rejected three times';
  end if;
  if position('waves_cleared' in v_size) > 0 or position('wave_number' in v_size) > 0
     or position('danger' in v_size) > 0 or position('o_arrived' in v_size) > 0
     or position('arrivals' in v_size) > 0 or position('destroyed' in v_size) > 0
     or position('secs_inside' in v_size) > 0 then
    raise exception '0350 ASSERT (c) FAIL: the size authority names a kill/wave/arrival signal — it cannot read one, but naming one means the next edit will try';
  end if;
  if position('waves_cleared' in v_step) > 0 or position('wave_number' in v_step) > 0
     or position('danger' in v_step) > 0 or position('secs_inside' in v_step) > 0 then
    raise exception '0350 ASSERT (c) FAIL: the spawn decision names a kill/wave signal';
  end if;
  -- ...and there is no loop in ANY of the three, because a loop is how BANKING is written (0344
  -- RULE 2) and it is also the only way a per-body hp roll could sneak back in.
  if position('loop' in v_leaf) > 0 or position('loop' in v_step) > 0 or position('loop' in v_size) > 0 then
    raise exception '0350 ASSERT (c) FAIL: a loop has appeared in the pressure path — one wave per call and nothing stored, or a suppressed body becomes a debt that a death can call in';
  end if;

  -- THE STEP NAMES THE ORDINAL EXACTLY ONCE — the write — AND THE VALUE IT WRITES IS THE LEAF'S.
  v_n := (length(v_step) - length(replace(v_step, 'pressure_wave_index', ''))) / length('pressure_wave_index');
  if v_n <> 1 then
    raise exception '0350 ASSERT (c) FAIL: the spawn decision names the ordinal % time(s) (want exactly 1 — the write)', v_n;
  end if;
  if v_step !~ 'pressure_wave_index[[:space:]]*=[[:space:]]*f\.wave_index' then
    raise exception '0350 ASSERT (c) FAIL: the spawn decision does not write the ordinal from the authority''s own answer (f.wave_index)';
  end if;

  -- ONE WRITER EACH, ACROSS THE WHOLE SCHEMA, FOR THE ORDINAL AND BOTH STAMPS. Every sweep must find
  -- the step itself, so a pattern that matched nothing fails as a broken pattern rather than passing.
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') ~ 'pressure_wave_index[[:space:]]*=';
  if v_n <> 1 then
    raise exception '0350 ASSERT (c) FAIL: % function(s) in public write pressure_wave_index (want exactly 1, public.combat_pressure_step). One clock, one ordinal, one writer', v_n;
  end if;
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') ~ 'pressure_effective_cap[[:space:]]*=';
  if v_n <> 1 then
    raise exception '0350 ASSERT (c) FAIL: % function(s) in public write pressure_effective_cap (want exactly 1, public.combat_pressure_step)', v_n;
  end if;
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') ~ 'pressure_next_wave_size[[:space:]]*=';
  if v_n <> 1 then
    raise exception '0350 ASSERT (c) FAIL: % function(s) in public write pressure_next_wave_size (want exactly 1, public.combat_pressure_step). The stamp is a PROJECTION of the authority''s answer; a second writer makes it a second opinion', v_n;
  end if;
  -- AND NOTHING READS EITHER STAMP BACK. They are shown, never consumed — a decision that read one
  -- would be reading its own last answer instead of asking the authority.
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname <> 'combat_pressure_step'
     and (position('pressure_effective_cap' in regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')) > 0
       or position('pressure_next_wave_size' in regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')) > 0);
  if v_n <> 0 then
    raise exception '0350 ASSERT (c) FAIL: % other function(s) in public name a pressure stamp — the stamps exist so a CLIENT can show the cap and the next wave''s size without recomputing them, and an engine function that reads one has made a cached number into an input', v_n;
  end if;
end $c$;

-- (d) THE THRESHOLDS ARE DATA — the period and both ceilings are columns, not literals
do $d$
declare v_size text; v_zraw text; v_leaf text; v_lraw text; v_n integer;
begin
  select p.prosrc into v_zraw from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_wave_size';
  v_size := regexp_replace(v_zraw, '--[^' || chr(10) || ']*', '', 'g');
  select p.prosrc into v_lraw from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_pressure_field';
  v_leaf := regexp_replace(v_lraw, '--[^' || chr(10) || ']*', '', 'g');
  if length(v_size) < 100 or length(v_size) >= length(v_zraw)
     or length(v_leaf) < 800 or length(v_leaf) >= length(v_lraw) then
    raise exception '0350 ASSERT (d) FAIL: the comment strip produced %/% chars from %/% char bodies', length(v_size), length(v_leaf), length(v_zraw), length(v_lraw);
  end if;

  -- NO LITERAL DIVISOR IN EITHER LEAF. The only divisions across the two are by the site's period,
  -- by the site's cadence and by one body's nominal hp, so a literal divisor can only be a hardcoded
  -- threshold. Broad ABSENCE needles, which is the direction that is allowed to be broad.
  if v_size ~ '/[[:space:]]*[0-9]' then
    raise exception '0350 ASSERT (d) FAIL: the size authority divides by a numeric literal — "every 3 waves" is CONTENT (location_pressure.growth_every), and a period written into the function is a balance decision nobody can find and nobody can change without a deploy';
  end if;
  if v_leaf ~ '/[[:space:]]*[0-9]' then
    raise exception '0350 ASSERT (d) FAIL: the cap authority divides by a numeric literal — 0347''s finding, still binding';
  end if;
  -- THE CEILINGS ARE READ FROM THE ROW, both of them, and applied by comparison rather than against
  -- some invented maximum.
  if position('p_size_ceiling' in v_size) = 0 then
    raise exception '0350 ASSERT (d) FAIL: the size authority ignores the wave ceiling it is handed — an unbounded growth with no data row to bound it later is the "decide it in code" outcome the header refuses';
  end if;
  if position('s.r_wave_ceiling' in v_leaf) = 0 or position('s.r_ceiling' in v_leaf) = 0 then
    raise exception '0350 ASSERT (d) FAIL: the cap authority does not read one of the site''s two ceilings (location_pressure.cap_ceiling / .wave_size_ceiling)';
  end if;

  -- ██ 0347's CAP ARITHMETIC SURVIVES CHARACTER FOR CHARACTER. The owner was shown its worked
  -- example (3,3,4,4,4,5) and approved it explicitly; this slice fixes a DIFFERENT defect and must
  -- not quietly retune it.
  --
  -- ⚠ EVERY assignment to the effective cap is ENUMERATED, not pattern-matched. A substring count
  -- alone is NOT enough and that was proven, not assumed: a mutation that appends `* 2` to the end of
  -- the derivation leaves the substring intact exactly once and passed a presence count. Only pinning
  -- the WHOLE statement — and requiring that the set of assignments is closed — refuses it.
  select count(*) into v_n
    from regexp_matches(v_leaf, '(?:^|[^_[:alnum:]])effective_cap[[:space:]]*:=[[:space:]]*([^;]*);', 'g') m;
  if v_n <> 4 then
    raise exception '0350 ASSERT (d) FAIL: the cap authority assigns the effective cap % time(s) (want exactly 4 — the NULL default, the no-growth arm, 0347''s derivation and the ceiling clamp). A fifth assignment is a cap arrived at some other way', v_n;
  end if;
  select count(*) into v_n
    from regexp_matches(v_leaf, '(?:^|[^_[:alnum:]])effective_cap[[:space:]]*:=[[:space:]]*([^;]*);', 'g') m
   where m[1] not in ('null', 'base_cap', 's.r_ceiling',
                      'base_cap + floor(wave_index::numeric / s.r_growth_every)::integer');
  if v_n <> 0 then
    raise exception '0350 ASSERT (d) FAIL: % assignment(s) give the effective cap a value that is not one of 0347''s own four. The owner approved that arithmetic explicitly ("yes, cap should grow"); re-tuning it inside a migration about the WAVE would be a second change smuggled into a fix, and this assert refuses the whole statement rather than a substring of it', v_n;
  end if;

  -- AND THE CONTENT IS SHAPED THE WAY THE COLUMNS PROMISE.
  if exists (select 1 from public.location_pressure where growth_every is not null and growth_every < 1) then
    raise exception '0350 ASSERT (d) FAIL: a location_pressure row carries an escalation period below 1 — the CHECK should have made this unreachable';
  end if;
  if exists (select 1 from public.location_pressure where wave_size_ceiling is not null and wave_size_ceiling < 1) then
    raise exception '0350 ASSERT (d) FAIL: a location_pressure row carries a wave ceiling below 1 — a site that may never send a body is a site with no reinforcements, and that is spelled by having no location_pressure row at all';
  end if;
  -- THE OLD NAME IS GONE. Two period columns is the exact disease this rename exists to prevent.
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'location_pressure'
                and column_name = 'cap_growth_every') then
    raise exception '0350 ASSERT (d) FAIL: location_pressure still carries cap_growth_every beside growth_every — one sentence from the owner ("every 3 wave") must be ONE number on the row, or a tuner changes one and ships a half-escalating site';
  end if;
end $d$;

-- (e) NOTHING DARK
do $e$
declare v_n integer; v_keys text;
begin
  -- NO game_config KEY FOR THIS SLICE — asserted ABSENT, not promised. The pattern is narrow on
  -- purpose: many real worldstate_/event_ keys contain "wave", and a broad pattern would make this
  -- assert unsatisfiable rather than strict.
  select count(*), coalesce(string_agg(key, ', '), '') into v_n, v_keys
    from public.game_config
   where key like '%wave_size%' or key like '%wave_growth%' or key like '%growth_every%';
  if v_n <> 0 then
    raise exception '0350 ASSERT (e) FAIL: % game_config key(s) exist for this slice (%) — the escalation period and the wave ceiling are COLUMNS on the site''s content row. A knob beside them would be a second authority, and a knob that could switch the growth off would be the adapter this project has a law against', v_n, v_keys;
  end if;

  -- AND THE OWNER'S RULE IS LIVE AT EVERY REAL SITE. This is the assert that makes shipping it dark
  -- impossible: a NULL period is exactly what "authored but inert" would look like.
  select count(*) into v_n
    from public.location_pressure lp join public.locations l on l.id = lp.location_id
   where l.location_type = 'pirate_hunt' and l.status = 'active';
  if v_n < 3 then
    raise exception '0350 ASSERT (e) FAIL: only % active pirate-hunt site(s) carry a pressure row (want at least the three seeded ones) — the coverage sweep below would be quantifying over a near-empty set and would pass while proving nothing', v_n;
  end if;
  select count(*) into v_n
    from public.location_pressure lp join public.locations l on l.id = lp.location_id
   where l.location_type = 'pirate_hunt' and l.status = 'active'
     and lp.growth_every is null;
  if v_n <> 0 then
    raise exception '0350 ASSERT (e) FAIL: % active pirate-hunt site(s) carry no escalation period — the owner asked for a wave that grows every third round and a NULL there means it never does. That is this slice shipped dark', v_n;
  end if;
  -- AND THE RULE IS ACTUALLY THE ONE HE ASKED FOR, MEASURED THROUGH THE AUTHORITY ITSELF rather than
  -- restated here. Waves 1-3 bring 1, 4-6 bring 2, 7-9 bring 3 — over every live site's own period.
  if exists (
    select 1 from public.location_pressure lp join public.locations l on l.id = lp.location_id
     where l.location_type = 'pirate_hunt' and l.status = 'active' and lp.growth_every = 3
       and (public.combat_wave_size(1, lp.growth_every, lp.wave_size_ceiling) <> 1
         or public.combat_wave_size(3, lp.growth_every, lp.wave_size_ceiling) <> 1
         or public.combat_wave_size(4, lp.growth_every, lp.wave_size_ceiling) <> 2
         or public.combat_wave_size(6, lp.growth_every, lp.wave_size_ceiling) <> 2
         or public.combat_wave_size(7, lp.growth_every, lp.wave_size_ceiling) <> 3
         or public.combat_wave_size(12, lp.growth_every, lp.wave_size_ceiling) <> 4)) then
    raise exception '0350 ASSERT (e) FAIL: at a live site authored "every 3", the size authority does not answer the owner''s own banding (waves 1-3 -> 1, 4-6 -> 2, 7-9 -> 3, 10-12 -> 4). That banding IS the requirement, in his words, and it is checked against real content rather than against a fixture';
  end if;
end $e$;

-- (f) THE TICK IS UNTOUCHED
do $f$
declare v_before text; v_len integer; v_after text; v_code text; v_raw text; v_n integer;
begin
  select body_md5, body_len into v_before, v_len from _0350_tick_before where fname = 'process_combat_ticks';
  if v_before is null or v_len is null or v_len < 40000 then
    raise exception '0350 ASSERT (f) FAIL: no usable pre-image of the tick was captured (md5 %, length %) — the comparison below would be between two nothings', coalesce(v_before, '<null>'), coalesce(v_len, -1);
  end if;
  select p.prosrc, md5(p.prosrc) into v_raw, v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if v_after is distinct from v_before then
    raise exception '0350 ASSERT (f) FAIL: process_combat_ticks changed during this migration (% -> %). This slice changes only the LEAVES the tick already composes, at an identical signature, because eleven generators assert that 0299 is still the newest textual re-create of that function — 0343 broke all eleven at once by re-emitting it', v_before, v_after;
  end if;
  -- ...and it still reaches the authority, twice, at 0344's exact argument list. Without this the
  -- assert above would be satisfied by a tick that had lost the call entirely, as long as it lost it
  -- before this migration started.
  v_code := regexp_replace(v_raw, '--[^' || chr(10) || ']*', '', 'g');
  v_n := (length(v_code) - length(replace(v_code, 'combat_pressure_step(', ''))) / length('combat_pressure_step(');
  if v_n <> 2 then
    raise exception '0350 ASSERT (f) FAIL: the tick composes the pressure authority % time(s) (want exactly 2)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_pressure_step(e.id, v_tick, v_anchor_x, v_anchor_y, loc.x, loc.y, v_seq, v_log_events)', '')))
         / length('public.combat_pressure_step(e.id, v_tick, v_anchor_x, v_anchor_y, loc.x, loc.y, v_seq, v_log_events)');
  if v_n <> 2 then
    raise exception '0350 ASSERT (f) FAIL: % of the tick''s calls to the pressure authority still pass 0344''s arguments (want 2)', v_n;
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
    raise exception '0350 ASSERT (g) FAIL: combat_encounters.pressure_wave_index does not exist';
  end if;
  if not v_notnull or coalesce(v_default, '') <> '0' then
    raise exception '0350 ASSERT (g) FAIL: the ordinal is nullable or its default is % (want NOT NULL DEFAULT 0). Nullability is the whole in-flight contract: the wave size is a function of this number, and a NULL ordinal is a fight whose wave size cannot be computed at all', coalesce(v_default, '<none>');
  end if;
  select count(*) into v_n from public.combat_encounters where pressure_wave_index is null;
  if v_n <> 0 then
    raise exception '0350 ASSERT (g) FAIL: % encounter(s) carry a NULL ordinal', v_n;
  end if;
  select count(*) into v_n
    from public.combat_encounters ce
   where ce.status in ('active', 'retreating')
     and ce.pressure_next_wave_size is null
     and exists (select 1 from public.location_pressure lp where lp.location_id = ce.location_id);
  if v_n <> 0 then
    raise exception '0350 ASSERT (g) FAIL: % in-flight fight(s) at an AUTHORED site carry no next-wave stamp — section 6''s backfill did not reach them, and a wave clock would announce nothing for up to a full cadence', v_n;
  end if;
  -- AND THE BACKFILL AGREES WITH THE AUTHORITY. It was TAKEN from the authority, so a disagreement
  -- here means a second derivation has appeared between section 6 and now.
  select count(*) into v_n
    from public.combat_encounters ce
   where ce.status in ('active', 'retreating')
     and exists (select 1 from public.location_pressure lp where lp.location_id = ce.location_id)
     and ce.pressure_next_wave_size
         is distinct from (select f.next_wave_size from public.combat_pressure_field(ce.id) f);
  if v_n <> 0 then
    raise exception '0350 ASSERT (g) FAIL: % in-flight fight(s) carry a next-wave stamp that differs from what the authority answers for them right now — the stamp is a PROJECTION and a projection that disagrees with its source is a second number', v_n;
  end if;
  raise notice '0350 in-flight: % non-terminal encounter(s); % of them stamped with a next-wave size by section 6',
    (select count(*) from public.combat_encounters where status in ('active','retreating')),
    (select count(*) from public.combat_encounters where status in ('active','retreating') and pressure_next_wave_size is not null);
end $g$;

-- (h) THE READOUT CONTRACT — the next wave's size is REACHABLE by the client, and only as a projection
do $h$
begin
  -- This is the other half of the slice, asserted rather than assumed. A wave clock that ANNOUNCES a
  -- number must read the engine's own; if it cannot, it will recompute the band, and a recomputed
  -- band is a second authority that says "1 ship" while three come out of the city.
  if not has_column_privilege('authenticated', 'public.combat_encounters', 'pressure_next_wave_size', 'SELECT')
     or not has_column_privilege('authenticated', 'public.combat_encounters', 'pressure_effective_cap', 'SELECT')
     or not has_column_privilege('authenticated', 'public.combat_encounters', 'pressure_wave_index', 'SELECT') then
    raise exception '0350 ASSERT (h) FAIL: an authenticated client cannot SELECT the next-wave stamp, the cap stamp or the ordinal on combat_encounters. The readout would then have to derive the band itself, which is exactly the defect this slice exists to prevent';
  end if;
  -- ⚠ WHAT IS DELIBERATELY *NOT* ASSERTED HERE, and 0347 recorded the same finding for the same
  -- reason: production's combat_encounters still carries Supabase's project-default client
  -- INSERT/UPDATE grant from 0014 (measured read-only). It is inert behind RLS — the table has
  -- exactly one policy, combat_encounters_select_own (SELECT) — it predates this slice by three
  -- hundred migrations, and asserting a posture a migration does not ESTABLISH is the 0254 mistake.
  -- Revoking it here would be a slice about a wave size silently changing the privilege surface of
  -- the central combat table. It is REPORTED, not asserted, and it wants its own slice.
  -- What IS asserted is the lockdown 0344 established by REVOKING, on the table this slice renames a
  -- column on and adds a column to — a rename and an ADD must not have reopened it.
  if has_table_privilege('authenticated', 'public.location_pressure', 'INSERT')
     or has_table_privilege('authenticated', 'public.location_pressure', 'UPDATE')
     or has_table_privilege('authenticated', 'public.location_pressure', 'DELETE')
     or has_table_privilege('anon', 'public.location_pressure', 'INSERT')
     or has_table_privilege('anon', 'public.location_pressure', 'UPDATE')
     or has_table_privilege('anon', 'public.location_pressure', 'DELETE') then
    raise exception '0350 ASSERT (h) FAIL: a client role can write location_pressure — 0344 established that lockdown by REVOKING it (the 0254 lesson) and renaming a column must not have reopened it';
  end if;
end $h$;

commit;
