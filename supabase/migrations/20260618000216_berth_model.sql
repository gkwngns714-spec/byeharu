-- S1 — THE BERTH MODEL: a ship is FLEETED xor BERTHED, as a SCHEMA FACT. Migration 0216.
--
-- Charter: docs/MOVEMENT_UNIFICATION_CHARTER.md §2 (the FLEET is the only mover; membership IS
-- position), the ⭐ FLIPPED-LIVE block (unified movement is ON in prod; the legacy per-ship movers
-- are dark), and the NO-HOME law (ports are the only base — a ship that is not with its fleet is
-- AT A PORT, never "home"). First migration of the post-flip ship-location arc.
--
-- ── THE MODEL ─────────────────────────────────────────────────────────────────────────────────────
-- A ship is in EXACTLY ONE of two mutually exclusive states:
--   FLEETED — group_id NON-NULL, berth_location_id NULL.  Its location is its group's fleet's
--             location (the existing 0210/0212 machinery, UNTOUCHED here).
--   BERTHED — group_id NULL, berth_location_id NON-NULL.  Its location is that port — shown as
--             INFO ("Docked at <port>"), never a map marker. Only fleets are map markers.
-- The XOR is a CHECK constraint, not a convention: no writer can produce a ship that is both, or
-- neither. ONE location resolver: fleeted → the fleet (mainship_resolve_fleet, 0210); else → berth.
--
-- ── GATING DOCTRINE (the rollback contract forces it) ─────────────────────────────────────────────
-- The flip is documented as reversible by one command with FLAG-EXACT behavior. Therefore:
--   • berth as DATA is maintained ALWAYS (the XOR is a schema fact — every group_id writer keeps
--     the pair coherent, lit or dark). This is the ONLY unconditional delta.
--   • berth as BEHAVIOR is LIT-ONLY (fleet_movement_unified_enabled): the unassign/delete guards,
--     the first-assign fleet mint, and the map's 'berthed' place all sit behind the flag. Dark
--     (= rolled back), every RPC behaves as its previous head byte-for-byte except the inert
--     berth-column writes. ROLLBACK RESIDUAL (recorded): while dark, unassign/delete berth ships
--     via the transition arm (own present per-ship fleet's port, else Haven) with no in-flight
--     refusal — exactly today's always-allowed semantics plus dormant berth data.
--
-- ── GROUND TRUTH — every head re-derived by grep 2026-07-18 (this arc's inventory was wrong 8×) ───
--   main_ship_instances.group_id FK — 0160:57-58 (ON DELETE SET NULL; the ONLY definition).
--   assign_ship_to_group            — TRUE head 0213:136-309 (0161:96 → 0204:139 → 0213; no other).
--   delete_ship_group               — TRUE head 0162:25-65 (the ONLY definition).
--   ship_group_resolve_fleet        — 0213 (the ONE group-fleet-shape authority; COMPOSED here).
--   mainship_resolve_fleet          — 0210 (the ONE ship→fleet resolver; COMPOSED, untouched).
--   port_entry_commission_build     — TRUE head **0197:222-330** (0080→0184→0193→0194→0197 — the
--                                     task brief said 0194; SHIELD-2 re-created it. Copied from 0197.)
--   ensure_main_ship_for_player     — TRUE head **0197:339-390** (0043→0077→0078→0193→0197) — the
--                                     second ship creator; the brief's "sibling creators" grep found it.
--   get_my_fleet_positions          — TRUE head 0212:58-219 (its own TRUE-HEAD declaration; copied
--                                     from 0212, per its instruction. 0216 is the new true head.)
--   PORT-ENTRY md5 pins             — scripts/port-entry-1-production-verify.{sh,sql} pin EXACTLY
--                                     port_entry_commission_writer / commission_first_main_ship /
--                                     normalize_main_ship_dock. NONE is re-created here (build and
--                                     ensure are NOT pinned — the 0184/0197 precedent), so NO pin
--                                     re-derivation is due at this deploy gate.
--
-- ── THE group_id WRITER AUDIT (grep over ALL migrations — every writer vs the XOR) ────────────────
--   1. assign_ship_to_group (0213 head)          — RE-CREATED HERE: the ONE UPDATE writes group_id
--      and berth_location_id together (assign clears berth; unassign sets it). XOR holds per row.
--   2. FK ON DELETE SET NULL cascade (0160)      — DEAD BY CONSTRUCTION under the XOR for any
--      still-existing member row (SET NULL alone → both-NULL → CHECK violation). delete_ship_group
--      (re-created here) therefore un-groups members MANUALLY (group_id + berth in ONE UPDATE)
--      before the delete, so the cascade fires on zero rows. ⚠ RESIDUAL (surfaced, not fixed): an
--      auth.users delete cascades ship_groups AND main_ship_instances; if the ship_groups cascade's
--      SET NULL reaches a still-live FLEETED member row first, that UPDATE violates the CHECK and
--      the account deletion errors. Cascade trigger order is not contractual. Remedy if it ever
--      bites: delete the player's groups (via delete_ship_group) before the account, or convert the
--      FK to deferred NO ACTION in a follow-up. Recorded here and in the slice report.
--   3. Ship-creating INSERTs — port_entry_commission_build + ensure_main_ship_for_player (both 0197
--      heads, both RE-CREATED HERE): a new ship is BORN BERTHED at Haven (group_id defaults NULL,
--      berth = the commission port). Preserves ASSIGN-FIRST (no group-cap change).
--   4. mainship_mark_combat_destroyed (0167) / dev_set_main_ship_destroyed (0059) — write status/hp/
--      spatial only; group_id and berth persist through destruction → XOR undisturbed. NO CHANGE.
--   5. send_ship_group_hunt (0214) / the mover (0208) / the brake (0215) / the settle / the 0199
--      reconciler / repair (0052/0199/0201) / shield+soul/trait writers — none touch group_id or
--      berth (grep-verified). The mover's §2 no-ship-write law now covers berth too (the proof's
--      ship snapshot gained the column). NO CHANGE.
--   There is no other group_id writer. INSERT paths all go through the two creators in (3).
--
-- ── WHAT IS DELIBERATELY NOT DONE HERE ────────────────────────────────────────────────────────────
--   • The legacy per-ship fleet/presence corpses are NOT touched (4c/4d own their retirement). The
--     backfill READS them once (the one sanctioned read — allowlisted in fleetgo-proof.sh's
--     tree-wide dock-copy ban) to seed berths that match real docks, then they are ignored.
--   • The hunt (0214), mover (0208), brake (0215), oracle/resolver (0210) are byte-untouched.
--   • No Fitting tab, no berth-side services — S6.
--
-- ── DEPLOY CHECKLIST + RECORDED RESIDUALS (S1 adversarial review — record-only, do NOT code here) ─
--   [DEPLOY] BACKFILL SPOT-CHECK (the backfill DML never executes in CI — a fresh chain has no
--     pre-existing ships; only its in-file coverage assert runs on real data). IMMEDIATELY after
--     the prod deploy, run and require 0:
--       select count(*) from public.main_ship_instances s
--        where s.group_id is null
--          and s.berth_location_id is distinct from coalesce(
--                (select f.current_location_id from public.fleets f
--                  where f.main_ship_id = s.main_ship_id and f.status = 'present'
--                    and f.location_mode = 'location' and f.current_location_id is not null
--                  order by f.created_at desc limit 1),
--                'b1a00001-0066-4a00-8a00-000000000001'::uuid);
--   [REQUIRED FOLLOW-UP — review MAJOR-2] auth.users cascade vs the XOR: deleting a user cascades
--     ship_groups (SET NULL onto members) AND main_ship_instances (row delete); if the SET NULL
--     reaches a still-live FLEETED member first (cascade trigger order is not contractual), that
--     UPDATE violates the CHECK and the account deletion ERRORS (never corrupts). BEFORE any
--     account-deletion tooling ships: delete the player's ship_groups (via delete_ship_group)
--     before auth.users, or convert the 0160 group_id FK to DEFERRABLE NO ACTION.
--   [RE-FLIP RUNBOOK — review MAJOR-3] dark berth-rot: while dark (rolled back) the legacy
--     per-ship movers move ships WITHOUT maintaining berth, so a later re-flip could read stale
--     berths (wrong-port co-location guards / wrong-port mints). On ANY re-flip, FIRST re-run the
--     §2 backfill UPDATE below verbatim (idempotent over ungrouped ships — it just resyncs berth
--     from the live corpse), THEN light the flag.
--   [4c/4d — review MINOR-7] a DARK delete_ship_group leaves the group's live 'present' fleet
--     un-consumed (head parity, deliberate): fleets.group_id goes SET-NULL and the orphan
--     'present' fleet + presence persist — pre-0216 behavior, uncollected by the 0047 reaper
--     (non-terminal). 4c/4d's corpse retirement owns the cleanup; recorded so it is not
--     rediscovered as a berth bug.
--   [NITS N-1..N-4, noted] N-2 is FIXED in-slice (the mint gates berth-port legality through
--     mainship_space_location_target_legal — skip-the-mint, never fail-the-assign). The rest are
--     recorded by the review and deferred with it.

-- ════════ §1) the column ═════════════════════════════════════════════════════════════════════════
alter table public.main_ship_instances
  add column berth_location_id uuid null references public.locations (id);

