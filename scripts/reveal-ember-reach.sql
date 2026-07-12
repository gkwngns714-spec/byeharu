-- EMBER REACH REVEAL — the ZONES2-2 content reveal (docs/FULL_CAPACITY_PLAN.md §C P4; queue slice #8;
-- content seeded HIDDEN by migration 20260618000175 / queue slice #7).
--
-- ██ HUMAN REVEAL TOOL ██ — run BY THE HUMAN, deliberately, against prod. NOT CI; nothing reveals at
-- build/deploy time. Each run of this file IS the recorded human go decision. Reveal IS the content
-- cadence mechanism (plan §C P4: "ship content hidden, reveal deliberately, ~monthly").
-- RECOMMENDED TIMING: after teams have had time to kit up — the gates price the sites at ≈4/6/8
-- kitted+captained ships (min_power 150/220/300 vs 38 combat_power per kitted ship — the
-- TEAM_ACTIVATION_PACKET §0.3/§1.3-C rationale), so revealing before modules/captains are flowing
-- shows players three sites nobody can enter yet.
--
-- ── WHAT IT DOES (one transaction; COMMIT only if every assert passes) ────────────────────────────
--   PRECONDITIONS (read-only; the write is not reached unless all hold):
--     • migration head >= 20260618000175 AND 0175 (the Ember Reach seed) recorded by version;
--     • the three canonical rows exist by FIXED uuid — exactly 3, ALL 'hidden', none active (a rerun
--       after a successful reveal fails closed HERE and never writes);
--     • each row still carries its exact seeded identity (name, bd 40/50/60, tier 4/4/5, min_power
--       150/220/300, activity hunt_pirates) — the reveal refuses drifted content;
--     • the gates are monotonic with difficulty (belt-and-braces re-check of the 0175 self-assert);
--     • the parent zone (Ember Reach) and sector (Ashen Frontier) are ACTIVE — otherwise flipping the
--       locations would be an invisible no-op (get_world_map filters all three levels);
--     • the deployed get_world_map() body still filters on status='active' at all three levels
--       (prosrc pin — the map read is the visibility authority this reveal flips against);
--     • behavioral pre-check: none of the three names/ids appear in get_world_map() output yet.
--   STAGE — THE ONLY WRITE of this script: ONE UPDATE flipping status hidden→active for EXACTLY the
--     three fixed uuids (guarded `and status='hidden'`; row_count must be exactly 3). No flag write,
--     no game_config write, no other table, no DDL.
--   SMOKE (read-only): the 3 rows active; net active-location change exactly +3; every NON-canonical
--     location STATUS-INVARIANT (id=status digest — proves no other row's status moved; not full byte-identity);
--     game_config byte-identical (key=value digest — proves no flag rode along); behavioral
--     post-check: all three names now IN get_world_map() output, inside zone Ember Reach.
--   Emits REVEAL_EMBER_PASS_* markers per stage + one final PASS line; any failed assert RAISES → the
--   whole transaction rolls back → NOTHING is applied (all-or-nothing reveal).
--
-- NOT idempotent BY DESIGN (the reveal-starter-ports posture): a second run fails closed at the
-- all-hidden precondition and never re-writes. "Already revealed" is an error, not a success.
--
-- ── INVOCATION (Management-API compatible: NO psql meta-commands; one BEGIN..COMMIT) ──────────────
--   psql "<prod session-pooler conn (pinned CA, sslmode=verify-full)>" -X -v ON_ERROR_STOP=1 \
--        -f scripts/reveal-ember-reach.sql
--   Or paste this whole file into the Supabase Dashboard SQL editor / management-API runner (it
--   contains no backslash commands to strip), or:
--     bash scripts/reveal-ember-reach.sh run REVEAL_EMBER_REACH      # DB_URL required
--   AFTER a green run: the manual smoke — open the galaxy map: three new hostile (triangle) markers
--   NE beyond Blackden (Ember Gate/Cinder Maw/The Furnace, bd 40/50/60, gates 150/220/300 shown in
--   the detail panel); an under-powered team send rejects power_below_required server-side. No client
--   PR exists for this reveal — the map is data-driven (markerStyle.ts derives everything from the
--   location row; verified: no client code keys on location count/sectors).
--
-- ── ROLLBACK (manual; commented at the BOTTOM) ────────────────────────────────────────────────────
--   UNLIKE the starter-port reveal (operationally one-way: players take home-port affiliation and
--   dock state at ports), a hunt-site reveal IS reversible — re-hiding flips the same three rows
--   back. The one consideration, thought through: send RPCs validate location status at SEND time
--   only (0019:39-41 / 0168:196-198); the settle chain, combat, and the return path all key on
--   location_id and never re-check status. So a fleet in flight to (or fighting at) a re-hidden site
--   still arrives, fights, retreats, and returns home with its loot — NOTHING strands server-side.
--   The site merely vanishes from the map read; an in-flight player's movement line points at
--   unlabeled space until the trip resolves. Acceptable for an emergency un-reveal; new sends reject
--   immediately.

begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local idle_in_transaction_session_timeout = '60s';

do $$
declare
  -- The fixed canonical Ember Reach set OWNED by migration 0175. NOT operator-supplied.
  c_gate constant uuid := 'eb000011-0175-4a00-8a00-000000000001';  -- Ember Gate  (bd 40, gate 150)
  c_maw  constant uuid := 'eb000012-0175-4a00-8a00-000000000002';  -- Cinder Maw  (bd 50, gate 220)
  c_furn constant uuid := 'eb000013-0175-4a00-8a00-000000000003';  -- The Furnace (bd 60, gate 300)
  c_zone constant uuid := 'eb000002-0175-4a00-8a00-0000000000b1';  -- zone Ember Reach
  c_sect constant uuid := 'eb000001-0175-4a00-8a00-0000000000a1';  -- sector Ashen Frontier
  v_sites uuid[] := array[c_gate, c_maw, c_furn];
  v_head text;
  v_n int;
  v_hidden_before int;
  v_active_before int;
  v_total_active_before int;
  v_total_active_after  int;
  -- identity-level digest of every NON-canonical location's (id,status) — the offsetting-proof: the
  -- postcondition proves the ONLY rows that changed are the three canonical sites.
  v_other_digest_before text;
  v_other_digest_after  text;
  -- full game_config digest — proves NO flag/knob rode along with a content reveal.
  v_cfg_digest_before text;
  v_cfg_digest_after  text;
  v_src text;
  v_map text;
begin
  -- serialize against any concurrent change to the three canonical rows (locks hold to COMMIT).
  perform 1 from public.locations where id = any(v_sites) order by id for update;

  -- ══ PRECONDITIONS (read-only) ══
  -- 0175 deployed AND recorded (head alone is not enough — 0174 may or may not exist, by design).
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  if v_head is null or v_head < '20260618000175' then
    raise exception 'PRECOND FAIL: migration head % < 20260618000175 (the Ember Reach seed) — deploy it first', coalesce(v_head, '(none)');
  end if;
  if not exists (select 1 from supabase_migrations.schema_migrations where version = '20260618000175') then
    raise exception 'PRECOND FAIL: migration 20260618000175 is not recorded as deployed — nothing to reveal';
  end if;

  -- exactly 3 canonical rows, ALL hidden, none active (a rerun fails closed HERE).
  select count(*),
         count(*) filter (where status = 'hidden'),
         count(*) filter (where status = 'active')
    into v_n, v_hidden_before, v_active_before
    from public.locations where id = any(v_sites);
  if v_n <> 3 then
    raise exception 'PRECOND FAIL: canonical Ember Reach set is not exactly 3 rows (got %)', v_n;
  end if;
  if v_active_before <> 0 then
    raise exception 'PRECOND FAIL: % canonical site(s) already ACTIVE — not the all-hidden pre-reveal baseline; reveal NOT performed (already revealed / rerun)', v_active_before;
  end if;
  if v_hidden_before <> 3 then
    raise exception 'PRECOND FAIL: expected exactly 3 HIDDEN canonical sites (hidden=%, active=%)', v_hidden_before, v_active_before;
  end if;

  -- exact seeded identity (the reveal refuses drifted content) + monotonic gates re-check.
  select count(*) into v_n from public.locations
   where (id, zone_id, name, base_difficulty, reward_tier, activity_type, min_power_required) in (
     (c_gate, c_zone, 'Ember Gate',  40.0, 4, 'hunt_pirates', 150.0),
     (c_maw,  c_zone, 'Cinder Maw',  50.0, 4, 'hunt_pirates', 220.0),
     (c_furn, c_zone, 'The Furnace', 60.0, 5, 'hunt_pirates', 300.0));
  if v_n <> 3 then
    raise exception 'PRECOND FAIL: % of 3 canonical rows match the seeded 0175 identity — content drifted; reconcile before revealing', v_n;
  end if;
  select count(*) into v_n from (
    select min_power_required - lag(min_power_required) over (order by base_difficulty) as d_pow
      from public.locations where id = any(v_sites)
  ) s where s.d_pow <= 0;
  if v_n <> 0 then
    raise exception 'PRECOND FAIL: min_power gates are not strictly monotonic with base_difficulty';
  end if;

  -- ACTIVE parents (a hidden parent would make this reveal an invisible no-op).
  if not exists (select 1 from public.zones where id = c_zone and status = 'active') then
    raise exception 'PRECOND FAIL: zone Ember Reach is not active — the location reveal would be invisible';
  end if;
  if not exists (select 1 from public.sectors where id = c_sect and status = 'active') then
    raise exception 'PRECOND FAIL: sector Ashen Frontier is not active — the location reveal would be invisible';
  end if;

  -- the map read is still the visibility authority: three-level active filter prosrc-pinned.
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.get_world_map()')::oid;
  if v_src is null then
    raise exception 'PRECOND FAIL: public.get_world_map() does not exist';
  end if;
  if position('l.zone_id = z.id and l.status = ''active''' in v_src) = 0
     or position('z.sector_id = se.id and z.status = ''active''' in v_src) = 0
     or position('se.status = ''active''' in v_src) = 0 then
    raise exception 'PRECOND FAIL: get_world_map() no longer filters status=active at all three levels — visibility semantics changed; re-audit before revealing';
  end if;

  -- behavioral pre-check: nothing leaked yet.
  v_map := public.get_world_map()::text;
  if position('Ember Gate' in v_map) > 0 or position('Cinder Maw' in v_map) > 0
     or position('The Furnace' in v_map) > 0 then
    raise exception 'PRECOND FAIL: an Ember Reach site already appears in get_world_map() output';
  end if;

  -- pre-op snapshots for the smoke invariance proofs.
  select count(*) into v_total_active_before from public.locations where status = 'active';
  select md5(coalesce(string_agg(id::text || '=' || status, ',' order by id), ''))
    into v_other_digest_before from public.locations where id <> all(v_sites);
  select md5(coalesce(string_agg(key || '=' || value::text, ',' order by key), ''))
    into v_cfg_digest_before from public.game_config;

  raise notice 'REVEAL_EMBER_PASS_PRECONDITIONS ok: head %, 0175 recorded; 3 canonical rows all hidden, identity exact, gates monotonic; parents active; get_world_map three-level filter pinned; no pre-reveal leak', v_head;

  -- ══ STAGE — THE ONLY WRITE: hidden→active for exactly the three fixed uuids ══
  update public.locations
     set status = 'active'
   where id = any(v_sites) and status = 'hidden';
  get diagnostics v_n = row_count;
  if v_n <> 3 then
    raise exception 'STAGE FAIL: expected exactly 3 rows hidden->active, got % (abort, rolled back)', v_n;
  end if;
  raise notice 'REVEAL_EMBER_PASS_STAGE ok: 3 rows hidden->active (Ember Gate, Cinder Maw, The Furnace)';

  -- ══ SMOKE (read-only) ══
  if (select count(*) from public.locations where id = any(v_sites) and status = 'active') <> 3 then
    raise exception 'SMOKE FAIL: not all 3 canonical sites read back active';
  end if;

  -- net +3 and NOTHING ELSE moved (identity-level invariance — the offsetting-proof).
  select count(*) into v_total_active_after from public.locations where status = 'active';
  if v_total_active_after <> v_total_active_before + 3 then
    raise exception 'SMOKE FAIL: net active-location change = % (expected exactly +3)', v_total_active_after - v_total_active_before;
  end if;
  select md5(coalesce(string_agg(id::text || '=' || status, ',' order by id), ''))
    into v_other_digest_after from public.locations where id <> all(v_sites);
  if v_other_digest_after is distinct from v_other_digest_before then
    raise exception 'SMOKE FAIL: a non-canonical location changed status (identity-level invariance broken)';
  end if;

  -- no flag rode along: game_config byte-identical.
  select md5(coalesce(string_agg(key || '=' || value::text, ',' order by key), ''))
    into v_cfg_digest_after from public.game_config;
  if v_cfg_digest_after is distinct from v_cfg_digest_before then
    raise exception 'SMOKE FAIL: game_config changed during the reveal (a content reveal must never move a flag/knob)';
  end if;

  -- behavioral post-check: the three sites are now IN the map read, and so is their zone.
  v_map := public.get_world_map()::text;
  if position('Ember Gate' in v_map) = 0 or position('Cinder Maw' in v_map) = 0
     or position('The Furnace' in v_map) = 0 or position('Ember Reach' in v_map) = 0 then
    raise exception 'SMOKE FAIL: a revealed site (or zone Ember Reach) is missing from get_world_map() output';
  end if;

  raise notice 'REVEAL_EMBER_PASS_SMOKE ok: 3 active; net +3; non-canonical location statuses invariant; game_config digest unchanged; all three sites live in the map read';
end $$;

select 'EMBER REACH REVEAL PASS — Ember Gate (bd 40, gate 150), Cinder Maw (bd 50, gate 220), The Furnace (bd 60, gate 300) are LIVE on the galaxy map (zone Ember Reach, sector Ashen Frontier, NE beyond Blackden). No client PR needed — the map is data-driven. Manual smoke: three new hostile triangle markers NE of Blackden; the detail panel reads Danger High / Rewards Rich (the client BUCKETS bd>20 and tier>=3 — exact numbers and min_power are NOT rendered anywhere yet; a small client polish to surface them is queued); an under-powered team send rejects power_below_required.' as result;

commit;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- Re-hiding IS supported for hunt sites (unlike the starter-port reveal — no player state anchors to
-- a hunt site). Consideration, thought through (see header): sends validate status at SEND time only;
-- settle/combat/return key on location_id and never re-check status — in-flight and in-combat fleets
-- at a re-hidden site resolve normally and come home with their loot; nothing strands. New sends
-- reject immediately (invalid_location / 'location not found or inactive'). The map merely stops
-- listing the sites; an in-flight movement line points at unlabeled space until the trip resolves.
--
-- begin;
-- update public.locations set status = 'hidden'
--  where id in ('eb000011-0175-4a00-8a00-000000000001',
--               'eb000012-0175-4a00-8a00-000000000002',
--               'eb000013-0175-4a00-8a00-000000000003')
--    and status = 'active';
-- select id, name, status from public.locations
--  where id in ('eb000011-0175-4a00-8a00-000000000001',
--               'eb000012-0175-4a00-8a00-000000000002',
--               'eb000013-0175-4a00-8a00-000000000003') order by name;
-- commit;
