-- Byeharu — make fleet_sync_quantities internal-only via SECURITY INVOKER.
--
-- Supabase re-grants EXECUTE to anon/authenticated on newly-created public
-- functions, and that grant resists REVOKE by the migration role — so a function
-- added after the lockdown (fleet_sync_quantities, from 0023) stayed client-callable.
-- Defense that does NOT depend on the grant: SECURITY INVOKER. A direct client call
-- then runs as 'authenticated', which has only SELECT (no UPDATE) on fleet_units, so
-- the write is denied. The sole internal caller is process_combat_ticks() — a
-- SECURITY DEFINER function owned by postgres — so its nested call runs as the owner
-- and succeeds.

create or replace function public.fleet_sync_quantities(p_fleet uuid, p_counts jsonb)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare r record;
begin
  for r in select key, value from jsonb_each(p_counts) loop
    update fleet_units set quantity = greatest(0, (r.value #>> '{}')::integer), updated_at = now()
      where fleet_id = p_fleet and unit_type_id = r.key;
  end loop;
end;
$$;
