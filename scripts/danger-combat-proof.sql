-- DANGER-ZONE COMBAT — disposable proof for the OWNER'S #1 chain: "send a fleet into a danger zone →
-- you get jumped by pirates WHERE you meet the zone, WHEN you get there." Drives the ACTUAL entry
-- path end to end, through the REAL RPCs:
--
--   command_ship_group_go (leg crosses a danger_zone)                    [0233/0292/0301]
--     → pirate_intercept_plan_leg (risk roll → a PENDING ambush)         [0301]
--   ... the fleet TRAVELS ...
--   process_fleet_movements (due-intercept scan)                         [0301]
--     → movement_advance → pirate_intercept_resolve_due_for_movement     [0301]
--       → manifest freeze + presence_create + activity_start('hunt_pirates')
--         → combat_create_encounter (resolves the engagement point)      [0168/0301]
--           → combat_create_group_encounter (MANDATORY point, spatial)   [0293/0301]
--   → process_combat_ticks (spatial branch: synthetic pirate spawn + fire)
--
-- ── WHAT CHANGED IN 0301, AND WHY THIS FILE CHANGED WITH IT ──────────────────────────────────────────
-- Before 0301 the ambush happened INSIDE the go call: the RPC returned intercepted=true and an
-- encounter id, and this proof asserted exactly that. That was the defect — the fleet never travelled.
-- The go call now starts a real journey and returns order_outcome='movement_started', and the ambush
-- fires later, from the movement processor, at the point where the leg first ENTERS the zone. So the
-- properties this file proves are the new ones, and several of them are proofs that the OLD behaviour
-- is gone.
--
-- ── WHY THE AMBUSH IS DETERMINISTIC HERE ─────────────────────────────────────────────────────────────
-- pirate_intercept_plan_leg draws a uniform roll in [0,1) and plans iff roll < risk. This proof sets
-- the risk knobs so pirate_intercept_compute_risk returns exactly 1.0 for ANY crossing — a [0,1) draw
-- is ALWAYS < 1.0 — so the plan is certain without the harness itself drawing an RNG value (0041 law).
--
-- ── HOW TIME IS CONTROLLED ───────────────────────────────────────────────────────────────────────────
-- No sleeping. The harness first ASSERTS that the planner's trigger_at is exactly
-- depart_at + (arrive_at - depart_at) * entry_fraction — i.e. it proves the schedule it is about to
-- manipulate — and only then TIME-TRAVELS the leg by shifting depart_at, arrive_at and trigger_at by
-- the SAME interval. That is "the fleet set off earlier", not "the ambush was moved".
--
-- ── PROPERTIES PROVEN (each a PASS marker) ───────────────────────────────────────────────────────────
--   DZCOMBAT_PASS_ORDER      — at order commit: order_outcome='movement_started', NO `intercepted` and
--                              NO `intercept_encounter_id` in the envelope, the movement is still
--                              'moving', the fleet is still 'moving' and has NOT been parked, NO
--                              encounter exists, and exactly ONE 'pending' pirate_intercepts row was
--                              written carrying an entry point ON the zone boundary and a trigger_at
--                              that is the exact interpolation of the leg's own clock.
--   DZCOMBAT_PASS_NOTYET     — a full process_fleet_movements() run BEFORE trigger_at creates NO
--                              encounter, leaves the row 'pending' and the movement 'moving'.
--   DZCOMBAT_PASS_FIRE       — with BOTH trigger_at and arrive_at in the past, ONE processor run fires
--                              the ambush INSTEAD of settling the arrival: row 'fired', movement
--                              'cancelled' (not 'arrived'), fleet parked in open space AT the recorded
--                              entry point (not at the destination), one active encounter, and the
--                              plotted route queue abandoned.
--   DZCOMBAT_PASS_ENGAGEMENT — combat_encounters.engagement_x/y EQUAL the recorded entry point, the
--                              command ship's combat_unit sits exactly on it, and the encounter row's
--                              location_id is still the linked location (identity, not position).
--   DZCOMBAT_PASS_ONCE       — a second processor run and a direct second resolve create no second
--                              encounter and cannot re-fire a terminal row.
--   DZCOMBAT_PASS_EVASION    — on a SECOND fleet: STOP before due cancels the owed ambush; a re-order
--                              before due cancels it and plans a fresh one on the new leg; STOP after
--                              it is due is REFUSED (intercepted_in_transit) and the ambush fires.
--   DZCOMBAT_PASS_SPATIAL    — the opened encounter is SPATIAL: player combat_units carry non-NULL
--                              pos_x/pos_y and the command ship carries its fitted weapon range.
--   DZCOMBAT_PASS_PIRATEFIRE — (re-premised 0336) a synthetic pirate spawns SILENT — it cannot fire on
--                              the tick it arrives, because 0336 stands a wave outside its own reach
--                              BY CONSTRUCTION — then CLOSES and FIRES a spatial missile_salvo whose
--                              unit_id/target_id RESOLVE to a real enemy row and a real player SHIP
--                              row of this encounter, and takes real damage back.
--   DZCOMBAT_PASS_ROSTERAUTH — (0308) a ship UNASSIGNED after a concluded fight is NOT seeded into
--                              the fleet's next ambush — it keeps its berth, status, hp — while the
--                              ship still on the roster IS seeded; the re-ambush freeze REPLACED the
--                              fleet's snapshot (stale row released, live membership frozen).
--   DZCOMBAT_PASS_RIGFALLBACK — (0308) a ship whose ONLY fitted module is a mining rig gets the 0262
--                              fallback weapon derived from its own attack (0317: power = its
--                              combat_power EXACTLY — the knob that used to scale it is deleted),
--                              never the rig's power-8 entry: a rig is not a gun.
--   DZCOMBAT_PASS_FITTEDEXACT — (0308) a ship with a REAL weapon fitted carries exactly its catalog
--                              weapon entry — alone, field-for-field — and no fallback entry.
--                              (0317) …except `power`, which is its own folded combat_power, not the
--                              catalog share weight. Every DELIVERY field is still pinned.
--   DZCOMBAT_PASS_ONEPOWER   — (0317) ONE AUTHORITY FOR ATTACK. Five hulls in one fleet, one
--                              encounter, no ticks: every hull's weapons_json totals to exactly its
--                              folded combat_power; a ship TRAIT (a source that can never reach a
--                              weapon row) raises the damage by exactly its own attack; two
--                              identical guns SHARE the ship's power in equal parts summing to 1
--                              rather than each carrying it; the no-weapon hull obeys the same
--                              identity through the synthesized weapon; and the stronger gun
--                              (mk2) never produces less damage than the weaker one.
--   DZCOMBAT_PASS_REPOSITION — (0337) an ambushed fleet ordered to a point INSIDE the fight's own
--                              zone gets a COURSE, not a jump: the order moves nothing at all, and
--                              the tick then walks the fleet there over THREE ticks at exactly its
--                              own combat_fleet_move_speed per tick, the formation holding ONE rigid
--                              offset from the anchor at every step, arriving exactly and consuming
--                              the order — encounter still active, NO retreat_target_* written, NO
--                              retreat started, NO leg minted, enemy rows moving under their own
--                              mover the whole way. The PER-TICK bound is the point: an endpoint
--                              assert alone passes a teleport, so a single-step body fails at step 1
--                              even with a perfect endpoint. Fails on the pre-0311 retreat-always
--                              body at its FIRST envelope assert ('retreat_started'), and on the
--                              0311 teleport body at "the ORDER moved the fleet".
--   DZCOMBAT_PASS_REPOHOLD   — (0337) the stale-destination case, decided: a fight that is RETREATING
--                              while still carrying a course does not follow it. Non-vacuous by
--                              construction — a living fleet, a positive speed and more than one
--                              step still to run — so only the step's own fresh status='active'
--                              read is holding it. Nothing clears the course, because a value on a
--                              row nobody reads is already gone.
--   DZCOMBAT_PASS_REPOOVERLAP — (0311) the admission QUANTIFIES over overlapping zones instead of
--                              choosing one: a thin lower-area zone that holds the anchor but not
--                              the destination cannot VETO a move whose destination sits inside
--                              another anchor-holding zone — in either area order. BOTH orders
--                              here fail on the tie-break body (131e027), which picked the
--                              smallest anchor-holding zone and retreated when it missed.
--   DZCOMBAT_PASS_REPOOUTSIDE — (0311) a destination inside a zone that does NOT hold the anchor —
--                              with no anchor-holding zone containing it — retreats exactly as
--                              before (destination stored, presence + encounter 'retreating',
--                              nothing moved, no leg): the quantifier's negative side. And a
--                              'retreating' encounter ordered back to an ADMITTED point never
--                              jumps — it only updates the stored destination and the retreat
--                              clocks never restart (no free escape from the damage window).
--   DZCOMBAT_PASS_REPOMODE   — (0311) a fleet fighting AT ITS SITE (location_mode <> 'space')
--                              ordered to an admitted in-zone point FALLS THROUGH to the retreat —
--                              today's behaviour exactly: never a reposition, and NEVER a refusal
--                              (the first cut refused here; adversarial review showed that
--                              regressed a capability, and this block fails on that 131e027 body).
--   DZCOMBAT_PASS_AUTOEXIT   — (0310) the HP auto-exit, staged on the REAL ambush chain and driven
--                              by the REAL tick: a fleet whose group sets a 50% threshold fights
--                              (real ambush → real encounter → real enemy fire) and, the first tick
--                              its hull is at or below 50% of its FULL CAPACITY (sum of
--                              main_ship_instances.max_hp — the threshold's real denominator,
--                              equal to the entry integrity here ONLY because the fleet is
--                              factory-fresh, and asserted so), AUTO-REQUESTS the canonical
--                              retreat (presence 'retreating', encounter 'retreating',
--                              retreat_started_at stamped, exactly ONE retreat_started event) —
--                              never a tick earlier (every tick observed above the threshold left
--                              it fighting, and at least one such tick is REQUIRED or the block
--                              fails vacuous); a second tick does NOT re-request; rewinding the
--                              retreat clock completes it EXACTLY like a human press (encounter
--                              'escaped', fleet 'returning'); THEN THE DAMAGED RE-ENTRY, the
--                              regression the capacity denominator exists for: the SAME fleet,
--                              un-repaired, re-enters a fight ALREADY below its (raised)
--                              threshold — its entry integrity asserted STRICTLY LESS than its
--                              capacity, or the scenario proves nothing — and auto-exits on the
--                              FIRST tick. An entry-hull denominator reads that first tick as
--                              ~94% of "max" and fights on, so this scenario is RED on any body
--                              measuring the entry hull (the cb10020 defect); a group with the
--                              toggle OFF fights on far below the default threshold (the control
--                              proving the flip assert is not vacuously green — and exactly what
--                              the pre-0310 tick does, so the block is RED on the pre-fix body by
--                              construction); set_group_auto_exit enforces its bounds ([5,95],
--                              NaN refused, null toggle refused, cross-player refused) and the
--                              table CHECK refuses NaN / out-of-range even on a direct write.
--   DZCOMBAT_PASS_CLOSURE    — (0313) with the seeded ranges cut below the 30-unit escort spawn gap,
--                              units MOVE: an escort and its pirate close on each other across real
--                              ticks (pos_x/pos_y changing), neither fires while the gap exceeds its
--                              own range, the escort's FIRST shot lands only on a tick whose pre-move
--                              distance is inside its range (after at least one silent closing tick),
--                              the pirate's first shot obeys ITS range the same way. This is the
--                              CLOSE arm of combat_unit_decide_move running at SEEDED values for the
--                              first time in the game's history. (0336 re-premised: the wave no
--                              longer spawns ON the anchor, so the opening tick is SILENT ON BOTH
--                              SIDES rather than the lead firing from distance 0, and the wave's
--                              spawn point is derived from the MEASURED formation extent — the one
--                              authority the engine itself uses — never from the ring knob.)
--   DZCOMBAT_PASS_LEAD       — (0315) EVERY fleet entering combat has a lead, whether or not any ship
--                              carries the flag. A three-hull fleet with NO command ship anywhere
--                              elects one by the stated rule (a real flag first, then the greatest
--                              max_hp, then the lowest main_ship_id, over living hulls) — capacities
--                              engineered so neither key can be the accidental reason — anchors
--                              exactly that hull on the engagement point at aggro 100 with both
--                              escorts at 0 on their unchanged ring slots, and FIRES ON TICK 1 from
--                              the anchor alone (the ring provably exceeds an escort's range, so no
--                              escort could have opened the fight). A fleet that DOES carry a
--                              designated command ship is placed exactly as it is today even though
--                              the fallback would have named the other hull on both derived keys —
--                              the derivation is a fallback, never an override. A single-hull fleet
--                              is its own lead. RED by construction on the pre-0315 body: a flagless
--                              fleet put nobody on the anchor and nobody at priority 100.
--   DZCOMBAT_PASS_DEADFIRE   — (0317) A UNIT DESTROYED EARLIER IN A TICK TAKES NO TURN. Two staged
--                              fights on the real ambush chain.
--                              (A) A MUTUAL ONE-SHOT KILL — one hull, one pirate, each sized from
--                              the fight's own numbers to destroy the other in a single shot at
--                              distance 0. Post-0317 the tick must produce EXACTLY ONE salvo, EXACTLY
--                              ONE landed hit and EXACTLY ONE destroyed unit: whichever the loop
--                              reaches first kills, and the loser — whichever SIDE it is — emits no
--                              attack event and deals no damage. RED by construction on the pre-0317
--                              body, where both fired and both died (two of each). The block also
--                              proves the loser WAS a live threat (its own weapon, at the real
--                              distance, would have destroyed the survivor) so the silence is not
--                              vacuous, and that the survivor's hull is untouched.
--                              (B) THE LIVING STILL ACT, AND THE FREEZE SURVIVES — a two-hull fleet
--                              against a six-pirate wave where exactly one pirate dies. Every pirate
--                              still alive after the tick must have fired exactly once (the fix must
--                              not silence survivors), and BOTH player hulls must have fired at the
--                              SAME pirate — the one the frozen snapshot named — with only ONE of
--                              those two shots landing damage. That second shot on a corpse is the
--                              proof that targeting still resolves from the pre-move freeze and that
--                              0317 re-reads the ACTOR's liveness only, never the snapshot.
--                              (C) THE INVARIANT, OVER BOTH FIGHTS AND BOTH SIDES — no unit emits a
--                              missile_salvo at a seq later than the unit_destroyed event naming it
--                              in the same tick. Quantified over every unit of every side, so a
--                              violation anywhere fails it.
--   DZCOMBAT_PASS_OWNWORLD   — (0336) the proof OWNS its zone world: every seeded (non-drawn) danger
--                              zone is deactivated in-txn before the first fixture is drawn, so a
--                              randomly-shaped seed blob can never again cover a fixed test
--                              coordinate on some runs and not others.
--   DZCOMBAT_PASS_RANGEINVARIANT — (0336) a wave must never arrive inside its own reach. The knob
--                              inequality over EVERY location with a positive difficulty (hidden
--                              ones included), the SAME thing measured on a real staged wave, and
--                              the kite band the closing enemy stops in proven to be inside the
--                              player's own shortest gun.
--   DZCOMBAT_PASS_VOLLEY     — (0336) a kill does not disarm the rest of the volley: a THREE-gun
--                              hull against a wave larger than its gun count fires 3 salvos at 3
--                              DISTINCT targets, lands 3 hits and destroys 3. The head resolved the
--                              target once above the per-weapon loop and dropped guns 2 and 3.
--   DZCOMBAT_PASS_WAVERING   — (0336) a wave arrives on a RING, not on one point: every unit on its
--                              own position, none on the anchor, all at one measured radius, and
--                              every one of them reproduced by combat_formation_point at the arrival
--                              phase on a slot no other unit used. AND (0338) IT CAME OUT OF THE
--                              CITY: exactly one pirate stands where the ray from the engagement
--                              anchor toward the zone's own settlement — combat_encounters.
--                              location_id, carried from danger_zones.location_id — crosses that
--                              radius, with the whole wave inside an arc of that bearing rather than
--                              encircling the fleet. Both preconditions (a site is linked; the
--                              anchor is not standing on it) are OWNED and raise rather than pass.
--   DZCOMBAT_PASS_NODIRECTION — (0338) the fallback, end to end. A deliberate hunt anchors its fight
--                              ON its site (combat_create_encounter hands the creator the location's
--                              own centre for any fleet not in open space), so there is no direction
--                              to arrive FROM — and the wave falls back to 0336's PLAIN RING value
--                              for value: n distinct points, one measured radius, every unit on
--                              combat_formation_point at 0336's own constant phase, and the arrival
--                              leaf answering that constant at every slot the wave used.
--   DZCOMBAT_PASS_RETREATNOSPAWN — (0336) pressing Retreat does not summon a bigger wave: with the
--                              transition window PROVEN closed, the retreat tick raises no
--                              wave_spawned, adds no enemy row and advances neither wave counter.
--   DZCOMBAT_PASS_NOWEDGE    — (0336) a terminal-arm status mismatch CONCLUDES the encounter with a
--                              warning instead of rolling the tick back forever: with the presence
--                              completed out of band (and presence_complete proven to raise for it)
--                              the death arm still reaches 'defeat', and last_resolved_at and
--                              tick_number both ADVANCE.
--   DZCOMBAT_PASS_ORDERSTABLE — (0336) the actor loop order is decided: over two consecutive ticks,
--                              six firing units emit their salvos in ascending combat_units.id.
--   DZCOMBAT_PASS_SHORTGUN   — (0336) a longer gun no longer disables a shorter one: a hull with an
--                              autocannon and an Mk-II passes through the band where only the Mk-II
--                              reaches and then settles inside its SHORTEST gun, with both module
--                              types on the record.
--   DZCOMBAT_PASS_RETREATCLEAR — (0336) all four terminal arms consume fleets.retreat_target_*: the
--                              DEATH arm (which leaked on the head) clears it, and the SETTLE arm
--                              still both clears it and USES it.
--   DZCOMBAT_PASS_WAVEBAND   — (0341) the owner's sentence, run through the real tick: eleven waves
--                              are cleared back to back at the SHIPPED band of 5 and the wave that
--                              arrives carries 1 body for rounds 1-5, 2 for rounds 6-10 and 3 for
--                              round 11 — and the cap still binds at a danger far past it.
--   DZCOMBAT_PASS_SLOWGUN    — (0341) a gun cannot fire on two consecutive ticks: every fitted gun in
--                              the DEPLOYED catalog needs two ticks to become ready, and a wave that
--                              fires arms every one of its weapons past the moment the NEXT tick
--                              runs. now() is txn-frozen, so the assertion is tick-RELATIVE
--                              (next_ready_at > now() + combat_tick_seconds) — the only form that
--                              can tell the new 4s cooldown apart from the old 2s one.
--
-- Self-rolling-back (begin;…rollback;, no COMMIT); every dark flag flipped ONLY inside the txn;
-- provisioning is 100% real-RPC; group_sortie_members and combat_units are NEVER hand-written.
-- No session RNG draw in the harness (0041).

\set ON_ERROR_STOP on

begin;   -- everything below is transient; the trailing ROLLBACK leaves ZERO persisted state.

create temp table dzc(k text primary key, v uuid) on commit preserve rows;
create temp table dzn(k text primary key, v double precision) on commit preserve rows;

create or replace function pg_temp.call_as(p_sub uuid, p_fn text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_fn into v;
  return v;
end $$;

-- TIME TRAVEL: move a leg and everything it owes backwards by the same interval. This is the ONLY
-- clock manipulation in the file and it never changes WHERE anything happens.
create or replace function pg_temp.rewind_leg(p_mv uuid, p_by interval) returns void language plpgsql as $$
begin
  update public.fleet_movements
     set depart_at = depart_at - p_by, arrive_at = arrive_at - p_by
   where id = p_mv;
  update public.pirate_intercepts
     set trigger_at = trigger_at - p_by
   where movement_id = p_mv and lifecycle_state = 'pending';
end $$;

-- DRAIN an encounter to a terminal state. A pirate-hunt combat never ends on its own — clearing a wave
-- spawns the next — so the ONLY way out is the canonical retreat, which the caller arms first (that is
-- what command_ship_group_go step 8 does against a live encounter). This drives the real engine plus the
-- movement processor, because the retreat mints its own leg that has to settle before the fleet is
-- commandable. Deliberately the single process_combat_ticks() site outside PIRATEFIRE, so the harness's
-- "one combat engine, known call sites" pin stays meaningful.
create or replace function pg_temp.drain_encounter(p_enc uuid, p_fleet uuid) returns text language plpgsql as $$
declare v_status text;
begin
  for i in 1..60 loop
    select status into v_status from public.combat_encounters where id = p_enc;
    exit when v_status not in ('active', 'retreating');
    -- Two clocks have to move, and only clocks: the tick cadence (last_resolved_at) and the retreat
    -- delay, which the engine measures as now() - retreat_started_at >= combat_retreat_delay_seconds
    -- (0299:541-543). Rewinding only the tick cadence leaves the encounter 'retreating' forever, which
    -- is exactly how an earlier draft stalled. No status, no outcome, no geometry is written here.
    update public.combat_encounters
       set last_resolved_at  = last_resolved_at - interval '1 minute',
           retreat_started_at = case when retreat_started_at is not null
                                     then retreat_started_at - interval '1 hour' end
     where id = p_enc;
    perform public.process_combat_ticks();
    update public.fleet_movements set depart_at = depart_at - interval '1 hour',
                                      arrive_at = arrive_at - interval '1 hour'
     where fleet_id = p_fleet and status = 'moving';
    perform public.process_fleet_movements();
  end loop;
  select status into v_status from public.combat_encounters where id = p_enc;
  return v_status;
end $$;

-- ONE tick of the REAL engine against ONE encounter (0310 AUTOEXIT). now() is frozen for the whole
-- txn, so the cadence gate (now() - last_resolved_at >= combat_tick_seconds) never re-opens on its
-- own — this rewinds the ONE encounter's tick clock and runs the engine. Every OTHER encounter's
-- last_resolved_at is untouched, so the same run skips them (their cadence reads zero elapsed):
-- the loop drives exactly one fight. Clock-only, same law as rewind_leg/drain_encounter: no status,
-- no outcome, no geometry, no hp is written here.
create or replace function pg_temp.ae_tick(p_enc uuid) returns void language plpgsql as $$
begin
  update public.combat_encounters
     set last_resolved_at = last_resolved_at - interval '1 minute'
   where id = p_enc;
  perform public.process_combat_ticks();
end $$;

-- ════════ SETUP: reveal starter ports, one funded fixture player ═════════════════════════════════════
do $$
declare r jsonb; uZ uuid;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: reveal_starter_ports %', r; end if;

  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uZ;
  insert into dzc values ('uZ', uZ);
  insert into public.player_wallet (player_id, balance) values (uZ, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
end $$;

-- dark capability gates — flipped ONLY inside this rolled-back txn (committed/production values stay
-- as they are; a fresh disposable chain seeds these false, so every one is load-bearing here).
update public.game_config set value='true'::jsonb where key='team_command_enabled';
update public.game_config set value='true'::jsonb where key='mainship_additional_commission_enabled';
update public.game_config set value='true'::jsonb where key='module_crafting_enabled';
update public.game_config set value='true'::jsonb where key='module_fitting_enabled';
update public.game_config set value='true'::jsonb where key='spatial_combat_enabled';
update public.game_config set value='true'::jsonb where key='pirate_intercept_enabled';
update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';
-- combat_telegraph_enabled stays FALSE → when the ambush FIRES the encounter opens in that same
-- resolution, so it is observable synchronously right after the processor run.
update public.game_config set value='false'::jsonb where key='combat_telegraph_enabled';
update public.game_config set value='false'::jsonb where key='timed_docking_enabled';

-- 0341: THE DEPLOYED WAVE BAND, CAPTURED BEFORE THE TUNING BELOW OVERWRITES IT. The tuning block
-- pins enemy_synthetic_units_per_danger_band to 1 so the ten blocks that need three or more bodies
-- on the field keep working, which means the SHIPPED value cannot be read back later. WAVEBAND has
-- to assert what the migration actually deployed rather than what this file would like it to be, so
-- the value is taken here, first, and read from this table there.
create temp table dzc_deployed on commit drop as
  select public.cfg_num('enemy_synthetic_units_per_danger_band') as wave_band;

-- tuning knobs (revertible by ROLLBACK). The DETERMINISTIC-AMBUSH knobs: risk=1.0 for any crossing.
do $$
begin
  perform public.set_game_config('pirate_intercept_base_risk',      '1.0'::jsonb);
  perform public.set_game_config('pirate_intercept_min_risk',       '1.0'::jsonb);
  perform public.set_game_config('pirate_intercept_max_risk',       '1.0'::jsonb);
  perform public.set_game_config('pirate_intercept_exposure_floor', '1.0'::jsonb);
  perform public.set_game_config('combat_damage_variance_pct',      '0'::jsonb);      -- determinism
  -- 0314: the per-hit roll's own knob, pinned 0 like the tick-shared one (it INHERITS that knob
  -- when absent, but the precondition is OWNED here, never inherited) — every damage number in the
  -- pre-0314 blocks stays byte-exact. The RSFEEL block sets its own 0.5 and restores this 0.
  perform public.set_game_config('combat_hit_variance_pct',         '0'::jsonb);
  perform public.set_game_config('combat_tick_logging',             'true'::jsonb);
  perform public.set_game_config('combat_event_logging',            'true'::jsonb);   -- so fire events land
  -- 0314: hull_damage must ride EVENT logging, not debug — RSFEEL proves the promotion, so the
  -- debug flag is pinned dark here (owned, not assumed from the chain seed).
  perform public.set_game_config('combat_debug_logging',            'false'::jsonb);
  -- 0314: the tick arms REAL weapon cooldowns (next_ready_at = now() + cooldown_seconds), and now()
  -- is FROZEN for this whole txn — so any positive cooldown means a weapon fires at most ONCE per
  -- proof run, which would stall every block that drives multi-tick fire (the AUTOEXIT erosion
  -- loops above all). Those blocks assert the fire-every-tick world, so they OWN it: the enemy
  -- cooldown knob is zeroed BEFORE any wave spawns (the wave snapshots it into weapons_json), and
  -- the player fallback likewise. The cooldown property itself is proven where it is owned — the
  -- RSFEEL block, which sets its own 3600s cooldown and demands tick-2 silence.
  perform public.set_game_config('enemy_synthetic_cooldown_seconds', '0'::jsonb);
  perform public.set_game_config('combat_player_fallback_weapon_cooldown_seconds', '0'::jsonb);
  perform public.set_game_config('enemy_hp_base',                   '1000'::jsonb);   -- pirate survives tick 1
  perform public.set_game_config('max_active_fleets',               '50'::jsonb);
  -- 0341 BAND = 1 FOR EVERY LEGACY BLOCK, DELIBERATELY AND ONCE. Ten blocks below stage a danger
  -- and then derive how many pirates that danger buys with the pre-0341 rule
  -- (least(cap, greatest(1, danger))), because several of them need THREE OR MORE bodies on the
  -- field to say anything at all (a ring cannot be told apart from a point with one unit; a
  -- three-gun ship cannot be shown to re-aim). 0341 made that a KNOB — a body per BAND of danger
  -- steps — and band=1 is exactly the old rule, so those blocks keep asserting what they were
  -- written to assert instead of being widened or weakened. The band's own behaviour is owned by
  -- the WAVEBAND block below, which sets it to the shipped 5 and puts it back.
  perform public.set_game_config('enemy_synthetic_units_per_danger_band', '1'::jsonb);
end $$;

-- ════════ DZCOMBAT_PASS_OWNWORLD (0336): THE PROOF OWNS ITS ZONE WORLD — NO RANDOM BLOB IN IT ═══════
-- ── THE FLAKE THIS ENDS, AND ITS EXACT MECHANISM ─────────────────────────────────────────────────
-- This suite failed and passed on IDENTICAL commits four times in one day, always here:
--     danger-combat-proof.sql:REPOSITION FAIL fixture: 1 unrelated active zone(s) also hold the
--     engagement point (<uuid> Reaver) — move the fixture geometry.
-- naming Reaver every time, with a DIFFERENT uuid every run. It was never a flake. It is a
-- randomly-shaped world colliding with a fixed test coordinate:
--   * The seeded pirate zones are regenerated on every fresh disposable database, and the generator
--     (0237, carried into 0296's rematerializer) builds each polygon from the session RNG: 12..24 vertices,
--     3..6 lobes, a random phase, per-vertex angular jitter, and a per-vertex radial wobble of
--     0.6..1.5 x territory_radius modulated by (1 +/- 0.18). So a seeded blob's reach from its own
--     centre lands anywhere in [0.492, 1.77] x territory_radius, redrawn on every CI run.
--   * The ROSTERAUTH fixture's ambush entry — the engagement point REPOSITION measures from — sits
--     at the starter port's (x, y + 200). Against the seeded world that is 18.03 units from Reaver's
--     centre, whose territory_radius is 12: minimum reach 5.90, MAXIMUM reach 21.24. The fixture
--     point lies INSIDE that annulus, so Reaver's blob covered it on some runs and not on others.
-- ── THE FIX: OWN THE PRECONDITION, DO NOT WIDEN THE GUARD ────────────────────────────────────────
-- The REPOSITION guard is right and stays exactly as strong as it was: a real overlap WOULD
-- invalidate the property it proves, and 0317's named diagnostic is what made this diagnosable at
-- all. What was wrong is that the block INHERITED an ambient, randomly-shaped world instead of
-- establishing its own — the proofs-never-assert-ambient-defaults law, in its geometric form.
-- So: every zone this proof did not draw is deactivated here, in-txn, before any fixture geometry
-- exists. From this line on, the ONLY active danger zones in the world are the ones this file
-- creates through pirate_zone_create, at coordinates this file chose. Every downstream zone
-- assertion — REPOSITION's single-holder guard, REPOOVERLAP's quantifier, the intercept plans, the
-- entry-point geometry — becomes deterministic, on every database, forever.
-- WHY DEACTIVATE RATHER THAN RESHAPE: the only in-repo reshaper is the random generator itself, and
-- this file may not draw a session RNG value at all (the 0041 determinism law, which the harness's own
-- static gate enforces by refusing the literal call). Status is the one lever that is both
-- deterministic and already the authority every reader uses: RLS, get_danger_zones and
-- pirate_intercept_leg_zone_hits all filter status = 'active'.
-- WHY IT WEAKENS NOTHING: no block in this file references a seeded zone, by name or by id; every
-- ambush it stages is planned from a zone it drew itself at risk 1.0. Removing ambient blobs can
-- only REMOVE unplanned intercepts, never add one — so the "exactly one pending ambush" asserts
-- downstream get stronger, not weaker.
do $$
declare n_seeded int; n_left int;
begin
  select count(*) into n_seeded from public.danger_zones where status = 'active' and source <> 'drawn';
  update public.danger_zones set status = 'inactive', updated_at = now()
   where status = 'active' and source <> 'drawn';
  -- NON-VACUITY: a world with no seeded zone at all would satisfy the asserts below while proving
  -- nothing, and would also mean the seed stopped producing the very shapes this block exists to
  -- exclude. Fail loudly instead — the next author must decide whether that is a real seed change.
  if n_seeded = 0 then
    raise exception 'OWNWORLD FAIL: the chain seeded ZERO active non-drawn danger zones — either the seed changed or this block is now inert, and either way the determinism it establishes is no longer being established';
  end if;
  select count(*) into n_left from public.danger_zones where status = 'active' and source <> 'drawn';
  if n_left <> 0 then
    raise exception 'OWNWORLD FAIL: % randomly-shaped seeded zone(s) are still active — a fixed test coordinate would keep colliding with them at random', n_left;
  end if;
  -- and nothing DRAWN is active yet either: this runs before the first pirate_zone_create, so the
  -- world is empty of zones and every later one is this file's own.
  select count(*) into n_left from public.danger_zones where status = 'active';
  if n_left <> 0 then
    raise exception 'OWNWORLD FAIL: % active zone(s) remain before any fixture is drawn — this block must run before the first pirate_zone_create', n_left;
  end if;
  raise notice 'DZCOMBAT_PASS_OWNWORLD ok: % randomly-shaped seeded zone(s) deactivated in-txn; zero active zones remain, so every zone this proof measures from here on is one it drew itself at a coordinate it chose', n_seeded;
end $$;

-- ════════ PROVISION: TWO command ships via the real RPCs, TWO teams ══════════════════════════════════
-- Team A carries the main scenario through to combat. Team B is kept clear for the STOP / re-order /
-- evasion scenario, which needs a fleet that is not already in a fight.
do $$
declare
  r jsonb;
  uZ uuid := (select v from dzc where k='uZ');
  s_cmd uuid; s_b uuid; v_mod uuid;
begin
  r := pg_temp.call_as(uZ, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL first ship: %', r; end if;
  select main_ship_id into s_cmd from public.main_ship_instances where player_id = uZ;
  insert into dzc values ('s_cmd', s_cmd);

  -- fund + craft + fit ONE autocannon_battery onto the command ship, via the real writers. Its range is
  -- NOT restated here: 0313 cut it 150 -> 25 and every assert downstream reads it from the catalog, so
  -- a number in this comment would be one more thing to forget to update.
  perform public.reward_grant('combat', gen_random_uuid(), uZ, null,
    '{"items": [{"item_id": "weapon_parts", "quantity": 8}, {"item_id": "pirate_alloy", "quantity": 4}, {"item_id": "scrap", "quantity": 12}]}'::jsonb);
  -- 0333: a craft draws on the store of the port the NAMED ship is DOCKED at. s_cmd is freshly
  -- commissioned, so it sits at Haven Reach — the same store the NULL-base grant above landed in
  -- (the player's oldest active base is the Home Base, whose location_id IS Haven).
  r := pg_temp.call_as(uZ, format('public.craft_module(''dzc-gun-1'', ''autocannon_battery'', %L::uuid)', s_cmd));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL craft: %', r; end if;
  v_mod := (r->>'instance_id')::uuid;
  r := pg_temp.call_as(uZ, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''dzc-fit-1'')', v_mod, s_cmd));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL fit: %', r; end if;

  -- team A
  r := pg_temp.call_as(uZ, 'public.upsert_ship_group(1, ''Danger'')');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL group create: %', r; end if;
  insert into dzc values ('gZ', (r->>'group_id')::uuid);
  r := pg_temp.call_as(uZ, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_cmd, (select v from dzc where k='gZ')));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL assign: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.set_fleet_command_ship(%L::uuid, true)', s_cmd));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL designate command: %', r; end if;

  -- a SECOND ship + team B for the stop/re-order/evasion scenario.
  r := pg_temp.call_as(uZ, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL second ship: %', r; end if;
  select main_ship_id into s_b from public.main_ship_instances
   where player_id = uZ and main_ship_id <> s_cmd limit 1;
  if s_b is null then raise exception 'PROVISION FAIL: no second ship materialised'; end if;
  insert into dzc values ('s_b', s_b);
  r := pg_temp.call_as(uZ, 'public.upsert_ship_group(2, ''Danger B'')');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL group B create: %', r; end if;
  insert into dzc values ('gB', (r->>'group_id')::uuid);
  r := pg_temp.call_as(uZ, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_b, (select v from dzc where k='gB')));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL assign B: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.set_fleet_command_ship(%L::uuid, true)', s_b));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL designate command B: %', r; end if;

  raise notice 'setup ok: two teams provisioned, docked at Haven (team A armed)';
end $$;

-- ════════ DRAW A ZONE ON THE DEPARTURE LEG + ORDER THE FLEET THROUGH IT ══════════════════════════════
-- GEOMETRY, engineered rather than incidental: the group departs from its Haven dock (origin O) and is
-- sent to a coordinate T 1000 units away. A 200-wide square zone straddles the MIDPOINT of O→T, so the
-- leg is guaranteed to pass through its interior — and, decisively for 0301, the zone's near EDGE is
-- 100 units before its CENTRE. The entry point and the old centroid foot are therefore provably
-- different points, and the proof below pins the entry one.
do $$
declare
  r jsonb;
  uZ uuid := (select v from dzc where k='uZ');
  gZ uuid := (select v from dzc where k='gZ');
  v_hunt uuid;
  o_x double precision; o_y double precision;
  t_x double precision; t_y double precision;
  m_x double precision; m_y double precision;
  v_verts jsonb;
begin
  select id into v_hunt from public.locations
    where activity_type = 'hunt_pirates' and status = 'active'
    order by min_power_required asc, base_difficulty asc limit 1;
  if v_hunt is null then raise exception 'SEND FAIL: no active hunt_pirates location to link the zone'; end if;
  insert into dzc values ('v_hunt', v_hunt);

  select l.x, l.y into o_x, o_y
    from public.main_ship_instances s
    join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = uZ and f.status = 'present'
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
    join public.locations l on l.id = lp.location_id
   where s.group_id = gZ
   limit 1;
  if o_x is null then raise exception 'SEND FAIL: could not resolve the group''s docked origin'; end if;

  t_x := case when o_x <= 0 then o_x + 1000 else o_x - 1000 end;
  t_y := o_y;
  m_x := (o_x + t_x) / 2;
  m_y := o_y;
  insert into dzn values ('o_x', o_x), ('o_y', o_y), ('t_x', round(t_x)), ('t_y', round(t_y)),
                         ('m_x', m_x), ('m_y', m_y);

  v_verts := jsonb_build_array(
    jsonb_build_array(m_x - 100, m_y - 100),
    jsonb_build_array(m_x + 100, m_y - 100),
    jsonb_build_array(m_x + 100, m_y + 100),
    jsonb_build_array(m_x - 100, m_y + 100));
  r := pg_temp.call_as(uZ, format('public.pirate_zone_create(%L, %L::jsonb, %L::uuid)', 'DZC Test Zone', v_verts::text, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'SEND FAIL: pirate_zone_create %', r; end if;
  insert into dzc values ('v_zone', (r->>'zone_id')::uuid);

  -- ★ THE OWNER'S ACTION: send the group to a coordinate whose leg crosses the danger zone. It is a
  -- ★ ROUTE, so the "an ambush abandons the rest of the plotted route" property is observable too.
  r := pg_temp.call_as(uZ, format(
        'public.command_ship_group_go_route(%L::uuid, %L::jsonb, null, %s, %s)',
        gZ,
        jsonb_build_array(jsonb_build_object('x', round(t_x), 'y', round(t_y)))::text,
        round(t_x), round(t_y) + 50));
  if (r->>'ok')::boolean is not true then raise exception 'SEND FAIL: command_ship_group_go_route %', r; end if;
  insert into dzc values ('v_fleet', (r->>'fleet_id')::uuid), ('v_mv', (r->>'movement_id')::uuid);
  insert into dzc values ('r_order', gen_random_uuid());
  create temp table dzr(k text primary key, v jsonb) on commit preserve rows;
  insert into dzr values ('order', r);
end $$;

-- ════════ DZCOMBAT_PASS_ORDER: the order STARTS A JOURNEY. It does not start a fight. ════════════════
do $$
declare
  r jsonb := (select v from dzr where k='order');
  n int;
  v_fleet uuid := (select v from dzc where k='v_fleet');
  v_mv uuid := (select v from dzc where k='v_mv');
  pi record; mv record; fl record;
  m_x double precision := (select v from dzn where k='m_x');
  v_expect timestamptz;
begin
  -- the envelope: the new contract, and the ABSENCE of the retired one.
  if (r->>'order_outcome') is distinct from 'movement_started' then
    raise exception 'DZCOMBAT FAIL ORDER: order_outcome is % (want movement_started): %', r->>'order_outcome', r;
  end if;
  if r ? 'intercepted' or r ? 'intercept_encounter_id' then
    raise exception 'DZCOMBAT FAIL ORDER: the envelope still carries the retired intercepted / intercept_encounter_id fields: %', r;
  end if;
  if (r->>'movement_id') is null or (r->>'movement_eta') is null then
    raise exception 'DZCOMBAT FAIL ORDER: the envelope lacks movement_id / movement_eta: %', r;
  end if;

  -- THE FLEET IS TRAVELLING. This is the whole defect, inverted into an assertion.
  select * into mv from public.fleet_movements where id = v_mv;
  if mv.status <> 'moving' then
    raise exception 'DZCOMBAT FAIL ORDER: the leg is % at order commit — the order-time ambush is still cancelling it', mv.status;
  end if;
  select * into fl from public.fleets where id = v_fleet;
  if fl.status <> 'moving' or fl.location_mode <> 'movement' or fl.active_movement_id is distinct from v_mv then
    raise exception 'DZCOMBAT FAIL ORDER: the fleet is %/% (active_movement %) at order commit — it was moved by the order', fl.status, fl.location_mode, fl.active_movement_id;
  end if;
  if fl.space_x is not null or fl.space_y is not null then
    raise exception 'DZCOMBAT FAIL ORDER: the fleet was PARKED at order time (space %,%) — fleet_set_in_space still runs on the order path', fl.space_x, fl.space_y;
  end if;

  -- NO COMBAT EXISTS YET, and no manifest was frozen.
  select count(*) into n from public.combat_encounters where fleet_id = v_fleet;
  if n <> 0 then raise exception 'DZCOMBAT FAIL ORDER: % encounter(s) already exist at order commit (want 0)', n; end if;
  select count(*) into n from public.group_sortie_members where fleet_id = v_fleet;
  if n <> 0 then raise exception 'DZCOMBAT FAIL ORDER: % manifest row(s) frozen at order commit (want 0)', n; end if;

  -- EXACTLY ONE OWED AMBUSH, and it is actionable.
  select count(*) into n from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if n <> 1 then raise exception 'DZCOMBAT FAIL ORDER: % pending intercept rows for this leg (want exactly 1)', n; end if;
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if pi.entry_x is null or pi.entry_y is null or pi.entry_fraction is null or pi.trigger_at is null then
    raise exception 'DZCOMBAT FAIL ORDER: the pending row is not actionable (entry %,% fraction % trigger %)', pi.entry_x, pi.entry_y, pi.entry_fraction, pi.trigger_at;
  end if;

  -- THE POINT IS THE ZONE'S EDGE, NOT ITS CENTRE. The square's near edge is at m_x -/+ 100; the old
  -- centroid-foot formula would have answered m_x exactly.
  if abs(pi.entry_x - m_x) < 1e-6 then
    raise exception 'DZCOMBAT FAIL ORDER: the ambush point is the zone CENTRE (%) — the retired ST_ClosestPoint(leg, centroid) formula is still in play', pi.entry_x;
  end if;
  if abs(abs(pi.entry_x - m_x) - 100) > 1e-6 then
    raise exception 'DZCOMBAT FAIL ORDER: the ambush point is % — it is not on the zone boundary 100 units from the centre (%)', pi.entry_x, m_x;
  end if;

  -- THE TIME IS THE LEG'S OWN CLOCK, INTERPOLATED. Proven before any time travel touches it.
  v_expect := mv.depart_at + (mv.arrive_at - mv.depart_at) * pi.entry_fraction;
  if abs(extract(epoch from (pi.trigger_at - v_expect))) > 1e-3 then
    raise exception 'DZCOMBAT FAIL ORDER: trigger_at % is not depart + duration*entry_fraction (%)', pi.trigger_at, v_expect;
  end if;
  if pi.trigger_at <= now() then
    raise exception 'DZCOMBAT FAIL ORDER: the ambush is already due at order commit — the leg is too short to prove the deferral';
  end if;

  raise notice 'DZCOMBAT_PASS_ORDER ok: the order started a JOURNEY (movement % moving, fleet moving, unparked, zero encounters, zero manifest rows) and scheduled exactly ONE ambush at the zone EDGE (entry %,% at fraction %, trigger % = depart + duration*fraction) — not at the zone centre, and not now',
    v_mv, pi.entry_x, pi.entry_y, pi.entry_fraction, pi.trigger_at;
end $$;

-- ════════ DZCOMBAT_PASS_NOTYET: the processor does NOT fire before trigger_at ════════════════════════
do $$
declare
  n int;
  v_mv uuid := (select v from dzc where k='v_mv');
  v_fleet uuid := (select v from dzc where k='v_fleet');
begin
  perform public.process_fleet_movements();

  select count(*) into n from public.combat_encounters where fleet_id = v_fleet;
  if n <> 0 then raise exception 'DZCOMBAT FAIL NOTYET: % encounter(s) opened before trigger_at', n; end if;
  select count(*) into n from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if n <> 1 then raise exception 'DZCOMBAT FAIL NOTYET: the owed ambush is no longer pending (% rows) before trigger_at', n; end if;
  select count(*) into n from public.fleet_movements where id = v_mv and status = 'moving';
  if n <> 1 then raise exception 'DZCOMBAT FAIL NOTYET: the leg stopped being ''moving'' before trigger_at'; end if;

  raise notice 'DZCOMBAT_PASS_NOTYET ok: a full process_fleet_movements() run before trigger_at opened no encounter, left the ambush pending and the leg moving';
end $$;

-- ════════ DZCOMBAT_PASS_FIRE: due → the ambush fires INSTEAD of the arrival ══════════════════════════
-- The rewind puts BOTH trigger_at AND arrive_at in the past, so this single processor run has the
-- arrival and the ambush available at the same instant. Firing must win — that is "arrival settlement
-- cannot precede intercept resolution", proven by outcome rather than by reading the source.
do $$
declare
  n int;
  v_mv uuid := (select v from dzc where k='v_mv');
  v_fleet uuid := (select v from dzc where k='v_fleet');
  v_hunt uuid := (select v from dzc where k='v_hunt');
  pi record; mv record; fl record; v_enc uuid;
begin
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');

  perform public.process_fleet_movements();

  select * into pi from public.pirate_intercepts where movement_id = v_mv order by created_at desc limit 1;
  if pi.lifecycle_state <> 'fired' then
    raise exception 'DZCOMBAT FAIL FIRE: the owed ambush is % after the processor run (want fired)', pi.lifecycle_state;
  end if;
  if pi.resolved_at is null then raise exception 'DZCOMBAT FAIL FIRE: a fired row carries no resolved_at'; end if;

  select * into mv from public.fleet_movements where id = v_mv;
  if mv.status <> 'cancelled' then
    raise exception 'DZCOMBAT FAIL FIRE: the leg is % — an arrival was settled past an ambush that was already owed', mv.status;
  end if;

  select * into fl from public.fleets where id = v_fleet;
  if fl.location_mode <> 'space' or fl.status <> 'idle' then
    raise exception 'DZCOMBAT FAIL FIRE: the ambushed fleet is %/% (want idle/space)', fl.status, fl.location_mode;
  end if;
  if abs(fl.space_x - pi.entry_x) > 1e-6 or abs(fl.space_y - pi.entry_y) > 1e-6 then
    raise exception 'DZCOMBAT FAIL FIRE: the fleet is parked at (%,%) but was ambushed at (%,%)', fl.space_x, fl.space_y, pi.entry_x, pi.entry_y;
  end if;
  if fl.current_location_id is not null then
    raise exception 'DZCOMBAT FAIL FIRE: the fleet is present at a location — it TELEPORTED instead of stopping where it was ambushed';
  end if;

  select count(*) into n from public.combat_encounters where fleet_id = v_fleet and status = 'active';
  if n <> 1 then raise exception 'DZCOMBAT FAIL FIRE: % active encounter(s) for the ambushed fleet (want 1)', n; end if;
  select id into v_enc from public.combat_encounters where fleet_id = v_fleet and status = 'active';
  if pi.encounter_id is distinct from v_enc then
    raise exception 'DZCOMBAT FAIL FIRE: the intercept row does not record the encounter it opened';
  end if;
  insert into dzc values ('v_enc', v_enc);

  -- the rest of the plotted route was abandoned, not silently resumed later.
  select count(*) into n from public.fleet_route_legs where fleet_id = v_fleet;
  if n <> 0 then
    raise exception 'DZCOMBAT FAIL FIRE: % route leg(s) still queued for the ambushed fleet — the route would resume from an unplanned position', n;
  end if;

  raise notice 'DZCOMBAT_PASS_FIRE ok: with the arrival AND the ambush both due, one processor run FIRED the ambush (row fired, leg cancelled not arrived), parked the fleet at the recorded entry point (%,%), opened encounter % and abandoned the remaining route',
    pi.entry_x, pi.entry_y, v_enc;
end $$;

-- ════════ DZCOMBAT_PASS_ENGAGEMENT: one point, written once, by the creator ══════════════════════════
do $$
declare
  e record; pi record; cu record;
  v_mv uuid := (select v from dzc where k='v_mv');
  v_enc uuid := (select v from dzc where k='v_enc');
  s_cmd uuid := (select v from dzc where k='s_cmd');
  v_hunt uuid := (select v from dzc where k='v_hunt');
begin
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'fired';
  select * into e  from public.combat_encounters where id = v_enc;

  if e.engagement_x is null or abs(e.engagement_x - pi.entry_x) > 1e-6
     or e.engagement_y is null or abs(e.engagement_y - pi.entry_y) > 1e-6 then
    raise exception 'DZCOMBAT FAIL ENGAGEMENT: the encounter says the fight is at (%,%) but the fleet was ambushed at (%,%)',
      e.engagement_x, e.engagement_y, pi.entry_x, pi.entry_y;
  end if;
  -- IDENTITY is still the linked location; only POSITION moved.
  if e.location_id is distinct from v_hunt then
    raise exception 'DZCOMBAT FAIL ENGAGEMENT: the encounter lost its linked location identity';
  end if;

  -- the command ship is seeded EXACTLY on the engagement point (the 0234 formation rule), which is
  -- only true if the creator was handed the point rather than being corrected afterwards.
  select * into cu from public.combat_units where encounter_id = v_enc and main_ship_id = s_cmd;
  if cu.pos_x is null or abs(cu.pos_x - e.engagement_x) > 1e-6
     or cu.pos_y is null or abs(cu.pos_y - e.engagement_y) > 1e-6 then
    raise exception 'DZCOMBAT FAIL ENGAGEMENT: the command ship sits at (%,%), not on the engagement point (%,%)',
      cu.pos_x, cu.pos_y, e.engagement_x, e.engagement_y;
  end if;

  raise notice 'DZCOMBAT_PASS_ENGAGEMENT ok: encounter.engagement_x/y = the recorded entry point (%,%), the command ship is seeded exactly on it, and the encounter still carries its linked location as IDENTITY',
    e.engagement_x, e.engagement_y;
end $$;

-- ════════ DZCOMBAT_PASS_ONCE: it cannot fire twice ══════════════════════════════════════════════════
do $$
declare
  n int; r jsonb;
  v_mv uuid := (select v from dzc where k='v_mv');
  v_fleet uuid := (select v from dzc where k='v_fleet');
begin
  perform public.process_fleet_movements();
  r := public.pirate_intercept_resolve_due_for_movement(v_mv);
  if coalesce((r->>'fired')::boolean, false) then
    raise exception 'DZCOMBAT FAIL ONCE: a terminal intercept row fired a SECOND time: %', r;
  end if;

  select count(*) into n from public.combat_encounters where fleet_id = v_fleet;
  if n <> 1 then raise exception 'DZCOMBAT FAIL ONCE: % encounters for the ambushed fleet after re-running the resolver (want 1)', n; end if;
  select count(*) into n from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'fired';
  if n <> 1 then raise exception 'DZCOMBAT FAIL ONCE: % fired rows for one leg (want 1)', n; end if;
  select count(*) into n from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if n <> 0 then raise exception 'DZCOMBAT FAIL ONCE: % rows still pending for a leg that already fired', n; end if;

  raise notice 'DZCOMBAT_PASS_ONCE ok: a second processor run and a direct second resolve produced no second encounter and could not re-fire the terminal row (the conditional claim + the UNIQUE one-pending-per-movement index)';
end $$;

-- ════════ DZCOMBAT_PASS_EVASION: STOP and RE-ORDER cannot outrun an ambush ══════════════════════════
do $$
declare
  r jsonb; n int;
  uZ uuid := (select v from dzc where k='uZ');
  gB uuid := (select v from dzc where k='gB');
  t_x double precision := (select v from dzn where k='t_x');
  t_y double precision := (select v from dzn where k='t_y');
  mv1 uuid; mv2 uuid; fB uuid; pi record; mv record;
begin
  -- B1. ORDER, then STOP BEFORE the ambush is due -> the owed ambush is CANCELLED, not left dangling.
  r := pg_temp.call_as(uZ, format('public.command_ship_group_go(%L::uuid, null, %s, %s)', gB, t_x, t_y));
  if (r->>'ok')::boolean is not true then raise exception 'EVASION FAIL B1 send: %', r; end if;
  fB  := (r->>'fleet_id')::uuid;
  mv1 := (r->>'movement_id')::uuid;
  select count(*) into n from public.pirate_intercepts where movement_id = mv1 and lifecycle_state = 'pending';
  if n <> 1 then raise exception 'EVASION FAIL B1: % pending rows on the first leg (want 1)', n; end if;

  r := pg_temp.call_as(uZ, format('public.command_ship_group_stop(%L::uuid)', gB));
  if coalesce((r->>'stopped')::boolean, false) is not true then raise exception 'EVASION FAIL B1 stop: %', r; end if;
  select count(*) into n from public.pirate_intercepts
   where movement_id = mv1 and lifecycle_state = 'cancelled' and cancel_reason = 'player_stop';
  if n <> 1 then raise exception 'EVASION FAIL B1: stopping before the ambush was due did not cancel it as player_stop (% rows)', n; end if;
  select count(*) into n from public.pirate_intercepts where movement_id = mv1 and lifecycle_state = 'pending';
  if n <> 0 then raise exception 'EVASION FAIL B1: % rows still pending on a cancelled leg', n; end if;

  -- B2. RE-ORDER BEFORE due -> the old leg's ambush is cancelled as superseded, and the NEW leg is
  --     planned from scratch (the player really did change course, and the new course is rolled).
  r := pg_temp.call_as(uZ, format('public.command_ship_group_go(%L::uuid, null, %s, %s)', gB, t_x, t_y));
  if (r->>'ok')::boolean is not true then raise exception 'EVASION FAIL B2 send: %', r; end if;
  mv1 := (r->>'movement_id')::uuid;
  r := pg_temp.call_as(uZ, format('public.command_ship_group_go(%L::uuid, null, %s, %s)', gB, t_x, t_y + 10));
  if (r->>'ok')::boolean is not true then raise exception 'EVASION FAIL B2 reorder: %', r; end if;
  mv2 := (r->>'movement_id')::uuid;
  if mv2 = mv1 then raise exception 'EVASION FAIL B2: the re-order did not mint a new leg'; end if;
  select count(*) into n from public.pirate_intercepts
   where movement_id = mv1 and lifecycle_state = 'cancelled' and cancel_reason = 'movement_superseded';
  if n <> 1 then raise exception 'EVASION FAIL B2: the superseded leg''s ambush was not cancelled (% rows)', n; end if;
  select count(*) into n from public.pirate_intercepts where movement_id = mv2 and lifecycle_state = 'pending';
  if n <> 1 then raise exception 'EVASION FAIL B2: the NEW leg was not re-planned (% pending rows)', n; end if;

  -- B3. NOW LET IT BECOME DUE, AND TRY TO STOP. The brake must be REFUSED and the ambush must fire.
  select * into mv from public.fleet_movements where id = mv2;
  perform pg_temp.rewind_leg(mv2, (mv.arrive_at - now()) + interval '5 seconds');
  r := pg_temp.call_as(uZ, format('public.command_ship_group_stop(%L::uuid)', gB));
  if coalesce((r->>'ok')::boolean, true) is not false or (r->>'reason') is distinct from 'intercepted_in_transit' then
    raise exception 'EVASION FAIL B3: stopping AFTER the ambush was due returned % — the evasion window is open', r;
  end if;
  select * into pi from public.pirate_intercepts where movement_id = mv2 order by created_at desc limit 1;
  if pi.lifecycle_state <> 'fired' then
    raise exception 'EVASION FAIL B3: the brake left the due ambush % instead of firing it', pi.lifecycle_state;
  end if;
  select count(*) into n from public.combat_encounters where fleet_id = fB and status = 'active';
  if n <> 1 then raise exception 'EVASION FAIL B3: % active encounter(s) for the fleet that tried to brake out of the ambush (want 1)', n; end if;

  raise notice 'DZCOMBAT_PASS_EVASION ok: STOP before due cancelled the owed ambush (player_stop); a re-order before due cancelled it (movement_superseded) and re-planned the new leg; STOP after it was due was REFUSED (intercepted_in_transit) and the ambush fired anyway';
end $$;

-- ════════ DZCOMBAT_PASS_SPATIAL: the intercept opened a POSITIONED (S4-renderable) encounter ════════
do $$
declare
  n int; n_pos int;
  v_enc uuid := (select v from dzc where k='v_enc');
  s_cmd uuid := (select v from dzc where k='s_cmd');
  v_cat_range numeric;
begin
  select count(*) into n from public.combat_units where encounter_id = v_enc and side = 'player';
  if n < 1 then raise exception 'DZCOMBAT FAIL SPATIAL: no player combat_units in the intercept encounter (want the group members)'; end if;

  select count(*) into n_pos from public.combat_units
    where encounter_id = v_enc and side = 'player' and pos_x is not null and pos_y is not null and move_speed is not null;
  if n_pos <> n then raise exception 'DZCOMBAT FAIL SPATIAL: only %/% player units carry positions — the encounter is NOT spatial (map would render nothing)', n_pos, n; end if;

  -- the expected range is DERIVED from the deployed catalog row at assert time (0313 repoint: the
  -- old form hard-coded the 150 seed — an ambient default this proof never owned).
  select range into v_cat_range from public.module_types where id = 'autocannon_battery';
  select count(*) into n from public.combat_units
    where encounter_id = v_enc and main_ship_id = s_cmd
      and (weapons_json->0->>'range')::numeric = v_cat_range;
  if n <> 1 then raise exception 'DZCOMBAT FAIL SPATIAL: command ship weapons_json did not carry the fitted range (want 1 row at the catalog autocannon_battery range %)', v_cat_range; end if;

  raise notice 'DZCOMBAT_PASS_SPATIAL ok: the intercept opened a SPATIAL encounter — % player units positioned, command ship carries its catalog %-range ring', n_pos, v_cat_range;
end $$;

-- ════════ DZCOMBAT_PASS_PIRATEFIRE: the wave arrives SILENT, CLOSES, then FIRES for real ═════════════
-- ── 0336 RE-PREMISED: THE SPAWN TICK IS NO LONGER THE FIRING TICK, AND THAT IS A NEW PROPERTY ─────
-- WHAT THIS BLOCK PROVED BEFORE: after ONE process_combat_ticks() a synthetic pirate exists, carries a
-- position, has emitted a spatial missile_salvo carrying unit_id/target_id, and has taken damage back.
-- Every one of those is still true. The only thing that died is the TICK NUMBER: 0336 spawns a wave at
-- (the MEASURED player-formation extent + THAT wave's own weapon range + 1) from the engagement anchor,
-- so the wave arrives strictly outside its own reach of EVERY player ship by construction and cannot
-- fire on the tick it spawns. "on tick 1" was a statement about the pre-0336 geometry, where every
-- enemy was inserted on the anchor — i.e. on top of the lead, at distance 0 — and therefore shot the
-- instant it existed. Asserting it now is asserting a world that no longer exists.
--
-- WHAT IS ASSERTED NOW, AND WHY IT IS AT LEAST AS STRONG:
--   (1) NEW, AND ONLY 0336 MAKES IT STATABLE — the wave is SILENT on its spawn tick. The old form
--       could not have asserted this: before 0336 the true answer was "it fires immediately". A body
--       that ever lets a freshly-spawned wave shoot across its own structural clearance fails HERE.
--   (2) THE FIRE ITSELF, OBSERVED RATHER THAN ASSUMED — ticks are driven until a pirate-sourced
--       missile_salvo actually exists. The exit condition is the OBSERVATION, never a tick count: how
--       many closing ticks a wave needs is a function of the site's difficulty (which sets both the
--       wave's range and its speed) and of the fleet's own combat speed, and pinning a number here
--       would re-introduce exactly the ambient assumption 0336 removed. The iteration is BOUNDED and
--       a wave that never fires fails loudly, with the encounter status in the message.
--   (3) STRONGER PAYLOAD — the old form only checked that the keys 'unit_id' and 'target_id' were
--       PRESENT. They must now RESOLVE: unit_id to an enemy row OF THIS ENCOUNTER and target_id to a
--       player SHIP row of it. A salvo addressed to nothing used to pass this block.
--   (4) UNCHANGED — the pirate took real damage back (hp_current < hp_max), now NULL-pinned so an
--       unwritten hp column cannot make the comparison vacuous.
-- THE CADENCE DRIVER IS THE FILE'S OWN. This block used to hand-roll the rewind-then-tick idiom;
-- pg_temp.ae_tick IS that idiom, already counted by the harness, so the block composes it and the
-- proof ends up with one FEWER direct engine call site rather than one more.
do $$
declare
  n int; i int;
  v_enc uuid := (select v from dzc where k='v_enc');
  v_e_hpmax double precision; v_e_hpcur double precision; v_e_dist double precision;
  v_eng_x double precision; v_eng_y double precision;
  v_tick int; v_fire_tick int := null; v_status text;
begin
  select count(*) into n from public.combat_units where encounter_id = v_enc and side = 'enemy';
  if n <> 0 then raise exception 'DZCOMBAT FAIL PIRATEFIRE precondition: % enemy rows before the first tick (want 0)', n; end if;

  -- ── THE SPAWN TICK ────────────────────────────────────────────────────────────────────────────
  perform pg_temp.ae_tick(v_enc);
  select tick_number into v_tick from public.combat_encounters where id = v_enc;
  if v_tick is distinct from 1 then
    raise exception 'DZCOMBAT FAIL PIRATEFIRE: the spawn tick is numbered % (want 1) — the silence assert below would be reading a tick that is not the one the wave arrived on', v_tick;
  end if;

  select count(*) into n from public.combat_units
    where encounter_id = v_enc and side = 'enemy' and unit_type_id = 'pirate_synthetic' and pos_x is not null;
  if n < 1 then raise exception 'DZCOMBAT FAIL PIRATEFIRE: no positioned synthetic pirate spawned after tick 1'; end if;

  -- ── (1) 0336's NEW PROPERTY: A WAVE CANNOT SHOOT ON THE TICK IT ARRIVES ───────────────────────
  select count(*) into n from public.combat_events
    where encounter_id = v_enc and tick_number = 1 and event_type = 'missile_salvo' and source = 'pirate';
  if n <> 0 then
    raise exception 'DZCOMBAT FAIL PIRATEFIRE: % pirate salvo(s) on the SPAWN tick — 0336 stands a wave at (measured player extent + its own range + 1), i.e. strictly outside its own reach of every player ship, so it MUST close before it can fire', n;
  end if;

  -- ── (2) DRIVE TICKS UNTIL THE WAVE HAS CLOSED AND ACTUALLY FIRED ─────────────────────────────
  for i in 1 .. 12 loop
    exit when v_fire_tick is not null;
    select status into v_status from public.combat_encounters where id = v_enc;
    if v_status is distinct from 'active' then
      raise exception 'DZCOMBAT FAIL PIRATEFIRE: the encounter went % during the approach — it never got to fire, so this block observed nothing it exists to prove', v_status;
    end if;
    perform pg_temp.ae_tick(v_enc);
    select tick_number into v_tick from public.combat_encounters where id = v_enc;
    select count(*) into n from public.combat_events
      where encounter_id = v_enc and tick_number = v_tick and event_type = 'missile_salvo'
        and source = 'pirate' and payload_json ? 'unit_id' and payload_json ? 'target_id';
    if n > 0 then v_fire_tick := v_tick; end if;
  end loop;
  if v_fire_tick is null then
    raise exception 'DZCOMBAT FAIL PIRATEFIRE: no pirate-sourced spatial missile_salvo (with unit_id/target_id) within 12 ticks of the spawn — the wave never closed into its own range';
  end if;
  -- NON-VACUITY: the loop must have OBSERVED a closing approach. Tick 1 is pinned silent above, so a
  -- first salvo on tick 1 would mean the two asserts contradict each other rather than that the loop ran.
  if v_fire_tick <= 1 then
    raise exception 'DZCOMBAT FAIL PIRATEFIRE: the first pirate salvo is recorded on tick % — the spawn tick was pinned SILENT, so this block observed no closing approach at all', v_fire_tick;
  end if;

  -- ── (3) THE PAYLOAD MUST RESOLVE, NOT MERELY EXIST ───────────────────────────────────────────
  -- Compared as TEXT on purpose: a malformed payload must fail as a missing pair here, not as an
  -- uncaught invalid-uuid cast somewhere inside the exists().
  select count(*) into n from public.combat_events ev
    where ev.encounter_id = v_enc and ev.tick_number = v_fire_tick
      and ev.event_type = 'missile_salvo' and ev.source = 'pirate' and ev.target = 'player'
      and exists (select 1 from public.combat_units u
                   where u.encounter_id = v_enc and u.side = 'enemy'
                     and u.id::text = ev.payload_json->>'unit_id')
      and exists (select 1 from public.combat_units u
                   where u.encounter_id = v_enc and u.side = 'player' and u.main_ship_id is not null
                     and u.id::text = ev.payload_json->>'target_id');
  if n < 1 then
    raise exception 'DZCOMBAT FAIL PIRATEFIRE: the tick-% pirate salvo does not RESOLVE to a real firer/target pair — unit_id must name an enemy row of this encounter and target_id a player SHIP row of it', v_fire_tick;
  end if;

  -- WHERE IT STANDS. The wave is laid out on a ring around the ENGAGEMENT anchor — the point the
  -- ambush recorded — not around the location centre, and (since 0336) not ON the anchor either.
  -- Measured here for the notice and NULL-pinned so the notice cannot report a distance from nothing;
  -- the exact ring is pinned where it is OWNED (DZCOMBAT_PASS_WAVERING, DZCOMBAT_PASS_CLOSURE).
  select engagement_x, engagement_y into v_eng_x, v_eng_y from public.combat_encounters where id = v_enc;
  if v_eng_x is null or v_eng_y is null then
    raise exception 'DZCOMBAT FAIL PIRATEFIRE: the encounter carries no engagement anchor (engagement_x/y is NULL) — the distance below would be measured from nothing';
  end if;
  select public.osn_distance(pos_x, pos_y, v_eng_x, v_eng_y) into v_e_dist
    from public.combat_units where encounter_id = v_enc and side = 'enemy' order by id limit 1;
  if v_e_dist is null then raise exception 'DZCOMBAT FAIL PIRATEFIRE: could not measure the pirate distance'; end if;

  -- ── (4) IT TOOK REAL DAMAGE BACK ─────────────────────────────────────────────────────────────
  select hp_max, hp_current into v_e_hpmax, v_e_hpcur
    from public.combat_units where encounter_id = v_enc and side = 'enemy' order by id limit 1;
  if v_e_hpmax is null or v_e_hpcur is null then
    raise exception 'DZCOMBAT FAIL PIRATEFIRE: the pirate carries a NULL hp column (max %, current %) — the damage comparison below would be vacuous', v_e_hpmax, v_e_hpcur;
  end if;
  if v_e_hpcur >= v_e_hpmax then
    raise exception 'DZCOMBAT FAIL PIRATEFIRE: pirate hp_current (%) not below hp_max (%) — no damage exchanged', v_e_hpcur, v_e_hpmax;
  end if;

  raise notice 'DZCOMBAT_PASS_PIRATEFIRE ok: the wave arrived SILENT on its spawn tick (0336 stands it outside its own reach by construction — zero pirate salvos on tick 1), then CLOSED and fired its first spatial missile_salvo on tick %, whose unit_id/target_id RESOLVE to a real enemy row and a real player ship row of this encounter; it stands % from the engagement anchor (the ambush point, never the location centre) and took real damage back (hp %/%)',
    v_fire_tick, round(v_e_dist::numeric, 2), v_e_hpcur, v_e_hpmax;
end $$;

-- ════════ DZCOMBAT_PASS_MANIFESTHELD: an ambush on a fleet holding a RETAINED manifest ══════════════
-- THE REGRESSION THIS FILE EXISTS TO CATCH FROM NOW ON (added with migration 0303, 2026-07-27).
--
-- The owner hit this in the live game: combat fires the first time and never again, the fleet is
-- yanked to the ambush point, and it is then permanently refused a new course with 'group_on_sortie'.
--
-- Cause: the ambush resolver's manifest freeze is idempotent (ON CONFLICT DO NOTHING) and the
-- zero-manifest guard measured it with `get diagnostics ... row_count` — rows INSERTED, not rows
-- PRESENT. Any ambush of a fleet that ALREADY carries sortie-manifest rows therefore inserts nothing,
-- reads zero, and the guard parks the fleet and opens no combat. 0303 makes the guard count.
--
-- ── THE FIXTURE IS PRODUCTION'S ACTUAL SEQUENCE ─────────────────────────────────────────────────────
-- Reconstructed from the live rows rather than imagined, and from what actually plans an ambush:
-- send_ship_group_hunt does NOT plan one (0301 asserts only command_ship_group_go and
-- process_pirate_route_legs plan the legs they mint). So on fleet e2151a71 the order was:
--   1. a HUNT SEND froze a 4-row manifest at 14:54:33Z (send_ship_group_hunt is its sole writer);
--   2. that sortie ENDED, and the manifest rows were RETAINED (0047 keeps a finished sortie's
--      manifest for up to 14 days) — which is the whole trap;
--   3. a later course change crossed the Snare zone, and THAT leg's ambush hit a fleet already
--      holding manifest rows: 14:57:07Z and 14:57:48Z, both empty_manifest, both no encounter.
-- This block reproduces exactly that: hunt → finish the sortie → re-order through a zone → ambush.
--
-- The fight in step 2 is made trivial and harmless on purpose, with the knobs set BEFORE the wave
-- spawns: an enemy is snapshotted with its weapons at spawn time, so zeroing damage afterwards
-- disarms nothing (an earlier draft learned that by killing its own fleet). enemy_hp_base=1 makes the
-- wave die to the first shot; enemy_attack_base=0 means it never fires back. Both restored after.
--
-- Two vacuity guards make a false green impossible:
--   1. the manifest must be non-empty BEFORE the ambush resolves;
--   2. the freeze must insert ZERO rows across the resolve — otherwise the pre-0303 code passes too.
do $$
declare
  r jsonb; n int; n_before int; n_after int;
  uZ uuid := (select v from dzc where k='uZ');
  v_hunt uuid := (select v from dzc where k='v_hunt');
  s_r uuid; gR uuid; v_fleet uuid; v_mv uuid; v_enc uuid; v_enc2 uuid;
  f_x double precision; f_y double precision; t_x double precision; t_y double precision;
  v_verts jsonb; v_hp_before double precision; v_atk_before double precision;
  pi record; mv record; fl record;
begin
  -- ── A third ship + team, provisioned exactly like the others (real RPCs only). ───────────────────
  r := pg_temp.call_as(uZ, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'MANIFESTHELD FAIL: commission: %', r; end if;
  select main_ship_id into s_r from public.main_ship_instances
   where player_id = uZ
     and main_ship_id not in ((select v from dzc where k='s_cmd'), (select v from dzc where k='s_b'))
   limit 1;
  if s_r is null then raise exception 'MANIFESTHELD FAIL: no third ship materialised'; end if;

  r := pg_temp.call_as(uZ, 'public.upsert_ship_group(3, ''Danger R'')');
  if (r->>'ok')::boolean is not true then raise exception 'MANIFESTHELD FAIL: group: %', r; end if;
  gR := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uZ, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_r, gR));
  if (r->>'ok')::boolean is not true then raise exception 'MANIFESTHELD FAIL: assign: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.set_fleet_command_ship(%L::uuid, true)', s_r));
  if (r->>'ok')::boolean is not true then raise exception 'MANIFESTHELD FAIL: designate command: %', r; end if;

  -- ── Make this fleet's hunt wave harmless BEFORE it spawns (see header). ──────────────────────────
  select coalesce(public.cfg_num('enemy_hp_base'), 0)     into v_hp_before;
  select coalesce(public.cfg_num('enemy_attack_base'), 0) into v_atk_before;
  perform public.set_game_config('enemy_hp_base',     '1'::jsonb);
  perform public.set_game_config('enemy_attack_base', '0'::jsonb);

  -- ── 1. THE HUNT SEND — the manifest's sole writer. ───────────────────────────────────────────────
  r := pg_temp.call_as(uZ, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gR, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'MANIFESTHELD FAIL: hunt send: %', r; end if;
  v_fleet := (r->>'fleet_id')::uuid;
  v_mv    := (r->>'movement_id')::uuid;

  select count(*) into n_before from public.group_sortie_members where fleet_id = v_fleet;
  if n_before = 0 then
    raise exception 'MANIFESTHELD FAIL: the hunt send froze no manifest';
  end if;

  -- ── 2. ARRIVE, FIGHT, FINISH. The sortie must END so the fleet is commandable again. ─────────────
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();

  select id into v_enc from public.combat_encounters where fleet_id = v_fleet and status = 'active';
  if v_enc is null then
    raise exception 'MANIFESTHELD FAIL: the hunt arrival opened no encounter';
  end if;
  -- A hunt combat spawns ENDLESS waves — clearing one spawns the next — so it cannot be waited out.
  -- The only exit is the canonical retreat, and the way a player arms it is by giving the fleet a new
  -- course: step 8 classifies that against the live encounter and returns 'retreat_started'. So the
  -- first course change here is the RETREAT, not the ambushed leg.
  r := pg_temp.call_as(uZ, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gR, round(coalesce((select space_x from public.fleets where id = v_fleet), 0)) + 10,
                                  round(coalesce((select space_y from public.fleets where id = v_fleet), 0))));
  if (r->>'ok')::boolean is not true then
    raise exception 'MANIFESTHELD FAIL: could not arm the retreat out of the hunt: %', r;
  end if;
  if (r->>'reason') not in ('retreat_started', 'retreat_destination_updated', 'movement_started') then
    raise exception 'MANIFESTHELD FAIL: unexpected outcome arming the retreat: %', r;
  end if;

  if pg_temp.drain_encounter(v_enc, v_fleet) in ('active', 'retreating') then
    raise exception 'MANIFESTHELD FAIL: the hunt encounter is still % after draining — the sortie never ended',
      (select status from public.combat_encounters where id = v_enc);
  end if;

  perform public.set_game_config('enemy_hp_base',     to_jsonb(v_hp_before));
  perform public.set_game_config('enemy_attack_base', to_jsonb(v_atk_before));

  select * into fl from public.fleets where id = v_fleet;
  if fl.status = 'destroyed' then
    raise exception 'MANIFESTHELD FAIL: the fleet died in its own hunt despite a 1-hp, 0-damage wave';
  end if;

  -- ── 3. THE MANIFEST IS RETAINED. This is the trap, asserted rather than assumed. ─────────────────
  select count(*) into n_before from public.group_sortie_members where fleet_id = v_fleet;
  if n_before = 0 then
    raise exception 'MANIFESTHELD FAIL: the finished sortie released its manifest — 0047 retention no longer holds, so the regression cannot reproduce and this block would pass vacuously';
  end if;

  -- ── 4. A ZONE ON THE NEXT LEG, drawn with the real verb (0304 gives it its effect row). ──────────
  select coalesce(f.space_x, 0), coalesce(f.space_y, 0) into f_x, f_y
    from public.fleets f where f.id = v_fleet;
  t_x := f_x + 400; t_y := f_y;
  v_verts := jsonb_build_array(
    jsonb_build_array(f_x + 100, f_y - 150),
    jsonb_build_array(f_x + 300, f_y - 150),
    jsonb_build_array(f_x + 300, f_y + 150),
    jsonb_build_array(f_x + 100, f_y + 150));
  -- Attached to a REAL location: the resolver opens the fight AT the zone's linked location, and a
  -- zone with a null location makes it bail early with note='location_missing' and no encounter.
  r := pg_temp.call_as(uZ, format('public.pirate_zone_create(%L, %L::jsonb, %L::uuid)',
                                  'DZC Retained Manifest Zone', v_verts::text, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'MANIFESTHELD FAIL: zone: %', r; end if;

  -- ── 5. THE COURSE CHANGE. This is the owner's action, and the leg that gets ambushed. ────────────
  r := pg_temp.call_as(uZ, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gR, round(t_x), round(t_y)));
  if (r->>'ok')::boolean is not true then
    raise exception 'MANIFESTHELD FAIL: the fleet could not be re-ordered after its sortie: %', r;
  end if;
  v_mv := (r->>'movement_id')::uuid;
  if v_mv is null then raise exception 'MANIFESTHELD FAIL: the course change started no movement: %', r; end if;

  select * into pi from public.pirate_intercepts where movement_id = v_mv order by created_at desc limit 1;
  if pi is null or pi.lifecycle_state <> 'pending' then
    raise exception 'MANIFESTHELD FAIL: the new leg scheduled no pending ambush (risk knobs are 1.0, and 0304 gives the new zone its effect row)';
  end if;

  -- ── 6. FIRE IT, through the REAL movement processor. ─────────────────────────────────────────────
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();

  select * into pi from public.pirate_intercepts where movement_id = v_mv order by created_at desc limit 1;
  if pi.lifecycle_state <> 'fired' then
    raise exception 'MANIFESTHELD FAIL: the ambush is % (want fired)', pi.lifecycle_state;
  end if;

  -- ── VACUITY GUARD: the freeze must have inserted NOTHING (the ON CONFLICT path). ─────────────────
  select count(*) into n_after from public.group_sortie_members where fleet_id = v_fleet;
  if n_after <> n_before then
    raise exception 'MANIFESTHELD FAIL: manifest went % -> % across the ambush — the ON CONFLICT path was not exercised, so this block does not reproduce the regression',
      n_before, n_after;
  end if;

  -- ── THE ASSERTIONS THE LIVE BUG FAILED ───────────────────────────────────────────────────────────
  if pi.note is not distinct from 'empty_manifest' then
    raise exception 'MANIFESTHELD FAIL: the ambush was logged empty_manifest while % manifest rows exist — the guard is counting the INSERT, not the MANIFEST (the 0303 regression)', n_after;
  end if;
  -- Any note at all means the resolver took one of its fail-open exits (location_missing and the
  -- like) instead of opening combat. Naming it beats inferring it from a null encounter_id.
  if pi.note is not null then
    raise exception 'MANIFESTHELD FAIL: the ambush bailed out with note=% instead of opening combat', pi.note;
  end if;
  if pi.encounter_id is null then
    raise exception 'MANIFESTHELD FAIL: the ambush fired but opened NO encounter — the player was parked without a fight';
  end if;

  select count(*) into n from public.combat_encounters
   where fleet_id = v_fleet and status = 'active' and id <> v_enc;
  if n <> 1 then
    raise exception 'MANIFESTHELD FAIL: % new active encounter(s) after the ambush (want exactly 1). Encounters: %. Intercept opened %. Fleet: %.',
      n,
      (select string_agg(format('%s=%s', ce.id, ce.status), ', ' order by ce.created_at)
         from public.combat_encounters ce where ce.fleet_id = v_fleet),
      pi.encounter_id,
      (select format('status=%s mode=%s loc=%s', f.status, f.location_mode, f.current_location_id)
         from public.fleets f where f.id = v_fleet);
  end if;
  select id into v_enc2 from public.combat_encounters
   where fleet_id = v_fleet and status = 'active' and id <> v_enc;
  if pi.encounter_id is distinct from v_enc2 then
    raise exception 'MANIFESTHELD FAIL: the intercept does not record the encounter it opened';
  end if;

  raise notice 'DZCOMBAT_PASS_MANIFESTHELD ok: a fleet still holding % retained manifest rows from a finished hunt was ambushed on a later course change, the freeze inserted 0 rows (the ON CONFLICT path), it was NOT logged empty_manifest, and it opened encounter % — production''s exact sequence, and the live defect (parked with no fight, then deadlocked on group_on_sortie) is proven fixed BY OUTCOME',
    n_after, v_enc2;
end $$;


-- ════════ DZCOMBAT_PASS_ROSTERAUTH (0308): THE COMBAT ROSTER IS LIVE MEMBERSHIP ══════════════════════
-- Production's destruction sequence, staged for real and inverted into assertions: a fleet fights,
-- the fight CONCLUDES, the player unassigns one ship (legal — the sortie is closed), and the fleet
-- is ambushed again. Pre-0308 the idempotent freeze inserted nothing, the unfiltered roster kept the
-- departed ship, and the builder seeded it into combat_units — a ship berthed at a port, dragged
-- into someone else's fight and destroyed on defeat. Post-0308 the re-ambush freeze REPLACES the
-- fleet's snapshot (the one release idiom) and the builder seeds live membership only.
--
-- A SECOND fixture player: uZ's three team slots are all spent (group_index <= 3), and an isolated
-- world makes the "untouched bystander ship" assertion airtight. Provisioning is 100% real-RPC.
-- STAGING LEGS FLY UNDER risk 0 (the proof owns its preconditions): the trip back to port must not
-- roll an ambush of its own; the knobs return to 1.0 for the leg under test.
do $$
declare
  r jsonb; n int;
  uZ uuid := (select v from dzc where k='uZ');
  v_hunt uuid := (select v from dzc where k='v_hunt');
  uL uuid; s_l uuid; s_d uuid; gL uuid; v_port uuid;
  v_fleet uuid; v_mv uuid; v_enc uuid; v_enc2 uuid;
  f_x double precision; f_y double precision; t_x double precision; t_y double precision;
  v_verts jsonb;
  v_hp_before double precision; v_atk_before double precision;
  d_status text; d_hp integer;
  pi record; mv record;
begin
  -- ── a second fixture player, funded like the first ───────────────────────────────────────────────
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzl.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uL;
  insert into dzc values ('uL', uL);
  insert into public.player_wallet (player_id, balance) values (uL, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;

  -- ── two ships, one team, command designated — the real RPCs only ─────────────────────────────────
  r := pg_temp.call_as(uL, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: first ship: %', r; end if;
  select main_ship_id into s_l from public.main_ship_instances where player_id = uL;
  select berth_location_id into v_port from public.main_ship_instances where main_ship_id = s_l;
  if v_port is null then raise exception 'ROSTERAUTH FAIL: the commissioned ship has no berth port'; end if;
  -- arm the survivor with a REAL autocannon (real writers): its unit in the final, never-ticked
  -- encounter below is what FITTEDEXACT pins field-for-field against the catalog.
  perform public.reward_grant('combat', gen_random_uuid(), uL, null,
    '{"items": [{"item_id": "weapon_parts", "quantity": 8}, {"item_id": "pirate_alloy", "quantity": 4}, {"item_id": "scrap", "quantity": 12}]}'::jsonb);
  -- 0333: crafted AT s_l's dock — Haven Reach, where it was just commissioned, and where the
  -- NULL-base grant above landed (uL's oldest active base is its Home Base at Haven). The craft
  -- happens BEFORE uL's second ship is commissioned, but the ship is named anyway: the port is the
  -- point, and the sole-ship shim would stop resolving the moment a second hull exists.
  r := pg_temp.call_as(uL, format('public.craft_module(''ral-gun-1'', ''autocannon_battery'', %L::uuid)', s_l));
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: craft gun: %', r; end if;
  r := pg_temp.call_as(uL, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''ral-fit-1'')', (r->>'instance_id')::uuid, s_l));
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: fit gun: %', r; end if;
  r := pg_temp.call_as(uL, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: second ship: %', r; end if;
  select main_ship_id into s_d from public.main_ship_instances
   where player_id = uL and main_ship_id <> s_l limit 1;
  if s_d is null then raise exception 'ROSTERAUTH FAIL: no second ship materialised'; end if;
  insert into dzc values ('uL_s_l', s_l), ('uL_s_d', s_d);

  r := pg_temp.call_as(uL, 'public.upsert_ship_group(1, ''Roster L'')');
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: group: %', r; end if;
  gL := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uL, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_l, gL));
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: assign s_l: %', r; end if;
  r := pg_temp.call_as(uL, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_d, gL));
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: assign s_d: %', r; end if;
  r := pg_temp.call_as(uL, format('public.set_fleet_command_ship(%L::uuid, true)', s_l));
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: designate command: %', r; end if;

  -- ── 1. A FIGHT, CONCLUDED. Harmless wave (knobs set BEFORE it spawns; restored after). ───────────
  select coalesce(public.cfg_num('enemy_hp_base'), 0)     into v_hp_before;
  select coalesce(public.cfg_num('enemy_attack_base'), 0) into v_atk_before;
  perform public.set_game_config('enemy_hp_base',     '1'::jsonb);
  perform public.set_game_config('enemy_attack_base', '0'::jsonb);

  r := pg_temp.call_as(uL, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gL, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: hunt send: %', r; end if;
  v_fleet := (r->>'fleet_id')::uuid; v_mv := (r->>'movement_id')::uuid;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id into v_enc from public.combat_encounters where fleet_id = v_fleet and status = 'active';
  if v_enc is null then raise exception 'ROSTERAUTH FAIL: the hunt arrival opened no encounter'; end if;
  -- the retreat is armed the way a player arms it: a new course against the live encounter.
  r := pg_temp.call_as(uL, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gL, round(coalesce((select space_x from public.fleets where id = v_fleet), 0)) + 10,
                                  round(coalesce((select space_y from public.fleets where id = v_fleet), 0))));
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: could not arm the retreat: %', r; end if;
  if pg_temp.drain_encounter(v_enc, v_fleet) in ('active', 'retreating') then
    raise exception 'ROSTERAUTH FAIL: the fight never concluded'; end if;
  perform public.set_game_config('enemy_hp_base',     to_jsonb(v_hp_before));
  perform public.set_game_config('enemy_attack_base', to_jsonb(v_atk_before));
  select count(*) into n from public.fleets where id = v_fleet and status = 'destroyed';
  if n <> 0 then raise exception 'ROSTERAUTH FAIL: the fleet died in a 1-hp, 0-damage fight'; end if;

  -- vacuity: the concluded sortie RETAINED its 2-row roster — the trap state exists.
  select count(*) into n from public.group_sortie_members where fleet_id = v_fleet;
  if n <> 2 then raise exception 'ROSTERAUTH FAIL: % roster rows after the concluded fight (want 2 retained — the trap)', n; end if;

  -- ── 2. HOME TO PORT under risk 0 (a staging leg must not roll its own ambush), then UNASSIGN. ────
  perform public.set_game_config('pirate_intercept_base_risk',      '0'::jsonb);
  perform public.set_game_config('pirate_intercept_min_risk',       '0'::jsonb);
  perform public.set_game_config('pirate_intercept_max_risk',       '0'::jsonb);
  perform public.set_game_config('pirate_intercept_exposure_floor', '0'::jsonb);
  r := pg_temp.call_as(uL, format('public.command_ship_group_go(%L::uuid, %L::uuid, null, null)', gL, v_port));
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: go to port: %', r; end if;
  -- vacuity: the production defect lives on a PERSISTENT group fleet — the go must reuse it, or the
  -- stale rows would sit on a different fleet and this block would prove nothing.
  if (r->>'fleet_id')::uuid is distinct from v_fleet then
    raise exception 'ROSTERAUTH FAIL: the go minted a different fleet (% vs %) — the persistent-fleet trap shape did not build', r->>'fleet_id', v_fleet; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select count(*) into n from public.fleets
   where id = (select f.id from public.fleets f where f.group_id = gL and f.player_id = uL
                 and f.status = 'present' and f.location_mode = 'location' and f.current_location_id = v_port limit 1);
  if n <> 1 then raise exception 'ROSTERAUTH FAIL: the fleet did not settle present at its port'; end if;

  -- THE PLAYER'S LEGAL ACT: the sortie is closed, so the unassign must succeed (0305).
  r := pg_temp.call_as(uL, format('public.assign_ship_to_group(%L::uuid, null)', s_d));
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: post-sortie unassign refused: %', r; end if;
  select count(*) into n from public.main_ship_instances
   where main_ship_id = s_d and group_id is null and berth_location_id = v_port;
  if n <> 1 then raise exception 'ROSTERAUTH FAIL: the unassigned ship is not berthed at the port, out of the group'; end if;
  -- vacuity: the STALE row for the departed ship is STILL on the roster — the trap is armed.
  select count(*) into n from public.group_sortie_members where fleet_id = v_fleet and main_ship_id = s_d;
  if n <> 1 then raise exception 'ROSTERAUTH FAIL: the departed ship''s stale roster row is already gone — the regression cannot reproduce and this block would pass vacuously'; end if;
  select status, hp into d_status, d_hp from public.main_ship_instances where main_ship_id = s_d;

  -- ── 3. THE RE-AMBUSH: risk back to 1.0, a fresh zone on a fresh leg, fired by the real processor. ─
  perform public.set_game_config('pirate_intercept_base_risk',      '1.0'::jsonb);
  perform public.set_game_config('pirate_intercept_min_risk',       '1.0'::jsonb);
  perform public.set_game_config('pirate_intercept_max_risk',       '1.0'::jsonb);
  perform public.set_game_config('pirate_intercept_exposure_floor', '1.0'::jsonb);
  select l.x, l.y into f_x, f_y from public.locations l where l.id = v_port;
  t_x := f_x; t_y := f_y + 700;
  v_verts := jsonb_build_array(
    jsonb_build_array(f_x - 150, f_y + 200),
    jsonb_build_array(f_x + 150, f_y + 200),
    jsonb_build_array(f_x + 150, f_y + 500),
    jsonb_build_array(f_x - 150, f_y + 500));
  r := pg_temp.call_as(uZ, format('public.pirate_zone_create(%L, %L::jsonb, %L::uuid)',
                                  'DZC Roster Authority Zone', v_verts::text, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: zone: %', r; end if;
  -- handed to the 0311 REPOSITION blocks below: the zone, the fleet, its group and the port anchor
  -- the zone geometry was built from (the ambush this block stages parks the fleet on this zone's
  -- bottom edge, which is exactly the boundary-anchored fixture reposition must work from).
  insert into dzc values ('ra_zone', (r->>'zone_id')::uuid), ('ra_group', gL);
  insert into dzn values ('ra_px', f_x), ('ra_py', f_y);

  r := pg_temp.call_as(uL, format('public.command_ship_group_go(%L::uuid, null, %s, %s)', gL, round(t_x), round(t_y)));
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: the re-order: %', r; end if;
  if (r->>'fleet_id')::uuid is distinct from v_fleet then
    raise exception 'ROSTERAUTH FAIL: the re-order minted a different fleet (% vs %) — the stale roster would not even be in play', r->>'fleet_id', v_fleet; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into pi from public.pirate_intercepts where movement_id = v_mv order by created_at desc limit 1;
  if pi is null or pi.lifecycle_state <> 'pending' then
    raise exception 'ROSTERAUTH FAIL: the leg under test scheduled no pending ambush'; end if;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select * into pi from public.pirate_intercepts where movement_id = v_mv order by created_at desc limit 1;
  if pi.lifecycle_state <> 'fired' then
    raise exception 'ROSTERAUTH FAIL: the ambush is % (want fired)', pi.lifecycle_state; end if;
  if pi.note is not null then
    raise exception 'ROSTERAUTH FAIL: the ambush bailed out with note=% instead of opening combat — one live member must be a fight', pi.note; end if;
  if pi.encounter_id is null then
    raise exception 'ROSTERAUTH FAIL: the ambush fired but opened NO encounter'; end if;
  v_enc2 := pi.encounter_id;

  -- ── THE ASSERTIONS THE LIVE DEFECT WOULD FAIL ────────────────────────────────────────────────────
  -- (i) the fight is fielded by LIVE MEMBERSHIP: exactly one player unit, and it is the member.
  select count(*) into n from public.combat_units where encounter_id = v_enc2 and side = 'player';
  if n <> 1 then raise exception 'ROSTERAUTH FAIL: % player unit(s) seeded (want exactly 1 — live membership only)', n; end if;
  select count(*) into n from public.combat_units
   where encounter_id = v_enc2 and side = 'player' and main_ship_id = s_l;
  if n <> 1 then raise exception 'ROSTERAUTH FAIL: the remaining member was NOT seeded — the roster rule is too aggressive'; end if;
  -- (ii) the DEPARTED ship was not dragged in — this line IS the production defect, inverted.
  select count(*) into n from public.combat_units where encounter_id = v_enc2 and main_ship_id = s_d;
  if n <> 0 then raise exception 'ROSTERAUTH FAIL: the ship that LEFT the fleet was seeded into its next fight (the 0308 defect)'; end if;
  -- (iii) the bystander is untouched: same berth, same status, same hp, still ungrouped.
  select count(*) into n from public.main_ship_instances
   where main_ship_id = s_d and group_id is null and berth_location_id = v_port
     and status = d_status and hp = d_hp;
  if n <> 1 then raise exception 'ROSTERAUTH FAIL: the departed ship''s row changed across a fight it was never in'; end if;
  -- (iv) the freeze REPLACED the snapshot: the stale row is released, the live member is frozen.
  select count(*) into n from public.group_sortie_members where fleet_id = v_fleet;
  if n <> 1 then raise exception 'ROSTERAUTH FAIL: % roster rows after the re-ambush (want exactly 1 — the snapshot was replaced)', n; end if;
  select count(*) into n from public.group_sortie_members where fleet_id = v_fleet and main_ship_id = s_l;
  if n <> 1 then raise exception 'ROSTERAUTH FAIL: the fresh snapshot does not carry the live member'; end if;
  -- hand the NEVER-TICKED armed encounter to FITTEDEXACT (the tick legitimately rewrites
  -- next_ready_at after a shot, so the frozen-at-creation shape can only be pinned pre-tick) and
  -- the fleet to the 0311 REPOSITION blocks (which run after FITTEDEXACT — they write positions,
  -- never weapons_json, so the pin still sees creation state).
  insert into dzc values ('ra_enc2', v_enc2), ('ra_fleet', v_fleet);

  raise notice 'DZCOMBAT_PASS_ROSTERAUTH ok: a fleet whose fight had concluded lost a ship to a legal unassign, was ambushed again, and the fight fielded ONLY the live member (1 unit = %); the departed ship kept its berth/status/hp and was never seeded; the re-ambush freeze replaced the 2-row stale snapshot with the 1-row live one', s_l;
end $$;

-- ════════ DZCOMBAT_PASS_RIGFALLBACK (0308): A MINING RIG IS NOT A GUN ════════════════════════════════
-- The catalog seeds mining_rig_extension with range 120 / power 8 (0229), and the creator's old
-- weapon test was `range is not null` — so a fitted rig fired power 8 AND suppressed the 0262
-- fallback. Post-0308 a rig-only ship's fitted-WEAPON join is empty and the fallback fires,
-- deriving power from the ship's own attack. Expected values are DERIVED from the knobs and the
-- unit's own snapshot at assert time — nothing ambient is hard-coded.
do $$
declare
  r jsonb; n int;
  uL uuid := (select v from dzc where k='uL');
  v_hunt uuid := (select v from dzc where k='v_hunt');
  s_m uuid; gM uuid; v_modinst uuid; v_fleet uuid; v_mv uuid; v_enc uuid;
  mv record; w jsonb;
  v_attack double precision; v_wc int;
  v_fb_id text; v_frange double precision;
begin
  -- ── a third ship for the second player, rigged (not armed), its own team ─────────────────────────
  r := pg_temp.call_as(uL, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'RIGFALLBACK FAIL: commission: %', r; end if;
  select main_ship_id into s_m from public.main_ship_instances
   where player_id = uL
     and main_ship_id not in ((select v from dzc where k='uL_s_l'), (select v from dzc where k='uL_s_d'))
   limit 1;
  if s_m is null then raise exception 'RIGFALLBACK FAIL: no third ship materialised'; end if;

  -- fund + craft + fit ONE mining rig via the real writers (recipe: crystal/ore/scrap, 0183).
  perform public.reward_grant('combat', gen_random_uuid(), uL, null,
    '{"items": [{"item_id": "crystal", "quantity": 4}, {"item_id": "ore", "quantity": 8}, {"item_id": "scrap", "quantity": 8}]}'::jsonb);
  -- 0333: uL owns THREE ships here (s_l, s_d and this new s_m), so the sole-ship shim cannot
  -- resolve one — the craft NAMES s_m, which is freshly commissioned and therefore docked at Haven
  -- Reach, the same store the NULL-base grant above deposited into.
  r := pg_temp.call_as(uL, format('public.craft_module(''dzc-rig-1'', ''mining_rig_extension'', %L::uuid)', s_m));
  if (r->>'ok')::boolean is not true then raise exception 'RIGFALLBACK FAIL: craft rig: %', r; end if;
  v_modinst := (r->>'instance_id')::uuid;
  r := pg_temp.call_as(uL, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''dzc-fit-rig'')', v_modinst, s_m));
  if (r->>'ok')::boolean is not true then raise exception 'RIGFALLBACK FAIL: fit rig: %', r; end if;

  -- vacuity guards: the rig really is the trap-carrier (a range-bearing NON-weapon), and it is the
  -- ship's ONLY range-bearing fitted module — the exact pre-0308 poisoned input.
  select count(*) into n from public.module_types t
   where t.id = 'mining_rig_extension' and t.slot_type = 'mining' and t.range is not null;
  if n <> 1 then raise exception 'RIGFALLBACK FAIL: mining_rig_extension is no longer a range-bearing mining module — the trap input does not exist and this block would pass vacuously'; end if;
  select count(*) into n
    from public.ship_module_fittings f
    join public.module_instances i on i.id = f.module_instance_id
    join public.module_types t     on t.id = i.module_type_id
   where f.main_ship_id = s_m and t.range is not null;
  if n <> 1 then raise exception 'RIGFALLBACK FAIL: % range-bearing fitted module(s) on the rig ship (want exactly the rig)', n; end if;

  r := pg_temp.call_as(uL, 'public.upsert_ship_group(2, ''Roster M'')');
  if (r->>'ok')::boolean is not true then raise exception 'RIGFALLBACK FAIL: group: %', r; end if;
  gM := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uL, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_m, gM));
  if (r->>'ok')::boolean is not true then raise exception 'RIGFALLBACK FAIL: assign: %', r; end if;
  r := pg_temp.call_as(uL, format('public.set_fleet_command_ship(%L::uuid, true)', s_m));
  if (r->>'ok')::boolean is not true then raise exception 'RIGFALLBACK FAIL: designate command: %', r; end if;

  -- ── a real sortie opens a real encounter (no ticks are run; creation state is the assertion). ────
  r := pg_temp.call_as(uL, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gM, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'RIGFALLBACK FAIL: hunt send: %', r; end if;
  v_fleet := (r->>'fleet_id')::uuid; v_mv := (r->>'movement_id')::uuid;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id into v_enc from public.combat_encounters where fleet_id = v_fleet and status = 'active';
  if v_enc is null then raise exception 'RIGFALLBACK FAIL: the hunt arrival opened no encounter'; end if;

  -- ── THE ASSERTIONS: the rig never fires; the ship fires ITS OWN attack through the fallback. ─────
  select attack_snapshot, jsonb_array_length(weapons_json) into v_attack, v_wc
    from public.combat_units where encounter_id = v_enc and main_ship_id = s_m;
  if v_attack is null or v_attack <= 0 then
    raise exception 'RIGFALLBACK FAIL: attack_snapshot is % — the fallback trigger (attack > 0) would be vacuous', v_attack; end if;
  if v_wc <> 1 then
    raise exception 'RIGFALLBACK FAIL: weapons_json has % entries (want exactly 1 — the synthesized fallback)', v_wc; end if;
  select weapons_json->0 into w from public.combat_units where encounter_id = v_enc and main_ship_id = s_m;
  select count(*) into n from public.combat_units cu, jsonb_array_elements(cu.weapons_json) e
   where cu.encounter_id = v_enc and cu.main_ship_id = s_m and e->>'module_type_id' = 'mining_rig_extension';
  if n <> 0 then
    raise exception 'RIGFALLBACK FAIL: the mining rig is in weapons_json — a rig still counts as a gun (the 0308 defect)'; end if;
  v_fb_id  := coalesce((select value #>> '{}' from public.game_config where key = 'combat_player_fallback_weapon_module_type_id'), 'basic_player_weapon');
  v_frange := coalesce(public.cfg_num('combat_player_fallback_weapon_range'), 150);
  if (w->>'module_type_id') is distinct from v_fb_id then
    raise exception 'RIGFALLBACK FAIL: the one weapon is % (want the fallback %) — the 0262 fallback did not fire', w->>'module_type_id', v_fb_id; end if;
  -- 0317 REPOINT (the knob is GONE, not the property). The head multiplied the ship's attack by
  -- combat_player_fallback_weapon_power_from_attack — a second, separately-settable rule that only
  -- the UNFITTED path obeyed. 0317 deleted it and made the synthesized weapon carry a share WEIGHT
  -- of 1 through the same normalisation the fitted path runs, so the one entry resolves to exactly
  -- the ship's combat_power. The assertion is therefore STRONGER now, not weaker: an exact identity
  -- with no free multiplier in it. Non-vacuity is the v_attack > 0 pin above.
  if (w->>'power')::double precision is distinct from v_attack then
    raise exception 'RIGFALLBACK FAIL: fallback power % <> attack_snapshot % — the ship does not fire its own attack (0317: the unfitted path must resolve to combat_power EXACTLY, through the same rule as the fitted one)', w->>'power', v_attack; end if;
  if exists (select 1 from public.game_config where key = 'combat_player_fallback_weapon_power_from_attack') then
    raise exception 'RIGFALLBACK FAIL: combat_player_fallback_weapon_power_from_attack is back — a second multiplier on one of the two paths is the drift 0317 removed'; end if;
  if (w->>'range')::double precision is distinct from v_frange then
    raise exception 'RIGFALLBACK FAIL: fallback range % <> the knob-derived %', w->>'range', v_frange; end if;

  -- handed to the 0311 REPOSITION-MODE block below: a LIVE, never-drained hunt fight whose fleet is
  -- 'present' AT its site — exactly the not-in-open-space shape the typed refusal exists for.
  insert into dzc values ('rf_enc', v_enc), ('rf_fleet', v_fleet), ('rf_group', gM);

  raise notice 'DZCOMBAT_PASS_RIGFALLBACK ok: a rig-only ship (the exact pre-0308 poisoned input: one range-bearing non-weapon fitted) was seeded with exactly ONE weapon — the % fallback at power % (its own combat_power, EXACTLY, through the same 0317 rule the fitted path runs), range % — and the rig entry is gone: a mining rig is not a gun',
    v_fb_id, v_attack, v_frange;
end $$;

-- ════════ DZCOMBAT_PASS_FITTEDEXACT (0308): A REAL WEAPON RIDES THROUGH EXACTLY, AND ALONE ═══════════
-- The control arm: the ROSTERAUTH survivor fitted a real autocannon_battery at provision time, and
-- the block's FINAL encounter has NEVER TICKED — deliberately: the tick legitimately rewrites
-- next_ready_at after a weapon fires (team A's PIRATEFIRE encounter proved that the hard way), so
-- the frozen-at-creation shape can only be pinned on a pre-tick encounter. Its weapons_json must be
-- exactly its CATALOG entry — every field equal to the deployed module_types row, no fallback entry
-- beside it. Field values are DERIVED from the catalog at assert time, never hard-coded.
do $$
declare
  n int;
  s_cmd uuid := (select v from dzc where k='uL_s_l');
  v_enc uuid := (select v from dzc where k='ra_enc2');
  w jsonb; t record; v_wc int;
  v_fb_id text;
  v_fe_attack double precision;
begin
  if v_enc is null then raise exception 'FITTEDEXACT FAIL: the ROSTERAUTH encounter was not handed over'; end if;

  select jsonb_array_length(weapons_json), weapons_json->0 into v_wc, w
    from public.combat_units where encounter_id = v_enc and main_ship_id = s_cmd;
  if v_wc is null then raise exception 'FITTEDEXACT FAIL: no combat unit for the armed command ship'; end if;
  if v_wc <> 1 then
    raise exception 'FITTEDEXACT FAIL: the armed ship carries % weapon entries (want exactly its one fitted gun)', v_wc; end if;

  select * into t from public.module_types where id = 'autocannon_battery';
  if t.id is null then raise exception 'FITTEDEXACT FAIL: autocannon_battery is not in the catalog'; end if;
  -- 0317 REPOINT — power LEFT THE DELIVERY FIELDS. Every field a weapon DECIDES (its reach, its
  -- muzzle velocity, its cadence, its ammo) is still pinned byte-for-byte to the catalog row: that
  -- is what this block has always been for and it is unchanged. `power` is no longer one of them.
  -- module_types.power is a SHARE WEIGHT from 0317 on, and the entry's power is the ship's folded
  -- combat_power times its share — for a single-gun ship, exactly the ship's combat_power. It is
  -- checked below, against attack_snapshot, together with the pin that the two numbers actually
  -- DIFFER (otherwise this repoint would be satisfiable by the old flat copy and prove nothing).
  if (w->>'module_type_id') is distinct from t.id
     or (w->>'range')::numeric            is distinct from t.range
     or (w->>'projectile_speed')::numeric is distinct from t.projectile_speed
     or (w->>'cooldown_seconds')::numeric is distinct from t.cooldown_seconds
     or (w->>'ammo_type')                 is distinct from t.ammo_type
     or (w->>'ammo_per_shot')::integer    is distinct from t.ammo_per_shot then
    raise exception 'FITTEDEXACT FAIL: the fitted weapon entry drifted from its catalog row: % vs (%, %, %, %, %, %)',
      w, t.id, t.range, t.projectile_speed, t.cooldown_seconds, t.ammo_type, t.ammo_per_shot; end if;
  select attack_snapshot into v_fe_attack from public.combat_units
   where encounter_id = v_enc and main_ship_id = s_cmd;
  if v_fe_attack is null or v_fe_attack <= 0 then
    raise exception 'FITTEDEXACT FAIL: attack_snapshot is % — every power assertion below would be vacuous', v_fe_attack; end if;
  if v_fe_attack = t.power then
    raise exception 'FITTEDEXACT FAIL: this ship''s combat_power (%) HAPPENS to equal the catalog share weight (%) — the fitted-power assertion below could then be satisfied by the pre-0317 flat copy and would prove nothing. Re-engineer the fixture (fit a second gun, or change the hull) rather than weakening the assert.', v_fe_attack, t.power; end if;
  if (w->>'power')::double precision is distinct from v_fe_attack then
    raise exception 'FITTEDEXACT FAIL: the fitted weapon fires % but the ship''s folded combat_power is % — the catalog is still deciding damage (the pre-0317 defect: attack_snapshot is used for damage ZERO times on the spatial arm, so hull/captain/trait/buff contributed nothing)', w->>'power', v_fe_attack; end if;
  if w->>'next_ready_at' is not null or w->>'ammo_remaining' is not null then
    raise exception 'FITTEDEXACT FAIL: the fitted entry lost its frozen next_ready_at/ammo_remaining NULLs'; end if;
  -- and NO fallback entry beside it: a real gun must keep suppressing the synthesized weapon.
  v_fb_id := coalesce((select value #>> '{}' from public.game_config where key = 'combat_player_fallback_weapon_module_type_id'), 'basic_player_weapon');
  select count(*) into n from public.combat_units cu, jsonb_array_elements(cu.weapons_json) e
   where cu.encounter_id = v_enc and cu.main_ship_id = s_cmd and e->>'module_type_id' = v_fb_id;
  if n <> 0 then
    raise exception 'FITTEDEXACT FAIL: a fallback entry sits beside the real gun — the empty-array guard broke'; end if;

  raise notice 'DZCOMBAT_PASS_FITTEDEXACT ok: the armed command ship''s weapons_json carries exactly its catalog autocannon_battery DELIVERY profile (range / projectile speed / cooldown / ammo, field-for-field, alone, frozen NULL clocks), no fallback beside it, and it fires its ship''s OWN folded combat_power (% — not the catalog share weight %)', v_fe_attack, t.power;
end $$;

-- ════════ DZCOMBAT_PASS_REPOSITION (0337): AN IN-ZONE ORDER IS A MOVE, NOT A TELEPORT ═══════════════
-- The owner's law, verbatim: "there should only be breaking combat when it is outside the zone.
-- When i am inside the zone and moving(redirecting), it should just move without breaking combat,
-- and battles being continued." 0311 built that — and built it as an INSTANT jump, saying so in its
-- own header ("The reposition is INSTANT") on the strength of a measurement 0316 then invalidated by
-- cutting every weapon range by five. The owner watched the result: "when in combat, and i move, i
-- teleport."
--
-- SO THIS BLOCK NOW PROVES THE JOURNEY, AND AN ENDPOINT-ONLY ASSERT CANNOT SATISFY IT:
--   1. the ORDER moves NOTHING — fleet, formation and anchor are byte-identical after it. On the
--      0311 body this fails on the FIRST position check, which is the teleport inverted.
--   2. the destination is RECORDED on the ENCOUNTER (per fleet, one pair, both-or-neither).
--   3. tick 1 moves the fleet EXACTLY the fleet's own speed and the order still stands.
--   4. tick 2 moves it EXACTLY that again — MORE THAN ONE TICK, which is the whole property.
--   5. tick 3 ARRIVES on the ordered point and the order is consumed.
--   Every step is bounded by combat_fleet_move_speed, so a body that covered the distance in one
--   step fails at (3) even though its endpoint is right.
--   6. the formation is RIGID: the player unit's offset from the anchor is IDENTICAL at every one of
--      the five observations — the fleet moves as ONE body ("show only fleet. it is as a whole").
--   7. the enemy RESPONDS: pirate rows move under their own mover while the fleet walks, so walking
--      away can never make a fleet unreachable by standing still.
--
-- THE PROOF OWNS ITS PRECONDITIONS: the destination is derived from the fleet's MEASURED speed
-- (2.5 x speed, so the arithmetic of "3 ticks" is a fact of this fixture rather than of a knob), and
-- the group's 0310 auto-exit is turned OFF through the real RPC so a damage roll mid-journey cannot
-- silently end the fight and turn an arrival assert into a flake.
--
-- Fixture: ROSTERAUTH's end state, reused. Encounter ra_enc2 is ACTIVE and never ticked; its fleet
-- is parked idle/space at the ambush entry point ON the 'DZC Roster Authority Zone' boundary — the
-- exact boundary-anchored engagement every real ambush produces (the reason the admission's anchor
-- arm is a closure test).
do $$
declare
  r jsonb; n int; i int;
  uL uuid := (select v from dzc where k='uL');
  gL uuid := (select v from dzc where k='ra_group');
  v_fleet uuid := (select v from dzc where k='ra_fleet');
  v_enc uuid := (select v from dzc where k='ra_enc2');
  z_small uuid := (select v from dzc where k='ra_zone');
  px double precision := (select v from dzn where k='ra_px');
  py double precision := (select v from dzn where k='ra_py');
  e0x double precision; e0y double precision;
  dx double precision; dy double precision;
  v_speed double precision;
  v_offset int; v_dist double precision; v_ticks int;
  v_step double precision; v_travelled double precision;
  prev_x double precision; prev_y double precision;
  off_x double precision; off_y double precision;
  fl record; e record; pr record;
  n_mv0 int; n_units0 int; n_enemy_moved int;
begin
  if v_enc is null or v_fleet is null or z_small is null or px is null then
    raise exception 'REPOSITION FAIL: the ROSTERAUTH fixture was not handed over'; end if;

  -- ── vacuity + fixture-isolation guards (the proof owns its preconditions). ──────────────────────
  select * into e from public.combat_encounters where id = v_enc;
  if e.status <> 'active' then raise exception 'REPOSITION FAIL precondition: the encounter is % (want active)', e.status; end if;
  if e.engagement_x is null or e.engagement_y is null then
    raise exception 'REPOSITION FAIL precondition: the encounter has no engagement point'; end if;
  if e.reposition_x is not null or e.reposition_y is not null then
    raise exception 'REPOSITION FAIL precondition: a reposition destination is already recorded (%,%)', e.reposition_x, e.reposition_y; end if;
  e0x := e.engagement_x; e0y := e.engagement_y;
  select * into fl from public.fleets where id = v_fleet;
  if fl.status <> 'idle' or fl.location_mode <> 'space' then
    raise exception 'REPOSITION FAIL precondition: the fleet is %/% (want idle/space — the ambush park)', fl.status, fl.location_mode; end if;
  if abs(fl.space_x - e0x) > 1e-6 or abs(fl.space_y - e0y) > 1e-6 then
    raise exception 'REPOSITION FAIL precondition: fleet (%,%) is not parked on the engagement point (%,%)', fl.space_x, fl.space_y, e0x, e0y; end if;
  if fl.retreat_target_location_id is not null or fl.retreat_target_x is not null or fl.retreat_target_y is not null then
    raise exception 'REPOSITION FAIL precondition: a retreat destination is already stored'; end if;
  -- exactly the ONE known zone holds the anchor here (overlap semantics get their own block below).
  select count(*) into n from public.danger_zones z
   where z.status = 'active' and z.id <> z_small
     and ST_DWithin(z.boundary, ST_MakePoint(e0x, e0y), 1e-6);
  if n <> 0 then
    raise exception 'REPOSITION FAIL fixture: % unrelated active zone(s) also hold the engagement point (%) — move the fixture geometry. NAMED, not just counted (0317): the count alone told an author nothing about WHICH block had drawn into this fixture''s geometry, and a proof block inserted upstream of here reproduced exactly that.', n,
      (select string_agg(z.id::text || ' ' || coalesce(z.name, '<unnamed>'), '; ')
         from public.danger_zones z
        where z.status = 'active' and z.id <> z_small
          and ST_DWithin(z.boundary, ST_MakePoint(e0x, e0y), 1e-6)); end if;

  -- ── snapshot EVERY combat unit in the world: only ra_enc2's player rows may be translated. ──────
  create temp table dz_repo_u1 on commit drop as
    select cu.id, cu.encounter_id, cu.side, cu.pos_x, cu.pos_y from public.combat_units cu;
  select count(*) into n_units0 from dz_repo_u1 where encounter_id = v_enc and side = 'player';
  if n_units0 < 1 then raise exception 'REPOSITION FAIL precondition: no player units in the fixture encounter'; end if;
  select count(*) into n_mv0 from public.fleet_movements where fleet_id = v_fleet;

  -- ── THE FLEET'S OWN SPEED, MEASURED through the deployed authority — never a quoted knob. ───────
  v_speed := public.combat_fleet_move_speed(v_enc);
  if v_speed is null or v_speed <= 0 then
    raise exception 'REPOSITION FAIL precondition: the fleet''s combat speed is % — it could not move under ANY order and every journey assert below would be vacuous', v_speed; end if;
  -- ── 0339: THE MOVE IS PERCEPTIBLE, AND IT IS THE RIGHT LEVER THAT MAKES IT SO. ─────────────────
  -- The owner's report was that combat movement is invisible: ~0.16-0.26 world units per 3s tick,
  -- about 1/16 px at playable zoom and 4-10x slower than the pirates chasing the fleet. docs/DEV_LOG
  -- named combat_player_speed_scale as the fix; it is the WRONG knob — 0316's invariant f7 caps it
  -- at ~0.38 (under 2x) and it also speeds every per-unit CLOSE and KITE decision, which is how a
  -- player kites a pirate out of the fight. combat_reposition_speed_scale moves ONLY this leaf.
  -- Both asserts are RED on the deployed body, where the leaf returns the bare min and the knob does
  -- not exist. The identity is measured against the LIVE rows, never against a quoted number.
  declare
    v_slowest double precision;
    v_scale   double precision := coalesce(public.cfg_num('combat_reposition_speed_scale'), 1);
  begin
    select min(cu.move_speed) into v_slowest from public.combat_units cu
     where cu.encounter_id = v_enc and cu.side = 'player' and cu.alive_count > 0;
    if v_slowest is null or v_slowest <= 0 then
      raise exception 'REPOSITION FAIL precondition: the fixture has no living player hull with a speed — the scaling identity below would be vacuous'; end if;
    if abs(v_speed - v_slowest * v_scale) > 1e-9 then
      raise exception 'REPOSITION FAIL: the fleet move leaf answers % but its slowest living hull is % at a reposition scale of % (want the product) — the ordered-move speed is not coming from the ONE leaf the knob scales', v_speed, v_slowest, v_scale; end if;
    if ceil(20.0 / v_speed) * coalesce(public.cfg_num('combat_tick_seconds'), 3) > 60 then
      raise exception 'REPOSITION FAIL: at % per tick this fleet needs % seconds to cross 20 world units — the owner reported that this takes MINUTES, and tens of seconds is the bar this slice set',
        v_speed, ceil(20.0 / v_speed) * coalesce(public.cfg_num('combat_tick_seconds'), 3); end if;
  end;
  -- 0310's auto-exit OFF through the real RPC: a damage roll must not end the fight mid-journey and
  -- turn "did it arrive?" into a coin toss. Owned precondition, set here, never assumed.
  r := pg_temp.call_as(uL, format('public.set_group_auto_exit(%L::uuid, false, 30)', gL));
  if (r->>'ok')::boolean is not true then raise exception 'REPOSITION FAIL precondition: could not disable auto-exit: %', r; end if;

  -- ── THE OWNER'S ACTION: redirect INSIDE the zone, a few steps deeper than the edge the fleet was
  -- ── ambushed on. THE DESTINATION MUST BE AN INTEGER POINT: step 3 of command_ship_group_go
  -- ── canonicalizes every ordered coordinate onto the integer world grid before anything reads it,
  -- ── so a fractional target is NOT the point the admission is tested against. The first cut of this
  -- ── block asked for e0y + 2.5*speed, which at this fixture's speed canonicalized straight back ONTO
  -- ── the boundary the fleet was ambushed on — and the admission demands STRICTLY inside, so the
  -- ── order came back 'retreat_started' and the journey was untestable. Integer offset, integer
  -- ── anchor, nothing left for the server to round.
  v_offset := greatest(2, ceil(2.5 * v_speed))::int;
  dx := round(e0x); dy := round(e0y) + v_offset;
  if not public.danger_zone_contains_point(z_small, dx, dy) then
    raise exception 'REPOSITION FAIL fixture: the destination (%,%) is not inside the fight''s zone — % unit(s) in from the ambush edge (%,%) leaves it; move the fixture geometry', dx, dy, v_offset, e0x, e0y; end if;
  -- THE JOURNEY LENGTH, SOLVED FROM THE FIXTURE'S OWN NUMBERS rather than assumed. The tick covers a
  -- full step every pass and lands on the last one, so the count is ceil(distance / speed) exactly.
  v_dist  := public.osn_distance(e0x, e0y, dx, dy);
  v_ticks := ceil(v_dist / v_speed)::int;
  if v_ticks < 3 then
    raise exception 'REPOSITION FAIL fixture: the journey is % tick(s) (% units at speed %) — fewer than three cannot distinguish a MOVE from a teleport, which is the entire property this block exists to prove', v_ticks, v_dist, v_speed; end if;
  r := pg_temp.call_as(uL, format('public.command_ship_group_go(%L::uuid, null, %s, %s)', gL, dx, dy));
  if (r->>'ok')::boolean is not true then raise exception 'REPOSITION FAIL: the in-zone order was refused: %', r; end if;
  if (r->>'order_outcome') is distinct from 'repositioning' then
    raise exception 'REPOSITION FAIL: order_outcome is % — the in-zone order armed a retreat instead of ordering a move (the pre-0311 behaviour), or still claims the arrival 0337 deleted', r->>'order_outcome'; end if;
  if (r->>'encounter_id')::uuid is distinct from v_enc then
    raise exception 'REPOSITION FAIL: the envelope names encounter % (want the live fight %)', r->>'encounter_id', v_enc; end if;
  if r ? 'movement_id' then
    raise exception 'REPOSITION FAIL: the envelope carries a movement_id — a reposition must never mint a leg: %', r; end if;

  -- ── 1. THE ORDER MOVED NOTHING. This is the teleport, inverted: on the 0311 body the fleet, the
  -- ── formation and the anchor are all AT the destination by now, and every one of these fails.
  select * into fl from public.fleets where id = v_fleet;
  if abs(fl.space_x - e0x) > 1e-6 or abs(fl.space_y - e0y) > 1e-6 then
    raise exception 'REPOSITION FAIL: the ORDER moved the fleet to (%,%) — a reposition orders a move; it does not perform one. THIS IS THE TELEPORT.', fl.space_x, fl.space_y; end if;
  select * into e from public.combat_encounters where id = v_enc;
  if abs(e.engagement_x - e0x) > 1e-6 or abs(e.engagement_y - e0y) > 1e-6 then
    raise exception 'REPOSITION FAIL: the ORDER restamped the anchor to (%,%) — the anchor is the tick''s to move, one step at a time', e.engagement_x, e.engagement_y; end if;
  select count(*) into n
    from dz_repo_u1 b join public.combat_units cu on cu.id = b.id
   where cu.pos_x is distinct from b.pos_x or cu.pos_y is distinct from b.pos_y;
  if n <> 0 then
    raise exception 'REPOSITION FAIL: the ORDER moved % combat unit(s) — the whole-delta translate 0337 deleted is still in the order verb', n; end if;

  -- ── 2. THE DESTINATION IS RECORDED ON THE FIGHT, per FLEET, as one both-or-neither pair. ────────
  if e.reposition_x is null or e.reposition_y is null then
    raise exception 'REPOSITION FAIL: no destination was recorded (%,%) — the order neither moved the fleet nor gave it a course', e.reposition_x, e.reposition_y; end if;
  if abs(e.reposition_x - dx) > 1e-6 or abs(e.reposition_y - dy) > 1e-6 then
    raise exception 'REPOSITION FAIL: the recorded destination is (%,%), not the ordered (%,%)', e.reposition_x, e.reposition_y, dx, dy; end if;
  if fl.retreat_target_location_id is not null or fl.retreat_target_x is not null or fl.retreat_target_y is not null then
    raise exception 'REPOSITION FAIL: a reposition wrote a retreat destination (%, %, %) — a move is never a retreat',
      fl.retreat_target_location_id, fl.retreat_target_x, fl.retreat_target_y; end if;
  select * into pr from public.location_presence where id = e.presence_id;
  if pr.status <> 'active' or pr.retreat_requested_at is not null then
    raise exception 'REPOSITION FAIL: the presence is %/retreat_requested % — the reposition armed a retreat', pr.status, pr.retreat_requested_at; end if;

  -- ── 3-6. THE JOURNEY. v_ticks passes: full steps, then an arrival — each one MEASURED. ──────────
  -- The rigid-body offset is captured from the pre-order world and re-checked after every step, so a
  -- formation that slid relative to its own anchor fails here even if the anchor's path is perfect.
  select cu.pos_x - e0x, cu.pos_y - e0y into off_x, off_y
    from public.combat_units cu where cu.encounter_id = v_enc and cu.side = 'player'
   order by cu.id limit 1;
  if off_x is null then raise exception 'REPOSITION FAIL: the fixture''s player unit has no position — every rigidity assert would be vacuous'; end if;
  -- ENEMY MOTION IS MEASURED TICK-TO-TICK, not against the pre-order world. This encounter is
  -- NEVER-TICKED when the order is given, so its first wave does not exist yet — a snapshot taken
  -- before the order holds ZERO enemy rows, and "did an enemy move?" asked against it is answered by
  -- the fixture rather than by the engine. (That is exactly how the first cut of this block failed:
  -- red on a correct system.) So the comparison walks forward, one tick at a time, from the first
  -- world in which enemies exist at all.
  create temp table dz_repo_e (id uuid primary key, pos_x double precision, pos_y double precision) on commit drop;
  n_enemy_moved := 0;
  prev_x := e0x; prev_y := e0y;
  for i in 1 .. v_ticks loop
    perform pg_temp.ae_tick(v_enc);
    select * into e from public.combat_encounters where id = v_enc;
    if e.status <> 'active' then
      raise exception 'REPOSITION FAIL: the encounter went % on step % — the journey must not end the fight (auto-exit is off; this is damage or a wave)', e.status, i; end if;
    v_step := public.osn_distance(prev_x, prev_y, e.engagement_x, e.engagement_y);
    -- THE PER-TICK BOUND. An endpoint-only assert passes a teleport; this one does not.
    if v_step > v_speed + 1e-9 then
      raise exception 'REPOSITION FAIL: step % covered % world units against a fleet speed of % — the fleet is moving faster than its own slowest hull, i.e. it is still jumping', i, v_step, v_speed; end if;
    if i < v_ticks then
      -- a FULL step, and the order still standing: this is what makes the journey longer than one tick
      if abs(v_step - v_speed) > 1e-9 then
        raise exception 'REPOSITION FAIL: step % of % covered % world units, want a full step of % — the fleet is dawdling or the mover is not being asked for a full step', i, v_ticks, v_step, v_speed; end if;
      if e.reposition_x is null then
        raise exception 'REPOSITION FAIL: the order was consumed on step % of % — it arrived early, which at this distance means it jumped', i, v_ticks; end if;
    end if;
    -- the fleet marker tracks the fight the whole way (not only at the end)
    select * into fl from public.fleets where id = v_fleet;
    if abs(fl.space_x - e.engagement_x) > 1e-6 or abs(fl.space_y - e.engagement_y) > 1e-6 then
      raise exception 'REPOSITION FAIL: after step % the fleet marker is (%,%) but the fight is at (%,%) — the map would show the ship somewhere it is not', i, fl.space_x, fl.space_y, e.engagement_x, e.engagement_y; end if;
    if fl.status <> 'idle' or fl.location_mode <> 'space' or fl.active_movement_id is not null
       or fl.current_location_id is not null then
      raise exception 'REPOSITION FAIL: after step % the fleet is %/% (movement %, location %) — a reposition mints no leg and docks nowhere', i, fl.status, fl.location_mode, fl.active_movement_id, fl.current_location_id; end if;
    -- RIGID BODY: the same offset from the anchor, every step, for every player row
    select count(*) into n from public.combat_units cu
     where cu.encounter_id = v_enc and cu.side = 'player'
       and (abs((cu.pos_x - e.engagement_x) - off_x) > 1e-6 or abs((cu.pos_y - e.engagement_y) - off_y) > 1e-6);
    if n <> 0 then
      raise exception 'REPOSITION FAIL: after step % , % player unit(s) sit at a different offset from the anchor — the fleet is dissolving into individual ships instead of moving as one body', i, n; end if;
    -- how many enemy rows moved between the previous tick and this one, accumulated across the run
    select count(*) into n
      from dz_repo_e b join public.combat_units cu on cu.id = b.id
     where cu.pos_x is distinct from b.pos_x or cu.pos_y is distinct from b.pos_y;
    n_enemy_moved := n_enemy_moved + n;
    delete from dz_repo_e;
    insert into dz_repo_e (id, pos_x, pos_y)
      select cu.id, cu.pos_x, cu.pos_y from public.combat_units cu
       where cu.encounter_id = v_enc and cu.side = 'enemy' and cu.alive_count > 0;
    prev_x := e.engagement_x; prev_y := e.engagement_y;
  end loop;

  -- ── 5. ARRIVED, EXACTLY, AND THE ORDER IS CONSUMED. ────────────────────────────────────────────
  if abs(e.engagement_x - dx) > 1e-6 or abs(e.engagement_y - dy) > 1e-6 then
    raise exception 'REPOSITION FAIL: after % step(s) the fight is at (%,%), not the ordered (%,%) — % units at speed % must land on tick %', v_ticks, e.engagement_x, e.engagement_y, dx, dy, v_dist, v_speed, v_ticks; end if;
  if e.reposition_x is not null or e.reposition_y is not null then
    raise exception 'REPOSITION FAIL: the fleet arrived and the order (%,%) still stands — arrival must consume it, or the tick keeps re-translating a fleet that is already there', e.reposition_x, e.reposition_y; end if;
  v_travelled := public.osn_distance(e0x, e0y, e.engagement_x, e.engagement_y);
  if abs(v_travelled - v_dist) > 1e-6 then
    raise exception 'REPOSITION FAIL: the fleet covered % world units, want the whole ordered distance %', v_travelled, v_dist; end if;
  if e.status <> 'active' then
    raise exception 'REPOSITION FAIL: the encounter is % — the in-zone order broke the combat', e.status; end if;
  select * into fl from public.fleets where id = v_fleet;
  if fl.retreat_target_location_id is not null or fl.retreat_target_x is not null or fl.retreat_target_y is not null then
    raise exception 'REPOSITION FAIL: a completed reposition wrote a retreat destination'; end if;
  select count(*) into n from public.combat_units where encounter_id = v_enc and side = 'player';
  if n <> n_units0 then
    raise exception 'REPOSITION FAIL: player unit count moved % -> % across the journey', n_units0, n; end if;

  -- ── 7. THE ENEMY RESPONDED. Pirate rows are never translated by the reposition — they move under
  -- ── their OWN mover, which is what stops a walking fleet from becoming unreachable.
  -- n_enemy_moved was accumulated tick-to-tick inside the loop. Zero enemy rows and zero enemy
  -- MOTION are different failures and get different diagnoses: the first says the fixture never
  -- fielded an opponent, the second says the engine let a fleet walk out of a fight unchallenged.
  select count(*) into n from public.combat_units where encounter_id = v_enc and side = 'enemy';
  if n = 0 then
    raise exception 'REPOSITION FAIL: the fight fielded NO enemy rows across % tick(s) — there was nothing that could have responded, so this property would pass vacuously', v_ticks; end if;
  if n_enemy_moved = 0 then
    raise exception 'REPOSITION FAIL: none of the % enemy row(s) moved on any tick of the journey — a fleet that walks away would be unreachable by standing still', n; end if;
  -- and no OTHER fight in the world was touched (dz_repo_u1 is the pre-order world; every row of it
  -- that belongs to another encounter must still be exactly where it was)
  select count(*) into n
    from dz_repo_u1 b join public.combat_units cu on cu.id = b.id
   where b.encounter_id <> v_enc
     and (cu.pos_x is distinct from b.pos_x or cu.pos_y is distinct from b.pos_y);
  if n <> 0 then
    raise exception 'REPOSITION FAIL: % unit(s) in OTHER encounters moved — the translate is scoped to this fight''s player side', n; end if;

  -- ── no journey leg, no fresh ambush roll: zero new legs, zero pending intercepts for this fleet. ─
  select count(*) into n from public.fleet_movements where fleet_id = v_fleet;
  if n <> n_mv0 then raise exception 'REPOSITION FAIL: a reposition minted a leg (% -> % movements)', n_mv0, n; end if;
  select count(*) into n from public.pirate_intercepts pi
   join public.fleet_movements m on m.id = pi.movement_id
   where m.fleet_id = v_fleet and pi.lifecycle_state = 'pending';
  if n <> 0 then raise exception 'REPOSITION FAIL: % pending ambush(es) exist after a reposition — the move was rolled like a journey', n; end if;

  raise notice 'DZCOMBAT_PASS_REPOSITION ok: the in-zone order MOVED NOTHING and recorded a course to (%,%); the tick then walked the fleet % world units there over % ticks at exactly % per tick (its own slowest hull), the formation held one rigid offset at every step, % enemy row(s) moved to follow, arrival consumed the order, and the fight never broke — no retreat write, no leg, no new roll',
    dx, dy, v_dist, v_ticks, v_speed, n_enemy_moved;
end $$;

-- ════════ DZCOMBAT_PASS_REPOOVERLAP (0311): QUANTIFY OVER OVERLAPPING ZONES — NEVER CHOOSE ONE ═══════
-- THE TIE-BREAK DEFECT, INVERTED (adversarial review of the first cut, upheld and fixed here). The
-- 131e027 body resolved "the" zone of the fight — the smallest-area zone whose closure holds the
-- engagement anchor — and tested the destination against ONLY that zone. With overlapping zones
-- that is wrong in both directions: a thin lower-area zone that holds the anchor VETOES a
-- destination genuinely inside the fight's own zone (order 1 below), and the same area ordering
-- decides instead of geometry when the containing zone is the bigger one (order 2). The fixed
-- admission asks only "does SOME active zone hold the anchor AND strictly contain the
-- destination" — so BOTH orders below reposition. BOTH fail on the 131e027 body, whose tie-break
-- picks the sliver (order 1) / the mid zone (order 2), misses the destination, and retreats.
--
-- Geometry, all relative to the ROSTERAUTH port anchor (px, py) and the previous block's
-- A1 IS READ FROM THE FIGHT, never recomputed (0337). The previous block used to leave the anchor at
-- a hard-coded (px, py+350) because a reposition TELEPORTED there; now it walks 2.5 of its own steps
-- and stops a couple of world units inside the zone edge, so the only honest source for "where is
-- this fight" is the encounter row. The two zones below are therefore drawn AROUND A1 rather than
-- around a remembered constant — same three areas, same three properties, no ambient value asserted:
--   S      = ra_zone     [px-150, px+150] x [py+200, py+500]      area  90,000 (holds A1)
--   SLIVER = drawn here  [A1x-5,   A1x+5] x [A1y-100, A1y+100]    area   2,000 (holds A1)
--   BIG    = drawn here  [A1x-350, A1x+350] x [A1y-150, A1y+550]  area 490,000 (holds A1)
--          BIG's y-window is offset UPWARD from the anchor on purpose: same 700-unit span (so the
--          area, and this block's largest-holder property, are unchanged) but clear of the
--          commission port every fixture in this file departs from. Enforced, not remembered — see
--          the port guard in the body.
--   order 1: D1 = A1 + (100, 0) — inside S and BIG, NOT inside SLIVER (the lowest-area holder).
--   order 2: D2 = A1 + (250, 0) — inside BIG only; S does not contain it. Area order must not
--            decide: geometry does.
-- AND THE ASSERTION MOVED WITH THE BEHAVIOUR (0337): an admitted order now RECORDS a course instead
-- of performing a jump, so what is checked is the admission's verdict and the recorded destination —
-- which is exactly the property this block has always been about. The journey itself is proven
-- above; repeating it here would only make this block slower, not stronger. Order 2 additionally
-- pins LAST-WRITE-WINS: one destination pair, overwritten in place, never a second course.
do $$
declare
  r jsonb; n int;
  uZ uuid := (select v from dzc where k='uZ');
  uL uuid := (select v from dzc where k='uL');
  gL uuid := (select v from dzc where k='ra_group');
  v_fleet uuid := (select v from dzc where k='ra_fleet');
  v_enc uuid := (select v from dzc where k='ra_enc2');
  z_s uuid := (select v from dzc where k='ra_zone');
  v_hunt uuid := (select v from dzc where k='v_hunt');
  px double precision := (select v from dzn where k='ra_px');
  py double precision := (select v from dzn where k='ra_py');
  a1x double precision := (select engagement_x from public.combat_encounters where id = v_enc);
  a1y double precision := (select engagement_y from public.combat_encounters where id = v_enc);
  d1x double precision; d1y double precision;
  d2x double precision; d2y double precision;
  z_sliver uuid; z_big uuid; v_verts jsonb;
  fl record; e record;
  n_mv0 int;
begin
  -- ── the two overlapping zones, drawn with the real verb (0304 gives each its effect row), around
  -- ── the anchor READ FROM THE FIGHT rather than around a remembered constant (0337).
  if a1x is null or a1y is null then
    raise exception 'REPOOVERLAP FAIL precondition: the fight has no anchor to draw around'; end if;
  v_verts := jsonb_build_array(
    jsonb_build_array(a1x - 5, a1y - 100),
    jsonb_build_array(a1x + 5, a1y - 100),
    jsonb_build_array(a1x + 5, a1y + 100),
    jsonb_build_array(a1x - 5, a1y + 100));
  r := pg_temp.call_as(uZ, format('public.pirate_zone_create(%L, %L::jsonb, %L::uuid)',
                                  'DZC Overlap Sliver Zone', v_verts::text, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'REPOOVERLAP FAIL: sliver zone: %', r; end if;
  z_sliver := (r->>'zone_id')::uuid;
  -- BIG's y-extent is deliberately OFFSET UPWARD from the anchor (-150 .. +550, not -300 .. +400).
  -- Both spans are 700 units, so the area — and therefore this block's "largest holder" property —
  -- is identical; what the offset buys is CLEARANCE OVER THE COMMISSION PORT. See the port guard
  -- immediately below for why that is load-bearing and how it is enforced rather than remembered.
  v_verts := jsonb_build_array(
    jsonb_build_array(a1x - 350, a1y - 150),
    jsonb_build_array(a1x + 350, a1y - 150),
    jsonb_build_array(a1x + 350, a1y + 550),
    jsonb_build_array(a1x - 350, a1y + 550));
  r := pg_temp.call_as(uZ, format('public.pirate_zone_create(%L, %L::jsonb, %L::uuid)',
                                  'DZC Overlap Big Zone', v_verts::text, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'REPOOVERLAP FAIL: big zone: %', r; end if;
  z_big := (r->>'zone_id')::uuid;

  -- ── ⛔ THE PORT GUARD: NO ZONE THIS BLOCK DRAWS MAY COVER THE COMMISSION PORT. ─────────────────
  -- EVERY fixture in this file launches from the SAME berth: port_entry_commission_build docks every
  -- commissioned starter at the one Haven location, so (px,py) here is also the departure point of
  -- blocks that run hundreds of lines later — NOLIVE among them.
  -- This proof pins pirate_intercept_base/min/max/exposure_floor to 1.0, so a leg touching an ACTIVE
  -- zone is ambushed with CERTAINTY. And a leg that BEGINS inside a zone has entry fraction 0, so
  -- trigger_at = depart + duration*0 = depart = now() — and now() is constant inside this one
  -- transaction, so that ambush is due the instant it is planned. A later block's
  -- command_ship_group_stop then answers 'intercepted_in_transit', which is CORRECT behaviour (the
  -- EVASION block above asserts exactly that rule) arriving in a block that never asked for a fight.
  -- THAT IS NOT A HYPOTHETICAL: it is how this block broke NOLIVE. When 0337 made the anchor stop
  -- teleporting, these zones were re-centred on the anchor, and BIG's y-extent — written then as
  -- a1y-300 — reached 150 units BELOW Haven, because the anchor sits ~200 units above the port. Two
  -- disposable runs failed identically, ~2,000 lines away, in a block about dead fleets.
  -- So the invariant is ENFORCED HERE, at the drawing site, in the block that owns the geometry —
  -- not remembered in a comment and not paid for by the victim. A future author who re-shapes these
  -- zones gets a named failure with the coordinates, instead of a mystery two thousand lines later.
  if px is null or py is null then
    raise exception 'REPOOVERLAP FAIL fixture: the commission port coordinates were not handed over — the port guard below cannot run and a zone drawn over the port would break a later block instead of this one'; end if;
  if public.danger_zone_contains_point(z_sliver, px, py)
     or public.danger_zone_contains_point(z_big, px, py) then
    raise exception 'REPOOVERLAP FAIL fixture: a zone drawn here covers the COMMISSION PORT (%,%) — sliver:% big:%. Every fixture in this file launches from that berth, and this proof pins intercept risk to 1.0, so a leg departing INSIDE an active zone is ambushed at entry fraction 0 (due immediately) and a later block''s stop is refused intercepted_in_transit. Move the zone, do not relax the victim.',
      px, py,
      public.danger_zone_contains_point(z_sliver, px, py),
      public.danger_zone_contains_point(z_big, px, py); end if;

  -- ── vacuity + isolation guards: the anchor is where the last block left it, the three zones hold
  -- ── it, the SLIVER is the lowest-area holder, and nothing else holds it. All derived, not assumed.
  select * into e from public.combat_encounters where id = v_enc;
  if e.status <> 'active' then raise exception 'REPOOVERLAP FAIL precondition: the encounter is % (want active)', e.status; end if;
  if abs(e.engagement_x - a1x) > 1e-6 or abs(e.engagement_y - a1y) > 1e-6 then
    raise exception 'REPOOVERLAP FAIL precondition: the anchor moved to (%,%) between the declare block and here (%,%)', e.engagement_x, e.engagement_y, a1x, a1y; end if;
  if e.reposition_x is not null or e.reposition_y is not null then
    raise exception 'REPOOVERLAP FAIL precondition: a course is still standing (%,%) — the previous block''s journey did not finish', e.reposition_x, e.reposition_y; end if;
  select count(*) into n from public.danger_zones z
   where z.status = 'active' and z.id in (z_s, z_sliver, z_big)
     and ST_DWithin(z.boundary, ST_MakePoint(a1x, a1y), 1e-6);
  if n <> 3 then raise exception 'REPOOVERLAP FAIL fixture: only % of the 3 zones hold the anchor', n; end if;
  select count(*) into n from public.danger_zones z
   where z.status = 'active' and z.id not in (z_s, z_sliver, z_big)
     and ST_DWithin(z.boundary, ST_MakePoint(a1x, a1y), 1e-6);
  if n <> 0 then raise exception 'REPOOVERLAP FAIL fixture: % unrelated zone(s) hold the anchor', n; end if;
  if (select ST_Area(boundary) from public.danger_zones where id = z_sliver)
     >= least((select ST_Area(boundary) from public.danger_zones where id = z_s),
              (select ST_Area(boundary) from public.danger_zones where id = z_big)) then
    raise exception 'REPOOVERLAP FAIL fixture: the sliver is not the lowest-area holder — the veto shape did not build'; end if;
  select count(*) into n_mv0 from public.fleet_movements where fleet_id = v_fleet;

  -- ── ORDER 1: destination inside S (and BIG) but NOT inside the lowest-area holder. ──────────────
  d1x := a1x + 100; d1y := a1y;
  if not public.danger_zone_contains_point(z_s, d1x, d1y)
     or public.danger_zone_contains_point(z_sliver, d1x, d1y) then
    raise exception 'REPOOVERLAP FAIL fixture: D1 is not (inside S, outside the sliver) — move it'; end if;
  r := pg_temp.call_as(uL, format('public.command_ship_group_go(%L::uuid, null, %s, %s)', gL, d1x, d1y));
  if (r->>'ok')::boolean is not true or (r->>'order_outcome') is distinct from 'repositioning' then
    raise exception 'REPOOVERLAP FAIL: order 1 answered % — a lower-area overlapping zone VETOED an in-zone move (the 131e027 tie-break defect)', r; end if;
  select * into e from public.combat_encounters where id = v_enc;
  select * into fl from public.fleets where id = v_fleet;
  if e.status <> 'active' or e.reposition_x is null
     or abs(e.reposition_x - d1x) > 1e-6 or abs(e.reposition_y - d1y) > 1e-6 then
    raise exception 'REPOOVERLAP FAIL: order 1 did not give the fight a course to D1 (encounter %, recorded %,%)', e.status, e.reposition_x, e.reposition_y; end if;
  if abs(fl.space_x - a1x) > 1e-6 or abs(fl.space_y - a1y) > 1e-6 then
    raise exception 'REPOOVERLAP FAIL: order 1 MOVED the fleet to (%,%) — an admitted order records a course, it does not perform a jump (0337)', fl.space_x, fl.space_y; end if;

  -- ── ORDER 2: destination inside the BIGGEST holder only — area order must not decide. ───────────
  d2x := a1x + 250; d2y := a1y;
  if public.danger_zone_contains_point(z_s, d2x, d2y)
     or not public.danger_zone_contains_point(z_big, d2x, d2y) then
    raise exception 'REPOOVERLAP FAIL fixture: D2 is not (outside S, inside BIG) — move it'; end if;
  r := pg_temp.call_as(uL, format('public.command_ship_group_go(%L::uuid, null, %s, %s)', gL, d2x, d2y));
  if (r->>'ok')::boolean is not true or (r->>'order_outcome') is distinct from 'repositioning' then
    raise exception 'REPOOVERLAP FAIL: order 2 answered % — the destination lies inside an anchor-holding zone and the area order still decided the outcome (the 131e027 tie-break defect)', r; end if;
  select * into e from public.combat_encounters where id = v_enc;
  select * into fl from public.fleets where id = v_fleet;
  -- LAST WRITE WINS, ONE PAIR (0337): D1's course is REPLACED by D2's, never joined by it. Two
  -- standing destinations would be two answers to "where is this fleet headed".
  if e.status <> 'active' or e.reposition_x is null
     or abs(e.reposition_x - d2x) > 1e-6 or abs(e.reposition_y - d2y) > 1e-6 then
    raise exception 'REPOOVERLAP FAIL: order 2 did not replace the course with D2 (encounter %, recorded %,%)', e.status, e.reposition_x, e.reposition_y; end if;
  if abs(fl.space_x - a1x) > 1e-6 or abs(fl.space_y - a1y) > 1e-6
     or abs(e.engagement_x - a1x) > 1e-6 or abs(e.engagement_y - a1y) > 1e-6 then
    raise exception 'REPOOVERLAP FAIL: two orders moved the fight to (%,%)/(%,%) without a single tick — ordering is not moving (0337)', fl.space_x, fl.space_y, e.engagement_x, e.engagement_y; end if;
  if fl.retreat_target_location_id is not null or fl.retreat_target_x is not null or fl.retreat_target_y is not null then
    raise exception 'REPOOVERLAP FAIL: an overlap reposition wrote a retreat destination'; end if;
  select count(*) into n from public.fleet_movements where fleet_id = v_fleet;
  if n <> n_mv0 then raise exception 'REPOOVERLAP FAIL: an overlap reposition minted a leg'; end if;

  raise notice 'DZCOMBAT_PASS_REPOOVERLAP ok: with three overlapping anchor-holding zones (areas 2000 / 90000 / 490000), an in-zone order was ADMITTED past the lower-area sliver to (%,%) and past the mid zone to (%,%), the second replacing the first on ONE destination pair — geometry admits, area never decides, neither order moved the fleet, no retreat write, no leg',
    d1x, d1y, d2x, d2y;
end $$;

-- ════════ DZCOMBAT_PASS_REPOOUTSIDE (0311): THE QUANTIFIER'S NEGATIVE SIDE, AND NO MID-RETREAT JUMP ══
-- Two properties on the same fleet and fight:
--   1. THE MIRROR of the overlap block: a destination inside a zone that does NOT hold the anchor —
--      with no anchor-holding zone containing it — is NOT an in-zone move. It retreats exactly as
--      the pre-0311 world did: destination stored, the ONE retreat authority armed, nothing moved,
--      no restamp, no leg. (Analysis note, stated rather than implied: the 131e027 tie-break body
--      also retreats here — any zone IT could pick holds the anchor by construction, so a grant
--      through a non-holding zone was impossible on either body. The discriminating cases live in
--      REPOOVERLAP; this block pins the negative side of the quantifier so a future widening —
--      "any zone containing the destination grants a jump" — fails loudly.)
--   2. Once the fight is 'retreating', an order back to an ADMITTED point must NOT jump: it only
--      replaces the stored destination, and neither retreat clock restarts.
do $$
declare
  r jsonb; n int;
  uZ uuid := (select v from dzc where k='uZ');
  uL uuid := (select v from dzc where k='uL');
  gL uuid := (select v from dzc where k='ra_group');
  v_fleet uuid := (select v from dzc where k='ra_fleet');
  v_enc uuid := (select v from dzc where k='ra_enc2');
  v_hunt uuid := (select v from dzc where k='v_hunt');
  px double precision := (select v from dzn where k='ra_px');
  py double precision := (select v from dzn where k='ra_py');
  -- 0337: READ FROM THE FIGHT. The overlap block used to leave the anchor at D2 because an admitted
  -- order teleported the fleet there; it now only records a course, so the anchor is still where the
  -- previous journey ended and the only honest source is the encounter row.
  a3x double precision := (select engagement_x from public.combat_encounters where id = v_enc);
  a3y double precision := (select engagement_y from public.combat_encounters where id = v_enc);
  obx double precision; oby double precision;
  irx double precision; iry double precision;
  z_far uuid; v_verts jsonb;
  fl record; e record; pr record;
  t_req timestamptz; t_start timestamptz;
  n_mv0 int;
begin
  -- ── a zone that contains the outside destination but does NOT hold the anchor. ──────────────────
  if a3x is null or a3y is null then
    raise exception 'REPOOUTSIDE FAIL precondition: the fight has no anchor to place the far zone against'; end if;
  v_verts := jsonb_build_array(
    jsonb_build_array(a3x + 1000, a3y - 50),
    jsonb_build_array(a3x + 1200, a3y - 50),
    jsonb_build_array(a3x + 1200, a3y + 50),
    jsonb_build_array(a3x + 1000, a3y + 50));
  r := pg_temp.call_as(uZ, format('public.pirate_zone_create(%L, %L::jsonb, %L::uuid)',
                                  'DZC Far Non-Holder Zone', v_verts::text, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'REPOOUTSIDE FAIL: far zone: %', r; end if;
  z_far := (r->>'zone_id')::uuid;
  -- THE PORT GUARD, same law as REPOOVERLAP's: this block draws an ACTIVE zone while intercept risk
  -- is pinned to 1.0, and every later fixture launches from the commission port. A zone over that
  -- berth makes a later leg start inside it, due at entry fraction 0, and refuses that block's stop
  -- with intercepted_in_transit. Uniform, cheap, and it names the offender at the drawing site.
  if public.danger_zone_contains_point(z_far, px, py) then
    raise exception 'REPOOUTSIDE FAIL fixture: the far zone covers the COMMISSION PORT (%,%) — every fixture in this file departs from that berth; move the zone, do not relax the block it breaks', px, py; end if;

  -- ── vacuity guards, all derived through the deployed authorities the mover itself consults. ─────
  select * into e from public.combat_encounters where id = v_enc;
  if e.status <> 'active' then raise exception 'REPOOUTSIDE FAIL precondition: the encounter is % (want active)', e.status; end if;
  if abs(e.engagement_x - a3x) > 1e-6 or abs(e.engagement_y - a3y) > 1e-6 then
    raise exception 'REPOOUTSIDE FAIL precondition: the anchor is (%,%), not the overlap block''s end state (%,%)', e.engagement_x, e.engagement_y, a3x, a3y; end if;
  obx := a3x + 1100; oby := a3y;
  if exists (select 1 from public.danger_zones z
              where z.id = z_far and ST_DWithin(z.boundary, ST_MakePoint(a3x, a3y), 1e-6)) then
    raise exception 'REPOOUTSIDE FAIL fixture: the far zone holds the anchor — the mirror shape did not build'; end if;
  if not public.danger_zone_contains_point(z_far, obx, oby) then
    raise exception 'REPOOUTSIDE FAIL fixture: the mirror destination is not inside the far zone — move it'; end if;
  if public.combat_encounter_zone_admits_point(v_enc, obx, oby) then
    raise exception 'REPOOUTSIDE FAIL fixture: the mirror destination IS admitted — some anchor-holding zone contains it; move the geometry'; end if;
  select count(*) into n_mv0 from public.fleet_movements where fleet_id = v_fleet;
  create temp table dz_repo_u2 on commit drop as
    select cu.id, cu.pos_x, cu.pos_y from public.combat_units cu where cu.encounter_id = v_enc;

  -- ── 1. THE MIRROR ORDER -> the retreat, exactly as before. ──────────────────────────────────────
  r := pg_temp.call_as(uL, format('public.command_ship_group_go(%L::uuid, null, %s, %s)', gL, obx, oby));
  if (r->>'ok')::boolean is not true or (r->>'order_outcome') is distinct from 'retreat_started' then
    raise exception 'REPOOUTSIDE FAIL: the mirror order answered % — a zone that does not hold the fight granted a jump', r; end if;
  select * into fl from public.fleets where id = v_fleet;
  if fl.retreat_target_x is distinct from obx or fl.retreat_target_y is distinct from oby
     or fl.retreat_target_location_id is not null then
    raise exception 'REPOOUTSIDE FAIL: the retreat destination was not stored (%, %, %)',
      fl.retreat_target_location_id, fl.retreat_target_x, fl.retreat_target_y; end if;
  if abs(fl.space_x - a3x) > 1e-6 or abs(fl.space_y - a3y) > 1e-6 then
    raise exception 'REPOOUTSIDE FAIL: the fleet MOVED on a retreat order (%,%) — the retreat leaves only when the window expires', fl.space_x, fl.space_y; end if;
  select * into e from public.combat_encounters where id = v_enc;
  if e.status <> 'retreating' or e.retreat_started_at is null then
    raise exception 'REPOOUTSIDE FAIL: the encounter is %/% — the sole retreat authority did not arm', e.status, e.retreat_started_at; end if;
  select * into pr from public.location_presence where id = e.presence_id;
  if pr.status <> 'retreating' or pr.retreat_requested_at is null then
    raise exception 'REPOOUTSIDE FAIL: the presence is %/% — the sole retreat authority did not arm', pr.status, pr.retreat_requested_at; end if;
  if abs(e.engagement_x - a3x) > 1e-6 or abs(e.engagement_y - a3y) > 1e-6 then
    raise exception 'REPOOUTSIDE FAIL: a retreat order restamped the engagement point'; end if;
  select count(*) into n from public.fleet_movements where fleet_id = v_fleet;
  if n <> n_mv0 then raise exception 'REPOOUTSIDE FAIL: the retreat order minted a leg immediately (the tick mints it when the window expires)'; end if;
  t_req := pr.retreat_requested_at; t_start := e.retreat_started_at;

  -- ── 2. NOW RETREATING: an order back to an ADMITTED point must NOT jump. ────────────────────────
  irx := a3x + 300; iry := a3y;
  if not public.combat_encounter_zone_admits_point(v_enc, irx, iry) then
    raise exception 'REPOOUTSIDE FAIL fixture: the admitted point is not admitted — the no-jump property would be vacuous'; end if;
  r := pg_temp.call_as(uL, format('public.command_ship_group_go(%L::uuid, null, %s, %s)', gL, irx, iry));
  if (r->>'ok')::boolean is not true or (r->>'order_outcome') is distinct from 'retreat_destination_updated' then
    raise exception 'REPOOUTSIDE FAIL: an admitted order on a RETREATING fight answered % — a mid-retreat jump would be a free escape from the damage window', r; end if;
  select * into fl from public.fleets where id = v_fleet;
  if fl.retreat_target_x is distinct from irx or fl.retreat_target_y is distinct from iry then
    raise exception 'REPOOUTSIDE FAIL: the stored destination was not replaced (%, %)', fl.retreat_target_x, fl.retreat_target_y; end if;
  if abs(fl.space_x - a3x) > 1e-6 or abs(fl.space_y - a3y) > 1e-6 then
    raise exception 'REPOOUTSIDE FAIL: the retreating fleet MOVED (%,%) — the blocked reposition still wrote a position', fl.space_x, fl.space_y; end if;
  select * into e from public.combat_encounters where id = v_enc;
  select * into pr from public.location_presence where id = e.presence_id;
  if abs(e.engagement_x - a3x) > 1e-6 or abs(e.engagement_y - a3y) > 1e-6 then
    raise exception 'REPOOUTSIDE FAIL: the blocked reposition restamped the engagement point'; end if;
  if e.retreat_started_at is distinct from t_start or pr.retreat_requested_at is distinct from t_req then
    raise exception 'REPOOUTSIDE FAIL: the retreat window was restarted (% -> %, % -> %) — a free reset of the damage window', t_start, e.retreat_started_at, t_req, pr.retreat_requested_at; end if;
  select count(*) into n
    from dz_repo_u2 b join public.combat_units cu on cu.id = b.id
   where cu.pos_x is distinct from b.pos_x or cu.pos_y is distinct from b.pos_y;
  if n <> 0 then
    raise exception 'REPOOUTSIDE FAIL: % unit(s) moved across the two retreat-path orders — only a real reposition may translate the formation', n; end if;

  raise notice 'DZCOMBAT_PASS_REPOOUTSIDE ok: the mirror order (destination inside a non-holding zone, admitted by nothing) stored (%,%) and armed the one retreat authority (presence + encounter retreating, fleet unmoved, no restamp, no leg); the admitted order on the retreating fight only replaced the destination with (%,%) — no jump, no restamp, no clock restart',
    obx, oby, irx, iry;
end $$;

-- ════════ DZCOMBAT_PASS_REPOHOLD (0337): A STANDING COURSE DIES WITH THE FIGHT IT BELONGS TO ════════
-- THE DEFECT THIS CLASS ALWAYS PRODUCES, named in the slice's own brief: a destination that outlives
-- its encounter. This repository has already been bitten by it once — fleets.retreat_target_* is a
-- destination stored on the FLEET row, and 0336 had to add fleet_consume_retreat_target and call it
-- from FOUR arms because a dead fleet kept a course its next sortie then flew. 0337 stores the
-- reposition destination on the ENCOUNTER instead, precisely so that there is nothing to consume:
-- the tick only ever selects status in ('active','retreating'), and the reposition step re-reads
-- status = 'active' at the instant of acting, so a course on a fight that is leaving or over is
-- unreachable BY CONSTRUCTION.
--
-- This block proves the sharp end of that, on the exact state the previous block leaves behind: an
-- encounter that is RETREATING while still carrying the course REPOOVERLAP recorded. It is the live
-- shape of "the owner ordered a reposition and then pressed Retreat mid-move."
--
-- NON-VACUITY IS THE WHOLE DIFFICULTY: "the fleet did not move" passes trivially on a fleet that
-- could never move. So the block pins, before ticking, that (a) a course IS standing, (b) the fleet's
-- own combat speed is positive — it COULD cover ground — and (c) the only thing between it and the
-- destination is the fence. Flip the step's `ce.status = 'active'` to a read of the loop record and
-- this block goes red while every other reposition assert stays green.
do $$
declare
  n int;
  v_fleet uuid := (select v from dzc where k='ra_fleet');
  v_enc uuid := (select v from dzc where k='ra_enc2');
  v_speed double precision;
  b_x double precision; b_y double precision;
  rpx double precision; rpy double precision;
  e record; fl record;
begin
  select * into e from public.combat_encounters where id = v_enc;
  if e.status <> 'retreating' then
    raise exception 'REPOHOLD FAIL precondition: the encounter is % (want retreating — the previous block arms it)', e.status; end if;
  if e.reposition_x is null or e.reposition_y is null then
    raise exception 'REPOHOLD FAIL precondition: no course is standing, so "it did not follow the course" is vacuous'; end if;
  rpx := e.reposition_x; rpy := e.reposition_y;
  b_x := e.engagement_x; b_y := e.engagement_y;
  v_speed := public.combat_fleet_move_speed(v_enc);
  if v_speed is null or v_speed <= 0 then
    raise exception 'REPOHOLD FAIL precondition: the fleet''s combat speed is % — it could not move under any circumstances and this block would pass vacuously', v_speed; end if;
  if public.osn_distance(b_x, b_y, rpx, rpy) <= v_speed then
    raise exception 'REPOHOLD FAIL precondition: the standing course is within a single step (% units at speed %) — a hold and an arrival would be indistinguishable', public.osn_distance(b_x, b_y, rpx, rpy), v_speed; end if;
  select count(*) into n from public.combat_units where encounter_id = v_enc and side = 'player' and alive_count > 0;
  if n < 1 then raise exception 'REPOHOLD FAIL precondition: no living player unit — nothing could have moved'; end if;

  -- ── THE TICK. A retreating fight is LEAVING, not manoeuvring: the fence is the engine's own rule
  -- ── for a retreating side, asked once more by the step's fresh status read.
  perform pg_temp.ae_tick(v_enc);

  select * into e from public.combat_encounters where id = v_enc;
  if e.status <> 'retreating' then
    raise exception 'REPOHOLD FAIL: the encounter went % on the tick (want retreating — the retreat window has not expired), so the hold below would be proving the wrong thing', e.status; end if;
  if abs(e.engagement_x - b_x) > 1e-9 or abs(e.engagement_y - b_y) > 1e-9 then
    raise exception 'REPOHOLD FAIL: a RETREATING fight walked from (%,%) to (%,%) toward a course ordered before the retreat — a stale destination is steering a fleet that is trying to leave', b_x, b_y, e.engagement_x, e.engagement_y; end if;
  select * into fl from public.fleets where id = v_fleet;
  if abs(fl.space_x - b_x) > 1e-9 or abs(fl.space_y - b_y) > 1e-9 then
    raise exception 'REPOHOLD FAIL: the retreating fleet''s marker moved to (%,%) — the retreat leg must depart from where the fleet actually stands', fl.space_x, fl.space_y; end if;
  -- and the FORMATION did not creep either: every PLAYER row is exactly where the snapshot taken
  -- before REPOOUTSIDE's orders left it (dz_repo_u2, which that block already proved unmoved). The
  -- enemy side is deliberately NOT pinned here — pirates keep closing on a retreating fleet, which is
  -- the engine working; only the player side is under the fence this block is about.
  select count(*) into n
    from dz_repo_u2 b join public.combat_units cu on cu.id = b.id
   where cu.side = 'player'
     and (cu.pos_x is distinct from b.pos_x or cu.pos_y is distinct from b.pos_y);
  if n <> 0 then
    raise exception 'REPOHOLD FAIL: % player unit(s) moved across a retreating tick — the rigid translate ran on a fight that is leaving', n; end if;
  -- the course is still ON the row and still untouched: 0337 clears NOTHING on a retreat, because a
  -- value nobody reads is already gone. If a future slice adds a clearing write, this line names it.
  if e.reposition_x is distinct from rpx or e.reposition_y is distinct from rpy then
    raise exception 'REPOHOLD FAIL: the course changed to (%,%) across a tick that must not touch it — the fence is the reader, not a writer', e.reposition_x, e.reposition_y; end if;

  raise notice 'DZCOMBAT_PASS_REPOHOLD ok: a RETREATING fight carrying a course to (%,%) — with a living fleet, a positive speed of % and % units still to run — moved NOT ONE unit across a real tick; the destination is fenced by the step''s own fresh status read, and nothing had to remember to clear it',
    rpx, rpy, v_speed, public.osn_distance(b_x, b_y, rpx, rpy);
end $$;

-- ════════ DZCOMBAT_PASS_REPOMODE (0339): A SITE FIGHT CAN BE MANOEUVRED IN ═══════════════════════
-- ██ INVERTED BY 0339, BECAUSE THE PROPERTY IT PINNED WAS THE OWNER'S BUG ██
-- The owner, playing the live game: "when fighting, i am not able to move my fleet."
-- This block used to assert the OPPOSITE of the fix — that a site fight's admitted move order falls
-- through to the RETREAT arms — and it was green on that behaviour the whole time. That is what a
-- proof of a defect looks like from the inside, and it is worth stating plainly rather than quietly
-- rewriting: the property was adopted from 0311, whose reposition arm required
-- fleets.location_mode='space' because the TICK composed fleet_set_in_space, which nulls
-- current_location_id, and 0337 recorded that interaction with a live 'present' presence as
-- explicitly UNVERIFIED. A hunt fight is ALWAYS 'present', so the owner's every deliberate fight
-- landed in the fall-through and the button they pressed to MANOEUVRE broke off the fight instead.
-- 0339 verified it (fleet_set_in_space would indeed strand the presence — 0231:1146-1170) and
-- resolved it by composition rather than by a gate: combat_fleet_track_position writes the marker
-- only while the fleet's position is EXPRESSED in space, so a PRESENT fleet's row is never touched
-- and the hazard is impossible. The gate then had no reason left and was deleted.
-- SO THIS BLOCK NOW DEMANDS THE MOVE, AND IT FAILS ON THE DEPLOYED BODY at its second assert —
-- which answers retreat_started. It also pins the half that made the old restriction necessary: the
-- fleet row and the live presence must come through the journey untouched.
-- Fixture: RIGFALLBACK's live hunt fight, reused — its fleet is 'present' AT the hunt location
-- (location_mode <> 'space'). The zone is drawn AFTER the fight opened, which also proves the
-- linkage is DERIVED live geometry, never a stored snapshot.
do $$
declare
  r jsonb; n int;
  uZ uuid := (select v from dzc where k='uZ');
  uL uuid := (select v from dzc where k='uL');
  gM uuid := (select v from dzc where k='rf_group');
  v_fleet uuid := (select v from dzc where k='rf_fleet');
  v_enc uuid := (select v from dzc where k='rf_enc');
  v_hunt uuid := (select v from dzc where k='v_hunt');
  hx double precision; hy double precision;
  v_verts jsonb;
  ix double precision; iy double precision;
  fl0 record; fl record; e record; pr record;
  n_mv0 int;
begin
  if v_enc is null or v_fleet is null then
    raise exception 'REPOMODE FAIL: the RIGFALLBACK fixture was not handed over'; end if;
  select l.x, l.y into hx, hy from public.locations l where l.id = v_hunt;

  -- ── a zone AROUND the site, drawn with the real verb AFTER the fight opened. ────────────────────
  v_verts := jsonb_build_array(
    jsonb_build_array(hx - 160, hy - 160),
    jsonb_build_array(hx + 160, hy - 160),
    jsonb_build_array(hx + 160, hy + 160),
    jsonb_build_array(hx - 160, hy + 160));
  r := pg_temp.call_as(uZ, format('public.pirate_zone_create(%L, %L::jsonb, %L::uuid)',
                                  'DZC Reposition Mode Zone', v_verts::text, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'REPOMODE FAIL: zone: %', r; end if;

  -- ── vacuity guards: the fight is live and anchored, the in-zone point IS admitted (so only the
  -- ── fleet's location_mode decides the outcome), and the fleet is NOT in open space. ─────────────
  select * into e from public.combat_encounters where id = v_enc;
  if e.status <> 'active' then raise exception 'REPOMODE FAIL precondition: the encounter is % (want active)', e.status; end if;
  if e.engagement_x is null then raise exception 'REPOMODE FAIL precondition: the encounter has no engagement point'; end if;
  insert into dzn values ('rm_e0x', e.engagement_x), ('rm_e0y', e.engagement_y);
  select * into fl0 from public.fleets where id = v_fleet;
  if fl0.location_mode = 'space' then
    raise exception 'REPOMODE FAIL precondition: the fleet is in open space — the fall-through shape did not build'; end if;
  if fl0.retreat_target_location_id is not null or fl0.retreat_target_x is not null or fl0.retreat_target_y is not null then
    raise exception 'REPOMODE FAIL precondition: a retreat destination is already stored'; end if;
  ix := round(hx) + 2; iy := round(hy);
  if not public.combat_encounter_zone_admits_point(v_enc, ix, iy) then
    raise exception 'REPOMODE FAIL fixture: the in-zone point (%,%) is not admitted for the site fight — the mode arm would be unreachable and this block vacuous', ix, iy; end if;
  select count(*) into n_mv0 from public.fleet_movements where fleet_id = v_fleet;
  create temp table dz_repo_u3 on commit drop as
    select cu.id, cu.pos_x, cu.pos_y from public.combat_units cu where cu.encounter_id = v_enc;

  -- ── THE OWNER'S ORDER: MOVE, INSIDE THE FIGHT'S OWN REGION. IT MUST MOVE. ─────────────────────
  -- On the pre-0339 body this returns ok:true / retreat_started and the player who asked to
  -- manoeuvre has broken off the fight. THAT is the defect, and this is the assert that fails on it.
  r := pg_temp.call_as(uL, format('public.command_ship_group_go(%L::uuid, null, %s, %s)', gM, ix, iy));
  if (r->>'ok')::boolean is not true then
    raise exception 'REPOMODE FAIL: the admitted order was REFUSED (%) — a site fight''s in-region order must order a MOVE, never a refusal', r; end if;
  if (r->>'order_outcome') = 'retreat_started' then
    raise exception 'REPOMODE FAIL: the site fight''s in-region MOVE order was silently reclassified as a RETREAT — this is the owner''s "when fighting, i am not able to move my fleet", and it is the pre-0339 behaviour exactly: the player asked to manoeuvre and broke off the fight instead'; end if;
  if (r->>'order_outcome') is distinct from 'repositioning' then
    raise exception 'REPOMODE FAIL: the admitted order answered % (want repositioning)', r->>'order_outcome'; end if;

  -- ── THE ORDER MOVED NOTHING AND ARMED NOTHING: a course, and only a course. ────────────────────
  select * into fl from public.fleets where id = v_fleet;
  if fl.retreat_target_location_id is not null or fl.retreat_target_x is not null or fl.retreat_target_y is not null then
    raise exception 'REPOMODE FAIL: a reposition wrote a retreat destination (%, %, %) — a move is never a retreat',
      fl.retreat_target_location_id, fl.retreat_target_x, fl.retreat_target_y; end if;
  select * into e from public.combat_encounters where id = v_enc;
  if e.status <> 'active' then
    raise exception 'REPOMODE FAIL: the encounter is % after a MOVE order (want active — the fight must not break)', e.status; end if;
  if e.reposition_x is distinct from ix or e.reposition_y is distinct from iy then
    raise exception 'REPOMODE FAIL: the course was not recorded (%,%) — the order neither moved the fleet nor gave it one', e.reposition_x, e.reposition_y; end if;
  select * into pr from public.location_presence where id = e.presence_id;
  if pr.status <> 'active' or pr.retreat_requested_at is not null then
    raise exception 'REPOMODE FAIL: the presence is %/retreat_requested % — a move armed a retreat', pr.status, pr.retreat_requested_at; end if;
  select count(*) into n
    from dz_repo_u3 b join public.combat_units cu on cu.id = b.id
   where cu.pos_x is distinct from b.pos_x or cu.pos_y is distinct from b.pos_y;
  if n <> 0 then raise exception 'REPOMODE FAIL: the ORDER moved % combat unit(s) — an order records a course, it does not perform it', n; end if;

  -- ── AND THE TICK ACTUALLY CARRIES THE FIGHT, WITHOUT UN-DOCKING THE FLEET. ────────────────────
  -- This is the half that 0337 could not verify and therefore forbade. combat_fleet_track_position
  -- writes fleets.space_x/y ONLY while location_mode='space'; this fleet is PRESENT, so the fleet row
  -- must come through the journey byte-identical while the FIGHT moves. A body that composed
  -- fleet_set_in_space here would flip status to 'idle' and null current_location_id, stranding the
  -- live presence against a placeless fleet — which is exactly why 0337 left this shut.
  perform pg_temp.ae_tick(v_enc);
  select * into e from public.combat_encounters where id = v_enc;
  if e.status <> 'active' then
    raise exception 'REPOMODE FAIL: the encounter went % on the first step of the journey', e.status; end if;
  if abs(e.engagement_x - (select v from dzn where k='rm_e0x')) < 1e-9
     and abs(e.engagement_y - (select v from dzn where k='rm_e0y')) < 1e-9 then
    raise exception 'REPOMODE FAIL: after a full tick the fight has not moved at all — the order is standing and nothing is walking it, which is a course that can never be consumed'; end if;
  select * into fl from public.fleets where id = v_fleet;
  if fl.status is distinct from fl0.status or fl.location_mode is distinct from fl0.location_mode
     or fl.current_location_id is distinct from fl0.current_location_id then
    raise exception 'REPOMODE FAIL: the journey changed the fleet row to %/% at loc % (was %/% at loc %) — a PRESENT fleet must not be un-docked by the combat mover; fleet_set_in_space nulls current_location_id and would strand the live presence',
      fl.status, fl.location_mode, fl.current_location_id, fl0.status, fl0.location_mode, fl0.current_location_id; end if;
  select * into pr from public.location_presence where id = e.presence_id;
  if pr.status <> 'active' then
    raise exception 'REPOMODE FAIL: the presence is % after the journey — the fight''s own presence must survive its fleet manoeuvring', pr.status; end if;
  select count(*) into n from public.fleet_movements where fleet_id = v_fleet;
  if n <> n_mv0 then raise exception 'REPOMODE FAIL: the move minted a leg'; end if;

  raise notice 'DZCOMBAT_PASS_REPOMODE ok (0339): a fleet PRESENT at its hunt site — the shape every deliberate fight has — was ordered to (%,%) inside its own region and MOVED: repositioning, course recorded, nothing armed, nothing translated by the order; the tick then carried the fight from (%,%) to (%,%) while the fleet row stayed %/% at its dock and its presence stayed active. On the pre-0339 body this order answered retreat_started and broke off the fight, which is the owner''s "when fighting, i am not able to move my fleet"',
    ix, iy, round((select v from dzn where k='rm_e0x')::numeric, 3), round((select v from dzn where k='rm_e0y')::numeric, 3),
    round(e.engagement_x::numeric, 3), round(e.engagement_y::numeric, 3), fl.status, fl.location_mode;
end $$;

-- ════════ DZCOMBAT_PASS_AUTOEXIT (0310): THE HP AUTO-EXIT, ON THE REAL CHAIN ═════════════════════════
-- The owner's core combat law, staged end to end: waves are endless by design, so the ONLY good
-- outcome of a fight is leaving it at the right moment — and until 0310 nothing left automatically.
--
-- A FRESH fixture player (its own auth row → the signup trigger mints its Home Base, so the
-- auto-exit's no-destination completion has its 'base' fallback exactly as every live player does),
-- two single-ship groups:
--   group A — threshold set to 50 through the REAL RPC (proving the percentage is the player's);
--   group B — toggle turned OFF through the REAL RPC (proving OFF means the pre-0310 world), pct
--             left at the default 30 so the control fights BELOW the very number that would have
--             fired it.
-- Both fleets take a REAL ambush (drawn zone → command_ship_group_go → pending intercept →
-- process_fleet_movements fires it → encounter), and the REAL tick does all the damage: the enemy
-- attack knob is DERIVED from the encounter's own at-entry integrity and the defender's own
-- defense snapshot so each tick erodes ~6% of the fleet's hull — small enough that ticks are
-- OBSERVED above the threshold (asserted non-vacuous), large enough to cross it inside the loop.
--
-- WHY THIS BLOCK IS RED ON THE PRE-0310 BODY, BY CONSTRUCTION: the flip assertion demands that the
-- first tick ending at-or-below the threshold leaves the encounter 'retreating'. The pre-0310 tick
-- has no auto-exit arm, so that tick ends 'active' and the loop raises "never auto-requested
-- leave". Group B is the in-file control proving the assert machinery distinguishes the two
-- worlds: with the toggle OFF the SAME staging, SAME knobs, SAME loop ends 'active' — pre-0310
-- behaviour reproduced and asserted, so a green flip assert can never be vacuous.
do $$
declare
  r jsonb; n int; i int;
  uZ uuid := (select v from dzc where k='uZ');
  uA uuid;
  v_hunt uuid := (select v from dzc where k='v_hunt');
  sA uuid; sB uuid; gA uuid; gB2 uuid;
  o_x double precision; o_y double precision;
  v_verts jsonb;
  v_fleet uuid; v_mv uuid; v_enc uuid;
  mv record; pi record; enc record; prs record;
  v_imax double precision; v_def double precision; v_bd double precision;
  v_eab_before double precision; v_eab numeric;
  v_srg_before double precision;
  v_thresh double precision; v_hp double precision;
  v_hp_a double precision; v_imax_a double precision;
  v_cap double precision; v_cap3 double precision; v_imax3 double precision; v_cur3 double precision;
  v_enc2 uuid; v_enc3 uuid; v_txt text;
  n_above int := 0;
  v_flipped boolean := false;
  v_started timestamptz;
begin
  -- ── A fresh, funded fixture player. The auth insert fires the signup trigger → Home Base exists,
  --    which is what the completion's origin-base fallback resolves for every real player. ─────────
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.ae.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uA;
  insert into public.player_wallet (player_id, balance) values (uA, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
  if not exists (select 1 from public.bases where player_id = uA) then
    raise exception 'AUTOEXIT FAIL: the signup trigger minted no base — the completion''s origin-base fallback would be untestable here and broken for a real player';
  end if;

  -- ── Two ships, two groups, both command-designated — 100% real RPCs. ────────────────────────────
  r := pg_temp.call_as(uA, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: commission A: %', r; end if;
  select main_ship_id into sA from public.main_ship_instances where player_id = uA;
  r := pg_temp.call_as(uA, 'public.upsert_ship_group(1, ''Auto Exit A'')');
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: group A: %', r; end if;
  gA := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uA, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sA, gA));
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: assign A: %', r; end if;
  r := pg_temp.call_as(uA, format('public.set_fleet_command_ship(%L::uuid, true)', sA));
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: command A: %', r; end if;

  r := pg_temp.call_as(uA, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: commission B: %', r; end if;
  select main_ship_id into sB from public.main_ship_instances where player_id = uA and main_ship_id <> sA limit 1;
  if sB is null then raise exception 'AUTOEXIT FAIL: no second ship materialised'; end if;
  r := pg_temp.call_as(uA, 'public.upsert_ship_group(2, ''Auto Exit B'')');
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: group B: %', r; end if;
  gB2 := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uA, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sB, gB2));
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: assign B: %', r; end if;
  r := pg_temp.call_as(uA, format('public.set_fleet_command_ship(%L::uuid, true)', sB));
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: command B: %', r; end if;

  -- ── The columns landed defaulted: ON at 30 for a brand-new group (the 0310 headline). ──────────
  select count(*) into n from public.ship_groups
   where group_id in (gA, gB2) and auto_exit_enabled and auto_exit_hp_pct = 30;
  if n <> 2 then
    raise exception 'AUTOEXIT FAIL: % of 2 fresh groups defaulted to enabled/30 — the protective default is not what 0310 states', n;
  end if;

  -- ── The player adjusts: group A to 50%; group B toggled OFF — through the ONE writer. ──────────
  r := pg_temp.call_as(uA, format('public.set_group_auto_exit(%L::uuid, true, 50)', gA));
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: set 50 on A: %', r; end if;
  r := pg_temp.call_as(uA, format('public.set_group_auto_exit(%L::uuid, false, 30)', gB2));
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: toggle OFF on B: %', r; end if;

  -- ── The writer's own boundary, exercised not assumed. ──────────────────────────────────────────
  r := pg_temp.call_as(uA, format('public.set_group_auto_exit(%L::uuid, true, 150)', gA));
  if (r->>'reason') is distinct from 'invalid_auto_exit_pct' then
    raise exception 'AUTOEXIT FAIL: pct 150 answered % — the server-side bounds are not the authority', r; end if;
  r := pg_temp.call_as(uA, format('public.set_group_auto_exit(%L::uuid, true, 4)', gA));
  if (r->>'reason') is distinct from 'invalid_auto_exit_pct' then
    raise exception 'AUTOEXIT FAIL: pct 4 answered % — the lower bound is not enforced', r; end if;
  r := pg_temp.call_as(uA, format('public.set_group_auto_exit(%L::uuid, true, ''NaN''::numeric)', gA));
  if (r->>'reason') is distinct from 'invalid_auto_exit_pct' then
    raise exception 'AUTOEXIT FAIL: NaN answered % — numeric NaN sorts above every value and a one-sided bound would accept it', r; end if;
  r := pg_temp.call_as(uA, format('public.set_group_auto_exit(%L::uuid, null, 30)', gA));
  if (r->>'reason') is distinct from 'invalid_auto_exit_toggle' then
    raise exception 'AUTOEXIT FAIL: a null toggle answered %', r; end if;
  r := pg_temp.call_as(uZ, format('public.set_group_auto_exit(%L::uuid, true, 50)', gA));
  if (r->>'reason') is distinct from 'group_not_found' then
    raise exception 'AUTOEXIT FAIL: another player''s write answered % (want group_not_found — owner-scoped, fail closed)', r; end if;
  -- and the TABLE's own CHECK, on a direct write (the layer beneath the RPC): NaN and out-of-range
  -- must be unstorable even if a future writer forgets to validate.
  begin
    update public.ship_groups set auto_exit_hp_pct = 'NaN'::numeric where group_id = gA;
    raise exception 'AUTOEXIT FAIL: the CHECK accepted NaN on a direct write';
  exception when check_violation then null;
  end;
  begin
    update public.ship_groups set auto_exit_hp_pct = 150 where group_id = gA;
    raise exception 'AUTOEXIT FAIL: the CHECK accepted 150 on a direct write';
  exception when check_violation then null;
  end;
  select auto_exit_hp_pct::double precision into v_hp from public.ship_groups where group_id = gA;
  if v_hp <> 50 then
    raise exception 'AUTOEXIT FAIL: group A''s threshold is % after the refused writes (want 50 intact)', v_hp;
  end if;

  -- ── Group A: a REAL ambush. Zone drawn perpendicular to the earlier scenarios' corridors so no
  --    other zone is crossed; attached to the hunt location (identity), like every zone here. ─────
  select l.x, l.y into o_x, o_y
    from public.main_ship_instances s
    join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = uA and f.status = 'present'
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
    join public.locations l on l.id = lp.location_id
   where s.group_id = gA
   limit 1;
  if o_x is null then raise exception 'AUTOEXIT FAIL: could not resolve group A''s docked origin'; end if;
  v_verts := jsonb_build_array(
    jsonb_build_array(o_x - 100, o_y + 400),
    jsonb_build_array(o_x + 100, o_y + 400),
    jsonb_build_array(o_x + 100, o_y + 600),
    jsonb_build_array(o_x - 100, o_y + 600));
  r := pg_temp.call_as(uA, format('public.pirate_zone_create(%L, %L::jsonb, %L::uuid)',
                                  'DZC Auto Exit Zone', v_verts::text, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: zone: %', r; end if;

  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gA, round(o_x), round(o_y + 1000)));
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: go A: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if pi is null then raise exception 'AUTOEXIT FAIL: no pending ambush on group A''s leg (risk knobs are 1.0)'; end if;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id, fleet_id into v_enc, v_fleet from public.combat_encounters
   where player_id = uA and status = 'active';
  if v_enc is null then raise exception 'AUTOEXIT FAIL: the ambush opened no encounter for group A'; end if;

  -- ── Derive the enemy attack from the fight's OWN numbers (never an ambient assumption): ~6% of
  --    the at-entry integrity per tick after the defender's own mitigation curve. Set BEFORE the
  --    first tick — the wave snapshots its weapons at spawn. ───────────────────────────────────────
  select player_integrity_max into v_imax from public.combat_encounters where id = v_enc;
  if v_imax is null or v_imax <= 0 then
    raise exception 'AUTOEXIT FAIL: at-entry integrity is % — the threshold would have no denominator', v_imax;
  end if;
  select coalesce(max(defense_snapshot), 0) into v_def from public.combat_units
   where encounter_id = v_enc and side = 'player';
  -- bd from the ENCOUNTER's OWN location (its identity), never an assumed one — the wave formulas
  -- read exactly this row, so the derived knob tracks whatever location the ambush resolved.
  select l.base_difficulty into v_bd
    from public.combat_encounters ce join public.locations l on l.id = ce.location_id
   where ce.id = v_enc;
  if v_bd is null or v_bd <= 0 then raise exception 'AUTOEXIT FAIL: the encounter''s location has base_difficulty %', v_bd; end if;
  select coalesce(public.cfg_num('enemy_attack_base'), 0) into v_eab_before;
  v_eab := round(((0.06 * v_imax) * ((100 + v_def) / 100.0) / (v_bd * 1.25))::numeric, 6);
  perform public.set_game_config('enemy_attack_base', to_jsonb(v_eab));
  -- erosion must be monotone; captured and restored at the end like every knob this block touches.
  select coalesce(public.cfg_num('shield_regen_combat_pct'), 0) into v_srg_before;
  perform public.set_game_config('shield_regen_combat_pct', '0'::jsonb);

  -- THE THRESHOLD'S REAL DENOMINATOR: the fleet's full capacity (sum of max_hp over the
  -- encounter's member units) — exactly what the 0310 arm computes. For THIS factory-fresh fleet
  -- it must equal the entry integrity, and that identity is asserted so the fresh-fleet loop below
  -- is knowingly testing both denominators at once; the damaged re-entry afterwards is where they
  -- part ways and the capacity one is proven to be the one in charge.
  -- alias u, mirroring the 0310 arm: cu is exactly the alias that was ambiguous inside the tick
  -- (a declared record variable there), and the one alias worth removing on sight everywhere.
  select sum(msi.max_hp)::double precision into v_cap
    from public.combat_units u
    join public.main_ship_instances msi on msi.main_ship_id = u.main_ship_id
   where u.encounter_id = v_enc and u.side = 'player' and u.main_ship_id is not null;
  if v_cap is null or v_cap <= 0 then
    raise exception 'AUTOEXIT FAIL: no capacity resolved for group A''s encounter (member units missing?)';
  end if;
  if abs(v_cap - v_imax) > 1e-6 then
    raise exception 'AUTOEXIT FAIL: a factory-fresh fleet''s capacity (%) differs from its entry integrity (%) — the fresh-fleet staging premise is broken', v_cap, v_imax;
  end if;
  v_thresh := v_cap * 0.50;

  -- ── THE LOOP: the REAL tick does the damage; every tick is judged BOTH ways. A tick that ends
  --    'active' at-or-below the threshold is the pre-0310 defect — fail. A tick that ends
  --    'retreating' ABOVE the threshold fired early — fail. ────────────────────────────────────────
  for i in 1..60 loop
    perform pg_temp.ae_tick(v_enc);
    select * into enc from public.combat_encounters where id = v_enc;
    v_hp := enc.player_integrity_current;
    if enc.status = 'active' then
      if v_hp <= v_thresh then
        raise exception 'AUTOEXIT FAIL: tick % ended active at hull %/% (threshold %) — the fleet never auto-requested leave (the pre-0310 world)',
          i, v_hp, v_imax, v_thresh;
      end if;
      n_above := n_above + 1;
    elsif enc.status = 'retreating' then
      if v_hp > v_thresh + 1e-6 then
        raise exception 'AUTOEXIT FAIL: the fleet auto-exited ABOVE its threshold (hull %/% > %)', v_hp, v_imax, v_thresh;
      end if;
      v_flipped := true;
      exit;
    else
      raise exception 'AUTOEXIT FAIL: encounter reached % mid-loop (hull %/%) — the staging died before the threshold', enc.status, v_hp, v_imax;
    end if;
  end loop;
  if not v_flipped then
    raise exception 'AUTOEXIT FAIL: 60 ticks never crossed the 50%% threshold (hull still %/%) — the derived attack knob is wrong, not the feature', v_hp, v_imax;
  end if;
  if n_above < 1 then
    raise exception 'AUTOEXIT FAIL: never observed above threshold — the first tick already crossed it, so "does not fire early" was not exercised (vacuous)';
  end if;
  if v_hp <= 0 then
    raise exception 'AUTOEXIT FAIL: the fleet is at 0 hull — it died instead of leaving; the safety line failed its one job';
  end if;
  v_hp_a := v_hp; v_imax_a := v_imax;  -- group A's flip numbers, before the control reuses the locals

  -- ── The flip is the CANONICAL retreat, not a lookalike: presence + encounter + timer + the ONE
  --    event, all stamped by the composed authority. ───────────────────────────────────────────────
  select * into prs from public.location_presence where id = enc.presence_id;
  if prs.status is distinct from 'retreating' or prs.retreat_requested_at is null then
    raise exception 'AUTOEXIT FAIL: presence is %/% — presence_request_leave did not arm the retreat', prs.status, prs.retreat_requested_at;
  end if;
  if enc.retreat_started_at is null then
    raise exception 'AUTOEXIT FAIL: retreat_started_at is unset — combat_set_retreating never ran, the completion branch could never finish this';
  end if;
  select count(*) into n from public.combat_events where encounter_id = v_enc and event_type = 'retreat_started';
  if n <> 1 then
    raise exception 'AUTOEXIT FAIL: % retreat_started event(s) (want exactly 1 — the one author is combat_set_retreating)', n;
  end if;
  v_started := enc.retreat_started_at;

  -- ── A second tick must NOT re-request (the encounter is 'retreating'; the arm is unreachable). ──
  perform pg_temp.ae_tick(v_enc);
  select * into enc from public.combat_encounters where id = v_enc;
  if enc.status is distinct from 'retreating' or enc.retreat_started_at is distinct from v_started then
    raise exception 'AUTOEXIT FAIL: a second tick re-requested the retreat (status %, timer % -> %)', enc.status, v_started, enc.retreat_started_at;
  end if;
  select count(*) into n from public.combat_events where encounter_id = v_enc and event_type = 'retreat_started';
  if n <> 1 then
    raise exception 'AUTOEXIT FAIL: a second tick re-requested the retreat (% retreat_started events)', n;
  end if;

  -- ── And it COMPLETES like a human press: rewind the retreat clock past the delay window (the
  --    drain_encounter idiom — now() is frozen in-txn), one tick, and the completion branch ends
  --    the fight and turns the fleet home (no destination was ordered → the origin-base arm). ─────
  update public.combat_encounters set retreat_started_at = retreat_started_at - interval '1 hour' where id = v_enc;
  perform pg_temp.ae_tick(v_enc);
  select * into enc from public.combat_encounters where id = v_enc;
  if enc.status is distinct from 'escaped' then
    raise exception 'AUTOEXIT FAIL: the auto-requested retreat did not complete like a human press (encounter % after the delay window)', enc.status;
  end if;
  select status into v_txt from public.fleets where id = v_fleet;
  if v_txt is distinct from 'returning' then
    raise exception 'AUTOEXIT FAIL: the fleet is % after completion (want returning — fleet_set_returning is the completion''s own verb)', v_txt;
  end if;

  -- ── THE DAMAGED RE-ENTRY — the regression the capacity denominator exists for. ─────────────────
  -- The same fleet, UN-REPAIRED (repair needs a port; it retreated to open coordinates), goes out
  -- again and is ambushed again. Its entry hull is now well under its capacity, so the encounter's
  -- own player_integrity_max (seeded from the CURRENT hull) and the real capacity DIVERGE — and
  -- that divergence is asserted, or this scenario proves nothing. With the player's threshold
  -- raised to 60%, the fleet enters ALREADY below the line and must auto-exit on the FIRST tick.
  -- A body measuring the entry hull reads that tick as ~94% of "max" and fights on — this exact
  -- assert is what fails on the cb10020 denominator, and what stops the compounding spiral
  -- (capacity 1000 -> exit 300 -> next "max" 300 -> exit 90 -> 27 -> dead before the arm runs).
  --
  -- First, land the return leg so the group is commandable again (the MANIFESTHELD idiom: clocks
  -- only, the settle itself is the real processor).
  for i in 1..10 loop
    exit when not exists (select 1 from public.fleet_movements where fleet_id = v_fleet and status = 'moving');
    update public.fleet_movements set depart_at = depart_at - interval '1 hour',
                                      arrive_at = arrive_at - interval '1 hour'
     where fleet_id = v_fleet and status = 'moving';
    perform public.process_fleet_movements();
  end loop;
  if exists (select 1 from public.fleet_movements where fleet_id = v_fleet and status = 'moving') then
    raise exception 'AUTOEXIT FAIL: group A''s return leg never settled — the re-entry cannot be staged';
  end if;

  -- The un-repaired hull, from the ship's own row (the tick synced it all fight long).
  select msi.hp::double precision, msi.max_hp::double precision into v_hp, v_cap
    from public.main_ship_instances msi where msi.main_ship_id = sA;
  if v_hp is null or v_hp <= 0 then
    raise exception 'AUTOEXIT FAIL: group A''s ship reads hull % after its fight — the re-entry needs a damaged, living ship', v_hp;
  end if;
  if v_hp >= v_cap * 0.60 then
    raise exception 'AUTOEXIT FAIL: group A''s ship still holds %/% hull — not below the 60%% re-entry threshold, so the first-tick exit could not be attributed to the capacity denominator (staging, not feature)', v_hp, v_cap;
  end if;

  -- The player raises the line to 60 — through the ONE writer, like every adjustment here.
  r := pg_temp.call_as(uA, format('public.set_group_auto_exit(%L::uuid, true, 60)', gA));
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: set 60 on A: %', r; end if;

  -- Out again, through the SAME standing zone corridor (the fleet completed at its Home Base,
  -- whose coordinate is the starter port's anchor — the same origin the first leg flew from).
  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gA, round(o_x), round(o_y + 1000)));
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: re-entry go: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if pi is null then raise exception 'AUTOEXIT FAIL: the re-entry leg scheduled no ambush (the standing zone should cover it)'; end if;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id into v_enc3 from public.combat_encounters where player_id = uA and status = 'active';
  if v_enc3 is null then raise exception 'AUTOEXIT FAIL: the re-entry ambush opened no encounter'; end if;

  -- ★ REPOINTED BY 0317, AND THE PROPERTY IS STRICTLY STRONGER. This asserted that the encounter's
  -- ★ player_integrity_max was strictly UNDER capacity — because it was seeded from the ship's
  -- ★ CURRENT hp, which is exactly the defect 0317 removed: the bar opened full on a battered fleet
  -- ★ while this safety line divided by real capacity, so the two could never agree. hp_max is
  -- ★ capacity now, so those two numbers are EQUAL BY CONSTRUCTION and the old premise can never
  -- ★ hold again. The regression it guarded (an auto-exit measuring the damaged entry hull instead
  -- ★ of capacity) is therefore closed structurally rather than by assertion — and the identity that
  -- ★ closes it is asserted HERE, so a future change that re-seeds hp_max from live hp fails on this
  -- ★ line instead of quietly reopening the compounding denominator.
  -- ★ The DIVERGENCE this scenario still needs has moved to the quantity that still varies: the
  -- ★ fleet's LIVE hull (player_integrity_current) strictly under its capacity. Equal values would
  -- ★ mean the fleet re-entered undamaged and could not possibly be under its line, which is what
  -- ★ would make the first-tick exit prove nothing.
  select player_integrity_max, player_integrity_current into v_imax3, v_cur3
    from public.combat_encounters where id = v_enc3;
  select sum(msi.max_hp)::double precision into v_cap3
    from public.combat_units u
    join public.main_ship_instances msi on msi.main_ship_id = u.main_ship_id
   where u.encounter_id = v_enc3 and u.side = 'player' and u.main_ship_id is not null;
  if v_cap3 is null or v_imax3 is null or v_cur3 is null then
    raise exception 'AUTOEXIT FAIL: the re-entry encounter carries no integrity numbers (max %, current %, capacity %) — every comparison below would be vacuous', v_imax3, v_cur3, v_cap3;
  end if;
  if v_imax3 is distinct from v_cap3 then
    raise exception 'AUTOEXIT FAIL: the encounter''s player_integrity_max (%) is not the auto-exit''s own denominator, sum(main_ship_instances.max_hp) (%) — the bar and the safety line are measuring different things again (the pre-0317 compounding denominator)', v_imax3, v_cap3;
  end if;
  if v_cur3 >= v_cap3 then
    raise exception 'AUTOEXIT FAIL: the fleet re-entered at full hull (% of %) — it is not damaged, so a first-tick exit could not distinguish a capacity denominator from anything else and the re-entry proves nothing', v_cur3, v_cap3;
  end if;
  if v_cur3 >= v_cap3 * 0.60 then
    raise exception 'AUTOEXIT FAIL: the fleet re-entered at %/% — not below its 60%% line; the first-tick exit would be ambiguous', v_cur3, v_cap3;
  end if;

  -- ONE tick. Below the capacity line from the first evaluation → the canonical retreat, now.
  perform pg_temp.ae_tick(v_enc3);
  select * into enc from public.combat_encounters where id = v_enc3;
  if enc.status is distinct from 'retreating' then
    raise exception 'AUTOEXIT FAIL: the un-repaired fleet (%/% of capacity, threshold 60%%) did not auto-exit on entry (the compounding-denominator defect: the arm is measuring the damaged entry hull, not real capacity)',
      enc.player_integrity_current, v_cap3;
  end if;
  if enc.player_integrity_current <= 0 then
    raise exception 'AUTOEXIT FAIL: the re-entered fleet is at 0 hull — it died on the entry tick instead of leaving';
  end if;
  select count(*) into n from public.combat_events where encounter_id = v_enc3 and event_type = 'retreat_started';
  if n <> 1 then
    raise exception 'AUTOEXIT FAIL: the re-entry exit armed % retreat_started event(s) (want exactly 1)', n;
  end if;

  -- ── GROUP B, THE CONTROL: toggle OFF → the pre-0310 world, far below the default threshold. ────
  select l.x, l.y into o_x, o_y
    from public.main_ship_instances s
    join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = uA and f.status = 'present'
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
    join public.locations l on l.id = lp.location_id
   where s.group_id = gB2
   limit 1;
  if o_x is null then raise exception 'AUTOEXIT FAIL: could not resolve group B''s docked origin'; end if;
  v_verts := jsonb_build_array(
    jsonb_build_array(o_x - 100, o_y - 600),
    jsonb_build_array(o_x + 100, o_y - 600),
    jsonb_build_array(o_x + 100, o_y - 400),
    jsonb_build_array(o_x - 100, o_y - 400));
  r := pg_temp.call_as(uA, format('public.pirate_zone_create(%L, %L::jsonb, %L::uuid)',
                                  'DZC Auto Exit Control Zone', v_verts::text, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: control zone: %', r; end if;
  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gB2, round(o_x), round(o_y - 1000)));
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: go B: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id, fleet_id into v_enc2, v_fleet from public.combat_encounters
   where player_id = uA and status = 'active';
  if v_enc2 is null then raise exception 'AUTOEXIT FAIL: the control ambush opened no encounter for group B'; end if;
  if v_enc2 = v_enc then raise exception 'AUTOEXIT FAIL: the control resolved onto group A''s (escaped) encounter — staging is tangled'; end if;

  select player_integrity_max into v_imax from public.combat_encounters where id = v_enc2;
  -- re-derive the knob from THIS fight's own numbers (its wave snapshots at ITS first tick).
  select coalesce(max(defense_snapshot), 0) into v_def from public.combat_units
   where encounter_id = v_enc2 and side = 'player';
  select l.base_difficulty into v_bd
    from public.combat_encounters ce join public.locations l on l.id = ce.location_id
   where ce.id = v_enc2;
  if v_bd is null or v_bd <= 0 then raise exception 'AUTOEXIT FAIL: the control encounter''s location has base_difficulty %', v_bd; end if;
  v_eab := round(((0.06 * v_imax) * ((100 + v_def) / 100.0) / (v_bd * 1.25))::numeric, 6);
  perform public.set_game_config('enemy_attack_base', to_jsonb(v_eab));
  for i in 1..60 loop
    perform pg_temp.ae_tick(v_enc2);
    select * into enc from public.combat_encounters where id = v_enc2;
    v_hp := enc.player_integrity_current;
    if enc.status is distinct from 'active' then
      raise exception 'AUTOEXIT FAIL: the control fleet auto-exited with the toggle OFF (encounter % at hull %/%)', enc.status, v_hp, v_imax;
    end if;
    exit when v_hp <= v_imax * 0.20;
  end loop;
  if v_hp > v_imax * 0.30 then
    raise exception 'AUTOEXIT FAIL: the control never sank below the default 30%% threshold (hull %/%) — "toggle OFF keeps fighting" was not exercised (vacuous)', v_hp, v_imax;
  end if;
  select count(*) into n from public.combat_events where encounter_id = v_enc2 and event_type = 'retreat_started';
  if n <> 0 then
    raise exception 'AUTOEXIT FAIL: the control fleet auto-exited with the toggle OFF (% retreat_started events)', n;
  end if;

  perform public.set_game_config('enemy_attack_base', to_jsonb(v_eab_before));
  perform public.set_game_config('shield_regen_combat_pct', to_jsonb(v_srg_before));

  raise notice 'DZCOMBAT_PASS_AUTOEXIT ok: default ON at 30 for fresh groups; the player set 50%% / toggled OFF through the one writer (bad pct, NaN, null toggle, cross-player all refused; the table CHECK refuses NaN/150 beneath it); group A fought % tick(s) above its CAPACITY-based threshold untouched, then auto-requested the canonical retreat the tick its hull hit %/% of capacity (presence retreating, retreat_started_at stamped, exactly 1 retreat_started event), a second tick did not re-request, and the retreat COMPLETED like a human press (escaped, fleet returning, origin-base arm); the DAMAGED RE-ENTRY (0317: the encounter bar''s own max % IS the auto-exit denominator, capacity %, and the fleet re-entered with a LIVE hull strictly under its 60%% line) auto-exited on its FIRST tick — the compounding-denominator regression, now closed by construction and pinned by that identity; group B — toggle OFF — fought on to %/% with zero retreat events: the pre-0310 world, reproduced as the control',
    n_above, round(v_hp_a::numeric), round(v_imax_a::numeric), round(v_imax3::numeric), round(v_cap3::numeric), round(v_hp::numeric), round(v_imax::numeric);
end $$;

-- ════════ DZCOMBAT_PASS_RSFEEL (0314): THE RUNESCAPE COMBAT FEEL, ON THE REAL CHAIN ═════════════════
-- The owner's ask: "attack with interval, showing hp, and everytime it deals differently."
-- Three properties, each RED on the pre-0314 tick body BY CONSTRUCTION:
--   1. INTERVAL — a weapon whose cooldown exceeds the tick period does NOT fire on the next tick.
--      The enemy wave spawns with a 3600s cooldown (owned knob, set before the spawn snapshots it);
--      tick 1 fires, tick 2 must be pirate-silent. Pre-0314 the tick armed next_ready_at with bare
--      now(), so tick 2 fired again -> red. (now() is txn-frozen, so 3600s can never elapse here —
--      the property provable in one txn is exactly "no fire while the cooldown is unelapsed";
--      re-fire AFTER elapse is live-cron behaviour, settled by the same arithmetic: now()+0 for a
--      zero cooldown is proven ready-every-tick below, on the player's own zeroed fallback.)
--   2. PER-HIT ROLL — two hits in the same tick carry DIFFERENT damage. Six pirates with identical
--      power hit the same command ship in tick 1 under combat_hit_variance_pct=0.5 (owned); their
--      unrounded payload damages must not all be equal. Pre-0314 every shot in a tick shared ONE
--      v_variance roll -> byte-identical numbers -> red. (With independent uniform doubles the
--      all-equal case has probability ~0 — this is not a tolerance assert.)
--   3. VISIBLE HIT — every landed hit emits hull_damage WITH its amount under combat_event_logging,
--      with combat_debug_logging pinned FALSE (owned in setup). Pre-0314 the spatial hitsplat was
--      debug-gated -> zero rows -> red.
-- Staging is the AUTOEXIT idiom end to end: fresh player, real RPCs only, real zone, real
-- processors, pg_temp.ae_tick as the one cadence driver. The only clock moved beyond ae_tick is
-- started_at (rewound 930s so the wave's danger derives a MULTI-UNIT spawn — same clock-only law
-- as every other rewind here; forced-extract needs 1800s, untouched).
--
-- ── 0336 RE-PREMISED: THE VOLLEY IS NOT ON TICK 1 ANY MORE, AND THAT IS A NEW PROPERTY ───────────
-- WHAT THIS BLOCK ASSERTED BEFORE: on TICK 1 the wave spawned AND fired — >= 3 pirate salvos, one
-- hull_damage per landed hit with its own amount, >= 2 distinct damage values across the volley, the
-- player's own hit visible, every fired weapon armed now()+3600s exactly — and TICK 2 was silent
-- while the player's zero-cooldown fallback kept firing.
-- WHAT IT ASSERTS NOW: EVERY ONE OF THOSE CLAUSES, VERBATIM, plus two the old form could not state.
-- Only the tick they are read from moved, and it moved because the geometry did: 0336 spawns each
-- unit of a wave at (the MEASURED player-formation extent + THAT wave's own weapon range + 1) from
-- the engagement anchor, so the wave arrives strictly outside its own reach of every player ship and
-- CANNOT fire on the tick it arrives. "on tick 1" was a statement about the pre-0336 world, where
-- every enemy was inserted ON the anchor — on top of the lead, at distance 0 — and therefore shot the
-- instant it existed. Asserting it now is asserting a world that no longer exists.
--   NEW (1) THE SPAWN TICK IS SILENT — zero pirate salvos on it. A body that ever lets a freshly
--           spawned wave shoot across its own structural clearance fails HERE.
--   NEW (2) THE VOLLEY TICK IS OBSERVED, NEVER PINNED — ticks are driven until a pirate salvo
--           actually exists, bounded, with a loud failure naming the encounter status, and a
--           `v_t1 > 1` vacuity pin so the loop cannot silently have done nothing. How many closing
--           ticks a wave needs is a function of the site's difficulty and the fleet's own combat
--           speed; pinning a number would re-introduce exactly the ambient assumption 0336 removed.
-- AND THE BLOCK OWNS THE ONE PRECONDITION ITS VOLLEY CLAUSE NEEDS. "Six identical guns roll distinct
-- damage IN ONE TICK" requires the whole wave to arrive together. The wave is laid out on a ring
-- around the anchor, so it IS equidistant from a lone hull standing on that anchor — but only while
-- the hull stays there. A player that out-ranges the wave KITES (combat_unit_decide_move's middle
-- arm) and every step it takes makes one arc of the ring nearer than another, which staggers the
-- arrival and would split the volley across two ticks. So combat_player_speed_scale is captured and
-- pinned to 0 BEFORE the encounter is created (the creator freezes each player row's move_speed from
-- it), the hull holds on the anchor, and the ring closes in perfect symmetry. This changes the
-- FIXTURE, never a property: nothing below is about approach geometry — this block is about the
-- CLOCK, the ROLL and the HITSPLAT — and every clause is asserted at full strength. Restored with
-- the other two knobs at the end.
do $$
declare
  r jsonb; n int; n_units int; n_exp int; n_hits int; n_distinct int;
  i int; v_tk int; v_status text;
  uR uuid;
  v_hunt uuid := (select v from dzc where k='v_hunt');
  sR uuid; gR uuid;
  o_x double precision; o_y double precision;
  v_verts jsonb;
  v_mv uuid; v_enc uuid;
  mv record; pi record;
  v_imax double precision; v_def double precision; v_bd double precision;
  v_danger int; v_scale double precision;
  v_eab_before double precision; v_eab numeric;
  v_cd_before double precision; v_hv_before double precision; v_ps_before double precision;
  v_esb_before double precision; v_esp_before double precision;  -- (0338) the wave's own closing speed
  v_t0 int; v_t1 int; v_t2 int;
begin
  -- ── a fresh, funded fixture player; one ship, one group, command designated — real RPCs. ───────
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.rs.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uR;
  insert into public.player_wallet (player_id, balance) values (uR, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
  r := pg_temp.call_as(uR, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'RSFEEL FAIL: commission: %', r; end if;
  select main_ship_id into sR from public.main_ship_instances where player_id = uR;
  r := pg_temp.call_as(uR, 'public.upsert_ship_group(1, ''RS Feel'')');
  if (r->>'ok')::boolean is not true then raise exception 'RSFEEL FAIL: group: %', r; end if;
  gR := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uR, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sR, gR));
  if (r->>'ok')::boolean is not true then raise exception 'RSFEEL FAIL: assign: %', r; end if;
  r := pg_temp.call_as(uR, format('public.set_fleet_command_ship(%L::uuid, true)', sR));
  if (r->>'ok')::boolean is not true then raise exception 'RSFEEL FAIL: command: %', r; end if;
  -- decouple 0310's arm entirely (also true by arithmetic — damage below stays under 40%):
  r := pg_temp.call_as(uR, format('public.set_group_auto_exit(%L::uuid, false, 30)', gR));
  if (r->>'ok')::boolean is not true then raise exception 'RSFEEL FAIL: auto-exit off: %', r; end if;

  -- ── OWN the knobs this block is about, BEFORE anything snapshots them. ──────────────────────────
  select coalesce(public.cfg_num('enemy_synthetic_cooldown_seconds'), 2) into v_cd_before;
  select coalesce(public.cfg_num('combat_hit_variance_pct'), 0)         into v_hv_before;
  perform public.set_game_config('enemy_synthetic_cooldown_seconds', '3600'::jsonb);
  perform public.set_game_config('combat_hit_variance_pct',          '0.5'::jsonb);
  -- 0336: THE HULL HOLDS THE ANCHOR, so the ring arrives all at once (see the header). The creator
  -- freezes every player row's combat move_speed as hull speed x this knob, so it has to be pinned
  -- BEFORE the ambush opens the encounter — after that the frozen column is what the tick reads.
  -- Captured, never assumed, and restored with the other two below.
  select coalesce(public.cfg_num('combat_player_speed_scale'), 0.2) into v_ps_before;
  perform public.set_game_config('combat_player_speed_scale',       '0'::jsonb);
  -- ██ (0338) OWN THE CLOSING SPEED, because the arrival lands EXACTLY ON THE RANGE BOUNDARY ██
  -- 0336 stands a wave at (measured extent + its own range + 1). The hull holds the anchor here, so
  -- the extent is 0 and every pirate spawns at exactly range + 1. At the SEEDED speed that is one
  -- close of exactly 1.0, which lands the whole wave at exactly range — the knife edge of its own
  -- fire gate, where `dist <= range` is decided by floating-point dust from six DIFFERENT cos/sin
  -- evaluations. This block was never testing that: it is about the attack INTERVAL and the per-hit
  -- roll, and it needs the volley to land on one tick for either to be measurable.
  -- MEASURED, NOT ARGUED: at the seeded speed the wave came to rest at d_hull = 3, 3, 4, 3, 4, 3 —
  -- two pirates a hair outside the gate, four a hair inside — and only 2 of 6 fired. It was a
  -- coincidence of symmetry that the seeded phase used to make all six land on the same side of the
  -- boundary, and 0338's arrival bearing is not that phase. A block must not depend on which way the
  -- dust falls, at any bearing.
  -- SO THE MARGIN IS OWNED: a closing step of 2 puts the wave a full unit INSIDE its own range after
  -- one close, while range + 1 still keeps the spawn tick silent by construction. The pinned
  -- properties are untouched — the arrival is still silent, the volley is still one tick, and the
  -- 3600s cooldown still proves the interval is real.
  select coalesce(public.cfg_num('enemy_synthetic_speed_base'), 0.6)            into v_esb_before;
  select coalesce(public.cfg_num('enemy_synthetic_speed_per_difficulty'), 0.04) into v_esp_before;
  perform public.set_game_config('enemy_synthetic_speed_base',           '2'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', '0'::jsonb);

  -- ── a REAL ambush through a drawn zone (the AUTOEXIT staging, verbatim in shape). ───────────────
  select l.x, l.y into o_x, o_y
    from public.main_ship_instances s
    join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = uR and f.status = 'present'
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
    join public.locations l on l.id = lp.location_id
   where s.group_id = gR
   limit 1;
  if o_x is null then raise exception 'RSFEEL FAIL: could not resolve the docked origin'; end if;
  -- the AUTOEXIT corridor geometry, verbatim: a vertical leg north through a zone straddling it.
  v_verts := jsonb_build_array(
    jsonb_build_array(o_x - 100, o_y + 400),
    jsonb_build_array(o_x + 100, o_y + 400),
    jsonb_build_array(o_x + 100, o_y + 600),
    jsonb_build_array(o_x - 100, o_y + 600));
  r := pg_temp.call_as(uR, format('public.pirate_zone_create(%L, %L::jsonb, %L::uuid)',
                                  'DZC RS Feel Zone', v_verts::text, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'RSFEEL FAIL: zone: %', r; end if;
  r := pg_temp.call_as(uR, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gR, round(o_x), round(o_y + 1000)));
  if (r->>'ok')::boolean is not true then raise exception 'RSFEEL FAIL: go: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if pi is null then raise exception 'RSFEEL FAIL: no pending ambush on the leg (risk knobs are 1.0)'; end if;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id into v_enc from public.combat_encounters where player_id = uR and status = 'active';
  if v_enc is null then raise exception 'RSFEEL FAIL: the ambush opened no encounter'; end if;

  -- ── a MULTI-UNIT wave: rewind started_at so the spawn's danger derives >= 3 units, and derive
  --    the expected count from the same knobs the tick reads (never an ambient assumption). ───────
  update public.combat_encounters set started_at = started_at - interval '930 seconds' where id = v_enc;
  v_danger := 1 + 0 + floor(930.0 / coalesce(public.cfg_num('danger_time_divisor_seconds'), 180))::int;
  n_exp    := least(coalesce(public.cfg_num('enemy_synthetic_max_units'), 6)::int, greatest(1, v_danger));
  if n_exp < 3 then
    raise exception 'RSFEEL FAIL: staging derives only % unit(s) — the wave is too small to exercise the roll spread', n_exp;
  end if;

  -- ── enemy attack derived from the fight's OWN numbers (the AUTOEXIT idiom): ~24%% of entry
  --    integrity per full volley -> ~4%% per hit, so six hits leave the command ship far alive. ───
  select player_integrity_max into v_imax from public.combat_encounters where id = v_enc;
  if v_imax is null or v_imax <= 0 then raise exception 'RSFEEL FAIL: entry integrity is %', v_imax; end if;
  select coalesce(max(defense_snapshot), 0) into v_def from public.combat_units
   where encounter_id = v_enc and side = 'player';
  select l.base_difficulty into v_bd
    from public.combat_encounters ce join public.locations l on l.id = ce.location_id
   where ce.id = v_enc;
  if v_bd is null or v_bd <= 0 then raise exception 'RSFEEL FAIL: base_difficulty %', v_bd; end if;
  -- 0341: the inverse of the engine's sizing is now (1 + scale) * bodies rather than
  -- (1 + danger * scale) — the pirate carries the danger and the wave is bodies x pirate. This keeps
  -- BOTH the wave total and the per-hit share exactly where this block sized them.
  v_scale := (1 + coalesce(public.cfg_num('enemy_attack_danger_scale'), 0.25)) * n_exp;
  select coalesce(public.cfg_num('enemy_attack_base'), 0) into v_eab_before;
  v_eab := round(((0.24 * v_imax) * ((100 + v_def) / 100.0) / (v_bd * v_scale))::numeric, 6);
  perform public.set_game_config('enemy_attack_base', to_jsonb(v_eab));

  -- ── THE SPAWN TICK: the wave arrives, and (0336) it arrives SILENT. ─────────────────────────────
  perform pg_temp.ae_tick(v_enc);
  select tick_number into v_t0 from public.combat_encounters where id = v_enc;
  if v_t0 is distinct from 1 then
    raise exception 'RSFEEL FAIL: the arrival tick is numbered % (want 1) — the silence pin below would be reading a tick the wave did not arrive on', v_t0;
  end if;
  select count(*) into n_units from public.combat_units where encounter_id = v_enc and side = 'enemy';
  if n_units <> n_exp then
    raise exception 'RSFEEL FAIL: % enemy unit(s) spawned (want the danger-derived %) — the wave is too small to exercise the roll spread', n_units, n_exp;
  end if;
  -- (0) 0336's NEW PROPERTY: a wave stands at (measured player extent + its own range + 1) from the
  --     anchor, i.e. strictly outside its own reach of every player ship, so it CANNOT shoot on the
  --     tick it arrives. The pre-0336 body fired here, so this clause is red on it by construction.
  select count(*) into n from public.combat_events
   where encounter_id = v_enc and tick_number = v_t0 and event_type = 'missile_salvo' and source = 'pirate';
  if n <> 0 then
    raise exception 'RSFEEL FAIL: % pirate salvo(s) on the tick the wave arrived on — 0336 stands a wave outside its own reach by construction, so it MUST close before it can fire', n;
  end if;

  -- ── DRIVE TICKS UNTIL THE WAVE HAS CLOSED AND FIRED. The exit condition is the OBSERVATION, ────
  --    never a tick count. Bounded, and a wave that never fires fails loudly with the status.
  for i in 1 .. 12 loop
    exit when v_t1 is not null;
    select status into v_status from public.combat_encounters where id = v_enc;
    if v_status is distinct from 'active' then
      raise exception 'RSFEEL FAIL: the encounter went % while the wave was closing — the volley this block exists to measure never happened', v_status;
    end if;
    perform pg_temp.ae_tick(v_enc);
    select tick_number into v_tk from public.combat_encounters where id = v_enc;
    select count(*) into n from public.combat_events
     where encounter_id = v_enc and tick_number = v_tk and event_type = 'missile_salvo' and source = 'pirate';
    if n > 0 then v_t1 := v_tk; end if;
  end loop;
  if v_t1 is null then
    raise exception 'RSFEEL FAIL: no pirate volley in 12 ticks after the spawn — the wave never closed into its own range, so there is no volley to measure';
  end if;
  -- NON-VACUITY: the spawn tick is pinned silent above, so a volley recorded ON it would mean the two
  -- asserts contradict each other rather than that this loop observed a closing approach.
  if v_t1 <= 1 then
    raise exception 'RSFEEL FAIL: the first pirate volley is recorded on tick % — the arrival tick was pinned SILENT, so the volley loop observed nothing', v_t1;
  end if;
  -- vacuity for the silence pin below: the volley tick really was a full pirate volley.
  select count(*) into n from public.combat_events
   where encounter_id = v_enc and tick_number = v_t1 and event_type = 'missile_salvo' and source = 'pirate';
  if n < 3 then
    -- (0338) THE FAILURE CARRIES THE GEOMETRY. This block's premise is that the hull HOLDS THE
    -- ANCHOR and the wave stands one ring out, so every pirate is the SAME distance away and the
    -- volley lands on one tick. If that stops being true the count alone says nothing about why, and
    -- the wave's layout is exactly what 0338 changed. Print it.
    raise exception 'RSFEEL FAIL: only % pirate salvo(s) on the volley tick % — no volley to measure. Wave layout, anchor (%,%), hull at (%,%): %',
      n, v_t1,
      (select engagement_x from public.combat_encounters where id = v_enc),
      (select engagement_y from public.combat_encounters where id = v_enc),
      (select pos_x from public.combat_units where encounter_id = v_enc and side = 'player' limit 1),
      (select pos_y from public.combat_units where encounter_id = v_enc and side = 'player' limit 1),
      (select string_agg(format('[%s at (%s,%s) d_hull=%s alive=%s range=%s speed=%s]',
                                left(e.id::text, 8), round(e.pos_x::numeric, 3), round(e.pos_y::numeric, 3),
                                round(public.osn_distance(e.pos_x, e.pos_y, p.pos_x, p.pos_y)::numeric, 3),
                                e.alive_count,
                                (select max((w->>'range')::double precision) from jsonb_array_elements(e.weapons_json) w),
                                e.move_speed), ' ' order by e.id)
         from public.combat_units e
         cross join lateral (select pos_x, pos_y from public.combat_units
                              where encounter_id = v_enc and side = 'player' limit 1) p
        where e.encounter_id = v_enc and e.side = 'enemy');
  end if;

  -- (3) THE VISIBLE HIT: one hull_damage per landed hit, WITH its amount, under EVENT logging
  --     (combat_debug_logging is pinned false in setup — the promotion is the thing under test).
  select count(*) into n_hits from public.combat_events
   where encounter_id = v_enc and tick_number = v_t1 and event_type = 'hull_damage'
     and source = 'pirate' and target = 'player' and (payload_json->>'damage')::numeric > 0;
  if n_hits < 3 then
    raise exception 'RSFEEL FAIL: % of % landed pirate hits produced no per-hit hull_damage under EVENT logging (the pre-0314 world: the hitsplat was debug-gated)', n_hits, n_units;
  end if;
  select count(*) into n from public.combat_events
   where encounter_id = v_enc and tick_number = v_t1 and event_type = 'hull_damage'
     and source = 'player' and (payload_json->>'damage')::numeric > 0;
  if n < 1 then
    raise exception 'RSFEEL FAIL: the player''s own landed hit emitted no visible hull_damage with its amount';
  end if;

  -- (2) THE PER-HIT ROLL: six identical guns, one target, one tick — the numbers must differ.
  select count(distinct payload_json->>'damage') into n_distinct from public.combat_events
   where encounter_id = v_enc and tick_number = v_t1 and event_type = 'hull_damage'
     and source = 'pirate' and target = 'player';
  if n_distinct < 2 then
    raise exception 'RSFEEL FAIL: every same-tick hit carries the same damage (% hits, % distinct value(s)) — the tick-shared roll is back and "everytime it deals differently" is dead', n_hits, n_distinct;
  end if;

  -- (1a) THE ARMING: every fired pirate weapon''s clock is now() + ITS OWN 3600s cooldown — exactly.
  select count(*) into n
    from public.combat_units u, jsonb_array_elements(u.weapons_json) w
   where u.encounter_id = v_enc and u.side = 'enemy'
     and nullif(w->>'next_ready_at','') is not null
     and (w->>'next_ready_at')::timestamptz = now() + make_interval(secs => 3600);
  if n <> n_units then
    raise exception 'RSFEEL FAIL: % of % fired pirate weapons carry now()+3600s — a weapon was armed with bare now() and the cooldown never reached the clock', n, n_units;
  end if;

  -- ── THE TICK AFTER THE VOLLEY: the cooldown is unelapsed (frozen now()), so the pirates hold ───
  --    fire. This is the SAME statement as the old "tick 2", read off the volley tick + 1 instead of
  --    off a number that only held while the wave spawned already inside its own range.
  perform pg_temp.ae_tick(v_enc);
  select tick_number into v_t2 from public.combat_encounters where id = v_enc;
  if v_t2 <> v_t1 + 1 then raise exception 'RSFEEL FAIL: the tick after the volley did not advance (% -> %)', v_t1, v_t2; end if;
  -- vacuity: the silence must not be an ended fight or a dead wave.
  select count(*) into n from public.combat_units
   where encounter_id = v_enc and side = 'enemy' and alive_count > 0 and hp_current > 0;
  if n < 3 then raise exception 'RSFEEL FAIL: only % live pirate(s) on the tick after the volley — silence would be vacuous', n; end if;
  if (select status from public.combat_encounters where id = v_enc) <> 'active' then
    raise exception 'RSFEEL FAIL: the encounter is not active on the tick after the volley — silence would be vacuous';
  end if;
  select count(*) into n from public.combat_events
   where encounter_id = v_enc and tick_number = v_t2 and source = 'pirate'
     and event_type in ('missile_salvo', 'hull_damage');
  if n <> 0 then
    raise exception 'RSFEEL FAIL: % pirate fire event(s) on tick % — the pirates fired again through an unelapsed 3600s cooldown (the pre-0314 world: attack speed was fake)', n, v_t2;
  end if;
  -- and the FAIL-OPEN arm: the player''s fallback weapon (cooldown knob 0 in setup) must still fire
  -- every tick — a zero-cooldown weapon must stay ready every tick, byte-equal to the old cadence.
  select count(*) into n from public.combat_events
   where encounter_id = v_enc and tick_number = v_t2 and source = 'player' and event_type = 'missile_salvo';
  if n < 1 then
    raise exception 'RSFEEL FAIL: the player''s zero-cooldown weapon went silent on the tick after the volley — a zero-cooldown weapon must stay ready every tick';
  end if;

  -- ── restore every knob this block owned (captured above; the setup values are 0/0). ────────────
  perform public.set_game_config('enemy_synthetic_cooldown_seconds', to_jsonb(v_cd_before));
  perform public.set_game_config('combat_hit_variance_pct',          to_jsonb(v_hv_before));
  perform public.set_game_config('combat_player_speed_scale',        to_jsonb(v_ps_before));
  perform public.set_game_config('enemy_synthetic_speed_base',           to_jsonb(v_esb_before));
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', to_jsonb(v_esp_before));
  perform public.set_game_config('enemy_attack_base', to_jsonb(v_eab_before));

  raise notice 'DZCOMBAT_PASS_RSFEEL ok: % pirates spawned at danger %, the wave arrived SILENT on its spawn tick (0336 stands it outside its own reach by construction) and CLOSED, and on the volley tick % every landed hit emitted its own hull_damage with a positive amount under EVENT logging (debug pinned dark), % distinct damage values across one volley of identical guns, the player''s own hit visible too; every fired weapon armed now()+3600s exactly, and tick % was pirate-silent (fight active, wave alive) while the zero-cooldown fallback kept firing (% player salvo(s)): attack interval real, every hit its own roll, every hit visible',
    n_units, v_danger, v_t1, n_distinct, v_t2, n;
end $$;

-- ^ RSFEEL's OWN terminator, added at the 0313/0314 merge. Both sides of this conflict appended a
-- do-block that leaned on the single shared terminator below, so a plain union leaves one block
-- unclosed and RSFEEL swallows CLOSURE and NOLIVE into its own body. Not hypothetical: commit
-- 040454e on this same file is "fix MY merge resolution: the REPOMODE block lost its terminator".
-- The selftest cannot see it — it is static greps; only real Postgres can.
--
-- NOTE TO THE NEXT RESOLVER: no comment in this file may contain a literal dollar-quote token. The
-- merge check for this file is arithmetic over those tokens — they must be even, and a depth walk
-- must return to zero — so one sitting in prose desyncs the count while changing nothing Postgres
-- sees, which is worse than either a real error or no check at all. This very comment was written
-- that way on the first attempt and the depth walk caught it.

-- ════════ DZCOMBAT_PASS_CLOSURE (0313, re-premised 0316): CUT RANGES MAKE POSITION MATTER ═══════════
-- The behaviour nobody had ever observed in this game: before 0313, every range (120–245) dwarfed
-- every spawn distance (0–30), so combat_unit_decide_move returned 'hold' on every tick of every
-- real fight and no combat_units row ever changed its pos_x/pos_y. This block stages a fresh
-- TWO-ship group (command + one escort) through the REAL ambush chain at the SEEDED knob/catalog
-- values (no range/ring/speed tuning — the seeds ARE the subject), and drives the REAL tick:
--   • premise, derived not assumed: ring > escort range AND ring > pirate range (if a later retune
--     re-buries the mechanic, this raises honestly);
--   • tick 1: the LEAD hull (dist 0) FIRES — combat still starts instantly — while the escort
--     and the pirate both MOVE (positions change, their gap shrinks) and neither fires;
--   • across ticks: the escort's FIRST salvo lands only on a tick whose recorded PRE-MOVE distance
--     is within its own range, with at least one earlier silent tick (fire strictly AFTER closure),
--     and the pirate's first salvo at the escort obeys ITS OWN shorter range the same way.
--
-- ── 0336 RE-PREMISED AGAIN: THE WAVE NO LONGER STANDS ON THE ANCHOR ──────────────────────────────
-- 0336 moved the enemy wave off the engagement anchor and onto a formation ring (radius
-- spatial_formation_ring_radius, on the bearing to the zone's own city since 0338). THREE of this
-- block's premises were statements about the OLD geometry and every one of them had to be
-- repointed rather than left to rot green:
--   (1) THE RECURRENCE SEED. It used to be the ring radius, which was correct only while the pirate
--       stood on the anchor and the escort on the ring. The wave now stands on a ring of its own —
--       further out than the player's, by its own weapon range plus one — at a different phase, so
--       the escort-pirate gap is a chord between two different radii and is not the ring at all.
--       The seed is now that gap, MEASURED by this block off combat_formation_point — the very leaf
--       the tick composes to place the wave — at the very radius the tick derives: the MEASURED
--       formation extent plus the wave's own range plus one. (An intermediate draft SOLVED for a
--       ring instead and wrote the knob; see the one-authority paragraph below for why that was
--       wrong and why the solve is deleted rather than corrected.)
--   (2) "THE PIRATE MOVED OFF ITS SPAWN ANCHOR" compared the pirate's post-tick position against
--       combat_encounters.engagement_x/y. After 0336 it never spawns there, so that comparison
--       passes for free and proves nothing — a vacuity hole, not merely a wrong message. It now
--       compares against the pirate's OWN spawn point and demands the step be exactly its own
--       frozen move_speed.
--   (3) "THE LEAD (dist 0) FIRES ON TICK 1" is DEAD, and it cannot be rescued. The lead stands on
--       the anchor and every escort stands on the ring, so nothing is at distance 0 from the wave
--       any more. WHICH hull is nearest is no longer a fixed fact either: 0338 makes the wave arrive
--       on the bearing to the zone's own city, so an escort is the near hull when the city lies
--       roughly its way and the LEAD is the near hull when it does not — the escort-to-wave chord
--       ranges over [range + 1, range + 1 + 2*extent] while the lead's gap is the constant radius.
--       Nothing here may assume an ordering between them. THE HONEST REPOINT, and it is the STRONGER
--       statement because it does not need one: after 0336 the opening tick
--       of a fight is SILENT ON BOTH SIDES — the wave spawns outside every gun's reach, both sides
--       CLOSE, and the first shot is fired after an approach. This block now asserts that, over
--       every unit of both sides, and the lead is covered by it like everybody else.
-- ── THE WAVE RADIUS HAS EXACTLY ONE AUTHORITY, AND IT IS THE MEASURED EXTENT ─────────────────────
-- THE BUG THIS PARAGRAPH REPLACES (CI, 02e7d87): `the pirate moved 1.9398 from the slot-0 formation
-- point but its own frozen move_speed is 1`. An earlier draft OWNED spatial_formation_ring_radius:
-- it left the knob alone while the encounter was CREATED (so the escort spawned on the committed
-- ring), then SOLVED for a new ring value, wrote the knob, and predicted the wave's spawn point from
-- the solved value. But 0336 does not read that knob when it places a wave. It measures
--   max(distance from the anchor to each LIVING player unit)
-- and spawns at `that MEASURED extent + the wave's own weapon range + 1`. The extent is the escort's
-- ACTUAL position — the committed ring it was created on — so the block was predicting from a knob
-- that no longer controls the thing it predicts. Two authorities for one radius, silently out of
-- step, and the step assert (correctly) caught it.
-- THE FIX IS A DELETION, not a second correction: the ring solve, the knob write and its restore are
-- GONE, and the block now MEASURES the formation extent exactly the way the spawn arm measures it,
-- then predicts the slot-0 point through combat_formation_point from that. One authority, no pair to
-- keep in step, and NO geometry knob written at all — which is what this block always claimed ("the
-- seeds ARE the subject"). The knob is still READ, for one thing only: pinning that the escort
-- spawned on the committed ring.
-- WHAT THAT COSTS, STATED: the spawn gap is now MEASURED rather than chosen, so the closing tick
-- count is a property of the seeded world instead of of a constructed one. It is not unpinned — it
-- is still asserted twice over (the engine's own recurrence must PREDICT it, the observed first
-- salvo must LAND on it, and the answer must be 2 or 3), which is the same bound 0316's own (f6)
-- self-assert carries. A retune that breaks it fails here, loudly, exactly as before.
-- WHY MEASURED AND NOT THE KNOB, AT THE ENGINE LEVEL — DO NOT REGRESS THIS: 0336 measures the extent
-- precisely so a LONE hull, which is its own lead and therefore stands ON the anchor at extent 0,
-- gets its fight immediately instead of waiting out an approach it has no screen to justify. That
-- was 9-15 SECONDS of silence per wave at live knobs, on endless waves, for the 71 of 77 production
-- ships that are in no fleet at all. This block reads the extent; it must never re-introduce a knob
-- that overrides it.
--
-- ── 0316 RE-PREMISED: THE TICK COUNT IS NOW A PINNED PROPERTY, NOT AN OBSERVATION ────────────────
-- 0316 divided every combat DISTANCE and every combat RATE by 5 together (gun 25→5, ring 30→6,
-- pirate range 18+0.2·D→3.6+0.04·D, pirate speed 3+0.2·D→0.6+0.04·D, and the player's world-travel
-- speed converted into a combat speed by combat_player_speed_scale). Because both the distances and
-- the per-tick steps scaled by the same factor, the geometry is SIMILAR to the old one and every
-- tick count is unchanged: one silent closing tick, first escort salvo on TICK 2.
-- The old wording of this block treated that number as whatever came out. It is now ASSERTED, twice
-- over, and both halves are derived from the rows this very encounter carries:
--   • PREDICTED — the engine's own recurrence (both sides step from the same frozen pre-move
--     snapshot, 0299:802-813, each capped at the remaining distance, 0234:249) run over this
--     encounter's real ring, real weapon range and real frozen move_speeds;
--   • OBSERVED  — the tick the escort's first salvo actually landed on.
-- They must AGREE, and the answer must be tick 2 or 3. A retune that reintroduces the sprawl — a
-- range cut without the ring, or a ring left large against a small gun — pushes the predicted tick
-- past 3 and fails HERE instead of in a playtest, which is exactly what 0313's cut-without-the-ring
-- would have done (25 units to close at ~1.2/tick ≈ 21 ticks ≈ a minute of nothing).
-- Damage knobs are owned in-block (pirate attack tiny so the escort survives the approach; hp_base
-- is already 1000 from setup so the wave survives) and restored after — the geometry knobs are NOT
-- touched, that is the point.
do $$
declare
  r jsonb; n int; i int;
  uC uuid;
  s1 uuid; s2 uuid; gC uuid;
  o_x double precision; o_y double precision;
  v_fleet uuid; v_mv uuid; v_enc uuid;
  mv record; pi record;
  u_cmd uuid; u_esc uuid; u_en uuid;
  v_r_esc double precision; v_r_en double precision; v_ring double precision;
  ex0 double precision; ey0 double precision; ex1 double precision; ey1 double precision;
  nx0 double precision; ny0 double precision; nx1 double precision; ny1 double precision;
  d_pre double precision; d_t1 double precision;
  v_tick int;
  v_esc_fire_tick int := null; v_esc_fire_dist double precision := null;
  v_en_fire_tick int := null; v_en_fire_dist double precision := null;
  n_silent int := 0;
  v_eab_before double precision;
  -- 0316: the predicted-vs-observed closure arithmetic. Every input is READ off this encounter's
  -- own rows (the frozen move_speeds, the frozen weapon range, the seeded ring) — nothing here is a
  -- number typed into the harness.
  v_sp_esc double precision; v_sp_en double precision;
  v_exp_tick int; v_sim double precision;
  -- 0336: the MEASURED formation extent and the spawn geometry derived from it (never from a knob).
  v_r_fb double precision;
  v_extent double precision; v_players int;       -- the extent the spawn arm itself measures
  v_fx double precision; v_fy double precision;   -- the pirate's own spawn point, through the leaf
  v_px double precision; v_py double precision;   -- where that spawn point must be after ONE close
  v_gap0 double precision;                        -- the escort<->pirate gap AT SPAWN (never the ring)
  v_step double precision;                        -- how far the pirate actually moved on tick 1
  v_bd double precision;                          -- the site difficulty both wave formulas take
  v_r_en_pred double precision;                   -- the wave's range, derived BEFORE it exists
  v_sp_en_pred double precision;                  -- ditto its speed; both re-asserted against the row
  v_site_x double precision; v_site_y double precision;  -- (0338) the zone's city: where the wave comes FROM
  v_worst_gap double precision; v_worst_tick int;        -- (0338) the WORST-BEARING approach, knobs only
begin
  -- ── fresh funded player, two ships, ONE group, command designated — 100% real RPCs. ────────────
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.cl.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uC;
  insert into public.player_wallet (player_id, balance) values (uC, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;

  r := pg_temp.call_as(uC, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'CLOSURE FAIL: commission 1: %', r; end if;
  select main_ship_id into s1 from public.main_ship_instances where player_id = uC;
  r := pg_temp.call_as(uC, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'CLOSURE FAIL: commission 2: %', r; end if;
  select main_ship_id into s2 from public.main_ship_instances where player_id = uC and main_ship_id <> s1 limit 1;
  if s2 is null then raise exception 'CLOSURE FAIL: no second ship materialised'; end if;
  r := pg_temp.call_as(uC, 'public.upsert_ship_group(1, ''Closure'')');
  if (r->>'ok')::boolean is not true then raise exception 'CLOSURE FAIL: group: %', r; end if;
  gC := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uC, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s1, gC));
  if (r->>'ok')::boolean is not true then raise exception 'CLOSURE FAIL: assign 1: %', r; end if;
  r := pg_temp.call_as(uC, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s2, gC));
  if (r->>'ok')::boolean is not true then raise exception 'CLOSURE FAIL: assign 2: %', r; end if;
  r := pg_temp.call_as(uC, format('public.set_fleet_command_ship(%L::uuid, true)', s1));
  if (r->>'ok')::boolean is not true then raise exception 'CLOSURE FAIL: command: %', r; end if;

  -- ── damage knobs owned in-block (geometry knobs deliberately NOT touched): the pirate must not
  --    meaningfully hurt the escort during the approach, and 0310's default auto-exit (ON at 30)
  --    must never trigger mid-scenario. Captured and restored below. ───────────────────────────────
  select coalesce(public.cfg_num('enemy_attack_base'), 0) into v_eab_before;
  perform public.set_game_config('enemy_attack_base', '0.001'::jsonb);

  -- ── 0336: the ring knob is READ and NEVER WRITTEN by this block. It is used for exactly one pin —
  --    that the escort spawned on the committed ring — and for nothing else. The wave radius has ONE
  --    authority and it is the MEASURED formation extent (see the header); a second lever here is
  --    what put the two out of step. Every geometry knob — the ring, both weapon ranges, both speeds
  --    — stays seeded: those are the subject, and they are not touched.
  select coalesce(public.cfg_num('spatial_formation_ring_radius'), 30) into v_ring;

  -- ── the REAL ambush, through the STANDING Auto Exit corridor (the AUTOEXIT re-entry idiom: the
  --    zone already stands; a new fleet crossing it gets its own certain pending intercept). ───────
  select l.x, l.y into o_x, o_y
    from public.main_ship_instances s
    join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = uC and f.status = 'present'
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
    join public.locations l on l.id = lp.location_id
   where s.group_id = gC
   limit 1;
  if o_x is null then raise exception 'CLOSURE FAIL: could not resolve the group''s docked origin'; end if;
  r := pg_temp.call_as(uC, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gC, round(o_x), round(o_y + 1000)));
  if (r->>'ok')::boolean is not true then raise exception 'CLOSURE FAIL: go: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if pi is null then raise exception 'CLOSURE FAIL: no pending ambush on the leg (the standing corridor should cover it)'; end if;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id, fleet_id into v_enc, v_fleet from public.combat_encounters
   where player_id = uC and status = 'active';
  if v_enc is null then raise exception 'CLOSURE FAIL: the ambush opened no encounter'; end if;

  select id into u_cmd from public.combat_units where encounter_id = v_enc and main_ship_id = s1;
  select id into u_esc from public.combat_units where encounter_id = v_enc and main_ship_id = s2;
  if u_cmd is null or u_esc is null then raise exception 'CLOSURE FAIL: the 2-ship roster did not seed 2 units'; end if;

  -- the escort's own range, from its OWN frozen weapons_json (fitted or fallback — derived, never
  -- assumed), and the seeded ring it spawned on.
  select max((w->>'range')::double precision) into v_r_esc
    from public.combat_units cu, jsonb_array_elements(cu.weapons_json) w where cu.id = u_esc;
  if v_r_esc is null then raise exception 'CLOSURE FAIL: the escort carries no ranged weapon at all (want the fitted/fallback range)'; end if;
  select public.osn_distance(e.pos_x, e.pos_y, c.pos_x, c.pos_y) into d_pre
    from public.combat_units e, public.combat_units c where e.id = u_esc and c.id = u_cmd;
  -- NULL IS FAILURE, not a pass. combat_units.pos_x/pos_y are NULLABLE (0234:173), so an
  -- unpositioned row makes osn_distance NULL, `abs(NULL - v_ring) > 0.01` NULL, and this whole spawn
  -- pin silently vacuous. Every positional comparison in this block is null-pinned for that reason
  -- (same defect class as the position(x in NULL) probe found on this chain).
  if d_pre is null then
    raise exception 'CLOSURE FAIL: the escort/command distance is NULL — one of them is unpositioned, so the spawn-ring pin would prove nothing';
  end if;
  if abs(d_pre - v_ring) > 0.01 then
    raise exception 'CLOSURE FAIL: escort spawned % from the command ship (want the % ring)', d_pre, v_ring;
  end if;

  -- ── 0336: DERIVE THE WAVE'S SPAWN POINT FROM THE MEASURED EXTENT — THE ENGINE'S OWN INPUT. ─────
  -- The tick places slot k of a wave at combat_formation_point(anchor, EXTENT + THAT WAVE'S OWN
  -- weapon range + 1, k, 0.5), where EXTENT is `max(distance from the anchor to each LIVING player
  -- unit)` measured at spawn — NOT the ring knob. Both terms are readable before the wave exists:
  -- the extent off the rows this encounter already carries, measured with the same expression and
  -- the same predicates the spawn arm uses, and the wave's range from the same
  -- base + difficulty*per_difficulty formula the spawn arm evaluates. So this block MEASURES the
  -- geometry it is about to observe instead of legislating a second one.
  select engagement_x, engagement_y into nx0, ny0 from public.combat_encounters where id = v_enc;
  if nx0 is null or ny0 is null then
    raise exception 'CLOSURE FAIL: the encounter carries no engagement anchor (engagement_x/y is NULL) — the spawn point this assert compares against does not exist';
  end if;
  -- THE EXTENT, measured the way the spawn arm measures it: living player rows, positions present.
  select count(*), coalesce(max(public.osn_distance(nx0, ny0, u.pos_x, u.pos_y)), 0)
    into v_players, v_extent
    from public.combat_units u
   where u.encounter_id = v_enc and u.side = 'player' and u.alive_count > 0
     and u.pos_x is not null and u.pos_y is not null;
  -- NON-VACUITY: with no positioned living player row the coalesce hands back a DEFAULT 0 that looks
  -- exactly like a real measurement of a lone hull standing on the anchor, and every radius below
  -- would be derived from that default instead of from this two-ship formation.
  if v_players <> 2 then
    raise exception 'CLOSURE FAIL: % positioned living player row(s) entering the spawn tick (want the 2 this block staged — lead on the anchor, escort on the ring) — the measured extent below would not be this formation''s', v_players;
  end if;
  select pos_x, pos_y into ex0, ey0 from public.combat_units where id = u_esc;
  select move_speed into v_sp_esc from public.combat_units where id = u_esc;
  -- (0338) the site is read HERE, from the same row the difficulty comes from, because it is now
  -- also where the wave comes FROM. One read, one join, the encounter's own link.
  select l.base_difficulty, l.x, l.y into v_bd, v_site_x, v_site_y
    from public.combat_encounters ce join public.locations l on l.id = ce.location_id
   where ce.id = v_enc;
  v_r_en_pred  := public.cfg_num('enemy_synthetic_range_base') + v_bd * public.cfg_num('enemy_synthetic_range_per_difficulty');
  v_sp_en_pred := public.cfg_num('enemy_synthetic_speed_base') + v_bd * public.cfg_num('enemy_synthetic_speed_per_difficulty');
  if v_site_x is null or v_site_y is null then
    raise exception 'CLOSURE FAIL: the ambushed encounter carries no linked site — the wave has no city to arrive from, the arrival leaf falls back to the plain ring, and the spawn point predicted below would be the fallback rather than the bearing this block is measuring';
  end if;
  if ex0 is null or ey0 is null or v_sp_esc is null or v_bd is null
     or v_r_en_pred is null or v_sp_en_pred is null then
    raise exception 'CLOSURE FAIL: the escort spawn (%,%), its frozen speed (%), the site difficulty (%) or the derived wave range/speed (% / %) is NULL — the wave spawn point this block has to predict cannot be derived',
      ex0, ey0, v_sp_esc, v_bd, v_r_en_pred, v_sp_en_pred;
  end if;
  if v_sp_esc <= 0 or v_sp_en_pred <= 0 then
    raise exception 'CLOSURE FAIL: a closing speed is not positive (escort %, wave %) — one side cannot close at all, so the approach is not a phase of the fight', v_sp_esc, v_sp_en_pred;
  end if;
  -- THE ESCORT IS THE OUTERMOST PLAYER HULL, so it IS the extent. Pinned rather than assumed: if a
  -- future fixture ever puts a hull further out, the wave stands clear of THAT hull instead and the
  -- chord this block measures below is no longer the one the recurrence models.
  if abs(v_extent - d_pre) > 1e-6 then
    raise exception 'CLOSURE FAIL: the measured formation extent is % but the escort stands % from the anchor — some other hull is now the outermost one, so the wave is standing clear of a ship this block is not tracking', v_extent, d_pre;
  end if;
  -- the slot-0 point the MEASURED extent implies, through the SAME leaf the tick composes — and
  -- (0338) at the SAME phase, taken from the one authority for which way a wave arrives from, at the
  -- arguments the tick composes it with. The RADIUS is untouched by 0338; only the bearing moves.
  select fp.x, fp.y into v_fx, v_fy
    from public.combat_formation_point(nx0, ny0, v_extent + v_r_en_pred + 1, 0,
           public.combat_wave_arrival_phase(nx0, ny0, v_site_x, v_site_y, 0)) fp;
  if v_fx is null or v_fy is null then
    raise exception 'CLOSURE FAIL: the wave slot-0 point is NULL — the closure recurrence would have no gap to start from';
  end if;
  -- THE SPAWN GAP IS MEASURED, never chosen: the chord between the escort (radius = the extent, slot
  -- 0, phase 0) and the wave (radius = extent + its own range + 1, slot 0, the arrival phase). Under
  -- 0338 that chord is a function of the BEARING to the city as well as of the knobs, which is why
  -- every bound below is derived from it rather than typed in.
  v_gap0 := public.osn_distance(ex0, ey0, v_fx, v_fy);
  if v_gap0 is null or v_gap0 <= 0 then
    raise exception 'CLOSURE FAIL: the escort-to-wave spawn gap measures % — there is no approach to observe', v_gap0;
  end if;
  perform pg_temp.ae_tick(v_enc);
  select count(*) into n from public.combat_units
   where encounter_id = v_enc and side = 'enemy' and alive_count > 0;
  -- ONE unit, so "the slot-0 point" names exactly one row. combat_units.id is a random uuid, so an
  -- `order by id limit 1` over a MULTI-unit wave would pick an arbitrary slot and every assert that
  -- compares against slot 0 would be a coincidence. Pinned rather than trusted to the danger roll.
  if n <> 1 then
    raise exception 'CLOSURE FAIL: % living pirate(s) after the spawn tick (want exactly 1 — at danger 1 the wave is one unit, and every assert below names the SLOT-0 point, which an id-ordered pick over a larger wave would not find)', n;
  end if;
  select id into u_en from public.combat_units
    where encounter_id = v_enc and side = 'enemy' and alive_count > 0
    order by id limit 1;
  if u_en is null then raise exception 'CLOSURE FAIL: no living pirate after tick 1'; end if;
  select max((w->>'range')::double precision) into v_r_en
    from public.combat_units cu, jsonb_array_elements(cu.weapons_json) w where cu.id = u_en;
  if v_r_en is null then raise exception 'CLOSURE FAIL: the pirate carries no range in its weapons_json'; end if;

  -- THE PREMISE 0313 ESTABLISHES, asserted not assumed — now against the MEASURED spawn gap rather
  -- than the ring, because after 0336 the ring is no longer the distance between these two units.
  if v_gap0 <= v_r_esc or v_gap0 <= v_r_en then
    raise exception 'CLOSURE FAIL premise: the % spawn gap does not exceed both ranges (escort %, pirate %) — the seeded world no longer forces closure and this scenario proves nothing',
      v_gap0, v_r_esc, v_r_en;
  end if;

  -- ── 0316 THE PREDICTED CLOSURE TICK, from the engine's own recurrence over THIS encounter's rows.
  -- Both sides step from the same pre-move snapshot within a tick, so the gap closes by the sum of
  -- the two frozen move_speeds, each capped at what is left; the escort fires on the first tick
  -- whose PRE-MOVE gap is inside its own range. NULL IS FAILURE: combat_units.move_speed is
  -- nullable (0234:175), and a NULL would make the recurrence NULL and every comparison below
  -- vacuously true — the same defect class as the position pins in this block.
  select move_speed into v_sp_esc from public.combat_units where id = u_esc;
  select move_speed into v_sp_en  from public.combat_units where id = u_en;
  if v_sp_esc is null or v_sp_en is null then
    raise exception 'CLOSURE FAIL: a frozen move_speed is NULL (escort %, pirate %) — the closure recurrence would have no speeds in it and the tick-count assert would prove nothing', v_sp_esc, v_sp_en;
  end if;
  if v_sp_esc <= 0 or v_sp_en <= 0 then
    raise exception 'CLOSURE FAIL: a frozen move_speed is not positive (escort %, pirate %) — one side cannot close at all, so the approach is not a phase of the fight', v_sp_esc, v_sp_en;
  end if;
  -- THE DERIVATION THAT PLACED THE SLOT-0 POINT MUST MATCH THE WAVE THAT ACTUALLY ARRIVED. The spawn
  -- point was derived from a PREDICTED range and speed (base + difficulty*per_difficulty, the same
  -- two expressions the spawn arm evaluates) because the wave did not exist yet. If the row
  -- disagrees, every number downstream was derived for a fight that is not the one on the table.
  if abs(v_r_en - v_r_en_pred) > 1e-6 or abs(v_sp_en - v_sp_en_pred) > 1e-6 then
    raise exception 'CLOSURE FAIL: the wave arrived with range % and speed % but this block derived its spawn point for % and % — the synthetic wave formulas moved and the geometry below was chosen for the wrong fight',
      v_r_en, v_sp_en, v_r_en_pred, v_sp_en_pred;
  end if;
  -- THE MODEL'S OWN PREMISE, asserted rather than assumed: the recurrence below applies BOTH sides'
  -- CLOSE step on every tick it runs, which is only correct while BOTH are out of their own range.
  -- The loop condition covers the escort; the pirate is covered only if its range is the shorter of
  -- the two. That ordering is exactly what 0313/0316's (f3) invariant establishes for the seeded
  -- world, and if a retune ever inverts it this recurrence would silently model the wrong fight.
  if v_r_en >= v_r_esc then
    raise exception 'CLOSURE FAIL premise: the pirate range % is not strictly under the escort range % — the closure recurrence assumes the escort out-ranges the pirate (otherwise the pirate KITEs or HOLDs during the approach and the predicted tick models a fight that is not happening)',
      v_r_en, v_r_esc;
  end if;
  v_sim := v_gap0; v_exp_tick := 1;
  while v_sim > v_r_esc and v_exp_tick <= 24 loop
    v_sim := v_sim - least(v_sp_esc, v_sim) - least(v_sp_en, v_sim);
    v_exp_tick := v_exp_tick + 1;
  end loop;
  -- THE BOUND THE SLICE SHIPS, REPOINTED BY 0338 — AND WIDENED HONESTLY RATHER THAN DELETED.
  -- 0336 could type the number 3 here because it stood the wave at a FIXED bearing, half a slot off
  -- the escort ring, so the escort-to-wave chord was a function of the knobs alone. 0338 makes the
  -- bearing the direction of the zone's own city, so that chord is a function of the knobs AND of
  -- where the fleet happens to be relative to the settlement: it ranges over
  --   [ (extent + range + 1) - extent , (extent + range + 1) + extent ] = [ range + 1 , range + 1 + 2*extent ].
  -- The floor is 0336's structural clearance and is UNCHANGED. The ceiling is the cost of the origin,
  -- and it is bounded by the FLEET'S OWN FORMATION EXTENT — never by how far away the city is. A lone
  -- hull is its own lead standing ON the anchor, so its extent is 0 and its approach is identical at
  -- every bearing; that is the 71-of-77-ships case, untouched.
  -- SO THE ANTI-SPRAWL TEETH ARE KEPT AS A KNOB-ONLY PROPERTY: the bound below is computed at the
  -- WORST bearing, from the same knobs and the same recurrence, and it does not move when the fixture
  -- happens to sit in a different direction from its site. A range cut made without the matching ring
  -- and speed cuts still fails HERE rather than in a playtest — it just fails on the worst case the
  -- geometry admits instead of on one arbitrary bearing's chord.
  v_worst_gap := (v_extent + v_r_en_pred + 1) + v_extent;
  v_sim := v_worst_gap; v_worst_tick := 1;
  while v_sim > v_r_esc and v_worst_tick <= 60 loop
    v_sim := v_sim - least(v_sp_esc, v_sim) - least(v_sp_en, v_sim);
    v_worst_tick := v_worst_tick + 1;
  end loop;
  if v_worst_tick > 12 then
    raise exception 'CLOSURE FAIL: at the WORST bearing the seeded world needs % ticks for an escort to reach firing range (worst-case gap %, extent %, wave range %, escort range %, escort speed %, pirate speed %) — the sprawl is back; closure must complete within one or two silent ticks of the structural floor, and a formation this wide turns the wave''s own arrival direction into a minute of a fight in which nobody shoots',
      v_worst_tick, v_worst_gap, v_extent, v_r_en, v_r_esc, v_sp_esc, v_sp_en;
  end if;
  -- and THIS fight, at THIS bearing, must be inside that same bound — a derived comparison, so a
  -- fixture that drifts into an absurd approach still fails even while the knobs stay legal.
  if v_exp_tick > v_worst_tick then
    raise exception 'CLOSURE FAIL: this fight needs % ticks to close but the worst bearing the geometry admits needs only % (spawn gap %, worst-case gap %) — the measured chord is outside the range the formation extent can produce, so the wave is not standing on the radius this block derived',
      v_exp_tick, v_worst_tick, v_gap0, v_worst_gap;
  end if;
  if v_exp_tick < 2 then
    raise exception 'CLOSURE FAIL: the recurrence says the escort is already in range at spawn (gap %, escort range %) — there would be nothing to close and this block would prove nothing',
      v_gap0, v_r_esc;
  end if;
  -- and the approach must not be a TELEPORT either: a single tick that swallows the whole gap puts
  -- the pirate on top of the escort and every unit HOLDs at contact forever after, which is position
  -- ceasing to matter — the very thing this block exists to witness.
  if v_sp_en > v_gap0 / 2 then
    raise exception 'CLOSURE FAIL: the pirate closes % of the % spawn gap in one tick — it arrives on top of its target and the CLOSE/KITE arms run for a single tick before everything HOLDs at contact',
      v_sp_en, v_gap0;
  end if;

  -- ── 0336 REPOINT: TICK 1 IS SILENT ON BOTH SIDES, AND THAT IS THE STRONGER STATEMENT. ───────────
  -- This assert used to read "the command ship (dist 0) FIRED on tick 1 — the fight starts instantly
  -- despite the gap", and it was true only because every pirate spawned ON the engagement anchor,
  -- which is where the lead stands. 0336 deletes that: the wave spawns on a formation ring, so
  -- NOTHING is at distance 0 from anybody any more. 0338 then removed the ordering too: the wave
  -- arrives on the bearing to the zone's own city, so whether the near hull is an escort or the lead
  -- depends on which way the settlement lies. No ring radius rescues the old assert, and no
  -- assertion here may depend on which hull is nearest.
  -- So the property is repointed to what 0336 actually establishes, quantified over EVERY unit of
  -- BOTH sides rather than over one hull: the opening tick of a fight is silent, because the wave
  -- arrives outside every gun's reach and both sides must CLOSE before anyone shoots. The lead is
  -- covered by that like everybody else, and a body that let anything fire across the spawn gap —
  -- either side — fails here.
  select count(*) into n from public.combat_events
    where encounter_id = v_enc and tick_number = 1 and event_type = 'missile_salvo';
  if n <> 0 then
    raise exception 'CLOSURE FAIL: % salvo(s) on tick 1 — the wave is meant to arrive OUTSIDE every gun on the field (escort gap %, escort range %, pirate range %), so the opening tick cannot start instantly any more; something fired across the spawn gap',
      n, v_gap0, v_r_esc, v_r_en;
  end if;

  -- tick 1, the escort and the pirate both MOVED (the first observed movement in a real fight)...
  -- Every operand is null-pinned FIRST. `x is not distinct from NULL` is FALSE for any real number,
  -- so a NULL on either side of these comparisons would skip the raise and pass an assert that
  -- proved nothing — the exact shape that let a moved/unmoved check go vacuous elsewhere on this
  -- chain. Absence of a coordinate is failure here, never evidence of movement.
  select pos_x, pos_y into ex1, ey1 from public.combat_units where id = u_esc;
  if ex0 is null or ey0 is null or ex1 is null or ey1 is null then
    raise exception 'CLOSURE FAIL: the escort has a NULL coordinate (pre %,% / post %,%) — an unpositioned unit cannot prove it moved', ex0, ey0, ex1, ey1;
  end if;
  if ex1 = ex0 and ey1 = ey0 then
    raise exception 'CLOSURE FAIL: the escort did not move on tick 1 (still at %,%) — the CLOSE arm never ran', ex0, ey0;
  end if;
  -- ── 0336 REPOINT: the pirate is measured against ITS OWN SPAWN POINT, never against the anchor.
  -- This used to compare the pirate's post-tick position with combat_encounters.engagement_x/y. That
  -- was only a movement test while the wave spawned ON the anchor; after 0336 it never spawns there,
  -- so the comparison would pass for free on every run — a VACUITY hole, not a wrong message. It now
  -- compares against (v_fx, v_fy), the slot-0 point combat_formation_point itself produces from the
  -- MEASURED formation extent, and it demands not merely the right STEP LENGTH but the exact right
  -- END POINT — spawn point, direction and cap pinned in one assert. IF THE WAVE'S SPAWN RADIUS EVER
  -- STOPS BEING (measured extent + its own range + 1), this is the line that fails, loudly and
  -- diagnosably, because (v_fx, v_fy) will no longer be where the unit started: re-derive the
  -- prediction above against whatever the spawn arm now measures, do not loosen this.
  select pos_x, pos_y into nx1, ny1 from public.combat_units where id = u_en;
  if nx1 is null or ny1 is null then
    raise exception 'CLOSURE FAIL: the pirate has a NULL position after tick 1 — an unpositioned enemy cannot prove it moved off the anchor';
  end if;
  if nx1 = v_fx and ny1 = v_fy then
    raise exception 'CLOSURE FAIL: the pirate did not move off its own ring spawn point (%,%) on tick 1 — the enemy CLOSE arm never ran', v_fx, v_fy;
  end if;
  v_step := public.osn_distance(v_fx, v_fy, nx1, ny1);
  if v_step is null or abs(v_step - least(v_sp_en, v_gap0)) > 1e-6 then
    raise exception 'CLOSURE FAIL: the pirate moved % from the slot-0 formation point (%,%) but its own frozen move_speed is % — either the wave did not spawn where combat_formation_point puts it (re-derive against the MEASURED formation extent, which is the one authority for the wave radius) or the CLOSE step is no longer capped by move_speed',
      v_step, v_fx, v_fy, v_sp_en;
  end if;
  -- …and it stepped along the RIGHT LINE. The pirate closes on the lowest-aggro alive row — the
  -- escort — from the FROZEN pre-move snapshot, so its post-tick point is determined exactly:
  -- spawn + (escort - spawn)/gap * min(speed, gap). Length alone would pass for a step in any
  -- direction; this pins the target choice, the direction and the cap together.
  v_px := v_fx + (ex0 - v_fx) / v_gap0 * least(v_sp_en, v_gap0);
  v_py := v_fy + (ey0 - v_fy) / v_gap0 * least(v_sp_en, v_gap0);
  if abs(nx1 - v_px) > 1e-6 or abs(ny1 - v_py) > 1e-6 then
    raise exception 'CLOSURE FAIL: the pirate stands at (%,%) after tick 1 but closing its own frozen speed % on the escort from the slot-0 point (%,%) lands at (%,%) — it either closed on a different hull than the lowest-aggro escort or it did not start where the measured extent puts it',
      nx1, ny1, v_sp_en, v_fx, v_fy, v_px, v_py;
  end if;
  -- ...toward each other: the gap after tick 1 is smaller than the MEASURED spawn gap.
  select public.osn_distance(e.pos_x, e.pos_y, x.pos_x, x.pos_y) into d_t1
    from public.combat_units e, public.combat_units x where e.id = u_esc and x.id = u_en;
  if d_t1 is null then
    raise exception 'CLOSURE FAIL: the escort-pirate gap after tick 1 is NULL — the closure comparison would be vacuous';
  end if;
  if d_t1 >= v_gap0 then
    raise exception 'CLOSURE FAIL: the escort-pirate gap after tick 1 is % (want < the % spawn gap) — they are not closing', d_t1, v_gap0;
  end if;
  -- ...and NEITHER of them fired (both pre-move distances were the full ring, beyond both ranges).
  select count(*) into n from public.combat_events
    where encounter_id = v_enc and tick_number = 1 and event_type = 'missile_salvo'
      and payload_json->>'unit_id' in (u_esc::text, u_en::text);
  if n <> 0 then
    raise exception 'CLOSURE FAIL: % salvo(s) from the escort/pirate on tick 1 — something fired across a gap larger than its own range', n;
  end if;

  -- ── THE APPROACH: pre-move distance recorded BEFORE each tick; first fire checked against it. ───
  -- (0338) THE OBSERVATION WINDOW IS DERIVED, not typed. The approach is now as long as the bearing
  -- to the city makes it, bounded by v_worst_tick above, so a fixed 12 would turn a legitimate long
  -- approach into a "never fired" failure that says the wrong thing. The window is the worst case the
  -- geometry admits plus a margin for the shorter-ranged pirate to close after the escort stops.
  for i in 2 .. greatest(12, v_worst_tick + 4) loop
    exit when v_esc_fire_tick is not null and v_en_fire_tick is not null;
    select public.osn_distance(e.pos_x, e.pos_y, x.pos_x, x.pos_y) into d_pre
      from public.combat_units e, public.combat_units x where e.id = u_esc and x.id = u_en;
    -- null-pinned like every other distance here: a NULL d_pre would make both `d_pre > v_r_esc`
    -- (the silent-tick counter) and the later `v_esc_fire_dist > v_r_esc + 1e-6` range check NULL,
    -- so the whole approach would be measured against nothing and still report PASS.
    if d_pre is null then
      raise exception 'CLOSURE FAIL: the escort-pirate pre-move distance is NULL on tick % — an unpositioned unit makes every range check in the approach vacuous', i;
    end if;
    perform pg_temp.ae_tick(v_enc);
    select tick_number into v_tick from public.combat_encounters where id = v_enc;
    if v_esc_fire_tick is null then
      select count(*) into n from public.combat_events
        where encounter_id = v_enc and tick_number = v_tick and event_type = 'missile_salvo'
          and payload_json->>'unit_id' = u_esc::text;
      if n > 0 then
        v_esc_fire_tick := v_tick; v_esc_fire_dist := d_pre;
      elsif d_pre > v_r_esc then
        n_silent := n_silent + 1;   -- a closing tick with the escort still legitimately silent
      end if;
    end if;
    if v_en_fire_tick is null then
      select count(*) into n from public.combat_events
        where encounter_id = v_enc and tick_number = v_tick and event_type = 'missile_salvo'
          and payload_json->>'unit_id' = u_en::text;
      if n > 0 then
        v_en_fire_tick := v_tick; v_en_fire_dist := d_pre;
      end if;
    end if;
  end loop;

  if v_esc_fire_tick is null then
    raise exception 'CLOSURE FAIL: the escort NEVER fired within the derived observation window — closure stalled (the recurrence over this encounter''s own rows predicted its first salvo on tick %, and the worst bearing the geometry admits needs %)', v_exp_tick, v_worst_tick;
  end if;
  -- ── 0316: OBSERVED MUST EQUAL PREDICTED. The recurrence above is the arithmetic the scaling
  -- decision was made on; this is where the engine is made to agree with it. A disagreement means
  -- either the tick no longer moves both sides from one frozen snapshot, or the fire gate no longer
  -- reads the PRE-move distance — both silent, both invisible to every static check in the repo.
  if v_esc_fire_tick is distinct from v_exp_tick then
    raise exception 'CLOSURE FAIL: the escort''s first salvo landed on tick % but the engine''s own recurrence over this encounter (spawn gap %, escort range %, escort speed %, pirate speed %) predicts tick % — the movement/fire arithmetic no longer matches the geometry the knobs were chosen for',
      v_esc_fire_tick, v_gap0, v_r_esc, v_sp_esc, v_sp_en, v_exp_tick;
  end if;
  if v_esc_fire_dist > v_r_esc + 1e-6 then
    raise exception 'CLOSURE FAIL: the escort''s first salvo (tick %) left at pre-move distance % — OUTSIDE its own % range; the fire gate is not honouring the cut range',
      v_esc_fire_tick, v_esc_fire_dist, v_r_esc;
  end if;
  -- non-vacuity: the first shot must come strictly AFTER a verified silent closing tick. Tick 1 is
  -- that tick by construction (the premise pinned gap > range, and the tick-1 assert above pinned
  -- zero escort salvos), so the first fire may never be tick 1 itself.
  if v_esc_fire_tick < 2 then
    raise exception 'CLOSURE FAIL: the escort fired on tick % with no silent closing tick before it — the gap never exceeded its range and closure was not exercised (vacuous)', v_esc_fire_tick;
  end if;
  if v_en_fire_tick is null then
    raise exception 'CLOSURE FAIL: the pirate NEVER fired at the escort within the derived observation window — the enemy approach stalled';
  end if;
  if v_en_fire_dist > v_r_en + 1e-6 then
    raise exception 'CLOSURE FAIL: the pirate''s first salvo (tick %) left at pre-move distance % — OUTSIDE its own % range', v_en_fire_tick, v_en_fire_dist, v_r_en;
  end if;
  if v_en_fire_tick < v_esc_fire_tick then
    raise exception 'CLOSURE FAIL: the short-ranged pirate (range %) fired on tick %, BEFORE the longer-ranged escort (range %, tick %) — the out-range order inverted',
      v_r_en, v_en_fire_tick, v_r_esc, v_esc_fire_tick;
  end if;

  -- the ONE knob this block owned. The formation ring is NOT among them any more: it is read for the
  -- escort-spawn pin and never written, so there is nothing to give back and nothing that could leak
  -- into DZCOMBAT_PASS_RANGEINVARIANT below.
  perform public.set_game_config('enemy_attack_base', to_jsonb(v_eab_before));

  raise notice 'DZCOMBAT_PASS_CLOSURE ok: at the SEEDED ranges, speeds and formation ring (escort range %, pirate range %, escort speed %, pirate speed %, committed ring %) — no geometry knob written by this block at all — the wave arrived on combat_formation_point(anchor, the MEASURED formation extent % + its own range + 1, slot 0, the 0338 arrival phase toward the zone''s own city), a MEASURED % from the escort: outside every gun on the field, so tick 1 was SILENT ON BOTH SIDES (0336 moved the wave off the anchor and out past its own reach; nothing stands at distance 0 any more) — and the escort and the pirate then MOVED toward each other (gap % -> % after tick 1, the pirate landing on EXACTLY the point one frozen-speed close on the escort puts it) and held fire until closure: escort''s first salvo tick %, EXACTLY the tick the engine''s own recurrence predicts, at pre-move distance % (<= its range); pirate''s tick % at % (<= its range); % additional silent closing tick(s): position matters in a real fight, and the number of ticks it takes is still pinned',
    v_r_esc, v_r_en, v_sp_esc, v_sp_en, v_ring, v_extent, v_gap0, v_gap0, d_t1, v_esc_fire_tick, round(v_esc_fire_dist::numeric, 2), v_en_fire_tick, round(v_en_fire_dist::numeric, 2), n_silent;
end $$;

-- ════════ DZCOMBAT_PASS_LEAD (0315): EVERY FLEET ENTERING COMBAT HAS A LEAD ══════════════════════════
-- The defect this block reds on: the builder asked main_ship_instances.is_command_ship directly and
-- assumed some member answered true. On production exactly ONE ship in 74 does, and the owner's own
-- fleets have none — because the unified mover command_ship_group_go (the verb an ambush interrupts)
-- never required the flag, only the legacy hunt/expedition senders do. A flagless fleet therefore got
-- NO hull at the engagement anchor (every hull on the 30-unit ring, outside its own 25 gun since
-- 0313, so tick 1 fired nothing) and NO aggro screen (every row priority 0, so the tick's
-- min(aggro_priority) tier admitted the whole fleet).
--
-- THREE FLEETS, all through the REAL ambush chain on the standing Auto Exit corridor:
--   A — THREE hulls, NONE flagged (the owner's Fleet 1 shape). The two capacities are engineered so
--       the rule's SECOND key decides against its THIRD: the id-first hull is the WEAKEST, and the
--       two strongest tie on capacity so the uuid tie-break has to break it. Expected lead = the
--       lower-id hull of the two strong ones. Then one real tick: the lead fires, the escorts (a
--       full ring out, beyond their own range — asserted as a premise, not assumed) cannot, so the
--       fight starting at all is attributable to the lead alone. RED BY CONSTRUCTION on the pre-0315
--       body: there is no hull at distance 0 to find, and no row carries priority 100.
--   B — TWO hulls, the WEAKER and HIGHER-id one designated through the real set_fleet_command_ship,
--       the other boosted so the fallback would pick it on BOTH derived keys. The flag must still
--       win, and the surviving escort must sit on ring slot 0 EXACTLY — that pair is the concrete
--       form of "a fleet with a real command ship is placed exactly as it is today".
--   C — ONE hull, not flagged: it is its own lead, on the anchor, priority 100.
-- Ships' capacities are an OWNED precondition, written directly and BOTH ways at once (hp = max_hp,
-- so every fleet enters at 100% of capacity and 0310's default 30% auto-exit can never fire
-- mid-scenario). No RPC lets a proof choose a hull size — the 0185 hulls that would (650 / 420) are
-- gated behind blueprint_fragment — and the thing under test is which hull the BUILDER elects, which
-- is never written here. is_command_ship is only ever written through its sole real writer.
do $$
declare
  r jsonb; n int;
  uL uuid; uM uuid; uS uuid;
  s1 uuid; s2 uuid; s3 uuid; sa uuid; sb uuid; sc uuid;
  gL uuid; gM uuid; gS uuid;
  o_x double precision; o_y double precision;
  v_mv uuid; v_enc uuid;
  mv record; pi record;
  ax double precision; ay double precision;
  v_ring double precision; v_r_esc double precision;
  u_lead uuid; u_e0 uuid; u_e1 uuid;
  d0 double precision; d1 double precision; d2 double precision;
  px double precision; py double precision;
  cap1 int; cap2 int; cap3 int;
  v_lead_ship uuid; v_pri int; n_cmd int;
  -- 0336: the wave arrives outside every gun on the field, so the opening tick is SILENT and the
  -- fleet's first shot lands on a tick the engine's own recurrence PREDICTS. Everything below is
  -- read off this encounter's own rows or derived from the same expressions the spawn arm evaluates.
  v_extent double precision; v_players int; v_bd double precision;
  v_r_en_pred double precision; v_sp_en_pred double precision;
  v_sp_pl double precision; v_sp_lead double precision;
  v_fx double precision; v_fy double precision;      -- the wave's slot-0 point, through the leaf
  v_gap0 double precision;                            -- the NEAREST hull -> wave, at spawn (0338:
                                                      -- which hull that is depends on the bearing)
  u_near uuid; v_sp_near double precision; v_r_near double precision;
  v_site_x double precision; v_site_y double precision;  -- (0338) the zone's city
  v_worst_gap double precision; v_worst_tick int;        -- (0338) the WORST-BEARING approach
  v_lead_d0 double precision; v_lead_d1 double precision;
  v_lx double precision; v_ly double precision;      -- where ONE close puts the lead
  v_sim double precision; v_exp_tick int; v_obs_tick int; i int; u_en uuid;
begin
  -- ══ ARM A — three hulls, NO command ship anywhere ═══════════════════════════════════════════════
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.ld.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uL;
  insert into public.player_wallet (player_id, balance) values (uL, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;

  r := pg_temp.call_as(uL, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'LEAD FAIL: commission A1: %', r; end if;
  r := pg_temp.call_as(uL, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'LEAD FAIL: commission A2: %', r; end if;
  r := pg_temp.call_as(uL, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'LEAD FAIL: commission A3: %', r; end if;
  select main_ship_id into s1 from public.main_ship_instances where player_id = uL order by main_ship_id offset 0 limit 1;
  select main_ship_id into s2 from public.main_ship_instances where player_id = uL order by main_ship_id offset 1 limit 1;
  select main_ship_id into s3 from public.main_ship_instances where player_id = uL order by main_ship_id offset 2 limit 1;
  if s1 is null or s2 is null or s3 is null then raise exception 'LEAD FAIL: three hulls did not materialise for arm A'; end if;

  -- THE OWNED PRECONDITION: capacities that make the rule's own keys observable. The id-FIRST hull
  -- is the weakest, and the other two TIE — so a green result cannot be produced by the uuid
  -- tie-break alone (it would have named s1), nor by capacity alone (it does not separate s2/s3).
  update public.main_ship_instances set max_hp = 600, hp = 600
   where main_ship_id in (s2, s3);
  select max_hp into cap1 from public.main_ship_instances where main_ship_id = s1;
  select max_hp into cap2 from public.main_ship_instances where main_ship_id = s2;
  select max_hp into cap3 from public.main_ship_instances where main_ship_id = s3;
  if cap1 is null or cap2 is null or cap3 is null then
    raise exception 'LEAD FAIL: a hull has no capacity — the lead rule''s second key has nothing to read';
  end if;
  if cap1 >= cap2 then
    raise exception 'LEAD FAIL premise: the id-first hull carries capacity % against the strong pair''s % — the two capacities do not differ in the direction that makes the max_hp key decide anything', cap1, cap2;
  end if;
  if cap2 <> cap3 then
    raise exception 'LEAD FAIL premise: the strong pair''s capacities are %/% — they must TIE or the uuid tie-break is never exercised', cap2, cap3;
  end if;

  r := pg_temp.call_as(uL, 'public.upsert_ship_group(1, ''Lead A'')');
  if (r->>'ok')::boolean is not true then raise exception 'LEAD FAIL: group A: %', r; end if;
  gL := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uL, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s1, gL));
  if (r->>'ok')::boolean is not true then raise exception 'LEAD FAIL: assign A1: %', r; end if;
  r := pg_temp.call_as(uL, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s2, gL));
  if (r->>'ok')::boolean is not true then raise exception 'LEAD FAIL: assign A2: %', r; end if;
  r := pg_temp.call_as(uL, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s3, gL));
  if (r->>'ok')::boolean is not true then raise exception 'LEAD FAIL: assign A3: %', r; end if;

  -- the scenario's whole point, asserted rather than assumed: NOBODY here is a command ship.
  select count(*) into n_cmd from public.main_ship_instances
   where player_id = uL and is_command_ship;
  if n_cmd <> 0 then
    raise exception 'LEAD FAIL: % flagged ship(s) were provisioned into the flagless fleet — the scenario would prove the head''s own path, not the fallback', n_cmd;
  end if;

  -- the REAL ambush, through the STANDING Auto Exit corridor (the CLOSURE idiom).
  select l.x, l.y into o_x, o_y
    from public.main_ship_instances s
    join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = uL and f.status = 'present'
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
    join public.locations l on l.id = lp.location_id
   where s.group_id = gL
   limit 1;
  if o_x is null then raise exception 'LEAD FAIL: could not resolve arm A''s docked origin'; end if;
  r := pg_temp.call_as(uL, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gL, round(o_x), round(o_y + 1000)));
  if (r->>'ok')::boolean is not true then raise exception 'LEAD FAIL: go A: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if pi is null then raise exception 'LEAD FAIL: no pending ambush on arm A''s leg (the standing corridor should cover it)'; end if;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id into v_enc from public.combat_encounters where player_id = uL and status = 'active';
  if v_enc is null then raise exception 'LEAD FAIL: the ambush opened no encounter for arm A'; end if;

  -- ── the formation, measured from the encounter's OWN anchor ─────────────────────────────────────
  select engagement_x, engagement_y into ax, ay from public.combat_encounters where id = v_enc;
  if ax is null or ay is null then
    raise exception 'LEAD FAIL: the encounter carries no engagement anchor — the anchor this assert measures from does not exist, and every distance below would be NULL and vacuous';
  end if;
  select count(*) into n from public.combat_units where encounter_id = v_enc and side = 'player';
  if n <> 3 then raise exception 'LEAD FAIL: the 3-hull roster seeded % player unit(s)', n; end if;
  select count(*) into n from public.combat_units
   where encounter_id = v_enc and side = 'player' and (pos_x is null or pos_y is null);
  if n <> 0 then
    raise exception 'LEAD FAIL: % player unit(s) have a NULL coordinate — an unpositioned hull cannot prove where it spawned, and every comparison below would pass on nothing', n;
  end if;

  -- ★ EXACTLY ONE hull stands on the engagement anchor. This is the assert that is RED on the
  --   pre-0315 body: with no flagged ship every hull took a ring slot and the count is 0.
  select count(*) into n from public.combat_units cu
   where cu.encounter_id = v_enc and cu.side = 'player'
     and public.osn_distance(cu.pos_x, cu.pos_y, ax, ay) <= 1e-9;
  if n = 0 then
    raise exception 'LEAD FAIL: no hull stands on the engagement anchor — a flagless fleet spawned entirely on the escort ring, which is the defect (the enemy wave spawns AT this point and nothing could reach it)';
  end if;
  if n <> 1 then
    raise exception 'LEAD FAIL: % hull(s) on the engagement anchor (want exactly 1 — a formation has one lead)', n;
  end if;
  select cu.id, cu.main_ship_id into u_lead, v_lead_ship from public.combat_units cu
   where cu.encounter_id = v_enc and cu.side = 'player'
     and public.osn_distance(cu.pos_x, cu.pos_y, ax, ay) <= 1e-9;

  -- ★ it is the hull the RULE names: greatest capacity, then the lowest main_ship_id — s2, never
  --   the id-first s1 (capacity decides) and never s3 (the tie-break decides).
  if v_lead_ship is distinct from s2 then
    raise exception 'LEAD FAIL: the lead is not the hull the rule names — anchored % (want %, the lower-id hull of the two at capacity %; s1 is id-first at capacity % and must lose on capacity, s3 ties on capacity and must lose on id)',
      v_lead_ship, s2, cap2, cap1;
  end if;

  -- ★ the aggro screen names the SAME hull: 100 on the lead, 0 on every other, exactly one 100.
  select aggro_priority into v_pri from public.combat_units where id = u_lead;
  if v_pri is distinct from 100 then
    raise exception 'LEAD FAIL: the anchored hull carries aggro priority % (want 100) — a hull standing on the enemy spawn point with no screen is the worst of both worlds', v_pri;
  end if;
  select count(*) into n from public.combat_units
   where encounter_id = v_enc and side = 'player' and id <> u_lead and aggro_priority is distinct from 0;
  if n <> 0 then
    raise exception 'LEAD FAIL: % escort(s) do not carry aggro priority 0 — the tier filter would not screen the lead', n;
  end if;
  select count(*) into n from public.combat_units
   where encounter_id = v_enc and side = 'player' and aggro_priority = 100;
  if n <> 1 then raise exception 'LEAD FAIL: % player row(s) carry priority 100 (want exactly 1)', n; end if;

  -- ★ the escorts keep the 0234 ring, taking slots 0 and 1 in main_ship_id order (s1 then s3).
  v_ring := coalesce(public.cfg_num('spatial_formation_ring_radius'), 30);
  select id into u_e0 from public.combat_units where encounter_id = v_enc and main_ship_id = s1;
  select id into u_e1 from public.combat_units where encounter_id = v_enc and main_ship_id = s3;
  if u_e0 is null or u_e1 is null then raise exception 'LEAD FAIL: an escort hull was not seeded'; end if;
  select pos_x, pos_y into px, py from public.combat_units where id = u_e0;
  if abs(px - (ax + v_ring * cos(0))) > 1e-6 or abs(py - (ay + v_ring * sin(0))) > 1e-6 then
    raise exception 'LEAD FAIL: the escort ring slot moved — the id-first escort sits at (%,%), want slot 0 at (%,%)',
      px, py, ax + v_ring * cos(0), ay + v_ring * sin(0);
  end if;
  select pos_x, pos_y into px, py from public.combat_units where id = u_e1;
  if abs(px - (ax + v_ring * cos(2 * pi() / 8))) > 1e-6 or abs(py - (ay + v_ring * sin(2 * pi() / 8))) > 1e-6 then
    raise exception 'LEAD FAIL: the escort ring slot moved — the second escort sits at (%,%), want slot 1 at (%,%)',
      px, py, ax + v_ring * cos(2 * pi() / 8), ay + v_ring * sin(2 * pi() / 8);
  end if;

  -- ★ ── 0336 RE-PREMISED: THE FLEET STILL JOINS THE FIGHT, ON THE TICK THE ENGINE PREDICTS ────────
  -- ★ WHAT THIS ASSERTED BEFORE: a salvo on TICK 1 whose unit_id is the LEAD (so a flagless fleet is
  -- ★ not helpless), with ZERO escort salvos on tick 1 as the attribution, premised on
  -- ★ `ring > escort range` so no escort could have opened the fight instead.
  -- ★ EVERY ONE OF THOSE THREE IS A STATEMENT ABOUT THE PRE-0336 WORLD, and two of them are now
  -- ★ inverted rather than merely late:
  -- ★   • "on tick 1" — 0336 stands a wave at (the MEASURED formation extent + its own weapon range
  -- ★     + 1), strictly outside its own reach of every player ship, so the opening tick is SILENT ON
  -- ★     BOTH SIDES by construction. The lead fired on tick 1 only because the wave used to be
  -- ★     inserted ON the anchor, which is where the lead stands — at distance 0.
  -- ★   • "the LEAD fires, an escort cannot" — DEAD, and unrescuable. This fixture is THREE hulls, so
  -- ★     the extent is the escort ring (6), not 0: the lead alone on the anchor is a full RADIUS
  -- ★     from the wave while each escort is a CHORD from it. Measured on the real fixture: the lead
  -- ★     stands 11.0 away and both escorts 5.92. The escorts are nearer and open the fight; the lead
  -- ★     is the LAST hull that can reach, not the first, and there is no ring radius that inverts a
  -- ★     chord and a radius (the same finding CLOSURE's header records).
  -- ★   • the `ring > escort range` premise measured the wrong gap: what decides who can fire is the
  -- ★     ESCORT-TO-WAVE gap, which is not the ring at all once the wave stops spawning on the anchor.
  -- ★ WHAT IS ASSERTED NOW, AND WHY IT IS AT LEAST AS STRONG. The defect this block guards —
  -- ★ A FLAGLESS FLEET OPENS A FIGHT IT CANNOT JOIN — is proven by two things instead of one, and
  -- ★ neither of them is "fires eventually":
  -- ★   (1) THE FLEET JOINS ON EXACTLY THE PREDICTED TICK. The engine's own recurrence (both sides
  -- ★       step from the same frozen pre-move snapshot, each capped at the remaining distance) is
  -- ★       run over this encounter's real frozen speeds, real frozen ranges and the MEASURED extent;
  -- ★       ticks are then driven until a salvo is OBSERVED, and the two must AGREE. A fleet that
  -- ★       cannot join never fires and fails; a fleet whose silence GROWS fires later than the
  -- ★       recurrence says and fails on the same line. Bounded 2..3, the bound 0316 already ships.
  -- ★   (2) THE LEAD IS CLOSING, EXACTLY, FROM THE ANCHOR. On the spawn tick the lead's CLOSE arm
  -- ★       must run and land it on the EXACT point one step of its own frozen move_speed toward the
  -- ★       wave puts it. This is the direct "it can join" evidence and it is STRICTLY MORE than the
  -- ★       old form ever had: the old assert only proved the lead fired BECAUSE it happened to be
  -- ★       standing at distance 0, and it could not have caught a lead that was stranded.
  -- ★ Plus the attribution, repointed to the statement that is now true and load-bearing: the lead is
  -- ★ STRICTLY FURTHER from the wave than every escort — which is the formation working, and is
  -- ★ exactly why electing a lead onto the anchor at aggro 100 behind an aggro-0 screen is the fix.
  select max((w->>'range')::double precision) into v_r_esc
    from public.combat_units cu, jsonb_array_elements(cu.weapons_json) w where cu.id = u_e0;
  if v_r_esc is null then
    raise exception 'LEAD FAIL: the escort carries no ranged weapon at all — the approach premise below has nothing to measure against';
  end if;
  -- THE MEASURED EXTENT — the spawn arm's own input, read with its own expression and predicates.
  select count(*), coalesce(max(public.osn_distance(ax, ay, u.pos_x, u.pos_y)), 0)
    into v_players, v_extent
    from public.combat_units u
   where u.encounter_id = v_enc and u.side = 'player' and u.alive_count > 0
     and u.pos_x is not null and u.pos_y is not null;
  if v_players <> 3 then
    raise exception 'LEAD FAIL: % positioned living player row(s) entering the spawn tick (want the 3 this arm staged — one lead on the anchor, two escorts on the ring) — the measured extent would not be this formation''s', v_players;
  end if;
  if abs(v_extent - v_ring) > 1e-6 then
    raise exception 'LEAD FAIL: the measured formation extent is % but the escorts stand on the % ring — the wave is standing clear of a hull this block is not tracking', v_extent, v_ring;
  end if;
  -- (0338) the site is read from the same row the difficulty comes from: it is now also where the
  -- wave arrives FROM, and a NULL one would silently put this block on the no-direction fallback.
  select l.base_difficulty, l.x, l.y into v_bd, v_site_x, v_site_y
    from public.combat_encounters ce join public.locations l on l.id = ce.location_id
   where ce.id = v_enc;
  if v_site_x is null or v_site_y is null then
    raise exception 'LEAD FAIL: the ambushed encounter carries no linked site — the wave has no city to arrive from and every point predicted below would be the plain-ring fallback rather than the geometry this block measures';
  end if;
  v_r_en_pred  := public.cfg_num('enemy_synthetic_range_base') + v_bd * public.cfg_num('enemy_synthetic_range_per_difficulty');
  v_sp_en_pred := public.cfg_num('enemy_synthetic_speed_base') + v_bd * public.cfg_num('enemy_synthetic_speed_per_difficulty');
  select move_speed into v_sp_pl   from public.combat_units where id = u_e0;
  select move_speed into v_sp_lead from public.combat_units where id = u_lead;
  if v_bd is null or v_r_en_pred is null or v_sp_en_pred is null or v_sp_pl is null or v_sp_lead is null then
    raise exception 'LEAD FAIL: the site difficulty (%), the derived wave range/speed (% / %) or a frozen hull speed (escort %, lead %) is NULL — the recurrence below would be NULL and every comparison vacuously true',
      v_bd, v_r_en_pred, v_sp_en_pred, v_sp_pl, v_sp_lead;
  end if;
  if v_sp_pl <= 0 or v_sp_lead <= 0 or v_sp_en_pred <= 0 then
    raise exception 'LEAD FAIL: a closing speed is not positive (escort %, lead %, wave %) — a side that cannot close cannot join, and the approach is not a phase of the fight', v_sp_pl, v_sp_lead, v_sp_en_pred;
  end if;
  -- the wave's slot-0 point, from the MEASURED extent, through the SAME leaf the tick composes —
  -- and (0338) at the SAME phase, from the one authority for which way a wave arrives from.
  select fp.x, fp.y into v_fx, v_fy
    from public.combat_formation_point(ax, ay, v_extent + v_r_en_pred + 1, 0,
           public.combat_wave_arrival_phase(ax, ay, v_site_x, v_site_y, 0)) fp;
  if v_fx is null or v_fy is null then
    raise exception 'LEAD FAIL: the wave slot-0 point is NULL — the recurrence would have no gap to start from';
  end if;
  -- ── (0338) WHICH HULL IS NEAREST IS NO LONGER A FIXED FACT, SO IT IS MEASURED. ────────────────
  -- 0336 stood the wave half a slot off the escort ring, which made an escort nearer than the lead
  -- BY CONSTRUCTION and let this block say so. 0338 stands it on the bearing to the zone's own city,
  -- so the escort-to-wave chord ranges over [range + 1, range + 1 + 2*extent] while the lead's gap
  -- is the constant radius: an escort is the near hull when the settlement lies roughly its way, and
  -- the LEAD is the near hull when it does not. Both are correct fights. The block therefore DERIVES
  -- the near hull over every living positioned player row instead of asserting an ordering, and
  -- every number after this — the recurrence, the predicted tick, the opener — follows from that one
  -- measurement. This is strictly stronger than the assert it replaces, which could only ever hold
  -- for one arrangement of the world.
  select u.id, public.osn_distance(u.pos_x, u.pos_y, v_fx, v_fy), coalesce(u.move_speed, 0),
         (select max((w->>'range')::double precision) from jsonb_array_elements(u.weapons_json) w)
    into u_near, v_gap0, v_sp_near, v_r_near
    from public.combat_units u
   where u.encounter_id = v_enc and u.side = 'player' and u.alive_count > 0
     and u.pos_x is not null and u.pos_y is not null
   order by public.osn_distance(u.pos_x, u.pos_y, v_fx, v_fy) asc, u.id asc
   limit 1;
  v_lead_d0 := public.osn_distance(ax, ay, v_fx, v_fy);
  if u_near is null or v_gap0 is null or v_lead_d0 is null or v_gap0 <= 0 or v_lead_d0 <= 0
     or v_sp_near is null or v_r_near is null then
    raise exception 'LEAD FAIL: the spawn geometry measures nearest-hull gap % / lead gap % (hull %, speed %, range %) — there is no approach to observe', v_gap0, v_lead_d0, u_near, v_sp_near, v_r_near;
  end if;
  -- THE PROPERTY THAT REPLACES THE ORDERING, and it is the one the election actually owns: THE LEAD
  -- STANDS EXACTLY THE SPAWN RADIUS FROM THE WAVE. That is true at every bearing, and it is only
  -- true if the election put exactly one hull ON the engagement anchor and the wave went out at the
  -- measured extent plus its own range plus one. It pins both facts in one line. The SCREEN itself is
  -- proven where it lives — in aggro, above: exactly one row at 100 and every other at 0.
  if abs(v_lead_d0 - (v_extent + v_r_en_pred + 1)) > 1e-6 then
    raise exception 'LEAD FAIL premise: the lead stands % from the wave but the spawn radius is % (measured extent % + the wave''s own range % + 1) — either the election stopped anchoring exactly one hull on the engagement point, or the wave is no longer going out at the radius 0336 established',
      v_lead_d0, v_extent + v_r_en_pred + 1, v_extent, v_r_en_pred;
  end if;
  -- and NOTHING can fire on the spawn tick: the NEAREST hull is outside its own range (whichever
  -- hull that is), and the wave is outside its own by the structural +1. Derived, so a retune that
  -- buries it raises honestly.
  if v_gap0 <= v_r_near then
    raise exception 'LEAD FAIL premise: the nearest hull''s spawn gap % does not exceed its own range % — a hull could open the fight from its spawn slot and the silent opening tick below would prove nothing',
      v_gap0, v_r_near;
  end if;

  -- ── THE SPAWN TICK: silent across the whole field, and the lead CLOSES off the anchor. ─────────
  perform pg_temp.ae_tick(v_enc);
  select count(*) into n from public.combat_units
   where encounter_id = v_enc and side = 'enemy' and alive_count > 0;
  if n <> 1 then
    raise exception 'LEAD FAIL: % living pirate(s) after the spawn tick (want exactly 1 — at danger 1 the wave is one unit, and the slot-0 point every assert here names is only identifiable while it is)', n;
  end if;
  select id into u_en from public.combat_units
   where encounter_id = v_enc and side = 'enemy' and alive_count > 0 limit 1;
  select count(*) into n from public.combat_events
   where encounter_id = v_enc and tick_number = 1 and event_type = 'missile_salvo';
  if n <> 0 then
    raise exception 'LEAD FAIL: % salvo(s) on the spawn tick — 0336 stands the wave at (measured extent % + its own range % + 1), outside every gun on the field (nearest hull %, its range %), so the opening tick cannot start instantly any more',
      n, v_extent, v_r_en_pred, v_gap0, v_r_esc;
  end if;
  -- (2) THE LEAD IS JOINING, NOT STRANDED — and the point is EXACT, not merely "it moved". A step
  -- length alone would pass for a step in any direction; this pins the target choice, the direction
  -- and the move_speed cap together, off the anchor the election put it on.
  v_lx := ax + (v_fx - ax) / v_lead_d0 * least(v_sp_lead, v_lead_d0);
  v_ly := ay + (v_fy - ay) / v_lead_d0 * least(v_sp_lead, v_lead_d0);
  select pos_x, pos_y into px, py from public.combat_units where id = u_lead;
  if px is null or py is null then
    raise exception 'LEAD FAIL: the lead carries a NULL coordinate after the spawn tick — an unpositioned hull cannot prove it is closing, and a NULL would pass the comparison below while proving nothing';
  end if;
  if abs(px - v_lx) > 1e-6 or abs(py - v_ly) > 1e-6 then
    raise exception 'LEAD FAIL: the lead stands at (%,%) after the spawn tick but one close of its own frozen speed % from the anchor (%,%) toward the wave lands at (%,%) — a flagless fleet still opens a fight its lead cannot join',
      px, py, v_sp_lead, ax, ay, v_lx, v_ly;
  end if;
  select public.osn_distance(px, py, e.pos_x, e.pos_y) into v_lead_d1
    from public.combat_units e where e.id = u_en;
  if v_lead_d1 is null or v_lead_d1 >= v_lead_d0 then
    raise exception 'LEAD FAIL: the lead is % from the wave after the spawn tick against % before it — it is not closing, so the fleet cannot join the fight it opened', v_lead_d1, v_lead_d0;
  end if;

  -- ── (1) THE PREDICTED JOINING TICK, from the engine's own recurrence over THIS encounter's rows.
  -- The near hull is whichever one the MEASUREMENT above named; both sides step from the same frozen
  -- pre-move snapshot, so the gap shrinks by the two frozen speeds together, each capped at what is
  -- left, and a hull fires on the first tick whose PRE-MOVE gap is inside its own range.
  v_sim := v_gap0; v_exp_tick := 1;
  while v_sim > v_r_near and v_exp_tick <= 60 loop
    v_sim := v_sim - least(v_sp_near, v_sim) - least(v_sp_en_pred, v_sim);
    v_exp_tick := v_exp_tick + 1;
  end loop;
  if v_exp_tick < 2 then
    raise exception 'LEAD FAIL: the recurrence says a hull is already in range at spawn (gap %, range %) — there would be nothing to close and the silent opening tick above would be vacuous', v_gap0, v_r_near;
  end if;
  -- THE ANTI-SPRAWL BOUND, REPOINTED BY 0338 THE SAME WAY CLOSURE'S IS. The literal 3 was a
  -- knob-only property only while the wave stood at a fixed bearing. Now the approach also depends on
  -- where the settlement lies, over [range + 1, range + 1 + 2*extent] — bounded by the FLEET'S OWN
  -- FORMATION EXTENT, never by how far away the city is, and identically zero-cost for a lone hull,
  -- which is its own lead on the anchor at extent 0. So the teeth are kept as a knob-only statement:
  -- the bound is computed at the WORST bearing the geometry admits and does not move when a fixture
  -- happens to sit in a different direction from its site.
  v_worst_gap := (v_extent + v_r_en_pred + 1) + v_extent;
  v_sim := v_worst_gap; v_worst_tick := 1;
  while v_sim > v_r_near and v_worst_tick <= 60 loop
    v_sim := v_sim - least(v_sp_near, v_sim) - least(v_sp_en_pred, v_sim);
    v_worst_tick := v_worst_tick + 1;
  end loop;
  if v_worst_tick > 12 then
    raise exception 'LEAD FAIL: at the WORST bearing the fleet needs % ticks to join its own fight (worst-case gap %, extent %, near-hull range %, hull speed %, wave speed %) — the sprawl is back; a flagless fleet must open fire within one or two silent closing ticks of the structural floor, not stall',
      v_worst_tick, v_worst_gap, v_extent, v_r_near, v_sp_near, v_sp_en_pred;
  end if;
  if v_exp_tick > v_worst_tick then
    raise exception 'LEAD FAIL: this fight needs % ticks to join but the worst bearing the geometry admits needs only % (spawn gap %, worst-case gap %) — the measured gap is outside the range the formation extent can produce, so the wave is not standing on the radius this block derived',
      v_exp_tick, v_worst_tick, v_gap0, v_worst_gap;
  end if;
  -- OBSERVED: drive ticks until the fleet actually fires. The exit condition is the OBSERVATION.
  -- (0338) the window is DERIVED for the same reason CLOSURE's is: a legitimate long approach must
  -- not be reported as "the fleet never fired".
  for i in 1 .. greatest(12, v_worst_tick + 4) loop
    exit when v_obs_tick is not null;
    if (select status from public.combat_encounters where id = v_enc) <> 'active' then
      raise exception 'LEAD FAIL: arm A''s encounter left ''active'' during the approach — the scenario is not measuring a live fight';
    end if;
    perform pg_temp.ae_tick(v_enc);
    select tick_number into v_obs_tick from public.combat_events
     where encounter_id = v_enc and event_type = 'missile_salvo' and source = 'player'
     order by tick_number asc limit 1;
  end loop;
  if v_obs_tick is null then
    raise exception 'LEAD FAIL: the fleet never fired within 12 ticks of the spawn (derived window %) — a flagless fleet still opens a fight it cannot join', greatest(12, v_worst_tick + 4);
  end if;
  if v_obs_tick is distinct from v_exp_tick then
    raise exception 'LEAD FAIL: the fleet joined its fight on tick % but the engine''s own recurrence over this encounter''s rows predicts tick % (spawn gap %, near-hull range %, hull speed %, wave speed %) — the movement/fire arithmetic no longer matches the geometry the formation was laid out for',
      v_obs_tick, v_exp_tick, v_gap0, v_r_near, v_sp_near, v_sp_en_pred;
  end if;
  -- and it is the hull this block MEASURED as nearest that opened it — whichever hull that is. Under
  -- 0338 the wave arrives on the bearing to the city, so naming "an escort" here would be asserting
  -- one arrangement of the world; naming the measured hull asserts the engine's own targeting and
  -- fire gate agree with the geometry, at every bearing.
  select count(*) into n from public.combat_events
   where encounter_id = v_enc and tick_number = v_obs_tick and event_type = 'missile_salvo'
     and payload_json->>'unit_id' = u_near::text;
  if n < 1 then
    raise exception 'LEAD FAIL: the tick-% opening salvo did not come from the hull this block measured as nearest to the wave (unit %, gap %, against the lead on the anchor at %) — an opener that is not the near hull means the fire gate is not reading the geometry the formation was laid out for',
      v_obs_tick, u_near, v_gap0, v_lead_d0;
  end if;
  if (select status from public.combat_encounters where id = v_enc) <> 'active' then
    raise exception 'LEAD FAIL: arm A''s encounter left ''active'' by the tick it joined the fight — the scenario is not measuring a live fight';
  end if;

  -- ══ ARM B — a REAL command ship still wins, and the fallback never overrides it ═════════════════
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.ld2.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uM;
  insert into public.player_wallet (player_id, balance) values (uM, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
  r := pg_temp.call_as(uM, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'LEAD FAIL: commission B1: %', r; end if;
  r := pg_temp.call_as(uM, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'LEAD FAIL: commission B2: %', r; end if;
  select main_ship_id into sa from public.main_ship_instances where player_id = uM order by main_ship_id offset 0 limit 1;
  select main_ship_id into sb from public.main_ship_instances where player_id = uM order by main_ship_id offset 1 limit 1;
  if sa is null or sb is null then raise exception 'LEAD FAIL: two hulls did not materialise for arm B'; end if;
  -- the UN-flagged hull is made stronger AND is id-first, so the derivation would name it on BOTH
  -- of its own keys. The flag has to beat both, or it is not first.
  update public.main_ship_instances set max_hp = 600, hp = 600 where main_ship_id = sa;
  r := pg_temp.call_as(uM, 'public.upsert_ship_group(1, ''Lead B'')');
  if (r->>'ok')::boolean is not true then raise exception 'LEAD FAIL: group B: %', r; end if;
  gM := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uM, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sa, gM));
  if (r->>'ok')::boolean is not true then raise exception 'LEAD FAIL: assign B1: %', r; end if;
  r := pg_temp.call_as(uM, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sb, gM));
  if (r->>'ok')::boolean is not true then raise exception 'LEAD FAIL: assign B2: %', r; end if;
  r := pg_temp.call_as(uM, format('public.set_fleet_command_ship(%L::uuid, true)', sb));
  if (r->>'ok')::boolean is not true then raise exception 'LEAD FAIL: designate B: %', r; end if;
  select count(*) into n_cmd from public.main_ship_instances where player_id = uM and is_command_ship;
  if n_cmd <> 1 then raise exception 'LEAD FAIL: arm B carries % command ship(s) (want exactly 1)', n_cmd; end if;

  select l.x, l.y into o_x, o_y
    from public.main_ship_instances s
    join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = uM and f.status = 'present'
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
    join public.locations l on l.id = lp.location_id
   where s.group_id = gM
   limit 1;
  if o_x is null then raise exception 'LEAD FAIL: could not resolve arm B''s docked origin'; end if;
  r := pg_temp.call_as(uM, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gM, round(o_x), round(o_y + 1000)));
  if (r->>'ok')::boolean is not true then raise exception 'LEAD FAIL: go B: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if pi is null then raise exception 'LEAD FAIL: no pending ambush on arm B''s leg'; end if;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id into v_enc from public.combat_encounters where player_id = uM and status = 'active';
  if v_enc is null then raise exception 'LEAD FAIL: the ambush opened no encounter for arm B'; end if;

  select engagement_x, engagement_y into ax, ay from public.combat_encounters where id = v_enc;
  if ax is null or ay is null then
    raise exception 'LEAD FAIL: arm B''s encounter carries no engagement anchor — the anchor this assert measures from does not exist';
  end if;
  select count(*) into n from public.combat_units
   where encounter_id = v_enc and side = 'player' and (pos_x is null or pos_y is null);
  if n <> 0 then
    raise exception 'LEAD FAIL: % arm-B unit(s) have a NULL coordinate — an unpositioned hull cannot prove where it spawned', n;
  end if;
  select public.osn_distance(cu.pos_x, cu.pos_y, ax, ay) into d1
    from public.combat_units cu where cu.encounter_id = v_enc and cu.main_ship_id = sb;
  select public.osn_distance(cu.pos_x, cu.pos_y, ax, ay) into d2
    from public.combat_units cu where cu.encounter_id = v_enc and cu.main_ship_id = sa;
  if d1 is null or d2 is null then
    raise exception 'LEAD FAIL: an arm-B distance is NULL — a hull is missing from its own fleet''s formation';
  end if;
  if d1 > 1e-9 then
    raise exception 'LEAD FAIL: the designated command ship stands % from the anchor (want 0) — the derivation overrode a real command ship, which it must never do', d1;
  end if;
  if abs(d2 - v_ring) > 1e-6 then
    raise exception 'LEAD FAIL: the stronger un-flagged hull stands % from the anchor (want the % ring) — arm B''s placement is not what a flagged fleet gets today', d2, v_ring;
  end if;
  select pos_x, pos_y into px, py from public.combat_units where encounter_id = v_enc and main_ship_id = sa;
  if abs(px - (ax + v_ring * cos(0))) > 1e-6 or abs(py - (ay + v_ring * sin(0))) > 1e-6 then
    raise exception 'LEAD FAIL: the escort ring slot moved on a flagged fleet — the escort sits at (%,%), want slot 0 at (%,%)',
      px, py, ax + v_ring * cos(0), ay + v_ring * sin(0);
  end if;
  select aggro_priority into v_pri from public.combat_units where encounter_id = v_enc and main_ship_id = sb;
  if v_pri is distinct from 100 then
    raise exception 'LEAD FAIL: the designated command ship carries aggro priority % (want 100)', v_pri;
  end if;
  select aggro_priority into v_pri from public.combat_units where encounter_id = v_enc and main_ship_id = sa;
  if v_pri is distinct from 0 then
    raise exception 'LEAD FAIL: the flagged fleet''s escort carries aggro priority % (want 0)', v_pri;
  end if;
  select count(*) into n from public.combat_units
   where encounter_id = v_enc and side = 'player' and aggro_priority = 100;
  if n <> 1 then raise exception 'LEAD FAIL: arm B carries % row(s) at priority 100 (want exactly 1)', n; end if;

  -- ══ ARM C — a single-hull fleet is its own lead ═════════════════════════════════════════════════
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.ld3.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uS;
  insert into public.player_wallet (player_id, balance) values (uS, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
  r := pg_temp.call_as(uS, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'LEAD FAIL: commission C: %', r; end if;
  select main_ship_id into sc from public.main_ship_instances where player_id = uS;
  r := pg_temp.call_as(uS, 'public.upsert_ship_group(1, ''Lead C'')');
  if (r->>'ok')::boolean is not true then raise exception 'LEAD FAIL: group C: %', r; end if;
  gS := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uS, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sc, gS));
  if (r->>'ok')::boolean is not true then raise exception 'LEAD FAIL: assign C: %', r; end if;
  select count(*) into n_cmd from public.main_ship_instances where player_id = uS and is_command_ship;
  if n_cmd <> 0 then raise exception 'LEAD FAIL: arm C''s lone hull is flagged — the single-hull case must be proven WITHOUT a command ship'; end if;

  select l.x, l.y into o_x, o_y
    from public.main_ship_instances s
    join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = uS and f.status = 'present'
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
    join public.locations l on l.id = lp.location_id
   where s.group_id = gS
   limit 1;
  if o_x is null then raise exception 'LEAD FAIL: could not resolve arm C''s docked origin'; end if;
  r := pg_temp.call_as(uS, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gS, round(o_x), round(o_y + 1000)));
  if (r->>'ok')::boolean is not true then raise exception 'LEAD FAIL: go C: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if pi is null then raise exception 'LEAD FAIL: no pending ambush on arm C''s leg'; end if;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id into v_enc from public.combat_encounters where player_id = uS and status = 'active';
  if v_enc is null then raise exception 'LEAD FAIL: the ambush opened no encounter for arm C'; end if;
  select engagement_x, engagement_y into ax, ay from public.combat_encounters where id = v_enc;
  if ax is null or ay is null then
    raise exception 'LEAD FAIL: arm C''s encounter carries no engagement anchor — the anchor this assert measures from does not exist';
  end if;
  select count(*) into n from public.combat_units where encounter_id = v_enc and side = 'player';
  if n <> 1 then raise exception 'LEAD FAIL: the single-hull roster seeded % player unit(s)', n; end if;
  select public.osn_distance(cu.pos_x, cu.pos_y, ax, ay), cu.aggro_priority into d0, v_pri
    from public.combat_units cu where cu.encounter_id = v_enc and cu.side = 'player';
  if d0 is null then
    raise exception 'LEAD FAIL: arm C''s lone hull has a NULL coordinate — an unpositioned hull cannot prove where it spawned';
  end if;
  if d0 > 1e-9 or v_pri is distinct from 100 then
    raise exception 'LEAD FAIL: the single hull did not lead its own fleet — it stands % from the anchor at priority % (want 0 and 100)', d0, v_pri;
  end if;

  raise notice 'DZCOMBAT_PASS_LEAD ok: a THREE-hull fleet with no command ship anywhere elected its lead by the rule — capacity beat the id-first hull (% vs %) and the uuid tie-break broke the equal pair — anchoring exactly ONE hull on the engagement point at priority 100 with both escorts at 0 on ring slots 0 and 1, and the wave then arriving on the bearing to the zone''s own city, whose NEAREST hull this block MEASURES rather than assumes (0338: at some bearings that is an escort on the ring, at others the lead on the anchor) — the lead standing EXACTLY the spawn radius out, the opening tick SILENT across the field, and the fleet joining on EXACTLY the tick the engine''s own recurrence predicts, opened by that measured near hull (ring %, escort range %); a fleet that DOES carry a designated command ship placed that ship on the anchor at 100 even though the fallback would have named the stronger, id-first hull on both of its own keys, with the escort still on ring slot 0 exactly; and a single-hull fleet is its own lead at distance 0, priority 100',
    cap2, cap1, v_ring, v_r_esc;
end $$;

-- ════════ DZCOMBAT_PASS_NOLIVE (0312): NO LIVING SHIPS, NO ORDERS ════════════════════════════════════
-- The owner's bug, verbatim: "when there is no fleet active, meaning if it has no hp, it should not
-- be able to move to map." Staged on the REAL writers end to end:
--   * the DEAD shape is produced by the tick's own terminal leaves — fleet_destroy then
--     mainship_mark_combat_destroyed per member, the defeat branch's exact write order — never by a
--     hand-write of main_ship_instances;
--   * a MERELY DAMAGED ship is produced by mainship_sync_combat_hp(ship, 0) — the tick's own hp
--     writer, in the exact round-to-zero shape (0234:851-852) that makes an ALIVE ship read
--     instance hp 0. If the liveness predicate ever reads hp, THIS scenario goes red: the damaged
--     fleet's order would bounce.
-- Properties, in order:
--   1. an EMPTY group still answers empty_group (the neighbouring state keeps its own code);
--   2. a fleet with a damaged-but-alive ship (instance hp 0!) is still ALLOWED to move;
--   3. with every ship destroyed, go (coordinate), go (port), go_route (leg-1 composition) and dock
--      (flag lit in-txn) are ALL refused with the typed no_living_ships — and the refused volley
--      mints NO fleet and NO movement row. ON THE PRE-0312 BODY THIS IS RED TWICE OVER — a claim
--      that is SOURCE-DERIVED, NOT EMPIRICALLY DEMONSTRATED: a proof can only run the post-fix
--      chain, so nobody has watched the old body fly these wrecks. The derivation, from source:
--      the member-count guard cannot see death (0301:1576-1584 counts rows, and destroyed ships
--      are never deleted), the dead group's fleet is 'destroyed' so step 9 resolves zero and falls
--      into the bootstrap arm, and calculate_group_expedition_stats folds ALL members with no
--      status filter (0166:100-118) — two wrecks still yield a positive team speed — so the old
--      body reaches movement_create: ok=true/movement_started AND a fresh fleet + leg. That chain
--      is what makes the minted-nothing arm below non-vacuous rather than an observation replay.
--   4. RECOVERY IS NEVER BLOCKED on exactly that dead fleet: the brake stays an idempotent ok,
--      the tow berths a wreck, repair revives it in port, the roster re-assign takes it back,
--      and ONE living ship is enough for the group to move again — the un-brick loop, closed.
do $$
declare
  r jsonb;
  uN uuid; gN uuid; gN2 uuid; sN1 uuid; sN2 uuid;
  v_port uuid; v_fleetN uuid;
  n_fleets integer; n_legs integer; n integer;
  v_status text; v_hp integer; v_group_tag uuid; v_max integer;
  v_dock_flag jsonb;
begin
  -- ── a fresh, funded fixture player; the signup trigger mints the base the PRE-0312 bootstrap
  --    would have launched the dead fleet from (without it this block could pass VACUOUSLY:
  --    the old body would refuse no_origin instead of flying, and the red would never show). ────
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.nl.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uN;
  insert into public.player_wallet (player_id, balance) values (uN, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
  if not exists (select 1 from public.bases where player_id = uN) then
    raise exception 'NOLIVE FAIL: the signup trigger minted no base — the pre-0312 bootstrap mint is unreachable here and the block would prove nothing';
  end if;

  -- ── two ships, one team, command designated — 100% real RPCs. ───────────────────────────────────
  r := pg_temp.call_as(uN, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'NOLIVE FAIL: first ship: %', r; end if;
  select main_ship_id into sN1 from public.main_ship_instances where player_id = uN;
  select berth_location_id into v_port from public.main_ship_instances where main_ship_id = sN1;
  if v_port is null then raise exception 'NOLIVE FAIL: the commissioned ship has no berth port'; end if;
  r := pg_temp.call_as(uN, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'NOLIVE FAIL: second ship: %', r; end if;
  select main_ship_id into sN2 from public.main_ship_instances
   where player_id = uN and main_ship_id <> sN1 limit 1;
  if sN2 is null then raise exception 'NOLIVE FAIL: no second ship materialised'; end if;
  r := pg_temp.call_as(uN, 'public.upsert_ship_group(1, ''No Live'')');
  if (r->>'ok')::boolean is not true then raise exception 'NOLIVE FAIL: group: %', r; end if;
  gN := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uN, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sN1, gN));
  if (r->>'ok')::boolean is not true then raise exception 'NOLIVE FAIL: assign 1: %', r; end if;
  r := pg_temp.call_as(uN, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sN2, gN));
  if (r->>'ok')::boolean is not true then raise exception 'NOLIVE FAIL: assign 2: %', r; end if;
  r := pg_temp.call_as(uN, format('public.set_fleet_command_ship(%L::uuid, true)', sN1));
  if (r->>'ok')::boolean is not true then raise exception 'NOLIVE FAIL: command: %', r; end if;

  -- ── 1. the NEIGHBOURING STATE keeps its own code: an EMPTY group answers empty_group. ──────────
  r := pg_temp.call_as(uN, 'public.upsert_ship_group(2, ''No Live Empty'')');
  if (r->>'ok')::boolean is not true then raise exception 'NOLIVE FAIL: empty group create: %', r; end if;
  gN2 := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uN, format('public.command_ship_group_go(%L::uuid, null, 60, 60)', gN2));
  if (r->>'ok')::boolean is not false or (r->>'reason') is distinct from 'empty_group' then
    raise exception 'NOLIVE FAIL: an order on a group with NO ships did not answer empty_group (got %) — the two states must stay distinguishable', r;
  end if;

  -- ── 2. a MERELY DAMAGED ship is never dead. mainship_sync_combat_hp(ship, 0) is the tick's own
  --      writer in its exact round-to-zero shape: the ship is ALIVE (status untouched) while its
  --      instance row reads hp 0. The order must go through — an hp-shaped predicate refuses here.
  perform public.mainship_sync_combat_hp(sN2, 0);
  select status, hp into v_status, v_hp from public.main_ship_instances where main_ship_id = sN2;
  if v_status = 'destroyed' or v_hp <> 0 then
    raise exception 'NOLIVE FAIL: staging drifted — wanted an alive ship at instance hp 0, got status %, hp %', v_status, v_hp;
  end if;
  r := pg_temp.call_as(uN, format('public.command_ship_group_go(%L::uuid, null, 60, 60)', gN));
  if (r->>'ok')::boolean is not true or (r->>'order_outcome') is distinct from 'movement_started' then
    raise exception 'NOLIVE FAIL: a merely damaged ship was treated as dead — the fleet with an alive hp-0 member was refused (%). The liveness predicate must be status, never hp (0234:851-852)', r;
  end if;
  v_fleetN := (r->>'fleet_id')::uuid;
  -- hold the fleet in open space (the brake's own HOLD), so the kill below lands on the defeat
  -- branch's exact from-state: idle + space (0293's widened fleet_destroy arm).
  r := pg_temp.call_as(uN, format('public.command_ship_group_stop(%L::uuid)', gN));
  if (r->>'ok')::boolean is not true or (r->>'stopped')::boolean is not true then
    raise exception 'NOLIVE FAIL: could not hold the fleet in open space: %', r;
  end if;

  -- ── 3. KILL THE FLEET — the defeat branch's own write order (fleet first, then each member). ───
  perform public.fleet_destroy(v_fleetN);
  perform public.mainship_mark_combat_destroyed(sN1);
  perform public.mainship_mark_combat_destroyed(sN2);
  select count(*) into n from public.main_ship_instances
   where player_id = uN and group_id = gN and status = 'destroyed' and hp = 0;
  if n <> 2 then
    raise exception 'NOLIVE FAIL: staging drifted — wanted 2 destroyed members still in the group, got %', n;
  end if;

  -- ── the refused volley writes NOTHING: capture the world before it. ─────────────────────────────
  select count(*) into n_fleets from public.fleets where player_id = uN;
  select count(*) into n_legs from public.fleet_movements where player_id = uN;

  -- go, coordinate target
  r := pg_temp.call_as(uN, format('public.command_ship_group_go(%L::uuid, null, 60, 60)', gN));
  if (r->>'ok')::boolean is not false or (r->>'reason') is distinct from 'no_living_ships' then
    raise exception 'NOLIVE FAIL: a dead fleet was ordered onto the map — go(coordinate) answered % instead of the typed no_living_ships refusal (source-derived expectation: the pre-0312 body reaches movement_create here — 0166''s status-blind fold — a proof can only run the post-fix chain)', r;
  end if;
  -- go, port target (both shapes of the exactly-one-of pair refuse identically)
  r := pg_temp.call_as(uN, format('public.command_ship_group_go(%L::uuid, %L::uuid, null, null)', gN, v_port));
  if (r->>'ok')::boolean is not false or (r->>'reason') is distinct from 'no_living_ships' then
    raise exception 'NOLIVE FAIL: a dead fleet was ordered onto the map — go(port) answered % instead of no_living_ships', r;
  end if;
  -- go_route: leg 1 COMPOSES the mover, so the refusal must ride through with no second guard
  r := pg_temp.call_as(uN, format(
        'public.command_ship_group_go_route(%L::uuid, %L::jsonb, null, 120, 120)',
        gN, jsonb_build_array(jsonb_build_object('x', 60, 'y', 60))::text));
  if (r->>'ok')::boolean is not false or (r->>'reason') is distinct from 'no_living_ships' then
    raise exception 'NOLIVE FAIL: a dead fleet was ordered onto the map — go_route answered % instead of no_living_ships (leg 1 composes the mover; its refusal must propagate)', r;
  end if;
  -- dock: the key comes up ONLY around this probe, and goes back to WHATEVER IT WAS — captured
  -- here, never restored to a hard-coded ambient default (the proofs-never-assert-ambient-defaults
  -- law: a later block appended to this file must inherit the setup's world, not this block's
  -- assumption of it). NOTE what this probe reaches: in PRODUCTION timed_docking_enabled is false
  -- and dock's dark gate answers first, so the deployed dock guard is pre-positioned, not live —
  -- this probe is the only place the guard is exercised until the owner lights that key.
  select value into v_dock_flag from public.game_config where key='timed_docking_enabled';
  if v_dock_flag is null then
    raise exception 'NOLIVE FAIL: timed_docking_enabled is not seeded — cannot capture a value to restore';
  end if;
  update public.game_config set value='true'::jsonb where key='timed_docking_enabled';
  r := pg_temp.call_as(uN, format('public.command_ship_group_dock(%L::uuid)', gN));
  update public.game_config set value = v_dock_flag where key='timed_docking_enabled';
  if (r->>'ok')::boolean is not false or (r->>'reason') is distinct from 'no_living_ships' then
    raise exception 'NOLIVE FAIL: a dead fleet was ordered onto the map — dock answered % instead of no_living_ships (the dock guard must answer before the fleet resolve''s no_fleet)', r;
  end if;
  -- and the volley left no trace
  select count(*) into n from public.fleets where player_id = uN;
  if n <> n_fleets then
    raise exception 'NOLIVE FAIL: a dead fleet''s refused order still minted a fleet or a leg (% fleets, was %) — the pre-0312 bootstrap arm is back', n, n_fleets;
  end if;
  select count(*) into n from public.fleet_movements where player_id = uN;
  if n <> n_legs then
    raise exception 'NOLIVE FAIL: a dead fleet''s refused order still minted a fleet or a leg (% movements, was %)', n, n_legs;
  end if;

  -- ── 4. RECOVERY IS NEVER BLOCKED on exactly this dead fleet. ────────────────────────────────────
  -- the brake stays an idempotent ok (an abort verb must never be gated on liveness)
  r := pg_temp.call_as(uN, format('public.command_ship_group_stop(%L::uuid)', gN));
  if (r->>'ok')::boolean is not true then
    raise exception 'NOLIVE FAIL: recovery is blocked on a dead fleet — the brake was refused: %', r;
  end if;
  -- the tow hauls a wreck in (it leaves the group: the 0216 XOR write)
  r := pg_temp.call_as(uN, format('public.mainship_emergency_tow(%L::uuid)', sN2));
  if (r->>'ok')::boolean is not true then
    raise exception 'NOLIVE FAIL: recovery is blocked on a dead fleet — the tow was refused: %', r;
  end if;
  -- repair revives it at the port (0335: an envelope, so a refusal is a value, never a raise)
  r := pg_temp.call_as(uN, format('public.repair_ship_hull(%L::uuid, null, %L::uuid)', sN2, gen_random_uuid()));
  if (r->>'ok')::boolean is not true or (r->>'status') is distinct from 'home' then
    raise exception 'NOLIVE FAIL: recovery is blocked on a dead fleet — repair did not revive the towed ship: %', r;
  end if;
  select hp, group_id into v_hp, v_group_tag from public.main_ship_instances where main_ship_id = sN2;
  select max_hp into v_max from public.main_ship_instances where main_ship_id = sN2;
  if v_hp is distinct from v_max or v_group_tag is not null then
    raise exception 'NOLIVE FAIL: repair left the ship half-revived (hp % of %, group %)', v_hp, v_max, v_group_tag;
  end if;
  -- the roster takes the revived ship back — into the group still holding a wreck
  r := pg_temp.call_as(uN, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sN2, gN));
  if (r->>'ok')::boolean is not true then
    raise exception 'NOLIVE FAIL: recovery is blocked on a dead fleet — re-assigning the revived ship was refused: %', r;
  end if;
  -- ONE living ship is enough: the group moves again, wreck still aboard — the un-brick, closed.
  r := pg_temp.call_as(uN, format('public.command_ship_group_go(%L::uuid, null, 60, 60)', gN));
  if (r->>'ok')::boolean is not true or (r->>'order_outcome') is distinct from 'movement_started' then
    raise exception 'NOLIVE FAIL: the recovered fleet (1 living ship + 1 wreck) was still refused: % — "all destroyed" must mean ALL', r;
  end if;

  raise notice 'DZCOMBAT_PASS_NOLIVE ok: empty_group kept its own code; a damaged-but-alive ship at instance hp 0 (the tick''s round-to-zero shape) still moved; with every ship destroyed, go(coordinate)/go(port)/go_route/dock all refused with the typed no_living_ships and minted nothing (source-derived, not observed: the pre-0312 body reaches movement_create right here — the member count is death-blind and 0166''s fold has no status filter — a proof can only run the post-fix chain); and on exactly that dead fleet the brake, the tow, the repair and the re-assign all worked — one living ship un-bricked the group';
end $$;

-- ════════ DZCOMBAT_PASS_DEADFIRE (0317): THE DEAD DO NOT SHOOT — AND THE LIVING STILL DO ═════════
-- THE DEFECT: the spatial fire loop iterates a population snapshot frozen before any movement, and
-- re-reads only the TARGET's liveness before applying damage. The ACTOR's is never re-read, so a
-- unit destroyed earlier in the same tick still reached its own iteration and still moved and fired.
--
-- (A) THE MUTUAL KILL — RED BY CONSTRUCTION on the pre-0317 body. One hull, one pirate, both at the
--     engagement anchor (distance 0), each sized FROM THE FIGHT'S OWN NUMBERS to destroy the other
--     in a single shot. On the head both fired and both died: two salvos, two landed hits, two
--     destroyed units. Post-0317 the tick must produce EXACTLY ONE of each — whichever the loop
--     reaches first kills, and the loser takes no turn.
--     WHICH SIDE loses is NOT asserted, because it is NOT determined: v_units is built by jsonb_agg
--     over an unordered scan of combat_units, so the firing order inside a tick is heap order and
--     effectively arbitrary. That is a real finding about the engine, not a gap in this block — and
--     it is why the block asserts the SYMMETRIC property (the loser, whichever side it is, emits no
--     attack event and deals no damage) instead of two side-specific outcomes. A construction that
--     pinned the side would be asserting an ambient implementation detail.
--     VACUITY IS CLOSED THREE WAYS: the loser must have been a live threat (its own weapon, at the
--     real post-tick distance, within its real range, would have destroyed the survivor outright);
--     the survivor must be un-hit (the single landed hit names the LOSER, never the survivor); and
--     the wave size is derived from the same knobs the tick reads, never assumed.
-- (B) THE LIVING STILL ACT, AND THE FREEZE SURVIVES. A two-hull fleet against a six-pirate wave in
--     which exactly one pirate dies. Every pirate still alive after the tick must have fired exactly
--     once — the failure mode where 0317 goes green by silencing everybody. And BOTH hulls must have
--     fired at the SAME pirate, the one the frozen snapshot named, with only ONE of those two shots
--     landing: the second lands on a corpse and deals nothing. That corpse shot is the positive
--     proof that targeting still resolves from the pre-move freeze — 0317 re-reads the ACTOR's own
--     liveness and nothing else, so simultaneity is intact.
-- (C) THE INVARIANT, OVER BOTH FIGHTS AND BOTH SIDES: no unit emits a missile_salvo at a seq later
--     than the unit_destroyed event naming it in the same tick.
-- Staging is the RSFEEL idiom end to end: fresh players, real RPCs only, a real drawn zone, the real
-- movement processor firing a real ambush, and pg_temp.ae_tick as the one cadence driver. Every knob
-- this block depends on is OWNED here and restored afterwards.
do $$
declare
  r jsonb; n int; n2 int; n_units int; n_exp int; n_alive int;
  v_hunt uuid := (select v from dzc where k='v_hunt');
  uA uuid; sA uuid; gA uuid;
  uB uuid; sB1 uuid; sB2 uuid; gB uuid;
  o_x double precision; o_y double precision; v_verts jsonb;
  v_mv uuid; v_encA uuid; v_encB uuid;
  mv record; pi record;
  k_hp double precision; k_atk double precision; k_frng double precision; k_erng double precision;
  k_dvar double precision; k_hvar double precision; k_ecd double precision; k_pcd double precision;
  v_pw double precision; v_pwA double precision; v_php double precision; v_pshield double precision; v_pdef double precision;
  v_bd double precision; v_defb double precision;
  v_danger int; v_hpsc double precision; v_atksc double precision;
  v_tA int; v_tB int;
  v_dead uuid; v_live uuid; v_live_side text; v_live_def double precision;
  v_dead_pow double precision; v_dead_rng double precision; v_would double precision;
  v_live_eff double precision; v_dist double precision;
  v_esc uuid; v_esc_hp double precision; v_tgt uuid; v_hit_unit uuid;
  ax double precision; ay double precision; v_gap double precision;
  -- 0336: a wave arrives at (measured extent + its OWN range + 1), so it is outside its own reach on
  -- the tick it spawns and a mutual exchange CANNOT happen on tick 1 — at any knob value. Both arms
  -- therefore stage equal reach on the two sides, let them close, and OBSERVE the exchange tick.
  k_perd double precision; k_ring double precision;
  k_espd double precision; k_espdd double precision; k_pspd double precision;
  v_reach double precision;            -- the ONE reach both sides carry, owned by this block
  v_pre double precision;              -- the PRE-MOVE distance the engine's own fire gate evaluated
  v_margin double precision;           -- reach - that distance: must be strictly positive, and named
  i int; v_tgt2 uuid;
begin
  -- ── OWN every knob this block reads back, and capture it for restore. ───────────────────────────
  k_hp   := coalesce(public.cfg_num('enemy_hp_base'), 14);
  k_atk  := coalesce(public.cfg_num('enemy_attack_base'), 1.0);
  k_frng := coalesce(public.cfg_num('combat_player_fallback_weapon_range'), 5);
  k_erng := coalesce(public.cfg_num('enemy_synthetic_range_base'), 3.6);
  k_dvar := coalesce(public.cfg_num('combat_damage_variance_pct'), 0);
  k_hvar := coalesce(public.cfg_num('combat_hit_variance_pct'), 0);
  k_ecd  := coalesce(public.cfg_num('enemy_synthetic_cooldown_seconds'), 0);
  k_pcd  := coalesce(public.cfg_num('combat_player_fallback_weapon_cooldown_seconds'), 0);
  k_perd := coalesce(public.cfg_num('enemy_synthetic_range_per_difficulty'), 0.04);
  k_ring := coalesce(public.cfg_num('spatial_formation_ring_radius'), 30);
  k_espd := coalesce(public.cfg_num('enemy_synthetic_speed_base'), 0.6);
  k_espdd:= coalesce(public.cfg_num('enemy_synthetic_speed_per_difficulty'), 0.04);
  k_pspd := coalesce(public.cfg_num('combat_player_speed_scale'), 0.2);
  v_defb := coalesce(public.cfg_num('defense_curve_base'), 100);
  if v_defb <= 0 then raise exception 'DEADFIRE FAIL: defense_curve_base is % — the mitigation arithmetic below has no base', v_defb; end if;
  -- OWN the determinism world rather than inherit it (the proofs-never-assert-ambient-defaults law):
  -- every damage number below is sized to the exact hit, so a live spread would make "one shot kills"
  -- a coin flip, and a live cooldown against txn-frozen now() would silence a unit for the wrong
  -- reason. Restored with the rest at the end of the block.
  perform public.set_game_config('combat_damage_variance_pct',                    '0'::jsonb);
  perform public.set_game_config('combat_hit_variance_pct',                       '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_cooldown_seconds',              '0'::jsonb);
  perform public.set_game_config('combat_player_fallback_weapon_cooldown_seconds', '0'::jsonb);
  -- ── 0336: EQUAL REACH ON BOTH SIDES, OWNED — AND WHY A TICK-1 EXCHANGE IS NOW IMPOSSIBLE ────────
  -- Both arms of this block need the two sides to fire AT EACH OTHER on one tick. Before 0336 that
  -- was free: every enemy was inserted ON the engagement anchor, i.e. on top of the lead, at distance
  -- 0 and inside every seeded range. 0336 spawns a wave at (the MEASURED player-formation extent +
  -- THAT wave's own weapon range + 1), so the wave is outside its OWN reach on the tick it arrives —
  -- BY CONSTRUCTION, at every knob value. Solving the geometry says there is no rescue: with the
  -- escort at radius `ext` and the wave at `ext + r + 1` half a slot round, an exchange at spawn would
  -- need `2*(ext + r + 1)*(ext*(1 - cos(pi/8)) + 1) <= 2*ext + 1`, i.e. a wave radius under ~4.5 when
  -- the radius is at least `ext + 1`. A tick-1 exchange is not tunable, it is gone.
  -- SO BOTH ARMS CLOSE FIRST, and this is what makes the close CONVERGE rather than turn into a
  -- chase: the two sides are given the SAME reach, so neither can out-range the other and neither
  -- takes combat_unit_decide_move's KITE arm. The per-difficulty term is zeroed so that reach is one
  -- constant rather than a value that drifts with whichever site the ambush resolves to — which is
  -- exactly what put arm A on a knife edge (see its own header). All three restored at the end.
  perform public.set_game_config('enemy_synthetic_range_per_difficulty',          '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_range_base',                   '60'::jsonb);
  perform public.set_game_config('combat_player_fallback_weapon_range',          '60'::jsonb);
  v_reach := 60;
  -- ── AND THE APPROACH IS MADE TO OVERSHOOT THE CLEARANCE, NOT LAND ON IT ─────────────────────────
  -- The clearance the wave must cross is exactly 1 (the structural `+ 1`). At the SEEDED knobs and
  -- this site's difficulty of 10 the wave's closing step is 0.6 + 0.04*10 = 1.0 — the SAME 1 — so it
  -- came to rest exactly on its own range edge and every comparison against that edge became a
  -- coin flip on the last ulp of a sqrt. That is not a rounding problem to paper over with an
  -- epsilon; it is a fixture standing on a boundary. The wave is given a step of 2 instead, and made
  -- independent of whichever site the ambush resolves to, so it crosses the clearance in ONE tick and
  -- comes to rest a whole unit INSIDE reach — a margin this block then measures and asserts.
  -- THE HULLS HOLD, for the same reason RSFEEL's does: a hull that moves breaks the symmetry of a
  -- ring, and arm B needs all six pirates equidistant from both hulls so that "everyone fires on one
  -- tick" is a property of the staging rather than of which arc a hull happened to drift toward. A
  -- frozen hull still fires; nothing in either arm is about player movement. All three restored below.
  perform public.set_game_config('enemy_synthetic_speed_base',                    '2'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty',          '0'::jsonb);
  perform public.set_game_config('combat_player_speed_scale',                     '0'::jsonb);

  -- ══ (A) THE MUTUAL KILL ════════════════════════════════════════════════════════════════════════
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.dfa.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uA;
  insert into public.player_wallet (player_id, balance) values (uA, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
  r := pg_temp.call_as(uA, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'DEADFIRE FAIL: commission A: %', r; end if;
  select main_ship_id into sA from public.main_ship_instances where player_id = uA;
  r := pg_temp.call_as(uA, 'public.upsert_ship_group(1, ''Dead Fire A'')');
  if (r->>'ok')::boolean is not true then raise exception 'DEADFIRE FAIL: group A: %', r; end if;
  gA := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uA, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sA, gA));
  if (r->>'ok')::boolean is not true then raise exception 'DEADFIRE FAIL: assign A: %', r; end if;
  r := pg_temp.call_as(uA, format('public.set_fleet_command_ship(%L::uuid, true)', sA));
  if (r->>'ok')::boolean is not true then raise exception 'DEADFIRE FAIL: command A: %', r; end if;
  -- decouple 0310's arm: a fleet that auto-retreats would hold fire (v_offense) and prove nothing.
  r := pg_temp.call_as(uA, format('public.set_group_auto_exit(%L::uuid, false, 30)', gA));
  if (r->>'ok')::boolean is not true then raise exception 'DEADFIRE FAIL: auto-exit off A: %', r; end if;

  select l.x, l.y into o_x, o_y
    from public.main_ship_instances s
    join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = uA and f.status = 'present'
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
    join public.locations l on l.id = lp.location_id
   where s.group_id = gA
   limit 1;
  if o_x is null then raise exception 'DEADFIRE FAIL: could not resolve A''s docked origin'; end if;
  v_verts := jsonb_build_array(
    jsonb_build_array(o_x - 100, o_y + 400),
    jsonb_build_array(o_x + 100, o_y + 400),
    jsonb_build_array(o_x + 100, o_y + 600),
    jsonb_build_array(o_x - 100, o_y + 600));
  r := pg_temp.call_as(uA, format('public.pirate_zone_create(%L, %L::jsonb, %L::uuid)',
                                  'DZC Dead Fire Zone A', v_verts::text, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'DEADFIRE FAIL: zone A: %', r; end if;
  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gA, round(o_x), round(o_y + 1000)));
  if (r->>'ok')::boolean is not true then raise exception 'DEADFIRE FAIL: go A: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if pi is null then raise exception 'DEADFIRE FAIL: no pending ambush on A''s leg (risk knobs are 1.0)'; end if;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id into v_encA from public.combat_encounters where player_id = uA and status = 'active';
  if v_encA is null then raise exception 'DEADFIRE FAIL: the ambush opened no encounter for A'; end if;

  -- ── 0336 RE-PREMISED: THE WAVE NO LONGER SPAWNS ON THE HULL, SO THE KILL IS NOT ON TICK 1 ───────
  -- WHAT THIS SAID, AND WHY IT WAS THE WHOLE BUG: "the ONE hull is its own lead (0315), so it stands
  -- ON the anchor and the wave spawns ON it too: distance 0, inside every seeded range, and the fight
  -- opens on tick 1." Every clause of that was true before 0336 and the first two are still true —
  -- but the wave no longer spawns on the anchor. A lone hull IS its own lead, so the MEASURED
  -- formation extent is 0, and the wave therefore lands at exactly (its own range + 1): one unit
  -- outside its own reach, which is the structural clearance 0336 exists to establish.
  -- WHAT THAT DID TO THIS FIXTURE, at the seeded knobs and this site's difficulty of 10:
  --   • the wave spawned 5.0 away with its own range 4.0 — so it could NEVER fire, and the "mutual"
  --     kill was not mutual: the hull shot it, and its silence proved nothing about 0317's liveness
  --     guard because it was simply out of range. The block was VACUOUS, and the non-vacuity premise
  --     that failed in CI was telling the truth about it.
  --   • it then closed exactly its own speed (0.6 + 0.04*10 = 1.0) into exactly its own range
  --     (3.6 + 0.04*10 = 4.0), because at D = 10 the closing step equals the +1 clearance EXACTLY.
  --     The premise compared that post-tick distance against 4 and the sqrt landed one ulp over:
  --     `4.00000000000001 > 4`. A zero-margin float comparison, and which side of it the run fell on
  --     also depended on a uuid ordering (the wave moves only if it is processed before the hull).
  -- THE FIX IS THE FIXTURE, NOT AN EPSILON. The two sides are given equal reach (owned above), so
  -- neither can fire at spawn and neither kites; they CLOSE together and enter reach on the same
  -- tick, and that tick is OBSERVED. The margin they enter with is measured and asserted STRICTLY
  -- positive, so a future retune that lands on the boundary again fails with the number in the
  -- message instead of on a coin flip.
  -- AND THE PREMISE NOW READS THE DISTANCE THE ENGINE READ. The fire gate evaluates the FROZEN
  -- PRE-MOVE distance; this block measured the POST-tick one. Before 0336 both were 0 and the
  -- difference was invisible. It is captured before the tick now, which is a second, independent
  -- correctness fix rather than a restaging detail.
  select count(*) into n from public.combat_units where encounter_id = v_encA and side = 'player';
  if n <> 1 then raise exception 'DEADFIRE FAIL: A fielded % player unit(s) (the mutual kill needs exactly 1)', n; end if;
  select hp_current, coalesce(shield_current, 0), coalesce(defense_snapshot, 0)
    into v_php, v_pshield, v_pdef
    from public.combat_units where encounter_id = v_encA and side = 'player';
  select max((w->>'power')::double precision) into v_pw
    from public.combat_units u, jsonb_array_elements(u.weapons_json) w
   where u.encounter_id = v_encA and u.side = 'player';
  if v_php is null or v_php <= 0 or v_pw is null or v_pw <= 0 then
    raise exception 'DEADFIRE FAIL: A''s hull carries hp % / weapon power % — the one-shot sizing has nothing to size against', v_php, v_pw;
  end if;
  select l.base_difficulty into v_bd
    from public.combat_encounters ce join public.locations l on l.id = ce.location_id
   where ce.id = v_encA;
  if v_bd is null or v_bd <= 0 then raise exception 'DEADFIRE FAIL: base_difficulty %', v_bd; end if;

  -- danger derived from the same inputs the tick reads (never assumed): a fresh encounter is danger
  -- 1, so the wave is exactly ONE pirate — which is what makes the kill mutual rather than a volley.
  v_danger := 1 + (select waves_cleared from public.combat_encounters where id = v_encA)
              + floor(extract(epoch from (now() - (select started_at from public.combat_encounters where id = v_encA)))
                      / coalesce(public.cfg_num('danger_time_divisor_seconds'), 180))::int;
  n_exp := least(coalesce(public.cfg_num('enemy_synthetic_max_units'), 6)::int, greatest(1, v_danger));
  if n_exp <> 1 then
    raise exception 'DEADFIRE FAIL: staging derives % pirate(s) for the mutual kill (want exactly 1)', n_exp;
  end if;
  -- 0341 RE-POINTED, NOT WIDENED. These two lines exist to invert the engine's own sizing so the
  -- staged base yields a chosen PER-UNIT hp/power. The engine used to divide a danger-scaled WAVE
  -- total by the body count; it now scales the PIRATE by the danger one body carries and multiplies
  -- up, so the inverse is (1 + scale) * bodies instead of (1 + danger * scale). At danger 1 with one
  -- body the two are identical, so this block's numbers are unchanged — the edit keeps them that way
  -- for the blocks below where they are not.
  v_hpsc  := (1 + coalesce(public.cfg_num('enemy_hp_danger_scale'), 0.6)) * n_exp;
  v_atksc := (1 + coalesce(public.cfg_num('enemy_attack_danger_scale'), 0.25)) * n_exp;
  -- the pirate dies to ONE player shot: half the player's own weapon power, spread over one unit.
  perform public.set_game_config('enemy_hp_base',
    to_jsonb(round(((0.5 * v_pw) / (v_bd * v_hpsc))::numeric, 9)));
  -- and the hull dies to ONE pirate shot: three times its hull-plus-shield, de-mitigated.
  perform public.set_game_config('enemy_attack_base',
    to_jsonb(round((((3.0 * (v_php + v_pshield)) * ((v_defb + v_pdef) / v_defb)) / (v_bd * v_atksc))::numeric, 9)));

  -- ── THE SPAWN TICK: the wave arrives, silent, and outside the reach of both sides. ─────────────
  perform pg_temp.ae_tick(v_encA);
  select count(*) into n from public.combat_events
   where encounter_id = v_encA and tick_number = 1 and event_type = 'missile_salvo';
  if n <> 0 then
    raise exception 'DEADFIRE FAIL: % salvo(s) on the spawn tick — with both sides at the owned reach % the wave arrives at (extent + its own range + 1), outside BOTH, so nothing can fire on the tick it appears', n, v_reach;
  end if;
  -- ── CLOSE UNTIL BOTH SIDES ARE IN REACH, then take THAT tick as the mutual-kill tick. The exit
  --    condition is the OBSERVATION (a salvo), never a tick count; the PRE-MOVE distance the fire
  --    gate evaluated is captured on each pass, so the premise below reads what the engine read.
  for i in 1 .. 12 loop
    exit when v_tA is not null;
    if (select status from public.combat_encounters where id = v_encA) <> 'active' then
      raise exception 'DEADFIRE FAIL: A''s encounter left ''active'' during the approach — the mutual kill never happened and this block observed nothing';
    end if;
    select public.osn_distance(a.pos_x, a.pos_y, b.pos_x, b.pos_y) into v_pre
      from public.combat_units a, public.combat_units b
     where a.encounter_id = v_encA and a.side = 'player'
       and b.encounter_id = v_encA and b.side = 'enemy';
    if v_pre is null then
      raise exception 'DEADFIRE FAIL: the pre-move distance between the two units is NULL on the approach — an unpositioned fight cannot prove either side was in reach';
    end if;
    perform pg_temp.ae_tick(v_encA);
    select tick_number into v_tA from public.combat_encounters ce
     where ce.id = v_encA
       and exists (select 1 from public.combat_events ev
                    where ev.encounter_id = v_encA and ev.tick_number = ce.tick_number
                      and ev.event_type = 'missile_salvo');
  end loop;
  if v_tA is null then
    raise exception 'DEADFIRE FAIL: neither side fired within 12 ticks of the spawn — at the owned reach % the two sides never closed into it, so there is no mutual-kill tick to measure', v_reach;
  end if;
  -- NON-VACUITY: the spawn tick is pinned silent above, so the exchange must be strictly later.
  if v_tA < 2 then
    raise exception 'DEADFIRE FAIL: the exchange is recorded on tick % — the spawn tick was pinned silent, so this block observed no approach at all', v_tA;
  end if;
  -- THE MARGIN, NAMED. v_pre is the FROZEN PRE-MOVE distance of the tick that fired — the very
  -- quantity combat_unit_decide_move and the fire gate evaluated. Both sides carry v_reach, so both
  -- were inside it by exactly this much. A future retune that lands the approach ON the boundary
  -- fails HERE, with the number, instead of on the last ulp of a sqrt.
  v_margin := v_reach - v_pre;
  if v_margin <= 0 then
    raise exception 'DEADFIRE FAIL: the exchange tick opened at a pre-move distance of % against a reach of % — margin %, so the mutual kill sits exactly on the range boundary and which side of it a run falls on is a rounding accident, not a property',
      v_pre, v_reach, v_margin;
  end if;
  select count(*) into n_units from public.combat_units where encounter_id = v_encA and side = 'enemy';
  if n_units <> 1 then
    raise exception 'DEADFIRE FAIL: % pirate unit(s) spawned into the mutual kill (want the danger-derived 1)', n_units;
  end if;

  -- THE THREE COUNTS. On the pre-0317 body every one of them is 2.
  select count(*) into n from public.combat_events
   where encounter_id = v_encA and tick_number = v_tA and event_type = 'missile_salvo';
  if n <> 1 then
    raise exception 'DEADFIRE FAIL: % attack event(s) in the mutual-kill tick (want exactly 1) — a unit that was destroyed earlier in the tick still fired', n;
  end if;
  select count(*) into n from public.combat_events
   where encounter_id = v_encA and tick_number = v_tA and event_type = 'hull_damage';
  if n <> 1 then
    raise exception 'DEADFIRE FAIL: % landed hit(s) in the mutual-kill tick (want exactly 1) — the dead unit dealt damage after its own destruction', n;
  end if;
  select count(*) into n from public.combat_events
   where encounter_id = v_encA and tick_number = v_tA and event_type = 'unit_destroyed';
  if n <> 1 then
    raise exception 'DEADFIRE FAIL: % unit(s) destroyed in the mutual-kill tick (want exactly 1) — both units died, so the loser still fired from beyond the grave', n;
  end if;

  select (payload_json->>'unit_id')::uuid into v_dead from public.combat_events
   where encounter_id = v_encA and tick_number = v_tA and event_type = 'unit_destroyed';
  select (payload_json->>'unit_id')::uuid into v_live from public.combat_events
   where encounter_id = v_encA and tick_number = v_tA and event_type = 'missile_salvo';
  select (payload_json->>'unit_id')::uuid into v_hit_unit from public.combat_events
   where encounter_id = v_encA and tick_number = v_tA and event_type = 'hull_damage';
  if v_dead is null or v_live is null or v_hit_unit is null then
    raise exception 'DEADFIRE FAIL: the tick did not name the dead / the firer / the hit unit (% / % / %) — absence is failure, not a pass', v_dead, v_live, v_hit_unit;
  end if;
  if v_dead = v_live then
    raise exception 'DEADFIRE FAIL: the destroyed unit is the one that fired — a unit that was destroyed earlier in the tick still fired';
  end if;
  if v_hit_unit <> v_dead then
    raise exception 'DEADFIRE FAIL: the survivor took damage from a unit that was already destroyed (the one landed hit names %, not the loser %)', v_hit_unit, v_dead;
  end if;
  select alive_count into n from public.combat_units where id = v_dead;
  if n is null or n <> 0 then raise exception 'DEADFIRE FAIL: the unit the tick reported destroyed still has alive_count %', n; end if;
  select alive_count into n from public.combat_units where id = v_live;
  if n is null or n <= 0 then raise exception 'DEADFIRE FAIL: the firer did not survive its own kill (alive_count %)', n; end if;

  -- NON-VACUITY: the loser was a live threat. Its own weapon, at the real distance between the two
  -- units and inside its own real range, would have DESTROYED the survivor outright had it fired.
  select side, coalesce(defense_snapshot, 0), hp_current + coalesce(shield_current, 0)
    into v_live_side, v_live_def, v_live_eff
    from public.combat_units where id = v_live;
  select max((w->>'power')::double precision), max((w->>'range')::double precision)
    into v_dead_pow, v_dead_rng
    from public.combat_units u, jsonb_array_elements(u.weapons_json) w
   where u.id = v_dead;
  -- THE DISTANCE THE ENGINE ITSELF EVALUATED. The fire gate reads the FROZEN PRE-MOVE distance, and
  -- v_pre is that quantity, captured before the tick that fired. Reading the POST-tick distance here
  -- (what this line used to do) compares against a number the fire decision never saw — invisible
  -- while the wave spawned at distance 0 and nothing moved, wrong the moment 0336 made units close.
  v_dist := v_pre;
  if v_dead_pow is null or v_dead_rng is null or v_dist is null or v_live_eff is null then
    raise exception 'DEADFIRE FAIL: the loser''s weapon (% power / % range), the distance (%) or the survivor''s pool (%) is NULL — the loser could not have killed its target anyway would be unprovable', v_dead_pow, v_dead_rng, v_dist, v_live_eff;
  end if;
  if v_dist > v_dead_rng then
    raise exception 'DEADFIRE FAIL: the loser was out of range (% > %) at the PRE-MOVE distance the fire gate evaluated — the loser could not have killed its target anyway, so its silence proves nothing', v_dist, v_dead_rng;
  end if;
  v_would := v_dead_pow * (case when v_live_side = 'player' then v_defb / (v_defb + v_live_def) else 1 end);
  if v_would < v_live_eff then
    raise exception 'DEADFIRE FAIL: the loser could not have killed its target anyway (% damage vs % hull+shield) — the mutual kill was not mutual and this block proves nothing', v_would, v_live_eff;
  end if;

  v_pwA := v_pw;   -- A's own weapon power, kept for the notice (B re-uses v_pw for its own fleet)

  -- ══ (B) THE LIVING STILL ACT, AND THE FREEZE SURVIVES ══════════════════════════════════════════
  -- Two hulls, six pirates. The equal reach both sides carry is owned ONCE at the top of this block
  -- (one authority, not a second copy here), and this arm adds the one thing it needs on top: a ring
  -- of ZERO, so both hulls stand ON the anchor and the MEASURED formation extent is 0.
  -- WHY THE RING, AND WHY IT IS NOT COSMETIC: 0336 lays the wave out at (extent + its own range + 1)
  -- and the escort sits on the ring, so with a ring the escort-to-wave gap is a CHORD between two
  -- different radii — bigger than the wave's own reach at every radius (the inequality in this
  -- block's header has no solution), and different for each hull, so "everyone fires on the same
  -- tick" would be false by construction. At extent 0 every hull is exactly (reach + 1) from every
  -- pirate, all six gaps are equal, and the whole field enters reach together. Restored at the end.
  perform public.set_game_config('spatial_formation_ring_radius', '0'::jsonb);

  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.dfb.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uB;
  insert into public.player_wallet (player_id, balance) values (uB, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
  r := pg_temp.call_as(uB, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'DEADFIRE FAIL: commission B1: %', r; end if;
  select main_ship_id into sB1 from public.main_ship_instances where player_id = uB;
  r := pg_temp.call_as(uB, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'DEADFIRE FAIL: commission B2: %', r; end if;
  select main_ship_id into sB2 from public.main_ship_instances
   where player_id = uB and main_ship_id <> sB1 limit 1;
  if sB2 is null then raise exception 'DEADFIRE FAIL: no second hull materialised for B'; end if;
  r := pg_temp.call_as(uB, 'public.upsert_ship_group(1, ''Dead Fire B'')');
  if (r->>'ok')::boolean is not true then raise exception 'DEADFIRE FAIL: group B: %', r; end if;
  gB := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uB, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sB1, gB));
  if (r->>'ok')::boolean is not true then raise exception 'DEADFIRE FAIL: assign B1: %', r; end if;
  r := pg_temp.call_as(uB, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sB2, gB));
  if (r->>'ok')::boolean is not true then raise exception 'DEADFIRE FAIL: assign B2: %', r; end if;
  r := pg_temp.call_as(uB, format('public.set_fleet_command_ship(%L::uuid, true)', sB1));
  if (r->>'ok')::boolean is not true then raise exception 'DEADFIRE FAIL: command B: %', r; end if;
  r := pg_temp.call_as(uB, format('public.set_group_auto_exit(%L::uuid, false, 30)', gB));
  if (r->>'ok')::boolean is not true then raise exception 'DEADFIRE FAIL: auto-exit off B: %', r; end if;

  select l.x, l.y into o_x, o_y
    from public.main_ship_instances s
    join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = uB and f.status = 'present'
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
    join public.locations l on l.id = lp.location_id
   where s.group_id = gB
   limit 1;
  if o_x is null then raise exception 'DEADFIRE FAIL: could not resolve B''s docked origin'; end if;
  v_verts := jsonb_build_array(
    jsonb_build_array(o_x - 100, o_y + 400),
    jsonb_build_array(o_x + 100, o_y + 400),
    jsonb_build_array(o_x + 100, o_y + 600),
    jsonb_build_array(o_x - 100, o_y + 600));
  r := pg_temp.call_as(uB, format('public.pirate_zone_create(%L, %L::jsonb, %L::uuid)',
                                  'DZC Dead Fire Zone B', v_verts::text, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'DEADFIRE FAIL: zone B: %', r; end if;
  r := pg_temp.call_as(uB, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gB, round(o_x), round(o_y + 1000)));
  if (r->>'ok')::boolean is not true then raise exception 'DEADFIRE FAIL: go B: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if pi is null then raise exception 'DEADFIRE FAIL: no pending ambush on B''s leg'; end if;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id into v_encB from public.combat_encounters where player_id = uB and status = 'active';
  if v_encB is null then raise exception 'DEADFIRE FAIL: the ambush opened no encounter for B'; end if;

  select count(*) into n from public.combat_units where encounter_id = v_encB and side = 'player';
  if n <> 2 then raise exception 'DEADFIRE FAIL: B fielded % player unit(s) (this scenario needs exactly 2)', n; end if;
  select count(*) into n from public.combat_units
   where encounter_id = v_encB and side = 'player' and aggro_priority = 0;
  if n <> 1 then
    raise exception 'DEADFIRE FAIL: B carries % screened hull(s) at aggro 0 (want exactly 1, so the whole volley lands on one known escort)', n;
  end if;
  select id, hp_current + coalesce(shield_current, 0) into v_esc, v_esc_hp
    from public.combat_units where encounter_id = v_encB and side = 'player' and aggro_priority = 0;
  if v_esc is null or v_esc_hp is null or v_esc_hp <= 0 then
    raise exception 'DEADFIRE FAIL: B has no screened escort to absorb the volley (% / %)', v_esc, v_esc_hp;
  end if;
  -- GEOMETRY PREMISE, REPOINTED (0336). It used to read: "the pirates spawn ON the engagement anchor
  -- and the escort spawns on the formation ring, so the ring IS the gap both guns must cover for tick
  -- 1 to be a full exchange", and it measured the escort's distance from the ANCHOR against 60. Both
  -- halves died with 0336: the pirates do not spawn on the anchor, so the ring is not the gap; and
  -- the gap that matters is hull-to-WAVE, not hull-to-anchor. What this arm needs instead is that
  -- every hull stands at the SAME distance from the wave — which the owned ring of 0 establishes —
  -- so that the whole field enters reach on one tick. NULL-pinned (the 0313 law): a missing
  -- coordinate would make this premise pass while proving nothing.
  select engagement_x, engagement_y into ax, ay from public.combat_encounters where id = v_encB;
  select max(public.osn_distance(ax, ay, u.pos_x, u.pos_y)) into v_gap
    from public.combat_units u
   where u.encounter_id = v_encB and u.side = 'player' and u.alive_count > 0
     and u.pos_x is not null and u.pos_y is not null;
  if ax is null or ay is null or v_gap is null then
    raise exception 'DEADFIRE FAIL: B''s anchor (%,%) or its measured formation extent (%) is NULL — an unpositioned fight cannot prove everyone was in reach', ax, ay, v_gap;
  end if;
  if v_gap <> 0 then
    raise exception 'DEADFIRE FAIL: B''s measured formation extent is % (want 0 — the ring this arm owns) — with any spread the hull-to-wave gap is a different chord per hull and "everyone fires on one tick" is false by construction, not by regression', v_gap;
  end if;
  select min((w->>'power')::double precision) into v_pw
    from public.combat_units u, jsonb_array_elements(u.weapons_json) w
   where u.encounter_id = v_encB and u.side = 'player';
  select coalesce(max(defense_snapshot), 0) into v_pdef
    from public.combat_units where encounter_id = v_encB and side = 'player';
  select l.base_difficulty into v_bd
    from public.combat_encounters ce join public.locations l on l.id = ce.location_id
   where ce.id = v_encB;
  if v_pw is null or v_pw <= 0 or v_bd is null or v_bd <= 0 then
    raise exception 'DEADFIRE FAIL: B''s weapon power % / base_difficulty % cannot size the wave', v_pw, v_bd;
  end if;

  -- a SIX-pirate wave: rewind started_at so the tick's own danger derivation reaches the cap.
  update public.combat_encounters set started_at = started_at - interval '930 seconds' where id = v_encB;
  v_danger := 1 + (select waves_cleared from public.combat_encounters where id = v_encB)
              + floor(extract(epoch from (now() - (select started_at from public.combat_encounters where id = v_encB)))
                      / coalesce(public.cfg_num('danger_time_divisor_seconds'), 180))::int;
  n_exp := least(coalesce(public.cfg_num('enemy_synthetic_max_units'), 6)::int, greatest(1, v_danger));
  if n_exp < 3 then
    raise exception 'DEADFIRE FAIL: staging derives only % pirate(s) — with fewer than 3 there are too few survivors to prove the living still act', n_exp;
  end if;
  -- 0341: the inverse of the engine's sizing is now (1 + scale) * bodies. See DEADFIRE arm A above.
  v_hpsc  := (1 + coalesce(public.cfg_num('enemy_hp_danger_scale'), 0.6)) * n_exp;
  v_atksc := (1 + coalesce(public.cfg_num('enemy_attack_danger_scale'), 0.25)) * n_exp;
  -- each pirate dies to ONE player shot (unit hp = half the player's weapon power) …
  perform public.set_game_config('enemy_hp_base',
    to_jsonb(round(((0.5 * v_pw * n_exp) / (v_bd * v_hpsc))::numeric, 9)));
  -- … and the whole volley costs the screened escort about a tenth of its pool, so nobody on the
  -- player side dies and "the living still act" is asked of a fight that is still going.
  perform public.set_game_config('enemy_attack_base',
    to_jsonb(round((((0.1 * v_esc_hp) * ((v_defb + v_pdef) / v_defb)) / (v_bd * v_atksc))::numeric, 9)));

  -- ── THE SPAWN TICK IS SILENT HERE TOO, THEN THE WHOLE FIELD CLOSES INTO REACH TOGETHER. ────────
  perform pg_temp.ae_tick(v_encB);
  select count(*) into n from public.combat_events
   where encounter_id = v_encB and tick_number = 1 and event_type = 'missile_salvo';
  if n <> 0 then
    raise exception 'DEADFIRE FAIL: % salvo(s) on B''s spawn tick — at extent 0 the whole wave arrives at (its own range + 1) from every hull, outside BOTH sides'' reach %, so nothing can fire on the tick it appears', n, v_reach;
  end if;
  for i in 1 .. 12 loop
    exit when v_tB is not null;
    if (select status from public.combat_encounters where id = v_encB) <> 'active' then
      raise exception 'DEADFIRE FAIL: B''s encounter left ''active'' during the approach — the exchange never happened and this arm observed nothing';
    end if;
    perform pg_temp.ae_tick(v_encB);
    select tick_number into v_tB from public.combat_encounters ce
     where ce.id = v_encB
       and exists (select 1 from public.combat_events ev
                    where ev.encounter_id = v_encB and ev.tick_number = ce.tick_number
                      and ev.event_type = 'missile_salvo');
  end loop;
  if v_tB is null then
    raise exception 'DEADFIRE FAIL: B''s field never fired within 12 ticks of the spawn — at the owned reach % the two sides never closed into it', v_reach;
  end if;
  if v_tB < 2 then
    raise exception 'DEADFIRE FAIL: B''s exchange is recorded on tick % — the spawn tick was pinned silent, so this arm observed no approach at all', v_tB;
  end if;
  select count(*) into n_units from public.combat_units where encounter_id = v_encB and side = 'enemy';
  if n_units <> n_exp then
    raise exception 'DEADFIRE FAIL: % pirate unit(s) spawned into B (want the danger-derived %)', n_units, n_exp;
  end if;

  -- ── 0336 REVERSED THIS PAIR OF CLAUSES DELIBERATELY, AND THEY ARE REPOINTED, NOT RELAXED ────────
  -- This arm asserted that the two hulls BOTH fired at the ONE pirate the frozen snapshot named, that
  -- only ONE of the two shots landed, and that exactly ONE pirate died — "the corpse shot that proves
  -- targeting was not re-read". 0336 says the opposite IN ITS OWN WORDS: its hunk 13 quotes 0317's
  -- "rather than silently re-acquiring — simultaneity is preserved" and answers "That is no longer
  -- true, and it should not have been the rule", because a shot thrown away on a corpse is the very
  -- defect (its #1) that slice was written to end. Targeting now asks for a LIVE target at BOTH
  -- acquisition sites, so the second hull re-aims instead of shooting a body.
  -- WHAT IS STILL SIMULTANEOUS, AND IS WHAT THIS ARM NOW PINS: POSITION. Every unit resolves its
  -- target and its close/kite decision from the frozen pre-move world — that is the freeze, and it
  -- survives. So the repointed claim is STRONGER than the corpse shot: two hulls firing produce TWO
  -- landed hits on TWO DISTINCT live pirates and TWO kills — no shot is wasted — while every pirate
  -- that survives still takes its own turn.
  select count(*) into n from public.combat_events
   where encounter_id = v_encB and tick_number = v_tB and event_type = 'unit_destroyed';
  if n <> 2 then
    -- (0338) THE FAILURE CARRIES THE GEOMETRY. This arm needs BOTH hulls to reach the wave on the
    -- exchange tick, and 0338 changed which DIRECTION the wave stands in — the radius is 0336's and
    -- is untouched, but a hull-to-wave distance is a chord, so it moves with the bearing to the
    -- city. A bare count cannot say whether the cause was reach, targeting or damage. Print it.
    raise exception 'DEADFIRE FAIL: % pirate(s) destroyed in B''s exchange tick (want exactly 2 — two hulls, each sized to one-shot a pirate, and 0336 re-aims the second onto a LIVE target instead of throwing it away on the corpse). Anchor (%,%); player salvos this tick %; hulls: %; wave: %',
      n, ax, ay,
      (select count(*) from public.combat_events where encounter_id = v_encB and tick_number = v_tB
        and event_type = 'missile_salvo' and source = 'player'),
      (select string_agg(format('[%s at (%s,%s) d_anchor=%s range=%s power=%s aggro=%s]',
                                left(u.id::text, 8), round(u.pos_x::numeric, 2), round(u.pos_y::numeric, 2),
                                round(public.osn_distance(ax, ay, u.pos_x, u.pos_y)::numeric, 2),
                                (select max((w->>'range')::double precision) from jsonb_array_elements(u.weapons_json) w),
                                (select max((w->>'power')::double precision) from jsonb_array_elements(u.weapons_json) w),
                                u.aggro_priority), ' ' order by u.id)
         from public.combat_units u where u.encounter_id = v_encB and u.side = 'player'),
      (select string_agg(format('[%s at (%s,%s) d_anchor=%s hp=%s range=%s dmin_hull=%s]',
                                left(e.id::text, 8), round(e.pos_x::numeric, 2), round(e.pos_y::numeric, 2),
                                round(public.osn_distance(ax, ay, e.pos_x, e.pos_y)::numeric, 2),
                                round(e.hp_current::numeric, 3),
                                (select max((w->>'range')::double precision) from jsonb_array_elements(e.weapons_json) w),
                                round((select min(public.osn_distance(e.pos_x, e.pos_y, p.pos_x, p.pos_y))
                                         from public.combat_units p
                                        where p.encounter_id = v_encB and p.side = 'player')::numeric, 2)), ' ' order by e.id)
         from public.combat_units e where e.encounter_id = v_encB and e.side = 'enemy');
  end if;
  select (payload_json->>'unit_id')::uuid into v_tgt from public.combat_events
   where encounter_id = v_encB and tick_number = v_tB and event_type = 'unit_destroyed'
   order by seq asc limit 1;
  select (payload_json->>'unit_id')::uuid into v_tgt2 from public.combat_events
   where encounter_id = v_encB and tick_number = v_tB and event_type = 'unit_destroyed'
   order by seq desc limit 1;
  if v_tgt is null or v_tgt2 is null or v_tgt = v_tgt2 then
    raise exception 'DEADFIRE FAIL: B''s two kills name % and % — two shots must land on two DISTINCT pirates, or the second gun was still aimed at the first one''s corpse', v_tgt, v_tgt2;
  end if;
  select count(*) into n from public.combat_units
   where id in (v_tgt, v_tgt2) and side = 'enemy';
  if n <> 2 then
    raise exception 'DEADFIRE FAIL: B destroyed a unit that is not a pirate (% of 2 named rows are enemy) — this scenario kills pirates', n;
  end if;
  select side into v_live_side from public.combat_units where id = v_tgt;
  select count(*) into n from public.combat_units
   where encounter_id = v_encB and side = 'player' and alive_count = 0;
  if n <> 0 then
    raise exception 'DEADFIRE FAIL: % player hull(s) died in B''s tick — the volley was sized not to, and the survivors assert below would be measuring a different fight', n;
  end if;

  -- THE FREEZE SURVIVES WHERE IT IS REAL — IN POSITION — AND NO SHOT IS WASTED.
  select count(*) into n from public.combat_events
   where encounter_id = v_encB and tick_number = v_tB and event_type = 'missile_salvo' and source = 'player';
  if n <> 2 then
    raise exception 'DEADFIRE FAIL: % player salvo(s) in B''s tick (want exactly 2 — a living unit went silent)', n;
  end if;
  select count(*) into n from public.combat_events
   where encounter_id = v_encB and tick_number = v_tB and event_type = 'missile_salvo' and source = 'player'
     and (payload_json->>'target_id')::uuid in (v_tgt, v_tgt2);
  if n <> 2 then
    raise exception 'DEADFIRE FAIL: only % of 2 player shots named one of the two pirates that died — a shot went somewhere other than the target it is credited with killing', n;
  end if;
  select count(distinct payload_json->>'target_id') into n from public.combat_events
   where encounter_id = v_encB and tick_number = v_tB and event_type = 'missile_salvo' and source = 'player';
  if n <> 2 then
    raise exception 'DEADFIRE FAIL: B''s two hulls named % distinct target(s) (want 2) — the second gun was still aimed at the first one''s corpse, which is the wasted shot 0336 exists to end', n;
  end if;
  select count(*) into n from public.combat_events
   where encounter_id = v_encB and tick_number = v_tB and event_type = 'hull_damage' and target = 'pirate';
  if n <> 2 then
    raise exception 'DEADFIRE FAIL: % landed hit(s) on the pirate side (want exactly 2 — every shot must reach a LIVE target; a shot that lands on a corpse and deals nothing is the pre-0336 waste)', n;
  end if;
  -- POSITION SIMULTANEITY, which IS what the freeze still guarantees: both hulls stand on the anchor
  -- and every surviving pirate is the same distance from them, so no hull gained ground by being
  -- processed earlier in the loop.
  select count(distinct round(public.osn_distance(ax, ay, u.pos_x, u.pos_y)::numeric, 9)) into n
    from public.combat_units u
   where u.encounter_id = v_encB and u.side = 'enemy' and u.alive_count > 0
     and u.pos_x is not null and u.pos_y is not null;
  if n <> 1 then
    raise exception 'DEADFIRE FAIL: the surviving pirates stand at % distinct radii from the anchor (want 1) — they all closed from one frozen snapshot at one speed, so a spread means a unit moved on a position another unit had already changed', n;
  end if;

  -- THE LIVING STILL ACT: every pirate still alive after the tick fired exactly once in it.
  select count(*) into n_alive from public.combat_units
   where encounter_id = v_encB and side = 'enemy' and alive_count > 0;
  if n_alive < 2 then
    raise exception 'DEADFIRE FAIL: only % pirate(s) survived B''s tick — with fewer than 2 the survivors assert is vacuous', n_alive;
  end if;
  select count(*) into n from public.combat_units u
   where u.encounter_id = v_encB and u.side = 'enemy' and u.alive_count > 0
     and not exists (select 1 from public.combat_events ev
                      where ev.encounter_id = v_encB and ev.tick_number = v_tB
                        and ev.event_type = 'missile_salvo'
                        and (ev.payload_json->>'unit_id')::uuid = u.id);
  if n <> 0 then
    raise exception 'DEADFIRE FAIL: % of % surviving pirate(s) emitted no attack event — a living unit went silent, which is how this fix goes green by breaking the fight', n, n_alive;
  end if;
  select count(*) into n from public.combat_events ev
   where ev.encounter_id = v_encB and ev.tick_number = v_tB and ev.event_type = 'missile_salvo'
     and ev.source = 'pirate'
     and (ev.payload_json->>'unit_id')::uuid = v_tgt
     and ev.seq > (select d.seq from public.combat_events d
                    where d.encounter_id = v_encB and d.tick_number = v_tB
                      and d.event_type = 'unit_destroyed'
                      and (d.payload_json->>'unit_id')::uuid = v_tgt);
  if n <> 0 then
    raise exception 'DEADFIRE FAIL: the destroyed pirate fired % time(s) after its own destruction event', n;
  end if;

  -- ══ (C) THE INVARIANT, OVER BOTH FIGHTS AND BOTH SIDES ═════════════════════════════════════════
  select count(*) into n2 from public.combat_events
   where encounter_id in (v_encA, v_encB) and event_type = 'unit_destroyed';
  if n2 < 2 then
    raise exception 'DEADFIRE FAIL: only % destruction event(s) across both fights — the ordering invariant would be vacuous', n2;
  end if;
  select count(*) into n from public.combat_events s
    join public.combat_events d
      on d.encounter_id = s.encounter_id
     and d.tick_number  = s.tick_number
     and d.event_type   = 'unit_destroyed'
     and d.payload_json->>'unit_id' = s.payload_json->>'unit_id'
   where s.encounter_id in (v_encA, v_encB)
     and s.event_type = 'missile_salvo'
     and s.seq > d.seq;
  if n <> 0 then
    raise exception 'DEADFIRE FAIL: % attack event(s) were emitted by a unit after the event that destroyed it in the same tick — the dead unit fired after its own destruction', n;
  end if;

  -- ── restore every knob this block owned. ───────────────────────────────────────────────────────
  perform public.set_game_config('enemy_hp_base',                       to_jsonb(k_hp));
  perform public.set_game_config('enemy_attack_base',                   to_jsonb(k_atk));
  perform public.set_game_config('combat_player_fallback_weapon_range', to_jsonb(k_frng));
  perform public.set_game_config('enemy_synthetic_range_base',          to_jsonb(k_erng));
  perform public.set_game_config('enemy_synthetic_range_per_difficulty', to_jsonb(k_perd));
  perform public.set_game_config('spatial_formation_ring_radius',        to_jsonb(k_ring));
  perform public.set_game_config('enemy_synthetic_speed_base',           to_jsonb(k_espd));
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', to_jsonb(k_espdd));
  perform public.set_game_config('combat_player_speed_scale',            to_jsonb(k_pspd));
  perform public.set_game_config('combat_damage_variance_pct',                     to_jsonb(k_dvar));
  perform public.set_game_config('combat_hit_variance_pct',                        to_jsonb(k_hvar));
  perform public.set_game_config('enemy_synthetic_cooldown_seconds',               to_jsonb(k_ecd));
  perform public.set_game_config('combat_player_fallback_weapon_cooldown_seconds', to_jsonb(k_pcd));

  raise notice 'DZCOMBAT_PASS_DEADFIRE ok: both sides carried the same OWNED reach %, so 0336''s structural clearance made the spawn tick SILENT on both sides and they CLOSED into reach together — the MUTUAL one-shot kill landing on tick % at a FROZEN PRE-MOVE distance of % (margin % inside that reach, measured not assumed), where the tick produced exactly ONE salvo, ONE landed hit and ONE destroyed unit: the loser (side %) emitted nothing and dealt nothing even though its own weapon (power %, hull power %) would have dealt % against the survivor''s % hull+shield; and in a % -pirate wave at extent 0, tick % saw TWO hulls kill TWO DISTINCT pirates with TWO landed hits — every shot re-aimed onto a LIVE target rather than wasted on a corpse (0336''s own reversal of the pre-0336 corpse shot) — while all % survivors still fired and still stood at ONE radius, the position freeze that IS still simultaneous; across both fights, zero attack events were emitted after the event that destroyed their firer',
    v_reach, v_tA, v_dist, v_margin, (select side from public.combat_units where id = v_dead),
    v_dead_pow, v_pwA, v_would, v_live_eff, n_units, v_tB, n_alive;
end $$;

-- ── WHY THIS BLOCK IS LAST IN THE FILE ─────────────────────────────────────────────────────────
-- It builds its OWN player, five hulls, group, sortie and encounter, and asserts only on its own
-- units — but the way it opens that encounter is the real, global path: rewind the leg, then
-- process_fleet_movements(), which advances EVERY due movement in the database. Placed mid-file it
-- sat between the ROSTERAUTH fixture and the 0311 REPOSITION block, whose first act is a
-- fixture-ISOLATION guard (exactly one active zone may hold the engagement anchor), and that guard
-- started failing the moment this block was inserted before it. Running last removes the coupling
-- entirely: nothing after it inspects the world. The guard downstream now also NAMES the zone it
-- objects to, so if that class of interference ever recurs the log says which zone rather than how
-- many.
-- ════════ DZCOMBAT_PASS_ONEPOWER (0317): THE FOLD DECIDES HOW MUCH, THE WEAPON DECIDES HOW ══════════
-- THE DEFECT THIS IS RED ON. process_combat_ticks reads combat_units.weapons_json->'power' and
-- NOTHING ELSE for damage (0299:568 -> :607/:609); attack_snapshot — the column holding the folded
-- combat_power — is used for damage ZERO times on the spatial arm, which is the live arm. The
-- builder copied module_types.power into weapons_json FLAT, so every hull attack, every captain,
-- every ship trait and every command buff contributed nothing to damage for any ship with a gun
-- fitted, and the two numbers were kept equal only by the hand-sync convention 0229:88-91 writes
-- down in prose. 0317 makes the fold the source: a ship's weapons together deliver its combat_power
-- per volley, split in proportion to their catalog power, which is now a unitless SHARE WEIGHT.
--
-- ON THE PRE-0317 BUILDER EVERY ASSERTION BELOW EXCEPT (5) FAILS AT ITS FIRST LINE: the armed ships
-- carry the flat catalog 10 / 20 / 18 while their folded combat_power is strictly larger, and the
-- trait ship fires exactly what the trait-less ship fires.
--
-- FIVE HULLS, ONE FLEET, ONE ENCOUNTER, NO TICKS (creation state IS the assertion — the tick
-- legitimately rewrites next_ready_at, so a frozen-at-creation shape can only be read pre-tick):
--   A  one autocannon_battery                    the base case
--   B  one autocannon_battery + hungry_guns      identical to A except +6 attack that is NOT a module
--   C  no weapon at all                          the 0262 fallback path — the SAME rule, share 1
--   D  two autocannon_battery                    multi-weapon: the two entries SHARE, never each
--   E  one autocannon_battery_mk2                a strictly stronger gun must never mean less damage
-- All five sit in ONE fleet on purpose: the command-buff contribution is then identical across them
-- and cancels out of every A-vs-B and A-vs-E comparison, so no assertion depends on which buff was
-- rolled. Every expected value is DERIVED at assert time from the catalog and from the unit's own
-- snapshot — nothing ambient is hard-coded, and each comparison carries its own non-vacuity pin.
do $$
declare
  r jsonb; n int;
  uP uuid;
  v_hunt uuid := (select v from dzc where k='v_hunt');
  sA uuid; sB uuid; sC uuid; sD uuid; sE uuid; s_iter uuid;
  gP uuid; v_fleet uuid; v_mv uuid; v_enc uuid;
  mv record;
  t_bat public.module_types; t_mk2 public.module_types;
  v_trait_atk numeric;
  pA double precision; pB double precision; pC double precision; pD double precision; pE double precision;
  wA double precision; wB double precision; wC double precision; wD double precision; wE double precision;
  d0 jsonb; d1 jsonb;
  v_tick_secs double precision;
  v_share_sum double precision;
begin
  -- ── THE PRECONDITION THIS BLOCK OWNS (never an ambient seed): traits must be foldable, or hull B
  --    is hull A and the whole "a trait raises damage" property is silently vacuous. ─────────────
  update public.game_config set value = 'true'::jsonb where key = 'ship_traits_enabled';

  select * into t_bat from public.module_types where id = 'autocannon_battery';
  select * into t_mk2 from public.module_types where id = 'autocannon_battery_mk2';
  if t_bat.id is null or t_mk2.id is null then
    raise exception 'ONEPOWER FAIL: the two firing weapons this block compares are not both in the catalog'; end if;
  if not public.module_is_firing_weapon(t_bat) or not public.module_is_firing_weapon(t_mk2) then
    raise exception 'ONEPOWER FAIL: a comparison weapon no longer passes module_is_firing_weapon — it would never reach weapons_json and every assert below would be vacuous'; end if;
  if coalesce((t_mk2.stats_json->>'attack')::numeric, 0) <= coalesce((t_bat.stats_json->>'attack')::numeric, 0) then
    raise exception 'ONEPOWER FAIL: autocannon_battery_mk2 does not contribute MORE attack than autocannon_battery (% vs %) — "a stronger weapon never reduces damage" would have no stronger weapon to test',
      t_mk2.stats_json->>'attack', t_bat.stats_json->>'attack'; end if;
  select coalesce((stats_json->>'attack')::numeric, 0) into v_trait_atk
    from public.ship_trait_types where trait_type_id = 'hungry_guns';
  if coalesce(v_trait_atk, 0) <= 0 then
    raise exception 'ONEPOWER FAIL: hungry_guns contributes % attack — a non-positive trait cannot demonstrate that a NON-MODULE source raises damage', v_trait_atk; end if;

  -- ── five hulls for a fresh player, one fleet ────────────────────────────────────────────────────
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.op.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uP;
  insert into public.player_wallet (player_id, balance) values (uP, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;

  r := pg_temp.call_as(uP, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'ONEPOWER FAIL: commission 1: %', r; end if;
  for n in 2 .. 5 loop
    r := pg_temp.call_as(uP, 'public.commission_additional_main_ship()');
    if (r->>'ok')::boolean is not true then raise exception 'ONEPOWER FAIL: commission %: %', n, r; end if;
  end loop;
  select main_ship_id into sA from public.main_ship_instances where player_id = uP order by main_ship_id offset 0 limit 1;
  select main_ship_id into sB from public.main_ship_instances where player_id = uP order by main_ship_id offset 1 limit 1;
  select main_ship_id into sC from public.main_ship_instances where player_id = uP order by main_ship_id offset 2 limit 1;
  select main_ship_id into sD from public.main_ship_instances where player_id = uP order by main_ship_id offset 3 limit 1;
  select main_ship_id into sE from public.main_ship_instances where player_id = uP order by main_ship_id offset 4 limit 1;
  if sA is null or sB is null or sC is null or sD is null or sE is null then
    raise exception 'ONEPOWER FAIL: five hulls did not materialise'; end if;

  -- Materials for FOUR autocannon_batteries and ONE mk2, DERIVED FROM module_recipe_ingredients
  -- rather than written out. The first version of this block hard-coded crystal/ore/scrap (the
  -- mining rig's recipe, copied from the RIGFALLBACK block above) and CI answered
  -- insufficient_items: pirate_alloy — a gun is not a rig. Deriving it means a recipe retune can
  -- never starve this fixture again, and the vacuity pin below means a recipe that VANISHED cannot
  -- quietly leave the grant empty and the craft failing for a different reason.
  select jsonb_build_object('items', jsonb_agg(jsonb_build_object('item_id', i.item_id, 'quantity', i.q)))
    into r
    from (select item_id, sum(qty * mult)::int as q from (
            select item_id, qty, 4 as mult from public.module_recipe_ingredients where module_type_id = 'autocannon_battery'
            union all
            select item_id, qty, 1      from public.module_recipe_ingredients where module_type_id = 'autocannon_battery_mk2'
          ) x group by item_id) i;
  if r is null or jsonb_array_length(r->'items') < 1 then
    raise exception 'ONEPOWER FAIL: module_recipe_ingredients carries no recipe for the two guns this block crafts — the grant would be empty and the failure would surface as a craft error rather than as this message'; end if;
  perform public.reward_grant('combat', gen_random_uuid(), uP, null, r);

  -- 0333: uP owns FIVE ships, so every craft below NAMES the hull it will be fitted to. All five
  -- are freshly commissioned and therefore docked at Haven Reach, which is also where the NULL-base
  -- grant above landed (uP's oldest active base is its Home Base at Haven) — so all five draw on
  -- the one stock that was just funded.
  r := pg_temp.call_as(uP, format('public.craft_module(''dzc-op-a1'', ''autocannon_battery'', %L::uuid)', sA));
  if (r->>'ok')::boolean is not true then raise exception 'ONEPOWER FAIL: craft A: %', r; end if;
  r := pg_temp.call_as(uP, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''dzc-op-fa'')', (r->>'instance_id')::uuid, sA));
  if (r->>'ok')::boolean is not true then raise exception 'ONEPOWER FAIL: fit A: %', r; end if;

  r := pg_temp.call_as(uP, format('public.craft_module(''dzc-op-b1'', ''autocannon_battery'', %L::uuid)', sB));
  if (r->>'ok')::boolean is not true then raise exception 'ONEPOWER FAIL: craft B: %', r; end if;
  r := pg_temp.call_as(uP, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''dzc-op-fb'')', (r->>'instance_id')::uuid, sB));
  if (r->>'ok')::boolean is not true then raise exception 'ONEPOWER FAIL: fit B: %', r; end if;

  r := pg_temp.call_as(uP, format('public.craft_module(''dzc-op-d1'', ''autocannon_battery'', %L::uuid)', sD));
  if (r->>'ok')::boolean is not true then raise exception 'ONEPOWER FAIL: craft D1: %', r; end if;
  r := pg_temp.call_as(uP, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''dzc-op-fd1'')', (r->>'instance_id')::uuid, sD));
  if (r->>'ok')::boolean is not true then raise exception 'ONEPOWER FAIL: fit D1: %', r; end if;
  r := pg_temp.call_as(uP, format('public.craft_module(''dzc-op-d2'', ''autocannon_battery'', %L::uuid)', sD));
  if (r->>'ok')::boolean is not true then raise exception 'ONEPOWER FAIL: craft D2: %', r; end if;
  r := pg_temp.call_as(uP, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''dzc-op-fd2'')', (r->>'instance_id')::uuid, sD));
  if (r->>'ok')::boolean is not true then raise exception 'ONEPOWER FAIL: fit D2: %', r; end if;

  r := pg_temp.call_as(uP, format('public.craft_module(''dzc-op-e1'', ''autocannon_battery_mk2'', %L::uuid)', sE));
  if (r->>'ok')::boolean is not true then raise exception 'ONEPOWER FAIL: craft E (mk2): %', r; end if;
  r := pg_temp.call_as(uP, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''dzc-op-fe'')', (r->>'instance_id')::uuid, sE));
  if (r->>'ok')::boolean is not true then raise exception 'ONEPOWER FAIL: fit E: %', r; end if;

  -- the ONE difference between B and A: a birthmark trait. NOT a module — that is the whole point,
  -- because a module can reach weapons_json and a trait never could.
  -- THE BLOCK OWNS THIS PRECONDITION RATHER THAN INHERITING IT (the lesson of every ambient-default
  -- red in this suite). Commissioning ROLLS a random pair of traits onto every hull, so five fresh
  -- hulls arrive carrying ten traits of unknown attack value — leaving them would make B differ from
  -- A by an unknown amount and the exact +attack identity below would flake from run to run. The
  -- rolled rows are cleared and B is given exactly one KNOWN trait. Written directly rather than
  -- through soul_roll_traits_for_ship for the same reason: that writer is random by design, and it
  -- could hand this block a zero-attack trait and make the property vacuous on some runs only. The
  -- row is a FIXTURE; what is under test is whether the FOLD carries it into damage.
  delete from public.main_ship_traits where main_ship_id in (sA, sB, sC, sD, sE);
  insert into public.main_ship_traits (main_ship_id, slot, trait_type_id) values (sB, 1, 'hungry_guns');
  select count(*) into n from public.main_ship_traits where main_ship_id in (sA, sC, sD, sE);
  if n <> 0 then raise exception 'ONEPOWER FAIL: % trait(s) survive on the control hulls — B is not a controlled variant of A', n; end if;
  select count(*) into n from public.main_ship_traits where main_ship_id = sB;
  if n <> 1 then raise exception 'ONEPOWER FAIL: hull B carries % trait(s) (want exactly the one this block gave it)', n; end if;

  -- ── fixture vacuity pins, BEFORE the fight: A and B differ by exactly the trait and nothing else,
  --    and D really did take two guns. ─────────────────────────────────────────────────────────────
  select count(*) into n from public.ship_module_fittings f
    join public.module_instances i on i.id = f.module_instance_id
    join public.module_types t on t.id = i.module_type_id
   where f.main_ship_id = sD and public.module_is_firing_weapon(t);
  if n <> 2 then raise exception 'ONEPOWER FAIL: hull D carries % firing weapon(s) (want 2) — the multi-weapon property has nothing to total', n; end if;
  select count(*) into n from public.ship_module_fittings f
    join public.module_instances i on i.id = f.module_instance_id
    join public.module_types t on t.id = i.module_type_id
   where f.main_ship_id = sC and public.module_is_firing_weapon(t);
  if n <> 0 then raise exception 'ONEPOWER FAIL: hull C carries % firing weapon(s) (want 0) — the unfitted path would never be exercised', n; end if;

  r := pg_temp.call_as(uP, 'public.upsert_ship_group(1, ''One Power'')');
  if (r->>'ok')::boolean is not true then raise exception 'ONEPOWER FAIL: group: %', r; end if;
  gP := (r->>'group_id')::uuid;
  foreach s_iter in array array[sA, sB, sC, sD, sE] loop
    r := pg_temp.call_as(uP, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_iter, gP));
    if (r->>'ok')::boolean is not true then raise exception 'ONEPOWER FAIL: assign %: %', s_iter, r; end if;
  end loop;
  r := pg_temp.call_as(uP, format('public.set_fleet_command_ship(%L::uuid, true)', sA));
  if (r->>'ok')::boolean is not true then raise exception 'ONEPOWER FAIL: designate command: %', r; end if;

  -- ── a real sortie opens a real encounter; NO ticks are run. ─────────────────────────────────────
  r := pg_temp.call_as(uP, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gP, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'ONEPOWER FAIL: hunt send: %', r; end if;
  v_fleet := (r->>'fleet_id')::uuid; v_mv := (r->>'movement_id')::uuid;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id into v_enc from public.combat_encounters where fleet_id = v_fleet and status = 'active';
  if v_enc is null then raise exception 'ONEPOWER FAIL: the hunt arrival opened no encounter'; end if;

  -- ── read each hull's FOLD (attack_snapshot) and its VOLLEY (the sum over its weapons_json) ──────
  select cu.attack_snapshot, coalesce((select sum(coalesce((e->>'power')::double precision, 0))
                                         from jsonb_array_elements(cu.weapons_json) e), 0)
    into pA, wA from public.combat_units cu where cu.encounter_id = v_enc and cu.main_ship_id = sA;
  select cu.attack_snapshot, coalesce((select sum(coalesce((e->>'power')::double precision, 0))
                                         from jsonb_array_elements(cu.weapons_json) e), 0)
    into pB, wB from public.combat_units cu where cu.encounter_id = v_enc and cu.main_ship_id = sB;
  select cu.attack_snapshot, coalesce((select sum(coalesce((e->>'power')::double precision, 0))
                                         from jsonb_array_elements(cu.weapons_json) e), 0)
    into pC, wC from public.combat_units cu where cu.encounter_id = v_enc and cu.main_ship_id = sC;
  select cu.attack_snapshot, coalesce((select sum(coalesce((e->>'power')::double precision, 0))
                                         from jsonb_array_elements(cu.weapons_json) e), 0)
    into pD, wD from public.combat_units cu where cu.encounter_id = v_enc and cu.main_ship_id = sD;
  select cu.attack_snapshot, coalesce((select sum(coalesce((e->>'power')::double precision, 0))
                                         from jsonb_array_elements(cu.weapons_json) e), 0)
    into pE, wE from public.combat_units cu where cu.encounter_id = v_enc and cu.main_ship_id = sE;
  -- NULL-VACUITY PIN (the 0313 law): attack_snapshot is nullable and `x is distinct from NULL` is
  -- TRUE for every real number, so a missing row would make some comparisons below pass while
  -- proving nothing and others fire for the wrong reason. Absence is failure, explicitly.
  if pA is null or pB is null or pC is null or pD is null or pE is null then
    raise exception 'ONEPOWER FAIL: a hull has no attack_snapshot in this encounter (A=% B=% C=% D=% E=%) — every comparison below would be vacuous', pA, pB, pC, pD, pE; end if;
  if pA <= 0 or pB <= 0 or pC <= 0 or pD <= 0 or pE <= 0 then
    raise exception 'ONEPOWER FAIL: a hull folded to a non-positive combat_power (A=% B=% C=% D=% E=%) — the identities below would be trivially satisfiable by zero', pA, pB, pC, pD, pE; end if;

  -- ── (0) THE PRE-0317 SHAPE MUST BE DISTINGUISHABLE. If a ship's fold happened to equal the sum of
  --    its guns' catalog weights, "the volley is the fold" and "the volley is the flat catalog copy"
  --    would be the same statement and the block would be green on the defect. Pin the difference.
  if pA = t_bat.power then
    raise exception 'ONEPOWER FAIL: hull A folds to % which EQUALS the catalog weight % — the pre-0317 flat copy would satisfy assertion (1) and this block would prove nothing', pA, t_bat.power; end if;
  if pD = 2 * t_bat.power then
    raise exception 'ONEPOWER FAIL: hull D folds to % which EQUALS its two catalog weights summed — assertion (3) would be satisfiable by the flat copy', pD; end if;

  -- ── (1) THE RULE: a ship's weapons together deliver exactly its folded combat_power. ────────────
  if abs(wA - pA) > 1e-9 then
    raise exception 'ONEPOWER FAIL (1): hull A fires % but its card says % — the catalog is still deciding damage instead of the fold (pre-0317: weapons_json.power was module_types.power copied flat, and attack_snapshot was never read for damage)', wA, pA; end if;
  if abs(wE - pE) > 1e-9 then
    raise exception 'ONEPOWER FAIL (1): hull E fires % but its card says %', wE, pE; end if;

  -- ── (2) A NON-MODULE SOURCE RAISES DAMAGE, PROPORTIONALLY. B is A plus one trait. ───────────────
  if abs((pB - pA) - v_trait_atk) > 1e-9 then
    raise exception 'ONEPOWER FAIL (2): B''s fold exceeds A''s by % but the trait contributes % — the fixture is not a controlled pair (something other than hungry_guns differs between the two hulls)', pB - pA, v_trait_atk; end if;
  if abs((wB - wA) - v_trait_atk) > 1e-9 then
    raise exception 'ONEPOWER FAIL (2): the trait ship fires % against the trait-less ship''s % — a difference of % where the trait is worth %. A ship trait (and by the same path every hull attack, captain and command buff) still contributes NOTHING to damage: this is the whole defect', wB, wA, wB - wA, v_trait_atk; end if;
  if wB <= wA then
    raise exception 'ONEPOWER FAIL (2): the trait did not raise damage at all (% vs %)', wB, wA; end if;

  -- ── (3) MULTI-WEAPON: the two guns SHARE the ship's power; they do not each carry it. ───────────
  if abs(wD - pD) > 1e-9 then
    raise exception 'ONEPOWER FAIL (3): the two-gun hull fires % in total but its card says % — a multi-weapon ship must total to its own combat_power', wD, pD; end if;
  select jsonb_array_length(weapons_json), weapons_json->0, weapons_json->1 into n, d0, d1
    from public.combat_units where encounter_id = v_enc and main_ship_id = sD;
  if n <> 2 then raise exception 'ONEPOWER FAIL (3): hull D carries % weapon entries (want 2)', n; end if;
  if (d0->>'power')::double precision is distinct from (d1->>'power')::double precision then
    raise exception 'ONEPOWER FAIL (3): two IDENTICAL guns took unequal shares (% vs %) — the split is not proportional to the catalog weight', d0->>'power', d1->>'power'; end if;
  if abs((d0->>'power')::double precision - pD) <= 1e-9 then
    raise exception 'ONEPOWER FAIL (3): each of the two guns carries the ship''s WHOLE combat_power (%) — that is "each", not "share", and a second gun would double a ship''s damage while its card moved by only that module''s own attack', pD; end if;
  select coalesce(sum(coalesce((e->>'power')::double precision, 0)), 0) / nullif(pD, 0) into v_share_sum
    from public.combat_units cu, jsonb_array_elements(cu.weapons_json) e
   where cu.encounter_id = v_enc and cu.main_ship_id = sD;
  if v_share_sum is null or abs(v_share_sum - 1) > 1e-9 then
    raise exception 'ONEPOWER FAIL (3): the shares sum to % of the ship''s power (want exactly 1)', v_share_sum; end if;

  -- ── (4) THE FITTED AND UNFITTED PATHS ARE ONE RULE. C fitted nothing; its synthesized weapon must
  --    satisfy the SAME identity A, D and E satisfy — volley equals fold — with no free multiplier.
  if abs(wC - pC) > 1e-9 then
    raise exception 'ONEPOWER FAIL (4): the no-weapon hull fires % against a card of % — the fitted and unfitted paths are not the same rule', wC, pC; end if;
  if exists (select 1 from public.game_config where key = 'combat_player_fallback_weapon_power_from_attack') then
    raise exception 'ONEPOWER FAIL (4): combat_player_fallback_weapon_power_from_attack still exists — a knob only the unfitted path obeys IS a second rule, however it is currently set'; end if;

  -- ── (5) FITTING A STRICTLY STRONGER WEAPON CAN NEVER REDUCE DAMAGE. E out-guns A. ───────────────
  --    Volley is damage per VOLLEY; the dps claim needs the cadences too, so they are derived and
  --    compared against each other (never against a hard-coded tick length): while every weapon's
  --    cooldown is at or under the tick, each fires once per tick and the volley ordering IS the dps
  --    ordering. A future long-cooldown weapon fails here loudly rather than making this claim false.
  --    0341 RE-DERIVED IT RATHER THAN TRUSTED IT, EXACTLY AS THE MESSAGE BELOW DEMANDED. Both guns'
  --    cooldowns were doubled past the tick (2 -> 4, 2.5 -> 5), so "fires once per tick" is no longer
  --    true of either. What the claim actually needs is that the two compared guns share a CADENCE —
  --    then the volley ordering is still the dps ordering. Cadence is ticks-to-ready, ceil(cooldown /
  --    tick): 4 and 5 both round to 2, exactly as 2 and 2.5 both rounded to 1. NOT re-pointed to a
  --    literal per-second dps ratio, which would INVERT the claim: mk2 is already the slower gun
  --    (2.5 vs 2 before, 5 vs 4 now), so wE/cd_mk2 < wA/cd_bat is possible while wE > wA is true.
  v_tick_secs := coalesce(public.cfg_num('combat_tick_seconds'), 3);
  if v_tick_secs is null or v_tick_secs <= 0 then
    raise exception 'ONEPOWER FAIL (5): combat_tick_seconds is % — no cadence can be derived from it', v_tick_secs; end if;
  if ceil(t_bat.cooldown_seconds / v_tick_secs::numeric) is distinct from ceil(t_mk2.cooldown_seconds / v_tick_secs::numeric) then
    raise exception 'ONEPOWER FAIL (5): the compared weapons no longer share a firing cadence — % and % seconds against a %s tick are % and % ticks to ready, so a volley comparison is not a dps comparison and this assertion must be re-derived rather than trusted',
      t_bat.cooldown_seconds, t_mk2.cooldown_seconds, v_tick_secs,
      ceil(t_bat.cooldown_seconds / v_tick_secs::numeric), ceil(t_mk2.cooldown_seconds / v_tick_secs::numeric); end if;
  if pE <= pA then
    raise exception 'ONEPOWER FAIL (5): the mk2 hull folds to % against the battery hull''s % — the stronger gun did not produce a stronger card and the ordering test has no direction', pE, pA; end if;
  if wE <= wA then
    raise exception 'ONEPOWER FAIL (5): fitting the STRONGER gun produced LESS OR EQUAL damage (% vs %) — the owner''s "a better module is simply a bigger number" does not hold', wE, wA; end if;

  raise notice 'DZCOMBAT_PASS_ONEPOWER ok: every hull fires exactly the number on its card — A % = %, B (+trait) % = % (the trait is worth % and it moved the damage by %), C (no weapon, synthesized) % = %, D (two guns, equal shares summing to 1) % = %, E (mk2) % = % and strictly above A. module_types.power decided only WHICH gun carried WHICH slice.',
    wA, pA, wB, pB, v_trait_atk, wB - wA, wC, pC, wD, pD, wE, pE;
end $$;

-- ════════ DZCOMBAT_PASS_WRECKHOME (0332): A WRECK CAN ALWAYS COME HOME ═══════════════════════════
-- The owner's bug, verbatim: "hull integrity ships right now have nothing to do, i don't think it is
-- fixable either." They were right — it was not fixable, and this block is the fight that produces
-- that exact ship and then proves it can now be brought back.
--
-- THE DEFECT THIS IS RED AGAINST: a fight ends through one of two arms. The DEFEAT arm has always
-- reconciled its members (fleet_destroy, then mainship_mark_combat_destroyed per member). The
-- ESCAPE/COMPLETED arm's member loop was FILTERED `and alive_count > 0` (0299:622-624) and marked
-- only the survivors 'returning' — the members that died while their fleetmates lived got NO write
-- at all. Their hull number had been written by mainship_sync_combat_hp (hp ONLY, never status), so
-- they ended the fight at hp=0 with status='home'. repair_ship_hull and mainship_emergency_tow both
-- gate on status='destroyed' (0297), and get_my_disabled_ships lists by it, so such a ship was
-- unrepairable, untowable AND invisible to the recovery UI. 0310's auto-exit made this the COMMON
-- ending rather than a rare one: its whole job is to end fights by retreating.
--
-- ── THE STAGING, and the two things it must engineer rather than hope for ────────────────────────
-- Everything runs on the REAL ambush chain and the REAL tick; combat_units is never hand-written.
--
--   (i) WHICH HULL DIES. The tick targets the LOWEST aggro tier, not the highest: its own comment
--       reads "while any escort, aggro 0, is alive, only escorts are targetable", and the query is
--       `tier as (select min(aggro_priority) …) … where c.aggro_priority = tier.m`. 0315 anchors the
--       COMMAND ship at priority 100 and screens every escort at 0 — so the escort absorbs the whole
--       wave and the command ship is the one that CANNOT be hit while it lives. This block therefore
--       pre-damages the ESCORT (through the tick's own hp writer, so the engine still deals every
--       point of damage) and designates the other hull as command. That is the ONLY reason the
--       casualty is predictable. The block does not rely on that prediction: it RESOLVES the
--       casualty and the survivor from combat_units after the fact, and asserts the identity
--       separately, so an aggro model that changed under it fails with a diagnosis instead of a
--       vacuous pass.
--
--  (ii) THAT THE FIGHT DOES NOT END BEFORE ANYONE DIES. The auto-exit's denominator is CAPACITY
--       (sum of max_hp, 0310 rev.2), so with two full hulls the 30% line sits at 30% of BOTH — which
--       a single escort's death cannot reach. Left on, the fleet simply retreats intact and this
--       block would have nothing to reconcile (the first CI run of this file did exactly that, and
--       said so). So the auto-exit is held OFF for the erosion, then re-armed through its own real
--       writer at a threshold the wounded fleet is already under, which arms the canonical retreat
--       on the very next tick. The exit path under test is unchanged: it is 0310's arm, then the
--       settle arm, exactly as in production.
--
-- PROPERTIES, in order. (1) is the pre-0332 RED; the rest exist so it cannot pass for a wrong reason:
--   1. THE WRECK IS RECONCILED. The member that died ends status='destroyed'. On the pre-0332 body
--      it ends 'home' — asserted here from a value captured live BEFORE the settle, so the block
--      carries its own evidence that the split state really existed and was really closed.
--   2. THE SURVIVOR IS UNTOUCHED, AND hp IS NOT THE PREDICATE. Immediately before the settle the
--      survivor's INSTANCE row is driven to hp 0 through the tick's own writer while its unit is
--      still alive — the exact fractional-hull state 0312:16-30 proves is legal. It must come out
--      'returning', NOT destroyed. A "fix" that reconciled on hp<=0 instead of on unit liveness
--      passes property 1 and FAILS HERE. This is the 0312 law, defended.
--   3. RECOVERY WORKS END TO END on the reconciled wreck: it is now LISTED by
--      get_my_disabled_ships, the tow berths it, and the free repair restores it to full hp at that
--      port. Before this migration none of the three was reachable for this ship.
--   4. RECOVERY IS OWNER-SCOPED: another player's tow and repair on the same wreck are refused.
--   5. THE HULL CAPACITY SURVIVES. max_hp is never reset — a destroyed ship at max_hp<=0 would raise
--      'invalid max_hp' and be unrepairable forever, the softlock 0052 exists to prevent.
--   6. A SHIP THAT WAS ALREADY DESTROYED, BERTHED, AND OUTSIDE THIS FIGHT IS UNDISTURBED and still
--      repairs exactly as before — the shape the three real destroyed ships in production carry.
do $$
declare
  r jsonb;
  uW uuid; gW uuid; sW1 uuid; sW2 uuid; sW3 uuid;
  uZ uuid := (select v from dzc where k='uZ');
  v_hunt uuid := (select v from dzc where k='v_hunt');
  v_port uuid; v_mv uuid; v_enc uuid; v_fleet uuid;
  v_wreck uuid; v_surv uuid;
  pi record; mv record; enc record;
  o_x double precision; o_y double precision; v_verts jsonb;
  v_imax double precision; v_def double precision; v_bd double precision;
  v_eab numeric; v_eab_before double precision; v_srg_before double precision;
  n_dead integer; n_alive integer; i integer;
  v_hp integer; v_max integer; v_max2 integer; v_wreck_max integer;
  v_status text; v_group uuid; v_berth uuid;
  v_pre_status text; v_pre_hp integer; v_listed jsonb; v_n integer;
  v_flipped boolean := false;
begin
  -- ── a fresh, funded fixture player and THREE hulls. 100% real RPCs. ────────────────────────────
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.wh.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uW;
  insert into public.player_wallet (player_id, balance) values (uW, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;

  r := pg_temp.call_as(uW, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'WRECKHOME FAIL: first hull: %', r; end if;
  select main_ship_id into sW1 from public.main_ship_instances where player_id = uW;
  select berth_location_id into v_port from public.main_ship_instances where main_ship_id = sW1;
  if v_port is null then raise exception 'WRECKHOME FAIL: the commissioned hull has no berth port'; end if;
  r := pg_temp.call_as(uW, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'WRECKHOME FAIL: second hull: %', r; end if;
  select main_ship_id into sW2 from public.main_ship_instances
   where player_id = uW and main_ship_id <> sW1 limit 1;
  if sW2 is null then raise exception 'WRECKHOME FAIL: no second hull materialised'; end if;
  -- a THIRD hull that never joins the fight — property 6's already-destroyed, berthed bystander.
  r := pg_temp.call_as(uW, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'WRECKHOME FAIL: third hull: %', r; end if;
  select main_ship_id into sW3 from public.main_ship_instances
   where player_id = uW and main_ship_id not in (sW1, sW2) limit 1;
  if sW3 is null then raise exception 'WRECKHOME FAIL: no third hull materialised'; end if;

  r := pg_temp.call_as(uW, 'public.upsert_ship_group(1, ''Wreck Home'')');
  if (r->>'ok')::boolean is not true then raise exception 'WRECKHOME FAIL: group: %', r; end if;
  gW := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uW, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sW1, gW));
  if (r->>'ok')::boolean is not true then raise exception 'WRECKHOME FAIL: assign 1: %', r; end if;
  r := pg_temp.call_as(uW, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sW2, gW));
  if (r->>'ok')::boolean is not true then raise exception 'WRECKHOME FAIL: assign 2: %', r; end if;
  -- sW1 COMMANDS. Per the tick's targeting tier that makes it the SCREENED one (priority 100) and
  -- leaves sW2, the escort at 0, as the only targetable hull while it lives — see staging note (i).
  r := pg_temp.call_as(uW, format('public.set_fleet_command_ship(%L::uuid, true)', sW1));
  if (r->>'ok')::boolean is not true then raise exception 'WRECKHOME FAIL: command ship: %', r; end if;
  -- HELD OFF for the erosion — staging note (ii). Re-armed below through the same real writer.
  r := pg_temp.call_as(uW, format('public.set_group_auto_exit(%L::uuid, false, 30)', gW));
  if (r->>'ok')::boolean is not true then raise exception 'WRECKHOME FAIL: auto-exit off: %', r; end if;

  -- ── PROPERTY 6's BYSTANDER: sW3 is wrecked WHILE BERTHED and never leaves port — the exact shape
  --    the three real destroyed ships in production carry (status destroyed + a berth). It must be
  --    untouched by everything below. Produced by the tick's own terminal leaf, never a hand-write.
  perform public.mainship_mark_combat_destroyed(sW3);
  select status, berth_location_id into v_status, v_berth from public.main_ship_instances where main_ship_id = sW3;
  if v_status <> 'destroyed' or v_berth is null then
    raise exception 'WRECKHOME FAIL: the bystander is not a berthed wreck (status %, berth %) — property 6 would prove nothing', v_status, v_berth;
  end if;

  -- ── PRE-DAMAGE THE ESCORT through the tick's OWN hp writer so it enters nearly dead. The
  --    encounter seeds each member's combat hull from its CURRENT instance hp, so the hull the wave
  --    is allowed to shoot is also the one that falls first — see staging note (i). This is NOT a
  --    hand-write of combat_units: the engine still deals every point of damage. ───────────────────
  select max_hp into v_max2 from public.main_ship_instances where main_ship_id = sW2;
  if v_max2 is null or v_max2 <= 20 then
    raise exception 'WRECKHOME FAIL: the escort max_hp is % — too small to pre-damage meaningfully', v_max2;
  end if;
  perform public.mainship_sync_combat_hp(sW2, greatest(1, round(v_max2 * 0.05)::integer));
  select hp, status into v_hp, v_status from public.main_ship_instances where main_ship_id = sW2;
  if v_status = 'destroyed' or v_hp <= 0 or v_hp >= v_max2 then
    raise exception 'WRECKHOME FAIL: pre-damage staging drifted (status %, hp % of %) — the escort must be ALIVE and hurt', v_status, v_hp, v_max2;
  end if;

  -- ── A REAL AMBUSH. Zone drawn on its own WESTWARD corridor: every other zone in this file sits
  --    north or south of the shared origin, so this leg crosses exactly one zone — this block's. ───
  select l.x, l.y into o_x, o_y
    from public.main_ship_instances s
    join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = uW and f.status = 'present'
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
    join public.locations l on l.id = lp.location_id
   where s.group_id = gW
   limit 1;
  if o_x is null then raise exception 'WRECKHOME FAIL: could not resolve the fleet''s docked origin'; end if;
  v_verts := jsonb_build_array(
    jsonb_build_array(o_x - 600, o_y - 100),
    jsonb_build_array(o_x - 400, o_y - 100),
    jsonb_build_array(o_x - 400, o_y + 100),
    jsonb_build_array(o_x - 600, o_y + 100));
  r := pg_temp.call_as(uW, format('public.pirate_zone_create(%L, %L::jsonb, %L::uuid)',
                                  'DZC Wreck Home Zone', v_verts::text, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'WRECKHOME FAIL: zone: %', r; end if;

  r := pg_temp.call_as(uW, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gW, round(o_x - 1000), round(o_y)));
  if (r->>'ok')::boolean is not true then raise exception 'WRECKHOME FAIL: go: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if pi is null then raise exception 'WRECKHOME FAIL: no pending ambush on the leg (risk knobs are 1.0)'; end if;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id, fleet_id into v_enc, v_fleet from public.combat_encounters
   where player_id = uW and status = 'active';
  if v_enc is null then raise exception 'WRECKHOME FAIL: the ambush opened no encounter'; end if;

  -- BOTH hulls must be fielded, or "one died and one lived" has nothing to distinguish.
  select count(*) into v_n from public.combat_units
   where encounter_id = v_enc and side = 'player' and main_ship_id is not null;
  if v_n <> 2 then
    raise exception 'WRECKHOME FAIL: % player hull(s) fielded (want exactly 2 — the whole scenario is one dying while the other lives)', v_n;
  end if;

  -- ── Derive the enemy attack from the fight's OWN numbers, exactly as AUTOEXIT does. ─────────────
  select player_integrity_max into v_imax from public.combat_encounters where id = v_enc;
  if v_imax is null or v_imax <= 0 then
    raise exception 'WRECKHOME FAIL: at-entry capacity is % — the erosion would have no scale', v_imax;
  end if;
  select coalesce(max(defense_snapshot), 0) into v_def from public.combat_units
   where encounter_id = v_enc and side = 'player';
  select l.base_difficulty into v_bd
    from public.combat_encounters ce join public.locations l on l.id = ce.location_id
   where ce.id = v_enc;
  if v_bd is null or v_bd <= 0 then raise exception 'WRECKHOME FAIL: the encounter''s location has base_difficulty %', v_bd; end if;
  select coalesce(public.cfg_num('enemy_attack_base'), 0) into v_eab_before;
  v_eab := round(((0.06 * v_imax) * ((100 + v_def) / 100.0) / (v_bd * 1.25))::numeric, 6);
  perform public.set_game_config('enemy_attack_base', to_jsonb(v_eab));
  select coalesce(public.cfg_num('shield_regen_combat_pct'), 0) into v_srg_before;
  perform public.set_game_config('shield_regen_combat_pct', '0'::jsonb);

  -- ── EROSION: the REAL tick does every point of damage. Stop the INSTANT one hull has fallen and
  --    another still stands — the window this block owns. ──────────────────────────────────────────
  for i in 1..60 loop
    perform pg_temp.ae_tick(v_enc);
    select * into enc from public.combat_encounters where id = v_enc;
    select count(*) filter (where alive_count <= 0), count(*) filter (where alive_count > 0)
      into n_dead, n_alive
      from public.combat_units where encounter_id = v_enc and side = 'player' and main_ship_id is not null;
    if n_dead >= 1 and n_alive >= 1 then v_flipped := true; exit; end if;
    if enc.status <> 'active' then
      raise exception 'WRECKHOME FAIL: the encounter reached % on tick % (% dead / % alive) — the fleet was wiped before the auto-exit could arm, so the settle arm under test was never reached. The whole point is a fight the fleet SURVIVES with a casualty; re-derive the erosion knob',
        enc.status, i, n_dead, n_alive;
    end if;
  end loop;

  -- ── THE WINDOW THIS BLOCK OWNS: exactly one hull dead, at least one alive. Absence is failure. ──
  if not v_flipped or n_dead <> 1 or n_alive < 1 then
    perform public.set_game_config('enemy_attack_base', to_jsonb(v_eab_before));
    perform public.set_game_config('shield_regen_combat_pct', to_jsonb(v_srg_before));
    raise exception 'WRECKHOME FAIL: after 60 ticks the fleet held % dead / % alive player hull(s) — this block needs EXACTLY ONE casualty beside a survivor. With 0 dead the settle has no wreck to reconcile and property 1 is vacuous; with both dead the DEFEAT arm (which always reconciled) would be doing the work instead of the settle arm under test',
      n_dead, n_alive;
  end if;

  -- RESOLVE the casualty and the survivor from the fight itself, never from the staging's intent.
  select main_ship_id into v_wreck from public.combat_units
   where encounter_id = v_enc and side = 'player' and main_ship_id is not null and alive_count <= 0 limit 1;
  select main_ship_id into v_surv from public.combat_units
   where encounter_id = v_enc and side = 'player' and main_ship_id is not null and alive_count > 0 limit 1;
  if v_wreck is null or v_surv is null or v_wreck = v_surv then
    raise exception 'WRECKHOME FAIL: could not resolve a distinct casualty (%) and survivor (%)', v_wreck, v_surv;
  end if;
  -- …and the casualty is the hull the targeting tier says it must be: the pre-damaged ESCORT, never
  -- the screened command ship. A model change here must fail loudly, not silently restage the fight.
  if v_wreck is distinct from sW2 then
    raise exception 'WRECKHOME FAIL: the casualty is % but the escort this block pre-damaged is % — the aggro concentration this block relies on did not hold (the tick targets the MINIMUM aggro tier, so while the escort at 0 lives the command ship at 100 cannot be hit), so the fight it staged is not the fight it describes',
      v_wreck, sW2;
  end if;
  select max_hp into v_wreck_max from public.main_ship_instances where main_ship_id = v_wreck;

  -- ── ⭐ THE RED, CAPTURED LIVE: the wreck's own row BEFORE the settle runs. On every body, at this
  --    instant, its unit is dead and its instance still says 'home' with hp 0 — the split state the
  --    owner could not recover from. Property 1 below asserts the settle closes it. ────────────────
  select status, hp into v_pre_status, v_pre_hp from public.main_ship_instances where main_ship_id = v_wreck;
  if v_pre_status = 'destroyed' then
    raise exception 'WRECKHOME FAIL: the casualty was ALREADY destroyed before the settle ran — something other than the settle arm reconciled it, so this block cannot attribute property 1 to the arm under test';
  end if;
  if v_pre_hp > 0 then
    raise exception 'WRECKHOME FAIL: the casualty reads hp % before the settle (want 0 — the tick''s hp writer should already have zeroed it, and without that the split state this block exists for was never created)', v_pre_hp;
  end if;

  -- ── ARM THE EXIT: the real 0310 writer, at a line the wounded fleet is already under, so the very
  --    next tick arms the canonical retreat. Same arm, same event, same path as production. ────────
  r := pg_temp.call_as(uW, format('public.set_group_auto_exit(%L::uuid, true, 95)', gW));
  if (r->>'ok')::boolean is not true then raise exception 'WRECKHOME FAIL: auto-exit re-arm: %', r; end if;
  perform pg_temp.ae_tick(v_enc);
  perform public.set_game_config('enemy_attack_base', to_jsonb(v_eab_before));
  perform public.set_game_config('shield_regen_combat_pct', to_jsonb(v_srg_before));
  select * into enc from public.combat_encounters where id = v_enc;
  if enc.status is distinct from 'retreating' then
    raise exception 'WRECKHOME FAIL: the wounded fleet did not auto-exit (encounter %) — the settle arm under test is only reachable through a completed retreat', enc.status;
  end if;
  -- the casualty must STILL be the only one, or the exit tick changed the scenario under us.
  select count(*) filter (where alive_count <= 0), count(*) filter (where alive_count > 0)
    into n_dead, n_alive
    from public.combat_units where encounter_id = v_enc and side = 'player' and main_ship_id is not null;
  if n_dead <> 1 or n_alive < 1 then
    raise exception 'WRECKHOME FAIL: the exit tick left % dead / % alive — the one-casualty window closed before the settle ran', n_dead, n_alive;
  end if;

  -- ── ⭐ PROPERTY 2's TRAP, ARMED: drive the SURVIVOR's instance row to hp 0 through the tick's own
  --    writer while its unit is still ALIVE. This is the legal fractional-hull state 0312:16-30
  --    proves is real. A reconciliation keyed on hp<=0 instead of on unit liveness wrecks this ship
  --    and fails below; the one keyed on alive_count leaves it alone. The settle arm runs no combat
  --    step, so nothing re-syncs this row before the assert. ─────────────────────────────────────────
  perform public.mainship_sync_combat_hp(v_surv, 0);
  select hp, status into v_hp, v_status from public.main_ship_instances where main_ship_id = v_surv;
  if v_hp <> 0 or v_status = 'destroyed' then
    raise exception 'WRECKHOME FAIL: could not arm the damaged-but-alive survivor (hp %, status %) — property 2 would be vacuous', v_hp, v_status;
  end if;
  select count(*) into v_n from public.combat_units
   where encounter_id = v_enc and main_ship_id = v_surv and alive_count > 0;
  if v_n <> 1 then
    raise exception 'WRECKHOME FAIL: the survivor''s unit is not alive — the hp-predicate trap is not armed and property 2 proves nothing';
  end if;

  -- ── THE SETTLE: complete the retreat like a human press (clock only), one real tick. ────────────
  update public.combat_encounters set retreat_started_at = retreat_started_at - interval '1 hour' where id = v_enc;
  perform pg_temp.ae_tick(v_enc);
  select * into enc from public.combat_encounters where id = v_enc;
  if enc.status is distinct from 'escaped' then
    raise exception 'WRECKHOME FAIL: the retreat did not complete through the settle arm (encounter % after the delay window) — the arm under test never ran', enc.status;
  end if;

  -- ── 1. THE WRECK IS RECONCILED. RED on the pre-0332 body: it stays exactly as v_pre_status. ─────
  select status, hp, max_hp into v_status, v_hp, v_max from public.main_ship_instances where main_ship_id = v_wreck;
  if v_status <> 'destroyed' then
    raise exception 'WRECKHOME FAIL: the fleet escaped and its casualty came out status=% (it was % before the settle) — a hull at 0 that the settle arm never marked is exactly the owner''s unrecoverable ship: repair_ship_hull answers nothing_to_repair, mainship_emergency_tow answers ship_not_disabled, and get_my_disabled_ships never lists it',
      v_status, v_pre_status;
  end if;
  if v_hp <> 0 then
    raise exception 'WRECKHOME FAIL: the reconciled wreck reads hp % (want 0 — the terminal leaf writes the pair together)', v_hp;
  end if;

  -- ── 5. THE HULL CAPACITY SURVIVES (checked here because the wreck is in hand). ──────────────────
  if v_max is distinct from v_wreck_max then
    raise exception 'WRECKHOME FAIL: the wreck''s max_hp moved % -> % — a wreck must keep the capacity its owner paid for, and max_hp<=0 would make repair_ship_hull answer hull_unrepairable forever', v_wreck_max, v_max;
  end if;

  -- ── 2. THE SURVIVOR IS UNTOUCHED, AND hp IS NOT THE PREDICATE. ─────────────────────────────────
  select status, hp into v_status, v_hp from public.main_ship_instances where main_ship_id = v_surv;
  if v_status = 'destroyed' then
    raise exception 'WRECKHOME FAIL: a merely damaged ship was wrecked by the settle — the survivor is ALIVE (its unit still holds alive_count > 0) and reads instance hp 0 only because the tick rounds a fractional hull down (0312:16-30). Reconciling on hp instead of on unit liveness is the damaged-is-dead trap';
  end if;
  if v_status is distinct from 'returning' then
    raise exception 'WRECKHOME FAIL: the survivor came out of the settle as % (want returning — the settle arm''s own repatriation write, unchanged by this slice)', v_status;
  end if;

  -- ── 6. THE ALREADY-DESTROYED, BERTHED BYSTANDER IS UNDISTURBED. ────────────────────────────────
  select status, hp, berth_location_id, group_id into v_status, v_hp, v_berth, v_group
    from public.main_ship_instances where main_ship_id = sW3;
  if v_status is distinct from 'destroyed' or v_berth is null or v_group is not null then
    raise exception 'WRECKHOME FAIL: the berthed bystander moved (status %, berth %, group %) — a fight it was never in must not touch a ship that was already destroyed', v_status, v_berth, v_group;
  end if;

  -- ── 3. RECOVERY WORKS END TO END on the reconciled wreck. ──────────────────────────────────────
  -- it is LISTED now — before the fix the client had nothing to render a button against.
  v_listed := pg_temp.call_as(uW, 'public.get_my_disabled_ships()');
  if not exists (select 1 from jsonb_array_elements(v_listed) el where (el->>'main_ship_id')::uuid = v_wreck) then
    raise exception 'WRECKHOME FAIL: the reconciled wreck is not listed by get_my_disabled_ships (%) — the recovery UI 0297 shipped keys on exactly this read, so an unlisted wreck has no button and the player is stuck however good the server verbs are',
      v_listed;
  end if;
  -- the tow hauls it in (the 0216 XOR write: it leaves the group and gains a berth)
  r := pg_temp.call_as(uW, format('public.mainship_emergency_tow(%L::uuid)', v_wreck));
  if (r->>'ok')::boolean is not true then
    raise exception 'WRECKHOME FAIL: the tow refused the reconciled wreck: % — the escape hatch 0297 promised must accept exactly the ships the position gate rejects', r;
  end if;
  select berth_location_id, group_id into v_berth, v_group from public.main_ship_instances where main_ship_id = v_wreck;
  if v_berth is null or v_group is not null then
    raise exception 'WRECKHOME FAIL: the tow left the wreck half-berthed (berth %, group %) — the 0216 XOR admits no intermediate', v_berth, v_group;
  end if;
  -- and the free repair brings it all the way back, at that port — free by POLICY, not by luck:
  -- 0335 charges a wreck nothing whatever repair_credits_per_hp says, and reports it in the envelope.
  r := pg_temp.call_as(uW, format('public.repair_ship_hull(%L::uuid, null, %L::uuid)', v_wreck, gen_random_uuid()));
  if (r->>'ok')::boolean is not true or (r->>'status') is distinct from 'home' then
    raise exception 'WRECKHOME FAIL: repair did not revive the towed wreck: %', r;
  end if;
  if (r->>'total_price')::numeric <> 0 or (r->>'recovered')::boolean is not true then
    raise exception 'WRECKHOME FAIL: wreck recovery was charged / not marked a recovery: %', r;
  end if;
  select hp, max_hp, status into v_hp, v_max, v_status from public.main_ship_instances where main_ship_id = v_wreck;
  if v_hp is distinct from v_max or v_status is distinct from 'home' then
    raise exception 'WRECKHOME FAIL: the recovered ship is hp %/% status % — the owner''s ship must come back whole', v_hp, v_max, v_status;
  end if;
  if v_max is distinct from v_wreck_max then
    raise exception 'WRECKHOME FAIL: recovery changed max_hp % -> %', v_wreck_max, v_max;
  end if;

  -- ── 6 (continued). THE BYSTANDER STILL REPAIRS EXACTLY AS BEFORE. ──────────────────────────────
  -- It is berthed, so 0297's position gate passes without a tow — the three real destroyed ships in
  -- production carry this shape and this migration must not have changed their day.
  r := pg_temp.call_as(uW, format('public.repair_ship_hull(%L::uuid, null, %L::uuid)', sW3, gen_random_uuid()));
  if (r->>'ok')::boolean is not true or (r->>'status') is distinct from 'home' then
    raise exception 'WRECKHOME FAIL: the already-destroyed berthed ship no longer repairs: % — this slice must not have touched the recovery path that already worked', r;
  end if;

  -- ── 4. RECOVERY IS OWNER-SCOPED. Re-wreck it through the terminal leaf, then let a STRANGER try. ──
  perform public.mainship_mark_combat_destroyed(v_wreck);
  r := pg_temp.call_as(uZ, format('public.mainship_emergency_tow(%L::uuid)', v_wreck));
  if (r->>'ok')::boolean is not false then
    raise exception 'WRECKHOME FAIL: another player towed a wreck they do not own: % — recovery must be owner-scoped and fail closed', r;
  end if;
  -- 0335: ownership is refused as a VALUE (ship_not_found — never an existence oracle for another
  -- player's hull), so the exception dance this needed is gone.
  r := pg_temp.call_as(uZ, format('public.repair_ship_hull(%L::uuid, null, %L::uuid)', v_wreck, gen_random_uuid()));
  if (r->>'ok')::boolean is not false or (r->>'reason') is distinct from 'ship_not_found' then
    raise exception 'WRECKHOME FAIL: another player repaired a wreck they do not own, or was refused for the wrong reason: %', r;
  end if;
  select status into v_status from public.main_ship_instances where main_ship_id = v_wreck;
  if v_status is distinct from 'destroyed' then
    raise exception 'WRECKHOME FAIL: a stranger''s refused recovery still moved the ship to % — a refusal must write nothing', v_status;
  end if;

  raise notice 'DZCOMBAT_PASS_WRECKHOME ok: a 2-hull fleet was ambushed and lost its screened escort (unit alive_count 0) while its command hull lived, then AUTO-EXITED and completed the retreat — the escape/completed settle arm, not the defeat arm. Before the settle the casualty read status=% hp=%; after it, status=destroyed hp=0 with max_hp still % — while the survivor, holding a LIVE unit and an instance row driven to hp 0, came out ''returning'' and NOT destroyed (the 0312 fractional-hull law, which an hp-shaped reconciliation would have broken). The wreck is then LISTED by get_my_disabled_ships, towed to a port and repaired to %/% — and a stranger''s tow and repair on it are both refused, writing nothing. A ship that was already destroyed and berthed, and never in this fight, is byte-unchanged and still repairs',
    v_pre_status, v_pre_hp, v_wreck_max, v_max, v_max;
end $$;

-- ════════ DZCOMBAT_PASS_DOCKWRECK (0334): A WRECK IS WHERE ITS FLEET IS ══════════════════════════
-- The owner, verbatim: "you don't need to tow to a nearest port. As a fleet we have arrived at a
-- dock already."
--
-- THE DEFECT THIS IS RED AGAINST: mainship_port_of_ship (0297 §1) had exactly two arms — the ship's
-- OWN resolved fleet, then its berth. A ship that owns no per-ship fleet row resolves nothing
-- (mainship_resolve_fleet's transition fallback ends `if v_n <> 1 then return null;`) and, being in a
-- group, can hold no berth at all (the 0216 XOR: `(group_id is null) = (berth_location_id is not
-- null)`). So it had NO position — while its own fleetmates, which DO own per-ship fleets, were
-- reading "Docked at Haven" from them. Every recovery verb then refused it: repair_ship_hull answers
-- not_at_port, and get_my_disabled_ships reports at_port=false so the client offers only a tow.
-- The tow was not the design; it was the only thing that still worked.
--
-- ── THE STAGING, and why it is the owner's shape rather than a convenient one ────────────────────
-- Every hull is commissioned through the real RPC, and port_entry_commission_build mints each one
-- "exactly ONE present/location fleet" tagged with its own main_ship_id. assign_ship_to_group then
-- mints ONE unified fleet (group_id set, main_ship_id NULL) for the first ship into an empty group,
-- and it never updates or deletes a fleet — so each member keeps its own commission fleet as well.
--
-- WHILE THAT UNIFIED FLEET LIVES THERE IS NO BUG: branch (1) of mainship_resolve_fleet answers for
-- every member, wreck or not. So the block RETIRES it with fleet_destroy — the tick's own leaf,
-- whose sole production caller is process_combat_ticks, and exactly what happened to the owner:
-- production group df4649fc holds FOUR fleets at status='destroyed' and no live unified one. Only
-- then does the group match the shape the two arms could not answer, and only then is this block
-- red against anything. The premise is asserted rather than assumed, both before and after.
--
-- The casualty is then produced by the tick's OWN terminal leaves, never a hand-write: fleet_destroy
-- on the wreck's own fleet (the exact thing combat does to a fleet that dies) followed by
-- mainship_mark_combat_destroyed on the ship. That leaves B owning no live fleet and no berth — the
-- pre-0334 dead end — while A, its fleetmate, is still docked.
--
-- NOTE WHICH CLAUSE OF THE FIX THIS EXERCISES: A's commission fleet carries main_ship_id but NOT
-- group_id (port_entry_commission_build sets no group), so the group arm can only find it through
-- its member-ownership clause — "a live docked fleet owned by a ship that is a member of my group".
-- A tagged-fleets-only implementation goes RED here. That clause is the load-bearing one and this is
-- what proves it.
--
-- PROPERTIES, in order. (1) is the pre-0334 RED; the rest exist so it cannot pass for a wrong reason:
--   1. THE WRECK IS AT ITS FLEET'S DOCK. Its port is the port its fleetmate is docked at. The RED is
--      SOURCE-DERIVED and stated as such: a proof can only run the post-fix chain, so the premise is
--      asserted instead — the wreck resolves NO fleet and holds NO berth, which are precisely the
--      two inputs the old body had, so the old body could only have returned NULL.
--   2. LIVING AND WRECKED CANNOT DISAGREE. The fleetmate and the wreck resolve the SAME port. This is
--      the invariant whose absence produced the bug, asserted directly.
--   3. THE CLIENT CAN SEE IT: get_my_disabled_ships lists the wreck with at_port TRUE and the right
--      location_id — the one field src/features/ship/shipRecovery.ts's repairGate keys on.
--   4. IT REPAIRS WITHOUT A TOW, AND KEEPS ITS PLACE IN THE FLEET. No tow is called; the ship comes
--      back to full hp and is STILL a member of its group. The tow un-groups (the 0216 XOR write), so
--      an unchanged group_id is positive proof no tow happened.
--   5. THE TOW SURVIVES FOR THE CASE IT WAS BUILT FOR. A wreck whose group holds no docked fleet at
--      all still resolves no port, still has its repair refused with not_at_port, and is still
--      recovered by tow-then-repair. 0334 must not have deleted the escape hatch.
--   6. RECOVERY IS OWNER-SCOPED: another player's tow and repair on the wreck are refused.
do $$
declare
  r jsonb;
  uD uuid; gG uuid; gH uuid; sA uuid; sB uuid; sC uuid;
  fA uuid; fB uuid; fC uuid; v_unified uuid;
  uZ uuid := (select v from dzc where k='uZ');
  v_port uuid; v_pa uuid; v_pb uuid; v_pc uuid;
  v_status text; v_hp integer; v_max integer; v_group uuid; v_berth uuid;
  v_listed jsonb; v_n integer; v_at_port boolean; v_loc_listed uuid;
begin
  -- ── a fresh, funded fixture player and THREE hulls. 100% real RPCs. ────────────────────────────
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.dw.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uD;
  insert into public.player_wallet (player_id, balance) values (uD, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;

  r := pg_temp.call_as(uD, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'DOCKWRECK FAIL: hull A: %', r; end if;
  select main_ship_id into sA from public.main_ship_instances where player_id = uD;
  select berth_location_id into v_port from public.main_ship_instances where main_ship_id = sA;
  if v_port is null then raise exception 'DOCKWRECK FAIL: the commissioned hull has no berth port'; end if;
  r := pg_temp.call_as(uD, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'DOCKWRECK FAIL: hull B: %', r; end if;
  select main_ship_id into sB from public.main_ship_instances
   where player_id = uD and main_ship_id <> sA limit 1;
  r := pg_temp.call_as(uD, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'DOCKWRECK FAIL: hull C: %', r; end if;
  select main_ship_id into sC from public.main_ship_instances
   where player_id = uD and main_ship_id not in (sA, sB) limit 1;
  if sB is null or sC is null then raise exception 'DOCKWRECK FAIL: hulls B/C did not materialise (% / %)', sB, sC; end if;

  -- ── TWO groups: G holds the fleetmate + the wreck; H holds the genuinely-nowhere wreck alone. ──
  r := pg_temp.call_as(uD, 'public.upsert_ship_group(1, ''Dock Wreck'')');
  if (r->>'ok')::boolean is not true then raise exception 'DOCKWRECK FAIL: group G: %', r; end if;
  gG := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uD, 'public.upsert_ship_group(2, ''Nowhere'')');
  if (r->>'ok')::boolean is not true then raise exception 'DOCKWRECK FAIL: group H: %', r; end if;
  gH := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uD, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sA, gG));
  if (r->>'ok')::boolean is not true then raise exception 'DOCKWRECK FAIL: assign A: %', r; end if;
  r := pg_temp.call_as(uD, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sB, gG));
  if (r->>'ok')::boolean is not true then raise exception 'DOCKWRECK FAIL: assign B: %', r; end if;
  r := pg_temp.call_as(uD, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sC, gH));
  if (r->>'ok')::boolean is not true then raise exception 'DOCKWRECK FAIL: assign C: %', r; end if;

  -- ── RETIRE THE GROUPS' UNIFIED FLEETS — the step that makes this production's shape. ───────────
  -- assign_ship_to_group mints ONE unified fleet (group_id set, main_ship_id NULL) for the first
  -- ship into an empty group. While that fleet lives, mainship_resolve_fleet's branch (1) answers
  -- for every member and NOTHING IS BROKEN — which is why the block must not stop here.
  -- Production group df4649fc has no unified fleet: it holds FOUR fleets at status='destroyed',
  -- because that is what a fight does to a fleet. fleet_destroy is the tick's own leaf and its sole
  -- production caller is process_combat_ticks, so this reproduces the owner's state through the
  -- exact writer that produced it — not by deleting or hand-editing a row.
  select id into v_unified from public.fleets
   where group_id = gG and player_id = uD and main_ship_id is null
     and status in ('idle','moving','present','returning') limit 1;
  if v_unified is null then
    raise exception 'DOCKWRECK FAIL: group G was never given a unified fleet — the staging assumes assign_ship_to_group mints one, and without it this block is not reproducing the shape it claims';
  end if;
  perform public.fleet_destroy(v_unified);
  select id into v_unified from public.fleets
   where group_id = gH and player_id = uD and main_ship_id is null
     and status in ('idle','moving','present','returning') limit 1;
  if v_unified is not null then perform public.fleet_destroy(v_unified); end if;

  -- ── THE STAGING PREMISE, OWNED not inherited: the group now has NO unified fleet, so every member
  --    is answered by its own commission fleet — production's shape exactly. ──────────────────────
  select count(*) into v_n from public.fleets
   where group_id = gG and player_id = uD and main_ship_id is null
     and status in ('idle','moving','present','returning');
  if v_n <> 0 then
    raise exception 'DOCKWRECK FAIL: group G still owns % unified fleet(s) — a group with a unified fleet was NEVER broken (its members resolve it through branch 1), so this block would prove nothing about the defect', v_n;
  end if;
  fA := public.mainship_resolve_fleet(sA);
  fB := public.mainship_resolve_fleet(sB);
  fC := public.mainship_resolve_fleet(sC);
  if fA is null or fB is null or fC is null then
    raise exception 'DOCKWRECK FAIL: a hull owns no per-ship fleet after commission+assign (% / % / %) — the staging assumes port_entry_commission_build''s present/location fleet survives assignment', fA, fB, fC;
  end if;
  -- and A's fleet is NOT group-tagged, which is what forces the fix's member-ownership clause to be
  -- the thing under test rather than a convenient tagged-fleet lookup.
  select group_id into v_group from public.fleets where id = fA;
  if v_group is not null then
    raise exception 'DOCKWRECK FAIL: the fleetmate''s commission fleet is group-tagged (%) — then a tagged-only implementation would pass and the member-ownership clause would be untested', v_group;
  end if;

  -- ── WRECK B, through the tick's OWN terminal leaves, exactly as a combat casualty is made. ──────
  perform public.fleet_destroy(fB);
  perform public.mainship_mark_combat_destroyed(sB);

  -- ── ⭐ THE PRE-0334 DEAD END, ASSERTED AS THE RED'S PREMISE. The old body had exactly two inputs:
  --    a resolved fleet, and a berth. Both are empty here, so it could only ever have returned NULL.
  if public.mainship_resolve_fleet(sB) is not null then
    raise exception 'DOCKWRECK FAIL: the wreck still resolves a fleet — the pre-0334 dead end is not staged and property 1 would prove nothing';
  end if;
  select berth_location_id, group_id, status into v_berth, v_group, v_status
    from public.main_ship_instances where main_ship_id = sB;
  if v_berth is not null then
    raise exception 'DOCKWRECK FAIL: the wreck holds a berth (%) — then the old berth arm would already have answered and this block would not be red against anything', v_berth;
  end if;
  if v_group is distinct from gG or v_status is distinct from 'destroyed' then
    raise exception 'DOCKWRECK FAIL: the wreck is group % status % (want group G, destroyed)', v_group, v_status;
  end if;
  -- …while its FLEETMATE is demonstrably docked. Without this the group has no dock to inherit.
  v_pa := public.mainship_port_of_ship(sA);
  if v_pa is distinct from v_port then
    raise exception 'DOCKWRECK FAIL: the fleetmate is at % (want the commission port %) — the group is not at a dock, so there is nothing for the wreck to be at either', v_pa, v_port;
  end if;

  -- ── 1. THE WRECK IS AT ITS FLEET'S DOCK. RED on the pre-0334 body (premise asserted above). ─────
  v_pb := public.mainship_port_of_ship(sB);
  if v_pb is null then
    raise exception 'DOCKWRECK FAIL: the wreck is at NO port even though its fleetmate is docked at % — this is the owner''s bug: "as a fleet we have arrived at a dock already". A ship that owns no per-ship fleet resolves none, and being grouped it can hold no berth (0216 XOR), so the two-arm body had no answer and demanded a tow to a port the fleet was already at',
      v_pa;
  end if;
  if v_pb is distinct from v_port then
    raise exception 'DOCKWRECK FAIL: the wreck resolved port % but its fleet is docked at % — a wreck must never name a port its fleetmates are not at', v_pb, v_port;
  end if;

  -- ── 2. LIVING AND WRECKED CANNOT DISAGREE. ─────────────────────────────────────────────────────
  if v_pb is distinct from v_pa then
    raise exception 'DOCKWRECK FAIL: the fleetmate reads % and the wreck reads % — a fleet''s living ships and its wrecks disagreeing about where they are is exactly what produced this defect', v_pa, v_pb;
  end if;

  -- ── 3. THE CLIENT CAN SEE IT (the one field repairGate keys on). ───────────────────────────────
  v_listed := pg_temp.call_as(uD, 'public.get_my_disabled_ships()');
  select (el->>'at_port')::boolean, (el->>'location_id')::uuid
    into v_at_port, v_loc_listed
    from jsonb_array_elements(v_listed) el
   where (el->>'main_ship_id')::uuid = sB;
  if not found then
    raise exception 'DOCKWRECK FAIL: the wreck is not listed by get_my_disabled_ships (%) — the Ships tab renders from exactly this read', v_listed;
  end if;
  if v_at_port is not true or v_loc_listed is distinct from v_port then
    raise exception 'DOCKWRECK FAIL: the wreck is listed at_port=% location=% (want true / %) — with at_port false the client shows "Tow to the nearest port" and disables Repair, so the player still cannot do the thing the server would now allow',
      v_at_port, v_loc_listed, v_port;
  end if;

  -- ── 4. IT REPAIRS WITHOUT A TOW, AND KEEPS ITS PLACE IN THE FLEET. ─────────────────────────────
  select max_hp into v_max from public.main_ship_instances where main_ship_id = sB;
  r := pg_temp.call_as(uD, format('public.repair_ship_hull(%L::uuid, null, %L::uuid)', sB, gen_random_uuid()));
  if (r->>'ok')::boolean is not true or (r->>'status') is distinct from 'home' then
    raise exception 'DOCKWRECK FAIL: repair refused a wreck standing at its own fleet''s dock: %', r;
  end if;
  select hp, status, group_id, berth_location_id into v_hp, v_status, v_group, v_berth
    from public.main_ship_instances where main_ship_id = sB;
  if v_hp is distinct from v_max or v_status is distinct from 'home' then
    raise exception 'DOCKWRECK FAIL: the repaired ship is hp %/% status %', v_hp, v_max, v_status;
  end if;
  -- NO TOW HAPPENED, positively: the tow's only durable write is the 0216 XOR pair (group -> NULL,
  -- berth -> a port). The ship is still grouped and still berthless, so it was never hauled anywhere.
  if v_group is distinct from gG or v_berth is not null then
    raise exception 'DOCKWRECK FAIL: the ship left its fleet during recovery (group %, berth %) — repairing where it already was must not un-group it, and an un-grouped berthed ship is the signature of a tow the owner said should not be needed', v_group, v_berth;
  end if;

  -- ── 5. THE TOW SURVIVES FOR THE CASE IT WAS BUILT FOR: a wreck whose group holds no dock. ──────
  perform public.fleet_destroy(fC);
  perform public.mainship_mark_combat_destroyed(sC);
  select count(*) into v_n from public.fleets f
   where f.player_id = uD and public.fleet_docked_location(f) is not null
     and (f.group_id = gH
          or exists (select 1 from public.main_ship_instances m
                      where m.main_ship_id = f.main_ship_id and m.group_id = gH));
  if v_n <> 0 then
    raise exception 'DOCKWRECK FAIL: group H still holds % docked fleet(s) — then its wreck is NOT nowhere and the tow-still-required property is vacuous', v_n;
  end if;
  v_pc := public.mainship_port_of_ship(sC);
  if v_pc is not null then
    raise exception 'DOCKWRECK FAIL: a wreck whose group holds no docked fleet resolved port % — 0334 must answer only from a dock the fleet actually holds, never invent one', v_pc;
  end if;
  r := pg_temp.call_as(uD, format('public.repair_ship_hull(%L::uuid, null, %L::uuid)', sC, gen_random_uuid()));
  if (r->>'ok')::boolean is not false then
    raise exception 'DOCKWRECK FAIL: repair accepted a wreck that is genuinely at no port: %', r;
  end if;
  if (r->>'reason') is distinct from 'not_at_port' then
    raise exception 'DOCKWRECK FAIL: repair refused the nowhere-wreck with the wrong reason (%) — the position gate must still be the thing that answers', r;
  end if;
  r := pg_temp.call_as(uD, format('public.mainship_emergency_tow(%L::uuid)', sC));
  if (r->>'ok')::boolean is not true then
    raise exception 'DOCKWRECK FAIL: the tow refused the nowhere-wreck: % — 0334 must not have broken the escape hatch it relies on for exactly this case', r;
  end if;
  r := pg_temp.call_as(uD, format('public.repair_ship_hull(%L::uuid, null, %L::uuid)', sC, gen_random_uuid()));
  if (r->>'ok')::boolean is not true or (r->>'status') is distinct from 'home' then
    raise exception 'DOCKWRECK FAIL: repair did not revive the towed nowhere-wreck: %', r;
  end if;

  -- ── 6. RECOVERY IS OWNER-SCOPED. Re-wreck B, then let a STRANGER try. ──────────────────────────
  perform public.mainship_mark_combat_destroyed(sB);
  r := pg_temp.call_as(uZ, format('public.mainship_emergency_tow(%L::uuid)', sB));
  if (r->>'ok')::boolean is not false then
    raise exception 'DOCKWRECK FAIL: another player towed a wreck they do not own: %', r;
  end if;
  r := pg_temp.call_as(uZ, format('public.repair_ship_hull(%L::uuid, null, %L::uuid)', sB, gen_random_uuid()));
  if (r->>'ok')::boolean is not false or (r->>'reason') is distinct from 'ship_not_found' then
    raise exception 'DOCKWRECK FAIL: another player repaired a wreck they do not own, or was refused for the wrong reason: %', r;
  end if;
  select status into v_status from public.main_ship_instances where main_ship_id = sB;
  if v_status is distinct from 'destroyed' then
    raise exception 'DOCKWRECK FAIL: a stranger''s refused recovery still moved the ship to % — a refusal must write nothing', v_status;
  end if;

  raise notice 'DZCOMBAT_PASS_DOCKWRECK ok: in a group with NO unified fleet (production''s own shape), a wreck that owns no fleet row and — being grouped — can hold no berth resolved its FLEETMATE''S dock (%) instead of nothing, through the member-ownership clause alone (the fleetmate''s commission fleet carries no group_id). The living ship and the wreck report the SAME port, get_my_disabled_ships lists it at_port=true, and it repaired to %/% WITHOUT a tow — still in its group, still berthless, so no haul occurred. A wreck whose group holds no docked fleet still resolves nothing, is still refused with not_at_port, and is still recovered by tow-then-repair; and a stranger''s tow and repair are both refused, writing nothing',
    v_port, v_hp, v_max;
end $$;

-- ════════ DZCOMBAT_PASS_RANGEINVARIANT (0336): A WAVE MUST NEVER ARRIVE INSIDE ITS OWN REACH ════════
-- THE DEFECT, executed read-only against the deployed mover at production's live knobs: at The
-- Furnace (base_difficulty 60, hidden) the synthetic enemy range is 3.6 + 0.04*60 = 6.0 and the
-- formation ring was 6.0, so the wave spawned INSIDE its own range, KITEd on tick one and settled at
-- enemy_range - player_speed = 5.8 — beyond the player's 5. It never fired; the pirate fired every
-- tick. A firing squad, not a fight, and it was decided by one comparison between two numbers.
-- WHY THERE IS NO KNOB INEQUALITY IN THIS BLOCK, AND WHY ITS ABSENCE IS THE BETTER PROOF. The first
-- cut asserted `spatial_formation_ring_radius > enemy_synthetic_range_base + D *
-- enemy_synthetic_range_per_difficulty` for every location — the shape the fix took when it was a
-- one-off raise of the ring at apply time. That is deleted, deliberately. 0336 now spawns the wave
-- at `spatial_formation_ring_radius + THAT WAVE'S OWN weapon range + 1`, so the clearance is a
-- STRUCTURE rather than a tuning and no knob value can violate it. Asserting the old inequality
-- would now be asserting a coincidence, and it would go RED on a correct system the moment either
-- knob moved: the ambient-default law, in the form it takes when a fix stops being a number.
-- TWO PROPERTIES, deliberately of different kinds:
--   (1) THE CLEARANCE, MEASURED on a real staged wave through the real chain — the minimum distance
--       from EVERY player unit to EVERY enemy unit must exceed the wave's own frozen weapon range.
--       This WITNESSES the geometry instead of inferring it, so it survives any future change to
--       how the spawn radius is computed and fails the moment a wave can arrive somewhere it can
--       shoot from and not be shot back at.
--   (2) THE CLOSING ENEMY MUST STOP SOMEWHERE THE PLAYER CAN REACH, over EVERY location that can
--       host a fight — including hidden ones, because a hidden site is one that has not been
--       RELEASED yet, not one that cannot be fought. (1) only guarantees the wave STARTS outside its
--       own reach and therefore closes. Where it STOPS is the kite band at enemy_range -
--       player_speed, and if that is beyond the player's own gun the standoff is back in a different
--       costume. Derived from game_config and the module catalog, never hard-coded. The migration
--       carries an equivalent in its own assert (g); the duplication is wanted — that one proves the
--       TEXT, this one proves the BEHAVIOUR.
-- IT RUNS FIRST AMONG THE 0336 BLOCKS ON PURPOSE: every block below OWNS a formation ring (each
-- needs its fixture in contact on the tick it measures) and restores it, so this is the one place
-- the COMMITTED value is still the value in the row. It captures that value and the last block
-- re-asserts it, so a restore that leaks fails loudly instead of moving the world under a later run.
do $$
declare
  r jsonb; n int;
  uV uuid; sV uuid; gV uuid;
  o_x double precision; o_y double precision;
  v_hunt uuid := (select v from dzc where k='v_hunt');
  v_mv uuid; v_enc uuid; mv record; pi record;
  v_ring double precision; v_base double precision; v_per double precision;
  v_pmin double precision; v_fb double precision; v_cat double precision;
  v_spd_base double precision; v_spd_per double precision;
  v_name text; v_status text; v_bd double precision; v_need double precision;
  v_er double precision; v_espd double precision;
  v_minsep double precision; v_wr double precision;
  n_locs int; n_enemy int; n_null int;
begin
  -- ── THE KNOBS THE QUANTIFIED HALF IS MADE OF, read from the live rows, none assumed. v_ring is
  --    NOT asserted against anything — 0336 stopped making the clearance a comparison between two
  --    knobs — it is captured only so the last 0336 block can prove no fixture leaked it. ──────────
  v_ring := public.cfg_num('spatial_formation_ring_radius');
  v_base := public.cfg_num('enemy_synthetic_range_base');
  v_per  := public.cfg_num('enemy_synthetic_range_per_difficulty');
  if v_ring is null or v_base is null or v_per is null then
    raise exception 'RANGEINVARIANT FAIL: a knob this invariant is made of is missing (ring %, enemy range base %, per difficulty %) — a comparison against NULL is TRUE for nothing and FALSE for nothing, so the whole check would prove nothing',
      v_ring, v_base, v_per;
  end if;
  -- NON-VACUITY, first half: an empty location set satisfies a universally quantified claim for
  -- free. If nothing in the world can host a fight, that is a fact about the seed the next author
  -- must decide about — never a green run.
  select count(*) into n_locs from public.locations where base_difficulty > 0;
  if n_locs = 0 then
    raise exception 'RANGEINVARIANT FAIL: not one location carries a positive base_difficulty — there is no site to quantify over and this invariant would be vacuously true on an empty world';
  end if;
  -- NON-VACUITY, second half: a NULL difficulty is not covered by `base_difficulty > 0`, so a row
  -- with an unknown difficulty would slip out of the quantifier unnoticed.
  select count(*) into n_null from public.locations where base_difficulty is null;
  if n_null <> 0 then
    raise exception 'RANGEINVARIANT FAIL: % location(s) carry a NULL base_difficulty — they fall outside this quantifier and their wave geometry is unchecked', n_null;
  end if;
  -- the widest synthetic range any live site can produce — reported in the notice as the scale the
  -- structural clearance has to cover, never compared against the ring.
  select max(v_base + l.base_difficulty * v_per) into v_need
    from public.locations l where l.base_difficulty > 0;

  -- ── (2) WHERE THE CLOSING ENEMY STOPS. The kite band is enemy_range - player_speed; a wave that
  --    settles beyond the player's own shortest gun rebuilds the standoff even though (1) holds. The
  --    player's reach is the SMALLEST thing that can be brought to a fight: the synthesized fallback
  --    weapon, or the shortest FIRING module in the catalog (a rig is not a gun — 0308's predicate
  --    is the authority, reused rather than re-stated). ──────────────────────────────────────────
  v_fb := public.cfg_num('combat_player_fallback_weapon_range');
  select min(t.range) into v_cat from public.module_types t
   where t.range is not null and public.module_is_firing_weapon(t);
  if v_fb is null or v_cat is null then
    raise exception 'RANGEINVARIANT FAIL: the player fallback range (%) or the shortest catalog firing weapon (%) is missing — there is no player reach to compare the kite band against', v_fb, v_cat;
  end if;
  v_pmin := least(v_fb, v_cat);
  v_spd_base := public.cfg_num('enemy_synthetic_speed_base');
  v_spd_per  := public.cfg_num('enemy_synthetic_speed_per_difficulty');
  if v_spd_base is null or v_spd_per is null then
    raise exception 'RANGEINVARIANT FAIL: the enemy speed knobs are missing (base %, per difficulty %) — the kite band has no width', v_spd_base, v_spd_per;
  end if;
  select l.name, l.status, l.base_difficulty,
         v_base + l.base_difficulty * v_per, v_spd_base + l.base_difficulty * v_spd_per
    into v_name, v_status, v_bd, v_er, v_espd
    from public.locations l
   where l.base_difficulty > 0
     and (v_base + l.base_difficulty * v_per) > v_pmin
     and (v_spd_base + l.base_difficulty * v_spd_per) <= (v_base + l.base_difficulty * v_per) - v_pmin
   order by l.base_difficulty desc, l.name asc
   limit 1;
  if v_name is not null then
    raise exception 'RANGEINVARIANT FAIL: at % (status %, base_difficulty %) the enemy range is % against a player reach of %, and the enemy closes only % per tick — it stops in the kite band at % and the player can never reach it: the standoff is back in a different costume',
      v_name, v_status, v_bd, v_er, v_pmin, v_espd, v_er - v_espd;
  end if;

  -- ── (1) THE CLEARANCE, MEASURED ON A REAL WAVE — the primary assert of this block. One hull, the
  --    real ambush chain, the real tick, then the minimum distance from EVERY player unit to EVERY
  --    enemy unit against the wave's own frozen weapon range. Enemy speed is zeroed for the
  --    measurement so the positions read back are the SPAWN positions and not wherever the CLOSE arm
  --    moved them; that knob is owned here and restored below. ─────────────────────────────────────
  select coalesce(public.cfg_num('enemy_synthetic_speed_base'), 0.6) into v_spd_base;
  select coalesce(public.cfg_num('enemy_synthetic_speed_per_difficulty'), 0.04) into v_spd_per;
  perform public.set_game_config('enemy_synthetic_speed_base',           '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', '0'::jsonb);

  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.ri.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uV;
  insert into public.player_wallet (player_id, balance) values (uV, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
  r := pg_temp.call_as(uV, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'RANGEINVARIANT FAIL: commission: %', r; end if;
  select main_ship_id into sV from public.main_ship_instances where player_id = uV;
  r := pg_temp.call_as(uV, 'public.upsert_ship_group(1, ''Range Invariant'')');
  if (r->>'ok')::boolean is not true then raise exception 'RANGEINVARIANT FAIL: group: %', r; end if;
  gV := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uV, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sV, gV));
  if (r->>'ok')::boolean is not true then raise exception 'RANGEINVARIANT FAIL: assign: %', r; end if;
  r := pg_temp.call_as(uV, format('public.set_fleet_command_ship(%L::uuid, true)', sV));
  if (r->>'ok')::boolean is not true then raise exception 'RANGEINVARIANT FAIL: command ship: %', r; end if;
  r := pg_temp.call_as(uV, format('public.set_group_auto_exit(%L::uuid, false, 30)', gV));
  if (r->>'ok')::boolean is not true then raise exception 'RANGEINVARIANT FAIL: auto-exit off: %', r; end if;
  select l.x, l.y into o_x, o_y
    from public.main_ship_instances s
    join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = uV and f.status = 'present'
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
    join public.locations l on l.id = lp.location_id
   where s.group_id = gV
   limit 1;
  if o_x is null then raise exception 'RANGEINVARIANT FAIL: could not resolve the docked origin'; end if;
  r := pg_temp.call_as(uV, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gV, round(o_x), round(o_y + 1000)));
  if (r->>'ok')::boolean is not true then raise exception 'RANGEINVARIANT FAIL: go: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if pi is null then raise exception 'RANGEINVARIANT FAIL: no pending ambush on the leg (the standing north corridor should cover it)'; end if;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id into v_enc from public.combat_encounters where player_id = uV and status = 'active';
  if v_enc is null then raise exception 'RANGEINVARIANT FAIL: the ambush opened no encounter'; end if;
  perform pg_temp.ae_tick(v_enc);

  select count(*) into n_enemy from public.combat_units where encounter_id = v_enc and side = 'enemy';
  if n_enemy < 1 then
    raise exception 'RANGEINVARIANT FAIL: the tick spawned % enemy unit(s) — there is no wave to measure and the geometric half of this invariant would be vacuous', n_enemy;
  end if;
  select max((w->>'range')::double precision) into v_wr
    from public.combat_units cu9, jsonb_array_elements(cu9.weapons_json) w
   where cu9.encounter_id = v_enc and cu9.side = 'enemy';
  -- NULL-VACUITY (the 0313 law): an unpositioned unit makes osn_distance NULL, and a NULL minimum
  -- compares FALSE against everything — the measurement would pass while measuring nothing.
  select count(*) into n_null from public.combat_units
   where encounter_id = v_enc and (pos_x is null or pos_y is null);
  if n_null <> 0 then
    raise exception 'RANGEINVARIANT FAIL: % unit(s) in the staged fight carry a NULL coordinate — an unpositioned wave cannot prove where it arrived', n_null;
  end if;
  if v_wr is null or v_wr <= 0 then
    raise exception 'RANGEINVARIANT FAIL: the wave carries no weapon range in its frozen weapons_json (%) — there is nothing to say it spawned outside', v_wr;
  end if;
  select min(public.osn_distance(p9.pos_x, p9.pos_y, e9.pos_x, e9.pos_y)) into v_minsep
    from public.combat_units p9, public.combat_units e9
   where p9.encounter_id = v_enc and p9.side = 'player'
     and e9.encounter_id = v_enc and e9.side = 'enemy';
  if v_minsep is null then
    raise exception 'RANGEINVARIANT FAIL: the player-to-wave separation is NULL — the geometric half of this invariant would be vacuous';
  end if;
  if v_minsep <= v_wr then
    raise exception 'RANGEINVARIANT FAIL: the nearest player hull stands % from the wave, inside the wave own reach of % — measured on a real fight, the wave arrived where it can shoot without being shot. 0336 makes that clearance STRUCTURAL (spawn radius = ring + that wave own range + 1), so this is not a knob that drifted: the spawn expression itself has been changed or lost',
      v_minsep, v_wr;
  end if;

  perform public.set_game_config('enemy_synthetic_speed_base',           to_jsonb(v_spd_base));
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', to_jsonb(v_spd_per));
  insert into dzn values ('ring0', v_ring);

  raise notice 'DZCOMBAT_PASS_RANGEINVARIANT ok: measured on a REAL staged wave, the nearest player hull stood % away against a wave reach of % — the clearance is structural (spawn radius = ring % + that wave own range + 1), not a comparison between two knobs; and over all % location(s) with a positive difficulty (hidden ones included, widest synthetic range %) the closing enemy always stops inside the player shortest reach of %',
    round(v_minsep::numeric, 3), v_wr, v_ring, n_locs, v_need, v_pmin;
end $$;

-- ════════ DZCOMBAT_PASS_VOLLEY (0336): A KILL DOES NOT DISARM THE REST OF THE VOLLEY ════════════════
-- THE DEFECT, RED BY CONSTRUCTION BELOW. The target was resolved ONCE, above the per-weapon loop, so
-- every gun on a ship fired at that one row — and when gun 1 destroyed it, the damage step's `if
-- found` guard simply DROPPED guns 2 and 3. Their shots were logged and then vanished. Production
-- holds one ship with THREE fitted autocannons, and 0331 had just split its combat_power three ways
-- to feed those three barrels, so two thirds of its damage disappeared on every kill tick.
-- THE FIXTURE: one hull carrying THREE autocannon_battery (slot_cost 1 each against the starter
-- hull's 3 module slots — the exact production shape), a wave with STRICTLY MORE pirates than the
-- ship has guns, and each pirate sized from the fight's own numbers to die to ONE gun's shot.
-- ON THE HEAD: 3 salvos, ONE distinct target across them, ONE landed hit, ONE kill.
-- POST-0336:   3 salvos, THREE distinct targets, THREE landed hits, THREE kills.
-- Every number is derived at assert time from the rows this encounter actually carries: the per-gun
-- power is read off weapons_json (0331 SHARES a ship's power between identical guns, so a guess of
-- "the catalog weight" would size the wave wrong), the wave size from the same danger formula the
-- tick evaluates, and the one-shot sizing is asserted to really one-shot before anything is claimed.
do $$
declare
  r jsonb; n int; n_exp int; n_guns int;
  uY uuid; sY uuid; gY uuid;
  o_x double precision; o_y double precision;
  v_hunt uuid := (select v from dzc where k='v_hunt');
  v_mv uuid; v_enc uuid; mv record; pi record;
  v_pw double precision; v_pw_max double precision; v_pool double precision; v_pdef double precision;
  v_defb double precision; v_bd double precision; v_danger int;
  v_hpsc double precision; v_atksc double precision; v_uhp double precision;
  v_tick int; n_salvo int; n_targets int; n_dmg int; n_kill int; n_alive int;
  k_ring double precision; k_ehp double precision; k_eatk double precision;
  k_erb double precision; k_erp double precision; k_esb double precision; k_esp double precision;
  k_srg double precision;
begin
  -- ── OWN EVERY PRECONDITION. The ring is pulled in so the wave lands inside the autocannon's own
  --    range on tick one (0336 RAISES the shipped ring past that range — this block is about the
  --    volley, not about closure, and CLOSURE above is where the approach is proven); the enemy
  --    range is pulled in so the wave cannot shoot back and change the fight underneath the
  --    measurement; the enemy speed is zeroed so the distances the fire gate reads are the spawn
  --    distances. All captured and restored at the end. ────────────────────────────────────────────
  select coalesce(public.cfg_num('spatial_formation_ring_radius'), 30)          into k_ring;
  select coalesce(public.cfg_num('enemy_hp_base'), 14)                          into k_ehp;
  select coalesce(public.cfg_num('enemy_attack_base'), 1.0)                     into k_eatk;
  select coalesce(public.cfg_num('enemy_synthetic_range_base'), 3.6)            into k_erb;
  select coalesce(public.cfg_num('enemy_synthetic_range_per_difficulty'), 0.04) into k_erp;
  select coalesce(public.cfg_num('enemy_synthetic_speed_base'), 0.6)            into k_esb;
  select coalesce(public.cfg_num('enemy_synthetic_speed_per_difficulty'), 0.04) into k_esp;
  select coalesce(public.cfg_num('shield_regen_combat_pct'), 0)                 into k_srg;
  perform public.set_game_config('spatial_formation_ring_radius',          '1'::jsonb);
  perform public.set_game_config('enemy_synthetic_range_base',             '0.1'::jsonb);
  perform public.set_game_config('enemy_synthetic_range_per_difficulty',   '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_base',             '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty',   '0'::jsonb);
  perform public.set_game_config('shield_regen_combat_pct',                '0'::jsonb);

  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.vo.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uY;
  insert into public.player_wallet (player_id, balance) values (uY, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
  r := pg_temp.call_as(uY, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'VOLLEY FAIL: commission: %', r; end if;
  select main_ship_id into sY from public.main_ship_instances where player_id = uY;

  -- Materials for THREE autocannon_batteries, DERIVED from the recipe rather than written out (the
  -- ONEPOWER lesson: a hard-coded ingredient list answers insufficient_items after a recipe retune).
  select jsonb_build_object('items', jsonb_agg(jsonb_build_object('item_id', i.item_id, 'quantity', i.q)))
    into r
    from (select item_id, sum(qty * 3)::int as q from public.module_recipe_ingredients
           where module_type_id = 'autocannon_battery' group by item_id) i;
  if r is null or jsonb_array_length(r->'items') < 1 then
    raise exception 'VOLLEY FAIL: module_recipe_ingredients carries no recipe for autocannon_battery — the grant would be empty and the failure would surface as a craft error instead of this message';
  end if;
  perform public.reward_grant('combat', gen_random_uuid(), uY, null, r);
  for n in 1 .. 3 loop
    r := pg_temp.call_as(uY, format('public.craft_module(%L, ''autocannon_battery'', %L::uuid)', 'dzc-vo-g'||n, sY));
    if (r->>'ok')::boolean is not true then raise exception 'VOLLEY FAIL: craft gun %: %', n, r; end if;
    r := pg_temp.call_as(uY, format('public.fit_module_to_ship(%L::uuid, %L::uuid, %L)', (r->>'instance_id')::uuid, sY, 'dzc-vo-f'||n));
    if (r->>'ok')::boolean is not true then raise exception 'VOLLEY FAIL: fit gun %: %', n, r; end if;
  end loop;
  -- FIXTURE VACUITY PIN, before the fight: three FIRING weapons really are fitted. A two-gun hull
  -- would satisfy every count below with the head's own behaviour on a two-pirate wave.
  select count(*) into n_guns from public.ship_module_fittings f
    join public.module_instances i on i.id = f.module_instance_id
    join public.module_types t on t.id = i.module_type_id
   where f.main_ship_id = sY and public.module_is_firing_weapon(t);
  if n_guns <> 3 then
    raise exception 'VOLLEY FAIL: the hull carries % firing weapon(s) — this block is about a THREE-gun ship and with fewer guns there is no dropped volley to observe', n_guns;
  end if;

  r := pg_temp.call_as(uY, 'public.upsert_ship_group(1, ''Volley'')');
  if (r->>'ok')::boolean is not true then raise exception 'VOLLEY FAIL: group: %', r; end if;
  gY := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uY, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sY, gY));
  if (r->>'ok')::boolean is not true then raise exception 'VOLLEY FAIL: assign: %', r; end if;
  r := pg_temp.call_as(uY, format('public.set_fleet_command_ship(%L::uuid, true)', sY));
  if (r->>'ok')::boolean is not true then raise exception 'VOLLEY FAIL: command ship: %', r; end if;
  r := pg_temp.call_as(uY, format('public.set_group_auto_exit(%L::uuid, false, 30)', gY));
  if (r->>'ok')::boolean is not true then raise exception 'VOLLEY FAIL: auto-exit off: %', r; end if;

  select l.x, l.y into o_x, o_y
    from public.main_ship_instances s
    join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = uY and f.status = 'present'
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
    join public.locations l on l.id = lp.location_id
   where s.group_id = gY
   limit 1;
  if o_x is null then raise exception 'VOLLEY FAIL: could not resolve the docked origin'; end if;
  r := pg_temp.call_as(uY, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gY, round(o_x), round(o_y + 1000)));
  if (r->>'ok')::boolean is not true then raise exception 'VOLLEY FAIL: go: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if pi is null then raise exception 'VOLLEY FAIL: no pending ambush on the leg'; end if;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id into v_enc from public.combat_encounters where player_id = uY and status = 'active';
  if v_enc is null then raise exception 'VOLLEY FAIL: the ambush opened no encounter'; end if;

  select count(*) into n from public.combat_units where encounter_id = v_enc and side = 'player';
  if n <> 1 then raise exception 'VOLLEY FAIL: % player unit(s) fielded (this block needs exactly 1, so every salvo in the tick is attributable to one ship)', n; end if;
  select jsonb_array_length(weapons_json) into n_guns from public.combat_units
   where encounter_id = v_enc and side = 'player';
  if n_guns <> 3 then
    raise exception 'VOLLEY FAIL: the fielded hull carries % weapon entr(ies) in its frozen weapons_json (want 3) — the fixture is not a three-gun ship and there is nothing to re-aim', n_guns;
  end if;
  select min((w->>'power')::double precision), max((w->>'power')::double precision)
    into v_pw, v_pw_max
    from public.combat_units cu9, jsonb_array_elements(cu9.weapons_json) w
   where cu9.encounter_id = v_enc and cu9.side = 'player';
  select hp_current + coalesce(shield_current, 0), coalesce(defense_snapshot, 0)
    into v_pool, v_pdef
    from public.combat_units where encounter_id = v_enc and side = 'player';
  -- NULL-VACUITY (the 0313 law): every one of these feeds a comparison, and a NULL turns the
  -- comparison into a silent pass. Absence is failure, said out loud.
  if v_pw is null or v_pw <= 0 or v_pool is null or v_pool <= 0 then
    raise exception 'VOLLEY FAIL: per-gun power % / hull pool % — the one-shot sizing has nothing to size against and every count below would be measuring a fight that never happened', v_pw, v_pool;
  end if;
  v_defb := coalesce(public.cfg_num('defense_curve_base'), 100);
  if v_defb <= 0 then raise exception 'VOLLEY FAIL: defense_curve_base is % — the mitigation arithmetic has no base', v_defb; end if;
  select l.base_difficulty into v_bd
    from public.combat_encounters ce join public.locations l on l.id = ce.location_id
   where ce.id = v_enc;
  if v_bd is null or v_bd <= 0 then raise exception 'VOLLEY FAIL: the encounter location carries base_difficulty % — the wave formulas have no scale', v_bd; end if;

  -- A WAVE WITH MORE PIRATES THAN THE SHIP HAS GUNS. now() is frozen for the whole txn, so a fresh
  -- encounter is always danger 1 (one pirate) — which is exactly the case that CANNOT distinguish
  -- the two bodies. Rewinding the encounter's OWN started_at is a CLOCK-ONLY write, the same law
  -- pg_temp.rewind_leg / drain_encounter / ae_tick already follow: no status, no outcome, no
  -- geometry, no hp is written. The count is then DERIVED from the same formula the tick evaluates.
  update public.combat_encounters set started_at = started_at - interval '600 seconds' where id = v_enc;
  v_danger := 1 + (select waves_cleared from public.combat_encounters where id = v_enc)
              + floor(extract(epoch from (now() - (select started_at from public.combat_encounters where id = v_enc)))
                      / coalesce(public.cfg_num('danger_time_divisor_seconds'), 180))::int;
  n_exp := least(coalesce(public.cfg_num('enemy_synthetic_max_units'), 6)::int, greatest(1, v_danger));
  if n_exp <= 3 then
    raise exception 'VOLLEY FAIL: staging derives % pirate(s) for a THREE-gun ship — the wave must hold strictly more pirates than the ship has guns, or the last gun has nothing left to re-aim at and the whole property is vacuous', n_exp;
  end if;
  -- 0341: the inverse of the engine's sizing is now (1 + scale) * bodies. See DEADFIRE arm A above.
  v_hpsc  := (1 + coalesce(public.cfg_num('enemy_hp_danger_scale'), 0.6)) * n_exp;
  v_atksc := (1 + coalesce(public.cfg_num('enemy_attack_danger_scale'), 0.25)) * n_exp;
  -- each pirate dies to ONE gun's shot (unit hp = half a single gun's share) …
  perform public.set_game_config('enemy_hp_base',
    to_jsonb(round(((0.5 * v_pw * n_exp) / (v_bd * v_hpsc))::numeric, 9)));
  -- … and the whole wave together costs the hull ~2% of its pool, so nothing about the player side
  -- changes underneath the counts.
  perform public.set_game_config('enemy_attack_base',
    to_jsonb(round((((0.02 * v_pool) * ((v_defb + v_pdef) / v_defb)) / (v_bd * v_atksc))::numeric, 9)));

  perform pg_temp.ae_tick(v_enc);
  select tick_number into v_tick from public.combat_encounters where id = v_enc;
  select count(*) into n from public.combat_units where encounter_id = v_enc and side = 'enemy';
  if n <> n_exp then
    raise exception 'VOLLEY FAIL: % pirate unit(s) spawned (want the danger-derived %)', n, n_exp;
  end if;
  -- THE ONE-SHOT SIZING REALLY ONE-SHOTS — asserted against the row the tick actually wrote, never
  -- assumed from the formula that asked for it. If a pirate could survive a single gun, gun 2 would
  -- have nothing to re-aim at and three distinct targets would be unreachable for a correct engine.
  select max(ship_hp) into v_uhp from public.combat_units where encounter_id = v_enc and side = 'enemy';
  if v_uhp is null or v_uhp <= 0 or v_uhp >= v_pw then
    raise exception 'VOLLEY FAIL: a pirate carries % hull against a per-gun share of % — one gun does not one-shot it, so the re-aim this block measures could not happen on ANY body', v_uhp, v_pw;
  end if;

  select count(*) into n_salvo from public.combat_events
   where encounter_id = v_enc and tick_number = v_tick and event_type = 'missile_salvo' and source = 'player';
  if n_salvo <> 3 then
    raise exception 'VOLLEY FAIL: % player salvo(s) in the tick (want exactly 3 — one per fitted gun)', n_salvo;
  end if;
  select count(*) filter (where payload_json->>'target_id' is null),
         count(distinct payload_json->>'target_id')
    into n, n_targets
    from public.combat_events
   where encounter_id = v_enc and tick_number = v_tick and event_type = 'missile_salvo' and source = 'player';
  if n <> 0 then
    raise exception 'VOLLEY FAIL: % player salvo(s) name no target at all — a distinct-target count over NULLs would prove nothing', n;
  end if;
  if n_targets <> 3 then
    raise exception 'VOLLEY FAIL: the three guns aimed at % distinct pirate(s) (want 3) — the target was resolved ONCE above the per-weapon loop, so gun 2 and gun 3 fired at the row gun 1 had already destroyed and their shots were dropped by the damage step',
      n_targets;
  end if;
  select count(*) into n_dmg from public.combat_events
   where encounter_id = v_enc and tick_number = v_tick and event_type = 'hull_damage' and source = 'player';
  if n_dmg <> 3 then
    raise exception 'VOLLEY FAIL: % landed hit(s) from a three-gun volley (want 3) — a kill disarmed the rest of the volley', n_dmg;
  end if;
  select count(*) into n_kill from public.combat_events
   where encounter_id = v_enc and tick_number = v_tick and event_type = 'unit_destroyed' and source = 'player';
  if n_kill <> 3 then
    raise exception 'VOLLEY FAIL: % pirate(s) destroyed by a three-gun volley (want 3) — two thirds of the ship damage vanished on the kill tick', n_kill;
  end if;
  select count(*) into n_alive from public.combat_units
   where encounter_id = v_enc and side = 'enemy' and alive_count > 0;
  if n_alive <> n_exp - 3 then
    raise exception 'VOLLEY FAIL: % pirate(s) survived the volley (want % — the wave minus one per gun)', n_alive, n_exp - 3;
  end if;
  select count(*) into n from public.combat_units
   where encounter_id = v_enc and side = 'player' and alive_count > 0;
  if n <> 1 then
    raise exception 'VOLLEY FAIL: the firing hull did not survive its own volley — the wave was sized not to touch it and these counts would be describing a different fight';
  end if;

  perform public.set_game_config('spatial_formation_ring_radius',        to_jsonb(k_ring));
  perform public.set_game_config('enemy_hp_base',                        to_jsonb(k_ehp));
  perform public.set_game_config('enemy_attack_base',                    to_jsonb(k_eatk));
  perform public.set_game_config('enemy_synthetic_range_base',           to_jsonb(k_erb));
  perform public.set_game_config('enemy_synthetic_range_per_difficulty', to_jsonb(k_erp));
  perform public.set_game_config('enemy_synthetic_speed_base',           to_jsonb(k_esb));
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', to_jsonb(k_esp));
  perform public.set_game_config('shield_regen_combat_pct',              to_jsonb(k_srg));

  raise notice 'DZCOMBAT_PASS_VOLLEY ok: a THREE-gun hull (equal shares of % each, %.. max, 0331) met a %-pirate wave sized so one gun one-shots one pirate (% hull each) and fired 3 salvos at 3 DISTINCT targets, landing 3 hits and destroying 3 — the head resolved the target once and dropped guns 2 and 3 (1 distinct target, 1 hit, 1 kill); % pirate(s) were left standing and the hull came through untouched',
    v_pw, v_pw_max, n_exp, round(v_uhp::numeric, 4), n_alive;
end $$;

-- ════════ DZCOMBAT_PASS_WAVERING (0336): A WAVE ARRIVES ON A RING, NOT ON ONE POINT ═════════════════
-- THE DEFECT, RED BY CONSTRUCTION BELOW. Both spawn arms inserted every unit of a wave at the
-- identical engagement anchor. Measured on production: every encounter that ever held enemies holds
-- them at exactly ONE distinct position. Three consequences, all bad — distance from any actor to
-- every enemy became the same constant, so the id-ascending tiebreak in targeting was absolute and
-- every gun of every ship converged on one row (which is what made the dropped-volley defect above
-- as expensive as it was); the fight rendered as a single pixel; and the whole wave sat inside its
-- own range from tick zero, which is the basin the standoff lives in.
-- WHAT IS ASSERTED, and why it is written to survive a retune of the radius: the block does NOT
-- assume how far out the ring is. It MEASURES the radius off the wave itself and then requires every
-- unit's position to be reproduced by combat_formation_point — the leaf the tick composes — at that
-- radius, at the arrival phase, at a slot that no other unit used. That pins the ring, the phase
-- and the per-slot stepping without hard-coding the radius, so a later change to how far out a wave
-- spawns cannot make this block wrong. ON THE HEAD the radius measures 0, every position is the
-- anchor and the distinct-position count is 1.
do $$
declare
  r jsonb; n int; n_exp int; n_match int; n_null int;
  uW2 uuid; sW2 uuid; gW2 uuid;
  o_x double precision; o_y double precision;
  v_hunt uuid := (select v from dzc where k='v_hunt');
  v_mv uuid; v_enc uuid; mv record; pi record;
  ax double precision; ay double precision;
  sx double precision; sy double precision;
  c_x double precision; c_y double precision;
  n_slot0 int; n_wide int;
  v_rad double precision; v_rmin double precision; v_rmax double precision;
  n_distinct int; n_units int;
  k_ring double precision; k_ehp double precision; k_esb double precision; k_esp double precision;
begin
  select coalesce(public.cfg_num('spatial_formation_ring_radius'), 30)          into k_ring;
  select coalesce(public.cfg_num('enemy_hp_base'), 14)                          into k_ehp;
  select coalesce(public.cfg_num('enemy_synthetic_speed_base'), 0.6)            into k_esb;
  select coalesce(public.cfg_num('enemy_synthetic_speed_per_difficulty'), 0.04) into k_esp;
  -- The enemy speed is zeroed so the positions read back after the tick ARE the spawn positions:
  -- the wave spawns and then moves inside the same tick, and a block about where a wave ARRIVES
  -- must not be measuring where the CLOSE arm took it. hp is raised so nothing dies mid-measurement.
  perform public.set_game_config('enemy_synthetic_speed_base',           '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', '0'::jsonb);
  perform public.set_game_config('enemy_hp_base',                        '100000'::jsonb);

  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.wv.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uW2;
  insert into public.player_wallet (player_id, balance) values (uW2, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
  r := pg_temp.call_as(uW2, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'WAVERING FAIL: commission: %', r; end if;
  select main_ship_id into sW2 from public.main_ship_instances where player_id = uW2;
  r := pg_temp.call_as(uW2, 'public.upsert_ship_group(1, ''Wavering'')');
  if (r->>'ok')::boolean is not true then raise exception 'WAVERING FAIL: group: %', r; end if;
  gW2 := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uW2, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sW2, gW2));
  if (r->>'ok')::boolean is not true then raise exception 'WAVERING FAIL: assign: %', r; end if;
  r := pg_temp.call_as(uW2, format('public.set_fleet_command_ship(%L::uuid, true)', sW2));
  if (r->>'ok')::boolean is not true then raise exception 'WAVERING FAIL: command ship: %', r; end if;
  r := pg_temp.call_as(uW2, format('public.set_group_auto_exit(%L::uuid, false, 30)', gW2));
  if (r->>'ok')::boolean is not true then raise exception 'WAVERING FAIL: auto-exit off: %', r; end if;
  select l.x, l.y into o_x, o_y
    from public.main_ship_instances s
    join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = uW2 and f.status = 'present'
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
    join public.locations l on l.id = lp.location_id
   where s.group_id = gW2
   limit 1;
  if o_x is null then raise exception 'WAVERING FAIL: could not resolve the docked origin'; end if;
  r := pg_temp.call_as(uW2, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                   gW2, round(o_x), round(o_y + 1000)));
  if (r->>'ok')::boolean is not true then raise exception 'WAVERING FAIL: go: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if pi is null then raise exception 'WAVERING FAIL: no pending ambush on the leg'; end if;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id into v_enc from public.combat_encounters where player_id = uW2 and status = 'active';
  if v_enc is null then raise exception 'WAVERING FAIL: the ambush opened no encounter'; end if;

  -- a wave of at least THREE: one point cannot be told from a ring, and two cannot be told from a
  -- line. CLOCK-ONLY rewind, the ae_tick/rewind_leg law, and the count DERIVED from the tick's own
  -- danger formula rather than assumed.
  update public.combat_encounters set started_at = started_at - interval '600 seconds' where id = v_enc;
  n_exp := least(coalesce(public.cfg_num('enemy_synthetic_max_units'), 6)::int,
                 greatest(1, 1 + (select waves_cleared from public.combat_encounters where id = v_enc)
                            + floor(extract(epoch from (now() - (select started_at from public.combat_encounters where id = v_enc)))
                                    / coalesce(public.cfg_num('danger_time_divisor_seconds'), 180))::int));
  if n_exp < 3 then
    raise exception 'WAVERING FAIL: staging derives only % pirate(s) — with fewer than 3 a ring cannot be told apart from a point or a line and this block would prove nothing', n_exp;
  end if;

  perform pg_temp.ae_tick(v_enc);
  select engagement_x, engagement_y into ax, ay from public.combat_encounters where id = v_enc;
  if ax is null or ay is null then
    raise exception 'WAVERING FAIL: the encounter carries no engagement anchor — every distance below would be NULL and every comparison a silent pass';
  end if;
  -- (0338) THE CITY THE WAVE COMES OUT OF, read through the game's own link rather than typed in:
  -- combat_encounters.location_id, which the ambush path carries from danger_zones.location_id.
  -- Both preconditions below are OWNED, not assumed — if the staging ever stops linking a site, or
  -- ever anchors the fight ON its site, the leaf correctly falls back to 0336's plain ring and the
  -- origin assert would pass while proving nothing. That must be loud, not silent.
  select l.x, l.y into sx, sy
    from public.combat_encounters ce join public.locations l on l.id = ce.location_id
   where ce.id = v_enc;
  if sx is null or sy is null then
    raise exception 'WAVERING FAIL: the encounter carries no linked site — this block stages a real AMBUSH, whose zone is created through pirate_zone_create WITH a pirate_hunt location, so a NULL site means the staging changed and the arrival-bearing assert below would be measuring the no-direction fallback';
  end if;
  if public.osn_distance(ax, ay, sx, sy) <= 1e-6 then
    raise exception 'WAVERING FAIL: the fight is anchored on its own site (anchor %,% site %,%) — there is no direction to arrive FROM, so the leaf correctly answers the plain ring and the arrival-bearing assert below would prove nothing', ax, ay, sx, sy;
  end if;
  select count(*) into n_units from public.combat_units where encounter_id = v_enc and side = 'enemy';
  if n_units <> n_exp then
    raise exception 'WAVERING FAIL: % pirate unit(s) spawned (want the danger-derived %)', n_units, n_exp;
  end if;
  -- NULL-VACUITY (the 0313 law) BEFORE any geometry: `x is distinct from NULL` is TRUE for every
  -- real number, so an unpositioned unit would make the distinct-position count and every radius
  -- comparison pass while proving nothing at all.
  select count(*) into n_null from public.combat_units
   where encounter_id = v_enc and side = 'enemy' and (pos_x is null or pos_y is null);
  if n_null <> 0 then
    raise exception 'WAVERING FAIL: % of % pirate(s) carry a NULL coordinate — an unpositioned wave cannot prove it arrived anywhere', n_null, n_units;
  end if;

  -- (1) EVERY UNIT ON ITS OWN POINT. On the head this count is 1, whatever the wave size.
  select count(distinct (pos_x, pos_y)) into n_distinct
    from public.combat_units where encounter_id = v_enc and side = 'enemy';
  if n_distinct <> n_units then
    raise exception 'WAVERING FAIL: % pirate(s) occupy only % distinct position(s) — the whole wave was inserted at one identical point, so distance became a constant, the id tiebreak became absolute and every gun on the field converged on one row',
      n_units, n_distinct;
  end if;

  -- (2) NOBODY ON THE ANCHOR, and every unit the SAME distance from it: that is what makes it a
  --     ring rather than a scatter. The radius is MEASURED, never assumed — a later change to how
  --     far out a wave spawns must not be able to make this block wrong.
  select min(public.osn_distance(ax, ay, pos_x, pos_y)),
         max(public.osn_distance(ax, ay, pos_x, pos_y))
    into v_rmin, v_rmax
    from public.combat_units where encounter_id = v_enc and side = 'enemy';
  if v_rmin is null or v_rmax is null then
    raise exception 'WAVERING FAIL: the wave radius measured NULL — the ring assert would be vacuous';
  end if;
  if v_rmin <= 0 then
    raise exception 'WAVERING FAIL: a pirate stands % from the engagement anchor — the wave is still being planted on the anchor itself, which is where the player lead stands', v_rmin;
  end if;
  if abs(v_rmax - v_rmin) > 1e-6 then
    raise exception 'WAVERING FAIL: the wave spans radii % to % — it is not one ring, so the formation leaf is not what placed it', v_rmin, v_rmax;
  end if;
  v_rad := v_rmin;

  -- (3) AND IT IS THE FORMATION LEAF'S OWN RING. Every unit must sit exactly on
  --     combat_formation_point(anchor, measured radius, k, the arrival phase for k) for some slot k
  --     in 0..n-1, and no two units may claim the same k. This pins the phase and the per-slot
  --     stepping — the two things that stop a wave landing on top of itself — without this block
  --     ever having to know how the radius is computed.
  --     0338 REPOINTED: the phase is no longer the bare constant 0336 passed. It comes from
  --     combat_wave_arrival_phase, THE one authority for which way a wave arrives from, composed
  --     here with the SAME four arguments the tick composes it with — the engagement anchor and the
  --     encounter's own site. Composing the leaf rather than re-deriving the angle is deliberate:
  --     check (4) below is what independently pins the leaf's ANSWER to the city.
  select count(*) into n_match
    from public.combat_units u9
   where u9.encounter_id = v_enc and u9.side = 'enemy'
     and exists (select 1 from generate_series(0, n_units - 1) as gs(k),
                      lateral public.combat_formation_point(ax, ay, v_rad, gs.k,
                                public.combat_wave_arrival_phase(ax, ay, sx, sy, gs.k)) fp
                  where abs(fp.x - u9.pos_x) <= 1e-6 and abs(fp.y - u9.pos_y) <= 1e-6);
  if n_match <> n_units then
    raise exception 'WAVERING FAIL: only % of % pirate(s) sit on a slot of combat_formation_point(anchor, %, k, the arrival phase) — the wave was not laid out by the one formation authority the player escort ring also composes',
      n_match, n_units, v_rad;
  end if;

  -- (4) AND IT CAME OUT OF THE CITY (0338). The owner: "make the enemy come out from the city of the
  --     zone. for example snare." The zone's settlement is combat_encounters.location_id, carried
  --     from danger_zones.location_id by the ambush path. EXACTLY ONE pirate must stand on the point
  --     where the ray from the engagement anchor toward that city crosses the wave's measured radius
  --     — that is what "they came out of the city" means geometrically, and the expected point is
  --     computed HERE from cos/sin of the site bearing, independently of the leaf, so this assert
  --     cannot be satisfied by a leaf that agrees with itself.
  --     RED ON 0336: the wave stood on a bearing fixed to the world x axis, which coincides with the
  --     ray to the site only for a site that happens to lie in that direction.
  c_x := ax + v_rad * cos(atan2(sy - ay, sx - ax));
  c_y := ay + v_rad * sin(atan2(sy - ay, sx - ax));
  select count(*) into n_slot0
    from public.combat_units u0
   where u0.encounter_id = v_enc and u0.side = 'enemy'
     and abs(u0.pos_x - c_x) <= 1e-6 and abs(u0.pos_y - c_y) <= 1e-6;
  if n_slot0 <> 1 then
    raise exception 'WAVERING FAIL: % pirate(s) stand where the ray from the engagement anchor (%,%) toward the zone''s city (%,%) crosses the wave radius % — want exactly 1. The wave must COME OUT OF THE CITY; a wave whose bearing has nothing to do with its site is the pre-0338 body',
      n_slot0, ax, ay, sx, sy, round(v_rad::numeric, 6);
  end if;

  -- (5) AND IT IS AN ARC FACING THE CITY, NOT AN ENCIRCLEMENT. The fan opens half a slot at a time
  --     either side of the city bearing, so a wave of n units reaches at most n/4 slots off it. A
  --     whole-slot fan — or no fan at all — would let a six-pirate wave wrap most of the circle and
  --     stand BEHIND the fleet, which is the opposite of coming out of the city.
  select count(*) into n_wide
    from public.combat_units u1
   where u1.encounter_id = v_enc and u1.side = 'enemy'
     and abs(atan2(sin(atan2(u1.pos_y - ay, u1.pos_x - ax) - atan2(sy - ay, sx - ax)),
                   cos(atan2(u1.pos_y - ay, u1.pos_x - ax) - atan2(sy - ay, sx - ax))))
         > (n_units::double precision / 4.0) * (pi() / 4.0) + 1e-9;
  if n_wide <> 0 then
    raise exception 'WAVERING FAIL: % of % pirate(s) stand more than % slot(s) off the bearing to the city — the wave is encircling the fleet rather than arriving from the settlement that sent it',
      n_wide, n_units, round((n_units / 4.0)::numeric, 4);
  end if;

  perform public.set_game_config('spatial_formation_ring_radius',        to_jsonb(k_ring));
  perform public.set_game_config('enemy_hp_base',                        to_jsonb(k_ehp));
  perform public.set_game_config('enemy_synthetic_speed_base',           to_jsonb(k_esb));
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', to_jsonb(k_esp));

  raise notice 'DZCOMBAT_PASS_WAVERING ok: a %-pirate wave arrived on % DISTINCT points, every one of them exactly % from the engagement anchor (never ON it) and every one of them reproduced by combat_formation_point at the arrival phase on a slot no other unit used — the head planted all % on the anchor itself (1 distinct point, radius 0); and (0338) it CAME OUT OF THE CITY: exactly one pirate stands where the ray from the anchor (%,%) toward the zone''s own settlement (%,%) crosses that radius, with the whole wave inside a % -slot arc of that bearing rather than encircling the fleet',
    n_units, n_distinct, round(v_rad::numeric, 6), n_units,
    round(ax::numeric, 3), round(ay::numeric, 3), round(sx::numeric, 3), round(sy::numeric, 3),
    round((n_units / 4.0)::numeric, 4);
end $$;

-- ════════ DZCOMBAT_PASS_NODIRECTION (0338): NO DIRECTION TO COME FROM FALLS BACK TO 0336'S RING ══════
-- THE OTHER HALF OF 0338, and the half a green origin assert cannot cover. 0338 makes a wave arrive
-- on the bearing from the fight to the zone's own city. Some fights HAVE no such bearing, and they
-- must fail to something sensible — never to a pile, never to a NULL coordinate, never to a raise
-- inside the tick.
-- ██ REPOINTED BY 0339, BECAUSE 0339 DELIBERATELY DESTROYS THIS BLOCK'S ORIGINAL PREMISE ██
-- 0338 staged the no-direction case as "a deliberate hunt at the site", because
-- combat_create_encounter handed the creator `l.x, l.y` for any fleet not in open space — so a hunt
-- fight was anchored ON its city and had no bearing. THAT WAS THE OWNER'S BUG ("The enemy ships are
-- not comming out from the location - snare"): it made 0338 inert on EVERY hunt, permanently. 0339
-- fixes it by standing a site fight off the site at its own territory_radius, so a hunt now HAS a
-- direction and this block can no longer reach the fallback that way.
-- THE FALLBACK STILL EXISTS AND STILL MATTERS, so it is staged through the arm 0339 itself defines:
-- A SITE WITH NO TERRITORY RADIUS HAS NO EDGE TO STAND OFF, so combat_site_standoff_point answers
-- the site itself, the fight anchors on it, and there is no direction to arrive from. The block
-- BORROWS locations.territory_radius for its own site and gives it back (the RSFEEL idiom), so it
-- owns that precondition rather than inheriting it — and it is now ALSO the only runtime proof of
-- 0339's own fail-closed arm. Everything below is 0338's, unchanged: the fallback must be the
-- predecessor, value for value.
-- THE GAME ANSWER IS STILL RIGHT: if you are fighting inside a city that claims no territory at all,
-- they come at you from all around.
-- The wave must then lay out on 0336's PLAIN RING, value for value: the same measured radius, the
-- same per-slot stepping, and 0336's own constant phase. That is the fallback being the predecessor
-- rather than a special case — and it is also the right game answer: if you are fighting inside the
-- city, they come at you from all around.
-- THE OTHER FALLBACK — an encounter with NO linked site at all — cannot be staged through any real
-- verb, and saying so is more honest than manufacturing it: a zone with no settlement never opens a
-- fight (pirate_intercept_resolve_due_for_movement answers 'standalone_zone_stub_forced_stop' and
-- creates no encounter). Migration 0338 EXECUTES that case instead, over sixteen slots, in assert (c).
do $$
declare
  r jsonb; n int; n_exp int; n_match int; n_null int; n_distinct int; n_units int;
  uN2 uuid; sN2 uuid; gN2 uuid;
  v_hunt uuid := (select v from dzc where k='v_hunt');
  lx double precision; ly double precision;
  v_mv uuid; v_enc uuid; mv record;
  ax double precision; ay double precision;
  v_rad double precision; v_rmin double precision; v_rmax double precision;
  k_ehp double precision; k_esb double precision; k_esp double precision;
  k_trad numeric;
begin
  select coalesce(public.cfg_num('enemy_hp_base'), 14)                          into k_ehp;
  select coalesce(public.cfg_num('enemy_synthetic_speed_base'), 0.6)            into k_esb;
  select coalesce(public.cfg_num('enemy_synthetic_speed_per_difficulty'), 0.04) into k_esp;
  -- Same staging law as WAVERING: the wave spawns and then MOVES inside the same tick, so a block
  -- about where a wave ARRIVES must freeze the close arm. hp is raised so nothing dies mid-measure.
  perform public.set_game_config('enemy_synthetic_speed_base',           '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', '0'::jsonb);
  perform public.set_game_config('enemy_hp_base',                        '100000'::jsonb);

  select l.x, l.y into lx, ly from public.locations l where l.id = v_hunt;
  if lx is null or ly is null then
    raise exception 'NODIRECTION FAIL: the shared hunt site carries no coordinate — the anchor-equals-site precondition cannot be established';
  end if;

  -- ── 0339: BORROW THE SITE'S TERRITORY RADIUS, AND GIVE IT BACK. ────────────────────────────────
  -- The no-direction case is now exactly "a site with no edge to stand off". This block OWNS that
  -- precondition instead of inheriting it from whatever 0217 happened to seed, and the non-vacuity
  -- guard beneath it is the one that matters: if the site DOES carry a radius when the fight opens,
  -- 0339 stands the fight off it, there IS a bearing, and every fallback assert below would be
  -- measuring the wrong world.
  select l.territory_radius into k_trad from public.locations l where l.id = v_hunt;
  if k_trad is null then
    raise exception 'NODIRECTION FAIL fixture: the shared hunt site already carries NO territory radius — this block must borrow a real one and give it back, or it is not proving that 0339''s fail-closed arm is what produced the fallback';
  end if;
  update public.locations set territory_radius = null where id = v_hunt;

  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.nd.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uN2;
  insert into public.player_wallet (player_id, balance) values (uN2, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
  r := pg_temp.call_as(uN2, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'NODIRECTION FAIL: commission: %', r; end if;
  select main_ship_id into sN2 from public.main_ship_instances where player_id = uN2;
  r := pg_temp.call_as(uN2, 'public.upsert_ship_group(1, ''No Direction'')');
  if (r->>'ok')::boolean is not true then raise exception 'NODIRECTION FAIL: group: %', r; end if;
  gN2 := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uN2, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sN2, gN2));
  if (r->>'ok')::boolean is not true then raise exception 'NODIRECTION FAIL: assign: %', r; end if;
  r := pg_temp.call_as(uN2, format('public.set_fleet_command_ship(%L::uuid, true)', sN2));
  if (r->>'ok')::boolean is not true then raise exception 'NODIRECTION FAIL: command ship: %', r; end if;
  r := pg_temp.call_as(uN2, format('public.set_group_auto_exit(%L::uuid, false, 30)', gN2));
  if (r->>'ok')::boolean is not true then raise exception 'NODIRECTION FAIL: auto-exit off: %', r; end if;

  -- ── A REAL HUNT, through the real verb — the fight is AT the site, not on a leg through a zone. ──
  r := pg_temp.call_as(uN2, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gN2, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'NODIRECTION FAIL: hunt send: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id into v_enc from public.combat_encounters
   where player_id = uN2 and status = 'active' order by created_at desc limit 1;
  if v_enc is null then raise exception 'NODIRECTION FAIL: the hunt arrival opened no encounter'; end if;

  -- ── THE PRECONDITION THIS BLOCK OWNS: the anchor IS the site. If a future creator ever stops
  -- ── anchoring a site fight on its site, this block is measuring the wrong thing and must say so.
  select engagement_x, engagement_y into ax, ay from public.combat_encounters where id = v_enc;
  if ax is null or ay is null then
    raise exception 'NODIRECTION FAIL: the site fight carries no engagement anchor — every geometry comparison below would be NULL and pass silently';
  end if;
  if abs(ax - lx) > 1e-6 or abs(ay - ly) > 1e-6 then
    raise exception 'NODIRECTION FAIL: the site fight is anchored at (%,%) but its site is at (%,%) — there IS a direction to arrive from, so this block is no longer staging the no-direction fallback at all',
      ax, ay, lx, ly;
  end if;

  -- a wave of at least THREE, for the same reason WAVERING needs one: a point cannot be told from a
  -- ring, and two points cannot be told from a line. DERIVED from the tick's own danger formula.
  update public.combat_encounters set started_at = started_at - interval '600 seconds' where id = v_enc;
  n_exp := least(coalesce(public.cfg_num('enemy_synthetic_max_units'), 6)::int,
                 greatest(1, 1 + (select waves_cleared from public.combat_encounters where id = v_enc)
                            + floor(extract(epoch from (now() - (select started_at from public.combat_encounters where id = v_enc)))
                                    / coalesce(public.cfg_num('danger_time_divisor_seconds'), 180))::int));
  if n_exp < 3 then
    raise exception 'NODIRECTION FAIL: staging derives only % pirate(s) — with fewer than 3 a ring cannot be told apart from a point or a line', n_exp;
  end if;

  perform pg_temp.ae_tick(v_enc);
  select count(*) into n_units from public.combat_units where encounter_id = v_enc and side = 'enemy';
  if n_units <> n_exp then
    raise exception 'NODIRECTION FAIL: % pirate unit(s) spawned (want the danger-derived %)', n_units, n_exp;
  end if;
  select count(*) into n_null from public.combat_units
   where encounter_id = v_enc and side = 'enemy' and (pos_x is null or pos_y is null);
  if n_null <> 0 then
    raise exception 'NODIRECTION FAIL: % of % pirate(s) carry a NULL coordinate — the fallback must produce a ring, never a NULL', n_null, n_units;
  end if;

  -- (1) STILL NOT A PILE. The fallback is 0336, and 0336's whole point is that a wave is n points.
  select count(distinct (pos_x, pos_y)) into n_distinct
    from public.combat_units where encounter_id = v_enc and side = 'enemy';
  if n_distinct <> n_units then
    raise exception 'NODIRECTION FAIL: % pirate(s) occupy only % distinct position(s) — falling back must not fall back to the pile',
      n_units, n_distinct;
  end if;

  -- (2) ONE MEASURED RADIUS, nobody on the anchor — the radius is never assumed here either.
  select min(public.osn_distance(ax, ay, pos_x, pos_y)),
         max(public.osn_distance(ax, ay, pos_x, pos_y))
    into v_rmin, v_rmax
    from public.combat_units where encounter_id = v_enc and side = 'enemy';
  if v_rmin is null or v_rmax is null then
    raise exception 'NODIRECTION FAIL: the wave radius measured NULL — every assert here would be vacuous';
  end if;
  if v_rmin <= 0 then
    raise exception 'NODIRECTION FAIL: a pirate stands % from the anchor — the fallback is planting the wave on the anchor itself', v_rmin;
  end if;
  if abs(v_rmax - v_rmin) > 1e-6 then
    raise exception 'NODIRECTION FAIL: the wave spans radii % to % — it is not one ring', v_rmin, v_rmax;
  end if;
  v_rad := v_rmin;

  -- (3) AND IT IS 0336'S RING, VALUE FOR VALUE — the constant phase, not the arrival bearing. This
  --     is the assert that makes "the fallback is the predecessor" a fact rather than a claim.
  select count(*) into n_match
    from public.combat_units u8
   where u8.encounter_id = v_enc and u8.side = 'enemy'
     and exists (select 1 from generate_series(0, n_units - 1) as gs(k),
                      lateral public.combat_formation_point(ax, ay, v_rad, gs.k, 0.5) fp
                  where abs(fp.x - u8.pos_x) <= 1e-6 and abs(fp.y - u8.pos_y) <= 1e-6);
  if n_match <> n_units then
    raise exception 'NODIRECTION FAIL: only % of % pirate(s) sit on 0336''s plain ring — a fight with no direction to come from must fall back to the predecessor exactly, not to some third layout',
      n_match, n_units;
  end if;

  -- (4) AND THE LEAF ITSELF SAYS SO, at exactly the arguments the tick composes it with.
  for n in 0 .. n_units - 1 loop
    if public.combat_wave_arrival_phase(ax, ay, lx, ly, n) is distinct from 0.5 then
      raise exception 'NODIRECTION FAIL: with the anchor standing on the site the arrival leaf answered % at slot % — it must answer 0336''s own constant',
        public.combat_wave_arrival_phase(ax, ay, lx, ly, n), n;
    end if;
  end loop;

  perform public.set_game_config('enemy_hp_base',                        to_jsonb(k_ehp));
  perform public.set_game_config('enemy_synthetic_speed_base',           to_jsonb(k_esb));
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', to_jsonb(k_esp));
  -- give the radius back: every block after this one shares this site, and a leaked NULL would
  -- silently repoint THEIR geometry to the pre-0339 world (the 0336 formation-ring leak lesson).
  update public.locations set territory_radius = k_trad where id = v_hunt;

  raise notice 'DZCOMBAT_PASS_NODIRECTION ok: a HUNT at a site that claims NO territory (0339: no edge to stand off) anchors its fight on the site itself (anchor %,% = site %,%), so there is no direction for a wave to arrive FROM — and the %-pirate wave fell back to 0336''s plain ring exactly: % distinct points, all at one measured radius of %, every one reproduced by combat_formation_point at 0336''s own constant phase, and the arrival leaf answering that constant at every slot. The fallback is the predecessor, not a special case, and it is still not a pile',
    round(ax::numeric, 3), round(ay::numeric, 3), round(lx::numeric, 3), round(ly::numeric, 3),
    n_units, n_distinct, round(v_rad::numeric, 6);
end $$;

-- ════════ DZCOMBAT_PASS_RETREATNOSPAWN (0336): PRESSING RETREAT DOES NOT SUMMON A BIGGER WAVE ═══════
-- THE DEFECT, RED BY CONSTRUCTION BELOW, and the most expensive of the eight in real money. The
-- offense gate silences the PLAYER while a fleet is retreating; the enemy side is never gated, by
-- design. But the wave-SPAWN block carried no status guard at all — so a player who cleared a wave
-- and then pressed Retreat was handed a FRESH, LARGER wave (danger rises with waves_cleared) which
-- then shot at a fleet that could not shoot back for the rest of the window. Production carries four
-- encounters that died exactly that way, 3.4 to 5.8 seconds into an 8-second window, and a death is
-- a 'defeat', which zeroes total_rewards_json: the entire haul, destroyed by pressing Retreat.
-- THE STAGING: clear the wave for real (the player's own gun, sized from the fight's own numbers),
-- press Retreat through the REAL path the button uses (request_retreat -> presence_request_leave ->
-- combat_set_retreating), then tick.
-- THE VACUITY GUARD THAT MATTERS MOST: wave_transition_seconds is pulled to 0 and `now() >=
-- next_wave_at` is ASSERTED before the retreat tick. Without it the head would take the
-- next_wave_incoming pause instead of the spawn, and this block would go green on the defect.
do $$
declare
  r jsonb; n int; n_exp int;
  uN uuid; sN uuid; gN uuid;
  o_x double precision; o_y double precision;
  v_hunt uuid := (select v from dzc where k='v_hunt');
  v_mv uuid; v_enc uuid; v_pres uuid; mv record; pi record; enc record;
  v_pw double precision; v_pool double precision; v_pdef double precision;
  v_defb double precision; v_bd double precision; v_danger int;
  v_hpsc double precision; v_atksc double precision; v_uhp double precision;
  v_tick int; v_wc0 int; v_wn0 int; v_rows0 int; v_nwa timestamptz;
  n_spawned int; n_live int;
  k_ring double precision; k_ehp double precision; k_eatk double precision;
  k_erb double precision; k_erp double precision; k_esb double precision; k_esp double precision;
  k_wts double precision;
begin
  select coalesce(public.cfg_num('spatial_formation_ring_radius'), 30)          into k_ring;
  select coalesce(public.cfg_num('enemy_hp_base'), 14)                          into k_ehp;
  select coalesce(public.cfg_num('enemy_attack_base'), 1.0)                     into k_eatk;
  select coalesce(public.cfg_num('enemy_synthetic_range_base'), 3.6)            into k_erb;
  select coalesce(public.cfg_num('enemy_synthetic_range_per_difficulty'), 0.04) into k_erp;
  select coalesce(public.cfg_num('enemy_synthetic_speed_base'), 0.6)            into k_esb;
  select coalesce(public.cfg_num('enemy_synthetic_speed_per_difficulty'), 0.04) into k_esp;
  select coalesce(public.cfg_num('wave_transition_seconds'), 3)                 into k_wts;
  perform public.set_game_config('spatial_formation_ring_radius',        '1'::jsonb);
  perform public.set_game_config('enemy_synthetic_range_base',           '0.1'::jsonb);
  perform public.set_game_config('enemy_synthetic_range_per_difficulty', '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_base',           '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', '0'::jsonb);
  -- THE TRANSITION PAUSE IS CLOSED. now() is frozen for the txn, so ANY positive transition window
  -- would still be open on the next tick and the head would take the next_wave_incoming branch —
  -- which spawns nothing, passes every assert below, and proves precisely nothing about the guard
  -- this block exists to test.
  perform public.set_game_config('wave_transition_seconds',              '0'::jsonb);

  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.rn.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uN;
  insert into public.player_wallet (player_id, balance) values (uN, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
  r := pg_temp.call_as(uN, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'RETREATNOSPAWN FAIL: commission: %', r; end if;
  select main_ship_id into sN from public.main_ship_instances where player_id = uN;
  r := pg_temp.call_as(uN, 'public.upsert_ship_group(1, ''Retreat No Spawn'')');
  if (r->>'ok')::boolean is not true then raise exception 'RETREATNOSPAWN FAIL: group: %', r; end if;
  gN := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uN, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sN, gN));
  if (r->>'ok')::boolean is not true then raise exception 'RETREATNOSPAWN FAIL: assign: %', r; end if;
  r := pg_temp.call_as(uN, format('public.set_fleet_command_ship(%L::uuid, true)', sN));
  if (r->>'ok')::boolean is not true then raise exception 'RETREATNOSPAWN FAIL: command ship: %', r; end if;
  r := pg_temp.call_as(uN, format('public.set_group_auto_exit(%L::uuid, false, 30)', gN));
  if (r->>'ok')::boolean is not true then raise exception 'RETREATNOSPAWN FAIL: auto-exit off: %', r; end if;
  select l.x, l.y into o_x, o_y
    from public.main_ship_instances s
    join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = uN and f.status = 'present'
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
    join public.locations l on l.id = lp.location_id
   where s.group_id = gN
   limit 1;
  if o_x is null then raise exception 'RETREATNOSPAWN FAIL: could not resolve the docked origin'; end if;
  r := pg_temp.call_as(uN, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gN, round(o_x), round(o_y + 1000)));
  if (r->>'ok')::boolean is not true then raise exception 'RETREATNOSPAWN FAIL: go: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if pi is null then raise exception 'RETREATNOSPAWN FAIL: no pending ambush on the leg'; end if;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id, presence_id into v_enc, v_pres from public.combat_encounters
   where player_id = uN and status = 'active';
  if v_enc is null then raise exception 'RETREATNOSPAWN FAIL: the ambush opened no encounter'; end if;

  -- size the ONE pirate of a fresh (danger 1) wave to die to a single player shot.
  select max((w->>'power')::double precision) into v_pw
    from public.combat_units cu9, jsonb_array_elements(cu9.weapons_json) w
   where cu9.encounter_id = v_enc and cu9.side = 'player';
  select hp_current + coalesce(shield_current, 0), coalesce(defense_snapshot, 0)
    into v_pool, v_pdef from public.combat_units where encounter_id = v_enc and side = 'player';
  v_defb := coalesce(public.cfg_num('defense_curve_base'), 100);
  select l.base_difficulty into v_bd
    from public.combat_encounters ce join public.locations l on l.id = ce.location_id where ce.id = v_enc;
  if v_pw is null or v_pw <= 0 or v_pool is null or v_pool <= 0 or v_bd is null or v_bd <= 0 or v_defb <= 0 then
    raise exception 'RETREATNOSPAWN FAIL: weapon power % / hull pool % / base_difficulty % / defense base % cannot size the wave', v_pw, v_pool, v_bd, v_defb;
  end if;
  v_danger := 1 + (select waves_cleared from public.combat_encounters where id = v_enc)
              + floor(extract(epoch from (now() - (select started_at from public.combat_encounters where id = v_enc)))
                      / coalesce(public.cfg_num('danger_time_divisor_seconds'), 180))::int;
  n_exp := least(coalesce(public.cfg_num('enemy_synthetic_max_units'), 6)::int, greatest(1, v_danger));
  -- 0341: the inverse of the engine's sizing is now (1 + scale) * bodies. See DEADFIRE arm A above.
  v_hpsc  := (1 + coalesce(public.cfg_num('enemy_hp_danger_scale'), 0.6)) * n_exp;
  v_atksc := (1 + coalesce(public.cfg_num('enemy_attack_danger_scale'), 0.25)) * n_exp;
  perform public.set_game_config('enemy_hp_base',
    to_jsonb(round(((0.5 * v_pw * n_exp) / (v_bd * v_hpsc))::numeric, 9)));
  perform public.set_game_config('enemy_attack_base',
    to_jsonb(round((((0.02 * v_pool) * ((v_defb + v_pdef) / v_defb)) / (v_bd * v_atksc))::numeric, 9)));

  -- ── TICK 1: the wave spawns and the player CLEARS it. ───────────────────────────────────────────
  perform pg_temp.ae_tick(v_enc);
  select * into enc from public.combat_encounters where id = v_enc;
  select max(ship_hp) into v_uhp from public.combat_units where encounter_id = v_enc and side = 'enemy';
  if v_uhp is null or v_uhp >= v_pw then
    raise exception 'RETREATNOSPAWN FAIL: a pirate carries % hull against a shot of % — the wave was not sized to clear in one tick and the whole scenario below is a different fight', v_uhp, v_pw;
  end if;
  select count(*) into n_live from public.combat_units
   where encounter_id = v_enc and side = 'enemy' and alive_count > 0;
  if n_live <> 0 or enc.waves_cleared <> 1 then
    raise exception 'RETREATNOSPAWN FAIL: after the opening tick % pirate(s) are still alive and waves_cleared is % (want 0 and 1) — the wave was never cleared, so the spawn branch this block tests would not be reached on ANY body', n_live, enc.waves_cleared;
  end if;
  v_nwa := enc.next_wave_at;
  if v_nwa is null or now() < v_nwa then
    raise exception 'RETREATNOSPAWN FAIL: the next wave is scheduled at % and now() is % — the transition window is still OPEN, so the head would take the next_wave_incoming pause instead of the spawn and this block would be green on the defect',
      v_nwa, now();
  end if;

  -- ── PRESS RETREAT — the real button path, not a status write. ───────────────────────────────────
  r := pg_temp.call_as(uN, format('public.request_retreat(%L::uuid)', v_pres));
  if r is null then raise exception 'RETREATNOSPAWN FAIL: request_retreat returned nothing'; end if;
  select * into enc from public.combat_encounters where id = v_enc;
  if enc.status <> 'retreating' or enc.retreat_started_at is null then
    raise exception 'RETREATNOSPAWN FAIL: the encounter is %/% after request_retreat — the retreating state this block tests was never entered', enc.status, enc.retreat_started_at;
  end if;
  v_wc0 := enc.waves_cleared; v_wn0 := enc.wave_number;
  select count(*) into v_rows0 from public.combat_units where encounter_id = v_enc and side = 'enemy';

  -- ── THE RETREAT TICK. On the head this is where the fresh, larger wave arrives. ─────────────────
  perform pg_temp.ae_tick(v_enc);
  select * into enc from public.combat_encounters where id = v_enc;
  v_tick := enc.tick_number;
  -- the window must still be OPEN, or the tick took the completion branch and never reached the
  -- spawn block at all — which would make every assert below vacuous.
  if enc.status <> 'retreating' then
    raise exception 'RETREATNOSPAWN FAIL: the encounter reached % on the retreat tick — it completed instead of running the combat step, so the spawn guard under test was never evaluated', enc.status;
  end if;
  select count(*) into n_spawned from public.combat_events
   where encounter_id = v_enc and tick_number = v_tick and event_type = 'wave_spawned';
  if n_spawned <> 0 then
    raise exception 'RETREATNOSPAWN FAIL: % wave_spawned event(s) fired on the retreat tick — pressing Retreat summoned a fresh wave at a fleet that cannot shoot back, and a death inside the window zeroes the whole haul', n_spawned;
  end if;
  select count(*) into n from public.combat_units where encounter_id = v_enc and side = 'enemy';
  if n <> v_rows0 then
    raise exception 'RETREATNOSPAWN FAIL: the enemy side went from % row(s) to % across the retreat tick — the spawn arm deleted the cleared wave and inserted a new one', v_rows0, n;
  end if;
  select count(*) into n_live from public.combat_units
   where encounter_id = v_enc and side = 'enemy' and alive_count > 0;
  if n_live <> 0 then
    raise exception 'RETREATNOSPAWN FAIL: % living pirate(s) exist after the retreat tick (want 0) — a retreating fleet was sent something to be shot by', n_live;
  end if;
  if enc.waves_cleared <> v_wc0 or enc.wave_number <> v_wn0 then
    raise exception 'RETREATNOSPAWN FAIL: waves_cleared % -> % and wave_number % -> % across the retreat tick — the wave counter advanced, which only happens when a new wave was raised',
      v_wc0, enc.waves_cleared, v_wn0, enc.wave_number;
  end if;

  perform public.set_game_config('spatial_formation_ring_radius',        to_jsonb(k_ring));
  perform public.set_game_config('enemy_hp_base',                        to_jsonb(k_ehp));
  perform public.set_game_config('enemy_attack_base',                    to_jsonb(k_eatk));
  perform public.set_game_config('enemy_synthetic_range_base',           to_jsonb(k_erb));
  perform public.set_game_config('enemy_synthetic_range_per_difficulty', to_jsonb(k_erp));
  perform public.set_game_config('enemy_synthetic_speed_base',           to_jsonb(k_esb));
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', to_jsonb(k_esp));
  perform public.set_game_config('wave_transition_seconds',              to_jsonb(k_wts));

  raise notice 'DZCOMBAT_PASS_RETREATNOSPAWN ok: the fleet cleared its wave (waves_cleared %), the transition window was PROVEN closed (next wave due %, now %), Retreat was pressed through the real request_retreat path — and the retreat tick raised NO wave_spawned event, left the enemy side at % row(s) and 0 living units, and moved neither waves_cleared (%) nor wave_number (%): on the head this is where a bigger wave arrived to shoot at a fleet that could not shoot back',
    v_wc0, v_nwa, now(), v_rows0, enc.waves_cleared, enc.wave_number;
end $$;

-- ════════ DZCOMBAT_PASS_WAVEBAND (0341): ONE MORE PIRATE EVERY FIVE ROUNDS, NOT EVERY ROUND ════════
-- THE OWNER, VERBATIM: "right each round? new fleets are made and fight is made +1, meaning 1 ship,
-- 2 ships, 3 ships and so on. Reduce this. round 1~5 should be only 1, then round 5~10 should be 2."
-- This block runs that sentence through the REAL tick at the SHIPPED band of 5 — the one place in
-- the suite where the band is not pulled to 1 — and reads the answer off combat_units.
-- RED ON THE PRE-0341 BODY BY CONSTRUCTION: on the head, round 3 arrives with THREE pirates and this
-- block fails at the first band it checks. The final pin makes that explicit rather than implicit —
-- at least one observed round must disagree with the pre-0341 rule, or the walk proved nothing.
-- THE STAGING ISOLATES THE COUNT AND NOTHING ELSE. enemy_hp_danger_scale is pulled to 0 so every
-- pirate in every round is the SAME size (one player shot), which makes the only thing that can move
-- across eleven rounds the number of bodies. Pirates are frozen (speed 0) at a 0.1 reach and deal no
-- damage, so the fleet is immortal, no terminal arm can fire, and the walk cannot end early.
-- wave_transition_seconds is 0 because now() is frozen: any positive window would leave the tick
-- taking the next_wave_incoming pause forever and the walk would never see round 2.
do $$
declare
  r jsonb; n int; w int; guard int; v_expect int; v_cap int; v_band double precision;
  uW uuid; sW uuid; gW uuid;
  o_x double precision; o_y double precision;
  v_mv uuid; v_enc uuid; mv record; pi record; enc record;
  v_pw double precision; v_bd double precision; v_uhp double precision;
  v_seen int[] := '{}'; v_old int; n_differ int := 0;
  k_ring double precision; k_ehp double precision; k_ehds double precision; k_eatk double precision;
  k_erb double precision; k_erp double precision; k_esb double precision; k_esp double precision;
  k_wts double precision; k_band double precision;
begin
  select coalesce(public.cfg_num('spatial_formation_ring_radius'), 30)          into k_ring;
  select coalesce(public.cfg_num('enemy_hp_base'), 14)                          into k_ehp;
  select coalesce(public.cfg_num('enemy_hp_danger_scale'), 0.6)                 into k_ehds;
  select coalesce(public.cfg_num('enemy_attack_base'), 1.0)                     into k_eatk;
  select coalesce(public.cfg_num('enemy_synthetic_range_base'), 3.6)            into k_erb;
  select coalesce(public.cfg_num('enemy_synthetic_range_per_difficulty'), 0.04) into k_erp;
  select coalesce(public.cfg_num('enemy_synthetic_speed_base'), 0.6)            into k_esb;
  select coalesce(public.cfg_num('enemy_synthetic_speed_per_difficulty'), 0.04) into k_esp;
  select coalesce(public.cfg_num('wave_transition_seconds'), 3)                 into k_wts;
  select coalesce(public.cfg_num('enemy_synthetic_units_per_danger_band'), 5)   into k_band;

  -- THE ONE BLOCK THAT RUNS THE SHIPPED BAND. Taken from dzc_deployed — the value read off
  -- game_config BEFORE the global tuning pinned it to 1 — so this asserts what the migration
  -- DEPLOYED, not what this file would like it to be.
  select wave_band into v_band from dzc_deployed;
  if v_band is distinct from 5 then
    raise exception 'WAVEBAND FAIL: the deployed band is % — 0341 ships 5, and the owner''s "round 1~5 / round 5~10" sentence is a statement about that number', v_band;
  end if;
  perform public.set_game_config('enemy_synthetic_units_per_danger_band', to_jsonb(v_band));
  v_cap := coalesce(public.cfg_num('enemy_synthetic_max_units'), 6)::int;
  if v_cap < 3 then
    raise exception 'WAVEBAND FAIL: the unit cap is % — below 3 the third band cannot be told apart from the second and this walk is vacuous', v_cap;
  end if;

  perform public.set_game_config('spatial_formation_ring_radius',        '1'::jsonb);
  perform public.set_game_config('enemy_synthetic_range_base',           '0.1'::jsonb);
  perform public.set_game_config('enemy_synthetic_range_per_difficulty', '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_base',           '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', '0'::jsonb);
  perform public.set_game_config('enemy_attack_base',                    '0'::jsonb);
  perform public.set_game_config('enemy_hp_danger_scale',                '0'::jsonb);
  perform public.set_game_config('wave_transition_seconds',              '0'::jsonb);

  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.wb.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uW;
  insert into public.player_wallet (player_id, balance) values (uW, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
  r := pg_temp.call_as(uW, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'WAVEBAND FAIL: commission: %', r; end if;
  select main_ship_id into sW from public.main_ship_instances where player_id = uW;
  r := pg_temp.call_as(uW, 'public.upsert_ship_group(1, ''Wave Band'')');
  if (r->>'ok')::boolean is not true then raise exception 'WAVEBAND FAIL: group: %', r; end if;
  gW := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uW, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sW, gW));
  if (r->>'ok')::boolean is not true then raise exception 'WAVEBAND FAIL: assign: %', r; end if;
  r := pg_temp.call_as(uW, format('public.set_fleet_command_ship(%L::uuid, true)', sW));
  if (r->>'ok')::boolean is not true then raise exception 'WAVEBAND FAIL: command ship: %', r; end if;
  r := pg_temp.call_as(uW, format('public.set_group_auto_exit(%L::uuid, false, 30)', gW));
  if (r->>'ok')::boolean is not true then raise exception 'WAVEBAND FAIL: auto-exit off: %', r; end if;
  select l.x, l.y into o_x, o_y
    from public.main_ship_instances s
    join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = uW and f.status = 'present'
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
    join public.locations l on l.id = lp.location_id
   where s.group_id = gW
   limit 1;
  if o_x is null then raise exception 'WAVEBAND FAIL: could not resolve the docked origin'; end if;
  r := pg_temp.call_as(uW, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gW, round(o_x), round(o_y + 1000)));
  if (r->>'ok')::boolean is not true then raise exception 'WAVEBAND FAIL: go: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if pi is null then raise exception 'WAVEBAND FAIL: no pending ambush on the leg'; end if;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id into v_enc from public.combat_encounters where player_id = uW and status = 'active';
  if v_enc is null then raise exception 'WAVEBAND FAIL: the ambush opened no encounter'; end if;

  -- EVERY PIRATE DIES TO ONE SHOT, IN EVERY ROUND. With enemy_hp_danger_scale pinned at 0 the engine's
  -- per-pirate hp is base_difficulty * enemy_hp_base flat, so this one number holds for all eleven.
  select max((wj->>'power')::double precision) into v_pw
    from public.combat_units cu9, jsonb_array_elements(cu9.weapons_json) wj
   where cu9.encounter_id = v_enc and cu9.side = 'player';
  select l.base_difficulty into v_bd
    from public.combat_encounters ce join public.locations l on l.id = ce.location_id where ce.id = v_enc;
  if v_pw is null or v_pw <= 0 or v_bd is null or v_bd <= 0 then
    raise exception 'WAVEBAND FAIL: weapon power % / base_difficulty % cannot size the wave', v_pw, v_bd;
  end if;
  perform public.set_game_config('enemy_hp_base', to_jsonb(round(((0.5 * v_pw) / v_bd)::numeric, 9)));

  -- ── THE WALK: eleven rounds, back to back, reading the size of each wave off the record. ────────
  -- THE WAVE IS COUNTED AFTER IT IS CLEARED, NOT WHILE IT STANDS, and that is deliberate: with the
  -- ring at 1 and the pirates' own reach at 0.1 the wave lands well inside the player's gun, so a
  -- ONE-body wave is spawned and destroyed inside a single tick and there is no moment at which it
  -- can be observed alive. Its rows survive as wrecks until the NEXT spawn deletes them, so counting
  -- them the instant waves_cleared reaches w reads exactly the wave that was just fought — and it
  -- reads the same number for a wave that took three ticks to kill.
  for w in 1 .. 11 loop
    guard := 0;
    loop
      select * into enc from public.combat_encounters where id = v_enc;
      exit when enc.waves_cleared >= w;
      if enc.status <> 'active' then
        raise exception 'WAVEBAND FAIL: the encounter reached % at round % — the walk ended early and the later bands are unobserved', enc.status, w;
      end if;
      perform pg_temp.ae_tick(v_enc);
      guard := guard + 1;
      if guard > 20 then
        select max(ship_hp) into v_uhp from public.combat_units where encounter_id = v_enc and side = 'enemy';
        raise exception 'WAVEBAND FAIL: round % did not clear within 20 ticks (a pirate carries % hull against a shot of %) — the walk stalled and every later round is unobserved', w, v_uhp, v_pw;
      end if;
    end loop;
    if enc.waves_cleared <> w then
      raise exception 'WAVEBAND FAIL: after round % the encounter reports % wave(s) cleared — the rounds and the danger have come apart', w, enc.waves_cleared;
    end if;
    -- danger comes from waves_cleared alone here: now() is frozen, so the time term is 0 and round w
    -- IS danger w. Asserted rather than assumed, because the whole table below is indexed by it.
    if enc.danger_level is distinct from w then
      raise exception 'WAVEBAND FAIL: round % ran at danger % — the time term moved and the band table below is indexed by the wrong number', w, enc.danger_level;
    end if;

    -- the wave that was just fought: every enemy row belongs to it until the next spawn deletes them
    select count(*) into n from public.combat_units where encounter_id = v_enc and side = 'enemy';
    v_seen := v_seen || n;

    -- THE OWNER'S SENTENCE, LITERALLY.
    if w between 1 and 5 then v_expect := 1;
    elsif w between 6 and 10 then v_expect := 2;
    else v_expect := 3;
    end if;
    if n <> v_expect then
      raise exception 'WAVEBAND FAIL: round % arrived with % pirate(s), want % — "round 1~5 should be only 1, then round 5~10 should be 2"', w, n, v_expect;
    end if;
    -- and it disagrees with the rule the head used, which is what makes this walk worth running
    v_old := least(v_cap, greatest(1, w));
    if n <> v_old then n_differ := n_differ + 1; end if;
  end loop;

  if n_differ = 0 then
    raise exception 'WAVEBAND FAIL: every one of the eleven rounds spawned exactly what the pre-0341 rule would have spawned — this walk is vacuous and would pass on the old body';
  end if;

  -- ── THE CAP STILL BINDS. The ceiling is tested by LOWERING IT, not by rewinding the clock past it.
  --    Deliberate: v_max_secs is coalesce(loc.max_presence_seconds, max_presence_seconds_default,
  --    1800), so the rewind needed to reach danger 30+ (3420s, five bands past the shipped cap of 6)
  --    would trip the FORCED EXTRACT and end the fight before the capped wave could be read — the
  --    block would then be green on an encounter that never spawned anything. Round 12 already asks
  --    the ramp for 3 bodies (ceil(12/5)); pulling the ceiling to 2 makes the cap the binding
  --    constraint with no clock manipulation at all, which is exactly the property under test.
  perform public.set_game_config('enemy_synthetic_max_units', '2'::jsonb);
  guard := 0;
  loop
    select * into enc from public.combat_encounters where id = v_enc;
    exit when enc.waves_cleared >= 12;
    if enc.status <> 'active' then
      raise exception 'WAVEBAND FAIL: the encounter reached % before the capped round could be read', enc.status;
    end if;
    perform pg_temp.ae_tick(v_enc);
    guard := guard + 1;
    if guard > 20 then raise exception 'WAVEBAND FAIL: the capped wave never cleared within 20 ticks'; end if;
  end loop;
  if ceil(enc.danger_level::double precision / v_band)::int <= 2 then
    raise exception 'WAVEBAND FAIL: at danger % the banded ramp asks for % bodies — at or under the lowered ceiling of 2, so the ceiling was never actually the binding constraint',
      enc.danger_level, ceil(enc.danger_level::double precision / v_band)::int;
  end if;
  select count(*) into n from public.combat_units where encounter_id = v_enc and side = 'enemy';
  if n <> 2 then
    raise exception 'WAVEBAND FAIL: at danger % the wave arrived with % pirate(s) — the ramp asked for % and enemy_synthetic_max_units was pulled to 2, so the ceiling must still bind',
      enc.danger_level, n, ceil(enc.danger_level::double precision / v_band)::int;
  end if;
  perform public.set_game_config('enemy_synthetic_max_units', to_jsonb(v_cap));

  perform public.set_game_config('spatial_formation_ring_radius',        to_jsonb(k_ring));
  perform public.set_game_config('enemy_hp_base',                        to_jsonb(k_ehp));
  perform public.set_game_config('enemy_hp_danger_scale',                to_jsonb(k_ehds));
  perform public.set_game_config('enemy_attack_base',                    to_jsonb(k_eatk));
  perform public.set_game_config('enemy_synthetic_range_base',           to_jsonb(k_erb));
  perform public.set_game_config('enemy_synthetic_range_per_difficulty', to_jsonb(k_erp));
  perform public.set_game_config('enemy_synthetic_speed_base',           to_jsonb(k_esb));
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', to_jsonb(k_esp));
  perform public.set_game_config('wave_transition_seconds',              to_jsonb(k_wts));
  perform public.set_game_config('enemy_synthetic_units_per_danger_band', to_jsonb(k_band));

  raise notice 'DZCOMBAT_PASS_WAVEBAND ok: eleven rounds walked through the real tick at the deployed band of 5 — bodies per round %, i.e. 1 for rounds 1-5, 2 for 6-10 and 3 for 11, with % of them disagreeing with the pre-0341 rule; and at danger % the ceiling still held the wave to 2 bodies where the ramp asked for % (the shipped ceiling is %)',
    v_seen, n_differ, enc.danger_level, ceil(enc.danger_level::double precision / v_band)::int, v_cap;
end $$;

-- ════════ DZCOMBAT_PASS_SLOWGUN (0341): A GUN CANNOT FIRE ON TWO CONSECUTIVE TICKS ═════════════════
-- THE OWNER, VERBATIM: "and make fire rate also slower, 2 times slower".
-- WHY THIS NEEDED A NEW SHAPE OF ASSERT. 0314 armed every weapon with now() + its own cooldown and
-- the readiness gate is now() >= next_ready_at — but combat_tick_seconds is 3 and every live cooldown
-- was 2 or 2.5, so the gate reopened every tick and the cooldown was INERT. 0341 doubles all four
-- (2 -> 4, 2.5 -> 5) which is the first time any of them exceeds the tick.
-- AND now() IS FROZEN FOR THIS WHOLE TRANSACTION, so "the next tick is silent" is true of ANY
-- positive cooldown and proves nothing about the 3-vs-4 boundary — RSFEEL's 3600s block already
-- passes on the old body. The assertion that CAN tell them apart is tick-RELATIVE: after a weapon
-- fires, is it still on cooldown at the moment the next tick will run? next_ready_at > now() + tick.
-- At 2s it is not (2 <= 3, ready); at 4s it is. That inequality is RED on the pre-0341 catalog and
-- on the pre-0341 knob, and it is asserted on BOTH sides: the DEPLOYED player catalog (which this
-- proof never touches) and a live pirate wave.
do $$
declare
  r jsonb; n int; i int; n_armed int; n_late int; n_alive2 int;
  uS uuid; sS uuid; gS uuid;
  o_x double precision; o_y double precision;
  v_mv uuid; v_enc uuid; mv record; pi record; enc record;
  v_pool double precision; v_pdef double precision; v_defb double precision; v_bd double precision;
  v_danger int; v_atksc double precision; n_exp int;
  v_tick_secs double precision; v_cd double precision; v_fired boolean := false; v_t1 int; v_t2 int;
  t_bat record; t_mk2 record;
  k_ecd double precision; k_ehp double precision; k_eatk double precision;
  k_esb double precision; k_esp double precision; k_ps double precision;
begin
  v_tick_secs := coalesce(public.cfg_num('combat_tick_seconds'), 3);
  if v_tick_secs is null or v_tick_secs <= 0 then
    raise exception 'SLOWGUN FAIL: combat_tick_seconds is % — no cadence can be derived from it', v_tick_secs;
  end if;

  -- ── (1) THE DEPLOYED PLAYER CATALOG. This file never writes module_types, so these are the values
  --    0341 shipped, read back. Two ticks to ready is exactly "half as often" against a 3s tick. ───
  select * into t_bat from public.module_types where id = 'autocannon_battery';
  select * into t_mk2 from public.module_types where id = 'autocannon_battery_mk2';
  if t_bat is null or t_mk2 is null then
    raise exception 'SLOWGUN FAIL: the compared guns are not in the catalog';
  end if;
  if t_bat.cooldown_seconds <= v_tick_secs or t_mk2.cooldown_seconds <= v_tick_secs then
    raise exception 'SLOWGUN FAIL: a fitted gun''s cooldown (% / %) is at or under the %s tick — the readiness gate reopens every tick and the gun fires exactly as often as it did before 0341',
      t_bat.cooldown_seconds, t_mk2.cooldown_seconds, v_tick_secs;
  end if;
  if ceil(t_bat.cooldown_seconds / v_tick_secs::numeric) <> 2
     or ceil(t_mk2.cooldown_seconds / v_tick_secs::numeric) <> 2 then
    raise exception 'SLOWGUN FAIL: the fitted guns need % and % ticks to become ready — the owner asked for TWICE as slow, which against a %s tick is exactly 2',
      ceil(t_bat.cooldown_seconds / v_tick_secs::numeric), ceil(t_mk2.cooldown_seconds / v_tick_secs::numeric), v_tick_secs;
  end if;

  -- ── (2) A LIVE PIRATE WAVE ARMS PAST THE NEXT TICK. ────────────────────────────────────────────
  select coalesce(public.cfg_num('enemy_synthetic_cooldown_seconds'), 2)       into k_ecd;
  select coalesce(public.cfg_num('enemy_hp_base'), 14)                         into k_ehp;
  select coalesce(public.cfg_num('enemy_attack_base'), 1.0)                    into k_eatk;
  select coalesce(public.cfg_num('enemy_synthetic_speed_base'), 0.6)           into k_esb;
  select coalesce(public.cfg_num('enemy_synthetic_speed_per_difficulty'), 0.04) into k_esp;
  select coalesce(public.cfg_num('combat_player_speed_scale'), 0.2)            into k_ps;
  -- The global staging above ZEROED this knob so the multi-tick fire blocks can run, so it cannot be
  -- read back here. It is restored to the value 0341 deploys — and that the DEPLOYED row really
  -- carries 4 is asserted by 0341's own self-assert (b), which runs in this same chain apply.
  v_cd := 4;
  perform public.set_game_config('enemy_synthetic_cooldown_seconds', to_jsonb(v_cd));
  perform public.set_game_config('enemy_synthetic_speed_base',           '2'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', '0'::jsonb);
  perform public.set_game_config('combat_player_speed_scale',            '0'::jsonb);
  if v_cd <= v_tick_secs then
    raise exception 'SLOWGUN FAIL: the pirate cooldown under test is % against a %s tick — at or under the tick this block asserts nothing 0314 did not already give it', v_cd, v_tick_secs;
  end if;

  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.sg.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uS;
  insert into public.player_wallet (player_id, balance) values (uS, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
  r := pg_temp.call_as(uS, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'SLOWGUN FAIL: commission: %', r; end if;
  select main_ship_id into sS from public.main_ship_instances where player_id = uS;
  r := pg_temp.call_as(uS, 'public.upsert_ship_group(1, ''Slow Gun'')');
  if (r->>'ok')::boolean is not true then raise exception 'SLOWGUN FAIL: group: %', r; end if;
  gS := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uS, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sS, gS));
  if (r->>'ok')::boolean is not true then raise exception 'SLOWGUN FAIL: assign: %', r; end if;
  r := pg_temp.call_as(uS, format('public.set_fleet_command_ship(%L::uuid, true)', sS));
  if (r->>'ok')::boolean is not true then raise exception 'SLOWGUN FAIL: command ship: %', r; end if;
  r := pg_temp.call_as(uS, format('public.set_group_auto_exit(%L::uuid, false, 30)', gS));
  if (r->>'ok')::boolean is not true then raise exception 'SLOWGUN FAIL: auto-exit off: %', r; end if;
  select l.x, l.y into o_x, o_y
    from public.main_ship_instances s
    join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = uS and f.status = 'present'
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
    join public.locations l on l.id = lp.location_id
   where s.group_id = gS
   limit 1;
  if o_x is null then raise exception 'SLOWGUN FAIL: could not resolve the docked origin'; end if;
  r := pg_temp.call_as(uS, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gS, round(o_x), round(o_y + 1000)));
  if (r->>'ok')::boolean is not true then raise exception 'SLOWGUN FAIL: go: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if pi is null then raise exception 'SLOWGUN FAIL: no pending ambush on the leg'; end if;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id into v_enc from public.combat_encounters where player_id = uS and status = 'active';
  if v_enc is null then raise exception 'SLOWGUN FAIL: the ambush opened no encounter'; end if;

  -- the wave survives its own volley and costs the hull ~2% of its pool, so nothing terminal fires.
  select hp_current + coalesce(shield_current, 0), coalesce(defense_snapshot, 0)
    into v_pool, v_pdef from public.combat_units where encounter_id = v_enc and side = 'player';
  v_defb := coalesce(public.cfg_num('defense_curve_base'), 100);
  select l.base_difficulty into v_bd
    from public.combat_encounters ce join public.locations l on l.id = ce.location_id where ce.id = v_enc;
  if v_pool is null or v_pool <= 0 or v_bd is null or v_bd <= 0 or v_defb <= 0 then
    raise exception 'SLOWGUN FAIL: hull pool % / base_difficulty % / defense base % cannot size the wave', v_pool, v_bd, v_defb;
  end if;
  v_danger := 1 + (select waves_cleared from public.combat_encounters where id = v_enc)
              + floor(extract(epoch from (now() - (select started_at from public.combat_encounters where id = v_enc)))
                      / coalesce(public.cfg_num('danger_time_divisor_seconds'), 180))::int;
  n_exp := least(coalesce(public.cfg_num('enemy_synthetic_max_units'), 6)::int,
                 greatest(1, ceil(v_danger::double precision
                                  / greatest(1, coalesce(public.cfg_num('enemy_synthetic_units_per_danger_band'), 5)))::int));
  v_atksc := (1 + coalesce(public.cfg_num('enemy_attack_danger_scale'), 0.25)) * n_exp;
  perform public.set_game_config('enemy_hp_base', '100000'::jsonb);   -- pirates outlive every tick here
  perform public.set_game_config('enemy_attack_base',
    to_jsonb(round((((0.02 * v_pool) * ((v_defb + v_pdef) / v_defb)) / (v_bd * v_atksc))::numeric, 9)));

  -- drive ticks until the wave has actually FIRED (it arrives silent and must close first)
  for i in 1..12 loop
    perform pg_temp.ae_tick(v_enc);
    select count(*) into n from public.combat_events
     where encounter_id = v_enc and source = 'pirate' and event_type in ('missile_salvo', 'hull_damage');
    if n > 0 then v_fired := true; exit; end if;
    select * into enc from public.combat_encounters where id = v_enc;
    if enc.status <> 'active' then exit; end if;
  end loop;
  if not v_fired then
    raise exception 'SLOWGUN FAIL: the wave never fired within 12 ticks — nothing was armed and every assertion below would be vacuous';
  end if;
  select tick_number into v_t1 from public.combat_encounters where id = v_enc;

  -- THE ASSERTION. Every armed pirate weapon must still be on cooldown at the moment the NEXT tick
  -- runs — now() + combat_tick_seconds. This is the inequality the old 2s cooldown FAILED.
  select count(*) into n_armed
    from public.combat_units u, jsonb_array_elements(u.weapons_json) wj
   where u.encounter_id = v_enc and u.side = 'enemy'
     and nullif(wj->>'next_ready_at','') is not null;
  if n_armed = 0 then
    raise exception 'SLOWGUN FAIL: not one pirate weapon carries a next_ready_at after a volley — nothing was armed and this block asserts nothing';
  end if;
  select count(*) into n_late
    from public.combat_units u, jsonb_array_elements(u.weapons_json) wj
   where u.encounter_id = v_enc and u.side = 'enemy'
     and nullif(wj->>'next_ready_at','') is not null
     and (wj->>'next_ready_at')::timestamptz > now() + make_interval(secs => v_tick_secs);
  if n_late <> n_armed then
    raise exception 'SLOWGUN FAIL: % of % armed pirate weapons are still on cooldown when the next tick runs (now() + %s) — a gun that is ready again on the very next tick fires exactly as often as it did before 0341',
      n_late, n_armed, v_tick_secs;
  end if;
  -- and stated as the comparison that makes it a CHANGE: the pre-0341 cooldown would have been ready.
  if now() + make_interval(secs => 2) > now() + make_interval(secs => v_tick_secs) then
    raise exception 'SLOWGUN FAIL: the pre-0341 cooldown of 2s already exceeded the %s tick — this block is not testing a change', v_tick_secs;
  end if;

  -- and the next tick is in fact silent on the pirate side (necessary, not sufficient — see header)
  perform pg_temp.ae_tick(v_enc);
  select tick_number into v_t2 from public.combat_encounters where id = v_enc;
  if v_t2 <> v_t1 + 1 then
    raise exception 'SLOWGUN FAIL: the tick after the volley did not advance (% -> %)', v_t1, v_t2;
  end if;
  select count(*) into n_alive2 from public.combat_units
   where encounter_id = v_enc and side = 'enemy' and alive_count > 0;
  if n_alive2 = 0 then
    raise exception 'SLOWGUN FAIL: no pirate is alive on the tick after the volley — silence would be trivial';
  end if;
  select count(*) into n from public.combat_events
   where encounter_id = v_enc and tick_number = v_t2 and source = 'pirate'
     and event_type in ('missile_salvo', 'hull_damage');
  if n <> 0 then
    raise exception 'SLOWGUN FAIL: % pirate fire event(s) on tick % — the wave fired on two consecutive ticks through an unelapsed %s cooldown', n, v_t2, v_cd;
  end if;

  perform public.set_game_config('enemy_synthetic_cooldown_seconds',      to_jsonb(k_ecd));
  perform public.set_game_config('enemy_hp_base',                         to_jsonb(k_ehp));
  perform public.set_game_config('enemy_attack_base',                     to_jsonb(k_eatk));
  perform public.set_game_config('enemy_synthetic_speed_base',            to_jsonb(k_esb));
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty',  to_jsonb(k_esp));
  perform public.set_game_config('combat_player_speed_scale',             to_jsonb(k_ps));

  raise notice 'DZCOMBAT_PASS_SLOWGUN ok: the deployed catalog needs 2 ticks to ready both fitted guns (% and %s against a %s tick), and all % armed weapons of a wave that fired at tick % are still on cooldown at now()+%s — the moment tick % ran, and it ran pirate-silent with % still alive',
    t_bat.cooldown_seconds, t_mk2.cooldown_seconds, v_tick_secs, n_armed, v_t1, v_tick_secs, v_t2, n_alive2;
end $$;

-- ════════ DZCOMBAT_PASS_NOWEDGE (0336): A TERMINAL-ARM MISMATCH CONCLUDES — IT DOES NOT WEDGE ═══════
-- THE DEFECT, RED BY CONSTRUCTION BELOW. fleet_destroy and presence_complete both RAISE on a status
-- mismatch, and all four terminal arms called them BEFORE their own status write — inside the per-
-- encounter subtransaction the 0206 guard wraps. So a mismatch rolled the whole tick back INCLUDING
-- last_resolved_at, the guard downgraded the raise to a warning, the cron returned normally, and the
-- encounter retried the identical tick every three seconds FOREVER. Silently. That is the wedge
-- send_ship_group_hunt already names in prose.
-- THE MISMATCH IS ENGINEERED, NOT WAITED FOR: the presence is completed OUT OF BAND through the very
-- leaf the arm composes, so the arm's own presence_complete call is guaranteed to raise. Both halves
-- of the non-vacuity are proven rather than assumed — that the presence really is out of the state
-- the leaf accepts, and that the leaf really does raise for it.
-- THE ASSERT IS THE ONE THAT DISTINGUISHES THE BODIES: reaching a TERMINAL status is not enough on
-- its own, because a body that rolls back leaves the encounter untouched rather than wrong. What
-- separates them is that last_resolved_at ADVANCED and tick_number ADVANCED — on the head the whole
-- per-encounter subtransaction unwinds and both are exactly where they were, every tick, forever.
do $$
declare
  r jsonb; n int; i int;
  uG uuid; sG uuid; gG uuid;
  o_x double precision; o_y double precision;
  v_hunt uuid := (select v from dzc where k='v_hunt');
  v_mv uuid; v_enc uuid; v_pres uuid; mv record; pi record; enc record;
  v_pool double precision; v_pdef double precision; v_defb double precision; v_bd double precision;
  v_danger int; v_atksc double precision;
  v_lra_before timestamptz; v_tick_before int; v_pstatus text;
  v_raised boolean := false; v_hit boolean := false; v_dead boolean := false;
  k_ring double precision; k_ehp double precision; k_eatk double precision;
  k_esb double precision; k_esp double precision; k_srg double precision;
begin
  select coalesce(public.cfg_num('spatial_formation_ring_radius'), 30)          into k_ring;
  select coalesce(public.cfg_num('enemy_hp_base'), 14)                          into k_ehp;
  select coalesce(public.cfg_num('enemy_attack_base'), 1.0)                     into k_eatk;
  select coalesce(public.cfg_num('enemy_synthetic_speed_base'), 0.6)            into k_esb;
  select coalesce(public.cfg_num('enemy_synthetic_speed_per_difficulty'), 0.04) into k_esp;
  select coalesce(public.cfg_num('shield_regen_combat_pct'), 0)                 into k_srg;
  -- The wave must be able to KILL, which is the only way to reach a terminal arm without writing
  -- combat_units by hand. It is given a big closing speed so it reaches its target in one step from
  -- wherever the spawn geometry puts it (this block is not about the approach), and enough hull to
  -- outlast the player's own fire. The ring is pulled in for the same reason.
  perform public.set_game_config('spatial_formation_ring_radius',        '1'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_base',           '20'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', '0'::jsonb);
  perform public.set_game_config('enemy_hp_base',                        '100000'::jsonb);
  perform public.set_game_config('shield_regen_combat_pct',              '0'::jsonb);

  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.nw.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uG;
  insert into public.player_wallet (player_id, balance) values (uG, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
  r := pg_temp.call_as(uG, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'NOWEDGE FAIL: commission: %', r; end if;
  select main_ship_id into sG from public.main_ship_instances where player_id = uG;
  r := pg_temp.call_as(uG, 'public.upsert_ship_group(1, ''No Wedge'')');
  if (r->>'ok')::boolean is not true then raise exception 'NOWEDGE FAIL: group: %', r; end if;
  gG := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uG, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sG, gG));
  if (r->>'ok')::boolean is not true then raise exception 'NOWEDGE FAIL: assign: %', r; end if;
  r := pg_temp.call_as(uG, format('public.set_fleet_command_ship(%L::uuid, true)', sG));
  if (r->>'ok')::boolean is not true then raise exception 'NOWEDGE FAIL: command ship: %', r; end if;
  r := pg_temp.call_as(uG, format('public.set_group_auto_exit(%L::uuid, false, 30)', gG));
  if (r->>'ok')::boolean is not true then raise exception 'NOWEDGE FAIL: auto-exit off: %', r; end if;
  select l.x, l.y into o_x, o_y
    from public.main_ship_instances s
    join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = uG and f.status = 'present'
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
    join public.locations l on l.id = lp.location_id
   where s.group_id = gG
   limit 1;
  if o_x is null then raise exception 'NOWEDGE FAIL: could not resolve the docked origin'; end if;
  r := pg_temp.call_as(uG, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gG, round(o_x), round(o_y + 1000)));
  if (r->>'ok')::boolean is not true then raise exception 'NOWEDGE FAIL: go: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if pi is null then raise exception 'NOWEDGE FAIL: no pending ambush on the leg'; end if;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id, presence_id into v_enc, v_pres from public.combat_encounters
   where player_id = uG and status = 'active';
  if v_enc is null then raise exception 'NOWEDGE FAIL: the ambush opened no encounter'; end if;

  -- the wave's shot costs the hull ~60% of its pool: one lands and it survives, two and it is gone.
  select hp_current + coalesce(shield_current, 0), coalesce(defense_snapshot, 0)
    into v_pool, v_pdef from public.combat_units where encounter_id = v_enc and side = 'player';
  v_defb := coalesce(public.cfg_num('defense_curve_base'), 100);
  select l.base_difficulty into v_bd
    from public.combat_encounters ce join public.locations l on l.id = ce.location_id where ce.id = v_enc;
  if v_pool is null or v_pool <= 0 or v_bd is null or v_bd <= 0 or v_defb <= 0 then
    raise exception 'NOWEDGE FAIL: hull pool % / base_difficulty % / defense base % cannot size the killing wave', v_pool, v_bd, v_defb;
  end if;
  v_danger := 1 + (select waves_cleared from public.combat_encounters where id = v_enc)
              + floor(extract(epoch from (now() - (select started_at from public.combat_encounters where id = v_enc)))
                      / coalesce(public.cfg_num('danger_time_divisor_seconds'), 180))::int;
  v_atksc := 1 + v_danger * coalesce(public.cfg_num('enemy_attack_danger_scale'), 0.25);
  perform public.set_game_config('enemy_attack_base',
    to_jsonb(round((((0.6 * v_pool) * ((v_defb + v_pdef) / v_defb)) / (v_bd * v_atksc))::numeric, 9)));

  -- ── PHASE 1: let the wave land its FIRST hit. The approach length depends on the spawn geometry,
  --    which this block deliberately does not pin, so it drives ticks until a pirate-sourced hit is
  --    on the record and stops the moment there is one. ─────────────────────────────────────────────
  for i in 1..10 loop
    perform pg_temp.ae_tick(v_enc);
    select count(*) into n from public.combat_events
     where encounter_id = v_enc and event_type = 'hull_damage' and source = 'pirate';
    if n > 0 then v_hit := true; exit; end if;
    select status into v_pstatus from public.combat_encounters where id = v_enc;
    if v_pstatus <> 'active' then exit; end if;
  end loop;
  if not v_hit then
    raise exception 'NOWEDGE FAIL: the wave never landed a hit in 10 ticks — the fixture cannot reach a terminal arm at all and everything below would be unreachable';
  end if;
  select count(*) into n from public.combat_units
   where encounter_id = v_enc and side = 'player' and alive_count > 0;
  if n <> 1 then
    raise exception 'NOWEDGE FAIL: the hull did not survive the FIRST landed hit — the mismatch below has to be armed while the fight is still running, so the killing tick is the one that meets it';
  end if;

  -- ── PHASE 2: ARM THE MISMATCH, through the real leaf, and prove it is real. ─────────────────────
  perform public.presence_complete(v_pres);
  select status into v_pstatus from public.location_presence where id = v_pres;
  if v_pstatus <> 'completed' then
    raise exception 'NOWEDGE FAIL: the presence reads % after being completed out of band (want completed) — the mismatch this block exists to survive was never created', v_pstatus;
  end if;
  -- and the leaf the terminal arm composes really does REFUSE this presence now. Without this the
  -- block could pass on a world where presence_complete had quietly become idempotent, and the
  -- confinement under test would never have been exercised.
  begin
    perform public.presence_complete(v_pres);
    v_raised := false;
  exception
    when others then v_raised := true;
  end;
  if not v_raised then
    raise exception 'NOWEDGE FAIL: presence_complete accepted the already-completed presence without raising — the terminal arm will meet no mismatch, so a body with no confinement at all would pass this block and it would prove nothing';
  end if;

  select last_resolved_at, tick_number into v_lra_before, v_tick_before
    from public.combat_encounters where id = v_enc;
  if v_lra_before is null then
    raise exception 'NOWEDGE FAIL: the encounter has no last_resolved_at to compare against — the whole point is that the head does not advance it';
  end if;

  -- ── PHASE 3: DRIVE THE DEATH ARM INTO THE MISMATCH. ────────────────────────────────────────────
  for i in 1..10 loop
    perform pg_temp.ae_tick(v_enc);
    select status into v_pstatus from public.combat_encounters where id = v_enc;
    if v_pstatus not in ('active', 'retreating') then v_dead := true; exit; end if;
  end loop;
  select * into enc from public.combat_encounters where id = v_enc;
  if not v_dead then
    raise exception 'NOWEDGE FAIL: after 10 ticks against a completed presence the encounter is STILL % (tick %, last resolved %) — the terminal arm raised inside the per-encounter guard, the whole tick rolled back, and the encounter is wedged retrying the identical tick forever: exactly the failure this slice exists to end',
      enc.status, enc.tick_number, enc.last_resolved_at;
  end if;
  if enc.status <> 'defeat' or enc.ended_at is null then
    raise exception 'NOWEDGE FAIL: the encounter reached % / ended_at % — a terminal arm that meets a mismatch must still CONCLUDE the encounter, not leave it in some third state', enc.status, enc.ended_at;
  end if;
  if enc.last_resolved_at < v_lra_before then
    raise exception 'NOWEDGE FAIL: last_resolved_at went BACKWARDS (% -> %) — the tick that hit the terminal arm was rolled back by the raise, which is the wedge itself: the cadence clock never moves and the same tick runs again in three seconds',
      v_lra_before, enc.last_resolved_at;
  end if;
  if enc.tick_number <= v_tick_before then
    raise exception 'NOWEDGE FAIL: tick_number did not advance (% -> %) — every tick after the mismatch was unwound, so no work survived at all', v_tick_before, enc.tick_number;
  end if;
  select count(*) into n from public.combat_units
   where encounter_id = v_enc and side = 'player' and alive_count > 0;
  if n <> 0 then
    raise exception 'NOWEDGE FAIL: % player hull(s) are still alive on a concluded encounter — the death arm did not actually run and the conclusion above came from somewhere else', n;
  end if;

  perform public.set_game_config('spatial_formation_ring_radius',        to_jsonb(k_ring));
  perform public.set_game_config('enemy_hp_base',                        to_jsonb(k_ehp));
  perform public.set_game_config('enemy_attack_base',                    to_jsonb(k_eatk));
  perform public.set_game_config('enemy_synthetic_speed_base',           to_jsonb(k_esb));
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', to_jsonb(k_esp));
  perform public.set_game_config('shield_regen_combat_pct',              to_jsonb(k_srg));

  raise notice 'DZCOMBAT_PASS_NOWEDGE ok: with the presence completed OUT OF BAND (and presence_complete PROVEN to raise for it), the death arm still concluded the encounter — status %, ended_at stamped, tick % -> % and last_resolved_at % -> % both ADVANCED. On the head the arm raised before its own status write, the per-encounter guard downgraded it to a warning, the tick rolled back whole and the encounter retried the identical tick every three seconds forever',
    enc.status, v_tick_before, enc.tick_number, v_lra_before, enc.last_resolved_at;
end $$;

-- ════════ DZCOMBAT_PASS_ORDERSTABLE (0336): WHO FIRES FIRST IS DECIDED, NOT LEFT TO THE HEAP ════════
-- THE DEFECT. The tick freezes its population into v_units with jsonb_agg and NO ORDER BY, so the
-- actor loop ran in heap order. Targeting was deterministic; WHO SHOOTS FIRST was not — and with
-- sequential damage inside a tick, who shoots first decides whose shots are wasted on a row that is
-- already dead. Any determinism harness over this tick was unsound without it. 0336 adds
-- `order by cu2.id` to the freeze.
-- HOW THIS IS PROVEN OBSERVABLY, and the honest caveat. combat_events.seq is stamped in the order
-- the loop emitted, so the ORDER BY's effect is directly visible: with several units on a side, the
-- salvos of one tick, read in seq order, must carry NON-DECREASING combat_units.id. That is the
-- property, stated as the ORDER BY's own effect rather than as "it differed from something".
-- BE HONEST ABOUT WHAT THE HEAD DOES: heap order for a freshly inserted set is insertion order, and
-- the encounter creator inserts player rows ordered by main_ship_id while combat_units.id is a fresh
-- uuid — two unrelated orders. So the head satisfies this by coincidence with probability 1/n! per
-- tick, and the block uses SIX hulls over TWO consecutive ticks (1/720 per tick) rather than the
-- three the property needs, precisely so that coincidence is not a realistic outcome. It is stated
-- here rather than hidden because a probabilistic red is not the same thing as a red by
-- construction, and the next author is entitled to know which one this is.
do $$
declare
  r jsonb; n int; i int; v_t int;
  uO uuid; gO uuid; s_iter uuid;
  o_x double precision; o_y double precision;
  v_hunt uuid := (select v from dzc where k='v_hunt');
  v_mv uuid; v_enc uuid; mv record; pi record;
  v_t1 int; v_t2 int; n_bad int; n_firers int; n_orphan int; n_nullid int;
  k_ring double precision; k_ehp double precision; k_erb double precision; k_erp double precision;
  k_esb double precision; k_esp double precision;
begin
  select coalesce(public.cfg_num('spatial_formation_ring_radius'), 30)          into k_ring;
  select coalesce(public.cfg_num('enemy_hp_base'), 14)                          into k_ehp;
  select coalesce(public.cfg_num('enemy_synthetic_range_base'), 3.6)            into k_erb;
  select coalesce(public.cfg_num('enemy_synthetic_range_per_difficulty'), 0.04) into k_erp;
  select coalesce(public.cfg_num('enemy_synthetic_speed_base'), 0.6)            into k_esb;
  select coalesce(public.cfg_num('enemy_synthetic_speed_per_difficulty'), 0.04) into k_esp;
  -- The whole fleet must be firing on the SAME tick or there is no ordering to observe: the ring is
  -- pulled in so every hull is inside its own range from the first tick, the wave is given a reach
  -- of almost nothing (it is a target, not a participant) and a hull deep enough that nobody dies
  -- and changes the population between the two ticks under comparison.
  perform public.set_game_config('spatial_formation_ring_radius',        '1'::jsonb);
  perform public.set_game_config('enemy_synthetic_range_base',           '0.1'::jsonb);
  perform public.set_game_config('enemy_synthetic_range_per_difficulty', '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_base',           '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', '0'::jsonb);
  perform public.set_game_config('enemy_hp_base',                        '100000'::jsonb);

  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.os.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uO;
  insert into public.player_wallet (player_id, balance) values (uO, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
  r := pg_temp.call_as(uO, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'ORDERSTABLE FAIL: commission 1: %', r; end if;
  for i in 2 .. 6 loop
    r := pg_temp.call_as(uO, 'public.commission_additional_main_ship()');
    if (r->>'ok')::boolean is not true then raise exception 'ORDERSTABLE FAIL: commission %: %', i, r; end if;
  end loop;
  r := pg_temp.call_as(uO, 'public.upsert_ship_group(1, ''Order Stable'')');
  if (r->>'ok')::boolean is not true then raise exception 'ORDERSTABLE FAIL: group: %', r; end if;
  gO := (r->>'group_id')::uuid;
  for s_iter in select main_ship_id from public.main_ship_instances where player_id = uO loop
    r := pg_temp.call_as(uO, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_iter, gO));
    if (r->>'ok')::boolean is not true then raise exception 'ORDERSTABLE FAIL: assign %: %', s_iter, r; end if;
  end loop;
  select main_ship_id into s_iter from public.main_ship_instances where player_id = uO order by main_ship_id limit 1;
  r := pg_temp.call_as(uO, format('public.set_fleet_command_ship(%L::uuid, true)', s_iter));
  if (r->>'ok')::boolean is not true then raise exception 'ORDERSTABLE FAIL: command ship: %', r; end if;
  r := pg_temp.call_as(uO, format('public.set_group_auto_exit(%L::uuid, false, 30)', gO));
  if (r->>'ok')::boolean is not true then raise exception 'ORDERSTABLE FAIL: auto-exit off: %', r; end if;
  select l.x, l.y into o_x, o_y
    from public.main_ship_instances s
    join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = uO and f.status = 'present'
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
    join public.locations l on l.id = lp.location_id
   where s.group_id = gO
   limit 1;
  if o_x is null then raise exception 'ORDERSTABLE FAIL: could not resolve the docked origin'; end if;
  r := pg_temp.call_as(uO, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gO, round(o_x), round(o_y + 1000)));
  if (r->>'ok')::boolean is not true then raise exception 'ORDERSTABLE FAIL: go: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if pi is null then raise exception 'ORDERSTABLE FAIL: no pending ambush on the leg'; end if;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id into v_enc from public.combat_encounters where player_id = uO and status = 'active';
  if v_enc is null then raise exception 'ORDERSTABLE FAIL: the ambush opened no encounter'; end if;
  select count(*) into n from public.combat_units where encounter_id = v_enc and side = 'player';
  if n < 6 then
    raise exception 'ORDERSTABLE FAIL: % player unit(s) fielded — with fewer than 6 the head satisfies an id-ascending order by coincidence often enough that a green run would mean nothing', n;
  end if;

  perform pg_temp.ae_tick(v_enc);
  select tick_number into v_t1 from public.combat_encounters where id = v_enc;
  perform pg_temp.ae_tick(v_enc);
  select tick_number into v_t2 from public.combat_encounters where id = v_enc;
  if v_t2 <> v_t1 + 1 then
    raise exception 'ORDERSTABLE FAIL: the two observed ticks are % and % — they must be CONSECUTIVE, or a stable order between them proves nothing about a single run of the loop', v_t1, v_t2;
  end if;

  foreach v_t in array array[v_t1, v_t2] loop
    -- NULL-VACUITY: a salvo that names no unit cannot participate in an ordering, and lag() over a
    -- column of NULLs compares FALSE against everything — the inversion count would be 0 for free.
    select count(*) into n_nullid from public.combat_events
     where encounter_id = v_enc and tick_number = v_t and event_type = 'missile_salvo'
       and payload_json->>'unit_id' is null;
    if n_nullid <> 0 then
      raise exception 'ORDERSTABLE FAIL: % salvo(s) on tick % name no firing unit — an ordering over NULLs is vacuous', n_nullid, v_t;
    end if;
    -- and every id named must be a real unit OF THIS ENCOUNTER, or the comparison is not being made
    -- against combat_units.id at all.
    select count(*) into n_orphan from public.combat_events ev
     where ev.encounter_id = v_enc and ev.tick_number = v_t and ev.event_type = 'missile_salvo'
       and not exists (select 1 from public.combat_units cu9
                        where cu9.encounter_id = v_enc and cu9.id = (ev.payload_json->>'unit_id')::uuid);
    if n_orphan <> 0 then
      raise exception 'ORDERSTABLE FAIL: % salvo(s) on tick % name a unit that is not in this encounter', n_orphan, v_t;
    end if;
    select count(distinct payload_json->>'unit_id') into n_firers from public.combat_events
     where encounter_id = v_enc and tick_number = v_t and event_type = 'missile_salvo';
    if n_firers < 6 then
      raise exception 'ORDERSTABLE FAIL: only % distinct unit(s) fired on tick % — with fewer than 6 firing units an id-ascending sequence is not evidence of an ORDER BY, it is a coincidence with odds better than one in a thousand', n_firers, v_t;
    end if;
    -- THE PROPERTY: read in seq order, the firing units ascend by combat_units.id. A unit carrying
    -- several weapons emits several adjacent salvos, so the requirement is NON-DECREASING; a strict
    -- decrease is a unit that acted out of turn.
    select count(*) into n_bad from (
      select (ev.payload_json->>'unit_id')::uuid as uid,
             lag((ev.payload_json->>'unit_id')::uuid) over (order by ev.seq) as prv
        from public.combat_events ev
       where ev.encounter_id = v_enc and ev.tick_number = v_t and ev.event_type = 'missile_salvo'
    ) z where z.prv is not null and z.uid < z.prv;
    if n_bad <> 0 then
      raise exception 'ORDERSTABLE FAIL: % unit(s) acted out of id order on tick % — the population freeze is running in heap order, so who fires first (and therefore whose shots are wasted on an already-dead row) is not decided by anything',
        n_bad, v_t;
    end if;
  end loop;

  perform public.set_game_config('spatial_formation_ring_radius',        to_jsonb(k_ring));
  perform public.set_game_config('enemy_hp_base',                        to_jsonb(k_ehp));
  perform public.set_game_config('enemy_synthetic_range_base',           to_jsonb(k_erb));
  perform public.set_game_config('enemy_synthetic_range_per_difficulty', to_jsonb(k_erp));
  perform public.set_game_config('enemy_synthetic_speed_base',           to_jsonb(k_esb));
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', to_jsonb(k_esp));

  raise notice 'DZCOMBAT_PASS_ORDERSTABLE ok: on BOTH of two consecutive ticks (% and %), % distinct firing units emitted their salvos in ascending combat_units.id order with zero inversions — the freeze carries its ORDER BY and the actor loop is decided rather than left to whatever order the heap happened to hand back',
    v_t1, v_t2, n_firers;
end $$;

-- ════════ DZCOMBAT_PASS_SHORTGUN (0336): A LONGER GUN NO LONGER DISABLES A SHORTER ONE ══════════════
-- THE DEFECT, RED BY CONSTRUCTION BELOW. The population freeze carried my_range = MAX(range), and
-- the mover uses that one value for BOTH the close decision and the kite cap — while the fire gate
-- is PER WEAPON. So a ship carrying an Mk-II (range 6) beside an autocannon (range 5) parked itself
-- at ~6 and the autocannon never fired once: a strictly better gun buying LESS damage, which is the
-- very defect 0331 was written to end, recreated through geometry. 0336 passes my_min_range to the
-- mover (MY engagement range) while the TARGET's my_range stays the longest (what I must respect
-- about the enemy is its full reach) — two questions, two values.
-- THE FIXTURE is exactly the production-plausible one: one starter hull, one autocannon_battery
-- (slot 1) and one autocannon_battery_mk2 (slot 2) — three slots, both fitted, no room for a third.
-- The wave is parked outside both ranges at spawn and given no reach and no speed of its own, so the
-- ONLY thing that moves is the hull, and where it comes to rest is the whole measurement.
-- ON THE HEAD it settles at exactly the LONG range and the short gun never appears in the log; the
-- non-vacuity guard below proves the ship really did pass through that band first.
do $$
declare
  r jsonb; n int; i int;
  uS uuid; sS uuid; gS uuid;
  o_x double precision; o_y double precision;
  v_hunt uuid := (select v from dzc where k='v_hunt');
  v_mv uuid; v_enc uuid; mv record; pi record;
  v_short double precision; v_long double precision; v_speed double precision;
  v_u_pl uuid; v_u_en uuid; v_dist double precision; n_units int;
  n_short int; n_long int; n_bandtick int;
  sE uuid;                                          -- the escort that MAKES the ring an extent
  v_ax double precision; v_ay double precision;
  v_extent double precision; v_players int;
  v_ren double precision; v_open double precision;  -- the wave's own reach, and the opening gap
  v_band double precision;                          -- v_long - v_short: the band the head parks in
  k_ring double precision; k_ehp double precision; k_erb double precision; k_erp double precision;
  k_esb double precision; k_esp double precision; k_pss double precision;
begin
  select coalesce(public.cfg_num('spatial_formation_ring_radius'), 30)          into k_ring;
  select coalesce(public.cfg_num('enemy_hp_base'), 14)                          into k_ehp;
  select coalesce(public.cfg_num('enemy_synthetic_range_base'), 3.6)            into k_erb;
  select coalesce(public.cfg_num('enemy_synthetic_range_per_difficulty'), 0.04) into k_erp;
  select coalesce(public.cfg_num('enemy_synthetic_speed_base'), 0.6)            into k_esb;
  select coalesce(public.cfg_num('enemy_synthetic_speed_per_difficulty'), 0.04) into k_esp;
  select coalesce(public.cfg_num('combat_player_speed_scale'), 0.2)             into k_pss;
  -- The wave is a fixed marker post: no reach, no speed, and hull enough to outlast the approach.
  -- The ring is pushed OUT so the hull provably starts beyond BOTH of its guns, and the player's
  -- combat speed is set so the approach is a handful of ticks rather than dozens.
  --
  -- ── 0336: THE RING ONLY PUSHES ANYTHING OUT IF THERE IS A SECOND HULL ON IT ─────────────────────
  -- THE BUG THIS PARAGRAPH REPLACES (CI): `the hull already stands 2.91999999999962 from the wave
  -- after one tick, inside its LONGER 6 range`. This block set the ring to 8 to stand the wave beyond
  -- both guns — which is the right intent and the wrong lever. 0336 does not read the ring when it
  -- places a wave; it measures `max(distance from the anchor to each LIVING player unit)`. This
  -- fixture commissioned exactly ONE hull, and a lone hull IS its own lead, so it stands ON the
  -- anchor, the MEASURED extent is 0, THE RING IS INERT, and the wave landed at 0 + 0.1 + 1 = 1.1 —
  -- inside both guns, with nothing to close. (The 2.92 in the log is that 1.1 after one tick of the
  -- hull KITING outward, which is what a ship does when it out-ranges its target by 4.9.)
  -- This is the THIRD block staged as if the ring set the wave radius — CLOSURE predicted from it and
  -- LEAD asserted against it, both fixed the same way: the wave radius has ONE authority and it is
  -- the measured extent. Here the fix is not to predict differently but to MAKE THE EXTENT REAL: a
  -- second hull, which is what a ring means. sS is the designated command ship, so it is the lead and
  -- keeps the anchor; the escort takes ring slot 0 and the extent becomes the 8 the author asked for,
  -- putting the wave at 8 + 0.1 + 1 = 9.1 — beyond the Mk-II's 6 with real margin, asserted below.
  perform public.set_game_config('spatial_formation_ring_radius',        '8'::jsonb);
  perform public.set_game_config('enemy_synthetic_range_base',           '0.1'::jsonb);
  perform public.set_game_config('enemy_synthetic_range_per_difficulty', '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_base',           '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', '0'::jsonb);
  perform public.set_game_config('enemy_hp_base',                        '100000'::jsonb);
  -- ── AND THE STEP MUST BE SMALLER THAN THE BAND, OR THE BAND CAN BE STEPPED OVER ─────────────────
  -- The non-vacuity guard below requires a tick on which ONLY the longer gun reaches — the band
  -- (v_short, v_long], one unit wide at the catalog ranges. At the old scale of 2 the hull moved ~1.82
  -- per tick, WIDER than that band, so whether it ever landed inside was an accident of
  -- (opening gap - v_short) mod step: it happened to at 9.1, and would have skipped it entirely from
  -- 10.0. A guard whose success depends on arithmetic luck is the same disease as a zero-margin float
  -- comparison. At 0.5 the step is ~0.46 and strictly under the band, so at least one pre-move
  -- distance MUST land in it — structural, and asserted from the frozen row below rather than assumed.
  perform public.set_game_config('combat_player_speed_scale',            '0.5'::jsonb);

  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.sg.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uS;
  insert into public.player_wallet (player_id, balance) values (uS, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
  r := pg_temp.call_as(uS, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'SHORTGUN FAIL: commission: %', r; end if;
  select main_ship_id into sS from public.main_ship_instances where player_id = uS;
  select jsonb_build_object('items', jsonb_agg(jsonb_build_object('item_id', i2.item_id, 'quantity', i2.q)))
    into r
    from (select item_id, sum(qty)::int as q from (
            select item_id, qty from public.module_recipe_ingredients where module_type_id = 'autocannon_battery'
            union all
            select item_id, qty from public.module_recipe_ingredients where module_type_id = 'autocannon_battery_mk2'
          ) x group by item_id) i2;
  if r is null or jsonb_array_length(r->'items') < 1 then
    raise exception 'SHORTGUN FAIL: module_recipe_ingredients carries no recipe for the two guns this block fits — the grant would be empty and the failure would surface as a craft error instead of this message';
  end if;
  perform public.reward_grant('combat', gen_random_uuid(), uS, null, r);
  r := pg_temp.call_as(uS, format('public.craft_module(''dzc-sg-s'', ''autocannon_battery'', %L::uuid)', sS));
  if (r->>'ok')::boolean is not true then raise exception 'SHORTGUN FAIL: craft short gun: %', r; end if;
  r := pg_temp.call_as(uS, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''dzc-sg-fs'')', (r->>'instance_id')::uuid, sS));
  if (r->>'ok')::boolean is not true then raise exception 'SHORTGUN FAIL: fit short gun: %', r; end if;
  r := pg_temp.call_as(uS, format('public.craft_module(''dzc-sg-l'', ''autocannon_battery_mk2'', %L::uuid)', sS));
  if (r->>'ok')::boolean is not true then raise exception 'SHORTGUN FAIL: craft long gun: %', r; end if;
  r := pg_temp.call_as(uS, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''dzc-sg-fl'')', (r->>'instance_id')::uuid, sS));
  if (r->>'ok')::boolean is not true then raise exception 'SHORTGUN FAIL: fit long gun: %', r; end if;

  r := pg_temp.call_as(uS, 'public.upsert_ship_group(1, ''Short Gun'')');
  if (r->>'ok')::boolean is not true then raise exception 'SHORTGUN FAIL: group: %', r; end if;
  gS := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uS, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sS, gS));
  if (r->>'ok')::boolean is not true then raise exception 'SHORTGUN FAIL: assign: %', r; end if;
  -- THE ESCORT THAT MAKES THE RING AN EXTENT (0336). It carries no fitted weapon — the 0262
  -- synthesized fallback is a THIRD module_type_id, so it can appear in neither gun's salvo count and
  -- cannot contaminate a single assert below; its only job is to stand on ring slot 0 so that the
  -- measured formation extent is the 8 this block owns. sS is designated command ship immediately
  -- after, so the lead election keeps the FITTED hull on the anchor and this hull on the ring.
  r := pg_temp.call_as(uS, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'SHORTGUN FAIL: commission escort: %', r; end if;
  select main_ship_id into sE from public.main_ship_instances
   where player_id = uS and main_ship_id <> sS limit 1;
  if sE is null then raise exception 'SHORTGUN FAIL: no escort hull materialised — without a second hull the ring is inert, the measured extent is 0 and the wave spawns on top of the fixture'; end if;
  r := pg_temp.call_as(uS, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sE, gS));
  if (r->>'ok')::boolean is not true then raise exception 'SHORTGUN FAIL: assign escort: %', r; end if;
  r := pg_temp.call_as(uS, format('public.set_fleet_command_ship(%L::uuid, true)', sS));
  if (r->>'ok')::boolean is not true then raise exception 'SHORTGUN FAIL: command ship: %', r; end if;
  r := pg_temp.call_as(uS, format('public.set_group_auto_exit(%L::uuid, false, 30)', gS));
  if (r->>'ok')::boolean is not true then raise exception 'SHORTGUN FAIL: auto-exit off: %', r; end if;
  select l.x, l.y into o_x, o_y
    from public.main_ship_instances s
    join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = uS and f.status = 'present'
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
    join public.locations l on l.id = lp.location_id
   where s.group_id = gS
   limit 1;
  if o_x is null then raise exception 'SHORTGUN FAIL: could not resolve the docked origin'; end if;
  r := pg_temp.call_as(uS, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gS, round(o_x), round(o_y + 1000)));
  if (r->>'ok')::boolean is not true then raise exception 'SHORTGUN FAIL: go: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if pi is null then raise exception 'SHORTGUN FAIL: no pending ambush on the leg'; end if;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id into v_enc from public.combat_encounters where player_id = uS and status = 'active';
  if v_enc is null then raise exception 'SHORTGUN FAIL: the ambush opened no encounter'; end if;

  -- SCOPED TO THE FITTED HULL. This read carried no ship filter and no LIMIT, which was harmless
  -- while the fleet was one ship and is a silent wrong-row pick now that it is two: plpgsql SELECT
  -- INTO takes the FIRST row without complaint, so every range and speed below could have come from
  -- the escort. The fixture is the MIXED-RANGE hull, by name.
  select id, move_speed into v_u_pl, v_speed from public.combat_units
   where encounter_id = v_enc and side = 'player' and main_ship_id = sS;
  if v_u_pl is null then
    raise exception 'SHORTGUN FAIL: the fitted hull seeded no combat unit — the whole measurement is about that one ship';
  end if;
  -- ── THE EXTENT IS REAL, AND THE WAVE IS WHERE THE MEASURED EXTENT PUTS IT (0336) ────────────────
  -- The one authority for a wave radius is the MEASURED formation extent, never the ring knob. Both
  -- are pinned here: the extent must BE the ring this block owns (so the escort really is on it), and
  -- the opening hull-to-wave gap must be exactly (extent + the wave's own frozen reach + 1). If a
  -- future change makes the ring inert again — a hull removed, a lead re-elected — this fails with
  -- the numbers instead of quietly staging a fight that starts on top of the fixture.
  select engagement_x, engagement_y into v_ax, v_ay from public.combat_encounters where id = v_enc;
  select count(*), coalesce(max(public.osn_distance(v_ax, v_ay, u.pos_x, u.pos_y)), 0)
    into v_players, v_extent
    from public.combat_units u
   where u.encounter_id = v_enc and u.side = 'player' and u.alive_count > 0
     and u.pos_x is not null and u.pos_y is not null;
  if v_ax is null or v_ay is null or v_players <> 2 then
    raise exception 'SHORTGUN FAIL: anchor (%,%) / % positioned living player row(s) — the fixture is a LEAD on the anchor plus ONE escort on the ring, and without both the measured extent is not the ring this block owns',
      v_ax, v_ay, v_players;
  end if;
  if abs(v_extent - 8) > 1e-6 then
    raise exception 'SHORTGUN FAIL: the measured formation extent is % (want the 8 ring this block owns) — the ring is inert again, so the wave will spawn on top of the fixture instead of beyond both of its guns', v_extent;
  end if;
  select min((w->>'range')::double precision), max((w->>'range')::double precision)
    into v_short, v_long
    from public.combat_units cu9, jsonb_array_elements(cu9.weapons_json) w
   where cu9.id = v_u_pl;
  select jsonb_array_length(weapons_json) into n from public.combat_units where id = v_u_pl;
  if n <> 2 then
    raise exception 'SHORTGUN FAIL: the hull carries % weapon entr(ies) (want 2) — a mixed-range ship is the entire fixture', n;
  end if;
  if v_short is null or v_long is null or v_short >= v_long then
    raise exception 'SHORTGUN FAIL: the two fitted guns reach % and % — they must differ, with one strictly SHORTER, or there is no gun for a longer one to disable', v_short, v_long;
  end if;
  if v_speed is null or v_speed <= 0 then
    raise exception 'SHORTGUN FAIL: the hull frozen move_speed is % — a ship that cannot move can never settle anywhere and the whole measurement is vacuous', v_speed;
  end if;
  -- THE STEP MUST BE STRICTLY UNDER THE BAND, so the band-tick guard below cannot be stepped over.
  -- Read off the hull's OWN frozen move_speed against its OWN two catalog ranges — derived, printed,
  -- and the difference between a guard that holds by construction and one that holds by luck.
  v_band := v_long - v_short;
  if v_speed >= v_band then
    raise exception 'SHORTGUN FAIL: the hull moves % per tick against a %-wide band between its two guns (% to %) — a step at or wider than the band can jump the approach straight past the only ticks that expose the defect, so whether the guard below fires would be an accident of arithmetic',
      v_speed, v_band, v_short, v_long;
  end if;

  perform pg_temp.ae_tick(v_enc);
  select count(*) into n_units from public.combat_units where encounter_id = v_enc and side = 'enemy';
  if n_units <> 1 then
    raise exception 'SHORTGUN FAIL: % pirate unit(s) spawned (this block needs exactly 1, so the settled distance is a single unambiguous number)', n_units;
  end if;
  select id into v_u_en from public.combat_units where encounter_id = v_enc and side = 'enemy';
  select public.osn_distance(a9.pos_x, a9.pos_y, b9.pos_x, b9.pos_y) into v_dist
    from public.combat_units a9, public.combat_units b9 where a9.id = v_u_pl and b9.id = v_u_en;
  if v_dist is null then
    raise exception 'SHORTGUN FAIL: the hull-to-wave distance is NULL after the opening tick — an unpositioned fight cannot prove where anything settled';
  end if;
  -- THE WAVE IS WHERE THE MEASURED EXTENT PUTS IT — derived through the spawn arm's own expression,
  -- from the wave's OWN frozen reach, not from the knob this block wrote.
  select max((w->>'range')::double precision) into v_ren
    from public.combat_units cu8, jsonb_array_elements(cu8.weapons_json) w where cu8.id = v_u_en;
  if v_ren is null then
    raise exception 'SHORTGUN FAIL: the spawned wave carries no weapon range — the spawn radius is DERIVED from that reach and cannot be checked';
  end if;
  v_open := v_dist + v_speed;   -- the gap at SPAWN: one tick of closing has already been applied
  if abs(v_open - (v_extent + v_ren + 1)) > 1e-6 then
    raise exception 'SHORTGUN FAIL: the wave opened % from the hull but the measured extent % plus its own reach % plus 1 is % — the wave is no longer arriving where 0336 puts it, so re-derive against the extent rather than loosening anything below',
      v_open, v_extent, v_ren, v_extent + v_ren + 1;
  end if;
  -- THE FIRST THRESHOLD, WITH ITS MARGIN PRINTED: after one tick the hull must still be beyond its
  -- LONGER gun, so the approach that exposes the short one is genuinely ahead of it.
  if v_dist <= v_long then
    raise exception 'SHORTGUN FAIL: the hull already stands % from the wave after one tick, inside its LONGER % range (margin % — it needed to be positive) — it never had to close, so the approach that exposes the short gun was never exercised',
      v_dist, v_long, v_dist - v_long;
  end if;

  -- ── DRIVE THE APPROACH TO ITS RESTING POINT. The hull is the only thing that moves. ─────────────
  for i in 1..20 loop
    perform pg_temp.ae_tick(v_enc);
  end loop;
  select public.osn_distance(a9.pos_x, a9.pos_y, b9.pos_x, b9.pos_y) into v_dist
    from public.combat_units a9, public.combat_units b9 where a9.id = v_u_pl and b9.id = v_u_en;
  if v_dist is null then
    raise exception 'SHORTGUN FAIL: the settled hull-to-wave distance is NULL — the settle assert would be vacuous';
  end if;

  select count(*) into n_short from public.combat_events
   where encounter_id = v_enc and event_type = 'missile_salvo' and source = 'player'
     and projectile_type = 'autocannon_battery';
  select count(*) into n_long from public.combat_events
   where encounter_id = v_enc and event_type = 'missile_salvo' and source = 'player'
     and projectile_type = 'autocannon_battery_mk2';
  -- NON-VACUITY, and it is the one that matters: the ship must have PASSED THROUGH the band where
  -- only the long gun reaches. That band is the head's permanent resting place, so a run that never
  -- entered it would be green on both bodies and prove nothing.
  select count(*) into n_bandtick from (
    select ev.tick_number
      from public.combat_events ev
     where ev.encounter_id = v_enc and ev.event_type = 'missile_salvo' and ev.source = 'player'
     group by ev.tick_number
    having count(*) filter (where ev.projectile_type = 'autocannon_battery_mk2') > 0
       and count(*) filter (where ev.projectile_type = 'autocannon_battery') = 0
  ) z;
  if n_bandtick = 0 then
    raise exception 'SHORTGUN FAIL: there was never a tick on which only the LONGER gun could reach — the fixture never entered the band the head parks in, so a green result here would say nothing about the defect';
  end if;
  if n_long = 0 then
    raise exception 'SHORTGUN FAIL: the longer gun never fired at all — the fixture never engaged and neither half of this block means anything';
  end if;
  if n_short = 0 then
    raise exception 'SHORTGUN FAIL: the SHORTER gun (% range) never fired in 21 ticks while the longer one (% range) fired % time(s), and the hull came to rest % away — the mover was handed the ship LONGEST reach for both the close decision and the kite cap, so it parks at the long gun edge and the short gun is silently disabled: a better module buying less damage',
      v_short, v_long, n_long, v_dist;
  end if;
  if v_dist > v_short + 1e-6 then
    raise exception 'SHORTGUN FAIL: the hull settled % from its target, beyond its own SHORTEST gun (% range) — the kite cap is still the longest gun, so the ship holds where half its guns cannot reach',
      v_dist, v_short;
  end if;
  -- ── THE SECOND THRESHOLD, WITH ITS MARGIN PRINTED — AND IT IS THE DEFECT'S OWN SIGNATURE ────────
  -- The tolerance above is not a boundary being papered over: a ship that out-ranges its target takes
  -- combat_unit_decide_move's KITE arm, which retreats to the edge of its own engagement range and
  -- therefore lands on `my_min_range` EXACTLY, by construction. Comparing a computed sqrt against
  -- that exact expected value is the same shape as CLOSURE's step pin, not a knife edge.
  -- What IS a real margin is the distance from the LONG gun's edge, because that edge is where the
  -- head parks: my_range = MAX(range) for both the close decision and the kite cap put the ship at 6
  -- with the autocannon silently disabled. So the fixed engine must settle a FULL BAND WIDTH inside
  -- the long gun, and that number is asserted and printed rather than left implicit in "<= short".
  if v_long - v_dist < v_band - 1e-6 then
    raise exception 'SHORTGUN FAIL: the hull settled % from its target — only % inside its LONGER % gun, against the % band between its two guns. The head parks AT the long edge, so a resting place that is not a whole band inside it is the defect surviving, not the fix landing',
      v_dist, v_long - v_dist, v_long, v_band;
  end if;

  perform public.set_game_config('spatial_formation_ring_radius',        to_jsonb(k_ring));
  perform public.set_game_config('enemy_hp_base',                        to_jsonb(k_ehp));
  perform public.set_game_config('enemy_synthetic_range_base',           to_jsonb(k_erb));
  perform public.set_game_config('enemy_synthetic_range_per_difficulty', to_jsonb(k_erp));
  perform public.set_game_config('enemy_synthetic_speed_base',           to_jsonb(k_esb));
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', to_jsonb(k_esp));
  perform public.set_game_config('combat_player_speed_scale',            to_jsonb(k_pss));

  raise notice 'DZCOMBAT_PASS_SHORTGUN ok: a hull carrying a % range autocannon beside a % range Mk-II opened % from its target — the MEASURED formation extent % (a real escort on the owned ring, never the knob) plus the wave own reach % plus 1 — and closed at % per tick, strictly under the % band so the approach could not step over it; it passed through % tick(s) where only the Mk-II could reach (the head resting place) and came to rest % from its target: exactly its SHORTEST gun edge and a full % inside its LONGEST, with BOTH module types on the record (% short salvo(s), % long)',
    v_short, v_long, round(v_open::numeric, 4), v_extent, v_ren, round(v_speed::numeric, 4), v_band,
    n_bandtick, round(v_dist::numeric, 4), round((v_long - v_dist)::numeric, 4), n_short, n_long;
end $$;

-- ════════ DZCOMBAT_PASS_RETREATCLEAR (0336): EVERY TERMINAL ARM CONSUMES THE RETREAT TARGET ═════════
-- THE DEFECT, RED BY CONSTRUCTION IN PART (A). fleets.retreat_target_location_id / _x / _y is the
-- destination a player ordered mid-combat, and the settle arm's own header states the invariant that
-- the recording is ALWAYS consumed. Only the settle arm ever cleared it. A fleet that DIED, or was
-- wiped, kept a stale destination — and the NEXT sortie of that fleet would then fly to it.
--   (A) THE DEATH ARM, the one that leaks on the head: arm a retreat destination through the real
--       mover, then let the wave kill the fleet, then require all three columns NULL.
--   (B) THE SETTLE ARM, which was never broken: arm the same recording, let the retreat COMPLETE,
--       and require the columns cleared AND the destination actually USED (the minted return leg
--       departs for exactly the ordered point). That half is not a regression test — it exists so
--       that the shared leaf can never be removed from the arm that always did this correctly, and
--       so that "consumed" keeps meaning read-and-clear rather than just clear.
-- The destination is proven UNADMITTED by the fight's own zone authority first, so the order is a
-- retreat rather than an in-zone reposition (0311) — otherwise nothing would be recorded at all and
-- both halves would be vacuous.
do $$
declare
  r jsonb; n int; i int;
  uD uuid; sD uuid; gD uuid;
  uE uuid; sE2 uuid; gE uuid;
  o_x double precision; o_y double precision;
  v_hunt uuid := (select v from dzc where k='v_hunt');
  v_mv uuid; v_enc uuid; v_fleet uuid; mv record; pi record; enc record; fl record;
  v_pool double precision; v_pdef double precision; v_defb double precision; v_bd double precision;
  v_danger int; v_atksc double precision;
  dx double precision; dy double precision;
  v_dead boolean := false; v_ring_now double precision; v_ring0 double precision;
  k_ring double precision; k_ehp double precision; k_eatk double precision;
  k_esb double precision; k_esp double precision; k_srg double precision;
begin
  select coalesce(public.cfg_num('spatial_formation_ring_radius'), 30)          into k_ring;
  select coalesce(public.cfg_num('enemy_hp_base'), 14)                          into k_ehp;
  select coalesce(public.cfg_num('enemy_attack_base'), 1.0)                     into k_eatk;
  select coalesce(public.cfg_num('enemy_synthetic_speed_base'), 0.6)            into k_esb;
  select coalesce(public.cfg_num('enemy_synthetic_speed_per_difficulty'), 0.04) into k_esp;
  select coalesce(public.cfg_num('shield_regen_combat_pct'), 0)                 into k_srg;
  perform public.set_game_config('spatial_formation_ring_radius',        '1'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_base',           '20'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', '0'::jsonb);
  perform public.set_game_config('enemy_hp_base',                        '100000'::jsonb);
  perform public.set_game_config('shield_regen_combat_pct',              '0'::jsonb);

  -- ══ (A) THE DEATH ARM ══════════════════════════════════════════════════════════════════════════
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.rc.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uD;
  insert into public.player_wallet (player_id, balance) values (uD, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
  r := pg_temp.call_as(uD, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'RETREATCLEAR FAIL: commission A: %', r; end if;
  select main_ship_id into sD from public.main_ship_instances where player_id = uD;
  r := pg_temp.call_as(uD, 'public.upsert_ship_group(1, ''Retreat Clear A'')');
  if (r->>'ok')::boolean is not true then raise exception 'RETREATCLEAR FAIL: group A: %', r; end if;
  gD := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uD, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sD, gD));
  if (r->>'ok')::boolean is not true then raise exception 'RETREATCLEAR FAIL: assign A: %', r; end if;
  r := pg_temp.call_as(uD, format('public.set_fleet_command_ship(%L::uuid, true)', sD));
  if (r->>'ok')::boolean is not true then raise exception 'RETREATCLEAR FAIL: command ship A: %', r; end if;
  r := pg_temp.call_as(uD, format('public.set_group_auto_exit(%L::uuid, false, 30)', gD));
  if (r->>'ok')::boolean is not true then raise exception 'RETREATCLEAR FAIL: auto-exit off A: %', r; end if;
  select l.x, l.y into o_x, o_y
    from public.main_ship_instances s
    join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = uD and f.status = 'present'
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
    join public.locations l on l.id = lp.location_id
   where s.group_id = gD
   limit 1;
  if o_x is null then raise exception 'RETREATCLEAR FAIL: could not resolve A''s docked origin'; end if;
  r := pg_temp.call_as(uD, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gD, round(o_x), round(o_y + 1000)));
  if (r->>'ok')::boolean is not true then raise exception 'RETREATCLEAR FAIL: go A: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if pi is null then raise exception 'RETREATCLEAR FAIL: no pending ambush on A''s leg'; end if;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id, fleet_id into v_enc, v_fleet from public.combat_encounters
   where player_id = uD and status = 'active';
  if v_enc is null then raise exception 'RETREATCLEAR FAIL: the ambush opened no encounter for A'; end if;

  select hp_current + coalesce(shield_current, 0), coalesce(defense_snapshot, 0)
    into v_pool, v_pdef from public.combat_units where encounter_id = v_enc and side = 'player';
  v_defb := coalesce(public.cfg_num('defense_curve_base'), 100);
  select l.base_difficulty into v_bd
    from public.combat_encounters ce join public.locations l on l.id = ce.location_id where ce.id = v_enc;
  if v_pool is null or v_pool <= 0 or v_bd is null or v_bd <= 0 or v_defb <= 0 then
    raise exception 'RETREATCLEAR FAIL: hull pool % / base_difficulty % / defense base % cannot size the killing wave', v_pool, v_bd, v_defb;
  end if;
  v_danger := 1 + (select waves_cleared from public.combat_encounters where id = v_enc)
              + floor(extract(epoch from (now() - (select started_at from public.combat_encounters where id = v_enc)))
                      / coalesce(public.cfg_num('danger_time_divisor_seconds'), 180))::int;
  v_atksc := 1 + v_danger * coalesce(public.cfg_num('enemy_attack_danger_scale'), 0.25);
  perform public.set_game_config('enemy_attack_base',
    to_jsonb(round((((0.6 * v_pool) * ((v_defb + v_pdef) / v_defb)) / (v_bd * v_atksc))::numeric, 9)));
  perform pg_temp.ae_tick(v_enc);

  -- ARM THE DESTINATION, through the mover the Retreat-to-a-point UI uses. It must be a point the
  -- fight's own zone authority does NOT admit, or 0311 would REPOSITION instead of retreating and
  -- nothing would be recorded for a terminal arm to consume.
  dx := round(o_x) + 300; dy := round(o_y) + 900;
  if public.combat_encounter_zone_admits_point(v_enc, dx, dy) then
    raise exception 'RETREATCLEAR FAIL: the destination (%,%) IS admitted by a zone that holds the fight — that order repositions instead of retreating, nothing is recorded, and both halves of this block would be vacuous', dx, dy;
  end if;
  r := pg_temp.call_as(uD, format('public.command_ship_group_go(%L::uuid, null, %s, %s)', gD, dx, dy));
  if (r->>'ok')::boolean is not true or (r->>'order_outcome') is distinct from 'retreat_started' then
    raise exception 'RETREATCLEAR FAIL: the retreat order answered % — this block needs a real recorded destination', r;
  end if;
  select * into fl from public.fleets where id = v_fleet;
  if fl.retreat_target_x is distinct from dx or fl.retreat_target_y is distinct from dy then
    raise exception 'RETREATCLEAR FAIL: the destination was not recorded (% , %) — there is nothing for a terminal arm to leak, so the death-arm assert below would pass on every body',
      fl.retreat_target_x, fl.retreat_target_y;
  end if;

  -- KILL IT. The player holds fire while retreating, so this is the wave's work alone.
  for i in 1..12 loop
    perform pg_temp.ae_tick(v_enc);
    select * into enc from public.combat_encounters where id = v_enc;
    if enc.status not in ('active', 'retreating') then v_dead := true; exit; end if;
  end loop;
  if not v_dead then
    raise exception 'RETREATCLEAR FAIL: after 12 ticks the encounter is still % — the fleet never died, so the DEATH arm this half is about was never reached', enc.status;
  end if;
  if enc.status <> 'defeat' then
    raise exception 'RETREATCLEAR FAIL: the encounter concluded as % rather than defeat — a completed retreat routes through the SETTLE arm, which always cleared the recording, so this half would be re-proving part (B)', enc.status;
  end if;
  select * into fl from public.fleets where id = v_fleet;
  if fl.retreat_target_location_id is not null or fl.retreat_target_x is not null or fl.retreat_target_y is not null then
    raise exception 'RETREATCLEAR FAIL: the DEATH arm left the retreat destination behind (%, %, %) — a fleet that died keeps a stale destination that the next sortie settle would fly to',
      fl.retreat_target_location_id, fl.retreat_target_x, fl.retreat_target_y;
  end if;

  -- ══ (B) THE SETTLE ARM: still consumes, and still READS what it consumes ═══════════════════════
  perform public.set_game_config('enemy_attack_base', '0.000001'::jsonb);
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.rc2.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uE;
  insert into public.player_wallet (player_id, balance) values (uE, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
  r := pg_temp.call_as(uE, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'RETREATCLEAR FAIL: commission B: %', r; end if;
  select main_ship_id into sE2 from public.main_ship_instances where player_id = uE;
  r := pg_temp.call_as(uE, 'public.upsert_ship_group(1, ''Retreat Clear B'')');
  if (r->>'ok')::boolean is not true then raise exception 'RETREATCLEAR FAIL: group B: %', r; end if;
  gE := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uE, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sE2, gE));
  if (r->>'ok')::boolean is not true then raise exception 'RETREATCLEAR FAIL: assign B: %', r; end if;
  r := pg_temp.call_as(uE, format('public.set_fleet_command_ship(%L::uuid, true)', sE2));
  if (r->>'ok')::boolean is not true then raise exception 'RETREATCLEAR FAIL: command ship B: %', r; end if;
  r := pg_temp.call_as(uE, format('public.set_group_auto_exit(%L::uuid, false, 30)', gE));
  if (r->>'ok')::boolean is not true then raise exception 'RETREATCLEAR FAIL: auto-exit off B: %', r; end if;
  select l.x, l.y into o_x, o_y
    from public.main_ship_instances s
    join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = uE and f.status = 'present'
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
    join public.locations l on l.id = lp.location_id
   where s.group_id = gE
   limit 1;
  if o_x is null then raise exception 'RETREATCLEAR FAIL: could not resolve B''s docked origin'; end if;
  r := pg_temp.call_as(uE, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gE, round(o_x), round(o_y + 1000)));
  if (r->>'ok')::boolean is not true then raise exception 'RETREATCLEAR FAIL: go B: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if pi is null then raise exception 'RETREATCLEAR FAIL: no pending ambush on B''s leg'; end if;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id, fleet_id into v_enc, v_fleet from public.combat_encounters
   where player_id = uE and status = 'active';
  if v_enc is null then raise exception 'RETREATCLEAR FAIL: the ambush opened no encounter for B'; end if;
  perform pg_temp.ae_tick(v_enc);

  dx := round(o_x) + 300; dy := round(o_y) + 900;
  if public.combat_encounter_zone_admits_point(v_enc, dx, dy) then
    raise exception 'RETREATCLEAR FAIL: B''s destination (%,%) IS admitted — the order would reposition and record nothing', dx, dy;
  end if;
  r := pg_temp.call_as(uE, format('public.command_ship_group_go(%L::uuid, null, %s, %s)', gE, dx, dy));
  if (r->>'ok')::boolean is not true or (r->>'order_outcome') is distinct from 'retreat_started' then
    raise exception 'RETREATCLEAR FAIL: B''s retreat order answered %', r;
  end if;
  select * into fl from public.fleets where id = v_fleet;
  if fl.retreat_target_x is distinct from dx or fl.retreat_target_y is distinct from dy then
    raise exception 'RETREATCLEAR FAIL: B''s destination was not recorded (%, %)', fl.retreat_target_x, fl.retreat_target_y;
  end if;
  -- LET THE WINDOW EXPIRE. CLOCK-ONLY, the drain_encounter law: the retreat delay is measured as
  -- now() - retreat_started_at, and now() is frozen for the txn, so the only way the window can
  -- close is to move the clock the engine reads. No status, no outcome, no geometry is written.
  update public.combat_encounters set retreat_started_at = retreat_started_at - interval '1 hour'
   where id = v_enc;
  perform pg_temp.ae_tick(v_enc);
  select * into enc from public.combat_encounters where id = v_enc;
  if enc.status <> 'escaped' then
    raise exception 'RETREATCLEAR FAIL: B''s encounter is % rather than escaped — the SETTLE arm was never reached, so the second half proves nothing', enc.status;
  end if;
  select * into fl from public.fleets where id = v_fleet;
  if fl.retreat_target_location_id is not null or fl.retreat_target_x is not null or fl.retreat_target_y is not null then
    raise exception 'RETREATCLEAR FAIL: the SETTLE arm left the retreat destination behind (%, %, %) — the shared clearer has been dropped from the one arm that always did this correctly',
      fl.retreat_target_location_id, fl.retreat_target_x, fl.retreat_target_y;
  end if;
  -- and it did not merely CLEAR the recording, it USED it: the return leg departs for that point.
  select count(*) into n from public.fleet_movements
   where fleet_id = v_fleet and mission_type = 'return_home'
     and abs(target_x - dx) <= 1e-6 and abs(target_y - dy) <= 1e-6;
  if n <> 1 then
    raise exception 'RETREATCLEAR FAIL: % return leg(s) depart for the ordered destination (%,%) — the settle arm cleared the recording without READING it, so consumed has stopped meaning read-and-clear and the player is flown somewhere they did not choose',
      n, dx, dy;
  end if;

  perform public.set_game_config('spatial_formation_ring_radius',        to_jsonb(k_ring));
  perform public.set_game_config('enemy_hp_base',                        to_jsonb(k_ehp));
  perform public.set_game_config('enemy_attack_base',                    to_jsonb(k_eatk));
  perform public.set_game_config('enemy_synthetic_speed_base',           to_jsonb(k_esb));
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', to_jsonb(k_esp));
  perform public.set_game_config('shield_regen_combat_pct',              to_jsonb(k_srg));

  -- ── THE LEAK PIN FOR THE WHOLE 0336 SECTION. Every block above OWNS a formation ring so its
  --    fixture can be in contact on the tick it measures, and every one of them restores it. This
  --    is the one place that is checked: the COMMITTED value RANGEINVARIANT captured before any
  --    fixture touched it must be the value still in the row now. 0336 itself moves no knob — it
  --    made the wave's clearance structural instead — so any drift here is a proof fixture that did
  --    not give the world back, and it would move the geometry under every later run.
  v_ring0 := (select v from dzn where k='ring0');
  select public.cfg_num('spatial_formation_ring_radius') into v_ring_now;
  if v_ring0 is null then
    raise exception 'RETREATCLEAR FAIL: the committed formation ring was never captured — the leak pin has nothing to compare against';
  end if;
  if v_ring_now is distinct from v_ring0 then
    raise exception 'RETREATCLEAR FAIL: the formation ring is % but the committed value is % — one of the 0336 blocks owned the knob and did not give it back, so every later fight in this run is being laid out on a fixture value',
      v_ring_now, v_ring0;
  end if;

  raise notice 'DZCOMBAT_PASS_RETREATCLEAR ok: a fleet with a recorded destination (%,%) DIED and all three retreat_target_* columns came back NULL (the head leaked them into the next sortie); the same recording on a fleet that RETREATED to completion was both cleared and USED — exactly one return leg departs for that point — and the formation ring is back at its committed %',
    dx, dy, v_ring0;
end $$;

-- ════════ DZCOMBAT_PASS_ONEANCHOR (0339): ONE WRITER FOR WHERE A FIGHT STANDS — RE-ARMED ═════════
-- ██ THIS BLOCK EXISTS BECAUSE A STATED INVARIANT WITH NO LIVE CHECK IS NOT AN INVARIANT ██
-- 0301:820 declared the encounter creator's INSERT "the only write of engagement_x/engagement_y in
-- the database", and 0301:2556-2566 shipped a schema-wide sweep that RAISES if any function's source
-- matches `set engagement_x`. 0337:486-492 then added exactly that write inside process_combat_ticks
-- — and the 0301 assert DOES NOT RE-RUN, so the drift landed silently and shipped.
-- THE SWEEP IS THE SAME SWEEP. What changes is where it lives: here, against the FULLY-APPLIED
-- CHAIN on a real Postgres, in the one suite triggered on every pull_request AND every push to main.
-- 0339 also carries it as its own self-assert (b), which re-runs on every apply. Neither is a runtime
-- guard on production, and that is stated rather than glossed: a BEFORE UPDATE trigger on
-- combat_encounters would enforce it forever and was REJECTED for blast radius — it would raise on
-- every encounter update of a live 30-player game.
-- IT IS RED ON THE DEPLOYED BODY: on 0338's head the sweep finds process_combat_ticks, because
-- combat_encounter_move does not exist yet.
-- THE SECOND HALF is the spawn fork, retired by the same slice: the tick must no longer place a unit
-- itself, and the two arms must differ ONLY in the stats they hand over.
do $$
declare
  v_other text; v_code text; n int;
begin
  -- (1) EXACTLY ONE FUNCTION IN THE SCHEMA MAY SET engagement_x, AND IT IS THE NAMED AUTHORITY.
  select string_agg(p.proname, ', ') into v_other
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.prokind = 'f'
     and p.proname <> 'combat_encounter_move'
     and regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') ~* 'set[[:space:]]+engagement_x';
  if v_other is not null then
    raise exception 'ONEANCHOR FAIL: % writes engagement_x by UPDATE — combat_encounter_move is the ONE authority for where a fight stands. This is exactly the drift 0301''s spent assert missed when 0337 added its restamp, and finding it here is this block working', v_other;
  end if;
  -- NON-VACUITY: a sweep over an empty set proves nothing. The authority must itself contain the
  -- write, or the clause above is passing because NOBODY writes the column.
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'combat_encounter_move'
     and regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') ~* 'set[[:space:]]+engagement_x';
  if n <> 1 then
    raise exception 'ONEANCHOR FAIL: the named authority does not itself set engagement_x — the sweep above is quantifying over an empty set, which is the vacuity class this repository has been bitten by';
  end if;

  -- (2) AND IT REALLY MOVES ALL THREE, EXECUTED — not asserted from the source text. A leaf that
  -- restamped the anchor without translating the formation would satisfy (1) and leave the fight's
  -- ships behind, which is the three-positions-disagreeing failure it exists to prevent.
  if to_regprocedure('public.combat_encounter_move(uuid, uuid, double precision, double precision, double precision, double precision)') is null then
    raise exception 'ONEANCHOR FAIL: the move authority does not exist at the signature the tick composes';
  end if;
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'combat_encounter_move';
  if position('combat_translate_player_formation' in v_code) = 0
     or position('combat_fleet_track_position' in v_code) = 0 then
    raise exception 'ONEANCHOR FAIL: the move authority does not spend its delta on the formation AND the fleet marker as well as the anchor — three positions that can disagree is the whole defect';
  end if;

  -- (3) THE TICK COMPOSES IT, AND NO LONGER MOVES ANYTHING BY HAND.
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'process_combat_ticks';
  if position('public.combat_encounter_move(' in v_code) = 0 then
    raise exception 'ONEANCHOR FAIL: the tick does not compose the move authority';
  end if;
  if position('public.fleet_set_in_space(' in v_code) > 0 then
    raise exception 'ONEANCHOR FAIL: the tick still writes the fleet position directly — that is how a PRESENT fleet gets silently un-docked, and it is why a site fight could never be manoeuvred in';
  end if;

  -- (4) ONE SPAWN AUTHORITY: the loop that was written twice is written once.
  n := (length(v_code) - length(replace(v_code, 'public.combat_spawn_wave_units(', '')))
       / length('public.combat_spawn_wave_units(');
  if n <> 2 then
    raise exception 'ONEANCHOR FAIL: % composition(s) of the spawn authority in the tick (want exactly 2 — the resolved arm and the synthetic arm, which legitimately differ in the STATS they pass and in nothing else)', n;
  end if;
  -- NOTE the concatenated needle: this harness's own selftest greps for a literal INSERT against the
  -- unit table and treats any occurrence as the proof hand-writing engine state (the sole-writer
  -- law). Splitting the string keeps that law's detector honest while still probing the tick.
  if position('public.combat_formation_point(' in v_code) > 0
     or position('public.combat_wave_arrival_phase(' in v_code) > 0
     or position('v_formation_extent' in v_code) > 0
     or position('insert into ' || 'combat_units' in v_code) > 0 then
    raise exception 'ONEANCHOR FAIL: the tick still measures, places or inserts a wave unit itself — the placement loop existed TWICE and every migration since 0299 had to patch both; it must exist once';
  end if;

  raise notice 'DZCOMBAT_PASS_ONEANCHOR ok: across the whole applied schema exactly ONE function sets engagement_x and it is combat_encounter_move (the sweep 0301 shipped and that never re-ran while 0337 drifted past it), that leaf provably spends its delta on the formation and the fleet marker as well as the anchor, the tick composes it and writes no position by hand, and the enemy-spawn loop that existed TWICE is now one leaf composed exactly twice';
end $$;

-- ════════ DZCOMBAT_PASS_SITEORIGIN (0339): ON A HUNT, THE ENEMY COMES OUT OF THE CITY ════════════
-- ██ THE OWNER'S HEADLINE BUG: "The enemy ships are not comming out from the location - snare." ██
-- They were right, and 0338 — the migration written to make raiders arrive from the zone's own city —
-- was INERT ON EVERY HUNT, by construction. Measured cause, off the deployed bodies: a hunt arrival
-- leaves the fleet 'present', so combat_create_encounter stamped the anchor on the SITE'S OWN
-- COORDINATES; the tick resolved v_anchor := coalesce(engagement_x, loc.x) with both operands the
-- same point; combat_wave_arrival_phase hit its equality guard and returned the neutral 0.5. A plain
-- ring, permanently, on every deliberate fight the owner opens. The ambush path only ever worked
-- because the resolver parks the fleet in open space first.
-- 0339 fixes the ANCHOR, not the leaf: a fight AT a site stands on the edge of that site's own
-- territory_radius, so the site becomes a DIRECTION instead of the place you are standing.
-- THIS BLOCK IS RED ON THE DEPLOYED BODY at its first assert: the anchor equals the site.
-- IT IS THE MIRROR OF NODIRECTION, deliberately — that block now stages a site with NO territory and
-- proves the fallback; this one stages the ordinary site and proves the bearing.
do $$
declare
  r jsonb; n int; n_units int;
  uS uuid; sS uuid; gS uuid;
  v_hunt uuid := (select v from dzc where k='v_hunt');
  lx double precision; ly double precision; v_trad numeric;
  v_mv uuid; v_enc uuid; mv record;
  ax double precision; ay double precision;
  v_d double precision; v_rad double precision; n_on_ray int;
  k_ehp double precision; k_esb double precision; k_esp double precision;
begin
  select coalesce(public.cfg_num('enemy_hp_base'), 14)                          into k_ehp;
  select coalesce(public.cfg_num('enemy_synthetic_speed_base'), 0.6)            into k_esb;
  select coalesce(public.cfg_num('enemy_synthetic_speed_per_difficulty'), 0.04) into k_esp;
  -- the WAVERING staging law: a wave spawns and then MOVES inside one tick, so a block about where a
  -- wave ARRIVES must freeze the close arm and keep everything alive while it measures.
  perform public.set_game_config('enemy_synthetic_speed_base',           '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', '0'::jsonb);
  perform public.set_game_config('enemy_hp_base',                        '100000'::jsonb);

  select l.x, l.y, l.territory_radius into lx, ly, v_trad from public.locations l where l.id = v_hunt;
  if lx is null or ly is null then
    raise exception 'SITEORIGIN FAIL: the shared hunt site carries no coordinate'; end if;
  -- OWNED PRECONDITION, and the one that makes everything below non-vacuous: the site must claim a
  -- real territory, or there is no edge to stand off and the correct answer IS the plain ring (which
  -- NODIRECTION proves). NODIRECTION borrows this column and gives it back; if that give-back ever
  -- leaks, this fires rather than silently measuring the wrong world.
  if v_trad is null or v_trad <= 0 then
    raise exception 'SITEORIGIN FAIL fixture: the hunt site claims no territory (radius %) — there is no edge for a fight to stand off, so the plain ring would be CORRECT here and every bearing assert below would be vacuous. If this fires, an earlier block borrowed locations.territory_radius and did not give it back', v_trad; end if;

  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.so.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uS;
  insert into public.player_wallet (player_id, balance) values (uS, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
  r := pg_temp.call_as(uS, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'SITEORIGIN FAIL: commission: %', r; end if;
  select main_ship_id into sS from public.main_ship_instances where player_id = uS;
  r := pg_temp.call_as(uS, 'public.upsert_ship_group(1, ''Site Origin'')');
  if (r->>'ok')::boolean is not true then raise exception 'SITEORIGIN FAIL: group: %', r; end if;
  gS := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uS, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sS, gS));
  if (r->>'ok')::boolean is not true then raise exception 'SITEORIGIN FAIL: assign: %', r; end if;
  r := pg_temp.call_as(uS, format('public.set_fleet_command_ship(%L::uuid, true)', sS));
  if (r->>'ok')::boolean is not true then raise exception 'SITEORIGIN FAIL: command ship: %', r; end if;
  r := pg_temp.call_as(uS, format('public.set_group_auto_exit(%L::uuid, false, 30)', gS));
  if (r->>'ok')::boolean is not true then raise exception 'SITEORIGIN FAIL: auto-exit off: %', r; end if;

  -- ── A REAL HUNT, through the real verb: the owner's own action. ────────────────────────────────
  r := pg_temp.call_as(uS, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gS, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'SITEORIGIN FAIL: hunt send: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id into v_enc from public.combat_encounters
   where player_id = uS and status = 'active' order by created_at desc limit 1;
  if v_enc is null then raise exception 'SITEORIGIN FAIL: the hunt arrival opened no encounter'; end if;

  -- ── (1) THE FIGHT STANDS OFF THE SITE. This is the assert that fails on the deployed body, where
  -- ── the anchor IS the site and the bearing is therefore undefined.
  select engagement_x, engagement_y into ax, ay from public.combat_encounters where id = v_enc;
  if ax is null or ay is null then
    raise exception 'SITEORIGIN FAIL: the hunt fight carries no engagement anchor — every geometry comparison below would be NULL and pass silently (the 0313 law)'; end if;
  v_d := public.osn_distance(ax, ay, lx, ly);
  if v_d < 1e-6 then
    raise exception 'SITEORIGIN FAIL: the hunt fight is anchored ON its own site (%,%) — so the site and the fight are one point, combat_wave_arrival_phase has no direction to compute, and every wave falls back to the plain ring. THIS IS THE OWNER''S BUG: "the enemy ships are not comming out from the location"', ax, ay; end if;
  -- 1e-5, and the bound is DERIVED not chosen: combat_site_standoff_point rounds each coordinate to
  -- six decimals so the anchor survives the creator's v_roster jsonb round trip BIT FOR BIT (which is
  -- what keeps a lone hull's measured formation extent exactly 0 — see the leaf's own comment and
  -- 0339 assert (d)). That rounding moves each coordinate by at most 0.5e-6, so the radial error is
  -- at most sqrt(2)*0.5e-6 = 7.08e-7. The previous 1e-6 here passed with only ~30% margin, which is
  -- the zero-margin disease this repo has already been bitten by twice; 1e-5 clears the derived
  -- bound and is still a million times finer than the integer grid the world stores positions on.
  if abs(v_d - v_trad::double precision) > 1e-5 then
    raise exception 'SITEORIGIN FAIL: the fight stands % from its site but the site''s territory_radius is % (error %, derived rounding bound 7.08e-7) — a fight at a site must stand on that site''s own edge, from the ONE standoff leaf, never on an invented distance', v_d, v_trad, abs(v_d - v_trad::double precision); end if;

  -- ── (2) SO THE WAVE HAS A BEARING, AND IT POINTS AT THE CITY. ─────────────────────────────────
  perform pg_temp.ae_tick(v_enc);
  select count(*) into n_units from public.combat_units where encounter_id = v_enc and side = 'enemy';
  -- ONE unit is enough, and CI taught this block that: wave 1 at danger 1 is a SINGLE pirate
  -- (least(enemy_synthetic_max_units, greatest(1, danger))), and the first cut demanded two "because
  -- an arc cannot be told from a point". THE PROPERTY HERE IS THE ORIGIN, NOT THE ARC: slot 0 stands
  -- on the bearing to the city whatever the wave size, and with one unit slot 0 IS the whole wave —
  -- a stronger witness, not a weaker one, because there is nowhere else for it to be. The ARC is
  -- owned where it belongs, by DZCOMBAT_PASS_WAVERING, which stages a wave large enough to have one.
  if n_units < 1 then
    raise exception 'SITEORIGIN FAIL: the fight fielded NO enemy row at all — there is no wave whose origin could be measured'; end if;
  select count(*) into n from public.combat_units
   where encounter_id = v_enc and side = 'enemy' and (pos_x is null or pos_y is null);
  if n <> 0 then
    raise exception 'SITEORIGIN FAIL: % enemy row(s) carry no position — an unpositioned wave cannot prove it arrived anywhere (the 0313 law)', n; end if;
  -- the measured radius the wave actually stands at, taken from the wave itself
  select max(public.osn_distance(ax, ay, cu.pos_x, cu.pos_y)) into v_rad
    from public.combat_units cu where cu.encounter_id = v_enc and cu.side = 'enemy';
  if v_rad is null or v_rad <= 0 then
    raise exception 'SITEORIGIN FAIL: the wave stands at radius % from the anchor — there is no ring to take a bearing on', v_rad; end if;
  -- EXACTLY ONE pirate stands where the ray from the fight toward the CITY crosses that radius.
  -- That is the origin, witnessed: slot 0 of the wave is on the bearing, by construction of the
  -- arrival leaf, and no other slot can be (the fan steps off it in half slots).
  select count(*) into n_on_ray from public.combat_units cu
   where cu.encounter_id = v_enc and cu.side = 'enemy'
     and abs(cu.pos_x - (ax + v_rad * (lx - ax) / v_d)) <= 1e-6
     and abs(cu.pos_y - (ay + v_rad * (ly - ay) / v_d)) <= 1e-6;
  if n_on_ray <> 1 then
    raise exception 'SITEORIGIN FAIL: % pirate(s) stand where the ray from the fight (%,%) toward the city (%,%) crosses the wave radius % — want exactly 1. The wave is not coming out of the city, which is what the owner reported',
      n_on_ray, round(ax::numeric,3), round(ay::numeric,3), round(lx::numeric,3), round(ly::numeric,3), round(v_rad::numeric,6); end if;

  perform public.set_game_config('enemy_hp_base',                        to_jsonb(k_ehp));
  perform public.set_game_config('enemy_synthetic_speed_base',           to_jsonb(k_esb));
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', to_jsonb(k_esp));

  raise notice 'DZCOMBAT_PASS_SITEORIGIN ok: a real HUNT at a site with territory_radius % anchored its fight EXACTLY that far off the site (fight %,% vs city %,%), so the city is a DIRECTION rather than the ground under the fleet — and the %-pirate wave then arrived on that bearing, with exactly one raider standing where the ray from the fight toward the city crosses the measured wave radius %. On the deployed body the anchor IS the site, the bearing is undefined and every hunt gets the plain ring: the owner''s "the enemy ships are not comming out from the location - snare"',
    v_trad, round(ax::numeric,3), round(ay::numeric,3), round(lx::numeric,3), round(ly::numeric,3),
    n_units, round(v_rad::numeric,6);
end $$;

do $$ begin raise notice 'DANGER-ZONE COMBAT PROOF PASSED'; end $$;

rollback;   -- self-rolling-back: ZERO persisted state (no COMMIT anywhere above).
