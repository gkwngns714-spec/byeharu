-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0320 — THE KNOBS ARE HONEST
--        (the eight config rows nothing reads are deleted; the three values production holds but
--         no file produces are written into the chain, so a fresh database boots the game that is
--         actually being played)
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- ── WHAT THE OWNER ASKED FOR ────────────────────────────────────────────────────────────────────
--   "easy to set for the game … the code can simply apply simple number then it will be done"
--
-- Tuning by number only works if the numbers are trustworthy. Two things were breaking that, and
-- this migration is the database half of the fix (the tools half is scripts/set-knob.mjs +
-- scripts/list-knobs.mjs):
--   1. EIGHT keys are read by NOTHING. Setting one changes nothing and says nothing. One of them,
--      `combat_variance`, is a second source of truth sitting beside the live
--      `combat_damage_variance_pct` — tune the wrong one and the game does not move.
--   2. THREE live values are produced by NO FILE. A fresh `supabase start` boots a different game
--      than the ~30 players are in, so every disposable proof validates the wrong world.
--
-- ── THIS FILE ENCODES DECISIONS ALREADY TAKEN. IT DECIDES NOTHING. ──────────────────────────────
-- Every value written below is READ OFF PRODUCTION, not chosen here. `mining_extract_radius` is 60
-- because somebody set it to 60; `dev_zone_editor_enabled` is true because the owner turned the
-- editor on; `combat_hit_variance_pct` is 0.5 because 0314's own header names 0.5 as the value that
-- widens the hit spread, and the owner applied it. This migration is transcription, not balance.
-- If a number here looks wrong, the argument is with production, not with this file.
--
-- ── WHAT IS DELIBERATELY *NOT* FOLDED IN ────────────────────────────────────────────────────────
-- Production also differs from the chain on ~28 capability flags flipped by the hand-run
-- `scripts/activate-*.sql` scripts (shipyard, team command, port shop, mining, trade, …). Those are
-- NOT drift and they do NOT belong here. DARK-FIRST is the project's law: every capability ships
-- seeded dark and is lit by an explicit, recorded human GO, one flag at a time, at the owner's pace.
-- The gap between "the chain seeds it dark" and "production has it lit" is that law WORKING — the
-- chain records what shipped, the activation script records the decision to switch it on, and the
-- two are meant to differ. Folding them into the chain would delete the record of the decision and
-- make every future `supabase start` light features nobody has agreed to light. The three values
-- below are a different animal entirely: no script and no migration produces them at all, so there
-- is nothing to preserve and nothing to decide — only a hole to close.
--
-- ── PART 1: THE EIGHT DEAD KEYS ─────────────────────────────────────────────────────────────────
-- Verified against production this session, three independent ways: every `pg_proc.prosrc` body,
-- every view/policy/constraint/default/trigger definition, every `cron.job.command`, and every file
-- under `src/` and `supabase/functions/`. Zero readers each.
--
--   combat_variance                          0.1     0016000003:36 — the M4 damage spread. SUPERSEDED
--                                                    by combat_damage_variance_pct (live 0.10, read
--                                                    by process_combat_ticks). Two knobs for one
--                                                    number is the exact duality NO-SPAGHETTI kills.
--   movement_tick_seconds                    30      0016000003:32 — documents a cron cadence that
--                                                    lives in cron.schedule, not here.
--   worldstate_tick_seconds                  60      0017000032:16 — same shape, same emptiness.
--   worldstate_pressure_drift_per_tick       2       0017000032:21. Its ONE reader was 0032's
--                                                    worldstate_tick (`:77`) — but the live
--                                                    worldstate_tick was re-created since and reads
--                                                    `worldstate_pressure_decay_rate` instead. The
--                                                    migration text still names the old key; the
--                                                    running function does not. Confirmed on prod.
--   max_coordinate_travel_seconds            86400   0018000057:40 — the admission cap for
--                                                    mainship_space_begin_move, DROPPED at
--                                                    0018000232:241.
--   mainship_coordinate_travel_enabled       true    0018000070 — the gate for
--                                                    command_main_ship_space_move, also part of the
--                                                    per-ship coordinate surface 0231/0232 removed.
--                                                    0300 lit it; nothing has ever read it since.
--   typed_zone_mining_runtime_enabled        true    0018000280:111 — the cutover gate for a
--   typed_zone_exploration_runtime_enabled   true    0018000281:74    typed-zone runtime that was
--                                                    never built. 0300 lit BOTH. A gate reading
--                                                    `true` in front of nothing is worse than no
--                                                    gate: the day someone wires that runtime it
--                                                    goes live with no decision behind it.
--
-- KEPT ON PURPOSE — `mainship_space_movement_enabled`. No production FUNCTION reads it either, but
-- the CLIENT does, at `src/lib/catalog.ts:115`. Deleting it would dark a live client capability.
-- This is why the deletion guard below checks the client too, not just pg_proc.
--
-- ── PART 2: THE THREE VALUES NO FILE PRODUCES ───────────────────────────────────────────────────
--   mining_extract_radius              chain 750 (0018000102:48)  -> PROD 60
--   dev_zone_editor_enabled            chain false (0018000238:26) -> PROD true
--   combat_hit_variance_pct            NOT IN THE CHAIN AT ALL     -> PROD 0.5
--
-- The third is the dangerous one. 0314 reads it as
-- `coalesce(cfg_num('combat_hit_variance_pct'), v_var_pct)` (0018000314:171) where v_var_pct is
-- combat_damage_variance_pct = 0.10. So the row's ABSENCE is not neutral — it silently reverts every
-- hit in the game from a +/-50% roll to +/-10%. A row that exists in no file is one `delete` away
-- from re-tuning combat by a factor of five, and nobody would know where it went. It gets a seed and
-- a description here.
--
-- ── CLAIMS THAT WERE CHECKED AND FOUND FALSE (recorded so nobody re-opens them) ─────────────────
-- `location_investment_enabled`, `module_range_attributes_enabled` and `per_ship_targeting_enabled`
-- were reported as chain-false / prod-true drift. They are NOT drift: `0018000300_lights_on.sql`
-- names all three in its lit array (`:49`, `:53`, `:77`) and sets them true, then ASSERTS them true
-- (`:160-183`). A fresh chain produces `true` for each, matching production exactly. Nothing to fix,
-- so nothing is written for them here.
--
-- ── EXACTLY-ONCE / FAIL-CLOSED ─────────────────────────────────────────────────────────────────
-- Every write is guarded on the exact expected OLD value, the idiom 0018000316:306-380 uses. A
-- re-apply, or an apply against a world that has since moved on, updates nothing — and the
-- self-asserts then check the RESULT rather than the write, so a legitimate later retune by the
-- owner is never clobbered and never fails this file.
--
-- Every DELETE carries a stronger guard than a value: it refuses to run at all if any function in
-- the database mentions the key. A value guard would only prove the value had not changed; the
-- reader guard proves the property that makes deletion SAFE, and it keeps proving it if some future
-- migration wires one of these keys up.
--
-- ── WHAT THIS FILE DOES NOT TOUCH ──────────────────────────────────────────────────────────────
-- No DDL, no function re-create, no grant change, no table other than public.game_config.
--
-- ── HAND-OFF: THE STALE `coalesce` DEFAULTS STILL LIVING INSIDE FUNCTION BODIES ─────────────────
-- A knob's in-body fallback is a SECOND value for the same number, and every one of these has
-- drifted off the live row. They only fire when the row is missing — which is exactly the moment
-- nobody is watching, and exactly what this migration's DELETE half makes thinkable. Deleting a
-- config row today does not restore a sane default; it jumps the arena scale by up to 30x.
--
-- Every literal below was read off PRODUCTION's own `pg_proc.prosrc` (2026-08-03), not off the
-- chain, so this list is what is actually running. It is NOT fixed here because each one requires
-- re-creating a live combat/economy function, and four of them are being rewritten in parallel
-- slices right now. Each is a one-literal change, and the correct new value is the LIVE value.
--
--   function                        literal in the body                                    -> live
--   process_combat_ticks            coalesce(cfg_num('enemy_synthetic_range_base'),120)     -> 3.6
--                                   coalesce(cfg_num('enemy_synthetic_range_per_difficulty'),5)
--                                                                                          -> 0.04
--                                   coalesce(cfg_num('enemy_synthetic_speed_base'),3)       -> 0.6
--                                   coalesce(cfg_num('enemy_synthetic_speed_per_difficulty'),0.2)
--                                                                                          -> 0.04
--                                   coalesce(cfg_num('enemy_synthetic_projectile_speed'),250)
--                                                                                          -> 50
--                                   coalesce(cfg_num('combat_tick_seconds'), 3)             -> 3 ok
--                                   coalesce(cfg_num('combat_damage_variance_pct'), 0.10)   -> 0.10 ok
--       TRUE HEAD of that body: 0018000299:694-708 (resolved arm) and :756-760 (synthetic arm);
--       0310-0316 patch it by text substitution, so the literals still live in 0299's text.
--   combat_create_group_encounter   coalesce(public.cfg_num('combat_player_fallback_weapon_range'), 150)
--                                                                                          -> 5
--                                   coalesce(public.cfg_num('combat_player_fallback_weapon_projectile_speed'), 300)
--                                                                                          -> 60
--                                   coalesce(public.cfg_num('spatial_formation_ring_radius'), 30)
--                                                                                          -> 6
--       TRUE HEAD: 0018000301:661-862, fallback block :791-802 (0301:794 is the range literal),
--       carried through 0308's hunk-2 rewrite and 0315.
--   mining_extract                  coalesce(public.cfg_num('mining_extract_radius'), 750)  -> 60
--   wallet_ensure                   coalesce(cfg_num('starting_credits'), 0)                -> 1000
--   movement_create                 coalesce(cfg_num('min_travel_seconds'), 1.0)            -> 5
--   pirate_loot_for_wave            coalesce(cfg_num('blueprint_fragment_drop_rate'), 0)    -> 0.15
--   calculate_expedition_stats      coalesce(cfg_num('captain_level_bonus_per_level'), 0)   -> 0.10
--   command_ship_group_go           coalesce(cfg_num('max_active_fleets'), 3)               -> 6
--   send_fleet_to_location          (same literal)                                          -> 6
--   send_ship_group_hunt            (same literal)                                          -> 6
--   pirate_intercept_compute_risk   coalesce(cfg_num('pirate_intercept_base_risk'), 0.35)   -> 1.0
--                                   coalesce(cfg_num('pirate_intercept_exposure_floor'), 0.15)
--                                                                                          -> 1.0
--                                   coalesce(cfg_num('pirate_intercept_max_risk'), 0.9)     -> 1.0
--                                   coalesce(cfg_num('pirate_intercept_min_risk'), 0.02)    -> 0.98
--   typed_zone_pirate_candidates_v1 (the same four intercept literals)
--   zone_effect_set                 coalesce(cfg_num('pirate_intercept_max_risk'), 0.90)    -> 1.0
--                                   coalesce(cfg_num('pirate_intercept_min_risk'), 0.02)    -> 0.98
--
-- The clean end state is no in-body literal at all: a knob that must exist should be asserted at
-- apply time (this file's pattern) rather than defaulted at read time, so a missing row FAILS
-- LOUDLY instead of quietly changing the game.
--
-- The CLIENT half of the same disease IS fixed in this slice:
-- src/features/map/useGalaxyMapData.ts (DEFAULT_MINING_EXTRACT_RADIUS 750 -> 60) and
-- src/features/worldeditor/miningValidation.ts (MINING_FIELD_OVERLAP_RADIUS_FALLBACK 750 -> 60),
-- with tests/miningValidation.spec.ts repointed. src/features/worldeditor/explorationValidation.ts
-- was reported as the same defect and is NOT: its fallback is 750 and production's
-- `exploration_scan_radius` is 750, so it already agrees and was left alone.
--
-- ── KNOWN CONSEQUENCES OF THE DELETES, STATED RATHER THAN DISCOVERED ────────────────────────────
-- Two of the eight keys are still NAMED by a dormant harness. The full list, so the next person
-- inherits the truth rather than re-derives it:
--
--   `max_coordinate_travel_seconds` — asserted to be 86400 by
--     scripts/osn3-anchor1a-realchain-fixtures.sql:283-287, osn3-s3-realchain-fixtures.sql:315/328/
--     375-379, osn3-s3-realchain-perm.sql:100-104, osn3-s3-live-inspect.sql:104-107,
--     osn3-s4-realchain-{fixtures:267-271,perm:89-92}, osn3-s5-realchain-{fixtures:271-275,perm:82-84},
--     osn3-s6a-realchain-{fixtures:287-291,perm:82-84}, osn3-legacy-send-live-check.sh:92-95,
--     osn3-s3-live-spotcheck.sh:67-71.
--   `mainship_coordinate_travel_enabled` — asserted to be false, or written, by
--     scripts/activate-coordinate-travel.sql:146-205, activate-unified-movement.sql:162/249/268/282,
--     osn-coord-enable-1b-readiness-proof.sql:25/111/123/132/238-240, osn-postenable-verify.sql:48-67,
--     port-entry-1-proof.sql:261, port-entry-1-production-verify.sql:133-136,
--     verify-0272-postdeploy.sql:312, and .github/workflows/osn-postenable-verify-proof.yml:79.
--
-- EVERY ONE OF THEM IS ALREADY DEAD OR ALREADY WRONG, before this migration touches anything:
--   • the osn3-* set drives `mainship_space_begin_move`, DROPPED at 0018000232:241, so those proofs
--     cannot run to completion on this chain regardless of any config row;
--   • every check that asserts `mainship_coordinate_travel_enabled = false` contradicts production,
--     where 0018000300 set it TRUE — verified against the live database 2026-08-03.
--
-- AND NONE OF THEM GATES ANYTHING. Their workflows were enumerated: osn3-*-realchain-proof.yml fire
-- on `osn3-**`, osn-postenable-verify-proof.yml on `osn-coord-verify-proof-**`,
-- osn-coord-enable-1b-readiness-proof.yml on `osn-coord-enable-**`, port-entry-1-*.yml on
-- `port-entry-1-**`, verify-0272-postdeploy-proof.yml on `slice-0272-postdeploy**`, and the rest are
-- workflow_dispatch only. Not one fires on `main`, on `pull_request`, or on `slice-**`.
-- scripts/activate-coordinate-travel.sql and activate-unified-movement.sql are hand-run and named by
-- no workflow at all.
--
-- `typed_zone_{mining,exploration}_runtime_enabled` are read once more, at
-- scripts/activate-typed-zone-authoring.sql:79-80, through `coalesce(cfg_bool(...), false)`.
-- `cfg_bool` already answers false for a key that does not exist, so deletion gives that guard the
-- SAME answer it gets today from a false row — the safe branch. No change there.
--
-- Retiring that whole dead OSN-3 per-ship harness — 9 workflows, ~14 scripts, and the two activate-*
-- scripts — is its own slice with its own blast radius, and is NOT smuggled in here.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ── 0. PRECONDITIONS — refuse to delete anything a reader could still be looking at ─────────────
do $pre$
declare
  v_key   text;
  v_fns   text;
  v_dead  text[] := array[
    'combat_variance',
    'movement_tick_seconds',
    'worldstate_tick_seconds',
    'worldstate_pressure_drift_per_tick',
    'max_coordinate_travel_seconds',
    'mainship_coordinate_travel_enabled',
    'typed_zone_mining_runtime_enabled',
    'typed_zone_exploration_runtime_enabled'
  ];
begin
  -- (a) THE GUARD THAT MATTERS. Absence of a reader is the whole reason these rows may go. Prove it
  --     here, at apply time, against the functions that actually exist — not against a grep taken
  --     on somebody's laptop weeks ago. If a later migration ever wires one of these keys up, this
  --     aborts instead of quietly deleting the config it now depends on.
  foreach v_key in array v_dead loop
    select string_agg(p.proname, ', ' order by p.proname) into v_fns
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname not in ('pg_catalog', 'information_schema')
       and strpos(p.prosrc, v_key) > 0;
    if v_fns is not null then
      raise exception '0320 PRECONDITION FAIL: % is NOT dead — read by: %', v_key, v_fns;
    end if;
  end loop;

  -- (b) the same for views, row policies, check constraints and column defaults — the other places
  --     in a database where a string can be a dependency. `cron.job.command` is deliberately NOT
  --     queried here: pg_cron is not installed on the disposable `supabase start` stack, so reading
  --     it would abort the apply-proof on every branch. It was checked against production by hand
  --     instead (2026-08-03: zero hits for all eight keys), and the two cron-cadence keys among them
  --     could not be read from a cron command anyway — a schedule lives in cron.schedule's own
  --     argument, which is why those two rows are dead in the first place.
  foreach v_key in array v_dead loop
    if exists (select 1 from pg_views v
                where v.schemaname not in ('pg_catalog','information_schema')
                  and strpos(v.definition, v_key) > 0) then
      raise exception '0320 PRECONDITION FAIL: % is referenced by a view', v_key;
    end if;
    if exists (select 1 from pg_policy pol
                where strpos(coalesce(pg_get_expr(pol.polqual, pol.polrelid), ''), v_key) > 0
                   or strpos(coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), ''), v_key) > 0) then
      raise exception '0320 PRECONDITION FAIL: % is referenced by a row policy', v_key;
    end if;
    if exists (select 1 from pg_constraint c
                where strpos(coalesce(pg_get_constraintdef(c.oid), ''), v_key) > 0) then
      raise exception '0320 PRECONDITION FAIL: % is referenced by a constraint', v_key;
    end if;
    if exists (select 1 from pg_attrdef d
                where strpos(pg_get_expr(d.adbin, d.adrelid), v_key) > 0) then
      raise exception '0320 PRECONDITION FAIL: % is referenced by a column default', v_key;
    end if;
  end loop;

  -- (c) the one key that LOOKS like the others and must survive. mainship_space_movement_enabled has
  --     no server reader either, so any rule phrased as "no pg_proc hit => delete" would take it —
  --     and dark the client capability at src/lib/catalog.ts:115. Asserting its presence here makes
  --     that mistake impossible to make silently in a later edit of this file.
  if not exists (select 1 from public.game_config where key = 'mainship_space_movement_enabled') then
    raise exception '0320 PRECONDITION FAIL: mainship_space_movement_enabled is absent — it is CLIENT-read (src/lib/catalog.ts:115) and must never be deleted';
  end if;

  raise notice '0320 PRECONDITIONS OK: 8 keys carry no reader anywhere in the database; the client-read key is present';
