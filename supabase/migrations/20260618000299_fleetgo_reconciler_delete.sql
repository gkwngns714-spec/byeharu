-- Byeharu — FLEET-GO step 4d: RECONCILER DELETE. Migration number 0299 is a PLACEHOLDER —
-- renumbered at integration (4c takes the low slot; THIS FILE MUST SORT AFTER 4c).
--
-- ── WHAT THIS DOES (charter step 4d — the final movement-arc migration) ──────────────────────────
--   1. REJECT-BEFORE-DELETE: refuses to run (RAISES) until the 4c world exists — the
--      main_ship_instances.status CHECK narrowed to {home,destroyed}, zero ships in any movement
--      status, the live reconciler still carrying the exact shield hunk we are about to copy, and
--      repair_main_ship no longer writing 'stationary'. Safety-critical ordering (charter 4d):
--      NEVER delete the reconciler while movement statuses are still writable.
--   2. Rehomes the SHIELD-2/NANGUARD idle shield-regen hunk (0199:555-556 declarations +
--      0199:630-642 hunk, VERBATIM) into a new leaf `process_shield_idle_regen()` — the hunk reads
--      no movement state and must not die with its host. The declarations travel WITH the hunk:
--      they carry the NANGUARD (0198) `= 'NaN'::double precision` guard AND the `greatest(0, …)`
--      drain-floor (without the floor a mis-set negative knob DRAINS shields every 30s).
--   3. Schedules the leaf at the reconciler's exact 0050 cadence ('30 seconds') — net heartbeat
--      count unchanged: one cron dies, one is born.
--   4. Unschedules 'process-mainship-expeditions' (the 0058 by-name idiom; job name from 0050:263).
--   5. Drops `process_mainship_expeditions()` and its sole callee `nohome_dock_returning_ship(uuid)`
--      (grep-verified: the reconciler is the leaf's only SQL caller — 0199:578/592; everything else
--      is activation-script/proof existence checks). Post-4c both re-home/dock-at-return candidate
--      sets are empty BY CHECK — the reconciler reconciles nothing and the leaf docks nothing.
--   6. Closing self-asserts (REGENHOME/REGENSCHED/RECONGONE/NOSTRAND shapes).
--
-- ANTI-0136 POSTURE: this migration re-creates NO surviving function — it is add-leaf + drop only.
-- NOT dropped here (live elsewhere): fleets.return_location_id (read by 0204/0214),
-- launch_from_dock_enabled, and every other 0199 surface (send/hunt/repair are 4b/4c's arc).
-- The regen is NOT merged into the 3s combat tick (different knob shield_regen_combat_pct,
-- different cadence) nor into process_fleet_movements (Movement must never write shields).
--
-- Supabase applies each migration file as ONE transaction — every step below is all-or-nothing.

-- ── §1) REJECT-BEFORE-DELETE (the 4c RAISES idiom: this file deploys AFTER 4c and refuses to run
--        before it; each RAISE names its unmet precondition) ─────────────────────────────────────
do $recon4d_gate$
declare
  v_n   integer;
  v_src text;
  r     record;
