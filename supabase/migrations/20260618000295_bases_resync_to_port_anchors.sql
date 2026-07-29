-- 0295 — BASES RESYNC TO THEIR PORT ANCHOR: 0227 moved the world and left the bases behind, and the
--        seeder that mints them was hardcoded to the origin in the first place.
--
-- ══ THE DEFECT (0227's false premise — this part of the earlier diagnosis stands) ═══════════════════
-- 0227 (world_geometry_rebalance) scaled locations.x/y ×3 and territory_radius ×3, and relocated every
-- active location anchor in lockstep. At 0227:95 it declared bases out of scope on this justification:
--
--     "bases.x/y stays untouched (every base sits at the player-home origin (0,0))"
--
-- THAT PREMISE IS FALSE, and was false when written. `bases` stopped being "one home per player at the
-- origin" at 0157, which generalized it into ONE STORE PER (player, port): get_or_create_store
-- (0157:100-105) mints a store whose x/y are COPIED FROM THE PORT'S ACTIVE space_anchors ROW. Every
-- store minted before 0227 therefore froze a pre-rebalance port coordinate — exactly one third of where
-- that port sits today. (The earlier investigation recorded production carrying Slagworks (70,-10) and
-- Driftmarch (10,80) against locations at (210,-30) and (30,240): the same places, one table moved.)
--
-- ══ AND THE HALF THE ×3 COULD NEVER HAVE FIXED ═════════════════════════════════════════════════════
-- The player's 'Home Base' is NOT a scaled-down port. initialize_new_player (0157:142-147) inserts it
-- with LITERAL x=0, y=0 — while stamping location_id = the starter port (Haven Reach). So it claims to
-- be that port's store and sits nowhere near it.
--
-- Every origin_base_id resolver takes the OLDEST active base —
--     `select id, x, y, sector_id from bases where player_id = … and status='active'
--      order by created_at limit 1`
--   — 0231:619-621, 0231:855-857, 0231:930-932, 0231:1369-1371 —
-- and Home Base is created at signup, so THE OLDEST ACTIVE BASE IS ALWAYS HOME BASE AT (0,0). The
-- retreat/return-home fallback leg targets precisely that: process_combat_ticks reads x,y from that base
-- (0294:494, the current head; 0292:929 before it) and hands them to movement_create as a
-- target_type='base' destination (0294 / 0292:976-977). The fleet flies to (0,0) — and the map draws
-- locations, so (0,0) is blank. That IS the owner's report: "retreat sends fleets to a certain location,
-- blank in map".
--
-- 0 × 3 = 0. A blanket ×3 would have shipped GREEN and left the reported bug fully intact.
--
-- ══ WHY A RESYNC, NOT A ×3 ═════════════════════════════════════════════════════════════════════════
-- ×3 is a guess about history: it assumes every base's coordinate was written from a pre-0227 anchor.
-- That is true for the two legacy port stores, false for Home Base (never anchored at all), and false
-- for any store minted AFTER 0227 (already correct — ×3 would take it to ×9).
--
-- The RESYNC states the invariant directly instead: a base's coordinate IS its port's coordinate.
-- §1 reads it from the same authority get_or_create_store already reads — the location's active
-- space_anchors row — so this migration produces, for every base, exactly the value the live minting
-- path would produce for it today. That is correct for Home Base, correct for the stale legacy stores
-- (where it happens to equal ×3), correct for post-0227 stores (a no-op), and re-runnable: applying it
-- twice changes nothing. It also needs no premise about how the world was scaled, so it survives any
-- FUTURE relocation of a port — the C3/C4 direction (0263-0265) already made space_anchors the sole
-- coordinate authority for locations, and this puts bases under the same authority instead of under a
-- one-off arithmetic factor.
--
-- OUT OF SCOPE, BY DECISION — a base with NO resolvable anchor is LEFT EXACTLY AS IT IS:
--   • location_id IS NULL (a legacy base from before 0157's backfill, or one minted while the starter
--     seed was absent). There is no port to derive a coordinate from. Inventing one would be this
--     migration guessing.
--   • location_id set, but that location has no ACTIVE kind='location' anchor. Same reason.
-- These rows are not silently hidden: §4's assert is scoped to exactly the rows §1 can resync (so it
-- cannot fail on data this migration does not own), and the closing NOTICE reports the skipped count
-- out loud. An unanchored location is already invisible to the player — get_world_map is fail-closed on
-- the anchor join since 0263 — so such a base has no on-map destination to be synced to.
--
-- ══ WHAT ELSE IS IN THIS SLICE, AND WHY IT CANNOT BE SPLIT OFF ═════════════════════════════════════
-- Moving a base's coordinate changes a contract, and every side of it lands here (the repo's
-- never-ship-half-a-slice rule; 0227 broke exactly this by moving locations and skipping bases):
--
-- §2 IN-FLIGHT SNAPSHOTS. fleet_movements freezes its destination at departure (movement_create,
--    0007:105-119 — it also derives travel_distance/travel_seconds from that frozen pair). The client
--    and the server both interpolate the fleet's live position from origin→target (0208:423,
--    0209:114), and Stop parks the fleet at that interpolated point. A fleet already returning home
--    when this lands would otherwise keep flying to the stale point — the very bug, surviving in the
--    rows already in the air. So every status='moving', target_type='base' leg is re-pointed at its
--    target base's new coordinate. This mirrors what 0227 did for its own in-flight legs at
--    0227:140-149 (main_ship_space_movements, target_kind='location'); the vocabulary here is
--    different and was read off the schema, not assumed: fleet_movements.target_type ∈
--    ('base','location','zone','space') (0007:21 + 0208:56-58) and .status ∈
--    ('moving','arrived','cancelled','failed') (0007:32-33).
--    DELIBERATELY NOT TOUCHED: origin_x/origin_y of a leg that DEPARTED a base. The origin is where the
--    fleet physically was when it left — history, and the same point the client has drawn the whole
--    flight. Rewriting it would teleport the traversed half of the leg under the player's eyes. The
--    TARGET must be right because the fleet parks/settles there; the ORIGIN must not move because it
--    already happened. Arrived/cancelled/failed rows are history too, and are left alone.
--
-- §3 THE SOURCE. Without it, the very next signup re-creates the defect at (0,0) and §1 becomes a
--    one-shot cleanup of a bug that keeps being manufactured. initialize_new_player is re-created from
--    its TRUE HEAD (0157:125-161 — grepped: only 0005:124 and 0157:125 ever define it, nothing after
--    0157 redefines it) with ONE hunk: the two literal `0, 0` coordinates become a read of the starter
--    port's active anchor, coalesced to 0 exactly as get_or_create_store does at 0157:105. Signature,
--    `security definer`, `set search_path = public`, the idempotency guard, the sector lookup, the
--    NULL-safe location_id subquery, the units and resources seeds are byte-for-byte the 0157 head.
--    No grant statement has ever existed for this function (0005 grants only bootstrap_me, its
--    authenticated-callable wrapper), and CREATE OR REPLACE preserves owner and ACL — so no privilege
--    changes here, and none are needed.
--    NOT composed onto get_or_create_store on purpose: that helper RAISES unless the port passes
--    is_home_port_eligible (which requires an ACTIVE location). Signup must never fail because a seed
--    port is hidden or missing, which is why the head is NULL-safe and why this hunk stays a plain
--    coalesced read.
--
-- EVERY OTHER CONSUMER OF bases.x/y READS IT LIVE, so it needs nothing here — enumerated, not assumed:
--   • fleet_current_position (0218:153-155) resolves a fleet sitting AT a base straight from bases.x/y,
--     so idle fleets re-render at the corrected point the moment §1 commits;
--   • every mint path (0231:619/855/930/1369, 0050:199, 0051:196, 0149:101, 0152:196/382) and the
--     retreat/settle branch (0294:494, the head; 0292:929 before it) select the base's coordinate at
--     call time and hand it to movement_create — a leg minted after this migration is already correct;
--   • the ONLY frozen copies are the fleet_movements snapshots §2 rewrites. The other snapshot table
--     0227 had to reconcile, main_ship_space_movements, no longer exists: 0231:1599 dropped it.
--   • No space_anchors row has ever been written with kind='base' (grep-verified across every
--     migration), so a base has no anchor of its own to keep in lockstep — it borrows its port's.
--
-- FORWARD-ONLY. No DDL, no new column/constraint/index, no flag read or written, no policy, no grant.
-- Nothing that consumes a base coordinate encodes a distance threshold in absolute units, so no rule is
-- retuned here.

