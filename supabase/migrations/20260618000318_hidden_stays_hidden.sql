-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0318 — HIDDEN STAYS HIDDEN
--        (one authority for "can this client see this row", and the drifted client write grants
--         on zones / sectors / bases are REVOKED rather than merely asserted)
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- ── THE LIVE LEAK, REPRODUCED AGAINST PRODUCTION WITH ONLY THE PUBLIC ANON KEY ──────────────────
--   GET /rest/v1/locations?select=name,status,x,y,territory_radius&status=eq.hidden   -> HTTP 200
--   [{"name":"Ember Gate","status":"hidden","x":300,"y":270,"territory_radius":12},
--    {"name":"Cinder Maw","status":"hidden","x":375,"y":330,"territory_radius":12},
--    {"name":"The Furnace","status":"hidden","x":450,"y":390,"territory_radius":12}]
--
-- Those are the three unreleased Ember-tier pirate sites seeded HIDDEN by 0175. Names and exact
-- coordinates, readable by anyone, unauthenticated, on a live ~30-player game.
--
-- ── THE CAUSE: TWO VISIBILITY AUTHORITIES FOR ONE TABLE, AND THE PERMISSIVE ONE IS REACHABLE ────
-- 20260616000002_world_map.sql created both halves in the same file, twenty lines apart:
--   :81-83   create policy sectors_public_read  / zones_public_read / locations_public_read
--            for select USING (TRUE)                       <- the reachable authority
--   :121,:125,:129  get_world_map() filters status='active' at all three nesting levels
--                                                          <- the intended authority
-- Every client read goes through get_world_map, so the intended rule is what the game behaves like
-- and the permissive rule is what the API actually enforces. 0175's own header recorded the gap and
-- accepted it: "Hidden != secret: locations has public-read RLS (0002:83), so a raw table read can
-- always see hidden rows — accepted since the 0066 hidden starter ports". That acceptance is what
-- this migration withdraws. A rule that two places must agree on is not one rule; it is two, and one
-- of them was wrong for the entire life of the schema.
--
-- ── THE FIX: ONE LEAF, COMPOSED TWICE — NOT A POLICY AND A FILTER THAT MUST AGREE ───────────────
-- Three predicate functions become THE definition of client visibility for the static world. The
-- RLS policy calls them. get_world_map calls the SAME functions in place of its three status
-- literals. There is now exactly one place where "can a client see this row" is written down; both
-- readers compose it. If the rule ever changes, it changes once.
--
--   world_sector_is_visible(status)                  status = 'active'
--   world_zone_is_visible(status, sector_id)         status = 'active' AND its sector is visible
--   world_location_is_visible(status, zone_id)       status = 'active' AND its zone is visible
--
-- ── WHY THAT IS THE RULE FOR EACH TABLE (established from source, not mirrored blindly) ─────────
--
-- locations.status IS the reveal mechanic, and it is the ONLY one. Every writer that has ever made
-- a location appear sets status='active' and nothing else:
--   * reveal_starter_ports  — 0068:119 / re-created 0227:257, `update public.locations set
--     status = 'active' where id = any(v_ports)`, service_role-only, hardcoded port uuids.
--   * the World Editor publish path — 0249/0264/0265/0267/0296 write status through the owner-gated
--     SECURITY DEFINER command contract.
--   * the ZONES2-2 reveal script for these exact three rows — 0175's header: "The ZONES2-2 reveal
--     flips ONLY the three location rows".
-- So a policy keyed on status FOLLOWS the reveal mechanic exactly: the day the owner reveals Ember
-- Reach, the rows become client-readable in the same statement that puts them on the map. There is
-- no second flag to remember.
--
-- is_public IS NOT A VISIBILITY GATE and must not be used as one. Grepped every migration and every
-- src/ file: it is written by the publish RPCs, emitted by get_world_map, rendered by the editor
-- (worldEditorAdapters.ts:66) and diffed by the audit UI (worldEditorAuditDiff.ts:54 classifies it
-- 'display') — and NOTHING anywhere filters on it. All three hidden rows carry is_public=true, so
-- keying the policy on it would leak exactly the rows this migration exists to hide. It is an inert
-- display field; treating it as a gate would invent a THIRD authority.
--
-- physical_role IS NOT A VISIBILITY GATE either. Exactly one query in 300 migrations filters it:
-- 0066:79 `l.physical_role in ('city','port')`, the starter-port reveal ELIGIBILITY list. The three
-- hidden rows are 'activity_site' (0175 chose it deliberately so port/dock predicates stay
-- fail-closed). Visibility is not its job.
--
-- zones.visibility ('visible'|'hidden'|'scouted', 0002:37-38) IS ALSO INERT — get_world_map emits it
-- (0002:109) and no query filters it. zones/sectors are gated by status, like locations.
--
-- exploration DISCOVERY reveals nothing here: 0099/0100/0146/0172/0221 all write
-- exploration_discoveries rows and none of them touches public.locations. The discovery mechanic
-- lives entirely in exploration_sites, which already has no permissive policy.
--
-- THE NESTING IS PART OF THE RULE, not decoration. get_world_map returns a location only when its
-- zone AND its sector are also active, because it reaches locations through those parents. A flat
-- `status = 'active'` policy on locations alone would therefore be LOOSER than the read path — a
-- location parked under a retired zone would become directly readable while the map correctly hid
-- it. The predicates compose upward so the two can never diverge. (Prod today has 3 active sectors,
-- 3 active zones, 8 active + 3 hidden locations, and zero rows in the divergent case — verified
-- read-only before writing this; the composition costs nothing today and is what keeps it correct
-- the first time someone retires a zone.)
--
-- ── WHAT DOES NOT CHANGE, AND WHY THE GAME CANNOT BREAK ─────────────────────────────────────────
-- NO client code reads these tables directly. Grepped all of src/: the only `.from()` against any of
-- the four is baseApi.ts:16 `from('bases').select('*')` — a SELECT, already scoped by
-- bases_select_own (player_id = auth.uid()), untouched here. There is no `.from('locations')`,
-- `.from('zones')` or `.from('sectors')` anywhere, and no PostgREST embedded-resource select that
-- would reach them. The client's ONLY path to the static world is get_world_map.
--
-- get_world_map is SECURITY DEFINER, owner postgres, since 0263 — and postgres carries BYPASSRLS on
-- this project (verified live). So RLS never applied to it and still does not; it keeps serving the
-- richer server-side view. Its OUTPUT after this migration is byte-identical, proven two ways: the
-- reverse-derivation parity assert in step 5, and the row-count assert in step 6.
--
-- Every other reader is SECURITY DEFINER too. Queried production for every function whose body
-- references public.locations / zones / sectors / bases: exactly ONE is SECURITY INVOKER —
-- danger_zone_rematerialize_for_location(uuid) — and neither anon nor authenticated can execute it
-- (it is an internal leaf called only from definer functions, where it inherits postgres). So the
-- World Editor's owner-only surface, which deliberately reads MORE than active
-- (world_editor_entity_catalog 0269, world_editor_entity_detail 0270, world_editor_revert 0267, the
-- publish/update RPCs) is entirely unaffected — that was the most likely way this fix goes wrong and
-- it does not apply. There are also ZERO views or materialized views over these tables.
--
-- service_role carries BYPASSRLS (verified live), so every .mjs verifier and every ops script keeps
-- reading the whole table.
--
-- ── THE SECOND FINDING: DRIFTED CLIENT WRITE GRANTS ON zones / sectors / bases ──────────────────
-- Production, read live via has_table_privilege (which folds in privileges held through PUBLIC):
--
--   table              anon INS/UPD/DEL     authenticated INS/UPD/DEL
--   locations          f / f / f            f / f / f      <- correctly revoked
--   mining_fields      f / f / f            f / f / f      <- correctly revoked
--   exploration_sites  f / f / f            f / f / f      <- correctly revoked
--   danger_zones       f / f / f            f / f / f      <- revoked by the 0254 fix (2026-07-20)
--   zones              t / t / t            t / t / t      <- DRIFT
--   sectors            t / t / t            t / t / t      <- DRIFT
--   bases              t / t / t            t / t / t      <- DRIFT
--
-- 0002:85-88 states that SELECT-only grants were established — "We intentionally do NOT grant
-- insert/update/delete" — and production disagrees, because the Supabase project-level default
-- GRANT ALL on new public tables was applied when the tables were created and no migration ever
-- revoked it. That is exactly the class that aborted the 0254 production deploy on danger_zones.
-- Not live-exploitable today (all three carry RLS with SELECT-only policies, so a write is denied by
-- the policy), but one permissive policy away from being so — and the whole point of this migration
-- is that a permissive policy is precisely the thing that turns out to be there.
--
-- ESTABLISH, NEVER MERELY ASSERT (the 0254 lesson, stated in 0309 and applied again here): this file
-- REVOKEs and then asserts the end state.
--
-- `public` IS IN THE REVOKE LIST DELIBERATELY — the 0309 lesson. has_table_privilege() counts a
-- privilege held via the PUBLIC pseudo-role, so a revoke naming only anon and authenticated can
-- remove NOTHING while the assert still sees the privilege, and the migration would then ABORT THE
-- PRODUCTION DEPLOY instead of fixing anything.
--
-- NO VACUITY PRECONDITION, deliberately, and this is the one place the net has a hole. 0309 could
-- refuse to run when its revoke would be a no-op, because EXECUTE grants are created by migrations
-- and therefore exist on a disposable chain too. These table grants are NOT: they come from a
-- project-level default that `supabase start` does not reproduce, so on CI's throwaway Postgres the
-- three tables carry no client write and the revoke is legitimately a no-op there. A non-vacuity
-- precondition would redden the entire chain in CI while passing on prod — inverted. The revoke is
-- idempotent and the END-STATE assert is what runs on production at deploy time; the proof covers
-- the efficacy of the revoke separately by establishing the drift itself and revoking it in-txn.
--
-- ── SCOPE: 67 OF 100 PUBLIC TABLES CARRY THIS DRIFT. THIS MIGRATION FIXES THREE ─────────────────
-- Swept every public table on production. 67 grant INSERT/UPDATE/DELETE to anon and authenticated.
-- Of those, exactly one (profiles) has a write POLICY and so is genuinely load-bearing, and one
-- (spatial_ref_sys) is a PostGIS system table. The remaining ~65 are latent in the same way these
-- three are. They are NOT swept here: this slice's contract is the hidden-row leak and the three
-- tables named with it, and a 65-table ACL change is a different slice with its own blast-radius
-- analysis that CI structurally cannot validate (the grants do not exist on the disposable chain).
-- The full inventory is in the slice report; do not read this paragraph as "the class is closed".
--
-- ── ROLLBACK ────────────────────────────────────────────────────────────────────────────────────
-- The commented block at the bottom restores the pre-0318 posture exactly (the three USING(true)
-- policies and the get_world_map head from 0264). It deliberately does NOT re-grant the write
-- privileges — restoring a Supabase project default that no migration ever intended is not a
-- rollback, it is a regression.

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ── 1. PRECONDITION — the three permissive policies are still exactly what this slice replaces ───
do $pre1$
declare
  v_bad text;
