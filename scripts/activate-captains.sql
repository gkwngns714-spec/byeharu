-- CAPTAINS ACTIVATION — the captains FAST-FOLLOW flip (docs/TEAM_ACTIVATION_PACKET.md §3,
-- Decision 3 APPROVED 2026-07-12; docs/TEAM_COMMAND.md → ACTIVATION CHECKLIST items 2/①-④).
-- Teams launched UNCAPTAINED on 2026-07-12; this script is the second window that lights captains.
--
-- ██ HUMAN ACTIVATION TOOL ██ — run BY THE HUMAN, deliberately, against prod. NOT CI; nothing
-- flips at build/deploy time. Each run of this file IS the recorded human go decision.
--
-- ── WHAT IT DOES (one transaction; COMMIT only if every assert passes) ───────────────────────────
--   PRECONDITIONS (no write until these hold):
--     • migration head >= 20260618000171 (the captains-launch prep migration is deployed);
--     • the pinned slot bump REALLY applied: every hull row has base_captain_slots = 6, and the
--       instance backfill is complete (no ship's captain_slots below its hull's value);
--     • every config key this script writes already exists (no typo can invent a key).
--   STAGE 1 — the economy knob (reversible one-liner, set_game_config):
--     • captain_shard_drop_rate  0 → 0.15  (the 0171 drop source goes LIVE: each cleared pirate
--       wave from wave 2 onward has a 15% chance of 1 captain_memory_shard — the packet-F5 fix;
--       every recruit recipe costs exactly 1 shard (0125). Launch-conservative and TUNABLE: to
--       retune later, one set_game_config write, no deploy.)
--   STAGE 2 — the switch (packet §3: both captain flags together, or recruiting stays dead — F5):
--     1. captain_assignment_enabled  → true  (assign/unassign/roster RPCs light: 0120/0123; the
--        0122 adapter's captain fold becomes reachable through every stat surface)
--     2. captain_progression_enabled → true  (recruit_captain lights: 0126 — the shard consumer)
--   STAGE 3 — smoke asserts (read-only): committed cfg values; the captain RPC surface exists
--     (5 client RPCs + the 3 internal writers + the 0171 loot leaf); captain_types catalog
--     non-empty with EVERY type recruitable (has recipe rows — the F5 dead-end can't recur);
--     slot-bump sanity re-select. Emits ACTIVATE_CAPTAINS_PASS_* markers per stage and one final
--     PASS line; any failed assert RAISES → the whole transaction rolls back → NOTHING is applied.
--
-- IDEMPOTENT: safe to re-run — every write is a set_game_config upsert to the same target value.
--
-- ── NO CLIENT PR IS NEEDED (verified 2026-07-12, this slice) ─────────────────────────────────────
--   Every captain surface is SERVER-LIT, not compile-gated — each renders null unless
--   get_my_captain_instances answers {ok:true}, which it does the moment stage 2 commits:
--     • CaptainsPanel (ShipScreen)          — isServerLit(roster) gate, CaptainsPanel.tsx:83;
--     • RecruitCaptainPanel (ShipScreen)    — isServerLit(roster) gate, RecruitCaptainPanel.tsx:82
--       (visibility rides the assignment-lit roster read; the recruit COMMAND is separately
--       authoritative on captain_progression_enabled — both flip here, so no dead affordance);
--     • TeamMemberCaptains (team roster)    — rendered by TeamRosterPanel only when
--       isServerLit(captainRoster) (TeamRosterPanel.tsx:144), and TeamRosterPanel is ALREADY
--       mounted (TEAM_COMMAND_ENABLED compiled true since the 2026-07-12 team launch).
--   There is NO captain compile-time constant in osnReleaseGates.ts. The server flip alone
--   mounts everything. (The "Captain seats 2 → 6" label already moved at the 0171 deploy —
--   cosmetic while dark; this flip makes the seats real.)
--
-- ── WHAT IT DELIBERATELY DOES NOT TOUCH ──────────────────────────────────────────────────────────
--   • team_command_enabled / mainship_additional_commission_enabled / module_* — already LIVE
--     (the 2026-07-12 team activation); this script never rewrites them.
--   • base_captain_slots / captain_slots — the bump is MIGRATION 0171's (already a precondition
--     here), never a script write. Any table other than game_config. Any DDL. Any migration.
--
-- ── INVOCATION (Management-API compatible: NO psql meta-commands; one BEGIN..COMMIT) ─────────────
--   psql "<prod session-pooler conn (pinned CA, sslmode=verify-full)>" -X -v ON_ERROR_STOP=1 \
--        -f scripts/activate-captains.sql
--   Or paste this whole file into the Supabase Dashboard SQL editor / run it through the
--   management-API runner (it contains no backslash commands to strip), or:
--     bash scripts/activate-captains.sh run ACTIVATE_CAPTAINS      # DB_URL required
--   AFTER a green run: scripts/team-command-proof.sh against a disposable FRESH-migration chain (dark seeds — the proof lights flags in-txn itself; it hard-fails on lit config by design), plus
--   the manual smoke: hunt past wave 2 with the rate visible → shard drops → recruit a captain →
--   assign to a team member → the C0 preview / D0 totals move by the captain's stats.
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
--   See the marked ROLLBACK section at the BOTTOM (commented out). Flags + the rate knob are fully
--   reversible (assignments/instances persist server-side; surfaces just go dark again — the
--   reject-before-read gates are the authority). NEVER lower base_captain_slots / captain_slots
--   once captains occupy slots 3–6: the 0122 adapter refuses over-capacity and every stat surface
--   would poison to stats_invalid (packet §3/§6). Roll back FLAGS, never slots.

begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local idle_in_transaction_session_timeout = '60s';

-- ══════════ PRECONDITIONS (read-only; no write happens unless all pass) ══════════
do $$
declare
  v_head text; n int; v_missing text;
begin
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  if v_head is null or v_head < '20260618000171' then
    raise exception 'PRECONDITION FAIL: migration head % < 20260618000171 — deploy the captains-launch prep migration first', coalesce(v_head, '(none)');
  end if;

  -- the pinned bump really applied: EVERY hull at 6 seats…
  select count(*) into n from public.main_ship_hull_types where base_captain_slots is distinct from 6;
  if n <> 0 then
    raise exception 'PRECONDITION FAIL: % hull row(s) without base_captain_slots = 6 (the 0171 bump)', n;
  end if;
  -- …and the instance backfill complete: no ship below its hull's seat count.
  select count(*) into n
    from public.main_ship_instances i
    join public.main_ship_hull_types h on h.hull_type_id = i.hull_type_id
   where i.captain_slots < h.base_captain_slots;
  if n <> 0 then
    raise exception 'PRECONDITION FAIL: % ship(s) with captain_slots below the hull value (the 0171 backfill)', n;
  end if;

  -- every key this script writes must already exist (refuse to invent config rows via a typo).
  select string_agg(k, ', ') into v_missing
    from unnest(array['captain_shard_drop_rate','captain_assignment_enabled','captain_progression_enabled']) k
    where not exists (select 1 from public.game_config g where g.key = k);
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: game_config key(s) missing: %', v_missing;
  end if;

  raise notice 'ACTIVATE_CAPTAINS_PASS_PRECONDITIONS ok: head %, hulls at 6 seats, backfill complete, all 3 config keys present', v_head;
end $$;

-- ══════════ STAGE 1 — the shard-drop knob (the 0171 drop source goes live) ══════════
do $$
declare v_before text;
begin
  select value::text into v_before from public.game_config where key = 'captain_shard_drop_rate';
  perform public.set_game_config('captain_shard_drop_rate', '0.15'::jsonb);
  raise notice 'stage 1: captain_shard_drop_rate % -> 0.15', v_before;

  raise notice 'ACTIVATE_CAPTAINS_PASS_STAGE1 ok: captain_shard_drop_rate=0.15';
end $$;

-- ══════════ STAGE 2 — the switch (packet §3: BOTH captain flags, or recruiting stays dead) ══════════
do $$
declare v_before text; k text;
begin
  foreach k in array array['captain_assignment_enabled',   -- 2.1 assign/roster surfaces light (0120/0123)
                           'captain_progression_enabled'] loop -- 2.2 recruiting lights (0126 — the shard consumer)
    select value::text into v_before from public.game_config where key = k;
    perform public.set_game_config(k, 'true'::jsonb);
    raise notice 'stage 2: % % -> true', k, v_before;
  end loop;
  raise notice 'ACTIVATE_CAPTAINS_PASS_STAGE2 ok: captain assignment + progression enabled';
end $$;

-- ══════════ STAGE 3 — smoke asserts (read-only) ══════════
do $$
declare
  n int; k text; v text; fn text;
begin
  -- (a) committed cfg values are exactly the activation state.
  for k, v in select * from (values
      ('captain_assignment_enabled',  'true'),
      ('captain_progression_enabled', 'true'),
      ('captain_shard_drop_rate',     '0.15')) t(key, want) loop
    if (select value #>> '{}' from public.game_config where key = k) is distinct from v then
      raise exception 'SMOKE FAIL: % is % (want %)', k, (select value #>> '{}' from public.game_config where key = k), v;
    end if;
  end loop;
  if not public.cfg_bool('captain_assignment_enabled') then
    raise exception 'SMOKE FAIL: cfg_bool(captain_assignment_enabled) still false'; end if;
  if not public.cfg_bool('captain_progression_enabled') then
    raise exception 'SMOKE FAIL: cfg_bool(captain_progression_enabled) still false'; end if;

  -- (b) the whole captain surface exists (the 5 client RPCs + the 3 internal writers + the 0171
  --     loot leaf). Existence, not execution — the behavior proof is scripts/team-command-proof.sh
  --     (CAPTAINS + SHARDDROP blocks), run separately.
  foreach fn in array array[
    'public.assign_captain_to_ship(text, uuid, uuid, text)',   -- DECKS-1: + p_station (0189 drop-then-create)
    'public.unassign_captain_from_ship(text, uuid)',
    'public.recruit_captain(text, text)',
    'public.get_my_captain_instances()',
    'public.get_my_ship_captains(uuid)',
    'public.captains_mint_instance(uuid, text, text)',
    'public.captain_assign_apply(uuid, uuid, uuid, text)',     -- DECKS-1: + p_station (0189 drop-then-create)
    'public.production_recruit_captain(uuid, text, text)',
    'public.pirate_loot_for_wave(integer, numeric)'] loop
    if to_regprocedure(fn) is null then
      raise exception 'SMOKE FAIL: function % does not exist', fn; end if;
  end loop;

  -- (c) the catalog is non-empty and EVERY captain type is recruitable (has recipe rows) — the
  --     packet-F5 dead-end (a lit recruit surface with no path to a shard/recipe) cannot recur.
  select count(*) into n from public.captain_types;
  if n < 1 then raise exception 'SMOKE FAIL: captain_types catalog is empty'; end if;
  raise notice 'smoke: captain_types rows = %', n;
  select count(*) into n from public.captain_types t
    where not exists (select 1 from public.captain_recipe_ingredients r where r.captain_type_id = t.id);
  if n <> 0 then raise exception 'SMOKE FAIL: % captain type(s) without a recruit recipe', n; end if;
  select count(*) into n from public.captain_recipe_ingredients where item_id = 'captain_memory_shard';
  if n < 1 then raise exception 'SMOKE FAIL: no recipe consumes captain_memory_shard (economy loop broken)'; end if;

  -- (d) one cheap sanity select (exists + selectable; count is FYI — likely 0 at flip time).
  select count(*) into n from public.captain_instances;
  raise notice 'smoke: captain_instances rows = %', n;

  raise notice 'ACTIVATE_CAPTAINS_PASS_SMOKE ok: 3 cfg values, 9 functions present, catalog recruitable, shard economy closed';
end $$;

select 'CAPTAINS ACTIVATION PASS — captains LIVE (assignment + recruiting + shard drops). NO client PR is needed: every captain surface (CaptainsPanel, RecruitCaptainPanel, TeamMemberCaptains) is server-lit via get_my_captain_instances and mounts automatically. Next: scripts/team-command-proof.sh against a disposable clone + the manual smoke (hunt past wave 2 -> shard -> recruit -> assign -> preview/totals move).' as result;

commit;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- To dark the captain surfaces again, run the reverse writes below (uncomment, run once). Notes:
--   • Fully reversible: recruited instances + assignments PERSIST server-side (harmless — every
--     read/command surface reject-before-reads on the flags, and the client surfaces fail closed
--     to null on the captain_assignment_disabled envelope).
--   • captain_shard_drop_rate 0 stops all new drops immediately; already-carried/deposited shards
--     persist (they are ordinary inventory).
--   • NEVER lower base_captain_slots / captain_slots (not this script's writes anyway): once
--     captains occupy slots 3–6 the 0122 adapter would refuse over-capacity -> stats_invalid
--     everywhere. Roll back FLAGS, never slots.
--
-- begin;
-- select public.set_game_config('captain_assignment_enabled',  'false'::jsonb);
-- select public.set_game_config('captain_progression_enabled', 'false'::jsonb);
-- select public.set_game_config('captain_shard_drop_rate',     '0'::jsonb);
-- select key, value from public.game_config
--  where key in ('captain_assignment_enabled','captain_progression_enabled','captain_shard_drop_rate')
--  order by key;
-- commit;
