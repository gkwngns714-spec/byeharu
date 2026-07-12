-- TEAM-COMMAND B-VERIFY — disposable REAL-CHAIN proof of the DARK team send/stop/combat surface (slices
-- 0160..0169 + the 0170/0171 activation-prep migrations + the 0177 captain-XP foundation + the
-- 0180 C2-2 captain level fold) in a throwaway local Supabase. Fixture users carry the 'tcmd.' email prefix. The ENTIRE
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
--   HULLSTATS (activation prep, 0170) — every hull row carries the seeded numeric base
--            attack/defense (starter_frigate exactly {attack 15, defense 10}) and the re-created
--            adapter (0122 head + the packet-§1.4 parity delta) FOLDS them: a factory-bare ship's
--            combat_power/survival equal its hull seed exactly through the ONE adapter.
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
--            with captain_slots_limit=6 (the 0171 captains-launch bump — asserted in setup, no
--            longer fixtured in-txn); an uncaptained member's group stats
--            are byte-identical to its solo get_my_expedition_preview; unassigning reverts the
--            delta. Captains are provisioned ONLY via the sole writers (captains_mint_instance /
--            captain_assign_apply — the sole-writer law; NEVER a direct insert into
--            captain_instances / ship_captain_assignments).
--   COMBATPARITY (Slice D1, 0167) — the re-created LIVE combat tick + report writer keep LEGACY
--            byte-parity: a real unit fleet is provisioned/sent/settled through the real chain (with
--            the team flag ON in-txn — proving the flag is irrelevant to legacy combat), one tick's
--            player_damage EQUALS the proof's OWN independent Σ(unit_types.attack × alive_count) and
--            its enemy_damage EQUALS the proof's own defense-curve value from the independent
--            Σ(defense × alive) (variance pinned 0 in-txn — both compares exact), every tick/report
--            jsonb key is a legacy unit_type id, hp and fleet_units sync are exact, the escape
--            settle's return speed equals legacy fleet_speed, the new exactly-one-identity CHECK
--            raises on both illegal shapes, the three D1 leaves smoke-check (NULL return speed for a
--            legacy fleet; hp-only sync; the 0059 destruction terminal), and EXACTLY ONE combat cron
--            job exists (the no-second-engine pin).
--   TEAMSTATS (Slice D0, 0166) — get_my_group_expedition_totals rejects dark BEFORE the team-flag
--            flip; invalid_activity / group_not_found (random + cross-player) / empty_group; on the
--            happy path every additive total EQUALS the proof's OWN independent per-member sum over
--            direct calculate_expedition_stats calls (the delegation-not-reimplementation pin) and
--            totals.speed = min member speed; and the STRICT posture: one over-capacity member →
--            the totals RPC refuses WHOLE with an opaque stats_invalid (no member detail) while the
--            C0 preview still answers ok with that member valid:false (strict-vs-preview).
--   TEAMHUNT (Slice D2, 0168) — send_ship_group_hunt rejects dark BEFORE the team-flag flip; the
--            reject vocabulary + ORDER (invalid_location answers before member readiness);
--            member_not_ready on an unready team; the happy path writes ONE fleet (group_id tag,
--            main_ship_id NULL) + a frozen 2-row manifest + 'hunting' ships with movement
--            speed_used == the proof's OWN independent D0 totals.speed; live-single-send and
--            double-team-send races reject mid-sortie; the settled arrival routes through
--            combat_create_encounter's D2 branch into a member encounter whose per-member
--            attack/defense snapshots EQUAL the proof's OWN direct adapter calls, whose hp carries
--            pre-existing damage, and whose player_power_start EQUALS totals.combat_power; one
--            tick's player_damage EQUALS Σ member attack_snapshot with the D1 leaf syncing damage
--            back to main_ship_instances.hp; the MANIFEST-WINS law — a mid-flight unassign
--            (real RPC) leaves the manifest whole and the next tick still drives both members; and
--            the H1 cron-safety law — a zero-hp member rejects at send, and an adapter-refused
--            member DEGRADES at arrival (alive_count=0 / zero snapshots) instead of raising inside
--            the settle, which must still succeed (the cron has no per-movement subtransaction).
--   TEAMSETTLE (Slice D3, 0169) — the sortie settle loop: the reconciler's mid-combat AND
--            in-transit race guards (members untouched while the manifest fleet is
--            present/returning); request_retreat works verbatim on a team encounter; the escape
--            tick marks surviving members 'returning' (member hull return speed with fleet_speed
--            NULL, member-keyed report, damage persisted); the return settle deposits the carried
--            bundle (reward_grants + base metal) and the reconciler then re-homes the members in
--            the head's exact write shape with the manifest RETAINED; a boosted-enemy defeat
--            destroys real alive members (D1 loop) and repair_main_ship revives one; the M1 guard
--            pin (a 'hunting' ship rejects the live single send with its own not-available raise —
--            never a lost update — and a legal single send still works); and the reconciler
--            self-heals manufactured 'returning'/'hunting' orphans home.
--   SHARDDROP (captains launch, 0171) — the config-gated captain_memory_shard drop: with the
--            committed seed rate 0 the re-created pirate_loot_for_wave is BYTE-IDENTICAL to its
--            0041 head (parity, element order included); at rate 1 (set in-txn) a wave >= 2
--            bundle gains EXACTLY one appended shard qty 1 (additive-only) while wave 1 stays
--            deterministic scrap-only at ANY rate; the rate is left 1 in-txn so TEAMSETTLE's won
--            encounter carries a shard end-to-end (drop → bundle → return → reward_grant →
--            player_inventory — the recruit currency really arrives).
--   CAPXP (CAPXP-0/1, 0177) — the captain-XP foundation, consuming the TEAMSETTLE fixture AS the
--            captained team sortie: committed seeds dark (captain_growth_enabled 'false', combat
--            knob '10'); every instance at the additive defaults (xp 0 / level 1);
--            captain_xp_accrue() no-ops {feature_disabled} with ZERO writes BEFORE the in-txn
--            flip; lit (flag + knob 100 in-txn — the exact level-2 boundary of the [D] curve),
--            ONE run credits the THREE currently-assigned manifest captains (capa+capb on c1,
--            capc on c2 — one grant feeds multiple captains, the per-(grant, captain) ledger
--            keying) EXACTLY knob × 1 qualifying grant each with level landing exactly 2 at the
--            100-xp boundary; a captain on a grantless ship (capd/b1 — defeat, no grant) and a
--            freshly-minted UNASSIGNED captain gain NOTHING; an ORPHAN grant (minted via the REAL
--            reward_grant sole writer with a random source_id — the retention-cleaned-encounter
--            shape) is consumed as a NULL-captain sentinel, never credited; zero grants left
--            unconsumed; the curve recomputed independently over every instance; and a RE-RUN
--            consumes/credits/awards ZERO (the anti-join exactly-once pin).
--   CAPLEVEL (C2-2, 0180) — the captain level → adapter fold, consuming the CAPXP outcome AS the
--            level-2 fixture (capa+capb level 2 on c1, capd level 1 on the grantless b1, flag lit
--            in-txn): the committed 0180 knob seed (0.10) untouched; LIT + LEVEL 2 — c1's
--            combat_power exceeds the level-1 baseline by EXACTLY round(knob × Σ(level-1)×attack,
--            2) (23 → 23.8 at the seeds) with every non-combat_power key byte-identical (the fold
--            scales captain stats_json contributions only — tradeoffs level-flat); FLAG OFF +
--            LEVEL 2 — the level-1 world exactly (combat_power = hull attack + Σ captain attack,
--            derived independently from the catalog joins); FLAG ON + LEVEL 1 — b1 byte-identical
--            lit or dark. The DOUBLE inertness, both arms pinned. Reconciliation (checked): no
--            earlier block calls the adapter after the CAPXP flip/accrual, so every existing
--            adapter pin runs dark at level 1 and stays byte-valid unreconciled.
--   MOD2 (MOD2-1, 0183) — the shield-line seeds end-to-end on a FRESH fixture user (free first
--            commission → canonically docked = settled-SAFE for fitting, 0114; captain/module-
--            free so the baseline decomposes exactly): both module gates asserted COMMITTED-dark
--            first, then flipped in-txn only; the 0183 catalog pinned verbatim (shield_lattice
--            defense 12 / mining_rig_extension mining 8, slot 1, the 6 exact recipe rows);
--            ingredients granted ONLY via the real reward_grant sole writer at EXACTLY the
--            recipe quantities; craft_module spends the exact price to zero, a second craft hits
--            the insufficient_items boundary, the replay is verbatim with ONE minted instance;
--            fit_module_to_ship + the 0180 adapter land survival = baseline + 12 EXACTLY (the
--            hull-only 10 → 22 — the packet-F2 degenerate curve's first fitted move) and
--            mining_yield + 8 EXACTLY, with nothing else moving but module_slots_used (the
--            minus-key isolation pin; defense/mining archetypes take the engine else-0 tradeoff).
--   SHIPYARD0 (SHIPYARD-0, 0185) — the ship-production foundation, all dark: shipyard_enabled
--            COMMITTED 'false' + blueprint_fragment_drop_rate COMMITTED '0' (asserted, never
--            flipped — no shipyard RPC exists to exercise); the 2 T1 hull rows pinned EXACT
--            (bulk_hauler 'Mule-class Hauler' 650/0.8/140/{5,15} + strike_corvette 'Talon-class
--            Corvette' 420/1.3/20/{30,10}, captains 6 / modules 2 and 4); the build recipes
--            pinned EXACT (2 headers: credits 400 / 3600s / NULL T1 gates; the 10 ingredient
--            rows, no strays); and the blueprint faucet at its deterministic endpoints (the
--            SHARDDROP technique, riding its in-txn shard-rate-1 fixture carry): rate-0
--            byte-parity with the 0171 head at waves 8 and 10, rate-1 wave-8 gains EXACTLY one
--            appended blueprint qty 1 (additive-only), wave 7 (w<8) and wave 1 stay
--            blueprint-free at any rate (the deep-run threshold).
--   SOUL0 (SOUL-0, 0186) — the per-ship trait foundation: committed `ship_traits_enabled` dark +
--            the roll writer's gate-first reject (random uuid — no existence oracle, zero rows);
--            the 8-trait catalog pinned verbatim (id + stats_json + hp_mult); determinism by
--            INLINE RE-DERIVATION (pg_temp.soul_expect re-implements the pure-hash ':soul:' salt
--            mapping, computed BEFORE each roll; fresh-commissioned fixture ships are drawn until
--            one derived pair carries veteran_frame and one does not, so both hp branches run
--            every time) — each roll lands EXACTLY the derived pair, slots distinct; the veteran
--            arm's max_hp = round(base × 1.08) exactly with hp scaled, the plain arm's hp/max_hp
--            byte-untouched; and a second roll is an idempotent replay (inserted 0, same traits,
--            max_hp never re-raised). The roll fn is service-only with NO caller in the product
--            (doubly dark); the harness never writes a Ship-Soul table directly (negative-grepped).
--   TEAMMAP (TEAMMAP-1, 0187) — the group-tag hunk on send_ship_group_expedition (re-created from
--            its 0163 head): a 2-ship team send to Slagworks (starter port) tags BOTH member
--            fleets with the team's group_id — exactly the envelope's sent[] fleet ids, no stray
--            tags — and settling each arrival through movement_settle_arrival (the SAME
--            per-movement settle the cron calls) DOCKS both members at the port (0153
--            stationary/at_location) with the informational tag SURVIVING the settle (the map's
--            docked-team badge read). Display-only law respected: no routing assertion keys on
--            the tag. Fresh fixture user (the MOD2 idiom).
--
-- ── DARK-CAPABILITY EXERCISE (sanctioned; never crosses the flag human-gate) ──────────────────────
-- The harness enables team_command_enabled + mainship_additional_commission_enabled +
-- mainship_send_enabled + captain_assignment_enabled (+ captain_growth_enabled at CAPXP,
-- module_crafting_enabled + module_fitting_enabled at MOD2, and ship_traits_enabled at
-- SOUL0) ONLY inside this rolled-back transaction; the ROLLBACK reverts them, so every
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
  -- Slice D0 (0166): the authoritative-totals wrapper rejects dark too — asserted BEFORE the
  -- team-flag flip below, with a random id and a VALID activity, so only the gate can be what answers.
  r := pg_temp.call_as(uA, 'public.get_my_group_expedition_totals(gen_random_uuid(), ''none'')');
  if (r->>'reason') is distinct from 'team_command_disabled' then raise exception 'DARK FAIL totals: %', r; end if;
  -- Slice D2 (0168): the combat team-send rejects dark too — asserted BEFORE the team-flag flip
  -- below, with random uuids, so only the gate can be what answers (a reject-after-read regression
  -- would surface group_not_found instead).
  r := pg_temp.call_as(uA, 'public.send_ship_group_hunt(gen_random_uuid(), gen_random_uuid())');
  if (r->>'reason') is distinct from 'team_command_disabled' then raise exception 'DARK FAIL hunt send: %', r; end if;

  select count(*) into n from public.ship_groups;
  if n <> 0 then raise exception 'DARK FAIL: % ship_groups rows written while dark (want 0)', n; end if;
  select count(*) into n from public.group_sortie_members;
  if n <> 0 then raise exception 'DARK FAIL: % group_sortie_members rows written while dark (want 0)', n; end if;

  raise notice 'TEAMCMD_PASS_DARK ok: all 8 team RPCs reject-before-read with team_command_disabled; 0 rows written';
end $$;

-- enable the dark capabilities ONLY inside this rolled-back txn (committed/production values stay false).
update public.game_config set value='true'::jsonb where key='team_command_enabled';
update public.game_config set value='true'::jsonb where key='mainship_additional_commission_enabled';
update public.game_config set value='true'::jsonb where key='mainship_send_enabled';
update public.game_config set value='true'::jsonb where key='captain_assignment_enabled';

-- CAPTAINS-LAUNCH RECONCILIATION (0171): the once-deferred hull bump + instance backfill NOW SHIP
-- as migration 20260618000171 (the captains fast-follow prep), and this disposable chain always
-- runs with ALL migrations applied — so base_captain_slots is 6 BEFORE any fixture exists. The
-- proof's former in-txn fixture bump (the pre-0171 activation rehearsal) is therefore RETIRED and
-- REPLACED BY AN ASSERT: the MIGRATION, not the harness, provides the 6-seat capacity the CAPTAINS
-- block pins. Ships commissioned below copy 6 at commission; the 0171 instance backfill is asserted
-- as a no-op on the fresh chain (monotonic — zero laggards can exist).
do $$
declare n int;
begin
  select count(*) into n from public.main_ship_hull_types where base_captain_slots is distinct from 6;
  if n <> 0 then raise exception 'SETUP FAIL: % hull row(s) not at base_captain_slots 6 (want 0 — the 0171 captains-launch bump)', n; end if;
  select count(*) into n from public.main_ship_instances i
    join public.main_ship_hull_types h on h.hull_type_id = i.hull_type_id
    where i.captain_slots < h.base_captain_slots;
  if n <> 0 then raise exception 'SETUP FAIL: % instance(s) below the hull captain_slots (want 0 — the 0171 backfill)', n; end if;
  raise notice 'setup ok: 0171 captain-slot bump in place (hulls at 6; backfill complete) — no fixture bump needed';
end $$;

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

-- ════════ BLOCK HULLSTATS (activation prep, 0170): hull base combat stats seeded + adapter-folded ════════
-- Migration 0170 re-created calculate_expedition_stats (from its 0122 head) with the packet-§1.4
-- parity delta — a_combat/a_survival += the HULL's base_stats_json attack/defense — and seeded
-- starter_frigate {attack 15, defense 10}. Pins: every hull row carries numeric attack+defense
-- (starter_frigate exactly 15/10), and the fold is LIVE through the ONE adapter: a factory-bare
-- ship's combat_power/survival EQUAL its hull's seeded stats (nothing else can contribute — a1 has
-- no loadout, no fittings, no captains at this point). Every later stat assert in this proof
-- (captain +8/+4 deltas, D0 independent sums, D2 snapshot pins) recomputes through the SAME
-- adapter, so those blocks stay value-independent of the seed by construction.
do $$
declare v_hull jsonb; s jsonb; n int;
  uA uuid := (select v from tcmd where k='uA'); a1 uuid := (select v from tcmd where k='a1');
begin
  -- every hull row carries the seeded numeric combat stats (today: exactly starter_frigate).
  select count(*) into n from public.main_ship_hull_types
    where (base_stats_json->>'attack')::numeric is null or (base_stats_json->>'defense')::numeric is null;
  if n <> 0 then raise exception 'HULLSTATS FAIL: % hull rows missing base attack/defense (want 0 — the 0170 seed)', n; end if;
  select base_stats_json into v_hull from public.main_ship_hull_types where hull_type_id = 'starter_frigate';
  if (v_hull->>'attack')::numeric is distinct from 15 or (v_hull->>'defense')::numeric is distinct from 10 then
    raise exception 'HULLSTATS FAIL: starter_frigate base stats % (want attack 15 / defense 10 — the 0170 seed)', v_hull; end if;

  -- the adapter folds the hull stats: a bare ship's combat_power/survival == the hull seed exactly.
  s := public.calculate_expedition_stats(uA, a1, '[]'::jsonb, 'none');
  if (s->>'combat_power')::numeric is distinct from (v_hull->>'attack')::numeric
     or (s->>'survival')::numeric is distinct from (v_hull->>'defense')::numeric then
    raise exception 'HULLSTATS FAIL: bare-ship adapter stats (combat_power %, survival %) diverge from the hull seed %', s->>'combat_power', s->>'survival', v_hull; end if;

  raise notice 'TEAMCMD_PASS_HULLSTATS ok: every hull row seeded (starter_frigate 15/10) and the adapter folds hull base stats (bare ship == hull seed exactly)';
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
  -- captain_slots_limit=6: migration 0171 (captains-launch prep) ships the once-deferred hull bump
  -- + instance backfill, so a fresh all-migrations chain seeds base_captain_slots=6 — these ships
  -- copied 6 at commission (asserted in setup, no fixture bump), and it flows through the ONE
  -- adapter into the preview's stats.
  if (base->>'captain_slots_limit')::int is distinct from 6 then
    raise exception 'CAPTAINS FAIL: baseline captain_slots_limit % (want 6 — the 0171 captains-launch bump)', base->>'captain_slots_limit'; end if;
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

-- ════════ BLOCK TEAMSTATS (Slice D0, 0166): authoritative totals = delegation, strict-vs-preview ════════
-- get_my_group_expedition_totals is the AUTHORITATIVE team-stats surface (0166). Its dark reject was
-- already asserted in BLOCK DARK, before the flag flips. This block pins:
--   (a) the reject vocabulary (invalid_activity / group_not_found random + cross-player / empty_group);
--   (b) DELEGATION-NOT-REIMPLEMENTATION: every additive total must EQUAL this proof's OWN independent
--       per-member sum over DIRECT calculate_expedition_stats calls (this privileged psql context can
--       call the service_role-only adapter), and totals.speed = min member speed — so the totals RPC
--       can only be folding the ONE adapter's outputs, never recomputing stats;
--   (c) the STRICT posture (deliberate divergence from the C0 preview): one over-capacity member makes
--       the totals RPC refuse WHOLE with an OPAQUE stats_invalid (no members/detail leaked), while the
--       preview still answers ok:true with that member valid:false — strict authority vs friendly preview.
-- Runs on the CAPTAINS-block fixtures (gA1 = {a1, a2}, both home, captains all unassigned) and restores
-- them exactly before BLOCK SEND. Captains provisioned ONLY via the sole writers, as everywhere.
do $$
declare r jsonb; p jsonb; s1 jsonb; s2 jsonb; mem jsonb; n int; gid uuid; cap1 uuid; sk text;
  uA uuid := (select v from tcmd where k='uA'); uB uuid := (select v from tcmd where k='uB');
  a1 uuid := (select v from tcmd where k='a1'); a2 uuid := (select v from tcmd where k='a2');
  gA1 uuid := (select v from tcmd where k='gA1');
begin
  -- (a) reject vocabulary, in the RPC's order (gate already proven in BLOCK DARK):
  -- invalid_activity — validated BEFORE any row read, so even a real owned group answers the same.
  r := pg_temp.call_as(uA, format('public.get_my_group_expedition_totals(%L::uuid, ''warp_speed'')', gA1));
  if (r->>'reason') is distinct from 'invalid_activity' then raise exception 'TEAMSTATS FAIL invalid activity: %', r; end if;
  -- group_not_found — a random uuid, and uB cross-player-probing uA's real group (no ownership oracle).
  r := pg_temp.call_as(uA, 'public.get_my_group_expedition_totals(gen_random_uuid(), ''none'')');
  if (r->>'reason') is distinct from 'group_not_found' then raise exception 'TEAMSTATS FAIL random group: %', r; end if;
  r := pg_temp.call_as(uB, format('public.get_my_group_expedition_totals(%L::uuid, ''none'')', gA1));
  if (r->>'reason') is distinct from 'group_not_found' then raise exception 'TEAMSTATS FAIL cross-player probe: %', r; end if;
  -- empty_group — uA's memberless slot 3 (created in CAPTAINS; upsert is idempotent on the slot).
  r := pg_temp.call_as(uA, 'public.upsert_ship_group(3, ''D0Empty'')');
  if (r->>'ok')::boolean is not true then raise exception 'TEAMSTATS FAIL empty-slot upsert: %', r; end if;
  gid := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uA, format('public.get_my_group_expedition_totals(%L::uuid, ''none'')', gid));
  if (r->>'reason') is distinct from 'empty_group' then raise exception 'TEAMSTATS FAIL empty_group: %', r; end if;

  -- (b) HAPPY PATH on gA1 = {a1, a2}. Re-captain a1 via the SOLE WRITERS so the two members genuinely
  -- differ — a captained/uncaptained split would expose a totals path that ignored the captain fold.
  cap1 := public.captains_mint_instance(uA, 'gunnery_veteran', 'tcmd-d0-1');
  if cap1 is null then raise exception 'TEAMSTATS FAIL: mint returned null'; end if;
  perform public.captain_assign_apply(uA, cap1, a1);

  r := pg_temp.call_as(uA, format('public.get_my_group_expedition_totals(%L::uuid, ''none'')', gA1));
  if (r->>'ok')::boolean is not true then raise exception 'TEAMSTATS FAIL happy path: %', r; end if;
  if (r->>'member_count')::int is distinct from 2 or jsonb_array_length(r->'members') is distinct from 2 then
    raise exception 'TEAMSTATS FAIL member count/length: %', r; end if;

  -- the INDEPENDENT SUM: this proof calls the ONE adapter DIRECTLY per member (same inputs the totals
  -- RPC delegates with: empty loadout, 'none') and requires each additive total to EQUAL its own sum.
  s1 := public.calculate_expedition_stats(uA, a1, '[]'::jsonb, 'none');
  s2 := public.calculate_expedition_stats(uA, a2, '[]'::jsonb, 'none');
  foreach sk in array array['combat_power','survival','repair','retreat_safety','scouting','mining_yield','cargo_capacity','pirate_attention'] loop
    if (r->'totals'->>sk)::numeric is distinct from (s1->>sk)::numeric + (s2->>sk)::numeric then
      raise exception 'TEAMSTATS FAIL: totals.% is % (want independent sum % + %)', sk, r->'totals'->>sk, s1->>sk, s2->>sk; end if;
  end loop;
  -- speed is NOT additive: members travel individually → the team moves at its slowest member's pace.
  if (r->'totals'->>'speed')::numeric is distinct from least((s1->>'speed')::numeric, (s2->>'speed')::numeric) then
    raise exception 'TEAMSTATS FAIL: totals.speed % (want min(%, %))', r->'totals'->>'speed', s1->>'speed', s2->>'speed'; end if;
  -- and each members[] stats object is byte-identical to the direct adapter call (pure delegation).
  select e->'stats' into mem from jsonb_array_elements(r->'members') e where e->>'main_ship_id' = a1::text;
  if mem is distinct from s1 then raise exception 'TEAMSTATS FAIL: a1 member stats diverge from direct adapter: % vs %', mem, s1; end if;
  select e->'stats' into mem from jsonb_array_elements(r->'members') e where e->>'main_ship_id' = a2::text;
  if mem is distinct from s2 then raise exception 'TEAMSTATS FAIL: a2 member stats diverge from direct adapter: % vs %', mem, s2; end if;

  -- (c) STRICT posture: shrink a1's captain_slots below its used count (legal ≥0 CHECK; the same
  -- direct main_ship_instances fixture surgery the normalization step uses — NOT a Captain-table
  -- write) → 0122's over-capacity refuse-don't-clamp raise for a1 → the totals RPC refuses WHOLE,
  -- opaquely (no members/detail — the preview is the diagnosing surface)…
  update public.main_ship_instances set captain_slots = 0, updated_at = now() where main_ship_id = a1;
  r := pg_temp.call_as(uA, format('public.get_my_group_expedition_totals(%L::uuid, ''none'')', gA1));
  if (r->>'reason') is distinct from 'stats_invalid' then raise exception 'TEAMSTATS FAIL strict refuse: %', r; end if;
  if r ? 'members' or r ? 'totals' or r ? 'detail' then
    raise exception 'TEAMSTATS FAIL: stats_invalid envelope leaks member detail: %', r; end if;
  -- …while the C0 PREVIEW still answers ok:true with exactly that member valid:false (strict-vs-preview).
  p := pg_temp.call_as(uA, format('public.get_my_group_expedition_preview(%L::uuid, ''none'')', gA1));
  if (p->>'ok')::boolean is not true then raise exception 'TEAMSTATS FAIL preview during invalid member: %', p; end if;
  select count(*) into n from jsonb_array_elements(p->'members') e
    where e->>'main_ship_id' = a1::text and (e->>'valid')::boolean is false;
  if n <> 1 then raise exception 'TEAMSTATS FAIL: preview did not mark a1 valid:false: %', p->'members'; end if;

  -- restore the CAPTAINS-block fixture shape for the SEND/STOP blocks: slots back to the in-txn
  -- activation value, captain unassigned (sole writer), and totals answers ok again.
  update public.main_ship_instances set captain_slots = 6, updated_at = now() where main_ship_id = a1;
  perform public.captain_assign_apply(uA, cap1, null);
  r := pg_temp.call_as(uA, format('public.get_my_group_expedition_totals(%L::uuid, ''none'')', gA1));
  if (r->>'ok')::boolean is not true then raise exception 'TEAMSTATS FAIL post-restore totals: %', r; end if;

  raise notice 'TEAMCMD_PASS_TEAMSTATS ok: rejects (invalid_activity/group_not_found×2/empty_group), totals = independent per-member adapter sums with speed=min, strict opaque stats_invalid vs preview valid:false, fixtures restored';
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

