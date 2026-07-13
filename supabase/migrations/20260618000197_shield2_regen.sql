-- Byeharu — SHIELD-2 (the SHIELD charter, slice 2 of SHIELD-0..2 + ACT-SHIELD): the shield
-- system's FINAL slice — the OUT-OF-COMBAT regen home + the deferred commission
-- base_shield → shield/max_shield copy. (The UI meter pair ships in the same PR, client-side.)
-- Everything is provably INERT while every pool is 0/0 and `shield_regen_idle_pct` is the
-- committed '0' (the 0191 dark seeds — both re-asserted below). ACT-SHIELD (human) stays the only
-- thing that makes any of it move: knobs + the monotonic per-hull backfill + the instance copy.
--
-- ── NUMBERING (coordination, explicit) ────────────────────────────────────────────────────────────
-- 0196 landed as DECKS-3 (merged, PR #141 — it renumbered past SHIELD-1's merged 0195 at its
-- rebase); this file takes 0197, the next free slot on the rebased main. (The recorded
-- choreography every recent slice has followed: 0193 → 0195 → 0196 → here.)
--
-- ── TRUE HEADS (grep over ALL migrations for each create-or-replace; VERIFIED on main today) ─────
--   • process_mainship_expeditions ← 0169:446 — created 0050:234, re-created ONLY at 0169 (D3);
--     every later mention (0170..0195) is a grant carry or a comment. SHIPYARD-2/SOUL-1/SHIELD-1
--     did NOT touch it (re-checked after #136/#139/#140 merged). The body below is the 0169 head
--     VERBATIM — including both D3 CTEs (homed + team_homed) and their race-guard predicates —
--     plus the ONE marked SHIELD-2 hunk (the parity law: everything outside the hunk is
--     byte-identical, extract-and-diff verified).
--   • ensure_main_ship_for_player ← 0193:175 — creates at 0043 → 0077 → 0078 → 0193 (SOUL-1);
--     nothing later. Copied VERBATIM + the ONE marked SHIELD-2 copy hunk (the hull lookup was
--     ALREADY in scope — the 0078-shaped insert selects from main_ship_hull_types, so the copy is
--     two added column refs, the cheapest honest form).
--   • port_entry_commission_build — head ON MAIN is now 0194:82 (0080 → 0184 → 0193 → 0194;
--     SHIPYARD-2 merged as PR #138). 0194 re-signed this function to (uuid, text default
--     'starter_frigate') — the hull-delivery parameter — from the 0193 head. This file carries the
--     MERGED 0194 BODY (extract-and-diff verified byte-for-byte against 0194) + the ONE marked
--     SHIELD-2 copy hunk, so the apply chain 0193 → 0194 → 0196 → 0197 lands every accumulated hunk
--     (0184 name, SOUL-1 hook, SHIPYARD-2 hull param/class-name, SHIELD-2 copy) in the last body.
--     The `drop function if exists` pair below keeps this re-create self-sufficient (both live
--     callers — port_entry_commission_writer 0080 and commission_additional_main_ship 0091,
--     grep-verified the only ones — call single-arg and resolve through the default). The two
--     slices' hunks are disjoint (theirs: signature + hull select + class name; ours: the two
--     insert columns), which is why the reconcile onto merged 0194 was mechanical. ██
--
-- ── THE REGEN HOME (the charter §1.3 decision, recorded) ─────────────────────────────────────────
-- Home = `process_mainship_expeditions` (the 30s reconciler cron, 0050 — asserted still scheduled
-- below). RECOMMENDED over a new cron (no second heartbeat to operate) and over the 3s combat
-- tick (idle regen is a slow out-of-combat trickle; the tick already owns the in-combat half).
-- ONE set-based statement riding the 0191 partial index (`where shield < max_shield` — only
-- damaged shields are candidates; the index matches ZERO rows while everything is 0/0):
--   update ... set shield = least(max_shield, shield + ceil(max_shield × knob)) ...
-- ceil() guarantees progress at any positive knob (a 1-point shield at knob 0.10 still climbs).
--
-- THE DOUBLE-WRITER EXCLUSION PREDICATE (charter §1.3.2, verbatim semantics): while an encounter
-- LIVES (`combat_encounters.status in ('active','retreating')` — the tick's own scan predicate),
-- the 3s tick is the SOLE shield writer for its member ships; outside a live encounter, this
-- reconciler statement is. The predicate is `not exists (a combat_units membership row whose
-- encounter is active/retreating)` — NOT a lock system, just a disjoint-writers partition on the
-- same rows the tick loops. It composes with the D3 race-guard idiom above it (both are
-- exact-complement not-exists predicates over live state). A ship 'hunting' but still OUTBOUND
-- (no encounter yet) regens — it is not in combat; the creator then snapshots whatever pool it
-- arrives with (the 0195 one-read carry). A ship whose encounter just ENDED (escaped/completed/
-- defeat) regens while flying home — out of combat is out of combat. The theoretical interleave
-- (an encounter goes live between this statement's snapshot and its write) is self-correcting:
-- the creator froze its snapshot from the committed pre-statement pool, and the leaf overwrites
-- the instance row from tick truth within 3s — no accounting depends on the instance pool
-- mid-encounter. Access path note: the outer scan is the 0191 partial index; the inner probe
-- joins combat_encounters on its live-status set (the same few rows the tick scans every 3s) —
-- no new index needed at today's scale (recorded; revisit if live encounters ever number in the
-- thousands).
--
-- ZERO-KNOB = ZERO WRITES (the double guard, stated per charter): `least(max, shield + 0)` equals
-- shield — but a SQL UPDATE that assigns a same-value expression STILL fires row writes (new
-- tuple versions, triggers, WAL) on every predicate-matching row. So the statement is guarded
-- `if v_idle > 0 then` — knob '0' (or missing/negative, floored to 0) skips it ENTIRELY:
-- zero reads of the instance table, zero writes, a byte-inert cron pass identical to the 0169
-- head's. The knob is read ONCE per invocation (cfg_num + the C2-2/0180 guard shape + the floor).
-- HONESTY NOTE: the `v_idle_raw <> v_idle_raw` guard mirrors the house NaN-guard SHAPE for parity
-- with 0180/0196, but this x<>x idiom is a NO-OP in PostgreSQL — NaN = NaN is TRUE here, so x<>x is
-- FALSE for NaN and a mis-set 'NaN' knob is NOT caught today (it would even pass `v_idle > 0`). The
-- committed seed '0' keeps that moot; the NANGUARD follow-up fixes all sites to the working
-- `= 'NaN'::float8` idiom.
-- Excluded rows: `status <> 'destroyed'` — a dead hull regenerates nothing (repair is the
-- revival path); the CTEs above never write shields, so the reconciler's pre-existing writes
-- stay byte-identical. The function's RETURN stays `v_count + v_team` — regenerated rows are NOT
-- counted (the envelope is byte-identical to the 0169 head; the cron discards it anyway).
--
-- ── THE COMMISSION COPY (deferred here from 0191/0195 — the recorded scope notes) ────────────────
-- Both creators' enumerated inserts gain `shield, max_shield` := `h.base_shield, h.base_shield` —
-- a new ship is born with a FULL shield (the base_hp/hp analogue: h.base_hp, h.base_hp — same
-- born-whole posture; documented [D]: a fresh hull leaves the yard charged, and ACT-SHIELD's
-- instance backfill uses the same shield=max shape). While every hull's base_shield is 0 (asserted
-- below) the copy writes 0/0 — byte-identical rows to the column defaults it replaces, so this is
-- provably inert on deploy. `ensure_main_ship_for_player` gets the SAME copy even though defaults
-- would carry it (0/0 today): the two creators must stay consistent the day ACT-SHIELD raises
-- base_shield — a legacy-ensure ship born 0/0 beside commission ships born full would be a silent
-- fork (and ensure's hull lookup is already in scope, so the copy costs two column refs).
--
-- ── FAN-OUT (one-directional DOWNWARD, acyclic — the §3 edge law) ────────────────────────────────
-- Reconciler (Main Ship row) → its own instance table (the regen write; NEW: the reconciler joins
-- Combat READ-ONLY for the exclusion predicate — a downward read of encounter liveness, no combat
-- write) · Reference/Config (the knob read). Commission core: unchanged edges (the copy reads the
-- hull row already joined). main_ship_instances.shield now has TWO runtime writers, DISJOINT BY
-- THE EXCLUSION PREDICATE: in-encounter = the tick via mainship_sync_combat_shield (0195);
-- out-of-encounter = this reconciler's ONE set-based statement (the leaf's per-row shape would
-- cost a call per damaged ship on every 30s pass for zero gain — the set statement carries the
-- same least() ceiling inline and can never go below 0 because it only adds; recorded in
-- SYSTEM_BOUNDARIES this same PR). `max_shield` gains its first runtime writers: the two
-- commission creators (insert-time only — never an update path).
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this PR): the main_ship_instances row (shield
-- disjoint-writers law updated; max_shield commission copy), the §2 Main Ship function row.
-- Docs synced: FULL_CAPACITY_PLAN §C P13 (SHIELD-2 shipped; ACT-SHIELD charter lines), DEV_LOG.
-- Proof: the TEAMCMD_PASS_SHIELD2 block in scripts/team-command-proof.{sql,sh} (24th marker —
-- DECKS-3 landed as the 23rd, SHIELD-2 appended as the 24th, the established both-blocks-kept idiom).
--
-- Forward-only: 0001–0196 unedited (0196 landed as DECKS-3, merged — see the numbering note).

