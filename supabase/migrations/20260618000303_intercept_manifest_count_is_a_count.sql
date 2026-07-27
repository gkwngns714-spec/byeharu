-- 0303 — THE AMBUSH MANIFEST GUARD COUNTS THE MANIFEST, NOT THE INSERT.
--
-- THE BUG, as the owner hit it in the live game (2026-07-27) and as production recorded it:
--
--   "moving inside a combat zone, changing course makes this saying and it teleports —
--    'This fleet is out on a sortie and can't take a new course yet.' Also, fighting starts
--    when entered a zone, but when i go out and back in, it doesn't."
--
-- Three symptoms, one defect. Production evidence, fleet e2151a71 (player 218500ff):
--   • group_sortie_members for that fleet: FOUR rows, written 14:54:33Z. The manifest is full.
--   • pirate_intercepts 14:57:07Z and 14:57:48Z: hit=true, lifecycle_state='fired',
--     encounter_id=NULL, note='empty_manifest'. Both rolled a hit and opened no combat.
--   • The fleet is now status='idle' parked at (-63, 96) = that intercept's entry_x/entry_y.
--
-- ROOT CAUSE — 0301:156-159 (this function's own head):
--
--     insert into public.group_sortie_members (...)
--       select ... from public.main_ship_instances msi
--        where msi.group_id = v_group and msi.player_id = v_fleet.player_id
--     on conflict (fleet_id, main_ship_id) do nothing;
--     get diagnostics v_manifest = row_count;
--
-- `row_count` after ON CONFLICT DO NOTHING is the number of rows INSERTED, not the number of rows
-- PRESENT. The freeze is deliberately idempotent — re-running it for a fleet that already carries a
-- manifest is supposed to be a no-op — so the second ambush of a fleet's life inserts nothing, reads
-- v_manifest = 0, and concludes the fleet cannot field a single ship. The guard then does what 0290
-- designed it to do with a genuinely empty manifest: park the fleet at the ambush point and open
-- nothing.
--
-- So, per fleet: the FIRST zone entry fights (rows inserted, count real). Every entry after it is
-- silently converted into "yank the fleet out of its course, park it, no combat" — and because the
-- manifest rows are still there, the fleet keeps reading as on-sortie while owning no encounter,
-- which is 0301 step 8 case (d): 'group_on_sortie', refused forever. The state cannot self-clear,
-- because the retreat that would release it needs an encounter that will never be created.
--
-- The guard's INTENT is correct and is preserved exactly: an ambush that cannot field a single ship
-- is not a fight. Only its MEASUREMENT was wrong. It now counts the manifest.
--
-- ── WHAT THIS MIGRATION CHANGES ─────────────────────────────────────────────────────────────────────
--   pirate_intercept_resolve_due_for_movement(uuid)   FROM 0301:988-1185, byte-identical except the
--                                                     ONE marked hunk that replaces the
--                                                     `get diagnostics ... row_count` read with a
--                                                     `select count(*)` over the manifest.
-- Nothing else is re-created. No schema change, no grant change, no flag change, no data repair.
--
-- ── WHAT THIS MIGRATION DELIBERATELY DOES **NOT** DO ────────────────────────────────────────────────
-- It does not release fleets ALREADY deadlocked by the bug (an open manifest, no encounter, parked).
-- Fleet e2151a71 is in that state right now and this migration will not move it. Unsticking live
-- player fleets is a data repair on a ~30-player production game and belongs to its own reviewed,
-- owner-authorised step — not smuggled into a logic fix. After this lands, a fleet in that state is
-- still stuck; it just stops being CREATED.
--
-- ── ROLLBACK ────────────────────────────────────────────────────────────────────────────────────────
-- Re-apply 0301's body verbatim. No schema or data change to undo.

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- ══════════ PRECONDITION: the head this migration claims to copy is the one that is deployed ════════
do $pre$
declare v_src text;
begin
  if to_regprocedure('public.pirate_intercept_resolve_due_for_movement(uuid)') is null then
    raise exception '0303: pirate_intercept_resolve_due_for_movement(uuid) is missing — 0301 must be deployed first';
  end if;

  v_src := regexp_replace(
             (select prosrc from pg_proc
               where oid = 'public.pirate_intercept_resolve_due_for_movement(uuid)'::regprocedure),
             '--[^\n]*', '', 'g');

  -- The exact defect being removed must be present in the deployed body. If it is not, this is not
  -- the head this migration was written against and re-creating from a stale copy would silently
  -- revert whatever landed in between (the 0136->0138 lesson).
  if position('get diagnostics v_manifest = row_count' in v_src) = 0 then
    raise exception '0303: the deployed resolver does not read v_manifest from row_count — refusing to overwrite an unexpected head';
  end if;

  -- And the guard it feeds must still be there, or the fix has nothing to protect.
  if position('empty_manifest' in v_src) = 0 then
    raise exception '0303: the deployed resolver carries no empty_manifest guard — refusing to overwrite an unexpected head';
  end if;
end
$pre$;

-- ══════════ THE FUNCTION — 0301:988-1185 VERBATIM, ONE MARKED HUNK ══════════════════════════════════
create or replace function public.pirate_intercept_resolve_due_for_movement(p_movement_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now      timestamptz := clock_timestamp();
  v_mv       record;
  v_pi       record;
  v_claim    record;
  v_fleet    record;
  v_group    uuid;
  v_frac     double precision;
  v_pos      record;
  v_zone_ok  boolean;
  v_manifest integer;
  v_loc      record;
  v_presence uuid;
  v_enc      uuid;
begin
  -- 1) THE MOVEMENT, LOCKED FIRST. A movement that is no longer moving owes nothing: terminalise
  --    whatever it still had pending rather than leaving a row that can never fire.
  select id, fleet_id, player_id, origin_x, origin_y, target_x, target_y, status, depart_at, arrive_at
    into v_mv
    from public.fleet_movements
   where id = p_movement_id
     for update;
  if not found or v_mv.status <> 'moving' then
    perform public.pirate_intercept_cancel_pending_for_movement(p_movement_id, 'movement_not_moving');
    return jsonb_build_object('fired', false, 'reason', 'not_moving');
  end if;

  -- 2) THE OWED AMBUSH, LOCKED SECOND. At most one can exist — the unique partial index says so —
  --    which is also why nothing below needs to sweep "the other" pending rows after firing.
  select *
    into v_pi
    from public.pirate_intercepts
   where movement_id = p_movement_id
     and lifecycle_state = 'pending'
     for update;
  if not found then
    return jsonb_build_object('fired', false, 'reason', 'nothing_pending');
  end if;

  -- 3) NOT YET. Both gates, against the one captured clock.
  if v_now < v_pi.trigger_at then
    return jsonb_build_object('fired', false, 'reason', 'not_due');
  end if;
  select o_x, o_y into v_pos
    from public.movement_position_at(v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y,
                                     v_mv.depart_at, v_mv.arrive_at, v_now);
  -- Where along its own leg the fleet has actually got to. A degenerate leg is treated as fully
  -- travelled (there is nowhere else to be), matching movement_position_at's own clamp behaviour.
  select case
           when ST_Length(ST_MakeLine(ST_MakePoint(v_mv.origin_x, v_mv.origin_y),
                                      ST_MakePoint(v_mv.target_x, v_mv.target_y))) > 0
           then ST_LineLocatePoint(
                  ST_MakeLine(ST_MakePoint(v_mv.origin_x, v_mv.origin_y),
                              ST_MakePoint(v_mv.target_x, v_mv.target_y)),
                  ST_MakePoint(v_pos.o_x, v_pos.o_y))
           else 1.0
         end
    into v_frac;
  if coalesce(v_frac, 0) + 1e-9 < v_pi.entry_fraction then
    return jsonb_build_object('fired', false, 'reason', 'not_reached', 'progress', v_frac);
  end if;

  -- 4) LIVENESS REVALIDATION — never geometry. Each failure TERMINALISES the row.
  --    (a) the fleet must still be the one that was ambushed, and still be the unified group shape.
  select id, player_id, group_id, main_ship_id
    into v_fleet
    from public.fleets
   where id = v_mv.fleet_id
     for update;
  if not found or v_fleet.id is distinct from v_pi.fleet_id
     or v_fleet.group_id is null or v_fleet.main_ship_id is not null then
    perform public.pirate_intercept_cancel_pending_for_movement(p_movement_id, 'fleet_changed');
    return jsonb_build_object('fired', false, 'reason', 'fleet_changed');
  end if;
  v_group := v_fleet.group_id;

  --    (b) a fleet already in a fight cannot be pulled into a second one.
  if exists (select 1 from public.combat_encounters ce
              where ce.fleet_id = v_fleet.id and ce.status in ('active', 'retreating')) then
    perform public.pirate_intercept_cancel_pending_for_movement(p_movement_id, 'fleet_in_combat');
    return jsonb_build_object('fired', false, 'reason', 'fleet_in_combat');
  end if;

  --    (c) the zone must still be lit. An owner who unpublishes a zone (0255) or deactivates it (0268)
  --        calls off the ambushes it owes — the movement then simply continues to its destination.
  --        Under the typed-zone runtime the effect row must still exist too, for the same reason.
  select (z.status = 'active')
     and (not coalesce(public.cfg_bool('typed_zone_pirate_intercept_runtime_enabled'), false)
          or exists (select 1 from public.zone_effect_pirate_intercept ze where ze.zone_id = z.id))
    into v_zone_ok
    from public.danger_zones z
   where z.id = v_pi.zone_id;
  if coalesce(v_zone_ok, false) is not true then
    perform public.pirate_intercept_cancel_pending_for_movement(p_movement_id, 'zone_inactive');
    return jsonb_build_object('fired', false, 'reason', 'zone_inactive');
  end if;

  -- 5) CLAIM IT. Conditional on the row still being pending: if a concurrent worker got here first,
  --    no row comes back and this one aborts without touching anything. Two workers cannot both fire.
  update public.pirate_intercepts
     set lifecycle_state = 'fired', resolved_at = v_now
   where id = v_pi.id and lifecycle_state = 'pending'
  returning * into v_claim;
  if not found then
    return jsonb_build_object('fired', false, 'reason', 'lost_race');
  end if;

  -- ── FROM HERE THE AMBUSH IS COMMITTED. The blocks below are 0294:1322-1402 with the restamp and
  -- ── the unit translation removed, and the ambush point taken from the row instead of recomputed.

  update public.fleet_movements set status = 'cancelled', resolved_at = v_now where id = p_movement_id;

  -- THE FLEET STOPS WHERE IT WAS AMBUSHED. This is the 0293 [A1] leaf, and it now runs BEFORE the
  -- presence exists — which is what lets combat_create_encounter read the fleet's own position as the
  -- engagement point instead of anything restamping it afterwards.
  perform public.fleet_set_in_space(v_fleet.id, v_pi.entry_x, v_pi.entry_y);

  -- The rest of a plotted route is ABANDONED, not silently resumed later from an unplanned position.
  -- 0233 made exactly this decision at command_ship_group_go_route:1085-1089 for the order-time
  -- ambush; deferring the ambush must not quietly reverse it. This makes the resolver a documented
  -- writer of fleet_route_legs (see that table's comment).
  delete from public.fleet_route_legs where fleet_id = v_fleet.id;

  if v_pi.location_id is null then
    -- STANDALONE drawn zone (no linked pirate_hunt location): the documented combat stub. No location
    -- means no presence/encounter is possible without inventing one — the ambush is made TANGIBLE by
    -- the forced stop above. Not a no-op.
    update public.pirate_intercepts set note = 'standalone_zone_stub_forced_stop' where id = v_pi.id;
    return jsonb_build_object('fired', true, 'reason', 'standalone_zone_stub', 'intercept_id', v_pi.id);
  end if;

  select l.id, l.zone_id, z.sector_id
    into v_loc
    from public.locations l
    join public.zones z on z.id = l.zone_id
   where l.id = v_pi.location_id and l.status = 'active';
  if v_loc.id is null then
    -- the linked location vanished/deactivated since the zone was drawn/seeded — fail open: parked,
    -- no combat, rather than reference a location that can no longer host a presence.
    update public.pirate_intercepts set note = 'location_missing' where id = v_pi.id;
    return jsonb_build_object('fired', true, 'reason', 'location_missing', 'intercept_id', v_pi.id);
  end if;

  -- Freeze the sortie MANIFEST — byte-identical INSERT shape to send_ship_group_hunt's sole-writer
  -- freeze (0168:304-306), so combat_create_encounter's manifest-gated branch routes this fleet into
  -- combat_create_group_encounter exactly as a deliberate hunt does. ON CONFLICT DO NOTHING:
  -- idempotent against a (should-be-impossible) re-entry.
  insert into public.group_sortie_members (fleet_id, main_ship_id, player_id)
  select v_fleet.id, msi.main_ship_id, v_fleet.player_id
    from public.main_ship_instances msi
   where msi.group_id = v_group and msi.player_id = v_fleet.player_id
  on conflict (fleet_id, main_ship_id) do nothing;

  -- ── ★ THE 0303 HUNK — COUNT THE MANIFEST, NOT THE INSERT ★ ────────────────────────────────────────
  -- The head read `get diagnostics v_manifest = row_count` here. That is the number of rows the
  -- statement above INSERTED, and that statement is deliberately idempotent (ON CONFLICT DO NOTHING),
  -- so a fleet that already carries its manifest inserts zero and then reads as having no ships at
  -- all. The question this guard asks is "can this ambush field a single ship?" — a question about
  -- the manifest's CONTENTS. Ask it of the manifest.
  select count(*) into v_manifest
    from public.group_sortie_members gsm
   where gsm.fleet_id = v_fleet.id;
  -- ── ★ END OF THE 0303 HUNK — the head continues verbatim from here ★ ──────────────────────────────

  -- 0290 ZERO-MANIFEST GUARD, sited exactly where 0290 put it: BEFORE presence_create. The freeze
  -- reads LIVE main_ship_instances.group_id and can legitimately return no rows (an empty/disbanded
  -- group, every ship reassigned). With no manifest, 0168's combat_create_encounter takes the legacy
  -- branch and inserts combat_units from fleet_units — a table a TEAM-SORTIE fleet has no rows in —
  -- producing an encounter with ZERO combat_units: nothing to draw, nothing to fight, and
  -- player_power_start = 0. An ambush that cannot field a single ship is not a fight. The fleet is
  -- already parked at the point it actually reached; log why and open nothing.
  if v_manifest = 0 then
    update public.pirate_intercepts set note = 'empty_manifest' where id = v_pi.id;
    return jsonb_build_object('fired', true, 'reason', 'empty_manifest', 'intercept_id', v_pi.id);
  end if;

  -- presence_create -> activity_start('hunt_pirates') -> combat_create_encounter -> (manifest exists)
  -- -> combat_create_group_encounter. FOUR frozen functions composed, ZERO re-created here. The
  -- presence carries NO coordinate and still does not need to: the fleet is already standing at the
  -- ambush point, and combat_create_encounter reads it from there.
  v_presence := public.presence_create(v_fleet.player_id, v_fleet.id, v_loc.sector_id, v_loc.zone_id, v_loc.id, 'hunt_pirates');

  select id into v_enc from public.combat_encounters where presence_id = v_presence order by created_at desc limit 1;
  update public.pirate_intercepts
     set encounter_id = v_enc, presence_id = v_presence
   where id = v_pi.id;

  -- combat_telegraph_enabled (lit by 0300) makes activity_start record a pending_encounters row and
  -- return WITHOUT creating the encounter; the telegraph cron opens it a few seconds later. The
  -- ambush has still FIRED — the leg is cancelled and the fleet is parked at the entry point — there
  -- is simply no encounter row to record yet. Say which of the two happened rather than reporting a
  -- null encounter_id as 'combat_started'. When the telegraph cron does open it, the fleet is still
  -- parked in open space at the entry point, so combat_create_encounter resolves the same engagement
  -- point this resolution would have.
  return jsonb_build_object(
    'fired', true,
    'reason', case when v_enc is null then 'combat_telegraphed' else 'combat_started' end,
    'intercept_id', v_pi.id, 'zone_id', v_pi.zone_id,
    'entry_x', v_pi.entry_x, 'entry_y', v_pi.entry_y,
    'location_id', v_loc.id, 'presence_id', v_presence, 'encounter_id', v_enc);
end;
$$;

-- ══════════ SELF-ASSERT — the fix is in and the head's shape survived ═══════════════════════════════
do $post$
declare v_src text;
begin
  v_src := regexp_replace(
             (select prosrc from pg_proc
               where oid = 'public.pirate_intercept_resolve_due_for_movement(uuid)'::regprocedure),
             '--[^\n]*', '', 'g');

  -- (a) the defect is GONE. Asserted on the comment-stripped body so the explanation above, which
  --     quotes the old line, cannot false-green this.
  if position('get diagnostics v_manifest = row_count' in v_src) > 0 then
    raise exception '0303 FAIL: the resolver still reads v_manifest from the insert row_count';
  end if;

  -- (b) the replacement is a real count over the manifest table.
  if position('select count(*) into v_manifest' in v_src) = 0
     or position('from public.group_sortie_members gsm' in v_src) = 0 then
    raise exception '0303 FAIL: v_manifest is not counted from group_sortie_members';
  end if;

  -- (c) the guard it feeds is UNCHANGED — this migration fixes the measurement, never the policy.
  if position('empty_manifest' in v_src) = 0 then
    raise exception '0303 FAIL: the empty_manifest guard was lost';
  end if;

  -- (d) the count must still be taken BEFORE the guard reads it, or the fix is inert.
  if position('select count(*) into v_manifest' in v_src) > position('if v_manifest = 0' in v_src) then
    raise exception '0303 FAIL: the manifest count is taken after the guard that consumes it';
  end if;

  -- (e) the freeze must still be idempotent. If a later edit ever drops ON CONFLICT DO NOTHING, this
  --     function starts raising on a re-ambush instead of no-opping.
  if position('on conflict (fleet_id, main_ship_id) do nothing' in v_src) = 0 then
    raise exception '0303 FAIL: the manifest freeze lost its idempotent ON CONFLICT clause';
  end if;

  -- (f) the composed chain is intact: still one presence_create, still no direct encounter creation.
  if position('presence_create' in v_src) = 0 then
    raise exception '0303 FAIL: presence_create is no longer composed';
  end if;
  if position('combat_create_group_encounter' in v_src) > 0 then
    raise exception '0303 FAIL: the resolver now creates an encounter directly — that is a second path';
  end if;

  raise notice '0303 self-assert ok: the ambush manifest guard counts the manifest (not the insert); guard policy, idempotent freeze and composed chain unchanged';
end
$post$;

commit;
