-- 4C-MIG-2A — MOVEMENT-WRITER REPOINT (migration 0222): the DUAL-SAFE first stage of the writer
-- retirement. The status literal 'stationary' is retired to 'home' everywhere a writer below still
-- mints it, and send_ship_group_hunt's launch-ELIGIBILITY logic — which READ
-- main_ship_instances.status/spatial_state to decide "is this member docked at a port" — is
-- repointed onto FLEET TRUTH, mirroring 0221 R1-f (the same fleet+presence pair the oracle trusts).
--
-- ─── CI-CORRECTED SCOPE (2026-07-18): the column WRITES themselves are NOT touched in this ────────
-- ─── migration — an earlier draft did, and it was a genuine constraint-safety bug. ─────────────────
-- The 0055 CHECKs COUPLE spatial_state to status (main_ship_instances_ss_at_location_status /
-- _ss_in_space_status: spatial_state='at_location'/'in_space' ⟹ status='stationary'). Every TRUE
-- head that moves status OFF 'stationary' (mainship_mark_combat_destroyed → 'destroyed',
-- repair_main_ship's docked revival → was 'stationary' now 'home', send_ship_group_hunt's departure
-- → 'hunting') ALWAYS clears spatial_state (and space_x/space_y) in the SAME statement, precisely
-- to satisfy that coupling. An earlier draft of this file deleted those clears, reasoning that 0221
-- already stopped every READ from consulting the column — true for reads, fatal for writes: THREE
-- real prod ships carry spatial_state='at_location' today, and any of the three writers above firing
-- on one of them would have left status≠'stationary' with spatial_state='at_location' still set —
-- a CHECK VIOLATION that aborts the write in prod (caught for real by the disposable-Postgres
-- apply-proof, not by the earlier static/adversarial review). THE FIX: every status-changing write
-- below KEEPS clearing spatial_state/space_x/space_y exactly as its head did — this migration
-- changes STATUS LITERALS and ONE READ, never leaves a write half-clearing a CHECK-coupled column
-- set. Column-WRITE removal (dropping the clears entirely) is safe ONLY after 4c-mig-2b narrows the
-- status CHECK and drops the columns together — it never belonged in this dual-safe stage.
--
-- Charter: docs/MOVEMENT_UNIFICATION_CHARTER.md §2 (the FLEET is the only mover; membership IS
-- position) + the legacy-schema retirement plan (4c). This is the SECOND dual-safe stage (after
-- 4c-mig-1/0221's READ repoint): the legacy objects all STILL EXIST after this migration —
-- NOTHING is dropped or altered here.
--
-- ─── ZERO DROPS / ZERO ALTER / ZERO CHECK NARROW. ─────────────────────────────────────────────────
-- This file contains ONLY `create or replace function` re-creates + grants + a self-assert. If a
-- future edit adds DROP, ALTER TABLE, or a CHECK narrow to this file it belongs in 4c-mig-2b, not
-- here. The §0 gate below ASSERTS the legacy objects still exist at apply time (the dual-safe
-- contract stated as code, exactly as 0221's).
--
-- ─── THE FOUR RE-CREATES (byte-parity discipline: each body is its TRUE head byte-for-byte with ──
-- ─── ONLY the marked hunks changed; the reviewer independently diffs body-vs-head). ──────────────
-- TRUE heads re-derived by grep over ALL migrations 2026-07-18 (trust the code, not the plan doc —
-- the plan's own inventory has been wrong repeatedly across this arc):
--   a1 mainship_space_lock_context  — TRUE head 20260618000056:20-86 (the ONLY definition ever;
--                                     ~19 live callers, verified by grep — matches the plan's count).
--                                     READ repoint only — no writes in this function.
--   b1 port_entry_commission_build  — TRUE head 20260618000216:651-764 (0080→0184→0193→0194→0197→0216).
--                                     A FRESH INSERT, not an update — dropping spatial_state/space_x/
--                                     space_y from the column list leaves them at the column DEFAULT
--                                     (NULL, no CHECK-coupling risk: there is no PRIOR row value to
--                                     conflict with 'home'). Confirmed constraint-safe by the
--                                     apply-proof; unchanged by this correction.
--   b2 ensure_main_ship_for_player  — TRUE head 20260618000216:772-828 — READ IN FULL: this body's
--                                     INSERT never lists status/spatial_state/space_x/space_y at
--                                     all (relies on the table's own column DEFAULTS: status
--                                     defaults 'home' at 0043, spatial_state is nullable with NO
--                                     default at 0054). There is NO hunk to apply here — the plan
--                                     document's "same shape, same hunk" instruction is WRONG vs
--                                     the code; this function is SKIPPED (not re-created) below.
--                                     See the note at §3.
--   b3 mainship_mark_combat_destroyed — SKIPPED. TRUE head 20260618000167:160-171 writes
--                                     status='destroyed', hp=0, spatial_state=null, space_x=null,
--                                     space_y=null in ONE statement. Once the CI-corrected spatial
--                                     clears are restored (constraint-required — see above), this
--                                     function has ZERO delta from its head, so — like b2 — it is
--                                     left un-re-created. See the note at §4.
--   b4 repair_main_ship             — TRUE head 20260618000199:750-797 (sig `(uuid default null)`;
--                                     the 0-arg overload was dropped at 0081 — this is the only
--                                     live overload, verified by grep: only 0052/0081-drop/0199).
--                                     The hunk is the status literal 'stationary'→'home' (SET +
--                                     return jsonb) PLUS the constraint-required spatial_state
--                                     co-change 'at_location'→null (space_x/space_y=null unchanged).
--   b5 send_ship_group_hunt         — TRUE head 20260618000214:114-632 (0168→0199-drop+recreate→
--                                     0204→0214; the ONLY four definitions found by grep, 0214 last).
--                                     THE HIGHEST-RISK re-create in this migration — see §6 below.
--                                     The three departure writes are now HEAD-VERBATIM (no hunk —
--                                     see the CI-corrected-scope note above); the ONLY real hunk is
--                                     the launch-eligibility READ repoint onto fleet truth.
--
-- ─── COMPOSITION LAW (NO new formulas). ───────────────────────────────────────────────────────────
-- b5's fleet-truth eligibility hunk composes the SAME leaves 0221 R1-f already trusts:
-- mainship_resolve_fleet (0210 — the ONE ship→fleet resolver) + a direct fleets/location_presence
-- read for "present at a location with a matching active presence" — the identical shape R1-f
-- checks, not a new formula.
--
-- CI: scripts/fleetgo-proof.sh selftest carries a REPOINT-PARITY static section for this file
-- (byte-diff pins against each head, the zero-drop/alter ban, the retired-literal bans, the
-- fleet-truth compose checks). The §9 self-assert below re-proves the repoint on the DEPLOYED
-- bodies AND reconciles the b5 fleet-truth predicate against EVERY REAL SHIP ROW reachable by the
-- code path it replaces, at apply time.

-- ── §0. dependency + dual-safe gate: the leaves this file composes must exist, and the legacy ─────
-- ──     objects must STILL exist (this migration must land strictly BEFORE 4c-mig-2b). ────────────
do $repoint0$
begin
  if to_regprocedure('public.mainship_resolve_fleet(uuid)') is null then
    raise exception '4C-MIG-2A: mainship_resolve_fleet (0210) is missing — the b5 repoint composes it';
  end if;
  if to_regprocedure('public.mainship_space_validate_context(uuid)') is null then
    raise exception '4C-MIG-2A: mainship_space_validate_context (0221 head) is missing — depended on by every re-created writer''s post-write checks';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'main_ship_instances'
                    and column_name = 'berth_location_id') then
    raise exception '4C-MIG-2A: main_ship_instances.berth_location_id (S1/0216) is missing — the S1 berth rule has no column';
  end if;
  -- the DUAL-SAFE contract: the legacy objects are intact at apply time. Their absence would mean
  -- 4c-mig-2b (or something worse) ran first and this file is being applied out of order.
  if to_regclass('public.main_ship_space_movements') is null then
    raise exception '4C-MIG-2A: main_ship_space_movements is already gone — this migration must apply with the legacy schema intact (it stops WRITING; 4c-mig-2b drops)';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fleets'
                    and column_name = 'active_space_movement_id')
     or not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'main_ship_instances'
                    and column_name = 'spatial_state') then
    raise exception '4C-MIG-2A: a legacy pointer/state column is already gone — apply order broken (this file precedes the drops)';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'main_ship_instances'
                    and column_name = 'status' and column_default like '%stationary%') then
    -- 'stationary' must still be an ALLOWED status value (the CHECK is not yet narrowed) — a writer
    -- that stopped minting it here must not be validated against a schema that already forbids it.
    if not exists (
      select 1 from pg_constraint c join pg_class t on t.oid = c.conrelid
       where t.relname = 'main_ship_instances' and c.contype = 'c'
         and pg_get_constraintdef(c.oid) like '%stationary%') then
      raise exception '4C-MIG-2A: the main_ship_instances status CHECK no longer admits ''stationary'' — the CHECK narrow (4c-mig-2b) ran before this dual-safe writer stage';
    end if;
  end if;
end $repoint0$;

