-- 4C-MIG-1 — MOVEMENT-SIGNAL REPOINT (migration 0221): every LIVE read that still answered from the
-- retired per-ship movement signals (main_ship_space_movements, fleets.active_space_movement_id,
-- main_ship_instances.spatial_state/space_x/space_y) now answers from FLEET/BERTH truth instead.
--
-- Charter: docs/MOVEMENT_UNIFICATION_CHARTER.md §2 (the FLEET is the only mover; membership IS
-- position) + the legacy-movement retirement plan (4c). This is the FIRST, dual-safe half of the
-- retirement: the legacy objects all STILL EXIST after this migration — nothing is dropped or
-- altered here — but no re-created read consults them any more, so the LATER schema-drop migration
-- (4c-mig-2) can remove them without changing what any of these functions answer.
--
-- ─── ZERO DROPS / ZERO SCHEMA. ────────────────────────────────────────────────────────────────────
-- This file contains ONLY `create or replace function` re-creates + grants + a self-assert. If a
-- future edit adds DROP or ALTER TABLE to this file it belongs in 4c-mig-2, not here. The §0 gate
-- below ASSERTS the legacy objects still exist at apply time (the dual-safe contract stated as
-- code), and the fleetgo-proof selftest statically bans drop/alter in this file.
--
-- ─── THE ROOT B1 FIX (the headline outcome). ──────────────────────────────────────────────────────
-- A BERTHED ship (S1/0216: group_id NULL + berth_location_id set — prod's 68-ship majority after
-- the 0216 backfill) used to fall through the oracle's per-ship fallback to 'legacy_home', which
-- the settled-safe rules (fitting 0114:130-133, captain/decks/rooms via the 0121 leaf — accepted
-- set EXACTLY ('home','at_location')) REJECT. Docked at a port, yet not fittable: bug B1. After R1
-- below, a settled berthed ship answers state='home' — 0114-accepted — so berthed ships become
-- truly fit-eligible and the client's fitgate interim patch can be reverted.
--
-- WHY 'home' AND NOT 'at_location' for the berthed shape (verified against every live consumer):
-- every live host maps 'home' and 'legacy_home' to the SAME branch — get_my_current_dock_services /
-- get_my_docked_store (0211: both fall to 'incoherent_or_unavailable'), commission_first_main_ship
-- (0211:419 groups ('home','legacy_home')), mainship_resolve_docked_location (0210: both → NULL),
-- get_my_fleet_positions (both → hidden → the S1 berthed branch answers the berth) — EXCEPT the
-- settled-safe rules, which accept 'home' and reject 'legacy_home'. So berthed→'home' changes
-- EXACTLY ONE live behavior: the intended B1 flip. 'at_location' would additionally claim the
-- docked-fleet pairing (a resolvable present fleet + presence) that a berthed ship does not have.
-- Dock services AT the berth port are deliberately NOT lit here — mainship_resolve_docked_location
-- is not a 4c-mig-1 repoint target; that is a later, separate decision.
--
-- ─── THE SEVEN RE-CREATES (byte-parity discipline: each body is its TRUE head byte-for-byte with ──
-- ─── ONLY the marked hunks changed; the reviewer independently diffs body-vs-head). ───────────────
-- TRUE heads re-derived by grep over ALL migrations 2026-07-18 (this arc's inventory was wrong 8×;
-- the plan itself warns the charter inventory lied — TRUST THE CODE):
--   R1 mainship_space_validate_context        — TRUE head 0210:130-271 (0056 → 0210; no other).
--   R2 mainship_space_assert_cross_domain_exclusion — TRUE head 0056:224-268 (the ONLY definition).
--   R3 get_my_fleet_positions                 — TRUE head 0216:846 (0200→0211→0212→0216 chain;
--                                               0216's own TRUE-HEAD declaration; 0219 pledged it
--                                               byte-untouched, verified — 0219 re-creates only the
--                                               mover + dock verb).
--   R5a exploration_scan                      — TRUE head 0172:55 (0099→0100→0146→0172; the plan's
--                                               0146 pointer is STALE, as it itself records).
--   R5b mining_extract                        — TRUE head 0172:222 (0104→0137→0143→0172).
--   R5c process_exploration_securing          — TRUE head 0100:203 (the ONLY definition).
--   R5d process_mining_securing               — TRUE head 0105:40 (the ONLY definition).
-- R6 (commission writers stop minting stationary/at_location) is DEFERRED to 4c-mig-2 with the
-- status-CHECK narrow it belongs to — this migration is READ repoints only. The freshly-commissioned
-- shape (present per-ship fleet + presence) reads 'at_location' via FLEET truth below, so the
-- writers' ship-column mints become read-inert now and can be retired with the columns.
--
-- ★★ TRUE-HEAD DECLARATION — READ THIS BEFORE TOUCHING ANY OF THE SEVEN AGAIN ★★
-- As of this migration, THIS FILE is the TRUE head of all seven functions above. Any later
-- re-create MUST copy from 0221 — never from 0210/0056/0216/0172/0100/0105. Rebuilding from a
-- stale head is exactly how 0136 silently re-inlined the dock block (and how 0146/0143 silently
-- reverted 0100/0137 — the 0172 file header records the full post-mortem).
--
-- ─── COMPOSITION LAW (NO new formulas). ───────────────────────────────────────────────────────────
-- Every repoint composes an EXISTING live leaf: mainship_resolve_fleet (0210 — the ONE ship→fleet
-- resolver), fleet_current_position (0218 — S3's ONE fleet-position dispatch),
-- mainship_space_assert_settled_safe (0121 — the ONE settled-safe rule), and the S1 berth column
-- read (0216's berthed idiom: berth answers ONLY where the resolver has no fleet).
--
-- ─── PARITY MAP (prod ground truth, head 0217 census; every reachable shape, pre → post): ─────────
--   • berthed, status home, no per-ship fleet (68 ships)      legacy_home → home   ← THE B1 FIX;
--     every non-settled-safe host behaves identically (see the 'home' argument above).
--   • per-ship present fleet + matching presence (3 ships,
--     spatial 'at_location'/status stationary; also every
--     fresh commission and every live per-ship settle)        at_location → at_location (now proven
--     from the FLEET pair, not the ship column; the 0216:758 commission gate keeps passing).
--   • spatial-NULL ship with a present fleet + presence       legacy_present → at_location (the two
--     shapes are indistinguishable without the ship column; the fleet pair IS the docked truth.
--     ZERO such ships in prod — the 73 spatial-NULL ships are 68 home/fleetless + 2 orphans +
--     3 destroyed. Recorded as the one deliberate state-token merge in this file.)
--   • grouped member, unified fleet (docked/moving/parked)    unchanged — the 0210 unified branch
--     is retained verbatim (one marked sub-hunk: lifecycle 'destroyed' no longer also reads the
--     retired ship column — status is the ONE lifecycle signal).
--   • grouped ship whose group has NO unified fleet           legacy_home → legacy_home (the honest
--     transition token; still settled-UNSAFE — such a ship is nowhere).
--   • the 2 'traveling' orphans (berth set, no fleet)         ok:false → ok:false (the berth branch
--     demands a settled status; wreckage stays refused until the owner reset).
--   • destroyed (3 ships)                                     destroyed → destroyed.
--   • per-ship fleet in flight (moving/returning + leg)       legacy_transit → legacy_transit.
--   • spatial 'in_space'/'in_transit'/'home' shapes           ZERO in prod, minted ONLY by the
--     flag-OFF legacy movers → unreachable; branches deleted. in_space now exists ONLY as fleet
--     truth (the unified branch / location_mode='space').
--
-- CI: scripts/fleetgo-proof.sh selftest carries the REPOINT-PARITY static section (byte-diff pins
-- against each head, the zero-drop ban, the legacy-read bans); scripts/fleetgo-proof.sql carries
-- the REPOINT_PASS_* runtime markers (berthed / grouped / legacy-home / fitgate / parked-space
-- probes, each with vacuity RAISE guards). The §8 self-assert below re-proves the repoint on the
-- DEPLOYED bodies and on EVERY REAL SHIP ROW at apply time.

-- ── §0. dependency + dual-safe gate: the leaves this file composes must exist, and the legacy ─────
-- ──     objects must STILL exist (this migration must land strictly BEFORE 4c-mig-2). ─────────────
do $repoint0$
begin
  if to_regprocedure('public.mainship_resolve_fleet(uuid)') is null then
    raise exception '4C-MIG-1: mainship_resolve_fleet (0210) is missing — the repoint composes it';
  end if;
  if to_regprocedure('public.fleet_current_position(uuid, timestamptz)') is null then
    raise exception '4C-MIG-1: fleet_current_position (S3/0218) is missing — the repoint composes it';
  end if;
  if to_regprocedure('public.mainship_space_assert_settled_safe(uuid)') is null then
    raise exception '4C-MIG-1: mainship_space_assert_settled_safe (0121) is missing — the repoint composes it';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'main_ship_instances'
                    and column_name = 'berth_location_id') then
    raise exception '4C-MIG-1: main_ship_instances.berth_location_id (S1/0216) is missing — berth truth has no column';
  end if;
  -- the DUAL-SAFE contract: the legacy objects are intact at apply time. Their absence would mean
  -- 4c-mig-2 (or something worse) ran first and this file is being applied out of order.
  if to_regclass('public.main_ship_space_movements') is null then
    raise exception '4C-MIG-1: main_ship_space_movements is already gone — this migration must apply with the legacy schema intact (it repoints reads; 4c-mig-2 drops)';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fleets'
                    and column_name = 'active_space_movement_id')
     or not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'main_ship_instances'
                    and column_name = 'spatial_state') then
    raise exception '4C-MIG-1: a legacy pointer/state column is already gone — apply order broken (this file precedes the drops)';
  end if;
