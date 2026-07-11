-- Byeharu — TEAM-COMMAND Slice B (sub-slice 2): DARK group-STOP RPC (stop a whole team mid-transit).
--
-- Twin of B-send (0163), but for STOP. Reuses the live, fleet-addressed `command_main_ship_stop_transit`
-- (STOP=HOLD, 0155; gated mainship_send_enabled=true) VERBATIM — this RPC resolves a team into its members'
-- in-flight fleets and calls the unmodified live stop once per fleet. No second movement engine; writes NO
-- fleets/movement row directly.
--
-- ── TERMINOLOGY: "group" (this file/DB/code) == "team" (UI). See docs/TEAM_COMMAND.md. ────────────────────
--
-- ── BEST-EFFORT, not all-or-nothing (the deliberate difference from B-send) ──────────────────────────────
--   Send COMMITS resources (fleets, active-fleet budget) → must be atomic. Stop RELEASES/HALTS → it is
--   idempotent + monotonic: a member already held/docked/home is a legitimate terminal, not a failure.
--   "Stop the team" = halt every haltable member (moving/returning → held in open space), SKIP the rest, and
--   report the breakdown {stopped, skipped, failed}. Aborting the whole team because one member already
--   docked would make Stop fail precisely in the common mixed-state case. So NO whole-team rollback: each
--   member runs in its own subtransaction (which also isolates the one defensive `raise` in 0155).
--
-- ── ANTI-SPAGHETTI ──────────────────────────────────────────────────────────────────────────────────────
--   Group-shaped. No second movement engine (all stop logic delegated to the live function). No new selection
--   source. No live-function edit. The client never supplies a fleet id — B-stop derives fleets from OWNED
--   members only. The OSN sole-ship selects are NOT on this path (legacy stop is fleet-addressed), so the
--   deferred OSN A0-fix is NOT a prerequisite here.
--
-- ── DARK/GATE ───────────────────────────────────────────────────────────────────────────────────────────
--   Reject-before-read on cfg_bool('team_command_enabled') (seeded FALSE in 0160) BEFORE any group/ship read.
--   The inner live stop has its OWN gate (mainship_send_enabled); this outer gate keeps a dark team-stop from
--   ever driving it. No flag flipped, no game_config write.
--
-- ── CONCURRENCY ─────────────────────────────────────────────────────────────────────────────────────────
--   Group FOR SHARE + revalidate serializes vs delete's FOR UPDATE. B-stop takes NO up-front member-ship lock
--   (unlike send/assign/delete): the arrival settle (0153) locks the moving fleet_movements row and THEN docks
--   the ship (movement→ship), so an up-front ship lock would invert that order and deadlock the arrival cron
--   (its batch has no per-row savepoint → a lost cron rolls back OTHER players' settlements). Instead B-stop's
--   only movement contention is through the inner stop's own `fleet_movements FOR UPDATE` (order movement→ship,
--   matching the settle → no cycle); that same inner lock + its status='moving' re-check serializes
--   team-stop vs team-stop (the loser re-reads → already_settled/held → skipped). See the loop body.
--
-- Touches NO existing signature, NO frozen verifier, NO game_config, NO cap. New function only.

create or replace function public.stop_ship_group_transit(p_group_id uuid)
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
  v_fleet   uuid;
  v_res     jsonb;
  v_results jsonb := '[]'::jsonb;
  v_stopped int := 0;
  v_skipped int := 0;
  v_failed  int := 0;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK gate FIRST — before any group/ship read (identical answer regardless of input; no existence oracle).
  if not public.cfg_bool('team_command_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'team_command_disabled');
  end if;

  v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
  if v_group is null then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  -- Group FOR SHARE + revalidate under the lock (serialize vs delete_ship_group's FOR UPDATE).
  perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for share;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  select coalesce(array_agg(main_ship_id order by created_at), '{}')
    into v_members
    from public.main_ship_instances
   where group_id = v_group and player_id = v_player;
  if array_length(v_members, 1) is null then
    return jsonb_build_object('ok', false, 'reason', 'empty_group');
  end if;

  -- DELIBERATELY NO up-front member-ship FOR UPDATE here (unlike send/assign/delete). The arrival settle
  -- (movement_settle_arrival, 0153) locks the moving fleet_movements row FOR UPDATE and THEN docks the ship
  -- (updates main_ship_instances) — order movement→ship. If B-stop locked ships first and then (via the inner
  -- stop) the movement row, that ship→movement order would INVERT the settle's and deadlock the arrival cron
  -- (whose batch has no per-row subtransaction → a lost-victim cron rolls back OTHER players' settlements).
  -- So B-stop takes NO ship lock: its only movement contention is through the inner stop's own
  -- `fleet_movements FOR UPDATE`, giving order movement→ship, matching the settle → no cycle. Team-op-vs-team-op
  -- safety still holds (a second stopper blocks on that movement lock, re-reads status<>'moving', returns
  -- already_settled/already_held → skipped); serialize-vs-delete is provided by the group FOR SHARE above.

  -- BEST-EFFORT loop: each member independently; NO whole-team rollback. Delegate ALL stop logic to the
  -- UNMODIFIED live command_main_ship_stop_transit(fleet).
  foreach v_ship in array v_members loop
    -- The member's in-flight legacy fleet (moving or returning, with an active movement). A member with none
    -- (home / docked / OSN-parked) is a legitimate skip. limit 1: a ship can hold at most one active fleet
    -- (send requires status='home' first).
    select id into v_fleet
      from public.fleets
     where main_ship_id = v_ship and player_id = v_player
       and status in ('moving', 'returning') and active_movement_id is not null
     order by created_at desc
     limit 1;

    if v_fleet is null then
      v_skipped := v_skipped + 1;
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'main_ship_id', v_ship, 'outcome', 'skipped', 'reason', 'no_active_fleet'));
      continue;
    end if;

    -- Per-member subtransaction isolates the one defensive `raise` in 0155 (and any surprise) so a single
    -- member's failure never aborts the team.
    begin
      v_res := public.command_main_ship_stop_transit(v_fleet);
      if coalesce((v_res->>'stopped')::boolean, false) then
        v_stopped := v_stopped + 1;
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'main_ship_id', v_ship, 'fleet_id', v_fleet, 'outcome', 'stopped', 'detail', v_res));
      elsif coalesce((v_res->>'ok')::boolean, false) then
        -- idempotent no-op: already_held / already_settled / arrived
        v_skipped := v_skipped + 1;
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'main_ship_id', v_ship, 'fleet_id', v_fleet, 'outcome', 'skipped', 'reason', v_res->>'reason'));
      else
        v_failed := v_failed + 1;
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'main_ship_id', v_ship, 'fleet_id', v_fleet, 'outcome', 'failed',
          'reason', coalesce(v_res->>'code', 'stop_failed')));
      end if;
    exception
      when others then
        v_failed := v_failed + 1;
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'main_ship_id', v_ship, 'fleet_id', v_fleet, 'outcome', 'failed', 'reason', 'stop_failed',
          'detail', sqlerrm));
    end;
  end loop;

  return jsonb_build_object('ok', true, 'group_id', v_group, 'results', v_results,
                            'stopped', v_stopped, 'skipped', v_skipped, 'failed', v_failed);
end;
$$;

-- ── ACL (0161/0162/0163 idiom): authenticated-only; the in-body gate rejects every call while
--    team_command_enabled is false. Explicit revokes are defense-in-depth. New-function-only.
revoke execute on function public.stop_ship_group_transit(uuid) from public, anon;
grant  execute on function public.stop_ship_group_transit(uuid) to authenticated;
