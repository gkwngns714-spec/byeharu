-- SOUL ACTIVATION — the ship-traits flip (docs/ACTIVATION_GUIDE.md → ACT-SOUL; the SHIP-SOUL packet's
-- human activation step, promised by SOUL-0/1). Ship traits are FULLY BUILT DARK: 0186 (the catalog
-- of 8 trait types + the per-ship traits table + the deterministic idempotent roll writer) and 0193
-- (the commission ROLL HOOK + the adapter TRAIT FOLD), everything behind ship_traits_enabled='false'.
--
-- ██ HUMAN ACTIVATION TOOL ██ — run BY THE HUMAN, deliberately, against prod. NOT CI; nothing flips
-- at build/deploy time. Each run of this file IS the recorded human go decision.
--
-- ── WHAT IT DOES (one transaction; COMMIT only if every assert passes) ────────────────────────────
--   PRECONDITIONS (no write until these hold):
--     • migration head >= 20260618000193 AND 0186 / 0193 both recorded as deployed;
--     • ██ THE CATALOG-FREEZE PRECONDITION (ACT-SOUL's load-bearing gate): ship_trait_types holds
--       EXACTLY 8 rows. A ship's two traits are a PURE DETERMINISTIC FUNCTION of its id indexed INTO
--       the catalog's size + order (the 0186 collation law); a catalog GROWN before the backfill
--       would change every unrolled ship's derivation. Freeze at 8, or refuse to flip;
--     • the roll writer + the adapter fold + the commission hooks exist via to_regprocedure;
--     • the DEPLOYED bodies are the current heads, prosrc-pinned: the roll writer carries the
--       idempotent on-conflict insert; the adapter carries the knob-gated trait fold;
--     • the flag ship_traits_enabled currently reads 'false' (this is a FIRST-FLIP tool — see
--       RE-RUN). Note the DATA backfill is idempotent regardless.
--   STAGE 1 — the switch (the ONE flag write, via the owned set_game_config writer):
--     ship_traits_enabled → true. ORDERED BEFORE THE BACKFILL, DELIBERATELY: the roll writer
--     gate-rejects (feature_disabled) while false — the same txn sees this write, so stage 2 rolls
--     lit. Every NEW ship born from here rolls its soul at commission (the 0193 hook).
--   STAGE 2 — ██ THE BACKFILL ██ [D — backfill = YES]: every EXISTING main ship with no soul rows
--     gets soul_roll_traits_for_ship() called on it. Idempotent BY CONSTRUCTION — the roll is
--     deterministic and inserts on-conflict-do-nothing, so a re-run rolls ZERO new rows and a ship
--     that already has traits is skipped by the has-no-rows predicate. (The retroactive roll over
--     pre-existing ships is deliberately ACT-SOUL's, gated behind the catalog freeze above — the
--     0193 hooks only ever roll ships born AFTER the flip.)
--   SMOKE (read-only): flag committed (raw + cfg_bool); catalog still frozen at 8; NO existing ship
--     is left without its 2 soul rows (the backfill is complete); the adapter fold is live
--     (prosrc-pinned v_traits_enabled). On an empty database no ships exist and the backfill/smoke
--     are trivially complete.
--   Emits ACTIVATE_SOUL_PASS_* markers per stage and one final PASS line; any failed assert RAISES
--   → the whole transaction rolls back → NOTHING is applied (all-or-nothing activation).
--
-- RE-RUN SEMANTICS (decided, documented): FIRST-FLIP tool. STAGE 1 hard-preconditions the flag reads
-- 'false', so a verbatim re-run after success RAISES at the precondition BY DESIGN. If a re-backfill
-- is ever needed after new ships appear, the roll writer's own idempotence makes calling it again
-- harmless — but this activator is the one-time flip.
--
-- ── NO CLIENT PR IS NEEDED FOR THE SERVER FLIP ───────────────────────────────────────────────────
--   The trait fold is SERVER-side inside calculate_expedition_stats — the moment the flag commits,
--   every stat surface (solo preview, D0 team totals, combat snapshots) folds each ship's traits.
--   Any trait-DISPLAY panel is a separate client concern (SOUL-2); the gameplay effect is live at flip.
--
-- ── INVOCATION (Management-API compatible: NO psql meta-commands; one BEGIN..COMMIT) ─────────────
--   psql "<prod session-pooler conn>" -X -v ON_ERROR_STOP=1 -f scripts/activate-soul.sql
--   Or paste into the Supabase Dashboard SQL editor / management-API runner, or:
--     bash scripts/activate-soul.sh run ACTIVATE_SOUL      # DB_URL required
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
--   See the marked ROLLBACK section (commented). FLAG-ONLY: ship_traits_enabled → false. The adapter
--   fold is skipped again (byte-identical output) and no new ship rolls; the rolled main_ship_traits
--   rows PERSIST (immutable — insert-only; harmless while dark) and any hp_mult already applied at
--   roll time stays (re-scaling would double-apply — the 0186 law). Roll the flag, never the rows.

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local idle_in_transaction_session_timeout = '60s';

-- ══════════ PRECONDITIONS (read-only; no write happens unless all pass) ══════════
do $$
declare v_head text; v_missing text; fn text; v_src text; n int;
begin
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  if v_head is null or v_head < '20260618000193' then
    raise exception 'PRECONDITION FAIL: migration head % < 20260618000193 (SOUL-1) — deploy the ship-traits stack first', coalesce(v_head, '(none)');
  end if;
  select string_agg(mv, ', ') into v_missing
    from unnest(array['20260618000186','20260618000193']) mv
   where not exists (select 1 from supabase_migrations.schema_migrations s where s.version = mv);
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: soul migration(s) not recorded as deployed: %', v_missing;
  end if;

  -- ██ THE CATALOG-FREEZE PRECONDITION ██ — exactly 8 trait types, or the deterministic derivations
  -- would be indexed into the wrong catalog size/order. Refuse the flip if the catalog has grown.
  select count(*) into n from public.ship_trait_types;
  if n <> 8 then
    raise exception 'PRECONDITION FAIL: ship_trait_types holds % rows (want the FROZEN 8 — the ACT-SOUL catalog-freeze law; a grown catalog changes every unrolled ship''s derivation)', n;
  end if;

  -- the function surface: the roll writer + the adapter fold + the commission hooks + config.
  foreach fn in array array[
    'public.soul_roll_traits_for_ship(uuid)',
    'public.calculate_expedition_stats(uuid, uuid, jsonb, text)',
    'public.port_entry_commission_build(uuid, text)',
    'public.ensure_main_ship_for_player(uuid)',
    'public.cfg_bool(text)',
    'public.set_game_config(text, jsonb)'] loop
    if to_regprocedure(fn) is null then
      raise exception 'PRECONDITION FAIL: function % does not exist', fn;
    end if;
  end loop;

  -- the DEPLOYED roll writer: the idempotent (ship, slot) insert (a re-roll is impossible by
  -- construction — the backfill relies on it).
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.soul_roll_traits_for_ship(uuid)')::oid;
  if position('on conflict (main_ship_id, slot) do nothing' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed soul_roll_traits_for_ship lacks the idempotent (ship, slot) insert (deploy 0186)';
  end if;

  -- the DEPLOYED adapter: the knob-gated trait fold (goes live the moment the flag flips).
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.calculate_expedition_stats(uuid, uuid, jsonb, text)')::oid;
  if position('v_traits_enabled' in v_src) = 0 or position('if v_traits_enabled then' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed calculate_expedition_stats lacks the knob-gated trait fold (deploy 0193)';
  end if;

  -- the commission hooks fire the roll on new ships when lit (the 0193 gated perform).
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.port_entry_commission_build(uuid, text)')::oid;
  if position('perform public.soul_roll_traits_for_ship(' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed commission build lacks the SOUL-1 roll hook (deploy 0193)';
  end if;

  -- the flag exists and reads 'false' (FIRST-FLIP guard — see RE-RUN SEMANTICS).
  if not exists (select 1 from public.game_config where key = 'ship_traits_enabled') then
    raise exception 'PRECONDITION FAIL: game_config key ship_traits_enabled missing (0186 seeds it false)';
  end if;
  if (select value #>> '{}' from public.game_config where key = 'ship_traits_enabled') is distinct from 'false' then
    raise exception 'PRECONDITION FAIL: ship_traits_enabled is not ''false'' — this is a FIRST-FLIP tool (already activated? the backfill is idempotent, but the flag flip refuses to re-run)';
  end if;

  -- ACL posture: the roll writer is service-role-only (this privileged script may call it; a client never).
  if has_function_privilege('authenticated', 'public.soul_roll_traits_for_ship(uuid)', 'execute')
     or has_function_privilege('anon', 'public.soul_roll_traits_for_ship(uuid)', 'execute') then
    raise exception 'PRECONDITION FAIL: soul_roll_traits_for_ship ACL drifted (want service-role-only)';
  end if;

  raise notice 'ACTIVATE_SOUL_PASS_PRECONDITIONS ok: head %, 0186/0193 recorded, catalog FROZEN at 8, roll writer + adapter fold + commission hook prosrc-pinned, flag false, roll writer service-role-only', v_head;
end $$;

-- ══════════ STAGE 1 — the switch (the ONE flag write; BEFORE the backfill: the roll writer
--            gate-rejects while false and the same txn sees this write, so stage 2 rolls lit) ══════════
do $$
declare v_before text;
begin
  select value::text into v_before from public.game_config where key = 'ship_traits_enabled';
  perform public.set_game_config('ship_traits_enabled', 'true'::jsonb);
  raise notice 'stage 1: ship_traits_enabled % -> true', v_before;
  raise notice 'ACTIVATE_SOUL_PASS_STAGE1 ok: ship_traits_enabled=true (uncommitted until the backfill + smoke pass — one all-or-nothing txn)';
end $$;

-- ══════════ STAGE 2 — ██ THE BACKFILL ██ [D = YES] (roll every existing soul-less ship;
--            idempotent — the roll is deterministic + on-conflict-do-nothing) ══════════
do $$
declare r record; v_rolled int := 0; v_res jsonb;
begin
  for r in
    select i.main_ship_id from public.main_ship_instances i
     where not exists (select 1 from public.main_ship_traits t where t.main_ship_id = i.main_ship_id)
  loop
    v_res := public.soul_roll_traits_for_ship(r.main_ship_id);
    if coalesce(v_res ->> 'ok', 'false') <> 'true' then
      raise exception 'STAGE2 FAIL: soul_roll_traits_for_ship rejected for ship % (gate should be open in-txn): %', r.main_ship_id, v_res;
    end if;
    v_rolled := v_rolled + 1;
  end loop;
  raise notice 'stage 2: rolled souls for % previously-soulless ship(s)', v_rolled;
  raise notice 'ACTIVATE_SOUL_PASS_STAGE2 ok: backfill complete (idempotent — a re-run rolls zero new rows)';
end $$;

-- ══════════ SMOKE — read-only ══════════
do $$
declare n int; v_src text;
begin
  -- (a) the committed flag value.
  if (select value #>> '{}' from public.game_config where key = 'ship_traits_enabled') is distinct from 'true' then
    raise exception 'SMOKE FAIL: ship_traits_enabled is % (want true)',
      (select value #>> '{}' from public.game_config where key = 'ship_traits_enabled');
  end if;
  if not public.cfg_bool('ship_traits_enabled') then
    raise exception 'SMOKE FAIL: cfg_bool(ship_traits_enabled) still false'; end if;

  -- (b) the catalog is still frozen at 8 (nothing grew it under us).
  select count(*) into n from public.ship_trait_types;
  if n <> 8 then raise exception 'SMOKE FAIL: catalog holds % rows (want the frozen 8)', n; end if;

  -- (c) NO existing ship left without its 2 soul rows (the backfill is complete). Empty DB: 0 rows,
  --     trivially complete; a fixture/first ship now carries exactly 2 trait rows.
  select count(*) into n from public.main_ship_instances i
   where (select count(*) from public.main_ship_traits t where t.main_ship_id = i.main_ship_id) <> 2;
  if n <> 0 then
    raise exception 'SMOKE FAIL: % ship(s) do not carry exactly 2 soul rows (backfill incomplete)', n;
  end if;

  -- (d) the adapter fold is live (the knob-gated read edge is present in the deployed body).
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.calculate_expedition_stats(uuid, uuid, jsonb, text)')::oid;
  if position('if v_traits_enabled then' in v_src) = 0 or position('from main_ship_traits' in v_src) = 0 then
    raise exception 'SMOKE FAIL: the adapter lost its trait fold'; end if;

  raise notice 'ACTIVATE_SOUL_PASS_SMOKE ok: flag committed true, catalog frozen at 8, every ship carries 2 soul rows, adapter fold live';
end $$;

select 'SOUL ACTIVATION PASS — per-ship traits are LIVE. ship_traits_enabled is true, every existing ship was backfilled with its two deterministic birthmark traits (idempotent roll, on-conflict-do-nothing), and every NEW ship rolls its soul at commission (the 0193 hook). The adapter now folds each ship''s traits into every stat surface (preview / team totals / combat snapshots); the veteran_frame hp bump was applied once at roll time. NO client PR is needed for the gameplay effect (a trait-display panel is SOUL-2''s concern).' as result;

commit;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- To dark the traits system again, run the reverse write below (uncomment, run once). Notes:
--   • FLAG-ONLY: ship_traits_enabled → false. The adapter fold is skipped again (byte-identical
--     output) and no new ship rolls a soul.
--   • The rolled main_ship_traits rows PERSIST (immutable — insert-only, no update/delete path;
--     harmless while dark) and any veteran_frame hp_mult already applied at roll time STANDS
--     (re-scaling would double-apply — the 0186 law). Roll back the FLAG, never the trait rows.
--
-- begin;
-- select public.set_game_config('ship_traits_enabled', 'false'::jsonb);
-- select key, value from public.game_config where key = 'ship_traits_enabled';
-- commit;