begin
  -- (a) the 4c narrowing landed: NO check constraint on main_ship_instances admits any movement
  --     status ('traveling','returning','hunting','stationary') or any dead status
  --     ('repairing','trading','exploring','mining','retreating') — and the status domain CHECK
  --     (admitting 'home' + 'destroyed') exists. Queried from pg_constraint, not assumed.
  select count(*) into v_n
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'public' and t.relname = 'main_ship_instances' and c.contype = 'c'
      and (   pg_get_constraintdef(c.oid) like '%''traveling''%'
           or pg_get_constraintdef(c.oid) like '%''returning''%'
           or pg_get_constraintdef(c.oid) like '%''hunting''%'
           or pg_get_constraintdef(c.oid) like '%''stationary''%'
           or pg_get_constraintdef(c.oid) like '%''repairing''%'
           or pg_get_constraintdef(c.oid) like '%''trading''%'
           or pg_get_constraintdef(c.oid) like '%''exploring''%'
           or pg_get_constraintdef(c.oid) like '%''mining''%'
           or pg_get_constraintdef(c.oid) like '%''retreating''%');
  if v_n > 0 then
    raise exception '4d REJECT-BEFORE-DELETE: 4c has not landed — % check constraint(s) on main_ship_instances still admit a movement/dead status (the status CHECK must admit only {home,destroyed}); this migration must deploy AFTER 4c', v_n;
  end if;
  select count(*) into v_n
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'public' and t.relname = 'main_ship_instances' and c.contype = 'c'
      and pg_get_constraintdef(c.oid) like '%status%'
      and pg_get_constraintdef(c.oid) like '%''home''%'
      and pg_get_constraintdef(c.oid) like '%''destroyed''%';
  if v_n = 0 then
    raise exception '4d REJECT-BEFORE-DELETE: no status domain CHECK admitting {home,destroyed} found on main_ship_instances — the 4c narrowed CHECK is missing entirely';
  end if;

  -- (b) zero ships sit in a movement status (belt-and-braces beside (a): a NOT VALID or dropped
  --     CHECK could otherwise hide strays; the owner's orphan reset is a 4c-gate, re-checked here).
  select count(*) into v_n
    from public.main_ship_instances
    where status in ('traveling','returning','hunting');
  if v_n > 0 then
    raise exception '4d REJECT-BEFORE-DELETE: % main_ship_instances row(s) still in a movement status (traveling/returning/hunting) — the reconciler may not be deleted while movement state exists', v_n;
  end if;

  -- (c) parity-source proof: the live reconciler still carries the EXACT shield-hunk tokens this
  --     migration copies (if a later re-create mutated them, the copy below would fork behavior).
  select p.prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'process_mainship_expeditions';
  if v_src is null then
    raise exception '4d REJECT-BEFORE-DELETE: process_mainship_expeditions is not deployed — nothing to rehome the shield hunk from (already deleted?)';
  end if;
  if position('v_idle_raw double precision := coalesce(cfg_num(''shield_regen_idle_pct''), 0);' in v_src) = 0
     or position('v_idle     double precision := greatest(0, case when v_idle_raw = ''NaN''::double precision then 0 else v_idle_raw end);' in v_src) = 0
     or position('if v_idle > 0 then' in v_src) = 0
     or position('set shield = least(s.max_shield, s.shield + ceil(s.max_shield * v_idle)::integer)' in v_src) = 0
     or position('and ce.status in (''active'',''retreating'')' in v_src) = 0 then
    raise exception '4d REJECT-BEFORE-DELETE: the live process_mainship_expeditions does not carry the exact 0199 shield-hunk tokens (declarations + guarded UPDATE + exclusion) — the verbatim copy below would not be parity; re-derive the hunk before deleting';
  end if;

  -- (d) 4c retired repair_main_ship's 'stationary' revive-write (the 0199 lit path): no definition
  --     of repair_main_ship may still write 'stationary' (checked across every overload).
  for r in
    select p.prosrc
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'repair_main_ship'
  loop
    if position('''stationary''' in r.prosrc) > 0 then
      raise exception '4d REJECT-BEFORE-DELETE: 4c did not retire repair_main_ship''s stationary write';
    end if;
  end loop;

  raise notice '4d gate ok: 4c world confirmed (status CHECK = {home,destroyed}; zero movement-status ships; reconciler carries the exact shield hunk; repair writes no stationary)';
end $recon4d_gate$;

-- ── §2) process_shield_idle_regen — the rehomed idle shield-regen leaf ───────────────────────────
-- Body = VERBATIM copy of 0199:555-556 (the declarations) + 0199:630-642 (the guarded hunk),
-- nothing else. Mechanically diffed against 0199 (see the slice report). The declarations carry:
--   • the NANGUARD (0198) working `= 'NaN'::double precision` idiom — a jsonb "NaN" knob floors
--     to 0 instead of aborting on ceil(NaN)::integer;
--   • the `greatest(0, …)` drain-floor — a mis-set NEGATIVE knob can never DRAIN shields.
-- The hunk keeps the SHIELD-2 (0197) disjoint-writers partition: inside a live active/retreating
-- encounter the 3s tick is the SOLE shield writer; outside one, this leaf is. `status <>
-- 'destroyed'` still reads pure lifecycle — 'destroyed' survives 4c (repair is the revival path).
create function public.process_shield_idle_regen()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_idle_raw double precision := coalesce(cfg_num('shield_regen_idle_pct'), 0);
  v_idle     double precision := greatest(0, case when v_idle_raw = 'NaN'::double precision then 0 else v_idle_raw end);
