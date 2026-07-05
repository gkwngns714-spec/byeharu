-- PORT-LAUNCH-2B — REAL-CHAIN reveal-precondition + first-player onboarding proof on the ACTUAL chain
-- (through 0068). Disposable only. Proves, in order: (1) dark baseline, (2) reveal semantics, (3) the REAL
-- HOME → Haven legacy main-ship onboarding via the existing send_main_ship_expedition contract →
-- standard movement/arrival → coherent legacy_present → mainship_space_resolve_origin = anchored →
-- get_osn_movement_readiness anchored/osn_available=false, (5) non-combat/non-reward behaviour, then (6)
-- REVERTS the world to fully hidden with no fixtures and no net world/player change.
--
-- Flags: this proof requires mainship_send_enabled=true (the LIVE production value) so the real send path
-- runs; the proof workflow sets it on the DISPOSABLE stack only. mainship_space_movement_enabled stays
-- false here and is asserted false throughout (the dark OSN gate). reveal_starter_ports() is invoked ONLY
-- here, inside this disposable proof, and the world is reverted at the end. Fixture users carry 'pl2bfix.'.

\set ON_ERROR_STOP on

-- Fixed 0066 identities.
create temp table pl2b_id(k text primary key, id uuid) on commit preserve rows;
insert into pl2b_id values
  ('p1','b1a00001-0066-4a00-8a00-000000000001'),   -- Haven (city)
  ('p2','b1a00002-0066-4a00-8a00-000000000002'),   -- Slagworks (port)
  ('p3','b1a00003-0066-4a00-8a00-000000000003'),   -- Driftmarch (port)
  ('a1','b1a0a001-0066-4a00-8a00-0000000000a1'),
  ('s1svc','b1a05001-0066-4a00-8a00-000000000051');

-- snapshot the ORIGINAL (non-port) locations to prove reveal never touches them
create temp table pl2b_orig as
  select id, status from public.locations
  where id not in ('b1a00001-0066-4a00-8a00-000000000001','b1a00002-0066-4a00-8a00-000000000002','b1a00003-0066-4a00-8a00-000000000003');

-- ════════ (1) DARK BASELINE — before any reveal ════════
do $$
declare n int; wm text;
begin
  -- flags: send live (true, set by the proof workflow on the disposable stack), OSN movement dark (false)
  if coalesce(public.cfg_bool('mainship_send_enabled'), false) <> true then
    raise exception 'BASELINE FAIL: mainship_send_enabled must be true for the real send path'; end if;
  if coalesce(public.cfg_bool('mainship_space_movement_enabled'), false) <> false then
    raise exception 'BASELINE FAIL: mainship_space_movement_enabled must be false (dark OSN)'; end if;

  -- 3 ports hidden, parent hierarchy active, role/activity/coord correct (per-port, fail-closed)
  if (select count(*) from public.locations l
        join public.zones z on z.id=l.zone_id join public.sectors se on se.id=z.sector_id
      where l.id = any(array[(select id from pl2b_id where k='p1'),(select id from pl2b_id where k='p2'),(select id from pl2b_id where k='p3')])
        and l.status='hidden' and l.activity_type='none' and l.location_type='trade_outpost'
        and l.physical_role in ('city','port') and z.status='active' and se.status='active') <> 3 then
    raise exception 'BASELINE FAIL: 3 starter ports not coherent-hidden (role/activity/hierarchy)'; end if;

  -- exactly one active canonical anchor per port at the approved in-bounds coordinate; none extra
  if (select count(*) from public.space_anchors a where a.kind='location' and a.status='active'
        and a.location_id in (select id from pl2b_id where k in ('p1','p2','p3'))
        and a.space_x between -10000 and 10000 and a.space_y between -10000 and 10000) <> 3 then
    raise exception 'BASELINE FAIL: expected exactly 3 active in-bounds location anchors'; end if;
  if (select count(*) from public.space_anchors where kind='location' and status='active'
        and location_id in (select id from pl2b_id where k in ('p1','p2','p3'))
        and id not in ('b1a0a001-0066-4a00-8a00-0000000000a1','b1a0a002-0066-4a00-8a00-0000000000a2','b1a0a003-0066-4a00-8a00-0000000000a3')) <> 0 then
    raise exception 'BASELINE FAIL: unexpected starter-port anchor'; end if;

  -- exactly one active docking service per port; none extra
  if (select count(*) from public.location_services where service='docking' and status='active'
        and location_id in (select id from pl2b_id where k in ('p1','p2','p3'))) <> 3 then
    raise exception 'BASELINE FAIL: expected exactly 3 active docking services'; end if;

  -- absent from get_world_map() (no name, no id leak). Name checks are field-anchored ("name": "…"):
  -- the bare word Haven would also match the sector 'Outer Haven'.
  wm := public.get_world_map()::text;
  if wm ~ '"name" *: *"(Haven|Slagworks|Driftmarch)"' or wm ~ 'b1a0000[123]-0066' then
    raise exception 'BASELINE FAIL: a hidden starter port leaks through get_world_map()'; end if;

  -- no pre-existing interaction state for the fixed ports (the exact precondition the prod verifier mirrors)
  if (select count(*) from public.location_presence where status='active' and location_id in (select id from pl2b_id where k in ('p1','p2','p3'))) <> 0
     or (select count(*) from public.fleets where status in ('idle','moving','present','returning') and current_location_id in (select id from pl2b_id where k in ('p1','p2','p3'))) <> 0
     or (select count(*) from public.player_home_port where location_id in (select id from pl2b_id where k in ('p1','p2','p3'))) <> 0 then
    raise exception 'BASELINE FAIL: a starter port already has interaction state'; end if;
  raise notice '(1) dark baseline ok: 3 ports coherent-hidden, anchored/serviced, absent from map, no interaction state, OSN dark';