-- ════════ BLOCK COMBATPARITY (Slice D1, 0167): legacy tick/report byte-parity + identity CHECK + one engine ════════
-- Slice D1 re-created the LIVE combat tick (0046 head) and report writer (0026 head) with member-only
-- deltas (member rows have NO writer until D2). This block proves the LEGACY combat path still behaves
-- identically — provisioned entirely through the real chain (send_fleet_to_location →
-- movement_settle_arrival, the SAME per-movement settle the movement cron loop calls →
-- combat_create_encounter → process_combat_ticks → request_retreat → escape → report_create).
-- Deliberately positioned AFTER the team blocks, with team_command_enabled still ON in-txn: the team
-- flag must be IRRELEVANT to a legacy unit fleet's combat — that irrelevance is itself asserted (the
-- encounter's combat_units rows must be pure legacy). In-txn config surgery goes through the real
-- set_game_config (the 0046-documented CI idiom; all reverted by ROLLBACK): tick logging ON so the
-- tick's internals are observable, damage variance 0 so the damage equality is EXACT, not statistical.
-- The only direct fixture surgery is clock rewinding (arrive_at / last_resolved_at /
-- retreat_started_at) — now() is txn-constant, so no real interval can ever elapse in this proof.
do $$
declare r jsonb; n int; t record;
  uA uuid := (select v from tcmd where k='uA');
  a1 uuid := (select v from tcmd where k='a1');
  a3 uuid := (select v from tcmd where k='a3');
  v_base uuid; v_hunt uuid; v_fleet uuid; v_mv uuid; v_enc uuid; v_pres uuid;
  v_expected_attack double precision; v_expected_defense double precision; v_hp_before double precision;
  v_hp_after double precision; v_expected_enemy double precision; v_bd double precision;
  v_defbase double precision; v_danger integer; v_waves integer; v_started timestamptz;
  v_keys text[]; v_expected_keys text[]; v_speed double precision; v_bad int := 0;
begin
  perform public.set_game_config('combat_tick_logging', 'true'::jsonb);
  perform public.set_game_config('combat_damage_variance_pct', '0'::jsonb);

  -- a real legacy unit fleet to a real hunt_pirates location (lowest entry gate first).
  select id into v_base from public.bases where player_id = uA and status = 'active' limit 1;
  select id into v_hunt from public.locations
    where activity_type = 'hunt_pirates' and status = 'active'
    order by min_power_required asc, base_difficulty asc limit 1;
  if v_hunt is null then raise exception 'COMBATPARITY FAIL: no active hunt_pirates location'; end if;

  r := pg_temp.call_as(uA, format('public.send_fleet_to_location(%L::uuid, %L::uuid, %L::jsonb)',
        v_base, v_hunt, '[{"unit_type_id":"scout","quantity":40},{"unit_type_id":"corvette","quantity":10}]'::jsonb));
  v_fleet := (r->>'fleet_id')::uuid; v_mv := (r->>'movement_id')::uuid;
  if v_fleet is null or v_mv is null then raise exception 'COMBATPARITY FAIL send: %', r; end if;

  -- settle the arrival through the SAME function the movement cron uses (rewind first — sanctioned
  -- clock surgery; the depart_at rewind keeps the arrive_at > depart_at CHECK satisfied).
  update public.fleet_movements
     set depart_at = now() - interval '2 minutes', arrive_at = now() - interval '1 minute'
   where id = v_mv;
  r := public.movement_settle_arrival(v_mv);
  if (r->>'settled')::boolean is not true or (r->>'outcome') is distinct from 'present' then
    raise exception 'COMBATPARITY FAIL settle: %', r; end if;

  -- the arrival hook created the encounter; every combat_units row is PURE LEGACY even though the
  -- team flag is ON in-txn: unit_type_id NOT NULL, main_ship_id NULL, snapshots NULL (no D2 writer).
  select id, presence_id into v_enc, v_pres from public.combat_encounters
    where fleet_id = v_fleet and status = 'active';
  if v_enc is null then raise exception 'COMBATPARITY FAIL: no active encounter after arrival'; end if;
  select count(*) into n from public.combat_units where encounter_id = v_enc;
  if n <> 2 then raise exception 'COMBATPARITY FAIL: % combat_units rows (want 2)', n; end if;
  select count(*) into n from public.combat_units where encounter_id = v_enc
    and (unit_type_id is null or main_ship_id is not null or attack_snapshot is not null or defense_snapshot is not null);
  if n <> 0 then raise exception 'COMBATPARITY FAIL: % non-legacy combat_units rows under team flag ON (want 0)', n; end if;

  -- leaf smoke: the member return-speed leaf answers NULL for a legacy (member-less) fleet with an
  -- active encounter — exactly the value that makes the tick's coalesce fallback a no-op.
  if public.combat_fleet_return_speed(v_fleet) is not null then
    raise exception 'COMBATPARITY FAIL: combat_fleet_return_speed not NULL for a legacy fleet'; end if;

  -- THE INDEPENDENT SUMS: expected tick attack = Σ(unit_types.attack × alive_count) and expected
  -- defense = Σ(unit_types.defense × alive_count), computed by this proof from the catalog BEFORE the
  -- tick. With variance pinned to 0 the tick's player_damage must EQUAL the attack sum exactly —
  -- through the D1 left-join/coalesce(snapshot, catalog) aggregation.
  select sum(ut.attack * cu.alive_count), sum(ut.defense * cu.alive_count), sum(cu.hp_current)
    into v_expected_attack, v_expected_defense, v_hp_before
    from public.combat_units cu join public.unit_types ut on ut.id = cu.unit_type_id
    where cu.encounter_id = v_enc;

  -- expected tick 1 ENEMY damage (the defense curve flows through the SAME D1 left-join/coalesce
  -- hunk), mirroring the tick body's arithmetic in the 0046 operation order EXACTLY:
  --   danger       = 1 + waves_cleared + floor(secs_inside / danger_time_divisor_seconds)
  --   enemy_attack = base_difficulty × enemy_attack_base × (1 + danger × enemy_attack_danger_scale)
  --   enemy_damage = enemy_attack × def_base / (def_base + Σ(defense×alive)) × variance
  -- The compare below is EXACT (no tolerance): the tick stores enemy_damage UNROUNDED; variance is
  -- exactly 1.0 with the pct pinned to 0 ((1-0) + random()*0), and ×1.0 is exact in IEEE; the 2-term
  -- defense sum is order-independent; and the expression here repeats the tick's operation order.
  select waves_cleared, started_at into v_waves, v_started from public.combat_encounters where id = v_enc;
  v_danger  := 1 + v_waves + floor(extract(epoch from (now() - v_started)) / coalesce(cfg_num('danger_time_divisor_seconds'), 180))::integer;
  v_defbase := coalesce(cfg_num('defense_curve_base'), 100);
  select base_difficulty into v_bd from public.locations where id = v_hunt;
  v_expected_enemy := v_bd * coalesce(cfg_num('enemy_attack_base'),1.0)
                      * (1 + v_danger * coalesce(cfg_num('enemy_attack_danger_scale'),0.25));
  v_expected_enemy := v_expected_enemy * v_defbase / (v_defbase + v_expected_defense) * 1.0;

  update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc;
  perform public.process_combat_ticks();

  select * into t from public.combat_ticks where encounter_id = v_enc and tick_number = 1;
  if t.id is null then raise exception 'COMBATPARITY FAIL: no tick 1 row (tick logging is on)'; end if;
  if t.player_damage is distinct from v_expected_attack then
    raise exception 'COMBATPARITY FAIL: tick player_damage % (want independent Σ(attack×alive) %)', t.player_damage, v_expected_attack; end if;
  if t.danger_level is distinct from v_danger then
    raise exception 'COMBATPARITY FAIL: tick danger_level % (want mirrored %)', t.danger_level, v_danger; end if;
  if t.enemy_damage is distinct from v_expected_enemy then
    raise exception 'COMBATPARITY FAIL: tick enemy_damage % (want independent defense-curve value %)', t.enemy_damage, v_expected_enemy; end if;
  if t.result not in ('ongoing','wave_cleared') then raise exception 'COMBATPARITY FAIL: tick 1 result %', t.result; end if;

  -- legacy jsonb keys: the tick snapshot keys are EXACTLY the fleet's unit_type_ids; every loss key
  -- is a catalog id (never a uuid-keyed member entry).
  select array_agg(k order by k) into v_keys from jsonb_object_keys(t.unit_snapshot_json) k;
  select array_agg(unit_type_id order by unit_type_id) into v_expected_keys
    from public.combat_units where encounter_id = v_enc;
  if v_keys is distinct from v_expected_keys then
    raise exception 'COMBATPARITY FAIL: snapshot keys % (want legacy unit keys %)', v_keys, v_expected_keys; end if;
  select count(*) into n from jsonb_object_keys(t.player_losses_json) k
    where not exists (select 1 from public.unit_types u where u.id = k);
  if n <> 0 then raise exception 'COMBATPARITY FAIL: % non-catalog loss keys: %', n, t.player_losses_json; end if;

  -- hp accounting is exact, and the catalog survivor sync landed in fleet_units — i.e.
  -- fleet_sync_quantities received ONLY catalog-keyed rows and synced every one of them.
  select sum(hp_current) into v_hp_after from public.combat_units where encounter_id = v_enc;
  if t.player_integrity_after is distinct from greatest(0, v_hp_after) then
    raise exception 'COMBATPARITY FAIL: integrity_after % vs summed unit hp %', t.player_integrity_after, v_hp_after; end if;
  if t.player_integrity_before is distinct from v_hp_before then
    raise exception 'COMBATPARITY FAIL: integrity_before % vs pre-tick unit hp %', t.player_integrity_before, v_hp_before; end if;
  select count(*) into n from public.combat_units cu
    join public.fleet_units fu on fu.fleet_id = v_fleet and fu.unit_type_id = cu.unit_type_id
    where cu.encounter_id = v_enc and fu.quantity <> cu.alive_count;
  if n <> 0 then raise exception 'COMBATPARITY FAIL: % fleet_units rows out of sync with alive_count', n; end if;

  -- retreat → escape settle: the report shape + the return movement's LEGACY speed.
  r := pg_temp.call_as(uA, format('public.request_retreat(%L::uuid)', v_pres));
  update public.combat_encounters
     set retreat_started_at = retreat_started_at - interval '1 minute',
         last_resolved_at   = last_resolved_at   - interval '1 minute'
   where id = v_enc;
  perform public.process_combat_ticks();

  select count(*) into n from public.combat_encounters where id = v_enc and status = 'escaped' and ended_at is not null;
  if n <> 1 then raise exception 'COMBATPARITY FAIL: encounter did not settle escaped'; end if;
  select count(*) into n from public.combat_reports where encounter_id = v_enc and result = 'escaped';
  if n <> 1 then raise exception 'COMBATPARITY FAIL: no escaped combat_report'; end if;
  -- report keys stay the legacy unit_type ids (the D1 coalesce key is a no-op for legacy rows).
  select count(*) into n from public.combat_reports cr, jsonb_object_keys(cr.survivors_json) k
    where cr.encounter_id = v_enc and not exists (select 1 from public.unit_types u where u.id = k);
  if n <> 0 then raise exception 'COMBATPARITY FAIL: non-catalog survivor keys in the report'; end if;
  -- the return movement used fleet_speed (units survive) — D1's combat_fleet_return_speed fallback is
  -- a coalesce no-op for legacy: speed_used must equal the independent min catalog speed.
  select min(ut.speed) into v_speed
    from public.fleet_units fu join public.unit_types ut on ut.id = fu.unit_type_id
    where fu.fleet_id = v_fleet and fu.quantity > 0;
  select count(*) into n from public.fleet_movements
    where fleet_id = v_fleet and mission_type = 'return_home' and status = 'moving' and speed_used = v_speed;
  if n <> 1 then raise exception 'COMBATPARITY FAIL: return movement missing or speed_used <> legacy fleet_speed %', v_speed; end if;

  -- the exactly-one-identity CHECK: BOTH identities and NEITHER identity must each raise 23514.
  -- (These are deliberate ILLEGAL inserts probing the constraint — not a member-row writer; a
  -- succeeding insert increments v_bad and fails the block. A not-null raise instead of a
  -- check_violation would also fail the block — pinning that the unit_type_id relax shipped.)
  begin
    insert into public.combat_units (encounter_id, player_id, unit_type_id, main_ship_id, ship_hp, initial_count, alive_count, hp_max, hp_current)
      values (v_enc, uA, 'frigate', a1, 1, 1, 1, 1, 1);
    v_bad := v_bad + 1;
  exception when check_violation then null; end;
  begin
    insert into public.combat_units (encounter_id, player_id, unit_type_id, main_ship_id, ship_hp, initial_count, alive_count, hp_max, hp_current)
      values (v_enc, uA, null, null, 1, 1, 1, 1, 1);
    v_bad := v_bad + 1;
  exception when check_violation then null; end;
  if v_bad <> 0 then raise exception 'COMBATPARITY FAIL: % illegal identity inserts were ACCEPTED (want 0)', v_bad; end if;

  -- leaf smoke on a fixture team ship (a3: home, spatial_state NULL — undisturbed since BLOCK STOP;
  -- rolled back with everything): mainship_sync_combat_hp writes hp ONLY (status/spatial untouched);
  -- mainship_mark_combat_destroyed writes the exact 0059 terminal (status/hp/spatial_state/coords).
  perform public.mainship_sync_combat_hp(a3, 123);
  select count(*) into n from public.main_ship_instances
    where main_ship_id = a3 and hp = 123 and status = 'home' and spatial_state is null;
  if n <> 1 then raise exception 'COMBATPARITY FAIL: mainship_sync_combat_hp did not write hp-only'; end if;
  perform public.mainship_mark_combat_destroyed(a3);
  select count(*) into n from public.main_ship_instances
    where main_ship_id = a3 and status = 'destroyed' and hp = 0
      and spatial_state is null and space_x is null and space_y is null;
  if n <> 1 then raise exception 'COMBATPARITY FAIL: mainship_mark_combat_destroyed did not write the 0059 terminal'; end if;

  -- the no-second-engine pin: EXACTLY one combat cron job, and it is the 0026 tick schedule.
  select count(*) into n from cron.job where jobname like '%combat%';
  if n <> 1 then raise exception 'COMBATPARITY FAIL: % combat cron jobs (want exactly 1)', n; end if;
  select count(*) into n from cron.job
    where jobname = 'process-combat-ticks' and command like '%process_combat_ticks%';
  if n <> 1 then raise exception 'COMBATPARITY FAIL: the one combat job is not process-combat-ticks'; end if;

  raise notice 'TEAMCMD_PASS_COMBATPARITY ok: legacy hunt via real chain under team flag ON; tick damage = independent Σ(attack×alive); enemy damage = independent defense-curve value; legacy jsonb keys; hp+fleet sync exact; escaped report legacy-keyed; return speed = fleet_speed; identity CHECK raises both ways; leaf smoke (NULL return speed, hp-only sync, 0059 terminal); exactly 1 combat cron job';
