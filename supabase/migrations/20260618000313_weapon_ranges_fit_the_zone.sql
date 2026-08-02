-- Byeharu — WEAPON RANGES FIT THE ZONE. Migration 0313. Pure DATA/CONFIG retune — this file
-- re-creates NO function, touches NO schema, and needs NO generator/parity machinery. Every consumer
-- reads these values at runtime (cfg_num / the module_types row), so the cut takes effect on the
-- next encounter creation / wave spawn with zero plpgsql change.
--
-- ── THE OWNER'S DECISION, VERBATIM ──────────────────────────────────────────────────────────────────
--   "cut the weapon ranges"
--
-- ── WHY (measured on production 2026-08-02, re-verified read-only the same day) ────────────────────
-- The three live pirate zones are 79.2×47.3 (Snare), 35.1×31.4 (Reaver), 28.6×29.6 (Blackden) world
-- units across, while weapon ranges were 120–245 (enemy: 120 + 5·difficulty at live difficulties
-- 10/15/25; player: 150/180). Combat geometry: every enemy spawns AT the engagement anchor
-- (0299:765-774), the command ship spawns ON the anchor (0301:755-757), escorts on the
-- spatial_formation_ring_radius=30 ring (0301:759-761). So every unit has ALWAYS been inside every
-- range from tick 1, and combat_unit_decide_move (0234:242-259) — which returns 'close' only when
-- dist > my_range and 'kite' only when dist > target_range — has NEVER returned anything but 'hold'
-- in a real fight. Position has never mattered. This migration cuts the ranges below the 30-unit
-- spawn gap so the CLOSE/KITE arms fire for the first time in the game's life.
--
-- ── THE NUMBERS, AND THE ARITHMETIC THAT PICKED THEM ────────────────────────────────────────────────
--   enemy_synthetic_range_base              120  -> 18
--   enemy_synthetic_range_per_difficulty      5  -> 0.2
--   combat_player_fallback_weapon_range     150  -> 25
--   module_types.autocannon_battery.range   150  -> 25
--   module_types.autocannon_battery_mk2.range 180 -> 30
--
-- Enemy range = 18 + 0.2·difficulty. At the LIVE difficulties (Snare 10, Reaver 15, Blackden 25):
-- 20 / 21 / 23. At the hidden, power-gated Ember tier (40/50/60): 26 / 28 / 30.
--   • The player's basic gun (25) STRICTLY out-ranges every live pirate (max 23). This is
--     load-bearing, not flavour — THE STANDOFF ARITHMETIC, re-derived from the code rather than
--     asserted (enemy move_speed is 3 + 0.2·difficulty = 5–8 at live sites; player in-combat
--     move_speed is the hull's base_speed ≈ 0.8–1.3 — 0043:39, 0185:143,147, 0122:259):
--       – Every unit moves from a snapshot frozen BEFORE any movement is applied (0299:802-813), so
--         within one tick the two moves are SIMULTANEOUS: the distance change is (enemy step) −
--         (player step), both measured from the same pre-move distance d.
--       – The KITE step is `least(v_e, R_e − d)` (0234:250-251): a kiter may never retreat past its
--         OWN range edge. The player, out-ranged, CLOSEs by its full v_p (0234:248-249).
--       – So d ↦ d + least(v_e, R_e − d) − v_p, which has a STABLE FIXED POINT at d* = R_e − v_p
--         whenever v_e ≥ v_p: at d*, the cap re-opens by exactly the v_p the player just closed, so
--         the kiter recovers it every tick, forever. Worked, R_e=30 / R_p=25 / v_p=1: an escort
--         spawned on the 30 ring is kited to 29 and stays at 29 for every tick of the fight.
--       – The player's fire gate is `pre-move distance ≤ its own range` (0299:872-873). It therefore
--         NEVER lands a shot while R_e − v_p > R_p — i.e. whenever the enemy out-ranges the player
--         by more than the player's own per-tick speed (~1). It is the enemy's RANGE that builds
--         the wall; its speed only has to be ≥ the player's for the wall to hold.
--     An earlier draft of this slice proposed per_difficulty = 1 (enemy 30/35/45 at live sites,
--     4–20 units above the 25 gun — far beyond the ~1 tolerance): a permanent standoff in which the
--     player takes fire without ever landing a shot. Rejected on exactly that arithmetic.
--   • Mk-II (30) out-ranges everything up to and including the deepest hidden site (The Furnace,
--     d=60 → 30) — the upgrade keeps a real edge everywhere.
--   • The 30-unit spawn ring now sits ABOVE every live range: escorts and enemies must close before
--     they can fire (mutual closure at ~(3+0.2d) + ~1 units/tick ≈ 6–9/tick → the escort's first
--     shot lands on tick 2–3, full mutual engagement by tick 3–4 ≈ 9–12 s at combat_tick_seconds=3).
--     The COMMAND ship spawns at distance 0 from the enemy stack, so a fight always starts firing on
--     tick 1 — closure adds theatre, never a stall. Mk-II escorts (range 30 = the ring) fire from
--     their formation slot on tick 1: a felt difference between the two guns.
--
-- ── DELIBERATELY NOT TOUCHED (asserted unchanged below) ─────────────────────────────────────────────
--   • mining_rig_extension.range (120) — slot_type='mining': it is the mining EXTRACTION radius when
--     module_range_attributes_enabled is lit (0229 §5) and feeds ship_weapon_modules
--     (0229:159-188). 0308's module_is_firing_weapon already excludes it from combat. Changing it
--     would silently retune mining.
--   • spatial_formation_ring_radius (30) — the spawn gap IS the closure theatre; with ranges 18–30
--     straddling it, cutting the ring would put everyone back in range at tick 1 and re-bury the
--     mechanic this slice exists to unlock.
--   • powers, projectile speeds, cooldowns, enemy speeds — the owner cut RANGES; damage/pacing knobs
--     are a separate balance decision.
--
-- ── EVERY CONSUMER OF EVERY CHANGED VALUE (the whole-slice check) ───────────────────────────────────
--   enemy_synthetic_range_base / _per_difficulty → process_combat_ticks (TRUE head 0299:705-706
--     resolved arm, 0299:756-757 synthetic arm) → frozen into enemy weapons_json at wave spawn.
--   combat_player_fallback_weapon_range → combat_create_group_encounter (TRUE head = 0308's hunk-2
--     rewrite of 0301:661-862; the fallback block is 0301:791-802 text) → frozen into player
--     weapons_json at creation for any ship with no firing weapon fitted.
--   module_types.range (the two guns) → the creator's fitting join (0301:767-776, filtered by
--     module_is_firing_weapon since 0308) → player weapons_json; ship_weapon_modules (0229:159-188,
--     no live client caller — grep-verified src/ has zero references); the tick's fire gate
--     (0299:872-873) and movement snapshot my_range (0299:807) consume weapons_json, never the
--     catalog directly; the client range rings (src/features/map/spatialCombatLayer.ts:49-55,207-215)
--     derive from combat_units.weapons_json — no client constant carries a range.
--   Proof harnesses repointed IN THIS SLICE (they asserted the old seeds as ambient defaults):
--     scripts/danger-combat-proof.sql (SPATIAL block; + the new CLOSURE runtime proof),
--     scripts/combat-spatial-proof.sql, scripts/combat-fallback-weapon-proof.sql.
--   In-flight encounters at deploy: weapons_json is frozen at creation/wave-spawn, so a fight open
--     at deploy keeps its old ranges until its NEXT wave spawns (which reads the new enemy knobs);
--     player units keep old ranges until the fight ends. No mid-fight contradiction — the same
--     freeze that protects dark-flag flips (0234 header) protects this retune.
--
-- ── EXACTLY-ONCE / FAIL-CLOSED ─────────────────────────────────────────────────────────────────────
-- Every UPDATE is guarded on the exact OLD value (production re-verified today: config 120/5/150,
-- catalog 150/180). A re-apply, or an apply against a drifted world, updates nothing — and the
-- self-asserts below then ABORT the migration rather than let a silent no-op ship. A later owner
-- retune can never be clobbered by replaying this file.
--
-- ── WHY THE EXPLICIT TRANSACTION BLOCK (the same guard every sibling carries: 0308:153-156,
--    0310:174-177, 0311:202-205, 0312:107-110) ──────────────────────────────────────────────────────
-- This file writes public.game_config and public.module_types — the two tables read by EVERY combat
-- tick (0299) and every fitting RPC, on a LIVE ~30-player production. Without `set local
-- lock_timeout`, an UPDATE that meets a concurrent tick's row lock waits INDEFINITELY, and a
-- migration hung inside `supabase db push` blocks every migration after it. 5s fails fast instead;
-- the deploy is then re-run in a quiet window. `statement_timeout` bounds the self-asserts the same
-- way, and `time zone 'UTC'` pins the `now()` the description `updated_at` stamps carry.
-- The block is also what makes `create temp table … on commit drop` (below) mean anything: outside an
-- explicit transaction each statement is its own txn, so the capture table would be dropped before
-- the asserts that read it ever ran.
--
-- Forward-only: 0001–0310 unedited. 0311 (reposition-in-zone) and 0312 (no-living-ships) are in
-- flight on sibling branches; both re-create plpgsql and neither writes these config keys or
-- module_types rows — verified by grepping both branches' migration files on origin
-- (origin/slice-reposition-in-zone, origin/slice-no-living-ships-no-orders): zero hits for any key
-- or catalog row this file touches. All three slices DO append blocks to
-- scripts/danger-combat-proof.{sql,sh} — an ordinary textual merge at integration time, not a
-- semantic conflict.

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ── 0) CAPTURE the deliberately-untouched values BEFORE any write (derived, never hard-coded) ──────
create temp table _0313_before (k text primary key, v text) on commit drop;
insert into _0313_before
select 'rig_' || key, value from (
  select 'range' as key, range::text as value from public.module_types where id = 'mining_rig_extension'
  union all select 'power', power::text from public.module_types where id = 'mining_rig_extension'
  union all select 'slot_type', slot_type from public.module_types where id = 'mining_rig_extension'
  union all select 'projectile_speed', coalesce(projectile_speed::text, '<null>') from public.module_types where id = 'mining_rig_extension'
  union all select 'cooldown_seconds', cooldown_seconds::text from public.module_types where id = 'mining_rig_extension'
) rig;
insert into _0313_before
select 'cfg_' || key, value::text from public.game_config
 where key in ('spatial_formation_ring_radius',
               'enemy_synthetic_speed_base', 'enemy_synthetic_speed_per_difficulty',
               'enemy_synthetic_projectile_speed', 'enemy_synthetic_cooldown_seconds',
               'enemy_synthetic_max_units',
               'combat_player_fallback_weapon_projectile_speed',
               'combat_player_fallback_weapon_cooldown_seconds',
               'combat_player_fallback_weapon_power_from_attack');
