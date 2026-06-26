-- Byeharu — OSN v1 enablement READ-ONLY production preflight.
--
-- Single source of truth for the frozen pre-enable checks. Run by:
--   * .github/workflows/osn-enablement-preflight.yml  → against PRODUCTION (manual, gated); GO/ABORT.
--   * .github/workflows/osn3-osn4-realchain-proof.yml → against the DISPOSABLE full chain (0001..0068);
--       validates that this script executes cleanly and that the STRUCTURAL checks pass.
--
-- HARD CONTRACT:
--   * READ-ONLY by construction: a read-only transaction is opened and default_transaction_read_only is
--     set on; the script contains NO DDL / DML / grant / revoke / migration / flag write / cron change.
--   * SAFE OUTPUT only: emits named PASS/FAIL booleans plus safe constant metadata (the migration version
--     string and the flag value's storage type name). It NEVER selects or prints secrets, connection
--     strings, user/ship/movement ids, coordinates, names, or any raw row.
--   * Gating lives in the calling workflow, NOT here: this script never RAISEs. The workflows read the
--     emitted sentinels: STRUCTURAL_PASS=<t|f> (head/ACL/surface/cron, deployment-shape facts) and
--     OVERALL_PASS=<t|f> (every check, the production GO gate).
--
-- Everything below is rebuilt from the deployed schema + migration 0068:
--   game_config.value is JSONB; the flag is read by cfg_bool() as (value #>> '{}')::boolean.
--   Exact OSN routine signatures and the canonical authenticated RPC surface are taken from 0068 §G.

\set ON_ERROR_STOP on
set default_transaction_read_only = on;
begin transaction read only;

with
flag as (
  select
    count(*) as n,
    (select pg_typeof(value)::text
       from public.game_config where key = 'mainship_space_movement_enabled')        as storage_type,
    (select (value #>> '{}')::boolean
       from public.game_config where key = 'mainship_space_movement_enabled')        as as_bool
  from public.game_config
  where key = 'mainship_space_movement_enabled'
),
mig as (
  select max(version)::text as head from supabase_migrations.schema_migrations
),
rpc as (
  select
    to_regprocedure('public.command_main_ship_space_move(double precision,double precision,uuid)') as move_wrapper,
    to_regprocedure('public.command_main_ship_space_stop(uuid)')                                   as stop_wrapper,
    to_regprocedure('public.mainship_space_stop(uuid,uuid,uuid)')                                  as stop_writer,
    to_regprocedure('public.mainship_space_settle_space_arrival(uuid,uuid,timestamptz)')           as arrival_primitive,
    to_regprocedure('public.process_mainship_space_arrivals()')                                    as arrival_processor
),
surface as (
  select string_agg(p.proname, ',' order by p.proname) as names
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prokind = 'f'
    and has_function_privilege('authenticated', p.oid, 'EXECUTE')
),
cronj as (
  select
    count(*)                                          as n,
    coalesce(bool_and(active), false)                 as all_active,
    coalesce(bool_and(schedule = '30 seconds'), false) as all_30s
  from cron.job
  where jobname = 'process-mainship-space-arrivals'
),
checks as (
  select
    -- [1] flag row exists exactly once, reads false, stored as jsonb
    (flag.n = 1)                                                                  as chk1_flag_one_row,
    (flag.as_bool is false)                                                       as chk1_flag_is_false,
    flag.storage_type                                                             as chk1_flag_storage_type,
    (flag.storage_type = 'jsonb')                                                 as chk1_flag_storage_type_is_jsonb,
    -- [2] migration head is exactly 0068
    mig.head                                                                      as chk2_migration_head,
    (mig.head = '20260618000068')                                                 as chk2_migration_head_is_0068,
    -- [3] exact OSN RPC permission surface (deployed 0068 signatures)
    coalesce(rpc.move_wrapper is not null
             and has_function_privilege('authenticated', rpc.move_wrapper::oid, 'EXECUTE'), false)        as chk3_move_wrapper_auth,
    coalesce(rpc.stop_wrapper is not null
             and has_function_privilege('authenticated', rpc.stop_wrapper::oid, 'EXECUTE'), false)        as chk3_stop_wrapper_auth,
    coalesce(rpc.stop_writer is not null
             and not has_function_privilege('authenticated', rpc.stop_writer::oid, 'EXECUTE'), false)     as chk3_writer_auth_denied,
    coalesce(rpc.stop_writer is not null
             and not has_function_privilege('anon', rpc.stop_writer::oid, 'EXECUTE'), false)              as chk3_writer_anon_denied,
    coalesce(rpc.arrival_primitive is not null
             and not has_function_privilege('authenticated', rpc.arrival_primitive::oid, 'EXECUTE'), false) as chk3_primitive_auth_denied,
    coalesce(rpc.arrival_primitive is not null
             and not has_function_privilege('anon', rpc.arrival_primitive::oid, 'EXECUTE'), false)        as chk3_primitive_anon_denied,
    coalesce(rpc.arrival_processor is not null
             and not has_function_privilege('authenticated', rpc.arrival_processor::oid, 'EXECUTE'), false) as chk3_processor_auth_denied,
    coalesce(rpc.stop_writer is not null
             and has_function_privilege('service_role', rpc.stop_writer::oid, 'EXECUTE'), false)          as chk3_writer_service_role,
    coalesce(rpc.arrival_primitive is not null
             and has_function_privilege('service_role', rpc.arrival_primitive::oid, 'EXECUTE'), false)    as chk3_primitive_service_role,
    coalesce(rpc.arrival_processor is not null
             and has_function_privilege('service_role', rpc.arrival_processor::oid, 'EXECUTE'), false)    as chk3_processor_service_role,
    -- [3b] authenticated public function surface equals the canonical set (exactly 17 at head 0068)
    coalesce(
      surface.names = 'bootstrap_me,cancel_build_order,command_main_ship_space_move,command_main_ship_space_move_to_location,command_main_ship_space_stop,get_combat_reports,get_my_expedition_preview,get_osn_movement_readiness,get_world_map,move_main_ship_to_location,repair_main_ship,request_leave_location,request_main_ship_return,request_retreat,send_fleet_to_location,send_main_ship_expedition,train_units',
      false
    )                                                                             as chk3b_client_surface_is_canonical_17,
    -- [4] zero active coordinate movements (space + location target kinds) while dark
    (not exists (
       select 1 from public.main_ship_space_movements m
       where m.status = 'moving' and m.target_kind in ('space', 'location')
     ))                                                                           as chk4_zero_active_coordinate_moves,
    -- [5] arrival cron exists once and is active at 30 seconds
    (cronj.n = 1)                                                                 as chk5_cron_exactly_one_job,
    cronj.all_active                                                              as chk5_cron_job_active,
    cronj.all_30s                                                                 as chk5_cron_schedule_30s,
    -- [6] coherence — ACTIVE COORDINATE MOVEMENTS ONLY, space + location (does NOT require in_transit ships to have a coordinate move)
    (not exists (
       select 1 from public.main_ship_space_movements m
       where m.status = 'moving' and m.target_kind in ('space', 'location')
         and not exists (
           select 1 from public.main_ship_instances s
           where s.main_ship_id = m.main_ship_id and s.spatial_state = 'in_transit'
         )
     ))                                                                           as chk6_i_every_coord_move_on_in_transit_ship,
    (not exists (
       select 1 from public.main_ship_space_movements m
       where m.status = 'moving' and m.target_kind in ('space', 'location')
       group by m.main_ship_id
       having count(*) > 1
     ))                                                                           as chk6_ii_no_ship_more_than_one_coord_move,
    (not exists (
       select 1 from public.main_ship_space_movements m
       where m.status = 'moving' and m.target_kind in ('space', 'location')
         and (m.origin_x is null or m.origin_y is null
              or m.target_x is null or m.target_y is null
              or m.depart_at is null or m.arrive_at is null
              or m.arrive_at <= m.depart_at)
     ))                                                                           as chk6_iii_valid_origin_target_timing
  from flag, mig, rpc, surface, cronj
),
result as (
  select
    c.*,
    ( c.chk2_migration_head_is_0068
      and c.chk3_move_wrapper_auth and c.chk3_stop_wrapper_auth
      and c.chk3_writer_auth_denied and c.chk3_writer_anon_denied
      and c.chk3_primitive_auth_denied and c.chk3_primitive_anon_denied
      and c.chk3_processor_auth_denied
      and c.chk3_writer_service_role and c.chk3_primitive_service_role and c.chk3_processor_service_role
      and c.chk3b_client_surface_is_canonical_17
      and c.chk5_cron_exactly_one_job and c.chk5_cron_job_active and c.chk5_cron_schedule_30s
    ) as structural_pass,
    ( c.chk1_flag_one_row and c.chk1_flag_is_false and c.chk1_flag_storage_type_is_jsonb
      and c.chk2_migration_head_is_0068
      and c.chk3_move_wrapper_auth and c.chk3_stop_wrapper_auth
      and c.chk3_writer_auth_denied and c.chk3_writer_anon_denied
      and c.chk3_primitive_auth_denied and c.chk3_primitive_anon_denied
      and c.chk3_processor_auth_denied
      and c.chk3_writer_service_role and c.chk3_primitive_service_role and c.chk3_processor_service_role
      and c.chk3b_client_surface_is_canonical_17
      and c.chk4_zero_active_coordinate_moves
      and c.chk5_cron_exactly_one_job and c.chk5_cron_job_active and c.chk5_cron_schedule_30s
      and c.chk6_i_every_coord_move_on_in_transit_ship
      and c.chk6_ii_no_ship_more_than_one_coord_move
      and c.chk6_iii_valid_origin_target_timing
    ) as overall_pass
  from checks c
)
select
  r.*,
  'STRUCTURAL_PASS=' || r.structural_pass::text as structural_status,
  'OVERALL_PASS='    || r.overall_pass::text    as overall_status
from result r;

commit;
