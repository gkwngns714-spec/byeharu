-- Byeharu — FITTING-P14 SLICE C: the dark two-layer fit/unfit command — module_fitting_receipts
-- (player-scoped idempotency ledger, Fitting-owned) + ONE private command (fitting_execute_command)
-- behind TWO thin authenticated wrappers (fit_module_to_ship / unfit_module_from_ship). NO frontend,
-- NO adapter change, NO verify script this slice.
--
-- THE ENTIRE SURFACE IS DARK TODAY: module_fitting_enabled = 'false' (0111), and the private
-- command rejects 'feature_disabled' BEFORE any other read (the 0097/0102/0107
-- reject-before-any-read law), with the defense-in-depth + anti-probe gate in BOTH public wrappers
-- too (0083/0099/0109 idiom — a dark feature answers identically regardless of input).
--
-- IDIOM SOURCE (matched line-by-line): 0109 (craft_module → production_craft_module) — receipts
-- table posture, dark-gate-first order, per-player advisory lock BEFORE the replay check,
-- trade-semantics verbatim replay with NO payload-conflict check (a reused request_id returns the
-- ORIGINAL success envelope flagged 'idempotent_replay', even if the replayed call names a
-- different module/ship — exactly as a same-key-different-good market_buy replay does; the 0099
-- request_id_payload_conflict hash check belongs to the ship-scoped space receipts, which this
-- player-scoped command does NOT use), failure-writes-no-receipt, envelope shapes, and the
-- grants/relock block. The mutation itself delegates to fitting_apply (0112) — this command NEVER
-- touches ship_module_fittings directly (the sole-writer law).
--
-- DELIBERATE ADAPTATIONS of 0109 for the two-action shape (recorded honestly):
--   · ONE PRIVATE COMMAND FOR BOTH ACTIONS ('fit'/'unfit') — precisely so module_fitting_receipts
--     keeps ONE sole writer (one sole writer per table covers ALL its mutations; a fit-command and
--     an unfit-command each inserting receipts would be TWO writers).
--   · RECEIPTS STORE THE FULL RESULT ENVELOPE (result_json): 0109 rebuilt its replay envelope from
--     receipt columns, which works because every craft success has ONE shape. Fit and unfit
--     successes have DIFFERENT shapes, so the receipt stores the writer's success envelope verbatim
--     and replay returns it verbatim (+ the 'idempotent_replay' flag) — storing the envelope IS the
--     verbatim guarantee, not a rebuild approximation. The request fingerprint (action /
--     module_instance_id / main_ship_id-as-requested) is stored alongside for audit.
--   · PRIMARY KEY (player_id, request_id) — the locked keying (the idempotency key IS the row
--     identity); 0109 used a surrogate receipt_id + a UNIQUE on the same pair. Same semantics.
--   · ONE SHARED reason→code/message MAPPER (fitting_command_client_envelope): 0109 inlined the map
--     in its single wrapper; TWO wrappers would duplicate that non-trivial block, so it is
--     extracted once and called by both (the no-duplication hard rule).
--
-- LOCK REENTRANCY (why the nested acquisition is safe): this command takes the SAME per-player
-- advisory lock key as fitting_apply — pg_advisory_xact_lock(hashtext('module_fitting'),
-- hashtext(player)) — BEFORE its replay check, then fitting_apply re-acquires it inside the same
-- transaction. pg_advisory_xact_lock is reentrant within a transaction (a lock already held by the
-- current transaction is simply granted again), so the nested acquisition cannot deadlock, and the
-- replay check is serialized with ALL of the player's fitting mutations: a same-request_id race
-- resolves to one mutation + one verbatim replay.
--
-- THE GAME RULE THIS LAYER OWNS — ship-must-be-home ('ship_not_home'): the affected ship
-- (p_main_ship_id on fit; the currently-fitted ship on unfit) must have spatial_state = 'home'.
-- RATIONALE (constrained state transitions): a loadout must never change mid-transit / in-space /
-- mid-combat — expedition stats are frozen for the duration of an expedition; refitting happens at
-- home, before departure. The check is fail-closed (`is distinct from 'home'`): NULL (legacy) and
-- every other state reject. ⚠ AS-SHIPPED HONESTY NOTE (for the human activation review): TODAY no
-- shipped writer ever sets spatial_state = 'home' — commissions insert ships at_location
-- (0072/0077/0078/0080), the OSN writers produce in_transit/in_space/at_location, and
-- destruction/repair leave NULL (0059) — so with current writers EVERY existing ship answers
-- ship_not_home even once the flag flips. This is a deliberate strict reading of the locked rule,
-- recorded in DEV_LOG; relaxing it (e.g. to the 0100/0105 settled-SAFE set
-- spatial_state in ('home','at_location')) or adding a writer that sets 'home' is a forward-only
-- HUMAN decision, not this loop's.
-- Layer split (the 0112 header law, now fulfilled): the WRITER owns table invariants (ownership,
-- one-ship-per-module, the slot hard cap); this COMMAND owns the game rules (dark gate, home rule,
-- receipt idempotency). The writer stays the final authority on the invariants it owns.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): module_fitting_receipts → Fitting
-- (sole writer = fitting_execute_command via the two public wrappers). fitting_apply's "called by
-- NOTHING yet" note is replaced: this command is its ONE caller. New edges, all DOWNWARD: Fitting →
-- Reference/Config (cfg_bool flag read) · Main Ship (spatial_state read) — no cycle; nothing
-- depends on Fitting yet. No flag flipped; 0001–0112 unedited.

