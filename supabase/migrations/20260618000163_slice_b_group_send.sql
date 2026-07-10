-- Byeharu — TEAM-COMMAND Slice B (sub-slice 1): DARK group-send RPC (send a whole team on one expedition).
--
-- First movement-touching team slice. It makes a team DO something (rally-send its ships to a location) WITHOUT
-- widening or editing any live function. `send_main_ship_expedition` (the live, mainship_send_enabled=true
-- single-ship send) is REUSED VERBATIM — this RPC resolves a team into repeated per-member calls of it inside
-- ONE all-or-nothing subtransaction. No second movement engine; the fleets spine is written ONLY through the
-- unchanged live send.
--
-- ── TERMINOLOGY: "group" (this file/DB/code) == "team" (UI). See docs/TEAM_COMMAND.md. ────────────────────
--
-- ── ANTI-SPAGHETTI ──────────────────────────────────────────────────────────────────────────────────────
--   #1 combat: untouched (send is non-combat 'rally'). #2 movement: REUSE ONLY — this RPC writes NO fleets /
--   fleet_movements / main_ship_space_movements row directly; every movement write is delegated to the live
--   send. #3 group-shaped: send_ship_group_expedition(p_group_id, …); the ship-shaped live send is NOT widened.
--   #4 one selection: backend-only, no client selection source added.
--
-- ── DARK/GATE ───────────────────────────────────────────────────────────────────────────────────────────
--   Reject-before-read on cfg_bool('team_command_enabled') (seeded FALSE in 0160) BEFORE any group/ship read.
--   NB the live send is gated on a DIFFERENT flag (mainship_send_enabled=true); keeping this gate at the top,
--   reject-before-read, is the sole safeguard that a dark team-send can never drive a live send. No flag
--   flipped, no game_config write. In prod every call returns team_command_disabled.
--
-- ── CONCURRENCY / ATOMICITY ─────────────────────────────────────────────────────────────────────────────
--   Locks the GROUP row FOR SHARE + revalidates (0161 assign idiom) → serializes vs delete_ship_group's
--   FOR UPDATE (0162). Then locks the MEMBER ship rows FOR UPDATE → serializes concurrent team-sends of
--   overlapping members (closes the double-send window; the live single-ship send takes no ship lock). Lock
--   order is GROUP-first then SHIPS, matching assign/delete → no deadlock cycle. The whole per-member loop runs
--   in ONE subtransaction (begin/exception): any member's send raising rolls back EVERY prior member's send →
--   a team is never half-sent.
--
-- Touches NO existing signature (no create-or-replace of any live function), NO frozen verifier, NO
-- game_config, NO shared cap (max_active_fleets stays as-is — it is LIVE and shared with old fleets). New
-- function only; new-function-only grant idiom (no schema-wide EXECUTE re-lock).

create or replace function public.send_ship_group_expedition(p_group_id uuid, p_location uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player  uuid := auth.uid();
  v_group   uuid;
  v_members uuid[];
  v_ship    uuid;
  v_res     jsonb;
  v_sent    jsonb := '[]'::jsonb;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK gate FIRST — before any group/ship read (identical answer regardless of input; no existence oracle).
  if not public.cfg_bool('team_command_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'team_command_disabled');
  end if;

  -- Resolve the owned group (explicit-only; null/non-owned/nonexistent → null → fail closed).
  v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
  if v_group is null then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  -- Lock the group row FOR SHARE, then revalidate under the lock (serializes vs delete's FOR UPDATE; if a
  -- delete won the resolve→lock window we lock zero rows and fail closed).
  perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for share;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  -- Gather the team's ships (owner- AND group-scoped), deterministic order.
  select coalesce(array_agg(main_ship_id order by created_at), '{}')
    into v_members
    from public.main_ship_instances
   where group_id = v_group and player_id = v_player;
  if array_length(v_members, 1) is null then
    return jsonb_build_object('ok', false, 'reason', 'empty_group');
  end if;

  -- Lock the member ship rows FOR UPDATE (ships AFTER group → same lock order as assign/delete, no deadlock)
  -- so a concurrent TEAM-send of overlapping members blocks, then re-reads them as already 'traveling' and its
  -- inner send raises → that whole send rolls back. NB this serializes team-send vs team-send ONLY: FOR UPDATE
  -- blocks lockers/writers, not MVCC readers, and the live single-ship send reads the ship with a plain
  -- unlocked SELECT — so a DIRECT single-ship send racing a team-send is unaffected here (closed only by the
  -- live status='home' re-check; a pre-existing single-ship TOCTOU, not newly introduced by this wrapper).
  perform 1 from public.main_ship_instances
    where main_ship_id = any(v_members) and player_id = v_player for update;

  -- ALL-OR-NOTHING: one subtransaction around the WHOLE loop. Reuse the LIVE send unchanged, once per member.
  -- Any member raise (not home, active-fleet cap, bad destination, …) rolls back every prior member's send.
  begin
    foreach v_ship in array v_members loop
      select public.send_main_ship_expedition(jsonb_build_array(v_ship), p_location) into v_res;
      v_sent := v_sent || jsonb_build_array(v_res);
    end loop;
  exception
    when others then
      return jsonb_build_object('ok', false, 'reason', 'member_send_failed', 'detail', sqlerrm);
  end;

  return jsonb_build_object('ok', true, 'group_id', v_group, 'sent', v_sent);
end;
$$;

-- ── ACL (0161/0162 idiom): authenticated-only; the in-body gate rejects every call while team_command_enabled
--    is false. Explicit revokes are defense-in-depth (0043 default-revokes EXECUTE from PUBLIC on new funcs).
revoke execute on function public.send_ship_group_expedition(uuid, uuid) from public, anon;
grant  execute on function public.send_ship_group_expedition(uuid, uuid) to authenticated;
