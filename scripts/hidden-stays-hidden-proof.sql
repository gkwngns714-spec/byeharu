-- HIDDEN STAYS HIDDEN — disposable apply-proof (run against a THROWAWAY local Supabase ONLY).
--
-- Proves migration 0318 (20260618000318_hidden_stays_hidden.sql) after `supabase start` has applied
-- the FULL chain: an unreleased row of the static world is INVISIBLE TO AN ANONYMOUS CALLER, while
-- everything the game and the owner's tool actually need still works.
--
-- WHY A MIGRATION SELF-ASSERT WAS NOT ENOUGH. 0318's own asserts run as `postgres`, and postgres
-- carries BYPASSRLS — so no assertion it can make about itself ever exercises a policy. The security
-- property only exists from the outside, and the only way to stand outside is to BE the role: every
-- visibility check below runs under `set local role anon` / `set local role authenticated`, which is
-- exactly the seat a PostgREST request occupies.
--
-- THE PROOF IS RED BY CONSTRUCTION ON THE PRE-FIX CHAIN. Section A reads nothing that 0318 creates —
-- it inserts a hidden location and asks anon to look at the table. Against `locations_public_read
-- USING (true)` the hidden fixture comes back and the assertion fires. That is the leak, reproduced
-- in CI. (Reproduced against production too, with the public anon key alone:
--   GET /rest/v1/locations?select=name,status,x,y,territory_radius&status=eq.hidden -> HTTP 200
--   [{"name":"Ember Gate",...},{"name":"Cinder Maw",...},{"name":"The Furnace",...}])
--
-- WHAT SECTION H EXISTS FOR — an honest hole, named rather than papered over. The drifted
-- INSERT/UPDATE/DELETE grants on zones/sectors/bases come from the Supabase PROJECT-LEVEL default
-- privileges, which a disposable `supabase start` does not reproduce. So the committed end-state
-- check (section G) passes on this chain whether or not 0318 revoked anything — it is only
-- load-bearing on production, where it runs as 0318's own assert at deploy time. Section H closes
-- that by OWNING ITS PRECONDITION: it grants the drift itself, proves the privilege is really there,
-- runs 0318's exact revoke statement, and proves it is gone. Efficacy is then a property of this
-- chain rather than of production alone.
--
-- Self-rolling-back: everything runs inside one begin;…rollback; — ZERO persisted state, no flag
-- flipped, no world row kept, and the section-H grant is rolled back with it. NEVER point this at
-- production.

\set ON_ERROR_STOP on

begin;

-- ══ FIXTURES — this proof asserts NO ambient default; it seeds every row it later reads ══════════
-- Five locations spanning every reason a row can be unreleased, so a policy that is too loose OR too
-- tight is caught by the same block. Each carries an ACTIVE space_anchor: get_world_map (and the
-- owner catalog) INNER-JOIN the anchor since 0264, so an unanchored fixture would vanish for a
-- reason that has nothing to do with visibility and would make section E vacuous.
do $setup$
declare
  v_sec_active uuid;
  v_sec_hidden uuid;
  v_zone_active uuid;
  v_zone_hidden uuid;
  v_zone_under_hidden_sector uuid;
  v_loc uuid;
