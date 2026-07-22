-- Byeharu — WORLD-EDITOR V1C PR-D+ : make public.space_anchors the SOLE location-coordinate AUTHORITY
-- (read AND write). This closes the split-brain gap PR-D (0263) left open and tightens the read from a
-- fail-SAFE fallback into a fail-CLOSED authority.
--
-- ── THE GAP THIS CLOSES ───────────────────────────────────────────────────────────────────────────────
-- 0263 relocated get_world_map()'s READ authority onto the active location anchor, but with a LEFT JOIN +
-- `coalesce(a.space_x, l.x)` fallback — because the owner-gated write RPCs still wrote ONLY locations.x/y:
--   • location_create (0252) inserts a location with NO anchor → coalesce silently falls back to l.x/l.y;
--   • location_update (0249) rewrites locations.x/y but never moves the anchor → the anchor goes STALE and
--     coalesce hides it (anchor present ⇒ map shows the OLD anchor coord, diverging from locations.x/y).
-- Either way the anchor and locations.x/y drift apart = split brain, and the "anchor is authority" claim is
-- only a read-preference. This migration makes every location-coordinate WRITE path also write the anchor,
-- ATOMICALLY, honoring the 0063 immutable-anchor lifecycle, then removes the coalesce so the anchor is the
-- ONLY source get_world_map reads.
--
-- ── THE 0063 ANCHOR LIFECYCLE (honored exactly) ───────────────────────────────────────────────────────
--   • kind='location', status='active', space_x/space_y = double precision in [-10000,10000]^2 (CHECK).
--   • An ACTIVE anchor row is IMMUTABLE except status active→retired (BEFORE-UPDATE guard 0063). A COORDINATE
--     change is therefore NOT an in-place UPDATE of space_x/space_y — it is RETIRE the current active anchor
--     (active→retired) + INSERT a new active anchor at the new coord.
--   • Partial unique index space_anchors_one_active_per_location ⇒ EXACTLY ONE active anchor per location.
--     Retire-then-insert within one txn never trips it (the retired row leaves the partial index first).
--   • The table is server-private (RLS on / no policy; client write REVOKED). All the RPCs below are already
--     SECURITY DEFINER, so they may write it; no client grant is widened.
--
-- ── WHAT CHANGES (three redefinitions + an idempotent backfill; forward-only, no history edited) ──────────
--   1. location_create — after the locations INSERT, INSERT exactly one active location anchor at the same
--      (x,y), in the SAME atomic sub-block (a failure rolls the location back too).
--   2. location_update — if (and only if) x or y actually change, RETIRE the current active anchor and INSERT
--      a new active one at the new (x,y), in the SAME atomic sub-block. A non-coordinate edit leaves the
--      anchor untouched.
--   3. get_world_map — read the ACTIVE anchor coordinate DIRECTLY via INNER JOIN (no coalesce, no locations.x/y
--      fallback). Every active location is guaranteed to have exactly one active anchor by steps 1+2 and the
--      backfill below, so the INNER JOIN drops nothing today; but it fail-CLOSES: an active location that ever
--      lost its anchor is EXCLUDED from the map (the same "only fully-active rows render" contract the function
--      already applies via its status='active' filters) rather than silently rendering a legacy coordinate.
--
-- ── INDEPENDENT OF THE ×17 RESCALE ────────────────────────────────────────────────────────────────────
-- This is NOT the physical rescale (PR #245 / migration 0253). No point is moved, no coordinate is scaled.
-- The seeded world's get_world_map payload stays BYTE-IDENTICAL to the legacy locations.x/y payload (the
-- backfill keeps every anchor at its location's EXACT current (x,y); the proof re-verifies byte-identity).
--
-- DEPLOY POSTURE: UNDEPLOYED — deploy is a human gate. The write paths stay inert until an owner is seeded
-- (is_owner() is false on an unseeded DB). No client grant is widened; the only anchor writer is the
-- SECURITY DEFINER command surface.

-- ── 0. dependency gate — abort loudly if a surface this slice rebuilds is missing ─────────────────────────
do $pubdep$
begin
  if to_regclass('public.locations') is null then
    raise exception 'V1C-WRITE-AUTHORITY: public.locations (0002) is missing';
  end if;
  if to_regclass('public.space_anchors') is null then
    raise exception 'V1C-WRITE-AUTHORITY: public.space_anchors (0063) is missing — the anchor authority table must exist';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'V1C-WRITE-AUTHORITY: public.world_editor_audit (0243) is missing — the audit/idempotency spine must exist';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'V1C-WRITE-AUTHORITY: public.is_owner() (0243) is missing';
  end if;
  if to_regprocedure('public.location_create(text, jsonb)') is null then
    raise exception 'V1C-WRITE-AUTHORITY: public.location_create (0252) is missing — the create write-path this rebuilds must exist';
  end if;
  if to_regprocedure('public.location_update(text, jsonb)') is null then
    raise exception 'V1C-WRITE-AUTHORITY: public.location_update (0249) is missing — the update write-path this rebuilds must exist';
  end if;
  if to_regprocedure('public.get_world_map()') is null then
    raise exception 'V1C-WRITE-AUTHORITY: public.get_world_map() (0263) is missing — the read this slice tightens must exist';
  end if;
  -- the 0063 immutability guard + partial unique index are the lifecycle authority; assert they exist.
  if to_regprocedure('public.space_anchors_immutability_guard()') is null then
    raise exception 'V1C-WRITE-AUTHORITY: 0063 immutability guard is missing — the anchor lifecycle is unenforced';
  end if;
  if to_regclass('public.space_anchors_one_active_per_location') is null then
    raise exception 'V1C-WRITE-AUTHORITY: 0063 partial unique index space_anchors_one_active_per_location is missing — one-active-per-location is unenforced';
  end if;
end $pubdep$;

-- ── 1. BACKFILL (idempotent; the 0245 world-wide backfill re-run) — one active anchor per unanchored active
--       location, at its exact current (x,y). Post-0245 this inserts ZERO rows; it is here so this migration
--       is a self-contained authority even if applied onto a chain where 0245 was rolled forward differently.
do $$
declare v_inserted int;
begin
  insert into public.space_anchors (kind, location_id, space_x, space_y, status)
  select 'location', l.id, l.x, l.y, 'active'
    from public.locations l
   where not exists (
           select 1 from public.space_anchors a
            where a.location_id = l.id and a.kind = 'location' and a.status = 'active')
   order by l.id;
  get diagnostics v_inserted = row_count;
  raise notice 'V1C-WRITE-AUTHORITY backfill: % location anchor(s) inserted at their location''s exact (x,y) (0 expected post-0245)', v_inserted;
end $$;

-- ── 2. location_create — 0252 body, REDEFINED to also write the active anchor atomically ──────────────────
-- Byte-identical to 0252 EXCEPT the single new anchor INSERT inside the apply sub-block (marked ANCHOR
-- AUTHORITY). Every other line — validation, idempotency, audit, envelope, ACL — is unchanged.
create or replace function public.location_create(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_fields    jsonb;
  v_details   jsonb := '[]'::jsonb;
  v_zone_raw  text;
  v_zone_id   uuid;
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
             'command_type', 'location_create', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  v_fields := p_payload->'fields';
  if v_fields is null or jsonb_typeof(v_fields) <> 'object' then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'invalid_payload', 'field', null, 'message', 'payload.fields must be a JSON object.'));
  else
    v_zone_raw := btrim(coalesce(v_fields->>'zone_id', ''));
    if v_zone_raw = '' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_zone', 'field', 'zone_id',
        'message', 'zone_id is required — a new location must be created inside an existing zone.'));
    else
      begin
        v_zone_id := v_zone_raw::uuid;
      exception when invalid_text_representation then
        v_zone_id := null;
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'invalid_zone', 'field', 'zone_id',
          'message', 'zone_id ''' || v_zone_raw || ''' is not a valid uuid.'));
      end;
      if v_zone_id is not null
         and not exists (select 1 from public.zones where id = v_zone_id) then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'invalid_zone', 'field', 'zone_id',
          'message', 'No zone with id ''' || v_zone_raw || ''' exists — pick an existing zone.'));
      end if;
    end if;

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

    if jsonb_typeof(v_fields->'x') is distinct from 'number' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'numeric_not_finite', 'field', 'x', 'message', 'x must be a finite number.'));
    else
      v_x := (v_fields->'x')::numeric;
      if v_x < -10000 or v_x > 10000 then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'coord_out_of_bounds', 'field', 'x', 'message', 'x must be within ±10000.'));
      end if;
    end if;

    if jsonb_typeof(v_fields->'y') is distinct from 'number' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'numeric_not_finite', 'field', 'y', 'message', 'y must be a finite number.'));
    else
      v_y := (v_fields->'y')::numeric;
      if v_y < -10000 or v_y > 10000 then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'coord_out_of_bounds', 'field', 'y', 'message', 'y must be within ±10000.'));
      end if;
    end if;

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

  begin
    insert into public.locations
        (zone_id, name, location_type, activity_type, x, y, reward_tier, base_difficulty,
         min_power_required, is_public, territory_radius, status)
      values
        (v_zone_id, v_name, v_loc_type, v_act_type, v_x::double precision, v_y::double precision,
         v_tier::int, v_diff::double precision, v_minpow::double precision, v_public, v_radius,
         v_status)
      returning jsonb_build_object(
                  'id', id, 'zone_id', zone_id, 'name', name, 'location_type', location_type,
                  'activity_type', activity_type, 'x', x, 'y', y, 'reward_tier', reward_tier,
                  'base_difficulty', base_difficulty, 'min_power_required', min_power_required,
                  'is_public', is_public, 'territory_radius', territory_radius, 'status', status,
                  'max_presence_seconds', max_presence_seconds, 'created_at', created_at),
                id
        into v_after, v_id;

    -- ── ANCHOR AUTHORITY (new): the created location's coordinate lives in space_anchors from birth. One
    -- active location-kind anchor at the SAME (x,y) the location was written with (both ::double precision,
    -- so anchor.space_x == locations.x exactly). Same sub-block ⇒ if this fails, the location INSERT rolls
    -- back too — a location can never exist without its anchor. A brand-new id has no prior anchor, so the
    -- one-active-per-location partial unique index cannot fire here.
    insert into public.space_anchors (kind, location_id, space_x, space_y, status)
      values ('location', v_id, v_x::double precision, v_y::double precision, 'active');

    v_result := jsonb_build_object('created', true, 'id', v_id, 'name', v_name);

    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'location_create', 'location', v_id::text, v_result::text,
         null, v_after, p_payload->>'source_revision');
  exception when unique_violation then
    get stacked diagnostics v_conflict_table = TABLE_NAME;
    if v_conflict_table = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'location_create', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'conflict',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'duplicate_name', 'field', 'name',
               'message', 'A location with this name already exists in the chosen zone.')));
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id,
           'command_type', 'location_create', 'result', v_result);
end $$;

revoke all on function public.location_create(text, jsonb) from public;
grant execute on function public.location_create(text, jsonb) to authenticated;  -- guard is in-body; NEVER anon
revoke insert, update, delete on table public.locations from anon, authenticated;

-- ── 3. location_update — 0249 body, REDEFINED to move the anchor when (and only when) x or y change ────────
-- Byte-identical to 0249 EXCEPT the marked ANCHOR AUTHORITY block inside the apply sub-block: on a real
-- coordinate change, RETIRE the current active anchor (active→retired, the ONE lifecycle transition the 0063
-- guard allows) and INSERT a new active anchor at the new (x,y) — never an in-place coordinate UPDATE. The
-- row-lock taken on the location (for update) serializes concurrent edits of the same location, so the
-- retire-then-insert can never race itself; the partial unique index is the backstop.
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

    if jsonb_typeof(v_fields->'x') is distinct from 'number' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'numeric_not_finite', 'field', 'x', 'message', 'x must be a finite number.'));
    else
      v_x := (v_fields->'x')::numeric;
      if v_x < -10000 or v_x > 10000 then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'coord_out_of_bounds', 'field', 'x', 'message', 'x must be within ±10000.'));
      end if;
    end if;

    if jsonb_typeof(v_fields->'y') is distinct from 'number' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'numeric_not_finite', 'field', 'y', 'message', 'y must be a finite number.'));
    else
      v_y := (v_fields->'y')::numeric;
      if v_y < -10000 or v_y > 10000 then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'coord_out_of_bounds', 'field', 'y', 'message', 'y must be within ±10000.'));
      end if;
    end if;

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

    -- ── ANCHOR AUTHORITY (new): keep the anchor in lock-step with the coordinate. ONLY when x or y actually
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

-- ── 4. get_world_map — 0263 body, TIGHTENED to FULL AUTHORITY: read the active anchor coord DIRECTLY via
--       INNER JOIN, no coalesce, no locations.x/y fallback. Payload shape, keys, ordering (l.name), grants,
--       SECURITY DEFINER + search_path all IDENTICAL to 0263 otherwise. Fail-CLOSED: an active location with
--       no active anchor is excluded (never rendered from a legacy coordinate). ───────────────────────────
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

grant execute on function public.get_world_map() to anon, authenticated;

-- ── 5. Self-assert (deploy-time; a raise aborts the migration txn — nothing half-applies) ─────────────────
do $$
declare
  v_locations int;
  v_active_locs int;
  v_anchors   int;
  v_n         int;
  v_src       text;
begin
  -- (a) vacuity guard.
  select count(*) into v_locations from public.locations;
  if v_locations = 0 then
    raise exception 'V1C-WRITE-AUTHORITY self-assert FAIL: no locations exist — the invariants would be vacuous';
  end if;

  -- (b) EVERY location has exactly ONE active anchor (the write authority + backfill precondition for the
  --     fail-closed INNER JOIN read). count(active location anchors) = count(locations), none missing.
  select count(*) into v_anchors
    from public.space_anchors where kind = 'location' and status = 'active';
  if v_anchors <> v_locations then
    raise exception 'V1C-WRITE-AUTHORITY self-assert FAIL: % active location anchor(s) for % location(s) — a location lacks (or doubles) an active anchor', v_anchors, v_locations;
  end if;
  if exists (select 1 from public.locations l
              where not exists (select 1 from public.space_anchors a
                                 where a.location_id = l.id and a.kind = 'location' and a.status = 'active')) then
    raise exception 'V1C-WRITE-AUTHORITY self-assert FAIL: a location has no active anchor — the fail-closed read would drop it';
  end if;

  -- (c) exactly ONE active anchor per location (no duplicates) — the INNER JOIN relies on it to not multiply.
  select count(*) into v_n
    from (select location_id from public.space_anchors
           where kind = 'location' and status = 'active'
           group by location_id having count(*) > 1) dup;
  if v_n <> 0 then
    raise exception 'V1C-WRITE-AUTHORITY self-assert FAIL: % location(s) with more than one active anchor', v_n;
  end if;

  -- (d) every active anchor coord EXACTLY equals its location's (x,y) — byte-identity precondition still holds
  --     world-wide after the backfill (nothing was scaled/moved).
  select count(*) into v_n
    from public.space_anchors a
    join public.locations l on l.id = a.location_id
   where a.kind = 'location' and a.status = 'active'
     and (a.space_x is distinct from l.x or a.space_y is distinct from l.y);
  if v_n <> 0 then
    raise exception 'V1C-WRITE-AUTHORITY self-assert FAIL: % active anchor(s) differ from their location''s exact (x,y) — a coordinate was moved; refuse', v_n;
  end if;

  -- (e) the READ is now FAIL-CLOSED: get_world_map reads the anchor coord DIRECTLY (no coalesce, no
  --     locations.x/y fallback), via the active-anchor INNER JOIN, still SECURITY DEFINER + all three
  --     status='active' filters + territory_radius + client grants.
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.get_world_map()')::oid;
  if v_src is null then
    raise exception 'V1C-WRITE-AUTHORITY self-assert FAIL: public.get_world_map() does not exist';
  end if;
  if position('coalesce(a.space_x' in v_src) <> 0 or position('coalesce(a.space_y' in v_src) <> 0 then
    raise exception 'V1C-WRITE-AUTHORITY self-assert FAIL: get_world_map() still has a coalesce anchor fallback — it is not fail-closed';
  end if;
  if position('''x'', a.space_x' in v_src) = 0 or position('''y'', a.space_y' in v_src) = 0 then
    raise exception 'V1C-WRITE-AUTHORITY self-assert FAIL: get_world_map() does not emit the anchor coordinate directly';
  end if;
  if position('join public.space_anchors a' in v_src) = 0 then
    raise exception 'V1C-WRITE-AUTHORITY self-assert FAIL: get_world_map() does not INNER JOIN the active anchor';
  end if;
  if not (select p.prosecdef from pg_proc p where p.oid = to_regprocedure('public.get_world_map()')::oid) then
    raise exception 'V1C-WRITE-AUTHORITY self-assert FAIL: get_world_map() is not SECURITY DEFINER';
  end if;
  if position('l.zone_id = z.id and l.status = ''active''' in v_src) = 0
     or position('z.sector_id = se.id and z.status = ''active''' in v_src) = 0
     or position('se.status = ''active''' in v_src) = 0 then
    raise exception 'V1C-WRITE-AUTHORITY self-assert FAIL: get_world_map() lost a status=''active'' filter';
  end if;
  if position('''territory_radius'', l.territory_radius' in v_src) = 0 then
    raise exception 'V1C-WRITE-AUTHORITY self-assert FAIL: get_world_map() no longer emits territory_radius';
  end if;
  if not has_function_privilege('anon', 'public.get_world_map()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_world_map()', 'execute') then
    raise exception 'V1C-WRITE-AUTHORITY self-assert FAIL: get_world_map() lost a client execute grant';
  end if;

  -- (f) the write RPCs are intact: both exist, SECURITY DEFINER, authenticated-only, anon-denied, and now
  --     write the anchor (the new INSERT/RETIRE lines are in their bodies).
  if not (select p.prosecdef from pg_proc p where p.oid = 'public.location_create(text,jsonb)'::regprocedure) then
    raise exception 'V1C-WRITE-AUTHORITY self-assert FAIL: location_create is not SECURITY DEFINER';
  end if;
  if not (select p.prosecdef from pg_proc p where p.oid = 'public.location_update(text,jsonb)'::regprocedure) then
    raise exception 'V1C-WRITE-AUTHORITY self-assert FAIL: location_update is not SECURITY DEFINER';
  end if;
  select prosrc into v_src from pg_proc where oid = 'public.location_create(text,jsonb)'::regprocedure;
  if position('insert into public.space_anchors' in v_src) = 0 then
    raise exception 'V1C-WRITE-AUTHORITY self-assert FAIL: location_create does not write a space_anchor';
  end if;
  select prosrc into v_src from pg_proc where oid = 'public.location_update(text,jsonb)'::regprocedure;
  if position('insert into public.space_anchors' in v_src) = 0
     or position('set status = ''retired''' in v_src) = 0 then
    raise exception 'V1C-WRITE-AUTHORITY self-assert FAIL: location_update does not retire+insert the anchor on a coordinate change';
  end if;
  if has_function_privilege('anon', 'public.location_create(text,jsonb)', 'execute')
     or has_function_privilege('anon', 'public.location_update(text,jsonb)', 'execute') then
    raise exception 'V1C-WRITE-AUTHORITY self-assert FAIL: anon can execute a location write RPC — must be authenticated-only';
  end if;

  -- (g) no client-role write grant on locations survived (the only write path is the SECURITY DEFINER surface);
  --     SELECT survives (the map read depends on it).
  if has_table_privilege('authenticated', 'public.locations', 'INSERT')
     or has_table_privilege('authenticated', 'public.locations', 'UPDATE')
     or has_table_privilege('authenticated', 'public.locations', 'DELETE')
     or has_table_privilege('anon', 'public.locations', 'INSERT')
     or has_table_privilege('anon', 'public.locations', 'UPDATE')
     or has_table_privilege('anon', 'public.locations', 'DELETE') then
    raise exception 'V1C-WRITE-AUTHORITY self-assert FAIL: a client role holds a locations write grant';
  end if;
  if not has_table_privilege('anon', 'public.locations', 'SELECT')
     or not has_table_privilege('authenticated', 'public.locations', 'SELECT') then
    raise exception 'V1C-WRITE-AUTHORITY self-assert FAIL: a client role lost SELECT on locations — the map read would break';
  end if;

  -- (h) space_anchors stays server-private: no client write/read grant regained.
  if has_table_privilege('anon', 'public.space_anchors', 'SELECT')
     or has_table_privilege('authenticated', 'public.space_anchors', 'SELECT')
     or has_table_privilege('anon', 'public.space_anchors', 'INSERT')
     or has_table_privilege('authenticated', 'public.space_anchors', 'INSERT')
     or has_table_privilege('anon', 'public.space_anchors', 'UPDATE')
     or has_table_privilege('authenticated', 'public.space_anchors', 'UPDATE') then
    raise exception 'V1C-WRITE-AUTHORITY self-assert FAIL: a client role holds a grant on the server-private space_anchors';
  end if;

  select count(*) into v_active_locs from public.locations where status = 'active';
  raise notice 'V1C-WRITE-AUTHORITY self-assert ok: %/% locations anchored (exactly one active each, coords == locations.x/y), % active; get_world_map fail-closed on the active anchor (no coalesce, SECURITY DEFINER, filters+territory_radius+grants intact); location_create/update write the anchor atomically; locations writes client-revoked (SELECT intact); space_anchors server-private',
    v_anchors, v_locations, v_active_locs;
end $$;
