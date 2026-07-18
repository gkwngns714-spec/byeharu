-- Byeharu — COMBAT SLICE 2: the TELEGRAPH (a warning beat before a combat encounter). DARK.
--
-- ── WHAT THIS IS ────────────────────────────────────────────────────────────────────────────────────
-- Today combat starts INSTANTLY on arrival at a hunt_pirates location: the settle chain
-- (process_fleet_movements → movement_settle_arrival → fleet_set_present → presence_create →
-- activity_start(presence,'hunt_pirates') → combat_create_encounter, 0018:16) fires the encounter the
-- moment the fleet lands. Owner intent: give the player a beat to react (flee / brace) — show a warning
-- that a combat encounter will begin in N seconds, and only THEN start combat.
--
-- The seam is ONE hop upstream, exactly where the pirate/group prototype composes: activity_start. When
-- LIT, instead of calling combat_create_encounter immediately for a combat activity, we record a
-- pending_encounters row with trigger_at := now() + combat_telegraph_seconds and return WITHOUT starting
-- combat. A NEW light resolver cron (process-combat-telegraphs) fires combat_create_encounter(presence)
-- once trigger_at passes. The player can abort during the window via combat_flee_pending, which withdraws
-- the fleet home (the EXISTING presence return-home leaves — never a new movement path). NO fork of the
-- combat engine: the pending row simply DELAYS the identical combat_create_encounter call.
--
-- ── DARK / GATE (byte-parity when off — the house discipline) ────────────────────────────────────────
-- New flag combat_telegraph_enabled (seeded FALSE). While dark:
--   • activity_start's hunt branch calls combat_create_encounter(p_presence) IMMEDIATELY — byte-identical
--     to the 0018 head (the else-branch below IS the head statement, verbatim);
--   • the resolver cron body reject-before-reads on the flag and returns 0 (no scan, no write);
--   • pending_encounters stays EMPTY (activity_start is its sole inserter, and it only inserts when lit),
--     so get_my_pending_encounter() returns null and the client banner renders nothing (fail-closed);
--   • combat_flee_pending finds no telegraphed row → no_pending.
-- Nothing goes live until a human flips the flag. The self-assert at the foot PROVES the dark path (the
-- immediate combat_create_encounter call) and the lit path (the pending insert) both exist, the flag
-- gates both, and the resolver is flag-gated + per-row isolated.
--
-- ── ANTI-SPAGHETTI ──────────────────────────────────────────────────────────────────────────────────
--   #1 combat: NOT forked. The telegraph inserts a delay row; the resolver calls the UNTOUCHED
--      combat_create_encounter (0168 head) — the exact chain a legacy/team hunt takes today, one hop
--      later. combat_create_encounter, its group twin, the tick, the settle — all byte-untouched.
--   #2 movement: flee REUSES the presence return-home leaves (presence_complete + movement_create
--      'return_home' + fleet_set_returning), the EXACT sequence presence_request_leave's safe-zone branch
--      (0018:45-58) and request_main_ship_return (0152:205-215) already use; member ships re-home via the
--      ONE 0152 legacy in-flight leaf (mainship_mark_legacy_in_flight, 'returning') — the SAME leaf the
--      D3 tick escape (0169:237-239) marks survivors with. No new movement verb, no second parking path.
--      (The brake/stop verbs — command_ship_group_stop, 0215 — do NOT fit: they halt a MOVING fleet and
--      HOLD it in space and REJECT an open sortie; at telegraph time the fleet has ALREADY ARRIVED —
--      status 'present' — so "stop it mid-transit" is the wrong verb. Verified: the correct verb for a
--      present fleet is the presence return-home withdraw, reused here.)
--   #3 the resolver is a NEW, SEPARATE cron (process-combat-telegraphs) on its own cheap schedule — the
--      hot process_fleet_movements (30s) / process_combat_ticks (2-3s) crons are NOT touched.
--   #4 per-row exception isolation on the resolver (the 0206 CRON-GUARD pattern): begin/exception per row,
--      query_canceled re-raised — one bad pending row can never wedge the sweep.
--
-- Forward-only: no shipped migration edited. Takes 0230 (0223-0229 claimed by in-flight branches;
-- verified 2026-07-18 by grep over all branches — 0223 movement_schema_drop … 0226 mining markers).