end $repoint0$;

-- ═══════════ §1. R1 — mainship_space_validate_context: the 0210:130 TRUE head, byte-copied, ═══════
-- ═══════════ with the marked repoint hunks ONLY. ═════════════════════════════════════════════════
-- The 0210 unified/group branch survives VERBATIM (one marked lifecycle sub-hunk). The 0056-head
-- per-ship fallback below it — the part that read the coordinate-movement table, the fleet's
-- coordinate pointer, and the ship's spatial column — is repointed onto the SAME fleet rows it
-- already read (fleets / location_presence / fleet_movements) plus the S1 berth column. Hunks:
--   R1-a  declares: the coordinate-movement rowtype, the spatial-state local, and the coordinate
--         flag are deleted (their reads are gone).
--   R1-b  `v_st := v_ship.status;` no longer also captures the retired ship column.
--   R1-c  unified-branch lifecycle check reads status ONLY (lifecycle has ONE signal).
--   R1-d  the coordinate-movement select + flag assignment are deleted.
--   R1-e  DESTROYED: the coordinate flag leaves the coherence condition; status is the signal.
--   R1-f  the whole spatial-state branch cascade (in_space/at_location/in_transit/home/unknown) is
--         deleted; the docked answer is re-created from FLEET truth: present fleet + location mode
--         + no live leg pointer + matching active presence → 'at_location'. This branch also
--         absorbs the old legacy_present shape (same fleet pair, minus the ship column that used
--         to split the token — the ONE deliberate merge, see the header parity map).
--   R1-g  legacy_transit: KEPT VERBATIM (it always was fleet truth).
--   R1-h  NEW berth branch: no per-ship fleet + berth set + settled status → 'home' (the S1 rule:
--         berth answers only where no fleet does; the XOR guarantees such a ship is ungrouped).
--   R1-i  legacy_home: KEPT VERBATIM — now reachable ONLY for a FLEETED (grouped) ship whose group
--         has no unified fleet (berth NULL under the XOR): the honest transition token, still
--         settled-unsafe.
create or replace function public.mainship_space_validate_context(p_main_ship_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_ship   main_ship_instances%rowtype;
  v_fleet  fleets%rowtype;
  v_count  integer := 0;
  -- ── ★ 4C-MIG-1 HUNK R1-a: the coordinate-movement rowtype, the spatial-state local, and the ★ ──
  -- ── ★ coordinate flag are DELETED from the declares (their reads are retired below).       ★ ──
  v_pres   location_presence%rowtype;
  v_st     text;
  v_has_legacy boolean := false;
  v_presact boolean;
  fail     constant text := 'contradictory_state';
  -- FLEET-GO 3c-1 additions:
  v_ufleet fleets%rowtype;
  v_upres  location_presence%rowtype;
begin
  select * into v_ship from main_ship_instances where main_ship_id = p_main_ship_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'ship_not_found'); end if;
  -- ── ★ 4C-MIG-1 HUNK R1-b: status only — the retired ship state column is no longer read. ★ ──
  v_st := v_ship.status;

  -- ★ THE FLEET-GO 3c BRANCH — dark by default; retained verbatim from the 0210 head. ★
  -- §2: the ship's place IS its fleet's place. When the ship is a member of a group that HAS a unified
  -- fleet, that fleet is the entire answer and the ship's own movement signals are IGNORED — they are
  -- the retired layer, and the mover never writes them (0208). 'destroyed' is checked first because it
  -- is LIFECYCLE, not movement: it stays the ship's own truth under §2 and survives step 4c.
  if public.cfg_bool('fleet_movement_unified_enabled') and v_ship.group_id is not null then
    -- KNOWN PAIR-DISAGREEMENT (recorded, not fixed — pre-existing, lit-only, needs a broken invariant):
    -- this is a NON-STRICT select — if TWO+ live unified fleets ever existed for one group it answers
    -- from an arbitrary row, while mainship_resolve_fleet fails CLOSED (NULL) on the same state. The
    -- oracle could then say 'at_location' while every resolver-based host says incoherent/hidden.
    -- Tolerated because the mover + hunt maintain at-most-one by construction; fold the two answers
    -- into one (fail closed here too) if that invariant ever gains a writer that can break it.
    select * into v_ufleet
      from public.fleets
     where group_id = v_ship.group_id and player_id = v_ship.player_id and main_ship_id is null
       and status in ('idle', 'moving', 'present', 'returning');
    if found then
      -- ── ★ 4C-MIG-1 HUNK R1-c: lifecycle reads status ONLY (the retired ship state column   ★ ──
      -- ── ★ carried a parallel 'destroyed' value only on the dark legacy destruction path).  ★ ──
      if v_st = 'destroyed' then
        return jsonb_build_object('ok', true, 'state', 'destroyed');
      end if;

      -- docked: the fleet is present at a port AND carries the matching active presence.
      if v_ufleet.status = 'present' and v_ufleet.location_mode = 'location'
         and v_ufleet.current_location_id is not null then
        select * into v_upres from public.location_presence
         where fleet_id = v_ufleet.id and status = 'active';
        if v_upres.id is null or v_upres.location_id is distinct from v_ufleet.current_location_id then
          return jsonb_build_object('ok', false, 'reason', fail);
        end if;
        return jsonb_build_object('ok', true, 'state', 'at_location');
      end if;

      -- parked in open space at the fleet's OWN coordinate (0208). Note the position is read from the
      -- FLEET, never the ship — that is §2 stated as a read.
      if v_ufleet.location_mode = 'space' then
        if v_ufleet.space_x is null or v_ufleet.space_y is null then
          return jsonb_build_object('ok', false, 'reason', fail);
        end if;
        return jsonb_build_object('ok', true, 'state', 'in_space');
      end if;

      -- under way on the legacy/fleet spine (the only spine the unified mover uses — it never creates a
      -- main_ship_space_movements row, so 'in_transit' would be a lie about which domain it is in).
      if v_ufleet.status in ('moving', 'returning') and v_ufleet.active_movement_id is not null then
        return jsonb_build_object('ok', true, 'state', 'legacy_transit');
      end if;

      -- an idle fleet at its anchor: coherent, and the mover's `else` origin branch departs from it.
      if v_ufleet.status = 'idle' then
        return jsonb_build_object('ok', true, 'state', 'legacy_home');
      end if;

      return jsonb_build_object('ok', false, 'reason', fail);
    end if;
    -- no unified fleet for this group → fall through to the per-ship fallback (the transition case).
  end if;

  -- ══════ the per-ship fallback — the 0056 head repointed onto fleet/berth truth (hunks R1-d..i);
  -- ══════ the fleet/presence/leg reads it always made are RETAINED verbatim. ══════
  select count(*) into v_count from fleets where main_ship_id = p_main_ship_id and status in ('idle','moving','present','returning');
  if v_count > 1 then return jsonb_build_object('ok', false, 'reason', 'multiple_active_fleets'); end if;
  if v_count = 1 then select * into v_fleet from fleets where main_ship_id = p_main_ship_id and status in ('idle','moving','present','returning'); end if;

  -- ── ★ 4C-MIG-1 HUNK R1-d: the coordinate-movement select and its flag are DELETED here. ★ ──
  if v_count = 1 then
    select * into v_pres from location_presence where fleet_id = v_fleet.id and status = 'active';
    v_has_legacy := exists (select 1 from fleet_movements where fleet_id = v_fleet.id and status = 'moving');
  end if;
  v_presact := v_pres.id is not null;

  -- DESTROYED (lifecycle: the ship's own status — the ONE signal that stays on the ship under §2)
  -- ── ★ 4C-MIG-1 HUNK R1-e: the coordinate-movement flag leaves the coherence condition. ★ ──
  if v_st = 'destroyed' then
    if v_presact or v_count > 0 then return jsonb_build_object('ok', false, 'reason', fail); end if;
    return jsonb_build_object('ok', true, 'state', 'destroyed');
  end if;

  -- ── ★ 4C-MIG-1 HUNK R1-f: the docked answer, from FLEET truth. Replaces the whole deleted   ★ ──
  -- ── ★ ship-state branch cascade AND the old legacy_present arm: a present/location fleet    ★ ──
  -- ── ★ with no live leg pointer and a matching active presence IS the docked pair — the same ★ ──
  -- ── ★ coherence the old at_location arm demanded, minus the retired ship-column and         ★ ──
  -- ── ★ coordinate-pointer reads. Incoherent present shapes fail closed exactly as before.    ★ ──
  if v_count = 1 and v_fleet.status = 'present' then
    if v_fleet.location_mode <> 'location' or v_fleet.current_location_id is null then return jsonb_build_object('ok', false, 'reason', fail); end if;
    if v_fleet.active_movement_id is not null then return jsonb_build_object('ok', false, 'reason', fail); end if;
    if not v_presact or v_pres.location_id is distinct from v_fleet.current_location_id then return jsonb_build_object('ok', false, 'reason', fail); end if;
    return jsonb_build_object('ok', true, 'state', 'at_location');
  end if;
  -- ── ★ END HUNK R1-f — the retained 0056 arms continue below. ★ ──
  if v_count = 1 and v_fleet.status in ('moving','returning') and v_has_legacy then
    return jsonb_build_object('ok', true, 'state', 'legacy_transit');
  end if;
  -- ── ★ 4C-MIG-1 HUNK R1-h: BERTH truth (S1/0216). No per-ship fleet + a berth + a settled    ★ ──
  -- ── ★ status → the ship is AT ITS BERTH PORT: settled, 0114-accepted. 'home' is the token   ★ ──
  -- ── ★ every live host already maps exactly like legacy_home EXCEPT the settled-safe rules — ★ ──
  -- ── ★ which is the entire intended delta (the root B1 fix; see the file header). The XOR    ★ ──
  -- ── ★ guarantees this ship is ungrouped; wreckage statuses stay refused below.              ★ ──
  if v_count = 0 and v_ship.berth_location_id is not null and v_st in ('home', 'stationary') then
    return jsonb_build_object('ok', true, 'state', 'home');
  end if;
  -- transition remainder (spatial-era: the bare legacy-home arm). Under the XOR a v_count=0 ship
  -- with no berth is GROUPED — its group simply has no unified fleet yet: coherent but placeless.
  if v_count = 0 and v_st = 'home' then
    return jsonb_build_object('ok', true, 'state', 'legacy_home');
  end if;
  -- nothing coherent → not an actionable origin context
  return jsonb_build_object('ok', false, 'reason', fail);
end;
$function$;

-- ACL re-asserted exactly as 0056 (CREATE OR REPLACE preserves it; defense-in-depth re-assert).
revoke execute on function public.mainship_space_validate_context(uuid) from public, anon, authenticated;
grant  execute on function public.mainship_space_validate_context(uuid) to service_role;

-- ═══════════ §2. R2 — mainship_space_assert_cross_domain_exclusion: the 0056:224 TRUE head, ══════
-- ═══════════ byte-copied, with the marked repoint hunks ONLY. ════════════════════════════════════
-- Six+ live callers (exploration_scan, mining_extract, both securing processors via the 0121 leaf,
-- fitting 0114, captain 0121, decks 0189, rooms 0203) — every one calls validate_context FIRST, so
-- their reachable outcomes are UNCHANGED (analysis in the file header). Hunks:
--   R2-a declares: the coordinate-movement rowtype → the resolved-fleet local.
--   R2-b the coordinate-movement read + pointer-agreement block → the RESOLVED fleet (0210's ONE
--        resolver — the group's unified fleet when grouped, the same per-ship row already judged
--        above otherwise) must not be under way on the fleet spine. Same reason token.
--   R2-c the ship-state presence-conflict read → fleet truth: a non-located resolved fleet
--        (moving/returning, or parked in open space) must not hold an active presence.
create or replace function public.mainship_space_assert_cross_domain_exclusion(p_main_ship_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ship  main_ship_instances%rowtype;
  v_fleet fleets%rowtype;
  v_count integer := 0;
  -- ── ★ 4C-MIG-1 HUNK R2-a: the coordinate-movement rowtype is replaced by the resolved fleet. ★ ──
  v_rfleet uuid;
begin
  select * into v_ship from main_ship_instances where main_ship_id = p_main_ship_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'ship_not_found'); end if;

  select count(*) into v_count from fleets where main_ship_id = p_main_ship_id and status in ('idle','moving','present','returning');
  if v_count > 1 then return jsonb_build_object('ok', false, 'reason', 'multiple_active_fleets'); end if;
  if v_count = 1 then
    select * into v_fleet from fleets where main_ship_id = p_main_ship_id and status in ('idle','moving','present','returning');
    -- a selected fleet with an active LEGACY movement blocks the coordinate domain
    if exists (select 1 from fleet_movements where fleet_id = v_fleet.id and status = 'moving') then
      return jsonb_build_object('ok', false, 'reason', 'active_legacy_movement');
    end if;
  end if;

  -- ── ★ 4C-MIG-1 HUNK R2-b: the coordinate-movement read and its fleet-pointer agreement       ★ ──
  -- ── ★ checks are replaced by FLEET truth — the ship's RESOLVED fleet (its group's unified   ★ ──
  -- ── ★ fleet when grouped; otherwise the same per-ship row the block above already judged)   ★ ──
  -- ── ★ must not be under way. Prod-reachable outcomes are identical: the coordinate table    ★ ──
  -- ── ★ has ZERO moving rows and every live caller pre-gates on the oracle's settled states.  ★ ──
  v_rfleet := public.mainship_resolve_fleet(p_main_ship_id);
  if v_rfleet is not null
     and exists (select 1 from fleet_movements where fleet_id = v_rfleet and status = 'moving') then
    return jsonb_build_object('ok', false, 'reason', 'active_legacy_movement');
  end if;

  -- ── ★ 4C-MIG-1 HUNK R2-c: an active presence that contradicts a NON-LOCATED resolved fleet ★ ──
  -- ── ★ (in flight, or parked in open space) — the old check keyed this on the retired ship  ★ ──
  -- ── ★ state column; the fleet's own mode/status is the truth now. Same reason token.       ★ ──
  if v_rfleet is not null
     and exists (select 1 from fleets f
                  where f.id = v_rfleet
                    and (f.status in ('moving', 'returning') or f.location_mode = 'space'))
     and exists (select 1 from location_presence where fleet_id = v_rfleet and status = 'active') then
    return jsonb_build_object('ok', false, 'reason', 'presence_conflict');
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

