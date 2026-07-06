-- Byeharu — PHASE20-POLISH SLICE 2: the World Events SOLE-writer functions — the ONLY path that
-- writes `world_events` — plus the idempotency column. Service-role-only, idempotent, DARK. This
-- fulfills the 0139 SYSTEM_BOUNDARIES promise that `world_events`' sole writer is "its own future
-- service-role writer function". NO read surface, NO client path, NO cron, NO flag flipped true.
--
-- Ships BEFORE the read surface (producer before consumer), mirroring the established
-- command→read-surface order (0133 invest command before 0134 read surface; 0099 scan before 0100/0101).
--
-- SELF-APPROVED LOCKED DESIGN DECISIONS (owner-directed, STEP 2; recorded in docs/DEV_LOG.md +
-- docs/SYSTEM_BOUNDARIES.md this SAME step so later slices are grounded):
--   1. SERVICE-ROLE-ONLY WRITER. `world_events_publish` / `world_events_set_active` are SECURITY
--      DEFINER, client-revoked, granted ONLY to service_role (the 0021/0135 lockdown idiom). That
--      alone keeps World Events server-authoritative and structurally forbids any player-to-player
--      event injection — there is NO client publish path, so events can never be a PvP / player-
--      interaction vector (Online Presence & Visibility v1 stays deferred — ROADMAP :123–153).
--   2. IDEMPOTENT PUBLISH via a nullable-unique `dedup_key` (the idempotent-command law): a retried
--      publish carrying the same key returns the EXISTING event id and never inserts a duplicate. A
--      NULL key means an "ad-hoc, non-deduplicated event" — a PERMANENT optional idempotency key, NOT
--      a shim, so it needs no retirement condition.
--   3. RETIRE-NOT-DELETE. `world_events_set_active` flips `is_active` (+ bumps `updated_at`); it is the
--      retire/reactivate path and NEVER deletes a row (NO DESTRUCTIVE CLEANUP of world data — the 0139
--      `is_active` column intent).
--   4. DARK GATE FIRST (reject-before-any-read; the 0107/0097/0133:74–78 house law). Both writers check
--      `phase20_polish_enabled` FIRST and no-op while false (publish → returns NULL; set_active →
--      returns without writing) BEFORE any validation or write. This DELIVERS the 0139 flag-description
--      commitment ("any future World Events writer/processor must no-op" while false) — so the shipped
--      config text and this code agree (a law/design doc that contradicted the code would be a defect).
--      DEVIATION FROM THE STEP-2 BRIEF (reported): the brief did not enumerate this flag gate; it is
--      added strictly for consistency with the 0139 promise + the pervasive reject-before-any-read
--      idiom, is more conservative (darker), and does not change the enabled-path publish/dedup/
--      set_active behavior the brief specified.
--
-- IDIOM SOURCES (reused, never reinvented):
--   · SECURITY DEFINER writer with input validation + `set search_path = public`: location_investment_invest
--     (0133). Exception-style raises on invalid input (the leaf-writer idiom — captains_mint_instance
--     0118 / inventory writers 0039) because this returns a bare uuid, not a jsonb envelope, and is an
--     internal service-role leaf.
--   · per-function ACL lockdown (`revoke … from public, anon, authenticated; grant … to service_role`):
--     0021 (RPC lockdown) + 0135:183–184 (worldstate_tick).
--   · validation MIRRORS the shipped 0139 CHECK constraints exactly (event_type/scope/severity
--     membership + the scope↔target invariant), so the writer never attempts an insert the table would
--     reject — defense-in-depth, one source of truth for the rules.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): §1 `world_events` sole writer becomes
-- the concrete `world_events_publish` / `world_events_set_active` (service-role only); §2 records the
-- two functions. World Events stays a downward LEAF: the ONLY cross-system access is a DOWNWARD read of
-- the static Map (`zones`/`locations`) to validate a supplied FK target — the already-noted
-- relationship, no NEW call-edge, acyclic. It writes ONLY `world_events`. Leaves `0001–0139` unedited;
-- forward-only.

-- ── (a) idempotency storage: the nullable-unique dedup_key ──────────────────────────────────────────
-- NULL = an ad-hoc, non-deduplicated event (a PERMANENT optional key, not a shim — no retirement
-- condition). The partial unique index enforces idempotency ONLY over non-null keys, so unlimited
-- ad-hoc events coexist while a keyed publish is exactly-once.
alter table public.world_events add column dedup_key text;

create unique index world_events_dedup_key_uidx
  on public.world_events (dedup_key) where dedup_key is not null;

comment on column public.world_events.dedup_key is
  'PHASE20-POLISH (0140): optional idempotency key for world_events_publish. NON-NULL = exactly-once '
  '(partial unique index) — a retried publish with the same key returns the existing event id, never a '
  'duplicate. NULL = ad-hoc, non-deduplicated event (a permanent optional key, not a shim).';

