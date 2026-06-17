-- Byeharu — Phase 8: calculate_expedition_stats() — the deterministic stat ADAPTER.
--
-- This is the bridge between the new main-ship model (Phase 7) + support craft metadata
-- (Phase 6) and the proven Expedition Engine. It will EVENTUALLY be the single source of
-- expedition stats (main ship + support craft + later captains + modules + activity).
--
-- LAW: replace the SOURCE of stats later, not the engine now. Phase 8 only ADDS this
-- function and verifies it in isolation. It is **read/compute only** — it never creates
-- expeditions, moves fleets, starts combat, deposits rewards, spends inventory, or mutates
-- the main ship / support craft / rankings / reports. Live combat still uses the old
-- verified fleet-stack path; integration is Phase 9/10+.
--
-- ANTI-STACKING: support craft are capacity-limited. The ship's finite `support_capacity`
-- is a HARD cap (over-capacity loadouts are rejected) — that is the mechanism that prevents
-- "bring infinite craft for infinite stats". Within the cap, contributions are deterministic.
--
-- OWNERSHIP NOTE: support-craft OWNERSHIP/consumption is NOT implemented yet (no owned-count
-- store). Phase 8 validates loadout **type + quantity + capacity + math** against
-- support_craft_types only. Ownership enforcement arrives when loadouts are actually attached
-- to expeditions (later phase).

create or replace function public.calculate_expedition_stats(
  p_player        uuid,
  p_main_ship_id  uuid,
  p_loadout       jsonb default '[]'::jsonb,
  p_activity_type text default 'pirate_hunt')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_ship   public.main_ship_instances%rowtype;
  v_speed  numeric;
  r        record;
  v_used   integer := 0;
  -- accumulated support contributions
  a_combat    numeric := 0;
  a_survival  numeric := 0;
  a_repair    numeric := 0;
  a_cargo     numeric := 0;
  a_scout     numeric := 0;
  a_mining    numeric := 0;
  a_retreat   numeric := 0;
  a_attention numeric := 0;
  a_spd_pen   numeric := 0;
  v_warnings  jsonb := '[]'::jsonb;
  v_final_speed numeric;