begin
  insert into public.sectors (name, sector_index, x, y, danger_tier, status)
    values ('HSH-Sector-Active', 9101, 9000, 9000, 1, 'active') returning id into v_sec_active;
  insert into public.sectors (name, sector_index, x, y, danger_tier, status)
    values ('HSH-Sector-Hidden', 9102, 9100, 9100, 1, 'hidden') returning id into v_sec_hidden;

  insert into public.zones (sector_id, name, x, y, radius, status)
    values (v_sec_active, 'HSH-Zone-Active', 9000, 9000, 10, 'active') returning id into v_zone_active;
  insert into public.zones (sector_id, name, x, y, radius, status)
    values (v_sec_active, 'HSH-Zone-Hidden', 9010, 9010, 10, 'hidden') returning id into v_zone_hidden;
  -- an ACTIVE zone whose SECTOR is hidden: get_world_map never reaches it (it descends from active
  -- sectors), so a flat status-only policy would be LOOSER than the read path. The composed
  -- predicate is what makes these two agree.
  insert into public.zones (sector_id, name, x, y, radius, status)
    values (v_sec_hidden, 'HSH-Zone-UnderHiddenSector', 9100, 9100, 10, 'active')
    returning id into v_zone_under_hidden_sector;

  -- (1) the released row — MUST stay visible to everyone. A policy that hides this breaks the game.
  insert into public.locations (zone_id, name, location_type, activity_type, x, y, is_public, status)
    values (v_zone_active, 'HSH-Loc-Active', 'pirate_hunt', 'hunt_pirates', 9000, 9000, true, 'active')
    returning id into v_loc;
  insert into public.space_anchors (kind, location_id, space_x, space_y, status)
    values ('location', v_loc, 9000, 9000, 'active');

  -- (2) THE LEAK ITSELF: unreleased content. is_public is deliberately TRUE — the three real hidden
  -- Ember rows carry is_public=true, so a policy keyed on is_public would leak exactly them.
  insert into public.locations (zone_id, name, location_type, activity_type, x, y, is_public, status)
    values (v_zone_active, 'HSH-Loc-Hidden', 'pirate_den', 'hunt_pirates', 9001, 9001, true, 'hidden')
    returning id into v_loc;
  insert into public.space_anchors (kind, location_id, space_x, space_y, status)
    values ('location', v_loc, 9001, 9001, 'active');

  -- (3) the other unreleased status in the 0002 enum.
  insert into public.locations (zone_id, name, location_type, activity_type, x, y, is_public, status)
    values (v_zone_active, 'HSH-Loc-Locked', 'trade_outpost', 'trade_visit', 9002, 9002, true, 'locked')
    returning id into v_loc;
  insert into public.space_anchors (kind, location_id, space_x, space_y, status)
    values ('location', v_loc, 9002, 9002, 'active');

  -- (4) active row, hidden ZONE — unreachable through the map, so it must be unreachable directly.
  insert into public.locations (zone_id, name, location_type, activity_type, x, y, is_public, status)
    values (v_zone_hidden, 'HSH-Loc-UnderHiddenZone', 'safe_zone', 'none', 9010, 9010, true, 'active')
    returning id into v_loc;
  insert into public.space_anchors (kind, location_id, space_x, space_y, status)
    values ('location', v_loc, 9010, 9010, 'active');

  -- (5) active row, active zone, hidden SECTOR — same, one level further up.
  insert into public.locations (zone_id, name, location_type, activity_type, x, y, is_public, status)
    values (v_zone_under_hidden_sector, 'HSH-Loc-UnderHiddenSector', 'safe_zone', 'none', 9100, 9100, true, 'active')
    returning id into v_loc;
  insert into public.space_anchors (kind, location_id, space_x, space_y, status)
    values ('location', v_loc, 9100, 9100, 'active');
end $setup$;

-- ══ A. THE SECURITY PROPERTY, FROM THE SEAT AN ANONYMOUS REQUEST OCCUPIES ════════════════════════
-- Everything in this block is a plain SELECT against the table, exactly what
-- `GET /rest/v1/locations` becomes. Nothing here references anything 0318 creates, so on the
-- pre-fix chain it runs and FAILS rather than erroring on a missing object.
set local role anon;

do $anon$
declare
  v_leaked text;
  v_n      integer;
begin
  select string_agg(name, ', ' order by name) into v_leaked
    from public.locations
   where name in ('HSH-Loc-Hidden', 'HSH-Loc-Locked',
                  'HSH-Loc-UnderHiddenZone', 'HSH-Loc-UnderHiddenSector');
  if v_leaked is not null then
    raise exception 'HIDDEN-STAYS-HIDDEN PROOF FAIL: an ANONYMOUS caller can read unreleased location(s): % — this is the live leak (names and exact coordinates of unreleased content)', v_leaked;
  end if;

  -- and the released row is STILL readable. Too tight is a bug too.
  select count(*) into v_n from public.locations where name = 'HSH-Loc-Active';
  if v_n <> 1 then
    raise exception 'HIDDEN-STAYS-HIDDEN PROOF FAIL: an anonymous caller can no longer read the RELEASED location (% row(s)) — the policy is too tight and the map would go blank', v_n;
  end if;

  -- the real production rows, on the chain rather than in the fixture: 0175 seeds Ember Gate /
  -- Cinder Maw / The Furnace hidden. They are the reason this migration exists.
  select string_agg(name, ', ' order by name) into v_leaked
    from public.locations where status <> 'active';
  if v_leaked is not null then
    raise exception 'HIDDEN-STAYS-HIDDEN PROOF FAIL: an ANONYMOUS caller can read non-active location(s) seeded by the chain: %', v_leaked;
  end if;

  -- zones and sectors carry the identical defect and the identical fix.
  select string_agg(name, ', ' order by name) into v_leaked
    from public.zones where name in ('HSH-Zone-Hidden', 'HSH-Zone-UnderHiddenSector');
  if v_leaked is not null then
    raise exception 'HIDDEN-STAYS-HIDDEN PROOF FAIL: an ANONYMOUS caller can read unreleased zone(s): %', v_leaked;
  end if;
  select count(*) into v_n from public.zones where name = 'HSH-Zone-Active';
  if v_n <> 1 then
    raise exception 'HIDDEN-STAYS-HIDDEN PROOF FAIL: an anonymous caller lost the RELEASED zone (% row(s))', v_n;
  end if;

  select string_agg(name, ', ' order by name) into v_leaked
    from public.sectors where name = 'HSH-Sector-Hidden';
  if v_leaked is not null then
    raise exception 'HIDDEN-STAYS-HIDDEN PROOF FAIL: an ANONYMOUS caller can read the unreleased sector: %', v_leaked;
  end if;
  select count(*) into v_n from public.sectors where name = 'HSH-Sector-Active';
  if v_n <> 1 then
    raise exception 'HIDDEN-STAYS-HIDDEN PROOF FAIL: an anonymous caller lost the RELEASED sector (% row(s))', v_n;
  end if;

  raise notice 'HSH_PASS_ANON_BLIND';
