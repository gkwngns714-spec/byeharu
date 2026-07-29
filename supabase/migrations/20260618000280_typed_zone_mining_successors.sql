-- Byeharu — TYPED-ZONE MINING SUCCESSORS (migration 0280). Slice 7 of the typed-zone platform.
-- DARK COEXISTENCE. The mining POINT rows stay authoritative; this adds INACTIVE successor zones
-- beside them and changes no player outcome. One new flag, seeded false.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE TRAP THIS SLICE HAD TO AVOID, STATED FIRST BECAUSE IT IS THE WHOLE DESIGN
-- pirate_intercept_leg_zone_hits selects:
--       from public.danger_zones z ... where z.status = 'active' and ST_Intersects(z.boundary, leg)
-- There is NO zone_kind filter. Under the legacy path — which is still authoritative — ANY active
-- danger_zones row is a pirate interception zone, whatever it calls itself. Creating "mining" zones
-- as active rows would therefore have carpeted the map with new pirate ambush regions around every
-- ore field, silently, on deploy.
--
-- So every successor is born status='inactive'. Both readers that matter (leg_zone_hits and
-- get_danger_zones) filter on status='active', so an inactive successor is invisible to gameplay and
-- to the client. The self-assert proves the ACTIVE-zone count is unchanged by this migration.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE FOOTPRINT IS NOT INVENTED
-- The architecture review is explicit that points must not be reinterpreted as zones by inventing a
-- radius. We invent nothing: mining_extract_radius (game_config, default 750) is the radius the
-- extract command ALREADY uses to decide whether a ship is close enough to a field. The successor
-- circle is exactly that interaction footprint, materialised with the same ST_Buffer(...,32) idiom
-- 0254 uses for zone geometry. If that radius is later retuned, these successors are stale by
-- definition — which is why they are inactive and why authority has not moved.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT IS DELIBERATELY NOT HERE
--   * no authority switch — the point rows still serve every mining read and write;
--   * no runtime that resolves a mining effect (V2 registers pirate_intercept and combat only; a
--     mining effect would need a V3, and V2 is immutable);
--   * no reward duplication — the successor carries a REFERENCE to its field, not a copy of its
--     reward bundle. Two copies of a reward payload is how a migration ends up granting twice.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. preconditions ────────────────────────────────────────────────────────────────────────────
do $pre$
begin
  if to_regclass('public.mining_fields') is null then
    raise exception 'TYPED-ZONE 0280: public.mining_fields is missing';
  end if;
  if to_regclass('public.zone_effect_combat') is null then
    raise exception 'TYPED-ZONE 0280: slice 6 (0278) must land first';
  end if;
  if public.cfg_num('mining_extract_radius') is null then
    raise exception 'TYPED-ZONE 0280: mining_extract_radius is not configured — the footprint would have to be invented';
  end if;
end $pre$;

-- ── 0b. pre-image: the ACTIVE zone set, so "we added no live geometry" is provable ──────────────
create temporary table _tz0280_before on commit drop as
  select id from public.danger_zones where status = 'active';

-- ── 1. widen zone_kind — identity gains a value; it still dispatches nothing ────────────────────
-- 0273 deliberately left this alone; this is the slice that needs it. Widening a CHECK only ADMITS
-- values, so no existing row can become invalid. zone_kind remains rendering/traceability only —
-- what a zone DOES is still decided entirely by which effect rows exist.
-- The old constraint was declared inline, so its name is auto-generated. Discover it rather than
-- guess: a wrong guess would leave the original in place AND add the new one, and every insert of a
-- non-pirate kind would then fail the surviving check.
do $widen$
declare v_name text;
begin
  select con.conname into v_name
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
   where rel.relname = 'danger_zones' and con.contype = 'c'
     and pg_get_constraintdef(con.oid) ilike '%zone_kind%'
   limit 1;
  if v_name is not null then
    execute format('alter table public.danger_zones drop constraint %I', v_name);
  end if;
  alter table public.danger_zones
    add constraint danger_zones_zone_kind_check
    check (zone_kind in ('pirate', 'combat', 'mining', 'exploration'));
  -- and prove no existing row was invalidated (a widen can only admit, never reject — assert it)
  if exists (select 1 from public.danger_zones
              where zone_kind not in ('pirate','combat','mining','exploration')) then
    raise exception 'TYPED-ZONE 0280: an existing zone_kind falls outside the widened set';
  end if;