comment on column public.main_ship_instances.berth_location_id is
  'S1 BERTH MODEL (0216): the port an UNFLEETED ship is docked at. XOR with group_id (the '
  'main_ship_instances_berth_xor_fleet CHECK): fleeted ships carry NULL here and locate via their '
  'group''s fleet; berthed ships carry the port and are shown as INFO, never a map marker.';

-- ════════ §2) the backfill — BEFORE the CHECK ════════════════════════════════════════════════════
-- Every ungrouped ship gets a berth: its own MOST RECENT status='present' per-ship fleet's port
-- (the prod-verified live-fleet shape — fleet rows are per-trip history; the 'present' row is the
-- live one), ELSE Haven (the commission port). Grouped ships keep berth NULL (they are fleeted).
-- This is the ONE sanctioned read of the legacy corpse layer (see the header); it converts the
-- corpses' truth into berth once, at deploy time, on the real data.
update public.main_ship_instances s
   set berth_location_id = coalesce(
         (select f.current_location_id
            from public.fleets f
           where f.main_ship_id = s.main_ship_id
             and f.status = 'present'
             and f.location_mode = 'location'
             and f.current_location_id is not null
           order by f.created_at desc
           limit 1),
         'b1a00001-0066-4a00-8a00-000000000001'::uuid),
       updated_at = now()
 where s.group_id is null;

-- backfill coverage assert: RAISES (rolling the deploy back) if any ungrouped ship is left
-- berthless — on PROD this runs against the real data, which no CI fixture can imitate.
do $s1backfill$
declare n int;
begin
  select count(*) into n from public.main_ship_instances
   where group_id is null and berth_location_id is null;
  if n <> 0 then
    raise exception 'S1-BERTH backfill FAIL: % ungrouped ship(s) left berthless — the XOR cannot be installed', n;
  end if;
end $s1backfill$;

-- ════════ §3) THE XOR — a schema fact, not a convention ══════════════════════════════════════════
-- (group_id IS NULL) = (berth_location_id IS NOT NULL): fleeted-no-berth and berthed-no-group are
-- the ONLY legal shapes. Added AFTER the backfill, so a plain (validating) ADD is safe — NOT VALID
-- is unnecessary because this same transaction just made every row conform (and asserted it).
alter table public.main_ship_instances
  add constraint main_ship_instances_berth_xor_fleet
  check ((group_id is null) = (berth_location_id is not null));

