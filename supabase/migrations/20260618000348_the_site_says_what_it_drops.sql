-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0348 — THE SITE SAYS WHAT IT DROPS
--        (one narrow read so a player can see a hunting ground's loot table before dying for it)
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- ── THE OWNER ───────────────────────────────────────────────────────────────────────────────────
--     "on the wave tab, it should have loot info as well, with total cargo space"
--
-- and the standing combat law this serves:
--
--     "the whole point of this game is never to win, but exit appropriately"
--
-- A fight in this game is endless by design (0347's ceiling is unbounded and that is deliberate),
-- and a DEFEAT zeroes combat_encounters.total_rewards_json — measured on production, that destroyed
-- 10 of the 11 engine_parts and all 1,115 metal one account had ever earned at Reaver. So the only
-- decision the fight actually asks is "stay for one more kill, or leave and bank what I have", and
-- the player cannot weigh it without knowing what a kill is worth HERE.
--
-- Everything else that readout needs is already client-readable and this file does not touch it:
--   · what has been earned so far  -> combat_encounters.total_rewards_json (RLS: own rows, 0014)
--   · how full the hold is         -> public.get_my_hold (0333), granted to authenticated
--   · an item's volume             -> public.item_types (public read, 0039/0333)
-- What was NOT reachable is the site's own loot table. 0344 created public.location_loot with RLS
-- ENABLED and NO POLICY AT ALL, which is deny-all whatever the grants say, and its only reader is
-- the engine-internal public.site_loot_for_kill (revoked from every client role). So this file adds
-- ONE narrow read and nothing else.
--
-- ── WHAT PRIVILEGE THIS OPENS, STATED EXACTLY ───────────────────────────────────────────────────
-- AFTER this migration an `authenticated` role may call public.get_site_loot(uuid) and learn, for
-- ONE location id at a time, which item_ids that site drops per enemy destroyed, in what quantity,
-- and at what chance. That is CONTENT — the same class of fact as public.item_types (already public
-- read) and public.locations. It exposes no player, no fleet, no encounter and no ownership.
--
-- What is deliberately NOT opened, and each is asserted below:
--   · NO policy is added to public.location_loot. The table stays deny-all; this function is its
--     ONE client-facing reader, exactly as 0344 intended ("this table is read by a SECURITY DEFINER
--     leaf"). A `grant select` on the table would have been the lazier fix and it would have made
--     the row shape a public contract forever.
--   · The table's client SELECT is REVOKED, which is a TIGHTENING this file performs rather than a
--     state it inherits. 0344 revoked only insert/update/delete, leaving whatever SELECT the
--     project's default privileges had granted -- harmless while RLS carries no policy (deny-all
--     wins over any grant), but it meant the sentence above was true by accident. Revoking makes it
--     true by construction, and it costs nothing: nothing client-side has ever named this table
--     (grepped over src/), and the engine reads it through SECURITY DEFINER functions that run as
--     the owner. Asserted below, so a later `grant select` "so the client can just read it" stops
--     the deploy.
--   · NO write of any kind. The 0344 revoke of insert/update/delete from anon and authenticated is
--     restated here so this file cannot be read as loosening it.
--   · NOTHING is granted to `anon`. A logged-out visitor learns nothing.
--   · public.site_loot_for_kill is NOT granted. It is VOLATILE and it ROLLS — handing it to a client
--     would let a player mint their own loot bundle. This function reads the TABLE and rolls nothing.
--
-- ── WHY drop_chance = 0 ROWS ARE NOT RETURNED ───────────────────────────────────────────────────
-- 0344 migrated two config-gated drops (captain_memory_shard, blueprint_fragment) into
-- location_loot.drop_chance, carrying whatever the knobs held. Where a knob was 0 the row exists and
-- can never drop. Advertising it would put a number on screen that the engine can never honour —
-- what is DRAWN must BE the rule — so the filter is `drop_chance > 0 and quantity > 0`, the same two
-- conditions site_loot_for_kill itself applies before it rolls (0344:817-818 filters quantity > 0
-- and rolls against drop_chance). Raise the knob-derived row above 0 and the item appears here.
--
-- ── PER KILL, AND SAID SO ───────────────────────────────────────────────────────────────────────
-- The quantities are PER ENEMY DESTROYED — that is the unit site_loot_for_kill pays in, one roll per
-- (item, kill). The client label must say "per kill"; nothing here multiplies by anything, because
-- how many kills a fight will produce is not a fact anyone has.
--
-- ── ROLLBACK BOUNDARY ───────────────────────────────────────────────────────────────────────────
-- This migration creates exactly ONE object and alters no table, no data and no existing function.
-- The complete rollback is:
--
--     drop function public.get_site_loot(uuid);
--
-- After that statement the database is byte-identical to head 0347 in every respect this file can
-- observe: location_loot keeps the same rows, the same zero policies and the same revokes; the
-- engine's own reader is untouched; no game_config key is added or changed. There is no data
-- migration to undo and no writer to quiesce first, so the rollback is safe at any moment,
-- including mid-fight.
--
-- ── PARITY ──────────────────────────────────────────────────────────────────────────────────────
-- public.process_combat_ticks is NOT re-created, NOT surgically patched and NOT read here. Assert
-- (f) captures md5(prosrc) of it before the first DDL statement and requires it unchanged
-- afterwards, which is the same guard 0347 used and is stronger than "no create appears in this
-- file" because it also catches one arriving by any other route.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── PRECONDITIONS ───────────────────────────────────────────────────────────────────────────────
-- Fail LOUD and fail EARLY if the world this file is handed is not the world it was written for.
do $$
begin
  if to_regclass('public.location_loot') is null then
    raise exception '0348 PRECONDITION FAIL: public.location_loot does not exist. This slice exposes 0344''s loot table; without it there is nothing to read and a silently-created empty reader would be worse than no reader';
  end if;
  if to_regproc('public.get_site_loot') is not null then
    raise exception '0348 PRECONDITION FAIL: public.get_site_loot already exists. This slice MINTS it; two files creating one reader is the duplication this repo keeps paying for — reconcile by hand';
  end if;
  -- The table must still be deny-all going IN, or the claim this file makes about what it opens is
  -- already false before it opens anything.
  if exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'location_loot') then
    raise exception '0348 PRECONDITION FAIL: public.location_loot already carries a row-security policy. 0344 left it with none on purpose; something else has opened this table and this file''s privilege statement would be a lie';
  end if;
end $$;

-- Capture the combat tick's fingerprint BEFORE any DDL, for assert (f). Byte-for-byte the idiom
-- 0347 uses for the same guard, deliberately -- a capture mechanism that has already survived the
-- disposable-Postgres apply is worth more than a cleverer one that has not.
create temp table _0348_tick_before (fname text primary key, body_md5 text, body_len integer)
  on commit drop;
insert into _0348_tick_before
select p.proname, md5(p.prosrc), length(p.prosrc)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'process_combat_ticks';


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE READ
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- STABLE and read-only: it selects, it aggregates, it rolls nothing and it writes nothing. That is
-- the whole difference from site_loot_for_kill, which is VOLATILE because it calls random(), and it
-- is why this one can be handed to a client and that one never can.
--
-- SECURITY DEFINER because public.location_loot carries RLS with no policy — the table is
-- unreadable to every client role by construction and stays that way. `set search_path to ''` and
-- fully-qualified names throughout: a definer function that resolves an unqualified name through a
-- caller-controlled path is the classic escalation, and every definer leaf in this chain is written
-- this way.
--
-- The envelope is the house shape (`ok` + payload), so a caller that gets `ok:false` renders NOTHING
-- rather than concluding "this site drops nothing" from a failed read. The two are different facts
-- and a client that cannot tell them apart will eventually tell the player the wrong one.
create or replace function public.get_site_loot(p_location uuid)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $gsl$
  select case
    when p_location is null then jsonb_build_object('ok', false, 'code', 'no_location')
    else jsonb_build_object(
      'ok', true,
      'location_id', p_location,
      -- PER ENEMY DESTROYED. id-sorted, so the list is stable across polls and never reorders under
      -- the player's finger — the same ordering site_loot_for_kill's own aggregate produces.
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'item_id',     ll.item_id,
                 'quantity',    ll.quantity,
                 'drop_chance', ll.drop_chance)
               order by ll.item_id)
          from public.location_loot ll
         where ll.location_id = p_location
           and ll.quantity > 0
           and ll.drop_chance > 0), '[]'::jsonb))
  end;
