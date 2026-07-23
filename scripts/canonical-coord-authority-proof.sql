-- CANONICAL COORD AUTHORITY — disposable apply-proof (run against a THROWAWAY local Supabase ONLY).
--
-- Proves migration 0265 (20260618000265_canonical_coord_validation_authority.sql) after the FULL chain is
-- applied by `supabase start`: the ±10000 point-coordinate-frame invariant now lives in ONE authority
-- (public.canonical_coord_violation) and the SIX owner-gated point-coord-write RPCs route through it —
-- BEHAVIOR-PRESERVING (byte-identical validation envelopes):
--   0. MIGRATION ORDER — 0265 is the applied head, sitting after prod head 0264.
--   1. MIGRATION INERT — 0265 modified no data row: it ran no editor command (audit ledger empty) and every
--      active location still has exactly one active anchor == its (x,y) (the 0264 invariant is undisturbed,
--      so no stored coordinate moved).
--   2. AUTHORITY IDENTITY — canonical_coord_violation reproduces, BYTE-FOR-BYTE, the exact {code,field,message}
--      details the deployed inline ±10000 checks emit — verified against a matrix of GROUND-TRUTH literals
--      copied verbatim from the 0244/0246/0247/0248/0249/0252 definitions (both field vocabularies: x/y and
--      space_x/space_y; the inclusive boundary; both codes; x-then-y ordering).
--   3..8. PER-RPC ENVELOPE — each of the six RPCs, driven with bad coordinates, returns the EXACT typed
--      validation_failed envelope it returned pre-0265 (same error, same details bytes), AND a valid coordinate
--      still writes the row (+ for locations, the space_anchor — 0264 behavior intact; a coordinate update still
--      retires+inserts the anchor). Detail ORDERING relative to other fields is preserved.
--
-- Self-rolling-back: everything runs inside one begin;...rollback; — ZERO persisted state, no world row kept.
-- The owner it "seeds" is a synthetic auth.users row created HERE. NEVER point this at production.

\set ON_ERROR_STOP on

begin;

-- ── PROOF 0 — MIGRATION ORDER: 0265 applied after prod head 0264 (and is the greatest version) ─────────────
do $$
declare v_head text; v_has264 bool; v_has265 bool;
begin
  select exists(select 1 from supabase_migrations.schema_migrations where version = '20260618000264') into v_has264;
  select exists(select 1 from supabase_migrations.schema_migrations where version = '20260618000265') into v_has265;
  select max(version) into v_head from supabase_migrations.schema_migrations;
  if not v_has264 then raise exception 'CANON PROOF FAIL: prod head 0264 is not in the applied chain'; end if;
  if not v_has265 then raise exception 'CANON PROOF FAIL: 0265 is not in the applied chain'; end if;
  if v_head <> '20260618000265' then
    raise exception 'CANON PROOF FAIL: applied head is % — 0265 must be the greatest version (after 0264)', v_head;
  end if;
  raise notice 'CANON_PASS_MIGRATION_ORDER (head=%, 0264/0265 present)', v_head;
end $$;

-- ── PROOF 1 — MIGRATION INERT: 0265 wrote no data row (empty audit ledger; 0264 anchor invariant intact) ────
do $$
declare v_locs int; v_anchors int; v_audit int; v_drift int;
begin
  select count(*) into v_locs    from public.locations;
  select count(*) into v_anchors from public.space_anchors where kind = 'location' and status = 'active';
  select count(*) into v_audit   from public.world_editor_audit;
  if v_locs = 0 then
    raise exception 'CANON PROOF FAIL: no locations — the invariants would be vacuous';
  end if;
  if v_audit <> 0 then
    raise exception 'CANON PROOF FAIL: world_editor_audit has % row(s) on a fresh chain — 0265 wrote an editor row', v_audit;
  end if;
  if v_anchors <> v_locs then
    raise exception 'CANON PROOF FAIL: % active location anchor(s) for % location(s) — 0265 disturbed the anchor set', v_anchors, v_locs;
  end if;
  select count(*) into v_drift
    from public.space_anchors a join public.locations l on l.id = a.location_id
   where a.kind = 'location' and a.status = 'active'
     and (a.space_x is distinct from l.x or a.space_y is distinct from l.y);
  if v_drift <> 0 then
    raise exception 'CANON PROOF FAIL: % anchor(s) differ from their location (x,y) — 0265 moved a coordinate', v_drift;
  end if;
  raise notice 'CANON_PASS_MIGRATION_INERT (% locations, % active anchors, 0 audit, 0 coord drift)', v_locs, v_anchors;
