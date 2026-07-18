-- Byeharu — COMBAT SLICE 3: SPATIAL combat. Migration 0231. DARK behind the new flag
-- `spatial_combat_enabled` (seeded false). Depends on S0 (0229, module range/projectile_speed/
-- power/ammo on module_types + ship_weapon_modules), S1 (0228, combat_units.aggro_priority +
-- process_combat_ticks' per-ship aggro targeting), S2 (0230, the telegraph — untouched by this
-- slice) — all on main.
--
-- ── WHAT THIS IS ────────────────────────────────────────────────────────────────────────────────────
-- The server core of on-map battle: per-ship positions, a CLOSE-vs-KITE movement/targeting AI, and a
-- tick that emits unit positions (via combat_units.pos_x/pos_y, read directly by a future client) and
-- fire events (combat_events, already shaped for this by S1/S0's projectile_type/projectile_count/
-- impact_delay_ms columns — unrendered until the S4 client slice). The client VISUAL layer (range
-- circles, projectiles, ship dots) is the SEPARATE next slice S4 — this slice only produces the data.
--
-- ── GROUNDING (grep-verified TRUE heads, re-verified this slice) ─────────────────────────────────────
--   combat_create_group_encounter — 20260618000228 (COMBAT-S1; only 0168→0195→0228 re-create it;
--     nothing later touches it — S0/0229 and S2/0230 both re-create OTHER functions, not this one).
--   process_combat_ticks          — 20260618000228 (COMBAT-S1; only 0206→0228 re-create it; S0/S2
--     re-create mining_extract / activity_start, not this).
--   calculate_expedition_stats    — 20260618000205 (COMMAND-BUFFS; returns 'speed' — reused verbatim,
--     never re-derived — for a member ship's in-combat move_speed).
--   ship_weapon_modules           — 20260618000229 (COMBAT-S0); NOT callable from the creator (it
--     filters `player_id = auth.uid()`, and combat_create_group_encounter runs from the arrival-
--     settle chain with NO session/auth.uid() — an engine context). This slice INLINES the identical
--     fitting join (ship_module_fittings → module_instances → module_types, S0's exact shape) rather
--     than call the client-scoped leaf — reuse of the JOIN SHAPE, not the RPC, which is the correct
--     seam for a security-definer engine caller with no JWT.
--   module_types.range/projectile_speed/power/ammo_*  — 20260618000229 (COMBAT-S0).
--   combat_units.aggro_priority   — 20260618000228 (COMBAT-S1); reused verbatim for enemy targeting.
--   unit_types                    — 20260616000004; scout/corvette/frigate only (player fleet-unit
--     catalog). Nothing pirate-shaped exists there — this slice seeds ONE new inert catalog row
--     (`pirate_synthetic`, status='disabled') purely so synthetic enemy combat_units rows can satisfy
--     the EXISTING `combat_units_exactly_one_identity` CHECK (0167: unit_type_id XOR main_ship_id)
--     WITHOUT loosening that CHECK at all — an enemy row's REAL stats (hp/power/range/speed) live
--     entirely in its own hp_current/ship_hp/weapons_json/move_speed columns, never read from
--     unit_types for a `pirate_synthetic` row (the catalog id is an FK/CHECK anchor only).
--
-- ── SCHEMA (additive; every existing combat_units row is side='player', pos_x/pos_y/move_speed NULL,
--    weapons_json='[]' — inert until a NEW group encounter is created with the flag lit) ─────────────
--   combat_units += pos_x, pos_y, move_speed (double precision, NULL until spatial) — the "does THIS
--     encounter carry positions" fallback signal IS `pos_x is not null`, read per-encounter by the tick.
--   combat_units += weapons_json (jsonb not null default '[]') — a frozen-at-spawn array of
--     {module_type_id, range, projectile_speed, power, ammo_type, ammo_per_shot, cooldown_seconds,
--     next_ready_at, ammo_remaining}; next_ready_at/ammo_remaining are the ONLY fields the tick ever
--     mutates post-spawn (per-weapon fire-state; nothing else in the array changes after creation).
--   combat_units += side (text not null default 'player' check in ('player','enemy')) — 'player' for
--     every row this migration's creator hunk ever writes (member ships); 'enemy' ONLY for the
--     tick's own synthetic pirate spawns (S3's one new writer of side='enemy').
--   combat_units_member_snapshot_pairing (0167) is untouched and still satisfied: an enemy row has
--     main_ship_id NULL, so it MUST carry NULL attack_snapshot/defense_snapshot too — true by
--     construction (this slice never sets them on an enemy row). combat_units_exactly_one_identity
--     (0167) is untouched: an enemy row's identity is unit_type_id='pirate_synthetic' (main_ship_id
--     NULL) — an ordinary catalog identity, no new CHECK shape needed.
--
-- ── THE PURE LEAF: combat_unit_decide_move ───────────────────────────────────────────────────────────
-- language sql immutable (calls only osn_distance, 0099, itself immutable) — a genuinely pure function
-- of its 7 scalar inputs, no table reads, table-free/FK-free and therefore EXECUTABLE inside this
-- migration's own self-assert (unlike the two re-created engine functions, which need live fixtures
-- this migration cannot build — the 0228 §"SELF-ASSERT DISCIPLINE" precedent, reused). THE DECISION
-- (verbatim from the charter): target out of my range → CLOSE (toward, capped by my_speed); I can hit
-- them and they can't hit me (my_range >= dist > their_range) → KITE (away, capped by my_speed, never
-- retreating past my own range edge); otherwise (both in range) → HOLD. Faster/longer-range ships kite
-- slower/shorter ones — emergent from the three inputs, never hardcoded per-hull-type.
--
-- ── SPAWN (combat_create_group_encounter — ONE marked hunk, additive to the existing bulk INSERT) ────
-- The 0228 body VERBATIM (every existing column/value untouched) + new columns APPENDED to the same
-- roster jsonb / same bulk INSERT's column and SELECT lists. When spatial_combat_enabled is dark, the
-- new per-member locals (v_pos_x/v_pos_y/v_move_speed/v_weapons_json) are reset to NULL/NULL/NULL/'[]'
-- at the top of EVERY loop iteration (mirroring the existing v_attack/v_defense/... reset — the same
-- "degraded/dark = the inert shape" law) and never computed — so the new columns land NULL/NULL/NULL/
-- '[]' for every row, byte-equivalent to "these columns did not exist" for the pre-existing behavior.
-- LIT: command ship spawns at the arrival location's center; escorts on a small deterministic ring
-- around it (fixed 8-slot angular spacing — the group cap is already 8, 0204 — so up to 7 escorts never
-- overlap); move_speed is read straight off the SAME calculate_expedition_stats call already made for
-- attack/defense (`->>'speed'` — no second adapter invocation); weapons_json is the inlined fitting
-- join (see grounding above), frozen with next_ready_at/ammo_remaining both NULL (ready to fire tick 1;
-- ammo tracking is documented-inert scaffolding — see the tick's fire section).
-- ENEMY units are NOT spawned by the creator (see the tick, below) — the wave-lifecycle authority
-- (danger scaling, next_wave_at pacing) has ALWAYS lived entirely in the tick (0023 head, 0228 head);
-- putting the FIRST wave's spawn there too, instead of duplicating the wave-hp formula in the creator,
-- keeps ONE authority for "when/how big is a pirate wave" — exactly the pre-existing invariant
-- (e.enemy_integrity_current starts at 0 → the tick's own first pass has always been where "wave 1"
-- materializes; this slice keeps that true, now materializing per-unit rows instead of a lone scalar).
--
-- ── THE SPATIAL TICK (process_combat_ticks — ONE marked hunk on the aggregate stat SELECT, ONE marked
--    branch on the (C) Combat step; (A) defeat and (B) escape/retreat are SHARED, UNMODIFIED — their
--    only combat_units reads already filter `main_ship_id is not null`, which naturally excludes every
--    enemy row (enemy rows never carry main_ship_id) — so they need no side= filter and needed no edit) ─
-- v_is_spatial := spatial_combat_enabled AND exists(an alive-or-not combat_units row on this encounter
-- with pos_x is not null). THIS is the null-pos fallback: an encounter created before the flag lit (or
-- while it stays dark) never gets positions, so v_is_spatial is false for it FOREVER regardless of a
-- later flag flip — an in-flight battle is never spatialized mid-fight, exactly the charter's safety
-- requirement. DARK (or no positions): the aggregate SELECT and the (C) block are the 0228 head text,
-- verbatim, unbranched from the flag's perspective — extract-and-diff proves the else-arm is untouched.
-- LIT + positioned: (C) forks into the SPATIAL branch — targeting (nearest alive opposite-side unit,
-- aggro-tier-filtered so the enemy side's targeting reuses S1's screening: while any escort, aggro 0,
-- is alive, only escorts are targetable, exactly as S1 already proved; the player side has no aggro
-- filter, since aggro_priority is a player-fleet-only concept and every enemy row's aggro_priority is
-- NULL) → movement (combat_unit_decide_move, applied against a FROZEN pre-tick position/range/speed
-- snapshot so no unit's movement this tick can contaminate another unit's "pre-move distance", the
-- charter's simplest-first requirement) → fire (per-weapon range+cooldown gate, one combat_events row
-- per shot, impact_delay_ms from distance/projectile_speed) → damage (the SHIELD-1 absorb pattern,
-- applied directly to the target's own hp_current/shield_current — reused, not re-derived). Enemy waves
-- are synthesized by splitting the SAME wave-hp/wave-attack formulas the aggregate arm has always used
-- (enemy_hp_base/enemy_hp_danger_scale/enemy_attack_base/enemy_attack_danger_scale — UNCHANGED config
-- keys) across N units (N := danger level, capped by a new tunable), so a spatial wave's TOTAL hp/dps
-- matches what the aggregate arm would have rolled for the same encounter — a deliberate balance
-- parity, not a coincidence. Enemies always spawn at the location's own center (`locations.x/y`) — the
-- "pirates spawn from the zone center" requirement — with weapon range/speed derived from
-- base_difficulty via new tunable knobs (all coalesce-defaulted, the house convention).
--
-- ── report_create — the ONE necessary third re-create (beyond the two the charter names) ────────────
-- report_create's (0167 head) survivors/losses aggregation has NEVER filtered by anything but
-- encounter_id — safe until now because EVERY combat_units row belonged to the player's own fleet.
-- This slice is the FIRST time a combat_units row can belong to the OTHER side (side='enemy'); left
-- unfixed, a spatial encounter's report would silently fold pirate unit counts into the PLAYER
-- survivors/losses object (keyed by the inert 'pirate_synthetic' catalog id — no raise, just wrong
-- data). The ONE-token fix: `and side = 'player'` on its lone combat_units scan — a provable no-op for
-- every pre-existing/non-spatial row (side defaults 'player' and this slice's tick never writes
-- side='enemy' onto anything but a `pirate_synthetic`-identified row, itself only reachable when
-- spatial_combat_enabled is lit AND the encounter is positioned).
--
-- ── OUT OF SCOPE (S4's job) ─────────────────────────────────────────────────────────────────────────
-- Client rendering (range circles / projectiles / ship dots), ammo depletion actually gating fire
-- (ammo_type is NULL on every module today — S0's own documented deferral; this slice decrements
-- ammo_remaining when ammo_type is set, per the charter, but does not GATE fire on it — there is no
-- inventory source wired for "how much ammo is aboard" yet, and inventing one is a future slice's
-- decision, not this one's), cross-tick pending-hit state (this slice resolves every hit synchronously
-- against pre-move distance, the charter's explicit MVP simplification).
--
-- ── VERIFICATION CAVEAT (honest, not overclaimed) ──────────────────────────────────────────────────
-- No local Postgres/Docker is available in this environment to execute this migration end-to-end.
-- combat_unit_decide_move is table-free/FK-free, so its CLOSE/KITE/HOLD arithmetic IS proven
-- executably below (real numbers in, real numbers asserted out). The two re-created engine functions
-- are proven by prosrc/structural token-pinning (the 0228 precedent — no migration in this chain
-- builds a live combat_units fixture inside itself; main_ship_instances.player_id is a hard FK to
-- auth.users). A live-DB scenario proof (spawn → tick → verify positions/fire/damage) belongs in a
-- follow-up scripts/*-proof.sh run against a disposable `supabase start`, exactly like every other
-- CI-proof-gated combat slice — recommended before this branch merges, not fabricated here.
--
-- Forward-only: 0001–0230 unedited. This file takes 0231 (0229/0230 are S0/S2, both merged to main).

-- ── 1) NEW flag spatial_combat_enabled (game_config bool, seeded FALSE) ────────────────────────────
insert into public.game_config (key, value, description) values
  ('spatial_combat_enabled', 'false',
   'COMBAT-S3 (0231): server gate for per-ship spatial positions/movement/targeting in group combat '
   'encounters (the CLOSE-vs-KITE AI + per-weapon fire events). Dark: process_combat_ticks runs the '
   'exact S1 (0228) aggregate/per-ship-targeting math, byte-parity; combat_create_group_encounter '
   'never writes positions. Lit: a NEW group encounter gets player positions/speeds/weapons snapshotted '
   'at creation and the tick runs the spatial per-unit loop for any encounter whose combat_units carry '
   'a non-NULL pos_x — an encounter created before this flag lit (all-NULL positions) ALWAYS falls back '
   'to the aggregate path regardless of the flag''s current value, so an in-flight battle is never '
   'spatialized mid-fight. OFF on live — dark until a human flips it.')
on conflict (key) do nothing;

-- Tunables for the synthetic-enemy split (all coalesce-defaulted at read time — the house convention;
-- seeding them here just documents the chosen defaults, a re-apply never clobbers a tuned value).
insert into public.game_config (key, value, description) values
  ('enemy_synthetic_max_units',            '6',   'COMBAT-S3: hard cap on synthetic pirate units per wave (N = min(this, danger_level)).'),
  ('enemy_synthetic_range_base',           '120', 'COMBAT-S3: synthetic pirate weapon range at base_difficulty=0 (world units).'),
  ('enemy_synthetic_range_per_difficulty', '5',   'COMBAT-S3: synthetic pirate weapon range added per point of location base_difficulty.'),
  ('enemy_synthetic_speed_base',           '3',   'COMBAT-S3: synthetic pirate ship move_speed at base_difficulty=0.'),
  ('enemy_synthetic_speed_per_difficulty', '0.2', 'COMBAT-S3: synthetic pirate ship move_speed added per point of base_difficulty.'),
  ('enemy_synthetic_projectile_speed',     '250', 'COMBAT-S3: synthetic pirate weapon projectile_speed (world units/sec).'),
  ('enemy_synthetic_cooldown_seconds',     '2',   'COMBAT-S3: synthetic pirate weapon cooldown between shots.'),
  ('spatial_formation_ring_radius',        '30',  'COMBAT-S3: radius (world units) of the escort ring around the command ship at spawn.')
on conflict (key) do nothing;

-- ── 2) combat_units — additive spatial columns (every existing row: side default applies, rest NULL) ─
alter table public.combat_units
  add column pos_x        double precision,
  add column pos_y        double precision,
  add column move_speed   double precision,
  add column weapons_json jsonb not null default '[]'::jsonb,
  add column side         text  not null default 'player' check (side in ('player','enemy'));

comment on column public.combat_units.pos_x is
  'COMBAT-S3 (0231): in-combat world-x. NULL until spatial_combat_enabled is lit AND this row was '
  'created by the spatial hunk; the tick''s null-pos fallback (an encounter with any NULL pos_x row '
  'runs the aggregate path, never the spatial one) keys off this column.';
comment on column public.combat_units.pos_y is
  'COMBAT-S3 (0231): in-combat world-y. Paired with pos_x (see its comment).';
comment on column public.combat_units.move_speed is
  'COMBAT-S3 (0231): this unit''s in-combat move speed (player rows: calculate_expedition_stats'' own '
  '''speed'', reused verbatim; enemy rows: a synthetic value derived from base_difficulty). NULL until '
  'spatial.';
comment on column public.combat_units.weapons_json is
  'COMBAT-S3 (0231): frozen-at-spawn array of {module_type_id,range,projectile_speed,power,ammo_type,'
  'ammo_per_shot,cooldown_seconds,next_ready_at,ammo_remaining}. Every field but next_ready_at/'
  'ammo_remaining is immutable after spawn; those two are the tick''s own per-weapon fire-state, '
  'mutated only by the unit that owns the row. Default ''[]'' — every pre-existing/non-spatial row '
  'stays an inert empty array forever.';
comment on column public.combat_units.side is
  'COMBAT-S3 (0231): ''player'' (every row this migration''s creator hunk ever writes — a member ship) '
  'or ''enemy'' (a synthetic pirate unit, written ONLY by process_combat_ticks'' wave-spawn hunk, and '
  'ONLY on an encounter with spatial_combat_enabled lit). Default ''player'' — every pre-existing row '
  'and every legacy catalog row this column never touches reads ''player'' truthfully (report_create''s '
  'new `and side = ''player''` filter is a provable no-op on all of them).';

-- ── 3) unit_types: ONE new inert catalog row — the FK/CHECK identity anchor for synthetic enemies ───
-- status='disabled' (never surfaced to players, never buildable); attack/defense/cargo/power_score/
-- build_time_seconds are dummy zeros and hull/speed are dummy 1s ONLY to satisfy this table's existing
-- CHECKs (hull>0, speed>0) — a `pirate_synthetic`-identified combat_units row NEVER reads any of these
-- columns; its real hp/power/range/speed live in its OWN hp_current/ship_hp/weapons_json/move_speed.
insert into public.unit_types (id, name, attack, defense, hull, speed, cargo, power_score, build_time_seconds, status)
  values ('pirate_synthetic', 'Synthetic Pirate Unit (COMBAT-S3 identity anchor — not a player unit)', 0, 0, 1, 1, 0, 0, 0, 'disabled')
on conflict (id) do nothing;

-- ── 4) combat_unit_decide_move — the pure CLOSE/KITE/HOLD leaf ──────────────────────────────────────
-- language sql immutable: a pure function of its 7 scalar inputs (reuses osn_distance, 0099, itself
-- immutable); no table reads, so it is genuinely executable in this migration's own self-assert.
create or replace function public.combat_unit_decide_move(
  p_my_x         double precision,
  p_my_y         double precision,
  p_my_range     double precision,
  p_my_speed     double precision,
  p_target_x     double precision,
  p_target_y     double precision,
  p_target_range double precision
) returns table (action text, new_x double precision, new_y double precision, dist double precision)
language sql
immutable
set search_path = public
as $$
  with d as (
    select public.osn_distance(p_my_x, p_my_y, p_target_x, p_target_y) as dist
  ),
  dir as (
    select d.dist,
           case when d.dist > 0 then (p_target_x - p_my_x) / d.dist else 0 end as ux,
           case when d.dist > 0 then (p_target_y - p_my_y) / d.dist else 0 end as uy
    from d
  )
  select
    -- ██ COMBAT-S3: THE CLOSE-vs-KITE DECISION ██
    -- out of my own range           → CLOSE (toward, capped by my_speed)
    -- in my range AND they can't hit me (my_range >= dist > their_range) → KITE (away, capped by
    --   my_speed, never retreating past my own range edge)
    -- both in range                 → HOLD (fire; no movement)
    case
      when dir.dist > coalesce(p_my_range, 0)     then 'close'
      when dir.dist > coalesce(p_target_range, 0) then 'kite'
      else 'hold'
    end as action,
    case
      when dir.dist > coalesce(p_my_range, 0)
        then p_my_x + dir.ux * least(coalesce(p_my_speed, 0), dir.dist)
      when dir.dist > coalesce(p_target_range, 0)
        then p_my_x - dir.ux * least(coalesce(p_my_speed, 0), coalesce(p_my_range, 0) - dir.dist)
      else p_my_x
    end as new_x,
    case
      when dir.dist > coalesce(p_my_range, 0)
        then p_my_y + dir.uy * least(coalesce(p_my_speed, 0), dir.dist)
      when dir.dist > coalesce(p_target_range, 0)
        then p_my_y - dir.uy * least(coalesce(p_my_speed, 0), coalesce(p_my_range, 0) - dir.dist)
      else p_my_y
    end as new_y,
    dir.dist as dist
  from dir;
$$;

comment on function public.combat_unit_decide_move(double precision, double precision, double precision, double precision, double precision, double precision, double precision) is
  'COMBAT-S3 (0231): the pure CLOSE/KITE/HOLD movement decision. Given my own position/range/speed and '
  'a target''s position/range: CLOSE when the target is out of my range; KITE when I can hit them but '
  'they can''t hit me (retreat to the edge of my own range, never further); HOLD (fire, no movement) '
  'when both are in range. Faster/longer-range ships kite slower/shorter ones — emergent from the '
  'three inputs, never hardcoded per hull type. Table-free/FK-free — deterministic, no randomness.';

revoke all on function public.combat_unit_decide_move(double precision, double precision, double precision, double precision, double precision, double precision, double precision) from public;
grant execute on function public.combat_unit_decide_move(double precision, double precision, double precision, double precision, double precision, double precision, double precision) to authenticated, service_role;

-- ── 5) combat_create_group_encounter — 0228 body VERBATIM + the marked COMBAT-S3 spawn hunk ─────────
create or replace function public.combat_create_group_encounter(p_presence uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  pr        location_presence%rowtype;
  m         record;
  v_stats   jsonb;
  v_roster  jsonb := '[]'::jsonb;
  v_power   double precision := 0;
  v_attack  double precision;
  v_defense double precision;
  v_hp      double precision;
  v_alive   integer;
  v_shield_max double precision;
  v_shield_cur double precision;
  v_aggro_priority integer;
  v_hull    double precision;
  v_enc     uuid;
  -- COMBAT-S3 (0231): the player position/speed/weapons snapshot — LIT-only working set. Gate read
  -- ONCE at entry (the 0198 v_growth / 0193 v_traits_enabled posture, mirrored). v_loc_x/v_loc_y/
  -- v_ring_radius are only ever populated when lit; the per-member locals (v_pos_x/v_pos_y/
  -- v_move_speed/v_weapons_json) are reset to the inert NULL/NULL/NULL/'[]' shape at the TOP of every
  -- loop iteration (the exact v_attack/v_defense/... reset law already in this function) so a dark or
  -- degraded member always lands the byte-equivalent-to-"column doesn't exist" shape.
  v_spatial_enabled boolean := public.cfg_bool('spatial_combat_enabled');
  v_loc_x           double precision;
  v_loc_y           double precision;
  v_ring_radius     double precision;
  v_escort_idx      integer := 0;
  v_pos_x           double precision;
  v_pos_y           double precision;
  v_move_speed      double precision;
  v_weapons_json    jsonb;
begin
  select * into pr from location_presence where id = p_presence;
  if not found then
    raise exception 'combat_create_group_encounter: presence % not found', p_presence;
  end if;

  -- COMBAT-S3 (0231): the arrival location's own center — the formation anchor (command ship spawns
  -- HERE; escorts ring around it). ONE extra read, dark-gated; a NEW statement, touches nothing else.
  if v_spatial_enabled then
    select x, y into v_loc_x, v_loc_y from locations where id = pr.location_id;
    v_ring_radius := coalesce(public.cfg_num('spatial_formation_ring_radius'), 30);
  end if;

  for m in
    select gsm.main_ship_id, gsm.player_id, msi.hp, msi.shield, msi.max_shield, msi.is_command_ship
      from group_sortie_members gsm
      join main_ship_instances msi on msi.main_ship_id = gsm.main_ship_id
     where gsm.fleet_id = pr.fleet_id
     order by gsm.main_ship_id
  loop
    v_attack := 0; v_defense := 0; v_hp := 0; v_alive := 0;
    v_shield_max := null; v_shield_cur := null;
    v_aggro_priority := case when m.is_command_ship then 100 else 0 end;
    -- COMBAT-S3 (0231): the inert default — reset EVERY iteration, before the hp>0 branch (the same
    -- unconditional-reset law aggro_priority already follows), so a degraded member's row lands
    -- exactly the "no spatial data" shape regardless of why it degraded.
    v_pos_x := null; v_pos_y := null; v_move_speed := null; v_weapons_json := '[]'::jsonb;
    if m.hp > 0 then
      begin
        v_stats   := public.calculate_expedition_stats(m.player_id, m.main_ship_id, '[]'::jsonb, 'pirate_hunt');
        v_attack  := coalesce((v_stats->>'combat_power')::double precision, 0);
        v_defense := coalesce((v_stats->>'survival')::double precision, 0);
        v_hp      := m.hp;
        v_alive   := 1;
        if m.max_shield > 0 then
          v_shield_max := m.max_shield;
          v_shield_cur := m.shield;
        end if;
        -- COMBAT-S3 (0231): position/speed/weapons — LIT only, computed from the SAME successful
        -- adapter call above (v_stats) — no second calculate_expedition_stats invocation.
        if v_spatial_enabled then
          v_move_speed := coalesce((v_stats->>'speed')::double precision, 1);
          if m.is_command_ship then
            v_pos_x := v_loc_x;
            v_pos_y := v_loc_y;
          else
            v_pos_x := v_loc_x + v_ring_radius * cos(2 * pi() * v_escort_idx / 8);
            v_pos_y := v_loc_y + v_ring_radius * sin(2 * pi() * v_escort_idx / 8);
            v_escort_idx := v_escort_idx + 1;
          end if;
          -- The S0 ship_weapon_modules (0229) fitting join, INLINED (that leaf filters
          -- player_id = auth.uid(), unusable from this security-definer engine context — see the
          -- header grounding). Frozen next_ready_at/ammo_remaining = NULL: every weapon is ready to
          -- fire tick 1.
          select coalesce(jsonb_agg(jsonb_build_object(
                   'module_type_id', t.id, 'range', t.range, 'projectile_speed', t.projectile_speed,
                   'power', t.power, 'ammo_type', t.ammo_type, 'ammo_per_shot', t.ammo_per_shot,
                   'cooldown_seconds', t.cooldown_seconds, 'next_ready_at', null, 'ammo_remaining', null)),
                 '[]'::jsonb)
            into v_weapons_json
            from ship_module_fittings f
            join module_instances i on i.id = f.module_instance_id
            join module_types t     on t.id = i.module_type_id
           where f.main_ship_id = m.main_ship_id and t.range is not null;
        end if;
      exception when others then
        v_attack := 0; v_defense := 0; v_hp := 0; v_alive := 0;
        v_shield_max := null; v_shield_cur := null;
      end;
    end if;
    v_power  := v_power + v_attack;
    v_roster := v_roster || jsonb_build_array(jsonb_build_object(
      'main_ship_id', m.main_ship_id, 'player_id', m.player_id, 'hp', v_hp,
      'alive', v_alive, 'attack', v_attack, 'defense', v_defense,
      'shield_max', v_shield_max, 'shield_cur', v_shield_cur,
      'aggro_priority', v_aggro_priority,
      'pos_x', v_pos_x, 'pos_y', v_pos_y, 'move_speed', v_move_speed, 'weapons_json', v_weapons_json));
  end loop;

  insert into combat_encounters (
    player_id, fleet_id, presence_id, location_id, status, danger_level,
    player_power_start, player_power_current, enemy_power_current,
    player_integrity_max, player_integrity_current, enemy_integrity_max, enemy_integrity_current,
    wave_number, last_resolved_at)
  values (
    pr.player_id, pr.fleet_id, p_presence, pr.location_id, 'active', 1,
    v_power, v_power, 0, 0, 0, 0, 0, 0, now())
  returning id into v_enc;

  -- COMBAT-S3 (0231): pos_x, pos_y, move_speed, weapons_json, side APPENDED to the existing column and
  -- SELECT lists — every pre-existing column/value is untouched (extract-and-diff proof: nothing
  -- before 'aggro_priority)' in the column list or before the aggro_priority cast in the SELECT list
  -- changed). side is always 'player' here (this function never writes an enemy row) — a literal, not
  -- roster-carried.
  insert into combat_units (
    encounter_id, player_id, unit_type_id, main_ship_id, attack_snapshot, defense_snapshot,
    ship_hp, initial_count, alive_count, hp_max, hp_current,
    shield_max, shield_current,
    aggro_priority,
    pos_x, pos_y, move_speed, weapons_json, side)
  select v_enc, (e->>'player_id')::uuid, null, (e->>'main_ship_id')::uuid,
         (e->>'attack')::double precision, (e->>'defense')::double precision,
         (e->>'hp')::double precision, 1, (e->>'alive')::integer,
         (e->>'hp')::double precision, (e->>'hp')::double precision,
         (e->>'shield_max')::double precision, (e->>'shield_cur')::double precision,
         (e->>'aggro_priority')::integer,
         (e->>'pos_x')::double precision, (e->>'pos_y')::double precision,
         (e->>'move_speed')::double precision, coalesce(e->'weapons_json', '[]'::jsonb), 'player'
  from jsonb_array_elements(v_roster) as e;

  select coalesce(sum(hp_max), 0) into v_hull from combat_units where encounter_id = v_enc;
  update combat_encounters set player_integrity_max = v_hull, player_integrity_current = v_hull where id = v_enc;

  insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
    values (v_enc, pr.player_id, 0, 0, 'wave_spawned', 'pirate', 'player', jsonb_build_object('wave', 1, 'danger', 1));
  return v_enc;
end;
$$;

-- ── 6) process_combat_ticks — 0228 body VERBATIM: shared (A)/(B), ONE marked aggregate-select hunk,
--    ONE marked (C) branch. ────────────────────────────────────────────────────────────────────────
create or replace function public.process_combat_ticks()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  e               combat_encounters%rowtype;
  pr              location_presence%rowtype;
  loc             record;
  cu              record;
  v_tick          integer;
  v_tick_secs     double precision;
  v_retreat_delay double precision;
  v_trans_secs    double precision;
  v_var_pct       double precision;
  v_def_base      double precision;
  v_secs_inside   double precision;
  v_max_secs      double precision;
  v_forced        boolean;
  v_retreat_done  boolean;
  v_danger        integer;
  v_variance      double precision;
  v_attack        double precision;
  v_defense       double precision;
  v_hp_total      double precision;
  v_alive_total   integer;
  v_wave_num      integer;
  v_enemy_hp      double precision;
  v_e_before      double precision;
  v_e_after       double precision;
  v_enemy_attack  double precision;
  v_player_damage double precision;
  v_final_player  double precision;
  v_cleared       boolean;
  v_offense       boolean;
  v_d_group       double precision;
  v_new_hp        double precision;
  v_new_alive     integer;
  v_destroyed     integer;
  v_losses        jsonb;
  v_counts        jsonb;
  v_snapshot      jsonb;
  v_hp_after      double precision;
  v_reward_metal  double precision;
  v_reward_delta  jsonb;
  v_loot_items    jsonb;
  v_seq           integer;
  v_end           text;
  v_base_id       uuid;
  v_base_x        double precision;
  v_base_y        double precision;
  v_loc_x         double precision;
  v_loc_y         double precision;
  v_speed         double precision;
  v_mv            uuid;
  v_count         integer := 0;
  v_log_ticks     boolean;
  v_log_events    boolean;
  v_log_debug     boolean;
  v_shield_regen  double precision;
  v_shield        double precision;
  v_absorb        double precision;
  v_per_ship_targeting boolean;
  v_target_unit        uuid;
  -- ██ COMBAT-S3 (0231) — the spatial working set ██
  v_spatial_combat_enabled boolean;  -- read ONCE per invocation, alongside every other one-read knob
  v_is_spatial             boolean;  -- read ONCE per encounter per tick (the null-pos fallback decision)
  v_wave_paused            boolean;
  v_units                  jsonb;    -- frozen pre-move snapshot: id/side/pos/my_range/move_speed/aggro/main_ship_id
  v_ur                     record;   -- the acting unit, looped from v_units
  v_target_id              uuid;
  v_target_x               double precision;
  v_target_y               double precision;
  v_target_range           double precision;
  v_target_dist            double precision;
  v_move_action            text;
  v_new_x                  double precision;
  v_new_y                  double precision;
  v_weapons_json           jsonb;
  v_weapons_out            jsonb;
  v_widx                   integer;
  v_weapon                 jsonb;
  v_w_range                double precision;
  v_w_pspeed               double precision;
  v_w_power                double precision;
  v_w_ammo_type            text;
  v_w_ammo_per_shot        integer;
  v_w_next_ready           timestamptz;
  v_new_ammo               integer;
  v_t_hp                   double precision;
  v_t_shield               double precision;
  v_t_shieldmax            double precision;
  v_t_alive                integer;
  v_t_shiphp               double precision;
  v_t_side                 text;
  v_t_defense              double precision;
  v_t_mainship             uuid;
  v_dmg                    double precision;
  v_shield_new             double precision;
  v_enemy_count            integer;
  v_enemy_range            double precision;
  v_enemy_speed            double precision;
  v_enemy_proj_speed       double precision;
  v_enemy_cooldown         double precision;
  v_enemy_unit_hp          double precision;
  v_enemy_unit_power       double precision;
  v_spawn_i                integer;
  v_dmg_player_total       double precision;
  v_dmg_enemy_total        double precision;
begin
  v_tick_secs     := coalesce(cfg_num('combat_tick_seconds'), 3);
  v_retreat_delay := coalesce(cfg_num('retreat_delay_seconds'), 8);
  v_trans_secs    := coalesce(cfg_num('wave_transition_seconds'), 3);
  v_var_pct       := coalesce(cfg_num('combat_damage_variance_pct'), 0.10);
  v_def_base      := coalesce(cfg_num('defense_curve_base'), 100);
  v_log_ticks     := cfg_bool('combat_tick_logging');
  v_log_events    := cfg_bool('combat_event_logging');
  v_log_debug     := cfg_bool('combat_debug_logging');
  v_shield_regen  := coalesce(cfg_num('shield_regen_combat_pct'), 0);
  v_per_ship_targeting := cfg_bool('per_ship_targeting_enabled');
  -- COMBAT-S3 (0231): joins the SAME one-read-per-invocation block, never re-read inside the loop.
  v_spatial_combat_enabled := cfg_bool('spatial_combat_enabled');

  for e in
    select * from combat_encounters
    where status in ('active','retreating')
      and (last_resolved_at is null or now() - last_resolved_at >= make_interval(secs => v_tick_secs))
    for update skip locked
  loop
    begin
    v_tick := e.tick_number + 1;
    select * into pr from location_presence where id = e.presence_id;
    select base_difficulty, reward_tier, max_presence_seconds into loc from locations where id = e.location_id;

    -- COMBAT-S3 (0231): THE NULL-POS FALLBACK. Read once per encounter per tick, BEFORE the aggregate
    -- select. An encounter with even one NULL pos_x row (dark at creation time, or created before the
    -- flag lit) is NEVER spatial, regardless of what the flag reads THIS tick — an in-flight battle is
    -- never spatialized mid-fight.
    v_is_spatial := v_spatial_combat_enabled
      and exists (select 1 from combat_units where encounter_id = e.id and pos_x is not null);

    -- COMBAT-S3 (0231): THE ONE MARKED AGGREGATE-SELECT HUNK. Dark/no-positions arm is the 0228 head
    -- SELECT, byte-identical (extract-and-diff: the else-arm below is untouched).
    if v_is_spatial then
      select coalesce(sum(hp_current), 0), coalesce(sum(alive_count), 0)
        into v_hp_total, v_alive_total
        from combat_units where encounter_id = e.id and side = 'player';
      v_attack := 0; v_defense := 0;
    else
      -- SLICE D1: member rows have no unit_types match → LEFT JOIN + snapshot-first stat reads. Every
      -- legacy row matches (FK) and has NULL snapshots, so coalesce resolves to the same catalog stats.
      select coalesce(sum(coalesce(cu2.attack_snapshot, ut.attack) * cu2.alive_count), 0),
             coalesce(sum(coalesce(cu2.defense_snapshot, ut.defense) * cu2.alive_count), 0),
             coalesce(sum(cu2.hp_current), 0),
             coalesce(sum(cu2.alive_count), 0)
        into v_attack, v_defense, v_hp_total, v_alive_total
        from combat_units cu2 left join unit_types ut on ut.id = cu2.unit_type_id
        where cu2.encounter_id = e.id;
    end if;

    -- (A) Already destroyed → defeat, NO rewards. [SHARED — 0228 head, unmodified: its only combat_units
    --     read filters `main_ship_id is not null`, which already excludes every enemy row.]
    if v_hp_total <= 0 or v_alive_total <= 0 then
      perform fleet_destroy(e.fleet_id);
      for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null loop
        perform mainship_mark_combat_destroyed(cu.main_ship_id);
      end loop;
      perform presence_complete(e.presence_id);
      update combat_encounters set status='defeat', tick_number=v_tick, ended_at=now(),
             last_resolved_at=now(), player_integrity_current=0, player_power_current=0,
             total_rewards_json='{}'::jsonb, updated_at=now() where id=e.id;
      if v_log_ticks then
        insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
               player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after, result)
          values (e.id, e.player_id, v_tick, e.wave_number, e.danger_level, 0, 0,
                  e.enemy_integrity_current, e.enemy_integrity_current, 'defeat');
      end if;
      if v_log_events then
        insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
          values (e.id, e.player_id, v_tick, 0, 'explosion', 'pirate', 'player', jsonb_build_object('reason','fleet_lost'));
      end if;
      perform report_create(e.id);
      v_count := v_count + 1; continue;
    end if;

    -- (B) End: retreat delay elapsed or forced auto-extract. [SHARED — 0228 head, unmodified: its
    --     member-repatriation read also filters `main_ship_id is not null`.]
    v_secs_inside  := extract(epoch from (now() - e.started_at));
    v_max_secs     := coalesce(loc.max_presence_seconds, cfg_num('max_presence_seconds_default'), 1800);
    v_forced       := v_secs_inside >= v_max_secs;
    v_retreat_done := e.status='retreating' and e.retreat_started_at is not null
                      and now() - e.retreat_started_at >= make_interval(secs => v_retreat_delay);
    if v_retreat_done or v_forced then
      v_end := case when v_forced and e.status <> 'retreating' then 'completed' else 'escaped' end;
      select origin_base_id into v_base_id from fleets where id = e.fleet_id;
      select x, y into v_base_x, v_base_y from bases where id = v_base_id;
      select x, y into v_loc_x, v_loc_y from locations where id = e.location_id;
      v_speed := coalesce(fleet_speed(e.fleet_id), combat_fleet_return_speed(e.fleet_id));
      update combat_encounters set status=v_end, tick_number=v_tick, ended_at=now(),
             last_resolved_at=now(), updated_at=now() where id=e.id;
      perform report_create(e.id);
      perform presence_complete(e.presence_id);
      v_mv := movement_create(e.player_id, e.fleet_id, 'location', null, pr.zone_id, e.location_id, v_loc_x, v_loc_y,
                              'base', v_base_id, null, null, v_base_x, v_base_y, 'return_home', v_speed);
      perform fleet_set_returning(e.fleet_id, v_mv);
      for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null and alive_count > 0 loop
        perform mainship_mark_legacy_in_flight(cu.main_ship_id, 'returning');
      end loop;
      if e.total_rewards_json is not null and e.total_rewards_json <> '{}'::jsonb then
        perform movement_attach_cargo(v_mv, e.id, e.total_rewards_json);
      end if;
      if v_log_ticks then
        insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
               player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after, reward_delta_json, result)
          values (e.id, e.player_id, v_tick, e.wave_number, e.danger_level, v_hp_total, v_hp_total,
                  e.enemy_integrity_current, e.enemy_integrity_current, e.total_rewards_json, v_end);
      end if;
      if v_log_events then
        insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
          values (e.id, e.player_id, v_tick, 0, 'retreat_completed', 'player', 'player', jsonb_build_object('forced', v_forced));
      end if;
      v_count := v_count + 1; continue;
    end if;

    -- (C) Combat step.
    if v_is_spatial then
      -- ██████████████████████████████████████████████████████████████████████████████████████████
      -- COMBAT-S3 (0231) SPATIAL COMBAT STEP — replaces the aggregate-damage step for any encounter
      -- whose combat_units carry positions. See the migration header for the full design walkthrough.
      -- ██████████████████████████████████████████████████████████████████████████████████████████
      v_danger   := 1 + e.waves_cleared + floor(v_secs_inside / coalesce(cfg_num('danger_time_divisor_seconds'), 180))::integer;
      v_variance := (1 - v_var_pct) + random() * (2 * v_var_pct);
      v_offense  := (e.status = 'active');
      v_wave_num := e.wave_number;
      v_seq      := 0;
      v_wave_paused := false;

      select coalesce(sum(hp_current), 0) into v_e_before from combat_units where encounter_id = e.id and side = 'enemy';

      -- Wave lifecycle: spawn a fresh synthetic pirate wave when the enemy side is wiped — the exact
      -- mirror of the aggregate arm's `enemy_integrity_current <= 0` branch, now materialized as
      -- combat_units rows split across N units instead of a lone scalar.
      if v_e_before <= 0 then
        if e.next_wave_at is not null and now() < e.next_wave_at then
          v_wave_paused := true;
          if v_log_ticks then
            insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
                   player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after, result)
              values (e.id, e.player_id, v_tick, v_wave_num, v_danger, v_hp_total, v_hp_total, 0, 0, 'next_wave_incoming');
          end if;
          update combat_encounters set tick_number=v_tick, danger_level=v_danger, last_resolved_at=now(), updated_at=now() where id=e.id;
          v_count := v_count + 1;
        else
          v_wave_num     := e.waves_cleared + 1;
          -- SAME wave-hp/wave-attack formulas the aggregate arm has always used — UNCHANGED config
          -- keys — so a spatial wave's total hp/dps matches what the aggregate arm would have rolled.
          v_enemy_hp     := loc.base_difficulty * coalesce(cfg_num('enemy_hp_base'),14)
                            * (1 + v_danger * coalesce(cfg_num('enemy_hp_danger_scale'),0.6)) * v_variance;
          v_enemy_attack := loc.base_difficulty * coalesce(cfg_num('enemy_attack_base'),1.0)
                            * (1 + v_danger * coalesce(cfg_num('enemy_attack_danger_scale'),0.25));
          v_enemy_count  := least(coalesce(cfg_num('enemy_synthetic_max_units'),6)::integer, greatest(1, v_danger));
          select x, y into v_loc_x, v_loc_y from locations where id = e.location_id;
          v_enemy_range      := coalesce(cfg_num('enemy_synthetic_range_base'),120)
                                 + loc.base_difficulty * coalesce(cfg_num('enemy_synthetic_range_per_difficulty'),5);
          v_enemy_speed      := coalesce(cfg_num('enemy_synthetic_speed_base'),3)
                                 + loc.base_difficulty * coalesce(cfg_num('enemy_synthetic_speed_per_difficulty'),0.2);
          v_enemy_proj_speed := coalesce(cfg_num('enemy_synthetic_projectile_speed'),250);
          v_enemy_cooldown   := coalesce(cfg_num('enemy_synthetic_cooldown_seconds'),2);
          v_enemy_unit_hp    := v_enemy_hp / v_enemy_count;
          v_enemy_unit_power := v_enemy_attack / v_enemy_count;

          -- Pirates spawn from the ZONE/LOCATION CENTER — every synthetic unit lands at the same point.
          delete from combat_units where encounter_id = e.id and side = 'enemy';
          for v_spawn_i in 1 .. v_enemy_count loop
            insert into combat_units (
              encounter_id, player_id, unit_type_id, side, ship_hp, initial_count, alive_count,
              hp_max, hp_current, pos_x, pos_y, move_speed, weapons_json)
            values (
              e.id, e.player_id, 'pirate_synthetic', 'enemy', v_enemy_unit_hp, 1, 1,
              v_enemy_unit_hp, v_enemy_unit_hp, v_loc_x, v_loc_y, v_enemy_speed,
              jsonb_build_array(jsonb_build_object(
                'module_type_id', 'pirate_synthetic_weapon', 'range', v_enemy_range,
                'projectile_speed', v_enemy_proj_speed, 'power', v_enemy_unit_power,
                'ammo_type', null, 'ammo_per_shot', 0, 'cooldown_seconds', v_enemy_cooldown,
                'next_ready_at', null, 'ammo_remaining', null)));
          end loop;
          v_e_before := v_enemy_hp;  -- the fresh wave's starting total (mirrors the aggregate arm's v_e_before)
          if v_log_events then
            insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
              values (e.id, e.player_id, v_tick, v_seq, 'wave_spawned', 'pirate', 'player',
                      jsonb_build_object('wave', v_wave_num, 'danger', v_danger, 'hp', round(v_enemy_hp), 'units', v_enemy_count));
          end if;
          v_seq := v_seq + 1;
        end if;
      else
        v_enemy_hp := e.enemy_integrity_max;  -- ongoing wave: the ceiling carries over, unchanged
      end if;

      if not v_wave_paused then
        -- Shield regen — once per unit per tick, BEFORE any fire this tick (the SHIELD-1 pattern,
        -- reused: a NULL shield_max row is untouched, exactly the shieldless-unit no-op).
        for cu in select * from combat_units where encounter_id = e.id and alive_count > 0 and shield_max is not null loop
          update combat_units set shield_current = least(cu.shield_max, cu.shield_current + cu.shield_max * v_shield_regen)
            where id = cu.id;
        end loop;

        -- Freeze this tick's population BEFORE any movement is applied — every targeting decision
        -- below reads THIS snapshot, never the live table, so a unit processed earlier in the loop
        -- can never contaminate a later unit's pre-move distance.
        select coalesce(jsonb_agg(jsonb_build_object(
                 'id', cu2.id, 'side', cu2.side, 'pos_x', cu2.pos_x, 'pos_y', cu2.pos_y,
                 'my_range', (select max((w->>'range')::double precision) from jsonb_array_elements(cu2.weapons_json) w),
                 'move_speed', coalesce(cu2.move_speed, 0),
                 'aggro_priority', cu2.aggro_priority,
                 'main_ship_id', cu2.main_ship_id)), '[]'::jsonb)
          into v_units
          from combat_units cu2
          where cu2.encounter_id = e.id and cu2.alive_count > 0;

        v_dmg_player_total := 0; v_dmg_enemy_total := 0;

        for v_ur in
          select * from jsonb_to_recordset(v_units) as x(
            id uuid, side text, pos_x double precision, pos_y double precision,
            my_range double precision, move_speed double precision, aggro_priority integer, main_ship_id uuid)
        loop
          -- Retreating player ships hold position and cease fire (the v_offense gate, mirrored — the
          -- enemy side is NEVER gated by this, exactly matching the aggregate arm's asymmetry).
          if v_ur.side = 'player' and not v_offense then
            continue;
          end if;

          -- TARGETING: nearest alive opposite-side unit, aggro-tier-filtered (S1's screening, reused
          -- verbatim in spirit — while any escort, aggro 0, is alive, only escorts are targetable; the
          -- player side has no aggro filter since every enemy row's aggro_priority is NULL).
          v_target_id := null; v_target_x := null; v_target_y := null; v_target_range := null; v_target_dist := null;
          with candidates as (
            select x.id, x.pos_x, x.pos_y, x.my_range, x.aggro_priority,
                   public.osn_distance(v_ur.pos_x, v_ur.pos_y, x.pos_x, x.pos_y) as dist
            from jsonb_to_recordset(v_units) as x(
              id uuid, side text, pos_x double precision, pos_y double precision,
              my_range double precision, move_speed double precision, aggro_priority integer, main_ship_id uuid)
            where x.side is distinct from v_ur.side
          ),
          tier as (select min(aggro_priority) as m from candidates)
          select c.id, c.pos_x, c.pos_y, c.my_range, c.dist
            into v_target_id, v_target_x, v_target_y, v_target_range, v_target_dist
          from candidates c, tier
          where tier.m is null or c.aggro_priority = tier.m
          order by c.dist asc, c.id asc
          limit 1;

          if v_target_id is null then
            continue;
          end if;

          -- MOVEMENT — combat_unit_decide_move, the pure leaf.
          select action, new_x, new_y into v_move_action, v_new_x, v_new_y
            from public.combat_unit_decide_move(
              v_ur.pos_x, v_ur.pos_y, coalesce(v_ur.my_range,0), coalesce(v_ur.move_speed,0),
              v_target_x, v_target_y, coalesce(v_target_range,0));
          update combat_units set pos_x = v_new_x, pos_y = v_new_y, updated_at = now() where id = v_ur.id;

          -- FIRE — this unit's own weapons_json. Safe to read live: only the unit itself ever writes
          -- its own weapons_json (no other unit's processing this tick can have touched it).
          select weapons_json into v_weapons_json from combat_units where id = v_ur.id;
          v_weapons_out := v_weapons_json;
          for v_widx in 0 .. jsonb_array_length(v_weapons_json) - 1 loop
            v_weapon      := v_weapons_json -> v_widx;
            v_w_range     := (v_weapon->>'range')::double precision;
            v_w_pspeed    := coalesce((v_weapon->>'projectile_speed')::double precision, 300);
            v_w_power     := coalesce((v_weapon->>'power')::double precision, 0);
            v_w_ammo_type := v_weapon->>'ammo_type';
            v_w_ammo_per_shot := coalesce((v_weapon->>'ammo_per_shot')::integer, 0);
            v_w_next_ready := nullif(v_weapon->>'next_ready_at','')::timestamptz;

            if v_w_range is not null and v_target_dist <= v_w_range
               and (v_w_next_ready is null or now() >= v_w_next_ready) then
              if v_log_events then
                insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target,
                      projectile_type, projectile_count, impact_delay_ms, payload_json)
                  values (e.id, e.player_id, v_tick, v_seq,
                          'missile_salvo',
                          case when v_ur.side = 'enemy' then 'pirate' else 'player' end,
                          case when v_ur.side = 'enemy' then 'player' else 'pirate' end,
                          coalesce(v_weapon->>'module_type_id', 'weapon'), 1,
                          round(1000 * v_target_dist / nullif(v_w_pspeed,0))::integer,
                          jsonb_build_object('unit_id', v_ur.id, 'target_id', v_target_id));
              end if;
              v_seq := v_seq + 1;

              -- DAMAGE — re-read the target fresh (it may already have taken an earlier shot THIS
              -- tick from a different firer); a target that died to an earlier shot simply takes no
              -- further damage from this one (`if found` guards it) — no error, no double-kill.
              select hp_current, shield_current, shield_max, alive_count, ship_hp, side, defense_snapshot, main_ship_id
                into v_t_hp, v_t_shield, v_t_shieldmax, v_t_alive, v_t_shiphp, v_t_side, v_t_defense, v_t_mainship
                from combat_units where id = v_target_id and alive_count > 0;
              if found then
                -- The aggregate arm's own asymmetry, reused: player fire on enemies is NEVER
                -- defense-mitigated (enemies carry no defense_snapshot); enemy fire on players IS,
                -- via the same def_base curve.
                if v_t_side = 'enemy' then
                  v_dmg := v_w_power * v_variance;
                else
                  v_dmg := v_w_power * v_def_base / (v_def_base + coalesce(v_t_defense,0)) * v_variance;
                end if;
                -- SHIELD-1 (0195) absorb pattern, reused verbatim: shield soaks min(pool,damage); only
                -- the overflow reaches hp.
                v_absorb     := least(coalesce(v_t_shield,0), v_dmg);
                v_shield_new := case when v_t_shieldmax is not null then v_t_shield - v_absorb else null end;
                v_new_hp     := v_t_hp - (v_dmg - v_absorb);
                v_new_alive  := greatest(0, least(v_t_alive, ceil(v_new_hp / v_t_shiphp)::integer));
                v_destroyed  := v_t_alive - v_new_alive;
                update combat_units set hp_current = greatest(0, v_new_hp), alive_count = v_new_alive,
                       shield_current = v_shield_new, updated_at = now()
                  where id = v_target_id;
                if v_t_side = 'player' then
                  perform mainship_sync_combat_hp(v_t_mainship, round(greatest(0, v_new_hp))::integer);
                  if v_shield_new is not null then
                    perform mainship_sync_combat_shield(v_t_mainship, round(v_shield_new)::integer);
                  end if;
                  v_dmg_enemy_total := v_dmg_enemy_total + v_dmg;
                else
                  v_dmg_player_total := v_dmg_player_total + v_dmg;
                end if;
                if v_log_debug then
                  insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
                    values (e.id, e.player_id, v_tick, v_seq, 'hull_damage',
                            case when v_ur.side='enemy' then 'pirate' else 'player' end,
                            case when v_ur.side='enemy' then 'player' else 'pirate' end,
                            jsonb_build_object('unit_id', v_target_id, 'damage', round(v_dmg)));
                  v_seq := v_seq + 1;
                end if;
                if v_destroyed > 0 and v_log_events then
                  insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
                    values (e.id, e.player_id, v_tick, v_seq, 'unit_destroyed',
                            case when v_ur.side='enemy' then 'pirate' else 'player' end,
                            case when v_ur.side='enemy' then 'player' else 'pirate' end,
                            jsonb_build_object('unit_id', v_target_id, 'count', v_destroyed));
                  v_seq := v_seq + 1;
                end if;
              end if;

              -- Ammo decrement (per the charter) — documented-inert scaffolding: no module seeds
              -- ammo_type yet (S0's own deferral), so this never actually consumes anything today,
              -- and fire eligibility above is NOT gated on ammo_remaining (no inventory source is
              -- wired to initialize it — a future slice's decision).
              v_new_ammo := case when v_w_ammo_type is not null
                                 then greatest(0, coalesce((v_weapon->>'ammo_remaining')::integer, 0) - v_w_ammo_per_shot)
                                 else null end;
              v_weapons_out := jsonb_set(v_weapons_out, array[v_widx::text],
                                  v_weapon || jsonb_build_object('next_ready_at', now(), 'ammo_remaining', v_new_ammo));
            end if;
          end loop;
          update combat_units set weapons_json = v_weapons_out where id = v_ur.id;
        end loop;

        -- Wave-clear + per-tick bookkeeping — the aggregate arm's shape, computed over per-unit sums.
        select coalesce(sum(hp_current), 0) into v_e_after from combat_units where encounter_id = e.id and side = 'enemy';
        v_cleared := v_offense and v_e_after <= 0;
        select coalesce(sum(hp_current), 0) into v_hp_after from combat_units where encounter_id = e.id and side = 'player';

        v_reward_metal := 0; v_reward_delta := '{}'::jsonb; v_loot_items := '[]'::jsonb;
        if v_cleared then
          v_reward_metal := round(coalesce(cfg_num('reward_metal_base'),10) * greatest(loc.reward_tier,1)
                                  * (1 + coalesce(cfg_num('reward_danger_scale'),0.25) * v_danger) * coalesce(cfg_num('reward_multiplier'),1.0));
          v_loot_items   := pirate_loot_for_wave(v_wave_num, v_danger);
          v_reward_delta := jsonb_build_object('metal', v_reward_metal, 'items', v_loot_items);
          if v_log_events then
            insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
              values (e.id, e.player_id, v_tick, v_seq, 'explosion', 'player', 'pirate',
                      jsonb_build_object('wave_cleared', true, 'wave', v_wave_num, 'reward_metal', v_reward_metal, 'reward_items', v_loot_items));
            v_seq := v_seq + 1;
          end if;
        end if;

        if v_log_ticks then
          insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
                 player_power_before, enemy_power, player_damage, enemy_damage,
                 player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after,
                 player_losses_json, reward_delta_json, unit_snapshot_json, result)
            values (e.id, e.player_id, v_tick, v_wave_num, v_danger,
                    v_hp_total, v_e_before, v_dmg_player_total, v_dmg_enemy_total,
                    v_hp_total, greatest(0, v_hp_after), v_e_before, greatest(0, v_e_after),
                    '{}'::jsonb, v_reward_delta, '{}'::jsonb,
                    case when v_cleared then 'wave_cleared' else 'ongoing' end);
        end if;

        update combat_encounters set
          tick_number              = v_tick,
          danger_level             = v_danger,
          wave_number              = v_wave_num,
          waves_cleared            = waves_cleared + (case when v_cleared then 1 else 0 end),
          player_integrity_current = greatest(0, v_hp_after),
          enemy_integrity_max      = v_enemy_hp,
          enemy_integrity_current  = greatest(0, v_e_after),
          enemy_power_current      = greatest(0, v_e_after),
          next_wave_at             = case when v_cleared then now() + make_interval(secs => v_trans_secs) else e.next_wave_at end,
          player_power_current     = fleet_get_power(e.fleet_id),
          total_rewards_json       = case when v_cleared
                                       then total_rewards_json
                                            || jsonb_build_object('metal', coalesce((total_rewards_json->>'metal')::double precision,0) + v_reward_metal)
                                            || jsonb_build_object('items', loot_merge_items(total_rewards_json->'items', v_loot_items))
                                       else total_rewards_json end,
          last_resolved_at         = now(),
          updated_at               = now()
        where id = e.id;

        if v_hp_after <= 0 then
          perform fleet_destroy(e.fleet_id);
          for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null loop
            perform mainship_mark_combat_destroyed(cu.main_ship_id);
          end loop;
          perform presence_complete(e.presence_id);
          update combat_encounters set status='defeat', ended_at=now(), total_rewards_json='{}'::jsonb, updated_at=now() where id=e.id;
          if v_log_events then
            insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
              values (e.id, e.player_id, v_tick, v_seq, 'explosion', 'pirate', 'player', jsonb_build_object('reason','fleet_lost'));
          end if;
          perform report_create(e.id);
        end if;

        v_count := v_count + 1;
      end if; -- not v_wave_paused
    else
      -- ██████████████████████████████████████████████████████████████████████████████████████████
      -- 0228 HEAD — (C) Combat step, VERBATIM (the dark / no-positions byte-parity arm).
      -- ██████████████████████████████████████████████████████████████████████████████████████████
      v_danger       := 1 + e.waves_cleared + floor(v_secs_inside / coalesce(cfg_num('danger_time_divisor_seconds'), 180))::integer;
      v_variance     := (1 - v_var_pct) + random() * (2 * v_var_pct);
      v_enemy_attack := loc.base_difficulty * coalesce(cfg_num('enemy_attack_base'),1.0)
                        * (1 + v_danger * coalesce(cfg_num('enemy_attack_danger_scale'),0.25));
      v_seq          := 0;
      v_offense      := (e.status = 'active');
      v_wave_num     := e.wave_number;

      if e.enemy_integrity_current <= 0 then
        if e.next_wave_at is not null and now() < e.next_wave_at then
          if v_log_ticks then
            insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
                   player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after, result)
              values (e.id, e.player_id, v_tick, v_wave_num, v_danger, v_hp_total, v_hp_total, 0, 0, 'next_wave_incoming');
          end if;
          update combat_encounters set tick_number=v_tick, danger_level=v_danger, last_resolved_at=now(), updated_at=now() where id=e.id;
          v_count := v_count + 1; continue;
        end if;
        v_wave_num := e.waves_cleared + 1;
        v_enemy_hp := loc.base_difficulty * coalesce(cfg_num('enemy_hp_base'),14)
                      * (1 + v_danger * coalesce(cfg_num('enemy_hp_danger_scale'),0.6)) * v_variance;
        v_e_before := v_enemy_hp;
        if v_log_events then
          insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
            values (e.id, e.player_id, v_tick, v_seq, 'wave_spawned', 'pirate', 'player',
                    jsonb_build_object('wave', v_wave_num, 'danger', v_danger, 'hp', round(v_enemy_hp)));
        end if;
        v_seq := v_seq + 1;
      else
        v_enemy_hp := e.enemy_integrity_max;
        v_e_before := e.enemy_integrity_current;
      end if;

      if v_offense then
        v_player_damage := v_attack * v_variance;
        v_e_after := v_e_before - v_player_damage;
        v_cleared := v_e_after <= 0;
        if v_log_events then
          insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, projectile_type, projectile_count, impact_delay_ms, payload_json)
            values (e.id, e.player_id, v_tick, v_seq, 'missile_salvo', 'player', 'pirate', 'missile', greatest(1, round(v_attack/50)::integer), 400,
                    jsonb_build_object('damage', round(v_player_damage), 'wave', v_wave_num));
        end if;
        v_seq := v_seq + 1;
      else
        v_player_damage := 0; v_e_after := v_e_before; v_cleared := false;
      end if;

      if v_log_events then
        insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, projectile_type, projectile_count, impact_delay_ms)
          values (e.id, e.player_id, v_tick, v_seq, 'laser_burst', 'pirate', 'player', 'laser', greatest(1, v_danger), 600);
      end if;
      v_seq := v_seq + 1;
      v_final_player := v_enemy_attack * v_def_base / (v_def_base + v_defense) * v_variance;

      v_target_unit := null;
      if v_per_ship_targeting then
        select id into v_target_unit
          from combat_units
         where encounter_id = e.id and alive_count > 0 and aggro_priority is not null
         order by aggro_priority asc, id asc
         limit 1;
      end if;

      v_losses := '{}'::jsonb; v_counts := '{}'::jsonb; v_snapshot := '{}'::jsonb;
      for cu in select * from combat_units where encounter_id = e.id and alive_count > 0 loop
        v_shield    := least(cu.shield_max, cu.shield_current + cu.shield_max * v_shield_regen);
        if v_target_unit is not null then
          v_d_group := case when cu.id = v_target_unit then v_final_player else 0 end;
        else
          v_d_group   := v_final_player * cu.alive_count / greatest(v_alive_total, 1);
        end if;
        v_absorb    := least(coalesce(v_shield, 0), v_d_group);
        v_shield    := v_shield - v_absorb;
        v_new_hp    := cu.hp_current - (v_d_group - v_absorb);
        v_new_alive := greatest(0, least(cu.alive_count, ceil(v_new_hp / cu.ship_hp)::integer));
        v_destroyed := cu.alive_count - v_new_alive;
        update combat_units set hp_current = greatest(0, v_new_hp), alive_count = v_new_alive,
               shield_current = v_shield,
               updated_at = now()
          where id = cu.id;
        if cu.unit_type_id is not null then
          v_counts := v_counts || jsonb_build_object(cu.unit_type_id, v_new_alive);
        else
          perform mainship_sync_combat_hp(cu.main_ship_id, round(greatest(0, v_new_hp))::integer);
          if v_shield is not null then
            perform mainship_sync_combat_shield(cu.main_ship_id, round(v_shield)::integer);
          end if;
        end if;
        v_snapshot := v_snapshot || jsonb_build_object(coalesce(cu.unit_type_id, cu.main_ship_id::text),
                         jsonb_build_object('alive', v_new_alive, 'hp', round(greatest(0, v_new_hp))));
        if v_log_debug then
          insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
            values (e.id, e.player_id, v_tick, v_seq, 'hull_damage', 'pirate', 'player',
                    jsonb_build_object('group', coalesce(cu.unit_type_id, cu.main_ship_id::text), 'damage', round(v_d_group)));
        end if;
        v_seq := v_seq + 1;
        if v_destroyed > 0 then
          v_losses := v_losses || jsonb_build_object(coalesce(cu.unit_type_id, cu.main_ship_id::text), v_destroyed);
          if v_log_events then
            insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
              values (e.id, e.player_id, v_tick, v_seq, 'unit_destroyed', 'pirate', 'player',
                      jsonb_build_object('group', coalesce(cu.unit_type_id, cu.main_ship_id::text), 'count', v_destroyed));
          end if;
          v_seq := v_seq + 1;
        end if;
      end loop;

      perform fleet_sync_quantities(e.fleet_id, v_counts);
      select coalesce(sum(hp_current), 0) into v_hp_after from combat_units where encounter_id = e.id;

      v_reward_metal := 0; v_reward_delta := '{}'::jsonb; v_loot_items := '[]'::jsonb;
      if v_cleared and v_offense then
        v_reward_metal := round(coalesce(cfg_num('reward_metal_base'),10) * greatest(loc.reward_tier,1)
                                * (1 + coalesce(cfg_num('reward_danger_scale'),0.25) * v_danger) * coalesce(cfg_num('reward_multiplier'),1.0));
        v_loot_items   := pirate_loot_for_wave(v_wave_num, v_danger);
        v_reward_delta := jsonb_build_object('metal', v_reward_metal, 'items', v_loot_items);
        if v_log_events then
          insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
            values (e.id, e.player_id, v_tick, v_seq, 'explosion', 'player', 'pirate',
                    jsonb_build_object('wave_cleared', true, 'wave', v_wave_num, 'reward_metal', v_reward_metal, 'reward_items', v_loot_items));
        end if;
        v_seq := v_seq + 1;
      end if;

      if v_log_ticks then
        insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
               player_power_before, enemy_power, player_damage, enemy_damage,
               player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after,
               player_losses_json, reward_delta_json, unit_snapshot_json, result)
          values (e.id, e.player_id, v_tick, v_wave_num, v_danger,
                  v_hp_total, v_e_before, v_player_damage, v_final_player,
                  v_hp_total, greatest(0, v_hp_after), v_e_before, greatest(0, v_e_after),
                  v_losses, v_reward_delta, v_snapshot,
                  case when v_cleared then 'wave_cleared' else 'ongoing' end);
      end if;

      update combat_encounters set
        tick_number              = v_tick,
        danger_level             = v_danger,
        wave_number              = v_wave_num,
        waves_cleared            = waves_cleared + (case when v_cleared then 1 else 0 end),
        player_integrity_current = greatest(0, v_hp_after),
        enemy_integrity_max      = v_enemy_hp,
        enemy_integrity_current  = case when v_cleared then 0 else greatest(0, v_e_after) end,
        enemy_power_current      = case when v_cleared then 0 else greatest(0, v_e_after) end,
        next_wave_at             = case when v_cleared then now() + make_interval(secs => v_trans_secs) else e.next_wave_at end,
        player_power_current     = fleet_get_power(e.fleet_id),
        total_rewards_json       = case when v_cleared and v_offense
                                     then total_rewards_json
                                          || jsonb_build_object('metal', coalesce((total_rewards_json->>'metal')::double precision,0) + v_reward_metal)
                                          || jsonb_build_object('items', loot_merge_items(total_rewards_json->'items', v_loot_items))
                                     else total_rewards_json end,
        last_resolved_at         = now(),
        updated_at               = now()
      where id = e.id;

      if v_hp_after <= 0 then
        perform fleet_destroy(e.fleet_id);
        for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null loop
          perform mainship_mark_combat_destroyed(cu.main_ship_id);
        end loop;
        perform presence_complete(e.presence_id);
        update combat_encounters set status='defeat', ended_at=now(), total_rewards_json='{}'::jsonb, updated_at=now() where id=e.id;
        if v_log_events then
          insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
            values (e.id, e.player_id, v_tick, v_seq, 'explosion', 'pirate', 'player', jsonb_build_object('reason','fleet_lost'));
        end if;
        perform report_create(e.id);
      end if;

      v_count := v_count + 1;
    end if;
    exception
      when query_canceled then raise;
      when others then
        raise warning 'process_combat_ticks: tick failed for encounter % (left in-place; retries next tick): %',
          e.id, sqlerrm;
    end;
  end loop;

  return v_count;
end;
$$;

-- ── 7) report_create — 0167 body VERBATIM + the ONE necessary `and side = 'player'` filter ──────────
-- Provable no-op for every pre-existing / non-spatial row (side defaults 'player'); prevents a spatial
-- encounter's synthetic pirate units (side='enemy', identity 'pirate_synthetic') from folding into the
-- PLAYER survivors/losses report.
create or replace function public.report_create(p_encounter uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  e          combat_encounters%rowtype;
  v_id       uuid;
  v_survivors jsonb;
  v_losses    jsonb;
  v_dur      integer;
begin
  select * into e from combat_encounters where id = p_encounter;
  if not found then
    raise exception 'report_create: encounter % not found', p_encounter;
  end if;
  if exists (select 1 from combat_reports where encounter_id = p_encounter) then
    return null;
  end if;

  -- COMBAT-S3 (0231): `and side = 'player'` — the ONE token added to this scan. Every pre-existing row
  -- is side='player' by column default, so this is a provable no-op for every non-spatial encounter.
  select
    coalesce(jsonb_object_agg(coalesce(unit_type_id, main_ship_id::text), alive_count) filter (where alive_count > 0), '{}'::jsonb),
    coalesce(jsonb_object_agg(coalesce(unit_type_id, main_ship_id::text), initial_count - alive_count) filter (where initial_count - alive_count > 0), '{}'::jsonb)
    into v_survivors, v_losses
    from combat_units where encounter_id = p_encounter and side = 'player';

  v_dur := greatest(0, extract(epoch from (coalesce(e.ended_at, now()) - e.started_at))::integer);

  insert into combat_reports (
    encounter_id, player_id, fleet_id, location_id, result, waves_cleared,
    duration_seconds, total_losses_json, total_rewards_json, survivors_json, summary_text)
  values (
    e.id, e.player_id, e.fleet_id, e.location_id, e.status, e.waves_cleared,
    v_dur, coalesce(v_losses, '{}'::jsonb), e.total_rewards_json, coalesce(v_survivors, '{}'::jsonb),
    format('%s after %s wave(s) over %ss', e.status, e.waves_cleared, v_dur))
  on conflict (encounter_id) do nothing
  returning id into v_id;

  update combat_encounters set report_created_at = now() where id = p_encounter;
  return v_id;
end;
$$;

-- ── 8) Execute surface ────────────────────────────────────────────────────────────────────────────
-- CREATE OR REPLACE on the three EXISTING functions PRESERVES their owner + grants (all three are
-- internal engine/cron functions with no client grant) — no blanket re-lock is emitted.

-- ── 9) SELF-ASSERTS — deploy-time; the migration proves its own grounding or refuses to land ────────
do $$
declare
  v_creator text;
  v_tick    text;
  v_report  text;
  v_n       integer;
  v_row     record;
  v_tok     text;
begin
  select prosrc into v_creator from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  select prosrc into v_tick from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'process_combat_ticks';
  select prosrc into v_report from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'report_create';
  if v_creator is null or v_tick is null or v_report is null then
    raise exception 'COMBAT-S3 self-assert FAIL: a re-created combat function is missing';
  end if;

  -- PROSRC-ASSERT COUPLING (the 0221/0222 house lesson): strip `--` line comments before probing.
  v_creator := regexp_replace(v_creator, '--[^\n]*', '', 'g');
  v_tick    := regexp_replace(v_tick,    '--[^\n]*', '', 'g');
  v_report  := regexp_replace(v_report,  '--[^\n]*', '', 'g');

  -- (1) the flag is committed DARK.
  if coalesce((select value #>> '{}' from public.game_config where key = 'spatial_combat_enabled'), 'false') <> 'false' then
    raise exception 'COMBAT-S3 self-assert FAIL: spatial_combat_enabled is not seeded false';
  end if;

  -- (2) combat_units columns: additive, correctly typed/nullable, defaults land inert on every
  --     pre-existing row (none of which this migration touches — no backfill statement exists).
  if not exists (select 1 from information_schema.columns
      where table_schema='public' and table_name='combat_units' and column_name='pos_x' and is_nullable='YES') then
    raise exception 'COMBAT-S3 self-assert FAIL: combat_units.pos_x missing/not nullable'; end if;
  if not exists (select 1 from information_schema.columns
      where table_schema='public' and table_name='combat_units' and column_name='pos_y' and is_nullable='YES') then
    raise exception 'COMBAT-S3 self-assert FAIL: combat_units.pos_y missing/not nullable'; end if;
  if not exists (select 1 from information_schema.columns
      where table_schema='public' and table_name='combat_units' and column_name='move_speed' and is_nullable='YES') then
    raise exception 'COMBAT-S3 self-assert FAIL: combat_units.move_speed missing/not nullable'; end if;
  if not exists (select 1 from information_schema.columns
      where table_schema='public' and table_name='combat_units' and column_name='weapons_json'
        and is_nullable='NO' and column_default is not null) then
    raise exception 'COMBAT-S3 self-assert FAIL: combat_units.weapons_json missing/nullable/no default'; end if;
  if not exists (select 1 from information_schema.columns
      where table_schema='public' and table_name='combat_units' and column_name='side'
        and is_nullable='NO' and column_default like '%player%') then
    raise exception 'COMBAT-S3 self-assert FAIL: combat_units.side missing/nullable/wrong default'; end if;
  select count(*) into v_n from public.combat_units where pos_x is not null or pos_y is not null or move_speed is not null;
  if v_n <> 0 then
    raise exception 'COMBAT-S3 self-assert FAIL: % pre-existing combat_units row(s) already carry a position at migration time (want 0)', v_n;
  end if;
  select count(*) into v_n from public.combat_units where side <> 'player' or weapons_json <> '[]'::jsonb;
  if v_n <> 0 then
    raise exception 'COMBAT-S3 self-assert FAIL: % pre-existing combat_units row(s) are not side=player/weapons_json=[] (want 0)', v_n;
  end if;

  -- (3) the pirate_synthetic identity anchor is seeded, disabled, never a real unit.
  if not exists (select 1 from public.unit_types where id = 'pirate_synthetic' and status = 'disabled') then
    raise exception 'COMBAT-S3 self-assert FAIL: unit_types.pirate_synthetic missing or not disabled';
  end if;

  -- (4) THE DECIDE-MOVE LEAF — genuinely executable (table-free/FK-free): CLOSE, KITE, and HOLD each
  --     proven on concrete numbers, not just "the branch text exists".
  select * into v_row from public.combat_unit_decide_move(0, 0, 100, 10, 500, 0, 100);  -- far out of range
  if v_row.action <> 'close' or v_row.new_x <> 10 or v_row.new_y <> 0 then
    raise exception 'COMBAT-S3 self-assert FAIL: CLOSE case wrong (action=%, new_x=%, new_y=%)', v_row.action, v_row.new_x, v_row.new_y;
  end if;
  select * into v_row from public.combat_unit_decide_move(0, 0, 100, 10, 50, 0, 20);  -- I can hit them (100>=50), they can't hit me (50>20)
  if v_row.action <> 'kite' or v_row.new_x <> -10 or v_row.new_y <> 0 then
    raise exception 'COMBAT-S3 self-assert FAIL: KITE case wrong (action=%, new_x=%, new_y=%)', v_row.action, v_row.new_x, v_row.new_y;
  end if;
  select * into v_row from public.combat_unit_decide_move(0, 0, 100, 10, 50, 0, 60);  -- both in range (100>=50 and 60>=50)
  if v_row.action <> 'hold' or v_row.new_x <> 0 or v_row.new_y <> 0 then
    raise exception 'COMBAT-S3 self-assert FAIL: HOLD case wrong (action=%, new_x=%, new_y=%)', v_row.action, v_row.new_x, v_row.new_y;
  end if;
  -- a faster+longer-range unit kites a slower+shorter one — emergent, not hardcoded (the charter's
  -- own framing): same geometry as the KITE case above but re-derived from a "who out-ranges/out-runs
  -- whom" framing to prove it is the RANGE/SPEED comparison driving the outcome, not a magic constant.
  select * into v_row from public.combat_unit_decide_move(0, 0, 150, 8, 100, 0, 60);  -- my_range 150 >= dist 100 (I can hit them); their_range 60 < 100 (they can't hit me)
  if v_row.action <> 'kite' or v_row.new_x <> -8 or v_row.new_y <> 0 then
    raise exception 'COMBAT-S3 self-assert FAIL: longer-range-kites-shorter-range case wrong (action=%, new_x=%, new_y=%)', v_row.action, v_row.new_x, v_row.new_y;
  end if;
  if has_function_privilege('anon', 'public.combat_unit_decide_move(double precision, double precision, double precision, double precision, double precision, double precision, double precision)', 'execute') then
    raise exception 'COMBAT-S3 self-assert FAIL: combat_unit_decide_move is anon-executable (must not be)';
  end if;

  -- (5) CREATOR — the spawn hunk: gate hoisted, position/weapons only computed when lit, new columns
  --     appended (not replacing) the existing INSERT column/select lists.
  if strpos(v_creator, 'v_spatial_enabled boolean := public.cfg_bool(''spatial_combat_enabled'');') = 0 then
    raise exception 'COMBAT-S3 self-assert FAIL: creator is missing the hoisted spatial gate read';
  end if;
  if strpos(v_creator, 'v_pos_x := null; v_pos_y := null; v_move_speed := null; v_weapons_json := ''[]''::jsonb;') = 0 then
    raise exception 'COMBAT-S3 self-assert FAIL: creator is missing the unconditional per-member inert reset';
  end if;
  if strpos(v_creator, 'v_pos_x := null;') > strpos(v_creator, 'if m.hp > 0 then') then
    raise exception 'COMBAT-S3 self-assert FAIL: the position reset is not unconditional (placed after the hp>0 branch)';
  end if;
  if strpos(v_creator, 'if v_spatial_enabled then') = 0 then
    raise exception 'COMBAT-S3 self-assert FAIL: creator does not gate the spatial snapshot on the flag';
  end if;
  if strpos(v_creator, 'v_move_speed := coalesce((v_stats->>''speed'')::double precision, 1);') = 0 then
    raise exception 'COMBAT-S3 self-assert FAIL: creator does not reuse calculate_expedition_stats'' own speed';
  end if;
  if strpos(v_creator, 'pos_x, pos_y, move_speed, weapons_json, side)') = 0 then
    raise exception 'COMBAT-S3 self-assert FAIL: creator INSERT does not append the 5 new columns';
  end if;
  -- pre-existing hull-integrity statement (the 0228/0195 pin, re-pinned) survives untouched.
  if strpos(v_creator, 'select coalesce(sum(hp_max), 0) into v_hull from combat_units where encounter_id = v_enc;') = 0 then
    raise exception 'COMBAT-S3 self-assert FAIL: creator lost the hull-only integrity statement';
  end if;

  -- (6) TICK — the null-pos fallback + dark-arm byte parity.
  if strpos(v_tick, 'v_is_spatial := v_spatial_combat_enabled') = 0
     or strpos(v_tick, 'exists (select 1 from combat_units where encounter_id = e.id and pos_x is not null)') = 0 then
    raise exception 'COMBAT-S3 self-assert FAIL: the tick is missing the null-pos-fallback detection';
  end if;
  v_n := (length(v_tick) - length(replace(v_tick, 'cfg_bool(''spatial_combat_enabled'')', '')))
         / length('cfg_bool(''spatial_combat_enabled'')');
  if v_n <> 1 then
    raise exception 'COMBAT-S3 self-assert FAIL: spatial_combat_enabled read % times (want exactly 1 — hoisted)', v_n;
  end if;
  -- the 0228 aggregate select survives verbatim as the else-arm.
  if strpos(v_tick, 'coalesce(sum(coalesce(cu2.attack_snapshot, ut.attack) * cu2.alive_count), 0)') = 0 then
    raise exception 'COMBAT-S3 self-assert FAIL: the 0228 aggregate SELECT is gone (byte-parity breach)';
  end if;
  -- the shared (A)/(B) blocks survive, unbranched by v_is_spatial (both member-scoping filters intact).
  if strpos(v_tick, 'for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null loop') = 0 then
    raise exception 'COMBAT-S3 self-assert FAIL: the shared (A) defeat member-mark loop is gone';
  end if;
  if strpos(v_tick, 'for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null and alive_count > 0 loop') = 0 then
    raise exception 'COMBAT-S3 self-assert FAIL: the shared (B) escape repatriation loop is gone';
  end if;
  -- the 0228 (C) block survives verbatim as the else-arm of the new branch — several independent,
  -- distinctive single-line tokens pinned separately (the 0228 house convention: single-line strpos
  -- pins, never a whitespace-sensitive multi-line join, which a harmless re-indent could false-fail).
  foreach v_tok in array array[
      'v_enemy_attack := loc.base_difficulty * coalesce(cfg_num(''enemy_attack_base''),1.0)',
      'v_wave_num := e.waves_cleared + 1;',
      'v_player_damage := v_attack * v_variance;',
      'v_final_player := v_enemy_attack * v_def_base / (v_def_base + v_defense) * v_variance;'
    ] loop
    if strpos(v_tick, v_tok) = 0 then
      raise exception 'COMBAT-S3 self-assert FAIL: process_combat_ticks lost a 0228 (C)-block token (%)', v_tok;
    end if;
  end loop;
  if strpos(v_tick, 'v_d_group := case when cu.id = v_target_unit then v_final_player else 0 end;') = 0
     or strpos(v_tick, 'v_d_group   := v_final_player * cu.alive_count / greatest(v_alive_total, 1);') = 0 then
    raise exception 'COMBAT-S3 self-assert FAIL: the 0228 per-ship-targeting/equal-split branch is gone from the else-arm';
  end if;
  -- the spatial branch itself: targeting/movement/fire/damage all present.
  if strpos(v_tick, 'combat_unit_decide_move(') = 0 then
    raise exception 'COMBAT-S3 self-assert FAIL: the spatial branch never calls combat_unit_decide_move';
  end if;
  if strpos(v_tick, 'where x.side is distinct from v_ur.side') = 0 then
    raise exception 'COMBAT-S3 self-assert FAIL: the spatial branch is missing the opposite-side targeting filter';
  end if;
  if strpos(v_tick, 'tier as (select min(aggro_priority) as m from candidates)') = 0 then
    raise exception 'COMBAT-S3 self-assert FAIL: the spatial branch is missing the aggro-tier screening reuse';
  end if;
  if strpos(v_tick, 'encounter_id, player_id, unit_type_id, side, ship_hp, initial_count, alive_count,') = 0 then
    raise exception 'COMBAT-S3 self-assert FAIL: the spatial branch is missing the synthetic enemy spawn insert';
  end if;
  -- determinism (0041): no NEW random() call beyond the head's one variance roll per branch.
  v_n := (length(v_tick) - length(replace(v_tick, 'random(', ''))) / length('random(');
  if v_n <> 2 then
    raise exception 'COMBAT-S3 self-assert FAIL: process_combat_ticks carries % random( call(s) (want exactly 2 — one per (C) arm''s variance roll)', v_n;
  end if;

  -- (7) REPORT_CREATE — the one added filter, provably scoped to the combat_units scan only.
  if strpos(v_report, 'from combat_units where encounter_id = p_encounter and side = ''player''') = 0 then
    raise exception 'COMBAT-S3 self-assert FAIL: report_create is missing the side=player scoping filter';
  end if;

  -- (8) ACL: all three re-created engine functions stay non-client-executable (unchanged posture).
  if has_function_privilege('authenticated', 'public.combat_create_group_encounter(uuid)', 'execute')
     or has_function_privilege('anon', 'public.combat_create_group_encounter(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.process_combat_ticks()', 'execute')
     or has_function_privilege('anon', 'public.process_combat_ticks()', 'execute') then
    raise exception 'COMBAT-S3 self-assert FAIL: a re-created engine function is client-executable';
  end if;

  raise notice 'COMBAT-S3 self-assert ok: spatial_combat_enabled seeded dark; combat_units pos_x/pos_y/move_speed/weapons_json/side additive with every pre-existing row inert (side=player, weapons_json=[], no position); pirate_synthetic identity anchor seeded disabled; combat_unit_decide_move proven executably on CLOSE/KITE/HOLD + the range/speed-driven kite case, locked from anon; creator hoists the spatial gate, resets position/weapons unconditionally per member, computes them only when lit reusing the SAME calculate_expedition_stats call, and appends (never replaces) the INSERT column/select lists; tick hoists the spatial gate once, the null-pos-fallback exists() check gates v_is_spatial, the 0228 aggregate SELECT and the ENTIRE 0228 (C) block survive byte-identical as the else-arm alongside the shared unbranched (A)/(B) member-scoped loops, and the new spatial branch composes combat_unit_decide_move + aggro-tier targeting + per-weapon fire/damage + synthetic enemy wave spawn; report_create gained the one provably-inert side=player scoping filter; ACL on all three engine functions unchanged (non-client-executable)';
end $$;