-- ── 1) RESYNC: a base's coordinate is its port's coordinate ─────────────────────────────────────────
-- The join is the whole scope statement: b.location_id IS NULL never matches (NULL = NULL is unknown),
-- and a location with no active anchor never matches — both are left untouched, as documented above.
-- space_anchors carries a unique partial index (one ACTIVE anchor per location, 0063), so the join can
-- produce at most one row per base. The is-distinct-from guard makes the write a no-op for rows that
-- already agree, which is what makes re-running this migration free.
update public.bases b
   set x = a.space_x,
       y = a.space_y
  from public.space_anchors a
 where a.location_id = b.location_id
   and a.kind   = 'location'
   and a.status = 'active'
   and (b.x is distinct from a.space_x or b.y is distinct from a.space_y);

-- ── 2) Re-point every IN-FLIGHT leg whose destination is a base that just moved ─────────────────────
-- Runs AFTER §1 on purpose: it copies the base's post-resync coordinate. A leg whose target_base_id
-- resolves to no base row cannot be re-pointed (there is nothing to read) and is reported by §4.
update public.fleet_movements m
   set target_x = b.x,
       target_y = b.y
  from public.bases b
 where b.id           = m.target_base_id
   and m.target_type  = 'base'
   and m.status       = 'moving'
   and (m.target_x is distinct from b.x or m.target_y is distinct from b.y);

