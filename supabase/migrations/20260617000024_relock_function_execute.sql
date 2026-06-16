-- Byeharu — re-lock RPC surface after M4 added new functions.
--
-- Migration 0021 revoked execute on then-existing functions, but Supabase grants
-- EXECUTE to anon/authenticated on NEW public functions by default, so functions
-- created later (e.g. fleet_sync_quantities in 0023) became client-callable again.
-- This re-locks everything and revokes the anon/authenticated default too.
-- (Convention going forward: any migration that adds functions ends with this block.)

revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

-- The ONLY client-callable RPCs:
grant execute on function public.get_world_map()                           to anon, authenticated;
grant execute on function public.bootstrap_me()                            to authenticated;
grant execute on function public.send_fleet_to_location(uuid, uuid, jsonb) to authenticated;
grant execute on function public.request_leave_location(uuid)              to authenticated;
grant execute on function public.request_retreat(uuid)                     to authenticated;
grant execute on function public.get_combat_reports()                      to authenticated;
