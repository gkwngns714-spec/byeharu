-- Byeharu — PERFORMANCE (UX-CLEANUP item 6, part A): on-demand OSN arrival settlement.
--
-- Problem: a due OSN movement (main_ship_space_movements) waits up to ~30s for the
-- process-mainship-space-arrivals cron (0058:129, cadence unchanged since) plus a 3–4s client poll before
-- the player sees the ship settle — the ship visibly floats "arrived but not settled".
--
-- Fix: ONE new authenticated RPC the client calls the moment the caller's own movement is due. It settles
-- THAT player's movement immediately by invoking the EXACT per-movement primitives the cron already uses —
-- ZERO settlement logic is duplicated:
--   • target_kind='location' → mainship_space_dock_at_location(ship, movement)   (0061; current body 0067 §E1)
--   • every other kind       → mainship_space_settle_space_arrival(ship, mv, t)  (0064 §A)
-- The cron (0064 §B) keeps running unchanged at 30s as the backstop; its candidate scan simply finds
-- nothing when the on-demand call settled first.
--
-- GATED ON THE EXISTING HUMAN GATE: cfg 'mainship_space_movement_enabled' — the SAME flag every OSN
-- movement command checks (0067 core / 0083:127). No new flag, no flip: dark environments reject with
-- feature_disabled; the human's already-enabled live environment gets it. NOT applied to any DB here.
--
-- IDEMPOTENT / RACE-SAFE BY STATE (no receipts — settling grants nothing new; it only advances an
-- inevitable transition):
--   • The ship is claimed via the SAME lock context the cron uses, SKIP-LOCKED
--     (mainship_space_lock_context(ship, true) — 0056:37-44 / 0064:120): on contention the cron (or a stop)
--     wins and this returns {ok:true, settled:false, reason:'busy'} — it never blocks or waits.
--   • It then mirrors the cron's own claim sequence verbatim (0064:126-160): coherent 'in_transit'
--     validate_context → cross-domain exclusion → re-read the movement UNDER LOCK still
--     status='moving' AND due → full fleet/movement linkage check (frozen-failure: any mismatch touches
--     nothing). The primitives themselves guard every write with `… and status='moving'` (0061/0064), so
--     if the cron settled first this call observes not-moving and no-ops as 'already_settled'. No
--     double-settle, double-dock, or double-move is possible.
--   • No reward/spend path exists to re-enter: OSN settlement writes only movement/fleet/ship/presence
--     state — the primitives touch no reward, inventory, or resource table (rewards ride LEGACY
--     fleet_movements only; OSN Dock-0/in-space arrival carries no bundle).
--
-- BOUNDARIES: same Movement/OSN system that owns main_ship_space_movements — no new writer (all writes go
-- through the two existing primitives), no new table, call graph unchanged/acyclic.
--
-- Result envelope (client maps it fail-closed):
--   {ok:false, reason:'not_authenticated'|'feature_disabled'|'no_ship'|'incoherent_state'|…}
--   {ok:true, settled:false, reason:'busy'|'not_due'|'no_active_movement'|'already_settled', …}
--   {ok:true, settled:true, outcome:'docked'|'terminal'|'arrived', movement_id, …}
--   ('terminal' = the Dock-0 deterministic terminal failure — still a settlement, per 0067 §E1.)