end $$;

-- ════════ BLOCK TEAMHUNT (Slice D2, 0168): hunt send + sortie manifest + member encounter routing ════════
-- The FIRST member combat_units rows ever written — the writer D1 deferred. Real chain end to end:
-- send_ship_group_hunt (ONE fleet, manifest frozen, ships 'hunting', speed = D0 totals.speed) →
-- movement_settle_arrival (the SAME per-movement settle the cron calls) → presence_create →
-- combat_create_encounter's D2 branch → combat_create_group_encounter (member snapshots from the
-- MANIFEST) → process_combat_ticks (the member path's first live execution: damage distribution +
-- the D1 hp sync leaf). Pins: reject vocabulary + order (invalid_location answers BEFORE member
-- readiness); ONE fleet per team send; movement speed_used == the proof's OWN independent D0
-- totals.speed; each member's attack_snapshot == the proof's OWN direct per-member adapter call;
-- hp_current == the ship's REAL current hp (pre-existing damage carries in); encounter
-- player_power_start == totals.combat_power; tick player_damage == Σ member attack_snapshot
-- (variance re-pinned 0); double-send + live-single-send races reject; the MANIFEST-WINS law —
-- a mid-flight unassign (real RPC) leaves the manifest at 2 rows and the next tick still drives BOTH
-- members; the send's hp>0 readiness guard (a zero-hp 'home' ship rejects member_not_ready); and the
-- H1 CRON-SAFETY degrade: an adapter-refused member does NOT poison movement_settle_arrival (no
-- per-movement subtransaction exists in the cron scan) — the settle succeeds, the member row lands
-- degraded (alive_count=0 / zero snapshots / zero hp), and the all-degraded encounter defeats cleanly
-- through the existing machinery. Fixture surgery is limited to the quarantined kinds already used
-- above: the c2 home normalization (the provisioning idiom), the TEAMSTATS captain_slots surgery, and
-- clock rewinds. The manifest itself is NEVER touched directly — send_ship_group_hunt is its sole
-- writer (the .sh selftest greps that no direct group_sortie_members mutation exists).
do $$
declare r jsonb; t jsonb; s1 jsonb; s2 jsonb; n int;
  uB uuid := (select v from tcmd where k='uB'); uC uuid := (select v from tcmd where k='uC');
  uA uuid := (select v from tcmd where k='uA');
  gA1 uuid := (select v from tcmd where k='gA1'); gB1 uuid := (select v from tcmd where k='gB1');
  c1 uuid := (select v from tcmd where k='c1'); c2 uuid := (select v from tcmd where k='c2');
  b1 uuid := (select v from tcmd where k='b1');
  slag uuid := (select v from tcmd where k='slag');
  v_hunt uuid; gH uuid; capa uuid; capb uuid; capc uuid; capd uuid;
  v_fleet uuid; v_mv uuid; v_enc uuid; v_active_before int;
  v_fleet2 uuid; v_mv2 uuid; v_enc2 uuid;
  v_hp1 double precision; v_hp2 double precision; v_hp1b double precision; v_hp2b double precision;
  v_err text;
