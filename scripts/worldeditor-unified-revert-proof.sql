-- WORLD EDITOR UNIFIED REVERT — disposable apply-proof (run against a THROWAWAY local Supabase ONLY).
--
-- Proves migration 0267 (20260618000267_worldeditor_unified_revert.sql) after the FULL chain is applied
-- by `supabase start`: the ONE cross-domain command world_editor_revert reverts an audited entity to its
-- before_snapshot across ALL FOUR domains, driving each through the REAL *_update RPC first to capture a
-- genuine audit row:
--   1  LOCATION  — update moves the row+anchor, revert restores all 11 fields; the moved anchor is
--                  RETIRED + a new active anchor re-inserted at the reverted coords; get_world_map returns
--                  the reverted coords; a NEW audit row records before=pre-revert / after=reverted.
--   2  MINING    — revert restores coords AND the server-only reward_bundle_json (from the RAW snapshot).
--   3  EXPLORATION — same as mining over exploration_sites.
--   4  ZONE      — revert restores the boundary geometry (ST_Equals to the pre-update boundary), name, attach.
--   5  non-owner (not_authorized) + anon (not_authenticated) rejected, zero side effects, anon no grant.
--   6  idempotent replay (same request_id → replayed, exactly one audit row, no double apply).
--   7  intentional-overwrite: a live row changed AFTER the update still reverts to before_snapshot
--      (revert is NOT optimistic-concurrency-guarded — it overwrites current with historical).
--   8  not_revertable (a create audit) + not_found (a bogus audit id).
--   9  source_missing (the audited live row was deleted).
--   10 the 0239 pirate-zone lockdown is intact.
--
-- Self-rolling-back: everything runs inside one begin;...rollback; — ZERO persisted state, no flag
-- flipped, no world row kept. The owner it "seeds" is a synthetic auth.users row created HERE (the real
-- byeharu owner does not exist in a disposable DB). NEVER point this at production.

\set ON_ERROR_STOP on

begin;

-- ── fixtures: a synthetic OWNER + a synthetic NON-OWNER; an ACTIVE zone under an ACTIVE sector; an
--    active HOSTILE attach target for the zone revert. ─────────────────────────────────────────────
create temp table revids(k text primary key, v uuid) on commit drop;
insert into revids values ('owner', gen_random_uuid()), ('nonowner', gen_random_uuid());

insert into auth.users
  (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
   confirmation_token,recovery_token,email_change_token_new,email_change)
select '00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated',
       'revert.'||k||'.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','',''
from revids;

insert into public.app_owners(user_id) select v from revids where k = 'owner';

