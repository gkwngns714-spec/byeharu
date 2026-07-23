-- Byeharu — WORLD EDITOR: ONE canonical point-coordinate-validation AUTHORITY.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT THIS IS: a single shared, pure validation helper — public.canonical_coord_violation — that
-- expresses the ±10000 navigable-square coordinate-frame invariant ONCE, and the SIX owner-gated
-- point-coordinate-write RPCs REDEFINED to call it in place of their SEPARATELY-DUPLICATED inline
-- coordinate checks:
--   • location_create        (0252, last redefined by 0264 — anchor write-authority)
--   • location_update        (0249, last redefined by 0264 — anchor write-authority)
--   • mining_field_create    (0246)
--   • mining_field_update    (0248)
--   • exploration_site_create(0244)
--   • exploration_site_update(0247)
--
-- Today each of the six re-validates its coordinate writes against the SAME frame (a jsonb number,
-- finite, within [-10000, 10000]) with its OWN copy of the same two `if` blocks — the only per-RPC
-- difference is the FIELD NAME (locations use x/y; mining/exploration use space_x/space_y). This
-- migration converges that ONE invariant into ONE authority (NO-SPAGHETTI: one authority per
-- concept, compose don't fork) WITHOUT changing observable behavior in ANY way.
--
-- BEHAVIOR-PRESERVING — THE KEY CONSTRAINT:
--   • The helper does NOT raise. Each RPC returns a TYPED validation envelope
--     ({ok:false, error:'validation_failed', details:[{code,field,message},...]}), never a raw
--     exception. So the helper RETURNS a details-array fragment (empty jsonb array if valid; the
--     SAME {code,field,message} entries the RPCs emit today otherwise) that each RPC folds into its
--     existing v_details accumulation, at the SAME position — so the details array order and every
--     byte of every code/field/message is IDENTICAL to today's output.
--   • The helper is PARAMETERIZED by the two field names, so each call site reproduces its OWN
--     current strings exactly: 'x'/'y' for locations, 'space_x'/'space_y' for mining/exploration.
--     The two error codes ('numeric_not_finite', 'coord_out_of_bounds') and the message templates
--     ('<field> must be a finite number.' / '<field> must be within ±10000.') are already IDENTICAL
--     across all six — verified against source — so ONLY the field name varies, and the helper
--     interpolates it, byte-for-byte.
--   • The finiteness semantics are preserved EXACTLY: a jsonb value is a "finite number" iff its
--     jsonb_typeof is 'number' (JSON cannot encode NaN/Infinity, so a jsonb number is finite by
--     construction — a NaN/Inf/absent/string/null coordinate is `is distinct from 'number'` and
--     yields numeric_not_finite, precisely as the inline checks do today). The bound is the same
--     inclusive `[-10000, 10000]` (a value strictly `< -10000` or `> 10000` is out of bounds; the
--     boundaries themselves are valid).
--   • Each RPC still parses v_x/v_y from the validated fields for its write; that parse is simply
--     RELOCATED to AFTER the validation gate (it is only ever reached when the coordinate is a valid
--     in-range number, exactly as the inline `else` branch guaranteed), so the STORED coordinate —
--     and, for locations, the space_anchor written from it (0264) — is byte-identical.
--
-- SCOPE — EXACTLY these six point-coordinate-write RPCs. EXCLUDED: zone_create (0254) /
-- zone_unpublish (0255) validate POLYGON/CIRCLE geometry via PostGIS (ST_IsValid/ST_Area over a
-- materialized boundary, per-vertex bounds on a geometry union) — a DIFFERENT, already-centralized
-- geometry authority whose shape (nested geometry.center / vertices[]) the two-scalar point helper
-- does not fit; they are deliberately untouched. This migration also does NOT touch space_anchors,
-- get_world_map, any grant/ACL, or any stored coordinate — it ONLY centralizes the validation the
-- six RPCs already perform.
--
-- DEPLOY POSTURE: UNDEPLOYED — deploy is a human gate. Every redefined RPC keeps its exact prior
-- SECURITY DEFINER posture, ACL (authenticated-only; anon/public denied), and in-body owner guard;
-- no grant is widened, no capability changes. Behavior is byte-identical to the pre-0265 chain.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. dependency gate — abort loudly if a surface this slice rebuilds is missing ─────────────────
do $pubdep$
begin
  if to_regprocedure('public.exploration_site_create(text, jsonb)') is null then
    raise exception 'CANONICAL-COORD: public.exploration_site_create (0244) is missing — a target RPC must exist to redefine';
  end if;
  if to_regprocedure('public.exploration_site_update(text, jsonb)') is null then
    raise exception 'CANONICAL-COORD: public.exploration_site_update (0247) is missing — a target RPC must exist to redefine';
  end if;
  if to_regprocedure('public.mining_field_create(text, jsonb)') is null then
    raise exception 'CANONICAL-COORD: public.mining_field_create (0246) is missing — a target RPC must exist to redefine';
  end if;
  if to_regprocedure('public.mining_field_update(text, jsonb)') is null then
    raise exception 'CANONICAL-COORD: public.mining_field_update (0248) is missing — a target RPC must exist to redefine';
  end if;
  if to_regprocedure('public.location_create(text, jsonb)') is null then
    raise exception 'CANONICAL-COORD: public.location_create (0252/0264) is missing — a target RPC must exist to redefine';
  end if;
  if to_regprocedure('public.location_update(text, jsonb)') is null then
    raise exception 'CANONICAL-COORD: public.location_update (0249/0264) is missing — a target RPC must exist to redefine';
  end if;
  -- the 0264 anchor authority must be in place: the location RPCs redefined below carry its anchor
  -- write behavior verbatim, so the table + one-active index must exist to preserve it.
  if to_regclass('public.space_anchors') is null then
    raise exception 'CANONICAL-COORD: public.space_anchors (0063) is missing — the location RPCs preserve 0264 anchor writes';
  end if;
end $pubdep$;

-- ── 1. THE ONE AUTHORITY — canonical_coord_violation ──────────────────────────────────────────────
-- A PURE, IMMUTABLE, non-raising validator for a POINT's two coordinate fields against the canonical
-- ±10000 frame. It takes the two RAW jsonb field VALUES (v_fields->'x', v_fields->'y') and their
-- FIELD NAMES, and returns a jsonb ARRAY fragment: [] if both coordinates are valid, else the same
-- {code,field,message} detail objects the RPCs emit inline today — x first, then y; at most one
-- entry per field; codes 'numeric_not_finite' (not a jsonb number) or 'coord_out_of_bounds' (a
-- number strictly outside [-10000, 10000]). Passing the jsonb VALUE (not a pre-cast double) is what
-- preserves the EXACT current finiteness semantics: "finite number" == jsonb_typeof = 'number'.
-- The if/elsif here mirrors the inline `if (not number) ... else (number) if (out of range) ...`
-- one-to-one, so the emitted bytes are identical.
create or replace function public.canonical_coord_violation(
  p_val_x jsonb, p_val_y jsonb, p_field_x text, p_field_y text)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_out jsonb := '[]'::jsonb;
begin
  -- x — a jsonb number in [-10000, 10000], else a typed detail (never a raise).
  if jsonb_typeof(p_val_x) is distinct from 'number' then
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'code', 'numeric_not_finite', 'field', p_field_x, 'message', p_field_x || ' must be a finite number.'));
  elsif (p_val_x)::numeric < -10000 or (p_val_x)::numeric > 10000 then
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'code', 'coord_out_of_bounds', 'field', p_field_x, 'message', p_field_x || ' must be within ±10000.'));
  end if;

  -- y — same frame; appended AFTER x so the details order matches the inline blocks exactly.
  if jsonb_typeof(p_val_y) is distinct from 'number' then
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'code', 'numeric_not_finite', 'field', p_field_y, 'message', p_field_y || ' must be a finite number.'));
  elsif (p_val_y)::numeric < -10000 or (p_val_y)::numeric > 10000 then
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'code', 'coord_out_of_bounds', 'field', p_field_y, 'message', p_field_y || ' must be within ±10000.'));
  end if;

  return v_out;
