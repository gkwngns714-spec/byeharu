-- 0215 — BRAKE-SORTIE GUARD (charter §2; the LAST pre-flip blocker of the movement-unification arc).
--
-- TRUE-HEAD DECLARATION: this file re-creates command_ship_group_stop and is now its TRUE HEAD.
-- The 0209 body is superseded — edit and copy from HERE (the 0211 lesson: a guard pointed at a
-- superseded head guards nothing; scripts/fleetgo-proof.sh's MIGRATION_STOP points here now).
--
-- WHAT: the 0209 head, byte-for-byte, with EXACTLY ONE marked hunk. The independent mechanical
-- diff of this file's function body against the 0209 head must show ONLY:
--   • the `v_hunting   integer;` declare line,
--   • the marked sortie-guard hunk between the group lock and the fleet count,
-- and, OUTSIDE the body, exactly one added sentence in the comment-on-function text (the sortie
-- reject). Anything else in the diff is drift and a defect.
--
-- WHY (found by three reviews + the architect): command_ship_group_stop resolves the group's fleet
-- by the exact shape a HUNT's sortie fleet has (0209:73-89 — group_id + main_ship_id IS NULL, four
-- statuses) and had ZERO sortie awareness. Lit, pressing Stop mid-hunt cancels the encounter's leg
-- and parks the fleet IDLE in open space WITH its frozen manifest (group_sortie_members, 0168)
-- still attached. The 0047 retention cron collects only TERMINAL fleets, so an idle fleet — and
-- its manifest, which dies only by ON DELETE CASCADE with the fleet — is immortal. A retained-but-
-- LIVE manifest is invisible to every live-scoped guard, so the next go relaunches the fleet
-- manifest-attached, and from then on every guard (the mover's guard 8, 0213's assign arm, 0214's
-- hunt arm, and this one) answers group_on_sortie FOREVER while the fleet never goes terminal and
-- permanently eats a max_active_fleets slot. It BRICKS THE GROUP.
--
-- THE DESIGN IS CORRECT, NOT A WORKAROUND: a hunt is a commitment of a frozen roster (0168's
-- manifest-wins law). The player aborts it through the existing Retreat button (request_retreat,
-- 0019/0169, live in ActiveCombatPanel) or the forced auto-extract at max_presence_seconds
-- (0169's tick). Rejecting the brake mid-sortie removes ZERO capability.
--
-- WHY LIVE-SCOPED (join fleets on status in moving/present/returning), NEVER a bare EXISTS: a
-- finished sortie's manifest is RETAINED up to 14 days (0169's retention decision + 0047's cron),
-- so a bare EXISTS would refuse to stop every NEW unified go a group launches after any hunt it
-- ever finished — greening the reject proof while bricking the brake the other way. The proof's
-- FLEETGO_PASS_STOP_SORTIE_LIVESCOPE marker makes exactly that mutation red.
--
-- WHY NO FLAG GATE ON THE HUNK: the 0209 head is already in-body gated on
-- cfg_bool('fleet_movement_unified_enabled') BEFORE any read (0209:56, verified). The hunk sits
-- strictly AFTER that gate, so while dark the gate returns first and behavior is byte-identical
-- to the head by construction (FLEETGO_PASS_STOP_DARKINERT pins it at runtime).
--
-- Purely additive posture, same as 0209: no table altered, no function dropped, no flag touched,
-- and (the §2 law) NOTHING written to main_ship_instances.

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
  v_hunting   integer;
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

  -- ── ★ THE 0215 HUNK — the ONLY addition to the 0209 head (plus its declare line and one     ★ ──
  -- ── ★ sentence of comment-on-function text; everything else below is the head, verbatim)    ★ ──
  -- 3b) the group must not be mid-sortie — the mover's guard 8 (0208:332-343), mirrored VERBATIM.
  --    WHY: a hunt's sortie fleet is group-shaped (0168: group_id set + main_ship_id NULL) and
  --    matches the resolve below, so without this guard the brake cancels the encounter's leg and
  --    parks the fleet IDLE in open space WITH its manifest still attached. An idle fleet is
  --    IMMORTAL (0047's retention collects only terminal fleets), the manifest is therefore never
  --    cleared, it is invisible to every LIVE-scoped guard, and the next go relaunches it
  --    manifest-attached — from then on every guard answers the sortie reject FOREVER, the fleet
  --    never goes terminal, and it permanently eats a max_active_fleets slot. It BRICKS THE GROUP.
  --    A hunt is a commitment of a frozen roster: the player aborts it with the existing Retreat
  --    button (request_retreat, 0019/0169) or the forced auto-extract at max_presence_seconds —
  --    rejecting here removes ZERO capability.
  --    LIVE-scoped join, NEVER a bare EXISTS: a finished sortie's manifest is RETAINED up to 14d
  --    (0047/0169's retention decision), and a retained dead manifest must not block stopping a
  --    NEW go. REJECT, not idempotent-skip: an open sortie is "refuse", not "nothing to do".
  select count(*) into v_hunting
    from public.group_sortie_members gsm
    join public.fleets f on f.id = gsm.fleet_id
   where gsm.player_id = v_player
     and f.group_id = v_group
     and f.status in ('moving', 'present', 'returning');
  if v_hunting > 0 then
    return jsonb_build_object('ok', false, 'reason', 'group_on_sortie');
  end if;
  -- ── ★ END OF THE 0215 HUNK — the head continues verbatim from here ★ ──────────────────────────

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
  'Refuses an OPEN SORTIE (group_on_sortie, live-scoped manifest join) — abort a hunt via Retreat, never the brake. '
  'Writes NO per-ship movement state — the legacy stop_ship_group_transit (0164) loops the PER-SHIP stop; '
  'this replaces that composed model. DARK behind fleet_movement_unified_enabled.';

revoke all on function public.command_ship_group_stop(uuid) from public;
grant execute on function public.command_ship_group_stop(uuid) to authenticated;

-- ── self-assert (deploy-time, raises on failure — the 0213/0214 idiom) ───────────────────────────
do $brake$
declare
  v_src text;
  v_gate int; v_lock int; v_gsm int; v_sort int; v_amb int; v_mvlock int; v_cancel int;
begin
  -- (a) single definition, authenticated-executable.
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'command_ship_group_stop') <> 1 then
    raise exception 'BRAKE-SORTIE self-assert FAIL: command_ship_group_stop is not a single definition'; end if;
  select prosrc into v_src from pg_proc where oid = 'public.command_ship_group_stop(uuid)'::regprocedure;
  if not has_function_privilege('authenticated', 'public.command_ship_group_stop(uuid)', 'execute') then
    raise exception 'BRAKE-SORTIE self-assert FAIL: command_ship_group_stop not authenticated-executable'; end if;

  -- (b) the 0209 head survives (parity is RETENTION of the head; the hunk is an ADDITION to it):
  --     the group-shaped resolve, the parking leaf, the interpolation pair, and the four head tokens.
  if position('main_ship_id is null' in v_src) = 0
     or position('status in (''idle'', ''moving'', ''present'', ''returning'')' in v_src) = 0
     or position('fleet_set_in_space' in v_src) = 0
     or position('v_x := v_mv.origin_x + (v_mv.target_x - v_mv.origin_x) * v_t' in v_src) = 0
     or position('v_y := v_mv.origin_y + (v_mv.target_y - v_mv.origin_y) * v_t' in v_src) = 0
     or position('not_moving' in v_src) = 0
     or position('already_settled' in v_src) = 0
     or position('fleet_ambiguous' in v_src) = 0
     or position('no_fleet' in v_src) = 0 then
    raise exception 'BRAKE-SORTIE self-assert FAIL: the 0209 head did not survive (resolve shape / parking leaf / interpolation pair / a head token)'; end if;

  -- (c) the hunk exists: the gsm join, LIVE-scoped, + the reject token. A bare EXISTS (or a lost
  --     status filter) fails the third string — the mutation that bricks every post-hunt stop.
  if position('join public.fleets f on f.id = gsm.fleet_id' in v_src) = 0
     or position('group_on_sortie' in v_src) = 0
     or position('f.status in (''moving'', ''present'', ''returning'')' in v_src) = 0 then
    raise exception 'BRAKE-SORTIE self-assert FAIL: the sortie-guard hunk is missing or lost its LIVE scope'; end if;

  -- (d) ORDER: gate < group lock < the sortie guard < the fleet count < the movement lock < the
  --     cancel write. A guard after the count would answer ambiguous/no_fleet past a live sortie;
  --     a guard before the gate would leak a sortie read while dark (DARKINERT reds too).
  v_gate   := position('cfg_bool(''fleet_movement_unified_enabled'')' in v_src);
  v_lock   := position('from public.ship_groups where group_id = v_group and player_id = v_player for update' in v_src);
  v_gsm    := position('join public.fleets f on f.id = gsm.fleet_id' in v_src);
  v_sort   := position('group_on_sortie' in v_src);
  v_amb    := position('fleet_ambiguous' in v_src);
  v_mvlock := position('where id = v_fleet_row.active_movement_id' in v_src);
  v_cancel := position('set status = ''cancelled''' in v_src);
  if not (v_gate > 0 and v_gate < v_lock and v_lock < v_gsm and v_gsm < v_sort
          and v_sort < v_amb and v_amb < v_mvlock and v_mvlock < v_cancel) then
    raise exception 'BRAKE-SORTIE self-assert FAIL: order broken (gate=%, lock=%, gsm=%, sortie=%, count=%, mvlock=%, cancel=%)',
      v_gate, v_lock, v_gsm, v_sort, v_amb, v_mvlock, v_cancel; end if;
end $brake$;
