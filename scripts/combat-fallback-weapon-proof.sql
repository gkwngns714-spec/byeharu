-- COMBAT-FALLBACK — disposable proof for the player-fallback-weapon slice (migration 0262): a spatial
-- combat player ship with NO fitted weapon module but a positive attack_snapshot fires a SYNTHESIZED
-- basic weapon (power = attack_snapshot) instead of dealing ZERO damage. Driven through the REAL chain
-- (commission → mint/assign a captain for attack → send_ship_group_hunt → movement_settle_arrival →
-- combat_create_group_encounter → process_combat_ticks), never a hand-rolled combat_units/
-- group_sortie_members write.
--
-- ── THE BUG THIS PROVES FIXED ────────────────────────────────────────────────────────────────────────
-- process_combat_ticks (the tick) is a PURE CONSUMER of combat_units.weapons_json — its fire loop is
-- `for v_widx in 0 .. jsonb_array_length(weapons_json) - 1`, which never iterates over an empty array.
-- Before 0262, combat_create_group_encounter built a player ship's weapons_json SOLELY from fitted
-- range-carrying weapon modules, so a ship whose combat_power comes from a CAPTAIN (no weapon module
-- fitted) landed weapons_json='[]' and dealt ZERO damage in spatial mode. 0262 synthesizes ONE fallback
-- weapon from attack_snapshot when the fitted array is empty.
--
-- ══ 0336 REPOINT — RING 500 NO LONGER MEANS "THE ESCORT IS OUT OF RANGE" ═════════════════════════
-- This file's whole attribution used to rest on one sentence: "the command ship spawns AT the pirate,
-- dist 0, and the escort is parked 500 away." Both halves came from the SAME knob, because the wave
-- spawned ON the engagement anchor — the exact point the command ship stands on — so raising
-- spatial_formation_ring_radius moved ONLY the escort. 0336 ends that: the wave now spawns at
--     radius = spatial_formation_ring_radius + THE WAVE'S OWN WEAPON RANGE + 1,  the 0338 arrival phase (slots)
-- through combat_formation_point, so the ring moves the WAVE as well. At ring 500 the wave stands 511
-- from the anchor, i.e. 511 from s_fb, hundreds of units outside the synthesized weapon's reach —
-- s_fb would silently CLOSE all fight and never fire, and CFALLBACK_PASS_DAMAGE ("no player
-- missile_salvo on tick 1 — the fallback weapon did not fire") would raise on a correct engine. The
-- knob has not merely drifted; the sentence it expressed no longer parses.
--
-- AND THE TWO WITNESSES HAVE SWAPPED PLACES. The lead stands ON the anchor, a full radius Re from the
-- wave; every escort stands on the ring, a CHORD away — and the chord is always SHORTER than the
-- radius. So the escort is now the NEAR hull and the lead the FAR one, the exact inverse of the old
-- picture. "s_fb can reach and s_arm cannot" therefore cannot come from geometry alone any more: it
-- comes from the RANGE GAP between the two weapons, with the ring sized so the chord clears the
-- catalog gun. Both halves are DERIVED and asserted below, never assumed.
--
-- ── SCENARIO (engineered so the fallback ship is the SOLE damage source) ──────────────────────────────
-- One team of 2 ships (R = the owned ring, er = the wave's own weapon range, Re = R + er + 1):
--   • s_fb  — the elected LEAD (spawns ON the engagement anchor, i.e. exactly Re from the wave).
--             Carries a gunnery_veteran CAPTAIN (attack 4, folded into combat_power) but NO weapon
--             module fitted → its RAW fitted-weapon join is EMPTY (the pre-fix state — asserted
--             directly). 0262 synthesizes a basic_player_weapon (power = attack_snapshot = 4, range =
--             the combat_player_fallback_weapon_range knob — asserted knob-derived, never hard-coded),
--             and this harness OWNS that knob ABOVE Re so the synthesized weapon can actually reach.
--             That is the whole subject: an EMPTY fitted array still fires, and still deals damage.
--   • s_arm — an armed escort with a real autocannon_battery fitted, on the ring at radius R, hence a
--             CHORD from the wave — owned at 20, which puts that chord at 8.89 against the catalog
--             gun's 5, so it is OUTSIDE its own reach and CLOSEs (no fire) on tick 1. Its roles: the
--             "armed ship's weapons_json is UNCHANGED (real autocannon, not the fallback)" witness,
--             and the silent second hull that keeps the damage attribution clean.
-- The wave spawns on its phase-0.5 slot with weapon range owned at 2 and speed owned at 0 (so its
-- post-tick position IS its spawn point and this proof can pin that point EXACTLY through the same
-- leaf the tick composes). 0336 stands it at least its own range + 1 from EVERY player hull, so it
-- fires NOTHING on tick 1 — and that is now DERIVED from the measured distances rather than bought
-- with a big ring. Therefore the ONLY unit that can damage the pirate on tick 1 is s_fb's SYNTHESIZED
-- weapon — and the proof does not merely infer that, it reads the salvo event's own unit_id and
-- requires it to BE s_fb. combat_damage_variance_pct and combat_hit_variance_pct are zeroed for
-- determinism; enemy_hp_base is raised so the pirate survives.
--
-- ── PROPERTIES PROVEN (each a PASS marker below) ───────────────────────────────────────────────────────
--   CFALLBACK_PASS_PREFIX_EMPTY — s_fb's RAW fitted-weapon join (ship_module_fittings→module_types,
--                                 range not null) is EMPTY: pre-fix its weapons_json would be '[]', and
--                                 the tick's 0-length-safe fire loop would fire zero shots → zero damage.
--   CFALLBACK_PASS_SYNTH        — POST-fix: s_fb's weapons_json carries exactly ONE synthesized entry —
--                                 module_type_id='basic_player_weapon', power = attack_snapshot (4),
--                                 range / projectile_speed / cooldown equal to the dedicated player
--                                 basic-weapon KNOBS (derived at assert time, 0313 repoint), NOT the
--                                 enemy synthetic's numbers.
--   CFALLBACK_PASS_ARMED        — s_arm (real autocannon fitted) keeps its own weapons_json: exactly one
--                                 entry, module_type_id='autocannon_battery', power/range equal to its
--                                 CATALOG row (derived at assert time) — the fallback did NOT
--                                 overwrite an already-armed ship.
--   CFALLBACK_PASS_DAMAGE       — after tick 1 the pirate's hp_current fell below its frozen hp_max,
--                                 and the attribution is now NAMED rather than inferred: the wave
--                                 stands exactly on combat_formation_point(anchor, ring + its OWN
--                                 range + 1, slot 0, the 0338 arrival phase) — pinned against a point predicted
--                                 from the knobs BEFORE the tick; s_fb's PRE-MOVE distance is inside
--                                 the synthesized weapon's own reach and s_arm's is outside its
--                                 catalog gun's; the derived count of in-reach player hulls is 1, the
--                                 observed tick-1 player salvo count equals it, and that salvo's own
--                                 payload unit_id IS s_fb's combat unit. The pirate fired nothing,
--                                 which is likewise derived (every hull is beyond its reach). So the
--                                 synthesized fallback weapon dealt the damage (NONZERO after the
--                                 fix, ZERO before).
--
-- Self-rolling-back (begin;...rollback;, no COMMIT); every dark flag flipped ONLY inside the txn;
-- provisioning is 100% real-RPC/real-writer (commission_first_main_ship / commission_additional_main_ship
-- / captains_mint_instance / assign_captain_to_ship / reward_grant / craft_module / fit_module_to_ship /
-- upsert_ship_group / assign_ship_to_group / set_fleet_command_ship / send_ship_group_hunt /
-- movement_settle_arrival); group_sortie_members and combat_units are NEVER hand-written. No session RNG
-- (the 0041 determinism law) — gen_random_uuid() is fixture identity only, never combat math.

\set ON_ERROR_STOP on

begin;   -- everything below is transient; the trailing ROLLBACK leaves ZERO persisted state.

create temp table cfb(k text primary key, v uuid) on commit preserve rows;

-- caller helper: set the authenticated subject then run an RPC, returning its jsonb.
create or replace function pg_temp.call_as(p_sub uuid, p_fn text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_fn into v;
  return v;
end $$;

-- ════════ SETUP: reveal starter ports (fresh disposable chain seeds them INACTIVE — commission hard-
--          requires Haven dockable), then one funded fixture player ════════════════════════════════════
do $$
declare r jsonb; uZ uuid;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: reveal_starter_ports %', r; end if;

  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'cfb.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uZ;
  insert into cfb values ('uZ', uZ);
  insert into public.player_wallet (player_id, balance) values (uZ, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
end $$;

-- dark capability gates — flipped ONLY inside this rolled-back txn (committed/production values stay
-- false; a fresh disposable chain has ALL of these seeded false, so every one is load-bearing here).
update public.game_config set value='true'::jsonb where key='team_command_enabled';
update public.game_config set value='true'::jsonb where key='mainship_additional_commission_enabled';
update public.game_config set value='true'::jsonb where key='module_crafting_enabled';
update public.game_config set value='true'::jsonb where key='module_fitting_enabled';
update public.game_config set value='true'::jsonb where key='captain_assignment_enabled';
update public.game_config set value='true'::jsonb where key='spatial_combat_enabled';
-- combat_telegraph stays DARK — OWNED here, not inherited (0300 lit it in the chain seeds, after
-- this proof was written; a lit telegraph queues the encounter instead of opening it inline at the
-- settle, and the attribution scenario observes the inline opening). The danger-combat-proof idiom.
update public.game_config set value='false'::jsonb where key='combat_telegraph_enabled';

-- tuning knobs (numeric, not capability gates) — all reverted by ROLLBACK. The engineered geometry
-- (header) depends on these EXACT values.
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
  perform public.set_game_config('enemy_hp_base', '1000'::jsonb);                    -- pirate survives the fallback hit
  -- ── THE 0336 GEOMETRY, OWNED (see the header: ring 500 stopped expressing anything) ─────────────
  -- The wave now stands at (ring + its own range + 1) on a phase-0.5 slot, so the ring moves the WAVE
  -- as well as the escort. What this scenario needs is one hull able to reach it and one not, and
  -- after 0336 that separation is a RANGE gap, not a ring: the lead sits at the full radius Re = 23
  -- and the escort a chord away at 8.89. So the ring is sized to put that chord clear of the catalog
  -- gun (8.89 > 5 — s_arm silent), and the synthesized weapon's own range is owned above Re (30 > 23
  -- — s_fb can reach). Both comparisons are re-derived and asserted in the DAMAGE block; these
  -- numbers are the intent, the asserts are the evidence.
  perform public.set_game_config('spatial_formation_ring_radius', '20'::jsonb);
  perform public.set_game_config('combat_player_fallback_weapon_range', '30'::jsonb);
  perform public.set_game_config('enemy_synthetic_range_base', '2'::jsonb);          -- er: the wave's own reach
  perform public.set_game_config('enemy_synthetic_range_per_difficulty', '0'::jsonb);
  -- THE WAVE DOES NOT MOVE: with its speed owned at 0 its post-tick position IS its spawn point, so
  -- the DAMAGE block can pin that point EXACTLY through combat_formation_point instead of measuring
  -- against a position the tick has already had a chance to change. 0336's "outside every player
  -- hull's reach by construction" invariant is then read off the spawn geometry itself.
  perform public.set_game_config('enemy_synthetic_speed_base', '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', '0'::jsonb);
end $$;

-- ════════ PROVISION: 2 ships via the real commission RPCs; s_fb gets a CAPTAIN (attack, NO weapon),
--          s_arm gets a real autocannon; a real team with s_fb designated command ════════════════════
do $$
declare
  r jsonb;
  uZ uuid := (select v from cfb where k='uZ');
  s_fb uuid; s_arm uuid;
  v_cap uuid; v_mod_arm uuid;
begin
  r := pg_temp.call_as(uZ, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL first ship: %', r; end if;
  select main_ship_id into s_fb from public.main_ship_instances where player_id = uZ;

  r := pg_temp.call_as(uZ, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then
    raise exception 'PROVISION FAIL 2nd ship: %', r; end if;
  s_arm := (r->>'main_ship_id')::uuid;

  insert into cfb values ('s_fb', s_fb), ('s_arm', s_arm);

  -- s_arm: a real autocannon_battery — the "armed ship weapons_json unchanged" witness. Fund the
  -- recipe (weapon_parts x4, pirate_alloy x2, scrap x6 — the S0/0107 seed) via the real Reward writer.
  -- ── CRAFTED HERE, BEFORE THE NORMALIZATION BELOW (0333) ──────────────────────────────────────
  -- Items live PER PORT now (`base_items`) and `craft_module` derives the port it spends from the
  -- crafting ship's VALIDATED DOCK. The normalization below retires the commission fleets, which is
  -- exactly what stops a ship being 'at_location' — a craft after it would answer `not_docked`. So
  -- the craft happens while both ships are still docked at Haven Reach, and it NAMES s_arm: uZ owns
  -- TWO ships, so the sole-ship shim cannot resolve one and would answer `ship_not_found`. A NULL
  -- base on the grant lands in uZ's oldest active base — the Home Base, whose location_id IS Haven
  -- — i.e. the same store the craft draws on. Fitting is legal at 'at_location' too (0114's
  -- settled-SAFE set is ('home','at_location')), so it moves up unchanged with the craft.
  perform public.reward_grant('combat', gen_random_uuid(), uZ, null,
    '{"items": [{"item_id": "weapon_parts", "quantity": 4}, {"item_id": "pirate_alloy", "quantity": 2}, {"item_id": "scrap", "quantity": 6}]}'::jsonb);
  r := pg_temp.call_as(uZ, format('public.craft_module(''cfb-gun-1'', ''autocannon_battery'', %L::uuid)', s_arm));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL craft gun: %', r; end if;
  v_mod_arm := (r->>'instance_id')::uuid;
  r := pg_temp.call_as(uZ, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''cfb-fit-1'')', v_mod_arm, s_arm));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL fit gun: %', r; end if;

  -- FIXTURE NORMALIZATION — retire each ship's commission 'present' fleet + complete its presence (the
  -- team-command/combat-spatial-proof precedent, verbatim): send_ship_group_hunt's dark-path readiness
  -- gate treats a fleet-truth-docked member as NOT ready, so a team fleet on top of a live dock fleet
  -- would be a phantom second fleet. This leaves each ship settled-SAFE ('home') — the state both
  -- fit_module_to_ship and assign_captain_to_ship require.
  update public.main_ship_instances
     set status = 'home', updated_at = now()
   where main_ship_id in (s_fb, s_arm);
  update public.fleets
     set status = 'destroyed', location_mode = 'destroyed', active_movement_id = null,
         current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
         updated_at = now()
   where main_ship_id in (s_fb, s_arm) and status = 'present';
  update public.location_presence
     set status = 'completed', updated_at = now()
   where fleet_id in (select id from public.fleets
                        where main_ship_id in (s_fb, s_arm) and status = 'destroyed')
     and status = 'active';

  -- s_fb: a gunnery_veteran captain (0117: stats_json attack 4) via the real writers — combat_power
  -- WITHOUT any weapon module fitted (the production scenario). Mint (service_role writer) + assign
  -- (client wrapper, owner-scoped).
  v_cap := public.captains_mint_instance(uZ, 'gunnery_veteran', 'cfb-cap-1');
  if v_cap is null then raise exception 'PROVISION FAIL mint captain: null'; end if;
  r := pg_temp.call_as(uZ, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid, %L)', 'cfb-assign-1', v_cap, s_fb, 'gunnery'));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL assign captain: %', r; end if;
  -- s_fb gets NO weapon module — its RAW fitted-weapon join must stay EMPTY (the fallback trigger).

  -- form the team, assign both, designate s_fb the command ship — 0315 elects it the LEAD, so it
  -- spawns ON the engagement anchor, a full radius from the wave's phase-0.5 ring slot.
  r := pg_temp.call_as(uZ, 'public.upsert_ship_group(1, ''Fallback'')');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL group create: %', r; end if;
  insert into cfb values ('gZ', (r->>'group_id')::uuid);
  r := pg_temp.call_as(uZ, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_fb,  (select v from cfb where k='gZ')));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL assign fb: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_arm, (select v from cfb where k='gZ')));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL assign arm: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.set_fleet_command_ship(%L::uuid, true)', s_fb));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL designate command: %', r; end if;

  raise notice 'setup ok: s_fb (captain attack, NO weapon, command) + s_arm (real autocannon escort) provisioned';