insert into _0313_before
select 'gun_' || id || '_' || key, value from (
  select id, 'power' as key, power::text as value from public.module_types where id in ('autocannon_battery','autocannon_battery_mk2')
  union all select id, 'projectile_speed', projectile_speed::text from public.module_types where id in ('autocannon_battery','autocannon_battery_mk2')
  union all select id, 'cooldown_seconds', cooldown_seconds::text from public.module_types where id in ('autocannon_battery','autocannon_battery_mk2')
  union all select id, 'slot_type', slot_type from public.module_types where id in ('autocannon_battery','autocannon_battery_mk2')
) guns;

-- ── 1) THE CONFIG CUT (guarded on the exact old values; descriptions updated where they carried
--       the stale numbers) ─────────────────────────────────────────────────────────────────────────
update public.game_config
   set value = '18'::jsonb,
       description = 'COMBAT-S3 (0234, retuned 0313): synthetic pirate weapon range at '
                     'base_difficulty=0 (world units). Cut 120->18 so ranges fit inside the pirate '
                     'zones (29-79 units across) and the CLOSE/KITE movement arms actually run; with '
                     '_per_difficulty this stays strictly under the player basic gun at every LIVE '
                     'difficulty: a longer-ranged kiter settles at the fixed distance (its own range '
                     '- the player speed) and the ~1-speed player then never lands a shot at all.',
       updated_at = now()
 where key = 'enemy_synthetic_range_base' and value = '120'::jsonb;

