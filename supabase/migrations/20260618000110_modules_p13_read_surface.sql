-- Byeharu — MODULES-P13 SLICE D: the dark read surface — get_my_module_instances().
-- Read-only; no write anywhere; dark-gated like every module-crafting surface.
-- Mirrors the exploration/mining read surfaces 0101/0106 exactly.
--
-- (1) ONE gated RPC for the PLAYER-STATE data only. get_my_module_instances() returns the caller's
--     OWN module_instances rows joined to their module_types catalog identity, newest first — the
--     0101/0106 shape (jsonb envelope · stable · security definer · auth check → dark gate BEFORE
--     any row read · jsonb_agg ordered desc · {ok:true, <plural>:[…]}).
-- (2) NO CATALOG RPC — the precedent points the OTHER way and is followed: 0101/0106 exist because
--     exploration_sites/mining_fields are HIDDEN (RLS with no client policy — reveal only through
--     the player's own rows). The module catalog/recipe tables are the opposite posture by design
--     (0107): public-read Reference/Config catalogs exactly like item_types (0039:23–25) /
--     support_craft_types (0042:32–36) / trade_goods, which the client reads by DIRECT table
--     select (the shipped convention — e.g. the hull-type selects in src/features/map/
--     mainshipApi.ts). Adding a get-catalog RPC would duplicate an already-public surface.
-- (3) NO balance-join surface: no shipped read surface joins inventory balances into another
--     system's read (inventory_get_balance is an internal leaf, service_role-only — 0039:156).
--     The surface stays dumb; the client reads its own player_inventory through the existing
--     Inventory read path (the 0039:50–52 own-row select policy + grant). No new cross-system
--     read edge without precedent.
--
-- Note (mirroring the 0106 header nuance): while module_instances also carries an own-row select
-- policy (0108), the CLIENT CONVENTION for player activity/progression state is this ONE gated
-- RPC — while module_crafting_enabled='false' it rejects identically regardless of caller state,
-- so nothing about a player's instances can be probed while dark.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): read-only function — NO new
-- writer, NO new table, so the §1 matrix is unchanged (the 0101/0106 precedent: read surfaces are
-- recorded in the §2 system row, not the matrix). The §2 Modules row gains this function. No flag
-- flipped; 0001–0109 unedited.

create or replace function public.get_my_module_instances()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_player    uuid := auth.uid();
  v_instances jsonb;
  c_empty     constant jsonb := '[]'::jsonb;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK server-reject FIRST (0107 law; 0087/0101/0106 read idiom): before any instance read, and
  -- the identical envelope regardless of the caller's instances — no probing while dark.
  if not public.cfg_bool('module_crafting_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'module_crafting_disabled');
  end if;

  -- read-only: ONLY the caller's own instances, joined to their public catalog identity.
  -- Writes nothing.
  select coalesce(jsonb_agg(jsonb_build_object(
           'instance_id',    i.id,
           'module_type_id', i.module_type_id,
           'name',           t.name,
           'slot_type',      t.slot_type,
           'created_at',     i.created_at) order by i.created_at desc),
         c_empty)
    into v_instances
    from public.module_instances i
    join public.module_types t on t.id = i.module_type_id
    where i.player_id = v_player;

  return jsonb_build_object('ok', true, 'instances', coalesce(v_instances, c_empty));
end;
$$;

-- ACL (0087/0101/0106 idiom): revoke the default PUBLIC grant, then authenticated only. Dark
-- today: the gate above rejects every call while module_crafting_enabled = 'false'.
revoke execute on function public.get_my_module_instances() from public, anon;
grant  execute on function public.get_my_module_instances() to authenticated;