-- ACL re-asserted exactly as 0056 (CREATE OR REPLACE preserves it; defense-in-depth re-assert).
revoke execute on function public.mainship_space_assert_cross_domain_exclusion(uuid) from public, anon, authenticated;
grant  execute on function public.mainship_space_assert_cross_domain_exclusion(uuid) to service_role;

-- ═══════════ §3. R3 — get_my_fleet_positions: the 0216:846 TRUE head, byte-copied, with the ══════
-- ═══════════ marked repoint hunks ONLY. ══════════════════════════════════════════════════════════
-- Every 0211/0212/0216 hunk that is not a legacy-spatial branch SURVIVES VERBATIM: the 0211 docked
-- resolver read, the 0212 transit + fleet-first in_space resolver reads, the 0212 emit shape, and
-- the S1 berthed branch (gate + resolver-NULL key). Hunks:
--   R3-a declares: the coordinate-movement record is deleted (its branch is gone).
--   R3-b loop select/filter: the ship coordinate columns leave the select (nothing reads them any
--        more); the legacy-destroyed filter leaves the where (status is the ONE lifecycle signal;
--        the retained state passthrough field still rides the select for the client contract).
--   R3-c in_space: the ship-column fallback arm is DELETED — the fleet's coordinate is the ONLY
--        position authority (§2 as a read). Post-R1 'in_space' exists ONLY as fleet truth, so the
--        arm was unreachable as well as untrue.
--   R3-d the coordinate-transit branch (the per-ship movement-table read) is DELETED — post-R1 the
--        oracle can no longer answer that state; fleet-spine transit stays in legacy_transit.
--   R3-e the emit comment is retargeted (the coordinate now always comes from the fleet).
-- The 'spatial_state' PASSTHROUGH FIELD in the emit is deliberately KEPT: the client FleetPosition
-- type (src/features/map/mainshipApi.ts:157) still carries it; it retires with the column in the
-- 4c-client PR + 4c-mig-2, client-before-schema.
create or replace function public.get_my_fleet_positions()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_out    jsonb := '[]'::jsonb;
  s        record;
  v_ctx    jsonb;
  v_ok     boolean;
  v_state  text;
  v_place  text;
  v_loc    uuid;
  v_seg    jsonb;
  -- ── ★ 4C-MIG-1 HUNK R3-a: the coordinate-movement record is deleted (branch retired below). ★ ──
  v_lm     record;
  -- FLEET-GO 3c-3 additions: the resolved in_space coordinate (fleet-first, ship fallback).
  v_sx     double precision;
  v_sy     double precision;
  -- S1-BERTH (0216) addition: the gate, read ONCE (not per ship row).
  v_unified boolean := public.cfg_bool('fleet_movement_unified_enabled');