end $anon$;

reset role;

-- ══ B. A LOGGED-IN PLAYER IS NOT PRIVILEGED OVER THE STATIC WORLD ════════════════════════════════
-- `authenticated` is the role every real player's request runs as. It must see exactly what anon
-- sees here — the static world carries no per-player reveal.
set local role authenticated;

do $auth$
declare
  v_leaked text;
  v_n      integer;
begin
  select string_agg(name, ', ' order by name) into v_leaked
    from public.locations where status <> 'active';
  if v_leaked is not null then
    raise exception 'HIDDEN-STAYS-HIDDEN PROOF FAIL: an AUTHENTICATED player can read unreleased location(s): %', v_leaked;
  end if;
  select count(*) into v_n from public.locations where name = 'HSH-Loc-Active';
  if v_n <> 1 then
    raise exception 'HIDDEN-STAYS-HIDDEN PROOF FAIL: an authenticated player lost the RELEASED location (% row(s))', v_n;
  end if;

  -- the client's real read path is a SECURITY DEFINER RPC and must keep working from this seat.
  if jsonb_array_length(public.get_world_map()->'sectors') < 1 then
    raise exception 'HIDDEN-STAYS-HIDDEN PROOF FAIL: get_world_map returns no sectors for an authenticated caller — the player map is blank';
  end if;

  raise notice 'HSH_PASS_AUTH_BLIND';
end $auth$;

reset role;

-- ══ C. anon can still call the map RPC, and it serves exactly the released set ════════════════════
set local role anon;

do $anonmap$
declare
  v_names text;
begin
  select string_agg(l->>'name', ', ' order by l->>'name') into v_names
    from jsonb_array_elements(public.get_world_map()->'sectors') se,
         jsonb_array_elements(se->'zones') z,
         jsonb_array_elements(z->'locations') l
   where l->>'name' like 'HSH-%';
  if v_names is distinct from 'HSH-Loc-Active' then
    raise exception 'HIDDEN-STAYS-HIDDEN PROOF FAIL: get_world_map served [%] of the fixture set for anon, want exactly HSH-Loc-Active', coalesce(v_names, '<none>');
  end if;
  raise notice 'HSH_PASS_ANON_MAP_INTACT';
end $anonmap$;

reset role;

-- ══ D. THE SERVER-SIDE VIEW IS UNCHANGED (postgres / definer seat) ═══════════════════════════════
-- get_world_map is SECURITY DEFINER and postgres has BYPASSRLS, so this asks the question the
-- migration's repoint could actually have broken: does the map still return the same set it did
-- when its three filters were `status = 'active'` literals? Derived from the rows, never from a
-- hard-coded count.
do $srv$
declare
  v_map      integer;
  v_expected integer;
  v_hidden   integer;
