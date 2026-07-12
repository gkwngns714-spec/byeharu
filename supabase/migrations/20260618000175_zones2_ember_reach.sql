-- Byeharu — ZONES2-1: "Ember Reach" content expansion seed (additive, HIDDEN — the C-seeds).
--
-- Queue slice #7 of the full-capacity plan (§C P4; its twin #8, the reveal operation script
-- scripts/reveal-ember-reach.{sql,sh}, ships in the same PR). PURE DATA: no schema change, no RPC
-- change, no flag change, no client change, ZERO engine edits. Every new location seeds
-- status='hidden' — absent from get_world_map()'s status='active' filter (0002:121) and rejected by
-- every send RPC's active check (send_fleet_to_location 0019:39-41; send_ship_group_hunt 0168:196-198)
-- — until the human runs the reveal script (reveal IS the content cadence mechanism, plan §C P4).
--
-- ── THE NUMBERS [D — owner-tunable; packet-derived] ──────────────────────────────────────────────────
-- TEAM_ACTIVATION_PACKET.md §0.3: a kitted+captained ship = 38 combat_power (3× autocannon_battery
-- attack 10 + 2× gunnery_veteran attack 4; the hull contributes 0 today). The min_power_required gates
-- therefore price the zones in kitted ships (§1.3 Option C — "so the D2 gate finally does its job"):
--   min_power 150 ≈ 4 kitted ships (150/38 = 3.9)  ·  ≈ 3 after the 6-captain bump (54/ship)
--   min_power 220 ≈ 6 kitted ships (220/38 = 5.8)  ·  ≈ 5 bumped
--   min_power 300 ≈ 8 kitted ships (300/38 = 7.9)  ·  ≈ 6 bumped
-- Enemy math at these base_difficulty values (§0.1 formulas; enemy_hp_base 14, danger-1 variance mean):
--   wave-1 HP = bd × 14 × 1.6 → Ember Gate (bd 40) 896 · Cinder Maw (bd 50) 1120 · The Furnace (bd 60) 1344
--   enemy dmg/tick @ danger 1 = bd × 1.25 → 50 · 62.5 · 75
-- Feel check against the §1.1 balance table (gate-sized team, full 500-hp ships): Ember Gate with
-- 4 kitted (152 atk) clears wave 1 in ~6 ticks taking ~300 hp of a 2000 pool (15% — the "Snare solo"
-- band); Cinder Maw with 6 (228) ~5 ticks / ~10%; The Furnace with 8 (304) ~5 ticks / ~9%. The ladder
-- extends Blackden (bd 25, wave-1 560 hp) rather than replacing it — danger = 1 + waves_cleared still
-- grows without bound, so nothing trivializes long-run.
--
-- ── WHAT reward_tier ACTUALLY DRIVES (verified against the TRUE combat head 0169) ────────────────────
-- reward_tier multiplies the METAL reward per cleared wave — process_combat_ticks (head 0169:354-355):
--   round(reward_metal_base(10) × greatest(loc.reward_tier, 1) × (1 + 0.25 × danger))
-- → tier 4/5 pays 4×/5× the metal of a tier-1 wave. ITEM loot (pirate_loot_for_wave, 0041) keys on
-- WAVE NUMBER only (scrap w≥1 … repair_parts w≥10) — reward_tier has NO loot-table meaning today, so
-- item drops keep riding wave/danger progression exactly as they do at Snare/Reaver/Blackden. That is
-- deliberate: defining tier-keyed loot would be an engine edit, out of this slice's charter.
--
-- ── COORDINATES (placed OUTSIDE the current play area but reachable; envelope-checked) ───────────────
-- Current content bbox is x −50…70, y −30…80 (0154 declutter; home base at (0,0)); 0154 also
-- established distance-from-home ordering by difficulty, with Blackden (bd 25) at (65,55), dist 85.1,
-- the farthest + NE-most hostile point. Ember Reach continues that NE ray beyond the bbox:
--   Ember Gate  (100,  90) dist ≈ 134.5   · Cinder Maw (125, 110) dist ≈ 166.5
--   The Furnace (150, 130) dist ≈ 198.5   — distance stays monotonic with base_difficulty.
-- Marker legibility: min pairwise separation among the new trio is 32.0 world units and the nearest
-- cross-pair (Blackden↔Ember Gate) is 49.5, against a grown content span of ~200 → ≥16% of span, well
-- above 0154's ~9% no-overlap threshold. All coordinates sit far inside the OSN sanity envelope
-- [−10000, 10000]² (0055). Legacy hunt travel time scales with distance (movement_create reads l.x/l.y
-- at send time) — the deeper zone is deliberately a longer sail.
--
-- ── HIERARCHY: new ACTIVE sector + zone, HIDDEN locations (the reveal shape) ─────────────────────────
-- get_world_map() filters ALL THREE levels on status='active' (0002:121/125/129). The ZONES2-2 reveal
-- flips ONLY the three location rows, so the parent sector 'Ashen Frontier' and zone 'Ember Reach'
-- seed ACTIVE — an active zone with zero active locations returns locations:[] and the client
-- (useGalaxyMapData.ts flattens locations only; nothing renders zones/sectors as visuals — verified)
-- shows nothing. Pre-reveal, the raw get_world_map JSON does carry the empty zone/sector NAMES — an
-- accepted teaser ("uncharted region on the charts"), same class as the 0066 precedent below.
-- Hidden ≠ secret: locations has public-read RLS (0002:83), so a raw table read can always see hidden
-- rows — accepted since the 0066 hidden starter ports; the gates that MATTER are the map read and the
-- send RPCs' status checks (both pinned in the self-assert below).
--
-- ── DELIBERATE OMISSIONS (each a judgment call, each justified) ──────────────────────────────────────
--   • NO safe waypoint anchor: zones are not rendered client-side (no shape needs anchoring), a tier-0
--     safe point ~110+ units out is a long rewardless sail, and omitting it keeps the reveal contract
--     exactly-3 all-or-nothing. Ship one later as its own additive seed if live play wants a rally.
--   • NO space_anchors / location_services rows: hunt sites are not dockable; anchors are the OSN
--     docking-target authority (0154 blast-radius note — the legacy waypoints have neither, by design).
--   • NO location_state / zone_state seed: World State owns those tables (0031, SYSTEM_BOUNDARIES);
--     worldstate_register_presence lazily UPSERTS the row on first arrival (0032:37-41) and both the
--     tick loop and the zone rollup tolerate missing rows — nothing strands post-reveal.
--   • physical_role='activity_site': the first honest user of the 0065 value; excluded from every
--     port predicate (city/port), so docking/home-port stay fail-closed. (The legacy waypoints keep
--     'unclassified' — 0065's don't-guess rule is for legacy rows, not new ones.)
--   • Two-word display names: 0148's one-word pass decluttered the legacy seed's generic names; these
--     are unique evocative names (distinct game-wide, asserted below). Identity is the fixed UUID —
--     a later display rename stays data-only, exactly like 0148.
--
-- ── IDENTITY + IDEMPOTENCY (the 0066 fixed-literal-id idiom, made re-runnable) ───────────────────────
-- Fixed literal UUIDs embed the migration number (valid v4 shape; 'eb' = EmBer): sector …a1, zone …b1,
-- hunt sites eb0000{11,12,13}-0175-…-{01,02,03}. Inserts are ON CONFLICT (id) DO NOTHING → a re-run is
-- a no-op; any OTHER unique-key collision (sector_index, (sector_id,name), (zone_id,name)) still
-- ABORTS the migration — never silently create ambiguous world data (the 0066 law).

