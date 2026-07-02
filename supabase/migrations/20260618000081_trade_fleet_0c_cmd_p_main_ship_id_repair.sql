-- Byeharu — TRADE-FLEET-0C §2.5: per-ship command conversion — shared resolver + FIRST site (repair).
--
-- Begins the "every §2.5 site, one coherent slice" conversion, staged across small BACKWARD-COMPATIBLE
-- commits. Each converted command gains a TRAILING `p_main_ship_id uuid default null`, so existing
-- zero-arg callers (the frontend, until TRADE-UI-1) keep working unchanged — no commit is broken.
--
-- ── DESIGN DECISION (planner authority — implements §2.5) ─────────────────────────────────────────
-- Ship resolution + ownership assertion + the sole-ship compat shim are centralized in ONE shared
-- helper (DRY), called by every command instead of copy-pasted:
--   • p_main_ship_id NON-NULL → assert it is OWNED (main_ship_id = p_main_ship_id AND player_id =
--     auth.uid()); UI selection is NEVER trusted.
--   • p_main_ship_id NULL (legacy/shim) → resolve the sole ship ONLY when the player has EXACTLY one;
--     zero or >1 (ambiguous) → unresolved (null) → the command fails closed. During the dark phase
--     every player has exactly one ship, so null resolves to it; once the add-ship flag flips, null
--     becomes ambiguous and the command forces explicit selection (the shim retires at TRADE-UI-1).
-- This commit creates the resolver and converts the FIRST site (repair_main_ship) as the pattern-
-- setter; the other six §2.5 sites follow in subsequent commits using the SAME helper.
--
-- No internal DB caller invokes any of the seven §2.5 functions (verified read-only); the frontend
-- calls them zero-arg, which the defaulted param satisfies. The PORT-ENTRY-1 production verifier stays
-- FROZEN at 0072 (md5 pins derive from the unchanged 0072 file); this migration touches NO verifier
-- file. Abstract columns, flags, and src/ are untouched. DARK: explicit selection is inert until
-- multi-ship exists (add-ship capability is server-rejected off).

-- ── A. Shared owned-ship resolver (internal helper; SECURITY DEFINER commands call it as the owner).
create or replace function public.mainship_resolve_owned_ship(p_player uuid, p_main_ship_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_ship uuid;
begin
  if p_player is null then
    return null;
  end if;

  if p_main_ship_id is not null then
    -- Explicit selection: assert ownership server-side; UI selection is never trusted. Null if not owned.
    select main_ship_id into v_ship from public.main_ship_instances
      where main_ship_id = p_main_ship_id and player_id = p_player;
    return v_ship;
  end if;

  -- Legacy / sole-ship shim: resolve ONLY when the player has EXACTLY one ship. Zero or >1 (ambiguous once
  -- the add-ship flag flips) → unresolved (null) → the caller fails closed, forcing explicit selection.
  if (select count(*) from public.main_ship_instances where player_id = p_player) <> 1 then
    return null;
  end if;
  select main_ship_id into v_ship from public.main_ship_instances where player_id = p_player;
  return v_ship;
end;
$$;

-- Internal helper: no client grant. The definer/owner calls it inside SECURITY DEFINER commands (the call
-- runs as the function owner, who always has EXECUTE), so revoking from all client roles is sufficient.
revoke execute on function public.mainship_resolve_owned_ship(uuid, uuid) from public, anon, authenticated;

-- ── B. repair_main_ship — FIRST §2.5 conversion (drop + recreate with the defaulted trailing param).
--    The ONLY body delta vs the 0052 original is the ship-resolution swap: the single-ship derivation
--    `where player_id = v_player` becomes `where main_ship_id = mainship_resolve_owned_ship(...)`. A null
--    resolution selects no row → the existing no-ship fail-closed raise fires (convention preserved).
drop function if exists public.repair_main_ship();
create function public.repair_main_ship(p_main_ship_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_ship   main_ship_instances%rowtype;
begin
  if v_player is null then
    raise exception 'repair_main_ship: not authenticated';
  end if;

  -- §2.5: resolve the caller's SELECTED owned ship (explicit p_main_ship_id, ownership asserted server-side)
  -- or, legacy/shim, the sole ship when the player has exactly one. UI selection is never trusted. A null
  -- resolution (unowned / zero / ambiguous >1) selects no row → the existing no-ship fail-closed raise fires.
  select * into v_ship from main_ship_instances
    where main_ship_id = public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship.main_ship_id is null then
    raise exception 'repair_main_ship: no main ship found';
  end if;
  if v_ship.status <> 'destroyed' then
    raise exception 'repair_main_ship: ship is not disabled (status %) — nothing to repair', v_ship.status;
  end if;
  if v_ship.max_hp is null or v_ship.max_hp <= 0 then
    raise exception 'repair_main_ship: invalid max_hp (%)', v_ship.max_hp;
  end if;

  -- Restore to full readiness, back home. No fleets/fleet_units/movements/presences created.
  update main_ship_instances
    set hp = v_ship.max_hp, status = 'home', updated_at = now()
    where main_ship_id = v_ship.main_ship_id;

  return jsonb_build_object(
    'main_ship_id', v_ship.main_ship_id, 'status', 'home',
    'hp', v_ship.max_hp, 'max_hp', v_ship.max_hp);
end;
$$;

-- The drop removed the old ACL — restore it on the NEW signature (authenticated; NOT flag-gated: recovery
-- must always be possible — the safelock guarantee, carried from 0052).
revoke execute on function public.repair_main_ship(uuid) from public, anon;
grant  execute on function public.repair_main_ship(uuid) to authenticated;
