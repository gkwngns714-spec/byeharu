-- 0289 — TERRITORY RINGS ÷3: the rings dominate the map and the owner has called them too large.
--
-- WHY THEY LOOK THIS BIG. 0220 tuned the radii to 10/12/8 and self-asserted "every territory pair
-- strictly disjoint; no ring reaches another location's center". 0227 then rebalanced world geometry
-- by scaling locations 3x AND territory_radius 3x (10/12/8 -> 30/36/24). Because both scaled by the
-- same factor the rings kept EXACTLY their old proportion of the map — so nothing regressed, and the
-- current size is the deliberate 0220 look, merely three times larger in absolute units.
--
-- The owner's judgement is that that proportion is wrong: at 30 units against 45-100 unit spacing a
-- ring nearly touches its neighbours, and a fleet docked at a location reads as sitting inside a huge
-- bubble. This restores the pre-0227 ABSOLUTE radii (10/12/8) while locations keep their 3x spread,
-- so each ring now covers roughly a NINTH of the area it did — the rings become a marker of a place,
-- not a region that swallows the map.
--
--   trade_outpost  30 -> 10
--   pirate_hunt    36 -> 12
--   safe_zone      24 ->  8
--
-- THIS IS A GAMEPLAY CHANGE, NOT A SKIN. Stated plainly because it must not surprise anyone:
-- territory_radius is the authority for public.fleet_in_territory (0218), which timed docking (0219)
-- consumes. Shrinking a ring shrinks the approach zone in which a fleet counts as "in territory", so
-- a fleet must come CLOSER to a location before docking becomes available, and territory-leave fires
-- sooner on departure. No rule is rewritten — the same predicate over smaller numbers. The renderer
-- is untouched: territoryLayer draws `territory_radius * WORLD_TO_VIEWBOX_SCALE`, world-true, so the
-- ring keeps telling the truth about the range it represents. Drawing a ring SMALLER than the real
-- radius was rejected outright: a ring that lies about a gameplay range is worse than a large ring.
--
-- Scale-only: no column, constraint, function, flag or policy changes. Uniform division preserves
-- every 0220/0227 invariant by construction (disjointness cannot break when radii only shrink).

update public.locations
set territory_radius = territory_radius / 3
where territory_radius is not null;

-- ── SELF-ASSERT — the 0220 invariants, re-proven on the new values ──────────────────────────────────
do $$
declare
  v_bad integer;
  v_min numeric;
begin
  -- (1) the positivity constraint (0219) still holds — a zero/negative radius would be a broken row.
  select count(*) into v_bad from public.locations
   where territory_radius is not null and territory_radius <= 0;
  if v_bad > 0 then
    raise exception '0289: % location(s) ended with a non-positive territory_radius', v_bad;
  end if;

  -- (2) 0220's headline invariant: every territory PAIR strictly disjoint (r_i + r_j < d).
  select count(*) into v_bad
    from public.locations a
    join public.locations b on b.id > a.id
   where a.territory_radius is not null and b.territory_radius is not null
     and public.osn_distance(a.x, a.y, b.x, b.y) <= (a.territory_radius + b.territory_radius);
  if v_bad > 0 then
    raise exception '0289: % overlapping territory pair(s) — disjointness broke', v_bad;
  end if;

  -- (3) …and no ring reaches another location's CENTRE.
  select count(*) into v_bad
    from public.locations a
    join public.locations b on b.id <> a.id
   where a.territory_radius is not null
     and public.osn_distance(a.x, a.y, b.x, b.y) <= a.territory_radius;
  if v_bad > 0 then
    raise exception '0289: % ring(s) reach another location centre', v_bad;
  end if;

  -- (4) the retune actually happened and landed in the intended band (a no-op migration is a bug).
  select max(territory_radius) into v_min from public.locations where territory_radius is not null;
  if v_min is null or v_min > 12 then
    raise exception '0289: largest territory_radius is % — expected <= 12 after the divide', v_min;
  end if;

  raise notice '0289 OK: territory radii divided by 3 (30/36/24 -> 10/12/8); pairs still disjoint; no ring reaches another centre';
end $$;