create or replace function public.command_main_ship_settle_arrival(p_main_ship_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_ship   uuid;
  v_lock   jsonb;
  v_val    jsonb;
  v_state  text;
  v_excl   jsonb;
  v_mv     main_ship_space_movements%rowtype;
  v_fleet  fleets%rowtype;
  v_now    timestamptz;
  v_res    jsonb;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- The EXISTING OSN movement gate (no new flag; dark envs reject before any read).
  if not public.cfg_bool('mainship_space_movement_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'feature_disabled');
  end if;

  -- Ownership resolution incl. the sole-ship shim — the same resolver every §2.5 command uses (0081).
  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then
    return jsonb_build_object('ok', false, 'reason', 'no_ship');
  end if;

  -- Claim the ship SKIP-LOCKED in the canonical order (ship → fleet → movement → presence), exactly like
  -- the cron (0064:120). Contention means the cron/another command is settling — it wins; never wait.
  v_lock := public.mainship_space_lock_context(v_ship, true);
  if (v_lock->>'status') = 'skipped' then
    return jsonb_build_object('ok', true, 'settled', false, 'reason', 'busy');
  end if;
  if (v_lock->>'status') is distinct from 'locked' then
    return jsonb_build_object('ok', false, 'reason', 'no_ship');
  end if;

  -- Coherent-state validation under the locks (the cron's step 4, 0064:126-131).
  v_val := public.mainship_space_validate_context(v_ship);
  if (v_val->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_val->>'reason', 'contradictory_state'));
  end if;
  v_state := v_val->>'state';
  if v_state is distinct from 'in_transit' then
    -- Nothing in flight. A just-settled ship (the cron won a race) reads as already_settled so the
    -- client's due-trigger treats it as success; anything else is simply no active movement.
    if v_state in ('in_space', 'at_location') then
      return jsonb_build_object('ok', true, 'settled', false, 'reason', 'already_settled', 'state', v_state);
    end if;
    return jsonb_build_object('ok', true, 'settled', false, 'reason', 'no_active_movement', 'state', v_state);
  end if;

  -- Cross-domain exclusion (the cron's step 5, 0064:134-139). Frozen-failure: touch nothing on mismatch.
  v_excl := public.mainship_space_assert_cross_domain_exclusion(v_ship);
  if (v_excl->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_excl->>'reason', 'incoherent_state'));
  end if;

  -- Re-read the movement UNDER the held locks (the cron's step 6, 0064:142-160).
  select * into v_mv from main_ship_space_movements
    where main_ship_id = v_ship and status = 'moving';
  if not found then
    return jsonb_build_object('ok', true, 'settled', false, 'reason', 'already_settled');
  end if;
  if v_mv.arrive_at > now() then
    return jsonb_build_object('ok', true, 'settled', false, 'reason', 'not_due', 'arrive_at', v_mv.arrive_at);
  end if;
  select * into v_fleet from fleets where id = v_mv.fleet_id;
  if not found
     or v_fleet.main_ship_id is distinct from v_ship
     or v_fleet.status <> 'moving'
     or v_fleet.location_mode <> 'movement'
     or v_fleet.active_space_movement_id is distinct from v_mv.id
     or v_fleet.active_movement_id is not null
     or v_mv.player_id is distinct from v_fleet.player_id then
    return jsonb_build_object('ok', false, 'reason', 'incoherent_state');
  end if;

  -- Settle via the cron's OWN primitives (0064:162-170) — no copied settlement body, ever.
  if v_mv.target_kind = 'location' then
    v_res := public.mainship_space_dock_at_location(v_ship, v_mv.id);
    if (v_res->>'ok')::boolean is not true then
      -- Raced settlement inside the primitive (its own status='moving' guard) — clean no-op.
      return jsonb_build_object('ok', true, 'settled', false, 'reason', 'already_settled');
    end if;
    return jsonb_build_object(
      'ok', true, 'settled', true,
      'outcome', case when (v_res->>'docked')::boolean then 'docked' else 'terminal' end,
      'movement_id', v_mv.id, 'location_id', v_res->'location_id', 'resolved_at', v_res->'resolved_at');
  else
    v_now := clock_timestamp();
    v_res := public.mainship_space_settle_space_arrival(v_ship, v_mv.id, v_now);
    if (v_res->>'ok')::boolean is not true then
      return jsonb_build_object('ok', true, 'settled', false, 'reason', 'already_settled');
    end if;
    return jsonb_build_object(
      'ok', true, 'settled', true, 'outcome', 'arrived',
      'movement_id', v_mv.id, 'resolved_at', to_jsonb(v_now));
  end if;
end;
$$;

revoke execute on function public.command_main_ship_settle_arrival(uuid) from public, anon;
grant  execute on function public.command_main_ship_settle_arrival(uuid) to authenticated;
