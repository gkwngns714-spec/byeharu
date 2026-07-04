-- Byeharu — FITTING-P14 SLICE C2: settled-SAFE ship-state rule (forward-only correction of the
-- 0113 game rule; a single-rule surgical re-create — the 0044-style `create or replace`
-- forward-only idiom. 0001–0113 unedited; 0113 stays as history).
--
-- WHY: the slice-C review confirmed the strict `spatial_state = 'home'` rule is dead-on-arrival —
-- NO shipped writer ever produces 'home' (commissions land 'at_location' per 0072/0077/0078/0080;
-- OSN writers produce in_transit/in_space/at_location; destruction/repair leave NULL, 0059), so
-- even after the owner flips the flag every ship would answer ship_not_home. The rule's INTENT
-- (recorded in 0113): a loadout must never change mid-transit / in-space / mid-combat. The
-- codebase already has an authoritative "ship is settled and safe to act on" definition — reuse
-- it. No flag is touched; everything stays dark.
--
-- THE SHIPPED GATING, AS READ (transcribed in FITTING_P14_RECON.local.md §6b):
--   · the activity COMMANDS (0099:151–167 scan · 0104:124–140 extract) gate IDENTICALLY to each
--     other (no stricter-of-two choice was needed): `mainship_space_validate_context` (0056 — full
--     coherence validation; returns a validated state) must be ok, then
--     `mainship_space_assert_cross_domain_exclusion` (0056 — the companion BUSY-checks: no active
--     legacy fleet movement / no coordinate-pointer mismatch / no presence conflict) must be ok.
--     Their accepted STATE is `'in_space'` — which exists because scan/extract ARE open-space
--     actions; transcribing that literal into fitting would contradict the recorded intent
--     (never in-space), so it deliberately does NOT transfer.
--   · the securing PROCESSORS (0100:231 · 0105:69) define the settled-SAFE STATE SET:
--     `spatial_state in ('home','at_location')` — "docked at a location or home; anything else
--     waits". Legacy NULL is NOT safe (fail-closed).
-- WHAT SHIPS HERE (intent preserved, literal fixed, precedent reused): the processors' settled-
-- SAFE state set VERBATIM + the commands' companion machinery VERBATIM — validate_context must be
-- ok AND its validated state in ('home','at_location') (legacy_home/legacy_present/legacy_transit/
-- in_space/in_transit/destroyed and any incoherent context all reject), then the cross-domain
-- exclusion must be ok — so fitting is gated AT LEAST as strictly as the shipped activity
-- commands. Every non-settled outcome collapses to ONE truthful reject `ship_not_settled` (the
-- 0099:159 "one truthful reason" idiom); the reject code ship_not_home is RENAMED
-- ship_not_settled. Satisfiable today: commissioned ships sit 'at_location' in the canonical
-- coherent shape.
--
-- SCOPE OF THE RE-CREATE (everything else byte-identical to 0113): fitting_execute_command changes
-- ONLY the step-6 game rule (+ the declare lines its variables need — v_state is replaced by
-- v_check_ship/v_val/v_excl); dark-gate order, request_id validation, lock, verbatim replay,
-- action-shape validation, delegation to fitting_apply, and failure-writes-no-receipt semantics
-- are UNCHANGED. fitting_command_client_envelope is re-created only because it embeds the renamed
-- code + its player-facing copy. fitting_apply, module_fitting_receipts, both wrappers, and every
-- exploration/mining object are NOT touched. NO-DUPLICATION NOTE (explicit, per the review): the
-- settled-SAFE mechanism appears ONCE — the affected ship is resolved per action first, then one
-- shared check block runs — so no shared-helper extraction is needed (and the membership check
-- itself is one line).
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): the §2 Fitting row's ⚠
-- unsatisfiable-rule note is replaced by the settled-SAFE rule as now shipped (citing the
-- 0099/0104 machinery + 0100/0105 state-set precedents). No new table, writer, or cross-system
-- edge (validate_context/exclusion were already Fitting-reachable Main-Ship/OSN reads via the
-- shipped helpers — read-only, downward, acyclic).