end $$;

-- ════════ (2) REVEAL SEMANTICS ════════
do $$
declare r jsonb; n int; wm text;
        v_anch_before int; v_svc_before int;
begin
  select count(*) into v_anch_before from public.space_anchors where status='active';
  select count(*) into v_svc_before from public.location_services where status='active';

  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true or (r->>'revealed')::int <> 3 or (r->>'already_active')::boolean <> false then
    raise exception '(2) REVEAL FAIL: %', r; end if;

  -- exactly 3 ports active; no OTHER location status changed
  if (select count(*) from public.locations where id in (select id from pl2b_id where k in ('p1','p2','p3')) and status='active') <> 3 then
    raise exception '(2) REVEAL FAIL: ports not all active'; end if;
  if exists (select 1 from public.locations l join pl2b_orig o on o.id=l.id where l.status is distinct from o.status) then
    raise exception '(2) REVEAL FAIL: a non-port location status changed'; end if;

  -- all 3 now visible through get_world_map()
  wm := public.get_world_map()::text;
  if not (wm ~ '"name" *: *"Haven"' and wm ~ '"name" *: *"Slagworks"' and wm ~ '"name" *: *"Driftmarch"') then
    raise exception '(2) REVEAL FAIL: a revealed port is not visible through get_world_map()'; end if;

  -- anchors/services unchanged; ports remain ordinary trade_outpost / activity_type='none'
  if (select count(*) from public.space_anchors where status='active') <> v_anch_before
     or (select count(*) from public.location_services where status='active') <> v_svc_before then
    raise exception '(2) REVEAL FAIL: an anchor/service changed on reveal'; end if;
  if (select count(*) from public.locations where id in (select id from pl2b_id where k in ('p1','p2','p3'))
        and location_type='trade_outpost' and activity_type='none') <> 3 then
    raise exception '(2) REVEAL FAIL: revealed ports are not ordinary trade_outpost/none locations'; end if;

  -- reveal alone created NO player/ship/fleet/presence/home-port/coordinate-movement, and did not flip flags
  if (select count(*) from public.player_home_port) <> 0
     or (select count(*) from public.location_presence where location_id in (select id from pl2b_id where k in ('p1','p2','p3'))) <> 0
     or (select count(*) from public.main_ship_space_movements where status='moving') <> 0
     or coalesce(public.cfg_bool('mainship_space_movement_enabled'),false) <> false then
    raise exception '(2) REVEAL FAIL: reveal created interaction/flag state'; end if;
  raise notice '(2) reveal ok: exactly 3 ports active + visible; anchors/services/flags/player-state unchanged';
