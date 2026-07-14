-- DECKS / ROOMS-8 — disposable write-then-ROLLBACK proof for the deck-rooms system: the 0189
-- station catalog + station axis on ship_captain_assignments, EXTENDED by ROOMS-8 (0203) to a large
-- room catalog (>= 14), 8 captain slots (up from 6), and 8 CONFIGURABLE room-slots per ship that the
-- captain assignment path is now scoped to.
--
-- Runs against a THROWAWAY local Supabase with ALL migrations applied (incl. 0189 + 0203) — NEVER
-- production. Everything below happens inside ONE transaction that ends in ROLLBACK: the dark
-- captain flag (and the station_affinity_bonus knob) are set ONLY in-txn (committed values stay
-- false/0), every fixture is transient, and zero persisted state survives. Fixture users carry the
-- 'dks.' email prefix.
--
-- SOLE-WRITER LAW: captains are provisioned ONLY via the real writers (captains_mint_instance 0118 /
-- the assign_captain_to_ship + unassign_captain_from_ship client wrappers 0120/0121/0189); ROOMS
-- are configured ONLY via configure_ship_room (0203) — the two owned tables are NEVER row-written by
-- this harness EXCEPT the two QUARANTINED backfill surgeries (the .sh greps this): (a) the 0189
-- station-NULLing UPDATE the station-backfill block needs, and (b) the 0203 ship_room_slots DELETE
-- the slot-backfill block needs. Both recreate a pre-migration world no real writer can produce.
--
-- PROPERTY MARKERS (the .sh asserts every one in the output):
--   DECKS_PASS_DARK            — with captain gates dark, assign/unassign/roster + the new room
--                                config/read reject captain_assignment_disabled BEFORE any read,
--                                IDENTICALLY for known and unknown input (no oracle); zero rows.
--   ROOMS8_PASS_SLOTS          — a fresh ship carries EXACTLY 8 default room-slots (the 8 lowest-
--                                sort rooms, slot_index order), read via get_my_ship_room_slots.
--   DECKS_PASS_ASSIGN_STATION  — assign to a named free room: ok envelope carries the station, the
--                                row carries it, the receipt stores it, the roster read projects it.
--   DECKS_PASS_OCCUPIED        — a second captain to the same room rejects station_occupied.
--   DECKS_PASS_UNKNOWN_STATION — a room outside the catalog rejects unknown_station.
--   ROOMS8_PASS_ASSIGN_ROOM    — a catalog room that is NOT one of THIS ship's fitted slots rejects
--                                unknown_station (the ROOMS-8 slot-scoping — a captain can only staff
--                                a fitted room), writes nothing.
--   ROOMS8_PASS_CONFIG         — configure_ship_room swaps a slot's room (happy path visible in the
--                                read); room_duplicate / unknown_room / invalid_slot / room_occupied
--                                all reject; the slot is restored; zero direct table writes.
--   DECKS_PASS_AUTOFILL        — a station-less assign auto-takes the LOWEST-SORT free room among the
--                                ship's 8 slots, deterministically; the headcount cap stays THE
--                                authority (a 9th captain answers captain_slots_full BEFORE any room
--                                reason, so no_free_station is unreachable).
--   DECKS_PASS_UNASSIGN_FREES  — unassign deletes the row and thereby FREES its room; immediately
--                                re-assignable.
--   DECKS_PASS_REPLAY          — a reused request_id replays the ORIGINAL envelope verbatim.
--   ROOMS8_PASS_AFFINITY       — the DECKS-3 affinity fold STILL fires through the preserved adapter
--                                read-shape: with the knob raised in-txn, a ship whose captains staff
--                                matching-affinity rooms gains combat_power vs the knob-0 preview
--                                (proving ship_captain_assignments.station → ship_stations.affinity
--                                is intact — the adapter was NOT re-created).
--   DECKS_PASS_BACKFILL        — the 0189 station backfill maps rows to stations deterministically.
--   ROOMS8_PASS_SLOT_BACKFILL  — the 0203 ship_room_slots backfill re-seeds a stripped ship to its 8
--                                default slots deterministically; re-running it changes nothing.

\set ON_ERROR_STOP on

begin;   -- everything below is transient; the trailing ROLLBACK leaves ZERO persisted state.

create temp table dks(k text primary key, v uuid) on commit preserve rows;