begin
  if v_player is null then
    return v_out;
  end if;

  -- Every owned, non-destroyed ship (owner-read scope). `order by created_at` is stable enumeration only —
  -- the marker placement per ship is decided below, never by row order.
  -- ── ★ 4C-MIG-1 HUNK R3-b: the ship coordinate columns leave the select; the legacy-destroyed ★ ──
  -- ── ★ filter leaves the where. The state passthrough stays for the client contract only.     ★ ──
  for s in
    select main_ship_id, name, hull_type_id, status, spatial_state,
           berth_location_id   -- S1-BERTH (0216): read with the row (part of the ONE hunk)
      from public.main_ship_instances
     where player_id = v_player
       and status <> 'destroyed'
     order by created_at asc
  loop
    v_place := 'hidden';
    v_loc   := null;
    v_seg   := null;
    -- FLEET-GO 3c-3: reset WITH the others. plpgsql variables persist across loop iterations, so a
    -- coordinate surviving into a later row is a ship drawn where a DIFFERENT fleet parked.
    v_sx    := null;
    v_sy    := null;

    -- Canonical coherence oracle — the SAME authority the single-ship dock/store reads trust. It fully
    -- validates fleet + presence + movement coherence and returns the ship's honest state (or ok=false).
    v_ctx   := public.mainship_space_validate_context(s.main_ship_id);
    v_ok    := coalesce((v_ctx->>'ok')::boolean, false);
    v_state := v_ctx->>'state';

    if v_ok then
      if v_state = 'in_space' then
        -- FLEET-GO 3c-3 (hunk 2 of 3): FLEET-FIRST. The unified world parks the FLEET
        -- (fleet_set_in_space, 0208) and never writes a ship coordinate, so a parked/braked group was
        -- INVISIBLE here — the old arm read only the ship's own columns. The fleet's coordinate now
        -- answers first (0210:188-189: the position is read from the FLEET, never the ship).
        -- ── ★ 4C-MIG-1 HUNK R3-c: the ship-column fallback arm below this read is DELETED —   ★ ──
        -- ── ★ post-R1 'in_space' IS fleet truth, so the arm was unreachable as well as untrue ★ ──
        -- ── ★ (the retired-layer read this whole migration exists to remove).                 ★ ──
        select f.space_x, f.space_y
          into v_sx, v_sy
          from public.fleets f
         where f.id = public.mainship_resolve_fleet(s.main_ship_id) and f.location_mode = 'space'
         limit 1;
        if v_sx is not null and v_sy is not null then
          v_place := 'in_space';
        end if;

      elsif v_state in ('at_location', 'legacy_present') then
        -- FLEET-GO 3c-2 (the ONE hunk): rekeyed from `f.main_ship_id = <ship>` (NULL on a unified
        -- fleet — the whole group vanished on arrival) to the ONE ship→fleet resolver, KEEPING this
        -- site's own status='present' read: 'legacy_present' reaches here too, and the at_location-only
        -- dock helper would return NULL for every legacy-shaped prod ship (a live map regression).
        -- Dark → both oracle guards pin exactly ONE active per-ship fleet, the resolver's fallback
        -- returns it, and f.id = <that one row> makes the old `order by created_at desc` dead weight.
        select f.current_location_id
          into v_loc
          from public.fleets f
         where f.id = public.mainship_resolve_fleet(s.main_ship_id) and f.status = 'present'
         limit 1;
        if v_loc is not null then
          v_place := 'docked';
        end if;

      -- ── ★ 4C-MIG-1 HUNK R3-d: the coordinate-transit branch (the per-ship movement-table    ★ ──
      -- ── ★ read) is DELETED — post-R1 the oracle never answers that state; fleet-spine       ★ ──
      -- ── ★ transit is the legacy_transit branch below, exactly as before.                    ★ ──

      elsif v_state = 'legacy_transit' then
        -- Legacy (spatial-era NULL) transit — the committed fleet_movements segment.
        -- FLEET-GO 3c-3 (hunk 1 of 3): rekeyed from `f.main_ship_id = s.main_ship_id` (NULL on a
        -- unified fleet — a flying group's members drew hidden for the whole flight) to the ONE
        -- ship→fleet resolver. Dark → the oracle's legacy_transit guard pins exactly ONE active
        -- per-ship fleet carrying a moving leg, the resolver's fallback returns it, and this join
        -- selects the same movement row the old key did (the honest residual is in the header). The
        -- host's own join, its `order by fm.depart_at desc`, and its `limit 1` are KEPT.
        select fm.origin_x, fm.origin_y, fm.target_x, fm.target_y, fm.target_type, fm.depart_at, fm.arrive_at
          into v_lm
          from public.fleet_movements fm
          join public.fleets f on f.id = fm.fleet_id
         where f.id = public.mainship_resolve_fleet(s.main_ship_id) and fm.status = 'moving'
         order by fm.depart_at desc
         limit 1;
        if found then
          v_place := 'transit';
          v_seg   := jsonb_build_object(
            'origin_x', v_lm.origin_x, 'origin_y', v_lm.origin_y,
            'target_x', v_lm.target_x, 'target_y', v_lm.target_y,
            'target_kind', v_lm.target_type,
            'depart_at', v_lm.depart_at, 'arrive_at', v_lm.arrive_at);
        end if;

      -- 'home' / 'legacy_home' → hidden: a ship idle at home is NOT drawn on the port map (mirrors the
      -- single-ship resolver §E/§F). Any other ok state falls through to hidden too (fail closed).
      end if;
    end if;

    -- S1-BERTH (0216) — THE ONE HUNK: the BERTHED branch. A ship no arm above placed, that the ONE
    -- resolver has no fleet for, and that carries a berth → place='berthed' at the berth port.
    -- Post-flip this is prod's majority ungrouped shape once the corpses die (4c/4d); until then a
    -- coherent corpse still answers 'docked' above (resolver non-NULL) and this branch stays quiet.
    -- A FLEETED ship with a broken fleet invariant has berth NULL → stays hidden (fail closed).
    -- Gated: dark = 0212 byte-identically.
    if v_unified and v_place = 'hidden' and s.berth_location_id is not null
       and public.mainship_resolve_fleet(s.main_ship_id) is null then
      v_place := 'berthed';
      v_loc   := s.berth_location_id;
    end if;

    -- Append as a single-element ARRAY (array || array is unambiguous concatenation).
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'main_ship_id', s.main_ship_id,
      'name',         s.name,
      'class',        s.hull_type_id,
      'status',       s.status,
      'spatial_state', s.spatial_state,
      'place',        v_place,
      'location_id',  v_loc,
      -- ── ★ 4C-MIG-1 HUNK R3-e (comment retarget only): the emitted coordinate is ALWAYS the ★ ──
      -- ── ★ resolved FLEET coordinate now — the ship-column fallback is retired above.       ★ ──
      'space_x',      case when v_place = 'in_space' then v_sx else null end,
      'space_y',      case when v_place = 'in_space' then v_sy else null end,
      'segment',      v_seg
    ));
  end loop;

  return v_out;
end;
$$;

-- Authenticated-only owner read (re-emitted verbatim from the 0216 head).
revoke all on function public.get_my_fleet_positions() from public;
grant execute on function public.get_my_fleet_positions() to authenticated;

