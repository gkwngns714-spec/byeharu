-- Byeharu — TEAM-COMMAND Slice B0: DARK group create/assign WRITE PATH (the writer Slice A omitted).
--
-- Slice A (0160) created ship_groups + main_ship_instances.group_id with NO client write path — the table is
-- empty and the roster shows every ship as unassigned. B0 adds the controlled, owner-scoped, DARK server
-- write path: create/rename a team slot, and assign/unassign a ship to a team. It does NOTHING else — no team
-- travel, no send/stop, no movement, no combat, no ship creation (those are Slices B/D).
--
-- ── TERMINOLOGY: "group" (this file, DB, code) == "team" (UI). See docs/TEAM_COMMAND.md. ──────────────────
--
-- ── ANTI-SPAGHETTI LAW (audited) ─────────────────────────────────────────────────────────────────────────
--   Touches ONLY ship_groups + main_ship_instances.group_id. NO fleets/fleet_units/combat_units, NO movement,
--   NO combat engine, NO ship creation. Adds no second client selection source. All new identifiers say
--   "group", never "team".
--
-- ── DARK / GATE ──────────────────────────────────────────────────────────────────────────────────────────
--   Both client RPCs reject-before-read on `cfg_bool('team_command_enabled')` (seeded FALSE in 0160), exactly
--   like commission_additional_main_ship() (0080). NO flag is flipped here; NO game_config is written.
--
-- ── SAME-PLAYER INTEGRITY (the headline) ─────────────────────────────────────────────────────────────────
--   Slice A's single-column FK (0160) lets a ship's group_id point at ANY ship_groups row. assign_ship_to_group
--   closes that gap by construction: it resolves the ship via mainship_resolve_owned_ship(auth.uid(), …) AND
--   the group via mainship_resolve_owned_group(auth.uid(), …) — BOTH against the same auth.uid() — then writes
--   only that pair. As the SOLE write path (no client update grant/policy on either table), a cross-player
--   (ship, group) pairing is unreachable.
--
-- Touches NO existing signature, NO frozen verifier, NO game_config. New functions only.

-- ── A. mainship_resolve_owned_group — internal owned-group resolver (mirrors mainship_resolve_owned_ship 0081).
--    DELIBERATE DIVERGENCE from the ship resolver: NO sole-group shim on null. For assignment, null means
--    "unassign" (the caller's intent), NOT "resolve the sole group" — so this resolver is explicit-ONLY and
--    returns a group_id only when it exists AND belongs to p_player; otherwise NULL (fail closed).
create or replace function public.mainship_resolve_owned_group(p_player uuid, p_group_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select g.group_id
    from public.ship_groups g
   where p_player   is not null
     and p_group_id is not null
     and g.group_id  = p_group_id
     and g.player_id = p_player;
$$;

-- ── B. upsert_ship_group — create or rename a team slot (group_index 1..3). Authenticated, DARK.
--    The (player_id, group_index) UNIQUE (0160) + the 1..3 CHECK cap a player at three rows DECLARATIVELY, so
--    NO advisory lock and NO count(*) are needed (unlike the commission cap, which counts a dynamic total).
create or replace function public.upsert_ship_group(p_group_index integer, p_name text default 'Team')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_clean  text;
  v_gid    uuid;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK gate FIRST — reject-before-read (mirror commission_additional_main_ship 0080). No table touched yet.
  if not public.cfg_bool('team_command_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'team_command_disabled');
  end if;

  -- Validate IN THE RPC so the table CHECKs (0160) can never raise an uncaught 500; the predicates below are
  -- EXACTLY the column constraints (1..3; char_length(btrim()) between 1 and 40), so the RPC is as strict as
  -- the table — never accept-then-violate.
  if p_group_index is null or p_group_index < 1 or p_group_index > 3 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_group_index');
  end if;

  v_clean := btrim(coalesce(p_name, ''));
  if char_length(v_clean) < 1 or char_length(v_clean) > 40 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_name');
  end if;

  -- Atomic, race-safe on the unique key: one caller inserts, a concurrent one conflicts→updates. No duplicate,
  -- no error, no lock (see header).
  insert into public.ship_groups (player_id, group_index, name)
  values (v_player, p_group_index, v_clean)
  on conflict (player_id, group_index)
    do update set name = excluded.name, updated_at = now()
  returning group_id into v_gid;

  return jsonb_build_object('ok', true, 'group_id', v_gid, 'group_index', p_group_index, 'name', v_clean);
end;
$$;

-- ── C. assign_ship_to_group — assign an owned ship to an owned team, or UNASSIGN (p_group_id null).
--    Authenticated, DARK. Both ownerships are asserted against the SAME auth.uid() (see header §SAME-PLAYER).
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
  end if;

  -- Single-row write. v_ship and v_group were both asserted against v_player=auth.uid() → the pair is
  -- same-player by construction; the player_id predicate is defense-in-depth.
  update public.main_ship_instances
     set group_id = v_group, updated_at = now()
   where main_ship_id = v_ship and player_id = v_player;

  return jsonb_build_object('ok', true, 'main_ship_id', v_ship, 'group_id', v_group);
end;
$$;

-- ── D. ACLs (0080 §E idiom). Resolver = internal helper (no client grant). The two write RPCs = authenticated
--    only; the in-body gate rejects every call while team_command_enabled is false. Explicit revokes are
--    defense-in-depth: since 0043's `alter default privileges … revoke execute`, new functions no longer
--    default-grant to PUBLIC.
revoke execute on function public.mainship_resolve_owned_group(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.upsert_ship_group(integer, text)         from public, anon;
grant  execute on function public.upsert_ship_group(integer, text)         to authenticated;
revoke execute on function public.assign_ship_to_group(uuid, uuid)         from public, anon;
grant  execute on function public.assign_ship_to_group(uuid, uuid)         to authenticated;
