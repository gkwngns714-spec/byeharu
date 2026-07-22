-- WORLD-EDITOR V1C ANCHOR WRITE-AUTHORITY — disposable apply-proof (run against a THROWAWAY local Supabase ONLY).
--
-- Proves migration 0264 (20260618000264_worldeditor_v1c_anchor_write_authority.sql) after the FULL chain is
-- applied by `supabase start` — space_anchors is now the SOLE location-coordinate authority (read AND write):
--   0. MIGRATION INERT — the migration modified NO existing data row: its only DML is the idempotent backfill,
--      which on this chain inserts ZERO (0245 already anchored every location); no anchor was retired, and the
--      world-editor audit ledger is empty (the migration ran no editor command).
--   1. BYTE-IDENTITY — for the pre-existing SEEDED world, the anchor-backed get_world_map() payload is
--      byte-identical (jsonb AND text) to the legacy locations.x/y payload — nothing regressed / moved.
--   2. CREATE → ANCHOR — after a location_create() RPC, EXACTLY ONE active location anchor exists at the
--      created coords, and get_world_map() returns that location at those coords.
--   3. UPDATE → RETIRE+INSERT — after a coordinate location_update() RPC, the OLD anchor is retired and EXACTLY
--      ONE NEW active anchor exists at the new coords (never two active), and get_world_map() follows.
--   4. NON-COORD UPDATE keeps the anchor — an update that does NOT move x/y leaves the SAME active anchor row.
--   5. ONE ACTIVE PER LOCATION — exactly one active anchor per active location after all operations.
--   6. MIGRATION ORDER — 0264 sits after prod head 0262 in the applied chain (and is the greatest version).
--
-- Self-rolling-back: everything runs inside one begin;...rollback; — ZERO persisted state, no world row kept.
-- The owner it "seeds" is a synthetic auth.users row created HERE. NEVER point this at production.

\set ON_ERROR_STOP on

begin;

-- ── PROOF 0 — MIGRATION INERT: it modified no existing data row (empty backfill, nothing retired, no audit) ─
do $$
declare v_locs int; v_anchors int; v_retired int; v_audit int;
begin
  select count(*) into v_locs    from public.locations;
  select count(*) into v_anchors from public.space_anchors where kind = 'location' and status = 'active';
  select count(*) into v_retired from public.space_anchors where kind = 'location' and status = 'retired';
  select count(*) into v_audit   from public.world_editor_audit;
  if v_locs = 0 then
    raise exception 'WAUTH PROOF FAIL: no locations — every invariant would be vacuous';
  end if;
  -- backfill was a no-op: every location already had its active anchor (count matches, none missing).
  if v_anchors <> v_locs then
    raise exception 'WAUTH PROOF FAIL: % active location anchor(s) for % location(s) — backfill was NOT a clean no-op', v_anchors, v_locs;
  end if;
  -- the migration retired NO anchor (it relocates none), and ran NO editor command (audit ledger empty).
  if v_retired <> 0 then
    raise exception 'WAUTH PROOF FAIL: % retired location anchor(s) exist on a fresh chain — the migration relocated an anchor it should not have', v_retired;
  end if;
  if v_audit <> 0 then
    raise exception 'WAUTH PROOF FAIL: world_editor_audit has % row(s) on a fresh chain — the migration wrote an editor/audit row', v_audit;
  end if;
  raise notice 'WAUTH_PASS_MIGRATION_INERT (% locations, % active anchors, 0 retired, 0 audit)', v_locs, v_anchors;
end $$;

-- ── PROOF 6 — MIGRATION ORDER: 0264 applied after prod head 0262 (and is the greatest version) ─────────────
do $$
declare v_head text; v_has262 bool; v_has263 bool; v_has264 bool;
begin
  select exists(select 1 from supabase_migrations.schema_migrations where version = '20260618000262') into v_has262;
  select exists(select 1 from supabase_migrations.schema_migrations where version = '20260618000263') into v_has263;
  select exists(select 1 from supabase_migrations.schema_migrations where version = '20260618000264') into v_has264;
  select max(version) into v_head from supabase_migrations.schema_migrations;
  if not v_has262 then raise exception 'WAUTH PROOF FAIL: prod head 0262 is not in the applied chain'; end if;
  if not v_has263 then raise exception 'WAUTH PROOF FAIL: read-cutover 0263 is not in the applied chain'; end if;
  if not v_has264 then raise exception 'WAUTH PROOF FAIL: write-authority 0264 is not in the applied chain'; end if;
  if v_head <> '20260618000264' then
    raise exception 'WAUTH PROOF FAIL: applied head is % — 0264 must be the greatest version (after 0262)', v_head;
  end if;
  raise notice 'WAUTH_PASS_MIGRATION_ORDER (head=%, 0262/0263/0264 all present)', v_head;
