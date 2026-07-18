-- FLEET-GO 4b-0 — THE PRE-FLIP OBLIGATION: ASSIGNMENT LEARNS THE GROUP HAS A FLEET. Migration 0213.
--
-- Charter: docs/MOVEMENT_UNIFICATION_CHARTER.md §0 (the recorded bug class), §2 (membership IS
-- position), §4 (compose, never hand-roll), and step 4b's ⚠ PRE-FLIP OBLIGATION block — this
-- migration IS that obligation's guard half. Companion reading: 0210's LESSON THREE (header +
-- resolver comment 0210:77-84), which recorded the defect and deferred it here.
--
-- ── THE DEFECT (verified at source, again — this charter's inventory has been wrong five times) ────
-- mainship_resolve_fleet (0210:85-100) resolves a member's fleet from LIVE membership by SHAPE
-- (group_id = <g> AND main_ship_id IS NULL AND status in idle/moving/present/returning), gated on
-- fleet_movement_unified_enabled. The live hunt (send_ship_group_hunt, 0168→0204:678-682) mints
-- EXACTLY that shape, and its manifest (group_sortie_members) is FROZEN at send.
-- assign_ship_to_group (0161:96 → TRUE head 0204:139-221; those two are the ONLY definitions,
-- re-derived by loose-shape grep, and 0204:805-809 self-asserts its own prosrc) has NO
-- movement-state guard. So the moment the flag lights: assign a docked ship into a group whose
-- fleet is elsewhere and every read answers the FLEET's place, not the ship's — it reads as moving
-- with the hunt, then docked at the HUNT SITE, while its own present fleet + active
-- location_presence sit at its real port. get_my_docked_store would get_or_create_store at the
-- WRONG port. That is the ghost-dock duality (§0) re-entering in READ form.
--
-- ── THE FIX: a CO-LOCATION guard on assignment INTO a group, lit-only ─────────────────────────────
-- Under §2 membership IS position, so joining a fleet is only coherent where the fleet actually is.
-- The predicate is CO-LOCATION, not "fleet in an active movement": the charter's own failure example
-- ("docked at the HUNT SITE") is a *present*-status failure, and a flat reject on 'present' would ban
-- the roster's bread-and-butter operation post-flip, when present-at-port is the NORMAL state of
-- every docked fleet. So, with the group's live group-shaped fleet resolved:
--   0 fleets  → ALLOW (fall through — today's semantics; the bootstrap case: no fleet, no position).
--   >1 fleets → reject 'fleet_ambiguous' (fail closed; the resolver fails closed on the same broken
--               invariant, 0210:90-92, and the mover/brake already named this token, 0207/0209 —
--               one broken state, one token; the plan proposed no token for this arm).
--   1, status moving/returning → reject 'group_fleet_in_flight'.
--   1, present at a port AND the assignee's own present fleet + active presence sit at the SAME
--      port AND the group has NO OPEN SORTIE → ALLOW (co-located: the read answer and the ship's
--      real dock coincide, and no frozen manifest is in play).
--   1, co-located but the group HAS an open sortie (a live gsm-manifest fleet, the mover's guard-7
--      read, 0207:161-172) → reject 'group_on_sortie'. Co-location does NOT override a sortie: the
--      manifest froze at send, the fleet will depart 'returning' on it, and a member added mid-
--      sortie is a ship the reconciler will never dock — §0's ghost-dock through the ALLOW arm
--      (the 0213 review's Finding 1).
--   anything else (idle = parked in open space per 0208/0209 — a docked ship cannot be there;
--      present at a different port; incoherent rows) → reject 'group_fleet_elsewhere'.
-- The leaf is read with ONE statement (a single FOR scan that counts and captures) — one READ
-- COMMITTED snapshot, so the settle cron cannot retire the fleet between a count and a re-select
-- (the review's Finding 3).
-- UNASSIGN (p_group_id null) is STRUCTURALLY untouched — the guard lives inside the non-null branch.
-- Leaving a fleet from anywhere is manifest-law (the hunt's frozen manifest wins; the reconciler
-- neither gains nor loses a sortie member by live membership).
--
-- ── THE LOCK (Hunk B): lit takes the group row FOR UPDATE; dark keeps the head's FOR SHARE ────────
-- WHY: the head's assign lock is FOR SHARE (0204:182) and both sends lock the group FOR SHARE too
-- (0168:175, 0204:261) — FOR SHARE does not conflict with FOR SHARE, and 0168:239-241 DOCUMENTS the
-- resulting assign-vs-send race (a ship slipping in between the send's gather and its manifest
-- freeze). Tolerated then: manifest-wins made it display-only. For THIS guard that race IS the
-- defect in TOCTOU form — a guard that can be raced is no guard. FOR UPDATE (lit only) conflicts
-- with the sends' FOR SHARE and with the mover/brake's FOR UPDATE (0207:118, 0209), so either:
--   • the send/go commits first → this assign's guard read (a NEW statement snapshot after the lock
--     wait, READ COMMITTED) sees the fleet → reject; or
--   • this assign commits first → the send's member gather, taken under the group lock it was
--     waiting for, includes the new ship → the ship IS on the manifest. No orphan window.
-- Dark keeps FOR SHARE byte-identically: THE LOCK FOOTPRINT IS PART OF PARITY — a dark assign must
-- not start conflicting with a concurrent dark send the day this deploys.
-- HONEST LIMIT (say it plainly): a deterministic two-session race is NOT testable in this repo's
-- single-session proof harness — psql runs one connection, and a second blocked session cannot be
-- stepped deterministically from SQL. The race closure above is proven by lock-conflict reasoning
-- plus a mutation-tested static assert on the gated lock branch (scripts/fleetgo-proof.sh); a
-- runtime marker that cannot fail would be decoration, so none is pretended.
--
-- ── LOCKING ORDER (the 0164 B-stop lesson; a HIGH deadlock was already caught in this arc) ────────
-- Established orders: group → member ships (assign/delete/send/hunt: 0168:200-208, 0204:287-294);
-- mover/brake: group FOR UPDATE → fleet FOR UPDATE, no ship locks; settle cron: movement → fleet →
-- ship, and no RPC may take a movement lock or an up-front member-ship lock preceding it.
-- THIS guard takes NO movement lock, NO fleet lock, NO new ship lock: Hunk C is a plain MVCC read
-- of fleets (+ location_presence for the assignee) under the group-row lock, and the only ship-row
-- write/lock is the head's own single-row UPDATE at the end — the same group → ship order every
-- sibling uses. Verified by reading what is written below, not assumed.
--
-- ── COMPOSITION: ONE new leaf, ship_group_resolve_fleet(p_player, p_group) ────────────────────────
-- The group-shaped-fleet SHAPE (group_id + main_ship_id IS NULL + live status — NEVER group_id
-- alone: the legacy expedition send tags group_id onto PER-MEMBER fleets, 0204:316-318, display-only,
-- the exact key mistake 0210:69-71 warns about) now has FOUR inline copies: the mover (0207:178-192),
-- the brake (0209), the resolver (0210:86-97), the oracle (0210:168-171). This guard does not add a
-- fifth: it composes the leaf below. 0207/0209/0210 are NOT re-created now (each is a live, proven
-- body; re-creating three functions to save three queries is churn, and 0210's header already marks
-- its own fold-up) — AT STEP 4 fold them onto this leaf: one query, one authority.
--
-- ── PARITY DISCIPLINE (ABSOLUTE — assign is a LIVE hot function; team command is ON in prod) ──────
-- Byte-copied from the 0204:139-221 head with exactly THREE marked hunks (A: the flag read; B: the
-- gated lock strength; C: the gated guard). Flag OFF (the committed seed): A is a side-effect-free
-- stable read, B takes the identical FOR SHARE, C is skipped entirely → behavior, envelopes, writes,
-- AND lock footprint equal the head on EVERY input — including the load-bearing REACHABLE dark
-- state (team_command_enabled live + hunt fleet mid-flight + assign a docked ship into that group),
-- which must SUCCEED while dark exactly as today. FLEETGO_PASS_ASSIGNGUARD_DARKPARITY asserts THAT
-- state specifically, not a convenient fixture (the 0210 lesson). Verified by mechanical diff
-- against 0204:139-221, not by claim.
--
-- ── GROUNDING (grep-verified) ─────────────────────────────────────────────────────────────────────
--   assign_ship_to_group        — TRUE head 20260618000204:139-221 (0161:96 is the only other def;
--                                 loose-shape grep over create/drop function found no third)
--   cfg_bool                    — 20260618000046 (reused)
--   mainship_resolve_owned_ship — 20260618000081 (reused, via the head)
--   mainship_resolve_owned_group— 20260618000161 (reused, via the head)
--   the fleet shape             — 0168/0204 (the hunt mints it), 0207/0209/0210 (inline matches)

-- ── §1) ship_group_resolve_fleet — the ONE authority on "the group's live group-shaped fleet(s)" ──
-- Returns the live rows; POLICY (0 → bootstrap-allow, >1 → fail closed, 1 → inspect) stays with the
-- caller, exactly as the mover/resolver each apply their own policy over this same shape today.
-- Internal leaf: composed by security-definer RPCs; not client-callable (no grants).
-- AT STEP 4: fold 0207:178-192, 0209's copy, and 0210:86-97/168-171 onto this leaf.
create or replace function public.ship_group_resolve_fleet(p_player uuid, p_group uuid)
returns setof public.fleets
language sql
stable
security definer
set search_path = public
as $$
  -- Keyed group_id + main_ship_id IS NULL — NOT group_id alone: the legacy expedition send tags
  -- group_id onto PER-MEMBER fleets (0204:316-318, display-only, "routing never reads it").
  select *
    from public.fleets
   where group_id = p_group
     and player_id = p_player
     and main_ship_id is null
     and status in ('idle', 'moving', 'present', 'returning');
$$;

comment on function public.ship_group_resolve_fleet(uuid, uuid) is
  'FLEET-GO 4b-0 (0213): the ONE authority on a group''s live group-shaped fleet(s) (group_id + '
  'main_ship_id IS NULL + live status — never group_id alone; the legacy expedition send tags '
  'group_id onto per-member fleets, display-only). Returns rows; policy is the caller''s. The mover '
  '(0207), brake (0209) and resolver/oracle (0210) inline this same shape — fold them onto this '
  'leaf at step 4. Internal: no client grants.';

revoke all on function public.ship_group_resolve_fleet(uuid, uuid) from public;

-- ── §2) assign_ship_to_group — the 0204:139-221 head, byte-copied, + the THREE marked hunks ───────
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
      if v_gf_n = 1 then
        if v_gf.status in ('moving', 'returning') then
          return jsonb_build_object('ok', false, 'reason', 'group_fleet_in_flight');
        end if;
        -- CO-LOCATION: the fleet is settled at a port (present + location + a real port id) AND the
        -- assignee's OWN present fleet + ACTIVE presence sit at that SAME port. The assignee side is
        -- the transition-world dock shape (per-ship fleet + presence — the same pair the hunt's
        -- common-port gather reads, 0204:607-611); after step 4 the assignee will itself be a group
        -- member and this arm is revisited with the rest of the transition surface.
        if not (v_gf.status = 'present' and v_gf.location_mode = 'location'
                and v_gf.current_location_id is not null
                and exists (
                      select 1
                        from public.fleets f
                        join public.location_presence lp
                          on lp.fleet_id = f.id and lp.status = 'active'
                       where f.main_ship_id = v_ship
                         and f.player_id = v_player
                         and f.status = 'present'
                         and f.location_mode = 'location'
                         and f.current_location_id = v_gf.current_location_id
                         and lp.location_id = v_gf.current_location_id
                    )) then
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
  end if;

  -- Single-row write. v_ship and v_group were both asserted against v_player=auth.uid() → the pair is
  -- same-player by construction; the player_id predicate is defense-in-depth.
  -- FLEET-CONTROL (0204): the per-fleet command-role reset — when the fleet CHANGES (RHS group_id is the
  -- OLD value in a SET clause; `is distinct from` covers null↔fleet either way), clear is_command_ship so
  -- the role must be re-designated in the new fleet. A same-fleet re-assign keeps it. Always-on: inert while
  -- dark (the column is ignored), so this is the only write delta beyond the flag-gated cap hunk.
  update public.main_ship_instances
     set group_id = v_group,
         is_command_ship = case when group_id is distinct from v_group then false else is_command_ship end,
         updated_at = now()
   where main_ship_id = v_ship and player_id = v_player;

  return jsonb_build_object('ok', true, 'main_ship_id', v_ship, 'group_id', v_group);
end;
$$;
-- ACL: the head's grants survive CREATE OR REPLACE; re-asserted defense-in-depth (the 0204 posture).
revoke execute on function public.assign_ship_to_group(uuid, uuid) from public, anon;
grant  execute on function public.assign_ship_to_group(uuid, uuid) to authenticated;

-- ── §3) self-assert (deploy-time, raises on failure — the 0204:805 idiom, widened) ────────────────
do $assignguard$
declare
  v_src  text;
  v_lock int; v_amb int; v_guard int; v_elsw int; v_sort int; v_cap int; v_upd int;
