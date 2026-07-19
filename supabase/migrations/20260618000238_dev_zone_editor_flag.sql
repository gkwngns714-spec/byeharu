-- Byeharu — DEV ZONE EDITOR gate flag (owner-only authoring surface; DARK by default).
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE FEATURE: the OWNER wants to DRAW danger-zone polygons by hand (define pirate territory
-- geometry) instead of me auto-generating them. That authoring surface is a dev-only client route
-- (src/features/dev/ZoneEditor.tsx, mounted at /dev/zones). It composes the ALREADY-DEPLOYED pirate-
-- intercept slice verbatim — pirate_zone_create / pirate_zone_delete / get_danger_zones (0233) over
-- get_world_map — and forks NOTHING. This migration adds ONLY the one client-read gate flag that
-- decides whether that route renders anything at all.
--
-- ONE FLAG: dev_zone_editor_enabled (seeded false below). It governs a CLIENT SURFACE ONLY — no
-- server function reads it (the editor's save/list/delete RPCs already gate on pirate_intercept_
-- enabled at their own boundary, 0233). So this migration is PURE additive config data: zero new
-- table, zero new function, zero behavior change to anything. While false the /dev/zones route is a
-- hard null and a normal player never sees it (it is never linked from the shell nav either).
--
-- HOW THE OWNER USES IT: flip dev_zone_editor_enabled → true to REACH the editor; the editor's own
-- saves additionally require pirate_intercept_enabled → true (the 0233 slice gate) to persist, and
-- the editor surfaces that reason honestly when it is still dark.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

insert into public.game_config (key, value, description)
values
  (
    'dev_zone_editor_enabled',
    'false'::jsonb,
    'DEV ZONE EDITOR (owner-only authoring): lights the hidden /dev/zones client route where the '
    'owner draws danger-zone polygons and saves them via pirate_zone_create (0233). Governs the '
    'CLIENT SURFACE ONLY — no server function reads it; the editor''s save/delete still gate on '
    'pirate_intercept_enabled at their own boundary. DARK by default: while false the route renders '
    'nothing and is unlinked, so a normal player never reaches it.'
  )
on conflict (key) do nothing;

-- ── self-assert (deploy-time; a raise aborts the migration txn — nothing half-applies) ────────────
do $devzoneassert$
declare
  v_val jsonb;
begin
  -- (a) the gate flag is seeded and carries a jsonb boolean value (mirrors the 0233 "row exists"
  --     idiom — asserts presence + shape, not the literal value, so a re-apply over a later flip
  --     stays green).
  select value into v_val from public.game_config where key = 'dev_zone_editor_enabled';
  if v_val is null then
    raise exception 'DEV-ZONE-EDITOR self-assert FAIL: dev_zone_editor_enabled seed is missing';
  end if;
  if jsonb_typeof(v_val) <> 'boolean' then
    raise exception 'DEV-ZONE-EDITOR self-assert FAIL: dev_zone_editor_enabled is not a jsonb boolean (got %)', jsonb_typeof(v_val);
  end if;

  -- (b) the editor composes the 0233 slice + the world map — assert every RPC it calls still exists
  --     with its client-callable execute grant, so this flag can never light a route onto a missing
  --     surface (the editor forks nothing; if these ever move, THIS assert catches the break).
  if to_regprocedure('public.pirate_zone_create(text,jsonb,uuid)') is null
     or to_regprocedure('public.pirate_zone_delete(uuid)') is null
     or to_regprocedure('public.get_danger_zones()') is null
     or to_regprocedure('public.get_world_map()') is null then
    raise exception 'DEV-ZONE-EDITOR self-assert FAIL: a dependency RPC the editor composes is missing';
  end if;
  if not has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.pirate_zone_delete(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.get_danger_zones()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_world_map()', 'execute') then
    raise exception 'DEV-ZONE-EDITOR self-assert FAIL: a dependency RPC lost its authenticated execute grant';
  end if;
end;
$devzoneassert$;