-- ── 3) THE SOURCE — initialize_new_player seeds Home Base AT the starter port, not at the origin ────
-- 0157:125-161 TRUE HEAD, byte-for-byte, with exactly one hunk (marked below).
create or replace function public.initialize_new_player(p_player uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_base    uuid;
  v_sector  uuid;
  v_starter uuid := 'b1a00001-0066-4a00-8a00-000000000001';  -- Haven Reach (STARTER_PORT_1)
begin
  if exists (select 1 from bases where player_id = p_player) then
    return;
  end if;

  select id into v_sector from sectors where sector_index = 1;  -- Outer Haven

  -- 0295 HUNK: the coordinate was the literal origin, which is why every origin_base_id resolver
  -- (the oldest active base = this row) sent return-home legs into blank space. It is now the
  -- starter port's canonical anchor — the SAME authority get_or_create_store reads at 0157:100-105,
  -- with the same coalesce-to-0 fallback so a missing seed/anchor can never fail a signup or write
  -- NULL into a NOT NULL column. Nothing else in this function changes.
  insert into bases (player_id, name, sector_id, x, y, location_id)
    values (
      p_player, 'Home Base', v_sector,
      coalesce((select a.space_x from public.space_anchors a
                 where a.location_id = v_starter and a.kind = 'location' and a.status = 'active'), 0),
      coalesce((select a.space_y from public.space_anchors a
                 where a.location_id = v_starter and a.kind = 'location' and a.status = 'active'), 0),
      (select id from public.locations where id = v_starter)  -- NULL-safe if seed absent
    )
    returning id into v_base;

  insert into base_units (base_id, unit_type_id, quantity) values
    (v_base, 'scout', 100),
    (v_base, 'corvette', 20),
    (v_base, 'frigate', 5)
  on conflict (base_id, unit_type_id) do nothing;

  insert into base_resources (base_id, resource_code, amount) values
    (v_base, 'metal', 0),
    (v_base, 'crystal', 0),
    (v_base, 'energy', 0)
  on conflict (base_id, resource_code) do nothing;
end;
$$;

-- ── 4) SELF-ASSERT — pins THIS migration's own effect, and nothing else ─────────────────────────────
-- The rule, learned the hard way twice: an assert describes what the migration DID. It never asserts a
-- game_config VALUE, never a feature flag, never "a seed row must exist" (0288 failed a PRODUCTION
-- deploy by asserting a flag value; an earlier draft of THIS file asserted that a base exists at the
-- origin and broke the disposable stack, which seeds no base at all). Every check below is a
-- zero-mismatch count over the exact set the statements above wrote, so all four hold on an EMPTY
-- dataset — and none can fail on a row this migration deliberately did not touch.
--
-- The assert this file previously carried joined `bases b join locations l on l.name = b.name`. No
-- location is named 'Home Base', so the one row carrying the reported bug was skipped and the check
-- passed VACUOUSLY while the bug survived. That join is gone. Identity comes from location_id — the
-- column the schema actually uses — never from a name.
do $$
declare
  v_bad        integer;
  v_anchored   integer;
  v_unanchored integer;
  v_legs       integer;
  v_orphan     integer;
  v_src        text;