end $$;

comment on function public.canonical_coord_violation(jsonb, jsonb, text, text) is
  'CANONICAL COORD AUTHORITY (0265): the ONE point-coordinate-frame validator for the World Editor '
  'write RPCs. Pure/IMMUTABLE, NON-raising. Takes the two raw jsonb coordinate field VALUES + their '
  'field names; returns a jsonb details-array fragment ([] if valid; {numeric_not_finite} for a '
  'non-jsonb-number, {coord_out_of_bounds} for a number outside the inclusive [-10000,10000] frame) '
  'that a caller folds into its validation_failed details[]. Field-name-parameterized so each of the '
  'six RPCs reproduces its own strings (x/y or space_x/space_y) byte-for-byte. Replaces the '
  'previously-duplicated inline ±10000 checks; behavior-preserving.';

-- ── 2. exploration_site_create — 0244 body, coordinate checks routed through the ONE authority ────
-- Byte-identical to 0244 EXCEPT: the two inline space_x/space_y blocks become ONE
-- canonical_coord_violation() call, and the v_x/v_y parse is relocated to just after the validation
-- gate (reached only when both are valid in-range numbers, exactly as the inline `else` guaranteed).
create or replace function public.exploration_site_create(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_fields  jsonb;
  v_details jsonb := '[]'::jsonb;
  v_name    text;
  v_x       numeric;
  v_y       numeric;
  v_bundle  jsonb;
  v_items   jsonb;
  v_item    jsonb;
  v_i       int;
  v_after   jsonb;
  v_result  jsonb;
  v_prior   text;
  v_id      uuid;
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
             'command_type', 'exploration_site_create', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  v_fields := p_payload->'fields';
  if v_fields is null or jsonb_typeof(v_fields) <> 'object' then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'invalid_payload', 'field', null, 'message', 'payload.fields must be a JSON object.'));
  else
    v_name := btrim(coalesce(v_fields->>'name', ''));
    if v_name = '' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'name_required', 'field', 'name', 'message', 'Name is required (exploration_sites.name is NOT NULL).'));
    end if;

    -- coordinates — THE ONE canonical ±10000 authority (was two inline space_x/space_y blocks).
    v_details := v_details || public.canonical_coord_violation(
                   v_fields->'space_x', v_fields->'space_y', 'space_x', 'space_y');

    v_bundle := v_fields->'reward_bundle_json';
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
        if jsonb_typeof(v_item) <> 'object'
           or btrim(coalesce(v_item->>'item_id', '')) = '' then
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
  end if;

  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'validation_failed', 'details', v_details);
  end if;

  -- coordinates validated above by the canonical authority; parse them for the write.
  v_x := (v_fields->'space_x')::numeric;
  v_y := (v_fields->'space_y')::numeric;

  begin
    insert into public.exploration_sites (name, space_x, space_y, reward_bundle_json)
      values (v_name, v_x::double precision, v_y::double precision, v_bundle)
      returning jsonb_build_object(
                  'id', id, 'name', name, 'space_x', space_x, 'space_y', space_y,
                  'reward_bundle_json', reward_bundle_json, 'is_active', is_active,
                  'created_at', created_at),
                id
        into v_after, v_id;

    v_result := jsonb_build_object('created', true, 'id', v_id, 'name', v_name);

    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'exploration_site_create', 'exploration_site', v_id::text, v_result::text,
         null, v_after, p_payload->>'source_revision');
  exception when unique_violation then
    get stacked diagnostics v_conflict_table = TABLE_NAME;
    if v_conflict_table = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'exploration_site_create', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'conflict',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'duplicate_name', 'field', 'name',
               'message', 'An exploration site with this name already exists.')));
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id,
           'command_type', 'exploration_site_create', 'result', v_result);
