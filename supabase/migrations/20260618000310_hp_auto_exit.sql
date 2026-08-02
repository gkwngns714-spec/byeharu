-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0310 — HP AUTO-EXIT: A FLEET LEAVES COMBAT ON ITS OWN AT THE PLAYER'S HP THRESHOLD
--        (adjustable percentage, and an off switch — the owner's ask, verbatim:
--         "now build the hp auto-exit, make user adjust the percentage. turn off on toggle as well")
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- THE DESIGN LAW THIS IMPLEMENTS (owner, 2026-07-27): "the whole point of this game is never to
-- win, but exit appropriately, by setting HP limitation or something, then it retreats outside the
-- combat zone." Endless escalating waves are CORRECT and intended; the skill is knowing when to
-- leave. Before this migration the ONLY exits from process_combat_ticks were hp<=0 (destroyed), the
-- forced extract at max_presence_seconds, or a human pressing Retreat in time. The owner has lost
-- two fleets to exactly that gap. This is not a win condition and adds none.
--
-- ██ DEFAULT ON AT 30% — A DELIBERATE, PROTECTIVE BEHAVIOUR CHANGE FOR EVERY EXISTING PLAYER ██
-- Every existing ship_groups row receives auto_exit_enabled=true, auto_exit_hp_pct=30 the moment
-- this applies. From the next combat tick onward, any group fleet in a fight whose remaining hull
-- drops to 30% or less of its at-entry total AUTO-REQUESTS the retreat — the same retreat a human
-- press produces, risk window included. A player who wants the old to-the-death behaviour turns the
-- toggle OFF (one call, persisted). Defaulting ON is deliberate: the owner's first instruction was
-- "use 30%", revised to "make it adjustable + a toggle", and the safety line protects the ~30 live
-- players who do not yet know the setting exists. Their in-flight fights pick the rule up on the
-- next tick (the tick reads the setting fresh each pass; no backfill of any encounter row).
--
-- ── STORAGE: ship_groups, NOT fleets ─────────────────────────────────────────────────────────────
-- A fleet is minted FRESH per sortie (0231:687 / :878 / :937 — each hunt/send inserts a new fleets
-- row), so a per-fleet setting would evaporate on every send. ship_groups is the persistent thing
-- the player commands; the tick resolves fleet → group through fleets.group_id, the same tag
-- 0308's roster authority already made routing-bearing.
--   auto_exit_enabled  boolean not null default true
--   auto_exit_hp_pct   numeric  not null default 30, CHECK [5,95]
-- RANGE RATIONALE: 0 would mean "never" — that is the toggle's job, and two spellings of OFF is two
-- authorities; 100 would fire on the first scratch — a retreat before the fight exists. 5 keeps the
-- floor above "already effectively dead"; 95 still requires actually being hit. Everything between
-- is the player's call. NaN/INFINITY: numeric NaN sorts ABOVE every non-NaN value in Postgres, so
-- `x >= 5` ACCEPTS NaN — but `x <= 95` rejects it, 'Infinity' fails the upper bound and
-- '-Infinity' the lower, so the two-sided CHECK is total over every value numeric can store. The
-- self-assert proves that arithmetic BY EVALUATION, not by assumption.
--
-- ── WHERE IT FIRES ───────────────────────────────────────────────────────────────────────────────
-- Inside process_combat_ticks' SPATIAL arm, immediately AFTER the death branch (a dead fleet is
-- dead, not retreating), inside `if not v_wave_paused` (never during the wave pause), reading the
-- tick's own v_hp_after against combat_encounters.player_integrity_max (the at-entry sum(hp_max)
-- the encounter creators wrote — 0301:855-856 / 0301:954). The AGGREGATE arm is deliberately NOT
-- touched: spatial_combat_enabled has been lit since 2026-07-19 and mode is STICKY per encounter
-- (0242/0291 — derived from persisted position rows), so every encounter the live game creates
-- takes the spatial arm; the aggregate arm survives only as the byte-parity path for position-less
-- legacy encounters, and widening this slice into it would double the parity surface of the most
-- re-emitted function in the chain for a path no live fight reaches. If a position-less encounter
-- class ever returns, the auto-exit arm must be composed there in its own slice.
--
-- ── HOW IT FIRES: COMPOSITION, NOT A SECOND RETREAT PATH ─────────────────────────────────────────
-- One call: presence_request_leave(e.presence_id) — the SAME authority the player's Retreat button
-- reaches (0019's request_retreat delegates to it). Verified from source at apply time by the
-- preconditions below: its hunt arm requires an ACTIVE presence, flips it to 'retreating', and
-- calls combat_set_retreating (0022), which sets combat_encounters.status='retreating' +
-- retreat_started_at=now() from 'active' only, and emits the one 'retreat_started' combat event.
-- The tick's existing completion branch (0299:542-544: status='retreating' AND retreat_started_at
-- set AND retreat_delay_seconds elapsed) then ends the fight and mints the return leg EXACTLY as it
-- does for a human press — chosen destination if one was ordered, origin base otherwise — risk
-- window included (v_offense stays false while retreating; the fleet holds fire and keeps taking
-- damage until the window closes). This migration emits NO second event (combat_set_retreating is
-- the one event author), writes NO retreat state directly, and mints NO movement.
--
-- ── THE RACE THIS DOES NOT ADD ───────────────────────────────────────────────────────────────────
-- A player pressing Retreat in the same 3-second tick the auto-exit fires: the player's transaction
-- locks the presence then updates the encounter; the tick holds the encounter row (FOR UPDATE loop)
-- and now touches the presence. That lock shape ALREADY EXISTS in the deployed tick — every
-- conclusion branch calls presence_complete, which writes location_presence under the same held
-- encounter lock — so this adds no new deadlock class. If the rare collision happens, one side
-- retries: the tick's 0206 per-row guard swallows its side (retried next tick), or the player's
-- call lands first and the guard e.status='active' makes the auto-exit a no-op. Either way exactly
-- one retreat is armed.
--
-- ── EVERY CONSUMER CHECKED (the never-ship-half-a-slice ledger) ──────────────────────────────────
--   ship_groups columns: NO `select *` and NO %rowtype reader exists anywhere in the chain or the
--     client (verified by sweep) — every reader names its columns, so two additive columns change
--     no read. Writers: upsert_ship_group (0161 — ON CONFLICT updates name only: a rename PRESERVES
--     these settings), delete_ship_group (0216 — deletes the row: settings die with the fleet the
--     player deleted, correct), and the new set_group_auto_exit below (the sole writer of the two
--     columns). RLS: owner-SELECT policy (0160) exposes the new columns to their owner only — the
--     client reads them to render the control.
--   fleets.group_id: read-only join, the same one 0308's group_sortie_live_members already takes;
--     a nulled tag simply reads zero rows here (no auto-exit), which is the specified behaviour.
--   process_combat_ticks consumers: pg_cron (schedule untouched), and every prosrc-probing harness
--     was swept — the elite-stat proof (no 'elite' token, random( still 2, its anchors untouched),
--     the fallback-weapon proof (0-length-safe loop untouched), and 0299's carried-through pins are
--     re-asserted below (cfg_bool 8, random 2, movement_create 2, three-column retreat read, no
--     fleet_get_power). No harness pins presence_request_leave ABSENT from the tick (swept).
--   client: the Fleets panel gains the toggle + percentage control in the SAME slice (dark-first is
--     suspended by owner order); its read fail-closes on a pre-0310 database (Pages deploys ahead
--     of the migration gate, so the control simply does not render until this applies).
--
-- ── BLAST RADIUS ON LIVE PLAYERS ─────────────────────────────────────────────────────────────────
--   - THE BEHAVIOUR CHANGE IS THE HEADLINE ABOVE: every existing group defaults ON at 30%.
--   - DDL locks: ALTER TABLE ship_groups takes an ACCESS EXCLUSIVE lock on a table of at most 3
--     rows per player; under set local lock_timeout='5s' a collision with a concurrent roster write
--     aborts THIS deploy (fail closed, retry), never the player's call. The add-column carries a
--     non-volatile default → metadata-only, no rewrite.
--   - The tick rewrite is CREATE OR REPLACE — atomic swap; the first tick after commit applies the
--     rule to every active encounter. No encounter/fleet/presence row is written by this file.
--   - New per-tick cost: ONE single-row indexed join (fleets pk → ship_groups pk) per active
--     encounter per tick, only on ticks that reach the spatial bookkeeping.
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
-- Re-apply 0299's process_combat_ticks definition (its section 2, verbatim), then
--   drop function public.set_group_auto_exit(uuid, boolean, numeric);
--   alter table public.ship_groups drop column auto_exit_enabled, drop column auto_exit_hp_pct;
-- Nothing else here writes state. To neutralise WITHOUT a deploy: the client can set every group's
-- toggle off (per player), or leave the columns and re-emit the tick without the arm.
--
-- ── SELF-ASSERT MAP (one DO block per check — the statement number IS the diagnosis) ─────────────
--   (a) columns exist with the right types, defaults and the two-sided CHECK
--   (b) the CHECK's arithmetic excludes NaN and both infinities — proven BY EVALUATION
--   (c) set_group_auto_exit exists, is callable, validates, and composes the ONE group resolver
--   (d) ACLs: the RPC is authenticated-only; the tick stays engine-only
--   (e) tick: the auto-exit arm is present, guarded, and composes presence_request_leave ONCE
--   (f) tick: the arm sits inside the not-wave-paused spatial bookkeeping, after the death branch
--   (g) tick: no second retreat authority was acquired (no direct status/event/timestamp writes)
--   (h) tick: every carried-through 0298/0299 invariant survives the re-emission
--   (i) metadata parity: the tick changed body and NOTHING else
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ── 0. PRECONDITIONS (read-only) — refuse to build on a base we did not slice from ───────────────
do $pre$
declare
  v_tick text;
  v_prl  text;
  v_csr  text;
begin
  if to_regclass('public.ship_groups') is null or to_regclass('public.fleets') is null then
    raise exception '0310 PRECONDITION FAIL: ship_groups/fleets is absent';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'ship_groups'
                and column_name in ('auto_exit_enabled', 'auto_exit_hp_pct')) then
    raise exception '0310 PRECONDITION FAIL: an auto_exit column already exists on ship_groups — this migration must not re-run or land over an unknown edit';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fleets' and column_name = 'group_id') then
    raise exception '0310 PRECONDITION FAIL: fleets.group_id is missing — the fleet→group resolution this slice reads does not exist';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'combat_encounters' and column_name = 'player_integrity_max') then
    raise exception '0310 PRECONDITION FAIL: combat_encounters.player_integrity_max is missing (0022) — the threshold has no denominator';
  end if;
  if to_regprocedure('public.process_combat_ticks()') is null
     or to_regprocedure('public.presence_request_leave(uuid)') is null
     or to_regprocedure('public.combat_set_retreating(uuid)') is null
     or to_regprocedure('public.mainship_resolve_owned_group(uuid,uuid)') is null then
    raise exception '0310 PRECONDITION FAIL: a function this migration composes is missing';
  end if;

  -- THE COMPOSED AUTHORITY DOES WHAT THIS SLICE CLAIMS — verified from the DEPLOYED source, not
  -- from memory. presence_request_leave's hunt arm must demand an ACTIVE presence, flip it to
  -- 'retreating', and delegate to combat_set_retreating; combat_set_retreating must stamp
  -- retreat_started_at from 'active' only — that pair is exactly what makes the tick's completion
  -- branch (0299:542-544) finish an auto-exit like a human press.
  select prosrc into v_prl from pg_proc where oid = 'public.presence_request_leave(uuid)'::regprocedure;
  if position('combat_set_retreating' in v_prl) = 0
     or position('status = ''retreating''' in v_prl) = 0
     or position('retreat_requested_at = now()' in v_prl) = 0 then
    raise exception '0310 PRECONDITION FAIL: presence_request_leave does not carry the 0018 combat-retreat arm this slice composes';
  end if;
  select prosrc into v_csr from pg_proc where oid = 'public.combat_set_retreating(uuid)'::regprocedure;
  if position('retreat_started_at = now()' in v_csr) = 0
     or position('and status = ''active''' in v_csr) = 0 then
    raise exception '0310 PRECONDITION FAIL: combat_set_retreating does not stamp retreat_started_at from active-only — the completion coupling this slice relies on is gone';
  end if;

  select prosrc into v_tick from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if position('presence_request_leave' in v_tick) > 0 or position('auto_exit' in v_tick) > 0 then
    raise exception '0310 PRECONDITION FAIL: the deployed tick already carries retreat-arming or auto-exit code — refusing to re-emit over an unknown edit';
  end if;
  if position('v_retreat_done := e.status=''retreating'' and e.retreat_started_at is not null' in v_tick) = 0 then
    raise exception '0310 PRECONDITION FAIL: the deployed tick does not carry the 0299 completion branch this slice composes with';
  end if;
  if position('public.combat_encounter_side_power(e.id, ''player'')' in v_tick) = 0 then
    raise exception '0310 PRECONDITION FAIL: the deployed tick is not the 0299 head (the snapshot-power authority is absent) — refusing to slice-and-replace an unknown base';
  end if;
