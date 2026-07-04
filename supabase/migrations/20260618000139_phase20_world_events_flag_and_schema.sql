-- Byeharu — PHASE20-POLISH SLICE 1: the Phase-20 dark master flag + the World Events schema
-- (config seed + table + RLS + indexes + comments ONLY; NO writer function, NO read RPC, NO
-- processor, NO cron, NO frontend; the feature stays fully DARK behind `phase20_polish_enabled=false`
-- from THIS migration — NOTHING can write or read this table yet).
--
-- Phase 20 = ROADMAP :95 "Polish / expansion (map UI, portraits, icons, events; guilds/PvP much
-- later, if ever)". World Events is the one genuinely SERVER-AUTHORITATIVE piece of that polish:
-- timed, presentational world happenings (a "pirate surge in Zone X" notice, a seasonal banner, a
-- world-state highlight) that the map / dashboard will READ (via a later flag-gated read RPC) to
-- satisfy the "events" polish goal.
--
-- SELF-APPROVED LOCKED DESIGN DECISION (owner-directed, STEP 1; recorded in docs/DEV_LOG.md +
-- docs/SYSTEM_BOUNDARIES.md this SAME step so later slices are grounded): **World Events is a NEW
-- server-authoritative downward-LEAF system**, the sole writer of its own `world_events` table. It is
-- a PURE leaf, honoring the one-directional pipeline law (ROADMAP standing law 3):
--   · It NEVER writes `zone_state` / `location_state` (World State's tables), `fleets`, `combat_*`,
--     `reward_grants`, or any other system's table — it is NOT a second writer to anything, and it
--     grants no rewards. It only READS the static Map (`zones`/`locations`) for FK integrity.
--   · Nothing depends on writing it; nothing writes it but its OWN future service-role writer.
--   · It exposes NO client read/write surface this slice — fail-closed, server-only (the
--     `mining_fields` / `market_offers` hidden posture): RLS enabled with NO client policy and NO
--     grant. A later slice adds ONE flag-gated read RPC (the ONLY client path), and later still a
--     service-role writer to publish/expire events. Both stay DARK behind `phase20_polish_enabled`.
--
-- Mirrors the prior schema-only slices (0103 mining_fields / 0128 ranking_standings) for the
-- table/RLS/index/comment idiom, deviating where the World Events design requires it: a
-- polymorphic scope↔target shape (global / zone / location) with a CHECK enforcing the invariant,
-- and the server-only (no client grant) posture of `mining_fields` (this table's rows are
-- server-published, not player-owned, so there is no owner-read policy either).
--
-- FK targets are the Map system's static tables: public.zones (id) and public.locations (id) from
-- 0002 (both uuid PKs). `on delete cascade` keeps events from dangling if a zone/location is removed.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced in the SAME step): §1 matrix gains `world_events`
-- under a NEW **World Events** system (sole writer = its OWN future service-role writer; server-only,
-- no client surface; DARK behind `phase20_polish_enabled`); §2 gains the World-Events contract row
-- (owns `world_events`; a downward leaf — reads only static Map for FK integrity; writes nothing
-- else; grants nothing). No new cross-system CALL edge exists yet (no function is created here).
-- No flag flipped; `0001–0138` unedited; forward-only.

-- ── (a) config: the Phase-20 dark master flag (NEW) ────────────────────────────────────────────────
insert into public.game_config (key, value, description) values
  ('phase20_polish_enabled', 'false',
   'PHASE20-POLISH: server-authoritative dark master gate for Phase 20 (Polish/expansion — map UI, '
   'portraits, icons, world events). OFF until the human owner activates. While false, every Phase-20 '
   'read surface (the future World Events read RPC, portrait/icon lookups) must gate on this FIRST and '
   'return nothing, and any future World Events writer/processor must no-op. Every Phase-20 capability '
   'ships DARK and server-rejected behind this flag; it is NOT flipped true by this migration.')
on conflict (key) do nothing;