end $$;

-- ── PROOF 2 — AUTHORITY IDENTITY: canonical_coord_violation == the deployed inline ±10000 emit, byte-for-byte.
--    The `expected` literals below are copied VERBATIM from the deployed 0244/0246/0247/0248/0249/0252 inline
--    coordinate checks (the pre-0265 ground truth). Matrix: valid, inclusive boundary, both codes, both field
--    vocabularies (x/y and space_x/space_y), x-then-y ordering. ────────────────────────────────────────────
do $$
declare f jsonb;
begin
  -- valid mid-range ⇒ [] (both vocabularies)
  if public.canonical_coord_violation('5'::jsonb,'-5'::jsonb,'x','y') <> '[]'::jsonb then
    raise exception 'CANON PROOF FAIL: valid (5,-5) x/y not []'; end if;
  if public.canonical_coord_violation('5'::jsonb,'-5'::jsonb,'space_x','space_y') <> '[]'::jsonb then
    raise exception 'CANON PROOF FAIL: valid (5,-5) space not []'; end if;

  -- inclusive ±10000 boundary ⇒ [] (both directions)
  if public.canonical_coord_violation('10000'::jsonb,'-10000'::jsonb,'x','y') <> '[]'::jsonb then
    raise exception 'CANON PROOF FAIL: boundary (10000,-10000) not []'; end if;
  if public.canonical_coord_violation('-10000'::jsonb,'10000'::jsonb,'space_x','space_y') <> '[]'::jsonb then
    raise exception 'CANON PROOF FAIL: boundary (-10000,10000) not []'; end if;

  -- x just over the bound ⇒ coord_out_of_bounds x, exact bytes (locations vocabulary)
  f := public.canonical_coord_violation('10001'::jsonb,'5'::jsonb,'x','y');
  if f <> '[{"code":"coord_out_of_bounds","field":"x","message":"x must be within ±10000."}]'::jsonb then
    raise exception 'CANON PROOF FAIL: x=10001 -> %', f; end if;
  -- x just under ⇒ coord_out_of_bounds x
  f := public.canonical_coord_violation('-10001'::jsonb,'5'::jsonb,'x','y');
  if f <> '[{"code":"coord_out_of_bounds","field":"x","message":"x must be within ±10000."}]'::jsonb then
    raise exception 'CANON PROOF FAIL: x=-10001 -> %', f; end if;
  -- y over ⇒ coord_out_of_bounds y (mining/exploration vocabulary)
  f := public.canonical_coord_violation('5'::jsonb,'10001'::jsonb,'space_x','space_y');
  if f <> '[{"code":"coord_out_of_bounds","field":"space_y","message":"space_y must be within ±10000."}]'::jsonb then
    raise exception 'CANON PROOF FAIL: space_y=10001 -> %', f; end if;

  -- non-number ⇒ numeric_not_finite, exact bytes (string, jsonb-null, and absent all take this branch)
  f := public.canonical_coord_violation('"z"'::jsonb,'5'::jsonb,'x','y');
  if f <> '[{"code":"numeric_not_finite","field":"x","message":"x must be a finite number."}]'::jsonb then
    raise exception 'CANON PROOF FAIL: x="z" -> %', f; end if;
  f := public.canonical_coord_violation('null'::jsonb,'5'::jsonb,'space_x','space_y');
  if f <> '[{"code":"numeric_not_finite","field":"space_x","message":"space_x must be a finite number."}]'::jsonb then
    raise exception 'CANON PROOF FAIL: space_x=json-null -> %', f; end if;
  f := public.canonical_coord_violation(null::jsonb,'5'::jsonb,'x','y');
  if f <> '[{"code":"numeric_not_finite","field":"x","message":"x must be a finite number."}]'::jsonb then
    raise exception 'CANON PROOF FAIL: x=absent(sql-null) -> %', f; end if;

  -- BOTH bad ⇒ x detail FIRST, then y (ordering preserved); mixed codes
  f := public.canonical_coord_violation('"z"'::jsonb,'null'::jsonb,'x','y');
  if f <> '[{"code":"numeric_not_finite","field":"x","message":"x must be a finite number."},{"code":"numeric_not_finite","field":"y","message":"y must be a finite number."}]'::jsonb then
    raise exception 'CANON PROOF FAIL: both non-number -> %', f; end if;
  f := public.canonical_coord_violation('10001'::jsonb,'"z"'::jsonb,'space_x','space_y');
  if f <> '[{"code":"coord_out_of_bounds","field":"space_x","message":"space_x must be within ±10000."},{"code":"numeric_not_finite","field":"space_y","message":"space_y must be a finite number."}]'::jsonb then
    raise exception 'CANON PROOF FAIL: oob x + nnf y -> %', f; end if;

  raise notice 'CANON_PASS_AUTHORITY_IDENTITY (helper == deployed inline emit, byte-for-byte, both vocabularies, x-then-y)';