$gsl$;

comment on function public.get_site_loot(uuid) is
  'THE ONE client-facing read of public.location_loot (0348). Returns {ok, location_id, items:[{item_id, '
  'quantity, drop_chance}]} for ONE site, id-sorted, PER ENEMY DESTROYED — the unit '
  'public.site_loot_for_kill pays in. Rows with quantity <= 0 or drop_chance <= 0 are omitted: a drop the '
  'engine can never honour must not appear on a screen. Read-only and STABLE — it rolls nothing, which is '
  'why it can be granted to a client while site_loot_for_kill (VOLATILE, calls random()) never can. '
  'location_loot itself keeps RLS with zero policies and no client SELECT grant; this function is its only '
  'client reader.';

-- GRANTS. Revoked from PUBLIC BY NAME first — the 0309 lesson: a revoke naming only anon and
-- authenticated leaves PUBLIC's default EXECUTE standing, and a definer function reachable by PUBLIC
-- is reachable by anon.
revoke all on function public.get_site_loot(uuid) from public;
revoke all on function public.get_site_loot(uuid) from anon, authenticated;
grant execute on function public.get_site_loot(uuid) to authenticated, service_role;

-- The table's write posture, RESTATED so this file cannot be read as having loosened it -- and its
-- READ posture TIGHTENED, so "the function is the only client reader" is enforced rather than merely
-- implied by an RLS policy list that happens to be empty. See the header for why this costs nothing.
revoke insert, update, delete on table public.location_loot from anon, authenticated;
revoke select on table public.location_loot from anon, authenticated;


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SELF-ASSERTS — in transaction. Any failure aborts the apply and the migration lands nowhere.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
do $$
declare
  v_oid       oid;
  v_n         integer;
  v_before    text;
  v_len       integer;
  v_after     text;
  v_loc       uuid;
  v_expect    integer;
  v_got       integer;
  v_payload   jsonb;
