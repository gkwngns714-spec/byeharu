-- Byeharu — FLEET-CONTROL: the owner's fleet control-model, DARK behind `fleet_control_enabled`. Migration 0204.
--
-- ── THE OWNER'S DESIGN (build exactly this; every behavior change gated on the new flag) ───────────────
-- 1. CAPS: max 3 fleets (already — ship_groups (player, group_index 1..3) unique, 0160), up to 8 ships per
--    fleet, minimum 1. This adds the 8-ship-per-fleet cap to the assign path (reject the 9th member).
-- 2. A fleet needs ≥1 COMMAND SHIP to be active. A per-ship command-ship designation
--    (main_ship_instances.is_command_ship, additive boolean default false) is meaningful ONLY relative to
--    the ship's fleet (group_id). "At least one" → a fleet can have MULTIPLE command ships (extras are
--    backups). A fleet with ZERO command ships is INACTIVE: it cannot move/send/hunt. A new RPC
--    set_fleet_command_ship(p_main_ship_id, p_is_command) toggles it — a ship must be IN a fleet to be
--    designated (reject if group_id null; clearing is always allowed).
-- 3. Everything moves as a FLEET. When the flag is LIT the three LIVE group RPCs
--    (send_ship_group_expedition, move_ship_group_to_location, send_ship_group_hunt) REJECT a fleet with no
--    command ship (reason `fleet_inactive_no_command`) — a 1-ship fleet is valid (that ship can be its own
--    command ship). The client hides the per-ship Move affordance when lit and routes movement through
--    fleets; a ship not in a fleet shows guidance.
--
-- ── TERMINOLOGY: "group" (this file/DB/code) == "fleet" (UI, post FLEET-RENAME). See docs/TEAM_COMMAND.md.
--
-- ── DESIGN DECISION (documented per the slice law) ─────────────────────────────────────────────────────
-- The DESIGNATION is ADDITIVE DATA and is ALWAYS settable (set_fleet_command_ship is NOT flag-gated) — it is
-- INERT while dark because NOTHING reads is_command_ship except the flag-gated hunks in the three group
-- RPCs, and the client control that surfaces it is gated by strictConfigFlag('fleet_control_enabled'). The
-- flag `fleet_control_enabled` gates ONLY (a) the command-ship-required MOVEMENT check and (b) the 8-ship
-- assign cap. Setting a command ship still requires the ship be in a fleet (a command ship is meaningless
-- otherwise) and requires ownership. So a dark game: column ignored by every RPC, no client surface → the
-- LIVE team-command game is byte-unchanged until the owner flips fleet_control_enabled.
--
-- ── PARITY DISCIPLINE (ABSOLUTE — team command is LIVE on prod) ────────────────────────────────────────
-- assign_ship_to_group / send_ship_group_expedition / move_ship_group_to_location / send_ship_group_hunt
-- are LIVE hot functions. Each is re-created from its grep-verified TRUE head with the ONE gate flag read
-- once at the top and the FLEET-CONTROL behavior confined to a marked `if v_fleet_control then … end if`
-- hunk. With the flag DARK (its committed seed) v_fleet_control is false → every hunk is skipped → the body
-- is byte-identical to its head (extract-and-diff). CREATE OR REPLACE preserves owner + the head grants;
-- the revokes/grants below are re-asserted defense-in-depth. No random(); reject-before-read.
--
-- ── GROUNDING (grep-verified TRUE heads) ───────────────────────────────────────────────────────────────
--   assign_ship_to_group            — 20260618000161 (only def) [8-cap hunk added]
--   send_ship_group_expedition      — 20260618000187 (TEAMMAP-1; the 0163 body + the group-tag hunk)
--   move_ship_group_to_location     — 20260618000190 (TEAMMOVE-1; only def)
--   send_ship_group_hunt            — 20260618000199 (NO-HOME widened it to 3-arg; the TRUE head — NOT 0168)
--   mainship_resolve_owned_group    — 20260618000161 (reused)
--   mainship_resolve_owned_ship     — 20260618000081 (reused)
--   cfg_bool                        — 20260618000046 (reused)

-- ── §1) NEW flag fleet_control_enabled (game_config bool, seeded FALSE) ─────────────────────────────────
-- Mirrors the team_command_enabled / launch_from_dock_enabled seed idiom (0160/0199): on conflict do
-- nothing so a re-apply never un-flips a live activation. OFF on live — dark until a human runs
-- scripts/activate-fleet-control.sql.
insert into public.game_config (key, value, description) values
  ('fleet_control_enabled', 'false',
   'FLEET-CONTROL (0204): server gate for the fleet control-model. When true, the three group movement '
   'RPCs (send_ship_group_expedition / move_ship_group_to_location / send_ship_group_hunt) REJECT a fleet '
   'with zero command ships (fleet_inactive_no_command) and assign_ship_to_group enforces the 8-ship '
   'per-fleet cap (fleet_full). The is_command_ship designation is settable regardless of this flag but '
   'inert until it is lit. OFF on live — dark until a human flips it.')
