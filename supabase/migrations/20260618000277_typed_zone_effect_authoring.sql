-- Byeharu — TYPED-ZONE EFFECT AUTHORING (migration 0277). Slice 5a of the typed-zone platform.
-- LANDS DARK behind typed_zone_authoring_enabled (seeded false in 0273). Two owner-gated commands.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SEPARATE INTENTS, NEVER ONE GIANT PAYLOAD
-- A zone now has four independent concerns — geometry, identity (kind), behaviour (effects) and
-- lifecycle (status). A single `zone_update(payload)` that accepted all four would let one careless
-- request silently alter three things the owner did not mean to touch, and would give the audit log
-- one indistinguishable event type for four very different acts.
--
-- So this slice adds ONLY the BEHAVIOUR intent, as two commands:
--     zone_effect_set     — create or update one effect's configuration on one zone
--     zone_effect_remove  — remove one effect from one zone
-- Neither can move a boundary, change a zone_kind, or flip a status. That is enforced, not merely
-- intended: both write exactly one effect table plus danger_zones.revision, and the self-assert
-- proves neither statement can reach boundary, zone_kind or status.
--
-- Geometry authoring already exists (zone_update, 0266). Identity conversion (change-zone-kind) is
-- deliberately NOT here — converting a kind while stale effect config remains would be a real
-- gameplay hazard, so it needs its own explicit conversion rules and its own slice.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHY THESE BUMP danger_zones.revision
-- 0275 defined revision as the AGGREGATE revision of a zone INCLUDING its effect set, because a
-- dispatch plan is tied to the configuration it was derived from. An effect change that left revision
-- untouched would produce two materially different plans claiming the same revision — which is
-- exactly the kind of silent drift the field exists to make visible. So every successful command here
-- increments it, in the same transaction as the effect write.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE HOUSE IDIOM, UNCHANGED (0243/0249/0266): authn → authz(is_owner) → request_id idempotency via
-- world_editor_audit → structural addressing → row-lock the target → optimistic concurrency against
-- an `expected` snapshot → validate → write + audit atomically. Nothing novel is invented for
-- security here; the only new gate is the authoring flag.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. preconditions ────────────────────────────────────────────────────────────────────────────
do $pre$
begin
  if to_regclass('public.zone_effect_pirate_intercept') is null then
    raise exception 'TYPED-ZONE 0277: zone_effect_pirate_intercept (0273) is missing';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='danger_zones' and column_name='revision') then
    raise exception 'TYPED-ZONE 0277: danger_zones.revision (0275) is missing';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'TYPED-ZONE 0277: the is_owner() spine (0243) is missing';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'TYPED-ZONE 0277: world_editor_audit (0243) is missing';
  end if;
  if not exists (select 1 from public.game_config where key = 'typed_zone_authoring_enabled') then
    raise exception 'TYPED-ZONE 0277: typed_zone_authoring_enabled (0273) is missing';
  end if;
end $pre$;