end $$;

-- ── PROOF 1 — BYTE-IDENTITY for the SEEDED world (before any create/update): anchor payload == legacy x/y ──
create function pg_temp.get_world_map_legacy_xy()
returns jsonb
language sql
stable
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
                      'x', l.x, 'y', l.y, 'base_difficulty', l.base_difficulty,
                      'reward_tier', l.reward_tier, 'activity_type', l.activity_type,
                      'min_power_required', l.min_power_required,
                      'is_public', l.is_public, 'status', l.status,
                      'territory_radius', l.territory_radius
                    ) order by l.name)
                  from public.locations l
                  where l.zone_id = z.id and l.status = 'active'
                ), '[]'::jsonb)
              ) order by z.name)
            from public.zones z
            where z.sector_id = se.id and z.status = 'active'
          ), '[]'::jsonb)
        ) order by se.sector_index)
      from public.sectors se
      where se.status = 'active'
    ), '[]'::jsonb)
  );
$$;

do $$
declare v_live jsonb; v_legacy jsonb; v_loc_count int;
begin
  v_live   := public.get_world_map();
  v_legacy := pg_temp.get_world_map_legacy_xy();
  select count(*) into v_loc_count
    from jsonb_array_elements(v_live->'sectors') se,
         jsonb_array_elements(se->'zones')       z,
         jsonb_array_elements(z->'locations')    loc;
  if v_loc_count <= 3 then
    raise exception 'WAUTH PROOF FAIL: get_world_map emitted only % location(s) — byte-identity would be near-vacuous', v_loc_count;
  end if;
  if v_live is distinct from v_legacy then
    raise exception 'WAUTH PROOF FAIL: fail-closed anchor payload differs (jsonb) from legacy locations.x/y payload';
  end if;
  if v_live::text <> v_legacy::text then
    raise exception 'WAUTH PROOF FAIL: fail-closed anchor payload differs (text) from legacy locations.x/y payload';
  end if;
  raise notice 'WAUTH_PASS_BYTE_IDENTICAL (% locations, jsonb + text identical)', v_loc_count;
end $$;

-- ── fixtures: a synthetic OWNER + one existing zone to create into ─────────────────────────────────────────
create temp table wauth_owner(k text primary key, v uuid) on commit drop;
insert into wauth_owner values ('owner', gen_random_uuid());
insert into auth.users
  (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
   confirmation_token,recovery_token,email_change_token_new,email_change)
select '00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated',
       'wauth.owner.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','',''
from wauth_owner;
insert into public.app_owners(user_id) select v from wauth_owner;

create temp table wauth_zone(k text primary key, v uuid) on commit drop;
do $$
declare v_zone uuid;
begin
  -- pick a zone reachable through the ACTIVE sector→zone hierarchy get_world_map renders, so a location
  -- created into it is guaranteed to appear in the map payload.
  select z.id into v_zone
    from public.zones z
    join public.sectors se on se.id = z.sector_id
   where z.status = 'active' and se.status = 'active'
   order by z.name limit 1;
  if v_zone is null then
    raise exception 'WAUTH PROOF SETUP FAIL: no active zone under an active sector to create a location in';
  end if;
  insert into wauth_zone values ('zone', v_zone);
end $$;

-- ── PROOF 2 — CREATE writes EXACTLY ONE active anchor at the created coords; get_world_map shows it ────────
create temp table wauth_created(k text primary key, v uuid) on commit drop;
do $$
declare v_owner uuid; v_zone uuid; r jsonb; v_id uuid; n int;
        v_ax double precision; v_ay double precision; v_mx double precision; v_my double precision;