end $$;

-- ════════ (3)+(5) REAL HOME → Haven onboarding via send_main_ship_expedition ════════
do $$
declare u uuid; s uuid; p1 uuid := (select id from pl2b_id where k='p1');
        v_send jsonb; v_fleet uuid; v_move uuid;
        v_origin jsonb; v_ready jsonb; dests jsonb;
        p2 uuid := (select id from pl2b_id where k='p2'); p3 uuid := (select id from pl2b_id where k='p3');
        n int;
begin
  -- a normal HOME player + main ship (provisioned by the established auth trigger + ensure_main_ship_for_player)
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'pl2bfix.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into u;
  perform public.ensure_main_ship_for_player(u);
  select main_ship_id into s from public.main_ship_instances where player_id = u;
  update public.main_ship_instances set status='home', spatial_state=null, space_x=null, space_y=null where main_ship_id=s;
  insert into pl2b_id values ('u', u), ('s', s);

  -- (3.1)+(3.2) the EXISTING command contract accepts the now-active Haven; no special port writer,
  -- no teleport, no base anchor, no home-port assignment. The server derives the player from auth.uid().
  perform set_config('request.jwt.claims', json_build_object('sub', u::text)::text, true);
  v_send := public.send_main_ship_expedition(jsonb_build_array(s::text), p1);
  v_fleet := (v_send->>'fleet_id')::uuid;
  v_move  := (v_send->>'movement_id')::uuid;
  if v_fleet is null or v_move is null then raise exception '(3) SEND FAIL: %', v_send; end if;
  if (select status from public.main_ship_instances where main_ship_id=s) <> 'traveling' then
    raise exception '(3) SEND FAIL: ship not traveling after send'; end if;
  if (select count(*) from public.player_home_port where player_id=u) <> 0
     or (select count(*) from public.space_anchors where kind='base' and base_id in (select id from public.bases where player_id=u)) <> 0 then
    raise exception '(3) SEND FAIL: send created a home-port or base anchor (must not)'; end if;

  -- (3.3) standard legacy movement/arrival processing reaches Haven. Make the movement DUE by moving
  -- its whole window into the past (preserving the arrive_at > depart_at table check), then run the real engine.
  update public.fleet_movements
    set depart_at = now() - interval '2 hours', arrive_at = now() - interval '1 hour' where id = v_move;
  perform public.process_fleet_movements();

  -- (3.4) coherent legacy-present state
  if (select status from public.fleets where id=v_fleet) <> 'present'
     or (select current_location_id from public.fleets where id=v_fleet) <> p1 then
    raise exception '(3) ARRIVE FAIL: fleet not present at Haven'; end if;
  if (select count(*) from public.location_presence where fleet_id=v_fleet and status='active' and location_id=p1) <> 1 then
    raise exception '(3) ARRIVE FAIL: no active presence at Haven'; end if;
  if (select count(*) from public.fleet_movements where fleet_id=v_fleet and status='moving') <> 0 then
    raise exception '(3) ARRIVE FAIL: an active legacy movement remains'; end if;
  if (select count(*) from public.main_ship_space_movements where main_ship_id=s and status='moving') <> 0 then
    raise exception '(3) ARRIVE FAIL: an active coordinate movement exists'; end if;
  if (select spatial_state from public.main_ship_instances where main_ship_id=s) is not null then
    raise exception '(3) ARRIVE FAIL: spatial_state was patched (must stay legacy NULL)'; end if;

  -- (3.5) resolve_origin returns a valid ANCHORED location origin for the now-docked ship
  v_origin := public.mainship_space_resolve_origin(s);
  if (v_origin->>'ok')::boolean is not true or v_origin->>'origin_kind' <> 'location'
     or (v_origin->>'origin_location_id')::uuid <> p1 then
    raise exception '(3) ORIGIN FAIL: resolve_origin not anchored at Haven: %', v_origin; end if;

  -- (3.6) readiness: anchored, osn_available=false, generic dark reason, ONLY the other visible ports, no leak
  v_ready := public.get_osn_movement_readiness();
  if v_ready->>'origin_category' <> 'anchored' or (v_ready->>'osn_available')::boolean <> false
     or v_ready->>'reason' <> 'feature_disabled' then
    raise exception '(3) READINESS FAIL: %', v_ready; end if;
  dests := v_ready->'eligible_destination_ids';
  if jsonb_array_length(dests) <> 2 or not (dests @> to_jsonb(p2) and dests @> to_jsonb(p3)) or (dests @> to_jsonb(p1)) then
    raise exception '(3) READINESS FAIL: destinations not exactly {p2,p3} (current dock p1 excluded): %', v_ready; end if;

  -- (5) non-combat / non-reward: a 'none' port spawns no combat/hunt, generates no combat report or reward
  if (select activity_type from public.locations where id=p1) <> 'none' then
    raise exception '(5) NONCOMBAT FAIL: Haven activity_type changed from none'; end if;
  select count(*) into n from public.combat_reports where player_id = u or location_id = p1;
  if n <> 0 then raise exception '(5) NONCOMBAT FAIL: a combat report was generated for a none-port trip (%)', n; end if;

  -- (3.7) the player can remain safely docked while OSN stays disabled (state is stable + dark)
  raise notice '(3)+(5) onboarding ok: HOME→send→arrive→legacy_present→anchored; readiness anchored/osn_available=false/dests={p2,p3}; no combat/reward';
