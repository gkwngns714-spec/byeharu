-- Byeharu — WORLD EDITOR V1.5 (Operations & Audit UX): world_editor_audit_list — the owner-only
-- READ boundary over the world_editor_audit ledger, through the 0243 spine.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT THIS IS: the FIRST client-reachable read over public.world_editor_audit. The ledger is RLS
-- deny-all + no client grant (0243:107-108), so today NO browser can read it; every existing read is
-- an internal idempotency lookup inside a SECURITY DEFINER command body. This adds ONE owner-gated
-- SECURITY DEFINER reader that returns a FIELD-FILTERED, PAGINATED view — never a table grant, never
-- the raw snapshot.
--
-- WHY FIELD-FILTERED (not the raw snapshot): the before/after snapshots serialize server-only data
-- that must NOT reach any browser bundle:
--   • reward_bundle_json — the exploration/mining loot tables. Those tables are RLS-no-client-grant
--     and the map reads (get_active_mining_fields, 0226) return name+coords ONLY, deliberately never
--     the reward bundle (server-only economy players discover by extracting). This reader STRIPS it.
--   • created_by / actor — raw auth.users UUIDs. This reader NEVER returns them; it returns
--     actor_is_owner (a boolean) instead. (The ledger has a single seeded owner; the value is always
--     the owner, but a raw account identifier is still not shipped verbatim.)
-- Kept (the owner is the AUTHOR of this content, and map-focus needs geometry): name / coords /
-- boundary_wkt / status / the world-config fields already client-readable via get_world_map /
-- get_danger_zones. A `redactions` array lists what was withheld, per record, for transparency.
--
-- CONTRACT: authn (auth.uid() null → not_authenticated) → authz (is_owner() → not_authorized) →
-- WHITELISTED filter parse (command_type / target_type / target_id / request_id / since / until /
-- limit / cursor — NO dynamic SQL, NO json-path, unknown enum values → invalid_request) → KEYSET
-- pagination over (created_at desc, id desc), limit clamped 1..100 (default 50), a next_cursor when a
-- further page exists → field-filtered typed envelope {ok:true, items[], next_cursor, page_size}.
-- Read-only + STABLE: it writes nothing (no audit row of its own — a read is not a command).
--
-- DEPLOY POSTURE: UNDEPLOYED — deploy is a human gate. Fail-closed: inert until an owner is seeded
-- (is_owner() false for everyone on an unseeded DB). No client grant is widened: world_editor_audit
-- stays RLS deny-all + no client table grant; the ONLY read path is THIS SECURITY DEFINER function,
-- EXECUTE to authenticated (the guard is in-body), NEVER anon/public.
--
-- NO-SPAGHETTI: no second owner check (is_owner() only), no table grant, no view, no reward/loot
-- exposure, no raw account UUID egress, no write of any kind. Mirrors the narrow-projection read
-- idiom of get_active_mining_fields (0226) rather than a broad table SELECT.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. dependency gate ────────────────────────────────────────────────────────────────────────────
do $auditdep$
begin
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'WORLDEDIT-AUDIT-READ: public.world_editor_audit (0243) is missing — nothing to read';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'WORLDEDIT-AUDIT-READ: public.is_owner() (0243) is missing — THE ONE owner guard must exist first';
  end if;
  if not exists (select 1 from pg_attribute
                 where attrelid = 'public.world_editor_audit'::regclass
                   and attname = 'before_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'after_snapshot' and not attisdropped) then
    raise exception 'WORLDEDIT-AUDIT-READ: a 0244 audit snapshot column is missing — the read projects them';
  end if;
end $auditdep$;

-- ── 1. world_editor_audit_list — the owner-only, field-filtered, paginated reader ─────────────────
create or replace function public.world_editor_audit_list(p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_cmd       text;
  v_ttype     text;
  v_tid       text;
  v_reqid     text;
  v_since     timestamptz;
  v_until     timestamptz;
  v_limit     int;
  v_cursor    jsonb;
  v_cur_ts    timestamptz;
  v_cur_id    uuid;
  v_items     jsonb;
  v_next      jsonb;
  v_fetched   int;
  -- the closed vocabularies (0243–0255): a filter value outside these is a malformed request, never
  -- a silent empty result (and never reaches a dynamic query — this is a membership check only).
  c_commands  text[] := array['world_editor_ping','exploration_site_create','mining_field_create',
                              'location_create','zone_create','exploration_site_update',
                              'mining_field_update','location_update','exploration_site_set_active',
                              'mining_field_set_active','zone_unpublish'];
  c_targets   text[] := array['none','exploration_site','mining_field','location','zone'];
begin
  -- (1) authn
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'not_authenticated');
  end if;

  -- (2) authz — THE ONE guard
  if not public.is_owner() then
    return jsonb_build_object('ok', false, 'error', 'not_authorized');
  end if;

  -- (3) WHITELISTED filter parse. Every filter is an equality/range on a KNOWN column; enum-typed
  -- filters are validated against the closed vocabulary. Nothing is interpolated into SQL.
  v_cmd   := nullif(btrim(coalesce(p_payload->>'command_type', '')), '');
  v_ttype := nullif(btrim(coalesce(p_payload->>'target_type', '')), '');
  v_tid   := nullif(btrim(coalesce(p_payload->>'target_id', '')), '');
  v_reqid := nullif(btrim(coalesce(p_payload->>'request_id', '')), '');
  if v_cmd is not null and not (v_cmd = any(c_commands)) then
    return jsonb_build_object('ok', false, 'error', 'invalid_request',
      'details', jsonb_build_array(jsonb_build_object('code','unknown_command_type','field','command_type')));
  end if;
  if v_ttype is not null and not (v_ttype = any(c_targets)) then
    return jsonb_build_object('ok', false, 'error', 'invalid_request',
      'details', jsonb_build_array(jsonb_build_object('code','unknown_target_type','field','target_type')));
  end if;

  -- date range (optional, bounded by value validity)
  begin
    v_since := nullif(p_payload->>'since', '')::timestamptz;
    v_until := nullif(p_payload->>'until', '')::timestamptz;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'invalid_request',
      'details', jsonb_build_array(jsonb_build_object('code','bad_date_range','field','since/until')));
  end;

  -- limit — clamp to [1,100], default 50 (a bounded page; never unbounded egress)
  begin
    v_limit := coalesce(nullif(p_payload->>'limit', '')::int, 50);
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'invalid_request',
      'details', jsonb_build_array(jsonb_build_object('code','bad_limit','field','limit')));
  end;
  v_limit := least(greatest(v_limit, 1), 100);

  -- cursor — keyset {ts,id}; a malformed cursor is invalid_request (never ignored)
  v_cursor := p_payload->'cursor';
  if v_cursor is not null and jsonb_typeof(v_cursor) <> 'null' then
    if jsonb_typeof(v_cursor) <> 'object' or (v_cursor->>'ts') is null or (v_cursor->>'id') is null then
      return jsonb_build_object('ok', false, 'error', 'invalid_request',
        'details', jsonb_build_array(jsonb_build_object('code','bad_cursor','field','cursor')));
    end if;
    begin
      v_cur_ts := (v_cursor->>'ts')::timestamptz;
      v_cur_id := (v_cursor->>'id')::uuid;
    exception when others then
      return jsonb_build_object('ok', false, 'error', 'invalid_request',
        'details', jsonb_build_array(jsonb_build_object('code','bad_cursor','field','cursor')));
    end;
  end if;

  -- (4) keyset page (fetch limit+1 to know if a further page exists), then FIELD-FILTER each row.
  with page as (
    select a.id, a.created_at, a.request_id, a.command_type, a.target_type, a.target_id,
           a.result, a.source_revision, a.actor, a.before_snapshot, a.after_snapshot
      from public.world_editor_audit a
     where (v_cmd   is null or a.command_type = v_cmd)
       and (v_ttype is null or a.target_type  = v_ttype)
       and (v_tid   is null or a.target_id    = v_tid)
       and (v_reqid is null or a.request_id   = v_reqid)
       and (v_since is null or a.created_at  >= v_since)
       and (v_until is null or a.created_at  <  v_until)
       and (v_cur_ts is null
            or a.created_at < v_cur_ts
            or (a.created_at = v_cur_ts and a.id < v_cur_id))
     order by a.created_at desc, a.id desc
     limit v_limit + 1
  ),
  ranked as (select p.*, row_number() over (order by created_at desc, id desc) as rn from page p)
  select
    coalesce(jsonb_agg(
      jsonb_build_object(
        'id', r.id,
        'request_id', r.request_id,
        'command_type', r.command_type,
        'target_type', r.target_type,
        'target_id', r.target_id,
        'created_at', r.created_at,
        'source_revision', r.source_revision,
        'result', (case when r.result is null then null else r.result::jsonb end),
        'actor_is_owner', (r.actor = v_uid),
        -- FIELD FILTER: strip server-only reward loot + raw account UUID from both snapshots.
        'before', (r.before_snapshot - 'reward_bundle_json' - 'created_by'),
        'after',  (r.after_snapshot  - 'reward_bundle_json' - 'created_by'),
        'redactions', (
          select coalesce(jsonb_agg(k), '[]'::jsonb) from (
            select 'reward_bundle_json' as k
              where (r.before_snapshot ? 'reward_bundle_json') or (r.after_snapshot ? 'reward_bundle_json')
            union all
            select 'created_by'
              where (r.before_snapshot ? 'created_by') or (r.after_snapshot ? 'created_by')
            union all select 'actor'
          ) rk)
      )
      order by r.created_at desc, r.id desc
    ) filter (where r.rn <= v_limit), '[]'::jsonb),
    count(*)::int,
    (select jsonb_build_object('ts', created_at, 'id', id) from ranked where rn = v_limit)
  into v_items, v_fetched, v_next
  from ranked r;

  -- a further page exists only when we actually fetched more than the page size.
  if v_fetched <= v_limit then
    v_next := null;
  end if;

  return jsonb_build_object(
    'ok', true,
    'page_size', v_limit,
    'next_cursor', v_next,
    'items', v_items
  );