begin
  select v into v_owner from wauth_owner where k = 'owner';
  select v into v_zone  from wauth_zone  where k = 'zone';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.location_create('wauth-create-req-1', jsonb_build_object(
         'fields', jsonb_build_object(
           'zone_id', v_zone::text,
           'name','WAUTH Created Alpha','location_type','rally_point','activity_type','rally',
           'x',1234.5,'y',-4321.25,'reward_tier',2,'base_difficulty',1.5,'min_power_required',7,
           'is_public',false,'territory_radius',33,'status','active')));
  if (r->>'ok')::boolean is not true or (r->'result'->>'created') <> 'true' then
    raise exception 'WAUTH PROOF FAIL: owner create not ok: %', r;
  end if;
  v_id := (r->'result'->>'id')::uuid;
  insert into wauth_created values ('id', v_id);

  -- exactly ONE active location anchor for the new location, at EXACTLY the created coords.
  select count(*) into n from public.space_anchors
   where location_id = v_id and kind = 'location' and status = 'active';
  if n <> 1 then
    raise exception 'WAUTH PROOF FAIL: created location has % active anchor(s), expected exactly 1', n;
  end if;
  select space_x, space_y into v_ax, v_ay from public.space_anchors
   where location_id = v_id and kind = 'location' and status = 'active';
  if v_ax is distinct from 1234.5::double precision or v_ay is distinct from (-4321.25)::double precision then
    raise exception 'WAUTH PROOF FAIL: created anchor coords (%,%) != created (1234.5,-4321.25)', v_ax, v_ay;
  end if;

  -- get_world_map returns the created location at the anchor coords.
  select (loc->>'x')::double precision, (loc->>'y')::double precision into v_mx, v_my
    from jsonb_array_elements(public.get_world_map()->'sectors') se,
         jsonb_array_elements(se->'zones')    z,
         jsonb_array_elements(z->'locations') loc
   where (loc->>'id')::uuid = v_id;
  if v_mx is distinct from 1234.5::double precision or v_my is distinct from (-4321.25)::double precision then
    raise exception 'WAUTH PROOF FAIL: get_world_map shows created location at (%,%), expected (1234.5,-4321.25)', v_mx, v_my;
  end if;
  raise notice 'WAUTH_PASS_CREATE_ANCHORED (one active anchor at created coords; map follows)';
end $$;

-- ── PROOF 3 — coordinate UPDATE retires the old anchor + inserts EXACTLY ONE new active at the new coords ──
do $$
declare v_owner uuid; r jsonb; v_id uuid; n_active int;
        v_ax double precision; v_ay double precision; v_mx double precision; v_my double precision;
        v_old_anchor uuid;
begin
  select v into v_owner from wauth_owner where k = 'owner';
  select v into v_id    from wauth_created where k = 'id';
  select id into v_old_anchor from public.space_anchors
   where location_id = v_id and kind = 'location' and status = 'active';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  -- expected = the fork-time snapshot (the created row's current values); fields move x/y only.
  r := public.location_update('wauth-update-req-1', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object(
           'name','WAUTH Created Alpha','location_type','rally_point','activity_type','rally',
           'x',1234.5,'y',-4321.25,'reward_tier',2,'base_difficulty',1.5,'min_power_required',7,
           'is_public',false,'territory_radius',33,'status','active'),
         'fields', jsonb_build_object(
           'name','WAUTH Created Alpha','location_type','rally_point','activity_type','rally',
           'x',-2222.75,'y',888.5,'reward_tier',2,'base_difficulty',1.5,'min_power_required',7,
           'is_public',false,'territory_radius',33,'status','active')));
  if (r->>'ok')::boolean is not true or (r->'result'->>'updated') <> 'true' then
    raise exception 'WAUTH PROOF FAIL: coordinate update not ok: %', r;
  end if;

  -- EXACTLY ONE active anchor (never two), at the NEW coords; the old anchor is RETIRED (not deleted).
  select count(*) into n_active from public.space_anchors
   where location_id = v_id and kind = 'location' and status = 'active';
  if n_active <> 1 then
    raise exception 'WAUTH PROOF FAIL: after coordinate update the location has % active anchor(s), expected exactly 1 (never two)', n_active;
  end if;
  select space_x, space_y into v_ax, v_ay from public.space_anchors
   where location_id = v_id and kind = 'location' and status = 'active';
  if v_ax is distinct from (-2222.75)::double precision or v_ay is distinct from 888.5::double precision then
    raise exception 'WAUTH PROOF FAIL: new active anchor coords (%,%) != new (-2222.75,888.5)', v_ax, v_ay;
  end if;
  -- the previously-active anchor is now RETIRED (relocation = retire + insert, not in-place edit).
  if not (select status = 'retired' from public.space_anchors where id = v_old_anchor) then
    raise exception 'WAUTH PROOF FAIL: the prior anchor was not retired (relocation must retire+insert, not edit in place)';
  end if;
  if (select count(*) from public.space_anchors where location_id = v_id and kind = 'location') <> 2 then
    raise exception 'WAUTH PROOF FAIL: expected 2 anchor rows (1 retired + 1 active) after one relocation';
  end if;

  -- get_world_map follows to the new coords; locations.x/y ALSO moved (the RPC writes both, in lock-step).
  select (loc->>'x')::double precision, (loc->>'y')::double precision into v_mx, v_my
    from jsonb_array_elements(public.get_world_map()->'sectors') se,
         jsonb_array_elements(se->'zones')    z,
         jsonb_array_elements(z->'locations') loc
   where (loc->>'id')::uuid = v_id;
  if v_mx is distinct from (-2222.75)::double precision or v_my is distinct from 888.5::double precision then
    raise exception 'WAUTH PROOF FAIL: get_world_map shows (%,%) after update, expected (-2222.75,888.5)', v_mx, v_my;
  end if;
  if (select x from public.locations where id = v_id) is distinct from (-2222.75)::double precision then
    raise exception 'WAUTH PROOF FAIL: locations.x did not move with the anchor — the two sources drifted';
  end if;
  raise notice 'WAUTH_PASS_UPDATE_RETIRE_INSERT (old anchor retired, one new active at new coords, map follows)';
