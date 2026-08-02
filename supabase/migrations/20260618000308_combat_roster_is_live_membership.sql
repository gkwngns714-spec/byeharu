-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0308 — THE COMBAT ROSTER IS LIVE MEMBERSHIP
--        (and a mining rig stops counting as a gun)
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- TWO DEFECTS, ONE FUNCTION. Both live inside combat_create_group_encounter (head 0301:661):
--
-- DEFECT 1 — A SHIP THAT LEFT A FLEET IS STILL DRAGGED INTO THAT FLEET'S NEXT FIGHT AND DESTROYED.
--   group_sortie_members is the frozen combat roster. The only functional release in the whole
--   chain is the brake's (0305:247), reachable only when Stop halts a live moving leg. Every fight
--   that ends by retreat, defeat or the forced 30-minute extract leaves the roster attached to the
--   PERSISTENT group fleet forever — and an ambushed fleet has no moving leg at all (0303:234
--   cancels it). The builder then read that stale set with no liveness check (0301:726-731: no
--   msi.group_id filter, nothing), and 0303:283 counted the same unfiltered set for the
--   empty-manifest guard, so stale rows actively satisfied the guard. Reachable sequence, every
--   step verified: fleet ambushed -> roster {A,B,C} frozen -> fight ends -> the player unassigns C
--   (legal: group_sortie_is_open is false, 0305:104-141) -> fleet ambushed again -> the idempotent
--   freeze inserts nothing -> the count reads leftovers -> C is seeded into combat_units, takes
--   tick damage while berthed at another port, and on defeat gets mainship_mark_combat_destroyed
--   (0299:516-518).
--
-- DEFECT 2 — A FITTED MINING RIG COUNTS AS A WEAPON AND SUPPRESSES THE ZERO-DAMAGE FALLBACK.
--   0301:773-776 built weapons_json with `t.range is not null` — not "is this module a weapon",
--   not "can it deal damage". mining_rig_extension is seeded range 120 / power 8 (0229:126-129,
--   asserted at 0229:513). The 0262 fallback (0301:791) is guarded on the array being EMPTY, so a
--   non-empty array of MINING RIGS blocked it permanently: a ship with attack_snapshot 60 and one
--   rig fitted fired power 8 — a 7.5x loss, while the card reported 60. Same class as the defect
--   that destroyed the owner's Fleet 1: 0262 fixed "empty array", never "array of non-guns".
--
-- ── WHAT THIS MIGRATION DOES ─────────────────────────────────────────────────────────────────────
--   1. public.group_sortie_live_members(fleet) — THE liveness authority. A roster row is honoured
--      only while its ship is still a member of the fleet's group NOW (msi.group_id = f.group_id,
--      same player). Composed at the three read-to-act sites: the builder's roster loop, the
--      resolver's empty-manifest count, and the flee verb's ride-home marking.
--      WHY THIS PREDICATE PRESERVES THE MANIFEST-WINS LAW: the manifest exists to freeze the
--      roster at send so a mid-sortie reassignment cannot rewrite a fight in progress. Since 0305,
--      assign/unassign/delete are REFUSED while group_sortie_is_open — membership cannot change
--      during a live sortie (including the telegraph window: clause 3 covers an active
--      hunt_pirates presence) — so live membership and the frozen manifest are EQUAL for the whole
--      life of a sortie, and the filter is an identity there. It can only diverge BETWEEN sorties,
--      where a departed ship must not fight. The manifest concept is kept, not deleted: the table,
--      its writers, and the routing gate (0301:919-921) are untouched.
--   2. public.group_sortie_release(player, fleet) — THE release idiom, extracted verbatim from the
--      brake (0305:247-248), which now composes it. The ambush resolver composes the SAME idiom
--      immediately before its freeze, turning the freeze into a true snapshot REPLACEMENT: a new
--      sortie on a fleet releases every leftover of the previous one. That point is passed by every
--      re-poisoning path, and it is the one place a release is consumer-safe (see the finding).
--   3. public.module_is_firing_weapon(module_types) — THE weapon authority: slot_type = 'weapon'
--      AND range IS NOT NULL AND power > 0. Proven against the deployed catalog below: both
--      autocannons qualify, the mining rig does not, and no seeded weapon is dropped. The 0262
--      fallback now fires for a rig-only ship (its array is empty), deriving power from the ship's
--      own attack — exactly what the card reports.
--
-- ── THE FINDING THE RELEASE PLACEMENT RESTS ON (verified, not inherited) ─────────────────────────
-- 0305:53-55 claimed roster deletion was out of scope because "battle reports read them". That is
-- FALSE: report_create (head 0234:1150-1194) reads combat_units and combat_encounters only. But a
-- release at the tick's conclusion branches (0299:514 defeat / 0299:544 retreat + forced extract)
-- would break TWO consumers that DO read the roster after a fight concludes:
--   - the return path: process_mainship_expeditions holds members un-reconciled while their
--     manifest fleet is live (0199:573-576, 0199:587-590) and nohome_dock_returning_ship reads the
--     manifest fleet's recorded return port to dock each member (0199:681-685). Releasing at
--     0299:544 would re-route/re-home live members MID-FLIGHT.
--   - captain XP: captain_xp_accrue attributes a combat reward grant through the roster AT ACCRUAL
--     TIME (0177:212), possibly minutes after the fight; captain_growth_enabled is lit (0300).
--     The team-command proof pins this green pre-SHIELD1 (scripts/team-command-proof.sql:2023-2033).
-- So the roster is NOT garbage at conclusion — it is the return trip's routing data and the XP
-- fold's attribution data. It becomes garbage when the fleet's NEXT sortie begins, which is where
-- the release now happens (and where the poison actually bites). Terminal fleets already release
-- by design: 0047's retention reaper deletes completed/destroyed fleets and the rows cascade
-- (0168:82). The remaining narrow window — a combat grant still unconsumed when the SAME fleet is
-- re-ambushed — degrades to 0177's designed sentinel path (consumed-with-no-credit), stated here
-- rather than hidden.
--
-- ── EVERY DEPLOYED CONSUMER OF group_sortie_members, AND THE IMPACT ON EACH ──────────────────────
--   combat_create_group_encounter 0301:728   read-to-act  -> composes the liveness authority (hunk 1)
--   pirate_intercept_resolve..    0303:284   read-to-act  -> composes the liveness authority (hunk 4)
--   combat_flee_pending           0230:215   read-to-act  -> composes the liveness authority (hunk 5)
--   combat_create_encounter       0301:921   routing gate -> UNTOUCHED: any manifest row (stale or
--     live) routes a group fleet to the group builder, which is correct for every group fleet; a
--     fleet with only stale rows cannot reach it (the count guard refuses upstream, and membership
--     cannot change during the telegraph window while group_sortie_is_open holds).
--   process_mainship_expeditions  0199:574,588,607,620  reconciler guards -> UNTOUCHED; the release
--     point keeps their input intact for the whole return trip (see the finding).
--   nohome_dock_returning_ship    0199:682   return-port lookup -> UNTOUCHED, same reason.
--   captain_xp_accrue             0177:212   XP attribution -> UNTOUCHED; narrow re-ambush window
--     degrades to the designed sentinel (stated above).
--   command_ship_group_stop       0305:247   the brake's release -> now composes the one idiom (hunk 6).
--   send_ship_group_hunt          0231:706/896/953  sole sender-writer -> UNTOUCHED. Its freeze
--     still accretes on a persistent fleet; that leak is bounded (PK fleet+ship; 0047 cascades
--     terminal fleets) and INERT after this migration (no read-to-act site consumes stale rows).
--     Folding the replacement into its three insert arms is a follow-up slice, deliberately not
--     smuggled in here.
--   group_sortie_is_open          0305       does NOT read the roster (0305 self-assert f).
--   client                        RLS SELECT grant (0168:96) exists; no client code reads the table.
--
-- ── CONSUMERS OF THE WEAPONS JOIN CONCEPT ────────────────────────────────────────────────────────
--   combat_create_group_encounter 0301:773-776 -> composes module_is_firing_weapon (hunk 2).
--   ship_weapon_modules 0229:159-188 -> UNTOUCHED ON PURPOSE: it is the "modules that carry a
--     spatial RANGE" read (weapon OR mining) feeding the client map-radius layer — a different
--     concept with a different truth; folding it onto the weapon authority would delete the mining
--     radius from the map.
--   mining_extract 0229 -> identifies MINING modules (slot_type='mining' or a mining stats key);
--     different concept, untouched.
--   process_combat_ticks -> a pure consumer of weapons_json; shape unchanged.
--
-- ── BLAST RADIUS ON LIVE PLAYER DATA ─────────────────────────────────────────────────────────────
--   - No data is written by this migration itself: no backfill, no roster rows deleted at deploy
--     time, no flag change, no client change. Live prod's ~35 retained rows stay untouched until
--     each fleet's next ambush replaces its own snapshot.
--   - Additive-safe roster rule: a ship that IS a member of the fleet's group is ALWAYS seeded —
--     the filter can only exclude a ship whose msi.group_id no longer matches, which is exactly a
--     ship the player moved out. During a live sortie the 0305 authority makes exclusion
--     impossible (membership is frozen by refusal).
--   - Weapon rule: a ship with a real gun is byte-identical (both autocannons pass all three
--     conjuncts). A rig-only ship gains the fallback (attack x knob, default x1) instead of 8.
--     A rig+gun ship loses the rig's phantom 8 damage — its combat output now matches its card.
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
-- Re-apply 0301's builder, 0303's resolver, 0230's flee and 0305's brake definitions, then
-- drop function public.group_sortie_live_members(uuid);
-- drop function public.group_sortie_release(uuid, uuid);
-- drop function public.module_is_firing_weapon(public.module_types);
-- Nothing else here writes state.
--
-- ── SELF-ASSERT MAP (one DO block per check — the statement number IS the diagnosis) ─────────────
--   (a) the three authorities exist with the right shape
--   (b) builder: raw roster read gone, liveness authority composed
--   (c) builder: range-test gone, weapon authority composed, 0262 fallback guard intact
--   (d) resolver: release composed BEFORE the freeze, count composed, guard order + freeze intact
--   (e) flee: raw roster read gone, liveness authority composed
--   (f) brake: inline delete gone, release composed, 0305 retreat-compose intact
--   (g) ONE release idiom: no function but group_sortie_release deletes from the roster
--   (h) weapon truth on the deployed catalog: rig refused, every seeded weapon kept
--   (i) liveness authority smoke: unknown fleet -> zero rows
--   (j) ACLs: no new authority is client-callable
--   (k) metadata parity: all four rewritten functions changed body and NOTHING else
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ── 0. PRECONDITIONS (read-only) ─────────────────────────────────────────────────────────────────
do $pre$
declare v_missing text;
begin
  if to_regclass('public.group_sortie_members') is null
     or to_regclass('public.module_types') is null
     or to_regclass('public.main_ship_instances') is null
     or to_regclass('public.fleets') is null then
    raise exception '0308 PRECONDITION FAIL: a table this migration composes over is absent';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'module_types'
                    and column_name in ('slot_type', 'range', 'power')
                 having count(*) = 3) then
    raise exception '0308 PRECONDITION FAIL: module_types lacks slot_type/range/power (0107/0229)';
  end if;
  select string_agg(f, ', ') into v_missing
    from unnest(array[
      'combat_create_group_encounter',
      'pirate_intercept_resolve_due_for_movement',
      'combat_flee_pending',
      'command_ship_group_stop',
      'group_sortie_is_open'
    ]) as f
   where not exists (
     select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = f);
  if v_missing is not null then
    raise exception '0308 PRECONDITION FAIL: missing function(s): %', v_missing;
  end if;