begin
  select string_agg(t || ': ' || coalesce(q, '<missing>'), ', ' order by t) into v_bad
    from (
      select x.t,
             (select pg_get_expr(p.polqual, p.polrelid)
                from pg_policy p
               where p.polrelid = ('public.' || x.t)::regclass
                 and p.polname  = x.t || '_public_read'
                 and p.polcmd   = 'r') as q
        from unnest(array['sectors', 'zones', 'locations']) as x(t)
    ) s
   where q is distinct from 'true';
  if v_bad is not null then
    raise exception '0318 PRECONDITION FAIL: the permissive read policies are not the expected USING (true) — %', v_bad;
  end if;
end $pre1$;

-- ── 2. PRECONDITION — get_world_map is byte-for-byte the head this slice slices from ─────────────
-- The pin is the FULL-BODY md5 of the deployed text, not "the old filter is still present": prod
-- could carry the old filter PLUS later edits, and re-creating from a stale copy would silently
-- revert them. Fetched read-only from production before this file was written; identical on a
-- freshly applied chain because 0264 is the last textual re-create (0002 -> 0217 -> 0263 -> 0264,
-- grep-verified). CR is stripped first so a CRLF checkout cannot change the answer.
do $pre2$
declare
  v_md5     text;
  v_secdef  boolean;