begin
  -- (0) Activity must be a known type (no activity logic runs here — just validation).
  if coalesce(p_activity_type, '') not in ('pirate_hunt','trade_run','exploration','mining','none') then
    raise exception 'calculate_expedition_stats: unknown activity_type %', p_activity_type;
  end if;

  -- (1)(2) Read the player's main ship (must exist AND be owned by p_player).
  select * into v_ship from main_ship_instances
    where main_ship_id = p_main_ship_id and player_id = p_player;
  if not found then
    raise exception 'calculate_expedition_stats: main ship % not found for player %', p_main_ship_id, p_player;
  end if;
  select base_speed into v_speed from main_ship_hull_types where hull_type_id = v_ship.hull_type_id;
  v_speed := coalesce(v_speed, 1);

  -- (3)(4)(5)(6)(8) Normalize + validate the loadout, accumulate capacity + effects.
  -- Duplicates are COMBINED (summed) deterministically. Invalid entries are REJECTED.
  for r in
    with norm as (
      select trim(el->>'support_craft_type_id')      as type_id,
             (el->>'quantity')::numeric               as qty
      from jsonb_array_elements(coalesce(p_loadout, '[]'::jsonb)) el
    ),
    agg as (
      select type_id, sum(qty) as qty
      from norm
      group by type_id
    )
    select a.type_id, a.qty,
           s.capacity_cost, s.role, s.activity_tags, s.base_stats_json
    from agg a
    left join support_craft_types s on s.support_craft_type_id = a.type_id
  loop
    -- (5) quantity must be a positive integer (rejects 0, negatives, NaN/Inf, fractions).
    if r.qty is null or r.qty <> floor(r.qty) or r.qty <= 0 or r.qty >= 1e9 then
      raise exception 'calculate_expedition_stats: invalid quantity % for %', r.qty, coalesce(r.type_id, '(null)');
    end if;
    -- (4) every support craft type must exist.
    if r.capacity_cost is null then
      raise exception 'calculate_expedition_stats: unknown support craft type %', coalesce(r.type_id, '(null)');
    end if;

    v_used := v_used + (r.capacity_cost * r.qty)::integer;

    -- (8) controlled effects: physical stats from base_stats_json; pirate_attention +
    --     speed penalty from role rules. Conservative, linear within the capacity cap.
    a_combat    := a_combat    + coalesce((r.base_stats_json->>'attack')::numeric, 0)  * r.qty;
    a_survival  := a_survival  + coalesce((r.base_stats_json->>'defense')::numeric, 0) * r.qty;
    a_repair    := a_repair    + coalesce((r.base_stats_json->>'repair')::numeric, 0)  * r.qty;
    a_cargo     := a_cargo     + coalesce((r.base_stats_json->>'cargo')::numeric, 0)   * r.qty;
    a_scout     := a_scout     + coalesce((r.base_stats_json->>'scan')::numeric, 0)    * r.qty;
    a_mining    := a_mining    + coalesce((r.base_stats_json->>'mining')::numeric, 0)  * r.qty;
    a_retreat   := a_retreat   + coalesce((r.base_stats_json->>'evasion')::numeric, 0) * r.qty;
    a_attention := a_attention + (case r.role when 'combat_damage' then 2 when 'cargo' then 2 when 'heavy_cargo' then 4 else 0 end) * r.qty;
    a_spd_pen   := a_spd_pen   + (case r.role when 'combat_damage' then 0.05 when 'heavy_cargo' then 0.08 when 'extraction' then 0.02 else 0 end) * r.qty;

    -- non-fatal warning if this craft isn't typically useful for the chosen activity.
    if p_activity_type <> 'none' and not (coalesce(r.activity_tags, '[]'::jsonb) ? p_activity_type) then
      v_warnings := v_warnings || to_jsonb(format('%s is not typically useful for %s', r.type_id, p_activity_type));
    end if;
  end loop;

  -- (7) capacity is a HARD cap — reject over-capacity loadouts.
  if v_used > v_ship.support_capacity then
    raise exception 'calculate_expedition_stats: loadout uses % support capacity, ship limit is %', v_used, v_ship.support_capacity;
  end if;

  -- final speed = hull base speed reduced by penalties, floored so it never goes <= 0.
  v_final_speed := round(greatest(0.2, v_speed * (1 - a_spd_pen)), 3);

  -- (9)(10)(11) Build the normalized stat object. Every field is coalesced + clamped to
  -- >= 0 and rounded → never NaN, never negative, deterministic for the same input.
  return jsonb_build_object(
    'main_ship_id',           v_ship.main_ship_id,
    'activity_type',          p_activity_type,
    'support_capacity_used',  v_used,
    'support_capacity_limit', v_ship.support_capacity,
    'speed',            v_final_speed,
    'cargo_capacity',   greatest(0, v_ship.cargo_capacity + round(a_cargo)::integer),
    'combat_power',     greatest(0, round(a_combat, 2)),
    'survival',         greatest(0, round(a_survival, 2)),
    'retreat_safety',   greatest(0, round(a_retreat, 2)),
    'scouting',         greatest(0, round(a_scout, 2)),
    'mining_yield',     greatest(0, round(a_mining, 2)),
    'repair',           greatest(0, round(a_repair, 2)),
    'pirate_attention', greatest(0, round(a_attention, 2)),
    'warnings',         v_warnings
  );
end;
$$;

-- ── Re-lock execute surface (anti-cheat). New function default-grants to PUBLIC on
--    create → revoke; re-grant only the client RPCs. calculate_expedition_stats is
--    read/compute only but stays server-only for now (no UI yet); a client preview RPC
--    (auth.uid()-scoped) will be added with the Phase 9 UI. Prior service_role grants are
--    untouched by a public/anon/authenticated revoke.
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
grant execute on function public.get_world_map()                           to anon, authenticated;
grant execute on function public.bootstrap_me()                            to authenticated;
grant execute on function public.send_fleet_to_location(uuid, uuid, jsonb) to authenticated;
grant execute on function public.request_leave_location(uuid)              to authenticated;
grant execute on function public.request_retreat(uuid)                     to authenticated;
grant execute on function public.get_combat_reports()                      to authenticated;
grant execute on function public.train_units(uuid, text, integer)          to authenticated;
grant execute on function public.cancel_build_order(uuid)                  to authenticated;
-- Server / CI only (service_role); NEVER clients:
grant execute on function public.calculate_expedition_stats(uuid, uuid, jsonb, text) to service_role;
