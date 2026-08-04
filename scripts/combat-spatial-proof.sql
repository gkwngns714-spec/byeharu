-- COMBAT-SPATIAL — disposable proof for the S3 spatial-combat slice (migration 0234): per-ship
-- positions, the CLOSE-vs-KITE-vs-HOLD movement/targeting AI, synthetic pirate spawn, per-weapon fire
-- events, and damage — driven through the REAL chain (send_ship_group_hunt → movement_settle_arrival
-- → activity_start → combat_create_encounter's D2 branch → combat_create_group_encounter →
-- process_combat_ticks), never a hand-rolled combat_units/group_sortie_members write.
--
-- This is the live-DB scenario proof the migration's own header flagged as owed: the migration
-- self-asserts prosrc/structural parity (no fixture harness exists inside a migration — the
-- auth.users FK chain), but NEVER executes the spatial tick end to end. This script does.
--
-- ══ 0336 REPOINT — THE WAVE NO LONGER STANDS ON THE ANCHOR, SO THIS SCENARIO IS REBUILT ══════════
-- Every revision of this file up to 0335 was written on ONE fact: "the pirate spawns on top of the
-- command ship". Both wave-spawn arms inserted every unit at the engagement anchor, which is exactly
-- where the lead hull stands, so the command ship opened every fight at distance 0 — in range of the
-- pirate, with the pirate in range of it — i.e. in HOLD, byte-identically motionless, firing on tick
-- 1. That world is gone. 0336 lays the wave out through combat_formation_point at
--     radius = spatial_formation_ring_radius + THAT WAVE'S OWN WEAPON RANGE + 1
--     phase  = 0.5 slots (half a slot off the player ring, so an enemy never lands on an escort)
--     slot   = a running counter across the whole wave
-- and the player formation is untouched (lead ON the anchor, escorts on the ring at phase 0).
--
-- THE ONE CONSEQUENCE THAT REWRITES THIS FILE: every player hull sits at radius <= ring from the
-- anchor, and the wave sits at ring + its own range + 1, so by the triangle inequality the distance
-- from ANY player ship to ANY enemy is AT LEAST (enemy range + 1) — strictly OUTSIDE the enemy's own
-- reach, by construction, at every difficulty. HOLD requires "I can hit them AND they can hit me".
-- Therefore **NO PLAYER SHIP CAN BE IN HOLD ON THE OPENING TICK, AT ANY KNOB SETTING**, and the lead
-- — alone on the anchor while the escorts stand on the ring — is now the FURTHEST player hull from
-- the wave rather than the nearest. There is no ring radius that rescues the old assertion; asking
-- for one is asking 0336 to be reverted. The property is repointed, not weakened: HOLD is proven
-- where it now exists — on the hull that has CLOSED to contact — and the arm of every witness is
-- DERIVED from the same three inputs the mover reads, then asserted, so a retune that silently moves
-- a witness into another arm fails loudly here instead of passing.
--
-- ── SCENARIO (engineered geometry; every distance this scenario stakes a property on is DERIVED
--    from a knob this block OWNS in-txn plus the units' own frozen weapons_json) ──────────────────
-- One team of 3 ships, all bare starter frigates:
--   • s_cmd  — the elected LEAD (armed: one catalog autocannon_battery). Stands ON the engagement
--              anchor, so its distance to the wave is exactly  R + er + 1.
--   • s_arm  — an ARMED escort (one catalog autocannon_battery), on the escort ring at radius R.
--   • s_bare — an escort with NO fitted weapon, which since 0262 carries the SYNTHESIZED fallback
--              weapon, whose range this harness OWNS.
-- The two escorts take ring slots 0 and 1 (angles 0 and pi/4) in main_ship_id order — which of them
-- takes which slot is a uuid coin-flip, and it CANNOT matter: the wave stands on the bearing to the zone's own city (0338), i.e.
-- half a slot between them, so slots 0 and 1 are mirror images about it and BOTH escorts are the
-- same chord away from the wave. That symmetry is why this scenario uses exactly two escorts.
--
-- OWNED KNOBS AND WHAT EACH ONE BUYS (R = ring, er = the wave's own weapon range):
--   spatial_formation_ring_radius        4   R
--   enemy_synthetic_range_base           2   er (per_difficulty pinned 0, so er is exactly this)
--   enemy_synthetic_speed_base           0   THE WAVE DOES NOT MOVE — see below
--   combat_player_fallback_weapon_range  1   s_bare's own reach, strictly under er
--   combat_player_speed_scale            1   the player step per tick (1.0 * the bare hull's speed)
-- The resulting geometry, all of it derived and asserted below rather than trusted:
--   lead   <-> wave =  R + er + 1                      = 7.000
--   escort <-> wave = sqrt(R^2 + Re^2 - 2*R*Re*cos(pi/8)) = 3.642   (Re = R + er + 1)
--   catalog autocannon range (read from module_types, never assumed) = 5
-- so on TICK 1:
--   • s_cmd   dist 7.000 > its own 5                    → CLOSE  (advances)
--   • s_arm   dist 3.642 <= its own 5, and > er 2       → KITE   (retreats, never past its own edge)
--   • s_bare  dist 3.642 > its own fallback 1           → CLOSE  (advances), cannot fire
--   • the wave, at 3.642 from its nearest target, is outside its own 2 → it does NOT fire tick 1
-- and then s_bare keeps closing, one player step per tick, until its distance falls inside its own
-- fallback range — which, because that range is <= er, is also inside the WAVE's range. That is the
-- state HOLD is defined by, and the hull sits byte-identically still in it. The number of closing
-- ticks is not typed into this harness: it is run out against the MEASURED gap and the MEASURED
-- frozen move_speed, and each closing tick is guarded to be genuinely in CLOSE before it runs.
--
-- WHY THE WAVE'S SPEED IS OWNED AT ZERO, AND WHY THAT COSTS THIS BLOCK NOTHING: a moving wave walks
-- toward whichever escort the id tiebreak hands it, and since the two escorts are equidistant that
-- choice is float noise — it would make every post-tick-1 position in this scenario depend on a coin
-- flip, i.e. non-deterministic (the 0041 law's spirit). A parked wave makes each unit's distance to
-- it a pure one-dimensional recurrence along a fixed ray, so the whole approach is exactly
-- predictable, and it also lets this block pin the wave's spawn point EXACTLY rather than within a
-- speed's slop (see COMBATSPATIAL_PASS_ENEMY — that is a strengthening 0336 makes possible, not a
-- concession). The enemy CLOSE arm is not this block's subject and is proven, on a moving wave, by
-- danger-combat-proof's own closure block.
-- enemy_hp_base is raised so the wave survives the whole approach; enemy_attack_base is OWNED so the
-- one pirate salvo that lands deals a positive amount (COMBATSPATIAL_PASS_SCREEN rests on it) while
-- staying far above 0310's auto-exit floor; combat_damage_variance_pct and combat_hit_variance_pct
-- are zeroed for determinism (the house idiom, team-command-proof.sql's own COMBATPARITY setup).
--
-- ── PROPERTIES PROVEN (each a PASS marker below) ───────────────────────────────────────────────────
--   COMBATSPATIAL_PASS_SPAWN     — spawn writes positions/speed/weapons ONLY when lit; the LEAD on
--                                  the engagement anchor; both escorts on the ring at the SAME
--                                  distance (the owned radius, derived from the knob); weapons_json
--                                  shapes match the loadout (fitted ships their 1 catalog gun, the
--                                  unfitted escort exactly the ONE 0262 fallback entry at the owned
--                                  range).
--   COMBATSPATIAL_PASS_ENEMY     — 0336's spawn geometry, pinned EXACTLY: one synthetic pirate,
--                                  side='enemy', standing on combat_formation_point(anchor,
--                                  ring + its OWN weapon range + 1, slot 0, the arrival phase) — the point
--                                  predicted from the knobs BEFORE the tick and compared to the row
--                                  AFTER it. The old form asserted the location centre; after 0336
--                                  that is simply false, and the "within one move_speed of the
--                                  centre" bound it had degraded to would now pass for free.
--   COMBATSPATIAL_PASS_KITE      — the armed escort's DERIVED arm is 'kite' (it is inside its own
--                                  range and outside the wave's), and it retreats — distance
--                                  increases, and never past its own frozen weapon range.
--   COMBATSPATIAL_PASS_CLOSE     — the DERIVED arm of BOTH the lead and the fallback escort is
--                                  'close' (each is outside its own range), and both advance.
--   COMBATSPATIAL_PASS_FIRE      — tick 1's player missile_salvo count equals the DERIVED count of
--                                  player hulls whose PRE-MOVE distance was inside their own frozen
--                                  weapon range (1: the armed escort — the lead now opens the fight
--                                  out of reach, which is 0336's whole point); the pirate does NOT
--                                  fire tick 1, and the derivation shows why: every player hull is
--                                  at least er+1 away from it.
--   COMBATSPATIAL_PASS_DAMAGE    — the pirate's hp_current fell below its frozen hp_max after tick 1
--                                  (it took real damage the same tick it spawned).
--   COMBATSPATIAL_PASS_HOLD      — after the approach, the fallback escort's DERIVED arm is 'hold'
--                                  (inside its own range AND inside the wave's), and one more tick
--                                  leaves its position BYTE-IDENTICAL — HOLD never touches
--                                  pos_x/pos_y. Non-vacuous by construction: the same hull was
--                                  proven to be in CLOSE, and moving, on every tick before this one.
--   COMBATSPATIAL_PASS_SCREEN    — once the wave can reach a player at all: a pirate-sourced
--                                  missile_salvo event exists, an ESCORT's hp fell, and the LEAD's
--                                  hp is UNCHANGED — the S1 aggro-tier screening (escorts before the
--                                  lead) holds in the spatial branch exactly as in the aggregate one.
--
-- Self-rolling-back (begin;...rollback;, no COMMIT); every dark flag flipped ONLY inside the txn;
-- provisioning is 100% real-RPC (commission_first_main_ship / commission_additional_main_ship /
-- upsert_ship_group / assign_ship_to_group / set_fleet_command_ship / craft_module /
-- fit_module_to_ship / send_ship_group_hunt); group_sortie_members and combat_units are NEVER
-- hand-written — send_ship_group_hunt and combat_create_group_encounter are their sole writers.
-- No session RNG calls (the 0041 determinism law) — gen_random_uuid() is the only randomness used,
-- for fixture identity only, never combat math (both variance knobs are zeroed).

\set ON_ERROR_STOP on

begin;   -- everything below is transient; the trailing ROLLBACK leaves ZERO persisted state.

create temp table cspatial(k text primary key, v uuid) on commit preserve rows;
-- the numeric side of the same scratchpad: the post-tick-1 hp baseline the SCREEN block compares
-- against. A baseline READ AT TICK 1 rather than a hp_current = hp_max identity, because "full hp at
-- creation" is an ambient property of a freshly commissioned hull that this proof does not own.
create temp table cspatial_num(k text primary key, v double precision) on commit preserve rows;

-- caller helper: set the authenticated subject then run an RPC, returning its jsonb. Self-contained
-- (not sourced from either contended proof file) — the tiny call_as idiom is infra, not owned state.
create or replace function pg_temp.call_as(p_sub uuid, p_fn text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_fn into v;
  return v;
end $$;

-- ── THE ONE AUTHORITY IN THIS HARNESS FOR "WHICH ARM IS THIS UNIT IN" (0336 repoint) ─────────────
-- Every witness below is guarded by this before its movement is asserted, so a retune that slides a
-- hull into a different arm fails loudly instead of passing a property it is no longer testing. The
-- rule is stated ONCE, here, from the same three inputs combat_unit_decide_move reads:
--   out of MY range                       -> close
--   in my range but out of THEIRS         -> kite
--   both                                  -> hold
-- MY range is the MINIMUM over my weapons — 0336's my_min_range, the value the mover now receives —
-- while THEIR range is the MAXIMUM over theirs, because what I must respect about the enemy is its
-- full reach. Single-weapon hulls (every hull in this scenario) have min = max.
-- NULL IS NOT 'hold': combat_units.pos_x/pos_y and weapons_json ranges are all nullable, and a NULL
-- flowing into the CASE would fall through to the else branch and report a motionless-by-accident
-- unit as a passing HOLD. It answers 'unknown' instead, which every guard below rejects.
-- The OUT names are deliberately arm_*-prefixed: they share no spelling with any column, alias or
-- plpgsql variable in this file, so no reference below can be ambiguous or captured.
create or replace function pg_temp.cs_arm(p_unit uuid, p_foe uuid)
returns table(arm_kind text, arm_gap double precision, arm_my double precision, arm_foe double precision)
language sql stable as $$
  select case when d.gap is null or d.my_min is null or d.foe_max is null then 'unknown'
              when d.gap > d.my_min  then 'close'
              when d.gap > d.foe_max then 'kite'
              else 'hold' end,
         d.gap, d.my_min, d.foe_max
  from (
    select public.osn_distance(u.pos_x, u.pos_y, f.pos_x, f.pos_y) as gap,
           (select min((w->>'range')::double precision) from jsonb_array_elements(u.weapons_json) w) as my_min,
           (select max((w->>'range')::double precision) from jsonb_array_elements(f.weapons_json) w) as foe_max
      from public.combat_units u, public.combat_units f
     where u.id = p_unit and f.id = p_foe
  ) d;
$$;

-- ── THE ONE AUTHORITY IN THIS HARNESS FOR "ADVANCE ONE TICK" ─────────────────────────────────────
-- The clock rewind and the cron leaf belong together: a rewind without the call advances nothing, a
-- call without the rewind is a no-op because the encounter is not due yet. The approach below runs a
-- derived number of ticks, so the pair must be one composable leaf rather than a copied couplet.
create or replace function pg_temp.cs_tick(p_enc uuid) returns void language plpgsql as $$
begin
  update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = p_enc;
  perform public.process_combat_ticks();
end $$;

-- ════════ SETUP: reveal the starter ports (a fresh disposable chain seeds Haven/Slagworks/
--          Driftmarch INACTIVE — port_entry_commission_build hard-requires Haven to be dockable, so
--          without this, EVERY commission call fails closed with commission_unavailable; this is the
--          team-command-proof.sql precedent's own first setup step, mirrored verbatim), then one
--          fixture player, funded ═══════════════════════════════════════════════════════════════════
do $$
declare r jsonb; uZ uuid;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: reveal_starter_ports %', r; end if;

  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'cspatial.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uZ;
  insert into cspatial values ('uZ', uZ);
  insert into public.player_wallet (player_id, balance) values (uZ, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
end $$;

-- dark capability gates — flipped ONLY inside this rolled-back txn (committed/production values stay
-- false; a fresh disposable chain has ALL of these seeded false, so every one is load-bearing here).
update public.game_config set value='true'::jsonb where key='team_command_enabled';
update public.game_config set value='true'::jsonb where key='mainship_additional_commission_enabled';
update public.game_config set value='true'::jsonb where key='module_crafting_enabled';
update public.game_config set value='true'::jsonb where key='module_fitting_enabled';
update public.game_config set value='true'::jsonb where key='spatial_combat_enabled';
-- combat_telegraph stays DARK — OWNED here, not inherited (0300 lit it in the chain seeds, after
-- this proof was written; a lit telegraph queues the encounter instead of opening it inline at the
-- settle, and this proof's whole scenario observes the inline opening). The danger-combat-proof
-- idiom, verbatim.
update public.game_config set value='false'::jsonb where key='combat_telegraph_enabled';

-- tuning knobs (numeric, not capability gates) — the real set_game_config leaf, all reverted by
-- ROLLBACK. The scenario's engineered geometry (header) depends on these EXACT values, and every
-- distance derived from them is asserted below rather than assumed.
do $$
begin
  perform public.set_game_config('combat_damage_variance_pct', '0'::jsonb);          -- determinism
  -- 0320 pins the SECOND spread knob too. The per-hit roll 0314 added reads
  --   coalesce(cfg_num('combat_hit_variance_pct'), v_var_pct)
  -- so it INHERITED the damage-variance pin above only while that key did not exist. 0320 seeds it
  -- (production runs it at 0.5), and the moment it exists the inheritance stops and every exact
  -- damage equality below becomes a +/-50% roll. A proof must state the precondition it owns
  -- rather than rely on a row's ABSENCE.
  perform public.set_game_config('combat_hit_variance_pct', '0'::jsonb);             -- determinism (0314 per-hit roll)
  perform public.set_game_config('combat_tick_logging', 'true'::jsonb);              -- so combat_ticks rows land
  perform public.set_game_config('combat_event_logging', 'true'::jsonb);             -- so fire events land
  perform public.set_game_config('enemy_hp_base', '1000'::jsonb);                    -- the wave survives the whole approach
  -- OWNED because COMBATSPATIAL_PASS_SCREEN stakes "an escort's hp FELL" on the one pirate salvo
  -- landing a positive amount. Small enough that a single hit stays far above 0310's auto-exit floor
  -- (30% of a 500-hp frigate), so the fleet can never break off mid-scenario.
  perform public.set_game_config('enemy_attack_base', '1'::jsonb);
  -- ── THE 0336 GEOMETRY, OWNED ────────────────────────────────────────────────────────────────────
  -- The wave now stands at (this ring + its OWN range + 1) on a phase-0.5 slot, so the escort chord
  -- to it is sqrt(R^2 + Re^2 - 2*R*Re*cos(pi/8)) = 3.642 at R=4, Re=7: inside the catalog gun (5),
  -- outside the wave's own reach (2), and outside the owned fallback (1). Every one of those four
  -- comparisons is re-derived and asserted at tick 1 — this comment is the intent, not the evidence.
  perform public.set_game_config('spatial_formation_ring_radius', '4'::jsonb);
  perform public.set_game_config('enemy_synthetic_range_base', '2'::jsonb);          -- er: the wave's reach
  perform public.set_game_config('enemy_synthetic_range_per_difficulty', '0'::jsonb);
  -- THE WAVE DOES NOT MOVE. Two escorts sit equidistant from a phase-0.5 slot, so a moving wave
  -- would walk toward whichever one a float-noise id tiebreak picked and every later position in
  -- this scenario would hang off that coin flip. Parked, each unit's distance to it is a clean
  -- one-dimensional recurrence, and its spawn point can be pinned EXACTLY (PASS_ENEMY).
  perform public.set_game_config('enemy_synthetic_speed_base', '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', '0'::jsonb);
  -- the CLOSE-then-HOLD witness's own range, OWNED here: since 0262 an unfitted ship carries the
  -- synthesized fallback weapon, so "advances because it cannot reach" needs a range this harness
  -- sets — and it is set at or under er so that the closure TERMINATES in HOLD rather than at a
  -- kite edge (a hull whose own range exceeds the enemy's stops at its own edge and never holds).
  perform public.set_game_config('combat_player_fallback_weapon_range', '1'::jsonb);
  -- the player step per tick. 0316 converts world-travel speed into combat speed with this factor
  -- and ships it at 0.2; at that rate the approach below would take fourteen ticks instead of three.
  -- 1 is the top of the band 0316's own self-assert declares legal (0 < scale <= 1).
  perform public.set_game_config('combat_player_speed_scale', '1'::jsonb);
end $$;

-- ════════ PROVISION: 3 ships via the real commission RPCs, a real team, a real command designation,
--          and 2 real weapon fits (lead + the armed escort) ══════════════════════════════════════════
do $$
declare
  r jsonb;
  uZ uuid := (select v from cspatial where k='uZ');
  s_cmd uuid; s_arm uuid; s_bare uuid;
  v_mod_cmd uuid; v_mod_arm uuid;
begin
  r := pg_temp.call_as(uZ, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL first ship: %', r; end if;
  select main_ship_id into s_cmd from public.main_ship_instances where player_id = uZ;

  r := pg_temp.call_as(uZ, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then
    raise exception 'PROVISION FAIL 2nd ship: %', r; end if;
  s_arm := (r->>'main_ship_id')::uuid;

  r := pg_temp.call_as(uZ, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then
    raise exception 'PROVISION FAIL 3rd ship: %', r; end if;
  s_bare := (r->>'main_ship_id')::uuid;

  insert into cspatial values ('s_cmd', s_cmd), ('s_arm', s_arm), ('s_bare', s_bare);

  -- ── CRAFT + FIT BEFORE THE NORMALIZATION BELOW (0333) ────────────────────────────────────────
  -- Items live PER PORT now (`base_items`), and `craft_module` derives the port it spends from the
  -- crafting ship's VALIDATED DOCK. The normalization immediately below deliberately retires each
  -- commission fleet, which is exactly what makes a ship stop being 'at_location' — so a craft
  -- placed after it would (correctly) answer `not_docked`. The crafts therefore happen HERE, while
  -- the three ships are still docked at Haven Reach, and each one NAMES the ship it builds at:
  -- uZ owns THREE ships, so the sole-ship shim cannot resolve one and would answer `ship_not_found`.
  --
  -- grant EXACTLY the autocannon_battery recipe TWICE over (weapon_parts x4, pirate_alloy x2, scrap x6
  -- per unit — the S0/0107 seed) via the real Reward sole writer. A NULL base sends it to uZ's oldest
  -- active base — the Home Base, whose location_id IS Haven — i.e. the very store the crafts draw on.
  perform public.reward_grant('combat', gen_random_uuid(), uZ, null,
    '{"items": [{"item_id": "weapon_parts", "quantity": 8}, {"item_id": "pirate_alloy", "quantity": 4}, {"item_id": "scrap", "quantity": 12}]}'::jsonb);

  -- craft + fit ONE autocannon_battery onto the lead.
  r := pg_temp.call_as(uZ, format('public.craft_module(''cspatial-gun-1'', ''autocannon_battery'', %L::uuid)', s_cmd));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL craft gun1: %', r; end if;
  v_mod_cmd := (r->>'instance_id')::uuid;
  r := pg_temp.call_as(uZ, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''cspatial-fit-1'')', v_mod_cmd, s_cmd));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL fit gun1: %', r; end if;

  -- craft + fit a SECOND autocannon_battery onto the armed escort.
  r := pg_temp.call_as(uZ, format('public.craft_module(''cspatial-gun-2'', ''autocannon_battery'', %L::uuid)', s_arm));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL craft gun2: %', r; end if;
  v_mod_arm := (r->>'instance_id')::uuid;
  r := pg_temp.call_as(uZ, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''cspatial-fit-2'')', v_mod_arm, s_arm));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL fit gun2: %', r; end if;

  -- s_bare gets NO craft/fit call — since 0262 it will carry the synthesized fallback weapon, whose
  -- range this harness owns at 1 (under the escort chord, and at/under the wave's own reach): the
  -- CLOSE witness on tick 1 and the HOLD witness once it arrives.

  -- ── FIXTURE NORMALIZATION — the ONE non-RPC-pure step in this proof (the team-command-proof.sql
  --    PROVISION-block precedent, lifted verbatim). port_entry_commission_build (0222) docks every
  --    freshly commissioned ship at Haven Reach via a REAL 'present' fleet + active location_presence
  --    (the "corpse dock" — a transitional dual-representation alongside main_ship_instances.status
  --    ='home'). send_ship_group_hunt's dark-path readiness check (the 4C-MIG-2B GATE FIX, migration
  --    0231/movement_schema_drop) DELIBERATELY treats a fleet-truth-docked member as NOT ready while
  --    dark (launch_from_dock_enabled unflipped here) — minting a team fleet on top of a live dock
  --    fleet would be a phantom second fleet. Retire each ship's commission fleet (status→'destroyed')
  --    and complete its now-orphaned presence — the SAME two-statement retirement every real sender
  --    of a freshly-commissioned ship performs before its first send, never a bespoke skip.
  update public.main_ship_instances
     set status = 'home', updated_at = now()
   where main_ship_id in (s_cmd, s_arm, s_bare);
  update public.fleets
     set status = 'destroyed', location_mode = 'destroyed', active_movement_id = null,
         current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
         updated_at = now()
   where main_ship_id in (s_cmd, s_arm, s_bare) and status = 'present';
  update public.location_presence
     set status = 'completed', updated_at = now()
   where fleet_id in (select id from public.fleets
                        where main_ship_id in (s_cmd, s_arm, s_bare) and status = 'destroyed')
     and status = 'active';

  -- form the team, assign all 3, designate the command ship (owner-scoped, NOT flag-gated, 0204).
  r := pg_temp.call_as(uZ, 'public.upsert_ship_group(1, ''Spatial'')');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL group create: %', r; end if;
  insert into cspatial values ('gZ', (r->>'group_id')::uuid);
  r := pg_temp.call_as(uZ, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_cmd,  (select v from cspatial where k='gZ')));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL assign cmd: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_arm,  (select v from cspatial where k='gZ')));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL assign arm: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_bare, (select v from cspatial where k='gZ')));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL assign bare: %', r; end if;

  r := pg_temp.call_as(uZ, format('public.set_fleet_command_ship(%L::uuid, true)', s_cmd));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL designate command: %', r; end if;

  raise notice 'setup ok: 3-ship team provisioned (s_cmd armed+lead, s_arm armed escort, s_bare unarmed escort)';
end $$;

-- ════════ SEND + SETTLE: the real chain, exactly team-command-proof.sql's TEAMHUNT pattern ══════════
do $$
declare
  r jsonb; n int;
  uZ uuid := (select v from cspatial where k='uZ');
  gZ uuid := (select v from cspatial where k='gZ');
  v_hunt uuid; v_fleet uuid; v_mv uuid; v_enc uuid;
begin
  select id into v_hunt from public.locations
    where activity_type = 'hunt_pirates' and status = 'active'
    order by min_power_required asc, base_difficulty asc limit 1;
  if v_hunt is null then raise exception 'SEND FAIL: no active hunt_pirates location'; end if;
  insert into cspatial values ('v_hunt', v_hunt);

  r := pg_temp.call_as(uZ, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gZ, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'SEND FAIL: %', r; end if;
  v_fleet := (r->>'fleet_id')::uuid; v_mv := (r->>'movement_id')::uuid;
  if v_fleet is null or v_mv is null then raise exception 'SEND FAIL envelope: %', r; end if;

  select count(*) into n from public.group_sortie_members where fleet_id = v_fleet;
  if n <> 3 then raise exception 'SEND FAIL: % manifest rows (want 3)', n; end if;

  -- settle via the cron's own per-movement settle (clock rewind, the sanctioned surgery — the
  -- team-command-proof.sql TEAMHUNT idiom, verbatim).
  update public.fleet_movements
     set depart_at = now() - interval '2 minutes', arrive_at = now() - interval '1 minute'
   where id = v_mv;
  r := public.movement_settle_arrival(v_mv);
  if (r->>'settled')::boolean is not true or (r->>'outcome') is distinct from 'present' then
    raise exception 'SEND FAIL settle: %', r; end if;

  select id into v_enc from public.combat_encounters where fleet_id = v_fleet and status = 'active';
  if v_enc is null then raise exception 'SEND FAIL: no active encounter after arrival'; end if;
  insert into cspatial values ('v_enc', v_enc);

  raise notice 'setup ok: sortie sent, settled, encounter % active', v_enc;
end $$;

-- ════════ BLOCK SPAWN: the creator's spatial hunk (LIT, positions/speed/weapons written) ═══════════
do $$
declare
  n int; v_enc uuid := (select v from cspatial where k='v_enc');
  s_cmd uuid := (select v from cspatial where k='s_cmd');
  s_arm uuid := (select v from cspatial where k='s_arm');
  s_bare uuid := (select v from cspatial where k='s_bare');
  v_anchor_x double precision; v_anchor_y double precision;
  v_cmd_x double precision; v_cmd_y double precision;
  v_dist_arm double precision; v_dist_bare double precision;
  v_wcount_cmd int; v_wcount_arm int; v_wcount_bare int;
  v_ring double precision; v_fb_range double precision;
begin
  -- THE ENGAGEMENT ANCHOR, resolved exactly as the tick resolves it
  -- (v_anchor_x := coalesce(e.engagement_x, loc.x), 0294/0299) — never the location row alone.
  select coalesce(e.engagement_x, l.x), coalesce(e.engagement_y, l.y)
    into v_anchor_x, v_anchor_y
    from public.combat_encounters e join public.locations l on l.id = e.location_id
   where e.id = v_enc;
  if v_anchor_x is null or v_anchor_y is null then
    raise exception 'SPAWN FAIL: the encounter has no engagement anchor — every position assert below would be vacuous';
  end if;
  -- the owned knobs, read back through the same leaf the engine reads them through.
  v_ring     := public.cfg_num('spatial_formation_ring_radius');
  v_fb_range := public.cfg_num('combat_player_fallback_weapon_range');
  if v_ring is null or v_ring <= 0 or v_fb_range is null or v_fb_range <= 0 then
    raise exception 'SPAWN FAIL: the owned ring (%) or fallback range (%) did not land — the geometry has nothing to stand on', v_ring, v_fb_range;
  end if;

  -- exactly 3 player-side rows, all positioned (LIT — not NULL).
  select count(*) into n from public.combat_units
    where encounter_id = v_enc and side = 'player' and pos_x is not null and pos_y is not null and move_speed is not null;
  if n <> 3 then raise exception 'SPAWN FAIL: % player rows carry positions (want 3)', n; end if;

  -- the LEAD spawns EXACTLY on the engagement anchor (0315: the elected lead takes the anchor slot).
  select pos_x, pos_y into v_cmd_x, v_cmd_y from public.combat_units where encounter_id = v_enc and main_ship_id = s_cmd;
  -- ██ RE-POINTED BY 0339: EXACT FLOAT EQUALITY ACROSS TWO DIFFERENT PATHS IS NOT A PROPERTY ██
  -- This asked `is distinct from`, and it held only because every engagement anchor used to be an
  -- INTEGER coordinate — a location's own x/y, exactly representable, so the two paths could not
  -- disagree. 0339 stands a site fight OFF its site (site + territory_radius on a hashed bearing) to
  -- give the wave a direction to arrive from, so the anchor is now an ordinary irrational double.
  -- The two values reach this assert by DIFFERENT ROUTES: engagement_x is written straight to the
  -- column, while the lead's pos_x travels through combat_create_group_encounter's v_roster JSONB
  -- and back out via (e->>'pos_x')::double precision — a jsonb numeric round-trip that can move the
  -- last bit. CI caught it as `got -53.8537253328581,111.899904461656 want
  -- -53.8537253328581,111.899904461656` — identical to fifteen digits and still `distinct`.
  -- THE PROPERTY IS "the lead stands ON the anchor", and it is unchanged. A tolerance of 1e-9 world
  -- units is fourteen orders of magnitude tighter than anything the game can express (positions are
  -- canonicalised onto an integer grid) and is the same judgement 0339 makes inside
  -- combat_wave_arrival_phase, and DEADFIRE already made after the 4.00000000000001 > 4 flake: a
  -- premise resting on exact float equality is a coin flip, not a property.
  if abs(v_cmd_x - v_anchor_x) > 1e-9 or abs(v_cmd_y - v_anchor_y) > 1e-9 then
    raise exception 'SPAWN FAIL: command ship not at the engagement anchor (got %,% want %,%, deltas %,%)', v_cmd_x, v_cmd_y, v_anchor_x, v_anchor_y, v_cmd_x - v_anchor_x, v_cmd_y - v_anchor_y;
  end if;

  -- both escorts sit on the SAME ring — the owned radius, derived from the knob, never a literal.
  select public.osn_distance(pos_x, pos_y, v_anchor_x, v_anchor_y) into v_dist_arm
    from public.combat_units where encounter_id = v_enc and main_ship_id = s_arm;
  select public.osn_distance(pos_x, pos_y, v_anchor_x, v_anchor_y) into v_dist_bare
    from public.combat_units where encounter_id = v_enc and main_ship_id = s_bare;
  if v_dist_arm is null or v_dist_bare is null
     or abs(v_dist_arm - v_ring) > 0.01 or abs(v_dist_bare - v_ring) > 0.01 then
    raise exception 'SPAWN FAIL: escort ring distances wrong (arm=%, bare=%, want ~% each — the owned spatial_formation_ring_radius)', v_dist_arm, v_dist_bare, v_ring;
  end if;

  -- weapons_json shapes: every ship carries exactly 1 entry — the two fitted ships their catalog
  -- gun, the unfitted escort the ONE synthesized 0262 fallback (follow-the-game repoint: before
  -- 0262 an unfitted ship carried NONE; asserting that old emptiness would assert a retired world).
  select jsonb_array_length(weapons_json) into v_wcount_cmd  from public.combat_units where encounter_id = v_enc and main_ship_id = s_cmd;
  select jsonb_array_length(weapons_json) into v_wcount_arm  from public.combat_units where encounter_id = v_enc and main_ship_id = s_arm;
  select jsonb_array_length(weapons_json) into v_wcount_bare from public.combat_units where encounter_id = v_enc and main_ship_id = s_bare;
  if v_wcount_cmd <> 1 or v_wcount_arm <> 1 or v_wcount_bare <> 1 then
    raise exception 'SPAWN FAIL: weapon counts wrong (cmd=%, arm=%, bare=% — want 1,1,1: two fitted guns + the 0262 fallback)', v_wcount_cmd, v_wcount_arm, v_wcount_bare;
  end if;
  -- the fitted entries carry the CATALOG range (derived at assert time — 0313 repoint: the old form
  -- hard-coded the 150 seed, an ambient default this proof never owned).
  select count(*) into n from public.combat_units cu
    where cu.encounter_id = v_enc and cu.main_ship_id in (s_cmd, s_arm)
      and (cu.weapons_json->0->>'module_type_id') = 'autocannon_battery'
      and (cu.weapons_json->0->>'range')::numeric = (select t.range from public.module_types t where t.id = 'autocannon_battery');
  if n <> 2 then raise exception 'SPAWN FAIL: fitted weapon range/id did not carry into weapons_json (want 2 rows at the catalog autocannon_battery range)'; end if;
  -- and the unfitted escort's ONE entry is the fallback, at the range this harness owns (derived
  -- from the knob at assert time, never the literal).
  select count(*) into n from public.combat_units cu
    where cu.encounter_id = v_enc and cu.main_ship_id = s_bare
      and (cu.weapons_json->0->>'module_type_id')
            = coalesce((select value #>> '{}' from public.game_config where key = 'combat_player_fallback_weapon_module_type_id'), 'basic_player_weapon')
      and (cu.weapons_json->0->>'range')::double precision = v_fb_range;
  if n <> 1 then raise exception 'SPAWN FAIL: the unfitted escort''s entry is not the owned-range fallback weapon (want 1 fallback row at the owned range)'; end if;

  -- side is 'player' for every row this creator ever writes.
  select count(*) into n from public.combat_units where encounter_id = v_enc and side <> 'player' and main_ship_id is not null;
  if n <> 0 then raise exception 'SPAWN FAIL: a member row is not side=player'; end if;

  raise notice 'COMBATSPATIAL_PASS_SPAWN ok: lead on the engagement anchor (%,%), both escorts on the owned %-unit ring, weapons_json shapes exact (1/1/1 — catalog guns + the fallback at the owned range %), side=player throughout', v_anchor_x, v_anchor_y, v_ring, v_fb_range;
end $$;

-- ════════ TICK 1: wave spawn on the 0336 ring + the first movement/fire pass ═══════════════════════
do $$
declare
  n int; n_player_fire int; v_enc uuid := (select v from cspatial where k='v_enc');
  s_cmd uuid := (select v from cspatial where k='s_cmd');
  s_arm uuid := (select v from cspatial where k='s_arm');
  s_bare uuid := (select v from cspatial where k='s_bare');
  v_anchor_x double precision; v_anchor_y double precision;
  v_ring double precision; v_diff double precision; v_er_pred double precision;
  v_site_x double precision; v_site_y double precision;  -- (0338) the zone's own city
  v_px double precision; v_py double precision;      -- the PREDICTED wave slot-0 point
  v_ex double precision; v_ey double precision;      -- where the wave actually stands
  u_cmd uuid; u_arm uuid; u_bare uuid; u_en uuid;
  v_cmd_x0 double precision; v_cmd_y0 double precision;
  v_arm_x0 double precision; v_arm_y0 double precision;
  v_bare_x0 double precision; v_bare_y0 double precision;
  v_d_cmd0 double precision; v_d_arm0 double precision; v_d_bare0 double precision;
  v_d_cmd1 double precision; v_d_arm1 double precision; v_d_bare1 double precision;
  v_r_cmd double precision; v_r_arm double precision; v_r_bare double precision; v_r_en double precision;
  v_hp_cmd0 double precision; v_hp_arm0 double precision; v_hp_bare0 double precision;
  v_enemy_hpmax double precision; v_enemy_hpcur double precision;
  v_exp_fire int;
  v_arm_cmd text; v_arm_arm text; v_arm_bare text;
begin
  select coalesce(e.engagement_x, l.x), coalesce(e.engagement_y, l.y), l.base_difficulty, l.x, l.y
    into v_anchor_x, v_anchor_y, v_diff, v_site_x, v_site_y
    from public.combat_encounters e join public.locations l on l.id = e.location_id
   where e.id = v_enc;
  v_ring := public.cfg_num('spatial_formation_ring_radius');

  -- ── 0336's spawn geometry, PREDICTED BEFORE THE TICK from the knobs the tick itself reads.
  --    The wave's own range is (base + difficulty * per_difficulty), exactly the tick's expression,
  --    and its slot-0 point is combat_formation_point(anchor, ring + that range + 1, 0, the arrival
  --    phase) — the very leaf the tick composes. Predicting first and comparing after is what makes
  --    PASS_ENEMY a pin on 0336 rather than a restatement of whatever the row happens to hold.
  --    0338 REPOINTED: the phase is no longer a bare constant. It comes from combat_wave_arrival_phase
  --    — the one authority for which way a wave arrives from — composed here with the SAME arguments
  --    the tick composes it with: this encounter's anchor and this encounter's own site. The RADIUS is
  --    untouched, so every distance predicted below is unchanged in magnitude; only the direction the
  --    wave stands in moves, which is exactly 0338's scope.
  v_er_pred := coalesce(public.cfg_num('enemy_synthetic_range_base'), 120)
               + v_diff * coalesce(public.cfg_num('enemy_synthetic_range_per_difficulty'), 5);
  if v_anchor_x is null or v_anchor_y is null or v_ring is null or v_er_pred is null then
    raise exception 'TICK1 FAIL: anchor (%,%), ring % or predicted enemy range % is NULL — the spawn-point pin would be vacuous', v_anchor_x, v_anchor_y, v_ring, v_er_pred;
  end if;
  select fp.x, fp.y into v_px, v_py
    from public.combat_formation_point(v_anchor_x, v_anchor_y, v_ring + v_er_pred + 1, 0,
           public.combat_wave_arrival_phase(v_anchor_x, v_anchor_y, v_site_x, v_site_y, 0)) fp;

  select id, pos_x, pos_y into u_cmd,  v_cmd_x0,  v_cmd_y0  from public.combat_units where encounter_id = v_enc and main_ship_id = s_cmd;
  select id, pos_x, pos_y into u_arm,  v_arm_x0,  v_arm_y0  from public.combat_units where encounter_id = v_enc and main_ship_id = s_arm;
  select id, pos_x, pos_y into u_bare, v_bare_x0, v_bare_y0 from public.combat_units where encounter_id = v_enc and main_ship_id = s_bare;
  insert into cspatial values ('u_cmd', u_cmd), ('u_arm', u_arm), ('u_bare', u_bare);

  -- each hull's own frozen reach (its weapons_json, never the catalog) and its PRE-MOVE distance to
  -- the point the wave is about to occupy.
  select max((w->>'range')::double precision) into v_r_cmd  from public.combat_units cu, jsonb_array_elements(cu.weapons_json) w where cu.id = u_cmd;
  select max((w->>'range')::double precision) into v_r_arm  from public.combat_units cu, jsonb_array_elements(cu.weapons_json) w where cu.id = u_arm;
  select max((w->>'range')::double precision) into v_r_bare from public.combat_units cu, jsonb_array_elements(cu.weapons_json) w where cu.id = u_bare;
  v_d_cmd0  := public.osn_distance(v_cmd_x0,  v_cmd_y0,  v_px, v_py);
  v_d_arm0  := public.osn_distance(v_arm_x0,  v_arm_y0,  v_px, v_py);
  v_d_bare0 := public.osn_distance(v_bare_x0, v_bare_y0, v_px, v_py);
  if v_r_cmd is null or v_r_arm is null or v_r_bare is null
     or v_d_cmd0 is null or v_d_arm0 is null or v_d_bare0 is null then
    raise exception 'TICK1 FAIL: a frozen weapon range (%/%/%) or a pre-move distance (%/%/%) is NULL — every arm derived below would be unknown', v_r_cmd, v_r_arm, v_r_bare, v_d_cmd0, v_d_arm0, v_d_bare0;
  end if;

  -- ── THE PREMISE THIS SCENARIO IS ENGINEERED FOR, ASSERTED NOT ASSUMED. Four orderings make the
  --    three arms reachable at all; if a catalog retune or a knob drift breaks any one of them the
  --    witnesses below would silently change arm, so it raises here instead. ──────────────────────
  if not (v_d_arm0 > v_er_pred) then
    raise exception 'TICK1 FAIL premise: the escort chord % is not outside the wave''s own reach % — 0336 guarantees at least range+1, so this world is not the one 0336 builds', v_d_arm0, v_er_pred;
  end if;
  if not (v_d_arm0 < v_r_arm) then
    raise exception 'TICK1 FAIL premise: the escort chord % is not inside the armed escort''s own % reach — it would CLOSE instead of KITE and the KITE witness would be testing the wrong arm', v_d_arm0, v_r_arm;
  end if;
  if not (v_d_bare0 > v_r_bare) then
    raise exception 'TICK1 FAIL premise: the fallback escort''s chord % is not outside its own % reach — it would not CLOSE and the approach would never start', v_d_bare0, v_r_bare;
  end if;
  if not (v_r_bare <= v_er_pred) then
    raise exception 'TICK1 FAIL premise: the fallback range % exceeds the wave''s reach % — a hull that out-ranges the enemy comes to rest at its own kite edge and NEVER reaches HOLD, so the HOLD witness could never arrive', v_r_bare, v_er_pred;
  end if;
  if not (v_d_cmd0 > v_r_cmd) then
    raise exception 'TICK1 FAIL premise: the lead''s distance % is not outside its own % reach — the lead is the second CLOSE witness and would be in another arm', v_d_cmd0, v_r_cmd;
  end if;

  select hp_current into v_hp_cmd0  from public.combat_units where id = u_cmd;
  select hp_current into v_hp_arm0  from public.combat_units where id = u_arm;
  select hp_current into v_hp_bare0 from public.combat_units where id = u_bare;
  insert into cspatial_num values ('hp_cmd', v_hp_cmd0), ('hp_arm', v_hp_arm0), ('hp_bare', v_hp_bare0);

  -- no enemy exists yet — wave 1 (and its first combat pass) spawns INSIDE this very tick call.
  select count(*) into n from public.combat_units where encounter_id = v_enc and side = 'enemy';
  if n <> 0 then raise exception 'TICK1 FAIL precondition: % enemy rows exist before the first tick (want 0)', n; end if;

  perform pg_temp.cs_tick(v_enc);

  -- ── ENEMY: exactly 1 synthetic pirate, standing on the point 0336 puts it on. ──────────────────
  -- The pre-0336 form of this assert required the pirate to still be at the LOCATION CENTRE, which
  -- is now simply false; the "within one move_speed of the centre" bound it had been softened to
  -- would, after 0336, pass for free on a wave that spawned anywhere at all. With the wave's speed
  -- owned at 0 its post-tick position IS its spawn position, so this pins the exact point instead —
  -- radius = ring + ITS OWN weapon range + 1, slot 0, the arrival phase — and cross-checks that the range in
  -- its weapons_json is the one the radius was predicted from.
  select count(*) into n from public.combat_units
    where encounter_id = v_enc and side = 'enemy' and unit_type_id = 'pirate_synthetic';
  if n <> 1 then raise exception 'TICK1 FAIL: % synthetic pirate row(s) (want exactly 1 — one unit means slot 0, which is what the spawn-point pin below names)', n; end if;
  select id, pos_x, pos_y into u_en, v_ex, v_ey from public.combat_units where encounter_id = v_enc and side = 'enemy';
  insert into cspatial values ('u_en', u_en);
  select max((w->>'range')::double precision) into v_r_en
    from public.combat_units cu, jsonb_array_elements(cu.weapons_json) w where cu.id = u_en;
  if v_ex is null or v_ey is null or v_r_en is null then
    raise exception 'TICK1 FAIL ENEMY: the wave row is unpositioned or carries no range (pos %,%, range %) — the spawn-point pin would be vacuous', v_ex, v_ey, v_r_en;
  end if;
  if abs(v_r_en - v_er_pred) > 1e-9 then
    raise exception 'TICK1 FAIL ENEMY: the wave carries range % but the knobs predict % — the radius pinned below was derived from the wrong reach', v_r_en, v_er_pred;
  end if;
  if abs(v_ex - v_px) > 1e-9 or abs(v_ey - v_py) > 1e-9 then
    raise exception 'TICK1 FAIL ENEMY: the wave stands at %,% but combat_formation_point(anchor, ring % + its own range % + 1, slot 0, the arrival phase) is %,% — 0336''s wave-spawn geometry is not what landed', v_ex, v_ey, v_ring, v_r_en, v_px, v_py;
  end if;
  raise notice 'COMBATSPATIAL_PASS_ENEMY ok: 1 synthetic pirate (side=enemy, unit_type_id=pirate_synthetic) standing exactly on combat_formation_point(anchor, ring % + its own range % + 1, slot 0, the 0338 arrival phase toward its own city) = %,%', v_ring, v_r_en, v_ex, v_ey;

  -- ── THE DERIVED ARMS, one per witness, taken from the frozen PRE-MOVE snapshot. Each is the
  --    non-vacuity guard for the movement asserted immediately after it. ─────────────────────────
  select arm_kind into v_arm_cmd  from pg_temp.cs_arm(u_cmd,  u_en);
  select arm_kind into v_arm_arm  from pg_temp.cs_arm(u_arm,  u_en);
  select arm_kind into v_arm_bare from pg_temp.cs_arm(u_bare, u_en);

  -- ── KITE: the armed escort is inside its own reach and outside the wave's, so it retreats — and
  --    never past its own range edge (0234's kite step is capped at my_range - dist). ────────────
  if v_arm_arm is distinct from 'kite' then
    raise exception 'TICK1 FAIL KITE: the armed escort''s derived arm is ''%'' , not ''kite'' (pre-move distance %, its own reach %, the wave''s reach %) — the witness is not in the arm this assert names', v_arm_arm, v_d_arm0, v_r_arm, v_r_en;
  end if;
  v_d_arm1 := public.osn_distance((select pos_x from public.combat_units where id = u_arm),
                                  (select pos_y from public.combat_units where id = u_arm), v_ex, v_ey);
  if v_d_arm1 is null or v_d_arm1 <= v_d_arm0 then
    raise exception 'TICK1 FAIL KITE: armed escort distance did not increase (%->%)', v_d_arm0, v_d_arm1; end if;
  if v_d_arm1 > v_r_arm + 0.001 then
    raise exception 'TICK1 FAIL KITE: armed escort retreated past its own frozen % range (dist %)', v_r_arm, v_d_arm1; end if;
  raise notice 'COMBATSPATIAL_PASS_KITE ok: armed escort derived arm ''kite'' and retreated (dist %->%), staying within its own frozen % weapon range', v_d_arm0, v_d_arm1, v_r_arm;

  -- ── CLOSE: BOTH hulls that are outside their own reach advance — the fallback escort AND the
  --    lead, which after 0336 is the FURTHEST player hull from the wave rather than the nearest. ──
  if v_arm_bare is distinct from 'close' then
    raise exception 'TICK1 FAIL CLOSE: the fallback escort''s derived arm is ''%'' , not ''close'' (pre-move distance %, its own reach %) — the witness is not in the arm this assert names', v_arm_bare, v_d_bare0, v_r_bare;
  end if;
  if v_arm_cmd is distinct from 'close' then
    raise exception 'TICK1 FAIL CLOSE: the lead''s derived arm is ''%'' , not ''close'' (pre-move distance %, its own reach %) — after 0336 the lead opens the fight out of reach and must advance', v_arm_cmd, v_d_cmd0, v_r_cmd;
  end if;
  v_d_bare1 := public.osn_distance((select pos_x from public.combat_units where id = u_bare),
                                   (select pos_y from public.combat_units where id = u_bare), v_ex, v_ey);
  v_d_cmd1  := public.osn_distance((select pos_x from public.combat_units where id = u_cmd),
                                   (select pos_y from public.combat_units where id = u_cmd), v_ex, v_ey);
  if v_d_bare1 is null or v_d_bare1 >= v_d_bare0 then
    raise exception 'TICK1 FAIL CLOSE: fallback escort distance did not decrease (%->%)', v_d_bare0, v_d_bare1; end if;
  if v_d_cmd1 is null or v_d_cmd1 >= v_d_cmd0 then
    raise exception 'TICK1 FAIL CLOSE: lead distance did not decrease (%->%)', v_d_cmd0, v_d_cmd1; end if;
  raise notice 'COMBATSPATIAL_PASS_CLOSE ok: both out-of-reach hulls advanced — fallback escort %->%, lead %->%', v_d_bare0, v_d_bare1, v_d_cmd0, v_d_cmd1;

  -- ── FIRE: the tick-1 player salvo count is DERIVED, not typed. A hull fires when its PRE-MOVE
  --    distance is within its own frozen reach (0299's gate), and each of these hulls carries
  --    exactly one weapon, so the count is exactly the number of hulls that satisfy it. After 0336
  --    that is the armed escort alone: the lead now opens the fight outside its own range, which is
  --    precisely the behaviour change this migration ships. ───────────────────────────────────────
  v_exp_fire := (case when v_d_cmd0  <= v_r_cmd  then 1 else 0 end)
              + (case when v_d_arm0  <= v_r_arm  then 1 else 0 end)
              + (case when v_d_bare0 <= v_r_bare then 1 else 0 end);
  if v_exp_fire < 1 then
    raise exception 'TICK1 FAIL FIRE: the derivation expects ZERO player salvos on tick 1 — nothing would damage the wave and PASS_DAMAGE would be vacuous';
  end if;
  select count(*) into n_player_fire from public.combat_events
    where encounter_id = v_enc and tick_number = 1 and event_type = 'missile_salvo' and source = 'player';
  if n_player_fire <> v_exp_fire then
    raise exception 'TICK1 FAIL FIRE: % player missile_salvo events on tick 1, derivation expects % (pre-move distances %/%/% against own reaches %/%/%)', n_player_fire, v_exp_fire, v_d_cmd0, v_d_arm0, v_d_bare0, v_r_cmd, v_r_arm, v_r_bare;
  end if;
  -- and the wave fired NOTHING: 0336 stands it at least its own range + 1 from every player hull,
  -- so the nearest hull is outside its reach by construction. Derived, then asserted.
  if least(v_d_cmd0, v_d_arm0, v_d_bare0) <= v_r_en then
    raise exception 'TICK1 FAIL FIRE: the nearest player hull is % from the wave, inside its own % reach — 0336''s spawn invariant (range + 1 from EVERY player ship) does not hold in this world', least(v_d_cmd0, v_d_arm0, v_d_bare0), v_r_en;
  end if;
  select count(*) into n from public.combat_events
    where encounter_id = v_enc and tick_number = 1 and event_type = 'missile_salvo' and source = 'pirate';
  if n <> 0 then raise exception 'TICK1 FAIL FIRE: pirate fired % time(s) on tick 1 (want 0 — every player hull is outside its % reach at spawn)', n, v_r_en; end if;
  raise notice 'COMBATSPATIAL_PASS_FIRE ok: tick 1 — % player missile_salvo event(s), exactly the derived in-reach count; the wave fired nothing (nearest player hull % against its own % reach)', n_player_fire, least(v_d_cmd0, v_d_arm0, v_d_bare0), v_r_en;

  -- ── DAMAGE: the pirate's hp_current fell below its frozen hp_max (it took real damage tick 1). ─────
  select hp_max, hp_current into v_enemy_hpmax, v_enemy_hpcur from public.combat_units where id = u_en;
  if v_enemy_hpcur >= v_enemy_hpmax then
    raise exception 'TICK1 FAIL DAMAGE: pirate hp_current (%) is not below hp_max (%)', v_enemy_hpcur, v_enemy_hpmax; end if;
  raise notice 'COMBATSPATIAL_PASS_DAMAGE ok: pirate hp_current % fell below its frozen hp_max % after tick 1', v_enemy_hpcur, v_enemy_hpmax;

  -- sanity: no player ship has taken damage yet (the wave could not reach anybody this tick).
  select count(*) into n from public.combat_units
    where encounter_id = v_enc and side = 'player'
      and ((id = u_cmd  and hp_current is distinct from v_hp_cmd0)
        or (id = u_arm  and hp_current is distinct from v_hp_arm0)
        or (id = u_bare and hp_current is distinct from v_hp_bare0));
  if n <> 0 then raise exception 'TICK1 FAIL: a player ship took damage before the wave was ever in range (want 0)'; end if;
end $$;

-- ════════ THE APPROACH + HOLD: the fallback escort closes, then comes to rest inside both reaches ══
-- 0336 makes the opening tick of every fight an approach, so HOLD is no longer something a hull is
-- BORN in — it is where a hull ARRIVES. This block walks the fallback escort in, one guarded CLOSE
-- step at a time (the number of steps is run out against the MEASURED gap and the MEASURED frozen
-- move_speed, never typed in), and only then asserts the property HOLD actually names: a unit inside
-- its own range whose target is inside its target's range does not move at all.
do $$
declare
  v_enc  uuid := (select v from cspatial where k='v_enc');
  u_bare uuid := (select v from cspatial where k='u_bare');
  u_en   uuid := (select v from cspatial where k='u_en');
  v_arm_bare text; v_gap double precision; v_gap_after double precision;
  v_speed double precision;
  v_steps int := 0;
  v_x0 double precision; v_y0 double precision; v_x1 double precision; v_y1 double precision;
  v_arm_engine text; v_pred_x double precision; v_pred_y double precision;
begin
  select move_speed into v_speed from public.combat_units where id = u_bare;
  if v_speed is null or v_speed <= 0 then
    raise exception 'HOLD FAIL: the fallback escort''s frozen move_speed is % — it can never close and this block would spin', v_speed;
  end if;

  -- walk it in. Every step is guarded to be genuinely in CLOSE before the tick runs, and to have
  -- actually shortened the gap after it — so this loop can never quietly become a no-op.
  loop
    select arm_kind, arm_gap into v_arm_bare, v_gap from pg_temp.cs_arm(u_bare, u_en);
    exit when v_arm_bare = 'hold';
    v_steps := v_steps + 1;
    if v_steps > 24 then
      raise exception 'HOLD FAIL: the fallback escort is still ''%'' after % closing ticks (gap %, its own reach and the wave''s are both meant to be above it) — the approach does not converge at this tuning', v_arm_bare, v_steps, v_gap;
    end if;
    if v_arm_bare is distinct from 'close' then
      raise exception 'HOLD FAIL: the fallback escort''s derived arm is ''%'' mid-approach (gap %) — it is neither closing nor arrived, so the approach is not the one this block measures', v_arm_bare, v_gap;
    end if;
    perform pg_temp.cs_tick(v_enc);
    select arm_gap into v_gap_after from pg_temp.cs_arm(u_bare, u_en);
    if v_gap_after is null or v_gap_after >= v_gap then
      raise exception 'HOLD FAIL: a closing tick did not shorten the gap (%->%) — the CLOSE arm stopped moving before arriving', v_gap, v_gap_after;
    end if;
  end loop;

  -- ARRIVED: derived arm is 'hold', i.e. inside its own reach AND inside the wave's. Non-vacuous by
  -- construction — the same hull was proven to be in CLOSE, and to have moved, on every tick above.
  select arm_gap into v_gap from pg_temp.cs_arm(u_bare, u_en);
  if v_steps < 1 then
    raise exception 'HOLD FAIL: the fallback escort was already in HOLD before any closing tick — it would have been born in range and this witness would prove nothing about arriving';
  end if;
  -- AND THE STILLNESS MUST NOT BE A CORPSE'S. 0317's actor-liveness guard skips a dead row entirely,
  -- and a concluded encounter is not ticked at all — either way the hull would sit byte-identically
  -- still and pass the assert below without ever having been in HOLD. Both are pinned first.
  perform 1 from public.combat_units where id = u_bare and alive_count > 0 and hp_current > 0;
  if not found then
    raise exception 'HOLD FAIL: the holding hull is not alive — a corpse never moves, so its stillness would prove nothing about the HOLD arm';
  end if;
  if (select status from public.combat_encounters where id = v_enc) is distinct from 'active' then
    raise exception 'HOLD FAIL: the encounter is no longer active — an unticked fight leaves every position untouched and the stillness below would be vacuous';
  end if;
  select pos_x, pos_y into v_x0, v_y0 from public.combat_units where id = u_bare;

  -- ── ASK THE ENGINE, DO NOT MIRROR IT ────────────────────────────────────────────────────────────
  -- cs_arm above is a hand-written copy of the mover's arm rule, and a copy can drift from the thing
  -- it copies. That is exactly the failure this block hit in CI: it reported "the holding hull moved"
  -- while printing a BYTE-IDENTICAL before/after, because the server renders at
  -- extra_float_digits = 0 (15 significant digits) and the move was smaller than that.
  -- The mover's arms are: dist > my_range -> close ; dist > target_range -> kite ; else hold. A hull
  -- inside its OWN reach but outside its target's is therefore in KITE, and its step is
  -- least(speed, my_range - dist), which VANISHES as dist approaches my_range from below. Measured
  -- against the DEPLOYED function: a gap of 4.9999999999 against a reach of 5 moves the hull 1e-10,
  -- and a true HOLD (inside BOTH reaches) returns the position bit-identically. So that is a real
  -- move in a real arm, invisible at 15 digits — the assert was right, and a mirror that says "hold"
  -- there is what was wrong.
  -- The arm is therefore taken from combat_unit_decide_move ITSELF, with exactly the arguments the
  -- tick passes it (0336: the hull's SHORTEST gun as its own reach, the target's LONGEST as the
  -- threat), and the predicted point is pinned against what the tick actually wrote.
  select m.action, m.new_x, m.new_y into v_arm_engine, v_pred_x, v_pred_y
    from public.combat_units u, public.combat_units f,
         lateral public.combat_unit_decide_move(
           -- THROUGH THE FREEZE, exactly as the tick does. This is a FACT ABOUT THE CODE, not a
           -- theory: process_combat_ticks never hands the mover the table's doubles. It builds a
           -- jsonb snapshot of the population first (jsonb_build_object('pos_x', cu2.pos_x, ...))
           -- and reads every mover argument back out of THAT. So a prediction made from the raw
           -- columns is predicting a different call than the one the engine makes.
           -- WHAT I VERIFIED, AND WHAT I DID NOT: CI failed here printing a tick-write and a
           -- prediction that were IDENTICAL at display precision, so they differ below it. The
           -- server runs at extra_float_digits = 0 (fifteen significant digits) — but a spot check
           -- against production showed a 15-digit coordinate round-tripping through jsonb EXACTLY,
           -- so "the round-trip is always lossy" is NOT established and is not claimed here. What is
           -- established is the call path. Routing the prediction through the same freeze makes this
           -- an exact model of what the engine does either way, with no tolerance and no epsilon; if
           -- the round-trip is exact for these values the pin is unchanged, and if it is not, the
           -- pin is now right. CI is what decides, and it is cheap to be right for both reasons.
           (to_jsonb(u.pos_x)#>>'{}')::double precision, (to_jsonb(u.pos_y)#>>'{}')::double precision,
           coalesce((select min((w->>'range')::double precision) from jsonb_array_elements(u.weapons_json) w), 0),
           coalesce(u.move_speed, 0),
           (to_jsonb(f.pos_x)#>>'{}')::double precision, (to_jsonb(f.pos_y)#>>'{}')::double precision,
           coalesce((select max((w->>'range')::double precision) from jsonb_array_elements(f.weapons_json) w), 0)) m
   where u.id = u_bare and f.id = u_en;
  if v_arm_engine is null then
    raise exception 'HOLD FAIL: the engine mover returned no arm for the holding hull — a NULL arm would make every comparison below vacuous';
  end if;
  if v_arm_engine is distinct from 'hold' then
    raise exception 'HOLD FAIL: the ENGINE says % where this block derived hold (gap %, own reach %, wave reach %) — either the harness mirror has drifted from combat_unit_decide_move, or the hull is inside its own reach but outside the wave''s, which is KITE with a vanishing step and not stillness at all',
      v_arm_engine, v_gap, (select arm_my from pg_temp.cs_arm(u_bare, u_en)), (select arm_foe from pg_temp.cs_arm(u_bare, u_en));
  end if;

  perform pg_temp.cs_tick(v_enc);
  select pos_x, pos_y into v_x1, v_y1 from public.combat_units where id = u_bare;
  if v_x0 is null or v_y0 is null or v_x1 is null or v_y1 is null then
    raise exception 'HOLD FAIL: the fallback escort has a NULL coordinate (pre %,% / post %,%) — an unpositioned unit cannot prove it stood still', v_x0, v_y0, v_x1, v_y1;
  end if;
  -- the tick wrote exactly what the engine own leaf predicted...
  if v_x1 is distinct from v_pred_x or v_y1 is distinct from v_pred_y then
    raise exception 'HOLD FAIL: the tick wrote (%, %) where combat_unit_decide_move predicted (%, %) — the tick is not composing the mover it is supposed to',
      to_char(v_x1, 'FM999999990.999999999999999999'), to_char(v_y1, 'FM999999990.999999999999999999'),
      to_char(v_pred_x, 'FM999999990.999999999999999999'), to_char(v_pred_y, 'FM999999990.999999999999999999');
  end if;
  -- ...and for the HOLD arm that prediction is the hull's own position, unchanged — but unchanged AS
  -- THE FREEZE SEES IT. The mover's hold arm returns its p_my_x argument verbatim, and that argument
  -- came through the jsonb snapshot, so a holding hull is rewritten with the round-trip of itself.
  -- The comparison is therefore against that round-trip and is still EXACT: no tolerance, no epsilon.
  -- Rendered at full scale so a sub-display-precision move can never again read as no move at all.
  if v_x1 is distinct from (to_jsonb(v_x0)#>>'{}')::double precision
     or v_y1 is distinct from (to_jsonb(v_y0)#>>'{}')::double precision then
    raise exception 'HOLD FAIL: the holding hull moved (%, % -> %, %; the freeze round-trip of the start point is %, %) — a HOLD must leave the position exactly as the freeze presented it (rendered at full scale: the server prints only 15 significant digits, which is how a vanishing KITE step once read as no move at all)',
      to_char(v_x0, 'FM999999990.999999999999999999'), to_char(v_y0, 'FM999999990.999999999999999999'),
      to_char(v_x1, 'FM999999990.999999999999999999'), to_char(v_y1, 'FM999999990.999999999999999999'),
      to_char((to_jsonb(v_x0)#>>'{}')::double precision, 'FM999999990.999999999999999999'),
      to_char((to_jsonb(v_y0)#>>'{}')::double precision, 'FM999999990.999999999999999999');
  end if;
  raise notice 'COMBATSPATIAL_PASS_HOLD ok: the fallback escort closed over % guarded CLOSE tick(s) at its frozen speed %, arrived at gap % — inside its own reach and inside the wave''s — and its position is BYTE-IDENTICAL across the next tick (HOLD never touches pos_x/pos_y)', v_steps, v_speed, v_gap;
end $$;

-- ════════ SCREEN: the wave can now reach a player — the aggro-tier screen must hold ════════════════
do $$
declare
  n int; v_enc uuid := (select v from cspatial where k='v_enc');
  u_cmd  uuid := (select v from cspatial where k='u_cmd');
  u_arm  uuid := (select v from cspatial where k='u_arm');
  u_bare uuid := (select v from cspatial where k='u_bare');
  v_hp_cmd double precision; v_hp_arm double precision; v_hp_bare double precision;
  v_b_cmd  double precision := (select v from cspatial_num where k='hp_cmd');
  v_b_arm  double precision := (select v from cspatial_num where k='hp_arm');
  v_b_bare double precision := (select v from cspatial_num where k='hp_bare');
begin
  select count(*) into n from public.combat_events
    where encounter_id = v_enc and event_type = 'missile_salvo' and source = 'pirate';
  if n < 1 then
    raise exception 'SCREEN FAIL: no pirate-sourced missile_salvo event by the end of the approach (want >= 1 — a hull closed inside the wave''s own reach, so it must have fired); with no pirate fire at all the screen below would be vacuous';
  end if;

  select hp_current into v_hp_cmd  from public.combat_units where id = u_cmd;
  select hp_current into v_hp_arm  from public.combat_units where id = u_arm;
  select hp_current into v_hp_bare from public.combat_units where id = u_bare;
  if v_hp_cmd is null or v_hp_arm is null or v_hp_bare is null
     or v_b_cmd is null or v_b_arm is null or v_b_bare is null then
    raise exception 'SCREEN FAIL: a hull hp or its tick-1 baseline is NULL (now %/%/%, baseline %/%/%) — every comparison below would be vacuous', v_hp_cmd, v_hp_arm, v_hp_bare, v_b_cmd, v_b_arm, v_b_bare;
  end if;

  -- the S1 aggro-tier screen: the LEAD (aggro 100) is NEVER a legal target while an escort (aggro 0)
  -- lives — its hp must be byte-identical to the tick-1 baseline.
  if v_hp_cmd is distinct from v_b_cmd then
    raise exception 'SCREEN FAIL: lead hp changed (%->%) while an escort still lives — aggro screening breached', v_b_cmd, v_hp_cmd;
  end if;
  -- and an escort took the hit instead.
  if v_hp_arm >= v_b_arm and v_hp_bare >= v_b_bare then
    raise exception 'SCREEN FAIL: neither escort took damage (arm %->%, bare %->%) — the wave fired, so an escort must have been hit', v_b_arm, v_hp_arm, v_b_bare, v_hp_bare;
  end if;

  raise notice 'COMBATSPATIAL_PASS_SCREEN ok: the wave fired % salvo(s) once a hull closed inside its reach, an escort took the hit (arm %->%, bare %->%), and the lead''s hp is byte-identical to its tick-1 baseline (%) — the S1 aggro-tier screen holds spatially', n, v_b_arm, v_hp_arm, v_b_bare, v_hp_bare, v_hp_cmd;
end $$;

do $$ begin raise notice 'COMBAT-SPATIAL PROOF PASSED'; end $$;

rollback;   -- self-rolling-back: ZERO persisted state (no COMMIT anywhere above).