-- caller helper: set the authenticated subject then run an RPC, returning its jsonb.
create or replace function pg_temp.call_as(p_sub uuid, p_fn text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_fn into v;
  return v;
end $$;

-- one fresh player (the on-signup triggers auto-create the Home Base).
do $$
declare u uuid;
begin
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dks.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into u;
  insert into dks values ('u1', u);
end $$;

-- ════════ SETUP: mirror production config a fresh disposable chain lacks (all reverted by ROLLBACK) ════════
do $$
declare r jsonb; n int;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: reveal_starter_ports %', r; end if;
  -- ROOMS-8 (0203): the catalog is now the room catalog — >= 14 rooms, the frozen six (0189/0196)
  -- verbatim in sort order + the eight new rooms (the board/auto-fill/affinity truth).
  select count(*) into n from public.ship_stations;
  if n < 14 then raise exception 'SETUP FAIL: ship_stations has % rooms (want >= 14 — ROOMS-8)', n; end if;
  select count(*) into n
    from (values ('bridge',1),('gunnery',2),('engineering',3),('logistics',4),('sensors',5),('medbay',6)) w(id, srt)
    join public.ship_stations s on s.station_id = w.id and s.sort = w.srt;
  if n <> 6 then raise exception 'SETUP FAIL: the frozen six-station ids/sorts drifted'; end if;
  select count(*) into n from public.ship_stations
    where station_id in ('command_deck','armory','cargo_hold','workshop','comms','outpost','sickbay','observatory');
  if n <> 8 then raise exception 'SETUP FAIL: % of the 8 ROOMS-8 rooms present (want 8)', n; end if;
  -- every hull carries 8 captain slots (the 0203 6->8 bump).
  select count(*) into n from public.main_ship_hull_types where base_captain_slots is distinct from 8;
  if n <> 0 then raise exception 'SETUP FAIL: % hull(s) not at base_captain_slots 8 (want 0 — the ROOMS-8 bump)', n; end if;
  raise notice 'setup ok: starter ports revealed; room catalog >= 14 (frozen six verbatim + 8 new); hulls at 8 captain slots (transient fixture user created)';
end $$;

-- ════════ BLOCK DARK: the captain + room command surfaces reject EXACTLY as before (no oracle) ════════
-- Run BEFORE the flag flip, as a REAL authenticated sub, with RANDOM NONEXISTENT ids — and with BOTH
-- a known ('gunnery') and an unknown ('helm') station: while dark the answer must be the IDENTICAL
-- captain_assignment_disabled envelope regardless of input (no station existence oracle;
-- reject-before-any-read preserved). The ROOMS-8 config/read wrappers ride the SAME dark gate.
do $$
declare r jsonb; r2 jsonb; n int; u1 uuid := (select v from dks where k='u1');
begin
  r := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, gen_random_uuid(), gen_random_uuid(), %L)', 'dks-dark-1', 'gunnery'));
  if r::text is distinct from '{"ok": false, "reason": "captain_assignment_disabled"}' then
    raise exception 'DARK FAIL assign(known station): %', r; end if;
  r2 := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, gen_random_uuid(), gen_random_uuid(), %L)', 'dks-dark-2', 'helm'));
  if r2::text is distinct from r::text then
    raise exception 'DARK FAIL: unknown station answers differently while dark (oracle!): % vs %', r2, r; end if;
  r := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, gen_random_uuid(), gen_random_uuid())', 'dks-dark-3'));
  if (r->>'reason') is distinct from 'captain_assignment_disabled' then
    raise exception 'DARK FAIL assign(no station): %', r; end if;
  r := pg_temp.call_as(u1, format('public.unassign_captain_from_ship(%L, gen_random_uuid())', 'dks-dark-4'));
  if (r->>'reason') is distinct from 'captain_assignment_disabled' then
    raise exception 'DARK FAIL unassign: %', r; end if;
  r := pg_temp.call_as(u1, 'public.get_my_captain_instances()');
  if (r->>'reason') is distinct from 'captain_assignment_disabled' then
    raise exception 'DARK FAIL roster read: %', r; end if;
  -- ROOMS-8: the new room config wrapper + read RPC are dark too, with the SAME no-oracle property.
  r := pg_temp.call_as(u1, format('public.configure_ship_room(gen_random_uuid(), 1, %L)', 'gunnery'));
  if (r->>'reason') is distinct from 'captain_assignment_disabled' then
    raise exception 'DARK FAIL configure_ship_room(known room): %', r; end if;
  r2 := pg_temp.call_as(u1, format('public.configure_ship_room(gen_random_uuid(), 1, %L)', 'helm'));
  if r2::text is distinct from r::text then
    raise exception 'DARK FAIL: configure answers differently while dark (oracle!): % vs %', r2, r; end if;
  r := pg_temp.call_as(u1, 'public.get_my_ship_room_slots(gen_random_uuid())');
  if (r->>'reason') is distinct from 'captain_assignment_disabled' then
    raise exception 'DARK FAIL room slots read: %', r; end if;
  select count(*) into n from public.ship_captain_assignments;
  if n <> 0 then raise exception 'DARK FAIL: % assignment rows written while dark (want 0)', n; end if;
  select count(*) into n from public.captain_assignment_receipts;
  if n <> 0 then raise exception 'DARK FAIL: % receipts written while dark (want 0)', n; end if;
  raise notice 'DECKS_PASS_DARK ok: assign/unassign/roster + room config/read reject captain_assignment_disabled before any read; known and unknown input answer identically; 0 rows written';
