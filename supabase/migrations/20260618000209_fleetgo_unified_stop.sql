-- FLEET-STOP (step 3c/1 of the movement unification) — the fleet-level BRAKE.
--
-- Charter: docs/MOVEMENT_UNIFICATION_CHARTER.md §2. Follows 0207 (the mover) + 0208 (the fleet's position).
--
-- WHY THIS EXISTS. The live group stop, stop_ship_group_transit (0164), LOOPS the per-ship stop
-- (command_main_ship_stop_transit) once per member fleet. That is the COMPOSED model — N brakes for one
-- fleet — and §2's correction names it as the spaghetti. Under §2 there is ONE moving thing, so there is
-- ONE brake: cancel the fleet's leg and park the fleet where it actually was. It composes NO per-ship
-- mover and writes NOTHING to main_ship_instances.
--
-- 3b MADE THIS TRIVIAL, WHICH IS THE TELL THAT THE MODEL IS RIGHT. A stop is "halt and hold at the
-- interpolated point". Until 0208 the fleet had nowhere to hold — no position column — so the legacy stop
-- had to park the SHIP (0155 writes main_ship_instances.status='stationary', spatial_state='in_space',
-- space_x/space_y = the turn point). That is precisely the per-ship movement state §2 abolishes. With the
-- fleet owning its position, the brake is: interpolate → cancel the leg → fleet_set_in_space(). Three
-- lines, no ship touched, and it reuses 0208's leaf rather than inventing a second parking mechanism.
--
-- IDEMPOTENT / BEST-EFFORT, matching 0164's posture: stopping a fleet that is not moving is a no-op that
-- reports itself, never an error. A brake that throws when you press it twice is a hazard.
--
-- The interpolation is byte-identical to the mover's redirect (0207/0208): a redirect is literally
-- "stop here, then go there", so the two must agree on where "here" is. The proof pins that they do.
--
-- DARK behind fleet_movement_unified_enabled (0207's gate — no new flag). Purely additive: no existing
-- function re-created, no table altered. stop_ship_group_transit (0164) is left ALONE and still live;
-- step 4 retires it when the client repoints. Both existing at once is the transition, not the target.

create or replace function public.command_ship_group_stop(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_player   uuid := auth.uid();
  v_group    uuid;
  v_fleet    uuid;
  v_fleet_row record;
  v_unified_n integer;
  v_mv       record;
  v_t        double precision;
  v_x        double precision;
  v_y        double precision;
  v_now      timestamptz := now();
begin
  -- 1) authenticated caller only.
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- 2) DARK gate — reject before ANY read, lock, or write.
  --    NOTE the deliberate divergence from the OSN stop (0083), which has NO boundary gate so that a flag
  --    flip can never strand an in-flight ship. That reasoning does not transfer: this brake can only ever
  --    stop a fleet that the SAME dark mover launched, so while the gate is false there is nothing here to
  --    strand. If that ever stops being true, this gate must go — not the other way around.
  if not public.cfg_bool('fleet_movement_unified_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'unified_movement_disabled');
  end if;

  -- 3) resolve + LOCK the group. FOR UPDATE, the same first lock the mover takes — a stop and a go on the
  --    same group must serialize, or a go could relaunch a fleet this stop is parking.
  v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
  if v_group is null then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;
  perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  -- 4) the group's ONE unified fleet (group_id + main_ship_id IS NULL — NOT group_id alone; the legacy
  --    expedition send tags group_id onto PER-MEMBER fleets, 0204:316, display-only).
  select count(*) into v_unified_n
    from public.fleets
   where group_id = v_group and player_id = v_player and main_ship_id is null
     and status in ('idle', 'moving', 'present', 'returning');
  if v_unified_n > 1 then
    return jsonb_build_object('ok', false, 'reason', 'fleet_ambiguous');
  end if;
  if v_unified_n = 0 then
    -- The group has no unified fleet at all: nothing to stop. Idempotent, not an error.
    return jsonb_build_object('ok', true, 'group_id', v_group, 'stopped', false, 'reason_code', 'no_fleet');
  end if;

  select * into v_fleet_row
    from public.fleets
   where group_id = v_group and player_id = v_player and main_ship_id is null
     and status in ('idle', 'moving', 'present', 'returning')
   for update;
  v_fleet := v_fleet_row.id;

  -- 5) not in flight → nothing to halt. Idempotent (0164's best-effort posture): pressing the brake on a
  --    parked fleet reports "already stopped", it does not raise.
  if v_fleet_row.active_movement_id is null then
    return jsonb_build_object('ok', true, 'group_id', v_group, 'fleet_id', v_fleet,
                              'stopped', false, 'reason_code', 'not_moving');
  end if;

  select * into v_mv
    from public.fleet_movements
   where id = v_fleet_row.active_movement_id
   for update;
  if v_mv.id is null or v_mv.status <> 'moving' then
    -- The settle cron took it between our reads. Nothing to stop; the arrival is the authority.
    return jsonb_build_object('ok', true, 'group_id', v_group, 'fleet_id', v_fleet,
                              'stopped', false, 'reason_code', 'already_settled');
  end if;

  -- 6) WHERE IT ACTUALLY IS. Byte-identical to the mover's redirect interpolation (0207/0208) — a redirect
  --    is "stop here, then go there", so both must agree on "here". The proof pins the agreement.
  v_t := extract(epoch from (v_now - v_mv.depart_at))
         / nullif(extract(epoch from (v_mv.arrive_at - v_mv.depart_at)), 0);
  v_t := greatest(0::double precision, least(1::double precision, coalesce(v_t, 0)));
  v_x := v_mv.origin_x + (v_mv.target_x - v_mv.origin_x) * v_t;
  v_y := v_mv.origin_y + (v_mv.target_y - v_mv.origin_y) * v_t;

  -- ── WRITES ─────────────────────────────────────────────────────────────────────────────────────
  -- NOTE FOR EVERY FUTURE READER: there is deliberately NO `update main_ship_instances` below. The legacy
  -- stop (0155) parks the SHIP; this parks the FLEET. That difference is the charter's §2.

  update public.fleet_movements
     set status = 'cancelled', resolved_at = v_now
   where id = v_mv.id and status = 'moving';

  -- STOP = HOLD (the 0155 semantic, kept): the fleet holds position in open space at the turn point. It
  -- does NOT return home, and it is immediately re-commandable — command_ship_group_go's location_mode
  -- ='space' branch departs straight from here. Composes 0208's leaf; no second parking mechanism.
  perform public.fleet_set_in_space(v_fleet, v_x, v_y);

  return jsonb_build_object(
    'ok', true,
    'group_id', v_group,
    'fleet_id', v_fleet,
    'stopped', true,
    'cancelled_movement_id', v_mv.id,
    'space_x', v_x,
    'space_y', v_y);
end;
$function$;

comment on function public.command_ship_group_stop(uuid) is
  'FLEET-STOP (charter §2): the ONE fleet-level brake. Halts the group''s fleet and HOLDS it in open space '
  'at the interpolated turn point (0208''s fleet_set_in_space), immediately re-commandable. Idempotent. '
  'Writes NO per-ship movement state — the legacy stop_ship_group_transit (0164) loops the PER-SHIP stop; '
  'this replaces that composed model. DARK behind fleet_movement_unified_enabled.';

revoke all on function public.command_ship_group_stop(uuid) from public;
grant execute on function public.command_ship_group_stop(uuid) to authenticated;