end $pre$;

-- ── 1. STORAGE — the persistent, player-owned setting, on the thing the player commands ─────────
alter table public.ship_groups
  add column auto_exit_enabled boolean not null default true,
  add column auto_exit_hp_pct  numeric not null default 30
    constraint ship_groups_auto_exit_hp_pct_range
    check (auto_exit_hp_pct >= 5 and auto_exit_hp_pct <= 95);

comment on column public.ship_groups.auto_exit_enabled is
  'HP AUTO-EXIT toggle (0310). ON: any fleet of this group in combat auto-requests the canonical '
  'retreat (presence_request_leave — the same one the Retreat button reaches) the first tick its '
  'remaining hull is at or below auto_exit_hp_pct percent of its at-entry total. OFF: the fleet '
  'fights until destroyed, force-extracted, or manually retreated — exactly the pre-0310 world. '
  'Default TRUE for every group, deliberately: this is the safety line of a game whose combat has '
  'no win state. Sole writer: set_group_auto_exit.';
comment on column public.ship_groups.auto_exit_hp_pct is
  'HP AUTO-EXIT threshold percent (0310), CHECK [5,95]. 0 and 100 are deliberately unreachable: '
  '"never" is the toggle''s job (one authority for OFF), and 100 would retreat on the first '
  'scratch. The two-sided CHECK also excludes numeric NaN (sorts above every value, fails the '
  'upper bound) and both infinities. Read fresh by process_combat_ticks every tick, so a mid-fight '
  'adjustment applies on the next tick. Sole writer: set_group_auto_exit.';

