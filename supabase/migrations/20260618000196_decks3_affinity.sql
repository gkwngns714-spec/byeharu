-- Byeharu — DECKS-3 (DECKS packet, slice 3): STATION AFFINITY BONUSES — a captain whose
-- specialization matches their held station's affinity_specialization (ship_stations, 0189:
-- Gunnery=combat, Engineering=mining, Logistics=trade, Sensors=exploration, Medbay=support,
-- Bridge=NULL) has THAT captain's stats_json contribution scaled by (1 + cfg_num(
-- 'station_affinity_bonus')) inside calculate_expedition_stats — EXACTLY the shape of the shipped
-- captain-level fold (0180): a knob-gated multiplier on the captain-contributed portion only,
-- seeded '0' → ×(1 + 0) = ×1.0 byte-inert, prosrc-pinned scale sites. Everything ships DARK/INERT
-- behind the zero-seeded knob; the proposed flip value is 0.15 [owner-tunable — DOCUMENTED, never
-- seeded: ACT-DECKS3 is one set_game_config write].
--
-- ── TRUE HEAD (grep-verified across ALL migrations before writing a line) ────────────────────────
--   · calculate_expedition_stats → **0193** (SOUL-1, just merged: creates at 0044 → 0115 → 0122 →
--     0170 → 0180 → 0193; nothing after 0193 re-creates it). This migration re-creates from THE
--     0193 BODY with marked `-- DECKS-3 (0196)` hunks ONLY — the accumulated-hunk law: the body
--     below carries EVERY prior hunk (0115 modules / 0122 captains / 0170 hull stats / 0180 level
--     fold / 0193 trait fold), extract-and-diff verified, and the 0180 + 0193 prosrc pins are
--     RE-RUN in §3 so a dropped hunk cannot land.
--   ██ COLLISION NOTES (numbering + proof — RESOLVED at this slice's rebase; actual landing order):
--   · 0194 LANDED as SHIPYARD-2 (PR #138 — its renumber per the 0193 header choreography) while
--     this slice was in flight. SHIPYARD-2 re-creates port_entry_commission_build (never the
--     adapter) and carries its own proof file — function sets disjoint, no proof collision:
--     this slice's rebase over it changed nothing here.
--   · 0195 LANDED as SHIELD-1 (PR #139) while this slice was in flight — this migration
--     RENUMBERED 0195 → 0196. SHIELD-1's engine re-creates are the 0168/0169 combat heads — NOT
--     the adapter — so the 0193 true head above still stands (re-grepped post-rebase). SHIELD-1's
--     team-command-proof marker landed as the 22nd; this slice's DECKS3 block reconciled to the
--     23rd slot, both-blocks-kept (the SOUL-1/TEAMMOVE precedent).
--
-- ── THE FOLD (the 0180 gated-knob idiom, mirrored exactly) ───────────────────────────────────────
-- Per captain: contribution × v_lvl_mult × v_aff_mult, where
--     v_aff_mult = CASE WHEN <held station's affinity_specialization> = <captain's specialization>
--                       THEN 1 + station_affinity_bonus ELSE 1 END
--   · the KNOB is read ONCE at entry (the 0180 v_growth / v_lvl_bonus posture: a mid-scan config
--     write must never split one ship's captains across two regimes; never a knob read per row),
--     floored at 0 (a mis-set negative value never makes a matched station a nerf), mirroring the
--     0180 guard SHAPE for parity — HONESTY NOTE (hostile review M1): the `x <> x` NaN-detect arm
--     of that shape is a NO-OP in PostgreSQL ('NaN'::float8 = 'NaN'::float8 is TRUE — PG deviates
--     from IEEE 754), so the arm is unreachable and a knob mis-set to "NaN" WOULD poison matched
--     captains' stats. Kept byte-for-byte anyway (0180 head parity outweighs a mid-slice idiom
--     fork); the NANGUARD follow-up (FULL_CAPACITY_PLAN queue row 20) fixes 0180 + this site
--     together to the working `= 'NaN'::float8` idiom, self-assert pins included;
--   · the station is reached by ONE added LEFT join (ship_captain_assignments.station →
--     ship_stations.affinity_specialization, 0189). LEFT, deliberately: an UNSTATIONED row
--     (station NULL = general quarters) must keep folding at ×1.0 — an inner join would silently
--     DROP that captain's whole contribution (a dark-parity breach). Post-0189 no live writer can
--     produce a station-NULL row (the sole writer always resolves a station; the backfill nulled
--     none; unassign deletes the row) — the LEFT join is defense-in-depth, prosrc-pinned;
--   · the captain's specialization is the 0117 catalog column captain_types.specialization —
--     ALREADY in the loop's join/select (0122 head); no new read for it. The 0189 CHECK pins the
--     two columns to the same vocabulary, so a match is always a legal comparison;
--   · NULL never matches: NULL = 'combat' IS NULL in SQL → the CASE takes the ELSE arm — so an
--     unstationed captain (NULL station → NULL affinity via the LEFT join) and a no-affinity
--     station (the Bridge, affinity NULL by seed) both fold at EXACTLY 1.0, never a knob read,
--     the same no-match branch as a plain mismatch (combat captain in Medbay);
--   · the multiplier composes at the EXISTING 0180 scale sites — the eight stats_json contribution
--     reads become `× v_lvl_mult × v_aff_mult` (multiplication commutes, so the order cannot
--     change the sum; the TOKEN order is the pin — `* v_lvl_mult * v_aff_mult`, exactly 8 sites,
--     asserted below). ONE multiplier, NO second captain loop, NO tradeoff scaling (the
--     specialization attention/speed CASEs stay affinity-flat: a matched station is never a
--     stealth cost raise — the 0180 law verbatim).
-- DOUBLE-INERT (the 0180 double-inertness law): knob committed '0' → v_aff_mult = 1 + 0 = ×1.0
-- EXACTLY on every captain regardless of station (this migration's deploy posture — byte-parity
-- with the 0193 head, every existing proof pin CAPLEVEL/COMBATPARITY/TEAMSTATS/SOUL1 runs knob-0
-- and stays byte-valid unreconciled); no match → ×1.0 EXACTLY regardless of the knob. Like 0180,
-- this delta necessarily MODIFIES the eight fold lines (a multiplicative scale cannot be expressed
-- as added lines — stated honestly); no other pre-existing line of the 0193 body changes.
--
-- ── LIVE-SURFACE HONESTY (what changes when this deploys): NOTHING ───────────────────────────────
-- The knob ships '0', so every adapter consumer — the solo preview (0049/0159), the D0 group
-- totals (0165/0166), the D2 encounter snapshots (0168) — answers byte-identically to the 0193
-- head. At the PROPOSED flip value 0.15 [owner-tunable]: a level-1 gunnery_veteran (0117:
-- attack 4, specialization combat) holding Gunnery contributes 4 × 1.15 = 4.6 attack; the same
-- captain in Medbay/Bridge/general quarters contributes 4 exactly. Composed with the 0180 level
-- fold when growth is lit: a level-2 match contributes 4 × 1.1 × 1.15 = 5.06. Proof = the
-- TEAMCMD_PASS_DECKS3 block in scripts/team-command-proof.{sql,sh} (knob-0 byte-parity on a
-- stationed MATCHING captain; the exact lit bonus composed with a REAL level multiplier;
-- mismatch/Bridge byte-identity; the unstationed arm pinned structurally — no writer can produce
-- the row post-0189 and the harness honors the Captain sole-writer law).
--
-- Forward-only: 0001–0193 unedited (0194 left to SHIPYARD-2).

-- ── 1) the station-affinity knob — seeded '0' (BYTE-INERT: ×(1+0) = ×1.0 exactly) ────────────────
insert into public.game_config (key, value, description) values
  ('station_affinity_bonus', '0',
   'DECKS-3 (0196): bonus multiplier step for an assigned captain whose specialization matches '
   'their held station''s affinity_specialization (ship_stations, 0189) in '
   'calculate_expedition_stats — that captain''s stats_json contribution × (1 + this), composed '
   'with the 0180 level multiplier at the same scale sites. Seeded 0 → ×1.0 exactly (deploy-inert '
   'both arms: knob 0, or no match — unstationed / Bridge / mismatch — is ×1.0 regardless). '
   'Floored at 0 by the adapter (a negative value never nerfs); tradeoffs stay affinity-flat. '
   'PROPOSED flip value 0.15 [owner-tunable — ACT-DECKS3 is one set_game_config write].')
on conflict (key) do nothing;

-- ── 2) calculate_expedition_stats — THE 0193 BODY re-created with the marked DECKS-3 hunks ───────
-- PARITY DISCIPLINE: byte-identical to the 0193 head EXCEPT the marked `-- DECKS-3 (0196)` hunks
-- (three added declares; ONE added LEFT join + ONE added select column in the captain loop; the
-- per-captain multiplier assignment; ` * v_aff_mult` appended to the EIGHT existing 0180 scale
-- sites). Reviewers: extract §C of 20260618000193_soul1_fold.sql and diff — everything outside a
-- marked hunk is byte-identical, every accumulated hunk (0115/0122/0170/0180/0193) present.
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
  -- re-read. HONESTY NOTE (hostile review M1) on the `x <> x` arm here AND in the inherited 0180
  -- comment/declare above: it is a NO-OP in PostgreSQL — 'NaN'::float8 = 'NaN'::float8 is TRUE
  -- (PG deviates from IEEE 754) — so the arm is unreachable and a knob mis-set to "NaN" WOULD
  -- poison the folded stats. Kept byte-for-byte anyway: 0180 head parity outweighs a mid-slice
  -- idiom fork. The NANGUARD follow-up (FULL_CAPACITY_PLAN queue row 20) fixes BOTH adapters'
  -- guards to the working `= 'NaN'::float8` idiom together with their pinned self-asserts.
  v_aff_bonus_raw   double precision := coalesce(public.cfg_num('station_affinity_bonus'), 0);
  v_aff_bonus       numeric := greatest(0, case when v_aff_bonus_raw <> v_aff_bonus_raw then 0 else v_aff_bonus_raw end)::numeric;
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

-- ── 3) Self-asserts — the migration proves its own grounding or refuses to land ─────────────────
do $$
declare
  v_src text;
  v_val text;
  v_n   integer;
  v_tok text;