-- ── 1) module_fitting_receipts — per-player idempotent fit/unfit ledger (Fitting-owned) ───────────
create table public.module_fitting_receipts (
  player_id          uuid not null references auth.users (id) on delete cascade,
  request_id         text not null,                          -- idempotency key (per-player)
  action             text not null check (action in ('fit','unfit')),
  -- request fingerprint (audit; replay truth is result_json). on delete cascade on both refs: the
  -- referenced rows only ever disappear via the auth.users cascade today — cascading the receipt
  -- keeps account deletion order-safe across the multi-path cascade graph (the 0088/0109 lesson).
  module_instance_id uuid not null references public.module_instances (id) on delete cascade,
  main_ship_id       uuid references public.main_ship_instances (main_ship_id) on delete cascade,  -- as requested; NULL on unfit
  result_json        jsonb not null,                         -- the writer's success envelope, verbatim
  created_at         timestamptz not null default now(),
  primary key (player_id, request_id)                        -- the idempotency key IS the identity
);
-- No extra index: the PK leads on player_id and covers idempotency probes + owner lookups (the
-- 0086/0109 comment idiom).

alter table public.module_fitting_receipts enable row level security;
-- Owner-read only (0109:71–77 posture verbatim); granted to authenticated, NOT anon. NO insert/
-- update/delete policy and NO write grant → clients cannot mutate; Fitting is sole writer
-- (server-only command below).
create policy "module_fitting_receipts_select_own" on public.module_fitting_receipts
  for select using (player_id = auth.uid());
grant select on public.module_fitting_receipts to authenticated;

comment on table public.module_fitting_receipts is
  'FITTING-P14: per-player idempotent fit/unfit ledger (Fitting-owned; sole writer = the ONE '
  'private command fitting_execute_command via the fit_module_to_ship / unfit_module_from_ship '
  'wrappers — one command handles BOTH actions so this table keeps ONE writer). PK '
  '(player_id, request_id) is the replay key — a replayed command returns result_json verbatim '
  '(0089/0095/0109 trade semantics, no payload-conflict check). Only SUCCESSFUL mutations write a '
  'receipt. Players read only their own rows. Feature DARK behind module_fitting_enabled.';