end $$;

revoke all on function public.exploration_site_create(text, jsonb) from public;
grant execute on function public.exploration_site_create(text, jsonb) to authenticated;  -- guard is in-body; NEVER anon
revoke insert, update, delete on table public.exploration_sites from anon, authenticated;

-- ── 3. exploration_site_update — 0247 body, coordinate checks routed through the ONE authority ────
create or replace function public.exploration_site_update(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_target   text;
  v_expected jsonb;
  v_fields   jsonb;
  v_details  jsonb := '[]'::jsonb;
  v_name     text;
  v_x        numeric;
  v_y        numeric;
  v_bundle   jsonb;          -- null ⇒ keep the live bundle (unauthorable on an edit draft)
  v_items    jsonb;
  v_item     jsonb;
  v_i        int;
  v_live     record;         -- the LOCKED live row
  v_before   jsonb;
  v_after    jsonb;
  v_result   jsonb;
  v_prior    text;
  v_id       uuid;
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
             'command_type', 'exploration_site_update', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  v_target   := btrim(coalesce(p_payload->>'target_id', ''));
  v_expected := p_payload->'expected';
  if v_target = '' or v_expected is null or jsonb_typeof(v_expected) <> 'object' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;

  select id, name, space_x, space_y, reward_bundle_json, is_active, created_at
    into v_live
    from public.exploration_sites
   where name = v_target
     for update;
  if not found then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_found',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_missing', 'field', null,
               'message', 'No live exploration site named ''' || v_target || ''' exists — it may have been renamed or removed since the draft was forked.')));
  end if;

  if v_expected->>'name' is distinct from v_live.name then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'name',
      'message', 'The live site''s name changed since this draft was forked.'));
  end if;
  if v_expected->'space_x' is distinct from to_jsonb(v_live.space_x) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'space_x',
      'message', 'The live site''s space_x changed since this draft was forked.'));
  end if;
  if v_expected->'space_y' is distinct from to_jsonb(v_live.space_y) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'space_y',
      'message', 'The live site''s space_y changed since this draft was forked.'));
  end if;
  if v_expected->'reward_bundle_json' is not null
     and jsonb_typeof(v_expected->'reward_bundle_json') <> 'null'
     and v_expected->'reward_bundle_json' is distinct from v_live.reward_bundle_json then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'reward_bundle_json',
      'message', 'The live site''s reward bundle changed since this draft was forked.'));
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
        'code', 'name_required', 'field', 'name', 'message', 'Name is required (exploration_sites.name is NOT NULL).'));
    end if;

    -- coordinates — THE ONE canonical ±10000 authority (was two inline space_x/space_y blocks).
    v_details := v_details || public.canonical_coord_violation(
                   v_fields->'space_x', v_fields->'space_y', 'space_x', 'space_y');

    v_bundle := v_fields->'reward_bundle_json';
    if v_bundle is null or jsonb_typeof(v_bundle) = 'null' then
      v_bundle := null;   -- keep the live bundle (the update-specific null semantics, header §)
    elsif jsonb_typeof(v_bundle) <> 'object' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'reward_bundle_invalid', 'field', 'reward_bundle_json',
        'message', 'reward_bundle_json must be a JSON object with a non-empty items[] list (or null to keep the live bundle).'));
    elsif jsonb_typeof(v_bundle->'items') is distinct from 'array' or jsonb_array_length(v_bundle->'items') = 0 then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'reward_bundle_invalid', 'field', 'reward_bundle_json',
        'message', 'Reward bundle must carry a non-empty items[] list.'));
    else
      v_items := v_bundle->'items';
      for v_i in 0 .. jsonb_array_length(v_items) - 1 loop
        v_item := v_items->v_i;
        if jsonb_typeof(v_item) <> 'object'
           or btrim(coalesce(v_item->>'item_id', '')) = '' then
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
  end if;

  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'validation_failed', 'details', v_details);
  end if;

  -- coordinates validated above by the canonical authority; parse them for the write.
  v_x := (v_fields->'space_x')::numeric;
  v_y := (v_fields->'space_y')::numeric;

  v_before := jsonb_build_object(
                'id', v_live.id, 'name', v_live.name, 'space_x', v_live.space_x,
                'space_y', v_live.space_y, 'reward_bundle_json', v_live.reward_bundle_json,
                'is_active', v_live.is_active, 'created_at', v_live.created_at);
  begin
    update public.exploration_sites
       set name    = v_name,
           space_x = v_x::double precision,
           space_y = v_y::double precision,
           reward_bundle_json = coalesce(v_bundle, reward_bundle_json)
     where id = v_live.id
     returning jsonb_build_object(
                 'id', id, 'name', name, 'space_x', space_x, 'space_y', space_y,
                 'reward_bundle_json', reward_bundle_json, 'is_active', is_active,
                 'created_at', created_at),
               id
       into v_after, v_id;

    v_result := jsonb_build_object('updated', true, 'id', v_id, 'name', v_name);

    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'exploration_site_update', 'exploration_site', v_id::text, v_result::text,
         v_before, v_after, p_payload->>'source_revision');
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
end $$;

revoke all on function public.exploration_site_update(text, jsonb) from public;
grant execute on function public.exploration_site_update(text, jsonb) to authenticated;  -- guard is in-body; NEVER anon

-- ── 4. mining_field_create — 0246 body, coordinate checks routed through the ONE authority ────────
create or replace function public.mining_field_create(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_fields  jsonb;
  v_details jsonb := '[]'::jsonb;
  v_name    text;
  v_x       numeric;
  v_y       numeric;
  v_bundle  jsonb;
  v_items   jsonb;
  v_item    jsonb;
  v_i       int;
  v_after   jsonb;
  v_result  jsonb;
  v_prior   text;
  v_id      uuid;
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
             'command_type', 'mining_field_create', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  v_fields := p_payload->'fields';
  if v_fields is null or jsonb_typeof(v_fields) <> 'object' then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'invalid_payload', 'field', null, 'message', 'payload.fields must be a JSON object.'));
  else
    v_name := btrim(coalesce(v_fields->>'name', ''));
    if v_name = '' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'name_required', 'field', 'name', 'message', 'Name is required (mining_fields.name is NOT NULL).'));
    end if;

    -- coordinates — THE ONE canonical ±10000 authority (was two inline space_x/space_y blocks).
    v_details := v_details || public.canonical_coord_violation(
                   v_fields->'space_x', v_fields->'space_y', 'space_x', 'space_y');

    v_bundle := v_fields->'reward_bundle_json';
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
        if jsonb_typeof(v_item) <> 'object'
           or btrim(coalesce(v_item->>'item_id', '')) = '' then
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
  end if;

  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'validation_failed', 'details', v_details);
  end if;

  -- coordinates validated above by the canonical authority; parse them for the write.
  v_x := (v_fields->'space_x')::numeric;
  v_y := (v_fields->'space_y')::numeric;

  begin
    insert into public.mining_fields (name, space_x, space_y, reward_bundle_json)
      values (v_name, v_x::double precision, v_y::double precision, v_bundle)
      returning jsonb_build_object(
                  'id', id, 'name', name, 'space_x', space_x, 'space_y', space_y,
                  'reward_bundle_json', reward_bundle_json, 'is_active', is_active,
                  'created_at', created_at),
                id
        into v_after, v_id;

    v_result := jsonb_build_object('created', true, 'id', v_id, 'name', v_name);

    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'mining_field_create', 'mining_field', v_id::text, v_result::text,
         null, v_after, p_payload->>'source_revision');
  exception when unique_violation then
    get stacked diagnostics v_conflict_table = TABLE_NAME;
    if v_conflict_table = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'mining_field_create', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'conflict',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'duplicate_name', 'field', 'name',
               'message', 'A mining field with this name already exists.')));
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id,
           'command_type', 'mining_field_create', 'result', v_result);
end $$;

revoke all on function public.mining_field_create(text, jsonb) from public;
grant execute on function public.mining_field_create(text, jsonb) to authenticated;  -- guard is in-body; NEVER anon
revoke insert, update, delete on table public.mining_fields from anon, authenticated;

-- ── 5. mining_field_update — 0248 body, coordinate checks routed through the ONE authority ────────
create or replace function public.mining_field_update(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_target   text;
  v_expected jsonb;
  v_fields   jsonb;
  v_details  jsonb := '[]'::jsonb;
  v_name     text;
  v_x        numeric;
  v_y        numeric;
  v_bundle   jsonb;          -- null ⇒ keep the live bundle (unauthorable on an edit draft)
  v_items    jsonb;
  v_item     jsonb;
  v_i        int;
  v_live     record;         -- the LOCKED live row
  v_before   jsonb;
  v_after    jsonb;
  v_result   jsonb;
  v_prior    text;
  v_id       uuid;
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
             'command_type', 'mining_field_update', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  v_target   := btrim(coalesce(p_payload->>'target_id', ''));
  v_expected := p_payload->'expected';
  if v_target = '' or v_expected is null or jsonb_typeof(v_expected) <> 'object' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;

  select id, name, space_x, space_y, reward_bundle_json, is_active, created_at
    into v_live
    from public.mining_fields
   where name = v_target
     for update;
  if not found then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_found',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_missing', 'field', null,
               'message', 'No live mining field named ''' || v_target || ''' exists — it may have been renamed or removed since the draft was forked.')));
  end if;

  if v_expected->>'name' is distinct from v_live.name then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'name',
      'message', 'The live field''s name changed since this draft was forked.'));
  end if;
  if v_expected->'space_x' is distinct from to_jsonb(v_live.space_x) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'space_x',
      'message', 'The live field''s space_x changed since this draft was forked.'));
  end if;
  if v_expected->'space_y' is distinct from to_jsonb(v_live.space_y) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'space_y',
      'message', 'The live field''s space_y changed since this draft was forked.'));
  end if;
  if v_expected->'reward_bundle_json' is not null
     and jsonb_typeof(v_expected->'reward_bundle_json') <> 'null'
     and v_expected->'reward_bundle_json' is distinct from v_live.reward_bundle_json then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'reward_bundle_json',
      'message', 'The live field''s reward bundle changed since this draft was forked.'));
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
        'code', 'name_required', 'field', 'name', 'message', 'Name is required (mining_fields.name is NOT NULL).'));
    end if;

    -- coordinates — THE ONE canonical ±10000 authority (was two inline space_x/space_y blocks).
    v_details := v_details || public.canonical_coord_violation(
                   v_fields->'space_x', v_fields->'space_y', 'space_x', 'space_y');

    v_bundle := v_fields->'reward_bundle_json';
    if v_bundle is null or jsonb_typeof(v_bundle) = 'null' then
      v_bundle := null;   -- keep the live bundle (the update-specific null semantics, header §)
    elsif jsonb_typeof(v_bundle) <> 'object' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'reward_bundle_invalid', 'field', 'reward_bundle_json',
        'message', 'reward_bundle_json must be a JSON object with a non-empty items[] list (or null to keep the live bundle).'));
    elsif jsonb_typeof(v_bundle->'items') is distinct from 'array' or jsonb_array_length(v_bundle->'items') = 0 then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'reward_bundle_invalid', 'field', 'reward_bundle_json',
        'message', 'Reward bundle must carry a non-empty items[] list.'));
    else
      v_items := v_bundle->'items';
      for v_i in 0 .. jsonb_array_length(v_items) - 1 loop
        v_item := v_items->v_i;
        if jsonb_typeof(v_item) <> 'object'
           or btrim(coalesce(v_item->>'item_id', '')) = '' then
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
  end if;

  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'validation_failed', 'details', v_details);
  end if;

  -- coordinates validated above by the canonical authority; parse them for the write.
  v_x := (v_fields->'space_x')::numeric;
  v_y := (v_fields->'space_y')::numeric;

  v_before := jsonb_build_object(
                'id', v_live.id, 'name', v_live.name, 'space_x', v_live.space_x,
                'space_y', v_live.space_y, 'reward_bundle_json', v_live.reward_bundle_json,
                'is_active', v_live.is_active, 'created_at', v_live.created_at);
  begin
    update public.mining_fields
       set name    = v_name,
           space_x = v_x::double precision,
           space_y = v_y::double precision,
           reward_bundle_json = coalesce(v_bundle, reward_bundle_json)
     where id = v_live.id
     returning jsonb_build_object(
                 'id', id, 'name', name, 'space_x', space_x, 'space_y', space_y,
                 'reward_bundle_json', reward_bundle_json, 'is_active', is_active,
                 'created_at', created_at),
               id
       into v_after, v_id;

    v_result := jsonb_build_object('updated', true, 'id', v_id, 'name', v_name);

    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'mining_field_update', 'mining_field', v_id::text, v_result::text,
         v_before, v_after, p_payload->>'source_revision');
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
end $$;

revoke all on function public.mining_field_update(text, jsonb) from public;
grant execute on function public.mining_field_update(text, jsonb) to authenticated;  -- guard is in-body; NEVER anon

-- ── 6. location_create — 0264 body (anchor write-authority), coords via the ONE authority ─────────
-- Byte-identical to the 0264 redefinition (incl. the ANCHOR AUTHORITY insert) EXCEPT: the two inline
-- x/y blocks become ONE canonical_coord_violation() call, and the v_x/v_y parse is relocated to just
-- after the validation gate. The anchor is still written from v_x/v_y (::double precision), so the
-- stored location coordinate AND its space_anchor are byte-identical to 0264.
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

    -- ── ANCHOR AUTHORITY (0264): the created location's coordinate lives in space_anchors from birth. One
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

-- ── 7. location_update — 0264 body (anchor write-authority), coords via the ONE authority ─────────
-- Byte-identical to the 0264 redefinition (incl. the ANCHOR AUTHORITY retire+insert on a coordinate
-- change) EXCEPT: the two inline x/y blocks become ONE canonical_coord_violation() call, and the
-- v_x/v_y parse is relocated to just after the validation gate. The anchor relocation still compares
-- v_x/v_y (::double precision) against the locked live row, so its trigger and stored coord match 0264.
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

-- ── 8. self-assert (deploy-time; any raise aborts the txn — nothing half-applies) ─────────────────
do $canonassert$
declare
  v_src   text;
  v_frag  jsonb;
begin
  -- (a) the ONE authority exists, is IMMUTABLE, and is a pure function (no table dependency).
  if to_regprocedure('public.canonical_coord_violation(jsonb, jsonb, text, text)') is null then
    raise exception 'CANONICAL-COORD self-assert FAIL: canonical_coord_violation(jsonb,jsonb,text,text) missing';
  end if;
  if not exists (select 1 from pg_proc
                 where oid = 'public.canonical_coord_violation(jsonb,jsonb,text,text)'::regprocedure
                   and provolatile = 'i') then
    raise exception 'CANONICAL-COORD self-assert FAIL: canonical_coord_violation is not IMMUTABLE';
  end if;

  -- (b) the authority is BEHAVIOR-CORRECT on the frame boundaries and both codes (NON-raising):
  --     valid mid-range ⇒ [] ; boundary 10000/-10000 ⇒ [] (inclusive) ; a number just outside ⇒
  --     coord_out_of_bounds ; a non-number ⇒ numeric_not_finite ; field name + message interpolated.
  if public.canonical_coord_violation('1234.5'::jsonb, '-4321.25'::jsonb, 'x', 'y') <> '[]'::jsonb then
    raise exception 'CANONICAL-COORD self-assert FAIL: a valid mid-range coord did not yield []';
  end if;
  if public.canonical_coord_violation('10000'::jsonb, '-10000'::jsonb, 'x', 'y') <> '[]'::jsonb then
    raise exception 'CANONICAL-COORD self-assert FAIL: the inclusive ±10000 boundary did not yield []';
  end if;
  v_frag := public.canonical_coord_violation('10001'::jsonb, '5'::jsonb, 'space_x', 'space_y');
  if v_frag <> jsonb_build_array(jsonb_build_object(
       'code','coord_out_of_bounds','field','space_x','message','space_x must be within ±10000.')) then
    raise exception 'CANONICAL-COORD self-assert FAIL: x=10001 did not yield the exact coord_out_of_bounds detail: %', v_frag;
  end if;
  v_frag := public.canonical_coord_violation('"nope"'::jsonb, 'null'::jsonb, 'x', 'y');
  if v_frag <> jsonb_build_array(
       jsonb_build_object('code','numeric_not_finite','field','x','message','x must be a finite number.'),
       jsonb_build_object('code','numeric_not_finite','field','y','message','y must be a finite number.')) then
    raise exception 'CANONICAL-COORD self-assert FAIL: non-number x + null y did not yield the exact numeric_not_finite details (x then y): %', v_frag;
  end if;

  -- (c) all six RPCs still exist, are SECURITY DEFINER, authenticated-only, anon-denied, and now call
  --     the ONE authority (their bodies reference canonical_coord_violation; the inline ±10000 check is gone).
  if not (select prosecdef from pg_proc where oid = 'public.exploration_site_create(text,jsonb)'::regprocedure)
     or not (select prosecdef from pg_proc where oid = 'public.exploration_site_update(text,jsonb)'::regprocedure)
     or not (select prosecdef from pg_proc where oid = 'public.mining_field_create(text,jsonb)'::regprocedure)
     or not (select prosecdef from pg_proc where oid = 'public.mining_field_update(text,jsonb)'::regprocedure)
     or not (select prosecdef from pg_proc where oid = 'public.location_create(text,jsonb)'::regprocedure)
     or not (select prosecdef from pg_proc where oid = 'public.location_update(text,jsonb)'::regprocedure) then
    raise exception 'CANONICAL-COORD self-assert FAIL: a target RPC lost SECURITY DEFINER';
  end if;

  -- each RPC body now routes through the ONE authority and no longer carries the inline coordinate check.
  select prosrc into v_src from pg_proc where oid = 'public.exploration_site_create(text,jsonb)'::regprocedure;
  if position('canonical_coord_violation' in v_src) = 0 or position('space_x must be within' in v_src) <> 0 then
    raise exception 'CANONICAL-COORD self-assert FAIL: exploration_site_create not routed through the authority';
  end if;
  select prosrc into v_src from pg_proc where oid = 'public.exploration_site_update(text,jsonb)'::regprocedure;
  if position('canonical_coord_violation' in v_src) = 0 or position('space_x must be within' in v_src) <> 0 then
    raise exception 'CANONICAL-COORD self-assert FAIL: exploration_site_update not routed through the authority';
  end if;
  select prosrc into v_src from pg_proc where oid = 'public.mining_field_create(text,jsonb)'::regprocedure;
  if position('canonical_coord_violation' in v_src) = 0 or position('space_x must be within' in v_src) <> 0 then
    raise exception 'CANONICAL-COORD self-assert FAIL: mining_field_create not routed through the authority';
  end if;
  select prosrc into v_src from pg_proc where oid = 'public.mining_field_update(text,jsonb)'::regprocedure;
  if position('canonical_coord_violation' in v_src) = 0 or position('space_x must be within' in v_src) <> 0 then
    raise exception 'CANONICAL-COORD self-assert FAIL: mining_field_update not routed through the authority';
  end if;
  select prosrc into v_src from pg_proc where oid = 'public.location_create(text,jsonb)'::regprocedure;
  if position('canonical_coord_violation' in v_src) = 0 or position('x must be within' in v_src) <> 0 then
    raise exception 'CANONICAL-COORD self-assert FAIL: location_create not routed through the authority';
  end if;
  -- location_create MUST still write the anchor (0264 behavior preserved).
  if position('insert into public.space_anchors' in v_src) = 0 then
    raise exception 'CANONICAL-COORD self-assert FAIL: location_create no longer writes a space_anchor (0264 anchor authority regressed)';
  end if;
  select prosrc into v_src from pg_proc where oid = 'public.location_update(text,jsonb)'::regprocedure;
  if position('canonical_coord_violation' in v_src) = 0 or position('x must be within' in v_src) <> 0 then
    raise exception 'CANONICAL-COORD self-assert FAIL: location_update not routed through the authority';
  end if;
  -- location_update MUST still retire+insert the anchor on a coordinate change (0264 behavior preserved).
  if position('insert into public.space_anchors' in v_src) = 0
     or position('set status = ''retired''' in v_src) = 0 then
    raise exception 'CANONICAL-COORD self-assert FAIL: location_update no longer retires+inserts the anchor (0264 anchor authority regressed)';
  end if;

  -- (d) ACL posture intact: authenticated may execute each; anon may NOT.
  if not has_function_privilege('authenticated', 'public.exploration_site_create(text,jsonb)', 'execute')
     or not has_function_privilege('authenticated', 'public.exploration_site_update(text,jsonb)', 'execute')
     or not has_function_privilege('authenticated', 'public.mining_field_create(text,jsonb)', 'execute')
     or not has_function_privilege('authenticated', 'public.mining_field_update(text,jsonb)', 'execute')
     or not has_function_privilege('authenticated', 'public.location_create(text,jsonb)', 'execute')
     or not has_function_privilege('authenticated', 'public.location_update(text,jsonb)', 'execute') then
    raise exception 'CANONICAL-COORD self-assert FAIL: an authenticated execute grant was lost on a target RPC';
  end if;
  if has_function_privilege('anon', 'public.exploration_site_create(text,jsonb)', 'execute')
     or has_function_privilege('anon', 'public.exploration_site_update(text,jsonb)', 'execute')
     or has_function_privilege('anon', 'public.mining_field_create(text,jsonb)', 'execute')
     or has_function_privilege('anon', 'public.mining_field_update(text,jsonb)', 'execute')
     or has_function_privilege('anon', 'public.location_create(text,jsonb)', 'execute')
     or has_function_privilege('anon', 'public.location_update(text,jsonb)', 'execute') then
    raise exception 'CANONICAL-COORD self-assert FAIL: anon CAN execute a target RPC — must be authenticated-only';
  end if;

  -- (e) no client-role write grant regained on any target table (the writes stay definer-only); SELECT posture
  --     on locations survives (the map read depends on it).
  if has_table_privilege('authenticated', 'public.locations', 'INSERT')
     or has_table_privilege('authenticated', 'public.locations', 'UPDATE')
     or has_table_privilege('authenticated', 'public.locations', 'DELETE')
     or has_table_privilege('anon', 'public.locations', 'INSERT')
     or has_table_privilege('authenticated', 'public.exploration_sites', 'INSERT')
     or has_table_privilege('authenticated', 'public.exploration_sites', 'UPDATE')
     or has_table_privilege('authenticated', 'public.mining_fields', 'INSERT')
     or has_table_privilege('authenticated', 'public.mining_fields', 'UPDATE') then
    raise exception 'CANONICAL-COORD self-assert FAIL: a client role holds a write grant on a target table';
  end if;
  if not has_table_privilege('anon', 'public.locations', 'SELECT')
     or not has_table_privilege('authenticated', 'public.locations', 'SELECT') then
    raise exception 'CANONICAL-COORD self-assert FAIL: a client role lost SELECT on locations — the map read would break';
  end if;

  raise notice 'CANONICAL-COORD self-assert ok: one IMMUTABLE canonical_coord_violation authority ([] on valid + inclusive ±10000 boundary; exact coord_out_of_bounds / numeric_not_finite details x-then-y); all six RPCs SECURITY DEFINER + authenticated-only + routed through it (inline ±10000 checks removed); locations/exploration/mining writes stay definer-only; 0264 anchor authority intact';
end $canonassert$;
