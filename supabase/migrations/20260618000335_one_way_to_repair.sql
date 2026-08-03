-- ONE WAY TO REPAIR (0335) — two repair systems collapsed into one, by DELETION.
--
-- THE COMPLAINT (verbatim): "why does command ship have separate repair system? unnecessary"
--
-- ── FIRST, THE PREMISE, CORRECTED ────────────────────────────────────────────────────────────────
-- There was never a COMMAND-SHIP repair system. `main_ship_instances` is EVERY ship (77 rows on
-- production today; only 2 carry is_command_ship, and every fleet elects a lead by
-- `is_command_ship desc, max_hp desc, id asc` — 0315). "Main ship" is legacy naming from when a
-- player had exactly one hull. NO repair path anywhere reads is_command_ship — verified against the
-- deployed bodies of both functions, not inferred. What the name `repair_main_ship` actually
-- described was DISABLED-SHIP RECOVERY, and the misleading name is most of why the duplication
-- looked like a command-ship privilege.
--
-- But the duplication the owner objected to is REAL, and it is what this file deletes.
--
-- ── WHAT WAS TRUE BEFORE THIS FILE — two functions, one concept ──────────────────────────────────
--
--   repair_main_ship(uuid)                     [0081 signature, 0231 body, 0297 position hunk]
--     auth -> mainship_resolve_owned_ship -> status = 'destroyed' (else RAISE) -> max_hp > 0
--     -> mainship_port_of_ship(ship) is not null (else RAISE ship_not_at_port)
--     -> hp = max_hp, status = 'home'. Free. No knob, no wallet, no receipt, no idempotency.
--     RAISES on every rejection, so its "reason codes" were substrings of an exception message that
--     the client matched with String.includes (src/features/ship/shipRecovery.ts:126-150).
--     It also carried a DEAD BRANCH: `if cfg_bool('launch_from_dock_enabled') then <UPDATE A> else
--     <UPDATE B>`, where UPDATE A and UPDATE B are byte-identical. One flag read, two spellings of
--     one statement, zero behavioural difference. It dies with the function.
--
--   repair_ship_hull_at_port(uuid, numeric, uuid)                                          [0201]
--     auth -> cfg_bool('repair_economy_enabled') -> amount shape -> resolve owned ship
--     -> per-ship lock -> REJECT status='destroyed' (ship_destroyed)
--     -> mainship_resolve_docked_location(ship) is not null (else not_docked)
--     -> replay by (ship, request_id) -> missing hull -> clamp -> cfg_num('repair_credits_per_hp')
--     -> wallet_debit -> hp += restore -> repair_receipts row.
--     Returns a {ok, reason} ENVELOPE and never raises.
--
-- ── ESSENTIAL, OR INCIDENTAL? ────────────────────────────────────────────────────────────────────
-- Only THREE differences are essential, and all three are POLICY over one verb, not a second verb:
--   (1) PRECONDITION — one accepts a wreck, the other refuses it. That is a STATE, not a concept.
--   (2) AMOUNT — full restore vs a requested partial. Policy.
--   (3) COST — free vs priced. Policy, and the only genuinely load-bearing one: a wreck must never
--       be un-recoverable for want of credits (the 0052 NO-SOFTLOCK rule), so wreck recovery is
--       free by law and mending a dented hull is priced by the knob.
-- Everything else was incidental duplication that had already DRIFTED APART:
--   * TWO POSITION AUTHORITIES for one question. Recovery asked mainship_port_of_ship (0297, then
--     0334) — fleet-dock, then group-dock, then berth. The paid mend asked
--     mainship_resolve_docked_location (0092/0210) — which additionally demands a coherent
--     `at_location` context and a PRESENT FLEET. So a BERTHED ship (no fleet, tied up at a port)
--     read as "at a port" for recovery and as `not_docked` for mending, on the same tick. All three
--     of production's destroyed ships are in exactly that shape right now. The client had to grow a
--     whole extra sentence to paper over it — "Add this ship to a fleet on the Fleet tab to mend
--     its hull here" (src/features/ship/repairEconomy.ts:134) — copy that exists ONLY because of
--     this split, and that this file deletes.
--   * TWO ERROR PROTOCOLS — raise vs envelope — hence TWO client reason vocabularies and TWO
--     mappers, one of which matched on exception SUBSTRINGS.
--   * TWO CLIENT WRAPPERS — src/features/map/mainshipApi.ts:282 and
--     src/features/ship/repairApi.ts:62.
--   * ONE path had a per-ship lock, a receipt and replay protection; the other had none.
-- Verdict: INCIDENTAL. Two authors, two migrations, one concept.
--
-- ── ██ THE LIVE DEFECT THIS ALSO CLOSES ██ ───────────────────────────────────────────────────────
-- Production right now: repair_economy_enabled = true, repair_credits_per_hp = 0 (the owner set it
-- to 0 deliberately, to make repair free pending a combat audit). 0201's knob read is
--     if v_per_hp is null or v_per_hp <= 0 then return 'repair_misconfigured'
-- so ZERO IS TREATED AS A MISCONFIGURATION. Setting the price to free turned the paid mend OFF for
-- every player: every damaged living hull answers "Repair pricing is unavailable right now."
-- (src/features/ship/repairReasonMessage.ts:20). The client fold agrees — repairEconomy.ts's
-- foldRepairRate requires `n > 0` and answers null at 0, so the desk also shows no price.
-- This file makes ZERO MEAN FREE and keeps NULL/NEGATIVE failing closed. The knob is still the only
-- lever: restoring the price later is one set-knob call, exactly as before. Nothing is hardcoded
-- free anywhere in this file — grep it for a literal price and you will find none.
--
-- ── WHAT THIS FILE DOES ──────────────────────────────────────────────────────────────────────────
--   §1 repair_ship_hull(uuid, numeric, uuid) -> jsonb — NEW, and the ONE authority for "restore this
--      hull". One position gate, one reason vocabulary, one receipt ledger, one lock. Cost and
--      amount are POLICY inside it (eight lines), not a second function.
--   §2 DROP repair_main_ship(uuid) and DROP repair_ship_hull_at_port(uuid, numeric, uuid). Not
--      deprecated, not shimmed, not wrapped — dropped, which also drops their grants. A wrapper
--      that kept either name alive would be the second authority this slice exists to remove.
--   §3 ACL — the one RPC is authenticated-only; and repair_receipts' client table-write is REVOKED
--      (it still carries the Supabase project-default GRANT ALL to anon/authenticated that no
--      migration ever revoked — the exact 0254/danger_zones drift. RLS with a SELECT-only policy
--      already denies the writes; this closes the latent hole in the same slice that makes this
--      table the sole repair ledger).
--   §4 SELF-ASSERT — this migration's own effect, on an EMPTY database, asserting no seed and no
--      flag VALUE.
--
-- ── THE RENAME, AND WHY IT IS SAFE ───────────────────────────────────────────────────────────────
-- `repair_main_ship` is the misleading name. It is not renamed — it is DELETED, and its concept is
-- absorbed. Every caller was enumerated before writing this:
--   * IN-DATABASE: none. The only occurrence of either name in another deployed function body is a
--     COMMENT inside process_combat_ticks (0332's explanation of the wreck-status bug). Verified by
--     scanning every pg_proc body on production, not by grep over the repo.
--   * CLIENT: two wrappers, both replaced by one in this slice.
--   * PROOFS / FIXTURES / ACL ALLOWLISTS: repointed in this same commit — danger-combat-proof,
--     team-command-proof, repair-econ-proof, the osn3 realchain perm + fixture scripts, the
--     osn-hub1a / port-entry / portlaunch catalogs, the osn3 live-check scripts, and
--     scripts/verify-mainship-repair.mjs. A drop whose proof harness still calls the dropped object
--     is how the chain got wedged once already; the harness is part of the surface being retired.
--   * scripts/activate-repair-econ.{sh,sql} is DELETED. Its job — flipping repair_economy_enabled
--     to true — is done and permanent on production, and its preconditions pin prosrc strings of
--     two functions that no longer exist. A spent activation script that can only ever fail is
--     dead code, not a record.
-- Earlier docs (docs/MAINSHIP_TRANSITION.md §12) list repair_main_ship among "frozen canonical
-- RPCs (MUST NOT rewrite)". That freeze was already broken by 0222 and again by 0297, and the
-- owner's instruction outranks it.
--
-- ── WHAT DOES NOT CHANGE ─────────────────────────────────────────────────────────────────────────
--   * mainship_emergency_tow (0297 §3) — untouched. Towing is a different verb: it MOVES a wreck.
--     It remains the free, always-available route out of the position gate.
--   * get_my_disabled_ships (0297 §4) and mainship_port_of_ship (0297 §1 / 0334) — untouched.
--   * repair_receipts' shape, and repair_economy_enabled / repair_credits_per_hp — untouched keys.
--   * A destroyed ship still comes back to status='home' with a full hull. 'home' is the live idle
--     status of 74 of production's 77 ships and the only non-terminal value the
--     main_ship_instances_status_check CHECK offers; the NO-HOME law is about the home BASE
--     concept, not this enum literal, and 0332 relies on exactly this pair.
--
-- ── ONE DELIBERATE ORDERING CHANGE, STATED PLAINLY ───────────────────────────────────────────────
-- 0201 read repair_economy_enabled FIRST, before any row read ("no ship read, no wallet touch, no
-- heal"). The unified function cannot: whether the economy applies at all depends on whether the
-- hull is a WRECK, which is a row fact. So the flag is now read after the ship resolve, and a dark
-- flag can answer ship_not_found / not_at_port / nothing_to_repair before it answers
-- repair_economy_disabled. This discloses nothing: ownership is asserted first, so every one of
-- those answers is about the CALLER'S OWN ship. The properties that mattered are intact and are
-- asserted by the proof — a dark flag still moves NO wallet, heals NO hull and writes NO receipt.

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ── 0. PRECONDITIONS (read-only) — refuse to build on a base we did not slice from ───────────────
do $pre$
declare
  v_free text;
  v_paid text;
begin
  select prosrc into v_free from pg_proc where oid = to_regprocedure('public.repair_main_ship(uuid)')::oid;
  if v_free is null then
    raise exception '0335 PRECONDITION FAIL: repair_main_ship(uuid) is absent — this migration removes it and must not run on a chain that never had it';
  end if;
  select prosrc into v_paid from pg_proc
   where oid = to_regprocedure('public.repair_ship_hull_at_port(uuid,numeric,uuid)')::oid;
  if v_paid is null then
    raise exception '0335 PRECONDITION FAIL: repair_ship_hull_at_port(uuid,numeric,uuid) is absent';
  end if;

  -- The four guards the unified body must inherit, pinned in the SOURCES before they are dropped.
  -- Each names the exact string this file's replacement is derived from; if a guard moved under us,
  -- we stop rather than silently ship a repair that lost it.
  if position('mainship_port_of_ship' in v_free) = 0 then
    raise exception '0335 PRECONDITION FAIL: repair_main_ship lost 0297''s position gate — the unified body is derived from it';
  end if;
  if position('ship is not disabled' in v_free) = 0 then
    raise exception '0335 PRECONDITION FAIL: repair_main_ship lost its destroyed-only guard';
  end if;
  if position('mainship_resolve_docked_location' in v_paid) = 0 then
    raise exception '0335 PRECONDITION FAIL: repair_ship_hull_at_port lost its dock gate';
  end if;
  if position('repair_credits_per_hp' in v_paid) = 0 or position('wallet_debit' in v_paid) = 0 then
    raise exception '0335 PRECONDITION FAIL: repair_ship_hull_at_port lost the knob read or the wallet debit';
  end if;
  -- The 0-is-misconfigured defect this file closes must actually be there. If it is already gone,
  -- someone else fixed it and this file's premise is stale.
  if position('v_per_hp <= 0' in v_paid) = 0 then
    raise exception '0335 PRECONDITION FAIL: repair_ship_hull_at_port no longer treats a 0 price as misconfigured — the defect this file closes is not present, so its premise is stale';
  end if;

  -- The leaves the unified body composes, and the ledger it writes.
  if to_regclass('public.repair_receipts') is null then
    raise exception '0335 PRECONDITION FAIL: repair_receipts is absent';
  end if;
  if to_regprocedure('public.mainship_port_of_ship(uuid)') is null
     or to_regprocedure('public.mainship_resolve_owned_ship(uuid,uuid)') is null
     or to_regprocedure('public.mainship_space_lock_context(uuid,boolean)') is null
     or to_regprocedure('public.wallet_debit(uuid,numeric)') is null
     or to_regprocedure('public.cfg_num(text)') is null
     or to_regprocedure('public.cfg_bool(text)') is null then
    raise exception '0335 PRECONDITION FAIL: a leaf the unified repair composes is missing';
  end if;
  -- The other half of the position gate must exist: a gate with no way out is the softlock 0052
  -- forbids, and 0297 shipped the tow precisely so this gate could exist at all.
  if to_regprocedure('public.mainship_emergency_tow(uuid)') is null then
    raise exception '0335 PRECONDITION FAIL: mainship_emergency_tow(uuid) is missing — the position gate must never exist without its recovery route';
  end if;
  -- Nothing may already own the new name.
  if to_regprocedure('public.repair_ship_hull(uuid,numeric,uuid)') is not null then
    raise exception '0335 PRECONDITION FAIL: repair_ship_hull(uuid,numeric,uuid) already exists — this migration must not land over an unknown edit';
  end if;
end $pre$;


-- ══════════════════════════════════════════════════════════════════════════════════════════════════
-- §1. repair_ship_hull — THE ONE AUTHORITY FOR "RESTORE THIS HULL".
-- ══════════════════════════════════════════════════════════════════════════════════════════════════
-- One verb. Whether the hull is a wreck or merely dented changes only what it COSTS and how much it
-- restores — both read from this one body, in two clearly-marked policy blocks. There is no second
-- function to keep in step, no second position authority to disagree with, and no second reason
-- vocabulary for the client to map.
--
-- ARGUMENTS
--   p_main_ship_id — null resolves the caller's sole ship (the 0081 shim both predecessors used).
--                    The id is a REQUEST, never a claim: mainship_resolve_owned_ship asserts it.
--   p_repair_hp    — null means "all of it". A number is CLAMPED to the actual missing hull, so an
--                    over-request tops up to max_hp and never over-charges. Hull hp is INTEGER
--                    (0043), so a fractional or non-positive request is invalid_amount, never
--                    rounded.
--   p_request_id   — the replay key, REQUIRED. Every hull-moving repair writes a
--                    repair_receipts row keyed (main_ship_id, request_id); a replay of that pair
--                    returns the original receipt verbatim with no second debit, heal or row. One
--                    rule, both policies — the free recovery gained replay protection it never had.
create or replace function public.repair_ship_hull(
  p_main_ship_id uuid    default null,
  p_repair_hp    numeric default null,
  p_request_id   uuid    default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_player   uuid := auth.uid();
  v_ship_id  uuid;
  v_ship     public.main_ship_instances%rowtype;
  v_wreck    boolean;
  v_port     uuid;
  v_existing public.repair_receipts%rowtype;
  v_want     integer;
  v_missing  integer;
  v_restore  integer;
  v_per_hp   numeric;
  v_total    numeric;
  v_after    integer;
  v_status   text;
  v_receipt  uuid;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- REPLAY KEY (0201's invalid_request, now covering both policies).
  if p_request_id is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid_request');
  end if;

  -- AMOUNT SHAPE — only when an amount was actually named. NULL is the legitimate "all of it"
  -- request and must not be shape-rejected. The 1e6 cap keeps the integer cast safe.
  if p_repair_hp is not null
     and (p_repair_hp <= 0 or p_repair_hp <> floor(p_repair_hp) or p_repair_hp > 1000000) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_amount');
  end if;
  v_want := p_repair_hp::integer;   -- stays NULL for "all of it"

  -- OWNERSHIP — the same resolver every main-ship RPC uses; the client id is never trusted.
  v_ship_id := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship_id is null then
    return jsonb_build_object('ok', false, 'reason', 'ship_not_found');
  end if;

  -- PER-SHIP LOCK (0138 idiom, inherited from 0201) acquired BEFORE the hull read and held to txn
  -- end, so the read, the replay check and the debit/heal/receipt writes are one critical section
  -- against a concurrent repair of the SAME ship. The free recovery never had this; it does now.
  perform public.mainship_space_lock_context(v_ship_id);
  select * into v_ship from public.main_ship_instances where main_ship_id = v_ship_id;

  -- THE ONE STATE QUESTION. Everything below that differs between a wreck and a dent reads THIS.
  v_wreck := (v_ship.status = 'destroyed');

  -- ██ POSITION — ONE AUTHORITY, FOR EVERY HULL. ████████████████████████████████████████████████
  -- mainship_port_of_ship (0297 §1, extended by 0334) is the ONE answer to "which port is this ship
  -- physically at, regardless of its lifecycle status": the fleet's dock, then the GROUP's dock
  -- (0334 — "as a fleet we have arrived at a dock already"), then the berth. The predecessors
  -- disagreed here: the paid mend asked mainship_resolve_docked_location, which additionally
  -- demands a coherent at_location context AND a present fleet, so it answered not_docked for a
  -- berthed ship sitting at a port. Adopting the position leaf for both is strictly WIDER — every
  -- ship the dock resolver accepted, this one accepts (its ARM 1 is the same present +
  -- location_mode='location' test through the same fleet resolver, via fleet_docked_location) —
  -- so no repair that worked before stops working, and a berthed hull can now be mended where it
  -- plainly is. It is NOT routed through mainship_space_validate_context: that oracle answers the
  -- LIFECYCLE question first and short-circuits on 'destroyed', so it structurally cannot answer a
  -- position question about a wreck (0297's header proves this at file:line).
  -- IT IS NOT A SOFTLOCK: mainship_emergency_tow is free, always available to exactly the wrecks
  -- this rejects, and berths them at a port where this gate then passes.
  v_port := public.mainship_port_of_ship(v_ship_id);
  if v_port is null then
    return jsonb_build_object('ok', false, 'reason', 'not_at_port');
  end if;

  if v_ship.max_hp is null or v_ship.max_hp <= 0 then
    -- The predecessors said 'invalid max_hp' (raise) and 'invalid_amount' (envelope) for this same
    -- broken-hull-row case. One honest reason now.
    return jsonb_build_object('ok', false, 'reason', 'hull_unrepairable');
  end if;

  -- IDEMPOTENCY — a receipt for (ship, request_id) already exists → replay verbatim: no write, no
  -- re-debit, no re-heal (the 0174 salvage-receipts semantics; no payload-conflict check).
  select * into v_existing from public.repair_receipts
   where main_ship_id = v_ship_id and request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'idempotent_replay', true,
      'receipt_id', v_existing.receipt_id, 'main_ship_id', v_ship_id,
      'hp_before', v_existing.hp_before, 'hp_after', v_existing.hp_after,
      'hp_restored', v_existing.hp_restored, 'credits_per_hp', v_existing.credits_per_hp,
      'total_price', v_existing.total_price, 'location_id', v_existing.location_id);
  end if;

  v_missing := v_ship.max_hp - v_ship.hp;

  -- ██ AMOUNT POLICY ███████████████████████████████████████████████████████████████████████████
  -- A WRECK restores whole. Recovery is not a shop counter — a half-recovered hull is a state the
  -- game has no verb for, and the predecessor (hp = max_hp) is preserved exactly. A DENTED hull
  -- restores what was asked for, clamped to what is actually missing.
  if v_wreck then
    v_restore := greatest(v_missing, 0);
  else
    v_restore := least(coalesce(v_want, v_missing), v_missing);
    if v_restore <= 0 then
      return jsonb_build_object('ok', false, 'reason', 'nothing_to_repair',
        'hp', v_ship.hp, 'max_hp', v_ship.max_hp);
    end if;
  end if;
  -- A wreck whose hull is somehow already full still needs its status flip, so it does NOT reject
  -- here: it falls through with v_restore = 0, writes no receipt (repair_receipts' own
  -- hp_restored > 0 CHECK forbids one) and still comes home. Never a softlock.

  -- ██ COST POLICY ████████████████████████████████████████████████████████████████████████████
  -- WRECK RECOVERY IS FREE AND UNGATED — the 0052 NO-SOFTLOCK rule, and the ONE genuinely
  -- essential difference between the two predecessors. A ship that cannot be recovered for want of
  -- credits is a ship the player can never play again; no price and no feature flag may ever stand
  -- between a player and their own wreck.
  -- A DENTED HULL IS PRICED BY THE KNOB, behind the economy flag, exactly as 0201 had it — with
  -- one correction: ZERO IS A VALID PRICE AND MEANS FREE. 0201 rejected any price at-or-below zero
  -- as repair_misconfigured, which turned the owner's deliberate "repairs are free for now"
  -- setting into a total outage. Only NULL (key deleted) or a NEGATIVE price is a misconfiguration,
  -- and both still fail closed. Nothing here is hardcoded: restoring a price is one set-knob call.
  -- (Assert (d) below re-reads this body and refuses to deploy if the old at-or-below-zero test —
  -- spelled with the <= operator — reappears anywhere in it, comments included.)
  if v_wreck then
    v_per_hp := 0;
  else
    if not public.cfg_bool('repair_economy_enabled') then
      return jsonb_build_object('ok', false, 'reason', 'repair_economy_disabled');
    end if;
    v_per_hp := public.cfg_num('repair_credits_per_hp');
    if v_per_hp is null or v_per_hp < 0 then
      return jsonb_build_object('ok', false, 'reason', 'repair_misconfigured');
    end if;
  end if;
  v_total  := v_restore * v_per_hp;
  v_after  := v_ship.hp + v_restore;
  v_status := case when v_wreck then 'home' else v_ship.status end;

  -- WALLET debit (atomic conditional; false → too poor → NOTHING healed/receipted — the 0138 law).
  -- A zero total never touches the wallet at all, so a free repair cannot fail on a missing wallet
  -- row and cannot mint a 0-credit ledger entry.
  if v_total > 0 and not public.wallet_debit(v_player, v_total) then
    return jsonb_build_object('ok', false, 'reason', 'insufficient_credits',
      'price', v_total, 'hp_restored', v_restore, 'credits_per_hp', v_per_hp);
  end if;

  -- THE ONE WRITE. hp always; status ONLY on a recovery (a dented ship keeps whatever it was
  -- doing). Nothing else on the row is touched — no spatial column, no fleet, no berth, no cargo.
  -- An exception below aborts the WHOLE txn, so the debit rolls back with it: all-or-nothing.
  update public.main_ship_instances
     set hp = v_after,
         status = v_status,
         updated_at = now()
   where main_ship_id = v_ship_id;

  -- RECEIPT — the ONE repair ledger, now written by both policies (a free recovery lands a
  -- total_price = 0 row). Skipped only when the hull did not move, which the table's own
  -- hp_restored > 0 CHECK requires anyway.
  if v_restore > 0 then
    insert into public.repair_receipts
      (main_ship_id, request_id, location_id, hp_before, hp_after, hp_restored, credits_per_hp, total_price)
      values (v_ship_id, p_request_id, v_port, v_ship.hp, v_after, v_restore, v_per_hp, v_total)
      returning receipt_id into v_receipt;
  end if;

  return jsonb_build_object('ok', true,
    'receipt_id', v_receipt, 'main_ship_id', v_ship_id,
    'recovered', v_wreck, 'status', v_status,
    'hp_before', v_ship.hp, 'hp_after', v_after, 'max_hp', v_ship.max_hp,
    'hp_restored', v_restore, 'credits_per_hp', v_per_hp, 'total_price', v_total,
    'location_id', v_port);
end;
$function$;

comment on function public.repair_ship_hull(uuid, numeric, uuid) is
  'THE ONE repair authority (0335): restore a hull at the port the ship resolves to via '
  'mainship_port_of_ship. Replaces repair_main_ship (free wreck recovery) and '
  'repair_ship_hull_at_port (paid mend), which are dropped in the same migration — they were one '
  'concept with two implementations. Cost and amount are POLICY inside this body: a wreck restores '
  'whole and free (the 0052 no-softlock rule, never gated by a flag or a price); a dented hull '
  'restores what was asked, clamped to what is missing, priced by repair_credits_per_hp behind '
  'repair_economy_enabled — where a price of 0 means FREE and only null/negative is a '
  'misconfiguration. Envelope-returning, never raises. Idempotent on (main_ship_id, request_id).';

revoke execute on function public.repair_ship_hull(uuid, numeric, uuid) from public, anon;
grant  execute on function public.repair_ship_hull(uuid, numeric, uuid) to authenticated;


-- ══════════════════════════════════════════════════════════════════════════════════════════════════
-- §2. THE DELETION — both predecessors, dropped.
-- ══════════════════════════════════════════════════════════════════════════════════════════════════
-- Not deprecated, not shimmed, not left granted-but-unused. DROP FUNCTION removes the grants with
-- the function, so the authenticated surface loses both names in this transaction. A shim that kept
-- either name callable would BE the second authority this slice exists to delete — and the last
-- time a retired mover was left alive on the client surface it took migration 0309 to close.
drop function if exists public.repair_main_ship(uuid);
drop function if exists public.repair_ship_hull_at_port(uuid, numeric, uuid);


-- ══════════════════════════════════════════════════════════════════════════════════════════════════
-- §3. LEDGER LOCKDOWN — repair_receipts carries client table-write it never should have had.
-- ══════════════════════════════════════════════════════════════════════════════════════════════════
-- Production check, read-only, before this file: anon AND authenticated hold INSERT/UPDATE/DELETE on
-- public.repair_receipts. Source is Supabase's project-default GRANT ALL on new public tables — the
-- identical drift that aborted the 0254 deploy (see the danger_zones incident). RLS is enabled with
-- a single SELECT policy (repair_receipts_select_own), so the writes are already denied and this is
-- a latent belt-and-suspenders gap, not a live exploit. It is closed HERE because this migration is
-- what makes repair_receipts the sole repair ledger for BOTH policies, and a ledger a client can
-- forge is not a ledger. ESTABLISH by revoking, never merely assert (the 0246 posture); SELECT is
-- preserved because the owner-read policy depends on it.
revoke insert, update, delete on table public.repair_receipts from anon, authenticated;


-- ══════════════════════════════════════════════════════════════════════════════════════════════════
-- §4. SELF-ASSERT — this migration's own effect, and nothing else.
-- ══════════════════════════════════════════════════════════════════════════════════════════════════
-- Asserts only what this file wrote: the one body, the two deletions, the ACLs, the ledger
-- lockdown, and zero-write behavioural probes. It reads NO game_config VALUE, requires NO seed row
-- and NO world data, and passes on a completely empty database — 0288 failed a production deploy
-- asserting a flag value and 0295 broke its own disposable proof asserting a seed row; neither
-- shape appears here.
do $$
declare
  v_src text;
  v_res jsonb;
begin
  -- (a) THE ONE AUTHORITY EXISTS, with its real signature.
  if to_regprocedure('public.repair_ship_hull(uuid,numeric,uuid)') is null then
    raise exception '0335 ASSERT (a) FAIL: repair_ship_hull(uuid,numeric,uuid) not deployed';
  end if;
  select prosrc into v_src from pg_proc
   where oid = to_regprocedure('public.repair_ship_hull(uuid,numeric,uuid)')::oid;

  -- (b) IT INHERITED EVERY GUARD ITS PREDECESSORS OWNED. Each string below was pinned in §0 against
  --     the source it came from, so this is the second half of a two-sided derivation, not a wish.
  if position('mainship_port_of_ship' in v_src) = 0 then
    raise exception '0335 ASSERT (b) FAIL: the unified repair does not compose the ONE position authority';
  end if;
  if position('mainship_resolve_owned_ship' in v_src) = 0 then
    raise exception '0335 ASSERT (b) FAIL: the unified repair does not assert ownership through the shared resolver';
  end if;
  if position('mainship_space_lock_context' in v_src) = 0 then
    raise exception '0335 ASSERT (b) FAIL: the unified repair lost the per-ship lock';
  end if;
  if position('repair_credits_per_hp' in v_src) = 0 or position('wallet_debit' in v_src) = 0 then
    raise exception '0335 ASSERT (b) FAIL: the unified repair lost the cost knob or the wallet debit';
  end if;
  if position('repair_receipts' in v_src) = 0 then
    raise exception '0335 ASSERT (b) FAIL: the unified repair writes no receipt';
  end if;

  -- (c) THE PRICE IS A KNOB, NOT A CONSTANT. The body must contain no literal price: the only way
  --     a rate enters is cfg_num('repair_credits_per_hp'), and the wreck exemption is the single
  --     `v_per_hp := 0` the cost-policy block declares. Setting a price later stays one set-knob
  --     call — this check is what stops a future edit from quietly hardcoding today's free repair.
  if position('cfg_num(''repair_credits_per_hp'')' in v_src) = 0 then
    raise exception '0335 ASSERT (c) FAIL: the price is not read from the knob';
  end if;
  if (length(v_src) - length(replace(v_src, 'v_per_hp := ', ''))) / length('v_per_hp := ') <> 2 then
    raise exception '0335 ASSERT (c) FAIL: v_per_hp is assigned somewhere other than the two cost-policy branches — a price may have been hardcoded';
  end if;

  -- (d) ZERO IS FREE, NOT BROKEN. The defect §0 pinned in the old paid body must be gone from the
  --     new one: only a NEGATIVE (or null) price may reject.
  if position('v_per_hp <= 0' in v_src) <> 0 then
    raise exception '0335 ASSERT (d) FAIL: the unified repair still treats a 0 price as a misconfiguration';
  end if;
  if position('v_per_hp < 0' in v_src) = 0 then
    raise exception '0335 ASSERT (d) FAIL: the unified repair lost the negative-price fail-closed guard';
  end if;

  -- (e) BOTH PREDECESSORS ARE GONE — the whole point. Absence is the assertion.
  if to_regprocedure('public.repair_main_ship(uuid)') is not null then
    raise exception '0335 ASSERT (e) FAIL: repair_main_ship survived — a second repair authority is still live';
  end if;
  if to_regprocedure('public.repair_ship_hull_at_port(uuid,numeric,uuid)') is not null then
    raise exception '0335 ASSERT (e) FAIL: repair_ship_hull_at_port survived — a second repair authority is still live';
  end if;
  -- and nothing anywhere in the schema still calls either name (a stale caller would raise at
  -- runtime, in a live game, on the one verb a stranded player needs).
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.prokind = 'f'
                and p.oid <> to_regprocedure('public.repair_ship_hull(uuid,numeric,uuid)')::oid
                and p.prosrc ~ '(repair_main_ship|repair_ship_hull_at_port)[[:space:]]*\(') then
    raise exception '0335 ASSERT (e) FAIL: a deployed function still CALLS a dropped repair function';
  end if;

  -- (f) THE RECOVERY ROUTE OUT OF THE POSITION GATE SURVIVED (0052 no-softlock).
  if to_regprocedure('public.mainship_emergency_tow(uuid)') is null
     or to_regprocedure('public.get_my_disabled_ships()') is null
     or to_regprocedure('public.mainship_port_of_ship(uuid)') is null then
    raise exception '0335 ASSERT (f) FAIL: a 0297 recovery surface disappeared — the gate must never ship without its way out';
  end if;

  -- (g) ACL: the one RPC is authenticated-only, never anon or public.
  if not has_function_privilege('authenticated', 'public.repair_ship_hull(uuid,numeric,uuid)', 'execute')
     or has_function_privilege('anon', 'public.repair_ship_hull(uuid,numeric,uuid)', 'execute') then
    raise exception '0335 ASSERT (g) FAIL: repair_ship_hull ACL drifted (want authenticated-only, never anon)';
  end if;

  -- (h) LEDGER LOCKDOWN established (not merely asserted — §3 revoked it above).
  if has_table_privilege('anon', 'public.repair_receipts', 'insert')
     or has_table_privilege('anon', 'public.repair_receipts', 'update')
     or has_table_privilege('anon', 'public.repair_receipts', 'delete')
     or has_table_privilege('authenticated', 'public.repair_receipts', 'insert')
     or has_table_privilege('authenticated', 'public.repair_receipts', 'update')
     or has_table_privilege('authenticated', 'public.repair_receipts', 'delete') then
    raise exception '0335 ASSERT (h) FAIL: a client role can still write repair_receipts';
  end if;
  if not has_table_privilege('authenticated', 'public.repair_receipts', 'select') then
    raise exception '0335 ASSERT (h) FAIL: the owner-read SELECT the RLS policy depends on was revoked too';
  end if;

  -- (i) ZERO-WRITE BEHAVIOURAL PROBES — valid on an EMPTY dataset, and they write nothing.
  --     This block runs with no request.jwt.claims, so auth.uid() is NULL.
  v_res := public.repair_ship_hull(null, null, gen_random_uuid());
  if (v_res ->> 'reason') is distinct from 'not_authenticated' then
    raise exception '0335 ASSERT (i) FAIL: the unified repair did not reject an unauthenticated caller (got %)', v_res;
  end if;
  if (v_res ->> 'ok')::boolean is not false then
    raise exception '0335 ASSERT (i) FAIL: an unauthenticated reject was not ok:false (got %)', v_res;
  end if;

  raise notice '0335 PASS: repair_ship_hull is the ONE repair authority (one position gate via mainship_port_of_ship, one reason vocabulary, one receipt ledger, one per-ship lock); cost + amount are policy in-body (a wreck restores whole and free; a dented hull is priced by the repair_credits_per_hp knob where 0 means FREE and only null/negative fails closed); repair_main_ship and repair_ship_hull_at_port are DROPPED with their grants and nothing calls them; the 0297 tow/read/position surfaces survive; ACL authenticated-only; repair_receipts client write REVOKED; probes zero-write';
end $$;

commit;