end $$;

-- ── PROOF 4 — a NON-coordinate update leaves the SAME active anchor row untouched ─────────────────────────
do $$
declare v_owner uuid; r jsonb; v_id uuid; v_before uuid; v_after uuid;
begin
  select v into v_owner from wauth_owner where k = 'owner';
  select v into v_id    from wauth_created where k = 'id';
  select id into v_before from public.space_anchors
   where location_id = v_id and kind = 'location' and status = 'active';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  -- change ONLY reward_tier (coords stay at -2222.75,888.5); expected = the current live row.
  r := public.location_update('wauth-update-noncoord-req-1', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object(
           'name','WAUTH Created Alpha','location_type','rally_point','activity_type','rally',
           'x',-2222.75,'y',888.5,'reward_tier',2,'base_difficulty',1.5,'min_power_required',7,
           'is_public',false,'territory_radius',33,'status','active'),
         'fields', jsonb_build_object(
           'name','WAUTH Created Alpha','location_type','rally_point','activity_type','rally',
           'x',-2222.75,'y',888.5,'reward_tier',5,'base_difficulty',1.5,'min_power_required',7,
           'is_public',false,'territory_radius',33,'status','active')));
  if (r->>'ok')::boolean is not true or (r->'result'->>'updated') <> 'true' then
    raise exception 'WAUTH PROOF FAIL: non-coordinate update not ok: %', r;
  end if;
  select id into v_after from public.space_anchors
   where location_id = v_id and kind = 'location' and status = 'active';
  if v_after is distinct from v_before then
    raise exception 'WAUTH PROOF FAIL: a non-coordinate update replaced the anchor (% -> %) — it must be left untouched', v_before, v_after;
  end if;
  if (select count(*) from public.space_anchors where location_id = v_id and kind = 'location') <> 2 then
    raise exception 'WAUTH PROOF FAIL: a non-coordinate update created a new anchor row (expected still 2: 1 retired + 1 active)';
  end if;
  raise notice 'WAUTH_PASS_NONCOORD_UPDATE_KEEPS_ANCHOR (same active anchor row, no relocation)';
end $$;

-- ── PROOF 5 — EXACTLY ONE active anchor per active location, world-wide, after all operations ─────────────
do $$
declare v_dupes int; v_missing int;
begin
  select count(*) into v_dupes
    from (select location_id from public.space_anchors
           where kind = 'location' and status = 'active'
           group by location_id having count(*) > 1) d;
  if v_dupes <> 0 then
    raise exception 'WAUTH PROOF FAIL: % location(s) have more than one active anchor', v_dupes;
  end if;
  select count(*) into v_missing
    from public.locations l
   where not exists (select 1 from public.space_anchors a
                      where a.location_id = l.id and a.kind = 'location' and a.status = 'active');
  if v_missing <> 0 then
    raise exception 'WAUTH PROOF FAIL: % location(s) have NO active anchor — the fail-closed read would drop them', v_missing;
  end if;
  raise notice 'WAUTH_PASS_ONE_ACTIVE_PER_LOCATION (no duplicates, none missing)';
end $$;

do $$ begin raise notice 'WORLD-EDITOR V1C ANCHOR WRITE-AUTHORITY PROOF PASSED'; end $$;

rollback;   -- leave ZERO persisted state.