-- ── 1) config: the flag (dark) + the window length ─────────────────────────────────────────────────
insert into public.game_config (key, value, description) values
  ('combat_telegraph_enabled', 'false', 'COMBAT-S2: when true, a hunt arrival records a pending_encounters warning and defers combat_create_encounter by combat_telegraph_seconds instead of starting combat instantly (dark by default — instant combat when false).'),
  ('combat_telegraph_seconds', '8',     'COMBAT-S2: seconds between the telegraph warning and the encounter starting (the flee/brace beat).')
on conflict (key) do nothing;

-- ── 2) pending_encounters: the telegraphed-but-not-yet-started encounters ───────────────────────────
-- SOLE INSERTER: activity_start (below), only while combat_telegraph_enabled is lit. Rows transition
-- telegraphed → resolved (the resolver cron fired combat) | fled (the player aborted). FK cascades keep
-- the table self-cleaning: a row dies with its presence, its fleet, or its location (whole-account
-- deletion cascades order-independently — the group_sortie_members 0168 rationale).
create table public.pending_encounters (
  id           uuid primary key default gen_random_uuid(),
  presence_id  uuid not null references public.location_presence (id) on delete cascade,
  fleet_id     uuid not null references public.fleets (id)            on delete cascade,
  location_id  uuid            references public.locations (id)       on delete cascade,
  activity     text not null,
  trigger_at   timestamptz not null,
  status       text not null default 'telegraphed'
                 check (status in ('telegraphed','resolved','fled')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
-- The resolver's due-row scan (status + trigger_at); the flee/read lookups key on fleet_id.
create index pending_encounters_due_idx   on public.pending_encounters (status, trigger_at);
create index pending_encounters_fleet_idx on public.pending_encounters (fleet_id);

-- Owner-select RLS: read-only to the owner (resolved through fleet → player), NO client write path.
-- The client reads via get_my_pending_encounter() (SECURITY DEFINER); this policy is defense-in-depth
-- so a direct table select can still only see the caller's own rows.
alter table public.pending_encounters enable row level security;
create policy "pending_encounters_select_own" on public.pending_encounters
  for select using (
    exists (select 1 from public.fleets f where f.id = fleet_id and f.player_id = auth.uid()));
grant select on public.pending_encounters to authenticated;

comment on table public.pending_encounters is
  'COMBAT-S2: a hunt arrival telegraphed (warning shown, combat deferred) but not yet started. Sole '
  'inserter: activity_start (only while combat_telegraph_enabled is lit). Resolver cron fires '
  'combat_create_encounter at trigger_at (→ resolved); combat_flee_pending withdraws the fleet (→ fled).';

-- ── 3) activity_start — 0018:6 head VERBATIM + the ONE marked TELEGRAPH hunk ─────────────────────────
-- Copied from the true head (grep over ALL migrations: created 0008, re-created 0018:6 — nothing later
-- re-creates it; VERIFIED). The single delta is inside the hunt_pirates branch: when the flag is LIT,
-- record a pending_encounters row and RETURN without starting combat; when DARK, the else-branch runs
-- `perform combat_create_encounter(p_presence)` — the 0018 head statement, byte-identical. The 'none'
-- branch and the unknown-activity raise are untouched.
create or replace function public.activity_start(p_presence uuid, p_activity text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_activity = 'none' then
    return;  -- safe zone
  elsif p_activity = 'hunt_pirates' then
    -- ── COMBAT-S2 TELEGRAPH HUNK ─────────────────────────────────────────────────────────────────────
    -- LIT: defer combat — record the warning (trigger_at = now + combat_telegraph_seconds) and return
    -- WITHOUT starting the encounter; the process-combat-telegraphs cron fires combat_create_encounter
    -- once trigger_at passes. The presence is already 'active' (presence_create inserted it one statement
    -- earlier, same txn), so fleet_id/location_id are read straight off it — no new argument, no new state.
    -- DARK: the else-branch is the 0018 head statement, byte-identical → instant combat exactly as today.
    if public.cfg_bool('combat_telegraph_enabled') then
      insert into public.pending_encounters (presence_id, fleet_id, location_id, activity, trigger_at, status)
        select p_presence, lp.fleet_id, lp.location_id, p_activity,
               now() + make_interval(secs => coalesce(public.cfg_num('combat_telegraph_seconds'), 8)),
               'telegraphed'
          from public.location_presence lp
         where lp.id = p_presence;
    else
      perform combat_create_encounter(p_presence);
    end if;
    -- ── END COMBAT-S2 TELEGRAPH HUNK ─────────────────────────────────────────────────────────────────
  else
    raise exception 'activity_start: unknown activity %', p_activity;
  end if;
end;
$$;
-- CREATE OR REPLACE preserves the head's owner + grants (internal Presence→Combat hook, invoked by
-- presence_create as owner) — no ACL change, matching the 0018 posture.

-- ── 4) combat_flee_pending — the player aborts a telegraphed encounter (withdraw the fleet home) ──────
-- Authenticated, own-fleet only. For a still-'telegraphed' pending row on the caller's fleet: mark it
-- 'fled' and send the fleet HOME via the EXISTING presence return-home leaves (never a new movement
-- path). Reject order (envelopes; gate first): not_authenticated → telegraph_disabled → no_pending
-- (none telegraphed for this owned fleet — includes "the resolver already started combat", since the
-- FOR UPDATE re-read then sees status='resolved' and the status='telegraphed' predicate no longer
-- matches) → ok.
--
-- CONCURRENCY vs the resolver: both lock the pending row FOR UPDATE. Whoever commits first wins — if
-- flee wins, the resolver's status='telegraphed' scan skips the now-'fled' row; if the resolver wins,
-- flee blocks then re-reads under READ COMMITTED, the row is 'resolved', the predicate fails → no_pending
-- (combat already started; abort via Retreat instead). Lock order pending → presence; the resolver takes
-- only the pending lock (combat_create_encounter reads the presence unlocked), so no cycle.
create or replace function public.combat_flee_pending(p_fleet_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player  uuid := auth.uid();
  v_pending pending_encounters%rowtype;
  v_pr      location_presence%rowtype;
  v_base    record;
  v_loc     record;
  v_speed   double precision;
  v_mv      uuid;
  m         record;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK gate first (while dark the table is empty anyway; the 0161/0163 reject-before-read posture).
  if not public.cfg_bool('combat_telegraph_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'telegraph_disabled');
  end if;

  -- Lock the caller's still-telegraphed pending row (owner-scoped through fleet). FOR UPDATE OF the
  -- pending row only (not fleets) serializes vs the resolver; the status='telegraphed' predicate makes a
  -- resolver-won race re-read as not-found on re-check.
  select pe.* into v_pending
    from pending_encounters pe
    join fleets f on f.id = pe.fleet_id
   where pe.fleet_id = p_fleet_id and f.player_id = v_player and pe.status = 'telegraphed'
   for update of pe;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_pending');
  end if;

  -- Mark it fled up front (inside the same txn as the withdraw — all-or-nothing).
  update pending_encounters set status = 'fled', updated_at = now() where id = v_pending.id;

  -- Resolve the presence. It should still be 'active' (nothing completes it during the window), but if
  -- it is already gone/closed there is nothing to withdraw — the row is fled, return cleanly.
  select * into v_pr from location_presence where id = v_pending.presence_id for update;
  if not found or v_pr.status <> 'active' then
    return jsonb_build_object('ok', true, 'fled', true, 'withdrew', false,
                              'fleet_id', p_fleet_id, 'reason', 'presence_already_closed');
  end if;

  -- Withdraw the fleet HOME — the presence_request_leave safe-zone leaf sequence (0018:45-58), reused
  -- verbatim: close the presence, create the return_home movement, set the fleet returning. Speed uses
  -- the tick's exact coalesce (fleet_speed for a unit fleet; the member-fleet fallback for a team sortie
  -- that carries no fleet_units — 0169:222).
  select b.id, b.x, b.y into v_base
    from fleets f join bases b on b.id = f.origin_base_id where f.id = v_pr.fleet_id;
  select x, y into v_loc from locations where id = v_pr.location_id;
  v_speed := coalesce(fleet_speed(v_pr.fleet_id), combat_fleet_return_speed(v_pr.fleet_id));

  perform presence_complete(v_pr.id);
  v_mv := movement_create(
    v_pr.player_id, v_pr.fleet_id,
    'location', null, v_pr.zone_id, v_pr.location_id, v_loc.x, v_loc.y,
    'base', v_base.id, null, null, v_base.x, v_base.y,
    'return_home', v_speed);
  perform fleet_set_returning(v_pr.fleet_id, v_mv);

  -- Team sortie members ride home with the fleet — 'returning' via the ONE 0152 legacy in-flight leaf,
  -- exactly as the D3 tick escape marks survivors (0169:237-239). A legacy unit fleet has no manifest
  -- rows → zero iterations. The reconciler (process_mainship_expeditions) re-homes them once the fleet
  -- completes, the identical path a combat escape takes.
  for m in select gsm.main_ship_id from group_sortie_members gsm where gsm.fleet_id = v_pr.fleet_id loop
    perform mainship_mark_legacy_in_flight(m.main_ship_id, 'returning');
  end loop;

  return jsonb_build_object('ok', true, 'fled', true, 'withdrew', true,
                            'fleet_id', v_pr.fleet_id, 'return_movement_id', v_mv);
end;
$$;

revoke execute on function public.combat_flee_pending(uuid) from public, anon;
grant  execute on function public.combat_flee_pending(uuid) to authenticated;

-- ── 5) get_my_pending_encounter — the tiny owner read behind the client banner ───────────────────────
-- Returns the caller's SOONEST still-telegraphed pending encounter as a jsonb object (fleet + location +
-- trigger_at + activity + location name for display), or null when none. Owner-scoped through fleet.
-- While dark the table is empty → always null → the banner renders nothing.
create or replace function public.get_my_pending_encounter()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_result jsonb;
begin
  if v_player is null then
    return null;
  end if;
  select jsonb_build_object(
           'pending_id',    pe.id,
           'fleet_id',      pe.fleet_id,
           'location_id',   pe.location_id,
           'location_name', l.name,
           'activity',      pe.activity,
           'trigger_at',    pe.trigger_at)
    into v_result
    from pending_encounters pe
    join fleets f on f.id = pe.fleet_id
    left join locations l on l.id = pe.location_id
   where f.player_id = v_player and pe.status = 'telegraphed'
   order by pe.trigger_at asc
   limit 1;
  return v_result;  -- null when the caller has no telegraphed encounter