-- ── (b) world_events — presentational timed world happenings (World Events; server-only) ────────────
create table public.world_events (
  id           uuid primary key default gen_random_uuid(),
  -- the KIND of happening this row represents (small explicit allowed set; additive forward-only
  -- CHECK change to extend). 'notice' = a free-form informational banner; 'world_state' = a highlight
  -- tied to world-state dynamics (e.g. a pirate surge); 'seasonal' = a time-boxed seasonal banner.
  event_type   text not null
                 check (event_type in ('notice', 'world_state', 'seasonal')),
  -- the polymorphic REACH of this event: whole world, one zone, or one location.
  scope        text not null
                 check (scope in ('global', 'zone', 'location')),
  -- targets (Map system, read-only FK for integrity/display join). NULL unless the scope names them.
  zone_id      uuid references public.zones (id) on delete cascade,
  location_id  uuid references public.locations (id) on delete cascade,
  -- scope↔target invariant: global ⇒ both null; zone ⇒ zone_id set & location_id null;
  -- location ⇒ location_id set & zone_id null. Fail-closed: no other combination is storable.
  check (
    (scope = 'global'   and zone_id is null     and location_id is null) or
    (scope = 'zone'     and zone_id is not null and location_id is null) or
    (scope = 'location' and location_id is not null and zone_id is null)
  ),
  title        text not null,
  body         text,
  severity     text not null default 'info'
                 check (severity in ('info', 'warning', 'critical')),
  -- lets an event be retired without deleting the row (no destructive cleanup of world data; future
  -- readers must treat is_active=false OR an elapsed ends_at as not-currently-showing).
  is_active    boolean not null default true,
  starts_at    timestamptz not null default now(),
  ends_at      timestamptz,                       -- NULL = open-ended
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- active-window read index: the future read RPC surfaces currently-showing events, newest first.
create index world_events_active_idx
  on public.world_events (is_active, starts_at desc);
-- scoped lookups: events attached to a given zone / location (partial — most rows are global/null).
create index world_events_zone_idx
  on public.world_events (zone_id) where zone_id is not null;
create index world_events_location_idx
  on public.world_events (location_id) where location_id is not null;

-- Fail-closed, SERVER-ONLY (the 0103 mining_fields / market_offers posture): RLS enabled with NO
-- client policy at all and NO grant to anon/authenticated → there is deliberately NO client read
-- path and NO client write path. The SOLE writer is World Events' OWN future service-role function
-- (a later slice; SECURITY DEFINER, client-revoked); the ONLY future client read path is a
-- flag-gated read RPC (a later slice). Both stay DARK behind `phase20_polish_enabled`. NOTHING reads
-- or writes this table yet.
alter table public.world_events enable row level security;
revoke all on public.world_events from public, anon, authenticated;

comment on table public.world_events is
  'PHASE20-POLISH: presentational timed world happenings (notice / world_state / seasonal banners) the '
  'map/dashboard will READ via a later flag-gated read RPC. Sole writer = World Events'' OWN future '
  'service-role function (a later slice); a downward LEAF — it writes ONLY this table and NEVER '
  'zone_state/location_state/fleets/combat/reward_grants, and grants no rewards (one-directional '
  'pipeline law). SERVER-ONLY: RLS enabled with no client policy/grant — no client read or write path '
  'exists; the flag-gated read RPC (later slice) is the only future client path. DARK behind '
  '`phase20_polish_enabled` — no writer or reader exists yet. scope↔target invariant enforced by CHECK '
  '(global ⇒ no target; zone ⇒ zone_id; location ⇒ location_id).';
comment on column public.world_events.is_active is
  'PHASE20-POLISH: false retires an event without deleting the row (no destructive cleanup). Future '
  'readers treat is_active=false OR an elapsed ends_at as not-currently-showing.';
comment on column public.world_events.ends_at is
  'PHASE20-POLISH: NULL = open-ended. Set by the future writer to time-box an event; the read RPC '
  'filters it out once now() passes ends_at.';

-- No function is created here → no execute-surface relock needed (0103/0128 precedent). No flag is
-- read or flipped; every Phase-20 capability remains server-rejected (the phase20_polish_enabled gate
-- seeded above, false). Forward-only; edits no shipped migration 0001–0138.