begin
  select md5(replace(p.prosrc, chr(13), '')), p.prosecdef
    into v_md5, v_secdef
    from pg_proc p
   where p.oid = 'public.get_world_map()'::regprocedure;
  if v_md5 is distinct from '6c2f30dad96990a5a4839f29329df7c8' then
    raise exception '0318 PRECONDITION FAIL: get_world_map body is not the 0264 head (md5 %) — somebody re-created it after 0264. Read that migration and re-point this slice; do NOT regenerate blindly.', coalesce(v_md5, '<absent>');
  end if;
  if not coalesce(v_secdef, false) then
    raise exception '0318 PRECONDITION FAIL: get_world_map is no longer SECURITY DEFINER — tightening RLS would blank the player map';
  end if;
end $pre2$;

-- ── 3. THE ONE VISIBILITY AUTHORITY ──────────────────────────────────────────────────────────────
-- SECURITY DEFINER so the answer is RLS-INDEPENDENT and deterministic: a policy that consulted the
-- parent table as the invoker would give an answer that depends on the parent's own policy, which is
-- itself defined in terms of these functions. Definer breaks that circle — these read the raw rows
-- and the policies are pure consumers.
--
-- Granting EXECUTE to anon/authenticated is required (a policy expression runs as the querying role)
-- and discloses nothing: the functions take a status text and a parent uuid and return a boolean
-- that the caller could already compute from rows they are allowed to read.
--
-- search_path is pinned to '' with every reference schema-qualified (house rule).