end $$;

-- ════════ (6) CLEANUP — revert world to fully hidden + remove all fixtures (no net change) ════════
delete from auth.users where email like 'pl2bfix.%@example.com';   -- cascades ships/fleets/presence/movements/bases
update public.locations set status='hidden'                        -- one-way reveal has no unreveal fn; test-only revert
  where id in (select id from pl2b_id where k in ('p1','p2','p3'));
do $$
declare n int;
begin
  select count(*) into n from auth.users where email like 'pl2bfix.%@example.com';
  if n <> 0 then raise exception 'CLEANUP: % fixture users remain', n; end if;
  if (select count(*) from public.locations where id in (select id from pl2b_id where k in ('p1','p2','p3')) and status <> 'hidden') <> 0 then
    raise exception 'CLEANUP: ports not reverted to hidden'; end if;
  if exists (select 1 from public.locations l join pl2b_orig o on o.id=l.id where l.status is distinct from o.status) then
    raise exception 'CLEANUP: an original location status changed'; end if;
  if (select count(*) from public.main_ship_instances s where s.player_id not in (select id from auth.users)) <> 0 then
    raise exception 'CLEANUP: orphan main ships remain'; end if;
  if (select count(*) from public.location_presence where location_id in (select id from pl2b_id where k in ('p1','p2','p3'))) <> 0 then
    raise exception 'CLEANUP: residual presence at a starter port'; end if;
  if (select count(*) from public.space_anchors where status <> 'active') <> 0 then
    raise exception 'CLEANUP: an anchor is not active (fixture leaked anchor state)'; end if;
  if (select count(*) from public.player_home_port) <> 0 then
    raise exception 'CLEANUP: a player_home_port row leaked'; end if;
  raise notice '(6) cleanup ok: 3 ports hidden again, originals unchanged, no fixtures/presence/home-port, anchors active';
end $$;
drop table if exists pl2b_id;
drop table if exists pl2b_orig;

select 'PORT-LAUNCH-2B REVEAL-PRECONDITION + ONBOARDING PROOF PASSED' as result;
