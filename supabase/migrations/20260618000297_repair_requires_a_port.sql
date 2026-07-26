-- REPAIR REQUIRES A PORT (0297) — the owner's bug report, closed as ONE slice.
--
-- THE COMPLAINT (verbatim): "The fleet ships are able to repair even though they are not in a city."
--
-- ── WHAT WAS TRUE BEFORE THIS FILE ────────────────────────────────────────────────────────────────
-- repair_main_ship (TRUE head 20260618000231:335-385) restored hp = max_hp, status = 'home', for
-- free, ANYWHERE. Its complete gate was: authenticated -> owns the ship -> status = 'destroyed' ->
-- max_hp > 0. No position check of any kind. That was deliberate — it is the 0052 NO-SOFTLOCK
-- safelock ("recovery must always be possible") — and it was harmless for as long as a defeat could
-- only ever be observed at a location.
--
-- 0293 ended that. Its hunk [A1] (20260618000293:663) made the location-linked ambush branch park the
-- fleet with fleet_set_in_space(...) instead of teleporting it to the linked location, while :701
-- still opens the encounter; and it widened fleet_destroy's from-state (:457) to admit
-- (status='idle' and location_mode='space'), which before 0293 would have RAISED. So for the first
-- time the defeat branch of process_combat_ticks completes in OPEN SPACE, and the free, ungated
-- repair CTA appears on a wreck floating in the deep. That is what the owner saw.
--
-- ── WHY THE OBVIOUS FIX IS THE WRONG FIX (verified, not assumed) ──────────────────────────────────
-- The natural move is "compose mainship_resolve_docked_location (0210:278-306), the same resolver the
-- paid repair_ship_hull_at_port gates on (0201:177)". It CANNOT be used here, and using it would
-- softlock every destroyed ship in the game, permanently:
--
--   * mainship_resolve_docked_location asks mainship_space_validate_context first and requires the
--     answer 'at_location'. In BOTH of that oracle's branches, 'destroyed' is checked FIRST and
--     short-circuits — the unified/group branch at 20260618000221:199-201, the per-ship fallback at
--     :254-257. A destroyed ship therefore resolves 'destroyed', never 'at_location', so the docked
--     resolver returns NULL for a destroyed ship IN EVERY POSITION, including tied up at a port.
--   * And the ship's fleet is gone anyway: process_combat_ticks' defeat branch calls
--     fleet_destroy(e.fleet_id) and ONLY THEN loops mainship_mark_combat_destroyed over the
--     encounter's member ships (the shape is identical in every live head — 20260618000228:366-371 is
--     the current one). A destroyed ship therefore ALWAYS sits in a destroyed fleet, and both
--     mainship_resolve_fleet (0210:52-118) and the oracle filter fleets to
--     status in ('idle','moving','present','returning'). Nothing that exists today can tell you where
--     a destroyed ship is.
--
-- So this file answers the position question with the ONE fact the schema still holds for a ship that
-- has no fleet: its BERTH. main_ship_instances carries berth_location_id under a hard CHECK —
-- main_ship_instances_group_berth_xor, 20260618000216:150-155: (group_id is null) = (berth_location_id
-- is not null). Fleeted ship => berth NULL. Berthed ship => it is AT that port. That XOR is exactly
-- the owner's distinction: a ship flying with a fleet is not in a city; a berthed ship is.
--
-- ── WHAT THIS FILE DOES (three functions, one concept) ────────────────────────────────────────────
--   §1 mainship_port_of_ship(ship) -> uuid — NEW, and the ONE authority for "which port is this ship
--      physically at, regardless of its lifecycle status". Two arms, both byte-copied from the arms
--      get_my_fleet_positions already uses to render "Docked at <port>": the fleet-dock read
--      (20260618000231:1069-1076) and the berth read (:1107-1110). It is NOT a fork of
--      mainship_resolve_docked_location — that function answers a DIFFERENT question (is this ship in
--      a coherent, settled, at_location context) and is left untouched, byte-for-byte, along with
--      every one of its callers.
--   §2 repair_main_ship(uuid) — the 0231 TRUE head, byte-copied, with ONE new hunk: the position
--      gate. Signature, volatility, security/search_path, return shape, both write branches, the
--      destroyed-only guard and its 'ship is not disabled' message are unchanged. The gate is about
--      POSITION and reads no flag, so scripts/activate-repair-econ.sql:119-129 (which pins that this
--      body never references repair_economy_enabled and never loses 'ship is not disabled') stays
--      true — re-asserted by this file's own self-assert.
--   §3 mainship_emergency_tow(uuid) -> jsonb — NEW. THE OTHER HALF OF THE SLICE. A gate with no way
--      out is a softlock, and a softlock is the exact thing 0052 exists to prevent. A destroyed ship
--      that is at no port is hauled — free, instantly, always available — to the nearest active
--      non-combat port and BERTHED there. The write is ONE update of the two XOR columns, the
--      identical write shape delete_ship_group already uses (20260618000216:618-628); it creates no
--      fleet, no movement and no presence, because there is nothing left to move: the wreck's fleet
--      is destroyed by construction (see above).
--   §4 get_my_disabled_ships() -> jsonb — NEW owner-read, the client's ONE source for the gate. It
--      exists because get_my_fleet_positions EXCLUDES destroyed ships outright
--      (20260618000231:1029-1030 `and status <> 'destroyed'`), so the Fitting screen has literally no
--      way to learn where a wreck is; without this it would show "Location unavailable" beside a
--      disabled Repair button and the player could not act. It answers from §1 — the SAME leaf the
--      server gate uses — so the button state and the server verdict can never disagree.
--
-- ── ██ WHAT A CURRENTLY-DESTROYED PLAYER SHIP EXPERIENCES THE MOMENT THIS DEPLOYS ██ ──────────────
-- Production is a LIVE ~30-player game. Plainly, for every ship sitting at status='destroyed' right
-- now:
--   * BERTHED wreck (group_id NULL, berth set — the shape every dev-destroyed and every
--     never-fleeted ship has): NOTHING CHANGES. Repair still works, still free, still instant.
--   * FLEETED wreck (group_id set, berth NULL — the shape a combat defeat leaves, in space OR at a
--     port): the Repair button stops working and raises ship_not_at_port. The player is NOT stranded:
--     "Tow to port" appears in its place on the same row, and one tap berths the wreck at the nearest
--     port and unlocks Repair there. The tow is free, has no cooldown, cannot fail for want of a
--     fleet/base/movement, and is granted to every authenticated player.
--   * Nobody loses a ship, hp, cargo, credits or a fleet. The only durable writes this file can ever
--     make are the two berth/group columns on the caller's OWN wreck.
-- The one visible cost: a towed wreck LEAVES its fleet (the XOR forbids being both berthed and
-- grouped, and its fleet was destroyed anyway). The player re-adds it in Command after repairing.
--
-- ── SELF-ASSERT SCOPE ────────────────────────────────────────────────────────────────────────────
-- Pins THIS migration's own effect ONLY: the three new/re-created bodies, their ACLs, and one
-- zero-write behavioural probe. It asserts NO game_config value, NO feature flag and NO seed row, and
-- every check holds on a completely EMPTY dataset.