create or replace function public.world_sector_is_visible(p_status text)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select p_status = 'active';
$$;

create or replace function public.world_zone_is_visible(p_status text, p_sector_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_status = 'active'
     and exists (
       select 1 from public.sectors s
        where s.id = p_sector_id
          and public.world_sector_is_visible(s.status));
$$;

create or replace function public.world_location_is_visible(p_status text, p_zone_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_status = 'active'
     and exists (
       select 1 from public.zones z
        where z.id = p_zone_id
          and public.world_zone_is_visible(z.status, z.sector_id));
$$;

alter function public.world_sector_is_visible(text)          owner to postgres;
alter function public.world_zone_is_visible(text, uuid)      owner to postgres;
alter function public.world_location_is_visible(text, uuid)  owner to postgres;

revoke execute on function public.world_sector_is_visible(text)         from public;
revoke execute on function public.world_zone_is_visible(text, uuid)     from public;
revoke execute on function public.world_location_is_visible(text, uuid) from public;

grant execute on function public.world_sector_is_visible(text)         to anon, authenticated, service_role;
grant execute on function public.world_zone_is_visible(text, uuid)     to anon, authenticated, service_role;
grant execute on function public.world_location_is_visible(text, uuid) to anon, authenticated, service_role;

-- ── 4. THE POLICIES — the permissive ones are DELETED, not left beside the new ones ──────────────
-- Two SELECT policies on one table OR together, so leaving locations_public_read in place would make
-- the new policy decorative. The old authority dies in the slice that replaces it.
drop policy if exists "sectors_public_read"   on public.sectors;
drop policy if exists "zones_public_read"     on public.zones;
drop policy if exists "locations_public_read" on public.locations;

create policy "sectors_client_read" on public.sectors
  for select using (public.world_sector_is_visible(status));

create policy "zones_client_read" on public.zones
  for select using (public.world_zone_is_visible(status, sector_id));

create policy "locations_client_read" on public.locations
  for select using (public.world_location_is_visible(status, zone_id));

-- ── 5. get_world_map RE-CREATED — 0264's exact bytes, three filters repointed at the authority ───
-- The body below is a byte-copy of the deployed text (pinned in step 2) with exactly three tokens
-- changed. Step 5b proves that mechanically rather than by review promise: it substitutes the three
-- new predicates back to their old literals and re-computes the md5, which must reproduce the pin.
-- Signature, volatility, SECURITY DEFINER, search_path, owner and grants are all unchanged.
create or replace function public.get_world_map()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'sectors',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', se.id, 'name', se.name, 'sector_index', se.sector_index,
          'x', se.x, 'y', se.y, 'danger_tier', se.danger_tier, 'status', se.status,
          'zones', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'id', z.id, 'name', z.name, 'x', z.x, 'y', z.y, 'radius', z.radius,
                'base_difficulty', z.base_difficulty,
                'max_danger_level', z.max_danger_level,
                'reward_tier', z.reward_tier, 'visibility', z.visibility,
                'status', z.status,
                'locations', coalesce((
                  select jsonb_agg(
                    jsonb_build_object(
                      'id', l.id, 'name', l.name, 'location_type', l.location_type,
                      'x', a.space_x, 'y', a.space_y,
                      'base_difficulty', l.base_difficulty,
                      'reward_tier', l.reward_tier, 'activity_type', l.activity_type,
                      'min_power_required', l.min_power_required,
                      'is_public', l.is_public, 'status', l.status,
                      'territory_radius', l.territory_radius
                    ) order by l.name)
                  from public.locations l
                  join public.space_anchors a
                    on a.location_id = l.id and a.kind = 'location' and a.status = 'active'
                  where l.zone_id = z.id and public.world_location_is_visible(l.status, l.zone_id)
                ), '[]'::jsonb)
              ) order by z.name)
            from public.zones z
            where z.sector_id = se.id and public.world_zone_is_visible(z.status, z.sector_id)
          ), '[]'::jsonb)
        ) order by se.sector_index)
      from public.sectors se
      where public.world_sector_is_visible(se.status)
    ), '[]'::jsonb)
  );
