-- Byeharu — M4: anti-cheat lockdown of RPC surface (SYSTEM_BOUNDARIES: client has
-- ZERO authority). Postgres grants EXECUTE to PUBLIC by default and PostgREST
-- exposes the whole `public` schema, so without this every internal SECURITY
-- DEFINER function (base_reserve_units, fleet_set_*, process_*, …) is callable by
-- any authenticated client. We revoke that and grant EXECUTE only on the explicit
-- client-facing RPCs. Internal functions still run fine because they are called
-- from SECURITY DEFINER functions / cron as the owner role.

-- Remove the implicit PUBLIC execute (and any direct grant) on ALL public functions.
revoke execute on all functions in schema public from public;
revoke execute on all functions in schema public from anon, authenticated;

-- Future functions in this schema must not auto-grant execute to PUBLIC.
alter default privileges in schema public revoke execute on functions from public;

-- The ONLY client-callable RPCs:
grant execute on function public.get_world_map()                              to anon, authenticated;
grant execute on function public.bootstrap_me()                               to authenticated;
grant execute on function public.send_fleet_to_location(uuid, uuid, jsonb)    to authenticated;
grant execute on function public.request_leave_location(uuid)                 to authenticated;
grant execute on function public.request_retreat(uuid)                        to authenticated;
grant execute on function public.get_combat_reports()                         to authenticated;
