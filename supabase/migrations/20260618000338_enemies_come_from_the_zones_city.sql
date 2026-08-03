-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0338 — THE ENEMY COMES OUT OF THE ZONE'S OWN CITY
--        a wave arrives from the settlement that owns the region it ambushes you in
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- THE ASK, from the owner while playing the live game:
--   "make the enemy come out from the city of the zone. for example snare."
--
-- ── WHICH "SNARE" IS THE CITY — ANSWERED, NOT ASSUMED ────────────────────────────────────────────
-- Production carries TWO rows called Snare, and telling them apart is the first half of this slice
-- (read-only against production, 2026-08-04, at head 20260618000335):
--   * a `locations` row  — Snare, location_type 'pirate_hunt', at (-45, 120), territory_radius 12.
--     THE SITE. THE CITY. A place a fleet can stand in front of.
--   * a `danger_zones` row — "Snare", a hand-drawn polygon, centroid (-49.99, 118.38). THE REGION
--     the ambush fires in. An area, not a place.
-- The owner's four trips into it were rally moves to open space at (-45,88), (-43,94), (-43,98) and
-- (-35,99) — inside the region, never at the site. So "the city of the zone" is the LOCATION row,
-- and the zone is what says which city owns that stretch of space.
--
-- ── THE ZONE -> SETTLEMENT LINK ALREADY EXISTS. NOTHING IS INVENTED, NOTHING IS HARDCODED ────────
-- `danger_zones.location_id` — declared at 20260618000233_pirate_intercept_danger_zones.sql:187 and
-- documented on that table as "optionally linked to a pirate_hunt location for live combat" — IS
-- the link. All three live pirate zones carry it, and all three point at their own pirate_hunt site:
--   Snare (drawn)     -> Snare    (-45, 120)
--   Reaver (circle)   -> Reaver   (-135, 120)
--   Blackden (circle) -> Blackden (195, 165)
-- And the ambush path already CARRIES that column all the way into the fight, with no help from
-- this migration:
--   pirate_intercept_leg_zone_hits  selects `z.location_id` (deployed body, read 2026-08-04)
--     -> pirate_intercepts.location_id
--     -> presence_create(..., v_loc.id, 'hunt_pirates')   (0303:295)
--     -> combat_encounters.location_id
-- Verified on production: the owner's last ten encounters all carry location_id = Snare while their
-- engagement points sit 20-35 units away in open space. The site is already known to the fight.
-- The tick already reads that row — `select base_difficulty, reward_tier, max_presence_seconds,
-- x, y into loc from locations where id = e.location_id` — once per encounter per tick, for
-- difficulty, reward tier and the presence cap. THE ORIGIN THEREFORE COSTS NO NEW READ, NO NEW JOIN
-- AND NO NEW COLUMN. And it is DATA: a designer who wants a zone's raiders to sortie from a
-- different city moves `danger_zones.location_id` to that city. A row, not a code edit.
--
-- ── WHAT ACTUALLY CHANGES: THE ANGLE, AND ONLY THE ANGLE ─────────────────────────────────────────
-- 0336 stopped the pile — every enemy in every production fight stood on ONE identical point — by
-- laying the wave out through `combat_formation_point` at radius (MEASURED formation extent + the
-- wave's own range + 1). That radius is 0336's and this migration does not touch it, because it is
-- what makes the clearance structural: every player ship is within the measured extent of the
-- anchor, so the minimum separation to any enemy is exactly (range + 1) whatever the formation's
-- shape — and measuring it, rather than taking the ring knob, is what stops a lone hull (its own
-- lead, standing ON the anchor at extent 0) from waiting out 9-15 seconds of silence it has no
-- screen to justify. 71 of 77 production ships are in no fleet at all.
-- What 0336 left unsaid is WHERE the wave comes from. Its phase argument was a bare constant, so
-- the ring was oriented by nothing: an ambush outside Snare looked exactly like an ambush in empty
-- space. 0338 replaces that constant — and nothing else — with the bearing from the engagement
-- anchor toward the zone's city, plus a fan that opens the wave into a compact arc centred on it.
-- THE ORIGIN IS A BEARING, NEVER A POSITION. Spawning the wave AT the city would be a forty-unit,
-- forty-tick walk before anyone fired, which is exactly the silence 0336's most valuable fix exists
-- to remove. The wave forms up on the city's side of the fight, at 0336's radius, and closes.
--
-- ── ONE NEW LEAF, ONE AUTHORITY ──────────────────────────────────────────────────────────────────
--   combat_wave_arrival_phase(anchor_x, anchor_y, site_x, site_y, slot)
--     THE ONE ANSWER to "which way does a wave arrive from". Returns the phase — in SLOTS, the unit
--     combat_formation_point's phase argument already takes — for slot k of the wave. Composed by
--     BOTH spawn arms and by nothing else. It reads no table, so it is immutable and revoked from
--     every client role, exactly as 0336's four leaves are.
--     The bare constant it replaces is DELETED from the tick in the same statement: after this
--     migration there is no second way for a wave to choose where it stands.
--
-- ── THE FALLBACKS, STATED ────────────────────────────────────────────────────────────────────────
-- The leaf answers 0.5 — 0336's own constant, so the wave lays out on 0336's plain ring
-- value-for-value — in exactly these cases. It never raises and never produces a pile:
--   (1) NO SETTLEMENT. The encounter's location_id is null, or the row is gone, so loc.x/loc.y read
--       NULL. Today a zone with no linked site cannot even open a fight — the resolver returns
--       'standalone_zone_stub_forced_stop' at 0303:243-249 and creates no encounter — so this is
--       the guard for a future in which that changes, not a live path.
--   (2) NOT IN A ZONE AT ALL, OR STANDING ON THE CITY. A deliberate hunt AT the site anchors the
--       fight on the site itself, so anchor = site and there is no direction to come from. A ring
--       is the right answer there: if you are fighting in the city, they come from all around you.
--   (3) DEGENERATE INPUT — a NULL anchor, a negative slot, or a NaN bearing. Fail to the ring, never
--       to a NULL coordinate and never to a raise inside the tick.
--
-- ── BLAST RADIUS ON THE LIVE GAME ────────────────────────────────────────────────────────────────
--   * CREATE OR REPLACE of process_combat_ticks plus ONE new function: an atomic catalog swap. The
--     tick body is read fresh every 3 seconds, so the next tick of every running fight runs the new
--     body. No per-fight opt-in, no drain.
--   * NO game_config write, NO schema change, NO grant widening, NO reward / drop / threshold /
--     range / speed / difficulty value moved. This migration writes not one row outside pg_proc.
--   * WHERE A FIGHT NOW OPENS FROM: a wave stands at the SAME distance from the anchor as it does
--     under 0336 — only its bearing changes — so the clearance invariant, the silent spawn tick and
--     the closing-tick count are all unchanged. What the player sees change is the direction the
--     raiders appear from, and that they arrive as a compact arc rather than a full encirclement.
--   * The client needs nothing: it already renders combat_units.pos_x/pos_y as the server sets them,
--     and the map already draws the site. No contract moves, so there is no other half to land.
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
-- Re-apply the deployed body with the two hunks reverted (0336's text) and drop the leaf. Nothing
-- else to unwind: no config, no combat row, no player state.
--
-- ── SELF-ASSERT MAP (one DO block per check — the statement number IS the diagnosis) ─────────────
-- WHAT THESE PROVE: (a) and (b) prove the emitted TEXT is what this migration intended. (c), (d)
-- and (e) EXECUTE the leaf and 0336's formation leaf together and prove the geometry itself. That
-- the real tick then places a real wave that way is proven by exactly one layer: the disposable
-- apply-proof driving the REAL tick (danger-combat-proof's DZCOMBAT_PASS_WAVERING and
-- DZCOMBAT_PASS_NODIRECTION).
--   (a) the leaf exists, immutable, non-SECURITY DEFINER, search_path pinned, and NO client role
--       can execute it
--   (b) ONE origin authority: both spawn arms compose the leaf and 0336's bare constant phase is
--       GONE from the tick
--   (c) THE FALLBACK IS THE PREDECESSOR, EXECUTED: with no site, a null anchor, a negative slot or
--       a site standing on the anchor, the leaf answers 0.5 for every slot and the resulting point
--       is value-for-value the point 0336 produced
--   (d) THE ORIGIN IS THE CITY, EXECUTED: for eight bearings around the circle, slot 0 lands exactly
--       on the ray from the anchor toward the site
--   (e) 0336'S RADIUS IS UNTOUCHED AND THE WAVE IS DISTINCT: over sixteen slots the distance from
--       the anchor is identical, slot for slot, to what 0336 produced, and the sixteen points are
--       sixteen distinct points
--   (f) metadata parity: process_combat_ticks changed its body and NOTHING else
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ── 0. PRECONDITIONS (read-only) — refuse to build on a base we did not slice from ───────────────
do $pre$
declare
  v_src text;
begin
  if to_regprocedure('public.combat_formation_point(double precision, double precision, double precision, integer, double precision)') is null then
    raise exception '0338 PRECONDITION FAIL: public.combat_formation_point is missing — 0338 composes 0336''s formation leaf and must be applied after it';
  end if;
  if to_regproc('public.process_combat_ticks') is null then
    raise exception '0338 PRECONDITION FAIL: public.process_combat_ticks is missing';
  end if;
  if to_regproc('public.combat_wave_arrival_phase') is not null then
    raise exception '0338 PRECONDITION FAIL: public.combat_wave_arrival_phase already exists — this slice is the only thing that creates it';
  end if;
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  -- 0336's MEASURED-extent radius must be what is deployed. If a later migration moved the wave's
  -- RADIUS, this slice's premise (only the angle moves) is no longer true and it must be re-derived
  -- rather than applied blind.
  if position('v_formation_extent + v_enemy_range + 1' in v_src) = 0 then
    raise exception '0338 PRECONDITION FAIL: the deployed tick does not carry 0336''s measured-extent wave radius — 0338 changes only the ANGLE at that radius and cannot be applied to a body that computes it differently';
  end if;
  -- The site the origin is taken from is the row the tick ALREADY reads. If that read ever stops
  -- carrying x/y, loc.x/loc.y below would silently be NULL and every wave would quietly fall back
  -- to 0336's plain ring — a regression that would look exactly like success.
  if position('max_presence_seconds, x, y into loc from locations where id = e.location_id' in v_src) = 0 then
    raise exception '0338 PRECONDITION FAIL: the deployed tick no longer reads the encounter location''s x/y into loc — the wave origin has no site to come from and would silently fall back to the plain ring';
  end if;
end $pre$;

-- ── 1. THE LEAF — the ONE authority for "which way does a wave arrive from" ──────────────────────
-- Phase is in SLOTS (0336's own unit: one slot is 2*pi/8 radians, so 0.5 means half a slot), which
-- is why this COMPOSES rather than forks. The value returned for slot k is
--     bearing_in_slots  +  fan(k)  -  k
-- so that combat_formation_point's own (slot + phase) reduces to (bearing_in_slots + fan(k)): the
-- SLOT still selects the radius ring exactly as 0336 defined it, and the PHASE carries the whole
-- angle. Nothing about the radius is touched.
--   bearing_in_slots = 4 * atan2(dy, dx) / pi — the direction of the city from the fight, in slots.
--   fan(k) = 0, -0.5, +0.5, -1, +1, -1.5, +1.5, -2, ... — half-slot steps alternating either side of
--   the bearing, so a wave opens as a compact arc CENTRED on the city rather than smeared one way
--   round the circle. Sixteen consecutive slots give sixteen distinct fan values; slots 8 and above
--   also step to a wider ring (0336's floor(slot/8) rule), so a wave larger than one ring still
--   cannot collide with itself.
-- WHY HALF SLOTS AND NOT WHOLE ONES: a whole-slot fan spans 45 degrees per unit, so the six-pirate
-- waves production actually produces (measured wave sizes 6, 2, 1, 6, 3, 0, 4) would wrap 225
-- degrees and read as an encirclement rather than a sortie. Half-slot steps put a six-pirate wave
-- inside a 112.5 degree arc facing the city.
-- WHY THE HALF-SLOT OFFSET 0336 USED IS NOT KEPT ON TOP: 0336 took phase 0.5 so that an enemy never
-- shares a ray with an escort. That offset is replaced here, not lost — the wave's rays are now set
-- by the city's bearing, and an enemy still cannot land ON an escort because it stands a full
-- (formation extent + its own range + 1) out while every escort is inside the extent. Sharing a ray
-- at different radii is a drawing detail; coming from the city is the thing the owner asked for.
create or replace function public.combat_wave_arrival_phase(
  p_anchor_x double precision,
  p_anchor_y double precision,
  p_site_x   double precision,
  p_site_y   double precision,
  p_slot     integer)
returns double precision
language sql
immutable
set search_path to 'public'
as $fwa$
  select case
           when b.bearing_slots is null then 0.5
           else b.bearing_slots
                + (case when p_slot % 2 = 0 then  p_slot::double precision / 4.0
                                            else -((p_slot + 1)::double precision / 4.0) end)
                - p_slot::double precision
         end
    from (
      select case
               when p_slot is null or p_slot < 0
                 or p_anchor_x is null or p_anchor_y is null
                 or p_site_x is null or p_site_y is null
                 or (p_site_x = p_anchor_x and p_site_y = p_anchor_y)
                 or 4.0 * atan2(p_site_y - p_anchor_y, p_site_x - p_anchor_x) / pi()
                    = 'NaN'::double precision
               then null::double precision
               else 4.0 * atan2(p_site_y - p_anchor_y, p_site_x - p_anchor_x) / pi()
             end as bearing_slots
    ) b;
$fwa$;

comment on function public.combat_wave_arrival_phase(double precision, double precision, double precision, double precision, integer) is
  'THE ONE AUTHORITY for "which way does a wave arrive from" (0338). Returns the phase, in SLOTS, to '
  'hand combat_formation_point for slot k of an enemy wave, so the wave forms up as a compact arc '
  'centred on the bearing from the engagement anchor toward the site that owns the zone — '
  'combat_encounters.location_id, which the ambush path carries from danger_zones.location_id. '
  'Changes the ANGLE only: the radius stays whatever the caller passes, so 0336''s clearance '
  'invariant is untouched. Answers 0.5 — 0336''s own constant, i.e. its plain ring — whenever there '
  'is no direction to come from: no site, a vanished site, a fight standing on the site, a null '
  'anchor, a negative slot or a NaN bearing. It never raises and never returns NULL for a non-null '
  'slot.';

revoke all on function public.combat_wave_arrival_phase(double precision, double precision, double precision, double precision, integer) from public;
revoke all on function public.combat_wave_arrival_phase(double precision, double precision, double precision, double precision, integer) from anon, authenticated;

-- ── 2. CAPTURE METADATA BEFORE THE REWRITE (for parity check f) ──────────────────────────────────
create temp table _0338_before (
  fname text primary key, body_md5 text, owner text, secdef boolean, volatility "char",
  parallel "char", proconfig text, args text, result text, acl text
) on commit drop;

insert into _0338_before
select p.proname, md5(p.prosrc), pg_get_userbyid(p.proowner), p.prosecdef, p.provolatile,
       p.proparallel, coalesce(array_to_string(p.proconfig, ','), ''),
       pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid),
       coalesce(p.proacl::text, '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'process_combat_ticks';

-- ── 3. REWRITE THE TWO SPAWN ARMS (located by exact deployed text, never retyped) ────────────────
-- Both old_t below were SLICED from the body 0336 emits — hunk 1 is the resolved-plan arm, hunk 2
-- the legacy synthetic arm — and they differ only in indentation, which is what makes each occur
-- exactly once and neither a substring of the other. The exactly-once guard below is the real gate.
do $rewrite$
declare
  r record;
  v_oid oid;
  v_src text;
  v_new text;
  v_n integer;
  v_done integer := 0;
begin
  for r in
    select * from (values
    (1, 'process_combat_ticks',
     $h1o$                select fp.x, fp.y into v_slot_x, v_slot_y
                  from public.combat_formation_point(v_anchor_x, v_anchor_y, v_formation_extent + v_enemy_range + 1, v_spawn_slot, 0.5) fp;$h1o$,
     $h1n$                -- ██ 0338 THE WAVE ARRIVES FROM THE ZONE'S OWN CITY ██
                -- 0336 put the wave on a RING instead of a pile, which is what stopped every enemy sharing one
                -- point. It did not say where the wave COMES FROM: the phase argument was a bare constant, so the
                -- arc was oriented by nothing and an ambush outside Snare looked exactly like an ambush in empty
                -- space. The owner, playing the live game: "make the enemy come out from the city of the zone. for
                -- example snare."
                -- THE LINK IS ALREADY IN THE DATA — nothing is invented here, and no mapping is hardcoded.
                -- danger_zones.location_id (0233) names the pirate site a zone belongs to; the ambush path carries
                -- exactly that column through pirate_intercept_leg_zone_hits -> pirate_intercepts.location_id ->
                -- presence_create -> combat_encounters.location_id. `loc` is THAT row, already read once per
                -- encounter per tick for difficulty / reward tier / presence cap — so the origin costs no new read,
                -- no new join and no new column. A designer who wants a zone's raiders to sortie from a different
                -- city moves danger_zones.location_id: a ROW, not a code edit.
                -- ONLY THE ANGLE MOVES, AND THAT IS THE WHOLE SCOPE. The radius is 0336's and is untouched — the
                -- wave still stands at the MEASURED formation extent plus its own range plus one — so the clearance
                -- invariant, the silence on the spawn tick and the number of closing ticks are all exactly what
                -- 0336 established. The origin is a BEARING, never a position: a city forty units away would
                -- otherwise mean a forty-tick walk before anyone fired.
                -- WHEN THERE IS NO DIRECTION — no linked site, a vanished one, or a fight standing on the site
                -- itself — combat_wave_arrival_phase returns 0336's own constant and the wave lays out on 0336's
                -- ring, value-for-value. The fallback is the predecessor, not a special case.
                select fp.x, fp.y into v_slot_x, v_slot_y
                  from public.combat_formation_point(v_anchor_x, v_anchor_y, v_formation_extent + v_enemy_range + 1, v_spawn_slot,
                         public.combat_wave_arrival_phase(v_anchor_x, v_anchor_y, loc.x, loc.y, v_spawn_slot)) fp;$h1n$),
    (2, 'process_combat_ticks',
     $h2o$            select fp.x, fp.y into v_slot_x, v_slot_y
              from public.combat_formation_point(v_anchor_x, v_anchor_y, v_formation_extent + v_enemy_range + 1, v_spawn_slot, 0.5) fp;$h2o$,
     $h2n$            -- ██ 0338 THE WAVE ARRIVES FROM THE ZONE'S OWN CITY ██
            -- 0336 put the wave on a RING instead of a pile, which is what stopped every enemy sharing one
            -- point. It did not say where the wave COMES FROM: the phase argument was a bare constant, so the
            -- arc was oriented by nothing and an ambush outside Snare looked exactly like an ambush in empty
            -- space. The owner, playing the live game: "make the enemy come out from the city of the zone. for
            -- example snare."
            -- THE LINK IS ALREADY IN THE DATA — nothing is invented here, and no mapping is hardcoded.
            -- danger_zones.location_id (0233) names the pirate site a zone belongs to; the ambush path carries
            -- exactly that column through pirate_intercept_leg_zone_hits -> pirate_intercepts.location_id ->
            -- presence_create -> combat_encounters.location_id. `loc` is THAT row, already read once per
            -- encounter per tick for difficulty / reward tier / presence cap — so the origin costs no new read,
            -- no new join and no new column. A designer who wants a zone's raiders to sortie from a different
            -- city moves danger_zones.location_id: a ROW, not a code edit.
            -- ONLY THE ANGLE MOVES, AND THAT IS THE WHOLE SCOPE. The radius is 0336's and is untouched — the
            -- wave still stands at the MEASURED formation extent plus its own range plus one — so the clearance
            -- invariant, the silence on the spawn tick and the number of closing ticks are all exactly what
            -- 0336 established. The origin is a BEARING, never a position: a city forty units away would
            -- otherwise mean a forty-tick walk before anyone fired.
            -- WHEN THERE IS NO DIRECTION — no linked site, a vanished one, or a fight standing on the site
            -- itself — combat_wave_arrival_phase returns 0336's own constant and the wave lays out on 0336's
            -- ring, value-for-value. The fallback is the predecessor, not a special case.
            select fp.x, fp.y into v_slot_x, v_slot_y
              from public.combat_formation_point(v_anchor_x, v_anchor_y, v_formation_extent + v_enemy_range + 1, v_spawn_slot,
                     public.combat_wave_arrival_phase(v_anchor_x, v_anchor_y, loc.x, loc.y, v_spawn_slot)) fp;$h2n$)
    ) as t(idx, fname, old_t, new_t)
    order by 1
  loop
    select p.oid into v_oid
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = r.fname;
    if v_oid is null then
      raise exception '0338 REWRITE FAIL [%]: function public.% not found', r.idx, r.fname;
    end if;
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = r.fname) <> 1 then
      raise exception '0338 REWRITE FAIL [%]: public.% is overloaded — refusing to guess', r.idx, r.fname;
    end if;

    v_src := pg_get_functiondef(v_oid);
    v_n := (length(v_src) - length(replace(v_src, r.old_t, ''))) / length(r.old_t);
    if v_n <> 1 then
      raise exception '0338 REWRITE FAIL [%]: hunk text occurs % time(s) in public.%, expected exactly 1 — the deployed body is not what this migration was sliced against',
        r.idx, v_n, r.fname;
    end if;

    v_new := replace(v_src, r.old_t, r.new_t);
    if length(v_new) <> length(v_src) - length(r.old_t) + length(r.new_t) then
      raise exception '0338 REWRITE FAIL [%]: unexpected length delta rewriting public.%', r.idx, r.fname;
    end if;
    execute v_new;
    v_done := v_done + 1;
  end loop;

  if v_done <> 2 then
    raise exception '0338 REWRITE FAIL: rewrote % site(s), expected 2', v_done;
  end if;
end $rewrite$;

-- ── 4. SELF-ASSERTS — one DO block per check; every prosrc probe strips comments first ───────────

-- (a) the leaf exists with the right posture, and NO client role can execute it
do $a$
declare v_oid oid;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_wave_arrival_phase';
  if v_oid is null then
    raise exception '0338 ASSERT (a) FAIL: leaf public.combat_wave_arrival_phase was not created';
  end if;
  if not exists (select 1 from pg_proc p where p.oid = v_oid
                  and p.provolatile = 'i' and p.prosecdef = false
                  and coalesce(array_to_string(p.proconfig, ','), '') = 'search_path=public') then
    raise exception '0338 ASSERT (a) FAIL: the leaf has the wrong volatility / security / search_path posture — it reads no table and must be IMMUTABLE, non-SECURITY DEFINER, search_path-pinned';
  end if;
  if has_function_privilege('anon', v_oid, 'EXECUTE')
     or has_function_privilege('authenticated', v_oid, 'EXECUTE') then
    raise exception '0338 ASSERT (a) FAIL: the leaf is EXECUTE-able by a client role — it is an engine internal, not a new surface';
  end if;
end $a$;

-- (b) ONE origin authority: both spawn arms compose the leaf, and 0336's bare constant phase is GONE
do $b$
declare v_code text; v_n integer;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_wave_arrival_phase(v_anchor_x, v_anchor_y, loc.x, loc.y, v_spawn_slot)', '')))
         / length('public.combat_wave_arrival_phase(v_anchor_x, v_anchor_y, loc.x, loc.y, v_spawn_slot)');
  if v_n <> 2 then
    raise exception '0338 ASSERT (b) FAIL: % composition(s) of the origin leaf (want exactly 2: the resolved-plan spawn arm and the legacy synthetic spawn arm)', v_n;
  end if;
  -- The constant this slice replaces must be GONE, or a wave still has two ways to choose where it
  -- stands and one of them is oriented by nothing. Comments are stripped above, so a comment that
  -- mentions the old shape cannot make this pass or fail.
  if position('v_spawn_slot, 0.5)' in v_code) > 0 then
    raise exception '0338 ASSERT (b) FAIL: the tick still spawns a wave at 0336''s bare constant phase — that is the second authority for where a wave comes from, and this slice exists to delete it';
  end if;
  -- and 0336's radius is still the one this slice composes, unchanged
  v_n := (length(v_code) - length(replace(v_code, 'v_formation_extent + v_enemy_range + 1', '')))
         / length('v_formation_extent + v_enemy_range + 1');
  if v_n <> 2 then
    raise exception '0338 ASSERT (b) FAIL: 0336''s measured-extent radius appears % time(s), want 2 — this slice must change the angle and leave the radius alone', v_n;
  end if;
end $b$;

-- (c) THE FALLBACK IS THE PREDECESSOR, EXECUTED — not asserted from the source text
do $c$
declare
  k integer; v_ph double precision;
  fx double precision; fy double precision; gx double precision; gy double precision;
begin
  for k in 0 .. 15 loop
    -- (1) no site at all
    v_ph := public.combat_wave_arrival_phase(10, -20, null, null, k);
    if v_ph is distinct from 0.5 then
      raise exception '0338 ASSERT (c) FAIL: with no site the leaf answered % at slot %, want 0336''s own 0.5', v_ph, k;
    end if;
    -- (2) the fight is standing on the site — no direction to come from
    v_ph := public.combat_wave_arrival_phase(10, -20, 10, -20, k);
    if v_ph is distinct from 0.5 then
      raise exception '0338 ASSERT (c) FAIL: with the fight standing on the site the leaf answered % at slot %, want 0336''s own 0.5', v_ph, k;
    end if;
    -- (3) a null anchor
    v_ph := public.combat_wave_arrival_phase(null, null, 10, -20, k);
    if v_ph is distinct from 0.5 then
      raise exception '0338 ASSERT (c) FAIL: with a null anchor the leaf answered % at slot %, want 0336''s own 0.5', v_ph, k;
    end if;
    -- and the POINT that falls out is 0336's point, value for value
    select fp.x, fp.y into fx, fy
      from public.combat_formation_point(10, -20, 7.5, k, public.combat_wave_arrival_phase(10, -20, null, null, k)) fp;
    select fp.x, fp.y into gx, gy
      from public.combat_formation_point(10, -20, 7.5, k, 0.5) fp;
    if fx is distinct from gx or fy is distinct from gy then
      raise exception '0338 ASSERT (c) FAIL: the no-direction fallback put slot % at (%,%) but 0336 puts it at (%,%) — the fallback must be the predecessor, value for value', k, fx, fy, gx, gy;
    end if;
  end loop;
  -- a negative slot is degenerate input, not a reason to raise inside the tick
  if public.combat_wave_arrival_phase(10, -20, 40, 60, -1) is distinct from 0.5 then
    raise exception '0338 ASSERT (c) FAIL: a negative slot must fall back to the ring rather than fold into the fan';
  end if;
  -- a NaN bearing must not escape into a coordinate
  if public.combat_wave_arrival_phase(10, -20, 'NaN'::double precision, 60, 0) is distinct from 0.5 then
    raise exception '0338 ASSERT (c) FAIL: a NaN site coordinate must fall back to the ring — Postgres orders NaN above every real, so a NaN position would silently win every distance comparison in the tick';
  end if;
end $c$;

-- (d) THE ORIGIN IS THE CITY, EXECUTED — slot 0 lands exactly on the ray anchor -> site
do $d$
declare
  i integer; th double precision;
  ax double precision := 12.5; ay double precision := -3.25; rad double precision := 7.5;
  sx double precision; sy double precision;
  fx double precision; fy double precision;
  ex double precision; ey double precision;
begin
  for i in 0 .. 7 loop
    -- eight bearings around the circle, at an arbitrary distance that is NOT the spawn radius: the
    -- origin is a DIRECTION, and how far away the city is must not move where the wave stands.
    th := 2 * pi() * i / 8.0 + 0.37;
    sx := ax + 137.0 * cos(th);
    sy := ay + 137.0 * sin(th);
    select fp.x, fp.y into fx, fy
      from public.combat_formation_point(ax, ay, rad, 0, public.combat_wave_arrival_phase(ax, ay, sx, sy, 0)) fp;
    ex := ax + rad * cos(th);
    ey := ay + rad * sin(th);
    if abs(fx - ex) > 1e-9 or abs(fy - ey) > 1e-9 then
      raise exception '0338 ASSERT (d) FAIL: with the city bearing % rad away, slot 0 landed at (%,%) but the point on the ray from the anchor toward the city at the spawn radius is (%,%) — the wave is not coming out of the city',
        round(th::numeric, 6), fx, fy, ex, ey;
    end if;
  end loop;
end $d$;

-- (e) 0336'S RADIUS IS UNTOUCHED, AND THE WAVE IS DISTINCT
do $e$
declare
  n_bad integer; n_dist integer;
  ax double precision := -4.0; ay double precision := 9.0; rad double precision := 6.25;
  sx double precision := -40.0; sy double precision := 120.0;
begin
  -- slot for slot, the distance from the anchor must be EXACTLY what 0336 produced. That identity is
  -- the whole clearance argument: every player ship is inside the measured extent, so a wave at the
  -- same radius is at the same minimum separation, whatever direction it came from.
  select count(*) into n_bad
    from generate_series(0, 15) as gs(k),
         lateral public.combat_formation_point(ax, ay, rad, gs.k,
                   public.combat_wave_arrival_phase(ax, ay, sx, sy, gs.k)) fnew,
         lateral public.combat_formation_point(ax, ay, rad, gs.k, 0.5) fold
   where abs(public.osn_distance(ax, ay, fnew.x, fnew.y)
             - public.osn_distance(ax, ay, fold.x, fold.y)) > 1e-9;
  if n_bad <> 0 then
    raise exception '0338 ASSERT (e) FAIL: % of 16 slots stand a different distance from the anchor than 0336 stood them — this slice moves the ANGLE only, and moving the radius would break the clearance invariant 0336 established', n_bad;
  end if;
  select count(distinct (f.x, f.y)) into n_dist
    from generate_series(0, 15) as gs(k),
         lateral public.combat_formation_point(ax, ay, rad, gs.k,
                   public.combat_wave_arrival_phase(ax, ay, sx, sy, gs.k)) f;
  if n_dist <> 16 then
    raise exception '0338 ASSERT (e) FAIL: sixteen slots produced only % distinct point(s) — a wave that shares points is the pile 0336 removed, coming back through the fan', n_dist;
  end if;
end $e$;

-- (f) metadata parity: the rewritten function changed its BODY and nothing else
do $f$
declare r record;
begin
  for r in
    select b.fname, b.body_md5 as old_md5, md5(p.prosrc) as new_md5,
           b.owner as old_owner, pg_get_userbyid(p.proowner) as new_owner,
           b.secdef as old_secdef, p.prosecdef as new_secdef,
           b.volatility as old_vol, p.provolatile as new_vol,
           b.parallel as old_par, p.proparallel as new_par,
           b.proconfig as old_cfg, coalesce(array_to_string(p.proconfig, ','), '') as new_cfg,
           b.args as old_args, pg_get_function_identity_arguments(p.oid) as new_args,
           b.result as old_result, pg_get_function_result(p.oid) as new_result,
           b.acl as old_acl, coalesce(p.proacl::text, '') as new_acl
      from _0338_before b
      join pg_proc p on p.proname = b.fname
      join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
  loop
    if r.old_md5 = r.new_md5 then
      raise exception '0338 ASSERT (f) FAIL: public.% is byte-identical to before the rewrite — the hunks did not land', r.fname;
    end if;
    if r.old_owner is distinct from r.new_owner or r.old_secdef is distinct from r.new_secdef
       or r.old_vol is distinct from r.new_vol or r.old_par is distinct from r.new_par
       or r.old_cfg is distinct from r.new_cfg or r.old_args is distinct from r.new_args
       or r.old_result is distinct from r.new_result or r.old_acl is distinct from r.new_acl then
      raise exception '0338 ASSERT (f) FAIL: public.% changed more than its body (owner %/%, secdef %/%, volatility %/%, parallel %/%, config %/%, args %/%, result %/%, acl %/%)',
        r.fname, r.old_owner, r.new_owner, r.old_secdef, r.new_secdef, r.old_vol, r.new_vol,
        r.old_par, r.new_par, r.old_cfg, r.new_cfg, r.old_args, r.new_args,
        r.old_result, r.new_result, r.old_acl, r.new_acl;
    end if;
  end loop;
end $f$;

commit;
