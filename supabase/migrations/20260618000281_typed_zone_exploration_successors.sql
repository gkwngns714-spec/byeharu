-- Byeharu — TYPED-ZONE EXPLORATION SUCCESSORS (migration 0281). Slice 8 of the typed-zone platform.
-- DARK COEXISTENCE, on its OWN gate. The exploration POINT rows stay authoritative.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHY THIS IS A SEPARATE SLICE AND A SEPARATE FLAG
-- Exploration and mining both happen to use point tables today, and it would be convenient to move
-- them together. The architecture review rejects that explicitly: sharing a rollout gate merely
-- because two systems share a STORAGE SHAPE couples two independent gameplay decisions. Discovering
-- a site and extracting ore have different semantics, different eligibility, and will very likely
-- want different footprints. So exploration gets typed_zone_exploration_runtime_enabled of its own,
-- and mining's flag can be flipped without dragging this along (or vice versa).
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE SAME TRAP AS 0280, RESTATED BECAUSE IT IS STILL LOAD-BEARING
-- pirate_intercept_leg_zone_hits filters `status = 'active'` and IGNORES zone_kind. Any ACTIVE
-- danger_zones row is a pirate ambush region regardless of what it calls itself. Every successor
-- here is therefore born INACTIVE, and the self-assert proves the active-zone set is unchanged.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE FOOTPRINT IS NOT INVENTED (same rule, different constant)
-- exploration_scan_radius (game_config, default 750) is the radius the scan command already uses to
-- decide whether a ship is close enough to a site. That, and nothing chosen by me, is the footprint.
-- It happens to equal mining's today; they are read from SEPARATE keys precisely so that retuning
-- one never silently moves the other.
--
-- NOT HERE: no authority switch, no dispatcher that resolves an exploration effect (V2 is immutable
-- and registers pirate_intercept + combat only), and no copy of any reward payload.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. preconditions ────────────────────────────────────────────────────────────────────────────
do $pre$
begin
  if to_regclass('public.exploration_sites') is null then
    raise exception 'TYPED-ZONE 0281: public.exploration_sites is missing';
  end if;
  if to_regclass('public.zone_effect_mining') is null then
    raise exception 'TYPED-ZONE 0281: slice 7 (0280) must land first — it widens zone_kind';
  end if;
  if public.cfg_num('exploration_scan_radius') is null then
    raise exception 'TYPED-ZONE 0281: exploration_scan_radius is not configured — the footprint would have to be invented';
  end if;
end $pre$;

-- ── 0b. pre-image of the ACTIVE zone set ────────────────────────────────────────────────────────
create temporary table _tz0281_before on commit drop as
  select id from public.danger_zones where status = 'active';