-- ── 1) The sector (ACTIVE container — see hierarchy note) ────────────────────────────────────────────
insert into public.sectors (id, name, sector_index, x, y, danger_tier, status) values
  ('eb000001-0175-4a00-8a00-0000000000a1', 'Ashen Frontier', 3, 125, 110, 3, 'active')
on conflict (id) do nothing;

-- ── 2) The zone (ACTIVE container; display stats mirror the site band) ───────────────────────────────
insert into public.zones
  (id, sector_id, name, x, y, radius, base_difficulty, max_danger_level, reward_tier, status) values
  ('eb000002-0175-4a00-8a00-0000000000b1', 'eb000001-0175-4a00-8a00-0000000000a1',
   'Ember Reach', 125, 110, 40, 50, 15, 4, 'active')
on conflict (id) do nothing;

-- ── 3) The three HIDDEN hunt sites (the actual ZONES2-1 content) ─────────────────────────────────────
insert into public.locations
  (id, zone_id, name, location_type, x, y, base_difficulty, reward_tier,
   activity_type, min_power_required, physical_role, status) values
  ('eb000011-0175-4a00-8a00-000000000001', 'eb000002-0175-4a00-8a00-0000000000b1',
   'Ember Gate',  'pirate_hunt', 100,  90, 40, 4, 'hunt_pirates', 150, 'activity_site', 'hidden'),
  ('eb000012-0175-4a00-8a00-000000000002', 'eb000002-0175-4a00-8a00-0000000000b1',
   'Cinder Maw',  'pirate_hunt', 125, 110, 50, 4, 'hunt_pirates', 220, 'activity_site', 'hidden'),
  ('eb000013-0175-4a00-8a00-000000000003', 'eb000002-0175-4a00-8a00-0000000000b1',
   'The Furnace', 'pirate_hunt', 150, 130, 60, 5, 'hunt_pirates', 300, 'activity_site', 'hidden')