update public.game_config
   set value = '0.2'::jsonb,
       description = 'COMBAT-S3 (0234, retuned 0313): synthetic pirate weapon range added per point '
                     'of base_difficulty. Cut 5->0.2: at live difficulties 10/15/25 enemy range is '
                     '20/21/23 (under the 25 basic gun); at the hidden Ember tier (40-60) it is '
                     '26-30 (basic guns are out-ranged there, Mk-II never is).',
       updated_at = now()
 where key = 'enemy_synthetic_range_per_difficulty' and value = '5'::jsonb;

update public.game_config
   set value = '25'::jsonb,
       description = 'COMBAT-FALLBACK (0262, retuned 0313): world-unit range of the synthesized '
                     'basic player weapon. Kept equal to the entry-tier autocannon_battery range '
                     '(the player basic-weapon default), DISTINCT from the enemy synthetic''s knob.',
       updated_at = now()
 where key = 'combat_player_fallback_weapon_range' and value = '150'::jsonb;

-- ── 2) THE CATALOG CUT (the two firing weapons; nothing else in the row moves) ─────────────────────
update public.module_types set range = 25
 where id = 'autocannon_battery' and range = 150;

update public.module_types set range = 30
 where id = 'autocannon_battery_mk2' and range = 180;

-- ── SELF-ASSERTS — one DO block per check; every write asserted, every deliberate non-write pinned ──

