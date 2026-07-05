-- Byeharu — UX CLEANUP (item 4): ONE-WORD LOCATION NAMES — player-facing display rename, data-only.
--
-- Renames all 8 seeded locations to single evocative unique words (thematically preserving the
-- safe vs. pirate/danger character). FORWARD-ONLY: the historical seeds (0002 waypoints, 0066
-- starter ports) are NOT edited. Identity is untouched — the starter ports keep their fixed 0066
-- literal UUIDs (0066 explicitly documents `name` as mutable display data; every functional
-- lookup — reveal_starter_ports 0068, port-entry commission 0072/0077/0078/0080, market seed
-- 0085, anchors, services, eligibility, movement targets — is UUID-keyed), and the legacy
-- waypoints are matched by their current unique (zone_id, name) key. No table, writer, flag,
-- grant, or RPC change; the existing unique (zone_id, name) constraint holds for the new names
-- (all 8 distinct, and distinct within each zone).
--
--   Safe Rally Point    → Refuge      (Wreck Belt waypoint, safe_zone)
--   Pirate Ambush Point → Snare       (Wreck Belt waypoint, pirate_hunt)
--   Raider Outpost      → Reaver      (Wreck Belt waypoint, pirate_hunt)
--   Quiet Drift         → Lull        (Ion Storm Route waypoint, safe_zone)
--   Pirate Den          → Blackden    (Ion Storm Route waypoint, pirate_hunt)
--   Haven Reach         → Haven       (starter port b1a00001-0066-4a00-8a00-000000000001)
--   Slagworks Anchorage → Slagworks   (starter port b1a00002-0066-4a00-8a00-000000000002)
--   Driftmarch Waypost  → Driftmarch  (starter port b1a00003-0066-4a00-8a00-000000000003)
--
-- Fail-closed + atomic: the whole rename runs in one do-block transaction; any missing row or
-- surviving multi-word name aborts with NO partial rename. Re-running is a tolerated no-op
-- (UUID updates are naturally idempotent; the waypoint checks accept already-renamed rows).

do $$
begin
  -- ── Starter ports by FIXED 0066 UUID (identity = literal PK; name = mutable display data) ──────────
  update public.locations set name = 'Haven'      where id = 'b1a00001-0066-4a00-8a00-000000000001';
  update public.locations set name = 'Slagworks'  where id = 'b1a00002-0066-4a00-8a00-000000000002';
  update public.locations set name = 'Driftmarch' where id = 'b1a00003-0066-4a00-8a00-000000000003';
  if not exists (select 1 from public.locations where id = 'b1a00001-0066-4a00-8a00-000000000001' and name = 'Haven')
     or not exists (select 1 from public.locations where id = 'b1a00002-0066-4a00-8a00-000000000002' and name = 'Slagworks')
     or not exists (select 1 from public.locations where id = 'b1a00003-0066-4a00-8a00-000000000003' and name = 'Driftmarch') then
    raise exception 'location_names_single_word: a fixed starter-port row is missing (abort, no partial rename)';
  end if;

  -- ── Legacy 0002 waypoints by current unique (zone_id, name) key (zone-scoped, fail-closed) ─────────
  update public.locations l
     set name = m.new_name
    from (values
      ('Safe Rally Point',    'Refuge',   'Wreck Belt'),
      ('Pirate Ambush Point', 'Snare',    'Wreck Belt'),
      ('Raider Outpost',      'Reaver',   'Wreck Belt'),
      ('Quiet Drift',         'Lull',     'Ion Storm Route'),
      ('Pirate Den',          'Blackden', 'Ion Storm Route')
    ) as m(old_name, new_name, zone_name)
    join public.zones z on z.name = m.zone_name
   where l.zone_id = z.id and l.name = m.old_name;

  -- Every new waypoint name must now exist in its zone (accepts an already-renamed re-run).
  if (select count(*) from public.locations l join public.zones z on z.id = l.zone_id
       where (z.name, l.name) in (('Wreck Belt','Refuge'), ('Wreck Belt','Snare'), ('Wreck Belt','Reaver'),
                                  ('Ion Storm Route','Lull'), ('Ion Storm Route','Blackden'))) <> 5 then
    raise exception 'location_names_single_word: waypoint rename incomplete (abort, no partial rename)';
  end if;

  -- ── Player-facing goal holds: no old name survives, and NO location keeps a multi-word name ────────
  if exists (select 1 from public.locations where name in
      ('Safe Rally Point','Pirate Ambush Point','Raider Outpost','Quiet Drift','Pirate Den',
       'Haven Reach','Slagworks Anchorage','Driftmarch Waypost')) then
    raise exception 'location_names_single_word: an old two-word name survived (abort)';
  end if;
  if exists (select 1 from public.locations where name like '% %') then
    raise exception 'location_names_single_word: unexpected multi-word location name found — extend the rename map (abort)';
  end if;
end $$;