-- ── 2. THE ONE WRITER — owner-scoped, actor from auth.uid(), never from an argument ──────────────
-- (0309 had to revoke a function that took the actor as a parameter; this one never does.)
create or replace function public.set_group_auto_exit(p_group_id uuid, p_enabled boolean, p_pct numeric)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_player uuid := auth.uid();
  v_group  uuid;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;
  -- gate FIRST — reject-before-read, the 0161 roster-write posture, same gate as every group write.
  if not public.cfg_bool('team_command_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'team_command_disabled');
  end if;
  -- Validate IN THE RPC exactly as strictly as the table CHECK (never accept-then-violate). The
  -- client's own bounds are UX only; this is the authority. NaN fails the <= arm (numeric NaN
  -- sorts above every value), 'Infinity' fails <=, '-Infinity' fails >= — the double-bounded
  -- predicate is total, so no separate finiteness test is needed.
  if p_enabled is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid_auto_exit_toggle');
  end if;
  if p_pct is null or not (p_pct >= 5 and p_pct <= 95) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_auto_exit_pct');
  end if;
  -- Resolve the group through the ONE owned-group resolver (0161) — same-player by construction,
  -- fail closed on anything else. Never a second resolution authority.
  v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
  if v_group is null then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;
  update public.ship_groups
     set auto_exit_enabled = p_enabled, auto_exit_hp_pct = p_pct, updated_at = now()
   where group_id = v_group and player_id = v_player;
  return jsonb_build_object('ok', true, 'group_id', v_group,
                            'auto_exit_enabled', p_enabled, 'auto_exit_hp_pct', p_pct);
