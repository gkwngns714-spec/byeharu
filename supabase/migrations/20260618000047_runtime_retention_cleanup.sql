-- Byeharu — Prevention Phase B: safe retention cleanup (batched, dry-run-first).
--
-- Deletes ONLY expired, terminal runtime rows in small batches. NEVER TRUNCATE. NEVER
-- touches active gameplay, seeded config/world, or permanent player-owned data (bases,
-- base_resources, base_units, player_inventory, inventory_ledger, main_ship_instances,
-- *_types, game_config, sectors/zones/locations). It is gated by `runtime_cleanup_enabled`
-- and defaults to dry-run.
--
-- SCHEMA RECONCILIATION (inspected, not assumed):
--   · combat_ticks    has resolved_at, NOT created_at  → retention/index use resolved_at.
--   · fleet_movements has NO updated_at                → use resolved_at (set on resolve).
--   · reward_grants   has granted_at, NOT claimed_at    → use granted_at (all grants are
--                       already-secured deposits; there is NO "pending" row in this table —
--                       pending rewards live on combat_encounters/fleet_movements jsonb).
--
-- CASCADE HAZARD (inspected): ON DELETE CASCADE chains all root at `fleets`:
--   fleets → fleet_units, fleet_movements, location_presence, combat_encounters
--   combat_encounters → combat_ticks, combat_events, combat_reports
--   location_presence → combat_encounters (via presence_id)
-- Because combat_reports (30d) hangs under encounters/presence/fleets, deleting any of
-- those ancestors would cascade-delete a still-retained report. So those three are
-- additionally gated: never delete one that has an ACTIVE encounter or a RETAINED report.
-- Net effect: encounters/presence/fleets are effectively kept until their report also
-- expires (≈30d); non-combat presence (no report) still cleans at its own short rule.

-- ── A. Indexes for the retention scans (real columns; IF NOT EXISTS) ─────────────
create index if not exists combat_ticks_resolved_at_idx       on public.combat_ticks (resolved_at);          -- spec said created_at (absent)
create index if not exists combat_events_created_at_idx       on public.combat_events (created_at);
create index if not exists combat_reports_created_at_idx      on public.combat_reports (created_at);
create index if not exists combat_encounters_status_updated_idx on public.combat_encounters (status, updated_at);
create index if not exists location_presence_updated_at_idx   on public.location_presence (updated_at);
create index if not exists fleet_movements_status_resolved_idx on public.fleet_movements (status, resolved_at); -- spec said updated_at (absent)
create index if not exists fleet_units_fleet_id_idx           on public.fleet_units (fleet_id);
create index if not exists fleets_status_updated_idx          on public.fleets (status, updated_at);
create index if not exists reward_grants_granted_at_idx       on public.reward_grants (granted_at);            -- spec said claimed_at (absent)
create index if not exists build_orders_status_updated_idx    on public.build_orders (status, updated_at);

-- ── B. maintenance_cleanup_runtime_data ─────────────────────────────────────────
create or replace function public.maintenance_cleanup_runtime_data(
  dry_run boolean default true,
  batch_limit integer default 5000)