end $$;

-- enable the dark capability ONLY inside this rolled-back txn (committed/production value stays false).
update public.game_config set value='true'::jsonb where key='captain_assignment_enabled';

-- ════════ PROVISION via the REAL RPCs/writers: one ship (canonically docked = settled-SAFE), 9 captains ════════
do $$
declare r jsonb; u1 uuid := (select v from dks where k='u1'); s1 uuid; c uuid; i int;
begin
  r := pg_temp.call_as(u1, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL first ship: %', r; end if;
  select main_ship_id into s1 from public.main_ship_instances where player_id = u1;
  if s1 is null then raise exception 'PROVISION FAIL: no ship row'; end if;
  insert into dks values ('s1', s1);
  -- 9 captains through THE mint writer (8 slots + 1 to prove the headcount cap stays first).
  for i in 1..9 loop
    c := public.captains_mint_instance(u1, 'gunnery_veteran', 'dks-mint-' || i);
    if c is null then raise exception 'PROVISION FAIL: mint % returned null', i; end if;
    insert into dks values ('cap' || i, c);
  end loop;
  raise notice 'provision ok: 1 commissioned (docked, settled-SAFE) ship + 9 minted captains, all via the real writers';
end $$;

-- ════════ BLOCK ROOMS8_SLOTS: the commission trigger seeded EXACTLY 8 default room-slots ════════
do $$
declare r jsonb; n int; u1 uuid := (select v from dks where k='u1'); s1 uuid := (select v from dks where k='s1');
begin
  r := pg_temp.call_as(u1, format('public.get_my_ship_room_slots(%L::uuid)', s1));
  if (r->>'ok')::boolean is not true then raise exception 'ROOMS8_SLOTS FAIL read: %', r; end if;
  select count(*) into n from jsonb_array_elements(r->'slots');
  if n <> 8 then raise exception 'ROOMS8_SLOTS FAIL: % slots (want exactly 8)', n; end if;
  -- the 8 defaults ARE the 8 lowest-sort rooms in slot_index order (deterministic seed).
  select count(*) into n
    from (values (1,'bridge'),(2,'gunnery'),(3,'engineering'),(4,'logistics'),
                 (5,'sensors'),(6,'medbay'),(7,'command_deck'),(8,'armory')) w(idx, room)
    join jsonb_array_elements(r->'slots') e
      on (e->>'slot_index')::int = w.idx and e->>'room_type_id' = w.room;
  if n <> 8 then raise exception 'ROOMS8_SLOTS FAIL: default slot mapping drifted: %', r->'slots'; end if;
  raise notice 'ROOMS8_PASS_SLOTS ok: the commission trigger seeded exactly 8 default room-slots (bridge..armory by slot_index)';
end $$;

-- ════════ BLOCK ASSIGN_STATION: named-room happy path (envelope + row + receipt + roster) ════════
do $$
declare r jsonb; n int; u1 uuid := (select v from dks where k='u1');
  s1 uuid := (select v from dks where k='s1'); cap1 uuid := (select v from dks where k='cap1');
begin
  r := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid, %L)', 'dks-req-1', cap1, s1, 'gunnery'));
  if (r->>'ok')::boolean is not true or (r->>'action') is distinct from 'assign'
     or (r->>'station') is distinct from 'gunnery'
     or (r->>'idempotent_replay')::boolean is distinct from false then
    raise exception 'ASSIGN_STATION FAIL envelope: %', r; end if;
  select count(*) into n from public.ship_captain_assignments
    where captain_instance_id = cap1 and main_ship_id = s1 and station = 'gunnery';
  if n <> 1 then raise exception 'ASSIGN_STATION FAIL: row does not carry station gunnery'; end if;
  select count(*) into n from public.captain_assignment_receipts
    where player_id = u1 and request_id = 'dks-req-1' and result_json->>'station' = 'gunnery';
  if n <> 1 then raise exception 'ASSIGN_STATION FAIL: receipt result_json lacks station gunnery'; end if;
  r := pg_temp.call_as(u1, 'public.get_my_captain_instances()');
  if (r->>'ok')::boolean is not true then raise exception 'ASSIGN_STATION FAIL roster: %', r; end if;
  select count(*) into n from jsonb_array_elements(r->'captains') e
    where e->>'instance_id' = cap1::text and e->>'station' = 'gunnery' and e->>'main_ship_id' = s1::text;
  if n <> 1 then raise exception 'ASSIGN_STATION FAIL: roster read does not project station gunnery: %', r->'captains'; end if;
  raise notice 'DECKS_PASS_ASSIGN_STATION ok: named assign lands on gunnery in the envelope, the row, the receipt, and the roster projection';
