-- Byeharu — C2-2: the captain level → stats adapter parity delta (master plan §C P5:
-- "level curve → adapter parity delta in calculate_expedition_stats (stats × (1 + level_bonus),
-- byte-inert at level 1)"). Everything stays DARK behind captain_growth_enabled (0177, 'false').
--
-- ── THE PARITY DISCIPLINE (the D1/D3/0170 re-create law) ─────────────────────────────────────────
-- calculate_expedition_stats is copied VERBATIM from its TRUE head — migration 0170 (grep-verified:
-- the only create sites are 0044 → 0115 → 0122 → 0170; nothing in 0171..0179 re-creates it —
-- 0159/0165/0166/0168 only CALL it). Every delta is marked `-- C2-2 (0180):` and the diff vs the
-- 0170 head is EXACTLY:
--   · three added declares (v_growth / v_lvl_bonus / v_lvl_mult — flag + knob read ONCE, at entry,
--     never per-captain);
--   · one added column in the captain-loop join select (i.level — the 0177 column; additive,
--     the join itself is untouched);
--   · the ONE marked hunk where each assigned captain's stats fold in: the per-captain multiplier
--     assignment + ` * v_lvl_mult` appended to the EIGHT stats_json contribution reads (attack /
--     defense / repair / cargo / scan / mining / evasion / speed_mult_bonus).
-- Unlike 0170's add-only shape, this delta necessarily MODIFIES those eight fold lines (a
-- multiplicative scale cannot be expressed as added lines) — stated honestly; no other
-- pre-existing line of the body changes, and no other function is touched (extract-and-diff
-- verified during review).
--
-- ── THE DOUBLE GATE (why this is DOUBLY byte-inert today) ────────────────────────────────────────
-- Per captain: contribution × v_lvl_mult, where
--     v_lvl_mult = CASE WHEN cfg_bool('captain_growth_enabled')
--                       THEN 1 + (level - 1) * captain_level_bonus_per_level
--                       ELSE 1 END
--   (1) WHILE DARK the flag branch pins the multiplier to exactly 1.0 REGARDLESS OF LEVEL — the
--       flag is read ONCE outside the loop (v_growth), so a mid-scan config write can never split
--       one ship's captains across two regimes.
--   (2) AT LEVEL 1 the multiplier is exactly 1.0 REGARDLESS OF THE FLAG — (level - 1) = 0, and
--       the 0177 CHECK (level >= 1, not null) plus xp never having moved (the flag has been dark
--       since 0177 seeded it; the accrual is its sole writer) means EVERY captain is level 1 at
--       deploy time (self-asserted below).
-- NEVER A REDUCTION: the knob is floored at 0 (the 0177 defensive-knob posture — a mis-set
-- negative value must never make leveling a nerf) and level - 1 >= 0 by CHECK, so
-- v_lvl_mult >= 1 always; while dark it is exactly 1.
--
-- ── THE CURVE INTERACTION (0177 × this knob, at the [D] seeds) ───────────────────────────────────
-- 0177 maintains level = 1 + floor(sqrt(xp / 100)) [D]. With captain_level_bonus_per_level = 0.10
-- [D owner-tunable; a retune is one set_game_config]:
--     level 2 (100 xp)  → ×1.10 — +10% on the CAPTAIN-CONTRIBUTED portion only
--     level 3 (400 xp)  → ×1.20,  level 4 (900 xp) → ×1.30, … (linear in level, quadratic in xp)
-- e.g. a level-2 gunnery_veteran (0117: attack 4) contributes 4.4 attack instead of 4. The scale
-- applies to the captain's stats_json contribution ONLY — the specialization TRADEOFFS
-- (pirate_attention / speed penalty) stay level-flat: growth is never a stealth cost raise, and
-- the hull/module/support-craft pipelines are untouched.
--
-- ── LIVE-SURFACE HONESTY (what changes when this deploys): NOTHING ───────────────────────────────
-- Doubly inert (flag committed 'false' AND every captain level 1), so every adapter consumer —
-- the solo preview (0049/0159), the D0 group totals/preview (0165/0166), the D2 encounter
-- snapshots (0168) — answers byte-identically to the 0170 head. The CI proof
-- (scripts/team-command-proof.sql, BLOCK CAPLEVEL) pins the exact lit bonus AND both inertness
-- arms against real level-2 fixtures; this migration's self-asserts pin the prosrc shape (no
-- fixture exists at migration time to call the adapter against).
--
-- Forward-only: 0001–0179 unedited. C2-3 (XP bars) + C2-4 (the 6→8 slot raise) remain later slices.

-- ── 1) the [D] level-bonus knob — seeded 0.10, owner-tunable (the 0176/0177 idiom) ────────────────
insert into public.game_config (key, value, description) values
  ('captain_level_bonus_per_level', '0.10',
   'C2-2 (0180): per-level multiplier step for an assigned captain''s stats contribution in '
   'calculate_expedition_stats — contribution × (1 + (level - 1) × this) while '
   'captain_growth_enabled is true (exactly ×1.0 while dark, and at level 1 regardless of the '
   'flag). At 0.10: level 2 = +10%, level 3 = +20%, … on the captain-contributed portion only '
   '(tradeoffs stay level-flat). Floored at 0 by the adapter (a negative value never nerfs). '
   'Owner-tunable.')
