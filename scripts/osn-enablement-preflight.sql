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
-- POST-REVEAL CURRENT STATE (OSN-ENABLEMENT-1A): the three canonical starter ports are now active/public.
-- These are RUNTIME-state checks; they live in OVERALL_PASS only (NOT STRUCTURAL_PASS) so the disposable
-- structural realchain proof — which seeds the ports HIDDEN — keeps passing on STRUCTURAL_PASS.
ports as (
  select
    count(*) filter (where id in ('b1a00001-0066-4a00-8a00-000000000001',
                                  'b1a00002-0066-4a00-8a00-000000000002',
                                  'b1a00003-0066-4a00-8a00-000000000003'))                       as canon_n,
    count(*) filter (where id in ('b1a00001-0066-4a00-8a00-000000000001',
                                  'b1a00002-0066-4a00-8a00-000000000002',
                                  'b1a00003-0066-4a00-8a00-000000000003') and status = 'active') as canon_active,
    count(*) filter (where id in ('b1a00001-0066-4a00-8a00-000000000001',
                                  'b1a00002-0066-4a00-8a00-000000000002',
                                  'b1a00003-0066-4a00-8a00-000000000003') and status = 'hidden') as canon_hidden
  from public.locations
),
wmap as (
  select count(*) as visible
  from jsonb_path_query(public.get_world_map(), '$.sectors[*].zones[*].locations[*]') as loc
  where (loc->>'id') in ('b1a00001-0066-4a00-8a00-000000000001',
                         'b1a00002-0066-4a00-8a00-000000000002',
                         'b1a00003-0066-4a00-8a00-000000000003')
),
sendflag as (
  select count(*) as n,
         (select (value #>> '{}')::boolean from public.game_config where key = 'mainship_send_enabled') as as_bool
  from public.game_config where key = 'mainship_send_enabled'
),
-- OSN-SAFETY STRUCTURE (deployment-shape facts → STRUCTURAL_PASS): the invariants a future flag-enable relies on.
struct as (
  select
    (select count(*) from pg_constraint c join pg_class t on t.oid = c.conrelid
       join pg_namespace nn on nn.oid = t.relnamespace
      where nn.nspname = 'public' and t.relname = 'fleets' and c.contype = 'c'
        and pg_get_constraintdef(c.oid) ilike '%active_movement_id%'
        and pg_get_constraintdef(c.oid) ilike '%active_space_movement_id%')               as fleet_excl_check,
    (select count(*) from pg_indexes where schemaname = 'public'
       and indexname = 'main_ship_space_movements_one_active_per_ship')                    as idx_per_ship,
    (select count(*) from pg_indexes where schemaname = 'public'
       and indexname = 'main_ship_space_movements_one_active_per_fleet')                   as idx_per_fleet,
    (select count(*) from pg_constraint c join pg_class t on t.oid = c.conrelid
       join pg_namespace nn on nn.oid = t.relnamespace
      where nn.nspname = 'public' and t.relname = 'main_ship_space_command_receipts' and c.contype = 'u'
        and pg_get_constraintdef(c.oid) ilike '%request_id%')                             as receipt_unique,
    to_regprocedure('public.mainship_space_dock_at_location(uuid,uuid)')                  as dock_fn,
    to_regprocedure('public.command_main_ship_space_move_to_location(uuid,uuid)')         as move_to_loc_wrapper,
    to_regprocedure('public.get_osn_movement_readiness()')                               as readiness_fn
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
     ))                                                                           as chk6_iii_valid_origin_target_timing,
    -- [7] POST-REVEAL current state (runtime → OVERALL only): exactly the three canonical ports active/public
    ports.canon_n                                                                as chk7_canonical_ports_n,
    (ports.canon_n = 3)                                                          as chk7_canonical_ports_expected_3,
    ports.canon_active                                                          as chk7_canonical_ports_active_n,
    (ports.canon_active = 3)                                                     as chk7_canonical_ports_active_3,
    ports.canon_hidden                                                          as chk7_canonical_ports_hidden_n,
    (ports.canon_hidden = 0)                                                     as chk7_canonical_ports_none_hidden,
    wmap.visible                                                                as chk7_map_visible_n,
    (wmap.visible = 3)                                                           as chk7_map_ports_visible_3,
    -- [8] legacy named-location travel remains live (send flag true)
    (sendflag.n = 1 and sendflag.as_bool is true)                              as chk8_send_flag_true,
    -- [9] OSN-safety structure (deployment-shape → STRUCTURAL): exclusivity, idempotency, settlement, boundary
    (struct.fleet_excl_check >= 1)                                             as chk9_fleet_movement_exclusivity,
    (struct.idx_per_ship = 1)                                                   as chk9_one_active_move_per_ship,
    (struct.idx_per_fleet = 1)                                                  as chk9_one_active_move_per_fleet,
    (struct.receipt_unique >= 1)                                               as chk9_receipt_idempotency_unique,
    coalesce(struct.dock_fn is not null
             and not has_function_privilege('authenticated', struct.dock_fn::oid, 'EXECUTE')
             and has_function_privilege('service_role', struct.dock_fn::oid, 'EXECUTE'), false)
                                                                                as chk9_dock_fn_service_role_only,
    coalesce(struct.move_to_loc_wrapper is not null
             and has_function_privilege('authenticated', struct.move_to_loc_wrapper::oid, 'EXECUTE'), false)
                                                                                as chk9_move_to_loc_authenticated,
    coalesce(struct.readiness_fn is not null
             and has_function_privilege('authenticated', struct.readiness_fn::oid, 'EXECUTE'), false)
                                                                                as chk9_readiness_authenticated
  from flag, mig, rpc, surface, cronj, ports, wmap, sendflag, struct
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
      -- OSN-safety structure (deployment-shape): exclusivity, idempotency, settlement, boundary
      and c.chk9_fleet_movement_exclusivity
      and c.chk9_one_active_move_per_ship and c.chk9_one_active_move_per_fleet
      and c.chk9_receipt_idempotency_unique
      and c.chk9_dock_fn_service_role_only and c.chk9_move_to_loc_authenticated
      and c.chk9_readiness_authenticated
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
      -- POST-REVEAL current state (runtime): exactly three canonical ports active/public + legacy travel live
      and c.chk7_canonical_ports_expected_3 and c.chk7_canonical_ports_active_3
      and c.chk7_canonical_ports_none_hidden and c.chk7_map_ports_visible_3
      and c.chk8_send_flag_true
      -- OSN-safety structure (also gates OVERALL)
      and c.chk9_fleet_movement_exclusivity
      and c.chk9_one_active_move_per_ship and c.chk9_one_active_move_per_fleet
      and c.chk9_receipt_idempotency_unique
      and c.chk9_dock_fn_service_role_only and c.chk9_move_to_loc_authenticated
      and c.chk9_readiness_authenticated
    ) as overall_pass
  from checks c
)
select
  r.*,
  -- Named current-state sentinels (OSN-ENABLEMENT-1A). OSN_COORDINATE_TRAVEL_ENABLED is a frontend
  -- compile-time const (not in the DB); the calling workflow asserts it = false from the checked-out source.
  'MIGRATION_HEAD='                  || right(r.chk2_migration_head, 4)        as s_migration_head,
  'CANONICAL_STARTER_PORTS_EXPECTED=3'                                         as s_ports_expected,
  'CANONICAL_STARTER_PORTS_ACTIVE='  || r.chk7_canonical_ports_active_n::text  as s_ports_active,
  'CANONICAL_STARTER_PORTS_HIDDEN='  || r.chk7_canonical_ports_hidden_n::text  as s_ports_hidden,
  'AUTHENTICATED_MAP_PORTS_VISIBLE=' || r.chk7_map_visible_n::text             as s_map_visible,
  'MAINSHIP_SEND_ENABLED='           || (r.chk8_send_flag_true)::text          as s_send_flag,
  'MAINSHIP_SPACE_MOVEMENT_ENABLED=' || (not r.chk1_flag_is_false)::text       as s_space_flag,
  'STRUCTURAL_PASS=' || r.structural_pass::text as structural_status,
  'OVERALL_PASS='    || r.overall_pass::text    as overall_status
from result r;

commit;
