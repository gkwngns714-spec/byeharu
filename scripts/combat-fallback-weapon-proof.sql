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
--   CFALLBACK_PASS_DAMAGE       — (0351 REPOINTED — the old per-hull attribution INVERTED) THE RULE
--                                 first: combat_fleet_actor(enc).reach = least(the unarmed lead's
--                                 synthesized fallback, the armed escort's catalog gun). The
--                                 fallback participates in the fold on exactly equal terms with a
--                                 catalog gun, and whichever is SHORTER is the fleet's one circle —
--                                 here the CATALOG gun, which is the reverse of the "an unarmed hull
--                                 drags the fleet down" direction that danger-combat-proof's
--                                 DZCOMBAT_PASS_SHORTGUN proves. Both are the same rule, so the rule
--                                 is what is asserted. Then: the wave stands exactly on
--                                 combat_formation_point(anchor, ring + its OWN range + 1, slot 0,
--                                 the 0338 arrival phase), predicted BEFORE the tick; tick 1 is
--                                 SILENT and the pirate's hp is UNTOUCHED (the old per-hull gate
--                                 fired the fallback there, because 23 <= its own 30); the fleet then
--                                 closes for exactly ceil((gap - reach) / fleet speed) ticks —
--                                 DERIVED from the engine's own recurrence over the frozen rows,
--                                 never a literal index — every one of them silent; and on the
--                                 arrival tick BOTH hulls fire together, the fallback salvo carrying
--                                 s_fb's own unit id and the basic_player_weapon projectile type,
--                                 with the wave's hp falling by EXACTLY the sum of the two frozen
--                                 0331 power shares. Pre-0262 (weapons_json = []) that sum is short
--                                 by the fallback's whole share — the original defect, still caught,
--                                 still by a number. 47 production hulls carry no weapon at all, so
--                                 this is also the guard that screams if the aggregate is ever
--                                 changed without them in mind.
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

-- ── THE ONE AUTHORITY IN THIS HARNESS FOR "ADVANCE ONE TICK" (0351) ──────────────────────────────
-- Until 0351 this file drove exactly one tick, inline. The fleet's circle is now folded to
-- least(fallback, catalog gun), so the DAMAGE block is an APPROACH of a DERIVED number of ticks and
-- the clock rewind + the cron leaf have to be one composable thing rather than a copied couplet: a
-- rewind without the call advances nothing, a call without the rewind is a no-op because the
-- encounter is not due yet. ONE textual process_combat_ticks() call site in the whole file, which is
-- what the .sh gate counts — the combat-spatial-proof (pg_temp.cs_tick) and danger-combat-proof
-- (pg_temp.ae_tick) idiom, mirrored rather than re-invented.
create or replace function pg_temp.cfb_tick(p_enc uuid) returns void language plpgsql as $$
begin
  update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = p_enc;
  perform public.process_combat_ticks();
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
  -- ── 0346: THIS SUITE OWNS THE INGRESS DURATION, IT DOES NOT INHERIT IT ────────────────────────
  -- 0346 makes an enemy body spawn AT its zone's city and travel in over combat_enemy_ingress_ticks
  -- ticks, arriving on the same engagement boundary it used to be PLACED on. Every geometry,
  -- closing-tick and first-salvo property in this file is about a body that is already at that
  -- boundary, so this suite states the precondition it depends on instead of inheriting whatever
  -- the seed happens to carry (the proofs-never-assert-ambient-defaults law). 0 means "no ingress":
  -- the spawn takes its degenerate arm and places the body on the boundary directly, which is
  -- byte-identical to the pre-0346 engine. A block that wants to test the INGRESS itself must set
  -- this to a positive value for itself and say so.
  perform public.set_game_config('combat_enemy_ingress_ticks', '0'::jsonb);
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
  -- ── 0351 FORCES THIS SUITE TO OWN THE PLAYER'S COMBAT SPEED ────────────────────────────────────
  -- Until 0351 the lead fired on tick 1 from where it spawned and nothing in this file ever moved,
  -- so the world-to-combat speed factor was irrelevant here. Now the fleet's circle is
  -- least(fallback 30, catalog 5) = 5 against a spawn radius of 23, so the DAMAGE block is an
  -- APPROACH and this knob decides how long it is: at the seeded 0.2 it would be dozens of ticks.
  -- 1 is the top of the band 0316's own self-assert declares legal (0 < scale <= 1), and it is read
  -- ONCE at encounter creation to freeze combat_units.move_speed — which is why it is set HERE, in
  -- setup, before the send/settle, and not inside the block that consumes it. The number of closing
  -- ticks is still DERIVED from the frozen row, never from this value.
  perform public.set_game_config('combat_player_speed_scale', '1'::jsonb);
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

