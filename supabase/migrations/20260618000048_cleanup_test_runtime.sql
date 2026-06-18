-- Byeharu — Prevention Phase C: self-cleaning verify runs.
--
-- Verify scripts create throwaway auth users whose emails all match '%test%@example.com'
-- (m4test/m5test/m45test/invtest/p4test…p8test). Every runtime table carries player_id,
-- so verify-created RUNTIME rows are precisely "rows owned by a test-email player". This
-- function deletes ONLY those runtime rows. No test_run_id column is needed (the existing
-- test-email convention is the cleanup key).
--
-- SAFETY:
--   · Pattern MUST contain 'test' (guards against a broad/real-user wipe).
--   · Touches ONLY the 9 runtime tables (+ fleet_units): combat_ticks/events/reports/
--     encounters, location_presence, fleet_movements, fleet_units, fleets, reward_grants,
--     build_orders. Deletes child rows before parents.
--   · NEVER touches auth.users, bases, base_units, base_resources, player_inventory,
--     inventory_ledger, main_ship_instances, *_types, game_config, or world tables.
--   · NEVER TRUNCATE. dry-run by default. SECURITY DEFINER, service_role only.

create or replace function public.cleanup_test_runtime(
  p_pattern text default '%test%@example.com',
  p_dry_run boolean default true)
returns table (
  table_name   text,
  rows_matched bigint,
  rows_deleted bigint,
  cleanup_key  text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids uuid[];
  v_m   bigint;
  v_d   bigint;
begin
  if position('test' in lower(coalesce(p_pattern, ''))) = 0 then
    raise exception 'cleanup_test_runtime: refusing — pattern must contain "test" (got %)', p_pattern;
  end if;
  select coalesce(array_agg(id), array[]::uuid[]) into v_ids
    from auth.users where email ilike p_pattern;

  -- child → parent order (FKs are ON DELETE CASCADE, but explicit order gives exact counts)

  select count(*) into v_m from combat_ticks where player_id = any(v_ids);
  v_d := 0; if not p_dry_run and v_m > 0 then delete from combat_ticks where player_id = any(v_ids); get diagnostics v_d = row_count; end if;
  table_name:='combat_ticks'; rows_matched:=v_m; rows_deleted:=v_d; cleanup_key:=p_pattern; return next;

  select count(*) into v_m from combat_events where player_id = any(v_ids);
  v_d := 0; if not p_dry_run and v_m > 0 then delete from combat_events where player_id = any(v_ids); get diagnostics v_d = row_count; end if;
  table_name:='combat_events'; rows_matched:=v_m; rows_deleted:=v_d; cleanup_key:=p_pattern; return next;

  select count(*) into v_m from combat_reports where player_id = any(v_ids);
  v_d := 0; if not p_dry_run and v_m > 0 then delete from combat_reports where player_id = any(v_ids); get diagnostics v_d = row_count; end if;
  table_name:='combat_reports'; rows_matched:=v_m; rows_deleted:=v_d; cleanup_key:=p_pattern; return next;

  select count(*) into v_m from combat_encounters where player_id = any(v_ids);
  v_d := 0; if not p_dry_run and v_m > 0 then delete from combat_encounters where player_id = any(v_ids); get diagnostics v_d = row_count; end if;
  table_name:='combat_encounters'; rows_matched:=v_m; rows_deleted:=v_d; cleanup_key:=p_pattern; return next;

  select count(*) into v_m from fleet_units where fleet_id in (select id from fleets where player_id = any(v_ids));
  v_d := 0; if not p_dry_run and v_m > 0 then delete from fleet_units where fleet_id in (select id from fleets where player_id = any(v_ids)); get diagnostics v_d = row_count; end if;
  table_name:='fleet_units'; rows_matched:=v_m; rows_deleted:=v_d; cleanup_key:=p_pattern; return next;

  select count(*) into v_m from fleet_movements where player_id = any(v_ids);
  v_d := 0; if not p_dry_run and v_m > 0 then delete from fleet_movements where player_id = any(v_ids); get diagnostics v_d = row_count; end if;
  table_name:='fleet_movements'; rows_matched:=v_m; rows_deleted:=v_d; cleanup_key:=p_pattern; return next;

  select count(*) into v_m from location_presence where player_id = any(v_ids);
  v_d := 0; if not p_dry_run and v_m > 0 then delete from location_presence where player_id = any(v_ids); get diagnostics v_d = row_count; end if;
  table_name:='location_presence'; rows_matched:=v_m; rows_deleted:=v_d; cleanup_key:=p_pattern; return next;

  select count(*) into v_m from fleets where player_id = any(v_ids);
  v_d := 0; if not p_dry_run and v_m > 0 then delete from fleets where player_id = any(v_ids); get diagnostics v_d = row_count; end if;
  table_name:='fleets'; rows_matched:=v_m; rows_deleted:=v_d; cleanup_key:=p_pattern; return next;

  select count(*) into v_m from reward_grants where player_id = any(v_ids);
  v_d := 0; if not p_dry_run and v_m > 0 then delete from reward_grants where player_id = any(v_ids); get diagnostics v_d = row_count; end if;
  table_name:='reward_grants'; rows_matched:=v_m; rows_deleted:=v_d; cleanup_key:=p_pattern; return next;

  select count(*) into v_m from build_orders where player_id = any(v_ids);
  v_d := 0; if not p_dry_run and v_m > 0 then delete from build_orders where player_id = any(v_ids); get diagnostics v_d = row_count; end if;
  table_name:='build_orders'; rows_matched:=v_m; rows_deleted:=v_d; cleanup_key:=p_pattern; return next;

  return;
end;
$$;

-- ── Re-lock (anti-cheat). New function → revoke from public; service_role only. ──
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
grant execute on function public.get_world_map()                           to anon, authenticated;
grant execute on function public.bootstrap_me()                            to authenticated;
grant execute on function public.send_fleet_to_location(uuid, uuid, jsonb) to authenticated;
grant execute on function public.request_leave_location(uuid)              to authenticated;
grant execute on function public.request_retreat(uuid)                     to authenticated;
grant execute on function public.get_combat_reports()                      to authenticated;
grant execute on function public.train_units(uuid, text, integer)          to authenticated;
grant execute on function public.cancel_build_order(uuid)                  to authenticated;
grant execute on function public.cleanup_test_runtime(text, boolean)       to service_role;