end $$;

-- ════════ BLOCK OCCUPIED: a second captain to a held room rejects station_occupied ════════
do $$
declare r jsonb; n int; u1 uuid := (select v from dks where k='u1');
  s1 uuid := (select v from dks where k='s1'); cap2 uuid := (select v from dks where k='cap2');
begin
  r := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid, %L)', 'dks-req-occ', cap2, s1, 'gunnery'));
  if (r->>'ok')::boolean is not false or (r->>'reason') is distinct from 'station_occupied'
     or (r->>'message') is null then
    raise exception 'OCCUPIED FAIL envelope: %', r; end if;
  select count(*) into n from public.ship_captain_assignments;
  if n <> 1 then raise exception 'OCCUPIED FAIL: reject wrote a row (% total, want 1)', n; end if;
  select count(*) into n from public.captain_assignment_receipts where request_id = 'dks-req-occ';
  if n <> 0 then raise exception 'OCCUPIED FAIL: a FAILED command wrote a receipt'; end if;
  raise notice 'DECKS_PASS_OCCUPIED ok: station_occupied reject, zero writes (failure-writes-no-receipt holds)';
end $$;

-- ════════ BLOCK UNKNOWN_STATION: a room outside the catalog rejects unknown_station ════════
do $$
declare r jsonb; n int; u1 uuid := (select v from dks where k='u1');
  s1 uuid := (select v from dks where k='s1'); cap2 uuid := (select v from dks where k='cap2');
begin
  r := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid, %L)', 'dks-req-unk', cap2, s1, 'helm'));
  if (r->>'ok')::boolean is not false or (r->>'reason') is distinct from 'unknown_station' then
    raise exception 'UNKNOWN_STATION FAIL envelope: %', r; end if;
  select count(*) into n from public.ship_captain_assignments;
  if n <> 1 then raise exception 'UNKNOWN_STATION FAIL: reject wrote a row'; end if;
  raise notice 'DECKS_PASS_UNKNOWN_STATION ok: helm rejects unknown_station, zero writes';
end $$;

-- ════════ BLOCK ROOMS8_ASSIGN_ROOM: a catalog room NOT fitted on this ship rejects unknown_station ════════
-- The ROOMS-8 slot-scoping: 'observatory' is a REAL catalog room (sort 14) but NOT one of s1's 8
-- fitted slots — so a captain cannot staff it. The pre-0203 world would have accepted it (catalog-
-- wide); ROOMS-8 rejects it exactly like a nonexistent room. Zero writes.
do $$
declare r jsonb; n int; u1 uuid := (select v from dks where k='u1');
  s1 uuid := (select v from dks where k='s1'); cap2 uuid := (select v from dks where k='cap2');
begin
  r := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid, %L)', 'dks-req-nofit', cap2, s1, 'observatory'));
  if (r->>'ok')::boolean is not false or (r->>'reason') is distinct from 'unknown_station' then
    raise exception 'ROOMS8_ASSIGN_ROOM FAIL: a non-fitted catalog room answered % (want unknown_station)', r; end if;
  select count(*) into n from public.ship_captain_assignments;
  if n <> 1 then raise exception 'ROOMS8_ASSIGN_ROOM FAIL: reject wrote a row'; end if;
  raise notice 'ROOMS8_PASS_ASSIGN_ROOM ok: a catalog room not fitted on this ship rejects unknown_station (slot-scoping), zero writes';
end $$;

