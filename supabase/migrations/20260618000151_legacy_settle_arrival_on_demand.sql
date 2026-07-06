-- Byeharu — PERFORMANCE (UX-CLEANUP item 6, part B): on-demand LEGACY main-ship arrival settlement.
--
-- Problem: a legacy fleet_movements arrival (the MainShipCommand first-trip path — home→port /
-- home→waypoint, and every return leg) waits up to ~30s for the process-fleet-movements cron (0011) plus a
-- 3–4s client poll. For a brand-new player the very FIRST arrival in the game feels slow.
--
-- Design (per the movement diagnosis; the OSN part-A pattern applied to the legacy family):
--   1. EXTRACT the cron's per-movement settle body into ONE shared helper `movement_settle_arrival` — the
--      cron and the new RPC both call it; no second settlement copy exists anywhere.
--   2. Re-create `process_fleet_movements()` so its loop body is exactly `perform movement_settle_arrival(id)`.
--      BYTE-EQUIVALENT behavior: the scan (`status='moving' and arrive_at<=now()` FOR UPDATE SKIP LOCKED,
--      0096) is unchanged; the helper re-reads the already-locked row (an inner FOR UPDATE on a lock the
--      caller holds is a no-op) and performs the IDENTICAL writes in the IDENTICAL order — including the
--      combat-adjacent parts: `presence_create(..., activity)` still routes hunt arrivals into Combat via
--      activity_start (0018), and the reward deposit still runs under the movement's activity-agnostic
--      `reward_source_type` (0096). Nothing in the combat/reward path changes.
--   3. NEW authenticated RPC `command_main_ship_settle_arrival_legacy(p_fleet default null)` settles the
--      CALLER'S own due main-ship movement immediately via that same helper.
--
-- GATED ON THE EXISTING HUMAN GATE: cfg 'mainship_send_enabled' (0050:73 / 0053:34 — the flag every visible
-- legacy main-ship send checks). No new flag, no flip; dark envs reject feature_disabled. NOT applied here.
--
-- NON-COMBAT SCOPING (defense-in-depth): the RPC refuses any location target whose activity_type <> 'none'
-- (combat_target_unsupported) BEFORE settling, so the on-demand path can never drive combat init. This is
-- structurally unreachable for main-ship fleets anyway — send_main_ship_expedition (0050:104) and
-- move_main_ship_to_location (0053:71) hard-reject non-'none' targets — but the refusal makes the scope a
-- property of THIS function, not of its callers. return_home (target_type='base') is always non-combat;
-- main-ship fleets carry no units and no reward payload ('{}' — 0030/0096 deposit branch requires a
-- non-empty payload + source), so no reward/spend path is re-entered.
--
-- IDEMPOTENT / RACE-SAFE BY STATE (no receipts — settling grants nothing new):
--   • The RPC claims the movement row FOR UPDATE SKIP LOCKED — the cron's OWN lock order (movement row
--     first, fleets updated after; 0096 scan) ⇒ no deadlock in either direction, and a row the cron holds
--     is skipped → {ok:true, settled:false, reason:'busy'} (the cron wins; never blocks/waits).
--   • The helper's re-read is guarded `status='moving' and arrive_at<=now()` under the row lock, so a
--     cron-vs-RPC race settles exactly once — the loser observes not-moving and no-ops as
--     'already_settled'. Not-due / no-movement calls are safe no-ops. No double-settle, no double-move.
--
-- BOUNDARIES: Movement stays the SOLE writer of fleet_movements — the helper is Movement-owned (extracted
-- from Movement's own cron), and the RPC writes nothing itself (all writes happen inside the helper's
-- existing calls: fleet_set_present / presence_create / base_merge_units / fleet_complete / reward_grant).
-- No new table; call graph unchanged/acyclic.

