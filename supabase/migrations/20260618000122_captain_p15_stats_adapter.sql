-- Byeharu — CAPTAIN-P15 SLICE F: the stats integration — assigned captains feed
-- calculate_expedition_stats via headcount-capacity/tradeoff (a `create or replace` re-create of
-- the 0115 adapter; the 0044/0115-style forward-only idiom. 0001–0121 unedited).
--
-- ROADMAP law 4 fulfilled for captains — the Phase-15 target itself (ROADMAP :90 "Captain
-- instances + assignment | effects via `calculate_expedition_stats`"): "replace the SOURCE of
-- expedition stats", and the source "enforces capacity + tradeoffs (never a plain sum)". The
-- support-craft loadout path AND the 0115 module path are preserved BYTE-IDENTICAL; the captain
-- feed is ADDED as a THIRD block between the module hard cap and the final speed/jsonb build.
-- The adapter stays read/compute-only, deterministic, and service_role-only.
--
-- THE COMPATIBILITY CONTRACT (what keeps verify:phase8 / verify:mainship-preview /
-- verify:fitting green — the 0115:10–18 contract restated for the third feed): a ship with NO
-- assigned captains returns the 0115 values for EVERY pre-existing key — the captain loop
-- contributes nothing, v_cap_speed_bonus = 0 makes the speed factor
-- (1 + v_mod_speed_bonus + 0) = 0115's (1 + v_mod_speed_bonus) exactly, and the only change is
-- the ADDITION of two keys (captain_slots_used / captain_slots_limit). The pinning scripts
-- assert specific field VALUES and list-membership finiteness (verify-phase8) or envelope/value
-- checks (verify-mainship-preview, verify-fitting's adapter probes) — none asserts an exact key
-- SET, so added keys are safe. And no assignment row can exist anywhere until the owner flips
-- the dark flag (captain_assignment_enabled='false' (0117); captain_assign_apply is
-- service_role-only behind the dark command (0119/0120/0121), and captain_instances itself has
-- no producer yet (0118)) — live behavior is unchanged today.
--
-- WHAT IS ADDED (and nothing else — mirroring 0115:157–196 point for point):
--   (1) DECLARES: c record; v_cap_used integer := 0; v_cap_speed_bonus numeric := 0;
--   (2) READ the ship's roster: ship_captain_assignments rows for v_ship.main_ship_id joined via
--       captain_instances to captain_types (specialization / stats_json — the 0117 catalog
--       columns' FIRST code consumer). A pure DOWNWARD read (Captain ← adapter), read-only. NO
--       player filter — the 0115:47–50 rationale verbatim: the (1)(2) ship read below already
--       proves v_ship belongs to p_player, and captain_assign_apply's owner-consistency
--       invariant (0119: row.player = captain owner = ship owner) guarantees every assignment on
--       that ship belongs to p_player.
--   (3) CONTRIBUTIONS flow into the SAME existing accumulators (a_combat/a_survival/a_repair/
--       a_cargo/a_scout/a_mining/a_retreat) from stats_json, exact key list
--       attack/defense/repair/cargo/scan/mining/evasion, coalesced to 0 — ONE stat pipeline, no
--       parallel captain pipeline; speed_mult_bonus sums into v_cap_speed_bonus.
--   (4) TRADEOFFS — the 0044 role-rule / 0115 slot_type idiom as a specialization CASE, one slot
--       each so NO cost scaling (a captain occupies exactly one slot — the 0117 locked headcount
--       decision). LOCKED VALUES (magnitudes mirror 0115's per-slot numbers; RATIONALE: a
--       captain draws attention like crewed hardware, support-role captains are the low-profile
--       option): combat → attention +2, spd_pen +0.02 · trade → attention +1, spd_pen +0.02 ·
--       exploration → attention +1 · mining → attention +1, spd_pen +0.02 · support → 0.
--       Unknown/future specializations contribute stats but no tradeoff (CASE else 0 — the same
--       permissive posture as 0044's unmatched roles / 0115's unknown slot_types; note the
--       0117 CHECK constrains the set today, so 'else' is pure forward-compatibility).
--   (5) HEADCOUNT HARD CAP — the 0044:112–115 / 0115:194–196 mechanism: v_cap_used >
--       v_ship.captain_slots → raise exception. DEFENSE-IN-DEPTH: assign-time enforcement in
--       captain_assign_apply (0119) is primary; the adapter must still REFUSE to compute stats
--       from an over-capacity state rather than clamp or trust it. count-based, never Σ cost —
--       one captain = one slot.
--   (6) SPEED — the captain bonus joins the module bonus ADDITIVELY inside the ONE multiplier:
--       v_final_speed := round(greatest(0.2, v_speed * (1 + v_mod_speed_bonus + v_cap_speed_bonus) * (1 - a_spd_pen)), 3)
--       (the existing 0.2 floor and 3-digit rounding untouched; zero captains reduces exactly to
--       the 0115 expression).
--   (7) OUTPUT — exactly two added keys, captain_slots_used / captain_slots_limit, mirroring the
--       module_slots_used/limit pair. NO existing key's value changes for a zero-captain ship.
--   · No activity-tag warning for captains: captain_types has no activity_tags column (0117) —
--     the warning loop remains support-craft-only by construction (the 0115 module stance).
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): §4 item 8 (the stat adapter) now
-- also reads ship_captain_assignments + captain_instances + captain_types (downward, read-only)
-- and hard-caps captain_slots alongside support_capacity and module_slots; its "(later
-- +captains)" note is redeemed. The §2 Captain row gains the inbound adapter-read edge (the 0115
-- Fitting precedent; nothing writes through Captain but its own command). Still acyclic; the
-- adapter owns no table and mutates nothing. No flag flipped.

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
  -- fitted modules (Phase 14, 0115)
  m                 record;
  v_mod_used        integer := 0;
  v_mod_speed_bonus numeric := 0;
  -- assigned captains (Phase 15, 0122)
  c                 record;
  v_cap_used        integer := 0;
  v_cap_speed_bonus numeric := 0;
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

  -- (M — Phase 14, 0115) FITTED MODULES feed the SAME accumulators, capacity-limited with
  -- tradeoffs (never a raw sum). Pure downward read of the ship's fit set; no player filter is
  -- needed — the (1)(2) read proved the ship is p_player's, and fitting_apply's owner-consistency
  -- invariant (0112) guarantees every fitting on an owned ship belongs to that owner. No
  -- activity-tag warning here: module_types has no activity_tags column (0107/0111).
  for m in
    select t.slot_cost, t.slot_type, t.stats_json
    from ship_module_fittings f
    join module_instances i on i.id = f.module_instance_id
    join module_types t     on t.id = i.module_type_id
    where f.main_ship_id = v_ship.main_ship_id
  loop
    v_mod_used := v_mod_used + m.slot_cost;

    -- contributions: the exact stats_json key list the loadout loop reads, coalesced to 0 —
    -- modules and support craft flow through ONE set of accumulators (no parallel pipeline).
    a_combat    := a_combat    + coalesce((m.stats_json->>'attack')::numeric, 0);
    a_survival  := a_survival  + coalesce((m.stats_json->>'defense')::numeric, 0);
    a_repair    := a_repair    + coalesce((m.stats_json->>'repair')::numeric, 0);
    a_cargo     := a_cargo     + coalesce((m.stats_json->>'cargo')::numeric, 0);
    a_scout     := a_scout     + coalesce((m.stats_json->>'scan')::numeric, 0);
    a_mining    := a_mining    + coalesce((m.stats_json->>'mining')::numeric, 0);
    a_retreat   := a_retreat   + coalesce((m.stats_json->>'evasion')::numeric, 0);
    v_mod_speed_bonus := v_mod_speed_bonus + coalesce((m.stats_json->>'speed_mult_bonus')::numeric, 0);

    -- tradeoffs: the 0044 role-rule idiom as a slot_type CASE scaled by slot_cost (the module
    -- analogue of ×qty). weapon/cargo mirror the combat_damage/cargo role tradeoffs (more
    -- firepower / a bigger hold draws pirates and slows the burn); sensors emit (attention only);
    -- the engine's cost is the slot itself. Unknown/future slot_types: stats yes, tradeoff 0 —
    -- the same permissive posture as unmatched roles above.
    a_attention := a_attention + (case m.slot_type when 'weapon' then 2 when 'cargo' then 2 when 'sensor' then 1 else 0 end) * m.slot_cost;
    a_spd_pen   := a_spd_pen   + (case m.slot_type when 'weapon' then 0.03 when 'cargo' then 0.04 else 0 end) * m.slot_cost;
  end loop;

  -- (M7) module slots are a HARD cap — the 0044:112–115 mechanism verbatim. DEFENSE-IN-DEPTH:
  -- fitting_apply (0112) enforces this at fit time and is the primary gate; the adapter still
  -- refuses to compute stats from an over-capacity state rather than clamp or trust it.
  if v_mod_used > v_ship.module_slots then
    raise exception 'calculate_expedition_stats: fitted modules use % module slots, ship limit is %', v_mod_used, v_ship.module_slots;
  end if;

  -- (C — Phase 15, 0122) ASSIGNED CAPTAINS feed the SAME accumulators, headcount-limited with
  -- tradeoffs (never a raw sum). Pure downward read of the ship's roster; no player filter is
  -- needed — the (1)(2) read proved the ship is p_player's, and captain_assign_apply's
  -- owner-consistency invariant (0119) guarantees every assignment on an owned ship belongs to
  -- that owner (the 0115:47–50 rationale). No activity-tag warning here: captain_types has no
  -- activity_tags column (0117).
  for c in
    select t.specialization, t.stats_json
    from ship_captain_assignments a
    join captain_instances i on i.id = a.captain_instance_id
    join captain_types t     on t.id = i.captain_type_id
    where a.main_ship_id = v_ship.main_ship_id
  loop
    v_cap_used := v_cap_used + 1;

    -- contributions: the exact stats_json key list the loadout/module loops read, coalesced to
    -- 0 — captains, modules, and support craft flow through ONE set of accumulators.
    a_combat    := a_combat    + coalesce((c.stats_json->>'attack')::numeric, 0);
    a_survival  := a_survival  + coalesce((c.stats_json->>'defense')::numeric, 0);
    a_repair    := a_repair    + coalesce((c.stats_json->>'repair')::numeric, 0);
    a_cargo     := a_cargo     + coalesce((c.stats_json->>'cargo')::numeric, 0);
    a_scout     := a_scout     + coalesce((c.stats_json->>'scan')::numeric, 0);
    a_mining    := a_mining    + coalesce((c.stats_json->>'mining')::numeric, 0);
    a_retreat   := a_retreat   + coalesce((c.stats_json->>'evasion')::numeric, 0);
    v_cap_speed_bonus := v_cap_speed_bonus + coalesce((c.stats_json->>'speed_mult_bonus')::numeric, 0);

    -- tradeoffs: the 0044/0115 idiom as a specialization CASE, ONE slot each so no cost scaling
    -- (a captain occupies exactly one slot — the 0117 headcount decision). A captain draws
    -- attention like crewed hardware; support-role captains are the low-profile option.
    -- Unknown/future specializations: stats yes, tradeoff 0 — the same permissive posture as
    -- above (the 0117 CHECK constrains the set today; 'else' is forward-compatibility).
    a_attention := a_attention + (case c.specialization when 'combat' then 2 when 'trade' then 1 when 'exploration' then 1 when 'mining' then 1 else 0 end);
    a_spd_pen   := a_spd_pen   + (case c.specialization when 'combat' then 0.02 when 'trade' then 0.02 when 'mining' then 0.02 else 0 end);
  end loop;

  -- (C7) captain slots are a HARD cap — the 0044:112–115 / 0115:194–196 mechanism, count-based
  -- (one captain = one slot). DEFENSE-IN-DEPTH: captain_assign_apply (0119) enforces this at
  -- assign time and is the primary gate; the adapter still refuses to compute stats from an
  -- over-capacity state rather than clamp or trust it.
  if v_cap_used > v_ship.captain_slots then
    raise exception 'calculate_expedition_stats: assigned captains use % captain slots, ship limit is %', v_cap_used, v_ship.captain_slots;
  end if;

  -- final speed = hull base speed raised by module + captain bonuses (additively inside the ONE
  -- multiplier, before penalties — the slice-locked order), reduced by penalties, floored so it
  -- never goes <= 0. With zero captains v_cap_speed_bonus = 0 and this reduces exactly to the
  -- 0115 expression (and with zero modules too, to 0044's).
  v_final_speed := round(greatest(0.2, v_speed * (1 + v_mod_speed_bonus + v_cap_speed_bonus) * (1 - a_spd_pen)), 3);

  -- (9)(10)(11) Build the normalized stat object. Every field is coalesced + clamped to
  -- >= 0 and rounded → never NaN, never negative, deterministic for the same input.
  return jsonb_build_object(
    'main_ship_id',           v_ship.main_ship_id,
    'activity_type',          p_activity_type,
    'support_capacity_used',  v_used,
    'support_capacity_limit', v_ship.support_capacity,
    'module_slots_used',      v_mod_used,
    'module_slots_limit',     v_ship.module_slots,
    'captain_slots_used',     v_cap_used,
    'captain_slots_limit',    v_ship.captain_slots,
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

-- ── ACL — re-asserted for the re-created function (the same posture 0044 established and 0115
--    re-asserted: server-only, service_role, NEVER clients — only the get_my_expedition_preview
--    wrapper (0049) is client-exposed). The TARGETED idiom (0115:232–233 verbatim). No other
--    function's grants touched.
revoke execute on function public.calculate_expedition_stats(uuid, uuid, jsonb, text) from public, anon, authenticated;
grant  execute on function public.calculate_expedition_stats(uuid, uuid, jsonb, text) to service_role;