end $$;

-- ── fixtures: a synthetic OWNER + one active zone to create locations into ─────────────────────────────────
create temp table canon_owner(k text primary key, v uuid) on commit drop;
insert into canon_owner values ('owner', gen_random_uuid());
insert into auth.users
  (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
   confirmation_token,recovery_token,email_change_token_new,email_change)
select '00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated',
       'canon.owner.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','',''
from canon_owner;
insert into public.app_owners(user_id) select v from canon_owner;

create temp table canon_zone(k text primary key, v uuid) on commit drop;
do $$
declare v_zone uuid;
begin
  select z.id into v_zone
    from public.zones z join public.sectors se on se.id = z.sector_id
   where z.status = 'active' and se.status = 'active'
   order by z.name limit 1;
  if v_zone is null then
    raise exception 'CANON PROOF SETUP FAIL: no active zone under an active sector';
  end if;
  insert into canon_zone values ('zone', v_zone);
end $$;

-- ── PROOF 3 — exploration_site_create: bad coords ⇒ EXACT envelope; valid coords write the row ─────────────
do $$
declare v_owner uuid; r jsonb; v_row record;
begin
  select v into v_owner from canon_owner where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  -- bad: space_x=10001 (oob), space_y="bad" (not finite); everything else valid ⇒ ONLY the two coord details.
  r := public.exploration_site_create('canon-expl-bad-1', jsonb_build_object('fields', jsonb_build_object(
         'name','Canon Expl Bad','space_x',10001,'space_y','bad',
         'reward_bundle_json', jsonb_build_object('items', jsonb_build_array(jsonb_build_object('item_id','ore','quantity',3))))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed' then
    raise exception 'CANON PROOF FAIL: expl_create bad coords not validation_failed: %', r; end if;
  if (r->'details') <> '[{"code":"coord_out_of_bounds","field":"space_x","message":"space_x must be within ±10000."},{"code":"numeric_not_finite","field":"space_y","message":"space_y must be a finite number."}]'::jsonb then
    raise exception 'CANON PROOF FAIL: expl_create bad-coord details not byte-identical: %', r->'details'; end if;

  -- valid: boundary 10000 / -10000 writes the row at exactly those coords.
  r := public.exploration_site_create('canon-expl-ok-1', jsonb_build_object('fields', jsonb_build_object(
         'name','Canon Expl OK','space_x',10000,'space_y',-10000,
         'reward_bundle_json', jsonb_build_object('items', jsonb_build_array(jsonb_build_object('item_id','ore','quantity',3))))));
  if (r->>'ok')::boolean is not true or (r->'result'->>'created') <> 'true' then
    raise exception 'CANON PROOF FAIL: expl_create valid not ok: %', r; end if;
  select * into v_row from public.exploration_sites where id = (r->'result'->>'id')::uuid;
  if v_row.space_x is distinct from 10000::double precision or v_row.space_y is distinct from (-10000)::double precision then
    raise exception 'CANON PROOF FAIL: expl_create stored coords (%,%) != (10000,-10000)', v_row.space_x, v_row.space_y; end if;
  raise notice 'CANON_PASS_EXPL_CREATE';
end $$;

-- ── PROOF 4 — exploration_site_update: bad coords ⇒ EXACT envelope; valid coords write the row ─────────────
do $$
declare v_owner uuid; r jsonb; v_row record;
begin
  select v into v_owner from canon_owner where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  -- target the row created in PROOF 3 ("Canon Expl OK" at 10000,-10000). expected == live (no drift), so the
  -- stale gate passes and we reach field validation; fields carry the bad coords.
  r := public.exploration_site_update('canon-expl-upd-bad-1', jsonb_build_object(
         'target_id','Canon Expl OK',
         'expected', jsonb_build_object('name','Canon Expl OK','space_x',10000,'space_y',-10000),
         'fields',   jsonb_build_object('name','Canon Expl OK','space_x',10001,'space_y','bad','reward_bundle_json',null)));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed' then
    raise exception 'CANON PROOF FAIL: expl_update bad coords not validation_failed: %', r; end if;
  if (r->'details') <> '[{"code":"coord_out_of_bounds","field":"space_x","message":"space_x must be within ±10000."},{"code":"numeric_not_finite","field":"space_y","message":"space_y must be a finite number."}]'::jsonb then
    raise exception 'CANON PROOF FAIL: expl_update bad-coord details not byte-identical: %', r->'details'; end if;

  -- valid coordinate move writes the row.
  r := public.exploration_site_update('canon-expl-upd-ok-1', jsonb_build_object(
         'target_id','Canon Expl OK',
         'expected', jsonb_build_object('name','Canon Expl OK','space_x',10000,'space_y',-10000),
         'fields',   jsonb_build_object('name','Canon Expl OK','space_x',-777,'space_y',888,'reward_bundle_json',null)));
  if (r->>'ok')::boolean is not true or (r->'result'->>'updated') <> 'true' then
    raise exception 'CANON PROOF FAIL: expl_update valid not ok: %', r; end if;
  select * into v_row from public.exploration_sites where name = 'Canon Expl OK';
  if v_row.space_x is distinct from (-777)::double precision or v_row.space_y is distinct from 888::double precision then
    raise exception 'CANON PROOF FAIL: expl_update stored coords (%,%) != (-777,888)', v_row.space_x, v_row.space_y; end if;
  raise notice 'CANON_PASS_EXPL_UPDATE';
end $$;

-- ── PROOF 5 — mining_field_create: bad coords ⇒ EXACT envelope; valid coords write the row ─────────────────
do $$
declare v_owner uuid; r jsonb; v_row record;
begin
  select v into v_owner from canon_owner where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.mining_field_create('canon-mine-bad-1', jsonb_build_object('fields', jsonb_build_object(
         'name','Canon Mine Bad','space_x',10001,'space_y','bad',
         'reward_bundle_json', jsonb_build_object('items', jsonb_build_array(jsonb_build_object('item_id','ore','quantity',3))))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed' then
    raise exception 'CANON PROOF FAIL: mine_create bad coords not validation_failed: %', r; end if;
  if (r->'details') <> '[{"code":"coord_out_of_bounds","field":"space_x","message":"space_x must be within ±10000."},{"code":"numeric_not_finite","field":"space_y","message":"space_y must be a finite number."}]'::jsonb then
    raise exception 'CANON PROOF FAIL: mine_create bad-coord details not byte-identical: %', r->'details'; end if;

  r := public.mining_field_create('canon-mine-ok-1', jsonb_build_object('fields', jsonb_build_object(
         'name','Canon Mine OK','space_x',-10000,'space_y',10000,
         'reward_bundle_json', jsonb_build_object('items', jsonb_build_array(jsonb_build_object('item_id','ore','quantity',3))))));
  if (r->>'ok')::boolean is not true or (r->'result'->>'created') <> 'true' then
    raise exception 'CANON PROOF FAIL: mine_create valid not ok: %', r; end if;
  select * into v_row from public.mining_fields where id = (r->'result'->>'id')::uuid;
  if v_row.space_x is distinct from (-10000)::double precision or v_row.space_y is distinct from 10000::double precision then
    raise exception 'CANON PROOF FAIL: mine_create stored coords (%,%) != (-10000,10000)', v_row.space_x, v_row.space_y; end if;
  raise notice 'CANON_PASS_MINING_CREATE';
end $$;

-- ── PROOF 6 — mining_field_update: bad coords ⇒ EXACT envelope; valid coords write the row ─────────────────
do $$
declare v_owner uuid; r jsonb; v_row record;
begin
  select v into v_owner from canon_owner where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.mining_field_update('canon-mine-upd-bad-1', jsonb_build_object(
         'target_id','Canon Mine OK',
         'expected', jsonb_build_object('name','Canon Mine OK','space_x',-10000,'space_y',10000),
         'fields',   jsonb_build_object('name','Canon Mine OK','space_x',10001,'space_y','bad','reward_bundle_json',null)));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed' then
    raise exception 'CANON PROOF FAIL: mine_update bad coords not validation_failed: %', r; end if;
  if (r->'details') <> '[{"code":"coord_out_of_bounds","field":"space_x","message":"space_x must be within ±10000."},{"code":"numeric_not_finite","field":"space_y","message":"space_y must be a finite number."}]'::jsonb then
    raise exception 'CANON PROOF FAIL: mine_update bad-coord details not byte-identical: %', r->'details'; end if;

  r := public.mining_field_update('canon-mine-upd-ok-1', jsonb_build_object(
         'target_id','Canon Mine OK',
         'expected', jsonb_build_object('name','Canon Mine OK','space_x',-10000,'space_y',10000),
         'fields',   jsonb_build_object('name','Canon Mine OK','space_x',123,'space_y',-456,'reward_bundle_json',null)));
  if (r->>'ok')::boolean is not true or (r->'result'->>'updated') <> 'true' then
    raise exception 'CANON PROOF FAIL: mine_update valid not ok: %', r; end if;
  select * into v_row from public.mining_fields where name = 'Canon Mine OK';
  if v_row.space_x is distinct from 123::double precision or v_row.space_y is distinct from (-456)::double precision then
    raise exception 'CANON PROOF FAIL: mine_update stored coords (%,%) != (123,-456)', v_row.space_x, v_row.space_y; end if;
  raise notice 'CANON_PASS_MINING_UPDATE';
end $$;

-- ── PROOF 7 — location_create: bad coords ⇒ EXACT envelope; ordering vs other fields preserved; valid coords
--    write the row AND exactly one active anchor at those coords (0264 behavior intact) ────────────────────
do $$
declare v_owner uuid; v_zone uuid; r jsonb; v_id uuid; n int; v_ax double precision; v_ay double precision;
begin
  select v into v_owner from canon_owner where k = 'owner';
  select v into v_zone  from canon_zone  where k = 'zone';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  -- bad coords only (everything else valid) ⇒ ONLY the two coord details, byte-identical (x-then-y).
  r := public.location_create('canon-loc-bad-1', jsonb_build_object('fields', jsonb_build_object(
         'zone_id', v_zone::text,'name','Canon Loc Bad','location_type','rally_point','activity_type','rally',
         'x',10001,'y','bad','reward_tier',2,'base_difficulty',1.5,'min_power_required',7,
         'is_public',false,'territory_radius',33,'status','active')));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed' then
    raise exception 'CANON PROOF FAIL: loc_create bad coords not validation_failed: %', r; end if;
  if (r->'details') <> '[{"code":"coord_out_of_bounds","field":"x","message":"x must be within ±10000."},{"code":"numeric_not_finite","field":"y","message":"y must be a finite number."}]'::jsonb then
    raise exception 'CANON PROOF FAIL: loc_create bad-coord details not byte-identical: %', r->'details'; end if;

  -- ORDERING: blank name + bad x + bad y together ⇒ [name_required, coord_out_of_bounds x, numeric_not_finite y]
  -- (the authority slots in at the coordinate position, between name and the reward fields, exactly as inline).
  r := public.location_create('canon-loc-order-1', jsonb_build_object('fields', jsonb_build_object(
         'zone_id', v_zone::text,'name','   ','location_type','rally_point','activity_type','rally',
         'x',10001,'y','bad','reward_tier',2,'base_difficulty',1.5,'min_power_required',7,
         'is_public',false,'territory_radius',33,'status','active')));
  if (r->'details') <> '[{"code":"name_required","field":"name","message":"Name is required (locations.name is NOT NULL)."},{"code":"coord_out_of_bounds","field":"x","message":"x must be within ±10000."},{"code":"numeric_not_finite","field":"y","message":"y must be a finite number."}]'::jsonb then
    raise exception 'CANON PROOF FAIL: loc_create detail ORDER (name,x,y) not preserved: %', r->'details'; end if;

  -- valid: boundary coords write the row + exactly one active anchor at those coords.
  r := public.location_create('canon-loc-ok-1', jsonb_build_object('fields', jsonb_build_object(
         'zone_id', v_zone::text,'name','Canon Loc OK','location_type','rally_point','activity_type','rally',
         'x',10000,'y',-10000,'reward_tier',2,'base_difficulty',1.5,'min_power_required',7,
         'is_public',false,'territory_radius',33,'status','active')));
  if (r->>'ok')::boolean is not true or (r->'result'->>'created') <> 'true' then
    raise exception 'CANON PROOF FAIL: loc_create valid not ok: %', r; end if;
  v_id := (r->'result'->>'id')::uuid;
  if (select x from public.locations where id = v_id) is distinct from 10000::double precision
     or (select y from public.locations where id = v_id) is distinct from (-10000)::double precision then
    raise exception 'CANON PROOF FAIL: loc_create stored coords wrong'; end if;
  select count(*) into n from public.space_anchors where location_id = v_id and kind='location' and status='active';
  if n <> 1 then raise exception 'CANON PROOF FAIL: loc_create wrote % active anchor(s), expected 1', n; end if;
  select space_x, space_y into v_ax, v_ay from public.space_anchors
   where location_id = v_id and kind='location' and status='active';
  if v_ax is distinct from 10000::double precision or v_ay is distinct from (-10000)::double precision then
    raise exception 'CANON PROOF FAIL: loc_create anchor coords (%,%) != (10000,-10000)', v_ax, v_ay; end if;
  raise notice 'CANON_PASS_LOC_CREATE';
end $$;

-- ── PROOF 8 — location_update: bad coords ⇒ EXACT envelope; a valid coordinate move writes the row AND
--    retires+inserts the anchor (exactly one active at the new coords — 0264 behavior intact) ──────────────
do $$
declare v_owner uuid; r jsonb; v_id uuid; v_old_anchor uuid; n int; v_ax double precision; v_ay double precision;
begin
  select v into v_owner from canon_owner where k = 'owner';
  select id into v_id from public.locations where name = 'Canon Loc OK';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  -- bad coords in fields; expected == live (created at 10000,-10000) ⇒ stale gate passes, field validation fires.
  r := public.location_update('canon-loc-upd-bad-1', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object('name','Canon Loc OK','location_type','rally_point','activity_type','rally',
           'x',10000,'y',-10000,'reward_tier',2,'base_difficulty',1.5,'min_power_required',7,
           'is_public',false,'territory_radius',33,'status','active'),
         'fields', jsonb_build_object('name','Canon Loc OK','location_type','rally_point','activity_type','rally',
           'x',10001,'y','bad','reward_tier',2,'base_difficulty',1.5,'min_power_required',7,
           'is_public',false,'territory_radius',33,'status','active')));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed' then
    raise exception 'CANON PROOF FAIL: loc_update bad coords not validation_failed: %', r; end if;
  if (r->'details') <> '[{"code":"coord_out_of_bounds","field":"x","message":"x must be within ±10000."},{"code":"numeric_not_finite","field":"y","message":"y must be a finite number."}]'::jsonb then
    raise exception 'CANON PROOF FAIL: loc_update bad-coord details not byte-identical: %', r->'details'; end if;

  select id into v_old_anchor from public.space_anchors
   where location_id = v_id and kind='location' and status='active';

  -- valid coordinate move: expected == live, fields move x/y ⇒ row moves + anchor retired + one new active.
  r := public.location_update('canon-loc-upd-ok-1', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object('name','Canon Loc OK','location_type','rally_point','activity_type','rally',
           'x',10000,'y',-10000,'reward_tier',2,'base_difficulty',1.5,'min_power_required',7,
           'is_public',false,'territory_radius',33,'status','active'),
         'fields', jsonb_build_object('name','Canon Loc OK','location_type','rally_point','activity_type','rally',
           'x',-321,'y',654,'reward_tier',2,'base_difficulty',1.5,'min_power_required',7,
           'is_public',false,'territory_radius',33,'status','active')));
  if (r->>'ok')::boolean is not true or (r->'result'->>'updated') <> 'true' then
    raise exception 'CANON PROOF FAIL: loc_update valid not ok: %', r; end if;
  if (select x from public.locations where id = v_id) is distinct from (-321)::double precision then
    raise exception 'CANON PROOF FAIL: loc_update did not move locations.x'; end if;
  select count(*) into n from public.space_anchors where location_id = v_id and kind='location' and status='active';
  if n <> 1 then raise exception 'CANON PROOF FAIL: loc_update left % active anchor(s), expected exactly 1', n; end if;
  select space_x, space_y into v_ax, v_ay from public.space_anchors
   where location_id = v_id and kind='location' and status='active';
  if v_ax is distinct from (-321)::double precision or v_ay is distinct from 654::double precision then
    raise exception 'CANON PROOF FAIL: loc_update new anchor coords (%,%) != (-321,654)', v_ax, v_ay; end if;
  if not (select status = 'retired' from public.space_anchors where id = v_old_anchor) then
    raise exception 'CANON PROOF FAIL: loc_update did not retire the old anchor'; end if;
  raise notice 'CANON_PASS_LOC_UPDATE';
end $$;

do $$ begin raise notice 'CANONICAL COORD AUTHORITY PROOF PASSED'; end $$;

rollback;   -- leave ZERO persisted state.