-- ═══════════ §4. R5a — exploration_scan: the 0172:55 TRUE head, byte-copied, ONE marked hunk ═════
-- ═══════════ (step 9: the position read). ════════════════════════════════════════════════════════
-- PROSRC-ASSERT COUPLING (0172's law, carried forward): scripts/activate-exploration.sql gates the
-- flip on this body containing 'unique_violation' + 'already_discovered' AND the restored insert
-- column list — ALL retained verbatim below. The §8 self-assert re-pins them on the deployed body.
create or replace function public.exploration_scan(
  p_player       uuid,
  p_main_ship_id uuid,
  p_request_id   uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c_cmd    constant text := 'exploration_scan';
  v_lock   jsonb;
  v_status text;
  v_owner  uuid;
  v_hash   text;
  v_rcpt   main_ship_space_command_receipts%rowtype;
  v_val    jsonb;
  v_state  text;
  v_excl   jsonb;
  v_x      double precision;
  v_y      double precision;
  v_radius double precision;
  v_site   exploration_sites%rowtype;
  v_now    timestamptz;
  v_result jsonb;
begin
  -- 1) DARK GATE FIRST (0097 law / 0070 idiom): while exploration_enabled is false, reject
  --    deterministically BEFORE any other read, lock, or write — no ship read, no receipt read,
  --    no site read, no discovery row.
  if not public.cfg_bool('exploration_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'feature_disabled');
  end if;

  -- 2) pure input validation
  if p_request_id is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid_request_id');
  end if;

  -- 3) S2 canonical lock context (blocking; ship → fleet → coordinate movement → presence)
  v_lock := public.mainship_space_lock_context(p_main_ship_id, false);
  v_status := v_lock->>'status';
  if v_status = 'not_found' then
    return jsonb_build_object('ok', false, 'reason', 'missing_ship');
  elsif v_status <> 'locked' then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_status, 'lock_failed'));
  end if;

  -- 4) ownership from the LOCKED snapshot (never from the client)
  v_owner := (v_lock->'ship'->>'player_id')::uuid;
  if v_owner is distinct from p_player then
    return jsonb_build_object('ok', false, 'reason', 'not_owned');
  end if;

  -- 5) canonical immutable command payload + hash (scan carries NO coordinate body — 0064 stop idiom)
  v_hash := md5(jsonb_build_object('command_type', c_cmd)::text);

  -- 6) idempotency receipt lookup AFTER the ship lock + ownership check (0064 order; reused
  --    mechanism — replay returns the FIRST committed result verbatim)
  select * into v_rcpt from main_ship_space_command_receipts
    where main_ship_id = p_main_ship_id and request_id = p_request_id;
  if found then
    if v_rcpt.command_type = c_cmd and v_rcpt.canonical_payload_hash = v_hash then
      return v_rcpt.result_json;
    else
      return jsonb_build_object('ok', false, 'reason', 'request_id_payload_conflict');
    end if;
  end if;

  -- 7) coherent-state validation under the locks; scanning requires a SETTLED in-space ship
  v_val := public.mainship_space_validate_context(p_main_ship_id);
  if (v_val->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_val->>'reason', 'contradictory_state'));
  end if;
  v_state := v_val->>'state';
  if v_state = 'destroyed' then
    return jsonb_build_object('ok', false, 'reason', 'destroyed');
  elsif v_state <> 'in_space' then
    -- in_transit / at_location / home / legacy_* — one truthful reason: not settled in open space
    return jsonb_build_object('ok', false, 'reason', 'not_in_space');
  end if;

  -- 8) cross-domain exclusion (0064 arrival-processor posture, reused): the ship must not be
  --    claimed by a legacy movement / pointer conflict / location presence.
  v_excl := public.mainship_space_assert_cross_domain_exclusion(p_main_ship_id);
  if (v_excl->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_excl->>'reason', 'cross_domain_conflict'));
  end if;

  -- 9) ── ★ 4C-MIG-1 HUNK R5a (this body's ONLY change): the position under lock is the      ★ ──
  --    ── ★ RESOLVED FLEET's, composed from S3's ONE position leaf (0218) through 0210's ONE ★ ──
  --    ── ★ resolver — never the retired ship columns. state='in_space' (step 7, post-R1)    ★ ──
  --    ── ★ proves the resolved fleet is parked in open space with non-null coordinates; a   ★ ──
  --    ── ★ vanished fleet answers NULL/NULL and falls closed to no_site_in_range below.     ★ ──
  select p.o_x, p.o_y into v_x, v_y
    from public.fleet_current_position(public.mainship_resolve_fleet(p_main_ship_id)) p;

  -- 10) nearest undiscovered ACTIVE site within the tunable radius; deterministic tie-break:
  --     distance, then name. Inactive sites are treated as nonexistent (0098 is_active law).
  v_radius := coalesce(public.cfg_num('exploration_scan_radius'), 750);
  select s.* into v_site
    from exploration_sites s
    where s.is_active
      and public.osn_distance(v_x, v_y, s.space_x, s.space_y) <= v_radius
      and not exists (select 1 from exploration_discoveries d
                      where d.player_id = p_player and d.site_id = s.id)
    order by public.osn_distance(v_x, v_y, s.space_x, s.space_y) asc, s.name asc
    limit 1;
  if not found then
    -- simplest truthful reason set: an in-range active site exists but every one is already
    -- this player's discovery → already_discovered; otherwise → no_site_in_range. Neither leaks
    -- undiscovered-site existence beyond what the player has legitimately learned.
    if exists (select 1 from exploration_sites s
               where s.is_active
                 and public.osn_distance(v_x, v_y, s.space_x, s.space_y) <= v_radius) then
      return jsonb_build_object('ok', false, 'reason', 'already_discovered');
    end if;
    return jsonb_build_object('ok', false, 'reason', 'no_site_in_range');
  end if;

  -- 11) ACCRUE (never deposit): record the discovery with the PENDING bundle snapshot on the
  --     activity's own state. secured_at stays NULL — the deposit slice's securing path alone
  --     sets it. No inventory/base/reward/movement write happens here.
  --     ── H1 RESTORE (0172's ONLY exploration change, retained verbatim) ──: the insert records
  --     main_ship_id — the exact 0100:170 column set that 0146's stale-body re-create
  --     dropped. Without it every discovery relies on the NULL-ship securing fallback, which
  --     resolves only for single-ship owners (0081) — multi-ship players' rewards would strand
  --     forever. The 0146 unique_violation handler is KEPT verbatim. PROSRC-ASSERT COUPLING:
  --     scripts/activate-exploration.sql asserts this body contains the unique_violation handler
  --     and the restored insert column list (the pending-bundle column immediately followed by the
  --     ship column — deliberately NOT spelled out here so a comment can never satisfy the assert;
  --     see the 0172 file header for the exact token).
  v_now := clock_timestamp();
  begin
    insert into exploration_discoveries (player_id, site_id, discovered_at, pending_bundle_json, main_ship_id)
      values (p_player, v_site.id, v_now, v_site.reward_bundle_json, p_main_ship_id);
  exception when unique_violation then
    -- a concurrent scan (a DIFFERENT request_id, a second ship of this same player) already recorded
    -- this player's discovery of this site between the step-10 not-exists pre-check and this insert.
    -- Return the SAME clean 'already_discovered' result the pre-check returns (and, like it, write NO
    -- receipt) instead of surfacing a raw unique_violation. Conservation is unaffected — the row
    -- already exists exactly once (the unique (player_id, site_id) constraint is the sole authority).
    return jsonb_build_object('ok', false, 'reason', 'already_discovered');
  end;

  v_result := jsonb_build_object('ok', true,
    'site_id', v_site.id, 'name', v_site.name,
    'space_x', v_site.space_x, 'space_y', v_site.space_y,
    'pending_bundle', v_site.reward_bundle_json,
    'discovered_at', v_now, 'request_id', p_request_id);

  -- 12) finalise the idempotency receipt atomically with the discovery (0064 idiom; scan creates
  --     no movement, so movement_id stays null)
  insert into main_ship_space_command_receipts (
    main_ship_id, player_id, request_id, command_type, canonical_payload_hash,
    outcome_status, result_json, completed_at)
  values (p_main_ship_id, p_player, p_request_id, c_cmd, v_hash, 'success', v_result, v_now);

  return v_result;
end;
$$;

-- ACL re-asserted exactly as 0099/0100/0172 (CREATE OR REPLACE preserves it; defense-in-depth re-assert):
revoke execute on function public.exploration_scan(uuid, uuid, uuid) from public, anon, authenticated;
grant  execute on function public.exploration_scan(uuid, uuid, uuid) to service_role;