end $pre$;

-- ── 1. THE DEAD KEYS GO ─────────────────────────────────────────────────────────────────────────
-- No value guard: for a key nothing reads, the value is not a fact worth protecting. The reader
-- guard above is the precondition, and the count assert below is the effect check.

delete from public.game_config
 where key in (
   'combat_variance',                        -- second source of truth beside combat_damage_variance_pct
   'movement_tick_seconds',                  -- a cron cadence that lives in cron.schedule
   'worldstate_tick_seconds',                -- same
   'worldstate_pressure_drift_per_tick',     -- the live worldstate_tick reads _decay_rate instead
   'max_coordinate_travel_seconds',          -- gate for a function dropped at 0232:241
   'mainship_coordinate_travel_enabled',     -- gate for the same removed coordinate surface
   'typed_zone_mining_runtime_enabled',      -- cutover gate for a runtime that was never built
   'typed_zone_exploration_runtime_enabled'  -- same
 );

-- ── 2. THE CHAIN CATCHES UP WITH PRODUCTION (guarded on the exact old values) ────────────────────

-- The world map is not the combat arena: 0316 divided every combat distance by 5 and deliberately
-- left this one alone (0018000316:131-135). 60 is what the world actually uses.
update public.game_config
   set value = '60'::jsonb,
       updated_at = now()
 where key = 'mining_extract_radius' and value = '750'::jsonb;

