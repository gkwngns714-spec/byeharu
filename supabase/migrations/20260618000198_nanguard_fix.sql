-- Byeharu — NANGUARD (FULL_CAPACITY_PLAN queue row 20): fix the inherited NO-OP NaN guards at all
-- three knob-read sites. The house idiom `case when v_raw <> v_raw then 0 else v_raw end` is meant
-- to floor a mis-set "NaN" knob to 0, but it is a NO-OP in PostgreSQL: PG deviates from IEEE-754 and
-- makes `'NaN'::float8 = 'NaN'::float8` TRUE (so `x <> x` is FALSE for NaN) — the guard arm is
-- UNREACHABLE and a knob mis-set to the JSON string "NaN" passes straight through greatest() (NaN
-- sorts above every numeric in PG) to poison / abort the guarded math. This slice switches all three
-- sites to the WORKING equality test `= 'NaN'::double precision` — the 0182 worldstate-knob
-- precedent (0182:204-207 guards `if v_x = 'NaN'::double precision then v_x := <default>`), the ONE
-- idiom that actually catches NaN in PG.
--
-- ── THE THREE GUARD SITES (grep-verified TRUE heads across ALL migrations) ────────────────────────
--   1. calculate_expedition_stats — TRUE head 0196 (DECKS-3; creates 0044→0115→0122→0170→0180→0193
--      →0196, nothing later). TWO guards live here: the 0180 LEVEL knob
--      (captain_level_bonus_per_level) and the 0196 AFFINITY knob (station_affinity_bonus).
--   2. process_mainship_expeditions — TRUE head 0197 (SHIELD-2; creates 0050→0169→0197, nothing
--      later). ONE guard: the 0197 IDLE-REGEN knob (shield_regen_idle_pct).
--   NOT a site: process_combat_ticks (0195) reads shield_regen_combat_pct as a bare
--      `coalesce(cfg_num('shield_regen_combat_pct'), 0)` — NO `x <> x` guard at all, so there is
--      nothing to fix there (verified: the only shield_regen_combat_pct read in that body is the
--      bare coalesce). Three guard sites, not four.
--
-- ── PARITY DISCIPLINE (extract-and-diff — these are LIVE/HOT functions) ───────────────────────────
-- Each function below is its TRUE-head body VERBATIM except the ONE marked `-- NANGUARD (0198)` hunk
-- per guard: the `<>` operator becomes `= 'NaN'::double precision`, and the adjacent honesty-note
-- comment that called the old arm a no-op is corrected (the plan row: "corrects the inherited
-- comments"). NOTHING else changes — no logic, no refactor, no helper. Reviewers: diff §2 of 0196
-- and §1 of 0197 — every accumulated hunk (0115/0122/0170/0180/0193/0196 in calc; the 0169 CTEs +
-- 0197 regen hunk in the reconciler) is byte-identical, only the guard operator moves.
--
-- ── BEHAVIORALLY INERT AT THE CURRENT SEEDS ──────────────────────────────────────────────────────
-- All three knobs are seeded '0' today, and 0 is not NaN under EITHER idiom — so this fix changes
-- NOTHING at the committed seeds: every existing proof stays green unchanged, every consumer answers
-- byte-identically. The fix matters ONLY post-flip, if someone ever writes a bad knob value: it is a
-- correctness / robustness fix with zero behavior change now. (A negative knob is still floored by
-- the unchanged greatest(0, …); this slice only makes the NaN arm reachable.)
--
-- ── PROOF (the witness the inert envelope can't show) ────────────────────────────────────────────
-- team-command-proof gains TEAMCMD_PASS_NANGUARD (25th marker): it sets a knob to the jsonb string
-- '"NaN"' IN-TXN, calls the affected function, and asserts the output is NOT poisoned (the fixed
-- guard floors NaN to 0 → the function behaves as if the knob were 0, never a NaN / abort). Done for
-- the affinity knob (calculate_expedition_stats: matched captain, knob "NaN" → bonus 0 → the knob-0
-- baseline) and the idle-regen knob (process_mainship_expeditions: knob "NaN" → the regen statement
-- is skipped, no NaN write, no abort). This proof would have FAILED before the fix (NaN propagates /
-- aborts) and PASSES after. Knobs restored to '0' in-txn.
--
-- Forward-only: 0001–0197 unedited.

-- ── §1) calculate_expedition_stats — the 0196 TRUE-head body VERBATIM + the TWO marked NANGUARD
--    guard hunks (the level knob + the affinity knob). ──────────────────────────────────────────
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
  -- (NaN sorts above all numerics in PG) and poison every folded stat.
  -- NANGUARD (0198): the guard is the WORKING equality test (= 'NaN'::double precision — the 0182
  -- worldstate-knob precedent). PG makes NaN = NaN TRUE, so this arm is REACHABLE and floors a
  -- mis-set "NaN" knob to 0. (The 0180 head shipped the dead x-not-equal-x shape, a PG no-op whose
  -- arm was unreachable; corrected here.)
  v_growth          boolean := public.cfg_bool('captain_growth_enabled');
  v_lvl_bonus_raw   double precision := coalesce(public.cfg_num('captain_level_bonus_per_level'), 0);
  v_lvl_bonus       numeric := greatest(0, case when v_lvl_bonus_raw = 'NaN'::double precision then 0 else v_lvl_bonus_raw end)::numeric;   -- NANGUARD (0198): was `<>` (a PG no-op)
  v_lvl_mult        numeric := 1;
  -- SOUL-1 (0193): ship-trait fold — the gate read ONCE at entry (the 0180 v_growth posture: a
  -- mid-scan config write must never split one ship's read across regimes). While false the
  -- trait read below is SKIPPED ENTIRELY (knob-gated read: dark = zero trait-table reads and a
  -- byte-identical output); lit with zero rolled rows = an empty loop (byte-identical output) —
  -- the DOUBLE inertness.
  v_traits_enabled    boolean := public.cfg_bool('ship_traits_enabled');
  tr                  record;
  v_trait_speed_bonus numeric := 0;
  -- DECKS-3 (0196): station-affinity fold — the bonus knob, read ONCE at entry (the exact 0180
  -- v_lvl_bonus posture, guard SHAPE mirrored for parity: never a knob read per row, never split
  -- across regimes mid-scan). Seeded '0' → ×(1 + 0) = ×1.0 exactly — byte-inert while unflipped;
  -- floored at 0 so a mis-set negative value never makes a matched station a nerf. v_aff_mult is
  -- assigned per captain inside the loop (from the two ALREADY-JOINED columns), the knob never
  -- re-read. NANGUARD (0198): both knob guards here use the WORKING equality test
  -- (= 'NaN'::double precision — the 0182 worldstate-knob precedent). PG makes NaN = NaN TRUE, so
  -- the arm is REACHABLE and a knob mis-set to "NaN" is floored to 0 (never poisons the folded
  -- stats). The 0180/0196 heads shipped the dead x-not-equal-x shape (a PG no-op whose arm was
  -- unreachable); this slice corrected BOTH adapter guards and their pinned self-asserts.
  v_aff_bonus_raw   double precision := coalesce(public.cfg_num('station_affinity_bonus'), 0);
  v_aff_bonus       numeric := greatest(0, case when v_aff_bonus_raw = 'NaN'::double precision then 0 else v_aff_bonus_raw end)::numeric;   -- NANGUARD (0198): was `<>` (a PG no-op)
  v_aff_mult        numeric := 1;
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

  -- SOUL-1 (0193): the ship's rolled BIRTHMARK TRAITS (main_ship_traits × ship_trait_types) feed
  -- the SAME accumulators — placed adjacent to the hull fold because traits are part of the SHIP
  -- ITSELF, another additive contribution ahead of the equipment loops (all contributions are
  -- additive into one accumulator set, so order cannot change the sum — adjacency to the 0170
  -- hull idiom is documentation, not arithmetic). Same key vocabulary as the module loop
  -- (0180:212–219), coalesced to 0 — the ONE fold idiom, no second trait reader. KNOB-GATED read:
  -- skipped entirely while dark. NO tradeoff CASE: a trait's costs live IN its stats_json minus
  -- keys (five of eight seeds — the 0186 law-4 posture). hp_mult is NOT read here — it was
  -- applied ONCE at roll time to max_hp by soul_roll_traits_for_ship (0186); re-scaling it in the
  -- adapter would double-apply.
  if v_traits_enabled then
    for tr in
      select y.stats_json
      from main_ship_traits mt
      join ship_trait_types y on y.trait_type_id = mt.trait_type_id
      where mt.main_ship_id = v_ship.main_ship_id
    loop
      a_combat    := a_combat    + coalesce((tr.stats_json->>'attack')::numeric, 0);
      a_survival  := a_survival  + coalesce((tr.stats_json->>'defense')::numeric, 0);
      a_repair    := a_repair    + coalesce((tr.stats_json->>'repair')::numeric, 0);
      a_cargo     := a_cargo     + coalesce((tr.stats_json->>'cargo')::numeric, 0);
      a_scout     := a_scout     + coalesce((tr.stats_json->>'scan')::numeric, 0);
      a_mining    := a_mining    + coalesce((tr.stats_json->>'mining')::numeric, 0);
      a_retreat   := a_retreat   + coalesce((tr.stats_json->>'evasion')::numeric, 0);
      v_trait_speed_bonus := v_trait_speed_bonus + coalesce((tr.stats_json->>'speed_mult_bonus')::numeric, 0);
    end loop;
  end if;
  -- END SOUL-1 (0193) trait-fold hunk — everything below is the 0180 head, byte-identical, except
  -- the ONE marked final-speed line.

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
           i.level,   -- C2-2 (0180): the captain's level (0177 column) joins the fold — additive column only
           st.affinity_specialization   -- DECKS-3 (0196): the held station's favored specialization (NULL when unstationed or the station has none — the Bridge); additive column only
    from ship_captain_assignments a
    join captain_instances i on i.id = a.captain_instance_id
    join captain_types t     on t.id = i.captain_type_id
    left join ship_stations st on st.station_id = a.station   -- DECKS-3 (0196): LEFT — a station-NULL row (general quarters) must KEEP folding at ×1.0; an inner join would silently drop that captain's whole contribution (dark-parity breach)
    where a.main_ship_id = v_ship.main_ship_id
  loop
    v_cap_used := v_cap_used + 1;

    -- C2-2 (0180): the level multiplier — GATED (v_growth false → exactly 1.0 whatever the level)
    -- and byte-inert at level 1 ((level - 1) = 0 → exactly 1.0 whatever the flag): the DOUBLE
    -- inertness. Scales ONLY this captain's stats_json contribution (the 8 reads below) — never
    -- the specialization tradeoffs (attention/speed cost stay level-flat: growth is never a
    -- stealth cost raise). v_lvl_bonus >= 0 and c.level >= 1 (0177 CHECK) → v_lvl_mult >= 1 always.
    v_lvl_mult := case when v_growth then 1 + (c.level - 1) * v_lvl_bonus else 1 end;

    -- DECKS-3 (0196): the station-affinity multiplier — the 0180 gated-multiplier shape mirrored.
    -- A MATCH (the held station's affinity_specialization equals THIS captain's specialization,
    -- the 0189 mapping: Gunnery=combat, Engineering=mining, Logistics=trade, Sensors=exploration,
    -- Medbay=support) → ×(1 + v_aff_bonus). EVERYTHING ELSE falls to the ELSE arm — exactly 1.0,
    -- never a knob read per row (the knob was read ONCE at entry): a MISMATCH (combat captain in
    -- Medbay), an UNSTATIONED captain (NULL station → NULL affinity via the LEFT join), and a
    -- no-affinity station (the Bridge, affinity NULL by seed) — NULL = <anything> is NULL in SQL,
    -- so both NULL shapes take the same no-match branch. DOUBLE-INERT: knob '0' (the committed
    -- seed) → ×(1+0) = ×1.0 exactly on every captain regardless of station; no match → ×1.0
    -- exactly regardless of the knob. Composes with the level multiplier at the EXISTING scale
    -- sites (contribution × v_lvl_mult × v_aff_mult — multiplication commutes; the token order is
    -- the pin) and scales ONLY this captain's stats_json contribution — never the specialization
    -- tradeoffs (affinity-flat: a matched station is never a stealth cost raise).
    -- v_aff_bonus >= 0 → v_aff_mult >= 1 always.
    v_aff_mult := case when c.affinity_specialization = c.specialization then 1 + v_aff_bonus else 1 end;

    -- contributions: the exact stats_json key list the loadout/module loops read, coalesced to
    -- 0 — captains, modules, and support craft flow through ONE set of accumulators.
    -- C2-2 (0180): each read scaled by the gated level multiplier (× 1.0 exactly while dark or at level 1).
    -- DECKS-3 (0196): × v_aff_mult composed at the same eight sites (× 1.0 exactly while the knob
    -- is 0 or the station doesn't match — the only modified pre-existing lines of this delta).
    a_combat    := a_combat    + coalesce((c.stats_json->>'attack')::numeric, 0)  * v_lvl_mult * v_aff_mult;
    a_survival  := a_survival  + coalesce((c.stats_json->>'defense')::numeric, 0) * v_lvl_mult * v_aff_mult;
    a_repair    := a_repair    + coalesce((c.stats_json->>'repair')::numeric, 0)  * v_lvl_mult * v_aff_mult;
    a_cargo     := a_cargo     + coalesce((c.stats_json->>'cargo')::numeric, 0)   * v_lvl_mult * v_aff_mult;
    a_scout     := a_scout     + coalesce((c.stats_json->>'scan')::numeric, 0)    * v_lvl_mult * v_aff_mult;
    a_mining    := a_mining    + coalesce((c.stats_json->>'mining')::numeric, 0)  * v_lvl_mult * v_aff_mult;
    a_retreat   := a_retreat   + coalesce((c.stats_json->>'evasion')::numeric, 0) * v_lvl_mult * v_aff_mult;
    v_cap_speed_bonus := v_cap_speed_bonus + coalesce((c.stats_json->>'speed_mult_bonus')::numeric, 0) * v_lvl_mult * v_aff_mult;
    -- END C2-2 (0180) + DECKS-3 (0196) hunks — everything below is the 0170 head, byte-identical.

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
  -- SOUL-1 (0193): + v_trait_speed_bonus joins the ONE multiplier (the only modified pre-existing
  -- line of this delta — exactly + 0 while dark or trait-less, so the value is unchanged).
  v_final_speed := round(greatest(0.2, v_speed * (1 + v_mod_speed_bonus + v_cap_speed_bonus + v_trait_speed_bonus) * (1 - a_spd_pen)), 3);

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

-- ── ACL — re-asserted for the re-created adapter (the 0044/0115/0122/0170/0180/0193 posture
--    verbatim: server-only, service_role, NEVER clients — only the get_my_expedition_preview
--    wrapper (0049/0159) is client-exposed). The TARGETED idiom. ─────────────────────────────────
revoke execute on function public.calculate_expedition_stats(uuid, uuid, jsonb, text) from public, anon, authenticated;
grant  execute on function public.calculate_expedition_stats(uuid, uuid, jsonb, text) to service_role;

-- ── §2) process_mainship_expeditions — the 0197 TRUE-head body VERBATIM + the ONE marked NANGUARD
--    guard hunk (the idle-regen knob). CREATE OR REPLACE preserves owner + grants (server-only —
--    re-asserted in §3). ONLY process_mainship_expeditions is re-created: the other two functions
--    0197 carried (port_entry_commission_build / ensure_main_ship_for_player) hold NO NaN guard and
--    stay at their 0197 head, untouched. ──────────────────────────────────────────────────────────
create or replace function public.process_mainship_expeditions()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
  v_team  integer;   -- SLICE D3: team-sortie reconcile count (0 on every run until the flag ever flips)
  -- SHIELD-2 (0197): the idle regen knob — read ONCE per invocation (the 0195 hoist law), floored
  -- at 0 (a mis-set negative can never DRAIN shields). NANGUARD (0198): the NaN guard is the WORKING
  -- equality test (= 'NaN'::double precision — the 0182 worldstate-knob precedent). PG makes NaN =
  -- NaN TRUE, so the arm is REACHABLE and a mis-set "NaN" knob is floored to 0 (the statement below
  -- is then skipped, never a NaN write / abort). The 0197 head shipped the dead x-not-equal-x shape
  -- (a PG no-op whose arm was unreachable); corrected here. '0' (the committed 0191 seed) → v_idle =
  -- 0 → the guarded statement below is SKIPPED ENTIRELY (zero reads, zero writes — see the hunk).
  v_idle_raw double precision := coalesce(cfg_num('shield_regen_idle_pct'), 0);
  v_idle     double precision := greatest(0, case when v_idle_raw = 'NaN'::double precision then 0 else v_idle_raw end);   -- NANGUARD (0198): was `<>` (a PG no-op)
begin
  -- A ship that is out (traveling/returning) but has no in-flight tagged fleet has come
  -- home (fleet completed) or lost its fleet → set it home. Idempotent.
  with homed as (
    update main_ship_instances s
      set status = 'home', updated_at = now()
      where s.status in ('traveling','returning')
        and not exists (
          select 1 from fleets f
          where f.main_ship_id = s.main_ship_id
            and f.status in ('moving','present','returning')
        )
        -- SLICE D3: member-only guard — a sortie member marked 'returning' by the tick has NO
        -- main_ship_id-tagged fleet (a team flies ONE untagged fleet), so the head's not-exists is
        -- vacuously true for it; without this guard the branch would yank it 'home' while its
        -- MANIFEST fleet is still flying home. Once that fleet finishes, the guard opens and this
        -- branch re-homes the member with its unchanged legacy write. No legacy ship has manifest
        -- rows → provably false-impact on every row this branch has ever touched (parity law).
        and not exists (
          select 1 from group_sortie_members gsm
          join fleets gf on gf.id = gsm.fleet_id
          where gsm.main_ship_id = s.main_ship_id
            and gf.status in ('moving','present','returning')
        )
      returning 1)
  select count(*) into v_count from homed;

  -- SLICE D3: the team-sortie branch — re-home 'hunting' ships whose MANIFEST fleet is finished
  -- (completed back home / destroyed / deleted). 'hunting' has exactly ONE writer
  -- (send_ship_group_hunt, 0168), so this can never touch a legacy ship. The predicate is the EXACT
  -- COMPLEMENT of "live sortie": a manifest fleet in ('moving','present','returning') — outbound,
  -- MID-COMBAT, or flying home — pins its members untouched. Self-healing by design (belt and
  -- braces against partial states): a 'hunting' ship whose fleet was destroyed but which the D1
  -- defeat loop somehow missed, or whose fleet row was deleted (manifest CASCADEd away → not-exists
  -- vacuously true), comes home rather than staying wedged — the reconciler NEVER destroys a ship
  -- (destruction is combat's verdict alone; a wrongly homed ship is self-correcting, a wrongly
  -- destroyed one is not). Write shape: the head branch's own (status only; spatial_state stays
  -- NULL — the clean legacy_home). Idempotent.
  with team_homed as (
    update main_ship_instances s
      set status = 'home', updated_at = now()
      where s.status = 'hunting'
        and not exists (
          select 1 from group_sortie_members gsm
          join fleets gf on gf.id = gsm.fleet_id
          where gsm.main_ship_id = s.main_ship_id
            and gf.status in ('moving','present','returning')
        )
      returning 1)
  select count(*) into v_team from team_homed;

  -- ── SHIELD-2 (0197) HUNK: the OUT-OF-COMBAT shield regen — the charter's ONE set-based
  --    statement, riding the 0191 partial index (`shield < max_shield` — only damaged shields are
  --    candidates; ZERO rows while everything is 0/0).
  --    DOUBLE-GUARDED: `least(max, shield + 0)` = shield, but a same-value UPDATE still fires row
  --    writes (new tuple versions, WAL) on every matching row — so knob 0 (the committed seed,
  --    incl. missing/negative floored above; and a 'NaN' knob floored to 0 by the NANGUARD (0198)
  --    guard fix) skips the statement ENTIRELY: zero reads, zero
  --    writes, a cron pass byte-identical to the 0169 head's. ceil() guarantees progress at any
  --    positive knob; least() owns the ceiling; the statement only ADDS, so the 0-floor is
  --    by construction.
  --    THE EXCLUSION PREDICATE (charter §1.3.2 — a disjoint-writers partition, NOT a second lock
  --    system): while a ship holds a membership row in a LIVE encounter (`status in
  --    ('active','retreating')` — the tick's own scan set), the 3s tick is the SOLE shield writer
  --    (via the 0191 leaf); outside one, this statement is. Historical combat_units rows are
  --    filtered by the encounter-status join — a ship that fought LAST week regens fine.
  --    `status <> 'destroyed'`: a dead hull regenerates nothing (repair is the revival path).
  --    Regenerated rows are NOT counted into the return value (envelope byte-identical to the
  --    0169 head). ─────────────────────────────────────────────────────────────────────────────
  if v_idle > 0 then
    update main_ship_instances s
      set shield = least(s.max_shield, s.shield + ceil(s.max_shield * v_idle)::integer),
          updated_at = now()
      where s.shield < s.max_shield
        and s.status <> 'destroyed'
        and not exists (
          select 1 from combat_units cu
          join combat_encounters ce on ce.id = cu.encounter_id
          where cu.main_ship_id = s.main_ship_id
            and ce.status in ('active','retreating')
        );
  end if;
  -- ── END SHIELD-2 (0197) HUNK ───────────────────────────────────────────────────────────────────

  return v_count + v_team;
end;
$$;

-- ── §3) SELF-ASSERTS — NANGUARD proves the fix landed at all three sites, every accumulated hunk
--    survived, and the knobs are still seeded '0' (inert) — or refuses to land ────────────────────
do $$
declare
  v_src text;
  v_n   integer;
  v_tok text;
  v_val text;
begin
  -- ══ A) calculate_expedition_stats — BOTH guards now the WORKING idiom, the dead arm gone ════════
  select prosrc into v_src from pg_proc
    where oid = 'public.calculate_expedition_stats(uuid, uuid, jsonb, text)'::regprocedure;
  if v_src is null then raise exception 'NANGUARD self-assert FAIL: calculate_expedition_stats not deployed'; end if;
  -- the LEVEL guard (0180): working equality form present, dead x<>x form gone:
  if position('case when v_lvl_bonus_raw = ''NaN''::double precision then 0 else v_lvl_bonus_raw end' in v_src) = 0 then
    raise exception 'NANGUARD self-assert FAIL: the level knob lacks the working = ''NaN''::double precision guard';
  end if;
  if position('v_lvl_bonus_raw <> v_lvl_bonus_raw' in v_src) > 0 then
    raise exception 'NANGUARD self-assert FAIL: the level knob still carries the dead x <> x guard';
  end if;
  -- the AFFINITY guard (0196): working equality form present, dead x<>x form gone:
  if position('case when v_aff_bonus_raw = ''NaN''::double precision then 0 else v_aff_bonus_raw end' in v_src) = 0 then
    raise exception 'NANGUARD self-assert FAIL: the affinity knob lacks the working = ''NaN''::double precision guard';
  end if;
  if position('v_aff_bonus_raw <> v_aff_bonus_raw' in v_src) > 0 then
    raise exception 'NANGUARD self-assert FAIL: the affinity knob still carries the dead x <> x guard';
  end if;
  -- exactly TWO NaN-floor guard sites in this function (the two knobs — no more, no fewer):
  v_n := (length(v_src) - length(replace(v_src, 'then 0 else', ''))) / length('then 0 else');
  if v_n <> 2 then
    raise exception 'NANGUARD self-assert FAIL: % NaN-floor guard sites in calculate_expedition_stats (want exactly 2 — the level + affinity knobs)', v_n;
  end if;
  if position('random(' in v_src) > 0 then
    raise exception 'NANGUARD self-assert FAIL: calculate_expedition_stats contains random() (0041)';
  end if;
  -- the ACCUMULATED-HUNK LAW: every marked head behavior survives the re-create (the guard change
  -- touches nothing else). Re-run the load-bearing 0180 / 0193 / 0196 + 0115/0122/0170 pins:
  v_tok := '* v_lvl_mult * v_aff_mult';
  v_n := (length(v_src) - length(replace(v_src, v_tok, ''))) / length(v_tok);
  if v_n <> 8 then raise exception 'NANGUARD self-assert FAIL: % composed scale sites (want the 0196 head''s 8)', v_n; end if;
  if position('v_lvl_mult := case when v_growth then 1 + (c.level - 1) * v_lvl_bonus else 1 end' in v_src) = 0 then
    raise exception 'NANGUARD self-assert FAIL: the 0180 gated level-multiplier vanished'; end if;
  if position('v_aff_mult := case when c.affinity_specialization = c.specialization then 1 + v_aff_bonus else 1 end' in v_src) = 0 then
    raise exception 'NANGUARD self-assert FAIL: the 0196 no-match affinity CASE vanished'; end if;
  v_tok := 'left join ship_stations st on st.station_id = a.station';
  v_n := (length(v_src) - length(replace(v_src, v_tok, ''))) / length(v_tok);
  if v_n <> 1 then raise exception 'NANGUARD self-assert FAIL: % LEFT station join sites (want the 0196 head''s 1)', v_n; end if;
  if position('if v_traits_enabled then' in v_src) = 0 or position('from main_ship_traits' in v_src) = 0 then
    raise exception 'NANGUARD self-assert FAIL: the 0193 knob-gated trait fold vanished'; end if;
  if position('(v_hull_stats->>''attack'')' in v_src) = 0
     or position('from ship_module_fittings f' in v_src) = 0
     or position('from ship_captain_assignments a' in v_src) = 0 then
    raise exception 'NANGUARD self-assert FAIL: a 0115/0122/0170 hunk vanished (accumulated-hunk law)'; end if;
  -- server-only ACL survives the re-create (the 0044..0196 posture):
  if has_function_privilege('authenticated', 'public.calculate_expedition_stats(uuid, uuid, jsonb, text)', 'execute')
     or has_function_privilege('anon', 'public.calculate_expedition_stats(uuid, uuid, jsonb, text)', 'execute') then
    raise exception 'NANGUARD self-assert FAIL: calculate_expedition_stats is client-executable'; end if;
  if not has_function_privilege('service_role', 'public.calculate_expedition_stats(uuid, uuid, jsonb, text)', 'execute') then
    raise exception 'NANGUARD self-assert FAIL: calculate_expedition_stats not granted to service_role'; end if;

  -- ══ B) process_mainship_expeditions — the idle-regen guard now the WORKING idiom ════════════════
  select prosrc into v_src from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'process_mainship_expeditions';
  if v_src is null then raise exception 'NANGUARD self-assert FAIL: process_mainship_expeditions not deployed'; end if;
  if position('case when v_idle_raw = ''NaN''::double precision then 0 else v_idle_raw end' in v_src) = 0 then
    raise exception 'NANGUARD self-assert FAIL: the idle-regen knob lacks the working = ''NaN''::double precision guard'; end if;
  if position('v_idle_raw <> v_idle_raw' in v_src) > 0 then
    raise exception 'NANGUARD self-assert FAIL: the idle-regen knob still carries the dead x <> x guard'; end if;
  v_n := (length(v_src) - length(replace(v_src, 'then 0 else', ''))) / length('then 0 else');
  if v_n <> 1 then
    raise exception 'NANGUARD self-assert FAIL: % NaN-floor guard sites in process_mainship_expeditions (want exactly 1 — the idle knob)', v_n; end if;
  -- the 0197 regen hunk + guard + exclusion and the 0169 head survive (accumulated-hunk law):
  foreach v_tok in array array[
    'v_idle_raw double precision := coalesce(cfg_num(''shield_regen_idle_pct''), 0);',
    'if v_idle > 0 then',
    'set shield = least(s.max_shield, s.shield + ceil(s.max_shield * v_idle)::integer)',
    's.status <> ''destroyed''',
    'ce.status in (''active'',''retreating'')',
    'with homed as (',
    'with team_homed as (',
    'return v_count + v_team;'] loop
    if strpos(v_src, v_tok) = 0 then
      raise exception 'NANGUARD self-assert FAIL: process_mainship_expeditions lost head token ''%'' (accumulated-hunk law)', v_tok; end if;
  end loop;
  -- the knob is still read exactly once (the 0195 hoist law survives):
  v_n := (length(v_src) - length(replace(v_src, 'cfg_num(''shield_regen_idle_pct'')', ''))) / length('cfg_num(''shield_regen_idle_pct'')');
  if v_n <> 1 then raise exception 'NANGUARD self-assert FAIL: shield_regen_idle_pct read % times (want exactly 1)', v_n; end if;
  if position('random(' in v_src) > 0 then
    raise exception 'NANGUARD self-assert FAIL: process_mainship_expeditions contains random() (0041)'; end if;
  if has_function_privilege('authenticated', 'public.process_mainship_expeditions()', 'execute')
     or has_function_privilege('anon', 'public.process_mainship_expeditions()', 'execute') then
    raise exception 'NANGUARD self-assert FAIL: process_mainship_expeditions is client-executable'; end if;
  if not has_function_privilege('service_role', 'public.process_mainship_expeditions()', 'execute') then
    raise exception 'NANGUARD self-assert FAIL: process_mainship_expeditions not granted to service_role'; end if;

  -- ══ C) INERTNESS — all three knobs are still the committed '0' (0 is not NaN under either idiom,
  --    so the fix is behaviorally inert at the seeds; every existing proof stays green) ════════════
  foreach v_tok in array array['captain_level_bonus_per_level','station_affinity_bonus','shield_regen_idle_pct'] loop
    select value #>> '{}' into v_val from public.game_config where key = v_tok;
    if v_val is distinct from '0' then
      raise exception 'NANGUARD self-assert FAIL: knob % reads % at apply time (want the committed ''0'' — NANGUARD is inert at seed)', v_tok, coalesce(v_val, '<missing>'); end if;
  end loop;

  raise notice 'NANGUARD self-assert ok: all THREE guard sites switched to the working = ''NaN''::double precision idiom (0182 precedent) — the level + affinity knobs in calculate_expedition_stats (exactly 2 NaN-floor sites) and the idle-regen knob in process_mainship_expeditions (exactly 1); the dead x <> x arm is gone at every knob site; every accumulated 0115/0122/0170/0180/0193/0196 + 0169/0197 hunk survives the re-create; no random(); ACLs server-only; all three knobs still committed ''0'' (behaviorally inert at seed — the fix bites only a post-flip bad knob write)';
end $$;
