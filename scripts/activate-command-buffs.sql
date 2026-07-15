-- COMMAND-BUFFS ACTIVATION — the FINALE of the owner's fleet reshape (docs/FULL_CAPACITY_PLAN.md
-- §FLEET; migration 0205). The system is FULLY BUILT DARK: the per-hull TIER column, the
-- command_buff_types catalog (~10 per tier), the ship BUFF SLOT (main_ship_instances.command_buff_id,
-- rolled deterministically at commission by an AFTER-INSERT trigger + backfilled, immutable), and the
-- FLEET-WIDE fold in calculate_expedition_stats — all gated on command_buffs_enabled (seeded false).
-- The client dossier reads the SAME flag at runtime via strictConfigFlag('command_buffs_enabled').
--
-- ██ HUMAN ACTIVATION TOOL ██ — run BY THE HUMAN, deliberately, against prod. NOT CI; nothing flips at
-- build/deploy time. Each run of this file IS the recorded human go decision.
--
-- ██ THE BEHAVIOR CHANGE (read before flipping) ██
--   Flipping this flag makes a fleet's FIRST ACTIVE command ship's rolled command buff apply
--   FLEET-WIDE: calculate_expedition_stats starts folding the buff's stats into EVERY fleet member's
--   totals (combat power / survival / cargo / speed / …). ONE BUFF PER FLEET — no stacking, no
--   backups (owner decision 2026-07-16): the fold takes `order by created_at, main_ship_id limit 1`,
--   so a second/third designated command ship contributes NOTHING. A fleet with no command ship, or a
--   game where no ship is a command ship, sees NO change — the fold is inert without an
--   is_command_ship member. So the visible impact scales with how many fleets already have a command
--   ship designated (the smoke reports it), and is capped at ONE buff per fleet regardless.
--   DEPENDENCY: is_command_ship is only meaningfully SET through the FLEET-CONTROL surface, so this
--   activation REQUIRES fleet_control_enabled to already be committed true — otherwise players have no
--   way to designate command ships and the buffs can never light.
--
-- ── WHAT IT DOES (one transaction; COMMIT only if every assert passes) ─────────────────────────────
--   PRECONDITIONS (no write until these hold):
--     • migration head >= 20260618000205 AND 0205 recorded in supabase_migrations.schema_migrations;
--     • command_buff_types exists; main_ship_instances.command_buff_id exists; main_ship_hull_types.tier
--       exists; the game_config key command_buffs_enabled exists (0205 seeds it false — a typo can never
--       invent a key; its VALUE is not asserted false so a RE-RUN after success is a supported no-op);
--     • calculate_expedition_stats + command_buff_roll_for_ship exist (the REAL signatures) AND the
--       DEPLOYED adapter body is the 0205 head — the marked COMMAND-BUFFS fold is prosrc-pinned
--       (command_buffs_enabled gate + the is_command_ship-scoped command_buff_types read);
--     • CATALOG FREEZE: >= 10 buffs per current tier (the rolls derive into the pool's size+order — a
--       thin pool would mean an incomplete roll; a FROZEN pool is the precondition the deterministic
--       derivation relies on, the 0186/ACT-SOUL catalog-freeze law);
--     • EVERY ship whose hull tier has a pool already carries a rolled buff (the commission trigger +
--       the 0205 backfill did their job — no ship is buff-less at flip time);
--     • team_command_enabled AND fleet_control_enabled are COMMITTED true — command buffs ride the LIVE
--       fleet command-ship model; flipping them on a game with no command-ship surface is a dead effect.
--   STAGE 1 — the switch (the ONE flag write, via the owned set_game_config writer):
--     command_buffs_enabled → true.
--   SMOKE (read-only): the flag is committed (raw + cfg_bool); an FYI count of currently-active command
--     ships (whose buffs now fold fleet-wide); the catalog + buff-slot coverage re-confirmed.
--   Emits ACTIVATE_CMDBUFF_PASS_* markers per stage and one final PASS line; any failed assert RAISES →
--   the whole transaction rolls back → NOTHING is applied (all-or-nothing activation).
--
-- RE-RUN SEMANTICS (decided, documented): safe no-op success. The flag write is a set_game_config upsert
-- to the same value; nothing else is written.
--
-- ── NO CLIENT PR IS NEEDED ─────────────────────────────────────────────────────────────────────────
--   The dossier's Command buff line is RUNTIME-flag-gated (strictConfigFlag('command_buffs_enabled'),
--   read by fetchShipCommandBuff), NOT compile-gated — there is NO COMMAND_BUFFS_* constant. The buff
--   card lights the moment this flag commits and the client re-polls the config — no deploy, no PR.
--   (The card ALREADY shows the rolled buff's name/effect once lit; the fleet-wide fold is server-side.)
--
-- ── WHAT IT DELIBERATELY DOES NOT TOUCH ────────────────────────────────────────────────────────────
--   • main_ship_instances.command_buff_id rows — NEVER written here (only the roll trigger/backfill
--     writes them; this script's only direct write is the ONE set_game_config upsert).
--   • main_ship_instances.is_command_ship rows — owners designate their own command ships (FLEET-CONTROL).
--   • Every other window's key. Any table other than game_config. Any DDL. Any migration.
--
-- ── INVOCATION (Management-API compatible: NO psql meta-commands; one BEGIN..COMMIT) ───────────────
--   psql "<prod session-pooler conn (pinned CA, sslmode=verify-full)>" -X -v ON_ERROR_STOP=1 \
--        -f scripts/activate-command-buffs.sql
--   Or paste this whole file into the Supabase Dashboard SQL editor / management-API runner, or:
--     bash scripts/activate-command-buffs.sh run ACTIVATE_CMDBUFF      # DB_URL required
--   AFTER a green run: manual smoke — open a ship's dossier → the Command buff line shows its rolled
--   buff + "Applies to the whole fleet when this ship is the command ship"; set that ship as its fleet's
--   command ship (Fleets panel) → every fleet member's Ship stats gain the buff.
--
-- ── ROLLBACK ───────────────────────────────────────────────────────────────────────────────────────
--   See the marked ROLLBACK section at the BOTTOM (commented out). FLAG-ONLY: command_buffs_enabled →
--   false. The adapter drops the fleet-buff fold again (byte-identical to today), and the dossier's buff
--   line hides on the next config poll — INSTANTLY. The rolled command_buff_id + is_command_ship rows
--   persist untouched (inert while dark) and reactivate on a re-flip.

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local idle_in_transaction_session_timeout = '60s';

-- ══════════ PRECONDITIONS (read-only; no write happens unless all pass) ══════════
do $$
declare
  v_head text; fn text; v_src text; v_n int;
begin
  -- 0205 deployed AND recorded (head alone is not enough).
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  if v_head is null or v_head < '20260618000205' then
    raise exception 'PRECONDITION FAIL: migration head % < 20260618000205 (the COMMAND-BUFFS migration) — deploy it first', coalesce(v_head, '(none)');
  end if;
  if not exists (select 1 from supabase_migrations.schema_migrations s where s.version = '20260618000205') then
    raise exception 'PRECONDITION FAIL: migration 20260618000205 not recorded as deployed';
  end if;

  -- the catalog table, the buff-slot column, the tier column, the flag key.
  if to_regclass('public.command_buff_types') is null then
    raise exception 'PRECONDITION FAIL: command_buff_types table missing (deploy 0205)'; end if;
  if not exists (select 1 from information_schema.columns
      where table_schema='public' and table_name='main_ship_instances' and column_name='command_buff_id') then
    raise exception 'PRECONDITION FAIL: main_ship_instances.command_buff_id missing (deploy 0205)'; end if;
  if not exists (select 1 from information_schema.columns
      where table_schema='public' and table_name='main_ship_hull_types' and column_name='tier') then
    raise exception 'PRECONDITION FAIL: main_ship_hull_types.tier missing (deploy 0205)'; end if;
  if not exists (select 1 from public.game_config where key = 'command_buffs_enabled') then
    raise exception 'PRECONDITION FAIL: game_config key command_buffs_enabled missing (0205 seeds it false)'; end if;

  -- the function surface — the REAL signatures.
  foreach fn in array array[
    'public.calculate_expedition_stats(uuid, uuid, jsonb, text)',
    'public.command_buff_roll_for_ship(uuid)',
    'public.cfg_bool(text)',
    'public.set_game_config(text, jsonb)'] loop
    if to_regprocedure(fn) is null then
      raise exception 'PRECONDITION FAIL: function % does not exist', fn;
    end if;
  end loop;

  -- the DEPLOYED adapter body is the 0205 head — the marked COMMAND-BUFFS fold is present (the gate read
  -- + the is_command_ship-scoped command_buff read). A pre-0205 adapter would silently never fold.
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.calculate_expedition_stats(uuid, uuid, jsonb, text)')::oid;
  if position('command_buffs_enabled' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed calculate_expedition_stats lacks the command_buffs_enabled gate (not the 0205 head)'; end if;
  if position('command_buff_types' in v_src) = 0 or position('is_command_ship' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed adapter lacks the is_command_ship-scoped command_buff fold (not the 0205 head)'; end if;

  -- CATALOG FREEZE: >= 10 buffs per current tier (the deterministic roll derives into the pool — a thin
  -- pool means an incomplete catalog; the 0186/ACT-SOUL freeze law).
  select min(c) into v_n from (select count(*) c from public.command_buff_types group by tier) q;
  if coalesce(v_n, 0) < 10 then
    raise exception 'PRECONDITION FAIL: a command-buff tier holds only % buffs (want >= 10 per tier — the catalog-freeze law)', coalesce(v_n, 0); end if;

  -- BUFF-SLOT COVERAGE: every ship whose hull tier has a pool already carries a rolled buff (the
  -- commission trigger + the 0205 backfill). A NULL here would mean a ship gets no buff at flip time.
  select count(*) into v_n
    from public.main_ship_instances i
    join public.main_ship_hull_types h on h.hull_type_id = i.hull_type_id
    join (select tier, count(*) c from public.command_buff_types group by tier) p on p.tier = h.tier
    where i.command_buff_id is null;
  if v_n <> 0 then
    raise exception 'PRECONDITION FAIL: % ship(s) with a pooled hull tier carry no rolled buff (the roll/backfill is incomplete)', v_n; end if;

  -- command buffs ride the LIVE fleet command-ship model: BOTH team_command_enabled AND
  -- fleet_control_enabled must be committed true (without a command-ship surface the fold can never light).
  if (select value #>> '{}' from public.game_config where key = 'team_command_enabled') is distinct from 'true'
     or not public.cfg_bool('team_command_enabled') then
    raise exception 'PRECONDITION FAIL: team_command_enabled is not committed true — command buffs ride the live fleet system'; end if;
  if (select value #>> '{}' from public.game_config where key = 'fleet_control_enabled') is distinct from 'true'
     or not public.cfg_bool('fleet_control_enabled') then
    raise exception 'PRECONDITION FAIL: fleet_control_enabled is not committed true — command buffs need the FLEET-CONTROL command-ship surface (is_command_ship is only meaningfully set there); activate FLEET-CONTROL first'; end if;

  raise notice 'ACTIVATE_CMDBUFF_PASS_PRECONDITIONS ok: head %, 0205 recorded; catalog/buff-slot/tier + command_buffs_enabled key present; the adapter + roll writer present (real signatures) with the command_buffs_enabled gate + is_command_ship-scoped fold prosrc-pinned; catalog frozen (>= 10/tier); every pooled-tier ship carries a rolled buff; team_command_enabled + fleet_control_enabled committed true', v_head;
end $$;

-- ══════════ STAGE 1 — the switch (the ONE flag write) ══════════
do $$
declare v_before text;
begin
  select value::text into v_before from public.game_config where key = 'command_buffs_enabled';
  perform public.set_game_config('command_buffs_enabled', 'true'::jsonb);
  raise notice 'stage 1: command_buffs_enabled % -> true', v_before;
  raise notice 'ACTIVATE_CMDBUFF_PASS_STAGE1 ok: command_buffs_enabled=true (uncommitted until the smoke passes — one all-or-nothing txn)';
end $$;

-- ══════════ SMOKE — read-only ══════════
do $$
declare v_active int; v_total int;
begin
  -- (a) the committed flag value is exactly the activation state (raw + through the reader).
  if (select value #>> '{}' from public.game_config where key = 'command_buffs_enabled') is distinct from 'true' then
    raise exception 'SMOKE FAIL: command_buffs_enabled is % (want true)',
      (select value #>> '{}' from public.game_config where key = 'command_buffs_enabled');
  end if;
  if not public.cfg_bool('command_buffs_enabled') then
    raise exception 'SMOKE FAIL: cfg_bool(command_buffs_enabled) still false'; end if;

  -- (b) FYI — how many command ships are currently ACTIVE (their buffs now fold fleet-wide). Zero is a
  --     valid state (nobody has designated one yet) — the buffs light per fleet as owners do. NOT a block.
  select count(*) into v_active from public.main_ship_instances where is_command_ship and group_id is not null;
  select count(*) into v_total from public.ship_groups;
  raise notice 'smoke: % active command ship(s) across % fleet(s) — their rolled buffs now fold fleet-wide; other fleets light as owners designate a command ship', v_active, v_total;

  raise notice 'ACTIVATE_CMDBUFF_PASS_SMOKE ok: flag committed true; % active command ship(s) across % fleets now folding buffs fleet-wide', v_active, v_total;
end $$;

select 'COMMAND-BUFFS ACTIVATION PASS — the fleet-wide command-buff fold is LIVE. calculate_expedition_stats now folds a fleet''s FIRST ACTIVE command ship''s rolled command buff into every fleet member''s totals — ONE buff per fleet, no stacking and no backups (extra command ships fold nothing). NO client PR is needed: the dossier Command buff line is runtime-flag-gated (strictConfigFlag/fetchShipCommandBuff) and lights on the next config poll. IMMEDIATE PLAYER IMPACT: every fleet with a designated command ship gains that ONE ship''s buff fleet-wide; fleets with no command ship are unchanged until their owner sets one.' as result;

commit;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- To dark the command-buff fold again, run the reverse write below (uncomment, run once). Notes:
--   • FLAG-ONLY: command_buffs_enabled → false. The adapter drops the fleet-buff fold (byte-identical to
--     today's fleet game); the dossier's buff line hides on the next config poll — INSTANTLY.
--   • The rolled command_buff_id + is_command_ship rows persist untouched (inert while dark) and
--     reactivate on a re-flip — nothing to clean up. No table other than game_config was ever written.
--
-- begin;
-- select public.set_game_config('command_buffs_enabled', 'false'::jsonb);
-- select key, value from public.game_config where key = 'command_buffs_enabled';
-- commit;