-- (a) the three knobs carry exactly the new values (a drifted base would have no-opped the guarded
--     UPDATE — this is the fail-closed abort for that case).
do $$
begin
  if coalesce(public.cfg_num('enemy_synthetic_range_base'), -1) <> 18 then
    raise exception '0313 ASSERT (a) FAIL: enemy_synthetic_range_base reads % (want 18) — the guarded UPDATE did not land; the deployed value had drifted off 120',
      public.cfg_num('enemy_synthetic_range_base');
  end if;
  if coalesce(public.cfg_num('enemy_synthetic_range_per_difficulty'), -1) <> 0.2 then
    raise exception '0313 ASSERT (a) FAIL: enemy_synthetic_range_per_difficulty reads % (want 0.2)',
      public.cfg_num('enemy_synthetic_range_per_difficulty');
  end if;
  if coalesce(public.cfg_num('combat_player_fallback_weapon_range'), -1) <> 25 then
    raise exception '0313 ASSERT (a) FAIL: combat_player_fallback_weapon_range reads % (want 25)',
      public.cfg_num('combat_player_fallback_weapon_range');
  end if;
end $$;

-- (b) the two guns carry exactly the new ranges, still satisfy module_types_range_nonneg (>0), and
--     are still firing weapons by THE authority (0308's module_is_firing_weapon), so the creator's
--     fitting join still snapshots them.
do $$
declare t public.module_types;
begin
  select * into t from public.module_types where id = 'autocannon_battery';
  if t.range is distinct from 25 then
    raise exception '0313 ASSERT (b) FAIL: autocannon_battery.range is % (want 25)', t.range;
  end if;
  if not public.module_is_firing_weapon(t) then
    raise exception '0313 ASSERT (b) FAIL: autocannon_battery no longer passes module_is_firing_weapon — the cut broke the weapon authority';
  end if;
  select * into t from public.module_types where id = 'autocannon_battery_mk2';
  if t.range is distinct from 30 then
    raise exception '0313 ASSERT (b) FAIL: autocannon_battery_mk2.range is % (want 30)', t.range;
  end if;
  if not public.module_is_firing_weapon(t) then
    raise exception '0313 ASSERT (b) FAIL: autocannon_battery_mk2 no longer passes module_is_firing_weapon';
  end if;
end $$;

-- (c) mining_rig_extension is BYTE-UNTOUCHED (compared to the pre-write capture, never a hard-coded
--     expectation) and is still NOT a firing weapon.
--     ABSENCE IS FAILURE, not a pass: if the row were gone, the pre-write capture at the top would
--     have inserted ZERO rig_* rows, the comparison below would join against nothing and yield NULL,
--     `select * into t` would leave t all-NULL, and module_is_firing_weapon(t) would raise nothing —
--     the whole assert would pass while the mining extraction radius had vanished. Both the row and
--     the capture are therefore pinned first. (Compare (b), where a vanished gun row already aborts
--     because NULL IS DISTINCT FROM 25.)
do $$
declare t public.module_types; v_bad text; v_n int;
begin
  select count(*) into v_n from _0313_before where k like 'rig\_%' escape '\';
  if v_n <> 5 then
    raise exception '0313 ASSERT (c) FAIL: the pre-write capture holds % mining_rig_extension attribute(s) (want 5) — the catalog row was already absent BEFORE this migration wrote anything, so the byte-comparison below would prove nothing', v_n;
  end if;
  select * into t from public.module_types where id = 'mining_rig_extension';
  if not found then
    raise exception '0313 ASSERT (c) FAIL: module_types row mining_rig_extension is GONE — the mining EXTRACTION radius (slot_type=mining, 0229 §5) this migration must never touch no longer exists';
  end if;
  select string_agg(b.k || ': ' || b.v || ' -> ' || cur.v, '; ') into v_bad
    from _0313_before b
    join (values ('rig_range',            t.range::text),
                 ('rig_power',            t.power::text),
                 ('rig_slot_type',        t.slot_type),
                 ('rig_projectile_speed', coalesce(t.projectile_speed::text, '<null>')),
                 ('rig_cooldown_seconds', t.cooldown_seconds::text)) as cur(k, v) on cur.k = b.k
   where cur.v is distinct from b.v;
  if v_bad is not null then
    raise exception '0313 ASSERT (c) FAIL: mining_rig_extension changed (%) — this migration must never touch the mining extraction radius', v_bad;
  end if;
  if public.module_is_firing_weapon(t) then
    raise exception '0313 ASSERT (c) FAIL: mining_rig_extension passes module_is_firing_weapon — a rig is a gun again (the 0308 defect resurrected)';
  end if;
end $$;

-- (d) every other tuning knob this slice deliberately did NOT move is byte-unchanged (derived from
--     the pre-write capture — asserting no collateral write, not an ambient seed).
do $$
declare v_bad text;
begin
  select string_agg(b.k || ': ' || b.v || ' -> ' || coalesce(g.value::text, '<gone>'), '; ') into v_bad
    from _0313_before b
    left join public.game_config g on 'cfg_' || g.key = b.k
   where b.k like 'cfg\_%' escape '\'
     and coalesce(g.value::text, '<gone>') is distinct from b.v;
  if v_bad is not null then
    raise exception '0313 ASSERT (d) FAIL: an untouched config knob changed under this migration (%)', v_bad;
  end if;
end $$;

-- (e) the guns' non-range attributes are byte-unchanged (power/projectile_speed/cooldown/slot).
--     Same absence-is-failure pin as (c): a vanished gun row would empty one side of the join and
--     the comparison would pass vacuously. BOTH sides are counted first — 2 guns x 4 attributes = 8.
do $$
declare v_bad text; v_n int; v_cur int;
begin
  select count(*) into v_n from _0313_before where k like 'gun\_%' escape '\';
  if v_n <> 8 then
    raise exception '0313 ASSERT (e) FAIL: the pre-write capture holds % gun attribute(s) (want 8 = 2 guns x 4 attributes) — a gun catalog row was already absent BEFORE this migration wrote anything, so the comparison below would prove nothing', v_n;
  end if;
  select count(*) into v_cur
    from public.module_types
   where id in ('autocannon_battery','autocannon_battery_mk2');
  if v_cur <> 2 then
    raise exception '0313 ASSERT (e) FAIL: % of the 2 gun catalog rows survive this migration — a firing-weapon row VANISHED', v_cur;
  end if;
  select string_agg(b.k || ': ' || b.v || ' -> ' || cur.v, '; ') into v_bad
    from _0313_before b
    join (select 'gun_' || id || '_' || key as k, value as v from (
            select id, 'power' as key, power::text as value from public.module_types where id in ('autocannon_battery','autocannon_battery_mk2')
            union all select id, 'projectile_speed', projectile_speed::text from public.module_types where id in ('autocannon_battery','autocannon_battery_mk2')
            union all select id, 'cooldown_seconds', cooldown_seconds::text from public.module_types where id in ('autocannon_battery','autocannon_battery_mk2')
            union all select id, 'slot_type', slot_type from public.module_types where id in ('autocannon_battery','autocannon_battery_mk2')
          ) g) cur on cur.k = b.k
   where cur.v is distinct from b.v;
  if v_bad is not null then
    raise exception '0313 ASSERT (e) FAIL: a gun attribute other than range changed (%)', v_bad;
  end if;
end $$;

-- (f) the DESIGN INVARIANTS the numbers were chosen for, derived from the live rows this chain
--     actually carries — the arithmetic in the header, executed rather than trusted:
--       1. fallback range == basic gun range (one basic-weapon tier, two spellings);
--       2. Mk-II strictly out-ranges the basic gun;
--       3. the basic gun strictly out-ranges the synthetic pirate at EVERY difficulty either spawn
--          arm can actually mint (otherwise the standoff bug — see the header's fixed-point
--          derivation: a kiter settles at its own range minus the player's speed, forever);
--       4. the escort spawn ring strictly exceeds that same worst-case pirate range
--          (the spawn gap forces closure — the mechanic this slice unlocks);
--       5. Mk-II covers the ring (a Mk-II escort fires from its formation slot on tick 1).
--
--     ⚠ BOTH SPAWN ARMS, not just one. `enemy range = base + per_difficulty × D` is evaluated in TWO
--     places and D comes from a DIFFERENT source in each:
--       • SYNTHETIC arm (0299:756-757): D = the LOCATION's own `locations.base_difficulty`.
--       • RESOLVED arm (0299:705-706): D = the PER-UNIT `base_difficulty` carried by the encounter
--         plan, which resolve_location_encounter materialises from `enemy_archetypes.base_difficulty`
--         (0272:245) and, for the units that roll ELITE, from base_difficulty ×
--         `encounter_elite_difficulty_multiplier` (read at 0272:208, applied at 0272:256; seeded 2 at
--         0272:75). Those archetypes are seeded with difficulties of their OWN — pirate_light 10 and
--         pirate_heavy 25 (0257:992-993) — that no location column constrains. An elite pirate_heavy
--         is effective difficulty 50, i.e. range 18 + 0.2·50 = 28, which would be ABOVE the 25 basic
--         gun while a location-only max saw nothing at all. Reading only the synthetic arm made (f3)
--         and (f4) blind to exactly the arm that can break them.
--     REACHABILITY for the resolved arm is the live binding chain the resolver itself walks, so this
--     can never fail on authored-but-unreachable content: ACTIVE binding (0272:141-147) → ACTIVE
--     profile (0272:160-161) → its members → ACTIVE fleet template (0272:195) → its members → ACTIVE
--     archetype (0272:224), at an ACTIVE location (0272:134). The elite multiplier is applied only
--     where the member's authored `elite_chance > 0` (0272:230-241) — elite_chance 0 mints no elite
--     entry at all, so it must not inflate the bound.
--     ASSERTED UNCONDITIONALLY, not under the resolver's quad flag (0272:126-131): those flags are a
--     runtime toggle written by set_game_config with no migration, so gating on them would let a
--     later flip walk straight past this invariant with nothing checking it. The CONTENT has to fit
--     the ranges whether the resolver is lit today or lit tomorrow.
do $$
declare
  v_basic numeric; v_mk2 numeric; v_fallback numeric; v_ring numeric;
  v_maxd  double precision; v_maxd_syn double precision; v_maxd_res double precision;
  v_elite_mult double precision; v_arm text; v_enemy_max numeric;
begin
  select range into v_basic from public.module_types where id = 'autocannon_battery';
  select range into v_mk2   from public.module_types where id = 'autocannon_battery_mk2';
  v_fallback := public.cfg_num('combat_player_fallback_weapon_range');
  v_ring     := coalesce(public.cfg_num('spatial_formation_ring_radius'), 30);

  -- ARM 1 — the SYNTHETIC wave: the location's own difficulty.
  select coalesce(max(base_difficulty), 0) into v_maxd_syn
    from public.locations where status = 'active' and activity_type = 'hunt_pirates';

  -- ARM 2 — the RESOLVED wave: the archetype difficulty reachable through a LIVE binding, amplified
  --          by the elite multiplier exactly where an elite can roll.
  v_elite_mult := greatest(1.0, coalesce(public.cfg_num('encounter_elite_difficulty_multiplier'), 2));
  select coalesce(max(a.base_difficulty
                      * case when coalesce(fm.elite_chance, 0) > 0 then v_elite_mult else 1.0::double precision end), 0)
    into v_maxd_res
    from public.location_encounter_bindings b
    join public.locations l                     on l.id  = b.location_id and l.status = 'active'
    join public.encounter_profiles ep           on ep.id = b.encounter_profile_id and ep.active is true
    join public.encounter_profile_members pm    on pm.encounter_profile_id = ep.id
    join public.enemy_fleet_templates ft        on ft.id = pm.fleet_template_id and ft.active is true
    join public.enemy_fleet_template_members fm on fm.fleet_template_id = ft.id
    join public.enemy_archetypes a              on a.id = fm.enemy_archetype_id and a.active is true
   where b.active is true;

  v_maxd := greatest(v_maxd_syn, v_maxd_res);
  v_arm  := case when v_maxd_res > v_maxd_syn
                 then format('the RESOLVED arm (encounter plan; synthetic arm tops out at %s)', v_maxd_syn)
                 else format('the SYNTHETIC arm (location base_difficulty; resolved arm tops out at %s)', v_maxd_res) end;
  v_enemy_max := public.cfg_num('enemy_synthetic_range_base')
               + v_maxd * public.cfg_num('enemy_synthetic_range_per_difficulty');
  if v_fallback is distinct from v_basic then
    raise exception '0313 ASSERT (f1) FAIL: fallback range % <> basic gun range % — the basic-weapon tier split in two', v_fallback, v_basic;
  end if;
  if v_mk2 <= v_basic then
    raise exception '0313 ASSERT (f2) FAIL: Mk-II range % does not exceed the basic gun''s % — the upgrade lost its edge', v_mk2, v_basic;
  end if;
  if v_enemy_max >= v_basic then
    raise exception '0313 ASSERT (f3) FAIL: the worst spawnable enemy range is % (difficulty %, from %) >= the basic gun''s % — a kiter at that range would settle at (its range - the player''s ~1 speed) and the player would never land a shot',
      v_enemy_max, v_maxd, v_arm, v_basic;
  end if;
  if v_ring <= v_enemy_max then
    raise exception '0313 ASSERT (f4) FAIL: the % spawn ring is inside the worst spawnable enemy range % (difficulty %, from %) — enemies reach escorts on tick 1 and nothing ever closes',
      v_ring, v_enemy_max, v_maxd, v_arm;
  end if;
  if v_mk2 < v_ring then
    raise exception '0313 ASSERT (f5) FAIL: Mk-II range % is under the % ring — a Mk-II escort could not fire from its formation slot', v_mk2, v_ring;
  end if;
  raise notice '0313 SELF-ASSERT PASS: ranges cut to fit the zone — basic gun %, Mk-II %, fallback %, spawn ring %; the worst enemy range ANY spawn arm can mint is % at difficulty % (from %), strictly under the basic gun and strictly inside the ring. mining_rig_extension and every untouched knob byte-unchanged.',
    v_basic, v_mk2, v_fallback, v_ring, v_enemy_max, v_maxd, v_arm;
end $$;

commit;
