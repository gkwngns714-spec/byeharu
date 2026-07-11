-- Byeharu — TEAM-COMMAND Slice C0: DARK group expedition preview RPC (RPC-ONLY; ZERO data change).
--
-- First captain sub-slice of Slice C (docs/TEAM_COMMAND.md). ONE thing: a new DARK, read-only RPC
-- get_my_group_expedition_preview(group, activity) — the GROUP-shaped twin of
-- get_my_expedition_preview (0159), delegating every member's stats to the ONE stat adapter
-- calculate_expedition_stats (0122) and COLLECTING the results. It computes NOTHING.
--
-- ── NO DATA CHANGE — both captain-slot bumps DEFERRED to activation (dark discipline) ─────────────
--   This migration performs NO insert/update on ANY table — grep it: there is no write to
--   main_ship_hull_types or main_ship_instances, none anywhere. BOTH captain_slots bumps are
--   deferred:
--     (1) the HULL bump `main_ship_hull_types.base_captain_slots 2→6` (starter_frigate), AND
--     (2) the existing-instance `main_ship_instances.captain_slots` backfill.
--   WHY BOTH (grep-verified): the Ship screen's "Captain seats" stat row
--   (src/features/ship/ShipStatusCard.tsx) renders BOTH values UNGATED — `hull.base_captain_slots`
--   in the no-ship starter teaser (:95) and the ship's `captain_slots` (:213). So the hull bump is
--   NOT invisible either: a shipless player would see the teaser's "Captain seats" move 2→6, and
--   every ship commissioned after the bump (captain_slots is COPIED from the hull at commission —
--   0043/0080) would show 6. While captains are dark (captain_assignment_enabled='false') the slot
--   count is PURELY COSMETIC — no assignment can exist, so no stat can change — so nothing NEEDS
--   the bump now. Deferring both keeps C0 changing NOTHING a player can see; it only adds a gated,
--   unreachable-in-prod RPC. At activation, run both together (idempotent, monotonic) ALONGSIDE the
--   flag flips (see docs/TEAM_COMMAND.md "Explicitly deferred" for the exact SQL):
--     update public.main_ship_hull_types
--        set base_captain_slots = 6 where hull_type_id = 'starter_frigate' and base_captain_slots < 6;
--     update public.main_ship_instances i
--        set captain_slots = h.base_captain_slots, updated_at = now()
--       from public.main_ship_hull_types h
--      where i.hull_type_id = h.hull_type_id and i.captain_slots < h.base_captain_slots;
--
-- ── TERMINOLOGY: "group" (this file/DB/code) == "team" (UI). See docs/TEAM_COMMAND.md. ────────────
--
-- ── ANTI-SPAGHETTI (audited) ──────────────────────────────────────────────────────────────────────
--   Touches NO fleets / fleet_units / combat_units, NO movement path, NO combat engine, NO captain
--   table or captain writer, NO client selection source. `calculate_expedition_stats` is NOT
--   re-created — 0122 stays byte-identical; it remains THE one stat source (it already folds
--   captain skills + the headcount cap since 0122). This RPC does ZERO stat arithmetic: no
--   accumulator, no sum, no min/max — per-member delegation + collection ONLY. Group TOTALS are a
--   CLIENT display concern (src/features/command/teamSkillset.ts, display-only); AUTHORITATIVE
--   team stats arrive in Slice D beside the combat consumer, never here.
--
-- ── DARK / GATE ───────────────────────────────────────────────────────────────────────────────────
--   The RPC rejects-before-read on cfg_bool('team_command_enabled') (seeded FALSE in 0160) BEFORE
--   any group/ship read — the 0161/0163/0164 posture (identical answer regardless of input; no
--   existence oracle). No flag is flipped; no game_config row is written. In prod every call
--   returns team_command_disabled.
--
-- ── READ-ONLY, NO LOCKS (deliberate divergence from B-send/B-stop, documented) ───────────────────
--   B-send/B-stop lock the group FOR SHARE and (send) the member ships FOR UPDATE because they
--   WRITE through the live send/stop. This RPC writes NOTHING — its consistency guarantee is the
--   statement's MVCC snapshot, so it takes NO FOR SHARE / FOR UPDATE anywhere. A preview raced by
--   an assign/delete simply describes the pre- or post-mutation snapshot, both truthful.
--
-- Touches NO existing signature, NO frozen verifier, NO game_config, NO data. New-function-only ACL idiom.

-- ── get_my_group_expedition_preview: DARK, read-only group stats preview ──────────────────────────
-- Reject order (client mirror: src/features/command/teamSkillset.ts):
--   not_authenticated → team_command_disabled → invalid_activity → group_not_found → empty_group → ok
create or replace function public.get_my_group_expedition_preview(
  p_group_id uuid, p_activity_type text default 'none')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_player  uuid := auth.uid();
  v_group   uuid;
  v_members uuid[];
  v_ship    uuid;
  v_stats   jsonb;
  v_out     jsonb := '[]'::jsonb;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK gate FIRST — before any group/ship read (identical answer regardless of input; no
  -- existence oracle). The 0161/0163/0164 posture verbatim.
  if not public.cfg_bool('team_command_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'team_command_disabled');
  end if;

  -- Activity validation BEFORE any row read — EXACTLY the set calculate_expedition_stats (0122)
  -- accepts, envelope-rejected here so a bad activity never costs a member loop of caught raises.
  if coalesce(p_activity_type, '') not in ('pirate_hunt','trade_run','exploration','mining','none') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_activity');
  end if;

  -- Resolve the owned group (explicit-only; null/non-owned/nonexistent → null → fail closed).
  v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
  if v_group is null then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  -- Gather the team's ships (owner- AND group-scoped), deterministic order — the 0163 member
  -- query, UNLOCKED: read-only, so MVCC is the consistency guarantee (header note).
  select coalesce(array_agg(main_ship_id order by created_at), '{}')
    into v_members
    from public.main_ship_instances
   where group_id = v_group and player_id = v_player;
  if array_length(v_members, 1) is null then
    return jsonb_build_object('ok', false, 'reason', 'empty_group');
  end if;

  -- Per-member DELEGATION to the ONE stat adapter (empty loadout — support craft is deprecated on
  -- this path; captains/modules are read from the ship's own state by 0122). Each member runs
  -- inside its own exception scope (the 0159 preview idiom): a member's validation raise (e.g.
  -- over-capacity) becomes {valid:false, error}, never a team-wide 500. NO arithmetic here.
  foreach v_ship in array v_members loop
    begin
      v_stats := public.calculate_expedition_stats(v_player, v_ship, '[]'::jsonb, p_activity_type);
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'main_ship_id', v_ship, 'valid', true, 'stats', v_stats));
    exception when others then
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'main_ship_id', v_ship, 'valid', false, 'error', sqlerrm));
    end;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'group_id', v_group,
    'activity_type', p_activity_type,
    'member_count', array_length(v_members, 1),
    'members', v_out);
end;
$$;

-- ── ACL (0163/0164 new-function-only idiom): authenticated-only; the in-body gate rejects every
--    call while team_command_enabled is false. calculate_expedition_stats's OWN ACL is NOT touched
--    (stays service_role-only, 0122): this SECURITY DEFINER wrapper calls it as the function owner
--    — exactly the get_my_expedition_preview (0049/0159) posture.
revoke execute on function public.get_my_group_expedition_preview(uuid, text) from public, anon;
grant  execute on function public.get_my_group_expedition_preview(uuid, text) to authenticated;