-- ═══════════ §5. R5b — mining_extract: the 0172:222 TRUE head, byte-copied, ONE marked hunk ══════
-- ═══════════ (step 9: the position read). ════════════════════════════════════════════════════════
-- PROSRC-ASSERT COUPLING (0172's law, carried forward): scripts/activate-mining.sql gates the flip
-- on this body containing 'pg_advisory_xact_lock' AND 'worldstate_deplete_field' — BOTH retained
-- verbatim below. The §8 self-assert re-pins them on the deployed body.
create or replace function public.mining_extract(
  p_player       uuid,
  p_main_ship_id uuid,
  p_request_id   uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c_cmd      constant text := 'mining_extract';
  v_lock     jsonb;
  v_status   text;
  v_owner    uuid;
  v_hash     text;
  v_rcpt     main_ship_space_command_receipts%rowtype;
  v_val      jsonb;
  v_state    text;
  v_excl     jsonb;
  v_x        double precision;
  v_y        double precision;
  v_radius   double precision;
  v_field    mining_fields%rowtype;
  v_cooldown double precision;
  v_last     timestamptz;
  v_retry    integer;
  v_now      timestamptz;
  v_ext_id   uuid;
  v_result   jsonb;
  -- ── H2 RESTORE ── WORLD-BALANCE-P19 (field depletion, 0137) locals — used ONLY inside the
  -- flag-gated blocks below; dropped by 0143's stale-body re-create, re-merged by 0172 (retained).
  v_wb       boolean;
  v_reserve  numeric;
  v_bundle   jsonb;
  v_items    jsonb;
begin
  -- 1) DARK GATE FIRST (0097 law / 0070 idiom): while mining_enabled is false, reject
  --    deterministically BEFORE any other read, lock, or write — no ship read, no receipt read,
  --    no field read, no extraction row.
  if not public.cfg_bool('mining_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'feature_disabled');
  end if;

  -- 2) pure input validation
  if p_request_id is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid_request_id');
  end if;

  -- 3) S2 canonical lock context (blocking; ship → fleet → coordinate movement → presence)
  v_lock := public.mainship_space_lock_context(p_main_ship_id, false);
  v_status := v_lock->>'status';
  if v_status = 'not_found' then
    return jsonb_build_object('ok', false, 'reason', 'missing_ship');
  elsif v_status <> 'locked' then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_status, 'lock_failed'));
  end if;

  -- 4) ownership from the LOCKED snapshot (never from the client)
  v_owner := (v_lock->'ship'->>'player_id')::uuid;
  if v_owner is distinct from p_player then
    return jsonb_build_object('ok', false, 'reason', 'not_owned');
  end if;

  -- 5) canonical immutable command payload + hash (extract carries NO coordinate body — 0064 stop
  --    idiom, via 0099)
  v_hash := md5(jsonb_build_object('command_type', c_cmd)::text);

  -- 6) idempotency receipt lookup AFTER the ship lock + ownership check (0064 order; reused
  --    mechanism — replay returns the FIRST committed result verbatim)
  select * into v_rcpt from main_ship_space_command_receipts
    where main_ship_id = p_main_ship_id and request_id = p_request_id;
  if found then
    if v_rcpt.command_type = c_cmd and v_rcpt.canonical_payload_hash = v_hash then
      return v_rcpt.result_json;
    else
      return jsonb_build_object('ok', false, 'reason', 'request_id_payload_conflict');
    end if;
  end if;

  -- 7) coherent-state validation under the locks; extracting requires a SETTLED in-space ship
  v_val := public.mainship_space_validate_context(p_main_ship_id);
  if (v_val->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_val->>'reason', 'contradictory_state'));
  end if;
  v_state := v_val->>'state';
  if v_state = 'destroyed' then
    return jsonb_build_object('ok', false, 'reason', 'destroyed');
  elsif v_state <> 'in_space' then
    -- in_transit / at_location / home / legacy_* — one truthful reason: not settled in open space
    return jsonb_build_object('ok', false, 'reason', 'not_in_space');
  end if;

  -- 8) cross-domain exclusion (0064 arrival-processor posture, reused): the ship must not be
  --    claimed by a legacy movement / pointer conflict / location presence.
  v_excl := public.mainship_space_assert_cross_domain_exclusion(p_main_ship_id);
  if (v_excl->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_excl->>'reason', 'cross_domain_conflict'));
  end if;

  -- 9) ── ★ 4C-MIG-1 HUNK R5b (this body's ONLY change): the position under lock is the      ★ ──
  --    ── ★ RESOLVED FLEET's, composed from S3's ONE position leaf (0218) through 0210's ONE ★ ──
  --    ── ★ resolver — never the retired ship columns. state='in_space' (step 7, post-R1)    ★ ──
  --    ── ★ proves the resolved fleet is parked in open space with non-null coordinates; a   ★ ──
  --    ── ★ vanished fleet answers NULL/NULL and falls closed to no_field_in_range below.    ★ ──
  select p.o_x, p.o_y into v_x, v_y
    from public.fleet_current_position(public.mainship_resolve_fleet(p_main_ship_id)) p;

  -- 10) nearest ACTIVE field within the tunable radius; deterministic tie-break: distance, then
  --     name (0099 rule; NO discovered-filter — extraction is repeatable). Inactive fields are
  --     treated as nonexistent (0103 is_active law).
  v_radius := coalesce(public.cfg_num('mining_extract_radius'), 750);
  select f.* into v_field
    from mining_fields f
    where f.is_active
      and public.osn_distance(v_x, v_y, f.space_x, f.space_y) <= v_radius
    order by public.osn_distance(v_x, v_y, f.space_x, f.space_y) asc, f.name asc
    limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_field_in_range');
  end if;

  -- 10b) SERIALIZE same-player extractions on the SAME field (0143 correctness guard — KEPT
  --      verbatim). The S2 ship lock (step 3) locks the caller's OWN ship row, so two DIFFERENT
  --      ships of the same player at the same field never contend there — leaving a
  --      read-then-insert double-extract window at step 11. This xact-scoped advisory lock keyed on
  --      (player, field) closes it: the second command blocks here until the first COMMITS, then
  --      reads the first's now-committed extraction below and is correctly 'cooldown'-rejected.
  --      Reuses the codebase idiom hashtext(<domain>), hashtext(<scope>) (0078/0113/0126/0133);
  --      xact-scoped ⇒ auto-released at commit/rollback (no cleanup, no softlock) and reentrant
  --      alongside the existing row locks. PERMANENT guard — not a shim, no retirement condition.
  perform pg_advisory_xact_lock(hashtext('mining_extract'), hashtext(p_player::text || ':' || v_field.id::text));

  -- 11) COOLDOWN (the slice-C deviation; recon decision 2): the latest extraction by this player
  --     from this field must be older than the tunable cooldown. Served by the 0103
  --     (player_id, field_id, created_at desc) index. Failure writes NO receipt (0064 posture),
  --     so retrying the same request_id after the cooldown succeeds.
  v_now := clock_timestamp();
  v_cooldown := coalesce(public.cfg_num('mining_extract_cooldown_seconds'), 300);
  select e.created_at into v_last
    from mining_extractions e
    where e.player_id = p_player and e.field_id = v_field.id
    order by e.created_at desc
    limit 1;
  if found and v_last + make_interval(secs => v_cooldown) > v_now then
    v_retry := ceil(extract(epoch from (v_last + make_interval(secs => v_cooldown) - v_now)))::integer;
    return jsonb_build_object('ok', false, 'reason', 'cooldown',
                              'retry_after_seconds', greatest(v_retry, 1));
  end if;

  -- 11.5) ── H2 RESTORE ── WORLD-BALANCE-P19 FIELD DEPLETION (0137, re-merged by 0172; retained
  --       verbatim; dark unless world_balance_enabled). ENTIRELY gated so mining is byte-identical
  --       while dark: v_bundle defaults to the field bundle VERBATIM; only when the flag is on do
  --       we scale each item qty by the current reserve (diminishing returns, per-item floor of 1).
  --       reserve is READ (DOWNWARD) BEFORE this extraction's depletion, so the bundle reflects the
  --       pre-extraction reserve. worldstate_field_remaining is itself flag-gated (returns 1.0
  --       while dark) — defense in depth.
  v_bundle := v_field.reward_bundle_json;
  v_wb := coalesce(public.cfg_bool('world_balance_enabled'), false);
  if v_wb then
    v_reserve := public.worldstate_field_remaining(v_field.id);
    select coalesce(jsonb_agg(
             jsonb_build_object('item_id',  it->>'item_id',
                                'quantity', greatest(1, round((it->>'quantity')::numeric * v_reserve)))
             order by ord), '[]'::jsonb)
      into v_items
      from jsonb_array_elements(v_field.reward_bundle_json->'items') with ordinality as t(it, ord);
    v_bundle := v_field.reward_bundle_json || jsonb_build_object('items', v_items);
  end if;

  -- 12) ACCRUE (never deposit): ONE extraction row per extraction (repeatable — no unique pair,
  --     no ON CONFLICT), snapshotting the (── H2 RESTORE ── depletion-scaled) v_bundle onto the
  --     activity's own state. secured_at stays NULL — the slice-D securing processor alone sets it.
  insert into mining_extractions (player_id, field_id, main_ship_id, pending_bundle_json, created_at)
    values (p_player, v_field.id, p_main_ship_id, v_bundle, v_now)
    returning id into v_ext_id;

  -- 12.5) ── H2 RESTORE ── WORLD-BALANCE-P19 (0137): deplete the field EXACTLY ONCE per REAL
  --        extraction. Placed in the success path right after the row insert (unreachable on
  --        replay — a replay returned at step 6), so no double-deplete. The deplete leaf is itself
  --        flag-gated (no-op while dark), and this call is additionally inside `if v_wb` so mining
  --        is byte-identical while dark. PROSRC-ASSERT COUPLING: scripts/activate-mining.sql
  --        asserts this body contains the deplete-leaf call below (the comment above deliberately
  --        avoids naming it, so a comment can never satisfy the assert).
  if v_wb then
    perform public.worldstate_deplete_field(v_field.id);
  end if;

  v_result := jsonb_build_object('ok', true,
    'extraction_id', v_ext_id,
    'field_id', v_field.id, 'name', v_field.name,
    'space_x', v_field.space_x, 'space_y', v_field.space_y,
    'pending_bundle', v_bundle,
    'extracted_at', v_now, 'request_id', p_request_id);

  -- 13) finalise the idempotency receipt atomically with the extraction (0064 idiom; extract
  --     creates no movement, so movement_id stays null)
  insert into main_ship_space_command_receipts (
    main_ship_id, player_id, request_id, command_type, canonical_payload_hash,
    outcome_status, result_json, completed_at)
  values (p_main_ship_id, p_player, p_request_id, c_cmd, v_hash, 'success', v_result, v_now);

  return v_result;
