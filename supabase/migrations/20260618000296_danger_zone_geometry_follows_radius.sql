-- 0296 — DANGER-ZONE GEOMETRY FOLLOWS THE RADIUS: re-materialize the derived circle zones from the
-- CURRENT territory_radius, and close the writer that let them drift in the first place.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE DEFECT (two authorities that disagree about the SAME region)
--
--   1. 0233:215-221 seeded ONE danger_zones row per hostile location, source='circle', with
--      boundary = ST_Buffer(ST_MakePoint(l.x, l.y), l.territory_radius, 32). At that time a
--      pirate_hunt site carried territory_radius = 36 (0227's 3x world scale).
--   2. 0237:115-118 reshaped every one of those into an organic "slime" polygon whose per-vertex
--      radius is  territory_radius * uniform(0.6, 1.5) * (1 + 0.18*sin(lobes*theta + phase))
--      (0237:96-101) — i.e. 0.492x .. 1.77x of the SAME territory_radius.
--   3. 0289:31-33 then did  `set territory_radius = territory_radius / 3`, taking pirate sites to 12.
--      0289 contains ZERO references to danger_zones. The polygons were never re-derived.
--
-- So the frozen snapshot is now ~3x the radius it claims to be derived from, and the two readers
-- genuinely disagree:
--   • DOCKING / CONTAINMENT reads territory_radius   — public.fleet_in_territory (0218:178-189) = 12.
--   • AMBUSH GEOMETRY reads boundary                 — public.pirate_intercept_leg_zone_hits
--     (0233:292-323, `where z.status='active' and ST_Intersects(z.boundary, leg)`) = the 36-era
--     footprint. A fleet is ambushed by a region three times wider than the territory it can dock in.
--
-- AND IT IS WHAT THE PLAYER SEES. src/features/map/territoryLayer.ts:49 skips the ring for any
-- combat marker that owns an active zone (`if (isCombatMarker(loc) && zonedLocationIds.has(loc.id))
-- continue`), so for exactly these locations the stale polygon IS the drawn region. That makes
-- 0289's own stated premise false for the class it retuned hardest: 0289:22-26 says drawing a region
-- that lies about a gameplay range "was rejected outright". For every zoned pirate site it has been
-- doing precisely that since 0289 applied.
--
-- These zones are LIVE (0237:21; pirate_intercept_enabled is true in prod).
--
-- THIS IS A GAMEPLAY CHANGE, NOT A SKIN — stated plainly, in 0289's own words, because it must not
-- surprise anyone. Every zoned hostile site's ambush region shrinks to roughly a NINTH of its
-- current area, and its drawn footprint on the map shrinks with it. No rule is rewritten: the same
-- ST_Intersects predicate over a polygon that finally matches the radius it was always supposed to
-- represent. A leg that used to be ambushed 30 world-units out from a pirate site now crosses in
-- peace — which is precisely what territory_radius = 12 has been promising the player since 0289.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT "DERIVED" MEANS HERE, AND HOW IT WAS DECIDED (from the schema, not from a guess)
--
-- danger_zones carries TWO classification columns, deliberately split by 0282:
--   source     — GEOMETRY REPRESENTATION and only that: 'circle' = generated from a location's
--                territory_radius; 'drawn' = a hand-authored ring. (0282:19-22, 0233:186.)
--   provenance — creation/protection class, IMMUTABLE: 'seeded' | 'owner'. (0282:57-59.)
--
-- The question this migration asks is "is this boundary a DERIVED SNAPSHOT?", which is exactly the
-- question `source` answers. So the sweep keys on source='circle', and on nothing else.
--
-- That is not a guess about which rows those are — every producer of a danger_zones row was checked:
--   • 0233:215-221  seed .............................. source='circle'  (the ONLY 'circle' producer)
--   • 0233:1464-1465 pirate_zone_create ............... source='drawn'
--   • 0254:352-353  zone_create (world editor) ........ source='drawn'
--   • 0280:134-137  mining successors ................. source='drawn', location_id NULL
--   • 0281:93-96    exploration successors ............ source='drawn', location_id NULL
-- No author-drawn zone is touched by anything below. The table's own CHECK (0233:195) guarantees a
-- 'circle' row is always location-backed, so every row in scope has a location to derive from.
-- (provenance='seeded' currently selects the identical set — 0282:71 backfilled it off source and
-- 0282's self-assert proves zero disagreement — but provenance answers a PROTECTION question, not a
-- geometry question, so keying on it here would be borrowing the wrong authority.)
--
-- KNOWN SEAM, STATED PLAINLY (not fixed here, and not reachable today): zone_update (0266, head
-- 0287:394-419) preserves `source` bit-for-bit when an owner reshapes a zone — it does NOT flip a
-- reshaped 'circle' row to 'drawn'. If the owner ever lights `seeded_zone_edit_enabled` (0283, seeded
-- false) and hand-reshapes a seeded zone, that row stays source='circle' and this migration's writer
-- hook would regenerate over the owner's shape on the next location edit. The correct fix is for
-- zone_update to set source='drawn' when it materializes an owner ring; that is zone_update's slice,
-- not this one, and the flag being dark means no such row can exist today.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHY BOTH HALVES SHIP IN ONE MIGRATION
--
-- Re-materializing the DATA without closing the WRITER guarantees the bug returns: location_update
-- (0249, head 0265:1037) can change a location's x, y or territory_radius and leaves the derived
-- polygon frozen — the identical split-brain 0264 closed for space_anchors (0264:9-14 names it in so
-- many words: "location_update rewrites locations.x/y but never moves the anchor -> the anchor goes
-- STALE"). The derived zone is the second thing hanging off the same coordinate + radius, and it was
-- never hooked. So: ONE re-materialization authority, called by the backfill AND by location_update.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- HOW THE SHAPE IS REGENERATED — 0237's GENERATOR, REUSED VERBATIM
--
-- public.danger_zone_rematerialize_for_location() below carries 0237:88-113 unchanged (vertex count
-- 12..24, monotonic angle sweep with jitter < half a step so the ring is star-shaped and therefore
-- simple, radius = base * uniform(0.6,1.5) * (1 + 0.18*sin(lobes*theta+phase)), ring closed by
-- repeating vertex 1, ST_MakePolygon(ST_MakeLine(pts)), ST_MakeValid repair, RAISE if even that
-- fails). The ONLY change is that `base` is now read at CALL TIME instead of being frozen in 2026-06.
-- The organic look 0237 shipped is preserved exactly; the zones simply stop being 3x too big.
--
-- PostGIS calls are schema-qualified (public.st_*) because every function here pins search_path=''
-- — the 0254/0266 idiom. Geometries carry NO SRID, matching every 0233/0237 geometry (0233:20-22).
--
-- SCOPE / NON-GOALS:
--   • A location whose territory_radius is NULL (territory removed) is SKIPPED — 0237's own domain
--     filter (0237:85-86). There is no radius to derive from; retiring such a zone is
--     zone_unpublish's job, not a geometry refresh's.
--   • Forward-only. No table DDL, no column, no constraint, no policy, no cron, no flag, no
--     game_config value read or written.
--   • revision is bumped on every rewrite (the 0287 concurrency token) so an owner draft forked
--     against the OLD boundary is correctly rejected as stale instead of silently re-freezing it.

-- ── 0. preconditions ────────────────────────────────────────────────────────────────────────────
do $dz0$
begin
  if to_regclass('public.danger_zones') is null then
    raise exception '0296: public.danger_zones (0233) is missing — this migration re-derives its circle geometry';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'danger_zones' and column_name = 'revision') then
    raise exception '0296: danger_zones.revision (0275) is missing — the concurrency token this bumps must exist';
  end if;
  -- exactly the signature strings already proven by shipped gates (0254:74, 0267:85, 0269:81) — a
  -- dependency gate must never be the thing that aborts a deploy on a signature-spelling guess.
  if to_regprocedure('public.st_makepolygon(public.geometry)') is null
     or to_regprocedure('public.st_isvalid(public.geometry)') is null
     or to_regprocedure('public.st_dumppoints(public.geometry)') is null
     or to_regprocedure('public.st_asbinary(public.geometry)') is null then
    raise exception '0296: PostGIS (installed by 0233) is missing — the 0237 generator and this migration''s self-assert compose it';
  end if;
  if to_regprocedure('public.location_update(text, jsonb)') is null then
    raise exception '0296: public.location_update(text,jsonb) (0249, head 0265) is missing — the writer this closes must exist';
  end if;
end $dz0$;

-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- PART 1a — THE ONE RE-MATERIALIZATION AUTHORITY
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- Regenerates the boundary of every DERIVED (source='circle') zone bound to p_location_id from that
-- location's CURRENT x, y and territory_radius, using 0237's generator unchanged. Returns how many
-- zones it rewrote. Author-drawn zones (source='drawn') are never selected, so this cannot overwrite
-- authored geometry. Called by the backfill below AND by location_update — ONE authority, two
-- callers, no second copy of the shape maths anywhere.
--
-- INTERNAL POSTURE: SECURITY INVOKER, execute revoked from public/anon/authenticated (the
-- pirate_intercept_leg_zone_hits idiom, 0233:325). Its only caller from the client side is
-- location_update, which is SECURITY DEFINER and therefore runs this as the definer.
--
-- A geometry that cannot be built RAISES (0237:111-113). That is a dead path by construction, and a
-- raise is the correct outcome: inside location_update it aborts the whole publish transaction, so a
-- location edit can never half-apply with a broken zone next to it.
create or replace function public.danger_zone_rematerialize_for_location(p_location_id uuid)
returns integer
language plpgsql
volatile
set search_path = ''
as $dzfn$
declare
  z        record;
  v_n      integer;
  v_i      integer;
  v_step   double precision;
  v_theta  double precision;
  v_r      double precision;
  v_lobes  double precision;
  v_phase  double precision;
  v_pts    public.geometry[];
  v_poly   public.geometry;
  v_count  integer := 0;
begin
  if p_location_id is null then
    return 0;
  end if;

  for z in
    select dz.id, l.x as cx, l.y as cy, l.territory_radius as base
      from public.danger_zones dz
      join public.locations l on l.id = dz.location_id
     where dz.location_id = p_location_id
       and dz.source = 'circle'
       and l.territory_radius is not null
       and l.territory_radius > 0
  loop
    -- ── 0237:88-104 verbatim; only `base` is now read live instead of frozen ──────────────────
    v_n     := 12 + floor(random() * 13)::int;          -- 12..24 vertices
    v_step  := 2 * pi() / v_n;
    v_lobes := 3 + floor(random() * 4)::int;            -- 3..6 organic lobes
    v_phase := random() * 2 * pi();
    v_pts   := array[]::public.geometry[];

    for v_i in 0 .. v_n - 1 loop
      -- angle: monotonic sweep + bounded jitter (< half a step => strictly increasing => simple ring)
      v_theta := v_i * v_step + (random() - 0.5) * 0.8 * v_step;
      -- radius: wobble 0.6x..1.5x of territory_radius, modulated by a deterministic multi-lobe sine
      v_r := z.base
             * (0.6 + random() * 0.9)
             * (1 + 0.18 * sin(v_lobes * v_theta + v_phase));
      v_pts := v_pts || public.st_makepoint(z.cx + v_r * cos(v_theta), z.cy + v_r * sin(v_theta));
    end loop;
    v_pts := v_pts || v_pts[1];                          -- close the ring

    v_poly := public.st_makepolygon(public.st_makeline(v_pts));
    if v_poly is null or not public.st_isvalid(v_poly) then
      -- belt-and-suspenders repair (dead path given the star-shaped construction above)
      v_poly := public.st_geometryn(public.st_collectionextract(public.st_makevalid(v_poly), 3), 1);
    end if;
    if v_poly is null or not public.st_isvalid(v_poly)
       or public.st_geometrytype(v_poly) <> 'ST_Polygon'
       or not (public.st_area(v_poly) > 0) then
      raise exception '0296: could not build a valid polygon for zone % (n=%, base=%)', z.id, v_n, z.base;
    end if;

    update public.danger_zones
       set boundary   = v_poly,
           updated_at = now(),
           revision   = revision + 1
     where id = z.id;
    v_count := v_count + 1;
  end loop;

  return v_count;
end $dzfn$;

comment on function public.danger_zone_rematerialize_for_location(uuid) is
  'THE re-materialization authority for DERIVED danger-zone geometry (0296). Rewrites the boundary of '
  'every source=''circle'' zone bound to this location from the location''s CURRENT x/y/territory_radius, '
  'reusing 0237''s organic generator unchanged, and bumps danger_zones.revision. source=''drawn'' '
  '(author-drawn) zones are never selected. Internal: no client grant — location_update (SECURITY '
  'DEFINER) is its caller. Exists because 0289 divided territory_radius by 3 and left the 0233/0237 '
  'snapshots frozen at the old scale, so docking read one region and ambush read another.';

revoke all on function public.danger_zone_rematerialize_for_location(uuid) from public, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- PART 1b — THE BACKFILL: re-derive every derived zone that exists today
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- Vacuous on an empty dataset (zero locations => zero iterations), which is exactly right — this is
-- data repair, and a migration must never require a seed row to exist.
--
-- BEFORE-SNAPSHOT of every AUTHOR-DRAWN zone, so the self-assert can PROVE (not merely document)
-- that this migration left authored geometry byte-identical. Session-local temp table, dropped
-- explicitly at the end of the file; it touches no schema and no live row. Deliberately NOT
-- `on commit drop` — a migration runner that does not wrap the file in one transaction would then
-- destroy the snapshot before the assert could read it.
create temp table dz0296_drawn_before as
  select id,
         public.st_asbinary(boundary) as wkb,
         revision,
         updated_at
    from public.danger_zones
   where source <> 'circle';

do $dz1$
declare
  v_loc    uuid;
  v_zones  integer := 0;
  v_locs   integer := 0;
begin
  for v_loc in
    select distinct dz.location_id
      from public.danger_zones dz
     where dz.source = 'circle'
       and dz.location_id is not null
  loop
    v_locs  := v_locs + 1;
    v_zones := v_zones + public.danger_zone_rematerialize_for_location(v_loc);
  end loop;
  raise notice '0296: re-materialized % derived circle zone(s) across % location(s) from the CURRENT territory_radius', v_zones, v_locs;
end $dz1$;

-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- PART 2 — CLOSE THE WRITER: location_update re-derives the zone when the location moves or resizes
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- The 0265 body (canonical coordinate authority over the 0264 anchor write-authority) reproduced
-- EXACTLY — same signature, same SECURITY DEFINER, same `set search_path = ''`, same validation, same
-- envelopes, same anchor retire+insert, same audit row, same grants — with ONE hunk added inside the
-- existing apply sub-block, immediately after the anchor block: when (and only when) x, y or
-- territory_radius actually changed against the LOCKED live row, the derived zone geometry is
-- re-derived through the single authority above.
--
-- Conditional, not unconditional, and deliberately so: the generator is random, so firing it on a
-- name-only edit would re-wobble a zone the owner did not touch. It fires on exactly the three
-- inputs the geometry is derived FROM — the same discipline 0264 applied to the anchor.
--
-- Inside the sub-block, so a raced duplicate request_id (unique_violation) rolls the zone rewrite
-- back together with the location write and the anchor move: one atomic publish, never a torn one.
create or replace function public.location_update(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_target    text;
  v_target_id uuid;
  v_expected  jsonb;
  v_fields    jsonb;
  v_details   jsonb := '[]'::jsonb;
  v_name      text;
  v_loc_type  text;
  v_act_type  text;
  v_status    text;
  v_x         numeric;
  v_y         numeric;
  v_tier      numeric;
  v_diff      numeric;
  v_minpow    numeric;
  v_radius    numeric;
  v_public    boolean;
  v_live      record;
  v_before    jsonb;
  v_after     jsonb;
  v_result    jsonb;
  v_prior     text;
  v_id        uuid;
  v_conflict_table text;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authenticated');
  end if;
  if not public.is_owner() then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authorized');
  end if;
  if p_request_id is null or length(btrim(p_request_id)) = 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;

  select result into v_prior from public.world_editor_audit where request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'request_id', p_request_id,
             'command_type', 'location_update', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  v_target   := btrim(coalesce(p_payload->>'target_id', ''));
  v_expected := p_payload->'expected';
  if v_target = '' or v_expected is null or jsonb_typeof(v_expected) <> 'object' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;
  begin
    v_target_id := v_target::uuid;
  exception when invalid_text_representation then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end;

  select id, zone_id, name, location_type, activity_type, x, y, reward_tier, base_difficulty,
         min_power_required, is_public, territory_radius, status, max_presence_seconds, created_at
    into v_live
    from public.locations
   where id = v_target_id
     for update;
  if not found then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_found',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_missing', 'field', null,
               'message', 'No live location with id ''' || v_target || ''' exists — it may have been removed since the draft was forked.')));
  end if;

  if v_expected->>'name' is distinct from v_live.name then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'name',
      'message', 'The live location''s name changed since this draft was forked.'));
  end if;
  if v_expected->>'location_type' is distinct from v_live.location_type then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'location_type',
      'message', 'The live location''s location_type changed since this draft was forked.'));
  end if;
  if v_expected->>'activity_type' is distinct from v_live.activity_type then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'activity_type',
      'message', 'The live location''s activity_type changed since this draft was forked.'));
  end if;
  if v_expected->'x' is distinct from to_jsonb(v_live.x) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'x',
      'message', 'The live location''s x changed since this draft was forked.'));
  end if;
  if v_expected->'y' is distinct from to_jsonb(v_live.y) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'y',
      'message', 'The live location''s y changed since this draft was forked.'));
  end if;
  if v_expected->'reward_tier' is distinct from to_jsonb(v_live.reward_tier) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'reward_tier',
      'message', 'The live location''s reward_tier changed since this draft was forked.'));
  end if;
  if v_expected->'base_difficulty' is distinct from to_jsonb(v_live.base_difficulty) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'base_difficulty',
      'message', 'The live location''s base_difficulty changed since this draft was forked.'));
  end if;
  if v_expected->'min_power_required' is distinct from to_jsonb(v_live.min_power_required) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'min_power_required',
      'message', 'The live location''s min_power_required changed since this draft was forked.'));
  end if;
  if v_expected->'is_public' is distinct from to_jsonb(v_live.is_public) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'is_public',
      'message', 'The live location''s is_public changed since this draft was forked.'));
  end if;
  if coalesce(v_expected->'territory_radius', 'null'::jsonb)
       is distinct from coalesce(to_jsonb(v_live.territory_radius), 'null'::jsonb) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'territory_radius',
      'message', 'The live location''s territory_radius changed since this draft was forked.'));
  end if;
  if v_expected->>'status' is distinct from v_live.status then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'status',
      'message', 'The live location''s status changed since this draft was forked.'));
  end if;
  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'stale_revision', 'details', v_details);
  end if;

  v_fields := p_payload->'fields';
  if v_fields is null or jsonb_typeof(v_fields) <> 'object' then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'invalid_payload', 'field', null, 'message', 'payload.fields must be a JSON object.'));
  else
    v_name := btrim(coalesce(v_fields->>'name', ''));
    if v_name = '' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'name_required', 'field', 'name', 'message', 'Name is required (locations.name is NOT NULL).'));
    end if;

    v_loc_type := v_fields->>'location_type';
    if v_loc_type is null or v_loc_type not in
       ('pirate_hunt','pirate_den','mining_site','derelict_station','trade_outpost','rally_point','safe_zone','event_site') then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_location_type', 'field', 'location_type',
        'message', 'Location type ''' || coalesce(v_loc_type, '(missing)') || ''' is not allowed by the live CHECK constraint.'));
    end if;

    v_act_type := v_fields->>'activity_type';
    if v_act_type is null or v_act_type not in
       ('hunt_pirates','mine_resource','explore_derelict','trade_visit','rally','none') then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_activity_type', 'field', 'activity_type',
        'message', 'Activity type ''' || coalesce(v_act_type, '(missing)') || ''' is not allowed by the live CHECK constraint.'));
    end if;

    v_status := v_fields->>'status';
    if v_status is null or v_status not in ('active','locked','hidden') then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_status', 'field', 'status',
        'message', 'Status ''' || coalesce(v_status, '(missing)') || ''' is not allowed — must be one of active, locked, hidden.'));
    end if;

    -- coordinates — THE ONE canonical ±10000 authority (was two inline x/y blocks).
    v_details := v_details || public.canonical_coord_violation(
                   v_fields->'x', v_fields->'y', 'x', 'y');

    if jsonb_typeof(v_fields->'reward_tier') is distinct from 'number' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'numeric_not_finite', 'field', 'reward_tier', 'message', 'reward_tier must be a finite number.'));
    else
      v_tier := (v_fields->'reward_tier')::numeric;
      if v_tier < 0 then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'reward_tier_negative', 'field', 'reward_tier', 'message', 'Reward tier must be >= 0.'));
      elsif (v_tier % 1) <> 0 then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'reward_tier_not_integer', 'field', 'reward_tier', 'message', 'Reward tier must be an integer.'));
      end if;
    end if;

    if jsonb_typeof(v_fields->'base_difficulty') is distinct from 'number' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'numeric_not_finite', 'field', 'base_difficulty', 'message', 'base_difficulty must be a finite number.'));
    else
      v_diff := (v_fields->'base_difficulty')::numeric;
      if v_diff < 0 then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'base_difficulty_negative', 'field', 'base_difficulty', 'message', 'Difficulty must be >= 0.'));
      end if;
    end if;

    if jsonb_typeof(v_fields->'min_power_required') is distinct from 'number' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'numeric_not_finite', 'field', 'min_power_required', 'message', 'min_power_required must be a finite number.'));
    else
      v_minpow := (v_fields->'min_power_required')::numeric;
      if v_minpow < 0 then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'min_power_negative', 'field', 'min_power_required', 'message', 'Min power must be >= 0.'));
      end if;
    end if;

    if v_fields->'territory_radius' is null or jsonb_typeof(v_fields->'territory_radius') = 'null' then
      v_radius := null;
    elsif jsonb_typeof(v_fields->'territory_radius') <> 'number' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'numeric_not_finite', 'field', 'territory_radius', 'message', 'territory_radius must be a finite number (or null for no territory).'));
    else
      v_radius := (v_fields->'territory_radius')::numeric;
      if v_radius <= 0 then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'territory_radius_not_positive', 'field', 'territory_radius',
          'message', 'Territory radius must be greater than 0 (null for no territory).'));
      end if;
    end if;

    if jsonb_typeof(v_fields->'is_public') is distinct from 'boolean' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_payload', 'field', 'is_public', 'message', 'is_public must be a boolean.'));
    else
      v_public := (v_fields->'is_public')::boolean;
    end if;
  end if;

  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'validation_failed', 'details', v_details);
  end if;

  -- coordinates validated above by the canonical authority; parse them for the write (+ anchor).
  v_x := (v_fields->'x')::numeric;
  v_y := (v_fields->'y')::numeric;

  v_before := jsonb_build_object(
                'id', v_live.id, 'zone_id', v_live.zone_id, 'name', v_live.name,
                'location_type', v_live.location_type, 'activity_type', v_live.activity_type,
                'x', v_live.x, 'y', v_live.y, 'reward_tier', v_live.reward_tier,
                'base_difficulty', v_live.base_difficulty,
                'min_power_required', v_live.min_power_required, 'is_public', v_live.is_public,
                'territory_radius', v_live.territory_radius, 'status', v_live.status,
                'max_presence_seconds', v_live.max_presence_seconds, 'created_at', v_live.created_at);
  begin
    update public.locations
       set name               = v_name,
           location_type      = v_loc_type,
           activity_type      = v_act_type,
           x                  = v_x::double precision,
           y                  = v_y::double precision,
           reward_tier        = v_tier::int,
           base_difficulty    = v_diff::double precision,
           min_power_required = v_minpow::double precision,
           is_public          = v_public,
           territory_radius   = v_radius,
           status             = v_status
     where id = v_live.id
     returning jsonb_build_object(
                 'id', id, 'zone_id', zone_id, 'name', name, 'location_type', location_type,
                 'activity_type', activity_type, 'x', x, 'y', y, 'reward_tier', reward_tier,
                 'base_difficulty', base_difficulty, 'min_power_required', min_power_required,
                 'is_public', is_public, 'territory_radius', territory_radius, 'status', status,
                 'max_presence_seconds', max_presence_seconds, 'created_at', created_at),
               id
       into v_after, v_id;

    -- ── ANCHOR AUTHORITY (0264): keep the anchor in lock-step with the coordinate. ONLY when x or y actually
    -- change (compared against the LOCKED live row, ::double precision to match anchor/column storage) do we
    -- relocate: RETIRE the current active anchor (active→retired — the sole 0063-permitted transition) then
    -- INSERT a new active anchor at the new (x,y). NOT an in-place UPDATE of space_x/space_y (the 0063 guard
    -- forbids that). A non-coordinate edit leaves the anchor untouched. If the location somehow had no active
    -- anchor (backfill guarantees it does), the retire updates 0 rows and the insert still establishes the
    -- one active anchor — self-healing, and still exactly one active.
    if v_x::double precision is distinct from v_live.x
       or v_y::double precision is distinct from v_live.y then
      update public.space_anchors
         set status = 'retired'
       where location_id = v_live.id and kind = 'location' and status = 'active';
      insert into public.space_anchors (kind, location_id, space_x, space_y, status)
        values ('location', v_live.id, v_x::double precision, v_y::double precision, 'active');
    end if;

    -- ── DERIVED-ZONE AUTHORITY (0296): the anchor is not the only thing hanging off this location's
    -- coordinate. A source='circle' danger zone IS a snapshot of (x, y, territory_radius); leaving it
    -- frozen is the same split-brain 0264 closed for space_anchors, and it is what 0289 did by
    -- dividing the radius without re-deriving the polygon. So when — and only when — one of those
    -- three derivation inputs actually moved against the LOCKED live row, re-derive through the ONE
    -- authority. It is a no-op for a location that owns no derived zone (the common case), and
    -- author-drawn zones are never selected by it.
    if v_x::double precision is distinct from v_live.x
       or v_y::double precision is distinct from v_live.y
       or v_radius is distinct from v_live.territory_radius then
      perform public.danger_zone_rematerialize_for_location(v_live.id);
    end if;

    v_result := jsonb_build_object('updated', true, 'id', v_id, 'name', v_name);

    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'location_update', 'location', v_id::text, v_result::text,
         v_before, v_after, p_payload->>'source_revision');
  exception when unique_violation then
    get stacked diagnostics v_conflict_table = TABLE_NAME;
    if v_conflict_table = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'location_update', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'conflict',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'duplicate_name', 'field', 'name',
               'message', 'A location with this name already exists in the same zone.')));
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id,
           'command_type', 'location_update', 'result', v_result);
end $$;

revoke all on function public.location_update(text, jsonb) from public;
grant execute on function public.location_update(text, jsonb) to authenticated;  -- guard is in-body; NEVER anon
revoke insert, update, delete on table public.locations from anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SELF-ASSERT — pins THIS migration's effect ONLY (deploy-time; a raise aborts the txn)
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- Deliberately asserts NO game_config value, NO feature flag, and NO seed-row existence: 0288 failed
-- a PRODUCTION deploy asserting a flag value, and 0295 broke its own disposable-stack proof
-- asserting a seed row existed. Every check below is VACUOUSLY TRUE on an empty dataset, which is
-- the correct posture for a migration that also has to apply to a fresh disposable Postgres.
do $dz2$
declare
  v_bad   integer;
  v_total integer;
  v_src   text;
begin
  -- ── (1) THE HEADLINE INVARIANT: every DERIVED zone's geometry now lies inside the band the 0237
  -- generator can produce around its location's CURRENT territory_radius.
  --   upper bound = base * 1.5 * 1.18   (0237's uniform ceiling 1.5, times the sine ceiling 1+0.18)
  --   lower bound = base * 0.6 * 0.82   (0237's uniform floor 0.6, times the sine floor 1-0.18)
  -- Both bounds are STRUCTURAL properties of 0237:96-101, not tuning. The upper bound is the one
  -- that the defect violated: before this migration the vertices sat at up to 3x that ceiling.
  -- Vertex radius is measured from the LOCATION's own (x, y) — the true generation centre — not from
  -- the polygon centroid, because "does the geometry follow the radius" is a question about the
  -- location, not about the blob's own middle.
  with v as (
    select dz.id,
           l.territory_radius::double precision as base,
           public.st_distance(p.geom, public.st_makepoint(l.x, l.y)) as vr
      from public.danger_zones dz
      join public.locations l on l.id = dz.location_id
      cross join lateral public.st_dumppoints(dz.boundary) p
     where dz.source = 'circle'
       and l.territory_radius is not null
       and l.territory_radius > 0
  ),
  agg as (
    select id, max(base) as base, max(vr) as maxr, min(vr) as minr
      from v group by id
  )
  select count(*) into v_bad
    from agg
   where maxr > base * 1.5 * 1.18 + 1e-6
      or minr < base * 0.6 * 0.82 - 1e-6;
  if v_bad > 0 then
    raise exception '0296 self-assert FAIL: % derived circle zone(s) have vertices outside [0.492x, 1.77x] of their location''s CURRENT territory_radius — the geometry does not follow the radius', v_bad;
  end if;

  -- ── (2) the rewrite produced sane PostGIS in every case (validity + positive area + Polygon).
  select count(*) into v_bad
    from public.danger_zones dz
    join public.locations l on l.id = dz.location_id
   where dz.source = 'circle'
     and l.territory_radius is not null
     and l.territory_radius > 0
     and (dz.boundary is null
          or not public.st_isvalid(dz.boundary)
          or public.st_geometrytype(dz.boundary) <> 'ST_Polygon'
          or not (public.st_area(dz.boundary) > 0));
  if v_bad > 0 then
    raise exception '0296 self-assert FAIL: % derived circle zone(s) are not valid positive-area polygons', v_bad;
  end if;

  -- ── (3) NOTHING AUTHOR-DRAWN WAS TOUCHED — proven against the before-snapshot, not asserted.
  -- Every non-'circle' row must still exist with a byte-identical boundary, an unmoved revision and
  -- an unmoved updated_at. This deliberately compares MY OWN before/after rather than checking that
  -- authored geometry is "valid": validity is a pre-existing property this migration does not own,
  -- and a self-assert must pin this migration's effect and nothing else. Vacuous when there are no
  -- author-drawn zones (a fresh disposable stack), which is correct.
  select count(*) into v_bad
    from dz0296_drawn_before b
    full outer join (
      select id, public.st_asbinary(boundary) as wkb, revision, updated_at
        from public.danger_zones where source <> 'circle'
    ) a on a.id = b.id
   where a.id is null
      or b.id is null
      or a.wkb is distinct from b.wkb
      or a.revision is distinct from b.revision
      or a.updated_at is distinct from b.updated_at;
  if v_bad > 0 then
    raise exception '0296 self-assert FAIL: % author-drawn zone(s) changed — this migration must only re-derive source=circle geometry', v_bad;
  end if;

  -- ── (4) THE WRITER IS CLOSED (the half-slice guard: repairing data without the writer guarantees
  -- the drift returns). location_update must carry the re-derivation call, gated on the derivation
  -- inputs, and must still be the 0264/0265 function in every other respect.
  select prosrc into v_src from pg_proc where oid = 'public.location_update(text,jsonb)'::regprocedure;
  if v_src is null then
    raise exception '0296 self-assert FAIL: location_update(text,jsonb) is missing';
  end if;
  if position('perform public.danger_zone_rematerialize_for_location(v_live.id)' in v_src) = 0 then
    raise exception '0296 self-assert FAIL: location_update does not re-derive the zone geometry — the writer is still open';
  end if;
  if position('or v_radius is distinct from v_live.territory_radius then' in v_src) = 0 then
    raise exception '0296 self-assert FAIL: location_update does not gate the re-derivation on a territory_radius change';
  end if;
  -- 0264's anchor write-authority preserved (0265:1431-1434, reproduced verbatim so a regression here
  -- is caught by THIS migration and not only by the next one to look).
  if position('insert into public.space_anchors' in v_src) = 0
     or position('set status = ''retired''' in v_src) = 0 then
    raise exception '0296 self-assert FAIL: location_update no longer retires+inserts the anchor (0264 anchor authority regressed)';
  end if;
  -- 0265's canonical coordinate authority preserved.
  if position('canonical_coord_violation' in v_src) = 0 or position('x must be within' in v_src) <> 0 then
    raise exception '0296 self-assert FAIL: location_update is no longer routed through the canonical coordinate authority (0265 regressed)';
  end if;

  -- ── (5) SECURITY POSTURE of location_update byte-for-byte with 0265: SECURITY DEFINER, pinned
  -- search_path, authenticated-only, anon denied, no client write grant regained on locations.
  if not (select prosecdef from pg_proc where oid = 'public.location_update(text,jsonb)'::regprocedure) then
    raise exception '0296 self-assert FAIL: location_update lost SECURITY DEFINER';
  end if;
  if not exists (select 1 from pg_proc p
                  where p.oid = 'public.location_update(text,jsonb)'::regprocedure
                    and p.proconfig is not null
                    and exists (select 1 from unnest(p.proconfig) cfg where cfg like 'search_path=%')) then
    raise exception '0296 self-assert FAIL: location_update does not pin search_path';
  end if;
  if not has_function_privilege('authenticated', 'public.location_update(text,jsonb)', 'execute') then
    raise exception '0296 self-assert FAIL: authenticated cannot execute location_update — the in-body guard would be unreachable';
  end if;
  if has_function_privilege('anon', 'public.location_update(text,jsonb)', 'execute') then
    raise exception '0296 self-assert FAIL: anon CAN execute location_update — must be authenticated-only';
  end if;
  if has_table_privilege('authenticated', 'public.locations', 'INSERT')
     or has_table_privilege('authenticated', 'public.locations', 'UPDATE')
     or has_table_privilege('authenticated', 'public.locations', 'DELETE') then
    raise exception '0296 self-assert FAIL: a client role holds a write grant on locations';
  end if;
  if not has_table_privilege('anon', 'public.locations', 'SELECT')
     or not has_table_privilege('authenticated', 'public.locations', 'SELECT') then
    raise exception '0296 self-assert FAIL: a client role lost SELECT on locations — the map read would break';
  end if;

  -- ── (6) the re-materialization authority is INTERNAL — no client role may call it directly.
  if to_regprocedure('public.danger_zone_rematerialize_for_location(uuid)') is null then
    raise exception '0296 self-assert FAIL: danger_zone_rematerialize_for_location(uuid) is missing';
  end if;
  if has_function_privilege('anon', 'public.danger_zone_rematerialize_for_location(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.danger_zone_rematerialize_for_location(uuid)', 'execute') then
    raise exception '0296 self-assert FAIL: a client role can execute the re-materialization authority — it is definer-internal';
  end if;
  -- it must select ONLY derived geometry, never author-drawn rows
  select prosrc into v_src from pg_proc where oid = 'public.danger_zone_rematerialize_for_location(uuid)'::regprocedure;
  if position('dz.source = ''circle''' in v_src) = 0 then
    raise exception '0296 self-assert FAIL: the re-materialization authority does not restrict itself to derived (source=circle) zones';
  end if;

  -- ── (7) no danger_zones write grant regained for a client role (0239 lockdown intact).
  if has_table_privilege('authenticated', 'public.danger_zones', 'INSERT')
     or has_table_privilege('authenticated', 'public.danger_zones', 'UPDATE')
     or has_table_privilege('authenticated', 'public.danger_zones', 'DELETE')
     or has_table_privilege('anon', 'public.danger_zones', 'UPDATE') then
    raise exception '0296 self-assert FAIL: a client role holds a write grant on danger_zones (0239 lockdown regressed)';
  end if;

  select count(*) into v_total from public.danger_zones where source = 'circle';
  raise notice '0296 OK: % derived circle zone(s) now lie within [0.492x, 1.77x] of their location''s CURRENT territory_radius (the 0237 generator band, re-derived live instead of frozen at the pre-0289 scale); author-drawn zones untouched; location_update re-derives on any x/y/territory_radius change with its 0264 anchor authority, 0265 coordinate authority, SECURITY DEFINER posture and grants intact', v_total;
end $dz2$;

-- the before-snapshot has served its purpose; it is session-local and owns nothing.
drop table if exists dz0296_drawn_before;