create temp table revfix(k text primary key, v uuid) on commit drop;
do $$
declare v_zone uuid; v_hostile uuid;
begin
  -- an ACTIVE zone whose sector is ACTIVE (so a created active location renders in get_world_map).
  select z.id into v_zone
    from public.zones z join public.sectors se on se.id = z.sector_id
   where z.status = 'active' and se.status = 'active'
   order by z.name limit 1;
  if v_zone is null then
    raise exception 'REVERT PROOF SETUP FAIL: the seeded chain has no active zone under an active sector';
  end if;
  insert into revfix values ('zone', v_zone);
  -- an active HOSTILE site (the legal attach target for the zone revert's location_id).
  insert into public.locations
      (zone_id, name, location_type, activity_type, x, y, reward_tier, base_difficulty,
       min_power_required, is_public, territory_radius, status)
    values
      (v_zone, 'Revert Proof Den', 'pirate_den', 'hunt_pirates', 1200, 1200, 1, 1, 0, true, null, 'active')
    returning id into v_hostile;
  insert into revfix values ('hostile', v_hostile);
end $$;

-- ══════════════ PROOF 1 — LOCATION revert restores all 11 fields + the anchor + get_world_map ══════════════
do $$
declare v_owner uuid; v_zone uuid; v_locid uuid; v_auditid uuid; r jsonb;
        v_row record; v_anchor_post uuid; v_active_cnt int; v_read jsonb; v_before jsonb; v_after jsonb;
begin
  select v into v_owner from revids where k = 'owner';
  select v into v_zone  from revfix where k = 'zone';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  -- create the origin location via the REAL RPC (it also writes the active anchor).
  r := public.location_create('rev-loc-seed', jsonb_build_object('fields', jsonb_build_object(
         'zone_id', v_zone::text, 'name','Rev Loc Origin','location_type','safe_zone','activity_type','none',
         'x',100,'y',200,'reward_tier',1,'base_difficulty',0,'min_power_required',0,
         'is_public',true,'territory_radius',null,'status','active')));
  if (r->>'ok')::boolean is not true then raise exception 'REVERT PROOF FAIL: loc create not ok: %', r; end if;
  v_locid := (r->'result'->>'id')::uuid;

  -- UPDATE it via the REAL RPC: move coords (100,200)->(500,600) + rename + retype. Anchor is relocated.
  r := public.location_update('rev-loc-upd', jsonb_build_object(
         'target_id', v_locid::text,
         'expected', jsonb_build_object('name','Rev Loc Origin','location_type','safe_zone','activity_type','none',
           'x',100,'y',200,'reward_tier',1,'base_difficulty',0,'min_power_required',0,
           'is_public',true,'territory_radius',null,'status','active'),
         'fields', jsonb_build_object('name','Rev Loc Edited','location_type','rally_point','activity_type','rally',
           'x',500,'y',600,'reward_tier',4,'base_difficulty',3,'min_power_required',9,
           'is_public',false,'territory_radius',77,'status','active')));
  if (r->>'ok')::boolean is not true then raise exception 'REVERT PROOF FAIL: loc update not ok: %', r; end if;
  select id into v_auditid from public.world_editor_audit where request_id = 'rev-loc-upd';

  -- capture the post-update ACTIVE anchor (must be RETIRED by the revert).
  select id into v_anchor_post from public.space_anchors
    where location_id = v_locid and kind = 'location' and status = 'active';

  -- REVERT.
  r := public.world_editor_revert('rev-loc-revert', v_auditid);
  if (r->>'ok')::boolean is not true or (r->>'command_type') <> 'location_update'
     or (r->'result'->>'reverted') <> 'true' then
    raise exception 'REVERT PROOF FAIL: location revert not ok: %', r;
  end if;

  -- the live row is restored EXACTLY to the pre-update state (all 11 fields).
  select * into v_row from public.locations where id = v_locid;
  if v_row.name <> 'Rev Loc Origin' or v_row.location_type <> 'safe_zone' or v_row.activity_type <> 'none'
     or v_row.x <> 100 or v_row.y <> 200 or v_row.reward_tier <> 1 or v_row.base_difficulty <> 0
     or v_row.min_power_required <> 0 or v_row.is_public is not true
     or v_row.territory_radius is not null or v_row.status <> 'active' then
    raise exception 'REVERT PROOF FAIL: location not fully restored (%, %, %, %, %, %, %)',
      v_row.name, v_row.location_type, v_row.x, v_row.y, v_row.reward_tier, v_row.is_public, v_row.territory_radius;
  end if;

  -- ANCHOR: the post-update anchor is now RETIRED; exactly one ACTIVE anchor at the reverted (100,200).
  if (select status from public.space_anchors where id = v_anchor_post) <> 'retired' then
    raise exception 'REVERT PROOF FAIL: the post-update anchor was not retired by the revert';
  end if;
  select count(*) into v_active_cnt from public.space_anchors
    where location_id = v_locid and kind = 'location' and status = 'active';
  if v_active_cnt <> 1 then
    raise exception 'REVERT PROOF FAIL: expected exactly one active anchor after revert, found %', v_active_cnt;
  end if;
  if not exists (select 1 from public.space_anchors
                  where location_id = v_locid and kind = 'location' and status = 'active'
                    and space_x = 100 and space_y = 200) then
    raise exception 'REVERT PROOF FAIL: the active anchor is not at the reverted coords (100,200)';
  end if;

  -- get_world_map (fail-closed on the anchor) returns the reverted coords.
  v_read := public.get_world_map();
  if not exists (
    select 1 from jsonb_array_elements(v_read->'sectors') s,
                  jsonb_array_elements(s->'zones') z,
                  jsonb_array_elements(z->'locations') loc
     where (loc->>'id')::uuid = v_locid
       and (loc->>'x')::numeric = 100 and (loc->>'y')::numeric = 200) then
    raise exception 'REVERT PROOF FAIL: get_world_map does not show the reverted location at (100,200)';
  end if;

  -- a NEW audit row: before = pre-revert live (x 500), after = reverted (x 100), command_type location_update.
  select before_snapshot, after_snapshot into v_before, v_after
    from public.world_editor_audit where request_id = 'rev-loc-revert';
  if v_before is null or (v_before->>'x')::numeric <> 500 or (v_before->>'name') <> 'Rev Loc Edited' then
    raise exception 'REVERT PROOF FAIL: revert audit before_snapshot is not the pre-revert live: %', v_before;
  end if;
  if v_after is null or (v_after->>'x')::numeric <> 100 or (v_after->>'name') <> 'Rev Loc Origin' then
    raise exception 'REVERT PROOF FAIL: revert audit after_snapshot is not the reverted values: %', v_after;
  end if;
  if (select command_type from public.world_editor_audit where request_id = 'rev-loc-revert') <> 'location_update' then
    raise exception 'REVERT PROOF FAIL: revert audit command_type is not location_update';
  end if;
  raise notice 'REVERT_PASS_LOCATION';
end $$;

-- ══════════════ PROOF 2 — MINING revert restores coords + the server-only reward_bundle_json ══════════════
do $$
declare v_owner uuid; v_id uuid; v_auditid uuid; r jsonb; v_row record; v_before jsonb; v_after jsonb;
begin
  select v into v_owner from revids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  r := public.mining_field_create('rev-min-seed', jsonb_build_object('fields', jsonb_build_object(
         'name','Rev Mine Origin','space_x',10,'space_y',20,
         'reward_bundle_json', jsonb_build_object('items', jsonb_build_array(
           jsonb_build_object('item_id','ore_common','quantity',5))))));
  if (r->>'ok')::boolean is not true then raise exception 'REVERT PROOF FAIL: mining create not ok: %', r; end if;
  v_id := (r->'result'->>'id')::uuid;

  -- update coords + a DIFFERENT bundle (mining_field_update addresses by current name).
  r := public.mining_field_update('rev-min-upd', jsonb_build_object(
         'target_id','Rev Mine Origin',
         'expected', jsonb_build_object('name','Rev Mine Origin','space_x',10,'space_y',20),
         'fields', jsonb_build_object('name','Rev Mine Origin','space_x',99,'space_y',88,
           'reward_bundle_json', jsonb_build_object('items', jsonb_build_array(
             jsonb_build_object('item_id','gem_rare','quantity',3))))));
  if (r->>'ok')::boolean is not true then raise exception 'REVERT PROOF FAIL: mining update not ok: %', r; end if;
  select id into v_auditid from public.world_editor_audit where request_id = 'rev-min-upd';

  r := public.world_editor_revert('rev-min-revert', v_auditid);
  if (r->>'ok')::boolean is not true or (r->>'command_type') <> 'mining_field_update' then
    raise exception 'REVERT PROOF FAIL: mining revert not ok: %', r;
  end if;

  select * into v_row from public.mining_fields where id = v_id;
  if v_row.space_x <> 10 or v_row.space_y <> 20 then
    raise exception 'REVERT PROOF FAIL: mining coords not restored (%, %)', v_row.space_x, v_row.space_y;
  end if;
  if (v_row.reward_bundle_json->'items'->0->>'item_id') <> 'ore_common'
     or (v_row.reward_bundle_json->'items'->0->>'quantity') <> '5' then
    raise exception 'REVERT PROOF FAIL: the server-only reward_bundle_json was not restored: %', v_row.reward_bundle_json;
  end if;

  select before_snapshot, after_snapshot into v_before, v_after
    from public.world_editor_audit where request_id = 'rev-min-revert';
  if (v_before->>'space_x')::numeric <> 99 or (v_before->'reward_bundle_json'->'items'->0->>'item_id') <> 'gem_rare' then
    raise exception 'REVERT PROOF FAIL: mining revert before_snapshot not the pre-revert live: %', v_before;
  end if;
  if (v_after->>'space_x')::numeric <> 10 or (v_after->'reward_bundle_json'->'items'->0->>'item_id') <> 'ore_common' then
    raise exception 'REVERT PROOF FAIL: mining revert after_snapshot not the reverted values: %', v_after;
  end if;
  raise notice 'REVERT_PASS_MINING';
end $$;

-- ══════════════ PROOF 3 — EXPLORATION revert restores coords + reward_bundle_json ══════════════
do $$
declare v_owner uuid; v_id uuid; v_auditid uuid; r jsonb; v_row record;
begin
  select v into v_owner from revids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  r := public.exploration_site_create('rev-exp-seed', jsonb_build_object('fields', jsonb_build_object(
         'name','Rev Site Origin','space_x',-30,'space_y',-40,
         'reward_bundle_json', jsonb_build_object('items', jsonb_build_array(
           jsonb_build_object('item_id','relic_alpha','quantity',2))))));
  if (r->>'ok')::boolean is not true then raise exception 'REVERT PROOF FAIL: expl create not ok: %', r; end if;
  v_id := (r->'result'->>'id')::uuid;

  r := public.exploration_site_update('rev-exp-upd', jsonb_build_object(
         'target_id','Rev Site Origin',
         'expected', jsonb_build_object('name','Rev Site Origin','space_x',-30,'space_y',-40),
         'fields', jsonb_build_object('name','Rev Site Origin','space_x',-300,'space_y',-400,
           'reward_bundle_json', jsonb_build_object('items', jsonb_build_array(
             jsonb_build_object('item_id','relic_omega','quantity',9))))));
  if (r->>'ok')::boolean is not true then raise exception 'REVERT PROOF FAIL: expl update not ok: %', r; end if;
  select id into v_auditid from public.world_editor_audit where request_id = 'rev-exp-upd';

  r := public.world_editor_revert('rev-exp-revert', v_auditid);
  if (r->>'ok')::boolean is not true or (r->>'command_type') <> 'exploration_site_update' then
    raise exception 'REVERT PROOF FAIL: expl revert not ok: %', r;
  end if;

  select * into v_row from public.exploration_sites where id = v_id;
  if v_row.space_x <> -30 or v_row.space_y <> -40
     or (v_row.reward_bundle_json->'items'->0->>'item_id') <> 'relic_alpha'
     or (v_row.reward_bundle_json->'items'->0->>'quantity') <> '2' then
    raise exception 'REVERT PROOF FAIL: exploration not fully restored (%, %, %)',
      v_row.space_x, v_row.space_y, v_row.reward_bundle_json;
  end if;
  raise notice 'REVERT_PASS_EXPLORATION';
end $$;

-- ══════════════ PROOF 4 — ZONE revert restores boundary geometry (ST_Equals), name, attach ══════════════
do $$
declare v_owner uuid; v_hostile uuid; v_id uuid; v_auditid uuid; r jsonb;
        v_orig public.geometry; v_row record; v_before jsonb; v_after jsonb;
begin
  select v into v_owner   from revids where k = 'owner';
  select v into v_hostile from revfix where k = 'hostile';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  -- a DRAWN square with INTEGER vertices (WKT round-trips EXACTLY → ST_Equals is deterministic).
  r := public.zone_create('rev-zone-seed', jsonb_build_object('fields', jsonb_build_object(
         'name','Rev Zone Origin','zone_kind','pirate','attach_location_id', null,
         'geometry', jsonb_build_object('kind','polygon','vertices', jsonb_build_array(
           jsonb_build_object('x',0,'y',0), jsonb_build_object('x',300,'y',0),
           jsonb_build_object('x',300,'y',300), jsonb_build_object('x',0,'y',300))))));
  if (r->>'ok')::boolean is not true then raise exception 'REVERT PROOF FAIL: zone create not ok: %', r; end if;
  v_id := (r->'result'->>'id')::uuid;
  select boundary into v_orig from public.danger_zones where id = v_id;   -- the pre-update square

  -- EDIT to a NEW circle + rename + attach to the hostile site.
  r := public.zone_update('rev-zone-upd', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object('name','Rev Zone Origin','zone_kind','pirate','attach_location_id', null,
           'geometry', jsonb_build_object('kind','polygon','vertices', jsonb_build_array(
             jsonb_build_object('x',0,'y',0), jsonb_build_object('x',300,'y',0),
             jsonb_build_object('x',300,'y',300), jsonb_build_object('x',0,'y',300)))),
         'fields', jsonb_build_object('name','Rev Zone Edited','attach_location_id', v_hostile::text,
           'geometry', jsonb_build_object('kind','circle','center', jsonb_build_object('x',1000,'y',1000),'radius',200))));
  if (r->>'ok')::boolean is not true then raise exception 'REVERT PROOF FAIL: zone update not ok: %', r; end if;
  select id into v_auditid from public.world_editor_audit where request_id = 'rev-zone-upd';

  r := public.world_editor_revert('rev-zone-revert', v_auditid);
  if (r->>'ok')::boolean is not true or (r->>'command_type') <> 'zone_update' then
    raise exception 'REVERT PROOF FAIL: zone revert not ok: %', r;
  end if;

  select * into v_row from public.danger_zones where id = v_id;
  if v_row.name <> 'Rev Zone Origin' or v_row.source <> 'drawn' or v_row.location_id is not null then
    raise exception 'REVERT PROOF FAIL: zone name/source/attach not restored (%, %, %)',
      v_row.name, v_row.source, v_row.location_id;
  end if;
  if not ST_Equals(v_row.boundary, v_orig) then
    raise exception 'REVERT PROOF FAIL: the zone boundary was not restored to the pre-update square (ST_Equals false)';
  end if;

  select before_snapshot, after_snapshot into v_before, v_after
    from public.world_editor_audit where request_id = 'rev-zone-revert';
  -- before = the pre-revert circle; after = the restored square.
  if (v_before->>'name') <> 'Rev Zone Edited' or (v_after->>'name') <> 'Rev Zone Origin' then
    raise exception 'REVERT PROOF FAIL: zone revert snapshots wrong (before %, after %)', v_before->>'name', v_after->>'name';
  end if;
  if (v_before->>'boundary_wkt') = (v_after->>'boundary_wkt') then
    raise exception 'REVERT PROOF FAIL: zone revert did not change the boundary snapshot';
  end if;
  raise notice 'REVERT_PASS_ZONE';
