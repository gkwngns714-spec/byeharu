-- Byeharu — WORLD EDITOR SLICE 1.75: world_editor_entity_detail — the owner-only INACTIVE-DETAIL / REACTIVATION
-- reader that lets the editor REACTIVATE a ZONE or LOCATION selected from the 0269 lifecycle catalog WITHOUT
-- fabricating the optimistic-concurrency `expected` fields those two reactivation commands demand.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE GAP THIS CLOSES: the 0269 catalog (world_editor_entity_catalog) lets the editor LIST / SEARCH / JUMP-TO
-- inactive entities, but its normalized row carries only name + point/geometry + lifecycle_status. Two of the
-- four reactivation paths need MORE than that as their `expected` snapshot, and the catalog does NOT carry it:
--   • ZONE     → zone_set_active (0268:202-215)   expected = {name, source, location_id} — the catalog has
--                name + geometry but NEITHER source NOR location_id.
--   • LOCATION → location_update (0249:200-251) status→'active'  expected = the 11 draft fields
--                {name, location_type, activity_type, x, y, reward_tier, base_difficulty, min_power_required,
--                 is_public, territory_radius, status} — the catalog has name + point only.
-- This migration adds ONE narrow owner-only READER that, given {domain∈{zone,location}, entity_id} for an
-- INACTIVE entity, returns an OPAQUE `reactivation_expected` object matching that command's `expected` EXACTLY
-- (plus display fields domain/name/lifecycle_status). The client passes reactivation_expected STRAIGHT THROUGH
-- as `expected` — NO client-side reconstruction; for LOCATION it also reuses it as the update `fields` with
-- status flipped to 'active'.
--
-- WHY ONLY ZONE + LOCATION (mining/exploration are catalog-sufficient): mining_field_set_active /
-- exploration_site_set_active (0250:178-195 / 336-357) compare expected = {name, space_x, space_y,
-- reward_bundle_json}, but reward_bundle_json is compared ONLY when `expected` carries a NON-NULL value ("the
-- live bundle is never client-readable, so a fork's null means UNOBSERVABLE"). The catalog already carries the
-- name and the point (= the native space_x/space_y), so the editor reactivates a mining field / exploration
-- site DIRECTLY from the catalog row with reward_bundle_json:null — no extra reader needed, and the server-only
-- bundle is never exposed. This reader therefore REJECTS domain 'mining'/'exploration' as unsupported_domain,
-- and any other domain as invalid_domain — scope cannot expand accidentally.
--
-- INACTIVE-ONLY: this is a REACTIVATION detail reader. An entity that is currently ACTIVE is rejected with a
-- typed validation_failed {already_active} — there is nothing to reactivate. (Deactivation is the job of
-- zone_unpublish / *_set_active(false) / location_update, never this reader.)
--
-- LOCATION COORDINATES: x/y in reactivation_expected are read from locations.x/y — the EXACT column
-- location_update's `expected` compare targets (v_expected->'x' is distinct from to_jsonb(v_live.x), v_live from
-- public.locations — 0249:215-223 / 0264:436-444). Under the 0264 write-authority the active space_anchor is
-- byte-identical to locations.x/y, so the two are numerically equal; but the value location_update ACTUALLY
-- compares against is locations.x/y, so returning locations.x/y is the exact-parity guarantee that the
-- reactivate is ACCEPTED (no stale on x/y). The anchor is NOT substituted into the payload.
--
-- ZONE geometry is already in the catalog and zone_set_active does NOT compare it (0268:197-201 — "geometry is
-- intentionally NOT compared"), so it is NOT re-returned here.
--
-- NO SERVER-ONLY / AUDIT DERIVATION: nothing is read from world_editor_audit, and no field is returned unless
-- the target reactivation command actually compares it (reward_bundle_json and every internal field excluded).
--
-- FAIL-CLOSED (raise / typed, never silently omit or fall back):
--   • an unknown domain (invalid_domain) or a mining/exploration domain (unsupported_domain) — typed;
--   • a missing entity (not_found) — typed;
--   • an ACTIVE entity (already_active) — typed;
--   • a zone whose boundary cannot normalize to a closed vertex ring (>= 4 points) — raise;
--   • a location without EXACTLY ONE active location-kind anchor (missing/ambiguous anchor history — the
--     0263/0264 coordinate-authority invariant) — raise.
--
-- WHAT THIS IS NOT: it does NOT modify, replace, or repoint ANY gameplay reader, the 0269 catalog, or ANY
-- *_set_active / *_update / location_update reactivation command. It writes NOTHING (no table write privilege
-- added anywhere); it is READ-ONLY (SECURITY DEFINER only so it can read the RLS-private domain tables the same
-- way get_world_map / the catalog already do).
--
-- DEPLOY POSTURE: UNDEPLOYED — deploy is a human gate. Fail-closed by design: even deployed, the capability is
-- inert until an owner is seeded into app_owners (is_owner() is false for everyone on an unseeded DB). No client
-- grant is widened; execute is authenticated-only (the guard is in-body) and explicitly revoked from PUBLIC/anon.
--
-- NO-SPAGHETTI: ONE owner guard (public.is_owner(), the 0243 spine — consulted IN-BODY), the `expected` field
-- sets copied field-for-field from each reactivation command's own compare — this reader derives NO new
-- authority and introduces NO new coordinate/geometry/lifecycle source. No table write, no audit row, no second
-- owner check, no reward/audit/internal field leaked, no mining/exploration duplication of the catalog.
--
-- TYPED ENVELOPE (the 0243/0269 WE vocabulary):
--   success : {ok:true, domain, entity_id, name, lifecycle_status:'inactive', reactivation_expected:{...}}
--             where reactivation_expected is EXACTLY the field set the domain's reactivation command compares.
--   failure : {ok:false, error:<code> [, details:[{code,field,message}...]]}  where code ∈
--             { 'not_authenticated'  -- no JWT subject (anonymous)
--             , 'not_authorized'     -- authenticated but not in app_owners
--             , 'validation_failed'  -- unsupported_domain (mining/exploration → reactivate from the catalog),
--                                       invalid_domain (unknown), invalid_entity_id (missing/not a uuid),
--                                       already_active (the target is currently active — nothing to reactivate)
--             , 'not_found'          -- no entity of that domain with that id (details: source_missing)
--             }
-- INPUT: p_payload = { domain: 'zone'|'location', entity_id: <uuid> }
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. dependency gate — abort loudly if a surface this reader reads / pairs with / promises to leave intact
--       is missing.
do $detdep$
begin
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'WE-ENTITY-DETAIL: public.is_owner() (0243) is missing — THE ONE owner guard must exist first';
  end if;
  if to_regclass('public.locations') is null or to_regclass('public.danger_zones') is null
     or to_regclass('public.space_anchors') is null then
    raise exception 'WE-ENTITY-DETAIL: a source domain table (locations/danger_zones/space_anchors) is missing';
  end if;
  -- the PostGIS ring primitives the zone geometry fail-closed guard composes (public schema, search_path='' safe).
  if to_regprocedure('public.st_exteriorring(public.geometry)') is null
     or to_regprocedure('public.st_dumppoints(public.geometry)') is null then
    raise exception 'WE-ENTITY-DETAIL: a PostGIS primitive (st_exteriorring/st_dumppoints) is missing — the zone geometry fail-closed guard needs them';
  end if;
  -- the 2 REACTIVATION commands this reader feeds must exist (the detail contract mirrors their `expected`).
  if to_regprocedure('public.zone_set_active(text, jsonb)') is null then
    raise exception 'WE-ENTITY-DETAIL: public.zone_set_active(text,jsonb) (0268) is missing — the zone reactivation command this reader feeds must exist';
  end if;
  if to_regprocedure('public.location_update(text, jsonb)') is null then
    raise exception 'WE-ENTITY-DETAIL: public.location_update(text,jsonb) (0249/0264) is missing — the location reactivation command this reader feeds must exist';
  end if;
  -- the 0269 catalog this reader complements (never replaces) must exist.
  if to_regprocedure('public.world_editor_entity_catalog(jsonb)') is null then
    raise exception 'WE-ENTITY-DETAIL: public.world_editor_entity_catalog(jsonb) (0269) is missing — the catalog this reader complements must exist';
  end if;
  -- the gameplay readers this slice PROMISES to leave intact must exist (never be the thing that removed one).
  if to_regprocedure('public.get_world_map()') is null
     or to_regprocedure('public.get_active_mining_fields()') is null
     or to_regprocedure('public.get_danger_zones()') is null
     or to_regprocedure('public.get_my_exploration_discoveries()') is null then
    raise exception 'WE-ENTITY-DETAIL: a gameplay reader (get_world_map/get_active_mining_fields/get_danger_zones/get_my_exploration_discoveries) is missing — this slice must NOT be what removed it';
  end if;
end $detdep$;

-- ── 1. world_editor_entity_detail — the owner-only reactivation-snapshot reader (READ-ONLY, zone+location) ──
create or replace function public.world_editor_entity_detail(p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_domain   text;
  v_id_raw   text;
  v_id       uuid;
  v_expected jsonb;
  v_name     text;
  v_anchor_n int;
  v_ring_n   int;
  v_zone     record;
  v_loc      record;
begin
  -- (1) authn — reject the anonymous caller with a typed code (no read at all). [0243/0269 idiom]
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'not_authenticated');
  end if;

  -- (2) authz — THE ONE guard, in-body on auth.uid(). Non-owner authenticated caller is rejected. [0243]
  if not public.is_owner() then
    return jsonb_build_object('ok', false, 'error', 'not_authorized');
  end if;

  -- (3) input validation — domain ∈ {zone,location}; entity_id present + a uuid. mining/exploration are
  --     REJECTED as unsupported_domain (reactivate them directly from the 0269 catalog); any other domain is
  --     invalid_domain; a missing/malformed id is invalid_entity_id — all typed validation_failed, no read.
  v_domain := lower(btrim(coalesce(p_payload->>'domain', '')));
  if v_domain in ('mining', 'exploration') then
    return jsonb_build_object('ok', false, 'error', 'validation_failed',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'unsupported_domain', 'field', 'domain',
               'message', 'mining/exploration reactivate directly from the catalog row (name + point = space_x/space_y, reward_bundle_json:null); the detail reader is only for zone and location.')));
  end if;
  if v_domain not in ('zone', 'location') then
    return jsonb_build_object('ok', false, 'error', 'validation_failed',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'invalid_domain', 'field', 'domain',
               'message', 'domain must be one of zone | location.')));
  end if;
  v_id_raw := btrim(coalesce(p_payload->>'entity_id', ''));
  if v_id_raw = '' then
    return jsonb_build_object('ok', false, 'error', 'validation_failed',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'invalid_entity_id', 'field', 'entity_id',
               'message', 'entity_id is required.')));
  end if;
  begin
    v_id := v_id_raw::uuid;
  exception when invalid_text_representation then
    return jsonb_build_object('ok', false, 'error', 'validation_failed',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'invalid_entity_id', 'field', 'entity_id',
               'message', 'entity_id ''' || v_id_raw || ''' is not a valid uuid.')));
  end;

  -- (4) per-domain: locate → reject-if-active (already_active) → fail-closed integrity guard → build the OPAQUE
  --     reactivation_expected, EXACTLY the field set the reactivation command's `expected` compares.
  if v_domain = 'zone' then
    -- ZONE → zone_set_active (0268): expected = {name, source, location_id} (geometry NOT compared). Address
    -- by uuid PK. lifecycle from danger_zones.status (0233 CHECK: active|inactive).
    select name, source, location_id, status, boundary
      into v_zone
      from public.danger_zones
     where id = v_id;
    if not found then
      return jsonb_build_object('ok', false, 'error', 'not_found',
               'details', jsonb_build_array(jsonb_build_object(
                 'code', 'source_missing', 'field', 'entity_id',
                 'message', 'No zone with id ''' || v_id_raw || ''' exists.')));
    end if;
    if v_zone.status = 'active' then
      return jsonb_build_object('ok', false, 'error', 'validation_failed',
               'details', jsonb_build_array(jsonb_build_object(
                 'code', 'already_active', 'field', 'entity_id',
                 'message', 'This zone is currently active — the reactivation detail reader serves inactive entities only.')));
    end if;
    -- FAIL-CLOSED: the zone boundary must normalize to a closed vertex ring (>= 4 points), never a broken geometry.
    v_ring_n := coalesce((select count(*) from public.st_dumppoints(public.st_exteriorring(v_zone.boundary))), 0);
    if v_ring_n < 4 then
      raise exception 'world_editor_entity_detail: zone % geometry cannot normalize to a closed ring (% vertices) — refusing to serve a malformed entity', v_id_raw, v_ring_n;
    end if;
    v_name     := v_zone.name;
    v_expected := jsonb_build_object(
                    'name', v_zone.name,
                    'source', v_zone.source,
                    'location_id', v_zone.location_id);

  else
    -- LOCATION → location_update (0249/0264) status→'active': expected = the 11 draft fields the command
    -- compares value-by-value. Address by uuid PK. x/y come from locations.x/y — the EXACT column
    -- location_update compares `expected` against (v_live.x/y from public.locations); this is the exact-parity
    -- guarantee that the reactivate is accepted. lifecycle from locations.status (0002 enum:
    -- active|locked|hidden → active|inactive).
    select name, location_type, activity_type, x, y, reward_tier, base_difficulty,
           min_power_required, is_public, territory_radius, status
      into v_loc
      from public.locations
     where id = v_id;
    if not found then
      return jsonb_build_object('ok', false, 'error', 'not_found',
               'details', jsonb_build_array(jsonb_build_object(
                 'code', 'source_missing', 'field', 'entity_id',
                 'message', 'No location with id ''' || v_id_raw || ''' exists.')));
    end if;
    if v_loc.status = 'active' then
      return jsonb_build_object('ok', false, 'error', 'validation_failed',
               'details', jsonb_build_array(jsonb_build_object(
                 'code', 'already_active', 'field', 'entity_id',
                 'message', 'This location is currently active — the reactivation detail reader serves inactive entities only.')));
    end if;
    -- FAIL-CLOSED: the location must have EXACTLY ONE active location-kind anchor (the 0263/0264 coordinate-
    -- authority invariant) — a missing/ambiguous anchor history means the coordinate authority is broken; refuse.
    select count(*) into v_anchor_n
      from public.space_anchors a
     where a.location_id = v_id and a.kind = 'location' and a.status = 'active';
    if v_anchor_n <> 1 then
      raise exception 'world_editor_entity_detail: location % has % active anchor(s) (expected exactly 1) — missing/ambiguous anchor history; refusing to serve', v_id_raw, v_anchor_n;
    end if;
    v_name     := v_loc.name;
    v_expected := jsonb_build_object(
                    'name', v_loc.name,
                    'location_type', v_loc.location_type,
                    'activity_type', v_loc.activity_type,
                    'x', v_loc.x,
                    'y', v_loc.y,
                    'reward_tier', v_loc.reward_tier,
                    'base_difficulty', v_loc.base_difficulty,
                    'min_power_required', v_loc.min_power_required,
                    'is_public', v_loc.is_public,
                    'territory_radius', v_loc.territory_radius,
                    'status', v_loc.status);
  end if;

  return jsonb_build_object(
           'ok', true,
           'domain', v_domain,
           'entity_id', v_id::text,
           'name', v_name,
           'lifecycle_status', 'inactive',
           'reactivation_expected', v_expected);
end $$;

comment on function public.world_editor_entity_detail(jsonb) is
  'WORLD EDITOR SLICE 1.75 (0270): the owner-only INACTIVE-DETAIL / REACTIVATION reader — returns an OPAQUE '
  'reactivation_expected snapshot a ZONE or LOCATION''s reactivation command needs as its optimistic-concurrency '
  '`expected`, enabling reactivate-from-catalog-selection (0269) WITHOUT fabricating fields or reading the audit '
  'ledger. Given {domain in {zone,location}, entity_id} for an INACTIVE entity it returns EXACTLY the field set '
  'that command compares (the client passes it straight through): zone→zone_set_active {name,source,location_id} '
  '(the catalog lacks source+location_id); location→location_update the 11 draft fields with x/y read from '
  'locations.x/y (the exact column location_update''s `expected` compares against; == the active anchor under '
  '0264). mining/exploration are REJECTED (unsupported_domain): their set_active skips reward_bundle_json when '
  'null, so they reactivate directly from the catalog row. An ACTIVE entity is rejected (already_active) — this '
  'serves inactive entities only. Zone geometry is NOT re-returned (already in the catalog; zone_set_active does '
  'not compare it). READ-ONLY (no table write, no audit row, no audit derivation). Fail-closed: unknown/'
  'unsupported domain, missing entity, an active entity, a zone whose geometry cannot normalize, a location '
  'without exactly one active anchor. Does NOT modify the 0269 catalog, any gameplay reader, or any '
  '*_set_active/*_update reactivation command. Execute is authenticated-only (guard in-body); NEVER anon/public.';

-- ── 2. ACL — authenticated may CALL (the guard is in-body); PUBLIC + anon may NOT. No table grant widened.
revoke all on function public.world_editor_entity_detail(jsonb) from public;
revoke execute on function public.world_editor_entity_detail(jsonb) from anon;
grant execute on function public.world_editor_entity_detail(jsonb) to authenticated;  -- guard is in-body; NEVER anon

-- ── 3. self-assert (deploy-time; any raise aborts the txn — nothing half-applies) ─────────────────
do $detassert$
declare
  v_def text;
begin
  -- (a) the 0243 owner spine this read stands on exists.
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'WE-ENTITY-DETAIL self-assert FAIL: is_owner() missing';
  end if;

  -- (b) the reader exists, is SECURITY DEFINER, and pins search_path (a hijack would otherwise be possible).
  if to_regprocedure('public.world_editor_entity_detail(jsonb)') is null then
    raise exception 'WE-ENTITY-DETAIL self-assert FAIL: world_editor_entity_detail(jsonb) missing';
  end if;
  if not exists (select 1 from pg_proc
                 where oid = 'public.world_editor_entity_detail(jsonb)'::regprocedure and prosecdef) then
    raise exception 'WE-ENTITY-DETAIL self-assert FAIL: world_editor_entity_detail is not SECURITY DEFINER';
  end if;
  if not exists (select 1 from pg_proc p
                 where p.oid = 'public.world_editor_entity_detail(jsonb)'::regprocedure
                   and exists (select 1 from unnest(p.proconfig) cfg where cfg like 'search_path=%')) then
    raise exception 'WE-ENTITY-DETAIL self-assert FAIL: world_editor_entity_detail does not pin search_path';
  end if;

  -- (c) ACL: authenticated MAY execute (in-body guard); anon/public MAY NOT.
  if not has_function_privilege('authenticated', 'public.world_editor_entity_detail(jsonb)', 'execute') then
    raise exception 'WE-ENTITY-DETAIL self-assert FAIL: authenticated cannot execute the reader — the in-body guard would be unreachable';
  end if;
  if has_function_privilege('anon', 'public.world_editor_entity_detail(jsonb)', 'execute') then
    raise exception 'WE-ENTITY-DETAIL self-assert FAIL: anon CAN execute the reader — must be authenticated-only';
  end if;

  -- (d) READ-ONLY: the body performs NO table write. A cheap, robust source-text guard — the reader must
  --     never mutate world state (and must never write an audit row).
  v_def := lower(pg_get_functiondef('public.world_editor_entity_detail(jsonb)'::regprocedure));
  if position('insert into' in v_def) > 0
     or position('update public.' in v_def) > 0
     or position('delete from' in v_def) > 0 then
    raise exception 'WE-ENTITY-DETAIL self-assert FAIL: the reader body contains a table write — it must be read-only';
  end if;
  -- and it never derives from the audit ledger.
  if position('world_editor_audit' in v_def) > 0 then
    raise exception 'WE-ENTITY-DETAIL self-assert FAIL: the reader references world_editor_audit — it must derive nothing from the audit ledger';
  end if;

  -- (e) the location coordinate-authority integrity guard reads space_anchors (the 0263/0264 authority).
  if position('space_anchors' in v_def) = 0 then
    raise exception 'WE-ENTITY-DETAIL self-assert FAIL: the reader does not read space_anchors — the location anchor fail-closed guard is missing';
  end if;

  -- (f) the 0269 catalog + the gameplay readers are UNTOUCHED: all exist and keep their client execute grants
  --     (this slice must not have modified or de-granted any of them).
  if to_regprocedure('public.world_editor_entity_catalog(jsonb)') is null then
    raise exception 'WE-ENTITY-DETAIL self-assert FAIL: the 0269 catalog vanished — this slice must not touch it';
  end if;
  if not has_function_privilege('authenticated', 'public.world_editor_entity_catalog(jsonb)', 'execute')
     or has_function_privilege('anon', 'public.world_editor_entity_catalog(jsonb)', 'execute') then
    raise exception 'WE-ENTITY-DETAIL self-assert FAIL: the 0269 catalog ACL was disturbed (must stay authenticated-only)';
  end if;
  if to_regprocedure('public.get_world_map()') is null
     or to_regprocedure('public.get_active_mining_fields()') is null
     or to_regprocedure('public.get_danger_zones()') is null
     or to_regprocedure('public.get_my_exploration_discoveries()') is null then
    raise exception 'WE-ENTITY-DETAIL self-assert FAIL: a gameplay reader vanished — this slice must not touch the gameplay readers';
  end if;
  if not has_function_privilege('anon', 'public.get_world_map()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_world_map()', 'execute')
     or not has_function_privilege('anon', 'public.get_danger_zones()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_danger_zones()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_active_mining_fields()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_my_exploration_discoveries()', 'execute') then
    raise exception 'WE-ENTITY-DETAIL self-assert FAIL: a gameplay reader lost a client execute grant — this slice must leave the read surface unchanged';
  end if;

  -- (g) the 2 REACTIVATION commands this reader feeds are intact: exist, authenticated-only, anon-denied
  --     (this slice must not have touched their ACL).
  if not has_function_privilege('authenticated', 'public.zone_set_active(text,jsonb)', 'execute')
     or has_function_privilege('anon', 'public.zone_set_active(text,jsonb)', 'execute')
     or not has_function_privilege('authenticated', 'public.location_update(text,jsonb)', 'execute')
     or has_function_privilege('anon', 'public.location_update(text,jsonb)', 'execute') then
    raise exception 'WE-ENTITY-DETAIL self-assert FAIL: a reactivation command ACL was disturbed (must stay authenticated-only) — this slice must not touch them';
  end if;

  -- (h) no client-role WRITE grant was added to a source domain table by this slice (the reader is a pure
  --     read; it must widen nothing). Mirrors the 0249/0268/0269 write-lockdown posture (SELECT is unrelated).
  if has_table_privilege('authenticated', 'public.locations', 'INSERT')
     or has_table_privilege('authenticated', 'public.locations', 'UPDATE')
     or has_table_privilege('authenticated', 'public.locations', 'DELETE')
     or has_table_privilege('authenticated', 'public.danger_zones', 'INSERT')
     or has_table_privilege('authenticated', 'public.danger_zones', 'UPDATE')
     or has_table_privilege('authenticated', 'public.danger_zones', 'DELETE')
     or has_table_privilege('authenticated', 'public.space_anchors', 'INSERT')
     or has_table_privilege('authenticated', 'public.space_anchors', 'UPDATE')
     or has_table_privilege('authenticated', 'public.space_anchors', 'DELETE')
     or has_table_privilege('anon', 'public.locations', 'INSERT')
     or has_table_privilege('anon', 'public.locations', 'UPDATE')
     or has_table_privilege('anon', 'public.locations', 'DELETE')
     or has_table_privilege('anon', 'public.danger_zones', 'INSERT')
     or has_table_privilege('anon', 'public.danger_zones', 'UPDATE')
     or has_table_privilege('anon', 'public.danger_zones', 'DELETE') then
    raise exception 'WE-ENTITY-DETAIL self-assert FAIL: a client role holds a WRITE grant on a source domain table — this slice must add no table write';
  end if;

  raise notice 'WE-ENTITY-DETAIL self-assert ok: world_editor_entity_detail SECURITY DEFINER + search_path pinned + authenticated-only (anon revoked); read-only (no table write/audit, no audit derivation); zone+location only (mining/exploration catalog-sufficient); inactive-only (active rejected); fail-closed on malformed zone geometry + missing/ambiguous location anchor; 0269 catalog + all 4 gameplay readers intact with client grants; zone_set_active + location_update intact (authenticated-only); no source-table write grant added';
end $detassert$;