begin
  -- 1. DEPLOY-TIME INERTNESS: the knob is committed AND reads exactly 0 through the SAME accessor
  --    the adapter uses — so v_aff_bonus = greatest(0, 0) = 0 and every v_aff_mult is 1 + 0 = ×1.0
  --    EXACTLY, whatever the stations say (the seeded-zero arm of the 0180 double-inertness law;
  --    the no-match arm is ×1.0 by the CASE ELSE regardless of the knob). A non-zero value at
  --    migration time would mean the knob was lit early — fail the deploy, force a human decision.
  select value #>> '{}' into v_val from public.game_config where key = 'station_affinity_bonus';
  if v_val is null then
    raise exception 'DECKS-3 self-assert FAIL: station_affinity_bonus is not seeded';
  end if;
  if public.cfg_num('station_affinity_bonus') is distinct from 0::double precision then
    raise exception 'DECKS-3 self-assert FAIL: station_affinity_bonus reads % at migration time (want exactly 0 — DECKS-3 must ship byte-inert; the 0.15 proposal is ACT-DECKS3''s, a human flip)', v_val;
  end if;

  -- 2. THE GROUNDING the match rides on (re-asserted from 0189, the 0193 catalog-re-assert
  --    posture): the six-station catalog with the locked affinity mapping — five affinity
  --    stations in the 0117 specialization vocabulary + the NULL-affinity bridge.
  select count(*) into v_n from public.ship_stations;
  if v_n <> 6 then
    raise exception 'DECKS-3 self-assert FAIL: ship_stations holds % rows (want the frozen 6 — the 0189 seed)', v_n;
  end if;
  select count(*) into v_n
    from (values ('bridge', null::text), ('gunnery','combat'), ('engineering','mining'),
                 ('logistics','trade'), ('sensors','exploration'), ('medbay','support')) w(id, aff)
    join public.ship_stations s
      on s.station_id = w.id and s.affinity_specialization is not distinct from w.aff;
  if v_n <> 6 then
    raise exception 'DECKS-3 self-assert FAIL: the 0189 affinity mapping drifted (% of 6 verbatim) — the bonus would land on the wrong decks', v_n;
  end if;

  -- 3. THE ADAPTER FOLD: prosrc pins — the knob read ONCE at entry with the 0180 guard/floor
  --    SHAPE (shape parity — the x <> x arm is a PG no-op, see the NANGUARD note above; the
  --    NANGUARD slice updates this pin when it fixes both sites); ONE LEFT station join (never inner — an unstationed row must keep folding); ONE
  --    no-match CASE whose ELSE is the literal 1; the composed `* v_lvl_mult * v_aff_mult` token
  --    at EXACTLY the 8 existing scale sites and nowhere else (tradeoffs affinity-flat); no
  --    random(); and EVERY 0180 + 0193 pin re-run on this re-create (the accumulated-hunk law).
  select prosrc into v_src from pg_proc
    where oid = 'public.calculate_expedition_stats(uuid, uuid, jsonb, text)'::regprocedure;
  -- the once-at-entry knob read (exactly one read site — never per row):
  v_tok := 'cfg_num(''station_affinity_bonus'')';
  v_n := (length(v_src) - length(replace(v_src, v_tok, ''))) / length(v_tok);
  if v_n <> 1 then
    raise exception 'DECKS-3 self-assert FAIL: % station_affinity_bonus read sites (want exactly 1 — the knob is read ONCE at entry, never per captain)', v_n;
  end if;
  if position('case when v_aff_bonus_raw <> v_aff_bonus_raw then 0 else v_aff_bonus_raw end' in v_src) = 0
     or position('greatest(0, case when v_aff_bonus_raw' in v_src) = 0 then
    raise exception 'DECKS-3 self-assert FAIL: the affinity knob lacks the 0180 guard-shape + floor posture (shape parity — see the NANGUARD note: the x <> x arm is a PG no-op)';
  end if;
  -- the ONE LEFT station join (defense-in-depth: a station-NULL row folds at ×1.0, never drops):
  v_tok := 'left join ship_stations st on st.station_id = a.station';
  v_n := (length(v_src) - length(replace(v_src, v_tok, ''))) / length(v_tok);
  if v_n <> 1 then
    raise exception 'DECKS-3 self-assert FAIL: % ship_stations join sites (want exactly 1, LEFT — an inner join would drop an unstationed captain''s whole contribution)', v_n;
  end if;
  v_tok := 'join ship_stations';
  v_n := (length(v_src) - length(replace(v_src, v_tok, ''))) / length(v_tok);
  if v_n <> 1 then
    raise exception 'DECKS-3 self-assert FAIL: % ship_stations join tokens (want exactly 1 — the ONE LEFT join above; a second/inner join site is a breach)', v_n;
  end if;
  -- the ONE no-match CASE (NULL affinity — unstationed or the bridge — and any mismatch all take
  -- the literal-1 ELSE; NULL = x is NULL in SQL, so no knob arm is reachable without a match):
  v_tok := 'v_aff_mult := case when c.affinity_specialization = c.specialization then 1 + v_aff_bonus else 1 end';
  v_n := (length(v_src) - length(replace(v_src, v_tok, ''))) / length(v_tok);
  if v_n <> 1 then
    raise exception 'DECKS-3 self-assert FAIL: % affinity-multiplier assignment sites (want exactly 1 — ONE multiplier, no second captain loop)', v_n;
  end if;
  -- the composed scale sites: exactly 8, all of them the existing 0180 sites, none anywhere else.
  v_tok := '* v_lvl_mult * v_aff_mult';
  v_n := (length(v_src) - length(replace(v_src, v_tok, ''))) / length(v_tok);
  if v_n <> 8 then
    raise exception 'DECKS-3 self-assert FAIL: % "* v_lvl_mult * v_aff_mult" composed scale sites (want exactly 8 — the affinity multiplier rides the 0180 sites)', v_n;
  end if;
  v_tok := '* v_aff_mult';
  v_n := (length(v_src) - length(replace(v_src, v_tok, ''))) / length(v_tok);
  if v_n <> 8 then
    raise exception 'DECKS-3 self-assert FAIL: % "* v_aff_mult" scale sites (want exactly 8 — a ninth site would scale something that is not a captain stats_json contribution)', v_n;
  end if;
  if position('else 0 end) * v_aff_mult' in v_src) > 0 then
    raise exception 'DECKS-3 self-assert FAIL: a specialization tradeoff is affinity-scaled (tradeoffs stay affinity-flat — a matched station is never a stealth cost raise)';
  end if;
  if position('random(' in v_src) > 0 then
    raise exception 'DECKS-3 self-assert FAIL: the adapter contains random() (the 0041 determinism law)';
  end if;

  -- 4. THE 0180 CAPTAIN-LEVEL PINS, re-run (head-parity on the re-create):
  if position('v_lvl_mult := case when v_growth then 1 + (c.level - 1) * v_lvl_bonus else 1 end' in v_src) = 0 then
    raise exception 'DECKS-3 self-assert FAIL: the 0180 gated level-multiplier token vanished (head-parity breach)';
  end if;
  v_tok := '* v_lvl_mult';
  v_n := (length(v_src) - length(replace(v_src, v_tok, ''))) / length(v_tok);
  if v_n <> 8 then
    raise exception 'DECKS-3 self-assert FAIL: % "* v_lvl_mult" scale sites (want exactly 8 — the 0180 pin must survive the re-create)', v_n;
  end if;
  if position('else 0 end) * v_lvl_mult' in v_src) > 0 then
    raise exception 'DECKS-3 self-assert FAIL: a specialization tradeoff is level-scaled (0180 regression)';
  end if;

  -- 5. THE 0193 TRAIT-FOLD PINS, re-run (the accumulated-hunk law: every prior hunk must survive):
  if position('v_traits_enabled' in v_src) = 0 or position('if v_traits_enabled then' in v_src) = 0 then
    raise exception 'DECKS-3 self-assert FAIL: the 0193 knob-gated trait fold vanished (v_traits_enabled)';
  end if;
  v_tok := 'from main_ship_traits';
  v_n := (length(v_src) - length(replace(v_src, v_tok, ''))) / length(v_tok);
  if v_n <> 1 then
    raise exception 'DECKS-3 self-assert FAIL: % main_ship_traits read sites (want exactly 1 — the 0193 ONE-fold pin)', v_n;
  end if;
  v_tok := '(tr.stats_json->>';
  v_n := (length(v_src) - length(replace(v_src, v_tok, ''))) / length(v_tok);
  if v_n <> 8 then
    raise exception 'DECKS-3 self-assert FAIL: % trait stats_json reads (want exactly 8 — the 0193 shared-vocabulary pin)', v_n;
  end if;
  if position('select y.stats_json' in v_src) = 0 then
    raise exception 'DECKS-3 self-assert FAIL: the 0193 trait join no longer projects exactly stats_json';
  end if;
  if position('y.hp_mult' in v_src) > 0 or position('tt.hp_mult' in v_src) > 0
     or position('.hp_mult' in v_src) > 0 or position('>''hp_mult''' in v_src) > 0 then
    raise exception 'DECKS-3 self-assert FAIL: the adapter reads hp_mult (applied ONCE at roll time — an adapter read double-applies; 0193 regression)';
  end if;
  if position('(1 + v_mod_speed_bonus + v_cap_speed_bonus + v_trait_speed_bonus)' in v_src) = 0 then
    raise exception 'DECKS-3 self-assert FAIL: the ONE final-speed multiplier lost a contribution (0193 regression)';
  end if;
  if position('* tr.' in v_src) > 0 then
    raise exception 'DECKS-3 self-assert FAIL: a trait contribution is scaled (0193 regression — traits fold unscaled)';
  end if;
  -- the 0170 hull fold + 0115 module loop + 0122 captain loop survive (coarse but honest tokens):
  if position('(v_hull_stats->>''attack'')' in v_src) = 0
     or position('from ship_module_fittings f' in v_src) = 0
     or position('from ship_captain_assignments a' in v_src) = 0 then
    raise exception 'DECKS-3 self-assert FAIL: a 0115/0122/0170 hunk vanished from the re-create (accumulated-hunk law breach)';
  end if;

  -- 6. ACLs: the adapter stays server-only (the 0044..0193 posture, asserted not assumed).
  if has_function_privilege('authenticated', 'public.calculate_expedition_stats(uuid, uuid, jsonb, text)', 'execute')
     or has_function_privilege('anon', 'public.calculate_expedition_stats(uuid, uuid, jsonb, text)', 'execute') then
    raise exception 'DECKS-3 self-assert FAIL: calculate_expedition_stats is client-executable (must be server-only)';
  end if;
  if not has_function_privilege('service_role', 'public.calculate_expedition_stats(uuid, uuid, jsonb, text)', 'execute') then
    raise exception 'DECKS-3 self-assert FAIL: calculate_expedition_stats not granted to service_role';
  end if;

  raise notice 'DECKS-3 self-assert ok: station_affinity_bonus seeded + reads exactly 0 (deploy-inert: every v_aff_mult is ×1.0); 0189 six-station affinity mapping verbatim; the adapter carries ONE once-at-entry 0180-guard-shaped knob read (the x <> x arm is a PG no-op — NANGUARD queued), ONE LEFT station join, ONE no-match CASE (ELSE 1 — unstationed/bridge/mismatch all ×1.0), the composed multiplier at exactly the 8 existing scale sites with tradeoffs affinity-flat, no random(); every 0180 level pin + 0193 trait pin + 0115/0122/0170 hunk survives the re-create; ACL server-only';
end $$;