on conflict (key) do nothing;

-- ── §2) main_ship_instances.is_command_ship — the per-ship command-ship designation (additive) ─────────
-- NOT NULL DEFAULT false: every existing row reads false → no fleet is "active" under the new model until a
-- human both flips the flag AND designates a command ship. Meaningful ONLY relative to the ship's fleet
-- (group_id); an ungrouped ship's flag is inert (the group RPCs scope the command-ship read to group_id =
-- the resolved fleet, so a group_id-null ship can never count for any fleet).
alter table public.main_ship_instances
  add column if not exists is_command_ship boolean not null default false;
comment on column public.main_ship_instances.is_command_ship is
  'FLEET-CONTROL (0204): true ⇒ this ship is a COMMAND SHIP of its fleet (group_id). A fleet with ≥1 '
  'command ship is ACTIVE (can move/send/hunt) when fleet_control_enabled is lit; zero command ships ⇒ '
  'INACTIVE. Multiple command ships allowed (backups). Sole writer: set_fleet_command_ship. Inert while '
  'group_id is null or the flag is dark.';

-- Partial index: the ONLY reader is the "does this fleet have a command ship?" exists-probe in the three
-- group RPCs (keyed by group_id, filtered is_command_ship) — a partial index on the designated rows keeps
-- that probe cheap and stays tiny (only command ships are indexed).
create index if not exists idx_msi_command_ship
  on public.main_ship_instances (group_id) where is_command_ship;