-- ═══════════ §1. a1 — mainship_space_lock_context: the 0056:20 TRUE head (the ONLY definition ════
-- ═══════════ ever written), byte-copied, with the marked repoint hunk ONLY. ══════════════════════
-- ~19 live callers (trade_market_buy/sell 0089/0090, resolve_docked_location 0092, world_balance
-- 0136/0138, salvage 0174, haul 0179, repair 0201, exploration_scan/mining_extract + their
-- duplicate-guards 0099/0100/0104/0137/0143/0146/0150/0172/0172, the OSN internals 0057/0058/0059/
-- 0060/0061/0064/0067×2 — grep-verified). ~15 of them `perform` it and discard the whole result
-- (transparent to any hunk here); only exploration_scan/mining_extract read `status`/`ship.player_id`
-- off it (both STILL present below) — grep-verified: zero callers read `->'space_movement'`.
-- Hunk: delete the coordinate-movement rowtype declare + its FOR UPDATE lock (old step 3) + the
-- 'space_movement' key from the returned jsonb. Everything else — the ship lock, the fleet
-- loop+lock, the presence lock, the non-locking fleet_movements existence check,
-- has_active_legacy_movement — survives VERBATIM.
create or replace function public.mainship_space_lock_context(p_main_ship_id uuid, p_skip_locked boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ship      main_ship_instances%rowtype;
  v_fleet     fleets%rowtype;
  v_fleets    jsonb := '[]'::jsonb;
  v_count     integer := 0;
  v_one_fleet uuid := null;
  -- ── ★ 4C-MIG-2A HUNK a1: the coordinate-movement rowtype declare is DELETED (its lock and its ★ ──
  -- ── ★ read below are both retired — 0221 already stopped every live caller from reading it).  ★ ──
  v_pres      location_presence%rowtype;
  v_has_legacy boolean := false;
begin
  -- 1) ship row FIRST
  if p_skip_locked then
    select * into v_ship from main_ship_instances where main_ship_id = p_main_ship_id for update skip locked;
    if not found then
      if exists (select 1 from main_ship_instances where main_ship_id = p_main_ship_id)
        then return jsonb_build_object('status','skipped');     -- locked by another txn
        else return jsonb_build_object('status','not_found');
      end if;
    end if;
  else
    select * into v_ship from main_ship_instances where main_ship_id = p_main_ship_id for update;
    if not found then return jsonb_build_object('status','not_found'); end if;
  end if;

  -- 2) the ship's non-terminal fleets (locked, deterministic order). >1 is a contradiction validate flags.
  for v_fleet in
    select * from fleets
    where main_ship_id = p_main_ship_id and status in ('idle','moving','present','returning')
    order by id
    for update
  loop
    v_count := v_count + 1;
    v_fleets := v_fleets || to_jsonb(v_fleet);
    v_one_fleet := v_fleet.id;
  end loop;
  if v_count <> 1 then v_one_fleet := null; end if;   -- only a single relevant fleet is "the" fleet

  -- ── ★ 4C-MIG-2A HUNK a1: the old step 3 (the coordinate movement's FOR UPDATE lock) is        ★ ──
  -- ── ★ DELETED here — nothing downstream of this function reads that lock anymore.            ★ ──

  -- 4) the active location presence for the single relevant fleet (if any)
  if v_one_fleet is not null then
    select * into v_pres from location_presence where fleet_id = v_one_fleet and status = 'active' for update;
    -- 5) NON-LOCKING legacy-movement existence check (never lock fleet_movements after the fleet)
    v_has_legacy := exists (select 1 from fleet_movements where fleet_id = v_one_fleet and status = 'moving');
  end if;

  return jsonb_build_object(
    'status', 'locked',
    'main_ship_id', p_main_ship_id,
    'ship', to_jsonb(v_ship),
    'fleets', v_fleets,
    'fleet_count', v_count,
    'relevant_fleet_id', v_one_fleet,
    -- ── ★ 4C-MIG-2A HUNK a1: the coordinate-movement return key is DELETED here — grep-verified ★ ──
    -- ── ★ zero callers read it (only ->status and ->ship->player_id are ever consulted).        ★ ──
    'presence', case when v_pres.id is null then null else to_jsonb(v_pres) end,
    'has_active_legacy_movement', v_has_legacy
  );
end;
$$;
-- ACL re-asserted exactly as 0056 (CREATE OR REPLACE preserves it; defense-in-depth re-assert).
revoke execute on function public.mainship_space_lock_context(uuid, boolean) from public, anon, authenticated;
grant  execute on function public.mainship_space_lock_context(uuid, boolean) to service_role;

-- ═══════════ §2. b1 — port_entry_commission_build: the 0216:651 TRUE head, byte-copied, with ════
-- ═══════════ the marked repoint hunks ONLY. ══════════════════════════════════════════════════════
-- Hunk: spatial_state/space_x/space_y are deleted from the INSERT column list + values; the status
-- literal 'stationary' → 'home'. The function's OWN final coherence gate (unchanged, below) already
-- proves the freshly-commissioned ship reads 'at_location' from the fleet+presence pair this same
-- function inserts — that proof was ALREADY fleet-truth after 0221 R1-f (v_count=1, fleet
-- status='present'), so this hunk is inert to that gate: it only stops minting a column nothing
-- decides on any more.
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
  -- ── ★ 4C-MIG-2A HUNK b1 (comment accuracy only): the ship is inserted status='home' below —   ★ ──
  -- ── ★ the retired spatial_state/space_x/space_y columns are no longer minted (they still      ★ ──
  -- ── ★ exist but stopped being READ at 0221; they retire with 4c-mig-2b). The "never a         ★ ──
  -- ── ★ committed intermediate bare home/legacy_home row" guarantee below now holds through the ★ ──
  -- ── ★ fleet/presence pair inserted in THIS SAME transaction, not through this column.         ★ ──
  -- No on-conflict: the CALLER already serialized + checked existence/cap.
  insert into public.main_ship_instances
    -- ── ★ 4C-MIG-2A HUNK b1: spatial_state, space_x, space_y are DELETED from the column list. ★ ──
    (player_id, hull_type_id, name, status,
     hp, max_hp, cargo_capacity, cargo_capacity_m3, support_capacity, captain_slots, module_slots,
     shield, max_shield,   -- SHIELD-2 (0197): the deferred commission copy (the 0043:81 base_hp analogue)
     berth_location_id)    -- S1-BERTH (0216) HUNK: born BERTHED at the commission port (XOR: group_id defaults NULL)
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
         -- ── ★ 4C-MIG-2A HUNK b1: 'stationary' → 'home' — status is the ONLY per-ship movement  ★ ──
         -- ── ★ signal this insert sets now; the docked shape is the fleet/presence pair minted  ★ ──
         -- ── ★ below, never this column.                                                        ★ ──
         'home',
         h.base_hp, h.base_hp, h.base_cargo_capacity, h.base_cargo_capacity_m3, h.base_support_capacity, h.base_captain_slots, h.base_module_slots,
         -- SHIELD-2 (0197) HUNK: born FULL — shield := base_shield AND max_shield := base_shield
         -- (the h.base_hp, h.base_hp posture above, mirrored: a fresh hull leaves the yard
         -- charged [D]; ACT-SHIELD's instance backfill uses the same shield=max shape). While
         -- every hull's base_shield is 0 (migration-asserted) this writes 0/0 — byte-identical
         -- to the column defaults it replaces (provably inert on deploy). shield <= max_shield
         -- holds by construction (equal).
         h.base_shield, h.base_shield,
         -- END SHIELD-2 (0197) HUNK
         -- S1-BERTH (0216) HUNK: the berth value — the commission port the fleet/presence write
         -- below docks the ship at, so the berth and the (transition-era) corpse dock agree.
         c_haven
         -- END S1-BERTH (0216) HUNK
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
-- explicitly — the 0197/0216 idiom carried forward):
revoke execute on function public.port_entry_commission_build(uuid, text) from public, anon, authenticated;
grant  execute on function public.port_entry_commission_build(uuid, text) to service_role;

-- ═══════════ §3. b2 — ensure_main_ship_for_player: SKIPPED (no hunk exists in the code). ═════════
-- The corrected plan document says this function needs the same spatial_state/coords/status hunk
-- as port_entry_commission_build. That is WRONG vs the TRUE head (20260618000216:772-828, read in
-- full above this migration's header): its INSERT column list is
--   (player_id, hull_type_id, hp, max_hp, cargo_capacity, cargo_capacity_m3, support_capacity,
--    captain_slots, module_slots, shield, max_shield, berth_location_id)
-- — status, spatial_state, space_x, and space_y are NOT in that list at all. The row is born
-- through the TABLE'S OWN column defaults: status defaults 'home' (20260617000043:50) and
-- spatial_state is nullable with no default (20260618000054:34). This function has therefore
-- ALREADY been minting the post-repoint shape (status='home', spatial_state=NULL) since it was
-- written — there is nothing to change. Re-creating it here with a no-op body would be pure churn
-- against the byte-parity discipline this migration otherwise enforces, so it is left untouched.

-- ═══════════ §4. b3 — mainship_mark_combat_destroyed: SKIPPED (CI-caught: the naive hunk was a ══
-- ═══════════ genuine constraint-safety bug, not a style choice). ═════════════════════════════════
-- The TRUE head (20260618000167:160-171, the ONLY definition ever) writes
--   set status = 'destroyed', hp = 0, spatial_state = null, space_x = null, space_y = null, updated_at = now()
-- An EARLIER draft of this migration deleted the spatial_state/space_x/space_y clears, reasoning
-- that 0221 already stopped every READ from consulting them. That reasoning ignored the WRITE-side
-- 0055 CHECK coupling: main_ship_instances_ss_at_location_status / _ss_in_space_status require
-- spatial_state='at_location'/'in_space' ⟹ status='stationary'. THREE prod ships currently carry
-- spatial_state='at_location' with a live per-ship fleet; a live combat kill on one of them would
-- have written status='destroyed' while spatial_state stayed 'at_location' — a CHECK VIOLATION
-- that aborts the whole combat-tick transaction in prod. The disposable-Postgres apply-proof (which
-- actually enforces the CHECK, unlike the adversarial static review) caught this for real.
-- THE FIX: restore spatial_state/space_x/space_y = null verbatim. Once restored, this function has
-- ZERO delta from its 0167 head — there is nothing left to re-create. Re-creating a byte-identical
-- body would be pure churn against this migration's own byte-parity discipline (the §3/b2 rule
-- applied consistently), so — like b2 — it is left untouched. NO re-create, NO ACL re-assert below.

