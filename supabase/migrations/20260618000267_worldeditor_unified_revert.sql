-- Byeharu — WORLD EDITOR: the ONE server-authoritative REVERT authority — world_editor_revert.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT THIS IS: a single owner-gated SECURITY DEFINER command that reverts an AUDITED entity to its
-- recorded before_snapshot state, across ALL FOUR editable domains (location / mining_field /
-- exploration_site / zone), through the 0243 spine. Revert is ONE concept and belongs on ONE
-- authority (NO-SPAGHETTI: one authority per concept, compose don't fork). It cannot live on the
-- client because the client CANNOT reconstruct the historical state:
--   • mining / exploration reverts need reward_bundle_json — server-only loot (0098/0103 RLS
--     no-client-grant) that the audit READER (world_editor_audit_list, 0256) deliberately STRIPS
--     from every browser payload;
--   • zone reverts need the fork-time boundary, stored in the snapshot as WKT (ST_AsText) — not the
--     draft geometry union the client authored.
-- The RAW world_editor_audit row DOES carry both (reward_bundle_json in the snapshot, boundary as
-- boundary_wkt) — only the READER strips them. So this SECURITY DEFINER command reads the RAW row by
-- id and re-applies the historical state server-side, exactly the way each domain's *_update RPC
-- applies its edit (reusing every apply pattern: the 0264 location anchor retire+insert on a coord
-- change; the 0265 canonical_coord_violation gate; the historical reward_bundle_json write; the WKT
-- boundary re-materialization through the authoritative ST_IsValid/ST_Area gate).
--
-- WHAT IT REVERTS (in scope): an UPDATE command with a non-null before_snapshot —
--   location_update / mining_field_update / exploration_site_update / zone_update.
-- Anything else is typed and refused, nothing written:
--   • a create / set_active / unpublish audit (before_snapshot semantics differ) → 'not_revertable';
--   • an audit id that names no row                                              → 'not_found';
--   • the audited live row no longer exists                                      → 'source_missing';
--   • the historical value is now invalid (e.g. a retired enum, a deleted attach) → 'validation_failed'.
-- Create / set_active / unpublish reverts are OUT OF SCOPE (deferred).
--
-- REVERT SEMANTICS — INTENTIONAL OVERWRITE (documented, confirmed): a revert always overwrites the
-- CURRENT live row with the historical before_snapshot, guarded ONLY by owner + existence — NOT by
-- optimistic concurrency. Unlike the *_update RPCs (which reject a stale `expected` fork), a revert
-- is a deliberate "put it back the way it was" and MUST win even if the row changed since. The
-- `expected` baseline is therefore DERIVED SERVER-SIDE from the CURRENT live row (locked FOR UPDATE)
-- and becomes the new audit row's before_snapshot — the only guards are is_owner() and the live
-- row's continued existence. This is the intended semantic.
--
-- SELF-REVERTABLE AUDIT: the revert writes EXACTLY ONE new world_editor_audit row whose command_type
-- is the DOMAIN's update command (e.g. 'location_update'), before_snapshot = the CURRENT live values
-- (pre-revert), after_snapshot = the reverted values. So History renders the revert as a normal
-- update AND the revert itself is revertable.
--
-- TOUCHES ONLY the target entity's own table (+ its space_anchor for a location coordinate change).
-- NEVER touches the 0239-locked pirate_zone_* surface; widens NO client grant (the writes happen only
-- inside this SECURITY DEFINER body); re-asserts the client write-path revokes on the four target
-- tables idempotently (the 0254 production-GRANT-ALL-drift lesson).
--
-- DEPLOY POSTURE: UNDEPLOYED — deploy is a human gate. Fail-closed by design: even deployed, the
-- capability is inert until an owner is seeded into app_owners (is_owner() is false for everyone on an
-- unseeded DB). This is a GATED migration slice; it re-applies historical state to LIVE rows.
--
-- NO-SPAGHETTI: no second owner check (is_owner() only), no second audit ledger, no second
-- idempotency key, no second coordinate/geometry validator (canonical_coord_violation + PostGIS are
-- the authorities), no reuse of any gameplay/map RPC, no client code change (the client cutover that
-- routes the History revert button through this RPC is a FOLLOW-UP PR). The four *_update RPCs, the
-- audit reader, and world_editor_ping are left byte-identical.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. dependency gate — abort loudly if a surface this slice builds on is missing ────────────────
do $pubdep$
begin
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'WORLDEDIT-REVERT: public.world_editor_audit (0243) is missing — the audit spine must exist first';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'WORLDEDIT-REVERT: public.is_owner() (0243) is missing — THE ONE owner guard must exist first';
  end if;
  if to_regprocedure('public.canonical_coord_violation(jsonb, jsonb, text, text)') is null then
    raise exception 'WORLDEDIT-REVERT: public.canonical_coord_violation (0265) is missing — the ONE coord authority the point domains reuse';
  end if;
  if to_regprocedure('public.location_update(text, jsonb)') is null
     or to_regprocedure('public.mining_field_update(text, jsonb)') is null
     or to_regprocedure('public.exploration_site_update(text, jsonb)') is null
     or to_regprocedure('public.zone_update(text, jsonb)') is null then
    raise exception 'WORLDEDIT-REVERT: a domain *_update RPC (0247/0248/0249/0266) is missing — the apply patterns this mirrors must exist';
  end if;
  if to_regclass('public.locations') is null or to_regclass('public.mining_fields') is null
     or to_regclass('public.exploration_sites') is null or to_regclass('public.danger_zones') is null then
    raise exception 'WORLDEDIT-REVERT: a target domain table (locations/mining_fields/exploration_sites/danger_zones) is missing';
  end if;
  if to_regclass('public.space_anchors') is null then
    raise exception 'WORLDEDIT-REVERT: public.space_anchors (0063) is missing — the location revert honors the 0264 anchor authority';
  end if;
  if to_regprocedure('public.st_geomfromtext(text)') is null
     or to_regprocedure('public.st_isvalid(public.geometry)') is null
     or to_regprocedure('public.st_area(public.geometry)') is null
     or to_regprocedure('public.st_astext(public.geometry)') is null then
    raise exception 'WORLDEDIT-REVERT: a PostGIS function (st_geomfromtext/st_isvalid/st_area/st_astext) is missing — the zone revert rebuilds the WKT boundary';
  end if;
  if not exists (select 1 from pg_attribute where attrelid = 'public.world_editor_audit'::regclass
                   and attname = 'before_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'after_snapshot' and not attisdropped) then
    raise exception 'WORLDEDIT-REVERT: a 0244 audit snapshot column (before_snapshot/after_snapshot) is missing';
  end if;
  if to_regprocedure('public.pirate_zone_create(text, jsonb, uuid)') is null
     or to_regprocedure('public.pirate_zone_delete(uuid)') is null then
    raise exception 'WORLDEDIT-REVERT: a 0239 pirate_zone write RPC is missing — the lockdown surface must exist to be re-asserted';
  end if;
end $pubdep$;

-- ── 1. world_editor_revert — the ONE cross-domain revert authority ────────────────────────────────
-- TYPED RESULT/ERROR CONTRACT:
--   success : {ok:true,  request_id, command_type:<domain update>, result:{reverted:true,id,name,from_audit_id}}
--   replay  : {ok:true,  request_id, command_type:<stored>, replayed:true, code:'duplicate_request', result:<prior jsonb>}
--   failure : {ok:false, request_id, error:<code> [, details:[{code,field,message}...]]}  where code ∈
--             { 'not_authenticated'          -- no JWT subject (anonymous)
--             , 'not_authorized'             -- authenticated but not an owner
--             , 'invalid_request'            -- missing/blank request_id or null p_audit_id
--             , 'not_found'                  -- p_audit_id names no audit row (details: audit_not_found)
--             , 'not_revertable'             -- not an UPDATE-with-before_snapshot (create/set_active/unpublish/malformed)
--             , 'source_missing'             -- the audited live row no longer exists (nothing to overwrite)
--             , 'validation_failed'          -- a historical value is now invalid (enum retired / attach deleted / bad geometry)
--             , 'conflict'                   -- restoring a name re-collides (mining/exploration unique name)
--             }
create or replace function public.world_editor_revert(p_request_id text, p_audit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_cmd       text;          -- the audited command_type (drives dispatch + the new audit row's command_type)
  v_ttype     text;
  v_tid       text;
  v_target_id uuid;
  v_before    jsonb;         -- the RAW historical before_snapshot we re-apply (carries reward_bundle_json / boundary_wkt)
  v_details   jsonb := '[]'::jsonb;
  v_prior     text;
  v_prior_cmd text;
  v_live      record;        -- the LOCKED current live row
  v_pre       jsonb;         -- CURRENT live values pre-revert (the new audit before_snapshot)
  v_after     jsonb;         -- the reverted row (the new audit after_snapshot)
  v_result    jsonb;
  v_id        uuid;
  v_name      text;
  v_conflict_table text;
  -- location domain
  v_loc_type  text; v_act_type text; v_status text;
  v_x numeric; v_y numeric; v_tier numeric; v_diff numeric; v_minpow numeric; v_radius numeric;
  v_public boolean;
  -- point (mining / exploration) domain
  v_bundle jsonb; v_items jsonb; v_item jsonb; v_i int;
  -- zone domain
  v_attach uuid; v_attach_raw text; v_wkt text; v_boundary public.geometry;
begin
  -- (1) authn — reject the anonymous caller with a typed code (no world touch).
  if v_uid is null then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authenticated');
  end if;

  -- (2) authz — THE ONE guard. A non-owner authenticated caller is rejected server-side.
  if not public.is_owner() then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authorized');
  end if;

  -- (3) request_id (the idempotency key) and p_audit_id (the target) must both be present.
  if p_request_id is null or length(btrim(p_request_id)) = 0 or p_audit_id is null then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;

  -- (4) idempotent replay: a prior row for this request_id ⇒ return its result (no second apply). The
  -- stored command_type is echoed (a revert row carries the domain's update command_type).
  select result, command_type into v_prior, v_prior_cmd
    from public.world_editor_audit where request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'request_id', p_request_id,
             'command_type', v_prior_cmd, 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  -- (5) read the RAW audited row by id (this row DOES carry reward_bundle_json + boundary_wkt — only
  -- the reader world_editor_audit_list strips them). A missing id is a typed not_found.
  select command_type, target_type, target_id, before_snapshot
    into v_cmd, v_ttype, v_tid, v_before
    from public.world_editor_audit where id = p_audit_id;
  if not found then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_found',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'audit_not_found', 'field', 'p_audit_id',
               'message', 'No world_editor_audit row with id ''' || p_audit_id::text || ''' exists.')));
  end if;

  -- (6) REVERTABLE ONLY when it is an UPDATE command carrying a non-null before_snapshot. Create /
  -- set_active / unpublish (before_snapshot null or different semantics) are OUT OF SCOPE → not_revertable.
  if v_cmd not in ('location_update', 'mining_field_update', 'exploration_site_update', 'zone_update')
     or v_before is null or jsonb_typeof(v_before) <> 'object' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_revertable',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'not_revertable', 'field', 'command_type',
               'message', 'Audit command ''' || coalesce(v_cmd, '(null)')
                          || ''' is not a revertable UPDATE with a before_snapshot (create/set_active/unpublish are out of scope).')));
  end if;

  -- (6b) our update rows always carry the row uuid in target_id; a non-uuid is a malformed audit row.
  begin
    v_target_id := v_tid::uuid;
  exception when others then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_revertable',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'not_revertable', 'field', 'target_id',
               'message', 'The audit row''s target_id is not a uuid — not a revertable update.')));
  end;

  -- ════════════════════════════════ LOCATION revert ════════════════════════════════
  -- Mirrors location_update (0249) + the 0264 anchor write-authority: re-apply the 11 fields from
  -- before_snapshot; a coordinate change goes through the anchor RETIRE+INSERT path (never a raw x/y
  -- write, or the fail-closed get_world_map would drop/mis-locate the row); coords via the 0265 gate.
  if v_cmd = 'location_update' then
    select id, zone_id, name, location_type, activity_type, x, y, reward_tier, base_difficulty,
           min_power_required, is_public, territory_radius, status, max_presence_seconds, created_at
      into v_live
      from public.locations
     where id = v_target_id
       for update;
    if not found then
      return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'source_missing',
               'details', jsonb_build_array(jsonb_build_object(
                 'code', 'source_missing', 'field', null,
                 'message', 'The location to revert no longer exists.')));
    end if;

    -- SERVER-SIDE re-validation of the HISTORICAL values (same rules location_update enforces). If a
    -- historical value is now invalid (e.g. a retired enum) it is a typed validation_failed, not a write.
    v_name := btrim(coalesce(v_before->>'name', ''));
    if v_name = '' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'name_required', 'field', 'name', 'message', 'Name is required (locations.name is NOT NULL).'));
    end if;
    v_loc_type := v_before->>'location_type';
    if v_loc_type is null or v_loc_type not in
       ('pirate_hunt','pirate_den','mining_site','derelict_station','trade_outpost','rally_point','safe_zone','event_site') then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_location_type', 'field', 'location_type',
        'message', 'Location type ''' || coalesce(v_loc_type, '(missing)') || ''' is not allowed by the live CHECK constraint.'));
    end if;
    v_act_type := v_before->>'activity_type';
    if v_act_type is null or v_act_type not in
       ('hunt_pirates','mine_resource','explore_derelict','trade_visit','rally','none') then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_activity_type', 'field', 'activity_type',
        'message', 'Activity type ''' || coalesce(v_act_type, '(missing)') || ''' is not allowed by the live CHECK constraint.'));
    end if;
    v_status := v_before->>'status';
    if v_status is null or v_status not in ('active','locked','hidden') then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_status', 'field', 'status',
        'message', 'Status ''' || coalesce(v_status, '(missing)') || ''' is not allowed — must be one of active, locked, hidden.'));
    end if;
    -- coordinates — THE ONE canonical ±10000 authority (0265), same as location_update.
    v_details := v_details || public.canonical_coord_violation(v_before->'x', v_before->'y', 'x', 'y');
    if jsonb_typeof(v_before->'reward_tier') is distinct from 'number' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'numeric_not_finite', 'field', 'reward_tier', 'message', 'reward_tier must be a finite number.'));
    else
      v_tier := (v_before->'reward_tier')::numeric;
      if v_tier < 0 then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'reward_tier_negative', 'field', 'reward_tier', 'message', 'Reward tier must be >= 0.'));
      elsif (v_tier % 1) <> 0 then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'reward_tier_not_integer', 'field', 'reward_tier', 'message', 'Reward tier must be an integer.'));
      end if;
    end if;
    if jsonb_typeof(v_before->'base_difficulty') is distinct from 'number' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'numeric_not_finite', 'field', 'base_difficulty', 'message', 'base_difficulty must be a finite number.'));
    else
      v_diff := (v_before->'base_difficulty')::numeric;
      if v_diff < 0 then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'base_difficulty_negative', 'field', 'base_difficulty', 'message', 'Difficulty must be >= 0.'));
      end if;
    end if;
    if jsonb_typeof(v_before->'min_power_required') is distinct from 'number' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'numeric_not_finite', 'field', 'min_power_required', 'message', 'min_power_required must be a finite number.'));
    else
      v_minpow := (v_before->'min_power_required')::numeric;
      if v_minpow < 0 then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'min_power_negative', 'field', 'min_power_required', 'message', 'Min power must be >= 0.'));
      end if;
    end if;
    if v_before->'territory_radius' is null or jsonb_typeof(v_before->'territory_radius') = 'null' then
      v_radius := null;
    elsif jsonb_typeof(v_before->'territory_radius') <> 'number' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'numeric_not_finite', 'field', 'territory_radius', 'message', 'territory_radius must be a finite number (or null for no territory).'));
    else
      v_radius := (v_before->'territory_radius')::numeric;
      if v_radius <= 0 then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'territory_radius_not_positive', 'field', 'territory_radius',
          'message', 'Territory radius must be greater than 0 (null for no territory).'));
      end if;
    end if;
    if jsonb_typeof(v_before->'is_public') is distinct from 'boolean' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_payload', 'field', 'is_public', 'message', 'is_public must be a boolean.'));
    else
      v_public := (v_before->'is_public')::boolean;
    end if;

    if jsonb_array_length(v_details) > 0 then
      return jsonb_build_object('ok', false, 'request_id', p_request_id,
               'error', 'validation_failed', 'details', v_details);
    end if;

    v_x := (v_before->'x')::numeric;
    v_y := (v_before->'y')::numeric;

    -- the new audit before_snapshot = the CURRENT live values (the `expected` baseline, server-derived).
    v_pre := jsonb_build_object(
               'id', v_live.id, 'zone_id', v_live.zone_id, 'name', v_live.name,
               'location_type', v_live.location_type, 'activity_type', v_live.activity_type,
               'x', v_live.x, 'y', v_live.y, 'reward_tier', v_live.reward_tier,
               'base_difficulty', v_live.base_difficulty, 'min_power_required', v_live.min_power_required,
               'is_public', v_live.is_public, 'territory_radius', v_live.territory_radius,
               'status', v_live.status, 'max_presence_seconds', v_live.max_presence_seconds,
               'created_at', v_live.created_at);
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

      -- ── ANCHOR AUTHORITY (0264): a coordinate change is RETIRE the active anchor + INSERT a new
      -- active one — NEVER a raw space_x/space_y write. Only when x or y actually differ from the
      -- LOCKED live coordinate (both ::double precision to match storage). A non-coordinate revert
      -- leaves the anchor untouched. Mirrors location_update exactly.
      if v_x::double precision is distinct from v_live.x
         or v_y::double precision is distinct from v_live.y then
        update public.space_anchors
           set status = 'retired'
         where location_id = v_live.id and kind = 'location' and status = 'active';
        insert into public.space_anchors (kind, location_id, space_x, space_y, status)
          values ('location', v_live.id, v_x::double precision, v_y::double precision, 'active');
      end if;

      v_result := jsonb_build_object('reverted', true, 'id', v_id, 'name', v_name, 'from_audit_id', p_audit_id);

      insert into public.world_editor_audit
          (actor, request_id, command_type, target_type, target_id, result,
           before_snapshot, after_snapshot, source_revision)
        values
          (v_uid, p_request_id, 'location_update', 'location', v_id::text, v_result::text,
           v_pre, v_after, 'revert:' || p_audit_id::text);
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

  -- ════════════════════════════ MINING FIELD revert ════════════════════════════
  -- Mirrors mining_field_update (0248): re-apply name, space_x, space_y, is_active, AND
  -- reward_bundle_json (from the RAW before_snapshot — server-only loot the reader strips; this is the
  -- whole reason revert is server-side). Coords via the 0265 canonical authority.
  elsif v_cmd = 'mining_field_update' then
    select id, name, space_x, space_y, reward_bundle_json, is_active, created_at
      into v_live
      from public.mining_fields
     where id = v_target_id
       for update;
    if not found then
      return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'source_missing',
               'details', jsonb_build_array(jsonb_build_object(
                 'code', 'source_missing', 'field', null,
                 'message', 'The mining field to revert no longer exists.')));
    end if;

    v_name := btrim(coalesce(v_before->>'name', ''));
    if v_name = '' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'name_required', 'field', 'name', 'message', 'Name is required (mining_fields.name is NOT NULL).'));
    end if;
    v_details := v_details || public.canonical_coord_violation(v_before->'space_x', v_before->'space_y', 'space_x', 'space_y');
    -- reward_bundle_json is NON-null in the snapshot (mining_fields.reward_bundle_json is NOT NULL);
    -- re-validate it as a real bundle (same rule mining_field_update applies to a non-null bundle).
    v_bundle := v_before->'reward_bundle_json';
    if v_bundle is null or jsonb_typeof(v_bundle) <> 'object' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'reward_bundle_invalid', 'field', 'reward_bundle_json',
        'message', 'reward_bundle_json must be a JSON object with a non-empty items[] list.'));
    elsif jsonb_typeof(v_bundle->'items') is distinct from 'array' or jsonb_array_length(v_bundle->'items') = 0 then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'reward_bundle_invalid', 'field', 'reward_bundle_json',
        'message', 'Reward bundle must carry a non-empty items[] list.'));
    else
      v_items := v_bundle->'items';
      for v_i in 0 .. jsonb_array_length(v_items) - 1 loop
        v_item := v_items->v_i;
        if jsonb_typeof(v_item) <> 'object' or btrim(coalesce(v_item->>'item_id', '')) = '' then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code', 'reward_bundle_invalid', 'field', 'reward_bundle_json',
            'message', 'Reward item #' || (v_i + 1) || ': item_id must be a non-empty string.'));
        end if;
        if jsonb_typeof(v_item) <> 'object'
           or jsonb_typeof(v_item->'quantity') is distinct from 'number'
           or (v_item->'quantity')::numeric <= 0
           or ((v_item->'quantity')::numeric % 1) <> 0 then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code', 'reward_bundle_invalid', 'field', 'reward_bundle_json',
            'message', 'Reward item #' || (v_i + 1) || ': quantity must be a positive integer.'));
        end if;
      end loop;
    end if;

    if jsonb_array_length(v_details) > 0 then
      return jsonb_build_object('ok', false, 'request_id', p_request_id,
               'error', 'validation_failed', 'details', v_details);
    end if;

    v_x := (v_before->'space_x')::numeric;
    v_y := (v_before->'space_y')::numeric;

    v_pre := jsonb_build_object(
               'id', v_live.id, 'name', v_live.name, 'space_x', v_live.space_x, 'space_y', v_live.space_y,
               'reward_bundle_json', v_live.reward_bundle_json, 'is_active', v_live.is_active,
               'created_at', v_live.created_at);
    begin
      update public.mining_fields
         set name               = v_name,
             space_x            = v_x::double precision,
             space_y            = v_y::double precision,
             is_active          = (v_before->>'is_active')::boolean,
             reward_bundle_json = v_bundle
       where id = v_live.id
       returning jsonb_build_object(
                   'id', id, 'name', name, 'space_x', space_x, 'space_y', space_y,
                   'reward_bundle_json', reward_bundle_json, 'is_active', is_active, 'created_at', created_at),
                 id
         into v_after, v_id;

      v_result := jsonb_build_object('reverted', true, 'id', v_id, 'name', v_name, 'from_audit_id', p_audit_id);

      insert into public.world_editor_audit
          (actor, request_id, command_type, target_type, target_id, result,
           before_snapshot, after_snapshot, source_revision)
        values
          (v_uid, p_request_id, 'mining_field_update', 'mining_field', v_id::text, v_result::text,
           v_pre, v_after, 'revert:' || p_audit_id::text);
    exception when unique_violation then
      get stacked diagnostics v_conflict_table = TABLE_NAME;
      if v_conflict_table = 'world_editor_audit' then
        select result into v_prior from public.world_editor_audit where request_id = p_request_id;
        return jsonb_build_object('ok', true, 'request_id', p_request_id,
                 'command_type', 'mining_field_update', 'replayed', true,
                 'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
      end if;
      return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'conflict',
               'details', jsonb_build_array(jsonb_build_object(
                 'code', 'duplicate_name', 'field', 'name',
                 'message', 'A mining field with this name already exists.')));
    end;

    return jsonb_build_object('ok', true, 'request_id', p_request_id,
             'command_type', 'mining_field_update', 'result', v_result);

  -- ════════════════════════ EXPLORATION SITE revert ════════════════════════
  -- Mirrors exploration_site_update (0247): identical to the mining twin over exploration_sites (the
  -- schema-identical table); re-applies reward_bundle_json from the RAW before_snapshot.
  elsif v_cmd = 'exploration_site_update' then
    select id, name, space_x, space_y, reward_bundle_json, is_active, created_at
      into v_live
      from public.exploration_sites
     where id = v_target_id
       for update;
    if not found then
      return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'source_missing',
               'details', jsonb_build_array(jsonb_build_object(
                 'code', 'source_missing', 'field', null,
                 'message', 'The exploration site to revert no longer exists.')));
    end if;

    v_name := btrim(coalesce(v_before->>'name', ''));
    if v_name = '' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'name_required', 'field', 'name', 'message', 'Name is required (exploration_sites.name is NOT NULL).'));
    end if;
    v_details := v_details || public.canonical_coord_violation(v_before->'space_x', v_before->'space_y', 'space_x', 'space_y');
    v_bundle := v_before->'reward_bundle_json';
    if v_bundle is null or jsonb_typeof(v_bundle) <> 'object' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'reward_bundle_invalid', 'field', 'reward_bundle_json',
        'message', 'reward_bundle_json must be a JSON object with a non-empty items[] list.'));
    elsif jsonb_typeof(v_bundle->'items') is distinct from 'array' or jsonb_array_length(v_bundle->'items') = 0 then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'reward_bundle_invalid', 'field', 'reward_bundle_json',
        'message', 'Reward bundle must carry a non-empty items[] list.'));
    else
      v_items := v_bundle->'items';
      for v_i in 0 .. jsonb_array_length(v_items) - 1 loop
        v_item := v_items->v_i;
        if jsonb_typeof(v_item) <> 'object' or btrim(coalesce(v_item->>'item_id', '')) = '' then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code', 'reward_bundle_invalid', 'field', 'reward_bundle_json',
            'message', 'Reward item #' || (v_i + 1) || ': item_id must be a non-empty string.'));
        end if;
        if jsonb_typeof(v_item) <> 'object'
           or jsonb_typeof(v_item->'quantity') is distinct from 'number'
           or (v_item->'quantity')::numeric <= 0
           or ((v_item->'quantity')::numeric % 1) <> 0 then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code', 'reward_bundle_invalid', 'field', 'reward_bundle_json',
            'message', 'Reward item #' || (v_i + 1) || ': quantity must be a positive integer.'));
        end if;
      end loop;
    end if;

    if jsonb_array_length(v_details) > 0 then
      return jsonb_build_object('ok', false, 'request_id', p_request_id,
               'error', 'validation_failed', 'details', v_details);
    end if;

    v_x := (v_before->'space_x')::numeric;
    v_y := (v_before->'space_y')::numeric;

    v_pre := jsonb_build_object(
               'id', v_live.id, 'name', v_live.name, 'space_x', v_live.space_x, 'space_y', v_live.space_y,
               'reward_bundle_json', v_live.reward_bundle_json, 'is_active', v_live.is_active,
               'created_at', v_live.created_at);
    begin
      update public.exploration_sites
         set name               = v_name,
             space_x            = v_x::double precision,
             space_y            = v_y::double precision,
             is_active          = (v_before->>'is_active')::boolean,
             reward_bundle_json = v_bundle
       where id = v_live.id
       returning jsonb_build_object(
                   'id', id, 'name', name, 'space_x', space_x, 'space_y', space_y,
                   'reward_bundle_json', reward_bundle_json, 'is_active', is_active, 'created_at', created_at),
                 id
         into v_after, v_id;

      v_result := jsonb_build_object('reverted', true, 'id', v_id, 'name', v_name, 'from_audit_id', p_audit_id);

      insert into public.world_editor_audit
          (actor, request_id, command_type, target_type, target_id, result,
           before_snapshot, after_snapshot, source_revision)
        values
          (v_uid, p_request_id, 'exploration_site_update', 'exploration_site', v_id::text, v_result::text,
           v_pre, v_after, 'revert:' || p_audit_id::text);
    exception when unique_violation then
      get stacked diagnostics v_conflict_table = TABLE_NAME;
      if v_conflict_table = 'world_editor_audit' then
        select result into v_prior from public.world_editor_audit where request_id = p_request_id;
        return jsonb_build_object('ok', true, 'request_id', p_request_id,
                 'command_type', 'exploration_site_update', 'replayed', true,
                 'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
      end if;
      return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'conflict',
               'details', jsonb_build_array(jsonb_build_object(
                 'code', 'duplicate_name', 'field', 'name',
                 'message', 'An exploration site with this name already exists.')));
    end;

    return jsonb_build_object('ok', true, 'request_id', p_request_id,
             'command_type', 'exploration_site_update', 'result', v_result);

  -- ════════════════════════════════ ZONE revert ════════════════════════════════════
  -- Mirrors zone_update (0266): the before_snapshot stores the boundary as WKT (boundary_wkt =
  -- ST_AsText). Reconstruct it DIRECTLY via ST_GeomFromText (danger_zones.boundary is geometry(Polygon)
  -- SRID 0 — a flat game grid, no CRS), re-apply name + attach location_id + boundary, and re-run the
  -- authoritative ST_IsValid + ST_Area>0 gate. NOT through the draft geometry union (the WKT is already
  -- a materialized valid polygon). Only editor-created source='drawn' zones are revertable.
  elsif v_cmd = 'zone_update' then
    select id, name, zone_kind, source, location_id, boundary, status, created_by, created_at
      into v_live
      from public.danger_zones
     where id = v_target_id
       for update;
    if not found then
      return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'source_missing',
               'details', jsonb_build_array(jsonb_build_object(
                 'code', 'source_missing', 'field', null,
                 'message', 'The zone to revert no longer exists.')));
    end if;

    -- SEEDED-ZONE PROTECTION (the 0266/0255 guard): only source='drawn' zones are editable/revertable.
    if v_live.source <> 'drawn' then
      return jsonb_build_object('ok', false, 'request_id', p_request_id,
               'error', 'validation_failed', 'details', jsonb_build_array(jsonb_build_object(
                 'code', 'protected_zone', 'field', 'source',
                 'message', 'Only editor-created (source=''drawn'') zones can be reverted; this is a seeded zone.')));
    end if;

    -- name — required, 1..60 (the danger_zones CHECK; same rule zone_update enforces).
    v_name := btrim(coalesce(v_before->>'name', ''));
    if v_name = '' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'name_required', 'field', 'name', 'message', 'Name is required — a zone must be nameable on the map.'));
    elsif char_length(v_name) > 60 then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'name_too_long', 'field', 'name', 'message', 'Name must be at most 60 characters (the live CHECK constraint).'));
    end if;

    -- attach location_id — null = standalone; else an EXISTING ACTIVE pirate_hunt/pirate_den location
    -- (the 0266/0233 rule). A historical attach whose target was deleted is a typed invalid_attach, never
    -- a raw FK violation.
    if v_before->'location_id' is null or jsonb_typeof(v_before->'location_id') = 'null' then
      v_attach := null;
    else
      v_attach_raw := btrim(coalesce(v_before->>'location_id', ''));
      begin
        v_attach := v_attach_raw::uuid;
      exception when others then
        v_attach := null;
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'invalid_attach', 'field', 'attach_location_id',
          'message', 'The historical attach_location_id ''' || v_attach_raw || ''' is not a valid uuid.'));
      end;
      if v_attach is not null
         and not exists (select 1 from public.locations l
                          where l.id = v_attach and l.status = 'active'
                            and l.location_type in ('pirate_hunt', 'pirate_den')) then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'invalid_attach', 'field', 'attach_location_id',
          'message', 'The historical attach target ''' || v_attach_raw
                     || ''' is no longer an ACTIVE pirate_hunt/pirate_den location — cannot restore the attachment.'));
        v_attach := null;
      end if;
    end if;

    -- reconstruct the boundary from the stored WKT (the materialized fork-time polygon).
    v_wkt := v_before->>'boundary_wkt';
    if v_wkt is null or btrim(v_wkt) = '' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_geometry', 'field', 'geometry',
        'message', 'The audit snapshot carries no boundary geometry (boundary_wkt) to restore.'));
    else
      begin
        v_boundary := public.st_geomfromtext(v_wkt);
      exception when others then
        v_boundary := null;   -- an unparseable WKT falls through to the authoritative gate below
      end;
    end if;

    if jsonb_array_length(v_details) > 0 then
      return jsonb_build_object('ok', false, 'request_id', p_request_id,
               'error', 'validation_failed', 'details', v_details);
    end if;

    -- THE AUTHORITATIVE GEOMETRY GATE (identical to zone_create/zone_update): a valid, positive-area
    -- polygon or a typed rejection — never a write.
    if v_boundary is null or not public.st_isvalid(v_boundary) or not (public.st_area(v_boundary) > 0) then
      return jsonb_build_object('ok', false, 'request_id', p_request_id,
               'error', 'validation_failed', 'details', jsonb_build_array(jsonb_build_object(
                 'code', 'invalid_geometry', 'field', 'geometry',
                 'message', 'The restored boundary is not a valid, positive-area polygon.')));
    end if;

    v_pre := jsonb_build_object(
               'id', v_live.id, 'name', v_live.name, 'zone_kind', v_live.zone_kind,
               'source', v_live.source, 'location_id', v_live.location_id, 'status', v_live.status,
               'boundary_wkt', public.st_astext(v_live.boundary), 'created_at', v_live.created_at);
    begin
      update public.danger_zones
         set boundary    = v_boundary,
             name        = v_name,
             location_id = v_attach,
             updated_at  = now()
       where id = v_live.id
       returning jsonb_build_object(
                   'id', id, 'name', name, 'zone_kind', zone_kind, 'source', source,
                   'location_id', location_id, 'status', status,
                   'boundary_wkt', public.st_astext(boundary), 'created_at', created_at),
                 id
         into v_after, v_id;

      v_result := jsonb_build_object('reverted', true, 'id', v_id, 'name', v_name, 'from_audit_id', p_audit_id);

      insert into public.world_editor_audit
          (actor, request_id, command_type, target_type, target_id, result,
           before_snapshot, after_snapshot, source_revision)
        values
          (v_uid, p_request_id, 'zone_update', 'zone', v_id::text, v_result::text,
           v_pre, v_after, 'revert:' || p_audit_id::text);
    exception when unique_violation then
      get stacked diagnostics v_conflict_table = TABLE_NAME;
      if v_conflict_table = 'world_editor_audit' then
        select result into v_prior from public.world_editor_audit where request_id = p_request_id;
        return jsonb_build_object('ok', true, 'request_id', p_request_id,
                 'command_type', 'zone_update', 'replayed', true,
                 'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
      end if;
      raise;   -- danger_zones has no unique natural key — any other unique_violation is a real anomaly.
    end;

    return jsonb_build_object('ok', true, 'request_id', p_request_id,
             'command_type', 'zone_update', 'result', v_result);
  end if;

  -- unreachable: the revertable set is exhaustively dispatched above (a non-revertable command_type is
  -- already refused at step (6)). Fail loudly rather than return a silent null envelope.
  return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_revertable',
           'details', jsonb_build_array(jsonb_build_object(
             'code', 'not_revertable', 'field', 'command_type',
             'message', 'Unhandled revert command_type ''' || coalesce(v_cmd, '(null)') || '''.')));
end $$;

comment on function public.world_editor_revert(text, uuid) is
  'WORLD EDITOR (0267): the ONE server-authoritative cross-domain REVERT command. Owner-gated via '
  'is_owner() (0243), SECURITY DEFINER, search_path='''', authenticated-only. Reads the RAW '
  'world_editor_audit row by id (which carries reward_bundle_json + boundary_wkt — only the reader '
  'strips them), reverts the audited entity to its before_snapshot, and mirrors each domain''s *_update '
  'apply pattern: location (the 11 fields + the 0264 anchor retire+insert on a coord change), '
  'mining/exploration (name/coords + the server-only reward_bundle_json, coords via the 0265 canonical '
  'authority), zone (name/attach + the WKT boundary re-materialized through ST_GeomFromText and the '
  'authoritative ST_IsValid/ST_Area gate; drawn zones only). REVERTABLE only for an UPDATE with a '
  'non-null before_snapshot (location_update/mining_field_update/exploration_site_update/zone_update); '
  'create/set_active/unpublish are not_revertable, a missing audit id is not_found, a vanished live row '
  'is source_missing. Intentional-overwrite semantics: guarded ONLY by owner + existence, NOT optimistic '
  'concurrency (the expected baseline is derived server-side from the current live row and becomes the '
  'new audit before_snapshot). request_id idempotency; writes EXACTLY ONE new audit row whose '
  'command_type is the domain''s update command (History shows a normal, itself-revertable update). '
  'Touches ONLY the target table (+ its anchor); NEVER the 0239-locked pirate_zone_*.';

-- ── 2. ACL — authenticated may CALL (the owner guard is in-body); anon/public may not. ────────────
revoke all on function public.world_editor_revert(text, uuid) from public;
grant execute on function public.world_editor_revert(text, uuid) to authenticated;  -- guard is in-body; NEVER anon

-- ── 2b. Re-assert the client write-path lockdown on the four target tables (idempotent; the 0254
-- production-GRANT-ALL-drift lesson). Revoking a privilege a role does not hold is a silent no-op, so
-- this keeps the fresh-chain apply-proof green and the privilege matrix unambiguous. SELECT is left
-- as-is (the map/zone reads depend on it). space_anchors is left to the 0063/0264 authority.
revoke insert, update, delete on table public.locations         from anon, authenticated;
revoke insert, update, delete on table public.mining_fields     from anon, authenticated;
revoke insert, update, delete on table public.exploration_sites from anon, authenticated;
revoke insert, update, delete on table public.danger_zones      from anon, authenticated;

-- ── 3. self-assert (deploy-time; any raise aborts the txn — nothing half-applies) ─────────────────
do $pubassert$
begin
  -- (a) the 0243 spine this command stands on exists.
  if to_regclass('public.app_owners') is null then
    raise exception 'WORLDEDIT-REVERT self-assert FAIL: app_owners missing';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'WORLDEDIT-REVERT self-assert FAIL: is_owner() missing';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'WORLDEDIT-REVERT self-assert FAIL: world_editor_audit missing';
  end if;
  if not exists (select 1 from pg_attribute where attrelid = 'public.world_editor_audit'::regclass
                   and attname = 'before_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'after_snapshot' and not attisdropped) then
    raise exception 'WORLDEDIT-REVERT self-assert FAIL: an audit snapshot column is missing';
  end if;

  -- (b) the command exists, is SECURITY DEFINER, pins search_path, and is authenticated-only.
  if to_regprocedure('public.world_editor_revert(text, uuid)') is null then
    raise exception 'WORLDEDIT-REVERT self-assert FAIL: world_editor_revert(text,uuid) missing';
  end if;
  if not exists (select 1 from pg_proc
                 where oid = 'public.world_editor_revert(text,uuid)'::regprocedure and prosecdef) then
    raise exception 'WORLDEDIT-REVERT self-assert FAIL: world_editor_revert is not SECURITY DEFINER';
  end if;
  if not exists (select 1 from pg_proc p
                 where p.oid = 'public.world_editor_revert(text,uuid)'::regprocedure
                   and exists (select 1 from unnest(p.proconfig) cfg where cfg like 'search_path=%')) then
    raise exception 'WORLDEDIT-REVERT self-assert FAIL: world_editor_revert does not pin search_path — a hijack would be possible';
  end if;
  if not has_function_privilege('authenticated', 'public.world_editor_revert(text,uuid)', 'execute') then
    raise exception 'WORLDEDIT-REVERT self-assert FAIL: authenticated cannot execute world_editor_revert — the in-body guard would be unreachable';
  end if;
  if has_function_privilege('anon', 'public.world_editor_revert(text,uuid)', 'execute') then
    raise exception 'WORLDEDIT-REVERT self-assert FAIL: anon CAN execute world_editor_revert — must be authenticated-only';
  end if;

  -- (c) the body writes ONLY the four target tables (+ space_anchors + the audit ledger) and NEVER the
  -- 0239-locked pirate_zone_* surface (a cheap, robust source-text guard).
  if position('pirate_zone' in pg_get_functiondef('public.world_editor_revert(text,uuid)'::regprocedure)) > 0 then
    raise exception 'WORLDEDIT-REVERT self-assert FAIL: body references pirate_zone — it must not touch the 0239-locked surface';
  end if;
  if position('public.locations' in pg_get_functiondef('public.world_editor_revert(text,uuid)'::regprocedure)) = 0
     or position('public.mining_fields' in pg_get_functiondef('public.world_editor_revert(text,uuid)'::regprocedure)) = 0
     or position('public.exploration_sites' in pg_get_functiondef('public.world_editor_revert(text,uuid)'::regprocedure)) = 0
     or position('public.danger_zones' in pg_get_functiondef('public.world_editor_revert(text,uuid)'::regprocedure)) = 0 then
    raise exception 'WORLDEDIT-REVERT self-assert FAIL: body does not reference all four target tables';
  end if;

  -- (d) the four domain *_update RPCs + the canonical coord authority are intact (untouched).
  if to_regprocedure('public.location_update(text, jsonb)') is null
     or to_regprocedure('public.mining_field_update(text, jsonb)') is null
     or to_regprocedure('public.exploration_site_update(text, jsonb)') is null
     or to_regprocedure('public.zone_update(text, jsonb)') is null
     or to_regprocedure('public.canonical_coord_violation(jsonb, jsonb, text, text)') is null then
    raise exception 'WORLDEDIT-REVERT self-assert FAIL: a domain *_update RPC or canonical_coord_violation vanished';
  end if;

  -- (e) NO client-role write grant on any of the four target tables (SELECT survives — the reads depend
  -- on it). The only write path is this SECURITY DEFINER surface (and the domain *_update RPCs).
  if has_table_privilege('authenticated', 'public.locations', 'INSERT')
     or has_table_privilege('authenticated', 'public.locations', 'UPDATE')
     or has_table_privilege('authenticated', 'public.mining_fields', 'UPDATE')
     or has_table_privilege('authenticated', 'public.exploration_sites', 'UPDATE')
     or has_table_privilege('authenticated', 'public.danger_zones', 'UPDATE')
     or has_table_privilege('anon', 'public.locations', 'UPDATE')
     or has_table_privilege('anon', 'public.danger_zones', 'UPDATE') then
    raise exception 'WORLDEDIT-REVERT self-assert FAIL: a client role holds a write grant on a target table — the only write path must be the SECURITY DEFINER surface';
  end if;
  if not has_table_privilege('anon', 'public.locations', 'SELECT')
     or not has_table_privilege('authenticated', 'public.locations', 'SELECT')
     or not has_table_privilege('anon', 'public.danger_zones', 'SELECT') then
    raise exception 'WORLDEDIT-REVERT self-assert FAIL: a client role LOST SELECT on a read table — a map/zone read would break';
  end if;

  -- (f) the 0239 pirate-zone lockdown is STILL intact (no client execute; service_role keeps its grant).
  if has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_zone_delete(uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'WORLDEDIT-REVERT self-assert FAIL: a client role regained EXECUTE on a pirate_zone write RPC — the 0239 lockdown was disturbed';
  end if;
  if not has_function_privilege('service_role', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or not has_function_privilege('service_role', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'WORLDEDIT-REVERT self-assert FAIL: service_role LOST execute on a pirate_zone RPC — the 0239 owner-tooling path was disturbed';
  end if;

  raise notice 'WORLDEDIT-REVERT self-assert ok: 0243 spine + snapshot columns present; world_editor_revert SECURITY DEFINER + search_path='''' + authenticated-only; body writes the four target tables only (never pirate_zone_*); the four *_update RPCs + canonical_coord_violation intact; no client write grant on the target tables (SELECT intact); 0239 lockdown intact (service_role kept)';
end $pubassert$;