begin
  -- (a) THE READER EXISTS, ONCE. An overload would mean two answers to one question.
  select p.oid into v_oid
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_site_loot';
  if v_oid is null then
    raise exception '0348 ASSERT (a) FAIL: public.get_site_loot was not created';
  end if;
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_site_loot';
  if v_n <> 1 then
    raise exception '0348 ASSERT (a) FAIL: public.get_site_loot is overloaded (% signatures) — "what does this site drop" must have exactly one answer', v_n;
  end if;

  -- (b) THE GRANT IS EXACTLY WHAT THE HEADER CLAIMS: authenticated may execute; anon and PUBLIC may
  -- not. proacl NULL means the PostgreSQL default (EXECUTE to PUBLIC) is still standing, which is
  -- the failure 0309 was written about, so it is checked explicitly rather than inferred.
  if (select proacl from pg_proc where oid = v_oid) is null then
    raise exception '0348 ASSERT (b) FAIL: public.get_site_loot carries no ACL, so PUBLIC still holds the default EXECUTE — anon can read every site''s loot table';
  end if;
  if not has_function_privilege('authenticated', v_oid, 'EXECUTE') then
    raise exception '0348 ASSERT (b) FAIL: authenticated cannot EXECUTE public.get_site_loot — the read this slice exists to open is closed';
  end if;
  if has_function_privilege('anon', v_oid, 'EXECUTE') then
    raise exception '0348 ASSERT (b) FAIL: anon can EXECUTE public.get_site_loot — this slice opens a read to LOGGED-IN players only';
  end if;

  -- (c) ██ THE TABLE IS STILL DENY-ALL ██ — the privilege statement in the header, enforced.
  -- location_loot must still carry RLS, must still carry ZERO policies, and must still grant no
  -- SELECT to a client role. If a later hand adds `grant select` "so the client can just read it",
  -- this is where the deploy stops.
  if not (select c.relrowsecurity from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relname = 'location_loot') then
    raise exception '0348 ASSERT (c) FAIL: row security is no longer enabled on public.location_loot';
  end if;
  select count(*) into v_n from pg_policies where schemaname = 'public' and tablename = 'location_loot';
  if v_n <> 0 then
    raise exception '0348 ASSERT (c) FAIL: public.location_loot carries % policy/policies — this slice deliberately did NOT open the table; its reader is public.get_site_loot', v_n;
  end if;
  -- The revoke above is what makes this true; before this file it may have been granted and merely
  -- inert behind RLS. Either way, from here on the function is the contract, not the row shape.
  if has_table_privilege('authenticated', 'public.location_loot', 'SELECT')
     or has_table_privilege('anon', 'public.location_loot', 'SELECT') then
    raise exception '0348 ASSERT (c) FAIL: a client role holds SELECT on public.location_loot — the row shape must not become a public contract; the function is the contract';
  end if;
  -- …and no client may write it, in any of the three ways.
  if has_table_privilege('authenticated', 'public.location_loot', 'INSERT')
     or has_table_privilege('authenticated', 'public.location_loot', 'UPDATE')
     or has_table_privilege('authenticated', 'public.location_loot', 'DELETE')
     or has_table_privilege('anon', 'public.location_loot', 'INSERT')
     or has_table_privilege('anon', 'public.location_loot', 'UPDATE')
     or has_table_privilege('anon', 'public.location_loot', 'DELETE') then
    raise exception '0348 ASSERT (c) FAIL: a client role can WRITE public.location_loot — a player could author their own loot table';
  end if;

  -- (d) THE ROLL IS STILL ENGINE-ONLY. This slice must not have made site_loot_for_kill reachable
  -- as a side effect of anything, because it is VOLATILE and it MINTS a bundle.
  select p.oid into v_oid
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'site_loot_for_kill';
  if v_oid is not null and (has_function_privilege('authenticated', v_oid, 'EXECUTE')
                            or has_function_privilege('anon', v_oid, 'EXECUTE')) then
    raise exception '0348 ASSERT (d) FAIL: a client role can EXECUTE public.site_loot_for_kill — it rolls random() and returns a loot bundle, so a player could mint their own';
  end if;

  -- (e) THE READER ANSWERS THE TABLE — a PROPERTY, never a seeded count. For EVERY site that has any
  -- payable loot row, the function must return exactly the rows the filter admits, and it must
  -- return them for every such site rather than for one the assert happened to name. A site with no
  -- rows must come back as an EMPTY LIST with ok:true — "nothing drops here" and "the read failed"
  -- are different facts and the envelope has to keep them apart.
  for v_loc, v_expect in
    select ll.location_id, count(*)::integer
      from public.location_loot ll
     where ll.quantity > 0 and ll.drop_chance > 0
     group by ll.location_id
  loop
    v_payload := public.get_site_loot(v_loc);
    if coalesce((v_payload->>'ok')::boolean, false) is not true then
      raise exception '0348 ASSERT (e) FAIL: get_site_loot(%) did not answer ok', v_loc;
    end if;
    v_got := jsonb_array_length(v_payload->'items');
    if v_got <> v_expect then
      raise exception '0348 ASSERT (e) FAIL: get_site_loot(%) returned % item(s) but the table admits % — the reader and the table disagree', v_loc, v_got, v_expect;
    end if;
  end loop;

  -- …and the inert rows really are withheld. Only meaningful when such a row exists; when none does
  -- the check is skipped rather than pretended, and it starts biting the day a knob is set to 0.
  select count(*)::integer into v_n
    from public.location_loot ll
   where ll.drop_chance <= 0 or ll.quantity <= 0;
  if v_n > 0 then
    for v_loc in
      select distinct ll.location_id from public.location_loot ll
       where ll.drop_chance <= 0 or ll.quantity <= 0
    loop
      v_payload := public.get_site_loot(v_loc);
      if exists (
        select 1
          from jsonb_array_elements(v_payload->'items') as e(val)
          join public.location_loot ll
            on ll.location_id = v_loc and ll.item_id = e.val->>'item_id'
         where ll.drop_chance <= 0 or ll.quantity <= 0) then
        raise exception '0348 ASSERT (e) FAIL: get_site_loot(%) advertises a drop the engine can never pay — a chance of 0 must not reach a screen', v_loc;
      end if;
    end loop;
  end if;

  -- A NULL location is a caller bug, not a site with no loot. It must be distinguishable.
  if coalesce((public.get_site_loot(null)->>'ok')::boolean, true) is not false then
    raise exception '0348 ASSERT (e) FAIL: get_site_loot(null) answered ok — "no site" and "a site that drops nothing" must not read the same';
  end if;

  -- (f) PARITY: the combat tick is not touched by this file, by any route.
  -- A guard that cannot RUN must not pass silently, so the pre-image is checked for usability first
  -- (0347's own rule, and its 40,000-char floor: the deployed body is ~87k, so anything smaller is a
  -- capture that did not happen rather than a tick that shrank).
  select body_md5, body_len into v_before, v_len from _0348_tick_before where fname = 'process_combat_ticks';
  if v_before is null or v_len is null or v_len < 40000 then
    raise exception '0348 ASSERT (f) FAIL: no usable pre-image of the tick was captured (md5 %, length %) - the comparison below would be between two nothings', coalesce(v_before, '<null>'), coalesce(v_len, -1);
  end if;
  select md5(p.prosrc) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if v_after is distinct from v_before then
    raise exception '0348 ASSERT (f) FAIL: public.process_combat_ticks changed during this migration (% -> %) - this slice adds a READ and must not reshape the engine', v_before, v_after;
  end if;

  raise notice '0348 OK: public.get_site_loot granted to authenticated; public.location_loot still RLS-on with 0 policies and no client grant of any kind.';
end $$;