-- ── 1. zone_effect_exploration — the fourth composable effect ───────────────────────────────────
-- References its site; copies no reward payload, for the same reason mining does not.
create table public.zone_effect_exploration (
  zone_id               uuid primary key references public.danger_zones (id) on delete cascade,
  exploration_site_id   uuid not null unique references public.exploration_sites (id) on delete cascade,
  -- multiplies the site's OWN reward; 1 = unchanged, which is what every backfilled row gets
  discovery_multiplier  double precision not null default 1
    check (discovery_multiplier = discovery_multiplier
           and discovery_multiplier <> 'Infinity'::double precision
           and discovery_multiplier <> '-Infinity'::double precision
           and discovery_multiplier > 0 and discovery_multiplier <= 100),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

comment on table public.zone_effect_exploration is
  'TYPED-ZONE PLATFORM (0281): the EXPLORATION effect of a zone. Holds a REFERENCE to its '
  'exploration_sites row, never a copy of the reward bundle. DARK: no dispatcher registers an '
  'exploration effect, every successor zone is inactive, and it is gated SEPARATELY from mining — '
  'sharing a gate because two systems share a storage shape would couple independent decisions.';

alter table public.zone_effect_exploration enable row level security;
revoke all on table public.zone_effect_exploration from anon, authenticated;

-- ── 2. its OWN flag — never mining's ────────────────────────────────────────────────────────────
insert into public.game_config (key, value, description) values
  ('typed_zone_exploration_runtime_enabled', 'false'::jsonb,
   'TYPED-ZONE PLATFORM: may the typed-zone runtime serve EXPLORATION? Seeded false, and INDEPENDENT '
   'of typed_zone_mining_runtime_enabled — the two share a storage shape today, not a decision.')
on conflict (key) do nothing;

-- ── 3. the successors — INACTIVE, one per active site ───────────────────────────────────────────
-- Row-at-a-time for the same reason as 0280: danger_zones.name is CHECKed to 60 characters, so a
-- derived name can truncate into a collision, and a CTE cannot return the source row beside the
-- inserted id. Carrying the site id in a variable makes the pairing exact by construction.
do $seed$
declare
  v_s      record;
  v_zone   uuid;
  v_radius double precision := coalesce(public.cfg_num('exploration_scan_radius'), 750);
  v_name   text;
begin
  for v_s in select id, name, space_x, space_y from public.exploration_sites where is_active order by id
  loop
    v_name := left('Exploration: ' || v_s.name, 60);
    insert into public.danger_zones (name, zone_kind, source, location_id, boundary, status)
    values (v_name, 'exploration', 'drawn', null,
            public.st_buffer(public.st_makepoint(v_s.space_x, v_s.space_y), v_radius, 32),
            'inactive')
    returning id into v_zone;

    insert into public.zone_effect_exploration (zone_id, exploration_site_id) values (v_zone, v_s.id);
  end loop;
end $seed$;

-- ── 4. SELF-ASSERT ──────────────────────────────────────────────────────────────────────────────
do $tze$
declare
  v_active_before int;
  v_active_after  int;
  v_sites         int;
  v_succ          int;
  v_bad           int;
begin
  -- (1) the load-bearing one: NO live geometry added
  select count(*) into v_active_before from _tz0281_before;
  select count(*) into v_active_after  from public.danger_zones where status = 'active';
  if v_active_before <> v_active_after then
    raise exception 'TYPED-ZONE 0281 self-assert FAIL: the ACTIVE zone count moved % -> % — this migration must add NO live geometry',
      v_active_before, v_active_after;
  end if;
  if exists (select 1 from public.danger_zones z
              where z.status = 'active' and not exists (select 1 from _tz0281_before b where b.id = z.id)) then
    raise exception 'TYPED-ZONE 0281 self-assert FAIL: a NEW zone is active';
  end if;

  -- (2) one successor per ACTIVE site, every one inactive and correctly kinded
  select count(*) into v_sites from public.exploration_sites where is_active;
  select count(*) into v_succ  from public.zone_effect_exploration;
  if v_sites <> v_succ then
    raise exception 'TYPED-ZONE 0281 self-assert FAIL: % active sites but % successors', v_sites, v_succ;
  end if;
  select count(*) into v_bad
    from public.zone_effect_exploration e join public.danger_zones z on z.id = e.zone_id
   where z.status <> 'inactive' or z.zone_kind <> 'exploration';
  if v_bad > 0 then
    raise exception 'TYPED-ZONE 0281 self-assert FAIL: % successor(s) are not inactive exploration zones', v_bad;
  end if;

  -- (3) INDEPENDENCE FROM MINING, proven rather than intended: the two flags are distinct keys and
  -- this migration does not touch mining's.
  if not exists (select 1 from public.game_config where key = 'typed_zone_exploration_runtime_enabled') then
    raise exception 'TYPED-ZONE 0281 self-assert FAIL: the exploration flag is missing'; end if;
  if coalesce(public.cfg_bool('typed_zone_exploration_runtime_enabled'), true) then
    raise exception 'TYPED-ZONE 0281 self-assert FAIL: the exploration flag is not false'; end if;
  if coalesce(public.cfg_bool('typed_zone_mining_runtime_enabled'), true) then
    raise exception 'TYPED-ZONE 0281 self-assert FAIL: mining''s flag was disturbed'; end if;
  -- and no exploration successor was attached to a mining field, or vice versa
  if exists (select 1 from public.zone_effect_exploration e join public.zone_effect_mining m on m.zone_id = e.zone_id) then
    raise exception 'TYPED-ZONE 0281 self-assert FAIL: a zone carries BOTH point-successor effects';
  end if;

  -- (4) no reward copy
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='zone_effect_exploration'
                and (column_name ilike '%reward%' or column_name ilike '%bundle%' or data_type = 'jsonb')) then
    raise exception 'TYPED-ZONE 0281 self-assert FAIL: the exploration effect copies a reward payload';
  end if;
  if exists (select 1 from public.zone_effect_exploration where discovery_multiplier <> 1) then
    raise exception 'TYPED-ZONE 0281 self-assert FAIL: a backfilled successor carries a non-neutral multiplier';
  end if;

  -- (5) fail-closed
  if has_table_privilege('anon', 'public.zone_effect_exploration', 'select')
     or has_table_privilege('authenticated', 'public.zone_effect_exploration', 'select') then
    raise exception 'TYPED-ZONE 0281 self-assert FAIL: a client role can read zone_effect_exploration'; end if;

  raise notice 'TYPED-ZONE 0281 self-assert ok: the ACTIVE zone set is UNCHANGED (% zones) and no new zone is active; % active exploration site(s) each have exactly ONE INACTIVE exploration successor whose footprint is the documented exploration_scan_radius read from its OWN config key; exploration is gated by its OWN flag and mining''s was not disturbed; no zone carries both point-successor effects; the effect table references its site and copies no reward payload; every backfilled multiplier is neutral; the table is fail-closed', v_active_after, v_sites;
end $tze$;