end;
$$;

revoke execute on function public.get_my_pending_encounter() from public, anon;
grant  execute on function public.get_my_pending_encounter() to authenticated;

-- ── 6) process_combat_telegraphs — the resolver cron (flag-gated, per-row isolated) ──────────────────
-- For each due telegraphed row (now >= trigger_at), fire the UNTOUCHED combat_create_encounter for its
-- presence (the exact chain a hunt takes today, one hop later) and mark it resolved. Gated on the flag
-- (no-op while dark). Per-row begin/exception subtransaction — the 0206 CRON-GUARD pattern: a raise on
-- one pending row logs a WARNING, rolls that row back, and the sweep CONTINUES; query_canceled is
-- re-raised (never swallow a statement-timeout cancel). Internal/cron-only — no client grant.
create or replace function public.process_combat_telegraphs()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r       record;
  v_count integer := 0;
begin
  -- DARK: reject-before-read — no scan, no write while the flag is off (byte-inert).
  if not public.cfg_bool('combat_telegraph_enabled') then
    return 0;
  end if;

  for r in
    select * from pending_encounters
    where status = 'telegraphed' and trigger_at <= now()
    for update skip locked
  loop
    -- ── CRON-GUARD (0206 pattern): per-row subtransaction so one bad pending row can't wedge the sweep.
    begin
      perform combat_create_encounter(r.presence_id);
      update pending_encounters set status = 'resolved', updated_at = now() where id = r.id;
      v_count := v_count + 1;
    exception
      when query_canceled then raise;
      when others then
        raise warning 'process_combat_telegraphs: resolve failed for pending % (left telegraphed; retries next tick): %',
          r.id, sqlerrm;
    end;
    -- ── END CRON-GUARD ───────────────────────────────────────────────────────────────────────────────
  end loop;

  return v_count;