$$;

-- ── 5b. SELF-ASSERT — parity outside the three hunks, proven by reverse derivation ───────────────
do $a5$
declare
  v_new     text;
  v_reverse text;
  v_hits    integer;
begin
  select replace(p.prosrc, chr(13), '') into v_new
    from pg_proc p where p.oid = 'public.get_world_map()'::regprocedure;

  -- each new predicate must appear EXACTLY once (an accidental double-apply would still reverse
  -- cleanly for the first occurrence, so count before substituting)
  select (length(v_new) - length(replace(v_new, 'public.world_location_is_visible(l.status, l.zone_id)', ''))) /
         length('public.world_location_is_visible(l.status, l.zone_id)')
    into v_hits;
  if v_hits <> 1 then
    raise exception '0318 ASSERT (5b) FAIL: the location predicate occurs % time(s) in get_world_map, want exactly 1', v_hits;
  end if;

  v_reverse := replace(v_new,
                 'public.world_location_is_visible(l.status, l.zone_id)', 'l.status = ''active''');
  v_reverse := replace(v_reverse,
                 'public.world_zone_is_visible(z.status, z.sector_id)',   'z.status = ''active''');
  v_reverse := replace(v_reverse,
                 'public.world_sector_is_visible(se.status)',             'se.status = ''active''');

  if md5(v_reverse) is distinct from '6c2f30dad96990a5a4839f29329df7c8' then
    raise exception '0318 ASSERT (5b) FAIL: get_world_map differs from the 0264 head OUTSIDE the three repointed filters (reverse-derived md5 %) — the body was retyped, not sliced', md5(v_reverse);
  end if;
end $a5$;

-- ── 6. SELF-ASSERT — the server-side view is unchanged, and the predicates actually discriminate ─
-- Derived from the live rows, never from a hard-coded expected count: the map must return exactly
-- the set of active locations under active zones under active sectors, which is what it returned
-- before. On a chain where every location is active this is still non-vacuous because it also
-- asserts the predicates reject a hidden row.
do $a6$
declare
  v_map_locations integer;
  v_expected      integer;
