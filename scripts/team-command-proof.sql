-- TEAM-COMMAND B-VERIFY — disposable REAL-CHAIN proof of the DARK team send/stop surface (slices
-- 0160..0164) in a throwaway local Supabase. Fixture users carry the 'tcmd.' email prefix. The ENTIRE
-- proof runs inside ONE transaction that ROLLBACKs — it persists NO ship, group, fleet, flag flip, or
-- fixture user. No production access. No COMMIT anywhere.
--
-- ── SCOPE ─────────────────────────────────────────────────────────────────────────────────────────
-- Proves, against the real chain:
--   DARK   — ALL FIVE team RPCs (upsert_ship_group / assign_ship_to_group / delete_ship_group /
--            send_ship_group_expedition / stop_ship_group_transit) reject-BEFORE-read with
--            team_command_disabled while team_command_enabled=false. Called with RANDOM nonexistent
--            ids by a real authenticated sub: a reject-AFTER-read regression would surface
--            group_not_found / ship_not_found (or even write a group) and fail these checks.
--   WRITE  — upsert create+rename lands on ONE (player, group_index) row; index/name validation;
--            assign/unassign persisted to the ship row; and the SAME-PLAYER integrity gap: every
--            cross-player (ship, group) pairing or delete fails closed as *_not_found.
--   SEND   — empty_group; foreign group fails closed; a 2-home-ship team send succeeds via per-member
--            delegation to the UNCHANGED live send (0152); and ALL-OR-NOTHING: one unsendable member
--            rolls back the already-sent member's fleet/movement/ship writes entirely.
--   STOP   — foreign group fails closed; the mixed best-effort aggregate is EXACT
--            {stopped:2, skipped:1, failed:0} with the stopped ships physically HELD in open space
--            (0155 shape: stationary / in_space / coords set; fleet completed, pointer cleared);
--            double-stop is idempotent: {stopped:0, skipped:3, failed:0}.
--   DELETE — deleting a group un-groups its members via the FK ON DELETE SET NULL (0160) — ships are
--            NEVER removed; re-delete fails closed as group_not_found (resolve → FOR UPDATE →
--            revalidate).
--   CAPTAINS (Slice C0, 0165) — get_my_group_expedition_preview rejects dark BEFORE the team-flag
--            flip; invalid_activity / group_not_found (random + cross-player) / empty_group; a
--            captained member's stats carry the captain seed bonus over the uncaptained baseline
--            with captain_slots_limit=6 (the Part-A backfill); an uncaptained member's group stats
--            are byte-identical to its solo get_my_expedition_preview; unassigning reverts the
--            delta. Captains are provisioned ONLY via the sole writers (captains_mint_instance /
--            captain_assign_apply — the sole-writer law; NEVER a direct insert into
--            captain_instances / ship_captain_assignments).
--
-- ── DARK-CAPABILITY EXERCISE (sanctioned; never crosses the flag human-gate) ──────────────────────
-- The harness enables team_command_enabled + mainship_additional_commission_enabled +
-- mainship_send_enabled + captain_assignment_enabled ONLY inside this rolled-back transaction; the ROLLBACK reverts them, so every
-- committed/production flag value stays false. It also transiently mirrors production config a fresh
-- chain lacks (reveal_starter_ports) — all reverted by ROLLBACK. No committed flag/state changes.
--
-- ── THE ONE NON-RPC-PURE STEP (fixture normalization; quarantined below) ──────────────────────────
-- Provisioning is 100% real-RPC (commission_first_main_ship + commission_additional_main_ship). But
-- commissioning docks ships CANONICALLY (status='stationary', spatial_state='at_location', plus a
-- 'present' commission fleet at Haven), while the legacy team-send path (0152/0163) requires
-- status='home' — and NO RPC cleanly transitions a stationary commissioned ship to 'home' under the
-- 0055 spatial CHECKs. So the harness fixture-normalizes the ships that must be legacy-sendable into
-- canonical home shape and retires their 'present' commission fleets (so they don't consume the
-- active-fleet cap). That single UPDATE pair — plus a created_at stagger for deterministic member
-- ordering (now() is txn-constant, so same-txn rows tie) — is the ONLY non-RPC state surgery here;
-- everything else goes through the real RPC surface.

\set ON_ERROR_STOP on

begin;   -- everything below is transient; the trailing ROLLBACK leaves ZERO persisted state.

create temp table tcmd(k text primary key, v uuid) on commit preserve rows;
insert into tcmd values
  ('slag', 'b1a00002-0066-4a00-8a00-000000000002');    -- Slagworks (active non-combat destination)

