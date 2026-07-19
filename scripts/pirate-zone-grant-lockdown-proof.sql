-- PIRATE-ZONE GRANT LOCKDOWN — disposable apply-proof (run against a THROWAWAY local Supabase only).
--
-- Proves migration 0239 (20260618000239_pirate_zone_grant_lockdown.sql) reproducibly contains the
-- 0233 PROTOTYPE grant: after the FULL migration chain is applied by `supabase start`, the zone
-- authoring RPCs pirate_zone_create/pirate_zone_delete are NOT executable by the player-facing
-- authenticated/anon roles, and REMAIN executable by service_role (owner tooling).
--
-- Read-only: this proof performs NO writes — it inspects catalog privileges only, so there is
-- nothing to roll back and no committed flag is touched. NEVER point this at production.

\set ON_ERROR_STOP on

do $$
begin
  -- ── containment: the client-facing roles must NOT be able to execute the authoring RPCs ──────────
  if has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute') then
    raise exception 'ZONE-LOCKDOWN PROOF FAIL: authenticated can execute pirate_zone_create';
  end if;
  if has_function_privilege('anon', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute') then
    raise exception 'ZONE-LOCKDOWN PROOF FAIL: anon can execute pirate_zone_create';
  end if;
  if has_function_privilege('authenticated', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'ZONE-LOCKDOWN PROOF FAIL: authenticated can execute pirate_zone_delete';
  end if;
  if has_function_privilege('anon', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'ZONE-LOCKDOWN PROOF FAIL: anon can execute pirate_zone_delete';
  end if;
  raise notice 'ZONE_LOCKDOWN_PASS_CLIENT_REVOKED';

  -- ── owner tooling survives: service_role MUST keep execute on both RPCs ──────────────────────────
  if not has_function_privilege('service_role', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute') then
    raise exception 'ZONE-LOCKDOWN PROOF FAIL: service_role lost execute on pirate_zone_create';
  end if;
  if not has_function_privilege('service_role', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'ZONE-LOCKDOWN PROOF FAIL: service_role lost execute on pirate_zone_delete';
  end if;
  raise notice 'ZONE_LOCKDOWN_PASS_SERVICE_ROLE_RETAINED';

  raise notice 'PIRATE-ZONE GRANT LOCKDOWN PROOF PASSED';
end $$;
