-- Byeharu — MOD2-2 (FULL_CAPACITY_PLAN §C P7): the Mk-II module tier — a PURE CATALOG SEED slice,
-- the exact shape of MOD2-1 (mig 0183). Two new module_types + their recipes; ZERO engine edits
-- (no RPC, no adapter re-create, no schema change, NO flag flip, no frontend). All stats flow
-- through the EXISTING pipeline: module_types.stats_json → the fitting adapter's module loop
-- (calculate_expedition_stats, head 0198 → verified-back to 0044/0115/0122/0170/0180/0193) → the
-- Σ slot_cost ≤ module_slots reject-never-clamp cap (0115/0112). NO NEW FLAG: the Mk-II rows go
-- live with the SAME module_crafting_enabled/module_fitting_enabled flips as MOD2-1.
--
-- STAT-KEY VERIFICATION (the whole slice hinges on this — a typo'd key is a dead module):
--   the 0198 head's module loop reads EXACTLY these stats_json keys, coalesced to 0:
--     attack / defense / repair / cargo / scan / mining / evasion + speed_mult_bonus
--   and folds them into the SAME accumulators as support craft / hull / captains:
--     (m.stats_json->>'attack')::numeric  → a_combat   → output key 'combat_power' (0198:247/366)
--     (m.stats_json->>'defense')::numeric → a_survival → output key 'survival'     (0198:248/367)
--   So the Mk-II autocannon seeds `attack` and the Mk-II shield seeds `defense` — the SAME input
--   vocabulary MOD2-1's shield/hull use ('defense', not the OUTPUT key 'survival'). Self-asserted
--   below against pg_proc.prosrc of the DEPLOYED adapter body (the 0183 pin, verbatim).
--
-- SLOT_TYPE — the Mk-II modules REUSE the shipped archetypes: autocannon_battery_mk2 is 'weapon'
-- (the 0107 autocannon's archetype) and shield_lattice_mk2 is 'defense' (the 0183 shield's). No
-- new archetype — the higher tier is a bigger number in the same class. The adapter's slot_type
-- tradeoff CASE (0115/0198:261-262) therefore already covers both: 'weapon' pays attention +2 and
-- speed −0.03 PER slot_cost (a Mk-II slot_cost 2 → +4 attention / −0.06 speed, DOUBLE the base
-- autocannon's cost — bigger guns draw more heat); 'defense' takes the permissive `else 0` arm
-- (armor does not draw pirates — the 0183 shield posture, inherited). Both proven end-to-end in the
-- team-command proof's MOD22 block (this same slice).
--
-- SLOT_COST 2 (the P7 line's number, verbatim: "slot_cost 2 so 3-slot ships face a real tradeoff")
-- — the capacity-tradeoff law made real. Base tier is slot 1 (four modules fit a 3-slot frigate
-- loosely); a Mk-II eats TWO of three slots, so a frigate carries AT MOST one Mk-II plus one base
-- module — a genuine loadout choice, not a free upgrade. Still fits every shipped hull: the
-- smallest is bulk_hauler base_module_slots 2 (0185) → slot_cost 2 ≤ 2, self-asserted below.
--
-- NUMBERS [D — owner-tunable; the P7 line's proposals, grounded on the base tier]:
--   · autocannon_battery_mk2 slot 2 → {"attack": 18} — the plan's number verbatim. The base
--     autocannon (0107) is attack 10; the Mk-II is +8 (×1.8). Band check against the 0111 seeding
--     law: for TWICE the slot cost the player gets 1.8× the firepower (a sub-linear premium — the
--     capacity-tradeoff law rewards the slot spend but never for free), and the +8 step is the
--     tier's single rule (see the shield below — same +8).
--   · shield_lattice_mk2 slot 2 → {"defense": 20} [D — the P7 line's "same for shield"] — the base
--     shield_lattice (0183) is defense 12; the Mk-II applies the SAME +8 tier step (12 → 20), so
--     one rule sets both lines (attack 10→18, defense 12→20). Band: the degenerate hull-only
--     survival curve (10, the packet F2 finding) with a Mk-II shield reads hull 10 → 30 fitted (a
--     ~−16% incoming-damage swing at every zone — the mid-game deep-push answer the defense line
--     exists to give), for two of three frigate slots.
--
-- RECIPES — LIVE DROPS ONLY (the F4 lesson), grounded source by source. The Mk-II recipes share
-- the PROGRESSION PAIR blueprint_fragment 2 + artifact_core 1 (the P7 line's "same for shield")
-- and differ only in the line-appropriate base component — EXACTLY the base tier's split
-- (autocannon=weapon_parts, shield=repair_parts, 0107/0183):
--   · autocannon_battery_mk2 = blueprint_fragment 2 + artifact_core 1 + weapon_parts 6 (the P7 line
--     verbatim). Drop sources:
--       - blueprint_fragment: the config-gated w≥8 combat drop in the DEPLOYED pirate_loot_for_wave
--         (head 0185 — appears in the function's prosrc). The 0107 deep_scan recipe already carries
--         blueprint_fragment 1, so this is a precedented, drop-grounded progression ingredient — NOT
--         a dead item (F4 satisfied). ██ THE FAUCET GATE (honest): blueprint_fragment_drop_rate is
--         committed '0' (byte-inert, 0185:96), so the combat faucet is CLOSED today; the ONLY
--         non-combat source is the SINGLE one-shot exploration site (0098:109 — qty 1, NOT a mining
--         field: 0103 seeds artifact_core but NO blueprint_fragment). So the shipped-config LIFETIME
--         CEILING for blueprint_fragment is 1 — and each Mk-II needs qty 2. THEREFORE both Mk-II
--         modules are UNCRAFTABLE under every shipped config until the combat faucet is LIT
--         (`blueprint_fragment_drop_rate > 0`) — a SEPARATE activation this slice does NOT ride. This
--         is a DELIBERATE deep-gate, not a bug, and it SELF-CORRECTS when the faucet lights: it is the
--         EXACT same dependency SHIPYARD-0's T1 ships already carry (bulk_hauler / strike_corvette
--         each need blueprint_fragment 2 behind this same closed faucet, 0185:162/168). Bigger guns
--         and bigger hulls cost the rarest input, gated behind the same one flip. ██
--       - artifact_core: the epic progression drop (item_types, 0039) — LIVE from the Singularity
--         Scar mining field (0103, qty 1) and the one-shot exploration reward set (0098). Grounded
--         below via the SAME mining_fields bundle check MOD2-1 used for crystal/ore (it is NOT a
--         combat drop — asserted against field bundles, never the loot prosrc).
--       - weapon_parts: the base autocannon's component — a live combat drop (pirate_loot_for_wave
--         wave ≥ 5, 0185/0171/0041). 6 ≈ 6 cleared waves past w5.
--   · shield_lattice_mk2 = blueprint_fragment 2 + artifact_core 1 + repair_parts 6 [D — the base
--     shield's repair_parts component, the "same for shield" pair]. repair_parts is the base
--     shield's signature drop — a DEEP-RUN combat drop (pirate_loot_for_wave wave ≥ 10, 0185): the
--     Mk-II shield is a deep-team unlock, exactly like the base shield (0183's wave-10 gate note),
--     one tier up. 6 ≈ 6 cleared waves past w10.
--
-- CRAFTABILITY (the 0109 recipe-check shape, asserted below): craft_module answers unknown_module
-- (catalog row missing) → both rows seeded; no_recipe (zero ingredient rows) → both recipes
-- seeded; insufficient_items (any balance < qty) → a player holding EXACTLY the listed quantities
-- passes the pre-check and the inventory_spend re-check by construction — items are the ENTIRE
-- price (0107 decision 3: no metal, no credits). End-to-end proven in the team-command proof's
-- MOD22 block (grant → exact-price craft → fit → adapter delta, this same slice).
--   ██ HONEST OBTAINABILITY (distinct from the recipe SHAPE above): the shape is craftable — a
--   player with the listed items crafts — but UNDER EVERY SHIPPED CONFIG no player can ACCUMULATE
--   them, because blueprint_fragment qty 2 exceeds its lifetime ceiling of 1 (the one-shot 0098 site)
--   until the combat faucet flips (see the blueprint_fragment note above). So the Mk-II tier is
--   ACTIVATION-gated on `blueprint_fragment_drop_rate > 0`, exactly like SHIPYARD-0's T1 ships — a
--   separate flip this slice does not ride. The MOD22 proof GRANTS the ingredients via the Reward
--   sole writer to exercise the craft path, which is how the T1-ship proofs exercise theirs too. ██
--
-- IDEMPOTENT: on conflict do nothing on the REAL unique keys — module_types (id) PK and
-- module_recipe_ingredients (module_type_id, item_id) PK. The columns already exist (0107/0111), so
-- the insert carries slot_cost/stats_json directly; the on-conflict guard gives the write-once
-- posture (a later owner rebalance is never clobbered by a re-run — the 0183 idiom verbatim).
--
-- DARK BY CONSTRUCTION / DEPLOY-INERT: this migration flips NOTHING. module_crafting_enabled and
-- module_fitting_enabled stay at their committed value (0107/0111 — 'false' in CI-dark chains; may
-- already be LIT in prod at the 2026-07-12 team-command activation, in which case the two Mk-II rows
-- become VISIBLE public catalog immediately but stay UNCRAFTABLE in practice — the blueprint_fragment
-- qty-2 gate above holds until the combat faucet flips too, so lighting the module gates alone adds
-- no obtainable content; owner-sanctioned, the 0183 note). Landing this migration changes NO
-- player-visible behavior until (and only until) the EXISTING module gates are lit — it is
-- deploy-inert additive catalog content behind the same dark gates as MOD2-1. RLS/
-- grants: no new table, no new policy, no new grant — the 0107 table-wide public-read policies
-- cover the new rows (the 0075/0076/0183 precedent).
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md): no change — module_types / module_recipe_ingredients stay
-- Modules-owned migration-seeded catalogs; no new writer, no new edge. Docs synced this slice:
-- FULL_CAPACITY_PLAN (MOD2-2 shipped; MOD2-3 remains), DEV_LOG.

-- ── 1) the two Mk-II module rows (idempotent; catalog tone matches 0107/0183) ─────────────────────
insert into public.module_types (id, name, slot_type, description, slot_cost, stats_json) values
  ('autocannon_battery_mk2', 'Autocannon Battery Mk-II', 'weapon',
   'A heavier autocannon array built on a blueprint fragment and an artifact core. Nearly double '
   'the base battery''s firepower — for twice the slot cost, and twice the heat it draws.',
   2, '{"attack": 18}'::jsonb),
  ('shield_lattice_mk2', 'Shield Lattice Mk-II', 'defense',
   'A reinforced deflection lattice reworked around salvaged progression tech. The deep-run answer '
   'to incoming fire — a bigger wall, for two of the ship''s module slots.',
   2, '{"defense": 20}'::jsonb)
on conflict (id) do nothing;

-- ── 2) recipes — the shared progression pair + a line-appropriate base component (live drops, F4) ─
insert into public.module_recipe_ingredients (module_type_id, item_id, qty) values
  -- weapon: the progression pair + the base autocannon's weapon_parts
  ('autocannon_battery_mk2', 'blueprint_fragment', 2),
  ('autocannon_battery_mk2', 'artifact_core',      1),
  ('autocannon_battery_mk2', 'weapon_parts',       6),
  -- defense: the progression pair + the base shield's repair_parts (the deep-run combat component)
  ('shield_lattice_mk2',     'blueprint_fragment', 2),
  ('shield_lattice_mk2',     'artifact_core',      1),
  ('shield_lattice_mk2',     'repair_parts',       6)
on conflict (module_type_id, item_id) do nothing;

-- ── 3) SELF-ASSERTS — the migration proves its own grounding or refuses to land (the 0183 shape) ──
do $$
declare
  v_n        integer;
  v_prosrc   text;
  v_loot     text;
  r          record;
  v_key      text;
begin
  -- (a) both Mk-II modules present with the EXACT seeded shape, AND each fits the SMALLEST shipped
  --     hull (slot_cost <= the min base_module_slots — today bulk_hauler's 2, 0185; slot_cost 2 <= 2).
  select count(*) into v_n from public.module_types
    where (id = 'autocannon_battery_mk2' and slot_type = 'weapon'  and slot_cost = 2
           and stats_json = '{"attack": 18}'::jsonb)
       or (id = 'shield_lattice_mk2'     and slot_type = 'defense' and slot_cost = 2
           and stats_json = '{"defense": 20}'::jsonb);
  if v_n <> 2 then
    raise exception 'MOD2-2 self-assert FAIL: % of 2 Mk-II module rows carry the exact seeded shape', v_n;
  end if;
  select count(*) into v_n from public.module_types t
    where t.id in ('autocannon_battery_mk2', 'shield_lattice_mk2')
      and t.slot_cost > (select min(base_module_slots) from public.main_ship_hull_types);
  if v_n <> 0 then
    raise exception 'MOD2-2 self-assert FAIL: % Mk-II module(s) cannot fit the smallest hull (slot_cost > min base_module_slots)', v_n;
  end if;

  -- (b) full recipes present, exactly as seeded (a partial landing = an uncraftable module that
  --     answers a WRONG price — worse than no_recipe), and no strays under the two Mk-II ids.
  select count(*) into v_n from public.module_recipe_ingredients
    where (module_type_id, item_id, qty) in (
      ('autocannon_battery_mk2', 'blueprint_fragment', 2), ('autocannon_battery_mk2', 'artifact_core', 1),
      ('autocannon_battery_mk2', 'weapon_parts', 6),
      ('shield_lattice_mk2', 'blueprint_fragment', 2), ('shield_lattice_mk2', 'artifact_core', 1),
      ('shield_lattice_mk2', 'repair_parts', 6));
  if v_n <> 6 then
    raise exception 'MOD2-2 self-assert FAIL: % of 6 recipe rows carry the exact seeded (module, item, qty)', v_n;
  end if;
  select count(*) into v_n from public.module_recipe_ingredients
    where module_type_id in ('autocannon_battery_mk2', 'shield_lattice_mk2');
  if v_n <> 6 then
    raise exception 'MOD2-2 self-assert FAIL: the two Mk-II modules carry % recipe rows (want exactly 6 — no strays)', v_n;
  end if;

  -- (c) every ingredient exists in item_types (the FK enforces it — asserted anyway), AND has a
  --     LIVE drop source: the COMBAT ingredients (blueprint_fragment / weapon_parts / repair_parts)
  --     must appear in the DEPLOYED pirate_loot_for_wave body (head 0185 — the drop table IS the
  --     prosrc); artifact_core is a MINING/exploration drop, grounded via a mining_fields bundle at
  --     qty > 0 (the 0183 crystal/ore idiom — NOT the loot prosrc, it is no combat drop).
  select count(*) into v_n
    from (select distinct item_id from public.module_recipe_ingredients
           where module_type_id in ('autocannon_battery_mk2', 'shield_lattice_mk2')) i
    where not exists (select 1 from public.item_types t where t.item_id = i.item_id);
  if v_n <> 0 then
    raise exception 'MOD2-2 self-assert FAIL: % recipe ingredient(s) missing from item_types', v_n;
  end if;
  select prosrc into v_loot from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'pirate_loot_for_wave';
  if v_loot is null then
    raise exception 'MOD2-2 self-assert FAIL: pirate_loot_for_wave not found (the combat drop source)';
  end if;
  -- NOTE (by-design, NOT asserted): this check proves each ingredient DROPS SOMEWHERE (the letter of
  -- F4), NOT that its required QTY is reachable under the committed config. blueprint_fragment qty 2
  -- is DELIBERATELY beyond today's shipped ceiling of 1 (the one-shot 0098 site) — its combat faucet
  -- (blueprint_fragment_drop_rate) is committed 0, so the Mk-II tier is intentionally ACTIVATION-
  -- gated on that faucet, exactly like SHIPYARD-0's T1 ships (same qty-2 blueprint gate, 0185). A hard
  -- qty-reachability assert is deliberately OMITTED: it would FAIL by design while the faucet is dark
  -- (the seed must land inert), and the gate is a feature, not a bug — it self-corrects at the flip.
  foreach v_key in array array['blueprint_fragment', 'weapon_parts', 'repair_parts'] loop
    if strpos(v_loot, '''' || v_key || '''') = 0 then
      raise exception 'MOD2-2 self-assert FAIL: combat ingredient % has no drop in pirate_loot_for_wave (F4 breach)', v_key;
    end if;
  end loop;
  select count(*) into v_n
    from public.mining_fields f,
         lateral jsonb_array_elements(f.reward_bundle_json->'items') el
    where el->>'item_id' = 'artifact_core' and (el->>'quantity')::numeric > 0;
  if v_n = 0 then
    raise exception 'MOD2-2 self-assert FAIL: artifact_core drops from no mining field (F4 breach)';
  end if;

  -- (d) THE STAT-KEY PIN: every stats_json key this migration seeds must be a key the DEPLOYED
  --     adapter's module loop actually reads — prosrc-checked in the exact read form
  --     (m.stats_json->>'<key>'), plus the output keys the Mk-II numbers land on. A typo'd key
  --     would fold to nothing (coalesce 0) and ship a dead module; this makes it unlandable.
  select prosrc into v_prosrc from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'calculate_expedition_stats';
  if v_prosrc is null then
    raise exception 'MOD2-2 self-assert FAIL: calculate_expedition_stats not found';
  end if;
  for r in
    select t.id, k.key
      from public.module_types t, lateral jsonb_object_keys(t.stats_json) k(key)
     where t.id in ('autocannon_battery_mk2', 'shield_lattice_mk2')
  loop
    if strpos(v_prosrc, '(m.stats_json->>''' || r.key || ''')') = 0 then
      raise exception 'MOD2-2 self-assert FAIL: % seeds stats key ''%'' which the adapter module loop does NOT read (dead module)', r.id, r.key;
    end if;
  end loop;
  if strpos(v_prosrc, '''combat_power''') = 0 or strpos(v_prosrc, '''survival''') = 0 then
    raise exception 'MOD2-2 self-assert FAIL: adapter output keys combat_power/survival not found in prosrc';
  end if;
  -- the weapon Mk-II's slot_type tradeoff must be a LIVE adapter rule (a slot 2 weapon costs
  -- attention +4 / speed −0.06) — pin the exact slot_type CASE arms so a future adapter that drops
  -- the weapon tradeoff cannot silently make the Mk-II a free upgrade.
  if strpos(v_prosrc, 'when ''weapon'' then 2') = 0 or strpos(v_prosrc, 'when ''weapon'' then 0.03') = 0 then
    raise exception 'MOD2-2 self-assert FAIL: the adapter weapon slot_type tradeoff (attention 2 / speed 0.03 per slot_cost) is not present — the Mk-II autocannon would be a free upgrade';
  end if;

  -- (e) craftability shape (0109): both modules clear unknown_module and no_recipe by (a)+(b);
  --     items-only price re-checked (the table shape makes other costs impossible).
  select count(*) into v_n from public.module_types t
    where t.id in ('autocannon_battery_mk2', 'shield_lattice_mk2')
      and not exists (select 1 from public.module_recipe_ingredients ri where ri.module_type_id = t.id);
  if v_n <> 0 then
    raise exception 'MOD2-2 self-assert FAIL: % Mk-II module(s) would answer no_recipe', v_n;
  end if;

  -- (f) this migration flips nothing — the module gates keep their committed value (the 0183 note:
  --     dark in CI chains, possibly LIT in prod at the 2026-07-12 activation; either way this seed
  --     is deploy-inert additive catalog content behind the SAME existing gates — no new flag).
  if public.cfg_bool('module_crafting_enabled') or public.cfg_bool('module_fitting_enabled') then
    raise notice 'MOD2-2: module gates are LIT at seed time — autocannon_battery_mk2 + shield_lattice_mk2 go craftable immediately (sanctioned)';
  end if;

  raise notice 'MOD2-2 self-assert ok: 2 Mk-II modules (attack 18 / defense 20, slot_cost 2 each, fit any hull) + 6 exact recipe rows; every ingredient item-typed with a live drop source (combat prosrc + artifact_core field bundle); every seeded stats key adapter-read (prosrc-pinned) with combat_power/survival outputs + the weapon tradeoff present; craftable shape; no new flag (lights with the existing module gates)';
end $$;