-- ── 1. zone_effect_set — create or update ONE effect's configuration ────────────────────────────
-- payload = {
--   target_id:   <zone uuid>,
--   effect_type: 'pirate_intercept',
--   expected:    { name, source, location_id },     -- the fork-time zone snapshot
--   overrides:   { base_risk, min_risk, max_risk, exposure_floor, stat_reference }  -- null = inherit
-- }
create or replace function public.zone_effect_set(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid        uuid := auth.uid();
  v_target     text;
  v_target_id  uuid;
  v_effect     text;
  v_expected   jsonb;
  v_ov         jsonb;
  v_live       record;
  v_prior      text;
  v_before     jsonb;
  v_after      jsonb;
  v_result     jsonb;
  v_details    jsonb := '[]'::jsonb;
  v_knob       text;
  v_num        double precision;
  v_res_min    double precision;
  v_res_max    double precision;
  v_conflict   text;
  v_existed    boolean;
  v_rev        integer;
begin
  -- (1) authn
  if v_uid is null then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authenticated');
  end if;
  -- (2) authz — the ONE guard
  if not public.is_owner() then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authorized');
  end if;
  -- (3) idempotency key
  if p_request_id is null or length(btrim(p_request_id)) = 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;
  -- (4) CAPABILITY GATE — dark by default. Checked AFTER authz so a non-owner never learns whether
  -- the capability exists, and BEFORE any world read so a dark call touches nothing.
  if not coalesce(public.cfg_bool('typed_zone_authoring_enabled'), false) then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'validation_failed',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'authoring_disabled', 'field', null,
               'message', 'Typed-zone authoring is not enabled.')));
  end if;
  -- (5) idempotent replay
  select result into v_prior from public.world_editor_audit where request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'request_id', p_request_id,
             'command_type', 'zone_effect_set', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  -- (6) structural addressing
  v_target   := btrim(coalesce(p_payload->>'target_id', ''));
  v_effect   := coalesce(p_payload->>'effect_type', '');
  v_expected := p_payload->'expected';
  v_ov       := coalesce(p_payload->'overrides', '{}'::jsonb);
  if v_target = '' or v_expected is null or jsonb_typeof(v_expected) <> 'object'
     or jsonb_typeof(v_ov) <> 'object' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;
  begin
    v_target_id := v_target::uuid;
  exception when invalid_text_representation then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end;
  -- an unknown effect type is TYPED, never a silent no-op
  if v_effect <> 'pirate_intercept' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'validation_failed',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'unsupported_effect_type', 'field', 'effect_type',
               'message', 'Only pirate_intercept is authorable today.')));
  end if;

  -- (7) LOCATE + ROW-LOCK the zone. The lock covers the effect write too: revision and the effect row
  -- must move together or not at all.
  select id, name, source, location_id, zone_kind, status, revision
    into v_live
    from public.danger_zones
   where id = v_target_id
     for update;
  if not found then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_found',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_missing', 'field', null,
               'message', 'No live zone with id ''' || v_target || ''' exists.')));
  end if;

  -- (8) OPTIMISTIC CONCURRENCY over the addressing fields (the 0255/0268 zone idiom). Geometry is NOT
  -- compared: this command cannot change it, so a concurrent reshape is not a conflict for us.
  if (v_expected->>'name') is distinct from v_live.name then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'name', 'message', 'The zone''s name changed since the draft was forked.'));
  end if;
  if (v_expected->>'source') is distinct from v_live.source then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'source', 'message', 'The zone''s source changed since the draft was forked.'));
  end if;
  if coalesce(v_expected->'location_id', 'null'::jsonb)
       is distinct from coalesce(to_jsonb(v_live.location_id), 'null'::jsonb) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'location_id', 'message', 'The zone''s attachment changed since the draft was forked.'));
  end if;
  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'stale_revision', 'details', v_details);
  end if;

  -- (9) VALIDATE the overrides. The CHECK constraints are the ultimate authority, but a typed report
  -- beats a raw constraint violation reaching the client.
  foreach v_knob in array array['base_risk','min_risk','max_risk','exposure_floor','stat_reference'] loop
    if v_ov ? v_knob and jsonb_typeof(v_ov->v_knob) <> 'null' then
      if jsonb_typeof(v_ov->v_knob) <> 'number' then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'invalid_value', 'field', v_knob, 'message', v_knob || ' must be a number or null.'));
        continue;
      end if;
      v_num := (v_ov->>v_knob)::double precision;
      -- NaN and the infinities: Postgres orders NaN above every real, so a bare > 0 would accept it.
      if v_num <> v_num or v_num = 'Infinity'::double precision or v_num = '-Infinity'::double precision then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'invalid_value', 'field', v_knob, 'message', v_knob || ' must be finite.'));
      elsif v_knob = 'stat_reference' then
        if v_num <= 0 then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code', 'invalid_value', 'field', v_knob, 'message', 'stat_reference must be greater than 0.'));
        end if;
      elsif v_num < 0 or v_num > 1 then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'invalid_value', 'field', v_knob, 'message', v_knob || ' must be within [0,1].'));
      end if;
    end if;
  end loop;

  -- the RESOLVED band, not just the supplied values: an override can be individually valid yet
  -- invert the band once combined with the globals it inherits.
  v_res_min := coalesce(nullif(v_ov->>'min_risk','')::double precision,
                        coalesce(public.cfg_num('pirate_intercept_min_risk'), 0.02));
  v_res_max := coalesce(nullif(v_ov->>'max_risk','')::double precision,
                        coalesce(public.cfg_num('pirate_intercept_max_risk'), 0.90));
  if v_res_min is not null and v_res_max is not null and v_res_min > v_res_max then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'invalid_resolved_effect_config', 'field', null,
      'message', 'The resolved minimum risk exceeds the resolved maximum risk.'));
  end if;

  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'validation_failed', 'details', v_details);
  end if;

  -- (10) BEFORE snapshot — the effect row as it stands (or its absence)
  select to_jsonb(e) into v_before from public.zone_effect_pirate_intercept e where e.zone_id = v_target_id;
  v_existed := v_before is not null;

  -- (11) WRITE — the effect row and the aggregate revision, atomically
  insert into public.zone_effect_pirate_intercept
    (zone_id, base_risk, min_risk, max_risk, exposure_floor, stat_reference)
  values (
    v_target_id,
    nullif(v_ov->>'base_risk','')::double precision,
    nullif(v_ov->>'min_risk','')::double precision,
    nullif(v_ov->>'max_risk','')::double precision,
    nullif(v_ov->>'exposure_floor','')::double precision,
    nullif(v_ov->>'stat_reference','')::double precision)
  on conflict (zone_id) do update set
    base_risk      = excluded.base_risk,
    min_risk       = excluded.min_risk,
    max_risk       = excluded.max_risk,
    exposure_floor = excluded.exposure_floor,
    stat_reference = excluded.stat_reference,
    updated_at     = now();

  update public.danger_zones set revision = revision + 1 where id = v_target_id
    returning revision into v_rev;

  select to_jsonb(e) into v_after from public.zone_effect_pirate_intercept e where e.zone_id = v_target_id;

  v_result := jsonb_build_object(
    'zone_id', v_target_id, 'effect_type', 'pirate_intercept',
    'created', not v_existed, 'revision', v_rev);

  begin
    insert into public.world_editor_audit
      (actor, request_id, command_type, target_type, target_id, result,
       before_snapshot, after_snapshot, source_revision)
    values
      (v_uid, p_request_id, 'zone_effect_set', 'zone', v_target_id::text, v_result::text,
       v_before, v_after, p_payload->>'source_revision');
  exception when unique_violation then
    get stacked diagnostics v_conflict = TABLE_NAME;
    if v_conflict = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'zone_effect_set', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    raise;
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id,
           'command_type', 'zone_effect_set', 'result', v_result);
end;
$$;

revoke execute on function public.zone_effect_set(text, jsonb) from public, anon;
grant execute on function public.zone_effect_set(text, jsonb) to authenticated;

comment on function public.zone_effect_set(text, jsonb) is
  'TYPED-ZONE PLATFORM (0277): owner-gated BEHAVIOUR authoring — creates or updates one effect''s '
  'configuration on one zone. Cannot move geometry, change zone_kind or flip status. Bumps '
  'danger_zones.revision so a dispatch plan can never claim a revision that predates its own config. '
  'Dark behind typed_zone_authoring_enabled.';

-- ── 2. zone_effect_remove — remove ONE effect from ONE zone ─────────────────────────────────────
-- Removing the last effect is legal and meaningful: the zone keeps its geometry and identity and
-- simply stops doing anything. Identity does not imply effect presence.
create or replace function public.zone_effect_remove(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_target    text;
  v_target_id uuid;
  v_effect    text;
  v_expected  jsonb;
  v_live      record;
  v_prior     text;
  v_before    jsonb;
  v_result    jsonb;
  v_details   jsonb := '[]'::jsonb;
  v_conflict  text;
  v_rev       integer;
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
  if not coalesce(public.cfg_bool('typed_zone_authoring_enabled'), false) then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'validation_failed',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'authoring_disabled', 'field', null,
               'message', 'Typed-zone authoring is not enabled.')));
  end if;
  select result into v_prior from public.world_editor_audit where request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'request_id', p_request_id,
             'command_type', 'zone_effect_remove', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  v_target   := btrim(coalesce(p_payload->>'target_id', ''));
  v_effect   := coalesce(p_payload->>'effect_type', '');
  v_expected := p_payload->'expected';
  if v_target = '' or v_expected is null or jsonb_typeof(v_expected) <> 'object' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;
  begin
    v_target_id := v_target::uuid;
  exception when invalid_text_representation then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end;
  if v_effect <> 'pirate_intercept' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'validation_failed',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'unsupported_effect_type', 'field', 'effect_type',
               'message', 'Only pirate_intercept is authorable today.')));
  end if;

  select id, name, source, location_id, revision into v_live
    from public.danger_zones where id = v_target_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_found',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_missing', 'field', null,
               'message', 'No live zone with id ''' || v_target || ''' exists.')));
  end if;

  if (v_expected->>'name') is distinct from v_live.name then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'name', 'message', 'The zone''s name changed since the draft was forked.'));
  end if;
  if (v_expected->>'source') is distinct from v_live.source then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'source', 'message', 'The zone''s source changed since the draft was forked.'));
  end if;
  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'stale_revision', 'details', v_details);
  end if;

  select to_jsonb(e) into v_before from public.zone_effect_pirate_intercept e where e.zone_id = v_target_id;
  if v_before is null then
    -- ALREADY ABSENT is a typed outcome, not a silent success: the caller's model of the world is
    -- wrong and it should learn that.
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'validation_failed',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'effect_absent', 'field', 'effect_type',
               'message', 'This zone does not carry the pirate_intercept effect.')));
  end if;

  delete from public.zone_effect_pirate_intercept where zone_id = v_target_id;
  update public.danger_zones set revision = revision + 1 where id = v_target_id
    returning revision into v_rev;

  v_result := jsonb_build_object('zone_id', v_target_id, 'effect_type', 'pirate_intercept',
                                 'removed', true, 'revision', v_rev);
  begin
    insert into public.world_editor_audit
      (actor, request_id, command_type, target_type, target_id, result,
       before_snapshot, after_snapshot, source_revision)
    values
      (v_uid, p_request_id, 'zone_effect_remove', 'zone', v_target_id::text, v_result::text,
       v_before, null, p_payload->>'source_revision');
  exception when unique_violation then
    get stacked diagnostics v_conflict = TABLE_NAME;
    if v_conflict = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'zone_effect_remove', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    raise;
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id,
           'command_type', 'zone_effect_remove', 'result', v_result);
end;
$$;

revoke execute on function public.zone_effect_remove(text, jsonb) from public, anon;
grant execute on function public.zone_effect_remove(text, jsonb) to authenticated;

comment on function public.zone_effect_remove(text, jsonb) is
  'TYPED-ZONE PLATFORM (0277): owner-gated BEHAVIOUR authoring — removes one effect from one zone. '
  'The zone keeps its geometry and identity and simply stops doing that thing; identity never implies '
  'effect presence. Bumps danger_zones.revision. Dark behind typed_zone_authoring_enabled.';

-- ── 3. SELF-ASSERT — dark, owner-gated, and behaviour-only ──────────────────────────────────────
do $tza$
declare
  v_set text;
  v_rem text;
begin
  if coalesce(public.cfg_bool('typed_zone_authoring_enabled'), true) then
    raise exception 'TYPED-ZONE 0277 self-assert FAIL: typed_zone_authoring_enabled is not false'; end if;

  select pg_get_functiondef(to_regprocedure('public.zone_effect_set(text, jsonb)'))    into v_set;
  select pg_get_functiondef(to_regprocedure('public.zone_effect_remove(text, jsonb)')) into v_rem;
  if v_set is null or v_rem is null then
    raise exception 'TYPED-ZONE 0277 self-assert FAIL: a command is missing'; end if;

  -- BEHAVIOUR ONLY: neither command may write geometry, identity or lifecycle. The only danger_zones
  -- write permitted is the revision bump.
  if v_set ~* 'update public\.danger_zones set (boundary|zone_kind|status|name|location_id)'
     or v_rem ~* 'update public\.danger_zones set (boundary|zone_kind|status|name|location_id)' then
    raise exception 'TYPED-ZONE 0277 self-assert FAIL: a behaviour command writes geometry/identity/lifecycle';
  end if;
  if v_set !~* 'update public\.danger_zones set revision = revision \+ 1'
     or v_rem !~* 'update public\.danger_zones set revision = revision \+ 1' then
    raise exception 'TYPED-ZONE 0277 self-assert FAIL: a command does not bump the aggregate revision';
  end if;

  -- the full house gate chain is present in both
  foreach v_set in array array[v_set, v_rem] loop
    if strpos(v_set, 'not_authenticated') = 0 or strpos(v_set, 'is_owner()') = 0
       or strpos(v_set, 'typed_zone_authoring_enabled') = 0
       or strpos(v_set, 'world_editor_audit') = 0
       or strpos(v_set, 'for update') = 0
       or strpos(v_set, 'stale_revision') = 0 then
      raise exception 'TYPED-ZONE 0277 self-assert FAIL: a command is missing part of the gate chain';
    end if;
  end loop;

  -- ACL: authenticated may CALL (the owner check is inside); anon may not.
  if has_function_privilege('anon', 'public.zone_effect_set(text, jsonb)', 'execute')
     or has_function_privilege('anon', 'public.zone_effect_remove(text, jsonb)', 'execute') then
    raise exception 'TYPED-ZONE 0277 self-assert FAIL: anon can execute an authoring command'; end if;
  if not has_function_privilege('authenticated', 'public.zone_effect_set(text, jsonb)', 'execute') then
    raise exception 'TYPED-ZONE 0277 self-assert FAIL: authenticated lost execute (the owner gate is inside)'; end if;

  raise notice 'TYPED-ZONE 0277 self-assert ok: lands DARK (typed_zone_authoring_enabled still false); two BEHAVIOUR-ONLY commands added — neither can write boundary, zone_kind, status, name or location_id, and both bump danger_zones.revision so no dispatch plan can claim a revision predating its own config; both carry the full house gate chain (authn, is_owner, capability gate, request_id idempotency via world_editor_audit, row lock, optimistic concurrency); anon cannot execute either, authenticated can (the owner check is server-side)';
end $tza$;
