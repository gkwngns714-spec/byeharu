-- Byeharu — TEAM-COMMAND Slice B1: DARK group DELETE RPC (the deleter B0 omitted).
--
-- B0 (0161) added create/rename (upsert_ship_group) + assign/unassign (assign_ship_to_group). B1 adds the
-- owner-scoped, DARK delete: remove a team slot. Its member ships are un-grouped by the ON DELETE SET NULL FK
-- on main_ship_instances.group_id (0160 §B) — NOT by any manual member update here.
--
-- ── TERMINOLOGY: "group" (this file/DB/code) == "team" (UI). See docs/TEAM_COMMAND.md. ────────────────────
--
-- ── ANTI-SPAGHETTI: touches ONLY ship_groups (+ the FK-driven SET NULL on main_ship_instances.group_id). NO
--    fleets/fleet_units/combat_units, NO movement, NO combat, NO ship deletion. NO new selection source. ─────
--
-- ── DARK/GATE: reject-before-read on cfg_bool('team_command_enabled') (seeded FALSE in 0160). NO flag flipped,
--    NO game_config written. In prod every call returns team_command_disabled. ─────────────────────────────
--
-- ── CONCURRENCY: locks the group row FOR UPDATE, then revalidates FOUND under the lock (the B0 assign idiom,
--    FOR SHARE→FOR UPDATE). This serializes against B0's assign (FOR SHARE conflicts with FOR UPDATE) and a
--    concurrent double-delete: the loser re-reads zero rows post-commit and fails closed as group_not_found —
--    never a 0-row silent success, never a raw 500. Both the assign and delete paths acquire the GROUP row
--    lock FIRST (before assign's child UPDATE / the delete's FK SET-NULL), a common first acquisition → they
--    serialize there with no cross-ordered cycle → no deadlock. Un-grouping members is the FK's job (0160 §B):
--    NO manual UPDATE main_ship_instances here (it would be a redundant second write + wider lock footprint).
--
-- Touches NO existing signature, NO frozen verifier, NO game_config. New function only.

create or replace function public.delete_ship_group(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_group  uuid;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK gate FIRST — before any ship_groups read (identical answer regardless of input; no existence oracle).
  if not public.cfg_bool('team_command_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'team_command_disabled');
  end if;

  -- Resolve the owned group (explicit-only; null id or non-owned/nonexistent → null → fail closed). Same
  -- resolver B0 assign uses, so a non-owned id is indistinguishable from a nonexistent one (no ownership oracle).
  v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
  if v_group is null then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  -- Lock the group row FOR UPDATE, THEN revalidate it still exists under the lock. The resolve above is
  -- unlocked, so a concurrent delete could commit in the resolve→lock window; if it did, we lock zero rows
  -- (FOUND=false) and fail closed here. FOR UPDATE conflicts with assign's FOR SHARE → the two serialize.
  perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  -- Delete the group. main_ship_instances.group_id ON DELETE SET NULL (0160) un-groups every member ship
  -- automatically; no manual member update. player_id predicate is defense-in-depth (v_group already owned).
  delete from public.ship_groups where group_id = v_group and player_id = v_player;

  return jsonb_build_object('ok', true, 'group_id', v_group);
end;
$$;

-- ── ACLs (0161 §D idiom). authenticated-only; the in-body gate rejects every call while team_command_enabled
--    is false. Explicit revokes are defense-in-depth (0043 default-revokes EXECUTE from PUBLIC on new funcs).
revoke execute on function public.delete_ship_group(uuid) from public, anon;
grant  execute on function public.delete_ship_group(uuid) to authenticated;
