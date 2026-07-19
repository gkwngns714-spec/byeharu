-- Byeharu — WORLD-EDITOR V1C PR-A/B: anchor scaffolding + world-wide location backfill.
-- ADDITIVE ONLY — the world is byte-identical after this migration.
--
-- GOAL (V1C direction): make public.space_anchors (0063) the canonical location coordinate authority.
-- This slice is the SAFE ADDITIVE first stage ONLY:
--   PR-A  a read resolver (get_location_anchor_points) that resolves a location's canonical point FROM
--         its active anchor — additive; NOTHING consumes it yet; get_world_map is NOT touched;
--   PR-B  a backfill: one ACTIVE kind='location' anchor for EVERY public.locations row that lacks one,
--         at EXACTLY the location's current (x, y) — extending the 0066/0227 invariant ("anchor
--         space_x/space_y EXACTLY equals locations.x/y") from the 3 starter ports to the WHOLE world.
--
-- EXPLICITLY NOT IN THIS SLICE (later, separate, world-affecting PRs behind the human deploy gate):
--   NO coordinate scale/normalize, NO point moved, NO get_world_map body change, NO cutover of any
--   existing read to the anchor, NO change to locations/zones/sectors/danger_zones rows or schema.
--
-- SAFETY ARGUMENT:
--   • The backfill only INSERTS new space_anchors rows — a server-private table (0063: RLS-on/no-policy,
--     service_role-only grants) that no player-facing read path consumes for these locations today. The
--     only live anchor consumers (mainship_space_dock_at_location / is_home_port_eligible /
--     reveal_starter_ports) key off the 3 starter-port anchors, which this migration DOES NOT TOUCH
--     (they already have active anchors ⇒ the not-exists backfill skips them; 0063's immutability guard
--     would reject an edit anyway). Newly anchored waypoints simply become anchor-resolvable — the same
--     coordinate they already display.
--   • The resolver is a NEW function; no existing function/view/client references it.
--   • The 0063 CHECKs stay the only bounds authority: a location outside [-10000,10000]^2 would abort
--     the INSERT (fail-closed) — no new coordinate-domain literal is introduced here.
--
-- Idempotent: the backfill inserts only where no ACTIVE location anchor exists (the partial unique
-- index space_anchors_one_active_per_location is the authority; the NOT EXISTS matches it exactly), so
-- a re-run inserts nothing. Plain INSERT..SELECT, no ON CONFLICT — within one migration txn there is no
-- concurrent writer, and a constraint violation should ABORT, never silently skip.

-- ── 1) PR-B backfill: one active anchor per unanchored location, at its current coordinate ───────────
do $$
declare v_inserted int;
begin
  insert into public.space_anchors (kind, location_id, space_x, space_y, status)
  select 'location', l.id, l.x, l.y, 'active'
    from public.locations l
   where not exists (
           select 1 from public.space_anchors a
            where a.location_id = l.id and a.kind = 'location' and a.status = 'active')
   order by l.id;

  get diagnostics v_inserted = row_count;
  raise notice '0245 backfill: % location anchor(s) inserted at their location''s exact current (x,y)', v_inserted;
end $$;

-- ── 2) PR-A resolver: the canonical anchor-backed location point read ────────────────────────────────
-- Resolves (location_id, space_x, space_y) from the ACTIVE location anchor — the read that a later
-- cutover slice will make authoritative. SECURITY DEFINER because space_anchors is server-private
-- (0063), but LEAK-PARITY with get_world_map is enforced in the body: the same three status='active'
-- filters (sector/zone/location — the 0175/0217 hidden-invisibility pin), so it exposes NOTHING not
-- already emitted by get_world_map (location ids + coordinates of active locations; anchor coords equal
-- location coords by the invariant asserted below). Exposed exactly like get_world_map: anon +
-- authenticated (+ service_role for server-side use).
create or replace function public.get_location_anchor_points()
returns table (location_id uuid, space_x double precision, space_y double precision)
language sql
stable
security definer
set search_path = public
as $$
  select l.id, a.space_x, a.space_y
    from public.locations l
    join public.zones    z  on z.id  = l.zone_id
    join public.sectors  se on se.id = z.sector_id
    join public.space_anchors a
      on a.location_id = l.id and a.kind = 'location' and a.status = 'active'
   where l.status  = 'active'
     and z.status  = 'active'
     and se.status = 'active'
   order by l.id;
