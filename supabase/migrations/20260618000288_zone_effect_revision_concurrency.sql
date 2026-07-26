-- 0288 — ONE ZONE CONCURRENCY TOKEN: the effect commands gate on danger_zones.revision.
--
-- WHY. 0287 made danger_zones.revision the sole optimistic-concurrency authority for zone_update, after
-- the geometry compare was found to reject unchanged zones permanently (the ring reaches a client only
-- through get_danger_zones, which emits float8 at 15 significant digits, so an ST_Equals compare against
-- the stored boundary can never be satisfied for a buffer-derived zone). 0277's zone_effect_set /
-- zone_effect_remove predate that and still compare an `expected` snapshot of {name, source, location_id}.
--
-- THIS IS NOT THE SAME BUG. Those three are plain scalars and DO round-trip exactly, so the effect
-- commands were never broken the way zone_update was. What it IS, is two write paths to the SAME
-- aggregate holding two different definitions of "stale". 0275 defined revision as the aggregate
-- revision of a zone INCLUDING its effect set, and 0287 established the invariant that every mutation
-- bumps it exactly once. Leaving a second, older notion of drift beside it means the next person to
-- touch either path has to guess which is authoritative — and that guess is how 0284 shipped a guard
-- reading a column its own SELECT never fetched.
--
-- One aggregate, one token. The effect commands already SELECT revision and already BUMP it (0277:241,
-- 0277:378); they simply never gated on it. This migration closes that.
--
-- WHAT CHANGES — exactly one thing per command:
--   * the `expected` field compare is replaced by `expected_revision` vs the locked v_live.revision.
-- Everything else is re-emitted BYTE-IDENTICAL to 0277: the same gate chain (authn → is_owner →
-- typed_zone_authoring_enabled → request_id idempotency → row lock), the same effect_type rejection,
-- the same override validation, the same write + audit, the same revision bump, the same grants.
--
-- WIRE CONTRACT CHANGE. `expected_revision` (a numeric string or number) is now REQUIRED; `expected` is
-- retained in the payload for the audit trail but no longer gates anything. This breaks any caller that
-- sends only `expected` — and NOTHING does: neither command appears in the client's command union
-- (commandContract.ts), and zoneEffectPanelModel.ts is mounted nowhere in the shell. This is the
-- cheapest moment this change will ever be.
--
-- FAIL-CLOSED: a caller with no usable token is stale, never written against an unknown baseline.
--
-- STILL DARK. typed_zone_authoring_enabled is untouched and stays false. No effect_type is added — the
-- commands still accept pirate_intercept only; teaching them 'combat' is a separate slice. No runtime
-- function is recreated, no flag is flipped, no gameplay becomes reachable.
--
-- FORWARD-ONLY: 0277 has already been applied and is never edited in place.


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
  v_exp_rev    text;               -- the caller's fork-time danger_zones.revision (the ONE token, 0287)
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
  v_expected := p_payload->'expected';   -- retained for the audit trail only; NOT a concurrency gate
  v_ov       := coalesce(p_payload->'overrides', '{}'::jsonb);
  if v_target = '' or not (p_payload ? 'expected_revision')
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

  -- (8) OPTIMISTIC CONCURRENCY — danger_zones.revision, the ONE zone token (0287).
  --
  -- 0277 shipped this as a field-by-field compare of `expected` {name, source, location_id}. 0287 then
  -- made revision the sole authority for zone_update, on the finding that a value compare decides drift
  -- from data the client can only ever receive lossily. These fields are plain scalars and DO round-trip,
  -- so this was never broken the way the geometry compare was — but it left two write paths to the SAME
  -- aggregate holding two different definitions of "stale", and the next person to touch either would
  -- have had to guess which was authoritative. One aggregate, one token.
  --
  -- FAIL-CLOSED: a caller with no usable token is stale, never published against an unknown baseline.
  v_exp_rev := nullif(btrim(coalesce(p_payload->>'expected_revision', '')), '');
  if v_exp_rev is null or v_exp_rev !~ '^[0-9]+$' or v_exp_rev::bigint is distinct from v_live.revision then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'stale_revision', 'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_changed', 'field', null,
               'message', 'The live zone changed since this draft was forked — re-open it to edit the current version.',
               'expected_revision', v_exp_rev,
               'current_revision', v_live.revision)));
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
  v_exp_rev    text;               -- the caller's fork-time danger_zones.revision (the ONE token, 0287)
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
  v_expected := p_payload->'expected';   -- retained for the audit trail only; NOT a concurrency gate
  if v_target = '' or not (p_payload ? 'expected_revision') then
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
  -- (8) OPTIMISTIC CONCURRENCY — danger_zones.revision, the ONE zone token (0287).
  --
  -- 0277 shipped this as a field-by-field compare of `expected` {name, source, location_id}. 0287 then
  -- made revision the sole authority for zone_update, on the finding that a value compare decides drift
  -- from data the client can only ever receive lossily. These fields are plain scalars and DO round-trip,
  -- so this was never broken the way the geometry compare was — but it left two write paths to the SAME
  -- aggregate holding two different definitions of "stale", and the next person to touch either would
  -- have had to guess which was authoritative. One aggregate, one token.
  --
  -- FAIL-CLOSED: a caller with no usable token is stale, never published against an unknown baseline.
  v_exp_rev := nullif(btrim(coalesce(p_payload->>'expected_revision', '')), '');
  if v_exp_rev is null or v_exp_rev !~ '^[0-9]+$' or v_exp_rev::bigint is distinct from v_live.revision then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'stale_revision', 'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_changed', 'field', null,
               'message', 'The live zone changed since this draft was forked — re-open it to edit the current version.',
               'expected_revision', v_exp_rev,
               'current_revision', v_live.revision)));
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


