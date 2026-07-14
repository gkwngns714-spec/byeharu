-- SHIPYARD ACTIVATION — ██ THE BUILD-LOOP UNLOCK ██ (docs/ACTIVATION_GUIDE.md → ACT-SHIPYARD; the
-- SHIPYARD packet's human activation step, and the #1 audit gap: ships are currently UNBUILDABLE
-- because the blueprint faucet is closed and no script opens it). The ship-production stack is FULLY
-- BUILT DARK: 0185 (the two T1 hull catalog rows + recipes + the config-gated blueprint faucet in
-- pirate_loot_for_wave), 0188 (the order RPC start_hull_build + the build_orders generalization),
-- 0194 (the queue engine's hull arm: promotion → completion → commission DELIVERY + hull-aware
-- cancel refunds). Everything is dark behind shipyard_enabled='false' AND the blueprint faucet knob
-- blueprint_fragment_drop_rate='0' (both recipes need blueprint_fragment ×2 — unreachable at rate 0).
--
-- ██ HUMAN ACTIVATION TOOL ██ — run BY THE HUMAN, deliberately, against prod. NOT CI; nothing flips
-- at build/deploy time. Each run of this file IS the recorded human go decision.
--
-- ── THE DEPENDENCY CHAIN (documented — read before running) ───────────────────────────────────────
--   A hull recipe is BUILDABLE only if every ingredient has a LIVE faucet. The T1 recipes consume:
--     bulk_hauler     = ore 24 + crystal 6 + engine_parts 6 + scrap 12 + blueprint_fragment 2
--     strike_corvette = ore 16 + crystal 4 + weapon_parts 6 + pirate_alloy 8 + blueprint_fragment 2
--   Faucets:
--     • ore / crystal          → MINING fields (needs mining_enabled lit — the HARD precondition below)
--     • scrap (w>=1) / pirate_alloy (w>=3) / weapon_parts (w>=5) / engine_parts (w>=8)
--                              → COMBAT loot (pirate_loot_for_wave — combat is inherently live)
--     • blueprint_fragment     → the w>=8 COMBAT faucet THIS script opens (rate 0 → 0.15) + the 0098
--                                exploration one-shot
--   So: shipyard needs MINING lit (ore/crystal) + COMBAT (weapon_parts / blueprint fragments via the
--   now-open faucet). This script HARD-PRECONDITIONS mining_enabled and, for EVERY distinct recipe
--   ingredient, verifies a live faucet exists — if any ingredient has NO faucet even after mining,
--   it RAISES with a clear message so the owner knows the recipe is unbuildable.
--
-- ── WHAT IT DOES (one transaction; COMMIT only if every assert passes) ────────────────────────────
--   PRECONDITIONS (no write until these hold):
--     • migration head >= 20260618000194 AND 0185 / 0188 / 0194 all recorded as deployed;
--     • ██ mining_enabled must be COMMITTED true (raw + cfg_bool) — the ore/crystal faucet ██;
--     • the T1 catalog is intact (2 recipe headers + 10 ingredient rows);
--     • the order RPC + the queue engine + the commission core exist via to_regprocedure;
--     • the DEPLOYED bodies are the current heads, prosrc-pinned: the order RPC gate-rejects on
--       shipyard_enabled; the loot fn carries the w>=8 blueprint faucet hunk;
--     • ██ SHIPYARD-2's hull-aware cancel refund is in place (0194 — the 0188 header flagged
--       cancel-eats-ingredients as a pre-flip requirement) ██: cancel_build_order's DEPLOYED body
--       carries the hull refund arm (wallet_credit + the receipt-bill read + keyed inventory_deposit),
--       else RAISE — flipping without it would let a cancel eat a build's ingredients;
--     • ██ REACHABILITY: every distinct recipe ingredient has a LIVE faucet ██ (mining field bundle,
--       or the combat loot prosrc, or an exploration one-shot) — else RAISE (recipe unbuildable);
--     • the flag + the faucet knob currently read their dark seeds (flag 'false', rate '0') — this is
--       a FIRST-FLIP tool (see RE-RUN).
--   STAGE 1 — the switch (the ONE flag write, via set_game_config): shipyard_enabled → true. The
--     order RPC dark-gates on cfg_bool('shipyard_enabled') FIRST — it physically cannot enqueue dark.
--   STAGE 2 — ██ open the blueprint faucet ██: blueprint_fragment_drop_rate 0 → 0.15. [D —
--     OWNER-TUNABLE: ~15% chance a cleared wave>=8 drops 1 blueprint_fragment; the charter proposal.
--     Edit before running.] This makes blueprint_fragment (needed ×2 per T1 recipe) reachable via
--     combat grinding.
--   SMOKE (read-only): shipyard_enabled committed true (raw + cfg_bool); the faucet reads > 0; at
--     least one recipe's ingredients ALL have a live source (the reachability finding, re-affirmed).
--   Emits ACTIVATE_SHIPYARD_PASS_* markers per stage and one final PASS line; any failed assert
--   RAISES → the whole transaction rolls back → NOTHING is applied (all-or-nothing activation).
--
-- RE-RUN SEMANTICS (decided, documented): FIRST-FLIP tool. The flag + faucet preconditions require
-- the dark seeds, so a verbatim re-run after success RAISES BY DESIGN — it refuses to re-clobber a
-- later deliberate faucet retune (a retune is a separate set_game_config write).
--
-- ── THE CLIENT SURFACE ────────────────────────────────────────────────────────────────────────────
--   The server flip lights the start_hull_build RPC + the cron delivery loop; a build-order UI is
--   SHIPYARD-3's concern (out of scope for this scripts-only slice — documented in ACTIVATION_GUIDE).
--   The build loop itself is fully server-side: enqueue → 30s-cron promote → build_seconds timer →
--   commission delivery at Haven Reach.
--
-- ── INVOCATION (Management-API compatible: NO psql meta-commands; one BEGIN..COMMIT) ─────────────
--   psql "<prod session-pooler conn>" -X -v ON_ERROR_STOP=1 -f scripts/activate-shipyard.sql
--   Or paste into the Supabase Dashboard SQL editor / management-API runner, or:
--     bash scripts/activate-shipyard.sh run ACTIVATE_SHIPYARD      # DB_URL required
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
--   See the marked ROLLBACK section (commented). FLAG + FAUCET back to their dark seeds: the order
--   RPC rejects gate-first again and wave>=8 stops dropping blueprint fragments. Already-queued
--   builds finish (the cron keeps delivering; the delivery path never reads the flag); no data reverts.

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local idle_in_transaction_session_timeout = '60s';