begin
  if v_idle > 0 then
    update main_ship_instances s
      set shield = least(s.max_shield, s.shield + ceil(s.max_shield * v_idle)::integer),
          updated_at = now()
      where s.shield < s.max_shield
        and s.status <> 'destroyed'
        and not exists (
          select 1 from combat_units cu
          join combat_encounters ce on ce.id = cu.encounter_id
          where cu.main_ship_id = s.main_ship_id
            and ce.status in ('active','retreating')
        );
  end if;
end;
$$;
-- the reconciler's exact ACL posture (0050 §6 / the 0199 leaf idiom): server-only, NEVER clients.
revoke execute on function public.process_shield_idle_regen() from public, anon, authenticated;
grant  execute on function public.process_shield_idle_regen() to service_role;

-- ── §3) schedule the leaf on the reconciler's exact 0050 cadence (unschedule-by-name first — the
--        0058 idempotent idiom — so a re-run cannot create a duplicate job) ──────────────────────
create extension if not exists pg_cron;
do $$
begin
  perform cron.unschedule(jobid) from cron.job where jobname = 'process-shield-idle-regen';
exception
  when undefined_table then null;  -- cron schema not ready yet (first run handles it)
end;
$$;
select cron.schedule(
  'process-shield-idle-regen',
  '30 seconds',
  $$select public.process_shield_idle_regen();$$
);

-- ── §4) unschedule the reconciler cron (job name grep-verified at 0050:263) ──────────────────────
do $$
begin
  perform cron.unschedule(jobid) from cron.job where jobname = 'process-mainship-expeditions';
exception
  when undefined_table then null;
end;
$$;

-- ── §5) drop the reconciler, then its sole callee ────────────────────────────────────────────────
-- process_mainship_expeditions: created 0050:234, re-created 0169 → 0197 → 0198 → 0199 (the last
-- head); its cron is unscheduled above and its shield hunk rehomed in §2 — post-4c both of its
-- reconcile candidate sets are empty by CHECK, so nothing else remains of it.
-- nohome_dock_returning_ship: created 0199:662; its ONLY SQL caller is the reconciler's lit path
-- (0199:578/592) — with the caller gone it is unreachable dead weight.
drop function public.process_mainship_expeditions();
drop function public.nohome_dock_returning_ship(uuid);

-- ── §6) closing self-asserts ─────────────────────────────────────────────────────────────────────
do $recon4d_close$
declare
  v_n   integer;
  v_src text;
