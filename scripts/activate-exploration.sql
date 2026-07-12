-- EXPLORATION ACTIVATION — the Phase-11 flip (docs/TEAM_ACTIVATION_PACKET.md §7 "the exploration
-- flip (can go first)", decision row "Exploration (independent) → Flip first" ✅ GO 2026-07-12).
--
-- ██ HUMAN ACTIVATION TOOL ██ — run BY THE HUMAN, deliberately, against prod. NOT CI; nothing
-- flips at build/deploy time. Each run of this file IS the recorded human go decision.
--
-- ── WHAT IT DOES (one transaction; COMMIT only if every assert passes) ───────────────────────────
--   PRECONDITIONS (no write until these hold):
--     • migration head >= 20260618000172 AND 0172 (the exploration/mining writer reconcile) is
--       actually recorded in supabase_migrations.schema_migrations. 0172 is a HARD gate because it
--       fixes the H1 launch-blocker: 0146's stale-body re-create had dropped the 0100 main_ship_id
--       from the discoveries insert, so securing fell to mainship_resolve_owned_ship(player, null)
--       — which resolves ONLY for single-ship owners (0081) — and with multi-ship commissioning
--       LIVE, any 2+-ship player's discoveries would have stranded FOREVER;
--     • the 5 seeded exploration sites (0098) exist AND are is_active;
--     • every active site bundle draws only catalog item ids (reward_grant validation is
--       catalog-driven — a missing id would silently skip that item on deposit);
--     • the MERGED writer is LIVE, not just recorded: the 0098 unique (player_id, site_id)
--       constraint exists by name, and the DEPLOYED exploration_scan body (pg_proc.prosrc) carries
--       BOTH the 0146 unique_violation handler AND the 0172-restored insert column list
--       'pending_bundle_json, main_ship_id' — the flip physically cannot run against the broken
--       writer;
--     • the config keys exist (no typo can invent a key): exploration_enabled (the ONE key this
--       script writes) + exploration_scan_radius (READ-ONLY knob sanity: 0 < r <= 20000; seeded
--       750 by 0099 — the packet does not retune it, so this script NEVER rewrites it).
--   STAGE 1 — the switch (ONE set_game_config write):
--     exploration_enabled → true — every exploration surface lights at once: the scan command
--     (command_exploration_scan, 0099/0146/0172), the read surface (get_my_exploration_discoveries,
--     0101), and via the read envelope the client panel (see NO CLIENT PR below). The securing
--     processor (0100) never read the flag (in-flight safety) and keeps running unchanged.
--   STAGE 2 — smoke asserts (read-only): the flag committed true (raw value + cfg_bool); the whole
--     exploration function surface exists via to_regprocedure (client command + client read +
--     private writer + securing processor + the osn_distance geometry leaf + the reward_grant
--     securing leaf); active sites non-empty; EXACTLY ONE process-exploration-securing cron job.
--   Emits ACTIVATE_EXPLORATION_PASS_* markers per stage and one final PASS line; any failed assert
--   RAISES → the whole transaction rolls back → NOTHING is applied (all-or-nothing activation).
--
-- IDEMPOTENT: safe to re-run — the single write is a set_game_config upsert to the same value.
--
-- ── NO CLIENT PR IS NEEDED (verified 2026-07-12, this slice) ─────────────────────────────────────
--   ExplorationPanel is SERVER-LIT, not compile-gated: it renders null unless its
--   get_my_exploration_discoveries read answers {ok:true} — `if (!isServerLit(result)) return null`
--   (src/features/exploration/ExplorationPanel.tsx:70; the api notes the server-driven visibility,
--   explorationApi.ts:12) — which it does the moment stage 1 commits. The panel is ALREADY MOUNTED
--   unconditionally on MapScreen's top-left OverlayRail (src/features/map/MapScreen.tsx:141). There
--   is NO exploration compile-time constant in src/features/map/osnReleaseGates.ts (only the OSN
--   coordinate-travel / trade / commission / team constants exist). The server flip alone mounts
--   everything.
--
-- ── RUN ORDER (the full-capacity plan) ───────────────────────────────────────────────────────────
--   Exploration flips FIRST (packet §7: "can go first" — low-risk, independent). Mining follows a
--   few days later via scripts/activate-mining.sql. The two scripts are fully INDEPENDENT: neither
--   reads nor writes the other's flag; either order works if the plan changes.
--
-- ── WHAT IT DELIBERATELY DOES NOT TOUCH ──────────────────────────────────────────────────────────
--   • mining_enabled (its own window: scripts/activate-mining.sql) and every team-launch key
--     (team_command_enabled etc., LIVE since 2026-07-12) and every captain key (their own window).
--   • exploration_scan_radius — asserted sane, NEVER rewritten (retunes are a deliberate separate
--     set_game_config write, no deploy).
--   • Any table other than game_config. Any DDL. Any migration.
--
-- ── INVOCATION (Management-API compatible: NO psql meta-commands; one BEGIN..COMMIT) ─────────────
--   psql "<prod session-pooler conn (pinned CA, sslmode=verify-full)>" -X -v ON_ERROR_STOP=1 \
--        -f scripts/activate-exploration.sql
--   Or paste this whole file into the Supabase Dashboard SQL editor / run it through the
--   management-API runner (it contains no backslash commands to strip), or:
--     bash scripts/activate-exploration.sh run ACTIVATE_EXPLORATION    # DB_URL required
--   AFTER a green run (packet §7 steps 1+3): node scripts/verify-exploration.mjs (service-role
--   env), then the manual smoke — undock, settle within 750 of a site → ExplorationPanel appears →
--   scan → discovery with a pending bundle → a re-scan rejects already_discovered (0146) → return
--   home/dock → the securing cron deposits the bundle within a minute.
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
--   See the marked ROLLBACK section at the BOTTOM (commented out). Flag-only and fully reversible
--   (packet §7: "Rollback = flip the flag back — discoveries persist, harmless"): discovery rows
--   are the player's own legitimate history; process_exploration_securing deliberately IGNORES the
--   flag (0100 in-flight safety), so pending discoveries keep securing after a rollback. PRECISELY
--   because this script preconditions on the 0172 fix, every discovery created after the flip
--   records its scanning ship, so securing never depends on the multi-ship-ambiguous resolver
--   fallback; a pending row can still legitimately WAIT (ship not settled safe, or no active home
--   base — the 0100 wait-not-forfeit posture). Only NEW scans/reads reject; the panel fails closed
--   to null again.

begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local idle_in_transaction_session_timeout = '60s';

-- ══════════ PRECONDITIONS (read-only; no write happens unless all pass) ══════════
do $$
declare
  v_head text; n int; v_missing text; v_src text; v_radius numeric;
begin
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  if v_head is null or v_head < '20260618000172' then
    raise exception 'PRECONDITION FAIL: migration head % < 20260618000172 (the writer reconcile carrying the H1 securing fix) — deploy it first', coalesce(v_head, '(none)');
  end if;
  if not exists (select 1 from supabase_migrations.schema_migrations where version = '20260618000172') then
    raise exception 'PRECONDITION FAIL: migration 20260618000172 (the exploration/mining writer reconcile) is not recorded as deployed';
  end if;

  -- the 5 seeded sites (0098, natural name key) present AND active
  select count(*) into n from public.exploration_sites
   where is_active and name in ('Derelict Listening Post', 'Shattered Survey Buoy',
         'Anomalous Debris Field', 'Silent Foundry Wreck', 'Precursor Vault Signal');
  if n <> 5 then
    raise exception 'PRECONDITION FAIL: only % of the 5 seeded exploration sites are present+active (the 0098 seed)', n;
  end if;

  -- every active bundle draws only catalog item ids (reward_grant skips unknown ids on deposit)
  select count(*) into n
    from public.exploration_sites s
    cross join lateral jsonb_array_elements(coalesce(s.reward_bundle_json->'items', '[]'::jsonb)) it
   where s.is_active
     and not exists (select 1 from public.item_types t where t.item_id = it->>'item_id');
  if n <> 0 then
    raise exception 'PRECONDITION FAIL: % active-site bundle item(s) missing from the item_types catalog', n;
  end if;

  -- the MERGED writer is LIVE: the 0098 unique pair constraint by name…
  if not exists (select 1 from pg_constraint
                 where conname = 'exploration_discoveries_player_id_site_id_key'
                   and conrelid = 'public.exploration_discoveries'::regclass
                   and contype = 'u') then
    raise exception 'PRECONDITION FAIL: unique constraint exploration_discoveries_player_id_site_id_key missing (the 0098 pair law)';
  end if;
  -- …and the DEPLOYED writer body carries BOTH the 0146 unique_violation handler AND the
  -- 0172-restored discoveries insert column list (the discriminating token is
  -- 'pending_bundle_json, main_ship_id' — 'main_ship_id' alone also appears in the receipt
  -- columns of the BROKEN body and proves nothing). This binds the H1 fix to the flip.
  select prosrc into v_src from pg_proc
   where oid = to_regprocedure('public.exploration_scan(uuid, uuid, uuid)')::oid;
  if v_src is null or position('unique_violation' in v_src) = 0
                   or position('already_discovered' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed exploration_scan body lacks the 0146 unique_violation handler';
  end if;
  if position('pending_bundle_json, main_ship_id' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed exploration_scan insert does not record main_ship_id (the 0172 H1 fix) — multi-ship players would strand discoveries; deploy 0172';
  end if;

  -- the ONE key this script writes + the read-only knob must already exist (no typo invents a key)
  select string_agg(k, ', ') into v_missing
    from unnest(array['exploration_enabled', 'exploration_scan_radius']) k
   where not exists (select 1 from public.game_config g where g.key = k);
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: game_config key(s) missing: %', v_missing;
  end if;

  -- knob sanity, READ-ONLY (0099 seeds 750; the packet does not retune, so neither does this script)
  v_radius := public.cfg_num('exploration_scan_radius');
  if v_radius is null or v_radius <= 0 or v_radius > 20000 then
    raise exception 'PRECONDITION FAIL: exploration_scan_radius % is not sane (want 0 < r <= 20000)', v_radius;
  end if;

  raise notice 'ACTIVATE_EXPLORATION_PASS_PRECONDITIONS ok: head %, 0172 reconcile deployed, 5 sites seeded+active, bundles catalog-closed, dup-guard + main_ship_id insert live, keys present, scan radius % left untouched', v_head, v_radius;
end $$;

-- ══════════ STAGE 1 — the switch (packet §7 step 2; the ONE write of this script) ══════════
do $$
declare v_before text;
begin
  select value::text into v_before from public.game_config where key = 'exploration_enabled';
  perform public.set_game_config('exploration_enabled', 'true'::jsonb);
  raise notice 'stage 1: exploration_enabled % -> true', v_before;

  raise notice 'ACTIVATE_EXPLORATION_PASS_STAGE1 ok: exploration_enabled=true';
end $$;

-- ══════════ STAGE 2 — smoke asserts (read-only) ══════════
do $$
declare
  n int; fn text;
begin
  -- (a) the committed flag value is exactly the activation state (raw + through the reader).
  if (select value #>> '{}' from public.game_config where key = 'exploration_enabled') is distinct from 'true' then
    raise exception 'SMOKE FAIL: exploration_enabled is % (want true)',
      (select value #>> '{}' from public.game_config where key = 'exploration_enabled');
  end if;
  if not public.cfg_bool('exploration_enabled') then
    raise exception 'SMOKE FAIL: cfg_bool(exploration_enabled) still false'; end if;

  -- (b) the whole exploration surface exists (client command + client read + private writer +
  --     securing processor + the two shared leaves). Existence, not execution — the behavior proof
  --     is node scripts/verify-exploration.mjs (packet §7 step 1), run separately.
  foreach fn in array array[
    'public.command_exploration_scan(uuid, uuid)',
    'public.get_my_exploration_discoveries()',
    'public.exploration_scan(uuid, uuid, uuid)',
    'public.process_exploration_securing()',
    'public.osn_distance(double precision, double precision, double precision, double precision)',
    'public.reward_grant(text, uuid, uuid, uuid, jsonb)'] loop
    if to_regprocedure(fn) is null then
      raise exception 'SMOKE FAIL: function % does not exist', fn; end if;
  end loop;

  -- (c) content sanity: active sites non-empty; discoveries selectable (count FYI, likely 0).
  select count(*) into n from public.exploration_sites where is_active;
  if n < 5 then raise exception 'SMOKE FAIL: only % active exploration sites (want >= 5)', n; end if;
  raise notice 'smoke: active exploration_sites rows = %', n;
  select count(*) into n from public.exploration_discoveries;
  raise notice 'smoke: exploration_discoveries rows = % (likely 0 at flip time)', n;

  -- (d) the securing pipeline is scheduled: EXACTLY ONE process-exploration-securing cron job
  --     (the 0100 every-minute schedule; no second engine, no missing engine).
  select count(*) into n from cron.job where jobname = 'process-exploration-securing';
  if n <> 1 then raise exception 'SMOKE FAIL: % process-exploration-securing cron jobs (want exactly 1)', n; end if;

  raise notice 'ACTIVATE_EXPLORATION_PASS_SMOKE ok: flag committed true, 6 functions present, sites active, securing cron scheduled';
end $$;

select 'EXPLORATION ACTIVATION PASS — exploration LIVE (scan + discoveries + securing). NO client PR is needed: ExplorationPanel is server-lit via get_my_exploration_discoveries (ExplorationPanel.tsx:70) and already mounted on MapScreen (MapScreen.tsx:141); no compile constant gates it. Next: node scripts/verify-exploration.mjs + the packet §7 manual smoke (undock -> settle within radius of a site -> scan -> re-scan rejects already_discovered -> settle safe -> the bundle deposits). Mining flips a few days later via scripts/activate-mining.sql (independent).' as result;

commit;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- To dark the exploration surfaces again, run the reverse write below (uncomment, run once). Notes:
--   • FLAG-ONLY and fully reversible (packet §7): discovery rows PERSIST harmlessly — they are the
--     player's own legitimate history (reveal-after-discovery already happened) and are invisible
--     again anyway: the read surface rejects exploration_disabled and the panel fails closed to null.
--   • Pending (secured_at IS NULL) discoveries keep securing after a rollback:
--     process_exploration_securing deliberately ignores the flag (the 0100 in-flight-safety
--     posture) and deposits each on its recorded ship's next safe settle (the ship IS recorded —
--     this script preconditions on the 0172 fix). A row can still legitimately wait while its ship
--     is not settled safe or the player has no active home base. Only NEW scans/reads reject.
--   • exploration_scan_radius was never touched by this script; nothing to revert there.
--
-- begin;
-- select public.set_game_config('exploration_enabled', 'false'::jsonb);
-- select key, value from public.game_config where key = 'exploration_enabled';
-- commit;