-- The owner uses the editor. A chain that seeds it dark makes every disposable proof boot a database
-- where the owner's own authoring route renders nothing.
update public.game_config
   set value = 'true'::jsonb,
       updated_at = now()
 where key = 'dev_zone_editor_enabled' and value = 'false'::jsonb;

-- The key that exists nowhere in the chain. The VALUE is seed-only — on conflict the stored value
-- wins, so production's 0.5 and any later owner retune are both untouched. The DESCRIPTION is
-- backfilled, and only when it is missing: production's row was minted by a bare UPSERT and carries
-- description NULL, which is precisely the state that makes a knob unfindable. Filling it is not a
-- balance change, and the `where description is null` clause makes it impossible to overwrite a
-- description somebody wrote later.
insert into public.game_config (key, value, description)
values (
  'combat_hit_variance_pct',
  '0.5'::jsonb,
  'RS-FEEL (0314): per-hit damage roll spread. Every landed hit rolls uniformly in '
  '[power * (1 - this), power * (1 + this)], mean unchanged, so a fight reads as a stream of '
  'different numbers instead of one repeated number. Read as '
  'coalesce(cfg_num(''combat_hit_variance_pct''), cfg_num(''combat_damage_variance_pct'')) at '
  '0314:171 — DELETING THIS ROW does not disable the roll, it silently narrows it to the damage '
  'variance (0.10). It is a SPREAD, not a damage multiplier: raising it makes hits swingier, never '
  'stronger on average. Distinct from combat_damage_variance_pct, which varies the whole tick.'
)
on conflict (key) do update
   set description = excluded.description
 where public.game_config.description is null;

