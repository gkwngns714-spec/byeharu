-- Byeharu — SOUL-1 (SHIP-SOUL packet, slice 1): ship traits go FUNCTIONAL — the commission ROLL
-- HOOK (every new ship is born with its soul WHEN LIT — the P12 charter) + the adapter TRAIT FOLD
-- (calculate_expedition_stats folds each rolled trait's stats_json into the ONE accumulator set,
-- the 0122/0180 hunk discipline). Everything stays DARK behind `ship_traits_enabled='false'`
-- (0186): dark = ZERO roll calls and ZERO trait reads — byte-parity with the live heads. NO read
-- RPC, NO frontend (SOUL-2), NO backfill over existing ships (ACT-SOUL, with the catalog-freeze
-- precondition count=8 — the 0186 header's fixed-catalog determinism law).
--
-- ── TRUE HEADS (grep-verified across ALL migrations before writing a line; re-verified after the
--    0190 TEAMMOVE / 0191 SHIELD-0 rebase — neither re-creates any of the three) ──────────────────
--   · port_entry_commission_build   → 0184 (creates at 0080 → 0184; 0185/0188 only MENTION it).
--     ██ COLLISION NOTE (both directions, explicit): the in-flight SHIPYARD-2 slice (currently
--     numbered 0192) ALSO re-creates this function (hull delivery) from the 0184 head.
--     · If SHIPYARD-2 had landed first: THIS migration would rebase and re-apply its ONE marked
--       hunk on SHIPYARD-2's head (the hunk is deliberately minimal — a gated perform after the
--       ship insert).
--     · SOUL-1 IS LANDING FIRST, so at ITS rebase SHIPYARD-2 MUST:
--       (a) RENUMBER to >= 0194 — a 0192 applying AFTER this 0193 on prod would silently erase
--           this hook (last create-or-replace wins), and on fresh chains this 0193 applying after
--           a 0192 would erase SHIPYARD-2's delivery hunks; the number must order the re-creates
--           the same way everywhere; and
--       (b) re-create build from THIS migration's head (0193 = the 0184 body + the SOUL-1 hook),
--           so BOTH hunks coexist in its body — never from the stale 0184 head. ██
--   · ensure_main_ship_for_player   → 0078 (creates at 0043 → 0077 → 0078; 0184 only references).
--   · calculate_expedition_stats    → 0180 (creates at 0044 → 0115 → 0122 → 0170 → 0180;
--     0181..0191 never re-create it).
-- Both commission WRITERS delegate the insert to build (port_entry_commission_writer 0080 §B;
-- commission_additional_main_ship 0091), so ONE hook in build covers the first-ship AND
-- additional-ship paths. ensure_main_ship_for_player is the separate legacy service_role/CI
-- creator (0184 §3 note) — P12 says "every new ship is born with its soul", and the packet's
-- explicit reading is that a starter Sparrow deserves a soul too, so BOTH creators get the hook
-- (documented; the ensure hook fires ONLY on its create branch — an existing ship's replay must
-- never roll here, that retroactive roll is ACT-SOUL's, behind the catalog-freeze precondition).
--
-- ── THE HOOK (double-gated; definer-to-definer — the 0169 leaf-call pattern) ─────────────────────
-- After the ship insert: `if cfg_bool('ship_traits_enabled') then perform
-- soul_roll_traits_for_ship(<new ship>)`. The gate is checked HERE too even though the roll fn
-- gates first itself (0186): dark = ZERO calls into the roll fn — the commission path's write set
-- and envelope are byte-identical to the 0184/0078 heads. Execution context: the commission
-- functions are SECURITY DEFINER, so their bodies execute as the function OWNER (the migration
-- role), which may execute the service_role-only roll writer — exactly how 0169's authenticated
-- team_hunt_send calls the service-only 0152 leaf mainship_mark_legacy_in_flight; no ACL change.
-- The roll is deterministic + idempotent (0186), so a re-fired hook can never re-roll or re-raise
-- hp. Its envelope is discarded (`perform`): every failure code is impossible-by-construction here
-- (ship_not_found — we just inserted it; catalog_too_small — 8 rows migration-asserted at 0186 and
-- re-asserted below; feature_disabled — only under a mid-txn config race, in which case the roll
-- fails CLOSED to dark, and the deterministic idempotent roll remains re-runnable by ops/ACT-SOUL).
--
-- ── THE FOLD (the 0180 gated-knob idiom, mirrored) ───────────────────────────────────────────────
-- calculate_expedition_stats is re-created from its 0180 head with the marked SOUL-1 delta:
--   · three added declares (v_traits_enabled — the flag read ONCE at entry, the 0180 v_growth
--     posture: a mid-scan config write must never split one ship's read across regimes; tr; and
--     v_trait_speed_bonus);
--   · the ONE marked trait-fold hunk: when v_traits_enabled, each of the ship's main_ship_traits
--     rows' stats_json feeds the SAME accumulators in the SAME key vocabulary as the module loop
--     (attack/defense/repair/cargo/scan/mining/evasion + speed_mult_bonus, coalesced to 0 —
--     0180:212–219; ONE fold idiom reused, no second trait reader anywhere). The read is
--     KNOB-GATED: while dark the loop is skipped ENTIRELY (zero table reads);
--   · ` + v_trait_speed_bonus` appended inside the ONE final-speed multiplier — the only modified
--     pre-existing line (a speed contribution cannot be expressed as added lines; stated honestly,
--     the C2-2 precedent). Exactly + 0 while dark or trait-less, so the value is unchanged.
-- DOUBLE-INERT: flag false → the loop never runs (byte-identical output — every existing proof pin
-- COMBATPARITY/TEAMSTATS/CAPLEVEL/… runs dark and stays byte-valid); flag true + zero trait rows →
-- an empty loop (byte-identical output). PLACEMENT: directly after the 0170 hull-base fold —
-- traits are part of the SHIP ITSELF (birthmarks), another additive contribution ahead of the
-- equipment loops (modules/captains); every contribution is additive into one accumulator set, so
-- ORDER CANNOT CHANGE THE SUM — adjacency to the hull idiom is documentation, not arithmetic, and
-- the existing fold order (hull base → loadout → modules → captains → the one speed multiplier →
-- clamps) is undisturbed. NO tradeoff CASE: a trait's costs live IN its stats_json minus keys
-- (five of eight — the 0186 law-4 posture). hp_mult is NOT the adapter's business: it was applied
-- ONCE at roll time to max_hp by soul_roll_traits_for_ship (0186); the adapter never reads it
-- (prosrc-pinned below) — re-scaling would double-apply.
--
-- Forward-only: 0001–0191 unedited. Proof = the TEAMCMD_PASS_SOUL1 block in team-command-proof
-- (dark parity, lit fold exactness, commission + ensure hooks, hp_mult non-double-application),
-- with the SOUL0 block reconciled: its fixtures now commission BEFORE its in-txn flip (a lit
-- commission rolls at birth under this hook) and the gate is re-darkened before TEAMMAP (which
-- also keeps SHIELD0's leaf-smoke commission and TEAMMOVE's docked hop byte-identical).

-- ── A. port_entry_commission_build — copied VERBATIM from its TRUE head, migration 0184;
--      the ONLY change is the marked SOUL-1 hook hunk after the ship insert. ─────────────────────
create or replace function public.port_entry_commission_build(p_player uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c_haven  constant uuid := 'b1a00001-0066-4a00-8a00-000000000001';
  v_ship   uuid;
  v_zone   uuid;
  v_sector uuid;
  v_base   uuid;
  v_fleet  uuid;
begin
  -- Insert the ship DIRECTLY in canonical at_location shape (status='stationary',
  -- spatial_state='at_location', x/y NULL) so there is never a committed intermediate bare
  -- home/legacy_home row. No on-conflict: the CALLER already serialized + checked existence/cap.
  insert into public.main_ship_instances
    (player_id, hull_type_id, name, status, spatial_state, space_x, space_y,
     hp, max_hp, cargo_capacity, cargo_capacity_m3, support_capacity, captain_slots, module_slots)
  select p_player, h.hull_type_id,
         -- [0184 NAME HUNK — the ONLY change vs the 0080 head] EVE-style default: the class name
         -- ('Sparrow' — correct here because this function hardcodes the starter_frigate hull),
         -- plus a per-player roman numeral from the SECOND ship on ('Sparrow', 'Sparrow II', …).
         -- Safe: every caller holds the per-player commission advisory lock before build.
         'Sparrow' || (select case when count(*) = 0 then ''
                                   else ' ' || to_char(count(*) + 1, 'FMRN') end
                         from public.main_ship_instances m where m.player_id = p_player),
         'stationary', 'at_location', null, null,
         h.base_hp, h.base_hp, h.base_cargo_capacity, h.base_cargo_capacity_m3, h.base_support_capacity, h.base_captain_slots, h.base_module_slots
    from public.main_ship_hull_types h
    where h.hull_type_id = 'starter_frigate'
  returning main_ship_id into v_ship;

  if v_ship is null then
    return jsonb_build_object('created', false);     -- hull row missing / nothing inserted
  end if;

  -- SOUL-1 (0193) HOOK: every new ship is born with its soul WHEN LIT (P12). Double-gated — the
  -- gate is checked HERE (dark = ZERO calls, byte-parity with the 0184 head) AND the roll fn
  -- gates first itself (0186). Definer-to-definer (the 0169 leaf-call pattern): this SECURITY
  -- DEFINER body executes as the function owner, which may execute the service_role-only roll
  -- writer. Deterministic + idempotent (0186) — a re-fired hook can never re-roll or re-raise hp;
  -- the envelope is discarded (failure codes impossible-by-construction here; a mid-txn config
  -- race fails CLOSED to dark and stays re-runnable). hp_mult lands here, once, via the roll.
  if public.cfg_bool('ship_traits_enabled') then
    perform public.soul_roll_traits_for_ship(v_ship);
  end if;
  -- END SOUL-1 (0193) hook — everything below is the 0184 head, byte-identical.

  -- ── Phase B: lock the Haven Reach target hierarchy in the canonical order (sector → zone → location →
  --    anchor → docking service, FOR SHARE — conflicts with a status disable/retire) and REVALIDATE legality
  --    through the single canonical rule AFTER the locks are held, immediately before the fleet/presence write.
  select l.zone_id, z.sector_id into v_zone, v_sector
    from public.locations l join public.zones z on z.id = l.zone_id
    where l.id = c_haven;
  if v_zone is null then
    raise exception 'port_entry_commission: Haven Reach location not found';
  end if;
  perform 1 from public.sectors           where id = v_sector for share;
  perform 1 from public.zones             where id = v_zone   for share;
  perform 1 from public.locations         where id = c_haven  for share;
  perform 1 from public.space_anchors     where location_id = c_haven and kind = 'location' and status = 'active' for share;
  perform 1 from public.location_services where location_id = c_haven and service = 'docking' and status = 'active' for share;

  if (public.mainship_space_location_target_legal(c_haven)->>'ok')::boolean is not true then
    raise exception 'port_entry_commission: Haven Reach is not dockable';   -- rolls back the ship insert (atomic)
  end if;

  -- exactly ONE present/location fleet at Haven (origin_base_id = the player's base if one exists, else NULL —
  -- NOT a home-port assignment; current_base_id stays NULL, matching a docked OSN fleet).
  select id into v_base from public.bases where player_id = p_player and status = 'active' order by created_at limit 1;
  v_fleet := gen_random_uuid();
  insert into public.fleets
    (id, player_id, origin_base_id, status, location_mode, current_base_id,
     current_location_id, current_zone_id, current_sector_id, main_ship_id)
  values (v_fleet, p_player, v_base, 'present', 'location', null,
          c_haven, v_zone, v_sector, v_ship);

  -- exactly ONE active presence through the established presence path (activity 'none', like the dock writer).
  perform public.presence_create(p_player, v_fleet, v_sector, v_zone, c_haven, 'none');

  -- final coherence gate: the ship MUST now be canonical at_location, else abort the whole transaction.
  if (public.mainship_space_validate_context(v_ship)->>'state') is distinct from 'at_location' then
    raise exception 'port_entry_commission: post-write state is not canonical at_location';
  end if;

  return jsonb_build_object('created', true, 'main_ship_id', v_ship, 'location_id', c_haven);
end;
$$;

-- ── B. ensure_main_ship_for_player — copied VERBATIM from its TRUE head, migration 0078;
--      the ONLY changes are the marked SOUL-1 declare + hook hunk inside the create branch. ──────
create or replace function public.ensure_main_ship_for_player(p_player uuid)
returns public.main_ship_instances
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ship public.main_ship_instances%rowtype;
  -- SOUL-1 (0193): the just-created ship id, captured so the gated roll hook fires ONLY on the
  -- create branch (an existing ship's idempotent replay must NEVER roll here — the retroactive
  -- roll over pre-existing ships is ACT-SOUL's, behind the catalog-freeze precondition).
  v_new  uuid;
begin
  -- Race-safe first-ship serialization per player (replaces the `on conflict (player_id)` guard so it is
  -- correct with OR without the player_id UNIQUE index): hold the per-player commission lock, then create
  -- ONLY if the player has zero ships. Never creates a 2nd ship implicitly.
  perform pg_advisory_xact_lock(hashtext('main_ship_commission'), hashtext(p_player::text));
  if not exists (select 1 from main_ship_instances where player_id = p_player) then
    insert into main_ship_instances
      (player_id, hull_type_id, hp, max_hp, cargo_capacity, cargo_capacity_m3, support_capacity, captain_slots, module_slots)
    select p_player, h.hull_type_id, h.base_hp, h.base_hp, h.base_cargo_capacity, h.base_cargo_capacity_m3,
           h.base_support_capacity, h.base_captain_slots, h.base_module_slots
      from main_ship_hull_types h
      where h.hull_type_id = 'starter_frigate'
    returning main_ship_id into v_new;   -- SOUL-1 (0193): capture for the hook (was a bare insert)

    -- SOUL-1 (0193) HOOK: starter ships get souls too (P12: "every new ship is born with its
    -- soul" — a starter Sparrow deserves one). Same double-gated, definer-to-definer, discard-
    -- envelope shape as the port_entry_commission_build hook above; fires ONLY when THIS call
    -- created the ship (v_new not null — the create branch). NESTED ifs, not AND: PG does not
    -- guarantee AND evaluation order, so the gate read must sit provably INSIDE the
    -- create-branch check — the replay path takes ZERO added reads.
    if v_new is not null then
      if public.cfg_bool('ship_traits_enabled') then
        perform public.soul_roll_traits_for_ship(v_new);
      end if;
    end if;
    -- END SOUL-1 (0193) hook — everything else is the 0078 head, byte-identical.
  end if;

  select * into v_ship from main_ship_instances where player_id = p_player;
  return v_ship;
end;
$$;

-- ── C. calculate_expedition_stats — 0180 head re-created with the marked SOUL-1 trait fold ──────
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

-- ── ACL — re-asserted for the re-created adapter (the 0044/0115/0122/0170/0180 posture verbatim:
--    server-only, service_role, NEVER clients — only the get_my_expedition_preview wrapper
--    (0049/0159) is client-exposed). The TARGETED idiom. The two commission functions keep their
--    prior grants via create-or-replace (the 0078/0184 posture — no grant/revoke needed there;
--    asserted below anyway). ────────────────────────────────────────────────────────────────────
revoke execute on function public.calculate_expedition_stats(uuid, uuid, jsonb, text) from public, anon, authenticated;
grant  execute on function public.calculate_expedition_stats(uuid, uuid, jsonb, text) to service_role;

-- ── D. Self-asserts — the migration proves its own grounding or refuses to land ─────────────────
do $$
declare
  v_src text;
  v_def text;
  v_n   integer;
  v_tok text;
begin
  -- 1. DEPLOY-TIME DOUBLE INERTNESS: the 0186 gate is still dark AND no ship has ever been rolled
  --    (the roll fn has had NO caller until this migration, and this migration ships dark). Either
  --    arm alone keeps both the hook and the fold byte-inert; both failing at deploy time would
  --    mean the flag was lit early — fail the deploy and force a human decision.
  if public.cfg_bool('ship_traits_enabled') then
    raise exception 'SOUL-1 self-assert FAIL: ship_traits_enabled is true at migration time (SOUL-1 must ship dark)';
  end if;
  select count(*) into v_n from public.main_ship_traits;
  if v_n <> 0 then
    raise exception 'SOUL-1 self-assert FAIL: main_ship_traits holds % rows at deploy time (want 0 — nothing has rolled yet)', v_n;
  end if;
  -- the fixed-catalog grounding the hook's roll relies on (re-asserted from 0186): exactly 8.
  select count(*) into v_n from public.ship_trait_types;
  if v_n <> 8 then
    raise exception 'SOUL-1 self-assert FAIL: trait catalog holds % rows (want the frozen 8 — the 0186 seed)', v_n;
  end if;

  -- 2. THE COMMISSION HOOK (build): gated call present, exactly once; the 0184 head is intact
  --    (Sparrow naming expression retained, no ''Byeharu'' literal anywhere on the surface).
  v_def := pg_get_functiondef('public.port_entry_commission_build(uuid)'::regprocedure);
  if position('if public.cfg_bool(''ship_traits_enabled'') then' in v_def) = 0 then
    raise exception 'SOUL-1 self-assert FAIL: build lacks the gated hook (the gate must be checked at the call site too — dark = zero calls)';
  end if;
  v_tok := 'perform public.soul_roll_traits_for_ship(';
  v_n := (length(v_def) - length(replace(v_def, v_tok, ''))) / length(v_tok);
  if v_n <> 1 then
    raise exception 'SOUL-1 self-assert FAIL: build carries % roll-hook call site(s) (want exactly 1)', v_n;
  end if;
  if position('''Sparrow''' in v_def) = 0 then
    raise exception 'SOUL-1 self-assert FAIL: build lost the 0184 Sparrow naming expression (head-parity breach)';
  end if;
  if position('''Byeharu''' in v_def) > 0 then
    raise exception 'SOUL-1 self-assert FAIL: build re-grew the ''Byeharu'' literal (0184 regression)';
  end if;

  -- 3. THE ENSURE HOOK: gated call present, exactly once, INSIDE the create branch (textually
  --    before the final player-scoped select — the create-branch shape; the proof pins the
  --    behavior: an existing unrolled ship's replay must never roll).
  v_def := pg_get_functiondef('public.ensure_main_ship_for_player(uuid)'::regprocedure);
  -- NESTED shape (review N1): the create-branch check wraps the gate read, which wraps the roll —
  -- pinned by token presence + strict textual nesting order (v_new check < gate read < perform),
  -- so the gate read provably never fires on the replay path (never an AND — PG does not
  -- guarantee AND evaluation order).
  if position('if v_new is not null then' in v_def) = 0
     or position('if public.cfg_bool(''ship_traits_enabled'') then' in v_def) = 0
     or position('if v_new is not null then' in v_def)
        >= position('if public.cfg_bool(''ship_traits_enabled'') then' in v_def)
     or position('if public.cfg_bool(''ship_traits_enabled'') then' in v_def)
        >= position('perform public.soul_roll_traits_for_ship(' in v_def) then
    raise exception 'SOUL-1 self-assert FAIL: ensure lacks the NESTED create-branch-gated hook (v_new check wrapping the gate read wrapping the roll)';
  end if;
  if position(' and public.cfg_bool(''ship_traits_enabled'')' in v_def) > 0 then
    raise exception 'SOUL-1 self-assert FAIL: the ensure gate read rides an AND (must be nested — AND evaluation order is not guaranteed)';
  end if;
  v_tok := 'perform public.soul_roll_traits_for_ship(';
  v_n := (length(v_def) - length(replace(v_def, v_tok, ''))) / length(v_tok);
  if v_n <> 1 then
    raise exception 'SOUL-1 self-assert FAIL: ensure carries % roll-hook call site(s) (want exactly 1)', v_n;
  end if;
  if position('returning main_ship_id into v_new' in v_def) = 0
     or position(v_tok in v_def) < position('returning main_ship_id into v_new' in v_def)
     or position(v_tok in v_def) > position('select * into v_ship from main_ship_instances where player_id' in v_def) then
    raise exception 'SOUL-1 self-assert FAIL: the ensure hook is not inside the create branch (after the captured insert, before the final select)';
  end if;

  -- 4. THE ADAPTER FOLD: prosrc pins — the gated trait read exists exactly once (ONE fold idiom,
  --    no second trait reader), reads exactly the 8 shared-vocabulary keys, never reads hp_mult
  --    (non-double-application), joins the speed contribution inside the ONE multiplier, and the
  --    0180 captain-level pins still hold on this re-create (nothing else drifted).
  select prosrc into v_src from pg_proc
    where oid = 'public.calculate_expedition_stats(uuid, uuid, jsonb, text)'::regprocedure;
  if position('v_traits_enabled' in v_src) = 0 or position('if v_traits_enabled then' in v_src) = 0 then
    raise exception 'SOUL-1 self-assert FAIL: the adapter lacks the knob-gated trait fold (v_traits_enabled)';
  end if;
  v_tok := 'from main_ship_traits';
  v_n := (length(v_src) - length(replace(v_src, v_tok, ''))) / length(v_tok);
  if v_n <> 1 then
    raise exception 'SOUL-1 self-assert FAIL: % main_ship_traits read sites in the adapter (want exactly 1 — the ONE fold idiom)', v_n;
  end if;
  v_tok := '(tr.stats_json->>';
  v_n := (length(v_src) - length(replace(v_src, v_tok, ''))) / length(v_tok);
  if v_n <> 8 then
    raise exception 'SOUL-1 self-assert FAIL: % trait stats_json reads (want exactly 8 — the shared 0180 vocabulary: 7 accumulators + speed_mult_bonus)', v_n;
  end if;
  -- non-double-application: the trait join projects ONLY stats_json, and no hp_mult COLUMN READ
  -- exists (the token is alias-qualified / operator forms — prose mentions in comments don't count).
  if position('select y.stats_json' in v_src) = 0 then
    raise exception 'SOUL-1 self-assert FAIL: the trait fold does not project exactly the stats_json column';
  end if;
  if position('y.hp_mult' in v_src) > 0 or position('tt.hp_mult' in v_src) > 0
     or position('.hp_mult' in v_src) > 0 or position('>''hp_mult''' in v_src) > 0 then
    raise exception 'SOUL-1 self-assert FAIL: the adapter reads hp_mult (it was applied ONCE at roll time — an adapter read double-applies)';
  end if;
  if position('(1 + v_mod_speed_bonus + v_cap_speed_bonus + v_trait_speed_bonus)' in v_src) = 0 then
    raise exception 'SOUL-1 self-assert FAIL: the trait speed contribution is not inside the ONE final-speed multiplier';
  end if;
  -- 0180 head-parity retained (the C2-2 pins re-run on this re-create):
  if position('v_lvl_mult := case when v_growth then 1 + (c.level - 1) * v_lvl_bonus else 1 end' in v_src) = 0 then
    raise exception 'SOUL-1 self-assert FAIL: the 0180 gated level-multiplier token vanished (head-parity breach)';
  end if;
  v_tok := '* v_lvl_mult';
  v_n := (length(v_src) - length(replace(v_src, v_tok, ''))) / length(v_tok);
  if v_n <> 8 then
    raise exception 'SOUL-1 self-assert FAIL: % "* v_lvl_mult" scale sites (want exactly 8 — the 0180 pin must survive the re-create)', v_n;
  end if;
  if position('else 0 end) * v_lvl_mult' in v_src) > 0 then
    raise exception 'SOUL-1 self-assert FAIL: a specialization tradeoff is level-scaled (0180 regression)';
  end if;
  -- the trait fold takes NO tradeoff CASE and NO qty/slot scaling (birthmarks: costs live in the
  -- minus keys): no "* tr." scale token may exist.
  if position('* tr.' in v_src) > 0 then
    raise exception 'SOUL-1 self-assert FAIL: a trait contribution is scaled (traits fold unscaled — costs live in minus keys)';
  end if;

  -- 5. ACLs: the adapter stays server-only; both commission functions stay service_role-only
  --    (grants preserved by create-or-replace, asserted not assumed); the roll fn is untouched.
  if has_function_privilege('authenticated', 'public.calculate_expedition_stats(uuid, uuid, jsonb, text)', 'execute')
     or has_function_privilege('anon', 'public.calculate_expedition_stats(uuid, uuid, jsonb, text)', 'execute') then
    raise exception 'SOUL-1 self-assert FAIL: calculate_expedition_stats is client-executable (must be server-only)';
  end if;
  if not has_function_privilege('service_role', 'public.calculate_expedition_stats(uuid, uuid, jsonb, text)', 'execute') then
    raise exception 'SOUL-1 self-assert FAIL: calculate_expedition_stats not granted to service_role';
  end if;
  if has_function_privilege('anon', 'public.port_entry_commission_build(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.port_entry_commission_build(uuid)', 'execute') then
    raise exception 'SOUL-1 self-assert FAIL: port_entry_commission_build became client-executable (create-or-replace must preserve the 0080 ACL)';
  end if;
  if has_function_privilege('anon', 'public.ensure_main_ship_for_player(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.ensure_main_ship_for_player(uuid)', 'execute') then
    raise exception 'SOUL-1 self-assert FAIL: ensure_main_ship_for_player became client-executable (create-or-replace must preserve the 0043 ACL)';
  end if;
  if has_function_privilege('anon', 'public.soul_roll_traits_for_ship(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.soul_roll_traits_for_ship(uuid)', 'execute') then
    raise exception 'SOUL-1 self-assert FAIL: the roll writer became client-executable (0186 regression)';
  end if;

  raise notice 'SOUL-1 self-assert ok: gate dark + zero rolled rows + catalog frozen at 8 (deploy-time double inertness); build + ensure carry exactly one gated roll hook each (ensure''s inside the create branch; Sparrow naming intact); the adapter carries the ONE knob-gated trait fold (1 read site, 8 shared-vocabulary keys, no hp_mult read, speed inside the one multiplier, traits unscaled) with every 0180 captain-level pin surviving the re-create; ACLs server-only across the board';
end $$;