-- ══════════ PRECONDITIONS (read-only; no write happens unless all pass) ══════════
do $$
declare
  v_head text; v_missing text; fn text; v_src text; v_loot text; n int;
  r record; v_sourced boolean; v_unbuildable text := '';
begin
  -- the three shipyard migrations deployed AND recorded.
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  if v_head is null or v_head < '20260618000194' then
    raise exception 'PRECONDITION FAIL: migration head % < 20260618000194 (SHIPYARD-2) — deploy the shipyard stack first', coalesce(v_head, '(none)');
  end if;
  select string_agg(mv, ', ') into v_missing
    from unnest(array['20260618000185','20260618000188','20260618000194']) mv
   where not exists (select 1 from supabase_migrations.schema_migrations s where s.version = mv);
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: shipyard migration(s) not recorded as deployed: %', v_missing;
  end if;

  -- ██ THE HARD MINING GATE ██ — ore/crystal only flow when mining is lit (raw + cfg_bool).
  if (select value #>> '{}' from public.game_config where key = 'mining_enabled') is distinct from 'true'
     or not public.cfg_bool('mining_enabled') then
    raise exception 'PRECONDITION FAIL: mining_enabled is not committed true — run ACT-MINING (scripts/activate-mining.sql) FIRST. Both T1 hull recipes need ore + crystal, and mining is the ONLY faucet for them; flipping the shipyard with mining dark leaves every recipe unbuildable';
  end if;

  -- the T1 catalog intact (the price + ingredient rows the build command charges).
  select count(*) into n from public.hull_build_recipes where hull_type_id in ('bulk_hauler','strike_corvette');
  if n <> 2 then raise exception 'PRECONDITION FAIL: % of 2 T1 recipe headers present (deploy 0185)', n; end if;
  select count(*) into n from public.hull_recipe_ingredients;
  if n <> 10 then raise exception 'PRECONDITION FAIL: hull_recipe_ingredients has % rows (want the 10 0185 seeds)', n; end if;

  -- the order RPC + queue engine + commission core + config leaves.
  foreach fn in array array[
    'public.start_hull_build(uuid, text)',
    'public.production_start_hull_build(uuid, text, uuid)',
    'public.process_build_queue()',
    'public.cancel_build_order(uuid)',
    'public.port_entry_commission_build(uuid, text)',
    'public.pirate_loot_for_wave(integer, numeric)',
    'public.cfg_bool(text)',
    'public.cfg_num(text)',
    'public.set_game_config(text, jsonb)'] loop
    if to_regprocedure(fn) is null then
      raise exception 'PRECONDITION FAIL: function % does not exist', fn;
    end if;
  end loop;

  -- the DEPLOYED order writer gate-rejects on shipyard_enabled (0188).
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.production_start_hull_build(uuid, text, uuid)')::oid;
  if position('cfg_bool(''shipyard_enabled''' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed production_start_hull_build does not gate on shipyard_enabled (deploy 0188)';
  end if;

  -- the DEPLOYED loot fn carries the w>=8 blueprint faucet hunk (the knob this script raises).
  select prosrc into v_loot from pg_proc where oid = to_regprocedure('public.pirate_loot_for_wave(integer, numeric)')::oid;
  if position('blueprint_fragment_drop_rate' in v_loot) = 0 or position('p_wave >= 8' in v_loot) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed pirate_loot_for_wave lacks the w>=8 blueprint faucet hunk (deploy 0185)';
  end if;

  -- ██ SHIPYARD-2's hull-aware cancel refund MUST be in place (0194) ██ — the 0188 header flagged
  -- cancel-eats-ingredients as a pre-flip requirement; confirm 0194 closed it.
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.cancel_build_order(uuid)')::oid;
  if position('wallet_credit' in v_src) = 0
     or position('from hull_build_receipts' in v_src) = 0
     or position('inventory_deposit' in v_src) = 0
     or position('hull_cancel:' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed cancel_build_order lacks SHIPYARD-2''s hull refund arm (wallet_credit + receipt-bill + keyed inventory_deposit) — flipping without it lets a cancel EAT a build''s ingredients; deploy 0194';
  end if;

  -- ██ REACHABILITY ██ — every distinct recipe ingredient must have a LIVE faucet: a mining-field
  -- bundle (ore/crystal — mining is lit, gated above), OR the deployed combat loot prosrc
  -- (scrap/pirate_alloy/weapon_parts/engine_parts/blueprint_fragment), OR an exploration one-shot.
  for r in select distinct item_id from public.hull_recipe_ingredients loop
    v_sourced := false;
    -- mining faucet
    if exists (select 1 from public.mining_fields f,
                    lateral jsonb_array_elements(f.reward_bundle_json->'items') el
                where el->>'item_id' = r.item_id and (el->>'quantity')::numeric > 0) then
      v_sourced := true;
    end if;
    -- combat loot faucet (the deployed loot body names the item)
    if strpos(v_loot, '''' || r.item_id || '''') > 0 then
      v_sourced := true;
    end if;
    -- exploration one-shot faucet
    if exists (select 1 from public.exploration_sites s,
                    lateral jsonb_array_elements(s.reward_bundle_json->'items') el
                where el->>'item_id' = r.item_id and (el->>'quantity')::numeric > 0) then
      v_sourced := true;
    end if;
    if not v_sourced then
      v_unbuildable := v_unbuildable || r.item_id || ' ';
    end if;
  end loop;
  if v_unbuildable <> '' then
    raise exception 'PRECONDITION FAIL: recipe ingredient(s) with NO live faucet even after mining/combat: % — the recipe is UNBUILDABLE; add a faucet before flipping', v_unbuildable;
  end if;

  -- the flag + faucet currently read their dark seeds (FIRST-FLIP guard).
  if not exists (select 1 from public.game_config where key = 'shipyard_enabled') then
    raise exception 'PRECONDITION FAIL: game_config key shipyard_enabled missing (0185 seeds it false)'; end if;
  if not exists (select 1 from public.game_config where key = 'blueprint_fragment_drop_rate') then
    raise exception 'PRECONDITION FAIL: game_config key blueprint_fragment_drop_rate missing (0185 seeds it 0)'; end if;
  if (select value #>> '{}' from public.game_config where key = 'shipyard_enabled') is distinct from 'false' then
    raise exception 'PRECONDITION FAIL: shipyard_enabled is not ''false'' — this is a FIRST-FLIP tool (already activated?)'; end if;
  if (select value #>> '{}' from public.game_config where key = 'blueprint_fragment_drop_rate') is distinct from '0' then
    raise exception 'PRECONDITION FAIL: blueprint_fragment_drop_rate is not the dark seed ''0'' — a retune is a separate set_game_config write'; end if;

  raise notice 'ACTIVATE_SHIPYARD_PASS_PRECONDITIONS ok: head %, 0185/0188/0194 recorded, mining committed lit, T1 catalog intact (2 headers/10 ingredients), order RPC gate-pinned, loot faucet hunk present, 0194 hull-aware cancel refund present, EVERY recipe ingredient has a live faucet (build-loop reachable), flag + faucet at their dark seeds', v_head;
end $$;

-- ══════════ STAGE 1 — the switch (shipyard_enabled → true; the order RPC gate-rejects while dark) ══════════
do $$
declare v_before text;
begin
  select value::text into v_before from public.game_config where key = 'shipyard_enabled';
  perform public.set_game_config('shipyard_enabled', 'true'::jsonb);
  raise notice 'stage 1: shipyard_enabled % -> true', v_before;
  raise notice 'ACTIVATE_SHIPYARD_PASS_STAGE1 ok: shipyard_enabled=true (uncommitted until the faucet + smoke pass)';
end $$;

-- ══════════ STAGE 2 — ██ open the blueprint faucet ██ (blueprint_fragment reachable via combat) ══════════
--   [D — OWNER-TUNABLE] ~15% chance a cleared wave>=8 drops 1 blueprint_fragment. Charter proposal: 0.15.
do $$
declare v_before text;
begin
  select value::text into v_before from public.game_config where key = 'blueprint_fragment_drop_rate';
  perform public.set_game_config('blueprint_fragment_drop_rate', '0.15'::jsonb);   -- [D] OWNER-TUNABLE
  raise notice 'stage 2: blueprint_fragment_drop_rate % -> 0.15', v_before;
  raise notice 'ACTIVATE_SHIPYARD_PASS_STAGE2 ok: blueprint faucet OPEN (blueprint_fragment now reachable at wave>=8)';
end $$;

-- ══════════ SMOKE — read-only ══════════
do $$
declare n int; v_loot text; r record; v_sourced boolean; v_unbuildable text := '';
begin
  -- (a) the committed flag value.
  if (select value #>> '{}' from public.game_config where key = 'shipyard_enabled') is distinct from 'true' then
    raise exception 'SMOKE FAIL: shipyard_enabled is % (want true)',
      (select value #>> '{}' from public.game_config where key = 'shipyard_enabled');
  end if;
  if not public.cfg_bool('shipyard_enabled') then
    raise exception 'SMOKE FAIL: cfg_bool(shipyard_enabled) still false'; end if;

  -- (b) the faucet reads > 0.
  if public.cfg_num('blueprint_fragment_drop_rate') is null or public.cfg_num('blueprint_fragment_drop_rate') <= 0 then
    raise exception 'SMOKE FAIL: blueprint_fragment_drop_rate is not > 0 after the flip'; end if;

  -- (c) the reachability finding re-affirmed: at least ONE recipe's ingredients ALL have a live
  --     source (the build loop is actually reachable, not just flag-lit).
  select prosrc into v_loot from pg_proc where oid = to_regprocedure('public.pirate_loot_for_wave(integer, numeric)')::oid;
  for r in select item_id from public.hull_recipe_ingredients where hull_type_id = 'strike_corvette' loop
    v_sourced := (
      exists (select 1 from public.mining_fields f, lateral jsonb_array_elements(f.reward_bundle_json->'items') el
                where el->>'item_id' = r.item_id and (el->>'quantity')::numeric > 0)
      or strpos(v_loot, '''' || r.item_id || '''') > 0
      or exists (select 1 from public.exploration_sites s, lateral jsonb_array_elements(s.reward_bundle_json->'items') el
                where el->>'item_id' = r.item_id and (el->>'quantity')::numeric > 0));
    if not v_sourced then v_unbuildable := v_unbuildable || r.item_id || ' '; end if;
  end loop;
  if v_unbuildable <> '' then
    raise exception 'SMOKE FAIL: strike_corvette ingredient(s) still unsourced: %', v_unbuildable;
  end if;

  raise notice 'ACTIVATE_SHIPYARD_PASS_SMOKE ok: shipyard_enabled true, blueprint faucet > 0, strike_corvette recipe fully sourced (build-loop reachable)';
end $$;

select 'SHIPYARD ACTIVATION PASS — the ship BUILD LOOP is UNLOCKED. shipyard_enabled is true (start_hull_build enqueues; the 30s cron promotes, times, and delivers a commissioned hull at Haven Reach) and the blueprint faucet is open (blueprint_fragment_drop_rate 0.15 [D] — wave>=8 grinding now yields the ×2 fragments each T1 recipe needs). REACHABILITY FINDING: opening the faucet DOES make both T1 hulls buildable — every ingredient (ore/crystal via mining, scrap/pirate_alloy/weapon_parts/engine_parts + blueprint_fragment via combat) has a live faucet; NO ingredient is left without a source. SHIPYARD-2''s hull-aware cancel refund (0194) is confirmed in place. Requires mining + combat lit (the dependency chain). A build-order UI is SHIPYARD-3''s concern.' as result;

commit;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- To dark ship production again, run the reverse writes below (uncomment, run once). Notes:
--   • shipyard_enabled → false: the order RPC rejects gate-first again (feature_disabled). Already-
--     queued builds STILL FINISH — the cron delivery path never reads the flag (a paid build is not
--     stranded); only NEW orders are blocked.
--   • blueprint_fragment_drop_rate → 0: wave>=8 stops dropping fragments (byte-identical 0171 loot).
--   • No data reverts (delivered ships, spent ingredients, receipts all stand).
--
-- begin;
-- select public.set_game_config('shipyard_enabled', 'false'::jsonb);
-- select public.set_game_config('blueprint_fragment_drop_rate', '0'::jsonb);
-- select key, value from public.game_config where key in ('shipyard_enabled','blueprint_fragment_drop_rate') order by key;
-- commit;
