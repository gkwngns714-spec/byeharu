-- Byeharu — SHIPYARD-0 (the SHIPYARD charter, slice 0 of SHIPYARD-0..3 + ACT-SHIPYARD): the
-- ship-production FOUNDATION — hull build recipes (catalog) + the two T1 hulls (seeded DARK) +
-- the blueprint_fragment combat faucet (config-gated inert). The owner's directive: "ships must
-- be made through mining, production, level requirement and more" — ships stop being
-- credits-only commissions; T1+ hulls are BUILT from mined/dropped materials + credits over a
-- build timer, gated by progression.
--
-- ── WHAT THIS SHIPS (ALL dark / inert until the human flips) ─────────────────────────────────────
--   1. `shipyard_enabled` — the NEW capability flag, seeded 'false' (the 0097/0102/0107 config+flag
--      idiom). NO RPC exists yet; the flag simply exists dark. EVERY shipyard RPC added in later
--      slices MUST check it FIRST and reject-before-any-read while false.
--   2. `hull_build_recipes` + `hull_recipe_ingredients` — the build-recipe catalog/config tables
--      (Reference/Config, MIGRATION-SEEDED ONLY, public read — the 0107 module_types/
--      module_recipe_ingredients posture verbatim: RLS + ONE public-read policy + select grant,
--      NO write policy/grant, NO runtime writer, ever). One implicit recipe per hull = its header
--      row (credits cost, build seconds, progression gates) + its ingredient rows (normalized,
--      FK-checked — referential integrity over blob parsing, the 0107 decision-3 shape, plus the
--      credits/build-time columns ships NEED that instant module crafting deliberately skipped).
--   3. The TWO T1 hulls, seeded DARK into `main_ship_hull_types` (verified absent today — 0043
--      seeds only starter_frigate, grep-verified sole hull seed site): **bulk_hauler**
--      ('Mule-class Hauler') and **strike_corvette** ('Talon-class Corvette') — the 0184 EVE-style
--      class register, exactly as 0184 pre-registered it ("hauler → 'Mule', corvette → 'Talon'").
--      Inert by construction: NOTHING resolves a non-starter hull today (every commission path
--      hardcodes 'starter_frigate' — 0072/0080/0091; the hull rows are public catalog data).
--   4. The BLUEPRINT FAUCET — `pirate_loot_for_wave` re-created from its TRUE head (0171 —
--      grep-verified: 0041 and 0171 are the ONLY create sites; 0046/0167/0169 call it, 0174/0176/
--      0183 only cite it) with ONE marked hunk: waves >= 8 roll
--      `random() < coalesce(cfg_num('blueprint_fragment_drop_rate'), 0)` for exactly 1
--      blueprint_fragment — the EXACT 0171 shard idiom. Knob seeded '0' → `random() < 0` is
--      STRICTLY-LESS-THAN against a [0,1) draw: NEVER true, so the function output is
--      BYTE-IDENTICAL to the 0171 head for every input until the activation script raises the
--      knob. WAVE THRESHOLD (the packet's design): shards are w>=2, blueprints w>=8 — the
--      DEEP-RUN gate (engine_parts depth; packet §1.1: w8+ is kitted-team territory), and wave 1
--      stays deterministic scrap-only at ANY rate (the live verify-phase5 exact pin never flakes).
--   5. NO build_orders changes, NO RPC, NO cron edits — SHIPYARD-1/2 own the queue + the build/
--      deliver commands. This slice is catalog + faucet ONLY.
--
-- ── THE PRODUCTION MODEL (the charter, restated) ─────────────────────────────────────────────────
--   T0 = starter_frigate (the existing credits-only commission — UNTOUCHED). T1 = bulk_hauler /
--   strike_corvette (built: items + credits + build_seconds through the M4.5 serial queue —
--   SHIPYARD-1). T2+ = later hulls that use `required_hull_type_id` (own the prerequisite hull)
--   and `required_captain_level` (the owner's "level requirement") — the T1 rows seed BOTH NULL,
--   honestly: captain levels are dark (0177/0180) and no T2 exists; the gate columns land now so
--   the recipe shape never migrates again.
--
-- ── NUMBERS [D — owner-tunable; the packet's proposals] ──────────────────────────────────────────
--   bulk_hauler:     hp 650, speed 0.8, cargo 140 (m3 140.0 — the 0075 1:1 abstract→volume law),
--                    modules 2, captains 6 (0171 seeds new hulls at 6 directly — the bump law),
--                    {"attack": 5, "defense": 15} (the 0170 input vocabulary; the fat slow truck).
--   strike_corvette: hp 420, speed 1.3, cargo 20 (m3 20.0), modules 4, captains 6,
--                    {"attack": 30, "defense": 10} (the fast glass gun — role emergent from fit,
--                    no activity locks, the MAINSHIP_TRANSITION core vision).
--   base_support_capacity 10 = starter parity [D] — support craft are deprecated scaffolding
--   (MAINSHIP_TRANSITION §★), the column is NOT NULL, the value is cosmetic.
--   Recipes [D]: bulk_hauler = ore 24 + crystal 6 + engine_parts 6 + scrap 12 +
--   blueprint_fragment 2, credits 400, build 3600s; strike_corvette = ore 16 + crystal 4 +
--   weapon_parts 6 + pirate_alloy 8 + blueprint_fragment 2, credits 400, build 3600s.
--
-- ── DROP GROUNDING (the F4 lesson — every ingredient has a live source; self-asserted) ───────────
--   ore / crystal — mining-field bundles (0103: ore in ALL 5 fields at 2–3, crystal in 3 of 5 at
--   1–2) — THE MINING FAUCET the owner named ("through mining"). scrap w>=1 / pirate_alloy w>=3 /
--   weapon_parts w>=5 / engine_parts w>=8 — pirate_loot_for_wave (head 0171 → now this file).
--   blueprint_fragment — the ONE progression-class gate ingredient: the exploration one-shot
--   (0098 'Silent Foundry Wreck' site bundle, qty 1 per player ever) + THIS migration's repeatable
--   w>=8 combat faucet (dark at rate 0). Never sellable (0174 salvage exclusion — unchanged).
--
-- ── THE PARITY DISCIPLINE (the 0171/0180/0182 re-create law) ─────────────────────────────────────
--   pirate_loot_for_wave is copied VERBATIM from its TRUE head — 0171 (grep-verified above).
--   Exactly ONE delta, marked `-- SHIPYARD-0 (0185):` — the config-gated blueprint append, added
--   lines only, appended AFTER every legacy element AND after the 0171 shard hunk so the rate-0
--   output is byte-identical INCLUDING element order. The header keyword set (volatile, forced by
--   0171) is unchanged — the new hunk reads the same table kinds the 0171 hunk already reads.
--   Verified by extracting both bodies and diffing (the 0170/0182 procedure): the diff is the one
--   marked hunk, nothing else. ACL re-asserted verbatim (the 0171 targeted idiom).
--
-- ── DARK BY CONSTRUCTION / LIVE-SURFACE HONESTY ──────────────────────────────────────────────────
--   The two hull rows ARE publicly readable on deploy (the catalog posture) — but no UI lists the
--   hull catalog (mainshipApi fetches BY the ship's own hull_type_id) and no commission path can
--   mint them; the recipes are inert rows behind `shipyard_enabled='false'` + a rate-0 faucet.
--   A player sees NOTHING change. Rollback = flags/knobs, never data.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this slice — the 0098/0103/0107 same-PR law):
-- §1 matrix gains `hull_build_recipes` + `hull_recipe_ingredients` under Reference/Config
-- (migration-seeded only, NO runtime writer — SHIPYARD-1's build command will READ them downward).
-- Docs synced: FULL_CAPACITY_PLAN (P6 → the SHIPYARD charter), DEV_LOG.
--
-- Forward-only: 0001–0184 unedited.

-- ── (a) the dark capability gate + the faucet knob (both inert seeds) ────────────────────────────
insert into public.game_config (key, value, description) values
  ('shipyard_enabled', 'false',
   'SHIPYARD-0 (0185): server-authoritative dark gate for ship production (hull building). OFF '
   'until the owner explicitly activates (ACT-SHIPYARD; preconditions: mining lit for the ore '
   'faucet + trade/salvage lit for credits). Every shipyard RPC (SHIPYARD-1+) must check this '
   'FIRST and reject-before-any-read while false; the UI fails closed independently.'),
  ('blueprint_fragment_drop_rate', '0',
   'SHIPYARD-0 (0185): probability (0..1) that a cleared pirate wave (wave >= 8 only — the '
   'deep-run gate; waves 1-7 are untouched, wave 1 stays deterministic scrap-only) drops exactly '
   '1 blueprint_fragment into the combat reward bundle (pirate_loot_for_wave). 0 = OFF '
   '(byte-identical 0171 loot). Raised by the human ACT-SHIPYARD activation script; tunable any '
   'time via set_game_config.')
on conflict (key) do nothing;

-- ── (b) hull_build_recipes — the per-hull build-recipe header (Reference/Config; public read) ────
create table public.hull_build_recipes (
  hull_type_id           text primary key references public.main_ship_hull_types (hull_type_id),
  credits_cost           numeric not null check (credits_cost >= 0),
  build_seconds          integer not null check (build_seconds > 0),
  required_hull_type_id  text references public.main_ship_hull_types (hull_type_id),
  -- review L (2026-07-12): a hull can never be its own prerequisite.
  constraint hull_recipe_no_self_prereq check (required_hull_type_id is null or required_hull_type_id <> hull_type_id),
  required_captain_level integer check (required_captain_level >= 1),
  created_at             timestamptz not null default now()
);
alter table public.hull_build_recipes enable row level security;
-- Public read-only; NO insert/update/delete policy and NO write grant → clients cannot mutate.
-- Only migrations / service_role (admin) write (the 0039/0042/0107 catalog posture).
create policy "hull_build_recipes_public_read" on public.hull_build_recipes for select using (true);
grant select on public.hull_build_recipes to anon, authenticated;

-- ── (c) hull_recipe_ingredients — normalized ingredient rows (Reference/Config; public read) ─────
create table public.hull_recipe_ingredients (
  hull_type_id text    not null references public.hull_build_recipes (hull_type_id),
  item_id      text    not null references public.item_types (item_id),
  qty          numeric not null check (qty > 0),
  created_at   timestamptz not null default now(),
  primary key (hull_type_id, item_id)
);
alter table public.hull_recipe_ingredients enable row level security;
create policy "hull_recipe_ingredients_public_read" on public.hull_recipe_ingredients for select using (true);
grant select on public.hull_recipe_ingredients to anon, authenticated;

-- ── (d) the two T1 hulls (DARK; idempotent on the PK; the 0043 column set + 0075 m3 + 0170
--        base_stats_json vocabulary + the 0171 captains=6 law; names per the 0184 register) ───────
insert into public.main_ship_hull_types
  (hull_type_id, name, description, base_hp, base_speed, base_cargo_capacity,
   base_cargo_capacity_m3, base_support_capacity, base_captain_slots, base_module_slots,
   base_stats_json) values
  ('bulk_hauler', 'Mule-class Hauler',
   'A wide-bellied freight workhorse. Slow and stubborn, but it carries what three frigates '
   'cannot — the backbone of any trade line.',
   650, 0.8, 140, 140.0, 10, 6, 2, '{"attack": 5, "defense": 15}'::jsonb),
  ('strike_corvette', 'Talon-class Corvette',
   'A lean, overgunned interceptor. Thin plating, oversized hardpoints — it ends fights fast '
   'or not at all.',
   420, 1.3, 20, 20.0, 10, 6, 4, '{"attack": 30, "defense": 10}'::jsonb)
on conflict (hull_type_id) do nothing;

-- ── (e) the build recipes (DARK; idempotent; T1 gates honestly NULL — see the header) ────────────
insert into public.hull_build_recipes
  (hull_type_id, credits_cost, build_seconds, required_hull_type_id, required_captain_level) values
  ('bulk_hauler',     400, 3600, null, null),
  ('strike_corvette', 400, 3600, null, null)
on conflict (hull_type_id) do nothing;

insert into public.hull_recipe_ingredients (hull_type_id, item_id, qty) values
  -- the hauler: bulk mining yields + the deep-run drive components + structure + the blueprint gate
  ('bulk_hauler',     'ore',                24),
  ('bulk_hauler',     'crystal',             6),
  ('bulk_hauler',     'engine_parts',        6),
  ('bulk_hauler',     'scrap',              12),
  ('bulk_hauler',     'blueprint_fragment',  2),
  -- the corvette: mining yields + the combat-component class + pirate salvage + the blueprint gate
  ('strike_corvette', 'ore',                16),
  ('strike_corvette', 'crystal',             4),
  ('strike_corvette', 'weapon_parts',        6),
  ('strike_corvette', 'pirate_alloy',        8),
  ('strike_corvette', 'blueprint_fragment',  2)
on conflict (hull_type_id, item_id) do nothing;

-- ── (f) pirate_loot_for_wave — 0171 head re-created with the marked blueprint-faucet delta ───────
-- Copied verbatim from 0171:88-119 (the TRUE head — see the parity section above). Delta: ONE
-- marked hunk appended AFTER the 0171 shard hunk; nothing else (diff-verified against the head).
create or replace function public.pirate_loot_for_wave(p_wave integer, p_danger numeric default 0)
returns jsonb
language plpgsql
volatile   -- CAPTAINS-LAUNCH (0171): was `immutable` (0041). Forced by the delta below (reads
           -- game_config + random() — both illegal under immutable); plpgsql call sites evaluate
           -- per call either way, so no caller's behavior changes. At rate 0 the OUTPUT is still
           -- byte-identical to the 0041 head for every input.
set search_path = public
as $$
declare
  v_items jsonb := '[]'::jsonb;
begin
  if p_wave is null or p_wave < 1 then
    return '[]'::jsonb;
  end if;
  -- guaranteed small scrap each cleared wave
  v_items := v_items || jsonb_build_object('item_id', 'scrap', 'quantity', 1);
  if p_wave >= 3  then v_items := v_items || jsonb_build_object('item_id', 'pirate_alloy', 'quantity', 1); end if;
  if p_wave >= 5  then v_items := v_items || jsonb_build_object('item_id', 'weapon_parts', 'quantity', 1); end if;
  if p_wave >= 8  then v_items := v_items || jsonb_build_object('item_id', 'engine_parts', 'quantity', 1); end if;
  if p_wave >= 10 then v_items := v_items || jsonb_build_object('item_id', 'repair_parts', 'quantity', 1); end if;
  -- CAPTAINS-LAUNCH (0171): the config-gated captain_memory_shard drop (packet F5 — the recruit
  -- economy's ONE source). Wave >= 2 keeps wave 1 deterministic (see header); appended AFTER every
  -- legacy element so the rate-0 array is byte-identical including order; flat qty 1 (the 0041
  -- anti-explosion posture). rate 0 (the seed) → `random() < 0` never fires → byte-inert.
  if p_wave >= 2 and random() < coalesce(cfg_num('captain_shard_drop_rate'), 0) then
    v_items := v_items || jsonb_build_object('item_id', 'captain_memory_shard', 'quantity', 1);
  end if;
  -- END CAPTAINS-LAUNCH (0171) delta — nothing else changed from the 0041 head.
  -- SHIPYARD-0 (0185): the config-gated blueprint_fragment drop — the SHIPYARD build-gate
  -- ingredient's repeatable combat faucet (the exploration site is a per-player one-shot, 0098).
  -- Wave >= 8 is the DEEP-RUN gate (the engine_parts depth; shards stay w>=2, wave 1 stays
  -- deterministic scrap-only at any rate); appended AFTER the 0171 shard hunk so the rate-0 array
  -- is byte-identical to the 0171 head including order; flat qty 1 (the 0041 anti-explosion
  -- posture). rate 0 (the seed) → `random() < 0` never fires → byte-inert.
  if p_wave >= 8 and random() < coalesce(cfg_num('blueprint_fragment_drop_rate'), 0) then
    v_items := v_items || jsonb_build_object('item_id', 'blueprint_fragment', 'quantity', 1);
  end if;
  -- END SHIPYARD-0 (0185) delta — nothing else changed from the 0171 head.
  return v_items;
end;
$$;

-- ── ACL — re-asserted for the re-created function (the 0041:353 posture verbatim: server-only;
--    service_role for CI verification; NEVER clients). The TARGETED idiom (0170/0171 precedent).
--    No other function's grants touched.
revoke execute on function public.pirate_loot_for_wave(integer, numeric) from public, anon, authenticated;
grant  execute on function public.pirate_loot_for_wave(integer, numeric) to service_role;

-- ── (g) SELF-ASSERTS — the migration proves its own grounding or refuses to land ─────────────────
do $$
declare
  v_n      integer;
  v_loot   text;
  v_got    jsonb;
  v_key    text;
begin
  -- (1) the gate is DARK and the faucet knob is 0 at seed time — this slice lands inert.
  if coalesce(public.cfg_bool('shipyard_enabled'), false) then
    raise exception 'SHIPYARD-0 self-assert FAIL: shipyard_enabled reads true at seed time (this slice must land dark)';
  end if;
  if (select value #>> '{}' from public.game_config where key = 'blueprint_fragment_drop_rate') is distinct from '0' then
    raise exception 'SHIPYARD-0 self-assert FAIL: blueprint_fragment_drop_rate is % at seed time (want 0 — the faucet must land inert)',
      (select value #>> '{}' from public.game_config where key = 'blueprint_fragment_drop_rate');
  end if;

  -- (2) both hulls present with the EXACT seeded stats (every gameplay column pinned — a partial
  --     landing would commission a wrong ship the day SHIPYARD-1 lights).
  select count(*) into v_n from public.main_ship_hull_types
    where (hull_type_id = 'bulk_hauler' and name = 'Mule-class Hauler'
           and base_hp = 650 and base_speed = 0.8
           and base_cargo_capacity = 140 and base_cargo_capacity_m3 = 140.0
           and base_support_capacity = 10 and base_captain_slots = 6 and base_module_slots = 2
           and base_stats_json = '{"attack": 5, "defense": 15}'::jsonb)
       or (hull_type_id = 'strike_corvette' and name = 'Talon-class Corvette'
           and base_hp = 420 and base_speed = 1.3
           and base_cargo_capacity = 20 and base_cargo_capacity_m3 = 20.0
           and base_support_capacity = 10 and base_captain_slots = 6 and base_module_slots = 4
           and base_stats_json = '{"attack": 30, "defense": 10}'::jsonb);
  if v_n <> 2 then
    raise exception 'SHIPYARD-0 self-assert FAIL: % of 2 hull rows carry the exact seeded stats', v_n;
  end if;
  -- the 0170 HULLSTATS law (every hull row carries numeric attack+defense) and the 0171 slot law
  -- (every hull at base_captain_slots 6) must survive this seed — the proof + activation scripts
  -- assert both across ALL hull rows.
  select count(*) into v_n from public.main_ship_hull_types
    where (base_stats_json->>'attack')::numeric is null or (base_stats_json->>'defense')::numeric is null
       or base_captain_slots is distinct from 6;
  if v_n <> 0 then
    raise exception 'SHIPYARD-0 self-assert FAIL: % hull row(s) break the 0170 stats / 0171 slots laws', v_n;
  end if;

  -- (3) recipes COMPLETE, exactly as seeded (a partial landing = a wrong price the day the build
  --     command lights — worse than no recipe): 2 header rows (T1 gates honestly NULL) + the 10
  --     exact ingredient rows, no strays.
  select count(*) into v_n from public.hull_build_recipes
    where hull_type_id in ('bulk_hauler', 'strike_corvette')
      and credits_cost = 400 and build_seconds = 3600
      and required_hull_type_id is null and required_captain_level is null;
  if v_n <> 2 then
    raise exception 'SHIPYARD-0 self-assert FAIL: % of 2 recipe header rows carry the exact seed (credits 400 / 3600s / NULL T1 gates)', v_n;
  end if;
  select count(*) into v_n from public.hull_recipe_ingredients
    where (hull_type_id, item_id, qty) in (
      ('bulk_hauler', 'ore', 24), ('bulk_hauler', 'crystal', 6),
      ('bulk_hauler', 'engine_parts', 6), ('bulk_hauler', 'scrap', 12),
      ('bulk_hauler', 'blueprint_fragment', 2),
      ('strike_corvette', 'ore', 16), ('strike_corvette', 'crystal', 4),
      ('strike_corvette', 'weapon_parts', 6), ('strike_corvette', 'pirate_alloy', 8),
      ('strike_corvette', 'blueprint_fragment', 2));
  if v_n <> 10 then
    raise exception 'SHIPYARD-0 self-assert FAIL: % of 10 ingredient rows carry the exact seeded (hull, item, qty)', v_n;
  end if;
  select count(*) into v_n from public.hull_recipe_ingredients;
  if v_n <> 10 then
    raise exception 'SHIPYARD-0 self-assert FAIL: hull_recipe_ingredients has % rows (want exactly 10 — no strays)', v_n;
  end if;

  -- (4) every ingredient item-typed (the FK already enforces it — asserted anyway, the 0183 (c)
  --     posture) AND drop-grounded (F4): combat items in the DEPLOYED pirate_loot_for_wave prosrc,
  --     mining items in a seeded mining_fields bundle at qty > 0, and blueprint_fragment BOTH in
  --     the deployed loot prosrc (this migration's w>=8 faucet) AND in an exploration_sites
  --     one-shot bundle at qty > 0 (0098) — two live sources for the gate ingredient.
  select count(*) into v_n
    from (select distinct item_id from public.hull_recipe_ingredients) i
    where not exists (select 1 from public.item_types t where t.item_id = i.item_id);
  if v_n <> 0 then
    raise exception 'SHIPYARD-0 self-assert FAIL: % recipe ingredient(s) missing from item_types', v_n;
  end if;
  select prosrc into v_loot from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'pirate_loot_for_wave';
  if v_loot is null then
    raise exception 'SHIPYARD-0 self-assert FAIL: pirate_loot_for_wave not found (the combat drop source)';
  end if;
  foreach v_key in array array['scrap', 'engine_parts', 'weapon_parts', 'pirate_alloy', 'blueprint_fragment'] loop
    if strpos(v_loot, '''' || v_key || '''') = 0 then
      raise exception 'SHIPYARD-0 self-assert FAIL: combat ingredient % has no drop in pirate_loot_for_wave (F4 breach)', v_key;
    end if;
  end loop;
  foreach v_key in array array['ore', 'crystal'] loop
    select count(*) into v_n
      from public.mining_fields f,
           lateral jsonb_array_elements(f.reward_bundle_json->'items') el
      where el->>'item_id' = v_key and (el->>'quantity')::numeric > 0;
    if v_n = 0 then
      raise exception 'SHIPYARD-0 self-assert FAIL: mining ingredient % drops from no mining field (F4 breach)', v_key;
    end if;
  end loop;
  select count(*) into v_n
    from public.exploration_sites s,
         lateral jsonb_array_elements(s.reward_bundle_json->'items') el
    where el->>'item_id' = 'blueprint_fragment' and (el->>'quantity')::numeric > 0;
  if v_n = 0 then
    raise exception 'SHIPYARD-0 self-assert FAIL: blueprint_fragment has no exploration one-shot source (0098 regression)';
  end if;

  -- (5) the loot parity spot-pins: the deployed body carries BOTH gated hunks in their exact
  --     idiom (knob token + threshold token), and behaves at the deterministic endpoints this
  --     migration controls — wave 1 is scrap-only EXACTLY at ANY knob values (both hunks gate
  --     w>=2 / w>=8), and at the committed rate-0 blueprint knob a deep wave yields NO blueprint
  --     element (strict-< against [0,1): rate 0 NEVER fires, regardless of the shard knob's
  --     current committed value — this assert is shard-tolerant by design).
  foreach v_key in array array['blueprint_fragment_drop_rate', 'p_wave >= 8', 'captain_shard_drop_rate', 'p_wave >= 2'] loop
    if strpos(v_loot, v_key) = 0 then
      raise exception 'SHIPYARD-0 self-assert FAIL: deployed pirate_loot_for_wave is missing the hunk token ''%'' (parity breach)', v_key;
    end if;
  end loop;
  v_got := public.pirate_loot_for_wave(1, 1);
  if v_got is distinct from jsonb_build_array(jsonb_build_object('item_id', 'scrap', 'quantity', 1)) then
    raise exception 'SHIPYARD-0 self-assert FAIL: wave-1 loot is not scrap-only: % (the deterministic-wave-1 law broke)', v_got;
  end if;
  v_got := public.pirate_loot_for_wave(10, 4);
  select count(*) into v_n from jsonb_array_elements(v_got) e where e->>'item_id' = 'blueprint_fragment';
  if v_n <> 0 then
    raise exception 'SHIPYARD-0 self-assert FAIL: rate-0 wave-10 loot carries a blueprint_fragment: % (the faucet is not inert)', v_got;
  end if;

  -- (6) craftability shape (the 0183 (e) analogue): every recipe header has ingredient rows, every
  --     ingredient set has a header (no orphans either way) — a player holding the listed items +
  --     credits faces the COMPLETE price, publicly readable (the catalog posture makes the recipe
  --     rows client-visible for the future shipyard UI's price display).
  select count(*) into v_n from public.hull_build_recipes r
    where not exists (select 1 from public.hull_recipe_ingredients i where i.hull_type_id = r.hull_type_id);
  if v_n <> 0 then
    raise exception 'SHIPYARD-0 self-assert FAIL: % recipe header(s) with zero ingredient rows', v_n;
  end if;
  select count(*) into v_n from public.hull_recipe_ingredients i
    where not exists (select 1 from public.hull_build_recipes r where r.hull_type_id = i.hull_type_id);
  if v_n <> 0 then
    raise exception 'SHIPYARD-0 self-assert FAIL: % ingredient row(s) with no recipe header', v_n;
  end if;

  raise notice 'SHIPYARD-0 self-assert ok: gate dark + faucet knob 0; 2 hulls exact (Mule 650/0.8/140/2 slots {5,15}; Talon 420/1.3/20/4 slots {30,10}; 0170 stats + 0171 slots laws hold); 2 recipe headers (400 cr / 3600s / NULL T1 gates) + 10 exact ingredient rows; every ingredient item-typed + drop-grounded (loot prosrc, field bundles, blueprint dual-source); loot hunk tokens pinned, wave-1 deterministic, rate-0 faucet inert';
end $$;