-- (mainship_mark_combat_destroyed intentionally has no §4 body — see the note above.)

-- ═══════════ §5. b4 — repair_main_ship: the 0199:750 TRUE head (sig `(uuid default null)`; the ══
-- ═══════════ 0-arg overload was DROPPED at 0081 — grep-verified this is the only live overload), ══
-- ═══════════ byte-copied, with the marked repoint hunk in the launch-from-dock branch ONLY. ══════
-- src/ was grepped for the literal 'stationary' before writing this hunk (see the migration
-- header/PR notes): both client call sites (src/features/ship/FittingDetail.tsx:196 and
-- src/features/ship/ShipScreen.tsx:139) call `await repairMainShip(shipId)` and DISCARD the return
-- value entirely (they re-fetch fresh state via game/map/selection refresh instead) — zero client
-- code pattern-matches this RPC's response 'status' field, so the return-jsonb literal change below
-- is safe.
create or replace function public.repair_main_ship(p_main_ship_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_ship   main_ship_instances%rowtype;
  v_launch_from_dock boolean := public.cfg_bool('launch_from_dock_enabled');
begin
  if v_player is null then
    raise exception 'repair_main_ship: not authenticated';
  end if;

  select * into v_ship from main_ship_instances
    where main_ship_id = public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship.main_ship_id is null then
    raise exception 'repair_main_ship: no main ship found';
  end if;
  if v_ship.status <> 'destroyed' then
    raise exception 'repair_main_ship: ship is not disabled (status %) — nothing to repair', v_ship.status;
  end if;
  if v_ship.max_hp is null or v_ship.max_hp <= 0 then
    raise exception 'repair_main_ship: invalid max_hp (%)', v_ship.max_hp;
  end if;

  if v_launch_from_dock then
    -- ── ★ 4C-MIG-2A HUNK b4 (CI-corrected): the revived-docked status literal changes            ★ ──
    -- ── ★ 'stationary' → 'home'. space_x=null/space_y=null are KEPT VERBATIM (byte-parity — no   ★ ──
    -- ── ★ value in dropping only the unconstrained coords while the columns still exist; 2b      ★ ──
    -- ── ★ removes all three writes together when it drops the columns). spatial_state is NOT    ★ ──
    -- ── ★ deleted from the SET — it is CO-CHANGED from 'at_location' to null: the 0055 CHECK     ★ ──
    -- ── ★ main_ship_instances_ss_at_location_status requires spatial_state='at_location' ⟹      ★ ──
    -- ── ★ status='stationary'; since this hunk already changes status to 'home', LEAVING         ★ ──
    -- ── ★ spatial_state='at_location' would violate that CHECK on every real docked-then-        ★ ──
    -- ── ★ destroyed-then-revived ship (an earlier draft did exactly that and the disposable-     ★ ──
    -- ── ★ Postgres apply-proof caught it). null is constraint-legal for status='home'            ★ ──
    -- ── ★ (ss_home_status: spatial_state='home' ⟹ status='home' — vacuous on null) and matches   ★ ──
    -- ── ★ the fleet-truth oracle's own posture: nothing downstream reads this column any more    ★ ──
    -- ── ★ (0221), the revived ship reads through whatever the oracle says from its               ★ ──
    -- ── ★ berth_location_id/group/any leftover fleet row instead. This branch mints NO fleet/     ★ ──
    -- ── ★ presence pair (the 0199 header's "Kept SIMPLE" note, carried forward unchanged).       ★ ──
    update main_ship_instances
      set hp = v_ship.max_hp, status = 'home', spatial_state = null,
          space_x = null, space_y = null, updated_at = now()
      where main_ship_id = v_ship.main_ship_id;
    return jsonb_build_object(
      'main_ship_id', v_ship.main_ship_id, 'status', 'home',
      'hp', v_ship.max_hp, 'max_hp', v_ship.max_hp);
  end if;

  -- 0081 HEAD (DARK path — byte-identical): restore to full readiness, back home.
  update main_ship_instances
    set hp = v_ship.max_hp, status = 'home', updated_at = now()
    where main_ship_id = v_ship.main_ship_id;

  return jsonb_build_object(
    'main_ship_id', v_ship.main_ship_id, 'status', 'home',
    'hp', v_ship.max_hp, 'max_hp', v_ship.max_hp);
end;
$$;
-- The signature is unchanged so CREATE OR REPLACE kept the 0081 ACL; re-assert for explicitness (recovery
-- is NEVER flag-gated — the safelock guarantee, carried from 0052/0081/0199).
revoke execute on function public.repair_main_ship(uuid) from public, anon;
grant execute on function public.repair_main_ship(uuid) to authenticated;

-- ═══════════ §6. b5 — send_ship_group_hunt: the 0214:114 TRUE head, byte-copied, with the ═══════
-- ═══════════ launch-eligibility READ hunk below (CI-corrected — see the file header). THE ════════
-- ═══════════ HIGHEST-RISK re-create in this migration (live hunt launch path; team_command ═══════
-- ═══════════ is ON in prod). ═══════════════════════════════════════════════════════════════════
--
-- SCOPE (CI-corrected — an earlier draft also hunked the three departure writes; that was reverted,
-- see the file header's "CI-CORRECTED SCOPE" note):
--   (i)  the THREE departure writes (Hunk C's mint / the NOHOME launch-branch mint / the 0168 dark
--        head's mint) are HEAD-VERBATIM — no hunk. status='hunting', spatial_state=null,
--        space_x=null, space_y=null are all KEPT exactly as the head writes them: status is the
--        sortie/combat layer's own signal (process_combat_ticks + shield-regen exclusion read it;
--        it retires at step 4c with the status-CHECK narrow), and the spatial clears are REQUIRED
--        by the 0055 CHECK coupling (spatial_state='at_location'/'in_space' ⟹ status='stationary')
--        on any docked member whose spatial_state is still non-null when the hunt fires.
--   (ii) the ONLY real hunk: the launch-ELIGIBILITY logic that read the ship's own
--        status='stationary' AND spatial_state='at_location' pair to decide "this member is docked
--        at a port" becomes FLEET TRUTH, mirroring 0221 R1-f exactly: a member is docked ⇔ its ONE
--        resolved fleet (mainship_resolve_fleet) is 'present' at a location
--        (location_mode='location', current_location_id not null, no live movement pointer) with a
--        matching active location_presence row. The common-port check is rekeyed the same way: it
--        now reads the port FROM THE FLEET (f.current_location_id), never by joining on the ship's
--        own main_ship_id column.
--
-- WHY mainship_resolve_fleet IS THE RIGHT COMPOSE HERE (not a new formula): by the time control
-- reaches ANY of these three call sites, Hunk C (BELOW, unchanged from 0214) has ALREADY proven
-- v_gf_n = 0 for this group — i.e. no live unified (main_ship_id IS NULL) fleet exists for it — the
-- ONLY way execution falls through to the readiness/launch code these hunks touch. Under that
-- precondition mainship_resolve_fleet's own group branch (0210:85-100) finds nothing and falls to
-- its TRANSITION FALLBACK (0210:102-116): the ship's OWN per-ship fleet — the EXACT row the old
-- `f.main_ship_id = s.main_ship_id` join used to key on. So on every state this code path can
-- actually reach, the fleet-truth predicate below resolves to the identical fleet row the retired
-- ship-column predicate implicitly assumed existed — this is a REPOINT, not a behavior change, on
-- the reachable domain. (For a member whose group DOES carry a live unified fleet, execution never
-- reaches this code at all — Hunk C's own v_gf_n = 1 branch handles it first, unchanged.)
create or replace function public.send_ship_group_hunt(p_group_id uuid, p_location uuid, p_return_location_id uuid default null)
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
  -- NOHOME (0199): the gate + docked-launch working set. Dark seed → false → the 0168 head runs verbatim.
  v_launch_from_dock boolean := public.cfg_bool('launch_from_dock_enabled');
  -- ── ★ 4C-MIG-2A HUNK B5-a (comment only): "docked" is now FLEET TRUTH (mirrors 0221 R1-f),   ★ ──
  -- ── ★ not the ship's own status='stationary'/spatial_state='at_location' pair.               ★ ──
  v_docked   integer;   -- members currently docked, per FLEET TRUTH (see Hunks B5-b/B5-c below)
  v_dockcount integer;  -- distinct docked ports across the members (must be exactly 1)
  v_dock_loc uuid;      -- the ONE common docked port (all members) — the launch origin
  v_cur      record;    -- docked-port coordinates + zone/sector
  v_return   uuid;      -- chosen (or origin) return port recorded on the team fleet
  -- FLEET-CONTROL (0204): the gate, read ONCE. Dark seed → false → the command-ship hunk is skipped and the
  -- 0199 body runs verbatim.
  v_fleet_control boolean := public.cfg_bool('fleet_control_enabled');
  -- HUNT-UNI (0214) HUNK A: the unification gate, read ONCE at the top (the 0204/0213 idiom directly
  -- above, verbatim). Dark seed → false → Hunk B below keeps the head's FOR SHARE and Hunk C is
  -- skipped entirely — a side-effect-free stable read is the WHOLE dark delta of this migration.
  v_unified boolean := public.cfg_bool('fleet_movement_unified_enabled');
  v_gf_n    integer;              -- live group-shaped fleets found by the 0213 leaf
  v_gf      public.fleets%rowtype; -- the ONE such fleet, when v_gf_n = 1
  v_busy    integer;              -- members flying their OWN per-ship fleet (the guard-7 read, F2)
  v_gfl     record;               -- the consumed fleet's port row (coords for the origin)
  v_o_type  text;                 -- sortie origin, captured FROM THE FLEET (the 0208 arm naming)
  v_o_base  uuid;
  v_o_zone  uuid;
  v_o_loc   uuid;
  v_o_x     double precision;
  v_o_y     double precision;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  if not public.cfg_bool('team_command_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'team_command_disabled');
  end if;

  v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
  if v_group is null then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  -- HUNT-UNI (0214) HUNK B: lock STRENGTH only — the statement and the envelope are the head's
  -- either way. LIT takes FOR UPDATE so this hunt SERIALIZES against command_ship_group_go/stop's
  -- group FOR UPDATE (0208:274, 0209:66) and 0213's lit assign arm: a hunt and a go that interleave
  -- their fleet reads could BOTH mint — the exact two-fleet catastrophe this migration exists to
  -- kill, arriving by race instead of by readiness hole. Whoever commits second re-reads the leaf
  -- under the lock and sees the other's fleet. DARK keeps FOR SHARE byte-identically — the lock
  -- footprint is part of parity (the 0213 rule). AT STEP 4 (flag permanently lit): collapse to the
  -- FOR UPDATE arm.
  if v_unified then
    perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for update;
  else
    perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for share;
  end if;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  select coalesce(array_agg(main_ship_id order by created_at), '{}')
    into v_members
    from public.main_ship_instances
   where group_id = v_group and player_id = v_player;
  if array_length(v_members, 1) is null then
    return jsonb_build_object('ok', false, 'reason', 'empty_group');
  end if;

  -- FLEET-CONTROL (0204): the ONE marked command-ship hunk. DARK — skipped (v_fleet_control false) → 0199
  -- behavior. LIT — a fleet with zero command ships is INACTIVE and cannot hunt: reject before the
  -- destination/readiness reads (the fleet's own property).
  if v_fleet_control then
    if not exists (
      select 1 from public.main_ship_instances
       where group_id = v_group and player_id = v_player and is_command_ship
    ) then
      return jsonb_build_object('ok', false, 'reason', 'fleet_inactive_no_command');
    end if;
  end if;

  select l.id, l.x, l.y, l.activity_type, l.status, l.zone_id, l.min_power_required, z.sector_id
    into v_loc
    from locations l join zones z on z.id = l.zone_id
    where l.id = p_location;
  if v_loc.id is null or v_loc.status <> 'active' or v_loc.activity_type is distinct from 'hunt_pirates' then
    return jsonb_build_object('ok', false, 'reason', 'invalid_location');
  end if;

  select count(*) into v_locked from (
    select main_ship_id from public.main_ship_instances
     where main_ship_id = any(v_members) and player_id = v_player
     for update
  ) locked;
  if v_locked <> array_length(v_members, 1) then
    return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
  end if;

  -- HUNT-UNI (0214) HUNK C: lit only — the hunt CONSUMES the settled unified fleet; readiness IS
  -- the fleet. Dark skips straight to the head's readiness, so the head's flow is untouched.
  -- Composes the 0213 leaf (ship_group_resolve_fleet) with ONE scan that counts and captures (one
  -- READ COMMITTED snapshot — the 0213 Finding-3 rule: never count in one statement and re-select
  -- in another). Policy over the rows:
  --   >1 → fleet_ambiguous (fail closed — the mover/brake/0213 token for this broken invariant);
  --   =1 moving/returning → group_fleet_in_flight (the mover's guard-8 twin: no hunt during a go);
  --   =1 settled → capture the origin FROM THE FLEET, consume it terminally, mint (below);
  --   =0 → fall through — the head's arms run VERBATIM (bootstrap parity: a pre-first-go group
  --        still carries per-ship dock shapes and the 0199 lit arm is the right reader for them).
  if v_unified then
    v_gf_n := 0;
    for v_gf in select * from public.ship_group_resolve_fleet(v_player, v_group) loop
      v_gf_n := v_gf_n + 1;
    end loop;
    if v_gf_n > 1 then
      -- Two live group-shaped fleets is the broken invariant this migration exists to prevent —
      -- never mint a third on top of it. Same fail-closed token as the mover/brake/assign guard.
      return jsonb_build_object('ok', false, 'reason', 'fleet_ambiguous');
    end if;
    if v_gf_n = 1 then
      if v_gf.status in ('moving', 'returning') then
        -- The group's ONE fleet is under way (a go in flight, or a sortie leg flying). A hunt is a
        -- commitment from a settled position, not a redirect of a live leg — fail closed. NOTE this
        -- status read alone is NOT the mover's guard-8 twin — guard 8 (0208:332-343) reads the
        -- MANIFEST; the manifest read is the NEXT arm, and the two arms together are the twin.
        return jsonb_build_object('ok', false, 'reason', 'group_fleet_in_flight');
      end if;

      -- AN OPEN SORTIE IS NEVER CONSUMABLE (the 0214 review's F1 — HIGH). A hunt's sortie fleet
      -- sits 'present' AT ITS HUNT SITE for the whole encounter (0169's race pin says it in words:
      -- 'present' = MID-COMBAT), so the status arm above waves it through — and "consuming" it
      -- would presence_complete the LIVE encounter's presence and complete the fleet under it,
      -- then the escape/extract tick (0169:210-230) runs fleet_set_returning on a completed
      -- fleet: a wedged encounter raising every tick, or a resurrected 'returning' fleet → v_n=2
      -- → the map blackout this migration exists to kill, re-minted by its own consume. The dark
      -- head rejected this for free (members read 'hunting' → member_not_ready); the lit hp-only
      -- readiness removed that guard, and THIS is its replacement — the mover's guard-8 manifest
      -- read, with 0213's token and posture (0213:250-268: a sortie is a frozen-roster
      -- commitment; nothing joins it, nothing consumes it). v_gf is live by the leaf's
      -- definition, so ANY manifest row on it IS an open sortie (finished fleets are outside the
      -- leaf's status set).
      if exists (select 1 from public.group_sortie_members where fleet_id = v_gf.id) then
        return jsonb_build_object('ok', false, 'reason', 'group_on_sortie');
      end if;

      -- SETTLED. The per-ship home/stationary readiness is deliberately NOT read here: the unified
      -- mover writes no ship rows (§2), so those signals are stale echoes of the retired layer —
      -- the settled fleet IS the readiness. What survives is the hp > 0 check: lifecycle, not
      -- movement (the same split step 4c preserves when it narrows the status column).
      select count(*) into v_not_home
        from public.main_ship_instances
        where main_ship_id = any(v_members) and hp <= 0;
      if v_not_home > 0 then
        return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
      end if;

      -- TRANSITION GUARD (the 0214 review's F2 — delete me at step 4 alongside the mover's guard 7,
      -- 0208:315-330, whose read this composes verbatim). While the per-ship movers are still live,
      -- a member could be flying its OWN per-ship fleet; the hp-only readiness above would mint it
      -- 'hunting' and its per-ship leg would later settle present + active presence — a ship
      -- hunting AND docked at once (§0 through a third door). The dark head rejects this via its
      -- status readiness ('traveling'/'returning' are neither home nor docked); the lit consume
      -- path must therefore carry the mover's own guard. One bounded count over fleets.
      select count(*) into v_busy
        from public.fleets f
       where f.player_id = v_player
         and f.main_ship_id = any(v_members)
         and f.status in ('moving', 'returning');
      if v_busy > 0 then
        return jsonb_build_object('ok', false, 'reason', 'member_busy');
      end if;

      -- Active-fleet limit EXCLUDING the fleet being consumed below AND the members' own present
      -- fleets (both are dissolved by this call — the head's launch-branch budget idiom, 0204:630-637,
      -- with the consumed unified fleet excluded on top: the sortie replaces them all, one slot net).
      v_max := coalesce(cfg_num('max_active_fleets'), 3);
      select count(*) into v_active
        from fleets
        where player_id = v_player and status in ('moving','present','returning')
          and id <> v_gf.id
          and (main_ship_id is null or not (main_ship_id = any(v_members)));
      if v_active >= v_max then
        return jsonb_build_object('ok', false, 'reason', 'fleet_limit_reached');
      end if;

      -- Team stats over the LOCKED members (the 0168 fold verbatim; raises → stats_invalid).
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
      if v_power < coalesce(v_loc.min_power_required, 0) then
        return jsonb_build_object('ok', false, 'reason', 'power_below_required');
      end if;

      -- origin_base anchors the return-to-base mechanics — the escape/extract tick reads
      -- origin_base_id off the sortie fleet (0169:217-228) on EVERY sortie, which is why the head
      -- rejects no_home_base on every mint path and why this select cannot move into the anchor
      -- arm alone (a present/space sortie with a NULL anchor would strand the escape tick).
      -- The HEAD's OWN select, verbatim (0204:657-659): plain first-active-base, NO preference for
      -- the consumed fleet's origin_base_id — the 0214 review's F3: a preference on a STALE anchor
      -- (base no longer active) dead-ends every consuming hunt even when other active bases exist.
      select id, x, y, sector_id into v_base
        from bases where player_id = v_player and status = 'active'
        order by created_at limit 1;
      if v_base.id is null then
        return jsonb_build_object('ok', false, 'reason', 'no_home_base');
      end if;

      -- ── THE ORIGIN, FROM THE FLEET (the mover's three settled arms, 0208:430-461, read the same
      --    way): present@port → the port; parked → the fleet's own coordinate; else its anchor. ──
      if v_gf.status = 'present' and v_gf.current_location_id is not null then
        select l.id, l.x, l.y, l.zone_id into v_gfl
          from locations l where l.id = v_gf.current_location_id;
        if v_gfl.id is null then
          return jsonb_build_object('ok', false, 'reason', 'invalid_origin');
        end if;
        v_o_type := 'location'; v_o_base := null; v_o_zone := v_gfl.zone_id; v_o_loc := v_gfl.id;
        v_o_x := v_gfl.x; v_o_y := v_gfl.y;
        -- the return port defaults to the port the fleet sails from (the 0199 launch-branch rule).
        v_return := coalesce(p_return_location_id, v_gf.current_location_id);
      elsif v_gf.location_mode = 'space' then
        -- Parked in open space (0208/0209) — depart the fleet's OWN coordinate. No port origin, so
        -- the return port is only what the caller chose (NULL → the reconciler's re-home path,
        -- exactly as the 0168 head's fleets carry no return_location_id).
        v_o_type := 'space'; v_o_base := null; v_o_zone := null; v_o_loc := null;
        v_o_x := v_gf.space_x; v_o_y := v_gf.space_y;
        v_return := p_return_location_id;
      else
        -- Idle at its anchor (the mover's fall-through place, 0208:447-461): depart the base.
        v_o_type := 'base'; v_o_base := v_base.id; v_o_zone := null; v_o_loc := null;
        v_o_x := v_base.x; v_o_y := v_base.y;
        v_return := p_return_location_id;
      end if;

      -- ── WRITES (all-or-nothing) ────────────────────────────────────────────────────────────────
      -- Dissolve each member's OWN present fleet FIRST — the head's dissolve block (0204:664-676),
      -- composed verbatim, exactly as the mover composes it at every go (0208:496-520). This is NOT
      -- vestigial in the consuming path: 0213's co-location arm ALLOWS assigning a docked ship into
      -- a group whose fleet is present at the SAME port, and that assignee KEEPS its own per-ship
      -- present fleet + active presence (0213 chose guard-assignment over dissolve-at-assignment).
      -- A sortie that left that pair active would be a ship hunting AND docked at once — §0's
      -- ghost-dock duality through the hunt's own front door.
      perform presence_complete(lp.id)
        from public.fleets f
        join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
        where f.player_id = v_player and f.main_ship_id = any(v_members) and f.status = 'present';
      update public.fleets
        set status = 'completed', location_mode = 'movement', active_movement_id = null,
            current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
            updated_at = now()
        where player_id = v_player and main_ship_id = any(v_members) and status = 'present';

      -- CONSUME the settled fleet: close its dock presence and complete it — the mover's own
      -- release idiom (0208:549-557), made TERMINAL ('completed', not 'idle') because the hunt
      -- mints a NEW fleet below. The old fleet is terminal before the new one exists, in the same
      -- transaction: at-most-one live group-shaped fleet is restored BY CONSTRUCTION, and no
      -- presence is orphaned (§0's ghost-dock class — asserted by HUNTUNI_PASS_NOGHOSTDOCK).
      perform presence_complete(lp.id)
        from public.location_presence lp
        where lp.fleet_id = v_gf.id and lp.status = 'active';
      update public.fleets
        set status = 'completed', location_mode = 'movement', active_movement_id = null,
            space_x = null, space_y = null,
            current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
            updated_at = now()
        where id = v_gf.id;

      -- ONE team fleet (main_ship_id NULL; members carried by the manifest) — the head's own mint,
      -- with the origin captured from the consumed fleet instead of a per-ship dock join.
      insert into fleets (player_id, origin_base_id, status, location_mode, current_base_id, group_id, return_location_id)
        values (v_player, v_base.id, 'idle', 'base', v_base.id, v_group, v_return)
        returning id into v_fleet;

      v_movement := movement_create(
        v_player, v_fleet,
        v_o_type, v_o_base, v_o_zone, v_o_loc, v_o_x, v_o_y,
        'location', null, null, v_loc.id, v_loc.x, v_loc.y,
        'hunt_pirates', v_speed);
      perform fleet_set_moving(v_fleet, v_movement);

      -- (CI-corrected: this write is HEAD-VERBATIM — no hunk. An earlier draft deleted
      -- spatial_state/space_x/space_y from this SET, reasoning 0221 already stopped every live
      -- READ from consulting them. That ignored the WRITE-side 0055 CHECK coupling
      -- (main_ship_instances_ss_at_location_status: spatial_state='at_location' ⟹
      -- status='stationary') — a docked member (3 such ships in prod carry spatial_state=
      -- 'at_location' today) launching a hunt would write status='hunting' while spatial_state
      -- stayed 'at_location', violating the CHECK and aborting the hunt. The disposable-Postgres
      -- apply-proof caught this for real. status='hunting' is KEPT verbatim (the sortie/combat
      -- layer's own signal — 0199 reconciler + shield-regen exclusion read it — NOT the movement
      -- layer §2 retires; IT RETIRES AT STEP 4c with the status-column narrowing).
      update main_ship_instances
        set status = 'hunting', spatial_state = null, space_x = null, space_y = null, updated_at = now()
        where main_ship_id = any(v_members);

      insert into group_sortie_members (fleet_id, main_ship_id, player_id)
        select v_fleet, m, v_player from unnest(v_members) as m;

      select arrive_at into v_arrive from fleet_movements where id = v_movement;
      return jsonb_build_object(
        'ok', true, 'group_id', v_group, 'fleet_id', v_fleet, 'movement_id', v_movement,
        'arrive_at', v_arrive, 'member_count', array_length(v_members, 1), 'return_location_id', v_return);
    end if;
    -- v_gf_n = 0 → fall through: the head's readiness + launch arms run VERBATIM (bootstrap parity).
  end if;

  -- Readiness UNDER the locks. NOHOME (0199): the ONE marked readiness hunk. DARK — the 0168 check
  -- verbatim (EVERY member status='home' AND hp>0). LIT — a member is ready if home OR DOCKED
  -- (the settled-safe pair) AND hp>0; a docked team is checked for a common port in the launch branch.
  if v_launch_from_dock then
    -- ── ★ 4C-MIG-2A HUNK B5-b: "docked" is no longer the ship's own status='stationary'/         ★ ──
    -- ── ★ spatial_state='at_location' pair — it is FLEET TRUTH, mirroring 0221 R1-f: the ship's  ★ ──
    -- ── ★ ONE resolved fleet (mainship_resolve_fleet — by this point Hunk C above already proved ★ ──
    -- ── ★ v_gf_n = 0 for this group, so the resolver's transition fallback answers the member's  ★ ──
    -- ── ★ own per-ship fleet, the exact row the retired predicate implicitly keyed on — see the  ★ ──
    -- ── ★ file-header "WHY mainship_resolve_fleet IS THE RIGHT COMPOSE HERE" note) is 'present'   ★ ──
    -- ── ★ at a location with a matching active presence. The retired ship columns still exist   ★ ──
    -- ── ★ but are no longer consulted here (0221 already stopped every live READ from doing so). ★ ──
    select count(*) into v_not_home
      from public.main_ship_instances s
      where s.main_ship_id = any(v_members)
        and (not (s.status = 'home' or exists (
               select 1 from public.fleets f
               where f.id = public.mainship_resolve_fleet(s.main_ship_id)
                 and f.status = 'present' and f.location_mode = 'location'
                 and f.current_location_id is not null and f.active_movement_id is null
                 and exists (
                   select 1 from public.location_presence lp
                    where lp.fleet_id = f.id and lp.status = 'active'
                      and lp.location_id = f.current_location_id)
             )) or s.hp <= 0);
  else
    select count(*) into v_not_home
      from public.main_ship_instances
      where main_ship_id = any(v_members) and (status <> 'home' or hp <= 0);
  end if;
  if v_not_home > 0 then
    return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
  end if;

  -- ── NOHOME (0199) LAUNCH-FROM-DOCK BRANCH — the whole team launches as ONE fleet from its port ──────
  -- Triggers ONLY when the flag is lit AND at least one member is docked. A docked team must be gathered
  -- at ONE port (else member_not_ready — the same all-or-nothing posture the move-team gate uses, 0190).
  -- The members' own present fleets are dissolved (they leave to fly with the team); the ONE new team
  -- fleet departs from the common port; origin_base_id stays the legacy base so the escape tick's
  -- return-to-base mechanics (process_combat_ticks 0169:217-228 — UNTOUCHED) still work, and the chosen
  -- (or origin) return port is recorded so the reconciler docks the team there instead of re-homing.
  -- (N2) count docked members ONLY when lit — the DARK path never touches this (v_docked stays NULL and
  -- the short-circuit `v_launch_from_dock and …` below never evaluates it).
  if v_launch_from_dock then
    -- ── ★ 4C-MIG-2A HUNK B5-c: the same fleet-truth docked predicate as Hunk B5-b, counted here. ★ ──
    select count(*) into v_docked
      from public.main_ship_instances s
      where s.main_ship_id = any(v_members)
        and exists (
          select 1 from public.fleets f
          where f.id = public.mainship_resolve_fleet(s.main_ship_id)
            and f.status = 'present' and f.location_mode = 'location'
            and f.current_location_id is not null and f.active_movement_id is null
            and exists (
              select 1 from public.location_presence lp
               where lp.fleet_id = f.id and lp.status = 'active'
                 and lp.location_id = f.current_location_id)
        );
  end if;

  if v_launch_from_dock and v_docked > 0 then
    -- EVERY member must be docked at ONE common port (a mixed home/docked team, or a split-port team,
    -- is not a coherent single-origin launch → member_not_ready).
    if v_docked <> array_length(v_members, 1) then
      return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
    end if;
    -- ── ★ 4C-MIG-2A HUNK B5-d: the common-port check no longer joins the fleet on the ship's OWN ★ ──
    -- ── ★ main_ship_id column (`f.main_ship_id = s.main_ship_id`) — it resolves the ship's ONE   ★ ──
    -- ── ★ fleet through the resolver (same reasoning as Hunk B5-b) and reads the port FROM THE   ★ ──
    -- ── ★ FLEET (f.current_location_id), never a ship column. Identical fleet row either way on  ★ ──
    -- ── ★ every reachable state today (see the file-header note) — inert on real data, but it    ★ ──
    -- ── ★ stops being a ship-column read going forward.                                          ★ ──
    select count(distinct f.current_location_id) into v_dockcount
      from public.main_ship_instances s
      join public.fleets f on f.id = public.mainship_resolve_fleet(s.main_ship_id)
                           and f.player_id = v_player and f.status = 'present'
                           and f.location_mode = 'location' and f.current_location_id is not null
                           and f.active_movement_id is null
      join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
                                       and lp.location_id = f.current_location_id
      where s.main_ship_id = any(v_members);
    if v_dockcount is distinct from 1 then
      return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
    end if;
    -- the ONE common port + its coordinates (distinct count proved a single location above); read
    -- FROM THE FLEET (f.current_location_id / current_zone_id), not the presence row.
    select f.current_location_id as location_id, f.current_zone_id as zone_id, l.x, l.y, z.sector_id
      into v_cur
      from public.main_ship_instances s
      join public.fleets f on f.id = public.mainship_resolve_fleet(s.main_ship_id)
                           and f.player_id = v_player and f.status = 'present'
                           and f.location_mode = 'location' and f.current_location_id is not null
                           and f.active_movement_id is null
      join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
                                       and lp.location_id = f.current_location_id
      join public.locations l on l.id = f.current_location_id
      join public.zones z on z.id = l.zone_id
      where s.main_ship_id = any(v_members)
      limit 1;
    v_dock_loc := v_cur.location_id;
    v_return   := coalesce(p_return_location_id, v_dock_loc);

    -- Active-fleet limit EXCLUDING the members' own present fleets (they are dissolved below; the team
    -- consumes ONE slot net — the 0168/0019 shared-budget idiom, adjusted for the dissolve).
    v_max := coalesce(cfg_num('max_active_fleets'), 3);
    select count(*) into v_active
      from fleets
      where player_id = v_player and status in ('moving','present','returning')
        and (main_ship_id is null or not (main_ship_id = any(v_members)));
    if v_active >= v_max then
      return jsonb_build_object('ok', false, 'reason', 'fleet_limit_reached');
    end if;

    -- Team stats over the LOCKED members (the 0168 fold verbatim; raises → stats_invalid envelope).
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
    if v_power < coalesce(v_loc.min_power_required, 0) then
      return jsonb_build_object('ok', false, 'reason', 'power_below_required');
    end if;

    -- origin_base anchors the return-to-base mechanics (the escape tick reads origin_base_id).
    select id, x, y, sector_id into v_base
      from bases where player_id = v_player and status = 'active'
      order by created_at limit 1;
    if v_base.id is null then
      return jsonb_build_object('ok', false, 'reason', 'no_home_base');
    end if;

    -- ── WRITES (all-or-nothing) ─────────────────────────────────────────────────────────────────────
    -- Dissolve each docked member's OWN present fleet: close its active presence and complete the fleet
    -- (the ship leaves the dock to fly with the team). fleet_complete requires 'returning', so this is a
    -- direct completed-write (the dock had no movement).
    perform presence_complete(lp.id)
      from public.fleets f
      join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
      where f.player_id = v_player and f.main_ship_id = any(v_members) and f.status = 'present';
    update public.fleets
      set status = 'completed', location_mode = 'movement', active_movement_id = null,
          current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
          updated_at = now()
      where player_id = v_player and main_ship_id = any(v_members) and status = 'present';

    -- ONE team fleet (main_ship_id NULL; members carried by the manifest) tagged with the group, origin
    -- the legacy base (return mechanics) + the recorded return port.
    insert into fleets (player_id, origin_base_id, status, location_mode, current_base_id, group_id, return_location_id)
      values (v_player, v_base.id, 'idle', 'base', v_base.id, v_group, v_return)
      returning id into v_fleet;

    -- Depart from the COMMON DOCKED PORT (origin_type='location', the port coordinates), mission
    -- 'hunt_pirates' — NOT from the (0,0) base.
    v_movement := movement_create(
      v_player, v_fleet,
      'location', null, v_cur.zone_id, v_dock_loc, v_cur.x, v_cur.y,
      'location', null, null, v_loc.id, v_loc.x, v_loc.y,
      'hunt_pirates', v_speed);
    perform fleet_set_moving(v_fleet, v_movement);

    -- (CI-corrected: HEAD-VERBATIM, same reasoning as the first departure write above.)
    update main_ship_instances
      set status = 'hunting', spatial_state = null, space_x = null, space_y = null, updated_at = now()
      where main_ship_id = any(v_members);

    insert into group_sortie_members (fleet_id, main_ship_id, player_id)
      select v_fleet, m, v_player from unnest(v_members) as m;

    select arrive_at into v_arrive from fleet_movements where id = v_movement;
    return jsonb_build_object(
      'ok', true, 'group_id', v_group, 'fleet_id', v_fleet, 'movement_id', v_movement,
      'arrive_at', v_arrive, 'member_count', array_length(v_members, 1), 'return_location_id', v_return);
  end if;

  -- ── 0168 HEAD (DARK path — byte-identical to send_ship_group_hunt 0168:226-312) ─────────────────────
  v_max := coalesce(cfg_num('max_active_fleets'), 3);
  select count(*) into v_active
    from fleets where player_id = v_player and status in ('moving','present','returning');
  if v_active >= v_max then
    return jsonb_build_object('ok', false, 'reason', 'fleet_limit_reached');
  end if;

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

  if v_power < coalesce(v_loc.min_power_required, 0) then
    return jsonb_build_object('ok', false, 'reason', 'power_below_required');
  end if;

  select id, x, y, sector_id into v_base
    from bases where player_id = v_player and status = 'active'
    order by created_at limit 1;
  if v_base.id is null then
    return jsonb_build_object('ok', false, 'reason', 'no_home_base');
  end if;

  insert into fleets (player_id, origin_base_id, status, location_mode, current_base_id, group_id)
    values (v_player, v_base.id, 'idle', 'base', v_base.id, v_group)
    returning id into v_fleet;

  v_movement := movement_create(
    v_player, v_fleet,
    'base', v_base.id, null, null, v_base.x, v_base.y,
    'location', null, null, v_loc.id, v_loc.x, v_loc.y,
    'hunt_pirates', v_speed);
  perform fleet_set_moving(v_fleet, v_movement);

  -- (CI-corrected: HEAD-VERBATIM — this is the 0168 dark path, byte-identical to the head; it was
  -- never supposed to carry a hunk at all.)
  update main_ship_instances
    set status = 'hunting', spatial_state = null, space_x = null, space_y = null, updated_at = now()
    where main_ship_id = any(v_members);

  insert into group_sortie_members (fleet_id, main_ship_id, player_id)
    select v_fleet, m, v_player from unnest(v_members) as m;

  select arrive_at into v_arrive from fleet_movements where id = v_movement;
  return jsonb_build_object(
    'ok', true, 'group_id', v_group, 'fleet_id', v_fleet, 'movement_id', v_movement,
    'arrive_at', v_arrive, 'member_count', array_length(v_members, 1));
end;
$$;
revoke execute on function public.send_ship_group_hunt(uuid, uuid, uuid) from public, anon;
grant  execute on function public.send_ship_group_hunt(uuid, uuid, uuid) to authenticated;

-- ═══════════ §7. re-derive the 0214 self-assert's own carried-forward checks (deploy-time, ═══════
-- ═══════════ raises on failure): the 0204/0214 heads survive verbatim except the marked hunks. ═══
do $huntuni_carry$
declare
  v_src   text;
begin
  select prosrc into v_src from pg_proc where oid = 'public.send_ship_group_hunt(uuid, uuid, uuid)'::regprocedure;
  if v_src is null then raise exception '4C-MIG-2A self-assert FAIL: send_ship_group_hunt(uuid,uuid,uuid) not deployed'; end if;
  -- PROSRC-ASSERT COUPLING (0221's lesson): strip `--` line comments before probing, so a hunk
  -- comment that NAMES a retired literal (to explain its removal) can never trip its own ban.
  v_src := regexp_replace(v_src, '--[^\n]*', '', 'g');
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'send_ship_group_hunt') <> 1 then
    raise exception '4C-MIG-2A self-assert FAIL: send_ship_group_hunt is not a single definition'; end if;
  if not has_function_privilege('authenticated', 'public.send_ship_group_hunt(uuid, uuid, uuid)', 'execute') then
    raise exception '4C-MIG-2A self-assert FAIL: send_ship_group_hunt not authenticated-executable'; end if;

  -- the 0204/0214 heads survive: fleet-control gate, NOHOME gate, the 0168 dark insert, Hunk-C
  -- tokens (leaf compose + all three reject tokens + the manifest read + the hp-only check).
  if position('v_fleet_control boolean := public.cfg_bool(''fleet_control_enabled'')' in v_src) = 0
     or position('fleet_inactive_no_command' in v_src) = 0
     or position('v_launch_from_dock boolean := public.cfg_bool(''launch_from_dock_enabled'')' in v_src) = 0
     or position('insert into fleets (player_id, origin_base_id, status, location_mode, current_base_id, group_id)' in v_src) = 0
     or position('v_unified boolean := public.cfg_bool(''fleet_movement_unified_enabled'')' in v_src) = 0
     or position('ship_group_resolve_fleet' in v_src) = 0
     or position('fleet_ambiguous' in v_src) = 0
     or position('group_fleet_in_flight' in v_src) = 0
     or position('group_on_sortie' in v_src) = 0
     or position('member_busy' in v_src) = 0
     -- the manifest write + the dark-path hp-only settle — REAL code tokens (survive the comment
     -- strip above). The prior marker probed a phrase that lived ONLY in a comment, so after the
     -- strip it was always absent and this block aborted every deploy (adversarial-review finding).
     or position('insert into group_sortie_members (fleet_id, main_ship_id, player_id)' in v_src) = 0
     or position('status <> ''home'' or hp <= 0' in v_src) = 0 then
    raise exception '4C-MIG-2A self-assert FAIL: the 0204/0214 head did not survive intact'; end if;

  -- ── THE b5 REPOINT ITSELF: the retired ship-column predicate is GONE, and the fleet-truth ──────
  -- ── compose LANDED, in both readiness sites + the common-port join. ─────────────────────────────
  if position('status = ''stationary'' and spatial_state = ''at_location''' in v_src) > 0 then
    raise exception '4C-MIG-2A self-assert FAIL: send_ship_group_hunt still reads the retired status=stationary/spatial_state=at_location pair — the b5 repoint did not land'; end if;
  if position('f.main_ship_id = s.main_ship_id and f.player_id = v_player and f.status = ''present''' in v_src) > 0 then
    raise exception '4C-MIG-2A self-assert FAIL: the common-port check still joins on the ship''s own main_ship_id column — the b5 repoint did not land'; end if;
  if (length(v_src) - length(replace(v_src, 'f.id = public.mainship_resolve_fleet(s.main_ship_id)', ''))) / length('f.id = public.mainship_resolve_fleet(s.main_ship_id)') < 3 then
    raise exception '4C-MIG-2A self-assert FAIL: send_ship_group_hunt does not compose mainship_resolve_fleet at all three fleet-truth sites (readiness + docked-count + common-port)'; end if;
  if position('f.current_location_id as location_id' in v_src) = 0 then
    raise exception '4C-MIG-2A self-assert FAIL: the common-port select no longer reads the port FROM THE FLEET'; end if;

  -- the three departure writes survive HEAD-VERBATIM (CI-corrected — the 0214 (e) check,
  -- RETARGETED: an earlier draft dropped the spatial clears from these writes, which is a genuine
  -- CHECK-constraint hazard (main_ship_instances_ss_at_location_status — see the file header), not
  -- a repoint. This asserts the ORIGINAL head shape is intact in EXACTLY the 3 mint paths.
  if (length(v_src) - length(replace(v_src,
        'set status = ''hunting'', spatial_state = null, space_x = null, space_y = null, updated_at = now()', ''))
     ) / length('set status = ''hunting'', spatial_state = null, space_x = null, space_y = null, updated_at = now()') <> 3 then
    raise exception '4C-MIG-2A self-assert FAIL: expected the HEAD-VERBATIM status=hunting write (with its spatial clears intact) in exactly 3 mint paths — a departure write must never leave spatial_state set while status leaves ''stationary'' (the 0055 CHECK coupling)'; end if;

  raise notice '4C-MIG-2A self-assert ok (send_ship_group_hunt): 0204/0214 heads intact; the retired ship-column docked predicate and ship-column port join are BOTH gone; mainship_resolve_fleet composed at all 3 fleet-truth sites; all 3 departure writes are HEAD-VERBATIM (status=hunting + the required spatial clears, CHECK-safe)';
end $huntuni_carry$;

-- ═══════════ §8. per-function repoint self-asserts (deploy-time, raises on failure): each host ══
-- ═══════════ is proven re-created from its TRUE head with ONLY the marked hunk. ══════════════════
do $repoint_writers$
declare
  v_src text;
begin
  -- a1: mainship_space_lock_context — the coordinate-movement rowtype/lock/return-key are gone;
  -- the surviving locks + has_active_legacy_movement are still present (byte-parity on the rest).
  select prosrc into v_src from pg_proc where oid = 'public.mainship_space_lock_context(uuid, boolean)'::regprocedure;
  if v_src is null then raise exception '4C-MIG-2A self-assert FAIL: mainship_space_lock_context(uuid,boolean) not deployed'; end if;
  -- PROSRC-ASSERT COUPLING (0221's lesson): strip `--` line comments before probing, so a hunk
  -- comment that NAMES a retired literal (to explain its removal) can never trip its own ban.
  v_src := regexp_replace(v_src, '--[^\n]*', '', 'g');
  if position('select * into v_mv from main_ship_space_movements' in v_src) > 0 then
    raise exception '4C-MIG-2A self-assert FAIL: mainship_space_lock_context still declares/reads the coordinate-movement rowtype'; end if;
  if position('space_movement''' in v_src) > 0 then
    raise exception '4C-MIG-2A self-assert FAIL: mainship_space_lock_context still returns the space_movement key'; end if;
  if position('has_active_legacy_movement' in v_src) = 0
     or position('for update skip locked' in v_src) = 0
     or position('relevant_fleet_id' in v_src) = 0 then
    raise exception '4C-MIG-2A self-assert FAIL: mainship_space_lock_context lost a surviving hunk (byte-parity broken beyond the marked delete)'; end if;
  if not has_function_privilege('service_role', 'public.mainship_space_lock_context(uuid, boolean)', 'execute')
     or has_function_privilege('authenticated', 'public.mainship_space_lock_context(uuid, boolean)', 'execute') then
    raise exception '4C-MIG-2A self-assert FAIL: mainship_space_lock_context ACL drifted (must stay service_role-only)'; end if;

  -- b1: port_entry_commission_build — the insert no longer mints spatial_state/space_x/space_y or
  -- the 'stationary' literal; the fleet/presence mint + final coherence gate survive verbatim.
  select prosrc into v_src from pg_proc where oid = 'public.port_entry_commission_build(uuid, text)'::regprocedure;
  if v_src is null then raise exception '4C-MIG-2A self-assert FAIL: port_entry_commission_build(uuid,text) not deployed'; end if;
  v_src := regexp_replace(v_src, '--[^\n]*', '', 'g');
  if position('spatial_state, space_x, space_y' in v_src) > 0 then
    raise exception '4C-MIG-2A self-assert FAIL: port_entry_commission_build still lists the retired columns in its insert'; end if;
  if position('''stationary'', ''at_location'', null, null,' in v_src) > 0 then
    raise exception '4C-MIG-2A self-assert FAIL: port_entry_commission_build still mints the retired stationary/at_location literal shape'; end if;
  if position('post-write state is not canonical at_location' in v_src) = 0
     or position('presence_create(p_player, v_fleet, v_sector, v_zone, c_haven, ''none'')' in v_src) = 0 then
    raise exception '4C-MIG-2A self-assert FAIL: port_entry_commission_build lost the fleet/presence mint or the final coherence gate'; end if;
  if has_function_privilege('authenticated', 'public.port_entry_commission_build(uuid, text)', 'execute')
     or has_function_privilege('anon', 'public.port_entry_commission_build(uuid, text)', 'execute') then
    raise exception '4C-MIG-2A self-assert FAIL: port_entry_commission_build became client-executable'; end if;

  -- b2: ensure_main_ship_for_player — UNCHANGED (§3 documents why). Pin that it still carries no
  -- status/spatial_state/space_x/space_y write, so a future edit cannot silently add one back
  -- without updating this migration's rationale.
  select prosrc into v_src from pg_proc where oid = 'public.ensure_main_ship_for_player(uuid)'::regprocedure;
  if v_src is null then raise exception '4C-MIG-2A self-assert FAIL: ensure_main_ship_for_player(uuid) not deployed'; end if;
  v_src := regexp_replace(v_src, '--[^\n]*', '', 'g');
  if position('spatial_state' in v_src) > 0 or position('space_x' in v_src) > 0 or position('space_y' in v_src) > 0 then
    raise exception '4C-MIG-2A self-assert FAIL: ensure_main_ship_for_player now mints a retired column — this migration''s "nothing to repoint" claim is stale, it needs a real hunk'; end if;

  -- b3: mainship_mark_combat_destroyed — UNCHANGED (§4 documents why: once the CHECK-required
  -- spatial clears are restored, this function has zero delta from its 0167 head). Pin that the
  -- head's FULL terminal write — status/hp AND the spatial clears TOGETHER — is still exactly what
  -- is deployed, so a future edit cannot silently drop the clears again without updating this
  -- migration's rationale (the exact regression the disposable-Postgres apply-proof caught).
  select prosrc into v_src from pg_proc where oid = 'public.mainship_mark_combat_destroyed(uuid)'::regprocedure;
  if v_src is null then raise exception '4C-MIG-2A self-assert FAIL: mainship_mark_combat_destroyed(uuid) not deployed'; end if;
  v_src := regexp_replace(v_src, '--[^\n]*', '', 'g');
  if position('status = ''destroyed'', hp = 0, spatial_state = null, space_x = null, space_y = null' in v_src) = 0 then
    raise exception '4C-MIG-2A self-assert FAIL: mainship_mark_combat_destroyed no longer matches its 0167 head (the destroyed/hp=0 write and its CHECK-required spatial clears must land together)'; end if;

  -- b4: repair_main_ship — the launch-from-dock branch no longer mints the retired 'stationary'/
  -- 'at_location' shape (SET or return jsonb), but spatial_state IS still written — co-changed to
  -- null (CHECK-required: status now leaves 'stationary', so spatial_state may no longer be
  -- 'at_location') — and space_x/space_y=null survive verbatim. The dark 0081 head is untouched.
  select prosrc into v_src from pg_proc where oid = 'public.repair_main_ship(uuid)'::regprocedure;
  if v_src is null then raise exception '4C-MIG-2A self-assert FAIL: repair_main_ship(uuid) not deployed'; end if;
  v_src := regexp_replace(v_src, '--[^\n]*', '', 'g');
  if position('spatial_state=''at_location''' in v_src) > 0 or position('spatial_state = ''at_location''' in v_src) > 0 then
    raise exception '4C-MIG-2A self-assert FAIL: repair_main_ship still mints the retired at_location shape'; end if;
  if position('''status'', ''stationary''' in v_src) > 0 then
    raise exception '4C-MIG-2A self-assert FAIL: repair_main_ship still returns the retired stationary literal'; end if;
  if position('status = ''home'', spatial_state = null' in v_src) = 0 then
    raise exception '4C-MIG-2A self-assert FAIL: repair_main_ship lost the CHECK-required spatial_state=null co-change (status now leaves ''stationary'' — leaving spatial_state=''at_location'' would violate main_ship_instances_ss_at_location_status)'; end if;
  if position('space_x = null, space_y = null' in v_src) = 0 then
    raise exception '4C-MIG-2A self-assert FAIL: repair_main_ship lost the space_x/space_y=null clear on the docked-revival branch'; end if;
  if position('set hp = v_ship.max_hp, status = ''home'', updated_at = now()' in v_src) = 0 then
    raise exception '4C-MIG-2A self-assert FAIL: repair_main_ship lost the 0081 dark home restore'; end if;
  if not has_function_privilege('authenticated', 'public.repair_main_ship(uuid)', 'execute') then
    raise exception '4C-MIG-2A self-assert FAIL: repair_main_ship not authenticated-executable (safelock broken)'; end if;

  raise notice '4C-MIG-2A self-assert ok (a1/b1/b2/b3/b4): a1/b1/b4 re-created from their true heads with only the marked (constraint-legal) hunk; b2/b3 confirmed to need no re-create; ACLs unchanged';
end $repoint_writers$;

-- ═══════════ §9. THE HIGH-RISK PROOF: reconcile the b5 fleet-truth "docked" predicate against ════
-- ═══════════ EVERY REAL SHIP ROW the retired predicate could ever have judged, at apply time. ═════
-- Scope of the comparison (matches EXACTLY the domain Hunks B5-b/B5-c/B5-d can reach — see the
-- file-header "WHY mainship_resolve_fleet IS THE RIGHT COMPOSE HERE" note): a ship whose group (if
-- any) carries NO live unified (main_ship_id IS NULL) fleet — the ONLY state under which
-- send_ship_group_hunt's readiness/launch code (as opposed to Hunk C) ever runs for it. Ships
-- outside that domain (a live group-shaped fleet exists) are Hunk C's territory, unchanged by this
-- migration and already proven by the 0214 TEAMHUNT/HUNTUNI runtime suites.
do $b5_reconcile$
declare
  r record;
  v_old boolean;
  v_new boolean;
  v_checked integer := 0;
  v_mismatches integer := 0;
  v_first_mismatch uuid;
begin
  for r in
    select s.main_ship_id, s.status, s.spatial_state, s.group_id
      from public.main_ship_instances s
     where s.status <> 'destroyed'
       and (
         s.group_id is null
         or not exists (
           select 1 from public.fleets gf
            where gf.group_id = s.group_id and gf.main_ship_id is null
              and gf.status in ('idle', 'moving', 'present', 'returning')
         )
       )
  loop
    v_checked := v_checked + 1;
    v_old := (r.status = 'stationary' and r.spatial_state = 'at_location');
    v_new := exists (
      select 1 from public.fleets f
       where f.id = public.mainship_resolve_fleet(r.main_ship_id)
         and f.status = 'present' and f.location_mode = 'location'
         and f.current_location_id is not null and f.active_movement_id is null
         and exists (
           select 1 from public.location_presence lp
            where lp.fleet_id = f.id and lp.status = 'active'
              and lp.location_id = f.current_location_id)
    );
    if v_old is distinct from v_new then
      v_mismatches := v_mismatches + 1;
      if v_first_mismatch is null then v_first_mismatch := r.main_ship_id; end if;
    end if;
  end loop;

  if v_mismatches > 0 then
    raise exception '4C-MIG-2A self-assert FAIL: the b5 fleet-truth docked predicate disagrees with the retired ship-column predicate on % of % real, in-scope ship row(s) — first mismatch %; the b5 repoint is NOT safe to deploy as written',
      v_mismatches, v_checked, v_first_mismatch;
  end if;

  raise notice '4C-MIG-2A self-assert ok (b5 fleet-truth reconciliation): % real in-scope ship row(s) checked, ZERO disagreement between the retired status/spatial_state predicate and the new fleet-truth predicate (mainship_resolve_fleet + present/location/presence)', v_checked;
end $b5_reconcile$;

-- ═══════════ §10. dual-safe re-confirmation: this migration dropped/altered NOTHING — the legacy ═
-- ═══════════ objects it stops WRITING to are still fully intact for 4c-mig-2b to remove later. ═══
do $dualsafe_out$
begin
  if to_regclass('public.main_ship_space_movements') is null then
    raise exception '4C-MIG-2A self-assert FAIL: main_ship_space_movements vanished — this migration must never drop it';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'main_ship_instances'
                    and column_name in ('spatial_state', 'space_x', 'space_y')
                  having count(*) = 3) then
    raise exception '4C-MIG-2A self-assert FAIL: a main_ship_instances legacy column vanished — this migration must never alter the table';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fleets' and column_name = 'active_space_movement_id') then
    raise exception '4C-MIG-2A self-assert FAIL: fleets.active_space_movement_id vanished — this migration must never alter the table';
  end if;
  raise notice '4C-MIG-2A self-assert ok (dual-safe): main_ship_space_movements + every legacy main_ship_instances/fleets column are fully intact — zero drop, zero alter, this migration is safe to apply strictly before 4c-mig-2b';
end $dualsafe_out$;