on conflict (key) do nothing;

-- ── 2) calculate_expedition_stats — 0170 head re-created with the marked C2-2 level fold ─────────
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
  -- TEAM-ACTIVATION-PREP (0170): hull base combat stats (packet §1.4 delta)
  v_hull_stats      jsonb := '{}'::jsonb;
  -- C2-2 (0180): captain level fold — the growth flag + bonus knob, read ONCE at entry (never
  -- per-captain: a mid-scan config write must not split one ship's captains across two regimes).
  -- While captain_growth_enabled is false, v_growth pins the multiplier to exactly 1.0 regardless
  -- of level; the knob is floored at 0 so a mis-set negative value never makes leveling a nerf.
  -- NaN guard (review L1): cfg_num transits float8 — a mis-set "NaN" string would pass greatest()
  -- (NaN sorts above all numerics in PG) and poison every folded stat; NaN <> NaN detects it.
  v_growth          boolean := public.cfg_bool('captain_growth_enabled');
  v_lvl_bonus_raw   double precision := coalesce(public.cfg_num('captain_level_bonus_per_level'), 0);
  v_lvl_bonus       numeric := greatest(0, case when v_lvl_bonus_raw <> v_lvl_bonus_raw then 0 else v_lvl_bonus_raw end)::numeric;
  v_lvl_mult        numeric := 1;
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

  -- TEAM-ACTIVATION-PREP (0170): the HULL's own combat stats feed the SAME accumulators the
  -- support-craft / module / captain feeds use (ONE stat pipeline, no parallel hull pipeline) —
  -- the exact packet-§1.4 shape. coalesce-to-0 keeps the function byte-inert for any hull whose
  -- base_stats_json carries no attack/defense keys (the 0043 '{}' default), the D1 parity idiom.
  -- No tradeoff CASE: the hull IS the ship — its attention/speed cost is already the baseline.
  select coalesce(base_stats_json, '{}'::jsonb) into v_hull_stats
    from main_ship_hull_types where hull_type_id = v_ship.hull_type_id;
  a_combat   := a_combat   + coalesce((v_hull_stats->>'attack')::numeric, 0);
  a_survival := a_survival + coalesce((v_hull_stats->>'defense')::numeric, 0);
  -- END TEAM-ACTIVATION-PREP (0170) delta — everything below is the 0122 head, byte-identical.

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
    select t.specialization, t.stats_json,
           i.level   -- C2-2 (0180): the captain's level (0177 column) joins the fold — additive column only
    from ship_captain_assignments a
    join captain_instances i on i.id = a.captain_instance_id
    join captain_types t     on t.id = i.captain_type_id
    where a.main_ship_id = v_ship.main_ship_id
  loop
    v_cap_used := v_cap_used + 1;

    -- C2-2 (0180): the level multiplier — GATED (v_growth false → exactly 1.0 whatever the level)
    -- and byte-inert at level 1 ((level - 1) = 0 → exactly 1.0 whatever the flag): the DOUBLE
    -- inertness. Scales ONLY this captain's stats_json contribution (the 8 reads below) — never
    -- the specialization tradeoffs (attention/speed cost stay level-flat: growth is never a
    -- stealth cost raise). v_lvl_bonus >= 0 and c.level >= 1 (0177 CHECK) → v_lvl_mult >= 1 always.
    v_lvl_mult := case when v_growth then 1 + (c.level - 1) * v_lvl_bonus else 1 end;

    -- contributions: the exact stats_json key list the loadout/module loops read, coalesced to
    -- 0 — captains, modules, and support craft flow through ONE set of accumulators.
    -- C2-2 (0180): each read scaled by the gated level multiplier (× 1.0 exactly while dark or at level 1).
    a_combat    := a_combat    + coalesce((c.stats_json->>'attack')::numeric, 0)  * v_lvl_mult;
    a_survival  := a_survival  + coalesce((c.stats_json->>'defense')::numeric, 0) * v_lvl_mult;
    a_repair    := a_repair    + coalesce((c.stats_json->>'repair')::numeric, 0)  * v_lvl_mult;
    a_cargo     := a_cargo     + coalesce((c.stats_json->>'cargo')::numeric, 0)   * v_lvl_mult;
    a_scout     := a_scout     + coalesce((c.stats_json->>'scan')::numeric, 0)    * v_lvl_mult;
    a_mining    := a_mining    + coalesce((c.stats_json->>'mining')::numeric, 0)  * v_lvl_mult;
    a_retreat   := a_retreat   + coalesce((c.stats_json->>'evasion')::numeric, 0) * v_lvl_mult;
    v_cap_speed_bonus := v_cap_speed_bonus + coalesce((c.stats_json->>'speed_mult_bonus')::numeric, 0) * v_lvl_mult;
    -- END C2-2 (0180) hunk — everything below is the 0170 head, byte-identical.

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

-- ── ACL — re-asserted for the re-created function (the 0044/0115/0122/0170 posture verbatim:
--    server-only, service_role, NEVER clients — only the get_my_expedition_preview wrapper
--    (0049/0159) is client-exposed). The TARGETED idiom. No other function's grants touched.
revoke execute on function public.calculate_expedition_stats(uuid, uuid, jsonb, text) from public, anon, authenticated;
grant  execute on function public.calculate_expedition_stats(uuid, uuid, jsonb, text) to service_role;

-- ── 3) Self-assert: knob seeded; DOUBLE inertness holds at migration time (flag dark + every
--       captain level 1); prosrc pins the gated-multiplier shape (no fixture exists in a
--       migration, so no adapter call here — the prosrc pins + the CI proof's BLOCK CAPLEVEL
--       carry the behavior: exact lit bonus + both inertness arms against real level-2 fixtures);
--       ACL server-only ─────────────────────────────────────────────────────────────────────────
do $$
declare v_n integer; v_src text; v_tok text;
begin
  -- 1. The knob is seeded 0.10 (both the numeric read and the committed jsonb text).
  if coalesce(public.cfg_num('captain_level_bonus_per_level'), -1) <> 0.10 then
    raise exception 'C2-2 self-assert FAIL: captain_level_bonus_per_level reads % (want 0.10)',
      public.cfg_num('captain_level_bonus_per_level');
  end if;

  -- 2. THE DOUBLE INERTNESS at migration time: the 0177 flag is still dark AND every captain
  --    instance is level 1 (xp untouched — the accrual is the sole writer and has only ever run
  --    dark). Either arm alone keeps the multiplier exactly 1.0; both failing simultaneously at
  --    deploy time would mean the flag was lit early — fail the deploy and force a human decision.
  if public.cfg_bool('captain_growth_enabled') then
    raise exception 'C2-2 self-assert FAIL: captain_growth_enabled is true at migration time (the C2-2 delta must ship dark)';
  end if;
  select count(*) into v_n from public.captain_instances where level <> 1;
  if v_n <> 0 then
    raise exception 'C2-2 self-assert FAIL: % captain instance(s) above level 1 at migration time (want 0 — growth has never been lit)', v_n;
  end if;

  -- 3. PROSRC PINS — the re-created adapter carries exactly the gated fold shape:
  select prosrc into v_src from pg_proc
    where oid = 'public.calculate_expedition_stats(uuid, uuid, jsonb, text)'::regprocedure;
  -- (a) the gated multiplier token (flag branch → level term → knob local; dark else-arm = 1):
  if position('v_lvl_mult := case when v_growth then 1 + (c.level - 1) * v_lvl_bonus else 1 end' in v_src) = 0 then
    raise exception 'C2-2 self-assert FAIL: the gated level-multiplier token is missing from prosrc';
  end if;
  -- (b) the knob is read (floored, coalesced) and the level column joins the fold:
  if position('captain_level_bonus_per_level' in v_src) = 0 then
    raise exception 'C2-2 self-assert FAIL: prosrc never reads captain_level_bonus_per_level';
  end if;
  if position('i.level' in v_src) = 0 then
    raise exception 'C2-2 self-assert FAIL: prosrc does not select captain_instances.level in the captain join';
  end if;
  -- (c) the multiplier scales EXACTLY the eight captain stats_json reads (7 accumulators +
  --     speed_mult_bonus) — fewer = a dropped stat, more = a leak onto another pipeline:
  v_tok := '* v_lvl_mult';
  v_n := (length(v_src) - length(replace(v_src, v_tok, ''))) / length(v_tok);
  if v_n <> 8 then
    raise exception 'C2-2 self-assert FAIL: found % "* v_lvl_mult" scale sites in prosrc (want exactly 8 — the captain stats_json reads only)', v_n;
  end if;
  -- (d) the tradeoff lines stay level-flat: neither tradeoff accumulator is multiplied by the fold.
  if position('else 0 end) * v_lvl_mult' in v_src) > 0 then
    raise exception 'C2-2 self-assert FAIL: a specialization tradeoff is scaled by the level multiplier (must stay level-flat)';
  end if;

  -- 4. ACL: still server-only (the 0170 posture re-asserted above must have landed).
  if has_function_privilege('authenticated', 'public.calculate_expedition_stats(uuid, uuid, jsonb, text)', 'execute')
     or has_function_privilege('anon', 'public.calculate_expedition_stats(uuid, uuid, jsonb, text)', 'execute') then
    raise exception 'C2-2 self-assert FAIL: calculate_expedition_stats is client-executable (must be server-only)';
  end if;
  if not has_function_privilege('service_role', 'public.calculate_expedition_stats(uuid, uuid, jsonb, text)', 'execute') then
    raise exception 'C2-2 self-assert FAIL: calculate_expedition_stats not granted to service_role';
  end if;

  raise notice 'C2-2 self-assert ok: knob seeded 0.10; doubly inert at migration time (flag dark + all captains level 1); prosrc pins the gated multiplier (8 scale sites, tradeoffs level-flat, i.level joined); adapter server-only';
end $$;
