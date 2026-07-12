-- DECKS — disposable write-then-ROLLBACK proof for the 0189 deck-stations slice (the six-station
-- catalog + the station axis on ship_captain_assignments through the ONE writer path).
--
-- Runs against a THROWAWAY local Supabase with ALL migrations applied (incl. 0189) — NEVER
-- production. Everything below happens inside ONE transaction that ends in ROLLBACK: the dark
-- captain flag is enabled ONLY in-txn (committed values stay false), every fixture is transient,
-- and zero persisted state survives. Fixture users carry the 'dks.' email prefix.
--
-- SOLE-WRITER LAW: captains are provisioned ONLY via the real writers (captains_mint_instance
-- 0118 / the assign_captain_to_ship + unassign_captain_from_ship client wrappers 0120/0121/0189)
-- — the assignment table is NEVER row-inserted or row-deleted by this harness (the .sh selftest
-- greps this file for exactly that violation). THE ONE QUARANTINED NON-RPC STEP: the BACKFILL block below
-- UPDATEs station back to NULL (+ staggers assigned_at for a deterministic order) to RECREATE
-- the pre-0189 world the migration backfill targets, then runs the 0189 backfill statement
-- VERBATIM — no real writer can produce a station-less row post-0189, so surgery is the only
-- honest fixture. Those UPDATEs mutate ONLY the station/assigned_at columns of rows the real
-- writers created; nothing else touches the table outside the writers.
--
-- PROPERTY MARKERS (the .sh asserts every one in the output):
--   DECKS_PASS_DARK            — with captain gates dark, assign/unassign/roster reject exactly
--                                as before (captain_assignment_disabled), IDENTICALLY for a
--                                known and an unknown station (no new oracle); zero rows written.
--   DECKS_PASS_ASSIGN_STATION  — assign to a named free station: ok envelope carries the station,
--                                the row carries it, the receipt stores it, the roster read
--                                projects it.
--   DECKS_PASS_OCCUPIED        — a second captain to the same station rejects station_occupied
--                                (writes nothing).
--   DECKS_PASS_UNKNOWN_STATION — a station outside the catalog rejects unknown_station.
--   DECKS_PASS_AUTOFILL        — a station-less assign auto-takes the LOWEST-SORT free station,
--                                deterministically, across the whole catalog; the headcount cap
--                                stays THE authority (a 7th captain answers captain_slots_full —
--                                BEFORE any station reason — so no_free_station is unreachable).
--   DECKS_PASS_UNASSIGN_FREES  — unassign deletes the row and thereby FREES its station; the
--                                station is immediately assignable again.
--   DECKS_PASS_REPLAY          — a reused request_id replays the ORIGINAL envelope verbatim
--                                (station included) with idempotent_replay, even when the replay
--                                call names different args; NO mutation (trade semantics).
--   DECKS_PASS_BACKFILL        — the 0189 backfill statement (verbatim copy) maps rows to
--                                stations per (assigned_at, captain_instance_id) → sort order,
--                                deterministically; re-running it changes nothing (monotonic).

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
  -- the 0189 catalog really is the six verbatim stations in sort order (the board/auto-fill truth).
  select count(*) into n from public.ship_stations;
  if n <> 6 then raise exception 'SETUP FAIL: ship_stations has % rows (want 6)', n; end if;
  select count(*) into n
    from (values ('bridge',1),('gunnery',2),('engineering',3),('logistics',4),('sensors',5),('medbay',6)) w(id, srt)
    join public.ship_stations s on s.station_id = w.id and s.sort = w.srt;
  if n <> 6 then raise exception 'SETUP FAIL: ship_stations ids/sorts drifted'; end if;
  raise notice 'setup ok: starter ports revealed; six-station catalog verbatim (transient fixture user created)';
end $$;

-- ════════ BLOCK DARK: the captain command surface rejects EXACTLY as before 0189 ════════
-- Run BEFORE the flag flip, as a REAL authenticated sub, with RANDOM NONEXISTENT ids — and with
-- BOTH a known ('gunnery') and an unknown ('helm') station: while dark the answer must be the
-- IDENTICAL captain_assignment_disabled envelope regardless of the new input (no station
-- existence oracle; reject-before-any-read preserved by the re-created heads).
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
  select count(*) into n from public.ship_captain_assignments;
  if n <> 0 then raise exception 'DARK FAIL: % assignment rows written while dark (want 0)', n; end if;
  select count(*) into n from public.captain_assignment_receipts;
  if n <> 0 then raise exception 'DARK FAIL: % receipts written while dark (want 0)', n; end if;
  raise notice 'DECKS_PASS_DARK ok: assign/unassign/roster reject captain_assignment_disabled before any read; known and unknown stations answer identically; 0 rows written';