end $$;

-- ══════════════ PROOF 5 — non-owner (not_authorized) + anon (not_authenticated) rejected ══════════════
do $$
declare v_no uuid; v_auditid uuid; r jsonb; n int;
begin
  select v into v_no from revids where k = 'nonowner';
  select id into v_auditid from public.world_editor_audit where request_id = 'rev-loc-upd';

  perform set_config('request.jwt.claims', json_build_object('sub', v_no::text, 'role','authenticated')::text, true);
  r := public.world_editor_revert('rev-nonowner-1', v_auditid);
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authorized' then
    raise exception 'REVERT PROOF FAIL: non-owner not rejected as not_authorized: %', r;
  end if;

  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  r := public.world_editor_revert('rev-anon-1', v_auditid);
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authenticated' then
    raise exception 'REVERT PROOF FAIL: anon not rejected as not_authenticated: %', r;
  end if;
  if has_function_privilege('anon', 'public.world_editor_revert(text,uuid)', 'execute') then
    raise exception 'REVERT PROOF FAIL: anon holds EXECUTE on world_editor_revert — must be authenticated-only';
  end if;

  select count(*) into n from public.world_editor_audit where request_id in ('rev-nonowner-1','rev-anon-1');
  if n <> 0 then raise exception 'REVERT PROOF FAIL: a rejected revert wrote % audit row(s)', n; end if;
  raise notice 'REVERT_PASS_REJECTIONS';
