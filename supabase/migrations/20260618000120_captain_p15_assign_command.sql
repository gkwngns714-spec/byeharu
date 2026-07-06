-- Byeharu — CAPTAIN-P15 SLICE D: the dark two-layer assign/unassign command —
-- captain_assignment_receipts (player-scoped idempotency ledger, Captain-owned) + ONE private
-- command (captain_execute_command) behind TWO thin authenticated wrappers (assign_captain_to_ship
-- / unassign_captain_from_ship). NO adapter change, NO read surface, NO frontend, NO verify script
-- this slice.
--
-- THE ENTIRE SURFACE IS DARK TODAY: captain_assignment_enabled = 'false' (0117), and the private
-- command rejects BEFORE any other read (the 0097/0102/0107 reject-before-any-read law), with the
-- defense-in-depth + anti-probe gate in BOTH public wrappers too (0083/0099/0109/0113 idiom — a
-- dark feature answers identically regardless of input).
--
-- IDIOM SOURCE (matched line-by-line): 0113 (fit_module_to_ship / unfit_module_from_ship →
-- fitting_execute_command) — receipts table posture, dark-gate-first order, per-player advisory
-- lock BEFORE the replay check, trade-semantics verbatim replay with NO payload-conflict check (a
-- reused request_id returns the ORIGINAL success envelope flagged 'idempotent_replay', even if the
-- replayed call names a different action/captain/ship — the market_buy semantics), action-shape
-- validation, failure-writes-no-receipt, one shared mapper for two wrappers, and the grants/relock
-- block. The mutation itself delegates to captain_assign_apply (0119) — this command NEVER touches
-- ship_captain_assignments directly (the sole-writer law). Captains are NON-SPATIAL, so the
-- receipts are PLAYER-scoped — the 0113 (player_id, request_id) keying, NOT the ship-scoped space
-- receipts.
--
-- DELIBERATE ADAPTATIONS of 0113 for the captain surface (recorded honestly):
--   · REASON-KEYED CLIENT ENVELOPES (LOCKED): the dark answer is the literal
--     {ok:false, reason:'captain_assignment_disabled'} — identical for every caller, from BOTH the
--     wrapper gates AND the mapper's feature_disabled entry, matching the 0110/0116 read-surface
--     signal convention (the frontend's ONE server-driven visibility signal), NOT 0113's
--     code-keyed 'feature_disabled' wrapper envelope. All other client failures are
--     {ok:false, reason, message} — one consistent reason vocabulary across the whole captain
--     surface.
--   · THE WRITER IS EXCEPTION-STYLE (the 0119 locked decision), so step 7 delegates inside a
--     guarded block and TRANSLATES the writer's reason-prefixed raises (captain_not_owned /
--     ship_not_owned / already_assigned / captain_slots_full / not_assigned) into failure
--     envelopes — the translation 0119's header promised to this layer. UNKNOWN exceptions
--     RE-RAISE (never hide a bug); a raise aborts the guarded block, so a failed delegate writes
--     nothing.
--   · RECEIPTS STORE THE FULL RESULT ENVELOPE (result_json) — the 0113 adaptation kept: assign and
--     unassign successes have different shapes, so replay returns the stored envelope verbatim
--     (+ 'idempotent_replay'); the request fingerprint (action / captain_instance_id /
--     main_ship_id-as-requested) is stored alongside for audit. The writer returns void, so the
--     success envelope is BUILT HERE (ok/action/ids) — this command is the envelope's one author.
--   · ONE SHARED reason→envelope MAPPER (captain_command_client_envelope): 0113's
--     fitting_command_client_envelope was read first per the slice spec — its map is COUPLED to
--     fitting's reason vocabulary (module_not_owned / already_fitted / insufficient_slots …,
--     0113:219–250), not feature-generic, so the captain analogue is created and called by BOTH
--     wrappers, never inlining the map twice (the exact 0113:33–35 extraction rationale).
--
-- LOCK REENTRANCY (why the nested acquisition is safe): this command takes the SAME per-player
-- advisory lock key as captain_assign_apply — pg_advisory_xact_lock(hashtext('captain_assignment'),
-- hashtext(player)) — BEFORE its replay check, then the writer re-acquires it inside the same
-- transaction. pg_advisory_xact_lock is reentrant within a transaction, so the nested acquisition
-- cannot deadlock, and the replay check is serialized with ALL of the player's assignment
-- mutations: a same-request_id race resolves to one mutation + one verbatim replay.
--
-- LOCKED DECISION — THE SETTLED-SAFE GAME RULE IS NOT IN THIS SLICE: the affected ship's
-- home/at_location spatial rule (the 0114 layer) lands NEXT slice as a forward-only amendment of
-- this command, mirroring exactly how P14 shipped 0113 (command) then 0114 (settled-SAFE
-- correction). SAFE because captain_assignment_enabled is 'false': no caller can reach the command
-- in the gap — the gate rejects before any read, so the rule-less window is unreachable by
-- construction. Layer split (the 0112/0119 header law): the WRITER owns table invariants
-- (ownership, one-ship-per-captain, the headcount cap); this COMMAND owns the game rules (dark
-- gate, receipt idempotency — spatial rule next slice). The writer stays the final authority on
-- the invariants it owns.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): captain_assignment_receipts →
-- Captain (sole writer = captain_execute_command via the two public wrappers).
-- captain_assign_apply's "called by NOTHING yet" note is replaced: this command is its ONE caller.
-- New edges, all DOWNWARD: Captain → Reference/Config (cfg_bool flag read); inbound: the two
-- authenticated wrappers are the ONLY client entries, dark today. No cycle; nothing depends on
-- Captain. No flag flipped; 0001–0119 unedited.