end $$;

-- enable the dark capability ONLY inside this rolled-back txn (committed/production value stays false).
update public.game_config set value='true'::jsonb where key='captain_assignment_enabled';

-- ════════ PROVISION via the REAL RPCs/writers: one ship (canonically docked = settled-SAFE), 7 captains ════════
do $$
declare r jsonb; u1 uuid := (select v from dks where k='u1'); s1 uuid; c uuid; i int;
begin
  r := pg_temp.call_as(u1, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL first ship: %', r; end if;
  select main_ship_id into s1 from public.main_ship_instances where player_id = u1;
  if s1 is null then raise exception 'PROVISION FAIL: no ship row'; end if;
  insert into dks values ('s1', s1);
  -- 7 captains through THE mint writer (6 stations + 1 to prove the headcount cap stays first).
  for i in 1..7 loop
    c := public.captains_mint_instance(u1, 'gunnery_veteran', 'dks-mint-' || i);
    if c is null then raise exception 'PROVISION FAIL: mint % returned null', i; end if;
    insert into dks values ('cap' || i, c);
  end loop;
  raise notice 'provision ok: 1 commissioned (docked, settled-SAFE) ship + 7 minted captains, all via the real writers';
end $$;

-- ════════ BLOCK ASSIGN_STATION: named-station happy path (envelope + row + receipt + roster) ════════
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
  -- the receipt stores the station verbatim (the replay source of truth).
  select count(*) into n from public.captain_assignment_receipts
    where player_id = u1 and request_id = 'dks-req-1' and result_json->>'station' = 'gunnery';
  if n <> 1 then raise exception 'ASSIGN_STATION FAIL: receipt result_json lacks station gunnery'; end if;
  -- the lit roster read projects the held station (the DECKS-2 board feed).
  r := pg_temp.call_as(u1, 'public.get_my_captain_instances()');
  if (r->>'ok')::boolean is not true then raise exception 'ASSIGN_STATION FAIL roster: %', r; end if;
  select count(*) into n from jsonb_array_elements(r->'captains') e
    where e->>'instance_id' = cap1::text and e->>'station' = 'gunnery' and e->>'main_ship_id' = s1::text;
  if n <> 1 then raise exception 'ASSIGN_STATION FAIL: roster read does not project station gunnery: %', r->'captains'; end if;
  raise notice 'DECKS_PASS_ASSIGN_STATION ok: named assign lands on gunnery in the envelope, the row, the receipt, and the roster projection';
end $$;

-- ════════ BLOCK OCCUPIED: a second captain to a held station rejects station_occupied ════════
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

-- ════════ BLOCK UNKNOWN_STATION: a station outside the catalog rejects unknown_station ════════
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

-- ════════ BLOCK AUTOFILL: station-less assigns take the LOWEST-SORT free station; the cap stays first ════════
do $$
declare r jsonb; n int; u1 uuid := (select v from dks where k='u1');
  s1 uuid := (select v from dks where k='s1');
  cap2 uuid := (select v from dks where k='cap2'); cap3 uuid := (select v from dks where k='cap3');
  cap4 uuid := (select v from dks where k='cap4'); cap5 uuid := (select v from dks where k='cap5');
  cap6 uuid := (select v from dks where k='cap6'); cap7 uuid := (select v from dks where k='cap7');
begin
  -- gunnery (sort 2) is held → the lowest-sort FREE station is bridge (sort 1).
  r := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid)', 'dks-req-af1', cap2, s1));
  if (r->>'ok')::boolean is not true or (r->>'station') is distinct from 'bridge' then
    raise exception 'AUTOFILL FAIL: expected bridge, got %', r; end if;
  -- bridge + gunnery held → next free by sort is engineering (sort 3), NOT logistics/sensors/medbay.
  r := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid)', 'dks-req-af2', cap3, s1));
  if (r->>'ok')::boolean is not true or (r->>'station') is distinct from 'engineering' then
    raise exception 'AUTOFILL FAIL: expected engineering, got %', r; end if;
  -- fill the rest in strict sort order: logistics → sensors → medbay.
  r := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid)', 'dks-req-af3', cap4, s1));
  if (r->>'station') is distinct from 'logistics' then raise exception 'AUTOFILL FAIL: expected logistics, got %', r; end if;
  r := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid)', 'dks-req-af4', cap5, s1));
  if (r->>'station') is distinct from 'sensors' then raise exception 'AUTOFILL FAIL: expected sensors, got %', r; end if;
  r := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid)', 'dks-req-af5', cap6, s1));
  if (r->>'station') is distinct from 'medbay' then raise exception 'AUTOFILL FAIL: expected medbay, got %', r; end if;
  select count(*) into n from public.ship_captain_assignments where main_ship_id = s1 and station is not null;
  if n <> 6 then raise exception 'AUTOFILL FAIL: % stationed rows (want 6/6)', n; end if;
  -- THE CAP STAYS THE AUTHORITY: a 7th captain answers captain_slots_full — the 0119 headcount
  -- reject fires BEFORE any station reason (explicit-station probe), and no_free_station is
  -- therefore unreachable while captain_slots = 6 = the catalog size (station-less probe).
  r := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid, %L)', 'dks-req-af6', cap7, s1, 'bridge'));
  if (r->>'reason') is distinct from 'captain_slots_full' then
    raise exception 'AUTOFILL FAIL: 7th (explicit station) answered % (want captain_slots_full before station_occupied)', r; end if;
  r := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid)', 'dks-req-af7', cap7, s1));
  if (r->>'reason') is distinct from 'captain_slots_full' then
    raise exception 'AUTOFILL FAIL: 7th (auto) answered % (want captain_slots_full — no_free_station unreachable)', r; end if;
  raise notice 'DECKS_PASS_AUTOFILL ok: auto-assign walked bridge->gunnery(held)->engineering->logistics->sensors->medbay by sort; headcount cap rejects the 7th before any station reason';