end $$;

-- ══════════════ PROOF 6 — idempotent replay (same request_id → replayed, one audit row, no double apply) ══════════════
do $$
declare v_owner uuid; v_zone uuid; v_locid uuid; v_auditid uuid; r1 jsonb; r2 jsonb; n int; v_row record;
begin
  select v into v_owner from revids where k = 'owner';
  select v into v_zone  from revfix where k = 'zone';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  r1 := public.location_create('rev-idem-seed', jsonb_build_object('fields', jsonb_build_object(
          'zone_id', v_zone::text, 'name','Rev Idem Origin','location_type','safe_zone','activity_type','none',
          'x',10,'y',10,'reward_tier',1,'base_difficulty',0,'min_power_required',0,
          'is_public',true,'territory_radius',null,'status','active')));
  v_locid := (r1->'result'->>'id')::uuid;
  r1 := public.location_update('rev-idem-upd', jsonb_build_object(
          'target_id', v_locid::text,
          'expected', jsonb_build_object('name','Rev Idem Origin','location_type','safe_zone','activity_type','none',
            'x',10,'y',10,'reward_tier',1,'base_difficulty',0,'min_power_required',0,
            'is_public',true,'territory_radius',null,'status','active'),
          'fields', jsonb_build_object('name','Rev Idem Edited','location_type','safe_zone','activity_type','none',
            'x',20,'y',20,'reward_tier',1,'base_difficulty',0,'min_power_required',0,
            'is_public',true,'territory_radius',null,'status','active')));
  select id into v_auditid from public.world_editor_audit where request_id = 'rev-idem-upd';

  r1 := public.world_editor_revert('rev-idem-revert', v_auditid);
  r2 := public.world_editor_revert('rev-idem-revert', v_auditid);   -- same request_id → replay
  if (r1->>'ok')::boolean is not true then raise exception 'REVERT PROOF FAIL: first revert not ok: %', r1; end if;
  if (r2->>'ok')::boolean is not true or (r2->>'replayed')::boolean is not true or (r2->>'code') <> 'duplicate_request' then
    raise exception 'REVERT PROOF FAIL: second revert was not an idempotent replay: %', r2;
  end if;
  if (r2->'result') <> (r1->'result') then
    raise exception 'REVERT PROOF FAIL: replay result differs from the original';
  end if;
  select * into v_row from public.locations where id = v_locid;
  if v_row.x <> 10 then raise exception 'REVERT PROOF FAIL: replay re-applied / wrong live x = %', v_row.x; end if;
  select count(*) into n from public.world_editor_audit where request_id = 'rev-idem-revert';
  if n <> 1 then raise exception 'REVERT PROOF FAIL: idempotent revert produced % audit rows (expected 1)', n; end if;
  raise notice 'REVERT_PASS_IDEMPOTENT';
