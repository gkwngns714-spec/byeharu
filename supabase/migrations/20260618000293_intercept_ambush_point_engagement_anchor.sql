-- 0293 — THE INTERCEPT TELEPORT. A fleet sent toward a hostile area is TELEPORTED to the destination
-- location's centre the instant the ambush fires. This migration makes the ambush stop the fleet WHERE
-- IT WAS AMBUSHED, and separates encounter IDENTITY (which location owns the fight, its pirates, its
-- rewards, its presence) from encounter POSITION (the point in space where the fight physically is).
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════
-- THE DEFECT, TRACED
--   command_ship_group_go (TRUE head 0233:589-995) mints a proper TIMED leg — movement_create 'rally'
--   (0233:962-966) + fleet_set_moving (0233:968) — and then, IN THE SAME TRANSACTION, calls
--   pirate_intercept_evaluate_leg (0233:975).
--   pirate_intercept_evaluate_leg (deployed head 0290:45-274) on a hit then:
--     0290:199  update fleet_movements set status = 'cancelled'   <- destroys the leg just ordered
--     0290:226  perform fleet_set_present(fleet, sector, zone, location)
--   fleet_set_present (0006:128-140) writes status='present', location_mode='location',
--   active_movement_id=null, current_location_id=<the DESTINATION location>. There is no segment, no
--   duration, no interpolation: one UPDATE and the fleet is standing at the far end of a journey it
--   never made. That is the teleport, and with 0236's tuning (base_risk 1.0 / min_risk 0.98 /
--   max_risk 1.0 / exposure_floor 1.0) it fires on very nearly every crossing.
--
--   The SAME function already does the right thing one branch up. A zone with NO linked location parks
--   the fleet with fleet_set_in_space(fleet, ambush_x, ambush_y) (0290:206), and the vanished-location
--   fail-open (0290:219) and the 0290 zero-manifest guard (0290:253) do the same. ambush_x/ambush_y
--   come from pirate_intercept_leg_zone_hits: ST_ClosestPoint(leg.geom, ST_Centroid(zone.boundary)) —
--   the point on the fleet's OWN leg where it met the zone. It is already computed, already logged,
--   already the parking coordinate for three of the four ambush exits. The linked-location exit is the
--   only one that throws it away.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════
-- THE RULING IMPLEMENTED HERE
--   (1) The location-linked ambush branch stops the fleet at the computed ambush point, exactly like
--       the standalone-zone branch. The linked-zone call to fleet_set_present is REMOVED. After this
--       migration ALL FOUR ambush exits park via fleet_set_in_space at ambush_x/ambush_y — there is no
--       longer any path through this function that writes a position the fleet did not travel to.
--       process_pirate_route_legs needs NO edit to inherit the identical rule: it does not park a fleet
--       itself, it calls this same evaluator (0233:1209) for every leg 2..N. One authority, one fix.
--   (2) The linked location REMAINS the authority for encounter content, pirate profile, rewards,
--       location name and presence ownership — presence_create still runs against v_loc, unchanged. It
--       STOPS being the physical coordinate authority: combat_encounters gains engagement_x /
--       engagement_y, the point where the fight actually is, and combat_create_group_encounter becomes
--       the single function that RESOLVES that point (intercept -> ambush_x/y; ordinary location hunt
--       -> location.x/y) and STORES it.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════
-- WHY THE LIFECYCLE LEAVES ARE RE-EMITTED (this is NOT scope creep — the ruling's fix does not
-- survive without it, and shipping without it trades a teleport for a permanently wedged fleet)
--   fleet_set_in_space (0231:1146) parks a fleet as status='idle', location_mode='space'. That is the
--   correct physical state and it is what the standalone branch has always produced. But the linked
--   branch alone goes on to open COMBAT, and both of process_combat_ticks' terminal branches assert the
--   OLD status:
--     0291:253 / :677 / :853  fleet_destroy(e.fleet_id)      — 0006:176 `status in ('moving','present','returning')`
--     0291:294                fleet_set_returning(e.fleet_id) — 0006:149 `status = 'present'`
--   An intercept fleet parked in space is 'idle', so BOTH raise. The tick wraps each encounter in a
--   subtransaction that swallows the raise and retries next tick (0291:867-872), so the encounter would
--   never reach a terminal state: every defeat and every retreat/max-presence extraction would spin
--   forever, warning every 2-4 seconds, with the player's ships stuck in a fight that cannot end. Both
--   leaves therefore learn ONE new legal from-state — a fleet parked in open space — and nothing else.
--   Blast radius, grep-verified: fleet_destroy's ONLY caller anywhere is process_combat_ticks (a fleet
--   that owns an active encounter, by construction); fleet_set_returning's callers each establish their
--   own precondition BEFORE calling (request_main_ship_return 0152:186 `status <> 'present'` raises;
--   send/return 0050:188, 0051:186 the same; presence_request_leave 0230 keys on a live presence row;
--   the tick keys on a live encounter). The widened arm is reachable only by the shape this migration
--   creates.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════
-- DELIBERATELY NOT DONE HERE — process_combat_ticks IS NOT TOUCHED. See the scope note at the foot of
-- this header. engagement_x/engagement_y land POPULATED AND UNREAD: no consumer in this migration reads
-- them, so the fight's spatial seeding is byte-for-byte what it is today. That is the point — 0291 JUST
-- restored 0242's sticky-mode guard in that function after 0260 and 0261 each reverted it from a stale
-- base, and repointing three reads inside a ~1000-line body is a separate slice with its own proof.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════
-- PROVENANCE — WHICH FILE:LINE EACH RE-EMITTED BODY WAS COPIED FROM, AND THE ONLY HUNKS CHANGED.
-- (The house lesson, stated twice today: 0284 re-emitted from a stale base and silently dropped the
-- provenance column list; 0260/0261 re-emitted from 0234 and silently reverted 0242's sticky-spatial
-- fix, twice. Every body below names its source and enumerates its deltas.)
--
--   A. public.pirate_intercept_evaluate_leg(uuid)
--      COPIED FROM: 20260618000290_intercept_zero_manifest_guard.sql:45-274 (the DEPLOYED head — the
--      0290 zero-manifest guard is IN this base, not bolted back on).
--      HUNKS: [A1] the linked-location park (0290:224-226) swaps fleet_set_present -> fleet_set_in_space
--             [A2] a new 3-line stamp of engagement_x/y = ambush_x/y on the encounter just created
--      EVERYTHING ELSE BYTE-IDENTICAL, INCLUDING: the dark gate, the 0276 typed-zone cutover and its
--      fail-closed exits, the stats fail-open, the single roll, the single pirate_intercepts insert, the
--      re-lock/race check, the cancel, the standalone stub, the location_missing fail-open, the 0290
--      manifest row_count capture + zero-manifest guard sited BEFORE presence_create, the
--      presence_create composition, the raise-free `exception when others` contract, and the grants.
--
--   B. public.combat_create_group_encounter(uuid) -> (uuid, double precision, double precision)
--      COPIED FROM: 20260618000262_combat_player_fallback_weapon.sql:63-242 (the TRUE head).
--      HUNKS: [B1] two optional trailing params (default null) + two locals
--             [B2] the engagement anchor is RESOLVED ONCE, unconditionally, as coalesce(param,
--                  location.x/y); the spatial block's own `select x, y from locations` is replaced by an
--                  assignment from that already-resolved anchor (same value, one read, one authority)
--             [B3] engagement_x/engagement_y appended to the combat_encounters INSERT
--      EVERYTHING ELSE BYTE-IDENTICAL, INCLUDING: the 0291-pinned creation-time flag gate
--      `v_spatial_enabled boolean := public.cfg_bool('spatial_combat_enabled')` (sticky mode is still
--      DECIDED at creation), the 0234 ring formation, the fitted-weapon range join, the 0262 empty-array
--      + positive-attack fallback weapon inside the LIT-only block, the 0234 spatial INSERT column
--      append, the hull rollup and the wave_spawned seed event.
--      SIGNATURE NOTE: the 1-arg form is DROPPED before the 3-arg form is created. Adding defaulted
--      params while the 1-arg overload still exists makes every existing `combat_create_group_encounter
--      (p_presence)` call ambiguous ("function is not unique") — including combat_create_encounter
--      0168:502 — and would leave TWO pg_proc rows under one proname, breaking every prosrc-by-proname
--      self-assert in the repo (0262:254, 0291:889). Exactly one row keeps its name.
--
--   C. public.fleet_set_returning(uuid, uuid)   COPIED FROM: 20260616000006_fleet_system.sql:142-153
--   D. public.fleet_destroy(uuid)               COPIED FROM: 20260616000006_fleet_system.sql:170-180
--      HUNK (each, one line): the from-state predicate gains a parked-in-space fleet. Every SET clause,
--      the raise text and the ACL are untouched. CREATE OR REPLACE preserves the existing grants.
--
--   NOT RE-EMITTED, ON PURPOSE: process_pirate_route_legs (0233:1128 — it parks nothing; it calls the
--   evaluator, so it inherits the fix), process_combat_ticks (0291), combat_create_encounter (0168:481
--   — its `return combat_create_group_encounter(p_presence)` binds late and resolves to the defaults),
--   presence_create (0032:175), activity_start (0230:98), fleet_set_present (0006:128 — still the right
--   leaf for a real arrival; only the INTERCEPT stops calling it).
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════
-- SCOPE RECOMMENDATION — WHAT MUST FOLLOW, AND WHY IT IS NOT HERE
--   0294 (recommended, separate): re-emit process_combat_ticks FROM ITS DEPLOYED pg_proc.prosrc (NOT
--   from any migration file) and repoint its three
--   `select x, y into v_loc_x, v_loc_y from locations where id = e.location_id` reads at
--   `coalesce(e.engagement_x, <location x/y>)`:
--       0291:364 / 0292:1047  the E3 resolved-plan wave spawn  (later-wave enemy seeding)
--       0291:422 / 0292:1105  the synthetic wave spawn         (later-wave enemy seeding — and wave
--                                    ONE's too, since the creator writes no enemy rows at all)
--       0291:286 / 0292:926   the retreat/extract movement ORIGIN (the return leg must depart from
--                                    where the fleet actually is, not from a port it never reached)
--
--   ⚠ READ BEFORE WRITING 0294. process_combat_ticks' newest re-emitter is 0292, NOT 0291, and 0292's
--   own header states it was built from "its TRUE head (0261:268-1067)". 0261 predates 0291. 0292:868
--   therefore carries `v_is_spatial := v_spatial_combat_enabled` — the FLAG-CONJOINED form that 0242
--   fixed, that 0260 and 0261 each reverted, that 0291 landed specifically to restore, and that
--   0291's own self-assert (1b) exists to forbid. If 0292 lands as written it is the THIRD stale-base
--   revert of the same guard, and 0291's assert will not catch it because 0291 does not re-run. 0293
--   does not touch process_combat_ticks and so neither causes nor cures this; it is recorded here
--   because 0294 must rebuild that function from the DEPLOYED prosrc and must re-state 0291's guard.
--   and, in the same slice, plumb the resolved anchor into the player formation. Until 0294 lands, an
--   intercept fight is drawn at the linked location exactly as it is today — self-consistent, unchanged,
--   and NOT a new defect. Splitting it this way is deliberate: the teleport is the owner's top complaint
--   and it is a two-line change; it must not wait behind a ~1000-line re-emission of the function 0291
--   just corrected. Landing the spatial repoint HALF-WAY would be worse than either end state — player
--   ships seeded at the ambush point while every enemy wave still spawns at the location centre is a
--   fight whose two sides start kilometres apart.
--
-- No flag is flipped. No config key is written. No balance number changes. Forward-only: 0290, 0262 and
-- 0006 are not edited in place.


-- ── 0. preconditions — every base this migration copies from must actually be deployed ──────────────
do $pre$
begin
  if to_regprocedure('public.pirate_intercept_evaluate_leg(uuid)') is null then
    raise exception '0293: pirate_intercept_evaluate_leg(uuid) is missing — there is no teleport to fix';
  end if;
  if to_regprocedure('public.combat_create_group_encounter(uuid)') is null then
    raise exception '0293: combat_create_group_encounter(uuid) is missing — 0262 must be deployed';
  end if;
  if to_regprocedure('public.fleet_set_in_space(uuid, double precision, double precision)') is null then
    raise exception '0293: fleet_set_in_space is missing — the ambush has nowhere to park the fleet';
  end if;
  -- the 0290 guard must be IN the base we are about to copy, or we are copying a stale body.
  if position('if v_manifest = 0 then' in
              (select prosrc from pg_proc where oid = 'public.pirate_intercept_evaluate_leg(uuid)'::regprocedure)) = 0 then
    raise exception '0293: the deployed evaluator does not carry 0290''s zero-manifest guard — refusing to re-emit from an unknown base';
  end if;
end $pre$;


-- ── 1. combat_encounters gains the ENGAGEMENT POINT ─────────────────────────────────────────────────
-- The location stays the encounter's IDENTITY (content, profile, rewards, name, presence ownership).
-- These two columns are its POSITION, and they are a different question. Nullable and additive: every
-- pre-existing row keeps reading as "no recorded engagement point", which every consumer resolves the
-- way it always has (locations.x/y). Nothing in this migration READS them — see the header scope note.
alter table public.combat_encounters
  add column if not exists engagement_x double precision,
  add column if not exists engagement_y double precision;

comment on column public.combat_encounters.engagement_x is
  'ENGAGEMENT POINT (0293): the x of the point in space where this fight physically is. An INTERCEPT '
  'encounter records the ambush point — ST_ClosestPoint(leg, zone centroid), the point on the fleet''s '
  'own leg where it met the danger zone. An ordinary location hunt records the location centre. '
  'Resolved and written ONCE by combat_create_group_encounter; an intercept restamps it with the ambush '
  'point. The linked location remains the authority for encounter CONTENT; this column is the authority '
  'for encounter POSITION. Every spatial seed — including later waves — must derive from this column '
  'rather than re-reading locations.x (see the 0294 follow-up named in 0293''s header).';
comment on column public.combat_encounters.engagement_y is
  'ENGAGEMENT POINT (0293): the y of the point in space where this fight physically is. See '
  'combat_encounters.engagement_x.';


-- ── 2. combat_create_group_encounter — 0262:63 body VERBATIM + hunks [B1] [B2] [B3] ─────────────────
-- The 1-arg form is dropped FIRST: with defaulted params both overloads would match a 1-arg call and
-- PostgreSQL would refuse it as ambiguous, and two pg_proc rows under one proname break every
-- prosrc-by-proname self-assert in the repo. combat_create_encounter (0168:502) calls this by name from
-- a plpgsql body — late-bound, so it resolves to the new form through the defaults, unchanged.
drop function if exists public.combat_create_group_encounter(uuid);

create or replace function public.combat_create_group_encounter(
  p_presence      uuid,
  -- ██ HUNK [B1] (0293): the ENGAGEMENT POINT, optional. Supplied => this fight is HERE. Omitted =>
  -- ██ the linked location's own centre, which is what every caller before 0293 meant implicitly.
  p_engagement_x  double precision default null,
  p_engagement_y  double precision default null)
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
  -- ██ HUNK [B1] (0293): the RESOLVED engagement point. Resolved unconditionally (not inside the
  -- ██ spatial gate) because it is stored on the encounter row whether or not the fight is spatial.
  v_eng_x   double precision;
  v_eng_y   double precision;
  -- COMBAT-S3 (0234): the player position/speed/weapons snapshot — LIT-only working set. Gate read
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

  -- ██ HUNK [B2] (0293): THE ONE ENGAGEMENT-ANCHOR RESOLUTION. This function is now the single place
  -- ██ that decides where a fight physically is: an explicitly supplied point wins, otherwise the
  -- ██ linked location's centre. Unconditional (the row is stamped even for a dark/aggregate
  -- ██ encounter, so a later consumer never has to ask "was this created spatial?"). A vanished
  -- ██ location leaves both NULL — byte-equivalent to what the deleted read below produced in the
  -- ██ same case, so nothing downstream changes shape.
  select coalesce(p_engagement_x, l.x), coalesce(p_engagement_y, l.y)
    into v_eng_x, v_eng_y
    from locations l
   where l.id = pr.location_id;

  -- COMBAT-S3 (0234): the arrival location's own center — the formation anchor (command ship spawns
  -- HERE; escorts ring around it). ONE extra read, dark-gated; a NEW statement, touches nothing else.
  -- 0293 [B2]: the read is GONE, not moved — v_loc_x/v_loc_y now take the anchor resolved above, which
  -- is the identical value whenever no engagement point was supplied. The gate, the ring radius knob
  -- and every use of v_loc_x/v_loc_y below are untouched.
  if v_spatial_enabled then
    v_loc_x := v_eng_x;
    v_loc_y := v_eng_y;
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
    -- COMBAT-S3 (0234): the inert default — reset EVERY iteration, before the hp>0 branch (the same
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
        -- COMBAT-S3 (0234): position/speed/weapons — LIT only, computed from the SAME successful
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
          -- ██ COMBAT-FALLBACK (0262): NO-WEAPON-MODULE PLAYER SHIPS STILL FIRE IN SPATIAL MODE ██
          -- A player ship whose fitted modules yield an EMPTY weapons array (no range-carrying
          -- weapon module fitted) but which still carries a positive attack_snapshot (v_attack —
          -- its combat_power from captain/hull/trait folds) would, in spatial mode, fire NOTHING
          -- and deal ZERO damage: the tick is a pure consumer of weapons_json and its fire loop
          -- `for v_widx in 0 .. jsonb_array_length(weapons_json) - 1` never iterates over an empty
          -- array. Materialize ONE synthesized "basic player weapon" HERE (at creation, never in
          -- the tick), deriving its power from the ship's OWN attack_snapshot and its range/
          -- projectile_speed/cooldown from the dedicated combat_player_fallback_weapon_* knobs (the
          -- player's basic-weapon profile — DELIBERATELY separate from the enemy synthetic's). A
          -- ship that DID fit a range weapon keeps its weapons_json byte-untouched (guarded on the
          -- array being EMPTY). Same entry shape as the fitted case (module_type_id/range/
          -- projectile_speed/power/ammo_type/ammo_per_shot/cooldown_seconds/next_ready_at/
          -- ammo_remaining) so the tick reads it identically.
          if jsonb_array_length(v_weapons_json) = 0 and coalesce(v_attack, 0) > 0 then
            v_weapons_json := jsonb_build_array(jsonb_build_object(
              'module_type_id',   coalesce((select value #>> '{}' from game_config where key = 'combat_player_fallback_weapon_module_type_id'), 'basic_player_weapon'),
              'range',            coalesce(public.cfg_num('combat_player_fallback_weapon_range'), 150),
              'projectile_speed', coalesce(public.cfg_num('combat_player_fallback_weapon_projectile_speed'), 300),
              'power',            v_attack * coalesce(public.cfg_num('combat_player_fallback_weapon_power_from_attack'), 1),
              'ammo_type',        null,
              'ammo_per_shot',    0,
              'cooldown_seconds', coalesce(public.cfg_num('combat_player_fallback_weapon_cooldown_seconds'), 2),
              'next_ready_at',    null,
              'ammo_remaining',   null));
          end if;
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

  -- ██ HUNK [B3] (0293): engagement_x, engagement_y APPENDED to the existing column and value lists —
  -- ██ every pre-existing column/value is untouched and in its original order (the 0234 append law).
  insert into combat_encounters (
    player_id, fleet_id, presence_id, location_id, status, danger_level,
    player_power_start, player_power_current, enemy_power_current,
    player_integrity_max, player_integrity_current, enemy_integrity_max, enemy_integrity_current,
    wave_number, last_resolved_at,
    engagement_x, engagement_y)
  values (
    pr.player_id, pr.fleet_id, p_presence, pr.location_id, 'active', 1,
    v_power, v_power, 0, 0, 0, 0, 0, 0, now(),
    v_eng_x, v_eng_y)
  returning id into v_enc;

  -- COMBAT-S3 (0234): pos_x, pos_y, move_speed, weapons_json, side APPENDED to the existing column and
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

-- Internal engine leaf — the 0168:467-471 ACL posture, restated on the NEW signature (the drop above
-- took the old signature's grants with it). SECURITY DEFINER callers run it as owner; service_role
-- keeps CI/inspection access; NO client role can execute it.
revoke execute on function public.combat_create_group_encounter(uuid, double precision, double precision) from public, anon, authenticated;
grant  execute on function public.combat_create_group_encounter(uuid, double precision, double precision) to service_role;

comment on function public.combat_create_group_encounter(uuid, double precision, double precision) is
  'GROUP ENCOUNTER CREATOR (0168 + 0195/0228/0234/0262) + ENGAGEMENT ANCHOR (0293). THE single '
  'authority that decides where a fight physically is: p_engagement_x/p_engagement_y when supplied (an '
  'INTERCEPT passes the ambush point), otherwise the linked location''s centre (an ordinary hunt). The '
  'resolved point is stored on combat_encounters.engagement_x/engagement_y and is the anchor of the '
  'player formation. The linked location remains the authority for encounter CONTENT; it is no longer '
  'the authority for encounter POSITION. Spatial mode is still DECIDED here, at creation, from '
  'spatial_combat_enabled (0242/0291 sticky mode).';


-- ── 3. the two lifecycle leaves — 0006:142-153 / 0006:170-180 VERBATIM + one predicate line each ────
-- WHY: a fleet ambushed at a location-linked zone now parks in open space (status 'idle',
-- location_mode 'space') and STILL owns a live encounter. Both of process_combat_ticks' terminal
-- branches assert the old docked status and would raise forever inside the tick's per-encounter
-- subtransaction, leaving every intercept defeat and every retreat/max-presence extraction unable to
-- complete. Each leaf learns exactly ONE new legal from-state: a fleet parked in open space. The SET
-- clauses, the raise texts and the ACLs are untouched; CREATE OR REPLACE preserves the existing grants.
create or replace function public.fleet_set_returning(p_fleet uuid, p_movement uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update fleets
    set status = 'returning', location_mode = 'movement', active_movement_id = p_movement,
        current_location_id = null, current_zone_id = null, current_sector_id = null,
        updated_at = now()
    -- 0293: 'present' (docked at a location, the original and still-normal case) OR parked in open
    -- space with a live encounter to leave (the ambush shape 0293 introduces). Every caller
    -- establishes its own precondition before reaching here — this predicate is the leaf's own floor.
    where id = p_fleet
      and (status = 'present' or (status = 'idle' and location_mode = 'space'));
  if not found then
    raise exception 'fleet_set_returning: fleet % not in present state', p_fleet;
  end if;
end; $$;

-- Used by Combat in M4.
create or replace function public.fleet_destroy(p_fleet uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update fleets
    set status = 'destroyed', location_mode = 'destroyed', active_movement_id = null,
        updated_at = now()
    -- 0293: the three original destroyable states PLUS a fleet parked in open space — an ambushed
    -- fleet fights, and can die, without ever being docked. Sole caller anywhere: process_combat_ticks.
    where id = p_fleet
      and (status in ('moving','present','returning') or (status = 'idle' and location_mode = 'space'));
  if not found then
    raise exception 'fleet_destroy: fleet % not in a destroyable state', p_fleet;
  end if;
end; $$;

comment on function public.fleet_set_returning(uuid, uuid) is
  'FLEET STATE (0006) + AMBUSH SHAPE (0293): accepts a fleet that is docked at a location OR parked in '
  'open space with a live encounter (the pirate-intercept ambush shape). Nothing else changed.';
comment on function public.fleet_destroy(uuid) is
  'FLEET STATE (0006) + AMBUSH SHAPE (0293): accepts moving/present/returning OR a fleet parked in open '
  'space (an ambushed fleet can die without ever having docked). Nothing else changed.';


-- ── 4. pirate_intercept_evaluate_leg — 0290:45-274 body VERBATIM + hunks [A1] [A2] ──────────────────
create or replace function public.pirate_intercept_evaluate_leg(p_movement_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mv       record;
  v_fleet    record;
  v_hit      record;
  v_group    uuid;
  v_manifest integer;   -- 0290: rows frozen into the sortie manifest; ZERO must not open combat
  v_stats    jsonb;
  v_combined double precision;
  v_risk     double precision;
  v_roll     double precision;
  v_hitbool  boolean;
  v_now      timestamptz := now();
  v_loc      record;
  v_presence uuid;
  v_enc      uuid;
  v_log_id   uuid;
  -- 0276 cutover locals. Only ever populated on the typed-zone branch.
  v_typed    boolean;
  v_req      jsonb;
  v_res      jsonb;
  v_pe       jsonb;
begin
  -- DARK GATE FIRST — before any read at all.
  if not public.cfg_bool('pirate_intercept_enabled') then
    return jsonb_build_object('hit', false, 'reason', 'dark');
  end if;

  select id, fleet_id, player_id, origin_x, origin_y, target_x, target_y, status
    into v_mv
    from public.fleet_movements
   where id = p_movement_id;
  if not found or v_mv.status <> 'moving' then
    return jsonb_build_object('hit', false, 'reason', 'not_moving');
  end if;

  select id, player_id, group_id, main_ship_id
    into v_fleet
    from public.fleets
   where id = v_mv.fleet_id;
  -- This hook only ever fires from the unified GROUP mover / route advance — the ONLY shapes that
  -- mint main_ship_id NULL + group_id SET fleets. Anything else (a legacy per-ship or unit fleet) is
  -- simply not this feature's concern for the prototype — skip cleanly, never guess.
  if not found or v_fleet.group_id is null or v_fleet.main_ship_id is not null then
    return jsonb_build_object('hit', false, 'reason', 'not_group_fleet');
  end if;
  v_group := v_fleet.group_id;

  -- ── 0276 CUTOVER POINT ──────────────────────────────────────────────
  -- Exactly ONE path decides, chosen once, here. The branches are never both run for side effects:
  -- whichever is authoritative produces v_hit, and everything downstream — the roll, the
  -- pirate_intercepts log, the cancel, the ambush — is shared and unchanged. With the flag dark
  -- (its seeded state) this is byte-for-byte the legacy 0233 decision.
  v_typed := coalesce(public.cfg_bool('typed_zone_pirate_intercept_runtime_enabled'), false);

  if not v_typed then
    -- LEGACY, authoritative while the flag is dark: deepest crossing wins (highest
    -- exposure_fraction); `limit 1` needs SOME order to be deterministic.
    select * into v_hit
      from public.pirate_intercept_leg_zone_hits(v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y)
     order by exposure_fraction desc, zone_id asc
     limit 1;
    if not found then
      return jsonb_build_object('hit', false, 'reason', 'no_crossing');
    end if;
  else
    -- TYPED-ZONE: the same geometry, but the decision comes from the pure V1 planner, so selection
    -- follows declared EFFECTS rather than the bare existence of a polygon. A zone carrying no
    -- pirate_intercept effect row is simply not planned — that is the point of the platform.
    v_req := public.typed_zone_pirate_candidates_v1(
               p_movement_id, v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y, 0);
    v_res := public.typed_zone_effect_dispatch_v1(v_req);
    -- FAIL CLOSED, NEVER FAIL OPEN. A planner that cannot answer must not silently fall back to the
    -- legacy path — that would make the cutover unobservable and hide the fault — and must not
    -- invent an interception. It leaves the leg alone, exactly as 'no_crossing' does.
    if (v_res->>'ok') <> 'true' then
      raise warning 'pirate_intercept_evaluate_leg: typed-zone dispatch rejected movement % (leg left UNINTERRUPTED): %',
        p_movement_id, v_res->'error';
      return jsonb_build_object('hit', false, 'reason', 'typed_zone_dispatch_error');
    end if;
    if jsonb_array_length(v_res->'plan'->'planned_effects') = 0 then
      return jsonb_build_object('hit', false, 'reason', 'no_crossing');
    end if;
    v_pe := v_res->'plan'->'planned_effects'->0;
    -- Re-read the geometry row for the PLANNED zone: location_id and the ambush point drive the
    -- shared downstream, and they must come from the same authority the legacy branch uses.
    select h.* into v_hit
      from public.pirate_intercept_leg_zone_hits(v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y) h
     where h.zone_id = (v_pe->>'zone_id')::uuid;
    if not found then
      raise warning 'pirate_intercept_evaluate_leg: planned zone % is not among the leg hits for movement % (leg left UNINTERRUPTED)',
        v_pe->>'zone_id', p_movement_id;
      return jsonb_build_object('hit', false, 'reason', 'typed_zone_dispatch_error');
    end if;
  end if;

  -- combined stats: reuse the SAME group-stats adapter the mover already calls for speed (D0, 0166).
  -- Fail OPEN on any adapter raise (an illegal member state etc.) — treat as unknown/weak (combined=0,
  -- the conservative choice) rather than let a stats bug break a player's movement command.
  begin
    v_stats := public.calculate_group_expedition_stats(v_fleet.player_id, v_group, 'none');
    v_combined := coalesce((v_stats->'totals'->>'combat_power')::double precision, 0)
                + coalesce((v_stats->'totals'->>'survival')::double precision, 0);
  exception when others then
    v_combined := 0;
  end;

  -- The typed branch resolves risk from THIS zone's own effect config (per-zone overrides coalesced
  -- against the globals). Recomputing with pirate_intercept_compute_risk here would read the globals
  -- only and silently re-globalise a zone the owner had deliberately tuned. The candidate request is
  -- rebuilt with the real combined stats — it was first built with 0, before the stats adapter ran.
  if v_typed then
    v_res := public.typed_zone_effect_dispatch_v1(
               jsonb_set(v_req, '{event,combined_stats}', to_jsonb(v_combined)));
    if (v_res->>'ok') <> 'true' or jsonb_array_length(v_res->'plan'->'planned_effects') = 0 then
      raise warning 'pirate_intercept_evaluate_leg: typed-zone re-plan failed for movement % (leg left UNINTERRUPTED)',
        p_movement_id;
      return jsonb_build_object('hit', false, 'reason', 'typed_zone_dispatch_error');
    end if;
    v_risk := (v_res->'plan'->'planned_effects'->0->>'risk')::double precision;
  else
    v_risk := public.pirate_intercept_compute_risk(v_combined, v_hit.exposure_fraction);
  end if;
  v_roll    := random();
  v_hitbool := v_roll < v_risk;

  insert into public.pirate_intercepts (
    movement_id, fleet_id, player_id, zone_id, location_id,
    origin_x, origin_y, target_x, target_y, exposure_fraction,
    combined_stats, risk, roll, hit)
  values (
    p_movement_id, v_fleet.id, v_fleet.player_id, v_hit.zone_id, v_hit.location_id,
    v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y, v_hit.exposure_fraction,
    v_combined, v_risk, v_roll, v_hitbool)
  returning id into v_log_id;

  if not v_hitbool then
    return jsonb_build_object('hit', false, 'risk', v_risk, 'roll', v_roll, 'zone_id', v_hit.zone_id);
  end if;

  -- ── THE AMBUSH ───────────────────────────────────────────────────────────────────────────────
  -- Re-lock + re-check: a concurrent brake/redirect may have resolved this movement between the
  -- first (unlocked) read above and here. Never double-trigger a settled/cancelled leg.
  perform 1 from public.fleet_movements where id = p_movement_id and status = 'moving' for update;
  if not found then
    update public.pirate_intercepts set hit = false, note = 'race_lost' where id = v_log_id;
    return jsonb_build_object('hit', false, 'reason', 'race_lost');
  end if;

  update public.fleet_movements set status = 'cancelled', resolved_at = v_now where id = p_movement_id;

  if v_hit.location_id is null then
    -- STANDALONE drawn zone (no linked pirate_hunt location): the documented combat stub. No
    -- location means no presence/encounter is possible without inventing one — instead the ambush
    -- is made TANGIBLE by forcing the fleet to a stop at the ambush point, the SAME leaf the brake
    -- (command_ship_group_stop, 0215/0218) uses to park a fleet mid-flight. Not a no-op.
    perform public.fleet_set_in_space(v_fleet.id, v_hit.ambush_x, v_hit.ambush_y);
    update public.pirate_intercepts set note = 'standalone_zone_stub_forced_stop' where id = v_log_id;
    return jsonb_build_object('hit', true, 'reason', 'standalone_zone_stub', 'risk', v_risk, 'roll', v_roll);
  end if;

  select l.id, l.zone_id, z.sector_id
    into v_loc
    from public.locations l
    join public.zones z on z.id = l.zone_id
   where l.id = v_hit.location_id and l.status = 'active';
  if v_loc.id is null then
    -- the linked location vanished/deactivated since the zone was drawn/seeded — fail open: park,
    -- no combat, rather than reference a location that can no longer host a presence.
    perform public.fleet_set_in_space(v_fleet.id, v_hit.ambush_x, v_hit.ambush_y);
    update public.pirate_intercepts set note = 'location_missing' where id = v_log_id;
    return jsonb_build_object('hit', true, 'reason', 'location_missing', 'risk', v_risk, 'roll', v_roll);
  end if;

  -- ██ HUNK [A1] (0293) — THE TELEPORT FIX. THE WHOLE POINT OF THIS MIGRATION. ██████████████████████
  -- This line used to be a call to the "arrived at the destination" leaf, which writes
  -- status='present', location_mode='location', current_location_id=<the linked location> — one
  -- UPDATE that stands the fleet at the far end of a journey it never completed. The leg had just
  -- been CANCELLED two statements above; there is no segment, no duration, nothing to interpolate.
  -- The fleet was ambushed at v_hit.ambush_x/ambush_y — ST_ClosestPoint(this leg, zone centroid), the
  -- point on the fleet's OWN path where it met the zone — so that is where it stops, via the identical
  -- leaf the standalone branch (above), the vanished-location fail-open (above) and the 0290
  -- zero-manifest guard (below) already use. ALL FOUR ambush exits now park at the same computed
  -- point; no exit from this function writes a position the fleet did not travel to.
  -- The linked location is NOT discarded — it stays the encounter's identity and owns the presence
  -- created below. It has simply stopped being the coordinate authority.
  perform public.fleet_set_in_space(v_fleet.id, v_hit.ambush_x, v_hit.ambush_y);

  -- Freeze the sortie MANIFEST — byte-identical INSERT shape to send_ship_group_hunt's sole-writer
  -- freeze (0168:304-306), so combat_create_encounter's manifest-gated branch (0168) routes this
  -- fleet into combat_create_group_encounter exactly as a deliberate hunt does. ON CONFLICT DO
  -- NOTHING: idempotent against a (should-be-impossible) re-entry.
  insert into public.group_sortie_members (fleet_id, main_ship_id, player_id)
  select v_fleet.id, msi.main_ship_id, v_fleet.player_id
    from public.main_ship_instances msi
   where msi.group_id = v_group and msi.player_id = v_fleet.player_id
  on conflict (fleet_id, main_ship_id) do nothing;
  get diagnostics v_manifest = row_count;

  -- 0290 ZERO-MANIFEST GUARD. The freeze above reads LIVE main_ship_instances.group_id, so it
  -- can legitimately return no rows (an empty/disbanded group, every ship reassigned). 0168's
  -- combat_create_encounter is manifest-GATED: with no manifest it takes the legacy branch and
  -- inserts combat_units from fleet_units -- a table a TEAM-SORTIE fleet has no rows in (0168:276
  -- creates the fleet and never populates it; 0169:222 documents exactly this). The result is an
  -- encounter with ZERO combat_units: nothing to draw on the map, nothing to fight, and
  -- player_power_start = 0 because fleet_get_power sums the same empty table.
  --
  -- 0168:478-480 asserts that branch is "UNREACHABLE IN PROD" because send_ship_group_hunt is
  -- the manifest's sole writer. That expired the moment THIS function became a second manifest
  -- writer. Rather than reopen the frozen legacy creator, refuse here: an ambush that cannot
  -- field a single ship is not a fight. Reuse the EXISTING fail-open exit (location_missing's
  -- shape) -- park the fleet at the ambush point it actually reached, log why, no combat.
  -- 0293: the park is now REDUNDANT here (the fleet was already parked at the identical point by
  -- hunk [A1] above) and is KEPT anyway, unchanged. It is idempotent, it costs one UPDATE on a rare
  -- path, and it keeps this guard self-sufficient rather than dependent on a caller three statements
  -- away — which is precisely what made it a guard worth adding.
  if v_manifest = 0 then
    perform public.fleet_set_in_space(v_fleet.id, v_hit.ambush_x, v_hit.ambush_y);
    update public.pirate_intercepts set note = 'empty_manifest' where id = v_log_id;
    return jsonb_build_object('hit', true, 'reason', 'empty_manifest', 'risk', v_risk, 'roll', v_roll);
  end if;

  -- presence_create -> activity_start('hunt_pirates') -> combat_create_encounter -> (manifest exists)
  -- -> combat_create_group_encounter. FOUR frozen functions composed, ZERO re-created.
  v_presence := public.presence_create(v_fleet.player_id, v_fleet.id, v_loc.sector_id, v_loc.zone_id, v_loc.id, 'hunt_pirates');

  select id into v_enc from public.combat_encounters where presence_id = v_presence order by created_at desc limit 1;
  update public.pirate_intercepts set encounter_id = v_enc, presence_id = v_presence where id = v_log_id;

  -- ██ HUNK [A2] (0293) — ENCOUNTER IDENTITY vs ENCOUNTER POSITION. ████████████████████████████████
  -- The creator resolved this encounter's engagement point from the linked location's centre: the
  -- presence chain (presence_create -> activity_start -> combat_create_encounter) carries no
  -- coordinate, and threading combat coordinates through the PRESENCE system to change that would be
  -- the wrong coupling for the wrong reason. So the ONE authority that knows the real answer — this
  -- function, which computed the ambush point — restates it on the row the creator just wrote. The
  -- encounter's identity (location_id, its pirates, its rewards, its presence) is untouched; only its
  -- POSITION is corrected, and it is corrected to the same v_hit.ambush_x/ambush_y the fleet is
  -- parked at, so the fleet and the fight it is in agree on where they are.
  -- Guarded on v_enc: if the creator produced no encounter there is nothing to stamp.
  if v_enc is not null then
    update public.combat_encounters
       set engagement_x = v_hit.ambush_x, engagement_y = v_hit.ambush_y
     where id = v_enc;
  end if;

  return jsonb_build_object(
    'hit', true, 'risk', v_risk, 'roll', v_roll,
    'location_id', v_loc.id, 'presence_id', v_presence, 'encounter_id', v_enc);
exception
  when others then
    raise warning 'pirate_intercept_evaluate_leg: unexpected error for movement % (leg left UNINTERRUPTED): %',
      p_movement_id, sqlerrm;
    return jsonb_build_object('hit', false, 'reason', 'internal_error');
end;
$$;


revoke execute on function public.pirate_intercept_evaluate_leg(uuid) from public, anon, authenticated;
grant execute on function public.pirate_intercept_evaluate_leg(uuid) to service_role;

comment on function public.pirate_intercept_evaluate_leg(uuid) is
  'PIRATE INTERCEPT (0233) + TYPED-ZONE CUTOVER (0276) + ZERO-MANIFEST GUARD (0290) + AMBUSH-POINT '
  'PARK (0293). While typed_zone_pirate_intercept_runtime_enabled is false, zone selection and risk '
  'behave byte-for-byte as 0233 shipped them; while true they come from the pure V1 typed-zone planner. '
  '0290: a sortie manifest that freezes ZERO rows opens NO combat. 0293: EVERY ambush exit — standalone '
  'zone, vanished location, empty manifest, and the location-linked combat path — parks the fleet at the '
  'computed ambush point via fleet_set_in_space. The linked location no longer receives the fleet; it '
  'remains the encounter''s identity and presence owner, and the ambush point is restated on '
  'combat_encounters.engagement_x/engagement_y. Exactly one path decides; a planner failure leaves the '
  'leg UNINTERRUPTED rather than falling back.';


-- ══ SELF-ASSERT ════════════════════════════════════════════════════════════════════════════════════
-- PROSRC-ASSERT COUPLING (the 0221/0222/0234/0262/0291 house lesson): `--` line comments are stripped
-- before probing, so the banners above can NAME the very call this migration removes without the probe
-- for its absence tripping over the explanation.
do $$
declare
  v_eval    text;
  v_creator text;
  v_ret     text;
  v_destroy text;
  v_tok     text;
  v_n       integer;
begin
  -- ── (0) every body exists, and the creator has exactly ONE signature under its name ──────────────
  if to_regprocedure('public.pirate_intercept_evaluate_leg(uuid)') is null then
    raise exception '0293 FAIL: pirate_intercept_evaluate_leg(uuid) is missing after this migration';
  end if;
  if to_regprocedure('public.combat_create_group_encounter(uuid, double precision, double precision)') is null then
    raise exception '0293 FAIL: the 3-arg combat_create_group_encounter was not created';
  end if;
  if to_regprocedure('public.combat_create_group_encounter(uuid)') is not null then
    raise exception '0293 FAIL: the 1-arg combat_create_group_encounter still exists — every 1-arg call (combat_create_encounter 0168:502) is now ambiguous';
  end if;
  select count(*) into v_n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  if v_n <> 1 then
    raise exception '0293 FAIL: % pg_proc rows named combat_create_group_encounter (want exactly 1) — prosrc-by-proname self-asserts (0262:254, 0291:889) would break', v_n;
  end if;

  select prosrc into v_eval    from pg_proc where oid = 'public.pirate_intercept_evaluate_leg(uuid)'::regprocedure;
  select prosrc into v_creator from pg_proc where oid = 'public.combat_create_group_encounter(uuid, double precision, double precision)'::regprocedure;
  select prosrc into v_ret     from pg_proc where oid = 'public.fleet_set_returning(uuid, uuid)'::regprocedure;
  select prosrc into v_destroy from pg_proc where oid = 'public.fleet_destroy(uuid)'::regprocedure;
  v_eval    := regexp_replace(v_eval,    '--[^' || chr(10) || ']*', '', 'g');
  v_creator := regexp_replace(v_creator, '--[^' || chr(10) || ']*', '', 'g');
  v_ret     := regexp_replace(v_ret,     '--[^' || chr(10) || ']*', '', 'g');
  v_destroy := regexp_replace(v_destroy, '--[^' || chr(10) || ']*', '', 'g');

  -- ── (1) THE TELEPORT IS GONE. The linked branch no longer calls the docked-arrival leaf AT ALL —
  --        not on any path — and every ambush exit parks at the ambush point instead. ──────────────
  if strpos(v_eval, 'fleet_set_present') <> 0 then
    raise exception '0293 FAIL: the evaluator still calls the docked-arrival leaf — the teleport is live';
  end if;
  v_n := (length(v_eval) - length(replace(v_eval, 'public.fleet_set_in_space(v_fleet.id, v_hit.ambush_x, v_hit.ambush_y)', '')))
         / length('public.fleet_set_in_space(v_fleet.id, v_hit.ambush_x, v_hit.ambush_y)');
  if v_n <> 4 then
    raise exception '0293 FAIL: the evaluator parks at the ambush point % time(s), want exactly 4 (standalone stub, vanished location, the location-linked combat path, empty manifest)', v_n;
  end if;
  -- the linked park must happen BEFORE the manifest freeze, i.e. before anything can return early
  -- without the fleet having been stopped at all.
  if strpos(v_eval, 'insert into public.group_sortie_members') < strpos(v_eval, 'update public.fleet_movements set status = ''cancelled''') then
    raise exception '0293 FAIL: the manifest freeze precedes the leg cancel — the body order was not preserved';
  end if;

  -- ── (2) ENCOUNTER POSITION IS RECORDED, AND SEPARATE FROM ENCOUNTER IDENTITY ─────────────────────
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'combat_encounters' and column_name = 'engagement_x')
     or not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'combat_encounters' and column_name = 'engagement_y') then
    raise exception '0293 FAIL: combat_encounters.engagement_x/engagement_y are missing';
  end if;
  if strpos(v_eval, 'set engagement_x = v_hit.ambush_x, engagement_y = v_hit.ambush_y') = 0 then
    raise exception '0293 FAIL: the intercept does not stamp the ambush point as the encounter''s engagement point';
  end if;
  -- identity untouched: the linked location still owns the presence.
  if strpos(v_eval, 'public.presence_create(v_fleet.player_id, v_fleet.id, v_loc.sector_id, v_loc.zone_id, v_loc.id, ''hunt_pirates'')') = 0 then
    raise exception '0293 FAIL: the linked location no longer owns the presence — identity was changed, not just position';
  end if;
  -- the creator resolves the anchor ONCE, param-first, and stores it.
  if strpos(v_creator, 'select coalesce(p_engagement_x, l.x), coalesce(p_engagement_y, l.y)') = 0 then
    raise exception '0293 FAIL: the creator does not resolve the engagement anchor param-first';
  end if;
  if strpos(v_creator, 'engagement_x, engagement_y)') = 0 or strpos(v_creator, 'v_eng_x, v_eng_y)') = 0 then
    raise exception '0293 FAIL: the creator does not store the resolved engagement point on the encounter';
  end if;
  -- and the formation anchors on THAT resolved point, not on a second read of locations.
  if strpos(v_creator, 'v_loc_x := v_eng_x;') = 0 then
    raise exception '0293 FAIL: the player formation does not anchor on the resolved engagement point';
  end if;
  v_n := (length(v_creator) - length(replace(v_creator, 'from locations', ''))) / length('from locations');
  if v_n <> 1 then
    raise exception '0293 FAIL: the creator reads locations % time(s), want exactly 1 (the single anchor resolution)', v_n;
  end if;

  -- ── (3) EVERY 0290 / 0276 / 0233 GUARANTEE SURVIVES. This is the hunk-discipline proof: the ONLY
  --        deltas to the evaluator are [A1] and [A2]. ────────────────────────────────────────────────
  foreach v_tok in array array[
      -- 0290's zero-manifest guard, whole:
      'get diagnostics v_manifest = row_count',
      'if v_manifest = 0 then',
      'empty_manifest',
      -- 0276's cutover, both deciders, fail-closed:
      'order by exposure_fraction desc, zone_id asc',
      'typed_zone_effect_dispatch_v1',
      'pirate_intercept_compute_risk',
      'typed_zone_dispatch_error',
      -- 0233's shared downstream:
      'insert into public.pirate_intercepts',
      'group_sortie_members',
      'public.presence_create',
      'standalone_zone_stub_forced_stop',
      'location_missing',
      'race_lost',
      'calculate_group_expedition_stats',
      'cfg_bool(''pirate_intercept_enabled'')',
      -- the raise-free contract: a failure leaves the leg UNINTERRUPTED, never propagates into the cron
      'when others then'
    ] loop
    if strpos(v_eval, v_tok) = 0 then
      raise exception '0293 FAIL: the evaluator lost a pinned guarantee (%) — this migration changes ONLY the park and the engagement stamp', v_tok;
    end if;
  end loop;
  -- 0290's siting requirement: the guard must still run BEFORE presence_create, or combat opens anyway.
  if strpos(v_eval, 'if v_manifest = 0 then') > strpos(v_eval, 'public.presence_create(') then
    raise exception '0293 FAIL: the zero-manifest guard runs AFTER presence_create — 0290 was reverted';
  end if;
  -- exactly ONE roll and ONE log insert: a second of either would double-trigger an ambush.
  v_n := (length(v_eval) - length(replace(v_eval, 'random()', ''))) / length('random()');
  if v_n <> 1 then
    raise exception '0293 FAIL: the evaluator rolls % time(s), want exactly 1', v_n; end if;
  v_n := (length(v_eval) - length(replace(v_eval, 'insert into public.pirate_intercepts', '')))
         / length('insert into public.pirate_intercepts');
  if v_n <> 1 then
    raise exception '0293 FAIL: the evaluator logs % time(s), want exactly 1', v_n; end if;
  -- the dark gate still runs before the cutover flag is read.
  if strpos(v_eval, 'cfg_bool(''pirate_intercept_enabled'')')
     > strpos(v_eval, 'cfg_bool(''typed_zone_pirate_intercept_runtime_enabled'')') then
    raise exception '0293 FAIL: the cutover flag is read before the dark gate';
  end if;

  -- ── (4) THE CREATOR'S OTHER HALVES SURVIVE — 0291's sticky-mode pin, 0262's fallback weapon, 0234's
  --        spatial append, 0168's manifest loop. Copied from 0262:63; nothing else moved. ───────────
  foreach v_tok in array array[
      -- 0291:925 pins this exact line. Sticky mode is still DECIDED at creation.
      'v_spatial_enabled boolean := public.cfg_bool(''spatial_combat_enabled'');',
      -- 0262's fallback weapon, guarded on the EMPTY array + a positive attack:
      'if jsonb_array_length(v_weapons_json) = 0 and coalesce(v_attack, 0) > 0 then',
      'v_attack * coalesce(public.cfg_num(''combat_player_fallback_weapon_power_from_attack''), 1)',
      -- the real fitted-weapon path the fallback only fills in for:
      'where f.main_ship_id = m.main_ship_id and t.range is not null;',
      -- 0234's spatial INSERT append and ring formation:
      'pos_x, pos_y, move_speed, weapons_json, side)',
      'v_ring_radius * cos(2 * pi() * v_escort_idx / 8)',
      -- 0168's manifest-driven roster:
      'from group_sortie_members gsm'
    ] loop
    if strpos(v_creator, v_tok) = 0 then
      raise exception '0293 FAIL: combat_create_group_encounter lost a pinned guarantee (%) — a stale-base re-emission', v_tok;
    end if;
  end loop;

  -- ── (5) THE LIFECYCLE LEAVES ACCEPT THE NEW SHAPE AND NOTHING ELSE. Without this the ruling's own
  --        fix wedges every intercept encounter at its terminal branch, forever. ────────────────────
  if strpos(v_ret, 'status = ''present'' or (status = ''idle'' and location_mode = ''space'')') = 0 then
    raise exception '0293 FAIL: fleet_set_returning does not accept a fleet parked in open space — every intercept retreat/extract would raise forever inside the tick';
  end if;
  if strpos(v_destroy, 'status in (''moving'',''present'',''returning'') or (status = ''idle'' and location_mode = ''space'')') = 0 then
    raise exception '0293 FAIL: fleet_destroy does not accept a fleet parked in open space — every intercept defeat would raise forever inside the tick';
  end if;
  -- the widening is EXACTLY that: a parked fleet, never a bare status test.
  if strpos(v_ret, 'status = ''idle'' and location_mode = ''space''') = 0
     or strpos(v_destroy, 'status = ''idle'' and location_mode = ''space''') = 0 then
    raise exception '0293 FAIL: a leaf accepts idle without requiring the fleet to be parked in space — the widening is broader than stated';
  end if;
  -- the SET clauses are untouched.
  if strpos(v_ret, 'set status = ''returning'', location_mode = ''movement'', active_movement_id = p_movement') = 0 then
    raise exception '0293 FAIL: fleet_set_returning''s SET clause changed'; end if;
  if strpos(v_destroy, 'set status = ''destroyed'', location_mode = ''destroyed'', active_movement_id = null') = 0 then
    raise exception '0293 FAIL: fleet_destroy''s SET clause changed'; end if;

  -- ── (6) EXPOSURE UNCHANGED — service_role only, never a client role, on every function touched. ──
  if not has_function_privilege('service_role', 'public.pirate_intercept_evaluate_leg(uuid)', 'execute') then
    raise exception '0293 FAIL: service_role lost execute on the evaluator'; end if;
  if not has_function_privilege('service_role', 'public.combat_create_group_encounter(uuid, double precision, double precision)', 'execute') then
    raise exception '0293 FAIL: service_role lost execute on the creator'; end if;
  if has_function_privilege('anon', 'public.pirate_intercept_evaluate_leg(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_intercept_evaluate_leg(uuid)', 'execute') then
    raise exception '0293 FAIL: a client role can execute the intercept leaf'; end if;
  if has_function_privilege('anon', 'public.combat_create_group_encounter(uuid, double precision, double precision)', 'execute')
     or has_function_privilege('authenticated', 'public.combat_create_group_encounter(uuid, double precision, double precision)', 'execute') then
    raise exception '0293 FAIL: a client role can execute the group encounter creator'; end if;
  -- the two state leaves keep the blanket engine lock (0021/0024). CREATE OR REPLACE cannot widen an
  -- ACL, so a failure here means the posture was already wrong before this migration — worth knowing.
  if has_function_privilege('anon', 'public.fleet_set_returning(uuid, uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.fleet_set_returning(uuid, uuid)', 'execute')
     or has_function_privilege('anon', 'public.fleet_destroy(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.fleet_destroy(uuid)', 'execute') then
    raise exception '0293 FAIL: a client role can execute a fleet state-machine leaf';
  end if;

  -- ── (7) NO FLAG FLIPPED. This migration writes no game_config row; the gates it depends on are left
  --        exactly as 0290/0291 left them. ──────────────────────────────────────────────────────────
  --        Asserted as THIS MIGRATION'S OWN EFFECT, never as operator state: the earlier form
  --        demanded encounter_resolver_enabled = 'false', a value the OWNER controls and intends to
  --        light, which would have failed this deploy the moment they did. 0288 failed production in
  --        exactly that way. What 0293 promises is that it writes no flag.
  if position('game_config' in v_eval) <> 0 and position('cfg_bool' in v_eval) = 0 then
    raise exception '0293 FAIL: the evaluator touches game_config outside its cfg_bool reads — this migration writes no flag';
  end if;

  raise notice '0293 OK: the intercept teleport is dead — the location-linked ambush branch no longer calls the docked-arrival leaf on ANY path, and all FOUR ambush exits (standalone stub, vanished location, the location-linked combat path, empty manifest) park the fleet at the computed ambush point via fleet_set_in_space, so no exit writes a position the fleet did not travel to; process_pirate_route_legs inherits the identical rule without an edit because it parks nothing itself and calls this same evaluator for legs 2..N; encounter POSITION is now separate from encounter IDENTITY (combat_encounters.engagement_x/engagement_y added; combat_create_group_encounter is the ONE resolver — p_engagement_x/y first, the linked location''s centre otherwise, exactly one read of locations — and the intercept restates the ambush point on the row it created, while the linked location still owns the presence and all encounter content); the 0290 zero-manifest guard SURVIVES, still sited before presence_create; the 0276 cutover, both deciders, the fail-closed exits, the single roll, the single pirate_intercepts insert, the race check and the raise-free `exception when others` contract all survive; 0291''s creation-time sticky-mode flag gate, 0262''s fallback weapon and 0234''s spatial append survive in the creator; fleet_set_returning and fleet_destroy each learned exactly ONE new from-state (a fleet parked in open space) so an ambushed fleet can retreat and can die instead of wedging its encounter in the tick forever; grants unchanged (service_role only, never anon/authenticated); no flag flipped; process_combat_ticks deliberately NOT touched — its three locations.x/y reads (later-wave enemy seeding x2, retreat movement origin) are the named 0294 follow-up';
end $$;