-- ── 1) captain_assignment_receipts — per-player idempotent assign/unassign ledger (Captain) ──────
create table public.captain_assignment_receipts (
  player_id           uuid not null references auth.users (id) on delete cascade,
  request_id          text not null,                          -- idempotency key (per-player)
  action              text not null check (action in ('assign','unassign')),
  -- request fingerprint (audit; replay truth is result_json). on delete cascade on both refs: the
  -- referenced rows only ever disappear via the auth.users cascade today — cascading the receipt
  -- keeps account deletion order-safe across the multi-path cascade graph (the 0088/0109/0113
  -- lesson).
  captain_instance_id uuid not null references public.captain_instances (id) on delete cascade,
  main_ship_id        uuid references public.main_ship_instances (main_ship_id) on delete cascade,  -- as requested; NULL on unassign
  result_json         jsonb not null,                         -- the command's success envelope, verbatim
  created_at          timestamptz not null default now(),
  primary key (player_id, request_id)                         -- the idempotency key IS the identity
);
-- No extra index: the PK leads on player_id and covers idempotency probes + owner lookups (the
-- 0086/0109/0113 comment idiom).

alter table public.captain_assignment_receipts enable row level security;
-- Owner-read only (0113:85–91 posture verbatim); granted to authenticated, NOT anon. NO insert/
-- update/delete policy and NO write grant → clients cannot mutate; Captain is sole writer
-- (server-only command below).
create policy "captain_assignment_receipts_select_own" on public.captain_assignment_receipts
  for select using (player_id = auth.uid());
grant select on public.captain_assignment_receipts to authenticated;

comment on table public.captain_assignment_receipts is
  'CAPTAIN-P15: per-player idempotent assign/unassign ledger (Captain-owned; sole writer = the ONE '
  'private command captain_execute_command via the assign_captain_to_ship / '
  'unassign_captain_from_ship wrappers — one command handles BOTH actions so this table keeps ONE '
  'writer). PK (player_id, request_id) is the replay key — a replayed command returns result_json '
  'verbatim (0089/0095/0109/0113 trade semantics, no payload-conflict check). Only SUCCESSFUL '
  'mutations write a receipt. Players read only their own rows. Feature DARK behind '
  'captain_assignment_enabled.';

