-- Byeharu — CAPTAIN-P15 SLICE E: the settled-SAFE game rule for captain assignment (the 0114
-- analogue) + the shared-leaf extraction the no-duplication HARD RULE now requires (forward-only
-- `create or replace` re-creates — the 0044/0114/0115 idiom. 0001–0120 unedited; 0114/0120 stay
-- as history).
--
-- WHAT 0114 WAS READ TO CONTAIN (the slice spec's first step): the settled-SAFE check is INLINE
-- in fitting_execute_command (0114:126–142) — resolve the affected ship per action
-- (owner-scoped), then ONE check block: `mainship_space_validate_context(ship)` must be ok AND
-- its validated state in ('home','at_location') (the 0100/0105 securing-processor SAFE set),
-- then `mainship_space_assert_cross_domain_exclusion(ship)` must be ok, else ONE truthful reject
-- `ship_not_settled` — fail-closed: legacy NULL, in_space, in_transit, destroyed, and any
-- incoherent context all reject. NO callable settled-safe composite exists; 0114:41–44 recorded
-- the no-duplication note explicitly: "the settled-SAFE mechanism appears ONCE … so no
-- shared-helper extraction is needed". THAT CONDITION IS NOW FALSE — Captain is the second
-- consumer — so the HARD RULE (the instant the same non-trivial logic would live in two places,
-- extract ONE shared helper and call it from every site IN THE SAME STEP) triggers here:
--
-- (E1) EXTRACT `mainship_space_assert_settled_safe(p_main_ship_id uuid) returns boolean` — the
--      0114:126–142 composite VERBATIM as ONE Main-Ship-owned internal leaf in the
--      `mainship_space_*` family (0056). SIGNATURE (locked, recorded honestly): ship-id-ONLY,
--      exactly like its family siblings `mainship_space_validate_context(uuid)` /
--      `mainship_space_assert_cross_domain_exclusion(uuid)` (0056:91/224) — NO p_player_id,
--      because ownership resolution is per-action, per-system semantics that stays in each
--      command (fit/assign reject `ship_not_owned` on a foreign ship; unfit/unassign resolve the
--      current ship from their own junction row and skip-if-none) and MUST stay there for the
--      fitting re-create to be behavior-identical; a player param would be either dead or a
--      behavior change. The helper is the ONE settled-safe definition; service_role-only ACL
--      (the 0056 family posture).
-- (E2) RE-CREATE fitting_execute_command to call the leaf — A PURE REFACTOR, ZERO BEHAVIOR
--      CHANGE (the compatibility contract, stated the way 0115:10–18 states its own): the body
--      is byte-identical to 0114's shipped body EXCEPT (a) the declare list drops v_val/v_excl
--      (the leaf owns them now) and (b) the step-6 `if v_check_ship is not null then …` block
--      calls the leaf instead of inlining the two-step check. Same reads, same evaluation order
--      (validate_context first, SAFE-set membership, then exclusion), same single truthful
--      `ship_not_settled`, same skip-if-null unfit semantics. Dark-gate order, request_id
--      validation, lock, verbatim replay, action-shape validation, delegation, and
--      failure-writes-no-receipt are UNTOUCHED. Nothing else about fitting is re-created.
-- (E3) RE-CREATE captain_execute_command with the rule — the 0120 header's promised forward-only
--      amendment, mirroring exactly how P14 shipped 0113 then 0114. LOCKED DECISIONS:
--      · PLACEMENT: inside captain_execute_command AFTER the replay check and action-shape
--        validation, BEFORE delegating to captain_assign_apply — the 0114 layering: game rule in
--        the COMMAND, structure in the WRITER (which stays the final authority on ownership /
--        one-ship-per-captain / the headcount cap).
--      · BOTH ACTIONS: assign checks the TARGET ship (owner-scoped read; a foreign/missing ship
--        answers `ship_not_owned` at this layer — the 0114 fit-branch shape; the writer would
--        answer identically); unassign checks the ship the captain is CURRENTLY assigned to
--        (owner-scoped read of ship_captain_assignments; if the captain is unassigned the rule
--        is SKIPPED — that case is the structural writer's truthful `not_assigned` reject, not a
--        settled-safe concern — the exact 0114 unfit-branch semantics). RATIONALE (recon §4 D'):
--        a loadout, captain roster included, is frozen mid-transit / in-space / mid-combat.
--      · REJECT REASON: the same truthful `ship_not_settled`, mapped through
--        captain_command_client_envelope (the mapping is ADDED — 0120 shipped without it, the
--        rule did not exist yet).
--      Everything else in the body is byte-identical to 0120 (gate order, lock, replay,
--      validation, exception→envelope translation, receipt-on-success).
-- (E4) RE-CREATE captain_command_client_envelope ONLY to add the ship_not_settled entry
--      (reason + player-facing copy, the captain wording of 0114:186/198). All other entries
--      byte-identical to 0120.
--
-- SAFE TO SHIP DARK: captain_assignment_enabled is 'false' (0117) — no caller could reach the
-- rule-less 0120 command in the gap, and none can reach this one; module_fitting_enabled is
-- 'false' (0111) likewise. No flag is touched.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): the new leaf is Main-Ship-owned
-- (the `mainship_space_*` family home), owns NO table, reads only through the two 0056 helpers —
-- a pure downward composite; Fitting and Captain both consume it DOWNWARD (the edges they
-- already had — no new cross-system edge, no cycle). The §2 Captain row gains the settled-SAFE
-- contract; the §2 Fitting row's inline-check wording now names the shared leaf; the leaf is
-- documented beside the OSN geometry leaf note. No flag flipped; 0001–0120 unedited.

-- ── 1) mainship_space_assert_settled_safe — THE ONE settled-safe definition (Main Ship leaf) ─────
-- The 0114:126–142 composite verbatim: coherence + settled state (the 0100/0105 SAFE set), then
-- the companion busy-checks (the 0099/0104 activity-command machinery). Fail-closed by
-- construction: legacy NULL, in_space, in_transit, destroyed, and any incoherent context are all
-- non-settled. Callers resolve WHICH ship per their own action semantics; this leaf answers only
-- "is that ship settled and safe to act on".
create or replace function public.mainship_space_assert_settled_safe(p_main_ship_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_val  jsonb;
  v_excl jsonb;
begin
  -- coherence + settled state (0099:151–160 / 0104:124–133 machinery; the 0100/0105 SAFE set):
  v_val := public.mainship_space_validate_context(p_main_ship_id);
  if (v_val->>'ok')::boolean is not true
     or (v_val->>'state') not in ('home', 'at_location') then
    return false;
  end if;
  -- companion busy-checks (0099:165–167 / 0104:138–140 verbatim): neither movement domain may
  -- own the ship in a conflicting way (active legacy movement / pointer mismatch / presence
  -- conflict).
  v_excl := public.mainship_space_assert_cross_domain_exclusion(p_main_ship_id);
  if (v_excl->>'ok')::boolean is not true then
    return false;
  end if;
  return true;
end;
$$;

-- ── 2) fitting_execute_command — re-created to call the leaf (PURE refactor, zero behavior
--       change; see header E2 for the compatibility contract) ────────────────────────────────────
create or replace function public.fitting_execute_command(
  p_player             uuid,
  p_action             text,
  p_module_instance_id uuid,
  p_main_ship_id       uuid,   -- required on 'fit'; must be NULL on 'unfit'
  p_request_id         text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rcpt       module_fitting_receipts%rowtype;
  v_check_ship uuid;
  v_res        jsonb;
begin
  -- 1) DARK GATE FIRST (0111 law / 0109:104–109 idiom): while module_fitting_enabled is false,
  --    reject deterministically BEFORE any other read — no receipt read, no lock, no row read.
  if not public.cfg_bool('module_fitting_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'feature_disabled');
  end if;

  -- 2) pure input validation of the idempotency key (0109:111–116 verbatim): TEXT, non-empty,
  --    sanity-capped (clients send 36-char crypto.randomUUID() strings).
  if p_request_id is null or p_request_id = '' or length(p_request_id) > 200 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_request_id');
  end if;

  -- 3) per-player serialization BEFORE the replay check (0109:118–123; the SAME
  --    ('module_fitting', player) key fitting_apply takes — reentrant within this transaction, see
  --    the 0113 header): all of this player's fitting commands AND mutations queue here, so a
  --    same-request_id race resolves to one mutation + one verbatim replay, and the settled-rule
  --    read below cannot be raced by another fitting command of this player.
  perform pg_advisory_xact_lock(hashtext('module_fitting'), hashtext(p_player::text));

  -- 4) IDEMPOTENCY REPLAY (0089/0095/0109 trade semantics, matched exactly): a receipt for
  --    (player, request_id) already exists → return its stored success envelope VERBATIM, flagged —
  --    no write, no re-check, NO payload-conflict check (a reused request_id replays the original
  --    result even if this call names a different action/module/ship — the market_buy semantics).
  select * into v_rcpt from module_fitting_receipts
    where player_id = p_player and request_id = p_request_id;
  if found then
    return v_rcpt.result_json || jsonb_build_object('idempotent_replay', true);
  end if;

  -- 5) action-shape validation: exactly two actions; 'fit' targets a ship, 'unfit' must not.
  if p_action is null or p_action not in ('fit', 'unfit')
     or (p_action = 'fit'   and p_main_ship_id is null)
     or (p_action = 'unfit' and p_main_ship_id is not null) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_request');
  end if;

  -- 6) THE GAME RULE THIS LAYER OWNS — ship-must-be-SETTLED-SAFE (the 0114 correction; see the
  --    header). Resolve the affected ship per action, then run the ONE shared check — since 0121
  --    the 0114 inline block lives in the Main-Ship leaf mainship_space_assert_settled_safe
  --    (extracted when Captain became its second consumer; behavior identical). Reads are
  --    owner-scoped so another player's ship state can never be probed; the writer remains the
  --    final authority on ownership.
  if p_action = 'fit' then
    select main_ship_id into v_check_ship from main_ship_instances
      where main_ship_id = p_main_ship_id and player_id = p_player;
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'ship_not_owned');
    end if;
  else
    -- unfit: the affected ship is the one the module is CURRENTLY fitted to. Owner-scoped read; if
    -- no fitting row exists, v_check_ship stays NULL and the rule is skipped — the writer answers
    -- module_not_owned / not_fitted truthfully (unchanged 0113 semantics).
    select f.main_ship_id into v_check_ship
      from ship_module_fittings f
      where f.module_instance_id = p_module_instance_id and f.player_id = p_player;
  end if;
  if v_check_ship is not null
     and not public.mainship_space_assert_settled_safe(v_check_ship) then
    return jsonb_build_object('ok', false, 'reason', 'ship_not_settled');
  end if;

  -- 7) DELEGATE the mutation to THE ONE writer (0112) — this command never touches
  --    ship_module_fittings directly. Writer failures pass through as this command's error
  --    reasons; a failure writes NO receipt (the 0109 failure-writes-no-receipt law).
  v_res := public.fitting_apply(p_player, p_module_instance_id,
                                case when p_action = 'fit' then p_main_ship_id else null end);
  if (v_res->>'ok')::boolean is not true then
    return v_res;
  end if;

  -- 8) RECEIPT — only a SUCCESSFUL mutation writes one, atomically with the mutation (same
  --    transaction as the writer's insert/delete). result_json = the success envelope verbatim.
  insert into module_fitting_receipts
      (player_id, request_id, action, module_instance_id, main_ship_id, result_json)
    values (p_player, p_request_id, p_action, p_module_instance_id,
            case when p_action = 'fit' then p_main_ship_id else null end, v_res);

  return v_res;
end;
$$;

-- ── 3) captain_execute_command — re-created with the settled-SAFE rule (the promised 0120→0121
--       amendment; single-rule change, everything else byte-identical to 0120) ────────────────────
create or replace function public.captain_execute_command(
  p_player_id           uuid,
  p_action              text,
  p_captain_instance_id uuid,
  p_main_ship_id        uuid,   -- required on 'assign'; must be NULL on 'unassign'
  p_request_id          text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rcpt       captain_assignment_receipts%rowtype;
  v_check_ship uuid;
  v_res        jsonb;
  v_reason     text;
begin
  -- 1) DARK GATE FIRST (0117 law / 0113:118–122 idiom): while captain_assignment_enabled is
  --    false, reject deterministically BEFORE any other read — no receipt read, no lock, no row
  --    read.
  if not public.cfg_bool('captain_assignment_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'feature_disabled');
  end if;

  -- 2) pure input validation of the idempotency key (0113:124–128 verbatim): TEXT, non-empty,
  --    sanity-capped (clients send 36-char crypto.randomUUID() strings).
  if p_request_id is null or p_request_id = '' or length(p_request_id) > 200 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_request_id');
  end if;

  -- 3) per-player serialization BEFORE the replay check (0113:130–135; the SAME
  --    ('captain_assignment', player) key captain_assign_apply takes — reentrant within this
  --    transaction, see the 0120 header): all of this player's assignment commands AND mutations
  --    queue here, so a same-request_id race resolves to one mutation + one verbatim replay, and
  --    the settled-rule read below cannot be raced by another assignment command of this player.
  perform pg_advisory_xact_lock(hashtext('captain_assignment'), hashtext(p_player_id::text));

  -- 4) IDEMPOTENCY REPLAY (0089/0095/0109/0113 trade semantics, matched exactly): a receipt for
  --    (player, request_id) already exists → return its stored success envelope VERBATIM,
  --    flagged — no write, no re-check, NO payload-conflict check (a reused request_id replays
  --    the original result even if this call names a different action/captain/ship).
  select * into v_rcpt from captain_assignment_receipts
    where player_id = p_player_id and request_id = p_request_id;
  if found then
    return v_rcpt.result_json || jsonb_build_object('idempotent_replay', true);
  end if;

  -- 5) action-shape validation: exactly two actions; 'assign' targets a ship, 'unassign' must not.
  if p_action is null or p_action not in ('assign', 'unassign')
     or (p_action = 'assign'   and p_main_ship_id is null)
     or (p_action = 'unassign' and p_main_ship_id is not null) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_request');
  end if;

  -- 6) THE GAME RULE THIS LAYER OWNS — ship-must-be-SETTLED-SAFE (the 0120 header's promised
  --    amendment; header E3): a loadout, captain roster included, is frozen mid-transit /
  --    in-space / mid-combat. Resolve the affected ship per action (the 0114 branch shapes),
  --    then run the ONE shared Main-Ship leaf. Reads are owner-scoped so another player's ship
  --    state can never be probed; the writer remains the final authority on ownership.
  if p_action = 'assign' then
    select main_ship_id into v_check_ship from main_ship_instances
      where main_ship_id = p_main_ship_id and player_id = p_player_id;
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'ship_not_owned');
    end if;
  else
    -- unassign: the affected ship is the one the captain is CURRENTLY assigned to. Owner-scoped
    -- read; if no assignment row exists, v_check_ship stays NULL and the rule is skipped — the
    -- writer answers captain_not_owned / not_assigned truthfully (the 0114 unfit-branch
    -- semantics; an unassigned captain is not a settled-safe concern).
    select a.main_ship_id into v_check_ship
      from ship_captain_assignments a
      where a.captain_instance_id = p_captain_instance_id and a.player_id = p_player_id;
  end if;
  if v_check_ship is not null
     and not public.mainship_space_assert_settled_safe(v_check_ship) then
    return jsonb_build_object('ok', false, 'reason', 'ship_not_settled');
  end if;

  -- 7) DELEGATE the mutation to THE ONE writer (0119) — this command never touches
  --    ship_captain_assignments directly. The writer is exception-style (the 0119 locked
  --    decision): its reason-prefixed raises are TRANSLATED here into failure envelopes — the
  --    known reasons only; anything else RE-RAISES (never hide a bug). A raise writes nothing
  --    (the failure-writes-no-receipt law holds by construction).
  begin
    perform public.captain_assign_apply(p_player_id, p_captain_instance_id,
      case when p_action = 'assign' then p_main_ship_id else null end);
  exception when others then
    v_reason := substring(sqlerrm from '^captain_assign_apply: ([a-z_]+)');
    if v_reason in ('captain_not_owned','ship_not_owned','already_assigned',
                    'captain_slots_full','not_assigned') then
      return jsonb_build_object('ok', false, 'reason', v_reason);
    end if;
    raise;
  end;

  -- 8) RECEIPT — only a SUCCESSFUL mutation writes one, atomically with the mutation (same
  --    transaction as the writer's insert/delete). The writer returns void, so the success
  --    envelope is built here; result_json stores it verbatim for replay.
  v_res := jsonb_build_object('ok', true, 'action', p_action,
    'captain_instance_id', p_captain_instance_id,
    'main_ship_id', case when p_action = 'assign' then p_main_ship_id else null end);
  insert into captain_assignment_receipts
      (player_id, request_id, action, captain_instance_id, main_ship_id, result_json)
    values (p_player_id, p_request_id, p_action, p_captain_instance_id,
            case when p_action = 'assign' then p_main_ship_id else null end, v_res);

  return v_res;
end;
$$;

-- ── 4) captain_command_client_envelope — re-created ONLY to add the ship_not_settled entry ───────
-- (identical to 0120 except the new reason + its player-facing copy — the 0114:164–165 re-create
-- rationale verbatim.)
create or replace function public.captain_command_client_envelope(p_res jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_reason text;
begin
  if (p_res->>'ok')::boolean is true then
    return p_res || jsonb_build_object('idempotent_replay',
      coalesce((p_res->>'idempotent_replay')::boolean, false));
  end if;

  v_reason := coalesce(p_res->>'reason', 'unavailable');

  -- the ONE dark visibility signal (no message — the 0110/0116 read-surface envelope shape):
  if v_reason = 'feature_disabled' then
    return jsonb_build_object('ok', false, 'reason', 'captain_assignment_disabled');
  end if;

  return jsonb_build_object(
    'ok', false,
    'reason', case v_reason
      when 'invalid_request_id'  then 'invalid_request'
      when 'invalid_request'     then 'invalid_request'
      when 'ship_not_settled'    then 'ship_not_settled'
      when 'captain_not_owned'   then 'captain_not_owned'
      when 'ship_not_owned'      then 'ship_not_owned'
      when 'already_assigned'    then 'already_assigned'
      when 'captain_slots_full'  then 'captain_slots_full'
      when 'not_assigned'        then 'not_assigned'
      else 'unavailable'
    end,
    'message', case v_reason
      when 'invalid_request_id'  then 'Invalid command request.'
      when 'invalid_request'     then 'Invalid command request.'
      when 'ship_not_settled'    then 'The ship must be settled at home or docked at a location to change its captain roster.'
      when 'captain_not_owned'   then 'That captain is not in your possession.'
      when 'ship_not_owned'      then 'That ship is not yours.'
      when 'already_assigned'    then 'That captain is already assigned to a ship. Unassign them first.'
      when 'captain_slots_full'  then 'No free captain slots on this ship.'
      when 'not_assigned'        then 'That captain is not assigned to any ship.'
      else 'Captain assignment is unavailable right now.'
    end);
end;
$$;

-- ── 5) ACL — the new leaf gets the 0056 family posture; the three re-created functions get their
--       grants re-asserted (0114:217–224 idiom — `create or replace` preserves grants, but the
--       shipped re-create precedents re-assert explicitly). No other function's grants touched;
--       the wrappers/writers are NOT re-created and keep their 0112/0113/0119/0120 grants.
revoke execute on function public.mainship_space_assert_settled_safe(uuid) from public, anon, authenticated;
grant  execute on function public.mainship_space_assert_settled_safe(uuid) to service_role;
revoke execute on function public.fitting_execute_command(uuid, text, uuid, uuid, text) from public, anon, authenticated;
grant  execute on function public.fitting_execute_command(uuid, text, uuid, uuid, text) to service_role;
revoke execute on function public.captain_execute_command(uuid, text, uuid, uuid, text) from public, anon, authenticated;
grant  execute on function public.captain_execute_command(uuid, text, uuid, uuid, text) to service_role;
revoke execute on function public.captain_command_client_envelope(jsonb) from public, anon, authenticated;
grant  execute on function public.captain_command_client_envelope(jsonb) to service_role;