end $$;

comment on function public.world_editor_audit_list(jsonb) is
  'WORLD EDITOR V1.5 (0256): owner-only, field-filtered, keyset-paginated READ over '
  'world_editor_audit. authn → is_owner() authz → whitelisted filter parse (command_type/target_type/'
  'target_id/request_id/since/until/limit/cursor; unknown enum → invalid_request) → page over '
  '(created_at desc, id desc), limit clamped 1..100 → typed {ok,items,next_cursor,page_size}. STRIPS '
  'reward_bundle_json (server-only loot) + created_by from snapshots and returns actor_is_owner (never '
  'the raw actor UUID); a per-record redactions[] lists what was withheld. No table grant, no write, '
  'no second read path — world_editor_audit stays RLS deny-all. Execute to authenticated (guard '
  'IN-BODY); NEVER anon/public.';

-- ── 2. ACL — authenticated may CALL (guard is in-body); anon/public may not. No table grant widened.
revoke all on function public.world_editor_audit_list(jsonb) from public;
grant execute on function public.world_editor_audit_list(jsonb) to authenticated;  -- guard is in-body; NEVER anon

-- ── 3. self-assert (deploy-time; any raise aborts the txn — nothing half-applies) ─────────────────
do $auditassert$
begin
  -- (a) the 0243 spine this reader stands on exists.
  if to_regclass('public.app_owners') is null then
    raise exception 'WORLDEDIT-AUDIT-READ self-assert FAIL: app_owners missing';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'WORLDEDIT-AUDIT-READ self-assert FAIL: is_owner() missing';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'WORLDEDIT-AUDIT-READ self-assert FAIL: world_editor_audit missing';
  end if;

  -- (b) the reader exists, is SECURITY DEFINER, and its ACL is authenticated-only.
  if to_regprocedure('public.world_editor_audit_list(jsonb)') is null then
    raise exception 'WORLDEDIT-AUDIT-READ self-assert FAIL: world_editor_audit_list(jsonb) missing';
  end if;
  if not exists (select 1 from pg_proc
                 where oid = 'public.world_editor_audit_list(jsonb)'::regprocedure and prosecdef) then
    raise exception 'WORLDEDIT-AUDIT-READ self-assert FAIL: world_editor_audit_list is not SECURITY DEFINER';
  end if;
  if not has_function_privilege('authenticated', 'public.world_editor_audit_list(jsonb)', 'execute') then
    raise exception 'WORLDEDIT-AUDIT-READ self-assert FAIL: authenticated cannot execute the reader — the in-body guard would be unreachable';
  end if;
  if has_function_privilege('anon', 'public.world_editor_audit_list(jsonb)', 'execute') then
    raise exception 'WORLDEDIT-AUDIT-READ self-assert FAIL: anon CAN execute the reader — must be authenticated-only';
  end if;

  -- (c) the ledger stays RLS deny-all with NO client table grant — this reader is the ONLY read path.
  if not (select relrowsecurity from pg_class where oid = 'public.world_editor_audit'::regclass) then
    raise exception 'WORLDEDIT-AUDIT-READ self-assert FAIL: RLS disabled on world_editor_audit';
  end if;
  if has_table_privilege('authenticated', 'public.world_editor_audit', 'SELECT')
     or has_table_privilege('anon', 'public.world_editor_audit', 'SELECT') then
    raise exception 'WORLDEDIT-AUDIT-READ self-assert FAIL: a client role holds SELECT on world_editor_audit — the ledger must stay deny-all (the reader is the only read path)';
  end if;

  raise notice 'WORLDEDIT-AUDIT-READ self-assert ok: 0243 spine present; world_editor_audit_list SECURITY DEFINER + authenticated-only; world_editor_audit RLS deny-all with no client table grant (reader is the only read path)';
end $auditassert$;