begin
  -- (a) assign_ship_to_group: single definition, authenticated-executable.
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'assign_ship_to_group') <> 1 then
    raise exception 'ASSIGN-GUARD self-assert FAIL: assign_ship_to_group is not a single definition'; end if;
  select prosrc into v_src from pg_proc where oid = 'public.assign_ship_to_group(uuid, uuid)'::regprocedure;
  if not has_function_privilege('authenticated', 'public.assign_ship_to_group(uuid, uuid)', 'execute') then
    raise exception 'ASSIGN-GUARD self-assert FAIL: assign_ship_to_group not authenticated-executable'; end if;

  -- (b) the 0204 head survives: the FLEET-CONTROL flag read, the cap token, the owner resolvers, and
  --     the command-role reset (parity is RETENTION of the head, hunks are ADDITIONS to it).
  if position('v_fleet_control boolean := public.cfg_bool(''fleet_control_enabled'')' in v_src) = 0
     or position('fleet_full' in v_src) = 0
     or position('mainship_resolve_owned_group' in v_src) = 0
     or position('is_command_ship = case when group_id is distinct from v_group' in v_src) = 0 then
    raise exception 'ASSIGN-GUARD self-assert FAIL: the 0204 head did not survive (flag read / fleet_full / resolver / role reset)'; end if;

  -- (c) the three hunks exist: the gate read, BOTH lock arms, ALL FOUR reject reasons (in-flight /
  --     elsewhere / on-sortie / the broken-invariant ambiguous arm), the sortie-manifest read, and
  --     the leaf compose.
  if position('v_unified boolean := public.cfg_bool(''fleet_movement_unified_enabled'')' in v_src) = 0
     or position('player_id = v_player for update' in v_src) = 0
     or position('player_id = v_player for share' in v_src) = 0
     or position('fleet_ambiguous' in v_src) = 0
     or position('group_fleet_in_flight' in v_src) = 0
     or position('group_fleet_elsewhere' in v_src) = 0
     or position('group_on_sortie' in v_src) = 0
     or position('group_sortie_members' in v_src) = 0
     or position('ship_group_resolve_fleet' in v_src) = 0 then
    raise exception 'ASSIGN-GUARD self-assert FAIL: a 0213 hunk is missing (gate read / gated lock arms / reject reasons incl. ambiguous+sortie / leaf compose)'; end if;

  -- (d) ORDER: lock → ambiguous → in-flight → elsewhere → on-sortie → cap → write. The guard arms
  --     must sit BETWEEN the group lock and the ship UPDATE (and before the cap), inside the
  --     non-null branch — a guard after the write guards nothing, one before the lock is the TOCTOU
  --     it exists to close, and the sortie arm must guard the would-be ALLOW (after elsewhere).
  v_lock  := position('from public.ship_groups' in v_src);
  v_amb   := position('fleet_ambiguous' in v_src);
  v_guard := position('group_fleet_in_flight' in v_src);
  v_elsw  := position('group_fleet_elsewhere' in v_src);
  v_sort  := position('group_on_sortie' in v_src);
  v_cap   := position('fleet_full' in v_src);
  v_upd   := position('update public.main_ship_instances' in v_src);
  if not (v_lock > 0 and v_lock < v_amb and v_amb < v_guard and v_guard < v_elsw
          and v_elsw < v_sort and v_sort < v_cap and v_cap < v_upd) then
    raise exception 'ASSIGN-GUARD self-assert FAIL: hunk order broken (lock=%, ambiguous=%, guard=%, elsewhere=%, sortie=%, cap=%, update=%)', v_lock, v_amb, v_guard, v_elsw, v_sort, v_cap, v_upd; end if;

  -- (e) the leaf: deployed, pins the SHAPE (never group_id alone), and NOT client-callable.
  --     Existence is guarded by NAME FIRST: a bare ::regprocedure cast on a missing function raises
  --     its own "function does not exist" before any friendly message could fire (the review's
  --     Finding 7 — the first cut's v_src-is-null branch was dead code).
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'ship_group_resolve_fleet') <> 1 then
    raise exception 'ASSIGN-GUARD self-assert FAIL: ship_group_resolve_fleet not deployed (or not a single definition)'; end if;
  select prosrc into v_src from pg_proc where oid = 'public.ship_group_resolve_fleet(uuid, uuid)'::regprocedure;
  if position('main_ship_id is null' in v_src) = 0 then
    raise exception 'ASSIGN-GUARD self-assert FAIL: the leaf lost the main_ship_id IS NULL key (group_id alone matches the legacy per-member tag)'; end if;
  if has_function_privilege('anon', 'public.ship_group_resolve_fleet(uuid, uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.ship_group_resolve_fleet(uuid, uuid)', 'execute') then
    raise exception 'ASSIGN-GUARD self-assert FAIL: ship_group_resolve_fleet is client-callable (internal leaf: no grants)'; end if;

  raise notice 'ASSIGN-GUARD self-assert ok: 0204 head intact + hunks A/B/C present in lock->ambiguous->in-flight->elsewhere->sortie->cap->write order; leaf deployed, shape-keyed, internal-only';
end $assignguard$;