-- ════════ §4) assign_ship_to_group — the 0213 TRUE head, byte-copied, + the marked S1 hunks ═══════
-- Hunks: A (declares) · B (the co-location guard's ship-side read becomes BERTH — one authority,
-- not a second read) · C (the =0 arm captures the pre-write empty/berth facts for the mint) ·
-- D (the UNASSIGN branch: lit ALLOW only from a docked fleet, else refuse; berth resolved) ·
-- E (the ONE UPDATE writes berth with group_id — the XOR maintenance) · F (the post-write mint:
-- FIRST assign into an EMPTY group mints the group fleet 'present' at the assignee's berth port —
-- the 0197 commission dock-mint idiom composed with the 0207/0214 group-fleet key, so every
-- non-empty group formed lit has a fleet and the map handoff berth→fleet is seamless).
-- Everything unmarked is the 0213 body verbatim (mechanical diff shows ONLY the hunks).
create or replace function public.assign_ship_to_group(p_main_ship_id uuid, p_group_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_ship   uuid;
  v_group  uuid;
  -- FLEET-CONTROL (0204): the gate, read ONCE. Dark seed → false → the cap hunk below is skipped and the
  -- 0161 head runs verbatim.
  v_fleet_control boolean := public.cfg_bool('fleet_control_enabled');
  v_members       integer;
  -- ASSIGN-GUARD (0213) HUNK A: the unification gate, read ONCE at the top (the 0204 idiom directly
  -- above, verbatim). Dark seed → false → Hunk B below keeps the head's FOR SHARE and Hunk C is
  -- skipped entirely — a side-effect-free stable read is the WHOLE dark delta of this migration.
  v_unified boolean := public.cfg_bool('fleet_movement_unified_enabled');
  v_gf_n    integer;
  v_gf      public.fleets%rowtype;
  v_hunting integer;
  -- S1-BERTH (0216) HUNK A: the berth working set. c_haven = the commission port (the 0197 build
  -- constant) — the transition fallback berth. v_ship_berth is the assignee's ONE location read
  -- (charter: if the guard reads the ship's location, it reads BERTH — never a second read).
  c_haven  constant uuid := 'b1a00001-0066-4a00-8a00-000000000001';
  v_ship_berth uuid;
  v_members0   integer;
  v_berth      uuid;
  v_cur_group  uuid;
  v_cur_berth  uuid;
  v_zone       uuid;
  v_sector     uuid;
  v_base       uuid;
  v_mint       uuid;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK gate FIRST — before any ship/group read (identical answer regardless of input; no existence oracle).
  if not public.cfg_bool('team_command_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'team_command_disabled');
  end if;

  -- Resolve the ship via the ESTABLISHED contract (0081): explicit id → ownership asserted; null → sole ship
  -- only (dark-phase shim); anything ambiguous → null → fail closed. UI selection is never trusted.
  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then
    return jsonb_build_object('ok', false, 'reason', 'ship_not_found');
  end if;

  -- Resolve the target group ONLY when one was requested. p_group_id null = UNASSIGN (always allowed for an
  -- owned ship). A non-null id not owned/nonexistent → fail closed. This resolve is what asserts SAME-PLAYER.
  if p_group_id is not null then
    v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
    if v_group is null then
      return jsonb_build_object('ok', false, 'reason', 'group_not_found');
    end if;
    -- FOR SHARE the resolved group, THEN revalidate it still exists under the lock. This serializes against a
    -- FUTURE group-delete (none in B0): the resolver read above is unlocked, so a concurrent delete could
    -- commit in the resolve→lock window; if it did, `perform` locks zero rows (FOUND=false) and we fail closed
    -- here instead of letting the update FK-violate into a raw 500. (Slice B's delete RPC must lock the group
    -- row FOR UPDATE and lean on ON DELETE SET NULL for members.)
    -- ASSIGN-GUARD (0213) HUNK B: lock STRENGTH only — the statement, the revalidate, and the
    -- envelope are the head's either way. LIT takes FOR UPDATE so this assign CONFLICTS with the
    -- sends' group FOR SHARE (0168:175, 0204:261) and the mover/brake's FOR UPDATE (0207:118, 0209):
    -- the documented assign-vs-send race (0168:239-241) — display-only under manifest-wins — would be
    -- Hunk C's TOCTOU hole, and the conflict closes it (see header: whoever commits second sees the
    -- other's write). DARK keeps FOR SHARE byte-identically — the lock footprint is part of parity.
    -- AT STEP 4 (flag permanently lit): collapse to the FOR UPDATE arm.
    if v_unified then
      perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for update;
    else
      perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for share;
    end if;
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'group_not_found');
    end if;
    -- ASSIGN-GUARD (0213) HUNK C: the co-location guard — lit only; dark skips to the cap hunk, so
    -- the head's flow is untouched. Under §2 membership IS position: a ship may only JOIN a fleet
    -- where that fleet actually is. Policy over the leaf's rows (see header for the full argument):
    -- 0 → allow (bootstrap; today's semantics), >1 → fail closed, in flight → reject, present at the
    -- assignee's own dock AND no open sortie → allow, anything else (incl. idle = parked in open
    -- space, 0208/0209; present elsewhere — the charter's own docked-at-the-HUNT-SITE branch; and a
    -- co-located but MID-SORTIE fleet) → reject.
    -- Takes NO lock of its own: a plain MVCC read of fleets/location_presence/the sortie manifest
    -- under the group lock.
    if v_unified then
      -- S1-BERTH (0216) HUNK B (part 1, REVISED by the S1 adversarial review): the SHIP-ROW LOCK,
      -- then the assignee's ONE ship-side read — its CURRENT group + its BERTH.
      -- • THE LOCK (review MAJOR-4): two concurrent assigns of the SAME ship into two DIFFERENT
      --   empty groups each hold only their own group row — nothing serializes on the ship — so
      --   both could read the same stale berth and BOTH mint a 'present' fleet there: an empty
      --   group left owning a live docked fleet (the ghost-dock class, silently). FOR UPDATE on
      --   the ship row queues same-ship assigns; the loser re-reads under the lock and sees the
      --   winner's write (now grouped → must_unassign_first below). Lock order stays the global
      --   group → ship order (assign/delete/send/hunt all take the group first; the settle's
      --   movement → fleet → ship chain shares only the ship row — no cycle). LIT-ONLY: the dark
      --   lock footprint is the head's (no ship lock before the UPDATE) — the parity law.
      -- • THE READ: berth is the unfleeted ship's ONE location authority (the backfill made it
      --   agree with the real dock; the per-ship movers are dark post-flip). Read ONCE, under the
      --   lock; used by the same/cross-group arms, the co-location arm, and the mint capture.
      perform 1 from public.main_ship_instances
        where main_ship_id = v_ship and player_id = v_player for update;
      select group_id, berth_location_id into v_cur_group, v_ship_berth
        from public.main_ship_instances
       where main_ship_id = v_ship and player_id = v_player;
      -- ONE statement, ONE snapshot (READ COMMITTED): the leaf is scanned with a single FOR loop
      -- that both counts the rows and captures the row. The first cut counted with one statement
      -- and re-selected with a second — TWO snapshots; the settle cron takes no group lock, so it
      -- could retire/replace the fleet between them and hand the checks an all-NULL row (a
      -- spurious reject from a phantom read — the 0213 review's Finding 3).
      v_gf_n := 0;
      for v_gf in select * from public.ship_group_resolve_fleet(v_player, v_group) loop
        v_gf_n := v_gf_n + 1;
      end loop;
      if v_gf_n > 1 then
        -- Two live group-shaped fleets is a broken invariant: fail closed with the token the mover
        -- and brake already use for this exact state (0207/0209) — one broken state, one token.
        return jsonb_build_object('ok', false, 'reason', 'fleet_ambiguous');
      end if;
      -- S1-BERTH (0216) — SAME-GROUP RE-ASSIGN (review MINOR-5): a member re-assigned to its OWN
      -- group is NEVER blocked (the 0204 :294 promise) — but a member's berth is NULL, so letting
      -- it fall into the co-location arm would misfire group_fleet_elsewhere. Short-circuit ok
      -- with the head's success envelope, writing nothing (group/berth/role are already exactly
      -- what the write would set them to). Sits AFTER the ambiguous arm deliberately: on a broken
      -- two-fleet invariant fail-closed beats idempotence (one broken state, one token).
      if v_cur_group = v_group then
        return jsonb_build_object('ok', true, 'main_ship_id', v_ship, 'group_id', v_group);
      end if;
      -- S1-BERTH (0216) — CROSS-GROUP DIRECT ASSIGN (review MAJOR-1): fail closed. A ship that is
      -- FLEETED in another group must leave through UNASSIGN, whose leave-guards decide whether
      -- leaving is even possible (a mid-sortie frozen-manifest member, or a member of a fleet in
      -- flight, must NOT step off by a direct re-assign — that is the exact state the unassign
      -- refusals exist to forbid, reachable through this side door otherwise: the ship would
      -- leave the manifest's group, resolve to nothing, and go hidden). One rule, one door:
      -- cross-group movement = unassign (berth at the fleet's docked port) + assign.
      if v_cur_group is not null then
        return jsonb_build_object('ok', false, 'reason', 'must_unassign_first');
      end if;
      if v_gf_n = 1 then
        if v_gf.status in ('moving', 'returning') then
          return jsonb_build_object('ok', false, 'reason', 'group_fleet_in_flight');
        end if;
        -- CO-LOCATION: the fleet is settled at a port (present + location + a real port id) AND the
        -- assignee's BERTH is that SAME port.
        -- S1-BERTH (0216) HUNK B (part 2): the ship-side read is now the berth captured above —
        -- 0213's per-ship fleet+presence EXISTS is the retired layer's shape and berth is the ONE
        -- authority (the head's read is retired WITH this hunk, not kept beside it).
        if not (v_gf.status = 'present' and v_gf.location_mode = 'location'
                and v_gf.current_location_id is not null
                and v_ship_berth is not null
                and v_ship_berth = v_gf.current_location_id) then
          return jsonb_build_object('ok', false, 'reason', 'group_fleet_elsewhere');
        end if;
        -- OPEN SORTIE — co-location does NOT override it (the 0213 review's Finding 1, the ghost-
        -- dock hole re-entering through the ALLOW arm): a hunt fleet settled 'present' at its site
        -- with the assignee's own dock AT that same site is co-located, but the sortie's manifest
        -- was FROZEN at send — combat ends, the fleet departs 'returning' on that manifest, the new
        -- member is not on it, and the resolver answers the group fleet for a ship the reconciler
        -- will never dock. A sortie is a commitment of a frozen roster; nothing joins it. The read
        -- mirrors the mover's guard 7 (0207:161-172) verbatim, same token. This guards ONLY the
        -- would-be ALLOW: every other sortie configuration is already rejected above (moving/
        -- returning → in-flight; present-but-not-co-located → elsewhere), so assignment into an
        -- open sortie is rejected REGARDLESS of co-location.
        select count(*) into v_hunting
          from public.group_sortie_members gsm
          join public.fleets f on f.id = gsm.fleet_id
         where gsm.player_id = v_player
           and f.group_id = v_group
           and f.status in ('moving', 'present', 'returning');
        if v_hunting > 0 then
          return jsonb_build_object('ok', false, 'reason', 'group_on_sortie');
        end if;
        -- co-located, no open sortie → fall through (ALLOW): the head's cap hunk and write run
        -- unchanged.
      end if;
      -- v_gf_n = 0 → fall through (ALLOW): no fleet, no position to contradict — the bootstrap case.
      -- S1-BERTH (0216) HUNK C: capture the PRE-WRITE facts the mint (Hunk F, after the ship
      -- UPDATE) needs — whether the group is EMPTY right now. The berth was captured above; the
      -- UPDATE below clears it, so both must be read here, under the group lock (no TOCTOU).
      if v_gf_n = 0 then
        select count(*) into v_members0
          from public.main_ship_instances
         where group_id = v_group and player_id = v_player;
      end if;
    end if;
    -- FLEET-CONTROL (0204): the ONE marked cap hunk. DARK — skipped (v_fleet_control false) → 0161 behavior.
    -- LIT — a fleet holds at most 8 ships; count the members ALREADY in the target fleet OTHER than the ship
    -- being written (so re-assigning a ship already in the fleet is never blocked). ≥8 → fleet_full. HONEST
    -- LIMIT: this is a SOFT gameplay cap, not a hard invariant — the group's lock above is FOR SHARE (shared),
    -- so two DIFFERENT ships assigned to the same 7-member fleet in the same instant could BOTH read 7 and
    -- both insert, landing 9. ACCEPTED (decision, not oversight): it needs the same authenticated player
    -- double-assigning concurrently, over-filling only their OWN fleet, with no downstream break (the movement
    -- RPCs don't cap), and it is dark until the flip. A hard cap would need FOR UPDATE on the group or an
    -- advisory lock — not worth the contention on a live RPC for a cosmetic ceiling.
    -- (0213 note: under v_unified the lock above IS FOR UPDATE, which incidentally hardens this cap
    -- lit; the head comment is preserved verbatim because the dark path is exactly as it describes.)
    if v_fleet_control then
      select count(*) into v_members
        from public.main_ship_instances
       where group_id = v_group and player_id = v_player and main_ship_id <> v_ship;
      if v_members >= 8 then
        return jsonb_build_object('ok', false, 'reason', 'fleet_full');
      end if;
    end if;
  else
    -- S1-BERTH (0216) HUNK D: UNASSIGN under the berth model. Leaving a fleet means BERTHING —
    -- the ship must land at a real port, so where the fleet IS decides whether leaving is possible:
    --   LIT, the group's ONE fleet resolved through the 0213 leaf:
    --     >1  → fleet_ambiguous (fail closed — the shared broken-invariant token);
    --     =1 moving/returning       → REFUSE 'fleet_in_flight' (a ship cannot berth in open space);
    --     =1 with an OPEN SORTIE    → REFUSE 'group_on_sortie' (the frozen manifest is a commitment:
    --                                 nothing joins it — 0213 — and nothing steps off it mid-sortie;
    --                                 the reconciler docks the manifest, not live membership);
    --     =1 docked (present + location + port) → ALLOW; berth = that port (the read the guard
    --                                 already does at 0213:234);
    --     =1 anything else (parked in open space / idle at anchor / incoherent) → REFUSE
    --                                 'fleet_in_flight' (no port under the keel);
    --     =0  → the TRANSITION arm (a pre-first-go group): berth = the ship's own resolved present
    --           per-ship fleet's port (mainship_resolve_fleet — the composed 0211 read, never a
    --           new inline dock copy), else Haven. Dies with the corpses at 4c/4d.
    --   DARK (rollback world): no refusal arms — the head's always-allowed semantics — and the
    --   berth resolves through the same transition arm (data maintenance only; flag-exact behavior).
    -- Unassigning an already-unassigned ship is an idempotent no-op that KEEPS its berth.
    -- Same guard-before-lock TOCTOU discipline as 0213: the group row is locked (lit FOR UPDATE —
    -- conflicts with the mover/brake/hunt group locks; dark FOR SHARE — the lock-footprint-parity
    -- rule) BEFORE the leaf is read, so a racing go/hunt commits first or sees this write.
    select group_id, berth_location_id into v_cur_group, v_cur_berth
      from public.main_ship_instances
     where main_ship_id = v_ship and player_id = v_player;
    if v_cur_group is not null then
      if v_unified then
        perform 1 from public.ship_groups where group_id = v_cur_group and player_id = v_player for update;
      else
        perform 1 from public.ship_groups where group_id = v_cur_group and player_id = v_player for share;
      end if;
      v_gf_n := 0;
      for v_gf in select * from public.ship_group_resolve_fleet(v_player, v_cur_group) loop
        v_gf_n := v_gf_n + 1;
      end loop;
      if v_unified then
        if v_gf_n > 1 then
          return jsonb_build_object('ok', false, 'reason', 'fleet_ambiguous');
        end if;
        if v_gf_n = 1 then
          if v_gf.status in ('moving', 'returning') then
            return jsonb_build_object('ok', false, 'reason', 'fleet_in_flight');
          end if;
          -- LIVE-SCOPED manifest read (the 0169/0215 live-scope law, per the S1 review's MINOR-6):
          -- a RETAINED manifest on a completed sortie fleet is kept up to 14d and must never block
          -- — the status join makes over-blocking impossible even if the leaf's own status set
          -- ever drifts (a bare EXISTS is safe only by construction, and constructions drift).
          if exists (select 1
                       from public.group_sortie_members gsm
                       join public.fleets f on f.id = gsm.fleet_id
                      where gsm.fleet_id = v_gf.id
                        and f.status in ('moving', 'present', 'returning')) then
            return jsonb_build_object('ok', false, 'reason', 'group_on_sortie');
          end if;
          if v_gf.status = 'present' and v_gf.location_mode = 'location'
             and v_gf.current_location_id is not null then
            v_berth := v_gf.current_location_id;
          else
            -- parked in open space (0208/0209) or idle at its anchor: no port to berth at.
            return jsonb_build_object('ok', false, 'reason', 'fleet_in_flight');
          end if;
        end if;
      end if;
      if v_berth is null then
        -- the TRANSITION arm (lit =0, or dark): the ship's own resolved present fleet's port.
        select f.current_location_id into v_berth
          from public.fleets f
         where f.id = public.mainship_resolve_fleet(v_ship)
           and f.status = 'present' and f.location_mode = 'location';
        v_berth := coalesce(v_berth, c_haven);
      end if;
    else
      -- already unassigned: keep the berth (idempotent replay). The coalesce is unreachable
      -- defense post-CHECK (an ungrouped ship always has a berth) — never a silent NULL.
      v_berth := coalesce(v_cur_berth, c_haven);
    end if;
  end if;

  -- Single-row write. v_ship and v_group were both asserted against v_player=auth.uid() → the pair is
  -- same-player by construction; the player_id predicate is defense-in-depth.
  -- FLEET-CONTROL (0204): the per-fleet command-role reset — when the fleet CHANGES (RHS group_id is the
  -- OLD value in a SET clause; `is distinct from` covers null↔fleet either way), clear is_command_ship so
  -- the role must be re-designated in the new fleet. A same-fleet re-assign keeps it. Always-on: inert while
  -- dark (the column is ignored), so this is the only write delta beyond the flag-gated cap hunk.
  update public.main_ship_instances
     set group_id = v_group,
         -- S1-BERTH (0216) HUNK E: the XOR maintenance, in the SAME UPDATE as the group_id write —
         -- assign (v_group non-null) clears the berth (the ship's location is now its fleet's);
         -- unassign writes the berth resolved in Hunk D. Unconditional: the CHECK is a schema fact.
         berth_location_id = case when v_group is not null then null else v_berth end,
         is_command_ship = case when group_id is distinct from v_group then false else is_command_ship end,
         updated_at = now()
   where main_ship_id = v_ship and player_id = v_player;

  -- S1-BERTH (0216) HUNK F: the FIRST-ASSIGN MINT — lit only, POST-write (no write ever precedes a
  -- reject: every guard/cap arm above returns before this point). When the assign put the FIRST
  -- ship into an EMPTY, fleetless group, the group's ONE fleet is minted 'present' AT THE
  -- ASSIGNEE'S BERTH PORT with an active presence — the 0197 commission dock-mint idiom (direct
  -- 'present' fleets INSERT + presence_create; fleet_set_present is a moving→present leaf and does
  -- not apply) carrying the 0207/0214 group-fleet key (group_id set, main_ship_id NULL). So every
  -- non-empty group formed lit has a fleet, and the berth→fleet location handoff is seamless (the
  -- oracle answers at_location at the same port the berth answered a moment ago). Serialized by
  -- the group FOR UPDATE lock above (no double-mint; the 0213/0214 lock reasoning). Bounded: ≤3
  -- groups per player (0160's group_index CHECK), so no fleet-budget interaction — a go/hunt on
  -- this fleet re-uses it and consumes no new slot. The assignee reaching here is always
  -- UNGROUPED (the review's must_unassign_first arm refuses fleeted ships before the write), so
  -- v_ship_berth is non-null by the XOR; the guard is kept as defense-in-depth. If the berth port
  -- is no longer DOCKABLE (review N-2 — a retired/disabled port; the canonical rule the
  -- commission's own fleet write gates on), nothing is minted: the assign still succeeds and the
  -- group is left fleetless-non-empty (the transition/bootstrap shape the =0 arms already serve,
  -- healed at its first go/hunt) rather than minting a docked fleet at an illegal port or failing
  -- a roster operation over a world-data change. origin_base_id = the player's first active base
  -- (the 0197 shape).
  if v_group is not null and v_unified and v_gf_n = 0 and v_members0 = 0
     and v_ship_berth is not null
     and (public.mainship_space_location_target_legal(v_ship_berth)->>'ok')::boolean is true then
    select l.zone_id, z.sector_id into v_zone, v_sector
      from public.locations l join public.zones z on z.id = l.zone_id
     where l.id = v_ship_berth;
    select b.id into v_base
      from public.bases b where b.player_id = v_player and b.status = 'active'
     order by b.created_at limit 1;
    insert into public.fleets
      (player_id, origin_base_id, status, location_mode, current_base_id,
       current_location_id, current_zone_id, current_sector_id, group_id)
    values (v_player, v_base, 'present', 'location', null,
            v_ship_berth, v_zone, v_sector, v_group)
    returning id into v_mint;
    perform public.presence_create(v_player, v_mint, v_sector, v_zone, v_ship_berth, 'none');
  end if;

  return jsonb_build_object('ok', true, 'main_ship_id', v_ship, 'group_id', v_group);
end;
$$;
-- ACL: the head's grants survive CREATE OR REPLACE; re-asserted defense-in-depth (the 0204 posture).
revoke execute on function public.assign_ship_to_group(uuid, uuid) from public, anon;
grant  execute on function public.assign_ship_to_group(uuid, uuid) to authenticated;

-- ════════ §5) delete_ship_group — the 0162 TRUE head, byte-copied, + the marked S1 hunks ══════════
-- WHY: the 0160 FK's ON DELETE SET NULL would set group_id NULL on members whose berth is NULL —
-- a CHECK violation (a raw 500) on every non-empty group. So the delete now (Hunk B) resolves the
-- group's fleet lit — refusing when it is in flight / mid-sortie / parked in space, and CONSUMING
-- it (presence closed + terminal, the 0214 release idiom) when it is docked so no orphan presence
-- survives the group — then (Hunk C) berths every member in ONE UPDATE (group_id + berth together)
-- BEFORE the delete, leaving the FK cascade zero rows to touch.
create or replace function public.delete_ship_group(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_group  uuid;
  -- S1-BERTH (0216) HUNK A: the unification gate (read once — the 0213 idiom) + the berth working
  -- set. Dark → false → the refusal/consume arms are skipped and behavior is the 0162 head plus the
  -- inert berth-column maintenance (the rollback contract).
  v_unified boolean := public.cfg_bool('fleet_movement_unified_enabled');
  v_gf_n    integer;
  v_gf      public.fleets%rowtype;
  v_port    uuid;
  c_haven   constant uuid := 'b1a00001-0066-4a00-8a00-000000000001';
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK gate FIRST — before any ship_groups read (identical answer regardless of input; no existence oracle).
  if not public.cfg_bool('team_command_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'team_command_disabled');
  end if;

  -- Resolve the owned group (explicit-only; null id or non-owned/nonexistent → null → fail closed). Same
  -- resolver B0 assign uses, so a non-owned id is indistinguishable from a nonexistent one (no ownership oracle).
  v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
  if v_group is null then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  -- Lock the group row FOR UPDATE, THEN revalidate it still exists under the lock. The resolve above is
  -- unlocked, so a concurrent delete could commit in the resolve→lock window; if it did, we lock zero rows
  -- (FOUND=false) and fail closed here. FOR UPDATE conflicts with assign's FOR SHARE → the two serialize.
  perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  -- S1-BERTH (0216) HUNK B: resolve the group's ONE fleet (the 0213 leaf — never a new inline copy
  -- of the shape) UNDER the group lock (guard-before-lock TOCTOU discipline: the mover/brake/hunt
  -- all take this same lock, so no go can slip between this read and the delete). LIT policy:
  --   >1 → fleet_ambiguous (fail closed, the shared token);
  --   =1 moving/returning → 'fleet_in_flight' (members cannot berth in open space);
  --   =1 with an open sortie manifest → 'group_on_sortie' (a frozen manifest is a commitment — and
  --      deleting mid-sortie would orphan the encounter's fleet);
  --   =1 docked → capture the port for Hunk C and CONSUME the fleet (presence_complete + terminal
  --      'completed' — the 0214 release idiom): a deleted group must not leave a live group-shaped
  --      fleet actively docked (fleets.group_id ON DELETE SET NULL would orphan its presence — the
  --      §0 ghost-dock class);
  --   =1 anything else (parked in space / idle anchor) → 'fleet_in_flight';
  --   =0 → nothing to consume (the transition/bootstrap group).
  -- DARK: all arms skipped — the 0162 head's always-allowed delete (a dark hunt fleet keeps today's
  -- FK SET-NULL fate; flag-exact rollback behavior).
  if v_unified then
    v_gf_n := 0;
    for v_gf in select * from public.ship_group_resolve_fleet(v_player, v_group) loop
      v_gf_n := v_gf_n + 1;
    end loop;
    if v_gf_n > 1 then
      return jsonb_build_object('ok', false, 'reason', 'fleet_ambiguous');
    end if;
    if v_gf_n = 1 then
      if v_gf.status in ('moving', 'returning') then
        return jsonb_build_object('ok', false, 'reason', 'fleet_in_flight');
      end if;
      -- LIVE-SCOPED manifest read (the 0169/0215 live-scope law, per the S1 review's MINOR-6):
      -- a RETAINED manifest on a completed sortie fleet must never block a delete.
      if exists (select 1
                   from public.group_sortie_members gsm
                   join public.fleets f on f.id = gsm.fleet_id
                  where gsm.fleet_id = v_gf.id
                    and f.status in ('moving', 'present', 'returning')) then
        return jsonb_build_object('ok', false, 'reason', 'group_on_sortie');
      end if;
      if v_gf.status = 'present' and v_gf.location_mode = 'location'
         and v_gf.current_location_id is not null then
        v_port := v_gf.current_location_id;
        perform public.presence_complete(lp.id)
          from public.location_presence lp
         where lp.fleet_id = v_gf.id and lp.status = 'active';
        update public.fleets
           set status = 'completed', location_mode = 'movement', active_movement_id = null,
               space_x = null, space_y = null,
               current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
               updated_at = now()
         where id = v_gf.id;
      else
        return jsonb_build_object('ok', false, 'reason', 'fleet_in_flight');
      end if;
    end if;
  end if;

  -- S1-BERTH (0216) HUNK C: berth every member and un-group it in ONE UPDATE (the XOR admits no
  -- intermediate: group NULL + berth NULL is illegal, so the FK's SET NULL alone can never succeed
  -- on a member — this manual write REPLACES the cascade, which then fires on zero rows). Berth =
  -- the consumed fleet's docked port when there was one, else the member's own resolved present
  -- per-ship fleet's port (the composed 0211 read — the transition arm), else Haven.
  update public.main_ship_instances s
     set group_id = null,
         berth_location_id = coalesce(
           v_port,
           (select f.current_location_id
              from public.fleets f
             where f.id = public.mainship_resolve_fleet(s.main_ship_id)
               and f.status = 'present' and f.location_mode = 'location'),
           c_haven),
         updated_at = now()
   where s.group_id = v_group and s.player_id = v_player;

  -- Delete the group. Members were un-grouped by Hunk C above (the 0160 FK's SET NULL is dead by
  -- construction under the XOR — see the header audit); the cascade therefore touches zero member
  -- rows. player_id predicate is defense-in-depth (v_group already owned).
  delete from public.ship_groups where group_id = v_group and player_id = v_player;

  return jsonb_build_object('ok', true, 'group_id', v_group);
end;
$$;

-- ── ACLs (0161 §D idiom). authenticated-only; the in-body gate rejects every call while team_command_enabled
--    is false. Explicit revokes are defense-in-depth (0043 default-revokes EXECUTE from PUBLIC on new funcs).
revoke execute on function public.delete_ship_group(uuid) from public, anon;
grant  execute on function public.delete_ship_group(uuid) to authenticated;

-- ════════ §6) the ship creators — a new ship is BORN BERTHED at the commission port ═══════════════
-- Both 0197 TRUE-head bodies byte-copied; the ONE marked hunk each adds berth_location_id to the
-- ship INSERT (group_id defaults NULL → the XOR demands a berth at birth). Neither function is an
-- md5-pinned PORT-ENTRY body (pins = writer/commission_first/normalize — grep-verified), so no pin
-- re-derivation is due. ASSIGN-FIRST is preserved: the ship is born berthed and ungrouped.

-- ── 6a) port_entry_commission_build — the 0197:222-330 body + the marked S1 berth hunk ────────────
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
         'stationary', 'at_location', null, null,
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
-- explicitly — the 0197 idiom carried forward):
revoke execute on function public.port_entry_commission_build(uuid, text) from public, anon, authenticated;
grant  execute on function public.port_entry_commission_build(uuid, text) to service_role;

-- ── 6b) ensure_main_ship_for_player — the 0197:339-390 body + the marked S1 berth hunk ────────────
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
       shield, max_shield,   -- SHIELD-2 (0197): the same commission copy as build's (creator consistency)
       berth_location_id)    -- S1-BERTH (0216) HUNK: born BERTHED (XOR: group_id defaults NULL)
    select p_player, h.hull_type_id, h.base_hp, h.base_hp, h.base_cargo_capacity, h.base_cargo_capacity_m3,
           h.base_support_capacity, h.base_captain_slots, h.base_module_slots,
           -- SHIELD-2 (0197) HUNK: born FULL, exactly as the build core above. The hull lookup
           -- was ALREADY in scope (the 0078-shaped insert selects from the hull row), so the copy
           -- is two added column refs — the cheapest honest form. Defaults would carry 0/0 today,
           -- but the two creators must stay consistent the day ACT-SHIELD raises base_shield (a
           -- legacy-ensure ship born 0/0 beside commission ships born full would be a silent fork).
           h.base_shield, h.base_shield,
           -- END SHIELD-2 (0197) HUNK
           -- S1-BERTH (0216) HUNK: berth = Haven, the commission/entry port — this legacy creator
           -- births a bare (fleetless) ship, and under NO-HOME its place is a PORT, never "home".
           'b1a00001-0066-4a00-8a00-000000000001'::uuid
           -- END S1-BERTH (0216) HUNK
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

-- ════════ §7) get_my_fleet_positions — the 0212 TRUE head, byte-copied, + the ONE berthed hunk ════
--
-- ★★ TRUE-HEAD DECLARATION — READ THIS BEFORE TOUCHING THIS FUNCTION AGAIN ★★
-- As of this migration the TRUE head of get_my_fleet_positions is THIS FILE (previously 0212:58-219,
-- before that 0211:225-353, before that 0200:24-148). Any later step MUST copy from 0216 — never
-- from 0212/0211/0200. Rebuilding from a stale head is exactly how 0136 silently re-inlined the dock
-- block and forced 0138 to exist. (0211's docked hunk and 0212's three hunks all survive here
-- VERBATIM — the selftest's stale-head tripwires grep this file for them.)
--
-- THE HUNK (gated on fleet_movement_unified_enabled, read ONCE — rollback keeps 0212's exact
-- behavior): a ship the ONE resolver returns NO fleet for, whose berth is set, and whom no other
-- arm placed → place='berthed', location_id = the berth. This is the ship tab's ONE location read
-- for an unfleeted ship — INFO, never a map marker (the client draws no marker for 'berthed').
-- Fail-closed survives: a ship with neither fleet nor berth-visible place stays 'hidden'.
-- Dark-reach argument (the 3c-1 lesson): dark the hunk is gated off entirely — byte-parity with
-- 0212 by construction, not by reasoning about reachable shapes.
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
  v_mv     record;
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
  for s in
    select main_ship_id, name, hull_type_id, status, spatial_state, space_x, space_y,
           berth_location_id   -- S1-BERTH (0216): read with the row (part of the ONE hunk)
      from public.main_ship_instances
     where player_id = v_player
       and status <> 'destroyed'
       and coalesce(spatial_state, '') <> 'destroyed'
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
        -- answers first (0210:188-189: the position is read from the FLEET, never the ship). The SHIP
        -- fallback below is the dark parity path — dark, 'in_space' requires ZERO active fleets, so
        -- the resolver returns NULL, the fleet read matches nothing, and the elsif is the pre-0212
        -- arm verbatim. DO NOT "clean up" the elsif: it is load-bearing until step 4c retires the
        -- ship columns, and the selftest pins its presence.
        select f.space_x, f.space_y
          into v_sx, v_sy
          from public.fleets f
         where f.id = public.mainship_resolve_fleet(s.main_ship_id) and f.location_mode = 'space'
         limit 1;
        if v_sx is not null and v_sy is not null then
          v_place := 'in_space';
        elsif s.space_x is not null and s.space_y is not null then
          -- held in open space on the ship's own (retired-layer) coordinates — the pre-0212 arm.
          v_place := 'in_space';
          v_sx    := s.space_x;
          v_sy    := s.space_y;
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

      elsif v_state = 'in_transit' then
        -- Coordinate (OSN) transit — the committed movement segment for client-side interpolation.
        select origin_x, origin_y, target_x, target_y, target_kind, depart_at, arrive_at
          into v_mv
          from public.main_ship_space_movements
         where main_ship_id = s.main_ship_id and status = 'moving'
         limit 1;
        if found then
          v_place := 'transit';
          v_seg   := jsonb_build_object(
            'origin_x', v_mv.origin_x, 'origin_y', v_mv.origin_y,
            'target_x', v_mv.target_x, 'target_y', v_mv.target_y,
            'target_kind', v_mv.target_kind,
            'depart_at', v_mv.depart_at, 'arrive_at', v_mv.arrive_at);
        end if;

      elsif v_state = 'legacy_transit' then
        -- Legacy (spatial_state NULL) transit — the committed fleet_movements segment.
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
      -- FLEET-GO 3c-3 (hunk 3 of 3): the emit reads the RESOLVED coordinate (fleet-first, ship
      -- fallback) instead of the ship columns. Dark, v_sx/v_sy carry exactly s.space_x/s.space_y
      -- (hunk 2's elsif) → byte-identical.
      'space_x',      case when v_place = 'in_space' then v_sx else null end,
      'space_y',      case when v_place = 'in_space' then v_sy else null end,
      'segment',      v_seg
    ));
  end loop;

  return v_out;
end;
$$;

-- Authenticated-only owner read (strip the default PUBLIC/anon grant that a new function receives on create,
-- then grant to authenticated). SECURITY DEFINER, so the nested validate_context call runs as owner regardless
-- of its own service_role-only grant — the get_my_docked_store (0158) posture exactly.
revoke all on function public.get_my_fleet_positions() from public;
grant execute on function public.get_my_fleet_positions() to authenticated;

-- ════════ §8) self-assert (deploy-time, raises on failure — the 0213/0214 idiom) ══════════════════
do $s1berth$
declare
  v_src text;
  a int; b int; c int; d int; e int; f int; g int; h int; i int;
begin
  -- (a) THE XOR exists, is VALIDATED (not NOT VALID), and says exactly the mutual exclusion.
  select pg_get_constraintdef(oid) into v_src
    from pg_constraint
   where conname = 'main_ship_instances_berth_xor_fleet'
     and conrelid = 'public.main_ship_instances'::regclass and convalidated;
  if v_src is null then
    raise exception 'S1-BERTH self-assert FAIL: the berth-xor-fleet CHECK is missing or NOT VALID'; end if;
  if position('group_id IS NULL' in v_src) = 0 or position('berth_location_id IS NOT NULL' in v_src) = 0 then
    raise exception 'S1-BERTH self-assert FAIL: the CHECK does not state the XOR (got %)', v_src; end if;

  -- (b) coverage: ZERO rows violate either shape (the backfill assert re-stated post-CHECK —
  --     belt and braces; on prod this ran over the real data).
  select count(*) into a from public.main_ship_instances
   where (group_id is null) <> (berth_location_id is not null);
  if a <> 0 then
    raise exception 'S1-BERTH self-assert FAIL: % ship row(s) violate the XOR', a; end if;

  -- (c) assign_ship_to_group: single definition, authenticated-executable, 0213 head retained
  --     (fleet-control flag read + cap token + resolvers + command-role reset + 0213 guard tokens),
  --     and the S1 hunks present in guard → cap → UPDATE(with berth) → mint order.
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'assign_ship_to_group') <> 1 then
    raise exception 'S1-BERTH self-assert FAIL: assign_ship_to_group is not a single definition'; end if;
  select prosrc into v_src from pg_proc where oid = 'public.assign_ship_to_group(uuid, uuid)'::regprocedure;
  if not has_function_privilege('authenticated', 'public.assign_ship_to_group(uuid, uuid)', 'execute') then
    raise exception 'S1-BERTH self-assert FAIL: assign_ship_to_group not authenticated-executable'; end if;
  if position('v_fleet_control boolean := public.cfg_bool(''fleet_control_enabled'')' in v_src) = 0
     or position('fleet_full' in v_src) = 0
     or position('mainship_resolve_owned_group' in v_src) = 0
     or position('is_command_ship = case when group_id is distinct from v_group' in v_src) = 0
     or position('fleet_ambiguous' in v_src) = 0
     or position('group_fleet_in_flight' in v_src) = 0
     or position('group_fleet_elsewhere' in v_src) = 0
     or position('group_on_sortie' in v_src) = 0
     or position('ship_group_resolve_fleet' in v_src) = 0 then
    raise exception 'S1-BERTH self-assert FAIL: the 0213 head did not survive in assign_ship_to_group'; end if;
  -- NOTE the reason-form: 'fleet_in_flight' alone is a SUBSTRING of the 0213 token
  -- 'group_fleet_in_flight' and would be vacuously satisfied by the head.
  if position('''reason'', ''fleet_in_flight''' in v_src) = 0
     or position('berth_location_id = case when v_group is not null then null else v_berth end' in v_src) = 0
     or position('v_ship_berth = v_gf.current_location_id' in v_src) = 0
     or position('presence_create(v_player, v_mint' in v_src) = 0
     or position('''must_unassign_first''' in v_src) = 0
     or position('main_ship_id = v_ship and player_id = v_player for update' in v_src) = 0
     or position('mainship_space_location_target_legal(v_ship_berth)' in v_src) = 0 then
    raise exception 'S1-BERTH self-assert FAIL: an S1 assign hunk is missing (unassign refusal / XOR update clause / berth co-location read / mint / cross-group arm / ship-row lock / mint legality gate)'; end if;
  a := position('from public.ship_groups' in v_src);            -- the (first) group lock
  h := position('main_ship_id = v_ship and player_id = v_player for update' in v_src);  -- the SHIP lock (MAJOR-4)
  b := position('fleet_ambiguous' in v_src);
  i := position('if v_cur_group = v_group then' in v_src);      -- same-group short-circuit (MINOR-5)
  -- the QUOTED code token, not the bare word — the ship-lock hunk's comment names the token
  -- earlier in the body and a bare-word position would land in prose (the grep-vacuity class).
  d := position('''must_unassign_first''' in v_src);            -- cross-group refusal (MAJOR-1)
  c := position('group_fleet_elsewhere' in v_src);
  e := position('fleet_full' in v_src);
  f := position('update public.main_ship_instances' in v_src);  -- the ONE ship write
  g := position('insert into public.fleets' in v_src);          -- the mint (post-write)
  -- ORDER: group lock → SHIP lock (before any berth/group read the mint trusts) → ambiguous →
  -- same-group ok (fail-closed beats idempotence on a broken invariant) → cross-group refusal →
  -- the =1 arms (elsewhere/sortie ride the existing chain) → cap → write → mint.
  if not (a > 0 and a < h and h < b and b < i and i < d and d < c
          and c < e and e < f and f < g) then
    raise exception 'S1-BERTH self-assert FAIL: assign hunk order broken (lock=%, shiplock=%, ambiguous=%, samegroup=%, crossgroup=%, elsewhere=%, cap=%, update=%, mint=%)', a, h, b, i, d, c, e, f, g; end if;
  d := position('group_on_sortie' in v_src);
  if not (c < d and d < e) then
    raise exception 'S1-BERTH self-assert FAIL: the sortie arm left its place (elsewhere=%, sortie=%, cap=%)', c, d, e; end if;

  -- (d) delete_ship_group: single definition, authenticated-executable; the consume + the ONE
  --     member berth UPDATE sit BEFORE the delete (a berth after the delete berths nobody — the
  --     cascade has already violated the CHECK by then).
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'delete_ship_group') <> 1 then
    raise exception 'S1-BERTH self-assert FAIL: delete_ship_group is not a single definition'; end if;
  select prosrc into v_src from pg_proc where oid = 'public.delete_ship_group(uuid)'::regprocedure;
  if not has_function_privilege('authenticated', 'public.delete_ship_group(uuid)', 'execute') then
    raise exception 'S1-BERTH self-assert FAIL: delete_ship_group not authenticated-executable'; end if;
  if position('ship_group_resolve_fleet' in v_src) = 0
     or position('''reason'', ''fleet_in_flight''' in v_src) = 0
     or position('group_on_sortie' in v_src) = 0
     or position('presence_complete' in v_src) = 0 then
    raise exception 'S1-BERTH self-assert FAIL: a delete hunk is missing (leaf compose / refusal arms / consume)'; end if;
  a := position('for update' in v_src);
  b := position('presence_complete' in v_src);
  c := position('update public.main_ship_instances' in v_src);
  d := position('delete from public.ship_groups' in v_src);
  if not (a > 0 and a < b and b < c and c < d) then
    raise exception 'S1-BERTH self-assert FAIL: delete order broken (lock=%, consume=%, berth-members=%, delete=%)', a, b, c, d; end if;

  -- (e) BOTH ship creators write the berth in their INSERT (creator consistency — the 0197 rule).
  select prosrc into v_src from pg_proc where oid = 'public.port_entry_commission_build(uuid, text)'::regprocedure;
  if position('berth_location_id' in v_src) = 0 then
    raise exception 'S1-BERTH self-assert FAIL: port_entry_commission_build does not berth the newborn ship'; end if;
  if position('h.base_shield, h.base_shield' in v_src) = 0 or position('soul_roll_traits_for_ship' in v_src) = 0 then
    raise exception 'S1-BERTH self-assert FAIL: the 0197 build head did not survive (shield copy / soul hook)'; end if;
  if has_function_privilege('authenticated', 'public.port_entry_commission_build(uuid, text)', 'execute') then
    raise exception 'S1-BERTH self-assert FAIL: port_entry_commission_build became client-callable'; end if;
  select prosrc into v_src from pg_proc where oid = 'public.ensure_main_ship_for_player(uuid)'::regprocedure;
  if position('berth_location_id' in v_src) = 0 then
    raise exception 'S1-BERTH self-assert FAIL: ensure_main_ship_for_player does not berth the newborn ship'; end if;
  if position('main_ship_commission' in v_src) = 0 or position('h.base_shield, h.base_shield' in v_src) = 0 then
    raise exception 'S1-BERTH self-assert FAIL: the 0197 ensure head did not survive (advisory lock / shield copy)'; end if;

  -- (f) the PORT-ENTRY md5 pins are NOT invalidated: none of the three pinned bodies was re-created
  --     here (this migration must not contain their definitions — checked by name against what WAS
  --     re-created; the pins' own verify script remains the authority at the deploy gate).
  --     (Nothing to compute here — the assert is that the three names are absent from this file's
  --     re-creates, which construction guarantees; recorded for the reader.)

  -- (g) get_my_fleet_positions: single definition, authenticated-executable, the 0212 hunks ALL
  --     survive (stale-head tripwires), and the berthed hunk is present and GATED.
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'get_my_fleet_positions') <> 1 then
    raise exception 'S1-BERTH self-assert FAIL: get_my_fleet_positions is not a single definition'; end if;
  select prosrc into v_src from pg_proc where oid = 'public.get_my_fleet_positions()'::regprocedure;
  if not has_function_privilege('authenticated', 'public.get_my_fleet_positions()', 'execute') then
    raise exception 'S1-BERTH self-assert FAIL: get_my_fleet_positions not authenticated-executable'; end if;
  if position('f.id = public.mainship_resolve_fleet(s.main_ship_id) and f.status = ''present''' in v_src) = 0
     or position('f.id = public.mainship_resolve_fleet(s.main_ship_id) and fm.status = ''moving''' in v_src) = 0
     or position('f.id = public.mainship_resolve_fleet(s.main_ship_id) and f.location_mode = ''space''' in v_src) = 0
     or position('s.space_x is not null' in v_src) = 0 then
    raise exception 'S1-BERTH self-assert FAIL: a 0211/0212 hunk was lost — the map read was rebuilt from a stale head (the 0136 mistake)'; end if;
  if position('v_unified and v_place = ''hidden'' and s.berth_location_id is not null' in v_src) = 0
     or position('v_place := ''berthed''' in v_src) = 0 then
    raise exception 'S1-BERTH self-assert FAIL: the berthed hunk is missing or un-gated'; end if;
  h := position('v_place := ''berthed''' in v_src);
  i := position('jsonb_build_array' in v_src);
  if not (h > 0 and h < i) then
    raise exception 'S1-BERTH self-assert FAIL: the berthed hunk does not precede the emit (berthed=%, emit=%)', h, i; end if;

  -- (h) the composed authorities are UNTOUCHED: the 0213 leaf keeps its shape key and stays
  --     internal-only; the 0210 resolver keeps its fail-closed NULL (the 0214 (g) pin, re-stated —
  --     this migration composes the resolver in three new places and must not have loosened it).
  select prosrc into v_src from pg_proc where oid = 'public.ship_group_resolve_fleet(uuid, uuid)'::regprocedure;
  if position('main_ship_id is null' in v_src) = 0 then
    raise exception 'S1-BERTH self-assert FAIL: the 0213 leaf lost its main_ship_id IS NULL key'; end if;
  if has_function_privilege('anon', 'public.ship_group_resolve_fleet(uuid, uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.ship_group_resolve_fleet(uuid, uuid)', 'execute') then
    raise exception 'S1-BERTH self-assert FAIL: ship_group_resolve_fleet became client-callable'; end if;
  select prosrc into v_src from pg_proc where oid = 'public.mainship_resolve_fleet(uuid)'::regprocedure;
  if position('return null;  -- fail closed' in v_src) = 0 then
    raise exception 'S1-BERTH self-assert FAIL: mainship_resolve_fleet lost its fail-closed NULL'; end if;

  raise notice 'S1-BERTH self-assert ok: XOR installed+validated over 100%% of rows; assign/delete/creators/map-read re-created with heads intact, hunks present, orders pinned; leaf + resolver untouched';
end $s1berth$;
