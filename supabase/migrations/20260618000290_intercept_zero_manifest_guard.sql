-- 0290 — ZERO-MANIFEST AMBUSH: an intercept that can field no ships must not open combat.
--
-- THE DEFECT, observed in production. An encounter exists carrying THREE combat_units rows with
-- main_ship_id NULL, unit_type_id NOT NULL, alive_count 0, no positions, no weapons — a fight with
-- nothing in it. Nothing to draw on the map, nothing to shoot, player_power_start = 0.
--
-- THE CHAIN.
--   1. pirate_intercept_evaluate_leg (0276) freezes the sortie manifest from LIVE data:
--        insert into group_sortie_members select ... from main_ship_instances where group_id = v_group
--      That select can legitimately return ZERO rows — an empty or disbanded group, or every ship
--      reassigned since the leg was ordered.
--   2. It then calls presence_create(...'hunt_pirates') unconditionally, which chains
--      activity_start -> combat_create_encounter.
--   3. combat_create_encounter (0168:501) is MANIFEST-GATED: `if exists (group_sortie_members ...)`.
--      With no manifest it falls through to the legacy branch at 0168:517, which inserts combat_units
--      from fleet_units — a table a TEAM-SORTIE fleet has no rows in (0168:276 creates the fleet and
--      never populates it; 0169:222 documents "a team sortie that carries no fleet_units").
--   4. Zero rows inserted. The encounter opens empty and stays empty: nothing ever deletes a player
--      row (the only deletes are `and side = 'enemy'`), and fleet_get_power sums the same empty table.
--
-- WHY THE OLD SAFETY NET STOPPED WORKING. 0168:478-480 states that legacy branch is "UNREACHABLE IN
-- PROD" because send_ship_group_hunt is the manifest's SOLE writer. That was true when written. It
-- expired the moment 0233/0276's intercept became a SECOND manifest writer — and unlike the hunt,
-- which freezes a roster it has just validated, the intercept freezes whatever the group happens to
-- contain at ambush time. The stale claim is the bug; the legacy branch merely executed it.
--
-- THE FIX — in the ONE function whose invariant broke. Capture the manifest insert's row_count and,
-- when it is zero, take the fail-open exit this function ALREADY has for a vanished location
-- (0276:240-242): park the fleet at the ambush point it genuinely reached, tag the intercept log,
-- return without creating combat. An ambush that cannot field a single ship is not a fight.
--
-- Deliberately NOT done here: reopening combat_create_encounter to refuse zero-unit encounters. That
-- is a shared legacy path used by non-team arrivals too, and 0272/0276 both certify the downstream
-- creators as FROZEN and un-recreated. Hardening it is worth doing as its own slice, with its own
-- proof, not smuggled into an intercept fix.
--
-- Everything else is re-emitted BYTE-IDENTICAL to 0276: the typed-zone planner cutover, the risk
-- roll, the log row, the location_missing exit, the fleet_set_present + presence_create composition,
-- the raise-free `exception when others` contract (a planner failure leaves the leg UNINTERRUPTED),
-- and the grants (service_role only; never anon/authenticated).
--
-- No schema change, no flag change, no balance change. Forward-only; 0276 is not edited in place.