-- ── 2) captain_execute_command — the ONE private command (Captain); SOLE writer of the receipts ──
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
  v_rcpt   captain_assignment_receipts%rowtype;
  v_res    jsonb;
  v_reason text;
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
  --    transaction, see header): all of this player's assignment commands AND mutations queue
  --    here, so a same-request_id race resolves to one mutation + one verbatim replay.
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

  -- 6) GAME RULE — deliberately ABSENT this slice (the header's LOCKED DECISION): the
  --    settled-SAFE spatial rule for the affected ship lands here NEXT slice as a forward-only
  --    amendment (the P14 0113→0114 split). Unreachable gap: the step-1 gate rejects every call
  --    while the flag is 'false'.

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

-- ── 3) captain_command_client_envelope — the ONE shared reason→envelope mapper ────────────────────
-- 0113's fitting_command_client_envelope was read first (the slice spec): its map is coupled to
-- fitting's reason vocabulary, so this is the captain analogue — extracted once and called by BOTH
-- wrappers (the 0113:33–35 no-duplication rationale). Pure jsonb→jsonb. Reason-keyed output (the
-- header's locked adaptation): the dark answer is the literal
-- {ok:false, reason:'captain_assignment_disabled'} — byte-identical to the wrapper gates'.
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
      when 'captain_not_owned'   then 'That captain is not in your possession.'
      when 'ship_not_owned'      then 'That ship is not yours.'
      when 'already_assigned'    then 'That captain is already assigned to a ship. Unassign them first.'
      when 'captain_slots_full'  then 'No free captain slots on this ship.'
      when 'not_assigned'        then 'That captain is not assigned to any ship.'
      else 'Captain assignment is unavailable right now.'
    end);
end;
$$;

-- ── 4) the TWO thin authenticated wrappers (0113:254–303 wrapper idiom; fixed action each) ───────
-- DARK TODAY: captain_assignment_enabled = 'false', so the gate below and the command's first
-- check both reject every call — the entire surface ships server-rejected with no client UI.
create or replace function public.assign_captain_to_ship(
  p_request_id          text,
  p_captain_instance_id uuid,
  p_main_ship_id        uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated', 'message', 'You must be signed in.');
  end if;
  -- flag gate FIRST (defense-in-depth + anti-probe, 0083/0099/0109/0113 idiom): while dark, the
  -- answer is the identical locked envelope regardless of input. The private command re-checks
  -- first and is the final authority.
  if not public.cfg_bool('captain_assignment_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'captain_assignment_disabled');
  end if;
  return public.captain_command_client_envelope(
    public.captain_execute_command(v_player, 'assign', p_captain_instance_id, p_main_ship_id, p_request_id));
end;
$$;

create or replace function public.unassign_captain_from_ship(
  p_request_id          text,
  p_captain_instance_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated', 'message', 'You must be signed in.');
  end if;
  if not public.cfg_bool('captain_assignment_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'captain_assignment_disabled');
  end if;
  return public.captain_command_client_envelope(
    public.captain_execute_command(v_player, 'unassign', p_captain_instance_id, null, p_request_id));
end;
$$;

-- ── 5) ACL (anti-cheat; targeted 0083/0095 idiom, verbatim from 0113:305–317 — the 0064-era
--       default-privileges revoke already denies new functions, these re-assert explicitly).
--       No existing grant is touched.
-- the private command + the shared mapper stay OFF the client surface:
revoke execute on function public.captain_execute_command(uuid, text, uuid, uuid, text) from public, anon, authenticated;
grant  execute on function public.captain_execute_command(uuid, text, uuid, uuid, text) to service_role;
revoke execute on function public.captain_command_client_envelope(jsonb) from public, anon, authenticated;
grant  execute on function public.captain_command_client_envelope(jsonb) to service_role;
-- the TWO client commands (dark: their gates and the command's first check reject today):
revoke execute on function public.assign_captain_to_ship(text, uuid, uuid) from public, anon;
grant  execute on function public.assign_captain_to_ship(text, uuid, uuid) to authenticated;
revoke execute on function public.unassign_captain_from_ship(text, uuid) from public, anon;
grant  execute on function public.unassign_captain_from_ship(text, uuid) to authenticated;