$$;

revoke all on function public.get_location_anchor_points() from public;
grant execute on function public.get_location_anchor_points() to anon, authenticated, service_role;

-- ── 3) Self-assert (deploy-time; a raise aborts the migration txn — nothing half-applies) ────────────
do $$
declare
  v_locations int;
  v_anchors   int;
  v_n         int;
  v_src       text;
begin
  -- (a) vacuity: a world with no locations would green every sweep below while proving nothing.
  select count(*) into v_locations from public.locations;
  if v_locations = 0 then
    raise exception '0245 self-assert FAIL: no locations exist — the backfill sweep would be vacuous';
  end if;

  -- (b) EVERY location is anchored: count(active location-kind anchors) = count(locations).
  select count(*) into v_anchors
    from public.space_anchors where kind = 'location' and status = 'active';
  if v_anchors <> v_locations then
    raise exception '0245 self-assert FAIL: % active location anchor(s) for % location(s) — backfill incomplete or orphan anchor', v_anchors, v_locations;
  end if;

  -- (c) the 0066/0227 invariant, now WORLD-WIDE: every active location anchor's (space_x, space_y)
  --     EXACTLY equals its location's (x, y).
  select count(*) into v_n
    from public.space_anchors a
    join public.locations l on l.id = a.location_id
   where a.kind = 'location' and a.status = 'active'
     and (a.space_x is distinct from l.x or a.space_y is distinct from l.y);
  if v_n <> 0 then
    raise exception '0245 self-assert FAIL: % active location anchor(s) differ from their location''s exact (x,y)', v_n;
  end if;

  -- (d) no location carries more than one active anchor (the partial unique index enforces this;
  --     re-prove it on the deployed data rather than trusting the catalog alone).
  select count(*) into v_n
    from (select location_id from public.space_anchors
           where kind = 'location' and status = 'active'
           group by location_id having count(*) > 1) dup;
  if v_n <> 0 then
    raise exception '0245 self-assert FAIL: % location(s) with more than one active anchor', v_n;
  end if;

  -- (e) get_world_map is UNTOUCHED: still exists, still carries all three status=''active'' filters and
  --     the territory_radius field (the 0217 head), and does NOT read space_anchors — proof that this
  --     slice changed no existing read and the world render is byte-identical.
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.get_world_map()')::oid;
  if v_src is null then
    raise exception '0245 self-assert FAIL: public.get_world_map() does not exist';
  end if;
  if position('l.zone_id = z.id and l.status = ''active''' in v_src) = 0
     or position('z.sector_id = se.id and z.status = ''active''' in v_src) = 0
     or position('se.status = ''active''' in v_src) = 0 then
    raise exception '0245 self-assert FAIL: get_world_map() lost a status=''active'' filter — it must remain byte-identical in behavior';
  end if;
  if position('''territory_radius'', l.territory_radius' in v_src) = 0 then
    raise exception '0245 self-assert FAIL: get_world_map() no longer emits territory_radius — the 0217 head was altered';
  end if;
  if position('space_anchors' in v_src) > 0 then
    raise exception '0245 self-assert FAIL: get_world_map() references space_anchors — the cutover is a LATER slice, not this one';
  end if;

  raise notice '0245 self-assert ok: %/% locations anchored (active kind=location), anchor coords exactly equal location coords world-wide, no duplicate active anchors, get_world_map untouched (filters + territory_radius intact, no anchor read)',
    v_anchors, v_locations;
end $$;