-- ── §3) set_fleet_command_ship — toggle a ship's command-ship designation (owner-scoped, NOT flag-gated) ─
-- The SOLE writer of is_command_ship. Owner-scoped via the established resolver (0081). Setting to TRUE
-- requires the ship be IN a fleet (group_id not null) — a command ship is meaningless otherwise; clearing
-- (false) is always allowed. Deliberately NOT gated on fleet_control_enabled: the designation is additive
-- data, inert until the flag lights the movement requirement (see header DESIGN DECISION). The group_id is
-- read under a row lock so a concurrent unassign can't leave the write racing the membership.
create or replace function public.set_fleet_command_ship(p_main_ship_id uuid, p_is_command boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player  uuid := auth.uid();
  v_ship    uuid;
  v_group   uuid;
  v_command boolean := coalesce(p_is_command, false);
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- Resolve the owned ship via the ESTABLISHED contract (0081): explicit id → ownership asserted; null →
  -- sole ship only; anything ambiguous → null → fail closed. UI selection is never trusted.
  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then
    return jsonb_build_object('ok', false, 'reason', 'ship_not_found');
  end if;

  -- Read the ship's current fleet UNDER a row lock (owner-scoped), then enforce the "must be in a fleet to
  -- be a command ship" rule. The lock serializes this write vs a concurrent assign/unassign of the same
  -- ship, so we never stamp a command flag on a ship that a racing unassign just ungrouped.
  select group_id into v_group from public.main_ship_instances
    where main_ship_id = v_ship and player_id = v_player for update;
  if v_command and v_group is null then
    return jsonb_build_object('ok', false, 'reason', 'ship_not_in_fleet');
  end if;

  update public.main_ship_instances
     set is_command_ship = v_command, updated_at = now()
   where main_ship_id = v_ship and player_id = v_player;

  return jsonb_build_object('ok', true, 'main_ship_id', v_ship, 'group_id', v_group, 'is_command_ship', v_command);
end;
$$;
-- ACL (0161 idiom): authenticated-only. Explicit revokes are defense-in-depth (0043 default-revokes EXECUTE
-- from PUBLIC on new functions).
revoke execute on function public.set_fleet_command_ship(uuid, boolean) from public, anon;
grant  execute on function public.set_fleet_command_ship(uuid, boolean) to authenticated;

-- ── §4) assign_ship_to_group — 0161 head + the marked FLEET-CONTROL 8-ship cap hunk + the per-fleet
--        command-role reset ──────────────────────────────────────────────────────────────────────────
-- The 8-cap hunk is flag-gated (dark = byte-identical to 0161: assigning to a fleet that already holds 8
-- OTHER members rejects `fleet_full`; min 1 is inherent; UNASSIGN and re-assign of the SAME ship are never
-- capped — the cap counts members other than the ship being written). PLUS the ONE marked always-on write
-- delta (NOT flag-gated, per the review): when a ship's group_id CHANGES (moved to a different fleet, or
-- unassigned), its is_command_ship is CLEARED to false. RATIONALE: the command role is PER-FLEET and EXPLICIT
-- — "to activate a fleet one must ASSIGN a command ship". Without the reset, moving a command ship into
-- fleet B would silently activate B with no explicit designation. Harmless while dark (is_command_ship is
-- ignored by every RPC and dark clients render no command surface), so extract-and-diff shows exactly the
-- flag hunk + this reset over the 0161 head. A no-op move (re-assign to the SAME fleet) keeps the role.
create or replace function public.assign_ship_to_group(p_main_ship_id uuid, p_group_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_ship   uuid;
  v_group  uuid;
  -- FLEET-CONTROL (0204): the gate, read ONCE. Dark seed → false → the cap hunk below is skipped and the
  -- 0161 head runs verbatim.
  v_fleet_control boolean := public.cfg_bool('fleet_control_enabled');
  v_members       integer;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK gate FIRST — before any ship/group read (identical answer regardless of input; no existence oracle).
  if not public.cfg_bool('team_command_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'team_command_disabled');
  end if;

  -- Resolve the ship via the ESTABLISHED contract (0081): explicit id → ownership asserted; null → sole ship
  -- only (dark-phase shim); anything ambiguous → null → fail closed. UI selection is never trusted.
  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then
    return jsonb_build_object('ok', false, 'reason', 'ship_not_found');
  end if;

  -- Resolve the target group ONLY when one was requested. p_group_id null = UNASSIGN (always allowed for an
  -- owned ship). A non-null id not owned/nonexistent → fail closed. This resolve is what asserts SAME-PLAYER.
  if p_group_id is not null then
    v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
    if v_group is null then
      return jsonb_build_object('ok', false, 'reason', 'group_not_found');
    end if;
    -- FOR SHARE the resolved group, THEN revalidate it still exists under the lock. This serializes against a
    -- FUTURE group-delete (none in B0): the resolver read above is unlocked, so a concurrent delete could
    -- commit in the resolve→lock window; if it did, `perform` locks zero rows (FOUND=false) and we fail closed
    -- here instead of letting the update FK-violate into a raw 500. (Slice B's delete RPC must lock the group
    -- row FOR UPDATE and lean on ON DELETE SET NULL for members.)
    perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for share;
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'group_not_found');
    end if;
    -- FLEET-CONTROL (0204): the ONE marked cap hunk. DARK — skipped (v_fleet_control false) → 0161 behavior.
    -- LIT — a fleet holds at most 8 ships; count the members ALREADY in the target fleet OTHER than the ship
    -- being written (so re-assigning a ship already in the fleet is never blocked). ≥8 → fleet_full. HONEST
    -- LIMIT: this is a SOFT gameplay cap, not a hard invariant — the group's lock above is FOR SHARE (shared),
    -- so two DIFFERENT ships assigned to the same 7-member fleet in the same instant could BOTH read 7 and
    -- both insert, landing 9. ACCEPTED (decision, not oversight): it needs the same authenticated player
    -- double-assigning concurrently, over-filling only their OWN fleet, with no downstream break (the movement
    -- RPCs don't cap), and it is dark until the flip. A hard cap would need FOR UPDATE on the group or an
    -- advisory lock — not worth the contention on a live RPC for a cosmetic ceiling.
    if v_fleet_control then
      select count(*) into v_members
        from public.main_ship_instances
       where group_id = v_group and player_id = v_player and main_ship_id <> v_ship;
      if v_members >= 8 then
        return jsonb_build_object('ok', false, 'reason', 'fleet_full');
      end if;
    end if;
  end if;

  -- Single-row write. v_ship and v_group were both asserted against v_player=auth.uid() → the pair is
  -- same-player by construction; the player_id predicate is defense-in-depth.
  -- FLEET-CONTROL (0204): the per-fleet command-role reset — when the fleet CHANGES (RHS group_id is the
  -- OLD value in a SET clause; `is distinct from` covers null↔fleet either way), clear is_command_ship so
  -- the role must be re-designated in the new fleet. A same-fleet re-assign keeps it. Always-on: inert while
  -- dark (the column is ignored), so this is the only write delta beyond the flag-gated cap hunk.
  update public.main_ship_instances
     set group_id = v_group,
         is_command_ship = case when group_id is distinct from v_group then false else is_command_ship end,
         updated_at = now()
   where main_ship_id = v_ship and player_id = v_player;

  return jsonb_build_object('ok', true, 'main_ship_id', v_ship, 'group_id', v_group);
end;
$$;
revoke execute on function public.assign_ship_to_group(uuid, uuid) from public, anon;
grant  execute on function public.assign_ship_to_group(uuid, uuid) to authenticated;

-- ── §5) send_ship_group_expedition — 0187 head VERBATIM + the marked FLEET-CONTROL command-ship gate ────
-- DARK path (v_fleet_control false) is byte-identical to the 0187 body (the 0163 body + the TEAMMAP-1
-- group-tag hunk). LIT path: a fleet with zero command ships is INACTIVE → reject fleet_inactive_no_command
-- BEFORE the member lock/loop (reject-before-read on the caller's own fleet).
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
  -- FLEET-CONTROL (0204): the gate, read ONCE. Dark seed → false → the command-ship hunk is skipped and the
  -- 0187 body runs verbatim.
  v_fleet_control boolean := public.cfg_bool('fleet_control_enabled');
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

  -- FLEET-CONTROL (0204): the ONE marked command-ship hunk. DARK — skipped (v_fleet_control false) → 0187
  -- behavior. LIT — a fleet with zero command ships is INACTIVE and cannot move: reject before locking the
  -- members (the fleet's own property, checked before touching movement).
  if v_fleet_control then
    if not exists (
      select 1 from public.main_ship_instances
       where group_id = v_group and player_id = v_player and is_command_ship
    ) then
      return jsonb_build_object('ok', false, 'reason', 'fleet_inactive_no_command');
    end if;
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

  -- TEAMMAP-1 (the 0187 marked hunk; everything else is the 0163 body verbatim): the member loop
  -- succeeded — tag the just-created member fleets with the team's group id, read straight from the
  -- envelope the loop collected (each live-send response carries 'fleet_id'). INFORMATIONAL / display
  -- only (the 0168 law verbatim): ROUTING NEVER reads fleets.group_id — this update changes no
  -- movement, settle, or combat behavior; it exists so the map can label the team's fleets. Owner-
  -- scoped defense-in-depth (the loop only ever created fleets for v_player). Runs INSIDE the same
  -- function transaction but AFTER the subtransaction: an (unreachable — the group row is held FOR
  -- SHARE) failure here raises and rolls back the whole send, never a half-tagged team.
  update public.fleets
     set group_id = v_group
   where player_id = v_player
     and id in (select (e->>'fleet_id')::uuid from jsonb_array_elements(v_sent) e);
  -- TEAMMAP-1 hunk end.

  return jsonb_build_object('ok', true, 'group_id', v_group, 'sent', v_sent);
end;
$$;
revoke execute on function public.send_ship_group_expedition(uuid, uuid) from public, anon;
grant  execute on function public.send_ship_group_expedition(uuid, uuid) to authenticated;

-- ── §6) move_ship_group_to_location — 0190 head VERBATIM + the marked FLEET-CONTROL command-ship gate ───
-- DARK path (v_fleet_control false) is byte-identical to 0190:79-202. LIT path: a fleet with zero command
-- ships is INACTIVE → reject fleet_inactive_no_command BEFORE the member lock/readiness reads.
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
  -- FLEET-CONTROL (0204): the gate, read ONCE. Dark seed → false → the command-ship hunk is skipped and the
  -- 0190 body runs verbatim.
  v_fleet_control boolean := public.cfg_bool('fleet_control_enabled');
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

  -- FLEET-CONTROL (0204): the ONE marked command-ship hunk. DARK — skipped (v_fleet_control false) → 0190
  -- behavior. LIT — a fleet with zero command ships is INACTIVE and cannot move: reject before the member
  -- locks/readiness reads (the fleet's own property, checked before touching movement).
  if v_fleet_control then
    if not exists (
      select 1 from public.main_ship_instances
       where group_id = v_group and player_id = v_player and is_command_ship
    ) then
      return jsonb_build_object('ok', false, 'reason', 'fleet_inactive_no_command');
    end if;
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
revoke execute on function public.move_ship_group_to_location(uuid, uuid) from public, anon;
grant  execute on function public.move_ship_group_to_location(uuid, uuid) to authenticated;

-- ── §7) send_ship_group_hunt — 0199 head (3-arg) VERBATIM + the marked FLEET-CONTROL command-ship gate ──
-- The TRUE head is 20260618000199 (NO-HOME widened it to 3-arg: p_return_location_id DEFAULT NULL). This
-- CREATE OR REPLACE keeps the SAME 3-arg signature, so no DROP is needed and the head grants survive. DARK
-- path (v_fleet_control false) is byte-identical to the 0199 body (both the launch-from-dock LIT branch and
-- the 0168 DARK head). FLEET-CONTROL LIT: a fleet with zero command ships is INACTIVE → reject
-- fleet_inactive_no_command BEFORE the destination read (reject-before-read on the caller's own fleet).
create or replace function public.send_ship_group_hunt(p_group_id uuid, p_location uuid, p_return_location_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_group    uuid;
  v_members  uuid[];
  v_locked   integer;
  v_not_home integer;
  v_loc      record;
  v_max      integer;
  v_active   integer;
  v_base     record;
  v_ship     uuid;
  v_stats    jsonb;
  v_ms       double precision;
  v_power    double precision;
  v_speed    double precision;
  v_fleet    uuid;
  v_movement uuid;
  v_arrive   timestamptz;
  -- NOHOME (0199): the gate + docked-launch working set. Dark seed → false → the 0168 head runs verbatim.
  v_launch_from_dock boolean := public.cfg_bool('launch_from_dock_enabled');
  v_docked   integer;   -- members currently docked (status='stationary'/spatial_state='at_location')
  v_dockcount integer;  -- distinct docked ports across the members (must be exactly 1)
  v_dock_loc uuid;      -- the ONE common docked port (all members) — the launch origin
  v_cur      record;    -- docked-port coordinates + zone/sector
  v_return   uuid;      -- chosen (or origin) return port recorded on the team fleet
  -- FLEET-CONTROL (0204): the gate, read ONCE. Dark seed → false → the command-ship hunk is skipped and the
  -- 0199 body runs verbatim.
  v_fleet_control boolean := public.cfg_bool('fleet_control_enabled');
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  if not public.cfg_bool('team_command_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'team_command_disabled');
  end if;

  v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
  if v_group is null then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

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

  -- FLEET-CONTROL (0204): the ONE marked command-ship hunk. DARK — skipped (v_fleet_control false) → 0199
  -- behavior. LIT — a fleet with zero command ships is INACTIVE and cannot hunt: reject before the
  -- destination/readiness reads (the fleet's own property).
  if v_fleet_control then
    if not exists (
      select 1 from public.main_ship_instances
       where group_id = v_group and player_id = v_player and is_command_ship
    ) then
      return jsonb_build_object('ok', false, 'reason', 'fleet_inactive_no_command');
    end if;
  end if;

  select l.id, l.x, l.y, l.activity_type, l.status, l.zone_id, l.min_power_required, z.sector_id
    into v_loc
    from locations l join zones z on z.id = l.zone_id
    where l.id = p_location;
  if v_loc.id is null or v_loc.status <> 'active' or v_loc.activity_type is distinct from 'hunt_pirates' then
    return jsonb_build_object('ok', false, 'reason', 'invalid_location');
  end if;

  select count(*) into v_locked from (
    select main_ship_id from public.main_ship_instances
     where main_ship_id = any(v_members) and player_id = v_player
     for update
  ) locked;
  if v_locked <> array_length(v_members, 1) then
    return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
  end if;

  -- Readiness UNDER the locks. NOHOME (0199): the ONE marked readiness hunk. DARK — the 0168 check
  -- verbatim (EVERY member status='home' AND hp>0). LIT — a member is ready if home OR DOCKED
  -- (the settled-safe pair) AND hp>0; a docked team is checked for a common port in the launch branch.
  if v_launch_from_dock then
    select count(*) into v_not_home
      from public.main_ship_instances
      where main_ship_id = any(v_members)
        and (not (status = 'home' or (status = 'stationary' and spatial_state = 'at_location')) or hp <= 0);
  else
    select count(*) into v_not_home
      from public.main_ship_instances
      where main_ship_id = any(v_members) and (status <> 'home' or hp <= 0);
  end if;
  if v_not_home > 0 then
    return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
  end if;

  -- ── NOHOME (0199) LAUNCH-FROM-DOCK BRANCH — the whole team launches as ONE fleet from its port ──────
  -- Triggers ONLY when the flag is lit AND at least one member is docked. A docked team must be gathered
  -- at ONE port (else member_not_ready — the same all-or-nothing posture the move-team gate uses, 0190).
  -- The members' own present fleets are dissolved (they leave to fly with the team); the ONE new team
  -- fleet departs from the common port; origin_base_id stays the legacy base so the escape tick's
  -- return-to-base mechanics (process_combat_ticks 0169:217-228 — UNTOUCHED) still work, and the chosen
  -- (or origin) return port is recorded so the reconciler docks the team there instead of re-homing.
  -- (N2) count docked members ONLY when lit — the DARK path never touches this (v_docked stays NULL and
  -- the short-circuit `v_launch_from_dock and …` below never evaluates it).
  if v_launch_from_dock then
    select count(*) into v_docked
      from public.main_ship_instances
      where main_ship_id = any(v_members) and status = 'stationary' and spatial_state = 'at_location';
  end if;

  if v_launch_from_dock and v_docked > 0 then
    -- EVERY member must be docked at ONE common port (a mixed home/docked team, or a split-port team,
    -- is not a coherent single-origin launch → member_not_ready).
    if v_docked <> array_length(v_members, 1) then
      return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
    end if;
    select count(distinct lp.location_id) into v_dockcount
      from public.main_ship_instances s
      join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = v_player and f.status = 'present'
      join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
      where s.main_ship_id = any(v_members);
    if v_dockcount is distinct from 1 then
      return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
    end if;
    -- the ONE common port + its coordinates (distinct count proved a single location above).
    select lp.location_id, lp.zone_id, l.x, l.y, z.sector_id
      into v_cur
      from public.main_ship_instances s
      join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = v_player and f.status = 'present'
      join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
      join public.locations l on l.id = lp.location_id
      join public.zones z on z.id = l.zone_id
      where s.main_ship_id = any(v_members)
      limit 1;
    v_dock_loc := v_cur.location_id;
    v_return   := coalesce(p_return_location_id, v_dock_loc);

    -- Active-fleet limit EXCLUDING the members' own present fleets (they are dissolved below; the team
    -- consumes ONE slot net — the 0168/0019 shared-budget idiom, adjusted for the dissolve).
    v_max := coalesce(cfg_num('max_active_fleets'), 3);
    select count(*) into v_active
      from fleets
      where player_id = v_player and status in ('moving','present','returning')
        and (main_ship_id is null or not (main_ship_id = any(v_members)));
    if v_active >= v_max then
      return jsonb_build_object('ok', false, 'reason', 'fleet_limit_reached');
    end if;

    -- Team stats over the LOCKED members (the 0168 fold verbatim; raises → stats_invalid envelope).
    v_power := 0;
    v_speed := null;
    begin
      foreach v_ship in array v_members loop
        v_stats := public.calculate_expedition_stats(v_player, v_ship, '[]'::jsonb, 'pirate_hunt');
        v_power := v_power + coalesce((v_stats->>'combat_power')::double precision, 0);
        v_ms    := (v_stats->>'speed')::double precision;
        v_speed := least(coalesce(v_speed, v_ms), v_ms);
      end loop;
    exception when others then
      return jsonb_build_object('ok', false, 'reason', 'stats_invalid');
    end;
    if v_power < coalesce(v_loc.min_power_required, 0) then
      return jsonb_build_object('ok', false, 'reason', 'power_below_required');
    end if;

    -- origin_base anchors the return-to-base mechanics (the escape tick reads origin_base_id).
    select id, x, y, sector_id into v_base
      from bases where player_id = v_player and status = 'active'
      order by created_at limit 1;
    if v_base.id is null then
      return jsonb_build_object('ok', false, 'reason', 'no_home_base');
    end if;

    -- ── WRITES (all-or-nothing) ─────────────────────────────────────────────────────────────────────
    -- Dissolve each docked member's OWN present fleet: close its active presence and complete the fleet
    -- (the ship leaves the dock to fly with the team). fleet_complete requires 'returning', so this is a
    -- direct completed-write (the dock had no movement).
    perform presence_complete(lp.id)
      from public.fleets f
      join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
      where f.player_id = v_player and f.main_ship_id = any(v_members) and f.status = 'present';
    update public.fleets
      set status = 'completed', location_mode = 'movement', active_movement_id = null,
          current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
          updated_at = now()
      where player_id = v_player and main_ship_id = any(v_members) and status = 'present';

    -- ONE team fleet (main_ship_id NULL; members carried by the manifest) tagged with the group, origin
    -- the legacy base (return mechanics) + the recorded return port.
    insert into fleets (player_id, origin_base_id, status, location_mode, current_base_id, group_id, return_location_id)
      values (v_player, v_base.id, 'idle', 'base', v_base.id, v_group, v_return)
      returning id into v_fleet;

    -- Depart from the COMMON DOCKED PORT (origin_type='location', the port coordinates), mission
    -- 'hunt_pirates' — NOT from the (0,0) base.
    v_movement := movement_create(
      v_player, v_fleet,
      'location', null, v_cur.zone_id, v_dock_loc, v_cur.x, v_cur.y,
      'location', null, null, v_loc.id, v_loc.x, v_loc.y,
      'hunt_pirates', v_speed);
    perform fleet_set_moving(v_fleet, v_movement);

    update main_ship_instances
      set status = 'hunting', spatial_state = null, space_x = null, space_y = null, updated_at = now()
      where main_ship_id = any(v_members);

    insert into group_sortie_members (fleet_id, main_ship_id, player_id)
      select v_fleet, m, v_player from unnest(v_members) as m;

    select arrive_at into v_arrive from fleet_movements where id = v_movement;
    return jsonb_build_object(
      'ok', true, 'group_id', v_group, 'fleet_id', v_fleet, 'movement_id', v_movement,
      'arrive_at', v_arrive, 'member_count', array_length(v_members, 1), 'return_location_id', v_return);
  end if;

  -- ── 0168 HEAD (DARK path — byte-identical to send_ship_group_hunt 0168:226-312) ─────────────────────
  v_max := coalesce(cfg_num('max_active_fleets'), 3);
  select count(*) into v_active
    from fleets where player_id = v_player and status in ('moving','present','returning');
  if v_active >= v_max then
    return jsonb_build_object('ok', false, 'reason', 'fleet_limit_reached');
  end if;

  v_power := 0;
  v_speed := null;
  begin
    foreach v_ship in array v_members loop
      v_stats := public.calculate_expedition_stats(v_player, v_ship, '[]'::jsonb, 'pirate_hunt');
      v_power := v_power + coalesce((v_stats->>'combat_power')::double precision, 0);
      v_ms    := (v_stats->>'speed')::double precision;
      v_speed := least(coalesce(v_speed, v_ms), v_ms);
    end loop;
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'stats_invalid');
  end;

  if v_power < coalesce(v_loc.min_power_required, 0) then
    return jsonb_build_object('ok', false, 'reason', 'power_below_required');
  end if;

  select id, x, y, sector_id into v_base
    from bases where player_id = v_player and status = 'active'
    order by created_at limit 1;
  if v_base.id is null then
    return jsonb_build_object('ok', false, 'reason', 'no_home_base');
  end if;

  insert into fleets (player_id, origin_base_id, status, location_mode, current_base_id, group_id)
    values (v_player, v_base.id, 'idle', 'base', v_base.id, v_group)
    returning id into v_fleet;

  v_movement := movement_create(
    v_player, v_fleet,
    'base', v_base.id, null, null, v_base.x, v_base.y,
    'location', null, null, v_loc.id, v_loc.x, v_loc.y,
    'hunt_pirates', v_speed);
  perform fleet_set_moving(v_fleet, v_movement);

  update main_ship_instances
    set status = 'hunting', spatial_state = null, space_x = null, space_y = null, updated_at = now()
    where main_ship_id = any(v_members);

  insert into group_sortie_members (fleet_id, main_ship_id, player_id)
    select v_fleet, m, v_player from unnest(v_members) as m;

  select arrive_at into v_arrive from fleet_movements where id = v_movement;
  return jsonb_build_object(
    'ok', true, 'group_id', v_group, 'fleet_id', v_fleet, 'movement_id', v_movement,
    'arrive_at', v_arrive, 'member_count', array_length(v_members, 1));
end;
$$;
revoke execute on function public.send_ship_group_hunt(uuid, uuid, uuid) from public, anon;
grant  execute on function public.send_ship_group_hunt(uuid, uuid, uuid) to authenticated;

-- ── §8) SELF-ASSERTS — the flag seed is dark, the column/index exist, the DARK paths are the head verbatim
do $fleetctrl$
declare
  v_src text;
begin
  -- (a) the flag seed is committed DARK (false) — this migration never lights it.
  if coalesce((select value #>> '{}' from public.game_config where key = 'fleet_control_enabled'), 'false') <> 'false' then
    raise exception 'FLEETCTRL self-assert FAIL: fleet_control_enabled is not seeded false';
  end if;

  -- (b) the additive column exists, not-null, default false.
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'main_ship_instances' and column_name = 'is_command_ship'
      and is_nullable = 'NO' and column_default like '%false%') then
    raise exception 'FLEETCTRL self-assert FAIL: main_ship_instances.is_command_ship missing / nullable / not default false';
  end if;
  -- every existing row reads false (deploy-inert: no fleet is active under the new model on deploy).
  if exists (select 1 from public.main_ship_instances where is_command_ship) then
    raise exception 'FLEETCTRL self-assert FAIL: a main_ship_instances row is already is_command_ship=true on deploy';
  end if;
  -- the partial command-ship index exists.
  if not exists (select 1 from pg_indexes where schemaname='public' and indexname='idx_msi_command_ship') then
    raise exception 'FLEETCTRL self-assert FAIL: idx_msi_command_ship partial index missing';
  end if;

  -- (c) set_fleet_command_ship — single definition, authenticated-executable, owner resolver + the
  --     ship_not_in_fleet guard present; NOT gated on fleet_control_enabled (settable while dark).
  select prosrc into v_src from pg_proc where oid = 'public.set_fleet_command_ship(uuid, boolean)'::regprocedure;
  if v_src is null then raise exception 'FLEETCTRL self-assert FAIL: set_fleet_command_ship(uuid,boolean) not deployed'; end if;
  if position('mainship_resolve_owned_ship' in v_src) = 0 or position('ship_not_in_fleet' in v_src) = 0 then
    raise exception 'FLEETCTRL self-assert FAIL: set_fleet_command_ship lacks the owner resolver / ship_not_in_fleet guard'; end if;
  if position('fleet_control_enabled' in v_src) > 0 then
    raise exception 'FLEETCTRL self-assert FAIL: set_fleet_command_ship must NOT read fleet_control_enabled (designation is always settable)'; end if;
  if not has_function_privilege('authenticated', 'public.set_fleet_command_ship(uuid, boolean)', 'execute') then
    raise exception 'FLEETCTRL self-assert FAIL: set_fleet_command_ship not authenticated-executable'; end if;

  -- (d) each re-created group RPC: single definition, carries the flag read + the marked reason token, and
  --     the DARK-head tokens survive verbatim (the head body is intact in the flag-off path).
  --   assign_ship_to_group — the 8-cap hunk + the 0161 head.
  select prosrc into v_src from pg_proc where oid = 'public.assign_ship_to_group(uuid, uuid)'::regprocedure;
  if position('v_fleet_control boolean := public.cfg_bool(''fleet_control_enabled'')' in v_src) = 0
     or position('fleet_full' in v_src) = 0
     or position('mainship_resolve_owned_group' in v_src) = 0 then
    raise exception 'FLEETCTRL self-assert FAIL: assign_ship_to_group lacks the flag read / fleet_full hunk / the 0161 head'; end if;

  --   send_ship_group_expedition — the command-ship hunk + the 0187 head (TEAMMAP-1 tag survives).
  select prosrc into v_src from pg_proc where oid = 'public.send_ship_group_expedition(uuid, uuid)'::regprocedure;
  if position('v_fleet_control boolean := public.cfg_bool(''fleet_control_enabled'')' in v_src) = 0
     or position('fleet_inactive_no_command' in v_src) = 0
     or position('id in (select (e->>''fleet_id'')::uuid from jsonb_array_elements(v_sent) e)' in v_src) = 0 then
    raise exception 'FLEETCTRL self-assert FAIL: send_ship_group_expedition lacks the flag read / command hunk / the 0187 tag head'; end if;

  --   move_ship_group_to_location — the command-ship hunk + the 0190 head (docked-move readiness survives).
  select prosrc into v_src from pg_proc where oid = 'public.move_ship_group_to_location(uuid, uuid)'::regprocedure;
  if position('v_fleet_control boolean := public.cfg_bool(''fleet_control_enabled'')' in v_src) = 0
     or position('fleet_inactive_no_command' in v_src) = 0
     or position('status <> ''stationary'' or spatial_state is distinct from ''at_location''' in v_src) = 0 then
    raise exception 'FLEETCTRL self-assert FAIL: move_ship_group_to_location lacks the flag read / command hunk / the 0190 head'; end if;

  --   send_ship_group_hunt — the command-ship hunk + the 0199 head (both the NOHOME lit branch + the 0168 dark head).
  select prosrc into v_src from pg_proc where oid = 'public.send_ship_group_hunt(uuid, uuid, uuid)'::regprocedure;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname='public' and p.proname='send_ship_group_hunt') <> 1 then
    raise exception 'FLEETCTRL self-assert FAIL: send_ship_group_hunt is not a single definition'; end if;
  if position('v_fleet_control boolean := public.cfg_bool(''fleet_control_enabled'')' in v_src) = 0
     or position('fleet_inactive_no_command' in v_src) = 0
     or position('v_launch_from_dock boolean := public.cfg_bool(''launch_from_dock_enabled'')' in v_src) = 0
     or position('insert into fleets (player_id, origin_base_id, status, location_mode, current_base_id, group_id)' in v_src) = 0 then
    raise exception 'FLEETCTRL self-assert FAIL: send_ship_group_hunt lacks the flag read / command hunk / the 0199 (NOHOME + 0168) head'; end if;

  raise notice 'FLEETCTRL self-assert ok: fleet_control_enabled seeded dark; is_command_ship additive/not-null/default-false + partial index; every row false on deploy; set_fleet_command_ship deployed (owner-scoped, ship_not_in_fleet guard, NOT flag-gated, authenticated); the 4 group RPCs carry the flag read + their marked reason token (fleet_full / fleet_inactive_no_command) with the head bodies intact';
end $fleetctrl$;
