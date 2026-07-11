-- Byeharu — TEAM-COMMAND Slice D2: the team enters the combat engine — hunt send + sortie manifest +
-- encounter routing (DARK).
--
-- ── WHAT THIS IS ────────────────────────────────────────────────────────────────────────────────────
-- The FIRST writer of member combat_units rows (the writer D1 explicitly deferred). Three pieces:
--   (1) group_sortie_members — the team's fleet_units analogue: the membership SNAPSHOT frozen at send.
--   (2) send_ship_group_hunt — the combat twin of B-send (0163), composed from the 0050 'narrow bridge'
--       spine primitives (the live single send hard-rejects combat destinations at 0050:104/0152:116,
--       and one-fleet-per-ship is the wrong shape for ONE team encounter — a team fights as ONE fleet).
--   (3) encounter routing — combat_create_encounter (head 0023) re-created with ONE up-front
--       manifest-gated branch into the new combat_create_group_encounter (member combat_units writer).
--
-- ── TERMINOLOGY: "group" (this file/DB/code) == "team" (UI). See docs/TEAM_COMMAND.md. ────────────────
--
-- ── THE MANIFEST-WINS LAW ───────────────────────────────────────────────────────────────────────────
-- From send until return, group_sortie_members IS the sortie's membership truth. Live group membership
-- (main_ship_instances.group_id) can change mid-flight (unassign, delete_ship_group → SET NULL) — the
-- sortie must NOT orphan: encounter routing and member-stat snapshots key on the MANIFEST, never on
-- live membership and never on the informational fleets.group_id below. The sole writer of the manifest
-- is send_ship_group_hunt (this migration); rows die with their fleet (ON DELETE CASCADE).
--
-- ── ANTI-SPAGHETTI (the roadmap law, audited) ──────────────────────────────────────────────────────
--   #1 combat: the team resolves into the EXISTING combat_units input (the D1-widened member shape) —
--      combat_create_group_encounter writes SNAPSHOT INPUTS ONLY (attack/defense/hp); ZERO wave or
--      damage math lives here (the second-engine tripwire). The one tick engine (process_combat_ticks,
--      D1) consumes the rows unchanged.
--   #2 movement: the fleets spine is REUSED — one direct fleets insert (the exact 0050:133-135 /
--      0152:135-137 narrow-bridge shape), movement_create, fleet_set_moving; the settle chain
--      (movement_settle_arrival → fleet_set_present → presence_create → activity_start) is untouched
--      and routes the arrival into combat exactly as a legacy hunt fleet's does (the location's
--      activity_type='hunt_pirates' drives presence_create, 0151:71).
--   #3 group-shaped RPC (send_ship_group_hunt(p_group_id, …)); the live single send is NOT widened.
--   #4 one selection source: backend-only, no client UI (that is D4).
--
-- ── DARK / GATE ────────────────────────────────────────────────────────────────────────────────────
-- send_ship_group_hunt rejects-before-read on cfg_bool('team_command_enabled') (seeded FALSE in 0160)
-- BEFORE any group/ship/location read — the 0161/0163/0164/0165/0166 posture. No flag flipped, no
-- game_config write. In prod every call returns team_command_disabled → NO manifest row can exist →
-- the re-created combat_create_encounter's member branch is UNREACHABLE (same parity discipline as D1).
--
-- ── CONCURRENCY / LOCK ORDER (the 0163 + 0164 lessons combined) ────────────────────────────────────
--   • Group FOR SHARE + revalidate (serializes vs delete_ship_group's FOR UPDATE) → member ships
--     FOR UPDATE — the EXACT 0163 group-then-ships order (matches assign/delete → no deadlock cycle).
--   • Member readiness (EVERY member status='home' AND hp>0 — all-or-nothing, the 0163 posture) is
--     checked UNDER the ship locks. HONEST SCOPE: this closes LOCKING racers only — a concurrent
--     team-send / assign / delete blocks on these ship/group locks, re-reads, and is observed. The
--     LIVE single send takes NO ship lock and writes ship status UNCONDITIONALLY (plain read
--     0050:87-94 / 0152:100-107, unconditional UPDATE 0050:146-147 / 0152:150), so a single send that
--     read 'home' before our commit can still overwrite 'hunting' → 'traveling' afterwards (a lost
--     update). That is M1 — an ACTIVATION BLOCKER, fixed in D3 by re-creating the single send's ship
--     write with `and status='home'` + FOUND (a live-function edit, out of D2's charter). A SEQUENTIAL
--     single send already rejects a 'hunting' member (0152:105-107). See docs/TEAM_COMMAND.md.
--   • NO movement-row lock anywhere (the 0164 B-stop lesson): the settle cron locks movement→ship
--     (0151 scan then fleet/ship writes); this RPC takes ship locks but NEVER a fleet_movements lock,
--     so no ship→movement inversion and no cycle with the cron. (The fleets insert + movement_create
--     touch only brand-new rows nobody else can hold.)
--   • One live sortie per ship is enforced BEHAVIORALLY, not by index: "live" is fleets.status
--     ('moving'/'present'/'returning'), a DIFFERENT table — a partial unique index on
--     group_sortie_members cannot reference it (index predicates are single-table). The sole writer's
--     under-lock status='home' check is the guarantee: joining a sortie sets status='hunting' in the
--     SAME transaction that writes the manifest row, and only the (D3) return path will ever set it
--     home again, so a second live manifest row for the same ship is unreachable through the sole
--     writer.
--
-- ── request_id / dedup ─────────────────────────────────────────────────────────────────────────────
-- B-send (0163) takes NO p_request_id (its idempotency is the status='home' state check) — mirrored
-- here exactly: the under-lock home re-check makes a duplicate call reject member_not_ready.
--
-- Touches NO existing signature except combat_create_encounter (re-created from its TRUE head 0023:69 —
-- grep-verified: 0017 → 0022 → 0023, nothing later — with the ONE marked branch; everything else
-- byte-identical, diff-verified). NO frozen verifier, NO game_config write, NO cron change, NO frontend.

-- ── 1) group_sortie_members: the sortie's membership SNAPSHOT (sole writer: send_ship_group_hunt) ────
-- The team's fleet_units analogue. fleet_id → fleets(id) (PK 'id', 0006) ON DELETE CASCADE: manifest
-- rows are meaningless without their fleet and die with it. main_ship_id → main_ship_instances
-- ON DELETE CASCADE (the D1 combat_units rationale: keeps a whole-account deletion — auth.users
-- cascading into BOTH fleets and main_ship_instances — order-independent). player_id → auth.users
-- ON DELETE CASCADE (the ship_groups/fleet_movements referenced-users pattern, 0160/0007).
-- SOLE WRITER: send_ship_group_hunt (below). Nothing else — no client write, no other RPC, no cron —
-- may insert/update/delete these rows (the proof harness's selftest greps enforce the convention).
create table public.group_sortie_members (
  fleet_id     uuid not null references public.fleets (id) on delete cascade,
  main_ship_id uuid not null references public.main_ship_instances (main_ship_id) on delete cascade,
  player_id    uuid not null references auth.users (id) on delete cascade,
  created_at   timestamptz not null default now(),
  primary key (fleet_id, main_ship_id)
);
-- PK covers fleet-keyed routing reads; these cover ship-keyed liveness probes + owner-RLS scans.
create index group_sortie_members_ship_idx   on public.group_sortie_members (main_ship_id);
create index group_sortie_members_player_idx on public.group_sortie_members (player_id);

-- Owner-select RLS (the ship_groups 0160 style verbatim): read-only to the owner, no client write path.
alter table public.group_sortie_members enable row level security;
create policy "group_sortie_members_select_own" on public.group_sortie_members
  for select using (player_id = auth.uid());
grant select on public.group_sortie_members to authenticated;

comment on table public.group_sortie_members is
  'Slice D2: membership SNAPSHOT of a team hunt sortie, frozen at send. THE routing truth from send '
  'until return (manifest-wins law — never live group membership). Sole writer: send_ship_group_hunt.';

-- ── 2) fleets.group_id — INFORMATIONAL team tag (display only; ROUTING NEVER reads it) ───────────────
-- Nullable → ship_groups(group_id) (PK, 0160) ON DELETE SET NULL: deleting a team mid-flight merely
-- unlabels the fleet — the sortie keeps flying on its manifest. Every consumer that must know "is this
-- a team sortie / who is in it" keys on group_sortie_members; this column exists ONLY so displays can
-- label the fleet with its team. Mirrors the fleets.main_ship_id tag idiom (0050:39-43).
alter table public.fleets
  add column group_id uuid references public.ship_groups (group_id) on delete set null;
create index fleets_group_id_idx on public.fleets (group_id) where group_id is not null;
comment on column public.fleets.group_id is
  'Slice D2: informational team label ONLY (display). ROUTING NEVER reads it — encounter routing and '
  'member snapshots key on group_sortie_members (the manifest-wins law).';

-- ── 3) send_ship_group_hunt — the combat twin of B-send over the 0050 narrow bridge ──────────────────
-- Reject order (envelopes; gate FIRST, before any read):
--   not_authenticated → team_command_disabled → group_not_found (mainship_resolve_owned_group,
--   explicit-only, fail closed) → empty_group → invalid_location (status='active' AND
--   activity_type='hunt_pirates' — the combat destination the live single send hard-rejects) →
--   member_not_ready (EVERY member status='home' AND hp>0, checked UNDER the ship locks —
--   all-or-nothing, the 0163 posture; the hp>0 guard rejects a schema-legal zero-hp 'home' ship,
--   which the D1 hp sync can produce, before it can ever reach the encounter creator; also returned
--   when the gather→lock window lost a member row) → fleet_limit_reached (count vs cfg
--   max_active_fleets, the 0019:46-51/0050:108-114 idiom — the team is ONE fleet) →
--   power_below_required (Σ member combat_power vs locations.min_power_required — the 0019:60-63
--   check semantics; the sum is the per-member adapter fold below, identical to D0's additive law) →
--   ok.
--   ADAPTATIONS beyond the vocabulary above (both fail closed, both documented):
--   stats_invalid — the per-ship adapter (0122) RAISES on an illegal member state (refuse-don't-clamp
--   law); folded into the ONE opaque envelope exactly as get_my_group_expedition_totals does (0166).
--   no_home_base — the 0050 origin anchor is missing (unreachable for real players: signup creates
--   the base); an envelope, never a raw 500.
create or replace function public.send_ship_group_hunt(p_group_id uuid, p_location uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_group    uuid;
  v_members  uuid[];
  v_locked   integer;
  v_not_home integer;
  v_loc      record;
  v_max      integer;
  v_active   integer;
  v_base     record;
  v_ship     uuid;
  v_stats    jsonb;
  v_ms       double precision;
  v_power    double precision;
  v_speed    double precision;
  v_fleet    uuid;
  v_movement uuid;
  v_arrive   timestamptz;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK gate FIRST — before any group/ship/location read (identical answer regardless of input; no
  -- existence oracle). The 0161/0163/0164/0165/0166 posture verbatim.
  if not public.cfg_bool('team_command_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'team_command_disabled');
  end if;

  -- Resolve the owned group (explicit-only; null/non-owned/nonexistent → null → fail closed).
  v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
  if v_group is null then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  -- Lock the group row FOR SHARE, then revalidate under the lock (serializes vs delete's FOR UPDATE;
  -- if a delete won the resolve→lock window we lock zero rows and fail closed). The 0163 idiom.
  perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for share;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  -- Gather the team's ships (owner- AND group-scoped), deterministic order — the 0163/0166 member query.
  select coalesce(array_agg(main_ship_id order by created_at), '{}')
    into v_members
    from public.main_ship_instances
   where group_id = v_group and player_id = v_player;
  if array_length(v_members, 1) is null then
    return jsonb_build_object('ok', false, 'reason', 'empty_group');
  end if;

  -- Destination must exist, be active, and be a COMBAT hunt zone — the exact predicate the settle
  -- chain routes into combat_create_encounter (locations.activity_type drives presence_create).
  -- min_power_required rides along for the power check below (the 0019:35-44 read shape).
  select l.id, l.x, l.y, l.activity_type, l.status, l.zone_id, l.min_power_required, z.sector_id
    into v_loc
    from locations l join zones z on z.id = l.zone_id
    where l.id = p_location;
  if v_loc.id is null or v_loc.status <> 'active' or v_loc.activity_type is distinct from 'hunt_pirates' then
    return jsonb_build_object('ok', false, 'reason', 'invalid_location');
  end if;

  -- Lock the member ship rows FOR UPDATE (ships AFTER group — the exact 0163 lock order; no movement
  -- row is ever locked here, see header). The locked count must equal the gathered count: a member
  -- row that vanished in the gather→lock window (account deletion — group ops never delete ships)
  -- would otherwise FK-500 the manifest insert below; envelope it instead (fail closed).
  select count(*) into v_locked from (
    select main_ship_id from public.main_ship_instances
     where main_ship_id = any(v_members) and player_id = v_player
     for update
  ) locked;
  if v_locked <> array_length(v_members, 1) then
    return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
  end if;

  -- Readiness UNDER the locks: EVERY member must be status='home' (all-or-nothing, the 0163 posture)
  -- AND hp > 0 — a zero-hp 'home' ship is schema-legal (the D1 tick's hp sync writes 0 on a member
  -- that died while its team escaped; only repair raises it) and must never join a new sortie: the
  -- encounter creator degrades it defensively at arrival, but the common path rejects HERE, cheaply.
  -- Race scope of this check: LOCKING racers only — the live single send's lost-update window is M1
  -- (header + docs/TEAM_COMMAND.md), an activation blocker fixed in D3.
  select count(*) into v_not_home
    from public.main_ship_instances
    where main_ship_id = any(v_members) and (status <> 'home' or hp <= 0);
  if v_not_home > 0 then
    return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
  end if;

  -- Active-fleet limit (shared budget with old fleets, by design — the 0019/0050 idiom verbatim).
  -- The whole team consumes exactly ONE fleet slot (the narrow-bridge payoff over per-member sends).
  v_max := coalesce(cfg_num('max_active_fleets'), 3);
  select count(*) into v_active
    from fleets where player_id = v_player and status in ('moving','present','returning');
  if v_active >= v_max then
    return jsonb_build_object('ok', false, 'reason', 'fleet_limit_reached');
  end if;

  -- Team stats for the gate + the movement: fold the ONE per-ship adapter (calculate_expedition_stats,
  -- 0122) over the LOCKED member set v_members — power = Σ combat_power, speed = min member speed —
  -- EXACTLY the D0 authority's folding law and EXACTLY what the encounter creator does at arrival.
  -- Deliberately NOT the group-shaped calculate_group_expedition_stats: it re-resolves LIVE membership,
  -- and a concurrent assign (group FOR SHARE does not conflict with our FOR SHARE; the new ship's row
  -- is not among our locks) could slip a ship in between our gather and its read — gating power /
  -- computing speed over a SUPERSET of the manifest we are about to freeze, violating the
  -- manifest-wins law at send time. Folding over v_members makes stats ≡ manifest by construction.
  -- The adapter RAISES on an illegal member state (refuse-don't-clamp); folded into the ONE opaque
  -- envelope exactly as get_my_group_expedition_totals does (0166).
  v_power := 0;
  v_speed := null;
  begin
    foreach v_ship in array v_members loop
      v_stats := public.calculate_expedition_stats(v_player, v_ship, '[]'::jsonb, 'pirate_hunt');
      v_power := v_power + coalesce((v_stats->>'combat_power')::double precision, 0);
      v_ms    := (v_stats->>'speed')::double precision;
      v_speed := least(coalesce(v_speed, v_ms), v_ms);
    end loop;
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'stats_invalid');
  end;

  -- Power gate — the 0019:60-63 semantics (reject strictly-below; coalesce a null requirement to 0).
  if v_power < coalesce(v_loc.min_power_required, 0) then
    return jsonb_build_object('ok', false, 'reason', 'power_below_required');
  end if;

  -- The player's home base anchors the trip's origin + return target (0050:117-122).
  select id, x, y, sector_id into v_base
    from bases where player_id = v_player and status = 'active'
    order by created_at limit 1;
  if v_base.id is null then
    return jsonb_build_object('ok', false, 'reason', 'no_home_base');
  end if;

  -- ── WRITES (all-or-nothing: any raise below aborts the whole statement set) ──────────────────────
  -- ONE direct fleets insert — the exact 0050:133-135/0152:135-137 narrow-bridge shape (no fleet_units;
  -- fleet_create rejects empty fleets), carrying what a legacy hunt fleet carries (player, origin base,
  -- 'idle'/'base' pre-move state) PLUS the informational group_id tag (#2 — display only). main_ship_id
  -- stays NULL: this is ONE fleet for MANY ships; the manifest below carries the members.
  insert into fleets (player_id, origin_base_id, status, location_mode, current_base_id, group_id)
    values (v_player, v_base.id, 'idle', 'base', v_base.id, v_group)
    returning id into v_fleet;

  -- Movement spine reuse — the exact 16-arg movement_create shape 0019:67-71 uses for a hunt fleet,
  -- mission 'hunt_pirates' (what a legacy hunt fleet carries; NB the ARRIVAL routes to combat via the
  -- LOCATION's activity_type at presence_create, 0151:66-72 — the mission tag matches legacy anyway),
  -- speed = the per-member fold above (min member speed — the team travels at its slowest ship's pace).
  v_movement := movement_create(
    v_player, v_fleet,
    'base', v_base.id, null, null, v_base.x, v_base.y,
    'location', null, null, v_loc.id, v_loc.x, v_loc.y,
    'hunt_pirates', v_speed);
  perform fleet_set_moving(v_fleet, v_movement);

  -- Member ships → status='hunting' — in the 0043 status domain since day one (kept through the 0055
  -- re-CHECK: 'home','traveling','hunting',… — VERIFIED) and ignored by process_mainship_expeditions
  -- (0050:248 reconciles ONLY 'traveling'/'returning' — VERIFIED) → no reconciler race can yank a
  -- hunting ship home mid-sortie. Pair-write shape (status + spatial_state NULL + coords NULL, the
  -- 0152 legacy-domain law): the members are status='home' under our locks, but 'home' is legal under
  -- BOTH spatial_state NULL and 'home' (0055 ss_home rule), and leaving spatial_state='home' beside
  -- status='hunting' would violate that CHECK. mainship_mark_legacy_in_flight is NOT reused — its
  -- domain is hard-constrained to 'traveling'|'returning' (0152:55) and widening a LIVE leaf for a
  -- dark slice is exactly what the slice discipline forbids.
  update main_ship_instances
    set status = 'hunting', spatial_state = null, space_x = null, space_y = null, updated_at = now()
    where main_ship_id = any(v_members);

  -- Freeze the MANIFEST (the sortie's membership truth; sole-writer law — see the table comment).
  insert into group_sortie_members (fleet_id, main_ship_id, player_id)
    select v_fleet, m, v_player from unnest(v_members) as m;

  select arrive_at into v_arrive from fleet_movements where id = v_movement;
  return jsonb_build_object(
    'ok', true, 'group_id', v_group, 'fleet_id', v_fleet, 'movement_id', v_movement,
    'arrive_at', v_arrive, 'member_count', array_length(v_members, 1));
end;
$$;

-- ── ACL (0163 idiom): authenticated-only; the in-body gate rejects every call while
--    team_command_enabled is false. Explicit revokes are defense-in-depth.
revoke execute on function public.send_ship_group_hunt(uuid, uuid) from public, anon;
grant  execute on function public.send_ship_group_hunt(uuid, uuid) to authenticated;

-- ── 4) combat_create_group_encounter — the member combat_units writer (internal; engine-only) ────────
-- Called ONLY by the re-created combat_create_encounter below when the presence's fleet has manifest
-- rows. SNAPSHOT INPUTS ONLY — zero wave/damage math (the second-engine tripwire): the one tick engine
-- (process_combat_ticks, D1) does all combat arithmetic.
--
-- MANIFEST-WINS DESIGN CHOICE (documented per the slice charter): the D0 authority
-- (calculate_group_expedition_stats) is GROUP-shaped — it reads LIVE membership
-- (main_ship_instances.group_id), which can have diverged from the sortie by arrival time (mid-flight
-- unassign / delete_ship_group). Passing the group and "asserting the manifest matches" would make a
-- legal mid-flight unassign FAIL the sortie. So this creator computes per-member stats by calling the
-- ONE per-ship adapter (calculate_expedition_stats, 0122 — the SAME adapter the D0 authority delegates
-- to) directly per MANIFEST member: zero divergence is possible because live membership is never read.
-- When membership is unchanged (the common case) player_power_start therefore EQUALS the D0
-- totals.combat_power by construction (same adapter, same member set, additive fold).
--
-- RAISE-FREE BY CONSTRUCTION (the settle-cron safety law): this function runs inside
-- movement_settle_arrival's txn, and process_fleet_movements (0151:100-121) has NO per-movement
-- subtransaction — pg_cron runs the whole scan as ONE txn. A raise here would (a) roll back EVERY
-- other player's arrival in that cron run and (b) leave this movement 'moving' and re-selected every
-- cycle: the cron would never settle ANY legacy arrival again. So NOTHING in this body may raise on
-- reachable data:
--   • a member in an illegal stats state (a 0122 refuse-don't-clamp raise — e.g. over-capacity after
--     a mid-flight fitting/captain change) or with hp <= 0 (schema-legal at 'home': the D1 tick's hp
--     sync writes 0 on a member that died while its team escaped; the send's hp>0 guard closes the
--     common path but a mid-flight hp write stays possible) DEGRADES instead of raising: its row is
--     STILL inserted (skipping it would orphan the ship's 'hunting' state outside the sortie's combat
--     accounting) with alive_count=0, attack_snapshot=0, defense_snapshot=0, hp columns 0 — never
--     alive_count=1 with ship_hp=0, which would divide-by-zero in the tick's ceil(hp/ship_hp). An
--     alive_count=0 row is inert and coherent: the tick's per-row loops filter alive_count>0, its
--     stat sums multiply by alive_count (contributes 0), and an all-degraded roster yields a zero-hp
--     encounter the tick's existing (A) defeat pass settles cleanly — fleet_destroy + the D1 member
--     loop marking each manifest ship combat-destroyed. No orphan, no second engine.
--   • the only remaining raise is the presence-not-found guard, mirroring head 0023:82-84 — genuinely
--     unreachable on this path (the presence is created two statements earlier in the SAME settle txn).
--   • the routing branch in combat_create_encounter below carries NO outer exception wrapper —
--     deliberate (choice documented per review): with every reachable raise degraded here the wrapper
--     would be dead code, and the only imaginable fallback (falling through to the legacy zero-unit
--     path) is INCOHERENT — it would insta-defeat a fleet with no member combat_units rows, so the D1
--     defeat loop (which keys on member rows) could never mark the ships, orphaning them in 'hunting'.
create or replace function public.combat_create_group_encounter(p_presence uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  pr        location_presence%rowtype;
  m         record;
  v_stats   jsonb;
  v_roster  jsonb := '[]'::jsonb;
  v_power   double precision := 0;
  v_attack  double precision;
  v_defense double precision;
  v_hp      double precision;
  v_alive   integer;
  v_hull    double precision;
  v_enc     uuid;
begin
  select * into pr from location_presence where id = p_presence;
  if not found then
    raise exception 'combat_create_group_encounter: presence % not found', p_presence;
  end if;

  -- ONE pass over the MANIFEST (never live group membership — the manifest-wins law): each member's
  -- adapter stats + REAL CURRENT hp are read together, BEFORE the encounter insert, so power_start
  -- and the per-member snapshots come from the same reads (no two-pass drift window).
  for m in
    select gsm.main_ship_id, gsm.player_id, msi.hp
      from group_sortie_members gsm
      join main_ship_instances msi on msi.main_ship_id = gsm.main_ship_id
     where gsm.fleet_id = pr.fleet_id
     order by gsm.main_ship_id
  loop
    -- DEGRADE, NEVER RAISE (header law — this runs inside the settle cron's one-txn scan). A member
    -- with hp <= 0, or whose adapter refuses its state (0122's refuse-don't-clamp raises), still gets
    -- a row — but a dead-on-arrival one: alive_count 0, zero snapshots, zero hp. Inert in every tick
    -- read (alive-filtered loops; ×alive_count sums) and settled by the existing defeat machinery if
    -- the whole roster is degraded. Never skipped (an absent row would orphan the ship's 'hunting'
    -- state) and never alive with ship_hp=0 (the tick's ceil(hp/ship_hp) would divide by zero).
    v_attack := 0; v_defense := 0; v_hp := 0; v_alive := 0;
    if m.hp > 0 then
      begin
        -- The ONE per-ship stat adapter (0122), empty loadout — exactly what the D0 authority
        -- delegates with. attack := combat_power, defense := survival (the D1 snapshot semantics).
        v_stats   := public.calculate_expedition_stats(m.player_id, m.main_ship_id, '[]'::jsonb, 'pirate_hunt');
        v_attack  := coalesce((v_stats->>'combat_power')::double precision, 0);
        v_defense := coalesce((v_stats->>'survival')::double precision, 0);
        v_hp      := m.hp;
        v_alive   := 1;
      exception when others then
        -- adapter refused (illegal member state) → the degraded shape above.
        v_attack := 0; v_defense := 0; v_hp := 0; v_alive := 0;
      end;
    end if;
    v_power  := v_power + v_attack;   -- a degraded member contributes zero fighting power.
    v_roster := v_roster || jsonb_build_array(jsonb_build_object(
      'main_ship_id', m.main_ship_id, 'player_id', m.player_id, 'hp', v_hp,
      'alive', v_alive, 'attack', v_attack, 'defense', v_defense));
  end loop;
  -- NO empty-roster raise (header law): unreachable behind the caller's exists() gate — the manifest
  -- is read in the same txn that just proved it non-empty — and if it somehow fired it would be
  -- another cron-poisoning raise. An empty roster would simply produce a zero-unit encounter the
  -- tick's (A) defeat pass settles on its first look.

  -- Encounter row — the head 0023:87-95 insert shape mirrored semantically: same columns, same
  -- 'active'/danger-1/wave-0 initial state; player_power_start/current := Σ member combat_power
  -- (the member analogue of fleet_get_power; == D0 totals.combat_power over the manifest set).
  insert into combat_encounters (
    player_id, fleet_id, presence_id, location_id, status, danger_level,
    player_power_start, player_power_current, enemy_power_current,
    player_integrity_max, player_integrity_current, enemy_integrity_max, enemy_integrity_current,
    wave_number, last_resolved_at)
  values (
    pr.player_id, pr.fleet_id, p_presence, pr.location_id, 'active', 1,
    v_power, v_power, 0, 0, 0, 0, 0, 0, now())
  returning id into v_enc;

  -- One member combat row per manifest member — the D1-widened shape, satisfying all three D1
  -- invariants: exactly-one-identity (unit_type_id NULL ⊕ main_ship_id), snapshot-pairing (BOTH
  -- snapshots set on a member row — a degraded member's are 0, which is non-null),
  -- one-member-row-per-encounter (the manifest PK guarantees distinct ships). For a LIVE member:
  -- hp_max/hp_current := the ship's REAL CURRENT main_ship_instances.hp — pre-existing damage
  -- carries into the encounter (never max_hp); ship_hp := the same (one hull, alive_count 1 — the
  -- tick's ceil(hp/ship_hp) keeps the single hull alive until 0). For a DEGRADED member: alive 0,
  -- all-zero stats/hp (header law; ship_hp=0 is safe ONLY because alive_count=0 rows never reach the
  -- tick's division).
  insert into combat_units (
    encounter_id, player_id, unit_type_id, main_ship_id, attack_snapshot, defense_snapshot,
    ship_hp, initial_count, alive_count, hp_max, hp_current)
  select v_enc, (e->>'player_id')::uuid, null, (e->>'main_ship_id')::uuid,
         (e->>'attack')::double precision, (e->>'defense')::double precision,
         (e->>'hp')::double precision, 1, (e->>'alive')::integer,
         (e->>'hp')::double precision, (e->>'hp')::double precision
  from jsonb_array_elements(v_roster) as e;

  -- Integrity := Σ member hp — the head 0023:103-104 statement pair verbatim (hp_max is per-member
  -- real hp here, so the sum IS the team's current hull integrity).
  select coalesce(sum(hp_max), 0) into v_hull from combat_units where encounter_id = v_enc;
  update combat_encounters set player_integrity_max = v_hull, player_integrity_current = v_hull where id = v_enc;

  -- The head 0023:106-107 opening event verbatim (the tick spawns the real wave on its first pass).
  insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
    values (v_enc, pr.player_id, 0, 0, 'wave_spawned', 'pirate', 'player', jsonb_build_object('wave', 1, 'danger', 1));
  return v_enc;
end;
$$;

-- Internal engine leaf — the D1 leaves' ACL posture (0153 idiom): SECURITY DEFINER callers
-- (combat_create_encounter, itself invoked by the settle chain) run it as owner; service_role keeps
-- CI/inspection access; NO client role can execute it.
revoke execute on function public.combat_create_group_encounter(uuid) from public, anon, authenticated;
grant  execute on function public.combat_create_group_encounter(uuid) to service_role;

-- ── 5) combat_create_encounter — 0023:69 body VERBATIM + the ONE marked SLICE D2 routing branch ──────
-- Copied from the TRUE head (grep over ALL migrations: created 0017, re-created 0022, re-created
-- 0023:69 — nothing later re-creates it; VERIFIED). The single delta is the manifest-gated branch
-- right after the presence read: a fleet with sortie manifest rows routes to the member encounter
-- creator; everything below the branch is byte-identical to the head (diff-verified — the D1 parity
-- discipline). UNREACHABLE IN PROD: no manifest row can exist while team_command_enabled is false
-- (send_ship_group_hunt is the manifest's sole writer and rejects at its gate), so every live legacy
-- hunt encounter takes the identical head path.
create or replace function public.combat_create_encounter(p_presence uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  pr      location_presence%rowtype;
  v_power double precision;
  v_hull  double precision;
  v_enc   uuid;
begin
  select * into pr from location_presence where id = p_presence;
  if not found then
    raise exception 'combat_create_encounter: presence % not found', p_presence;
  end if;
  -- SLICE D2: a fleet with a sortie MANIFEST routes to the member encounter creator. Keys on
  -- group_sortie_members ONLY (never live group membership, never fleets.group_id — the
  -- manifest-wins law). No manifest row can exist while team_command_enabled=false (sole writer is
  -- the gated send_ship_group_hunt) → this branch is unreachable in prod; legacy byte-parity below.
  if exists (select 1 from group_sortie_members gsm where gsm.fleet_id = pr.fleet_id) then
    return combat_create_group_encounter(p_presence);
  end if;
  v_power := fleet_get_power(pr.fleet_id);

  insert into combat_encounters (
    player_id, fleet_id, presence_id, location_id, status, danger_level,
    player_power_start, player_power_current, enemy_power_current,
    player_integrity_max, player_integrity_current, enemy_integrity_max, enemy_integrity_current,
    wave_number, last_resolved_at)
  values (
    pr.player_id, pr.fleet_id, p_presence, pr.location_id, 'active', 1,
    v_power, v_power, 0, 0, 0, 0, 0, 0, now())
  returning id into v_enc;

  -- Per-unit combat state from the fleet's composition.
  insert into combat_units (encounter_id, player_id, unit_type_id, ship_hp, initial_count, alive_count, hp_max, hp_current)
  select v_enc, pr.player_id, fu.unit_type_id, ut.hull, fu.quantity, fu.quantity, fu.quantity * ut.hull, fu.quantity * ut.hull
  from fleet_units fu join unit_types ut on ut.id = fu.unit_type_id
  where fu.fleet_id = pr.fleet_id and fu.quantity > 0;

  select coalesce(sum(hp_max), 0) into v_hull from combat_units where encounter_id = v_enc;
  update combat_encounters set player_integrity_max = v_hull, player_integrity_current = v_hull where id = v_enc;

  insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
    values (v_enc, pr.player_id, 0, 0, 'wave_spawned', 'pirate', 'player', jsonb_build_object('wave', 1, 'danger', 1));
  return v_enc;
end;
$$;

-- CREATE OR REPLACE on the EXISTING function PRESERVES its owner and grants (it is an internal
-- Presence→Combat hook with no client grant, 0017/0021 lock era) — no blanket re-lock is emitted
-- (the D1 §7 rationale verbatim: that idiom belongs to migrations adding NEW client RPCs).