end $fn$;

comment on function public.set_group_auto_exit(uuid, boolean, numeric) is
  'THE one writer of ship_groups.auto_exit_enabled / auto_exit_hp_pct (0310). Owner-scoped: actor '
  'from auth.uid() (never an argument), group re-resolved against that player through '
  'mainship_resolve_owned_group, percentage validated server-side to the table CHECK''s exact '
  '[5,95] bounds. Deliberately NOT refused mid-sortie: the tick reads the setting fresh each pass, '
  'so adjusting the threshold during a fight is a feature — "exit appropriately" is a live call.';

-- ACLs: client-callable (that is its purpose), explicitly revoked from everything else
-- (the 0254 prod grant-drift lesson: REVOKE, never merely assert).
revoke execute on function public.set_group_auto_exit(uuid, boolean, numeric) from public, anon;
grant  execute on function public.set_group_auto_exit(uuid, boolean, numeric) to authenticated;

-- ── 3. CAPTURE METADATA BEFORE THE REWRITE (for parity check i) ──────────────────────────────────
create temp table _0310_before (
  fname text primary key, body_md5 text, owner text, secdef boolean, volatility "char",
  parallel "char", proconfig text, args text, result text, acl text
) on commit drop;

insert into _0310_before
select p.proname, md5(p.prosrc), pg_get_userbyid(p.proowner), p.prosecdef, p.provolatile,
       p.proparallel, coalesce(array_to_string(p.proconfig, ','), ''),
       pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid),
       coalesce(p.proacl::text, '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'process_combat_ticks';

-- ── 4. REWRITE THE ONE HUNK (located by exact deployed text, never retyped) ──────────────────────
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
    (1, 'process_combat_ticks',
     $h1o$          perform report_create(e.id);
        end if;

        v_count := v_count + 1;
      end if; -- not v_wave_paused$h1o$,
     $h1n$          perform report_create(e.id);
        end if;

        -- ── ★ 0310 HP AUTO-EXIT — the owner's core combat law, in the engine at last ★ ──────────
        -- "the whole point of this game is never to win, but exit appropriately, by setting HP
        -- limitation or something, then it retreats outside the combat zone." Waves are endless BY
        -- DESIGN; the skill is leaving in time. Until 0310 the only exits were death (the branch
        -- directly above), the forced extract, or a human pressing Retreat within the window.
        --
        -- COMPOSED, NOT RE-IMPLEMENTED: presence_request_leave(presence) is the SAME authority the
        -- Retreat button reaches (0019's request_retreat delegates to it). Its hunt arm flips the
        -- presence to 'retreating' and calls combat_set_retreating (0022), which stamps
        -- status='retreating' + retreat_started_at and emits the ONE retreat_started event; branch
        -- (B) above then completes the retreat after retreat_delay_seconds exactly as for a human
        -- press. No second retreat path, no status write here, no movement minted here, no event
        -- emitted here.
        --
        -- GUARDS, each load-bearing:
        --   e.status = 'active'       — never re-request on an encounter already 'retreating'; the
        --                               idempotency across ticks (once this fires the encounter IS
        --                               'retreating', so this arm is unreachable until it ends).
        --   pr.status = 'active'      — presence_request_leave RAISES on a non-active presence and
        --                               a raise would roll back this encounter's whole tick (the
        --                               0206 per-row guard would catch it, but a guard is not a
        --                               license to throw).
        --   v_hp_after > 0            — a dead fleet is dead, not retreating: the death branch
        --                               above already concluded the encounter (its update is not
        --                               visible in the stale e record, so this local is the
        --                               truth).
        --   found and v_ae_on         — a fleet with no group tag, a group row that is gone, or
        --                               the toggle OFF behaves EXACTLY as before 0310.
        --   player_integrity_max > 0  — the denominator, NOT NULL (0022) and written only by the
        --                               two encounter creators as sum(hp_max) over the seeded
        --                               roster; 0 means an empty roster, which the empty-manifest
        --                               guard (0303) and the hunt's member checks refuse upstream —
        --                               here it simply never fires.
        --   auto_exit_hp_pct          — CHECK-constrained to [5,95] on ship_groups; numeric NaN
        --                               sorts ABOVE every value so NaN fails the upper bound, and
        --                               both infinities fail a bound each — the comparison below is
        --                               total over every storable value.
        -- Sited inside the not-v_wave_paused arm on purpose: never during the wave pause. Read fresh
        -- every tick on purpose: adjusting the threshold MID-FIGHT is the point of the feature.
        if e.status = 'active' and pr.status = 'active' and v_hp_after > 0 then
          declare
            v_ae_on  boolean;
            v_ae_pct numeric;
          begin
            select g.auto_exit_enabled, g.auto_exit_hp_pct
              into v_ae_on, v_ae_pct
              from fleets f
              join ship_groups g on g.group_id = f.group_id
             where f.id = e.fleet_id;
            if found and v_ae_on
               and e.player_integrity_max > 0
               and v_hp_after <= e.player_integrity_max * (v_ae_pct / 100.0) then
              perform presence_request_leave(e.presence_id);
            end if;
          end;
        end if;

        v_count := v_count + 1;
      end if; -- not v_wave_paused$h1n$)
    ) as t(idx, fname, old_t, new_t)
    order by idx
  loop
    select p.oid into v_oid
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = r.fname;
    if v_oid is null then
      raise exception '0310 REWRITE FAIL [%]: function public.% not found', r.idx, r.fname;
    end if;
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = r.fname) <> 1 then
      raise exception '0310 REWRITE FAIL [%]: public.% is overloaded — refusing to guess', r.idx, r.fname;
    end if;

    v_src := pg_get_functiondef(v_oid);
    v_n := (length(v_src) - length(replace(v_src, r.old_t, ''))) / length(r.old_t);
    if v_n <> 1 then
      raise exception '0310 REWRITE FAIL [%]: hunk text occurs % time(s) in public.%, expected exactly 1 — the deployed body is not what this migration was generated against',
        r.idx, v_n, r.fname;
    end if;

    v_new := replace(v_src, r.old_t, r.new_t);
    if length(v_new) <> length(v_src) - length(r.old_t) + length(r.new_t) then
      raise exception '0310 REWRITE FAIL [%]: unexpected length delta rewriting public.%', r.idx, r.fname;
    end if;
    execute v_new;
    v_done := v_done + 1;
  end loop;

  if v_done <> 1 then
    raise exception '0310 REWRITE FAIL: rewrote % site(s), expected 1', v_done;
  end if;
  raise notice '0310: composed the HP auto-exit arm into process_combat_ticks'' spatial bookkeeping';
