-- MINING ACTIVATION — the Phase-12 flip (the full-capacity plan's second activity window; the
-- exploration §7 posture applied to mining: one server flag, no migration, no client change).
--
-- ██ HUMAN ACTIVATION TOOL ██ — run BY THE HUMAN, deliberately, against prod. NOT CI; nothing
-- flips at build/deploy time. Each run of this file IS the recorded human go decision.
--
-- ── WHAT IT DOES (one transaction; COMMIT only if every assert passes) ───────────────────────────
--   PRECONDITIONS (no write until these hold):
--     • migration head >= 20260618000172 AND 0172 (the exploration/mining writer reconcile) is
--       actually recorded in supabase_migrations.schema_migrations. 0172 is a HARD gate because it
--       fixes H2: 0143's stale-body re-create ("verbatim from 0104") had clobbered 0137's P19
--       field-depletion integration — the deployed mining_extract had ZERO depletion hooks and
--       worldstate_deplete_field had NO caller, which would silently kill the P19 depletion
--       subsystem the day world_balance_enabled lights;
--     • the 5 seeded mining fields (0103) exist AND are is_active;
--     • every active field bundle draws only catalog item ids (reward_grant validation is
--       catalog-driven — a missing id would silently skip that item on deposit);
--     • the MERGED writer is LIVE, not just recorded: the DEPLOYED mining_extract body
--       (pg_proc.prosrc) carries BOTH the 0143 pg_advisory_xact_lock AND the 0172-restored
--       worldstate_deplete_field call — the flip physically cannot run against the clobbered
--       writer; and the 0103 cooldown index mining_extractions_cooldown_idx exists;
--     • the config keys exist (no typo can invent a key): mining_enabled (the ONE key this script
--       writes) + the two READ-ONLY knobs — mining_extract_radius (sane: 0 < r <= 20000; seeded
--       750 by 0102) and mining_extract_cooldown_seconds (sane: 0 <= s <= 86400; seeded 300).
--       Neither knob is retuned by the plan, so this script NEVER rewrites them.
--   STAGE 1 — the switch (ONE set_game_config write):
--     mining_enabled → true — every mining surface lights at once: the extract command
--     (command_mining_extract, 0104/0137/0143/0172), the read surface (get_my_mining_extractions,
--     0106), and via the read envelope the client panel (see NO CLIENT PR below). The securing
--     processor (0105) never read the flag (in-flight safety) and keeps running unchanged. The
--     0137 depletion hooks stay dormant behind world_balance_enabled='false' — this script never
--     touches that flag.
--   STAGE 2 — smoke asserts (read-only): the flag committed true (raw value + cfg_bool); the whole
--     mining function surface exists via to_regprocedure (client command + client read + private
--     writer + securing processor + the osn_distance geometry leaf + the reward_grant securing
--     leaf + the two 0137 world-state depletion leaves the merged writer calls when world balance
--     lights); active fields non-empty; EXACTLY ONE process-mining-securing cron job.
--   Emits ACTIVATE_MINING_PASS_* markers per stage and one final PASS line; any failed assert
--   RAISES → the whole transaction rolls back → NOTHING is applied (all-or-nothing activation).
--
-- IDEMPOTENT: safe to re-run — the single write is a set_game_config upsert to the same value.
--
-- ── NO CLIENT PR IS NEEDED (verified 2026-07-12, this slice) ─────────────────────────────────────
--   MiningPanel is SERVER-LIT, not compile-gated: it renders null unless its
--   get_my_mining_extractions read answers {ok:true} — `if (!isServerLit(result)) return null`
--   (src/features/mining/MiningPanel.tsx:77; the api notes the server-driven visibility,
--   miningApi.ts:12) — which it does the moment stage 1 commits. The panel is ALREADY MOUNTED
--   unconditionally on MapScreen's top-left OverlayRail (src/features/map/MapScreen.tsx:148). There
--   is NO mining compile-time constant in src/features/map/osnReleaseGates.ts (only the OSN
--   coordinate-travel / trade / commission / team constants exist). The server flip alone mounts
--   everything.
--
-- ── RUN ORDER (the full-capacity plan) ───────────────────────────────────────────────────────────
--   Exploration flips FIRST (scripts/activate-exploration.sql, packet §7 "can go first"); mining
--   follows a FEW DAYS LATER once exploration looks healthy. The two scripts are fully
--   INDEPENDENT: neither reads nor writes the other's flag; either order works if the plan changes.
--
-- ── WHAT IT DELIBERATELY DOES NOT TOUCH ──────────────────────────────────────────────────────────
--   • exploration_enabled (its own window: scripts/activate-exploration.sql) and every team-launch
--     key (team_command_enabled etc., LIVE since 2026-07-12) and every captain key (their window).
--   • mining_extract_radius / mining_extract_cooldown_seconds — asserted sane, NEVER rewritten
--     (retunes are a deliberate separate set_game_config write, no deploy).
--   • Any table other than game_config. Any DDL. Any migration.
--
-- ── INVOCATION (Management-API compatible: NO psql meta-commands; one BEGIN..COMMIT) ─────────────
--   psql "<prod session-pooler conn (pinned CA, sslmode=verify-full)>" -X -v ON_ERROR_STOP=1 \
--        -f scripts/activate-mining.sql
--   Or paste this whole file into the Supabase Dashboard SQL editor / run it through the
--   management-API runner (it contains no backslash commands to strip), or:
--     bash scripts/activate-mining.sh run ACTIVATE_MINING              # DB_URL required
--   AFTER a green run: node scripts/verify-mining.mjs (service-role env), then the manual smoke —
--   undock, settle within 750 of a field → MiningPanel appears → extract → pending yield → an
--   immediate re-extract rejects cooldown (retry_after_seconds) → return home/dock → the securing
--   cron deposits the items within a minute.
--
-- ── POST-FLIP WATCH (documented, deliberately NOT asserted here) ─────────────────────────────────
--   mining_extractions rows with secured_at IS NULL are PENDING yields, not errors: each secures
--   on the carrying ship's next SAFE settle (spatial_state home/at_location — the 0105 processor,
--   every minute). A row staying pending simply means its ship has not settled safe yet (or the
--   player has no active home base — the 0105 wait-not-forfeit posture). Watch the count trend
--   after the flip; a monotonically growing floor of old pending rows is the signal to investigate.
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
--   See the marked ROLLBACK section at the BOTTOM (commented out). Flag-only and fully reversible:
--   extraction rows persist harmlessly (own history; invisible again behind the mining_disabled
--   envelope). Pending yields are NOT stranded — process_mining_securing deliberately IGNORES the
--   flag (the 0105 in-flight-safety posture) and still deposits them on the next safe settle. Only
--   NEW extracts/reads reject; the panel fails closed to null again.

begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local idle_in_transaction_session_timeout = '60s';

-- ══════════ PRECONDITIONS (read-only; no write happens unless all pass) ══════════
do $$
declare
  v_head text; n int; v_missing text; v_src text; v_radius numeric; v_cooldown numeric;
begin
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  if v_head is null or v_head < '20260618000172' then
    raise exception 'PRECONDITION FAIL: migration head % < 20260618000172 (the writer reconcile restoring the 0137 depletion hooks) — deploy it first', coalesce(v_head, '(none)');
  end if;
  if not exists (select 1 from supabase_migrations.schema_migrations where version = '20260618000172') then
    raise exception 'PRECONDITION FAIL: migration 20260618000172 (the exploration/mining writer reconcile) is not recorded as deployed';
  end if;

  -- the 5 seeded fields (0103, natural name key) present AND active
  select count(*) into n from public.mining_fields
   where is_active and name in ('Sparse Ore Belt', 'Ferrous Drift Field',
         'Crystalline Shelf', 'Deep Vein Cluster', 'Singularity Scar');
  if n <> 5 then
    raise exception 'PRECONDITION FAIL: only % of the 5 seeded mining fields are present+active (the 0103 seed)', n;
  end if;

  -- every active bundle draws only catalog item ids (reward_grant skips unknown ids on deposit)
  select count(*) into n
    from public.mining_fields f
    cross join lateral jsonb_array_elements(coalesce(f.reward_bundle_json->'items', '[]'::jsonb)) it
   where f.is_active
     and not exists (select 1 from public.item_types t where t.item_id = it->>'item_id');
  if n <> 0 then
    raise exception 'PRECONDITION FAIL: % active-field bundle item(s) missing from the item_types catalog', n;
  end if;

  -- the MERGED writer is LIVE: the DEPLOYED body carries the 0143 advisory lock…
  select prosrc into v_src from pg_proc
   where oid = to_regprocedure('public.mining_extract(uuid, uuid, uuid)')::oid;
  if v_src is null or position('pg_advisory_xact_lock' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed mining_extract body lacks the 0143 pg_advisory_xact_lock double-extract guard';
  end if;
  -- …AND the 0172-restored 0137 depletion hooks (0143 had clobbered them — the deployed writer
  -- would silently never scale bundles nor deplete fields when world balance lights). This binds
  -- the H2 fix to the flip.
  if position('worldstate_deplete_field' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed mining_extract body lacks the 0137/0172 worldstate_deplete_field depletion hook — deploy 0172';
  end if;
  -- …and the 0103 cooldown index (the pacing read the guard serializes) exists
  if to_regclass('public.mining_extractions_cooldown_idx') is null then
    raise exception 'PRECONDITION FAIL: index mining_extractions_cooldown_idx missing (the 0103 cooldown anchor)';
  end if;

  -- the ONE key this script writes + the two read-only knobs must already exist
  select string_agg(k, ', ') into v_missing
    from unnest(array['mining_enabled', 'mining_extract_radius', 'mining_extract_cooldown_seconds']) k
   where not exists (select 1 from public.game_config g where g.key = k);
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: game_config key(s) missing: %', v_missing;
  end if;

  -- knob sanity, READ-ONLY (0102 seeds radius 750 / cooldown 300; no retune in the plan, none here)
  v_radius := public.cfg_num('mining_extract_radius');
  if v_radius is null or v_radius <= 0 or v_radius > 20000 then
    raise exception 'PRECONDITION FAIL: mining_extract_radius % is not sane (want 0 < r <= 20000)', v_radius;
  end if;
  v_cooldown := public.cfg_num('mining_extract_cooldown_seconds');
  if v_cooldown is null or v_cooldown < 0 or v_cooldown > 86400 then
    raise exception 'PRECONDITION FAIL: mining_extract_cooldown_seconds % is not sane (want 0 <= s <= 86400)', v_cooldown;
  end if;

  raise notice 'ACTIVATE_MINING_PASS_PRECONDITIONS ok: head %, 0172 reconcile deployed, 5 fields seeded+active, bundles catalog-closed, extract guard + depletion hooks live, keys present, radius % / cooldown %s left untouched', v_head, v_radius, v_cooldown;
end $$;

-- ══════════ STAGE 1 — the switch (the ONE write of this script) ══════════
do $$
declare v_before text;
begin
  select value::text into v_before from public.game_config where key = 'mining_enabled';
  perform public.set_game_config('mining_enabled', 'true'::jsonb);
  raise notice 'stage 1: mining_enabled % -> true', v_before;

  raise notice 'ACTIVATE_MINING_PASS_STAGE1 ok: mining_enabled=true';
end $$;

-- ══════════ STAGE 2 — smoke asserts (read-only) ══════════
do $$
declare
  n int; fn text;
begin
  -- (a) the committed flag value is exactly the activation state (raw + through the reader).
  if (select value #>> '{}' from public.game_config where key = 'mining_enabled') is distinct from 'true' then
    raise exception 'SMOKE FAIL: mining_enabled is % (want true)',
      (select value #>> '{}' from public.game_config where key = 'mining_enabled');
  end if;
  if not public.cfg_bool('mining_enabled') then
    raise exception 'SMOKE FAIL: cfg_bool(mining_enabled) still false'; end if;

  -- (b) the whole mining surface exists (client command + client read + private writer + securing
  --     processor + the two shared leaves + the two 0137 world-state depletion leaves the merged
  --     writer calls once world balance lights). Existence, not execution — the behavior proof is
  --     node scripts/verify-mining.mjs, run separately.
  foreach fn in array array[
    'public.command_mining_extract(uuid, uuid)',
    'public.get_my_mining_extractions()',
    'public.mining_extract(uuid, uuid, uuid)',
    'public.process_mining_securing()',
    'public.osn_distance(double precision, double precision, double precision, double precision)',
    'public.reward_grant(text, uuid, uuid, uuid, jsonb)',
    'public.worldstate_field_remaining(uuid)',
    'public.worldstate_deplete_field(uuid)'] loop
    if to_regprocedure(fn) is null then
      raise exception 'SMOKE FAIL: function % does not exist', fn; end if;
  end loop;

  -- (c) content sanity: active fields non-empty; extractions selectable (count FYI, likely 0).
  select count(*) into n from public.mining_fields where is_active;
  if n < 5 then raise exception 'SMOKE FAIL: only % active mining fields (want >= 5)', n; end if;
  raise notice 'smoke: active mining_fields rows = %', n;
  select count(*) into n from public.mining_extractions;
  raise notice 'smoke: mining_extractions rows = % (likely 0 at flip time; secured_at NULL = pending, see POST-FLIP WATCH)', n;

  -- (d) the securing pipeline is scheduled: EXACTLY ONE process-mining-securing cron job
  --     (the 0105 every-minute schedule; no second engine, no missing engine).
  select count(*) into n from cron.job where jobname = 'process-mining-securing';
  if n <> 1 then raise exception 'SMOKE FAIL: % process-mining-securing cron jobs (want exactly 1)', n; end if;

  raise notice 'ACTIVATE_MINING_PASS_SMOKE ok: flag committed true, 8 functions present, fields active, securing cron scheduled';
end $$;

select 'MINING ACTIVATION PASS — mining LIVE (extract + history + securing). NO client PR is needed: MiningPanel is server-lit via get_my_mining_extractions (MiningPanel.tsx:77) and already mounted on MapScreen (MapScreen.tsx:148); no compile constant gates it. Next: node scripts/verify-mining.mjs + the manual smoke (undock -> settle within radius of a field -> extract -> immediate re-extract rejects cooldown -> settle safe -> the items deposit). POST-FLIP WATCH: mining_extractions rows with secured_at NULL are pending yields securing on the next safe settle, not errors.' as result;

commit;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- To dark the mining surfaces again, run the reverse write below (uncomment, run once). Notes:
--   • FLAG-ONLY and fully reversible: extraction rows PERSIST harmlessly — the player's own
--     history, invisible again anyway (the read surface rejects mining_disabled and the panel
--     fails closed to null).
--   • Pending (secured_at IS NULL) yields keep securing after a rollback: process_mining_securing
--     deliberately ignores the flag (the 0105 in-flight-safety posture) and deposits each on its
--     recorded ship's next safe settle (mining_extractions has always recorded main_ship_id —
--     0103/0143). A row can still legitimately wait while its ship is not settled safe or the
--     player has no active home base. Only NEW extracts/reads reject. Watch the pending count
--     trend downward after a rollback.
--   • mining_extract_radius / mining_extract_cooldown_seconds were never touched by this script;
--     nothing to revert there.
--
-- begin;
-- select public.set_game_config('mining_enabled', 'false'::jsonb);
-- select key, value from public.game_config where key = 'mining_enabled';
-- commit;