-- ════════ BLOCK DAMAGE: the synthesized weapon deals REAL damage — and the fold that lets it ═══════
--
-- ── ██ 0351: THIS BLOCK'S ATTRIBUTION INVERTED, AND THE RULE REPLACES BOTH ANECDOTES ██ ──────────
-- WHAT IT PROTECTED: that on TICK 1 exactly ONE player hull was in reach — s_fb, the unarmed lead,
-- whose synthesized fallback (range owned at 30) covered the full spawn radius of 23 while s_arm's
-- catalog autocannon (5) did not cover its chord of 8.89 — so the single tick-1 salvo, and therefore
-- the pirate's hp loss, was s_fb's alone.
-- WHY IT INVERTS. 0351 folds the reach: the fleet's circle is `min` over its LIVING HULLS of `min`
-- over their guns, so this fleet's reach is least(30, 5) = 5 against a gap of 23. The fleet cannot
-- fire on tick 1 at all, and every one of the old attribution guards ("s_fb is in reach", "s_arm is
-- not", "the derivation expects exactly 1 in-reach hull") is a statement about a model that no
-- longer exists.
-- ██ AND NOTE WHICH WAY ROUND IT IS HERE. The cap comes from the ARMED escort's CATALOG GUN, not
-- from the unarmed hull's long fallback — the reverse of the "an unarmed hull drags the fleet down"
-- framing that the same fold produces elsewhere (danger-combat-proof's DZCOMBAT_PASS_SHORTGUN, where
-- a fitted hull's short gun caps a fleet whose unarmed escort reaches further). Both directions are
-- the SAME RULE, so this block asserts the rule rather than either anecdote:
--
--     combat_fleet_actor(enc).reach = least(v_r_fb, v_r_arm)
--
-- — the synthesized fallback participates in the fold on exactly equal terms with a catalog gun, and
-- whichever is shorter is the fleet's one circle. The fixture is deliberately the case where the
-- fallback is the LONGER of the two, so a fold that special-cased or skipped synthesized weapons
-- would still produce 5 here and pass; what would NOT pass is a fold that took the max (30), or the
-- lead's own (30), or the point-hull's own (30). Each of those is printed against the observed value
-- when this fails.
-- WHY THIS BLOCK MATTERS BEYOND ITS OWN SUITE: 47 production hulls carry no weapon at all. Every one
-- of them hands its fleet a synthesized fallback range as a candidate for the fleet's reach. This
-- assert is the guard that screams if someone changes the aggregate without thinking about them.
--
-- WHAT IT PROTECTS NOW, and every part of it fails the old engine:
--   • THE FOLD, above — combat_fleet_actor does not exist on the old body, and no per-hull gate
--     produces a single number that is least() over two hulls' weapons.
--   • TICK 1 IS SILENT. The old engine fired s_fb's fallback on tick 1 and damaged the pirate; the
--     new one cannot, at a gap of 23 against a circle of 5. 0 <> 1, and the pirate's hp is required
--     to be untouched where the old body had already reduced it.
--   • THE DAMAGE WITNESS MOVES TO THE DERIVED ARRIVAL TICK — ceil((gap - fleet reach) / fleet speed),
--     computed from the engine's own recurrence over this encounter's frozen rows, never a literal
--     index — and on that tick BOTH hulls fire (all-or-none), which the old per-hull gate never did
--     on any single tick in this geometry.
--   • THE SUBJECT STILL FIRES, AND ITS DAMAGE IS SEPARATED OUT AS A NUMBER. The pirate's hp falls by
--     EXACTLY the sum of the two frozen power shares, and the salvo carrying s_fb's own unit id and
--     the basic_player_weapon projectile type is required to be there. Pre-0262 (weapons_json = [])
--     that ship contributed nothing, so the sum would be short by the fallback's whole share.
--
-- ── THE ONE KNOB THIS REPOINT FORCES THE SUITE TO OWN ────────────────────────────────────────────
-- The approach is now 18 units long instead of zero, so combat_player_speed_scale stops being
-- irrelevant to this file and becomes the thing that decides how many ticks it takes. It is OWNED in
-- the setup block (see there) rather than inherited, and the tick count is DERIVED from the frozen
-- move_speed the encounter actually carries — a literal tick index is the fixture assumption that
-- has cost this repo real CI rounds.
do $$
declare
  n int; i int; v_enc uuid := (select v from cfb where k='v_enc');
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
  v_p_fb double precision; v_p_arm double precision;
  v_e_hpmax double precision; v_e_hpcur double precision; v_e_shield double precision;
  v_pirate_fire int; v_firers int;
  v_hp_fb0 double precision; v_hp_arm0 double precision; v_hp_fb1 double precision; v_hp_arm1 double precision;
  v_fb_mid text;
  -- ── 0351: the fleet as ONE actor, and the derived arrival the damage witness moves to ──────────
  v_fl_x double precision; v_fl_y double precision;
  v_fl_reach double precision; v_fl_speed double precision;
  v_fl_gap double precision; v_gap_pre double precision;
  v_sim double precision; v_pred_tick int; v_steps int := 0; v_hit_tick int;
  v_hp0 double precision; v_hp1 double precision; v_drop double precision;
  n_fb int; n_arm int; n_hulls int;
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
  v_er_pred := coalesce(public.cfg_num('enemy_synthetic_range_base'), 120)
               + v_diff * coalesce(public.cfg_num('enemy_synthetic_range_per_difficulty'), 5);
  if v_anchor_x is null or v_anchor_y is null or v_ring is null or v_er_pred is null then
    raise exception 'DAMAGE FAIL: anchor (%,%), ring % or predicted wave range % is NULL — every distance below would be vacuous', v_anchor_x, v_anchor_y, v_ring, v_er_pred;
  end if;
  select fp.x, fp.y into v_px, v_py
    from public.combat_formation_point(v_anchor_x, v_anchor_y, v_ring + v_er_pred + 1, 0,
           public.combat_wave_arrival_phase(v_anchor_x, v_anchor_y, v_site_x, v_site_y, 0)) fp;

  -- the PRE-MOVE player positions, each hull's own frozen reach and each hull's own frozen 0331
  -- power share (its weapons_json, never the catalog).
  select id, pos_x, pos_y, hp_current into u_fb,  v_fb_x,  v_fb_y,  v_hp_fb0
    from public.combat_units where encounter_id = v_enc and main_ship_id = s_fb;
  select id, pos_x, pos_y, hp_current into u_arm, v_arm_x, v_arm_y, v_hp_arm0
    from public.combat_units where encounter_id = v_enc and main_ship_id = s_arm;
  select max((w->>'range')::double precision), max((w->>'power')::double precision) into v_r_fb, v_p_fb
    from public.combat_units cu, jsonb_array_elements(cu.weapons_json) w where cu.id = u_fb;
  select max((w->>'range')::double precision), max((w->>'power')::double precision) into v_r_arm, v_p_arm
    from public.combat_units cu, jsonb_array_elements(cu.weapons_json) w where cu.id = u_arm;
  v_dist_fb  := public.osn_distance(v_fb_x,  v_fb_y,  v_px, v_py);
  v_dist_arm := public.osn_distance(v_arm_x, v_arm_y, v_px, v_py);
  if v_r_fb is null or v_r_arm is null or v_dist_fb is null or v_dist_arm is null
     or v_p_fb is null or v_p_arm is null then
    raise exception 'DAMAGE FAIL: a frozen weapon range (fb %, arm %), power share (fb %, arm %) or pre-move distance (fb %, arm %) is NULL — the fold and the damage identity below would both be vacuous', v_r_fb, v_r_arm, v_p_fb, v_p_arm, v_dist_fb, v_dist_arm;
  end if;
  v_fb_mid := coalesce((select value #>> '{}' from public.game_config
                         where key = 'combat_player_fallback_weapon_module_type_id'), 'basic_player_weapon');

  -- ── ★ THE RULE, ASSERTED AS A RULE (0351) — READ BEFORE THE SPAWN TICK ────────────────────────
  -- The fleet's reach is least() over the two hulls' own frozen weapons: the synthesized fallback on
  -- exactly equal terms with a catalog gun. Here the SHORTER one is the ARMED escort's, so the cap
  -- comes from a real gun and not from the unarmed hull; DZCOMBAT_PASS_SHORTGUN proves the other
  -- direction of the same rule.
  -- IT IS READ HERE, BEFORE THE TICK, ON PURPOSE. The gate compares the PRE-MOVE fleet point against
  -- the wave, and the fleet MOVES on the spawn tick (it is in CLOSE at a gap of 23 against a circle
  -- of 5) — so an actor read afterwards would be a different point, and comparing it against the
  -- pre-move hull distances measured above would be comparing two different instants.
  select a.x, a.y, a.reach, a.speed into v_fl_x, v_fl_y, v_fl_reach, v_fl_speed
    from public.combat_fleet_actor(v_enc) a;
  if v_fl_x is null or v_fl_y is null or v_fl_reach is null or v_fl_speed is null then
    raise exception 'DAMAGE FAIL: combat_fleet_actor answers point (%,%), reach %, speed % — a NULL in any of the four makes every assert below vacuous', v_fl_x, v_fl_y, v_fl_reach, v_fl_speed;
  end if;
  if abs(v_fl_reach - least(v_r_fb, v_r_arm)) > 1e-9 then
    raise exception 'DAMAGE FAIL attribution: the fleet''s reach is % but least(the unarmed lead''s synthesized fallback %, the armed escort''s catalog gun %) is % — 0351 folds the circle with min() over living hulls and the fallback takes part on exactly equal terms with a catalog gun. A max() would answer %, the lead''s own would answer %, and either would let the fleet shoot from outside the circle the player is shown',
      v_fl_reach, v_r_fb, v_r_arm, least(v_r_fb, v_r_arm), greatest(v_r_fb, v_r_arm), v_r_fb;
  end if;
  -- NON-VACUITY for the rule: the two reaches must actually DIFFER, or least() and max() and
  -- "the lead's own" all coincide and the assert above could not tell any of them apart.
  if v_r_fb <= v_r_arm then
    raise exception 'DAMAGE FAIL attribution: the synthesized fallback reaches % against the catalog gun''s % — this fixture needs the fallback to be strictly the LONGER one, so that least() is distinguishable from max() and from the lead''s own reach. Own combat_player_fallback_weapon_range above the catalog range rather than loosening the fold assert',
      v_r_fb, v_r_arm;
  end if;
  -- the fleet stands on its 0315-elected lead, which is s_fb on the anchor — so the circle the gate
  -- uses is centred where the client draws the glyph.
  if abs(v_fl_x - v_fb_x) > 1e-9 or abs(v_fl_y - v_fb_y) > 1e-9 then
    raise exception 'DAMAGE FAIL attribution: the fleet stands at (%,%) but its elected lead s_fb is at (%,%) — every distance below is measured from the fleet point, and it must be the hull 0315 elected', v_fl_x, v_fl_y, v_fb_x, v_fb_y;
  end if;
  -- the SPAWN gap: the pre-move fleet point to the point the wave is about to occupy (pinned to be
  -- where it actually lands, immediately after the tick). Identical to s_fb's own pre-move distance
  -- BECAUSE the fleet's point is s_fb — asserted, not assumed.
  v_fl_gap := public.osn_distance(v_fl_x, v_fl_y, v_px, v_py);
  if v_fl_gap is null or abs(v_fl_gap - v_dist_fb) > 1e-9 then
    raise exception 'DAMAGE FAIL attribution: the fleet''s gap to the wave is % but s_fb''s own pre-move distance is % — the fleet point is not the lead and the recurrence below would be run on the wrong number', v_fl_gap, v_dist_fb;
  end if;
  if v_fl_speed <= 0 then
    raise exception 'DAMAGE FAIL: the fleet''s frozen speed is % — it can never close and this block would spin', v_fl_speed;
  end if;
  -- ── THE ARRIVAL TICK, DERIVED FROM THE ENGINE'S OWN RECURRENCE, BEFORE A SINGLE TICK IS DRIVEN ──
  -- The wave is PARKED (its speed knobs are owned at 0 in setup), so the close arm shortens the gap
  -- by exactly the fleet's frozen speed each tick until the PRE-MOVE gap is inside the fleet's reach.
  -- Counting from the spawn tick as tick 1 — which is the engine's own combat_encounters.tick_number
  -- — the fleet fires on the tick this loop lands on. Never a literal index.
  v_sim := v_fl_gap; v_pred_tick := 1;
  while v_sim > v_fl_reach and v_pred_tick <= 60 loop
    v_sim := v_sim - least(v_fl_speed, v_sim);
    v_pred_tick := v_pred_tick + 1;
  end loop;
  if v_pred_tick < 2 then
    raise exception 'DAMAGE FAIL: the recurrence says the fleet is already inside its own circle at spawn (gap %, reach %) — there is nothing to close and the arrival witness would be the spawn tick again', v_fl_gap, v_fl_reach;
  end if;
  if v_pred_tick > 40 then
    raise exception 'DAMAGE FAIL: the recurrence needs % ticks to close (gap %, fleet reach %, fleet speed %) — this suite OWNS combat_player_speed_scale so the approach stays a handful of ticks; an approach this long means the knob it owns stopped landing', v_pred_tick, v_fl_gap, v_fl_reach, v_fl_speed;
  end if;

  -- no enemy yet — wave 1 spawns and takes its first fire pass INSIDE this tick call.
  select count(*) into n from public.combat_units where encounter_id = v_enc and side = 'enemy';
  if n <> 0 then raise exception 'DAMAGE FAIL precondition: % enemy rows before the first tick (want 0)', n; end if;

  perform pg_temp.cfb_tick(v_enc);

  -- exactly ONE synthetic pirate (danger 1), and it stands where 0336 puts it.
  select count(*) into n from public.combat_units where encounter_id = v_enc and side = 'enemy' and unit_type_id = 'pirate_synthetic';
  if n <> 1 then raise exception 'DAMAGE FAIL: % synthetic pirate row(s) (want exactly 1 — one unit means slot 0, which is the point pinned below)', n; end if;
  select id, pos_x, pos_y, shield_current into u_en, v_ex, v_ey, v_e_shield
    from public.combat_units where encounter_id = v_enc and side = 'enemy';
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

  -- ── ★ TICK 1 IS SILENT, AND THAT IS THE INVERSION ──────────────────────────────────────────────
  -- The old engine fired s_fb's fallback here (23 <= its own 30) and the pirate's hp was already
  -- down by this line. Under one circle the fleet opens at % of a reach of % and fires nothing.
  if v_fl_gap <= v_fl_reach then
    raise exception 'DAMAGE FAIL attribution: the fleet opens INSIDE its own circle (gap % <= reach %) — this scenario is now an APPROACH, and a fleet born in range would prove nothing about the fold or about the arrival tick below', v_fl_gap, v_fl_reach;
  end if;
  select count(*) into n from public.combat_events
    where encounter_id = v_enc and tick_number = 1 and event_type = 'missile_salvo' and source = 'player';
  if n <> 0 then
    raise exception 'DAMAGE FAIL attribution: % player missile_salvo event(s) on tick 1, and the derivation expects 0 — the fleet stands % from the wave against a circle of least(fallback %, catalog %) = %, so a salvo here is a hull firing on its OWN distance, which is the per-hull gate 0351 deleted',
      n, v_fl_gap, v_r_fb, v_r_arm, v_fl_reach;
  end if;
  -- (3) the wave reaches nobody either: 0336 stands it at least its own range + 1 from every hull,
  --     and since 0351 the distance ITS gate reads is the one to the FLEET POINT.
  if v_fl_gap <= v_r_en or least(v_dist_fb, v_dist_arm) <= v_r_en then
    raise exception 'DAMAGE FAIL attribution: the fleet point is % from the wave and its nearest hull % , against the wave''s own % reach — 0336''s spawn invariant does not hold in this world and the pirate could fire', v_fl_gap, least(v_dist_fb, v_dist_arm), v_r_en;
  end if;
  select count(*) into v_pirate_fire from public.combat_events
    where encounter_id = v_enc and tick_number = 1 and event_type = 'missile_salvo' and source = 'pirate';
  if v_pirate_fire <> 0 then raise exception 'DAMAGE FAIL attribution: pirate fired % time(s) on tick 1 (want 0 — the fleet point is outside its reach at spawn)', v_pirate_fire; end if;
  select hp_max, hp_current into v_e_hpmax, v_e_hpcur from public.combat_units where id = u_en;
  if v_e_hpcur is distinct from v_e_hpmax then
    raise exception 'DAMAGE FAIL: pirate hp_current (%) is not its untouched hp_max (%) on the spawn tick, with the whole fleet outside its own circle — some path is still firing on a hull''s own distance', v_e_hpcur, v_e_hpmax;
  end if;
  -- and no player ship was hit either — a clean tick.
  select hp_current into v_hp_fb1  from public.combat_units where id = u_fb;
  select hp_current into v_hp_arm1 from public.combat_units where id = u_arm;
  if v_hp_fb1 is distinct from v_hp_fb0 or v_hp_arm1 is distinct from v_hp_arm0 then
    raise exception 'DAMAGE FAIL: a player ship took damage on tick 1 (pirate should have fired nothing)'; end if;

  -- ── ★ DRIVE TO THE DERIVED ARRIVAL TICK, AND REQUIRE EVERY TICK BEFORE IT TO BE SILENT ────────
  select count(*) into n_hulls from public.combat_units
   where encounter_id = v_enc and side = 'player' and alive_count > 0;
  if n_hulls <> 2 then
    raise exception 'DAMAGE FAIL: % living player hull(s) entering the approach (want the 2 this fixture staged) — the all-or-none volley assert below would be measuring a different formation', n_hulls;
  end if;
  v_hit_tick := null;
  for i in 1 .. v_pred_tick + 4 loop
    -- STOP ONE TICK SHORT. The loop drives the SILENT ticks 2 .. (arrival - 1); the arrival tick
    -- itself is driven below, on its own, so the hp either side of it brackets exactly one volley.
    -- Exiting at `>= v_pred_tick` instead would drive the arrival inside the loop and then drive a
    -- second tick after it, and the damage identity would be measuring the wrong instant.
    select tick_number into v_steps from public.combat_encounters where id = v_enc;
    exit when v_steps >= v_pred_tick - 1;
    select public.osn_distance(a.x, a.y, e.pos_x, e.pos_y) into v_gap_pre
      from public.combat_fleet_actor(v_enc) a, public.combat_units e where e.id = u_en;
    if v_gap_pre is null then
      raise exception 'DAMAGE FAIL: the pre-move fleet gap is NULL before tick % — an unpositioned unit makes every range check in the approach vacuous', v_steps + 1;
    end if;
    -- every tick strictly before the derived arrival must be OUTSIDE the circle, by the same
    -- recurrence that predicted the arrival. If it is not, the recurrence and the engine disagree
    -- and the arrival tick below would be measuring the wrong instant.
    if v_gap_pre <= v_fl_reach then
      raise exception 'DAMAGE FAIL: the fleet is already inside its own % circle (gap %) before tick %, but the mover''s own recurrence ceil((gap - reach) / speed) predicts arrival on tick % — the tick is not stepping the fleet at the fleet''s speed %',
        v_fl_reach, v_gap_pre, v_steps + 1, v_pred_tick, v_fl_speed;
    end if;
    perform pg_temp.cfb_tick(v_enc);
    select tick_number into v_steps from public.combat_encounters where id = v_enc;
    select count(*) into n from public.combat_events
     where encounter_id = v_enc and tick_number = v_steps
       and event_type = 'missile_salvo' and source = 'player';
    if n <> 0 then
      raise exception 'DAMAGE FAIL attribution: % player salvo(s) on tick % at a pre-move fleet gap of % against a circle of % — nothing may fire before the fleet is inside its own reach', n, v_steps, v_gap_pre, v_fl_reach;
    end if;
  end loop;
  -- the ARRIVAL tick itself: the pre-move gap is inside the circle, and this is where the witness is.
  select public.osn_distance(a.x, a.y, e.pos_x, e.pos_y) into v_gap_pre
    from public.combat_fleet_actor(v_enc) a, public.combat_units e where e.id = u_en;
  if v_gap_pre is null or v_gap_pre > v_fl_reach then
    raise exception 'DAMAGE FAIL: entering the derived arrival tick % the fleet stands % from the wave, still OUTSIDE its own % circle — the engine is not closing at the frozen speed % the recurrence was run on',
      v_pred_tick, v_gap_pre, v_fl_reach, v_fl_speed;
  end if;
  select hp_current into v_hp0 from public.combat_units where id = u_en;
  perform pg_temp.cfb_tick(v_enc);
  select tick_number into v_hit_tick from public.combat_encounters where id = v_enc;
  select hp_current into v_hp1 from public.combat_units where id = u_en;
  if v_hit_tick is distinct from v_pred_tick then
    raise exception 'DAMAGE FAIL: the fleet entered its own circle on tick % but the mover''s own recurrence ceil((gap - reach) / speed) predicts % (spawn gap %, reach %, speed %) — the tick is not stepping the fleet at the fleet''s speed', v_hit_tick, v_pred_tick, v_fl_gap, v_fl_reach, v_fl_speed;
  end if;

  -- ── ★ ON THAT TICK BOTH HULLS FIRE, AND THE SUBJECT IS ONE OF THEM, BY NAME ────────────────────
  select count(*) filter (where projectile_type = v_fb_mid),
         count(*) filter (where projectile_type = 'autocannon_battery'),
         count(distinct payload_json->>'unit_id')
    into n_fb, n_arm, v_firers
    from public.combat_events
   where encounter_id = v_enc and tick_number = v_hit_tick
     and event_type = 'missile_salvo' and source = 'player';
  if n_fb < 1 then
    raise exception 'DAMAGE FAIL: no % salvo on the derived arrival tick % (pre-move fleet gap % inside the fleet''s % circle) — the synthesized fallback weapon did not fire, which is this proof''s entire subject', v_fb_mid, v_hit_tick, v_gap_pre, v_fl_reach;
  end if;
  if v_firers <> n_hulls then
    raise exception 'DAMAGE FAIL attribution: the arrival volley (tick %) came from % of the fleet''s % living hull(s), and the derivation expects ALL of them — 0351 gates every gun on ONE circle about ONE point, so a subset is the per-hull gate this slice deleted (fleet gap %, reach %, fallback %, catalog %)',
      v_hit_tick, v_firers, n_hulls, v_gap_pre, v_fl_reach, v_r_fb, v_r_arm;
  end if;
  if n_fb <> 1 or n_arm <> 1 then
    raise exception 'DAMAGE FAIL attribution: the arrival volley carried % % salvo(s) and % autocannon_battery salvo(s) (want exactly 1 each — one weapon per hull, both inside the one circle)', n_fb, v_fb_mid, n_arm;
  end if;
  if (select count(*) from public.combat_events
       where encounter_id = v_enc and tick_number = v_hit_tick and event_type = 'missile_salvo'
         and source = 'player' and projectile_type = v_fb_mid
         and (payload_json->>'unit_id')::uuid = u_fb) <> 1 then
    raise exception 'DAMAGE FAIL attribution: the arrival tick''s % salvo does not carry s_fb''s own unit id % — the fallback damage below would not be the synthesized weapon''s', v_fb_mid, u_fb;
  end if;

  -- ── ★ AND THE FALLBACK'S SHARE LANDED, SEPARATED OUT AS A NUMBER ───────────────────────────────
  -- Both variance knobs are zeroed in setup and player fire on an enemy is never defense-mitigated
  -- (0299:897), so a landed shot removes EXACTLY its frozen power share. The pirate's hp therefore
  -- falls by (fallback share + catalog share). Asserting the SUM rather than "hp fell" is what keeps
  -- the attribution exact now that the escort fires in the same volley: pre-0262 the unarmed ship
  -- carried weapons_json = [] and contributed nothing, so the drop would be short by v_p_fb — the
  -- original defect, still caught, still by a number.
  if v_e_shield is not null and v_e_shield <> 0 then
    raise exception 'DAMAGE FAIL: the wave carries shield_current % — the absorb step would eat part of the volley and the exact damage identity below would be measuring the shield, not the weapons', v_e_shield;
  end if;
  if v_hp0 is null or v_hp1 is null then
    raise exception 'DAMAGE FAIL: the wave''s hp around the arrival tick is % -> % — a NULL makes the damage identity vacuous', v_hp0, v_hp1;
  end if;
  v_drop := v_hp0 - v_hp1;
  if v_drop <= 0 then
    raise exception 'DAMAGE FAIL: pirate hp_current did not fall on the derived arrival tick (% -> %) — the fallback weapon dealt ZERO damage', v_hp0, v_hp1;
  end if;
  if abs(v_drop - (v_p_fb + v_p_arm)) > 1e-6 then
    raise exception 'DAMAGE FAIL: the wave lost % hp on the arrival tick but the two frozen 0331 power shares that fired sum to % (synthesized fallback %, catalog autocannon %) — a drop short by exactly % is the pre-0262 empty weapons_json, in which the unarmed hull logged nothing and dealt nothing',
      v_drop, v_p_fb + v_p_arm, v_p_fb, v_p_arm, v_p_fb;
  end if;

  -- and STILL no player ship has been hit: the fleet's circle (5) is wider than the wave's reach (2),
  -- so the formation comes to rest at its own edge and the wave never gets a shot at all.
  select count(*) into v_pirate_fire from public.combat_events
    where encounter_id = v_enc and event_type = 'missile_salvo' and source = 'pirate';
  select hp_current into v_hp_fb1  from public.combat_units where id = u_fb;
  select hp_current into v_hp_arm1 from public.combat_units where id = u_arm;
  if v_pirate_fire <> 0 or v_hp_fb1 is distinct from v_hp_fb0 or v_hp_arm1 is distinct from v_hp_arm0 then
    raise exception 'DAMAGE FAIL: the pirate fired % salvo(s) across the whole approach and the player hp went fb %->%, arm %->% — the fleet''s reach % exceeds the wave''s % , so the formation stops at its own edge and the wave can never reach it; a hit means the enemy gate is not measuring to the fleet point',
      v_pirate_fire, v_hp_fb0, v_hp_fb1, v_hp_arm0, v_hp_arm1, v_fl_reach, v_r_en;
  end if;

  raise notice 'CFALLBACK_PASS_DAMAGE ok: the wave stands exactly on combat_formation_point(anchor, ring % + its own range % + 1, slot 0, the 0338 arrival phase); the FLEET''S CIRCLE is % = least(the unarmed lead''s synthesized fallback %, the armed escort''s catalog gun %) — the fallback folds in on equal terms with a real gun and the SHORTER one wins, which here is the CATALOG gun (DZCOMBAT_PASS_SHORTGUN proves the same rule with the cap coming from a fitted hull instead). At a spawn gap of % the fleet therefore fired NOTHING on tick 1 and the pirate''s hp was untouched (the pre-0351 per-hull gate fired the fallback here, because 23 <= its own 30); the fleet then closed for exactly % tick(s) — ceil((gap - reach) / fleet speed %), derived from the engine''s own recurrence, never a literal — and on arrival tick % BOTH hulls fired together, one % salvo carrying s_fb''s own unit id and one autocannon_battery, dropping the wave''s hp by exactly % = the two frozen 0331 shares (% + %). Pre-fix (empty weapons_json) that drop would have been short by the fallback''s whole %',
    v_ring, v_r_en, v_fl_reach, v_r_fb, v_r_arm, round(v_fl_gap::numeric, 3), v_pred_tick - 1,
    round(v_fl_speed::numeric, 4), v_hit_tick, v_fb_mid, round(v_drop::numeric, 4), v_p_fb, v_p_arm, v_p_fb;
end $$;

do $$ begin raise notice 'COMBAT-FALLBACK PROOF PASSED'; end $$;

rollback;   -- self-rolling-back: ZERO persisted state (no COMMIT anywhere above).