-- caller helper: set the authenticated subject then run an RPC, returning its jsonb.
create or replace function pg_temp.call_as(p_sub uuid, p_fn text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_fn into v;
  return v;
end $$;

-- three fresh players: uA (3-ship team ops), uB (foreign-owner gap probe), uC (all-or-nothing pair).
-- The on-signup triggers auto-create each player's ACTIVE Home Base (required by the live send).
do $$
declare u uuid; k text;
begin
  foreach k in array array['uA','uB','uC'] loop
    insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
      values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
              'tcmd.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
      returning id into u;
    insert into tcmd values (k, u);
  end loop;
end $$;

-- ════════ SETUP: mirror production config a fresh disposable chain lacks (all reverted by ROLLBACK) ════════
do $$
declare r jsonb; n int;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: reveal_starter_ports %', r; end if;

  -- the send destination must be exactly what the live send requires: active + non-combat.
  select count(*) into n from public.locations
    where id = (select v from tcmd where k='slag') and status = 'active' and activity_type = 'none';
  if n <> 1 then raise exception 'SETUP FAIL: Slagworks is not active/activity_type=none'; end if;

  -- every fixture player has an ACTIVE Home Base (auto-created on signup; required by the live send).
  select count(*) into n from public.bases b join tcmd t on t.v = b.player_id
    where t.k in ('uA','uB','uC') and b.status = 'active';
  if n <> 3 then raise exception 'SETUP FAIL: expected 3 active fixture bases, got %', n; end if;

  raise notice 'setup ok: starter ports active, Slagworks sendable, 3 active fixture bases (transient)';
end $$;

-- ════════ BLOCK DARK: every team RPC rejects-BEFORE-read while team_command_enabled=false ════════
-- Run BEFORE any flag flip, as a REAL authenticated sub, with RANDOM NONEXISTENT ids. If any RPC read
-- group/ship state before its gate, these calls would surface group_not_found / ship_not_found (or the
-- upsert would return ok and write a row) instead of team_command_disabled — so this proves the gate
-- fires before any read, with no existence oracle.
do $$
declare r jsonb; n int; uA uuid := (select v from tcmd where k='uA'); slag uuid := (select v from tcmd where k='slag');
begin
  r := pg_temp.call_as(uA, 'public.upsert_ship_group(2, ''Alpha'')');
  if (r->>'reason') is distinct from 'team_command_disabled' then raise exception 'DARK FAIL upsert: %', r; end if;
  r := pg_temp.call_as(uA, 'public.assign_ship_to_group(gen_random_uuid(), gen_random_uuid())');
  if (r->>'reason') is distinct from 'team_command_disabled' then raise exception 'DARK FAIL assign: %', r; end if;
  r := pg_temp.call_as(uA, 'public.delete_ship_group(gen_random_uuid())');
  if (r->>'reason') is distinct from 'team_command_disabled' then raise exception 'DARK FAIL delete: %', r; end if;
  r := pg_temp.call_as(uA, format('public.send_ship_group_expedition(gen_random_uuid(), %L::uuid)', slag));
  if (r->>'reason') is distinct from 'team_command_disabled' then raise exception 'DARK FAIL send: %', r; end if;
  r := pg_temp.call_as(uA, 'public.stop_ship_group_transit(gen_random_uuid())');
  if (r->>'reason') is distinct from 'team_command_disabled' then raise exception 'DARK FAIL stop: %', r; end if;
  -- Slice C0 (0165): the group preview rejects dark too — asserted BEFORE the team-flag flip below,
  -- with a random id and a VALID activity, so only the gate can be what answers.
  r := pg_temp.call_as(uA, 'public.get_my_group_expedition_preview(gen_random_uuid(), ''none'')');
  if (r->>'reason') is distinct from 'team_command_disabled' then raise exception 'DARK FAIL preview: %', r; end if;

  select count(*) into n from public.ship_groups;
  if n <> 0 then raise exception 'DARK FAIL: % ship_groups rows written while dark (want 0)', n; end if;

  raise notice 'TEAMCMD_PASS_DARK ok: all 6 team RPCs reject-before-read with team_command_disabled; 0 rows written';
end $$;

-- enable the dark capabilities ONLY inside this rolled-back txn (committed/production values stay false).
update public.game_config set value='true'::jsonb where key='team_command_enabled';
update public.game_config set value='true'::jsonb where key='mainship_additional_commission_enabled';
update public.game_config set value='true'::jsonb where key='mainship_send_enabled';
update public.game_config set value='true'::jsonb where key='captain_assignment_enabled';

-- Slice C0 is RPC-ONLY: migration 0165 does NOT bump base_captain_slots (both the hull bump AND the
-- instance backfill are deferred to activation, because the "Captain seats" row in ShipStatusCard
-- renders them ungated). So a fresh chain's starter_frigate hull is still at its 0043 seed (2). The
-- CAPTAINS block below needs the ACTIVATED capacity to prove captain_slots_limit=6 and to fit two
-- captains, so apply the ACTIVATION-STEP hull bump HERE, INSIDE the rolled-back txn (reverted by the
-- trailing ROLLBACK — no committed data change). Ships commissioned below then copy 6 at commission,
-- so no instance backfill is needed for the fixture. This mirrors what the real activation migration
-- will run alongside these same flag flips (see docs/TEAM_COMMAND.md "Explicitly deferred").
update public.main_ship_hull_types set base_captain_slots = 6 where hull_type_id = 'starter_frigate';

-- Fund the fixture wallets BEFORE any additional-commission call. commission_first_main_ship is free, but
-- every ADDITIONAL commission DEBITS a price (1000 credits/ship, 0091) from player_wallet — and fresh
-- fixtures have zero balance, so uA's 3rd ship (and uC's 2nd) fail 'insufficient_credits' without this.
-- Kept AFTER the DARK block (which must stay unfunded/unprovisioned) and INSIDE the txn (rolled back with
-- everything). Direct owner insert mirrors trade-market-1-proof.sql; 1,000,000 is ample headroom and
-- perturbs no assertion (B-verify makes none about balances). player_wallet is lazy, so on_conflict
-- covers a row a signup/ensure path may already have created.
insert into public.player_wallet (player_id, balance)
select v, 1000000 from tcmd where k in ('uA','uB','uC')
on conflict (player_id) do update set balance = excluded.balance;