begin
  -- REGENHOME: the leaf exists and carries the pinned tokens (the exact UPDATE, the NANGUARD
  -- idiom, the drain-floor, the fire-guard, the encounter exclusion).
  select p.prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'process_shield_idle_regen';
  if v_src is null then
    raise exception '4d self-assert FAIL: process_shield_idle_regen not deployed';
  end if;
  if position('set shield = least(s.max_shield, s.shield + ceil(s.max_shield * v_idle)::integer)' in v_src) = 0 then
    raise exception '4d self-assert FAIL: the leaf lost the exact idle-regen UPDATE (REGENHOME)';
  end if;
  if position('= ''NaN''::double precision' in v_src) = 0 then
    raise exception '4d self-assert FAIL: the leaf lost the NANGUARD NaN-floor idiom (REGENHOME)';
  end if;
  if position('greatest(0,' in v_src) = 0 then
    raise exception '4d self-assert FAIL: the leaf lost the greatest(0, …) drain-floor — a negative knob would DRAIN shields (REGENHOME)';
  end if;
  if position('if v_idle > 0 then' in v_src) = 0 then
    raise exception '4d self-assert FAIL: the leaf lost the v_idle > 0 fire-guard — knob 0 would fire same-value row writes every 30s (REGENHOME)';
  end if;
  if position('and ce.status in (''active'',''retreating'')' in v_src) = 0 then
    raise exception '4d self-assert FAIL: the leaf lost the live-encounter exclusion — it would fight the 3s tick for mid-combat shields (REGENHOME)';
  end if;

  -- REGENSCHED: exactly ONE cron job for the new name, at exactly '30 seconds'; ZERO for the old.
  select count(*) into v_n from cron.job where jobname = 'process-shield-idle-regen';
  if v_n <> 1 then
    raise exception '4d self-assert FAIL: % cron job(s) named process-shield-idle-regen (want exactly 1)', v_n;
  end if;
  select count(*) into v_n from cron.job where jobname = 'process-shield-idle-regen' and schedule = '30 seconds';
  if v_n <> 1 then
    raise exception '4d self-assert FAIL: process-shield-idle-regen is not scheduled at the 0050 cadence ''30 seconds''';
  end if;
  select count(*) into v_n from cron.job where jobname = 'process-mainship-expeditions';
  if v_n <> 0 then
    raise exception '4d self-assert FAIL: % cron job(s) named process-mainship-expeditions survive (want 0 — the reconciler heartbeat must die here)', v_n;
  end if;

  -- RECONGONE: both dropped functions resolve to NULL.
  if to_regprocedure('public.process_mainship_expeditions()') is not null then
    raise exception '4d self-assert FAIL: process_mainship_expeditions still deployed (RECONGONE)';
  end if;
  if to_regprocedure('public.nohome_dock_returning_ship(uuid)') is not null then
    raise exception '4d self-assert FAIL: nohome_dock_returning_ship still deployed (RECONGONE)';
  end if;

  -- the leaf is NOT client-executable (server/cron only — the reconciler's posture carried over).
  if has_function_privilege('authenticated', 'public.process_shield_idle_regen()', 'execute')
     or has_function_privilege('anon', 'public.process_shield_idle_regen()', 'execute') then
    raise exception '4d self-assert FAIL: process_shield_idle_regen is client-executable (must be service_role only)';
  end if;
  if not has_function_privilege('service_role', 'public.process_shield_idle_regen()', 'execute') then
    raise exception '4d self-assert FAIL: service_role cannot execute process_shield_idle_regen (the cron would silently die)';
  end if;

  -- NOSTRAND post-cycle sweep: zero ships in ANY movement status (all four; guaranteed by the 4c
  -- CHECK, asserted anyway — a stranded row here would be invisible forever with no reconciler).
  select count(*) into v_n
    from public.main_ship_instances
    where status in ('traveling','returning','hunting','stationary');
  if v_n > 0 then
    raise exception '4d self-assert FAIL: % ship(s) stranded in a movement status after the reconciler delete (NOSTRAND)', v_n;
  end if;

  raise notice '4d self-assert ok: idle shield regen rehomed verbatim into process_shield_idle_regen (NaN guard + drain-floor + fire-guard + encounter exclusion intact, service_role-only), scheduled once at 30 seconds; the reconciler cron and both functions are gone; zero ships stranded in any movement status';
end $recon4d_close$;