begin
  -- (1) THE INVARIANT §1 ESTABLISHED, and the one that would have caught 0227: every base whose
  --     location has an active anchor sits EXACTLY on that anchor. Scope == §1's scope, so an
  --     unanchored base cannot fail this — it is counted and reported instead.
  select count(*) into v_bad
    from public.bases b
    join public.space_anchors a
      on a.location_id = b.location_id and a.kind = 'location' and a.status = 'active'
   where b.x is distinct from a.space_x or b.y is distinct from a.space_y;
  if v_bad > 0 then
    raise exception '0295: % base(s) still disagree with their port''s active anchor', v_bad;
  end if;

  select count(*) into v_anchored
    from public.bases b
    join public.space_anchors a
      on a.location_id = b.location_id and a.kind = 'location' and a.status = 'active';
  select count(*) into v_unanchored
    from public.bases b
   where not exists (select 1 from public.space_anchors a
                      where a.location_id = b.location_id and a.kind = 'location' and a.status = 'active');

  -- (2) §2's effect: no leg still in the air is flying to a stale copy of its target base.
  select count(*) into v_bad
    from public.fleet_movements m
    join public.bases b on b.id = m.target_base_id
   where m.target_type = 'base' and m.status = 'moving'
     and (m.target_x is distinct from b.x or m.target_y is distinct from b.y);
  if v_bad > 0 then
    raise exception '0295: % in-flight base-bound leg(s) still carry a stale destination snapshot', v_bad;
  end if;

  select count(*) into v_legs
    from public.fleet_movements m
   where m.target_type = 'base' and m.status = 'moving';
  select count(*) into v_orphan
    from public.fleet_movements m
   where m.target_type = 'base' and m.status = 'moving'
     and not exists (select 1 from public.bases b where b.id = m.target_base_id);
  -- Reported, NOT raised: such a leg has no base to sync to and could never settle anyway (the base
  -- arrival branch, 0208:143-150, merges units into target_base_id). Failing the deploy over it would
  -- be this migration asserting the state of data it did not write.

  -- (3) §3's effect, proven STRUCTURALLY on the deployed body — the function is NOT invoked here
  --     (creating a player is a signup action, not a migration's business). Both probes target real
  --     code lines, never a comment: the anchor read must be present, and the head's hardcoded origin
  --     must be gone.
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.initialize_new_player(uuid)')::oid;
  if v_src is null then
    raise exception '0295: public.initialize_new_player(uuid) does not exist';
  end if;
  if position('space_anchors' in v_src) = 0 then
    raise exception '0295: initialize_new_player does not read the starter port anchor — the re-create did not land';
  end if;
  if position('v_sector, 0, 0' in v_src) > 0 then
    raise exception '0295: initialize_new_player still seeds Home Base at the hardcoded origin';
  end if;

  -- (4) coordinates stay finite and inside the charted square (the ONE navigable bound, ±10000).
  --     Anchors are already CHECK-bounded (0063), so this pins the rows §1 did NOT rewrite too.
  if exists (select 1 from public.bases
              where x is null or y is null
                 or x <> x or y <> y                 -- NaN
                 or abs(x) > 10000 or abs(y) > 10000) then
    raise exception '0295: a base sits outside charted space or carries a non-finite coordinate';
  end if;

  raise notice '0295 OK: % base(s) now sit exactly on their port''s active anchor; % base(s) have no anchor to resync to and were left untouched; % in-flight base-bound leg(s) re-pointed and consistent (% with no resolvable target base, left as-is); initialize_new_player now seeds Home Base at the starter port anchor instead of (0,0)',
    v_anchored, v_unanchored, v_legs, v_orphan;
end $$;
