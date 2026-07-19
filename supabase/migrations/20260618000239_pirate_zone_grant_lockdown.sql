-- Byeharu — PIRATE-ZONE GRANT LOCKDOWN (reproducible privilege containment; no behavior change).
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE EXPOSURE: migration 0233 (20260618000233_pirate_intercept_danger_zones.sql) minted the zone
-- authoring RPCs pirate_zone_create(text,jsonb,uuid) and pirate_zone_delete(uuid) and — by its own
-- header's admission — granted EXECUTE on BOTH to `authenticated` as a "PROTOTYPE: no admin-role
-- gate" (0233:1473, 0233:1509). That let ANY authenticated caller draw or delete pirate danger-zone
-- geometry whenever pirate_intercept_enabled is lit. That grant has since been REVOKED from
-- authenticated MANUALLY on production. But migrations are the source of truth for a rebuild: a fresh
-- `supabase start` / a from-scratch chain replay would re-run 0233 and SILENTLY RE-GRANT execute to
-- authenticated, reopening the hole. This migration codifies the manual prod revoke into the chain so
-- the contained state is REPRODUCIBLE and can never regress on a rebuild.
--
-- INTENDED PRIVILEGE STATE (what this migration pins): ONLY the owner (postgres) and service_role may
-- EXECUTE pirate_zone_create / pirate_zone_delete. The dark dev ZoneEditor (the /dev/zones authoring
-- surface, 0238) is owner-only tooling that drives these through service_role/owner credentials, NOT
-- the player-facing `authenticated` anon-JWT role. Player-facing gameplay NEVER calls these two RPCs
-- (movement/combat compose the internal pirate_intercept_evaluate_leg leaf, never the authoring RPCs).
-- So removing the authenticated grant costs the game nothing and closes the prototype hole.
--
-- WHY A NEW MIGRATION (not an edit to 0233): applied migrations are IMMUTABLE — 0233 already ran on
-- prod and on every disposable DB, so its text is frozen. Corrective privilege state is expressed as a
-- forward migration, the house idiom. 0233's own deploy-time self-assert (0233:1552) asserts
-- authenticated HAS execute at 0233's point in the chain; that remains true when 0233 runs — THIS
-- migration runs strictly AFTER it and tightens the state, so the chain stays green end to end.
--
-- IDEMPOTENT: `revoke` is a no-op when the privilege is already absent (the manual prod revoke means
-- prod is already in the target state; this simply makes the migration chain agree). Belt-and-braces
-- we also revoke from anon (0233 never granted anon, so this is defensive — pins the state either way).
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. dependency gate — the two RPCs must exist to be locked down (never silently no-op) ─────────
do $lockdep$
begin
  if to_regprocedure('public.pirate_zone_create(text, jsonb, uuid)') is null then
    raise exception 'PIRATE-ZONE LOCKDOWN: public.pirate_zone_create(text,jsonb,uuid) is missing — 0233 must have landed first';
  end if;
  if to_regprocedure('public.pirate_zone_delete(uuid)') is null then
    raise exception 'PIRATE-ZONE LOCKDOWN: public.pirate_zone_delete(uuid) is missing — 0233 must have landed first';
  end if;
end $lockdep$;

-- ── 1. revoke the prototype client grant — reproducibly (idempotent; owner+service_role untouched) ─
-- service_role's grant is NEVER touched here, so owner tooling / the dark dev ZoneEditor keep working.
revoke execute on function public.pirate_zone_create(text, jsonb, uuid) from authenticated;
revoke execute on function public.pirate_zone_create(text, jsonb, uuid) from anon;
revoke execute on function public.pirate_zone_delete(uuid) from authenticated;
revoke execute on function public.pirate_zone_delete(uuid) from anon;

comment on function public.pirate_zone_create(text, jsonb, uuid) is
  'PIRATE INTERCEPT: the draw-editor''s save RPC. p_vertices is an ordered [[x,y],...] ring (3-64 '
  'points); optionally attaches to an active pirate_hunt/pirate_den location for live combat, or '
  'stands alone (location_id NULL). LOCKED DOWN (0239): execute is owner/service_role ONLY — the '
  '0233 PROTOTYPE grant to authenticated is revoked. The dark dev ZoneEditor drives this via '
  'service_role/owner tooling; player-facing gameplay never calls it.';

comment on function public.pirate_zone_delete(uuid) is
  'PIRATE INTERCEPT: deletes a caller-drawn zone (source=''drawn''). LOCKED DOWN (0239): execute is '
  'owner/service_role ONLY — the 0233 PROTOTYPE grant to authenticated is revoked. Owner tooling '
  '(service_role) only; player-facing gameplay never calls it.';

-- ── 2. self-assert (deploy-time; a raise aborts the migration txn — nothing half-applies) ─────────
-- The disposable-DB apply-proof (`supabase start`) runs this against real Postgres: if a future
-- migration or a rebuild ever re-opens execute to authenticated/anon, this RAISES and the chain
-- goes RED loudly instead of silently reopening the hole. Mirrors the 0233 has_function_privilege
-- self-assert idiom (0233:1544-1554).
do $lockassert$
begin
  -- (a) the containment: neither client role may execute EITHER authoring RPC.
  if has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute') then
    raise exception 'PIRATE-ZONE LOCKDOWN self-assert FAIL: authenticated still has EXECUTE on pirate_zone_create — the 0233 prototype hole is open';
  end if;
  if has_function_privilege('anon', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute') then
    raise exception 'PIRATE-ZONE LOCKDOWN self-assert FAIL: anon has EXECUTE on pirate_zone_create';
  end if;
  if has_function_privilege('authenticated', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'PIRATE-ZONE LOCKDOWN self-assert FAIL: authenticated still has EXECUTE on pirate_zone_delete — the 0233 prototype hole is open';
  end if;
  if has_function_privilege('anon', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'PIRATE-ZONE LOCKDOWN self-assert FAIL: anon has EXECUTE on pirate_zone_delete';
  end if;

  -- (b) service_role KEEPS execute — the owner tooling / dark dev ZoneEditor path must survive.
  if not has_function_privilege('service_role', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute') then
    raise exception 'PIRATE-ZONE LOCKDOWN self-assert FAIL: service_role LOST execute on pirate_zone_create — owner tooling is broken';
  end if;
  if not has_function_privilege('service_role', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'PIRATE-ZONE LOCKDOWN self-assert FAIL: service_role LOST execute on pirate_zone_delete — owner tooling is broken';
  end if;

  raise notice 'PIRATE-ZONE LOCKDOWN self-assert ok: pirate_zone_create/delete EXECUTE revoked from authenticated+anon, retained for service_role — 0233 prototype grant reproducibly contained';
end $lockassert$;