end;
$$;

-- Re-assert the private writer ACL (CREATE OR REPLACE keeps it; restated per the 0104/0137/0143/0172
-- precedent).
revoke execute on function public.mining_extract(uuid, uuid, uuid) from public, anon, authenticated;
grant  execute on function public.mining_extract(uuid, uuid, uuid) to service_role;

-- ═══════════ §6. R5c — process_exploration_securing: the 0100:203 TRUE head, byte-copied, ════════
-- ═══════════ ONE marked hunk (the settled-safe read). ════════════════════════════════════════════
-- With zero in-space ships in prod this processor's queue is empty today; the repoint REVIVES it
-- under the fleet model — a berthed or fleet-docked carrier now secures its pending bundles.
create or replace function public.process_exploration_securing()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  d         record;
  v_ship    uuid;
  v_safe    boolean;
  v_base_id uuid;
  v_count   integer := 0;
begin
  for d in
    select * from exploration_discoveries
    where secured_at is null
    for update skip locked
  loop
    -- carrying ship: the recorded scanner, else the player's canonical main ship (0081 resolver).
    v_ship := d.main_ship_id;
    if v_ship is null then
      v_ship := public.mainship_resolve_owned_ship(d.player_id, null);
    end if;
    if v_ship is null then
      continue;  -- no resolvable ship: the row stays pending (never forfeited by this processor)
    end if;

    -- ── ★ 4C-MIG-1 HUNK R5c (this body's ONLY change): settled SAFE via the ONE settled-safe ★ ──
    -- ── ★ leaf (0121) instead of the retired per-ship state-column read. Post-R1/R2 the leaf ★ ──
    -- ── ★ answers from fleet/berth truth: a berthed or fleet-docked carrier secures;         ★ ──
    -- ── ★ anything in flight, in open space, or incoherent WAITS — exactly the old contract, ★ ──
    -- ── ★ minus the retired column.                                                          ★ ──
    v_safe := public.mainship_space_assert_settled_safe(v_ship);
    if v_safe is not true then
      continue;
    end if;

    -- deposit target: the player's active home base (0050 idiom). NEVER grant with a null base —
    -- reward_grant would silently skip the metal half of the bundle; the row waits instead.
    select id into v_base_id
      from bases where player_id = d.player_id and status = 'active'
      order by created_at limit 1;
    if v_base_id is null then
      continue;
    end if;

    -- SECURE: the one sole depositor, exactly as the fleet return branch calls it. Idempotent by
    -- reward_grants UNIQUE (source_type, source_id) — this discovery can never double-deposit.
    perform reward_grant('exploration', d.id, d.player_id, v_base_id, d.pending_bundle_json);
    update exploration_discoveries set secured_at = now() where id = d.id;
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- Lock to server/cron (0033 idiom, re-emitted verbatim from the 0100 head).
revoke execute on function public.process_exploration_securing() from public, anon, authenticated;
grant  execute on function public.process_exploration_securing() to service_role;

-- ═══════════ §7. R5d — process_mining_securing: the 0105:40 TRUE head, byte-copied, ══════════════
-- ═══════════ ONE marked hunk (the settled-safe read). ════════════════════════════════════════════
create or replace function public.process_mining_securing()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  e         record;
  v_ship    uuid;
  v_safe    boolean;
  v_base_id uuid;
  v_count   integer := 0;
begin
  for e in
    select * from mining_extractions
    where secured_at is null
    for update skip locked
  loop
    -- carrying ship: the recorded extractor, else the player's canonical main ship (0081 resolver;
    -- NULL is only possible for deleted-ship rows — the FK orphans on ship deletion).
    v_ship := e.main_ship_id;
    if v_ship is null then
      v_ship := public.mainship_resolve_owned_ship(e.player_id, null);
    end if;
    if v_ship is null then
      continue;  -- no resolvable ship: the row stays pending (never forfeited by this processor)
    end if;

    -- ── ★ 4C-MIG-1 HUNK R5d (this body's ONLY change): settled SAFE via the ONE settled-safe ★ ──
    -- ── ★ leaf (0121) instead of the retired per-ship state-column read — the same hunk as   ★ ──
    -- ── ★ the exploration processor (one pattern, not two, exactly as 0105 mirrored 0100).   ★ ──
    v_safe := public.mainship_space_assert_settled_safe(v_ship);
    if v_safe is not true then
      continue;
    end if;

    -- deposit target: the player's active home base (0050 idiom). NEVER grant with a null base —
    -- reward_grant would silently skip a scalar half of the bundle; the row waits instead. (Mining
    -- bundles are items-only by decision 3, but the guard is kept verbatim from 0100 — one
    -- pattern, not two, and it also shields against a malformed future seed.)
    select id into v_base_id
      from bases where player_id = e.player_id and status = 'active'
      order by created_at limit 1;
    if v_base_id is null then
      continue;
    end if;

    -- SECURE: the one sole depositor, exactly as the fleet return branch and the exploration
    -- processor call it. Idempotent by reward_grants UNIQUE (source_type, source_id) — this
    -- extraction can never double-deposit.
    perform reward_grant('mining', e.id, e.player_id, v_base_id, e.pending_bundle_json);
    update mining_extractions set secured_at = now() where id = e.id;
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- Lock to server/cron (0033 idiom, re-emitted verbatim from the 0105 head).
revoke execute on function public.process_mining_securing() from public, anon, authenticated;
grant  execute on function public.process_mining_securing() to service_role;

-- ═══════════ §8. self-assert (deploy-time, raises on failure — the 0213/0216 idiom). ═════════════
-- Three layers: (a) definitions + grant posture; (b) prosrc pins — the repoint LANDED (no retired
-- read survives in any body) AND every retained head token/coupling SURVIVED (parity is retention);
-- (c) a FULL RECONCILIATION over every REAL ship row: the berthed majority answers a 0114-accepted
-- settled state and passes the whole fit gate (oracle + exclusion via the 0121 leaf) — the B1
-- outcome proven on the live data at the moment of apply. Token probes use code-only literals
-- (the 0216 lesson: prosrc keeps comments; the marked-hunk banners above deliberately avoid the
-- banned spellings so a comment can never mask a surviving read).
do $repoint8$
declare
  v_src text;
  r     record;
  v     jsonb;
  n_berthed int := 0;
  n_ships   int := 0;
begin
  -- (a) single definitions + grant posture (each per its head).
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname in
         ('mainship_space_validate_context', 'mainship_space_assert_cross_domain_exclusion',
          'get_my_fleet_positions', 'exploration_scan', 'mining_extract',
          'process_exploration_securing', 'process_mining_securing')) <> 7 then
    raise exception '4C-MIG-1 self-assert FAIL: expected exactly 7 single definitions'; end if;
  if not has_function_privilege('authenticated', 'public.get_my_fleet_positions()', 'execute') then
    raise exception '4C-MIG-1 self-assert FAIL: get_my_fleet_positions lost its authenticated grant'; end if;
  if has_function_privilege('authenticated', 'public.mainship_space_validate_context(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.mainship_space_assert_cross_domain_exclusion(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.exploration_scan(uuid, uuid, uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.mining_extract(uuid, uuid, uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.process_exploration_securing()', 'execute')
     or has_function_privilege('authenticated', 'public.process_mining_securing()', 'execute') then
    raise exception '4C-MIG-1 self-assert FAIL: an internal function leaked onto the client surface'; end if;

  -- (b1) R1: no retired read survives; the retained head + the new branches are present.
  select prosrc into v_src from pg_proc where oid = 'public.mainship_space_validate_context(uuid)'::regprocedure;
  if position('from main_ship_space_movements' in v_src) > 0
     or position('.spatial_state' in v_src) > 0
     or position('active_space_movement_id' in v_src) > 0 then
    raise exception '4C-MIG-1 self-assert FAIL: a retired-signal read survives in validate_context'; end if;
  if position('cfg_bool(''fleet_movement_unified_enabled'') and v_ship.group_id is not null' in v_src) = 0
     or position('''state'', ''legacy_transit''' in v_src) = 0
     or position('''state'', ''legacy_home''' in v_src) = 0
     or position('''reason'', ''multiple_active_fleets''' in v_src) = 0 then
    raise exception '4C-MIG-1 self-assert FAIL: a retained 0210/0056 arm vanished from validate_context — parity broke'; end if;
  if position('v_ship.berth_location_id is not null and v_st in (''home'', ''stationary'')' in v_src) = 0
     or position('v_fleet.status = ''present''' in v_src) = 0 then
    raise exception '4C-MIG-1 self-assert FAIL: a repoint branch (berth / fleet-docked) is missing from validate_context'; end if;
  -- the old spatial-era tokens must be GONE as ANSWERS (code-form: the state emit).
  if position('''state'', ''legacy_present''' in v_src) > 0
     or position('''state'', ''in_transit''' in v_src) > 0
     or position('''reason'', ''unknown_spatial_state''' in v_src) > 0 then
    raise exception '4C-MIG-1 self-assert FAIL: a retired spatial-era state is still emitted by validate_context'; end if;

  -- (b2) R2: repointed to the ONE resolver; tokens retained.
  select prosrc into v_src from pg_proc where oid = 'public.mainship_space_assert_cross_domain_exclusion(uuid)'::regprocedure;
  if position('from main_ship_space_movements' in v_src) > 0
     or position('.spatial_state' in v_src) > 0
     or position('active_space_movement_id' in v_src) > 0 then
    raise exception '4C-MIG-1 self-assert FAIL: a retired-signal read survives in cross_domain_exclusion'; end if;
  if position('mainship_resolve_fleet' in v_src) = 0
     or position('''reason'', ''active_legacy_movement''' in v_src) = 0
     or position('''reason'', ''presence_conflict''' in v_src) = 0
     or position('''reason'', ''multiple_active_fleets''' in v_src) = 0 then
    raise exception '4C-MIG-1 self-assert FAIL: cross_domain_exclusion lost the resolver compose or a reason token'; end if;

  -- (b3) R3: the legacy branches are gone; every retained 0211/0212/0216 hunk survives.
  select prosrc into v_src from pg_proc where oid = 'public.get_my_fleet_positions()'::regprocedure;
  if position('from public.main_ship_space_movements' in v_src) > 0
     or position('s.space_x' in v_src) > 0 then
    raise exception '4C-MIG-1 self-assert FAIL: a retired-signal read survives in get_my_fleet_positions'; end if;
  if position('f.id = public.mainship_resolve_fleet(s.main_ship_id) and f.status = ''present''' in v_src) = 0
     or position('f.id = public.mainship_resolve_fleet(s.main_ship_id) and fm.status = ''moving''' in v_src) = 0
     or position('f.id = public.mainship_resolve_fleet(s.main_ship_id) and f.location_mode = ''space''' in v_src) = 0 then
    raise exception '4C-MIG-1 self-assert FAIL: a 0211/0212 resolver hunk vanished from get_my_fleet_positions — stale-head rebuild'; end if;
  if position('if v_unified and v_place = ''hidden'' and s.berth_location_id is not null' in v_src) = 0
     or position('and public.mainship_resolve_fleet(s.main_ship_id) is null then' in v_src) = 0 then
    raise exception '4C-MIG-1 self-assert FAIL: the S1 berthed branch (gate + resolver-NULL key) vanished from get_my_fleet_positions'; end if;
  if position('''spatial_state'', s.spatial_state' in v_src) = 0 then
    raise exception '4C-MIG-1 self-assert FAIL: the client-contract passthrough field left the map emit early (that retires with 4c-client + 4c-mig-2)'; end if;

  -- (b4) R5a/R5b: the position compose landed; the activation-script couplings survived.
  select prosrc into v_src from pg_proc where oid = 'public.exploration_scan(uuid, uuid, uuid)'::regprocedure;
  if position('from main_ship_instances' in v_src) > 0 then
    raise exception '4C-MIG-1 self-assert FAIL: exploration_scan still reads the ship row for position'; end if;
  if position('fleet_current_position(public.mainship_resolve_fleet(p_main_ship_id))' in v_src) = 0
     or position('unique_violation' in v_src) = 0
     or position('already_discovered' in v_src) = 0
     or position('pending_bundle_json, main_ship_id' in v_src) = 0 then
    raise exception '4C-MIG-1 self-assert FAIL: exploration_scan lost the leaf compose or an activation-coupled 0172 token'; end if;
  select prosrc into v_src from pg_proc where oid = 'public.mining_extract(uuid, uuid, uuid)'::regprocedure;
  if position('from main_ship_instances' in v_src) > 0 then
    raise exception '4C-MIG-1 self-assert FAIL: mining_extract still reads the ship row for position'; end if;
  if position('fleet_current_position(public.mainship_resolve_fleet(p_main_ship_id))' in v_src) = 0
     or position('pg_advisory_xact_lock' in v_src) = 0
     or position('worldstate_deplete_field' in v_src) = 0 then
    raise exception '4C-MIG-1 self-assert FAIL: mining_extract lost the leaf compose or an activation-coupled 0143/0172 token'; end if;

  -- (b5) R5c/R5d: the ONE settled-safe leaf composed; no retired column read.
  select prosrc into v_src from pg_proc where oid = 'public.process_exploration_securing()'::regprocedure;
  if position('spatial_state' in v_src) > 0 or position('mainship_space_assert_settled_safe' in v_src) = 0
     or position('reward_grant' in v_src) = 0 or position('skip locked' in v_src) = 0 then
    raise exception '4C-MIG-1 self-assert FAIL: process_exploration_securing repoint broke (leaf missing, retired read surviving, or a head call lost)'; end if;
  select prosrc into v_src from pg_proc where oid = 'public.process_mining_securing()'::regprocedure;
  if position('spatial_state' in v_src) > 0 or position('mainship_space_assert_settled_safe' in v_src) = 0
     or position('reward_grant' in v_src) = 0 or position('skip locked' in v_src) = 0 then
    raise exception '4C-MIG-1 self-assert FAIL: process_mining_securing repoint broke (leaf missing, retired read surviving, or a head call lost)'; end if;

  -- (c) FULL RECONCILIATION on the real data (76 rows in prod; 0 on a fresh CI chain — the CI
  --     runtime markers carry the fixture-based behavioral proof there). For EVERY ship:
  --       • settled-berthed shape (ungrouped + berth + home/stationary + no live per-ship fleet)
  --         → ok:true, a 0114-accepted state, AND the whole 0121 fit gate passes  ← THE B1 FIX.
  --       • non-settled berthed wreckage (the 'traveling' orphans) → stays ok:false.
  --       • NO ungrouped ship may still answer the pre-repoint hidden token.
  for r in select * from public.main_ship_instances loop
    n_ships := n_ships + 1;
    v := public.mainship_space_validate_context(r.main_ship_id);
    if r.group_id is null and r.berth_location_id is not null and r.status in ('home', 'stationary')
       and not exists (select 1 from public.fleets f
                        where f.main_ship_id = r.main_ship_id
                          and f.status in ('idle', 'moving', 'present', 'returning')) then
      if (v->>'ok')::boolean is not true or (v->>'state') not in ('home', 'at_location') then
        raise exception '4C-MIG-1 self-assert FAIL: settled berthed ship % answers % — the B1 outcome did not land', r.main_ship_id, v; end if;
      if public.mainship_space_assert_settled_safe(r.main_ship_id) is not true then
        raise exception '4C-MIG-1 self-assert FAIL: settled berthed ship % fails the 0121/0114 fit gate', r.main_ship_id; end if;
      n_berthed := n_berthed + 1;
    end if;
    if r.group_id is null and r.berth_location_id is not null
       and r.status not in ('home', 'stationary', 'destroyed')
       and not exists (select 1 from public.fleets f
                        where f.main_ship_id = r.main_ship_id
                          and f.status in ('idle', 'moving', 'present', 'returning')) then
      if (v->>'ok')::boolean is true and (v->>'state') in ('home', 'at_location') then
        raise exception '4C-MIG-1 self-assert FAIL: unsettled berthed wreckage % reads settled (%)', r.main_ship_id, v; end if;
    end if;
    if r.group_id is null and (v->>'state') = 'legacy_home' then
      raise exception '4C-MIG-1 self-assert FAIL: ungrouped ship % still answers the pre-repoint legacy_home token', r.main_ship_id; end if;
  end loop;
  raise notice '4C-MIG-1 self-assert: % ship row(s) reconciled; % settled-berthed ship(s) proven 0114-fit-eligible', n_ships, n_berthed;
end $repoint8$;