end $$;

-- ════════ BLOCK UNASSIGN_FREES: the row delete frees the station for immediate re-assign ════════
do $$
declare r jsonb; n int; u1 uuid := (select v from dks where k='u1');
  s1 uuid := (select v from dks where k='s1');
  cap1 uuid := (select v from dks where k='cap1'); cap7 uuid := (select v from dks where k='cap7');
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
  -- the freed station is immediately assignable again (explicit, so ONLY the free-ness decides).
  r := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid, %L)', 'dks-req-un2', cap7, s1, 'gunnery'));
  if (r->>'ok')::boolean is not true or (r->>'station') is distinct from 'gunnery' then
    raise exception 'UNASSIGN_FREES FAIL re-assign: %', r; end if;
  raise notice 'DECKS_PASS_UNASSIGN_FREES ok: unassign deleted the row, gunnery freed and immediately re-held by another captain';
end $$;

-- ════════ BLOCK REPLAY: a reused request_id replays the ORIGINAL envelope verbatim, mutating nothing ════════
do $$
declare r jsonb; n int; u1 uuid := (select v from dks where k='u1');
  s1 uuid := (select v from dks where k='s1'); cap1 uuid := (select v from dks where k='cap1');
begin
  -- dks-req-1 originally assigned cap1 -> gunnery. Replay it with DIFFERENT args (station medbay):
  -- trade semantics (0113/0120) — the stored envelope returns verbatim + idempotent_replay, the
  -- differing payload is IGNORED, and nothing moves (cap1 stays unassigned; gunnery stays cap7's).
  r := pg_temp.call_as(u1, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid, %L)', 'dks-req-1', cap1, s1, 'medbay'));
  if (r->>'ok')::boolean is not true or (r->>'idempotent_replay')::boolean is not true
     or (r->>'station') is distinct from 'gunnery' or (r->>'captain_instance_id') is distinct from cap1::text then
    raise exception 'REPLAY FAIL envelope: %', r; end if;
  select count(*) into n from public.ship_captain_assignments where captain_instance_id = cap1;
  if n <> 0 then raise exception 'REPLAY FAIL: the replay re-assigned cap1'; end if;
  select count(*) into n from public.ship_captain_assignments where main_ship_id = s1;
  if n <> 6 then raise exception 'REPLAY FAIL: row count moved to % (want 6)', n; end if;
  select count(*) into n from public.captain_assignment_receipts where player_id = u1 and request_id = 'dks-req-1';
  if n <> 1 then raise exception 'REPLAY FAIL: receipt duplicated'; end if;
  raise notice 'DECKS_PASS_REPLAY ok: reused request_id returned the original station-bearing envelope verbatim (idempotent_replay), zero mutations';
end $$;

-- ════════ BLOCK BACKFILL: the 0189 backfill statement is deterministic and monotonic ════════
-- QUARANTINED FIXTURE SURGERY (the one non-writer step, see header): no real writer can produce a
-- station-less row post-0189, so recreate the pre-0189 world by hand — NULL every station and pin
-- a known assigned_at order — then run the migration's backfill VERBATIM and assert the mapping.
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

select 'DECKS PROOF PASSED — six-station catalog; named/auto assign through the ONE writer; occupied/unknown rejects; cap-first authority; unassign frees; verbatim replay; deterministic monotonic backfill; dark posture unchanged' as result;

rollback;  -- ZERO persisted state: flags, users, ships, captains, assignments, receipts all revert.