end;
$$;

revoke execute on function public.process_combat_telegraphs() from public, anon, authenticated;

-- ── 7) schedule the resolver — a NEW, SEPARATE cron job (the hot crons are untouched) ────────────────
-- Idempotent (re-runnable): drop any existing job of this name first (the 0011 idiom verbatim). Cheap
-- 2s cadence gives fine granularity inside the ~8s window; the body no-ops while dark so the schedule
-- is inert until the flag flips.
create extension if not exists pg_cron;
do $$
begin
  perform cron.unschedule(jobid) from cron.job where jobname = 'process-combat-telegraphs';
exception
  when undefined_table then null;  -- cron schema not ready yet (first run handles it)
end;
$$;
select cron.schedule(
  'process-combat-telegraphs',
  '2 seconds',
  $$select public.process_combat_telegraphs();$$
);

-- ── 8) SELF-ASSERT — the migration proves its dark/lit paths + gating or refuses to land ─────────────
-- prosrc probes strip -- comments first (the house lesson: a token inside a comment must not
-- false-positive a code-presence or ordering check).
do $telegraph$
declare
  v_as text;   -- activity_start body, comments stripped
  v_rs text;   -- resolver body, comments stripped
  v_gate int; v_insert int; v_combat int;
begin
  select regexp_replace(prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_as
    from pg_proc where oid = 'public.activity_start(uuid,text)'::regprocedure;
  select regexp_replace(prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_rs
    from pg_proc where oid = 'public.process_combat_telegraphs()'::regprocedure;
  if v_as is null or v_rs is null then
    raise exception 'TELEGRAPH self-assert FAIL: a required function is missing';
  end if;

  -- (1) the table landed with RLS + the authenticated select grant.
  if to_regclass('public.pending_encounters') is null then
    raise exception 'TELEGRAPH self-assert FAIL: pending_encounters table missing'; end if;
  if not (select relrowsecurity from pg_class where oid = 'public.pending_encounters'::regclass) then
    raise exception 'TELEGRAPH self-assert FAIL: pending_encounters has no RLS'; end if;
  if not has_table_privilege('authenticated', 'public.pending_encounters', 'select') then
    raise exception 'TELEGRAPH self-assert FAIL: pending_encounters not owner-readable'; end if;

  -- (2) DARK path present: activity_start STILL calls combat_create_encounter immediately.
  if strpos(v_as, 'combat_create_encounter(p_presence)') = 0 then
    raise exception 'TELEGRAPH self-assert FAIL: activity_start lost the immediate combat_create_encounter (dark parity)'; end if;
  -- (3) LIT path present: the pending insert.
  if strpos(v_as, 'insert into public.pending_encounters') = 0 then
    raise exception 'TELEGRAPH self-assert FAIL: activity_start missing the pending_encounters insert (lit path)'; end if;
  -- (4) the flag gates BOTH paths (gate precedes the insert AND the immediate combat call).
  v_gate   := strpos(v_as, 'cfg_bool(''combat_telegraph_enabled'')');
  v_insert := strpos(v_as, 'insert into public.pending_encounters');
  v_combat := strpos(v_as, 'combat_create_encounter(p_presence)');
  if not (v_gate > 0 and v_gate < v_insert and v_gate < v_combat) then
    raise exception 'TELEGRAPH self-assert FAIL: the flag does not gate both paths (gate=%, insert=%, combat=%)', v_gate, v_insert, v_combat; end if;
  -- (5) the 0018 head survives: the 'none' safe-zone and the unknown-activity raise.
  if strpos(v_as, 'unknown activity') = 0 then
    raise exception 'TELEGRAPH self-assert FAIL: activity_start lost the 0018 head (unknown-activity raise)'; end if;

  -- (6) the resolver is flag-gated (no-op while dark) and calls the untouched combat_create_encounter.
  if strpos(v_rs, 'cfg_bool(''combat_telegraph_enabled'')') = 0 then
    raise exception 'TELEGRAPH self-assert FAIL: the resolver is not flag-gated (would run while dark)'; end if;
  if strpos(v_rs, 'combat_create_encounter(r.presence_id)') = 0 then
    raise exception 'TELEGRAPH self-assert FAIL: the resolver lost its combat_create_encounter call'; end if;
  -- (7) per-row isolation (the 0206 CRON-GUARD): query_canceled re-raised.
  if strpos(v_rs, 'when query_canceled then raise') = 0 then
    raise exception 'TELEGRAPH self-assert FAIL: the resolver lost its per-row query_canceled re-raise'; end if;

  -- (8) the resolver cron job is scheduled.
  if not exists (select 1 from cron.job where jobname = 'process-combat-telegraphs') then
    raise exception 'TELEGRAPH self-assert FAIL: the process-combat-telegraphs cron job is not scheduled'; end if;

  -- (9) ACLs: flee + read are authenticated-executable; the resolver is client-locked.
  if not has_function_privilege('authenticated', 'public.combat_flee_pending(uuid)', 'execute') then
    raise exception 'TELEGRAPH self-assert FAIL: combat_flee_pending is not authenticated-executable'; end if;
  if not has_function_privilege('authenticated', 'public.get_my_pending_encounter()', 'execute') then
    raise exception 'TELEGRAPH self-assert FAIL: get_my_pending_encounter is not authenticated-executable'; end if;
  if has_function_privilege('authenticated', 'public.process_combat_telegraphs()', 'execute')
     or has_function_privilege('anon', 'public.process_combat_telegraphs()', 'execute') then
    raise exception 'TELEGRAPH self-assert FAIL: the resolver cron is client-executable'; end if;

  -- (10) the flag + window config seeded.
  if public.cfg_num('combat_telegraph_seconds') is null then
    raise exception 'TELEGRAPH self-assert FAIL: combat_telegraph_seconds not seeded'; end if;
  if not exists (select 1 from game_config where key = 'combat_telegraph_enabled') then
    raise exception 'TELEGRAPH self-assert FAIL: combat_telegraph_enabled not seeded'; end if;

  raise notice 'TELEGRAPH self-assert ok: pending_encounters table (RLS, owner-read); activity_start re-created from the 0018 head with ONE flag-gated telegraph hunk (DARK → immediate combat_create_encounter byte-parity; LIT → pending insert; head unknown-activity raise intact); flee withdraws via the presence return-home leaves; resolver flag-gated + per-row isolated (query_canceled re-raised) on its own process-combat-telegraphs cron; ACLs (flee/read authenticated, resolver client-locked); flag seeded FALSE';
end $telegraph$;