create or replace function public.pirate_intercept_evaluate_leg(p_movement_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mv       record;
  v_fleet    record;
  v_hit      record;
  v_group    uuid;
  v_manifest integer;   -- 0290: rows frozen into the sortie manifest; ZERO must not open combat
  v_stats    jsonb;
  v_combined double precision;
  v_risk     double precision;
  v_roll     double precision;
  v_hitbool  boolean;
  v_now      timestamptz := now();
  v_loc      record;
  v_presence uuid;
  v_enc      uuid;
  v_log_id   uuid;
  -- 0276 cutover locals. Only ever populated on the typed-zone branch.
  v_typed    boolean;
  v_req      jsonb;
  v_res      jsonb;
  v_pe       jsonb;
begin
  -- DARK GATE FIRST — before any read at all.
  if not public.cfg_bool('pirate_intercept_enabled') then
    return jsonb_build_object('hit', false, 'reason', 'dark');
  end if;

  select id, fleet_id, player_id, origin_x, origin_y, target_x, target_y, status
    into v_mv
    from public.fleet_movements
   where id = p_movement_id;
  if not found or v_mv.status <> 'moving' then
    return jsonb_build_object('hit', false, 'reason', 'not_moving');
  end if;

  select id, player_id, group_id, main_ship_id
    into v_fleet
    from public.fleets
   where id = v_mv.fleet_id;
  -- This hook only ever fires from the unified GROUP mover / route advance — the ONLY shapes that
  -- mint main_ship_id NULL + group_id SET fleets. Anything else (a legacy per-ship or unit fleet) is
  -- simply not this feature's concern for the prototype — skip cleanly, never guess.
  if not found or v_fleet.group_id is null or v_fleet.main_ship_id is not null then
    return jsonb_build_object('hit', false, 'reason', 'not_group_fleet');
  end if;
  v_group := v_fleet.group_id;

  -- ── 0276 CUTOVER POINT ──────────────────────────────────────────────
  -- Exactly ONE path decides, chosen once, here. The branches are never both run for side effects:
  -- whichever is authoritative produces v_hit, and everything downstream — the roll, the
  -- pirate_intercepts log, the cancel, the ambush — is shared and unchanged. With the flag dark
  -- (its seeded state) this is byte-for-byte the legacy 0233 decision.
  v_typed := coalesce(public.cfg_bool('typed_zone_pirate_intercept_runtime_enabled'), false);

  if not v_typed then
    -- LEGACY, authoritative while the flag is dark: deepest crossing wins (highest
    -- exposure_fraction); `limit 1` needs SOME order to be deterministic.
    select * into v_hit
      from public.pirate_intercept_leg_zone_hits(v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y)
     order by exposure_fraction desc, zone_id asc
     limit 1;
    if not found then
      return jsonb_build_object('hit', false, 'reason', 'no_crossing');
    end if;
  else
    -- TYPED-ZONE: the same geometry, but the decision comes from the pure V1 planner, so selection
    -- follows declared EFFECTS rather than the bare existence of a polygon. A zone carrying no
    -- pirate_intercept effect row is simply not planned — that is the point of the platform.
    v_req := public.typed_zone_pirate_candidates_v1(
               p_movement_id, v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y, 0);
    v_res := public.typed_zone_effect_dispatch_v1(v_req);
    -- FAIL CLOSED, NEVER FAIL OPEN. A planner that cannot answer must not silently fall back to the
    -- legacy path — that would make the cutover unobservable and hide the fault — and must not
    -- invent an interception. It leaves the leg alone, exactly as 'no_crossing' does.
    if (v_res->>'ok') <> 'true' then
      raise warning 'pirate_intercept_evaluate_leg: typed-zone dispatch rejected movement % (leg left UNINTERRUPTED): %',
        p_movement_id, v_res->'error';
      return jsonb_build_object('hit', false, 'reason', 'typed_zone_dispatch_error');
    end if;
    if jsonb_array_length(v_res->'plan'->'planned_effects') = 0 then
      return jsonb_build_object('hit', false, 'reason', 'no_crossing');
    end if;
    v_pe := v_res->'plan'->'planned_effects'->0;
    -- Re-read the geometry row for the PLANNED zone: location_id and the ambush point drive the
    -- shared downstream, and they must come from the same authority the legacy branch uses.
    select h.* into v_hit
      from public.pirate_intercept_leg_zone_hits(v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y) h
     where h.zone_id = (v_pe->>'zone_id')::uuid;
    if not found then
      raise warning 'pirate_intercept_evaluate_leg: planned zone % is not among the leg hits for movement % (leg left UNINTERRUPTED)',
        v_pe->>'zone_id', p_movement_id;
      return jsonb_build_object('hit', false, 'reason', 'typed_zone_dispatch_error');
    end if;
  end if;

  -- combined stats: reuse the SAME group-stats adapter the mover already calls for speed (D0, 0166).
  -- Fail OPEN on any adapter raise (an illegal member state etc.) — treat as unknown/weak (combined=0,
  -- the conservative choice) rather than let a stats bug break a player's movement command.
  begin
    v_stats := public.calculate_group_expedition_stats(v_fleet.player_id, v_group, 'none');
    v_combined := coalesce((v_stats->'totals'->>'combat_power')::double precision, 0)
                + coalesce((v_stats->'totals'->>'survival')::double precision, 0);
  exception when others then
    v_combined := 0;
  end;

  -- The typed branch resolves risk from THIS zone's own effect config (per-zone overrides coalesced
  -- against the globals). Recomputing with pirate_intercept_compute_risk here would read the globals
  -- only and silently re-globalise a zone the owner had deliberately tuned. The candidate request is
  -- rebuilt with the real combined stats — it was first built with 0, before the stats adapter ran.
  if v_typed then
    v_res := public.typed_zone_effect_dispatch_v1(
               jsonb_set(v_req, '{event,combined_stats}', to_jsonb(v_combined)));
    if (v_res->>'ok') <> 'true' or jsonb_array_length(v_res->'plan'->'planned_effects') = 0 then
      raise warning 'pirate_intercept_evaluate_leg: typed-zone re-plan failed for movement % (leg left UNINTERRUPTED)',
        p_movement_id;
      return jsonb_build_object('hit', false, 'reason', 'typed_zone_dispatch_error');
    end if;
    v_risk := (v_res->'plan'->'planned_effects'->0->>'risk')::double precision;
  else
    v_risk := public.pirate_intercept_compute_risk(v_combined, v_hit.exposure_fraction);
  end if;
  v_roll    := random();
  v_hitbool := v_roll < v_risk;

  insert into public.pirate_intercepts (
    movement_id, fleet_id, player_id, zone_id, location_id,
    origin_x, origin_y, target_x, target_y, exposure_fraction,
    combined_stats, risk, roll, hit)
  values (
    p_movement_id, v_fleet.id, v_fleet.player_id, v_hit.zone_id, v_hit.location_id,
    v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y, v_hit.exposure_fraction,
    v_combined, v_risk, v_roll, v_hitbool)
  returning id into v_log_id;

  if not v_hitbool then
    return jsonb_build_object('hit', false, 'risk', v_risk, 'roll', v_roll, 'zone_id', v_hit.zone_id);
  end if;

  -- ── THE AMBUSH ───────────────────────────────────────────────────────────────────────────────
  -- Re-lock + re-check: a concurrent brake/redirect may have resolved this movement between the
  -- first (unlocked) read above and here. Never double-trigger a settled/cancelled leg.
  perform 1 from public.fleet_movements where id = p_movement_id and status = 'moving' for update;
  if not found then
    update public.pirate_intercepts set hit = false, note = 'race_lost' where id = v_log_id;
    return jsonb_build_object('hit', false, 'reason', 'race_lost');
  end if;

  update public.fleet_movements set status = 'cancelled', resolved_at = v_now where id = p_movement_id;

  if v_hit.location_id is null then
    -- STANDALONE drawn zone (no linked pirate_hunt location): the documented combat stub. No
    -- location means no presence/encounter is possible without inventing one — instead the ambush
    -- is made TANGIBLE by forcing the fleet to a stop at the ambush point, the SAME leaf the brake
    -- (command_ship_group_stop, 0215/0218) uses to park a fleet mid-flight. Not a no-op.
    perform public.fleet_set_in_space(v_fleet.id, v_hit.ambush_x, v_hit.ambush_y);
    update public.pirate_intercepts set note = 'standalone_zone_stub_forced_stop' where id = v_log_id;
    return jsonb_build_object('hit', true, 'reason', 'standalone_zone_stub', 'risk', v_risk, 'roll', v_roll);
  end if;

  select l.id, l.zone_id, z.sector_id
    into v_loc
    from public.locations l
    join public.zones z on z.id = l.zone_id
   where l.id = v_hit.location_id and l.status = 'active';
  if v_loc.id is null then
    -- the linked location vanished/deactivated since the zone was drawn/seeded — fail open: park,
    -- no combat, rather than reference a location that can no longer host a presence.
    perform public.fleet_set_in_space(v_fleet.id, v_hit.ambush_x, v_hit.ambush_y);
    update public.pirate_intercepts set note = 'location_missing' where id = v_log_id;
    return jsonb_build_object('hit', true, 'reason', 'location_missing', 'risk', v_risk, 'roll', v_roll);
  end if;

  -- fleet_set_present demands status='moving' (0006) — true here: the mover just called
  -- fleet_set_moving and nothing since has changed the fleet's status.
  perform public.fleet_set_present(v_fleet.id, v_loc.sector_id, v_loc.zone_id, v_loc.id);

  -- Freeze the sortie MANIFEST — byte-identical INSERT shape to send_ship_group_hunt's sole-writer
  -- freeze (0168:304-306), so combat_create_encounter's manifest-gated branch (0168) routes this
  -- fleet into combat_create_group_encounter exactly as a deliberate hunt does. ON CONFLICT DO
  -- NOTHING: idempotent against a (should-be-impossible) re-entry.
  insert into public.group_sortie_members (fleet_id, main_ship_id, player_id)
  select v_fleet.id, msi.main_ship_id, v_fleet.player_id
    from public.main_ship_instances msi
   where msi.group_id = v_group and msi.player_id = v_fleet.player_id
  on conflict (fleet_id, main_ship_id) do nothing;
  get diagnostics v_manifest = row_count;

  -- 0290 ZERO-MANIFEST GUARD. The freeze above reads LIVE main_ship_instances.group_id, so it
  -- can legitimately return no rows (an empty/disbanded group, every ship reassigned). 0168's
  -- combat_create_encounter is manifest-GATED: with no manifest it takes the legacy branch and
  -- inserts combat_units from fleet_units -- a table a TEAM-SORTIE fleet has no rows in (0168:276
  -- creates the fleet and never populates it; 0169:222 documents exactly this). The result is an
  -- encounter with ZERO combat_units: nothing to draw on the map, nothing to fight, and
  -- player_power_start = 0 because fleet_get_power sums the same empty table.
  --
  -- 0168:478-480 asserts that branch is "UNREACHABLE IN PROD" because send_ship_group_hunt is
  -- the manifest's sole writer. That expired the moment THIS function became a second manifest
  -- writer. Rather than reopen the frozen legacy creator, refuse here: an ambush that cannot
  -- field a single ship is not a fight. Reuse the EXISTING fail-open exit (location_missing's
  -- shape) -- park the fleet at the ambush point it actually reached, log why, no combat.
  if v_manifest = 0 then
    perform public.fleet_set_in_space(v_fleet.id, v_hit.ambush_x, v_hit.ambush_y);
    update public.pirate_intercepts set note = 'empty_manifest' where id = v_log_id;
    return jsonb_build_object('hit', true, 'reason', 'empty_manifest', 'risk', v_risk, 'roll', v_roll);
  end if;

  -- presence_create -> activity_start('hunt_pirates') -> combat_create_encounter -> (manifest exists)
  -- -> combat_create_group_encounter. FOUR frozen functions composed, ZERO re-created.
  v_presence := public.presence_create(v_fleet.player_id, v_fleet.id, v_loc.sector_id, v_loc.zone_id, v_loc.id, 'hunt_pirates');

  select id into v_enc from public.combat_encounters where presence_id = v_presence order by created_at desc limit 1;
  update public.pirate_intercepts set encounter_id = v_enc, presence_id = v_presence where id = v_log_id;

  return jsonb_build_object(
    'hit', true, 'risk', v_risk, 'roll', v_roll,
    'location_id', v_loc.id, 'presence_id', v_presence, 'encounter_id', v_enc);
