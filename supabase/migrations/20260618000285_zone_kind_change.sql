-- Byeharu — ZONE KIND CHANGE (migration 0285). The fourth and last authoring intent.
-- LANDS DARK behind typed_zone_authoring_enabled (still false). One owner-gated command.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHY THIS WAS HELD BACK UNTIL EVERY OTHER INTENT EXISTED
-- Slice 5a shipped geometry and behaviour authoring and deliberately refused to ship this one. The
-- reason is the failure it invites: a zone converted from pirate to mining that KEEPS its
-- pirate_intercept effect row is now a "mining" zone that still intercepts fleets. Nothing in the
-- schema forbids it — effects are keyed by zone_id, not by kind, precisely so they compose — so the
-- stale effect just sits there, invisible, doing its old job under a new name.
--
-- That is not a hypothetical. It is the exact shape of the bug this platform was built to remove:
-- something happening because of what a row IS rather than what it DECLARES.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE CONVERSION RULE, STATED ONCE AND ENFORCED
-- A kind change is REFUSED while the zone still carries an effect that does not belong to the target
-- kind. It does NOT silently delete those effects: destroying authored configuration to satisfy a
-- rename is a far worse trade than making the owner say what they mean. The rejection names every
-- offending effect, so the fix is one zone_effect_remove call per named effect and then a retry.
--
-- "Belongs to" is a declared table, not a guess:
--     pirate      -> pirate_intercept
--     combat      -> combat
--     mining      -> mining
--     exploration -> exploration
-- A kind may legitimately carry MORE than its namesake later (a mining zone that also spawns), so the
-- rule is one-directional: an effect must be PERMITTED by the target kind, and today each kind
-- permits exactly its own. Widening a kind's permission set is a data change in one table, not a
-- code change scattered across a command.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- IT CHANGES IDENTITY AND NOTHING ELSE
-- Not geometry, not effects, not lifecycle. The same separate-intents discipline as slice 5a, and the
-- self-assert proves it: the only danger_zones columns this command may write are zone_kind and the
-- revision bump. `provenance` is untouched and could not be written anyway — 0282's trigger forbids it.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. preconditions ────────────────────────────────────────────────────────────────────────────
do $pre$
begin
  if to_regclass('public.zone_effect_exploration') is null then
    raise exception 'ZONE KIND CHANGE 0285: the effect tables (through 0281) must exist';
  end if;
  if not exists (select 1 from public.game_config where key = 'typed_zone_authoring_enabled') then
    raise exception 'ZONE KIND CHANGE 0285: typed_zone_authoring_enabled (0273) is missing';
  end if;
end $pre$;

-- ── 1. the permission table — data, not a CASE buried in a command ──────────────────────────────
create table public.zone_kind_permitted_effects (
  zone_kind   text not null,
  effect_type text not null,
  primary key (zone_kind, effect_type)
);

insert into public.zone_kind_permitted_effects (zone_kind, effect_type) values
  ('pirate',      'pirate_intercept'),
  ('combat',      'combat'),
  ('mining',      'mining'),
  ('exploration', 'exploration');

comment on table public.zone_kind_permitted_effects is
  'ZONE KIND CHANGE (0285): which effects a zone of a given kind may carry. Data rather than a CASE '
  'inside zone_kind_change, so letting (say) a mining zone also spawn is one INSERT and no code '
  'change. Read ONLY by the kind-conversion guard — it never gates dispatch, because effects decide '
  'behaviour and identity must never dispatch anything.';

alter table public.zone_kind_permitted_effects enable row level security;
revoke all on table public.zone_kind_permitted_effects from anon, authenticated;

