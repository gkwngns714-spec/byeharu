-- Byeharu — S2 TERRITORY: location-centered territory radius (additive data, always-on).
--
-- WHAT: `locations.territory_radius numeric` (nullable) — the WORLD-UNIT radius of the zone of
-- influence a named location projects into open space. Seeded once here by CASE on location_type
-- (trade_outpost → 25; pirate_hunt AND pirate_den → 35 — all live hostiles are pirate_hunt,
-- pirate_den has 0 rows today and is seeded for the day it gains one; safe_zone/rally_point → 15;
-- everything else NULL = projects no territory), plus a PARITY re-create of get_world_map() that
-- adds the ONE field to the location JSON. NO feature flag: this is an additive display column
-- riding an existing read — there is no behavior to gate, and a NULL radius renders nothing.
--
-- WHY NOT the dormant `zones.radius` sibling (0002:33): that column is the ZONE's own geometric
-- extent — a zone-level bound on a CONTAINER of locations, already returned by get_world_map
-- (0002:106) and drawn nowhere. Territory is LOCATION-centered gameplay influence: one radius per
-- named site, a different concept at a different level of the sector→zone→location hierarchy.
-- Reusing the zone sibling would overload one column with two meanings and could not express two
-- locations with different radii inside one zone — so the dormant sibling stays dormant, untouched.
-- WHY NOT a game_config key: exploration_scan_radius / mining_extract_radius are SHIP-centered
-- global scalars (one knob each); territory varies PER LOCATION → a locations column, never config.
--
-- OWNERSHIP: migrations remain the sole writer of locations (0002:9-10) — this file writes the
-- static world once; no RPC gains a write path and no client can write the column (RLS: no write
-- policies, SELECT-only grants).
--
-- PARITY (get_world_map): the body below is a byte-copy of the TRUE head (0002:91-132 — a
-- `language sql stable` function NEVER re-created since; every later mention is a grant re-emit)
-- with EXACTLY ONE hunk: the inner location jsonb_build_object gains
-- 'territory_radius', l.territory_radius beside 'status', l.status. All three status='active'
-- filters (0002:121/125/129) are preserved verbatim — 20260618000175:161-180 structurally pins
-- them (hidden-port leak safety) — and the anon/authenticated execute grant is re-emitted. The
-- selftest (scripts/fleetgo-proof.sh) diffs this body against 0002's minus the one added field;
-- the in-file assert below re-pins the filters + the seed on the DEPLOYED state.

alter table public.locations add column territory_radius numeric;

-- ── Seed: the decided radius map (CASE on location_type; the column default is already NULL, the
-- explicit else arm states the "no territory" outcome rather than implying it). ──────────────────
update public.locations
set territory_radius = case location_type
  when 'trade_outpost' then 25
  when 'pirate_hunt' then 35
  when 'pirate_den' then 35
  when 'safe_zone' then 15
  when 'rally_point' then 15
  else null
end;

-- ── get_world_map(): PARITY re-create — 0002:91-132 byte-copied, ONE field added. ────────────────
create or replace function public.get_world_map()
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'sectors',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', se.id, 'name', se.name, 'sector_index', se.sector_index,
          'x', se.x, 'y', se.y, 'danger_tier', se.danger_tier, 'status', se.status,
          'zones', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'id', z.id, 'name', z.name, 'x', z.x, 'y', z.y, 'radius', z.radius,
                'base_difficulty', z.base_difficulty,
                'max_danger_level', z.max_danger_level,
                'reward_tier', z.reward_tier, 'visibility', z.visibility,
                'status', z.status,
                'locations', coalesce((
                  select jsonb_agg(
                    jsonb_build_object(
                      'id', l.id, 'name', l.name, 'location_type', l.location_type,
                      'x', l.x, 'y', l.y, 'base_difficulty', l.base_difficulty,
                      'reward_tier', l.reward_tier, 'activity_type', l.activity_type,
                      'min_power_required', l.min_power_required,
                      'is_public', l.is_public, 'status', l.status,
                      'territory_radius', l.territory_radius
                    ) order by l.name)
                  from public.locations l
                  where l.zone_id = z.id and l.status = 'active'
                ), '[]'::jsonb)
              ) order by z.name)
            from public.zones z
            where z.sector_id = se.id and z.status = 'active'
          ), '[]'::jsonb)
        ) order by se.sector_index)
      from public.sectors se
      where se.status = 'active'
    ), '[]'::jsonb)
  );
$$;

grant execute on function public.get_world_map() to anon, authenticated;

-- ── Self-assert (deploy-time; a raise aborts the migration txn — nothing half-applies) ───────────
do $$
declare v_src text; v_n int;
begin
  -- (a) HIDDEN-INVISIBILITY RE-PIN, structural: the DEPLOYED get_world_map() body still filters
  --     every level on status='active' (the 0175:161-180 pin ran against the PRE-0217 body on this
  --     chain — the re-create must re-prove it, or a hidden port would leak on deploy).
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.get_world_map()')::oid;
  if v_src is null then
    raise exception '0217 self-assert FAIL: public.get_world_map() does not exist';
  end if;
  if position('l.zone_id = z.id and l.status = ''active''' in v_src) = 0
     or position('z.sector_id = se.id and z.status = ''active''' in v_src) = 0
     or position('se.status = ''active''' in v_src) = 0 then
    raise exception '0217 self-assert FAIL: get_world_map() lost a status=''active'' filter — hidden ports would be VISIBLE; do not deploy';
  end if;
  -- (b) the one added field is really emitted.
  if position('''territory_radius'', l.territory_radius' in v_src) = 0 then
    raise exception '0217 self-assert FAIL: get_world_map() does not emit territory_radius';
  end if;
  -- (c) the seed landed, class-complete, world-wide (vacuity: the probed classes must exist — a
  --     chain with zero ports/hostiles/safe zones would green the sweep while proving nothing).
  select count(*) into v_n from public.locations where location_type = 'trade_outpost';
  if v_n = 0 then raise exception '0217 self-assert FAIL: no trade_outpost rows — the seed sweep would be vacuous'; end if;
  select count(*) into v_n from public.locations where location_type in ('pirate_hunt', 'pirate_den');
  if v_n = 0 then raise exception '0217 self-assert FAIL: no hostile rows — the seed sweep would be vacuous'; end if;
  select count(*) into v_n from public.locations where location_type in ('safe_zone', 'rally_point');
  if v_n = 0 then raise exception '0217 self-assert FAIL: no safe/rally rows — the seed sweep would be vacuous'; end if;
  select count(*) into v_n from public.locations
   where (location_type = 'trade_outpost' and territory_radius is distinct from 25)
      or (location_type in ('pirate_hunt', 'pirate_den') and territory_radius is distinct from 35)
      or (location_type in ('safe_zone', 'rally_point') and territory_radius is distinct from 15)
      or (location_type in ('mining_site', 'derelict_station', 'event_site') and territory_radius is not null);
  if v_n <> 0 then
    raise exception '0217 self-assert FAIL: % location(s) off the decided radius map (25/35/15/NULL)', v_n;
  end if;
  raise notice '0217 self-assert ok: territory_radius seeded 25/35/15/NULL class-complete; get_world_map re-created with the ONE added field and all three status=active filters intact';
end $$;
