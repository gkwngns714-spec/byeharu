-- Byeharu — MOD2-1 (FULL_CAPACITY_PLAN §C P7, queue #11): the shield line + mining rig module
-- seeds — a PURE CATALOG SEED slice. Two new module_types + their recipes; ZERO engine edits
-- (no RPC, no adapter re-create, no schema change, no flag flip, no frontend). All stats flow
-- through the EXISTING pipeline: module_types.stats_json → the fitting adapter's module loop
-- (calculate_expedition_stats, TRUE head 0180 — creates at 0044→0115→0122→0170→0180,
-- grep-verified) → the Σ slot_cost ≤ module_slots reject-never-clamp cap (0115/0112).
--
-- STAT-KEY VERIFICATION (the whole slice hinges on this — a typo'd key is a dead module):
--   the 0180 head's module loop reads EXACTLY these stats_json keys, coalesced to 0:
--     attack / defense / repair / cargo / scan / mining / evasion + speed_mult_bonus
--   and folds them into the SAME accumulators as support craft / hull / captains:
--     (m.stats_json->>'defense')::numeric → a_survival → output key 'survival'   (0180:213/310)
--     (m.stats_json->>'mining')::numeric  → a_mining   → output key 'mining_yield' (0180:217/313)
--   So the shield seeds `defense` (NOT "survival" — survival is the OUTPUT key; the hull's
--   base_stats_json uses the same input vocabulary {attack, defense}, 0170) and the rig seeds
--   `mining`. Self-asserted below against pg_proc.prosrc of the DEPLOYED adapter body.
--
-- SLOT_TYPE — two NEW archetypes, 'defense' and 'mining' (additive by design: 0107 (b) —
-- slot_type is unconstrained Reference/Config metadata, "new archetypes are additive later, no
-- CHECK to migrate"). TRADEOFF POSTURE (deliberate, grounded in the 0115 CASE): the adapter's
-- slot_type tradeoff rules cover weapon/cargo/sensor; every other archetype takes the permissive
-- `else 0` arm — stats yes, tradeoff 0 — exactly like 'engine' ("the engine's cost is the slot
-- itself", 0115 (5)). The shield/rig inherit that engine posture. Taxing defense with attention
-- would require an adapter re-create — explicitly OUT OF SCOPE for this seed-only slice (the P7
-- guard: zero engine edits), and thematically backwards anyway (armor does not draw pirates).
--
-- NUMBERS [D — owner-tunable; the plan's proposals, grounded]:
--   · shield_lattice  slot 1 → {"defense": 12} — the plan's number verbatim. Band check against
--     the 0111 seeding law (a slot-1 module ≈ a capacity-2/3 support craft): autocannon slot 1 →
--     attack 10; the only defense carriers today are hull 10 (0170) and support craft (pinned out
--     of team hunts, packet §0.3). 12 more than DOUBLES the degenerate survival curve
--     (hull-only 10 → 22 fitted — the packet F2 finding this slice exists to fix).
--   · mining_rig_extension slot 1 → {"mining": 8} — band: mining_drone (0042) capacity 2 →
--     mining 8; the shipped slot-1 sensor precedent seeds exactly the cap-2 drone's value
--     (deep_scan_sensor_array scan 8 = survey_drone's 8), applied identically here. HONESTY NOTE:
--     mining_yield has NO engine consumer yet — extraction bundles are fixed per field (0103:
--     "Weighted/depleting yields are an additive later change"), so today the stat lands in the
--     adapter/preview/group-totals surface only. That is a STAT gap, not an ITEM gap — the F4
--     lesson (never seed an item nothing drops) is about recipes, and every ingredient below has
--     a live drop source. When weighted yields ship, this module is already the knob.
--
-- RECIPES — LIVE DROPS ONLY (the F4 lesson), grounded source by source:
--   · shield_lattice = repair_parts 4 + pirate_alloy 3 + scrap 8 (the plan's recipe verbatim).
--     Drop sources (pirate_loot_for_wave, head 0171 — 0041 parity + the gated shard hunk):
--     scrap wave ≥ 1 (guaranteed), pirate_alloy wave ≥ 3, repair_parts wave ≥ 10.
--     ██ THE WAVE-10 GATE, noted as requested: repair_parts is a DEEP-RUN drop — packet §1.1: a
--     solo kitted ship farms ~3 waves at Snare; wave 10+ takes a ~4-ship kitted team (12 w) or a
--     6-ship team (17 w). That makes the shield a MID-GAME UNLOCK — deliberate and coherent: the
--     defense stat matters most exactly where teams push deep (danger growth outruns any fixed
--     team, §1.1), and the precedent already exists (expanded_cargo_lattice carries repair_parts
--     2 since 0107). Magnitude: 4 repair_parts ≈ 4 cleared waves past w10 across runs. ██
--   · mining_rig_extension = crystal 2 + ore 6 + scrap 4 [D]. crystal/ore are MINING-gated drops
--     (0103 field bundles: ore in ALL 5 seeded fields at qty 2–3; crystal in 3 of 5 at qty 1–2)
--     — the cross-activity economy loop the plan names: mine to mine better. crystal 2 matches
--     the shipped crystal magnitude (vector_thruster_kit crystal 2, 0107); ore 6 ≈ 2–3
--     extractions; scrap 4 ≈ 4 combat waves (the thruster's scrap 4). Both activities feed one
--     module — mining alone cannot craft it, mirroring every other recipe's mixed sourcing.
--
-- CRAFTABILITY (the 0109 recipe-check shape, asserted below): craft_module answers
-- unknown_module (catalog row missing) → both rows seeded; no_recipe (zero ingredient rows) →
-- both recipes seeded; insufficient_items (any balance < qty) → a player holding EXACTLY the
-- listed quantities passes the pre-check and the inventory_spend re-check by construction —
-- items are the ENTIRE price (0107 decision 3: no metal, no credits). End-to-end proven in the
-- team-command proof's MOD2 block (grant → craft → fit → adapter delta, this same slice).
--
-- IDEMPOTENT: on conflict do nothing on the REAL unique keys — module_types (id) PK and
-- module_recipe_ingredients (module_type_id, item_id) PK. The 0111 guarded-UPDATE idiom is NOT
-- needed here: slot_cost/stats_json columns already exist, so the insert carries them directly
-- and the on-conflict guard gives the same write-once posture (a later owner rebalance is never
-- clobbered by a re-run).
--
-- DARK BY CONSTRUCTION: module_crafting_enabled and module_fitting_enabled are both committed
-- 'false' (0107/0111) and this migration flips NOTHING — the new rows are inert public catalog
-- data until the owner's activation flips. RLS/grants: no new table, no new policy, no new grant
-- — the 0107 table-wide public-read policies cover new rows (the 0075/0076 precedent).
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md): no change — module_types / module_recipe_ingredients
-- stay Modules-owned migration-seeded catalogs; no new writer, no new edge. Docs synced this
-- slice: FULL_CAPACITY_PLAN (MOD2-1 shipped; MOD2-2 Mk-II remains), DEV_LOG (incl. the survival-
-- curve balance paragraph: hull 10 → 22 ≈ −9.8% incoming damage at every zone).

-- ── 1) the two new module archetypes (idempotent; catalog tone matches 0107) ─────────────────────
insert into public.module_types (id, name, slot_type, description, slot_cost, stats_json) values
  ('shield_lattice', 'Shield Lattice', 'defense',
   'A layered deflection lattice bolted over the hull''s weak seams. The first fitted answer to '
   'incoming fire — the ship endures what used to get through.',
   1, '{"defense": 12}'::jsonb),
  ('mining_rig_extension', 'Mining Rig Extension', 'mining',
   'An extended extraction rig assembled from refined field yields. Crews that mine, mine better '
   'with it fitted.',
   1, '{"mining": 8}'::jsonb)
on conflict (id) do nothing;

-- ── 2) recipes — live drops only (F4); quantities per the header grounding ───────────────────────
insert into public.module_recipe_ingredients (module_type_id, item_id, qty) values
  -- defense: the deep-run combat-component class + pirate salvage + bulk structure
  ('shield_lattice',       'repair_parts', 4),
  ('shield_lattice',       'pirate_alloy', 3),
  ('shield_lattice',       'scrap',        8),
  -- mining: the cross-activity loop — mining yields + combat scrap
  ('mining_rig_extension', 'crystal',      2),
  ('mining_rig_extension', 'ore',          6),
  ('mining_rig_extension', 'scrap',        4)
on conflict (module_type_id, item_id) do nothing;

-- ── 3) SELF-ASSERTS — the migration proves its own grounding or refuses to land ──────────────────
do $$
declare
  v_n        integer;
  v_prosrc   text;
  v_loot     text;
  r          record;
  v_key      text;
begin
  -- (a) both modules present with the EXACT seeded shape (slot_cost sane: >= 1 by CHECK, and each
  --     fits ANY shipped hull — slot_cost <= the smallest base_module_slots, today 3).
  select count(*) into v_n from public.module_types
    where (id = 'shield_lattice'       and slot_type = 'defense' and slot_cost = 1
           and stats_json = '{"defense": 12}'::jsonb)
       or (id = 'mining_rig_extension' and slot_type = 'mining'  and slot_cost = 1
           and stats_json = '{"mining": 8}'::jsonb);
  if v_n <> 2 then
    raise exception 'MOD2-1 self-assert FAIL: % of 2 module rows carry the exact seeded shape', v_n;
  end if;
  select count(*) into v_n from public.module_types t
    where t.id in ('shield_lattice', 'mining_rig_extension')
      and t.slot_cost > (select min(base_module_slots) from public.main_ship_hull_types);
  if v_n <> 0 then
    raise exception 'MOD2-1 self-assert FAIL: % module(s) cannot fit the smallest hull (slot_cost > min base_module_slots)', v_n;
  end if;

  -- (b) full recipes present, exactly as seeded (a partial landing = an uncraftable module that
  --     answers a WRONG price — worse than no_recipe).
  select count(*) into v_n from public.module_recipe_ingredients
    where (module_type_id, item_id, qty) in (
      ('shield_lattice', 'repair_parts', 4), ('shield_lattice', 'pirate_alloy', 3),
      ('shield_lattice', 'scrap', 8),
      ('mining_rig_extension', 'crystal', 2), ('mining_rig_extension', 'ore', 6),
      ('mining_rig_extension', 'scrap', 4));
  if v_n <> 6 then
    raise exception 'MOD2-1 self-assert FAIL: % of 6 recipe rows carry the exact seeded (module, item, qty)', v_n;
  end if;
  select count(*) into v_n from public.module_recipe_ingredients
    where module_type_id in ('shield_lattice', 'mining_rig_extension');
  if v_n <> 6 then
    raise exception 'MOD2-1 self-assert FAIL: the two modules carry % recipe rows (want exactly 6 — no strays)', v_n;
  end if;

  -- (c) every ingredient exists in item_types (the FK already enforces this — asserted anyway so
  --     a future FK relaxation cannot silently orphan the recipes), AND has a LIVE drop source:
  --     combat items must appear in the DEPLOYED pirate_loot_for_wave body (head 0171 — the drop
  --     table IS the function's prosrc), mining items in a seeded mining_fields bundle at qty > 0
  --     (0103 — fixed bundles, no depletion; both queryable, so asserted, not just documented).
  select count(*) into v_n
    from (select distinct item_id from public.module_recipe_ingredients
           where module_type_id in ('shield_lattice', 'mining_rig_extension')) i
    where not exists (select 1 from public.item_types t where t.item_id = i.item_id);
  if v_n <> 0 then
    raise exception 'MOD2-1 self-assert FAIL: % recipe ingredient(s) missing from item_types', v_n;
  end if;
  select prosrc into v_loot from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'pirate_loot_for_wave';
  if v_loot is null then
    raise exception 'MOD2-1 self-assert FAIL: pirate_loot_for_wave not found (the combat drop source)';
  end if;
  foreach v_key in array array['repair_parts', 'pirate_alloy', 'scrap'] loop
    if strpos(v_loot, '''' || v_key || '''') = 0 then
      raise exception 'MOD2-1 self-assert FAIL: combat ingredient % has no drop in pirate_loot_for_wave (F4 breach)', v_key;
    end if;
  end loop;
  foreach v_key in array array['crystal', 'ore'] loop
    select count(*) into v_n
      from public.mining_fields f,
           lateral jsonb_array_elements(f.reward_bundle_json->'items') el
      where el->>'item_id' = v_key and (el->>'quantity')::numeric > 0;
    if v_n = 0 then
      raise exception 'MOD2-1 self-assert FAIL: mining ingredient % drops from no mining field (F4 breach)', v_key;
    end if;
  end loop;

  -- (d) THE STAT-KEY PIN: every stats_json key this migration seeds must be a key the DEPLOYED
  --     adapter's module loop actually reads — prosrc-checked in the exact read form
  --     (m.stats_json->>'<key>'), plus the output keys the plan's numbers land on. A typo'd key
  --     would fold to nothing (coalesce 0) and ship a dead module; this makes it unlandable.
  select prosrc into v_prosrc from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'calculate_expedition_stats';
  if v_prosrc is null then
    raise exception 'MOD2-1 self-assert FAIL: calculate_expedition_stats not found';
  end if;
  for r in
    select t.id, k.key
      from public.module_types t, lateral jsonb_object_keys(t.stats_json) k(key)
     where t.id in ('shield_lattice', 'mining_rig_extension')
  loop
    if strpos(v_prosrc, '(m.stats_json->>''' || r.key || ''')') = 0 then
      raise exception 'MOD2-1 self-assert FAIL: % seeds stats key ''%'' which the adapter module loop does NOT read (dead module)', r.id, r.key;
    end if;
  end loop;
  if strpos(v_prosrc, '''survival''') = 0 or strpos(v_prosrc, '''mining_yield''') = 0 then
    raise exception 'MOD2-1 self-assert FAIL: adapter output keys survival/mining_yield not found in prosrc';
  end if;

  -- (e) craftability shape (0109): both modules clear the unknown_module and no_recipe gates by
  --     (a)+(b); items-only price re-checked — no recipe row references a non-item cost (the
  --     table shape makes other costs impossible, so present rows + existing items = a player
  --     with the listed quantities passes both the pre-check loop and inventory_spend).
  select count(*) into v_n from public.module_types t
    where t.id in ('shield_lattice', 'mining_rig_extension')
      and not exists (select 1 from public.module_recipe_ingredients ri where ri.module_type_id = t.id);
  if v_n <> 0 then
    raise exception 'MOD2-1 self-assert FAIL: % module(s) would answer no_recipe', v_n;
  end if;

  -- (f) this migration flips nothing — but the module gates MAY legitimately be lit already:
  -- module_crafting_enabled/module_fitting_enabled went TRUE at the 2026-07-12 team-command
  -- activation (scripts/activate-team-command.sql stage 2, packet §1.4.2). Landing this seed on a
  -- LIT system simply makes the two modules immediately craftable — owner-sanctioned content.
  -- (The original dark-assert here BLOCKED the prod deploy — repaired 2026-07-12 while unapplied;
  -- CI chains are dark-seeded so both arms stay covered.)
  if public.cfg_bool('module_crafting_enabled') or public.cfg_bool('module_fitting_enabled') then
    raise notice 'MOD2-1: module gates are LIT at seed time — shield_lattice + mining_rig_extension go live immediately (sanctioned)';
  end if;

  raise notice 'MOD2-1 self-assert ok: 2 modules (defense 12 / mining 8, slot 1 each, fit any hull) + 6 exact recipe rows; every ingredient item-typed with a live drop source (loot prosrc + field bundles); every seeded stats key adapter-read (prosrc-pinned) with survival/mining_yield outputs present; craftable shape; both gates still dark';
end $$;