exception
  when others then
    raise warning 'pirate_intercept_evaluate_leg: unexpected error for movement % (leg left UNINTERRUPTED): %',
      p_movement_id, sqlerrm;
    return jsonb_build_object('hit', false, 'reason', 'internal_error');
end;
$$;


revoke execute on function public.pirate_intercept_evaluate_leg(uuid) from public, anon, authenticated;
grant execute on function public.pirate_intercept_evaluate_leg(uuid) to service_role;

comment on function public.pirate_intercept_evaluate_leg(uuid) is
  'PIRATE INTERCEPT (0233) + TYPED-ZONE CUTOVER (0276) + ZERO-MANIFEST GUARD (0290). While '
  'typed_zone_pirate_intercept_runtime_enabled is false this behaves byte-for-byte as 0233 shipped '
  'it. While true, zone SELECTION and RISK come from the pure V1 typed-zone planner. 0290: if the '
  'sortie manifest freezes ZERO rows the ambush parks the fleet at the ambush point and opens NO '
  'combat — a manifest-less fleet would otherwise route into 0168''s legacy creator and produce an '
  'encounter with no combat_units at all. Exactly one path decides; a planner failure leaves the leg '
  'UNINTERRUPTED rather than falling back.';

-- ── SELF-ASSERT ─────────────────────────────────────────────────────────────────────────────────────
do $$
declare v_src text;
begin
  if to_regprocedure('public.pirate_intercept_evaluate_leg(uuid)') is null then
    raise exception '0290: pirate_intercept_evaluate_leg(uuid) is missing after this migration';
  end if;
  select prosrc into v_src from pg_proc
   where oid = 'public.pirate_intercept_evaluate_leg(uuid)'::regprocedure;

  -- (1) THE FIX: the manifest row_count is captured AND gated on.
  if position('get diagnostics v_manifest = row_count' in v_src) = 0 then
    raise exception '0290: the manifest row_count is not captured';
  end if;
  if position('if v_manifest = 0 then' in v_src) = 0 then
    raise exception '0290: no zero-manifest guard';
  end if;
  if position('empty_manifest' in v_src) = 0 then
    raise exception '0290: the zero-manifest exit is not tagged on pirate_intercepts';
  end if;
  -- the guard must sit BEFORE presence_create, or combat opens anyway
  if position('if v_manifest = 0 then' in v_src) > position('public.presence_create(' in v_src) then
    raise exception '0290: the zero-manifest guard runs AFTER presence_create — combat would still open';
  end if;

  -- (2) everything the intercept already guaranteed is still here.
  if position('location_missing' in v_src) = 0 then
    raise exception '0290: the vanished-location fail-open exit was lost';
  end if;
  if position('fleet_set_present' in v_src) = 0 or position('presence_create' in v_src) = 0 then
    raise exception '0290: the ambush composition was lost';
  end if;
  -- raise-free contract: a failure must leave the leg uninterrupted, never propagate into the cron
  if position('when others then' in v_src) = 0 then
    raise exception '0290: the raise-free exception contract was lost';
  end if;

  -- (3) exposure unchanged: service_role only. A client must never drive an ambush.
  if not has_function_privilege('service_role', 'public.pirate_intercept_evaluate_leg(uuid)', 'execute') then
    raise exception '0290: service_role lost execute';
  end if;
  if has_function_privilege('anon', 'public.pirate_intercept_evaluate_leg(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_intercept_evaluate_leg(uuid)', 'execute') then
    raise exception '0290: a client role can execute the intercept leaf — exposure must not widen';
  end if;

  raise notice '0290 OK: a zero-row sortie manifest parks the fleet and opens NO combat; every 0276 guarantee intact';
end $$;