-- ── 1) fitting_execute_command — re-created with the settled-SAFE rule (single-rule change) ───────
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
  v_val        jsonb;
  v_excl       jsonb;
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
  --    header). Resolve the affected ship per action, then run the ONE shared check block:
  --    the 0100/0105 settled-SAFE state set + the 0099/0104 companion machinery. Reads are
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
  if v_check_ship is not null then
    -- coherence + settled state (0099:151–160 / 0104:124–133 machinery; the 0100/0105 SAFE set):
    -- legacy NULL, in_space, in_transit, destroyed, and any incoherent context all reject —
    -- ONE truthful reason (the 0099:159 idiom).
    v_val := public.mainship_space_validate_context(v_check_ship);
    if (v_val->>'ok')::boolean is not true
       or (v_val->>'state') not in ('home', 'at_location') then
      return jsonb_build_object('ok', false, 'reason', 'ship_not_settled');
    end if;
    -- companion busy-checks (0099:165–167 / 0104:138–140 verbatim): neither movement domain may
    -- own the ship in a conflicting way (active legacy movement / pointer mismatch / presence
    -- conflict) — fitting is gated at least as strictly as the shipped activity commands.
    v_excl := public.mainship_space_assert_cross_domain_exclusion(v_check_ship);
    if (v_excl->>'ok')::boolean is not true then
      return jsonb_build_object('ok', false, 'reason', 'ship_not_settled');
    end if;
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

-- ── 2) fitting_command_client_envelope — re-created ONLY for the renamed code + copy ──────────────
-- (identical to 0113 except: ship_not_home → ship_not_settled, and its player-facing message.)
create or replace function public.fitting_command_client_envelope(p_res jsonb)
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
  return jsonb_build_object(
    'ok', false,
    'code', case v_reason
      when 'feature_disabled'   then 'feature_disabled'
      when 'invalid_request_id' then 'invalid_request'
      when 'invalid_request'    then 'invalid_request'
      when 'ship_not_settled'   then 'ship_not_settled'
      when 'module_not_owned'   then 'module_not_owned'
      when 'ship_not_owned'     then 'ship_not_owned'
      when 'already_fitted'     then 'already_fitted'
      when 'not_fitted'         then 'not_fitted'
      when 'insufficient_slots' then 'insufficient_slots'
      else 'unavailable'
    end,
    'message', case v_reason
      when 'feature_disabled'   then 'Module fitting is not available yet.'
      when 'invalid_request_id' then 'Invalid command request.'
      when 'invalid_request'    then 'Invalid command request.'
      when 'ship_not_settled'   then 'The ship must be settled at home or docked at a location to change its module loadout.'
      when 'module_not_owned'   then 'That module is not in your possession.'
      when 'ship_not_owned'     then 'That ship is not yours.'
      when 'already_fitted'     then 'That module is already fitted to a ship. Unfit it first.'
      when 'not_fitted'         then 'That module is not fitted to any ship.'
      when 'insufficient_slots' then 'Not enough free module slots on this ship.'
      else 'Module fitting is unavailable right now.'
    end)
    -- context pass-through (the 0104/0109 idiom): the capacity detail and the current-ship detail
    -- ride their failure envelopes through to the client.
    || case when v_reason = 'insufficient_slots'
         then jsonb_build_object('used', p_res->'used', 'cost', p_res->'cost', 'limit', p_res->'limit')
         when v_reason = 'already_fitted'
         then jsonb_build_object('main_ship_id', p_res->'main_ship_id')
         else '{}'::jsonb
       end;
end;
$$;

-- ── 3) ACL — re-asserted for the two re-created functions (0113:265–273 posture verbatim; a
--       `create or replace` preserves existing grants, but the shipped re-create precedents
--       re-assert explicitly — the 0084 posture). No other function's grants touched; the
--       wrappers/writer are NOT re-created and keep their 0112/0113 grants.
revoke execute on function public.fitting_execute_command(uuid, text, uuid, uuid, text) from public, anon, authenticated;
grant  execute on function public.fitting_execute_command(uuid, text, uuid, uuid, text) to service_role;
revoke execute on function public.fitting_command_client_envelope(jsonb) from public, anon, authenticated;
grant  execute on function public.fitting_command_client_envelope(jsonb) to service_role;