-- ════════ PROVISION via the REAL commission RPCs, then the ONE fixture normalization ════════
do $$
declare r jsonb; n int;
  uA uuid := (select v from tcmd where k='uA'); uB uuid := (select v from tcmd where k='uB'); uC uuid := (select v from tcmd where k='uC');
  a1 uuid; a2 uuid; a3 uuid; b1 uuid; c1 uuid; c2 uuid;
begin
  -- uA: 3 ships (first + 2 additional).
  r := pg_temp.call_as(uA, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL uA first: %', r; end if;
  select main_ship_id into a1 from public.main_ship_instances where player_id = uA;
  r := pg_temp.call_as(uA, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then raise exception 'PROVISION FAIL uA 2nd: %', r; end if;
  a2 := (r->>'main_ship_id')::uuid;
  r := pg_temp.call_as(uA, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then raise exception 'PROVISION FAIL uA 3rd: %', r; end if;
  a3 := (r->>'main_ship_id')::uuid;

  -- uB: 1 ship (the foreign-owner probe target).
  r := pg_temp.call_as(uB, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL uB first: %', r; end if;
  select main_ship_id into b1 from public.main_ship_instances where player_id = uB;

  -- uC: 2 ships (the all-or-nothing pair: c1 sendable, c2 deliberately NOT).
  r := pg_temp.call_as(uC, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL uC first: %', r; end if;
  select main_ship_id into c1 from public.main_ship_instances where player_id = uC;
  r := pg_temp.call_as(uC, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then raise exception 'PROVISION FAIL uC 2nd: %', r; end if;
  c2 := (r->>'main_ship_id')::uuid;

  insert into tcmd values ('a1',a1),('a2',a2),('a3',a3),('b1',b1),('c1',c1),('c2',c2);

  -- ── FIXTURE NORMALIZATION — the ONE non-RPC-pure step in this proof (see header). ────────────────
  -- Commissioning docks ships canonically (stationary / at_location + a 'present' commission fleet at
  -- Haven), but the legacy send (0152) requires status='home', and NO RPC cleanly transitions a
  -- stationary commissioned ship to 'home' under the 0055 spatial CHECKs. Normalize the ships that
  -- must be legacy-sendable (a1,a2,a3,b1,c1) into canonical home shape, and retire their 'present'
  -- commission fleets so they don't consume the active-fleet cap. c2 is DELIBERATELY LEFT in its
  -- commissioned 'stationary' shape — it is the un-sendable member the all-or-nothing test needs.
  update public.main_ship_instances
     set status = 'home', spatial_state = null, space_x = null, space_y = null, updated_at = now()
   where main_ship_id in (a1, a2, a3, b1, c1);
  update public.fleets
     set status = 'destroyed', location_mode = 'destroyed', active_movement_id = null,
         current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
         updated_at = now()
   where main_ship_id in (a1, a2, a3, b1, c1) and status = 'present';
  -- Settle the retired fleets' commission presence rows too — a 'destroyed' fleet with a lingering
  -- status='active' location_presence is a state no real path leaves behind, so complete them (the
  -- presence_complete terminal) to keep the fixture a fully legal, real-path-reachable state.
  update public.location_presence
     set status = 'completed', updated_at = now()
   where fleet_id in (select id from public.fleets
                        where main_ship_id in (a1, a2, a3, b1, c1) and status = 'destroyed')
     and status = 'active';

  -- Deterministic member ordering: group-send/stop iterate members ORDER BY created_at, but now() is
  -- txn-constant so same-txn commissions tie. Stagger so a1<a2<a3 and c1<c2 — the all-or-nothing test
  -- REQUIRES the sendable c1 to be attempted (and succeed) BEFORE c2 fails, to prove the rollback.
  update public.main_ship_instances set created_at = created_at - interval '3 seconds' where main_ship_id in (a1, c1);
  update public.main_ship_instances set created_at = created_at - interval '2 seconds' where main_ship_id = a2;
  update public.main_ship_instances set created_at = created_at - interval '1 second'  where main_ship_id = a3;

  -- post-normalization coherence: 5 home ships with zero active fleets; c2 stationary with its 1 'present'.
  select count(*) into n from public.main_ship_instances
    where main_ship_id in (a1,a2,a3,b1,c1) and status = 'home' and spatial_state is null;
  if n <> 5 then raise exception 'PROVISION FAIL: % of 5 normalized home ships', n; end if;
  select count(*) into n from public.fleets
    where main_ship_id in (a1,a2,a3,b1,c1) and status in ('moving','present','returning');
  if n <> 0 then raise exception 'PROVISION FAIL: % active fleets survive normalization (want 0)', n; end if;
  select count(*) into n from public.main_ship_instances where main_ship_id = c2 and status = 'stationary';
  if n <> 1 then raise exception 'PROVISION FAIL: c2 is not stationary'; end if;

  raise notice 'provision ok: uA=3 uB=1 uC=2 ships via real RPCs; 5 normalized to home; c2 left stationary';
end $$;

-- ════════ BLOCK WRITE: upsert/rename, validation, assign/unassign, and the same-player gap ════════
do $$
declare r jsonb; n int; gid uuid; gid2 uuid;
  uA uuid := (select v from tcmd where k='uA'); uB uuid := (select v from tcmd where k='uB');
  a1 uuid := (select v from tcmd where k='a1'); b1 uuid := (select v from tcmd where k='b1');
begin
  -- create then RENAME: both land on the SAME (player, group_index) row → same group_id, new name.
  r := pg_temp.call_as(uA, 'public.upsert_ship_group(1, ''Alpha'')');
  if (r->>'ok')::boolean is not true then raise exception 'WRITE FAIL create: %', r; end if;
  gid := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uA, 'public.upsert_ship_group(1, ''AlphaPrime'')');
  if (r->>'ok')::boolean is not true then raise exception 'WRITE FAIL rename: %', r; end if;
  gid2 := (r->>'group_id')::uuid;
  if gid2 is distinct from gid then raise exception 'WRITE FAIL: rename created a NEW row (% vs %)', gid2, gid; end if;
  select count(*) into n from public.ship_groups where group_id = gid and name = 'AlphaPrime';
  if n <> 1 then raise exception 'WRITE FAIL: rename not persisted'; end if;
  insert into tcmd values ('gA1', gid);

  -- index validation: 0 and 4 are outside the 1..3 slot domain.
  r := pg_temp.call_as(uA, 'public.upsert_ship_group(0, ''X'')');
  if (r->>'reason') is distinct from 'invalid_group_index' then raise exception 'WRITE FAIL index 0: %', r; end if;
  r := pg_temp.call_as(uA, 'public.upsert_ship_group(4, ''X'')');
  if (r->>'reason') is distinct from 'invalid_group_index' then raise exception 'WRITE FAIL index 4: %', r; end if;

  -- name validation: empty, whitespace-only, and 41 chars (btrim'd length must be 1..40).
  r := pg_temp.call_as(uA, 'public.upsert_ship_group(2, '''')');
  if (r->>'reason') is distinct from 'invalid_name' then raise exception 'WRITE FAIL empty name: %', r; end if;
  r := pg_temp.call_as(uA, 'public.upsert_ship_group(2, ''   '')');
  if (r->>'reason') is distinct from 'invalid_name' then raise exception 'WRITE FAIL blank name: %', r; end if;
  r := pg_temp.call_as(uA, format('public.upsert_ship_group(2, %L)', repeat('x', 41)));
  if (r->>'reason') is distinct from 'invalid_name' then raise exception 'WRITE FAIL 41-char name: %', r; end if;

  -- assign + unassign, persisted on main_ship_instances.group_id.
  r := pg_temp.call_as(uA, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', a1, gid));
  if (r->>'ok')::boolean is not true then raise exception 'WRITE FAIL assign: %', r; end if;
  select count(*) into n from public.main_ship_instances where main_ship_id = a1 and group_id = gid;
  if n <> 1 then raise exception 'WRITE FAIL: assign not persisted'; end if;
  r := pg_temp.call_as(uA, format('public.assign_ship_to_group(%L::uuid, null)', a1));
  if (r->>'ok')::boolean is not true then raise exception 'WRITE FAIL unassign: %', r; end if;
  select count(*) into n from public.main_ship_instances where main_ship_id = a1 and group_id is null;
  if n <> 1 then raise exception 'WRITE FAIL: unassign not persisted'; end if;

  -- fail-closed resolves: random ship, random group.
  r := pg_temp.call_as(uA, format('public.assign_ship_to_group(gen_random_uuid(), %L::uuid)', gid));
  if (r->>'reason') is distinct from 'ship_not_found' then raise exception 'WRITE FAIL random ship: %', r; end if;
  r := pg_temp.call_as(uA, format('public.assign_ship_to_group(%L::uuid, gen_random_uuid())', a1));
  if (r->>'reason') is distinct from 'group_not_found' then raise exception 'WRITE FAIL random group: %', r; end if;

  -- SAME-PLAYER GAP: uB's group exists, but uA can neither pair into it, pair uB's ship, nor delete it —
  -- every cross-player probe is indistinguishable from nonexistence (no ownership oracle).
  r := pg_temp.call_as(uB, 'public.upsert_ship_group(1, ''Bravo'')');
  if (r->>'ok')::boolean is not true then raise exception 'WRITE FAIL uB group: %', r; end if;
  insert into tcmd values ('gB1', (r->>'group_id')::uuid);
  r := pg_temp.call_as(uA, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', a1, (select v from tcmd where k='gB1')));
  if (r->>'reason') is distinct from 'group_not_found' then raise exception 'WRITE FAIL cross-group assign: %', r; end if;
  r := pg_temp.call_as(uA, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', b1, gid));
  if (r->>'reason') is distinct from 'ship_not_found' then raise exception 'WRITE FAIL cross-ship assign: %', r; end if;
  r := pg_temp.call_as(uA, format('public.delete_ship_group(%L::uuid)', (select v from tcmd where k='gB1')));
  if (r->>'reason') is distinct from 'group_not_found' then raise exception 'WRITE FAIL cross delete: %', r; end if;
  select count(*) into n from public.ship_groups where group_id = (select v from tcmd where k='gB1');
  if n <> 1 then raise exception 'WRITE FAIL: uB group did not survive uA delete attempt'; end if;

  raise notice 'TEAMCMD_PASS_WRITE ok: upsert/rename one-row, index+name validation, assign/unassign persisted, same-player gap closed';
end $$;

-- ════════ BLOCK CAPTAINS (Slice C0, 0165): group preview rejects + captain-fold delta + slots=6 ════════
-- Captains are provisioned ONLY via the SOLE WRITERS (captains_mint_instance 0118 /
-- captain_assign_apply 0119) in this privileged psql context — NEVER a direct insert into
-- captain_instances / ship_captain_assignments (the sole-writer law; the .sh selftest greps this
-- file for exactly that violation). Player-facing preview calls go through pg_temp.call_as. The
-- dark reject for the preview itself was already asserted in BLOCK DARK, before the flag flips.
do $$
declare r jsonb; base jsonb; capped jsonb; a2grp jsonb; solo jsonb; n int;
  uA uuid := (select v from tcmd where k='uA'); uB uuid := (select v from tcmd where k='uB');
  a1 uuid := (select v from tcmd where k='a1'); a2 uuid := (select v from tcmd where k='a2');
  gA1 uuid := (select v from tcmd where k='gA1');
  gid uuid; cap1 uuid; cap2 uuid;
begin
  -- reject vocabulary, in the RPC's order (gate already proven in BLOCK DARK):
  -- invalid_activity — validated BEFORE any row read, so even a real owned group answers the same.
  r := pg_temp.call_as(uA, format('public.get_my_group_expedition_preview(%L::uuid, ''warp_speed'')', gA1));
  if (r->>'reason') is distinct from 'invalid_activity' then raise exception 'CAPTAINS FAIL invalid activity: %', r; end if;
  -- group_not_found — a random uuid, and uB cross-player-probing uA's real group (no ownership oracle).
  r := pg_temp.call_as(uA, 'public.get_my_group_expedition_preview(gen_random_uuid(), ''none'')');
  if (r->>'reason') is distinct from 'group_not_found' then raise exception 'CAPTAINS FAIL random group: %', r; end if;
  r := pg_temp.call_as(uB, format('public.get_my_group_expedition_preview(%L::uuid, ''none'')', gA1));
  if (r->>'reason') is distinct from 'group_not_found' then raise exception 'CAPTAINS FAIL cross-player probe: %', r; end if;
  -- empty_group — a created-but-memberless slot.
  r := pg_temp.call_as(uA, 'public.upsert_ship_group(3, ''C0Empty'')');
  if (r->>'ok')::boolean is not true then raise exception 'CAPTAINS FAIL empty-slot create: %', r; end if;
  gid := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uA, format('public.get_my_group_expedition_preview(%L::uuid, ''none'')', gid));
  if (r->>'reason') is distinct from 'empty_group' then raise exception 'CAPTAINS FAIL empty_group: %', r; end if;

  -- membership: a1 + a2 into gA1 (both still home from provisioning; a1 was unassigned in WRITE).
  r := pg_temp.call_as(uA, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', a1, gA1));
  if (r->>'ok')::boolean is not true then raise exception 'CAPTAINS FAIL assign a1: %', r; end if;
  r := pg_temp.call_as(uA, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', a2, gA1));
  if (r->>'ok')::boolean is not true then raise exception 'CAPTAINS FAIL assign a2: %', r; end if;

  -- UNCAPTAINED BASELINE: ok envelope, member_count 2, every member valid; capture a1's stats.
  r := pg_temp.call_as(uA, format('public.get_my_group_expedition_preview(%L::uuid, ''none'')', gA1));
  if (r->>'ok')::boolean is not true then raise exception 'CAPTAINS FAIL baseline preview: %', r; end if;
  if (r->>'member_count')::int is distinct from 2 or jsonb_array_length(r->'members') is distinct from 2 then
    raise exception 'CAPTAINS FAIL baseline member count: %', r; end if;
  select count(*) into n from jsonb_array_elements(r->'members') e where (e->>'valid')::boolean;
  if n <> 2 then raise exception 'CAPTAINS FAIL baseline validity: %', r->'members'; end if;
  select e->'stats' into base from jsonb_array_elements(r->'members') e where e->>'main_ship_id' = a1::text;
  -- captain_slots_limit=6: migration 0165 is RPC-only (no hull/instance bump — both deferred to
  -- activation). This proof applies the ACTIVATION-STEP hull bump IN-TXN above (before provisioning),
  -- so these ships copied base_captain_slots=6 at commission, and it flows through the ONE adapter
  -- into the preview's stats. (No instance backfill needed for the fixture; the in-txn bump preceded
  -- the commissions. All reverted by ROLLBACK.)
  if (base->>'captain_slots_limit')::int is distinct from 6 then
    raise exception 'CAPTAINS FAIL: baseline captain_slots_limit % (want 6 — activation hull bump applied in-txn)', base->>'captain_slots_limit'; end if;
  if (base->>'captain_slots_used')::int is distinct from 0 then
    raise exception 'CAPTAINS FAIL: baseline captain_slots_used % (want 0)', base->>'captain_slots_used'; end if;

  -- provision TWO captains via the sole writers only (mint → assign to a1); gunnery_veteran seeds
  -- attack 4 (0117), so two of them must move a1's combat_power by exactly +8 through 0122.
  cap1 := public.captains_mint_instance(uA, 'gunnery_veteran', 'tcmd-c0-1');
  cap2 := public.captains_mint_instance(uA, 'gunnery_veteran', 'tcmd-c0-2');
  if cap1 is null or cap2 is null or cap1 = cap2 then raise exception 'CAPTAINS FAIL: mint returned %/%', cap1, cap2; end if;
  perform public.captain_assign_apply(uA, cap1, a1);
  perform public.captain_assign_apply(uA, cap2, a1);

  -- CAPTAINED: a1's stats show the seed bonus over the baseline; slots book 2 used of 6.
  r := pg_temp.call_as(uA, format('public.get_my_group_expedition_preview(%L::uuid, ''none'')', gA1));
  if (r->>'ok')::boolean is not true then raise exception 'CAPTAINS FAIL captained preview: %', r; end if;
  select e->'stats' into capped from jsonb_array_elements(r->'members') e where e->>'main_ship_id' = a1::text;
  if (capped->>'combat_power')::numeric is distinct from (base->>'combat_power')::numeric + 8 then
    raise exception 'CAPTAINS FAIL: captained combat_power % (want baseline % + 8)', capped->>'combat_power', base->>'combat_power'; end if;
  if (capped->>'captain_slots_used')::int is distinct from 2 then
    raise exception 'CAPTAINS FAIL: captained captain_slots_used % (want 2)', capped->>'captain_slots_used'; end if;
  if (capped->>'captain_slots_limit')::int is distinct from 6 then
    raise exception 'CAPTAINS FAIL: captained captain_slots_limit % (want 6)', capped->>'captain_slots_limit'; end if;

  -- UNCAPTAINED MEMBER PARITY: a2's stats in the GROUP preview must be byte-identical to its SOLO
  -- get_my_expedition_preview stats (same adapter, same inputs — the group RPC adds no arithmetic).
  select e->'stats' into a2grp from jsonb_array_elements(r->'members') e where e->>'main_ship_id' = a2::text;
  solo := pg_temp.call_as(uA, format('public.get_my_expedition_preview(''[]''::jsonb, ''none'', %L::uuid)', a2));
  if (solo->>'valid')::boolean is not true then raise exception 'CAPTAINS FAIL solo preview: %', solo; end if;
  if a2grp is distinct from solo->'stats' then
    raise exception 'CAPTAINS FAIL: a2 group stats diverge from its solo preview: % vs %', a2grp, solo->'stats'; end if;

  -- UNASSIGN one captain (the sole writer's null-ship form) → the delta steps back by one seed…
  perform public.captain_assign_apply(uA, cap2, null);
  r := pg_temp.call_as(uA, format('public.get_my_group_expedition_preview(%L::uuid, ''none'')', gA1));
  select e->'stats' into capped from jsonb_array_elements(r->'members') e where e->>'main_ship_id' = a1::text;
  if (capped->>'combat_power')::numeric is distinct from (base->>'combat_power')::numeric + 4
     or (capped->>'captain_slots_used')::int is distinct from 1 then
    raise exception 'CAPTAINS FAIL: one-unassign did not step the delta back (%, used %)', capped->>'combat_power', capped->>'captain_slots_used'; end if;
  -- …and unassigning the second reverts a1 byte-identically to the uncaptained baseline.
  perform public.captain_assign_apply(uA, cap1, null);
  r := pg_temp.call_as(uA, format('public.get_my_group_expedition_preview(%L::uuid, ''none'')', gA1));
  select e->'stats' into capped from jsonb_array_elements(r->'members') e where e->>'main_ship_id' = a1::text;
  if capped is distinct from base then
    raise exception 'CAPTAINS FAIL: full unassign did not revert to baseline: % vs %', capped, base; end if;

  raise notice 'TEAMCMD_PASS_CAPTAINS ok: preview rejects (invalid_activity/group_not_found×2/empty_group), captain fold +8 with 2/6 slots, uncaptained parity with solo preview, unassign reverts';
end $$;

-- ════════ BLOCK SEND: empty group, foreign group, real 2-ship send, and ALL-OR-NOTHING ════════
do $$
declare r jsonb; n int; gC1 uuid;
  uA uuid := (select v from tcmd where k='uA'); uC uuid := (select v from tcmd where k='uC');
  slag uuid := (select v from tcmd where k='slag'); gA1 uuid := (select v from tcmd where k='gA1');
  gB1 uuid := (select v from tcmd where k='gB1');
  a1 uuid := (select v from tcmd where k='a1'); a2 uuid := (select v from tcmd where k='a2');
  c1 uuid := (select v from tcmd where k='c1'); c2 uuid := (select v from tcmd where k='c2');
begin
  -- empty_group: a created-but-memberless slot.
  r := pg_temp.call_as(uA, 'public.upsert_ship_group(3, ''Empty'')');
  if (r->>'ok')::boolean is not true then raise exception 'SEND FAIL empty-slot create: %', r; end if;
  r := pg_temp.call_as(uA, format('public.send_ship_group_expedition(%L::uuid, %L::uuid)', (r->>'group_id')::uuid, slag));
  if (r->>'reason') is distinct from 'empty_group' then raise exception 'SEND FAIL empty_group: %', r; end if;

  -- foreign group fails closed.
  r := pg_temp.call_as(uA, format('public.send_ship_group_expedition(%L::uuid, %L::uuid)', gB1, slag));
  if (r->>'reason') is distinct from 'group_not_found' then raise exception 'SEND FAIL foreign group: %', r; end if;

  -- SUCCESS: a 2-home-ship team (a1,a2) → ok, sent length 2, each with a movement_id, 2 moving fleets,
  -- 2 traveling ships. Every movement write is the live send's — this RPC only orchestrates.
  r := pg_temp.call_as(uA, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', a1, gA1));
  if (r->>'ok')::boolean is not true then raise exception 'SEND FAIL assign a1: %', r; end if;
  r := pg_temp.call_as(uA, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', a2, gA1));
  if (r->>'ok')::boolean is not true then raise exception 'SEND FAIL assign a2: %', r; end if;
  r := pg_temp.call_as(uA, format('public.send_ship_group_expedition(%L::uuid, %L::uuid)', gA1, slag));
  if (r->>'ok')::boolean is not true then raise exception 'SEND FAIL team send: %', r; end if;
  if jsonb_array_length(r->'sent') <> 2 then raise exception 'SEND FAIL: sent length % (want 2)', jsonb_array_length(r->'sent'); end if;
  select count(*) into n from jsonb_array_elements(r->'sent') as t(elem) where t.elem->>'movement_id' is not null;
  if n <> 2 then raise exception 'SEND FAIL: % sent members carry a movement_id (want 2)', n; end if;
  select count(*) into n from public.fleets
    where main_ship_id in (a1, a2) and status = 'moving' and active_movement_id is not null;
  if n <> 2 then raise exception 'SEND FAIL: % moving fleets (want 2)', n; end if;
  select count(*) into n from public.main_ship_instances where main_ship_id in (a1, a2) and status = 'traveling';
  if n <> 2 then raise exception 'SEND FAIL: % traveling ships (want 2)', n; end if;

  -- ALL-OR-NOTHING: team {c1 home (ordered FIRST), c2 stationary}. c1's member-send SUCCEEDS inside the
  -- subtransaction, then c2's raises (not 'home') → the whole loop rolls back → member_send_failed AND
  -- c1 keeps ZERO active fleets and is still 'home' — the already-succeeded member was rolled back.
  r := pg_temp.call_as(uC, 'public.upsert_ship_group(1, ''Charlie'')');
  if (r->>'ok')::boolean is not true then raise exception 'SEND FAIL uC group: %', r; end if;
  gC1 := (r->>'group_id')::uuid;
  insert into tcmd values ('gC1', gC1);
  r := pg_temp.call_as(uC, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', c1, gC1));
  if (r->>'ok')::boolean is not true then raise exception 'SEND FAIL assign c1: %', r; end if;
  r := pg_temp.call_as(uC, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', c2, gC1));
  if (r->>'ok')::boolean is not true then raise exception 'SEND FAIL assign c2: %', r; end if;
  r := pg_temp.call_as(uC, format('public.send_ship_group_expedition(%L::uuid, %L::uuid)', gC1, slag));
  if (r->>'reason') is distinct from 'member_send_failed' then raise exception 'SEND FAIL all-or-nothing reason: %', r; end if;
  -- the abort must be pinned to c2 specifically: the live send raises this exact message for a stationary
  -- ship (0152:106). Its presence in `detail` proves the loop reached (and failed on) c2 AFTER c1's
  -- member-send had already succeeded inside the subtransaction — i.e. c1 was rolled back, not never-sent.
  if (r->>'detail') not like '%not available (status stationary)%' then
    raise exception 'SEND FAIL all-or-nothing detail not pinned to stationary c2: %', r; end if;
  select count(*) into n from public.fleets
    where main_ship_id = c1 and status in ('moving','present','returning');
  if n <> 0 then raise exception 'SEND FAIL all-or-nothing: c1 kept % active fleets (want 0 — the succeeded member must be rolled back)', n; end if;
  select count(*) into n from public.main_ship_instances where main_ship_id = c1 and status = 'home';
  if n <> 1 then raise exception 'SEND FAIL all-or-nothing: c1 is no longer home'; end if;
  select count(*) into n from public.main_ship_instances where main_ship_id = c2 and status = 'stationary';
  if n <> 1 then raise exception 'SEND FAIL all-or-nothing: c2 is no longer stationary'; end if;

  raise notice 'TEAMCMD_PASS_SEND ok: empty_group, foreign fail-closed, 2-ship send (2 movements/fleets/traveling), all-or-nothing rollback';
end $$;

-- ════════ BLOCK STOP: foreign group, EXACT mixed aggregate + held-in-space shape, idempotent re-stop ════════
do $$
declare r jsonb; n int;
  uA uuid := (select v from tcmd where k='uA');
  gA1 uuid := (select v from tcmd where k='gA1'); gB1 uuid := (select v from tcmd where k='gB1');
  a1 uuid := (select v from tcmd where k='a1'); a2 uuid := (select v from tcmd where k='a2');
  a3 uuid := (select v from tcmd where k='a3');
begin
  -- foreign group fails closed.
  r := pg_temp.call_as(uA, format('public.stop_ship_group_transit(%L::uuid)', gB1));
  if (r->>'reason') is distinct from 'group_not_found' then raise exception 'STOP FAIL foreign group: %', r; end if;

  -- MIXED aggregate: a1,a2 traveling (from BLOCK SEND) + a3 home, all in gA1 → exactly {2,1,0}.
  r := pg_temp.call_as(uA, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', a3, gA1));
  if (r->>'ok')::boolean is not true then raise exception 'STOP FAIL assign a3: %', r; end if;
  r := pg_temp.call_as(uA, format('public.stop_ship_group_transit(%L::uuid)', gA1));
  if (r->>'ok')::boolean is not true then raise exception 'STOP FAIL mixed stop: %', r; end if;
  if (r->>'stopped')::int is distinct from 2 or (r->>'skipped')::int is distinct from 1 or (r->>'failed')::int is distinct from 0 then
    raise exception 'STOP FAIL mixed aggregate: stopped=% skipped=% failed=% (want 2/1/0)', r->>'stopped', r->>'skipped', r->>'failed';
  end if;
  -- per-member results payload (not just the aggregate): a3 (home, no in-flight fleet) is the skip, tagged
  -- with the exact outcome/reason token the RPC emits for a member with nothing to halt.
  select count(*) into n from jsonb_array_elements(r->'results') e
    where e->>'main_ship_id' = a3::text and e->>'outcome' = 'skipped' and e->>'reason' = 'no_active_fleet';
  if n <> 1 then raise exception 'STOP FAIL mixed results: a3 not skipped/no_active_fleet: %', r->'results'; end if;

  -- physical hold shape (0155): a1,a2 HELD in open space; their fleets settled movement-less; a3 untouched.
  select count(*) into n from public.main_ship_instances
    where main_ship_id in (a1, a2) and status = 'stationary' and spatial_state = 'in_space'
      and space_x is not null and space_y is not null;
  if n <> 2 then raise exception 'STOP FAIL: % ships held stationary/in_space with coords (want 2)', n; end if;
  select count(*) into n from public.fleets
    where main_ship_id in (a1, a2) and status = 'completed' and active_movement_id is null;
  if n <> 2 then raise exception 'STOP FAIL: % settled (completed, pointer-cleared) fleets (want 2)', n; end if;
  -- movement-row terminal: each stopped fleet's fleet_movements row reached the 'cancelled' terminal with
  -- resolved_at set. A regression that skipped the movement cancel would leave a 'moving' row for the cron
  -- to later settle (un-holding the ship) yet still pass the ship/fleet shape checks above.
  select count(*) into n from public.fleet_movements
    where fleet_id in (select id from public.fleets where main_ship_id in (a1, a2))
      and status = 'cancelled' and resolved_at is not null;
  if n <> 2 then raise exception 'STOP FAIL: % cancelled/resolved movement rows for the stopped fleets (want 2)', n; end if;
  select count(*) into n from public.main_ship_instances where main_ship_id = a3 and status = 'home';
  if n <> 1 then raise exception 'STOP FAIL: a3 was disturbed (not home)'; end if;

  -- idempotent double-stop: nothing left to halt → {0,3,0} (every member is a legitimate skip).
  r := pg_temp.call_as(uA, format('public.stop_ship_group_transit(%L::uuid)', gA1));
  if (r->>'ok')::boolean is not true then raise exception 'STOP FAIL double stop: %', r; end if;
  if (r->>'stopped')::int is distinct from 0 or (r->>'skipped')::int is distinct from 3 or (r->>'failed')::int is distinct from 0 then
    raise exception 'STOP FAIL double-stop aggregate: stopped=% skipped=% failed=% (want 0/3/0)', r->>'stopped', r->>'skipped', r->>'failed';
  end if;
  -- every one of the three members must carry outcome='skipped' in the payload (no silent failed/stopped).
  select count(*) into n from jsonb_array_elements(r->'results') e where e->>'outcome' = 'skipped';
  if n <> 3 then raise exception 'STOP FAIL double-stop results: % of 3 entries skipped: %', n, r->'results'; end if;

  raise notice 'TEAMCMD_PASS_STOP ok: foreign fail-closed, mixed {2,1,0} with held-in-space shape, idempotent {0,3,0}';
end $$;

-- ════════ BLOCK DELETE: member SET-NULL un-grouping (ships survive), double-delete fails closed ════════
do $$
declare r jsonb; n int;
  uC uuid := (select v from tcmd where k='uC'); gC1 uuid := (select v from tcmd where k='gC1');
  c1 uuid := (select v from tcmd where k='c1'); c2 uuid := (select v from tcmd where k='c2');
begin
  -- gC1 still has 2 members (c1,c2 from BLOCK SEND).
  select count(*) into n from public.main_ship_instances where main_ship_id in (c1, c2) and group_id = gC1;
  if n <> 2 then raise exception 'DELETE FAIL precondition: gC1 has % members (want 2)', n; end if;

  r := pg_temp.call_as(uC, format('public.delete_ship_group(%L::uuid)', gC1));
  if (r->>'ok')::boolean is not true then raise exception 'DELETE FAIL: %', r; end if;

  -- members are UN-GROUPED via the FK ON DELETE SET NULL — the ships themselves are NEVER removed.
  select count(*) into n from public.main_ship_instances where main_ship_id in (c1, c2) and group_id is null;
  if n <> 2 then raise exception 'DELETE FAIL: % members un-grouped by SET NULL (want 2)', n; end if;
  select count(*) into n from public.main_ship_instances where main_ship_id in (c1, c2);
  if n <> 2 then raise exception 'DELETE FAIL: a member SHIP was removed by group delete (% survive, want 2)', n; end if;

  -- double-delete fails closed (resolve → FOR UPDATE → revalidate → group_not_found; never a raw 500).
  r := pg_temp.call_as(uC, format('public.delete_ship_group(%L::uuid)', gC1));
  if (r->>'reason') is distinct from 'group_not_found' then raise exception 'DELETE FAIL double delete: %', r; end if;

  raise notice 'TEAMCMD_PASS_DELETE ok: members SET-NULL un-grouped, ships survive, double-delete fails closed';
end $$;

select 'TEAM-COMMAND B-VERIFY PROOF PASSED (dark reject-before-read; write/assign integrity; C0 captain-fold group preview; all-or-nothing send; best-effort stop; SET-NULL delete)' as result;

rollback;   -- leave ZERO persisted state: no ship, no group, no fleet, no flag flip, no fixture user.