-- ── (b) world_events_publish — the SOLE insert path (service-role; idempotent) ──────────────────────
create or replace function public.world_events_publish(
  p_event_type  text,
  p_scope       text,
  p_zone_id     uuid,
  p_location_id uuid,
  p_title       text,
  p_body        text,
  p_severity    text        default 'info',
  p_starts_at   timestamptz default now(),
  p_ends_at     timestamptz default null,
  p_dedup_key   text        default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  -- 1) DARK GATE FIRST (0133:74–78 law; delivers the 0139 "writer must no-op while false" promise):
  --    while phase20_polish_enabled is false, no-op (return NULL) BEFORE any validation/read/write.
  if not public.cfg_bool('phase20_polish_enabled') then
    return null;
  end if;

  -- 2) input validation — mirrors the 0139 CHECK constraints exactly (defense-in-depth; the DB CHECK
  --    is the backstop). Exception-style raises: this is an internal service-role leaf returning a uuid.
  if p_event_type is null or p_event_type not in ('notice', 'world_state', 'seasonal') then
    raise exception 'world_events_publish: invalid event_type %', p_event_type;
  end if;
  if p_scope is null or p_scope not in ('global', 'zone', 'location') then
    raise exception 'world_events_publish: invalid scope %', p_scope;
  end if;
  if p_severity is null or p_severity not in ('info', 'warning', 'critical') then
    raise exception 'world_events_publish: invalid severity %', p_severity;
  end if;
  if p_title is null or length(btrim(p_title)) = 0 then
    raise exception 'world_events_publish: title is required';
  end if;

  -- scope↔target invariant, byte-for-byte the 0139 CHECK: global ⇒ both null; zone ⇒ zone_id only;
  -- location ⇒ location_id only.
  if p_scope = 'global' and (p_zone_id is not null or p_location_id is not null) then
    raise exception 'world_events_publish: global scope requires null zone_id and location_id';
  elsif p_scope = 'zone' and (p_zone_id is null or p_location_id is not null) then
    raise exception 'world_events_publish: zone scope requires a zone_id and null location_id';
  elsif p_scope = 'location' and (p_location_id is null or p_zone_id is not null) then
    raise exception 'world_events_publish: location scope requires a location_id and null zone_id';
  end if;

  -- 3) referenced Map row must exist — a DOWNWARD read of the static Map (the already-noted
  --    relationship; no new call-edge). Guards against a dangling FK target before the insert.
  if p_zone_id is not null
     and not exists (select 1 from public.zones where id = p_zone_id) then
    raise exception 'world_events_publish: zone_id % not found', p_zone_id;
  end if;
  if p_location_id is not null
     and not exists (select 1 from public.locations where id = p_location_id) then
    raise exception 'world_events_publish: location_id % not found', p_location_id;
  end if;

  -- 4) IDEMPOTENT publish (dedup_key non-null): insert, or on the partial-unique conflict return the
  --    EXISTING event id without a duplicate (the on-conflict-do-nothing + fallback-select idiom).
  if p_dedup_key is not null then
    insert into public.world_events
      (event_type, scope, zone_id, location_id, title, body, severity, starts_at, ends_at, dedup_key)
    values
      (p_event_type, p_scope, p_zone_id, p_location_id, p_title, p_body, p_severity,
       coalesce(p_starts_at, now()), p_ends_at, p_dedup_key)
    on conflict (dedup_key) where dedup_key is not null do nothing
    returning id into v_id;

    if v_id is null then
      -- conflict: a row with this key already exists → return its id (idempotent replay, no dup).
      select id into v_id from public.world_events where dedup_key = p_dedup_key;
    end if;
    return v_id;
  end if;

  -- 5) ad-hoc publish (no dedup_key): always a fresh event.
  insert into public.world_events
    (event_type, scope, zone_id, location_id, title, body, severity, starts_at, ends_at)
  values
    (p_event_type, p_scope, p_zone_id, p_location_id, p_title, p_body, p_severity,
     coalesce(p_starts_at, now()), p_ends_at)
  returning id into v_id;
  return v_id;
end;
$$;

-- ── (c) world_events_set_active — the retire/reactivate path (service-role; NEVER deletes) ──────────
create or replace function public.world_events_set_active(
  p_event_id  uuid,
  p_is_active boolean
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- DARK GATE FIRST (same law as publish): no-op while phase20_polish_enabled is false.
  if not public.cfg_bool('phase20_polish_enabled') then
    return;
  end if;

  if p_event_id is null or p_is_active is null then
    raise exception 'world_events_set_active: event_id and is_active are required';
  end if;

  -- retire (false) / reactivate (true) — a status flip, NEVER a delete (no destructive cleanup).
  update public.world_events
     set is_active  = p_is_active,
         updated_at = now()
   where id = p_event_id;
end;
$$;

-- ── (d) ACL lockdown (anti-cheat; the 0021 / 0135:183–184 idiom) — service-role ONLY, never clients ─
-- The 0064-era default-privileges revoke already denies new functions to PUBLIC; these re-assert
-- explicitly. There is NO client publish/retire path — World Events is server-authoritative.
revoke execute on function public.world_events_publish(text, text, uuid, uuid, text, text, text, timestamptz, timestamptz, text) from public, anon, authenticated;
grant  execute on function public.world_events_publish(text, text, uuid, uuid, text, text, text, timestamptz, timestamptz, text) to service_role;

revoke execute on function public.world_events_set_active(uuid, boolean) from public, anon, authenticated;
grant  execute on function public.world_events_set_active(uuid, boolean) to service_role;

-- No flag is read to gate creation and none is flipped; every Phase-20 capability remains
-- server-rejected (the phase20_polish_enabled gate, still false). Forward-only; edits no 0001–0139.