-- ── 1. THE extracted per-movement settle (verbatim 0096 loop body; internal) ─────────────────────────────
create or replace function public.movement_settle_arrival(p_movement uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  m       fleet_movements%rowtype;
  v_loc   record;
  v_units jsonb;
begin
  -- Guarded locked re-read: still moving AND due. For the cron this is a no-op re-take of a lock it
  -- already holds on a row it already proved due (now() is constant within the txn) — byte-equivalent.
  -- For the on-demand RPC it is the authoritative claim.
  select * into m from fleet_movements
    where id = p_movement and status = 'moving' and arrive_at <= now()
    for update;
  if not found then
    return jsonb_build_object('settled', false, 'reason', 'not_settleable');
  end if;

  if m.target_type = 'location' then
    select l.activity_type as activity, l.zone_id as zone_id, z.sector_id as sector_id
      into v_loc from locations l join zones z on z.id = l.zone_id where l.id = m.target_location_id;
    update fleet_movements set status = 'arrived', resolved_at = now() where id = m.id;
    perform fleet_set_present(m.fleet_id, v_loc.sector_id, v_loc.zone_id, m.target_location_id);
    perform presence_create(m.player_id, m.fleet_id, v_loc.sector_id, v_loc.zone_id, m.target_location_id, v_loc.activity);
    return jsonb_build_object('settled', true, 'outcome', 'present', 'movement_id', m.id);

  elsif m.target_type = 'base' then
    select jsonb_agg(jsonb_build_object('unit_type_id', unit_type_id, 'quantity', quantity))
      into v_units from fleet_units where fleet_id = m.fleet_id and quantity > 0;
    update fleet_movements set status = 'arrived', resolved_at = now() where id = m.id;
    if v_units is not null then
      perform base_merge_units(m.target_base_id, v_units);
    end if;
    perform fleet_complete(m.fleet_id);
    -- Deposit carried rewards now that the fleet is safely home (idempotent via
    -- reward_grants unique source), under the movement's activity source type.
    if m.reward_payload_json is not null and m.reward_payload_json <> '{}'::jsonb and m.reward_grant_source is not null then
      perform reward_grant(m.reward_source_type, m.reward_grant_source, m.player_id, m.target_base_id, m.reward_payload_json);
    end if;
    return jsonb_build_object('settled', true, 'outcome', 'completed', 'movement_id', m.id);

  else
    update fleet_movements set status = 'failed', resolved_at = now() where id = m.id;
    return jsonb_build_object('settled', true, 'outcome', 'failed', 'movement_id', m.id);
  end if;
end;
$$;

-- Internal (0093/0096 idiom): cron + SECURITY DEFINER orchestrators invoke it as owner; no client path.
revoke execute on function public.movement_settle_arrival(uuid) from public, anon, authenticated;

-- ── 2. process_fleet_movements — IDENTICAL scan; the loop body now IS the shared helper ──────────────────
create or replace function public.process_fleet_movements()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  m       record;
  v_count integer := 0;
begin
  for m in
    select * from fleet_movements
    where status = 'moving' and arrive_at <= now()
    for update skip locked
  loop
    perform movement_settle_arrival(m.id);
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke execute on function public.process_fleet_movements() from public, anon, authenticated;

-- ── 3. The on-demand caller: settle MY due main-ship legacy arrival now ──────────────────────────────────
create or replace function public.command_main_ship_settle_arrival_legacy(p_fleet uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_fleet  fleets%rowtype;
  v_n      integer;
  m        fleet_movements%rowtype;
  v_act    text;
  v_res    jsonb;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- The EXISTING legacy-send human gate (0050/0053).
  if not cfg_bool('mainship_send_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'feature_disabled');
  end if;

  -- Resolve the fleet: explicit id (owned) or the sole in-flight main-ship fleet (the 0081 resolver's
  -- fail-closed shape — ambiguity forces explicit selection).
  if p_fleet is not null then
    select * into v_fleet from fleets where id = p_fleet and player_id = v_player;
    if v_fleet.id is null then
      return jsonb_build_object('ok', false, 'reason', 'fleet_not_found');
    end if;
  else
    select count(*) into v_n from fleets
      where player_id = v_player and main_ship_id is not null and status in ('moving', 'returning');
    if v_n = 0 then
      return jsonb_build_object('ok', true, 'settled', false, 'reason', 'no_active_movement');
    elsif v_n > 1 then
      return jsonb_build_object('ok', false, 'reason', 'ambiguous_fleet');
    end if;
    select * into v_fleet from fleets
      where player_id = v_player and main_ship_id is not null and status in ('moving', 'returning');
  end if;
  -- Main-ship fleets only (the request_main_ship_return predicate, 0050:185-187).
  if v_fleet.main_ship_id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_main_ship_fleet');
  end if;

  -- Claim the active movement the cron's OWN way: row lock, SKIP LOCKED (contention → the cron wins).
  select * into m from fleet_movements
    where fleet_id = v_fleet.id and status = 'moving'
    for update skip locked;
  if m.id is null then
    if exists (select 1 from fleet_movements where fleet_id = v_fleet.id and status = 'moving') then
      return jsonb_build_object('ok', true, 'settled', false, 'reason', 'busy');
    end if;
    -- No moving row: a settled fleet reads as already_settled (the raced case); anything else is idle.
    if v_fleet.status in ('present', 'completed') then
      return jsonb_build_object('ok', true, 'settled', false, 'reason', 'already_settled');
    end if;
    return jsonb_build_object('ok', true, 'settled', false, 'reason', 'no_active_movement');
  end if;

  if m.arrive_at > now() then
    return jsonb_build_object('ok', true, 'settled', false, 'reason', 'not_due', 'arrive_at', m.arrive_at);
  end if;

  -- NON-COMBAT SCOPING: never drive combat init from the on-demand path (structurally unreachable for a
  -- main-ship fleet — 0050:104/0053:71 — but enforced HERE regardless).
  if m.target_type = 'location' then
    select activity_type into v_act from locations where id = m.target_location_id;
    if v_act is distinct from 'none' then
      return jsonb_build_object('ok', false, 'reason', 'combat_target_unsupported');
    end if;
  elsif m.target_type <> 'base' then
    return jsonb_build_object('ok', false, 'reason', 'unsupported_target');
  end if;

  -- Settle via the cron's OWN helper (the extraction above) — no copied settlement body, ever.
  v_res := public.movement_settle_arrival(m.id);
  if (v_res->>'settled')::boolean is true then
    return jsonb_build_object('ok', true, 'settled', true,
      'outcome', v_res->>'outcome', 'movement_id', m.id);
  end if;
  return jsonb_build_object('ok', true, 'settled', false, 'reason', 'already_settled');
end;
$$;

revoke execute on function public.command_main_ship_settle_arrival_legacy(uuid) from public, anon;
grant  execute on function public.command_main_ship_settle_arrival_legacy(uuid) to authenticated;