end $rewrite$;

-- ── 5. SELF-ASSERTS — one DO block per check; every prosrc probe strips comments first ───────────

-- (a) columns exist with the right types, defaults and the two-sided CHECK
do $a$
declare v_def text;
begin
  -- is_nullable is the SQL-standard 'YES'/'NO' (uppercase) — the lowercase spelling never matches
  -- and failed this assert's first CI run; the fix is the literal, recorded here so it stays.
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'ship_groups'
                    and column_name = 'auto_exit_enabled' and data_type = 'boolean'
                    and is_nullable = 'NO' and column_default = 'true') then
    raise exception '0310 ASSERT (a) FAIL: auto_exit_enabled is not boolean NOT NULL DEFAULT true';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'ship_groups'
                    and column_name = 'auto_exit_hp_pct' and data_type = 'numeric'
                    and is_nullable = 'NO') then
    raise exception '0310 ASSERT (a) FAIL: auto_exit_hp_pct is not numeric NOT NULL';
  end if;
  if (select column_default from information_schema.columns
       where table_schema = 'public' and table_name = 'ship_groups'
         and column_name = 'auto_exit_hp_pct') not in ('30', '30::numeric', '''30''::numeric') then
    raise exception '0310 ASSERT (a) FAIL: auto_exit_hp_pct default is % (want 30)',
      (select column_default from information_schema.columns
        where table_schema = 'public' and table_name = 'ship_groups' and column_name = 'auto_exit_hp_pct');
  end if;
  select pg_get_constraintdef(oid) into v_def
    from pg_constraint where conname = 'ship_groups_auto_exit_hp_pct_range' and convalidated;
  if v_def is null then
    raise exception '0310 ASSERT (a) FAIL: ship_groups_auto_exit_hp_pct_range is missing or not validated';
  end if;
  if position('auto_exit_hp_pct >=' in v_def) = 0 or position('auto_exit_hp_pct <=' in v_def) = 0
     or position('5' in v_def) = 0 or position('95' in v_def) = 0 then
    raise exception '0310 ASSERT (a) FAIL: the CHECK is not the two-sided [5,95] predicate: %', v_def;
  end if;
end $a$;

-- (b) the CHECK's arithmetic excludes NaN and both infinities — proven BY EVALUATION, because
--     Postgres orders numeric NaN above every value and a one-sided `> 0` would ACCEPT it.
do $b$
begin
  if ('NaN'::numeric >= 5 and 'NaN'::numeric <= 95) then
    raise exception '0310 ASSERT (b) FAIL: the [5,95] predicate accepts NaN — the threshold comparison would never fire';
  end if;
  if ('Infinity'::numeric >= 5 and 'Infinity'::numeric <= 95) then
    raise exception '0310 ASSERT (b) FAIL: the [5,95] predicate accepts Infinity';
  end if;
  if ('-Infinity'::numeric >= 5 and '-Infinity'::numeric <= 95) then
    raise exception '0310 ASSERT (b) FAIL: the [5,95] predicate accepts -Infinity';
  end if;
  if (4::numeric >= 5 and 4::numeric <= 95) or (96::numeric >= 5 and 96::numeric <= 95) then
    raise exception '0310 ASSERT (b) FAIL: the [5,95] predicate accepts an out-of-range value';
  end if;
  if not (5::numeric >= 5 and 5::numeric <= 95) or not (30::numeric >= 5 and 30::numeric <= 95)
     or not (95::numeric >= 5 and 95::numeric <= 95) then
    raise exception '0310 ASSERT (b) FAIL: the [5,95] predicate rejects an in-range value';
  end if;
end $b$;

-- (c) the writer exists, is callable, validates, and composes the ONE group resolver
do $c$
declare v_code text; v_res jsonb;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'set_group_auto_exit';
  if v_code is null then
    raise exception '0310 ASSERT (c) FAIL: set_group_auto_exit is missing';
  end if;
  if position('auth.uid()' in v_code) = 0 then
    raise exception '0310 ASSERT (c) FAIL: the writer does not derive the actor from auth.uid()';
  end if;
  if position('mainship_resolve_owned_group' in v_code) = 0 then
    raise exception '0310 ASSERT (c) FAIL: the writer does not compose the ONE owned-group resolver';
  end if;
  if position('team_command_disabled' in v_code) = 0 or position('invalid_auto_exit_pct' in v_code) = 0
     or position('p_pct >= 5 and p_pct <= 95' in v_code) = 0 then
    raise exception '0310 ASSERT (c) FAIL: the writer lost its gate or its server-side bounds';
  end if;
  if not exists (select 1 from pg_proc p
                  where p.oid = 'public.set_group_auto_exit(uuid, boolean, numeric)'::regprocedure
                    and p.prosecdef
                    and exists (select 1 from unnest(p.proconfig) cfg where cfg = 'search_path=public')) then
    raise exception '0310 ASSERT (c) FAIL: the writer is not SECURITY DEFINER with a pinned search_path';
  end if;
  -- callable probe: unauthenticated (no jwt claims in a migration) → the typed envelope, no write.
  select public.set_group_auto_exit(gen_random_uuid(), true, 30) into v_res;
  if (v_res->>'ok')::boolean is not false or v_res->>'reason' is distinct from 'not_authenticated' then
    raise exception '0310 ASSERT (c) FAIL: the unauthenticated probe answered % (want ok:false/not_authenticated)', v_res;
  end if;
end $c$;

-- (d) ACLs: the writer is authenticated-only; the tick stays engine-only
do $d$
begin
  if not has_function_privilege('authenticated', 'public.set_group_auto_exit(uuid, boolean, numeric)', 'execute') then
    raise exception '0310 ASSERT (d) FAIL: authenticated cannot call set_group_auto_exit — the control would be dead';
  end if;
  if has_function_privilege('anon', 'public.set_group_auto_exit(uuid, boolean, numeric)', 'execute') then
    raise exception '0310 ASSERT (d) FAIL: anon can call set_group_auto_exit';
  end if;
  if has_function_privilege('authenticated', 'public.process_combat_ticks()', 'execute')
     or has_function_privilege('anon', 'public.process_combat_ticks()', 'execute') then
    raise exception '0310 ASSERT (d) FAIL: process_combat_ticks became client-executable';
  end if;
end $d$;

-- (e) tick: the auto-exit arm is present, guarded, and composes presence_request_leave ONCE
do $e$
declare v_code text; v_n integer;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  v_n := (length(v_code) - length(replace(v_code, 'presence_request_leave(e.presence_id)', '')))
         / length('presence_request_leave(e.presence_id)');
  if v_n <> 1 then
    raise exception '0310 ASSERT (e) FAIL: the tick composes presence_request_leave % time(s), want exactly 1', v_n;
  end if;
  if position('if e.status = ''active'' and pr.status = ''active'' and v_hp_after > 0 then' in v_code) = 0 then
    raise exception '0310 ASSERT (e) FAIL: the auto-exit arm lost its status/liveness guard — it could re-request on a retreating encounter or throw on a non-active presence';
  end if;
  if position('e.player_integrity_max > 0' in v_code) = 0 then
    raise exception '0310 ASSERT (e) FAIL: the denominator guard is gone — a zero at-entry integrity would make the comparison vacuous or wrong';
  end if;
  if position('v_hp_after <= e.player_integrity_max * (v_ae_pct / 100.0)' in v_code) = 0 then
    raise exception '0310 ASSERT (e) FAIL: the threshold predicate is not the specified one';
  end if;
  if position('join ship_groups g on g.group_id = f.group_id' in v_code) = 0 then
    raise exception '0310 ASSERT (e) FAIL: the setting is not resolved fleet→group through fleets.group_id';
  end if;
  if position('auto_exit_enabled' in v_code) = 0 or position('auto_exit_hp_pct' in v_code) = 0 then
    raise exception '0310 ASSERT (e) FAIL: the tick does not read the group''s auto-exit setting';
  end if;
end $e$;

-- (f) tick: the arm sits INSIDE the not-wave-paused spatial bookkeeping, AFTER the death branch and
--     BEFORE the aggregate arm — never during the wave pause, never before death is decided.
do $f$
declare v_code text; v_at integer;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  v_at := position('presence_request_leave(e.presence_id)' in v_code);
  if v_at < position('if not v_wave_paused then' in v_code) then
    raise exception '0310 ASSERT (f) FAIL: the auto-exit arm sits before the not-wave-paused gate — it could fire during the wave pause';
  end if;
  -- the first status='defeat' write in the body is the SPATIAL death branch (branch (A)''s carries
  -- tick_number between status and ended_at, so it cannot match this literal).
  if v_at < position('update combat_encounters set status=''defeat'', ended_at=now()' in v_code) then
    raise exception '0310 ASSERT (f) FAIL: the auto-exit arm sits before the spatial death branch — a dead fleet could be asked to retreat';
  end if;
  if v_at > position('perform fleet_sync_quantities(e.fleet_id, v_counts);' in v_code) then
    raise exception '0310 ASSERT (f) FAIL: the auto-exit arm landed in the aggregate arm — the deliberate spatial-only scope drifted';
  end if;
end $f$;

-- (g) tick: no second retreat authority was acquired — the arm may only ASK, never write
do $g$
declare v_code text;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if position('combat_set_retreating' in v_code) > 0 then
    raise exception '0310 ASSERT (g) FAIL: the tick calls combat_set_retreating directly — presence_request_leave is the single retreat authority';
  end if;
  if position('set status = ''retreating''' in v_code) > 0
     or position('retreat_requested_at' in v_code) > 0 then
    raise exception '0310 ASSERT (g) FAIL: the tick writes retreat state directly — a second retreat path';
  end if;
  if position('''retreat_started''' in v_code) > 0 then
    raise exception '0310 ASSERT (g) FAIL: the tick emits its own retreat event — combat_set_retreating is the one event author';
  end if;