begin
  -- config surgery must be in effect for the exact-damage pins: re-apply the COMBATPARITY in-txn
  -- surgery (idempotent; the real set_game_config; all reverted by ROLLBACK).
  perform public.set_game_config('combat_tick_logging', 'true'::jsonb);
  perform public.set_game_config('combat_damage_variance_pct', '0'::jsonb);

  -- the same seeded hunt destination COMBATPARITY used (lowest entry gate first).
  select id into v_hunt from public.locations
    where activity_type = 'hunt_pirates' and status = 'active'
    order by min_power_required asc, base_difficulty asc limit 1;
  if v_hunt is null then raise exception 'TEAMHUNT FAIL: no active hunt_pirates location'; end if;

  -- ── reject vocabulary, in the RPC's order (dark gate already proven in BLOCK DARK) ────────────────
  -- group_not_found — a random uuid, and uC cross-player-probing uB's real group (no ownership oracle).
  r := pg_temp.call_as(uC, format('public.send_ship_group_hunt(gen_random_uuid(), %L::uuid)', v_hunt));
  if (r->>'reason') is distinct from 'group_not_found' then raise exception 'TEAMHUNT FAIL random group: %', r; end if;
  r := pg_temp.call_as(uC, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gB1, v_hunt));
  if (r->>'reason') is distinct from 'group_not_found' then raise exception 'TEAMHUNT FAIL cross-player probe: %', r; end if;
  -- empty_group — uB's created-but-memberless slot.
  r := pg_temp.call_as(uB, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gB1, v_hunt));
  if (r->>'reason') is distinct from 'empty_group' then raise exception 'TEAMHUNT FAIL empty_group: %', r; end if;
  -- invalid_location — a SAFE (activity none) destination MUST reject, and it must answer BEFORE the
  -- member-readiness check: gA1's members (a1,a2 held stationary since BLOCK STOP; a3 destroyed in
  -- COMBATPARITY) are all unready, yet the answer is the location's (the reject-order pin).
  r := pg_temp.call_as(uA, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gA1, slag));
  if (r->>'reason') is distinct from 'invalid_location' then raise exception 'TEAMHUNT FAIL invalid_location: %', r; end if;
  -- member_not_ready — the same unready team against the REAL hunt destination.
  r := pg_temp.call_as(uA, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gA1, v_hunt));
  if (r->>'reason') is distinct from 'member_not_ready' then raise exception 'TEAMHUNT FAIL member_not_ready: %', r; end if;

  -- ── happy-path fixture: uC's pair {c1 (home), c2} — normalize c2 to home (the SAME quarantined
  -- provisioning idiom: home shape + retire its 'present' commission fleet + settle its presence).
  update public.main_ship_instances
     set status = 'home', spatial_state = null, space_x = null, space_y = null, updated_at = now()
   where main_ship_id = c2;
  update public.fleets
     set status = 'destroyed', location_mode = 'destroyed', active_movement_id = null,
         current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
         updated_at = now()
   where main_ship_id = c2 and status = 'present';
  update public.location_presence
     set status = 'completed', updated_at = now()
   where fleet_id in (select id from public.fleets where main_ship_id = c2 and status = 'destroyed')
     and status = 'active';
  -- pre-existing damage pin: dent c2 via the D1 hp-only leaf (hp 500 → 350) BEFORE the send — its
  -- member combat row must carry 350, never max_hp.
  perform public.mainship_sync_combat_hp(c2, 350);

  -- captains via the SOLE WRITERS only (as everywhere): c1 gets two gunnery seeds (+8 combat), c2 one
  -- (+4) — members genuinely differ, so a creator that swapped/averaged snapshots cannot false-green.
  capa := public.captains_mint_instance(uC, 'gunnery_veteran', 'tcmd-d2-1');
  capb := public.captains_mint_instance(uC, 'gunnery_veteran', 'tcmd-d2-2');
  capc := public.captains_mint_instance(uC, 'gunnery_veteran', 'tcmd-d2-3');
  perform public.captain_assign_apply(uC, capa, c1);
  perform public.captain_assign_apply(uC, capb, c1);
  perform public.captain_assign_apply(uC, capc, c2);

  -- team slot 1 is free again for uC (gC1 was deleted in BLOCK DELETE).
  r := pg_temp.call_as(uC, 'public.upsert_ship_group(1, ''HuntPack'')');
  if (r->>'ok')::boolean is not true then raise exception 'TEAMHUNT FAIL group create: %', r; end if;
  gH := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uC, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', c1, gH));
  if (r->>'ok')::boolean is not true then raise exception 'TEAMHUNT FAIL assign c1: %', r; end if;
  r := pg_temp.call_as(uC, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', c2, gH));
  if (r->>'ok')::boolean is not true then raise exception 'TEAMHUNT FAIL assign c2: %', r; end if;

  -- H1 send-side hp guard: a ZERO-hp 'home' member is schema-legal (the D1 hp sync can write 0 on a
  -- member that died while its team escaped) and must reject member_not_ready at SEND time — dent c1
  -- to 0 via the D1 leaf, assert, restore the fixture hp.
  perform public.mainship_sync_combat_hp(c1, 0);
  r := pg_temp.call_as(uC, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gH, v_hunt));
  if (r->>'reason') is distinct from 'member_not_ready' then raise exception 'TEAMHUNT FAIL hp-zero send: %', r; end if;
  perform public.mainship_sync_combat_hp(c1, 500);

  -- THE INDEPENDENT EXPECTATIONS, captured BEFORE the send: the D0 authority's totals (this
  -- privileged context calls it directly) and the ONE adapter per member (the same inputs the
  -- encounter creator must use).
  t  := public.calculate_group_expedition_stats(uC, gH, 'pirate_hunt');
  s1 := public.calculate_expedition_stats(uC, c1, '[]'::jsonb, 'pirate_hunt');
  s2 := public.calculate_expedition_stats(uC, c2, '[]'::jsonb, 'pirate_hunt');
  select count(*) into v_active_before from public.fleets
    where player_id = uC and status in ('moving','present','returning');
  if v_active_before <> 0 then raise exception 'TEAMHUNT FAIL precondition: uC has % active fleets (want 0)', v_active_before; end if;

  -- ── SEND ──────────────────────────────────────────────────────────────────────────────────────────
  r := pg_temp.call_as(uC, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gH, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'TEAMHUNT FAIL send: %', r; end if;
  v_fleet := (r->>'fleet_id')::uuid; v_mv := (r->>'movement_id')::uuid;
  if v_fleet is null or v_mv is null or (r->>'member_count')::int is distinct from 2 then
    raise exception 'TEAMHUNT FAIL send envelope: %', r; end if;

  -- exactly ONE fleet for the whole team (the narrow-bridge shape, not per-member fleets)…
  select count(*) into n from public.fleets
    where player_id = uC and status in ('moving','present','returning');
  if n <> 1 then raise exception 'TEAMHUNT FAIL: % active fleets for the team send (want exactly ONE)', n; end if;
  -- …tagged with the informational group_id, moving, and NOT main-ship-tagged (one fleet, many ships).
  select count(*) into n from public.fleets
    where id = v_fleet and group_id = gH and main_ship_id is null and status = 'moving' and active_movement_id = v_mv;
  if n <> 1 then raise exception 'TEAMHUNT FAIL: sortie fleet shape wrong (group_id/main_ship_id/status)'; end if;
  -- the MANIFEST: exactly the 2 members, frozen.
  select count(*) into n from public.group_sortie_members
    where fleet_id = v_fleet and main_ship_id in (c1, c2) and player_id = uC;
  if n <> 2 then raise exception 'TEAMHUNT FAIL: % manifest rows (want 2)', n; end if;
  -- both ships out hunting (the 0043 status that only the D3 return path will clear).
  select count(*) into n from public.main_ship_instances
    where main_ship_id in (c1, c2) and status = 'hunting' and spatial_state is null;
  if n <> 2 then raise exception 'TEAMHUNT FAIL: % ships hunting (want 2)', n; end if;
  -- movement speed == the INDEPENDENT D0 totals.speed (min member speed), mission = hunt_pirates.
  select count(*) into n from public.fleet_movements
    where id = v_mv and mission_type = 'hunt_pirates' and target_location_id = v_hunt
      and speed_used is not distinct from (t->'totals'->>'speed')::double precision;
  if n <> 1 then raise exception 'TEAMHUNT FAIL: movement speed_used is distinct from (t->''totals''->>''speed'') (independent D0 totals.speed)'; end if;
  select count(*) into n from public.fleet_movements
    where id = v_mv and speed_used is not distinct from least((s1->>'speed')::double precision, (s2->>'speed')::double precision);
  if n <> 1 then raise exception 'TEAMHUNT FAIL: movement speed_used <> min member adapter speed'; end if;

  -- ── RACES while the sortie is live ────────────────────────────────────────────────────────────────
  -- the live single send must reject a hunting member (status='hunting' is not 'home')…
  begin
    r := pg_temp.call_as(uC, format('public.send_main_ship_expedition(%L::jsonb, %L::uuid)',
          jsonb_build_array(c1), slag));
    raise exception 'TEAMHUNT FAIL: live single send ACCEPTED a hunting member: %', r;
  exception when others then
    v_err := sqlerrm;
    if v_err not like '%not available (status hunting)%' then
      raise exception 'TEAMHUNT FAIL: single-send race raised the wrong error: %', v_err; end if;
  end;
  -- …and a second team hunt-send on the same group rejects member_not_ready (double-send close).
  r := pg_temp.call_as(uC, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gH, v_hunt));
  if (r->>'reason') is distinct from 'member_not_ready' then raise exception 'TEAMHUNT FAIL double send: %', r; end if;

  -- ── SETTLE via the cron's own per-movement settle (clock rewind, the sanctioned surgery) ──────────
  update public.fleet_movements
     set depart_at = now() - interval '2 minutes', arrive_at = now() - interval '1 minute'
   where id = v_mv;
  r := public.movement_settle_arrival(v_mv);
  if (r->>'settled')::boolean is not true or (r->>'outcome') is distinct from 'present' then
    raise exception 'TEAMHUNT FAIL settle: %', r; end if;

  -- ONE encounter, routed through the D2 branch into the member creator.
  select count(*) into n from public.combat_encounters where fleet_id = v_fleet;
  if n <> 1 then raise exception 'TEAMHUNT FAIL: % encounters for the sortie fleet (want 1)', n; end if;
  select id into v_enc from public.combat_encounters where fleet_id = v_fleet and status = 'active';
  if v_enc is null then raise exception 'TEAMHUNT FAIL: sortie encounter not active'; end if;

  -- exactly 2 member combat rows, all member-shaped (unit_type_id NULL + both snapshots — D1 CHECKs).
  select count(*) into n from public.combat_units where encounter_id = v_enc;
  if n <> 2 then raise exception 'TEAMHUNT FAIL: % combat_units rows (want 2)', n; end if;
  select count(*) into n from public.combat_units
    where encounter_id = v_enc and unit_type_id is null and main_ship_id in (c1, c2)
      and attack_snapshot is not null and defense_snapshot is not null
      and initial_count = 1 and alive_count = 1;
  if n <> 2 then raise exception 'TEAMHUNT FAIL: combat rows are not member-shaped'; end if;
  -- per-member snapshots == the proof's OWN direct adapter calls (the delegation pin, member side).
  select count(*) into n from public.combat_units
    where encounter_id = v_enc and main_ship_id = c1
      and attack_snapshot  is not distinct from (s1->>'combat_power')::double precision
      and defense_snapshot is not distinct from (s1->>'survival')::double precision;
  if n <> 1 then raise exception 'TEAMHUNT FAIL: c1 attack_snapshot is distinct from (s1->>''combat_power'') (independent adapter call)'; end if;
  select count(*) into n from public.combat_units
    where encounter_id = v_enc and main_ship_id = c2
      and attack_snapshot  is not distinct from (s2->>'combat_power')::double precision
      and defense_snapshot is not distinct from (s2->>'survival')::double precision;
  if n <> 1 then raise exception 'TEAMHUNT FAIL: c2 attack_snapshot is distinct from (s2->>''combat_power'') (independent adapter call)'; end if;
  -- hp_current == each ship's REAL current hp (c2 carries its pre-send dent: 350, never max_hp).
  select count(*) into n from public.combat_units cu
    join public.main_ship_instances msi on msi.main_ship_id = cu.main_ship_id
    where cu.encounter_id = v_enc
      and cu.hp_current is not distinct from msi.hp::double precision
      and cu.hp_max     is not distinct from msi.hp::double precision
      and cu.ship_hp    is not distinct from msi.hp::double precision;
  if n <> 2 then raise exception 'TEAMHUNT FAIL: member hp columns diverge from the ships'' real hp'; end if;
  select count(*) into n from public.combat_units
    where encounter_id = v_enc and main_ship_id = c2 and hp_current = 350;
  if n <> 1 then raise exception 'TEAMHUNT FAIL: c2 pre-existing damage did not carry in (want hp_current 350)'; end if;
  -- encounter aggregates: power_start == the INDEPENDENT D0 totals.combat_power (== s1+s2 sum);
  -- integrity == Σ member real hp.
  select count(*) into n from public.combat_encounters
    where id = v_enc
      and player_power_start is not distinct from (t->'totals'->>'combat_power')::double precision
      and player_power_start is not distinct from ((s1->>'combat_power')::double precision + (s2->>'combat_power')::double precision);
  if n <> 1 then raise exception 'TEAMHUNT FAIL: player_power_start is distinct from (t->''totals''->>''combat_power'') (independent D0 totals)'; end if;
  select count(*) into n from public.combat_encounters ce
    where ce.id = v_enc and ce.player_integrity_max is not distinct from
      (select sum(hp_current) from public.combat_units where encounter_id = v_enc);
  if n <> 1 then raise exception 'TEAMHUNT FAIL: player_integrity_max <> summed member hp'; end if;

  -- ── TICK 1: the member path's first live execution ────────────────────────────────────────────────
  select hp_current into v_hp1 from public.combat_units where encounter_id = v_enc and main_ship_id = c1;
  select hp_current into v_hp2 from public.combat_units where encounter_id = v_enc and main_ship_id = c2;
  update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc;
  perform public.process_combat_ticks();
  -- tick player_damage == Σ member attack_snapshot (the member-side aggregation pin; variance 0).
  select count(*) into n from public.combat_ticks
    where encounter_id = v_enc and tick_number = 1
      and player_damage is not distinct from
        (select sum(attack_snapshot * alive_count) from public.combat_units where encounter_id = v_enc);
  if n <> 1 then raise exception 'TEAMHUNT FAIL: tick player_damage is distinct from sum(attack_snapshot) (member aggregation pin)'; end if;
  -- damage distributed over the member rows: both alive rows took hull damage…
  select hp_current into v_hp1b from public.combat_units where encounter_id = v_enc and main_ship_id = c1;
  select hp_current into v_hp2b from public.combat_units where encounter_id = v_enc and main_ship_id = c2;
  if v_hp1b >= v_hp1 or v_hp2b >= v_hp2 then
    raise exception 'TEAMHUNT FAIL: member rows took no damage on tick 1 (c1 %→%, c2 %→%)', v_hp1, v_hp1b, v_hp2, v_hp2b; end if;
  -- …and the D1 sync leaf drove the damage back to the SHIP rows (hp only; still hunting).
  select count(*) into n from public.combat_units cu
    join public.main_ship_instances msi on msi.main_ship_id = cu.main_ship_id
    where cu.encounter_id = v_enc and msi.status = 'hunting'
      and msi.hp = round(greatest(0, cu.hp_current))::integer;
  if n <> 2 then raise exception 'TEAMHUNT FAIL: main_ship_instances.hp not synced from the member rows'; end if;

  -- ── MANIFEST WINS: mid-flight unassign (real RPC) must not orphan the sortie ──────────────────────
  r := pg_temp.call_as(uC, format('public.assign_ship_to_group(%L::uuid, null)', c1));
  if (r->>'ok')::boolean is not true then raise exception 'TEAMHUNT FAIL manifest-wins unassign: %', r; end if;
  select count(*) into n from public.group_sortie_members where fleet_id = v_fleet;
  if n <> 2 then raise exception 'TEAMHUNT FAIL manifest-wins: manifest has % rows after unassign (want still 2)', n; end if;
  -- the next tick still drives BOTH members (damage + hp sync), though c1 left the live group.
  select hp_current into v_hp1 from public.combat_units where encounter_id = v_enc and main_ship_id = c1;
  select hp_current into v_hp2 from public.combat_units where encounter_id = v_enc and main_ship_id = c2;
  update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc;
  perform public.process_combat_ticks();
  select hp_current into v_hp1b from public.combat_units where encounter_id = v_enc and main_ship_id = c1;
  select hp_current into v_hp2b from public.combat_units where encounter_id = v_enc and main_ship_id = c2;
  if v_hp1b >= v_hp1 or v_hp2b >= v_hp2 then
    raise exception 'TEAMHUNT FAIL manifest-wins: a member row took no damage after the unassign (c1 %→%, c2 %→%)', v_hp1, v_hp1b, v_hp2, v_hp2b; end if;
  select count(*) into n from public.combat_units cu
    join public.main_ship_instances msi on msi.main_ship_id = cu.main_ship_id
    where cu.encounter_id = v_enc and msi.hp = round(greatest(0, cu.hp_current))::integer;
  if n <> 2 then raise exception 'TEAMHUNT FAIL manifest-wins: hp sync missed a member after the unassign'; end if;

  -- ── H1 CRON-SAFETY (the crown-jewel pin): a member whose adapter RAISES at arrival must NOT ───────
  -- poison the settle. process_fleet_movements has NO per-movement subtransaction (pg_cron runs the
  -- scan as ONE txn) — a creator raise would roll back every other arrival in the run AND wedge the
  -- movement forever. Fixture: uB's b1 (home, unused) with one captain (sole writer), sent as a
  -- 1-ship team, then captain_slots→0 surgery MID-FLIGHT (the TEAMSTATS over-capacity idiom — a
  -- main_ship_instances fixture write, NOT a Captain-table write) so calculate_expedition_stats
  -- refuses b1 at arrival. The settle must still SUCCEED; b1's member row must DEGRADE
  -- (alive_count=0, zero snapshots, zero hp); and the next tick must settle the all-degraded
  -- zero-hp encounter as a clean DEFEAT through the EXISTING machinery (fleet_destroy + the D1
  -- member loop marking b1 combat-destroyed) — no raise, no orphaned 'hunting' ship.
  capd := public.captains_mint_instance(uB, 'gunnery_veteran', 'tcmd-d2-4');
  perform public.captain_assign_apply(uB, capd, b1);
  r := pg_temp.call_as(uB, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', b1, gB1));
  if (r->>'ok')::boolean is not true then raise exception 'TEAMHUNT FAIL degrade assign: %', r; end if;
  r := pg_temp.call_as(uB, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gB1, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'TEAMHUNT FAIL degrade send: %', r; end if;
  v_fleet2 := (r->>'fleet_id')::uuid; v_mv2 := (r->>'movement_id')::uuid;
  update public.main_ship_instances set captain_slots = 0, updated_at = now() where main_ship_id = b1;
  update public.fleet_movements
     set depart_at = now() - interval '2 minutes', arrive_at = now() - interval '1 minute'
   where id = v_mv2;
  r := public.movement_settle_arrival(v_mv2);
  if (r->>'settled')::boolean is not true or (r->>'outcome') is distinct from 'present' then
    raise exception 'TEAMHUNT FAIL: settle did NOT succeed despite the degraded member (cron-safety pin): %', r; end if;
  select id into v_enc2 from public.combat_encounters where fleet_id = v_fleet2 and status = 'active';
  if v_enc2 is null then raise exception 'TEAMHUNT FAIL degrade: no active encounter for the degraded sortie'; end if;
  -- the degraded member row: inserted (never skipped), dead-on-arrival, D1-CHECK-legal (snapshots 0).
  select count(*) into n from public.combat_units
    where encounter_id = v_enc2 and main_ship_id = b1 and unit_type_id is null
      and alive_count = 0 and attack_snapshot = 0 and defense_snapshot = 0 and hp_current = 0;
  if n <> 1 then raise exception 'TEAMHUNT FAIL degrade: b1 row not degraded (want alive_count=0 / zero snapshots / zero hp)'; end if;
  select count(*) into n from public.combat_encounters where id = v_enc2 and player_power_start = 0;
  if n <> 1 then raise exception 'TEAMHUNT FAIL degrade: degraded member leaked fighting power into power_start'; end if;
  -- the all-degraded zero-hp encounter settles as a clean DEFEAT on its first tick (existing machinery).
  update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc2;
  perform public.process_combat_ticks();
  select count(*) into n from public.combat_encounters where id = v_enc2 and status = 'defeat' and ended_at is not null;
  if n <> 1 then raise exception 'TEAMHUNT FAIL degrade: zero-hp encounter did not settle defeat'; end if;
  select count(*) into n from public.main_ship_instances
    where main_ship_id = b1 and status = 'destroyed' and hp = 0 and spatial_state is null;
  if n <> 1 then raise exception 'TEAMHUNT FAIL degrade: b1 not marked combat-destroyed by the D1 member loop'; end if;
  select count(*) into n from public.fleets where id = v_fleet2 and status = 'destroyed';
  if n <> 1 then raise exception 'TEAMHUNT FAIL degrade: sortie fleet not destroyed on defeat'; end if;

  raise notice 'TEAMCMD_PASS_TEAMHUNT ok: rejects (group_not_found×2/empty_group/invalid_location-before-readiness/member_not_ready incl. zero-hp), ONE fleet + 2-row manifest + hunting ships, speed_used = independent D0 totals.speed, races reject (single send + double team send), member encounter (attack_snapshot = per-member adapter, hp carries pre-existing damage, power_start = totals.combat_power), tick damage = sum(attack_snapshot) with ship-hp sync, manifest wins over a mid-flight unassign, and the H1 cron-safety degrade: settle succeeds despite an adapter-refused member, whose row lands alive_count=0/zero-snapshot and defeats cleanly';
end $$;

-- ════════ BLOCK SHARDDROP (captains launch, 0171): config-gated captain_memory_shard drop ════════
-- Migration 0171 re-created pirate_loot_for_wave (from its TRUE head, 0041 — the only create site)
-- with ONE marked hunk: from wave 2 onward a cleared wave rolls `random() < cfg
-- captain_shard_drop_rate` for exactly 1 captain_memory_shard (the packet-F5 recruit-economy
-- source). Direct-call pins at the knob's DETERMINISTIC endpoints (rate 0 → never, rate 1 →
-- always; the probabilistic middle is deliberately untested):
--   PARITY (rate 0, the committed 0171 seed) — output BYTE-IDENTICAL to the 0041 head, element
--            order included: wave 10 (all five legacy drops) and wave 1 (scrap only);
--   DROP (rate 1)      — a wave-2 bundle gains EXACTLY one shard qty 1, APPENDED after the legacy
--            elements (additive-only: bundle minus the shard == the legacy bundle);
--   THRESHOLD (rate 1) — wave 1 stays scrap-only at ANY rate (the wave >= 2 gate — the live
--            verify-phase5 `wave 1 → scrap only` exact pin must never go flaky post-flip);
--   DEEP SHAPE (rate 1) — wave 10 == the legacy bundle || the one shard.
-- The rate is then LEFT at 1 (in-txn only; ROLLBACK reverts) so TEAMSETTLE's real won encounter
-- below carries a shard END-TO-END through the unchanged bundle path.
do $$
declare v_legacy jsonb; v_got jsonb; n int;
begin
  -- the committed knob seed is 0 (dark) — the migration's inert-by-default posture.
  if (select value #>> '{}' from public.game_config where key = 'captain_shard_drop_rate') is distinct from '0' then
    raise exception 'SHARDDROP FAIL: committed captain_shard_drop_rate is % (want 0 — the 0171 dark seed)',
      (select value #>> '{}' from public.game_config where key = 'captain_shard_drop_rate'); end if;

  -- PARITY at rate 0: byte-identical to the proof's OWN independently-built 0041 bundle (the
  -- head's exact append order), deep wave and wave 1.
  v_legacy := jsonb_build_array(
    jsonb_build_object('item_id', 'scrap',        'quantity', 1),
    jsonb_build_object('item_id', 'pirate_alloy', 'quantity', 1),
    jsonb_build_object('item_id', 'weapon_parts', 'quantity', 1),
    jsonb_build_object('item_id', 'engine_parts', 'quantity', 1),
    jsonb_build_object('item_id', 'repair_parts', 'quantity', 1));
  v_got := public.pirate_loot_for_wave(10, 4);
  if v_got is distinct from v_legacy then
    raise exception 'SHARDDROP FAIL: rate-0 loot diverges from the legacy 0041 bundle: % vs %', v_got, v_legacy; end if;
  v_got := public.pirate_loot_for_wave(1, 1);
  if v_got is distinct from jsonb_build_array(jsonb_build_object('item_id', 'scrap', 'quantity', 1)) then
    raise exception 'SHARDDROP FAIL: rate-0 wave-1 loot is not scrap-only: %', v_got; end if;

  -- DROP at rate 1 (the real set_game_config; reverted by ROLLBACK): wave 2 gains EXACTLY one
  -- shard qty 1, appended LAST (additive-only over the legacy wave-2 bundle = scrap alone).
  perform public.set_game_config('captain_shard_drop_rate', '1'::jsonb);
  v_got := public.pirate_loot_for_wave(2, 1);
  select count(*) into n from jsonb_array_elements(v_got) e
    where e->>'item_id' = 'captain_memory_shard' and (e->>'quantity')::int = 1;
  if n <> 1 then
    raise exception 'SHARDDROP FAIL: rate-1 wave-2 loot has % shard elements (want exactly 1, qty 1): %', n, v_got; end if;
  if v_got->(jsonb_array_length(v_got) - 1)->>'item_id' is distinct from 'captain_memory_shard' then
    raise exception 'SHARDDROP FAIL: the shard is not appended after the legacy elements: %', v_got; end if;
  if v_got - (jsonb_array_length(v_got) - 1) is distinct from jsonb_build_array(jsonb_build_object('item_id', 'scrap', 'quantity', 1)) then
    raise exception 'SHARDDROP FAIL: rate-1 wave-2 bundle minus the shard is not the legacy bundle: %', v_got; end if;

  -- THRESHOLD at rate 1: wave 1 STILL scrap-only (the wave >= 2 gate holds at any rate).
  v_got := public.pirate_loot_for_wave(1, 1);
  if v_got is distinct from jsonb_build_array(jsonb_build_object('item_id', 'scrap', 'quantity', 1)) then
    raise exception 'SHARDDROP FAIL: rate-1 wave-1 loot is not scrap-only (threshold breach): %', v_got; end if;

  -- DEEP SHAPE at rate 1: the full legacy bundle plus the one appended shard, nothing else.
  v_got := public.pirate_loot_for_wave(10, 4);
  if v_got is distinct from (v_legacy || jsonb_build_object('item_id', 'captain_memory_shard', 'quantity', 1)) then
    raise exception 'SHARDDROP FAIL: rate-1 wave-10 bundle wrong: %', v_got; end if;

  raise notice 'TEAMCMD_PASS_SHARDDROP ok: committed seed 0 (dark); rate-0 byte-parity with the 0041 bundle (wave 10 + wave 1); rate-1 wave-2 gains exactly one appended shard (additive-only); wave-1 threshold holds at any rate; rate left 1 in-txn for the TEAMSETTLE end-to-end carry';
end $$;

-- ════════ BLOCK TEAMSETTLE (Slice D3, 0169): sortie settle — members return, reconcile home, M1 ════════
-- Closes the member lifecycle loop over TEAMHUNT's still-LIVE sortie (uC's active encounter: c1,c2
-- 'hunting', fleet 'present') plus a fresh loss sortie. Pins:
--   RACE (mid-combat)  — process_mainship_expeditions must NOT touch a member while the manifest
--                        fleet is 'present' (the exact-complement predicate);
--   ESCAPE             — request_retreat works VERBATIM on the team encounter (presence-addressed,
--                        owner-checked — nothing team-shaped on the retreat path); the escape tick
--                        writes a member-keyed report, a return_home movement whose speed_used ==
--                        the proof's OWN independent min member HULL base_speed while fleet_speed is
--                        NULL (so the tick's coalesce provably took the D1 member fallback), attaches
--                        the accrued reward bundle, and — THE D3 DELTA — marks the surviving members
--                        'returning' (spatial_state NULL pair-shape) with their combat damage
--                        persisted on the ship rows;
--   RACE (in transit)  — the reconciler must NOT yank a 'returning' member home while the fleet is
--                        still 'returning' (the D3 legacy-branch guard);
--   RETURN SETTLE      — movement_settle_arrival's base branch completes the fleet and deposits the
--                        carried bundle (reward_grants row keyed by the encounter; base_resources
--                        metal grows by exactly the carried metal; the 0171 wave-2 shard lands in
--                        player_inventory — the SHARDDROP end-to-end carry), touching NO member ship;
--   RECONCILE          — the next reconciler run re-homes both members in the head branch's exact
--                        write shape (status='home', spatial_state stays NULL — the clean
--                        legacy_home) with damage persisted; the manifest rows are RETAINED (the D3
--                        retention decision — they die with their fleet via 0047's retention cascade,
--                        never via the reconciler);
--   LOSS + RECOVERY    — a fresh sortie under a one-step-wipe enemy (enemy_attack_base surgery,
--                        restored after) defeats with REAL alive members (TEAMHUNT's defeat covered
--                        only the degraded shape): fleet destroyed, members 'destroyed' hp=0 by the
--                        D1 loop, defeat report; then the 0081 ship-addressed repair_main_ship
--                        revives a member to home @ max_hp;
--   M1 GUARD           — a true interleaving is untestable in one session, so pin the guard's
--                        contract: a 'hunting' ship rejects through the single send's own
--                        not-available raise and is NOT moved (no lost update), and a legal single
--                        send afterwards is intact (parity for non-racing callers);
--   SELF-HEAL          — a manufactured 'returning' and a manufactured 'hunting' ship whose manifest
--                        fleets are all finished are re-homed by the reconciler (never destroyed).
-- Fixture surgery stays inside the quarantined kinds: clock rewinds, config via the real
-- set_game_config, and main_ship_instances status surgery (the provisioning idiom). The manifest is
-- never touched directly (sole-writer law, grep-enforced).
do $$
declare r jsonb; n int; i int; v_err text;
  uC uuid := (select v from tcmd where k='uC');
  c1 uuid := (select v from tcmd where k='c1'); c2 uuid := (select v from tcmd where k='c2');
  slag uuid := (select v from tcmd where k='slag');
  gH uuid; v_hunt uuid; v_fleet uuid; v_enc uuid; v_pres uuid; v_rmv uuid;
  v_fleet3 uuid; v_mv3 uuid; v_enc3 uuid;
  v_rw jsonb; v_minspeed double precision; v_cbase uuid; v_metal_before double precision;
  v_shard_before integer;
  v_hp1 integer; v_hp2 integer;
begin
  -- config surgery re-applied (idempotent; the real set_game_config; all reverted by ROLLBACK).
  perform public.set_game_config('combat_tick_logging', 'true'::jsonb);
  perform public.set_game_config('combat_damage_variance_pct', '0'::jsonb);

  select id into v_hunt from public.locations
    where activity_type = 'hunt_pirates' and status = 'active'
    order by min_power_required asc, base_difficulty asc limit 1;

  -- reuse TEAMHUNT's LIVE sortie: uC's one active encounter (c1,c2 'hunting', fleet 'present').
  select ce.id, ce.presence_id, ce.fleet_id into v_enc, v_pres, v_fleet
    from public.combat_encounters ce join public.fleets f on f.id = ce.fleet_id
    where f.player_id = uC and ce.status = 'active';
  if v_enc is null then raise exception 'TEAMSETTLE FAIL: no live uC sortie to reuse'; end if;
  select group_id into gH from public.fleets where id = v_fleet;
  select count(*) into n from public.fleets where id = v_fleet and status = 'present';
  if n <> 1 then raise exception 'TEAMSETTLE FAIL precondition: sortie fleet not present'; end if;

  -- ── RACE PIN (mid-combat): the reconciler must not touch members of a 'present' manifest fleet.
  perform public.process_mainship_expeditions();
  select count(*) into n from public.main_ship_instances
    where main_ship_id in (c1, c2) and status = 'hunting';
  if n <> 2 then raise exception 'TEAMSETTLE FAIL: reconciler touched a mid-combat member (race guard): % hunting (want 2)', n; end if;

  -- ── accrue a reward: tick until TWO waves clear (variance 0; bounded). Two, not one, since the
  -- SHARDDROP block left captain_shard_drop_rate at 1 and the 0171 drop starts at wave 2 — the won
  -- bundle must carry a shard for the end-to-end deposit pin below. Each tick needs a
  -- last_resolved_at rewind, and the wave-2 spawn needs a next_wave_at rewind too, because now()
  -- is txn-constant (the SHARDDROP-era extension of the same clock-rewind fixture kind).
  for i in 1..60 loop
    select total_rewards_json into v_rw from public.combat_encounters where id = v_enc;
    exit when v_rw is not null and v_rw <> '{}'::jsonb
          and (select waves_cleared from public.combat_encounters where id = v_enc) >= 2;
    update public.combat_encounters
       set last_resolved_at = last_resolved_at - interval '1 minute',
           next_wave_at     = next_wave_at - interval '1 minute'
     where id = v_enc;
    perform public.process_combat_ticks();
  end loop;
  if v_rw is null or v_rw = '{}'::jsonb
     or (select waves_cleared from public.combat_encounters where id = v_enc) < 2 then
    raise exception 'TEAMSETTLE FAIL: two waves not cleared in 60 ticks (rewards %)', v_rw; end if;
  -- THE 0171 SHARD CARRY: at rate 1 the wave-2 clear must have merged EXACTLY one shard element
  -- (qty 1 — wave 1 contributes none, the threshold) into the pending bundle.
  select count(*) into n from jsonb_array_elements(v_rw->'items') e
    where e->>'item_id' = 'captain_memory_shard' and (e->>'quantity')::int = 1;
  if n <> 1 then
    raise exception 'TEAMSETTLE FAIL: won bundle carries % shard elements (want exactly 1 — the 0171 drop at rate 1): %', n, v_rw; end if;
  select count(*) into n from public.combat_units where encounter_id = v_enc and alive_count > 0;
  if n <> 2 then raise exception 'TEAMSETTLE FAIL: % members alive before retreat (want 2)', n; end if;

  -- independent return speed: min member HULL base_speed over the MANIFEST (the exact D1 leaf
  -- semantics) — and fleet_speed must be NULL (no fleet_units), so the tick's coalesce can only
  -- have taken the member fallback.
  select min(h.base_speed)::double precision into v_minspeed
    from public.group_sortie_members gsm
    join public.main_ship_instances msi on msi.main_ship_id = gsm.main_ship_id
    join public.main_ship_hull_types h on h.hull_type_id = msi.hull_type_id
    where gsm.fleet_id = v_fleet;
  if public.fleet_speed(v_fleet) is not null then
    raise exception 'TEAMSETTLE FAIL: fleet_speed not NULL for the member fleet'; end if;

  -- ── RETREAT (the verbatim pin) + escape settle (retreat-clock rewind, the COMBATPARITY idiom).
  r := pg_temp.call_as(uC, format('public.request_retreat(%L::uuid)', v_pres));
  select count(*) into n from public.combat_encounters
    where id = v_enc and status = 'retreating' and retreat_started_at is not null;
  if n <> 1 then raise exception 'TEAMSETTLE FAIL: request_retreat did not arm the team encounter'; end if;
  update public.combat_encounters
     set retreat_started_at = retreat_started_at - interval '1 minute',
         last_resolved_at   = last_resolved_at   - interval '1 minute'
   where id = v_enc;
  perform public.process_combat_ticks();

  select count(*) into n from public.combat_encounters where id = v_enc and status = 'escaped' and ended_at is not null;
  if n <> 1 then raise exception 'TEAMSETTLE FAIL: encounter did not settle escaped'; end if;
  -- member-keyed report (every survivor key is a manifest ship id).
  select count(*) into n from public.combat_reports where encounter_id = v_enc and result = 'escaped';
  if n <> 1 then raise exception 'TEAMSETTLE FAIL: no escaped team report'; end if;
  select count(*) into n from public.combat_reports cr, jsonb_object_keys(cr.survivors_json) k
    where cr.encounter_id = v_enc and k not in (c1::text, c2::text);
  if n <> 0 then raise exception 'TEAMSETTLE FAIL: non-member survivor key in the team report'; end if;
  -- return movement: member hull speed + the accrued bundle attached.
  select id into v_rmv from public.fleet_movements
    where fleet_id = v_fleet and mission_type = 'return_home' and status = 'moving';
  if v_rmv is null then raise exception 'TEAMSETTLE FAIL: no return_home movement for the escaped sortie'; end if;
  select count(*) into n from public.fleet_movements
    where id = v_rmv and speed_used is not distinct from v_minspeed
      and reward_grant_source = v_enc and reward_payload_json = v_rw;
  if n <> 1 then raise exception 'TEAMSETTLE FAIL: return movement wrong (want speed_used = independent min member hull speed % + the attached bundle)', v_minspeed; end if;

  -- THE D3 DELTA: surviving members are 'returning' (pair-shape) with combat damage persisted.
  select count(*) into n from public.main_ship_instances
    where main_ship_id in (c1, c2) and status = 'returning' and spatial_state is null;
  if n <> 2 then raise exception 'TEAMSETTLE FAIL: % members returning after escape (want 2 — the D3 tick delta)', n; end if;
  select count(*) into n from public.combat_units cu
    join public.main_ship_instances msi on msi.main_ship_id = cu.main_ship_id
    where cu.encounter_id = v_enc and msi.hp = round(greatest(0, cu.hp_current))::integer and msi.hp < msi.max_hp;
  if n <> 2 then raise exception 'TEAMSETTLE FAIL: member damage not persisted onto the ship rows'; end if;

  -- ── RACE PIN (in transit home): fleet 'returning' is a LIVE manifest state — the reconciler must
  -- leave the members alone (the D3 legacy-branch guard; the head branch would yank them home).
  perform public.process_mainship_expeditions();
  select count(*) into n from public.main_ship_instances
    where main_ship_id in (c1, c2) and status = 'returning';
  if n <> 2 then raise exception 'TEAMSETTLE FAIL: reconciler yanked a returning member home mid-flight (guard breach): % returning (want 2)', n; end if;

  -- ── settle the return (the SAME per-movement settle the cron loop calls; base branch).
  select id into v_cbase from public.bases where player_id = uC and status = 'active' order by created_at limit 1;
  select coalesce((select amount from public.base_resources where base_id = v_cbase and resource_code = 'metal'), 0)
    into v_metal_before;
  v_shard_before := public.inventory_get_balance(uC, 'captain_memory_shard');
  update public.fleet_movements
     set depart_at = now() - interval '2 minutes', arrive_at = now() - interval '1 minute'
   where id = v_rmv;
  r := public.movement_settle_arrival(v_rmv);
  if (r->>'settled')::boolean is not true or (r->>'outcome') is distinct from 'completed' then
    raise exception 'TEAMSETTLE FAIL return settle: %', r; end if;
  select count(*) into n from public.fleets where id = v_fleet and status = 'completed';
  if n <> 1 then raise exception 'TEAMSETTLE FAIL: sortie fleet not completed after the return settle'; end if;
  -- the deposit landed: ONE reward_grants row keyed by the encounter, and the base metal store grew
  -- by exactly the carried metal (reward_grant → base_add_resources — the read deposit path).
  select count(*) into n from public.reward_grants where source_type = 'combat' and source_id = v_enc;
  if n <> 1 then raise exception 'TEAMSETTLE FAIL: reward not granted from the sortie encounter'; end if;
  select count(*) into n from public.base_resources
    where base_id = v_cbase and resource_code = 'metal'
      and amount is not distinct from v_metal_before + (v_rw->>'metal')::double precision;
  if n <> 1 then raise exception 'TEAMSETTLE FAIL: base metal did not grow by the carried reward metal'; end if;
  -- THE 0171 SHARD DEPOSIT: the carried shard landed in player_inventory (reward_grant's item
  -- path) — the recruit currency (0125: every recipe costs exactly 1 shard) really arrives.
  if public.inventory_get_balance(uC, 'captain_memory_shard') is distinct from v_shard_before + 1 then
    raise exception 'TEAMSETTLE FAIL: carried shard not deposited to player_inventory (have %, want % — the recruit currency)',
      public.inventory_get_balance(uC, 'captain_memory_shard'), v_shard_before + 1; end if;
  -- the base settle itself never touches member ships (untagged fleet): still 'returning'.
  select count(*) into n from public.main_ship_instances
    where main_ship_id in (c1, c2) and status = 'returning';
  if n <> 2 then raise exception 'TEAMSETTLE FAIL: return settle unexpectedly touched member ships'; end if;

  -- ── RECONCILE HOME: manifest fleet finished → both members home in the head write shape
  -- (status='home', spatial_state stays NULL — the clean legacy_home), damage persisted.
  select hp into v_hp1 from public.main_ship_instances where main_ship_id = c1;
  select hp into v_hp2 from public.main_ship_instances where main_ship_id = c2;
  perform public.process_mainship_expeditions();
  select count(*) into n from public.main_ship_instances
    where main_ship_id in (c1, c2) and status = 'home' and spatial_state is null;
  if n <> 2 then raise exception 'TEAMSETTLE FAIL: % members re-homed (want 2 home/legacy-shape after the reconciler)', n; end if;
  select count(*) into n from public.main_ship_instances
    where (main_ship_id = c1 and hp = v_hp1) or (main_ship_id = c2 and hp = v_hp2);
  if n <> 2 then raise exception 'TEAMSETTLE FAIL: reconcile changed member hp (damage must persist)'; end if;
  -- manifest RETAINED (the D3 retention decision): rows die with their fleet via 0047's retention
  -- cascade, never via the reconciler (sole-writer law) — still 2 rows for the completed sortie.
  select count(*) into n from public.group_sortie_members where fleet_id = v_fleet;
  if n <> 2 then raise exception 'TEAMSETTLE FAIL: % manifest rows for the completed sortie (want 2 retained)', n; end if;

  -- ── LOSS + RECOVERY: fresh sortie (c1 rejoins the team), enemy boosted to a one-step wipe — the
  -- REAL alive-member defeat (TEAMHUNT's defeat covered only the degraded shape).
  r := pg_temp.call_as(uC, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', c1, gH));
  if (r->>'ok')::boolean is not true then raise exception 'TEAMSETTLE FAIL loss reassign: %', r; end if;
  r := pg_temp.call_as(uC, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gH, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'TEAMSETTLE FAIL loss send: %', r; end if;
  v_fleet3 := (r->>'fleet_id')::uuid; v_mv3 := (r->>'movement_id')::uuid;
  update public.fleet_movements
     set depart_at = now() - interval '2 minutes', arrive_at = now() - interval '1 minute'
   where id = v_mv3;
  r := public.movement_settle_arrival(v_mv3);
  if (r->>'settled')::boolean is not true then raise exception 'TEAMSETTLE FAIL loss settle: %', r; end if;
  select id into v_enc3 from public.combat_encounters where fleet_id = v_fleet3 and status = 'active';
  if v_enc3 is null then raise exception 'TEAMSETTLE FAIL loss: no active encounter'; end if;
  perform public.set_game_config('enemy_attack_base', '1000000'::jsonb);   -- one-step roster wipe
  update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc3;
  perform public.process_combat_ticks();
  perform public.set_game_config('enemy_attack_base', '1'::jsonb);         -- restore the engine default
  select count(*) into n from public.combat_encounters where id = v_enc3 and status = 'defeat' and ended_at is not null;
  if n <> 1 then raise exception 'TEAMSETTLE FAIL loss: encounter did not defeat under the boosted enemy'; end if;
  select count(*) into n from public.fleets where id = v_fleet3 and status = 'destroyed';
  if n <> 1 then raise exception 'TEAMSETTLE FAIL loss: sortie fleet not destroyed'; end if;
  select count(*) into n from public.main_ship_instances
    where main_ship_id in (c1, c2) and status = 'destroyed' and hp = 0 and spatial_state is null;
  if n <> 2 then raise exception 'TEAMSETTLE FAIL loss: members not combat-destroyed by the D1 loop'; end if;
  select count(*) into n from public.combat_reports where encounter_id = v_enc3 and result = 'defeat';
  if n <> 1 then raise exception 'TEAMSETTLE FAIL loss: no defeat report'; end if;
  -- RECOVERY PIN: the 0081 ship-addressed repair revives a combat-destroyed member.
  r := pg_temp.call_as(uC, format('public.repair_main_ship(%L::uuid)', c1));
  select count(*) into n from public.main_ship_instances
    where main_ship_id = c1 and status = 'home' and hp = max_hp and spatial_state is null;
  if n <> 1 then raise exception 'TEAMSETTLE FAIL: repair did not revive the destroyed member (want home @ max_hp)'; end if;

  -- ── M1 GUARD PIN: interleaving is untestable in one session — pin the guard's contract instead:
  -- a 'hunting' ship rejects through the send's own not-available raise (never a lost update), and
  -- a legal single send afterwards still works (parity for non-racing callers).
  update public.main_ship_instances
     set status = 'hunting', spatial_state = null, space_x = null, space_y = null, updated_at = now()
   where main_ship_id = c1;
  begin
    r := pg_temp.call_as(uC, format('public.send_main_ship_expedition(%L::jsonb, %L::uuid)', jsonb_build_array(c1), slag));
    raise exception 'TEAMSETTLE FAIL: live single send ACCEPTED a hunting ship (M1): %', r;
  exception when others then
    v_err := sqlerrm;
    if v_err not like '%not available (status hunting)%' then
      raise exception 'TEAMSETTLE FAIL: M1 hunting-reject raised the wrong error: %', v_err; end if;
  end;
  select count(*) into n from public.main_ship_instances where main_ship_id = c1 and status = 'hunting';
  if n <> 1 then raise exception 'TEAMSETTLE FAIL: the rejected single send moved the hunting ship (lost update)'; end if;
  update public.main_ship_instances set status = 'home', updated_at = now() where main_ship_id = c1;
  r := pg_temp.call_as(uC, format('public.send_main_ship_expedition(%L::jsonb, %L::uuid)', jsonb_build_array(c1), slag));
  if (r->>'movement_id') is null then raise exception 'TEAMSETTLE FAIL: legal single send broken by the M1 fix: %', r; end if;
  select count(*) into n from public.main_ship_instances
    where main_ship_id = c1 and status = 'traveling' and spatial_state is null;
  if n <> 1 then raise exception 'TEAMSETTLE FAIL: legal single send did not put the ship in flight'; end if;

  -- ── SELF-HEAL PIN: manufactured partial states (fixture surgery) whose manifest fleets are ALL
  -- finished (v_fleet completed / v_fleet3 destroyed) → the reconciler re-homes; never destroys.
  r := pg_temp.call_as(uC, format('public.repair_main_ship(%L::uuid)', c2));
  update public.main_ship_instances
     set status = 'returning', spatial_state = null, space_x = null, space_y = null, updated_at = now()
   where main_ship_id = c2;
  perform public.process_mainship_expeditions();
  select count(*) into n from public.main_ship_instances
    where main_ship_id = c2 and status = 'home' and spatial_state is null;
  if n <> 1 then raise exception 'TEAMSETTLE FAIL: self-heal did not re-home the orphaned returning member'; end if;
  update public.main_ship_instances
     set status = 'hunting', spatial_state = null, space_x = null, space_y = null, updated_at = now()
   where main_ship_id = c2;
  perform public.process_mainship_expeditions();
  select count(*) into n from public.main_ship_instances
    where main_ship_id = c2 and status = 'home' and spatial_state is null;
  if n <> 1 then raise exception 'TEAMSETTLE FAIL: self-heal did not re-home the orphaned hunting member'; end if;

  raise notice 'TEAMCMD_PASS_TEAMSETTLE ok: mid-combat + in-transit reconciler race guards, verbatim team retreat, escape marks survivors returning (member hull speed, member-keyed report, damage persisted), return settle deposits the bundle (metal + the 0171 wave-2 shard into player_inventory), reconciler re-homes in the legacy shape with the manifest retained, real-member defeat + repair revival, M1 hunting-reject without a lost update + legal single-send parity, and both self-heal re-homes';
end $$;

-- ════════ BLOCK CAPXP (CAPXP-0/1, 0177): captain-XP foundation — dark no-op, exact accrual, ledger ════════
-- Consumes the TEAMSETTLE fixture AS the captained team sortie the 0177 charter names: the settled
-- uC sortie deposited ONE finalized combat reward_grants row whose manifest is {c1, c2}, and the
-- TEAMHUNT captain roster is STILL ASSIGNED NOW (capa+capb on c1, capc on c2, capd on the grantless
-- b1 — all provisioned via the 0118/0119 sole writers). The 0177 accrual credits captains assigned
-- AT ACCRUAL TIME (the documented current-assignment semantic — captain-at-sortie-time is recorded
-- nowhere), so this roster is exactly the credit set. Fixture surgery stays inside the sanctioned
-- kinds: config via the real set_game_config, captains via the sole writers, and the one orphan
-- grant via the REAL Reward sole writer reward_grant() — never a direct insert into any
-- Captain-owned or ledger table (grep-enforced).
do $$
declare r jsonb; n int;
begin
  -- committed seeds (nothing in-txn has touched these keys): the flag is dark, the knob at seed.
  if (select value #>> '{}' from public.game_config where key = 'captain_growth_enabled') is distinct from 'false' then
    raise exception 'CAPXP FAIL: committed captain_growth_enabled is % (want ''false'' — the 0177 dark seed)',
      (select value #>> '{}' from public.game_config where key = 'captain_growth_enabled'); end if;
  if (select value #>> '{}' from public.game_config where key = 'captain_xp_per_combat_grant') is distinct from '10' then
    raise exception 'CAPXP FAIL: committed captain_xp_per_combat_grant is % (want 10 — the 0177 knob seed)',
      (select value #>> '{}' from public.game_config where key = 'captain_xp_per_combat_grant'); end if;

  -- additive defaults: every instance (the C0/D0/D2 fixtures included) sits at xp 0 / level 1.
  select count(*) into n from public.captain_instances where xp <> 0 or level <> 1;
  if n <> 0 then raise exception 'CAPXP FAIL: % instance(s) off the additive defaults before accrual (want 0)', n; end if;

  -- DARK NO-OP (asserted BEFORE the flag flip below): reject-before-read envelope, ZERO writes —
  -- finalized grants already exist at this point, so a gate-after-read regression would fold them.
  r := public.captain_xp_accrue();
  if (r->>'ok')::boolean is not false or (r->>'code') is distinct from 'feature_disabled' then
    raise exception 'CAPXP FAIL dark: %', r; end if;
  select count(*) into n from public.captain_counted_grants;
  if n <> 0 then raise exception 'CAPXP FAIL: dark run left % ledger row(s) (want 0)', n; end if;
  select count(*) into n from public.captain_instances where xp <> 0 or level <> 1;
  if n <> 0 then raise exception 'CAPXP FAIL: dark run moved xp/level on % instance(s) (want 0)', n; end if;
end $$;

-- light captain growth ONLY inside this rolled-back txn (the committed/production value stays false).
update public.game_config set value='true'::jsonb where key='captain_growth_enabled';

do $$
declare r jsonb; r2 jsonb; n int;
  uC uuid := (select v from tcmd where k='uC');
  c1 uuid := (select v from tcmd where k='c1'); c2 uuid := (select v from tcmd where k='c2');
  b1 uuid := (select v from tcmd where k='b1');
  v_grant uuid; v_capu uuid; v_knob numeric; v_total numeric;
begin
  -- ── fixture facts, derived independently (precondition-pinned so the arithmetic is airtight) ─────
  -- exactly ONE finalized grant exists (the TEAMSETTLE deposit)…
  select count(*) into n from public.reward_grants;
  if n <> 1 then raise exception 'CAPXP FAIL precondition: % reward_grants rows (want exactly 1 — the TEAMSETTLE deposit)', n; end if;
  select rg.id into v_grant from public.reward_grants rg where rg.source_type = 'combat';
  -- …its sortie manifest is exactly {c1, c2}…
  select count(*) into n from public.group_sortie_members gsm
    join public.combat_encounters ce on ce.fleet_id = gsm.fleet_id
    where ce.id = (select source_id from public.reward_grants where id = v_grant)
      and gsm.main_ship_id in (c1, c2);
  if n <> 2 then raise exception 'CAPXP FAIL precondition: the grant manifest is not {c1, c2} (matched %)', n; end if;
  -- …and the TEAMHUNT roster is still assigned NOW: 2 captains on c1, 1 on c2, 1 on the grantless b1.
  select count(*) into n from public.ship_captain_assignments where main_ship_id = c1;
  if n <> 2 then raise exception 'CAPXP FAIL precondition: % captain(s) on c1 (want 2)', n; end if;
  select count(*) into n from public.ship_captain_assignments where main_ship_id in (c2, b1);
  if n <> 2 then raise exception 'CAPXP FAIL precondition: % captain(s) on c2+b1 (want 1+1)', n; end if;

  -- controls: a freshly-minted UNASSIGNED captain (the sole writer, as everywhere), and an ORPHAN
  -- grant via the REAL Reward sole writer (random source_id = the retention-cleaned-encounter
  -- shape: no encounter row, no derivable ship — must be consumed as a sentinel, never credited).
  v_capu := public.captains_mint_instance(uC, 'gunnery_veteran', 'tcmd-capxp-u');
  perform public.reward_grant('combat', gen_random_uuid(), uC, null, '{"metal": 1}'::jsonb);
  select count(*) into n from public.reward_grants;
  if n <> 2 then raise exception 'CAPXP FAIL: the orphan grant was not minted via reward_grant (% rows, want 2)', n; end if;

  -- the boundary knob: 100 is EXACTLY the level-2 threshold of the [D] curve (level = 1 +
  -- floor(sqrt(xp/100)): 99 xp stays level 1, 100 lands level 2) — raised via the real
  -- set_game_config (in-txn only; ROLLBACK reverts; the committed seed 10 was pinned above).
  perform public.set_game_config('captain_xp_per_combat_grant', '100'::jsonb);
  v_knob := public.cfg_num('captain_xp_per_combat_grant');

  -- ── THE ACCRUAL ───────────────────────────────────────────────────────────────────────────────────
  r := public.captain_xp_accrue();
  if (r->>'ok')::boolean is not true then raise exception 'CAPXP FAIL accrue: %', r; end if;
  -- envelope: BOTH grants consumed (the sortie grant + the orphan), 3 credit rows over 3 captains.
  if (r->>'grants_consumed')::int is distinct from 2
     or (r->>'credits_inserted')::int is distinct from 3
     or (r->>'captains_credited')::int is distinct from 3
     or (r->>'xp_awarded')::numeric is distinct from 3 * v_knob then
    raise exception 'CAPXP FAIL: accrual envelope wrong (want 2 grants / 3 credits / 3 captains / % xp): %', 3 * v_knob, r; end if;

  -- every currently-assigned manifest captain gained EXACTLY the knob amount × its 1 qualifying
  -- grant — one grant feeds multiple captains (2 on c1 + 1 on c2), the per-(grant, captain) keying…
  select count(*) into n from public.ship_captain_assignments sca
    join public.captain_instances ci on ci.id = sca.captain_instance_id
    where sca.main_ship_id in (c1, c2) and ci.xp = v_knob;
  if n <> 3 then
    raise exception 'CAPXP FAIL: % manifest captain(s) at xp % (want exactly the knob 100 × 1 qualifying grant on all 3)', n, v_knob; end if;
  -- …and each landed level EXACTLY 2 at the 100-xp boundary (a >=-vs-> slip in the curve → 1).
  select count(*) into n from public.ship_captain_assignments sca
    join public.captain_instances ci on ci.id = sca.captain_instance_id
    where sca.main_ship_id in (c1, c2) and ci.level = 2;
  if n <> 3 then
    raise exception 'CAPXP FAIL: % manifest captain(s) at level 2 at the 100-xp boundary (want all 3 exactly 2)', n; end if;

  -- a captain on a GRANTLESS ship gains nothing (b1's only sortie was a defeat — no grant)…
  select count(*) into n from public.ship_captain_assignments sca
    join public.captain_instances ci on ci.id = sca.captain_instance_id
    where sca.main_ship_id = b1 and ci.xp = 0 and ci.level = 1;
  if n <> 1 then raise exception 'CAPXP FAIL: the grantless-ship captain moved (want xp 0 / level 1)'; end if;
  -- …and the UNASSIGNED captain gains nothing at all (no xp, no ledger row).
  select count(*) into n from public.captain_instances where id = v_capu and xp = 0 and level = 1;
  if n <> 1 then raise exception 'CAPXP FAIL: the unassigned captain gained xp'; end if;
  select count(*) into n from public.captain_counted_grants where captain_instance_id = v_capu;
  if n <> 0 then raise exception 'CAPXP FAIL: the unassigned captain has % ledger row(s) (want 0)', n; end if;

  -- LEDGER SHAPE: 3 credit rows for the sortie grant (each xp = knob, the linked ship recorded) +
  -- exactly 1 NULL-captain sentinel for the orphan — 4 rows total, zero grants left unconsumed.
  select count(*) into n from public.captain_counted_grants
    where grant_id = v_grant and captain_instance_id is not null
      and xp = v_knob and main_ship_id in (c1, c2) and source_type = 'combat';
  if n <> 3 then raise exception 'CAPXP FAIL: % credit row(s) for the sortie grant (want 3 — one per assigned manifest captain)', n; end if;
  select count(*) into n from public.captain_counted_grants
    where grant_id <> v_grant and captain_instance_id is null and main_ship_id is null and xp = 0;
  if n <> 1 then raise exception 'CAPXP FAIL: % orphan sentinel row(s) (want 1 sentinel row — consumed, never credited)', n; end if;
  select count(*) into n from public.captain_counted_grants;
  if n <> 4 then raise exception 'CAPXP FAIL: % total ledger row(s) (want 4)', n; end if;
  select count(*) into n from public.reward_grants rg
    where not exists (select 1 from public.captain_counted_grants c where c.grant_id = rg.id);
  if n <> 0 then raise exception 'CAPXP FAIL: % grants left unconsumed after the run (want 0)', n; end if;

  -- CURVE COHERENCE, recomputed independently over EVERY instance (the maintained level column may
  -- never drift from the [D] formula).
  select count(*) into n from public.captain_instances
    where level <> 1 + floor(sqrt(xp / 100.0))::integer;
  if n <> 0 then raise exception 'CAPXP FAIL: % instance(s) where level <> 1 + floor(sqrt(xp / 100)) (curve drift)', n; end if;

  -- THE ANTI-JOIN PIN: a re-run consumes/credits/awards ZERO — no double count, ledger unchanged.
  r2 := public.captain_xp_accrue();
  if (r2->>'ok')::boolean is not true
     or (r2->>'grants_consumed')::int is distinct from 0
     or (r2->>'credits_inserted')::int is distinct from 0
     or (r2->>'xp_awarded')::numeric is distinct from 0 then
    raise exception 'CAPXP FAIL: re-run double-counted (want all-zero envelope): %', r2; end if;
  select count(*) into n from public.captain_counted_grants;
  if n <> 4 then raise exception 'CAPXP FAIL: re-run grew the ledger to % row(s) (want still 4)', n; end if;
  select coalesce(sum(xp), 0) into v_total from public.captain_instances;
  if v_total is distinct from 3 * v_knob then
    raise exception 'CAPXP FAIL: re-run moved total xp to % (want still %)', v_total, 3 * v_knob; end if;

  raise notice 'TEAMCMD_PASS_CAPXP ok: committed seeds dark (flag false, knob 10); additive defaults; dark accrue = clean no-op with grants present; lit accrue credits the 3 currently-assigned manifest captains exactly knob×1 grant each (xp 100 → level exactly 2 at the boundary), per-(grant, captain) ledger + 1 orphan sentinel, zero grants unconsumed; grantless-ship + unassigned captains untouched; curve recomputed clean over every instance; re-run = all-zero envelope, no double count';
end $$;

-- ════════ BLOCK CAPLEVEL (C2-2, 0180): the captain level fold — exact lit bonus + DOUBLE inertness ════════
-- Consumes the CAPXP outcome AS the level-2 fixture: capa+capb (gunnery_veteran, attack 4 each)
-- sit on c1 at EXACTLY level 2 (the 100-xp boundary), capd sits on the grantless b1 at level 1,
-- and captain_growth_enabled is TRUE in-txn (the flip above CAPXP). RECONCILIATION (checked at
-- C2-2 time): NO earlier block calls the adapter after that flip or after the accrual moved any
-- level — every adapter-pinned block (HULLSTATS/CAPTAINS/TEAMSTATS/TEAMHUNT/…) runs dark at level
-- 1, where the 0180 multiplier is exactly 1.0 twice over, so every existing pin stays byte-valid
-- unreconciled. This block pins the delta itself, all expectations derived INDEPENDENTLY from the
-- catalog/instance joins (the TEAMSTATS independent-sum style — never the adapter's own math):
--   (1) LIT + LEVEL 2: c1's combat_power EXCEEDS the level-1 baseline by exactly
--       round(knob × Σ(level-1)×attack, 2) — with hull 15 + 2×4 captains at knob 0.10: 23 → 23.8 —
--       and NO other stat key moves (gunnery seeds carry attack only; tradeoffs stay level-flat);
--   (2) FLAG OFF + LEVEL 2 → the baseline EXACTLY: dark c1 answers hull attack + Σ captain attack
--       (the level-1 world absolute — the first inertness arm);
--   (3) FLAG ON + LEVEL 1 → the baseline EXACTLY: b1 (single level-1 captain) answers
--       byte-identically lit or dark (the second inertness arm).
-- Flag toggles are in-txn only (rolled back); the committed knob seed is pinned untouched first.
do $$
declare s_on jsonb; s_off jsonb; b_on jsonb; b_off jsonb; n int;
  uC uuid := (select v from tcmd where k='uC'); uB uuid := (select v from tcmd where k='uB');
  c1 uuid := (select v from tcmd where k='c1'); b1 uuid := (select v from tcmd where k='b1');
  v_knob numeric; v_hull numeric; v_cap numeric; v_lvl numeric;
begin
  -- committed seed (nothing in-txn has touched this key): the 0180 knob at 0.10.
  if (select value #>> '{}' from public.game_config where key = 'captain_level_bonus_per_level') is distinct from '0.10' then
    raise exception 'CAPLEVEL FAIL: committed captain_level_bonus_per_level is % (want ''0.10'' — the 0180 knob seed)',
      (select value #>> '{}' from public.game_config where key = 'captain_level_bonus_per_level'); end if;
  v_knob := public.cfg_num('captain_level_bonus_per_level');

  -- FIXTURE REPAIR (CI 2026-07-12): the TEAMHUNT degrade case zeroed b1's captain_slots mid-flight
  -- (the adapter-raise surgery) and nothing restored it — no block called the adapter on b1 again
  -- until THIS one, so the call raised 'captains use 1 slots, limit 0'. Restore the 0171 value
  -- before the adapter calls (in-txn; ROLLBACK reverts regardless).
  update public.main_ship_instances set captain_slots = 6, updated_at = now()
    where main_ship_id = b1 and captain_slots < 6;

  -- preconditions: the CAPXP flip left the flag LIT in-txn; the fixture levels are exactly as the
  -- accrual left them (2 level-2 captains on c1; 1 level-1 captain on the grantless b1); c1 is
  -- module-free so its combat_power decomposes to hull + captains exactly.
  if not public.cfg_bool('captain_growth_enabled') then
    raise exception 'CAPLEVEL FAIL precondition: captain_growth_enabled is not lit in-txn (the CAPXP flip)'; end if;
  select count(*) into n from public.ship_captain_assignments sca
    join public.captain_instances ci on ci.id = sca.captain_instance_id
    where sca.main_ship_id = c1 and ci.level = 2;
  if n <> 2 then raise exception 'CAPLEVEL FAIL precondition: % level-2 captain(s) on c1 (want 2 — the CAPXP boundary fixture)', n; end if;
  select count(*) into n from public.ship_captain_assignments sca
    join public.captain_instances ci on ci.id = sca.captain_instance_id
    where sca.main_ship_id = b1 and ci.level = 1;
  if n <> 1 then raise exception 'CAPLEVEL FAIL precondition: % captain(s) (want 1 level-1 captain on the grantless b1)', n; end if;
  select count(*) into n from public.ship_module_fittings where main_ship_id = c1;
  if n <> 0 then raise exception 'CAPLEVEL FAIL precondition: c1 carries % fitted module(s) (want 0 — the decomposition needs a module-free ship)', n; end if;

  -- THE INDEPENDENT EXPECTATIONS (catalog/instance joins, never the adapter): c1's hull attack,
  -- Σ captain attack, and the level-weighted Σ(level-1)×attack the C2-2 bonus applies to.
  select coalesce((h.base_stats_json->>'attack')::numeric, 0) into v_hull
    from public.main_ship_instances i
    join public.main_ship_hull_types h on h.hull_type_id = i.hull_type_id
    where i.main_ship_id = c1;
  select coalesce(sum(coalesce((t.stats_json->>'attack')::numeric, 0)), 0),
         coalesce(sum((ci.level - 1) * coalesce((t.stats_json->>'attack')::numeric, 0)), 0)
    into v_cap, v_lvl
    from public.ship_captain_assignments sca
    join public.captain_instances ci on ci.id = sca.captain_instance_id
    join public.captain_types t on t.id = ci.captain_type_id
    where sca.main_ship_id = c1;
  if v_lvl <= 0 then
    raise exception 'CAPLEVEL FAIL precondition: Σ(level-1)×attack on c1 is % — the bonus under test must be REAL (a 0=0 compare can only false-green)', v_lvl; end if;

  -- (1) LIT + LEVEL 2, and (3a) LIT + LEVEL 1 — capture both while the flag is on.
  s_on := public.calculate_expedition_stats(uC, c1, '[]'::jsonb, 'none');
  b_on := public.calculate_expedition_stats(uB, b1, '[]'::jsonb, 'none');

  -- (2) FLAG OFF + LEVEL 2 → the level-1 baseline EXACTLY (in-txn flip; restored below).
  update public.game_config set value='false'::jsonb where key='captain_growth_enabled';
  s_off := public.calculate_expedition_stats(uC, c1, '[]'::jsonb, 'none');
  b_off := public.calculate_expedition_stats(uB, b1, '[]'::jsonb, 'none');
  if (s_off->>'combat_power')::numeric is distinct from v_hull + v_cap then
    raise exception 'CAPLEVEL FAIL: flag off + level 2 diverged from the level-1 world: combat_power % (want hull attack % + Σ captain attack % exactly)',
      s_off->>'combat_power', v_hull, v_cap; end if;

  -- the EXACT BONUS: lit exceeds the baseline by round(knob × Σ(level-1)×attack, 2) — 23 → 23.8
  -- at the seeds — and by NOTHING else (every non-combat_power key byte-identical: gunnery seeds
  -- carry attack only, and the fold never touches tradeoffs).
  if (s_on->>'combat_power')::numeric is distinct from (s_off->>'combat_power')::numeric + round(v_knob * v_lvl, 2) then
    raise exception 'CAPLEVEL FAIL: lit combat_power % (want baseline % + knob × Σ(level-1)×attack = % — the exact C2-2 bonus)',
      s_on->>'combat_power', s_off->>'combat_power', (s_off->>'combat_power')::numeric + round(v_knob * v_lvl, 2); end if;
  if (s_on - 'combat_power') is distinct from (s_off - 'combat_power') then
    raise exception 'CAPLEVEL FAIL: the level fold moved a non-captain-stat key: lit % vs dark %', s_on, s_off; end if;

  -- (3) FLAG ON + LEVEL 1 → the baseline EXACTLY: b1 byte-identical lit or dark (whole envelope).
  if b_on is distinct from b_off then
    raise exception 'CAPLEVEL FAIL: flag on + level 1 diverged from its dark baseline (the level-1 world must be byte-identical lit or dark): % vs %', b_on, b_off; end if;

  -- restore the in-txn state this block found (the CAPXP flip; ROLLBACK reverts everything anyway).
  update public.game_config set value='true'::jsonb where key='captain_growth_enabled';

  raise notice 'TEAMCMD_PASS_CAPLEVEL ok: committed knob 0.10 untouched; lit level-2 c1 exceeds the level-1 baseline by exactly round(knob × Σ(level-1)×attack, 2) (23 → 23.8 at the seeds) with every other key byte-identical; flag off + level 2 = hull + Σ captain attack exactly; flag on + level 1 = byte-identical to dark — the DOUBLE inertness, both arms pinned';
end $$;

-- ════════ BLOCK MOD2 (MOD2-1, 0183): the shield line — grant → craft → fit → adapter delta ════════
-- The FIRST end-to-end pin of a module DEFENSE stat through the whole dark pipeline: the 0183
-- catalog seeds (shield_lattice defense 12 / mining_rig_extension mining 8, slot 1 each, recipes
-- from live drops only), the REAL craft_module RPC (0109 — exact recipe spend to zero via the
-- Inventory sole writers, one mint, verbatim replay, the insufficient_items boundary), the REAL
-- fit_module_to_ship RPC (0113/0114 — a canonically-docked commissioned ship IS settled-SAFE),
-- and the 0180 adapter fold: survival rises by EXACTLY the seeded 12 (hull-only 10 → 22 — the
-- packet-F2 degenerate curve finally moves) and mining_yield by EXACTLY 8, with NOTHING else
-- moving but module_slots_used (the CAPLEVEL minus-key isolation idiom). Fixture: a FRESH user uD
-- with a free first commission — canonically docked (at_location, fit-legal per 0114), captain-
-- free and module-free, so the survival baseline decomposes to the hull defense seed EXACTLY and
-- no earlier block's fixture state is touched (every prior pin stays byte-valid). Ingredients
-- arrive ONLY via the REAL Reward sole writer reward_grant() (the CAPXP orphan-grant idiom) —
-- never a direct inventory write; modules only via the real craft/fit RPCs — never a direct
-- module-table write. Both module gates are asserted COMMITTED-dark FIRST (nothing in-txn has
-- touched them), then flipped in-txn only (rolled back).
do $$
begin
  if (select value #>> '{}' from public.game_config where key = 'module_crafting_enabled') is distinct from 'false' then
    raise exception 'MOD2 FAIL: committed module_crafting_enabled is % (want ''false'' — the 0107/0183 dark seeds)',
      (select value #>> '{}' from public.game_config where key = 'module_crafting_enabled'); end if;
  if (select value #>> '{}' from public.game_config where key = 'module_fitting_enabled') is distinct from 'false' then
    raise exception 'MOD2 FAIL: committed module_fitting_enabled is % (want ''false'' — the 0107/0183 dark seeds)',
      (select value #>> '{}' from public.game_config where key = 'module_fitting_enabled'); end if;
end $$;

update public.game_config set value='true'::jsonb where key='module_crafting_enabled';
update public.game_config set value='true'::jsonb where key='module_fitting_enabled';

do $$
declare r jsonb; s0 jsonb; s1 jsonb; s2 jsonb; n int;
  uD uuid; d1 uuid; v_shield uuid; v_rig uuid; v_hulldef numeric; ing record;
begin
  -- fresh fixture user (the signup idiom above) + the FREE first commission → canonically docked.
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'tcmd.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uD;
  insert into tcmd values ('uD', uD);
  r := pg_temp.call_as(uD, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'MOD2 FAIL provision: %', r; end if;
  select main_ship_id into d1 from public.main_ship_instances where player_id = uD;

  -- the 0183 catalog seeds, pinned verbatim (shape + stats + slot_cost + full recipes).
  select count(*) into n from public.module_types
    where (id = 'shield_lattice'       and slot_type = 'defense' and slot_cost = 1 and stats_json = '{"defense": 12}'::jsonb)
       or (id = 'mining_rig_extension' and slot_type = 'mining'  and slot_cost = 1 and stats_json = '{"mining": 8}'::jsonb);
  if n <> 2 then raise exception 'MOD2 FAIL: % of 2 module rows carry the exact 0183 seed shape', n; end if;
  select count(*) into n from public.module_recipe_ingredients
    where (module_type_id, item_id, qty) in (
      ('shield_lattice', 'repair_parts', 4), ('shield_lattice', 'pirate_alloy', 3), ('shield_lattice', 'scrap', 8),
      ('mining_rig_extension', 'crystal', 2), ('mining_rig_extension', 'ore', 6), ('mining_rig_extension', 'scrap', 4));
  if n <> 6 then raise exception 'MOD2 FAIL: % of 6 recipe rows carry the exact 0183 seed (module, item, qty)', n; end if;

  -- grant EXACTLY the shield recipe via the REAL Reward sole writer, and verify it landed —
  -- the craftability math: the listed items ARE the entire price, so exactly-enough must craft.
  perform public.reward_grant('combat', gen_random_uuid(), uD, null,
    '{"items": [{"item_id": "repair_parts", "quantity": 4}, {"item_id": "pirate_alloy", "quantity": 3}, {"item_id": "scrap", "quantity": 8}]}'::jsonb);
  for ing in select item_id, qty from public.module_recipe_ingredients where module_type_id = 'shield_lattice' loop
    if public.inventory_get_balance(uD, ing.item_id) <> ing.qty then
      raise exception 'MOD2 FAIL: pre-craft balance of % is % (want exactly the recipe qty %)',
        ing.item_id, public.inventory_get_balance(uD, ing.item_id), ing.qty; end if;
  end loop;

  -- the survival BASELINE decomposes to the hull defense seed exactly (uD is captain/module/loadout-free).
  select coalesce((h.base_stats_json->>'defense')::numeric, 0) into v_hulldef
    from public.main_ship_instances i join public.main_ship_hull_types h on h.hull_type_id = i.hull_type_id
    where i.main_ship_id = d1;
  s0 := public.calculate_expedition_stats(uD, d1, '[]'::jsonb, 'none');
  if (s0->>'survival')::numeric is distinct from v_hulldef then
    raise exception 'MOD2 FAIL: bare-ship survival % (want the hull defense seed % exactly — the F2 hull-only baseline)',
      s0->>'survival', v_hulldef; end if;

  -- CRAFT via the real RPC: exact spend to ZERO, one instance + one receipt, verbatim replay.
  r := pg_temp.call_as(uD, 'public.craft_module(''mod2-shield-1'', ''shield_lattice'')');
  if (r->>'ok')::boolean is not true or coalesce((r->>'idempotent_replay')::boolean, false) then
    raise exception 'MOD2 FAIL craft: %', r; end if;
  v_shield := (r->>'instance_id')::uuid;
  for ing in select item_id from public.module_recipe_ingredients where module_type_id = 'shield_lattice' loop
    if public.inventory_get_balance(uD, ing.item_id) <> 0 then
      raise exception 'MOD2 FAIL: post-craft balance of % is % — the recipe spend did not land the balance at 0 (exact price)',
        ing.item_id, public.inventory_get_balance(uD, ing.item_id); end if;
  end loop;
  -- the insufficient boundary: with the price fully spent, a SECOND craft must answer
  -- insufficient_items (the 0109 envelope) and mint nothing.
  r := pg_temp.call_as(uD, 'public.craft_module(''mod2-shield-2'', ''shield_lattice'')');
  if (r->>'code') is distinct from 'insufficient_items' then
    raise exception 'MOD2 FAIL: second craft answered % (want insufficient_items — the exact-price boundary)', r; end if;
  -- verbatim replay of the FIRST craft: no double spend, no double mint.
  r := pg_temp.call_as(uD, 'public.craft_module(''mod2-shield-1'', ''shield_lattice'')');
  if (r->>'ok')::boolean is not true or (r->>'idempotent_replay')::boolean is not true
     or (r->>'instance_id')::uuid is distinct from v_shield then
    raise exception 'MOD2 FAIL replay: %', r; end if;
  select count(*) into n from public.module_instances where player_id = uD;
  if n <> 1 then raise exception 'MOD2 FAIL: % module instance(s) after craft+replay (want exactly 1)', n; end if;

  -- FIT via the real RPC, then THE DELTA: survival = baseline + 12 EXACTLY (the 0183 shield
  -- seed), slots 0 → 1, and NO other key moves (the minus-key isolation compare).
  r := pg_temp.call_as(uD, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''mod2-fit-1'')', v_shield, d1));
  if (r->>'ok')::boolean is not true then raise exception 'MOD2 FAIL fit shield: %', r; end if;
  s1 := public.calculate_expedition_stats(uD, d1, '[]'::jsonb, 'none');
  if (s1->>'survival')::numeric is distinct from (s0->>'survival')::numeric + 12 then
    raise exception 'MOD2 FAIL: fitted survival % (want baseline % + the 0183 shield defense 12 exactly)',
      s1->>'survival', s0->>'survival'; end if;
  if (s1->>'module_slots_used')::int is distinct from 1 then
    raise exception 'MOD2 FAIL: module_slots_used % after the shield fit (want 1)', s1->>'module_slots_used'; end if;
  if (s1 - 'survival' - 'module_slots_used') is distinct from (s0 - 'survival' - 'module_slots_used') then
    raise exception 'MOD2 FAIL: the shield moved a non-defense key (defense archetype = the engine tradeoff posture): fitted % vs bare %', s1, s0; end if;

  -- the MINING RIG end-to-end on the same ship: grant its exact recipe, craft, fit →
  -- mining_yield = +8 EXACTLY, slots 1 → 2, same isolation pin.
  perform public.reward_grant('combat', gen_random_uuid(), uD, null,
    '{"items": [{"item_id": "crystal", "quantity": 2}, {"item_id": "ore", "quantity": 6}, {"item_id": "scrap", "quantity": 4}]}'::jsonb);
  r := pg_temp.call_as(uD, 'public.craft_module(''mod2-rig-1'', ''mining_rig_extension'')');
  if (r->>'ok')::boolean is not true then raise exception 'MOD2 FAIL craft rig: %', r; end if;
  v_rig := (r->>'instance_id')::uuid;
  r := pg_temp.call_as(uD, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''mod2-fit-2'')', v_rig, d1));
  if (r->>'ok')::boolean is not true then raise exception 'MOD2 FAIL fit rig: %', r; end if;
  s2 := public.calculate_expedition_stats(uD, d1, '[]'::jsonb, 'none');
  if (s2->>'mining_yield')::numeric is distinct from (s1->>'mining_yield')::numeric + 8 then
    raise exception 'MOD2 FAIL: fitted mining_yield % (want % + the 0183 rig mining 8 exactly)',
      s2->>'mining_yield', s1->>'mining_yield'; end if;
  if (s2->>'module_slots_used')::int is distinct from 2 then
    raise exception 'MOD2 FAIL: module_slots_used % after the rig fit (want 2)', s2->>'module_slots_used'; end if;
  if (s2 - 'mining_yield' - 'module_slots_used') is distinct from (s1 - 'mining_yield' - 'module_slots_used') then
    raise exception 'MOD2 FAIL: the rig moved a non-mining key (mining archetype = the engine tradeoff posture): % vs %', s2, s1; end if;

  raise notice 'TEAMCMD_PASS_MOD2 ok: committed module gates dark; 0183 seeds exact (defense 12 / mining 8, 6 recipe rows); exact-price craft spends to 0 with insufficient_items at the boundary + verbatim replay (1 instance); fit lands survival +12 exactly (hull 10 -> 22, the F2 curve moves) and mining_yield +8 exactly, nothing else but slots 1 then 2';
end $$;

-- ════════ BLOCK SHIPYARD0 (SHIPYARD-0, 0185): T1 hull/recipe catalog + the blueprint faucet ════════
-- Migration 0185 seeded the ship-production foundation DARK: `shipyard_enabled='false'`, the two
-- T1 hulls (bulk_hauler / strike_corvette — the 0184 Mule/Talon register), their build recipes
-- (`hull_build_recipes` + `hull_recipe_ingredients`, Reference/Config, migration-seeded only),
-- and ONE marked hunk on pirate_loot_for_wave (re-created from its TRUE head, 0171): waves >= 8
-- roll `random() < cfg blueprint_fragment_drop_rate` for exactly 1 blueprint_fragment — the EXACT
-- 0171 shard idiom at a DEEPER threshold (shards w>=2, blueprints w>=8 — the deep-run gate).
-- Direct-call pins at the knob's DETERMINISTIC endpoints (the SHARDDROP technique — rate 0 →
-- never, rate 1 → always; the probabilistic middle is deliberately untested). FIXTURE CARRY: the
-- SHARDDROP block left captain_shard_drop_rate at 1 IN-TXN (asserted below), so every legacy
-- bundle here deterministically carries the appended shard — the expected arrays include it.
--   CATALOG   — 2 hull rows EXACT (all gameplay columns + display names + base_stats_json);
--               2 recipe headers EXACT (credits 400 / 3600s / NULL T1 gates); 10 ingredient rows
--               EXACT, no strays.
--   PARITY (blueprint rate 0, the committed 0185 seed) — wave-8 and wave-10 bundles BYTE-IDENTICAL
--               to the 0171 head's output (legacy elements + the rate-1 shard), NO blueprint.
--   DROP (rate 1)      — a wave-8 bundle gains EXACTLY one blueprint qty 1, APPENDED LAST
--               (additive-only: bundle minus the blueprint == the 0171 bundle).
--   THRESHOLD (rate 1) — wave 7 (w<8) gains NO blueprint at ANY rate; wave 1 stays scrap-only
--               with BOTH knobs at 1 (the verify-phase5 exact pin can never flake).
--   DARK      — shipyard_enabled COMMITTED 'false'; blueprint_fragment_drop_rate COMMITTED '0'
--               (both asserted before any in-txn knob write; the flag is NEVER flipped, even
--               in-txn — no shipyard RPC exists to exercise).
do $$
declare v_legacy8 jsonb; v_legacy10 jsonb; v_shard jsonb; v_got jsonb; n int;
begin
  -- the committed seeds are dark/inert — the 0185 posture (asserted BEFORE the in-txn knob write).
  if (select value #>> '{}' from public.game_config where key = 'shipyard_enabled') is distinct from 'false' then
    raise exception 'SHIPYARD0 FAIL: committed shipyard_enabled is % (want ''false'' — the 0185 dark seed)',
      (select value #>> '{}' from public.game_config where key = 'shipyard_enabled'); end if;
  if (select value #>> '{}' from public.game_config where key = 'blueprint_fragment_drop_rate') is distinct from '0' then
    raise exception 'SHIPYARD0 FAIL: committed blueprint_fragment_drop_rate is % (want 0 — the 0185 faucet seed)',
      (select value #>> '{}' from public.game_config where key = 'blueprint_fragment_drop_rate'); end if;
  -- the SHARDDROP fixture carry this block's exact bundles depend on (see header).
  if public.cfg_num('captain_shard_drop_rate') is distinct from 1 then
    raise exception 'SHIPYARD0 FAIL: in-txn captain_shard_drop_rate is % (want 1 — the SHARDDROP block''s fixture carry)',
      public.cfg_num('captain_shard_drop_rate'); end if;

  -- CATALOG: the two T1 hulls, every gameplay column pinned (the 0185 seed verbatim).
  select count(*) into n from public.main_ship_hull_types
    where (hull_type_id = 'bulk_hauler' and name = 'Mule-class Hauler'
           and base_hp = 650 and base_speed = 0.8
           and base_cargo_capacity = 140 and base_cargo_capacity_m3 = 140.0
           and base_support_capacity = 10 and base_captain_slots = 6 and base_module_slots = 2
           and base_stats_json = '{"attack": 5, "defense": 15}'::jsonb)
       or (hull_type_id = 'strike_corvette' and name = 'Talon-class Corvette'
           and base_hp = 420 and base_speed = 1.3
           and base_cargo_capacity = 20 and base_cargo_capacity_m3 = 20.0
           and base_support_capacity = 10 and base_captain_slots = 6 and base_module_slots = 4
           and base_stats_json = '{"attack": 30, "defense": 10}'::jsonb);
  if n <> 2 then raise exception 'SHIPYARD0 FAIL: % of 2 T1 hull rows carry the exact 0185 seed (stats + display names)', n; end if;

  -- CATALOG: the recipe headers + the full ingredient set, exact and stray-free.
  select count(*) into n from public.hull_build_recipes
    where hull_type_id in ('bulk_hauler', 'strike_corvette')
      and credits_cost = 400 and build_seconds = 3600
      and required_hull_type_id is null and required_captain_level is null;
  if n <> 2 then raise exception 'SHIPYARD0 FAIL: % of 2 recipe header rows carry the exact 0185 seed (credits 400 / 3600s / NULL T1 gates)', n; end if;
  select count(*) into n from public.hull_recipe_ingredients
    where (hull_type_id, item_id, qty) in (
      ('bulk_hauler', 'ore', 24), ('bulk_hauler', 'crystal', 6), ('bulk_hauler', 'engine_parts', 6),
      ('bulk_hauler', 'scrap', 12), ('bulk_hauler', 'blueprint_fragment', 2),
      ('strike_corvette', 'ore', 16), ('strike_corvette', 'crystal', 4), ('strike_corvette', 'weapon_parts', 6),
      ('strike_corvette', 'pirate_alloy', 8), ('strike_corvette', 'blueprint_fragment', 2));
  if n <> 10 then raise exception 'SHIPYARD0 FAIL: % of 10 ingredient rows carry the exact 0185 seed (hull, item, qty)', n; end if;
  select count(*) into n from public.hull_recipe_ingredients;
  if n <> 10 then raise exception 'SHIPYARD0 FAIL: hull_recipe_ingredients has % rows (want exactly 10 — no strays)', n; end if;

  -- PARITY at blueprint rate 0 (the committed seed): the deployed body's output is byte-identical
  -- to the 0171 head — the legacy elements + the (shard-rate-1) shard, NO blueprint, order intact.
  v_legacy8 := jsonb_build_array(
    jsonb_build_object('item_id', 'scrap',        'quantity', 1),
    jsonb_build_object('item_id', 'pirate_alloy', 'quantity', 1),
    jsonb_build_object('item_id', 'weapon_parts', 'quantity', 1),
    jsonb_build_object('item_id', 'engine_parts', 'quantity', 1));
  v_legacy10 := v_legacy8 || jsonb_build_object('item_id', 'repair_parts', 'quantity', 1);
  v_shard    := jsonb_build_object('item_id', 'captain_memory_shard', 'quantity', 1);
  v_got := public.pirate_loot_for_wave(8, 2);
  if v_got is distinct from (v_legacy8 || v_shard) then
    raise exception 'SHIPYARD0 FAIL: rate-0 wave-8 bundle diverges from the 0171 head output: % vs %', v_got, v_legacy8 || v_shard; end if;
  v_got := public.pirate_loot_for_wave(10, 4);
  if v_got is distinct from (v_legacy10 || v_shard) then
    raise exception 'SHIPYARD0 FAIL: rate-0 wave-10 bundle diverges from the 0171 head output: % vs %', v_got, v_legacy10 || v_shard; end if;

  -- DROP at rate 1 (the real set_game_config; reverted by ROLLBACK): wave 8 gains EXACTLY one
  -- blueprint qty 1, appended LAST (additive-only over the 0171 bundle).
  perform public.set_game_config('blueprint_fragment_drop_rate', '1'::jsonb);
  v_got := public.pirate_loot_for_wave(8, 2);
  select count(*) into n from jsonb_array_elements(v_got) e
    where e->>'item_id' = 'blueprint_fragment' and (e->>'quantity')::int = 1;
  if n <> 1 then
    raise exception 'SHIPYARD0 FAIL: rate-1 wave-8 loot has % blueprint elements (want exactly 1 blueprint, qty 1): %', n, v_got; end if;
  if v_got->(jsonb_array_length(v_got) - 1)->>'item_id' is distinct from 'blueprint_fragment' then
    raise exception 'SHIPYARD0 FAIL: the blueprint is not appended after every 0171 element: %', v_got; end if;
  if v_got - (jsonb_array_length(v_got) - 1) is distinct from (v_legacy8 || v_shard) then
    raise exception 'SHIPYARD0 FAIL: rate-1 wave-8 bundle minus the blueprint is not the 0171 bundle: %', v_got; end if;

  -- THRESHOLD at rate 1: wave 7 (w<8) gains NO blueprint; wave 1 STILL scrap-only with BOTH
  -- knobs at 1 (shards gate w>=2, blueprints w>=8 — the deterministic-wave-1 law holds).
  v_got := public.pirate_loot_for_wave(7, 2);
  select count(*) into n from jsonb_array_elements(v_got) e where e->>'item_id' = 'blueprint_fragment';
  if n <> 0 then
    raise exception 'SHIPYARD0 FAIL: rate-1 wave-7 loot carries a blueprint (w>=8 threshold breach): %', v_got; end if;
  v_got := public.pirate_loot_for_wave(1, 1);
  if v_got is distinct from jsonb_build_array(jsonb_build_object('item_id', 'scrap', 'quantity', 1)) then
    raise exception 'SHIPYARD0 FAIL: wave-1 loot is not scrap-only with both knobs at 1 (threshold breach): %', v_got; end if;

  -- DEEP SHAPE at rate 1: the full 0171 bundle plus the one appended blueprint, nothing else.
  v_got := public.pirate_loot_for_wave(10, 4);
  if v_got is distinct from (v_legacy10 || v_shard || jsonb_build_object('item_id', 'blueprint_fragment', 'quantity', 1)) then
    raise exception 'SHIPYARD0 FAIL: rate-1 wave-10 bundle wrong: %', v_got; end if;

  raise notice 'TEAMCMD_PASS_SHIPYARD0 ok: committed shipyard flag false + faucet knob 0 (dark); 2 T1 hulls exact (Mule 650/0.8/140 + Talon 420/1.3/20, names + stats); 2 recipe headers + 10 ingredient rows exact; rate-0 byte-parity with the 0171 head (wave 8 + wave 10, shard carried); rate-1 wave-8 gains exactly one appended blueprint (additive-only); w<8 + wave-1 thresholds hold at any rate';
end $$;

-- ════════ BLOCK SOUL0 (SOUL-0, 0186): per-ship traits — deterministic roll, immutability, hp_mult ════════
-- The trait FOUNDATION end-to-end on FRESH fixture users (free first commissions — captain/module-
-- free, no earlier block's fixture state touched): the committed `ship_traits_enabled` seed
-- asserted DARK first, and the roll writer's gate-first reject pinned with a RANDOM uuid (a
-- reject-after-read regression would answer ship_not_found — no existence oracle) with ZERO rows
-- written; the 0186 catalog pinned VERBATIM (8 traits exact: id + stats_json + hp_mult); then the
-- flag flipped in-txn only. DETERMINISM is proven by INLINE RE-DERIVATION (the D0/D1 independent-
-- computation idiom): pg_temp.soul_expect re-implements the pure-hash mapping (hashtextextended
-- over the ':soul:' salts → ((h % n + n) % n) into the trait_type_id order under the SAME
-- collate "C" pin as the writer — the collation law: byte order, never the DB default — with
-- the same bounded (64) re-salt loop) and is computed BEFORE each roll — the fixture loop commissions fresh
-- ships until one arm's derived pair CONTAINS veteran_frame (the sole hp_mult carrier) and one
-- arm's does NOT, so BOTH hp branches are exercised every run even though ship ids are fresh
-- uuids (the derivation, not a fixed id, is the pin — the rolls must land exactly the derived
-- traits or the writer is not the pinned pure function). Veteran arm: max_hp = round(base × 1.08)
-- exactly, hp scales with it (full-hp ship stays full). Plain arm: hp/max_hp byte-untouched.
-- IMMUTABILITY: a second roll is an idempotent replay — inserted 0, same 2 rows, same traits,
-- max_hp NOT re-raised (the double-apply hazard pin), and its ENVELOPE reports the STORED roll
-- (traits + the ship's real hp_mult product — the 0186 M2 stored-row envelope, asserted so a
-- future catalog change can never make a replay contradict the ship); the harness itself NEVER writes either
-- Ship-Soul table directly (the sole-writer negative grep in the .sh). The roll fn is called
-- directly (service context) — it is service_role-only with NO wrapper and NO caller in the
-- product (doubly dark: flag + no caller; SOUL-1 owns the commission hook + adapter fold).
create or replace function pg_temp.soul_expect(p_ship uuid) returns text[] language plpgsql as $$
declare v_count int; v_h bigint; v_i1 int; v_i2 int; v_k int := 0; v_salt text; v_t1 text; v_t2 text;
begin
  select count(*) into v_count from public.ship_trait_types;
  v_h  := hashtextextended(p_ship::text || ':soul:1', 0);
  v_i1 := (((v_h % v_count) + v_count) % v_count)::int;
  loop
    v_k := v_k + 1;
    if v_k > 64 then raise exception 'soul_expect: no distinct slot-2 index after 64 re-salts (mirrors the writer bound)'; end if;
    v_salt := p_ship::text || ':soul:2' || case when v_k = 1 then '' else ':' || v_k end;
    v_h  := hashtextextended(v_salt, 0);
    v_i2 := (((v_h % v_count) + v_count) % v_count)::int;
    exit when v_i2 <> v_i1;
  end loop;
  -- collate "C": the SAME derivation-order pin as the writer (byte order, never the DB default).
  select trait_type_id into v_t1 from public.ship_trait_types order by trait_type_id collate "C" offset v_i1 limit 1;
  select trait_type_id into v_t2 from public.ship_trait_types order by trait_type_id collate "C" offset v_i2 limit 1;
  return array[v_t1, v_t2];
end $$;

do $$
declare r jsonb; n int;
begin
  if (select value #>> '{}' from public.game_config where key = 'ship_traits_enabled') is distinct from 'false' then
    raise exception 'SOUL0 FAIL: committed ship_traits_enabled is % (want ''false'' — the 0186 dark seed)',
      (select value #>> '{}' from public.game_config where key = 'ship_traits_enabled'); end if;
  -- gate-first while dark: a RANDOM uuid — a reject-after-read regression would answer
  -- ship_not_found instead (no existence oracle); and nothing may be written.
  r := public.soul_roll_traits_for_ship(gen_random_uuid());
  if (r->>'code') is distinct from 'feature_disabled' then
    raise exception 'SOUL0 FAIL dark: % (want the gate-first feature_disabled envelope)', r; end if;
  select count(*) into n from public.main_ship_traits;
  if n <> 0 then raise exception 'SOUL0 FAIL: % main_ship_traits rows written while dark (want 0)', n; end if;
end $$;

update public.game_config set value='true'::jsonb where key='ship_traits_enabled';

do $$
declare r jsonb; n int; i int;
  u uuid; s uuid; shipv uuid; shipp uuid;
  exp text[]; expv text[]; expp text[];
  t1 text; t2 text; v_mult numeric;
  v_max0 int; v_max1 int; v_hp1 int; v_maxp0 int;
begin
  -- the 0186 catalog, pinned verbatim (id + stats_json + hp_mult), and exactly 8 total.
  select count(*) into n from public.ship_trait_types t
    join (values
      ('veteran_frame',      '{"defense": 5}'::jsonb,                            1.08::numeric),
      ('tuned_thrusters',    '{"speed_mult_bonus": 0.08, "cargo": -3}'::jsonb,   1.0),
      ('reinforced_plating', '{"defense": 8, "speed_mult_bonus": -0.04}'::jsonb, 1.0),
      ('smugglers_holds',    '{"cargo": 8, "scan": -2}'::jsonb,                  1.0),
      ('keen_arrays',        '{"scan": 5}'::jsonb,                               1.0),
      ('hungry_guns',        '{"attack": 6, "defense": -3}'::jsonb,              1.0),
      ('steady_rigger',      '{"mining": 4, "repair": 2}'::jsonb,                1.0),
      ('ill_omened',         '{"evasion": 6, "attack": -2}'::jsonb,              1.0)
    ) v(id, stats, mult)
    on v.id = t.trait_type_id and t.stats_json = v.stats and t.hp_mult = v.mult;
  if n <> 8 then
    raise exception 'SOUL0 FAIL: % trait rows carry the exact seed (want 8 traits exact — the 0186 catalog verbatim)', n; end if;
  select count(*) into n from public.ship_trait_types;
  if n <> 8 then raise exception 'SOUL0 FAIL: catalog holds % rows (want exactly 8 — no strays)', n; end if;

  -- fixture search: commission fresh ships until the INLINE DERIVATION says one pair carries
  -- veteran_frame (the sole hp_mult carrier) and one does not — both hp branches exercised every
  -- run. E[draws] ≈ 3 at 8 traits; 40 bounds the miss probability below 1e-4.
  for i in 1..40 loop
    exit when shipv is not null and shipp is not null;
    insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
      values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
              'tcmd.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
      returning id into u;
    r := pg_temp.call_as(u, 'public.commission_first_main_ship()');
    if (r->>'ok')::boolean is not true then raise exception 'SOUL0 FAIL provision: %', r; end if;
    select main_ship_id into s from public.main_ship_instances where player_id = u;
    exp := pg_temp.soul_expect(s);
    if 'veteran_frame' = any(exp) then
      if shipv is null then shipv := s; expv := exp; end if;
    else
      if shipp is null then shipp := s; expp := exp; end if;
    end if;
  end loop;
  if shipv is null or shipp is null then
    raise exception 'SOUL0 FAIL: could not draw both fixture arms (veteran + plain) in 40 commissions'; end if;

  -- ── the VETERAN arm: exact derived traits, distinct slots, exact hp_mult application ────────
  select max_hp into v_max0 from public.main_ship_instances where main_ship_id = shipv;
  r := public.soul_roll_traits_for_ship(shipv);
  if (r->>'ok')::boolean is not true or (r->>'inserted')::int is distinct from 2 then
    raise exception 'SOUL0 FAIL roll(V): %', r; end if;
  select count(*) into n from public.main_ship_traits where main_ship_id = shipv;
  if n <> 2 then raise exception 'SOUL0 FAIL: % trait rows after the roll (want exactly 2)', n; end if;
  select trait_type_id into t1 from public.main_ship_traits where main_ship_id = shipv and slot = 1;
  select trait_type_id into t2 from public.main_ship_traits where main_ship_id = shipv and slot = 2;
  if t1 is distinct from expv[1] or t2 is distinct from expv[2] then
    raise exception 'SOUL0 FAIL: rolled (%, %) but the inline re-derivation says (%, %) — the roll is not the pinned pure function',
      t1, t2, expv[1], expv[2]; end if;
  if t1 = t2 then raise exception 'SOUL0 FAIL: slot1 = slot2 (%) — distinctness breach', t1; end if;
  select a.hp_mult * b.hp_mult into v_mult
    from public.ship_trait_types a, public.ship_trait_types b
    where a.trait_type_id = expv[1] and b.trait_type_id = expv[2];
  select max_hp, hp into v_max1, v_hp1 from public.main_ship_instances where main_ship_id = shipv;
  if v_max1 is distinct from round(v_max0 * v_mult)::int then
    raise exception 'SOUL0 FAIL: max_hp % after the veteran roll (want round(% × %) — the hp_mult exactly)',
      v_max1, v_max0, v_mult; end if;
  if v_hp1 is distinct from v_max1 then
    raise exception 'SOUL0 FAIL: hp % after the full-hp veteran roll (want % — hp scales proportionally with max)',
      v_hp1, v_max1; end if;

  -- ── immutability: the second call is an idempotent replay — nothing may move ────────────────
  r := public.soul_roll_traits_for_ship(shipv);
  if (r->>'ok')::boolean is not true or (r->>'inserted')::int is distinct from 0 then
    raise exception 'SOUL0 FAIL second roll: % (want inserted 0 — the idempotent replay)', r; end if;
  -- the M2 stored-row envelope: the replay must report the ship's STORED roll — the same traits
  -- AND the ship's real hp_mult product (1.08 on this veteran arm), never a re-derived default.
  if (r->'traits'->>0) is distinct from expv[1] or (r->'traits'->>1) is distinct from expv[2]
     or (r->>'hp_mult')::numeric is distinct from v_mult then
    raise exception 'SOUL0 FAIL: the replay envelope does not report the STORED roll (got traits %/% hp_mult % — want %/% %)',
      r->'traits'->>0, r->'traits'->>1, r->>'hp_mult', expv[1], expv[2], v_mult; end if;
  select count(*) into n from public.main_ship_traits where main_ship_id = shipv;
  if n <> 2 then raise exception 'SOUL0 FAIL: the second roll changed the row count to % (want still 2)', n; end if;
  select count(*) into n from public.main_ship_traits
    where main_ship_id = shipv
      and ((slot = 1 and trait_type_id = expv[1]) or (slot = 2 and trait_type_id = expv[2]));
  if n <> 2 then raise exception 'SOUL0 FAIL: the second roll changed a rolled trait (re-roll breach)'; end if;
  select max_hp into n from public.main_ship_instances where main_ship_id = shipv;
  if n is distinct from v_max1 then
    raise exception 'SOUL0 FAIL: the second roll re-raised max_hp to % (want % — hp applies once)', n, v_max1; end if;

  -- ── the PLAIN arm: exact derived traits, and hp/max_hp byte-untouched (no hp_mult carrier) ───
  select max_hp into v_maxp0 from public.main_ship_instances where main_ship_id = shipp;
  r := public.soul_roll_traits_for_ship(shipp);
  if (r->>'ok')::boolean is not true or (r->>'inserted')::int is distinct from 2 then
    raise exception 'SOUL0 FAIL roll(P): %', r; end if;
  select trait_type_id into t1 from public.main_ship_traits where main_ship_id = shipp and slot = 1;
  select trait_type_id into t2 from public.main_ship_traits where main_ship_id = shipp and slot = 2;
  if t1 is distinct from expp[1] or t2 is distinct from expp[2] then
    raise exception 'SOUL0 FAIL: plain arm rolled (%, %) but the inline re-derivation says (%, %) — the roll is not the pinned pure function',
      t1, t2, expp[1], expp[2]; end if;
  if t1 = t2 then raise exception 'SOUL0 FAIL: slot1 = slot2 (%) — distinctness breach', t1; end if;
  select max_hp, hp into v_max1, v_hp1 from public.main_ship_instances where main_ship_id = shipp;
  if v_max1 is distinct from v_maxp0 or v_hp1 is distinct from v_maxp0 then
    raise exception 'SOUL0 FAIL: a plain (mult-1.0) roll moved hp/max_hp to %/% (want % untouched)',
      v_hp1, v_max1, v_maxp0; end if;

  raise notice 'TEAMCMD_PASS_SOUL0 ok: committed flag dark + gate-first reject with 0 rows; 0186 catalog pinned verbatim (8 exact); both rolls land exactly the inline re-derived traits (pure-hash determinism), slots distinct; veteran arm max_hp = round(base × 1.08) with hp scaled, plain arm byte-untouched; second roll = idempotent replay (0 inserts, same traits, stored-roll envelope incl. the real hp_mult, no hp re-raise)';
end $$;

-- ════════ BLOCK TEAMMAP (TEAMMAP-1, 0187): group-send tags member fleets; arrival docks the team ════════
-- Migration 0187 re-created send_ship_group_expedition (from its TRUE 0163 head) with ONE marked hunk:
-- after the all-or-nothing member loop succeeds, the just-created member fleets are tagged with the
-- team's group_id — the 0168 INFORMATIONAL, display-only column (ROUTING NEVER reads it; accordingly
-- this block makes no routing assertion on the tag either — it pins the tag itself and that the
-- pre-existing dock settle is untouched by it). Runs on a FRESH fixture user (the MOD2 idiom — the
-- earlier fixtures sit in deep post-settle shapes):
--   TAG  — a 2-ship team send to Slagworks (starter port) leaves BOTH member fleets carrying
--          group_id = the team, the tagged set is exactly the envelope's sent[] fleet ids, and the
--          owner has NO stray tagged fleet beyond those two.
--   DOCK — rewinding arrive_at (the sanctioned clock surgery) and settling each movement through
--          movement_settle_arrival (the SAME per-movement settle the cron calls) DOCKS both members
--          at the port (0153: status 'stationary' / spatial_state 'at_location'), their fleets
--          'present' at Slagworks — and the informational tag SURVIVES the settle (the map's
--          docked-team badge read).
do $$
declare r jsonb; n int; uT uuid; t1 uuid; t2 uuid; gT uuid; v_mv uuid;
  slag uuid := (select v from tcmd where k='slag');
  v_sent_fleets uuid[];
begin
  -- fresh fixture user (the MOD2 idiom): the on-signup triggers auto-create the active Home Base;
  -- fund the wallet for the additional commission (the same direct owner insert as the funding step
  -- above — B-verify makes no balance assertion).
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'tcmd.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uT;
  insert into public.player_wallet (player_id, balance) values (uT, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;

  -- two ships via the REAL commission RPCs, then the ONE sanctioned fixture normalization to legacy
  -- 'home' (the provisioning idiom verbatim: home pair-shape + retire the 'present' commission
  -- fleets + complete their presence rows + a created_at stagger for deterministic member order).
  r := pg_temp.call_as(uT, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'TEAMMAP FAIL provision first: %', r; end if;
  select main_ship_id into t1 from public.main_ship_instances where player_id = uT;
  r := pg_temp.call_as(uT, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then raise exception 'TEAMMAP FAIL provision 2nd: %', r; end if;
  t2 := (r->>'main_ship_id')::uuid;
  update public.main_ship_instances
     set status = 'home', spatial_state = null, space_x = null, space_y = null, updated_at = now()
   where main_ship_id in (t1, t2);
  update public.fleets
     set status = 'destroyed', location_mode = 'destroyed', active_movement_id = null,
         current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
         updated_at = now()
   where main_ship_id in (t1, t2) and status = 'present';
  update public.location_presence
     set status = 'completed', updated_at = now()
   where fleet_id in (select id from public.fleets where main_ship_id in (t1, t2) and status = 'destroyed')
     and status = 'active';
  update public.main_ship_instances set created_at = created_at - interval '2 seconds' where main_ship_id = t1;
  update public.main_ship_instances set created_at = created_at - interval '1 second'  where main_ship_id = t2;

  -- a team of two, via the real RPCs.
  r := pg_temp.call_as(uT, 'public.upsert_ship_group(1, ''MapWing'')');
  if (r->>'ok')::boolean is not true then raise exception 'TEAMMAP FAIL group create: %', r; end if;
  gT := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uT, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', t1, gT));
  if (r->>'ok')::boolean is not true then raise exception 'TEAMMAP FAIL assign t1: %', r; end if;
  r := pg_temp.call_as(uT, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', t2, gT));
  if (r->>'ok')::boolean is not true then raise exception 'TEAMMAP FAIL assign t2: %', r; end if;

  -- TAG: group-send to the port; both member fleets carry the informational group_id, the tagged
  -- set is exactly the envelope's sent[] fleet ids (the hunk updates what the loop just created),
  -- and the owner has no stray tagged fleet.
  r := pg_temp.call_as(uT, format('public.send_ship_group_expedition(%L::uuid, %L::uuid)', gT, slag));
  if (r->>'ok')::boolean is not true then raise exception 'TEAMMAP FAIL team send: %', r; end if;
  if jsonb_array_length(r->'sent') <> 2 then raise exception 'TEAMMAP FAIL: sent length % (want 2)', jsonb_array_length(r->'sent'); end if;
  select array_agg((e->>'fleet_id')::uuid) into v_sent_fleets from jsonb_array_elements(r->'sent') e;
  select count(*) into n from public.fleets
    where main_ship_id in (t1, t2) and status = 'moving' and group_id = gT;
  if n <> 2 then raise exception 'TEAMMAP FAIL: % member fleets carry group_id = the team (want 2 — the 0187 tag hunk)', n; end if;
  select count(*) into n from public.fleets where id = any(v_sent_fleets) and group_id = gT;
  if n <> 2 then raise exception 'TEAMMAP FAIL: tagged fleets are not exactly the envelope''s sent[] ids (% of 2)', n; end if;
  select count(*) into n from public.fleets where player_id = uT and group_id is not null;
  if n <> 2 then raise exception 'TEAMMAP FAIL: % tagged fleets for the owner (want exactly the 2 member fleets — no strays)', n; end if;

  -- DOCK: settle both arrivals through the cron's own per-movement settle (clock rewind first — the
  -- sanctioned surgery; now() is txn-constant so no real interval can elapse). Slagworks is a legal
  -- dockable port (0065/0066 role + docking service + anchor seeds, revealed in setup), so the 0153
  -- location branch docks each main ship; the informational tag must survive the settle.
  for v_mv in
    select fm.id from public.fleet_movements fm
      join public.fleets f on f.id = fm.fleet_id
     where f.main_ship_id in (t1, t2) and fm.status = 'moving'
  loop
    -- shift BOTH timestamps (the established rewind idiom of every earlier block): moving only
    -- arrive_at back would land arrive_at <= depart_at on a just-sent movement and violate the
    -- 0007 fleet_movements check (arrive_at > depart_at).
    update public.fleet_movements
       set depart_at = now() - interval '2 minutes', arrive_at = now() - interval '1 minute'
     where id = v_mv;
    r := public.movement_settle_arrival(v_mv);
    if (r->>'settled')::boolean is not true or (r->>'outcome') is distinct from 'present' then
      raise exception 'TEAMMAP FAIL settle: %', r; end if;
  end loop;
  select count(*) into n from public.main_ship_instances
    where main_ship_id in (t1, t2) and status = 'stationary' and spatial_state = 'at_location';
  if n <> 2 then raise exception 'TEAMMAP FAIL: % members docked at arrival (want 2 — the 0153 dock write)', n; end if;
  select count(*) into n from public.fleets
    where main_ship_id in (t1, t2) and status = 'present' and current_location_id = slag and group_id = gT;
  if n <> 2 then raise exception 'TEAMMAP FAIL: % present member fleets at the port still tagged (want 2 — the docked-team badge read)', n; end if;

  raise notice 'TEAMCMD_PASS_TEAMMAP ok: 2-ship team send tags both member fleets with group_id (= the envelope''s sent[] ids, no strays); arrival settles dock both members at the port (stationary/at_location, fleets present at Slagworks) with the informational tag surviving the settle';
end $$;

select 'TEAM-COMMAND B-VERIFY PROOF PASSED (dark reject-before-read; write/assign integrity; C0 captain-fold group preview; D0 authoritative totals = delegated sums, strict-vs-preview; all-or-nothing send; best-effort stop; SET-NULL delete; D1 legacy combat parity; D2 team hunt send + manifest + member encounter; 0171 shard drop: rate-0 parity + rate-1 wave-2 drop + end-to-end deposit; D3 sortie settle: returning members, reconciler re-home + race guards, M1 race closure; 0177 captain XP: dark no-op, current-assignment accrual with per-(grant, captain) ledger + sentinel, boundary curve, re-run exactly-once; 0180 C2-2 level fold: exact lit bonus on the captain-contributed portion + double inertness both arms; 0183 MOD2-1: exact-price craft + fit + adapter survival/mining deltas end-to-end; 0185 SHIPYARD-0: T1 hull + recipe catalog exact, blueprint faucet rate-0 parity + rate-1 w>=8 drop with the w<8 threshold, shipyard flag dark; 0186 SOUL-0: deterministic trait rolls = the inline re-derivation, exact hp_mult, idempotent immutability; 0187 TEAMMAP-1: team send tags member fleets = the sent[] envelope, arrival docks the team with the tag surviving)' as result;

rollback;   -- leave ZERO persisted state: no ship, no group, no fleet, no flag flip, no fixture user.