-- ════════ BLOCK ROOMS8_CONFIG: configure_ship_room swaps a slot's room; rejects the illegal cases ════════
do $$
declare r jsonb; n int; u1 uuid := (select v from dks where k='u1'); s1 uuid := (select v from dks where k='s1');
begin
  -- HAPPY: swap slot 8 (armory) -> cargo_hold (a fitted-elsewhere-free room); the read reflects it.
  r := pg_temp.call_as(u1, format('public.configure_ship_room(%L::uuid, 8, %L)', s1, 'cargo_hold'));
  if (r->>'ok')::boolean is not true or (r->>'room_type_id') is distinct from 'cargo_hold' then
    raise exception 'ROOMS8_CONFIG FAIL happy: %', r; end if;
  r := pg_temp.call_as(u1, format('public.get_my_ship_room_slots(%L::uuid)', s1));
  select count(*) into n from jsonb_array_elements(r->'slots') e
    where (e->>'slot_index')::int = 8 and e->>'room_type_id' = 'cargo_hold';
  if n <> 1 then raise exception 'ROOMS8_CONFIG FAIL: read does not reflect the swap: %', r->'slots'; end if;
  -- ROOM_DUPLICATE: slot 7 -> bridge (bridge already fills slot 1) rejects.
  r := pg_temp.call_as(u1, format('public.configure_ship_room(%L::uuid, 7, %L)', s1, 'bridge'));
  if (r->>'reason') is distinct from 'room_duplicate' then
    raise exception 'ROOMS8_CONFIG FAIL duplicate: %', r; end if;
  -- UNKNOWN_ROOM: slot 1 -> 'helm' (not in the catalog) rejects.
  r := pg_temp.call_as(u1, format('public.configure_ship_room(%L::uuid, 1, %L)', s1, 'helm'));
  if (r->>'reason') is distinct from 'unknown_room' then
    raise exception 'ROOMS8_CONFIG FAIL unknown_room: %', r; end if;
  -- INVALID_SLOT: slot 9 (out of the 1..8 range) rejects.
  r := pg_temp.call_as(u1, format('public.configure_ship_room(%L::uuid, 9, %L)', s1, 'workshop'));
  if (r->>'reason') is distinct from 'invalid_slot' then
    raise exception 'ROOMS8_CONFIG FAIL invalid_slot: %', r; end if;
  -- ROOM_OCCUPIED: slot 2 holds gunnery, which cap1 staffs (ASSIGN_STATION) — refit rejects.
  r := pg_temp.call_as(u1, format('public.configure_ship_room(%L::uuid, 2, %L)', s1, 'workshop'));
  if (r->>'reason') is distinct from 'room_occupied' then
    raise exception 'ROOMS8_CONFIG FAIL room_occupied: %', r; end if;
  -- RESTORE slot 8 back to armory so the AUTOFILL walk below stays the default (bridge..armory).
  r := pg_temp.call_as(u1, format('public.configure_ship_room(%L::uuid, 8, %L)', s1, 'armory'));
  if (r->>'ok')::boolean is not true or (r->>'room_type_id') is distinct from 'armory' then
    raise exception 'ROOMS8_CONFIG FAIL restore: %', r; end if;
  raise notice 'ROOMS8_PASS_CONFIG ok: configure swaps a slot (read reflects it); room_duplicate/unknown_room/invalid_slot/room_occupied all reject; slot restored';
end $$;

-- ════════ BLOCK AUTOFILL: station-less assigns take the LOWEST-SORT free room; the cap stays first ════════
do $$
declare r jsonb; n int; u1 uuid := (select v from dks where k='u1');
  s1 uuid := (select v from dks where k='s1');
  cap2 uuid := (select v from dks where k='cap2'); cap3 uuid := (select v from dks where k='cap3');
  cap4 uuid := (select v from dks where k='cap4'); cap5 uuid := (select v from dks where k='cap5');
  cap6 uuid := (select v from dks where k='cap6'); cap7 uuid := (select v from dks where k='cap7');
  cap8 uuid := (select v from dks where k='cap8'); cap9 uuid := (select v from dks where k='cap9');
begin
  -- gunnery (sort 2) is held → the lowest-sort FREE room is bridge (sort 1).
  r := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid)', 'dks-req-af1', cap2, s1));
  if (r->>'ok')::boolean is not true or (r->>'station') is distinct from 'bridge' then
    raise exception 'AUTOFILL FAIL: expected bridge, got %', r; end if;
  -- bridge + gunnery held → next free by sort is engineering (sort 3).
  r := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid)', 'dks-req-af2', cap3, s1));
  if (r->>'station') is distinct from 'engineering' then raise exception 'AUTOFILL FAIL: expected engineering, got %', r; end if;
  -- fill the rest in strict sort order among the 8 fitted rooms: logistics -> sensors -> medbay ->
  -- command_deck -> armory.
  r := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid)', 'dks-req-af3', cap4, s1));
  if (r->>'station') is distinct from 'logistics' then raise exception 'AUTOFILL FAIL: expected logistics, got %', r; end if;
  r := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid)', 'dks-req-af4', cap5, s1));
  if (r->>'station') is distinct from 'sensors' then raise exception 'AUTOFILL FAIL: expected sensors, got %', r; end if;
  r := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid)', 'dks-req-af5', cap6, s1));
  if (r->>'station') is distinct from 'medbay' then raise exception 'AUTOFILL FAIL: expected medbay, got %', r; end if;
  r := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid)', 'dks-req-af6', cap7, s1));
  if (r->>'station') is distinct from 'command_deck' then raise exception 'AUTOFILL FAIL: expected command_deck, got %', r; end if;
  r := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid)', 'dks-req-af7', cap8, s1));
  if (r->>'station') is distinct from 'armory' then raise exception 'AUTOFILL FAIL: expected armory, got %', r; end if;
  select count(*) into n from public.ship_captain_assignments where main_ship_id = s1 and station is not null;
  if n <> 8 then raise exception 'AUTOFILL FAIL: % stationed rows (want 8/8)', n; end if;
  -- THE CAP STAYS THE AUTHORITY: a 9th captain answers captain_slots_full — the 0119 headcount
  -- reject fires BEFORE any room reason (explicit-room probe), and no_free_station is therefore
  -- unreachable while captain_slots = 8 = the slot count (station-less probe).
  r := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid, %L)', 'dks-req-af8', cap9, s1, 'bridge'));
  if (r->>'reason') is distinct from 'captain_slots_full' then
    raise exception 'AUTOFILL FAIL: 9th (explicit room) answered % (want captain_slots_full before station_occupied)', r; end if;
  r := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid)', 'dks-req-af9', cap9, s1));
  if (r->>'reason') is distinct from 'captain_slots_full' then
    raise exception 'AUTOFILL FAIL: 9th (auto) answered % (want captain_slots_full — no_free_station unreachable)', r; end if;
  raise notice 'DECKS_PASS_AUTOFILL ok: auto-assign walked bridge->gunnery(held)->engineering->logistics->sensors->medbay->command_deck->armory by sort; headcount cap rejects the 9th before any room reason';