end $$;

-- ══════════════ PROOF 7 — intentional overwrite: a row changed AFTER the update still reverts to before ══════════════
-- Documents the semantic: revert is NOT optimistic-concurrency-guarded; it overwrites current with the
-- historical before_snapshot regardless of intervening changes (guarded only by owner + existence).
do $$
declare v_owner uuid; v_zone uuid; v_locid uuid; v_auditid uuid; r jsonb; v_row record;
begin
  select v into v_owner from revids where k = 'owner';
  select v into v_zone  from revfix where k = 'zone';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  r := public.location_create('rev-ow-seed', jsonb_build_object('fields', jsonb_build_object(
         'zone_id', v_zone::text, 'name','Rev OW Origin','location_type','safe_zone','activity_type','none',
         'x',111,'y',222,'reward_tier',1,'base_difficulty',0,'min_power_required',0,
         'is_public',true,'territory_radius',null,'status','active')));
  v_locid := (r->'result'->>'id')::uuid;   -- P0 = (111,222)
  r := public.location_update('rev-ow-upd', jsonb_build_object(
         'target_id', v_locid::text,
         'expected', jsonb_build_object('name','Rev OW Origin','location_type','safe_zone','activity_type','none',
           'x',111,'y',222,'reward_tier',1,'base_difficulty',0,'min_power_required',0,
           'is_public',true,'territory_radius',null,'status','active'),
         'fields', jsonb_build_object('name','Rev OW Edited','location_type','safe_zone','activity_type','none',
           'x',333,'y',444,'reward_tier',1,'base_difficulty',0,'min_power_required',0,
           'is_public',true,'territory_radius',null,'status','active')));   -- P1 = (333,444)
  select id into v_auditid from public.world_editor_audit where request_id = 'rev-ow-upd';

  -- a THIRD concurrent change (superuser) drifts the live row to P2 = (777,888) AFTER the audited update.
  update public.locations set x = 777, y = 888, name = 'Rev OW Drifted' where id = v_locid;

  -- revert using the audit whose before_snapshot is P0 — it overwrites P2 back to P0 regardless of drift.
  r := public.world_editor_revert('rev-ow-revert', v_auditid);
  if (r->>'ok')::boolean is not true then raise exception 'REVERT PROOF FAIL: overwrite revert not ok: %', r; end if;
  select * into v_row from public.locations where id = v_locid;
  if v_row.x <> 111 or v_row.y <> 222 or v_row.name <> 'Rev OW Origin' then
    raise exception 'REVERT PROOF FAIL: revert did not overwrite the drifted row back to before_snapshot (%, %, %)',
      v_row.x, v_row.y, v_row.name;
  end if;
  raise notice 'REVERT_PASS_INTENTIONAL_OVERWRITE';
