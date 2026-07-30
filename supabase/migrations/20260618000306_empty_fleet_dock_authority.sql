-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0306 — A FLEET WITH NO SHIPS IS NOT A FLEET
--        (and "is this fleet docked?" finally gets ONE definition)
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- THE BUG THE OWNER HIT: "my fleet has no ship, so it has nothing, yet i can't assign ship to fleet
-- since the fleet is not docked."
--
-- THE DEADLOCK, exactly. assign_ship_to_group judges a group by its FLEET and never by its
-- MEMBERSHIP (0216:306-320 asks only about the row ship_group_resolve_fleet returns). That is fine
-- while the two agree. They stop agreeing because the UNASSIGN arm berths the departing ship but
-- never retires the group's fleet — unlike delete_ship_group, which has always consumed it
-- (0216:595-609). Nothing else collects one either: the retention reaper (0047:174-194) only deletes
-- fleets ALREADY completed/destroyed. So removing the last ship from a fleet leaves a member-less
-- group owning a live fleet, pinned at a port, permanently. From that state every exit is closed:
--
--   assign a ship   → 0216:315-320 co-location fails (the ship is berthed elsewhere) → group_fleet_elsewhere
--   move it to me   → 0301:1582-1584 empty_group
--   dock it         → 0219:147-149 timed_docking_disabled (the verb is dark, 0300:74)
--   delete it       → 0216:595-609 needs the fleet DOCKED; idle/moving → fleet_in_flight
--
-- ...and a berthed ship has no mover of its own under the unified model, so it cannot come to the
-- ghost either. The fleet is bricked, and so is the group slot.
--
-- THE SPAGHETTI (the owner's actual complaint). "The fleet is docked" is the conjunction
-- `status = 'present' AND location_mode = 'location' AND current_location_id IS NOT NULL`, and it is
-- hand-copied ELEVEN times with no authority — THREE of them inside assign_ship_to_group alone.
-- This is the same shape 0305 retired for "is this group on a sortie?", and it was never done for
-- docking. 0306 gives it one definition and folds the copies that live in the two roster functions.
--
-- WHAT THIS MIGRATION DOES
--   1. public.fleet_docked_location(fleets) — THE docked authority. Pure over a row already in
--      hand (IMMUTABLE, reads nothing), so folding the copies adds NO second snapshot: the
--      one-statement-one-snapshot property the 0213 review won at 0216:273-277 is preserved.
--   2. public.group_fleet_retire(player, fleet) — THE retire idiom, lifted verbatim out of
--      delete_ship_group, which was its only instance.
--   3. public.group_retire_empty_fleet(player, group) — THE collector. Retires a group's live
--      fleet only when the group has NO members and no fight is open (composing with 0305's
--      group_sortie_is_open rather than inventing a second "is it busy" rule).
--   4. Rewrites 7 hunks across assign_ship_to_group and delete_ship_group onto 1-3, by SLICING the
--      deployed text (scripts/gen-0306-dock-authority.mjs) — nothing retyped, per the 0303 lesson.
--   5. BACKFILLS: retires every already-orphaned fleet, which is what unbricks the owner's game.
--
-- BLAST RADIUS. Prod is a live ~30-player game. The backfill writes ONLY to fleets that hold no
-- ships — by definition no player asset is inside one — and only to idle/present ones, never to a
-- fleet in flight (a moving fleet keeps its movement row and settles by itself; it is collected on
-- the next assign/unassign once it has settled). Nothing is deleted; fleets are 'completed', the
-- same terminal state delete_ship_group has always written. group_sortie_members is not touched.
--
-- NON-GOALS (named, not silently skipped). The remaining SIX copies of the docked test are read-side
-- projections in other functions and are NOT folded here — 0210:178-186 and 0210:299-303
-- (mainship_space_validate_context, mainship_resolve_docked_location), 0231:1069-1073
-- (get_my_fleet_positions), 0231:1486-1501 (move_ship_group_to_location, whose predicate carries two
-- extra conjuncts), 0297:126-131 (mainship_port_of_ship). They now have an authority to fold onto;
-- doing it here would put the map projection and the movement oracle in a roster-bug slice.
-- No flag is flipped. No new client-callable RPC. No client change.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 1. THE ONE DOCKED AUTHORITY ──────────────────────────────────────────────────────────────────
-- IMMUTABLE, not STABLE: it reads no tables at all — it is a pure predicate over a fleets row the
-- caller already holds. That is the whole point. A re-querying authority would have re-introduced
-- the two-snapshot phantom read that 0216:273-277 exists to prevent.
create or replace function public.fleet_docked_location(f public.fleets)
returns uuid
language sql
immutable
as $fn$
  select case
           when f.status = 'present'
            and f.location_mode = 'location'
            and f.current_location_id is not null
           then f.current_location_id
           else null
         end;
$fn$;

comment on function public.fleet_docked_location(public.fleets) is
  'THE one answer to "is this fleet docked, and where?" (0306). Non-null = the port it is settled '
  'at; NULL = not docked (in flight, or parked in open space). Pure over a row already in hand, so '
  'callers fold onto it without paying a second snapshot. Sole definition of '
  'status=present AND location_mode=location AND current_location_id IS NOT NULL.';

-- ── 2. THE ONE RETIRE IDIOM ──────────────────────────────────────────────────────────────────────
-- Lifted out of delete_ship_group (0216:598-606), which was its only instance. Same statements,
-- same order, plus a player scope that was previously implied by the caller's leaf.
create or replace function public.group_fleet_retire(p_player uuid, p_fleet uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $fn$
begin
  perform public.presence_complete(lp.id)
    from public.location_presence lp
   where lp.fleet_id = p_fleet and lp.status = 'active';
  update public.fleets
     set status = 'completed', location_mode = 'movement', active_movement_id = null,
         space_x = null, space_y = null,
         current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
         updated_at = now()
   where id = p_fleet and player_id = p_player;
end $fn$;

comment on function public.group_fleet_retire(uuid, uuid) is
  'THE one way a group fleet is consumed (0306): close its active presence, then park it '
  'completed with every position column cleared. Extracted from delete_ship_group 0216:598-606.';

-- ── 3. THE COLLECTOR ─────────────────────────────────────────────────────────────────────────────
create or replace function public.group_retire_empty_fleet(p_player uuid, p_group uuid)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_n integer := 0;
  v_f record;
begin
  if p_player is null or p_group is null then
    return 0;
  end if;
  -- A group with ANY member owns its fleet legitimately. This is the membership question the
  -- assign guard never asked, and the whole reason the deadlock existed.
  if exists (select 1
               from public.main_ship_instances s
              where s.group_id = p_group and s.player_id = p_player) then
    return 0;
  end if;
  -- A live fight owns the fleet even with the roster gone — compose with the 0305 authority
  -- instead of inventing a second opinion about whether a group is busy.
  if public.group_sortie_is_open(p_player, p_group) then
    return 0;
  end if;
  -- Only settled fleets. A member-less fleet still in flight keeps its movement row and settles by
  -- itself; collecting it here would strand that movement. It is collected on the next pass.
  for v_f in select * from public.ship_group_resolve_fleet(p_player, p_group) loop
    if v_f.status in ('idle', 'present') then
      perform public.group_fleet_retire(p_player, v_f.id);
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end $fn$;

comment on function public.group_retire_empty_fleet(uuid, uuid) is
  'THE collector (0306): a group with no ships has no fleet. Retires a member-less group''s settled '
  'fleet so it can never again judge an assign by a ghost. No-op while any member remains, while a '
  'fight is open (group_sortie_is_open), or while the fleet is in flight.';

-- ACLs: all three are internal leaves — every caller is itself a security-definer RPC. Explicitly
-- revoked rather than merely un-granted (the 0254 prod grant-drift lesson: a Supabase default GRANT
-- can leave a new object client-callable).
revoke execute on function public.fleet_docked_location(public.fleets) from public, anon, authenticated;
revoke execute on function public.group_fleet_retire(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.group_retire_empty_fleet(uuid, uuid) from public, anon, authenticated;

-- ── 4. FOLD THE COPIES ───────────────────────────────────────────────────────────────────────────
-- The 0305 rewrite method: slice the deployed text, prove it occurs EXACTLY once, replace, prove
-- the length moved by exactly the hunk delta, re-execute. Nothing is retyped.
do $rewrite$
declare
  r record;
  v_oid oid;
  v_src text;
  v_new text;
  v_n integer;
  v_done integer := 0;
begin
  for r in
    select * from (values
    (1, 'assign_ship_to_group',
     $h1o$      -- ONE statement, ONE snapshot (READ COMMITTED): the leaf is scanned with a single FOR loop
      -- that both counts the rows and captures the row. The first cut counted with one statement
      -- and re-selected with a second — TWO snapshots; the settle cron takes no group lock, so it
      -- could retire/replace the fleet between them and hand the checks an all-NULL row (a
      -- spurious reject from a phantom read — the 0213 review's Finding 3).
      v_gf_n := 0;
      for v_gf in select * from public.ship_group_resolve_fleet(v_player, v_group) loop
        v_gf_n := v_gf_n + 1;
      end loop;$h1o$,
     $h1n$      -- 0306: A GROUP WITH NO SHIPS HAS NO FLEET. This assign is about to be judged against the
      -- group's FLEET — never against its membership — so a member-less group that still owns a
      -- live fleet judges every future assign by a ghost (see the header's deadlock). Collect it
      -- first: the collector is a no-op unless the group is genuinely empty and not in a fight.
      -- Runs under the group lock taken above, so nothing can join between the collect and the read.
      perform public.group_retire_empty_fleet(v_player, v_group);
      -- ONE statement, ONE snapshot (READ COMMITTED): the leaf is scanned with a single FOR loop
      -- that both counts the rows and captures the row. The first cut counted with one statement
      -- and re-selected with a second — TWO snapshots; the settle cron takes no group lock, so it
      -- could retire/replace the fleet between them and hand the checks an all-NULL row (a
      -- spurious reject from a phantom read — the 0213 review's Finding 3).
      v_gf_n := 0;
      for v_gf in select * from public.ship_group_resolve_fleet(v_player, v_group) loop
        v_gf_n := v_gf_n + 1;
      end loop;$h1n$),
    (2, 'assign_ship_to_group',
     $h2o$        if not (v_gf.status = 'present' and v_gf.location_mode = 'location'
                and v_gf.current_location_id is not null
                and v_ship_berth is not null
                and v_ship_berth = v_gf.current_location_id) then
          return jsonb_build_object('ok', false, 'reason', 'group_fleet_elsewhere');
        end if;$h2o$,
     $h2n$        -- 0306: THE ONE DOCKED AUTHORITY. Identical rule ("settled at a real port"), one
        -- definition — public.fleet_docked_location, evaluated over the row ALREADY in hand, so
        -- this still costs no second snapshot (the 0213 review's Finding 3 stays closed).
        -- `is distinct from` alone would let NULL berth meet NULL dock, so the berth is tested too.
        if v_ship_berth is null
           or public.fleet_docked_location(v_gf) is distinct from v_ship_berth then
          return jsonb_build_object('ok', false, 'reason', 'group_fleet_elsewhere');
        end if;$h2n$),
    (3, 'assign_ship_to_group',
     $h3o$        select f.current_location_id into v_berth
          from public.fleets f
         where f.id = public.mainship_resolve_fleet(v_ship)
           and f.status = 'present' and f.location_mode = 'location';$h3o$,
     $h3n$        select public.fleet_docked_location(f) into v_berth
          from public.fleets f
         where f.id = public.mainship_resolve_fleet(v_ship);$h3n$),
    (4, 'assign_ship_to_group',
     $h4o$          if v_gf.status = 'present' and v_gf.location_mode = 'location'
             and v_gf.current_location_id is not null then
            v_berth := v_gf.current_location_id;
          else
            -- parked in open space (0208/0209) or idle at its anchor: no port to berth at.
            return jsonb_build_object('ok', false, 'reason', 'fleet_in_flight');
          end if;$h4o$,
     $h4n$          -- 0306: THE ONE DOCKED AUTHORITY (copy 2 of 3 inside this one function).
          v_berth := public.fleet_docked_location(v_gf);
          if v_berth is null then
            -- parked in open space (0208/0209) or idle at its anchor: no port to berth at.
            return jsonb_build_object('ok', false, 'reason', 'fleet_in_flight');
          end if;$h4n$),
    (5, 'assign_ship_to_group',
     $h5o$  end if;

  return jsonb_build_object('ok', true, 'main_ship_id', v_ship, 'group_id', v_group);$h5o$,
     $h5n$  end if;

  -- 0306: THE SYMMETRY delete_ship_group ALWAYS HAD AND UNASSIGN NEVER DID. Removing the last ship
  -- used to leave the group empty and still owning a live docked fleet — forever, because nothing
  -- collects it (the retention reaper only touches fleets already completed/destroyed). That ghost
  -- is what then refused every attempt to put a ship back. Retire it here, post-write, so the
  -- membership read sees the departure. No-op while any member remains, or while a fight is open.
  if v_group is null and v_unified and v_cur_group is not null then
    perform public.group_retire_empty_fleet(v_player, v_cur_group);
  end if;

  return jsonb_build_object('ok', true, 'main_ship_id', v_ship, 'group_id', v_group);$h5n$),
    (6, 'delete_ship_group',
     $h6o$      if v_gf.status = 'present' and v_gf.location_mode = 'location'
         and v_gf.current_location_id is not null then
        v_port := v_gf.current_location_id;
        perform public.presence_complete(lp.id)
          from public.location_presence lp
         where lp.fleet_id = v_gf.id and lp.status = 'active';
        update public.fleets
           set status = 'completed', location_mode = 'movement', active_movement_id = null,
               space_x = null, space_y = null,
               current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
               updated_at = now()
         where id = v_gf.id;
      else
        return jsonb_build_object('ok', false, 'reason', 'fleet_in_flight');
      end if;$h6o$,
     $h6n$      -- 0306: THE ONE DOCKED AUTHORITY, and the ONE retire idiom. The consume below was the
      -- only place in the codebase that retired a group's fleet; group_fleet_retire is now that
      -- idiom's single definition and the empty-fleet collector calls the very same one.
      v_port := public.fleet_docked_location(v_gf);
      if v_port is null then
        return jsonb_build_object('ok', false, 'reason', 'fleet_in_flight');
      end if;
      perform public.group_fleet_retire(v_player, v_gf.id);$h6n$),
    (7, 'delete_ship_group',
     $h7o$           (select f.current_location_id
              from public.fleets f
             where f.id = public.mainship_resolve_fleet(s.main_ship_id)
               and f.status = 'present' and f.location_mode = 'location'),$h7o$,
     $h7n$           (select public.fleet_docked_location(f)
              from public.fleets f
             where f.id = public.mainship_resolve_fleet(s.main_ship_id)),$h7n$)
    ) as t(idx, fname, old_t, new_t)
    order by idx
  loop
    select p.oid into v_oid
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = r.fname;
    if v_oid is null then
      raise exception '0306 REWRITE FAIL [%]: function public.% not found', r.idx, r.fname;
    end if;
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = r.fname) <> 1 then
      raise exception '0306 REWRITE FAIL [%]: public.% is overloaded — refusing to guess', r.idx, r.fname;
    end if;

    v_src := pg_get_functiondef(v_oid);
    v_n := (length(v_src) - length(replace(v_src, r.old_t, ''))) / length(r.old_t);
    if v_n <> 1 then
      raise exception '0306 REWRITE FAIL [%]: hunk text occurs % time(s) in public.%, expected exactly 1 — the deployed body is not what this migration was generated against',
        r.idx, v_n, r.fname;
    end if;

    v_new := replace(v_src, r.old_t, r.new_t);
    if length(v_new) <> length(v_src) - length(r.old_t) + length(r.new_t) then
      raise exception '0306 REWRITE FAIL [%]: unexpected length delta rewriting public.%', r.idx, r.fname;
    end if;
    execute v_new;
    v_done := v_done + 1;
  end loop;

  if v_done <> 7 then
    raise exception '0306 REWRITE FAIL: rewrote % site(s), expected 7', v_done;
  end if;
  raise notice '0306: folded % docked-test/retire copies onto the one authority', v_done;
end $rewrite$;

-- ── 5. BACKFILL — unbrick every group already holding a ghost ────────────────────────────────────
do $backfill$
declare
  v_r record;
  v_n integer := 0;
begin
  for v_r in
    select distinct f.player_id, f.group_id
      from public.fleets f
     where f.group_id is not null
       and f.main_ship_id is null
       and f.status in ('idle', 'present')
       and not exists (select 1
                         from public.main_ship_instances s
                        where s.group_id = f.group_id and s.player_id = f.player_id)
  loop
    v_n := v_n + public.group_retire_empty_fleet(v_r.player_id, v_r.group_id);
  end loop;
  raise notice '0306 BACKFILL: retired % ghost fleet(s) owned by member-less groups', v_n;
end $backfill$;

-- ── 6. SELF-ASSERTS ──────────────────────────────────────────────────────────────────────────────
-- ONE DO BLOCK PER CHECK (the 0305 lesson: the Supabase CLI prints neither the raise message nor
-- notices — only "At statement: N" — so the statement number must BE the diagnosis).
-- Every body probe strips comments first (the 0303/0305 lesson: probe CODE, never PROSE).

-- (a) the three authorities exist
do $a$
begin
  if to_regprocedure('public.fleet_docked_location(public.fleets)') is null
     or to_regprocedure('public.group_fleet_retire(uuid,uuid)') is null
     or to_regprocedure('public.group_retire_empty_fleet(uuid,uuid)') is null then
    raise exception '0306 ASSERT (a) FAIL: an authority is missing';
  end if;
end $a$;

-- (b) assign_ship_to_group no longer contains a hand-written docked test
do $b$
declare v_code text;
begin
  select regexp_replace(prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'assign_ship_to_group';
  if v_code like '%location_mode = ''location''%' then
    raise exception '0306 ASSERT (b) FAIL: a docked-test copy survives in assign_ship_to_group';
  end if;
end $b$;

-- (c) delete_ship_group no longer contains one either
do $c$
declare v_code text;
begin
  select regexp_replace(prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'delete_ship_group';
  if v_code like '%location_mode = ''location''%' then
    raise exception '0306 ASSERT (c) FAIL: a docked-test copy survives in delete_ship_group';
  end if;
end $c$;

-- (d) both roster functions now go through the authority
do $d$
declare v_a text; v_d text;
begin
  select regexp_replace(prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_a
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'assign_ship_to_group';
  select regexp_replace(prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_d
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'delete_ship_group';
  if v_a not like '%fleet_docked_location%' or v_d not like '%fleet_docked_location%' then
    raise exception '0306 ASSERT (d) FAIL: a roster function does not call the docked authority';
  end if;
end $d$;

-- (e) the collector is wired into BOTH arms of assign_ship_to_group (assign + unassign), exactly twice
do $e$
declare v_code text; v_n integer;
begin
  select regexp_replace(prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'assign_ship_to_group';
  v_n := (length(v_code) - length(replace(v_code, 'group_retire_empty_fleet', ''))) / length('group_retire_empty_fleet');
  if v_n <> 2 then
    raise exception '0306 ASSERT (e) FAIL: the collector is called % time(s) in assign_ship_to_group, expected 2', v_n;
  end if;
end $e$;

-- (f) delete_ship_group retires through the one idiom, not its own copy
do $f$
declare v_code text;
begin
  select regexp_replace(prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'delete_ship_group';
  if v_code not like '%group_fleet_retire%' then
    raise exception '0306 ASSERT (f) FAIL: delete_ship_group does not use the retire idiom';
  end if;
  if v_code like '%presence_complete%' then
    raise exception '0306 ASSERT (f) FAIL: the retire idiom is still inlined in delete_ship_group';
  end if;
end $f$;

-- (g) 0305 is intact: assign still calls the sortie authority twice and never reads the roster
do $g$
declare v_code text; v_n integer;
begin
  select regexp_replace(prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'assign_ship_to_group';
  if v_code like '%group_sortie_members%' then
    raise exception '0306 ASSERT (g) FAIL: assign_ship_to_group reads group_sortie_members again';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'group_sortie_is_open', ''))) / length('group_sortie_is_open');
  if v_n <> 2 then
    raise exception '0306 ASSERT (g) FAIL: group_sortie_is_open called % time(s), expected 2 (0305 invariant)', v_n;
  end if;
end $g$;

-- (h) the backfill left no ghost behind
do $h$
declare v_n integer;
begin
  select count(*) into v_n
    from public.fleets f
   where f.group_id is not null
     and f.main_ship_id is null
     and f.status in ('idle', 'present')
     and not exists (select 1
                       from public.main_ship_instances s
                      where s.group_id = f.group_id and s.player_id = f.player_id)
     and not public.group_sortie_is_open(f.player_id, f.group_id);
  if v_n > 0 then
    raise exception '0306 ASSERT (h) FAIL: % member-less group(s) still own a settled fleet', v_n;
  end if;
end $h$;

-- (i) the authorities are not client-callable
do $i$
declare v_n integer;
begin
  select count(*) into v_n
    from (values ('public.fleet_docked_location(public.fleets)'),
                 ('public.group_fleet_retire(uuid,uuid)'),
                 ('public.group_retire_empty_fleet(uuid,uuid)')) as t(sig)
   where has_function_privilege('authenticated', t.sig, 'execute')
      or has_function_privilege('anon', t.sig, 'execute');
  if v_n > 0 then
    raise exception '0306 ASSERT (i) FAIL: % new authority function(s) are client-callable', v_n;
  end if;
end $i$;