end $pre$;

-- ── 1. THE LIVENESS AUTHORITY ────────────────────────────────────────────────────────────────────
-- STABLE (reads tables), SECURITY DEFINER + pinned search_path to match every caller (all three
-- composition sites are themselves security-definer engine functions).
create or replace function public.group_sortie_live_members(p_fleet uuid)
returns setof public.group_sortie_members
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select gsm.*
    from public.group_sortie_members gsm
    join public.fleets f on f.id = gsm.fleet_id
    join public.main_ship_instances msi on msi.main_ship_id = gsm.main_ship_id
   where gsm.fleet_id = p_fleet
     and msi.player_id = gsm.player_id
     and f.group_id is not null
     and msi.group_id = f.group_id;
$fn$;

comment on function public.group_sortie_live_members(uuid) is
  'THE one answer to "which manifest rows are still this fleet''s roster?" (0308). A '
  'group_sortie_members row is honoured only while its ship is still a member of the fleet''s '
  'group NOW. Identity during a live sortie (0305 refuses assign/unassign while a sortie is '
  'open), so the manifest-wins law is intact; it diverges only BETWEEN sorties, where a departed '
  'ship must not be seeded into a fight, counted by the empty-manifest guard, or marked '
  '''returning'' by a flee. Composed by combat_create_group_encounter, '
  'pirate_intercept_resolve_due_for_movement and combat_flee_pending.';

-- ── 2. THE RELEASE IDIOM ─────────────────────────────────────────────────────────────────────────
-- Lifted verbatim from the brake (0305:247-248), which was its only instance and now composes it.
create or replace function public.group_sortie_release(p_player uuid, p_fleet uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $fn$
begin
  delete from public.group_sortie_members
   where fleet_id = p_fleet and player_id = p_player;
end $fn$;

comment on function public.group_sortie_release(uuid, uuid) is
  'THE one way a sortie roster is released (0308) — extracted from the brake''s 0305 release, '
  'same delete, same fleet+caller scope. Composed by command_ship_group_stop (aborting a sortie) '
  'and by the ambush resolver immediately before its freeze (a new sortie replaces the previous '
  'snapshot). NOT called at combat conclusion: the roster is still the return trip''s routing '
  'data (0199) and the XP fold''s attribution data (0177) — see the 0308 header.';

-- ── 3. THE WEAPON AUTHORITY ──────────────────────────────────────────────────────────────────────
-- IMMUTABLE and pure over a catalog row already in hand (the 0306 fleet_docked_location pattern).
create or replace function public.module_is_firing_weapon(t public.module_types)
returns boolean
language sql
immutable
as $fn$
  select t.slot_type = 'weapon'
     and t.range is not null
     and coalesce(t.power, 0) > 0;
$fn$;

comment on function public.module_is_firing_weapon(public.module_types) is
  'THE one answer to "is this fitted module a weapon that can fire?" (0308): weapon archetype '
  '(slot_type — the discriminator 0229:62-65 names), a real spatial reach, and real damage. '
  'range alone is NOT weapon-ness: the mining rig carries range 120 / power 8 and must never '
  'fire or suppress the 0262 fallback. Deliberately NOT composed by ship_weapon_modules, which '
  'answers a different question ("what carries a spatial range?" — weapon OR mining) for the '
  'client map-radius layer.';

-- ACLs: internal leaves — every composer is a security-definer engine function. Explicitly revoked
-- rather than merely un-granted (the 0254 prod grant-drift lesson).
revoke execute on function public.group_sortie_live_members(uuid) from public, anon, authenticated;
revoke execute on function public.group_sortie_release(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.module_is_firing_weapon(public.module_types) from public, anon, authenticated;

-- ── 4. CAPTURE METADATA BEFORE THE REWRITE (for parity check k) ──────────────────────────────────
create temp table _0308_before (
  fname text primary key, body_md5 text, owner text, secdef boolean, volatility "char",
  parallel "char", proconfig text, args text, result text, acl text
) on commit drop;

insert into _0308_before
select p.proname, md5(p.prosrc), pg_get_userbyid(p.proowner), p.prosecdef, p.provolatile,
       p.proparallel, coalesce(array_to_string(p.proconfig, ','), ''),
       pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid),
       coalesce(p.proacl::text, '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('combat_create_group_encounter', 'pirate_intercept_resolve_due_for_movement',
                     'combat_flee_pending', 'command_ship_group_stop');

-- ── 5. REWRITE THE SIX HUNKS (located by exact deployed text, never retyped) ─────────────────────
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
    (1, 'combat_create_group_encounter',
     $h1o$  for m in
    select gsm.main_ship_id, gsm.player_id, msi.hp, msi.shield, msi.max_shield, msi.is_command_ship
      from group_sortie_members gsm
      join main_ship_instances msi on msi.main_ship_id = gsm.main_ship_id
     where gsm.fleet_id = pr.fleet_id
     order by gsm.main_ship_id$h1o$,
     $h1n$  for m in
    -- 0308: THE ROSTER IS LIVE MEMBERSHIP, THROUGH THE ONE AUTHORITY. The raw join read EVERY
    -- group_sortie_members row for the fleet — no msi.group_id filter, no liveness of any kind —
    -- so rows left over from a CONCLUDED sortie (the freeze is idempotent and nothing released
    -- them on a persistent group fleet) dragged ships that had since LEFT the group into the next
    -- fight, dealt them tick damage while they sat berthed at another port, and destroyed them on
    -- defeat. group_sortie_live_members honours a row only while its ship is still a member of
    -- the fleet's group NOW. During a LIVE sortie the filter is an identity: assign/unassign are
    -- refused while group_sortie_is_open (0305), so the frozen manifest still wins mid-sortie —
    -- the filter can only bite BETWEEN sorties, which is exactly when it must.
    select gsm.main_ship_id, gsm.player_id, msi.hp, msi.shield, msi.max_shield, msi.is_command_ship
      from public.group_sortie_live_members(pr.fleet_id) gsm
      join main_ship_instances msi on msi.main_ship_id = gsm.main_ship_id
     order by gsm.main_ship_id$h1n$),
    (2, 'combat_create_group_encounter',
     $h2o$            from ship_module_fittings f
            join module_instances i on i.id = f.module_instance_id
            join module_types t     on t.id = i.module_type_id
           where f.main_ship_id = m.main_ship_id and t.range is not null;$h2o$,
     $h2n$            from ship_module_fittings f
            join module_instances i on i.id = f.module_instance_id
            join module_types t     on t.id = i.module_type_id
            -- 0308: A WEAPON IS A WEAPON, NOT "ANYTHING WITH A RANGE". The old test was
            -- t.range IS NOT NULL — but range means spatial reach, and the catalog seeds
            -- mining_rig_extension with range 120 / power 8 (0229:126-129). A fitted mining rig
            -- therefore counted as a gun: it fired power 8, and its presence made this array
            -- non-empty, permanently suppressing the 0262 fallback below — a ship whose card
            -- reports attack 60 fired 8 in the fight (the same class as the defect that destroyed
            -- Fleet 1). module_is_firing_weapon is the ONE authority: the weapon archetype
            -- (slot_type — the discriminator 0229:62-65 itself names), a real reach, real damage.
           where f.main_ship_id = m.main_ship_id and public.module_is_firing_weapon(t);$h2n$),
    (3, 'pirate_intercept_resolve_due_for_movement',
     $h3o$  insert into public.group_sortie_members (fleet_id, main_ship_id, player_id)
  select v_fleet.id, msi.main_ship_id, v_fleet.player_id
    from public.main_ship_instances msi
   where msi.group_id = v_group and msi.player_id = v_fleet.player_id
  on conflict (fleet_id, main_ship_id) do nothing;$h3o$,
     $h3n$  -- 0308: THE FREEZE IS A SNAPSHOT, NOT AN ACCRETION. 0168 calls this table "the membership
  -- SNAPSHOT frozen at send" — but the freeze was insert-only (ON CONFLICT DO NOTHING) and nothing
  -- released a concluded sortie's rows on a fleet that lives on (the persistent group fleet), so
  -- every re-ambush UNIONED today's members with every roster the fleet ever flew — which is the
  -- accumulation that fed defect rows into the count and the builder. Release the old snapshot
  -- first, composing THE one release idiom (0305's brake release, now public.group_sortie_release),
  -- so what follows freezes exactly the fleet's live membership. Safe here by construction:
  -- liveness gate (b) above already refused any fleet with an open fight, so no live encounter can
  -- be reading these rows; a ship still on the roster is re-inserted in this same transaction.
  perform public.group_sortie_release(v_fleet.player_id, v_fleet.id);
  insert into public.group_sortie_members (fleet_id, main_ship_id, player_id)
  select v_fleet.id, msi.main_ship_id, v_fleet.player_id
    from public.main_ship_instances msi
   where msi.group_id = v_group and msi.player_id = v_fleet.player_id
  on conflict (fleet_id, main_ship_id) do nothing;$h3n$),
    (4, 'pirate_intercept_resolve_due_for_movement',
     $h4o$  select count(*) into v_manifest
    from public.group_sortie_members gsm
   where gsm.fleet_id = v_fleet.id;$h4o$,
     $h4n$  -- 0308: measure what the builder will actually seed — the LIVE roster, through the same one
  -- authority the builder composes. After the snapshot replacement above the two are equal by
  -- construction; the shared leaf keeps them equal if any freeze-less path ever reaches a build.
  select count(*) into v_manifest
    from public.group_sortie_live_members(v_fleet.id) gsm;$h4n$),
    (5, 'combat_flee_pending',
     $h5o$  for m in select gsm.main_ship_id from group_sortie_members gsm where gsm.fleet_id = v_pr.fleet_id loop$h5o$,
     $h5n$  -- 0308: only ships still in the fleet's group ride home — a stale roster row must not mark a
  -- ship that long since left the group (and may be berthed at another port) as 'returning'.
  for m in select gsm.main_ship_id from public.group_sortie_live_members(v_pr.fleet_id) gsm loop$h5n$),
    (6, 'command_ship_group_stop',
     $h6o$  delete from public.group_sortie_members
   where fleet_id = v_fleet and player_id = v_player;$h6o$,
     $h6n$  -- 0308: the release is now THE one idiom, public.group_sortie_release — same delete, same
  -- fleet+caller scope, one definition (the ambush freeze composes the very same one).
  perform public.group_sortie_release(v_player, v_fleet);$h6n$)
    ) as t(idx, fname, old_t, new_t)
    order by idx
  loop
    select p.oid into v_oid
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = r.fname;
    if v_oid is null then
      raise exception '0308 REWRITE FAIL [%]: function public.% not found', r.idx, r.fname;
    end if;
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = r.fname) <> 1 then
      raise exception '0308 REWRITE FAIL [%]: public.% is overloaded — refusing to guess', r.idx, r.fname;
    end if;

    v_src := pg_get_functiondef(v_oid);
    v_n := (length(v_src) - length(replace(v_src, r.old_t, ''))) / length(r.old_t);
    if v_n <> 1 then
      raise exception '0308 REWRITE FAIL [%]: hunk text occurs % time(s) in public.%, expected exactly 1 — the deployed body is not what this migration was generated against',
        r.idx, v_n, r.fname;
    end if;

    v_new := replace(v_src, r.old_t, r.new_t);
    if length(v_new) <> length(v_src) - length(r.old_t) + length(r.new_t) then
      raise exception '0308 REWRITE FAIL [%]: unexpected length delta rewriting public.%', r.idx, r.fname;
    end if;
    execute v_new;
    v_done := v_done + 1;
  end loop;

  if v_done <> 6 then
    raise exception '0308 REWRITE FAIL: rewrote % site(s), expected 6', v_done;
  end if;
  raise notice '0308: rewrote 6 hunks across 4 functions onto the three authorities';
end $rewrite$;

-- ── 6. SELF-ASSERTS — one DO block per check; every probe strips comments first ─────────────────

-- (a) the three authorities exist with the right shape
do $a$
begin
  if to_regprocedure('public.group_sortie_live_members(uuid)') is null
     or to_regprocedure('public.group_sortie_release(uuid,uuid)') is null
     or to_regprocedure('public.module_is_firing_weapon(public.module_types)') is null then
    raise exception '0308 ASSERT (a) FAIL: an authority is missing';
  end if;
  if (select provolatile from pg_proc where oid = 'public.group_sortie_live_members(uuid)'::regprocedure) <> 's'
     or (select prosecdef from pg_proc where oid = 'public.group_sortie_live_members(uuid)'::regprocedure) is not true then
    raise exception '0308 ASSERT (a) FAIL: group_sortie_live_members must be STABLE SECURITY DEFINER';
  end if;
  if (select provolatile from pg_proc where oid = 'public.module_is_firing_weapon(public.module_types)'::regprocedure) <> 'i' then
    raise exception '0308 ASSERT (a) FAIL: module_is_firing_weapon must be IMMUTABLE (pure over a row in hand)';
  end if;
end $a$;

-- (b) builder: raw roster read gone, liveness authority composed
do $b$
declare v_code text;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  if position('from group_sortie_members' in v_code) > 0
     or position('from public.group_sortie_members' in v_code) > 0
     or position('join group_sortie_members' in v_code) > 0
     or position('join public.group_sortie_members' in v_code) > 0 then
    raise exception '0308 ASSERT (b) FAIL: the builder still reads the raw roster';
  end if;
  if position('group_sortie_live_members(pr.fleet_id)' in v_code) = 0 then
    raise exception '0308 ASSERT (b) FAIL: the builder does not compose the liveness authority';
  end if;
end $b$;

-- (c) builder: range-test gone, weapon authority composed, the 0262 fallback guard intact
do $c$
declare v_code text;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  if position('t.range is not null' in v_code) > 0 then
    raise exception '0308 ASSERT (c) FAIL: the builder still treats "has a range" as "is a weapon"';
  end if;
  if position('module_is_firing_weapon(t)' in v_code) = 0 then
    raise exception '0308 ASSERT (c) FAIL: the builder does not compose the weapon authority';
  end if;
  if position('jsonb_array_length(v_weapons_json) = 0' in v_code) = 0
     or position('basic_player_weapon' in v_code) = 0
     or position('combat_player_fallback_weapon_power_from_attack' in v_code) = 0 then
    raise exception '0308 ASSERT (c) FAIL: the 0262 fallback guard lost a piece';
  end if;
end $c$;

-- (d) resolver: release composed BEFORE the freeze, count composed, guard order + freeze intact
do $d$
declare v_code text;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'pirate_intercept_resolve_due_for_movement';
  if position('group_sortie_release(v_fleet.player_id, v_fleet.id)' in v_code) = 0 then
    raise exception '0308 ASSERT (d) FAIL: the resolver does not release the previous snapshot';
  end if;
  if position('group_sortie_release' in v_code) > position('insert into public.group_sortie_members' in v_code) then
    raise exception '0308 ASSERT (d) FAIL: the release runs AFTER the freeze — it would delete the fresh snapshot';
  end if;
  if position('on conflict (fleet_id, main_ship_id) do nothing' in v_code) = 0 then
    raise exception '0308 ASSERT (d) FAIL: the freeze lost its idempotent ON CONFLICT clause';
  end if;
  if position('group_sortie_live_members(v_fleet.id)' in v_code) = 0 then
    raise exception '0308 ASSERT (d) FAIL: the count does not compose the liveness authority';
  end if;
  if position('from public.group_sortie_members gsm' in v_code) > 0 then
    raise exception '0308 ASSERT (d) FAIL: the raw unfiltered count read survives';
  end if;
  if position('select count(*) into v_manifest' in v_code) = 0
     or position('select count(*) into v_manifest' in v_code) > position('if v_manifest = 0' in v_code) then
    raise exception '0308 ASSERT (d) FAIL: the count no longer feeds the empty_manifest guard (0303 order)';
  end if;
  if position('empty_manifest' in v_code) = 0 or position('presence_create' in v_code) = 0 then
    raise exception '0308 ASSERT (d) FAIL: the 0290 guard or the composed chain was lost';
  end if;
  if position('combat_create_group_encounter' in v_code) > 0 then
    raise exception '0308 ASSERT (d) FAIL: the resolver creates an encounter directly — a second path';
  end if;
end $d$;

-- (e) flee: raw roster read gone, liveness authority composed
do $e$
declare v_code text;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_flee_pending';
  if position('from group_sortie_members' in v_code) > 0
     or position('from public.group_sortie_members' in v_code) > 0 then
    raise exception '0308 ASSERT (e) FAIL: the flee verb still reads the raw roster';
  end if;
  if position('group_sortie_live_members(v_pr.fleet_id)' in v_code) = 0 then
    raise exception '0308 ASSERT (e) FAIL: the flee verb does not compose the liveness authority';
  end if;
end $e$;

-- (f) brake: inline delete gone, release composed, the 0305 retreat-compose intact
do $f$
declare v_code text;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'command_ship_group_stop';
  if position('delete from public.group_sortie_members' in v_code) > 0 then
    raise exception '0308 ASSERT (f) FAIL: the brake still carries its own inline delete';
  end if;
  if position('group_sortie_release(v_player, v_fleet)' in v_code) = 0 then
    raise exception '0308 ASSERT (f) FAIL: the brake does not compose the release idiom';
  end if;
  if position('presence_request_leave' in v_code) = 0
     or position('retreat_started' in v_code) = 0
     or position('retreat_already_underway' in v_code) = 0 then
    raise exception '0308 ASSERT (f) FAIL: the 0305 retreat compose was damaged';
  end if;
  if position('retreat_requested_at' in v_code) > 0 or position('presence_complete' in v_code) > 0 then
    raise exception '0308 ASSERT (f) FAIL: the brake writes retreat state directly (0305 invariant)';
  end if;
end $f$;

-- (g) ONE release idiom: no function but group_sortie_release deletes from the roster
do $g$
declare v_bad text;
begin
  select string_agg(p.proname, ', ') into v_bad
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    join pg_language l on l.oid = p.prolang
   where n.nspname = 'public'
     and l.lanname in ('sql', 'plpgsql')
     and p.proname <> 'group_sortie_release'
     and (position('delete from public.group_sortie_members' in regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')) > 0
          or position('delete from group_sortie_members' in regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')) > 0);
  if v_bad is not null then
    raise exception '0308 ASSERT (g) FAIL: a second roster-delete idiom survives in: %', v_bad;
  end if;
end $g$;

-- (h) weapon truth on the deployed catalog: rig refused, every seeded weapon kept
do $h$
declare v_n integer; v_rig boolean;
begin
  select public.module_is_firing_weapon(t) into v_rig
    from public.module_types t where t.id = 'mining_rig_extension';
  if v_rig is distinct from false then
    raise exception '0308 ASSERT (h) FAIL: mining_rig_extension answers % (want false — it is the defect)', v_rig;
  end if;
  select count(*) into v_n from public.module_types t
   where t.slot_type = 'weapon' and not public.module_is_firing_weapon(t);
  if v_n <> 0 then
    raise exception '0308 ASSERT (h) FAIL: % seeded weapon(s) would be DROPPED by the authority — too aggressive', v_n;
  end if;
  select count(*) into v_n from public.module_types t
   where t.id in ('autocannon_battery', 'autocannon_battery_mk2') and public.module_is_firing_weapon(t);
  if v_n <> 2 then
    raise exception '0308 ASSERT (h) FAIL: only % of the 2 seeded autocannons pass the authority', v_n;
  end if;
end $h$;

-- (i) liveness authority smoke: unknown fleet -> zero rows (callable, empty-safe)
do $i$
declare v_n integer;
begin
  select count(*) into v_n
    from public.group_sortie_live_members('00000000-0000-4308-8308-000000000308'::uuid);
  if v_n <> 0 then
    raise exception '0308 ASSERT (i) FAIL: the authority answered % row(s) for a fleet that does not exist', v_n;
  end if;
end $i$;

-- (j) ACLs: no new authority is client-callable
do $j$
declare v_n integer;
begin
  select count(*) into v_n
    from (values ('public.group_sortie_live_members(uuid)'),
                 ('public.group_sortie_release(uuid,uuid)'),
                 ('public.module_is_firing_weapon(public.module_types)')) as t(sig)
   where has_function_privilege('authenticated', t.sig, 'execute')
      or has_function_privilege('anon', t.sig, 'execute');
  if v_n > 0 then
    raise exception '0308 ASSERT (j) FAIL: % new authority function(s) are client-callable', v_n;
  end if;
end $j$;

-- (k) metadata parity: all four rewritten functions changed body and NOTHING else
do $k$
declare b record; a record; v_n integer := 0;
begin
  for b in select * from _0308_before loop
    select md5(p.prosrc) as body_md5, pg_get_userbyid(p.proowner) as owner, p.prosecdef as secdef,
           p.provolatile as volatility, p.proparallel as parallel,
           coalesce(array_to_string(p.proconfig, ','), '') as proconfig,
           pg_get_function_identity_arguments(p.oid) as args, pg_get_function_result(p.oid) as result,
           coalesce(p.proacl::text, '') as acl
      into a
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = b.fname;
    if a.owner is distinct from b.owner or a.secdef is distinct from b.secdef
       or a.volatility is distinct from b.volatility or a.parallel is distinct from b.parallel
       or a.proconfig is distinct from b.proconfig or a.args is distinct from b.args
       or a.result is distinct from b.result or a.acl is distinct from b.acl then
      raise exception '0308 ASSERT (k) FAIL: public.% changed metadata across the rewrite', b.fname;
    end if;
    if a.body_md5 = b.body_md5 then
      raise exception '0308 ASSERT (k) FAIL: public.% body is byte-identical — a hunk did not land', b.fname;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n <> 4 then
    raise exception '0308 ASSERT (k) FAIL: parity-checked % function(s), expected 4', v_n;
  end if;
  raise notice '0308 SELF-ASSERT PASS: live-membership roster, one release idiom, weapons are weapons';
end $k$;

commit;