-- ══════════════════════════════════════════════════════════════════════════════════════════════════
-- §1. mainship_port_of_ship — the ONE "is this ship at a port, and which" authority.
-- ══════════════════════════════════════════════════════════════════════════════════════════════════
-- Deliberately NOT routed through mainship_space_validate_context: that oracle answers the LIFECYCLE
-- question first ('destroyed' short-circuits, 0221:199-201 / :254-257) and therefore cannot answer a
-- POSITION question about a wreck. This leaf asks only about position, and is honest for a ship in
-- any status.
--
-- ARM ORDER mirrors get_my_fleet_positions exactly: the fleet answers first; the berth answers only
-- when the ship has no resolved fleet (0231:1107-1108's own guard). Deliberately NOT gated on
-- fleet_movement_unified_enabled — unlike the projection's berth arm, which is gated because it is a
-- MAP-RENDER parity concern. berth_location_id is a hard, flag-independent fact under the 0216 XOR
-- CHECK, and gating a SAFETY gate on a feature flag would mean the flag's value could strand a ship.
create or replace function public.mainship_port_of_ship(p_main_ship_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_ship  public.main_ship_instances%rowtype;
  v_fleet uuid;
  v_loc   uuid;
begin
  select * into v_ship from public.main_ship_instances where main_ship_id = p_main_ship_id;
  if not found then
    return null;
  end if;

  v_fleet := public.mainship_resolve_fleet(p_main_ship_id);

  -- ARM 1 — the ship's FLEET is tied up at a port (get_my_fleet_positions' 'docked' arm, 0231:1069-1076).
  if v_fleet is not null then
    select f.current_location_id
      into v_loc
      from public.fleets f
     where f.id = v_fleet
       and f.status = 'present'
       and f.location_mode = 'location'
     limit 1;
    if v_loc is not null then
      return v_loc;
    end if;
    -- A resolved fleet that is NOT docked owns the answer: the ship is with that fleet, wherever it
    -- is, and its berth (NULL under the XOR) has nothing to add.
    return null;
  end if;

  -- ARM 2 — the BERTH (get_my_fleet_positions' 'berthed' arm, 0231:1107-1110). No fleet + a berth =
  -- the ship is sitting at that port.
  return v_ship.berth_location_id;
end;
$function$;

comment on function public.mainship_port_of_ship(uuid) is
  'POSITION, not lifecycle (0297): the port this ship is physically at — its fleet''s dock if it has a '
  'resolved fleet, else its berth — or NULL if it is at no port. Honest for a DESTROYED ship, which '
  'mainship_resolve_docked_location cannot be: that resolver goes through '
  'mainship_space_validate_context, whose ''destroyed'' arm short-circuits ahead of ''at_location'' '
  '(0221:199-201, :254-257). The two answer different questions and neither replaces the other.';

revoke execute on function public.mainship_port_of_ship(uuid) from public, anon, authenticated;
grant  execute on function public.mainship_port_of_ship(uuid) to service_role;


-- ══════════════════════════════════════════════════════════════════════════════════════════════════
-- §2. repair_main_ship — the 20260618000231:335-385 TRUE head, byte-copied, ONE marked hunk.
-- ══════════════════════════════════════════════════════════════════════════════════════════════════
-- PARITY: signature (uuid default null), returns jsonb, language plpgsql, security definer,
-- `set search_path = public`, the v_launch_from_dock read, BOTH write branches, both return shapes,
-- every raise text — all byte-identical to the 0231 head. The ONLY delta anywhere in this body is the
-- marked gate block, and it is placed AFTER the destroyed-only guard so a healthy ship still gets the
-- 'ship is not disabled' answer first (the message scripts/activate-repair-econ.sql:127 pins, and the
-- one scripts/verify-mainship-repair.mjs:126 matches on).
--
-- It STAYS the free, never-priced, never-flag-gated safelock: no cost, no cooldown, no
-- repair_economy_enabled read, no game_config read of any kind added. What changed is WHERE, never
-- WHETHER.
create or replace function public.repair_main_ship(p_main_ship_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_ship   main_ship_instances%rowtype;
  v_launch_from_dock boolean := public.cfg_bool('launch_from_dock_enabled');
  -- ★ 0297 HUNK (declare): the port this ship is at, from the ONE position authority (§1). ★
  v_port   uuid;
begin
  if v_player is null then
    raise exception 'repair_main_ship: not authenticated';
  end if;

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

  -- ██ 0297 HUNK — THE POSITION GATE. THE WHOLE POINT OF THIS MIGRATION. ████████████████████████████
  -- The owner's rule: a ship is repaired in a city, not adrift. Composed from §1, the ONE authority
  -- for where a ship is — never a second inlined dock read (the 0138 disease), and never
  -- mainship_resolve_docked_location, which structurally cannot answer for a destroyed ship (file
  -- header). This is a POSITION test: it reads no flag, no price, no wallet, so the free safelock
  -- stays free and stays ungated by the economy.
  -- IT IS NOT A SOFTLOCK: mainship_emergency_tow (§3) is free, always available to exactly the ships
  -- this rejects, and berths them at a port where this gate then passes.
  v_port := public.mainship_port_of_ship(v_ship.main_ship_id);
  if v_port is null then
    raise exception 'repair_main_ship: ship_not_at_port — this ship is adrift; tow it to a port before repairing';
  end if;
  -- ██ END 0297 HUNK — the 0231 head continues verbatim from here ██████████████████████████████████

  if v_launch_from_dock then
    -- 4C-MIG-2B HUNK: the spatial_state/space_x/space_y=null co-change retires WITH the columns
    -- (it existed only to satisfy the 0055 CHECK coupling, dropped in 0231 §4 in that same
    -- transaction). status='home' is unchanged from 2a's b4 hunk.
    update main_ship_instances
      set hp = v_ship.max_hp, status = 'home', updated_at = now()
      where main_ship_id = v_ship.main_ship_id;
    return jsonb_build_object(
      'main_ship_id', v_ship.main_ship_id, 'status', 'home',
      'hp', v_ship.max_hp, 'max_hp', v_ship.max_hp);
  end if;

  -- 0081 HEAD (DARK path — byte-identical): restore to full readiness, back home.
  update main_ship_instances
    set hp = v_ship.max_hp, status = 'home', updated_at = now()
    where main_ship_id = v_ship.main_ship_id;

  return jsonb_build_object(
    'main_ship_id', v_ship.main_ship_id, 'status', 'home',
    'hp', v_ship.max_hp, 'max_hp', v_ship.max_hp);
end;
$$;
revoke execute on function public.repair_main_ship(uuid) from public, anon;
grant execute on function public.repair_main_ship(uuid) to authenticated;

comment on function public.repair_main_ship(uuid) is
  'THE FREE NO-SOFTLOCK RECOVERY (0052), now POSITION-GATED (0297): a disabled ship is restored to '
  'full hp for free, with no cost/cooldown/flag — but only while it is AT A PORT '
  '(mainship_port_of_ship). A wreck that is at no port raises ship_not_at_port and must first be '
  'hauled in by mainship_emergency_tow, which is free and always available — so the safelock '
  'guarantee (recovery is always reachable) is preserved end to end.';


-- ══════════════════════════════════════════════════════════════════════════════════════════════════
-- §3. mainship_emergency_tow — the recovery route. The half without which §2 would be a softlock.
-- ══════════════════════════════════════════════════════════════════════════════════════════════════
-- WHY IT IS A BERTH WRITE AND NOT A MOVEMENT: a destroyed ship is, by construction, in a DESTROYED
-- fleet (process_combat_ticks destroys the fleet, then marks its member ships — 0228:366-371). There
-- is no fleet to move, and minting a fresh one to fly a 0-hp hull back through the danger zones that
-- just killed it would be a second, parallel movement path for a state that has no business flying.
-- The schema already has the exact concept for "this ship is at a port and is not with a fleet":
-- BERTHED (0216). So the tow simply makes the wreck berthed at a port — the same ONE update of the
-- two XOR-coupled columns that delete_ship_group performs at 20260618000216:618-628. It writes
-- nothing else: no fleets, no fleet_movements, no location_presence, no combat rows, no hp, no
-- status, no wallet.
--
-- REJECT ORDER (envelope, never a raise — this is a client RPC boundary):
--   not_authenticated -> ship_not_found -> ship_not_disabled -> already_at_port -> no_port_available -> ok
create or replace function public.mainship_emergency_tow(p_main_ship_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player  uuid := auth.uid();
  v_ship_id uuid;
  v_ship    public.main_ship_instances%rowtype;
  v_x       double precision;
  v_y       double precision;
  v_port    record;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- The SAME ownership resolver every other main-ship RPC uses; the client id is never trusted.
  v_ship_id := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship_id is null then
    return jsonb_build_object('ok', false, 'reason', 'ship_not_found');
  end if;
  select * into v_ship from public.main_ship_instances where main_ship_id = v_ship_id;

  -- A tow is WRECK RECOVERY, not free teleportation: only a disabled ship qualifies. A live ship
  -- moves with its fleet through command_ship_group_go, which this function must never shadow.
  if v_ship.status <> 'destroyed' then
    return jsonb_build_object('ok', false, 'reason', 'ship_not_disabled');
  end if;

  -- Already at a port -> nothing to haul; repair is already unlocked. Answered by the SAME leaf §2
  -- gates on, so the tow can never disagree with the repair gate about whether it is needed.
  if public.mainship_port_of_ship(v_ship_id) is not null then
    return jsonb_build_object('ok', false, 'reason', 'already_at_port');
  end if;

  -- WHERE THE WRECK LIES — best effort, for choosing the NEAREST port only. fleet_destroy writes only
  -- status/location_mode/active_movement_id (0293:451-457), so a fleet killed in open space still
  -- carries the space_x/space_y fleet_set_in_space last wrote (0231:1159-1165). Unknown position is
  -- fine: the ordering below simply degrades to a deterministic pick.
  select f.space_x, f.space_y
    into v_x, v_y
    from public.fleets f
   where f.player_id = v_player
     and f.space_x is not null and f.space_y is not null
     and ((v_ship.group_id is not null and f.group_id = v_ship.group_id and f.main_ship_id is null)
          or f.main_ship_id = v_ship_id)
   order by f.updated_at desc
   limit 1;

  -- THE DESTINATION — an active, NON-COMBAT location: exactly command_ship_group_go's own
  -- destination rule (0292:291-296), composed rather than re-invented, so a tow can never dump a
  -- wreck somewhere the ordinary mover would refuse to send a fleet. Nearest to the wreck when the
  -- wreck's position is known; `l.id` breaks every tie so the choice is deterministic.
  select l.id, l.name
    into v_port
    from public.locations l
   where l.status = 'active'
     and l.activity_type is not distinct from 'none'
   order by case when v_x is null or v_y is null then 0
                 else (l.x - v_x) * (l.x - v_x) + (l.y - v_y) * (l.y - v_y) end asc,
            l.id asc
   limit 1;
  if v_port.id is null then
    -- Only reachable on a world with no active non-combat location at all (an empty/unseeded DB).
    return jsonb_build_object('ok', false, 'reason', 'no_port_available');
  end if;

  -- THE TOW — ONE update of the two XOR-coupled columns, the 0216:618-628 write shape. The XOR CHECK
  -- (main_ship_instances_group_berth_xor) admits no intermediate: group NULL + berth NULL is illegal,
  -- so un-grouping and berthing MUST land in the same statement. The wreck leaves its (already
  -- destroyed) fleet and is berthed at the port that took it in.
  update public.main_ship_instances
     set group_id = null,
         berth_location_id = v_port.id,
         updated_at = now()
   where main_ship_id = v_ship_id and player_id = v_player;

  return jsonb_build_object(
    'ok', true,
    'main_ship_id', v_ship_id,
    'location_id', v_port.id,
    'location_name', v_port.name);
end;
$$;

comment on function public.mainship_emergency_tow(uuid) is
  'THE RECOVERY ROUTE for 0297''s repair gate: a DESTROYED ship that is at no port is hauled to the '
  'nearest active non-combat port and BERTHED there (one update of the 0216 XOR columns — it leaves '
  'its destroyed fleet). Free, instant, no cooldown, no flag, no cost; it exists so the position gate '
  'on repair_main_ship can never strand a ship, which is the 0052 safelock guarantee.';

revoke execute on function public.mainship_emergency_tow(uuid) from public, anon;
grant  execute on function public.mainship_emergency_tow(uuid) to authenticated;


-- ══════════════════════════════════════════════════════════════════════════════════════════════════
-- §4. get_my_disabled_ships — the client's ONE read of the gate.
-- ══════════════════════════════════════════════════════════════════════════════════════════════════
-- get_my_fleet_positions, the projection every screen uses for "where is this ship", filters
-- destroyed ships OUT at 20260618000231:1029-1030. A wreck therefore has NO position row and the
-- Fitting screen renders "Location unavailable" for it — which, the moment repair is position-gated,
-- would leave the player looking at a dead button with no way to learn why or what to do. This read
-- closes that seam. It answers from mainship_port_of_ship, the SAME leaf repair_main_ship gates on,
-- so the button state and the server verdict are the same fact by construction.
create or replace function public.get_my_disabled_ships()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_out    jsonb := '[]'::jsonb;
  s        record;
  v_port   uuid;
begin
  if v_player is null then
    return v_out;   -- owner-read: no session, no rows (never an error, never an existence oracle)
  end if;

  for s in
    select main_ship_id, name
      from public.main_ship_instances
     where player_id = v_player
       and status = 'destroyed'
     order by created_at asc
  loop
    v_port := public.mainship_port_of_ship(s.main_ship_id);
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'main_ship_id', s.main_ship_id,
      'name',         s.name,
      'at_port',      v_port is not null,
      'location_id',  v_port));
  end loop;

  return v_out;
end;
$$;

comment on function public.get_my_disabled_ships() is
  'Owner-read companion to get_my_fleet_positions, which excludes destroyed ships (0231:1029-1030): '
  'for each of the caller''s DISABLED ships, whether it is at a port and which one — read from '
  'mainship_port_of_ship, the same authority repair_main_ship (0297) gates on. Returns [] with no '
  'session. Read-only.';

revoke execute on function public.get_my_disabled_ships() from public, anon;
grant  execute on function public.get_my_disabled_ships() to authenticated;


-- ══════════════════════════════════════════════════════════════════════════════════════════════════
-- §5. SELF-ASSERT — this migration's own effect, and nothing else.
-- ══════════════════════════════════════════════════════════════════════════════════════════════════
-- Every check below is about the three bodies this file just wrote, their ACLs, and one zero-write
-- probe. NO game_config value is read, NO feature flag is asserted, NO seed/world row is required —
-- it passes on a completely EMPTY database. (0288 failed a production deploy asserting a flag value;
-- 0295 broke its own disposable-stack proof asserting a seed row existed. Neither shape appears here.)
do $$
declare
  v_src text;
  v_res jsonb;
begin
  -- 1. the new position authority exists with its real signature.
  if to_regprocedure('public.mainship_port_of_ship(uuid)') is null then
    raise exception '0297 self-assert FAIL: mainship_port_of_ship(uuid) not deployed';
  end if;

  -- 2. repair_main_ship carries THE GATE — and still carries everything it must not have lost.
  select prosrc into v_src from pg_proc
   where oid = to_regprocedure('public.repair_main_ship(uuid)')::oid;
  if v_src is null then
    raise exception '0297 self-assert FAIL: repair_main_ship(uuid) not deployed';
  end if;
  if position('mainship_port_of_ship' in v_src) = 0 then
    raise exception '0297 self-assert FAIL: repair_main_ship does not compose the position authority';
  end if;
  if position('ship_not_at_port' in v_src) = 0 then
    raise exception '0297 self-assert FAIL: repair_main_ship carries no ship_not_at_port reject';
  end if;
  -- the destroyed-only guard survived (scripts/activate-repair-econ.sql:127 pins this exact string).
  if position('ship is not disabled' in v_src) = 0 then
    raise exception '0297 self-assert FAIL: repair_main_ship lost its destroyed-only guard';
  end if;
  -- the gate is about POSITION, never the economy — scripts/activate-repair-econ.sql:124 stays true.
  if position('repair_economy_enabled' in v_src) <> 0 then
    raise exception '0297 self-assert FAIL: repair_main_ship now references repair_economy_enabled — the free safelock must stay UNGATED';
  end if;

  -- 3. THE OTHER HALF EXISTS. A gate without its recovery route is the softlock 0052 forbids, so the
  --    tow's presence is asserted in the SAME transaction that installs the gate.
  if to_regprocedure('public.mainship_emergency_tow(uuid)') is null then
    raise exception '0297 self-assert FAIL: the recovery route mainship_emergency_tow(uuid) is missing — the gate must never ship without it';
  end if;
  select prosrc into v_src from pg_proc
   where oid = to_regprocedure('public.mainship_emergency_tow(uuid)')::oid;
  if position('berth_location_id' in v_src) = 0 or position('group_id = null' in v_src) = 0 then
    raise exception '0297 self-assert FAIL: the tow does not write both XOR columns (0216 CHECK admits no intermediate)';
  end if;

  -- 4. the client read exists (the seam: without it the screen cannot tell the player where the wreck is).
  if to_regprocedure('public.get_my_disabled_ships()') is null then
    raise exception '0297 self-assert FAIL: get_my_disabled_ships() not deployed';
  end if;

  -- 5. ACL posture. The two client RPCs are authenticated-only, never anon; the internal leaf is
  --    neither (SECURITY DEFINER callers reach it as the owner).
  if not has_function_privilege('authenticated', 'public.repair_main_ship(uuid)', 'execute')
     or has_function_privilege('anon', 'public.repair_main_ship(uuid)', 'execute') then
    raise exception '0297 self-assert FAIL: repair_main_ship ACL drifted (want authenticated-only, never anon)';
  end if;
  if not has_function_privilege('authenticated', 'public.mainship_emergency_tow(uuid)', 'execute')
     or has_function_privilege('anon', 'public.mainship_emergency_tow(uuid)', 'execute') then
    raise exception '0297 self-assert FAIL: mainship_emergency_tow ACL drifted (want authenticated-only, never anon)';
  end if;
  if not has_function_privilege('authenticated', 'public.get_my_disabled_ships()', 'execute')
     or has_function_privilege('anon', 'public.get_my_disabled_ships()', 'execute') then
    raise exception '0297 self-assert FAIL: get_my_disabled_ships ACL drifted (want authenticated-only, never anon)';
  end if;
  if has_function_privilege('authenticated', 'public.mainship_port_of_ship(uuid)', 'execute')
     or has_function_privilege('anon', 'public.mainship_port_of_ship(uuid)', 'execute') then
    raise exception '0297 self-assert FAIL: the internal position leaf must not be client-callable';
  end if;

  -- 6. ZERO-WRITE BEHAVIOURAL PROBES — valid on an EMPTY dataset, and they write nothing.
  --    (a) the leaf is honest about a ship that does not exist.
  if public.mainship_port_of_ship(gen_random_uuid()) is not null then
    raise exception '0297 self-assert FAIL: mainship_port_of_ship invented a port for a nonexistent ship';
  end if;
  --    (b) both client RPCs are safe with NO session: the read returns [], the tow rejects typed.
  --        (This block runs with no request.jwt.claims set, so auth.uid() is NULL.)
  if public.get_my_disabled_ships() is distinct from '[]'::jsonb then
    raise exception '0297 self-assert FAIL: get_my_disabled_ships leaked rows with no session';
  end if;
  v_res := public.mainship_emergency_tow(null::uuid);
  if (v_res ->> 'reason') is distinct from 'not_authenticated' then
    raise exception '0297 self-assert FAIL: the tow did not reject an unauthenticated caller (got %)', v_res;
  end if;

  raise notice '0297 PASS: repair_main_ship position-gated via mainship_port_of_ship (free + economy-ungated, destroyed-only guard intact); mainship_emergency_tow installed as the always-available recovery route (one 0216-XOR berth write); get_my_disabled_ships installed so the client can see the gate; ACLs authenticated-only; probes zero-write';
end $$;