begin
  select count(*) into v_map_locations
    from jsonb_array_elements(public.get_world_map()->'sectors') se,
         jsonb_array_elements(se->'zones') z,
         jsonb_array_elements(z->'locations') l;

  select count(*) into v_expected
    from public.locations l
    join public.zones z    on z.id = l.zone_id
    join public.sectors s  on s.id = z.sector_id
    join public.space_anchors a
      on a.location_id = l.id and a.kind = 'location' and a.status = 'active'
   where l.status = 'active' and z.status = 'active' and s.status = 'active';

  if v_map_locations is distinct from v_expected then
    raise exception '0318 ASSERT (6) FAIL: get_world_map now returns % location(s), the active set is % — the repoint changed the server-side view', v_map_locations, v_expected;
  end if;

  -- the authority discriminates: active accepted, every non-active status rejected.
  if not public.world_sector_is_visible('active')
     or public.world_sector_is_visible('hidden')
     or public.world_sector_is_visible('locked')
     or public.world_sector_is_visible('inactive') then
    raise exception '0318 ASSERT (6) FAIL: world_sector_is_visible does not discriminate on status';
  end if;
end $a6$;

-- ── 7. THE REVOKES — establish the write lockdown, do not merely assert it ───────────────────────
revoke insert, update, delete on table public.zones   from public, anon, authenticated;
revoke insert, update, delete on table public.sectors from public, anon, authenticated;
revoke insert, update, delete on table public.bases   from public, anon, authenticated;

-- ── 8. SELF-ASSERT — the grant END STATE, checked with has_table_privilege ───────────────────────
-- has_table_privilege is the real check: it folds in privileges held through PUBLIC, which
-- information_schema.role_table_grants and a reading of pg_class.relacl both miss. 3 tables x 3
-- verbs x 3 grantees = 27 assertions, all of which must be false.
do $a8$
declare
  v_bad text;
begin
  select string_agg(t || '.' || v || ' [' || r || ']', ', ' order by t, v, r) into v_bad
    from unnest(array['zones', 'sectors', 'bases'])                as t
   cross join unnest(array['INSERT', 'UPDATE', 'DELETE'])          as v
   cross join unnest(array['anon', 'authenticated', 'public'])     as r
   where has_table_privilege(r, 'public.' || t, v);
  if v_bad is not null then
    raise exception '0318 ASSERT (8) FAIL: client write privilege SURVIVES on: %', v_bad;
  end if;
end $a8$;

-- ── 9. SELF-ASSERT — SELECT survives for the client, and the four cured siblings stay cured ──────
do $a9$
declare
  v_missing text;
  v_bad     text;
begin
  -- SELECT must survive exactly where a MIGRATION established it, and nowhere is it asserted on the
  -- strength of a project default. 0002:88 grants select on sectors/zones/locations to anon AND
  -- authenticated; 20260616000005_base_system.sql:58 grants select on bases to `authenticated` ONLY.
  -- anon's SELECT on bases exists on production, but it comes from the SAME Supabase project default
  -- whose write half this migration revokes — so asserting it would pass on prod and REDDEN the
  -- disposable chain, which is the CI-vs-production asymmetry pointing the wrong way. The revoke
  -- names only insert/update/delete, so SELECT is untouched either way.
  select string_agg(t || ' [' || r || ']', ', ' order by t, r) into v_missing
    from unnest(array['zones', 'sectors', 'locations'])            as t
   cross join unnest(array['anon', 'authenticated'])               as r
   where not has_table_privilege(r, 'public.' || t, 'SELECT');
  if v_missing is not null then
    raise exception '0318 ASSERT (9) FAIL: the revoke took SELECT as well — lost on: %', v_missing;
  end if;
  if not has_table_privilege('authenticated', 'public.bases', 'SELECT') then
    raise exception '0318 ASSERT (9) FAIL: the revoke took the authenticated SELECT on bases — baseApi.ts:16 would break';
  end if;

  -- the tables that were already correct must not have regressed while we were in here.
  select string_agg(t || '.' || v || ' [' || r || ']', ', ' order by t, v, r) into v_bad
    from unnest(array['locations', 'mining_fields', 'exploration_sites', 'danger_zones']) as t
   cross join unnest(array['INSERT', 'UPDATE', 'DELETE'])      as v
   cross join unnest(array['anon', 'authenticated', 'public']) as r
   where has_table_privilege(r, 'public.' || t, v);
  if v_bad is not null then
    raise exception '0318 ASSERT (9) FAIL: a previously-cured table carries client write: %', v_bad;
  end if;