end $$;

-- ════════ BLOCK UNASSIGN_FREES: the row delete frees the room for immediate re-assign ════════
do $$
declare r jsonb; n int; u1 uuid := (select v from dks where k='u1');
  s1 uuid := (select v from dks where k='s1');
  cap1 uuid := (select v from dks where k='cap1'); cap9 uuid := (select v from dks where k='cap9');
begin
  -- cap1 holds gunnery (ASSIGN_STATION). Unassign through the UNTOUCHED 0120 wrapper — this also
  -- proves the 2-arg wrapper late-binds cleanly onto the re-created defaulted command.
  r := pg_temp.call_as(u1, format('public.unassign_captain_from_ship(%L, %L::uuid)', 'dks-req-un1', cap1));
  if (r->>'ok')::boolean is not true or (r->>'action') is distinct from 'unassign' then
    raise exception 'UNASSIGN_FREES FAIL envelope: %', r; end if;
  select count(*) into n from public.ship_captain_assignments where captain_instance_id = cap1;
  if n <> 0 then raise exception 'UNASSIGN_FREES FAIL: cap1 row survives'; end if;
  select count(*) into n from public.ship_captain_assignments where main_ship_id = s1 and station = 'gunnery';
  if n <> 0 then raise exception 'UNASSIGN_FREES FAIL: gunnery still reads held'; end if;
  -- the freed room is immediately assignable again (explicit, so ONLY the free-ness decides).
  r := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid, %L)', 'dks-req-un2', cap9, s1, 'gunnery'));
  if (r->>'ok')::boolean is not true or (r->>'station') is distinct from 'gunnery' then
    raise exception 'UNASSIGN_FREES FAIL re-assign: %', r; end if;
  raise notice 'DECKS_PASS_UNASSIGN_FREES ok: unassign deleted the row, gunnery freed and immediately re-held by another captain';
end $$;

-- ════════ BLOCK REPLAY: a reused request_id replays the ORIGINAL envelope verbatim, mutating nothing ════════
do $$
declare r jsonb; n int; u1 uuid := (select v from dks where k='u1');
  s1 uuid := (select v from dks where k='s1'); cap1 uuid := (select v from dks where k='cap1');
begin
  -- dks-req-1 originally assigned cap1 -> gunnery. Replay it with DIFFERENT args (room medbay):
  -- trade semantics (0113/0120) — the stored envelope returns verbatim + idempotent_replay, the
  -- differing payload is IGNORED, and nothing moves (cap1 stays unassigned; gunnery stays cap9's).
  r := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid, %L)', 'dks-req-1', cap1, s1, 'medbay'));
  if (r->>'ok')::boolean is not true or (r->>'idempotent_replay')::boolean is not true
     or (r->>'station') is distinct from 'gunnery' or (r->>'captain_instance_id') is distinct from cap1::text then
    raise exception 'REPLAY FAIL envelope: %', r; end if;
  select count(*) into n from public.ship_captain_assignments where captain_instance_id = cap1;
  if n <> 0 then raise exception 'REPLAY FAIL: the replay re-assigned cap1'; end if;
  select count(*) into n from public.ship_captain_assignments where main_ship_id = s1;
  if n <> 8 then raise exception 'REPLAY FAIL: row count moved to % (want 8)', n; end if;
  select count(*) into n from public.captain_assignment_receipts where player_id = u1 and request_id = 'dks-req-1';
  if n <> 1 then raise exception 'REPLAY FAIL: receipt duplicated'; end if;
  raise notice 'DECKS_PASS_REPLAY ok: reused request_id returned the original station-bearing envelope verbatim (idempotent_replay), zero mutations';
end $$;