-- ── 3. SELF-ASSERT (deploy-time; a raise aborts the migration txn — nothing half-applies) ───────
-- Every check reads the RESULT, never the write. That is what makes the file re-appliable over a
-- later owner retune: it asserts the state the game needs, not the transition this file happened to
-- make.
do $post$
declare
  v_key   text;
  v_left  text[] := '{}';
  v_dead  text[] := array[
    'combat_variance',
    'movement_tick_seconds',
    'worldstate_tick_seconds',
    'worldstate_pressure_drift_per_tick',
    'max_coordinate_travel_seconds',
    'mainship_coordinate_travel_enabled',
    'typed_zone_mining_runtime_enabled',
    'typed_zone_exploration_runtime_enabled'
  ];
  v_val   jsonb;
begin
  -- (a) all eight gone
  foreach v_key in array v_dead loop
    if exists (select 1 from public.game_config where key = v_key) then
      v_left := v_left || v_key;
    end if;
  end loop;
  if array_length(v_left, 1) is not null then
    raise exception '0320 ASSERT (a) FAIL: dead key(s) still present: %', array_to_string(v_left, ', ');
  end if;

  -- (b) the client-read look-alike survived, and still carries a jsonb boolean
  select value into v_val from public.game_config where key = 'mainship_space_movement_enabled';
  if v_val is null then
    raise exception '0320 ASSERT (b) FAIL: mainship_space_movement_enabled was deleted — it is CLIENT-read (src/lib/catalog.ts:115)';
  end if;
  if jsonb_typeof(v_val) <> 'boolean' then
    raise exception '0320 ASSERT (b) FAIL: mainship_space_movement_enabled is not a jsonb boolean (got %)', jsonb_typeof(v_val);
  end if;

  -- (c) combat has exactly ONE damage-spread authority left. This is the NO-SPAGHETTI half of the
  --     slice: deleting combat_variance is only a fix if nothing re-creates it.
  if exists (select 1 from public.game_config where key = 'combat_variance') then
    raise exception '0320 ASSERT (c) FAIL: combat_variance is back — combat_damage_variance_pct is the one authority';
  end if;
  if not exists (select 1 from public.game_config where key = 'combat_damage_variance_pct') then
    raise exception '0320 ASSERT (c) FAIL: combat_damage_variance_pct is absent — the surviving authority must exist';
  end if;

  -- (d) the three catch-up values are present, right-typed and sane. Ranges, not equalities, so a
  --     later deliberate retune by the owner passes this file on re-apply.
  select value into v_val from public.game_config where key = 'mining_extract_radius';
  if v_val is null or jsonb_typeof(v_val) <> 'number' then
    raise exception '0320 ASSERT (d) FAIL: mining_extract_radius missing or not a number';
  end if;
  if (v_val #>> '{}')::double precision = 750 then
    raise exception '0320 ASSERT (d) FAIL: mining_extract_radius is still the chain seed 750 — the catch-up update did not land';
  end if;

  select value into v_val from public.game_config where key = 'dev_zone_editor_enabled';
  if v_val is null or jsonb_typeof(v_val) <> 'boolean' then
    raise exception '0320 ASSERT (d) FAIL: dev_zone_editor_enabled missing or not a boolean';
  end if;
  -- Same shape as the mining check above: assert the CHAIN SEED is gone, not a literal value. On a
  -- fresh chain 0238 leaves it false and the guarded update above must have moved it, so a false
  -- here means the update matched nothing and the drift silently survived — which is the exact
  -- failure a guarded update can hide.
  if v_val = 'false'::jsonb then
    raise exception '0320 ASSERT (d) FAIL: dev_zone_editor_enabled is still the chain seed false — the catch-up update did not land';
  end if;

  select value into v_val from public.game_config where key = 'combat_hit_variance_pct';
  if v_val is null then
    raise exception '0320 ASSERT (d) FAIL: combat_hit_variance_pct is absent — its absence silently narrows every hit roll to combat_damage_variance_pct (0314:171)';
  end if;
  if jsonb_typeof(v_val) <> 'number' then
    raise exception '0320 ASSERT (d) FAIL: combat_hit_variance_pct is not a number (got %)', jsonb_typeof(v_val);
  end if;
  if (v_val #>> '{}')::double precision < 0 or (v_val #>> '{}')::double precision > 1 then
    raise exception '0320 ASSERT (d) FAIL: combat_hit_variance_pct % is outside [0,1] — a spread above 1 rolls negative damage', (v_val #>> '{}')::double precision;
  end if;
  if (select description from public.game_config where key = 'combat_hit_variance_pct') is null then
    raise exception '0320 ASSERT (d) FAIL: combat_hit_variance_pct still has no description — a row with no description is a row a bare UPSERT minted';
  end if;

  -- (e) nothing outside game_config moved. This file is config-only by construction; the assert is
  --     here so a later edit that reaches for a function re-create fails loudly instead of quietly
  --     becoming a different kind of migration.
  if to_regprocedure('public.set_game_config(text, jsonb)') is null then
    raise exception '0320 ASSERT (e) FAIL: public.set_game_config(text, jsonb) is absent — the owned config writer must survive this migration';
  end if;

  raise notice '0320 SELF-ASSERT PASS: 8 unread keys deleted (combat now has ONE damage-spread authority), and the chain reproduces production for mining_extract_radius, dev_zone_editor_enabled and combat_hit_variance_pct — a fresh database now boots the game that is being played';
end $post$;

commit;