-- ── 2. zone_kind_change ─────────────────────────────────────────────────────────────────────────
-- payload = { target_id, new_kind, expected: { name, source, zone_kind } }
create or replace function public.zone_kind_change(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_target    text;
  v_target_id uuid;
  v_new_kind  text;
  v_expected  jsonb;
  v_live      record;
  v_prior     text;
  v_before    jsonb;
  v_after     jsonb;
  v_result    jsonb;
  v_details   jsonb := '[]'::jsonb;
  v_conflict  text;
  v_rev       integer;
  v_stale     text[];
begin
  -- (1) authn
  if v_uid is null then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authenticated');
  end if;
  -- (2) authz
  if not public.is_owner() then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authorized');
  end if;
  -- (3) request id
  if p_request_id is null or length(btrim(p_request_id)) = 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;
  -- (4) capability gate — after authz, before any world read
  if not coalesce(public.cfg_bool('typed_zone_authoring_enabled'), false) then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'validation_failed',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'authoring_disabled', 'field', null,
               'message', 'Typed-zone authoring is not enabled.')));
  end if;
  -- (5) idempotent replay — ahead of every judgement, per the 0284 precedence rule
  select result into v_prior from public.world_editor_audit where request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'request_id', p_request_id,
             'command_type', 'zone_kind_change', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  -- (6) addressing
  v_target   := btrim(coalesce(p_payload->>'target_id', ''));
  v_new_kind := coalesce(p_payload->>'new_kind', '');
  v_expected := p_payload->'expected';
  if v_target = '' or v_new_kind = '' or v_expected is null or jsonb_typeof(v_expected) <> 'object' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;
  begin
    v_target_id := v_target::uuid;
  exception when invalid_text_representation then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end;
  if not exists (select 1 from public.zone_kind_permitted_effects where zone_kind = v_new_kind) then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'validation_failed',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'unsupported_zone_kind', 'field', 'new_kind',
               'message', 'That is not a zone kind this world recognises.')));
  end if;

  -- (7) locate + ROW LOCK
  select id, name, source, location_id, zone_kind, status, revision, provenance
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

  -- (8) ELIGIBILITY, BEFORE THE CONCURRENCY COMPARE — the 0284 precedence rule. A refusal that is
  -- categorical must not masquerade as a conflict.
  --
  -- (8a) THE CONVERSION RULE: refuse while a non-permitted effect remains. Deleting it to make the
  -- rename succeed would destroy authored configuration to satisfy a label, and would recreate the
  -- exact bug this platform exists to remove — a zone still doing its old job under a new name.
  select coalesce(array_agg(e.effect_type order by e.effect_type), array[]::text[]) into v_stale
    from (
      select 'pirate_intercept'::text as effect_type from public.zone_effect_pirate_intercept where zone_id = v_target_id
      union all
      select 'combat'      from public.zone_effect_combat      where zone_id = v_target_id
      union all
      select 'mining'      from public.zone_effect_mining      where zone_id = v_target_id
      union all
      select 'exploration' from public.zone_effect_exploration where zone_id = v_target_id
    ) e
   where not exists (
     select 1 from public.zone_kind_permitted_effects p
      where p.zone_kind = v_new_kind and p.effect_type = e.effect_type);

  if array_length(v_stale, 1) is not null then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'validation_failed',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'incompatible_effects', 'field', 'new_kind',
               'message', 'This zone still carries effect(s) a ''' || v_new_kind ||
                          ''' zone does not permit: ' || array_to_string(v_stale, ', ') ||
                          '. Remove them first — they are not deleted automatically.',
               'effects', to_jsonb(v_stale))));
  end if;

  -- (8b) a no-op conversion is a typed outcome, not a silent success that burns a request_id
  if v_live.zone_kind = v_new_kind then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'validation_failed',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'already_that_kind', 'field', 'new_kind',
               'message', 'This zone is already of that kind.')));
  end if;

  -- (9) OPTIMISTIC CONCURRENCY — now that the operation is known to be permitted
  if (v_expected->>'name') is distinct from v_live.name then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'name', 'message', 'The zone''s name changed since the draft was forked.'));
  end if;
  if (v_expected->>'source') is distinct from v_live.source then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'source', 'message', 'The zone''s source changed since the draft was forked.'));
  end if;
  if (v_expected->>'zone_kind') is distinct from v_live.zone_kind then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'source_changed', 'field', 'zone_kind', 'message', 'The zone''s kind changed since the draft was forked.'));
  end if;
  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id,
             'error', 'stale_revision', 'details', v_details);
  end if;

  -- (10) WRITE — identity and the revision bump, nothing else
  v_before := jsonb_build_object('id', v_live.id, 'zone_kind', v_live.zone_kind,
                                 'name', v_live.name, 'source', v_live.source,
                                 'provenance', v_live.provenance, 'revision', v_live.revision);

  update public.danger_zones set zone_kind = v_new_kind, revision = revision + 1
   where id = v_target_id
   returning revision into v_rev;

  v_after := jsonb_build_object('id', v_live.id, 'zone_kind', v_new_kind,
                                'name', v_live.name, 'source', v_live.source,
                                'provenance', v_live.provenance, 'revision', v_rev);
  v_result := jsonb_build_object('zone_id', v_target_id, 'from_kind', v_live.zone_kind,
                                 'to_kind', v_new_kind, 'revision', v_rev);

  begin
    insert into public.world_editor_audit
      (actor, request_id, command_type, target_type, target_id, result,
       before_snapshot, after_snapshot, source_revision)
    values
      (v_uid, p_request_id, 'zone_kind_change', 'zone', v_target_id::text, v_result::text,
       v_before, v_after, p_payload->>'source_revision');
  exception when unique_violation then
    get stacked diagnostics v_conflict = TABLE_NAME;
    if v_conflict = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'zone_kind_change', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    raise;
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id,
           'command_type', 'zone_kind_change', 'result', v_result);
end;
$$;

revoke execute on function public.zone_kind_change(text, jsonb) from public, anon;
grant execute on function public.zone_kind_change(text, jsonb) to authenticated;

comment on function public.zone_kind_change(text, jsonb) is
  'ZONE KIND CHANGE (0285): the fourth authoring intent. Changes IDENTITY and nothing else — not '
  'geometry, not effects, not lifecycle. REFUSES while the zone carries an effect the target kind '
  'does not permit, naming each one, rather than deleting authored configuration to satisfy a rename. '
  'Dark behind typed_zone_authoring_enabled.';

-- ── 3. SELF-ASSERT ──────────────────────────────────────────────────────────────────────────────
do $kind$
declare v_def text;
begin
  if coalesce(public.cfg_bool('typed_zone_authoring_enabled'), true) then
    raise exception 'ZONE KIND CHANGE 0285 self-assert FAIL: typed_zone_authoring_enabled is not false'; end if;

  select pg_get_functiondef(to_regprocedure('public.zone_kind_change(text, jsonb)')) into v_def;
  if v_def is null then raise exception 'ZONE KIND CHANGE 0285 self-assert FAIL: the command is missing'; end if;

  -- IDENTITY ONLY: the only danger_zones write is zone_kind + the revision bump
  if v_def ~* 'update public\.danger_zones set [^;]*(boundary|status|location_id|provenance)' then
    raise exception 'ZONE KIND CHANGE 0285 self-assert FAIL: the command writes geometry, lifecycle, attachment or provenance';
  end if;
  if strpos(v_def, 'set zone_kind = v_new_kind, revision = revision + 1') = 0 then
    raise exception 'ZONE KIND CHANGE 0285 self-assert FAIL: it does not change identity and bump the revision together';
  end if;
  -- it must never delete an effect to make a conversion succeed
  if v_def ~* 'delete from public\.zone_effect_' then
    raise exception 'ZONE KIND CHANGE 0285 self-assert FAIL: the command deletes effects — authored config must not be destroyed to satisfy a rename';
  end if;

  -- PRECEDENCE (the 0284 rule): replay < eligibility < concurrency
  if strpos(v_def, 'from public.world_editor_audit where request_id')
     > strpos(v_def, 'incompatible_effects') then
    raise exception 'ZONE KIND CHANGE 0285 self-assert FAIL: eligibility is evaluated before the idempotent replay'; end if;
  if strpos(v_def, 'incompatible_effects') > strpos(v_def, '''stale_revision''') then
    raise exception 'ZONE KIND CHANGE 0285 self-assert FAIL: it reports stale_revision before the categorical refusal'; end if;
  if strpos(v_def, 'for update') > strpos(v_def, 'incompatible_effects') then
    raise exception 'ZONE KIND CHANGE 0285 self-assert FAIL: eligibility is evaluated before the row lock'; end if;

  -- the permitted-effect map is DATA and covers every kind the widened CHECK admits
  if exists (
    select 1 from unnest(array['pirate','combat','mining','exploration']) k(kind)
     where not exists (select 1 from public.zone_kind_permitted_effects p where p.zone_kind = k.kind)) then
    raise exception 'ZONE KIND CHANGE 0285 self-assert FAIL: a permitted zone_kind has no effect mapping';
  end if;
  -- and it must not be readable by the dispatchers — identity never dispatches
  if pg_get_functiondef(to_regprocedure('public.typed_zone_effect_dispatch_v2(jsonb)'))
       ilike '%zone_kind_permitted_effects%' then
    raise exception 'ZONE KIND CHANGE 0285 self-assert FAIL: a dispatcher reads the kind/effect map — identity must never dispatch';
  end if;

  -- house gate chain
  if strpos(v_def, 'not_authenticated') = 0 or strpos(v_def, 'is_owner()') = 0
     or strpos(v_def, 'typed_zone_authoring_enabled') = 0 or strpos(v_def, 'duplicate_request') = 0 then
    raise exception 'ZONE KIND CHANGE 0285 self-assert FAIL: part of the gate chain is missing'; end if;
  if has_function_privilege('anon', 'public.zone_kind_change(text, jsonb)', 'execute') then
    raise exception 'ZONE KIND CHANGE 0285 self-assert FAIL: anon can execute the command'; end if;

  raise notice 'ZONE KIND CHANGE 0285 self-assert ok: lands DARK; changes IDENTITY only (the sole danger_zones write is zone_kind plus the revision bump — never geometry, lifecycle, attachment or provenance) and NEVER deletes an effect to make a conversion succeed; it REFUSES while a non-permitted effect remains, naming each one, so a converted zone can never keep doing its old job under a new name; precedence follows 0284 (replay, then row lock, then categorical eligibility, then the concurrency compare); the kind/effect map is DATA covering every permitted kind and no dispatcher reads it, because identity must never dispatch; the full house gate chain is present and anon cannot execute it';
end $kind$;