returns table (
  table_name     text,
  retention_rule text,
  rows_matched   bigint,
  rows_deleted   bigint,
  dry_run        boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dry        boolean := dry_run;
  v_batch      integer := greatest(1, least(coalesce(batch_limit, 5000), 50000));
  v_now        timestamptz := now();
  v_cut_ticks  timestamptz := v_now - make_interval(days => coalesce(cfg_num('combat_tick_retention_days')::int, 3));
  v_cut_events timestamptz := v_now - make_interval(days => coalesce(cfg_num('combat_event_retention_days')::int, 7));
  v_cut_report timestamptz := v_now - make_interval(days => coalesce(cfg_num('combat_report_retention_days')::int, 30));
  v_cut_14     timestamptz := v_now - interval '14 days';
  v_cut_1      timestamptz := v_now - interval '1 day';
  v_cut_30     timestamptz := v_now - interval '30 days';
  v_matched    bigint;
  v_deleted    bigint;
  v_n          bigint;
begin
  -- Master kill-switch: if cleanup is disabled, force dry-run (report only, never delete).
  if not cfg_bool('runtime_cleanup_enabled') then
    v_dry := true;
  end if;

  -- 1) combat_ticks — resolved_at older than retention (leaf; high volume).
  select count(*) into v_matched from combat_ticks where resolved_at < v_cut_ticks;
  v_deleted := 0;
  if not v_dry and v_matched > 0 then
    loop
      delete from combat_ticks where ctid in (select ctid from combat_ticks where resolved_at < v_cut_ticks limit v_batch);
      get diagnostics v_n = row_count; v_deleted := v_deleted + v_n; exit when v_n = 0;
    end loop;
  end if;
  table_name:='combat_ticks'; retention_rule:='resolved_at < now()-tick_retention'; rows_matched:=v_matched; rows_deleted:=v_deleted; dry_run:=v_dry; return next;

  -- 2) combat_events — created_at older than retention (leaf; high volume).
  select count(*) into v_matched from combat_events where created_at < v_cut_events;
  v_deleted := 0;
  if not v_dry and v_matched > 0 then
    loop
      delete from combat_events where ctid in (select ctid from combat_events where created_at < v_cut_events limit v_batch);
      get diagnostics v_n = row_count; v_deleted := v_deleted + v_n; exit when v_n = 0;
    end loop;
  end if;
  table_name:='combat_events'; retention_rule:='created_at < now()-event_retention'; rows_matched:=v_matched; rows_deleted:=v_deleted; dry_run:=v_dry; return next;

  -- 3) combat_reports — created_at older than retention (player-facing; leaf).
  select count(*) into v_matched from combat_reports where created_at < v_cut_report;
  v_deleted := 0;
  if not v_dry and v_matched > 0 then
    loop
      delete from combat_reports where ctid in (select ctid from combat_reports where created_at < v_cut_report limit v_batch);
      get diagnostics v_n = row_count; v_deleted := v_deleted + v_n; exit when v_n = 0;
    end loop;
  end if;
  table_name:='combat_reports'; retention_rule:='created_at < now()-report_retention'; rows_matched:=v_matched; rows_deleted:=v_deleted; dry_run:=v_dry; return next;

  -- 4) combat_encounters — terminal, >14d, AND no retained report (cascade guard).
  select count(*) into v_matched from combat_encounters e
    where e.status in ('escaped','defeat','completed') and e.updated_at < v_cut_14
      and not exists (select 1 from combat_reports r where r.encounter_id = e.id and r.created_at >= v_cut_report);
  v_deleted := 0;
  if not v_dry and v_matched > 0 then
    loop
      delete from combat_encounters where ctid in (
        select e.ctid from combat_encounters e
        where e.status in ('escaped','defeat','completed') and e.updated_at < v_cut_14
          and not exists (select 1 from combat_reports r where r.encounter_id = e.id and r.created_at >= v_cut_report)
        limit v_batch);
      get diagnostics v_n = row_count; v_deleted := v_deleted + v_n; exit when v_n = 0;
    end loop;
  end if;
  table_name:='combat_encounters'; retention_rule:='terminal & >14d & no retained report'; rows_matched:=v_matched; rows_deleted:=v_deleted; dry_run:=v_dry; return next;

  -- 5) location_presence — terminal, >1d, no active encounter, no retained report.
  select count(*) into v_matched from location_presence lp
    where lp.status in ('completed','destroyed','expired') and lp.updated_at < v_cut_1
      and not exists (select 1 from combat_encounters e where e.presence_id = lp.id
                        and (e.status in ('active','retreating')
                             or exists (select 1 from combat_reports r where r.encounter_id = e.id and r.created_at >= v_cut_report)));
  v_deleted := 0;
  if not v_dry and v_matched > 0 then
    loop
      delete from location_presence where ctid in (
        select lp.ctid from location_presence lp
        where lp.status in ('completed','destroyed','expired') and lp.updated_at < v_cut_1
          and not exists (select 1 from combat_encounters e where e.presence_id = lp.id
                            and (e.status in ('active','retreating')
                                 or exists (select 1 from combat_reports r where r.encounter_id = e.id and r.created_at >= v_cut_report)))
        limit v_batch);
      get diagnostics v_n = row_count; v_deleted := v_deleted + v_n; exit when v_n = 0;
    end loop;
  end if;
  table_name:='location_presence'; retention_rule:='terminal & >1d & no active enc / retained report'; rows_matched:=v_matched; rows_deleted:=v_deleted; dry_run:=v_dry; return next;

  -- 6) fleet_movements — terminal (arrived/cancelled/failed), resolved >14d (leaf).
  select count(*) into v_matched from fleet_movements
    where status in ('arrived','cancelled','failed') and resolved_at is not null and resolved_at < v_cut_14;
  v_deleted := 0;
  if not v_dry and v_matched > 0 then
    loop
      delete from fleet_movements where ctid in (
        select ctid from fleet_movements
        where status in ('arrived','cancelled','failed') and resolved_at is not null and resolved_at < v_cut_14 limit v_batch);
      get diagnostics v_n = row_count; v_deleted := v_deleted + v_n; exit when v_n = 0;
    end loop;
  end if;
  table_name:='fleet_movements'; retention_rule:='terminal & resolved_at >14d'; rows_matched:=v_matched; rows_deleted:=v_deleted; dry_run:=v_dry; return next;

  -- 7) fleet_units — only where the parent fleet is terminal & >14d (units aren't in the
  --    report cascade, so no report guard needed).
  select count(*) into v_matched from fleet_units fu
    where exists (select 1 from fleets f where f.id = fu.fleet_id and f.status in ('completed','destroyed') and f.updated_at < v_cut_14);
  v_deleted := 0;
  if not v_dry and v_matched > 0 then
    loop
      delete from fleet_units where ctid in (
        select fu.ctid from fleet_units fu
        where exists (select 1 from fleets f where f.id = fu.fleet_id and f.status in ('completed','destroyed') and f.updated_at < v_cut_14)
        limit v_batch);
      get diagnostics v_n = row_count; v_deleted := v_deleted + v_n; exit when v_n = 0;
    end loop;
  end if;
  table_name:='fleet_units'; retention_rule:='parent fleet terminal & >14d'; rows_matched:=v_matched; rows_deleted:=v_deleted; dry_run:=v_dry; return next;

  -- 8) fleets — terminal (completed/destroyed), >14d, no active encounter, no retained
  --    report (root of the cascade; this is the catch-all that respects report retention).
  select count(*) into v_matched from fleets f
    where f.status in ('completed','destroyed') and f.updated_at < v_cut_14
      and not exists (select 1 from combat_encounters e where e.fleet_id = f.id
                        and (e.status in ('active','retreating')
                             or exists (select 1 from combat_reports r where r.encounter_id = e.id and r.created_at >= v_cut_report)));
  v_deleted := 0;
  if not v_dry and v_matched > 0 then
    loop
      delete from fleets where ctid in (
        select f.ctid from fleets f
        where f.status in ('completed','destroyed') and f.updated_at < v_cut_14
          and not exists (select 1 from combat_encounters e where e.fleet_id = f.id
                            and (e.status in ('active','retreating')
                                 or exists (select 1 from combat_reports r where r.encounter_id = e.id and r.created_at >= v_cut_report)))
        limit v_batch);
      get diagnostics v_n = row_count; v_deleted := v_deleted + v_n; exit when v_n = 0;
    end loop;
  end if;
  table_name:='fleets'; retention_rule:='terminal & >14d & no active enc / retained report'; rows_matched:=v_matched; rows_deleted:=v_deleted; dry_run:=v_dry; return next;

  -- 9) reward_grants — granted >30d (all grants are already-secured; no pending rows here).
  select count(*) into v_matched from reward_grants where granted_at < v_cut_30;
  v_deleted := 0;
  if not v_dry and v_matched > 0 then
    loop
      delete from reward_grants where ctid in (select ctid from reward_grants where granted_at < v_cut_30 limit v_batch);
      get diagnostics v_n = row_count; v_deleted := v_deleted + v_n; exit when v_n = 0;
    end loop;
  end if;
  table_name:='reward_grants'; retention_rule:='granted_at < now()-30d'; rows_matched:=v_matched; rows_deleted:=v_deleted; dry_run:=v_dry; return next;

  -- 10) build_orders — terminal (completed/cancelled), >30d. 'waiting'/'active' are LIVE.
  select count(*) into v_matched from build_orders where status in ('completed','cancelled') and updated_at < v_cut_30;
  v_deleted := 0;
  if not v_dry and v_matched > 0 then
    loop
      delete from build_orders where ctid in (
        select ctid from build_orders where status in ('completed','cancelled') and updated_at < v_cut_30 limit v_batch);
      get diagnostics v_n = row_count; v_deleted := v_deleted + v_n; exit when v_n = 0;
    end loop;
  end if;
  table_name:='build_orders'; retention_rule:='terminal & updated_at >30d'; rows_matched:=v_matched; rows_deleted:=v_deleted; dry_run:=v_dry; return next;

  return;
end;
$$;

-- ── Re-lock (anti-cheat). New function → revoke from public; grant to service_role only
--    (CI/admin). Client RPCs re-granted; prior service_role grants survive the revoke.
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
grant execute on function public.maintenance_cleanup_runtime_data(boolean, integer) to service_role;