-- ── grants + comments, RE-EMITTED ───────────────────────────────────────────────────────────────
-- `create or replace function` preserves existing privileges, so these are strictly belt-and-braces —
-- but stating exposure in the same migration that redefines the body means the grant can never drift
-- silently from the definition, and a reader never has to open 0277 to learn who may call this.
revoke execute on function public.zone_effect_set(text, jsonb) from public, anon;
grant execute on function public.zone_effect_set(text, jsonb) to authenticated;

comment on function public.zone_effect_set(text, jsonb) is
  'TYPED-ZONE PLATFORM (0277, concurrency retargeted 0288): owner-gated BEHAVIOUR authoring — creates '
  'or updates one effect''s configuration on one zone. Cannot move geometry, change zone_kind or flip '
  'status. Optimistic concurrency is danger_zones.revision via p_payload.expected_revision — the ONE '
  'zone token (0287); the pre-0288 `expected` {name, source, location_id} compare is gone. Bumps '
  'danger_zones.revision so a dispatch plan can never claim a revision that predates its own config. '
  'Dark behind typed_zone_authoring_enabled.';

revoke execute on function public.zone_effect_remove(text, jsonb) from public, anon;
grant execute on function public.zone_effect_remove(text, jsonb) to authenticated;

comment on function public.zone_effect_remove(text, jsonb) is
  'TYPED-ZONE PLATFORM (0277, concurrency retargeted 0288): owner-gated BEHAVIOUR authoring — removes '
  'one effect from one zone. The zone keeps its geometry and identity and simply stops doing that '
  'thing; identity never implies effect presence. Optimistic concurrency is danger_zones.revision via '
  'p_payload.expected_revision (0287). Bumps danger_zones.revision. Dark behind '
  'typed_zone_authoring_enabled.';

-- KIND CONVERSION IS deliberately NOT here. Converting a zone_kind while stale effect config remains
-- is a real hazard and needs its own rules — 0285 owns it. This migration retargets concurrency and
-- nothing else. Teaching these commands the 'combat' effect_type is likewise a separate slice.


-- ── SELF-ASSERT ─────────────────────────────────────────────────────────────────────────────────────
do $$
declare v_fn text; v_def text;
begin
  foreach v_fn in array array['zone_effect_set', 'zone_effect_remove'] loop
    if to_regprocedure('public.' || v_fn || '(text, jsonb)') is null then
      raise exception '0288: public.%(text, jsonb) is missing after this migration', v_fn;
    end if;
    v_def := pg_get_functiondef(to_regprocedure('public.' || v_fn || '(text, jsonb)'));

    -- (1) THE FIX: revision is the gate…
    if position('v_exp_rev::bigint is distinct from v_live.revision' in v_def) = 0 then
      raise exception '0288: % does not gate on expected_revision vs v_live.revision', v_fn;
    end if;
    -- …and the OLD field compare is GONE, not merely bypassed. If it survives, two definitions of
    -- "stale" still exist for one aggregate, which is the whole reason for this migration.
    if position('v_expected->>''name''' in v_def) > 0
       or position('v_expected->>''source''' in v_def) > 0 then
      raise exception '0288: % still compares the expected snapshot — one aggregate, one token', v_fn;
    end if;

    -- (2) the revision BUMP survives (0275's aggregate-revision contract; a dispatch plan must never
    -- be able to claim a revision predating its own config).
    if v_def !~* 'update public\.danger_zones set revision = revision \+ 1' then
      raise exception '0288: % no longer bumps the aggregate revision', v_fn;
    end if;

    -- (3) the capability gate and the owner spine are intact — this migration widens nothing.
    if position('typed_zone_authoring_enabled' in v_def) = 0 then
      raise exception '0288: % lost its typed_zone_authoring_enabled gate', v_fn;
    end if;
    if position('is_owner' in v_def) = 0 then
      raise exception '0288: % lost its is_owner guard', v_fn;
    end if;

    -- (4) still BEHAVIOUR-ONLY: neither command may write zone identity or geometry (0277's law).
    if v_def ~* 'update\s+public\.danger_zones\s+set\s+(boundary|zone_kind|status|name|location_id)' then
      raise exception '0288: % can now write zone identity/geometry — it must stay behaviour-only', v_fn;
    end if;

    -- (5) exposure unchanged: authenticated may execute, anon NEVER.
    if not has_function_privilege('authenticated', 'public.' || v_fn || '(text,jsonb)', 'execute') then
      raise exception '0288: % lost its authenticated execute grant', v_fn;
    end if;
    if has_function_privilege('anon', 'public.' || v_fn || '(text,jsonb)', 'execute') then
      raise exception '0288: % is executable by anon', v_fn;
    end if;

    -- (6) no effect_type was smuggled in: 'combat' authoring is a SEPARATE slice.
    if position('''combat''' in v_def) > 0 then
      raise exception '0288: % accepts a combat effect_type — that is not this migration''s job', v_fn;
    end if;
  end loop;

  -- (7) the capability flag is untouched and still dark.
  if coalesce((select (value)::text::boolean from public.game_config
                where key = 'typed_zone_authoring_enabled'), true) then
    raise exception '0288: typed_zone_authoring_enabled is not false — this migration must land dark';
  end if;

  raise notice '0288 OK: zone_effect_set/remove gate on danger_zones.revision; the expected-snapshot compare is gone; still dark, still behaviour-only';
end $$;

