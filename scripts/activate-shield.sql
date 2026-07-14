-- SHIELD ACTIVATION — the regenerating-shield flip (docs/ACTIVATION_GUIDE.md → ACT-SHIELD; the
-- SHIELD charter's human activation step, promised by SHIELD-0/1/2). The shield stack is FULLY
-- BUILT DARK across three migrations — 0191 (schema + the sync leaf + the two regen knobs), 0195
-- (the in-combat tick: snapshot + absorb-first + the gated ship-row sync), 0197 (the out-of-combat
-- regen home + the commission born-full copy) — and is DATA-GATED, deliberately with NO
-- shield_enabled flag: every hull's base_shield is 0, every instance is 0/0, and both regen knobs
-- are the committed seed '0'. Nothing shields anything until THIS script raises the data + knobs.
--
-- ██ HUMAN ACTIVATION TOOL ██ — run BY THE HUMAN, deliberately, against prod. NOT CI; nothing flips
-- at build/deploy time. Each run of this file IS the recorded human go decision. ██ NOTE: unlike
-- the flag-flip activators, this one WRITES DATA (hull base_shield + a monotonic instance backfill)
-- because the shield system is data-gated, not flag-gated — that is the SHIELD-0 activation story.
--
-- ── WHAT IT DOES (one transaction; COMMIT only if every assert passes) ────────────────────────────
--   PRECONDITIONS (no write until these hold):
--     • migration head >= 20260618000197 AND 0191 / 0195 / 0197 all recorded as deployed;
--     • the shield columns exist (main_ship_hull_types.base_shield; main_ship_instances.shield /
--       max_shield);
--     • the function surface exists via to_regprocedure — the sync leaf + the two engine bodies the
--       shields ride, and cfg/set_game_config;
--     • the DEPLOYED bodies are the current heads, prosrc-pinned: the 0191 leaf carries BOTH clamps
--       and writes shield only; the 0195 tick carries the ONE absorb point + the combat regen knob
--       read; the 0197 reconciler carries the guarded idle-regen set-statement + the idle knob read;
--     • both regen knobs currently read the dark seed '0' (this is a FIRST-FLIP tool — see RE-RUN);
--     • the three seeded hulls (starter_frigate / bulk_hauler / strike_corvette) exist so the
--       per-hull base_shield seed lands on a real row.
--   STAGE 1 — the per-hull base_shield seed (MONOTONIC — only ever RAISES a hull's base_shield,
--     never lowers): starter_frigate 100, bulk_hauler 130, strike_corvette 85. [D — OWNER-TUNABLE:
--     edit the three numbers below before running. Sparrow=100 / Mule=130 / Talon=85 are the
--     charter proposals.]
--   STAGE 2 — the MONOTONIC instance backfill (the deferred-bump idiom, the 0171 never-lower
--     posture): every existing ship whose max_shield is BELOW its hull's base_shield is brought to
--     shield = max_shield = base_shield (born full — the SHIELD-2 commission copy shape). A ship
--     already at/above its hull value (e.g. a shield that took combat damage after a prior flip) is
--     UNTOUCHED — the predicate max_shield < base_shield is false for it, so a re-run never resets a
--     damaged pool.
--   STAGE 3 — the two regen knobs (via the owned set_game_config writer): shield_regen_combat_pct
--     0.02, shield_regen_idle_pct 0.10. [D — OWNER-TUNABLE: fractions of max_shield per combat tick
--     / per idle reconciler pass. The charter proposals.]
--   SMOKE (read-only): the three hulls carry their target base_shield; NO instance is left with
--     max_shield below its hull's base_shield (the backfill is complete); both knobs read > 0
--     through cfg_num; the deployed bodies still carry their shield hunks.
--   Emits ACTIVATE_SHIELD_PASS_* markers per stage and one final PASS line; any failed assert
--   RAISES → the whole transaction rolls back → NOTHING is applied (all-or-nothing activation).
--
-- RE-RUN SEMANTICS (decided, documented): this is a FIRST-FLIP tool. STAGE 3 hard-preconditions
-- that both knobs read '0', so a verbatim re-run AFTER a successful activation RAISES at the knob
-- precondition BY DESIGN — it refuses to silently re-clobber a later deliberate retune (a retune is
-- a separate set_game_config write, no deploy). The DATA stages (1/2) are monotonic + idempotent on
-- their own (they only ever raise a below-target value), so nothing is corrupted even mid-abort.
--
-- ── NOTE: SHIELDS MATTER IN COMBAT — PAIRS WITH HUNTING ───────────────────────────────────────────
--   Once lit, a member ship entering a team encounter snapshots its pool (0195), absorbs damage
--   shield-first, regenerates in-combat by shield_regen_combat_pct/tick and out-of-combat by
--   shield_regen_idle_pct on the 30s reconciler pass. This is a COMBAT survivability buff — flip it
--   alongside the hunting loop (it does nothing for a ship that never fights).
--
-- ── INVOCATION (Management-API compatible: NO psql meta-commands; one BEGIN..COMMIT) ─────────────
--   psql "<prod session-pooler conn (pinned CA, sslmode=verify-full)>" -X -v ON_ERROR_STOP=1 \
--        -f scripts/activate-shield.sql
--   Or paste this whole file into the Supabase Dashboard SQL editor / management-API runner, or:
--     bash scripts/activate-shield.sh run ACTIVATE_SHIELD      # DB_URL required
--   AFTER a green run: manual smoke — send a team on a hunt, watch a member's shield absorb the
--   first salvos and refill between waves; a docked/idle damaged shield trickles back on the 30s
--   reconciler.
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
--   See the marked ROLLBACK section at the BOTTOM (commented out). KNOBS-back-to-0 darkens all
--   regeneration instantly (combat + idle both read the knob). The DATA (hull base_shield + instance
--   pools) is deliberately left — a shielded ship keeps its pool; it simply stops regenerating.
--   Optionally zero the data too (the commented data-rollback) to return to the pristine 0/0 posture.

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local idle_in_transaction_session_timeout = '60s';

-- ══════════ PRECONDITIONS (read-only; no write happens unless all pass) ══════════
do $$
declare
  v_head text; v_missing text; fn text; v_src text;
  v_combat text; v_idle text; n int;
begin
  -- the three shield migrations deployed AND recorded (head alone is not enough).
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  if v_head is null or v_head < '20260618000197' then
    raise exception 'PRECONDITION FAIL: migration head % < 20260618000197 (SHIELD-2) — deploy the shield stack first', coalesce(v_head, '(none)');
  end if;
  select string_agg(mv, ', ') into v_missing
    from unnest(array['20260618000191','20260618000195','20260618000197']) mv
   where not exists (select 1 from supabase_migrations.schema_migrations s where s.version = mv);
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: shield migration(s) not recorded as deployed: %', v_missing;
  end if;

  -- the shield columns exist (the 0191 schema).
  if not exists (select 1 from information_schema.columns
     where table_schema='public' and table_name='main_ship_hull_types' and column_name='base_shield') then
    raise exception 'PRECONDITION FAIL: main_ship_hull_types.base_shield missing (deploy 0191)';
  end if;
  if not exists (select 1 from information_schema.columns
     where table_schema='public' and table_name='main_ship_instances' and column_name='shield')
  or not exists (select 1 from information_schema.columns
     where table_schema='public' and table_name='main_ship_instances' and column_name='max_shield') then
    raise exception 'PRECONDITION FAIL: main_ship_instances.shield / max_shield missing (deploy 0191)';
  end if;

  -- the function surface — the leaf + the two engine bodies the shields ride + config.
  foreach fn in array array[
    'public.mainship_sync_combat_shield(uuid, integer)',
    'public.process_combat_ticks()',
    'public.process_mainship_expeditions()',
    'public.cfg_num(text)',
    'public.cfg_bool(text)',
    'public.set_game_config(text, jsonb)'] loop
    if to_regprocedure(fn) is null then
      raise exception 'PRECONDITION FAIL: function % does not exist', fn;
    end if;
  end loop;

  -- the DEPLOYED 0191 leaf: both clamps, writes shield only (the one-leaf law).
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.mainship_sync_combat_shield(uuid, integer)')::oid;
  if position('least(max_shield, greatest(0, p_shield))' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed mainship_sync_combat_shield lacks both clamps (0191 leaf head)';
  end if;

  -- the DEPLOYED 0195 tick: the ONE absorb point + the hoisted combat-regen knob read.
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.process_combat_ticks()')::oid;
  if position('least(coalesce(v_shield, 0), v_d_group)' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed process_combat_ticks lacks the ONE shield-absorb point (deploy 0195)';
  end if;
  if position('cfg_num(''shield_regen_combat_pct'')' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed process_combat_ticks does not read shield_regen_combat_pct (deploy 0195)';
  end if;

  -- the DEPLOYED 0197 reconciler: the guarded idle-regen set-statement + the idle knob read.
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.process_mainship_expeditions()')::oid;
  if position('set shield = least(s.max_shield, s.shield + ceil(s.max_shield * v_idle)::integer)' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed process_mainship_expeditions lacks the idle-regen set-statement (deploy 0197)';
  end if;
  if position('cfg_num(''shield_regen_idle_pct'')' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed process_mainship_expeditions does not read shield_regen_idle_pct (deploy 0197)';
  end if;

  -- both regen knobs currently the dark seed '0' (FIRST-FLIP guard — see RE-RUN SEMANTICS).
  v_combat := (select value #>> '{}' from public.game_config where key = 'shield_regen_combat_pct');
  v_idle   := (select value #>> '{}' from public.game_config where key = 'shield_regen_idle_pct');
  if v_combat is null or v_idle is null then
    raise exception 'PRECONDITION FAIL: a shield regen knob is missing (deploy 0191 — it seeds both ''0'')';
  end if;
  if v_combat is distinct from '0' or v_idle is distinct from '0' then
    raise exception 'PRECONDITION FAIL: a shield regen knob is not the dark seed ''0'' (combat=%, idle=%) — this is a FIRST-FLIP tool; a retune is a separate set_game_config write', v_combat, v_idle;
  end if;

  -- the three seeded hulls exist (the base_shield seed must land on real rows).
  select string_agg(h, ', ') into v_missing
    from unnest(array['starter_frigate','bulk_hauler','strike_corvette']) h
   where not exists (select 1 from public.main_ship_hull_types t where t.hull_type_id = h);
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: hull row(s) missing for the base_shield seed: % (deploy 0043 + 0185)', v_missing;
  end if;

  raise notice 'ACTIVATE_SHIELD_PASS_PRECONDITIONS ok: head %, 3 shield migrations recorded, columns present, leaf/tick/reconciler bodies prosrc-pinned to their heads, both regen knobs at the dark seed 0, 3 target hulls present', v_head;
end $$;

-- ══════════ STAGE 1 — the per-hull base_shield seed (MONOTONIC: only raises where lower) ══════════
--   [D — OWNER-TUNABLE] edit the three integers below before running. These are the SHIELD charter
--   proposals: starter_frigate/Sparrow=100, bulk_hauler/Mule=130, strike_corvette/Talon=85.
do $$
declare n int;
begin
  update public.main_ship_hull_types h
    set base_shield = v.bs
    from (values ('starter_frigate', 100),   -- [D] Sparrow
                 ('bulk_hauler',     130),   -- [D] Mule
                 ('strike_corvette',  85))   -- [D] Talon
         v(id, bs)
   where h.hull_type_id = v.id
     and h.base_shield < v.bs;               -- MONOTONIC: never lower a hull's shield template
  get diagnostics n = row_count;
  raise notice 'stage 1: raised base_shield on % hull row(s)', n;
  raise notice 'ACTIVATE_SHIELD_PASS_STAGE1 ok: per-hull base_shield seeded (monotonic)';
end $$;

-- ══════════ STAGE 2 — the MONOTONIC instance backfill (the deferred-bump idiom; born full) ══════════
do $$
declare n int;
begin
  update public.main_ship_instances i
    set max_shield = h.base_shield,
        shield     = h.base_shield,          -- born full — the SHIELD-2 commission copy shape
        updated_at = now()
    from public.main_ship_hull_types h
   where h.hull_type_id = i.hull_type_id
     and i.max_shield < h.base_shield;        -- deferred bump: only ships below their hull value
  get diagnostics n = row_count;
  raise notice 'stage 2: backfilled % existing ship instance(s) to born-full shields', n;
  raise notice 'ACTIVATE_SHIELD_PASS_STAGE2 ok: instance backfill complete (monotonic; damaged pools untouched)';
end $$;

-- ══════════ STAGE 3 — the two regen knobs (via the owned set_game_config writer) ══════════
--   [D — OWNER-TUNABLE] combat = fraction of max_shield regenerated per combat tick; idle = per
--   out-of-combat reconciler pass. Charter proposals: 0.02 combat, 0.10 idle.
do $$
declare v_c text; v_i text;
begin
  select value::text into v_c from public.game_config where key = 'shield_regen_combat_pct';
  select value::text into v_i from public.game_config where key = 'shield_regen_idle_pct';
  perform public.set_game_config('shield_regen_combat_pct', '0.02'::jsonb);   -- [D] OWNER-TUNABLE
  perform public.set_game_config('shield_regen_idle_pct',   '0.10'::jsonb);   -- [D] OWNER-TUNABLE
  raise notice 'stage 3: shield_regen_combat_pct % -> 0.02, shield_regen_idle_pct % -> 0.10', v_c, v_i;
  raise notice 'ACTIVATE_SHIELD_PASS_STAGE3 ok: both regen knobs > 0 (uncommitted until smoke passes)';
end $$;

-- ══════════ SMOKE — read-only ══════════
do $$
declare n int; v_src text;
begin
  -- (a) the three hulls carry a shield template >= their target (monotonic seed landed).
  select count(*) into n from public.main_ship_hull_types
   where (hull_type_id = 'starter_frigate' and base_shield >= 100)
      or (hull_type_id = 'bulk_hauler'     and base_shield >= 130)
      or (hull_type_id = 'strike_corvette' and base_shield >=  85);
  if n <> 3 then
    raise exception 'SMOKE FAIL: % of 3 target hulls carry their base_shield (seed did not land)', n;
  end if;

  -- (b) NO instance left below its hull's base_shield — the backfill is complete (empty DB: 0 rows,
  --     trivially complete; a fixture/first ship now carries shield > 0).
  select count(*) into n from public.main_ship_instances i
    join public.main_ship_hull_types h on h.hull_type_id = i.hull_type_id
   where i.max_shield < h.base_shield;
  if n <> 0 then
    raise exception 'SMOKE FAIL: % instance(s) still below their hull base_shield (backfill incomplete)', n;
  end if;

  -- (c) both regen knobs read > 0 through the reader the engines use.
  if public.cfg_num('shield_regen_combat_pct') is null or public.cfg_num('shield_regen_combat_pct') <= 0 then
    raise exception 'SMOKE FAIL: shield_regen_combat_pct is not > 0 after the flip'; end if;
  if public.cfg_num('shield_regen_idle_pct') is null or public.cfg_num('shield_regen_idle_pct') <= 0 then
    raise exception 'SMOKE FAIL: shield_regen_idle_pct is not > 0 after the flip'; end if;

  -- (d) the engine bodies still carry their shield hunks (nothing drifted under us).
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.process_combat_ticks()')::oid;
  if position('least(coalesce(v_shield, 0), v_d_group)' in v_src) = 0 then
    raise exception 'SMOKE FAIL: the combat tick lost its absorb point'; end if;
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.process_mainship_expeditions()')::oid;
  if position('ceil(s.max_shield * v_idle)::integer' in v_src) = 0 then
    raise exception 'SMOKE FAIL: the reconciler lost its idle-regen statement'; end if;

  raise notice 'ACTIVATE_SHIELD_PASS_SMOKE ok: 3 hulls seeded, no instance below its hull value (backfill complete), both regen knobs > 0, engine shield hunks intact';
end $$;

select 'SHIELD ACTIVATION PASS — regenerating shields are LIVE. Every hull carries a shield template (Sparrow 100 / Mule 130 / Talon 85 [D]), every existing ship was backfilled born-full (monotonic — damaged pools untouched), and both regen knobs are > 0 (combat 0.02/tick, idle 0.10/pass [D]). In combat a member ship now absorbs damage shield-first and refills between waves; out of combat a damaged pool trickles back on the 30s reconciler. Shields matter in combat — pair this with the hunting loop.' as result;

commit;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- To darken shield regeneration again, run the KNOBS-only reverse writes below (uncomment, run
-- once). The DATA (hull base_shield + instance pools) is left in place — a shielded ship keeps its
-- pool but stops regenerating (both the combat tick and the reconciler read the knob). To return to
-- the pristine 0/0 posture entirely, also uncomment the OPTIONAL data-rollback lines.
--
-- begin;
-- select public.set_game_config('shield_regen_combat_pct', '0'::jsonb);
-- select public.set_game_config('shield_regen_idle_pct',   '0'::jsonb);
-- -- OPTIONAL full data-rollback (returns hulls + instances to the pristine 0/0 shieldless posture):
-- -- update public.main_ship_instances set shield = 0, max_shield = 0, updated_at = now();
-- -- update public.main_ship_hull_types set base_shield = 0;
-- select key, value from public.game_config where key in ('shield_regen_combat_pct','shield_regen_idle_pct') order by key;
-- commit;