end $$;

-- ════════ SEND + SETTLE: the real chain ═══════════════════════════════════════════════════════════════
do $$
declare
  r jsonb; n int;
  uZ uuid := (select v from cfb where k='uZ');
  gZ uuid := (select v from cfb where k='gZ');
  v_hunt uuid; v_fleet uuid; v_mv uuid; v_enc uuid;
begin
  select id into v_hunt from public.locations
    where activity_type = 'hunt_pirates' and status = 'active'
    order by min_power_required asc, base_difficulty asc limit 1;
  if v_hunt is null then raise exception 'SEND FAIL: no active hunt_pirates location'; end if;
  insert into cfb values ('v_hunt', v_hunt);

  r := pg_temp.call_as(uZ, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gZ, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'SEND FAIL: %', r; end if;
  v_fleet := (r->>'fleet_id')::uuid; v_mv := (r->>'movement_id')::uuid;
  if v_fleet is null or v_mv is null then raise exception 'SEND FAIL envelope: %', r; end if;

  select count(*) into n from public.group_sortie_members where fleet_id = v_fleet;
  if n <> 2 then raise exception 'SEND FAIL: % manifest rows (want 2)', n; end if;

  update public.fleet_movements
     set depart_at = now() - interval '2 minutes', arrive_at = now() - interval '1 minute'
   where id = v_mv;
  r := public.movement_settle_arrival(v_mv);
  if (r->>'settled')::boolean is not true or (r->>'outcome') is distinct from 'present' then
    raise exception 'SEND FAIL settle: %', r; end if;

  select id into v_enc from public.combat_encounters where fleet_id = v_fleet and status = 'active';
  if v_enc is null then raise exception 'SEND FAIL: no active encounter after arrival'; end if;
  insert into cfb values ('v_enc', v_enc);
  raise notice 'setup ok: sortie sent, settled, encounter % active', v_enc;
end $$;

-- ════════ BLOCK PREFIX_EMPTY + SYNTH + ARMED: the creator's fallback hunk landed correctly ═══════════
do $$
declare
  n int; v_enc uuid := (select v from cfb where k='v_enc');
  s_fb uuid := (select v from cfb where k='s_fb');
  s_arm uuid := (select v from cfb where k='s_arm');
  v_attack_fb double precision; v_wc int;
  v_mid text; v_power double precision; v_range double precision; v_pspeed double precision; v_cd double precision;
  v_tick text;
  -- expected values DERIVED at assert time (0313 repoint: the old form hard-coded the 150/300/2 and
  -- 10/150 seeds — ambient defaults this proof never owned): the fallback entry must equal the
  -- knobs the creator reads, the fitted entry must equal its catalog row.
  v_exp_range double precision; v_exp_pspeed double precision; v_exp_cd double precision;
  v_cat record;
  v_attack_arm double precision;   -- 0317: the armed ship's own folded combat_power (see ARMED)
begin
  v_exp_range  := coalesce(public.cfg_num('combat_player_fallback_weapon_range'), 150);
  v_exp_pspeed := coalesce(public.cfg_num('combat_player_fallback_weapon_projectile_speed'), 300);
  v_exp_cd     := coalesce(public.cfg_num('combat_player_fallback_weapon_cooldown_seconds'), 2);
  select * into v_cat from public.module_types where id = 'autocannon_battery';
  -- ── PREFIX_EMPTY: s_fb's RAW fitted-weapon join (what the pre-0262 creator used) is EMPTY. ──────────
  select count(*) into n
    from public.ship_module_fittings f
    join public.module_instances i on i.id = f.module_instance_id
    join public.module_types t     on t.id = i.module_type_id
   where f.main_ship_id = s_fb and t.range is not null;
  if n <> 0 then raise exception 'PREFIX_EMPTY FAIL: s_fb has % fitted range-weapon module(s) (want 0 — the fallback trigger requires an empty fitted array)', n; end if;
  -- and the tick fires SOLELY from weapons_json via a 0-length-safe loop — so an empty array = zero
  -- shots = zero damage (the pre-fix behavior). Pin the loop token in the live tick source.
  select prosrc into v_tick from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'process_combat_ticks';
  if v_tick is null or position('jsonb_array_length(v_weapons_json) - 1' in v_tick) = 0 then
    raise exception 'PREFIX_EMPTY FAIL: process_combat_ticks does not fire from weapons_json via the 0-length-safe loop';
  end if;
  raise notice 'CFALLBACK_PASS_PREFIX_EMPTY ok: s_fb''s raw fitted-weapon join is empty (pre-fix weapons_json=[]); the tick fires only from weapons_json via `for v_widx in 0..jsonb_array_length-1`, so an empty array = zero shots = zero damage';

  -- ── SYNTH: POST-fix s_fb carries exactly ONE synthesized fallback weapon, power = attack_snapshot. ──
  select attack_snapshot, jsonb_array_length(weapons_json) into v_attack_fb, v_wc
    from public.combat_units where encounter_id = v_enc and main_ship_id = s_fb;
  if v_attack_fb is null or v_attack_fb <= 0 then
    raise exception 'SYNTH FAIL: s_fb attack_snapshot is % (want > 0 — the captain must contribute combat_power)', v_attack_fb; end if;
  if v_wc <> 1 then raise exception 'SYNTH FAIL: s_fb weapons_json has % entries (want exactly 1 synthesized)', v_wc; end if;
  select weapons_json->0->>'module_type_id',
         (weapons_json->0->>'power')::double precision,
         (weapons_json->0->>'range')::double precision,
         (weapons_json->0->>'projectile_speed')::double precision,
         (weapons_json->0->>'cooldown_seconds')::double precision
    into v_mid, v_power, v_range, v_pspeed, v_cd
    from public.combat_units where encounter_id = v_enc and main_ship_id = s_fb;
  if v_mid <> 'basic_player_weapon' then raise exception 'SYNTH FAIL: fallback module_type_id is % (want basic_player_weapon)', v_mid; end if;
  if v_power is distinct from v_attack_fb then raise exception 'SYNTH FAIL: fallback power % <> attack_snapshot %', v_power, v_attack_fb; end if;
  if v_range <> v_exp_range or v_pspeed <> v_exp_pspeed or v_cd <> v_exp_cd then
    raise exception 'SYNTH FAIL: fallback range/projectile/cooldown = %/%/% (want %/%/% — the player basic-weapon knobs, derived at assert time)', v_range, v_pspeed, v_cd, v_exp_range, v_exp_pspeed, v_exp_cd; end if;
  raise notice 'CFALLBACK_PASS_SYNTH ok: s_fb synthesized ONE basic_player_weapon (power=% = attack_snapshot, range %, projectile %, cooldown % — all knob-derived)', v_power, v_range, v_pspeed, v_cd;

  -- ── ARMED: s_arm (real autocannon fitted) keeps its OWN weapons_json — the fallback did NOT touch it.
  select jsonb_array_length(weapons_json), weapons_json->0->>'module_type_id', (weapons_json->0->>'power')::double precision, (weapons_json->0->>'range')::double precision
    into v_wc, v_mid, v_power, v_range
    from public.combat_units where encounter_id = v_enc and main_ship_id = s_arm;
  if v_wc <> 1 then raise exception 'ARMED FAIL: s_arm weapons_json has % entries (want exactly 1 real autocannon)', v_wc; end if;
  if v_mid <> 'autocannon_battery' then raise exception 'ARMED FAIL: s_arm weapon is % (want autocannon_battery — the fallback overwrote a fitted weapon!)', v_mid; end if;
  -- 0317 REPOINT — power is no longer a catalog COPY, so this stops comparing it to one. The gun's
  -- RANGE is still pinned to the catalog row byte-for-byte (that is what a weapon decides), but its
  -- power is the ship's own folded combat_power times its share, and with one gun fitted the share
  -- is 1. Read s_arm's attack_snapshot and require the identity — plus the pin that the fold and the
  -- catalog weight actually DIFFER, without which the pre-0317 flat copy would satisfy this line and
  -- the repoint would have quietly thrown the property away.
  select attack_snapshot into v_attack_arm from public.combat_units
   where encounter_id = v_enc and main_ship_id = s_arm;
  if v_attack_arm is null or v_attack_arm <= 0 then
    raise exception 'ARMED FAIL: s_arm attack_snapshot is % — the power identity below would be vacuous', v_attack_arm; end if;
  if v_attack_arm = v_cat.power then
    raise exception 'ARMED FAIL: s_arm''s combat_power (%) equals the catalog share weight (%) — the identity below could be satisfied by the pre-0317 flat copy and would prove nothing', v_attack_arm, v_cat.power; end if;
  if v_power is distinct from v_attack_arm then
    raise exception 'ARMED FAIL: s_arm''s fitted autocannon fires % but the ship''s folded combat_power is % — the catalog is still deciding damage (0317: the fold decides HOW MUCH, the weapon decides HOW)', v_power, v_attack_arm; end if;
  if v_range <> v_cat.range then
    raise exception 'ARMED FAIL: s_arm autocannon range = % (want % — the catalog row, derived at assert time)', v_range, v_cat.range; end if;
  raise notice 'CFALLBACK_PASS_ARMED ok: s_arm keeps its real autocannon_battery — the catalog RANGE % byte-for-byte, and power % = its own folded combat_power (0317), not the catalog share weight %', v_range, v_power, v_cat.power;
end $$;

-- ════════ BLOCK DAMAGE: tick 1 — the synthesized weapon deals REAL damage to the pirate ═══════════════
do $$
declare
  n int; v_enc uuid := (select v from cfb where k='v_enc');
  s_fb uuid := (select v from cfb where k='s_fb');
  s_arm uuid := (select v from cfb where k='s_arm');
  u_fb uuid; u_arm uuid; u_en uuid;
  v_anchor_x double precision; v_anchor_y double precision; v_diff double precision;
  v_site_x double precision; v_site_y double precision;  -- (0338) the zone's own city
  v_ring double precision; v_er_pred double precision;
  v_px double precision; v_py double precision;      -- the PREDICTED wave slot-0 point
  v_ex double precision; v_ey double precision;      -- where the wave actually stands
  v_fb_x double precision; v_fb_y double precision;
  v_arm_x double precision; v_arm_y double precision;
  v_dist_fb double precision; v_dist_arm double precision;
  v_r_fb double precision; v_r_arm double precision; v_r_en double precision;
  v_e_hpmax double precision; v_e_hpcur double precision;
  v_pirate_fire int; v_exp_fire int; v_firer uuid;
  v_hp_fb0 double precision; v_hp_arm0 double precision; v_hp_fb1 double precision; v_hp_arm1 double precision;
begin
  -- THE ENGAGEMENT ANCHOR, resolved exactly as the tick resolves it
  -- (v_anchor_x := coalesce(e.engagement_x, loc.x), 0294/0299) — never the location row alone.
  select coalesce(e.engagement_x, l.x), coalesce(e.engagement_y, l.y), l.base_difficulty, l.x, l.y
    into v_anchor_x, v_anchor_y, v_diff, v_site_x, v_site_y
    from public.combat_encounters e join public.locations l on l.id = e.location_id
   where e.id = v_enc;
  v_ring := public.cfg_num('spatial_formation_ring_radius');
  -- 0336's spawn geometry, PREDICTED from the knobs BEFORE the tick, through the very leaf the tick
  -- composes: radius = ring + the wave's OWN range + 1, slot 0, the arrival phase. Predicting first
  -- and comparing after is what makes this a pin on 0336 rather than a restatement of the row.
  -- 0338 REPOINTED: the phase is the bearing to this encounter's OWN site, taken from the one
  -- authority (combat_wave_arrival_phase) at the same arguments the tick composes it with. The radius
  -- is untouched, so the LEAD's distance to the wave — the full radius, because the lead stands on
  -- the anchor — is unchanged; only the direction moves.
  v_er_pred := coalesce(public.cfg_num('enemy_synthetic_range_base'), 120)
               + v_diff * coalesce(public.cfg_num('enemy_synthetic_range_per_difficulty'), 5);
  if v_anchor_x is null or v_anchor_y is null or v_ring is null or v_er_pred is null then
    raise exception 'DAMAGE FAIL: anchor (%,%), ring % or predicted wave range % is NULL — every distance below would be vacuous', v_anchor_x, v_anchor_y, v_ring, v_er_pred;
  end if;
  select fp.x, fp.y into v_px, v_py
    from public.combat_formation_point(v_anchor_x, v_anchor_y, v_ring + v_er_pred + 1, 0,
           public.combat_wave_arrival_phase(v_anchor_x, v_anchor_y, v_site_x, v_site_y, 0)) fp;

  -- the PRE-MOVE player positions and each hull's own frozen reach (its weapons_json, never the
  -- catalog): 0299's fire gate compares the PRE-MOVE distance, so that is what attribution must use.
  select id, pos_x, pos_y, hp_current into u_fb,  v_fb_x,  v_fb_y,  v_hp_fb0
    from public.combat_units where encounter_id = v_enc and main_ship_id = s_fb;
  select id, pos_x, pos_y, hp_current into u_arm, v_arm_x, v_arm_y, v_hp_arm0
    from public.combat_units where encounter_id = v_enc and main_ship_id = s_arm;
  select max((w->>'range')::double precision) into v_r_fb
    from public.combat_units cu, jsonb_array_elements(cu.weapons_json) w where cu.id = u_fb;
  select max((w->>'range')::double precision) into v_r_arm
    from public.combat_units cu, jsonb_array_elements(cu.weapons_json) w where cu.id = u_arm;
  v_dist_fb  := public.osn_distance(v_fb_x,  v_fb_y,  v_px, v_py);
  v_dist_arm := public.osn_distance(v_arm_x, v_arm_y, v_px, v_py);
  if v_r_fb is null or v_r_arm is null or v_dist_fb is null or v_dist_arm is null then
    raise exception 'DAMAGE FAIL: a frozen weapon range (fb %, arm %) or a pre-move distance (fb %, arm %) is NULL — the attribution below would be vacuous', v_r_fb, v_r_arm, v_dist_fb, v_dist_arm;
  end if;

  -- no enemy yet — wave 1 spawns and takes its first fire pass INSIDE this tick call.
  select count(*) into n from public.combat_units where encounter_id = v_enc and side = 'enemy';
  if n <> 0 then raise exception 'DAMAGE FAIL precondition: % enemy rows before the first tick (want 0)', n; end if;

  update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc;
  perform public.process_combat_ticks();

  -- exactly ONE synthetic pirate (danger 1), and it stands where 0336 puts it.
  select count(*) into n from public.combat_units where encounter_id = v_enc and side = 'enemy' and unit_type_id = 'pirate_synthetic';
  if n <> 1 then raise exception 'DAMAGE FAIL: % synthetic pirate row(s) (want exactly 1 — one unit means slot 0, which is the point pinned below)', n; end if;
  select id, pos_x, pos_y into u_en, v_ex, v_ey from public.combat_units where encounter_id = v_enc and side = 'enemy';
  select max((w->>'range')::double precision) into v_r_en
    from public.combat_units cu, jsonb_array_elements(cu.weapons_json) w where cu.id = u_en;
  if v_ex is null or v_ey is null or v_r_en is null then
    raise exception 'DAMAGE FAIL: the wave row is unpositioned or carries no range (pos %,%, range %) — the spawn-point pin would be vacuous', v_ex, v_ey, v_r_en;
  end if;
  if abs(v_r_en - v_er_pred) > 1e-9 then
    raise exception 'DAMAGE FAIL: the wave carries range % but the knobs predict % — the radius the distances were measured against was derived from the wrong reach', v_r_en, v_er_pred;
  end if;
  if abs(v_ex - v_px) > 1e-9 or abs(v_ey - v_py) > 1e-9 then
    raise exception 'DAMAGE FAIL: the wave stands at %,% but combat_formation_point(anchor, ring % + its own range % + 1, slot 0, the arrival phase) is %,% — 0336''s wave-spawn geometry is not what landed, so every pre-move distance above was measured to the wrong point', v_ex, v_ey, v_ring, v_r_en, v_px, v_py;
  end if;

  -- ── ATTRIBUTION, all of it DERIVED from the measured geometry ──────────────────────────────────
  -- (1) s_fb can reach: its PRE-MOVE distance (the full radius Re, because the lead stands on the
  --     anchor) is inside the SYNTHESIZED weapon's own range. Without this the DAMAGE assert below
  --     would be testing an engine that never fired at all.
  if v_dist_fb > v_r_fb then
    raise exception 'DAMAGE FAIL attribution: s_fb is % from the wave, OUTSIDE its own synthesized % range — after 0336 the lead opens at (ring + the wave''s range + 1), so the fallback range must be owned above that or this proof''s subject never fires', v_dist_fb, v_r_fb;
  end if;
  -- (2) s_arm cannot: its chord to the wave is outside its own catalog gun, so it CLOSEs in silence.
  if v_dist_arm <= v_r_arm then
    raise exception 'DAMAGE FAIL attribution: s_arm is % from the wave, within its % range (it would fire and muddy attribution) — after 0336 the escort is the NEAR hull, so the ring must be owned large enough that its chord clears the catalog gun', v_dist_arm, v_r_arm;
  end if;
  -- (3) the wave reaches nobody: 0336 stands it at least its own range + 1 from EVERY player hull.
  if least(v_dist_fb, v_dist_arm) <= v_r_en then
    raise exception 'DAMAGE FAIL attribution: the nearest player hull is % from the wave, inside its own % reach — 0336''s spawn invariant does not hold in this world and the pirate could fire', least(v_dist_fb, v_dist_arm), v_r_en;
  end if;
  select count(*) into v_pirate_fire from public.combat_events
    where encounter_id = v_enc and tick_number = 1 and event_type = 'missile_salvo' and source = 'pirate';
  if v_pirate_fire <> 0 then raise exception 'DAMAGE FAIL attribution: pirate fired % time(s) on tick 1 (want 0 — every player hull is outside its own reach at spawn)', v_pirate_fire; end if;

  -- (4) exactly ONE player hull was in reach, so exactly one player salvo — and it is s_fb's. Each
  --     hull here carries exactly one weapon (asserted above), so the derived count IS the salvo
  --     count, and the event's own payload names the firer rather than leaving it to be inferred.
  v_exp_fire := (case when v_dist_fb  <= v_r_fb  then 1 else 0 end)
              + (case when v_dist_arm <= v_r_arm then 1 else 0 end);
  if v_exp_fire <> 1 then
    raise exception 'DAMAGE FAIL attribution: the derivation expects % in-reach player hull(s) on tick 1 (want exactly 1 — s_fb alone)', v_exp_fire;
  end if;
  select count(*) into n from public.combat_events
    where encounter_id = v_enc and tick_number = 1 and event_type = 'missile_salvo' and source = 'player';
  if n < 1 then raise exception 'DAMAGE FAIL: no player missile_salvo on tick 1 (the fallback weapon did not fire)'; end if;
  if n <> v_exp_fire then
    raise exception 'DAMAGE FAIL attribution: % player missile_salvo event(s) on tick 1, derivation expects % (pre-move distances fb %, arm % against reaches %, %)', n, v_exp_fire, v_dist_fb, v_dist_arm, v_r_fb, v_r_arm;
  end if;
  select (payload_json->>'unit_id')::uuid into v_firer from public.combat_events
    where encounter_id = v_enc and tick_number = 1 and event_type = 'missile_salvo' and source = 'player';
  if v_firer is distinct from u_fb then
    raise exception 'DAMAGE FAIL attribution: the tick-1 player salvo came from unit % , not from s_fb''s unit % — the damage below is not the synthesized weapon''s', v_firer, u_fb;
  end if;

  -- the pirate's hp fell below its frozen max: the synthesized weapon dealt REAL damage.
  select hp_max, hp_current into v_e_hpmax, v_e_hpcur from public.combat_units where id = u_en;
  if v_e_hpcur >= v_e_hpmax then
    raise exception 'DAMAGE FAIL: pirate hp_current (%) is not below hp_max (%) — the fallback weapon dealt ZERO damage', v_e_hpcur, v_e_hpmax; end if;

  -- and no player ship was hit (the pirate fired nothing) — a clean tick.
  select hp_current into v_hp_fb1  from public.combat_units where id = u_fb;
  select hp_current into v_hp_arm1 from public.combat_units where id = u_arm;
  if v_hp_fb1 is distinct from v_hp_fb0 or v_hp_arm1 is distinct from v_hp_arm0 then
    raise exception 'DAMAGE FAIL: a player ship took damage on tick 1 (pirate should have fired nothing)'; end if;

  raise notice 'CFALLBACK_PASS_DAMAGE ok: tick 1 — the wave stands exactly on combat_formation_point(anchor, ring % + its own range % + 1, slot 0, the 0338 arrival phase); pirate hp fell %->% (NONZERO, from s_fb''s synthesized weapon ALONE — the single tick-1 player salvo carries s_fb''s own unit id, s_fb in reach at pre-move dist % against its synthesized %, s_arm out of reach at % against its catalog %, pirate fired 0); pre-fix (empty weapons_json) this ship would have dealt ZERO', v_ring, v_r_en, v_e_hpmax, v_e_hpcur, v_dist_fb, v_r_fb, v_dist_arm, v_r_arm;
end $$;

do $$ begin raise notice 'COMBAT-FALLBACK PROOF PASSED'; end $$;

rollback;   -- self-rolling-back: ZERO persisted state (no COMMIT anywhere above).