end $$;

-- ══════════════ PROOF 8 — not_revertable (a create audit) + not_found (a bogus audit id) ══════════════
do $$
declare v_owner uuid; v_zone uuid; v_createaudit uuid; r jsonb; n int;
begin
  select v into v_owner from revids where k = 'owner';
  select v into v_zone  from revfix where k = 'zone';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  r := public.location_create('rev-notrev-seed', jsonb_build_object('fields', jsonb_build_object(
         'zone_id', v_zone::text, 'name','Rev NotRev','location_type','safe_zone','activity_type','none',
         'x',5,'y',5,'reward_tier',1,'base_difficulty',0,'min_power_required',0,
         'is_public',true,'territory_radius',null,'status','active')));
  select id into v_createaudit from public.world_editor_audit where request_id = 'rev-notrev-seed';

  r := public.world_editor_revert('rev-notrev-1', v_createaudit);
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_revertable'
     or (r->'details'->0->>'code') <> 'not_revertable' then
    raise exception 'REVERT PROOF FAIL: a create audit was not typed not_revertable: %', r;
  end if;

  r := public.world_editor_revert('rev-notfound-1', gen_random_uuid());
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_found'
     or (r->'details'->0->>'code') <> 'audit_not_found' then
    raise exception 'REVERT PROOF FAIL: a bogus audit id was not typed not_found/audit_not_found: %', r;
  end if;

  select count(*) into n from public.world_editor_audit where request_id in ('rev-notrev-1','rev-notfound-1');
  if n <> 0 then raise exception 'REVERT PROOF FAIL: a not_revertable/not_found call wrote % audit row(s)', n; end if;
  raise notice 'REVERT_PASS_NOT_REVERTABLE';