-- ════════ BLOCK ROOMS8_AFFINITY: the DECKS-3 fold STILL fires — the adapter read-shape is preserved ════════
-- s1 now has 8 gunnery_veteran (combat) captains staffing bridge/gunnery/engineering/logistics/
-- sensors/medbay/command_deck/armory. Two of those rooms have combat affinity (gunnery, armory), so
-- with the knob raised the matched captains' combat contribution scales — proving
-- ship_captain_assignments.station -> ship_stations.affinity_specialization is read by the UNCHANGED
-- adapter (calculate_expedition_stats was NOT re-created by ROOMS-8). Knob is set in-txn only.
do $$
declare p0 jsonb; p1 jsonb; cp0 numeric; cp1 numeric; u1 uuid := (select v from dks where k='u1');
  s1 uuid := (select v from dks where k='s1');
begin
  -- knob committed '0' (byte-inert): baseline combat_power.
  p0 := pg_temp.call_as(u1, format('public.get_my_expedition_preview(''[]''::jsonb, ''none'', %L::uuid)', s1));
  if (p0->>'valid')::boolean is not true then raise exception 'ROOMS8_AFFINITY FAIL baseline preview: %', p0; end if;
  cp0 := (p0->'stats'->>'combat_power')::numeric;
  -- raise the knob IN-TXN only (rolled back). The committed seed is asserted '0' first (parity pin).
  if (select value #>> '{}' from public.game_config where key = 'station_affinity_bonus') is distinct from '0' then
    raise exception 'ROOMS8_AFFINITY FAIL: committed station_affinity_bonus is not 0 (the 0196 seed)'; end if;
  update public.game_config set value = '0.15'::jsonb where key = 'station_affinity_bonus';
  p1 := pg_temp.call_as(u1, format('public.get_my_expedition_preview(''[]''::jsonb, ''none'', %L::uuid)', s1));
  if (p1->>'valid')::boolean is not true then raise exception 'ROOMS8_AFFINITY FAIL lit preview: %', p1; end if;
  cp1 := (p1->'stats'->>'combat_power')::numeric;
  if not (cp1 > cp0) then
    raise exception 'ROOMS8_AFFINITY FAIL: knob 0.15 did not raise combat_power (%.->%) — the adapter no longer reads station affinity?', cp0, cp1; end if;
  -- restore the knob to its committed inert value inside the txn (belt-and-braces; ROLLBACK also reverts).
  update public.game_config set value = '0'::jsonb where key = 'station_affinity_bonus';
  raise notice 'ROOMS8_PASS_AFFINITY ok: with the knob raised in-txn, a ship whose captains staff matching-affinity rooms gains combat_power (% -> %) — the DECKS-3 read-shape (station -> ship_stations.affinity) is intact; the adapter was NOT re-created', cp0, cp1;
end $$;

-- ════════ BLOCK BACKFILL: the 0189 station backfill statement is deterministic and monotonic ════════
-- QUARANTINED FIXTURE SURGERY (the one non-writer step for ship_captain_assignments, see header): no
-- real writer can produce a station-less row post-0189, so recreate the pre-0189 world by hand — NULL
-- every station and pin a known assigned_at order — then run the migration's backfill VERBATIM and
-- assert the mapping. With >= 14 rooms only the first 8 ranks are used (8 assignment rows).
update public.ship_captain_assignments a
   set station = null,
       assigned_at = timestamptz '2026-07-01 00:00:00+00'
                     + make_interval(secs => sub.rn)
  from (select captain_instance_id,
               row_number() over (order by captain_instance_id) as rn
          from public.ship_captain_assignments) sub
 where a.captain_instance_id = sub.captain_instance_id;

-- ── the 0189 backfill, VERBATIM (reviewers: extract-and-diff against the migration §8) ───────────
with ranked as (
  select a.captain_instance_id,
         row_number() over (partition by a.main_ship_id
                            order by a.assigned_at, a.captain_instance_id) as rn
    from public.ship_captain_assignments a
   where a.station is null
), stations as (
  select station_id, row_number() over (order by sort) as rn
    from public.ship_stations
)
update public.ship_captain_assignments a
   set station = s.station_id
  from ranked r
  join stations s on s.rn = r.rn
 where a.captain_instance_id = r.captain_instance_id;

do $$
declare n int; v_before text;
begin
  -- no null survives, and the mapping IS (assigned_at, captain_instance_id) order -> sort order.
  select count(*) into n from public.ship_captain_assignments where station is null;
  if n <> 0 then raise exception 'BACKFILL FAIL: % station-less rows survive', n; end if;
  select count(*) into n
    from (select captain_instance_id, station,
                 row_number() over (partition by main_ship_id order by assigned_at, captain_instance_id) as rn
            from public.ship_captain_assignments) a
    join (select station_id, row_number() over (order by sort) as rn from public.ship_stations) s
      on s.rn = a.rn
   where a.station is distinct from s.station_id;
  if n <> 0 then raise exception 'BACKFILL FAIL: % rows off the deterministic (assigned_at -> sort) mapping', n; end if;

  -- MONOTONIC: a second run touches nothing (only null rows rank; there are none).
  select string_agg(captain_instance_id::text || ':' || station, ',' order by captain_instance_id)
    into v_before from public.ship_captain_assignments;
  with ranked as (
    select a.captain_instance_id,
           row_number() over (partition by a.main_ship_id
                              order by a.assigned_at, a.captain_instance_id) as rn
      from public.ship_captain_assignments a
     where a.station is null
  ), stations as (
    select station_id, row_number() over (order by sort) as rn
      from public.ship_stations
  )
  update public.ship_captain_assignments a
     set station = s.station_id
    from ranked r
    join stations s on s.rn = r.rn
   where a.captain_instance_id = r.captain_instance_id;
  if (select string_agg(captain_instance_id::text || ':' || station, ',' order by captain_instance_id)
        from public.ship_captain_assignments) is distinct from v_before then
    raise exception 'BACKFILL FAIL: a second run moved stations (not monotonic)'; end if;

  raise notice 'DECKS_PASS_BACKFILL ok: verbatim 0189 backfill maps (assigned_at, id) order onto sort order deterministically; second run is a no-op';
end $$;

-- ════════ BLOCK ROOMS8_SLOT_BACKFILL: the 0203 ship_room_slots backfill is deterministic + monotonic ════════
-- QUARANTINED FIXTURE SURGERY (the one ship_room_slots non-writer step): the trigger seeds slots for
-- every commissioned ship, so recreate a pre-0203 ship by hand — DELETE s1's slots — then run the
-- migration's slot-backfill VERBATIM and assert the 8 defaults come back. (Other ships already have
-- their 8; on-conflict-do-nothing makes the ALL-ships statement a no-op for them.)
delete from public.ship_room_slots a
  using dks
 where dks.k = 's1' and a.main_ship_id = dks.v;