-- ── 1) process_mainship_expeditions — 0169:446 body VERBATIM + the marked SHIELD-2 hunk ──────────
create or replace function public.process_mainship_expeditions()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
  v_team  integer;   -- SLICE D3: team-sortie reconcile count (0 on every run until the flag ever flips)
  -- SHIELD-2 (0197): the idle regen knob — read ONCE per invocation (the 0195 hoist law), carrying
  -- the C2-2/0180 NaN-guard SHAPE for parity (the `x <> x` case) — but NOTE that idiom is a NO-OP in
  -- PostgreSQL (NaN = NaN is TRUE, so x<>x is false for NaN; a mis-set 'NaN' is NOT caught — the
  -- NANGUARD follow-up switches all sites to `= 'NaN'::float8`), floored at 0 (a mis-set negative can
  -- never DRAIN shields). '0' (the committed 0191 seed) → v_idle = 0 → the guarded statement below is
  -- SKIPPED ENTIRELY (zero reads, zero writes — see the hunk).
  v_idle_raw double precision := coalesce(cfg_num('shield_regen_idle_pct'), 0);
  v_idle     double precision := greatest(0, case when v_idle_raw <> v_idle_raw then 0 else v_idle_raw end);
begin
  -- A ship that is out (traveling/returning) but has no in-flight tagged fleet has come
  -- home (fleet completed) or lost its fleet → set it home. Idempotent.
  with homed as (
    update main_ship_instances s
      set status = 'home', updated_at = now()
      where s.status in ('traveling','returning')
        and not exists (
          select 1 from fleets f
          where f.main_ship_id = s.main_ship_id
            and f.status in ('moving','present','returning')
        )
        -- SLICE D3: member-only guard — a sortie member marked 'returning' by the tick has NO
        -- main_ship_id-tagged fleet (a team flies ONE untagged fleet), so the head's not-exists is
        -- vacuously true for it; without this guard the branch would yank it 'home' while its
        -- MANIFEST fleet is still flying home. Once that fleet finishes, the guard opens and this
        -- branch re-homes the member with its unchanged legacy write. No legacy ship has manifest
        -- rows → provably false-impact on every row this branch has ever touched (parity law).
        and not exists (
          select 1 from group_sortie_members gsm
          join fleets gf on gf.id = gsm.fleet_id
          where gsm.main_ship_id = s.main_ship_id
            and gf.status in ('moving','present','returning')
        )
      returning 1)
  select count(*) into v_count from homed;

  -- SLICE D3: the team-sortie branch — re-home 'hunting' ships whose MANIFEST fleet is finished
  -- (completed back home / destroyed / deleted). 'hunting' has exactly ONE writer
  -- (send_ship_group_hunt, 0168), so this can never touch a legacy ship. The predicate is the EXACT
  -- COMPLEMENT of "live sortie": a manifest fleet in ('moving','present','returning') — outbound,
  -- MID-COMBAT, or flying home — pins its members untouched. Self-healing by design (belt and
  -- braces against partial states): a 'hunting' ship whose fleet was destroyed but which the D1
  -- defeat loop somehow missed, or whose fleet row was deleted (manifest CASCADEd away → not-exists
  -- vacuously true), comes home rather than staying wedged — the reconciler NEVER destroys a ship
  -- (destruction is combat's verdict alone; a wrongly homed ship is self-correcting, a wrongly
  -- destroyed one is not). Write shape: the head branch's own (status only; spatial_state stays
  -- NULL — the clean legacy_home). Idempotent.
  with team_homed as (
    update main_ship_instances s
      set status = 'home', updated_at = now()
      where s.status = 'hunting'
        and not exists (
          select 1 from group_sortie_members gsm
          join fleets gf on gf.id = gsm.fleet_id
          where gsm.main_ship_id = s.main_ship_id
            and gf.status in ('moving','present','returning')
        )
      returning 1)
  select count(*) into v_team from team_homed;

  -- ── SHIELD-2 (0197) HUNK: the OUT-OF-COMBAT shield regen — the charter's ONE set-based
  --    statement, riding the 0191 partial index (`shield < max_shield` — only damaged shields are
  --    candidates; ZERO rows while everything is 0/0).
  --    DOUBLE-GUARDED: `least(max, shield + 0)` = shield, but a same-value UPDATE still fires row
  --    writes (new tuple versions, WAL) on every matching row — so knob 0 (the committed seed,
  --    incl. missing/negative floored above; a 'NaN' knob is NOT caught — see the header honesty
  --    note on the no-op x<>x shape) skips the statement ENTIRELY: zero reads, zero
  --    writes, a cron pass byte-identical to the 0169 head's. ceil() guarantees progress at any
  --    positive knob; least() owns the ceiling; the statement only ADDS, so the 0-floor is
  --    by construction.
  --    THE EXCLUSION PREDICATE (charter §1.3.2 — a disjoint-writers partition, NOT a second lock
  --    system): while a ship holds a membership row in a LIVE encounter (`status in
  --    ('active','retreating')` — the tick's own scan set), the 3s tick is the SOLE shield writer
  --    (via the 0191 leaf); outside one, this statement is. Historical combat_units rows are
  --    filtered by the encounter-status join — a ship that fought LAST week regens fine.
  --    `status <> 'destroyed'`: a dead hull regenerates nothing (repair is the revival path).
  --    Regenerated rows are NOT counted into the return value (envelope byte-identical to the
  --    0169 head). ─────────────────────────────────────────────────────────────────────────────
  if v_idle > 0 then
    update main_ship_instances s
      set shield = least(s.max_shield, s.shield + ceil(s.max_shield * v_idle)::integer),
          updated_at = now()
      where s.shield < s.max_shield
        and s.status <> 'destroyed'
        and not exists (
          select 1 from combat_units cu
          join combat_encounters ce on ce.id = cu.encounter_id
          where cu.main_ship_id = s.main_ship_id
            and ce.status in ('active','retreating')
        );
  end if;
  -- ── END SHIELD-2 (0197) HUNK ───────────────────────────────────────────────────────────────────

  return v_count + v_team;
end;
$$;

-- ── 2) port_entry_commission_build — the 0194 body (see the collision note) + the marked copy hunk ─
-- Order-robust re-signing: if SHIPYARD-2's 0194 already applied, the (uuid) drop no-ops and the
-- create-or-replace swaps the (uuid, text) body in place (grants preserved — but re-asserted below
-- anyway, belt and braces); if it has NOT, the (uuid) drop removes the 0193 head and the create
-- installs the two-arg re-signing (byte-inert through the default — the header's argument).
drop function if exists public.port_entry_commission_build(uuid);
create or replace function public.port_entry_commission_build(
  p_player       uuid,
  p_hull_type_id text default 'starter_frigate'   -- SHIPYARD-2 (0194): the hull parameter; default = the exact 0193 behavior
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c_haven  constant uuid := 'b1a00001-0066-4a00-8a00-000000000001';
  v_ship   uuid;
  v_zone   uuid;
  v_sector uuid;
  v_base   uuid;
  v_fleet  uuid;
begin
  -- Insert the ship DIRECTLY in canonical at_location shape (status='stationary',
  -- spatial_state='at_location', x/y NULL) so there is never a committed intermediate bare
  -- home/legacy_home row. No on-conflict: the CALLER already serialized + checked existence/cap.
  insert into public.main_ship_instances
    (player_id, hull_type_id, name, status, spatial_state, space_x, space_y,
     hp, max_hp, cargo_capacity, cargo_capacity_m3, support_capacity, captain_slots, module_slots,
     shield, max_shield)   -- SHIELD-2 (0197): the deferred commission copy (the 0043:81 base_hp analogue)
  select p_player, h.hull_type_id,
         -- [0184 NAME HUNK, generalized by SHIPYARD-2 (0194)] EVE-style default: the class name +
         -- a per-player roman numeral from the SECOND ship on. The class-name SOURCE is the only
         -- 0194 delta: the starter keeps the exact 0184 'Sparrow' literal (byte-inert through the
         -- default parameter); any other hull rides its catalog display name (h.name), the
         -- numeral still counting ALL of the player's ships ACROSS classes — a player whose
         -- third ship is their first Mule gets 'Mule-class Hauler III' (the 0184
         -- per-player-ordinal law, NOT a per-class counter) — exactly as the 0184 header
         -- pre-recorded: "when multi-hull commissioning lands, the class name should ride the
         -- hull row". Safe: every caller holds the per-player commission advisory lock before build.
         (case when p_hull_type_id = 'starter_frigate' then 'Sparrow' else h.name end)
           || (select case when count(*) = 0 then ''
                           else ' ' || to_char(count(*) + 1, 'FMRN') end
                 from public.main_ship_instances m where m.player_id = p_player),
         'stationary', 'at_location', null, null,
         h.base_hp, h.base_hp, h.base_cargo_capacity, h.base_cargo_capacity_m3, h.base_support_capacity, h.base_captain_slots, h.base_module_slots,
         -- SHIELD-2 (0197) HUNK: born FULL — shield := base_shield AND max_shield := base_shield
         -- (the h.base_hp, h.base_hp posture above, mirrored: a fresh hull leaves the yard
         -- charged [D]; ACT-SHIELD's instance backfill uses the same shield=max shape). While
         -- every hull's base_shield is 0 (migration-asserted) this writes 0/0 — byte-identical
         -- to the column defaults it replaces (provably inert on deploy). shield <= max_shield
         -- holds by construction (equal).
         h.base_shield, h.base_shield
         -- END SHIELD-2 (0197) HUNK
    from public.main_ship_hull_types h
    where h.hull_type_id = p_hull_type_id   -- SHIPYARD-2 (0194): was the 'starter_frigate' literal
  returning main_ship_id into v_ship;

  if v_ship is null then
    return jsonb_build_object('created', false);     -- hull row missing / nothing inserted
  end if;

  -- SOUL-1 (0193) HOOK: every new ship is born with its soul WHEN LIT (P12). Double-gated — the
  -- gate is checked HERE (dark = ZERO calls, byte-parity with the 0184 head) AND the roll fn
  -- gates first itself (0186). Definer-to-definer (the 0169 leaf-call pattern): this SECURITY
  -- DEFINER body executes as the function owner, which may execute the service_role-only roll
  -- writer. Deterministic + idempotent (0186) — a re-fired hook can never re-roll or re-raise hp;
  -- the envelope is discarded (failure codes impossible-by-construction here; a mid-txn config
  -- race fails CLOSED to dark and stays re-runnable). hp_mult lands here, once, via the roll.
  -- [Carried VERBATIM from the 0193 head by SHIPYARD-2 (0194) — a DELIVERED hull passes through
  -- this same hook, so built ships are born with souls when lit too.]
  if public.cfg_bool('ship_traits_enabled') then
    perform public.soul_roll_traits_for_ship(v_ship);
  end if;
  -- END SOUL-1 (0193) hook — everything below is the 0184 head, byte-identical.

  -- ── Phase B: lock the Haven Reach target hierarchy in the canonical order (sector → zone → location →
  --    anchor → docking service, FOR SHARE — conflicts with a status disable/retire) and REVALIDATE legality
  --    through the single canonical rule AFTER the locks are held, immediately before the fleet/presence write.
  select l.zone_id, z.sector_id into v_zone, v_sector
    from public.locations l join public.zones z on z.id = l.zone_id
    where l.id = c_haven;
  if v_zone is null then
    raise exception 'port_entry_commission: Haven Reach location not found';
  end if;
  perform 1 from public.sectors           where id = v_sector for share;
  perform 1 from public.zones             where id = v_zone   for share;
  perform 1 from public.locations         where id = c_haven  for share;
  perform 1 from public.space_anchors     where location_id = c_haven and kind = 'location' and status = 'active' for share;
  perform 1 from public.location_services where location_id = c_haven and service = 'docking' and status = 'active' for share;

  if (public.mainship_space_location_target_legal(c_haven)->>'ok')::boolean is not true then
    raise exception 'port_entry_commission: Haven Reach is not dockable';   -- rolls back the ship insert (atomic)
  end if;

  -- exactly ONE present/location fleet at Haven (origin_base_id = the player's base if one exists, else NULL —
  -- NOT a home-port assignment; current_base_id stays NULL, matching a docked OSN fleet).
  select id into v_base from public.bases where player_id = p_player and status = 'active' order by created_at limit 1;
  v_fleet := gen_random_uuid();
  insert into public.fleets
    (id, player_id, origin_base_id, status, location_mode, current_base_id,
     current_location_id, current_zone_id, current_sector_id, main_ship_id)
  values (v_fleet, p_player, v_base, 'present', 'location', null,
          c_haven, v_zone, v_sector, v_ship);

  -- exactly ONE active presence through the established presence path (activity 'none', like the dock writer).
  perform public.presence_create(p_player, v_fleet, v_sector, v_zone, c_haven, 'none');

  -- final coherence gate: the ship MUST now be canonical at_location, else abort the whole transaction.
  if (public.mainship_space_validate_context(v_ship)->>'state') is distinct from 'at_location' then
    raise exception 'port_entry_commission: post-write state is not canonical at_location';
  end if;

  return jsonb_build_object('created', true, 'main_ship_id', v_ship, 'location_id', c_haven);
end;
$$;

-- the re-signed commission core stays OFF the client surface (the 0080 posture; re-asserted
-- explicitly because the (uuid, text) function may be freshly created on a 0193-headed chain —
-- the 0064-era default-privileges revoke already denies it, this makes the intent audit-visible):
revoke execute on function public.port_entry_commission_build(uuid, text) from public, anon, authenticated;
grant  execute on function public.port_entry_commission_build(uuid, text) to service_role;

-- ── 3) ensure_main_ship_for_player — 0193:175 body VERBATIM + the marked copy hunk ───────────────
create or replace function public.ensure_main_ship_for_player(p_player uuid)
returns public.main_ship_instances
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ship public.main_ship_instances%rowtype;
  -- SOUL-1 (0193): the just-created ship id, captured so the gated roll hook fires ONLY on the
  -- create branch (an existing ship's idempotent replay must NEVER roll here — the retroactive
  -- roll over pre-existing ships is ACT-SOUL's, behind the catalog-freeze precondition).
  v_new  uuid;
begin
  -- Race-safe first-ship serialization per player (replaces the `on conflict (player_id)` guard so it is
  -- correct with OR without the player_id UNIQUE index): hold the per-player commission lock, then create
  -- ONLY if the player has zero ships. Never creates a 2nd ship implicitly.
  perform pg_advisory_xact_lock(hashtext('main_ship_commission'), hashtext(p_player::text));
  if not exists (select 1 from main_ship_instances where player_id = p_player) then
    insert into main_ship_instances
      (player_id, hull_type_id, hp, max_hp, cargo_capacity, cargo_capacity_m3, support_capacity, captain_slots, module_slots,
       shield, max_shield)   -- SHIELD-2 (0197): the same commission copy as build's (creator consistency)
    select p_player, h.hull_type_id, h.base_hp, h.base_hp, h.base_cargo_capacity, h.base_cargo_capacity_m3,
           h.base_support_capacity, h.base_captain_slots, h.base_module_slots,
           -- SHIELD-2 (0197) HUNK: born FULL, exactly as the build core above. The hull lookup
           -- was ALREADY in scope (the 0078-shaped insert selects from the hull row), so the copy
           -- is two added column refs — the cheapest honest form. Defaults would carry 0/0 today,
           -- but the two creators must stay consistent the day ACT-SHIELD raises base_shield (a
           -- legacy-ensure ship born 0/0 beside commission ships born full would be a silent fork).
           h.base_shield, h.base_shield
           -- END SHIELD-2 (0197) HUNK
      from main_ship_hull_types h
      where h.hull_type_id = 'starter_frigate'
    returning main_ship_id into v_new;   -- SOUL-1 (0193): capture for the hook (was a bare insert)

    -- SOUL-1 (0193) HOOK: starter ships get souls too (P12: "every new ship is born with its
    -- soul" — a starter Sparrow deserves one). Same double-gated, definer-to-definer, discard-
    -- envelope shape as the port_entry_commission_build hook above; fires ONLY when THIS call
    -- created the ship (v_new not null — the create branch). NESTED ifs, not AND: PG does not
    -- guarantee AND evaluation order, so the gate read must sit provably INSIDE the
    -- create-branch check — the replay path takes ZERO added reads.
    if v_new is not null then
      if public.cfg_bool('ship_traits_enabled') then
        perform public.soul_roll_traits_for_ship(v_new);
      end if;
    end if;
    -- END SOUL-1 (0193) hook — everything else is the 0078 head, byte-identical.
  end if;

  select * into v_ship from main_ship_instances where player_id = p_player;
  return v_ship;
end;
$$;

-- ── 4) Execute surface ────────────────────────────────────────────────────────────────────────────
-- process_mainship_expeditions and ensure_main_ship_for_player are CREATE OR REPLACE on EXISTING
-- functions, which PRESERVES owner and grants (both server-only; carried unchanged — asserted
-- below). port_entry_commission_build's ACL is re-asserted above beside its create (it may be a
-- fresh (uuid, text) object on a 0193-headed chain). No blanket re-lock (the D1 §7 rationale:
-- that idiom belongs to migrations adding NEW client RPCs).

-- ── 5) SELF-ASSERTS — the migration proves its own parity/inertness or refuses to land ───────────
do $$
declare
  v_rec  text;
  v_src  text;
  v_args text;
  v_tok  text;
  v_n    integer;
  v_val  text;
begin
  -- (1) DEPLOY-TIME INERTNESS: the idle knob is still the committed '0'; every hull base_shield
  --     is 0 (the commission copy writes 0/0 — byte-identical to the defaults it replaces);
  --     every instance is 0/0 (nothing for the regen statement to ever match).
  select value #>> '{}' into v_val from public.game_config where key = 'shield_regen_idle_pct';
  if v_val is distinct from '0' then
    raise exception 'SHIELD-2 self-assert FAIL: shield_regen_idle_pct is % (must land with the dark seed ''0'')', coalesce(v_val, '<missing>');
  end if;
  select count(*) into v_n from public.main_ship_hull_types where base_shield <> 0;
  if v_n <> 0 then
    raise exception 'SHIELD-2 self-assert FAIL: % hull row(s) carry base_shield <> 0 at apply time (the copy must land inert)', v_n;
  end if;
  select count(*) into v_n from public.main_ship_instances where shield <> 0 or max_shield <> 0;
  if v_n <> 0 then
    raise exception 'SHIELD-2 self-assert FAIL: % instance row(s) off shield 0/0 at apply time (want 0)', v_n;
  end if;

  -- (2) RECONCILER — the marked hunk is present with its exact shape…
  select prosrc into v_rec from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'process_mainship_expeditions';
  if v_rec is null then raise exception 'SHIELD-2 self-assert FAIL: process_mainship_expeditions not deployed'; end if;
  foreach v_tok in array array[
    'v_idle_raw double precision := coalesce(cfg_num(''shield_regen_idle_pct''), 0);',
    'case when v_idle_raw <> v_idle_raw then 0 else v_idle_raw end',
    'if v_idle > 0 then',
    'set shield = least(s.max_shield, s.shield + ceil(s.max_shield * v_idle)::integer)',
    's.shield < s.max_shield',
    's.status <> ''destroyed''',
    'ce.status in (''active'',''retreating'')'] loop
    if strpos(v_rec, v_tok) = 0 then
      raise exception 'SHIELD-2 self-assert FAIL: reconciler missing token ''%'' (regen hunk / NaN-guard shape / exclusion breach)', v_tok;
    end if;
  end loop;
  --   …the knob is read exactly ONCE (the hoist law)…
  v_n := (length(v_rec) - length(replace(v_rec, 'cfg_num(''shield_regen_idle_pct'')', '')))
         / length('cfg_num(''shield_regen_idle_pct'')');
  if v_n <> 1 then
    raise exception 'SHIELD-2 self-assert FAIL: shield_regen_idle_pct read % times (want exactly 1)', v_n;
  end if;
  --   …the zero-writes guard appears before the statement (guard token strictly BEFORE the update)…
  if strpos(v_rec, 'if v_idle > 0 then') > strpos(v_rec, 'set shield = least(s.max_shield') then
    raise exception 'SHIELD-2 self-assert FAIL: the regen statement is not inside the v_idle > 0 guard (zero-knob must mean zero writes)';
  end if;
  --   …the 0169 head is byte-intact around it: both D3 CTEs, BOTH race-guard predicates, the
  --   legacy write shape, and the unchanged envelope…
  foreach v_tok in array array[
    'with homed as (',
    'with team_homed as (',
    's.status in (''traveling'',''returning'')',
    's.status = ''hunting''',
    'return v_count + v_team;'] loop
    if strpos(v_rec, v_tok) = 0 then
      raise exception 'SHIELD-2 self-assert FAIL: reconciler lost 0169-head token ''%'' (parity breach)', v_tok;
    end if;
  end loop;
  v_n := (length(v_rec) - length(replace(v_rec, 'gf.status in (''moving'',''present'',''returning'')', '')))
         / length('gf.status in (''moving'',''present'',''returning'')');
  if v_n <> 2 then
    raise exception 'SHIELD-2 self-assert FAIL: % D3 manifest race-guard predicates (want exactly the head''s 2)', v_n;
  end if;
  --   …and no session RNG entered (0041).
  if strpos(v_rec, 'random(') <> 0 or strpos(v_rec, 'setseed') <> 0 then
    raise exception 'SHIELD-2 self-assert FAIL: reconciler body carries session RNG (0041 determinism breach)';
  end if;

  -- (3) THE REGEN HOME IS SCHEDULED: exactly one 'process-mainship-expeditions' cron job (0050 —
  --     the 30s reconciler this slice rides; a second job would double the regen cadence).
  select count(*) into v_n from cron.job where jobname = 'process-mainship-expeditions';
  if v_n <> 1 then
    raise exception 'SHIELD-2 self-assert FAIL: % process-mainship-expeditions cron job(s) (want exactly 1)', v_n;
  end if;

  -- (4) COMMISSION CORE — the old (uuid) signature is GONE (single-arg calls stay unambiguous),
  --     the (uuid, text) resolves with the starter default…
  if to_regprocedure('public.port_entry_commission_build(uuid)') is not null then
    raise exception 'SHIELD-2 self-assert FAIL: the old port_entry_commission_build(uuid) still exists (single-arg calls would be ambiguous)';
  end if;
  if to_regprocedure('public.port_entry_commission_build(uuid, text)') is null then
    raise exception 'SHIELD-2 self-assert FAIL: port_entry_commission_build(uuid, text) not deployed';
  end if;
  select pg_get_function_arguments('public.port_entry_commission_build(uuid, text)'::regprocedure) into v_args;
  if strpos(v_args, 'DEFAULT ''starter_frigate''::text') = 0 then
    raise exception 'SHIELD-2 self-assert FAIL: the hull parameter default is not ''starter_frigate'' (got: %)', v_args;
  end if;
  --   …every accumulated hunk is aboard: the 0184 name idiom, the 0194 class-name/hull-param
  --   hunks, the SOUL-1 gated hook (exactly once, gate BEFORE the call), the UNMOVED sanctioned
  --   fleets insert, and the SHIELD-2 copy…
  select prosrc into v_src from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'port_entry_commission_build';
  foreach v_tok in array array[
    '''Sparrow''', 'else h.name end', 'h.hull_type_id = p_hull_type_id',
    'to_char(count(*) + 1, ''FMRN'')',
    'insert into public.fleets', 'presence_create',
    'if public.cfg_bool(''ship_traits_enabled'') then',
    'shield, max_shield)',
    'h.base_shield, h.base_shield'] loop
    if strpos(v_src, v_tok) = 0 then
      raise exception 'SHIELD-2 self-assert FAIL: port_entry_commission_build missing token ''%'' (an accumulated hunk was dropped)', v_tok;
    end if;
  end loop;
  v_tok := 'perform public.soul_roll_traits_for_ship(';
  v_n := (length(v_src) - length(replace(v_src, v_tok, ''))) / length(v_tok);
  if v_n <> 1 then
    raise exception 'SHIELD-2 self-assert FAIL: build carries % SOUL-1 roll-hook call site(s) (want exactly 1)', v_n;
  end if;
  if strpos(v_src, 'if public.cfg_bool(''ship_traits_enabled'') then') > strpos(v_src, v_tok) then
    raise exception 'SHIELD-2 self-assert FAIL: the SOUL-1 roll call is not behind its ship_traits_enabled gate';
  end if;
  --   …the copy sits INSIDE the ship insert (both tokens before the RETURNING of the insert) —
  --   shield and max_shield are written at BIRTH, never by a later update path in this body.
  if strpos(v_src, 'h.base_shield, h.base_shield') > strpos(v_src, 'returning main_ship_id into v_ship') then
    raise exception 'SHIELD-2 self-assert FAIL: the commission copy is not inside the ship insert';
  end if;
  --   …and both 0184-era callers still delegate single-arg (they ride the starter default).
  select prosrc into v_src from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'port_entry_commission_writer';
  if v_src is null or strpos(v_src, 'port_entry_commission_build(p_player)') = 0 then
    raise exception 'SHIELD-2 self-assert FAIL: port_entry_commission_writer no longer delegates single-arg';
  end if;
  select prosrc into v_src from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'commission_additional_main_ship';
  if v_src is null or strpos(v_src, 'port_entry_commission_build(v_player)') = 0 then
    raise exception 'SHIELD-2 self-assert FAIL: commission_additional_main_ship no longer delegates single-arg';
  end if;

  -- (5) ENSURE — the copy hunk landed inside ITS insert, the SOUL-1 create-branch hook and the
  --     commission lock survived (0193-head parity).
  select prosrc into v_src from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'ensure_main_ship_for_player';
  if v_src is null then raise exception 'SHIELD-2 self-assert FAIL: ensure_main_ship_for_player not deployed'; end if;
  foreach v_tok in array array[
    'pg_advisory_xact_lock(hashtext(''main_ship_commission'')',
    'shield, max_shield)',
    'h.base_shield, h.base_shield',
    'returning main_ship_id into v_new',
    'if v_new is not null then',
    'if public.cfg_bool(''ship_traits_enabled'') then'] loop
    if strpos(v_src, v_tok) = 0 then
      raise exception 'SHIELD-2 self-assert FAIL: ensure_main_ship_for_player missing token ''%''', v_tok;
    end if;
  end loop;

  -- (6) determinism (the 0041 law): no random() in any body this migration re-created.
  select count(*) into v_n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public'
      and p.proname in ('process_mainship_expeditions', 'port_entry_commission_build', 'ensure_main_ship_for_player')
      and strpos(p.prosrc, 'random()') <> 0;
  if v_n <> 0 then
    raise exception 'SHIELD-2 self-assert FAIL: % re-created body(ies) call random() (0041)', v_n;
  end if;

  -- (7) ACL posture: the commission core + the reconciler are OFF the client surface;
  --     service_role keeps both (the cron/CI surface).
  if has_function_privilege('authenticated', 'public.port_entry_commission_build(uuid, text)', 'execute')
     or has_function_privilege('anon', 'public.port_entry_commission_build(uuid, text)', 'execute') then
    raise exception 'SHIELD-2 self-assert FAIL: the commission core is client-executable';
  end if;
  if not has_function_privilege('service_role', 'public.port_entry_commission_build(uuid, text)', 'execute') then
    raise exception 'SHIELD-2 self-assert FAIL: service_role cannot execute the commission core';
  end if;
  if has_function_privilege('authenticated', 'public.process_mainship_expeditions()', 'execute')
     or has_function_privilege('anon', 'public.process_mainship_expeditions()', 'execute') then
    raise exception 'SHIELD-2 self-assert FAIL: the reconciler is client-executable';
  end if;
  if not has_function_privilege('service_role', 'public.process_mainship_expeditions()', 'execute') then
    raise exception 'SHIELD-2 self-assert FAIL: service_role cannot execute the reconciler (the cron/CI surface)';
  end if;

  -- (8) BEHAVIORAL SMOKE (safe on any database, incl. an empty CI chain): one live reconciler
  --     pass with the knob at its committed '0' moves NO shield (the double guard skips the
  --     statement entirely; the pass itself is the same call the 30s cron makes — idempotent).
  perform public.process_mainship_expeditions();
  select count(*) into v_n from public.main_ship_instances where shield <> 0;
  if v_n <> 0 then
    raise exception 'SHIELD-2 self-assert FAIL: a knob-0 reconciler pass moved % shield row(s) (want 0 — zero-knob = zero writes)', v_n;
  end if;

  raise notice 'SHIELD-2 self-assert ok: idle knob ''0'' + every hull/instance at 0 (deploy-inert); reconciler carries the guarded set-based regen hunk (one hoisted floored knob read behind the house NaN-guard SHAPE — a documented no-op today, NANGUARD follow-up pending; ceil climb capped by least; destroyed excluded; the active/retreating encounter-membership exclusion predicate) with both D3 CTEs + race guards byte-intact and the envelope unchanged; exactly 1 reconciler cron job; commission core re-signed (old (uuid) gone, starter default, Sparrow + h.name + FMRN numeral + SOUL-1 gated hook exactly once + fleets insert unmoved + the born-full copy inside the insert) with both callers still single-arg; ensure carries the same copy + its create-branch hook + the commission lock; determinism; ACLs server-only; knob-0 smoke pass moved nothing';
end $$;