end $widen$;

-- ── 2. zone_effect_mining — the third composable effect ─────────────────────────────────────────
-- It REFERENCES its field rather than copying the reward bundle. A copied payload is a second
-- authority for what the field pays out, and two authorities are how a migration double-grants.
create table public.zone_effect_mining (
  zone_id          uuid primary key references public.danger_zones (id) on delete cascade,
  mining_field_id  uuid not null unique references public.mining_fields (id) on delete cascade,
  -- multiplies the field's OWN yield; 1 = unchanged, which is what every backfilled row gets
  yield_multiplier double precision not null default 1
    check (yield_multiplier = yield_multiplier
           and yield_multiplier <> 'Infinity'::double precision
           and yield_multiplier <> '-Infinity'::double precision
           and yield_multiplier > 0 and yield_multiplier <= 100),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

comment on table public.zone_effect_mining is
  'TYPED-ZONE PLATFORM (0280): the MINING effect of a zone. Holds a REFERENCE to its mining_fields '
  'row, never a copy of the reward bundle — a copied payload would be a second authority for what the '
  'field pays out, which is how a migration ends up granting twice. DARK: no dispatcher registers a '
  'mining effect (V2 is immutable and knows only pirate_intercept + combat), and every successor zone '
  'is inactive.';

alter table public.zone_effect_mining enable row level security;
revoke all on table public.zone_effect_mining from anon, authenticated;

-- ── 3. the flag — seeded false ──────────────────────────────────────────────────────────────────
insert into public.game_config (key, value, description) values
  ('typed_zone_mining_runtime_enabled', 'false'::jsonb,
   'TYPED-ZONE PLATFORM: may the typed-zone runtime serve MINING? Seeded false. While false the '
   'mining_fields point rows remain the sole authority and the successor zones stay inactive.')
on conflict (key) do nothing;

-- ── 4. the successors — INACTIVE, one per active field, footprint = the documented radius ───────
-- A row-at-a-time loop rather than a CTE, for two reasons that both bite in practice:
--   * danger_zones.name is CHECKed to 1..60 characters, so a long field name must be truncated —
--     and truncation can make two successor names collide;
--   * a CTE cannot return the SOURCE row alongside the inserted id, so the pairing would have to be
--     re-joined on that same (possibly colliding) name. Pairing a zone with the wrong field is the
--     kind of error that stays invisible until something grants the wrong ore.
-- The loop carries the field id in a variable, so the pairing is exact by construction.
do $seed$
declare
  v_f      record;
  v_zone   uuid;
  v_radius double precision := coalesce(public.cfg_num('mining_extract_radius'), 750);
  v_name   text;
begin
  for v_f in select id, name, space_x, space_y from public.mining_fields where is_active order by id
  loop
    v_name := left('Mining: ' || v_f.name, 60);
    insert into public.danger_zones (name, zone_kind, source, location_id, boundary, status)
    values (v_name, 'mining', 'drawn', null,
            public.st_buffer(public.st_makepoint(v_f.space_x, v_f.space_y), v_radius, 32),
            'inactive')
    returning id into v_zone;

    insert into public.zone_effect_mining (zone_id, mining_field_id) values (v_zone, v_f.id);
  end loop;
end $seed$;

-- ── 5. SELF-ASSERT — no live geometry added, every successor dark and linked ────────────────────
do $tzm$
declare
  v_active_before int;
  v_active_after  int;
  v_fields        int;
  v_succ          int;
  v_bad           int;
begin
  -- (1) THE LOAD-BEARING ASSERT: the ACTIVE zone set is untouched. If this ever fails, the migration
  -- has just created pirate ambush regions around every ore field, because leg_zone_hits filters on
  -- status alone and ignores zone_kind entirely.
  select count(*) into v_active_before from _tz0280_before;
  select count(*) into v_active_after  from public.danger_zones where status = 'active';
  if v_active_before <> v_active_after then
    raise exception 'TYPED-ZONE 0280 self-assert FAIL: the ACTIVE zone count moved % -> % — this migration must add NO live geometry',
      v_active_before, v_active_after;
  end if;
  if exists (select 1 from public.danger_zones z
              where z.status = 'active' and not exists (select 1 from _tz0280_before b where b.id = z.id)) then
    raise exception 'TYPED-ZONE 0280 self-assert FAIL: a NEW zone is active';
  end if;

  -- (2) one successor per ACTIVE field, and every one of them inactive
  select count(*) into v_fields from public.mining_fields where is_active;
  select count(*) into v_succ   from public.zone_effect_mining;
  if v_fields <> v_succ then
    raise exception 'TYPED-ZONE 0280 self-assert FAIL: % active fields but % successors', v_fields, v_succ;
  end if;
  select count(*) into v_bad
    from public.zone_effect_mining m join public.danger_zones z on z.id = m.zone_id
   where z.status <> 'inactive' or z.zone_kind <> 'mining';
  if v_bad > 0 then
    raise exception 'TYPED-ZONE 0280 self-assert FAIL: % successor(s) are not inactive mining zones', v_bad;
  end if;

  -- (3) NO REWARD COPY — the effect table references the field and stores no payload
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='zone_effect_mining'
                and (column_name ilike '%reward%' or column_name ilike '%bundle%' or data_type = 'jsonb')) then
    raise exception 'TYPED-ZONE 0280 self-assert FAIL: the mining effect copies a reward payload — that is a second authority';
  end if;

  -- (4) every backfilled multiplier is neutral, so the successors carry no behaviour change
  if exists (select 1 from public.zone_effect_mining where yield_multiplier <> 1) then
    raise exception 'TYPED-ZONE 0280 self-assert FAIL: a backfilled successor carries a non-neutral yield';
  end if;

  -- (5) the point rows are untouched — authority has not moved
  if to_regprocedure('public.mining_extract(uuid, uuid, text)') is not null
     and pg_get_functiondef(to_regprocedure('public.mining_extract(uuid, uuid, text)')) ilike '%zone_effect_mining%' then
    raise exception 'TYPED-ZONE 0280 self-assert FAIL: the mining runtime reads the successor table';
  end if;

  -- (6) dark, and fail-closed
  if coalesce(public.cfg_bool('typed_zone_mining_runtime_enabled'), true) then
    raise exception 'TYPED-ZONE 0280 self-assert FAIL: typed_zone_mining_runtime_enabled is not false'; end if;
  if has_table_privilege('anon', 'public.zone_effect_mining', 'select')
     or has_table_privilege('authenticated', 'public.zone_effect_mining', 'select') then
    raise exception 'TYPED-ZONE 0280 self-assert FAIL: a client role can read zone_effect_mining'; end if;

  -- (7) V2 stays mining-blind: a mining effect would need a V3, and V2 is immutable
  if pg_get_functiondef(to_regprocedure('public.typed_zone_effect_dispatch_v2(jsonb)')) ilike '%mining%' then
    raise exception 'TYPED-ZONE 0280 self-assert FAIL: V2 mentions mining — V2 is immutable'; end if;

  raise notice 'TYPED-ZONE 0280 self-assert ok: the ACTIVE zone set is UNCHANGED (% zones) and no new zone is active — critical, because leg_zone_hits filters on status alone and ignores zone_kind, so an active "mining" zone would be a pirate ambush region; % active mining field(s) each have exactly ONE successor and every successor is an INACTIVE mining zone whose footprint is the documented mining_extract_radius, not an invented one; the effect table REFERENCES its field and copies no reward payload; every backfilled yield multiplier is neutral; the mining runtime does not read the successor table; the flag is false, the table is fail-closed, and V2 stays mining-blind', v_active_after, v_fields;
end $tzm$;