begin
  select count(*) into v_map
    from jsonb_array_elements(public.get_world_map()->'sectors') se,
         jsonb_array_elements(se->'zones') z,
         jsonb_array_elements(z->'locations') l;

  select count(*) into v_expected
    from public.locations l
    join public.zones z   on z.id = l.zone_id
    join public.sectors s on s.id = z.sector_id
    join public.space_anchors a
      on a.location_id = l.id and a.kind = 'location' and a.status = 'active'
   where l.status = 'active' and z.status = 'active' and s.status = 'active';

  if v_map <> v_expected then
    raise exception 'HIDDEN-STAYS-HIDDEN PROOF FAIL: get_world_map returns % location(s), the active set is % — the repoint changed the server-side view', v_map, v_expected;
  end if;

  -- the raw rows are still THERE — this is a visibility change, not a data change. Scoped to the
  -- fixtures this proof OWNS (never to the chain's seed count, which is an ambient default).
  select count(*) into v_hidden
    from public.locations
   where name in ('HSH-Loc-Hidden', 'HSH-Loc-Locked',
                  'HSH-Loc-UnderHiddenZone', 'HSH-Loc-UnderHiddenSector');
  if v_hidden <> 4 then
    raise exception 'HIDDEN-STAYS-HIDDEN PROOF FAIL: % of the 4 unreleased fixtures exist server-side — hiding a row must never delete it', v_hidden;
  end if;

  raise notice 'HSH_PASS_SERVER_VIEW_UNCHANGED';
end $srv$;

-- ══ E. THE OWNER'S TOOL STILL READS MORE THAN ACTIVE ═════════════════════════════════════════════
-- This is the way the fix was most likely to go wrong: the World Editor deliberately lists inactive
-- entities, and tightening RLS would blind it IF it read the tables as the invoker. It does not —
-- world_editor_entity_catalog (0269) is SECURITY DEFINER owned by postgres. Proven by CALLING it as
-- a real owner over an authenticated JWT, not by inspecting its catalog row.
do $owner$
declare
  v_owner uuid := gen_random_uuid();
  r       jsonb;
  v_found integer;
begin
  insert into auth.users
    (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at,
     confirmation_token, recovery_token, email_change_token_new, email_change)
  values ('00000000-0000-0000-0000-000000000000', v_owner, 'authenticated', 'authenticated',
          'hsh.owner.' || replace(v_owner::text, '-', '') || '@example.com', '', now(), now(), now(), '', '', '', '');
  insert into public.app_owners(user_id) values (v_owner);

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner::text, 'role', 'authenticated')::text, true);

  r := public.world_editor_entity_catalog(jsonb_build_object('status', 'all'));
  if (r->>'ok')::boolean is not true then
    raise exception 'HIDDEN-STAYS-HIDDEN PROOF FAIL: the owner catalog did not return ok: %', r;
  end if;

  select count(*) into v_found
    from jsonb_array_elements(r->'rows') row_
   where row_->>'name' in ('HSH-Loc-Hidden', 'HSH-Loc-Locked');
  if v_found <> 2 then
    raise exception 'HIDDEN-STAYS-HIDDEN PROOF FAIL: the owner catalog returned % of the 2 unreleased location fixtures — tightening RLS blinded the owner tool', v_found;
  end if;

  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  raise notice 'HSH_PASS_OWNER_SEES_UNRELEASED';
end $owner$;

-- ══ F. THE VISIBILITY AUTHORITY IS ONE LEAF, NOT A POLICY PLUS A FILTER ══════════════════════════
do $auth1$
declare
  v_missing text;
  v_src     text;
  v_bad     text;
begin
  select string_agg(f, ', ' order by f) into v_missing
    from unnest(array[
      'public.world_sector_is_visible(text)',
      'public.world_zone_is_visible(text, uuid)',
      'public.world_location_is_visible(text, uuid)'
    ]) f
   where to_regprocedure(f) is null;
  if v_missing is not null then
    raise exception 'HIDDEN-STAYS-HIDDEN PROOF FAIL: the visibility authority is missing: %', v_missing;
  end if;

  select replace(p.prosrc, chr(13), '') into v_src
    from pg_proc p where p.oid = 'public.get_world_map()'::regprocedure;
  if position('l.status = ''active''' in v_src) > 0
     or position('z.status = ''active''' in v_src) > 0
     or position('se.status = ''active''' in v_src) > 0 then
    raise exception 'HIDDEN-STAYS-HIDDEN PROOF FAIL: get_world_map keeps its OWN copy of the visibility rule — two authorities that must agree is the defect, not the fix';
  end if;

  -- exactly one SELECT policy per table, and it is the composed one.
  select string_agg(t.t, ', ' order by t.t) into v_bad
    from unnest(array['sectors', 'zones', 'locations']) as t(t)
   where (select count(*) from pg_policy p where p.polrelid = ('public.' || t.t)::regclass) <> 1
      or not exists (select 1 from pg_policy p
                      where p.polrelid = ('public.' || t.t)::regclass
                        and p.polname = t.t || '_client_read'
                        and p.polcmd = 'r'
                        -- position(), not LIKE: pg_get_expr renders the schema qualifier only when
                        -- public is not on the search_path, so a LIKE anchored at the start would be
                        -- a coin flip on how the proof happens to be invoked.
                        and position('_is_visible(' in pg_get_expr(p.polqual, p.polrelid)) > 0);
  if v_bad is not null then
    raise exception 'HIDDEN-STAYS-HIDDEN PROOF FAIL: the policy set is not exactly one composed SELECT policy on: %', v_bad;
  end if;

  raise notice 'HSH_PASS_ONE_AUTHORITY';
