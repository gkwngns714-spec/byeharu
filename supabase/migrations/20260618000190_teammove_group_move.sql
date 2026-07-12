-- Byeharu — TEAMMOVE-1: a DOCKED team moves onward as one (the other half of the owner directive).
--
-- OWNER DIRECTIVE: "the team should also be able to be docked or move as a whole." The dock half already
-- works (team send → members arrive docked at the port, 0153) and is visible (TEAMMAP rollup + badges,
-- 0187). This migration closes gap G-B: BOTH existing team sends (send_ship_group_expedition 0163,
-- send_ship_group_hunt 0168) require every member status='home', but a docked member is 'stationary' —
-- so a docked team was team-STRANDED: it could arrive together but never leave together.
--
-- ── TERMINOLOGY: "group" (this file/DB/code) == "team" (UI). See docs/TEAM_COMMAND.md. ────────────────
--
-- ── HEAD PROVENANCE (grep-verified over ALL migrations) ───────────────────────────────────────────────
-- The ONE per-ship send-to-location path is move_main_ship_to_location: created 0053:14, re-created
-- 0152:222 (in-flight spatial pair), re-created 0156:62 (depart from PRESENT or HELD) — nothing later
-- re-creates it, so 0156 is the TRUE head. By 0156's own convergence decision it is THE one
-- send-to-location path ("converge on ONE send-to-location path, do NOT add a parallel resume RPC").
-- Its PRESENT branch is exactly a docked member's departure state (0153 dock settle leaves the fleet
-- 'present' with an active presence; the ship in the canonical stationary/at_location pair), and its
-- success envelope carries 'fleet_id' (0156:195-198) — which this wrapper's tag hunk reads. That RPC is
-- REUSED VERBATIM here: NOT widened, NOT re-created; the wrapper below is new code only.
--
-- ── ANTI-SPAGHETTI (the 0163 audit, re-run) ───────────────────────────────────────────────────────────
--   #1 combat: untouched (the move is the non-combat 'rally' path; the per-ship RPC hard-rejects combat
--      destinations at 0156:154-156). #2 movement: REUSE ONLY — this RPC writes NO fleet_movements row
--      and no fleets movement-state directly; every departure write is delegated to the unchanged live
--      per-ship move. The ONE direct fleets write is the 0187 informational group_id tag (display-only
--      law restated below). #3 group-shaped: move_ship_group_to_location(p_group_id, …); the ship-shaped
--      live move is NOT widened. #4 one selection source: backend-only (the client supplies only ids).
--
-- ── GATE / LIVE POSTURE (deliberate, stated per the slice law) ────────────────────────────────────────
-- This RPC rides the LIVE team_command_enabled gate (the 0163 gate block, copied exactly): team command
-- is LIT in production, so this function is live on a flip-free deploy — there is no dark posture to
-- hide behind and it must be RIGHT by construction. The movement-legality burden is NOT re-implemented
-- here: the per-ship RPC's own gates (mainship_send_enabled, ownership, departable state, destination
-- active + non-combat) protect every actual departure; this wrapper adds only the TEAM-shaped
-- preconditions (whole team docked together) and the all-or-nothing envelope around the composition.
-- Reject-before-read: the gate answers before any group/ship read (no existence oracle) — and the
-- DESTINATION is deliberately never read here at all: its legality is the per-ship RPC's own law, whose
-- rejects surface through the subtransaction as member_send_failed (the 0163 posture).
--
-- ── CONCURRENCY / ATOMICITY (the 0163/0168 shape) ─────────────────────────────────────────────────────
-- Group FOR SHARE + revalidate (serializes vs delete_ship_group's FOR UPDATE) → member ships FOR UPDATE
-- (ships AFTER group — the exact 0163 lock order; matches assign/delete → no deadlock cycle). Readiness
-- (EVERY member docked at the SAME location) is checked UNDER the ship locks — the 0168:219-224 shape,
-- docked flavor. The 0164 movement-lock lesson does NOT bite here: unlike Stop, the per-ship move takes
-- NO fleet_movements lock (it only INSERTS a new movement row), so the up-front ship locks create no
-- ship→movement order that could invert the settle cron's movement→ship order — and the cron cannot be
-- concurrently settling these members anyway (a 'present' member has no 'moving' movement row). The
-- whole per-member loop runs in ONE subtransaction (the 0163:89-99 shape): any member's move raising
-- rolls back EVERY prior member's departure → a docked team is never half-moved.
--
-- HONEST LOCK-ORDER INVERSION (documented, accepted): inside THIS wrapper the row-lock order is
-- SHIP → FLEET (the up-front member-ship FOR UPDATE, then the delegated per-ship move's guarded fleets
-- UPDATE), while a STANDALONE move_main_ship_to_location on the same member takes FLEET → SHIP (its
-- fleets 'moving' UPDATE, 0156:179-188, precedes its mainship_mark_legacy_in_flight ship write,
-- 0156:192). So the owner racing a direct per-ship move against this group move on an overlapping
-- member CAN deadlock; Postgres detects it (40P01) and aborts one side, and BOTH sides fail CLOSED:
-- the group side's abort is caught by the subtransaction handler → member_send_failed with every prior
-- departure rolled back (never a half-moved team); the standalone side surfaces an ordinary client
-- error. That is availability noise on a self-race — never corruption, never a stuck lock. ACCEPTED
-- AS-IS (decision documented per the slice law): closing it would take an advisory lock or a
-- fleets-first pre-lock pass — a NEW idiom no 0163-family group RPC uses (0163/0168 carry the same
-- shaped ship-locks-then-fleets-write exposure against the live single send), the window needs the
-- SAME authenticated player driving both surfaces in the same instant, and the deterministic detector
-- already resolves it fail-closed on both sides.
--
-- ── THE DISPLAY-ONLY TAG LAW (restated from 0168/0187) ────────────────────────────────────────────────
-- fleets.group_id is an INFORMATIONAL team tag (display only; ROUTING NEVER reads it). After the loop
-- succeeds, the departed member fleets — read straight from the envelopes the loop collected (each
-- per-ship response carries 'fleet_id'; here these are the members' OWN docked fleets re-departed, not
-- new rows) — are tagged with the team's group id, exactly the 0187 hunk's idiom. A docked team's
-- fleets normally already carry the tag (0187 tags at team-send and TEAMMAP proved it survives the dock
-- settle), so this re-tag is usually idempotent; it exists so a team assembled at a port by OTHER
-- routes (per-ship sends) still departs labeled. ON DELETE SET NULL semantics unchanged.
--
-- Touches NO existing signature (no create-or-replace of any live function), NO frozen verifier, NO
-- game_config, NO flag created/read-differently/flipped. New function only; new-function-only grant
-- idiom (no schema-wide EXECUTE re-lock).

create or replace function public.move_ship_group_to_location(p_group_id uuid, p_location_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player     uuid := auth.uid();
  v_group      uuid;
  v_members    uuid[];
  v_fleets     uuid[];
  v_fleet      uuid;
  v_locked     integer;
  v_not_docked integer;
  v_loc_count  integer;
  v_null_locs  integer;
  v_res        jsonb;
  v_sent       jsonb := '[]'::jsonb;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- Gate FIRST — before any group/ship read (identical answer regardless of input; no existence
  -- oracle). The 0163 gate block exactly; LIVE in production (see header).
  if not public.cfg_bool('team_command_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'team_command_disabled');
  end if;

  -- Resolve the owned group (explicit-only; null/non-owned/nonexistent → null → fail closed).
  v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
  if v_group is null then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  -- Lock the group row FOR SHARE, then revalidate under the lock (serializes vs delete's FOR UPDATE;
  -- if a delete won the resolve→lock window we lock zero rows and fail closed). The 0163 idiom.
  perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for share;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  -- Gather the team's ships (owner- AND group-scoped), deterministic order — the 0163/0168 member query.
  select coalesce(array_agg(main_ship_id order by created_at), '{}')
    into v_members
    from public.main_ship_instances
   where group_id = v_group and player_id = v_player;
  if array_length(v_members, 1) is null then
    return jsonb_build_object('ok', false, 'reason', 'empty_group');
  end if;

  -- Lock the member ship rows FOR UPDATE (ships AFTER group — the exact 0163 lock order; NO movement
  -- row is ever locked here, see header) so a concurrent team op on overlapping members serializes.
  -- The locked count must equal the gathered count (a member row vanished in the gather→lock window
  -- → fail closed) — the 0168:204-211 idiom.
  select count(*) into v_locked from (
    select main_ship_id from public.main_ship_instances
     where main_ship_id = any(v_members) and player_id = v_player
     for update
  ) locked;
  if v_locked <> array_length(v_members, 1) then
    return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
  end if;

  -- Readiness UNDER the locks (all-or-nothing, the 0163 posture; the 0168:219-224 reject shape, docked
  -- flavor): EVERY member must sit in the canonical docked pair (0153: status='stationary' AND
  -- spatial_state='at_location') — a 'home', in-flight, held-in-space, or hunting member means the
  -- team is not docked together and the whole move rejects.
  select count(*) into v_not_docked
    from public.main_ship_instances
    where main_ship_id = any(v_members)
      and (status <> 'stationary' or spatial_state is distinct from 'at_location');
  if v_not_docked > 0 then
    return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
  end if;

  -- …and every member must resolve to EXACTLY ONE owned 'present' fleet, all pinned to the SAME
  -- location (fleet_set_present wrote current_location_id at the dock settle, 0153 — the same
  -- docked-location truth the TEAMMAP rollup displays). A member with zero or multiple 'present'
  -- fleets, a NULL location, or a team split across ports all land here → member_not_ready.
  -- The fleet array is member-ordered (msi.created_at — the same deterministic order as v_members).
  select coalesce(array_agg(f.id order by msi.created_at), '{}'),
         count(distinct f.current_location_id),
         count(*) filter (where f.current_location_id is null)
    into v_fleets, v_loc_count, v_null_locs
    from public.main_ship_instances msi
    join public.fleets f
      on f.main_ship_id = msi.main_ship_id and f.player_id = v_player and f.status = 'present'
   where msi.main_ship_id = any(v_members);
  if coalesce(array_length(v_fleets, 1), 0) <> array_length(v_members, 1)
     or v_loc_count <> 1 or v_null_locs > 0 then
    return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
  end if;

  -- ALL-OR-NOTHING: one subtransaction around the WHOLE loop (the 0163:89-99 shape). Reuse the LIVE
  -- per-ship move unchanged, once per member fleet. Any member raise (destination inactive/combat,
  -- already at that location, presence lost, feature disabled, …) rolls back every prior member's
  -- departure → the team either moves whole or stays docked whole.
  begin
    foreach v_fleet in array v_fleets loop
      select public.move_main_ship_to_location(v_fleet, p_location_id) into v_res;
      v_sent := v_sent || jsonb_build_array(v_res);
    end loop;
  exception
    when others then
      return jsonb_build_object('ok', false, 'reason', 'member_send_failed', 'detail', sqlerrm);
  end;

  -- TEAMMOVE-1 tag (the 0187 hunk idiom): the member loop succeeded — tag the departed member fleets
  -- with the team's group id, read straight from the envelopes the loop collected (each per-ship
  -- response carries 'fleet_id'; these are the fleets the members now own — re-departed, not
  -- re-created). INFORMATIONAL / display only (the 0168 law verbatim): ROUTING NEVER reads
  -- fleets.group_id — this update changes no movement, settle, or combat behavior; it exists so the
  -- map can label the moving team. Owner-scoped defense-in-depth. Runs INSIDE the same function
  -- transaction but AFTER the subtransaction: a failure here raises and rolls back the whole move,
  -- never a half-tagged team.
  update public.fleets
     set group_id = v_group
   where player_id = v_player
     and id in (select (e->>'fleet_id')::uuid from jsonb_array_elements(v_sent) e);

  return jsonb_build_object('ok', true, 'group_id', v_group, 'sent', v_sent);
end;
$$;

-- ── ACL (0163 idiom): authenticated-only wrapper posture, matching the other group RPCs. The in-body
--    gate is the team_command_enabled check above (LIVE — see header); the per-ship RPC's own gates
--    protect every actual departure. Explicit revokes are defense-in-depth (0043 default-revokes
--    EXECUTE from PUBLIC on new functions).
revoke execute on function public.move_ship_group_to_location(uuid, uuid) from public, anon;
grant  execute on function public.move_ship_group_to_location(uuid, uuid) to authenticated;