end $$;

-- ══════════════ PROOF 9 — source_missing when the audited live row was deleted ══════════════
do $$
declare v_owner uuid; v_id uuid; v_auditid uuid; r jsonb; n int;
begin
  select v into v_owner from revids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  r := public.mining_field_create('rev-miss-seed', jsonb_build_object('fields', jsonb_build_object(
         'name','Rev Miss Origin','space_x',1,'space_y',1,
         'reward_bundle_json', jsonb_build_object('items', jsonb_build_array(
           jsonb_build_object('item_id','ore_common','quantity',1))))));
  v_id := (r->'result'->>'id')::uuid;
  r := public.mining_field_update('rev-miss-upd', jsonb_build_object(
         'target_id','Rev Miss Origin',
         'expected', jsonb_build_object('name','Rev Miss Origin','space_x',1,'space_y',1),
         'fields', jsonb_build_object('name','Rev Miss Origin','space_x',2,'space_y',2)));
  select id into v_auditid from public.world_editor_audit where request_id = 'rev-miss-upd';

  -- the audited live row vanishes (superuser delete).
  delete from public.mining_fields where id = v_id;

  r := public.world_editor_revert('rev-miss-revert', v_auditid);
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'source_missing'
     or (r->'details'->0->>'code') <> 'source_missing' then
    raise exception 'REVERT PROOF FAIL: a vanished live row was not typed source_missing: %', r;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'rev-miss-revert';
  if n <> 0 then raise exception 'REVERT PROOF FAIL: a source_missing revert wrote % audit row(s)', n; end if;
  raise notice 'REVERT_PASS_SOURCE_MISSING';
end $$;

-- ══════════════ PROOF 10 — the 0239 pirate-zone lockdown is INTACT ══════════════
do $$
begin
  if has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_zone_delete(uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'REVERT PROOF FAIL: a client role regained EXECUTE on a pirate_zone write RPC — 0239 lockdown regressed';
  end if;
  if not has_function_privilege('service_role', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or not has_function_privilege('service_role', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'REVERT PROOF FAIL: service_role LOST execute on a pirate_zone RPC — the 0239 owner-tooling path regressed';
  end if;
  raise notice 'REVERT_PASS_PIRATE_ZONE_LOCKDOWN_INTACT';
end $$;

do $$ begin raise notice 'WORLD-EDITOR UNIFIED REVERT PROOF PASSED'; end $$;

rollback;   -- leave ZERO persisted state.
