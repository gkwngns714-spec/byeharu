-- OSN-ENABLEMENT-2 — the ONE controlled OSN port-to-port ENABLE operation.
--
-- This is the EXACT transaction the gated production workflow runs, and the same transaction the disposable
-- proof exercises. It is HARD-CODED: it accepts NO operator-supplied SQL, flag name, value, key, environment,
-- host, or ref. It flips exactly ONE game_config key — mainship_space_movement_enabled — from false to true,
-- exactly once, guarded by preconditions and postconditions.
--
-- One session, one transaction:
--   (1) conservative lock/statement timeouts;
--   (2) lock the two flag rows (key order) so snapshot→flip→postcondition is atomic;
--   (3) snapshot: both flags, migration head, canonical-port active/hidden counts, the OSN-safety structure,
--       and an md5 digest of EVERY game_config key EXCEPT the one being flipped;
--   (4) ASSERT the untouched pre-enable baseline (head 0068; OSN flag currently false [refuse to re-enable];
--       send=true; exactly 3 canonical ports active, 0 hidden; OSN-safety structure present) — the flip is
--       NOT performed unless every precondition holds;
--   (5) flip mainship_space_movement_enabled to true EXACTLY ONCE (one key, one update);
--   (6) ASSERT the postconditions: the flag now reads true (value + cfg_bool); mainship_send_enabled is
--       byte-for-byte unchanged; EVERY OTHER game_config key is byte-for-byte unchanged (only-this-key
--       invariance — an offsetting change to any other key is caught); canonical ports still 3 active;
--   (7) emit machine-readable success markers ONLY after all assertions pass;
--   (8) COMMIT only if every assertion passed.

\set ON_ERROR_STOP on

begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local idle_in_transaction_session_timeout = '30s';

do $$
declare
  c_flag constant text := 'mainship_space_movement_enabled';
  c_send constant text := 'mainship_send_enabled';
  c_p1 constant uuid := 'b1a00001-0066-4a00-8a00-000000000001';
  c_p2 constant uuid := 'b1a00002-0066-4a00-8a00-000000000002';
  c_p3 constant uuid := 'b1a00003-0066-4a00-8a00-000000000003';
  v_space_before jsonb;  v_send_before jsonb;
  v_space_after  jsonb;  v_send_after  jsonb;
  v_head text;           v_n_after int;
  v_active int;          v_hidden int;
  v_other_before text;   v_other_after text;   -- digest of EVERY game_config key except c_flag
  v_struct_ok boolean;
begin
  -- (2) lock the flag rows so the snapshot→flip→postcondition window is atomic
  perform 1 from public.game_config where key in (c_flag, c_send) order by key for update;

  -- (3) snapshot
  select value into v_space_before from public.game_config where key = c_flag;
  select value into v_send_before  from public.game_config where key = c_send;
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  select count(*) into v_n_after from supabase_migrations.schema_migrations where version > '20260618000068';
  select count(*) into v_active from public.locations where id in (c_p1,c_p2,c_p3) and status = 'active';
  select count(*) into v_hidden from public.locations where id in (c_p1,c_p2,c_p3) and status = 'hidden';
  select md5(coalesce(string_agg(key || '=' || value::text, ',' order by key), ''))
    into v_other_before from public.game_config where key <> c_flag;
  select
    (select count(*) from pg_constraint c join pg_class t on t.oid = c.conrelid
        join pg_namespace nn on nn.oid = t.relnamespace
       where nn.nspname='public' and t.relname='fleets' and c.contype='c'
         and pg_get_constraintdef(c.oid) ilike '%active_movement_id%'
         and pg_get_constraintdef(c.oid) ilike '%active_space_movement_id%') >= 1
    and (select count(*) from pg_indexes where schemaname='public'
           and indexname='main_ship_space_movements_one_active_per_ship') = 1
    and (select count(*) from pg_indexes where schemaname='public'
           and indexname='main_ship_space_movements_one_active_per_fleet') = 1
    and (select count(*) from pg_constraint c join pg_class t on t.oid = c.conrelid
        join pg_namespace nn on nn.oid = t.relnamespace
       where nn.nspname='public' and t.relname='main_ship_space_command_receipts' and c.contype='u'
         and pg_get_constraintdef(c.oid) ilike '%request_id%') >= 1
    and to_regprocedure('public.mainship_space_dock_at_location(uuid,uuid)') is not null
    and to_regprocedure('public.command_main_ship_space_move_to_location(uuid,uuid)') is not null
    and to_regprocedure('public.get_osn_movement_readiness()') is not null
    into v_struct_ok;

  -- (4) PRECONDITIONS — the flip is NOT performed unless every one holds
  if v_head is distinct from '20260618000068' then raise exception 'PRECOND FAIL: migration head % (expected 0068)', v_head; end if;
  if v_n_after <> 0 then raise exception 'PRECOND FAIL: % migration(s) after 0068', v_n_after; end if;
  if v_space_before is distinct from 'false'::jsonb then raise exception 'PRECOND FAIL: mainship_space_movement_enabled is already % (expected false; refusing to re-enable)', v_space_before; end if;
  if v_send_before  is distinct from 'true'::jsonb  then raise exception 'PRECOND FAIL: mainship_send_enabled is % (expected true)', v_send_before; end if;
  if v_active <> 3 then raise exception 'PRECOND FAIL: % canonical starter ports active (expected 3)', v_active; end if;
  if v_hidden <> 0 then raise exception 'PRECOND FAIL: % canonical starter ports hidden (expected 0)', v_hidden; end if;
  if not v_struct_ok then raise exception 'PRECOND FAIL: OSN-safety structure missing (exclusivity / one-active indexes / receipt idempotency / dock / move-to-location / readiness)'; end if;
  raise notice 'PRECONDITIONS_PASS=true';
  raise notice 'OSN_FLAG_BEFORE=%', v_space_before;

  -- (5) THE ONE FLAG FLIP — exactly this one key, exactly once
  update public.game_config set value = 'true'::jsonb where key = c_flag;
  raise notice 'OSN_FLAG_WRITES=1';

  -- (6) POSTCONDITIONS
  select value into v_space_after from public.game_config where key = c_flag;
  select value into v_send_after  from public.game_config where key = c_send;
  select md5(coalesce(string_agg(key || '=' || value::text, ',' order by key), ''))
    into v_other_after from public.game_config where key <> c_flag;
  if v_space_after is distinct from 'true'::jsonb then raise exception 'POSTCOND FAIL: OSN flag is % after enable (expected true)', v_space_after; end if;
  if not public.cfg_bool(c_flag) then raise exception 'POSTCOND FAIL: cfg_bool(mainship_space_movement_enabled) does not read true'; end if;
  if v_send_after is distinct from v_send_before then raise exception 'POSTCOND FAIL: mainship_send_enabled changed (% -> %)', v_send_before, v_send_after; end if;
  if v_other_after is distinct from v_other_before then raise exception 'POSTCOND FAIL: a game_config key OTHER than the OSN flag changed (only-this-key invariance broken)'; end if;
  if (select count(*) from public.locations where id in (c_p1,c_p2,c_p3) and status = 'active') <> 3 then raise exception 'POSTCOND FAIL: canonical starter-port active count changed'; end if;
  raise notice 'OSN_FLAG_AFTER=%', v_space_after;
  raise notice 'SEND_FLAG_UNCHANGED=true';
  raise notice 'OTHER_CONFIG_UNCHANGED=true';
  raise notice 'OSN_ENABLE_OPERATION_PASS=true';
end $$;

commit;