-- ── the 0203 ship_room_slots backfill, VERBATIM (reviewers: extract-and-diff against migration §5) ─
insert into public.ship_room_slots (main_ship_id, slot_index, room_type_id)
  select i.main_ship_id, d.rn, d.station_id
    from public.main_ship_instances i
    cross join (select station_id, row_number() over (order by sort) as rn
                  from public.ship_stations order by sort limit 8) d
on conflict (main_ship_id, slot_index) do nothing;

do $$
declare n int; v_before text; s1 uuid := (select v from dks where k='s1');
begin
  -- s1 has its 8 defaults back, in slot_index order = the 8 lowest-sort rooms.
  select count(*) into n from public.ship_room_slots where main_ship_id = s1;
  if n <> 8 then raise exception 'ROOMS8_SLOT_BACKFILL FAIL: % slots restored (want 8)', n; end if;
  select count(*) into n
    from (values (1,'bridge'),(2,'gunnery'),(3,'engineering'),(4,'logistics'),
                 (5,'sensors'),(6,'medbay'),(7,'command_deck'),(8,'armory')) w(idx, room)
    join public.ship_room_slots sl on sl.main_ship_id = s1 and sl.slot_index = w.idx and sl.room_type_id = w.room;
  if n <> 8 then raise exception 'ROOMS8_SLOT_BACKFILL FAIL: default mapping drifted after re-seed'; end if;

  -- MONOTONIC: a second verbatim run touches nothing (every slot already present).
  select string_agg(slot_index::text || ':' || room_type_id, ',' order by slot_index)
    into v_before from public.ship_room_slots where main_ship_id = s1;
  insert into public.ship_room_slots (main_ship_id, slot_index, room_type_id)
    select i.main_ship_id, d.rn, d.station_id
      from public.main_ship_instances i
      cross join (select station_id, row_number() over (order by sort) as rn
                    from public.ship_stations order by sort limit 8) d
  on conflict (main_ship_id, slot_index) do nothing;
  if (select string_agg(slot_index::text || ':' || room_type_id, ',' order by slot_index)
        from public.ship_room_slots where main_ship_id = s1) is distinct from v_before then
    raise exception 'ROOMS8_SLOT_BACKFILL FAIL: a second run moved a slot (not monotonic)'; end if;

  raise notice 'ROOMS8_PASS_SLOT_BACKFILL ok: the verbatim 0203 slot backfill re-seeds a stripped ship to its 8 default rooms deterministically; second run is a no-op';
end $$;

select 'DECKS/ROOMS-8 PROOF PASSED — room catalog >= 14; 8 configurable slots per ship (default-seeded, read, reconfigured with every reject); 8 captain slots; slot-scoped named/auto assign through the ONE writer; occupied/unknown/non-fitted rejects; cap-first authority; unassign frees; verbatim replay; the DECKS-3 affinity fold intact through the preserved adapter read-shape; deterministic monotonic station + slot backfills; dark posture unchanged' as result;

rollback;  -- ZERO persisted state: flags, knob, users, ships, captains, assignments, slots, receipts all revert.