end $g$;

-- (h) tick: every carried-through 0298/0299 invariant survives the re-emission
do $h$
declare v_code text; v_n integer; v_tok text;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if position('fleet_get_power' in v_code) > 0 then
    raise exception '0310 ASSERT (h) FAIL: fleet_get_power is back in the tick (0299 reverted)';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_encounter_side_power(e.id, ''player'')', '')))
         / length('public.combat_encounter_side_power(e.id, ''player'')');
  if v_n <> 2 then
    raise exception '0310 ASSERT (h) FAIL: % of 2 power writes read the 0299 authority', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'cfg_bool(', ''))) / length('cfg_bool(');
  if v_n <> 8 then
    raise exception '0310 ASSERT (h) FAIL: the tick carries % cfg_bool call(s) (want the 0299 head''s 8 — this slice adds no gate)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'random(', ''))) / length('random(');
  if v_n <> 2 then
    raise exception '0310 ASSERT (h) FAIL: the tick carries % random( call(s) (want the head''s 2)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'movement_create(', ''))) / length('movement_create(');
  if v_n <> 2 then
    raise exception '0310 ASSERT (h) FAIL: the tick mints % movement leg(s) (want the head''s 2 — the auto-exit arm mints none)', v_n;
  end if;
  foreach v_tok in array array[
      'select f.retreat_target_location_id, f.retreat_target_x, f.retreat_target_y',
      'v_is_spatial := exists (select 1 from combat_units where encounter_id = e.id and pos_x is not null)',
      'v_retreat_done := e.status=''retreating'' and e.retreat_started_at is not null',
      'if e.next_wave_at is not null and now() < e.next_wave_at then',
      'when query_canceled then raise;'
    ] loop
    if position(v_tok in v_code) = 0 then
      raise exception '0310 ASSERT (h) FAIL: the tick lost a pinned head guarantee (%) — a stale-base re-emission', v_tok;
    end if;
  end loop;
  if position('select f.retreat_target_location_id into v_ret_loc from fleets f where f.id = e.fleet_id;' in v_code) > 0 then
    raise exception '0310 ASSERT (h) FAIL: 0292''s superseded single-column retreat read is back — a pre-0298 base';
  end if;
end $h$;

-- (i) metadata parity: the tick changed body and NOTHING else
do $i$
declare b record; a record; v_n integer := 0;
begin
  for b in select * from _0310_before loop
    select md5(p.prosrc) as body_md5, pg_get_userbyid(p.proowner) as owner, p.prosecdef as secdef,
           p.provolatile as volatility, p.proparallel as parallel,
           coalesce(array_to_string(p.proconfig, ','), '') as proconfig,
           pg_get_function_identity_arguments(p.oid) as args, pg_get_function_result(p.oid) as result,
           coalesce(p.proacl::text, '') as acl
      into a
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = b.fname;
    if a.owner is distinct from b.owner or a.secdef is distinct from b.secdef
       or a.volatility is distinct from b.volatility or a.parallel is distinct from b.parallel
       or a.proconfig is distinct from b.proconfig or a.args is distinct from b.args
       or a.result is distinct from b.result or a.acl is distinct from b.acl then
      raise exception '0310 ASSERT (i) FAIL: public.% changed metadata across the rewrite', b.fname;
    end if;
    if a.body_md5 = b.body_md5 then
      raise exception '0310 ASSERT (i) FAIL: public.% body is byte-identical — the hunk did not land', b.fname;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n <> 1 then
    raise exception '0310 ASSERT (i) FAIL: parity-checked % function(s), expected 1', v_n;
  end if;
  raise notice '0310 SELF-ASSERT PASS: the HP auto-exit is live — default ON at 30 percent, player-adjustable [5,95], toggleable, composed through the one retreat authority';
end $i$;

commit;
