-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- BYSTANDER SEED for the disposable-DB resolver+damage canary proof.
--
-- ██ THROWAWAY DATABASES ONLY — NEVER point this at production. ██  This is the ONE script in the packet
-- that COMMITS. It exists solely so the canary's isolation/fence assertion (8) is NON-VACUOUS: an empty
-- disposable DB would make "ZERO non-canary combat/fleet/ship rows changed" trivially true. It seeds a
-- SECOND, unrelated player with a REAL, ACTIVE combat encounter (its own fleet + player-side combat_units)
-- through the SAME real RPC chain the canary uses (reveal_starter_ports / commission_first_main_ship /
-- upsert_ship_group / assign_ship_to_group / set_fleet_command_ship / send_ship_group_hunt +
-- movement_settle_arrival → combat_create_group_encounter), then COMMITS it.
--
-- PROD-PARITY: the canary is authored FOR production, where the movement/feature gates it depends on but
-- does NOT itself flip (launch_from_dock_enabled / fleet_movement_unified_enabled / fleet_control_enabled /
-- mainship_send_enabled) are committed-TRUE. A fresh disposable stack seeds them FALSE. This seed commits
-- exactly those four movement gates TRUE so the disposable DB matches the committed posture the canary
-- assumes. Every DARK combat/authoring gate — and CRUCIALLY encounter_resolver_enabled — is left/returned
-- committed-FALSE (matching prod), so the canary's in-txn flip of encounter_resolver_enabled is the real
-- pre-flip subject and the harness can prove the flag never persisted.
--
-- CRON-PROOF: the local disposable stack runs pg_cron `process-combat-ticks` every few seconds, and the
-- tick loop selects ANY eligible active/retreating encounter (combat_spatial_tick.sql:559 — no gate on
-- spatial_combat_enabled). We therefore commit the bystander encounter with last_resolved_at set FAR into
-- the future, so `now() - last_resolved_at >= tick_secs` is never true and cron NEVER processes it. The
-- bystander stays a pristine, unchanging active encounter for the harness's before/after byte-identity
-- check. (Inside the canary's own txn the fence bumps this to now(); that is rolled back.)
-- ════════════════════════════════════════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

begin;

set local statement_timeout = '60s';
set local lock_timeout = '5s';

create temp table bys(k text primary key, v text);

-- run an authenticated player RPC as a given subject (identical shape to the canary's pg_temp.call_as).
create or replace function pg_temp.call_as(p_sub uuid, p_fn text) returns jsonb language plpgsql as $fn$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_fn into v;
  return v;
end $fn$;

-- send a group to a hunt location + settle the arrival, returning the created active encounter id
-- (verbatim shape of the canary's pg_temp.send_and_settle).
create or replace function pg_temp.send_and_settle(p_uid uuid, p_group uuid, p_hunt uuid) returns uuid language plpgsql as $fn$
declare r jsonb; v_fleet uuid; v_mv uuid; v_enc uuid;
begin
  r := pg_temp.call_as(p_uid, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', p_group, p_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'BYSTANDER SEND FAIL: %', r; end if;
  v_fleet := (r->>'fleet_id')::uuid; v_mv := (r->>'movement_id')::uuid;
  if v_fleet is null or v_mv is null then raise exception 'BYSTANDER SEND FAIL envelope: %', r; end if;
  update public.fleet_movements set depart_at = now() - interval '2 minutes', arrive_at = now() - interval '1 minute' where id = v_mv;
  r := public.movement_settle_arrival(v_mv);
  if (r->>'settled')::boolean is not true or (r->>'outcome') is distinct from 'present' then raise exception 'BYSTANDER SETTLE FAIL: %', r; end if;
  select id into v_enc from public.combat_encounters where fleet_id = v_fleet and status='active';
  if v_enc is null then raise exception 'BYSTANDER SEND FAIL: no active encounter after arrival'; end if;
  return v_enc;
end $fn$;

-- ════════ Prod-parity gates: TRUE for the four movement gates the canary assumes-but-never-flips, plus
--          the (dark) gates the bystander itself needs to provision + send. The dark ones are returned to
--          FALSE before commit; the four movement gates stay committed-TRUE. ═════════════════════════════
update public.game_config set value='true'::jsonb where key='launch_from_dock_enabled';        -- prod-parity (kept true)
update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';   -- prod-parity (kept true)
update public.game_config set value='true'::jsonb where key='fleet_control_enabled';             -- prod-parity (kept true)
update public.game_config set value='true'::jsonb where key='mainship_send_enabled';             -- prod-parity (kept true)
update public.game_config set value='true'::jsonb where key='team_command_enabled';              -- returned false below
update public.game_config set value='true'::jsonb where key='spatial_combat_enabled';            -- returned false below
-- encounter_resolver_enabled is DELIBERATELY NOT flipped — it stays committed-FALSE (prod posture / the
-- canary's real pre-flip subject / the harness's committed-FALSE post-check).

-- ════════ ONE funded, unrelated bystander player ═════════════════════════════════════════════════════
do $$
declare r jsonb; uB uuid;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'BYSTANDER SETUP FAIL: reveal_starter_ports %', r; end if;

  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'bystander.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uB;
  insert into bys values ('uB', uB::text);
  insert into public.player_wallet (player_id, balance) values (uB, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
end $$;

-- ════════ Provision ONE main ship + a single-ship team, then send it hunting (real RPCs) ══════════════
do $$
declare
  uB uuid := (select v::uuid from bys where k='uB'); r jsonb;
  s uuid; g uuid; v_hunt uuid; v_enc uuid;
begin
  r := pg_temp.call_as(uB, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'BYSTANDER PROVISION FAIL 1st ship: %', r; end if;
  select main_ship_id into s from public.main_ship_instances where player_id = uB;
  if s is null then raise exception 'BYSTANDER PROVISION FAIL: no commissioned ship'; end if;
  insert into bys values ('s', s::text);

  -- normalize the commissioned ship to settled-SAFE 'home' (verbatim the canary/team-command idiom): retire
  -- the commission 'present' dock fleet + complete its presence so the send readiness gate treats it ready.
  update public.main_ship_instances set status='home', updated_at=now() where main_ship_id = s;
  update public.fleets set status='destroyed', location_mode='destroyed', active_movement_id=null,
         current_base_id=null, current_location_id=null, current_zone_id=null, current_sector_id=null, updated_at=now()
   where main_ship_id = s and status='present';
  update public.location_presence set status='completed', updated_at=now()
   where fleet_id in (select id from public.fleets where main_ship_id = s and status='destroyed') and status='active';

  -- the bystander hunts the STRONGEST active hunt location — the opposite end from the canary's weakest
  -- pick (order asc) — so the two players never share a location and cannot couple through it.
  select id into v_hunt from public.locations
    where activity_type = 'hunt_pirates' and status = 'active'
    order by min_power_required desc, base_difficulty desc limit 1;
  if v_hunt is null then raise exception 'BYSTANDER SETUP FAIL: no active hunt_pirates location'; end if;
  insert into bys values ('hunt', v_hunt::text);

  r := pg_temp.call_as(uB, 'public.upsert_ship_group(1, ''Bystander Team'')');
  if (r->>'ok')::boolean is not true then raise exception 'BYSTANDER PROVISION FAIL group: %', r; end if;
  g := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uB, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s, g));
  if (r->>'ok')::boolean is not true then raise exception 'BYSTANDER PROVISION FAIL assign: %', r; end if;
  r := pg_temp.call_as(uB, format('public.set_fleet_command_ship(%L::uuid, true)', s));
  if (r->>'ok')::boolean is not true then raise exception 'BYSTANDER PROVISION FAIL command: %', r; end if;

  v_enc := pg_temp.send_and_settle(uB, g, v_hunt);
  insert into bys values ('enc', v_enc::text);

  -- CRON-PROOF: park the encounter far in the future so the every-few-seconds pg_cron tick never touches
  -- it (the tick's eligibility guard is now() - last_resolved_at >= tick_secs).
  update public.combat_encounters set last_resolved_at = now() + interval '1 day', updated_at = now() where id = v_enc;

  raise notice 'BYSTANDER_SEED: active encounter % for player % at hunt %', v_enc, uB, v_hunt;
end $$;

-- ════════ Return the DARK gates to committed-FALSE (prod posture); keep only the four movement gates TRUE.
update public.game_config set value='false'::jsonb where key='team_command_enabled';
update public.game_config set value='false'::jsonb where key='spatial_combat_enabled';

-- Fail closed if the seed did not actually produce a committed-worthy active encounter.
do $$
declare n int;
begin
  select count(*) into n from public.combat_encounters where status = 'active'
    and last_resolved_at > now() + interval '1 hour';
  if n < 1 then raise exception 'BYSTANDER_SEED FAIL: no cron-proof active bystander encounter to commit (found %)', n; end if;
  if public.cfg_bool('encounter_resolver_enabled') is not false then
    raise exception 'BYSTANDER_SEED FAIL: encounter_resolver_enabled must remain committed-FALSE, is %', public.cfg_bool('encounter_resolver_enabled'); end if;
  raise notice 'BYSTANDER_SEED: PASS — % cron-proof active encounter(s) committed; resolver flag committed-FALSE', n;
end $$;

commit;