-- ── 2) fitting_execute_command — the ONE private command (Fitting); SOLE writer of the receipts ───
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
  v_rcpt  module_fitting_receipts%rowtype;
  v_state text;
  v_res   jsonb;
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
  --    header): all of this player's fitting commands AND mutations queue here, so a
  --    same-request_id race resolves to one mutation + one verbatim replay, and the home-rule read
  --    below cannot be raced by another fitting command of this player.
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

  -- 6) THE GAME RULE THIS LAYER OWNS — ship-must-be-home (see header for the rationale + the
  --    as-shipped honesty note). Fail-closed: `is distinct from 'home'` rejects NULL (legacy) and
  --    every non-home state. Reads are owner-scoped so another player's ship state can never be
  --    probed (the not-owned answer is identical to the writer's); the writer remains the final
  --    authority on ownership.
  if p_action = 'fit' then
    select spatial_state into v_state from main_ship_instances
      where main_ship_id = p_main_ship_id and player_id = p_player;
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'ship_not_owned');
    end if;
    if v_state is distinct from 'home' then
      return jsonb_build_object('ok', false, 'reason', 'ship_not_home');
    end if;
  else
    -- unfit: the affected ship is the one the module is CURRENTLY fitted to. Owner-scoped read; if
    -- no fitting row exists, delegate — the writer answers module_not_owned / not_fitted truthfully.
    select s.spatial_state into v_state
      from ship_module_fittings f
      join main_ship_instances s on s.main_ship_id = f.main_ship_id
      where f.module_instance_id = p_module_instance_id and f.player_id = p_player;
    if found and v_state is distinct from 'home' then
      return jsonb_build_object('ok', false, 'reason', 'ship_not_home');
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

-- ── 3) fitting_command_client_envelope — the ONE shared reason→code/message mapper ────────────────
-- 0109 inlined this map in its single wrapper; with TWO wrappers the block would be duplicated, so
-- it is extracted once (the no-duplication hard rule) and both wrappers call it. Pure jsonb→jsonb.
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
      when 'ship_not_home'      then 'ship_not_home'
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
      when 'ship_not_home'      then 'The ship must be at home to change its module loadout.'
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

-- ── 4) the TWO thin authenticated wrappers (0109:200–222 wrapper idiom; fixed action each) ────────
-- DARK TODAY: module_fitting_enabled = 'false', so the gate below and the command's first check
-- both reject every call — the entire surface ships server-rejected with no client UI.
-- Named per ROADMAP :89 ("fit_module_to_ship").
create or replace function public.fit_module_to_ship(
  p_module_instance_id uuid,
  p_main_ship_id       uuid,
  p_request_id         text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'code', 'not_authenticated', 'message', 'You must be signed in.');
  end if;
  -- flag gate FIRST (defense-in-depth + anti-probe, 0083/0099/0109 idiom): while dark, the answer
  -- is identical regardless of input. The private command re-checks first and is the final authority.
  if not public.cfg_bool('module_fitting_enabled') then
    return jsonb_build_object('ok', false, 'code', 'feature_disabled', 'message', 'Module fitting is not available yet.');
  end if;
  return public.fitting_command_client_envelope(
    public.fitting_execute_command(v_player, 'fit', p_module_instance_id, p_main_ship_id, p_request_id));
end;
$$;

create or replace function public.unfit_module_from_ship(
  p_module_instance_id uuid,
  p_request_id         text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'code', 'not_authenticated', 'message', 'You must be signed in.');
  end if;
  if not public.cfg_bool('module_fitting_enabled') then
    return jsonb_build_object('ok', false, 'code', 'feature_disabled', 'message', 'Module fitting is not available yet.');
  end if;
  return public.fitting_command_client_envelope(
    public.fitting_execute_command(v_player, 'unfit', p_module_instance_id, null, p_request_id));
end;
$$;

-- ── 5) ACL (anti-cheat; targeted 0083/0095 idiom, verbatim from 0109:265–273 — the 0064-era
--       default-privileges revoke already denies new functions, these re-assert explicitly).
--       No existing grant is touched.
-- the private command + the shared mapper stay OFF the client surface:
revoke execute on function public.fitting_execute_command(uuid, text, uuid, uuid, text) from public, anon, authenticated;
grant  execute on function public.fitting_execute_command(uuid, text, uuid, uuid, text) to service_role;
revoke execute on function public.fitting_command_client_envelope(jsonb) from public, anon, authenticated;
grant  execute on function public.fitting_command_client_envelope(jsonb) to service_role;
-- the TWO client commands (dark: their gates and the command's first check reject today):
revoke execute on function public.fit_module_to_ship(uuid, uuid, text) from public, anon;
grant  execute on function public.fit_module_to_ship(uuid, uuid, text) to authenticated;
revoke execute on function public.unfit_module_from_ship(uuid, text) from public, anon;
grant  execute on function public.unfit_module_from_ship(uuid, text) to authenticated;