end $auth1$;

-- ══ G. THE COMMITTED GRANT END STATE ═════════════════════════════════════════════════════════════
-- has_table_privilege, not information_schema — it is the only check that counts a privilege held
-- through the PUBLIC pseudo-role, which is the shape the 0309 lesson is about.
do $grants$
declare
  v_bad     text;
  v_missing text;
begin
  select string_agg(t || '.' || v || ' [' || r || ']', ', ' order by t, v, r) into v_bad
    from unnest(array['zones', 'sectors', 'bases'])              as t
   cross join unnest(array['INSERT', 'UPDATE', 'DELETE'])        as v
   cross join unnest(array['anon', 'authenticated', 'public'])   as r
   where has_table_privilege(r, 'public.' || t, v);
  if v_bad is not null then
    raise exception 'HIDDEN-STAYS-HIDDEN PROOF FAIL: client write privilege survives on: %', v_bad;
  end if;

  -- Asserted only where a MIGRATION established it: 0002:88 grants select on sectors/zones/locations
  -- to anon AND authenticated; 20260616000005_base_system.sql:58 grants select on bases to
  -- `authenticated` ONLY. anon's SELECT on bases exists on production solely because of the same
  -- project default whose write half 0318 revokes, so requiring it here would pass on prod and
  -- redden this chain.
  select string_agg(t || ' [' || r || ']', ', ' order by t, r) into v_missing
    from unnest(array['zones', 'sectors', 'locations'])           as t
   cross join unnest(array['anon', 'authenticated'])              as r
   where not has_table_privilege(r, 'public.' || t, 'SELECT');
  if v_missing is not null then
    raise exception 'HIDDEN-STAYS-HIDDEN PROOF FAIL: SELECT was revoked along with the writes on: %', v_missing;
  end if;
  if not has_table_privilege('authenticated', 'public.bases', 'SELECT') then
    raise exception 'HIDDEN-STAYS-HIDDEN PROOF FAIL: the authenticated SELECT on bases was revoked — baseApi.ts:16 would break';
  end if;

  raise notice 'HSH_PASS_GRANT_END_STATE';
end $grants$;

-- ══ H. THE REVOKE IS EFFECTIVE — established, not assumed ════════════════════════════════════════
-- Section G cannot distinguish "0318 revoked the drift" from "the drift never existed here", because
-- `supabase start` does not reproduce Supabase's project-level default privileges. So OWN the
-- precondition: create the drift, prove it is real, run 0318's exact revoke, prove it is gone.
grant insert, update, delete on table public.zones to anon, authenticated;

do $driftcheck$
begin
  if not has_table_privilege('anon', 'public.zones', 'INSERT')
     or not has_table_privilege('authenticated', 'public.zones', 'UPDATE') then
    raise exception 'HIDDEN-STAYS-HIDDEN PROOF FAIL: could not establish the drift precondition — the rest of section H would be vacuous';
  end if;
end $driftcheck$;

-- byte-for-byte the statement migration 0318 runs.
revoke insert, update, delete on table public.zones   from public, anon, authenticated;

do $revokecheck$
declare
  v_bad text;
begin
  select string_agg(v || ' [' || r || ']', ', ' order by v, r) into v_bad
    from unnest(array['INSERT', 'UPDATE', 'DELETE'])              as v
   cross join unnest(array['anon', 'authenticated', 'public'])    as r
   where has_table_privilege(r, 'public.zones', v);
  if v_bad is not null then
    raise exception 'HIDDEN-STAYS-HIDDEN PROOF FAIL: 0318''s revoke statement did not remove the drift: %', v_bad;
  end if;
  if not has_table_privilege('anon', 'public.zones', 'SELECT') then
    raise exception 'HIDDEN-STAYS-HIDDEN PROOF FAIL: 0318''s revoke statement also removed SELECT';
  end if;
  raise notice 'HSH_PASS_REVOKE_EFFECTIVE';
end $revokecheck$;

do $$ begin raise notice 'HIDDEN-STAYS-HIDDEN PROOF PASSED'; end $$;

rollback;   -- leave ZERO persisted state (fixtures, the synthetic owner and the section-H grant included).