end $a9$;

-- ── 10. SELF-ASSERT — the policy set is exactly one SELECT policy per table, and it is the new one ─
do $a10$
declare
  v_bad text;
begin
  select string_agg(x.t || ': ' || coalesce(x.detail, '<none>'), ', ' order by x.t) into v_bad
    from (
      select t.t,
             (select string_agg(p.polname || '/' || p.polcmd || '/' || coalesce(pg_get_expr(p.polqual, p.polrelid), 'null'), ' + '
                                order by p.polname)
                from pg_policy p where p.polrelid = ('public.' || t.t)::regclass) as detail,
             (select count(*) from pg_policy p where p.polrelid = ('public.' || t.t)::regclass) as n
        from unnest(array['sectors', 'zones', 'locations']) as t(t)
    ) x
   where x.n <> 1
      or x.detail not like x.t || '_client_read/r/%';
  if v_bad is not null then
    raise exception '0318 ASSERT (10) FAIL: expected exactly one SELECT policy <table>_client_read per table, found — %', v_bad;
  end if;

  -- and RLS is still ON, or the policies are decoration.
  select string_agg(c.relname, ', ' order by c.relname) into v_bad
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relname in ('sectors', 'zones', 'locations', 'bases')
     and not c.relrowsecurity;
  if v_bad is not null then
    raise exception '0318 ASSERT (10) FAIL: row level security is OFF on: %', v_bad;
  end if;
end $a10$;

-- ── 11. SELF-ASSERT — the visibility authority has exactly one definition, and nothing else keeps
--        a second copy of the rule on the client read path ───────────────────────────────────────
do $a11$
declare
  v_missing text;
  v_src     text;
begin
  select string_agg(f, ', ' order by f) into v_missing
    from unnest(array[
      'public.world_sector_is_visible(text)',
      'public.world_zone_is_visible(text, uuid)',
      'public.world_location_is_visible(text, uuid)'
    ]) f
   where to_regprocedure(f) is null;
  if v_missing is not null then
    raise exception '0318 ASSERT (11) FAIL: the visibility authority is not installed: %', v_missing;
  end if;

  -- get_world_map must hold NO status literal of its own for the three world tables any more (the
  -- space_anchors join's own a.status='active' is a different table and correctly stays).
  select replace(p.prosrc, chr(13), '') into v_src
    from pg_proc p where p.oid = 'public.get_world_map()'::regprocedure;
  if position('l.status = ''active''' in v_src) > 0
     or position('z.status = ''active''' in v_src) > 0
     or position('se.status = ''active''' in v_src) > 0 then
    raise exception '0318 ASSERT (11) FAIL: get_world_map still carries its own copy of the visibility rule — that is the two-authority defect this migration removes';
  end if;
  if position('a.status = ''active''' in v_src) = 0 then
    raise exception '0318 ASSERT (11) FAIL: the space_anchors active-anchor join was lost — the map would serve stale coordinates';
  end if;
end $a11$;

commit;

-- ── ROLLBACK (commented; restores the pre-0318 posture exactly) ──────────────────────────────────
-- Deliberately does NOT re-grant insert/update/delete on zones/sectors/bases — that privilege came
-- from a Supabase project default no migration ever intended, and restoring it is a regression, not
-- a rollback.
--
-- begin;
-- drop policy if exists "sectors_client_read"   on public.sectors;
-- drop policy if exists "zones_client_read"     on public.zones;
-- drop policy if exists "locations_client_read" on public.locations;
-- create policy "sectors_public_read"   on public.sectors   for select using (true);
-- create policy "zones_public_read"     on public.zones     for select using (true);
-- create policy "locations_public_read" on public.locations for select using (true);
-- -- and re-apply the get_world_map body from
-- -- supabase/migrations/20260618000264_worldeditor_v1c_anchor_write_authority.sql (md5 of the body
-- -- text, CR-stripped: 6c2f30dad96990a5a4839f29329df7c8), then:
-- -- drop function if exists public.world_location_is_visible(text, uuid);
-- -- drop function if exists public.world_zone_is_visible(text, uuid);
-- -- drop function if exists public.world_sector_is_visible(text);
-- commit;