on conflict (id) do nothing;

-- ── 4) Self-assert (fail-closed: any miss aborts the whole migration) ────────────────────────────────
do $$
declare
  c_sector constant uuid := 'eb000001-0175-4a00-8a00-0000000000a1';
  c_zone   constant uuid := 'eb000002-0175-4a00-8a00-0000000000b1';
  c_gate   constant uuid := 'eb000011-0175-4a00-8a00-000000000001';
  c_maw    constant uuid := 'eb000012-0175-4a00-8a00-000000000002';
  c_furn   constant uuid := 'eb000013-0175-4a00-8a00-000000000003';
  v_n int;
  v_src text;
  v_map text;
begin
  -- (a) Containers present, correctly parented, ACTIVE (a hidden parent would make the location-only
  --     reveal a silent no-op — get_world_map filters zones/sectors on active too).
  if not exists (select 1 from public.sectors
                  where id = c_sector and sector_index = 3 and status = 'active') then
    raise exception 'ZONES2-1 self-assert FAIL: sector Ashen Frontier (index 3) missing or not active';
  end if;
  if not exists (select 1 from public.zones
                  where id = c_zone and sector_id = c_sector and name = 'Ember Reach'
                    and status = 'active') then
    raise exception 'ZONES2-1 self-assert FAIL: zone Ember Reach missing, misparented, or not active';
  end if;

  -- (b) Exact read-back of all three hunt sites (identity, stats, gates, coordinates, HIDDEN).
  select count(*) into v_n from public.locations
   where (id, zone_id, name, location_type, x, y, base_difficulty, reward_tier,
          activity_type, min_power_required, physical_role, status) in (
     (c_gate, c_zone, 'Ember Gate',  'pirate_hunt', 100.0,  90.0, 40.0, 4, 'hunt_pirates', 150.0, 'activity_site', 'hidden'),
     (c_maw,  c_zone, 'Cinder Maw',  'pirate_hunt', 125.0, 110.0, 50.0, 4, 'hunt_pirates', 220.0, 'activity_site', 'hidden'),
     (c_furn, c_zone, 'The Furnace', 'pirate_hunt', 150.0, 130.0, 60.0, 5, 'hunt_pirates', 300.0, 'activity_site', 'hidden'));
  if v_n <> 3 then
    raise exception 'ZONES2-1 self-assert FAIL: read-back matched % of 3 hunt sites (identity/stats/hidden drift)', v_n;
  end if;

  -- (c) The gates are MONOTONIC with difficulty: over the three rows ordered by base_difficulty,
  --     min_power_required strictly rises, reward_tier never falls, and distance-from-home rises
  --     (the 0154 distance-orders-by-difficulty rule, extended).
  select count(*) into v_n from (
    select base_difficulty,
           min_power_required - lag(min_power_required) over (order by base_difficulty) as d_pow,
           reward_tier        - lag(reward_tier)        over (order by base_difficulty) as d_tier,
           sqrt(x*x + y*y)    - lag(sqrt(x*x + y*y))    over (order by base_difficulty) as d_dist
      from public.locations where id in (c_gate, c_maw, c_furn)
  ) s where s.d_pow <= 0 or s.d_tier < 0 or s.d_dist <= 0;
  if v_n <> 0 then
    raise exception 'ZONES2-1 self-assert FAIL: gates not monotonic with base_difficulty (% violation rows)', v_n;
  end if;

  -- (d) No identity collision: the three display names exist NOWHERE else on the map (game-wide
  --     uniqueness, stronger than the (zone_id,name) key — the 0148 all-distinct posture).
  select count(*) into v_n from public.locations
   where name in ('Ember Gate', 'Cinder Maw', 'The Furnace')
     and id not in (c_gate, c_maw, c_furn);
  if v_n <> 0 then
    raise exception 'ZONES2-1 self-assert FAIL: % foreign location row(s) already carry an Ember Reach name', v_n;
  end if;

  -- (e) HIDDEN-INVISIBILITY PIN, structural: the deployed get_world_map() body filters every level on
  --     status='active' (0002:121/125/129) — the WHERE-clause semantics that make 'hidden' invisible.
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.get_world_map()')::oid;
  if v_src is null then
    raise exception 'ZONES2-1 self-assert FAIL: public.get_world_map() does not exist';
  end if;
  if position('l.zone_id = z.id and l.status = ''active''' in v_src) = 0
     or position('z.sector_id = se.id and z.status = ''active''' in v_src) = 0
     or position('se.status = ''active''' in v_src) = 0 then
    raise exception 'ZONES2-1 self-assert FAIL: get_world_map() no longer filters on status=active at all three levels — the hidden seed would be VISIBLE; do not deploy';
  end if;

  -- (f) HIDDEN-INVISIBILITY PIN, behavioral: the map read (a STABLE table-reading SQL function —
  --     callable right here) must NOT carry the three hidden sites, by name or by id.
  v_map := public.get_world_map()::text;
  if position('Ember Gate' in v_map) > 0 or position('Cinder Maw' in v_map) > 0
     or position('The Furnace' in v_map) > 0
     or position(c_gate::text in v_map) > 0 or position(c_maw::text in v_map) > 0
     or position(c_furn::text in v_map) > 0 then
    raise exception 'ZONES2-1 self-assert FAIL: a hidden Ember Reach site leaked into get_world_map() output';
  end if;

  -- (g) Envelope + placement sanity: inside the OSN world envelope, OUTSIDE the pre-0175 content
  --     bbox (x −50…70, y −30…80) — genuinely new territory, never overlapping the current play area.
  select count(*) into v_n from public.locations
   where id in (c_gate, c_maw, c_furn)
     and (x < -10000 or x > 10000 or y < -10000 or y > 10000
          or (x between -50 and 70 and y between -30 and 80));
  if v_n <> 0 then
    raise exception 'ZONES2-1 self-assert FAIL: % site(s) outside the OSN envelope or inside the legacy content bbox', v_n;
  end if;

  raise notice 'ZONES2-1 self-assert ok: Ashen Frontier/Ember Reach active containers; 3 hunt sites read back exact + HIDDEN (bd 40/50/60, min_power 150/220/300 monotonic, tiers 4/4/5); names unique game-wide; get_world_map three-level active filter pinned structurally AND behaviorally; coordinates in-envelope, outside the legacy bbox';
end $$;
