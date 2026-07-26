-- 0295 — BASES FOLLOW THE WORLD: 0227 moved the world x3 and left the bases behind.
--
-- THE DEFECT. 0227 (world_geometry_rebalance) scaled locations.x/y x3 and territory_radius x3. At
-- 0227:95 it declared bases out of scope on this justification:
--
--     "bases.x/y stays untouched (every base sits at the player-home origin (0,0))"
--
-- THAT PREMISE IS FALSE, and was false when written. Production carries THREE bases:
--
--     Home Base   (  0,   0)
--     Slagworks   ( 70, -10)   <- its namesake LOCATION is at (210, -30)
--     Driftmarch  ( 10,  80)   <- its namesake LOCATION is at ( 30, 240)
--
-- Both non-origin bases sit at EXACTLY one third of their location's coordinates. They are the same
-- places; only one of the two tables was moved.
--
-- WHAT IT BREAKS FOR A PLAYER. origin_base_id is the destination of every return-home leg — the
-- retreat completion branch, the settle path, the telegraph flee. Each of those targets bases.x/y, so
-- a fleet ordered home flies to a point a third of the way in and parks in EMPTY SPACE: the map draws
-- locations, and there is nothing at (0,0) or (70,-10). The owner's report was exactly this — "retreat
-- sends fleets to a certain location, blank in map" — and the long wrong-length leg also holds the
-- group under the sortie predicate (moving/present/returning) for the whole flight.
--
-- WHY x3 IS THE RIGHT FIX AND NOT A DESIGN CHANGE. This restores 0227's OWN INTENT to the table it
-- missed. The ratio is exact and uniform (210/70 = 30/10 = 240/80 = -30/-10 = 3), the base and the
-- location share a name, and Home Base at the origin is a fixed point under any scaling — so the
-- migration is a no-op for it. Nothing about what a base IS changes; it simply stops being in a stale
-- coordinate space. The alternative reading — that bases are a separate home-space concept never meant
-- to align — is contradicted by the exact 3x ratio and the shared names: a genuinely independent
-- coordinate would not land on precisely one third.
--
-- SCALE ONLY. No column, constraint, function, flag, grant or policy changes. Nothing that depends on
-- base coordinates encodes a distance threshold in absolute units, so no rule is retuned here.

update public.bases
set x = x * 3,
    y = y * 3;

-- ── SELF-ASSERT — pins THIS migration's own effect, never the operator's configuration ──────────────
-- (0288 failed its production deploy by asserting a flag value the owner controls. An assert describes
--  what the migration did; the world's settings are not its business.)
do $$
declare
  v_mismatch integer;
begin
  -- (1) every base that shares a name with a location now sits ON that location. This is the whole
  --     point of the migration, and it is the assertion that would have caught 0227's false premise.
  select count(*) into v_mismatch
    from public.bases b
    join public.locations l on l.name = b.name
   where l.status = 'active'
     and (b.x is distinct from l.x or b.y is distinct from l.y);
  if v_mismatch > 0 then
    raise exception '0295: % base(s) still disagree with their namesake location''s coordinates', v_mismatch;
  end if;

  -- (2) DELIBERATELY ABSENT: an assert that "a base exists at (0,0)".
  --     I wrote one, and it failed the disposable stack — which seeds no origin base. That is the
  --     SAME defect as 0288's production failure: asserting the state of the WORLD rather than the
  --     effect of the MIGRATION. A row at the origin maps to the origin under any scaling; that is
  --     arithmetic, not something a proof needs to witness, and asserting a base must be there makes
  --     this migration depend on seed data it does not own.
  --     Assert (1) above is the real invariant and holds on any dataset, including an empty one.

  -- (3) coordinates stay finite and inside the charted square (the ONE navigable bound, +/-10000).
  if exists (select 1 from public.bases
              where x is null or y is null
                 or x <> x or y <> y                 -- NaN
                 or abs(x) > 10000 or abs(y) > 10000) then
    raise exception '0295: a base landed outside charted space or non-finite';
  end if;

  raise notice '0295 OK: bases scaled x3 into the post-0227 world; every named base now coincides with its location; the origin base is unmoved';
end $$;
