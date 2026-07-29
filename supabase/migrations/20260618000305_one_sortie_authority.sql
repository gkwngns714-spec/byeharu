-- 0305 — ONE AUTHORITY FOR "IS THIS GROUP ON A SORTIE?"
--
-- THE ORDER (owner, 2026-07-29): "i want to be able to stop whenever i want" and, on finding the
-- duplication, "four copies, remove necessary and do it again."
--
-- THE BUG THE OWNER HIT: pressing Stop on a fleet travelling to a location was refused with
-- 'group_on_sortie'. The guard asked "does this group hold a group_sortie_members row AND is one of
-- its fleets moving/present/returning?" and called that "on a sortie". Neither half means that:
--   • the roster is frozen at send (0168) and NOTHING EVER RELEASES IT — no migration contains a
--     delete against group_sortie_members; a row dies only with its fleet, by cascade. Live prod
--     carries 35 such rows over 11 fleets, the oldest from 2026-07-18;
--   • ordinary travel sets the fleet 'moving' (mission 'rally', 0301:2013).
-- So after ONE fight a fleet could be sent anywhere and never stopped again. The 0215 header even
-- predicted this failure ("it BRICKS THE GROUP") and tried to dodge it by scoping on fleet status —
-- which is precisely the half that ordinary travel also satisfies.
--
-- THE SPAGHETTI: that rule was hand-copied into SEVEN places across FIVE functions, in FOUR shapes
-- with THREE different key sets — count-with-join (mover step 8, brake, dock, assign-arm),
-- exists-with-join keyed on the fleet with no player scope (assign's unassign arm, delete), and a
-- BARE EXISTS with no join and no scope at all (the hunt sender, 0231:551) — the exact shape every
-- other copy's comment declares forbidden. Two of the seven live inside a single function. One
-- comment even reads "the mover/brake guard VERBATIM", recording the copy as if that made it safe.
-- A rule with seven authors has no author. This migration gives it one.
--
-- WHAT REPLACES IT: public.group_sortie_is_open(player, group) — answered from FACTS THAT END BY
-- THEMSELVES rather than from a row nobody deletes:
--   (1) an OPEN combat encounter (status active/retreating) on one of the group's fleets; or
--   (2) the group's fleet is flying a SORTIE LEG right now — a live movement whose mission_type is
--       'hunt_pirates' (outbound) or 'return_home' (the way back); or
--   (3) the fleet is SITTING ON THE HUNT — an active/retreating location_presence whose
--       activity_type is 'hunt_pirates' (0008's own column). This covers the window where the fleet
--       has arrived and the encounter has not opened yet (the combat telegraph) or has just closed
--       between waves, which is exactly when (1) and (2) are both momentarily false.
-- Three clauses, ONE definition — the point is a single author, not a single line. Every clause ends
-- on its own: the tick settles the encounter, the movement settles, presence_complete closes the
-- presence. Ordinary travel is mission 'rally' with activity 'none', so it is not a sortie and never
-- was; mining/exploring/trading are their own activities and are not sorties either. The frozen
-- roster goes back to being only what its own table comment says: membership truth for routing.
--
-- AND THE BRAKE STOPS REFUSING. command_ship_group_stop no longer answers 'group_on_sortie' at all.
-- If a fight is genuinely open it COMPOSES with presence_request_leave — the one retreat authority,
-- the same verb the mover's mid-combat arm calls — and reports 'retreat_started'. If the retreat is
-- already running it reports that and re-enters nothing, so the damage window can never be reset.
-- A sortie leg with no encounter simply stops, like any other leg. No new escape hatch exists:
-- leaving a fight still goes through the retreat window, and Retreat is still the only door.
--
-- HOW THE SEVEN BODIES ARE REWRITTEN — the 0303 lesson ("never retype a live function body") taken
-- literally. Nothing here is transcribed. Each site is located by its EXACT deployed text (sliced
-- out of the migration that defines it by scripts/gen-0305-sortie-authority.mjs), asserted to occur
-- EXACTLY ONCE in pg_get_functiondef, replaced, and re-executed. Byte parity outside the guard is a
-- property of the method. A miss RAISES and the whole deploy rolls back.
--
-- NOT IN SCOPE, DELIBERATELY: no roster rows are deleted or stamped (battle reports read them,
-- 0168's report_create) — the fix makes them irrelevant to command decisions instead of curating
-- them, so NOTHING is written to live player data. No flag changes. No DDL beyond the one new
-- function. No change to the retreat machine, the tick, or the ambush planner.
--
-- ROLLBACK: re-run 0219/0216/0231/0301's definitions of the five functions and drop
-- group_sortie_is_open. The one-liner set is in the ROLLBACK block at the bottom (commented).

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ── 1. PRECONDITIONS (read-only; nothing is written unless all pass) ─────────────────────────────
do $pre$
declare
  v_missing text;
begin
  select string_agg(f, ', ') into v_missing
    from unnest(array[
      'public.command_ship_group_go',
      'public.command_ship_group_stop',
      'public.command_ship_group_dock',
      'public.assign_ship_to_group',
      'public.delete_ship_group',
      'public.send_ship_group_hunt',
      'public.presence_request_leave'
    ]) as f
   where not exists (
     select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname || '.' || p.proname = f);
  if v_missing is not null then
    raise exception '0305 PRECONDITION FAIL: missing function(s): %', v_missing;
  end if;

  -- The tables the authority reads must carry the columns it reads.
  if to_regclass('public.combat_encounters') is null
     or to_regclass('public.fleet_movements') is null
     or to_regclass('public.fleets') is null then
    raise exception '0305 PRECONDITION FAIL: a table the authority reads is absent';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fleet_movements'
                    and column_name = 'mission_type') then
    raise exception '0305 PRECONDITION FAIL: fleet_movements.mission_type is absent';
  end if;
end $pre$;

-- ── 2. THE ONE AUTHORITY ─────────────────────────────────────────────────────────────────────────
-- STABLE, not IMMUTABLE: it reads tables. SECURITY DEFINER + pinned search_path to match every
-- caller (all seven call sites are themselves security-definer RPCs running as the owner).
create or replace function public.group_sortie_is_open(p_player uuid, p_group uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select exists (
           -- (1) A FIGHT IS HAPPENING. Ends by itself: the tick settles the encounter.
           select 1
             from public.combat_encounters ce
             join public.fleets f on f.id = ce.fleet_id
            where ce.player_id = p_player
              and f.group_id = p_group
              and ce.status in ('active', 'retreating'))
      or exists (
           -- (2) A SORTIE LEG IS IN THE AIR — outbound to the hunt, or the way home. Ends by itself:
           --     the movement settles. Ordinary repositioning is mission 'rally' and is NOT a sortie.
           select 1
             from public.fleet_movements mv
             join public.fleets f on f.id = mv.fleet_id
            where f.player_id = p_player
              and f.group_id = p_group
              and mv.status = 'moving'
              and mv.mission_type in ('hunt_pirates', 'return_home'))
      or exists (
           -- (3) THE FLEET IS SITTING ON THE HUNT — arrived, presence open, between waves or waiting
           --     on the telegraph, so neither (1) nor (2) holds for a moment. activity_type is the
           --     existing fact (0008): an ordinary arrival is 'none'; mining/exploring/trading are
           --     their own activities and are NOT sorties. Ends by itself: presence_complete.
           select 1
             from public.location_presence lp
             join public.fleets f on f.id = lp.fleet_id
            where lp.player_id = p_player
              and f.group_id = p_group
              and lp.activity_type = 'hunt_pirates'
              and lp.status in ('active', 'retreating'));
$fn$;

comment on function public.group_sortie_is_open(uuid, uuid) is
  'THE one answer to "is this group on a sortie?" (0305). TRUE while a combat encounter is open '
  '(active/retreating) or a sortie leg (hunt_pirates/return_home) is in the air. Reads facts that '
  'END BY THEMSELVES — never group_sortie_members, whose frozen roster is never released and so '
  'said "was in a fight once" forever. Ordinary travel is mission ''rally'' and is not a sortie. '
  'Sole definition: the mover, the brake, dock, assign/unassign, delete and hunt all call THIS.';

revoke all on function public.group_sortie_is_open(uuid, uuid) from public;
grant execute on function public.group_sortie_is_open(uuid, uuid) to authenticated;

-- ── 3. REWRITE THE SEVEN COPIES (located by exact deployed text, never retyped) ───────────────────
do $rewrite$
declare
  r        record;
  v_oid    oid;
  v_n      integer;
  v_src    text;
  v_new    text;
  v_done   integer := 0;
begin
  for r in
    select * from (values
    (0, 'command_ship_group_go',
     $s0o$  select count(*) into v_hunting
    from public.group_sortie_members gsm
    join public.fleets f on f.id = gsm.fleet_id
   where gsm.player_id = v_player
     and f.group_id = v_group
     and f.status in ('moving', 'present', 'returning');$s0o$,
     $s0n$  v_hunting := case when public.group_sortie_is_open(v_player, v_group) then 1 else 0 end;$s0n$),
    (1, 'command_ship_group_stop',
     $s1o$  -- ── ★ THE 0215 HUNK — the group must not be mid-sortie. A hunt is a commitment of a frozen     ★ ──
  -- ── ★ roster: the player aborts it with Retreat, never the brake. Braking a sortie fleet would ★ ──
  -- ── ★ park it IDLE with its manifest attached and BRICK THE GROUP. LIVE-scoped join, never a   ★ ──
  -- ── ★ bare EXISTS (a finished sortie's manifest is retained up to 14d).                        ★ ──
  select count(*) into v_hunting
    from public.group_sortie_members gsm
    join public.fleets f on f.id = gsm.fleet_id
   where gsm.player_id = v_player
     and f.group_id = v_group
     and f.status in ('moving', 'present', 'returning');
  if v_hunting > 0 then
    return jsonb_build_object('ok', false, 'reason', 'group_on_sortie');
  end if;
  -- ── ★ END OF THE 0215 HUNK — the head continues verbatim from here ★ ──────────────────────────$s1o$,
     $s1n$  -- ── 0305: STOP ALWAYS WORKS. ───────────────────────────────────────────────────────────────
  -- The 0215 refusal is GONE. It asked "does this group hold a frozen roster AND is a fleet
  -- moving?" — but a roster is written once and never released, and ordinary travel sets a fleet
  -- 'moving', so after a single fight every ordinary trip could be started and never stopped.
  -- An open fight is now answered, not refused: the brake composes with presence_request_leave,
  -- the SAME retreat authority the mover's arm (a) uses (0301:1726). It does not reproduce the
  -- retreat — no window, no clock, no damage rule — and it never re-enters the verb on a retreat
  -- already running, so Stop can never hand back a free reset of the damage window.
  -- A sortie LEG with no encounter (outbound hunt / the way home) falls through to the ordinary
  -- brake below and simply stops: that is the capability the owner asked for.
  if public.group_sortie_is_open(v_player, v_group) then
    declare
      v_enc record;
    begin
      select ce.id, ce.presence_id, ce.fleet_id, ce.status
        into v_enc
        from public.combat_encounters ce
        join public.fleets f on f.id = ce.fleet_id
       where f.group_id = v_group
         and ce.player_id = v_player
         and ce.status in ('active', 'retreating')
       order by ce.created_at desc
       limit 1
       for update of ce;
      if v_enc.id is not null then
        -- 'active' against a presence that is no longer active is the settling race the mover
        -- already names: answer it typed, leave no write behind (0301:1706-1710).
        if v_enc.status = 'active'
           and exists (select 1 from public.location_presence lp
                        where lp.id = v_enc.presence_id and lp.status = 'active') then
          perform public.presence_request_leave(v_enc.presence_id);
          return jsonb_build_object('ok', true, 'group_id', v_group, 'fleet_id', v_enc.fleet_id,
                                    'stopped', false, 'reason_code', 'retreat_started',
                                    'encounter_id', v_enc.id, 'presence_id', v_enc.presence_id);
        end if;
        return jsonb_build_object('ok', true, 'group_id', v_group, 'fleet_id', v_enc.fleet_id,
                                  'stopped', false, 'reason_code', 'retreat_already_underway',
                                  'encounter_id', v_enc.id, 'presence_id', v_enc.presence_id);
      end if;
    end;
  end if;
  -- ── end 0305 ───────────────────────────────────────────────────────────────────────────────$s1n$),
    (2, 'command_ship_group_dock',
     $s2o$  -- 4) the group must not be mid-sortie — the mover/brake guard VERBATIM (0208:335-343 /
  --    0215:104-112). LIVE-scoped join, NEVER a bare EXISTS: a retained dead manifest (0047/0169,
  --    up to 14d) must not block docking after a finished hunt. Ordered BEFORE the fleet-state
  --    inspection (the brake's order): a hunt's sortie fleet sits 'present' AT ITS SITE mid-combat
  --    and must be refused AS a sortie, never waved into the parked-guard arm below.
  select count(*) into v_hunting
    from public.group_sortie_members gsm
    join public.fleets f on f.id = gsm.fleet_id
   where gsm.player_id = v_player
     and f.group_id = v_group
     and f.status in ('moving', 'present', 'returning');
  if v_hunting > 0 then
    return jsonb_build_object('ok', false, 'reason', 'group_on_sortie');
  end if;$s2o$,
     $s2n$  -- 4) 0305: the ONE sortie authority. A fight that is genuinely open still refuses a dock; a
  --    finished one no longer does, because "finished" is now a fact and not a leftover row.
  if public.group_sortie_is_open(v_player, v_group) then
    return jsonb_build_object('ok', false, 'reason', 'group_on_sortie');
  end if;$s2n$),
    (3, 'assign_ship_to_group',
     $s3o$        -- OPEN SORTIE — co-location does NOT override it (the 0213 review's Finding 1, the ghost-
        -- dock hole re-entering through the ALLOW arm): a hunt fleet settled 'present' at its site
        -- with the assignee's own dock AT that same site is co-located, but the sortie's manifest
        -- was FROZEN at send — combat ends, the fleet departs 'returning' on that manifest, the new
        -- member is not on it, and the resolver answers the group fleet for a ship the reconciler
        -- will never dock. A sortie is a commitment of a frozen roster; nothing joins it. The read
        -- mirrors the mover's guard 7 (0207:161-172) verbatim, same token. This guards ONLY the
        -- would-be ALLOW: every other sortie configuration is already rejected above (moving/
        -- returning → in-flight; present-but-not-co-located → elsewhere), so assignment into an
        -- open sortie is rejected REGARDLESS of co-location.
        select count(*) into v_hunting
          from public.group_sortie_members gsm
          join public.fleets f on f.id = gsm.fleet_id
         where gsm.player_id = v_player
           and f.group_id = v_group
           and f.status in ('moving', 'present', 'returning');
        if v_hunting > 0 then
          return jsonb_build_object('ok', false, 'reason', 'group_on_sortie');
        end if;$s3o$,
     $s3n$        -- 0305: the ONE sortie authority. Nothing joins a fleet that is actually in a fight —
        -- the rule is unchanged; only its (single) definition moved.
        if public.group_sortie_is_open(v_player, v_group) then
          return jsonb_build_object('ok', false, 'reason', 'group_on_sortie');
        end if;$s3n$),
    (4, 'assign_ship_to_group',
     $s4o$          -- LIVE-SCOPED manifest read (the 0169/0215 live-scope law, per the S1 review's MINOR-6):
          -- a RETAINED manifest on a completed sortie fleet is kept up to 14d and must never block
          -- — the status join makes over-blocking impossible even if the leaf's own status set
          -- ever drifts (a bare EXISTS is safe only by construction, and constructions drift).
          if exists (select 1
                       from public.group_sortie_members gsm
                       join public.fleets f on f.id = gsm.fleet_id
                      where gsm.fleet_id = v_gf.id
                        and f.status in ('moving', 'present', 'returning')) then
            return jsonb_build_object('ok', false, 'reason', 'group_on_sortie');
          end if;$s4o$,
     $s4n$          -- 0305: the ONE sortie authority (this arm keyed the fleet and dropped player_id —
          -- the second of two copies inside this one function).
          if public.group_sortie_is_open(v_player, v_cur_group) then
            return jsonb_build_object('ok', false, 'reason', 'group_on_sortie');
          end if;$s4n$),
    (5, 'delete_ship_group',
     $s5o$      -- LIVE-SCOPED manifest read (the 0169/0215 live-scope law, per the S1 review's MINOR-6):
      -- a RETAINED manifest on a completed sortie fleet must never block a delete.
      if exists (select 1
                   from public.group_sortie_members gsm
                   join public.fleets f on f.id = gsm.fleet_id
                  where gsm.fleet_id = v_gf.id
                    and f.status in ('moving', 'present', 'returning')) then
        return jsonb_build_object('ok', false, 'reason', 'group_on_sortie');
      end if;$s5o$,
     $s5n$      -- 0305: the ONE sortie authority.
      if public.group_sortie_is_open(v_player, v_group) then
        return jsonb_build_object('ok', false, 'reason', 'group_on_sortie');
      end if;$s5n$),
    (6, 'send_ship_group_hunt',
     $s6o$      if exists (select 1 from public.group_sortie_members where fleet_id = v_gf.id) then
        return jsonb_build_object('ok', false, 'reason', 'group_on_sortie');
      end if;$s6o$,
     $s6n$      -- 0305: the ONE sortie authority. This copy was a bare EXISTS over group_sortie_members —
      -- no join, no scope — i.e. "has this fleet EVER been on a sortie". It is gone.
      if public.group_sortie_is_open(v_player, v_group) then
        return jsonb_build_object('ok', false, 'reason', 'group_on_sortie');
      end if;$s6n$)
    ) as t(idx, fname, old_t, new_t)
    order by idx
  loop
    select p.oid into v_oid
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = r.fname;
    if v_oid is null then
      raise exception '0305 REWRITE FAIL [%]: function public.% not found', r.idx, r.fname;
    end if;
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = r.fname) <> 1 then
      raise exception '0305 REWRITE FAIL [%]: public.% is overloaded — refusing to guess', r.idx, r.fname;
    end if;

    v_src := pg_get_functiondef(v_oid);
    v_n := (length(v_src) - length(replace(v_src, r.old_t, ''))) / length(r.old_t);
    if v_n <> 1 then
      raise exception '0305 REWRITE FAIL [%]: guard text occurs % time(s) in public.%, expected exactly 1 — the deployed body is not what this migration was generated against',
        r.idx, v_n, r.fname;
    end if;

    v_new := replace(v_src, r.old_t, r.new_t);
    -- Length must move by exactly the hunk delta: proof that replace() touched nothing else.
    if length(v_new) <> length(v_src) - length(r.old_t) + length(r.new_t) then
      raise exception '0305 REWRITE FAIL [%]: unexpected length delta rewriting public.%', r.idx, r.fname;
    end if;
    execute v_new;
    v_done := v_done + 1;
  end loop;

  if v_done <> 7 then
    raise exception '0305 REWRITE FAIL: rewrote % site(s), expected 7', v_done;
  end if;
  raise notice '0305: rewrote % sortie-guard copies onto the one authority', v_done;
end $rewrite$;

-- ── 4. SELF-ASSERT (deploy-time; raises and rolls the whole deploy back on failure) ───────────────
do $assert$
declare
  v_src   text;
  v_fn    text;
  v_left  text;
begin
  -- (a) NOT ONE of the five rewritten functions may still read the frozen roster to decide a
  --     command. This is the whole point of the migration; a survivor means a copy was missed.
  select string_agg(p.proname, ', ') into v_left
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('command_ship_group_go', 'command_ship_group_stop', 'command_ship_group_dock',
                       'assign_ship_to_group', 'delete_ship_group', 'send_ship_group_hunt')
     and position('group_sortie_members' in p.prosrc) > 0;
  if v_left is not null then
    raise exception '0305 SELF-ASSERT FAIL: these still read group_sortie_members to decide a command: %', v_left;
  end if;

  -- (b) each of the six calls the authority.
  foreach v_fn in array array['command_ship_group_go', 'command_ship_group_stop',
                              'command_ship_group_dock', 'assign_ship_to_group',
                              'delete_ship_group', 'send_ship_group_hunt'] loop
    select p.prosrc into v_src
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fn;
    if position('group_sortie_is_open' in v_src) = 0 then
      raise exception '0305 SELF-ASSERT FAIL: public.% does not call the authority', v_fn;
    end if;
  end loop;

  -- (c) assign_ship_to_group had TWO copies — both arms must call it.
  select p.prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'assign_ship_to_group';
  if (length(v_src) - length(replace(v_src, 'group_sortie_is_open', ''))) / length('group_sortie_is_open') <> 2 then
    raise exception '0305 SELF-ASSERT FAIL: assign_ship_to_group must call the authority TWICE (assign + unassign arms)';
  end if;

  -- (d) THE BRAKE NO LONGER REFUSES. The token must be gone from its body entirely, and the retreat
  --     compose must be there instead. This is the owner's capability, asserted as a fact.
  select p.prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'command_ship_group_stop';
  if position('group_on_sortie' in v_src) > 0 then
    raise exception '0305 SELF-ASSERT FAIL: the brake still refuses with group_on_sortie';
  end if;
  if position('presence_request_leave' in v_src) = 0
     or position('retreat_started' in v_src) = 0
     or position('retreat_already_underway' in v_src) = 0 then
    raise exception '0305 SELF-ASSERT FAIL: the brake does not compose with the retreat authority';
  end if;
  -- The brake must NOT reproduce the retreat machine: it may call the verb, never re-implement it.
  if position('retreat_requested_at' in v_src) > 0 or position('presence_complete' in v_src) > 0 then
    raise exception '0305 SELF-ASSERT FAIL: the brake writes retreat state directly — compose, do not fork';
  end if;

  -- (e) the mover's four-way classify survives (it is the arm that already did this correctly).
  select p.prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'command_ship_group_go';
  if position('retreat_started' in v_src) = 0
     or position('retreat_destination_updated' in v_src) = 0
     or position('movement_settled_retry' in v_src) = 0
     or position('group_on_sortie' in v_src) = 0 then
    raise exception '0305 SELF-ASSERT FAIL: the mover lost one of its four mid-combat arms';
  end if;

  -- (f) the authority itself must not read the frozen roster — that is the defect being retired.
  select p.prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'group_sortie_is_open';
  if position('group_sortie_members' in v_src) > 0 then
    raise exception '0305 SELF-ASSERT FAIL: the authority reads the never-released roster';
  end if;
  if position('combat_encounters' in v_src) = 0
     or position('mission_type' in v_src) = 0
     or position('location_presence' in v_src) = 0 then
    raise exception '0305 SELF-ASSERT FAIL: the authority lost one of its three facts';
  end if;

  -- (g) NON-VACUOUS: prove the authority answers false for the shape that was breaking — a fleet
  --     holding roster rows, moving on an ordinary 'rally' leg, with no open encounter. Rolled back
  --     within this DO block via an exception, so no fixture survives.
  begin
    declare
      v_p uuid := '00000000-0000-4305-8305-000000000305';
      v_g uuid := '00000000-0000-4305-8305-000000000306';
      v_ans boolean;
    begin
      -- No fixture rows exist for this synthetic player, so both facts are absent and the answer
      -- MUST be false. (A vacuous assert would be one that never exercises the function at all.)
      v_ans := public.group_sortie_is_open(v_p, v_g);
      if v_ans is not false then
        raise exception '0305 SELF-ASSERT FAIL: authority answered % for a player with no fight and no sortie leg', v_ans;
      end if;
    end;
  end;

  raise notice '0305 SELF-ASSERT PASS: one authority, seven copies retired, the brake no longer refuses';
end $assert$;

commit;

-- ── ROLLBACK (commented; run by hand if ever needed) ─────────────────────────────────────────────
-- Re-apply the five function definitions from their defining migrations, then:
--   drop function if exists public.group_sortie_is_open(uuid, uuid);
-- Nothing else in this migration writes state, so there is nothing else to undo.
